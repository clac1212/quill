---
title: "macOS capture-health monitoring and segmented route recovery"
date: 2026-08-03
status: implemented — hardware route matrix pending
affects: "macOS recording lifecycle, session metadata, transcription, and menu-bar state"
---

## Context

Quill currently treats the microphone `AVAudioEngine` graph and the Core Audio
system process tap as stable for the lifetime of a recording. The observed
2026.08.03 session disproved that assumption: Bluetooth route churn stopped
microphone callbacks at 28:08, while the application continued to display a
healthy 36:40 recording and generated metadata for the full wall-clock
duration. The system track did not provide usable redundancy because its tail
was digital silence.

The [bug report](../.issues/bug-001-macos-route-change-truncates-mic.md) records
the incident and the
[RCA](../.issues/rca-006-macos-route-change-truncates-mic.md) identifies the
failure mechanism. The production fix must detect callback loss, preserve all
valid audio already written, recover onto the current audio route, expose any
gap or unrecovered failure to the user, and keep recovered segments aligned on
one session clock during transcription.

This plan deliberately distinguishes three outcomes:

- **complete** — the track ran through stop without a detected interruption;
- **recovered** — capture resumed, but the metadata preserves the interruption
  and its bounded gap; and
- **incomplete** — capture could not be restored or was stale when the session
  stopped.

A recovered session is usable, but it is never represented as uninterrupted.

## Decisions

1. **RecordingSession owns recovery policy.** `MicRecorder` and
   `SystemAudioRecorder` own platform resources and emit health events;
   `RecordingSession` owns the track state machines, watchdog, retry policy,
   segment allocation, and final completeness decision. The UI renders session
   state and does not infer capture health itself.
2. **Use one monotonic session clock.** Capture offsets and gap calculations
   derive from a host-time baseline captured when the session starts. `Date`
   remains only for human-readable `started` and `ended` values. Wall-clock
   adjustments cannot move segments relative to one another.
3. **Recovery always creates a new segment.** The initial files remain
   `mic.caf` and `system.caf` for familiarity. Restarts create
   `mic-002.caf`, `system-002.caf`, and so on. Quill never reopens, truncates,
   deletes, or overwrites a segment that may contain valid audio.
4. **Callback progress proves transport health; amplitude does not.** Every
   successfully written buffer advances the track heartbeat. Missing callbacks
   can trigger recovery. Exact digital silence can produce a warning and
   metadata diagnostic, but cannot independently trigger a restart because
   silence may be legitimate.
5. **Route notifications accelerate detection but are not proof of failure.**
   `AVAudioEngineConfigurationChange` and Core Audio default input/output
   notifications mark the relevant track suspect and schedule a debounced
   health check. The watchdog also detects failures when the OS emits no useful
   notification.
6. **Recovery is serialized and generation-guarded.** Only one recovery may
   run per track. Stop invalidates pending work so a delayed retry cannot start
   a new recorder after the user ends the session.
7. **Metadata v2 is authoritative and backward-readable.** New sessions use a
   typed `tracks[].segments[]` representation rather than duplicating segment
   truth across `files` and `start_offset_ms`. The transcription reader accepts
   both v1 and v2 so existing recordings remain transcribable. The shared
   architecture contract and future Windows application target v2.
8. **Track and session health remain separate.** One track can recover while
   the other remains healthy. Session health is the worst active track state,
   and final session status is derived from both final track results.
9. **Warn immediately on unrecovered capture loss.** A failed recovery changes
   the menu-bar presentation and sends one local notification per degradation
   episode. Repeated watchdog ticks do not spam notifications.
10. **Keep audio lifecycle work off the main actor.** The session state machine
    and UI publication stay on `@MainActor`, while each recorder serializes
    graph/tap teardown and construction on its own control queue. Completion
    events return to the session actor. Recovery cannot freeze the menu bar or
    race two generations of the same recorder.

## Health model

### Live track states

```text
starting
   | first buffer written
   v
healthy -- route/config event --> suspect
   |                              |
   | callback stale               | callback remains current
   v                              v
recovering --------------------> healthy
   |
   | retry budget exhausted
   v
degraded

any active state -- user stops --> stopped
```

`recovered` is a historical/final result, not a live state. A successful
restart returns the live state to `healthy` while setting `didRecover=true` and
retaining the interruption record. A route event with continuing callbacks
returns from `suspect` to `healthy` without rotating the file.

### Timing and thresholds

