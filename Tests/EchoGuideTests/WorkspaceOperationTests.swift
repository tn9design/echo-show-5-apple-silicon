import XCTest
import Darwin
@testable import EchoGuideCore

final class WorkspaceOperationTests: XCTestCase {
  private func engine() throws -> WorkflowEngine {
    try WorkflowEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), runner: WorkspaceHostFixture())
  }
  func testMissingNativeSelectionDoesNotJournalOrCreate() throws {
    let e = try engine(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    XCTAssertThrowsError(try e.startConfiguredWorkspace())
    XCTAssertTrue(try e.status().operations.isEmpty)
    XCTAssertNil(try e.status().vmID)
  }
  func testExistingVMAndInterruptedIntentAreNeverReplayed() throws {
    let e = try engine(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { $0.vmID = UUID().uuidString }
    XCTAssertThrowsError(try e.startConfiguredWorkspace())
    try e.store.transaction { $0.vmID = nil }
    try Data("intent".utf8).write(to: e.store.root.appendingPathComponent("workspace-intent.json"))
    XCTAssertThrowsError(try e.startConfiguredWorkspace())
    XCTAssertTrue(try e.status().operations.isEmpty)
  }
  func testConcurrentOperationAndChangedProfileAreRejectedBeforeJournal() throws {
    let e = try engine(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let fd = open(e.store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    XCTAssertThrowsError(try e.startConfiguredWorkspace())
    flock(fd, LOCK_UN); close(fd)
    try e.store.transaction { $0.workspaceSelection = WorkspacePreparationSelection(utmPath: "/fixture/UTM.app", isoPath: "/fixture/file.iso", profileID: "changed", isoSHA256: "changed") }
    XCTAssertThrowsError(try e.startConfiguredWorkspace())
    XCTAssertTrue(try e.status().operations.isEmpty)
  }
  func testWrongISORejectedBeforeSavingNativeSelection() throws {
    let e = try engine(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let iso = e.store.root.appendingPathComponent("wrong.iso")
    try Data("wrong".utf8).write(to: iso)
    XCTAssertThrowsError(try e.configureWorkspacePreparation(utm: URL(fileURLWithPath: "/fixture/UTM.app"), iso: iso))
    XCTAssertNil(try e.status().workspaceSelection)
  }
  func testUnsupportedHostPersistsSafeDiagnosticAndResetsPreviousDiagnostic() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let e = try WorkflowEngine(root: root, runner: WorkspaceHostFixture(architecture: "x86_64"))
    defer { try? FileManager.default.removeItem(at: root) }
    let hash = try XCTUnwrap(e.profile.artifacts.first { $0.name.hasSuffix("netinst.iso") }).sha256
    try e.store.transaction {
      $0.workspaceDiagnostic = BackendDiagnostic(error: BackendFailure(.hashMismatch, "/private/secret"))
      $0.workspaceSelection = WorkspacePreparationSelection(utmPath: "/private/secret/UTM.app", isoPath: "/private/secret/file.iso", profileID: e.profile.id, isoSHA256: hash)
    }
    _ = try e.startConfiguredWorkspace()
    await e.waitForWorkspacePreparation()
    XCTAssertEqual(try e.status().workspaceDiagnostic?.code, .unsupportedHost)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(e.status().workspaceDiagnostic), as: UTF8.self).contains("/private/secret"))
  }
  func testWrongUTMVersionHasSafeActionableDiagnostic() async throws {
    let e = try engine(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    do { try await e.validateWorkspaceTool(URL(fileURLWithPath: "/private/secret/UTM.app")); XCTFail() }
    catch {
      let diagnostic = BackendDiagnostic(error: error)
      XCTAssertEqual(diagnostic.code, .unsupportedWorkspaceTool)
      XCTAssertFalse(diagnostic.message.contains("/private/secret"))
    }
  }
  private func pinnedISO() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["ECHOGUIDE_TEST_PINNED_ISO"] else {
      throw XCTSkip("Set ECHOGUIDE_TEST_PINNED_ISO for pinned-byte workspace creation tests")
    }
    return URL(fileURLWithPath: path)
  }
  func testConfiguredBackgroundCreationJournalsOwnedUUIDWithoutReadiness() async throws {
    let iso = try pinnedISO()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runner = WorkspaceCreationFixture(root: root, expectedISO: iso, denied: false)
    let e = try WorkflowEngine(root: root, runner: runner)
    defer { try? FileManager.default.removeItem(at: root) }
    try e.configureWorkspacePreparation(utm: URL(fileURLWithPath: "/fixture/SelectedUTM.app"), iso: iso)
    let op = try e.startConfiguredWorkspace()
    await e.waitForWorkspacePreparation()
    let state = try e.status()
    XCTAssertEqual(state.vmID, runner.createdID.uuidString)
    XCTAssertEqual(state.phase, .workspace)
    XCTAssertNil(state.guest)
    XCTAssertNil(state.workspaceDiagnostic)
    let saved = try XCTUnwrap(state.operations.first { $0.id == op.id })
    XCTAssertNotNil(saved.completedAt)
    XCTAssertEqual(saved.result, "completed")
    let count = await runner.creationCount()
    XCTAssertEqual(count, 1)
  }
  func testPermissionDeniedCreationPersistsDiagnosticAndRemovesNoWriteIntent() async throws {
    let iso = try pinnedISO()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runner = WorkspaceCreationFixture(root: root, expectedISO: iso, denied: true)
    let e = try WorkflowEngine(root: root, runner: runner)
    defer { try? FileManager.default.removeItem(at: root) }
    try e.configureWorkspacePreparation(utm: URL(fileURLWithPath: "/fixture/SelectedUTM.app"), iso: iso)
    let op = try e.startConfiguredWorkspace()
    await e.waitForWorkspacePreparation()
    let state = try e.status()
    XCTAssertNil(state.vmID)
    XCTAssertNil(state.guest)
    XCTAssertEqual(state.workspaceDiagnostic?.code, .permissionDenied)
    XCTAssertFalse(state.workspaceDiagnostic?.message.contains("/fixture") ?? true)
    XCTAssertEqual(state.operations.first { $0.id == op.id }?.result, "failed; inspection required")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace-intent.json").path))
    let count = await runner.creationCount()
    XCTAssertEqual(count, 1)
  }
  func testChangedSelectedISOIsJournaledAsFailureWithoutCreation() async throws {
    let e = try engine(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let iso = e.store.root.appendingPathComponent("changed.iso")
    try Data("wrong".utf8).write(to: iso)
    let hash = try XCTUnwrap(e.profile.artifacts.first { $0.name.hasSuffix("netinst.iso") }).sha256
    try e.store.transaction { $0.workspaceSelection = WorkspacePreparationSelection(utmPath: "/fixture/UTM.app", isoPath: iso.path, profileID: e.profile.id, isoSHA256: hash) }
    let op = try e.startConfiguredWorkspace()
    await e.waitForWorkspacePreparation()
    let saved = try XCTUnwrap(e.status().operations.first { $0.id == op.id })
    XCTAssertNotNil(saved.completedAt)
    XCTAssertEqual(saved.result, "failed; inspection required")
    XCTAssertEqual(try e.status().workspaceDiagnostic?.code, .hashMismatch)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(e.status().workspaceDiagnostic), as: UTF8.self).contains(iso.path))
    XCTAssertNil(try e.status().vmID)
    XCTAssertFalse(FileManager.default.fileExists(atPath: e.store.root.appendingPathComponent("workspace-intent.json").path))
  }
}

