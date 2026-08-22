# System Audio App Picker Implementation Plan

> **ステータス: 完了済み — 履歴として保存。再実行しないこと。** 下記のタスクはすべて実装済みで、チェックボックスが
> 未チェックなのはプランの書き方によるもので、残作業ではない。掲載しているコードは 2026-05-16 時点のもので、
> 一部は現在では**使ってはいけない**実装になっている。特に:
>
> - Task 2 の `audioConverter.convert(to:from:)` 呼び出し — この API はサンプルレート
>   変換に対応しておらず、アサート失敗でプロセスごと停止する。現行は `convert(to:error:withInputFrom:)`。
> - 同じく Task 2 の `CMBlockBufferCopyDataBytes(...)` でブロックバッファ全体を channel 0 へコピーする箇所 — ステレオ入力で
>   長さが倍になり片チャンネルが壊れる。現行は `withAudioBufferList` + ASBD 由来フォーマット。
>
> 現在の実装と制約は `CLAUDE.md` および
> `docs/superpowers/specs/2026-05-16-system-audio-app-picker-design.md` の「実装後の追補」を参照。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ユーザーが「システム音声」モードでキャプチャ対象アプリ (Zoom 等) をインラインで選択できる UI を `ControlPanel` に追加する。

**Architecture:** `SystemAudioManager` を `ContentView` の `@State` に昇格させ、新規 `SystemAudioAppPicker` View が `@Bindable` 経由で操作する。対象アプリは Optional の `selectedApp` (`nil` = ディスプレイ全体) として表現し、ピッカーは「ディスプレイ全体」を先頭固定エントリにする。`SCRunningApplication` をテスト用にプロトコル `RunningApplicationLike` で抽象化し、選択候補生成ロジック (`makeChoices`) は純粋関数として単独テストする。

**Tech Stack:** Swift 6 / SwiftUI / `@Observable` / `ScreenCaptureKit` / XCTest / `xcodebuild`

**Spec:** `docs/superpowers/specs/2026-05-16-system-audio-app-picker-design.md`

---

## ファイル構成

| パス | 種別 | 役割 |
|---|---|---|
| `SummaryTalk/Models/SystemAudioAppChoice.swift` | 新規 | `RunningApplicationLike`, `AppChoice`, `AppChoiceLabel`, `makeChoices(from:)`, `SCRunningApplication` 適合 |
| `SummaryTalkTests/SystemAudioManagerTests.swift` | 新規 | `makeChoices` の 4 ケースと `lastErrorKind` の権限拒否ケースを XCTest で検証 |
| `SummaryTalk/Models/SystemAudioManager.swift` | 修正 | `isRefreshing` / `lastErrorKind` / `permissionCheck` / `requestPermission` 追加。`refreshAvailableApps()` に権限プリフライト。`startCapturing` は preflight のみ |
| `SummaryTalk/Models/TranscriptionManager.swift` | 修正 | `systemAudioManager` プロパティ削除。`startRecording(systemAudioManager:)` に署名変更 |
| `SummaryTalk/Views/SystemAudioAppPicker.swift` | 新規 | Picker + 更新ボタン + 権限/エラー表示 + 「システム設定を開く」ボタン |
| `SummaryTalk/Views/ControlPanel.swift` | 修正 | `systemAudioManager` 引数追加。`audioSource == .systemAudio` のときピッカーを表示 |
| `SummaryTalk/ContentView.swift` | 修正 | `@State systemAudioManager: SystemAudioManager` 追加 |
| `SummaryTalk.xcodeproj/project.pbxproj` | 修正 | 新規 3 ファイル (`SystemAudioAppChoice.swift`, `SystemAudioAppPicker.swift`, `SystemAudioManagerTests.swift`) の `PBXBuildFile` / `PBXFileReference` / グループ参照 / Sources ビルドフェーズ登録 |

---

## ビルド & テストコマンド (リファレンス)

