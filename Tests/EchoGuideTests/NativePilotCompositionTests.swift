#if canImport(AppKit)
import AppKit
import XCTest
@testable import EchoGuideCore

@MainActor
final class NativePilotCompositionTests: XCTestCase {
  private let selection = NativePilotSelection(utm: URL(fileURLWithPath: "/fixture/UTM.app"),
    unlockPayload: URL(fileURLWithPath: "/fixture/payload.img"))
  private func fixture(guest: Bool = true) throws -> (WorkflowEngine, ApprovalRequest) {
    let e = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    let id = UUID()
    try e.store.transaction {
      $0.phase = .identified
      $0.device = DeviceIdentity(serial: "FIXTURE", product: e.profile.product, lkBuild: e.profile.lkBuild)
      if guest { $0.vmID = id.uuidString; $0.guest = GuestWorkspaceRecord(vmID: id,
        address: "192.168.64.7", hostKeyFingerprint: "fixture-key", checkedAt: Date(), ready: true) }
    }
    return (e, try e.requestApproval(action: .unlock))
  }
  func testDefaultFactoryGateRefusesBeforeNativeUI() throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    XCTAssertThrowsError(try NativePilotComposition.make(engine: e, requestID: req.id,
      selection: selection, window: nil))
    XCTAssertTrue(try e.status().operations.isEmpty)
  }
  func testMissingGuestAndPayloadRefuseCompositionWithoutProbes() throws {
    let (e, req) = try fixture(guest: false); defer { try? FileManager.default.removeItem(at: e.store.root) }
    XCTAssertThrowsError(try NativePilotComposition.make(engine: e, requestID: req.id,
      selection: selection, window: nil, gate: .experimentalOptIn))
    let (withGuest, second) = try fixture(); defer { try? FileManager.default.removeItem(at: withGuest.store.root) }
    XCTAssertThrowsError(try NativePilotComposition.make(engine: withGuest, requestID: second.id,
      selection: NativePilotSelection(utm: selection.utm, unlockPayload: nil), window: nil,
      gate: .experimentalOptIn))
    XCTAssertTrue(try withGuest.status().operations.isEmpty)
  }
  func testNilOwningWindowCannotCreateRunnablePilotOwner() throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    XCTAssertThrowsError(try NativePilotComposition.make(engine: e, requestID: req.id,
      selection: selection, window: nil, gate: .experimentalOptIn)) { error in
      XCTAssertTrue(error.localizedDescription.contains("owning native window"))
    }
  }
  func testRecoveryInstallationNeedsNoGuestUTMOrBootloaderProofToCompose() throws {
    let (e, original) = try fixture(guest: false); defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction {
      $0.phase = .backedUp; $0.adbPath = "/fixture/adb"; $0.configuredROMPath = "/fixture/ROM.zip"
      $0.backupManifest = "/fixture/manifest.json"
      $0.stagedROMHash = try e.profile.artifact(named: ROMStagingAdapter.filename).sha256
      $0.device = DeviceIdentity(serial: "FIXTURE", product: e.profile.product,
        lkBuild: "not verified in recovery", recoveryVersion: e.profile.recoveryVersion)
      $0.pendingApproval = ApprovalRequest(id: original.id, action: .install, device: $0.device!,
        createdAt: original.createdAt, sessionID: $0.id, prerequisitesDigest: "fixture")
    }
    XCTAssertThrowsError(try NativePilotComposition.make(engine: e, requestID: original.id,
      selection: NativePilotSelection(utm: nil, unlockPayload: nil), window: nil,
      gate: .experimentalOptIn)) { error in
      // All recovery-entry composition prerequisites passed; only a real native
      // owning window is missing. No alert, host probe, or device command ran.
      XCTAssertTrue(error.localizedDescription.contains("owning native window"))
    }
  }
  func testNativeSummaryIncludesExactActionIdentityExpiryAndArtifact() throws {
    let (e, req) = try fixture(); defer { try? FileManager.default.removeItem(at: e.store.root) }
    let hash = try e.profile.artifact(named: "fastbrick-20240709.img").sha256
    let summary = NativeApprovalSummary(requestID: req.id, sessionID: req.sessionID, action: req.action,
      device: req.device, evidenceFingerprint: req.prerequisitesDigest,
      expiresAt: req.createdAt.addingTimeInterval(300), selection: selection, pinnedArtifactSHA256: hash)
    let text = NativePilotComposition.summaryText(summary)
    for expected in ["FIXTURE", e.profile.product, e.profile.lkBuild, hash, "Expires:", "Permanent device damage", selection.utm!.path] {
      XCTAssertTrue(text.contains(expected))
    }
  }
}
#endif
