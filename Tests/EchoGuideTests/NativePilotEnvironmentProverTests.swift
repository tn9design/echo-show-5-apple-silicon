import XCTest
@testable import EchoGuideCore

private actor EnvironmentRunner: BinaryCommandRunning, TimedCommandRunning {
  enum Mode { case good, absent, changedVM, wrongBackend, stopped, readinessFailure }
  let mode: Mode
  var sshCalls = 0
  init(_ mode: Mode) { self.mode = mode }
  func run(executable: String, arguments: [String]) async throws -> CommandResult { throw GuideError.stopped("Unbounded forbidden") }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult { throw GuideError.stopped("Transfers forbidden") }
  func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
    XCTAssertEqual(timeoutSeconds, 25)
    if executable == "/usr/bin/osascript" {
      XCTAssertFalse(arguments[1].contains("stop selectedVM")); XCTAssertFalse(arguments[1].contains("start selectedVM"))
      let id = mode == .changedVM ? UUID().uuidString : arguments.last!
      if mode == .absent { return CommandResult(stdout: "NONE") }
      return CommandResult(stdout: id + "\t" + (mode == .wrongBackend ? "qemu" : "apple") + "\t" + (mode == .stopped ? "stopped" : "started"))
    }
    XCTAssertEqual(executable, "/usr/bin/ssh"); sshCalls += 1
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    let command = arguments.last!
    XCTAssertFalse(command.contains("fastboot devices")); XCTAssertFalse(command.contains("getvar")); XCTAssertFalse(command.contains(" flash "))
    XCTAssertFalse(command.contains("mkdir")); XCTAssertFalse(command.contains("scp"))
    if mode == .readinessFailure { return CommandResult(stdout: "", stderr: "", exitCode: 42) }
    let mock = "{\"matches\":true,\"exit\":1,\"bytes\":4096,\"commands\":[\"flash:brick\"],\"output\":\"isolated mock deliberately rejects flash\"}"
    return CommandResult(stdout: "fastboot version 28.0.0\n" + mock)
  }
  func calls() -> Int { sshCalls }
}
final class NativePilotEnvironmentProverTests: XCTestCase {
  private func fixture(_ runner: EnvironmentRunner) throws -> WorkflowEngine {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let e = try WorkflowEngine(root: root, runner: runner)
    let id = UUID(); let directory = root.appendingPathComponent("guest-" + id.uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let keyFile = directory.appendingPathComponent("client-ed25519")
    try Data("fixture".utf8).write(to: keyFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    let guest = try GuestAdapter(runner: runner, ownedVMID: id, credentialsDirectory: directory, address: "192.168.64.7")
    let key = "ssh-ed25519 " + Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating: UInt8(1), count: 32)).base64EncodedString()
    let fingerprint = try guest.pinHostKey(.init(ownedVMID: id, publicHostKey: key))
    try JSONEncoder().encode(OwnedVMSpecification()).write(to: root.appendingPathComponent("workspace-intent.json"))
    try e.store.transaction {
      $0.vmID = id.uuidString
      $0.guest = GuestWorkspaceRecord(vmID: id, address: guest.address, hostKeyFingerprint: fingerprint, checkedAt: .distantPast, ready: true)
    }
    return e
  }
  private func prover(_ e: WorkflowEngine) -> NativePilotEnvironmentProver {
    NativePilotEnvironmentProver(engine: e, utm: URL(fileURLWithPath: "/fixture/UTM.app"), inspectHost: {
      HostInspection(architecture: "arm64", macOS: "27", writingBackendSupported: true,
        usbInspectionAvailable: true, devices: [], nextAction: "fixture")
    })
  }
  func testObservedProofIsFreshWithoutPersistingOrDeviceQueries() async throws {
    let runner = EnvironmentRunner(.good); let e = try fixture(runner)
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    let original = try e.status()
    let proof = try await prover(e).prove(session: original)
    let observedGuest = try XCTUnwrap(proof.guest)
    XCTAssertEqual(observedGuest.vmID, original.guest?.vmID)
    XCTAssertLessThan(Date().timeIntervalSince(observedGuest.checkedAt), 1)
    XCTAssertEqual(try e.status().guest?.checkedAt, .distantPast)
    XCTAssertTrue(try e.status().operations.isEmpty)
    let calls = await runner.calls(); XCTAssertEqual(calls, 1)
  }
  func testMissingChangedWrongBackendOrStoppedVMCannotQueryGuest() async throws {
    for mode in [EnvironmentRunner.Mode.absent, .changedVM, .wrongBackend, .stopped] {
      let runner = EnvironmentRunner(mode); let e = try fixture(runner)
      defer { try? FileManager.default.removeItem(at: e.store.root) }
      do { _ = try await prover(e).prove(session: e.status()); XCTFail("Bad VM") } catch {}
      let calls = await runner.calls(); XCTAssertEqual(calls, 0)
    }
  }
  func testReadinessFailureCannotBecomeFreshProof() async throws {
    let runner = EnvironmentRunner(.readinessFailure); let e = try fixture(runner)
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    do { _ = try await prover(e).prove(session: e.status()); XCTFail("Bad readiness") } catch {}
    XCTAssertEqual(try e.status().guest?.checkedAt, .distantPast)
  }
  func testChangedPinnedTrustStopsBeforeSSH() async throws {
    let runner = EnvironmentRunner(.good); let e = try fixture(runner)
    defer { try? FileManager.default.removeItem(at: e.store.root) }
    try e.store.transaction { $0.guest = GuestWorkspaceRecord(vmID: $0.guest!.vmID,
      address: $0.guest!.address, hostKeyFingerprint: "changed", checkedAt: .distantPast, ready: true) }
    do { _ = try await prover(e).prove(session: e.status()); XCTFail("Bad trust") } catch {}
    let calls = await runner.calls(); XCTAssertEqual(calls, 0)
  }
}
