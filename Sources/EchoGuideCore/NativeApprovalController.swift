import Foundation

struct NativePilotSelection: Sendable, Equatable {
  let utm: URL
  let unlockPayload: URL?
}
struct NativeApprovalSummary: Sendable {
  let requestID: UUID
  let sessionID: UUID
  let action: WriteAction
  let device: DeviceIdentity
  let evidenceFingerprint: String
  let expiresAt: Date
  let selection: NativePilotSelection
  let pinnedArtifactSHA256: String
}
enum NativeApprovalDecision: Sendable { case cancel, confirm }

/// In-memory native confirmation lifecycle only. There is no public approval
/// endpoint or persisted confirmation token, and the default gate never presents
/// a destructive approval. A presenter is trusted native UI, not assistant input.
@MainActor
final class NativeApprovalController {
  typealias Presenter = @MainActor @Sendable (NativeApprovalSummary) async throws -> NativeApprovalDecision
  typealias SelectionValidator = @Sendable (NativePilotSelection, WriteAction) async throws -> Void
  private let engine: WorkflowEngine
  private let gate: NativePilotGate
  private let presenter: Presenter
  private let dispatch: @Sendable (UUID, NativePilotSelection) async throws -> NativePilotResult
  private let validateSelection: SelectionValidator
  private let now: @Sendable () -> Date
  private var generation = UUID()
  private var closed = false

  init(engine: WorkflowEngine, gate: NativePilotGate = .disabled,
       presenter: @escaping Presenter,
       dispatch: @escaping @Sendable (UUID, NativePilotSelection) async throws -> NativePilotResult,
       validateSelection: SelectionValidator? = nil,
       now: @escaping @Sendable () -> Date = { Date() }) {
    self.engine = engine; self.gate = gate; self.presenter = presenter
    self.dispatch = dispatch; self.now = now
    let profile = engine.profile
    self.validateSelection = validateSelection ?? { selection, action in
      guard selection.utm.isFileURL, selection.utm.pathExtension == "app",
        selection.utm.standardizedFileURL == selection.utm.resolvingSymlinksInPath().standardizedFileURL,
        try selection.utm.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw GuideError.stopped("Select the local UTM application; ownership is checked before dispatch")
      }
      if action == .unlock {
        guard let payload = selection.unlockPayload, payload.isFileURL,
          payload.standardizedFileURL == payload.resolvingSymlinksInPath().standardizedFileURL else {
          throw GuideError.stopped("Native selection requires the pinned unlock payload")
        }
        let artifact = try profile.artifact(named: "fastbrick-20240709.img")
        let attributes = try FileManager.default.attributesOfItem(atPath: payload.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.size] as? NSNumber)?.int64Value == artifact.size,
          try RecoveryAdapter.hash(payload) == artifact.sha256 else {
          throw GuideError.stopped("Selected unlock payload changed or is unsupported")
        }
      } else if selection.unlockPayload != nil {
        throw GuideError.stopped("Installation does not select an unlock payload")
      }
    }
  }

  private static func sameRequest(_ current: ApprovalRequest?, _ reviewed: ApprovalRequest) -> Bool {
    guard let current else { return false }
    return current.id == reviewed.id && current.action == reviewed.action
      && current.device == reviewed.device && current.createdAt == reviewed.createdAt
      && current.sessionID == reviewed.sessionID
      && current.prerequisitesDigest == reviewed.prerequisitesDigest
  }

  /// Native window/app close permanently invalidates this controller instance.
  /// Reopening requires a fresh controller and a fresh native confirmation.
  func invalidateForClosure() { closed = true; generation = UUID() }

  func confirm(requestID: UUID, selection: NativePilotSelection) async throws -> NativePilotResult? {
    guard gate == .experimentalOptIn, !closed else {
      throw GuideError.stopped("Native pilot confirmation is disabled or closed")
    }
    let presentation = UUID(); generation = presentation
    let state = try engine.status()
    guard let request = state.pendingApproval, request.id == requestID,
      state.operations.allSatisfy({ $0.completedAt != nil }) else {
      throw GuideError.stopped("Native request is absent or an operation needs inspection")
    }
    let prerequisites = try ApprovalPrerequisites.capture(session: state, action: request.action, profile: engine.profile)
    try ApprovalPolicy.validate(request, requestID: requestID, current: prerequisites, now: now())
    try await validateSelection(selection, request.action)
    let artifact = try engine.profile.artifact(named: request.action == .unlock
      ? "fastbrick-20240709.img" : ROMStagingAdapter.filename)
    let summary = NativeApprovalSummary(requestID: request.id, sessionID: request.sessionID,
      action: request.action, device: request.device, evidenceFingerprint: request.prerequisitesDigest,
      expiresAt: request.createdAt.addingTimeInterval(ApprovalPolicy.validitySeconds),
      selection: selection, pinnedArtifactSHA256: artifact.sha256)
    let decision = try await presenter(summary)
    try Task.checkCancellation()
    guard !closed, generation == presentation else {
      throw GuideError.stopped("Native window closed or another review replaced this confirmation")
    }
    guard decision == .confirm else {
      try engine.rejectApproval(requestID: requestID)
      return nil
    }
    let current = try engine.status()
    guard Self.sameRequest(current.pendingApproval, request),
      current.operations.allSatisfy({ $0.completedAt != nil }) else {
      throw GuideError.stopped("Native request changed while confirmation was open")
    }
    let refreshed = try ApprovalPrerequisites.capture(session: current, action: request.action, profile: engine.profile)
    try ApprovalPolicy.validate(request, requestID: requestID, current: refreshed, now: now())
    try await validateSelection(selection, request.action)
    try Task.checkCancellation()
    guard !closed, generation == presentation else {
      throw GuideError.stopped("Native review was invalidated during selection verification")
    }
    let finalState = try engine.status()
    guard Self.sameRequest(finalState.pendingApproval, request) else {
      throw GuideError.stopped("Native request changed during selection verification")
    }
    try ApprovalPolicy.validate(request, requestID: requestID,
      current: ApprovalPrerequisites.capture(session: finalState, action: request.action, profile: engine.profile),
      now: now())
    // The dispatcher independently refreshes host/guest/device/artifact evidence
    // under operation ownership and consumes approval before any device write.
    return try await dispatch(requestID, selection)
  }
}
