import Darwin
import Foundation

public struct CommandResult: Sendable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32
  public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}
public protocol CommandRunning: Sendable {
  func run(executable: String, arguments: [String]) async throws -> CommandResult
}
public enum GuideError: Error, LocalizedError {
  case stopped(String)
  public var errorDescription: String? {
    switch self {
    case .stopped(let s): return s
    }
  }
}
public struct Artifact: Codable, Sendable {
  public let name: String
  public let sha256: String
  public let publisherURL: String?
  public let size: Int64?
}
public struct CompatibilityProfile: Codable, Sendable {
  public let id: String
  public let product: String
  public let lkBuild: String
  public let minimumWritingOS: Int
  public let utmVersion: String
  public let guestVersion: String
  public let recoveryVersion: String
  public let romVersion: String
  public let experimental: Bool
  public let artifacts: [Artifact]
  public func artifact(named name: String) throws -> Artifact {
    let matches = artifacts.filter { $0.name == name }
    guard matches.count == 1, let artifact = matches.first,
      artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    else {
      throw GuideError.stopped("Missing, ambiguous or invalid pinned artifact")
    }
    return artifact
  }
  public static func bundled() throws -> Self {
    guard let url = Bundle.module.url(forResource: "checkers-v1", withExtension: "json") else {
      throw GuideError.stopped("Compatibility profile missing")
    }
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}
public enum Phase: String, Codable, Sendable {
  case setup, workspace, identified, recovery, backedUp, awaitingApproval, inspectionRequired,
    installed, finished
}
public enum WriteAction: String, Codable, Sendable { case unlock, install }
public struct DeviceIdentity: Codable, Sendable, Equatable {
  public var serial: String
  public var product: String
  public var lkBuild: String
  public var recoveryVersion: String?
  public init(serial: String, product: String, lkBuild: String, recoveryVersion: String? = nil) {
    self.serial = serial
    self.product = product
    self.lkBuild = lkBuild
    self.recoveryVersion = recoveryVersion
  }
}
public struct ApprovalRequest: Codable, Sendable {
  public let id: UUID
  public let action: WriteAction
  public let device: DeviceIdentity
  public let createdAt: Date
  public let sessionID: UUID
  public let prerequisitesDigest: String
}
public struct OperationRecord: Codable, Sendable {
  public var id: UUID
  public var action: String
  public var startedAt: Date
  public var completedAt: Date?
  public var result: String?
}
public struct SessionRecord: Codable, Sendable {
  public var id = UUID()
  public var phase: Phase = .setup
  public var profileID: String
  public var device: DeviceIdentity?
  public var vmID: String?
  public var adbPath: String?
  public var backupDestination: String?
  public var configuredROMPath: String?
  public var stagedROMHash: String?
  public var pendingApproval: ApprovalRequest?
  public var operations: [OperationRecord] = []
  public var backupManifest: String?
  public var guest: GuestWorkspaceRecord?
  public var backupProgress: BackupProgress?
  public var downloadProgress: PublisherPreparationProgress?
  public var postInstallObservations: [PostInstallObservation]?
  public var startupConfirmed = false
  public init(profileID: String) { self.profileID = profileID }
}
public struct HostInspection: Codable, Sendable {
  public let architecture: String
  public let macOS: String
  public let writingBackendSupported: Bool
  public let usbInspectionAvailable: Bool
  public let devices: [USBDevice]
  public let nextAction: String
}
public struct DiagnosticReport: Codable, Sendable {
  public let profile: String
  public let phase: Phase
  public let operations: [String]
  public let experimental: Bool
  public let note: String
}

// File locking covers every process (app, CLI and MCP), not merely one Swift actor.
public final class SessionStore: @unchecked Sendable {
  public let root: URL
  public init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  public func transaction<T>(_ body: (inout SessionRecord) throws -> T) throws -> T {
    let fd = open(root.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot open workflow lock") }
    defer { close(fd) }
    // State transactions are short; polling must not make an active backup fail.
    // The separate active.lock still rejects concurrent operations immediately.
    var acquired = false
    for _ in 0..<250 {
      if flock(fd, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
      if errno != EWOULDBLOCK && errno != EAGAIN { break }
      usleep(1_000)
    }
    guard acquired else { throw GuideError.stopped("Workflow state is busy; retry status shortly") }
    defer { flock(fd, LOCK_UN) }
    let url = root.appendingPathComponent("session.json")
    var session: SessionRecord
    if FileManager.default.fileExists(atPath: url.path) {
      session = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: url))
    } else {
      session = SessionRecord(profileID: try CompatibilityProfile.bundled().id)
    }
    let result = try body(&session)
    let data = try JSONEncoder().encode(session)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return result
  }
}
public final class WorkflowEngine: @unchecked Sendable {
  private let backgroundLock = NSLock()
  private var backgroundBackup: Task<Void, Never>?
  private var backgroundPersistenceFailure: String?
  public static var defaultRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/EchoGuide")
  }
  public let store: SessionStore
  public let profile: CompatibilityProfile
  public let runner: any BinaryCommandRunning
  public init(
    root: URL = WorkflowEngine.defaultRoot, runner: any BinaryCommandRunning = ProcessRunner()
  ) throws {
    self.runner = runner
    store = try SessionStore(root: root)
    profile = try CompatibilityProfile.bundled()
  }
  public func status() throws -> SessionRecord {
    try store.transaction { s in
      let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
      if fd >= 0 {
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
          defer { flock(fd, LOCK_UN) }
          if s.operations.contains(where: { $0.completedAt == nil }) {
            s.phase = .inspectionRequired
            s.pendingApproval = nil
          }
        }
      }
      return s
    }
  }
  public func inspect() async throws -> HostInspection {
    let r = runner
    let arch = try await r.run(executable: "/usr/bin/uname", arguments: ["-m"])
    let os = try await r.run(executable: "/usr/bin/sw_vers", arguments: ["-productVersion"])
    guard arch.exitCode == 0, os.exitCode == 0 else {
      throw BackendFailure(.inspectionUnavailable, "Mac architecture or operating-system inspection failed; backend support is unknown")
    }
    let usb = try await r.run(executable: "/usr/sbin/ioreg", arguments: ["-a", "-p", "IOUSB"])
    let a = arch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let v = os.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let supported =
      a == "arm64" && (Int(v.split(separator: ".").first ?? "0") ?? 0) >= profile.minimumWritingOS
    let parsedDevices = usb.exitCode == 0 ? try? USBInspection.parse(Data(usb.stdout.utf8)) : nil
    let usbAvailable = parsedDevices != nil
    let connectionAction: String
    if !usbAvailable {
      connectionAction = "USB inspection is unavailable; device presence is unknown. Recheck Mac USB inspection before assigning the Echo."
    } else if parsedDevices!.isEmpty {
      connectionAction = "No USB devices were detected. Connect the Echo with a data-capable cable, leave wall power connected, and recheck."
    } else {
      connectionAction = "Prepare the isolated Linux workspace, then assign only the Echo USB accessory."
    }
    return HostInspection(
      architecture: a, macOS: v, writingBackendSupported: supported,
      usbInspectionAvailable: usbAvailable,
      devices: parsedDevices ?? [],
      nextAction: supported
        ? connectionAction
        : "Device-writing backend requires Apple Silicon and macOS 27 or later; other versions are not validated."
    )
  }

  public func diagnosticReport() throws -> DiagnosticReport {
    let s = try status()
    return DiagnosticReport(
      profile: profile.id, phase: s.phase,
      operations: s.operations.map {
        let outcome: String
        if $0.completedAt == nil { outcome = "incomplete" }
        else if $0.result == "completed" { outcome = "completed" }
        else if $0.result == "failed" { outcome = "failed" }
        else if $0.result == "failed; inspection required" { outcome = "failed; inspection required" }
        else if $0.result == "interrupted read abandoned after recovery reinspection; partial files preserved" {
          outcome = "interrupted; partial files preserved"
        } else if $0.result == "creation reconciled by exact ownership marker and VM UUID" {
          outcome = "creation reconciled"
        } else { outcome = "finished; outcome unknown" }
        let allowedActions: Set<String> = ["prepare_downloads", "prepare_workspace", "reconcile_workspace", "start_workspace", "stop_workspace", "bootstrap_guest", "validate_guest", "discover_fastboot", "identify_fastboot", "verify_recovery", "backup", "configure_rom", "stage_rom", "consume_native_approval", "unlock", "install"]
        let action = allowedActions.contains($0.action) ? $0.action : "unknown_operation"
        return action + ": " + outcome
      }, experimental: true,
      note: "Serials, addresses, private paths, command output, credentials and backups omitted.")
  }
  public func requestApproval(action: WriteAction) throws -> ApprovalRequest {
    let request = try store.transaction { s in
      guard s.operations.allSatisfy({ $0.completedAt != nil }) else {
        throw GuideError.stopped(
          "An interrupted operation requires inspection; it cannot be replayed")
      }
      guard let d = s.device, d.product == profile.product,
        action == .install
          ? d.recoveryVersion == profile.recoveryVersion : d.lkBuild == profile.lkBuild
      else { throw GuideError.stopped("Exact supported device/build has not been verified") }
      guard action == .unlock ? s.phase == .identified : s.phase == .backedUp else {
        throw GuideError.stopped("Required device mode or verified backups are missing")
      }
      if action == .install {
        guard let manifest = s.backupManifest, FileManager.default.fileExists(atPath: manifest)
        else { throw GuideError.stopped("Verified backup manifest is missing") }
        let entries = try JSONDecoder().decode(
          [VerifiedPartitionBackup].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        guard
          Set(entries.map { $0.partition.name })
            == Set(["boot", "recovery", "system", "userdata", "metadata"]), entries.count == 5
        else { throw GuideError.stopped("Backup manifest is incomplete") }
        for entry in entries {
          guard entry.filename == entry.partition.name + ".img" else {
            throw GuideError.stopped("Invalid backup filename")
          }
          let url = URL(fileURLWithPath: manifest).deletingLastPathComponent()
            .appendingPathComponent(entry.filename)
          let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
          guard size?.uint64Value == entry.partition.size,
            try RecoveryAdapter.hash(url) == entry.sha256
          else { throw GuideError.stopped("Backup image is missing or has changed") }
        }
        guard
          s.stagedROMHash
            == profile.artifacts.first(where: { $0.name.hasPrefix("lineage-") })?.sha256
        else { throw GuideError.stopped("Device-side ROM staging has not been verified") }
      }
      let digest = try ApprovalPrerequisites.capture(session: s, action: action, profile: profile).digest()
      let req = ApprovalRequest(
        id: UUID(), action: action, device: d, createdAt: Date(), sessionID: s.id,
        prerequisitesDigest: digest)
      s.pendingApproval = req
      return req
    }
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("org.echoguide.approvalRequested"), object: nil)
    return request
  }
  // Approval records are intentionally not exposed as CLI or MCP methods.
  public func approve(requestID: UUID) throws {
    try store.transaction { s in
      guard let req = s.pendingApproval else {
        throw GuideError.stopped("Approval request is missing")
      }
      let current = try ApprovalPrerequisites.capture(session: s, action: req.action, profile: profile)
      try ApprovalPolicy.validate(req, requestID: requestID, current: current)
      // Live writing remains unavailable until fresh-host and independent-device pilot gates pass.
      throw GuideError.stopped(
        "Experimental device-writing dispatcher is not released. No device command was sent.")
    }
  }
  public func rejectApproval(requestID: UUID) throws {
    try store.transaction { s in
      guard s.pendingApproval?.id == requestID else {
        throw GuideError.stopped("Approval request is stale")
      }
      s.pendingApproval = nil
    }
  }
  public func confirmStartup() throws {
    try store.transaction { s in
      guard s.phase == .installed else {
        throw GuideError.stopped("Successful installation has not been verified")
      }
      s.startupConfirmed = true
      s.phase = .finished
    }
  }
}

