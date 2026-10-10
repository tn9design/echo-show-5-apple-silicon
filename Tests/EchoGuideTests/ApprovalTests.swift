import XCTest
@testable import EchoGuideCore

final class ApprovalTests: XCTestCase {
  func fixture() throws -> (SessionRecord, CompatibilityProfile, ApprovalPrerequisites, ApprovalRequest) {
    let profile = try CompatibilityProfile.bundled()
    var session = SessionRecord(profileID: profile.id)
    session.phase = .identified
    session.device = DeviceIdentity(serial: "FIXTURE", product: profile.product, lkBuild: profile.lkBuild)
    let evidence = try ApprovalPrerequisites(session: session, action: .unlock, profile: profile)
    let request = ApprovalRequest(id: UUID(), action: .unlock, device: session.device!,
      createdAt: Date(timeIntervalSince1970: 1000), sessionID: session.id,
      prerequisitesDigest: try evidence.digest())
    return (session, profile, evidence, request)
  }
  func testCurrentEvidencePassesPolicyWithoutDispatch() throws {
    let (_, _, evidence, request) = try fixture()
    XCTAssertNoThrow(try ApprovalPolicy.validate(request, requestID: request.id, current: evidence,
      now: Date(timeIntervalSince1970: 1001)))
  }
  func testClockRollbackAndExactExpiryFail() throws {
    let (_, _, evidence, request) = try fixture()
    for instant in [999.0, 1300.0, 1301.0] {
      XCTAssertThrowsError(try ApprovalPolicy.validate(request, requestID: request.id,
        current: evidence, now: Date(timeIntervalSince1970: instant)))
    }
  }
  func testWrongRequestAndChangedIdentityFail() throws {
    var (session, profile, evidence, request) = try fixture()
    XCTAssertThrowsError(try ApprovalPolicy.validate(request, requestID: UUID(), current: evidence,
      now: Date(timeIntervalSince1970: 1001)))
    session.device?.serial = "DIFFERENT"
    evidence = try ApprovalPrerequisites(session: session, action: .unlock, profile: profile)
    XCTAssertThrowsError(try ApprovalPolicy.validate(request, requestID: request.id, current: evidence,
      now: Date(timeIntervalSince1970: 1001)))
  }
  func testPinnedProfileArtifactChangeInvalidatesDigest() throws {
    let (session, profile, first, _) = try fixture()
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
    var artifacts = object["artifacts"] as! [[String: Any]]
    artifacts[0]["sha256"] = String(repeating: "0", count: 64)
    object["artifacts"] = artifacts
    let changed = try JSONDecoder().decode(CompatibilityProfile.self,
      from: JSONSerialization.data(withJSONObject: object))
    let second = try ApprovalPrerequisites(session: session, action: .unlock, profile: changed)
    XCTAssertNotEqual(try first.digest(), try second.digest())
  }
  func testChangedVMAndPhaseInvalidateEvidence() throws {
    let (initial, profile, _, request) = try fixture()
    var changed = initial
    changed.vmID = UUID().uuidString
    let newVM = try ApprovalPrerequisites(session: changed, action: .unlock, profile: profile)
    XCTAssertThrowsError(try ApprovalPolicy.validate(request, requestID: request.id, current: newVM,
      now: Date(timeIntervalSince1970: 1001)))
    changed = initial
    changed.phase = .inspectionRequired
    let newPhase = try ApprovalPrerequisites(session: changed, action: .unlock, profile: profile)
    XCTAssertThrowsError(try ApprovalPolicy.validate(request, requestID: request.id, current: newPhase,
      now: Date(timeIntervalSince1970: 1001)))
  }
  func testManifestContentChangesDigest() throws {
    var (session, profile, _, _) = try fixture()
    session.phase = .backedUp
    let first = try ApprovalPrerequisites(session: session, action: .install, profile: profile,
      backupManifestData: Data("first manifest".utf8))
    let second = try ApprovalPrerequisites(session: session, action: .install, profile: profile,
      backupManifestData: Data("changed manifest".utf8))
    XCTAssertNotEqual(try first.digest(), try second.digest())
    XCTAssertThrowsError(try ApprovalPrerequisites(session: session, action: .install, profile: profile))
  }
  func testGuestTrustChangeInvalidatesDigest() throws {
    var (session, profile, _, _) = try fixture()
    let id = UUID()
    session.vmID = id.uuidString
    session.guest = GuestWorkspaceRecord(vmID: id, address: "192.0.2.1", hostKeyFingerprint: "first",
      checkedAt: Date(timeIntervalSince1970: 900), ready: true)
    let first = try ApprovalPrerequisites(session: session, action: .unlock, profile: profile)
    session.guest = GuestWorkspaceRecord(vmID: id, address: "192.0.2.1", hostKeyFingerprint: "changed",
      checkedAt: Date(timeIntervalSince1970: 900), ready: true)
    let second = try ApprovalPrerequisites(session: session, action: .unlock, profile: profile)
    XCTAssertNotEqual(try first.digest(), try second.digest())
  }
}
