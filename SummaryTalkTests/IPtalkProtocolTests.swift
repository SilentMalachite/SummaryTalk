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

    func testMemberDiscoveryRequestContainsHandleName() {
        let data = IPtalkProtocol.memberDiscoveryRequest(handleName: "テスター")
        let decoded = IPtalkProtocol.decode(data)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), "テスター")
    }

    func testMemberDiscoveryReplyContainsHandleName() {
        let data = IPtalkProtocol.memberDiscoveryReply(handleName: "サマライズ")
        let decoded = IPtalkProtocol.decode(data)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), "サマライズ")
    }

    func testMemberDiscoveryRequestHandlesEmptyHandle() {
        let data = IPtalkProtocol.memberDiscoveryRequest(handleName: "")
        XCTAssertFalse(data.isEmpty, "must still send something so peers can register our IP")
    }

    func testAllRolesYieldDistinctPortsPerChannel() {
        for channel in 1...9 {
            let ports = IPtalkPortRole.allCases.map { IPtalkProtocol.port(role: $0, channel: channel) }
            XCTAssertEqual(Set(ports).count, ports.count, "channel \(channel): roles must map to unique ports")
        }
    }

    func testChannelsDoNotOverlapForSameRole() {
        let displayPorts = (1...9).map { IPtalkProtocol.port(role: .display, channel: $0) }
        XCTAssertEqual(displayPorts, [6711, 6811, 6911, 7011, 7111, 7211, 7311, 7411, 7511])
        XCTAssertEqual(Set(displayPorts).count, displayPorts.count)
    }

    func testDecodePreservesTrailingLF() {
        let encoded = IPtalkProtocol.encode(line: "hi")
        let decoded = IPtalkProtocol.decode(encoded)
        XCTAssertEqual(decoded, "hi\n", "decode is byte-faithful — callers strip the LF themselves")
    }

    func testEncodeShiftJISBytesForKnownKanji() {
        // 「あ」 = 0x82 0xA0 in Shift-JIS — guards against accidental encoding swap (e.g. to UTF-8).
        let data = IPtalkProtocol.encode(line: "あ")
        XCTAssertEqual(data, Data([0x82, 0xA0, 0x0a]))
    }
}
