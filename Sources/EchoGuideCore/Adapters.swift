import CryptoKit
import Foundation

public enum AdapterError: Error, Equatable, LocalizedError {
  case inspectionUnavailable, invalidDevice, incompatibleRecovery
  case commandFailed(String)
  case invalidPartitions, insufficientSpace, mountedData
  case mismatch(String)
  case destinationExists
  public var errorDescription: String? {
    switch self {
    case .inspectionUnavailable: return "USB inspection is unavailable; device presence is unknown."
    case .invalidDevice: return "Choose one device with a valid serial before continuing."
    case .incompatibleRecovery:
      return "Expected CHECKERS with TWRP 3.7.0_9-0; no backup or installation was started."
    case .commandFailed(let stage):
      return "The \(stage) stage failed. Stop and inspect the current device/workspace state."
    case .invalidPartitions:
      return
        "Named partition mappings are missing, duplicated, or unexpected. No raw image will be read."
    case .insufficientSpace:
      return
        "The backup destination does not have enough free space for all required images and a safety margin."
    case .mountedData:
      return "User data or a storage alias is still mounted. Backup stopped before reading it."
    case .mismatch(let name):
      return
        "The \(name) image failed size/hash verification. Its partial file is not a verified backup."
    case .destinationExists:
      return
        "This destination already contains an image, partial capture, or manifest. Choose a new empty backup folder; existing files were preserved."
    }
  }
}

public struct USBDevice: Codable, Sendable, Equatable {
  public let vendorID: Int
  public let productID: Int
  public let registryID: UInt64
  public let name: String
}

public enum USBInspection {
  public static func parse(_ data: Data) throws -> [USBDevice] {
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    var found: [USBDevice] = []
    func visit(_ value: Any) {
      if let list = value as? [Any] { list.forEach(visit) }
      guard let node = value as? [String: Any] else { return }
      if let vendor = node["idVendor"] as? NSNumber, let product = node["idProduct"] as? NSNumber,
        let identity = node["IORegistryEntryID"] as? NSNumber
      {
        found.append(
          USBDevice(
            vendorID: vendor.intValue, productID: product.intValue,
            registryID: identity.uint64Value,
            name: node["USB Product Name"] as? String ?? "USB device"))
      }
      if let children = node["IORegistryEntryChildren"] { visit(children) }
    }
    visit(plist)
    return found
  }
}

/// Configuration contract only. Translation and first USB assignment remain guided UI steps.
/// This specification does not imply that the untested provisioning backend is ready.
public struct OwnedVMSpecification: Codable, Sendable, Equatable {
  public let ownershipID: UUID
  public let memoryMiB: Int
  public let diskGiB: Int
  public let architecture: String
  public let backend: String
  public init(ownershipID: UUID = UUID()) {
    self.ownershipID = ownershipID
    memoryMiB = 4096
    diskGiB = 12
    architecture = "aarch64"
    backend = "Apple"
  }
  public func validates(vmID: UUID, registeredVMID: UUID?, backend: String, architecture: String)
    -> Bool
  {
    registeredVMID == vmID && backend == self.backend && architecture == self.architecture
  }
}

/// Binary transfers must stream into the supplied destination, never decode partition bytes as text.
public protocol BinaryCommandRunning: CommandRunning {
  func runToFile(executable: String, arguments: [String], destination: URL) async throws
    -> CommandResult
}

public struct Partition: Codable, Sendable, Equatable {
  public let name: String
  public let device: String
  public let size: UInt64
}
public struct VerifiedPartitionBackup: Codable, Sendable, Equatable {
  public let partition: Partition
  public let filename: String
  public let sha256: String
}

public struct BackupProgress: Codable, Sendable, Equatable {
  public let partition: String?
  public let stage: String
  public let transferredBytes: UInt64
  public let expectedBytes: UInt64
  public let verifiedPartitions: Int
  public init(partition: String?, stage: String, transferredBytes: UInt64, expectedBytes: UInt64, verifiedPartitions: Int) {
    self.partition = partition; self.stage = stage; self.transferredBytes = transferredBytes
    self.expectedBytes = expectedBytes; self.verifiedPartitions = verifiedPartitions
  }
}

