---
title: "Quill for Windows — implementation plan"
date: 2026-08-01
status: approved
affects: "windows/"
---

## Context

Quill for macOS is a working single-binary meeting recorder: mic and system
audio as two independent tracks, on-device Parakeet transcription, menu-bar UI.
The repository is now organized into native platform roots (ADR-001), and
`windows/README.md` fixes the first Windows deliverable: a console capture
probe — not the tray app — validated against Signal, WhatsApp, Zoom, and Teams
on Windows 11. This plan covers the full Windows implementation, structured so
the probe's capture code is the application's capture module, not a throwaway.

Every macOS layer has a Windows equivalent, and two are strictly simpler:
system-audio capture (WASAPI process loopback, no permission dialog, no TCC)
and startup registration (a registry Run key instead of the LaunchAgent +
embedded-Info.plist TCC workaround). The transcription model is the same —
Parakeet TDT 0.6B v2 runs on Windows through sherpa-onnx (ONNX Runtime).

Reference behavior is the macOS implementation: session layout from
`macos/Sources/quill/RecordingSession.swift`, queue semantics from
`macos/Sources/quill/Transcription/TranscriptionCoordinator.swift`, engine
contract from `macos/Sources/quill/Transcription/TranscriptionEngine.swift`.
The shared contract (`docs/architecture.md`) allows the audio container to
differ; everything else — session directory naming, `meta.json` keys,
`transcript.json`/`transcript.md`, filesystem-as-queue — is identical.

Roadmap note: `.plan/roadmap.md` gates Windows behind qualified demand plus "a
short architecture spike." The M1 probe below *is* that spike. M2–M4 do not
start until the roadmap's promotion rule is satisfied.

## Decisions

1. **Language: Rust.** One small static binary, matching quill's no-app-bundle
   ethos, and `windows-rs` gives first-class WASAPI/COM access. C# can also
   ship self-contained (Native AOT), so runtime availability is not the
   deciding fact; the deciding facts are windows-rs API parity for the
   process-loopback activation path and single-file binary ergonomics.
2. **One crate: a library plus two binaries, feature-gated transcription.**
   Cargo binaries do not share modules declared in `src/main.rs`, so the
   shared code lives in `src/lib.rs` (library target); `src/main.rs` (app)
   and `src/bin/probe.rs` (M1) both import capture/session/transcribe from
   the library. `transcribe` is a cargo feature so the probe builds without
   the sherpa-onnx C++ toolchain. A workspace is overhead we don't need.
3. **Container: WAV (16-bit PCM), crash-tolerant by construction.** Write
   order per interval: append PCM, flush data to the OS, then patch the
   header sizes — so the declared length never runs ahead of durable data.
   Accepted loss window: at most the flush interval (10 s) of *declared*
   audio; samples past the declared length survive on disk and are
   recoverable by tools that read to EOF (ffmpeg does). This is a bounded
   claim, not "loses nothing." AAC via Media Foundation reintroduces a
   finalization pass; rejected for the working tracks (the roadmap's merged
   `recording.m4a` export can encode AAC later, once the session is safe on
   disk).
4. **System audio: per-process-tree loopback, not endpoint loopback.**
   `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` +
   `PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE` captures the selected
   app and its children (Teams/Zoom spawn renderer children) regardless of
   which output device it plays to, and Spotify never leaks into the track —
   fixing the macOS gotcha. Fallback: plain endpoint loopback behind a
   `--all-system-audio` flag, which restores exact macOS semantics.
5. **Capture format: request 48 kHz stereo f32, write 16-bit mono.** Process
   loopback requires the client to specify a format; mic uses the endpoint mix
   format. Both downmix to mono on write (macOS does the same for the mic).
   Engines resample to 16 kHz at transcription time, not at capture.
