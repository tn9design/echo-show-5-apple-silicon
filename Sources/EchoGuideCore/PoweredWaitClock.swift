import Foundation

/// Safety waiting owns its timer independently of cancellation of the workflow
/// caller. Task.sleep uses a monotonic clock; wall-clock changes cannot shorten it.
struct PoweredWaitClock: UnlockClock {
  private let poweredTickNanoseconds: UInt64
  init() { poweredTickNanoseconds = 1_000_000_000 }
  /// Internal fixture timing only; no public timing or live adapter selection.
  init(testOnlyTickNanoseconds: UInt64) {
    precondition(testOnlyTickNanoseconds > 0)
    poweredTickNanoseconds = testOnlyTickNanoseconds
  }
  func sleep(seconds: Int) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
  }
  func poweredWaitSecond() async throws {
    let interval = poweredTickNanoseconds
    let timer = Task.detached(priority: .utility) {
      try await Task.sleep(nanoseconds: interval)
    }
    // Awaiting an unstructured detached task does not propagate caller cancel.
    try await timer.value
  }
}
