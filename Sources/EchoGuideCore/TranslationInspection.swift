import Darwin
import Foundation

public struct TranslationInterruptionInspection: Codable, Sendable {
  public let category: String
  public let pendingIntentPresent: Bool
  public let incompleteTranslationJournal: Bool
  public let connection: GuestConnectionInspection
  public let reason: String
}

extension WorkflowEngine {
  /// Read-only exception for inspecting a legacy interrupted translation operation.
  /// Connection evidence cannot establish execution completion or release its guard.
  public func inspectInterruptedTranslation(utm: URL) async throws -> TranslationInterruptionInspection {
    let fd = open(store.root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GuideError.stopped("Cannot acquire operation lock") }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw BackendFailure(.concurrentOperation, "Another operation is active")
    }
    defer { flock(fd, LOCK_UN) }
    let state = try status()
    let incomplete = state.operations.filter { $0.completedAt == nil }
    guard incomplete.count <= 1, incomplete.allSatisfy({ $0.action == "configure_guest_translation" }) else {
      throw BackendFailure(.interruptedOperation, "Another interrupted operation requires its own inspection")
    }
    guard let saved = state.guest, state.vmID == saved.vmID.uuidString else {
      throw GuideError.stopped("No matching owned guest to inspect")
    }
    let intent = store.root.appendingPathComponent("translation-setup-pending.json")
    let attributes: [FileAttributeKey: Any]?
    do { attributes = try FileManager.default.attributesOfItem(atPath: intent.path) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { attributes = nil }
    catch { throw GuideError.stopped("Translation intent could not be inspected") }
    let pending = attributes != nil
    let intentSnapshot: Data?
    if let attributes {
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber, size.intValue <= 4096 else {
        throw GuideError.stopped("Translation intent is invalid or belongs to another workspace")
      }
      let bytes = try Data(contentsOf: intent)
      intentSnapshot = bytes
      guard let record = try? JSONDecoder().decode([String: String].self, from: bytes),
        record["vmID"] == saved.vmID.uuidString, record["action"] == "configure_guest_translation" else {
        throw GuideError.stopped("Translation intent is invalid or belongs to another workspace")
      }
      if let operationText = record["operationID"] {
        guard let operationID = UUID(uuidString: operationText),
          state.operations.contains(where: { $0.id == operationID && $0.action == "configure_guest_translation" }),
          record["scriptSHA256"] == (try profile.artifact(named: "setup-linux-translation.sh").sha256) else {
          throw GuideError.stopped("Translation intent does not match its operation or pinned script")
        }
      } else if record["scriptSHA256"] != nil {
        throw GuideError.stopped("Translation intent has incomplete attempt bindings")
      }
    } else {
      intentSnapshot = nil
    }
    guard pending || !incomplete.isEmpty else {
      throw GuideError.stopped("No interrupted translation evidence to inspect")
    }
    let workspaceIntent = store.root.appendingPathComponent("workspace-intent.json")
    let workspaceSnapshot = try Data(contentsOf: workspaceIntent)
    let specification = try JSONDecoder().decode(OwnedVMSpecification.self, from: workspaceSnapshot)
    let adapter = UTMAdapter(runner: runner, application: utm)
    let channel = try await adapter.serialChannel(specification: specification, vmID: saved.vmID)
    let guest = try GuestAdapter(runner: runner, ownedVMID: saved.vmID,
      credentialsDirectory: store.root.appendingPathComponent("guest-" + saved.vmID.uuidString),
      address: saved.address, username: state.guestUsername ?? "user")
    let connection = try await guest.inspectConnection()
    guard try await adapter.serialChannel(specification: specification, vmID: saved.vmID) == channel else {
      throw GuideError.stopped("Owned workspace changed during inspection")
    }
    let current = try status()
    let currentIntent: Data?
    do { currentIntent = try Data(contentsOf: intent) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { currentIntent = nil }
    catch { throw GuideError.stopped("Translation intent could not be rechecked") }
    guard current.id == state.id, current.vmID == state.vmID,
      current.operations.filter({ $0.completedAt == nil }).map(\.id) == incomplete.map(\.id),
      currentIntent == intentSnapshot,
      try Data(contentsOf: workspaceIntent) == workspaceSnapshot,
      current.guestUsername == state.guestUsername,
      current.guest?.hostKeyFingerprint == saved.hostKeyFingerprint,
      current.guest?.address == saved.address else {
      throw GuideError.stopped("Guest bindings changed during inspection")
    }
    return TranslationInterruptionInspection(category: "unknown", pendingIntentPresent: pending,
      incompleteTranslationJournal: !incomplete.isEmpty, connection: connection,
      reason: "Legacy setup has no attempt-bound terminal receipt or process-group evidence. Connection and tool availability do not prove completion. No marker, journal, readiness or guest state was changed; setup and restart remain blocked.")
  }
}
