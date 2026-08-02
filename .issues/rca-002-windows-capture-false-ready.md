---
title: "Windows capture reports ready before recording starts"
date: 2026-08-02
status: fixed
affects: "Windows microphone and system-audio capture startup"
---

## Context

The Windows capture probe runs microphone and system-audio capture on dedicated
worker threads. `TrackRecorder::start` must return only after the worker has
created its output file and successfully started the WASAPI client. Setup
failures must be returned synchronously so `RecordingSession` never presents a
half-started session as recording.

## Problem statement

Both recorder implementations currently report readiness after COM and WASAPI
activation, but before `pump::run` creates the WAV file or calls
`IAudioClient::Start`. The probe can therefore print that it is recording even
when file creation or client startup has already failed. The real error remains
hidden in the worker until the user stops the apparent recording.

## RCA

The readiness sender is owned by the worker closure in `MicRecorder::start` and
`LoopbackRecorder::start`. Each closure sends `Ok(())` immediately after
`activate`, then enters `pump::run`. The remaining fallible startup operations
are the first two statements inside `pump::run`:

1. `WavWriter::create` creates and initializes the output file.
2. `IAudioClient::Start` starts the initialized WASAPI stream.

Because the signal precedes both operations, the signal describes activation,
not recording readiness. This contradicts the `TrackRecorder::start` contract.

## Proposed fix

Pass the readiness sender into `pump::run` and send the signal only after both
file creation and `IAudioClient::Start` succeed. Use a unit channel rather than
`Result<(), ()>`: a setup failure returns from the worker and drops the sender,
causing `recv` to fail. The recorder then joins the worker and returns its
original `CaptureError`, preserving diagnostic context without cloning errors.

Apply the same handshake to microphone and loopback capture. Validate with the
portable test suite, Windows x64 cross-compilation, Windows-target Clippy, and
format checking. Actual `IAudioClient::Start` failure injection remains part of
the Windows VM test harness because the COM interfaces cannot run on macOS.

## Relevant files

**Fix targets:**

- `windows/src/audio/pump.rs` — owns file creation and `IAudioClient::Start`; must signal readiness.
- `windows/src/audio/mic.rs` — must wait for the pump readiness signal.
- `windows/src/audio/loopback.rs` — must wait for the pump readiness signal.

**Flow:**

- `windows/src/audio/mod.rs` — defines the `TrackRecorder::start` contract.
- `windows/src/session.rs` — starts system capture before microphone capture.
- `windows/src/bin/probe.rs` — reports recording only after session startup succeeds.
