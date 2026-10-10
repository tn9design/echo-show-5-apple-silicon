import XCTest

@testable import EchoGuideCore

private struct GuestFixtureRunner: CommandRunning {
  let output: String
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTAssertEqual(executable, "/usr/bin/ssh")
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    XCTAssertTrue(arguments.contains("ProxyCommand=none"))
    XCTAssertTrue(arguments.contains("ForwardAgent=no"))
    XCTAssertEqual(arguments[arguments.count - 2], "user@192.168.64.7")
    XCTAssertFalse(arguments.last!.contains("-s fixture"))
    return CommandResult(stdout: output)
  }
}
final class GuestTests: XCTestCase {
  func testAbsentTrustDoesNotConnect() async throws {
    let guest = try GuestAdapter(
      runner: GuestFixtureRunner(output: ""), ownedVMID: UUID(),
      credentialsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString), address: "192.168.64.7")
    let ready = try await guest.readiness()
    XCTAssertFalse(ready.ready)
  }
  func testRejectsPublicAndInjectedAddress() {
    for address in ["8.8.8.8", "192.168.64.7;evil", "192.168.64.999", "-oProxyCommand=evil"] {
      XCTAssertThrowsError(
        try GuestAdapter(
          runner: GuestFixtureRunner(output: ""), ownedVMID: UUID(),
          credentialsDirectory: URL(fileURLWithPath: "/tmp/fixture"), address: address))
    }
  }
  func testWrongSerialVMAndChangedHostKeyRejected() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("fixture private key".utf8).write(to: folder.appendingPathComponent("client-ed25519"))
    let identity = UUID()
    let guest = try GuestAdapter(
      runner: GuestFixtureRunner(output: ""), ownedVMID: identity, credentialsDirectory: folder,
      address: "192.168.64.7")
    let key =
      "ssh-ed25519 "
      + Data(
        [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
          + Array(repeating: UInt8(1), count: 32)
      ).base64EncodedString()
    XCTAssertThrowsError(try guest.pinHostKey(.init(ownedVMID: UUID(), publicHostKey: key)))
    XCTAssertTrue(
      try guest.pinHostKey(.init(ownedVMID: identity, publicHostKey: key)).hasPrefix("SHA256:"))
    let changed =
      "ssh-ed25519 "
      + Data(
        [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32]
          + Array(repeating: UInt8(2), count: 32)
      ).base64EncodedString()
    XCTAssertThrowsError(try guest.pinHostKey(.init(ownedVMID: identity, publicHostKey: changed)))
  }
  func testStagingRejectsUnverifiedAssetsBeforeConnection() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("unverified".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let guest = try GuestAdapter(
      runner: GuestFixtureRunner(output: ""), ownedVMID: UUID(),
      credentialsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString), address: "192.168.64.7")
    do {
      try await guest.stageValidationAssets(fastboot: file, mockScript: file)
      XCTFail("Expected artifact rejection")
    } catch { XCTAssertTrue(error.localizedDescription.contains("hash mismatch")) }
  }
  func testCompleteMockEvidenceIsReady() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("fixture".utf8).write(to: folder.appendingPathComponent("client-ed25519"))
    try Data("fixture".utf8).write(to: folder.appendingPathComponent("known_hosts"))
    let output =
      "fastboot version 28.0.0\n"
      + "{\"matches\":true,\"exit\":1,\"bytes\":4096,\"commands\":[\"flash:brick\"],\"output\":\"isolated mock deliberately rejects flash\"}"
    let guest = try GuestAdapter(
      runner: GuestFixtureRunner(output: output), ownedVMID: UUID(), credentialsDirectory: folder,
      address: "192.168.64.7")
    let ready = try await guest.readiness()
    XCTAssertTrue(ready.ready)
  }
  func testIncompleteMockEvidenceIsNotReady() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("fixture".utf8).write(to: folder.appendingPathComponent("client-ed25519"))
    try Data("fixture".utf8).write(to: folder.appendingPathComponent("known_hosts"))
    let guest = try GuestAdapter(
      runner: GuestFixtureRunner(output: "fastboot version 28.0.0\n{\"matches\":true}"),
      ownedVMID: UUID(), credentialsDirectory: folder, address: "192.168.64.7")
    let ready = try await guest.readiness()
    XCTAssertFalse(ready.ready)
  }
}

extension GuestTests {
  func testKnownHostsConfigurationEscapesSpecialPaths() throws {
    XCTAssertEqual(
      try GuestAdapter.knownHostsOption(path: "/tmp/Application Support/key"),
      "UserKnownHostsFile=\"/tmp/Application Support/key\"")
    XCTAssertEqual(
      try GuestAdapter.knownHostsOption(path: "/tmp/a\"b\\c%h"),
      "UserKnownHostsFile=\"/tmp/a\\\"b\\\\c%%h\"")
    for path in ["/tmp/a\nb", "/tmp/a\rb", "/tmp/${HOME}", "relative"] {
      XCTAssertThrowsError(try GuestAdapter.knownHostsOption(path: path))
    }
  }
  func testKnownHostsSSHConfigurationParsesWithoutNetwork() async throws {
    let option = try GuestAdapter.knownHostsOption(path: "/tmp/Application Support/key%h")
    let result = try await ProcessRunner().run(
      executable: "/usr/bin/ssh",
      arguments: [
        "-G", "-F", "/dev/null", "-o", option, "-o", "StrictHostKeyChecking=yes",
        "user@192.168.64.7",
      ])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("userknownhostsfile /tmp/Application Support/key%h"))
  }
}

extension GuestTests {
  func testBundledHelperMatchesPinnedProfileAndSource() throws {
    let helper = try GuestAdapter.bundledValidationHelper()
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tools/compare-mock.py")
    XCTAssertEqual(try Data(contentsOf: helper), try Data(contentsOf: source))
    XCTAssertThrowsError(try CompatibilityProfile.bundled().artifact(named: "unknown"))
  }
}

private struct GuestFailureRunner: CommandRunning {
  let code: Int32
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTAssertTrue(arguments.last!.contains("exit 41"))
    XCTAssertTrue(arguments.last!.contains("exit 42"))
    XCTAssertTrue(arguments.last!.contains("exit 43"))
    return CommandResult(stdout: "", stderr: "fixture", exitCode: code)
  }
}
extension GuestTests {
  func testReadinessFailuresHaveSpecificNextActions() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["client-ed25519", "known_hosts"] {
      try Data("fixture".utf8).write(to: folder.appendingPathComponent(name))
    }
    for (code, expected) in [(Int32(41), "not ARM64"), (42, "Enable Rosetta"), (43, "not registered"), (255, "SSH connection failed"), (1, "offline mock")] {
      let guest = try GuestAdapter(runner: GuestFailureRunner(code: code), ownedVMID: UUID(), credentialsDirectory: folder, address: "192.168.64.7")
      let result = try await guest.readiness()
      XCTAssertFalse(result.ready)
      XCTAssertTrue(result.reason.contains(expected), result.reason)
    }
  }
}
