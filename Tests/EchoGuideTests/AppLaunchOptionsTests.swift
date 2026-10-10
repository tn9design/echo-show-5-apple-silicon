import XCTest
@testable import EchoGuideCore

final class AppLaunchOptionsTests: XCTestCase {
  func testDefaultAndExplicitFreshRootDoNotCreateSession() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    XCTAssertEqual(try AppLaunchOptions.stateRoot(arguments: [], defaultRoot: root), root)
    XCTAssertEqual(try AppLaunchOptions.stateRoot(arguments: ["--state-root", root.path]).path, root.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
  func testMalformedArgumentsFailWithoutFallbackToDefault() throws {
    for args in [["--state-root"], ["--state-root", "relative"], ["--state-root", "/"],
                 ["--unknown", "/private/tmp/session"], ["--state-root", "/private/tmp/a", "extra"],
                 ["--state-root", "/private/tmp/a\nb"]] {
      XCTAssertThrowsError(try AppLaunchOptions.stateRoot(arguments: args))
    }
  }
  func testExistingPrivateOwnedSessionCanBeLoaded() throws {
    let engine = try WorkflowEngine(root: URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction { $0.phase = .workspace }
    XCTAssertEqual(try AppLaunchOptions.stateRoot(arguments: ["--state-root", engine.store.root.path]).path, engine.store.root.path)
  }
  func testUnrelatedDirectorySymlinkAndPublicDirectoryRefused() throws {
    let fm = FileManager.default; let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: base) }
    let unrelated = base.appendingPathComponent("unrelated")
    try fm.createDirectory(at: unrelated, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("keep".utf8).write(to: unrelated.appendingPathComponent("other.txt"))
    XCTAssertThrowsError(try AppLaunchOptions.stateRoot(arguments: ["--state-root", unrelated.path]))
    let link = base.appendingPathComponent("link")
    try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)
    XCTAssertThrowsError(try AppLaunchOptions.stateRoot(arguments: ["--state-root", link.path]))
    let publicFolder = base.appendingPathComponent("public")
    try fm.createDirectory(at: publicFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    XCTAssertThrowsError(try AppLaunchOptions.stateRoot(arguments: ["--state-root", publicFolder.path]))
    XCTAssertEqual(try String(contentsOf: unrelated.appendingPathComponent("other.txt"), encoding: .utf8), "keep")
  }
}
