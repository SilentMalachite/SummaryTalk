import Foundation
import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreGraphics

@MainActor
@Observable
final class SystemAudioManager: NSObject {
    var isCapturing: Bool = false
    var errorMessage: String?
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?
    
    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var audioConverter: AVAudioConverter?
    private let targetFormat: AVAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    
    var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    
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
                let name = app.applicationName
                return name.localizedCaseInsensitiveContains("zoom") ||
                       name.localizedCaseInsensitiveContains("teams") ||
                       name.localizedCaseInsensitiveContains("meet") ||
                       name.localizedCaseInsensitiveContains("webex") ||
                       name.localizedCaseInsensitiveContains("slack") ||
                       name.localizedCaseInsensitiveContains("discord") ||
                       name.localizedCaseInsensitiveContains("facetime")
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
            
            streamOutput = AudioStreamOutput { [weak self] buffer in
                guard let self else { return }
                if let converted = self.convertBuffer(buffer) {
                    self.audioBufferHandler?(converted)
                }
            }
            
            try stream?.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: .main)
            try await stream?.startCapture()
            
            isCapturing = true
            errorMessage = nil
            audioConverter = nil
            
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
        audioConverter = nil
        isCapturing = false
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if audioConverter == nil {
            audioConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let audioConverter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let convertedCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedCapacity) else {
            errorMessage = "オーディオバッファ変換に失敗しました"
            return nil
        }
        do {
            try audioConverter.convert(to: outputBuffer, from: buffer)
            return outputBuffer
        } catch {
            errorMessage = "オーディオ変換エラー: \(error.localizedDescription)"
            return nil
        }
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
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return }
        
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        let frameCapacity = AVAudioFrameCount(totalLength / bytesPerFrame)
        guard frameCapacity > 0 else { return }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return }
        
        var data = Data(count: totalLength)
        let copyResult = data.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let dest = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: dest)
        }
        guard copyResult == kCMBlockBufferNoErr else { return }
        
        let copyBytes = min(totalLength, Int(frameCapacity) * bytesPerFrame)
        if let channelData = pcmBuffer.floatChannelData {
            data.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    memcpy(channelData[0], base, copyBytes)
                }
            }
            let framesCopied = copyBytes / bytesPerFrame
            pcmBuffer.frameLength = AVAudioFrameCount(framesCopied)
        }
        
        handler(pcmBuffer)
    }
}