public struct RecoveryAdapter: Sendable {
  public let runner: any BinaryCommandRunning
  public let adbPath: String
  public let serial: String
  public init(runner: any BinaryCommandRunning, adbPath: String, serial: String) throws {
    guard !serial.isEmpty,
      serial.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
    else { throw AdapterError.invalidDevice }
    self.runner = runner
    self.adbPath = adbPath
    self.serial = serial
  }
  private func command(_ arguments: [String]) async throws -> String {
    let result = try await runner.run(executable: adbPath, arguments: ["-s", serial] + arguments)
    guard result.exitCode == 0 else { throw AdapterError.commandFailed(arguments.first ?? "adb") }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  public func verify() async throws {
    let product = try await command(["shell", "getprop", "ro.product.device"])
    let version = try await command(["shell", "getprop", "ro.twrp.version"])
    guard product == "checkers", version == "3.7.0_9-0" else {
      throw AdapterError.incompatibleRecovery
    }
  }
  public static func parsePartitions(_ output: String) throws -> [Partition] {
    let expected = Set(["boot", "recovery", "system", "userdata", "metadata"])
    let partitions = try output.split(separator: "\n").map { line -> Partition in
      let fields = line.split(separator: "\t")
      guard fields.count == 3, expected.contains(String(fields[0])),
        fields[1].range(of: "^/dev/block/mmcblk[0-9]+p[0-9]+$", options: .regularExpression) != nil,
        let size = UInt64(fields[2]), size >= 1_048_576, size <= 32 * 1024 * 1024 * 1024
      else { throw AdapterError.invalidPartitions }
      return Partition(name: String(fields[0]), device: String(fields[1]), size: size)
    }
    guard partitions.count == expected.count, Set(partitions.map(\.name)) == expected,
      Set(partitions.map(\.device)).count == expected.count
    else { throw AdapterError.invalidPartitions }
    return partitions
  }
  public func discoverPartitions() async throws -> [Partition] {
    // A fixed script: names are not supplied by callers and mappings are resolved on this device.
    let script =
      "for n in boot recovery system userdata metadata; do p=$(readlink -f /dev/block/platform/*/by-name/$n); [ -b \"$p\" ] || exit 1; s=$(blockdev --getsize64 \"$p\") || exit 1; printf '%s\\t%s\\t%s\\n' \"$n\" \"$p\" \"$s\"; done"
    return try Self.parsePartitions(await command(["shell", script]))
  }
  public func backup(to folder: URL, progress: (@Sendable (BackupProgress) -> Void)? = nil) async throws -> [VerifiedPartitionBackup] {
    try await verify()
    let partitions = try await discoverPartitions()
    let expectedBytes = partitions.reduce(UInt64(0)) { $0 + $1.size }
    let required = expectedBytes + 512 * 1024 * 1024
    let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
    guard let available = attributes[.systemFreeSize] as? NSNumber,
      available.uint64Value >= required
    else { throw AdapterError.insufficientSpace }
    let originalMounts = try await command(["shell", "cat", "/proc/mounts"])
    // Unknown userdata bind aliases cannot be restored safely; stop before unmounting.
    let dataDevice = partitions.first { $0.name == "userdata" }!.device
    for line in originalMounts.split(separator: "\n") {
      let f = line.split(separator: " ")
      if f.count > 1,
        f[0] == Substring(dataDevice) || f[0].hasPrefix("/data/") || f[1].hasPrefix("/data/")
          || f[1].hasPrefix("/storage/"),
        f[1] != "/data", f[1] != "/sdcard"
      {
        throw AdapterError.mountedData
      }
    }
    let mountedData = originalMounts.split(separator: "\n").filter { line in
      let fields = line.split(separator: " ")
      return fields.count > 1 && (fields[1] == "/data" || fields[1] == "/sdcard")
    }
    let restoreTargets = mountedData.compactMap { line -> String? in
      let fields = line.split(separator: " ")
      return fields.count > 1 ? String(fields[1]) : nil
    }
    func restore() async throws {
      for target in restoreTargets { _ = try await command(["shell", "twrp", "mount", target]) }
      let restored = try await command(["shell", "cat", "/proc/mounts"])
      let targets = Set(
        restored.split(separator: "\n").compactMap { line -> String? in
          let fields = line.split(separator: " ")
          return fields.count > 1 ? String(fields[1]) : nil
        })
      guard restoreTargets.allSatisfy(targets.contains) else { throw AdapterError.mountedData }
    }
    var result: [VerifiedPartitionBackup] = []
    do {
      _ = try await command(["shell", "twrp", "unmount", "/data"])
      // Aliases may not have separate mounts; fixed umount tolerates absent aliases.
      _ = try await command(["shell", "umount /sdcard 2>/dev/null; true"])
      let mounts = try await command(["shell", "cat", "/proc/mounts"])
      guard
        !mounts.split(separator: "\n").contains(where: { line in
          let f = line.split(separator: " ")
          return f.count > 1
            && (f[0] == Substring(dataDevice) || f[1] == "/data" || f[1] == "/sdcard"
              || f[1].hasPrefix("/data/"))
        })
      else { throw AdapterError.mountedData }
      for partition in partitions {
        try Task.checkCancellation()
        let destination = folder.appendingPathComponent(partition.name + ".img")
        let partial = folder.appendingPathComponent(partition.name + ".img.partial")
        guard !FileManager.default.fileExists(atPath: destination.path),
          !FileManager.default.fileExists(atPath: partial.path)
        else { throw AdapterError.destinationExists }
        let capturedBefore = result.reduce(UInt64(0)) { $0 + $1.partition.size }
        progress?(BackupProgress(partition: partition.name, stage: "hashing", transferredBytes: capturedBefore, expectedBytes: expectedBytes, verifiedPartitions: result.count))
        let sourceHash =
          try await command(["shell", "sha256sum", partition.device]).split(separator: " ").first
          .map(String.init) ?? ""
        guard sourceHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
          throw AdapterError.mismatch(partition.name)
        }
        let transfer = try await capture(partition: partition, partial: partial, capturedBefore: capturedBefore, expectedBytes: expectedBytes, verifiedPartitions: result.count, progress: progress)
        guard transfer.exitCode == 0 else { throw AdapterError.commandFailed("backup transfer") }
        let measuredSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0
        progress?(BackupProgress(partition: partition.name, stage: "verifying", transferredBytes: capturedBefore + measuredSize, expectedBytes: expectedBytes, verifiedPartitions: result.count))
        let size =
          try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
        guard size?.uint64Value == partition.size, try Self.hash(partial) == sourceHash else {
          throw AdapterError.mismatch(partition.name)
        }
        let finalSourceHash =
          try await command(["shell", "sha256sum", partition.device]).split(separator: " ").first
          .map(String.init) ?? ""
        guard finalSourceHash == sourceHash else { throw AdapterError.mismatch(partition.name) }
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: partial.path)
        try FileManager.default.moveItem(at: partial, to: destination)
        result.append(
          VerifiedPartitionBackup(
            partition: partition, filename: destination.lastPathComponent, sha256: sourceHash))
        progress?(BackupProgress(partition: partition.name, stage: "verifying", transferredBytes: capturedBefore + partition.size, expectedBytes: expectedBytes, verifiedPartitions: result.count))
      }
    } catch {
      try? await restore()
      throw error
    }
    try await restore()
    let manifest = try JSONEncoder().encode(result)
    let manifestURL = folder.appendingPathComponent("verified-backups.json")
    guard !FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw AdapterError.destinationExists
    }
    try manifest.write(to: manifestURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    progress?(BackupProgress(partition: nil, stage: "complete", transferredBytes: expectedBytes, expectedBytes: expectedBytes, verifiedPartitions: result.count))
    return result
  }
  private func capture(partition: Partition, partial: URL, capturedBefore: UInt64, expectedBytes: UInt64, verifiedPartitions: Int, progress: (@Sendable (BackupProgress) -> Void)?) async throws -> CommandResult {
    let arguments = ["-s", serial, "exec-out", "cat", partition.device]
    guard let progress else { return try await runner.runToFile(executable: adbPath, arguments: arguments, destination: partial) }
    let sample: @Sendable () -> BackupProgress = {
      let actual = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0
      return BackupProgress(partition: partition.name, stage: "capturing", transferredBytes: capturedBefore + actual, expectedBytes: expectedBytes, verifiedPartitions: verifiedPartitions)
    }
    progress(sample())
    // Polling observes bytes already written; it never estimates a transfer rate or verification.
    let monitor = Task {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(1800))
      while !Task.isCancelled && clock.now < deadline {
        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { break }
        guard !Task.isCancelled else { break }
        progress(sample())
      }
    }
    do {
      let result = try await runner.runToFile(executable: adbPath, arguments: arguments, destination: partial)
      monitor.cancel(); await monitor.value
      progress(sample())
      return result
    } catch {
      monitor.cancel(); await monitor.value
      throw error
    }
  }
  public static func hash(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var digest = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      digest.update(data: chunk)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
