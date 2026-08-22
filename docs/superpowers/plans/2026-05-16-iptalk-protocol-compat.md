# IPtalk Protocol Compatibility Implementation Plan

> **STATUS: COMPLETED — historical record. Do not execute.** Every task below shipped; the unticked
> checkboxes are an artefact of how the plan was written, not remaining work. The code listings are what
> was written on 2026-05-16 and several have since been replaced — notably the `NWConnection` send path,
> which was later given an owner because Network.framework does not retain connections, and the
> single-datagram receive, which now re-arms and reaps idle flows. Treat this file as a record of what
> was decided and why. For current behaviour see `CLAUDE.md`, `README.md`, and the addendum in
> `docs/superpowers/specs/2026-05-16-iptalk-protocol-compat-design.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the custom `"TEXT"`-prefixed IPtalk implementation (port 15000) with a real IPtalk-compatible protocol over UDP ports 6711–6723 (channel-scaled), so SummaryTalk can interoperate with Shigeaki Kurita's IPtalk client.

**Architecture:** Split `IPtalkManager` into a pure protocol module (`IPtalkProtocol.swift`: port table, Shift-JIS encode/decode, payload helpers) and a network module (`IPtalkManager.swift`: per-port `NWListener`s, broadcast/unicast senders, member registry). Wire finalized speech-recognition lines through a closure on `TranscriptionManager` to `IPtalkManager.sendDisplayLine`, controlled by a UI toggle.

**Tech Stack:** Swift 6 (strict concurrency complete), SwiftUI, `Network.framework` (`NWListener` / `NWConnection`), XCTest, Xcode 15+, macOS 14+, Shift-JIS via `String.Encoding.shiftJIS`.

**Reference spec:** `docs/superpowers/specs/2026-05-16-iptalk-protocol-compat-design.md`

---

## File map

**Create:**
- `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift` — pure functions (port arithmetic, encode/decode, member discovery payloads)
- `SummaryTalk/Models/IPtalk/IPtalkManager.swift` — `@MainActor @Observable` networking + state
- `SummaryTalkTests/IPtalkProtocolTests.swift` — pure-function tests

**Modify:**
- `SummaryTalk/Models/TranscriptionManager.swift` — add `onFinalizedLine: ((String) -> Void)?` callback, track last finalized text, emit deltas
- `SummaryTalk/Views/IPtalkPanel.swift` — replace port field with channel picker, add handle-name field, members list, auto-send toggle
- `SummaryTalk/ContentView.swift` — wire `transcriptionManager.onFinalizedLine` to `iptalkManager.sendDisplayLine` via `@AppStorage`
- `SummaryTalk.xcodeproj/project.pbxproj` — add new file refs, remove deleted ones

**Delete:**
- `SummaryTalk/Models/IPtalkManager.swift` (replaced by `Models/IPtalk/IPtalkManager.swift`)
- `SummaryTalkTests/IPtalkManagerTests.swift` (tests the deleted `"TEXT"` format — has no replacement)

---

## Task 1: Restructure Xcode project for new file layout

**Files:**
- Create (empty stubs): `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift`, `SummaryTalk/Models/IPtalk/IPtalkManager.swift`, `SummaryTalkTests/IPtalkProtocolTests.swift`
- Delete: `SummaryTalk/Models/IPtalkManager.swift`, `SummaryTalkTests/IPtalkManagerTests.swift`
- Modify: `SummaryTalk.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create stub Swift files so the project still compiles**

```bash
mkdir -p SummaryTalk/Models/IPtalk
```

Create `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift`:

```swift
import Foundation

enum IPtalkProtocol {
}
```

Create `SummaryTalk/Models/IPtalk/IPtalkManager.swift`:

```swift
import Foundation

@MainActor
@Observable
final class IPtalkManager {
    init() {}
}
```

Create `SummaryTalkTests/IPtalkProtocolTests.swift`:

```swift
import XCTest
@testable import SummaryTalk

final class IPtalkProtocolTests: XCTestCase {
}
```

- [ ] **Step 2: Delete the old IPtalkManager.swift and IPtalkManagerTests.swift from the filesystem**

```bash
rm SummaryTalk/Models/IPtalkManager.swift
rm SummaryTalkTests/IPtalkManagerTests.swift
```

- [ ] **Step 3: Patch project.pbxproj — replace the IPtalkManager.swift / IPtalkManagerTests.swift file references with the new paths and add IPtalkProtocol.swift**

The existing `IPtalkManager.swift` file ref uses `path = IPtalkManager.swift` under the `Models` group. We're moving it inside a new `IPtalk` group at `Models/IPtalk/`. Simplest approach: edit the existing entries in-place (keep their UUIDs to minimize diff) and add new entries for `IPtalkProtocol.swift`.

Apply these four edits with the Edit tool:

