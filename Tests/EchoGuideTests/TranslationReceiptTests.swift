import XCTest
@testable import EchoGuideCore

final class TranslationReceiptTests: XCTestCase {
  let id = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
  var binding: TranslationAttemptBinding { .init(attempt: id, vm: id, session: id, boot: id, hash: String(repeating: "a", count: 64), account: "echotest") }
  var frame: String {
    """
    ECHOGUIDE-INSPECTION-v1
    version=1
    attempt=\(id.uuidString)
    vm=\(id.uuidString)
    session=\(id.uuidString)
    hash=\(binding.hash)
    boot=\(id.uuidString)
    account=echotest
    invocation=\(String(repeating: "b", count: 32))
    invocation=\(String(repeating: "b", count: 32))
    result=success
    code=exited
    status=0
    LoadState=loaded
    ActiveState=inactive
    SubState=dead
    Result=success
    ExecMainCode=1
    ExecMainStatus=0
    InvocationID=\(String(repeating: "b", count: 32))
    ControlGroup=/system.slice/echoguide-translation-\(id.uuidString).service
    cgroupPopulated=0
    category=unknown
    packageState=unverified
    END

    """
  }
  func testTerminalNeverMeansReadyOrPackageClean() throws {
    let result = try TranslationReceiptObservation.parse(frame, expected: binding)
    XCTAssertEqual(result.state, .terminalPackageStateUnverified)
    XCTAssertEqual(result.exitStatus, 0)
    let running = try TranslationReceiptObservation.parse(frame.replacingOccurrences(of: "cgroupPopulated=0", with: "cgroupPopulated=1"), expected: binding)
    XCTAssertEqual(running.state, .running); XCTAssertNil(running.exitStatus)
    let unknown = try TranslationReceiptObservation.parse(frame.replacingOccurrences(of: "cgroupPopulated=0", with: "cgroupPopulated=unknown"), expected: binding)
    XCTAssertEqual(unknown.state, .unknown)
  }
  func testPartialUnknownAndMalformedFrames() throws {
    XCTAssertEqual(try TranslationReceiptObservation.parse("ECHOGUIDE-INSPECTION-v1\ncategory=unknown\nEND\n", expected: binding).state, .unknown)
    for invalid in [String(frame.dropLast()), frame + "extra\n", frame.replacingOccurrences(of: "version=1", with: "version=1\nversion=1"), frame.replacingOccurrences(of: "account=echotest", with: "account=wrong"), frame.replacingOccurrences(of: "vm=\(id.uuidString)", with: "vm=\(UUID().uuidString)"), frame.replacingOccurrences(of: "InvocationID=" + String(repeating: "b", count: 32), with: "InvocationID=" + String(repeating: "c", count: 32))] {
      XCTAssertThrowsError(try TranslationReceiptObservation.parse(invalid, expected: binding))
    }
  }
  func testEveryIdentityBindingIsRequired() {
    for key in ["attempt", "vm", "session", "boot"] {
      let changed = frame.replacingOccurrences(of: "\(key)=\(id.uuidString)", with: "\(key)=\(UUID().uuidString)")
      XCTAssertThrowsError(try TranslationReceiptObservation.parse(changed, expected: binding), key)
    }
    for changed in [
      frame.replacingOccurrences(of: "hash=\(binding.hash)", with: "hash=" + String(repeating: "c", count: 64)),
      frame.replacingOccurrences(of: "ControlGroup=/system.slice/", with: "ControlGroup=/wrong/")
    ] {
      XCTAssertThrowsError(try TranslationReceiptObservation.parse(changed, expected: binding))
    }
  }
  func testRemovedLiveMetadataDoesNotProveDrainOrCompletion() throws {
    for changed in [
      frame.replacingOccurrences(of: "LoadState=loaded", with: "LoadState=not-found"),
      frame.replacingOccurrences(of: "InvocationID=" + String(repeating: "b", count: 32), with: "InvocationID="),
      frame.replacingOccurrences(of: "ControlGroup=/system.slice/echoguide-translation-\(id.uuidString).service", with: "ControlGroup="),
      frame.replacingOccurrences(of: "cgroupPopulated=0", with: "cgroupPopulated=unknown")
    ] {
      let result = try TranslationReceiptObservation.parse(changed, expected: binding)
      XCTAssertEqual(result.state, .unknown)
      XCTAssertNil(result.exitStatus)
    }
  }
  func testStartedReceiptRunningFrame() throws {
    var lines = frame.split(separator: "\n").map(String.init)
    lines.removeAll { $0.hasPrefix("result=") || $0.hasPrefix("code=") || $0.hasPrefix("status=") }
    let invocation = lines.firstIndex { $0.hasPrefix("invocation=") }!
    lines.remove(at: invocation)
    lines.insert("receiptState=running", at: 1)
    let running = (lines.joined(separator: "\n") + "\n")
      .replacingOccurrences(of: "ActiveState=inactive", with: "ActiveState=active")
      .replacingOccurrences(of: "SubState=dead", with: "SubState=running")
      .replacingOccurrences(of: "cgroupPopulated=0", with: "cgroupPopulated=1")
    XCTAssertEqual(try TranslationReceiptObservation.parse(running, expected: binding).state, .running)
    for changed in [
      running.replacingOccurrences(of: "cgroupPopulated=1", with: "cgroupPopulated=0"),
      running.replacingOccurrences(of: "ActiveState=active", with: "ActiveState=failed"),
      running.replacingOccurrences(of: "receiptState=running", with: "receiptState=terminal")
    ] {
      XCTAssertThrowsError(try TranslationReceiptObservation.parse(changed, expected: binding))
    }
  }
  func testContradictoryTerminalEvidenceRemainsUnknown() throws {
    for changed in [
      frame.replacingOccurrences(of: "status=0", with: "status=1").replacingOccurrences(of: "ExecMainStatus=0", with: "ExecMainStatus=1"),
      frame.replacingOccurrences(of: "ExecMainStatus=0", with: "ExecMainStatus=1"),
      frame.replacingOccurrences(of: "code=exited", with: "code=killed"),
      frame.replacingOccurrences(of: "SubState=dead", with: "SubState=running")
    ] {
      let observed = try TranslationReceiptObservation.parse(changed, expected: binding)
      XCTAssertEqual(observed.state, .unknown)
      XCTAssertNil(observed.exitStatus)
    }
  }
}
