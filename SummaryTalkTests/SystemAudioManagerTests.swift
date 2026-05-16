import XCTest
@testable import SummaryTalk

private struct FakeApp: RunningApplicationLike {
    let processID: pid_t
    let applicationName: String
    let bundleIdentifier: String
}

final class SystemAudioAppChoiceTests: XCTestCase {
    func testWholeDisplayIsAlwaysFirstAndOnlyEntryWhenAppsEmpty() {
        let result = makeChoices(from: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.choice, .wholeDisplay)
        XCTAssertEqual(result.first?.displayName, "ディスプレイ全体（すべてのシステム音声）")
    }

    func testWholeDisplayIsFirstWhenAppsPresent() {
        let apps = [FakeApp(processID: 10, applicationName: "Zoom", bundleIdentifier: "us.zoom.xos")]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].choice, .wholeDisplay)
        XCTAssertEqual(result[1].choice, .app(processID: 10))
        XCTAssertEqual(result[1].displayName, "Zoom")
    }

    func testDuplicateProcessIDsAreNormalizedToFirstOccurrence() {
        let apps = [
            FakeApp(processID: 100, applicationName: "Zoom", bundleIdentifier: "us.zoom"),
            FakeApp(processID: 100, applicationName: "Zoom Helper", bundleIdentifier: "us.zoom.helper")
        ]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].choice, .app(processID: 100))
        XCTAssertEqual(result[1].displayName, "Zoom")
    }

    func testEmptyApplicationNameFallsBackToBundleIdentifier() {
        let apps = [FakeApp(processID: 200, applicationName: "", bundleIdentifier: "com.example.app")]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result[1].displayName, "com.example.app")
    }

    func testBothNamesEmptyFallsBackToUnknownWithPid() {
        let apps = [FakeApp(processID: 300, applicationName: "", bundleIdentifier: "")]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result[1].displayName, "不明なアプリ (PID 300)")
    }
}

@MainActor
final class SystemAudioManagerTests: XCTestCase {
    func testRefreshSetsPermissionDeniedWhenPreflightFails() async {
        var requestCalled = false
        let manager = SystemAudioManager(
            permissionCheck: { false },
            requestPermission: { requestCalled = true }
        )

        await manager.refreshAvailableApps()

        XCTAssertEqual(manager.lastErrorKind, .permissionDenied)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.isRefreshing, "refresh完了後は isRefreshing が false に戻る")
        XCTAssertTrue(requestCalled, "preflight 失敗時は requestPermission が呼ばれる")
        XCTAssertTrue(manager.availableApps.isEmpty)
    }

    func testStartCapturingSetsPermissionDeniedAndDoesNotPrompt() async {
        var requestCalled = false
        let manager = SystemAudioManager(
            permissionCheck: { false },
            requestPermission: { requestCalled = true }
        )

        await manager.startCapturing()

        XCTAssertEqual(manager.lastErrorKind, .permissionDenied)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.isCapturing)
        XCTAssertFalse(requestCalled, "startCapturing は preflight のみで requestPermission を呼ばない")
    }
}
