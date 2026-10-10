import Foundation

public struct GuestBootstrapRequest: Sendable {
  public let username: String
  public let ownedVMID: UUID
  public let nonce: UUID
  public let clientPublicKey: String?
  public var endMarker: String { "ECHOGUIDE-END \(ownedVMID.uuidString) \(nonce.uuidString)" }
  public init(ownedVMID: UUID, nonce: UUID = UUID(), clientPublicKey: String? = nil, username: String = "user") throws {
    self.username = try GuestUsername.validated(username)
    self.ownedVMID = ownedVMID
    self.nonce = nonce
    self.clientPublicKey = try clientPublicKey.map(GuestBootstrapProtocol.canonicalPublicKey)
  }
}
public struct GuestBootstrapEvidence: Sendable {
  public let trust: GuestTrustEvidence
  public let address: String
  public let clientAuthorized: Bool
}

/// A console protocol after login to the selected account in the owned Debian VM.
/// These builders do not log in, open a PTY, run a guest command or authorize SSH by themselves.
public enum GuestBootstrapProtocol {
  public static let maximumTranscriptBytes = 16_384
  public static func canonicalPublicKey(_ text: String) throws -> String {
    guard !text.contains("\n"), !text.contains("\r"), text.utf8.count <= 512 else {
      throw GuideError.stopped("Invalid bootstrap public key")
    }
    let fields = text.split(whereSeparator: \.isWhitespace)
    guard (2...3).contains(fields.count), fields[0] == "ssh-ed25519",
      fields[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }),
      let raw = Data(base64Encoded: String(fields[1])), raw.count == 51,
      raw.prefix(19) == Data([0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]),
      fields.count == 2
        || fields[2].allSatisfy({
          $0.isASCII && ($0.isLetter || $0.isNumber || "@._-".contains($0))
        })
    else {
      throw GuideError.stopped(
        "Expected a complete ed25519 public key, without options or shell text")
    }
    return "ssh-ed25519 " + raw.base64EncodedString()
  }
  private static func privateIPv4(_ text: String) -> Bool {
    let components = text.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4,
      components.allSatisfy({ value in
        value.allSatisfy({ $0.isASCII && $0.isNumber })
          && Int(value).map { (0...255).contains($0) } == true
      }), let first = Int(components[0]), let second = Int(components[1])
    else { return false }
    return first == 10 || (first == 172 && (16...31).contains(second))
      || (first == 192 && second == 168)
  }
  /// One fixed shell command. Only UUIDs and a validated public-key blob are interpolated.
  public static func consoleCommand(for request: GuestBootstrapRequest) -> String {
    let home = "/home/" + request.username
    let owner = request.ownedVMID.uuidString
    let nonce = request.nonce.uuidString
    let clientInstallation: String
    if let key = request.clientPublicKey {
      clientInstallation =
        "test ! -L \(home)/.ssh; mkdir -p \(home)/.ssh; test ! -L \(home)/.ssh/authorized_keys; touch \(home)/.ssh/authorized_keys; chmod 700 \(home)/.ssh; chmod 600 \(home)/.ssh/authorized_keys; grep -qxF 'restrict \(key)' \(home)/.ssh/authorized_keys || printf '%s\\n' 'restrict \(key)' >> \(home)/.ssh/authorized_keys; client_state=installed;"
    } else {
      clientInstallation = "client_state=read-only;"
    }
    // Host public key and network discovery precede key installation; failure produces no frame.
    // Readline may emit bracketed-paste cleanup plus CR before output. Start a fresh
    // line so those terminal bytes stay outside the strictly checked evidence frame.
    let command =
      "set -eu; test \"$(id -un)\" = \(request.username); test \"$HOME\" = \(home); test \"$(uname -m)\" = aarch64; host_key=$(cat /etc/ssh/ssh_host_ed25519_key.pub); address=$(ip -4 -o addr show scope global | awk '{split($4,a,\"/\"); split(a[1],b,\".\"); if (b[1]==10 || (b[1]==172 && b[2]>=16 && b[2]<=31) || (b[1]==192 && b[2]==168)) print a[1]}'); test \"$(printf '%s\\n' \"$address\" | wc -l)\" -eq 1; test -n \"$address\"; \(clientInstallation) printf '\\nECHOGUIDE-BEGIN %s %s\\nVERSION 1\\nUSER \(request.username)\\nARCH aarch64\\nIPV4 %s\\nHOST_KEY %s\\nCLIENT_AUTH %s\\nECHOGUIDE-END %s %s\\n' '\(owner)' '\(nonce)' \"$address\" \"$host_key\" \"$client_state\" '\(owner)' '\(nonce)'"
    // Subshell avoids changing the login shell's error options when bootstrap fails.
    return "( " + command + " )\n"
  }
  /// Console echo/prompts outside the frame are permitted; all framed fields are exact and ordered.
  public static func parse(_ transcript: String, for request: GuestBootstrapRequest) throws
    -> GuestBootstrapEvidence
  {
    guard transcript.utf8.count <= maximumTranscriptBytes, !transcript.contains("\0") else {
      throw GuideError.stopped("Bootstrap transcript exceeded its bound or contained invalid bytes")
    }
    let normalized = transcript.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    let begin = "ECHOGUIDE-BEGIN \(request.ownedVMID.uuidString) \(request.nonce.uuidString)"
    let end = "ECHOGUIDE-END \(request.ownedVMID.uuidString) \(request.nonce.uuidString)"
    let starts = lines.indices.filter { lines[$0].hasPrefix("ECHOGUIDE-BEGIN ") }
    let ends = lines.indices.filter { lines[$0].hasPrefix("ECHOGUIDE-END ") }
    guard starts.count == 1, ends.count == 1, let first = starts.first, let last = ends.first,
      lines[first] == begin, lines[last] == end, last - first == 7
    else {
      throw GuideError.stopped(
        "Bootstrap frame invalid (begin markers: \(starts.count), end markers: \(ends.count), exact begin: \(starts.first.map { lines[$0] == begin } ?? false), exact end: \(ends.first.map { lines[$0] == end } ?? false), frame line distance: \(starts.first.flatMap { first in ends.first.map { $0 - first } } ?? -1)). No transcript or identifiers included")
    }
    // Terminal echo may redraw a line with a bare CR outside the protocol frame.
    // Framed evidence must remain exact; never strip control bytes from its fields.
    guard !lines[first...last].contains(where: { $0.contains("\r") }) else {
      throw GuideError.stopped("Unexpected carriage return in bootstrap frame")
    }
    let fields = Array(lines[(first + 1)..<last])
    guard fields[0] == "VERSION 1", fields[1] == "USER \(request.username)", fields[2] == "ARCH aarch64",
      fields[3].hasPrefix("IPV4 "), fields[4].hasPrefix("HOST_KEY "),
      fields[5].hasPrefix("CLIENT_AUTH ")
    else { throw GuideError.stopped("Unexpected or duplicate bootstrap fields") }
    let address = String(fields[3].dropFirst(5))
    guard privateIPv4(address) else {
      throw GuideError.stopped("Guest did not report one private IPv4 address")
    }
    let key = try canonicalPublicKey(String(fields[4].dropFirst(9)))
    let clientState = String(fields[5].dropFirst(12))
    guard clientState == (request.clientPublicKey == nil ? "read-only" : "installed") else {
      throw GuideError.stopped(
        "Guest client authorization result does not match the requested operation")
    }
    return GuestBootstrapEvidence(
      trust: GuestTrustEvidence(ownedVMID: request.ownedVMID, publicHostKey: key), address: address,
      clientAuthorized: clientState == "installed")
  }
}
