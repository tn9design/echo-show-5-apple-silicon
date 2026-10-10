import Foundation
import Darwin

public struct PublisherPreparationProgress: Codable, Sendable {
  public let artifact: String?
  public let stage: String
  public let receivedBytes: Int64
  public let expectedBytes: Int64?
  public let verifiedFiles: Int
}

private final class PublisherTasks: @unchecked Sendable {
  static let shared = PublisherTasks()
  private let lock = NSLock()
  private var tasks: [String: Task<Void, Never>] = [:]
  private var failures: [String: String] = [:]
  func reset(_ key: String) { lock.withLock { _ = failures.removeValue(forKey: key) } }
  func register(_ task: Task<Void, Never>, key: String) { lock.withLock { tasks[key] = task } }
  func failed(_ key: String, message: String) { lock.withLock { failures[key] = message } }
  func wait(_ key: String) async throws {
    let task = lock.withLock { tasks[key] }
    await task?.value
    if let failure = lock.withLock({ failures[key] }) { throw GuideError.stopped(failure) }
  }
}

extension WorkflowEngine {
  /// Publisher URLs and artifacts are chosen exclusively from the bundled profile.
  /// This prepares files only. It never creates, starts, or validates a Linux VM.
  public func startPublisherDownloads(
    transport: any DownloadTransport = PublisherDownloadTransport()
  ) throws -> OperationRecord {
    let artifacts = try profile.publisherDownloads()
    let folder = store.root.appendingPathComponent("downloads", isDirectory: true)
    let attrs = try? FileManager.default.attributesOfItem(atPath: folder.path)
    guard attrs?[.type] as? FileAttributeType != .typeSymbolicLink else {
      throw PreparationError.unsafeArtifact
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot acquire operation lock") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd); throw GuideError.stopped("Another operation is active")
    }
    let operation = OperationRecord(id: UUID(), action: "prepare_downloads", startedAt: Date())
    do {
      try store.transaction { state in
        guard state.operations.allSatisfy({ $0.completedAt != nil }) else {
          throw GuideError.stopped("An interrupted operation requires inspection; downloads are not restarted automatically")
        }
        state.operations.append(operation)
        state.downloadProgress = .init(artifact: nil, stage: "starting", receivedBytes: 0, expectedBytes: nil, verifiedFiles: 0)
      }
    } catch {
      flock(fd, LOCK_UN); close(fd); throw error
    }
    let key = store.root.standardizedFileURL.path
    PublisherTasks.shared.reset(key)
    let task = Task.detached { [self] in
      defer { flock(fd, LOCK_UN); close(fd) }
      var verifiedFiles = 0
      do {
        for artifact in artifacts {
          try Task.checkCancellation()
          let completed = verifiedFiles
          try store.transaction { state in
            state.downloadProgress = .init(artifact: artifact.name, stage: "downloading or verifying", receivedBytes: 0, expectedBytes: artifact.size, verifiedFiles: completed)
          }
          _ = try await prepareArtifact(artifact, in: folder, progress: { bytes, expected in
            try? self.store.transaction { state in
              state.downloadProgress = .init(artifact: artifact.name, stage: "receiving", receivedBytes: bytes, expectedBytes: expected, verifiedFiles: completed)
            }
          }, transport: transport)
          verifiedFiles += 1
        }
        try store.transaction { state in
          state.downloadProgress = .init(artifact: nil, stage: "verified downloads ready; Linux workspace not prepared", receivedBytes: 0, expectedBytes: nil, verifiedFiles: verifiedFiles)
          if let index = state.operations.firstIndex(where: { $0.id == operation.id }) {
            state.operations[index].completedAt = Date()
            state.operations[index].result = "completed"
          }
        }
      } catch {
        let message = error is CancellationError ? "Publisher preparation cancelled" : "Publisher preparation failed; inspect downloaded files before explicitly retrying"
        PublisherTasks.shared.failed(key, message: message)
        do {
          try store.transaction { state in
            let previous = state.downloadProgress
            state.downloadProgress = .init(artifact: previous?.artifact, stage: error is CancellationError ? "cancelled" : "failed", receivedBytes: previous?.receivedBytes ?? 0, expectedBytes: previous?.expectedBytes, verifiedFiles: verifiedFiles)
            if let index = state.operations.firstIndex(where: { $0.id == operation.id }) {
              state.operations[index].completedAt = Date()
              state.operations[index].result = "failed"
            }
          }
        } catch {
          PublisherTasks.shared.failed(key, message: "Publisher preparation stopped but terminal state could not be saved; inspect the incomplete operation")
        }
      }
    }
    PublisherTasks.shared.register(task, key: key)
    return operation
  }
  public func waitForPublisherDownloads() async throws {
    try await PublisherTasks.shared.wait(store.root.standardizedFileURL.path)
  }
  public func prepareOwnedDownloads() async throws -> OperationRecord {
    let operation = try startPublisherDownloads()
    try await waitForPublisherDownloads()
    guard let observed = try status().operations.first(where: { $0.id == operation.id }), observed.result == "completed" else {
      throw GuideError.stopped("Publisher preparation did not complete")
    }
    return observed
  }
}