```bash
# ビルドのみ
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' build

# テスト実行 (全テスト)
xcodebuild test -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS'

# 特定テストクラスだけ
xcodebuild test -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/SystemAudioAppChoiceTests
```

`xcodebuild` 出力は冗長なので、テスト結果だけ見たいなら末尾に `| grep -E "Test Case|PASS|FAIL|error:"` を付ける。

---

## Task 1: 純粋ロジック `makeChoices` を TDD で追加

**Files:**
- Create: `SummaryTalk/Models/SystemAudioAppChoice.swift`
- Create: `SummaryTalkTests/SystemAudioManagerTests.swift`
- Modify: `SummaryTalk.xcodeproj/project.pbxproj` (新規 2 ファイル登録)

- [ ] **Step 1.1: 新規テストファイルを作成 (失敗するテストを先に書く)**

`SummaryTalkTests/SystemAudioManagerTests.swift` を以下で新規作成。

```swift
import XCTest
@testable import SummaryTalk

private struct FakeApp: RunningApplicationLike {
    let processID: pid_t
    let applicationName: String
    let bundleIdentifier: String
}

final class SystemAudioAppChoiceTests: XCTestCase {
    func testWholeDisplayIsAlwaysFirstAndOnlyEntryWhenAppsEmpty() {
        let result = makeChoices(from: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.choice, .wholeDisplay)
        XCTAssertEqual(result.first?.displayName, "ディスプレイ全体（すべてのシステム音声）")
    }

    func testWholeDisplayIsFirstWhenAppsPresent() {
        let apps = [FakeApp(processID: 10, applicationName: "Zoom", bundleIdentifier: "us.zoom.xos")]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].choice, .wholeDisplay)
        XCTAssertEqual(result[1].choice, .app(processID: 10))
        XCTAssertEqual(result[1].displayName, "Zoom")
    }

    func testDuplicateProcessIDsAreNormalizedToFirstOccurrence() {
        let apps = [
            FakeApp(processID: 100, applicationName: "Zoom", bundleIdentifier: "us.zoom"),
            FakeApp(processID: 100, applicationName: "Zoom Helper", bundleIdentifier: "us.zoom.helper")
        ]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].choice, .app(processID: 100))
        XCTAssertEqual(result[1].displayName, "Zoom")
    }

    func testEmptyApplicationNameFallsBackToBundleIdentifier() {
        let apps = [FakeApp(processID: 200, applicationName: "", bundleIdentifier: "com.example.app")]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result[1].displayName, "com.example.app")
    }

    func testBothNamesEmptyFallsBackToUnknownWithPid() {
        let apps = [FakeApp(processID: 300, applicationName: "", bundleIdentifier: "")]
        let result = makeChoices(from: apps)
        XCTAssertEqual(result[1].displayName, "不明なアプリ (PID 300)")
    }
}
```

- [ ] **Step 1.2: pbxproj にテストファイルを登録**

`SummaryTalk.xcodeproj/project.pbxproj` に以下の編集を加える。既存 ID は最大 `A1000010` / `A200000C` なので、新 ID は `A100001A` / `A200000D` を使う (連番だと将来の差し込みで衝突しやすいので末尾は 1A から)。

(a) `Begin PBXBuildFile section` ブロックの末尾 (現状最終行 = `A1000010 /* IPtalkManagerTests.swift ... */`) の直後に追加:

```
		A100001A /* SystemAudioManagerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000D /* SystemAudioManagerTests.swift */; };
```

(b) `Begin PBXFileReference section` ブロック内、`A200000C /* IPtalkManagerTests.swift */` の直後に追加:

```
		A200000D /* SystemAudioManagerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SystemAudioManagerTests.swift; sourceTree = "<group>"; };
```

(c) `A5000006 /* SummaryTalkTests */` グループの `children` 配列に追加:

```
				A200000D /* SystemAudioManagerTests.swift */,
```

(d) `A7000003 /* Sources */` (テストターゲット側の `PBXSourcesBuildPhase`) の `files` 配列に追加:

