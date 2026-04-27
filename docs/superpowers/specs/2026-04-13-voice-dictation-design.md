# Murmur — Voice Dictation Design

**Date:** 2026-04-13
**Status:** Spec — pending implementation
**Author:** brainstormed with Claude

## Overview

A macOS menu bar app that lets the user hold a global hotkey to dictate, transcribes the audio locally with WhisperKit, cleans the transcript with an LLM (Groq Llama 3.3 70B primary, local Gemma3 fallback), and pastes the result into the focused text field via clipboard swap + ⌘V. Per-app overrides control how aggressively the cleanup model edits the text.

This is the first of two subsystems planned for the broader project; the second (camera-based hand tracking for cursor control + gesture shortcuts) will be specified separately and grafted onto the same app shell. The end-state goal is to "vibe code" with minimal physical contact with the computer.

**Project codename:** Murmur (rename later if desired).

## Goals

- Hold-to-talk dictation that feels indistinguishable from typing — sub-1.5s end-to-end for a 5-second clip.
- Works in every macOS text field (native, web, Electron, Terminal).
- Privacy-preserving: STT is local; cleanup falls back to local when offline.
- Per-app cleanup behavior so dictating into Terminal does not destroy `git push --force`.
- Reliable: never lose the user's words, even on every conceivable failure path.

## Non-Goals (v1)

- Hand tracking — separate spec, separate session.
- Cloud STT (Groq Whisper, OpenAI) — protocol exists but no concrete impl in v1.
- Streaming partial transcription.
- Multi-language (English-only via `*.en` Whisper models).
- Custom vocabulary / dictionary.
- Per-app prompt customization beyond the three modes (light / prose / code).
- Sync, accounts, telemetry — none.
- iOS/iPadOS companion.
- Voice commands ("delete that", "new line") — pure dictation only.
- Auto-update mechanism (Sparkle etc).

## Provider Choices

| Concern | Choice | Rationale |
|---|---|---|
| STT engine | WhisperKit (local, MLX) | Free, private, no network. Sub-second on Apple Silicon. Behind `TranscriptionProvider` protocol so Groq Whisper can be added later without touching the orchestrator. |
| Cleanup primary | Groq Llama 3.3 70B | LPU is genuinely fast (~150–300ms inference). 70B handles level-2 cleanup nuance well. ~$0.0001/cleanup. |
| Cleanup fallback | Gemma3 E2B via Ollama | All-local fallback when offline / Groq down / rate-limited. Reliable for level-1 cleanup, acceptable for level-2. |
| Cleanup level | Level 2 — collapse false starts, fix punctuation, preserve technical strings | Whisprflow-equivalent; the bar users expect. |
| Hotkey | Right Option, hold-to-talk (rebindable) | Most reliable interaction model; zero ambiguity about start/stop. Right Option default because it's rarely used standalone. |
| Paste | Clipboard swap + synthetic ⌘V with `org.nspasteboard.TransientType` tag | Works in every text field on macOS. Clipboard managers respect the transient tag. |
| App shell | Menu bar app + standalone Settings window (`LSUIElement = true`) | Lightest footprint; settings will grow beyond a popover. |
| Recording feedback | Floating HUD, anchored bottom-center of `NSScreen.main` | Predictable position; never wonder where it went. |
| Context awareness | Per-app cleanup mode overrides (config-driven) | Predictable, debuggable, no LLM-classifier latency hit or misclassification footgun. |

## Architecture

**Single-target SwiftUI macOS app**, one process. No XPC helper. Heavy work runs on isolated Swift actors so it never blocks `@MainActor`. Provider abstractions allow swapping STT / Cleanup implementations without changing the orchestrator.

### Module layout