extension WorkflowEngine {
  func operation<T: Sendable>(_ action: String, _ body: @Sendable () async throws -> T)
    async throws -> T
  {
    let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot acquire operation lock") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw BackendFailure(.concurrentOperation, "Another operation is active")
    }
    defer { flock(fd, LOCK_UN) }
    let id = UUID()
    try store.transaction { s in
      guard s.operations.allSatisfy({ $0.completedAt != nil }) else {
        throw BackendFailure(.interruptedOperation, "An interrupted operation requires inspection")
      }
      s.operations.append(OperationRecord(id: id, action: action, startedAt: Date()))
    }
    do {
      let result = try await body()
      try store.transaction { s in
        if let i = s.operations.firstIndex(where: { $0.id == id }) {
          s.operations[i].completedAt = Date()
          s.operations[i].result = "completed"
        }
      }
      return result
    } catch {
      try? store.transaction { s in
        s.phase = .inspectionRequired
        if let i = s.operations.firstIndex(where: { $0.id == id }) {
          s.operations[i].completedAt = Date()
          s.operations[i].result = "failed; inspection required"
        }
      }
      throw error
    }
  }
  public func prepareWorkspace(utm: URL, iso: URL) async throws -> UUID {
    let host = try await inspect()
    guard host.writingBackendSupported else { throw GuideError.stopped("Unsupported host backend") }
    guard
      let artifact = profile.artifacts.first(where: { $0.name == "debian-13.7.0-arm64-netinst.iso" }
      ), try RecoveryAdapter.hash(iso) == artifact.sha256
    else { throw GuideError.stopped("Pinned Debian ISO missing or mismatched") }
    return try await operation("prepare_workspace") {
      guard try self.status().vmID == nil else {
        throw GuideError.stopped("Workspace exists; inspect it rather than creating a duplicate")
      }
      let spec = OwnedVMSpecification()
      let intent = self.store.root.appendingPathComponent("workspace-intent.json")
      guard !FileManager.default.fileExists(atPath: intent.path) else {
        throw GuideError.stopped(
          "Previous workspace creation may be incomplete; reconcile ownership before retrying")
      }
      try JSONEncoder().encode(spec).write(to: intent, options: .atomic)
      let id: UUID
      do {
        id = try await UTMAdapter(runner: self.runner, application: utm).create(
          specification: spec, verifiedISO: iso)
      } catch let failure as BackendFailure
        where failure.code == .permissionDenied
      {
        try FileManager.default.removeItem(at: intent)
        throw BackendFailure(.permissionDenied,
          "Automation permission denied before VM creation. Enable UTM Automation permission, then explicitly retry.")
      }

      try self.store.transaction {
        $0.vmID = id.uuidString
        $0.phase = .workspace
      }
      return id
    }
  }
  public func verifyRecovery(adb: URL, serial: String) async throws {
    try await operation("verify_recovery") {
      let adapter = try RecoveryAdapter(runner: self.runner, adbPath: adb.path, serial: serial)
      try await adapter.verify()
      try self.store.transaction { s in
        if let old = s.device, old.serial != serial {
          s.backupManifest = nil
          s.pendingApproval = nil
        }
        // Recovery proves CHECKERS/TWRP, not LK. Do not invent a bootloader result.
        s.adbPath = adb.path
        s.device = DeviceIdentity(
          serial: serial, product: self.profile.product,
          lkBuild: s.device?.serial == serial ? s.device!.lkBuild : "not verified in recovery",
          recoveryVersion: self.profile.recoveryVersion)
        // Entering a new recovery workflow invalidates observations from a previous installation.
        s.postInstallObservations = nil
        s.startupConfirmed = false
        s.phase = .recovery
      }
    }
  }
  public func backup(
    adb: URL, destination: URL,
    progress: (@Sendable (BackupProgress) -> Void)? = nil
  ) async throws -> [VerifiedPartitionBackup] {
    try await operation("backup") {
      try await self.performBackup(adb: adb, destination: destination, progress: progress)
    }
  }
  private func performBackup(
    adb: URL, destination: URL, progress: (@Sendable (BackupProgress) -> Void)? = nil
  ) async throws -> [VerifiedPartitionBackup] {
      let state = try self.status()
      guard state.phase == .recovery, let device = state.device else {
        throw GuideError.stopped("Compatible recovery has not been verified")
      }
      let adapter = try RecoveryAdapter(
        runner: self.runner, adbPath: adb.path, serial: device.serial)
      try self.store.transaction { $0.backupProgress = nil }
      let results = try await adapter.backup(
        to: destination,
        progress: { update in
          try? self.store.transaction { $0.backupProgress = update }
          progress?(update)
        })
      try self.store.transaction {
        $0.backupDestination = destination.path
        $0.adbPath = adb.path
        $0.backupManifest = destination.appendingPathComponent("verified-backups.json").path
        $0.phase = .backedUp
      }
      return results
  }
}

