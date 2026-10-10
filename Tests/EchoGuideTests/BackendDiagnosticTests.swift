import XCTest
@testable import EchoGuideCore

final class BackendDiagnosticTests: XCTestCase {
  func testTypedDiagnosticsNeverExportRawMessage() throws {
    let secret = "PRIVATE-IDENTIFIER /Users/private key-password"
    let diagnostic = BackendDiagnostic(error: BackendFailure(.approvalChanged, secret))
    XCTAssertEqual(diagnostic.code, .approvalChanged)
    let encoded = try JSONEncoder().encode(diagnostic)
    let text = String(decoding: encoded, as: UTF8.self)
    XCTAssertTrue(text.contains("approval_changed")); XCTAssertFalse(text.contains(secret))
  }
  func testUnknownErrorsCannotAcquireCodeFromTheirText() {
    let diagnostic = BackendDiagnostic(error: GuideError.stopped("permission_denied hash_mismatch guest_translation_missing PRIVATE"))
    XCTAssertEqual(diagnostic.code, .operationFailed)
    XCTAssertFalse(diagnostic.message.contains("PRIVATE"))
  }
  func testExactAdapterCocoaAndCancellationMapping() {
    XCTAssertEqual(BackendDiagnostic(error: AdapterError.mismatch("private")).code, .hashMismatch)
    XCTAssertEqual(BackendDiagnostic(error: AdapterError.inspectionUnavailable).code, .inspectionUnavailable)
    XCTAssertEqual(BackendDiagnostic(error: CancellationError()).code, .operationCancelled)
    XCTAssertEqual(BackendDiagnostic(error: NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)).code, .permissionDenied)
    XCTAssertEqual(BackendDiagnostic(error: NSError(domain: "unrelated", code: NSFileReadNoPermissionError)).code, .operationFailed)
  }
  func testFixedGuestExitCodeMapping() {
    XCTAssertEqual(GuestAdapter.readinessFailureCode(exitCode: 42), .guestTranslationMissing)
    XCTAssertEqual(GuestAdapter.readinessFailureCode(exitCode: 43), .guestTranslationMissing)
    XCTAssertEqual(GuestAdapter.readinessFailureCode(exitCode: 255), .guestAuthenticationRequired)
    XCTAssertEqual(GuestAdapter.readinessFailureCode(exitCode: 41), .unsupportedGuest)
    XCTAssertEqual(GuestAdapter.readinessFailureCode(exitCode: 1), .operationFailed)
  }
}
