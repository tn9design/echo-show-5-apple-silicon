import Foundation
import Network

public enum GuestNetworkProbeResult: String, Codable, Sendable, Equatable {
  case reachable, localNetworkDenied, unavailable, cancelled
}

/// A diagnostic TCP connection to the saved private guest address, port 22 only.
/// It sends no application bytes and does not establish SSH or device identity.
public protocol GuestNetworkProbing: Sendable {
  func probe(address: String) async -> GuestNetworkProbeResult
}

public struct GuestNetworkProbe: GuestNetworkProbing {
  public init() {}
  public func probe(address: String) async -> GuestNetworkProbeResult {
    guard Self.validPrivateAddress(address) else { return .unavailable }
    let coordinator = GuestNetworkProbeCoordinator(address: address)
    return await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { coordinator.start($0) }
    }, onCancel: { coordinator.finish(.cancelled) })
  }
  static func validPrivateAddress(_ address: String) -> Bool {
    let parts = address.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, IPv4Address(address) != nil else { return false }
    let octets = parts.compactMap { part -> Int? in
      guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
        let value = Int(part), (0...255).contains(value) else { return nil }
      return value
    }
    guard octets.count == 4 else { return false }
    return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
      || (octets[0] == 192 && octets[1] == 168)
  }
  static func result(for event: GuestNetworkProbeEvent) -> GuestNetworkProbeResult? {
    switch event {
    case .ready: return .reachable
    case .localNetworkDenied: return .localNetworkDenied
    case .failed, .deadline: return .unavailable
    case .cancelled: return .cancelled
    case .waiting: return nil
    }
  }
}
enum GuestNetworkProbeEvent: Sendable { case ready, localNetworkDenied, failed, deadline, cancelled, waiting }

/// All mutable state is protected by lock; callbacks and cancellation may race.
private final class GuestNetworkProbeCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "org.echoguide.guest-network-probe")
  private var continuation: CheckedContinuation<GuestNetworkProbeResult, Never>?
  private var terminal: GuestNetworkProbeResult?
  private var deadline: DispatchWorkItem?
  init(address: String) {
    connection = NWConnection(host: NWEndpoint.Host(address), port: 22, using: .tcp)
  }
  func start(_ continuation: CheckedContinuation<GuestNetworkProbeResult, Never>) {
    lock.lock()
    if let terminal { lock.unlock(); continuation.resume(returning: terminal); return }
    self.continuation = continuation
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      let event: GuestNetworkProbeEvent
      switch state {
      case .ready: event = .ready
      case .waiting:
        event = self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .localNetworkDenied : .waiting
      case .failed:
        event = self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied ? .localNetworkDenied : .failed
      case .cancelled: event = .cancelled
      default: return
      }
      if let result = GuestNetworkProbe.result(for: event) { self.finish(result) }
    }
    let timeout = DispatchWorkItem { [weak self] in self?.finish(.unavailable) }
    deadline = timeout
    queue.asyncAfter(deadline: .now() + 10, execute: timeout)
    connection.start(queue: queue)
    lock.unlock()
  }
  func finish(_ result: GuestNetworkProbeResult) {
    lock.lock()
    guard terminal == nil else { lock.unlock(); return }
    terminal = result
    let continuation = self.continuation; self.continuation = nil
    deadline?.cancel(); deadline = nil
    connection.stateUpdateHandler = nil
    connection.cancel()
    lock.unlock()
    continuation?.resume(returning: result)
  }
}
