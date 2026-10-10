import Foundation
import Darwin

public struct PublisherPreparationProgress: Codable, Sendable {
  public let artifact: String?
  public let stage: String
  public let receivedBytes: Int64
  public let expectedBytes: Int64?
  public let verifiedFiles: Int
}

private final class PublisherJob: @unchecked Sendable {
  private let lock = NSLock()
  private let registered = DispatchSemaphore(value: 0)
  private var task: Task<Void, Never>?
  private var failure: String?
  private var finished = false
  func attach(_ task: Task<Void, Never>) { lock.withLock { self.task = task } }
  func begin() { registered.signal() }
  func awaitRegistration() { registered.wait() }
  func completed() { lock.withLock { finished = true } }
  var isFinished: Bool { lock.withLock { finished } }
  func failed(_ message: String) { lock.withLock { failure = message } }
  func wait() async throws {
    let captured = lock.withLock { task }
    await captured?.value
    if let failure = lock.withLock({ failure }) { throw GuideError.stopped(failure) }
  }
}
private final class PublisherTasks: @unchecked Sendable {
  static let shared = PublisherTasks()
  private let lock = NSLock()
  private var jobs: [String: [UUID: PublisherJob]] = [:]
  private var latest: [String: UUID] = [:]
  func register(_ job: PublisherJob, key: String, operationID: UUID) {
    lock.withLock { jobs[key, default: [:]][operationID] = job; latest[key] = operationID }
  }
  func wait(_ key: String, operationID: UUID?) async throws {
    let captured: [PublisherJob] = try lock.withLock {
      if let operationID {
        guard let job = jobs[key]?[operationID] else { throw GuideError.stopped("Publisher operation identifier is not owned by this process") }
        return [job]
      }
      let outstanding = Array(jobs[key]?.values ?? Dictionary<UUID, PublisherJob>().values).filter { !$0.isFinished }
      if !outstanding.isEmpty { return outstanding }
      return latest[key].flatMap { jobs[key]?[$0] }.map { [$0] } ?? []
    }
    var terminalFailure: String?
    for job in captured {
      do { try await job.wait() } catch { terminalFailure = error.localizedDescription }
    }
    if let terminalFailure { throw GuideError.stopped(terminalFailure) }
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
    if let type = attrs?[.type] as? FileAttributeType {
      guard type == .typeDirectory else { throw PreparationError.unsafeArtifact }
    } else {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
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
    let job = PublisherJob()
    let task = Task.detached { [self] in
      job.awaitRegistration()
      defer { flock(fd, LOCK_UN); close(fd); job.completed() }
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
        job.failed(message)
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
          job.failed("Publisher preparation stopped but terminal state could not be saved; inspect the incomplete operation")
        }
      }
    }
    job.attach(task)
    PublisherTasks.shared.register(job, key: key, operationID: operation.id)
    job.begin()
    return operation
  }
  public func waitForPublisherDownloads(operationID: UUID? = nil) async throws {
    try await PublisherTasks.shared.wait(store.root.standardizedFileURL.path, operationID: operationID)
  }
  public func prepareOwnedDownloads() async throws -> OperationRecord {
    let operation = try startPublisherDownloads()
    try await waitForPublisherDownloads(operationID: operation.id)
    guard let observed = try status().operations.first(where: { $0.id == operation.id }), observed.result == "completed" else {
      throw GuideError.stopped("Publisher preparation did not complete")
    }
    return observed
  }
}
