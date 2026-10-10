import Foundation
import Darwin

/// Internal preparation only. No wipe, install, reboot, or public command dispatch.
struct ROMStagingAdapter: Sendable {
  static let filename = "lineage-18.1-20260904-UNOFFICIAL-checkers.zip"
  static let destination = "/sdcard/" + filename
  let runner: any CommandRunning

  struct Receipt: Codable, Sendable {
    let serial: String
    let destination: String
    let sha256: String
    let bytes: Int64
    let verifiedAt: Date
  }

  func stage(adb: String, serial: String, localROM: URL, artifact: Artifact,
    evidenceURL: URL) async throws -> Receipt {
    let pinned = try CompatibilityProfile.bundled().artifact(named: Self.filename)
    let parent = try FileManager.default.attributesOfItem(atPath: evidenceURL.deletingLastPathComponent().path)
    guard localROM.isFileURL, evidenceURL.isFileURL,
      parent[.type] as? FileAttributeType == .typeDirectory,
      ((parent[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
      adb.hasPrefix("/"), serial.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil,
      artifact.name == Self.filename, artifact.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
      artifact.sha256 == pinned.sha256, artifact.size == pinned.size,
      artifact.publisherURL == pinned.publisherURL,
      let bytes = artifact.size, bytes > 0,
      !FileManager.default.fileExists(atPath: evidenceURL.path),
      evidenceURL.standardizedFileURL.path == evidenceURL.resolvingSymlinksInPath().standardizedFileURL.path,
      localROM.standardizedFileURL.path == localROM.resolvingSymlinksInPath().standardizedFileURL.path
    else { throw GuideError.stopped("Invalid ROM staging prerequisites or existing evidence") }
    let attributes = try FileManager.default.attributesOfItem(atPath: localROM.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? NSNumber)?.int64Value == bytes,
      try RecoveryAdapter.hash(localROM) == artifact.sha256
    else { throw GuideError.stopped("Local ROM does not match pinned artifact") }
    func run(_ args: [String]) async throws -> String {
      let result = try await runner.run(executable: adb, arguments: ["-s", serial] + args)
      guard result.exitCode == 0 else { throw GuideError.stopped("ROM staging failed; no installation started") }
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard try await run(["shell", "getprop", "ro.product.device"]) == "checkers",
      try await run(["shell", "getprop", "ro.twrp.version"]) == "3.7.0_9-0"
    else { throw AdapterError.incompatibleRecovery }
    // Refuse overwriting an existing ZIP, including a symlink. Storage must already be mounted.
    _ = try await run(["shell", "test ! -e " + Self.destination + " && test ! -L " + Self.destination])
    _ = try await run(["push", localROM.path, Self.destination])
    let hash = try await run(["shell", "sha256sum", Self.destination])
    guard Self.exactRemoteHash(hash, expected: artifact.sha256),
      try await run(["shell", "stat", "-c", "%s", Self.destination]) == String(bytes)
    else { throw GuideError.stopped("Device ROM verification failed; no installation started") }
    guard try RecoveryAdapter.hash(localROM) == artifact.sha256,
      try await run(["shell", "getprop", "ro.product.device"]) == "checkers",
      try await run(["shell", "getprop", "ro.twrp.version"]) == "3.7.0_9-0"
    else { throw GuideError.stopped("ROM or recovery changed during staging") }
    let receipt = Receipt(serial: serial, destination: Self.destination, sha256: artifact.sha256,
      bytes: bytes, verifiedAt: Date())
    // Exclusive creation prevents a concurrent operation from replacing existing evidence.
    let fd = open(evidenceURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Staging evidence destination changed") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: JSONEncoder().encode(receipt))
      try handle.synchronize()
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
    return receipt
  }

  static func exactRemoteHash(_ output: String, expected: String) -> Bool {
    let fields = output.split(whereSeparator: { $0.isWhitespace })
    return fields.count == 2 && fields[0] == expected && fields[1] == destination
  }
}
