import CryptoKit
import Foundation

extension GuestAdapter {
  public static func bundledTranslationSetup() throws -> URL {
    guard let url = Bundle.module.url(forResource: "setup-linux-translation", withExtension: "sh") else {
      throw GuideError.stopped("Bundled translation setup missing")
    }
    let artifact = try CompatibilityProfile.bundled().artifact(named: "setup-linux-translation.sh")
    let bytes = try Data(contentsOf: url)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard hash == artifact.sha256, artifact.size == Int64(bytes.count) else {
      throw BackendFailure(.hashMismatch, "Bundled translation setup hash mismatch")
    }
    return url
  }

  /// Authenticates the supervision helper only; never dispatches it.
  public static func bundledTranslationAttemptHelper() throws -> URL {
    guard let url = Bundle.module.url(forResource: "translation-attempt", withExtension: "sh") else {
      throw GuideError.stopped("Bundled translation supervision helper missing")
    }
    let artifact = try CompatibilityProfile.bundled().artifact(named: "translation-attempt.sh")
    let bytes = try Data(contentsOf: url)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    guard hash == artifact.sha256, artifact.size == Int64(bytes.count) else {
      throw BackendFailure(.hashMismatch, "Bundled translation supervision helper hash mismatch")
    }
    return url
  }

  /// Fixed guest provisioning only. Password input and guest output never enter diagnostics.
  func configureTranslation(password: String, sensitiveRunner: any SensitiveCommandRunning,
    beforeSetup: @Sendable () throws -> Void = {}) async throws {
    try SerialLogin.validatePassword(password)
    let source = try Self.bundledTranslationSetup()
    let hash = try CompatibilityProfile.bundled().artifact(named: "setup-linux-translation.sh").sha256
    let target = workspacePath + "/setup-linux-translation.sh"
    let preparation = try await runner.run(executable: "/usr/bin/ssh", arguments: arguments(command:
      "set -eu; test -x /usr/bin/sudo || exit 45; test \"$(id -un)\" = \(username); test \"$HOME\" = /home/\(username); test ! -L \(workspacePath); mkdir -p \(workspacePath); chmod 700 \(workspacePath); test ! -L \(target)"))
    guard preparation.exitCode == 0 else {
      if preparation.exitCode == 45 {
        throw GuideError.stopped("The owned Debian guest has no /usr/bin/sudo. Translation setup requires a sudo-enabled account; no password was submitted and no setup ran. Inspect the guest installation before continuing")
      }
      let failure = Self.connectionFailure(preparation)
      throw GuideError.stopped("Translation staging stopped [\(failure.category)]: \(failure.reason) No setup executed")
    }
    let options = try Array(arguments(command: "").dropLast(2)).filter { $0 != "-T" }
    let transfer = try await runner.run(executable: "/usr/bin/scp", arguments:
      ["-B"] + options + [source.path, username + "@" + address + ":" + target])
    guard transfer.exitCode == 0 else { throw GuideError.stopped("Translation setup transfer failed; no setup executed") }
    let verification = try await runner.run(executable: "/usr/bin/ssh", arguments: arguments(command:
      "set -eu; test ! -L \(target); chmod 600 \(target); printf '%s  %s\\n' \(hash) \(target) | sha256sum -c - >/dev/null"))
    guard verification.exitCode == 0 else { throw BackendFailure(.hashMismatch, "Guest translation setup verification failed; no setup executed") }
    // Copy into a root-owned temporary file before verifying/executing, so the
    // logged-in guest account cannot replace the script after its hash check.
    let privileged = "set -eu; setup=$(mktemp /run/echoguide-translation.XXXXXX); trap 'rm -f -- \"$setup\"' EXIT; cp -- \(target) \"$setup\"; chmod 600 \"$setup\"; printf '%s  %s\\n' \(hash) \"$setup\" | sha256sum -c - >/dev/null; /bin/bash \"$setup\""
    let quoted = "'" + privileged.replacingOccurrences(of: "'", with: "'\\''") + "'"
    try Task.checkCancellation()
    try beforeSetup()
    let code = try await sensitiveRunner.run(executable: "/usr/bin/ssh", arguments: arguments(command:
      "/usr/bin/sudo -S -k -p '' /bin/bash -c \(quoted)"), input: Data((password + "\n").utf8), timeoutSeconds: 1800)
    guard code == 0 else { throw GuideError.stopped("Guest translation setup failed (exit \(code)); inspect before another explicit attempt") }
  }
}

extension WorkflowEngine {
  func requireTranslationInspectionComplete() throws {
    guard !FileManager.default.fileExists(atPath: store.root.appendingPathComponent("translation-setup-pending.json").path) else {
      throw GuideError.stopped("Previous translation setup may still be running. Inspect the guest before setup, restart, or readiness validation; no automatic reconciliation")
    }
  }
  /// An explicit guest-only write; never called by inspection or device operations.
  public func configureOwnedGuestTranslation(utm: URL, password: String,
    sensitiveRunner: any SensitiveCommandRunning = SensitiveProcessRunner()) async throws {
    try SerialLogin.validatePassword(password)
    try await operationWithIdentifier("configure_guest_translation") { operationID in
      try self.requireTranslationInspectionComplete()
      let state = try self.status()
      guard let saved = state.guest, state.vmID == saved.vmID.uuidString,
        state.device == nil, state.pendingApproval == nil else {
        throw GuideError.stopped("Translation setup requires the owned bootstrapped workspace before device selection")
      }
      let specification = try JSONDecoder().decode(OwnedVMSpecification.self,
        from: Data(contentsOf: self.store.root.appendingPathComponent("workspace-intent.json")))
      let adapter = UTMAdapter(runner: self.runner, application: utm)
      _ = try await adapter.serialChannel(specification: specification, vmID: saved.vmID)
      try self.store.transaction { $0.guest?.ready = false }
      let guest = try GuestAdapter(runner: self.runner, ownedVMID: saved.vmID,
        credentialsDirectory: self.store.root.appendingPathComponent("guest-" + saved.vmID.uuidString),
        address: saved.address, username: state.guestUsername ?? "user")
      let intent = self.store.root.appendingPathComponent("translation-setup-pending.json")
      try await guest.configureTranslation(password: password, sensitiveRunner: sensitiveRunner) {
        let record = ["vmID": saved.vmID.uuidString, "action": "configure_guest_translation",
          "operationID": operationID.uuidString,
          "scriptSHA256": try self.profile.artifact(named: "setup-linux-translation.sh").sha256]
        try JSONEncoder().encode(record).write(to: intent, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: intent.path)
      }
      try FileManager.default.removeItem(at: intent)
      // A successful setup is not readiness; require restart and offline client validation.
    }
  }
}
