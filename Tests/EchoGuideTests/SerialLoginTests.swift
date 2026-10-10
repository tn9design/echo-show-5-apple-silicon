import Darwin
import XCTest

@testable import EchoGuideCore

final class SerialLoginTests: XCTestCase {
  func testRejectsTerminalControlCharacters() throws {
    for password in ["", "x\nuser", "x\r", "x\u{1b}", String(repeating: "a", count: 1025)] {
      XCTAssertThrowsError(try SerialLogin.validatePassword(password))
    }
    XCTAssertNoThrow(try SerialLogin.validatePassword("a test password"))
  }
  func testLoginAndRejectionOnIsolatedTerminal() async throws {
    for accepted in [true, false] {
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
        let wake = try line()
        send("debian login: ")
        let user = try line()
        send("Password: ")
        let password = try line()
        send(accepted ? "\r\nuser@debian:~$ " : "\r\nLogin incorrect\r\n")
        return [wake, user, password]
      }
      do {
        try await SerialLogin.authenticate(terminal, password: "fixture-only")
        XCTAssertTrue(accepted)
      } catch { XCTAssertFalse(accepted) }
      let received = try await peer.value
      XCTAssertEqual(received, ["\n", "user\n", "fixture-only\n"])
      await terminal.close()
    }
  }
}
