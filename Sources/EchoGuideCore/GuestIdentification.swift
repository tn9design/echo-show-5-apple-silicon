import CryptoKit
import Foundation

public struct FastbootCandidate: Codable, Sendable, Equatable {
  public let serial: String
}

/// Read-only fastboot visibility does not establish device compatibility.
struct GuestIdentificationAdapter: Sendable {
  let guest: GuestAdapter
  let profile: CompatibilityProfile
  let fingerprint: String

  func validateTrust() throws {
    for name in ["known_hosts", "client-ed25519"] {
      let file = guest.credentialsDirectory.appendingPathComponent(name)
      guard file.standardizedFileURL == file.resolvingSymlinksInPath(), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw GuideError.stopped("Guest trust files are not private regular files") }
    }
    let text = try String(contentsOf: guest.credentialsDirectory.appendingPathComponent("known_hosts"), encoding: .utf8)
    let parts = text.split(whereSeparator: { $0.isWhitespace })
    guard parts.count == 3, parts[0] == "echoguide-" + guest.ownedVMID.uuidString else {
      throw GuideError.stopped("Pinned guest host key is invalid")
    }
    _ = try GuestBootstrapProtocol.canonicalPublicKey(String(parts[1]) + " " + String(parts[2]))
    guard let raw = Data(base64Encoded: String(parts[2])),
      "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "") == fingerprint
    else { throw GuideError.stopped("Pinned guest host key changed") }
  }
  private func run(_ command: String) async throws -> CommandResult {
    try validateTrust()
    guard let runner = guest.runner as? any TimedCommandRunning else {
      throw GuideError.stopped("Identification requires a bounded authenticated command runner")
    }
    return try await runner.run(executable: "/usr/bin/ssh", arguments: guest.arguments(command: command), timeoutSeconds: 25)
  }
  func discover() async throws -> [FastbootCandidate] {
    let hash = try profile.artifact(named: "fastboot").sha256
    let readiness = try await run("set -eu; test \"$(uname -m)\" = aarch64; test -x /media/rosetta/rosetta; grep -q '^enabled' /proc/sys/fs/binfmt_misc/rosetta; printf '%s  %s\\n' \(hash) /home/user/echoguide/fastboot | sha256sum -c - >/dev/null; /home/user/echoguide/fastboot --version")
    guard readiness.exitCode == 0, readiness.stdout.split(separator: "\n").first == "fastboot version 28.0.0" else {
      throw GuideError.stopped("Fresh guest ARM64, translation, or pinned fastboot validation failed")
    }
    let result = try await run("timeout --kill-after=2s 10s /home/user/echoguide/fastboot devices")
    guard result.exitCode == 0, result.stderr.isEmpty else { throw GuideError.stopped("Guest fastboot enumeration failed; visibility remains unknown") }
    return try Self.parseCandidates(result.stdout)
  }
  static func parseCandidates(_ output: String) throws -> [FastbootCandidate] {
    guard output.utf8.count <= 16_384, !output.contains("\0") else { throw GuideError.stopped("Invalid fastboot enumeration") }
    var seen = Set<String>()
    return try output.split(separator: "\n").map { line in
      let parts = line.split(whereSeparator: { $0.isWhitespace })
      guard parts.count == 2, parts[1] == "fastboot", parts[0].count <= 128, parts[0].range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil,
        seen.insert(String(parts[0])).inserted else { throw GuideError.stopped("Duplicated or malformed fastboot candidates") }
      return FastbootCandidate(serial: String(parts[0]))
    }
  }
  func identify(serial: String) async throws -> DeviceIdentity {
    guard serial.count <= 128, serial.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { throw GuideError.stopped("Select a valid fastboot serial") }
    let candidates = try await discover()
    guard candidates.contains(FastbootCandidate(serial: serial)) else { throw GuideError.stopped("Selected Echo is not assigned to this Linux workspace") }
    for (key, expected) in [("product", profile.product), ("unlock_status", "false"), ("lk_build_desc", profile.lkBuild)] {
      let result = try await run("timeout --kill-after=2s 10s /home/user/echoguide/fastboot -s \(serial) getvar \(key)")
      guard result.exitCode == 0, PilotSequence.exactGetvar(result.stdout + result.stderr, key: key, expected: expected) else {
        throw GuideError.stopped("Unsupported or changed Echo identity at " + key)
      }
    }
    return DeviceIdentity(serial: serial, product: profile.product, lkBuild: profile.lkBuild)
  }
}

extension WorkflowEngine {
  private func identificationAdapter(clearIdentity: Bool) throws -> GuestIdentificationAdapter {
    let state = try status()
    guard [.workspace, .identified].contains(state.phase), state.backupManifest == nil,
      let saved = state.guest, saved.ready, state.vmID == saved.vmID.uuidString else {
      throw GuideError.stopped("Identify only a prepared owned guest before recovery or installation")
    }
    if clearIdentity { try store.transaction { s in
      s.device = nil; s.pendingApproval = nil; s.stagedROMHash = nil; s.startupConfirmed = false
      s.phase = .workspace
    } }
    let guest = try GuestAdapter(runner: runner, ownedVMID: saved.vmID,
      credentialsDirectory: store.root.appendingPathComponent("guest-" + saved.vmID.uuidString), address: saved.address)
    return GuestIdentificationAdapter(guest: guest, profile: profile, fingerprint: saved.hostKeyFingerprint)
  }
  public func discoverFastbootDevices() async throws -> [FastbootCandidate] {
    try await operation("discover_fastboot") { try await self.identificationAdapter(clearIdentity: false).discover() }
  }
  public func identifyFastbootDevice(serial: String) async throws -> DeviceIdentity {
    try await operation("identify_fastboot") {
      let adapter = try self.identificationAdapter(clearIdentity: true)
      let device = try await adapter.identify(serial: serial)
      try self.store.transaction { s in
        guard s.phase == .workspace, s.device == nil, s.guest?.ready == true, s.vmID == adapter.guest.ownedVMID.uuidString,
          s.guest?.address == adapter.guest.address,
          s.guest?.hostKeyFingerprint == adapter.fingerprint else { throw GuideError.stopped("Owned workspace changed during identification") }
        s.device = device; s.phase = .identified
      }
      return device
    }
  }
}
