# システム音声キャプチャ対象アプリ選択 UI 設計

- 日付: 2026-05-16
- 対象アプリ: SummaryTalk (macOS / SwiftUI / Swift 6)
- ステータス: **実装済み**。2026-08-23 に現行実装と食い違っていた記述を訂正（末尾の「実装後の追補」を参照）

## 1. 背景と目的

`SystemAudioManager` には対象アプリを切り替えるための `availableApps` / `selectedApp` / `refreshAvailableApps()` がすでに用意されているが、どの View からも呼ばれていない。実行時はディスプレイ全体キャプチャに無条件でフォールバックしており、「Zoom の音声だけを文字起こしする」という README 記載のユースケースが UI 上は実現できていない。

本設計はこの未配線状態を解消し、ユーザーが対象アプリを能動的に選択できる UI を `ControlPanel` に組み込むことをゴールとする。

## 2. UX 要件

- 配置: `ControlPanel` 内に**インライン展開**。音声ソースが「システム音声」のときだけ右に「対象アプリ ▼」プルダウンと更新ボタン (⟳) を表示する
- アプリ一覧の取得タイミング: ユーザーが「システム音声」を選んだ瞬間に **1 回だけ** 遅延取得する。以降は手動更新ボタンが唯一の再取得手段
- デフォルトとフォールバック: 「ディスプレイ全体（すべてのシステム音声）」を**常設項目としてリスト先頭に表示**し、デフォルト選択もこれにする。明示的にアプリを選べばそれに切り替わる
- 録音中はピッカーと更新ボタンを `.disabled` にする (既存の音声ソース Picker と同じ挙動)

## 3. アーキテクチャと所有権

```
ContentView
├── @State transcriptionManager: TranscriptionManager
├── @State systemAudioManager:  SystemAudioManager   ← 新規昇格
└── @State iptalkManager:       IPtalkManager
        │
        ▼
ControlPanel(transcriptionManager:, systemAudioManager:, ...)
        │
        ├── Picker(音声ソース)        — TranscriptionManager.audioSource
        └── SystemAudioAppPicker      — 新ファイル, systemAudioManager のみ依存
                                         (audioSource == .systemAudio のときだけ表示)
```

- `SystemAudioManager` を `ContentView` の `@State` に昇格させ、`TranscriptionManager` / `IPtalkManager` と同列で扱う
- `TranscriptionManager.systemAudioManager` プロパティは**削除**し、録音開始 API には引数で渡す形に変更する（実装後のシグネチャは `startRecording(systemAudioManager:)`。対象アプリは引数ではなく `SystemAudioManager.selectedApp` から読む）
- `SystemAudioAppPicker` は `@Bindable var manager: SystemAudioManager` のみを依存に持つ単一責務の View
- `SystemAudioManager` は常時生存するが、`SCShareableContent` を呼ぶのは `refreshAvailableApps()` 実行時だけなので画面収録権限プロンプトは初期表示で出ない

## 4. データモデル

`SystemAudioManager.selectedApp: SCRunningApplication?` の `nil` を「ディスプレイ全体」を意味する正規の値として扱う。センチネル enum をモデル層に増やさず、Optional の意味論をそのまま維持する。

`Picker` の `selection` には以下の薄いラッパー enum を使う。テストから到達可能にするため `SystemAudioAppChoice.swift` (新規) に internal アクセスで定義する:

```swift
// SystemAudioAppChoice.swift
enum AppChoice: Hashable {
    case wholeDisplay
    case app(processID: pid_t)
}
```

- `availableApps` (型は後述の `RunningApplicationLike`) から `AppChoice` のリストを `makeChoices(from:)` で生成し、先頭に `wholeDisplay` を必ず差し込む
- 選択変更時に `processID` から元の `SCRunningApplication` を引いて `manager.selectedApp` に反映
- `SCRunningApplication` 自体を `Hashable` のキーに使わない理由: SC 由来オブジェクトの ID 同等性が将来的に変動した場合の影響を局所化するため

表示文字列:

- `wholeDisplay` → `"ディスプレイ全体（すべてのシステム音声）"`
- `app(processID:)` → 対応する `applicationName`。空文字列のときは `bundleIdentifier`、それも空なら `"不明なアプリ (PID xxxx)"`

## 5. データフロー

