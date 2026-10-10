import Darwin
import Foundation

public enum AppLaunchOptions {
  /// Explicit local session selection only. This does not change compatibility,
  /// approval requirements, or the compile-time native pilot gate.
  public static func stateRoot(arguments: [String], defaultRoot: URL = WorkflowEngine.defaultRoot) throws -> URL {
    guard !arguments.isEmpty else { return defaultRoot }
    guard arguments.count == 2, arguments[0] == "--state-root",
      arguments[1].hasPrefix("/"), !arguments[1].contains("\0"),
      !arguments[1].contains("\n"), !arguments[1].contains("\r") else {
      throw GuideError.stopped("Usage: EchoGuide [--state-root ABSOLUTE_DIRECTORY]")
    }
    let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
    var existingAncestor = root
    while !FileManager.default.fileExists(atPath: existingAncestor.path), existingAncestor.path != "/" {
      if (try? FileManager.default.attributesOfItem(atPath: existingAncestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
        throw GuideError.stopped("State root cannot contain a symbolic link")
      }
      existingAncestor.deleteLastPathComponent()
    }
    guard root.path != "/", let canonical = realpath(existingAncestor.path, nil) else {
      throw GuideError.stopped("State root must have an accessible local parent")
    }
    defer { free(canonical) }
    guard existingAncestor.path == String(cString: canonical) else {
      throw GuideError.stopped("State root must be a local directory without symbolic links")
    }
    let fm = FileManager.default
    if fm.fileExists(atPath: root.path) {
      let attributes = try fm.attributesOfItem(atPath: root.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory,
        (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
        ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
        throw GuideError.stopped("Existing state root must be a private directory owned by this Mac user")
      }
      let contents = try fm.contentsOfDirectory(atPath: root.path)
      if !contents.isEmpty {
        let session = root.appendingPathComponent("session.json")
        guard try session.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
          try session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
          throw GuideError.stopped("Existing directory is not an EchoGuide session; choose a fresh directory")
        }
        let record = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: session))
        guard record.profileID == (try CompatibilityProfile.bundled().id) else {
          throw GuideError.stopped("Existing session belongs to an unsupported compatibility profile")
        }
      }
    }
    return root
  }
}
