# Changelog

このプロジェクトの注目すべき変更を記録します。
形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [Unreleased]

### Added

- **本物の IPtalk と通信できるプロトコル互換実装**（栗田茂明氏作 IPtalk）。1ch あたり 6 ポート（表示 6711 / モニタ 6712 / 「送」修正 6713 / メンバ応答 6718 / メンバ探索 6722 / Undo 6723）に同時にリスナを張り、`N` ch では各ポートに `+100×(N-1)` を加算。
- `IPtalkPanel` に「チャンネル」Picker (1–9)、「ハンドル名」テキストフィールド、「メンバー一覧」、「認識結果を自動送信」トグルを追加。設定は `@AppStorage` で永続化。
- 音声認識が確定（`isFinal == true`）した行を自動的に IPtalk 表示部（6711）へブロードキャストする `TranscriptionManager.onFinalizedLine` コールバック。差分のみを送信し、新しいセッション開始 / `clearText()` で内部状態をリセット。
- メンバ探索の往復処理。6722 で他クライアントからの問い合わせを受けると 6718 でユニキャスト応答し、自分自身も `startListening()` 完了時に 1 度ブロードキャストする。
- ブロードキャスト先をサブネット限定アドレスとして算出する処理。有効な IPv4 インターフェース（`en*` を優先し、ループバックとリンクローカル 169.254.x.x は除外）から `ip | ~netmask` を求める。判定は純粋関数 `IPtalkProtocol.broadcastAddress(ip:netmask:)` / `preferredBroadcast(interfaces:)`、インターフェース列挙は `IPtalkManager.systemInterfaces()`（`getifaddrs`）で、後者は `interfaceProvider` によりテストから差し替えられる。
- システム音声キャプチャ対象のアプリを選択する `SystemAudioAppPicker` UI（Zoom / Teams / Meet 等を一覧から選択。「ディスプレイ全体」も選択可能）。
- `SystemAudioManager.lastErrorKind`（`SystemAudioErrorKind`）— UI が permission / listing / capture 失敗を区別して対処できるようにする。
- ユニットテスト計 89 件 — `IPtalkProtocolTests`（35）/ `IPtalkManagerTests`（21）/ `TranscriptionManagerTests`（18）/ `SystemAudioAppChoiceTests`（6）/ `SystemAudioManagerTests`（6）/ `AudioStreamOutputTests`（3）。ポート算術、Shift-JIS 往復、メンバ探索ペイロード、リスナ ライフサイクル、ポート競合時のロールバック、認識セッションのライフサイクル、オーディオ変換を網羅。
- `AudioStreamOutputTests` — 合成 `CMSampleBuffer` を用いて、ステレオ→モノラル変換時のフレーム数、パススルー時のバッファ寿命、連続リサンプリングの安定性を検証。テストから駆動できるよう `AudioStreamOutput.process(sampleBuffer:)` を切り出した（`SCStream` はユニットテストで生成できないため）。
- `Info.plist` に `NSLocalNetworkUsageDescription` を追加し、同一ネットワーク上の端末と通信する旨を明示。
- IPtalk パネルに、送信内容が暗号化されず LAN へブロードキャストされる旨の注意書きを表示。

### Changed

