import XCTest
@testable import EchoGuideCore

private actor PublisherOperationFixture: DownloadTransport {
  let directory: URL
  let cancel: Bool
  var urls: [URL] = []
  init(directory: URL, cancel: Bool = false) { self.directory = directory; self.cancel = cancel }
  func download(from url: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> (URL, URLResponse) {
    urls.append(url)
    try await Task.sleep(nanoseconds: 200_000_000)
    let partial = directory.appendingPathComponent(UUID().uuidString + ".partial")
    try Data([1]).write(to: partial)
    progress?(1, 1)
    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    return (partial, HTTPURLResponse(url: url, statusCode: cancel ? 200 : 503, httpVersion: nil, headerFields: nil)!)
  }
}

final class PublisherOperationTests: XCTestCase {
  func testOwnedPinnedDownloadReturnsIDRetainsLockAndPersistsFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    let fixture = PublisherOperationFixture(directory: root)
    let operation = try engine.startPublisherDownloads(transport: fixture)
    XCTAssertEqual(operation.action, "prepare_downloads")
    XCTAssertNil(try engine.status().operations.last?.completedAt)
    let second = try WorkflowEngine(root: root)
    XCTAssertThrowsError(try second.startPublisherDownloads(transport: fixture))
    do { try await engine.waitForPublisherDownloads(); XCTFail("HTTP failure became completion") }
    catch {}
    let state = try engine.status()
    XCTAssertEqual(state.operations.count, 1)
    XCTAssertEqual(state.operations.last?.id, operation.id)
    XCTAssertEqual(state.operations.last?.result, "failed")
    XCTAssertNotNil(state.operations.last?.completedAt)
    XCTAssertEqual(state.downloadProgress?.stage, "failed")
    XCTAssertEqual(state.downloadProgress?.verifiedFiles, 0)
    XCTAssertEqual(state.phase, .setup)
    XCTAssertNil(state.vmID)
    let urls = await fixture.urls
    XCTAssertEqual(urls, [try engine.profile.publisherDownloads()[0].url])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("downloads").path).isEmpty)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasSuffix(".partial") }))
  }

  func testCancellationPersistsTruthfulOutcomeWithoutFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    _ = try engine.startPublisherDownloads(transport: PublisherOperationFixture(directory: root, cancel: true))
    do { try await engine.waitForPublisherDownloads(); XCTFail("Cancellation became success") }
    catch {}
    XCTAssertEqual(try engine.status().downloadProgress?.stage, "cancelled")
    XCTAssertEqual(try engine.status().operations.last?.result, "failed")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("downloads").path).isEmpty)
  }

  func testExactWaiterKeepsEarlierOutcomeWhenLaterOperationStarts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    let first = try engine.startPublisherDownloads(transport: PublisherOperationFixture(directory: root))
    do { try await engine.waitForPublisherDownloads(operationID: first.id); XCTFail("Expected first HTTP failure") } catch {}
    let second = try engine.startPublisherDownloads(transport: PublisherOperationFixture(directory: root, cancel: true))
    do { try await engine.waitForPublisherDownloads(operationID: first.id); XCTFail("Earlier failure was lost") }
    catch { XCTAssertTrue(error.localizedDescription.contains("failed")) }
    XCTAssertNil(try engine.status().operations.first(where: { $0.id == second.id })?.completedAt)
    do { try await engine.waitForPublisherDownloads(operationID: second.id); XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error.localizedDescription.contains("cancelled")) }
    XCTAssertEqual(try engine.status().operations.count, 2)
  }

  func testRegularFileCannotBeUsedAsOwnedDownloadDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    try Data("preserve".utf8).write(to: root.appendingPathComponent("downloads"))
    XCTAssertThrowsError(try engine.startPublisherDownloads(transport: PublisherOperationFixture(directory: root)))
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("downloads")), Data("preserve".utf8))
    XCTAssertTrue(try engine.status().operations.isEmpty)
  }

  func testSymlinkOwnedDirectoryStopsBeforeReservation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("downloads"), withDestinationURL: root)
    XCTAssertThrowsError(try engine.startPublisherDownloads(transport: PublisherOperationFixture(directory: root)))
    XCTAssertTrue(try engine.status().operations.isEmpty)
  }
}
