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

    /// Two IPtalkManagers on the same channel coexist instead of conflicting because
    /// `NWParameters.udp.allowLocalEndpointReuse = true` is set on every listener (so the
    /// app can re-bind ports after a crash/restart without waiting on the OS). As a side
    /// effect, the spec §6 "ポート XXXX が使用中です" rollback path is unreachable in
    /// Phase 1 — verified by this test. If a future change tightens the binding (e.g.
    /// drops the reuse flag), this test should be replaced with the port-conflict
    /// assertions the spec originally described.
    func testSameChannelManagersCoexistDueToPortReuse() async {
        let first = IPtalkManager()
        first.channel = 1
        first.handleName = "Holder"
        await first.startListening()
        defer { first.stopListening() }
        XCTAssertTrue(first.isConnected)

        let second = IPtalkManager()
        second.channel = 1
        second.handleName = "Coexister"
        await second.startListening()
        defer { second.stopListening() }

        XCTAssertTrue(second.isConnected, "with allowLocalEndpointReuse, the second listener binds successfully")
        XCTAssertNil(second.errorMessage, "no error surfaces because the bind didn't actually fail")
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

    func testInitialStateIsIdle() {
        let manager = IPtalkManager()
        XCTAssertEqual(manager.channel, 1, "default channel is 1")
        XCTAssertEqual(manager.handleName, "")
        XCTAssertFalse(manager.isConnected)
        XCTAssertTrue(manager.members.isEmpty)
        XCTAssertTrue(manager.receivedLines.isEmpty)
        XCTAssertEqual(manager.receivedText, "")
        XCTAssertNil(manager.errorMessage)
    }

    func testStopListeningWhenNeverStartedIsSafe() {
        let manager = IPtalkManager()
        manager.stopListening()
        XCTAssertFalse(manager.isConnected)
        XCTAssertTrue(manager.members.isEmpty)
        XCTAssertNil(manager.errorMessage)
    }

    func testSendBeforeStartIsNoOpAndDoesNotSetError() {
        let manager = IPtalkManager()
        manager.channel = 1

        // All three send paths are guarded by `isConnected` — must silently no-op.
        manager.sendDisplayLine("これは送られない")
        manager.sendCorrection("これも送られない")
        manager.sendUndo()

        XCTAssertNil(manager.errorMessage, "unconnected sends are silent — they do not surface an error")
        XCTAssertFalse(manager.isConnected)
    }

    func testStartListeningClearsExistingErrorMessage() async {
        let manager = IPtalkManager()
        manager.channel = 1
        manager.errorMessage = "前回の残骸"
        await manager.startListening()
        defer { manager.stopListening() }

        XCTAssertNil(manager.errorMessage, "startListening clears stale error message at the top")
        XCTAssertTrue(manager.isConnected)
    }

    func testClearReceivedTextWhenEmptyIsSafe() {
        let manager = IPtalkManager()
        manager.clearReceivedText()
        XCTAssertEqual(manager.receivedText, "")
    }
}