```
				A100001A /* SystemAudioManagerTests.swift in Sources */,
```

- [ ] **Step 1.3: テストをビルドして失敗を確認**

```bash
xcodebuild test -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/SystemAudioAppChoiceTests 2>&1 | tail -40
```

期待: コンパイルエラー (`cannot find 'RunningApplicationLike' in scope` / `cannot find 'makeChoices' in scope` / `'AppChoice'` 未定義)。

- [ ] **Step 1.4: `SystemAudioAppChoice.swift` を新規作成 (最小実装でテスト通過まで一気に)**

`SummaryTalk/Models/SystemAudioAppChoice.swift` を以下で新規作成。

```swift
import Foundation
import ScreenCaptureKit

protocol RunningApplicationLike {
    var processID: pid_t { get }
    var applicationName: String { get }
    var bundleIdentifier: String { get }
}

extension SCRunningApplication: RunningApplicationLike {}

enum AppChoice: Hashable {
    case wholeDisplay
    case app(processID: pid_t)
}

struct AppChoiceLabel: Hashable {
    let choice: AppChoice
    let displayName: String
}

func makeChoices(from apps: [RunningApplicationLike]) -> [AppChoiceLabel] {
    var labels: [AppChoiceLabel] = [
        AppChoiceLabel(choice: .wholeDisplay,
                       displayName: "ディスプレイ全体（すべてのシステム音声）")
    ]
    var seen = Set<pid_t>()
    for app in apps {
        guard !seen.contains(app.processID) else { continue }
        seen.insert(app.processID)

        let name: String
        if !app.applicationName.isEmpty {
            name = app.applicationName
        } else if !app.bundleIdentifier.isEmpty {
            name = app.bundleIdentifier
        } else {
            name = "不明なアプリ (PID \(app.processID))"
        }
        labels.append(AppChoiceLabel(choice: .app(processID: app.processID),
                                     displayName: name))
    }
    return labels
}
```

- [ ] **Step 1.5: pbxproj に `SystemAudioAppChoice.swift` を登録**

ID は `A100001B` / `A200000E` を使う。

(a) `Begin PBXBuildFile section` の Step 1.2 で追加した行の直後にもう 1 行追加:

```
		A100001B /* SystemAudioAppChoice.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000E /* SystemAudioAppChoice.swift */; };
```

(b) `Begin PBXFileReference section` の Step 1.2 で追加した行の直後にもう 1 行追加:

```
		A200000E /* SystemAudioAppChoice.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SystemAudioAppChoice.swift; sourceTree = "<group>"; };
```

(c) `A5000003 /* Models */` グループの `children` 配列、`A200000B /* SystemAudioManager.swift */` の直後に追加:

```
				A200000E /* SystemAudioAppChoice.swift */,
```

(d) `A7000001 /* Sources */` (アプリ本体ターゲットの `PBXSourcesBuildPhase`) の `files` 配列、`A1000009 /* SystemAudioManager.swift in Sources */` の直後に追加:

```
				A100001B /* SystemAudioAppChoice.swift in Sources */,
```

- [ ] **Step 1.6: テストが全件通過することを確認**

```bash
xcodebuild test -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/SystemAudioAppChoiceTests 2>&1 | tail -30
```

期待: 5 件すべて PASS (` Test Suite 'SystemAudioAppChoiceTests' passed`)。

- [ ] **Step 1.7: コミット**

```bash
git add SummaryTalk/Models/SystemAudioAppChoice.swift \
        SummaryTalkTests/SystemAudioManagerTests.swift \
        SummaryTalk.xcodeproj/project.pbxproj
git commit -m "feat: add AppChoice generation logic for system audio picker"
```

---

## Task 2: `SystemAudioManager` に状態・エラー種別・権限注入を追加

**Files:**
- Modify: `SummaryTalk/Models/SystemAudioManager.swift`
- Modify: `SummaryTalkTests/SystemAudioManagerTests.swift` (テスト追加)

