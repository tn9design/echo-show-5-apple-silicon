import XCTest
@testable import EchoGuideCore

private actor NativePilotFixture: UnlockTransport, UnlockClock {
  var calls = 0
  func count() -> Int { calls }
  func validate(session: SessionRecord, profile: CompatibilityProfile) async throws -> UnlockValidation {
    calls += 1
    return UnlockValidation(vmID: session.guest!.vmID, hostKeyFingerprint: session.guest!.hostKeyFingerprint,
      clientSHA256: try profile.artifact(named: "fastboot").sha256,
      payloadSHA256: try profile.artifact(named: "fastbrick-20240709.img").sha256, ready: true)
  }
  func execute(_ command: UnlockCommand, timeoutSeconds: Int) async throws -> CommandResult {
    calls += 1
    let p = try CompatibilityProfile.bundled()
    switch command {
    case .getvar(_, let key):
      let value = key == "product" ? p.product : key == "unlock_status" ? "false" : p.lkBuild
      return CommandResult(stdout: key + ": " + value, stderr: "", exitCode: 0)
    case .flashPinnedBrick:
      return CommandResult(stdout: "unexpected", stderr: "", exitCode: 0)
    }
  }
  func sleep(seconds: Int) async throws {}
  func poweredWaitSecond() async throws {}
}
final class NativePilotDispatcherTests: XCTestCase {
  private func fixture() throws -> (WorkflowEngine, ApprovalRequest) {
    let e = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    let id = UUID()
    try e.store.transaction {
      $0.phase = .identified; $0.vmID = id.uuidString
      $0.device = DeviceIdentity(serial: "FIXTURE", product: e.profile.product, lkBuild: e.profile.lkBuild)
      $0.guest = GuestWorkspaceRecord(vmID: id, address: "fixture", hostKeyFingerprint: "key", checkedAt: Date(), ready: true)
    }
    return (e, try e.requestApproval(action: .unlock))
  }
  private func host(_ supported: Bool) -> HostInspection {
    HostInspection(architecture: "arm64", macOS: "27", writingBackendSupported: supported,
      usbInspectionAvailable: true, devices: [], nextAction: "fixture")
  }
  func testDefaultGateNeverInspectsOrDispatches() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture()
    let dispatcher = NativePilotDispatcher(engine: e, environment: { _ in
      XCTFail("Disabled gate inspected environment"); throw GuideError.stopped("Fixture")
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Gate bypassed") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testUnsupportedHostStopsUnderOwnershipBeforeDeviceOrConsumption() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture(); let host = host(false)
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      XCTAssertNil(try e.status().operations.last?.completedAt)
      return NativePilotEnvironmentProof(host: host, guest: current.guest!)
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Unsupported host") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testStaleGuestProofStopsBeforeDeviceOrConsumption() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture(); let host = host(true)
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      let guest = current.guest!
      return NativePilotEnvironmentProof(host: host, guest: GuestWorkspaceRecord(vmID: guest.vmID,
        address: guest.address, hostKeyFingerprint: guest.hostKeyFingerprint,
        checkedAt: Date().addingTimeInterval(-60), ready: true))
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Stale guest") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
  }
  func testInstallActionRoutesToCheckedInstallPrerequisites() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction {
      $0.adbPath = "/fixture/adb"
      $0.pendingApproval = ApprovalRequest(id: req.id, action: .install, device: req.device,
        createdAt: req.createdAt, sessionID: req.sessionID, prerequisitesDigest: req.prerequisitesDigest)
    }
    let f = NativePilotFixture(); let host = host(true)
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      NativePilotEnvironmentProof(host: host, guest: current.guest!)
    }, unlockTransport: f, clock: f)
    do { _ = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id); XCTFail("Install prerequisites bypassed") } catch {}
    let count = await f.count(); XCTAssertEqual(count, 0)
    XCTAssertEqual(try e.status().pendingApproval?.id, req.id)
    XCTAssertEqual(try e.status().phase, .inspectionRequired)
  }
  func testExperimentalCompositionNeverCallsTimeoutOrResponseSuccess() async throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let f = NativePilotFixture(); let host = host(true)
    let dispatcher = NativePilotDispatcher(engine: e, gate: .experimentalOptIn, environment: { current in
      NativePilotEnvironmentProof(host: host, guest: current.guest!)
    }, unlockTransport: f, clock: f)
    let result = try await dispatcher.dispatch(nativeConfirmedRequestID: req.id)
    guard case .recoveryInspectionRequired(let outcome) = result else { return XCTFail("Claimed install") }
    XCTAssertEqual(outcome.attempts, 1)
    XCTAssertNil(try e.status().pendingApproval); XCTAssertEqual(try e.status().phase, .inspectionRequired)
    XCTAssertThrowsError(try e.approve(requestID: req.id))
  }
}
