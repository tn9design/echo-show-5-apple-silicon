import Foundation

public struct GuestWorkspaceRecord: Codable, Sendable {
  public let vmID: UUID
  public let address: String
  public let hostKeyFingerprint: String
  public let checkedAt: Date
  public var ready: Bool
}

extension WorkflowEngine {
  /// Explicit action using a memory-only password or an already authenticated serial shell.
  /// Acquires trust through serial before any SSH operation; never accepts a caller's host key.
  public func bootstrapOwnedGuest(utm: URL, password: String? = nil) async throws
    -> GuestBootstrapEvidence
  {
    try await operation("bootstrap_guest") {
      let state = try self.status()
      guard let text = state.vmID, let id = UUID(uuidString: text) else {
        throw GuideError.stopped("No registered app-owned workspace")
      }
      let specification = try JSONDecoder().decode(
        OwnedVMSpecification.self,
        from: Data(contentsOf: self.store.root.appendingPathComponent("workspace-intent.json")))
      let username = try GuestUsername.validated(state.guestUsername ?? "user")
      let adapter = UTMAdapter(runner: self.runner, application: utm)
      let channel = try await adapter.serialChannel(specification: specification, vmID: id)
      let terminal = try SerialTransport(channel: channel)
      do {
        if let password { try await SerialLogin.authenticate(terminal, password: password, username: username) }
        let observation = try GuestBootstrapRequest(ownedVMID: id, username: username)
        let initial = try await Self.bootstrapExchange(terminal, request: observation)
        let guest = try GuestAdapter(
          runner: self.runner, ownedVMID: id,
          credentialsDirectory: self.store.root.appendingPathComponent("guest-" + id.uuidString),
          address: initial.address, username: username)
        // A failed/interrupted identity setup is inspected rather than overwritten or replayed.
        let publicKeyFile = try await guest.createClientIdentity()
        let publicKey = try String(contentsOf: publicKeyFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard try await adapter.serialChannel(specification: specification, vmID: id) == channel
        else {
          throw GuideError.stopped(
            "Owned VM serial channel changed; inspect before key installation")
        }
        let installation = try GuestBootstrapRequest(ownedVMID: id, clientPublicKey: publicKey, username: username)
        let installed = try await Self.bootstrapExchange(terminal, request: installation)
        guard installed.address == initial.address,
          installed.trust.publicHostKey == initial.trust.publicHostKey
        else {
          throw GuideError.stopped("Guest identity or address changed during serial bootstrap")
        }
        let fingerprint = try guest.pinHostKey(installed.trust)
        try self.store.transaction { session in
          guard session.vmID == id.uuidString, (session.guestUsername ?? "user") == username else { throw GuideError.stopped("Workspace changed") }
          session.guest = GuestWorkspaceRecord(
            vmID: id, address: installed.address,
            hostKeyFingerprint: fingerprint, checkedAt: Date(), ready: false)
        }
        await terminal.close()
        return installed
      } catch {
        await terminal.close()
        throw error
      }
    }
  }
  /// Refreshes serial trust after restarts before staging the two pinned public validation assets.
  public func validateOwnedGuest(utm: URL, fastboot: URL, mockScript: URL, password: String? = nil)
    async throws
    -> GuestReadiness
  {
    try await operation("validate_guest") {
      let state = try self.status()
      guard let saved = state.guest, state.vmID == saved.vmID.uuidString else {
        throw GuideError.stopped("Bootstrap this owned guest before validation")
      }
      try self.store.transaction { $0.guest?.ready = false }
      let spec = try JSONDecoder().decode(
        OwnedVMSpecification.self,
        from: Data(contentsOf: self.store.root.appendingPathComponent("workspace-intent.json")))
      let username = try GuestUsername.validated(state.guestUsername ?? "user")
      let adapter = UTMAdapter(runner: self.runner, application: utm)
      let channel = try await adapter.serialChannel(specification: spec, vmID: saved.vmID)
      let terminal = try SerialTransport(channel: channel)
      let evidence: GuestBootstrapEvidence
      do {
        if let password { try await SerialLogin.authenticate(terminal, password: password, username: username) }
        evidence = try await Self.bootstrapExchange(
          terminal,
          request: GuestBootstrapRequest(ownedVMID: saved.vmID, username: username))
        await terminal.close()
      } catch {
        await terminal.close()
        throw error
      }
      let guest = try GuestAdapter(
        runner: self.runner, ownedVMID: saved.vmID,
        credentialsDirectory: self.store.root.appendingPathComponent(
          "guest-" + saved.vmID.uuidString),
        address: evidence.address, username: username)
      let fingerprint = try guest.pinHostKey(evidence.trust)
      guard fingerprint == saved.hostKeyFingerprint else {
        throw GuideError.stopped("Guest host key changed")
      }
      try await guest.stageValidationAssets(fastboot: fastboot, mockScript: mockScript)
      let readiness = try await guest.readiness()
      try self.store.transaction { session in
        guard session.vmID == saved.vmID.uuidString, (session.guestUsername ?? "user") == username else {
          throw GuideError.stopped("Workspace changed")
        }
        session.guest = GuestWorkspaceRecord(
          vmID: saved.vmID, address: evidence.address,
          hostKeyFingerprint: fingerprint, checkedAt: Date(), ready: readiness.ready)
      }
      return readiness
    }
  }
  private static func bootstrapExchange(_ terminal: SerialTransport, request: GuestBootstrapRequest)
    async throws -> GuestBootstrapEvidence
  {
    try await terminal.write(Data(GuestBootstrapProtocol.consoleCommand(for: request).utf8))
    let marker = Data(request.endMarker.utf8)
    let data = try await terminal.read(
      until: marker, limit: GuestBootstrapProtocol.maximumTranscriptBytes)
    guard let transcript = String(data: data, encoding: .utf8) else {
      throw GuideError.stopped("Guest serial response is not UTF-8")
    }
    return try GuestBootstrapProtocol.parse(transcript, for: request)
  }
}
