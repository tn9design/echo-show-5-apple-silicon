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
}
