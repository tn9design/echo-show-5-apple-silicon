import XCTest
@testable import EchoGuideCore

private actor NativePilotFixture: UnlockTransport, UnlockClock {
  var calls = 0
  func count() -> Int { calls }
  func validate(session: SessionRecord, profile: CompatibilityProfile) async throws -> UnlockValidation {
    calls += 1
    return UnlockValidation(vmID: session.guest!.vmID, hostKeyFingerprint: session.guest!.hostKeyFingerprint,
      clientSHA256: try profile.artifact(named: "fastboot").sha256,
      payloadSHA256: try profile.artifact(named: "fastbrick-20240709.img").sha256, ready: true)
  }
  func execute(_ command: UnlockCommand, timeoutSeconds: Int) async throws -> CommandResult {
    calls += 1
    let p = try CompatibilityProfile.bundled()
    switch command {
    case .getvar(_, let key):
      let value = key == "product" ? p.product : key == "unlock_status" ? "false" : p.lkBuild
      return CommandResult(stdout: key + ": " + value, stderr: "", exitCode: 0)
    case .flashPinnedBrick:
      return CommandResult(stdout: "unexpected", stderr: "", exitCode: 0)
    }
  }
  func sleep(seconds: Int) async throws {}
  func poweredWaitSecond() async throws {}
}
private final class NativeProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var ticks: [NativePilotProgress] = []
  func append(_ tick: NativePilotProgress) { lock.lock(); defer { lock.unlock() }; ticks.append(tick) }
  func values() -> [NativePilotProgress] { lock.lock(); defer { lock.unlock() }; return ticks }
}

final class NativePilotDispatcherTests: XCTestCase {
  private func fixture() throws -> (WorkflowEngine, ApprovalRequest) {
    let e = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    let id = UUID()
    try e.store.transaction {
      $0.phase = .identified; $0.vmID = id.uuidString
      $0.device = DeviceIdentity(serial: "FIXTURE", product: e.profile.product, lkBuild: e.profile.lkBuild)
      $0.guest = GuestWorkspaceRecord(vmID: id, address: "fixture", hostKeyFingerprint: "key", checkedAt: Date(), ready: true)
    }
    return (e, try e.requestApproval(action: .unlock))
  }
  private func host(_ supported: Bool) -> HostInspection {
    HostInspection(architecture: "arm64", macOS: "27", writingBackendSupported: supported,
      usbInspectionAvailable: true, devices: [], nextAction: "fixture")
  }
  func testDefaultGateNeverInspectsOrDispatches() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture()
    let dispatcher = NativePilotDispatcher(engine: e, environment: { _ in
      XCTFail("Disabled gate inspected environment"); throw GuideError.stopped("Fixture")
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Gate bypassed") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testUnsupportedHostStopsUnderOwnershipBeforeDeviceOrConsumption() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture(); let host = host(false)
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      XCTAssertNil(try e.status().operations.last?.completedAt)
      return NativePilotEnvironmentProof(host: host, guest: current.guest!)
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Unsupported host") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testStaleGuestProofStopsBeforeDeviceOrConsumption() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture(); let host = host(true)
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      let guest = current.guest!
      return NativePilotEnvironmentProof(host: host, guest: GuestWorkspaceRecord(vmID: guest.vmID,
        address: guest.address, hostKeyFingerprint: guest.hostKeyFingerprint,
        checkedAt: Date().addingTimeInterval(-60), ready: true))
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Stale guest") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testInstallActionRoutesToCheckedInstallPrerequisites() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction {
      $0.adbPath = "/fixture/adb"
      $0.pendingApproval = ApprovalRequest(id: req.id, action: .install, device: req.device,
        createdAt: req.createdAt, sessionID: req.sessionID, prerequisitesDigest: req.prerequisitesDigest)
    }
    let f = NativePilotFixture(); let host = host(true)
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      NativePilotEnvironmentProof(host: host, guest: current.guest!)
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Install prerequisites bypassed") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
    XCTAssertEqual(try e.status().phase, .inspectionRequired)
  }
  func testExperimentalCompositionNeverCallsTimeoutOrResponseSuccess() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture(); let host = host(true); let progress = NativeProgressRecorder()
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      NativePilotEnvironmentProof(host: host, guest: current.guest!)
    }, unlockTransport: f, clock: f, progress: { progress.append($0) })
    let result = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id)
    guard case .recoveryInspectionRequired(let outcome) = result else { return XCTFail("Claimed install") }
    XCTAssertEqual(outcome.attempts, 1)
    XCTAssertEqual(progress.values().map(\.poweredWaitElapsedSeconds), Array(0...300))
    XCTAssertTrue(progress.values().allSatisfy { $0.attempts == 1 && $0.poweredWaitRequiredSeconds == 300 })
    XCTAssertNil(try e.status().pendingApproval); XCTAssertEqual(try e.status().phase, .inspectionRequired)
    XCTAssertThrowsError(try e.approve(requestID: req.id))
  }
}

