import Foundation
import Darwin

/// Internal validator evidence, never a caller-selectable MCP/CLI parameter.
/// The future pilot validator must independently inspect hardware/artifact bytes
/// before constructing this value; persisted session capture alone is insufficient.
struct FreshApprovalEvidence: Sendable {
  let prerequisites: ApprovalPrerequisites
  let checkedAt: Date
}

/// Scoped metadata handed only to the internal callback after durable consumption.
/// This type is not itself an externally usable write capability.
struct ConsumedApproval: Sendable {
  let requestID: UUID
  let action: WriteAction
  let device: DeviceIdentity
  let prerequisitesDigest: String
}

extension WorkflowEngine {
  /// Internal-only boundary for future pilot integration. No production caller
  /// or live dispatch is wired; public approve remains release-gated.
  func withConsumedApproval<T: Sendable>(requestID: UUID, evidence: FreshApprovalEvidence,
      now: Date = Date(), callback: @Sendable (ConsumedApproval) async throws -> T) async throws -> T {
    try await operation("consume_native_approval") {
      let consumed = try self.store.transaction { state in
        let age = now.timeIntervalSince(evidence.checkedAt)
        guard age.isFinite, age >= 0, age < 30 else {
          throw GuideError.stopped("Fresh approval evidence expired; inspect again")
        }
        guard let request = state.pendingApproval else {
          throw GuideError.stopped("Approval is missing or already consumed")
        }
        let current = try ApprovalPrerequisites.capture(session: state,
          action: request.action, profile: self.profile)
        guard current == evidence.prerequisites else {
          throw GuideError.stopped("Fresh approval evidence differs from current session")
        }
        try ApprovalPolicy.validate(request, requestID: requestID, current: current, now: now)
        let metadata = ConsumedApproval(requestID: request.id, action: request.action,
          device: request.device, prerequisitesDigest: request.prerequisitesDigest)
        // The atomic session write commits before the callback is entered.
        // Unknown outcomes require inspection; approval is never recreated.
        state.pendingApproval = nil
        state.phase = .inspectionRequired
        return metadata
      }
      try Self.synchronizeConsumedApproval(at: self.store.root)
      return try await callback(consumed)
    }
  }

  private static func synchronizeConsumedApproval(at root: URL) throws {
    let state = open(root.appendingPathComponent("session.json").path, O_RDONLY | O_NOFOLLOW)
    guard state >= 0 else { throw GuideError.stopped("Cannot synchronize consumed approval") }
    defer { close(state) }
    guard fsync(state) == 0 else { throw GuideError.stopped("Approval consumption did not synchronize") }
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard directory >= 0 else { throw GuideError.stopped("Cannot synchronize approval directory") }
    defer { close(directory) }
    guard fsync(directory) == 0 else { throw GuideError.stopped("Approval directory did not synchronize") }
  }
}
