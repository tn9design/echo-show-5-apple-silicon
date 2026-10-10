import Foundation

public struct ProcessRunner: BinaryCommandRunning {
  public init() {}
  public func run(executable: String, arguments: [String]) async throws -> CommandResult {
    let task = Task.detached { try Self.execute(executable, arguments, nil) }
    return try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
  }
  public func runToFile(executable: String, arguments: [String], destination: URL) async throws
    -> CommandResult
  {
    let task = Task.detached { try Self.execute(executable, arguments, destination) }
    return try await withTaskCancellationHandler(
      operation: { try await task.value }, onCancel: { task.cancel() })
  }
  private static func execute(_ executable: String, _ arguments: [String], _ destination: URL?)
    throws -> CommandResult
  {
    guard executable.hasPrefix("/") else {
      throw GuideError.stopped("Executable must have an absolute path")
    }
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent("EchoGuide-" + UUID().uuidString)
    try fm.createDirectory(
      at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: temp) }
    let out = destination ?? temp.appendingPathComponent("stdout")
    let err = temp.appendingPathComponent("stderr")
    guard !fm.fileExists(atPath: out.path),
      fm.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]),
      fm.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw GuideError.stopped("Output destination already exists or cannot be created") }
    let stdout = try FileHandle(forWritingTo: out)
    let stderr = try FileHandle(forWritingTo: err)
    defer {
      try? stdout.close()
      try? stderr.close()
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    p.standardOutput = stdout
    p.standardError = stderr
    try p.run()
    let deadline = Date().addingTimeInterval(
      destination == nil ? (arguments.contains("sha256sum") ? 1800 : 300) : 1800)
    while p.isRunning && Date() < deadline && !Task.isCancelled {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if p.isRunning {
      p.terminate()
      Thread.sleep(forTimeInterval: 0.2)
      if p.isRunning { kill(p.processIdentifier, SIGKILL) }
      p.waitUntilExit()
      if Task.isCancelled { throw CancellationError() }
      throw GuideError.stopped("Command timed out; outcome requires inspection")
    }
    p.waitUntilExit()
    return CommandResult(
      stdout: destination == nil ? String(decoding: try Data(contentsOf: out), as: UTF8.self) : "",
      stderr: String(decoding: try Data(contentsOf: err), as: UTF8.self),
      exitCode: p.terminationStatus)
  }
}
