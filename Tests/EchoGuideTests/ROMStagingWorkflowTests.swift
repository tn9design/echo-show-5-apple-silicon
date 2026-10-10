import Foundation
import XCTest
@testable import EchoGuideCore

private actor NoStagingCommands: BinaryCommandRunning {
  var calls = 0
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    calls += 1; throw GuideError.stopped("Unexpected command in workflow fixture")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    calls += 1; throw GuideError.stopped("Unexpected command in workflow fixture")
  }
  func count() -> Int { calls }
}
private struct FixtureROMStager: ROMStaging {
  let mutate: (@Sendable () throws -> Void)?
  let wrongReceipt: Bool
  func stage(adb: String, serial: String, localROM: URL, artifact: Artifact,
             evidenceURL: URL) async throws -> ROMStagingAdapter.Receipt {
    let receipt = ROMStagingAdapter.Receipt(serial: serial, destination: ROMStagingAdapter.destination,
      sha256: wrongReceipt ? String(repeating: "0", count: 64) : artifact.sha256,
      bytes: artifact.size!, verifiedAt: Date())
    try JSONEncoder().encode(receipt).write(to: evidenceURL)
    try mutate?()
    return receipt
  }
}

final class ROMStagingWorkflowTests: XCTestCase {
  private func fixture(backups: Bool = true) throws -> (WorkflowEngine, NoStagingCommands) {
    let runner = NoStagingCommands()
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let engine = try WorkflowEngine(root: root, runner: runner)
    var manifest: String?
    if backups {
      let folder = root.appendingPathComponent("backups")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      var entries: [VerifiedPartitionBackup] = []
      for (index, name) in ["boot", "recovery", "system", "userdata", "metadata"].enumerated() {
        let file = folder.appendingPathComponent(name + ".img")
        try Data(repeating: UInt8(index), count: 1_048_576).write(to: file)
        entries.append(VerifiedPartitionBackup(partition: Partition(name: name,
          device: "/dev/block/mmcblk0p\(index + 1)", size: 1_048_576), filename: file.lastPathComponent,
          sha256: try RecoveryAdapter.hash(file)))
      }
      let path = folder.appendingPathComponent("verified-backups.json")
      try JSONEncoder().encode(entries).write(to: path)
      manifest = path.path
    }
    try engine.store.transaction { state in
      state.phase = .backedUp
      state.device = DeviceIdentity(serial: "FIXTURE", product: engine.profile.product,
        lkBuild: "not verified in recovery", recoveryVersion: engine.profile.recoveryVersion)
      state.backupManifest = manifest
    }
    return (engine, runner)
  }
  func testMissingBackupsStopWithoutCommands() async throws {
    let (engine, runner) = try fixture(backups: false)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do {
      _ = try await engine.stagePinnedROM(adb: URL(fileURLWithPath: "/fixture/adb"),
        localROM: URL(fileURLWithPath: "/fixture/ROM"), staging: FixtureROMStager(mutate: nil, wrongReceipt: false))
      XCTFail("Missing backups accepted")
    } catch {}
    XCTAssertNil(try engine.status().stagedROMHash)
    XCTAssertEqual(try engine.status().operations.last?.result, "failed; inspection required")
    let count = await runner.count(); XCTAssertEqual(count, 0)
  }
  func testVerifiedReceiptBindsToSessionWithoutInstall() async throws {
    let (engine, runner) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let receipt = try await engine.stagePinnedROM(adb: URL(fileURLWithPath: "/fixture/adb"),
      localROM: URL(fileURLWithPath: "/fixture/ROM"), staging: FixtureROMStager(mutate: nil, wrongReceipt: false))
    let state = try engine.status()
    XCTAssertEqual(state.stagedROMHash, receipt.sha256)
    XCTAssertEqual(state.phase, .backedUp)
    XCTAssertEqual(state.operations.last?.action, "stage_rom")
    XCTAssertNil(state.pendingApproval)
    let request = try engine.requestApproval(action: .install)
    XCTAssertThrowsError(try engine.approve(requestID: request.id))
    let count = await runner.count(); XCTAssertEqual(count, 0)
  }
  func testWrongReceiptCannotRecordStaging() async throws {
    let (engine, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do {
      _ = try await engine.stagePinnedROM(adb: URL(fileURLWithPath: "/fixture/adb"),
        localROM: URL(fileURLWithPath: "/fixture/ROM"), staging: FixtureROMStager(mutate: nil, wrongReceipt: true))
      XCTFail("Incorrect receipt accepted")
    } catch {}
    XCTAssertNil(try engine.status().stagedROMHash)
  }
  func testCorruptedBackupStopsBeforeStaging() async throws {
    let (engine, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let file = engine.store.root.appendingPathComponent("backups/boot.img")
    try Data(repeating: 99, count: 1_048_576).write(to: file)
    do {
      _ = try await engine.stagePinnedROM(adb: URL(fileURLWithPath: "/fixture/adb"),
        localROM: URL(fileURLWithPath: "/fixture/ROM"), staging: FixtureROMStager(mutate: nil, wrongReceipt: false))
      XCTFail("Corrupted backup accepted")
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: engine.store.root.appendingPathComponent("staged-rom-receipt.json").path))
    XCTAssertNil(try engine.status().stagedROMHash)
  }
  func testChangedDeviceDuringCopyCannotRecordStaging() async throws {
    let (engine, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let stager = FixtureROMStager(mutate: { try engine.store.transaction { $0.device?.serial = "OTHER" } }, wrongReceipt: false)
    do {
      _ = try await engine.stagePinnedROM(adb: URL(fileURLWithPath: "/fixture/adb"),
        localROM: URL(fileURLWithPath: "/fixture/ROM"), staging: stager)
      XCTFail("Changed device accepted")
    } catch {}
    XCTAssertNil(try engine.status().stagedROMHash)
  }
}