extension WorkflowEngine {
  public func verifyConfiguredRecovery() async throws {
    let s = try status()
    guard let adb = s.adbPath, let d = s.device else {
      throw GuideError.stopped("Select ADB and the recovery device in the native app first")
    }
    try await verifyRecovery(adb: URL(fileURLWithPath: adb), serial: d.serial)
  }
  /// Reserve and journal before returning; the detached worker retains cross-process ownership.
  public func startConfiguredBackup() throws -> OperationRecord {
    let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot acquire operation lock") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw BackendFailure(.concurrentOperation, "Another operation is active")
    }
    let record = OperationRecord(id: UUID(), action: "backup", startedAt: Date())
    let configuration: (String, String)
    do {
      configuration = try store.transaction { state in
        guard state.operations.allSatisfy({ $0.completedAt != nil }) else {
          throw BackendFailure(.interruptedOperation, "An interrupted operation requires inspection")
        }
        guard state.phase == .recovery, state.device != nil else {
          throw GuideError.stopped("Compatible recovery has not been verified")
        }
        guard let adb = state.adbPath, let folder = state.backupDestination else {
          throw GuideError.stopped("Choose the backup destination and ADB in the native app first")
        }
        state.backupProgress = nil
        state.operations.append(record)
        return (adb, folder)
      }
    } catch {
      flock(fd, LOCK_UN); close(fd)
      throw error
    }
    backgroundLock.withLock { backgroundPersistenceFailure = nil }
    let task = Task.detached { [self] in
      defer { flock(fd, LOCK_UN); close(fd) }
      do {
        _ = try await performBackup(
          adb: URL(fileURLWithPath: configuration.0),
          destination: URL(fileURLWithPath: configuration.1))
        try store.transaction { state in
          if let index = state.operations.firstIndex(where: { $0.id == record.id }) {
            state.operations[index].completedAt = Date()
            state.operations[index].result = "completed"
          }
        }
      } catch {
        do {
          try store.transaction { state in
            state.phase = .inspectionRequired
            if let index = state.operations.firstIndex(where: { $0.id == record.id }) {
              state.operations[index].completedAt = Date()
              state.operations[index].result = "failed; inspection required"
            }
          }
        } catch {
          // Leave the intent incomplete; status requires inspection after ownership ends.
          backgroundLock.withLock {
            backgroundPersistenceFailure = "Backup stopped but terminal state could not be saved; inspection is required"
          }
        }
      }
    }
    backgroundLock.withLock { backgroundBackup = task }
    return record
  }
  /// Graceful stdio EOF does not kill an in-flight backup. Forced termination leaves an incomplete journal.
  public func waitForBackgroundOperations() async throws {
    let task = backgroundLock.withLock { backgroundBackup }
    await task?.value
    if let failure = backgroundLock.withLock({ backgroundPersistenceFailure }) {
      throw GuideError.stopped(failure)
    }
  }
  public func backupConfigured() async throws -> [VerifiedPartitionBackup] {
    let s = try status()
    guard let adb = s.adbPath, let folder = s.backupDestination else {
      throw GuideError.stopped("Choose the backup destination and ADB in the native app first")
    }
    return try await backup(
      adb: URL(fileURLWithPath: adb), destination: URL(fileURLWithPath: folder))
  }
}

