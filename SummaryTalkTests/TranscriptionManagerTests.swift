import XCTest
import Speech
@testable import SummaryTalk

@MainActor
final class TranscriptionManagerTests: XCTestCase {
    func testInitialState() {
        let manager = TranscriptionManager()
        XCTAssertEqual(manager.transcribedText, "")
        XCTAssertFalse(manager.isRecording)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(manager.audioSource, .microphone, "default source is the mic")
        XCTAssertEqual(manager.authorizationStatus, .notDetermined)
        XCTAssertNil(manager.onFinalizedLine)
    }

    func testAudioSourceIsAssignable() {
        let manager = TranscriptionManager()
        manager.audioSource = .systemAudio
        XCTAssertEqual(manager.audioSource, .systemAudio)
        manager.audioSource = .microphone
        XCTAssertEqual(manager.audioSource, .microphone)
    }

    func testClearTextResetsTranscribedText() {
        let manager = TranscriptionManager()
        manager.transcribedText = "途中まで認識された文"
        manager.clearText()
        XCTAssertEqual(manager.transcribedText, "")
    }

    func testStopRecordingWhenIdleIsSafe() async {
        let manager = TranscriptionManager()
        await manager.stopRecording()
        XCTAssertFalse(manager.isRecording)
        XCTAssertNil(manager.errorMessage)
    }

