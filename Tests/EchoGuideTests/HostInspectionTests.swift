import XCTest
@testable import EchoGuideCore

private struct HostInspectionRunner: BinaryCommandRunning {
  let usb: CommandResult
  let os: String
  var architectureExit: Int32 = 0
  var osExit: Int32 = 0
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    switch executable {
    case "/usr/bin/uname": return CommandResult(stdout: "arm64", exitCode: architectureExit)
    case "/usr/bin/sw_vers": return CommandResult(stdout: os, exitCode: osExit)
    case "/usr/sbin/ioreg": return usb
    default: throw AdapterError.commandFailed("unexpected fixture command")
    }
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    throw AdapterError.commandFailed("unexpected transfer")
  }
}
final class HostInspectionTests: XCTestCase {
  func testFailedHostCommandsCannotEstablishBackendSupport() async throws {
    for (architectureExit, osExit): (Int32, Int32) in [(1, 0), (0, 1)] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let engine = try WorkflowEngine(root: root, runner: HostInspectionRunner(
        usb: CommandResult(stdout: "invalid"), os: "27.0",
        architectureExit: architectureExit, osExit: osExit))
      do { _ = try await engine.inspect(); XCTFail("Failed host inspection accepted") }
      catch {
        XCTAssertTrue(error.localizedDescription.contains("backend support is unknown"))
        XCTAssertEqual(BackendDiagnostic(error: error).code, .inspectionUnavailable)
      }
    }
  }
  func testInvalidPlistIsUnavailableWhileEmptyPlistIsDetectedAbsence() async throws {
    let empty = String(data: try PropertyListSerialization.data(fromPropertyList: [], format: .xml, options: 0), encoding: .utf8)!
    for (result, available, action) in [
      (CommandResult(stdout: "invalid"), false, "unknown"),
      (CommandResult(stdout: empty), true, "data-capable cable"),
      (CommandResult(stdout: empty, exitCode: 1), false, "unknown")
    ] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let engine = try WorkflowEngine(root: root, runner: HostInspectionRunner(usb: result, os: "27.0"))
      let inspection = try await engine.inspect()
      XCTAssertEqual(inspection.usbInspectionAvailable, available)
      XCTAssertTrue(inspection.devices.isEmpty)
      XCTAssertTrue(inspection.nextAction.contains(action), inspection.nextAction)
    }
  }
  func testUnsupportedBackendExplanationRemainsPrimary() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root, runner: HostInspectionRunner(usb: CommandResult(stdout: "invalid"), os: "14.0"))
    let inspection = try await engine.inspect()
    XCTAssertFalse(inspection.writingBackendSupported)
    XCTAssertTrue(inspection.nextAction.contains("macOS 27"))
  }
}
