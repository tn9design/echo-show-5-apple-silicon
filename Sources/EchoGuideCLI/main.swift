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
      guard
        (args.count == 1
          && !["prepare-workspace", "reconcile-workspace", "start-workspace", "stop-workspace"]
            .contains(args[0]))
          || (args.count == 3 && args.first == "prepare-workspace")
          || (args.count == 2
            && ["reconcile-workspace", "start-workspace", "stop-workspace"].contains(args[0]))
      else {
        throw CLIError.usage
      }
      let engine = try WorkflowEngine(root: root)
      switch args[0] {
      case "start-workspace":
        try emit(try await engine.startOwnedWorkspace(utm: URL(fileURLWithPath: args[1])))
      case "stop-workspace":
        try emit(try await engine.stopOwnedWorkspace(utm: URL(fileURLWithPath: args[1])))
      case "reconcile-workspace":
        switch try await engine.reconcileWorkspace(utm: URL(fileURLWithPath: args[1])) {
        case .absent: try emit(["result": "absent; creation intent retained"])
        case .owned(let info): try emit(info)
        }
      case "prepare-workspace":
        let id = try await engine.prepareWorkspace(
          utm: URL(fileURLWithPath: args[1]), iso: URL(fileURLWithPath: args[2]))
        try emit(["managedVMID": id.uuidString])
      case "inspect": try emit(try await engine.inspect())
            case "prepare-downloads": try emit(try await engine.prepareOwnedDownloads())
      case "status": try emit(try engine.status())
      case "powered-wait-status": try emit(try engine.poweredWaitStatus())
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
      if let usage = error as? CLIError {
        FileHandle.standardError.write(Data("EchoGuide: \(usage.description)\n".utf8))
      } else {
        let diagnostic = BackendDiagnostic(error: error)
        let data = (try? JSONEncoder().encode(diagnostic)) ?? Data("{\"code\":\"operation_failed\",\"message\":\"The operation failed; inspect local state.\"}".utf8)
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
      }
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
      "Usage: echo-guide [--state-root DIRECTORY] inspect|prepare-downloads|status|powered-wait-status|verify-recovery|backup|request-unlock|request-install|report; or prepare-workspace UTM_APPLICATION DEBIAN_ISO; or reconcile-workspace|start-workspace|stop-workspace UTM_APPLICATION. Workspace creation uses only the pinned profile and creates an isolated owned VM. Echo write requests require native app approval; they do not execute a write."
    }
  }
}
