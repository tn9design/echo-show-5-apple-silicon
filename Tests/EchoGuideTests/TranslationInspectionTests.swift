import Darwin
import XCTest
@testable import EchoGuideCore

private actor TranslationInspectionRunner: BinaryCommandRunning {
  let id: UUID
  var calls = 0
  init(id: UUID) { self.id = id }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    calls += 1
    if executable == "/usr/bin/osascript" {
      return .init(stdout: "\(id.uuidString)\t0\t/dev/ttys001")
    }
    XCTAssertEqual(executable, "/usr/bin/ssh")
    XCTAssertFalse(arguments.last!.contains("sudo -"))
    XCTAssertFalse(arguments.last!.contains("mkdir"))
    XCTAssertFalse(arguments.last!.contains("systemctl"))
    return .init(stdout: "ECHOGUIDE-CONNECTION-OK\nECHOGUIDE-SUDO-NO\n")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    XCTFail("Inspection must not transfer files")
    throw GuideError.stopped("Unexpected transfer")
  }
  func count() -> Int { calls }
}

final class TranslationInspectionTests: XCTestCase {
  private func fixture(action: String? = nil, marker: Bool = true) throws -> (WorkflowEngine, TranslationInspectionRunner) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let id = UUID(), runner = TranslationInspectionRunner(id: id)
    let engine = try WorkflowEngine(root: root, runner: runner)
    try engine.store.transaction {
      $0.vmID = id.uuidString; $0.guestUsername = "echotest"
      $0.guest = GuestWorkspaceRecord(vmID: id, address: "192.168.64.7", hostKeyFingerprint: "fixture", checkedAt: Date(), ready: false)
      if let action { $0.operations.append(OperationRecord(id: UUID(), action: action, startedAt: Date())) }
    }
    try JSONEncoder().encode(OwnedVMSpecification()).write(to: root.appendingPathComponent("workspace-intent.json"))
    let credentials = root.appendingPathComponent("guest-" + id.uuidString)
    try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
    for name in ["client-ed25519", "known_hosts"] { try Data("fixture".utf8).write(to: credentials.appendingPathComponent(name)) }
    if marker {
      try JSONEncoder().encode(["vmID": id.uuidString, "action": "configure_guest_translation"])
        .write(to: root.appendingPathComponent("translation-setup-pending.json"))
    }
    return (engine, runner)
  }
  func testPendingInspectionPreservesMarkerJournalAndReadiness() async throws {
    let (engine, _) = try fixture(action: "configure_guest_translation")
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let session = engine.store.root.appendingPathComponent("session.json")
    let marker = engine.store.root.appendingPathComponent("translation-setup-pending.json")
    let before = try Data(contentsOf: session), intent = try Data(contentsOf: marker)
    let result = try await engine.inspectInterruptedTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
    XCTAssertEqual(result.category, "unknown")
    XCTAssertTrue(result.connection.connected)
    XCTAssertEqual(result.connection.translationPrivilegeToolAvailable, false)
    XCTAssertTrue(result.pendingIntentPresent); XCTAssertTrue(result.incompleteTranslationJournal)
    XCTAssertEqual(try Data(contentsOf: session), before)
    XCTAssertEqual(try Data(contentsOf: marker), intent)
    XCTAssertEqual(try engine.status().guest?.ready, false)
  }
  func testCrashAfterMarkerRemovalStillRemainsUnknown() async throws {
    let (engine, _) = try fixture(action: "configure_guest_translation", marker: false)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let result = try await engine.inspectInterruptedTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
    XCTAssertFalse(result.pendingIntentPresent); XCTAssertTrue(result.incompleteTranslationJournal)
    XCTAssertEqual(result.category, "unknown")
    XCTAssertNil(try engine.status().operations.last?.completedAt)
  }
  func testOtherInterruptedActionsStopBeforeBackend() async throws {
    let (engine, runner) = try fixture(action: "install")
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { _ = try await engine.inspectInterruptedTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app")); XCTFail() } catch {}
    let calls = await runner.count(); XCTAssertEqual(calls, 0)
  }
  func testMismatchedMarkerStopsBeforeBackend() async throws {
    let (engine, runner) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try JSONEncoder().encode(["vmID": UUID().uuidString, "action": "configure_guest_translation"])
      .write(to: engine.store.root.appendingPathComponent("translation-setup-pending.json"))
    do { _ = try await engine.inspectInterruptedTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app")); XCTFail() } catch {}
    let calls = await runner.count(); XCTAssertEqual(calls, 0)
  }
  func testBoundIntentMatchesJournalAndPinnedScript() async throws {
    let (engine, _) = try fixture(action: "configure_guest_translation")
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let state = try engine.status()
    try JSONEncoder().encode(["vmID": state.vmID!, "action": "configure_guest_translation",
      "operationID": state.operations.last!.id.uuidString,
      "scriptSHA256": try engine.profile.artifact(named: "setup-linux-translation.sh").sha256])
      .write(to: engine.store.root.appendingPathComponent("translation-setup-pending.json"))
    let result = try await engine.inspectInterruptedTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
    XCTAssertEqual(result.category, "unknown")
    XCTAssertNil(try engine.status().operations.last?.completedAt)
  }
  func testWrongOrPartialAttemptBindingStopsBeforeBackend() async throws {
    for kind in 0...2 {
      let (engine, runner) = try fixture(action: "configure_guest_translation")
      defer { try? FileManager.default.removeItem(at: engine.store.root) }
      let state = try engine.status()
      var marker = ["vmID": state.vmID!, "action": "configure_guest_translation",
        "operationID": state.operations.last!.id.uuidString,
        "scriptSHA256": try engine.profile.artifact(named: "setup-linux-translation.sh").sha256]
      if kind == 0 { marker["operationID"] = UUID().uuidString }
      if kind == 1 { marker["scriptSHA256"] = String(repeating: "0", count: 64) }
      if kind == 2 { marker.removeValue(forKey: "operationID") }
      try JSONEncoder().encode(marker).write(to: engine.store.root.appendingPathComponent("translation-setup-pending.json"))
      do { _ = try await engine.inspectInterruptedTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app")); XCTFail() } catch {}
      let calls = await runner.count(); XCTAssertEqual(calls, 0)
    }
  }
  func testConcurrentOperationStopsBeforeBackend() async throws {
    let (engine, runner) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let fd = open(engine.store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { flock(fd, LOCK_UN); close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
    do { _ = try await engine.inspectInterruptedTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app")); XCTFail() } catch {}
    let calls = await runner.count(); XCTAssertEqual(calls, 0)
  }
}
