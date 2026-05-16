# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

This is an Xcode project (no SwiftPM `Package.swift`). Use `xcodebuild` from the repo root:

```bash
# Build the app (Debug)
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -configuration Debug build

# Run all unit tests
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' test

# Run a single test class or method
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/IPtalkProtocolTests test
xcodebuild -project SummaryTalk.xcodeproj -scheme SummaryTalk -destination 'platform=macOS' \
  -only-testing:SummaryTalkTests/IPtalkProtocolTests/testEncodeKanjiRoundTrip test
```

Build settings of note: `SWIFT_VERSION = 6.0`, `SWIFT_STRICT_CONCURRENCY = complete`, `MACOSX_DEPLOYMENT_TARGET = 14.0`. New code must compile cleanly under Swift 6 complete concurrency checking.

## Architecture

SwiftUI macOS app with three independent `@MainActor @Observable` managers wired together in `ContentView`. There is no shared store — managers communicate via direct method calls and a single closure handoff for audio.

- **`TranscriptionManager`** (`Models/TranscriptionManager.swift`) — owns the `SFSpeechRecognizer` (locale `ja-JP`, on-device when supported) and an `AVAudioEngine` for mic input. Exposes `audioSource` (`.microphone` | `.systemAudio`); when `.systemAudio`, it delegates audio acquisition to `SystemAudioManager` and only runs the recognition request itself. Partial recognition results are throttled to `partialUpdateInterval` (0.25s) so SwiftUI isn't re-rendered on every callback. The "no speech detected" error (`kAFAssistantErrorDomain` 1110) is intentionally swallowed.

- **`SystemAudioManager`** (`Models/SystemAudioManager.swift`) — `ScreenCaptureKit` (`SCStream`) wrapper. Captures audio either from a single app's window (`SCContentFilter(desktopIndependentWindow:)`) or the whole display. Always converts incoming buffers to the target format (16 kHz / mono / float32) via a lazily-created `AVAudioConverter` before invoking `audioBufferHandler`. The handler closure is set by `TranscriptionManager` and is what bridges system audio into the speech recognition request — it is cleared on stop. `permissionCheck` / `requestPermission` are injectable for testability (production uses `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`). `lastErrorKind: SystemAudioErrorKind` distinguishes permission/listing/capture failures so the UI can react. After granting Screen Recording for the first time, the app must be relaunched for permission to take effect.

- **`IPtalkManager`** (`Models/IPtalk/IPtalkManager.swift` + `Models/IPtalk/IPtalkProtocol.swift`) — real IPtalk-compatible UDP client (栗田茂明氏作 IPtalk). Opens 6 `NWListener`s per channel (display 6711, monitor 6712, correction 6713, member-reply 6718, member-broadcast 6722, undo 6723; channel N adds 100×(N-1)). Text is plain Shift-JIS terminated by LF — no custom header. `IPtalkProtocol.swift` holds the pure functions (port arithmetic, encode/decode, member-discovery payloads) and is the place to iterate on wire format if real-IPtalk packet captures reveal the Phase 1 payload guesses are wrong. `IPtalkManager.swift` owns the listener stack and broadcasts to `255.255.255.255`. Finalized speech-recognition lines auto-publish via `TranscriptionManager.onFinalizedLine` when `iptalkAutoSend` (UserDefault) is true.

- **`SystemAudioAppChoice.swift`** — pure helper (`makeChoices(from:)`) that turns a list of `RunningApplicationLike` into picker entries, prepending a "whole display" option and de-duplicating by PID. The `RunningApplicationLike` protocol exists specifically so tests can substitute `FakeApp` without an `SCRunningApplication` instance.

Views (`Views/ControlPanel.swift`, `Views/TranscriptView.swift`, `Views/IPtalkPanel.swift`, `Views/SystemAudioAppPicker.swift`) hold no state — they receive `@Bindable` managers and call into them. The IPtalk panel is conditionally rendered alongside the main column.

## Permissions & Sandbox

The app is sandboxed (`SummaryTalk.entitlements`) with: `audio-input`, `network.client`, `network.server`, `files.user-selected.read-write`. `Info.plist` declares `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`. **Screen Recording (used by `ScreenCaptureKit` for system audio) is intentionally not in `Info.plist`** — it is requested at runtime via `CGRequestScreenCaptureAccess()`. When changing audio capture code, remember the user-visible failure mode is "permission granted but capture still fails until relaunch."

## UI Language

User-facing strings (errors, button labels, picker entries) are Japanese. Match the existing tone when adding new messages — these strings flow directly into `errorMessage` properties bound to the UI.
