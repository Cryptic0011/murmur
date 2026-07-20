# Murmur iOS — Design

**Date:** 2026-07-20
**Status:** Approved by Grayson

## Goal

An iPhone version of Murmur matching how Superwhisper/Wispr Flow work on iOS:
Action Button dictation via a Shortcuts-assignable App Intent, plus a custom
keyboard, with transcription fully on-device using NVIDIA Parakeet (FluidAudio
CoreML). Personal build (dev account, iPhone 17 Pro Max); no App Store scope.

## Decisions

- **Keyboard model:** bounce-to-app. Keyboard mic key deep-links into the
  Murmur app to record; app returns to the previous app; keyboard inserts the
  transcript from the App Group. (Background Wispr-style sessions deferred.)
- **STT scope:** Parakeet only (on-device, offline). No cloud providers in v1.
- **Shortcut:** a "Toggle Recording" App Intent that *returns the transcript
  as text*, mirroring Superwhisper's shortcut (If/Otherwise → copy to
  clipboard → notification). Exposed through `AppShortcutsProvider` so it
  appears in the Shortcuts app and Action Button picker with zero setup.

## Targets (same Xcode project)

1. **MurmurIOS app** (SwiftUI, iOS 17+)
   - Hosts mic capture, Parakeet engine, model download (~600MB, first-launch
     progress screen), dictation history, minimal settings.
   - Reuses macOS sources via shared file references: `STT/ParakeetProvider`,
     audio capture, text cleanup.
   - URL scheme `murmur://dictate?return=<bundle-or-scheme>` starts a
     recording session.
2. **App Intent extension (in-app intent)** — `ToggleRecordingIntent`
   - Press 1: opens app foreground, starts recording.
   - Press 2 (or in-app stop): stops, transcribes, returns transcript as the
     intent's string output.
   - Parameters kept minimal (no modes in v1).
   - Registered in an `AppShortcutsProvider` ("Toggle Recording") → visible in
     Shortcuts/Action Button immediately. Ship a sample shortcut matching the
     Superwhisper one (copy to clipboard + notification).
3. **Keyboard extension** — mic key, globe, delete, return, space.
   - No mic/model in-extension (iOS forbids mic; memory cap forbids model).
   - Flow: mic key → deep link → app records → transcript written to App
     Group `UserDefaults` (`group.com.murmur.Murmur`) with a timestamp →
     app returns user to previous app → keyboard reads + inserts + clears.
   - Recording backend behind one function so a session-based backend can
     swap in later.

## Data flow

Keyboard path: keyboard → URL scheme → app (record → Parakeet on ANE →
transcript) → App Group → keyboard inserts.
Action Button path: intent → app records → transcript returned as intent
output → user's Shortcut decides (clipboard/notification/etc.).

## Error handling

- Model not downloaded: keyboard/intent surfaces "Open Murmur to finish
  setup" instead of failing silently.
- Mic permission denied: prompt with link to Settings.
- Empty/failed transcription: intent returns empty string; keyboard inserts
  nothing and shows a brief error state.
- Stale App Group transcript (>60s old): discarded, never inserted.

## Testing

- Unit: transcript handoff (App Group write/read/clear, staleness).
- Manual on-device: Action Button round trip with the sample shortcut;
  keyboard round trip from Notes/Messages; cold-launch with no model.

## Out of scope (v1)

Cloud providers, AI formatting modes, background recording sessions, iPad
layout, App Store submission.