- IPtalk の文字コードを Shift-JIS に統一し、ペイロードを「プレーンテキスト + LF」へ変更（旧実装の独自ヘッダを廃止）。絵文字など Shift-JIS 非対応文字は `?` への lossy 変換でフレームを保つ。
- `IPtalkManager` を `Models/IPtalk/` 配下に分割。`IPtalkProtocol.swift`（純粋関数: ポート算術 / encode / decode / メンバ探索ペイロード）と `IPtalkManager.swift`（ネットワーク責務）。Phase 2 で wire format を差し替える際の改修範囲を局所化。
- システム音声ソース切り替え時にアプリ一覧を失わないように、`SystemAudioManager` が選択状態を保持し続けるよう変更。
- `SystemAudioManager.startCapturing()` 成功時に過去のエラー状態を確実にクリア。
- UDP 送信失敗時に `errorMessage` を「送信失敗: {error}」として通知（`isConnected` は維持）。
- ブロードキャストの宛先が `255.255.255.255` 固定ではなくなった（上記）。ネットワークスタックが導出アドレスへの送信を拒否した場合は 1 度だけ `255.255.255.255` で再送し、以降はそのセッション中ずっと `255.255.255.255` を使う（`broadcastFallbackEngaged`）。フラグは再接続時にリセットされ、次のセッションで導出をやり直す。
- 受信フローの保持上限 `maxInboundConnections` とアイドル回収時間 `inboundIdleTimeout` を `static let` からインスタンスプロパティへ変更。既定値は 64 / 60 秒のままで、UI には公開していない。
- 音声認識を確定結果ごとに再武装し、開始 / 停止を直列化。システム音声の起動中に停止しても録音が復活しないようにした。
- `IPtalkManager.startListening()` が全リスナの `.ready` を待ってから接続完了とするよう変更。並行呼び出しは 1 つだけが成立し、古い接続世代のタイムアウトは無視される。
- テストターゲットの署名設定（`DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY`）をアプリ本体に合わせた。
- `SystemAudioManager` の `SCStreamDelegate` 実装を専用の `StreamStopObserver` へ分離（`SCStream` が `Sendable` でないため世代トークンを受け渡す）。不要になった `NSObject` 継承を削除。

### Fixed

- dual-stack 環境で同一ピアがメンバー一覧に二重登録される問題。IPv4-mapped IPv6（`::ffff:192.168.1.5`、および同じバイト列の 16 進表記 `::ffff:c0a8:105`）を `IPtalkProtocol.canonicalHost(_:)` が IPv4 表記へ畳み、インターフェース ゾーン（`fe80::1%en0` の `%en0`）も除去して送信元の識別子を一意にする。
- システム音声ストリーム停止後に `audioBufferHandler` が残り続けて次回キャプチャに影響する問題。
- 同一エラーを連続して出力していたキャプチャエラーの重複を抑止。
- 画面収録権限を初回付与した直後に「再起動が必要」というヒントをエラーメッセージに含めるよう改善。
- `IPtalkManager` 内の `NWConnection` 送信クロージャでの強参照保持（自己解決はしていたものの retain cycle を明示的に解消）。
- `clearReceivedText()` の意味漏れ — 表示部（`.display`）以外の履歴まで消していた問題を修正し、`receivedText` 計算プロパティが見せる範囲のみクリアするよう挙動を一致させた。
- **システム音声が 16 kHz 以外で届くとアプリごとクラッシュする問題。** `AVAudioConverter.convert(to:from:)` はサンプルレート変換に対応しておらず、`outputBuffer.frameCapacity >= inputBuffer.frameLength` のアサートでプロセスを停止する（Swift の `catch` では捕捉できない）。プル型の `convert(to:error:withInputFrom:)` に置き換え、入力フォーマットが変化した場合はコンバータを作り直す。
- **ステレオのシステム音声が二重の長さ・片チャンネル未初期化のまま音声認識に渡っていた問題。** ASBD を無視して float32 / 非インターリーブと決め打ちし、フレーム数を「全体バイト数 ÷ フレームあたりバイト数」で求めてブロックバッファ全体を channel 0 へコピーしていた。`withAudioBufferList` と ASBD 由来のフォーマットで読み出すよう変更。
- パススルー経路が no-copy バッファをそのまま渡していた問題。`CMSampleBuffer` の寿命が尽きると解放済みメモリを指すため、コピーを取るようにした。
- 意図的なキャプチャ停止が「ストリームエラー」として報告され、再開直後のセッションを巻き添えで停止させうる問題。`isStoppingIntentionally` フラグは `didStopWithError` の `Task { @MainActor }` ホップより前に `defer` で戻るため機能していなかった。世代トークン方式に統一。
- IPtalk の送信データグラムが送出されないことがある問題。`NWConnection` を保持する参照がなく `.ready` 到達前に解放（＝強制キャンセル）されうるため、送信完了まで保持する（上記「送信クロージャの retain cycle 解消」を、所有権をマネージャ側に移す形で見直し）。
- IPtalk の受信で、同一ピアが同じ送信元ポートから連続送信した行を取りこぼす問題。1 データグラムごとに接続をキャンセルしていたのを受信ループの再武装に変更。あわせて、送信元ポートが毎回変わるピア（本アプリ自身が該当）で接続が際限なく増えないよう、アイドル超過と LRU による回収を追加（上限 64 / 60 秒）。
- 録音停止時に、スロットル待ち（0.25 秒）の認識結果が破棄されて文字起こしの末尾が欠ける問題。
- 確定結果の直後に停止すると、確定済みの行が 1 つ前の partial に巻き戻り、句点や修正が失われる問題。
- 認識セッション再武装時に旧 `SFSpeechAudioBufferRecognitionRequest` を `endAudio()` せず放置し、旧タスクが録音時間上限まで残っていた問題。
- `RecognitionRequestBox.append` がロック解放後に append していたため、再武装の境界でオーディオバッファが終了済みリクエストに落ちて失われる競合。
- `receivedLines` が無制限に増加する問題（上限 2000 行）。`receivedText` は SwiftUI の描画ごとに全履歴を連結するため、実測上の負荷にもなっていた。
- テストバンドルが無署名だったため hardened runtime のホストアプリに `dlopen` できず、`xcodebuild ... test` が 1 件も実行できなかった問題（`different Team IDs`）。

