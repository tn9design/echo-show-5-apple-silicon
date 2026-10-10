import Foundation

struct TranslationAttemptBinding: Sendable {
  let attempt: UUID
  let vm: UUID
  let session: UUID
  let boot: UUID
  let hash: String
  let account: String
}

struct TranslationReceiptObservation: Sendable, Equatable {
  enum State: String, Sendable { case unknown, running, terminalPackageStateUnverified }
  let state: State
  let exitStatus: Int?
  /// Never establishes package consistency, readiness, or permission to reconcile.
  static func parse(_ frame: String, expected: TranslationAttemptBinding) throws -> Self {
    func invalid() -> GuideError { .stopped("Translation receipt is incomplete or does not match this attempt") }
    guard frame.utf8.count <= 8192, !frame.contains("\r"), !frame.contains("\0"),
      frame.hasSuffix("\n") else { throw invalid() }
    let lines = frame.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.first == "ECHOGUIDE-INSPECTION-v1", lines.suffix(2) == ["END", ""] else { throw invalid() }
    if lines == ["ECHOGUIDE-INSPECTION-v1", "category=unknown", "END", ""] {
      return Self(state: .unknown, exitStatus: nil)
    }
    let terminalFields: Set<String> = ["result", "code", "status"]
    let allowed: Set<String> = ["version", "attempt", "vm", "session", "hash", "boot", "account", "invocation", "result", "code", "status", "LoadState", "ActiveState", "SubState", "Result", "ExecMainCode", "ExecMainStatus", "InvocationID", "ControlGroup", "cgroupPopulated", "category", "packageState", "receiptState"]
    var fields: [String: String] = [:]
    var invocations: [String] = []
    for line in lines.dropFirst().dropLast(2) {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, allowed.contains(String(parts[0])) else { throw invalid() }
      let key = String(parts[0]), value = String(parts[1])
      if key == "invocation" { invocations.append(value) }
      else { guard fields.updateValue(value, forKey: key) == nil else { throw invalid() } }
    }
    let runningFrame = fields["receiptState"] == "running"
    let required = runningFrame ? allowed.subtracting(terminalFields.union(["invocation"])) : allowed.subtracting(["invocation", "receiptState"])
    guard Set(fields.keys) == required,
      fields["version"] == "1", fields["category"] == "unknown", fields["packageState"] == "unverified",
      UUID(uuidString: fields["attempt"]!) == expected.attempt,
      UUID(uuidString: fields["vm"]!) == expected.vm,
      UUID(uuidString: fields["session"]!) == expected.session,
      UUID(uuidString: fields["boot"]!) == expected.boot,
      expected.hash.count == 64, expected.hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      fields["hash"] == expected.hash, fields["account"] == expected.account,
      invocations.count == (runningFrame ? 1 : 2),
      runningFrame || invocations[0] == invocations[1], invocations[0].count == 32,
      invocations[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw invalid() }
    // systemd may discard live metadata after stopping or unloading a unit.
    // Absence is not evidence that the process group drained.
    guard fields["InvocationID"] == "" || fields["InvocationID"] == invocations[0],
      fields["ControlGroup"] == "" || fields["ControlGroup"] == "/system.slice/echoguide-translation-\(fields["attempt"]!).service" else { throw invalid() }
    if fields["InvocationID"] == "" || fields["ControlGroup"] == "" || fields["LoadState"] == "not-found" {
      return Self(state: .unknown, exitStatus: nil)
    }
    let active = fields["ActiveState"]!, sub = fields["SubState"]!
    guard fields["LoadState"] == "loaded",
      fields["ControlGroup"] == "/system.slice/echoguide-translation-\(fields["attempt"]!).service",
      ["active", "activating", "deactivating", "inactive", "failed"].contains(active),
      ["0", "1", "unknown"].contains(fields["cgroupPopulated"]!) else { throw invalid() }
    if runningFrame {
      guard ["active", "activating"].contains(active), fields["cgroupPopulated"] == "1" else { throw invalid() }
      return Self(state: .running, exitStatus: nil)
    }
    if ["active", "activating", "deactivating"].contains(active) || fields["cgroupPopulated"] == "1" {
      return Self(state: .running, exitStatus: nil)
    }
    let status = fields["status"]!
    guard ["dead", "failed"].contains(sub),
      fields["cgroupPopulated"] == "0",
      fields["ControlGroup"] == "/system.slice/echoguide-translation-\(fields["attempt"]!).service",
      fields["result"] == fields["Result"], fields["code"] == "exited",
      fields["ExecMainCode"] == "1", status == fields["ExecMainStatus"],
      !status.isEmpty, status.utf8.allSatisfy({ (48...57).contains($0) }),
      let exit = Int(status), (0...255).contains(exit),
      fields["result"] != "success" || exit == 0 else {
      return Self(state: .unknown, exitStatus: nil)
    }
    return Self(state: .terminalPackageStateUnverified, exitStatus: exit)
  }
}
