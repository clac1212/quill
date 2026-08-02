//! Recording session: two tracks, one directory, meta.json — mirrors
//! `macos/Sources/quill/RecordingSession.swift` and the shared contract in
//! `docs/architecture.md`.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::audio::loopback::{LoopbackRecorder, LoopbackTarget};
use crate::audio::mic::MicRecorder;
use crate::audio::{CaptureError, QpcInstant, TrackRecorder, TrackStats};

pub const MIC_FILE: &str = "mic.wav";
pub const SYSTEM_FILE: &str = "system.wav";

pub struct RecordingSession {
    dir: PathBuf,
    started: chrono::DateTime<chrono::Local>,
    /// Shared zero for both tracks' first-buffer deltas (plan decision 10).
    qpc_baseline: QpcInstant,
    mic: MicRecorder,
    system: LoopbackRecorder,
}

#[derive(Serialize)]
pub struct SessionMeta {
    pub started: String,
    pub ended: String,
    pub duration_seconds: u64,
    pub files: TrackFiles,
    pub start_offset_ms: TrackOffsets,
}

#[derive(Serialize)]
pub struct TrackFiles {
    pub mic: &'static str,
    pub system: &'static str,
}

/// Lag of each track behind the earliest first buffer, from QPC deltas.
#[derive(Serialize, Clone, Copy)]
pub struct TrackOffsets {
    pub mic: i64,
    pub system: i64,
}

/// Everything the probe (and later the tray) reports after stop.
pub struct SessionSummary {
    pub dir: PathBuf,
    pub mic: TrackStats,
    pub system: TrackStats,
    pub offsets: TrackOffsets,
    pub duration_seconds: u64,
    /// First-audio latency after session start per track, from the QPC
    /// baseline; None if the track never delivered a buffer.
    pub mic_latency_ms: Option<i64>,
    pub system_latency_ms: Option<i64>,
}

impl RecordingSession {
    /// Start both tracks: system first, then mic — a mic failure tears the
    /// loopback down so a half-silent session never runs (macOS order).
    pub fn start(root: &Path, target: LoopbackTarget) -> Result<Self, CaptureError> {
        let started = chrono::Local::now();
        let dir = create_session_dir(root, started)?;
        let qpc_baseline = QpcInstant::now();

        let mut system = LoopbackRecorder::new(target);
        system.start(&dir.join(SYSTEM_FILE))?;

        let mut mic = MicRecorder::new();
        if let Err(e) = mic.start(&dir.join(MIC_FILE)) {
            let _ = system.stop();
            return Err(e);
        }

        Ok(Self {
            dir,
            started,
            qpc_baseline,
            mic,
            system,
        })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Whether either capture worker ended before an explicit session stop.
    pub fn capture_has_stopped(&self) -> bool {
        self.mic.has_stopped() || self.system.has_stopped()
    }

    /// Stop both tracks and write meta.json. Both stops always run; the
    /// first error surfaces after cleanup.
    pub fn stop(mut self) -> Result<SessionSummary, CaptureError> {
        let mic_first = self.mic.first_buffer_at();
        let system_first = self.system.first_buffer_at();

        let system_result = self.system.stop();
        let mic_result = self.mic.stop();
        let system = system_result?;
        let mic = mic_result?;

        let ended = chrono::Local::now();
        let duration_seconds = (ended - self.started).num_seconds().max(0) as u64;

        let offsets = match (mic_first, system_first) {
            (Some(m), Some(s)) => {
                let earliest = m.min(s);
                TrackOffsets {
                    mic: m.millis_since(earliest),
                    system: s.millis_since(earliest),
                }
            }
            _ => TrackOffsets { mic: 0, system: 0 },
        };

        let meta = SessionMeta {
            started: self.started.to_rfc3339(),
            ended: ended.to_rfc3339(),
            duration_seconds,
            files: TrackFiles {
                mic: MIC_FILE,
                system: SYSTEM_FILE,
            },
            start_offset_ms: offsets,
        };
        let json = serde_json::to_vec_pretty(&meta).expect("meta serialization is infallible");
        std::fs::write(self.dir.join("meta.json"), json)?;

        Ok(SessionSummary {
            dir: self.dir,
            mic,
            system,
            offsets,
            duration_seconds,
            mic_latency_ms: mic_first.map(|t| t.millis_since(self.qpc_baseline)),
            system_latency_ms: system_first.map(|t| t.millis_since(self.qpc_baseline)),
        })
    }
}

/// `<root>/yyyy.MM.dd-HHmm`, suffixed `-2`, `-3`, … on collision — same
/// scheme as macOS.
fn create_session_dir(
    root: &Path,
    started: chrono::DateTime<chrono::Local>,
) -> Result<PathBuf, CaptureError> {
    std::fs::create_dir_all(root)?;
    let base = started.format("%Y.%m.%d-%H%M").to_string();
    let mut candidate = root.join(&base);
    let mut n = 1u32;
    while candidate.exists() {
        n += 1;
        candidate = root.join(format!("{base}-{n}"));
    }
    std::fs::create_dir(&candidate)?;
    Ok(candidate)
}
