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

private enum GuideStep: String, CaseIterable, Identifiable {
  case inspect = "Check your Mac"
  case prepare = "Prepare downloads"
  case workspace = "Linux workspace"
  case recovery = "Recovery and backups"
  case install = "Installation"
  case diagnostics = "Troubleshooting"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .inspect: "desktopcomputer"
    case .prepare: "arrow.down.circle"
    case .workspace: "externaldrive"
    case .recovery: "shield.lefthalf.filled"
    case .install: "checkmark.circle"
    case .diagnostics: "doc.text.magnifyingglass"
    }
  }
}

@MainActor struct GuideView: View {
  @State private var step: GuideStep = .inspect
  @State private var engine: WorkflowEngine?
  @State private var status = "Start with a read-only check of this Mac and its USB devices."
  @State private var session = "No session loaded."
  @State private var report = "Create a diagnostic preview before exporting."
  @State private var files = "Choose a destination for verified publisher downloads."
  @State private var busy = false
  @State private var operation = ""
  @State private var downloadTask: Task<Void, Never>?
  @State private var activeDownload: String?
  @State private var pendingApproval: ApprovalRequest?
  @State private var adbURL: URL?
  @State private var deviceSerial = ""
  @State private var recoveryDevices: [ADBDevice] = []
  @State private var verifiedRecoverySerial: String?
  @State private var guestConsoleReady = false
  @State private var guestPassword = ""
  @State private var backupProgress: BackupProgress?
  @State private var activeBackupID: UUID?
  @State private var checklist: Set<String> = []

