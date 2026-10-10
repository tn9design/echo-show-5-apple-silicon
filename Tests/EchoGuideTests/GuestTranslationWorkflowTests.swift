import Darwin
import XCTest
@testable import EchoGuideCore

private actor TranslationWorkflowCommands: BinaryCommandRunning {
  let id: UUID
  var commands = 0
  let wrongVM: Bool
  init(id: UUID, wrongVM: Bool = false) { self.id = id; self.wrongVM = wrongVM }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    commands += 1
    if executable == "/usr/bin/osascript" {
      XCTAssertEqual(arguments.last, id.uuidString)
      return .init(stdout: "\((wrongVM ? UUID() : id).uuidString)\t0\t/dev/ttys001")
    }
    return .init(stdout: "")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    XCTFail("No binary transfer permitted")
    throw GuideError.stopped("Unexpected binary transfer")
  }
  func count() -> Int { commands }
}
private actor TranslationWorkflowInput: SensitiveCommandRunning {
  var submissions = 0
  let fail: Bool
  init(fail: Bool = false) { self.fail = fail }
  func run(executable: String, arguments: [String], input: Data, timeoutSeconds: Int) async throws -> Int32 {
    submissions += 1
    if fail { throw GuideError.stopped("Sensitive command timed out; inspect outcome before retry") }
    return 0
  }
  func count() -> Int { submissions }
}
final class GuestTranslationWorkflowTests: XCTestCase {
  private func fixture(wrongVM: Bool = false) throws -> (WorkflowEngine, TranslationWorkflowCommands) {
    let id = UUID(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runner = TranslationWorkflowCommands(id: id, wrongVM: wrongVM)
    let engine = try WorkflowEngine(root: root, runner: runner)
    try engine.store.transaction {
      $0.vmID = id.uuidString; $0.guestUsername = "echotest"
      $0.guest = GuestWorkspaceRecord(vmID: id, address: "192.168.64.7", hostKeyFingerprint: "fixture", checkedAt: Date(), ready: true)
    }
    try JSONEncoder().encode(OwnedVMSpecification()).write(to: root.appendingPathComponent("workspace-intent.json"))
    let credentials = root.appendingPathComponent("guest-" + id.uuidString)
    try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
    for name in ["client-ed25519", "known_hosts"] { try Data("fixture".utf8).write(to: credentials.appendingPathComponent(name)) }
    return (engine, runner)
  }
  func testSuccessIsJournaledButNeverEstablishesReadiness() async throws {
    let (engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try await engine.configureOwnedGuestTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "fixture-only", sensitiveRunner: TranslationWorkflowInput())
    let state = try engine.status()
    XCTAssertEqual(state.guest?.ready, false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: engine.store.root.appendingPathComponent("translation-setup-pending.json").path))
    XCTAssertEqual(state.operations.last?.action, "configure_guest_translation")
    XCTAssertEqual(state.operations.last?.result, "completed")
    XCTAssertNotNil(state.operations.last?.completedAt)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("fixture-only"))
  }
  func testTimeoutPersistsInspectionAndUnreadyWithoutRetry() async throws {
    let (engine, _) = try fixture(); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let input = TranslationWorkflowInput(fail: true)
    do { try await engine.configureOwnedGuestTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "fixture-only", sensitiveRunner: input); XCTFail("Expected timeout") } catch {}
    let reopened = try WorkflowEngine(root: engine.store.root, runner: engine.runner)
    let state = try reopened.status()
    XCTAssertEqual(state.phase, .inspectionRequired)
    XCTAssertEqual(state.guest?.ready, false)
    XCTAssertEqual(state.operations.last?.result, "failed; inspection required")
    let calls = await input.count(); XCTAssertEqual(calls, 1)
    let intent = engine.store.root.appendingPathComponent("translation-setup-pending.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: intent.path))
    let marker = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: intent))
    XCTAssertEqual(marker["vmID"], state.vmID)
    XCTAssertEqual(marker["action"], "configure_guest_translation")
    XCTAssertEqual(marker["operationID"], state.operations.last?.id.uuidString)
    XCTAssertEqual(marker["scriptSHA256"], try engine.profile.artifact(named: "setup-linux-translation.sh").sha256)
    let ordinary = engine.runner as! TranslationWorkflowCommands
    let before = await ordinary.count()
    for action in 0...4 {
      do {
        switch action {
        case 0: try await reopened.configureOwnedGuestTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "fixture-only", sensitiveRunner: input)
        case 1: _ = try await reopened.startOwnedWorkspace(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
        case 2: _ = try await reopened.stopOwnedWorkspace(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
        case 3: _ = try await reopened.bootstrapOwnedGuest(utm: URL(fileURLWithPath: "/Applications/UTM.app"))
        default: _ = try await reopened.validateOwnedGuest(utm: URL(fileURLWithPath: "/Applications/UTM.app"), fastboot: URL(fileURLWithPath: "/fixture/fastboot"), mockScript: URL(fileURLWithPath: "/fixture/mock"))
        }
        XCTFail("Expected pending setup guard")
      } catch {
        XCTAssertEqual(error.localizedDescription, "Previous translation setup may still be running. Inspect the guest before setup, restart, or readiness validation; no automatic reconciliation")
      }
    }
    let after = await ordinary.count(), finalSubmissions = await input.count()
    XCTAssertEqual(before, after); XCTAssertEqual(finalSubmissions, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: intent.path))
  }
  func testInvalidPasswordAndInterruptedOperationNeverInvokeBackend() async throws {
    let (engine, runner) = try fixture(); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let input = TranslationWorkflowInput()
    do { try await engine.configureOwnedGuestTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "", sensitiveRunner: input); XCTFail() } catch {}
    XCTAssertTrue(try engine.status().operations.isEmpty)
    try engine.store.transaction { $0.operations.append(OperationRecord(id: UUID(), action: "configure_guest_translation", startedAt: Date())) }
    do { try await engine.configureOwnedGuestTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "fixture-only", sensitiveRunner: input); XCTFail() } catch {}
    let commands = await runner.count(), submissions = await input.count()
    XCTAssertEqual(commands, 0); XCTAssertEqual(submissions, 0)
    XCTAssertNil(try engine.status().operations.last?.completedAt)
  }
  func testWrongOwnedVMStopsBeforeSSHOrPassword() async throws {
    let (engine, runner) = try fixture(wrongVM: true); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let input = TranslationWorkflowInput()
    do { try await engine.configureOwnedGuestTranslation(utm: URL(fileURLWithPath: "/Applications/UTM.app"), password: "fixture-only", sensitiveRunner: input); XCTFail() } catch {}
    let commands = await runner.count(), submissions = await input.count()
    XCTAssertEqual(commands, 1); XCTAssertEqual(submissions, 0)
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
  }
}
