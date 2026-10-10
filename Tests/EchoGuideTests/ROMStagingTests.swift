import Foundation
import XCTest
@testable import EchoGuideCore

private actor StagingFake: CommandRunning {
  var calls = 0
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    calls += 1
    return CommandResult(stdout: "unexpected")
  }
  func count() -> Int { calls }
}

private actor OrderedStagingFake: CommandRunning {
  let source: URL
  let artifact: Artifact
  let changeDevice: Bool
  let mutateCopy: Bool
  var index = 0
  init(source: URL, artifact: Artifact, changeDevice: Bool = false, mutateCopy: Bool = false) {
    self.source = source; self.artifact = artifact
    self.changeDevice = changeDevice; self.mutateCopy = mutateCopy
  }
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    let path = ROMStagingAdapter.destination
    let sequence: [[String]] = [
      ["shell", "getprop", "ro.product.device"],
      ["shell", "getprop", "ro.twrp.version"],
      ["shell", "test ! -e " + path + " && test ! -L " + path],
      ["push", source.path, path],
      ["shell", "sha256sum", path],
      ["shell", "stat", "-c", "%s", path],
      ["shell", "getprop", "ro.product.device"],
      ["shell", "getprop", "ro.twrp.version"],
    ]
    guard executable == "/fixture/adb", index < sequence.count,
      arguments == ["-s", "TEST"] + sequence[index]
    else { throw GuideError.stopped("Unexpected fixture command or ordering") }
    let step = index; index += 1
    if step == 3 && mutateCopy {
      let handle = try FileHandle(forWritingTo: source)
      try handle.write(contentsOf: Data([0]))
      try handle.close()
    }
    switch step {
    case 0: return CommandResult(stdout: "checkers\n")
    case 1, 7: return CommandResult(stdout: "3.7.0_9-0\n")
    case 4: return CommandResult(stdout: artifact.sha256 + "  " + path + "\n")
    case 5: return CommandResult(stdout: String(artifact.size!) + "\n")
    case 6: return CommandResult(stdout: changeDevice ? "cronos\n" : "checkers\n")
    default: return CommandResult(stdout: "")
    }
  }
  func count() -> Int { index }
}

final class ROMStagingTests: XCTestCase {
  func testCallerChosenHashCannotStage() async throws {
    let folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let runner = StagingFake()
    let fake = Artifact(name: ROMStagingAdapter.filename, sha256: String(repeating: "a", count: 64), publisherURL: nil, size: 1)
    do {
      _ = try await ROMStagingAdapter(runner: runner).stage(adb: "/fixture/adb", serial: "TEST",
        localROM: URL(fileURLWithPath: "/nonexistent"), artifact: fake,
        evidenceURL: folder.appendingPathComponent("receipt.json"))
      XCTFail("Unsupported artifact accepted")
    } catch {}
    let count = await runner.count()
    XCTAssertEqual(count, 0)
  }

  func testLocalSymlinkCannotStage() async throws {
    let folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("rom")
    try Data("fixture".utf8).write(to: file)
    let link = folder.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let runner = StagingFake()
    do {
      _ = try await ROMStagingAdapter(runner: runner).stage(adb: "/fixture/adb", serial: "TEST",
        localROM: link, artifact: CompatibilityProfile.bundled().artifact(named: ROMStagingAdapter.filename),
        evidenceURL: folder.appendingPathComponent("receipt.json"))
      XCTFail("Symbolic ROM accepted")
    } catch {}
    let count = await runner.count()
    XCTAssertEqual(count, 0)
  }

  func testRemoteHashMustNameExactSingleFile() {
    let hash = String(repeating: "a", count: 64)
    XCTAssertTrue(ROMStagingAdapter.exactRemoteHash(hash + "  " + ROMStagingAdapter.destination, expected: hash))
    XCTAssertFalse(ROMStagingAdapter.exactRemoteHash(hash + "  /other.zip", expected: hash))
    XCTAssertFalse(ROMStagingAdapter.exactRemoteHash(hash + "  " + ROMStagingAdapter.destination + "\n" + hash + "  " + ROMStagingAdapter.destination, expected: hash))
  }

  private func pinnedFixture() throws -> (URL, Artifact, URL) {
    guard let path = ProcessInfo.processInfo.environment["ECHOGUIDE_TEST_PINNED_ROM"] else {
      throw XCTSkip("Set ECHOGUIDE_TEST_PINNED_ROM to the verified public ROM for staging fixtures")
    }
    let folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return (URL(fileURLWithPath: path), try CompatibilityProfile.bundled().artifact(named: ROMStagingAdapter.filename), folder)
  }

  func testPinnedROMStagesWithOrderedFakeAndPrivateReceipt() async throws {
    let (source, artifact, folder) = try pinnedFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let evidence = folder.appendingPathComponent("receipt.json")
    let runner = OrderedStagingFake(source: source, artifact: artifact)
    let receipt = try await ROMStagingAdapter(runner: runner).stage(adb: "/fixture/adb", serial: "TEST",
      localROM: source, artifact: artifact, evidenceURL: evidence)
    let count = await runner.count()
    XCTAssertEqual(count, 8)
    XCTAssertEqual(receipt.sha256, artifact.sha256)
    XCTAssertEqual(receipt.bytes, artifact.size)
    XCTAssertEqual(receipt.destination, ROMStagingAdapter.destination)
    let saved = try JSONDecoder().decode(ROMStagingAdapter.Receipt.self, from: Data(contentsOf: evidence))
    XCTAssertEqual(saved.serial, "TEST")
    XCTAssertEqual(saved.sha256, receipt.sha256)
    let mode = try FileManager.default.attributesOfItem(atPath: evidence.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(mode?.intValue, 0o600)
  }

  func testChangedRecoveryCannotCreateReceipt() async throws {
    let (source, artifact, folder) = try pinnedFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let evidence = folder.appendingPathComponent("receipt.json")
    let runner = OrderedStagingFake(source: source, artifact: artifact, changeDevice: true)
    do {
      _ = try await ROMStagingAdapter(runner: runner).stage(adb: "/fixture/adb", serial: "TEST",
        localROM: source, artifact: artifact, evidenceURL: evidence)
      XCTFail("Changed recovery accepted")
    } catch {}
    let count = await runner.count()
    XCTAssertEqual(count, 7)
    XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.path))
  }

  func testSourceMutationAfterFakePushCannotCreateReceipt() async throws {
    let (source, artifact, folder) = try pinnedFixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let copy = folder.appendingPathComponent("copied-rom.zip")
    try FileManager.default.copyItem(at: source, to: copy)
    let evidence = folder.appendingPathComponent("receipt.json")
    let runner = OrderedStagingFake(source: copy, artifact: artifact, mutateCopy: true)
    do {
      _ = try await ROMStagingAdapter(runner: runner).stage(adb: "/fixture/adb", serial: "TEST",
        localROM: copy, artifact: artifact, evidenceURL: evidence)
      XCTFail("Changed source accepted")
    } catch {}
    let count = await runner.count()
    XCTAssertEqual(count, 6)
    XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.path))
  }
}
