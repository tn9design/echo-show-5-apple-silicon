import XCTest
@testable import EchoGuideCore

final class DownloadTests: XCTestCase {
    func testTraversalAndNonHTTPSStopBeforeNetwork() async throws {
        let folder = FileManager.default.temporaryDirectory
        for artifact in [
            DownloadArtifact(name: "../outside", url: URL(string: "https://example.invalid/file")!, sha256: "wrong"),
            DownloadArtifact(name: "file", url: URL(string: "http://example.invalid/file")!, sha256: "wrong")
        ] {
            do { _ = try await prepareArtifact(artifact, in: folder); XCTFail("Unsafe artifact accepted") }
            catch PreparationError.unsafeArtifact { }
        }
    }

    func testSymlinkDestinationRejected() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("fixture"), withDestinationURL: folder.appendingPathComponent("missing"))
        let artifact = DownloadArtifact(name: "fixture", url: URL(string: "https://example.invalid/file")!, sha256: "wrong")
        do { _ = try await prepareArtifact(artifact, in: folder); XCTFail("Symlink accepted") }
        catch PreparationError.unsafeArtifact { }
    }

    func testPinnedSizeMismatchStops() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fixture")
        try Data("abc".utf8).write(to: file)
        let artifact = DownloadArtifact(name: "fixture", url: URL(string: "https://example.invalid/file")!, sha256: try fileSHA256(file), size: 4)
        do { _ = try await prepareArtifact(artifact, in: folder); XCTFail("Wrong size accepted") }
        catch PreparationError.mismatch { }
    }
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