(a) Rename the build-file comments and the file-ref path/comments to point at the new location:

In `SummaryTalk.xcodeproj/project.pbxproj`, replace this line:
```
		A1000007 /* IPtalkManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000009 /* IPtalkManager.swift */; };
```
with:
```
		A1000007 /* IPtalkManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000009 /* IPtalkManager.swift */; };
		A1000020 /* IPtalkProtocol.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000020 /* IPtalkProtocol.swift */; };
```

(b) Update the file-ref to the new path. Replace:
```
		A2000009 /* IPtalkManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IPtalkManager.swift; sourceTree = "<group>"; };
```
with:
```
		A2000009 /* IPtalkManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IPtalk/IPtalkManager.swift; sourceTree = "<group>"; };
		A2000020 /* IPtalkProtocol.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IPtalk/IPtalkProtocol.swift; sourceTree = "<group>"; };
```

(c) Add the new file ref to the Models group children. Replace:
```
				A2000009 /* IPtalkManager.swift */,
```
with:
```
				A2000009 /* IPtalkManager.swift */,
				A2000020 /* IPtalkProtocol.swift */,
```

(d) Rename the test file-ref to point at the new test name. Replace:
```
		A1000010 /* IPtalkManagerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000C /* IPtalkManagerTests.swift */; };
```
with:
```
		A1000010 /* IPtalkProtocolTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A200000C /* IPtalkProtocolTests.swift */; };
```

and replace:
```
		A200000C /* IPtalkManagerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IPtalkManagerTests.swift; sourceTree = "<group>"; };
```
with:
```
		A200000C /* IPtalkProtocolTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = IPtalkProtocolTests.swift; sourceTree = "<group>"; };
```

and replace:
```
				A200000C /* IPtalkManagerTests.swift */,
```
with:
```
				A200000C /* IPtalkProtocolTests.swift */,
```

and replace:
```
				A1000010 /* IPtalkManagerTests.swift in Sources */,
```
with:
```
				A1000010 /* IPtalkProtocolTests.swift in Sources */,
```

- [ ] **Step 4: Build to verify the project file is still valid**

Run:
```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. The stub `IPtalkManager` has no members the rest of the app uses, so `ContentView` / `IPtalkPanel` will fail to compile. That's expected at this point — we'll fix them as we go. **If you see compile errors only in `ContentView.swift` / `IPtalkPanel.swift` referencing methods like `sendText` / `startListening` / `port` / `connectedPartners` / `receivedText`, that is the expected failure mode; do not try to fix those yet.** Build success at this step means only "the project file parses." If you see errors mentioning `Models/IPtalk/IPtalkProtocol.swift` or `IPtalkProtocolTests.swift` being unfound, the pbxproj patch is wrong; re-check Step 3.

- [ ] **Step 5: Commit**

```bash
git add SummaryTalk/Models/IPtalk SummaryTalkTests/IPtalkProtocolTests.swift SummaryTalk.xcodeproj/project.pbxproj
git add -u  # picks up the two deletions
git commit -m "refactor: restructure IPtalk module into IPtalk/ subdirectory"
```

---

## Task 2: Implement `IPtalkProtocol.port(role:channel:)` (TDD)

**Files:**
- Modify: `SummaryTalkTests/IPtalkProtocolTests.swift`
- Modify: `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift`

- [ ] **Step 1: Write the failing tests**

Replace the body of `SummaryTalkTests/IPtalkProtocolTests.swift` with:

```swift
import XCTest
@testable import SummaryTalk

final class IPtalkProtocolTests: XCTestCase {
    func testPortsForChannel1() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 1), 6711)
        XCTAssertEqual(IPtalkProtocol.port(role: .monitor, channel: 1), 6712)
        XCTAssertEqual(IPtalkProtocol.port(role: .correction, channel: 1), 6713)
        XCTAssertEqual(IPtalkProtocol.port(role: .memberReply, channel: 1), 6718)
        XCTAssertEqual(IPtalkProtocol.port(role: .memberBroadcast, channel: 1), 6722)
        XCTAssertEqual(IPtalkProtocol.port(role: .undo, channel: 1), 6723)
    }

    func testChannel2AddsHundred() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 2), 6811)
        XCTAssertEqual(IPtalkProtocol.port(role: .undo, channel: 2), 6823)
    }

    func testChannel9AddsEightHundred() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 9), 7511)
        XCTAssertEqual(IPtalkProtocol.port(role: .memberBroadcast, channel: 9), 7522)
    }

    func testChannelClampedToValidRange() {
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 0), 6711, "channel < 1 clamps to 1")
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: 10), 7511, "channel > 9 clamps to 9")
        XCTAssertEqual(IPtalkProtocol.port(role: .display, channel: -5), 6711)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail (compile error)**

