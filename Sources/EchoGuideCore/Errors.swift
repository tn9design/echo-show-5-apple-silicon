import Foundation

/// Stable machine-readable outcomes; unclassified failures remain unknown.
public enum BackendErrorCode: String, Codable, Sendable {
  case permissionDenied = "permission_denied"
  case inspectionUnavailable = "inspection_unavailable"
  case guestTranslationMissing = "guest_translation_missing"
  case guestAuthenticationRequired = "guest_authentication_required"
  case unsupportedGuest = "unsupported_guest"
  case unsupportedDevice = "unsupported_device"
  case hashMismatch = "hash_mismatch"
  case interruptedOperation = "interrupted_operation"
  case approvalChanged = "approval_changed"
  case operationCancelled = "operation_cancelled"
  case operationFailed = "operation_failed"
  case operationTimeout = "operation_timeout"
  case insufficientSpace = "insufficient_space"
  case mountedData = "mounted_data"
  case invalidPartitions = "invalid_partitions"
  case destinationExists = "destination_exists"
  case concurrentOperation = "concurrent_operation"
}
public struct BackendFailure: Error, LocalizedError, Sendable {
  public let code: BackendErrorCode
  /// Local presentation only; diagnostics use fixed messages instead.
  public let message: String
  public init(_ code: BackendErrorCode, _ message: String) { self.code = code; self.message = message }
  public var errorDescription: String? { message }
}
public struct BackendDiagnostic: Codable, Sendable, Equatable {
  public let code: BackendErrorCode
  public let message: String
  public init(error: any Error) {
    if let failure = error as? BackendFailure { code = failure.code }
    else if error is CancellationError { code = .operationCancelled }
    else if let adapter = error as? AdapterError {
      switch adapter {
      case .inspectionUnavailable: code = .inspectionUnavailable
      case .invalidDevice, .incompatibleRecovery: code = .unsupportedDevice
      case .invalidPartitions: code = .invalidPartitions
      case .insufficientSpace: code = .insufficientSpace
      case .mountedData: code = .mountedData
      case .mismatch: code = .hashMismatch
      case .destinationExists: code = .destinationExists
      case .commandFailed: code = .operationFailed
      }
    } else {
      let ns = error as NSError
      code = ns.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(ns.code) ? .permissionDenied : .operationFailed
    }
    message = Self.message(for: code)
  }
  public static func message(for code: BackendErrorCode) -> String {
    switch code {
    case .permissionDenied: return "Required local permission was denied. Review access before retrying."
    case .inspectionUnavailable: return "Inspection is unavailable; device presence or compatibility remains unknown."
    case .guestTranslationMissing: return "Linux translation is missing or disabled. Complete the owned workspace translation setup."
    case .guestAuthenticationRequired: return "Authenticated guest access is unavailable. Recheck owned serial trust and client authentication."
    case .unsupportedGuest: return "The guest does not match the supported ARM64 environment."
    case .unsupportedDevice: return "The selected device or recovery does not match the pinned compatibility profile."
    case .hashMismatch: return "Required bytes failed integrity verification; no verified result was recorded."
    case .interruptedOperation: return "An interrupted operation requires inspection and must not be replayed automatically."
    case .approvalChanged: return "Native approval is missing, expired, or bound to changed prerequisites."
    case .operationCancelled: return "The operation was cancelled. Inspect its state before continuing."
    case .operationFailed: return "The operation failed with an unclassified result. Inspect local details before continuing."
    case .operationTimeout: return "The operation timed out; its outcome requires inspection."
    case .insufficientSpace: return "The backup destination lacks required free space."
    case .mountedData: return "User data remains mounted; backup must stop before capture."
    case .invalidPartitions: return "Named partition mappings are missing or ambiguous."
    case .destinationExists: return "Existing destination files were preserved. Choose a new empty destination."
    case .concurrentOperation: return "Another operation owns this session. Wait for its result."
    }
  }
}
