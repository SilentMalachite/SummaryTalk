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
protocol SystemAudioCapturing: AnyObject {
    var errorMessage: String? { get }
    var isCapturing: Bool { get }
    var audioBufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }
    var onStreamStopped: ((Error) -> Void)? { get set }
    func startCapturing() async
    func stopCapturing() async
}

@MainActor
@Observable
final class SystemAudioManager: NSObject, SystemAudioCapturing {
    var isCapturing: Bool = false
    var isRefreshing: Bool = false
    var errorMessage: String?
    var lastErrorKind: SystemAudioErrorKind?
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var isStoppingIntentionally = false
    private let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!
    private let audioProcessingQueue = DispatchQueue(label: "com.summarytalk.audio", qos: .userInitiated)
    private let permissionCheck: () -> Bool
    private let requestPermission: () -> Void

    var audioBufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var onStreamStopped: ((Error) -> Void)?

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

    func startCapturing() async {
        await startCapturing(app: nil)
    }

    func startCapturing(app: SCRunningApplication?) async {
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

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            let downstream = audioBufferHandler
            let output = AudioStreamOutput(
                targetFormat: targetFormat,
                onError: { [weak self] message in
                    Task { @MainActor in
                        self?.lastErrorKind = .captureFailed
                        self?.errorMessage = message
                    }
                },
                handler: { buffer in
                    downstream?(buffer)
                }
            )

            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioProcessingQueue)
            stream = newStream
            streamOutput = output
            try await newStream.startCapture()

            isCapturing = true
            errorMessage = nil
            lastErrorKind = nil
        } catch {
            await abandonUnstartedCapture()
            lastErrorKind = .captureFailed
            errorMessage = "キャプチャ開始エラー: \(error.localizedDescription)"
            isCapturing = false
        }
    }

    func stopCapturing() async {
        isStoppingIntentionally = true
        defer { isStoppingIntentionally = false }

        let existing = stream
        streamOutput = nil
        stream = nil
        isCapturing = false

        guard let existing else { return }

        do {
            try await existing.stopCapture()
            errorMessage = nil
            lastErrorKind = nil
        } catch {
            lastErrorKind = .captureFailed
            errorMessage = "キャプチャ停止エラー: \(error.localizedDescription)"
        }
    }

    private func abandonUnstartedCapture() async {
        isStoppingIntentionally = true
        defer { isStoppingIntentionally = false }

        let existing = stream
        streamOutput = nil
        stream = nil
        isCapturing = false
        if let existing {
            try? await existing.stopCapture()
        }
    }

    private func handleStreamStopped(error: Error) {
        streamOutput = nil
        stream = nil
        isCapturing = false
        guard !isStoppingIntentionally else { return }
        lastErrorKind = .captureFailed
        errorMessage = "ストリームエラー: \(error.localizedDescription)"
        onStreamStopped?(error)
    }
}

extension SystemAudioManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.handleStreamStopped(error: error)
        }
    }
}

final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private let handler: @Sendable (AVAudioPCMBuffer) -> Void
    private let onError: (@Sendable (String) -> Void)?

    init(
        targetFormat: AVAudioFormat,
        onError: (@Sendable (String) -> Void)? = nil,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        self.targetFormat = targetFormat
        self.onError = onError
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

        guard let converted = convertBuffer(pcmBuffer) else { return }
        handler(converted)
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == targetFormat.channelCount,
           buffer.format.commonFormat == targetFormat.commonFormat {
            return buffer
        }
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let convertedCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedCapacity) else {
            onError?("オーディオバッファ変換に失敗しました")
            return nil
        }
        do {
            try converter.convert(to: outputBuffer, from: buffer)
            return outputBuffer
        } catch {
            onError?("オーディオ変換エラー: \(error.localizedDescription)")
            return nil
        }
    }
}
