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
final class SystemAudioManager: SystemAudioCapturing {
    var isCapturing: Bool = false
    var isRefreshing: Bool = false
    var errorMessage: String?
    var lastErrorKind: SystemAudioErrorKind?
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?
    private var streamDelegate: StreamStopObserver?
    private var streamGeneration: UInt64 = 0
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

            streamGeneration += 1
            let generation = streamGeneration
            let delegate = StreamStopObserver(generation: generation) { [weak self] stoppedGeneration, error in
                Task { @MainActor in
                    self?.handleStreamStopped(generation: stoppedGeneration, error: error)
                }
            }
            let newStream = SCStream(filter: filter, configuration: config, delegate: delegate)
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
            streamDelegate = delegate
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
        streamGeneration += 1
        let existing = stream
        streamOutput = nil
        streamDelegate = nil
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
        streamGeneration += 1
        let existing = stream
        streamOutput = nil
        streamDelegate = nil
        stream = nil
        isCapturing = false
        if let existing {
            try? await existing.stopCapture()
        }
    }

    /// `didStopWithError` reaches us through a `Task` hop, so it can land after the
    /// intentional stop has already returned — or even after a *new* stream started.
    /// The generation token is what separates a genuine failure from a late echo;
    /// a bare flag would already have been reset by the time this runs.
    private func handleStreamStopped(generation: UInt64, error: Error) {
        guard generation == streamGeneration, stream != nil else { return }
        streamOutput = nil
        streamDelegate = nil
        stream = nil
        isCapturing = false
        lastErrorKind = .captureFailed
        errorMessage = "ストリームエラー: \(error.localizedDescription)"
        onStreamStopped?(error)
    }
}

/// `SCStream` holds its delegate weakly and is not `Sendable`, so the stop callback
/// carries a generation token instead of the stream itself.
private final class StreamStopObserver: NSObject, SCStreamDelegate {
    private let generation: UInt64
    private let onStopped: @Sendable (UInt64, Error) -> Void

    init(generation: UInt64, onStopped: @escaping @Sendable (UInt64, Error) -> Void) {
        self.generation = generation
        self.onStopped = onStopped
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped(generation, error)
    }
}

final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var pendingInput: AVAudioPCMBuffer?
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
        process(sampleBuffer: sampleBuffer)
    }

    /// Split out of the delegate callback so tests can drive it with a synthetic
    /// `CMSampleBuffer` — an `SCStream` cannot be constructed in a unit test.
    func process(sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let sourceFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        // The source layout has to come from the ASBD: assuming non-interleaved and
        // copying the whole block buffer into channel 0 mangles anything but mono.
        let converted = try? sampleBuffer.withAudioBufferList { bufferList, _ -> AVAudioPCMBuffer? in
            guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, bufferListNoCopy: bufferList.unsafePointer) else {
                return nil
            }
            return convertBuffer(source)
        }

        guard let converted else { return }
        handler(converted)
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == targetFormat.channelCount,
           buffer.format.commonFormat == targetFormat.commonFormat,
           buffer.format.isInterleaved == targetFormat.isInterleaved {
            return copied(buffer)
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else {
            onError?("オーディオコンバータの作成に失敗しました")
            return nil
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let convertedCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: convertedCapacity) else {
            onError?("オーディオバッファ変換に失敗しました")
            return nil
        }

        // `convert(to:from:)` asserts `outputBuffer.frameCapacity >= inputBuffer.frameLength`
        // and traps the process — it cannot resample. Only the pull-based API can.
        pendingInput = buffer
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { [self] _, outStatus in
            guard let next = pendingInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            pendingInput = nil
            outStatus.pointee = .haveData
            return next
        }
        pendingInput = nil

        switch status {
        case .haveData, .inputRanDry:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .endOfStream:
            return nil
        case .error:
            onError?("オーディオ変換エラー: \(conversionError?.localizedDescription ?? "不明なエラー")")
            return nil
        @unknown default:
            return nil
        }
    }

    /// The incoming buffer wraps the sample buffer's memory and is invalid the moment
    /// `withAudioBufferList` returns, so the pass-through path must still own its bytes.
    private func copied(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames),
              let source = buffer.floatChannelData,
              let destination = copy.floatChannelData else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: Int(frames))
        }
        copy.frameLength = frames
        return copy
    }
}
