import XCTest

@testable import EchoGuideCore

private struct UTMFixtureRunner: CommandRunning {
  let result: CommandResult
  let expectedOwnershipID: UUID
  let expectedVMID: UUID?
  let expectedAction: UTMAdapter.LifecycleAction
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTAssertEqual(executable, "/usr/bin/osascript")
    XCTAssertEqual(arguments.count, 4)
    XCTAssertEqual(arguments[0], "-e")
    XCTAssertEqual(arguments[2], expectedOwnershipID.uuidString)
    XCTAssertEqual(arguments[3], expectedVMID?.uuidString ?? "")
    let script = arguments[1]
    XCTAssertTrue(script.contains("notes of candidateConfiguration is ownershipMarker"))
    XCTAssertTrue(script.contains("considering case"))
    XCTAssertTrue(script.contains("Duplicate EchoGuide ownership markers"))
    XCTAssertFalse(script.contains("make new virtual machine"))
    XCTAssertFalse(script.contains("by force"))
    XCTAssertFalse(script.contains("by kill"))
    switch expectedAction {
    case .info:
      XCTAssertFalse(script.contains("start selectedVM"))
      XCTAssertFalse(script.contains("stop selectedVM"))
    case .start:
      XCTAssertTrue(script.contains("start selectedVM"))
      XCTAssertTrue(script.contains("Owned VM binding changed"))
    case .gracefulStop:
      XCTAssertTrue(script.contains("stop selectedVM by request"))
      XCTAssertTrue(script.contains("activeInstallation"))
    }
    return result
  }
}
final class UTMTests: XCTestCase {
  private let app = URL(fileURLWithPath: "/Applications/UTM.app")
  func testReconciliationDoesNotCreateWhenAbsent() async throws {
    let spec = OwnedVMSpecification()
    let runner = UTMFixtureRunner(
      result: .init(stdout: "NONE\n"), expectedOwnershipID: spec.ownershipID, expectedVMID: nil,
      expectedAction: .info)
    let result = try await UTMAdapter(runner: runner, application: app).reconcile(
      specification: spec, registeredVMID: nil)
    XCTAssertEqual(result, .absent)
  }
  func testRecoversOneOwnedUUIDFromCreationIntent() async throws {
    let spec = OwnedVMSpecification()
    let id = UUID()
    let runner = UTMFixtureRunner(
      result: .init(stdout: id.uuidString + "\tapple\tstopped"),
      expectedOwnershipID: spec.ownershipID, expectedVMID: nil, expectedAction: .info)
    let result = try await UTMAdapter(runner: runner, application: app).reconcile(
      specification: spec, registeredVMID: nil)
    guard case .owned(let info) = result else { return XCTFail("Expected owned VM") }
    XCTAssertEqual(info.id, id)
  }
  func testDuplicateOrPermissionFailurePreservesAmbiguity() async throws {
    let spec = OwnedVMSpecification()
    for error in ["Duplicate ownership markers", "Automation denied (-1743)"] {
      let runner = UTMFixtureRunner(
        result: .init(stdout: "", stderr: error, exitCode: 1),
        expectedOwnershipID: spec.ownershipID, expectedVMID: nil, expectedAction: .info)
      do {
        _ = try await UTMAdapter(runner: runner, application: app).reconcile(
          specification: spec, registeredVMID: nil)
        XCTFail("Expected stopped operation")
      } catch {}
    }
  }
  func testRecordedUUIDCannotAdoptOtherOwnedVM() async throws {
    let spec = OwnedVMSpecification()
    let recorded = UUID()
    let runner = UTMFixtureRunner(
      result: .init(stdout: UUID().uuidString + "\tapple\tstopped"),
      expectedOwnershipID: spec.ownershipID, expectedVMID: recorded, expectedAction: .info)
    do {
      _ = try await UTMAdapter(runner: runner, application: app).reconcile(
        specification: spec, registeredVMID: recorded)
      XCTFail("Expected binding mismatch")
    } catch {}
  }
  func testStartRequiresBoundOwnershipAndReturnsObservedState() async throws {
    let spec = OwnedVMSpecification()
    let id = UUID()
    let runner = UTMFixtureRunner(
      result: .init(stdout: id.uuidString + "\tapple\tstarting"),
      expectedOwnershipID: spec.ownershipID, expectedVMID: id, expectedAction: .start)
    let info = try await UTMAdapter(runner: runner, application: app).start(
      specification: spec, vmID: id)
    XCTAssertEqual(info.state, .starting)
  }
  func testGracefulShutdownDoesNotClaimStoppedWhenIgnored() async throws {
    let spec = OwnedVMSpecification()
    let id = UUID()
    let runner = UTMFixtureRunner(
      result: .init(stdout: id.uuidString + "\tapple\tstarted"),
      expectedOwnershipID: spec.ownershipID, expectedVMID: id, expectedAction: .gracefulStop)
    let info = try await UTMAdapter(runner: runner, application: app).requestGracefulStop(
      specification: spec, vmID: id)
    XCTAssertEqual(info.state, .started)
  }
  func testRejectsMalformedOrMultipleRowsAndWrongBackend() async throws {
    let spec = OwnedVMSpecification()
    let id = UUID()
    for text in [
      id.uuidString + "\tqemu\tstopped", id.uuidString + "\tapple\tunknown",
      id.uuidString + "\tapple\tstopped\n" + UUID().uuidString + "\tapple\tstopped",
    ] {
      let runner = UTMFixtureRunner(
        result: .init(stdout: text), expectedOwnershipID: spec.ownershipID, expectedVMID: id,
        expectedAction: .info)
      do {
        _ = try await UTMAdapter(runner: runner, application: app).info(
          specification: spec, vmID: id)
        XCTFail("Expected invalid info rejection")
      } catch {}
    }
  }
}

