import EchoGuideCore
import Foundation

@main struct EchoGuideCLI {
  static func main() async {
    do {
      var args = Array(CommandLine.arguments.dropFirst())
      var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/EchoGuide")
      if args.first == "--state-root" {
        guard args.count >= 3 else { throw CLIError.usage }
        root = URL(fileURLWithPath: args[1], isDirectory: true)
        args.removeFirst(2)
      }
      guard args.count == 1 else { throw CLIError.usage }
      let engine = try WorkflowEngine(root: root)
      switch args[0] {
      case "inspect": try emit(try await engine.inspect())
      case "status": try emit(try engine.status())
      case "verify-recovery":
        try await engine.verifyConfiguredRecovery()
        try emit(try engine.status())
      case "backup": try emit(try await engine.backupConfigured())
      case "request-unlock": try emit(try engine.requestApproval(action: .unlock))
      case "request-install": try emit(try engine.requestApproval(action: .install))
      case "report": try emit(try engine.diagnosticReport())
      default: throw CLIError.usage
      }
    } catch {
      FileHandle.standardError.write(Data("EchoGuide: \(error)\n".utf8))
      exit(1)
    }
  }
  static func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
  enum CLIError: Error, CustomStringConvertible {
    case usage
    var description: String {
      "Usage: EchoGuideCLI [--state-root DIRECTORY] inspect|status|verify-recovery|backup|request-unlock|request-install|report. Write requests require native app approval; they do not execute a write."
    }
  }
}
