# ADR-002 :: Voice identification

Last updated: `2026.09.30`

> Split each track into voices on-device (Nemotron 3 Diarization), embed each
> voice (WeSpeaker), and match embeddings against a local directory of names
> the user gives from the menu. Names propagate to every session, so each
> meeting needs fewer names than the last. Fork-only (`fr-ultra`, macOS).

## 1. Decision

- **Diarization:** NVIDIA Nemotron 3 Diarization (up to 8 speakers), offline
  preset, through FluidAudio's Core ML port (`Nemotron3Diarizer`).
- **Embeddings:** WeSpeaker via FluidAudio's `DiarizerManager`, L2-normalized.
  A voice's embedding is the normalized mean over up to 15 clean windows
  (≥ 3 s, nobody else talking, capped at 10 s, spread over the file).
- **Match threshold:** cosine similarity ≥ 0.6 means "same person".
- **Both tracks** are diarized. On the mic track, a voice whose speech falls
  > 90 % inside remote speech is call audio leaking into the mic, not a
  person: it stays plain `me`.
- **Short-turn speakers** (no clean 3 s span) get one embedding from their
  clean turns end to end (≥ 0.3 s each, ≥ 2 s total). That separates them
  within the session; it is too thin to recognize them across sessions.
- **Storage:** per-session `voices.json` (voice id, name, ignored, embedding,
  playable excerpt); a directory at `<recordings root>/.voices/voices.json`
  (name → up to 20 embeddings). Both local-only.
- **Transcript contract:** segments gain optional `voice_id` and `voice`
  (name once known). `speaker` keeps its `me`/`them` meaning; transcripts
  without voices serialize exactly as before.
- **Naming** (menu → *Name voices…*) enrolls the embedding, rewrites that
  session's transcript, then names matching unnamed, non-ignored voices in
  every other session.
- **UI** lives in a `QuillUI` library target, not the executable.

## 2. Rationale

Measured on the user's real French meetings (September 2026), not on
benchmarks:

| Question | Measurement | Consequence |
|---|---|---|
| Does diarization find everyone? | 88-min call, 5 participants: 5 voices on the mixed tracks, including one who spoke 2 min, first at minute 20. Lowering the activity threshold to 0.3 added no speaker. | Default threshold 0.5. |
| Is it fast enough? | 88 min processed in ~11 s (RTFx ≈ 480). | Runs inline after transcription, no opt-in needed. |
| Are extra mic voices people? | Two minor mic "voices" overlapped remote speech 98–99 % of their time; the user's own voice 7 %. The user heard them as unintelligible crosstalk. | Echo filter at 90 %. |
| Same person across meetings? | WeSpeaker centroids: same person 0.80–0.94 across two meetings, different people ≤ 0.45; a newcomer's best match 0.29. 15/15 per-segment votes correct for all four returning speakers. | Threshold 0.6, WeSpeaker. |
| Why not CAM++? | Different people scored 0.4–0.6; the newcomer matched an existing person by a 0.01 margin. | Rejected: cannot say "unknown". |
| Short turns? | A speaker with only 0.3–1.1 s replies: 3.4 s of turns end to end scored 0.35 against the same person's voice from other meetings. | Session-level separation only. |

Nemotron 3 Diarization over the older 4-speaker streaming Sortformer: 8
speakers, and NVIDIA reports ~41 % relative DER reduction. The full release
is OpenMDW 1.1 (commercial use allowed); the gated Hugging Face *preview* is
evaluation-only and must not be used.

The transcript additions are optional fields so upstream readers, the
`on_stop` hook, and older sessions are unaffected. New code sits in new files
(`Voices.swift`, `VoiceAnalyzer.swift`, `VoiceLibrary.swift`, `QuillUI/`) so
rebasing the fork on `upstream/main` stays cheap.

`QuillUI` exists because Xcode cannot preview SwiftUI in an executable target
without `ENABLE_DEBUG_DYLIB`, which a Swift package cannot set. The view talks
to a `VoicesStore` protocol: quill backs it with the recordings folder,
previews and tests with memory.

## 3. Design Implications

- Voice identification is best-effort: any failure (models not downloadable
  offline) logs to `transcribe.log` and leaves the track as `me`/`them`.
- Auto-recognized voices never enroll embeddings; only a user's naming does,
  so a wrong match cannot reinforce itself.
- Ignored voices are never auto-named.
- The voice directory is biometric data. It never leaves the machine and must
  not be committed, logged, or used as a test fixture — tests use hand-built
  vectors.
- Renaming rewrites the transcript but does not re-run `on_stop`.
- Speaker boundaries from diarization can lag a word; attribution takes the
  span overlapping each word most and carries the previous speaker through
  uncovered words.

## 4. When to Revisit

- A wrong name shows up in practice → re-measure the threshold on more
  meetings before changing it.
- Meetings with more than 8 speakers per track.
- Live labeling during recording (Nemotron 3 streams; the pipeline doesn't).
- FluidAudio ships a stronger embedding model, or CAM++ leaves beta.
- Upstream quill adopts its own diarization.
