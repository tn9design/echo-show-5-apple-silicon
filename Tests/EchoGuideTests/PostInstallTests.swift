import XCTest
@testable import EchoGuideCore

private struct PostInstallRecoveryFixture: BinaryCommandRunning {
  func run(executable: String, arguments: [String]) async throws -> CommandResult {
    .init(stdout: arguments.contains("ro.product.device") ? "checkers" : "3.7.0_9-0")
  }
  func runToFile(executable: String, arguments: [String], destination: URL) async throws -> CommandResult {
    throw GuideError.stopped("No partition transfers in this fixture")
  }
}

final class PostInstallTests: XCTestCase {
  private func engine() throws -> WorkflowEngine {
    try WorkflowEngine(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  }
  func testObservationsRejectBeforeInstallation() throws {
    let engine = try engine(); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    for phase in [Phase.setup, .recovery, .backedUp, .inspectionRequired] {
      try engine.store.transaction { $0.phase = phase }
      XCTAssertThrowsError(try engine.recordPostInstallObservation(check: .wifi, outcome: .working))
      XCTAssertNil(try engine.status().postInstallObservations)
    }
  }
  func testIndividualOutcomesPersistWithoutImplyingOtherChecksOrStartup() throws {
    let engine = try engine(); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction { $0.phase = .installed }
    try engine.recordPostInstallObservation(check: .wifi, outcome: .working)
    try engine.recordPostInstallObservation(check: .camera, outcome: .issueObserved)
    let reopened = try WorkflowEngine(root: engine.store.root)
    let state = try reopened.status()
    XCTAssertEqual(state.postInstallObservations?.count, 2)
    XCTAssertEqual(state.postInstallObservations?.first(where: { $0.check == .wifi })?.outcome, .working)
    XCTAssertEqual(state.postInstallObservations?.first(where: { $0.check == .camera })?.outcome, .issueObserved)
    XCTAssertTrue(state.postInstallObservations?.allSatisfy { $0.source == "personReported" } == true)
    XCTAssertNil(state.postInstallObservations?.first(where: { $0.check == .microphone }))
    XCTAssertFalse(state.startupConfirmed)
    XCTAssertEqual(state.phase, .installed)
  }
  func testChangingOrClearingOneOutcomePreservesOtherOutcomesAfterStartup() throws {
    let engine = try engine(); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    try engine.store.transaction { $0.phase = .installed }
    try engine.recordPostInstallObservation(check: .audio, outcome: .working)
    try engine.recordPostInstallObservation(check: .wifi, outcome: .working)
    try engine.confirmStartup()
    try engine.recordPostInstallObservation(check: .audio, outcome: .unableToCheck)
    XCTAssertEqual(try engine.status().postInstallObservations?.filter { $0.check == .audio }.count, 1)
    try engine.recordPostInstallObservation(check: .audio, outcome: .notChecked)
    XCTAssertEqual(try engine.status().postInstallObservations?.map(\.check), [.wifi])
    XCTAssertTrue(try engine.status().startupConfirmed)
  }
  func testRecoveryWorkflowClearsPreviousInstallationObservations() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = try WorkflowEngine(root: root, runner: PostInstallRecoveryFixture())
    try engine.store.transaction {
      $0.phase = .installed
      $0.device = DeviceIdentity(serial: "fixture", product: "CHECKERS", lkBuild: "fixture")
    }
    try engine.recordPostInstallObservation(check: .wifi, outcome: .working)
    try engine.confirmStartup()
    try await engine.verifyRecovery(adb: URL(fileURLWithPath: "/fixture/adb"), serial: "fixture")
    XCTAssertNil(try engine.status().postInstallObservations)
    XCTAssertFalse(try engine.status().startupConfirmed)
  }
  func testLegacySessionHasNoInventedChecklist() throws {
    let engine = try engine(); defer { try? FileManager.default.removeItem(at: engine.store.root) }
    let encoded = try JSONEncoder().encode(engine.status())
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "postInstallObservations")
    let legacy = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(legacy.postInstallObservations)
  }
}
