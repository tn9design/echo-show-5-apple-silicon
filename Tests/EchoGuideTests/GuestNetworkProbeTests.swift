import XCTest
@testable import EchoGuideCore

final class GuestNetworkProbeTests: XCTestCase {
  func testOnlyPrivateIPv4Accepted() {
    for address in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.64.7"] {
      XCTAssertTrue(GuestNetworkProbe.validPrivateAddress(address))
    }
    for address in ["127.0.0.1", "172.15.0.1", "172.32.0.1", "8.8.8.8", "::1", "guest.local", "192.168.1.999", "192.168.1.1:22", "192.168.1.1\n", "192.168.1"] {
      XCTAssertFalse(GuestNetworkProbe.validPrivateAddress(address))
    }
  }
  func testWaitingDoesNotBecomeSuccessOrPrivacyDenial() {
    XCTAssertNil(GuestNetworkProbe.result(for: .waiting))
    XCTAssertEqual(GuestNetworkProbe.result(for: .localNetworkDenied), .localNetworkDenied)
    XCTAssertEqual(GuestNetworkProbe.result(for: .ready), .reachable)
    XCTAssertEqual(GuestNetworkProbe.result(for: .failed), .unavailable)
    XCTAssertEqual(GuestNetworkProbe.result(for: .deadline), .unavailable)
    XCTAssertEqual(GuestNetworkProbe.result(for: .cancelled), .cancelled)
  }
  func testInvalidAddressReturnsWithoutConnecting() async {
    let result = await GuestNetworkProbe().probe(address: "public.example.com")
    XCTAssertEqual(result, .unavailable)
  }
}
