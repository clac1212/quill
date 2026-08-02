//! Quill for Windows — shared library behind both binaries.
//!
//! `src/bin/probe.rs` (M1 capture probe) and `src/main.rs` (M3 tray app)
//! both import capture and session code from here. The `wav` module and the
//! portable domain types compile on any host so the crash-tolerance tests
//! run natively; everything that touches WASAPI/COM is `cfg(windows)`.

pub mod audio;
#[cfg(windows)]
pub mod session;
