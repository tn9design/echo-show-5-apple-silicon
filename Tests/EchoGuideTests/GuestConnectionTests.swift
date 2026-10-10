import XCTest
@testable import EchoGuideCore

private struct ConnectionRunner: CommandRunning {
  let result: CommandResult
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTAssertEqual(executable, "/usr/bin/ssh")
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(arguments.contains("BatchMode=yes"))
    XCTAssertFalse(arguments.last!.contains("mkdir"))
    XCTAssertFalse(arguments.last!.contains("sudo -"))
    return result
  }
}
private struct DeniedNetworkProbe: GuestNetworkProbing {
  func probe(address: String) async -> GuestNetworkProbeResult {
    XCTAssertEqual(address, "192.168.64.7")
    return .localNetworkDenied
  }
}

final class GuestConnectionTests: XCTestCase {
  func testOnlyExactReadOnlyEvidenceEstablishesConnection() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["client-ed25519", "known_hosts"] {
      try Data("fixture".utf8).write(to: folder.appendingPathComponent(name))
    }
    for (output, connected) in [("ECHOGUIDE-CONNECTION-OK\nECHOGUIDE-SUDO-YES\n", true), ("ECHOGUIDE-CONNECTION-OK\nECHOGUIDE-SUDO-NO\n", true), ("ECHOGUIDE-CONNECTION-OK\n", false), ("fixture-secret", false)] {
      let guest = try GuestAdapter(runner: ConnectionRunner(result: CommandResult(stdout: output)),
        ownedVMID: UUID(), credentialsDirectory: folder, address: "192.168.64.7")
      let result = try await guest.inspectConnection()
      XCTAssertEqual(result.connected, connected)
      if connected { XCTAssertEqual(result.translationPrivilegeToolAvailable, output.hasSuffix("ECHOGUIDE-SUDO-YES\n")) }
      else { XCTAssertNil(result.translationPrivilegeToolAvailable) }
      XCTAssertFalse(result.reason.contains("fixture-secret"))
    }
  }
  func testTransportFailuresAreCategorizedWithoutPrivateOutput() {
    for (message, category) in [
      ("Host key verification failed. fixture-secret 192.168.64.7", "host_key_rejected"),
      ("Permission denied (publickey). fixture-secret", "authentication_rejected"),
      ("Load key /private/fixture: Permission denied", "ssh_access_denied"),
      ("connect to host 192.168.64.7: No route to host", "connection_blocked_or_unreachable"),
      ("Connection refused", "connection_refused"),
      ("Connection timed out", "connection_timeout"),
      ("unknown fixture-secret", "ssh_transport_failed")
    ] {
      let result = GuestAdapter.connectionFailure(CommandResult(stdout: "fixture-secret", stderr: message, exitCode: 255))
      XCTAssertFalse(result.connected)
      XCTAssertEqual(result.category, category)
      XCTAssertFalse(result.reason.contains("fixture-secret"))
      XCTAssertFalse(result.reason.contains("192.168"))
    }
  }
  func testPrivacyDiagnosisUsesSameSavedAddressAndNeverEstablishesIdentity() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["client-ed25519", "known_hosts"] {
      try Data("fixture".utf8).write(to: folder.appendingPathComponent(name))
    }
    let guest = try GuestAdapter(runner: ConnectionRunner(result:
      CommandResult(stdout: "", stderr: "No route to host: fixture-secret", exitCode: 255)),
      ownedVMID: UUID(), credentialsDirectory: folder, address: "192.168.64.7")
    let result = try await guest.inspectConnection(networkProbe: DeniedNetworkProbe())
    XCTAssertFalse(result.connected)
    XCTAssertEqual(result.category, "local_network_denied")
    XCTAssertEqual(result.networkProbe, .localNetworkDenied)
    XCTAssertFalse(result.reason.contains("fixture-secret"))
  }
  func testRemotePrerequisiteFailureIsNotCalledTransportSuccess() {
    let result = GuestAdapter.connectionFailure(CommandResult(stdout: "ECHOGUIDE-CONNECTION-OK\n", exitCode: 41))
    XCTAssertFalse(result.connected)
    XCTAssertEqual(result.category, "guest_prerequisite_failed")
  }
}
