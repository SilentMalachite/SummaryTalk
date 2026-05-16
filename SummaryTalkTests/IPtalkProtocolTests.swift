import XCTest
@testable import SummaryTalk

final class IPtalkProtocolTests: XCTestCase {
    func testPortsForChannel1() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 1), 6711)
        XCTAssertEqual(IPtalkProtocol.port(role: .monitor, channel: 1), 6712)
        XCTAssertEqual(IPtalkProtocol.port(role: .correction, channel: 1), 6713)
        XCTAssertEqual(IPtalkProtocol.port(role: .memberReply, channel: 1), 6718)
        XCTAssertEqual(IPtalkProtocol.port(role: .memberBroadcast, channel: 1), 6722)
        XCTAssertEqual(IPtalkProtocol.port(role: .undo, channel: 1), 6723)
    }

    func testChannel2AddsHundred() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 2), 6811)
        XCTAssertEqual(IPtalkProtocol.port(role: .undo, channel: 2), 6823)
    }

    func testChannel9AddsEightHundred() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 9), 7511)
        XCTAssertEqual(IPtalkProtocol.port(role: .memberBroadcast, channel: 9), 7522)
    }

    func testChannelClampedToValidRange() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 0), 6711, "channel < 1 clamps to 1")
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 10), 7511, "channel > 9 clamps to 9")
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: -5), 6711)
    }
}
