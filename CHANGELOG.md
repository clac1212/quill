# Changelog

## Unreleased

- Organized Quill as a multiplatform repository with native macOS, Windows,
  and Linux platform roots, stable macOS build scripts, and an explicit shared
  architecture boundary.

## 0.1.1 - 2026-08-02

- Fixed Windows capture startup so recording is reported only after the WAV
  file and WASAPI stream are ready.
- Resolved audio renderer processes to their user-facing application roots
  without broadening capture into shell, terminal, or service processes.
- Made process-loopback recording stop with a diagnostic when its target exits
  instead of silently continuing against an obsolete PID.
