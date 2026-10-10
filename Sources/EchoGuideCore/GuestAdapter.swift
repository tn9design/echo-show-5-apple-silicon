import CryptoKit
import Foundation

public struct GuestTrustEvidence: Sendable {
  public let ownedVMID: UUID
  /// Public host key obtained from the app-owned serial bootstrap channel, never ssh-keyscan.
  public let publicHostKey: String
  public init(ownedVMID: UUID, publicHostKey: String) {
    self.ownedVMID = ownedVMID
    self.publicHostKey = publicHostKey
  }
}
public struct GuestReadiness: Codable, Sendable, Equatable {
  public let ready: Bool
  public let reason: String
  public let hostKeyFingerprint: String?
}
public struct GuestAdapter: Sendable {
  public let runner: any CommandRunning
  public let ownedVMID: UUID
  public let credentialsDirectory: URL
  public let address: String
  private let clientName = "client-ed25519"
  public init(
    runner: any CommandRunning, ownedVMID: UUID, credentialsDirectory: URL, address: String
  ) throws {
    guard credentialsDirectory.isFileURL, credentialsDirectory.path.hasPrefix("/"),
      !credentialsDirectory.path.contains("\n"), !credentialsDirectory.path.contains("\r"),
      !credentialsDirectory.path.contains("${"), Self.privateIPv4(address)
    else {
      throw GuideError.stopped("Expected app-owned credential directory and private guest IPv4")
    }
    self.runner = runner
    self.ownedVMID = ownedVMID
    self.credentialsDirectory = credentialsDirectory
    self.address = address
  }
  private static func privateIPv4(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4,
      parts.allSatisfy({
        Int($0).map { (0...255).contains($0) } == true && $0.allSatisfy(\.isNumber)
      }),
      let first = Int(parts[0]), let second = Int(parts[1])
    else { return false }
    return first == 10 || (first == 172 && (16...31).contains(second))
      || (first == 192 && second == 168)
  }
  /// Only invoked by an explicit workspace preparation action. This method is never called by inspection.
  public func createClientIdentity() async throws -> URL {
    let fm = FileManager.default
    guard !fm.fileExists(atPath: credentialsDirectory.path) else {
      throw GuideError.stopped("Credential directory already exists; no keys overwritten")
    }
    try fm.createDirectory(
      at: credentialsDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let privateKey = credentialsDirectory.appendingPathComponent(clientName)
    let result = try await runner.run(
      executable: "/usr/bin/ssh-keygen",
      arguments: [
        "-q", "-t", "ed25519", "-N", "", "-C", "EchoGuide-" + ownedVMID.uuidString, "-f",
        privateKey.path,
      ])
    guard result.exitCode == 0, fm.fileExists(atPath: privateKey.path),
      fm.fileExists(atPath: privateKey.path + ".pub")
    else {
      throw GuideError.stopped("Client identity creation failed; inspect workspace before retry")
    }
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
    return URL(fileURLWithPath: privateKey.path + ".pub")
  }
  /// Caller must obtain evidence from the serial channel bound to this managed VM UUID.
  public func pinHostKey(_ evidence: GuestTrustEvidence) throws -> String {
    guard evidence.ownedVMID == ownedVMID else {
      throw GuideError.stopped("Serial evidence belongs to a different VM")
    }
    let fields = evidence.publicHostKey.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 2, fields[0] == "ssh-ed25519",
      let raw = Data(base64Encoded: String(fields[1])), raw.count == 51,
      raw.prefix(19) == Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]),
      !evidence.publicHostKey.contains("\n"), !evidence.publicHostKey.contains("\r")
    else { throw GuideError.stopped("Invalid serial host key evidence") }
    guard
      FileManager.default.fileExists(
        atPath: credentialsDirectory.appendingPathComponent(clientName).path)
    else { throw GuideError.stopped("Create the client identity first") }
    let knownHosts = credentialsDirectory.appendingPathComponent("known_hosts")
    let line = "echoguide-\(ownedVMID.uuidString) \(fields[0]) \(fields[1])\n"
    if FileManager.default.fileExists(atPath: knownHosts.path) {
      guard try String(contentsOf: knownHosts, encoding: .utf8) == line else {
        throw GuideError.stopped("Guest host key changed; obtain new owned-serial evidence")
      }
    } else {
      try Data(line.utf8).write(to: knownHosts, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
    }
    return "SHA256:"
      + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
  }
  /// OpenSSH parses -o values as configuration text, independently of argv boundaries.
  public static func knownHostsOption(path: String) throws -> String {
    try pathOption(name: "UserKnownHostsFile", path: path)
  }
  private static func pathOption(name: String, path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), !path.contains("\0"),
      !path.contains("${")
    else { throw GuideError.stopped("Invalid known-hosts path") }
    let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "%", with: "%%")
    return name + "=\"" + escaped + "\""
  }
  private func arguments(command: String) throws -> [String] {
    let key = credentialsDirectory.appendingPathComponent(clientName)
    let knownHosts = credentialsDirectory.appendingPathComponent("known_hosts")
    guard FileManager.default.fileExists(atPath: key.path),
      FileManager.default.fileExists(atPath: knownHosts.path)
    else {
      throw GuideError.stopped(
        "Guest trust is absent; obtain the host key through the owned serial channel")
    }
    return [
      "-F", "/dev/null", "-T", "-o", try Self.pathOption(name: "IdentityFile", path: key.path),
      "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o",
      try Self.knownHostsOption(path: knownHosts.path), "-o", "GlobalKnownHostsFile=/dev/null",
      "-o", "HostKeyAlias=echoguide-" + ownedVMID.uuidString, "-o", "ConnectTimeout=10", "-o",
      "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", "-o",
      "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ProxyCommand=none",
      "user@" + address, command,
    ]
  }
  /// Uploads only hash-verified public validation artifacts; arbitrary files cannot be staged.
  public func stageValidationAssets(fastboot: URL, mockScript: URL) async throws {
    func hash(_ url: URL) throws -> String {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var digest = SHA256()
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        digest.update(data: data)
      }
      return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    guard try hash(fastboot) == "cb3d13b850143da85eb4b2099462514894459213da93d03d6ff4782d927d6e20",
      try hash(mockScript) == "4f453414d4bc53e0e414306fe82a0d05b5679de8ae4c95961c6636927cf44301"
    else { throw GuideError.stopped("Validation asset hash mismatch") }
    let setup = try await runner.run(
      executable: "/usr/bin/ssh",
      arguments: try arguments(
        command:
          "set -eu; test ! -L /home/user/echoguide; mkdir -p /home/user/echoguide; chmod 700 /home/user/echoguide"
      ))
    guard setup.exitCode == 0 else {
      throw GuideError.stopped("Guest validation directory could not be prepared")
    }
    let fixture = credentialsDirectory.appendingPathComponent("mock.img")
    try Data(repeating: 0, count: 4096).write(to: fixture, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.path)
    // scp must not inherit SSH's -T: scp -T disables strict filename checking.
    let options = try Array(arguments(command: "").dropLast(2)).filter { $0 != "-T" }
    for (source, name) in [
      (fastboot, "fastboot"), (mockScript, "compare-mock.py"), (fixture, "mock.img"),
    ] {
      let transfer = try await runner.run(
        executable: "/usr/bin/scp",
        arguments: ["-B"] + options + [
          source.path, "user@" + address + ":/home/user/echoguide/" + name,
        ])
      guard transfer.exitCode == 0 else {
        throw GuideError.stopped("Guest validation artifact transfer failed")
      }
    }
    let finish = try await runner.run(
      executable: "/usr/bin/ssh",
      arguments: try arguments(
        command:
          "chmod 700 /home/user/echoguide/fastboot; chmod 600 /home/user/echoguide/compare-mock.py /home/user/echoguide/mock.img"
      ))
    guard finish.exitCode == 0 else {
      throw GuideError.stopped("Guest validation artifact permissions failed")
    }
  }
  public func readiness() async throws -> GuestReadiness {
    let knownHosts = credentialsDirectory.appendingPathComponent("known_hosts")
    guard FileManager.default.fileExists(atPath: knownHosts.path),
      FileManager.default.fileExists(
        atPath: credentialsDirectory.appendingPathComponent(clientName).path)
    else {
      return GuestReadiness(
        ready: false,
        reason:
          "Obtain owned-serial host-key evidence and create the client identity before connecting.",
        hostKeyFingerprint: nil)
    }
    // Fixed paths and arguments; no caller-supplied guest shell fragments or device commands.
    let script =
      "set -eu; test \"$(uname -m)\" = aarch64; test -x /media/rosetta/rosetta; grep -q '^enabled' /proc/sys/fs/binfmt_misc/rosetta; cd /home/user/echoguide; printf '%s  %s\\n' cb3d13b850143da85eb4b2099462514894459213da93d03d6ff4782d927d6e20 fastboot | sha256sum -c - >/dev/null; printf '%s  %s\\n' 4f453414d4bc53e0e414306fe82a0d05b5679de8ae4c95961c6636927cf44301 compare-mock.py | sha256sum -c - >/dev/null; printf '%s  %s\\n' ad7facb2586fc6e966c004d7d1d16b024f5805ff7cb47c7a85dabd8b48892ca7 mock.img | sha256sum -c - >/dev/null; ./fastboot --version; python3 compare-mock.py --fastboot ./fastboot --image mock.img"
    let result = try await runner.run(
      executable: "/usr/bin/ssh", arguments: try arguments(command: script))
    guard result.exitCode == 0 else {
      return GuestReadiness(
        ready: false,
        reason:
          "Guest architecture, translation, original client, or offline mock failed validation.",
        hostKeyFingerprint: nil)
    }
    guard result.stdout.contains("fastboot version 28.0.0"),
      let firstBrace = result.stdout.firstIndex(of: "{"),
      let json = result.stdout[firstBrace...].data(using: .utf8),
      let mock = try JSONSerialization.jsonObject(with: json) as? [String: Any],
      mock["matches"] as? Bool == true,
      mock["exit"] as? Int == 1, mock["bytes"] as? Int == 4096,
      let commands = mock["commands"] as? [String], commands.last == "flash:brick",
      let output = mock["output"] as? String,
      output.contains("isolated mock deliberately rejects flash")
    else {
      return GuestReadiness(
        ready: false, reason: "Offline client test did not produce the expected complete evidence.",
        hostKeyFingerprint: nil)
    }
    return GuestReadiness(
      ready: true,
      reason:
        "ARM64, translation, original client hash/version and isolated TCP mock passed. USB identity still requires a separate check.",
      hostKeyFingerprint: nil)
  }
}
