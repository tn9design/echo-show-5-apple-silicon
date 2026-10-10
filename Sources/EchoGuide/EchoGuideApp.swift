import AppKit
import EchoGuideCore
import SwiftUI

@main struct EchoGuide: App {
  init() { NSApplication.shared.setActivationPolicy(.regular) }
  var body: some Scene {
    WindowGroup("EchoGuide") {
      GuideView().onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
    }
  }
}

@MainActor private struct OwningWindowCapture: NSViewRepresentable {
  let changed: @MainActor (NSWindow?) -> Void
  func makeNSView(context: Context) -> WindowCaptureView { WindowCaptureView(changed: changed) }
  func updateNSView(_ view: WindowCaptureView, context: Context) {}
}

@MainActor private final class WindowCaptureView: NSView {
  let changed: @MainActor (NSWindow?) -> Void
  init(changed: @escaping @MainActor (NSWindow?) -> Void) {
    self.changed = changed
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let owning = window
    Task { @MainActor in changed(owning) }
  }
}

private enum GuideStep: String, CaseIterable, Identifiable {
  case inspect = "Check your Mac"
  case prepare = "Prepare downloads"
  case workspace = "Linux workspace"
  case identify = "Identify the Echo"
  case recovery = "Recovery and backups"
  case install = "Installation"
  case diagnostics = "Troubleshooting"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .inspect: "desktopcomputer"
    case .prepare: "arrow.down.circle"
    case .workspace: "externaldrive"
    case .identify: "cable.connector"
    case .recovery: "shield.lefthalf.filled"
    case .install: "checkmark.circle"
    case .diagnostics: "doc.text.magnifyingglass"
    }
  }
}

@MainActor struct GuideView: View {
  @State private var owningWindow: NSWindow?
  @State private var nativeProgress: NativePilotProgress?
  @State private var nativeProgressGeneration: UUID?
  @State private var nativePilot: NativePilotCoordinator?
  private var experimentalPilot: Bool { NativePilotCoordinator.buildMode == .experimentalPilot }
  @State private var step: GuideStep = .inspect
  @State private var engine: WorkflowEngine?
  @State private var status = "Start with a read-only check of this Mac and its USB devices."
  @State private var session = "No session loaded."
  @State private var report = "Create a diagnostic preview before exporting."
  @State private var files = "Choose a destination for verified publisher downloads."
  @State private var busy = false
  @State private var operation = ""
  @State private var downloadTask: Task<Void, Never>?
  @State private var activeDownloadID: UUID?
  @State private var pendingApproval: ApprovalRequest?
  @State private var adbURL: URL?
  @State private var deviceSerial = ""
  @State private var fastbootCandidates: [FastbootCandidate] = []
  @State private var fastbootSerial = ""
  @State private var fastbootSupported = false
  @State private var guestIdentificationReady = false
  @State private var macUSBVisibility = "Not checked in this app session"
  @State private var recoveryDevices: [ADBDevice] = []
  @State private var verifiedRecoverySerial: String?
  @State private var guestConsoleReady = false
  @State private var workspaceRegistered = false
  @State private var guestPassword = ""
  @State private var backupProgress: BackupProgress?
  @State private var activeBackupID: UUID?
  @State private var poweredWait: PoweredWaitStatus?
  @State private var poweredWaitUnreadable = false
  @State private var startupPersonallyObserved = false
  @State private var startupAlreadyRecorded = false
  @State private var postInstallEnabled = false
  @State private var romConfigured = false
  @State private var backedUpForStaging = false
  @State private var installationReady = false
  @State private var postInstallOutcomes: [PostInstallCheck: PostInstallOutcome] = [:]

