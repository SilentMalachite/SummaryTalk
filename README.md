# SummaryTalk

[日本語](#summarytalk-日本語) | [English](#summarytalk-english)

---

## SummaryTalk (日本語)

SummaryTalkは、macOS向けのリアルタイム文字起こし（要約筆記）支援アプリケーションです。
マイク音声だけでなく、Zoomなどのシステム音声の文字起こしにも対応しており、IPtalkプロトコルを用いた外部機器との連携も可能です。

## 主な機能

- **リアルタイム文字起こし**: AppleのSpeechフレームワークを使用し、高精度な日本語音声認識を行います。
- **システム音声キャプチャ**: ScreenCaptureKitを使用して、Zoom、Microsoft Teams、Google MeetなどのWeb会議システムの音声を直接キャプチャして文字起こしできます。
- **IPtalk互換機能**: UDPポート15000（Shift-JIS）を使用し、IPtalkと互換性のあるLAN内放送・受信が可能です。
- **テキスト編集・保存**: 認識されたテキストをその場で編集し、テキストファイルとして保存できます。
- **Swift 6 / SwiftUI**: 最新のSwift 6の並行処理（Strict Concurrency）に対応しています。

## 動作環境

- **OS**: macOS 14.0 (Sonoma) 以上
- **ハードウェア**: Apple Silicon (M1/M2/M3) または Intel Mac

## セットアップと使用方法

1. **プロジェクトのビルド**:
   - `SummaryTalk.xcodeproj`をXcodeで開きます。
   - 適切な開発チーム（Signing & Capabilities）を選択します。
   - ビルドして実行します。

2. **権限の許可**:
   - 初回起動時に「マイク」「音声認識」「画面収録」の権限を求められます。システム音声のキャプチャには「画面収録（Screen Recording）」の権限が必要です（実際に画面を録画するわけではなく、音声を抽出するために必要です）。

3. **文字起こしの開始**:
   - **マイク音声**: 「マイク」を選択して「録音開始」をクリックします。
   - **Zoom等の音声**: 「システム音声（Zoom等）」を選択して「録音開始」をクリックします。
     - *注: 文字起こしを開始する前にZoomなどのアプリケーションが起動している必要があります。*

4. **IPtalk連携**:
   - 「IPtalkパネルを表示」をオンにします。
   - 「接続」をクリックすると、LAN内での送受信が可能になります。

## 開発情報

- **言語**: Swift 6
- **フレームワーク**: SwiftUI, Speech, ScreenCaptureKit, Network
- **アーキテクチャ**: Observableプロトコルを使用したMVVMライクな構成

## 免責事項

本ソフトウェアは開発中（Beta）のものです。音声認識の精度は通信環境や周囲の騒音に依存します。

---

## SummaryTalk (English)

SummaryTalk is a real-time transcription (Summary Writing/要約筆記) support application for macOS.
It supports transcription from not only microphone input but also system audio from apps like Zoom, and integrates with other devices using the IPtalk protocol.

## Key Features

- **Real-time Transcription**: High-precision Japanese speech recognition using Apple's Speech framework.
- **System Audio Capture**: Directly capture and transcribe audio from web conferencing systems like Zoom, Microsoft Teams, and Google Meet using ScreenCaptureKit.
- **IPtalk Compatibility**: Support for LAN-based broadcasting and receiving compatible with IPtalk (UDP port 15000, Shift-JIS encoding).
- **Text Editing & Saving**: Edit recognized text on the fly and save it as a text file.
- **Swift 6 / SwiftUI**: Built with the latest Swift 6 features including Strict Concurrency.

## Requirements

- **OS**: macOS 14.0 (Sonoma) or later
- **Hardware**: Apple Silicon (M1/M2/M3) or Intel Mac

## Setup and Usage

1. **Build the Project**:
   - Open `SummaryTalk.xcodeproj` in Xcode.
   - Select your development team in "Signing & Capabilities".
   - Build and run the app.

2. **Grant Permissions**:
   - On first launch, the app will request access to "Microphone", "Speech Recognition", and "Screen Recording". Screen Recording permission is required to capture system audio (it does not record your screen, but extracts audio data).

3. **Start Transcription**:
   - **Microphone**: Select "マイク (Microphone)" and click "録音開始 (Start Recording)".
   - **Zoom/System Audio**: Select "システム音声 (System Audio)" and click "録音開始 (Start Recording)".
     - *Note: The target application (e.g., Zoom) must be running before starting transcription.*

4. **IPtalk Integration**:
   - Toggle "IPtalkパネルを表示 (Show IPtalk Panel)".
   - Click "接続 (Connect)" to enable LAN communication.

## Development

- **Language**: Swift 6
- **Frameworks**: SwiftUI, Speech, ScreenCaptureKit, Network
- **Architecture**: MVVM-like structure using the Observable protocol.

## Disclaimer

This software is currently in Beta. Transcription accuracy depends on the communication environment and ambient noise.

## License

[MIT License](LICENSE)
