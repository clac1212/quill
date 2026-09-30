# quill — fr-ultra fork

Fork of [humanitas-labs/quill](https://github.com/humanitas-labs/quill), a fully
local meeting recorder/transcriber. This fork adds:

- **French transcription** — Parakeet Ultra (multilingual) via FluidAudio.
- **Voice identification** — who said what, named once and recognized in every
  later meeting. Design and measurements: `docs/decisions/002-voice-identification.md`.

Only `macos/` is worked on. Architecture: `docs/architecture.md`. User docs:
`macos/README.md`.

## Fork rules

- Branch `fr-ultra`, rebased on `upstream/main`. **Never move or rename upstream
  files**; put new code in new files and keep edits to upstream files small, so
  rebases stay cheap.
- Transcript/session JSON changes are additive and optional: `speaker` keeps
  its `me`/`them` meaning, older sessions must stay readable.
- Voice embeddings are biometric data: never commit them, log them, or use real
  ones as fixtures. Tests use hand-built vectors.
- Recordings live in `~/Recordings` — the user's data. Test on copies.

## Commands

Run from the repo root. Give the user commands alone in a code block — they
copy-paste, and trailing punctuation has broken commands before.

```sh
./scripts/build-macos                                   # release build → macos/.build/release/quill
sudo ./scripts/install-macos                            # copy to /usr/local/bin/quill (what launchd runs)
launchctl kickstart -k gui/$(id -u)/com.digimata.quill  # restart the running daemon on the new binary
tail -20 /tmp/quill.err.log                             # daemon log
```

quill is a menu-bar daemon, not a `.app`: a LaunchAgent
(`~/Library/LaunchAgents/com.digimata.quill.plist`) starts it at login and
restarts it only after a crash. A session's own log is
`~/Recordings/<session>/transcribe.log`. Deleting or renaming a session's
`transcript.json` makes the daemon re-transcribe it at next launch.

Tests (Xcode is required for XCTest; if `xcode-select -p` shows
CommandLineTools, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`):

```sh
cd macos && swift test
```

## Layout (macOS)

| Path | What |
|---|---|
| `Sources/quill/` | the executable: capture, transcription queue, menu bar |
| `Sources/quill/Transcription/Voices.swift` | pure voice logic: attribution, echo filter, matching, directory — unit-tested |
| `Sources/quill/Transcription/VoiceAnalyzer.swift` | FluidAudio models (Nemotron 3 Diarization, WeSpeaker) |
| `Sources/quill/Transcription/VoiceLibrary.swift` | naming voices and propagating names across sessions |
| `Sources/QuillUI/` | SwiftUI naming window, behind the `VoicesStore` protocol |
| `Sources/quill/UI/VoicesWindow.swift` | opens that window; `RecordingsVoicesStore` backs it with the disk |

## UI iteration

Xcode can't preview SwiftUI in the executable target, so views go in
`QuillUI`. Open `macos/Package.swift` in Xcode, then
`Sources/QuillUI/VoicesView.swift` with the canvas (⌥⌘↩). The previews use
`PreviewVoicesStore` (in-memory, interactive). Edit the file and the canvas
updates live — no build/install needed until the final check in the real app.

## Measuring before changing thresholds

Voice thresholds (0.6 cosine, 90 % echo overlap, 3 s windows) come from the
user's real meetings, recorded in ADR-002. Re-measure on real audio before
changing them. The FluidAudio CLI helps: build it from
`macos/.build/checkouts/FluidAudio` (copy it elsewhere first) and run
`fluidaudiocli nemotron3-diarize <16 kHz mono wav> --variant offline --output out.rttm`.
