import EchoGuideCore
import Foundation

/// Local newline-framed stdio transport. Stdout contains JSON-RPC only.
@main struct EchoGuideMCP {
  static func main() async {
    do {
      let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/EchoGuide")
      var engine: WorkflowEngine?
      var initialized = false
      let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]
      while let line = readLine() {
        guard line.utf8.count <= 1_048_576 else {
          respond(id: NSNull(), error: (-32600, "Request exceeds one MiB"))
          continue
        }
        guard let bytes = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else {
          respond(id: NSNull(), error: (-32700, "Invalid JSON"))
          continue
        }
        let id = request["id"]
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String
        else {
          respond(id: id ?? NSNull(), error: (-32600, "Invalid JSON-RPC request"))
          continue
        }
        // Notifications must not receive replies or trigger operations.
        guard let id else { continue }
        guard id is String || id is NSNumber || id is NSNull else {
          respond(id: NSNull(), error: (-32600, "Invalid request ID"))
          continue
        }
        do {
          switch method {
          case "initialize":
            let requested = (request["params"] as? [String: Any])?["protocolVersion"] as? String
            let version =
              requested.flatMap { supportedProtocols.contains($0) ? $0 : nil }
              ?? supportedProtocols[0]
            initialized = true
            respond(
              id: id,
              result: [
                "protocolVersion": version, "capabilities": ["tools": [:]],
                "serverInfo": ["name": "echoguide", "version": "0.1.0"],
              ])
          case "ping": respond(id: id, result: [:])
          case "tools/list":
            guard initialized else {
              respond(id: id, error: (-32000, "Initialize first"))
              continue
            }
            respond(id: id, result: ["tools": toolDefinitions])
          case "tools/call":
            guard initialized else {
              respond(id: id, error: (-32000, "Initialize first"))
              continue
            }
            guard let params = request["params"] as? [String: Any],
              let name = params["name"] as? String,
              params["arguments"] == nil || params["arguments"] is [String: Any]
            else {
              respond(id: id, error: (-32602, "Tool takes no arguments"))
              continue
            }
            if let arguments = params["arguments"] as? [String: Any], !arguments.isEmpty {
              respond(id: id, error: (-32602, "Tool takes no arguments"))
              continue
            }
            guard
              [
                "inspect", "prepare_downloads", "status", "powered_wait_status", "verify_recovery", "backup", "request_unlock",
                "request_install", "report",
              ].contains(name)
            else {
              respond(id: id, error: (-32602, "Unknown tool"))
              continue
            }
            let activeEngine: WorkflowEngine
            if let existing = engine {
              activeEngine = existing
            } else {
              let created = try WorkflowEngine(root: root)
              engine = created
              activeEngine = created
            }
            let data: Data
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            switch name {
            case "inspect": data = try encoder.encode(try await activeEngine.inspect())
            case "prepare_downloads": data = try encoder.encode(try activeEngine.startPublisherDownloads())
            case "status": data = try encoder.encode(try activeEngine.status())
            case "powered_wait_status": data = try encoder.encode(try activeEngine.poweredWaitStatus())
            case "verify_recovery":
              try await activeEngine.verifyConfiguredRecovery()
              data = try encoder.encode(try activeEngine.status())
            case "backup": data = try encoder.encode(try activeEngine.startConfiguredBackup())
            case "request_unlock":
              data = try encoder.encode(try activeEngine.requestApproval(action: .unlock))
            case "request_install":
              data = try encoder.encode(try activeEngine.requestApproval(action: .install))
            case "report": data = try encoder.encode(try activeEngine.diagnosticReport())
            default:
              respond(id: id, error: (-32602, "Unknown tool"))
              continue
            }
            respond(
              id: id,
              result: [
                "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
              ])
          default: respond(id: id, error: (-32601, "Method not found"))
          }
        } catch {
          // Typed, sanitized backend diagnostics are failures, never success evidence.
          let diagnostic = BackendDiagnostic(error: error)
          let text = String(decoding: (try? JSONEncoder().encode(diagnostic)) ?? Data(), as: UTF8.self)
          respond(
            id: id,
            result: [
              "isError": true,
              "structuredContent": ["code": diagnostic.code.rawValue, "message": diagnostic.message],
              "content": [["type": "text", "text": text]],
            ])
        }
      }
      do { try await engine?.waitForBackgroundOperations() }
      catch {
        let diagnostic = BackendDiagnostic(error: error)
        FileHandle.standardError.write(Data("EchoGuide: \(diagnostic.code.rawValue): \(diagnostic.message)\n".utf8))
      }
      do { try await engine?.waitForPublisherDownloads() }
      catch {
        let diagnostic = BackendDiagnostic(error: error)
        FileHandle.standardError.write(Data("EchoGuide: \(diagnostic.code.rawValue): \(diagnostic.message)\n".utf8))
      }
    }
  }
  static var toolDefinitions: [[String: Any]] {
    let definitions: [(String, String)] = [
      ("inspect", "Inspect host readiness; does not unlock or install."),
      ("prepare_downloads", "Start pinned publisher downloads in the private app-owned directory. Returns operation ID; poll status.downloadProgress. Downloads only, never Linux workspace readiness."),
      ("status", "Read the private local session and pending operation."),
      ("powered_wait_status", "Read saved powered-wait evidence and safety guidance, without request IDs or paths. Incomplete means keep wall power connected and inspect; never retry automatically. Completion does not prove unlock success."),
      (
        "verify_recovery",
        "Verify recovery using only the native app-selected device and ADB executable."
      ),
      (
        "backup",
        "Start verified private backups and return the persistent operation ID immediately. Poll status for backupProgress and completion. Uses only the native app-selected destination; requires prior recovery verification."
      ),
      (
        "request_unlock",
        "Request native human approval for a supported unlock. Cannot approve or execute it."
      ),
      (
        "request_install",
        "Request native human approval for installation. Cannot approve or execute it."
      ),
      ("report", "Return a redacted diagnostic report; no backup images or credentials."),
    ]
    return definitions.map { name, description -> [String: Any] in
      let schema: [String: Any] = ["type": "object", "properties": [:], "additionalProperties": false]
      let annotations: [String: Any] = [
        "readOnlyHint": !["request_unlock", "request_install", "backup", "prepare_downloads"].contains(name),
        "openWorldHint": name == "prepare_downloads"
      ]
      return [
        "name": name, "description": description,
        "inputSchema": schema,
        "annotations": annotations,
      ]
    }
  }
  static func respond(id: Any, result: [String: Any]? = nil, error: (Int, String)? = nil) {
    var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
    if let error {
      response["error"] = ["code": error.0, "message": error.1]
    } else {
      response["result"] = result ?? [:]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}
