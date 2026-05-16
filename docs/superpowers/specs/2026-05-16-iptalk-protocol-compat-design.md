# IPtalk プロトコル互換化 設計書

- 日付: 2026-05-16
- 対象: `SummaryTalk/Models/IPtalkManager.swift` の全面書き換え
- 目的: 本物のIPtalk（栗田茂明氏作のパソコン要約筆記ソフト）と相互通信できる実装に置き換える

## 1. 背景と問題意識

現在の `IPtalkManager` は独自の `"TEXT"` + 4バイトLE長 + Shift-JIS本文 という形式をUDPポート **15000** にブロードキャストしている。これは本物のIPtalkとは一切互換性がない（IPtalkは 6700番台のポートを使用し、独自ヘッダを持たない）。

### 公開仕様で確認できた事実

| 項目 | 内容 | 出典 |
|---|---|---|
| トランスポート | UDP/IP ブロードキャスト | s-kurita.net 6-16-14 |
| ポート（ch1）| 6711〜6739 を機能別に使用 | s-kurita.net 6-16-14 |
| チャンネル | N ch = 6711 + 100×(N-1) スタート | NCK #08, 全体マニュアル |
| 文字コード | Shift-JIS（IPtalkはUnicode非対応） | mekiku FAQ |
| ペイロード | 「全てテキスト」 | s-kurita.net 6-16-14 |
| ログ形式 | `時刻,IP,内容` のCSV（ログ仕様で、wire formatではない） | s-kurita.net 3-7-10 |
| 12バイト時刻プレフィクス | オプション機能（「入力開始時刻を説明ページに記録」） | s-kurita.net 3-7-10 |

### 公開仕様で確認できなかった事実

- 6711(表示部)パケットに何らかのヘッダ/タグが付くのか、純粋テキストか
- メンバ探索(6718/6722)の問い合わせ・応答フォーマット
- Undo/修正パケットの正確な書式

IPtalk本体・mekiku-mともにソース非公開。 → **Phase 1 は公開仕様から推定できる範囲で実装、Phase 2 でユーザーが本物IPtalkとのパケットキャプチャを提供して微調整する** という二段階方針を採る。

### 参照URL

