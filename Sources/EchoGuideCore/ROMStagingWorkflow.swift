import Foundation

protocol ROMStaging: Sendable {
  func stage(adb: String, serial: String, localROM: URL, artifact: Artifact,
             evidenceURL: URL) async throws -> ROMStagingAdapter.Receipt
}
extension ROMStagingAdapter: ROMStaging {}

extension WorkflowEngine {
  /// Internal pilot integration only. Not exposed through the app, CLI, or MCP.
  /// Copies the pinned ROM, never wipes, installs, or reboots. The live write
  /// release gate in approve remains disabled independently of staging evidence.
  func stagePinnedROM(adb: URL, localROM: URL,
                      staging: (any ROMStaging)? = nil) async throws -> ROMStagingAdapter.Receipt {
    try await operation("stage_rom") {
      let initial = try self.store.transaction { state in
        state.pendingApproval = nil
        state.stagedROMHash = nil
        return state
      }
      guard initial.phase == .backedUp, initial.profileID == self.profile.id,
            let device = initial.device, device.product == self.profile.product,
            device.recoveryVersion == self.profile.recoveryVersion else {
        throw GuideError.stopped("ROM staging requires the exact backed-up recovery device")
      }
      let manifest = try Self.verifyStagingBackups(initial)
      let snapshot = try ApprovalPrerequisites(session: initial, action: .install,
        profile: self.profile, backupManifestData: manifest)
      let artifact = try self.profile.artifact(named: ROMStagingAdapter.filename)
      let receiptURL = self.store.root.appendingPathComponent("staged-rom-receipt.json")
      let adapter = staging ?? ROMStagingAdapter(runner: self.runner)
      let receipt = try await adapter.stage(adb: adb.path, serial: device.serial,
        localROM: localROM, artifact: artifact, evidenceURL: receiptURL)
      guard receipt.serial == device.serial, receipt.destination == ROMStagingAdapter.destination,
            receipt.sha256 == artifact.sha256, receipt.bytes == artifact.size else {
        throw GuideError.stopped("Staging receipt does not match the pinned device and ROM")
      }
      let durable = try JSONDecoder().decode(ROMStagingAdapter.Receipt.self,
        from: Data(contentsOf: receiptURL))
      guard durable.serial == receipt.serial, durable.destination == receipt.destination,
            durable.sha256 == receipt.sha256, durable.bytes == receipt.bytes,
            durable.verifiedAt == receipt.verifiedAt else {
        throw GuideError.stopped("Durable staging receipt differs from verified evidence")
      }
      try self.store.transaction { current in
        let currentManifest = try Self.verifyStagingBackups(current)
        let currentSnapshot = try ApprovalPrerequisites(session: current, action: .install,
          profile: self.profile, backupManifestData: currentManifest)
        guard currentSnapshot == snapshot, current.pendingApproval == nil else {
          throw GuideError.stopped("Session, device, or backup evidence changed during staging")
        }
        current.adbPath = adb.path
        current.stagedROMHash = receipt.sha256
      }
      return receipt
    }
  }

  private static func verifyStagingBackups(_ state: SessionRecord) throws -> Data {
    guard let path = state.backupManifest else {
      throw GuideError.stopped("Verified backup manifest is missing")
    }
    let manifestURL = URL(fileURLWithPath: path)
    guard manifestURL.standardizedFileURL == manifestURL.resolvingSymlinksInPath().standardizedFileURL else {
      throw GuideError.stopped("Backup manifest cannot be a symbolic link")
    }
    let data = try Data(contentsOf: manifestURL)
    let entries = try JSONDecoder().decode([VerifiedPartitionBackup].self, from: data)
    guard entries.count == 5, Set(entries.map { $0.partition.device }).count == 5,
      Set(entries.map { $0.partition.name }) == Set(["boot", "recovery", "system", "userdata", "metadata"]) else {
      throw GuideError.stopped("Verified backup manifest is incomplete")
    }
    for entry in entries {
      guard entry.filename == entry.partition.name + ".img",
        entry.partition.device.range(of: "^/dev/block/mmcblk0p[0-9]+$", options: .regularExpression) != nil,
        entry.partition.size >= 1_048_576, entry.partition.size <= 32 * 1024 * 1024 * 1024,
        entry.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
        throw GuideError.stopped("Invalid verified backup entry")
      }
      let file = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.filename)
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        (attributes[.size] as? NSNumber)?.uint64Value == entry.partition.size,
        try RecoveryAdapter.hash(file) == entry.sha256 else {
        throw GuideError.stopped("Backup bytes changed before staging was recorded")
      }
    }
    return data
  }
}
