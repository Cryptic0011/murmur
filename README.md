<p align="center">
  <img src="Murmur/Resources/AppIcon.iconset/icon_512x512@2x.png" alt="Murmur app icon" width="160">
</p>

<h1 align="center">Murmur</h1>

<p align="center">Push-to-talk dictation for macOS with visible transcription, cleanup, and paste feedback.</p>

<p align="center">
  <a href="https://usemurmurapp.vercel.app/">Website</a>
</p>

Murmur is a macOS menu bar app for fast voice dictation. Hold your hotkey, speak naturally, and Murmur records, transcribes, optionally cleans the text, then pastes it into the active app. It is designed to be usable with fully local models, API-backed models, or a mix of both.

## Features

- Menu bar dictation app for macOS
- Push-to-talk hotkey with custom shortcut capture
- Local transcription with WhisperKit or Parakeet (FluidAudio), or Apple Speech on macOS 26+
- Optional cloud transcription with Groq (falls back to a downloaded WhisperKit model on failure)
- Cleanup with Groq, Cerebras, any OpenAI-compatible endpoint, Ollama, Apple Intelligence (macOS 26+), or built-in rules only
- Live hosted model lists and automatic recovery from retired models
- Adjustable AI cleanup cutoff, recording sounds, and dictation capsule visibility
- Per-app cleanup styles for prose, email, chat, notes, prompts, and code
- Microphone picker and in-app dictation test flow
- Visible runtime/setup state instead of silent failures
- Signed Sparkle updates from GitHub Releases (checked every 12 hours)
- Optional `murmur://` URL control for Shortcuts, Raycast, or Stream Deck (off by default)

## Privacy

Murmur can run fully locally, but cloud providers receive audio or transcript
content when you select them. API keys are stored in macOS Keychain, recorded
audio stays in memory and is never written to disk, and local dictation history
is off by default. See [PRIVACY.md](PRIVACY.md) for the complete data-flow and
storage details.

## Install

### Option 1: Download the latest DMG

Open the releases page and download `Murmur.dmg` from the latest published release:

```text
https://github.com/Cryptic0011/murmur/releases
```

Install steps:

1. Download `Murmur.dmg`
2. Open the DMG
3. Drag `Murmur.app` into `Applications`
4. Launch Murmur from `Applications`
5. Grant microphone and accessibility permissions when prompted

### Option 2: Build from source

Prerequisites:

- Xcode 26 or newer (the macOS 26 SDK is required for Apple Speech and
  Apple Intelligence support), which needs macOS 15.6 or newer to run
- Homebrew and `xcodegen`

The built app runs on macOS 14 or newer. Dependency versions are locked in
`Murmur.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`;
Xcode resolves exactly those versions on a fresh clone.

Setup:

```bash
brew install xcodegen
xcodegen generate
open Murmur.xcodeproj
```

Or build from Terminal:

```bash
xcodegen generate
xcodebuild -scheme Murmur -destination 'platform=macOS' build
```

For a local install flow that rebuilds and copies the app into `/Applications`, use:

```bash
./scripts/install-dev.sh
```

The script builds into `build/DerivedData`, stops on build errors, refuses to
replace a Developer ID release install unless run with `FORCE=1`, and resets
Murmur's Microphone and Accessibility permissions. Debug builds are ad-hoc
signed, so macOS asks for those permissions (and Keychain access to saved API
keys) again after each install.

## Prerequisites

Murmur always needs:

- Microphone permission
- Accessibility permission
- macOS 14+

Depending on how you configure providers, you may also need:

- A Groq, Cerebras, or custom endpoint API key for those providers
- Ollama installed locally for Ollama cleanup
- A one-time model download for WhisperKit or Parakeet

Local speech models download on first use. WhisperKit models are stored in
`~/Library/Application Support/Murmur/Models` (the model that older versions saved
under `~/Documents/huggingface` is copied there once; the original is left for other
WhisperKit tools). Parakeet models are
stored by FluidAudio in `~/Library/Application Support/FluidAudio/Models`.

## First Run

On first launch, Murmur walks through the required permissions and runtime checks.

Recommended first-run path:

1. Launch Murmur
2. Grant microphone access
3. Grant Accessibility access so Murmur can monitor the hotkey and paste text
4. Open Settings
5. Choose your transcription and cleanup providers
6. Use `Try Murmur` to test microphone input and run a no-paste dictation test
7. Test your provider connection if using Groq or Cerebras
8. Try the default hotkey and adjust it if needed

## Provider Setup

Murmur supports several practical setups.

### Fully local

- Transcription: WhisperKit, Parakeet, or Apple Speech (macOS 26+)
- Cleanup: Built-in rules, Apple Intelligence (macOS 26+), or Ollama

Use this if you want to avoid external API calls. Built-in rules and Apple
Intelligence need no extra install. Ollama must be installed and running on
`localhost:11434`:

```text
https://ollama.com/download/mac
```

### Mixed

- Transcription: WhisperKit or Parakeet
- Cleanup: Groq, Cerebras, or a custom OpenAI-compatible endpoint

This is a good default if you want local speech-to-text but stronger cleanup options.

### API-backed

- Transcription: Groq
- Cleanup: Groq, Cerebras, or a custom endpoint

Use this if you want to avoid local model setup and you are fine with API usage.

### Custom endpoint

Choose **Custom endpoint** for cleanup to use any OpenAI-compatible
`/chat/completions` server (for example LM Studio or a hosted gateway). Remote
endpoints must use HTTPS; plain HTTP is allowed only for `localhost`. The
optional API key is stored in Keychain.

## Groq API Key Setup

You only need a Groq key if you select a Groq provider in Murmur.

Steps:

1. Create or sign into your Groq account
2. Open the Groq keys page:

```text
https://console.groq.com/keys
```

3. Create a new API key
4. Open Murmur
5. Go to `Settings` > `Providers`
6. Paste the key into the `Groq API key` field
7. Click `Save Key`
8. Click `Test Connection`

Notes:

- Murmur stores the Groq key in the macOS keychain; surrounding whitespace is
  trimmed, and saving an empty field removes the key
- The same key is used for Groq transcription and Groq cleanup
- If you do not use Groq in your provider settings, you do not need a key
- If Groq is selected but no key is saved, the setup card shows an `Open Groq Keys` action that opens the Groq keys page

Groq cleanup defaults to `openai/gpt-oss-20b`; Cerebras cleanup defaults to
`gpt-oss-120b`. Saved retired Llama defaults migrate automatically. Use
**Refresh Models** in Providers to choose from the provider's live catalog.
A retired model error triggers one retry with an available replacement on the
same provider; authentication and rate-limit errors do not switch models.

Select **Built-in rules only** to clean up text without an AI model. The
**AI cleanup minimum** controls how many words trigger AI cleanup (default 12;
0 always uses the selected provider). General settings also let you disable
recording sounds or the dictation capsule.

When Groq transcription fails, Murmur uses the selected WhisperKit model if it
is already downloaded. It does not download a fallback model during dictation.
Selecting Groq still sends audio to Groq before attempting local fallback.

## Usage

Basic flow:

1. Hold the push-to-talk hotkey
2. Speak
3. Release the hotkey
4. Murmur transcribes and optionally cleans the text
5. Murmur pastes into the focused text field

If there is no editable field focused, Murmur shows the result state instead of silently failing.

### URL control

Murmur can be driven by other apps with `murmur://toggle`, `murmur://start`,
`murmur://stop`, `murmur://cancel`, and `murmur://settings`. Because any app
or web page can open these URLs, starting or stopping dictation by URL is off
by default; turn on URL control in Settings to allow it.

### History

History is off by default. When enabled, the newest 50 dictations are saved
to `~/Library/Application Support/Murmur/history.json`, readable only by your
user account (permissions 0600). Turning history off stops saving new entries;
use **Clear All** in Settings > History to delete saved ones. If the file
becomes unreadable, Murmur moves it aside as `history.corrupt-<timestamp>.json`
in the same folder and starts a new history.

## Updates

Murmur uses Sparkle 2 to check a signed appcast hosted with GitHub Releases.

- New users install Murmur from the signed and notarized DMG
- Existing users can download and install updates directly inside Murmur
- Update archives are verified with Sparkle EdDSA signatures and Apple code signing
- Murmur checks for updates every 12 hours; automatic checks can be disabled
  in `Settings` > `About`

Official public builds are Developer ID signed, notarized by Apple, and
distributed with SHA-256 checksum files alongside the DMG and Sparkle appcast.

## Troubleshooting

### Murmur is not recording

Check:

- microphone permission is granted
- the hotkey is not paused
- the selected transcription provider is configured correctly

### Murmur is not pasting

Check:

- Accessibility permission is granted
- the target app has an editable field focused

### Groq is failing

Check:

- your API key is saved
- `Test Connection` succeeds in `Settings` > `Providers`
- you selected a Groq-backed provider

### Ollama is failing

Check:

- Ollama is installed
- Ollama is running locally
- it is reachable on `localhost:11434`

## Development

Project generation:

```bash
xcodegen generate
```

Open in Xcode:

```bash
open Murmur.xcodeproj
```

Run tests:

```bash
xcodebuild test -scheme Murmur -destination 'platform=macOS'
```

## Repository Docs

- Design spec: [docs/superpowers/specs/2026-04-13-voice-dictation-design.md](docs/superpowers/specs/2026-04-13-voice-dictation-design.md)
- Implementation plan: [docs/superpowers/plans/2026-04-13-voice-dictation.md](docs/superpowers/plans/2026-04-13-voice-dictation.md)
