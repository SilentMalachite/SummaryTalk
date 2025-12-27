import Foundation
import ScreenCaptureKit
import AVFoundation

@MainActor
@Observable
final class SystemAudioManager: NSObject {
    var isCapturing: Bool = false
    var errorMessage: String?
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?
    
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    
    var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    
    override init() {
        super.init()
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
    
    func startCapturing(app: SCRunningApplication? = nil) async {
        guard !isCapturing else { return }
        
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            let filter: SCContentFilter
            if let app = app ?? selectedApp {
                filter = SCContentFilter(desktopIndependentWindow: content.windows.first { $0.owningApplication?.processID == app.processID } ?? content.windows.first!)
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
            
            streamOutput = AudioStreamOutput { [weak self] buffer in
                self?.audioBufferHandler?(buffer)
            }
            
            try stream?.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: .main)
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
    private let handler: (AVAudioPCMBuffer) -> Void
    
    init(handler: @escaping (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
        super.init()
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: false
        )
        
        guard let format = format else { return }
        
        do {
            let blockBuffer = try sampleBuffer.dataBuffer?.dataBytes()
            guard let blockBuffer = blockBuffer else { return }
            
            let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            pcmBuffer.frameLength = frameCount
            
            if let channelData = pcmBuffer.floatChannelData {
                blockBuffer.withUnsafeBytes { ptr in
                    if let baseAddress = ptr.baseAddress {
                        memcpy(channelData[0], baseAddress, Int(frameCount) * MemoryLayout<Float>.size)
                    }
                }
            }
            
            handler(pcmBuffer)
        } catch {
            // Ignore conversion errors
        }
    }
}
