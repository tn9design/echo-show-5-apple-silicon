import XCTest
@testable import EchoGuideCore

private actor NativeValidationBarrier {
  var entered = false
  var continuation: CheckedContinuation<Void, Never>?
  func pause() async {
    entered = true
    await withCheckedContinuation { continuation = $0 }
  }
  func waitForEntry() async { while !entered { await Task.yield() } }
  func release() { continuation?.resume(); continuation = nil }
}
private actor NativeWriteCounter {
  var value = 0
  func write() { value += 1 }
  func count() -> Int { value }
}

@MainActor
final class NativeConfirmationLeaseTests: XCTestCase {
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
  private func controller(_ e: WorkflowEngine, barrier: NativeValidationBarrier,
                          writes: NativeWriteCounter) -> NativeApprovalController {
    NativeApprovalController(engine: e, gate: .experimentalOptIn, presenter: { _ in .confirm },
      dispatch: { id, _, lease in
        try await e.withFreshConsumedApproval(requestID: id, nativeLease: lease, validator: { state in
          await barrier.pause()
          return FreshApprovalEvidence(prerequisites: try ApprovalPrerequisites.capture(
            session: state, action: .unlock, profile: e.profile), checkedAt: Date())
        }, callback: { _ in
          await writes.write()
          return .recoveryInspectionRequired(UnlockOutcome(attempts: 1, reason: "fixture"))
        })
      }, validateSelection: { _, _ in })
  }
  func testWindowClosureDuringValidatorRevokesBeforeConsumptionOrWrite() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let barrier = NativeValidationBarrier(); let writes = NativeWriteCounter()
    let c = controller(e, barrier: barrier, writes: writes); let selected = selection
    let worker = Task { try await c.confirm(requestID: req.id, selection: selected) }
    await barrier.waitForEntry(); c.invalidateForClosure(); await barrier.release()
    do { _ = try await worker.value; XCTFail("Closed native lease consumed") } catch {}
    let count = await writes.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
    XCTAssertEqual(try e.status().phase, .inspectionRequired)
  }
  func testClosureDuringInitialSelectionValidationNeverPresentsApproval() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let barrier = NativeValidationBarrier(); let writes = NativeWriteCounter()
    let c = NativeApprovalController(engine: e, gate: .experimentalOptIn, presenter: { _ in
      XCTFail("Closed native review presented"); return .confirm
    }, dispatch: { _, _, _ in
      await writes.write(); return .installedAwaitingUserStartup
    }, validateSelection: { _, _ in await barrier.pause() })
    let selected = selection
    let worker = Task { try await c.confirm(requestID: req.id, selection: selected) }
    await barrier.waitForEntry(); c.invalidateForClosure(); await barrier.release()
    do { _ = try await worker.value; XCTFail("Closed initial validation") } catch {}
    let count = await writes.count(); XCTAssertEqual(count, 0)
  }
  func testCallerCancellationDuringValidatorRevokesBeforeConsumption() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let barrier = NativeValidationBarrier(); let writes = NativeWriteCounter()
    let c = controller(e, barrier: barrier, writes: writes); let selected = selection
    let worker = Task { try await c.confirm(requestID: req.id, selection: selected) }
    await barrier.waitForEntry(); worker.cancel(); await barrier.release()
    do { _ = try await worker.value; XCTFail("Cancelled native lease consumed") } catch {}
    let count = await writes.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testRevocationAfterConsumptionRetainsAllPoweredTicksDespiteCancellation() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let lease = NativeConfirmationLease(); let barrier = NativeValidationBarrier()
    let clock = PoweredWaitClock(testOnlyTickNanoseconds: 1_000)
    let worker = Task {
      try await e.withFreshConsumedApproval(requestID: req.id, nativeLease: lease, validator: { state in
        FreshApprovalEvidence(prerequisites: try ApprovalPrerequisites.capture(
          session: state, action: .unlock, profile: e.profile), checkedAt: Date())
      }, callback: { _ in
        XCTAssertNil(try e.status().pendingApproval)
        await barrier.pause()
        var ticks = 0
        for _ in 0..<300 { try await clock.poweredWaitSecond(); ticks += 1 }
        return ticks
      })
    }
    await barrier.waitForEntry(); lease.revoke(); worker.cancel(); await barrier.release()
    let ticks = try await worker.value; XCTAssertEqual(ticks, 300)
    XCTAssertNil(try e.status().pendingApproval)
    XCTAssertEqual(try e.status().phase, .inspectionRequired)
    XCTAssertThrowsError(try lease.consuming { 1 })
  }
  func testRevokedLeaseCannotEnterConsumptionBody() throws {
    let lease = NativeConfirmationLease(); lease.revoke()
    XCTAssertThrowsError(try lease.consuming { XCTFail("Revoked body ran") })
  }
}
