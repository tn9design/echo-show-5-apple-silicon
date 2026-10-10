import Foundation

public struct GuestConnectionInspection: Codable, Sendable, Equatable {
  public let connected: Bool
  public let category: String
  public let reason: String
  public var networkProbe: GuestNetworkProbeResult? = nil
}

extension GuestAdapter {
  static func connectionFailure(_ result: CommandResult) -> GuestConnectionInspection {
    let text = result.stderr.lowercased()
    let category: String
    let reason: String
    if result.exitCode == 0 {
      category = "unexpected_connection_evidence"; reason = "SSH completed without the exact connection-check evidence. Inspect before setup; raw output is excluded."
    } else if result.exitCode == 255 {
      if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
        category = "host_key_rejected"; reason = "Pinned guest host key was rejected. Inspect through the owned serial channel; never disable host-key checking."
      } else if text.contains("permission denied (publickey") {
        category = "authentication_rejected"; reason = "The guest rejected the workspace SSH key. Inspect the owned account and key authorization; no password retry was performed."
      } else if text.contains("permission denied") {
        category = "ssh_access_denied"; reason = "SSH reported an access denial. Local key-file or socket access may be blocked; this does not establish guest key rejection."
      } else if text.contains("no route to host") || text.contains("operation not permitted") {
        category = "connection_blocked_or_unreachable"; reason = "The app cannot reach the guest. Check EchoGuide's Local Network permission and the owned VM's network state. This result does not establish which caused the failure."
      } else if text.contains("connection refused") {
        category = "connection_refused"; reason = "The guest connection was refused. Inspect the owned VM and SSH service."
      } else if text.contains("timed out") {
        category = "connection_timeout"; reason = "The guest connection timed out. Inspect the saved address and owned VM network; no address was replaced."
      } else {
        category = "ssh_transport_failed"; reason = "The app's pinned SSH transport failed. No raw guest output or private address is included."
      }
    } else {
      category = "guest_prerequisite_failed"; reason = "Guest identity or directory checks failed (exit \(result.exitCode)). Inspect the owned guest before setup."
    }
    return GuestConnectionInspection(connected: false, category: category, reason: reason)
  }

  func inspectConnection(networkProbe: any GuestNetworkProbing = GuestNetworkProbe()) async throws -> GuestConnectionInspection {
    let result = try await runner.run(executable: "/usr/bin/ssh", arguments: arguments(command:
      "set -eu; test \"$(id -un)\" = \(username) || exit 41; test \"$HOME\" = /home/\(username) || exit 42; test ! -L \(workspacePath) || exit 43; test -w /home/\(username) || exit 44; printf 'ECHOGUIDE-CONNECTION-OK\\n'"))
    guard result.exitCode == 0, result.stdout == "ECHOGUIDE-CONNECTION-OK\n" else {
      var failure = Self.connectionFailure(result)
      if result.exitCode == 255 {
        failure.networkProbe = await networkProbe.probe(address: address)
        if failure.networkProbe == .localNetworkDenied {
          return GuestConnectionInspection(connected: false, category: "local_network_denied",
            reason: "macOS denied this app's connection to the owned guest. Allow EchoGuide in System Settings → Privacy & Security → Local Network before another check.", networkProbe: .localNetworkDenied)
        }
      }
      return failure
    }
    return GuestConnectionInspection(connected: true, category: "connected",
      reason: "Pinned SSH connection and account checks passed. Translation and client readiness remain separate.")
  }
}

extension WorkflowEngine {
  public func inspectOwnedGuestConnection() async throws -> GuestConnectionInspection {
    try await operation("inspect_guest_connection") {
      let state = try self.status()
      guard let saved = state.guest, state.vmID == saved.vmID.uuidString else {
        throw GuideError.stopped("No bootstrapped owned guest to inspect")
      }
      let guest = try GuestAdapter(runner: self.runner, ownedVMID: saved.vmID,
        credentialsDirectory: self.store.root.appendingPathComponent("guest-" + saved.vmID.uuidString),
        address: saved.address, username: state.guestUsername ?? "user")
      return try await guest.inspectConnection()
    }
  }
}
