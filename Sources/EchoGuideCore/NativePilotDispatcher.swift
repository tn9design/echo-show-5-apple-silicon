import Foundation

enum NativePilotGate: Sendable { case disabled, experimentalOptIn }
struct NativePilotEnvironmentProof: Sendable {
  let host: HostInspection
  /// Must be refreshed by an audited owned-VM/guest adapter, not a session echo.
  let guest: GuestWorkspaceRecord
}
enum NativePilotResult: Sendable {
  case recoveryInspectionRequired(UnlockOutcome)
  case installedAwaitingUserStartup
}

/// Native-only internal composition. There is no production environment prover
/// or unlock transport default, nor a public CLI/MCP approval method. Request ID
/// comes from native confirmation; this API cannot itself prove a human UI click.
struct NativePilotDispatcher: Sendable {
  let engine: WorkflowEngine
  let gate: NativePilotGate
  let environment: @Sendable (SessionRecord) async throws -> NativePilotEnvironmentProof
  let unlockTransport: any UnlockTransport
  let clock: any UnlockClock

  init(engine: WorkflowEngine, gate: NativePilotGate = .disabled,
       environment: @escaping @Sendable (SessionRecord) async throws -> NativePilotEnvironmentProof,
       unlockTransport: any UnlockTransport, clock: any UnlockClock = PoweredWaitClock()) {
    self.engine = engine; self.gate = gate; self.environment = environment
    self.unlockTransport = unlockTransport; self.clock = clock
  }

  func dispatch(nativeConfirmedRequestID: UUID) async throws -> NativePilotResult {
    guard gate == .experimentalOptIn else {
      throw GuideError.stopped("Native experimental pilot is disabled")
    }
    let state = try engine.status()
    guard let request = state.pendingApproval, request.id == nativeConfirmedRequestID else {
      throw GuideError.stopped("Native confirmation request is missing or changed")
    }
    let check: @Sendable (SessionRecord) async throws -> Void = { current in
      let proof = try await environment(current)
      let age = Date().timeIntervalSince(proof.guest.checkedAt)
      guard age.isFinite, age >= 0, age < 30, proof.host.architecture == "arm64", proof.host.writingBackendSupported,
        let guest = current.guest, guest.ready, proof.guest.ready,
        current.vmID == guest.vmID.uuidString, proof.guest.vmID == guest.vmID,
        proof.guest.hostKeyFingerprint == guest.hostKeyFingerprint,
        !proof.guest.hostKeyFingerprint.isEmpty else {
        throw GuideError.stopped("Fresh supported host and authenticated owned guest proof required")
      }
    }
    switch request.action {
    case .unlock:
      return .recoveryInspectionRequired(try await engine.unlockPinnedDevice(
        requestID: nativeConfirmedRequestID, transport: unlockTransport, clock: clock,
        hostPrerequisite: check))
    case .install:
      guard let adb = state.adbPath else { throw GuideError.stopped("Configured recovery ADB is missing") }
      try await engine.installPinnedROM(requestID: nativeConfirmedRequestID,
        adb: URL(fileURLWithPath: adb), hostPrerequisite: check)
      return .installedAwaitingUserStartup
    }
  }
}
