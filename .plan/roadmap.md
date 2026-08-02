# Quill :: Product Roadmap

Last updated: `2026.07.30`

**Status:** Provisional

> Quill should first become a reliable, low-friction macOS product. Additional
> languages are the most reusable expansion. Multi-speaker diarization is a
> promising product hypothesis for interviews, podcasts, and group meetings.
> Windows, Linux, and mobile remain demand hypotheses until qualified requests
> justify their engineering and maintenance cost.

## Table of Contents

1. [Current objective](#1-current-objective)
2. [Observed requests](#2-observed-requests)
3. [Roadmap](#3-roadmap)
4. [Platform distinctions](#4-platform-distinctions)
5. [Promotion rule](#5-promotion-rule)
6. [Request ledger](#6-request-ledger)

---

## 1. Current objective

Convert Quill from a developer-installed utility into a reliable application
that a normal Mac user can discover, install, authorize, and operate without
Terminal.

The current release must establish:

- a polished product page;
- a downloadable `.app` or DMG;
- signing and notarization, if credentials permit;
- legible first-run permissions;
- reliable recording and transcription;
- one conventional audio file for ordinary playback and sharing;
- safe recovery from interrupted recordings and transcription failures; and
- a repeatable release process.

No platform expansion should outrank defects that prevent the macOS product
from completing its core job.

---

## 2. Observed requests

Current public responses cluster around four requests:

| Request | Evidence state | Commitment state |
|---|---|---|
| Mobile | Repeated public requests; exact user job is unclear | Discovery only |
| Windows | Repeated public requests | Validate demand and architecture |
| Linux | Repeated public requests | Validate demand and architecture |
| Additional languages | Repeated public requests; current Parakeet engine is English-only | Leading expansion candidate |

The current observations establish interest, not priority. Exact counts,
distinct requesters, user types, and willingness to test or pay have not yet
been recorded.

---

## 3. Roadmap

### 3.1 — Now: macOS reliability and distribution

1. Package and test the application outside the development directory.
2. Resolve signing, notarization, Gatekeeper, and first-run permission flows.
3. Fix defects that interrupt recording, transcription, or transcript output.
4. Produce one merged `recording.m4a` for ordinary playback and sharing.
5. Polish the page and installation instructions.
6. Establish a repeatable build and release pipeline.

#### 3.1.1 — Unified audio output

The user-facing session should contain one conventional audio file rather than
requiring the user to understand `mic.caf` and `system.caf`.

```text
mic.caf + system.caf + timing offsets
    -> aligned mix
    -> recording.m4a
```

Preserve the split CAF files as crash-safe working tracks until transcription
and merged export succeed. They retain free `me` versus `them` diarization and
allow recovery when recording stops unexpectedly. After successful export,
either move them into an internal session directory or delete them under an
explicit cleanup policy.

Use AAC in an M4A container as the default because it is native to the macOS
media stack and broadly playable. Add MP3 only if compatibility evidence shows
that M4A is insufficient. The product requirement is a single legible playback
file, not a particular codec.

### 3.2 — Next candidate: multilingual transcription

Add a Whisper-backed path capable of supporting additional languages. Resolve:

- automatic detection versus explicit language selection;
- model size and download behavior;
- performance and accuracy by language;
- fallback behavior when the default engine is inappropriate; and
- whether translated output is distinct from transcription.

This is the leading expansion candidate because the capability can improve
Quill across every future platform.

### 3.3 — Evaluate: multi-speaker diarization

Quill currently provides **source-level separation**: the microphone can be
labeled `me`, while system audio can be labeled `them`. That is useful but is
not true speaker diarization. Multi-speaker diarization would identify and
consistently label distinct people within a shared recording source:

```text
system audio or room microphone
    -> speech segments
    -> speaker clusters
    -> Speaker 1 / Speaker 2 / Speaker 3
    -> optional user-assigned names
```

The likely jobs are interviews, podcasts, group meetings, and any conversation
where a single `them` label hides materially different participants.

Before committing, resolve:

- whether users need automatic speaker counts or can provide the expected
  number of speakers;
- whether diarization can remain local and complete within acceptable time;
- accuracy under overlapping speech, poor microphones, and remote-call audio;
- how users correct mistaken speaker assignments;
- whether speaker identities should persist within one session or across
  sessions; and
- whether the improvement justifies the model size, processing time, and
  interface complexity.

Preserve source tracks and timing metadata in the current release architecture
so this remains possible later. Do not make diarization a dependency of the
initial DMG.

### 3.4 — Validate: Windows

Windows may have the largest platform-expansion opportunity, but it requires a
separate implementation for system-audio capture, application packaging,
permissions, startup behavior, and local inference.

Do not commit until qualified demand and a short architecture spike justify
the maintenance burden.

### 3.5 — Validate: Linux

Linux demand may be meaningful among technical users, but desktop audio,
packaging, and distribution are fragmented across PipeWire, PulseAudio,
distributions, and desktop environments.

Do not treat a Linux port as a cheap derivative of the macOS application.

### 3.6 — Discover: mobile

“Mobile” does not yet name one product. Possible jobs include:

- recording calls or meetings;
- using the phone as a microphone;
- importing mobile recordings for transcription;
- viewing, editing, or sharing transcripts; and
- synchronizing recordings with the desktop application.

iOS and Android restrictions may prevent arbitrary system-audio capture. Ask
requesters what they expect to record and what outcome they need before
selecting an implementation.

---

## 4. Platform distinctions

```text
Quill product model
    -> shared transcript format
    -> shared transcription engines
    -> shared product identity

platform implementation
    -> platform-specific audio capture
    -> platform-specific permissions
    -> platform-specific packaging
    -> platform-specific lifecycle and updates
```

Shared product intent does not imply shared implementation cost.

---

## 5. Promotion rule

Evaluate each expansion using:

```text
qualified demand × user value × strategic reuse
──────────────────────────────────────────────
engineering cost + maintenance burden
```

A request becomes qualified when it identifies:

1. a distinct requester;
2. the job they expect Quill to perform;
3. their operating system or language;
4. willingness to test an early build; and
5. the consequence of the capability being absent.

The product page should collect separate expressions of interest for Windows,
Linux, mobile, and additional languages. GitHub reactions and replies provide
supporting evidence but do not substitute for qualified requests.

The provisional sequence is:

```text
stable normie-ready macOS release
    -> multilingual transcription and diarization evaluated independently
    -> Windows
    -> Linux
    -> mobile after the requested job is understood
```

Revise the sequence when observed demand or implementation evidence changes
the expected-value ranking.

---

## 6. Request ledger

Record new evidence without rewriting the roadmap after each response.

| Date | Requester | Request | Platform / language | Expected job | Beta willingness | Source |
|---|---|---|---|---|---|---|
| `2026.07.29` | Multiple public respondents | Mobile, Windows, Linux, and additional-language support | Mixed | Not yet qualified | Unknown | Current X response cluster |
| `2026.07.29` | Andrew | One conventional audio file instead of exposed split CAF tracks | macOS | Play, share, and reuse a completed recording without understanding Quill's internal capture model | Product requirement | Direct product use |
| `2026.07.30` | Andrew | Multi-speaker diarization | macOS initially | Distinguish participants in interviews, podcasts, and group conversations instead of collapsing everyone into `them` | Product hypothesis | Internal product observation |