extension WorkflowEngine {
  /// Explicit reinspection only. Interrupted device writes or VM creation must use their own reconciliation.
  public func recoverInterruptedReads(adb: URL, serial: String) async throws {
    try await recoverInterruptedReads(runner: self.runner, adb: adb, serial: serial)
  }
  func recoverInterruptedReads(runner: any BinaryCommandRunning, adb: URL, serial: String)
    async throws
  {
    let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot acquire operation lock") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw GuideError.stopped("An operation is still active; it cannot be abandoned")
    }
    defer { flock(fd, LOCK_UN) }
    let before = try store.transaction { s -> SessionRecord in
      guard s.device?.serial == serial else {
        throw GuideError.stopped("Select the same device associated with the interrupted read")
      }
      let incomplete = s.operations.filter { $0.completedAt == nil }
      guard !incomplete.isEmpty,
        incomplete.allSatisfy({ ["backup", "verify_recovery"].contains($0.action) })
      else {
        throw GuideError.stopped(
          "Only interrupted read/backup operations can be reconciled here; no write or workspace operation is replayed"
        )
      }
      return s
    }
    try await RecoveryAdapter(runner: runner, adbPath: adb.path, serial: serial).verify()
    try store.transaction { s in
      guard s.id == before.id, s.device == before.device else {
        throw GuideError.stopped("Session changed during reinspection")
      }
      for i in s.operations.indices where s.operations[i].completedAt == nil {
        guard ["backup", "verify_recovery"].contains(s.operations[i].action) else {
          throw GuideError.stopped("Session contains an interrupted write")
        }
        s.operations[i].completedAt = Date()
        s.operations[i].result =
          "interrupted read abandoned after recovery reinspection; partial files preserved"
      }
      s.backupManifest = nil
      s.stagedROMHash = nil
      s.pendingApproval = nil
      s.backupDestination = nil
      s.adbPath = adb.path
      s.phase = .recovery
    }
  }
}

