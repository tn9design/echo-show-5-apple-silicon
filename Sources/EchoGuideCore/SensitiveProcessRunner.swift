import Darwin
import Foundation

/// Only fixed, reviewed provisioning commands may use this capability. Output is discarded:
/// a guest could echo input, so no stdout/stderr is returned, logged, or saved to disk.
public protocol SensitiveCommandRunning: Sendable {
  func run(executable: String, arguments: [String], input: Data, timeoutSeconds: Int) async throws -> Int32
}

public struct SensitiveProcessRunner: SensitiveCommandRunning {
  public init() {}
  public func run(executable: String, arguments: [String], input: Data, timeoutSeconds: Int) async throws -> Int32 {
    guard executable.hasPrefix("/"), timeoutSeconds > 0, timeoutSeconds <= 1800,
      !input.isEmpty, input.count <= 4096 else {
      throw GuideError.stopped("Invalid sensitive command request")
    }
    let task = Task.detached { try Self.execute(executable, arguments, input, timeoutSeconds) }
    return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
  }
  private static func execute(_ executable: String, _ arguments: [String], _ input: Data, _ timeout: Int) throws -> Int32 {
    try Task.checkCancellation()
    try Task.checkCancellation()
    // Block SIGPIPE only on this worker thread, avoiding process-wide signal changes.
    var blocked = sigset_t(); var previous = sigset_t()
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE)
    guard pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0 else {
      throw GuideError.stopped("Sensitive input channel unavailable")
    }
    defer {
      var pending = sigset_t(); sigpending(&pending)
      if sigismember(&pending, SIGPIPE) == 1 && sigismember(&previous, SIGPIPE) != 1 {
        var signal: Int32 = 0; sigwait(&blocked, &signal)
      }
      pthread_sigmask(SIG_SETMASK, &previous, nil)
    }
    let pipe = Pipe()
    let discarded = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
    defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close(); try? discarded.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardInput = pipe; process.standardOutput = discarded; process.standardError = discarded
    let fd = pipe.fileHandleForWriting.fileDescriptor
    guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
      throw GuideError.stopped("Sensitive input channel unavailable")
    }
    try Task.checkCancellation()
    do { try process.run() } catch { throw GuideError.stopped("Sensitive command could not start") }
    // The parent must not retain the read end after the child has inherited it.
    try? pipe.fileHandleForReading.close()
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    var sent = 0; var inputFailed = false
    while process.isRunning && ContinuousClock.now < deadline && !Task.isCancelled {
      if sent < input.count && !inputFailed {
        let count = input.withUnsafeBytes { bytes in
          Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), input.count - sent)
        }
        if count > 0 { sent += count }
        else if count < 0 && errno != EAGAIN && errno != EINTR { inputFailed = true }
        if sent == input.count || inputFailed { try? pipe.fileHandleForWriting.close() }
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      process.terminate(); Thread.sleep(forTimeInterval: 0.2)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      if Task.isCancelled { throw CancellationError() }
      throw GuideError.stopped("Sensitive command timed out; inspect outcome before retry")
    }
    process.waitUntilExit()
    if Task.isCancelled { throw CancellationError() }
    guard sent == input.count, !inputFailed else {
      throw GuideError.stopped("Sensitive input delivery failed; no automatic retry")
    }
    return process.terminationStatus
  }
}
