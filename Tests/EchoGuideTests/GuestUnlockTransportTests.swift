import XCTest
@testable import EchoGuideCore

private struct ForbiddenUnlockRunner: TimedCommandRunning {
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTFail("Unexpected guest command")
    throw GuideError.stopped("fixture")
  }
  func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
    XCTFail("Unexpected bounded guest command")
    throw GuideError.stopped("fixture")
  }
}
final class GuestUnlockTransportTests: XCTestCase {
  func testExecutionRequiresFreshValidation() async throws {
    let guest = try GuestAdapter(runner: ForbiddenUnlockRunner(), ownedVMID: UUID(), credentialsDirectory: URL(fileURLWithPath: "/tmp/fixture"), address: "192.168.64.7")
    let transport = GuestUnlockTransport(guest: guest, payload: URL(fileURLWithPath: "/tmp/payload"))
    for command in [UnlockCommand.getvar(serial: "TEST", key: "product"), .flashPinnedBrick(serial: "TEST")] {
      do { _ = try await transport.execute(command, timeoutSeconds: 8); XCTFail("Expected refusal") }
      catch { XCTAssertTrue(error.localizedDescription.contains("validation")) }
    }
  }
  func testWrongSessionNeverConnects() async throws {
    let guest = try GuestAdapter(runner: ForbiddenUnlockRunner(), ownedVMID: UUID(), credentialsDirectory: URL(fileURLWithPath: "/tmp/fixture"), address: "192.168.64.7")
    let transport = GuestUnlockTransport(guest: guest, payload: URL(fileURLWithPath: "/tmp/payload"))
    do { _ = try await transport.validate(session: SessionRecord(profileID: "checkers-20240709-v1"), profile: CompatibilityProfile.bundled()); XCTFail("Expected refusal") }
    catch { XCTAssertTrue(error.localizedDescription.contains("identity")) }
  }
}

