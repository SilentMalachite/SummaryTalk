import XCTest
@testable import SummaryTalk

@MainActor
final class IPtalkManagerTests: XCTestCase {
    func testStartListeningSetsConnected() async {
        let manager = IPtalkManager()
        manager.channel = 1
        manager.handleName = "TestStart"

        await manager.startListening()
        defer { manager.stopListening() }

        XCTAssertTrue(manager.isConnected, "startListening should flip isConnected to true on success")
        XCTAssertNil(manager.errorMessage, "no error expected on the happy path")
    }

    func testStopListeningClearsConnectedAndMembers() async {
        let manager = IPtalkManager()
        manager.channel = 1
        manager.handleName = "TestStop"

        await manager.startListening()
        XCTAssertTrue(manager.isConnected)

        manager.stopListening()

        XCTAssertFalse(manager.isConnected, "stopListening should flip isConnected to false")
        XCTAssertTrue(manager.members.isEmpty, "stopListening should clear discovered members")
    }

    func testPortConflictRollsBackAndSetsError() async {
        let first = IPtalkManager()
        first.channel = 1
        first.handleName = "Holder"
        await first.startListening()
        defer { first.stopListening() }
        XCTAssertTrue(first.isConnected, "first manager must hold the channel-1 ports")

        let second = IPtalkManager()
        second.channel = 1
        second.handleName = "Conflict"
        await second.startListening()

        XCTAssertFalse(second.isConnected, "second startListening on same channel must fail to fully connect")
        XCTAssertNotNil(second.errorMessage, "port-in-use must surface via errorMessage")
        XCTAssertTrue(second.errorMessage?.contains("使用中") ?? false, "error message must mention port-in-use")
    }

    func testStartListeningTwiceIsNoOp() async {
        let manager = IPtalkManager()
        manager.channel = 1
        await manager.startListening()
        defer { manager.stopListening() }
        XCTAssertTrue(manager.isConnected)

        // Calling again while already connected should not throw or change state.
        await manager.startListening()
        XCTAssertTrue(manager.isConnected, "still connected after second call")
        XCTAssertNil(manager.errorMessage)
    }
}
