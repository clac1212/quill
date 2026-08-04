# Bug Report :: macOS audio-route change truncates an active mic recording

Last updated: `2026.08.04`

> A 36:40 macOS session appeared to keep recording, but the mic file stopped
> receiving audio at 28:08 after an AirPods device-route event. Quill emitted
> no warning and produced a transcript missing the final 8:32.

| Field | Value |
|---|---|
| **Project** | quill |
| **Severity** | degraded |
| **Status** | fixed — automated verification passed; hardware route matrix pending |
| **Affects** | macOS microphone capture, recording liveness, transcript completeness |

---

## 1. Symptom

Quill displayed an active recording for 36 minutes 40 seconds and stopped the
session cleanly. The resulting `mic.caf` is only 28 minutes 7.851 seconds long,
and the final transcript segment ends at 28 minutes 7.929 seconds. The last 8
minutes 32 seconds of the meeting are absent.

The system-audio file has the full 36-minute duration, but its tail is digital
silence and therefore does not provide a usable backup. No capture error or
degraded-state warning appears in Quill's stderr log.

The source recording and transcript are retained in a private workspace; no
call content or participant information is copied into this repository.

---

## 2. Steps to reproduce

The observed route-change sequence is known; a deterministic laboratory
reproduction is not yet established.

1. On macOS 26.5.1, run the installed `/usr/local/bin/quill` LaunchAgent with
   default configuration (`mic_voice_processing=false`).
2. Start a recording while the built-in `Digital Mic` and `Speaker` devices
   are active.
3. During the session, introduce Bluetooth audio-route churn by opening or
   reconnecting paired AirPods so macOS reevaluates the default audio devices.
4. Continue speaking for several minutes, then stop the recording normally.
5. Compare the session duration in `meta.json` with the decoded mic duration
   and the timestamp of the final transcript segment.

---

## 3. Expected vs actual

**Expected:** Quill records usable audio for the entire declared session. If a
device change interrupts capture, it restarts onto the new route or immediately
warns that the recording is degraded.

**Actual:** The menu-bar timer continues and `meta.json` records the full
session, while the mic tap silently stops delivering buffers. The incomplete
track is accepted and transcribed without warning.

---

## 4. Environment

- Branch / commit: `master` at `3d8f1e8`; installed binary dated 2026.07.25,
  corresponding to the current macOS capture behavior
- Runtime: macOS 26.5.1 (`25F80`), Apple Silicon
- Relevant config: no config file; raw mic capture is the default
- Capture path: `AVAudioEngine` input-node tap plus independent Core Audio
  global process tap

---

## 5. Evidence

- Session metadata: start `2026-08-03T19:32:55Z`, end
  `2026-08-03T20:09:35Z`, declared duration 2,200 seconds.
- `mic.caf`: AAC, mono, 48 kHz, decoded duration `1687.850667` seconds.
- `system.caf`: AAC, stereo, 48 kHz, decoded duration `2200.426667` seconds.
- Transcript: 405 mic-derived segments; final segment ends at `1687929` ms;
  no system-derived segments.
- The final 520 seconds of `system.caf` measure `-91.0 dB` mean and maximum,
  i.e. digital silence.
- Quill stderr records start and clean stop only. It contains no mic write
  error, engine-stop event, route-change notice, or incomplete-track warning.
- macOS unified logs show AirPods discovery and case-open events beginning at
  approximately `2026-08-03T20:00:59Z`, within seconds of the mic endpoint.
- Later in the same route transition, Core Audio reports a lost connected
  device, repeated `RemoveDeviceClient: bad device ID` errors, and
  `owning device is missing`.
- `MicRecorder` performs only a first-second signal check. It does not observe
  `AVAudioEngineConfigurationChange`, default-device changes,
  `engine.isRunning`, or the time of the most recent buffer.
- The menu state and elapsed timer depend on `RecordingSession` existence and
  wall-clock time, not track liveness.

---

## 6. Hypothesis

The best-supported hypothesis is that Bluetooth route churn invalidated or
reconfigured the default-input `AVAudioEngine` graph. The input tap then stopped
calling back, but Quill retained `isRecording=true` and had no continuous
liveness check or configuration-change recovery path.

The system track's lack of usable redundancy is a second concern. It may share
the route-change failure, but this recording was already mostly silent on that
track, so its exact failure mechanism is not established by this incident.

---

## 7. Scope

- Quill remained alive throughout the session.
- Clean stop, metadata writing, and transcription completed successfully.
- The CAF container preserved every mic buffer received before the cutoff.
- Earlier 38:10 and 27:44 sessions completed without the same truncation.
- This incident does not implicate the transcription engine; the source mic
  file itself ends at the transcript endpoint.

---

## 8. Resolution

Fixed in 0.1.3 per the plan in `.plan/macos-route-recovery.md` (mechanism in
[rca-006](rca-006-macos-route-change-truncates-mic.md)). Both recorders now
report callback telemetry and route-change events; `RecordingSession` runs a
one-second watchdog that restarts a stalled track on the current route into a
new numbered segment, preserving all audio already written. Metadata v2
records segments, interruptions, and a `complete`/`recovered`/`incomplete`
status; the menu bar, notifications, and transcript header surface recovery
and loss instead of displaying a healthy recording.

Verification evidence:

- `swift format lint --strict`, `swift build -c release`, and `swift test`
  pass — 32 deterministic tests covering the health state machine (stall
  detection, route-event debounce, retry schedule, degradation), recovery
  orchestration with fake recorders (single rotation, stop-during-retry
  creating no post-stop segment, startup rollback), metadata v1/v2
  compatibility, and offset-preserving transcript merges.
- The manual hardware route matrix (AirPods connect/disconnect, default-device
  switches, rapid churn, 45-minute control run) defined in the plan's
  Verification section has not yet been executed; the bug closes fully once it
  has.