  private let startupChecks = [
    "Android setup / home screen", "Wi-Fi", "Touchscreen", "Audio", "Microphone", "Camera",
    "Normal reboot",
  ]

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
          stageContent
          if pendingApproval != nil {
            Button("Review pending native approval…") { reviewPendingApproval() }
              .disabled(busy)
          }
          if busy {
            if let progress = backupProgress {
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
              Button("Cancel downloads") { downloadTask?.cancel() }
            }
          }
          Divider()
          Text(
            "Experimental source preview. Preparation, recovery inspection, and verified backup adapters are available as pilot integration. Device writing is unavailable in this preview; a timeout never proves an unlock."
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
        "Download the pinned UTM and CHECKERS ROM directly from their publishers. SHA-256 verification completes before a file is considered usable. No files are installed or executed."
      )
      GroupBox("Download progress") { selectable(files) }
      Button("Choose folder and prepare downloads…") { prepareDownloads() }.disabled(busy)
    case .workspace:
      Text(
        "Linux translation and the first USB assignment require a user action in UTM/macOS. Workspace creation is available as pilot integration; guest bootstrap is still being validated, so creation does not establish readiness."
      )
      instruction(
        "0", "Enable installer input",
        "Before starting the app-owned VM, open its Edit settings → Devices and enable keyboard and pointer input. UTM’s scripting interface does not configure these devices. Confirm the Debian menu responds to arrow keys before continuing; a visible boot menu alone does not establish readiness."
      )
      instruction(
        "1", "Enable Linux translation",
        "In the app-owned UTM VM configuration, enable Rosetta translation for Linux. Do not change an unrelated VM."
      )
      instruction(
        "2", "Assign the Echo to UTM",
        "At the top right of the Mac menu bar, open the accessories icon. Select Android → Use with UTM. Leave your mouse, charger, and other accessories on This Mac."
      )
      instruction(
        "3", "Attach to the correct VM",
        "In UTM, open Virtual Machine → USB Devices and choose the Echo for the workspace identified by this session. A successful attachment still requires guest identity checks."
      )
      Button("Create managed UTM workspace…") { prepareWorkspace() }.disabled(busy || engine == nil)
      VStack(alignment: .leading, spacing: 8) {
        Button("Reconcile interrupted workspace creation…") { workspaceLifecycle(.reconcile) }
        Button("Start owned workspace…") { workspaceLifecycle(.start) }
        Button("Gracefully stop owned workspace…") { workspaceLifecycle(.stop) }
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
            .disabled(busy || engine == nil || !guestConsoleReady || guestPassword.isEmpty)
          Button("Validate owned guest and original client…") { validateGuest() }
            .disabled(busy || engine == nil || !guestConsoleReady || guestPassword.isEmpty)
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
    case .recovery:
      Text(
        "Enter this stage only after compatible TWRP is independently verified. Tap Keep Read Only at the first recovery prompt. Do not wipe anything yet."
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
        "Unlock and installation are separate approvals. Each must show the exact selected device and action. The backend rejects requests with missing or changed prerequisites."
      )
      HStack {
        Button("Request unlock approval…") { requestApproval(.unlock) }
        Button("Request installation approval…") { requestApproval(.install) }
      }.disabled(busy || engine == nil)
      GroupBox("After a verified installation") {
        VStack(alignment: .leading, spacing: 10) {
          Text(
            "During Android setup, leave Update Lineage Recovery unchecked to retain TWRP. A dark screen may be asleep; do not assume it is a failed boot."
          )
          Text(
            "Personal checklist below is not an automated verification and is not saved as device evidence."
          ).font(.caption).foregroundStyle(.secondary)
          ForEach(startupChecks, id: \.self) { check in
            Toggle(
              check,
              isOn: Binding(
                get: { checklist.contains(check) },
                set: { value in
                  if value { checklist.insert(check) } else { checklist.remove(check) }
                }))
          }
          Button("Confirm I reached Android setup / home") { confirmStartup() }
            .disabled(!checklist.contains("Android setup / home screen") || engine == nil || busy)
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
      engine = try WorkflowEngine(root: WorkflowEngine.defaultRoot)
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
    } catch { status = "Session check stopped: \(error.localizedDescription)" }
  }

  private func inspect() {
    guard let engine else { return }
    busy = true
    operation = "Inspecting this Mac and USB…"
    Task {
      do {
        let result = try await engine.inspect()
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
    do {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Review the exact device and action"
      alert.informativeText =
        "This experimental operation can erase data or permanently damage the Echo. Approval applies only to the session and prerequisites shown below.\n\n"
        + (try encoded(request))
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Approve this request")
      if alert.runModal() == .alertSecondButtonReturn {
        try engine.approve(requestID: request.id)
        status =
          "Native approval recorded. An approval alone does not prove an operation ran or succeeded."
      } else {
        try engine.rejectApproval(requestID: request.id)
        status = "Request declined; no operation authorized."
      }
      refresh()
    } catch {
      status = "Approval stopped: \(error.localizedDescription)"
      refresh()
    }
  }

  private func previewReport() {
    guard let engine else { return }
    do { report = try encoded(engine.diagnosticReport()) } catch {
      status = "Report stopped: \(error.localizedDescription)"
    }
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
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "echoguide-diagnostic.json"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do { try Data(report.utf8).write(to: destination, options: .atomic) } catch {
      status = "Export stopped: \(error.localizedDescription)"
    }
  }

  private func prepareDownloads() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message =
      "Choose where to save verified UTM and ROM downloads (about 790 MB). Nothing will be installed."
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    busy = true
    operation = "Preparing publisher downloads…"
    downloadTask = Task {
      var completed: [String] = []
      do {
        let profile = try CompatibilityProfile.bundled()
        let artifacts = try profile.artifacts.filter {
          $0.name.hasSuffix(".dmg") || $0.name.hasPrefix("lineage-")
        }.map { artifact -> DownloadArtifact in
          guard let address = artifact.publisherURL, let url = URL(string: address),
            url.scheme == "https"
          else {
            throw GuideError.stopped("Publisher URL missing or invalid for \(artifact.name)")
          }
          return DownloadArtifact(
            name: artifact.name, url: url, sha256: artifact.sha256, size: artifact.size)
        }
        guard !artifacts.isEmpty else {
          throw GuideError.stopped("No publisher downloads in the pinned profile")
        }
        for artifact in artifacts {
          try Task.checkCancellation()
          activeDownload = artifact.name
          files = (completed + ["Downloading or verifying \(artifact.name)…"]).joined(
            separator: "\n")
          let completedSoFar = completed
          completed.append(
            try await prepareArtifact(artifact, in: folder) { received, total in
              Task { @MainActor in
                guard activeDownload == artifact.name else { return }
                let measured =
                  "\(received.formatted()) bytes received"
                  + (total.map { " of \($0.formatted())" } ?? "")
                files = (completedSoFar + ["Downloading \(artifact.name): \(measured)"]).joined(
                  separator: "\n")
              }
            })
          activeDownload = nil
        }
        files =
          (completed + ["Verified downloads ready. The Linux workspace still needs preparation."])
          .joined(separator: "\n")
      } catch is CancellationError {
        files = (completed + ["Cancelled. Completed verified downloads were retained."]).joined(
          separator: "\n")
      } catch {
        files = (completed + ["Stopped: \(error.localizedDescription)"]).joined(separator: "\n")
      }
      downloadTask = nil
      activeDownload = nil
      busy = false
    }
  }
}