- [IPtalkポート番号一覧](http://s-kurita.net/manual/9i9s/9i9smanual/6zatta/6-16-14port_no.htm)
- [IPtalk #08 全体マニュアルPDF（NCK）](http://nck.or.jp/shiryou/150923IPtalk_zentai.pdf)
- [IPtalk9t69マニュアルPDF](http://www.s-kurita.net/download/201001IPtalk9t69_manual.pdf)
- [mekiku IPtalk互換FAQ](https://mekiku.com/ja/faq_with_iptalk.html)
- [IPtalk 入力記録（12バイト時刻プレフィクス言及）](http://s-kurita.net/manual/9i9s/9i9smanual/3kinou/3-7-10nyuryoku_kiroku.htm)

## 2. 採用アプローチ

Approach A: 既存 `IPtalkManager` を全面書き換え。旧 `"TEXT"` 独自形式は完全削除。

却下した代替案:
- B (互換モード共存): 「完全互換」の趣旨と矛盾、保守コスト過大。
- C (新規モジュール `IPtalkCompat` を作って旧を残す): ContentView/Test の参照リネームが波及して大きすぎる。

## 3. モジュール構成

```
SummaryTalk/Models/IPtalk/
├── IPtalkProtocol.swift   // 純粋関数: ポート表/チャンネル算術/Shift-JIS変換/パケット組み立て
└── IPtalkManager.swift    // @MainActor @Observable: マルチポートリスナ/送信/メンバ管理
```

旧 `SummaryTalk/Models/IPtalkManager.swift` は削除。型名 `IPtalkManager` は維持するため `ContentView` / `IPtalkPanel` 側の参照はインポート以外変更不要。

### IPtalkProtocol.swift（純粋関数のみ、テスト容易）

```swift
enum IPtalkPortRole {
    case display, monitor, correction, memberReply, memberBroadcast, undo
}

enum IPtalkProtocol {
    static let basePorts: [IPtalkPortRole: UInt16] = [
        .display: 6711,
        .monitor: 6712,
        .correction: 6713,
        .memberReply: 6718,
        .memberBroadcast: 6722,
        .undo: 6723,
    ]

    /// チャンネル 1...9 を受け、各 role の実ポート番号を返す。
    static func port(role: IPtalkPortRole, channel: Int) -> UInt16

    /// テキストをShift-JIS LFターミネートでエンコード（絵文字等はlossy '?' 置換）
    static func encode(line: String) -> Data

    /// 受信データをShift-JISでデコード（失敗時 nil）
    static func decode(_ data: Data) -> String?

    /// メンバ探索ブロードキャスト用ペイロード（Phase 1: ハンドル名のShift-JISバイト列を仮置き）
    static func memberDiscoveryRequest(handleName: String) -> Data

    /// メンバ探索応答用ペイロード（Phase 1: 同上）
    static func memberDiscoveryReply(handleName: String) -> Data
}
```

### IPtalkManager.swift（ネットワーク責務）

```swift
struct IPtalkMember: Identifiable, Hashable {
    let id: String         // IP文字列をIDとする
    let name: String
    let ip: String
}

enum IPtalkLineKind { case display, monitor, correction, undo }

struct IPtalkReceivedLine: Identifiable {
    let id: UUID
    let kind: IPtalkLineKind
    let sender: String
    let text: String
    let receivedAt: Date
}

@MainActor @Observable
final class IPtalkManager {
    // 設定（UserDefaultsバックではなく純粋プロパティ。永続化はView層が担う）
    var channel: Int = 1
    var handleName: String = ""

    // 状態
    private(set) var isConnected: Bool = false
    private(set) var members: [IPtalkMember] = []
    private(set) var receivedLines: [IPtalkReceivedLine] = []
    var errorMessage: String?

    // 既存API互換
    var receivedText: String { receivedLines.filter { $0.kind == .display }.map(\.text).joined() }

    // 接続/切断
    func startListening() async
    func stopListening()

    // 送信
    func sendDisplayLine(_ text: String)
    func sendCorrection(_ text: String)
    func sendUndo()

    // メンバ管理
    func refreshMembers() async

    // クリア
    func clearReceivedText()
}
```

## 4. データフロー

### 送信（音声認識 → IPtalk）

```
SFSpeechRecognitionTask
  ↓ (isFinal == true)
TranscriptionManager.handleRecognitionUpdate
  ↓ onFinalizedLine?(text)   // クロージャ通知（依存逆転）
ContentView
  ↓ iptalkManager.sendDisplayLine(text)  // autoSendEnabled時のみ
IPtalkManager
  ↓ IPtalkProtocol.encode(line:)
  ↓ NWConnection(.udp, broadcast, port=6711)
LAN
```

逆方向（IPtalk→Transcription）の依存は持たせない。TranscriptionManagerはIPtalkManagerの存在を知らない。

### 受信

各ポートに `NWListener` を1つずつ立てる。受信したパケットは `IPtalkProtocol.decode` でテキスト化し、ポートに応じた `IPtalkLineKind` で `receivedLines` に積む。送信元IPは `connection.currentPath?.remoteEndpoint` から取得し `members` を自動更新（IPベースでdedup）。

### メンバ探索

`startListening()` の最後で 1 回 `refreshMembers()` を自動実行。
- 6722 にブロードキャスト送信（自分のハンドル名をペイロード）
- 他IPtalkからの 6722 受信時は、その送信元IPに対して 6718 でユニキャスト応答（自分のハンドル名）
- 6718 受信時は `members` に追加

**Phase 1 の制約**: `memberDiscoveryRequest` / `memberDiscoveryReply` のペイロードは公開仕様に詳細がないため、最小実装としてハンドル名のShift-JISバイト列をそのまま入れる。Phase 2 で本物パケットに合わせて差し替え可能なように、純粋関数として分離する。

## 5. UI 変更

### IPtalkPanel.swift

| 変更前 | 変更後 |
|---|---|
| 「ポート」TextField（自由入力、デフォルト15000）| 「チャンネル」Picker (1...9, デフォルト1) |
| なし | 「ハンドル名」TextField（`@AppStorage("iptalkHandleName")` で永続化） |
| 「接続パートナー」リスト（`connectedPartners: [String]`）| 「メンバー一覧」リスト（`members: [IPtalkMember]` — 名前 + IP表示） |
| なし | 「認識結果を自動送信」Toggle（`@AppStorage("iptalkAutoSend")`） |
| 「IPtalkに送信」ボタン（手動）| 維持（`sendDisplayLine` に変更） |

### ControlView/ContentView.swift

`IPtalkPanel` 表示状態と、自動送信のクロージャ配線を ContentView の `onAppear` で行う:

```swift
.onAppear {
    transcriptionManager.onFinalizedLine = { [weak iptalkManager] line in
        guard iptalkAutoSend, iptalkManager?.isConnected == true else { return }
        iptalkManager?.sendDisplayLine(line)
    }
}
```

## 6. エラー処理

| シナリオ | 挙動 |
|---|---|
| ポート使用中（同一機で本物IPtalkが先に起動） | 全listenerをロールバック、`isConnected=false`、`errorMessage` に「ポート XXXX が使用中。別チャンネルで起動してください」 |
| 単一listener失敗時 | 全ポートロールバック（部分的に動くより無接続のほうが理解しやすい） |
| Shift-JIS非対応文字 | `allowLossyConversion: true` で '?' 置換して送信続行。errorMessageには出さない |
| 受信デコード失敗 | 当該行を破棄。errorMessageは出さない（騒音回避） |
| ブロードキャストsend失敗 | `errorMessage` に「送信失敗: \(error)」、isConnectedは維持 |

## 7. テスト戦略

### IPtalkProtocolTests.swift（新規・純粋関数）

- `port(role:channel:)` の網羅: 全role × ch1/ch5/ch9
- `encode(line:)`: ASCII / 漢字 / 半角カナ / 絵文字（lossy '?'）/ 空文字 / LF含み
- `decode(_:)`: Shift-JIS 正常系 / 非Shift-JIS バイト列での nil 返却
- `memberDiscoveryRequest` / `memberDiscoveryReply`: Phase 1 ペイロードの構造を固定（Phase 2 で本物パケットに置き換える際の差分が見えるように）

### IPtalkManagerTests（最小限）

- `startListening` → `isConnected = true`、`stopListening` で false に戻る
- ポート競合シミュレーション（事前に一つのlistenerを立てる）でerrorMessage設定と全ロールバック

旧 `IPtalkManagerTests.swift` （TEXT形式の検証）は **削除**。

### 統合検証（人手）

Phase 1 完成後、ユーザーが下記を実施:
1. Windows機で本物IPtalk起動
2. SummaryTalk起動、「接続」ボタン押下
3. 本物IPtalk側の「パートナー」ページ「メンバーを捜す」で SummaryTalk が見えるか確認
4. SummaryTalk で発話 → 本物IPtalk の表示部に出るか確認
5. Wireshark/tcpdump で 6711/6712/6718/6722/6723 のパケットを採取し共有
6. 不一致があれば Phase 2 で `IPtalkProtocol` の該当関数を修正

## 8. マイグレーション・互換性

- 旧 `"TEXT"` 形式は完全廃止
- 旧形式で他者と通信できていたユーザーはいない（誰も解読できない独自形式だったため）
- SummaryTalk⇄SummaryTalk のユースケースは新形式（IPtalk互換）で引き続き動作
- `Info.plist` / entitlements は既存の `network.client`/`network.server` で十分（変更不要）

## 9. スコープ外

- IPtalk の全機能（カラオケ、ルビ送信、ロール連動、スライド、テンプレートなど 6714-6739 の 20+ ポート）
- 暗号化通信（IPtalk側のオプション機能）
- TCP通信（IPtalkは原則UDPのみ）
- IPv6（IPtalkはIPv4のみ）

## 10. Phase 2 のトリガー条件

ユーザーから以下のいずれかが提供された時点でPhase 2に移行:
- 本物IPtalk と SummaryTalk 間のパケットキャプチャ（pcapファイル）
- 「メンバー一覧に表示されない」など具体的な非互換症状の報告と再現手順
