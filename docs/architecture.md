# Quill architecture

Last updated: `2026.08.01`

Quill is one product with separate native implementations for each supported
desktop platform. Platform code does not share a runtime or source language.
Compatibility is maintained through shared behavioral contracts and fixtures.

## Repository boundaries

```text
Quill product
├── shared behavior and formats
├── macOS implementation
│   ├── Swift and AppKit lifecycle
│   ├── Core Audio capture
│   └── Core ML transcription through FluidAudio
├── Windows implementation
    ├── native Windows lifecycle
    ├── WASAPI microphone and process-loopback capture
    └── local ONNX transcription
└── Linux implementation
    ├── native Linux lifecycle
    ├── PipeWire microphone and playback capture
    └── local ONNX transcription
```

| Path | Responsibility |
|---|---|
| `macos/` | Complete native macOS implementation and Swift package |
| `windows/` | Native Windows implementation and platform documentation |
| `linux/` | Native Linux implementation boundary and platform documentation |
| `docs/` | Current architecture and historical decisions |
| `.plan/` | Product roadmap and active implementation plans |
| `fixtures/` | Future cross-platform session and transcript compatibility fixtures |
| `scripts/` | Stable repository-level developer entry points |

## Shared contract

The platforms share these concepts even when their audio containers differ:

- one timestamped directory per recording session;
- independent microphone (`me`) and playback (`them`) tracks;
- `meta.json` with session times, filenames, and track offsets;
- canonical, timed, speaker-tagged `transcript.json`;
- readable `transcript.md` generated from the canonical transcript;
- a recoverable filesystem-backed transcription queue; and
- local-only recording and inference.

Formal JSON schemas and compatibility fixtures will be extracted before the
Windows capture probe becomes a full application. Until then, the macOS output
implemented in `macos/Sources/quill/RecordingSession.swift` and
`macos/Sources/quill/Transcription/TranscriptionCoordinator.swift` is the
reference behavior.

## Build and release boundaries

Each platform owns its build graph, dependencies, tests, packaging, and release
artifact. Repository-level scripts provide stable entry points. A platform
failure must not prevent the other platform from building independently.

Release artifacts will be platform-qualified rather than presented as one
portable executable.

## Decision log

| Decision | Status | Summary |
|---|---|---|
| [ADR-001](decisions/001-multiplatform-repository.md) | Active | Keep native platform implementations in one repository under symmetric platform roots. |
