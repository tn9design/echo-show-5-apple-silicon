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
  static func authenticate(_ terminal: SerialTransport, password: String) async throws {
    try validatePassword(password)
    try await terminal.write(Data("\n".utf8))
    let first = try await terminal.read(untilAny: [Data("login: ".utf8), Data("$ ".utf8)])
    guard let text = String(data: first, encoding: .utf8) else {
      throw GuideError.stopped("Unexpected serial login encoding")
    }
    // An existing shell is verified by the subsequent fresh bootstrap challenge, not this prompt.
    if text.hasSuffix("$ ") { return }
    guard text.hasSuffix("login: ") else {
      throw GuideError.stopped("Ambiguous serial login prompt")
    }
    try await terminal.write(Data("user\n".utf8))
    let prompt = try await terminal.read(untilAny: [Data("Password: ".utf8), Data("login: ".utf8)])
    guard String(data: prompt, encoding: .utf8)?.hasSuffix("Password: ") == true else {
      throw GuideError.stopped("Serial login did not request the user password")
    }
    try await terminal.write(Data((password + "\n").utf8))
    let response = try await terminal.read(untilAny: [
      Data("$ ".utf8), Data("login: ".utf8), Data("Login incorrect".utf8),
    ])
    guard let result = String(data: response, encoding: .utf8), result.hasSuffix("$ "),
      !result.contains("Login incorrect"), !result.contains("login: ")
    else {
      throw GuideError.stopped("Linux login failed; no automatic retry")
    }
  }
}