```
[ユーザー] ──「音声ソース ▼ システム音声」を選択
    │
    ▼
TranscriptionManager.audioSource が .systemAudio に変化
    │
    ▼ (.onChange in ControlPanel)
SystemAudioAppPicker が表示される
    │
    ▼ (.task — 初回のみ)
systemAudioManager.refreshAvailableApps()  ← 画面収録権限プロンプトはここで初発生
    │
    ├── 成功 → availableApps が埋まる、Picker に反映
    └── 失敗 → errorMessage 表示、Picker は「ディスプレイ全体」のみ

[ユーザー] ──「⟳」更新ボタン押下
    │
    ▼
systemAudioManager.refreshAvailableApps() を再実行（手動）

[ユーザー] ── Picker から Zoom を選択
    │
    ▼
systemAudioManager.selectedApp = (該当 SCRunningApplication)

[ユーザー] ──「録音開始」押下
    │
    ▼
TranscriptionManager.startRecording(
    systemAudioManager: systemAudioManager,
    selectedApp: systemAudioManager.selectedApp   // nil なら display 全体
)
    │
    ▼
systemAudioManager.startCapturing(app: selectedApp)
```

ポイント:

- 初回ロードのトリガーは `audioSource == .systemAudio` になった瞬間。`SystemAudioAppPicker` の `.task` で実装し、View 出現時の 1 回のみ走らせる
- 2 回目以降の表示 (マイク → システム音声 → マイク → システム音声) では再取得しない
- 録音中はピッカーと更新ボタンを `.disabled(transcriptionManager.isRecording)` にする
- `refreshAvailableApps()` は async。タップ時は `Task { await ... }` で起動し、ボタンには ProgressView をオーバーレイして二重起動を防ぐ。そのため `SystemAudioManager` に `isRefreshing: Bool` を追加する

## 6. エラー処理と権限

`SystemAudioManager` が出すエラーは 3 種類に分類して扱う。

| 種別 | 発生箇所 | UI 反映 |
|---|---|---|
| 画面収録権限なし | `refreshAvailableApps()` の前段で `CGPreflightScreenCaptureAccess()` が `false` | Picker 直下に赤字で「システム設定 > プライバシーとセキュリティ > 画面収録 で許可してください」+「システム設定を開く」ボタン |
| `SCShareableContent` の取得失敗 | `refreshAvailableApps()` の `try await` が throw | Picker 直下に赤字でエラーメッセージ + 更新ボタンで再試行可 |
| `startCapturing` の失敗 | 既存通り `errorMessage` に格納 | 既存の `TranscriptView` のエラー表示を流用 |

実装上の変更:

1. `SystemAudioManager.refreshAvailableApps()` の冒頭に権限プリフライトを追加する。プロンプトを誘発する `CGRequestScreenCaptureAccess()` は `refreshAvailableApps()` でだけ呼ぶ。`startCapturing()` 側は preflight のみで判定し、未許可なら案内だけ。プリフライトはテストで差し替え可能にするため、`SystemAudioManager` の init に `permissionCheck: () -> Bool = { CGPreflightScreenCaptureAccess() }` をデフォルト引数で受け取る形にする
2. `isRefreshing: Bool` を新設。Picker 横の更新ボタンに ProgressView を出し、二重タップを防止
3. 「システム設定を開く」ボタンは以下で実装:

   ```swift
   NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
   ```

4. 既存の `errorMessage: String?` は継続。種別判定は文字列ではなく新設の `lastErrorKind: ErrorKind?` enum を使う:

   ```swift
   // 実装時の型名は SystemAudioErrorKind
   enum SystemAudioErrorKind { case permissionDenied, listingFailed, captureFailed }
   ```

   View 側はこれを見て表示出し分けする。エラー文言は既存の日本語に揃える。

## 7. テスト方針

`SystemAudioManager` は ScreenCaptureKit / CoreGraphics の system API に強く依存しており純粋なユニットテストが難しい。現実的に効くテスト範囲を絞る。

### テストする

1. **`AppChoice` の生成ロジック**
   - `wholeDisplay` が常に先頭にある
   - 重複 `processID` が来ても 1 件に正規化される
   - `applicationName` が空のときの表示名フォールバック (`bundleIdentifier` → `"不明なアプリ (PID xxxx)"`)

   このロジックは `SystemAudioAppPicker` のプライベートな実装に閉じず、別ファイル (`SystemAudioAppChoice.swift`) のトップレベル関数 `makeChoices(from:)` に切り出して、入力 (`[RunningApplicationLike]`) → 出力 (`[AppChoice]`) のテーブルテストを書く。

2. **エラー種別の遷移**
   - `lastErrorKind` が `refreshAvailableApps` の各経路で正しく入るか
   - 権限プリフライトを差し替え可能なクロージャ `permissionCheck: () -> Bool` として注入し、`false` を返したときに `.permissionDenied` になることを確認

### テストしない (理由)

- `SCShareableContent.excludingDesktopWindows(...)` の実呼び出し — 環境依存・権限要求
- `SCStream` のキャプチャパイプライン — 同上
- 画面収録権限プロンプトの UI 動作 — システム API
- `NSWorkspace.shared.open` の遷移 — 副作用のみ

### 抽象化

`SCRunningApplication` を直接モックできないので、以下のプロトコルを導入し `SCRunningApplication` を `extension` で適合させる。`makeChoices(from:)` の引数型はこれにする:

