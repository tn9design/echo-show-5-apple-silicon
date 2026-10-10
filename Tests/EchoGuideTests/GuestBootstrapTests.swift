import XCTest

@testable import EchoGuideCore

final class GuestBootstrapTests: XCTestCase {
  private var key: String {
    "ssh-ed25519 "
      + Data(
        [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
          + Array(repeating: UInt8(7), count: 32)
      ).base64EncodedString()
  }
  private func frame(
    _ request: GuestBootstrapRequest, address: String = "192.168.64.7",
    authorized: String = "read-only"
  ) -> String {
    "ECHOGUIDE-BEGIN \(request.ownedVMID.uuidString) \(request.nonce.uuidString)\nVERSION 1\nUSER user\nARCH aarch64\nIPV4 \(address)\nHOST_KEY \(key) root@debian\nCLIENT_AUTH \(authorized)\n"
      + request.endMarker + "\n"
  }
  func testReadOnlyFrameBindsVMAndChallenge() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID())
    let evidence = try GuestBootstrapProtocol.parse(
      "console echo\r\n" + frame(request).replacingOccurrences(of: "\n", with: "\r\n")
        + "user@debian:~$ ", for: request)
    XCTAssertEqual(evidence.trust.ownedVMID, request.ownedVMID)
    XCTAssertEqual(evidence.trust.publicHostKey, key)
    XCTAssertEqual(evidence.address, "192.168.64.7")
    XCTAssertFalse(evidence.clientAuthorized)
    XCTAssertNoThrow(
      try GuestBootstrapProtocol.parse(
        frame(request).trimmingCharacters(in: .newlines), for: request))
  }
  func testTerminalRedrawOutsideFrameDoesNotAlterTrustedFields() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID())
    XCTAssertNoThrow(try GuestBootstrapProtocol.parse(
      "echo\rredraw\n" + frame(request) + "prompt\r", for: request))
    for field in ["VERSION 1", "USER user", "ARCH aarch64", "IPV4 192.168.64.7", "HOST_KEY", "CLIENT_AUTH read-only"] {
      XCTAssertThrowsError(try GuestBootstrapProtocol.parse(
        frame(request).replacingOccurrences(of: field, with: "\r" + field), for: request))
    }
  }
  func testPublicKeyAuthorizationIsExplicitAndBuilderFixed() throws {
    let readOnly = try GuestBootstrapRequest(ownedVMID: UUID())
    XCTAssertFalse(GuestBootstrapProtocol.consoleCommand(for: readOnly).contains("authorized_keys"))
    let request = try GuestBootstrapRequest(
      ownedVMID: UUID(), clientPublicKey: key + " EchoGuide-fixture")
    let command = GuestBootstrapProtocol.consoleCommand(for: request)
    XCTAssertTrue(command.contains("test ! -L /home/user/.ssh/authorized_keys"))
    XCTAssertTrue(command.contains("restrict " + key))
    XCTAssertFalse(command.contains("EchoGuide-fixture"))
    XCTAssertFalse(command.contains("sudo"))
    XCTAssertTrue(
      try GuestBootstrapProtocol.parse(frame(request, authorized: "installed"), for: request)
        .clientAuthorized)
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(frame(request), for: request))
  }
  func testRejectsWrongChallengeAndDuplicateFrames() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID())
    let other = try GuestBootstrapRequest(ownedVMID: request.ownedVMID)
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(frame(other), for: request))
    XCTAssertThrowsError(
      try GuestBootstrapProtocol.parse(frame(request) + frame(request), for: request))
    XCTAssertThrowsError(
      try GuestBootstrapProtocol.parse(
        frame(request).replacingOccurrences(
          of: request.ownedVMID.uuidString, with: UUID().uuidString), for: request))
  }
  func testRejectsDuplicateOrUnexpectedFieldsAndUntrustedAddresses() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID())
    XCTAssertThrowsError(
      try GuestBootstrapProtocol.parse(
        frame(request).replacingOccurrences(of: "ARCH aarch64", with: "USER user"), for: request))
    XCTAssertThrowsError(
      try GuestBootstrapProtocol.parse(
        frame(request).replacingOccurrences(of: "VERSION 1", with: "VERSION 2"), for: request))
    XCTAssertThrowsError(
      try GuestBootstrapProtocol.parse(
        frame(request).replacingOccurrences(of: "USER user", with: "USER root"), for: request))
    for address in [
      "8.8.8.8", "192.168.64.999", "192.168.64.7;evil", "192.168.64.7\nIPV4 10.0.0.2",
    ] {
      XCTAssertThrowsError(
        try GuestBootstrapProtocol.parse(frame(request, address: address), for: request))
    }
  }
  func testRejectsInvalidKeyAndBoundedTranscript() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID())
    for invalid in [
      key + "\ncommand", "command=" + key, "ssh-ed25519 invalid", key + " comment;evil",
    ] {
      XCTAssertThrowsError(try GuestBootstrapRequest(ownedVMID: UUID(), clientPublicKey: invalid))
    }
    XCTAssertThrowsError(
      try GuestBootstrapProtocol.parse(
        String(repeating: "x", count: GuestBootstrapProtocol.maximumTranscriptBytes + 1)
          + frame(request), for: request))
    XCTAssertThrowsError(
      try GuestBootstrapProtocol.parse(
        frame(request).replacingOccurrences(of: key, with: "ssh-ed25519 invalid"), for: request))
  }
}
