import CryptoKit
import Foundation

/// Immutable binding of the evidence reviewed by the human. This is not a write
/// grant, and persisted evidence must be independently refreshed before dispatch.
public struct ApprovalPrerequisites: Codable, Sendable, Equatable {
  public let sessionID: UUID
  public let action: WriteAction
  public let device: DeviceIdentity
  public let phase: Phase
  public let profileSHA256: String
  public let vmID: String?
  public let guestEvidenceSHA256: String?
  public let backupManifestSHA256: String?
  public let stagedROMHash: String?

  public init(session: SessionRecord, action: WriteAction, profile: CompatibilityProfile,
              backupManifestData: Data? = nil) throws {
    guard let device = session.device, session.profileID == profile.id else {
      throw GuideError.stopped("Approval session or selected device is not bound to this profile")
    }
    if action == .install, backupManifestData == nil {
      throw GuideError.stopped("Approval requires backup manifest content")
    }
    self.sessionID = session.id
    self.action = action
    self.device = device
    self.phase = session.phase
    self.profileSHA256 = try Self.hashEncoded(profile)
    self.vmID = session.vmID
    self.guestEvidenceSHA256 = try session.guest.map { try Self.hashEncoded($0) }
    self.backupManifestSHA256 = backupManifestData.map(Self.hash)
    self.stagedROMHash = session.stagedROMHash
  }

  public func digest() throws -> String { try Self.hashEncoded(self) }

  /// Reads manifest bytes, rather than binding approval only to a filename.
  public static func capture(session: SessionRecord, action: WriteAction,
                             profile: CompatibilityProfile) throws -> Self {
    let manifestData: Data?
    if action == .install {
      guard let path = session.backupManifest else {
        throw GuideError.stopped("Verified backup manifest is missing")
      }
      manifestData = try Data(contentsOf: URL(fileURLWithPath: path))
    } else { manifestData = nil }
    return try Self(session: session, action: action, profile: profile, backupManifestData: manifestData)
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func hashEncoded<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return hash(try encoder.encode(value))
  }
}

public enum ApprovalPolicy {
  public static let validitySeconds: TimeInterval = 300

  /// Validation does not authorize dispatch. The native app remains the only
  /// provided approval client; live write dispatch stays disabled in the preview.
  public static func validate(_ request: ApprovalRequest, requestID: UUID,
                              current: ApprovalPrerequisites, now: Date = Date()) throws {
    let age = now.timeIntervalSince(request.createdAt)
    guard age.isFinite, age >= 0, age < validitySeconds,
          request.id == requestID, request.sessionID == current.sessionID,
          request.action == current.action, request.device == current.device,
          request.prerequisitesDigest == (try current.digest()) else {
      throw GuideError.stopped("Approval expired or prerequisites changed")
    }
  }
}
