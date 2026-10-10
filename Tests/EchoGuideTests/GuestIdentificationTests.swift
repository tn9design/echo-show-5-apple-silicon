import XCTest
@testable import EchoGuideCore

private actor IdentificationRunner: BinaryCommandRunning, TimedCommandRunning {
  let build: String
  let devices: String
  var queries: [String] = []
  var connectionCount = 0
  var vmID: UUID?
  var ownershipCalls = 0
  let stoppedAfter: Int?
  func bind(_ id: UUID) { vmID = id }
  init(build: String = "44072a3-20240709_170103", devices: String = "TEST\tfastboot\n", stoppedAfter: Int? = nil) { self.build = build; self.devices = devices; self.stoppedAfter = stoppedAfter }
  func run(executable: String, arguments: [String]) async throws -> CommandResult { throw GuideError.stopped("Unbounded command forbidden") }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult { throw GuideError.stopped("Transfer forbidden") }
  func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
    if executable == "/usr/bin/osascript" {
      ownershipCalls += 1
      let state = stoppedAfter.map { ownershipCalls >= $0 ? "stopped" : "started" } ?? "started"
      return CommandResult(stdout: vmID!.uuidString + "\tapple\t" + state + "\n")
    }
    connectionCount += 1
    XCTAssertEqual(executable, "/usr/bin/ssh"); XCTAssertEqual(timeoutSeconds, 25)
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    let command = arguments.last!
    XCTAssertFalse(command.contains("flash")); XCTAssertFalse(command.contains("reboot"))
    if command.contains("--version") { return CommandResult(stdout: "fastboot version 28.0.0\nInstalled as /home/user/echoguide/fastboot\n") }
    if command.hasSuffix(" devices") { return CommandResult(stdout: devices) }
    for (key, value) in [("product", "CHECKERS"), ("unlock_status", "false"), ("lk_build_desc", build)] {
      if command.hasSuffix("getvar " + key) { queries.append(key); return CommandResult(stdout: key + ": " + value + "\n") }
    }
    throw GuideError.stopped("Unexpected command")
  }
}
final class GuestIdentificationTests: XCTestCase {
  private func fixture(_ runner: IdentificationRunner) async throws -> WorkflowEngine {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let engine = try WorkflowEngine(root: root, runner: runner)
    let id = UUID(); await runner.bind(id)
    try JSONEncoder().encode(OwnedVMSpecification()).write(to: root.appendingPathComponent("workspace-intent.json"))
    let folder = root.appendingPathComponent("guest-" + id.uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: folder.appendingPathComponent("client-ed25519"))
    let guest = try GuestAdapter(runner: runner, ownedVMID: id, credentialsDirectory: folder, address: "192.168.64.7")
    let key = "ssh-ed25519 " + Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
    let fingerprint = try guest.pinHostKey(.init(ownedVMID: id, publicHostKey: key))
    try engine.store.transaction { s in
      s.phase = .workspace; s.vmID = id.uuidString
      s.guest = GuestWorkspaceRecord(vmID: id, address: guest.address, hostKeyFingerprint: fingerprint, checkedAt: Date(), ready: true)
    }
    return engine
  }
  func testExplicitSelectionIdentifiesPinnedBuildInReviewedOrder() async throws {
    let runner = IdentificationRunner(); let engine = try await fixture(runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let candidates = try await engine.discoverFastbootDevices(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
    XCTAssertEqual(candidates.map(\.serial), ["TEST"])
    let device = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "TEST")
    XCTAssertEqual(device.product, "CHECKERS")
    XCTAssertEqual(try engine.status().phase, .identified)
    let queries = await runner.queries
    XCTAssertEqual(queries, ["product", "unlock_status", "lk_build_desc"])
  }
  func testUnsupportedBuildInvalidatesStaleIdentity() async throws {
    let engine = try await fixture(IdentificationRunner(build: "WRONG"))
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction { $0.device = DeviceIdentity(serial: "OLD", product: "CHECKERS", lkBuild: engine.profile.lkBuild) }
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "TEST"); XCTFail("Unsupported build") } catch {}
    XCTAssertNil(try engine.status().device)
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
  }
  func testDiscoveryDoesNotDiscardExistingIdentity() async throws {
    let engine = try await fixture(IdentificationRunner(devices: ""))
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let old = DeviceIdentity(serial: "OLD", product: "CHECKERS", lkBuild: engine.profile.lkBuild)
    try engine.store.transaction { $0.device = old; $0.phase = .identified }
    let candidates = try await engine.discoverFastbootDevices(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
    XCTAssertTrue(candidates.isEmpty)
    XCTAssertEqual(try engine.status().device, old)
  }
  func testDuplicatesMalformedAndUnselectedCandidatesStop() async throws {
    for text in ["TEST fastboot\nTEST fastboot\n", "TEST adb\n", "TEST;bad fastboot\n"] { XCTAssertThrowsError(try GuestIdentificationAdapter.parseCandidates(text)) }
    let engine = try await fixture(IdentificationRunner())
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "OTHER"); XCTFail("Missing selection") } catch {}
  }
  func testChangedHostKeyNeverQueriesDevice() async throws {
    let runner = IdentificationRunner(); let engine = try await fixture(runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction { $0.guest = GuestWorkspaceRecord(vmID: $0.guest!.vmID, address: $0.guest!.address, hostKeyFingerprint: "CHANGED", checkedAt: Date(), ready: true) }
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "TEST"); XCTFail("Changed trust") } catch {}
    let queries = await runner.queries; XCTAssertTrue(queries.isEmpty)
    let count = await runner.connectionCount; XCTAssertEqual(count, 0)
  }
}

