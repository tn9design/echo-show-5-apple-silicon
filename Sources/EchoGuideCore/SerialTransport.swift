import Darwin
import Foundation

/// Owns one verified PTY descriptor. No transcript or credential is persisted.
public actor SerialTransport {
  private var descriptor: Int32
  private var originalSettings: termios
  private var reading = false
  private var writing = false
  public let channel: OwnedSerialChannel

  public init(channel: OwnedSerialChannel) throws {
    guard channel.portID == 0,
      channel.path.range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil
    else { throw GuideError.stopped("Invalid owned serial channel") }
    var before = stat()
    guard lstat(channel.path, &before) == 0,
      before.st_mode & S_IFMT == S_IFCHR
    else { throw GuideError.stopped("Owned serial channel is not a character device") }
    let fd = Darwin.open(channel.path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_NOFOLLOW)
    guard fd >= 0 else { throw GuideError.stopped("Cannot open owned serial channel") }
    var after = stat()
    guard fstat(fd, &after) == 0, after.st_dev == before.st_dev,
      after.st_ino == before.st_ino, after.st_rdev == before.st_rdev
    else {
      Darwin.close(fd)
      throw GuideError.stopped("Owned serial channel changed while opening")
    }
    var settings = termios()
    guard tcgetattr(fd, &settings) == 0 else {
      Darwin.close(fd)
      throw GuideError.stopped("Cannot inspect serial terminal settings")
    }
    originalSettings = settings
    cfmakeraw(&settings)
    guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
      Darwin.close(fd)
      throw GuideError.stopped("Cannot configure serial terminal")
    }
    self.descriptor = fd
    self.channel = channel
  }
  deinit {
    if descriptor >= 0 {
      tcsetattr(descriptor, TCSANOW, &originalSettings)
      Darwin.close(descriptor)
    }
  }
  public func close() {
    if descriptor >= 0 {
      tcsetattr(descriptor, TCSANOW, &originalSettings)
      Darwin.close(descriptor)
      descriptor = -1
    }
  }
  /// Each call is bounded and cancellable; bytes may contain a password and are never logged.
  public func write(_ data: Data, timeout: TimeInterval = 5) async throws {
    guard !data.isEmpty, data.count <= 65_536, timeout > 0, timeout <= 60 else {
      throw GuideError.stopped("Invalid bounded serial write")
    }
    guard !writing else { throw GuideError.stopped("Serial write already active") }
    writing = true
    defer { writing = false }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    var offset = 0
    while offset < data.count {
      try Task.checkCancellation()
      guard descriptor >= 0 else { throw GuideError.stopped("Serial channel closed") }
      let count = data.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count > 0 {
        offset += count
        continue
      }
      guard count < 0 && [EAGAIN, EINTR].contains(errno) else {
        throw GuideError.stopped("Serial write disconnected or failed")
      }
      guard clock.now < deadline else { throw GuideError.stopped("Serial write timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  /// Returns when a complete marker arrives. Timeout/overflow never supplies partial evidence.
  public func read(until marker: Data, timeout: TimeInterval = 20, limit: Int = 65_536)
    async throws -> Data
  {
    guard !marker.isEmpty, marker.count <= 1024, timeout > 0, timeout <= 60,
      limit >= marker.count, limit <= 262_144
    else { throw GuideError.stopped("Invalid bounded serial read") }
    guard !reading else { throw GuideError.stopped("Serial read already active") }
    reading = true
    defer { reading = false }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      try Task.checkCancellation()
      guard descriptor >= 0 else { throw GuideError.stopped("Serial channel closed") }
      let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit - output.count))
      if count > 0 {
        output.append(contentsOf: buffer.prefix(count))
        if output.range(of: marker) != nil { return output }
        guard output.count < limit else {
          throw GuideError.stopped("Serial response exceeded limit")
        }
      } else if count == 0 {
        throw GuideError.stopped("Serial channel disconnected")
      } else if ![EAGAIN, EINTR].contains(errno) {
        throw GuideError.stopped("Serial read failed")
      }
      guard clock.now < deadline else { throw GuideError.stopped("Serial response timed out") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
