import Darwin
import XCTest

@testable import EchoGuideCore

final class SerialTests: XCTestCase {
  func testPeerDisconnectStopsRead() async throws {
    let (master, slave, channel) = try pair()
    defer { Darwin.close(slave) }
    let transport = try SerialTransport(channel: channel)
    Darwin.close(master)
    do {
      _ = try await transport.read(until: Data("END".utf8), timeout: 1)
      XCTFail("Expected disconnected peer")
    } catch {
      XCTAssertFalse(error.localizedDescription.contains("timed out"))
    }
    await transport.close()
  }
  private func pair() throws -> (Int32, Int32, OwnedSerialChannel) {
    var master: Int32 = -1
    var slave: Int32 = -1
    var name = [CChar](repeating: 0, count: 1024)
    guard openpty(&master, &slave, &name, nil, nil) == 0 else {
      throw GuideError.stopped("Test PTY allocation failed")
    }
    let path = String(cString: name)
    return (master, slave, OwnedSerialChannel(vmID: UUID(), portID: 0, path: path))
  }
  func testRejectsNonTerminalPath() throws {
    XCTAssertThrowsError(
      try SerialTransport(channel: .init(vmID: UUID(), portID: 0, path: "/tmp/file")))
  }
  func testBoundedReadAndWriteOnIsolatedPTY() async throws {
    let (master, slave, channel) = try pair()
    defer {
      Darwin.close(master)
      Darwin.close(slave)
    }
    let transport = try SerialTransport(channel: channel)
    try await transport.write(Data("hello\n".utf8))
    var bytes = [UInt8](repeating: 0, count: 32)
    let size = Darwin.read(master, &bytes, bytes.count)
    XCTAssertEqual(Data(bytes.prefix(size)), Data("hello\n".utf8))
    let reply = Data("BEGIN\nEND\n".utf8)
    _ = reply.withUnsafeBytes { Darwin.write(master, $0.baseAddress, reply.count) }
    let output = try await transport.read(until: Data("END\n".utf8))
    XCTAssertEqual(output, reply)
    await transport.close()
  }
  func testReadPreservesTrailingBytesAndChoosesEarliestMarker() async throws {
    let (master, slave, channel) = try pair()
    defer {
      Darwin.close(master)
      Darwin.close(slave)
    }
    let transport = try SerialTransport(channel: channel)
    let reply = Data("login: Password: tail".utf8)
    _ = reply.withUnsafeBytes { Darwin.write(master, $0.baseAddress, reply.count) }
    let first = try await transport.read(untilAny: [Data("Password: ".utf8), Data("login: ".utf8)])
    XCTAssertEqual(first, Data("login: ".utf8))
    let second = try await transport.read(until: Data("Password: ".utf8))
    XCTAssertEqual(second, Data("Password: ".utf8))
    let third = try await transport.read(until: Data("tail".utf8))
    XCTAssertEqual(third, Data("tail".utf8))
    await transport.close()
  }
  func testTimeoutDoesNotReturnPartialEvidence() async throws {
    let (master, slave, channel) = try pair()
    defer {
      Darwin.close(master)
      Darwin.close(slave)
    }
    let transport = try SerialTransport(channel: channel)
    do {
      _ = try await transport.read(until: Data("END".utf8), timeout: 0.05)
      XCTFail("Expected timeout")
    } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    await transport.close()
  }
  func testOverflowAndClosedChannelStop() async throws {
    let (master, slave, channel) = try pair()
    defer {
      Darwin.close(master)
      Darwin.close(slave)
    }
    let transport = try SerialTransport(channel: channel)
    let reply = Data(repeating: 65, count: 64)
    _ = reply.withUnsafeBytes { Darwin.write(master, $0.baseAddress, reply.count) }
    do {
      _ = try await transport.read(until: Data("END".utf8), limit: 32)
      XCTFail("Expected overflow")
    } catch { XCTAssertTrue(error.localizedDescription.contains("limit")) }
    await transport.close()
    do {
      try await transport.write(Data("x".utf8))
      XCTFail("Expected closed")
    } catch {}
  }
}
