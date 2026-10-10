import Foundation
import CryptoKit

struct DownloadArtifact: Sendable {
    let name: String
    let url: URL
    let sha256: String
    let size: Int64?
    init(name: String, url: URL, sha256: String, size: Int64? = nil) {
        self.name = name; self.url = url; self.sha256 = sha256; self.size = size
    }
}

enum PreparationError: LocalizedError {
    case mismatch(String)
    case response
    case unsafeArtifact
    var errorDescription: String? {
        switch self {
        case .mismatch(let name): return "Hash mismatch for \(name). Existing files were not overwritten."
        case .response: return "Publisher download did not return HTTP 200."
        case .unsafeArtifact: return "Unsafe download name, URL, or symbolic-link destination."
        }
    }
}

func fileSHA256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
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

func prepareArtifact(_ artifact: DownloadArtifact, in folder: URL,
                     progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> String {
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
    let delegate = DownloadProgressDelegate(progress: progress)
    let (temporary, response) = try await URLSession.shared.download(from: artifact.url, delegate: delegate)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PreparationError.response }
    try verify(temporary)
    try Task.checkCancellation()
    // moveItem refuses to overwrite a file created while downloading.
    try FileManager.default.moveItem(at: temporary, to: destination)
    return "Downloaded and hash verified: \(artifact.name)"
}
