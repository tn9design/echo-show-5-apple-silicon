import XCTest
@testable import EchoGuideCore

private struct HTTPDownloadFixture: DownloadTransport {
    let directory: URL
    let bytes: Data
    let status: Int
    let cancelOnArrival: Bool
    func download(from url: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> (URL, URLResponse) {
        let partial = directory.appendingPathComponent("fixture-download.partial")
        try bytes.write(to: partial)
        progress?(Int64(bytes.count), Int64(bytes.count))
        if cancelOnArrival { withUnsafeCurrentTask { $0?.cancel() } }
        return (partial, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class PublisherDownloadTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private var artifact: DownloadArtifact {
        DownloadArtifact(name: "pinned.zip", url: URL(string: "https://publisher.invalid/pinned.zip")!,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", size: 3)
    }
    func testHTTPFailureRemovesPartialAndNeverPublishesDestination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await prepareArtifact(artifact, in: root,
                transport: HTTPDownloadFixture(directory: root, bytes: Data("abc".utf8), status: 503, cancelOnArrival: false))
            XCTFail("HTTP failure accepted")
        } catch PreparationError.response {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testHashFailureRemovesPartialAndNeverPublishesDestination() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await prepareArtifact(artifact, in: root,
                transport: HTTPDownloadFixture(directory: root, bytes: Data("bad".utf8), status: 200, cancelOnArrival: false))
            XCTFail("Wrong hash accepted")
        } catch PreparationError.mismatch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testVerifiedTransferPublishedAndPartialRemoved() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try await prepareArtifact(artifact, in: root,
            transport: HTTPDownloadFixture(directory: root, bytes: Data("abc".utf8), status: 200, cancelOnArrival: false))
        XCTAssertTrue(result.contains("Downloaded and hash verified"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pinned.zip")), Data("abc".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["pinned.zip"])
    }
    func testCancellationAfterArrivalDoesNotPublishVerifiedFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = artifact
        let task = Task {
            try await prepareArtifact(descriptor, in: root,
                transport: HTTPDownloadFixture(directory: root, bytes: Data("abc".utf8), status: 200, cancelOnArrival: true))
        }
        do { _ = try await task.value; XCTFail("Cancelled transfer published") }
        catch is CancellationError {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testPublisherSelectionUsesBundledProfile() throws {
        let profile = try CompatibilityProfile.bundled()
        let downloads = try profile.publisherDownloads()
        XCTAssertEqual(Set(downloads.map(\.name)), Set(profile.artifacts.filter { $0.publisherURL != nil }.map(\.name)))
        XCTAssertEqual(downloads.count, 3)
        let iso = try XCTUnwrap(downloads.first { $0.name == "debian-13.7.0-arm64-netinst.iso" })
        XCTAssertEqual(iso.url.absoluteString, "https://cdimage.debian.org/debian-cd/13.7.0/arm64/iso-cd/debian-13.7.0-arm64-netinst.iso")
        XCTAssertEqual(iso.size, 735358976)
        XCTAssertEqual(iso.sha256, "6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b")
        XCTAssertTrue(downloads.allSatisfy { $0.url.scheme == "https" && $0.sha256.count == 64 })
    }
}
