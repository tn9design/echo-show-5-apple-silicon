import Darwin
import XCTest

@testable import EchoGuideCore

final class SerialLoginTests: XCTestCase {
  func testTimeoutReportsWhetherPasswordWasSubmitted() async throws {
    for passwordPrompt in [false, true] {
      var master: Int32 = -1; var slave: Int32 = -1
      var name = [CChar](repeating: 0, count: 1024)
      guard openpty(&master, &slave, &name, nil, nil) == 0 else { return XCTFail("PTY unavailable") }
      defer { Darwin.close(master); Darwin.close(slave) }
      _ = fcntl(master, F_SETFL, O_NONBLOCK)
      let terminal = try SerialTransport(channel: .init(vmID: UUID(), portID: 0, path: String(cString: name)))
      let fd = master
      let peer = Task.detached { () -> Data in
        let login = Data("debian login: ".utf8)
        _ = login.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, login.count) }
        var received = Data(); var sentPrompt = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var bytes = [UInt8](repeating: 0, count: 128)
        while ContinuousClock.now < deadline {
          let count = Darwin.read(fd, &bytes, bytes.count)
          if count > 0 { received.append(contentsOf: bytes.prefix(count)) }
          if passwordPrompt && !sentPrompt && received.contains(10) {
            let prompt = Data("Password: ".utf8)
            _ = prompt.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, prompt.count) }
            sentPrompt = true
          }
          usleep(1000)
        }
        return received
      }
      do {
        try await SerialLogin.authenticate(terminal, password: "fixture-only", promptTimeout: 0.2)
        XCTFail("Expected timeout")
      } catch {
        XCTAssertEqual(error.localizedDescription, passwordPrompt
          ? "Serial timed out waiting for login completion; password submitted once, no retry"
          : "Serial timed out waiting for the password prompt; no password submitted")
        XCTAssertFalse(error.localizedDescription.contains("fixture-only"))
      }
      let received = await peer.value
      XCTAssertEqual(String(decoding: received, as: UTF8.self), passwordPrompt ? "user\nfixture-only\n" : "user\n")
      await terminal.close()
    }
  }
  func testRejectsTerminalControlCharacters() throws {
    for password in ["", "x\nuser", "x\r", "x\u{1b}", String(repeating: "a", count: 1025)] {
      XCTAssertThrowsError(try SerialLogin.validatePassword(password))
    }
    XCTAssertNoThrow(try SerialLogin.validatePassword("a test password"))
  }
  func testLoginAndRejectionOnIsolatedTerminal() async throws {
    for (accepted, duplicatePrompt, existingShell) in [
      (true, false, false), (false, false, false), (true, true, false), (true, false, true),
    ] {
      var master: Int32 = -1
      var slave: Int32 = -1
      var name = [CChar](repeating: 0, count: 1024)
      guard openpty(&master, &slave, &name, nil, nil) == 0 else {
        return XCTFail("PTY unavailable")
      }
      defer {
        Darwin.close(master)
        Darwin.close(slave)
      }
      _ = fcntl(master, F_SETFL, O_NONBLOCK)
      let account = duplicatePrompt ? "echotest" : "user"
      let terminal = try SerialTransport(
        channel: OwnedSerialChannel(vmID: UUID(), portID: 0, path: String(cString: name)))
      let fd = master
      let peer = Task.detached { () throws -> [String] in
        func line() throws -> String {
          let deadline = ContinuousClock.now.advanced(by: .seconds(2))
          var result = Data()
          var bytes = [UInt8](repeating: 0, count: 128)
          while ContinuousClock.now < deadline {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
              result.append(contentsOf: bytes.prefix(count))
              if result.contains(10) { return String(decoding: result, as: UTF8.self) }
            }
            usleep(1000)
          }
          throw GuideError.stopped("Test peer timed out")
        }
        func send(_ string: String) {
          let data = Data(string.utf8)
          _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        }
        if existingShell {
          send("\r\nuser@debian:~$ ")
          return []
        }
        send("debian login: ")
        let user = try line()
        send(duplicatePrompt ? "\r\ndebian login: Password: " : "Password: ")
        let password = try line()
        send(accepted ? "\r\nuser@debian:~$ " : "\r\nLogin incorrect\r\n")
        return [user, password]
      }
      do {
        try await SerialLogin.authenticate(terminal, password: "fixture-only", username: account)
        XCTAssertTrue(accepted)
      } catch { XCTAssertFalse(accepted) }
      let received = try await peer.value
      XCTAssertEqual(received, existingShell ? [] : [account + "\n", "fixture-only\n"])
      await terminal.close()
    }
  }
  func testStaleOrMissingPromptStopsWithoutWriting() async throws {
    for prompt in ["Password: ", "Login incorrect", "debian login: Password: ", "user@debian:~$ Password: ", ""] {
      var master: Int32 = -1
      var slave: Int32 = -1
      var name = [CChar](repeating: 0, count: 1024)
      guard openpty(&master, &slave, &name, nil, nil) == 0 else {
        return XCTFail("PTY unavailable")
      }
      defer { Darwin.close(master); Darwin.close(slave) }
      _ = fcntl(master, F_SETFL, O_NONBLOCK)
      let terminal = try SerialTransport(channel: .init(
        vmID: UUID(), portID: 0, path: String(cString: name)))
      let data = Data(prompt.utf8)
      if !data.isEmpty {
        _ = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, data.count) }
      }
      do {
        try await SerialLogin.authenticate(terminal, password: "fixture-only", promptTimeout: 0.05)
        XCTFail("Ambiguous initial state must stop")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("Gracefully restart"))
      }
      var bytes = [UInt8](repeating: 0, count: 128)
      let count = Darwin.read(master, &bytes, bytes.count)
      XCTAssertEqual(count, -1)
      XCTAssertEqual(errno, EAGAIN)
      await terminal.close()
    }
  }

}