- [ ] **Step 2.1: テストを追加 (権限拒否で `.permissionDenied` になることを検証)**

`SummaryTalkTests/SystemAudioManagerTests.swift` の末尾 (最後の `}` の前) に以下のテストクラスを追加。

```swift
@MainActor
final class SystemAudioManagerTests: XCTestCase {
    func testRefreshSetsPermissionDeniedWhenPreflightFails() async {
        var requestCalled = false
        let manager = SystemAudioManager(
            permissionCheck: { false },
            requestPermission: { requestCalled = true }
        )

        await manager.refreshAvailableApps()

        XCTAssertEqual(manager.lastErrorKind, .permissionDenied)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.isRefreshing, "refresh完了後は isRefreshing が false に戻る")
        XCTAssertTrue(requestCalled, "preflight 失敗時は requestPermission が呼ばれる")
        XCTAssertTrue(manager.availableApps.isEmpty)
    }
}
```

- [ ] **Step 2.2: テストをビルドして失敗を確認**

```bash
xcodebuild test -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/SystemAudioManagerTests 2>&1 | tail -40
```

期待: コンパイルエラー (`extra arguments at positions #1, #2 in call` / `cannot find 'permissionDenied' in scope` / `value of type 'SystemAudioManager' has no member 'lastErrorKind'` 等)。

- [ ] **Step 2.3: `SystemAudioManager.swift` を全面更新**

`SummaryTalk/Models/SystemAudioManager.swift` を以下で **置き換え** (元のロジックは保持しつつ、`init`/`refreshAvailableApps`/`startCapturing` を改修)。

```swift
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
            errorMessage = "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で許可してください。"
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
            errorMessage = "画面収録の権限がありません。システム設定 > プライバシーとセキュリティ > 画面収録 で許可してください。"
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

        do {
            try await stream?.stopCapture()
        } catch {
            lastErrorKind = .captureFailed
            errorMessage = "キャプチャ停止エラー: \(error.localizedDescription)"
        }

        stream = nil
        streamOutput = nil
        audioConverter = nil
        isCapturing = false
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
```

- [ ] **Step 2.4: テストが通ることを確認**

```bash
xcodebuild test -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/SystemAudioManagerTests 2>&1 | tail -30
```

期待: `SystemAudioManagerTests` の 1 件、`SystemAudioAppChoiceTests` の 5 件、全 6 件 PASS。

- [ ] **Step 2.5: コミット**

```bash
git add SummaryTalk/Models/SystemAudioManager.swift \
        SummaryTalkTests/SystemAudioManagerTests.swift
git commit -m "feat: add error kind and injectable permission check to SystemAudioManager"
```

---

## Task 3: `TranscriptionManager` の API を変更 (`systemAudioManager` 引数渡しに)

**Files:**
- Modify: `SummaryTalk/Models/TranscriptionManager.swift`

このタスクは Views/ContentView の参照を一時的に壊すため、Task 4-6 完了までビルドが通らない。**コミットは Task 6 完了後にまとめて行う** (各タスクで `git add` だけしておく)。

- [ ] **Step 3.1: `TranscriptionManager` から `systemAudioManager` プロパティを削除し、API を引数渡しに変更**

`SummaryTalk/Models/TranscriptionManager.swift` の以下を編集:

(a) 30-32 行目周辺の以下を削除:

```swift
    var systemAudioManager: SystemAudioManager?
```

(b) 45 行目の `func startRecording() async {` を以下に変更:

```swift
    func startRecording(systemAudioManager: SystemAudioManager? = nil) async {
```

(c) 67 行目の `case .systemAudio: try await startSystemAudioRecording()` を以下に変更:

```swift
            case .systemAudio:
                guard let systemAudioManager else {
                    errorMessage = "システム音声マネージャが提供されていません"
                    return
                }
                try await startSystemAudioRecording(systemAudioManager: systemAudioManager)
```

