#if canImport(AppKit)
import AppKit
import Foundation

public enum NativePilotBuildMode: String, Codable, Sendable {
  case preparationPreview
  case experimentalPilot
}
public enum NativePilotReviewResult: Sendable {
  /// This is not unlock success. Independently verify compatible TWRP recovery.
  case recoveryInspectionRequired(attempts: Int, reason: String)
  /// Installation evidence was observed; Android setup still needs human proof.
  case installedAwaitingUserStartup
  case declined
}

/// AppKit-only native facade, absent from CLI/MCP tool registration. The compile
/// flag is an explicit audited source-build choice; no runtime/environment switch
/// can enable writes in the normal preparation preview.
private final class CoordinatorObservers: @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [NSObjectProtocol] = []
  func add(_ token: NSObjectProtocol) { lock.lock(); tokens.append(token); lock.unlock() }
  func removeAll() {
    lock.lock(); let old = tokens; tokens = []; lock.unlock()
    for token in old { NotificationCenter.default.removeObserver(token) }
  }
  deinit { removeAll() }
}

@MainActor
public final class NativePilotCoordinator {
  public static var buildMode: NativePilotBuildMode {
#if ECHOGUIDE_EXPERIMENTAL_PILOT
    .experimentalPilot
#else
    .preparationPreview
#endif
  }
  private let engine: WorkflowEngine
  private weak var window: NSWindow?
  private var owner: NativePilotOwner?
  private let observers = CoordinatorObservers()
  private(set) var closed = false
  private init(engine: WorkflowEngine, window: NSWindow) {
    self.engine = engine; self.window = window
    for name in [NSWindow.willCloseNotification, NSApplication.willTerminateNotification] {
      let object: AnyObject? = name == NSWindow.willCloseNotification ? window : nil
      observers.add(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })
    }
  }
  /// Internal lifecycle fixture only; no window means review can never dispatch.
  init(testOnlyNoWindowEngine engine: WorkflowEngine) { self.engine = engine; self.window = nil }

  /// Nil never yields a runnable coordinator. Disabled builds refuse even before
  /// window/selection inspection, which allows the UI to explain preview limits.
  public static func make(engine: WorkflowEngine, window: NSWindow?) throws -> NativePilotCoordinator {
    guard buildMode == .experimentalPilot else {
      throw GuideError.stopped("This source build is a preparation preview; native pilot writes are disabled")
    }
    guard let window, window.isVisible else { throw GuideError.stopped("A real visible owning native window is required") }
    return NativePilotCoordinator(engine: engine, window: window)
  }

  public func review(requestID: UUID, utm: URL? = nil,
                     unlockPayload: URL? = nil,
                     progress: (@Sendable (NativePilotProgress) -> Void)? = nil) async throws -> NativePilotReviewResult {
    guard !closed else { throw GuideError.stopped("Native pilot coordinator is permanently closed") }
    guard Self.buildMode == .experimentalPilot, let window, window.isVisible, owner == nil else {
      throw GuideError.stopped("Native pilot build, owning window and exclusive native review are required")
    }
    let selection = NativePilotSelection(utm: utm, unlockPayload: unlockPayload)
    let currentOwner = try NativePilotComposition.make(engine: engine, requestID: requestID,
      selection: selection, window: window, gate: .experimentalOptIn, progress: progress)
    owner = currentOwner
    defer { currentOwner.close(); owner = nil }
    guard let result = try await currentOwner.controller.confirm(requestID: requestID, selection: selection) else {
      return .declined
    }
    switch result {
    case .recoveryInspectionRequired(let outcome):
      return .recoveryInspectionRequired(attempts: outcome.attempts, reason: outcome.reason)
    case .installedAwaitingUserStartup: return .installedAwaitingUserStartup
    }
  }

  /// Invalidates an open native confirmation, never silently replays a request.
  public func close() {
    closed = true
    owner?.close()
    observers.removeAll()
  }
}
#endif
