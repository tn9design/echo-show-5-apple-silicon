import Foundation
import XCTest
@testable import EchoGuideCore

private actor SupervisedInstallFixture: BinaryCommandRunning {
  enum Mode { case success, wrongRecovery, wrongZIP, failedInstall, failedReboot }
  let mode: Mode
  let artifact: Artifact
  var commands: [[String]] = []
  var installed = false
  var engine: WorkflowEngine?
  var wipeSawConsumedApproval = true
  init(mode: Mode, artifact: Artifact) { self.mode = mode; self.artifact = artifact }
  func bind(_ engine: WorkflowEngine) { self.engine = engine }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    commands.append(arguments)
    if arguments.last == "ro.product.device" {
      return CommandResult(stdout: mode == .wrongRecovery ? "other" : "checkers")
    }
    if arguments.last == "ro.twrp.version" { return CommandResult(stdout: "3.7.0_9-0") }
    if arguments.contains("sha256sum") {
      return CommandResult(stdout: (mode == .wrongZIP ? String(repeating: "0", count: 64) : artifact.sha256)
        + "  " + ROMStagingAdapter.destination + "\n")
    }
    if arguments.contains("stat") { return CommandResult(stdout: String(artifact.size!) + "\n") }
    if arguments.contains("wipe") {
      if try engine?.status().pendingApproval != nil { wipeSawConsumedApproval = false }
      return CommandResult(stdout: "")
    }
    if arguments.contains("install") {
      installed = true
      return CommandResult(stdout: "", exitCode: mode == .failedInstall ? 1 : 0)
    }
    if arguments.contains("/tmp/recovery.log") {
      var log = "prior recovery log\n"
      if installed {
        let code = mode == .failedInstall ? 1 : 0
        log += "Installing zip file '" + ROMStagingAdapter.destination
          + "'\nUpdater process ended with RC=\(code)\nI:operation_end - status=\(code)\n"
      }
      return CommandResult(stdout: log)
    }
    if arguments.last == "reboot" { return CommandResult(stdout: "", exitCode: mode == .failedReboot ? 1 : 0) }
    throw GuideError.stopped("Unexpected fixture command")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    throw GuideError.stopped("Unexpected capture in install fixture")
  }
  func snapshot() -> ([[String]], Bool) { (commands, wipeSawConsumedApproval) }
}

final class InstallWorkflowTests: XCTestCase {
  private func fixture(_ mode: SupervisedInstallFixture.Mode = .success) async throws
    -> (WorkflowEngine, SupervisedInstallFixture, ApprovalRequest) {
    let profile = try CompatibilityProfile.bundled()
    let runner = SupervisedInstallFixture(mode: mode, artifact: try profile.artifact(named: ROMStagingAdapter.filename))
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let engine = try WorkflowEngine(root: root, runner: runner)
    await runner.bind(engine)
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
    let manifest = folder.appendingPathComponent("verified-backups.json")
    try JSONEncoder().encode(entries).write(to: manifest)
    try engine.store.transaction {
      $0.device = DeviceIdentity(serial: "FIXTURE", product: profile.product,
        lkBuild: "not verified in recovery", recoveryVersion: profile.recoveryVersion)
      $0.phase = .backedUp
      $0.adbPath = "/fixture/adb"
      $0.backupManifest = manifest.path
      $0.stagedROMHash = try profile.artifact(named: ROMStagingAdapter.filename).sha256
      $0.startupConfirmed = true
      $0.postInstallObservations = [PostInstallObservation(check: .audio, outcome: .working,
        reportedAt: Date(), source: "old manual observation")]
    }
    return (engine, runner, try engine.requestApproval(action: .install))
  }
  func testVerifiedInstallConsumesBeforeWipeAndLeavesStartupUnconfirmed() async throws {
    let (engine, runner, request) = try await fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb"))
    let state = try engine.status()
    XCTAssertEqual(state.phase, .installed)
    XCTAssertFalse(state.startupConfirmed)
    XCTAssertNil(state.pendingApproval)
    XCTAssertNil(state.postInstallObservations)
    let (commands, consumed) = await runner.snapshot()
    XCTAssertTrue(consumed)
    XCTAssertEqual(commands.filter { $0.contains("wipe") }.map { $0.last! }, ["data", "system", "cache"])
    XCTAssertEqual(commands.last?.last, "reboot")
    XCTAssertTrue(FileManager.default.fileExists(atPath: engine.store.root.appendingPathComponent("install-recovery.log").path))
    let permissions = try FileManager.default.attributesOfItem(atPath: engine.store.root.appendingPathComponent("install-recovery.log").path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }
  func testWrongRecoveryStopsBeforeConsumptionAndWipe() async throws {
    let (engine, runner, request) = try await fixture(.wrongRecovery)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb")); XCTFail() } catch {}
    XCTAssertEqual(try engine.status().pendingApproval?.id, request.id)
    let (commands, _) = await runner.snapshot()
    XCTAssertFalse(commands.contains { $0.contains("wipe") })
  }
  func testWrongZIPStopsBeforeConsumptionAndWipe() async throws {
    let (engine, runner, request) = try await fixture(.wrongZIP)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb")); XCTFail() } catch {}
    XCTAssertEqual(try engine.status().pendingApproval?.id, request.id)
    let (commands, _) = await runner.snapshot()
    XCTAssertFalse(commands.contains { $0.contains("wipe") })
  }
  func testChangedBackupStopsBeforeConsumptionAndWipe() async throws {
    let (engine, runner, request) = try await fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try Data(repeating: 99, count: 1_048_576).write(to: engine.store.root.appendingPathComponent("backups/boot.img"))
    do { try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb")); XCTFail() } catch {}
    XCTAssertEqual(try engine.status().pendingApproval?.id, request.id)
    let (commands, _) = await runner.snapshot()
    XCTAssertFalse(commands.contains { $0.contains("wipe") })
  }
  func testFailedInstallSavesLogAndNeverRebootsOrRestoresApproval() async throws {
    let (engine, runner, request) = try await fixture(.failedInstall)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb")); XCTFail() } catch {}
    let state = try engine.status()
    XCTAssertEqual(state.phase, .inspectionRequired)
    XCTAssertNil(state.pendingApproval)
    let (commands, _) = await runner.snapshot()
    XCTAssertFalse(commands.contains { $0.last == "reboot" })
    XCTAssertTrue(FileManager.default.fileExists(atPath: engine.store.root.appendingPathComponent("install-recovery.log").path))
  }
  func testFailedRebootDoesNotMarkInstalled() async throws {
    let (engine, _, request) = try await fixture(.failedReboot)
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    do { try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb")); XCTFail() } catch {}
    XCTAssertEqual(try engine.status().phase, .inspectionRequired)
    XCTAssertNil(try engine.status().pendingApproval)
  }
  func testConsumedInstallCannotReplayAnyCommands() async throws {
    let (engine, runner, request) = try await fixture()
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb"))
    let before = await runner.snapshot().0.count
    do { try await engine.installPinnedROM(requestID: request.id, adb: URL(fileURLWithPath: "/fixture/adb")); XCTFail() } catch {}
    let after = await runner.snapshot().0.count
    XCTAssertEqual(before, after)
  }
}
