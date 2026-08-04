---
title: "macOS audio-route change silently truncates mic capture"
date: 2026-08-03
status: open
affects: "macOS microphone capture and recording completeness"
---

## Context

Quill's macOS recorder starts two independent capture paths. `MicRecorder`
installs a tap on the current `AVAudioEngine.inputNode`; `SystemAudioRecorder`
creates a Core Audio global process tap. `RecordingSession` holds both recorders
and writes a wall-clock duration when the user stops.

The mic recorder's only liveness mechanism examines signal during the first
second when voice processing is enabled. Raw capture, which is the default, has
no startup or continuous liveness check. Neither capture path currently reports
its last successful buffer time to the session controller.

## Problem statement

A 36:40 session stopped cleanly, but `mic.caf` ended at 28:07.851 and the
transcript ended at 28:07.929. Quill continued showing an active recording and
did not warn that the final 8:32 were missing. The full-length system track was
digitally silent over the missing interval.

## RCA

The mic graph is treated as stable for the lifetime of a session, but macOS
audio routes are not stable. `MicRecorder.attach` resolves the default input,
creates one `AVAudioEngine`, installs one input-node tap, and starts the engine.
After that point, Quill does not observe:

1. `AVAudioEngineConfigurationChange` notifications;
2. Core Audio default-input device changes;
3. whether `engine.isRunning` becomes false; or
4. whether the input tap has delivered a buffer recently.

The observed mic endpoint aligns within seconds of macOS discovering paired
AirPods and reevaluating the audio route. The same transition later produced
Core Audio device-loss and missing-device errors. When that route transition
invalidated or stopped the original input graph, the tap ceased callbacks.
Because write errors are logged only from inside the callback, no callback also
means no error. `isRecording` remained true, the wall-clock menu timer continued,
and clean stop wrote the full session duration despite the short file.

This is a recorder-lifecycle defect, not a CAF or transcription defect. The CAF
duration and final transcript timestamp agree: all received buffers were
preserved and transcribed, but no later mic buffers reached Quill.

The system track did not rescue this session. Its container continued to the
clean stop, but its final 520 seconds are exact digital silence. The incident
does not establish whether the process tap was invalidated by the same route
change because that track contained long silent intervals before the mic
cutoff. System-track route recovery should therefore be addressed alongside
the mic fix, but kept as a separately measurable behavior.

## Proposed fix

Introduce session-level capture health and segmented recovery rather than
assuming one audio graph can survive an entire meeting:

1. Track the wall-clock time and frame position of every successful mic and
   system buffer.
2. Observe `AVAudioEngineConfigurationChange` and Core Audio default-device
   changes while a session is active.
3. Run a lightweight watchdog. If mic callbacks stop for a short threshold
   while the session remains active, mark the track degraded and rebuild the
   engine against the current default input.
4. Restart into a new file such as `mic-002.caf`; do not delete or overwrite the
   valid first segment. Record each segment's start offset in `meta.json` so
   transcription can merge them onto the session clock.
5. Recreate the system process tap after relevant route changes. Treat absent
   callbacks as failure; treat zero signal as a warning rather than proof of
   failure because legitimate system silence is possible.
6. If recovery fails, change the menu-bar state and issue an immediate local
   notification that the recording is incomplete.
7. At stop, compare each track's final buffer time with the session end. Mark
   incomplete tracks in metadata and warn before transcription presents the
   result as complete.

Test with a manual route matrix: built-in devices to AirPods, AirPods to
built-in devices, AirPods disconnect, and default-input switch while speaking.
For automated coverage, isolate the watchdog and segment-transition state
machine behind a capture-health type and simulate configuration notifications,
callback stalls, successful recovery, and failed recovery.

## Relevant files

**Fix targets:**

- `macos/Sources/quill/Audio/MicRecorder.swift` — observe engine/device changes,
  expose buffer health, and support safe segmented restart.
- `macos/Sources/quill/Audio/SystemAudioRecorder.swift` — expose buffer health
  and recreate the process tap after relevant route changes.
- `macos/Sources/quill/RecordingSession.swift` — own the watchdog, recovery
  state, segment offsets, and completeness metadata.
- `macos/Sources/quill/UI/MenuBarController.swift` — display degraded capture.
- `macos/Sources/quill/Quill.swift` — surface recovery failure notifications.
- `macos/Sources/quill/Transcription/TranscriptionCoordinator.swift` — merge
  multiple per-track segments using metadata offsets.

**Flow** (read in order):

- `macos/Sources/quill/Quill.swift` — starts, times, and stops a session.
- `macos/Sources/quill/RecordingSession.swift` — starts both recorders and
  writes session metadata.
- `macos/Sources/quill/Audio/MicRecorder.swift` — owns the mic engine and tap.
- `macos/Sources/quill/Audio/SystemAudioRecorder.swift` — owns the system tap.
- `macos/Sources/quill/Transcription/TranscriptionCoordinator.swift` — reads
  recorded tracks and emits the transcript.

**Downstream:**

- `macos/Sources/quill/Transcription/ParakeetEngine.swift` — correctly
  transcribes the audio frames present in each source file.
