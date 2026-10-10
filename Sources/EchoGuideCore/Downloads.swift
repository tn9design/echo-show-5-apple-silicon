import Foundation
import CryptoKit

public struct DownloadArtifact: Sendable {
    public let name: String
    public let url: URL
    public let sha256: String
    public let size: Int64?
    public init(name: String, url: URL, sha256: String, size: Int64? = nil) {
        self.name = name; self.url = url; self.sha256 = sha256; self.size = size
    }
}

public enum PreparationError: LocalizedError {
    case mismatch(String)
    case response
    case unsafeArtifact
    public var errorDescription: String? {
        switch self {
        case .mismatch(let name): return "Hash mismatch for \(name). Existing files were not overwritten."
        case .response: return "Publisher download did not return HTTP 200."
        case .unsafeArtifact: return "Unsafe download name, URL, or symbolic-link destination."
        }
    }
}

public func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

public protocol DownloadTransport: Sendable {
    func download(from url: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> (URL, URLResponse)
}

public struct PublisherDownloadTransport: DownloadTransport {
    public init() {}
    public func download(from url: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate(progress: progress)
        return try await URLSession.shared.download(from: url, delegate: delegate)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: (@Sendable (Int64, Int64?) -> Void)?
    init(progress: (@Sendable (Int64, Int64?) -> Void)?) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

public func prepareArtifact(_ artifact: DownloadArtifact, in folder: URL,
                     progress: (@Sendable (Int64, Int64?) -> Void)? = nil,
                     transport: any DownloadTransport = PublisherDownloadTransport()) async throws -> String {
    try Task.checkCancellation()
    guard !artifact.name.isEmpty, artifact.name != ".", artifact.name != "..",
          !artifact.name.contains("/"), !artifact.name.contains("\\"), !artifact.name.contains("\0"),
          artifact.url.scheme == "https", artifact.url.host != nil,
          artifact.url.user == nil, artifact.url.password == nil else { throw PreparationError.unsafeArtifact }
    let destination = folder.appendingPathComponent(artifact.name)
    let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
    guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else { throw PreparationError.unsafeArtifact }
    func verify(_ file: URL) throws {
        if let expected = artifact.size {
            let actual = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard expected > 0, actual.map(Int64.init) == expected else { throw PreparationError.mismatch(artifact.name) }
        }
        guard try fileSHA256(file) == artifact.sha256 else { throw PreparationError.mismatch(artifact.name) }
    }
    if FileManager.default.fileExists(atPath: destination.path) {
        try verify(destination)
        return "Reused verified file: \(artifact.name)"
    }
    try Task.checkCancellation()
    let (temporary, response) = try await transport.download(from: artifact.url, progress: progress)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PreparationError.response }
    try Task.checkCancellation()
    try verify(temporary)
    try Task.checkCancellation()
    // moveItem refuses to overwrite a file created while downloading.
    try FileManager.default.moveItem(at: temporary, to: destination)
    return "Downloaded and hash verified: \(artifact.name)"
}


extension CompatibilityProfile {
    /// Only publisher-backed artifacts from this versioned, bundled profile.
    public func publisherDownloads() throws -> [DownloadArtifact] {
        let selected = try artifacts.compactMap { artifact -> DownloadArtifact? in
            guard let address = artifact.publisherURL else { return nil }
            guard let url = URL(string: address), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else {
                throw GuideError.stopped("Pinned publisher URL is invalid")
            }
            return DownloadArtifact(name: artifact.name, url: url, sha256: artifact.sha256, size: artifact.size)
        }
        guard !selected.isEmpty else { throw GuideError.stopped("No publisher downloads in the pinned profile") }
        return selected
    }
}

extension WorkflowEngine {
    public func prepareDownloads(in folder: URL,
      progress: (@Sendable (String, Int64, Int64?) -> Void)? = nil,
      transport: any DownloadTransport = PublisherDownloadTransport()
    ) async throws -> [String] {
        var results: [String] = []
        for artifact in try profile.publisherDownloads() {
            try Task.checkCancellation()
            results.append(try await prepareArtifact(artifact, in: folder,
                progress: { bytes, total in progress?(artifact.name, bytes, total) }, transport: transport))
        }
        return results
    }
}
