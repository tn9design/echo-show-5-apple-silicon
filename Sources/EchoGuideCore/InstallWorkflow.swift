import Foundation

extension WorkflowEngine {
  /// Internal pilot integration only. There is no public app/CLI/MCP dispatcher.
  /// The native release gate remains closed independently of this tested sequence.
  func installPinnedROM(requestID: UUID, adb: URL,
      hostPrerequisite: (@Sendable (SessionRecord) async throws -> Void)? = nil) async throws {
    let log = store.root.appendingPathComponent("install-recovery.log")
    try await withFreshConsumedApproval(requestID: requestID, validator: { state in
      try await hostPrerequisite?(state)
      guard adb.isFileURL, adb.path.hasPrefix("/"), state.adbPath == adb.path,
        state.phase == .backedUp, state.profileID == self.profile.id,
        let device = state.device, device.product == self.profile.product,
        device.recoveryVersion == self.profile.recoveryVersion,
        state.pendingApproval?.action == .install else {
        throw GuideError.stopped("Installation requires the exact backed-up recovery and selected ADB")
      }
      guard !FileManager.default.fileExists(atPath: log.path),
        (try? FileManager.default.attributesOfItem(atPath: log.path)) == nil else {
        throw GuideError.stopped("Previous installation log exists; inspect it before another attempt")
      }
      let artifact = try self.profile.artifact(named: ROMStagingAdapter.filename)
      guard state.stagedROMHash == artifact.sha256, let bytes = artifact.size, bytes > 0 else {
        throw GuideError.stopped("Pinned device ROM staging evidence is missing")
      }
      let recovery = try RecoveryAdapter(runner: self.runner, adbPath: adb.path, serial: device.serial)
      try await recovery.verify()
      let manifest = try Self.verifyStagingBackups(state)
      let hash = try await self.runner.run(executable: adb.path,
        arguments: ["-s", device.serial, "shell", "sha256sum", ROMStagingAdapter.destination])
      let size = try await self.runner.run(executable: adb.path,
        arguments: ["-s", device.serial, "shell", "stat", "-c", "%s", ROMStagingAdapter.destination])
      guard hash.exitCode == 0, ROMStagingAdapter.exactRemoteHash(hash.stdout, expected: artifact.sha256),
        size.exitCode == 0, size.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == String(bytes) else {
        throw GuideError.stopped("Fresh device ZIP verification failed; no wipe started")
      }
      try await hostPrerequisite?(state)
      let evidence = try ApprovalPrerequisites(session: state, action: .install,
        profile: self.profile, backupManifestData: manifest)
      return FreshApprovalEvidence(prerequisites: evidence, checkedAt: Date())
    }, callback: { consumed in
      guard consumed.action == .install else { throw GuideError.stopped("Wrong consumed approval action") }
      let artifact = try self.profile.artifact(named: ROMStagingAdapter.filename)
      try await PilotSequence(runner: self.runner).install(adb: adb.path,
        serial: consumed.device.serial, romHash: artifact.sha256, saveLog: log)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path)
      try self.store.transaction { state in
        guard state.id == consumed.sessionID, state.device == consumed.device,
          state.profileID == self.profile.id, state.pendingApproval == nil else {
          throw GuideError.stopped("Session changed during installation; inspect the saved recovery log")
        }
        state.phase = .installed
        state.startupConfirmed = false
        state.postInstallObservations = nil
      }
    })
  }
}