Run:
```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' -only-testing:SummaryTalkTests/IPtalkProtocolTests test 2>&1 | tail -10
```

Expected: compilation fails because `IPtalkProtocol.port` and `IPtalkPortRole` don't exist.

- [ ] **Step 3: Implement just enough to pass**

Replace the body of `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift` with:

```swift
import Foundation

enum IPtalkPortRole: CaseIterable {
    case display
    case monitor
    case correction
    case memberReply
    case memberBroadcast
    case undo
}

enum IPtalkProtocol {
    static func port(role: IPtalkPortRole, channel: Int) -> UInt16 {
        let base: UInt16
        switch role {
        case .display:          base = 6711
        case .monitor:          base = 6712
        case .correction:       base = 6713
        case .memberReply:      base = 6718
        case .memberBroadcast:  base = 6722
        case .undo:             base = 6723
        }
        let clamped = max(1, min(9, channel))
        return base + UInt16(clamped - 1) * 100
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run:
```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' -only-testing:SummaryTalkTests/IPtalkProtocolTests test 2>&1 | tail -15
```

Expected: `Test Suite 'IPtalkProtocolTests' passed` with 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git add SummaryTalk/Models/IPtalk/IPtalkProtocol.swift SummaryTalkTests/IPtalkProtocolTests.swift
git commit -m "feat: add IPtalk port mapping with channel arithmetic"
```

---

## Task 3: Implement Shift-JIS encode/decode (TDD)

**Files:**
- Modify: `SummaryTalkTests/IPtalkProtocolTests.swift`
- Modify: `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift`

- [ ] **Step 1: Write the failing tests**

Append these test methods inside the `IPtalkProtocolTests` class:

```swift
    func testEncodeAsciiAddsLF() {
        let data = IPtalkProtocol.encode(line: "hello")
        XCTAssertEqual(data, Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a]))
    }

    func testEncodeDoesNotDoubleLFWhenAlreadyTerminated() {
        let data = IPtalkProtocol.encode(line: "hello\n")
        XCTAssertEqual(data, Data([0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x0a]))
    }

    func testEncodeEmptyStringIsJustLF() {
        XCTAssertEqual(IPtalkProtocol.encode(line: ""), Data([0x0a]))
    }

    func testEncodeKanjiRoundTrip() {
        let original = "こんにちは"
        let encoded = IPtalkProtocol.encode(line: original)
        let decoded = IPtalkProtocol.decode(encoded)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), original)
    }

    func testEncodeHalfwidthKanaRoundTrip() {
        let original = "ｶﾀｶﾅ"
        let encoded = IPtalkProtocol.encode(line: original)
        let decoded = IPtalkProtocol.decode(encoded)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), original)
    }

    func testEncodeEmojiFallsBackLossy() {
        // Emoji has no Shift-JIS representation; encode must not crash and must produce
        // bytes that decode back to *something* (lossy '?' replacement is acceptable).
        let encoded = IPtalkProtocol.encode(line: "abc😀def")
        XCTAssertFalse(encoded.isEmpty)
        let decoded = IPtalkProtocol.decode(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.contains("abc"))
        XCTAssertTrue(decoded!.contains("def"))
    }

    func testDecodeEmptyDataReturnsEmptyString() {
        XCTAssertEqual(IPtalkProtocol.decode(Data()), "")
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' -only-testing:SummaryTalkTests/IPtalkProtocolTests test 2>&1 | tail -15
```

Expected: compile error (no `encode` / `decode`).

- [ ] **Step 3: Implement encode/decode**

Append to `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift` (after the existing `port(role:channel:)` static method, still inside `enum IPtalkProtocol`):

```swift
    static let encoding: String.Encoding = .shiftJIS

    static func encode(line: String) -> Data {
        let terminated = line.hasSuffix("\n") ? line : line + "\n"
        return terminated.data(using: encoding, allowLossyConversion: true) ?? Data()
    }

    static func decode(_ data: Data) -> String? {
        String(data: data, encoding: encoding)
    }
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' -only-testing:SummaryTalkTests/IPtalkProtocolTests test 2>&1 | tail -15
```