private struct SerialFixtureRunner: CommandRunning {
  let owner: UUID
  let vm: UUID
  let output: String
  let exitCode: Int32
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    XCTAssertEqual(executable, "/usr/bin/osascript")
    XCTAssertEqual(arguments[2], owner.uuidString)
    XCTAssertEqual(arguments[3], vm.uuidString)
    XCTAssertTrue(arguments[1].contains("serial ports of selectedVM"))
    XCTAssertTrue(arguments[1].contains("interface of guestPort is not ptty"))
    XCTAssertTrue(arguments[1].contains("count of guestPorts is not 1"))
    XCTAssertTrue(arguments[1].contains("Owned VM binding changed"))
    XCTAssertFalse(arguments[1].contains("start selectedVM"))
    XCTAssertFalse(arguments[1].contains("stop selectedVM"))
    return .init(
      stdout: output, stderr: exitCode == 0 ? "" : "Serial unavailable", exitCode: exitCode)
  }
}
extension UTMTests {
  func testSerialChannelBoundToOwnershipAndUUID() async throws {
    let spec = OwnedVMSpecification()
    let vm = UUID()
    let runner = SerialFixtureRunner(
      owner: spec.ownershipID, vm: vm, output: vm.uuidString + "\t0\t/dev/ttys008", exitCode: 0)
    let channel = try await UTMAdapter(
      runner: runner, application: URL(fileURLWithPath: "/Applications/UTM.app")
    ).serialChannel(specification: spec, vmID: vm)
    XCTAssertEqual(channel.vmID, vm)
    XCTAssertEqual(channel.portID, 0)
    XCTAssertEqual(channel.path, "/dev/ttys008")
  }
  func testSerialChannelRejectsWrongBindingPathsAndAmbiguity() async throws {
    let spec = OwnedVMSpecification()
    let vm = UUID()
    for output in [
      "NONE", UUID().uuidString + "\t0\t/dev/ttys008", vm.uuidString + "\t1\t/dev/ttys008",
      vm.uuidString + "\t0\t/tmp/file",
      vm.uuidString + "\t0\t/dev/ttys008\n" + vm.uuidString + "\t0\t/dev/ttys009",
    ] {
      let runner = SerialFixtureRunner(owner: spec.ownershipID, vm: vm, output: output, exitCode: 0)
      do {
        _ = try await UTMAdapter(
          runner: runner, application: URL(fileURLWithPath: "/Applications/UTM.app")
        ).serialChannel(specification: spec, vmID: vm)
        XCTFail("Expected serial discovery rejection")
      } catch {}
    }
  }
  func testSerialChannelUnavailableDoesNotStartVM() async throws {
    let spec = OwnedVMSpecification()
    let vm = UUID()
    let runner = SerialFixtureRunner(owner: spec.ownershipID, vm: vm, output: "", exitCode: 1)
    do {
      _ = try await UTMAdapter(
        runner: runner, application: URL(fileURLWithPath: "/Applications/UTM.app")
      ).serialChannel(specification: spec, vmID: vm)
      XCTFail("Expected unavailable channel")
    } catch {}
  }
}
