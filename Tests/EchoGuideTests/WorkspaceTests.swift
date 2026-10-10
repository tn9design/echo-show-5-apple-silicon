import XCTest

@testable import EchoGuideCore

private struct NoGuestCommands: BinaryCommandRunning {
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTFail("Guest prerequisites must stop before invoking a command")
    throw GuideError.stopped("Unexpected command")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws
    -> CommandResult
  {
    XCTFail("No transfer permitted")
    throw GuideError.stopped("Unexpected transfer")
  }
}
final class WorkspaceTests: XCTestCase {
  func testValidationRejectsAbsentOrOtherWorkspaceTrustBeforeCommands() async throws {
    for otherWorkspace in [false, true] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let engine = try WorkflowEngine(root: root, runner: NoGuestCommands())
      if otherWorkspace {
        try engine.store.transaction { session in
          session.vmID = UUID().uuidString
          session.guest = GuestWorkspaceRecord(
            vmID: UUID(), address: "192.168.64.99",
            hostKeyFingerprint: "PRIVATE-FINGERPRINT", checkedAt: Date(), ready: true)
        }
      }
      do {
        _ = try await engine.validateOwnedGuest(
          utm: URL(fileURLWithPath: "/Applications/UTM.app"),
          fastboot: URL(fileURLWithPath: "/not-read"), mockScript: URL(fileURLWithPath: "/not-read")
        )
        XCTFail("Expected missing trust rejection")
      } catch {}
      XCTAssertEqual(try engine.status().operations.last?.result, "failed; inspection required")
    }
  }
  func testGuestRecordPersistsPrivatelyAndReportOmitsIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    let id = UUID()
    try engine.store.transaction { session in
      session.vmID = id.uuidString
      session.guest = GuestWorkspaceRecord(
        vmID: id, address: "192.168.64.99",
        hostKeyFingerprint: "PRIVATE-FINGERPRINT", checkedAt: Date(), ready: false)
    }
    let restored = try WorkflowEngine(root: root).status()
    XCTAssertEqual(restored.guest?.vmID, id)
    let report = String(
      decoding: try JSONEncoder().encode(engine.diagnosticReport()), as: UTF8.self)
    XCTAssertFalse(report.contains("192.168.64.99"))
    XCTAssertFalse(report.contains("PRIVATE-FINGERPRINT"))
    XCTAssertFalse(report.contains(id.uuidString))
  }
}
