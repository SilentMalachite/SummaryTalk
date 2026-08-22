import Foundation
import Speech
import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum AudioSource: String, CaseIterable {
    case microphone = "マイク"
    case systemAudio = "システム音声（Zoom等）"
}

enum RecordingPhase: Equatable {
    case idle
    case starting
    case running
    case stopping
}

final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }
}

@MainActor
@Observable
final class TranscriptionManager {
    var transcribedText: String = ""
    var isRecording: Bool = false
    private(set) var recordingPhase: RecordingPhase = .idle
    var errorMessage: String?
    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    var audioSource: AudioSource = .microphone
    var onFinalizedLine: ((String) -> Void)?
    private var lastFinalizedText: String = ""
    private var committedText: String = ""

    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var pendingTranscription: String = ""
    private var lastTranscriptionUpdate: Date = .distantPast
    private var partialUpdateTask: Task<Void, Never>?
    private let partialUpdateInterval: TimeInterval = 0.25
    private let audioBufferSize: AVAudioFrameCount = 2048
    private let requestBox = RecognitionRequestBox()
    private var recognitionGeneration: UInt64 = 0
    private var tapInstalled = false
    private var captureStopObserver: (any SystemAudioCapturing)?

    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    }

    func requestAuthorization() async {
        authorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    func startRecording(systemAudioManager: (any SystemAudioCapturing)? = nil) async {
        guard !isRecording, recordingPhase == .idle else { return }

        if authorizationStatus != .authorized {
            await requestAuthorization()
        }

        guard authorizationStatus == .authorized else {
            errorMessage = "音声認識の権限が許可されていません。システム設定から許可してください。"
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "音声認識が利用できません。"
            return
        }

        recordingPhase = .starting
        isRecording = true

        do {
            switch audioSource {
            case .microphone:
                try startMicrophoneRecording()
            case .systemAudio:
                guard let systemAudioManager else {
                    throw NSError(
                        domain: "TranscriptionManager",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "システム音声マネージャが提供されていません"]
                    )
                }
                try await startSystemAudioRecording(systemAudioManager: systemAudioManager)
            }
            guard recordingPhase == .starting else {
                await systemAudioManager?.stopCapturing()
                return
            }
            recordingPhase = .running
            errorMessage = nil
        } catch {
            if recordingPhase == .idle {
                return
            }
            await rollbackStart(systemAudioManager: systemAudioManager)
            errorMessage = "録音の開始に失敗しました: \(error.localizedDescription)"
        }
    }

    private func startMicrophoneRecording() throws {
        resetRecognitionStateForNewSession()

        let recordingFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            throw NSError(
                domain: "TranscriptionManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "マイクが利用できません。システム設定からマイクへのアクセスを許可してください。"]
            )
        }

        let box = requestBox
        audioEngine.inputNode.installTap(onBus: 0, bufferSize: audioBufferSize, format: recordingFormat) { buffer, _ in
            box.append(buffer)
        }
        tapInstalled = true

        do {
            beginRecognitionRequest()
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            removeMicrophoneTapIfNeeded()
            abandonRecognitionRequest()
            throw error
        }
    }

    private func startSystemAudioRecording(systemAudioManager: any SystemAudioCapturing) async throws {
        resetRecognitionStateForNewSession()
        beginRecognitionRequest()

        let box = requestBox
        systemAudioManager.audioBufferHandler = { buffer in
            box.append(buffer)
        }
        systemAudioManager.onStreamStopped = { [weak self] error in
            Task { @MainActor in
                await self?.handleCaptureStopped(error: error, systemAudioManager: systemAudioManager)
            }
        }
        captureStopObserver = systemAudioManager

        await systemAudioManager.startCapturing()

        if let error = systemAudioManager.errorMessage {
            systemAudioManager.audioBufferHandler = nil
            systemAudioManager.onStreamStopped = nil
            captureStopObserver = nil
            abandonRecognitionRequest()
            throw NSError(domain: "TranscriptionManager", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    private func resetRecognitionStateForNewSession() {
        recognitionTask?.cancel()
        recognitionTask = nil
        partialUpdateTask?.cancel()
        pendingTranscription = ""
        lastFinalizedText = ""
        committedText = ""
        requestBox.set(nil)
        recognitionRequest = nil
    }

    private func beginRecognitionRequest() {
        recognitionGeneration += 1
        let generation = recognitionGeneration

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request
        requestBox.set(request)
        startRecognitionTask(generation: generation)
    }

    private func startRecognitionTask(generation: UInt64) {
        guard let speechRecognizer, let recognitionRequest else { return }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.recognitionGeneration else { return }

                if let result {
                    self.handleRecognitionUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                }

                if result?.isFinal != true, let error {
                    self.handleRecognitionError(error)
                }
            }
        }
    }

    func handleRecognitionUpdate(text: String, isFinal: Bool) {
        if isFinal {
            partialUpdateTask?.cancel()
            let display = Self.joinedDisplay(committed: committedText, current: text)
            if transcribedText != display {
                transcribedText = display
            }
            lastTranscriptionUpdate = .distantPast
            emitFinalizedDelta(currentText: text)
            committedText = display
            rearmRecognitionIfNeeded()
            return
        }

        let display = Self.joinedDisplay(committed: committedText, current: text)
        guard display != transcribedText else { return }

        pendingTranscription = display
        let now = Date()
        if now.timeIntervalSince(lastTranscriptionUpdate) >= partialUpdateInterval {
            transcribedText = pendingTranscription
            lastTranscriptionUpdate = now
            return
        }

        partialUpdateTask?.cancel()
        partialUpdateTask = Task { @MainActor in
            let delay = UInt64(partialUpdateInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            if self.transcribedText != self.pendingTranscription {
                self.transcribedText = self.pendingTranscription
                self.lastTranscriptionUpdate = Date()
            }
        }
    }

    private func handleRecognitionError(_ error: Error) {
        let nsError = error as NSError
        let isNoSpeech = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
        if !isNoSpeech {
            errorMessage = error.localizedDescription
        }
        rearmRecognitionIfNeeded()
    }

    private func rearmRecognitionIfNeeded() {
        guard isRecording, recordingPhase == .running, let previousRequest = recognitionRequest else { return }
        lastFinalizedText = ""
        let previousTask = recognitionTask
        // Swap the replacement in first so the audio tap never has a dead request to
        // append to, then retire the old one — releasing the references is not enough,
        // an un-ended request keeps its task alive until the audio limit trips.
        beginRecognitionRequest()
        previousRequest.endAudio()
        previousTask?.cancel()
    }

    private func emitFinalizedDelta(currentText: String) {
        let delta: String
        if currentText.hasPrefix(lastFinalizedText) {
            delta = String(currentText.dropFirst(lastFinalizedText.count))
        } else {
            delta = currentText
        }
        lastFinalizedText = currentText
        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onFinalizedLine?(trimmed)
        }
    }

    static func joinedDisplay(committed: String, current: String) -> String {
        if committed.isEmpty { return current }
        if current.isEmpty { return committed }
        return committed + current
    }

    func stopRecording(systemAudioManager: (any SystemAudioCapturing)? = nil) async {
        guard recordingPhase == .starting || recordingPhase == .running || isRecording else { return }
        recordingPhase = .stopping
        await tearDownSession(systemAudioManager: systemAudioManager)
    }

    private func handleCaptureStopped(error: Error, systemAudioManager: any SystemAudioCapturing) async {
        guard recordingPhase == .running || recordingPhase == .starting else { return }
        errorMessage = "ストリームエラー: \(error.localizedDescription)"
        await stopRecording(systemAudioManager: systemAudioManager)
    }

    private func rollbackStart(systemAudioManager: (any SystemAudioCapturing)?) async {
        await tearDownSession(systemAudioManager: systemAudioManager)
    }

    private func tearDownSession(systemAudioManager: (any SystemAudioCapturing)?) async {
        recognitionGeneration += 1
        requestBox.set(nil)

        removeMicrophoneTapIfNeeded()
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        let audioManager = systemAudioManager ?? captureStopObserver
        if let audioManager {
            audioManager.audioBufferHandler = nil
            audioManager.onStreamStopped = nil
            await audioManager.stopCapturing()
        }
        captureStopObserver = nil

        // A partial can be sitting in the throttle window when the user hits stop;
        // dropping it silently loses up to `partialUpdateInterval` of transcript.
        partialUpdateTask?.cancel()
        flushPendingTranscription()

        abandonRecognitionRequest()

        recordingPhase = .idle
        isRecording = false
    }

    private func flushPendingTranscription() {
        if !pendingTranscription.isEmpty, transcribedText != pendingTranscription {
            transcribedText = pendingTranscription
        }
        pendingTranscription = ""
    }

    private func abandonRecognitionRequest() {
        requestBox.set(nil)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private func removeMicrophoneTapIfNeeded() {
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    func clearText() {
        partialUpdateTask?.cancel()
        pendingTranscription = ""
        lastFinalizedText = ""
        committedText = ""
        transcribedText = ""
    }

    func saveToFile() async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "transcription.txt"

        let response = await panel.begin()

        guard response == .OK, let url = panel.url else {
            return nil
        }

        do {
            try transcribedText.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
            return nil
        }
    }
}
