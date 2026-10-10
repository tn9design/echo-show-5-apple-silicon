import Foundation

/// Uses the Apple backend creation fields present in UTM 5.0.6's shipped UTM.sdef.
/// Runtime creation remains a pilot integration: it does not start or provision the VM.
public struct UTMAdapter: Sendable {
  public let runner: any CommandRunning
  public let application: URL
  public init(runner: any CommandRunning, application: URL) {
    self.runner = runner
    self.application = application
  }
  public static func creationScript(application: URL) throws -> String {
    guard application.pathExtension == "app", !application.path.contains("\n") else {
      throw AdapterError.commandFailed("Invalid UTM application")
    }
    let literal = application.path.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return """
      on run argv
          set isoImage to POSIX file (item 1 of argv)
          set ownershipToken to item 2 of argv
          tell application "\(literal)"
              if UTM version is not "5.0.6" then error "Unsupported UTM version"
              set newVM to make new virtual machine with properties {backend:apple, configuration:{name:"EchoGuide " & ownershipToken, notes:"EchoGuide ownership: " & ownershipToken, memory:4096, cpu cores:4, os:linux, directory shares:{}, drives:{{guest size:12288}, {removable:true, source:isoImage}}, network interfaces:{{mode:shared}}, serial ports:{{interface:ptty}}, displays:{{dynamic resolution:true}}}}
              return id of newVM
          end tell
      end run
      """
  }
  /// Caller must persist the ownership intent before calling, and returned UUID afterward.
  public func create(specification: OwnedVMSpecification, verifiedISO: URL) async throws -> UUID {
    guard verifiedISO.isFileURL, FileManager.default.fileExists(atPath: verifiedISO.path) else {
      throw AdapterError.commandFailed("Missing verified ISO")
    }
    let script = try Self.creationScript(application: application)
    let result = try await runner.run(
      executable: "/usr/bin/osascript",
      arguments: ["-e", script, verifiedISO.path, specification.ownershipID.uuidString])
    if result.exitCode != 0 && result.stderr.contains("(-1743)") {
      throw GuideError.stopped("Automation permission denied before VM creation")
    }
    guard result.exitCode == 0,
      let vm = UUID(uuidString: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw AdapterError.commandFailed("UTM create; inspect ownership marker before retrying")
    }
    return vm
  }
}
