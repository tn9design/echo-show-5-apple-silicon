import Foundation
import XCTest
@testable import EchoGuideCore

private actor TranslationCommands: CommandRunning {
  var calls: [[String]] = []
  let failAt: Int?
  init(failAt: Int? = nil) { self.failAt = failAt }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    calls.append([executable] + arguments)
    return CommandResult(stdout: "fixture output must not become a status", exitCode: calls.count == failAt ? 1 : 0)
  }
  func recorded() -> [[String]] { calls }
}
private actor TranslationInput: SensitiveCommandRunning {
  var calls = 0
  let code: Int32
  init(code: Int32 = 0) { self.code = code }
  func run(executable: String, arguments: [String], input: Data, timeoutSeconds: Int) async throws -> Int32 {
    calls += 1
    XCTAssertEqual(executable, "/usr/bin/ssh")
    XCTAssertTrue(arguments.contains("StrictHostKeyChecking=yes"))
    XCTAssertFalse(arguments.joined().contains("fixture-secret"))
    XCTAssertEqual(input, Data("fixture-secret\n".utf8))
    XCTAssertEqual(timeoutSeconds, 1800)
    XCTAssertTrue(arguments.last!.hasPrefix("sudo -S -k -p '' /bin/bash -c '"))
    XCTAssertTrue(arguments.last!.contains("mktemp /run/echoguide-translation.XXXXXX"))
    XCTAssertTrue(arguments.last!.contains("sha256sum -c -"))
    let syntax = Process()
    syntax.executableURL = URL(fileURLWithPath: "/bin/bash")
    syntax.arguments = ["-n", "-c", arguments.last!]
    try syntax.run(); syntax.waitUntilExit()
    XCTAssertEqual(syntax.terminationStatus, 0)
    return code
  }
  func count() -> Int { calls }
}
final class GuestTranslationTests: XCTestCase {
  private func guest(_ runner: TranslationCommands) throws -> (GuestAdapter, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["client-ed25519", "known_hosts"] {
      try Data("fixture".utf8).write(to: folder.appendingPathComponent(name))
    }
    return (try GuestAdapter(runner: runner, ownedVMID: UUID(), credentialsDirectory: folder,
      address: "192.168.64.7", username: "echotest"), folder)
  }
  func testBundledScriptMatchesPinnedProfile() throws {
    XCTAssertTrue(FileManager.default.fileExists(atPath: try GuestAdapter.bundledTranslationSetup().path))
  }
  func testSetupUsesPinnedTransferAndOnePrivatePasswordSubmission() async throws {
    let runner = TranslationCommands(), input = TranslationInput()
    let (guest, folder) = try guest(runner)
    defer { try? FileManager.default.removeItem(at: folder) }
    try await guest.configureTranslation(password: "fixture-secret", sensitiveRunner: input)
    let calls = await runner.recorded()
    XCTAssertEqual(calls.count, 3)
    XCTAssertEqual(calls[1].first, "/usr/bin/scp")
    XCTAssertFalse(calls[1].contains("-T"))
    XCTAssertTrue(calls.allSatisfy { $0.contains("StrictHostKeyChecking=yes") })
    XCTAssertFalse(calls.joined().joined().contains("fixture-secret"))
    let submissions = await input.count()
    XCTAssertEqual(submissions, 1)
  }
  func testEachStagingFailureStopsBeforePassword() async throws {
    for stage in 1...3 {
      let runner = TranslationCommands(failAt: stage), input = TranslationInput()
      let (guest, folder) = try guest(runner)
      defer { try? FileManager.default.removeItem(at: folder) }
      do { try await guest.configureTranslation(password: "fixture-secret", sensitiveRunner: input); XCTFail("Expected stop") }
      catch { XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
      let calls = await runner.recorded(), submissions = await input.count()
      XCTAssertEqual(calls.count, stage)
      XCTAssertEqual(submissions, 0)
    }
  }
  func testSudoFailureIsNotRetriedOrExposed() async throws {
    let runner = TranslationCommands(), input = TranslationInput(code: 1)
    let (guest, folder) = try guest(runner)
    defer { try? FileManager.default.removeItem(at: folder) }
    do { try await guest.configureTranslation(password: "fixture-secret", sensitiveRunner: input); XCTFail("Expected stop") }
    catch { XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
    let submissions = await input.count()
    XCTAssertEqual(submissions, 1)
  }
}
