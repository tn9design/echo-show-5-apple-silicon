import Foundation

enum NativePilotGate: Sendable { case disabled, experimentalOptIn }
struct NativePilotEnvironmentProof: Sendable {
  let host: HostInspection
  /// Must be refreshed by an audited owned-VM/guest adapter, not a session echo.
  let guest: GuestWorkspaceRecord?
}
enum NativePilotResult: Sendable {
  case recoveryInspectionRequired(UnlockOutcome)
  case installedAwaitingUserStartup
}

/// Native-only internal composition. Environment proof and unlock transport are
/// explicitly supplied; there is no public CLI/MCP approval method. Request ID
/// comes from native confirmation; this API cannot itself prove a human UI click.
struct NativePilotDispatcher: Sendable {
  let engine: WorkflowEngine
  let gate: NativePilotGate
  let environment: @Sendable (SessionRecord) async throws -> NativePilotEnvironmentProof
  let unlockTransport: (any UnlockTransport)?
  let clock: any UnlockClock

  init(engine: WorkflowEngine, gate: NativePilotGate = .disabled,
       environment: @escaping @Sendable (SessionRecord) async throws -> NativePilotEnvironmentProof,
       unlockTransport: (any UnlockTransport)? = nil, clock: any UnlockClock = PoweredWaitClock()) {
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
      guard proof.host.architecture == "arm64", proof.host.writingBackendSupported else {
        throw GuideError.stopped("Fresh supported host proof required")
      }
      if request.action == .unlock {
        guard let observed = proof.guest else { throw GuideError.stopped("Fresh authenticated owned guest proof required for unlock") }
        let age = Date().timeIntervalSince(observed.checkedAt)
        guard age.isFinite, age >= 0, age < 30,
          let guest = current.guest, guest.ready, observed.ready,
          current.vmID == guest.vmID.uuidString, observed.vmID == guest.vmID,
          observed.hostKeyFingerprint == guest.hostKeyFingerprint,
          !observed.hostKeyFingerprint.isEmpty else {
          throw GuideError.stopped("Fresh supported host and authenticated owned guest proof required")
        }
      }
    }
    switch request.action {
    case .unlock:
      guard let unlockTransport else { throw GuideError.stopped("Authenticated unlock transport is missing") }
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
