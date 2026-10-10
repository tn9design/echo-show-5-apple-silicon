import Foundation

/// A single bounded login attempt. Password bytes go only to the owned PTY, never a process argument.
enum SerialLogin {
  static func validatePassword(_ password: String) throws {
    guard !password.isEmpty, password.utf8.count <= 1024,
      !password.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else {
      throw GuideError.stopped("Enter a nonempty Linux password without control characters")
    }
  }
  static func authenticate(_ terminal: SerialTransport, password: String, username: String = "user", promptTimeout: TimeInterval = 20) async throws {
    try validatePassword(password)
    let username = try GuestUsername.validated(username)
    // Observe before sending anything: an interrupted invocation may still be at
    // Password, where even a wake newline would submit an unintended credential.
    let first: Data
    do {
      first = try await terminal.read(untilAny: [
        Data("login: ".utf8), Data("$ ".utf8), Data("Password: ".utf8),
        Data("Login incorrect".utf8),
      ], timeout: promptTimeout)
    } catch GuideError.stopped(let message) where message == "Serial response timed out" {
      throw GuideError.stopped("No fresh serial login prompt. Gracefully restart the owned VM before another explicit bootstrap")
    }
    guard let text = String(data: first, encoding: .utf8) else {
      throw GuideError.stopped("Unexpected serial login encoding")
    }
    if text.hasSuffix("Password: ") || text.hasSuffix("Login incorrect") {
      throw GuideError.stopped("Serial login is already in progress. Gracefully restart the owned VM before another explicit bootstrap")
    }
    guard !(await terminal.hasBufferedInput(containing: [
      Data("Password: ".utf8), Data("Login incorrect".utf8),
    ])) else {
      throw GuideError.stopped("Serial login is already in progress. Gracefully restart the owned VM before another explicit bootstrap")
    }
    // An existing shell is verified by the subsequent fresh bootstrap challenge, not this prompt.
    if text.hasSuffix("$ ") { return }
    guard text.hasSuffix("login: ") else {
      throw GuideError.stopped("Ambiguous serial login prompt")
    }
    try await terminal.write(Data((username + "\n").utf8))
    // A delayed duplicate getty prompt is not evidence of a failed username attempt.
    // Await the password request within the same bounded read; credentials are sent once.
    let prompt: Data
    do {
      prompt = try await terminal.read(untilAny: [
        Data("Password: ".utf8), Data("Login incorrect".utf8),
      ], timeout: promptTimeout)
    } catch GuideError.stopped(let message) where message == "Serial response timed out" {
      throw GuideError.stopped("Serial timed out waiting for the password prompt; no password submitted")
    }
    guard String(data: prompt, encoding: .utf8)?.hasSuffix("Password: ") == true else {
      throw GuideError.stopped("Serial login did not request the user password")
    }
    try await terminal.write(Data((password + "\n").utf8))
    let response: Data
    do {
      response = try await terminal.read(untilAny: [
        Data("$ ".utf8), Data("login: ".utf8), Data("Login incorrect".utf8),
      ], timeout: promptTimeout)
    } catch GuideError.stopped(let message) where message == "Serial response timed out" {
      throw GuideError.stopped("Serial timed out waiting for login completion; password submitted once, no retry")
    }
    guard let result = String(data: response, encoding: .utf8), result.hasSuffix("$ "),
      !result.contains("Login incorrect"), !result.contains("login: ")
    else {
      throw GuideError.stopped("Linux login failed; no automatic retry")
    }
  }
}
