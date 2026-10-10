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
    guard application.isFileURL, application.pathExtension == "app",
      !application.path.contains("\n"), !application.path.contains("\r")
    else {
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

public enum OwnedVMState: String, Codable, Sendable {
  case stopped, starting, started, pausing, paused, resuming, stopping
}
public struct OwnedVMInfo: Codable, Sendable, Equatable {
  public let id: UUID
  public let state: OwnedVMState
  public let backend: String
}
public enum VMReconciliation: Sendable, Equatable {
  /// No matching VM was found. This does not authorize silently clearing a creation intent.
  case absent
  case owned(OwnedVMInfo)
}

extension UTMAdapter {
  public enum LifecycleAction: String, Sendable { case info, start, gracefulStop }
  private static func applicationLiteral(_ application: URL) throws -> String {
    guard application.isFileURL, application.pathExtension == "app",
      !application.path.contains("\n"), !application.path.contains("\r")
    else { throw GuideError.stopped("Invalid UTM application") }
    return application.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
      of: "\"", with: "\\\"")
  }
  /// Exact notes matching prevents similarly named user VMs from being adopted.
  public static func ownershipScript(application: URL, action: LifecycleAction = .info) throws
    -> String
  {
    let literal = try applicationLiteral(application)
    let mutation: String
    switch action {
    case .info: mutation = ""
    case .start:
      mutation = """
        if count of ownedVMs is not 1 then error "Owned VM missing or duplicated"
        set selectedVM to item 1 of ownedVMs
        if backend of selectedVM is not apple then error "Owned VM backend changed"
        if expectedVMID is "" or id of selectedVM is not expectedVMID then error "Owned VM binding changed"
        if status of selectedVM is stopped then
            start selectedVM
        else if status of selectedVM is not started then
            error "VM is transitioning or paused; inspect before starting"
        end if
        """
    case .gracefulStop:
      mutation = """
        if count of ownedVMs is not 1 then error "Owned VM missing or duplicated"
        set selectedVM to item 1 of ownedVMs
        if backend of selectedVM is not apple then error "Owned VM backend changed"
        if expectedVMID is "" or id of selectedVM is not expectedVMID then error "Owned VM binding changed"
        set activeInstallation to false
        try
            set installationInfo to query install selectedVM
            set activeInstallation to installing of installationInfo
        end try
        if activeInstallation then error "VM installation is active; shutdown blocked"
        if status of selectedVM is started then
            stop selectedVM by request
        else if status of selectedVM is not stopped then
            error "VM is transitioning or paused; no forced shutdown"
        end if
        """
    }
    return """
      on run argv
          set ownershipMarker to "EchoGuide ownership: " & (item 1 of argv)
          set expectedVMID to item 2 of argv
          tell application "\(literal)"
              if UTM version is not "5.0.6" then error "Unsupported UTM version"
              set ownedVMs to {}
              repeat with candidate in virtual machines
                  if backend of candidate is unavailable then error "VM metadata unavailable; reconciliation incomplete"
                  set candidateConfiguration to configuration of candidate
                  considering case
                      if notes of candidateConfiguration is ownershipMarker then set end of ownedVMs to contents of candidate
                  end considering
              end repeat
              if count of ownedVMs > 1 then error "Duplicate EchoGuide ownership markers; inspect without recreating"
              if count of ownedVMs is 1 and expectedVMID is not "" then
                  if id of item 1 of ownedVMs is not expectedVMID then error "Owned VM binding changed"
              end if
              \(mutation)
              if count of ownedVMs is 0 then return "NONE"
              set selectedVM to item 1 of ownedVMs
              if backend of selectedVM is not apple then error "Owned VM backend changed"
              set selectedState to status of selectedVM
              if selectedState is stopped then
                  set stateLabel to "stopped"
              else if selectedState is starting then
                  set stateLabel to "starting"
              else if selectedState is started then
                  set stateLabel to "started"
              else if selectedState is pausing then
                  set stateLabel to "pausing"
              else if selectedState is paused then
                  set stateLabel to "paused"
              else if selectedState is resuming then
                  set stateLabel to "resuming"
              else if selectedState is stopping then
                  set stateLabel to "stopping"
              else
                  error "Unknown VM state"
              end if
              return (id of selectedVM) & tab & "apple" & tab & stateLabel
          end tell
      end run
      """
  }
  private static func parseInfo(_ text: String, expectedVMID: UUID?) throws -> VMReconciliation {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "NONE" { return .absent }
    let fields = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 3, let id = UUID(uuidString: String(fields[0])), fields[1] == "apple",
      let state = OwnedVMState(rawValue: String(fields[2])),
      expectedVMID == nil || expectedVMID == id
    else {
      throw GuideError.stopped(
        "Owned VM identity/backend/state is ambiguous; inspect creation intent")
    }
    return .owned(OwnedVMInfo(id: id, state: state, backend: "apple"))
  }
  private func ownedOperation(
    specification: OwnedVMSpecification, expectedVMID: UUID?, action: LifecycleAction
  ) async throws -> VMReconciliation {
    if action != .info && expectedVMID == nil {
      throw GuideError.stopped("Lifecycle operation requires a persisted owned VM UUID")
    }
    let script = try Self.ownershipScript(application: application, action: action)
    let result = try await runner.run(
      executable: "/usr/bin/osascript",
      arguments: [
        "-e", script, specification.ownershipID.uuidString, expectedVMID?.uuidString ?? "",
      ])
    guard result.exitCode == 0 else {
      throw GuideError.stopped(
        result.stderr.contains("(-1743)")
          ? "UTM Automation permission denied"
          : "Owned VM operation failed; preserve creation intent and inspect ownership markers")
    }
    let reconciled = try Self.parseInfo(result.stdout, expectedVMID: expectedVMID)
    if action != .info, reconciled == .absent {
      throw GuideError.stopped("Owned VM disappeared; lifecycle outcome requires inspection")
    }
    return reconciled
  }
  public func reconcile(specification: OwnedVMSpecification, registeredVMID: UUID?) async throws
    -> VMReconciliation
  {
    try await ownedOperation(
      specification: specification, expectedVMID: registeredVMID, action: .info)
  }
  public func info(specification: OwnedVMSpecification, vmID: UUID) async throws -> OwnedVMInfo {
    guard
      case .owned(let value) = try await reconcile(
        specification: specification, registeredVMID: vmID)
    else {
      throw GuideError.stopped("Recorded owned VM is absent; preserve binding until inspected")
    }
    return value
  }
  public func start(specification: OwnedVMSpecification, vmID: UUID) async throws -> OwnedVMInfo {
    guard
      case .owned(let value) = try await ownedOperation(
        specification: specification, expectedVMID: vmID, action: .start)
    else { throw GuideError.stopped("Owned VM start outcome unknown") }
    return value
  }
  /// A guest may ignore the shutdown request; inspect returned state rather than assuming stopped.
  public func requestGracefulStop(specification: OwnedVMSpecification, vmID: UUID) async throws
    -> OwnedVMInfo
  {
    guard
      case .owned(let value) = try await ownedOperation(
        specification: specification, expectedVMID: vmID, action: .gracefulStop)
    else { throw GuideError.stopped("Owned VM stop outcome unknown") }
    return value
  }
}

