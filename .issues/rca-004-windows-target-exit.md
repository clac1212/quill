---
title: "Windows process-loopback silently outlives its target"
date: 2026-08-02
status: fixed
affects: "Windows process-loopback recording lifecycle"
---

## Context

Process-loopback activation is tied to one selected PID and its descendants.
The M1 verification contract requires a defined outcome when the target exits
or restarts: continue correctly, or stop with a diagnostic capture error.

## Problem statement

The loopback worker never observes the selected process after activation. If
the application exits or restarts under a new PID, system capture can stop
receiving meaningful audio while the microphone and probe continue recording.
`CaptureError::TargetExited` exists but is never produced.

## RCA

The capture pump waits only on the WASAPI event and a polling stop flag. It has
no handle to the selected process. A Windows process object becomes signaled
when the process terminates, and a handle opened with synchronization access can
participate in the same multi-object wait as the audio event.

Even if the worker returned an error, the foreground probe currently checks
only its Ctrl-C flag. It would not discover the completed worker until the user
eventually stopped the session.

## Proposed fix

1. Open the selected process with `PROCESS_SYNCHRONIZE` before loopback
   activation and retain the handle for the worker lifetime.
2. For process-tree capture, wait on both the WASAPI event and process handle.
   Return `CaptureError::TargetExited(pid)` when the process becomes signaled.
3. Expose worker completion through `TrackRecorder` and `RecordingSession`.
   The probe polling loop stops when either capture worker finishes, then joins
   both workers and prints the original diagnostic.
4. Preserve endpoint-loopback behavior, which has no target process.
5. Close the process handle through RAII and surface wait failures rather than
   spinning.

Automatic reacquisition is deliberately excluded from M1. A restarted process
has a new tree and potentially a different application identity; silently
switching would need an explicit source-reacquisition policy.

## Relevant files

**Fix targets:**

- `windows/src/audio/pump.rs` — process handle, multi-object wait, target-exit error.
- `windows/src/audio/loopback.rs` — opens and supplies the target monitor.
- `windows/src/audio/mic.rs` — reports whether its worker has ended.
- `windows/src/audio/mod.rs` — extends the recorder lifecycle contract.
- `windows/src/session.rs` — aggregates premature worker completion.
- `windows/src/bin/probe.rs` — stops polling when capture ends unexpectedly.
