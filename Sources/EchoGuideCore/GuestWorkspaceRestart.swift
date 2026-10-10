import Foundation

/// An explicit preparation action, never a fallback after failed authentication.
enum GuestWorkspaceRestart {
  static func run(adapter: UTMAdapter, specification: OwnedVMSpecification, vmID: UUID,
    maximumChecks: Int = 30, interval: Duration = .seconds(1)) async throws {
    var info = try await adapter.info(specification: specification, vmID: vmID)
    guard info.state == .started || info.state == .stopped else {
      throw GuideError.stopped("Workspace is transitioning or paused; restart requires inspection")
    }
    if info.state == .started {
      try Task.checkCancellation()
      info = try await adapter.requestGracefulStop(specification: specification, vmID: vmID)
      for _ in 0..<maximumChecks where info.state != .stopped {
        try Task.checkCancellation()
        guard info.state == .started || info.state == .stopping else {
          throw GuideError.stopped("Unexpected shutdown state; no forced stop or start")
        }
        try await Task.sleep(for: interval)
        info = try await adapter.info(specification: specification, vmID: vmID)
      }
    }
    guard info.state == .stopped else {
      throw GuideError.stopped("Graceful shutdown did not finish; no start or login attempted")
    }
    try Task.checkCancellation()
    info = try await adapter.start(specification: specification, vmID: vmID)
    for _ in 0..<maximumChecks where info.state != .started {
      try Task.checkCancellation()
      guard info.state == .starting else {
        throw GuideError.stopped("Unexpected startup state; no login attempted")
      }
      try await Task.sleep(for: interval)
      info = try await adapter.info(specification: specification, vmID: vmID)
    }
    guard info.state == .started else {
      throw GuideError.stopped("Workspace startup did not finish; no login attempted")
    }
    try Task.checkCancellation()
  }
}
