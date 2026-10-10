import XCTest
@testable import EchoGuideCore

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [BackupProgress] = []
  func append(_ value: BackupProgress) { lock.lock(); defer { lock.unlock() }; values.append(value) }
  func snapshot() -> [BackupProgress] { lock.lock(); defer { lock.unlock() }; return values }
}
private actor ProgressBackupRunner: BinaryCommandRunning {
  let corrupt: Bool
  let restorationFails: Bool
  let transferThrows: Bool
  var mounted = true
  init(corrupt: Bool = false, restorationFails: Bool = false, transferThrows: Bool = false) { self.corrupt = corrupt; self.restorationFails = restorationFails; self.transferThrows = transferThrows }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    var out = ""
    if arguments.contains("ro.product.device") { out = "checkers" }
    else if arguments.contains("ro.twrp.version") { out = "3.7.0_9-0" }
    else if arguments.contains("/proc/mounts") { out = mounted ? "/dev/block/mmcblk0p4 /data ext4 rw 0 0" : "" }
    else if arguments.contains("unmount") { mounted = false }
    else if arguments.contains("mount") {
      if restorationFails { return .init(stdout: "", exitCode: 1) }
      mounted = true
    } else if arguments.last?.hasPrefix("for n in boot") == true {
      out = ["boot", "recovery", "system", "userdata", "metadata"].enumerated().map { "\($0.element)\t/dev/block/mmcblk0p\($0.offset + 1)\t1048576" }.joined(separator: "\n")
    } else if arguments.contains("sha256sum") { out = "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58 file" }
    return .init(stdout: out)
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    XCTAssertFalse(mounted)
    if corrupt || transferThrows {
      try Data([1,2,3]).write(to: destination)
      try await Task.sleep(nanoseconds: 150_000_000)
      if transferThrows { throw GuideError.stopped("Fixture transfer interrupted") }
      return .init(stdout: "")
    }
    XCTAssertTrue(FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]))
    let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
    for _ in 0..<4 {
      try file.write(contentsOf: Data(repeating: 0, count: 262144))
      try await Task.sleep(nanoseconds: 60_000_000)
    }
    return .init(stdout: "")
  }
}
final class BackupProgressTests: XCTestCase {
  private func destination() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  func testMeasuredBytesAreSeparateFromVerificationAndCompletion() async throws {
    let folder = try destination(); defer { try? FileManager.default.removeItem(at: folder) }
    let events = ProgressRecorder()
    let adapter = try RecoveryAdapter(runner: ProgressBackupRunner(), adbPath: "/fixture/adb", serial: "fixture")
    let result = try await adapter.backup(to: folder, progress: { events.append($0) })
    XCTAssertEqual(result.count, 5)
    let values = events.snapshot()
    XCTAssertTrue(values.contains { $0.partition == "boot" && $0.stage == "capturing" && $0.transferredBytes > 0 && $0.transferredBytes < 1048576 && $0.verifiedPartitions == 0 })
    XCTAssertTrue(values.contains { $0.stage == "verifying" && $0.partition == "boot" && $0.transferredBytes == 1048576 && $0.verifiedPartitions == 0 })
    XCTAssertEqual(values.last?.stage, "complete")
    XCTAssertEqual(values.last?.verifiedPartitions, 5)
    XCTAssertEqual(values.last?.transferredBytes, 5 * 1048576)
    XCTAssertTrue(values.allSatisfy { $0.expectedBytes == 5 * 1048576 })
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("verified-backups.json").path))
  }
  func testCorruptCaptureReportsOnlyActualBytesAndStopsMonitor() async throws {
    let folder = try destination(); defer { try? FileManager.default.removeItem(at: folder) }
    let events = ProgressRecorder()
    let adapter = try RecoveryAdapter(runner: ProgressBackupRunner(corrupt: true), adbPath: "/fixture/adb", serial: "fixture")
    do { _ = try await adapter.backup(to: folder, progress: { events.append($0) }); XCTFail("Expected mismatch") } catch { }
    let values = events.snapshot()
    XCTAssertTrue(values.contains { $0.stage == "capturing" && $0.transferredBytes == 3 })
    XCTAssertTrue(values.allSatisfy { $0.transferredBytes <= 3 && $0.verifiedPartitions == 0 && $0.stage != "complete" })
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(events.snapshot(), values)
  }
  func testTransferErrorCancelsMonitorAndLeavesPartialUnverified() async throws {
    let folder = try destination(); defer { try? FileManager.default.removeItem(at: folder) }
    let events = ProgressRecorder()
    let adapter = try RecoveryAdapter(runner: ProgressBackupRunner(transferThrows: true), adbPath: "/fixture/adb", serial: "fixture")
    do { _ = try await adapter.backup(to: folder, progress: { events.append($0) }); XCTFail("Expected transfer error") } catch { }
    let values = events.snapshot()
    try await Task.sleep(nanoseconds: 250_000_000)
    XCTAssertEqual(events.snapshot(), values)
    XCTAssertTrue(values.allSatisfy { $0.verifiedPartitions == 0 && $0.stage != "complete" })
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("boot.img.partial").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("boot.img").path))
  }
  func testRestorationFailureCannotEmitCompletion() async throws {
    let folder = try destination(); defer { try? FileManager.default.removeItem(at: folder) }
    let events = ProgressRecorder()
    let adapter = try RecoveryAdapter(runner: ProgressBackupRunner(restorationFails: true), adbPath: "/fixture/adb", serial: "fixture")
    do { _ = try await adapter.backup(to: folder, progress: { events.append($0) }); XCTFail("Expected restoration failure") } catch { }
    XCTAssertFalse(events.snapshot().contains { $0.stage == "complete" })
    XCTAssertEqual(events.snapshot().last?.verifiedPartitions, 5)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("verified-backups.json").path))
  }
}
