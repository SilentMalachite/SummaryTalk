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

    func testEncodeAsciiAddsLF() {
        let data = IPtalkProtocol.encode(line: "hello")
        XCTAssertEqual(data, Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a]))
    }

    func testEncodeDoesNotDoubleLFWhenAlreadyTerminated() {
        let data = IPtalkProtocol.encode(line: "hello\n")
        XCTAssertEqual(data, Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a]))
    }

    func testEncodeEmptyStringIsJustLF() {
        XCTAssertEqual(IPtalkProtocol.encode(line: ""), Data([0x0a]))
    }

    func testEncodeKanjiRoundTrip() {
        let original = "こんにちは"
        let encoded = IPtalkProtocol.encode(line: original)
        let decoded = IPtalkProtocol.decode(encoded)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), original)
    }

    func testEncodeHalfwidthKanaRoundTrip() {
        let original = "ｶﾀｶﾅ"
        let encoded = IPtalkProtocol.encode(line: original)
        let decoded = IPtalkProtocol.decode(encoded)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), original)
    }

    func testEncodeEmojiFallsBackLossy() {
        // Emoji has no Shift-JIS representation; encode must not crash and must produce
        // bytes that decode back to *something* (lossy '?' replacement is acceptable).
        let encoded = IPtalkProtocol.encode(line: "abc😀def")
        XCTAssertFalse(encoded.isEmpty)
        let decoded = IPtalkProtocol.decode(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.contains("abc"))
        XCTAssertTrue(decoded!.contains("def"))
    }

    func testDecodeEmptyDataReturnsEmptyString() {
        XCTAssertEqual(IPtalkProtocol.decode(Data()), "")
    }
}
