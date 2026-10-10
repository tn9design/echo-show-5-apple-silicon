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
  let sessionID: UUID
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
      let consumed = try self.consumeApproval(requestID: requestID, evidence: evidence, now: now)
      return try await callback(consumed)
    }
  }

  /// The validator runs under the same operation ownership as consumption and
  /// dispatch. It must only inspect the selected device and immutable inputs.
  func withFreshConsumedApproval<T: Sendable>(requestID: UUID,
      nativeLease: NativeConfirmationLease? = nil,
      validator: @Sendable (SessionRecord) async throws -> FreshApprovalEvidence,
      callback: @Sendable (ConsumedApproval) async throws -> T) async throws -> T {
    try await operation("consume_native_approval") {
      let initial = try self.status()
      guard initial.pendingApproval?.id == requestID else {
        throw GuideError.stopped("Approval is missing or already consumed")
      }
      let evidence = try await validator(initial)
      try Task.checkCancellation()
      let consumed: ConsumedApproval
      if let nativeLease {
        consumed = try nativeLease.consuming {
          try self.consumeApproval(requestID: requestID, evidence: evidence, now: Date())
        }
      } else {
        consumed = try self.consumeApproval(requestID: requestID, evidence: evidence, now: Date())
      }
      return try await callback(consumed)
    }
  }

  private func consumeApproval(requestID: UUID, evidence: FreshApprovalEvidence,
                               now: Date) throws -> ConsumedApproval {
    let consumed = try store.transaction { state in
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
      let metadata = ConsumedApproval(requestID: request.id, sessionID: request.sessionID,
        action: request.action, device: request.device,
        prerequisitesDigest: request.prerequisitesDigest)
      state.pendingApproval = nil
      state.phase = .inspectionRequired
      return metadata
    }
    try Self.synchronizeConsumedApproval(at: store.root)
    return consumed
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
