# Changelog

このプロジェクトの注目すべき変更を記録します。
形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) に従います。

## [Unreleased]

### Added

- **本物の IPtalk と通信できるプロトコル互換実装**（栗田茂明氏作 IPtalk）。1ch あたり 6 ポート（表示 6711 / モニタ 6712 / 「送」修正 6713 / メンバ応答 6718 / メンバ探索 6722 / Undo 6723）に同時にリスナを張り、`N` ch では各ポートに `+100×(N-1)` を加算。
- `IPtalkPanel` に「チャンネル」Picker (1–9)、「ハンドル名」テキストフィールド、「メンバー一覧」、「認識結果を自動送信」トグルを追加。設定は `@AppStorage` で永続化。
- 音声認識が確定（`isFinal == true`）した行を自動的に IPtalk 表示部（6711）へブロードキャストする `TranscriptionManager.onFinalizedLine` コールバック。差分のみを送信し、新しいセッション開始 / `clearText()` で内部状態をリセット。
- メンバ探索の往復処理。6722 で他クライアントからの問い合わせを受けると 6718 でユニキャスト応答し、自分自身も `startListening()` 完了時に 1 度ブロードキャストする。
- システム音声キャプチャ対象のアプリを選択する `SystemAudioAppPicker` UI（Zoom / Teams / Meet 等を一覧から選択。「ディスプレイ全体」も選択可能）。
- `SystemAudioManager.lastErrorKind`（`SystemAudioErrorKind`）— UI が permission / listing / capture 失敗を区別して対処できるようにする。
- `IPtalkProtocolTests`（14 件）と `IPtalkManagerTests`（4 件）。ポート算術、Shift-JIS 往復、メンバ探索ペイロード、リスナ ライフサイクル、ポート再利用挙動を網羅。

### Changed

- IPtalk の文字コードを Shift-JIS に統一し、ペイロードを「プレーンテキスト + LF」へ変更（旧実装の独自ヘッダを廃止）。絵文字など Shift-JIS 非対応文字は `?` への lossy 変換でフレームを保つ。
- `IPtalkManager` を `Models/IPtalk/` 配下に分割。`IPtalkProtocol.swift`（純粋関数: ポート算術 / encode / decode / メンバ探索ペイロード）と `IPtalkManager.swift`（ネットワーク責務）。Phase 2 で wire format を差し替える際の改修範囲を局所化。
- システム音声ソース切り替え時にアプリ一覧を失わないように、`SystemAudioManager` が選択状態を保持し続けるよう変更。
- `SystemAudioManager.startCapturing()` 成功時に過去のエラー状態を確実にクリア。
- UDP 送信失敗時に `errorMessage` を「送信失敗: {error}」として通知（`isConnected` は維持）。

### Fixed

- システム音声ストリーム停止後に `audioBufferHandler` が残り続けて次回キャプチャに影響する問題。
- 同一エラーを連続して出力していたキャプチャエラーの重複を抑止。
- 画面収録権限を初回付与した直後に「再起動が必要」というヒントをエラーメッセージに含めるよう改善。
- `IPtalkManager` 内の `NWConnection` 送信クロージャでの強参照保持（自己解決はしていたものの retain cycle を明示的に解消）。
- `clearReceivedText()` の意味漏れ — 表示部（`.display`）以外の履歴まで消していた問題を修正し、`receivedText` 計算プロパティが見せる範囲のみクリアするよう挙動を一致させた。

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
- `NWParameters.udp.allowLocalEndpointReuse = true` のため、同一マシン上の 2 つの SummaryTalk は同チャンネルで共存する（spec §6 のポート競合エラーは事実上発火しない）。意図的な挙動として `testSameChannelManagersCoexistDueToPortReuse` でピン留め。
- `endpointHost(_:)` が dual-stack 環境で IPv4-mapped IPv6 形式（`::ffff:192.168.x.x`）を返すケースがあり、同一ピアが別表現でメンバー一覧に二重登録されうる。
- ブロードキャスト先は `255.255.255.255` 固定。サブネット限定ブロードキャスト（`192.168.x.255`）が必要な環境では届かない可能性。