(d) 109 行目の `private func startSystemAudioRecording() async throws {` を以下に変更:

```swift
    private func startSystemAudioRecording(systemAudioManager: SystemAudioManager) async throws {
```

(e) 同関数内 128-140 行目の以下のブロックを置き換え:

```swift
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
```

を以下に:

```swift
        systemAudioManager.audioBufferHandler = { [weak self] buffer in
            self?.recognitionRequest?.append(buffer)
        }

        await systemAudioManager.startCapturing()

        if let error = systemAudioManager.errorMessage {
            throw NSError(domain: "TranscriptionManager", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
        }
```

(f) `stopRecording()` 内 204-208 行目周辺の以下を変更:

```swift
        case .systemAudio:
            Task {
                await systemAudioManager?.stopCapturing()
            }
```

`stopRecording()` は引数を取らないので、`systemAudioManager` への参照を捨てる。代替として、`stopRecording` 自体に `systemAudioManager: SystemAudioManager?` 引数を追加する:

`func stopRecording() {` を `func stopRecording(systemAudioManager: SystemAudioManager? = nil) {` に変更し、上記ブロックを:

```swift
        case .systemAudio:
            if let systemAudioManager {
                Task { await systemAudioManager.stopCapturing() }
            }
```

に置き換える。

- [ ] **Step 3.2: ビルドが (Views 経路の参照欠落で) 失敗することを確認**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' build 2>&1 | tail -30
```

期待: `ControlPanel.swift` 等で `startRecording`/`stopRecording` の呼び出しが新シグネチャと噛み合わずビルド失敗。Task 5 まで進める前提でこのまま続行。

- [ ] **Step 3.3: `git add` のみ (commit はまだ)**

```bash
git add SummaryTalk/Models/TranscriptionManager.swift
```

---

## Task 4: `SystemAudioAppPicker` View を新規作成

**Files:**
- Create: `SummaryTalk/Views/SystemAudioAppPicker.swift`
- Modify: `SummaryTalk.xcodeproj/project.pbxproj`

- [ ] **Step 4.1: `SystemAudioAppPicker.swift` を新規作成**

`SummaryTalk/Views/SystemAudioAppPicker.swift` を以下で新規作成。

```swift
import SwiftUI
import AppKit
import ScreenCaptureKit

struct SystemAudioAppPicker: View {
    @Bindable var manager: SystemAudioManager
    var isDisabled: Bool = false

