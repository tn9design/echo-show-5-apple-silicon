import Foundation

public enum GuestUsername {
  public static func validated(_ value: String) throws -> String {
    guard !value.isEmpty, value.utf8.count <= 32,
      value.utf8.first.map({ (97...122).contains($0) || $0 == 95 }) == true,
      value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
      value != "root" else { throw GuideError.stopped("Enter the Debian account username using lowercase letters, digits, underscore or hyphen; root is unsupported") }
    return value
  }
}
extension WorkflowEngine {
  public func configureGuestUsername(_ username: String) throws {
    let value = try GuestUsername.validated(username)
    try store.transaction { state in
      guard let vmID = state.vmID, state.operations.allSatisfy({ $0.completedAt != nil }) else {
        throw GuideError.stopped("Inspect the owned or interrupted workspace before configuring its account")
      }
      if (state.guestUsername ?? "user") == value { return }
      guard !FileManager.default.fileExists(atPath: store.root.appendingPathComponent("guest-" + vmID).path),
        state.guest == nil, state.device == nil, state.pendingApproval == nil else {
        throw GuideError.stopped("Configure the owned guest account before authentication or device identification")
      }
      state.guestUsername = value
    }
  }
}
