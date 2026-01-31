import Foundation
import Speech
import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum AudioSource: String, CaseIterable {
    case microphone = "マイク"
    case systemAudio = "システム音声（Zoom等）"
}

@MainActor
@Observable
final class TranscriptionManager {
    var transcribedText: String = ""
    var isRecording: Bool = false
    var errorMessage: String?
    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    var audioSource: AudioSource = .microphone
    
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let speechRecognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var pendingTranscription: String = ""
    private var lastTranscriptionUpdate: Date = .distantPast
    private var partialUpdateTask: Task<Void, Never>?
    private let partialUpdateInterval: TimeInterval = 0.25
    private let audioBufferSize: AVAudioFrameCount = 2048
    
    var systemAudioManager: SystemAudioManager?
    
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
    
    func startRecording() async {
        guard !isRecording else { return }
        
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
        
        do {
            switch audioSource {
            case .microphone:
                try startMicrophoneRecording()
            case .systemAudio:
                try await startSystemAudioRecording()
            }
        } catch {
            errorMessage = "録音の開始に失敗しました: \(error.localizedDescription)"
        }
    }
    
    private func startMicrophoneRecording() throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        partialUpdateTask?.cancel()
        pendingTranscription = ""
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest else {
            throw NSError(domain: "TranscriptionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "認識リクエストを作成できません"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        recognitionRequest.taskHint = .dictation
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: audioBufferSize, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        isRecording = true
        errorMessage = nil
        
        startRecognitionTask()
    }
    
    private func startSystemAudioRecording() async throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        partialUpdateTask?.cancel()
        pendingTranscription = ""
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest else {
            throw NSError(domain: "TranscriptionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "認識リクエストを作成できません"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        recognitionRequest.taskHint = .dictation
        if speechRecognizer?.supportsOnDeviceRecognition == true {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        
        if systemAudioManager == nil {
            systemAudioManager = SystemAudioManager()
        }
        
        systemAudioManager?.audioBufferHandler = { [weak self] buffer in
            self?.recognitionRequest?.append(buffer)
        }
        
        await systemAudioManager?.startCapturing()
        
        if let error = systemAudioManager?.errorMessage {
            throw NSError(domain: "TranscriptionManager", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
        
        isRecording = true
        errorMessage = nil
        
        startRecognitionTask()
    }
    
    private func startRecognitionTask() {
        guard let speechRecognizer, let recognitionRequest else { return }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                
                if let result {
                    self.handleRecognitionUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                }
                
                if let error {
                    let nsError = error as NSError
                    // Ignore "No speech detected" errors (code 1110)
                    if nsError.domain != "kAFAssistantErrorDomain" || nsError.code != 1110 {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func handleRecognitionUpdate(text: String, isFinal: Bool) {
        guard text != transcribedText else { return }
        if isFinal {
            partialUpdateTask?.cancel()
            transcribedText = text
            lastTranscriptionUpdate = Date()
            return
        }

        pendingTranscription = text
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
    
    func stopRecording() {
        switch audioSource {
        case .microphone:
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        case .systemAudio:
            Task {
                await systemAudioManager?.stopCapturing()
            }
        }

        partialUpdateTask?.cancel()
        pendingTranscription = ""
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
    
    func clearText() {
        partialUpdateTask?.cancel()
        pendingTranscription = ""
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