extension GuestIdentificationTests {
  func testInspectionRequiredCannotBeResetAfterWrite() async throws {
    let runner = IdentificationRunner(); let engine = try await fixture(runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let original = DeviceIdentity(serial: "TEST", product: "CHECKERS", lkBuild: engine.profile.lkBuild)
    try engine.store.transaction { s in
      s.phase = .inspectionRequired; s.device = original
      s.operations.append(OperationRecord(id: UUID(), action: "unlock", startedAt: Date(), completedAt: Date(), result: "failed; inspection required"))
    }
    do { _ = try await engine.discoverFastbootDevices(utm: URL(fileURLWithPath: "/Applications/UTM.app")); XCTFail("Diagnosis must not reset a failed write") } catch {}
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "TEST"); XCTFail("Diagnosis must not reset a failed write") } catch {}
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
    XCTAssertEqual(try engine.status().device, original)
    let queries = await runner.queries; XCTAssertTrue(queries.isEmpty)
    let count = await runner.connectionCount; XCTAssertEqual(count, 0)
  }
  func testIncompleteWriteBlocksBeforeSSHOrIdentityClear() async throws {
    let runner = IdentificationRunner(); let engine = try await fixture(runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let original = DeviceIdentity(serial: "TEST", product: "CHECKERS", lkBuild: engine.profile.lkBuild)
    try engine.store.transaction { s in
      s.phase = .identified; s.device = original
      s.operations.append(OperationRecord(id: UUID(), action: "unlock", startedAt: Date()))
    }
    do { _ = try await engine.discoverFastbootDevices(utm: URL(fileURLWithPath: "/Applications/UTM.app")); XCTFail("Interrupted operation") } catch {}
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "TEST"); XCTFail("Interrupted operation") } catch {}
    XCTAssertEqual(try engine.status().device, original)
    let queries = await runner.queries; XCTAssertTrue(queries.isEmpty)
    let count = await runner.connectionCount; XCTAssertEqual(count, 0)
  }
  func testOversizedSerialAndSymlinkTrustStopBeforeSSH() async throws {
    XCTAssertThrowsError(try GuestIdentificationAdapter.parseCandidates(String(repeating: "A", count: 129) + " fastboot\n"))
    let runner = IdentificationRunner(); let engine = try await fixture(runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: String(repeating: "A", count: 129)); XCTFail("Oversized serial") } catch {}
    // Failed explicit identification requires diagnosis; reset only this offline fixture.
    try engine.store.transaction { $0.phase = .workspace }
    let id = try engine.status().guest!.vmID
    let known = engine.store.root.appendingPathComponent("guest-" + id.uuidString).appendingPathComponent("known_hosts")
    let target = engine.store.root.appendingPathComponent("copied-host-key")
    try FileManager.default.moveItem(at: known, to: target)
    try FileManager.default.createSymbolicLink(at: known, withDestinationURL: target)
    do { _ = try await engine.discoverFastbootDevices(utm: URL(fileURLWithPath: "/Applications/UTM.app")); XCTFail("Symlink trust") } catch {}
    let queries = await runner.queries; XCTAssertTrue(queries.isEmpty)
    let count = await runner.connectionCount; XCTAssertEqual(count, 0)
  }
}

extension GuestIdentificationTests {
  func testStoppedOwnedVMPreventsSSH() async throws {
    let runner = IdentificationRunner(stoppedAfter: 1); let engine = try await fixture(runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "TEST"); XCTFail("Stopped VM") } catch {}
    let count = await runner.connectionCount; XCTAssertEqual(count, 0)
    XCTAssertNil(try engine.status().device)
  }
  func testChangedOwnedVMAfterQueriesPreventsIdentityCommit() async throws {
    let runner = IdentificationRunner(stoppedAfter: 2); let engine = try await fixture(runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { _ = try await engine.identifyFastbootDevice(utm: URL(fileURLWithPath: "/Applications/UTM.app"), serial: "TEST"); XCTFail("Changed owned VM") } catch {}
    let queries = await runner.queries; XCTAssertEqual(queries.count, 3)
    XCTAssertNil(try engine.status().device)
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
  }
}
