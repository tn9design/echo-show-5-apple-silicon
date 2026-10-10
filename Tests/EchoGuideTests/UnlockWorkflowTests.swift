import XCTest
@testable import EchoGuideCore

private actor UnlockFixture: UnlockTransport, UnlockClock {
  enum Mode { case rejection, timeout, unexpected, disconnected, cancelled, wrongIdentity, wrongArtifact, waitFailure }
  let mode: Mode
  var commands: [UnlockCommand] = []
  var sleeps: [Int] = []
  init(_ mode: Mode) { self.mode = mode }
  func validate(session: SessionRecord, profile: CompatibilityProfile) async throws -> UnlockValidation {
    UnlockValidation(vmID: session.guest!.vmID, hostKeyFingerprint: session.guest!.hostKeyFingerprint,
      clientSHA256: mode == .wrongArtifact ? "bad" : try profile.artifact(named: "fastboot").sha256,
      payloadSHA256: try profile.artifact(named: "fastbrick-20240709.img").sha256, ready: true)
  }
  func execute(_ command: UnlockCommand, timeoutSeconds: Int) async throws -> CommandResult {
    commands.append(command)
    switch command {
    case .getvar(_, let key):
      XCTAssertEqual(timeoutSeconds, 10)
      let p = try CompatibilityProfile.bundled()
      let value = key == "product" ? (mode == .wrongIdentity ? "WRONG" : p.product)
        : key == "unlock_status" ? "false" : p.lkBuild
      return CommandResult(stdout: key + ": " + value + "\n", stderr: "", exitCode: 0)
    case .flashPinnedBrick:
      XCTAssertEqual(timeoutSeconds, 8)
      if mode == .cancelled { throw CancellationError() }
      if mode == .timeout || mode == .disconnected { throw GuideError.stopped("Fixture transfer failure") }
      if mode == .unexpected { return CommandResult(stdout: "OKAY", stderr: "", exitCode: 0) }
      return CommandResult(stdout: "target reported max download size of 114294784 bytes\nSending 'brick' (111785 KB)...\nOKAY [ 0.123s]\nWriting 'brick'...\nFAILED (remote: the command you input is restricted on locked hw)\nFinished. Total time: 0.456s\n", stderr: "", exitCode: 1)
    }
  }
  func sleep(seconds: Int) async throws {
    sleeps.append(seconds)
    if mode == .waitFailure && seconds == 1 { throw GuideError.stopped("Fixture wait unavailable") }
  }
  func poweredWaitSecond() async throws {
    try await sleep(seconds: 1)
  }
  func snapshot() -> ([UnlockCommand], [Int]) { (commands, sleeps) }
}

final class UnlockWorkflowTests: XCTestCase {
  private func fixture() throws -> (WorkflowEngine, ApprovalRequest) {
    let e = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    let vm = UUID()
    try e.store.transaction {
      $0.phase = .identified
      $0.device = DeviceIdentity(serial: "FIXTURE", product: e.profile.product, lkBuild: e.profile.lkBuild)
      $0.vmID = vm.uuidString
      $0.guest = GuestWorkspaceRecord(vmID: vm, address: "fixture", hostKeyFingerprint: "fixture-key", checkedAt: Date(), ready: true)
    }
    return (e, try e.requestApproval(action: .unlock))
  }
  func testRejectionsBoundedWithWaitAndConsumedApproval() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = UnlockFixture(.rejection)
    let result = try await e.unlockPinnedDevice(requestID: req.id, transport: f, clock: f)
    XCTAssertEqual(result.attempts, 3)
    let (commands, sleeps) = await f.snapshot()
    XCTAssertEqual(Array(commands.prefix(3)), [.getvar(serial: "FIXTURE", key: "product"), .getvar(serial: "FIXTURE", key: "unlock_status"), .getvar(serial: "FIXTURE", key: "lk_build_desc")])
    XCTAssertEqual(commands.count, 6); XCTAssertEqual(sleeps, [2, 2] + Array(repeating: 1, count: 300))
    XCTAssertNil(try e.status().pendingApproval); XCTAssertEqual(try e.status().phase, .inspectionRequired)
    do { _ = try await e.unlockPinnedDevice(requestID: req.id, transport: f, clock: f); XCTFail("Reused") } catch {}
    let after = await f.snapshot(); XCTAssertEqual(after.0.count, commands.count)
  }
  func testTimeoutUnexpectedAndConnectionLossNeverRetryOrSucceed() async throws {
    for mode in [UnlockFixture.Mode.timeout, .unexpected, .disconnected, .cancelled] {
      let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
      let f = UnlockFixture(mode)
      let result = try await e.unlockPinnedDevice(requestID: req.id, transport: f, clock: f)
      XCTAssertEqual(result.attempts, 1)
      let (_, sleeps) = await f.snapshot(); XCTAssertEqual(sleeps, Array(repeating: 1, count: 300))
      XCTAssertEqual(try e.status().phase, .inspectionRequired)
    }
  }
  func testIdentityAndArtifactFailureDoNotConsumeOrDispatch() async throws {
    for mode in [UnlockFixture.Mode.wrongIdentity, .wrongArtifact] {
      let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
      let f = UnlockFixture(mode)
      do { _ = try await e.unlockPinnedDevice(requestID: req.id, transport: f, clock: f); XCTFail("Bad validation") } catch {}
      let (commands, sleeps) = await f.snapshot()
      XCTAssertFalse(commands.contains(.flashPinnedBrick(serial: "FIXTURE"))); XCTAssertTrue(sleeps.isEmpty)
      XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
    }
  }
  func testWaitFailurePersistsIncompleteIntentAndCannotReplay() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = UnlockFixture(.waitFailure)
    do { _ = try await e.unlockPinnedDevice(requestID: req.id, transport: f, clock: f); XCTFail("Lost wait failure") } catch {}
    let data = try Data(contentsOf: e.store.root.appendingPathComponent("unlock-powered-wait.json"))
    let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(record["elapsedSeconds"] as? Int, 0); XCTAssertEqual(record["complete"] as? Bool, false)
    XCTAssertNil(try e.status().pendingApproval); XCTAssertEqual(try e.status().phase, .inspectionRequired)
    XCTAssertEqual(try e.poweredWaitStatus()?.elapsedSeconds, 0)
  }
}
