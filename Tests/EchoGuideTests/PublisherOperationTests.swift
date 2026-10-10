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

private actor CancellablePublisherFixture: DownloadTransport {
  let root: URL
  var calls = 0
  init(root: URL) { self.root = root }
  func count() -> Int { calls }
  func download(from url: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> (URL, URLResponse) {
    calls += 1
    if calls > 1 { try await Task.sleep(for: .seconds(30)) }
    let file = root.appendingPathComponent(UUID().uuidString)
    try Data([1]).write(to: file)
    return (file, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
extension PublisherOperationTests {
  func testScopedCancellationRetainsVerifiedFileAndReleasesOwnership() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root)
    let fixture = CancellablePublisherFixture(root: root)
    let hash = "4bf5122f344554c53bde2ebb8cd2b7e3d1600ad631c385a5d7cce23c7785459a"
    let artifacts = ["first.zip", "second.zip"].map { DownloadArtifact(name: $0, url: URL(string: "https://fixture.invalid/" + $0)!, sha256: hash, size: 1) }
    let folder = root.appendingPathComponent("chosen")
    let job = try engine.startPublisherDownloads(artifacts: artifacts, destination: folder, transport: fixture)
    for _ in 0..<100 {
      if await fixture.count() == 2 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let calls = await fixture.count()
    XCTAssertEqual(calls, 2)
    let unrelated = try WorkflowEngine(root: root.appendingPathComponent("other-session"))
    XCTAssertFalse(unrelated.cancelPublisherDownloads(operationID: job.id))
    XCTAssertFalse(engine.cancelPublisherDownloads(operationID: UUID()))
    XCTAssertNil(try engine.status().operations.last?.completedAt)
    XCTAssertTrue(engine.cancelPublisherDownloads(operationID: job.id))
    do { try await engine.waitForPublisherDownloads(operationID: job.id); XCTFail("Cancelled job succeeded") } catch {}
    XCTAssertEqual(try engine.status().downloadProgress?.stage, "cancelled")
    XCTAssertEqual(try engine.status().downloadProgress?.verifiedFiles, 1)
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("first.zip")), Data([1]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("second.zip").path))
    XCTAssertFalse(engine.cancelPublisherDownloads(operationID: job.id))
    let next = try engine.startPublisherDownloads(artifacts: [], destination: folder, transport: fixture)
    try await engine.waitForPublisherDownloads(operationID: next.id)
    XCTAssertEqual(try engine.status().operations.last?.result, "completed")
  }
}
