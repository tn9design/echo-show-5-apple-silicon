import Foundation

/// Native lifecycle revocation and durable approval consumption share this lock.
/// Closure/cancellation wins if it occurs first; after consumption, safety work
/// owns the operation and must continue independently of native-window lifetime.
final class NativeConfirmationLease: @unchecked Sendable {
  private enum State { case active, revoked, consumed }
  private let lock = NSLock()
  private var state: State = .active
  func revoke() {
    lock.lock(); defer { lock.unlock() }
    if state == .active { state = .revoked }
  }
  func consuming<T>(_ body: () throws -> T) throws -> T {
    lock.lock(); defer { lock.unlock() }
    guard state == .active else { throw GuideError.stopped("Native confirmation was revoked or already consumed") }
    let result = try body()
    state = .consumed
    return result
  }
}
