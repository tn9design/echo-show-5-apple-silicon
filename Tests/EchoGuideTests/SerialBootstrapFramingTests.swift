import Foundation
import XCTest

@testable import EchoGuideCore

final class SerialBootstrapFramingTests: XCTestCase {
  func testActualCommandFramesEvidenceAfterReadlineTerminalCleanup() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID(), username: "echotest")
    let key = "ssh-ed25519 " + Data(
      [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
        + Array(repeating: UInt8(7), count: 32)
    ).base64EncodedString()
    let command = GuestBootstrapProtocol.consoleCommand(for: request)
    // The serial write submits one shell input line; printf emits the frame separators.
    XCTAssertEqual(command.filter { $0 == "\n" }.count, 1)
    let fixture = """
      HOME=/home/echotest
      export HOME
      id() { printf '%s\\n' echotest; }
      uname() { printf '%s\\n' aarch64; }
      cat() { test "$1" = /etc/ssh/ssh_host_ed25519_key.pub || return 99; printf '%s\\n' '\(key) fixture'; }
      ip() { printf '%s\\n' '2: eth0 inet 192.168.64.7/24 brd 192.168.64.255 scope global eth0'; }
      """
    // GNU Readline emits bracketed-paste disable + CR after accepting a line.
    // These are outside the trusted frame; the producer must begin on a fresh line.
    for cleanup in ["", "\\033[?2004l\\r", "\\r"] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", fixture + "\nprintf '" + cleanup + "'\n" + command]
      process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let transcript = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0)
      let evidence = try GuestBootstrapProtocol.parse(
        String(decoding: transcript, as: UTF8.self), for: request)
      XCTAssertEqual(evidence.trust.ownedVMID, request.ownedVMID)
      XCTAssertEqual(evidence.trust.publicHostKey, key)
      XCTAssertEqual(evidence.address, "192.168.64.7")
      XCTAssertFalse(evidence.clientAuthorized)
    }
  }
}
