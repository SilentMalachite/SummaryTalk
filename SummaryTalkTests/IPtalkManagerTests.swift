import XCTest
@testable import SummaryTalk

@MainActor
final class IPtalkManagerTests: XCTestCase {
    func testCreatePacketContainsHeaderAndLength() throws {
        let manager = IPtalkManager(port: 15000)
        let text = "テスト送信"
        let packet = manager.createIPtalkPacket(text: text)

        XCTAssertGreaterThanOrEqual(packet.count, 8, "Packet should contain header and length")

        let commandData = packet.prefix(4)
        XCTAssertEqual(String(data: commandData, encoding: .ascii), "TEXT")

        let lengthData = packet.subdata(in: 4..<8)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let payload = packet.subdata(in: 8..<packet.count)

        guard let expected = text.data(using: .shiftJIS) else {
            XCTFail("Shift-JIS encoding failed")
            return
        }

        XCTAssertEqual(length, UInt32(expected.count))
        XCTAssertEqual(payload, expected)
    }

    func testParsePacketReturnsOriginalText() throws {
        let manager = IPtalkManager(port: 15000)
        let original = "行1\n行2"
        let packet = manager.createIPtalkPacket(text: original)

        let parsed = manager.parseIPtalkPacket(data: packet)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.command, "TEXT")
        XCTAssertEqual(parsed?.text, original)
    }

    func testParsePacketRejectsTooShortData() {
        let manager = IPtalkManager(port: 15000)
        let shortData = Data([0x00, 0x01, 0x02])
        XCTAssertNil(manager.parseIPtalkPacket(data: shortData))
    }

    func testUpdatePortChangesPortValue() {
        let manager = IPtalkManager(port: 15000)
        manager.updatePort(16000)
        XCTAssertEqual(manager.port, 16000)
    }
}
