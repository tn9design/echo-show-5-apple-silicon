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
            ProgressView(operation)
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
        "The scripted Linux VM needs keyboard and pointer input enabled in UTM’s Devices settings before a graphical Debian installation. This integration still needs fresh-guest validation."
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
      }.disabled(busy)
      TextField("Exact device serial from adb devices", text: $deviceSerial)
        .textFieldStyle(.roundedBorder)
      Text(
        "Manual serial selection is temporary. Verification checks the exact selected device before recording recovery readiness."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Verify this recovery") { verifyRecovery() }
          .disabled(busy || adbURL == nil || deviceSerial.isEmpty || engine == nil)
        Button("Back up and verify partitions…") { backup() }
          .disabled(busy || adbURL == nil || engine == nil)
      }
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

  private func verifyRecovery() {
    guard let engine, let adbURL else { return }
    let serial = deviceSerial
    busy = true
    operation = "Verifying selected recovery identity…"
    Task {
      do {
        try await engine.verifyRecovery(adb: adbURL, serial: serial)
        status =
          "Selected recovery passed the engine’s identity checks. Backups must still complete before installation."
      } catch { status = "Recovery verification stopped: \(error.localizedDescription)" }
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
    Task {
      do { status = try encoded(await engine.backup(adb: adbURL, destination: folder)) } catch {
        status = "Backup stopped: \(error.localizedDescription)"
      }
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