- Watchdog cadence: once per second on the main actor.
- Initial callback grace: 5 seconds after starting a segment.
- Stale callback threshold: 3 seconds since the last successfully written
  buffer. This is much longer than the normal 4,096-frame callback interval
  (about 85 ms at 48 kHz) but short enough to limit meeting loss.
- Route-event debounce: 750 ms, coalescing the burst of notifications produced
  by one physical device transition.
- Recovery attempts: three per episode, after 0 ms, 500 ms, and 2 seconds.
- Retry reset: a newly started segment must write continuously for 5 seconds
  before the episode is considered recovered and a future incident receives a
  fresh retry budget.
- Final-tail tolerance: 3 seconds between the last written buffer end and
  session stop. A longer unresolved tail marks the track incomplete.
- Exact-silence diagnostic: record a warning after 15 seconds of callbacks
  whose peak is exactly zero; clear it after non-zero signal returns. It does
  not change transport state or initiate recovery.

Keep these values together in one `CapturePolicy` value so tests can substitute
short deterministic durations. Do not scatter literals across recorders and
UI code.

## Metadata contract

New recordings write a typed, atomically replaced `meta.json` after both
recorders stop. The intended v2 shape is:

```json
{
  "schema_version": 2,
  "started": "2026-08-03T19:32:55Z",
  "ended": "2026-08-03T20:09:35Z",
  "duration_seconds": 2200,
  "status": "recovered",
  "tracks": [
    {
      "kind": "mic",
      "speaker": "me",
      "status": "recovered",
      "segments": [
        {
          "file": "mic.caf",
          "start_offset_ms": 18,
          "end_offset_ms": 1687869,
          "frames_written": 81016832,
          "sample_rate_hz": 48000,
          "channels": 1
        },
        {
          "file": "mic-002.caf",
          "start_offset_ms": 1691120,
          "end_offset_ms": 2200014,
          "frames_written": 24426720,
          "sample_rate_hz": 48000,
          "channels": 1
        }
      ],
      "interruptions": [
        {
          "detected_offset_ms": 1690869,
          "recovered_offset_ms": 1691120,
          "reason": "callback_stalled",
          "attempts": 1
        }
      ],
      "warnings": []
    }
  ]
}
```

Exact field names are fixed by the implementation tests. `end_offset_ms`
means the expected end of the last successfully written buffer on the session
clock, not the time at which `stop()` happened. `status` is one of `complete`,
`recovered`, or `incomplete`. An interruption with no `recovered_offset_ms`
records the failed attempts and error summary. Error summaries must not contain
private call content or unbounded OS log text.

The session directory remains the durable queue boundary: `meta.json` is
written only after capture teardown finishes. It is written atomically so the
transcription resumer never consumes a partial v2 document.

## Changes

1. **Add typed session-clock and capture-health models.**
   - Create `macos/Sources/quill/Audio/CaptureHealth.swift`.
   - Define `TrackKind`, `CaptureState`, `CaptureEvent`, `CapturePolicy`,
     `SegmentStats`, `Interruption`, and the pure transition reducer used by
     both tracks.
   - Add a small lock-protected telemetry store for callback-owned fields:
     last successful buffer host time, last buffer end, frames written,
     rolling exact-zero duration, and latest write error.
   - Keep the audio callbacks non-blocking: update counters under the lock and
     dispatch state-changing events to the session owner; never perform route
     recovery inside a real-time callback.

2. **Introduce an observable recorder contract.**
   - Create `macos/Sources/quill/Audio/TrackRecorder.swift`.
   - Define the common operations needed by `RecordingSession`: start a named
     segment, stop and return `SegmentStats`, report a health snapshot, and
     register an event handler.
   - Use dependency injection for the two concrete recorders so the session
     state machine can be tested with deterministic fakes and no audio devices.
   - Recorder methods return errors to the session. Write errors become health
     events instead of stderr-only messages.
   - Give each concrete recorder a serial control queue for start, teardown,
     and restart. The real-time audio callback only writes its generation's
     immutable file and updates telemetry; it never waits on the main actor.

3. **Make microphone capture restartable and route-aware.**
   - Edit `macos/Sources/quill/Audio/MicRecorder.swift`.
   - Observe `AVAudioEngineConfigurationChange` for the active engine and the
     Core Audio system object's default-input-device property. Remove both
     observers during teardown and before replacing the engine.
   - Stamp each tap buffer from `AVAudioTime.hostTime` when valid, falling back
     to receipt host time; update telemetry only after `AVAudioFile.write`
     succeeds.
   - Replace the destructive voice-processing fallback with a normal segment
     rotation. A confirmed zero-only startup segment remains on disk and is
     marked with a warning; raw capture starts in the next numbered segment.
   - Make teardown idempotent and ordered: stop engine, remove tap, detach
     observers, close file, then release graph references.
   - Expose `engine.isRunning == false` as an immediate suspect event, while
     leaving the watchdog as the authoritative fallback.

