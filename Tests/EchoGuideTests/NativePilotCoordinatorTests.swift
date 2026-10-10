#if canImport(AppKit)
import AppKit
import XCTest
@testable import EchoGuideCore

private actor CoordinatorNoCommands: BinaryCommandRunning {
  var calls = 0
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    calls += 1; throw GuideError.stopped("Unexpected command")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    calls += 1; throw GuideError.stopped("Unexpected transfer")
  }
  func count() -> Int { calls }
}
@MainActor
final class NativePilotCoordinatorTests: XCTestCase {
  func testPreviewFacadeRefusesBeforeWindowInspectionUIOrCommands() async throws {
#if ECHOGUIDE_EXPERIMENTAL_PILOT
    throw XCTSkip("This assertion targets the default preparation build, not explicitly compiled pilot builds")
#else
    XCTAssertEqual(NativePilotCoordinator.buildMode, .preparationPreview)
    let runner = CoordinatorNoCommands()
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString), runner: runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    XCTAssertThrowsError(try NativePilotCoordinator.make(engine: engine, window: nil)) { error in
      XCTAssertTrue(error.localizedDescription.contains("preparation preview"))
    }
    let count = await runner.count(); XCTAssertEqual(count, 0)
    XCTAssertTrue(try engine.status().operations.isEmpty)
#endif
  }
  func testClosePermanentlyInvalidatesEvenRetainedCoordinatorWithoutWindow() async throws {
    let runner = CoordinatorNoCommands()
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString), runner: runner)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let coordinator = NativePilotCoordinator(testOnlyNoWindowEngine: engine)
    XCTAssertFalse(coordinator.closed)
    coordinator.close(); coordinator.close()
    XCTAssertTrue(coordinator.closed)
    do { _ = try await coordinator.review(requestID: UUID()); XCTFail("Closed coordinator reviewed") }
    catch { XCTAssertTrue(error.localizedDescription.contains("permanently closed")) }
    let count = await runner.count(); XCTAssertEqual(count, 0)
  }
  func testNilWindowNeverProducesRunnableFacade() throws {
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    XCTAssertThrowsError(try NativePilotCoordinator.make(engine: engine, window: nil))
  }
}
#endif
