import Foundation
import XCTest
@testable import EchoGuideCore

final class GuestNetworkWaitTests: XCTestCase {
  private var key: String { "ssh-ed25519 " + Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating:UInt8(7),count:32)).base64EncodedString() }
  private struct Outcome {
    let request: GuestBootstrapRequest
    let status: Int32
    let frame: String
    let events: [String]
  }
  private func run(emptyBefore: Int, result: String, authorize: Bool = false) throws -> Outcome {
    let folder=FileManager.default.temporaryDirectory.appendingPathComponent("EchoGuideWait-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    defer {try? FileManager.default.removeItem(at:folder)}
    let count=folder.appendingPathComponent("count"),events=folder.appendingPathComponent("events")
    try Data("0\n".utf8).write(to:count)
    try Data().write(to:events)
    let request=try GuestBootstrapRequest(ownedVMID:UUID(),clientPublicKey:authorize ? key : nil,username:"echotest")
    let fixture="""
    HOME=/home/echotest
    export HOME
    id() { printf '%s\\n' echotest; }
    uname() { printf '%s\\n' aarch64; }
    cat() { printf '%s\\n' '\(key) fixture'; }
    ip() {
      read -r counter < '\(count.path)'
      counter=$((counter + 1))
      printf '%s\\n' "$counter" > '\(count.path)'
      printf '%s\\n' probe >> '\(events.path)'
      if [ "$counter" -le \(emptyBefore) ]; then return 0; fi
      if [ '\(result)' = error ]; then return 7; fi
      printf '%s\\n' '2: eth0 inet 192.168.64.7/24 scope global eth0'
      if [ '\(result)' = multiple ]; then printf '%s\\n' '3: eth1 inet 10.0.0.2/24 scope global eth1'; fi
      return 0
    }
    sleep() { [ "$1" = 1 ] || return 99; printf '%s\\n' wait >> '\(events.path)'; }
    test() { if [ "$1" = '!' ] && [ "$2" = '-L' ]; then return 0; fi; command test "$@"; }
    mkdir() { printf '%s\\n' authorize >> '\(events.path)'; }
    touch() { :; }
    chmod() { :; }
    grep() { return 0; }
    """
    // The only writes are to this test's temporary counters. Guest filesystem/key
    // operations are stubbed; no account, authorized_keys or credentials are touched.
    let p=Process(),out=Pipe()
    p.executableURL=URL(fileURLWithPath:"/bin/sh")
    p.arguments=["-c",fixture+"\n"+GuestBootstrapProtocol.consoleCommand(for:request)]
    p.environment=["PATH":"/usr/bin:/bin","LC_ALL":"C"]
    p.standardOutput=out;p.standardError=FileHandle.nullDevice
    try p.run();let data=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
    return Outcome(request:request,status:p.terminationStatus,frame:String(decoding:data,as:UTF8.self),events:try String(contentsOf:events,encoding:.utf8).split(separator:"\n").map(String.init))
  }
  func testZeroThenOneAddressProceedsOnceAfterReadOnlyWait() throws {
    let value=try run(emptyBefore:2,result:"one")
    XCTAssertEqual(value.status,0)
    XCTAssertEqual(value.events,["probe","wait","probe","wait","probe"])
    XCTAssertFalse(try GuestBootstrapProtocol.parse(value.frame,for:value.request).clientAuthorized)
  }
  func testFinalPermittedRecheckCanEstablishOneAddress() throws {
    let value=try run(emptyBefore:10,result:"one")
    XCTAssertEqual(value.status,0)
    XCTAssertEqual(value.events.filter{$0=="probe"}.count,11)
    XCTAssertEqual(value.events.filter{$0=="wait"}.count,10)
    XCTAssertNoThrow(try GuestBootstrapProtocol.parse(value.frame,for:value.request))
  }
  func testZeroAddressBoundStopsWithoutKeyAuthorization() throws {
    let value=try run(emptyBefore:11,result:"one")
    XCTAssertEqual(value.status,1)
    XCTAssertEqual(value.events.filter{$0=="probe"}.count,11)
    XCTAssertEqual(value.events.filter{$0=="wait"}.count,10)
    XCTAssertFalse(value.events.contains("authorize"))
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(value.frame,for:value.request)) {
      XCTAssertEqual($0 as? GuestBootstrapFailure,GuestBootstrapFailure(stage:.address,exitCode:1))
    }
  }
  func testMultipleAddressesStopWithoutWaitingOrAuthorization() throws {
    let value=try run(emptyBefore:0,result:"multiple",authorize:true)
    XCTAssertEqual(value.status,1)
    XCTAssertEqual(value.events,["probe"])
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(value.frame,for:value.request)) {
      XCTAssertEqual($0 as? GuestBootstrapFailure,GuestBootstrapFailure(stage:.address,exitCode:1))
    }
  }
  func testAuthorizationRecheckNeverWaitsForAnAddress() throws {
    let value=try run(emptyBefore:1,result:"one",authorize:true)
    XCTAssertEqual(value.status,1)
    XCTAssertEqual(value.events,["probe"])
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(value.frame,for:value.request)) {
      XCTAssertEqual($0 as? GuestBootstrapFailure,GuestBootstrapFailure(stage:.address,exitCode:1))
    }
  }
  func testReadyAuthorizationExecutesOnceWithoutWaiting() throws {
    let value=try run(emptyBefore:0,result:"one",authorize:true)
    XCTAssertEqual(value.status,0)
    XCTAssertEqual(value.events,["probe","authorize"])
    XCTAssertTrue(try GuestBootstrapProtocol.parse(value.frame,for:value.request).clientAuthorized)
  }
  func testNetworkCommandFailureStopsWithoutWaitingOrAuthorization() throws {
    let value=try run(emptyBefore:0,result:"error",authorize:true)
    XCTAssertEqual(value.status,7)
    XCTAssertEqual(value.events,["probe"])
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(value.frame,for:value.request)) {
      XCTAssertEqual($0 as? GuestBootstrapFailure,GuestBootstrapFailure(stage:.network,exitCode:7))
    }
  }
}
