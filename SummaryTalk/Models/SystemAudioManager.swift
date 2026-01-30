import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics
import CoreMedia

@MainActor
@Observable
final class SystemAudioManager: NSObject {
    var isCapturing: Bool = false
    var errorMessage: String?
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?
    
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private let audioQueue = DispatchQueue(label: "com.summarytalk.audio")
    
    override init() {
        super.init()
    }

    private func ensureScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }
    
    func refreshAvailableApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableApps = content.applications.filter { app in
                let name = app.applicationName.lowercased()
                return name.contains("zoom") || 
                       name.contains("teams") || 
                       name.contains("meet") ||
                       name.contains("webex") ||
                       name.contains("slack") ||
                       name.contains("discord") ||
                       name.contains("facetime")
            }
            
            if availableApps.isEmpty {
                availableApps = content.applications
            }
            
            errorMessage = nil
        } catch {
            errorMessage = "アプリ一覧の取得に失敗: \(error.localizedDescription)"
        }
    }
    
    func startCapturing(app: SCRunningApplication? = nil, handler: @escaping (CMSampleBuffer) -> Void) async {
        guard !isCapturing else { return }
        
        do {
            guard ensureScreenRecordingPermission() else {
                errorMessage = "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録で許可してください。"
                return
            }
            
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            let filter: SCContentFilter
            if let app = app ?? selectedApp {
                let windows = content.windows.filter { $0.owningApplication?.processID == app.processID }
                guard let targetWindow = windows.first else {
                    errorMessage = "選択したアプリにキャプチャ対象のウィンドウがありません"
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            } else {
                guard let display = content.displays.first else {
                    errorMessage = "ディスプレイが見つかりません"
                    return
                }
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }
            
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 16000
            config.channelCount = 1
            
            // Disable video capture for audio-only
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            
            stream = SCStream(filter: filter, configuration: config, delegate: self)
            
            streamOutput = AudioStreamOutput(handler: handler)
            
            try stream?.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream?.startCapture()
            
            isCapturing = true
            errorMessage = nil
            
        } catch {
            errorMessage = "キャプチャ開始エラー: \(error.localizedDescription)"
            isCapturing = false
        }
    }
    
    func stopCapturing() async {
        guard isCapturing else { return }
        
        do {
            try await stream?.stopCapture()
        } catch {
            errorMessage = "キャプチャ停止エラー: \(error.localizedDescription)"
        }
        
        stream = nil
        streamOutput = nil
        isCapturing = false
    }
}

extension SystemAudioManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = "ストリームエラー: \(error.localizedDescription)"
            self.isCapturing = false
        }
    }
}

final class AudioStreamOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void
    
    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler(sampleBuffer)
    }
}
