---
title: "Windows audio targets can resolve to renderer child processes"
date: 2026-08-02
status: fixed
affects: "Windows process-loopback target discovery"
---

## Context

WASAPI process loopback includes the selected process and its descendants. The
capture probe therefore needs to offer an application's root process rather
than an isolated renderer or audio-helper child. Calling applications commonly
use multiple processes whose executable names are not necessarily identical.

## Problem statement

Target discovery climbs from an audio-session PID only while its parent has the
same executable name. A renderer with a different name remains the capture
target, so loopback excludes its parent and siblings. This can produce an
incomplete or silent system track in multi-process calling applications.

## RCA

`IAudioSessionControl2::GetProcessId` identifies the process associated with an
audio session, but process-loopback inclusion is directional: it captures that
PID and child processes, never ancestors or siblings. Executable-name equality
is not an application identity and cannot reliably locate the application
root.

Blindly climbing to the oldest ancestor is also wrong. Desktop applications
are commonly launched by Explorer, terminals, or service infrastructure;
choosing one of those ancestors would capture unrelated processes.

The useful observable boundary for the M1 desktop-call matrix is ownership of a
visible top-level window. Renderer and utility children normally have no such
window, while the user-facing application process does. The nearest qualifying
ancestor is the narrowest process tree containing the helper. Known shell,
terminal, and service hosts are traversal boundaries rather than candidates.

## Proposed fix

1. Enumerate PIDs owning visible top-level windows with `EnumWindows`.
2. Walk from each audio-session PID toward its ancestors and select the nearest
   visible-window owner before a shell/service boundary.
3. If there is no visible owner, retain the existing same-executable climb as a
   conservative fallback for headless or tray-only applications.
4. Extract the pure tree-selection policy into a portable module and cover
   different-name renderers, shell boundaries, headless fallback, missing
   parents, and malformed cycles with unit tests.

The Windows VM application matrix remains the acceptance test because window
and process layouts belong to the applications, not to a stable Windows API
contract.

## Relevant files

**Fix targets:**

- `windows/src/audio/process.rs` — collects audio-session and window-owner PIDs.
- `windows/src/audio/process_tree.rs` — portable root-selection policy and tests.
- `windows/src/audio/mod.rs` — declares the private policy module.
- `windows/Cargo.toml` — enables the Windows window-enumeration API surface.

**Downstream:**

- `windows/src/bin/probe.rs` — displays and resolves capture targets.
- `windows/src/audio/loopback.rs` — passes the selected root PID to process loopback.
