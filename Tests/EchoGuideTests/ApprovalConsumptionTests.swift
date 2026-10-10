import XCTest
@testable import EchoGuideCore

private actor ConsumptionCount {
  var value = 0
  func increment() { value += 1 }
  func count() -> Int { value }
}

final class ApprovalConsumptionTests: XCTestCase {
  private func fixture() throws -> (WorkflowEngine, ApprovalRequest, FreshApprovalEvidence, Date) {
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    let now = Date(timeIntervalSince1970: 1700000000)
    var session = SessionRecord(profileID: engine.profile.id)
    session.phase = .identified
    session.device = DeviceIdentity(serial: "FIXTURE", product: engine.profile.product, lkBuild: engine.profile.lkBuild)
    let prerequisites = try ApprovalPrerequisites(session: session, action: .unlock, profile: engine.profile)
    let request = ApprovalRequest(id: UUID(), action: .unlock, device: session.device!,
      createdAt: now, sessionID: session.id, prerequisitesDigest: try prerequisites.digest())
    session.pendingApproval = request
    try engine.store.transaction { $0 = session }
    return (engine, request, FreshApprovalEvidence(prerequisites: prerequisites, checkedAt: now), now)
  }
  func testConsumptionCommitsBeforeCallbackAndCannotBeReused() async throws {
    let (engine, request, evidence, now) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let counter = ConsumptionCount()
    try await engine.withConsumedApproval(requestID: request.id, evidence: evidence, now: now) { consumed in
      XCTAssertEqual(consumed.requestID, request.id)
      let state = try engine.status()
      XCTAssertNil(state.pendingApproval)
      XCTAssertEqual(state.phase, .inspectionRequired)
      XCTAssertNil(state.operations.last?.completedAt)
      await counter.increment()
    }
    do {
      try await engine.withConsumedApproval(requestID: request.id, evidence: evidence, now: now) { _ in await counter.increment() }
      XCTFail("Consumed approval reused")
    } catch {}
    let count = await counter.count(); XCTAssertEqual(count, 1)
    XCTAssertFalse(try engine.status().startupConfirmed)
  }
  func testCallbackFailureNeverRestoresApproval() async throws {
    let (engine, request, evidence, now) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do {
      try await engine.withConsumedApproval(requestID: request.id, evidence: evidence, now: now) { _ in
        throw GuideError.stopped("Fixture callback outcome unknown")
      }
      XCTFail("Failure lost")
    } catch {}
    let state = try engine.status()
    XCTAssertNil(state.pendingApproval)
    XCTAssertEqual(state.phase, .inspectionRequired)
    XCTAssertEqual(state.operations.last?.result, "failed; inspection required")
  }
  func testConcurrentConsumerCannotEnterCallback() async throws {
    let (engine, request, evidence, now) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let counter = ConsumptionCount()
    try await engine.withConsumedApproval(requestID: request.id, evidence: evidence, now: now) { _ in
      await counter.increment()
      do {
        try await engine.withConsumedApproval(requestID: request.id, evidence: evidence, now: now) { _ in await counter.increment() }
        XCTFail("Concurrent consumer acquired operation ownership")
      } catch {}
    }
    let count = await counter.count(); XCTAssertEqual(count, 1)
    XCTAssertEqual(try engine.status().operations.count, 1)
  }
  func testStaleAndFutureEvidenceNeverEnterCallback() async throws {
    for checkedAt in [1700000001.0, 1699999970.0] {
      let (engine, request, evidence, now) = try fixture()
      defer { try? FileManager.default.removeItem(at: engine.store.root) }
      let counter = ConsumptionCount()
      do {
        try await engine.withConsumedApproval(requestID: request.id,
          evidence: FreshApprovalEvidence(prerequisites: evidence.prerequisites,
            checkedAt: Date(timeIntervalSince1970: checkedAt)), now: now) { _ in await counter.increment() }
        XCTFail("Expired evidence accepted")
      } catch {}
      let count = await counter.count(); XCTAssertEqual(count, 0)
    }
  }
  func testChangedSessionNeverEntersCallback() async throws {
    let (engine, request, evidence, now) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction { $0.device?.serial = "OTHER" }
    let counter = ConsumptionCount()
    do {
      try await engine.withConsumedApproval(requestID: request.id, evidence: evidence, now: now) { _ in await counter.increment() }
      XCTFail("Changed device accepted")
    } catch {}
    let count = await counter.count(); XCTAssertEqual(count, 0)
  }
  func testInterruptedConsumptionCannotResume() async throws {
    let (engine, request, evidence, now) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction {
      $0.pendingApproval = nil
      $0.operations.append(OperationRecord(id: UUID(), action: "consume_native_approval", startedAt: now))
    }
    let counter = ConsumptionCount()
    do {
      try await engine.withConsumedApproval(requestID: request.id, evidence: evidence, now: now) { _ in await counter.increment() }
      XCTFail("Interrupted consumption resumed")
    } catch {}
    let count = await counter.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
  }
}