  var body: some View {
    NavigationSplitView {
      List(GuideStep.allCases, selection: $step) { item in
        Label(item.rawValue, systemImage: item.symbol).tag(item)
      }
      .navigationTitle("EchoGuide")
      .frame(minWidth: 210)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(step.rawValue).font(.largeTitle.bold())
          Text("First-generation Echo Show 5 · CHECKERS · Apple Silicon")
            .foregroundStyle(.secondary)
          if poweredWaitUnreadable {
            Label("Powered-wait evidence cannot be read. Keep wall power connected and inspect before any further attempt.", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          } else if let wait = poweredWait {
            GroupBox("Powered wait safety status") {
              VStack(alignment: .leading, spacing: 8) {
                Label(wait.guidance, systemImage: "powerplug.fill").foregroundStyle(.orange)
                Text("Recorded wait: \(wait.elapsedSeconds) of \(wait.requiredSeconds) seconds. Completion does not prove an unlock; recovery must be independently verified.")
                if !wait.complete {
                  Text("Do not disconnect wall power or start another attempt. An interrupted wait requires inspection.").font(.callout.bold())
                }
                Button("Refresh powered wait status") { refreshPoweredWait() }
              }.padding(8)
            }
          }
          if experimentalPilot {
            Label("EXPERIMENTAL PILOT SOURCE BUILD — native confirmations can authorize irreversible device changes and permanent damage. Fresh environment proof and matching prerequisites remain required.", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange).font(.callout.bold())
          }
          stageContent
          if pendingApproval != nil {
            Button("Review pending native approval…") { reviewPendingApproval() }
              .disabled(busy)
          }
          if busy {
            if let progress = nativeProgress {
              ProgressView(value: Double(progress.poweredWaitElapsedSeconds), total: Double(progress.poweredWaitRequiredSeconds))
              Text("Keep wall power connected. Powered wait: \(progress.poweredWaitElapsedSeconds) of \(progress.poweredWaitRequiredSeconds) seconds; \(progress.attempts) bounded attempt(s).")
              Text("Elapsed time is not unlock success. Compatible recovery must be independently verified.").font(.caption).foregroundStyle(.secondary)
            } else if let progress = backupProgress {
              VStack(alignment: .leading, spacing: 8) {
                Text("\(progress.partition ?? "Backup") · \(progress.stage.replacingOccurrences(of: "_", with: " "))")
                if progress.stage == "capturing", progress.expectedBytes > 0 {
                  ProgressView(value: Double(min(progress.transferredBytes, progress.expectedBytes)), total: Double(progress.expectedBytes))
                  Text("\(progress.transferredBytes.formatted()) of \(progress.expectedBytes.formatted()) bytes captured · verification pending")
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                  ProgressView("Checking backup evidence…")
                }
                Text("Verified partitions: \(progress.verifiedPartitions)")
                  .font(.caption).foregroundStyle(.secondary)
              }
            } else {
              ProgressView(operation)
            }
            if downloadTask != nil {
              Button("Cancel downloads") { if let activeDownloadID { engine?.cancelPublisherDownloads(operationID: activeDownloadID) } }
            }
          }
          Divider()
          Text(
            experimentalPilot ? "Experimental pilot source build. Native confirmations may authorize irreversible writes; results require independent verification. A timeout never proves an unlock." : "Experimental source preview. Preparation, recovery inspection, verified backups, and verified ROM copying are available as pilot integration. Unlock, wipes, installation, and reboot are unavailable in this preview; a timeout never proves an unlock."
          )
          .font(.footnote).foregroundStyle(.secondary)
          DisclosureGroup("Private local session details") {
            Text(session).font(.system(.caption, design: .monospaced))
              .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
          }
        }.padding(28)
      }
    }
    .frame(minWidth: 850, minHeight: 620)
    .background(OwningWindowCapture { owningWindow = $0 }.frame(width: 0, height: 0))
    .onDisappear { nativePilot?.close() }
    .task { initialize() }
    .onReceive(
      DistributedNotificationCenter.default().publisher(
        for: Notification.Name("org.echoguide.approvalRequested"))
    ) { _ in
      if !busy {
        NSApplication.shared.activate(ignoringOtherApps: true)
        reviewPendingApproval()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      if !busy { refresh() }
    }
  }

