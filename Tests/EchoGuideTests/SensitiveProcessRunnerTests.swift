import XCTest
@testable import EchoGuideCore

final class SensitiveProcessRunnerTests: XCTestCase {
  func testInputIsDeliveredAndOutputDiscarded() async throws {
    let status = try await SensitiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "read value; test \"$value\" = fixture-only; result=$?; printf '%s' \"$value\"; printf '%s' \"$value\" >&2; exit $result"], input: Data("fixture-only\n".utf8), timeoutSeconds: 2)
    XCTAssertEqual(status, 0)
  }
  func testLargeOutputCannotBlock() async throws {
    let status = try await SensitiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "read value; /usr/bin/yes output | /usr/bin/head -c 1048576; /usr/bin/yes error | /usr/bin/head -c 1048576 >&2; exit 7"], input: Data("fixture\n".utf8), timeoutSeconds: 3)
    XCTAssertEqual(status, 7)
  }
  func testTimeoutContainsNoInput() async throws {
    do {
      _ = try await SensitiveProcessRunner().run(executable: "/bin/sleep", arguments: ["10"], input: Data("fixture-secret\n".utf8), timeoutSeconds: 1)
      XCTFail("Expected timeout")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Sensitive command timed out; inspect outcome before retry")
      XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
    }
  }
  func testClosedChildInputDoesNotRaiseSIGPIPE() async throws {
    do {
      let status = try await SensitiveProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "exec 0<&-; sleep 0.1; exit 9"], input: Data(repeating: 65, count: 4096), timeoutSeconds: 2)
      XCTAssertEqual(status, 9)
    } catch {
      XCTAssertEqual(error.localizedDescription, "Sensitive input delivery failed; no automatic retry")
    }
  }
  func testCancellation() async throws {
    let task = Task { try await SensitiveProcessRunner().run(executable: "/bin/sleep", arguments: ["10"], input: Data("fixture\n".utf8), timeoutSeconds: 20) }
    try await Task.sleep(for: .milliseconds(100)); task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
  }
  func testRejectsInvalidRequests() async throws {
    for (executable, input, timeout) in [("relative", Data([1]), 1), ("/bin/true", Data(), 1), ("/bin/true", Data(repeating: 1, count: 4097), 1), ("/bin/true", Data([1]), 0)] {
      do { _ = try await SensitiveProcessRunner().run(executable: executable, arguments: [], input: input, timeoutSeconds: timeout); XCTFail("Expected rejection") } catch { XCTAssertEqual(error.localizedDescription, "Invalid sensitive command request") }
    }
  }
}
