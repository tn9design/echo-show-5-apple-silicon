import XCTest
@testable import EchoGuideCore

final class GuestUsernameTests: XCTestCase {
  func testAccountValidationRejectsShellAndPathText() throws {
    for value in ["echotest", "user", "echo-test", "_test", "echo_2"] { XCTAssertEqual(try GuestUsername.validated(value), value) }
    for value in ["", "root", "Echo Test", "echo/test", "../user", "user;id", "$(id)", "user\n", "-user", String(repeating: "a", count: 33)] { XCTAssertThrowsError(try GuestUsername.validated(value)) }
  }
  func testChallengeIsBoundToSelectedAccount() throws {
    let request = try GuestBootstrapRequest(ownedVMID: UUID(), username: "echotest")
    let command = GuestBootstrapProtocol.consoleCommand(for: request)
    XCTAssertTrue(command.contains("$(id -un)\" = echotest"))
    XCTAssertTrue(command.contains("USER echotest"))
    XCTAssertTrue(command.contains("test \"$HOME\" = /home/echotest"))
    let key = "ssh-ed25519 " + Data([0,0,0,11] + Array("ssh-ed25519".utf8) + [0,0,0,32] + Array(repeating: UInt8(7), count:32)).base64EncodedString()
    let frame = "ECHOGUIDE-BEGIN \(request.ownedVMID.uuidString) \(request.nonce.uuidString)\nVERSION 1\nUSER echotest\nARCH aarch64\nIPV4 192.168.64.7\nHOST_KEY \(key)\nCLIENT_AUTH read-only\n\(request.endMarker)\n"
    XCTAssertNoThrow(try GuestBootstrapProtocol.parse(frame, for: request))
    XCTAssertThrowsError(try GuestBootstrapProtocol.parse(frame.replacingOccurrences(of:"USER echotest",with:"USER user"), for:request))
    let install = try GuestBootstrapRequest(ownedVMID: request.ownedVMID, clientPublicKey:key, username:"echotest")
    XCTAssertTrue(GuestBootstrapProtocol.consoleCommand(for:install).contains("/home/echotest/.ssh/authorized_keys"))
    XCTAssertFalse(GuestBootstrapProtocol.consoleCommand(for:install).contains("/home/user"))
  }
  func testSessionBindingCannotChangeAfterKeyCreation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let engine = try WorkflowEngine(root:root)
    let id = UUID().uuidString
    try engine.store.transaction { $0.vmID = id }
    try engine.configureGuestUsername("echotest")
    XCTAssertEqual(try WorkflowEngine(root:root).status().guestUsername,"echotest")
    try FileManager.default.createDirectory(at:root.appendingPathComponent("guest-" + id),withIntermediateDirectories:true)
    XCTAssertNoThrow(try engine.configureGuestUsername("echotest"))
    XCTAssertThrowsError(try engine.configureGuestUsername("user"))
    XCTAssertEqual(try engine.status().guestUsername,"echotest")
    let report = String(decoding:try JSONEncoder().encode(engine.diagnosticReport()),as:UTF8.self)
    XCTAssertFalse(report.contains("echotest"))
  }
  func testAdapterSSHAndPathsUseConfiguredAccount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let engine = try WorkflowEngine(root:root)
    let directory = root.appendingPathComponent("credentials")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    try Data().write(to:directory.appendingPathComponent("client-ed25519"))
    try Data().write(to:directory.appendingPathComponent("known_hosts"))
    let guest = try GuestAdapter(runner:engine.runner,ownedVMID:UUID(),credentialsDirectory:directory,address:"192.168.64.7",username:"echotest")
    XCTAssertEqual(guest.workspacePath,"/home/echotest/echoguide")
    XCTAssertEqual(try guest.arguments(command:"fixture").suffix(2),["echotest@192.168.64.7","fixture"])
  }
  func testLegacySessionUsesDefaultAccount() throws {
    let session = SessionRecord(profileID:"fixture")
    let data = try JSONEncoder().encode(session)
    XCTAssertNil(try JSONDecoder().decode(SessionRecord.self,from:data).guestUsername)
    XCTAssertEqual(try GuestBootstrapRequest(ownedVMID:UUID()).username,"user")
  }
}