### Removed

- 旧 `SummaryTalk/Models/IPtalkManager.swift`（独自 `"TEXT"` ヘッダ + 4 バイト長 + Shift-JIS 本文を UDP 15000 へブロードキャストする実装）と対応する `IPtalkManagerTests.swift`。本物の IPtalk と互換性がなく、別 SummaryTalk 同士の通信専用となっていたため新形式へ置換。

### Security

- 変更なし。エンタイトルメント（`network.client` / `network.server` / `audio-input` / `files.user-selected.read-write`）と `Info.plist` の使用目的記述は据え置き。

### Documentation

- IPtalk 互換化の設計書（`docs/superpowers/specs/2026-05-16-iptalk-protocol-compat-design.md`）と実装計画（`docs/superpowers/plans/2026-05-16-iptalk-protocol-compat.md`）。Phase 1 の妥協点と Phase 2 で要対応の項目を明示。
- システム音声アプリ ピッカーの設計書 / 実装計画（`docs/superpowers/specs/`、`docs/superpowers/plans/`）。
- `CLAUDE.md` を新規作成。ビルド / テストコマンド、3 マネージャ間のデータフロー、IPtalk の wire format、サンドボックス & 権限の落とし穴を集約。

### Known limitations (Phase 2 で対応予定)

- `memberDiscoveryRequest` / `memberDiscoveryReply` のペイロードは公開仕様の範囲で実装（ハンドル名の Shift-JIS バイト列）。本物 IPtalk とのパケットキャプチャ次第で形式の調整が必要。
- 6711 表示部パケットのヘッダ有無、Undo / 修正パケットの正確な書式は同様に検証待ち。
- `NWParameters.udp.allowLocalEndpointReuse = true` により `NWListener` の生成自体は成功するが、同一マシンで同チャンネルを取り合うと一部ポート（特にメンバ探索 6722）が `.ready` に到達しないため、2 つ目の SummaryTalk は spec §6 のロールバックに入る。`testSameChannelSecondManagerRollsBackOnPortConflict` でピン留め。
- 受信フローの保持上限は既定 64、アイドル回収は既定 60 秒（`IPtalkManager` のインスタンスプロパティで変更できるが UI には出していない）。多数のピアが同時に送信する環境では最も古いフローから切断される（次のデータグラムで再確立されるため通信自体は継続する）。
- サブネット限定ブロードキャスト宛の送信を Network.framework が許可するかは実機未検証。拒否された場合は `255.255.255.255` へ自動フォールバックするので通信は継続するが、フォールバックが起きたことは UI にもログにも出ない。