public struct OwnedSerialChannel: Codable, Sendable, Equatable {
  public let vmID: UUID
  public let portID: Int
  public let path: String
}

extension UTMAdapter {
  /// UTM 5.0.6 serial-port address is the Apple backend's live PTY interface name.
  /// This discovers an address only; it does not open the port or treat its output as trusted yet.
  public static func serialChannelScript(application: URL) throws -> String {
    let script = try ownershipScript(application: application)
    let returnLine = "return (id of selectedVM) & tab & \"apple\" & tab & stateLabel"
    let serialInspection = """
      if expectedVMID is "" then error "Serial discovery requires a persisted VM UUID"
      if selectedState is not started then error "Owned VM must be running for serial discovery"
      set guestPorts to serial ports of selectedVM
      if count of guestPorts is not 1 then error "Missing or ambiguous owned serial ports"
      set guestPort to item 1 of guestPorts
      if interface of guestPort is not ptty then error "Owned serial port is unavailable or not PTY"
      set ptyAddress to address of guestPort
      if ptyAddress is "" then error "Owned PTY address is not available"
      return (id of selectedVM) & tab & (id of guestPort as text) & tab & ptyAddress
      """
    guard script.contains(returnLine) else {
      throw GuideError.stopped("Serial discovery script invariant failed")
    }
    return script.replacingOccurrences(of: returnLine, with: serialInspection)
  }
  public func serialChannel(specification: OwnedVMSpecification, vmID: UUID) async throws
    -> OwnedSerialChannel
  {
    let script = try Self.serialChannelScript(application: application)
    let result = try await runner.run(
      executable: "/usr/bin/osascript",
      arguments: ["-e", script, specification.ownershipID.uuidString, vmID.uuidString])
    guard result.exitCode == 0 else {
      throw GuideError.stopped(
        result.stderr.contains("(-1743)")
          ? "UTM Automation permission denied"
          : "Owned serial channel unavailable; leave VM and ownership binding intact")
    }
    let fields = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(
      separator: "\t", omittingEmptySubsequences: false)
    guard fields.count == 3, UUID(uuidString: String(fields[0])) == vmID,
      let portID = Int(fields[1]), portID == 0,
      String(fields[2]).range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil
    else { throw GuideError.stopped("Serial address, port index, or VM binding is ambiguous") }
    return OwnedSerialChannel(vmID: vmID, portID: portID, path: String(fields[2]))
  }
}