extension WorkflowEngine {
  public func reconcileWorkspace(utm: URL) async throws -> VMReconciliation {
    let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot acquire operation lock") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw GuideError.stopped("Workspace operation is still active")
    }
    defer { flock(fd, LOCK_UN) }
    let intent = store.root.appendingPathComponent("workspace-intent.json")
    guard FileManager.default.fileExists(atPath: intent.path) else {
      throw GuideError.stopped("No app-owned workspace creation intent exists")
    }
    let spec = try JSONDecoder().decode(OwnedVMSpecification.self, from: Data(contentsOf: intent))
    let before = try store.transaction { $0 }
    guard
      before.operations.filter({ $0.completedAt == nil }).allSatisfy({
        $0.action == "prepare_workspace"
      })
    else {
      throw GuideError.stopped(
        "An interrupted device operation cannot be reconciled as VM creation")
    }
    let expected: UUID?
    if let id = before.vmID {
      guard let parsed = UUID(uuidString: id) else {
        throw GuideError.stopped("Invalid recorded VM UUID")
      }
      expected = parsed
    } else {
      expected = nil
    }
    let result = try await UTMAdapter(runner: runner, application: utm).reconcile(
      specification: spec, registeredVMID: expected)
    try store.transaction { s in
      guard s.id == before.id, s.vmID == before.vmID else {
        throw GuideError.stopped("Workspace binding changed during inspection")
      }
      switch result {
      case .absent: s.phase = .inspectionRequired  // Intent retained; no automatic recreation.
      case .owned(let info):
        s.vmID = info.id.uuidString
        s.phase = .workspace
        for i in s.operations.indices where s.operations[i].completedAt == nil {
          s.operations[i].completedAt = Date()
          s.operations[i].result = "creation reconciled by exact ownership marker and VM UUID"
        }
      }
    }
    return result
  }
  public func inspectOwnedWorkspace(utm: URL) async throws -> OwnedVMInfo {
    guard case .owned(let info) = try await reconcileWorkspace(utm: utm) else {
      throw GuideError.stopped("Owned workspace absent; creation intent retained")
    }
    return info
  }
}

extension WorkflowEngine {
  public func startOwnedWorkspace(utm: URL) async throws -> OwnedVMInfo {
    try await changeOwnedWorkspace(utm: utm, start: true)
  }
  public func stopOwnedWorkspace(utm: URL) async throws -> OwnedVMInfo {
    try await changeOwnedWorkspace(utm: utm, start: false)
  }
  private func changeOwnedWorkspace(utm: URL, start: Bool) async throws -> OwnedVMInfo {
    try await operation(start ? "start_workspace" : "stop_workspace") {
      try self.store.transaction { $0.guest?.ready = false }
      let state = try self.status()
      guard let text = state.vmID, let id = UUID(uuidString: text) else {
        throw GuideError.stopped("No registered app-owned workspace")
      }
      let intent = self.store.root.appendingPathComponent("workspace-intent.json")
      let spec = try JSONDecoder().decode(OwnedVMSpecification.self, from: Data(contentsOf: intent))
      let adapter = UTMAdapter(runner: self.runner, application: utm)
      // The adapter rechecks exact ownership and UUID in the same scripting invocation.
      return try await
        (start
        ? adapter.start(specification: spec, vmID: id)
        : adapter.requestGracefulStop(specification: spec, vmID: id))
    }
  }
}
