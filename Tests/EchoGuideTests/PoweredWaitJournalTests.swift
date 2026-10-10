import XCTest
@testable import EchoGuideCore

private actor JournalUnlockFixture: UnlockTransport, UnlockClock {
  var flashes = 0
  var ticks = 0
  func validate(session: SessionRecord, profile: CompatibilityProfile) async throws -> UnlockValidation {
    UnlockValidation(vmID: session.guest!.vmID, hostKeyFingerprint: session.guest!.hostKeyFingerprint,
      clientSHA256: try profile.artifact(named: "fastboot").sha256,
      payloadSHA256: try profile.artifact(named: "fastbrick-20240709.img").sha256, ready: true)
  }
  func execute(_ command: UnlockCommand, timeoutSeconds: Int) async throws -> CommandResult {
    switch command {
    case .getvar(_, let key):
      let p = try CompatibilityProfile.bundled()
      let value = key == "product" ? p.product : key == "unlock_status" ? "false" : p.lkBuild
      return CommandResult(stdout: key + ": " + value + "\n")
    case .flashPinnedBrick:
      flashes += 1; return CommandResult(stdout: "unexpected", exitCode: 124)
    }
  }
  func sleep(seconds: Int) async throws {}
  func poweredWaitSecond() async throws { ticks += 1 }
  func counts() -> (Int, Int) { (flashes, ticks) }
}
private final class JournalFixture: @unchecked Sendable {
  let lock = NSLock()
  var elapsed: [Int] = []
  var progress: [Int] = []
  let failAt: Int
  init(failAt: Int) { self.failAt = failAt }
  func write(_ record: PoweredWaitRecord, _ url: URL) throws {
    lock.lock(); elapsed.append(record.elapsedSeconds); lock.unlock()
    if record.elapsedSeconds >= failAt { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
  }
  func report(_ value: UnlockProgress) { lock.lock(); progress.append(value.poweredWaitElapsedSeconds); lock.unlock() }
  func snapshot() -> ([Int], [Int]) { lock.lock(); defer { lock.unlock() }; return (elapsed, progress) }
}
final class PoweredWaitJournalTests: XCTestCase {
  private func fixture() throws -> (WorkflowEngine, ApprovalRequest) {
    let e = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    let id = UUID()
    try e.store.transaction { s in
      s.phase = .identified; s.vmID = id.uuidString
      s.device = DeviceIdentity(serial: "FIXTURE", product: e.profile.product, lkBuild: e.profile.lkBuild)
      s.guest = GuestWorkspaceRecord(vmID: id, address: "fixture", hostKeyFingerprint: "key", checkedAt: Date(), ready: true)
    }
    return (e, try e.requestApproval(action: .unlock))
  }
  func testJournalFailureAfterAttemptCannotShortenPoweredWait() async throws {
    let (engine, request) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let transport = JournalUnlockFixture(); let journal = JournalFixture(failAt: 1)
    do {
      _ = try await engine.unlockPinnedDevice(requestID: request.id, transport: transport, clock: transport,
        progress: { journal.report($0) }, journalWriter: { try journal.write($0, $1) })
      XCTFail("Journal error must surface after full wait")
    } catch { XCTAssertEqual(BackendDiagnostic(error: error).code, .interruptedOperation) }
    let (flashes, ticks) = await transport.counts()
    XCTAssertEqual(flashes, 1); XCTAssertEqual(ticks, 300)
    let (writes, progress) = journal.snapshot()
    XCTAssertEqual(writes, Array(0...300)); XCTAssertEqual(progress, Array(0...300))
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
    XCTAssertNil(try engine.status().pendingApproval)
    XCTAssertFalse(try engine.poweredWaitStatus()!.complete)
  }
  func testInitialIntentFailureBlocksAllAttemptsAndWait() async throws {
    let (engine, request) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let transport = JournalUnlockFixture(); let journal = JournalFixture(failAt: 0)
    do {
      _ = try await engine.unlockPinnedDevice(requestID: request.id, transport: transport, clock: transport,
        journalWriter: { try journal.write($0, $1) })
      XCTFail("Missing durable intent")
    } catch {}
    let (flashes, ticks) = await transport.counts()
    XCTAssertEqual(flashes, 0); XCTAssertEqual(ticks, 0)
    XCTAssertEqual(journal.snapshot().0, [0])
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
  }
}
