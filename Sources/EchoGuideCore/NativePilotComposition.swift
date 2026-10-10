#if canImport(AppKit)
import AppKit
import Foundation

private final class NativePilotObservers: @unchecked Sendable {
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
private final class NativePilotSheet {
  weak var window: NSWindow?
  let alert: NSAlert
  init(window: NSWindow, alert: NSAlert) { self.window = window; self.alert = alert }
  func cancel() {
    if let window, window.attachedSheet === alert.window {
      window.endSheet(alert.window, returnCode: .cancel)
    }
  }
}

@MainActor
final class NativePilotOwner {
  let controller: NativeApprovalController
  private weak var window: NSWindow?
  private let observers = NativePilotObservers()
  init(controller: NativeApprovalController, window: NSWindow) {
    self.controller = controller; self.window = window
    for name in [NSWindow.willCloseNotification, NSApplication.willTerminateNotification] {
      let object: AnyObject? = name == NSWindow.willCloseNotification ? window : nil
      observers.add(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.close() }
      })
    }
  }
  func close() {
    controller.invalidateForClosure()
    if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel) }
    observers.removeAll()
  }
}

@MainActor
enum NativePilotComposition {
  static func summaryText(_ summary: NativeApprovalSummary) -> String {
    let action = summary.action == .unlock
      ? "Attempt the reviewed experimental unlock. Permanent device damage is possible. Keep wall power connected during the attempt and for five minutes afterward. Recovery must be independently verified."
      : "Erase data, system, and cache, install the pinned LineageOS ROM, save the recovery log, and reboot only after verified installation. Stock apps and settings are removed; verified backups remain on this Mac."
    return "Device: \(summary.device.product)\nSerial: \(summary.device.serial)\nBootloader: \(summary.device.lkBuild)\nRecovery: \(summary.device.recoveryVersion ?? "not verified")\n\n\(action)\n\nExpires: \(summary.expiresAt.formatted())\nArtifact SHA-256: \(summary.pinnedArtifactSHA256)\nEvidence: \(summary.evidenceFingerprint)\nSession: \(summary.sessionID.uuidString)\nUTM: \(summary.selection.utm?.path ?? "none; installation uses host ADB")\nPayload: \(summary.selection.unlockPayload?.path ?? "none; configured ROM staging is checked independently")"
  }

  /// No app entry point calls this factory. An explicit internal experimental
  /// opt-in is required; wider release evidence is a separate promotion decision.
  static func make(engine: WorkflowEngine, requestID: UUID, selection: NativePilotSelection,
                   window: NSWindow?, gate: NativePilotGate = .disabled,
                   progress: (@Sendable (NativePilotProgress) -> Void)? = nil) throws -> NativePilotOwner {
    guard gate == .experimentalOptIn else { throw GuideError.stopped("Native pilot composition is disabled") }
    let state = try engine.status()
    guard let request = state.pendingApproval, request.id == requestID else {
      throw GuideError.stopped("Native pilot request is missing or changed")
    }
    let transport: (any UnlockTransport)?
    let environment: @Sendable (SessionRecord) async throws -> NativePilotEnvironmentProof
    if request.action == .unlock {
      guard let saved = state.guest, saved.ready, state.vmID == saved.vmID.uuidString,
        !saved.hostKeyFingerprint.isEmpty, engine.runner is any TimedCommandRunning,
        let utm = selection.utm, utm.isFileURL, utm.pathExtension == "app",
        state.phase == .identified, let payload = selection.unlockPayload else {
        throw GuideError.stopped("Unlock composition requires identified mode, owned Linux baseline, UTM and pinned payload")
      }
      let guest = try GuestAdapter(runner: engine.runner, ownedVMID: saved.vmID,
        credentialsDirectory: engine.store.root.appendingPathComponent("guest-" + saved.vmID.uuidString),
        address: saved.address, username: state.guestUsername ?? "user")
      transport = GuestUnlockTransport(guest: guest, payload: payload)
      let prover = NativePilotEnvironmentProver(engine: engine, utm: utm)
      environment = { try await prover.prove(session: $0) }
    } else {
      guard state.phase == .backedUp, state.adbPath != nil, state.configuredROMPath != nil,
        state.backupManifest != nil, state.stagedROMHash == (try engine.profile.artifact(named: ROMStagingAdapter.filename).sha256),
        selection.unlockPayload == nil, selection.utm == nil else {
        throw GuideError.stopped("Installation composition requires configured ADB, ROM, backups and staging; no Linux workspace selection")
      }
      transport = nil
      environment = { _ in NativePilotEnvironmentProof(host: try await engine.inspect(), guest: nil) }
    }
    guard let window else { throw GuideError.stopped("A real owning native window is required") }
    let dispatcher = NativePilotDispatcher(engine: engine, gate: gate,
      environment: environment, unlockTransport: transport, progress: progress)
    let controller = NativeApprovalController(engine: engine, gate: gate, presenter: { [weak window] summary in
      guard let window else { throw GuideError.stopped("Native owning window closed") }
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = summary.action == .unlock ? "Confirm experimental Echo unlock" : "Confirm erasure and LineageOS installation"
      alert.informativeText = summaryText(summary)
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: summary.action == .unlock ? "Attempt unlock; accept permanent damage risk" : "Erase and install LineageOS")
      alert.buttons.first?.keyEquivalent = "\r"
      alert.buttons.last?.keyEquivalent = ""
      let sheet = NativePilotSheet(window: window, alert: alert)
      return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          if Task.isCancelled { continuation.resume(returning: .cancel); return }
          alert.beginSheetModal(for: window) { response in
            continuation.resume(returning: response == .alertSecondButtonReturn ? .confirm : .cancel)
          }
        }
      } onCancel: {
        Task { @MainActor in sheet.cancel() }
      }
    }, dispatch: { confirmedID, confirmedSelection, lease in
      guard confirmedID == requestID, confirmedSelection == selection else {
        throw GuideError.stopped("Native selection binding changed")
      }
      return try await dispatcher.dispatch(nativeConfirmedRequestID: confirmedID, nativeLease: lease)
    })
    return NativePilotOwner(controller: controller, window: window)
  }
}
#endif
