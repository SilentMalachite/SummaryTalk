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
        manager.channel = 2
        manager.handleName = "TestStop"

        await manager.startListening()
        XCTAssertTrue(manager.isConnected)

        manager.stopListening()

        XCTAssertFalse(manager.isConnected, "stopListening should flip isConnected to false")
        XCTAssertTrue(manager.members.isEmpty, "stopListening should clear discovered members")
    }

    /// Listener init can succeed with `allowLocalEndpointReuse`, but `.ready` still
    /// fails for some ports (notably member-broadcast 6722) when another process
    /// already holds the channel. Waiting for `.ready` therefore surfaces the spec §6
    /// rollback that used to be unreachable at `NWListener` construction.
    func testSameChannelSecondManagerRollsBackOnPortConflict() async {
        let first = IPtalkManager()
        first.channel = 3
        first.handleName = "Holder"
        await first.startListening()
        defer { first.stopListening() }
        XCTAssertTrue(first.isConnected)

        let second = IPtalkManager()
        second.channel = 3
        second.handleName = "Coexister"
        await second.startListening()
        defer { second.stopListening() }

        XCTAssertFalse(second.isConnected, "a port-in-use failure during ready must not leave isConnected true")
        XCTAssertNotNil(second.errorMessage)
        XCTAssertTrue(first.isConnected, "the first manager must stay connected after the second rolls back")
    }

    func testConcurrentStartListeningDoesNotOverwriteStartup() async {
        let manager = IPtalkManager()
        manager.channel = 4
        manager.handleName = "Concurrent"

        async let first = manager.startListening()
        async let second = manager.startListening()
        _ = await (first, second)
        defer { manager.stopListening() }

        XCTAssertTrue(manager.isConnected, "exactly one in-flight start should complete")
        XCTAssertNil(manager.errorMessage)
    }

    func testStartListeningTwiceIsNoOp() async {
        let manager = IPtalkManager()
        manager.channel = 5
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
        XCTAssertFalse(manager.isConnecting)
        XCTAssertTrue(manager.members.isEmpty)
        XCTAssertTrue(manager.receivedLines.isEmpty)
        XCTAssertEqual(manager.receivedText, "")
        XCTAssertNil(manager.errorMessage)
    }

    func testStaleStartupTimeoutDoesNotSetError() async {
        let manager = IPtalkManager()
        manager.channel = 6
        await manager.startListening()
        defer { manager.stopListening() }

        XCTAssertTrue(manager.isConnected)
        manager.applyStartupTimeout(generation: 0)
        XCTAssertTrue(manager.isConnected)
        XCTAssertNil(manager.errorMessage)
    }

    func testReconnectIgnoresPreviousTimeoutTask() async throws {
        let manager = IPtalkManager()
        manager.channel = 7
        manager.startupTimeoutNanoseconds = 200_000_000
        await manager.startListening()
        manager.stopListening()

        await manager.startListening()
        defer { manager.stopListening() }

        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertTrue(manager.isConnected)
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
        manager.channel = 8
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
