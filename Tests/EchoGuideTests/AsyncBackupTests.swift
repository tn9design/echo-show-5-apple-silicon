import XCTest
@testable import EchoGuideCore

private struct DelayedRecoveryRejection: BinaryCommandRunning {
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    try await Task.sleep(nanoseconds: 250_000_000)
    return .init(stdout: "unsupported-fixture")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    XCTFail("Rejected recovery must never transfer a partition")
    throw GuideError.stopped("Unexpected transfer")
  }
}

final class AsyncBackupTests: XCTestCase {
  func testStartReturnsPersistentIDAndRetainsExclusiveOwnershipUntilFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root, runner: DelayedRecoveryRejection())
    try engine.store.transaction { state in
      state.phase = .recovery
      state.device = DeviceIdentity(serial: "fixture", product: "checkers", lkBuild: "fixture")
      state.adbPath = "/fixture/adb"
      state.backupDestination = root.path
    }
    let operation = try engine.startConfiguredBackup()
    let running = try engine.status()
    XCTAssertEqual(running.operations.last?.id, operation.id)
    XCTAssertNil(running.operations.last?.completedAt)
    let otherProcess = try WorkflowEngine(root: root, runner: DelayedRecoveryRejection())
    XCTAssertThrowsError(try otherProcess.startConfiguredBackup())
    for _ in 0..<10 {
      let polled = try otherProcess.status()
      XCTAssertEqual(polled.operations.count, 1)
      XCTAssertEqual(polled.operations.last?.id, operation.id)
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    try await engine.waitForBackgroundOperations()
    let failed = try engine.status()
    XCTAssertEqual(failed.operations.count, 1)
    XCTAssertEqual(failed.operations.last?.id, operation.id)
    XCTAssertNotNil(failed.operations.last?.completedAt)
    XCTAssertEqual(failed.operations.last?.result, "failed; inspection required")
    XCTAssertEqual(failed.phase, .inspectionRequired)
    XCTAssertNil(failed.backupManifest)
  }

  func testUnconfiguredRequestDoesNotCreateOperationIntent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root, runner: DelayedRecoveryRejection())
    XCTAssertThrowsError(try engine.startConfiguredBackup())
    XCTAssertTrue(try engine.status().operations.isEmpty)
  }
}
