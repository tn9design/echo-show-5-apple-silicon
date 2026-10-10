import XCTest
@testable import EchoGuideCore

final class ConfiguredROMTests: XCTestCase {
  func testPinnedPublisherROMSelectionWhenFixtureProvided() async throws {
    guard let path = ProcessInfo.processInfo.environment["ECHOGUIDE_TEST_PINNED_ROM"] else {
      throw XCTSkip("Set ECHOGUIDE_TEST_PINNED_ROM to the verified publisher ROM for read-only fixture validation")
    }
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction {
      $0.phase = .backedUp
      $0.device = DeviceIdentity(serial: "FIXTURE", product: engine.profile.product,
        lkBuild: "recovery", recoveryVersion: engine.profile.recoveryVersion)
      $0.stagedROMHash = "stale"
      $0.pendingApproval = ApprovalRequest(id: UUID(), action: .install, device: $0.device!,
        createdAt: Date(), sessionID: $0.id, prerequisitesDigest: "stale")
    }
    let selected = URL(fileURLWithPath: path)
    try await engine.configureROM(localROM: selected)
    let state = try engine.status()
    XCTAssertEqual(state.configuredROMPath, selected.standardizedFileURL.path)
    XCTAssertNil(state.pendingApproval)
    XCTAssertNil(state.stagedROMHash)
    XCTAssertEqual(state.phase, .backedUp)
    XCTAssertEqual(state.operations.last?.action, "configure_rom")
    XCTAssertEqual(state.operations.last?.result, "completed")
  }

  func testMissingNativeConfigurationCannotStage() async throws {
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { _ = try await engine.stageConfiguredROM(); XCTFail("Missing configuration accepted") } catch {}
    XCTAssertTrue(try engine.status().operations.isEmpty)
  }
  func testWrongSizeAndSymlinkDoNotRecordSelection() async throws {
    for symlink in [false, true] {
      let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
      defer { try? FileManager.default.removeItem(at: engine.store.root) }
      try engine.store.transaction { $0.phase = .backedUp }
      let file = engine.store.root.appendingPathComponent("ROM.zip")
      try Data("not pinned".utf8).write(to: file)
      let selected = symlink ? engine.store.root.appendingPathComponent("link.zip") : file
      if symlink { try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: file) }
      do { try await engine.configureROM(localROM: selected); XCTFail("Invalid ROM accepted") } catch {}
      XCTAssertNil(try engine.status().configuredROMPath)
      XCTAssertNil(try engine.status().stagedROMHash)
    }
  }
  func testConfiguredPathCannotBypassArtifactValidation() async throws {
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let file = engine.store.root.appendingPathComponent("bad.zip")
    try Data("bad".utf8).write(to: file)
    try engine.store.transaction {
      $0.phase = .backedUp; $0.configuredROMPath = file.path; $0.adbPath = "/fixture/adb"
      $0.device = DeviceIdentity(serial: "FIXTURE", product: engine.profile.product,
        lkBuild: "recovery", recoveryVersion: engine.profile.recoveryVersion)
    }
    do { _ = try await engine.stageConfiguredROM(); XCTFail("Bypassed artifact") } catch {}
    XCTAssertNil(try engine.status().stagedROMHash)
    XCTAssertFalse(FileManager.default.fileExists(atPath: engine.store.root.appendingPathComponent("staged-rom-receipt.json").path))
  }
}
