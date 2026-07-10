# Murmur Privacy

Murmur records audio only while a dictation session is active. It does not keep
audio recordings after transcription finishes or fails.

## Processing choices

- WhisperKit, Parakeet, Apple Speech, Apple Intelligence, and Ollama processing
  run locally on the Mac. Model downloads may contact their respective model
  hosts, but dictated audio and transcript text are not sent to those hosts by
  Murmur.
- When Groq transcription is selected, Murmur sends the recorded audio and any
  configured vocabulary prompt to Groq over HTTPS.
- When Groq, Cerebras, or a custom cleanup provider is selected, Murmur sends
  the transcript, cleanup instructions, configured vocabulary, and limited text
  from the focused field to that provider. Murmur requires HTTPS for remote
  custom endpoints; plaintext HTTP is permitted only for localhost.

Third-party providers process submitted data under their own terms and privacy
policies. Murmur does not operate those services.

## Data stored on the Mac

- Provider API keys are stored in macOS Keychain.
- Preferences are stored in macOS user defaults.
- Dictation history is off by default. If enabled, the last 50 raw and cleaned
  transcripts are stored in `~/Library/Application Support/Murmur/history.json`
  with owner-only file permissions. History can be deleted from Murmur Settings.
- Murmur temporarily uses the system clipboard to paste dictated text and
  restores the previous clipboard contents when the destination confirms the
  paste. If automatic paste cannot be confirmed, the dictated text remains on
  the clipboard so it is not lost.

## Permissions

Murmur requests microphone access to record dictation and Accessibility access
to detect the configured global shortcut, inspect the focused editable field,
and paste text into the active app.

Murmur does not include advertising or analytics SDKs.

Murmur uses Sparkle to check the GitHub-hosted update feed. These requests use
standard network metadata needed to retrieve the feed and update archive;
dictation audio, transcripts, API keys, and local history are never included.