Expected: 11 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SummaryTalk/Models/IPtalk/IPtalkProtocol.swift SummaryTalkTests/IPtalkProtocolTests.swift
git commit -m "feat: add Shift-JIS encode/decode for IPtalk text frames"
```

---

## Task 4: Implement member-discovery payload helpers (TDD)

**Files:**
- Modify: `SummaryTalkTests/IPtalkProtocolTests.swift`
- Modify: `SummaryTalk/Models/IPtalk/IPtalkProtocol.swift`

These are Phase 1 placeholder payloads (handle name as Shift-JIS); the exact wire format is unknown until users provide packet captures. The helpers exist as a seam so Phase 2 can swap the format without touching the manager.

- [ ] **Step 1: Write the failing tests**

Append inside `IPtalkProtocolTests`:

```swift
    func testMemberDiscoveryRequestContainsHandleName() {
        let data = IPtalkProtocol.memberDiscoveryRequest(handleName: "テスター")
        let decoded = IPtalkProtocol.decode(data)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), "テスター")
    }

    func testMemberDiscoveryReplyContainsHandleName() {
        let data = IPtalkProtocol.memberDiscoveryReply(handleName: "サマライズ")
        let decoded = IPtalkProtocol.decode(data)
        XCTAssertEqual(decoded?.trimmingCharacters(in: .newlines), "サマライズ")
    }

    func testMemberDiscoveryRequestHandlesEmptyHandle() {
        let data = IPtalkProtocol.memberDiscoveryRequest(handleName: "")
        XCTAssertFalse(data.isEmpty, "must still send something so peers can register our IP")
    }
```

- [ ] **Step 2: Run to confirm failure**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' -only-testing:SummaryTalkTests/IPtalkProtocolTests test 2>&1 | tail -10
```

Expected: compile error (no `memberDiscoveryRequest`/`Reply`).

- [ ] **Step 3: Implement helpers**

Append inside `enum IPtalkProtocol`:

```swift
    static func memberDiscoveryRequest(handleName: String) -> Data {
        encode(line: handleName)
    }

    static func memberDiscoveryReply(handleName: String) -> Data {
        encode(line: handleName)
    }
```

- [ ] **Step 4: Run to confirm pass**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' -only-testing:SummaryTalkTests/IPtalkProtocolTests test 2>&1 | tail -10
```

Expected: 14 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SummaryTalk/Models/IPtalk/IPtalkProtocol.swift SummaryTalkTests/IPtalkProtocolTests.swift
git commit -m "feat: add Phase 1 IPtalk member discovery payload helpers"
```

---

## Task 5: Define value types (`IPtalkMember`, `IPtalkLineKind`, `IPtalkReceivedLine`)

**Files:**
- Modify: `SummaryTalk/Models/IPtalk/IPtalkManager.swift`

These are simple Sendable value types; they don't need their own file.

- [ ] **Step 1: Add the value types**

Replace the body of `SummaryTalk/Models/IPtalk/IPtalkManager.swift` with:

```swift
import Foundation
import Network

struct IPtalkMember: Identifiable, Hashable {
    let id: String   // IP string; serves as identity
    let name: String
    let ip: String
}

enum IPtalkLineKind: Hashable {
    case display
    case monitor
    case correction
    case undo
}

struct IPtalkReceivedLine: Identifiable, Hashable {
    let id: UUID
    let kind: IPtalkLineKind
    let sender: String
    let text: String
    let receivedAt: Date
}

@MainActor
@Observable
final class IPtalkManager {
    init() {}
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build 2>&1 | tail -10
```

Expected: errors only in `ContentView.swift` / `IPtalkPanel.swift` (still referencing the removed API). No errors in `IPtalkManager.swift` itself.

- [ ] **Step 3: Commit**

```bash
git add SummaryTalk/Models/IPtalk/IPtalkManager.swift
git commit -m "feat: add IPtalk member and received-line value types"
```

---

## Task 6: Implement `IPtalkManager` state and listener lifecycle

**Files:**
- Modify: `SummaryTalk/Models/IPtalk/IPtalkManager.swift`

This is the biggest single task — it brings up the full multi-port listener stack. Tests are deferred to manual integration since `NWListener` is awkward to unit-test (binds real sockets). State changes (`isConnected`) are verified by the integration test step in Task 12.

- [ ] **Step 1: Replace the class body with the full networking implementation**

Replace the existing `final class IPtalkManager` block (the one with empty `init()`) with:

