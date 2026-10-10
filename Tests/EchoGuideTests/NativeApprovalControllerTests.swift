import XCTest
@testable import EchoGuideCore

private actor ApprovalDispatchCounter {
  var value = 0
  func called() { value += 1 }
  func count() -> Int { value }
}
@MainActor
final class NativeApprovalControllerTests: XCTestCase {
  private let selection = NativePilotSelection(utm: URL(fileURLWithPath: "/fixture/UTM.app"),
    unlockPayload: URL(fileURLWithPath: "/fixture/payload.img"))
  private func fixture() throws -> (WorkflowEngine, ApprovalRequest) {
    let e = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    try e.store.transaction {
      $0.phase = .identified
      $0.device = DeviceIdentity(serial: "FIXTURE", product: e.profile.product, lkBuild: e.profile.lkBuild)
    }
    return (e, try e.requestApproval(action: .unlock))
  }
  private func controller(_ e: WorkflowEngine, count: ApprovalDispatchCounter,
    gate: NativePilotGate = .experimentalOptIn,
    presenter: @escaping NativeApprovalController.Presenter) -> NativeApprovalController {
    NativeApprovalController(engine: e, gate: gate, presenter: presenter, dispatch: { _, _, _ in
      await count.called()
      return .recoveryInspectionRequired(UnlockOutcome(attempts: 1, reason: "fixture"))
    }, validateSelection: { _, _ in })
  }
  func testDisabledGateDoesNotPresentOrDispatch() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let count = ApprovalDispatchCounter()
    let c = controller(e, count: count, gate: .disabled) { _ in XCTFail("Presented"); return .confirm }
    do { _ = try await c.confirm(requestID: req.id, selection: selection); XCTFail("Gate") } catch {}
    let calls = await count.count(); XCTAssertEqual(calls, 0)
  }
  func testCancelRejectsWithoutDispatch() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let count = ApprovalDispatchCounter(); let c = controller(e, count: count) { _ in .cancel }
    let result = try await c.confirm(requestID: req.id, selection: selection)
    XCTAssertNil(result); XCTAssertNil(try e.status().pendingApproval)
    let calls = await count.count(); XCTAssertEqual(calls, 0)
  }
  func testChangedDeviceDuringReviewCannotDispatch() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let count = ApprovalDispatchCounter()
    let c = controller(e, count: count) { summary in
      XCTAssertEqual(summary.device.serial, "FIXTURE"); XCTAssertEqual(summary.requestID, req.id)
      try e.store.transaction { $0.device?.serial = "OTHER" }
      return .confirm
    }
    do { _ = try await c.confirm(requestID: req.id, selection: selection); XCTFail("Changed device") } catch {}
    let calls = await count.count(); XCTAssertEqual(calls, 0)
  }
  func testExpiredRequestDoesNotPresent() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let count = ApprovalDispatchCounter()
    let c = NativeApprovalController(engine: e, gate: .experimentalOptIn, presenter: { _ in
      XCTFail("Expired request shown"); return .confirm
    }, dispatch: { _, _, _ in await count.called(); return .installedAwaitingUserStartup },
      validateSelection: { _, _ in }, now: { req.createdAt.addingTimeInterval(301) })
    do { _ = try await c.confirm(requestID: req.id, selection: selection); XCTFail("Expired") } catch {}
    let calls = await count.count(); XCTAssertEqual(calls, 0)
  }
  func testWindowClosureInvalidatesConfirmedReview() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let count = ApprovalDispatchCounter()
    var c: NativeApprovalController!
    c = controller(e, count: count) { _ in c.invalidateForClosure(); return .confirm }
    do { _ = try await c.confirm(requestID: req.id, selection: selection); XCTFail("Closed") } catch {}
    let calls = await count.count(); XCTAssertEqual(calls, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testCancelledPresentationDoesNotDispatch() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let count = ApprovalDispatchCounter()
    let c = controller(e, count: count) { _ in
      try await Task.sleep(nanoseconds: 100_000_000)
      return .confirm
    }
    let selected = selection
    let worker = Task { try await c.confirm(requestID: req.id, selection: selected) }
    try await Task.sleep(nanoseconds: 5_000_000)
    worker.cancel()
    do { _ = try await worker.value; XCTFail("Cancelled confirmation") } catch {}
    let calls = await count.count(); XCTAssertEqual(calls, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testSameIDChangedActionCannotDispatchDifferentAction() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let count = ApprovalDispatchCounter()
    let c = controller(e, count: count) { _ in
      try e.store.transaction { $0.pendingApproval = ApprovalRequest(id: req.id, action: .install,
        device: req.device, createdAt: req.createdAt, sessionID: req.sessionID,
        prerequisitesDigest: req.prerequisitesDigest) }
      return .confirm
    }
    do { _ = try await c.confirm(requestID: req.id, selection: selection); XCTFail("Changed action") } catch {}
    let calls = await count.count(); XCTAssertEqual(calls, 0)
  }
  func testConfirmedUnchangedSummaryHandsOffExactIDAndSelection() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let expected = selection; let count = ApprovalDispatchCounter()
    let c = NativeApprovalController(engine: e, gate: .experimentalOptIn, presenter: { summary in
      XCTAssertEqual(summary.selection, expected); XCTAssertEqual(summary.evidenceFingerprint, req.prerequisitesDigest)
      return .confirm
    }, dispatch: { id, selected, _ in
      XCTAssertEqual(id, req.id); XCTAssertEqual(selected, expected); await count.called()
      return .recoveryInspectionRequired(UnlockOutcome(attempts: 1, reason: "fixture"))
    }, validateSelection: { _, _ in })
    _ = try await c.confirm(requestID: req.id, selection: expected)
    let calls = await count.count(); XCTAssertEqual(calls, 1)
  }
}