    func testStopDuringSystemAudioStartDoesNotResumeRecording() async throws {
        try XCTSkipUnless(
            SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))?.isAvailable == true,
            "ja-JP speech recognizer is required"
        )

        let capture = GatedSystemAudioCapture()
        let manager = TranscriptionManager()
        manager.audioSource = .systemAudio
        manager.authorizationStatus = .authorized

        let started = Task {
            await manager.startRecording(systemAudioManager: capture)
        }

        let deadline = Date().addingTimeInterval(2)
        while !manager.isRecording, Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(manager.isRecording, "start marks recording before capture resumes")

        await manager.stopRecording(systemAudioManager: capture)
        await started.value

        XCTAssertFalse(manager.isRecording, "a stop during startCapturing must not resurrect recording")
        XCTAssertEqual(manager.recordingPhase, .idle, "await after startCapturing must not force .running")
        XCTAssertFalse(capture.isCapturing, "capture must not keep running after stop")
    }

    func testFailedSystemAudioStartLeavesIdle() async throws {
        try XCTSkipUnless(
            SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))?.isAvailable == true,
            "ja-JP speech recognizer is required"
        )

        let capture = FailingSystemAudioCapture()
        let manager = TranscriptionManager()
        manager.audioSource = .systemAudio
        manager.authorizationStatus = .authorized

        await manager.startRecording(systemAudioManager: capture)

        XCTAssertFalse(manager.isRecording)
        XCTAssertEqual(manager.recordingPhase, .idle)
        XCTAssertNotNil(manager.errorMessage)
    }

    func testStartRecordingNoOpsWhenAlreadyRecording() async {
        let manager = TranscriptionManager()
        manager.isRecording = true
        manager.errorMessage = nil

        await manager.startRecording()

        XCTAssertTrue(manager.isRecording, "stays recording — function returned at the guard")
        XCTAssertNil(manager.errorMessage, "no auth / availability error surfaces")
    }

    func testOnFinalizedLineCallbackIsInvokable() {
        let manager = TranscriptionManager()
        var received: [String] = []
        manager.onFinalizedLine = { received.append($0) }

        manager.onFinalizedLine?("一行目")
        manager.onFinalizedLine?("二行目")

        XCTAssertEqual(received, ["一行目", "二行目"])
    }

    /// The last partial is often identical to the subsequent `isFinal` result.
    /// Auto-send (`onFinalizedLine`) must still fire in that case.
    func testFinalMatchingLastPartialStillEmitsFinalizedLine() {
        let manager = TranscriptionManager()
        var received: [String] = []
        manager.onFinalizedLine = { received.append($0) }

        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: false)
        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: true)

        XCTAssertEqual(received, ["こんにちは"])
        XCTAssertEqual(manager.transcribedText, "こんにちは")
    }

    func testIdenticalFinalDoesNotEmitTwice() {
        let manager = TranscriptionManager()
        var received: [String] = []
        manager.onFinalizedLine = { received.append($0) }

        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: true)
        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: true)

        XCTAssertEqual(received, ["こんにちは"])
    }

    func testSubsequentUtteranceAppendsToCommittedText() {
        let manager = TranscriptionManager()
        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: true)
        manager.handleRecognitionUpdate(text: "世界", isFinal: false)
        XCTAssertEqual(manager.transcribedText, "こんにちは世界")
    }

    func testSecondFinalEmitsOnlyNewUtterance() {
        let manager = TranscriptionManager()
        var received: [String] = []
        manager.onFinalizedLine = { received.append($0) }

        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: true)
        manager.handleRecognitionUpdate(text: "世界", isFinal: true)

        XCTAssertEqual(received, ["こんにちは", "世界"])
        XCTAssertEqual(manager.transcribedText, "こんにちは世界")
    }

    func testClearTextResetsCommittedUtterances() {
        let manager = TranscriptionManager()
        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: true)
        manager.clearText()
        manager.handleRecognitionUpdate(text: "世界", isFinal: false)
        XCTAssertEqual(manager.transcribedText, "世界")
    }

    /// Partials inside the throttle window are only staged in `pendingTranscription`.
    /// Teardown used to clear that staging area, silently dropping the tail of the
    /// transcript whenever the user stopped mid-utterance.
    func testStopFlushesThrottledPartialText() async throws {
        let manager = TranscriptionManager()

        manager.handleRecognitionUpdate(text: "こんに", isFinal: false)
        XCTAssertEqual(manager.transcribedText, "こんに")

        manager.handleRecognitionUpdate(text: "こんにちは", isFinal: false)
        try XCTSkipIf(manager.transcribedText == "こんにちは",
                      "throttle window elapsed between calls — nothing was staged to flush")
        XCTAssertEqual(manager.transcribedText, "こんに", "a throttled partial is not applied immediately")

        manager.isRecording = true
        await manager.stopRecording()

        XCTAssertEqual(manager.transcribedText, "こんにちは", "stopping must flush the staged partial")
        XCTAssertFalse(manager.isRecording)
        XCTAssertEqual(manager.recordingPhase, .idle)
    }

    func testJoinedDisplayConcatenatesCommittedAndCurrent() {
        XCTAssertEqual(TranscriptionManager.joinedDisplay(committed: "", current: "こんにちは"), "こんにちは")
        XCTAssertEqual(TranscriptionManager.joinedDisplay(committed: "こんにちは", current: ""), "こんにちは")
        XCTAssertEqual(TranscriptionManager.joinedDisplay(committed: "こんにちは", current: "世界"), "こんにちは世界")
    }

    func testAudioSourceRawValuesAreJapanese() {
        XCTAssertEqual(AudioSource.microphone.rawValue, "マイク")
        XCTAssertEqual(AudioSource.systemAudio.rawValue, "システム音声（Zoom等）")
    }

    func testAudioSourceAllCasesCoversBothVariants() {
        XCTAssertEqual(AudioSource.allCases, [.microphone, .systemAudio])
    }
}

@MainActor
private final class GatedSystemAudioCapture: SystemAudioCapturing {
    var errorMessage: String?
    var isCapturing = false
    var audioBufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onStreamStopped: ((Error) -> Void)?
    private var startGate: CheckedContinuation<Void, Never>?
    private var cancelled = false

    func startCapturing() async {
        cancelled = false
        await withCheckedContinuation { continuation in
            startGate = continuation
        }
        if !cancelled {
            isCapturing = true
        }
    }

    func stopCapturing() async {
        cancelled = true
        isCapturing = false
        startGate?.resume()
        startGate = nil
    }
}

@MainActor
private final class FailingSystemAudioCapture: SystemAudioCapturing {
    var errorMessage: String? = "画面収録の権限がありません"
    var isCapturing = false
    var audioBufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onStreamStopped: ((Error) -> Void)?

    func startCapturing() async {}

    func stopCapturing() async {
        isCapturing = false
    }
}