```swift
@MainActor
@Observable
final class IPtalkManager {
    // Configuration (View layer is responsible for persistence)
    var channel: Int = 1
    var handleName: String = ""

    // Observable state
    private(set) var isConnected: Bool = false
    private(set) var members: [IPtalkMember] = []
    private(set) var receivedLines: [IPtalkReceivedLine] = []
    var errorMessage: String?

    // Backward-compatible view for IPtalkPanel — concatenates display lines only.
    var receivedText: String {
        receivedLines.filter { $0.kind == .display }.map(\.text).joined()
    }

    private var listeners: [IPtalkPortRole: NWListener] = [:]
    private let networkQueue = DispatchQueue(label: "com.summarytalk.iptalk", qos: .userInitiated)

    init() {}

    // MARK: - Lifecycle

    func startListening() async {
        guard !isConnected else { return }
        errorMessage = nil

        var opened: [IPtalkPortRole: NWListener] = [:]
        for role in IPtalkPortRole.allCases {
            let portNum = IPtalkProtocol.port(role: role, channel: channel)
            guard let nwPort = NWEndpoint.Port(rawValue: portNum) else { continue }
            do {
                let params = NWParameters.udp
                params.allowLocalEndpointReuse = true
                let listener = try NWListener(using: params, on: nwPort)
                listener.newConnectionHandler = { [weak self] conn in
                    Task { @MainActor in self?.handleIncoming(conn, role: role) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .failed(let err) = state {
                        Task { @MainActor in
                            self?.errorMessage = "ポート \(portNum) リスナエラー: \(err.localizedDescription)"
                            self?.tearDown()
                        }
                    }
                }
                listener.start(queue: networkQueue)
                opened[role] = listener
            } catch {
                opened.values.forEach { $0.cancel() }
                errorMessage = "ポート \(portNum) が使用中です。別のチャンネルを試してください。"
                return
            }
        }
        listeners = opened
        isConnected = true
        await refreshMembers()
    }

    func stopListening() {
        tearDown()
    }

    private func tearDown() {
        listeners.values.forEach { $0.cancel() }
        listeners.removeAll()
        isConnected = false
        members.removeAll()
    }

    // MARK: - Receive

    private func handleIncoming(_ connection: NWConnection, role: IPtalkPortRole) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receive(on: connection, role: role)
            }
        }
        connection.start(queue: networkQueue)
    }

    private func receive(on connection: NWConnection, role: IPtalkPortRole) {
        connection.receiveMessage { [weak self] content, _, _, _ in
            guard let self else { return }
            Task { @MainActor in
                if let content {
                    let sender = self.endpointHost(connection)
                    self.process(data: content, role: role, sender: sender)
                }
                connection.cancel()
            }
        }
    }

    private func endpointHost(_ connection: NWConnection) -> String {
        if let endpoint = connection.currentPath?.remoteEndpoint,
           case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return "unknown"
    }

    private func process(data: Data, role: IPtalkPortRole, sender: String) {
        guard let text = IPtalkProtocol.decode(data) else { return }
        let stripped = text.trimmingCharacters(in: .newlines)
        switch role {
        case .display:
            appendLine(.display, sender: sender, text: text)
            addOrUpdateMember(ip: sender, name: nil)
        case .monitor:
            appendLine(.monitor, sender: sender, text: text)
        case .correction:
            appendLine(.correction, sender: sender, text: text)
        case .undo:
            appendLine(.undo, sender: sender, text: text)
        case .memberBroadcast:
            // A peer is asking "who's here?" — reply on memberReply (unicast).
            let replyPort = IPtalkProtocol.port(role: .memberReply, channel: channel)
            sendUnicast(IPtalkProtocol.memberDiscoveryReply(handleName: handleName), to: sender, port: replyPort)
            addOrUpdateMember(ip: sender, name: stripped)
        case .memberReply:
            addOrUpdateMember(ip: sender, name: stripped)
        }
    }

    private func appendLine(_ kind: IPtalkLineKind, sender: String, text: String) {
        receivedLines.append(IPtalkReceivedLine(id: UUID(), kind: kind, sender: sender, text: text, receivedAt: Date()))
    }

    /// Adds a member if new. If `name` is non-nil and non-empty, updates the display
    /// name (so a later member-discovery reply can replace the IP fallback assigned
    /// when we first saw the peer via a display packet).
    private func addOrUpdateMember(ip: String, name: String?) {
        if let idx = members.firstIndex(where: { $0.id == ip }) {
            if let name, !name.isEmpty {
                members[idx] = IPtalkMember(id: ip, name: name, ip: ip)
            }
        } else {
            let resolved = (name?.isEmpty == false) ? name! : ip
            members.append(IPtalkMember(id: ip, name: resolved, ip: ip))
        }
    }

    // MARK: - Send

    func sendDisplayLine(_ text: String) {
        guard isConnected else { return }
        sendBroadcast(IPtalkProtocol.encode(line: text),
                      port: IPtalkProtocol.port(role: .display, channel: channel))
    }

    func sendCorrection(_ text: String) {
        guard isConnected else { return }
        sendBroadcast(IPtalkProtocol.encode(line: text),
                      port: IPtalkProtocol.port(role: .correction, channel: channel))
    }

    func sendUndo() {
        guard isConnected else { return }
        sendBroadcast(IPtalkProtocol.encode(line: ""),
                      port: IPtalkProtocol.port(role: .undo, channel: channel))
    }

    func refreshMembers() async {
        guard isConnected else { return }
        members.removeAll()
        sendBroadcast(IPtalkProtocol.memberDiscoveryRequest(handleName: handleName),
                      port: IPtalkProtocol.port(role: .memberBroadcast, channel: channel))
    }

    func clearReceivedText() {
        receivedLines.removeAll()
    }

    private func sendBroadcast(_ data: Data, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: "255.255.255.255", port: nwPort, using: params)
        send(data, on: conn)
    }

    private func sendUnicast(_ data: Data, to host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.udp
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        send(data, on: conn)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        connection.start(queue: networkQueue)
    }
}
```

