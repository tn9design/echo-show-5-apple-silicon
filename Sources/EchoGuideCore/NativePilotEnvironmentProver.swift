import Foundation

private struct BoundedPilotReadRunner: CommandRunning {
  let runner: any TimedCommandRunning
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    try await runner.run(executable: executable, arguments: arguments, timeoutSeconds: 25)
  }
}

/// Production read-only environment composition. Calling this does not start a
/// VM, bootstrap trust, stage files, discover an Echo, or enable the pilot gate.
struct NativePilotEnvironmentProver: Sendable {
  let engine: WorkflowEngine
  let utm: URL
  let inspectHost: @Sendable () async throws -> HostInspection
  init(engine: WorkflowEngine, utm: URL,
       inspectHost: (@Sendable () async throws -> HostInspection)? = nil) {
    self.engine = engine; self.utm = utm
    self.inspectHost = inspectHost ?? { try await engine.inspect() }
  }
  func prove(session: SessionRecord) async throws -> NativePilotEnvironmentProof {
    guard let saved = session.guest, saved.ready,
      session.vmID == saved.vmID.uuidString,
      let timed = engine.runner as? any TimedCommandRunning else {
      throw GuideError.stopped("Recorded owned guest and bounded runner are required")
    }
    let initialHost = try await inspectHost()
    guard initialHost.architecture == "arm64", initialHost.writingBackendSupported else {
      throw GuideError.stopped("Fresh host does not support the experimental pilot backend")
    }
    let intentURL = engine.store.root.appendingPathComponent("workspace-intent.json")
    guard intentURL.standardizedFileURL == intentURL.resolvingSymlinksInPath().standardizedFileURL else {
      throw GuideError.stopped("Workspace ownership intent cannot be a symbolic link")
    }
    let intentData = try Data(contentsOf: intentURL)
    let specification = try JSONDecoder().decode(OwnedVMSpecification.self, from: intentData)
    guard specification.backend == "Apple", specification.architecture == "aarch64" else {
      throw GuideError.stopped("Owned workspace specification changed")
    }
    let bounded = BoundedPilotReadRunner(runner: timed)
    let adapter = UTMAdapter(runner: bounded, application: utm)
    func verifyVM() async throws {
      guard case .owned(let vm) = try await adapter.reconcile(specification: specification,
        registeredVMID: saved.vmID), vm.id == saved.vmID,
        vm.backend == "apple", vm.state == .started else {
        throw GuideError.stopped("Exact app-owned Apple VM must be running")
      }
    }
    try await verifyVM()
    let directory = engine.store.root.appendingPathComponent("guest-" + saved.vmID.uuidString)
    let guest = try GuestAdapter(runner: bounded, ownedVMID: saved.vmID,
      credentialsDirectory: directory, address: saved.address)
    let trust = GuestIdentificationAdapter(guest: guest, profile: engine.profile,
                                           fingerprint: saved.hostKeyFingerprint)
    try trust.validateTrust()
    let readiness = try await guest.readiness()
    guard readiness.ready else { throw GuideError.stopped(readiness.reason) }
    // Ensure local bindings and ownership did not change during the offline test.
    try trust.validateTrust()
    try await verifyVM()
    guard try Data(contentsOf: intentURL) == intentData else {
      throw GuideError.stopped("Workspace ownership intent changed during proof")
    }
    let current = try engine.status()
    guard current.id == session.id, current.vmID == session.vmID,
      current.guest?.vmID == saved.vmID, current.guest?.address == saved.address,
      current.guest?.hostKeyFingerprint == saved.hostKeyFingerprint,
      current.guest?.ready == true else {
      throw GuideError.stopped("Recorded guest changed during environment proof")
    }
    let host = try await inspectHost()
    guard host.architecture == "arm64", host.writingBackendSupported else {
      throw GuideError.stopped("Host backend changed during environment proof")
    }
    return NativePilotEnvironmentProof(host: host, guest: GuestWorkspaceRecord(vmID: saved.vmID,
      address: saved.address, hostKeyFingerprint: saved.hostKeyFingerprint,
      checkedAt: Date(), ready: true))
  }
}