private actor NativeRecoveryInstallRunner: BinaryCommandRunning {
  var installed = false
  let artifact: Artifact
  init(artifact: Artifact) { self.artifact = artifact }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    if arguments.last == "ro.product.device" { return CommandResult(stdout: "checkers") }
    if arguments.last == "ro.twrp.version" { return CommandResult(stdout: "3.7.0_9-0") }
    if arguments.contains("sha256sum") { return CommandResult(stdout: artifact.sha256 + "  " + ROMStagingAdapter.destination + "\n") }
    if arguments.contains("stat") { return CommandResult(stdout: String(artifact.size!) + "\n") }
    if arguments.contains("wipe") { return CommandResult(stdout: "") }
    if arguments.contains("install") { installed = true; return CommandResult(stdout: "") }
    if arguments.contains("/tmp/recovery.log") { return CommandResult(stdout: installed ? "prior\nInstalling zip file '\(ROMStagingAdapter.destination)'\nUpdater process ended with RC=0\nI:operation_end - status=0\n" : "prior\n") }
    if arguments.last == "reboot" { return CommandResult(stdout: "") }
    throw GuideError.stopped("Unexpected recovery fixture")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult { throw GuideError.stopped("Unexpected capture") }
}
extension NativePilotDispatcherTests {
  func testRecoveryEntryInstallsWithHostProofWithoutVMGuestOrUnlockTransport() async throws {
    let profile = try CompatibilityProfile.bundled()
    let artifact = try profile.artifact(named: ROMStagingAdapter.filename)
    let runner = NativeRecoveryInstallRunner(artifact: artifact)
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString), runner: runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let folder = engine.store.root.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var entries: [VerifiedPartitionBackup] = []
    for (index, name) in ["boot", "recovery", "system", "userdata", "metadata"].enumerated() {
      let file = folder.appendingPathComponent(name + ".img")
      try Data(repeating: UInt8(index), count: 1_048_576).write(to: file)
      entries.append(VerifiedPartitionBackup(partition: Partition(name: name, device: "/dev/block/mmcblk0p\(index + 1)", size: 1_048_576), filename: file.lastPathComponent, sha256: try RecoveryAdapter.hash(file)))
    }
    let manifest = folder.appendingPathComponent("verified-backups.json")
    try JSONEncoder().encode(entries).write(to: manifest)
    try engine.store.transaction { s in
      s.device = DeviceIdentity(serial: "FIXTURE", product: profile.product, lkBuild: "not verified in recovery", recoveryVersion: profile.recoveryVersion)
      s.phase = .backedUp; s.adbPath = "/fixture/adb"; s.backupManifest = manifest.path; s.stagedROMHash = artifact.sha256
    }
    let request = try engine.requestApproval(action: .install)
    let host = host(true)
    let progress = NativeProgressRecorder()
    let dispatcher = NativePilotDispatcher(engine: engine, gate: .experimentalOptIn, environment: { _ in NativePilotEnvironmentProof(host: host, guest: nil) }, progress: { progress.append($0) })
    let result = try await dispatcher.dispatch(nativeConfirmedRequestID: request.id)
    guard case .installedAwaitingUserStartup = result else { return XCTFail("Expected installation") }
    XCTAssertEqual(try engine.status().phase, .installed)
    XCTAssertTrue(progress.values().isEmpty)
    XCTAssertNil(try engine.status().vmID); XCTAssertNil(try engine.status().guest)
  }
  func testUnlockCannotUseHostOnlyProofOrAbsentTransport() async throws {
    let (engine, request) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction { $0.vmID = nil; $0.guest = nil }
    let host = host(true); let transport = NativePilotFixture()
    let dispatcher = NativePilotDispatcher(engine: engine, gate: .experimentalOptIn, environment: { _ in NativePilotEnvironmentProof(host: host, guest: nil) }, unlockTransport: transport)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: request.id); XCTFail("Host-only unlock") } catch {}
    let count = await transport.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try engine.status().pendingApproval?.id, request.id)
    let missing = NativePilotDispatcher(engine: engine, gate: .experimentalOptIn, environment: { _ in NativePilotEnvironmentProof(host: host, guest: nil) })
    do { _ = try await missing.dispatch(nativeConfirmedRequestID: request.id); XCTFail("Missing transport") } catch {}
  }
}