- [ ] **Step 2: Build and confirm `IPtalkManager.swift` itself compiles cleanly**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build 2>&1 | grep -E "(error:|warning:)" | grep -v "ContentView\|IPtalkPanel" | head -20
```

Expected: no errors from `IPtalkManager.swift` itself. The only errors should still be in `ContentView.swift` / `IPtalkPanel.swift` (next tasks). Swift 6 strict concurrency may flag the `NWListener` callbacks — confirm they all use `[weak self]` and dispatch to `@MainActor` via `Task { @MainActor in ... }`.

- [ ] **Step 3: Commit**

```bash
git add SummaryTalk/Models/IPtalk/IPtalkManager.swift
git commit -m "feat: implement multi-port UDP listeners and IPtalk send/receive"
```

---

## Task 7: Add `onFinalizedLine` callback to `TranscriptionManager` (TDD)

**Files:**
- Modify: `SummaryTalk/Models/TranscriptionManager.swift`
- (No test file for this — `SFSpeechRecognizer` cannot be exercised in unit tests on CI. Verified manually in Task 12.)

The callback fires only the *newly-finalized portion* (delta since the last finalization), since `result.bestTranscription.formattedString` is cumulative within a session.

- [ ] **Step 1: Add the `onFinalizedLine` property**

In `SummaryTalk/Models/TranscriptionManager.swift`, locate the existing block of properties at the top of the class (after `var audioSource: AudioSource = .microphone`) and add:

```swift
    var onFinalizedLine: ((String) -> Void)?
    private var lastFinalizedText: String = ""
```

- [ ] **Step 2: Emit deltas from `handleRecognitionUpdate(text:isFinal:)`**

Locate the existing `handleRecognitionUpdate` method (around line 168). Replace its entire body with:

```swift
    private func handleRecognitionUpdate(text: String, isFinal: Bool) {
        guard text != transcribedText else { return }
        if isFinal {
            partialUpdateTask?.cancel()
            transcribedText = text
            lastTranscriptionUpdate = Date()
            emitFinalizedDelta(currentText: text)
            return
        }

        pendingTranscription = text
        let now = Date()
        if now.timeIntervalSince(lastTranscriptionUpdate) >= partialUpdateInterval {
            transcribedText = pendingTranscription
            lastTranscriptionUpdate = now
            return
        }

        partialUpdateTask?.cancel()
        partialUpdateTask = Task { @MainActor in
            let delay = UInt64(partialUpdateInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            if self.transcribedText != self.pendingTranscription {
                self.transcribedText = self.pendingTranscription
                self.lastTranscriptionUpdate = Date()
            }
        }
    }

    private func emitFinalizedDelta(currentText: String) {
        let delta: String
        if currentText.hasPrefix(lastFinalizedText) {
            delta = String(currentText.dropFirst(lastFinalizedText.count))
        } else {
            // Session restarted or recognizer reset — treat the whole text as new.
            delta = currentText
        }
        lastFinalizedText = currentText
        let trimmed = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onFinalizedLine?(trimmed)
        }
    }
```

- [ ] **Step 3: Reset `lastFinalizedText` on session boundaries**

In `startMicrophoneRecording()` (around line 76), add this line right after `pendingTranscription = ""`:

```swift
        lastFinalizedText = ""
```

Do the same in `startSystemAudioRecording(systemAudioManager:)` (around line 111), right after the matching `pendingTranscription = ""`.

In `clearText()` (around line 220), replace its body with:

```swift
    func clearText() {
        partialUpdateTask?.cancel()
        pendingTranscription = ""
        lastFinalizedText = ""
        transcribedText = ""
    }
```

- [ ] **Step 4: Build to confirm `TranscriptionManager.swift` compiles**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build 2>&1 | grep -E "error:" | grep "TranscriptionManager" | head -10
```

Expected: no errors in `TranscriptionManager.swift`.

- [ ] **Step 5: Commit**

```bash
git add SummaryTalk/Models/TranscriptionManager.swift
git commit -m "feat: emit finalized recognition deltas via onFinalizedLine callback"
```

---

## Task 8: Rewrite `IPtalkPanel.swift` UI

**Files:**
- Modify: `SummaryTalk/Views/IPtalkPanel.swift`

- [ ] **Step 1: Replace the entire file**

Replace the full contents of `SummaryTalk/Views/IPtalkPanel.swift` with:

```swift
import SwiftUI

struct IPtalkPanel: View {
    @Bindable var iptalkManager: IPtalkManager
    @Binding var textToSend: String

    @AppStorage("iptalkHandleName") private var handleName: String = ""
    @AppStorage("iptalkChannel") private var channel: Int = 1
    @AppStorage("iptalkAutoSend") private var autoSend: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("IPtalk接続")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(iptalkManager.isConnected ? .green : .gray)
                    .frame(width: 10, height: 10)
                Text(iptalkManager.isConnected ? "接続中" : "未接続")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("チャンネル:")
                    .foregroundStyle(.secondary)
                Picker("", selection: $channel) {
                    ForEach(1...9, id: \.self) { ch in
                        Text("\(ch)").tag(ch)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
                .disabled(iptalkManager.isConnected)

                Spacer()

                Button {
                    Task {
                        if iptalkManager.isConnected {
                            iptalkManager.stopListening()
                        } else {
                            iptalkManager.channel = channel
                            iptalkManager.handleName = resolvedHandleName
                            await iptalkManager.startListening()
                        }
                    }
                } label: {
                    Text(iptalkManager.isConnected ? "切断" : "接続")
                        .frame(width: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(iptalkManager.isConnected ? .red : .blue)
            }

            HStack {
                Text("ハンドル名:")
                    .foregroundStyle(.secondary)
                TextField("自動 (\(autoHandleName))", text: $handleName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(iptalkManager.isConnected)
            }

            Toggle("認識結果を自動送信", isOn: $autoSend)
                .toggleStyle(.switch)

            if !iptalkManager.members.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("メンバー一覧:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(iptalkManager.members) { member in
                        HStack {
                            Text(member.name)
                                .font(.caption.bold())
                            Text(member.ip)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            if let error = iptalkManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack {
                Button {
                    if !textToSend.isEmpty {
                        iptalkManager.sendDisplayLine(textToSend)
                    }
                } label: {
                    Label("IPtalkに送信", systemImage: "paperplane.fill")
                }
                .disabled(!iptalkManager.isConnected || textToSend.isEmpty)

                Spacer()

                Button {
                    iptalkManager.clearReceivedText()
                } label: {
                    Label("受信クリア", systemImage: "trash")
                }
                .disabled(iptalkManager.receivedText.isEmpty)
            }

            if !iptalkManager.receivedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("受信テキスト:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(iptalkManager.receivedText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var autoHandleName: String {
        let host = ProcessInfo.processInfo.hostName
        return host.components(separatedBy: ".").first ?? "SummaryTalk"
    }

    private var resolvedHandleName: String {
        handleName.trimmingCharacters(in: .whitespaces).isEmpty ? autoHandleName : handleName
    }
}

#Preview {
    IPtalkPanel(
        iptalkManager: IPtalkManager(),
        textToSend: .constant("テストテキスト")
    )
    .frame(width: 400)
    .padding()
}
```

- [ ] **Step 2: Build to confirm IPtalkPanel compiles**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build 2>&1 | grep "error:" | head -20
```

Expected: only errors in `ContentView.swift` (next task). No errors in `IPtalkPanel.swift`.

- [ ] **Step 3: Commit**

```bash
git add SummaryTalk/Views/IPtalkPanel.swift
git commit -m "feat: rewrite IPtalkPanel with channel picker, handle name, and auto-send toggle"
```

---

## Task 9: Wire `onFinalizedLine` in `ContentView`

**Files:**
- Modify: `SummaryTalk/ContentView.swift`

- [ ] **Step 1: Replace the file**

Replace the full contents of `SummaryTalk/ContentView.swift` with:

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
        .onAppear {
            transcriptionManager.onFinalizedLine = { [weak iptalkManager] line in
                let autoSend = UserDefaults.standard.object(forKey: "iptalkAutoSend") as? Bool ?? true
                guard autoSend, let manager = iptalkManager, manager.isConnected else { return }
                manager.sendDisplayLine(line)
            }
        }
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 2: Build the whole app**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite to confirm no regressions**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' test 2>&1 | tail -25
```

Expected: all tests pass (`IPtalkProtocolTests` 14, `SystemAudioAppChoiceTests` 5, `SystemAudioManagerTests` 2). The old `IPtalkManagerTests` should be gone.

- [ ] **Step 4: Commit**

```bash
git add SummaryTalk/ContentView.swift
git commit -m "feat: auto-send finalized recognition lines via IPtalk when enabled"
```

---

## Task 10: Manual integration test (golden path)

**Files:** none (manual verification)

Run the app and confirm the IPtalk-compat path works end-to-end on the local machine (loopback first; cross-machine with a real IPtalk client is Phase 2).

- [ ] **Step 1: Launch the app**

```bash
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug -derivedDataPath build/dd build
open build/dd/Build/Products/Debug/SummaryTalk.app
```

- [ ] **Step 2: Open the IPtalk panel**