```
Murmur/
├── App/
│   ├── MurmurApp.swift              # @main, menu bar setup
│   └── AppDelegate.swift            # NSApp lifecycle, status item
├── Hotkey/
│   └── HotkeyMonitor.swift          # Right-Option hold detection
├── Audio/
│   ├── AudioRecorder.swift          # AVAudioEngine → 16kHz PCM buffer
│   └── AudioBuffer.swift            # In-memory ring buffer, 60s cap
├── STT/
│   ├── TranscriptionProvider.swift  # Protocol
│   └── WhisperKitProvider.swift     # Default impl
├── Cleanup/
│   ├── CleanupProvider.swift        # Protocol
│   ├── CleanupMode.swift            # .light / .prose / .code
│   ├── PromptBuilder.swift          # System prompts per mode
│   ├── GroqProvider.swift           # Primary
│   └── GemmaOllamaProvider.swift    # Fallback
├── Paste/
│   ├── Paster.swift                 # Clipboard swap + ⌘V
│   └── ContextDetector.swift        # frontmostApplication → CleanupMode
├── Pipeline/
│   └── DictationOrchestrator.swift  # Coordinates all stages
├── UI/
│   ├── HUD/
│   │   ├── HUDWindow.swift          # Borderless NSPanel
│   │   ├── HUDViewModel.swift       # State machine
│   │   └── HUDView.swift            # SwiftUI view
│   ├── Settings/
│   │   ├── SettingsWindow.swift
│   │   ├── GeneralTab.swift
│   │   ├── ProvidersTab.swift
│   │   ├── AppOverridesTab.swift
│   │   ├── HistoryTab.swift
│   │   └── AboutTab.swift
│   └── Onboarding/
│       └── OnboardingWindow.swift
├── Storage/
│   ├── KeychainStore.swift          # Secrets (Groq API key)
│   ├── SettingsStore.swift          # UserDefaults wrapper
│   └── HistoryStore.swift           # JSON file, last 50 entries
└── Resources/
    ├── Defaults.plist               # Default per-app overrides
    └── Prompts/                     # Cleanup prompt templates per mode
```

### Concurrency model

- `DictationOrchestrator`, `AudioRecorder`, all provider implementations are `actor`s — no locks, no queues.
- UI updates marshal to `@MainActor` via `MainActor.run { ... }`.
- Each pipeline run is a structured `Task` owned by the orchestrator. New recording cancels any in-flight task.
- All provider methods accept implicit cancellation via `Task.isCancelled` checks at await points.

## Data Flow

### Happy path (target: <1.5s end-to-end for a 5s clip)

```
t=0       Right Option pressed
          → HotkeyMonitor.onPress
          → DictationOrchestrator.startRecording()
          → AudioRecorder.start()       (AVAudioEngine, 16kHz mono PCM)
          → HUDViewModel.state = .recording
          → HUDWindow appears w/ live audio meter

t=Xms     Right Option released
          → HotkeyMonitor.onRelease
          → DictationOrchestrator.stopRecording()
          → AudioRecorder.stop() returns Data
          → HUDViewModel.state = .transcribing

          (async)
          → TranscriptionProvider.transcribe(pcm) → String
            (WhisperKit, ~300–800ms for a 5s clip on M2)
          → HUDViewModel.state = .cleaning

          → ContextDetector.modeForFrontmostApp() → CleanupMode
            (NSWorkspace.shared.frontmostApplication.bundleIdentifier
             → SettingsStore.appOverrides lookup)

          → CleanupProvider.clean(text, mode) → String
            (Groq Llama 3.3 70B, ~150–300ms)
          → HUDViewModel.state = .pasted

          → Paster.paste(cleanedText)
            • save current NSPasteboard.general contents
            • write cleanedText with org.nspasteboard.TransientType tag
            • CGEvent post ⌘V down/up
            • after 200ms, restore prior pasteboard if changeCount unchanged
          → HistoryStore.append(raw, cleaned, bundleID, timestamp)
          → HUDWindow fades out (200ms)
```

### Failure paths — every failure has a defined behavior

| Failure | Behavior |
|---|---|
| Mic permission revoked mid-session | HUD error: "Microphone unavailable", deeplink to System Settings. |
| Recording exceeds 60s cap | AudioBuffer auto-stops, processes captured audio, brief HUD note: "Capped at 60s". |
| Escape pressed during recording | Buffer discarded, HUD fades, nothing pasted. |
| WhisperKit model not loaded | HUD error w/ "Download model" action triggering WhisperKit downloader. |
| WhisperKit returns empty (silence) | HUD: "No speech detected", fade out. No paste. |
| Groq times out (>2s) or errors | Fall through to Gemma3 (Ollama). HUD shows "via Gemma" indicator. |
| Ollama not running | Skip cleanup, paste raw transcript, HUD note: "Cleanup unavailable". |
| Both cleanup providers fail | Paste raw transcript. Never lose words. |
| No focused text field | Skip ⌘V, copy to clipboard with normal pasteboard type, toast: "Copied — no field focused". |
| User copies during 200ms restore window | Detected via `NSPasteboard.changeCount` check before restore — abort restore. |

## HUD State Machine

| State | Visual | Trigger |
|---|---|---|
| `.idle` | hidden | default |
| `.recording` | red dot, live waveform, timer | hotkey down |
| `.transcribing` | spinner + "Transcribing…" | hotkey up |
| `.cleaning` | spinner + "Polishing… [via Groq/Gemma]" | STT complete |
| `.pasted` | green check + "Pasted (N words)", 800ms fade | paste complete |
| `.copiedOnly` | clipboard icon + "Copied (no field focused)" | no AX target |
| `.error` | red ✕ + message + dismiss button | any failure |

