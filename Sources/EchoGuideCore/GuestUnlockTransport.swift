import CryptoKit
import Foundation

protocol TimedCommandRunning: CommandRunning {
  func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult
}

/// Internal pilot adapter only; not registered with the app, CLI, or MCP dispatcher.
actor GuestUnlockTransport: UnlockTransport {
  private let guest: GuestAdapter
  private let payload: URL
  private var serial: String?
  private var identityIndex = 0
  private var expected: [String: String] = [:]
  init(guest: GuestAdapter, payload: URL) { self.guest = guest; self.payload = payload }

  private func bounded(_ executable: String, _ arguments: [String], seconds: Int = 25) async throws -> CommandResult {
    guard let runner = guest.runner as? any TimedCommandRunning else {
      throw GuideError.stopped("Unlock transport requires a bounded command runner")
    }
    return try await runner.run(executable: executable, arguments: arguments, timeoutSeconds: seconds)
  }

  private func ssh(_ script: String, seconds: Int = 25) async throws -> CommandResult {
    do { return try await bounded("/usr/bin/ssh", guest.arguments(command: script), seconds: seconds) }
    catch { serial = nil; throw error }
  }
  func validate(session: SessionRecord, profile: CompatibilityProfile) async throws -> UnlockValidation {
    serial = nil; expected = [:]; identityIndex = 0
    guard let record = session.guest, record.ready, record.vmID == guest.ownedVMID,
      session.vmID == guest.ownedVMID.uuidString, record.address == guest.address,
      (session.guestUsername ?? "user") == guest.username,
      let device = session.device, device.serial.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil,
      profile.id == "checkers-20240709-v1", device.product == profile.product, device.lkBuild == profile.lkBuild
    else { throw GuideError.stopped("Owned guest/session identity changed") }
    let known = try String(contentsOf: guest.credentialsDirectory.appendingPathComponent("known_hosts"), encoding: .utf8)
    let parts = known.split(whereSeparator: { $0.isWhitespace })
    guard parts.count == 3, parts[0] == "echoguide-" + guest.ownedVMID.uuidString,
      parts[1] == "ssh-ed25519", let raw = Data(base64Encoded: String(parts[2]))
    else { throw GuideError.stopped("Pinned guest host key is invalid") }
    _ = try GuestBootstrapProtocol.canonicalPublicKey(String(parts[1]) + " " + String(parts[2]))
    let fingerprint = "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    guard fingerprint == record.hostKeyFingerprint else { throw GuideError.stopped("Pinned guest host key changed") }
    let artifact = try profile.artifact(named: "fastbrick-20240709.img")
    guard payload.isFileURL, payload.standardizedFileURL == payload.resolvingSymlinksInPath(),
      try payload.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
      try RecoveryAdapter.hash(payload) == artifact.sha256,
      let size = artifact.size,
      let localSize = try payload.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      Int64(localSize) == size
    else { throw GuideError.stopped("Pinned local unlock payload failed verification") }
    let readiness = try await guest.readiness()
    guard readiness.ready else { throw GuideError.stopped(readiness.reason) }
    let remote = "\(guest.workspacePath)/fastbrick-20240709.img"
    // Never overwrite an existing unknown payload, including a symlink.
    let check = try await ssh("test ! -L \(remote) || exit 44; if test -e \(remote); then sha256sum \(remote); wc -c < \(remote); else printf 'ABSENT\\n'; fi")
    guard check.exitCode == 0 else { throw GuideError.stopped("Guest payload inspection failed") }
    if check.stdout == "ABSENT\n" {
      let options = try Array(guest.arguments(command: "").dropLast(2)).filter { $0 != "-T" }
      let partial = remote + ".partial-" + UUID().uuidString
      let transfer = try await bounded("/usr/bin/scp", ["-B"] + options + [payload.path, guest.username + "@" + guest.address + ":" + partial], seconds: 300)
      guard transfer.exitCode == 0 else { throw GuideError.stopped("Pinned payload transfer failed") }
      let staged = try await ssh("set -eu; test ! -L \(partial); printf '%s  %s\\n' \(artifact.sha256) \(partial) | sha256sum -c - >/dev/null; test \"$(wc -c < \(partial))\" -eq \(size); chmod 600 \(partial); ln \(partial) \(remote); rm \(partial); printf 'STAGED\\n'")
      guard staged.exitCode == 0, staged.stdout == "STAGED\n" else { throw GuideError.stopped("Guest payload staging failed; unknown destination was not overwritten") }
    } else {
      guard check.stdout == "\(artifact.sha256)  \(remote)\n\(size)\n" else { throw GuideError.stopped("Existing guest payload differs; inspect without overwriting") }
    }
    guard try RecoveryAdapter.hash(payload) == artifact.sha256 else {
      throw GuideError.stopped("Local payload changed during staging")
    }
    let clientHash = try profile.artifact(named: "fastboot").sha256
    let verification = try await ssh("set -eu; test ! -L \(remote); printf '%s  %s\\n' \(clientHash) \(guest.workspacePath)/fastboot \(artifact.sha256) \(remote) | sha256sum -c - >/dev/null; test \"$(wc -c < \(remote))\" -eq \(size); timeout --version >/dev/null; printf 'VERIFIED\\n'")
    guard verification.exitCode == 0, verification.stdout == "VERIFIED\n" else { throw GuideError.stopped("Fresh guest unlock artifacts failed verification") }
    serial = device.serial
    expected = ["product": profile.product, "unlock_status": "false", "lk_build_desc": profile.lkBuild]
    return UnlockValidation(vmID: guest.ownedVMID, hostKeyFingerprint: fingerprint, clientSHA256: clientHash, payloadSHA256: artifact.sha256, ready: true)
  }
  func execute(_ command: UnlockCommand, timeoutSeconds: Int) async throws -> CommandResult {
    guard let approvedSerial = serial else { throw GuideError.stopped("Fresh transport validation is required") }
    let arguments: String
    switch command {
    case .getvar(let value, let key):
      guard value == approvedSerial, identityIndex < 3, ["product", "unlock_status", "lk_build_desc"][identityIndex] == key, let expectedValue = expected[key], timeoutSeconds == 10 else {
        serial = nil; throw GuideError.stopped("Unexpected unlock identity command")
      }
      arguments = "getvar " + key
      let result = try await ssh("timeout --kill-after=2s 10s \(guest.workspacePath)/fastboot -s \(value) \(arguments)")
      guard result.exitCode == 0, PilotSequence.exactGetvar(result.stdout + result.stderr, key: key, expected: expectedValue) else {
        serial = nil; return result
      }
      identityIndex += 1
      return result
    case .flashPinnedBrick(let value):
      guard value == approvedSerial, identityIndex == 3, timeoutSeconds == 8 else {
        serial = nil; throw GuideError.stopped("Unexpected unlock write command")
      }
      let result = try await ssh("timeout --kill-after=2s 8s \(guest.workspacePath)/fastboot -s \(value) flash brick \(guest.workspacePath)/fastbrick-20240709.img", seconds: 23)
      if !PilotSequence.ordinaryRejection(result.stdout + result.stderr, exit: result.exitCode) { serial = nil }
      return result
    }
  }
}