    @State private var hasLoadedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("対象アプリ", selection: choiceBinding) {
                    ForEach(makeChoices(from: manager.availableApps), id: \.choice) { label in
                        Text(label.displayName).tag(label.choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minWidth: 180, maxWidth: 240)
                .disabled(isDisabled || manager.isRefreshing)

                Button {
                    Task { await manager.refreshAvailableApps() }
                } label: {
                    if manager.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isDisabled || manager.isRefreshing)
                .help("対象アプリ一覧を更新")
            }

            if let kind = manager.lastErrorKind, let message = manager.errorMessage {
                errorView(kind: kind, message: message)
            }
        }
        .task {
            guard !hasLoadedOnce else { return }
            hasLoadedOnce = true
            await manager.refreshAvailableApps()
        }
    }

    private var choiceBinding: Binding<AppChoice> {
        Binding(
            get: {
                if let app = manager.selectedApp {
                    return .app(processID: app.processID)
                }
                return .wholeDisplay
            },
            set: { newValue in
                switch newValue {
                case .wholeDisplay:
                    manager.selectedApp = nil
                case .app(let pid):
                    manager.selectedApp = manager.availableApps.first { $0.processID == pid }
                }
            }
        )
    }

    @ViewBuilder
    private func errorView(kind: SystemAudioErrorKind, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            if kind == .permissionDenied {
                Button("システム設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

#Preview {
    SystemAudioAppPicker(manager: SystemAudioManager())
        .padding()
}
```

- [ ] **Step 4.2: pbxproj に `SystemAudioAppPicker.swift` を登録**

ID は `A100001C` / `A200000F` を使う。

(a) `Begin PBXBuildFile section` の Task 1.5 で追加した行の直後にもう 1 行追加:

```
		A100001C /* SystemAudioAppPicker.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000F /* SystemAudioAppPicker.swift */; };
```

(b) `Begin PBXFileReference section` の Task 1.5 で追加した行の直後にもう 1 行追加:

```
		A200000F /* SystemAudioAppPicker.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SystemAudioAppPicker.swift; sourceTree = "<group>"; };
```

(c) `A5000004 /* Views */` グループの `children` 配列、`A200000A /* IPtalkPanel.swift */` の直後に追加:

```
				A200000F /* SystemAudioAppPicker.swift */,
```

(d) `A7000001 /* Sources */` の `files` 配列、Task 1.5 で追加した `A100001B` 行の直後に追加:

```
				A100001C /* SystemAudioAppPicker.swift in Sources */,
```

- [ ] **Step 4.3: `git add` のみ**

```bash
git add SummaryTalk/Views/SystemAudioAppPicker.swift \
        SummaryTalk.xcodeproj/project.pbxproj
```

---

## Task 5: `ControlPanel` に `SystemAudioAppPicker` を組み込む

**Files:**
- Modify: `SummaryTalk/Views/ControlPanel.swift`

- [ ] **Step 5.1: `ControlPanel` を更新**

`SummaryTalk/Views/ControlPanel.swift` を以下で **置き換え**。

```swift
import SwiftUI

struct ControlPanel: View {
    @Bindable var transcriptionManager: TranscriptionManager
    @Bindable var systemAudioManager: SystemAudioManager
    @Binding var showIPtalkPanel: Bool

    var body: some View {
        HStack(spacing: 16) {
            Picker("音声ソース", selection: $transcriptionManager.audioSource) {
                ForEach(AudioSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .disabled(transcriptionManager.isRecording)

            if transcriptionManager.audioSource == .systemAudio {
                SystemAudioAppPicker(
                    manager: systemAudioManager,
                    isDisabled: transcriptionManager.isRecording
                )
            }

            Button {
                Task {
                    if transcriptionManager.isRecording {
                        transcriptionManager.stopRecording(systemAudioManager: systemAudioManager)
                    } else {
                        await transcriptionManager.startRecording(systemAudioManager: systemAudioManager)
                    }
                }
            } label: {
                Label(
                    transcriptionManager.isRecording ? "停止" : "録音開始",
                    systemImage: transcriptionManager.isRecording ? "stop.fill" : (transcriptionManager.audioSource == .microphone ? "mic.fill" : "speaker.wave.2.fill")
                )
                .frame(minWidth: 100)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(transcriptionManager.isRecording ? .red : .accentColor)

            Button {
                transcriptionManager.clearText()
            } label: {
                Label("クリア", systemImage: "trash")
            }
            .controlSize(.large)
            .disabled(transcriptionManager.transcribedText.isEmpty)

            Divider()
                .frame(height: 24)

            Button {
                withAnimation {
                    showIPtalkPanel.toggle()
                }
            } label: {
                Label("IPtalk", systemImage: "network")
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(showIPtalkPanel ? .blue : nil)

            Spacer()

            Text("\(transcriptionManager.transcribedText.count) 文字")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    await transcriptionManager.saveToFile()
                }
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            .disabled(transcriptionManager.transcribedText.isEmpty)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    ControlPanel(
        transcriptionManager: TranscriptionManager(),
        systemAudioManager: SystemAudioManager(),
        showIPtalkPanel: .constant(false)
    )
    .frame(width: 800)
}
```

- [ ] **Step 5.2: `git add` のみ**

```bash
git add SummaryTalk/Views/ControlPanel.swift
```

---

## Task 6: `ContentView` で `SystemAudioManager` の所有権を上げる + 一括ビルド検証 + コミット

**Files:**
- Modify: `SummaryTalk/ContentView.swift`

- [ ] **Step 6.1: `ContentView` を更新**

`SummaryTalk/ContentView.swift` を以下で **置き換え**。

```swift
import SwiftUI

struct ContentView: View {
    @State private var transcriptionManager = TranscriptionManager()
    @State private var systemAudioManager = SystemAudioManager()
    @State private var iptalkManager = IPtalkManager()
    @State private var showIPtalkPanel = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TranscriptView(transcriptionManager: transcriptionManager)
                Divider()
                ControlPanel(
                    transcriptionManager: transcriptionManager,
                    systemAudioManager: systemAudioManager,
                    showIPtalkPanel: $showIPtalkPanel
                )
            }

            if showIPtalkPanel {
                Divider()
                IPtalkPanel(
                    iptalkManager: iptalkManager,
                    textToSend: $transcriptionManager.transcribedText
                )
                .frame(width: 300)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

#Preview {
    ContentView()
}
```

(注: 旧コードの `onChange` の空ボディはデッドコードだったので削除した)

- [ ] **Step 6.2: アプリ全体のビルド検証**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

期待: `** BUILD SUCCEEDED **`。

- [ ] **Step 6.3: テスト全件再実行**

```bash
xcodebuild test -project SummaryTalk.xcodeproj -scheme SummaryTalk \
  -destination 'platform=macOS' 2>&1 | tail -30
```

期待: `Test Suite 'All tests' passed` (既存の `IPtalkManagerTests` 4 件 + 新規 6 件 = 10 件)。

- [ ] **Step 6.4: Task 3〜6 の変更をまとめてコミット**

```bash
git add SummaryTalk/ContentView.swift
git commit -m "feat: wire system audio app picker into ControlPanel and ContentView"
```

`git status` で working tree が clean になっていることを確認。

---

## Task 7: 手動 UX 確認 (アプリ起動・実機テスト)

ユニットテストでは UI と権限フローを検証できないため、Xcode から実機ビルドして以下のシナリオを通す。

- [ ] **Step 7.1: Xcode から `SummaryTalk` スキームで Run**

期待: アプリが起動し、初期表示でデフォルト「マイク」ソース。**画面収録権限プロンプトが出ない** (まだ refresh していないので)。

- [ ] **Step 7.2: 音声ソースを「システム音声」に切り替え**

期待:
- `ControlPanel` 右側にピッカー (「ディスプレイ全体（すべてのシステム音声）」が選択済み) と更新ボタンが表示される
- 初回切り替え時に画面収録権限プロンプト (システム由来) が出る or `permissionDenied` 状態でエラー表示 +「システム設定を開く」ボタン

権限を許可してアプリを再起動。

- [ ] **Step 7.3: Zoom (または Teams 等) を起動してから更新ボタン (⟳) を押下**

期待: ピッカーに Zoom が表示される。Zoom を選択して「録音開始」を押し、Zoom 上の発話が文字起こしされることを確認。

- [ ] **Step 7.4: 「ディスプレイ全体」に戻して「録音開始」**

期待: システム音声全体が拾われて文字起こしされる。録音停止できる。

- [ ] **Step 7.5: マイクに戻して「録音開始」**

期待: 既存通り動作。SystemAudio が走っていない (CPU 負荷なし) こと。

- [ ] **Step 7.6: 確認結果を作業者がユーザーに報告**

何が動いて何が動かなかったか、画面録画やスクリーンショットがあればそれも添えて報告する。問題があれば修正タスクを起こす。

---

## 完了基準

- 全 10 件のユニットテストが PASS
- アプリがビルド成功し、システム音声モードで対象アプリピッカーが UI に表示される
- Zoom 等のアプリを選択して文字起こしできる
- 「ディスプレイ全体」フォールバックが正常に動く
- 画面収録権限なしでエラー表示+「システム設定を開く」ボタンが機能する