4. **Make system capture restartable and measurable.**
   - Edit `macos/Sources/quill/Audio/SystemAudioRecorder.swift`.
   - Treat one segment as one complete process-tap/aggregate-device/IO-proc
     lifecycle; recovery destroys the old resources and constructs fresh ones
     for the next numbered file.
   - Observe default-output-device and device-list changes and emit debounced
     suspect events. Do not destroy the tap directly from the Core Audio
     property-listener callback.
   - Use the IO callback's host timestamp when valid, update telemetry only
     after a successful write, and surface write/device-stop failures.
   - Track exact-zero buffers separately from callback health. Continued zero
     buffers keep the transport heartbeat healthy but add a signal warning.
   - Make cleanup safe after partial construction so every failed recovery
     releases any tap, aggregate device, and IO proc created by that attempt.

5. **Move lifecycle policy into `RecordingSession`.**
   - Edit `macos/Sources/quill/RecordingSession.swift` and isolate its mutable
     lifecycle on `@MainActor`.
   - Capture the shared monotonic baseline and allocate segment names from one
     monotonically increasing counter per track.
   - Start both initial tracks with the existing all-or-nothing startup rule.
     Once the session is live, failure of one track no longer stops the healthy
     track; it enters recovery independently.
   - Start the watchdog after both initial recorders are ready. On each tick,
     reduce route events, engine state, callback age, and pending retry state
     into track transitions.
   - Serialize teardown/rebuild per track, apply the retry schedule, and ignore
     callbacks or retries whose session generation is stale.
   - Publish a `SessionCaptureStatus` whenever the externally visible state
     changes. Include affected track, live state, historical recovery, and
     signal warnings.
   - On stop, cancel watchdog and observers first, invalidate pending retries,
     stop both recorders even if one throws, derive final statuses using the
     final-tail tolerance, and atomically write typed v2 metadata.
   - Return a stop result containing the final status so the app can warn before
     enqueueing transcription.

6. **Render live recovery and incomplete-session state.**
   - Edit `macos/Sources/quill/UI/MenuBarController.swift`.
   - Extend the recording presentation from a Boolean to a typed display state:
     healthy (red), recovering/suspect (orange), and degraded (orange warning).
   - Keep elapsed time visible in every recording state and identify the track:
     for example, `◐ recovering microphone · 28:11` or
     `⚠ microphone capture lost · 28:14`.
   - Exact-zero system signal is a secondary warning, not the same visual state
     as stopped callbacks.
   - Edit `macos/Sources/quill/Quill.swift` so `AppController` subscribes to
     session status, emits one notification when an episode becomes degraded,
     updates the menu immediately on recovery, and warns at stop when final
     metadata is not `complete`.
   - Transcription still runs for recovered or incomplete sessions; the user
     receives the warning before a later “transcript ready” notification.

7. **Read and merge every segment during transcription.**
   - Edit
     `macos/Sources/quill/Transcription/TranscriptionCoordinator.swift`.
   - Replace the ad hoc dictionary reader with typed `Codable` v1/v2 parsing.
     Normalize both schemas into one ordered list of `(speaker, file,
     startOffsetMs)` inputs.
   - Transcribe each segment independently, shift it by its segment offset, and
     merge all results on the shared session clock. A failed segment is logged
     and skipped without discarding successful segments from the same track.
   - Preserve visible timing gaps. Do not concatenate audio or collapse the
     second segment back against the first segment's end.
   - Add the final session capture status to the readable transcript header so
     an incomplete recording is still visibly incomplete after the transient
     notification disappears. Keep the canonical transcript segment schema
     unchanged.

8. **Add deterministic automated coverage.**
   - Edit `macos/Package.swift` to add `QuillTests` and create
     `macos/Tests/QuillTests/`.
   - Unit-test the pure health reducer for startup grace, healthy progress,
     route-event debounce, callback stall, successful recovery, exhausted
     retries, repeated incidents, stop during retry, and final-tail status.
   - Unit-test segment naming and metadata encoding for uninterrupted,
     recovered, and incomplete sessions.
   - Unit-test backward parsing of current v1 metadata and v2 normalization
     across multiple mic and system segments.
   - Test transcript merging with interleaved segments and a deliberate gap;
     assert that timestamps retain their session offsets.
   - Use fake recorders and a manual test clock for session orchestration tests;
     no automated test may depend on a physical microphone, AirPods, TCC, or
     real-time sleeps.

