import Foundation

public enum PostInstallCheck: String, Codable, CaseIterable, Sendable, Identifiable {
  case wifi, touchscreen, audio, microphone, camera, normalReboot
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .wifi: return "Wi-Fi"
    case .touchscreen: return "Touchscreen"
    case .audio: return "Audio"
    case .microphone: return "Microphone"
    case .camera: return "Camera"
    case .normalReboot: return "Normal reboot"
    }
  }
}
public enum PostInstallOutcome: String, Codable, CaseIterable, Sendable, Identifiable {
  case notChecked, working, issueObserved, unableToCheck
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .notChecked: return "Not checked"
    case .working: return "I checked: working"
    case .issueObserved: return "I checked: issue observed"
    case .unableToCheck: return "Unable to check"
    }
  }
}
public struct PostInstallObservation: Codable, Sendable, Equatable {
  public let check: PostInstallCheck
  public let outcome: PostInstallOutcome
  public let reportedAt: Date
  /// Manual report by the person using the device, never an automated hardware claim.
  public let source: String
}

extension WorkflowEngine {
  /// Called from native checklist controls after an explicit personal observation.
  /// No MCP endpoint can populate hardware outcomes on the person's behalf.
  public func recordPostInstallObservation(check: PostInstallCheck, outcome: PostInstallOutcome) throws {
    try store.transaction { state in
      guard state.phase == .installed || state.phase == .finished else {
        throw GuideError.stopped("Post-install observations require a verified installation")
      }
      guard state.operations.allSatisfy({ $0.completedAt != nil }) else {
        throw GuideError.stopped("Inspect the interrupted operation before recording hardware outcomes")
      }
      var observations = state.postInstallObservations ?? []
      observations.removeAll { $0.check == check }
      if outcome != .notChecked {
        observations.append(PostInstallObservation(check: check, outcome: outcome, reportedAt: Date(), source: "personReported"))
      }
      state.postInstallObservations = observations.sorted { $0.check.rawValue < $1.check.rawValue }
    }
  }
}