  @ViewBuilder private var stageContent: some View {
    switch step {
    case .inspect:
      Text(
        "Use the Echo’s wall power supply and a Micro-USB data cable. Seeing a USB device establishes visibility; bootloader and recovery checks establish compatibility."
      )
      GroupBox("Inspection result") { selectable(status) }
      Button("Inspect this Mac and USB") { inspect() }.disabled(busy || engine == nil)
      Text(
        "The guided USB backend requires macOS 27 and the pinned UTM 5.0.6. Earlier macOS versions can use preparation tools but cannot use this installer backend."
      )
      .font(.callout).foregroundStyle(.secondary)
    case .prepare:
      Text(
        "Download the pinned UTM, Debian installer, and CHECKERS ROM directly from their publishers. SHA-256 verification completes before a file is considered usable. No files are installed or executed."
      )
      GroupBox("Download progress") { selectable(files) }
      Button("Choose folder and prepare downloads…") { prepareDownloads() }.disabled(busy)
    case .workspace:
      Text(
        "Linux translation and the first USB assignment require a user action in UTM/macOS. Workspace creation is available as pilot integration; guest bootstrap is still being validated, so creation does not establish readiness."
      )
      Button("Create managed UTM workspace…") { prepareWorkspace() }.disabled(busy || engine == nil)
      Text("After creation, configure only the workspace recorded in this session. Then start it and complete Debian setup before guest authentication.").font(.callout)
      instruction(
        "1", "Enable installer input",
        "Before starting the app-owned VM, open Edit → Virtualization. Set Keyboard to Generic USB and Pointer to Generic Mouse, then Save. UTM’s scripting interface does not configure these devices. Confirm the Debian menu responds to arrow keys before continuing; a visible boot menu alone does not establish readiness."
      )
      instruction(
        "2", "Enable Linux translation",
        "In the app-owned UTM VM configuration, enable Rosetta translation for Linux. Do not change an unrelated VM."
      )
      instruction(
        "3", "Assign the Echo to UTM only when needed",
        "At the top right of the Mac menu bar, open the accessories icon. Select Android → Use with UTM. Leave your mouse, charger, and other accessories on This Mac."
      )
      instruction(
        "4", "Attach to the correct VM",
        "In UTM, open Virtual Machine → USB Devices and choose the Echo for the workspace identified by this session. A successful attachment still requires guest identity checks."
      )
      VStack(alignment: .leading, spacing: 8) {
        Button("Reconcile interrupted workspace creation…") { workspaceLifecycle(.reconcile) }
        Button("Start owned workspace…") { workspaceLifecycle(.start) }.disabled(!workspaceRegistered)
        Button("Gracefully stop owned workspace…") { workspaceLifecycle(.stop) }.disabled(!workspaceRegistered)
      }.disabled(busy || engine == nil)
      Text("These actions inspect or control only the workspace recorded by this session. Observed VM state does not prove guest or USB readiness. Reconciliation never silently creates a replacement; stop requests are graceful, never forced.")
        .font(.caption).foregroundStyle(.secondary)
      GroupBox("Experimental pilot: authenticate the Linux guest") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Finish Debian setup with the account named user and the SSH server installed. Enter that temporary Linux account password below. The app logs in through the app-owned serial console, obtains the guest host key, and installs this workspace’s public SSH key for user. Graphical-display login alone is insufficient. These actions do not write to the Echo.")
          Toggle("The user account and SSH server setup are complete", isOn: $guestConsoleReady)
          SecureField("Temporary Linux user password", text: $guestPassword)
            .textFieldStyle(.roundedBorder).disabled(busy)
          Text("The password is used in memory for this action, cleared from the field immediately, and never saved to the session or diagnostics. Re-enter it for another action.")
            .font(.caption).foregroundStyle(.secondary)
          Button("Bootstrap owned guest SSH…") { bootstrapGuest() }
            .disabled(busy || engine == nil || !workspaceRegistered || !guestConsoleReady || guestPassword.isEmpty)
          Button("Validate owned guest and original client…") { validateGuest() }
            .disabled(busy || engine == nil || !workspaceRegistered || !guestConsoleReady || guestPassword.isEmpty)
          Text("For validation, choose the original publisher fastboot binary. The app uses its bundled, hash-verified protocol helper and checks the binary’s pinned hash before an offline test; it does not contact the Echo.")
            .font(.caption).foregroundStyle(.secondary)
          Text("Successful trust acquisition is separate from Linux translation, client validation, and USB readiness. Do not treat it as an installation prerequisite pass.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(8)
      }
      GroupBox("Workspace result") { selectable(status) }
      Link(
        "Open the installation guide",
        destination: URL(
          string:
            "https://github.com/tn9design/echo-show-5-apple-silicon/blob/main/docs/install-guide.md"
        )!)
    case .identify:
      Text("Keep the Echo’s wall power connected. Put it into FASTBOOT using the supported device guide, and connect its Micro-USB data cable. This screen performs read-only checks; it does not unlock the Echo.")
      instruction("1", "Assign only the Echo", "In the Mac menu bar’s Virtual Machine Accessories icon, choose Android → Use with UTM. In UTM, open Virtual Machine → USB Devices and attach it to this session’s workspace. Leave unrelated accessories on This Mac.")
      GroupBox("Separate connection evidence") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Visible to this Mac: \(macUSBVisibility)")
          Text("Assigned to Linux workspace: \(fastbootCandidates.isEmpty ? "not established by guest enumeration" : "fastboot candidates observed; choose one below")")
          Text("Supported device/build: \(fastbootSupported ? "verified for the selected Echo" : "not verified")")
          Text("Recovery compatibility: checked separately in Recovery and backups.")
        }.padding(8)
      }
      Button("List fastboot devices in owned Linux workspace") { discoverFastboot() }
        .disabled(busy || engine == nil || !guestIdentificationReady)
      Picker("Selected fastboot device", selection: $fastbootSerial) {
        Text("Choose a device…").tag("")
        ForEach(fastbootCandidates, id: \.serial) { candidate in Text(candidate.serial).tag(candidate.serial) }
      }.disabled(busy || fastbootCandidates.isEmpty)
        .onChange(of: fastbootSerial) { _, _ in fastbootSupported = false }
      Button("Verify selected Echo and exact bootloader build") { identifyFastboot() }
        .disabled(busy || engine == nil || fastbootSerial.isEmpty || !guestIdentificationReady)
      Text("If guest enumeration is empty, check the data cable and accessory assignment. A USB name or fastboot serial alone does not prove compatibility. Complete guest validation first if listing is disabled.").font(.caption).foregroundStyle(.secondary)
      Text(!guestIdentificationReady ? "Next: return to Linux workspace and validate the owned guest and original client." : fastbootCandidates.isEmpty ? "Next: list fastboot devices after assigning the Echo to the owned workspace." : fastbootSerial.isEmpty ? "Next: explicitly select the Echo from the list." : !fastbootSupported ? "Next: verify the selected Echo’s exact bootloader build." : (experimentalPilot ? "Supported identity verified. A native experimental confirmation is required before any unlock attempt." : "Supported identity verified. This preview can review an unlock request but cannot perform an unlock."))
        .font(.callout)
      Button(experimentalPilot ? "Request native experimental unlock confirmation…" : "Review unlock request in source preview…") { requestApproval(.unlock) }
        .disabled(busy || engine == nil || !fastbootSupported)
      Text(experimentalPilot ? "Continue to Recovery and backups only when compatible TWRP is independently verified. A completed attempt or timeout is never proof of unlock." : "Continue to Recovery and backups only when the Echo independently shows compatible TWRP. A request review does not unlock or enter recovery.").font(.caption).foregroundStyle(.secondary)
      GroupBox("Identification result") { selectable(status) }
    case .recovery:
      Text(
        "If the Echo already shows TWRP, tap Keep Read Only at its first prompt. Select ADB, list devices, choose the Echo, then verify recovery below. Verification must succeed before backups; do not wipe anything."
      )
      Text(
        "Required backups: boot, installed recovery, system, userdata, and metadata. The engine must discover named partitions and compare source/host sizes and hashes before installation. Use the backup action below to capture and verify them. This integration is not yet live-device validated."
      )
      Text(
        "These are pre-ROM backups after unlocking; recovery includes TWRP. They do not undo the earlier unlock step, and automatic restoration remains unavailable."
      )
      .foregroundStyle(.secondary)
      Button(adbURL == nil ? "Select platform-tools adb…" : "Change selected adb…") {
        adbURL = selectFile(
          message: "Select the adb executable from your verified Android platform-tools folder.")
        recoveryDevices = []
        deviceSerial = ""
      }.disabled(busy)
      Button("List connected recovery devices") { listRecoveryDevices() }
        .disabled(busy || adbURL == nil)
      Picker("Selected recovery device", selection: $deviceSerial) {
        Text("Choose a device…").tag("")
        ForEach(recoveryDevices, id: \.serial) { device in
          Text("\(device.serial) · \(device.state) · \(device.product ?? "unknown product")")
            .tag(device.serial).disabled(!device.isRecoveryCandidate)
        }
      }
      .disabled(busy || recoveryDevices.isEmpty)
      .onChange(of: deviceSerial) { _, _ in verifiedRecoverySerial = nil }
      Text(
        "Choose explicitly from the connected devices. Recovery visibility is only a candidate; verification still checks the exact selected device and compatible TWRP. Unauthorized or other-mode devices cannot be selected."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(adbURL == nil ? "Next: select the platform-tools ADB executable." : recoveryDevices.isEmpty ? "Next: list connected recovery devices." : deviceSerial.isEmpty ? "Next: explicitly select the Echo." : verifiedRecoverySerial != deviceSerial ? "Next: verify the selected recovery." : "Next: choose a private backup destination and capture all required partitions.")
        .font(.callout)
      HStack {
        Button("Verify this recovery") { verifyRecovery() }
          .disabled(busy || adbURL == nil || deviceSerial.isEmpty || engine == nil)
        Button("Back up and verify partitions…") { backup() }
          .disabled(busy || adbURL == nil || engine == nil || verifiedRecoverySerial != deviceSerial || deviceSerial.isEmpty)
      }
      Button("Reinspect interrupted read-only operation") { recoverInterruptedReads() }
        .disabled(busy || adbURL == nil || deviceSerial.isEmpty || engine == nil)
      Text("Reinspection can abandon an interrupted backup or recovery check after verifying the selected recovery again. It never resumes unlocks, wipes, installation, or VM creation.")
        .font(.caption).foregroundStyle(.secondary)
      GroupBox("Recovery / backup result") { selectable(status) }
      Button("Refresh session status") { refresh() }.disabled(busy || engine == nil)
    case .install:
      Text(
        experimentalPilot ? "After compatible recovery and verified backups, select and stage the pinned ROM below. Native confirmation may authorize erasure and installation in this experimental pilot build." : "After compatible recovery and verified backups, select and stage the pinned ROM below. Then review the exact erase/install request. This source preview cannot execute it."
      )
      GroupBox("Prepare the pinned ROM after verified backups") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Choose the publisher’s LineageOS 18.1 CHECKERS v0.7 ZIP. EchoGuide checks its exact size and hash before copying it to recovery.")
          Button("Choose and verify pinned ROM…") { configureROM() }
            .disabled(busy || engine == nil || !backedUpForStaging)
          Button("Copy ROM and verify device hash") { stageROM() }
            .disabled(busy || engine == nil || !backedUpForStaging || !romConfigured)
          Text(!backedUpForStaging ? "Next: complete recovery verification and all required backups." : !romConfigured ? "Next: choose and verify the pinned publisher ROM." : !installationReady ? "Next: copy the ROM and independently verify its device-side hash." : (experimentalPilot ? "Pinned ROM verified on the device; native experimental installation confirmation may be requested." : "Pinned ROM verified on the device; the native source-preview request may be reviewed."))
            .font(.caption).foregroundStyle(.secondary)
        }.padding(8)
      }
      Button(experimentalPilot ? "Request native experimental installation confirmation…" : "Review installation request in source preview…") { requestApproval(.install) }
        .disabled(busy || engine == nil || !installationReady)
      GroupBox("After a verified installation") {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "During Android setup, leave Update Lineage Recovery unchecked to retain TWRP. A dark screen may be asleep; do not assume it is a failed boot."
          )
          Text("These saved outcomes are your observations, not automated hardware verification. Leave anything you have not checked as Not checked.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("I personally reached Android setup / home screen", isOn: $startupPersonallyObserved)
            .disabled(!postInstallEnabled || busy || startupAlreadyRecorded)
          Button("Record my Android startup confirmation") { confirmStartup() }
            .disabled(!startupPersonallyObserved || !postInstallEnabled || engine == nil || busy || startupAlreadyRecorded)
          ForEach(PostInstallCheck.allCases) { check in
            Picker(check.label, selection: Binding(
              get: { postInstallOutcomes[check] ?? .notChecked },
              set: { outcome in recordPostInstall(check, outcome: outcome) }
            )) {
              ForEach(PostInstallOutcome.allCases) { outcome in
                Text(outcome.label).tag(outcome)
              }
            }.disabled(!postInstallEnabled || engine == nil || busy)
          }
          if !postInstallEnabled {
            Text("Hardware observations can be saved after installation is verified.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }.padding(8)
      }
      GroupBox("Latest result") { selectable(status) }
    case .diagnostics:
      Text(
        "Preview the engine’s redacted report before saving it. Backups, credentials, full serials, network addresses, and private paths must stay private."
      )
      Button("Create redacted diagnostic preview") { previewReport() }.disabled(
        busy || engine == nil)
      GroupBox("Export preview") { selectable(report) }
      Text("The saved file will contain exactly this redacted preview.").font(.caption).foregroundStyle(.secondary)
      Button("Save this report…") { exportReport() }
        .disabled(report == "Create a diagnostic preview before exporting.")
    }
  }

  private func selectable(_ value: String) -> some View {
    Text(value).font(.system(.callout, design: .monospaced))
      .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
  }

  private func instruction(_ number: String, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number).font(.headline).padding(8).background(.quaternary, in: Circle())
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.headline)
        Text(text)
      }
    }
  }

  private func initialize() {
    do {
      let root = try AppLaunchOptions.stateRoot(arguments: Array(CommandLine.arguments.dropFirst()))
      engine = try WorkflowEngine(root: root)
      refresh()
    } catch { status = "Unable to open the local session: \(error.localizedDescription)" }
  }

  private func selectFile(message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
  }

  private func prepareWorkspace() {
    guard let engine,
      let utm = selectFile(message: "Select the verified UTM 5.0.6 application."),
      let iso = selectFile(message: "Select the pinned Debian ARM64 netinst ISO.")
    else { return }
    busy = true
    operation = "Preparing app-owned Linux workspace…"
    Task {
      do {
        let id = try await engine.prepareWorkspace(utm: utm, iso: iso)
        status =
          "Managed workspace recorded: \(id). Complete the guided guest setup and translation checks; creation alone does not prove readiness."
      } catch { status = "Workspace preparation stopped: \(error.localizedDescription)" }
      refresh()
      busy = false
    }
  }

  private enum WorkspaceAction { case reconcile, start, stop }

  private func bootstrapGuest() {
    guard guestConsoleReady, !guestPassword.isEmpty, let engine else { return }
    let password = guestPassword
    guestPassword = ""
    guard let utm = selectFile(message: "Select verified UTM. The app logs into the owned Debian serial console as user and installs the workspace public SSH key.") else { return }
    busy = true
    operation = "Acquiring guest trust through the owned serial channel…"
    guestConsoleReady = false
    Task {
      do {
        let evidence = try await engine.bootstrapOwnedGuest(utm: utm, password: password)
        status = "Guest host trust acquired through the owned serial channel.\nOwned VM: \(evidence.trust.ownedVMID.uuidString)\nGuest address (private): \(evidence.address)\nWorkspace public SSH key authorized: \(evidence.clientAuthorized ? "yes" : "no")\nTranslation, original client, and USB readiness are not yet verified."
      } catch { status = "Guest bootstrap stopped: \(error.localizedDescription). Inspect the owned serial console before retrying; interrupted key setup is not replayed automatically." }
      refresh()
      busy = false
    }
  }

  private func validateGuest() {
    guard guestConsoleReady, !guestPassword.isEmpty, let engine else { return }
    let password = guestPassword
    guestPassword = ""
    guard let utm = selectFile(message: "Select verified UTM. The app authenticates the owned Debian serial console as user."),
          let fastboot = selectFile(message: "Select the original publisher Linux fastboot binary from the CHECKERS package; its pinned hash will be checked.") else { return }
    busy = true
    operation = "Verifying guest trust, translation, and offline client protocol…"
    guestConsoleReady = false
    Task {
      do {
        let mock = try GuestAdapter.bundledValidationHelper()
        let readiness = try await engine.validateOwnedGuest(utm: utm, fastboot: fastboot, mockScript: mock, password: password)
        status = try encoded(readiness) + "\nThis is guest/client validation only. Echo USB assignment and exact device compatibility still require independent checks."
      } catch { status = "Guest validation stopped: \(error.localizedDescription). Inspect the owned serial console and session before another attempt." }
      refresh()
      busy = false
    }
  }

  private func workspaceLifecycle(_ action: WorkspaceAction) {
    guard let engine,
          let utm = selectFile(message: "Select the verified UTM application to inspect this session’s owned workspace.") else { return }
    busy = true
    operation = "Checking app-owned workspace…"
    Task {
      do {
        switch action {
        case .reconcile:
          switch try await engine.reconcileWorkspace(utm: utm) {
          case .absent:
            status = "No matching owned VM was found. Creation intent remains recorded; no replacement was created. Inspect the session before proceeding."
          case .owned(let info):
            status = "Owned workspace reconciled. Observed VM state only; guest and USB readiness still need independent verification.\n" + (try encoded(info))
          }
        case .start:
          let info = try await engine.startOwnedWorkspace(utm: utm)
          status = "Owned workspace start result. Observed VM state only; guest and USB readiness are unverified.\n" + (try encoded(info))
        case .stop:
          let info = try await engine.stopOwnedWorkspace(utm: utm)
          status = "Graceful stop request result. Observed VM state only; a stop request does not guarantee the guest has stopped.\n" + (try encoded(info))
        }
      } catch { status = "Workspace lifecycle action stopped: \(error.localizedDescription)" }
      refresh()
      busy = false
    }
  }

  private func verifyRecovery() {
    guard let engine, let adbURL else { return }
    let serial = deviceSerial
    busy = true
    operation = "Verifying selected recovery identity…"
    Task {
      do {
        try await engine.verifyRecovery(adb: adbURL, serial: serial)
        verifiedRecoverySerial = serial
        status =
          "Selected recovery passed the engine’s identity checks. Backups must still complete before installation."
      } catch { status = "Recovery verification stopped: \(error.localizedDescription)" }
      refresh()
      busy = false
    }
  }

  private func listRecoveryDevices() {
    guard let adbURL else { return }
    busy = true
    operation = "Reading connected devices…"
    deviceSerial = ""
    verifiedRecoverySerial = nil
    recoveryDevices = []
    Task {
      do {
        recoveryDevices = try await RecoveryDeviceDiscovery(runner: ProcessRunner(), adbPath: adbURL.path).devices()
        status = recoveryDevices.isEmpty
          ? "No ADB devices found. Check wall power, data cable, and recovery mode."
          : "Choose a recovery candidate explicitly, then verify it. Listing alone does not prove compatibility."
      } catch { status = "Device discovery stopped: \(error.localizedDescription)" }
      busy = false
    }
  }

  private func recoverInterruptedReads() {
    guard let engine, let adbURL, !deviceSerial.isEmpty else { return }
    let serial = deviceSerial
    busy = true
    operation = "Reinspecting selected recovery after interruption…"
    Task {
      do {
        try await engine.recoverInterruptedReads(adb: adbURL, serial: serial)
        verifiedRecoverySerial = serial
        status = "Recovery reinspected. Eligible interrupted reads were abandoned; no device-writing operation was replayed."
      } catch { status = "Interrupted-read reinspection stopped: \(error.localizedDescription)" }
      refresh()
      busy = false
    }
  }

  private func backup() {
    guard let engine, let adbURL else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.message =
      "Choose a private backup destination with enough free space. Backups may contain account credentials; never include them in a public report."
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    busy = true
    operation = "Capturing and verifying partition backups…"
    let backupID = UUID()
    activeBackupID = backupID
    backupProgress = nil
    Task {
      do {
        status = try encoded(await engine.backup(adb: adbURL, destination: folder) { progress in
          Task { @MainActor in
            guard activeBackupID == backupID else { return }
            backupProgress = progress
          }
        })
      } catch {
        status = "Backup stopped: \(error.localizedDescription)"
      }
      activeBackupID = nil
      backupProgress = nil
      refresh()
      busy = false
    }
  }

  private func encoded<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private func refresh() {
    guard let engine else { return }
    do {
      let record = try engine.status()
      session = try encoded(record)
      pendingApproval = record.pendingApproval
      workspaceRegistered = record.vmID != nil
      if record.phase != .identified || record.device?.serial != fastbootSerial || record.device?.product != engine.profile.product || record.device?.lkBuild != engine.profile.lkBuild { fastbootSupported = false }
      guestIdentificationReady = record.guest?.ready == true && record.backupManifest == nil && [.workspace, .identified, .inspectionRequired].contains(record.phase)
      backedUpForStaging = record.phase == .backedUp && record.backupManifest != nil
      romConfigured = record.configuredROMPath != nil
      installationReady = backedUpForStaging && record.stagedROMHash == (try? engine.profile.artifact(named: "lineage-18.1-20260904-UNOFFICIAL-checkers.zip"))?.sha256
      postInstallEnabled = record.phase == .installed || record.phase == .finished
      startupPersonallyObserved = record.startupConfirmed
      startupAlreadyRecorded = record.startupConfirmed
      postInstallOutcomes = Dictionary((record.postInstallObservations ?? []).map { ($0.check, $0.outcome) }, uniquingKeysWith: { _, newest in newest })
    } catch { status = "Session check stopped: \(error.localizedDescription)" }
    refreshPoweredWait()
  }

  private func discoverFastboot() {
    guard let engine, let utm = selectFile(message: "Select the verified UTM application. EchoGuide will freshly verify this session’s exact owned VM is running before listing fastboot devices.") else { return }
    busy = true; fastbootSupported = false; fastbootCandidates = []; fastbootSerial = ""
    operation = "Rechecking guest readiness and listing fastboot devices…"
    Task {
      defer { busy = false; refresh() }
      do {
        fastbootCandidates = try await engine.discoverFastbootDevices(utm: utm)
        status = fastbootCandidates.isEmpty ? "No fastboot devices observed in the owned guest. Check FASTBOOT mode, the data cable, and accessory assignment." : "Guest enumeration completed. Explicitly select the Echo, then verify its exact build."
      } catch { status = "Guest enumeration stopped: \(error.localizedDescription). Visibility remains unknown." }
    }
  }

  private func identifyFastboot() {
    guard let engine, let utm = selectFile(message: "Select the verified UTM application for a fresh owned-workspace check before and after read-only Echo identification.") else { return }
    let selected = fastbootSerial
    busy = true; fastbootSupported = false
    operation = "Verifying the selected Echo’s product, lock state, and exact bootloader…"
    Task {
      defer { busy = false; refresh() }
      do {
        let identity = try await engine.identifyFastbootDevice(utm: utm, serial: selected)
        fastbootSupported = true
        status = "Supported identity verified: \(identity.product), bootloader \(identity.lkBuild). This read-only check did not unlock or enter recovery."
      } catch { status = "Compatibility verification stopped: \(error.localizedDescription). No unlock was attempted." }
    }
  }

  private func configureROM() {
    guard let engine, let file = selectFile(message: "Select the publisher LineageOS 18.1 CHECKERS v0.7 ZIP. Its pinned size and SHA-256 will be verified.") else { return }
    busy = true
    operation = "Verifying the selected ROM against the pinned compatibility profile…"
    Task {
      defer { busy = false; refresh() }
      do {
        try await engine.configureROM(localROM: file)
        status = "Pinned ROM verified locally. Copy and independently verify it on the device next."
      } catch { status = "ROM selection stopped: \(error.localizedDescription)" }
    }
  }

  private func stageROM() {
    guard let engine else { return }
    busy = true
    operation = "Checking backups, copying the pinned ROM, and independently verifying the device hash…"
    Task {
      defer { busy = false; refresh() }
      do {
        let receipt = try await engine.stageConfiguredROM()
        status = "Device-side ROM verified: \(receipt.bytes.formatted()) bytes; SHA-256 \(receipt.sha256). No wipe or installation has run."
      } catch { status = "ROM staging stopped: \(error.localizedDescription). Installation prerequisites must be rechecked." }
    }
  }

  private func refreshPoweredWait() {
    guard let engine else { return }
    do {
      poweredWait = try engine.poweredWaitStatus()
      poweredWaitUnreadable = false
    } catch {
      poweredWait = nil
      poweredWaitUnreadable = true
    }
  }

  private func inspect() {
    guard let engine else { return }
    busy = true
    operation = "Inspecting this Mac and USB…"
    Task {
      do {
        let result = try await engine.inspect()
        macUSBVisibility = !result.usbInspectionAvailable ? "inspection unavailable" : result.devices.isEmpty ? "no candidates observed; VM assignment can hide them here" : "USB candidates observed; IDs alone do not prove identity"
        status =
          "Mac: \(result.architecture), macOS \(result.macOS)\n"
          + (result.writingBackendSupported
            ? "Host supports the pinned USB backend.\n"
            : "Host does not support the device-writing backend.\n")
          + (result.usbInspectionAvailable
            ? "USB inspection completed.\n"
            : "USB inspection unavailable; device visibility is unknown.\n")
          + (result.devices.isEmpty
            ? "No USB candidates found. Check wall power and the data cable; VM-assigned devices may be absent from this Mac view.\n"
            : "USB devices visible: "
              + result.devices.map {
                "\($0.name) (\(String(format: "%04X", $0.vendorID)):\(String(format: "%04X", $0.productID)))"
              }.joined(separator: ", ") + "\nUSB IDs do not prove CHECKERS compatibility.\n")
          + "Next: \(result.nextAction)"
      } catch { status = "Inspection stopped: \(error.localizedDescription)" }
      refresh()
      busy = false
    }
  }

  private func requestApproval(_ action: WriteAction) {
    guard let engine else { return }
    do {
      let request = try engine.requestApproval(action: action)
      pendingApproval = request
      status = "Approval requested. Review the native confirmation; no device command has run."
      refresh()
    } catch {
      status = "Request stopped: \(error.localizedDescription)"
      refresh()
    }
  }

  private func reviewPendingApproval() {
    refresh()
    guard let request = pendingApproval else { return }
    presentApproval(request)
  }

  private func presentApproval(_ request: ApprovalRequest) {
    guard let engine else { return }
    if experimentalPilot { presentPilotApproval(request); return }
    do {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = request.action == .unlock
        ? "Review experimental bootloader unlock" : "Review erasure and LineageOS installation"
      let action = request.action == .unlock
        ? "Attempt the reviewed bootloader unlock. Permanent device damage is possible. Keep wall power connected during the attempt and for five minutes afterward."
        : "Erase data, system, and cache, install the pinned LineageOS ROM, then reboot only after verified installation. Stock apps and settings are removed; verified backups remain private on your Mac."
      alert.informativeText = "Device: \(request.device.product)\nSerial: \(request.device.serial)\nBootloader: \(request.device.lkBuild)\nRecovery: \(request.device.recoveryVersion ?? "not verified")\n\n\(action)\n\nApproval expires five minutes after \(request.createdAt.formatted(date: .omitted, time: .standard)). Changed device or prerequisites invalidate it.\nSession: \(request.sessionID.uuidString)\nEvidence fingerprint: \(request.prerequisitesDigest)\n\nUnlock, wipes, installation, and reboot are disabled in this source preview; reviewing this request cannot enable them."
      alert.addButton(withTitle: "Close preview review")
      alert.addButton(withTitle: "Decline pending request")
      if alert.runModal() == .alertSecondButtonReturn {
        try engine.rejectApproval(requestID: request.id)
        status = "Request declined; no operation authorized."
      } else {
        status = "Preview reviewed; no approval was recorded and no device operation ran."
      }
      refresh()
    } catch {
      status = "Approval stopped: \(error.localizedDescription)"
      refresh()
    }
  }

  private func presentPilotApproval(_ request: ApprovalRequest) {
    guard let engine, !busy else { return }
    do {
      let current = try engine.status()
      guard current.pendingApproval?.id == request.id else {
        status = "The pending request changed. Refresh and review the current request; no operation ran."
        refresh(); return
      }
    } catch { status = "Native request inspection stopped: \(error.localizedDescription)"; return }
    var selectedUTM: URL?
    var selectedPayload: URL?
    if request.action == .unlock {
      guard let utm = selectFile(message: "Experimental unlock: select the verified UTM application for fresh exact-workspace ownership checks."),
            let payload = selectFile(message: "Experimental unlock: select the original developer’s pinned CHECKERS unlock payload. The backend verifies its exact hash before native confirmation.") else { return }
      selectedUTM = utm; selectedPayload = payload
    }
    do {
      let coordinator = try NativePilotCoordinator.make(engine: engine, window: owningWindow)
      nativePilot = coordinator
      let generation = UUID()
      nativeProgressGeneration = generation; nativeProgress = nil
      busy = true
      operation = "Experimental native review and checked operation. Keep Echo wall power connected; an ambiguous result requires inspection."
      Task {
        defer { nativePilot = nil; nativeProgressGeneration = nil; nativeProgress = nil; busy = false; refresh() }
        do {
          let result = try await coordinator.review(requestID: request.id, utm: selectedUTM, unlockPayload: selectedPayload, progress: { tick in
            Task { @MainActor in
              guard nativeProgressGeneration == generation,
                tick.poweredWaitElapsedSeconds >= (nativeProgress?.poweredWaitElapsedSeconds ?? 0) else { return }
              nativeProgress = tick
            }
          })
          switch result {
          case .declined:
            status = "Native request declined; no operation was authorized."
          case .recoveryInspectionRequired(let attempts, let reason):
            status = "Recovery inspection required after \(attempts) bounded attempt(s): \(reason). This is not unlock success. Keep wall power connected and independently verify compatible TWRP before any further write."
            step = .recovery
          case .installedAwaitingUserStartup:
            status = "Installation evidence verified. Android setup/home-screen startup still requires your personal confirmation; individual hardware checks remain unverified."
            step = .install
          }
        } catch { status = "Experimental native operation stopped: \(error.localizedDescription). Inspect saved state; do not replay an interrupted write." }
      }
    } catch { status = "Native experimental review unavailable: \(error.localizedDescription)" }
  }

  private func previewReport() {
    guard let engine else { return }
    do { report = try encoded(engine.diagnosticReport()) } catch {
      status = "Report stopped: \(error.localizedDescription)"
    }
  }

  private func recordPostInstall(_ check: PostInstallCheck, outcome: PostInstallOutcome) {
    guard let engine else { return }
    do {
      try engine.recordPostInstallObservation(check: check, outcome: outcome)
      status = "Your \(check.label) observation was saved: \(outcome.label). Other checks remain separate."
      refresh()
    } catch { status = "Observation was not saved: \(error.localizedDescription)" }
  }

  private func confirmStartup() {
    guard let engine else { return }
    do {
      try engine.confirmStartup()
      status =
        "Your confirmation of Android startup was recorded. Other hardware checks remain separate."
      refresh()
    } catch { status = "Startup confirmation stopped: \(error.localizedDescription)" }
  }

  private func exportReport() {
    let preview = report
    guard preview != "Create a diagnostic preview before exporting." else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "echoguide-diagnostic.json"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do { try Data(preview.utf8).write(to: destination, options: .atomic) } catch {
      status = "Export stopped: \(error.localizedDescription)"
    }
  }

  private func prepareDownloads() {
    guard let engine else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    panel.message = "Choose where to save pinned UTM, Debian ARM64 ISO, and CHECKERS ROM downloads (about 1.5 GB). The shared engine verifies every file; no software is installed."
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    do {
      let job = try engine.startPublisherDownloads(in: folder)
      activeDownloadID = job.id
      busy = true; operation = "Preparing publisher downloads…"
      downloadTask = Task {
        defer { downloadTask = nil; activeDownloadID = nil; busy = false; refresh() }
        do {
          while true {
            let state = try engine.status()
            guard let current = state.operations.first(where: { $0.id == job.id }) else { throw GuideError.stopped("Download operation disappeared; inspect the session") }
            if let progress = state.downloadProgress {
              files = "\(progress.artifact ?? "Publisher preparation") · \(progress.stage)\n\(progress.receivedBytes.formatted()) bytes received" + (progress.expectedBytes.map { " of \($0.formatted())" } ?? "") + "\nVerified files: \(progress.verifiedFiles)"
            }
            if current.completedAt != nil { break }
            try await Task.sleep(for: .milliseconds(200))
          }
          try await engine.waitForPublisherDownloads(operationID: job.id)
          files += "\nVerified downloads ready. The Linux workspace still needs preparation."
        } catch {
          files += "\nStopped: \(error.localizedDescription). Previously verified files were retained; no workspace readiness was established."
        }
      }
    } catch { files = "Preparation stopped: \(error.localizedDescription)" }
  }
}
