# SummaryTalk

[日本語](#summarytalk-日本語) | [English](#summarytalk-english)

---

## SummaryTalk (日本語)

SummaryTalk は、macOS 向けのリアルタイム文字起こし（要約筆記）支援アプリケーションです。
マイク音声に加え、Zoom などのシステム音声の文字起こしに対応し、栗田茂明氏作 **IPtalk** とプロトコル互換の UDP 通信で外部機器・他クライアントとの連携も可能です。

## 主な機能

- **リアルタイム文字起こし**: Apple の Speech フレームワーク（`SFSpeechRecognizer`, ロケール `ja-JP`、対応機ではオンデバイス）で高精度な日本語音声認識を行います。部分認識結果は 0.25 秒間隔にスロットルされ、UI 更新の負荷を抑えています。
- **システム音声キャプチャ**: `ScreenCaptureKit` を使用して、Zoom / Microsoft Teams / Google Meet などの音声を直接キャプチャします。**アプリ単位の選択ピッカー**から対象を選ぶか、「ディスプレイ全体」を選択できます。取り込んだ音声は内部で 16 kHz / モノラル / float32 に変換して認識エンジンへ橋渡しします。
- **IPtalk 互換通信**: 本物の IPtalk と通信できる UDP 実装。1 ch あたり 6 ポート（表示 6711 / モニタ 6712 / 「送」修正 6713 / メンバ応答 6718 / メンバ探索 6722 / Undo 6723）を同時に張り、N ch では各ポートに `+100×(N-1)` を加算します。文字コードは **Shift-JIS**、ペイロードは「プレーンテキスト + LF」。LAN ブロードキャスト（`255.255.255.255`）で送信します。
- **チャンネル / ハンドル名 / メンバー一覧**: パネルから 1–9 のチャンネル切替、ハンドル名の設定、検出されたメンバーの一覧表示が可能。設定は `@AppStorage` に永続化されます。
- **認識結果の自動送信**: 音声認識が「確定行」になったタイミングで IPtalk 表示部（6711）へ自動ブロードキャストします（トグルで ON/OFF）。
- **テキスト編集・保存**: 認識・受信したテキストをその場で編集し、テキストファイルとして保存できます。
- **Swift 6 / SwiftUI**: Swift 6 の Strict Concurrency（complete）でビルドされ、`@MainActor @Observable` ベースの構成。

## 動作環境

- **OS**: macOS 14.0 (Sonoma) 以上
- **ハードウェア**: Apple Silicon (M1/M2/M3 以降) または Intel Mac
- **Swift / Xcode**: Swift 6.0（`SWIFT_STRICT_CONCURRENCY = complete`）

## セットアップ

1. **プロジェクトを開く**: `SummaryTalk.xcodeproj` を Xcode で開きます（SwiftPM の `Package.swift` はありません）。
2. **署名設定**: 「Signing & Capabilities」で開発チームを選択します。
3. **ビルド & 実行**: スキーム `SummaryTalk`、Destination `My Mac` でビルド・実行します。

### コマンドラインからのビルド / テスト

```bash
# Debug ビルド
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build

# 全テスト実行
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' test

# 単一テストクラス / メソッドのみ
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/IPtalkProtocolTests test
```

## 使い方

1. **権限の許可**: 初回起動時に「マイク」「音声認識」、システム音声利用時は「画面収録」の権限が求められます。画面収録は音声抽出のためにのみ使用します。
   - 画面収録権限は **初回付与後にアプリの再起動が必要** です（macOS の仕様）。
2. **入力ソースの選択**:
   - **マイク**: 「マイク」を選択して「録音開始」。
   - **システム音声（Zoom 等）**: 「システム音声」を選択し、アプリピッカーから対象アプリ（または「ディスプレイ全体」）を選んで「録音開始」。対象アプリは事前に起動しておく必要があります。
3. **IPtalk 連携**:
   - 「IPtalk パネルを表示」をオン。
   - チャンネル（1–9）とハンドル名を設定し、「接続」をクリック。
   - 「認識結果を自動送信」をオンにすると、確定した認識行が自動で表示部にブロードキャストされます。

## アーキテクチャ概要

3 つの独立した `@MainActor @Observable` マネージャを `ContentView` で配線しています。共有ストアは無く、マネージャ間は直接呼び出しと音声引き渡し用の単一クロージャだけで通信します。

- **`TranscriptionManager`** (`Models/TranscriptionManager.swift`) — Speech 認識と `AVAudioEngine`（マイク）を所有。`audioSource` が `.systemAudio` の場合は `SystemAudioManager` から受け取った音声バッファを認識リクエストに流し込みます。確定行は `onFinalizedLine` 経由で外部に伝搬。
- **`SystemAudioManager`** (`Models/SystemAudioManager.swift`) — `ScreenCaptureKit`（`SCStream`）のラッパ。アプリ単位 or ディスプレイ全体の音声をキャプチャし、内部で 16 kHz / mono / float32 に変換して `audioBufferHandler` に渡します。`lastErrorKind`（`SystemAudioErrorKind`）で permission / listing / capture の失敗を区別。
- **`IPtalkManager` + `IPtalkProtocol`** (`Models/IPtalk/`) — IPtalk 互換 UDP クライアント。`IPtalkProtocol.swift` は純粋関数（ポート算術、Shift-JIS encode/decode、メンバ探索ペイロード）で、wire format の調整はここに局所化。`IPtalkManager.swift` がリスナのライフサイクルとブロードキャストを担当します。

## テスト

`SummaryTalkTests/` に以下のテストがあります。

- `IPtalkProtocolTests` — ポート算術、Shift-JIS 往復、メンバ探索ペイロード等の純粋関数テスト。
- `IPtalkManagerTests` — リスナ ライフサイクル、ポート再利用挙動、送信失敗時のエラー通知。
- `SystemAudioManagerTests` — `RunningApplicationLike` の差し替えによる選択肢生成と権限フローのテスト。
- `TranscriptionManagerTests` — 音声ソース切替、部分結果スロットル、確定行のコールバック発火。

## 既知の制限（Phase 2 で対応予定）

- メンバ探索 (6722/6718) ペイロードはハンドル名 Shift-JIS バイト列での実装。本物の IPtalk とのパケットキャプチャ次第で形式の再調整が必要。
- 6711 表示部パケットのヘッダ有無、Undo / 修正パケットの正確な書式は同様に検証待ち。
- `NWParameters.udp.allowLocalEndpointReuse = true` のため、同一マシン上の 2 インスタンスは同一チャンネルで共存します（ポート競合エラーは発火しません）。
- ブロードキャスト先は `255.255.255.255` 固定。サブネット限定ブロードキャストが必要な環境では届かない可能性があります。
- 詳細は [`CHANGELOG.md`](CHANGELOG.md) および `docs/superpowers/specs/` の設計書を参照。

## 開発情報

- **言語**: Swift 6（Strict Concurrency: complete）
- **フレームワーク**: SwiftUI / Speech / ScreenCaptureKit / Network / AVFoundation
- **アーキテクチャ**: `Observable` プロトコルを使った MVVM ライク
- **サンドボックス**: `audio-input`, `network.client`, `network.server`, `files.user-selected.read-write`
- **UI 言語**: ユーザー向け文字列は日本語

## 免責事項

本ソフトウェアは開発中（Beta）です。音声認識の精度はネットワーク状況や周囲の騒音に依存します。IPtalk 互換実装は Phase 1 相当で、未検証の wire format がある点に注意してください。

## ライセンス

[MIT License](LICENSE)

---

## SummaryTalk (English)

SummaryTalk is a real-time transcription (要約筆記 / Summary Writing) support application for macOS.
It transcribes both microphone input and system audio (e.g. Zoom), and provides UDP communication that is **protocol-compatible with real IPtalk** (by Shigeaki Kurita) for collaboration with other IPtalk clients on the LAN.

## Key Features

- **Real-time Transcription**: High-precision Japanese speech recognition via Apple's `SFSpeechRecognizer` (locale `ja-JP`, on-device when supported). Partial results are throttled at 0.25 s to avoid UI thrashing.
- **System Audio Capture**: Capture audio from Zoom / Microsoft Teams / Google Meet etc. via `ScreenCaptureKit`. Choose a target app from the **app picker**, or capture the **entire display**. Buffers are converted internally to 16 kHz / mono / float32 before being fed to the recognizer.
- **IPtalk-compatible Communication**: Real IPtalk wire-compatible UDP. Per channel, 6 ports are bound concurrently: display 6711 / monitor 6712 / "send" correction 6713 / member-reply 6718 / member-discovery 6722 / undo 6723. Channel N adds `+100×(N-1)` to each port. Payload is **plain Shift-JIS text + LF**. Broadcasts to `255.255.255.255`.
- **Channel / Handle / Member List**: Switch among channels 1–9, set your handle name, and view discovered members. Settings are persisted via `@AppStorage`.
- **Auto-send finalized lines**: Finalized recognition lines are automatically broadcast to the IPtalk display port (6711); toggleable.
- **Text Editing & Saving**: Edit the recognized/received text inline and save it as a text file.
- **Swift 6 / SwiftUI**: Built under Swift 6 Strict Concurrency (`complete`), with `@MainActor @Observable` managers.

## Requirements

- **OS**: macOS 14.0 (Sonoma) or later
- **Hardware**: Apple Silicon (M1/M2/M3 or newer) or Intel Mac
- **Toolchain**: Swift 6.0, Xcode that supports it

## Setup

1. **Open the project**: open `SummaryTalk.xcodeproj` in Xcode (no SwiftPM `Package.swift`).
2. **Signing**: pick your development team under "Signing & Capabilities".
3. **Build & Run**: scheme `SummaryTalk`, destination `My Mac`.

### Command-line build / test

```bash
# Debug build
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build

# Full test run
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' test
```

## Usage

1. **Grant permissions**: on first launch the app asks for Microphone, Speech Recognition, and (for system audio) Screen Recording. Screen Recording is only used to extract audio — and **the app must be relaunched after the first grant** for it to take effect.
2. **Pick an input source**:
   - **Microphone**: select "マイク (Microphone)", click "録音開始 (Start)".
   - **System Audio**: select "システム音声 (System Audio)", choose a target app (or "ディスプレイ全体" / entire display) in the picker, then click "録音開始". The target app must be running beforehand.
3. **IPtalk integration**:
   - Toggle "IPtalk パネルを表示 (Show IPtalk Panel)".
   - Pick channel (1–9), set your handle name, and click "接続 (Connect)".
   - Enable "認識結果を自動送信 (Auto-send recognized lines)" to broadcast finalized lines automatically.

## Architecture

Three independent `@MainActor @Observable` managers are wired together in `ContentView`. There is no shared store — managers communicate via direct method calls and a single closure handoff for audio.

- **`TranscriptionManager`** (`Models/TranscriptionManager.swift`) — owns Speech recognition and an `AVAudioEngine` for mic input. When `audioSource == .systemAudio`, it consumes buffers handed off by `SystemAudioManager`. Finalized lines are emitted via `onFinalizedLine`.
- **`SystemAudioManager`** (`Models/SystemAudioManager.swift`) — `ScreenCaptureKit` (`SCStream`) wrapper. Captures per-app or entire-display audio, converts internally to 16 kHz / mono / float32, and pushes buffers into `audioBufferHandler`. `lastErrorKind: SystemAudioErrorKind` distinguishes permission / listing / capture failures for the UI.
- **`IPtalkManager` + `IPtalkProtocol`** (`Models/IPtalk/`) — IPtalk-compatible UDP client. `IPtalkProtocol.swift` holds pure functions (port arithmetic, Shift-JIS encode/decode, member-discovery payloads); `IPtalkManager.swift` owns listener lifecycle and broadcasting. Wire-format adjustments stay local to `IPtalkProtocol.swift`.

## Tests

Under `SummaryTalkTests/`:

- `IPtalkProtocolTests` — pure-function tests for port math, Shift-JIS round-trip, and member-discovery payloads.
- `IPtalkManagerTests` — listener lifecycle, port-reuse behavior, send-failure error propagation.
- `SystemAudioManagerTests` — picker entry construction (via `RunningApplicationLike`) and permission flow.
- `TranscriptionManagerTests` — audio-source switching, partial-result throttling, finalized-line callback.

## Known Limitations (planned for Phase 2)

- Member-discovery (6722/6718) payload is currently a Shift-JIS handle-name byte sequence; needs adjustment once we have real-IPtalk packet captures.
- The display-port (6711) header presence and the exact byte format of Undo / correction packets are likewise pending verification.
- Because `NWParameters.udp.allowLocalEndpointReuse = true`, two SummaryTalk instances on the same host can coexist on the same channel (no port-conflict errors).
- Broadcast destination is hard-coded to `255.255.255.255`; subnet-directed broadcasts (`192.168.x.255`) are not used.
- See [`CHANGELOG.md`](CHANGELOG.md) and the design docs under `docs/superpowers/specs/` for the full list.

## Development

- **Language**: Swift 6 (Strict Concurrency: `complete`)
- **Frameworks**: SwiftUI / Speech / ScreenCaptureKit / Network / AVFoundation
- **Architecture**: MVVM-like, built around the `Observable` macro
- **Sandbox entitlements**: `audio-input`, `network.client`, `network.server`, `files.user-selected.read-write`
- **UI language**: user-facing strings are in Japanese

## Disclaimer

This software is currently in Beta. Transcription accuracy depends on network conditions and ambient noise. The IPtalk-compatible implementation is at Phase 1 — some wire-format details remain unverified against real IPtalk packet captures.

## License

[MIT License](LICENSE)
