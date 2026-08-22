import XCTest
import AVFoundation
import CoreMedia
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

    func testMultipleDistinctAppsPreserveInputOrder() {
        let apps = [
            FakeApp(processID: 1, applicationName: "Slack", bundleIdentifier: "com.slack"),
            FakeApp(processID: 2, applicationName: "Teams", bundleIdentifier: "com.microsoft.teams"),
            FakeApp(processID: 3, applicationName: "Zoom",  bundleIdentifier: "us.zoom.xos")
        ]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result.map(\.choice),
                       [.wholeDisplay, .app(processID: 1), .app(processID: 2), .app(processID: 3)])
        XCTAssertEqual(result.dropFirst().map(\.displayName), ["Slack", "Teams", "Zoom"])
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

    func testInitialStateIsIdle() {
        let manager = SystemAudioManager(permissionCheck: { true }, requestPermission: {})
        XCTAssertFalse(manager.isCapturing)
        XCTAssertFalse(manager.isRefreshing)
        XCTAssertNil(manager.errorMessage)
        XCTAssertNil(manager.lastErrorKind)
        XCTAssertTrue(manager.availableApps.isEmpty)
        XCTAssertNil(manager.selectedApp)
        XCTAssertNil(manager.audioBufferHandler)
    }

    func testStopCapturingWhenNotCapturingIsNoOp() async {
        let manager = SystemAudioManager(permissionCheck: { true }, requestPermission: {})
        // Preset error to confirm stopCapturing leaves it untouched when it short-circuits.
        manager.errorMessage = "前回のエラー"
        manager.lastErrorKind = .captureFailed

        await manager.stopCapturing()

        XCTAssertFalse(manager.isCapturing)
        XCTAssertEqual(manager.errorMessage, "前回のエラー",
                       "stopCapturing returns early when !isCapturing — must not touch state")
        XCTAssertEqual(manager.lastErrorKind, .captureFailed)
    }

    func testRefreshAvailableAppsTwiceDeniedRequestsPermissionEachTime() async {
        var requestCount = 0
        let manager = SystemAudioManager(
            permissionCheck: { false },
            requestPermission: { requestCount += 1 }
        )

        await manager.refreshAvailableApps()
        await manager.refreshAvailableApps()

        XCTAssertEqual(requestCount, 2, "denial path re-prompts on every refresh attempt")
        XCTAssertEqual(manager.lastErrorKind, .permissionDenied)
    }

    func testSystemAudioErrorKindEquatability() {
        XCTAssertEqual(SystemAudioErrorKind.permissionDenied, .permissionDenied)
        XCTAssertNotEqual(SystemAudioErrorKind.permissionDenied, .listingFailed)
        XCTAssertNotEqual(SystemAudioErrorKind.captureFailed, .listingFailed)
    }
}


/// Collects buffers handed to the `@Sendable` output handler.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    var all: [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return buffers
    }
}

final class AudioStreamOutputTests: XCTestCase {
    private func makeTargetFormat() throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
    }

    /// Builds a float32 non-interleaved sample buffer where channel N is filled with
    /// `(N + 1) * 0.25`. The `AVAudioPCMBuffer` is returned so callers can keep the
    /// backing memory alive for the duration of the test.
    private func makeAudioSampleBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount
    ) throws -> (CMSampleBuffer, AVAudioPCMBuffer) {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false
        ))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        let channelData = try XCTUnwrap(pcm.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                channelData[channel][frame] = Float(channel + 1) * 0.25
            }
        }

        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        XCTAssertEqual(status, noErr, "format description creation failed")

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(frames),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        XCTAssertEqual(status, noErr, "sample buffer creation failed")
        let buffer = try XCTUnwrap(sampleBuffer)

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        XCTAssertEqual(status, noErr, "attaching the audio buffer list failed")
        return (buffer, pcm)
    }

    /// 480 frames @48 kHz is 10 ms, i.e. ~160 frames @16 kHz. Deriving the frame count
    /// from `totalLength / bytesPerFrame` counted every channel as its own frame, so a
    /// stereo capture arrived at double length with channel 1 read as garbage.
    func testStereoSourceIsResampledToMonoTargetWithoutDoublingFrames() throws {
        let collector = BufferCollector()
        let output = AudioStreamOutput(targetFormat: try makeTargetFormat()) { collector.append($0) }

        let (sampleBuffer, backing) = try makeAudioSampleBuffer(sampleRate: 48_000, channels: 2, frames: 480)
        output.process(sampleBuffer: sampleBuffer)
        withExtendedLifetime(backing) {}

        let produced = collector.all
        XCTAssertEqual(produced.count, 1, "one input buffer produces one output buffer")
        let buffer = try XCTUnwrap(produced.first)
        XCTAssertEqual(buffer.format.sampleRate, 16_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        XCTAssertLessThanOrEqual(buffer.frameLength, 161, "a 10 ms slice must not come out ~320 frames long")
    }

    /// The pass-through path used to hand back the buffer it was given. Once that
    /// buffer wraps the sample buffer's own memory it is dangling the moment
    /// `withAudioBufferList` returns.
    func testMatchingFormatIsCopiedAndOutlivesTheSampleBuffer() throws {
        let collector = BufferCollector()
        let output = AudioStreamOutput(targetFormat: try makeTargetFormat()) { collector.append($0) }

        try autoreleasepool {
            let (sampleBuffer, backing) = try makeAudioSampleBuffer(sampleRate: 16_000, channels: 1, frames: 160)
            output.process(sampleBuffer: sampleBuffer)
            withExtendedLifetime(backing) {}
        }

        let buffer = try XCTUnwrap(collector.all.first)
        XCTAssertEqual(buffer.frameLength, 160)
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        XCTAssertEqual(channelData[0][0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(channelData[0][159], 0.25, accuracy: 0.0001)
    }

    /// `convert(to:from:)` cannot resample — it asserts
    /// `outputBuffer.frameCapacity >= inputBuffer.frameLength` and traps the process,
    /// so a 48 kHz capture used to take the whole app down.
    func testResamplingManyBuffersDoesNotTrapAndKeepsDurationStable() throws {
        let collector = BufferCollector()
        let output = AudioStreamOutput(targetFormat: try makeTargetFormat()) { collector.append($0) }

        for _ in 0..<10 {
            let (sampleBuffer, backing) = try makeAudioSampleBuffer(sampleRate: 48_000, channels: 2, frames: 480)
            output.process(sampleBuffer: sampleBuffer)
            withExtendedLifetime(backing) {}
        }

        let totalFrames = collector.all.reduce(0) { $0 + Int($1.frameLength) }
        // 10 × 10 ms at 16 kHz is 1600 frames; allow for the resampler's priming delay.
        XCTAssertGreaterThan(totalFrames, 1500)
        XCTAssertLessThanOrEqual(totalFrames, 1600)
    }
}