**Visual spec:**
- Floating `NSPanel`, level `.statusBar`, anchored 60pt above the visible bottom edge of `NSScreen.main`, horizontally centered. Recomputes on `NSApplication.didChangeScreenParametersNotification`.
- Capsule shape, `.thinMaterial` background, ~280pt × 44pt resting size (grows to fit text).
- `canBecomeKey = false`, `.transient` collection behavior, `ignoresMouseEvents = true` except on dismiss button.
- 200ms ease-in-out fade transitions between states.
- Waveform: redraws @ 30fps from 100-sample audio meter ring buffer fed by `AVAudioEngine` tap.

## Settings Window

**5 tabs:**

1. **General** — hotkey rebinder (record-key UI), max recording length slider (10s–5min, default 60s), launch-at-login toggle, show-menu-bar-icon toggle.
2. **Providers** —
   - STT: WhisperKit + model selector (`tiny.en` / `base.en` / `small.en` / `medium.en`). Default `small.en`.
   - Cleanup primary: Groq API key (with "Test connection"), model selector. Default `llama-3.3-70b-versatile`.
   - Cleanup fallback: Gemma3 toggle, Ollama detection status (reachable / not reachable), "Open Ollama" link if not installed.
3. **App Overrides** — table of `Bundle ID | App Name | Cleanup Mode`. Pre-populated from `Defaults.plist`. User can add/edit/remove. "Pick from running apps" populates from `NSWorkspace.runningApplications`.
4. **History** — last 50 entries, columns: time, app icon + name, raw transcript (truncated), cleaned transcript (truncated). Click row to expand. Per-row: copy raw / copy cleaned / delete. "Clear all" at bottom. "Save history" toggle (default on).
5. **About** — version, permissions status (Mic ✓, Accessibility ✓), open data folder button, credits.

### Default per-app overrides (`Defaults.plist`)

