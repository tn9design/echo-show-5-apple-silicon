import Foundation

extension WorkflowEngine {
  /// Explicit action after the user logs into this owned VM's console as `user`.
  /// Acquires trust through serial before any SSH operation; never accepts a caller's host key.
  public func bootstrapOwnedGuest(utm: URL) async throws -> GuestBootstrapEvidence {
    try await operation("bootstrap_guest") {
      let state = try self.status()
      guard let text = state.vmID, let id = UUID(uuidString: text) else {
        throw GuideError.stopped("No registered app-owned workspace")
      }
      let specification = try JSONDecoder().decode(
        OwnedVMSpecification.self,
        from: Data(contentsOf: self.store.root.appendingPathComponent("workspace-intent.json")))
      let adapter = UTMAdapter(runner: self.runner, application: utm)
      let channel = try await adapter.serialChannel(specification: specification, vmID: id)
      let terminal = try SerialTransport(channel: channel)
      do {
        let observation = try GuestBootstrapRequest(ownedVMID: id)
        let initial = try await Self.bootstrapExchange(terminal, request: observation)
        let guest = try GuestAdapter(
          runner: self.runner, ownedVMID: id,
          credentialsDirectory: self.store.root.appendingPathComponent("guest-" + id.uuidString),
          address: initial.address)
        // A failed/interrupted identity setup is inspected rather than overwritten or replayed.
        let publicKeyFile = try await guest.createClientIdentity()
        let publicKey = try String(contentsOf: publicKeyFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard try await adapter.serialChannel(specification: specification, vmID: id) == channel
        else {
          throw GuideError.stopped(
            "Owned VM serial channel changed; inspect before key installation")
        }
        let installation = try GuestBootstrapRequest(ownedVMID: id, clientPublicKey: publicKey)
        let installed = try await Self.bootstrapExchange(terminal, request: installation)
        guard installed.address == initial.address,
          installed.trust.publicHostKey == initial.trust.publicHostKey
        else {
          throw GuideError.stopped("Guest identity or address changed during serial bootstrap")
        }
        _ = try guest.pinHostKey(installed.trust)
        await terminal.close()
        return installed
      } catch {
        await terminal.close()
        throw error
      }
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