private struct WorkspaceHostFixture: BinaryCommandRunning {
  var architecture = "arm64"
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    switch executable {
    case "/usr/bin/uname": return CommandResult(stdout: architecture)
    case "/usr/bin/sw_vers": return CommandResult(stdout: "27.2")
    case "/usr/bin/defaults": return CommandResult(stdout: "wrong-version")
    case "/usr/sbin/ioreg": return CommandResult(stdout: "")
    default: throw GuideError.stopped("Unexpected command; no live VM access")
    }
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    throw GuideError.stopped("Unexpected capture; no live VM access")
  }
}

private actor WorkspaceCreationFixture: BinaryCommandRunning {
  nonisolated let createdID = UUID()
  let root: URL
  let expectedISO: URL
  let denied: Bool
  private var creations = 0
  init(root: URL, expectedISO: URL, denied: Bool) { self.root = root; self.expectedISO = expectedISO; self.denied = denied }
  func creationCount() -> Int { creations }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    switch executable {
    case "/usr/bin/uname": return CommandResult(stdout: "arm64")
    case "/usr/bin/sw_vers": return CommandResult(stdout: "27.2")
    case "/usr/sbin/ioreg": return CommandResult(stdout: "")
    case "/usr/bin/defaults":
      XCTAssertEqual(arguments, ["read", "/fixture/SelectedUTM.app/Contents/Info", "CFBundleShortVersionString"])
      return CommandResult(stdout: "5.0.6")
    case "/usr/bin/osascript":
      creations += 1
      XCTAssertEqual(arguments.count, 4)
      XCTAssertEqual(arguments[0], "-e")
      XCTAssertEqual(arguments[1], try UTMAdapter.creationScript(application: URL(fileURLWithPath: "/fixture/SelectedUTM.app")))
      XCTAssertEqual(arguments[2], expectedISO.path)
      XCTAssertNotNil(UUID(uuidString: arguments[3]))
      let intent = try JSONDecoder().decode(OwnedVMSpecification.self, from: Data(contentsOf: root.appendingPathComponent("workspace-intent.json")))
      XCTAssertEqual(intent.ownershipID.uuidString, arguments[3])
      let journal = try SessionStore(root: root).transaction { $0.operations }
      XCTAssertEqual(journal.last?.action, "prepare_workspace")
      XCTAssertNil(journal.last?.completedAt)
      return denied ? CommandResult(stdout: "", stderr: "Not authorized /private/secret (-1743)", exitCode: 1) : CommandResult(stdout: createdID.uuidString)
    default: throw GuideError.stopped("Unexpected command; no live VM access")
    }
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    throw GuideError.stopped("Unexpected capture; no live VM access")
  }
}
