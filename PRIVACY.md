# Murmur Privacy

Murmur records audio only while a dictation session is active. Audio is kept in
memory, never written to disk, and discarded once transcription finishes or
fails.

## Processing choices

- WhisperKit, Parakeet, Apple Speech, Apple Intelligence, built-in rules, and
  Ollama processing run locally on the Mac. Downloading a WhisperKit or
  Parakeet model contacts Hugging Face, but dictated audio and transcript text
  are never sent there.
- When Groq transcription is selected, Murmur sends the recorded audio and any
  configured vocabulary prompt to Groq over HTTPS. If Groq fails, Murmur may
  then transcribe the same audio locally with an already-downloaded WhisperKit
  model.
- When Groq, Cerebras, or a custom cleanup provider is selected, Murmur sends
  the transcript, cleanup instructions, configured vocabulary, and limited text
  from the focused field to that provider. Murmur requires HTTPS for remote
  custom endpoints; plaintext HTTP is permitted only for localhost.
- Listing a hosted provider's models (when you refresh or test it, or when a
  retired model needs a replacement) sends only your API key to that provider.

Third-party providers process submitted data under their own terms and privacy
policies. Murmur does not operate those services.

## Data stored on the Mac

- Provider API keys are stored in macOS Keychain. Saving an empty key field
  deletes the stored key.
- Preferences are stored in macOS user defaults.
- Dictation history is off by default. If enabled, the newest 50 raw and
  cleaned transcripts, with app names and paste outcomes, are stored in
  `~/Library/Application Support/Murmur/history.json` with owner-only (0600)
  permissions. Murmur also tightens files written by older versions to 0600 at
  launch. Turning history off stops new entries but keeps saved ones until you
  use **Clear All** in Settings > History. If the file becomes unreadable,
  Murmur moves it aside as `history.corrupt-<timestamp>.json` in the same
  folder rather than deleting it.
- Downloaded speech models are stored in
  `~/Library/Application Support/Murmur/Models` (WhisperKit) and
  `~/Library/Application Support/FluidAudio/Models` (Parakeet). On existing
  installs only, the configured WhisperKit model and the Whisper tokenizers
  that older versions saved under `~/Documents/huggingface` are copied once
  (as an APFS clone where the disk supports it) into the Application Support
  store. Nothing in `~/Documents` is moved or deleted. This is the only reason
  Murmur may ask for access to the Documents folder.
- Murmur temporarily uses the system clipboard to paste dictated text. It
  restores the previous clipboard contents after a confirmed paste, and after
  a short delay when a paste can't be confirmed but most likely landed: in a
  code editor, a terminal, a known text field, or an app that doesn't report
  its focused element. When the paste visibly failed, or the focus showed no
  text field to paste into, the dictated text stays on the clipboard so it is
  not lost.
- Text dictated while a password field is focused, or while the frontmost app
  holds secure input, stays on this Mac (it is not shared over Universal
  Clipboard) and is hidden from clipboard managers. If it is left on the
  clipboard, it is cleared after 45 seconds unless something else has been
  copied since. It is never saved to history.

## Permissions

Murmur requests microphone access to record dictation and Accessibility access
to detect the configured global shortcut, inspect the focused editable field,
and paste text into the active app.

Other apps can control Murmur through `murmur://` URLs only if you turn on URL
control in Settings; it is off by default.

Murmur does not include advertising or analytics SDKs.

Murmur uses Sparkle to check the GitHub-hosted update feed every 12 hours
(unless automatic checks are turned off). These requests use standard network
metadata needed to retrieve the feed and update archive; dictation audio,
transcripts, API keys, and local history are never included.
