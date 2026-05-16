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

    func testStopRecordingWhenIdleIsSafe() {
        let manager = TranscriptionManager()
        manager.stopRecording()
        XCTAssertFalse(manager.isRecording)
        XCTAssertNil(manager.errorMessage)
    }

    /// `startRecording` short-circuits when already recording. We can't drive the real
    /// SFSpeechRecognizer + AVAudioEngine pipeline in a unit test, but we *can* verify
    /// the early-return contract by force-flipping `isRecording` and asserting no error
    /// path runs (no permission prompt, no errorMessage mutation).
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

    func testAudioSourceRawValuesAreJapanese() {
        XCTAssertEqual(AudioSource.microphone.rawValue, "マイク")
        XCTAssertEqual(AudioSource.systemAudio.rawValue, "システム音声（Zoom等）")
    }

    func testAudioSourceAllCasesCoversBothVariants() {
        XCTAssertEqual(AudioSource.allCases, [.microphone, .systemAudio])
    }
}
