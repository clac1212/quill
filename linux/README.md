# quill for Linux

**Status:** Capture probe proposed; no installable build exists.

The Linux implementation will use the same session and transcript contracts as
the other Quill platforms. Its first technical boundary is PipeWire capture:

```text
selected playback node or stream via PipeWire -> them
microphone source via PipeWire                 -> me
```

The first deliverable should be a console capture probe that:

1. enumerates available PipeWire sources, sinks, monitors, and application
   streams;
2. records a selected playback source and microphone concurrently;
3. writes separate tracks and timing metadata;
4. detects silent or disconnected streams; and
5. documents behavior across representative GNOME and KDE distributions.

The probe must determine whether application-scoped capture is stable enough to
be the default. A full Linux application, compatibility fallback, desktop
integration, and packaging matrix should not be selected before that result.

See the repository [architecture](../docs/architecture.md) and
[multiplatform decision](../docs/decisions/001-multiplatform-repository.md).
