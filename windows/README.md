# quill for Windows

**Status:** Capture probe planned; no installable build exists yet.

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

See the repository [architecture](../docs/architecture.md) and
[multiplatform decision](../docs/decisions/001-multiplatform-repository.md).
