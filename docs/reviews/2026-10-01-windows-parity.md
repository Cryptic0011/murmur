# Windows changes brought back to macOS

Compared macOS `cd0b463` plus the existing working-tree changes with
[Cryptic0011/murmur-windows](https://github.com/Cryptic0011/murmur-windows)
at `ba91a66` (its current main branch). The Windows repository is a C#/.NET 8
WPF port, so its files cannot be merged directly into the Swift macOS app.

| Windows behavior | macOS result |
| --- | --- |
| Current Groq/Cerebras cleanup models | Default to `openai/gpt-oss-20b` / `gpt-oss-120b`; migrate saved retired Llama defaults, preserve other user selections. |
| GPT-OSS request compatibility | No assistant prefill, low reasoning effort, extra completion budget; hide reasoning on Groq. Existing output validation remains in place. |
| Live model lists | Refresh Models and select hosted cleanup/transcription models in Providers; manual model entry remains available. |
| Recovery from retired cleanup/transcription models | On a model-unavailable error, list active models and retry once with a replacement from the same provider. Remember successful replacements for future dictations. |
| Cloud-to-local transcription fallback | Use the selected, already-downloaded WhisperKit model after a Groq failure. No surprise model download; cancellation does not trigger fallback. |
| Built-in rules only | Explicit cleanup provider using the existing LocalCleanup implementation. |
| Adjustable cleanup word threshold | Providers setting, default 12, range 0–200; 0 always attempts the selected provider. |
| Sound and HUD toggles | General settings with enabled defaults, preserving the Mac's existing behavior. |
| Capture field/app context before transcription | Snapshot the cleanup context before asynchronous transcription can let the focused field change. |
| Wider app style coverage | Add locally verified Mac bundle IDs for Obsidian, Telegram, and Cursor. |
| Vocabulary, replacements, silence trimming, hallucination filtering, history, clipboard restore, toggle mode, Enter-after-paste | Already present on macOS. |
| Tray menu recording control | Add Start or Stop Dictation to the Mac menu using the existing URL toggle handler. |
| Remote control via second process | Add the settings URL; Mac already supports `murmur://` start/stop/toggle/cancel/settings URLs. |
| Windows installer, DPAPI secrets, registry startup, process IDs, CPU/Vulkan/CUDA Whisper builds | Platform-specific; retain macOS Keychain, login items, bundle IDs, and Core ML. |
| Windows lacks auto-update and streaming transcription | Retain existing Mac updater and streaming transcription. |

The existing local updater, settings, HUD, installation-script, and iOS changes
were preserved.

## Model verification

[Groq deprecations](https://console.groq.com/docs/deprecations) confirms the
August 16, 2026 retirement of `llama-3.1-8b-instant` and
`llama-3.3-70b-versatile` for free/developer tiers.
[Groq reasoning](https://console.groq.com/docs/reasoning) documents GPT-OSS low
reasoning effort and `include_reasoning: false`.
[Cerebras deprecations](https://inference-docs.cerebras.ai/support/deprecation)
lists the May 27, 2026 retirement of `llama3.1-8b` and recommends GPT-OSS 120B
for retired Llama 70B.

## Verification

`xcodebuild test -scheme Murmur -destination 'platform=macOS'
-derivedDataPath /tmp/murmur-port-build CODE_SIGN_IDENTITY=-` passed:
23 XCTest checks plus 76 Swift Testing checks, 99 total, zero failures.
`git diff --check` also passed. The development build is saved at
`dist/windows-parity/Murmur.app`; the installed `/Applications` app was not replaced.
The test host skips normal runtime startup to avoid prompting for real Keychain
credentials or starting dictation while running unit tests.


Regression checks cover GPT-OSS and ordinary request payloads, live catalog
filtering, one retry on retirement, no retry on authentication/rate limits,
saved-model migration, settings persistence, built-in cleanup, local fallback,
cancellation, and excluding incomplete local model downloads.

Cloud responses are stubbed in tests. A real provider connection and physical
microphone/hotkey/paste check remain manual validation steps.
