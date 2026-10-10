import XCTest

@testable import EchoGuideCore

final class WorkflowTests: XCTestCase {
  func engine() throws -> WorkflowEngine {
    try WorkflowEngine(
      root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  }
  func testUnidentifiedDeviceCannotRequestWrite() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    XCTAssertThrowsError(try e.requestApproval(action: .unlock))
    XCTAssertThrowsError(try e.requestApproval(action: .install))
  }
  func testInterruptedOperationCannotReplay() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { s in
      s.device = DeviceIdentity(
        serial: "TEST", product: e.profile.product, lkBuild: e.profile.lkBuild)
      s.phase = .identified
      s.operations = [OperationRecord(id: UUID(), action: "unlock", startedAt: Date())]
    }
    XCTAssertThrowsError(try e.requestApproval(action: .unlock))
  }
  func testChangedIdentityInvalidatesApproval() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { s in
      s.device = DeviceIdentity(
        serial: "TEST", product: e.profile.product, lkBuild: e.profile.lkBuild)
      s.phase = .identified
    }
    let a = try e.requestApproval(action: .unlock)
    try e.store.transaction { $0.device?.serial = "OTHER" }
    XCTAssertThrowsError(try e.approve(requestID: a.id))
  }
  func testReportsOmitPrivateDeviceValues() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction {
      $0.device = DeviceIdentity(serial: "PRIVATE-SERIAL", product: "CHECKERS", lkBuild: "private")
    }
    let data = try JSONEncoder().encode(e.diagnosticReport())
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("PRIVATE-SERIAL"))
  }
  func testReportDoesNotTurnFailureOrUnknownOutcomeIntoSuccess() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { s in
      s.operations = [
        OperationRecord(id: UUID(), action: "backup", startedAt: Date(), completedAt: Date(), result: "failed; inspection required"),
        OperationRecord(id: UUID(), action: "start_workspace", startedAt: Date(), completedAt: Date(), result: "PRIVATE-DIAGNOSTIC")
      ]
    }
    let report = try e.diagnosticReport()
    XCTAssertEqual(report.operations, ["backup: failed; inspection required", "start_workspace: finished; outcome unknown"])
    XCTAssertFalse(try String(decoding: JSONEncoder().encode(report), as: UTF8.self).contains("PRIVATE-DIAGNOSTIC"))
  }
  func testCrossProcessLockRejectsConcurrentTransaction() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { _ in XCTAssertThrowsError(try e.status()) }
  }
  func testNativeApprovalCannotWriteInPreview() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { s in
      s.device = DeviceIdentity(
        serial: "TEST", product: e.profile.product, lkBuild: e.profile.lkBuild)
      s.phase = .identified
    }
    let a = try e.requestApproval(action: .unlock)
    XCTAssertThrowsError(try e.approve(requestID: a.id))
    XCTAssertTrue(try e.status().operations.isEmpty)
  }
}
extension WorkflowTests {
  func testMissingBackupManifestCannotRequestInstall() throws {
    let e = try engine()
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { s in
      s.device = DeviceIdentity(
        serial: "TEST", product: e.profile.product, lkBuild: e.profile.lkBuild,
        recoveryVersion: e.profile.recoveryVersion)
      s.phase = .backedUp
      s.backupManifest = "/nonexistent/manifest.json"
    }
    XCTAssertThrowsError(try e.requestApproval(action: .install))
  }
}