| Bundle ID | Mode |
|---|---|
| `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `org.alacritty` | `.light` |
| `com.apple.dt.Xcode`, Cursor, `com.microsoft.VSCode`, `dev.zed.Zed` | `.code` |
| (default for unmapped) | `.prose` |

> Bundle IDs above are starting points. Verify each at implementation time by inspecting `/Applications/<App>.app/Contents/Info.plist` `CFBundleIdentifier` — Cursor in particular ships under a Todesktop-generated bundle ID that changes with updates and should be confirmed locally before committing to `Defaults.plist`.

## Onboarding (first launch only)

3 required steps + 1 optional, each blocking `Continue` until satisfied:

1. **Welcome.** One-line description + Continue.
2. **Microphone access.** Button triggers `AVCaptureDevice.requestAccess(for: .audio)`. ✓ when granted.
3. **Accessibility access.** Button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. Poll `AXIsProcessTrusted()` every 500ms; ✓ when granted.
4. **Cleanup provider (optional).** Paste Groq key + test, or "skip — use Ollama only", or "skip — use raw transcription".

After completion: brief tutorial bubble on the menu bar icon: "Hold Right Option to dictate."

## Menu Bar Icon

SF Symbol `mic.fill`. States:
- **Idle:** gray
- **Recording:** red
- **Processing:** animated (subtle pulse)

Click opens menu: Open Settings · History · Pause Murmur (disables hotkey) · Quit.

## Storage

- **Keychain (`kSecClassGenericPassword`):** Groq API key. Service: `com.murmur.app`. Account: `groq-api-key`.
- **UserDefaults (via `SettingsStore`):** all non-secret settings, JSON-encoded for forward-compat.
- **History file:** `~/Library/Application Support/Murmur/history.json`. Append-write, capped at 50 entries (rotates oldest out). Plain JSON array of `{timestamp, raw, cleaned, bundleID, appName}`.

## Audio Format

- 16kHz, mono, 16-bit PCM (Whisper's native input — no resampling needed).
- Lives in memory only; no temp file written during normal operation.
- Discarded immediately after transcription completes (or fails).

## Cleanup Prompts (per mode)

Each mode is a system prompt template stored in `Resources/Prompts/`. Sketch:

- **`.light`** — "Add punctuation and capitalization. Remove only obvious filler words ('um', 'uh'). Do not rephrase. Preserve every other word verbatim."
- **`.prose`** — "Clean up dictated speech: add punctuation, fix capitalization, remove filler words ('um', 'uh', 'like'), and collapse false starts (e.g., 'I was, I mean, I wanted' → 'I wanted'). Preserve the speaker's voice and word choices. Preserve technical strings, identifiers, file paths, and code verbatim."
- **`.code`** — "The user is dictating code or command-line text. Add punctuation only where it would appear in the source. Convert spelled-out symbols ('open paren', 'equals') to their characters. Do not rephrase, restructure, or 'improve' anything. Preserve every identifier, flag, and path verbatim."

User cannot edit these in v1. Per-app prompt customization is a non-goal.

## Testing Strategy

### Unit tests (Swift Testing, fast, no I/O)

- `DictationOrchestratorTests` with mocks for every provider — happy path, cancellation at every stage, empty STT, primary cleanup fails → fallback engaged, both fail → raw paste, no focused field → copy-only branch, Escape during recording.
- `ContextDetectorTests` — bundle ID lookups, user override beats default.
- `AudioBufferTests` — write past 60s cap, ring-buffer semantics.
- `KeychainStoreTests` — round-trip in test keychain.
- `SettingsStoreTests` — encode/decode all shapes.
- `HistoryStoreTests` — append / read / delete / cap-at-50.
- `PromptBuilderTests` — each mode produces prompts with the expected guards.

### Integration tests (gated)

- `WhisperKitProviderIntegration` — bundled `test_audio.wav`, assert transcription contains expected words. Tagged `.integration`; skipped in CI without model.
- `GroqProviderIntegration` — gated on `GROQ_API_KEY` env var; assert disfluent input cleans to expected shape.
- `GemmaOllamaProviderIntegration` — gated on Ollama reachable + `gemma3:e2b` pulled.
- `PasterIntegration` — local-only; opens TextEdit, sends a string, reads back via AX, asserts equality, restores pasteboard.

### Manual test matrix

Per release, dictate into: TextEdit, Notes, Terminal, Xcode, Cursor, Slack, Chrome address bar, Google Docs, Gmail compose, native Mail compose. Verify paste lands and clipboard restores. Record perceived latency.

### Performance budgets (tracked)

| Stage | Budget |
|---|---|
| Hotkey-down → recording active | <50ms |
| Hotkey-up → first STT token | <300ms |
| STT done → cleanup done | <500ms (Groq) / <2000ms (Gemma) |
| Cleanup done → text on screen | <100ms |
| **Total (5s clip, Groq path)** | **<1.5s** |

Misses trigger spec revisit, not just an "optimize later" ticket.

### Out of v1 testing scope

- HUD pixel rendering (visual inspection).
- Onboarding flow automation (manual walkthrough).
- Snapshot/UI tests (too brittle).

## Open Questions

1. **Right Option detection mechanism.** `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` may be flaky for modifier-only events; may require `CGEventTap` + Input Monitoring entitlement. Prototype both on day 1; pick whichever avoids Input Monitoring.
2. **WhisperKit default model.** Benchmark `base.en` vs `small.en` vs `medium.en` on M-series Macs with realistic 5–10s clips. Default to `small.en` provisionally; revisit after measurement.
3. **Streaming transcription.** Out of scope for v1, but the orchestrator's async-stream-friendly shape should not preclude it.
4. **History storage backend.** JSON for v1 (50 entries; trivial). Migrate to SQLite/GRDB if history grows.
5. **Codesigning + entitlements.** Hardened runtime, notarization, `com.apple.security.device.audio-input` + Accessibility usage strings — set up the entitlements file from project creation, even though distribution is out of v1 scope.

## Risks

- **Right Option detection edge cases** — international keyboards, external keyboards, BetterTouchTool/Karabiner remappings. Mitigation: hotkey rebindable from day 1.
- **Clipboard restore race** — clipboard managers may still cache despite transient tag. Mitigation: ship with `org.nspasteboard.TransientType` tag, document edge case.
- **Ollama dependency drift** — Ollama API or model names may change. Mitigation: provider abstraction allows swapping; pin assumed Ollama version in docs.
- **WhisperKit memory footprint** — `medium.en` ~1.5GB resident. Mitigation: default `small.en`; offer model picker.
- **Accessibility silently revoked** — macOS occasionally drops AX trust on app updates. Mitigation: orchestrator polls `AXIsProcessTrusted()` before paste; surfaces re-grant flow if lost.
- **"Vibe code without touching computer" goal** — hold-to-talk requires touching the computer. Voice alone is a partial solution by design; hand tracking subsystem closes the loop.

## Future Work (post-v1, in rough order)

1. **Hand tracking subsystem** (separate spec) — Vision framework `VNDetectHumanHandPoseRequest` driving `CGEvent` mouse + gesture-mapped shortcuts.
2. **VAD-based auto-stop** as an alternative to hold-to-talk.
3. **Streaming partial transcription** in the HUD.
4. **Cloud STT providers** (Groq Whisper, OpenAI) as protocol implementations.
5. **Voice commands** ("delete that", "select line", "new paragraph").
6. **Custom vocabulary** for names, acronyms, jargon.
7. **Multi-language support** via non-`.en` Whisper models.
