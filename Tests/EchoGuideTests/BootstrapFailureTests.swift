import Foundation
import XCTest
@testable import EchoGuideCore

final class BootstrapFailureTests: XCTestCase {
  private var key: String { "ssh-ed25519 " + Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating: UInt8(7),count:32)).base64EncodedString() }
  private func execute(_ request: GuestBootstrapRequest, override: String = "") throws -> (Int32,String) {
    let fixture = """
    HOME=/home/echotest
    export HOME
    id() { printf '%s\\n' echotest; }
    uname() { printf '%s\\n' aarch64; }
    cat() { test "$1" = /etc/ssh/ssh_host_ed25519_key.pub || return 99; printf '%s\\n' '\(key) fixture'; }
    ip() { printf '%s\\n' '2: eth0 inet 192.168.64.7/24 scope global eth0'; }
    """
    let p=Process(),out=Pipe()
    p.executableURL=URL(fileURLWithPath:"/bin/sh")
    p.arguments=["-c",fixture+"\n"+override+"\nprintf '\\033[?2004l\\r'\n"+GuestBootstrapProtocol.consoleCommand(for:request)]
    p.environment=["PATH":"/usr/bin:/bin","LC_ALL":"C"]
    p.standardOutput=out;p.standardError=FileHandle.nullDevice
    try p.run();let data=out.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
    return (p.terminationStatus,String(decoding:data,as:UTF8.self))
  }
  func testHealthyCommandStillReturnsExactEvidence() throws {
    let request=try GuestBootstrapRequest(ownedVMID:UUID(),username:"echotest")
    let (code,output)=try execute(request)
    XCTAssertEqual(code,0)
    let evidence=try GuestBootstrapProtocol.parse(output,for:request)
    XCTAssertEqual(evidence.address,"192.168.64.7")
    XCTAssertEqual(evidence.trust.publicHostKey,key)
    XCTAssertFalse(evidence.clientAuthorized)
  }
  func testActualCommandReportsEachFailedPrerequisiteWithoutGuestOutput() throws {
    let request=try GuestBootstrapRequest(ownedVMID:UUID(),username:"echotest")
    let cases:[(String,GuestBootstrapFailure.Stage,Int)] = [
      ("id() { printf '%s\\n' private-wrong-user; }",.identity,1),
      ("HOME=/private-wrong-home",.home,1),
      ("uname() { printf '%s\\n' x86_64; }",.architecture,1),
      ("cat() { return 13; }",.hostKey,13),
      ("ip() { return 127; }",.network,127),
      ("ip() { return 0; }",.address,1),
      ("ip() { printf '%s\\n' '2: eth0 inet 192.168.64.7/24 scope global eth0' '3: eth1 inet 10.0.0.2/24 scope global eth1'; }",.address,1)
    ]
    for (command,stage,code) in cases {
      let (status,output)=try execute(request,override:command)
      XCTAssertEqual(status,Int32(code))
      XCTAssertTrue(output.contains(request.endMarker))
      XCTAssertFalse(output.contains("private-wrong"))
      XCTAssertThrowsError(try GuestBootstrapProtocol.parse(output,for:request)) { error in
        XCTAssertEqual(error as? GuestBootstrapFailure,GuestBootstrapFailure(stage:stage,exitCode:code))
        XCTAssertFalse(error.localizedDescription.contains(request.ownedVMID.uuidString))
        XCTAssertFalse(error.localizedDescription.contains(request.nonce.uuidString))
      }
    }
  }
  func testFailureFrameCannotBypassBindingOrExactGrammar() throws {
    let request=try GuestBootstrapRequest(ownedVMID:UUID(),username:"echotest")
    let (_,frame)=try execute(request,override:"ip() { return 0; }")
    let invalid=[frame+frame,frame.replacingOccurrences(of:request.nonce.uuidString,with:UUID().uuidString),frame.replacingOccurrences(of:request.ownedVMID.uuidString,with:UUID().uuidString),frame.replacingOccurrences(of:"ERROR address 1",with:"ERROR arbitrary-private-text 1"),frame.replacingOccurrences(of:"ERROR address 1",with:"ERROR address 0"),frame.replacingOccurrences(of:"ERROR address 1",with:"ERROR address 256"),frame.replacingOccurrences(of:"ERROR address 1",with:"ERROR address 01"),frame.replacingOccurrences(of:"ERROR address 1",with:"ERROR add\rress 1"),frame.replacingOccurrences(of:"ERROR address 1",with:"ERROR  address 1")]
    for malformed in invalid {
      XCTAssertThrowsError(try GuestBootstrapProtocol.parse(malformed,for:request)) { error in
        XCTAssertNil(error as? GuestBootstrapFailure)
      }
    }
  }
  func testCommandsRemainOneBoundedInputLine() throws {
    for client in [nil,key] {
      let request=try GuestBootstrapRequest(ownedVMID:UUID(),clientPublicKey:client,username:"echotest")
      let text=GuestBootstrapProtocol.consoleCommand(for:request)
      XCTAssertEqual(text.filter{$0=="\n"}.count,1)
      XCTAssertLessThan(text.utf8.count,4096)
    }
  }
  func testFailedClientKeySetupNeverReportsAuthorization() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID(), clientPublicKey: key, username: "echotest")
    let (code, output) = try execute(request, override: "mkdir() { return 13; }")
    XCTAssertEqual(code, 13)
    XCTAssertFalse(output.contains("CLIENT_AUTH installed"))
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(output, for: request)) { error in
      XCTAssertEqual(error as? GuestBootstrapFailure, .init(stage: .clientAuthorization, exitCode: 13))
    }
  }
}
