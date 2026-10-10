import XCTest
@testable import EchoGuideCore

private actor ReceiptRunner: TimedCommandRunning {
  let result: CommandResult
  var calls = 0
  init(_ result: CommandResult) { self.result = result }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTFail("Inspection requires a bounded runner")
    throw GuideError.stopped("Unbounded command")
  }
  func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
    calls += 1
    XCTAssertEqual(executable, "/usr/bin/ssh")
    XCTAssertEqual(timeoutSeconds, 20)
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    let script = arguments.last!
    XCTAssertTrue(script.contains("sha256sum -c -"))
    XCTAssertTrue(script.contains("helper.sh inspect"))
    for forbidden in ["sudo", " dispatch ", "mkdir", "systemctl start", "rm "] {
      XCTAssertFalse(script.contains(forbidden))
    }
    return result
  }
  func count() -> Int { calls }
}

final class TranslationReceiptAdapterTests: XCTestCase {
  func testBoundedInspectionRejectsTransportAndUnexpectedFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["client-ed25519", "known_hosts"] { try Data("fixture".utf8).write(to: root.appendingPathComponent(name)) }
    let vm = UUID()
    let hash = try CompatibilityProfile.bundled().artifact(named: "setup-linux-translation.sh").sha256
    let binding = TranslationAttemptBinding(attempt: UUID(), vm: vm, session: UUID(), boot: UUID(), hash: hash, account: "echotest")
    for result in [CommandResult(stdout: "ECHOGUIDE-INSPECTION-v1\ncategory=unknown\nEND\n"),
                   CommandResult(stdout: "unexpected"), CommandResult(stdout: "", exitCode: 255)] {
      let runner = ReceiptRunner(result)
      let guest = try GuestAdapter(runner: runner, ownedVMID: vm, credentialsDirectory: root, address: "192.168.64.7", username: "echotest")
      if result.exitCode == 0 && result.stdout.hasPrefix("ECHOGUIDE") {
        let observed = try await guest.inspectTranslationAttempt(binding)
        XCTAssertEqual(observed.state, .unknown)
      } else {
        do { _ = try await guest.inspectTranslationAttempt(binding); XCTFail("Invalid evidence must stop") } catch {}
      }
      let count = await runner.count(); XCTAssertEqual(count, 1)
      for wrong in [TranslationAttemptBinding(attempt: binding.attempt, vm: UUID(), session: binding.session, boot: binding.boot, hash: hash, account: "echotest"),
                    TranslationAttemptBinding(attempt: binding.attempt, vm: vm, session: binding.session, boot: binding.boot, hash: hash, account: "other")] {
        do { _ = try await guest.inspectTranslationAttempt(wrong); XCTFail("Wrong identity must stop before SSH") } catch {}
      }
      let finalCount = await runner.count(); XCTAssertEqual(finalCount, 1)
    }
  }
}