private actor UnlockPipelineRunner: TimedCommandRunning {
  var commands: [(String, Int)] = []
  let existing: Bool
  let wrongIdentity: Bool
  init(existing: Bool = false, wrongIdentity: Bool = false) { self.existing = existing; self.wrongIdentity = wrongIdentity }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    return CommandResult(stdout: "fastboot version 28.0.0\n{\"matches\":true,\"exit\":1,\"bytes\":4096,\"commands\":[\"flash:brick\"],\"output\":\"isolated mock deliberately rejects flash\"}")
  }
  func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    let command = arguments.last!
    commands.append((command, timeoutSeconds))
    if executable == "/usr/bin/scp" { return CommandResult(stdout: "") }
    if command.contains("ABSENT") { return CommandResult(stdout: existing ? "mismatch\n1\n" : "ABSENT\n") }
    if command.contains("STAGED") { return CommandResult(stdout: "STAGED\n") }
    if command.contains("VERIFIED") { return CommandResult(stdout: "VERIFIED\n") }
    for (key, value) in [("product", "CHECKERS"), ("unlock_status", "false"), ("lk_build_desc", "44072a3-20240709_170103")] {
      if command.hasSuffix("getvar " + key) { return CommandResult(stdout: key + ": " + (wrongIdentity ? "WRONG" : value) + "\n") }
    }
    return CommandResult(stdout: "unexpected flash result", exitCode: 124)
  }
}
extension GuestUnlockTransportTests {
  private func fixture(_ runner: any CommandRunning, payload: URL) throws -> (GuestUnlockTransport, SessionRecord, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: folder.appendingPathComponent("client-ed25519"))
    let id = UUID()
    let guest = try GuestAdapter(runner: runner, ownedVMID: id, credentialsDirectory: folder, address: "192.168.64.7")
    let key = "ssh-ed25519 " + Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
    let fingerprint = try guest.pinHostKey(.init(ownedVMID: id, publicHostKey: key))
    var state = SessionRecord(profileID: "checkers-20240709-v1")
    state.vmID = id.uuidString
    state.device = DeviceIdentity(serial: "TEST", product: "CHECKERS", lkBuild: "44072a3-20240709_170103")
    state.guest = GuestWorkspaceRecord(vmID: id, address: guest.address, hostKeyFingerprint: fingerprint, checkedAt: Date(), ready: true)
    return (GuestUnlockTransport(guest: guest, payload: payload), state, folder)
  }
  private func pinnedPayload() throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["ECHOGUIDE_TEST_PINNED_PAYLOAD"] else { throw XCTSkip("Provide readonly pinned payload for offline pipeline tests") }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
  }
  func testFixedPipelineAndDeadlinesWithoutDevice() async throws {
    let runner = UnlockPipelineRunner()
    let (transport, state, folder) = try fixture(runner, payload: pinnedPayload())
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try await transport.validate(session: state, profile: CompatibilityProfile.bundled())
    for key in ["product", "unlock_status", "lk_build_desc"] {
      _ = try await transport.execute(.getvar(serial: "TEST", key: key), timeoutSeconds: 10)
    }
    _ = try await transport.execute(.flashPinnedBrick(serial: "TEST"), timeoutSeconds: 8)
    do { _ = try await transport.execute(.flashPinnedBrick(serial: "TEST"), timeoutSeconds: 8); XCTFail("Unexpected retry") } catch {}
    let calls = await runner.commands
    XCTAssertTrue(calls.contains { $0.1 == 300 })
    XCTAssertEqual(calls.last?.1, 23)
    XCTAssertTrue(calls.last!.0.contains("timeout --kill-after=2s 8s"))
    XCTAssertEqual(calls.filter { $0.0.contains("getvar") }.map(\.1), [25,25,25])
  }
  func testFlashCannotBypassIdentityQueries() async throws {
    let runner = UnlockPipelineRunner()
    let (transport, state, folder) = try fixture(runner, payload: pinnedPayload())
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try await transport.validate(session: state, profile: CompatibilityProfile.bundled())
    do { _ = try await transport.execute(.flashPinnedBrick(serial: "TEST"), timeoutSeconds: 8); XCTFail("Expected refusal") } catch {}
    let calls = await runner.commands
    XCTAssertFalse(calls.contains { $0.0.contains(" flash brick ") })
  }
  func testMismatchedExistingPayloadNeverOverwrites() async throws {
    let runner = UnlockPipelineRunner(existing: true)
    let (transport, state, folder) = try fixture(runner, payload: pinnedPayload())
    defer { try? FileManager.default.removeItem(at: folder) }
    do { _ = try await transport.validate(session: state, profile: CompatibilityProfile.bundled()); XCTFail("Expected mismatch") } catch {}
    let calls = await runner.commands
    XCTAssertFalse(calls.contains { $0.1 == 300 })
  }
  func testLocalSymlinkRejectedWithoutConnection() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let link = folder.appendingPathComponent("payload")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/private/tmp/absent-payload"))
    let (transport, state, credentials) = try fixture(ForbiddenUnlockRunner(), payload: link)
    defer { try? FileManager.default.removeItem(at: credentials) }
    do { _ = try await transport.validate(session: state, profile: CompatibilityProfile.bundled()); XCTFail("Expected refusal") } catch {}
  }
  func testProcessRunnerEnforcesMonotonicDeadline() async throws {
    let clock = ContinuousClock(); let start = clock.now
    do { _ = try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["10"], timeoutSeconds: 1); XCTFail("Expected timeout") }
    catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    XCTAssertLessThan(start.duration(to: clock.now), .seconds(4))
  }
}

extension GuestUnlockTransportTests {
  func testChangedIdentityRevokesTransport() async throws {
    let runner = UnlockPipelineRunner(wrongIdentity: true)
    let (transport, state, folder) = try fixture(runner, payload: pinnedPayload())
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try await transport.validate(session: state, profile: CompatibilityProfile.bundled())
    _ = try await transport.execute(.getvar(serial: "TEST", key: "product"), timeoutSeconds: 10)
    do { _ = try await transport.execute(.getvar(serial: "TEST", key: "unlock_status"), timeoutSeconds: 10); XCTFail("Expected revoked validation") } catch {}
    let calls = await runner.commands
    XCTAssertEqual(calls.filter { $0.0.contains("getvar") }.count, 1)
  }
}
