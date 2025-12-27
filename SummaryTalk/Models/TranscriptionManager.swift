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
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest else {
            throw NSError(domain: "TranscriptionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "認識リクエストを作成できません"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
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
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest else {
            throw NSError(domain: "TranscriptionManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "認識リクエストを作成できません"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.addsPunctuation = true
        
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
                    self.transcribedText = result.bestTranscription.formattedString
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
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }
    
    func clearText() {
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
