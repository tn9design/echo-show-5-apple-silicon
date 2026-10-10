import Foundation
import CryptoKit

struct DownloadArtifact: Sendable {
    let name: String
    let url: URL
    let sha256: String
}

enum PreparationError: LocalizedError {
    case mismatch(String)
    case response
    var errorDescription: String? {
        switch self {
        case .mismatch(let name): return "Hash mismatch for \(name). Existing files were not overwritten."
        case .response: return "Publisher download did not return HTTP 200."
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

let preparationArtifacts: [DownloadArtifact] = [
    .init(name: "UTM-5.0.6.dmg", url: URL(string: "https://github.com/utmapp/UTM/releases/download/v5.0.6/UTM.dmg")!, sha256: "6a722486a660e0ab2cf5826bbeaee0f5963999029366709f5a3048d73b1d7cb1"),
    .init(name: "lineage-18.1-20260904-UNOFFICIAL-checkers.zip", url: URL(string: "https://github.com/amazon-oss/releases/releases/download/lineage-18.1-checkers-v0.7/lineage-18.1-20260904-UNOFFICIAL-checkers.zip")!, sha256: "785fa643fd68b2e6f6f02d96a2da58373c6a577b92a27cf6cec69603bb94068e")
]

func prepareArtifact(_ artifact: DownloadArtifact, in folder: URL) async throws -> String {
    let destination = folder.appendingPathComponent(artifact.name)
    if FileManager.default.fileExists(atPath: destination.path) {
        guard try fileSHA256(destination) == artifact.sha256 else { throw PreparationError.mismatch(artifact.name) }
        return "Reused verified file: \(artifact.name)"
    }
    let (temporary, response) = try await URLSession.shared.download(from: artifact.url)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PreparationError.response }
    guard try fileSHA256(temporary) == artifact.sha256 else { throw PreparationError.mismatch(artifact.name) }
    // moveItem refuses to overwrite a file created while downloading.
    try FileManager.default.moveItem(at: temporary, to: destination)
    return "Downloaded and hash verified: \(artifact.name)"
}