```swift
protocol RunningApplicationLike {
    var processID: pid_t { get }
    var applicationName: String { get }
    var bundleIdentifier: String { get }
}
```

## 8. 変更ファイル一覧

| ファイル | 変更種別 | 概要 |
|---|---|---|
| `SummaryTalk/Models/SystemAudioManager.swift` | 修正 | `isRefreshing`, `lastErrorKind`, `permissionCheck` (注入可能) を追加。`refreshAvailableApps()` に権限プリフライト追加。`startCapturing` は preflight のみ (プロンプト誘発なし)。`RunningApplicationLike` プロトコル導入と `SCRunningApplication` の適合 |
| `SummaryTalk/Models/SystemAudioAppChoice.swift` | 新規 | `AppChoice` enum と `makeChoices(from: [RunningApplicationLike]) -> [AppChoice]` トップレベル関数 |
| `SummaryTalk/Models/TranscriptionManager.swift` | 修正 | `systemAudioManager` プロパティを削除。`startRecording(systemAudioManager:selectedApp:)` に署名変更。`startSystemAudioRecording` も同様 |
| `SummaryTalk/Views/SystemAudioAppPicker.swift` | 新規 | Picker + 更新ボタン + 権限/エラー表示 + 「システム設定を開く」ボタン |
| `SummaryTalk/Views/ControlPanel.swift` | 修正 | 引数に `systemAudioManager` 追加。`audioSource == .systemAudio` のとき `SystemAudioAppPicker` をインライン表示 |
| `SummaryTalk/ContentView.swift` | 修正 | `@State systemAudioManager: SystemAudioManager` を追加し、ControlPanel に渡す |
| `SummaryTalkTests/SystemAudioManagerTests.swift` | 新規 | `makeChoices` のテーブルテスト + `lastErrorKind` の権限拒否ケース |

非変更ファイル: `IPtalkManager.swift`, `IPtalkPanel.swift`, `TranscriptView.swift`, `Info.plist`, `SummaryTalk.entitlements`

## 9. 実装順序

各ステップでビルドが通ることを保証する順序:

1. `RunningApplicationLike` プロトコル + `SystemAudioAppChoice.swift` (純粋ロジック、テストも同時に追加)
2. `SystemAudioManager` の `isRefreshing` / `lastErrorKind` / `permissionCheck` / プリフライト分離
3. `TranscriptionManager` の API 変更 (`systemAudioManager` プロパティ削除 + 引数受け渡し)
4. `SystemAudioAppPicker` 新規追加
5. `ControlPanel` に `SystemAudioAppPicker` を組み込み
6. `ContentView` で `SystemAudioManager` の所有権を上げる

---

## 実装後の追補（2026-08-23）

この設計書はピッカー UI の配線を対象としており、その下にある音声変換パスには踏み込んでいない。実装・修正を経て判明した、壊しやすい制約を記録しておく。

**バッファの読み出し.** `AudioStreamOutput` は `CMSampleBuffer` を `withAudioBufferList` で読み、`AVAudioFormat` は実際の ASBD から組み立てる。float32 / 非インターリーブと決め打ちしたり、フレーム数を「全体バイト数 ÷ フレームあたりバイト数」で求めたりしてはいけない（後者は全チャンネルを 1 フレームずつと数えるため、ステレオで長さが倍になり片チャンネルが未初期化になる）。

**リサンプリング.** `AVAudioConverter.convert(to:from:)` を使ってはいけない。サンプルレート変換に対応しておらず、`outputBuffer.frameCapacity >= inputBuffer.frameLength` のアサートで**プロセスごと停止する**（Swift の `catch` では捕捉できない）。プル型の `convert(to:error:withInputFrom:)` を使う。`SCStreamConfiguration.sampleRate = 16000` が効いている間は等価フォーマット経路に入るため表面化しないが、48 kHz が届いた瞬間に落ちる。

**バッファの寿命.** `bufferListNoCopy` で作ったバッファは `withAudioBufferList` を抜けた時点で無効になる。ハンドラに渡す前に必ずコピーを取る（フォーマットが一致するパススルー経路も例外ではない）。

**停止の検出.** `SCStream` は `Sendable` ではなく、デリゲートを弱参照で保持する。`didStopWithError` は `Task { @MainActor }` を経由して着弾するため、意図的な停止の後や次のストリーム開始後に届きうる。専用の `StreamStopObserver` が `streamGeneration` トークンを運び、世代が一致しない通知を捨てる。真偽値フラグでは `defer` が先に戻るため機能しない。

**テストの入口.** `SCStream` はユニットテストで生成できないため、変換パスは `AudioStreamOutput.process(sampleBuffer:)` として切り出してある。`AudioStreamOutputTests` が合成 `CMSampleBuffer` で駆動している。
