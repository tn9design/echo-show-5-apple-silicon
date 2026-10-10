import Foundation

public struct ADBDevice: Codable, Sendable, Equatable, Identifiable {
  public let serial: String
  public let state: String
  public let product: String?
  public var id: String { serial }
  public var isRecoveryCandidate: Bool { state == "recovery" && product == "omni_checkers" }
  public init(serial: String, state: String, product: String? = nil) {
    self.serial = serial
    self.state = state
    self.product = product
  }
}
public struct RecoveryDeviceDiscovery: Sendable {
  public let runner: any CommandRunning
  public let adbPath: String
  public init(runner: any CommandRunning, adbPath: String) {
    self.runner = runner
    self.adbPath = adbPath
  }
  public static func parse(_ output: String) throws -> [ADBDevice] {
    var results: [ADBDevice] = []
    var sawHeader = false
    for raw in output.split(separator: "\n") {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line == "List of devices attached" {
        guard !sawHeader else { throw GuideError.stopped("Duplicate ADB device-list header") }
        sawHeader = true
        continue
      }
      guard sawHeader else { throw GuideError.stopped("Unexpected ADB device-list output") }
      let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
      guard fields.count >= 2,
        fields[0].range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil
      else { throw GuideError.stopped("Malformed ADB device row") }
      guard ["device", "recovery", "offline", "unauthorized", "sideload"].contains(fields[1]) else {
        throw GuideError.stopped("Unsupported or ambiguous ADB state")
      }
      let products = fields.dropFirst(2).filter { $0.hasPrefix("product:") }.map {
        String($0.dropFirst(8))
      }
      guard products.count <= 1, !results.contains(where: { $0.serial == fields[0] }) else {
        throw GuideError.stopped("Ambiguous ADB device identity")
      }
      results.append(ADBDevice(serial: fields[0], state: fields[1], product: products.first))
    }
    guard sawHeader else { throw GuideError.stopped("ADB did not return a complete device list") }
    return results
  }
  public func devices() async throws -> [ADBDevice] {
    let r = try await runner.run(executable: adbPath, arguments: ["devices", "-l"])
    guard r.exitCode == 0 else { throw GuideError.stopped("ADB device enumeration failed") }
    return try Self.parse(r.stdout)
  }
}
