---
title: "Windows WAV checkpoints do not establish their crash guarantee"
date: 2026-08-02
status: fixed
affects: "Windows recording durability and crash recovery"
---

## Context

The Windows probe writes 16-bit mono WAV tracks during recording and patches
their RIFF and data lengths every ten seconds. The plan promises that a killed
probe leaves a playable file whose declared audio never exceeds durable PCM.

## Problem statement

Periodic checkpoints currently write both header lengths without first syncing
PCM. They sync only during clean finish. A power interruption can therefore
persist a new declared length ahead of its audio data. A process kill between
the two header writes can also leave mismatched lengths.

The tests snapshot files only before or after the complete patch operation,
inspect four header fields manually, and call that a simulated kill. They never
terminate a subprocess during a checkpoint or ask a WAV decoder to open the
intermediate file.

## RCA

`File::write_all` makes data visible through the operating-system cache but does
not establish durable ordering. `patch_header` writes RIFF length and data
length consecutively and `finish` calls `sync_data` only after both writes.

The two WAV lengths occupy separate offsets and cannot be updated atomically.
The safe ordering is therefore intentional degradation:

1. Sync all appended PCM.
2. Write and sync the new RIFF length.
3. Write and sync the new data length.

If termination occurs after step 1, both lengths describe the previous durable
checkpoint. If it occurs after step 2, RIFF spans the newer durable bytes but
the data chunk still exposes only the previous checkpoint. If it occurs after
step 3, both lengths describe the new checkpoint. At no boundary does the data
chunk expose bytes that were not synced first.

## Proposed fix

- Replace the header patch with the ordered, individually synced checkpoint.
- Sync the initial empty header before capture startup reports ready.
- Add best-effort checkpointing on ordinary drop while retaining `finish` as
  the error-reporting clean-stop path.
- Reject WAV sizes that exceed 32-bit RIFF limits instead of wrapping them.
- Add a subprocess truncation harness. The child writes one completed interval,
  starts another checkpoint, and aborts after each durability boundary. The
  parent reopens every result with the `hound` WAV decoder and verifies the
  readable sample count and declared-versus-file-length invariant.

The guarantee is scoped to process termination after a completed filesystem
sync. Hardware, filesystem, or kernel failures that violate successful sync
semantics are outside the application-level contract.

## Relevant files

**Fix targets:**

- `windows/src/audio/wav.rs` — ordered checkpoints, drop behavior, crash harness.
- `windows/Cargo.toml` — decoder dependency used only by tests.
- `windows/Cargo.lock` — reproducible dependency resolution.

**Flow:**

- `windows/src/audio/pump.rs` — creates, appends to, and finishes the writer.
- `.plan/windows.md` — defines the bounded-loss guarantee and M1 exit test.
