import XCTest
@testable import EchoGuideCore

private actor RestartFixture: BinaryCommandRunning {
  let id: UUID
  var steps: [(String, String)]
  let cancelOnStopped: Bool
  init(id: UUID, steps: [(String, String)], cancelOnStopped: Bool = false) {
    self.id = id; self.steps = steps; self.cancelOnStopped = cancelOnStopped
  }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    guard !steps.isEmpty else { XCTFail("Unexpected restart command"); throw GuideError.stopped("Unexpected command") }
    let step = steps.removeFirst()
    XCTAssertEqual(executable, "/usr/bin/osascript")
    XCTAssertEqual(arguments.last, id.uuidString)
    let script = arguments[1]
    let action = script.contains("stop selectedVM by request") ? "stop" : script.contains("start selectedVM") ? "start" : "info"
    XCTAssertEqual(action, step.0)
    XCTAssertFalse(script.contains("by force"))
    if cancelOnStopped && step.1 == "stopped" {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    return .init(stdout: id.uuidString + "\tapple\t" + step.1)
  }
  func remaining() -> Int { steps.count }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    XCTFail("Restart must not transfer files")
    throw GuideError.stopped("Unexpected transfer")
  }
}
final class GuestWorkspaceRestartTests: XCTestCase {
  func testCancellationAfterShutdownPreventsStart() async throws {
    let id = UUID()
    let fixture = RestartFixture(id: id, steps: [("info", "started"), ("stop", "stopped")], cancelOnStopped: true)
    let task = Task {
      try await GuestWorkspaceRestart.run(adapter: UTMAdapter(runner: fixture, application: URL(fileURLWithPath: "/Applications/UTM.app")), specification: OwnedVMSpecification(), vmID: id, maximumChecks: 2, interval: .zero)
    }
    do { try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError {}
    let remaining = await fixture.remaining(); XCTAssertEqual(remaining, 0)
  }
  func testInvalidPasswordStopsBeforeAnyWorkspaceOperation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(); let fixture = RestartFixture(id: id, steps: [])
    let engine = try WorkflowEngine(root: root, runner: fixture)
    do {
      _ = try await engine.bootstrapOwnedGuest(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "", restartWorkspace: true)
      XCTFail("Expected password rejection")
    } catch {}
    XCTAssertTrue(try engine.status().operations.isEmpty)
  }
  func testInterruptedKeySetupStopsBeforeRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID(); let fixture = RestartFixture(id: id, steps: [])
    let engine = try WorkflowEngine(root: root, runner: fixture)
    try engine.store.transaction { $0.vmID = id.uuidString }
    try JSONEncoder().encode(OwnedVMSpecification()).write(to: root.appendingPathComponent("workspace-intent.json"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("guest-" + id.uuidString), withIntermediateDirectories: true)
    do {
      _ = try await engine.bootstrapOwnedGuest(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "fixture-only", restartWorkspace: true)
      XCTFail("Expected interrupted credentials rejection")
    } catch {}
    XCTAssertEqual(try engine.status().operations.last?.result, "failed; inspection required")
  }
  private func run(_ fixture: RestartFixture, id: UUID, checks: Int = 2) async throws {
    try await GuestWorkspaceRestart.run(adapter: UTMAdapter(runner: fixture, application: URL(fileURLWithPath: "/Applications/UTM.app")), specification: OwnedVMSpecification(), vmID: id, maximumChecks: checks, interval: .zero)
  }
  func testWaitsForObservedShutdownBeforeStarting() async throws {
    let id = UUID()
    let fixture = RestartFixture(id: id, steps: [("info","started"),("stop","started"),("info","stopping"),("info","stopped"),("start","starting"),("info","started")])
    try await run(fixture, id: id)
    let remaining = await fixture.remaining(); XCTAssertEqual(remaining, 0)
  }
  func testIgnoredShutdownNeverStartsOrForces() async throws {
    let id = UUID()
    let fixture = RestartFixture(id: id, steps: [("info","started"),("stop","started"),("info","started"),("info","started")])
    do { try await run(fixture, id: id); XCTFail("Expected shutdown timeout") } catch {}
    let remaining = await fixture.remaining(); XCTAssertEqual(remaining, 0)
  }
  func testPausedWorkspaceStopsBeforeMutation() async throws {
    let id = UUID(); let fixture = RestartFixture(id: id, steps: [("info","paused")])
    do { try await run(fixture, id: id); XCTFail("Expected paused rejection") } catch {}
    let remaining = await fixture.remaining(); XCTAssertEqual(remaining, 0)
  }
  func testFailedStartupDoesNotContinue() async throws {
    let id = UUID(); let fixture = RestartFixture(id: id, steps: [("info","stopped"),("start","stopped")])
    do { try await run(fixture, id: id); XCTFail("Expected startup rejection") } catch {}
    let remaining = await fixture.remaining(); XCTAssertEqual(remaining, 0)
  }
}
