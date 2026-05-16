import Foundation
import ScreenCaptureKit
@preconcurrency import AVFoundation
import CoreGraphics

enum SystemAudioErrorKind: Equatable {
    case permissionDenied
    case listingFailed
    case captureFailed
}

@MainActor
@Observable
final class SystemAudioManager: NSObject {
    var isCapturing: Bool = false
    var isRefreshing: Bool = false
    var errorMessage: String?
    var lastErrorKind: SystemAudioErrorKind?
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var audioConverter: AVAudioConverter?
    private let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private let audioProcessingQueue = DispatchQueue(label: "com.summarytalk.audio", qos: .userInitiated)
    private let permissionCheck: () -> Bool
    private let requestPermission: () -> Void

    var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?

    init(
        permissionCheck: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestPermission: @escaping () -> Void = { _ = CGRequestScreenCaptureAccess() }
    ) {
        self.permissionCheck = permissionCheck
        self.requestPermission = requestPermission
        super.init()
    }

    func refreshAvailableApps() async {
        isRefreshing = true
        defer { isRefreshing = false }

        guard permissionCheck() else {
            requestPermission()
            lastErrorKind = .permissionDenied
            errorMessage = "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で許可後、アプリを再起動してください。"
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let targetApps = ["zoom", "teams", "meet", "webex", "slack", "discord", "facetime"]
            let filtered = content.applications.filter { app in
                targetApps.contains { target in
                    app.applicationName.localizedCaseInsensitiveContains(target)
                }
            }
            availableApps = filtered.isEmpty ? content.applications : filtered
            if let current = selectedApp,
               !availableApps.contains(where: { $0.processID == current.processID }) {
                selectedApp = nil
            }
            errorMessage = nil
            lastErrorKind = nil
        } catch {
            lastErrorKind = .listingFailed
            errorMessage = "アプリ一覧の取得に失敗: \(error.localizedDescription)"
        }
    }

    func startCapturing(app: SCRunningApplication? = nil) async {
        guard !isCapturing else { return }

        guard permissionCheck() else {
            lastErrorKind = .permissionDenied
            errorMessage = "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で許可後、アプリを再起動してください。"
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let filter: SCContentFilter
            if let app = app ?? selectedApp {
                let windows = content.windows.filter { $0.owningApplication?.processID == app.processID }
                guard let targetWindow = windows.first else {
                    lastErrorKind = .captureFailed
                    errorMessage = "選択したアプリにキャプチャ対象のウィンドウがありません"
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            } else {
                guard let display = content.displays.first else {
                    lastErrorKind = .captureFailed
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

            try stream?.addStreamOutput(streamOutput!, type: .audio, sampleHandlerQueue: audioProcessingQueue)
            try await stream?.startCapture()

            isCapturing = true
            errorMessage = nil
            lastErrorKind = nil
            audioConverter = nil
        } catch {
            lastErrorKind = .captureFailed
            errorMessage = "キャプチャ開始エラー: \(error.localizedDescription)"
            isCapturing = false
        }
    }

    func stopCapturing() async {
        guard isCapturing else { return }

        var stopSucceeded = true
        do {
            try await stream?.stopCapture()
        } catch {
            lastErrorKind = .captureFailed
            errorMessage = "キャプチャ停止エラー: \(error.localizedDescription)"
            stopSucceeded = false
        }

        stream = nil
        streamOutput = nil
        audioConverter = nil
        isCapturing = false

        if stopSucceeded {
            errorMessage = nil
            lastErrorKind = nil
        }
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == targetFormat.channelCount,
           buffer.format.commonFormat == targetFormat.commonFormat {
            return buffer
        }
        if audioConverter == nil {
            audioConverter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let audioConverter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let convertedCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedCapacity) else {
            Task { @MainActor in
                lastErrorKind = .captureFailed
                errorMessage = "オーディオバッファ変換に失敗しました"
            }
            return nil
        }
        do {
            try audioConverter.convert(to: outputBuffer, from: buffer)
            return outputBuffer
        } catch {
            Task { @MainActor in
                lastErrorKind = .captureFailed
                errorMessage = "オーディオ変換エラー: \(error.localizedDescription)"
            }
            return nil
        }
    }
}

extension SystemAudioManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.lastErrorKind = .captureFailed
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

        guard let channelData = pcmBuffer.floatChannelData else { return }

        let copyResult = CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: totalLength, destination: channelData[0])
        guard copyResult == kCMBlockBufferNoErr else { return }

        pcmBuffer.frameLength = frameCapacity

        handler(pcmBuffer)
    }
}