9. **Update the shared contract and operator documentation.**
   - Edit `docs/architecture.md` with metadata v2, segment naming, final status,
     backward-read expectations, and monotonic alignment rules.
   - Edit `macos/README.md` to explain additional segment files, menu warnings,
     recovery semantics, and how to inspect `meta.json` after an incident.
   - Edit `.plan/windows.md` only where it currently declares v1 fields as the
     future shared contract; make the future Windows application target v2
     without expanding this macOS bugfix into Windows implementation work.
   - On implementation completion, update the bug and RCA status, bump the
     patch version, and add the fix to `CHANGELOG.md` under the release version.

## Files touched

```text
┌───────────────────────────────────────────────────────────────┬──────────────────────────────────────────────────────────┐
│ File                                                          │ Action                                                   │
├───────────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────┤
│ macos/Sources/quill/Audio/CaptureHealth.swift                 │ Create health types, policy, telemetry, and reducer      │
│ macos/Sources/quill/Audio/TrackRecorder.swift                 │ Create recorder protocol and shared segment result types │
│ macos/Sources/quill/Audio/MicRecorder.swift                   │ Edit for observation, telemetry, and segmented restart   │
│ macos/Sources/quill/Audio/SystemAudioRecorder.swift           │ Edit for observation, telemetry, and segmented restart   │
│ macos/Sources/quill/RecordingSession.swift                    │ Edit for watchdog, retries, segments, and metadata v2    │
│ macos/Sources/quill/UI/MenuBarController.swift                │ Edit for healthy/recovering/degraded presentation        │
│ macos/Sources/quill/Quill.swift                               │ Edit for status subscription and notifications           │
│ macos/Sources/quill/Transcription/TranscriptionCoordinator.swift│ Edit for v1/v2 parsing and multi-segment merge          │
│ macos/Tests/QuillTests/CaptureHealthTests.swift               │ Create deterministic state-machine tests                 │
│ macos/Tests/QuillTests/RecordingSessionTests.swift            │ Create recovery orchestration and stop-race tests        │
│ macos/Tests/QuillTests/SessionMetaTests.swift                 │ Create schema compatibility and segment tests            │
│ macos/Tests/QuillTests/TranscriptionCoordinatorTests.swift    │ Create offset-preserving merge tests                     │
│ macos/Package.swift                                           │ Edit to register the test target                         │
│ docs/architecture.md                                          │ Edit the shared session contract                         │
│ macos/README.md                                               │ Edit user and troubleshooting documentation              │
│ .plan/windows.md                                              │ Edit future metadata target only                         │
│ .issues/bug-001-macos-route-change-truncates-mic.md           │ Edit status and verification evidence on completion      │
│ .issues/rca-006-macos-route-change-truncates-mic.md           │ Edit status and link the completed fix                   │
│ CHANGELOG.md                                                  │ Edit release entry                                       │
└───────────────────────────────────────────────────────────────┴──────────────────────────────────────────────────────────┘
```

File boundaries may be split further if a Swift type approaches the 80-line
function limit, but the ownership above should remain stable. Do not add a
general-purpose shared runtime or change the Windows implementation as part of
this fix.

## Implementation order

1. Add the pure health model, metadata v2 types, fakes, and failing unit tests.
2. Make each recorder implement the observable segment contract independently.
3. Integrate the watchdog and serialized recovery in `RecordingSession`.
4. Add v2 transcription normalization and multi-segment merge.
5. Wire status through `AppController` to menu and notifications.
6. Update documentation, version, changelog, issue, and RCA.
7. Run automated checks, then execute the hardware route matrix.

The first five steps should be committed as one bugfix unless review reveals a
clean independently releasable boundary. Avoid landing metadata v2 without the
matching transcription reader.

## Verification

### Automated

Run from `macos/`:

```sh
swift format lint --recursive --strict Sources Tests
swift build -c release
swift test
```

Required assertions include:

1. A buffer arriving before the stale threshold keeps the track healthy.
2. A route notification alone does not rotate a healthy track.
3. A stalled callback rotates exactly once and preserves the old segment.
4. A successful replacement segment becomes healthy only after its stability
   window and leaves final status `recovered`.
5. Three failed attempts produce one degraded transition and one notification
   request, not one per watchdog tick.
6. Stop during debounce or retry creates no post-stop segment.
7. Final metadata reports the actual last written buffer end, interruption
   gap, attempt count, and incomplete tail.
