import Foundation

/// Reviewed sequence is testable without enabling live dispatch in the preview.
struct PilotSequence: Sendable {
  let runner: any CommandRunning
  init(runner: any CommandRunning) { self.runner = runner }
  static func exactGetvar(_ output: String, key: String, expected: String) -> Bool {
    let values = output.split(separator: "\n").filter { $0.hasPrefix(key + ":") }.map {
      $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
    }
    return values == [expected]
  }
  static func ordinaryRejection(_ output: String, exit: Int32) -> Bool {
    guard exit == 1 else { return false }
    let lines = output.split(separator: "\n").map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
    // Exact observed complete rejection. Additional output prevents retries.
    guard lines.count == 6, lines[0] == "target reported max download size of 114294784 bytes",
      lines[1] == "Sending 'brick' (111785 KB)...",
      lines[2].range(of: "^OKAY \\[ *[0-9]+\\.[0-9]+s\\]$", options: .regularExpression) != nil,
      lines[3] == "Writing 'brick'...",
      lines[4] == "FAILED (remote: the command you input is restricted on locked hw)",
      lines[5].range(of: "^Finished\\. Total time: [0-9]+\\.[0-9]+s$", options: .regularExpression)
        != nil
    else { return false }
    return true
  }
  func verifyIdentity(fastboot: String, serial: String, profile: CompatibilityProfile) async throws
  {
    guard serial.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
      throw GuideError.stopped("Invalid device serial")
    }
    for (key, expected) in [
      ("product", profile.product), ("unlock_status", "false"), ("lk_build_desc", profile.lkBuild),
    ] {
      let r = try await runner.run(executable: fastboot, arguments: ["-s", serial, "getvar", key])
      guard r.exitCode == 0, Self.exactGetvar(r.stdout + r.stderr, key: key, expected: expected)
      else { throw GuideError.stopped("Unsupported or ambiguous identity: " + key) }
    }
  }
  func install(adb: String, serial: String, romHash: String, saveLog: URL) async throws {
    guard serial.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil,
      romHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    else { throw GuideError.stopped("Invalid installation identity") }
    let zip = "/sdcard/lineage-18.1-20260904-UNOFFICIAL-checkers.zip"
    func run(_ args: [String]) async throws -> CommandResult {
      let r = try await runner.run(executable: adb, arguments: ["-s", serial] + args)
      guard r.exitCode == 0 else {
        throw GuideError.stopped("Installation stopped; preserve recovery and inspect")
      }
      return r
    }
    func verifyZip() async throws {
      let r = try await run(["shell", "sha256sum", zip])
      guard r.stdout.split(separator: " ").first.map(String.init) == romHash else {
        throw GuideError.stopped("Device ROM hash mismatch")
      }
    }
    try await verifyZip()
    for p in ["data", "system", "cache"] { _ = try await run(["shell", "twrp", "wipe", p]) }
    try await verifyZip()
    let before = try await run(["shell", "cat", "/tmp/recovery.log"])
    let installation = try await runner.run(
      executable: adb, arguments: ["-s", serial, "shell", "twrp", "install", zip])
    let log = try await run(["shell", "cat", "/tmp/recovery.log"])
    try Data(log.stdout.utf8).write(to: saveLog, options: .atomic)
    guard log.stdout.hasPrefix(before.stdout) else {
      throw GuideError.stopped(
        "Recovery log rotated or changed; cannot tie success to this invocation")
    }
    let fresh = String(log.stdout.dropFirst(before.stdout.count))
    guard installation.exitCode == 0, fresh.contains("Installing zip file '" + zip + "'"),
      let current = fresh.components(separatedBy: "Installing zip file '" + zip + "'").last,
      current.contains("Updater process ended with RC=0"),
      current.contains("operation_end - status=0"), !current.contains("operation_end - status=1")
    else { throw GuideError.stopped("Installer success evidence missing; log saved, no reboot") }
    _ = try await run(["reboot"])
  }
}
