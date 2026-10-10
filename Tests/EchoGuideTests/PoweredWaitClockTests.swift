import XCTest
@testable import EchoGuideCore

final class PoweredWaitClockTests: XCTestCase {
  func testAlreadyCancelledCallerCannotSkipPoweredTicks() async throws {
    let clock = PoweredWaitClock(testOnlyTickNanoseconds: 10_000_000)
    let start = ContinuousClock.now
    let worker = Task {
      // Yield until parent cancellation is observed, then enter powered waiting.
      while !Task.isCancelled { await Task.yield() }
      for _ in 0..<3 { try await clock.poweredWaitSecond() }
      return Task.isCancelled
    }
    worker.cancel()
    let remainedCancelled = try await worker.value
    XCTAssertTrue(remainedCancelled)
    XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(30))
  }
  func testCancellationDuringOwnedTimerCannotShortenIt() async throws {
    let clock = PoweredWaitClock(testOnlyTickNanoseconds: 40_000_000)
    let start = ContinuousClock.now
    let worker = Task { try await clock.poweredWaitSecond() }
    try await Task.sleep(nanoseconds: 5_000_000)
    worker.cancel()
    try await worker.value
    XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(40))
  }
  func testOrdinaryRetrySleepRetainsCancellation() async throws {
    let clock = PoweredWaitClock()
    let worker = Task {
      while !Task.isCancelled { await Task.yield() }
      try await clock.sleep(seconds: 2)
    }
    worker.cancel()
    do { try await worker.value; XCTFail("Retry sleep ignored cancellation") }
    catch is CancellationError {} catch { XCTFail("Wrong failure") }
  }
}
