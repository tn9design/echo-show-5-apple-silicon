import XCTest

@testable import EchoGuideCore

final class AdapterTests: XCTestCase {
  func testStructuredUSBEnumeration() throws {
    let values: [[String: Any]] = [
      [
        "IORegistryEntryChildren": [
          [
            "idVendor": 0x0bb4, "idProduct": 0x0c01, "IORegistryEntryID": UInt64(42),
            "USB Product Name": "Android",
          ]
        ]
      ]
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: values, format: .xml, options: 0)
    let devices = try USBInspection.parse(data)
    XCTAssertEqual(devices.count, 1)
    XCTAssertEqual(devices.first?.registryID, 42)
    XCTAssertEqual(devices.first?.vendorID, 0x0bb4)
  }
  func testDeviceNameDoesNotEstablishCompatibility() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [["USB Product Name": "Echo Show 5"]], format: .xml, options: 0)
    XCTAssertTrue(try USBInspection.parse(data).isEmpty)
  }
  func testUniquePartitionDiscovery() throws {
    let text = ["boot", "recovery", "system", "userdata", "metadata"].enumerated().map {
      "\($0.element)\t/dev/block/mmcblk0p\($0.offset + 1)\t16777216"
    }.joined(separator: "\n")
    XCTAssertEqual(try RecoveryAdapter.parsePartitions(text).count, 5)
    XCTAssertThrowsError(
      try RecoveryAdapter.parsePartitions(text + "\nboot\t/dev/block/mmcblk0p1\t16777216"))
    XCTAssertThrowsError(
      try RecoveryAdapter.parsePartitions(
        text.replacingOccurrences(of: "mmcblk0p2", with: "mmcblk0p1")))
    XCTAssertThrowsError(
      try RecoveryAdapter.parsePartitions(text.replacingOccurrences(of: "16777216", with: "1")))
    XCTAssertThrowsError(
      try RecoveryAdapter.parsePartitions(
        text.replacingOccurrences(of: "/dev/block/mmcblk0p1", with: "/tmp/file")))
  }
  func testUTMCreationHasPinnedBackendAndNoAutomaticStart() throws {
    let script = try UTMAdapter.creationScript(
      application: URL(fileURLWithPath: "/Applications/UTM.app"))
    XCTAssertTrue(script.contains("backend:apple"))
    XCTAssertTrue(script.contains("guest size:12288"))
    XCTAssertTrue(script.contains("ownershipToken"))
    XCTAssertFalse(script.contains("start newVM"))
    XCTAssertFalse(script.contains("rosetta"))
    XCTAssertThrowsError(
      try UTMAdapter.creationScript(application: URL(fileURLWithPath: "/Applications/other")))
  }
  func testVMOwnershipRequiresRecordedUUIDAndBackend() {
    let first = OwnedVMSpecification()
    let second = OwnedVMSpecification()
    XCTAssertNotEqual(first.ownershipID, second.ownershipID)
    let vm = UUID()
    XCTAssertTrue(
      first.validates(vmID: vm, registeredVMID: vm, backend: "Apple", architecture: "aarch64"))
    XCTAssertFalse(
      first.validates(vmID: vm, registeredVMID: nil, backend: "Apple", architecture: "aarch64"))
    XCTAssertFalse(
      first.validates(vmID: vm, registeredVMID: vm, backend: "QEMU", architecture: "aarch64"))
  }
}

private struct BackupFixtureRunner: BinaryCommandRunning {
  let mounted: Bool
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    let out: String
    if arguments.contains("ro.product.device") {
      out = "checkers"
    } else if arguments.contains("ro.twrp.version") {
      out = "3.7.0_9-0"
    } else if arguments.contains("/proc/mounts") {
      out = mounted ? "/dev/block/mmcblk0p4 /data ext4 rw 0 0" : ""
    } else if arguments.last?.hasPrefix("for n in boot") == true {
      out = ["boot", "recovery", "system", "userdata", "metadata"].enumerated().map {
        "\($0.element)\t/dev/block/mmcblk0p\($0.offset + 1)\t1048576"
      }.joined(separator: "\n")
    } else if arguments.contains("sha256sum") {
      out = String(repeating: "0", count: 64) + " file"
    } else {
      out = ""
    }
    return CommandResult(stdout: out, stderr: "", exitCode: 0)
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws
    -> CommandResult
  {
    try Data([1, 2, 3]).write(to: destination)
    return CommandResult(stdout: "", stderr: "", exitCode: 0)
  }
}

extension AdapterTests {
  func testCorruptTransferNeverBecomesVerified() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let adapter = try RecoveryAdapter(
      runner: BackupFixtureRunner(mounted: false), adbPath: "/fixture/adb", serial: "fixture")
    do {
      _ = try await adapter.backup(to: folder)
      XCTFail("Expected mismatch")
    } catch { XCTAssertEqual(error as? AdapterError, .mismatch("boot")) }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("boot.img").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("verified-backups.json").path))
  }
  func testMountedUserdataStopsBeforeTransfer() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let adapter = try RecoveryAdapter(
      runner: BackupFixtureRunner(mounted: true), adbPath: "/fixture/adb", serial: "fixture")
    do {
      _ = try await adapter.backup(to: folder)
      XCTFail("Expected mounted data stop")
    } catch { XCTAssertEqual(error as? AdapterError, .mountedData) }
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
  }
}

private actor SuccessfulBackupRunner: BinaryCommandRunning {
  var mounted = true
  var restored = false
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    let out: String
    if arguments.contains("ro.product.device") {
      out = "checkers"
    } else if arguments.contains("ro.twrp.version") {
      out = "3.7.0_9-0"
    } else if arguments.contains("/proc/mounts") {
      out = mounted ? "/dev/block/mmcblk0p4 /data ext4 rw 0 0" : ""
    } else if arguments.contains("unmount") {
      mounted = false
      out = ""
    } else if arguments.contains("mount") {
      mounted = true
      restored = true
      out = ""
    } else if arguments.last?.hasPrefix("for n in boot") == true {
      out = ["boot", "recovery", "system", "userdata", "metadata"].enumerated().map {
        "\($0.element)\t/dev/block/mmcblk0p\($0.offset + 1)\t1048576"
      }.joined(separator: "\n")
    } else if arguments.contains("sha256sum") {
      out = "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58 file"
    } else {
      out = ""
    }
    return CommandResult(stdout: out)
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws
    -> CommandResult
  {
    XCTAssertFalse(mounted)
    try Data(repeating: 0, count: 1_048_576).write(to: destination)
    return CommandResult(stdout: "")
  }
}
extension AdapterTests {
  func testVerifiedBackupRestoresOriginalMountAndCreatesManifest() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = SuccessfulBackupRunner()
    let adapter = try RecoveryAdapter(runner: runner, adbPath: "/fixture/adb", serial: "fixture")
    let backups = try await adapter.backup(to: folder)
    XCTAssertEqual(backups.count, 5)
    let restored = await runner.restored
    XCTAssertTrue(restored)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("verified-backups.json").path))
    let permissions =
      try FileManager.default.attributesOfItem(
        atPath: folder.appendingPathComponent("userdata.img").path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
  }
}
