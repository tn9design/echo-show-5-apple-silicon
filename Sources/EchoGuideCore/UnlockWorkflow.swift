import Foundation

/// No live transport is provided. A future audited guest adapter must verify
/// artifact bytes and authenticated guest readiness before returning this evidence.
struct UnlockValidation: Sendable {
  let vmID: UUID
  let hostKeyFingerprint: String
  let clientSHA256: String
  let payloadSHA256: String
  let ready: Bool
}
enum UnlockCommand: Sendable, Equatable {
  case getvar(serial: String, key: String)
  case flashPinnedBrick(serial: String)
}
protocol UnlockTransport: Sendable {
  func validate(session: SessionRecord, profile: CompatibilityProfile) async throws -> UnlockValidation
  func execute(_ command: UnlockCommand, timeoutSeconds: Int) async throws -> CommandResult
}
protocol UnlockClock: Sendable {
  func sleep(seconds: Int) async throws
  /// Must wait one real second independently of caller/transfer cancellation.
  /// Only clock failure may throw; production adapters require separate audit.
  func poweredWaitSecond() async throws
}
struct PoweredWaitRecord: Codable, Sendable {
  let requestID: UUID
  let requiredSeconds: Int
  let elapsedSeconds: Int
  let complete: Bool
}
struct UnlockProgress: Sendable {
  let attempts: Int
  let poweredWaitElapsedSeconds: Int
  let poweredWaitRequiredSeconds: Int
}
struct UnlockOutcome: Sendable {
  let attempts: Int
  let reason: String
  // Intentionally no success flag: independent recovery verification is required.
}

extension WorkflowEngine {
  func poweredWaitStatus() throws -> PoweredWaitRecord? {
    let url = store.root.appendingPathComponent("unlock-powered-wait.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(PoweredWaitRecord.self, from: Data(contentsOf: url))
  }

  /// Internal pilot orchestration only. Ownership spans validation, consumption,
  /// all attempts, and the powered wait; interrupted writes are never replayed.
  func unlockPinnedDevice(requestID: UUID, transport: any UnlockTransport,
      clock: any UnlockClock,
      progress: (@Sendable (UnlockProgress) -> Void)? = nil) async throws -> UnlockOutcome {
    try await withFreshConsumedApproval(requestID: requestID, validator: { state in
      guard state.phase == .identified, state.pendingApproval?.action == .unlock,
        let device = state.device, device.product == self.profile.product,
        device.lkBuild == self.profile.lkBuild,
        device.serial.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil,
        let guest = state.guest, guest.ready, state.vmID == guest.vmID.uuidString
      else { throw GuideError.stopped("Unlock requires exact identity and a ready owned guest") }
      let evidence = try await transport.validate(session: state, profile: self.profile)
      guard evidence.ready, evidence.vmID == guest.vmID,
        evidence.hostKeyFingerprint == guest.hostKeyFingerprint,
        evidence.clientSHA256 == (try self.profile.artifact(named: "fastboot").sha256),
        evidence.payloadSHA256 == (try self.profile.artifact(named: "fastbrick-20240709.img").sha256)
      else { throw GuideError.stopped("Fresh guest or pinned unlock artifacts failed validation") }
      for (key, expected) in [("product", self.profile.product), ("unlock_status", "false"),
                              ("lk_build_desc", self.profile.lkBuild)] {
        let result = try await transport.execute(.getvar(serial: device.serial, key: key), timeoutSeconds: 10)
        guard result.exitCode == 0,
          PilotSequence.exactGetvar(result.stdout + result.stderr, key: key, expected: expected)
        else { throw GuideError.stopped("Fresh unlock identity mismatch: " + key) }
      }
      return FreshApprovalEvidence(prerequisites: try ApprovalPrerequisites.capture(
        session: state, action: .unlock, profile: self.profile), checkedAt: Date())
    }, callback: { consumed in
      guard consumed.action == .unlock else { throw GuideError.stopped("Wrong approval action") }
      var attempts = 0
      var reason = "Known rejection limit reached; recovery inspection required"
      let waitURL = self.store.root.appendingPathComponent("unlock-powered-wait.json")
      func recordWait(_ elapsed: Int) throws {
        let data = try JSONEncoder().encode(PoweredWaitRecord(requestID: consumed.requestID,
          requiredSeconds: 300, elapsedSeconds: elapsed, complete: elapsed == 300))
        try data.write(to: waitURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: waitURL.path)
      }
      try recordWait(0)
      while attempts < 3 {
        attempts += 1
        do {
          let result = try await transport.execute(.flashPinnedBrick(serial: consumed.device.serial),
                                                   timeoutSeconds: 8)
          guard PilotSequence.ordinaryRejection(result.stdout + result.stderr, exit: result.exitCode) else {
            reason = "Unexpected response; recovery inspection required"
            break
          }
          if attempts < 3 { try await clock.sleep(seconds: 2) }
        } catch {
          reason = "Transfer interrupted or timed out; recovery inspection required"
          break
        }
      }
      progress?(UnlockProgress(attempts: attempts, poweredWaitElapsedSeconds: 0,
                               poweredWaitRequiredSeconds: 300))
      for elapsed in 1...300 {
        do { try await clock.poweredWaitSecond() }
        catch { throw GuideError.stopped("Powered wait incomplete; keep wall power connected for at least five minutes and inspect") }
        try recordWait(elapsed)
        progress?(UnlockProgress(attempts: attempts, poweredWaitElapsedSeconds: elapsed,
                                 poweredWaitRequiredSeconds: 300))
      }
      // Approval consumption already committed inspectionRequired. No result,
      // including timeout or exit zero, is evidence of recovery or unlock success.
      return UnlockOutcome(attempts: attempts, reason: reason)
    })
  }
}