Click the "IPtalk" button in the control bar. Confirm the panel appears with:
- "チャンネル" picker (default 1)
- "ハンドル名" text field (placeholder shows machine name)
- "認識結果を自動送信" toggle (default ON)
- "接続" button

- [ ] **Step 3: Connect on channel 1**

Click "接続". Confirm:
- The status dot turns green ("接続中")
- No error appears
- (Optional) `lsof -i UDP -P | grep SummaryTalk` from a terminal shows ports 6711, 6712, 6713, 6718, 6722, 6723

- [ ] **Step 4: Verify loopback display send works**

Type some text into the transcript area (or paste it into `textToSend` via the manual "IPtalkに送信" button) and click "IPtalkに送信". Confirm:
- `tcpdump -i lo0 -A -n udp port 6711` (in another terminal, run before the click) shows a UDP packet with the Shift-JIS bytes of your text followed by `\n`

- [ ] **Step 5: Verify channel change is gated by disconnect**

Disconnect. Change channel to 2. Reconnect. Confirm `lsof` now shows ports 6811-6823 instead of 6711-6723.

- [ ] **Step 6: Verify port-conflict error**

With SummaryTalk connected on channel 1, launch a second instance of SummaryTalk and try to connect on channel 1. Confirm the second instance shows the error "ポート 6711 が使用中です。別のチャンネルを試してください。" and `isConnected` stays false.

- [ ] **Step 7: No commit needed for manual test**

If any of the above fails, file a follow-up task before declaring Phase 1 done.

---

## Task 11: Update CLAUDE.md to reflect new IPtalk wire format

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the stale test-command examples (lines 18 and 20)**

Replace this line:
```
  -only-testing:SummaryTalkTests/IPtalkManagerTests test
```
with:
```
  -only-testing:SummaryTalkTests/IPtalkProtocolTests test
```

Replace this line:
```
  -only-testing:SummaryTalkTests/IPtalkManagerTests/testParsePacketReturnsOriginalText test
```
with:
```
  -only-testing:SummaryTalkTests/IPtalkProtocolTests/testEncodeKanjiRoundTrip test
```

- [ ] **Step 2: Replace the IPtalkManager architecture bullet (line 33)**

Replace the entire one-line bullet starting `- **\`IPtalkManager\`** (\`Models/IPtalkManager.swift\`)` with:

```markdown
- **`IPtalkManager`** (`Models/IPtalk/IPtalkManager.swift` + `Models/IPtalk/IPtalkProtocol.swift`) — real IPtalk-compatible UDP client (栗田茂明氏作 IPtalk). Opens 6 `NWListener`s per channel (display 6711, monitor 6712, correction 6713, member-reply 6718, member-broadcast 6722, undo 6723; channel N adds 100×(N-1)). Text is plain Shift-JIS terminated by LF — no custom header. `IPtalkProtocol.swift` holds the pure functions (port arithmetic, encode/decode, member-discovery payloads) and is the place to iterate on wire format if real-IPtalk packet captures reveal the Phase 1 payload guesses are wrong. `IPtalkManager.swift` owns the listener stack and broadcasts to `255.255.255.255`. Finalized speech-recognition lines auto-publish via `TranscriptionManager.onFinalizedLine` when `iptalkAutoSend` (UserDefault) is true.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document real IPtalk wire format in CLAUDE.md"
```

---

## Self-review checklist

- [x] **Spec coverage:**
  - Spec §3 module structure → Task 1 (project restructure), Tasks 5–6 (manager), Tasks 2–4 (protocol)
  - Spec §3 port table → Task 2
  - Spec §3 public API → Tasks 5–6 (types, lifecycle, send, member discovery)
  - Spec §4 data flow → Task 7 (TranscriptionManager) + Task 9 (ContentView wiring)
  - Spec §5 UI changes → Task 8 (IPtalkPanel rewrite)
  - Spec §6 error handling → Task 6 (port-in-use rollback, errorMessage)
  - Spec §7 testing → Tasks 2–4 (IPtalkProtocolTests), Task 10 (manual integration)
  - Spec §8 migration → Task 1 (old file deletion)
  - Spec §9 scope-out items → not implemented, correctly absent
- [x] **No placeholders:** all code blocks contain real Swift; no "TBD" / "TODO" / "similar to" references
- [x] **Type consistency:** `IPtalkPortRole` (Task 2), `IPtalkProtocol.encode/decode` (Task 3), `memberDiscoveryRequest/Reply` (Task 4), `IPtalkMember/IPtalkLineKind/IPtalkReceivedLine` (Task 5), `IPtalkManager.{channel,handleName,members,receivedLines,receivedText,isConnected,startListening,stopListening,sendDisplayLine,sendCorrection,sendUndo,refreshMembers,clearReceivedText}` (Task 6) — all referenced names match across tasks and against `IPtalkPanel.swift` (Task 8) and `ContentView.swift` (Task 9)
