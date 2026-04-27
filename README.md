<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Murmur/Assets.xcassets/MurmurMark.imageset/murmur-mark-light.png">
    <source media="(prefers-color-scheme: light)" srcset="Murmur/Assets.xcassets/MurmurMark.imageset/murmur-mark-dark.png">
    <img src="Murmur/Assets.xcassets/MurmurMark.imageset/murmur-mark-dark.png" alt="Murmur logo" width="140">
  </picture>
</p>

<h1 align="center">Murmur</h1>

<p align="center">Push-to-talk dictation for macOS with visible transcription, cleanup, and paste feedback.</p>

Murmur is a macOS menu bar app for fast voice dictation. Hold your hotkey, speak naturally, and Murmur records, transcribes, optionally cleans the text, then pastes it into the active app. It is designed to be usable with fully local models, API-backed models, or a mix of both.

## Features

- Menu bar dictation app for macOS
- Push-to-talk hotkey with custom shortcut capture
- Local transcription with WhisperKit
- Optional local transcription with Apple Speech on supported macOS versions
- Optional API transcription and cleanup with Groq
- Optional cleanup with Ollama, Gemini CLI OAuth, or ChatGPT via Codex CLI OAuth
- Per-app cleanup styles for prose, email, chat, notes, prompts, and code
- Microphone picker and in-app dictation test flow
- Visible runtime/setup state instead of silent failures
- Automatic update checks against GitHub Releases

## Install

### Option 1: Download the latest DMG

Use the latest stable download link:

```text
https://github.com/Cryptic0011/murmur/releases/latest/download/Murmur.dmg
```

Install steps:

1. Download `Murmur.dmg`
2. Open the DMG
3. Drag `Murmur.app` into `Applications`
4. Launch Murmur from `Applications`
5. Grant microphone and accessibility permissions when prompted

### Option 2: Build from source

Prerequisites:

- macOS 14 or newer
- Xcode
- Homebrew
- `xcodegen`

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

## Prerequisites

Murmur always needs:

- Microphone permission
- Accessibility permission
- macOS 14+

Depending on how you configure providers, you may also need:

- A Groq API key for Groq transcription or cleanup
- Ollama installed locally for local cleanup with Gemma
- WhisperKit model download for local transcription

## First Run

On first launch, Murmur walks through the required permissions and runtime checks.

Recommended first-run path:

1. Launch Murmur
2. Grant microphone access
3. Grant Accessibility access so Murmur can monitor the hotkey and paste text
4. Open Settings
5. Choose your transcription and cleanup providers
6. Use `Try Murmur` to test microphone input and run a no-paste dictation test
7. Test your provider connection if using Groq, Gemini CLI, or ChatGPT OAuth
8. Try the default hotkey and adjust it if needed

## Provider Setup

Murmur supports several practical setups.

### Fully local

- Transcription: WhisperKit
- Cleanup: Ollama / Gemma

Use this if you want to avoid external API calls.

You will need:

- a WhisperKit model
- Ollama installed and running on `localhost:11434`

Download Ollama:

```text
https://ollama.com/download/mac
```

### Mixed

- Transcription: WhisperKit
- Cleanup: Groq, Ollama, Gemini CLI, ChatGPT OAuth, or Apple Intelligence

This is a good default if you want local speech-to-text but stronger cleanup options.

### API-backed

- Transcription: Groq
- Cleanup: Groq

Use this if you want to avoid local model setup and you are fine with API usage.

### OAuth cleanup

- Transcription: WhisperKit or Groq
- Cleanup: Gemini CLI or ChatGPT via Codex CLI

Use this if you already use one of those CLIs and prefer OAuth sign-in over pasting API keys.

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

- Murmur stores the Groq key in the macOS keychain
- The same key is used for Groq transcription and Groq cleanup
- If you do not use Groq in your provider settings, you do not need a key
- If Groq is selected but no key is saved, the setup card shows an `Open Groq Keys` action that opens the Groq keys page

## Usage

Basic flow:

1. Hold the push-to-talk hotkey
2. Speak
3. Release the hotkey
4. Murmur transcribes and optionally cleans the text
5. Murmur pastes into the focused text field

If there is no editable field focused, Murmur shows the result state instead of silently failing.

## Updates

Murmur checks GitHub Releases for updates on launch.

- If a newer release exists, the app prompts the user to download it
- The prompt opens the release DMG when available
- Users update by installing the newer app build

This is a download-and-replace update flow, not an in-place auto-installer.

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

## Releases

Interactive all-in-one release flow:

```bash
./scripts/release-interactive.sh
```

The release script walks you through:

1. Choose the release version and build number
2. Optionally run the test suite
3. Commit release app paths only
4. Push the current branch
5. Switch to `main`, pull latest, and merge if needed
6. Create and push an annotated tag like `v0.2.0`
7. Build `dist/Murmur.dmg`
8. Create or update the GitHub Release
9. Upload both `dist/Murmur.dmg` and `dist/Murmur-vX.Y.Z.dmg`

To safely test the prompts without publishing anything, run the script and answer `N` to build, commit, push, tag-from-main, upload release, and final proceed prompts.

The script stages only app release paths:

- `project.yml`
- `Murmur`
- `MurmurTests`
- `Murmur.xcodeproj`
- `scripts`

Unrelated files such as `.DS_Store`, local browser artifacts, generated landing assets, and sibling worktree files are left alone. If those files would block `git pull` or `git switch`, the script asks to temporarily stash and restore them.

Supporting scripts:

```bash
./scripts/bump-version.sh 0.2.0
./scripts/build-release-dmg.sh
```

For signed or notarized DMGs, set these optional environment variables before running the build or release script:

```bash
export MURMUR_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export MURMUR_NOTARY_PROFILE="murmur-notary"
```

Full release notes are documented in [docs/release.md](docs/release.md).

## Repository Docs

- Design spec: [docs/superpowers/specs/2026-04-13-voice-dictation-design.md](docs/superpowers/specs/2026-04-13-voice-dictation-design.md)
- Implementation plan: [docs/superpowers/plans/2026-04-13-voice-dictation.md](docs/superpowers/plans/2026-04-13-voice-dictation.md)
