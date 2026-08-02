# quill for Windows

**Status:** Capture probe implemented, awaiting validation on Windows 11
hardware; no installable build exists yet.

The Windows implementation will provide the same local recording and
transcription behavior as Quill for macOS using native Windows facilities. Its
audio boundary is two independent streams:

```text
selected process tree via WASAPI loopback -> them
microphone via WASAPI capture             -> me
```

The first deliverable is a console capture probe, not the tray application. It
must:

1. enumerate candidate processes;
2. capture one selected process tree;
3. capture the microphone concurrently;
4. write separate WAV tracks and timing metadata;
5. detect silent output; and
6. be exercised against Signal, WhatsApp, Zoom, and Teams on Windows 11.

Only after that probe passes will this directory gain the application solution,
tray interface, transcription runtime, installer, and release packaging.

## Building and running the probe

On Windows 11 (needs the MSVC toolchain, `rustup default stable-msvc`):

```powershell
cargo build --release
target\release\quill-probe.exe list
target\release\quill-probe.exe record teams        # or a pid; Ctrl-C stops
target\release\quill-probe.exe record --all-system-audio
```

Sessions land in `%USERPROFILE%\Recordings\yyyy.MM.dd-HHmm\` as `mic.wav`,
`system.wav`, and `meta.json`. Exit code 2 with a `Silent` diagnosis means a
track's peak never cleared the silence floor.

Development from any host: `cargo test` runs the portable WAV crash-tolerance
harness; `cargo clippy --target x86_64-pc-windows-msvc --all-targets --
-D warnings` is the cross-compile gate. The implementation plan is
[`.plan/windows.md`](../.plan/windows.md).

See the repository [architecture](../docs/architecture.md) and
[multiplatform decision](../docs/decisions/001-multiplatform-repository.md).
