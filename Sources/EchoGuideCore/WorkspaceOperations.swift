import Foundation
import Darwin

/// Paths are chosen by the native app, never by MCP arguments. Publisher identity is not implied.
public struct WorkspacePreparationSelection: Codable, Sendable {
  public let utmPath: String
  public let isoPath: String
  public let profileID: String
  public let isoSHA256: String
}

private final class WorkspaceRegistration: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  func wait() { semaphore.wait() }
  func signal() { semaphore.signal() }
}

private final class WorkspaceJobs: @unchecked Sendable {
  static let shared = WorkspaceJobs()
  private let lock = NSLock()
  private var tasks: [String: Task<Void, Never>] = [:]
  func register(_ task: Task<Void, Never>, root: String) { lock.withLock { tasks[root] = task } }
  func wait(root: String) async { await lock.withLock { tasks[root] }?.value }
}

extension WorkflowEngine {
  public func configureWorkspacePreparation(utm: URL, iso: URL) throws {
    let artifact = try workspaceISOArtifact()
    _ = try UTMAdapter.creationScript(application: utm)
    guard iso.isFileURL, try RecoveryAdapter.hash(iso) == artifact.sha256 else {
      throw BackendFailure(.hashMismatch, "Select the pinned Debian installer in the native app")
    }
    try store.transaction { state in
      guard state.vmID == nil, state.operations.allSatisfy({ $0.completedAt != nil }) else {
        throw BackendFailure(.interruptedOperation, "Inspect the existing or interrupted workspace first")
      }
      state.workspaceSelection = WorkspacePreparationSelection(utmPath: utm.path, isoPath: iso.path,
        profileID: profile.id, isoSHA256: artifact.sha256)
    }
  }
  private func workspaceISOArtifact() throws -> Artifact {
    guard let artifact = profile.artifacts.first(where: { $0.name == "debian-13.7.0-arm64-netinst.iso" }) else {
      throw GuideError.stopped("Pinned Debian installer profile is unavailable")
    }
    return artifact
  }
  /// Reserves ownership and records intent before returning; no automatic replay after interruption.
  public func startConfiguredWorkspace() throws -> OperationRecord {
    let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot acquire operation lock") }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd); throw BackendFailure(.concurrentOperation, "Another operation is active")
    }
    let record = OperationRecord(id: UUID(), action: "prepare_workspace", startedAt: Date())
    let selection: WorkspacePreparationSelection
    do {
      selection = try store.transaction { state in
        guard state.operations.allSatisfy({ $0.completedAt != nil }) else {
          throw BackendFailure(.interruptedOperation, "An interrupted operation requires inspection")
        }
        guard state.vmID == nil,
          !FileManager.default.fileExists(atPath: store.root.appendingPathComponent("workspace-intent.json").path) else {
          throw BackendFailure(.interruptedOperation, "Inspect the existing workspace or creation intent")
        }
        guard let selection = state.workspaceSelection, selection.profileID == profile.id,
          selection.isoSHA256 == (try workspaceISOArtifact()).sha256 else {
          throw GuideError.stopped("Choose UTM and the pinned Debian installer in the native app first")
        }
        state.workspaceDiagnostic = nil
        state.operations.append(record)
        return selection
      }
    } catch { flock(fd, LOCK_UN); close(fd); throw error }
    let registered = WorkspaceRegistration()
    let task = Task.detached { [self] in
      registered.wait()
      defer { flock(fd, LOCK_UN); close(fd) }
      do {
        guard try await inspect().writingBackendSupported else { throw BackendFailure(.unsupportedHost, "Unsupported host backend") }
        let iso = URL(fileURLWithPath: selection.isoPath)
        guard try RecoveryAdapter.hash(iso) == selection.isoSHA256 else {
          throw BackendFailure(.hashMismatch, "The selected Debian installer changed")
        }
        try await validateWorkspaceTool(URL(fileURLWithPath: selection.utmPath))
        _ = try await performWorkspaceCreation(utm: URL(fileURLWithPath: selection.utmPath), iso: iso)
        try store.transaction { state in
          if let index = state.operations.firstIndex(where: { $0.id == record.id }) {
            state.operations[index].completedAt = Date(); state.operations[index].result = "completed"
          }
        }
      } catch {
        try? store.transaction { state in
          state.workspaceDiagnostic = BackendDiagnostic(error: error)
          state.phase = .inspectionRequired
          if let index = state.operations.firstIndex(where: { $0.id == record.id }) {
            state.operations[index].completedAt = Date(); state.operations[index].result = "failed; inspection required"
          }
        }
      }
    }
    WorkspaceJobs.shared.register(task, root: store.root.standardizedFileURL.path)
    registered.signal()
    return record
  }
  func validateWorkspaceTool(_ utm: URL) async throws {
    _ = try UTMAdapter.creationScript(application: utm)
    let version = try await runner.run(executable: "/usr/bin/defaults", arguments: ["read", utm.appendingPathComponent("Contents/Info").path, "CFBundleShortVersionString"])
    guard version.exitCode == 0, version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == profile.utmVersion else {
      throw BackendFailure(.unsupportedWorkspaceTool, "Selected UTM version does not match the profile")
    }
  }
  public func waitForWorkspacePreparation() async { await WorkspaceJobs.shared.wait(root: store.root.standardizedFileURL.path) }
}