8. A v1 session produces the same normalized transcription inputs as before.
9. V2 segment transcripts retain their offsets and visible gaps after merge.
10. One unreadable segment does not suppress other valid segments.

If `swift format` is not installed in the development environment, use the
repository's configured Swift formatter or add an explicit formatting command
before implementation; do not silently skip linting.

### Manual route matrix

For every row, speak continuously into the mic and play a repeating spoken
sample through the meeting application. Record the menu transition, local
notification, generated segment files, metadata status/gap, decoded duration,
and final transcript timestamps.

| Start route | Mid-session action | Expected result |
|---|---|---|
| Built-in mic + speaker | Open/connect AirPods | No silent truncation; either uninterrupted or recovered segments with a recorded gap |
| AirPods mic + output | Disconnect/close AirPods | Mic and system recover to current defaults or show degraded immediately |
| Built-in mic | Change default input in System Settings | New mic segment begins; old segment remains intact |
| Built-in output | Change default output in System Settings | System callbacks continue or a new system segment begins |
| Any route | Rapid connect/disconnect burst | Events coalesce; no overlapping recoveries or duplicate segment numbers |
| Any route | Recovery target unavailable | Three bounded retries, persistent degraded UI, one notification, incomplete metadata |
| Any route | Stop during recovery delay | Clean stop; no recorder restarts afterward; metadata remains parseable |
| Stable route | 45-minute control recording | One segment per track, complete status, no false recovery |
| Stable route | 30+ seconds of intentional playback silence | Signal warning may appear; no system-tap restart |

For each produced CAF, use `ffprobe` to confirm it decodes and compare decoded
duration with that segment's `frames_written`, sample rate, and metadata
offsets. Confirm that no segment file is modified after the next segment
starts. Inspect the final transcript around every recovery boundary to ensure
the timestamp gap is retained.

### Regression checks

- Start failure still tears down the other initial track and shows a recording
  failure rather than entering a half-started session.
- Voice-processing fallback still produces usable raw mic audio without
  deleting the first segment.
- A normal stop writes metadata before transcription is queued.
- Pending v1 and v2 sessions both resume transcription after relaunch.
- A new recording can begin while the previous session transcribes.
- `quill doctor`, LaunchAgent operation, permissions, and `on_stop` behavior
  remain unchanged.
- Run `kdb check projects/.misc/quill`; no new broken links are introduced.

## Acceptance criteria

The fix is complete when:

1. Quill detects a stopped mic or system callback stream within 4 seconds under
   normal scheduler conditions.
2. A recoverable route change resumes capture in a new segment without
   modifying any prior segment.
3. Transcript timestamps preserve real session time across segment gaps.
4. An unrecoverable interruption is visible during recording, notified once,
   and persisted as `incomplete` in metadata and the readable transcript.
5. A recovered interruption is persisted as `recovered`, including its gap and
   retry evidence; it is never labeled `complete`.
6. Existing v1 sessions remain transcribable with unchanged timestamps.
7. The automated suite passes, all manual route-matrix cases meet their
   expected behavior, and the 45-minute control run produces no false recovery.

## Risks and containment

- **Recovery causes additional route churn.** Debounce notifications, serialize
  recovery, and require callback staleness before rotating a still-running
  recorder.
- **Real-time callback contention drops audio.** Keep telemetry updates fixed
  size and lock duration minimal; perform allocation, logging, metadata work,
  and state transitions off the callback path.
- **Old callbacks write into a new segment.** Bind each callback to an immutable
  segment generation and ignore it after teardown; never let callbacks resolve
  `self.file` to a later segment.
- **Stop races a delayed retry.** Invalidate the session generation before
  teardown and check it before and after every asynchronous retry.
- **Exact silence creates false alarms.** Treat amplitude only as a diagnostic,
  clearly separate it from transport degradation, and never restart on signal
  level alone.
- **Schema migration strands existing sessions.** Land the backward-compatible
  reader and v2 writer together and test fixtures for both before release.
- **Recovery closes a file while its callback writes.** Recorder teardown must
  synchronize with its capture queue before releasing `AVAudioFile`; tests and
  Thread Sanitizer runs should specifically exercise repeated start/stop.

## Out of scope

- Recovering the already-missing 8:32 from the observed call.
- Mixing split tracks into the planned user-facing `recording.m4a`.
- Per-application system-audio selection.
- Windows or Linux capture recovery implementation.
- Treating silence as proof that a participant or application should have been
  producing audio.
- Uploads, cloud monitoring, or remote telemetry.