6. **Transcription: the official `sherpa-onnx` crate (k2-fsa, v1.13+),
   Parakeet TDT 0.6B v2 int8.** The community `sherpa-rs` bindings were
   archived in 2026.03 and point users at the official crate, which supports
   Windows static linking and ships a Parakeet example. Same model as macOS,
   so transcript quality is comparable. Two known risks are gated in M2
   before any app work: the reported empty-output issue
   (k2-fsa/sherpa-onnx#2258) and CPU int8 throughput on a real target
   machine. whisper.cpp is the fallback engine if either fails.
7. **Tray: `tray-icon` + `muda` crates.** Raw `Shell_NotifyIcon` + menu message
   pumps via windows-rs is ~500 lines of Win32 boilerplate; the tauri-maintained
   crates are thin wrappers over exactly that. Not worth hand-rolling.
8. **Config/paths.** Config at `%APPDATA%\quill\config.json`, same schema as
   macOS (`recordings_dir`, `transcription.{enabled,engine}`, `on_stop`);
   recordings default `%USERPROFILE%\Recordings`. `mic_voice_processing` has no
   Windows equivalent (no VoiceProcessingIO); nearest analog is enabling the
   mic's audio-effects AEC when present — deferred, headphones remain the
   default assumption. `on_stop` semantics are defined explicitly for
   Windows: the value is executed as `cmd /C <command> "<session dir>"` —
   the session directory is appended as one quoted final argument, and the
   command string itself is passed through untouched. Shell quoting inside
   the command is the user's cmd-syntax problem, documented in the README.
9. **Startup: `HKCU\...\CurrentVersion\Run` value; Start-menu shortcut for
   toasts.** `quill install --launch-at-login` writes the Run value,
   `--uninstall` removes it. Desktop toast notifications from an unpackaged
   Win32 exe require a Start-menu shortcut carrying a matching
   AppUserModelID, so `install` also writes that shortcut (M3, not deferred
   to packaging); when the shortcut is absent, notify falls back to a
   `Shell_NotifyIcon` balloon so notification never silently no-ops. No TCC
   equivalent exists, so the whole embedded-plist hack disappears.
10. **Clocks.** QPC (`QueryPerformanceCounter`) is the only clock used for
    track alignment: both recorders stamp their first delivered buffer
    against one shared QPC baseline taken at session start, and
    `start_offset_ms` is derived purely from QPC deltas. Wall clock
    (`SystemTime`) appears only in the human-readable `started`/`ended`
    fields — a mid-recording wall-clock adjustment must not corrupt
    alignment.

## Folder organization

```text
windows/
├── README.md
├── Cargo.toml               # features: default = [], transcribe = ["sherpa-onnx"]
├── rust-toolchain.toml
└── src/
    ├── lib.rs               # shared library target: declares all modules below
    ├── main.rs              # tray app binary: parse CLI, run state machine (M3)
    ├── bin/
    │   └── probe.rs         # M1 console capture probe binary
    ├── config.rs            # Config load/merge, path resolution
    ├── session.rs           # RecordingSession, SessionMeta (meta.json)
    ├── audio/
    │   ├── mod.rs           # re-exports; TrackRecorder trait; CaptureError
    │   ├── com.rs           # COM init guard, HRESULT → CaptureError helpers
    │   ├── device.rs        # endpoint enumeration, mix-format query
    │   ├── process.rs       # audio-session enumeration → CaptureTarget list
    │   ├── mic.rs           # WASAPI shared-mode capture client
    │   ├── loopback.rs      # process-tree loopback capture client
    │   └── wav.rs           # crash-safe WAV writer (periodic header patch)
    ├── transcribe/          # entire module cfg-gated behind `transcribe`
    │   ├── mod.rs           # TranscriptionEngine trait, TranscriptSegment
    │   ├── parakeet.rs      # sherpa-rs offline recognizer, model download
    │   ├── coordinator.rs   # filesystem queue scan + serial worker thread
    │   └── transcript.rs    # offset shift, timestamp merge, json/md render
    ├── ui/
    │   └── tray.rs          # tray icon, menu, elapsed-time title (M3)
    ├── notify.rs            # toast notification on transcript ready
    ├── install.rs           # Run-key install/uninstall
    └── doctor.rs            # mic consent, recordings dir, model cache checks
```

## Types

Core domain types, following CC-R7 (newtypes), CC-R8 (states as enums),
CC-R11 (error enums carry context). Illustrative — fields may grow, shapes
should not.

```rust
// audio/mod.rs
pub struct Pid(NonZeroU32);

/// A process tree offered for capture: one row in the probe's picker and the
/// tray's (eventual) source menu.
pub struct CaptureTarget {
    pub pid: Pid,
    pub name: String,        // e.g. "ms-teams.exe"
    pub session_active: bool // has an active audio render session right now
}

/// One capture track. Both recorders implement this; RecordingSession only
/// speaks the trait.
/// Instant on the QueryPerformanceCounter timeline. Alignment math never
/// touches wall clock (decision 10).
pub struct QpcInstant(i64);

pub trait TrackRecorder: Send {
    fn start(&mut self, out: &Path) -> Result<(), CaptureError>;
    /// Final flush + header patch happen here; their failures must surface,
    /// not vanish.
    fn stop(&mut self) -> Result<TrackStats, CaptureError>;
    /// QPC stamp of the first delivered buffer; None if no audio ever
    /// arrived. start_offset_ms = delta from the session's QPC baseline.
    fn first_buffer_at(&self) -> Option<QpcInstant>;
}

pub struct TrackStats {
    pub frames_written: u64,
    pub peak_amplitude: f32, // silence detection: peak below floor => Silent
}

pub enum CaptureError {
    DeviceNotFound,
    Activation { hr: windows::core::HRESULT, stage: &'static str },
    FormatRejected { requested: WaveFormat },
    TargetExited(Pid),
    Io(std::io::Error),
}
```

```rust
// session.rs — mirrors macos RecordingSession.swift
pub struct RecordingSession {
    dir: PathBuf,            // <root>/yyyy.MM.dd-HHmm, suffixed on collision
    started_at: SystemTime,  // human-readable meta.json fields only
    qpc_baseline: QpcInstant, // shared zero for both tracks' offsets
    mic: MicRecorder,
    system: LoopbackRecorder,
}
// start(): system first, then mic; mic failure tears the loopback down so a
// half-silent session never runs. stop(): stop both, write meta.json.

#[derive(Serialize)]
pub struct SessionMeta {
    started: String,             // ISO 8601
    ended: String,
    duration_seconds: u64,
    files: TrackFiles,           // { mic: "mic.wav", system: "system.wav" }
    start_offset_ms: TrackOffsets, // lag of each track behind the earliest
}
```

```rust
// main.rs — app state machine (CC-R8); the tray renders this, never owns it
pub enum AppState {
    Idle,
    Recording(RecordingSession),
}
// Transcription runs on the coordinator's worker thread and is deliberately
// NOT an AppState: recording may start while the last session transcribes,
// same as macOS.
```

```rust
// transcribe/mod.rs — port of TranscriptionEngine.swift
pub struct TranscriptSegment {
    pub start: f64, // seconds, relative to the track's own start
    pub end: f64,
    pub text: String,
}

pub trait TranscriptionEngine: Send {
    fn name(&self) -> &str;   // transcript.json provenance
    fn model(&self) -> &str;
    fn prepare(&mut self) -> Result<(), TranscribeError>;  // download + load
    fn transcribe(&self, wav: &Path) -> Result<Vec<TranscriptSegment>, TranscribeError>;
    fn release(&mut self);    // drop model weights when the queue drains
}

// transcribe/coordinator.rs — the filesystem is the queue: a session dir with
// meta.json and no transcript.json is pending. Scan on launch (resume), push
// on session stop, one serial worker; failures append to the session's
// transcribe.log and never block later jobs.
pub struct TranscriptionCoordinator { /* worker: JoinHandle, tx: Sender<PathBuf> */ }
```

## Changes

Ordered as milestones; each is independently verifiable and M2–M4 do not start
before the roadmap promotion rule clears.

### M1 — capture probe (`quill-probe.exe`)

1. `windows/Cargo.toml`, `rust-toolchain.toml` — crate skeleton; deps:
   `windows` (Win32 audio + registry features), `serde`/`serde_json`,
   `clap`. No transcription deps.
2. `src/audio/com.rs`, `device.rs` — COM lifetime guard; default-endpoint
   lookup and mix-format query.
3. `src/audio/process.rs` — enumerate processes with *active render
   sessions* via `IAudioSessionManager2`/`IAudioSessionEnumerator` across
   render endpoints (not a raw process list); dedupe to top-level parents so
   Teams' renderer children collapse into one row.
4. `src/audio/wav.rs` — writer with the append → flush → header-patch cycle
   every 10 s and on drop (decision 3). Unit-tested against a truncation
   harness (kill mid-write at each point in the cycle, reopen, assert
   readable and assert declared length ≤ durable data).
5. `src/audio/loopback.rs` — `ActivateAudioInterfaceAsync` with
   `AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS`, include-tree mode, event-driven
   capture loop on a dedicated thread. `--all-system-audio` fallback path
   uses plain endpoint loopback.
6. `src/audio/mic.rs` — shared-mode capture client on the default input,
   event-driven, mono downmix.
7. `src/session.rs` — session dir creation, ordered start/stop, meta.json.
8. `src/bin/probe.rs` — CLI: list targets, pick by name/pid, record until
   Ctrl-C, print per-track stats, exit nonzero with a `Silent` diagnosis if
   either track's peak stays under the floor.

### M2 — transcription (feature `transcribe`)

9. **Gate first:** standalone smoke test of the official `sherpa-onnx` crate
   (static-linked) + Parakeet TDT int8 on Windows against the macOS test
   fixtures — correctness (issue #2258 class failures) and throughput
   (target: ≤ 5 min per meeting-hour on the target machine). A failed gate
   switches `parakeet.rs` to a whisper.cpp engine behind the same trait; the
   trait is the insurance.
10. `src/transcribe/mod.rs`, `parakeet.rs` — trait port; model download to
    `%LOCALAPPDATA%\quill\models\` with the doctor reporting cache state.
11. `src/transcribe/transcript.rs` — port the macOS merge: per-track
    transcribe, shift by `start_offset_ms`, merge by timestamp, tag `me`/
    `them`, render transcript.json (with engine provenance) + transcript.md.
    Merge/render logic is verified against deterministic synthetic segment
    fixtures (schema, speaker labels, ordering, offset arithmetic); engine
    output is judged semantically against the macOS reference transcript,
    never byte-for-byte — different runtimes and quantization make byte
    equality unattainable.
12. `src/transcribe/coordinator.rs` — queue scan, serial worker, resume on
    launch, per-session transcribe.log.

### M3 — tray application (`quill.exe`)

13. `src/main.rs` — CLI (`run`, `doctor`, `install`), AppState machine.
14. `src/ui/tray.rs` — feather icon, red + elapsed counter while recording,
    Start/Stop, source picker submenu (target process or all system audio),
    Quit.
15. `src/config.rs`, `notify.rs`, `install.rs`, `doctor.rs` — config load;
    toast on transcript ready (Start-menu shortcut + AppUserModelID written
    by `install`, balloon fallback per decision 9); Run-key install; doctor
    checks. Doctor probes mic access by attempting a real capture-client
    initialization and mapping the failure to an actionable message — the
    internal consent-store registry is not a stable public contract and is
    not read.
16. `on_stop` hook — spawn per decision 8 (`cmd /C`, session dir as quoted
    final argument) after transcript write; behavioral parity with macOS,
    not literal shell-string parity.

### M4 — packaging

17. `scripts/build-windows` (repo root, mirrors `build-macos`) — release
    build, embed icon + version resource via `winresource`. Single exe;
    installer (MSIX/Inno) deferred until distribution demand exists.

## Files touched

```text
┌──────────────────────────────────────┬──────────────────────────────┐
│ File                                 │ Action                       │
├──────────────────────────────────────┼──────────────────────────────┤
│ windows/Cargo.toml                   │ Create                       │
│ windows/rust-toolchain.toml          │ Create                       │
│ windows/src/** (per tree above)      │ Create                       │
│ windows/README.md                    │ Edit (status + usage per     │
│                                      │ milestone)                   │
│ scripts/build-windows                │ Create (M4)                  │
│ docs/architecture.md                 │ Edit (fixtures extracted     │
│                                      │ before M2 §11)               │
│ fixtures/                            │ Create (macOS-produced       │
│                                      │ session + transcript pair)   │
└──────────────────────────────────────┴──────────────────────────────┘
```

## Verification

- **M1 exit test (from windows/README.md):** record a real call in each of
  Signal, WhatsApp, Zoom, Teams on Windows 11; both WAVs audible, correct
  sides, meta.json offsets sane; silence detector fires when pointed at a
  process rendering nothing. Kill the probe mid-recording; both WAVs must
  reopen playable with declared length ≤ durable data.
- **M1 device-route matrix:** wired headphones, Bluetooth headset, USB
  microphone, default-device change mid-recording, device unplug
  mid-recording, and target-process restart mid-recording — each with a
  defined outcome (keep recording, or stop with a diagnosable
  `CaptureError`), no silent tracks. Sleep/resume is exercised and its
  behavior recorded; surviving it is not an M1 pass requirement.
- **M2 exit test:** transcript.json/md produced from the fixture session
  matches the macOS reference within timestamp tolerance; throughput within
  target; queue resumes an interrupted job on relaunch.
- **M3 exit test:** full loop from tray — record a Zoom call, stop, toast
  fires, transcript readable, `on_stop` hook runs; `doctor` output correct on
  a machine with mic access denied.
- Continuous: `cargo clippy -- -D warnings` and `cargo test` clean (CC-2.3);
  wav truncation harness in CI.
