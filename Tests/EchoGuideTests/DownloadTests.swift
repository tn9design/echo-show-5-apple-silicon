import XCTest
@testable import EchoGuide

final class DownloadTests: XCTestCase {
    func testStreamingHash() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try fileSHA256(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testExistingMismatchStopsWithoutOverwrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture")
        try Data("original".utf8).write(to: file)
        let artifact = DownloadArtifact(name: "fixture", url: URL(string: "https://example.invalid/never-contact")!, sha256: "wrong")
        do {
            _ = try await prepareArtifact(artifact, in: folder)
            XCTFail("Mismatch accepted")
        } catch PreparationError.mismatch { }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testVerifiedExistingFileNeedsNoNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture")
        try Data("abc".utf8).write(to: file)
        let artifact = DownloadArtifact(name: "fixture", url: URL(string: "https://example.invalid/never-contact")!, sha256: try fileSHA256(file))
        let result = try await prepareArtifact(artifact, in: folder)
        XCTAssertTrue(result.contains("Reused verified"))
    }
}
