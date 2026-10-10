import XCTest
@testable import EchoGuideCore

final class DiagnosticRedactionTests: XCTestCase {
  func testHostileFreeTextFieldsCannotLeakIntoShareableReport() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    let privateValue = "PRIVATE-SERIAL /Users/private/person 192.168.1.50 password-secret"
    try engine.store.transaction { state in
      state.profileID = privateValue
      state.adbPath = privateValue
      state.backupDestination = privateValue
      state.device = DeviceIdentity(serial: privateValue, product: privateValue, lkBuild: privateValue)
      state.operations = [OperationRecord(id: UUID(), action: privateValue, startedAt: Date(), completedAt: Date(), result: privateValue),
        OperationRecord(id: UUID(), action: "prepare_downloads", startedAt: Date(), completedAt: Date(), result: "failed")]
    }
    let report = try engine.diagnosticReport()
    XCTAssertEqual(report.profile, engine.profile.id)
    XCTAssertEqual(report.operations, ["unknown_operation: finished; outcome unknown", "prepare_downloads: failed"])
    let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    for forbidden in ["PRIVATE-SERIAL", "/Users/private", "192.168.1.50", "password-secret"] {
      XCTAssertFalse(text.contains(forbidden))
    }
  }
}
