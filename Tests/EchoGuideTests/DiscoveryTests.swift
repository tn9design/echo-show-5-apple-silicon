import XCTest

@testable import EchoGuideCore

final class DiscoveryTests: XCTestCase {
  func testEnumeratesMultipleDevicesWithoutSelectingOne() throws {
    let d = try RecoveryDeviceDiscovery.parse(
      "List of devices attached\nONE recovery product:omni_checkers model:Echo_Show_5\nTWO unauthorized\n"
    )
    XCTAssertEqual(d.count, 2)
    XCTAssertTrue(d[0].isRecoveryCandidate)
    XCTAssertFalse(d[1].isRecoveryCandidate)
  }
  func testRejectsDuplicateAndMalformedList() {
    XCTAssertThrowsError(try RecoveryDeviceDiscovery.parse("ONE recovery"))
    XCTAssertThrowsError(
      try RecoveryDeviceDiscovery.parse("List of devices attached\nONE recovery\nONE recovery"))
    XCTAssertThrowsError(
      try RecoveryDeviceDiscovery.parse(
        "List of devices attached\nONE recovery product:x product:y"))
  }
  func testEmptyListIsDifferentFromUnavailableInspection() throws {
    XCTAssertEqual(try RecoveryDeviceDiscovery.parse("List of devices attached\n"), [])
    XCTAssertThrowsError(try RecoveryDeviceDiscovery.parse(""))
  }
}
private actor ReinspectionRunner: BinaryCommandRunning {
  var count = 0
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    count += 1
    return CommandResult(stdout: arguments.contains("ro.product.device") ? "checkers" : "3.7.0_9-0")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws
    -> CommandResult
  { throw GuideError.stopped("No capture during reinspection") }
  func calls() -> Int { count }
}
extension DiscoveryTests {
  func testInterruptedBackupRequiresSameRecoveryAndPreservesPartial() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let e = try WorkflowEngine(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let partial = root.appendingPathComponent("userdata.img.partial")
    try Data([1, 2, 3]).write(to: partial)
    try e.store.transaction { s in
      s.device = DeviceIdentity(
        serial: "TEST", product: "CHECKERS", lkBuild: "unknown", recoveryVersion: "3.7.0_9-0")
      s.phase = .inspectionRequired
      s.backupManifest = "stale"
      s.operations = [OperationRecord(id: UUID(), action: "backup", startedAt: Date())]
    }
    try await e.recoverInterruptedReads(
      runner: ReinspectionRunner(), adb: URL(fileURLWithPath: "/fixture/adb"), serial: "TEST")
    XCTAssertEqual(try e.status().phase, .recovery)
    XCTAssertNil(try e.status().backupManifest)
    XCTAssertEqual(try Data(contentsOf: partial), Data([1, 2, 3]))
  }
  func testInterruptedUnlockCannotUseReadReconciliation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let e = try WorkflowEngine(root: root)
    defer { try? FileManager.default.removeItem(at: root) }
    try e.store.transaction { s in
      s.device = DeviceIdentity(serial: "TEST", product: "CHECKERS", lkBuild: "unknown")
      s.operations = [OperationRecord(id: UUID(), action: "unlock", startedAt: Date())]
    }
    let runner = ReinspectionRunner()
    do {
      try await e.recoverInterruptedReads(
        runner: runner, adb: URL(fileURLWithPath: "/fixture/adb"), serial: "TEST")
      XCTFail()
    } catch {}
    let calls = await runner.calls()
    XCTAssertEqual(calls, 0)
    XCTAssertNil(try e.status().operations[0].completedAt)
  }
}
private struct VMFixtureRunner: BinaryCommandRunning {
  let id: UUID
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    return CommandResult(stdout: id.uuidString + "\tapple\tstopped")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws
    -> CommandResult
  { throw GuideError.stopped("No binary transfer") }
}
extension DiscoveryTests {
  func testLostVMCreationResponseReconcilesWithoutCreatingAnother() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let id = UUID()
    let e = try WorkflowEngine(root: root, runner: VMFixtureRunner(id: id))
    defer { try? FileManager.default.removeItem(at: root) }
    try JSONEncoder().encode(OwnedVMSpecification()).write(
      to: root.appendingPathComponent("workspace-intent.json"))
    try e.store.transaction { s in
      s.operations = [OperationRecord(id: UUID(), action: "prepare_workspace", startedAt: Date())]
    }
    let info = try await e.inspectOwnedWorkspace(utm: URL(fileURLWithPath: "/fixture/UTM.app"))
    XCTAssertEqual(info.id, id)
    XCTAssertEqual(try e.status().vmID, id.uuidString)
    XCTAssertNotNil(try e.status().operations[0].completedAt)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent("workspace-intent.json").path))
  }
}
