import XCTest

@testable import EchoGuideCore

final class PilotTests: XCTestCase {
  func testExactIdentityRejectsPrefixesDuplicates() {
    XCTAssertTrue(
      PilotSequence.exactGetvar("product: CHECKERS\n", key: "product", expected: "CHECKERS"))
    XCTAssertFalse(
      PilotSequence.exactGetvar("product: CHECKERS-extra\n", key: "product", expected: "CHECKERS"))
    XCTAssertFalse(
      PilotSequence.exactGetvar(
        "product: CHECKERS\nproduct: CHECKERS\n", key: "product", expected: "CHECKERS"))
  }
  func testTimeoutAndPartialOutputNeverPermitRetry() {
    XCTAssertFalse(PilotSequence.ordinaryRejection("Sending 'brick' (111789 KB)...", exit: 124))
    XCTAssertFalse(
      PilotSequence.ordinaryRejection(
        "OKAY [ 1.00s]\nFAILED (remote: the command you input is restricted on locked hw)", exit: 1)
    )
  }
  func testCompleteRejectionAndExtraOutput() {
    let s =
      "target reported max download size of 114294784 bytes\nSending 'brick' (111785 KB)...\nOKAY [ 1.000s]\nWriting 'brick'...\nFAILED (remote: the command you input is restricted on locked hw)\nFinished. Total time: 1.000s"
    XCTAssertTrue(PilotSequence.ordinaryRejection(s, exit: 1))
    XCTAssertFalse(PilotSequence.ordinaryRejection(s + "\nERROR unexpected", exit: 1))
  }
}

private actor InstallFixture: CommandRunning {
  var commands: [[String]] = []
  var logCalls = 0
  let staleLog: Bool
  let badHash: Bool
  let failedWipe: Bool
  let failedInstaller: Bool
  let ambiguousHash: Bool
  init(
    badHash: Bool = false, failedWipe: Bool = false, failedInstaller: Bool = false,
    staleLog: Bool = false, ambiguousHash: Bool = false
  ) {
    self.staleLog = staleLog
    self.badHash = badHash
    self.failedWipe = failedWipe
    self.failedInstaller = failedInstaller
    self.ambiguousHash = ambiguousHash
  }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    commands.append(arguments)
    if arguments.contains("sha256sum") {
      let line = String(repeating: badHash ? "0" : "a", count: 64) + "  " + ROMStagingAdapter.destination
      return CommandResult(stdout: ambiguousHash ? line + "\n" + line : line)
    }
    if arguments.contains("wipe") && failedWipe {
      return CommandResult(stdout: "failed", exitCode: 1)
    }
    if arguments.contains("/tmp/recovery.log") {
      logCalls += 1
      if logCalls == 1 && !staleLog { return CommandResult(stdout: "") }
      return CommandResult(
        stdout:
          "Installing zip file '/sdcard/lineage-18.1-20260904-UNOFFICIAL-checkers.zip'\nUpdater process ended with RC=\(failedInstaller ? 1 : 0)\nI:operation_end - status=\(failedInstaller ? 1 : 0)"
      )
    }
    return CommandResult(stdout: "")
  }
  func snapshot() -> [[String]] { commands }
}
extension PilotTests {
  func testAmbiguousHashStopsBeforeWipe() async throws {
    let runner = InstallFixture(ambiguousHash: true)
    do {
      try await PilotSequence(runner: runner).install(
        adb: "/fixture/adb", serial: "TEST", romHash: String(repeating: "a", count: 64),
        saveLog: URL(fileURLWithPath: "/unused"))
      XCTFail("Duplicate hash output accepted")
    } catch {}
    let commands = await runner.snapshot()
    XCTAssertFalse(commands.contains { $0.contains("wipe") })
  }

  func testBadROMStopsBeforeWipe() async throws {
    let r = InstallFixture(badHash: true)
    do {
      try await PilotSequence(runner: r).install(
        adb: "/fixture/adb", serial: "TEST", romHash: String(repeating: "a", count: 64),
        saveLog: URL(fileURLWithPath: "/unused"))
      XCTFail()
    } catch {}
    let c = await r.snapshot()
    XCTAssertFalse(c.contains { $0.contains("wipe") })
  }
  func testFailedWipeStopsBeforeInstall() async throws {
    let r = InstallFixture(failedWipe: true)
    do {
      try await PilotSequence(runner: r).install(
        adb: "/fixture/adb", serial: "TEST", romHash: String(repeating: "a", count: 64),
        saveLog: URL(fileURLWithPath: "/unused"))
      XCTFail()
    } catch {}
    let c = await r.snapshot()
    XCTAssertFalse(c.contains { $0.contains("install") })
    XCTAssertFalse(c.contains { $0.contains("reboot") })
  }
  func testFailedInstallerSavesLogAndNeverReboots() async throws {
    let r = InstallFixture(failedInstaller: true)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    do {
      try await PilotSequence(runner: r).install(
        adb: "/fixture/adb", serial: "TEST", romHash: String(repeating: "a", count: 64),
        saveLog: file)
      XCTFail()
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    let c = await r.snapshot()
    XCTAssertFalse(c.contains { $0.contains("reboot") })
  }
}

extension PilotTests {
  func testStaleSameROMSuccessCannotReboot() async throws {
    let r = InstallFixture(staleLog: true)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    do {
      try await PilotSequence(runner: r).install(
        adb: "/fixture/adb", serial: "TEST", romHash: String(repeating: "a", count: 64),
        saveLog: file)
      XCTFail("Stale success accepted")
    } catch {}
    let commands = await r.snapshot()
    XCTAssertFalse(commands.contains { $0.contains("reboot") })
  }
}
