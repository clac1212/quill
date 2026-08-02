//! Capture domain types shared by both recorders and the session.

use std::fmt;
use std::num::NonZeroU32;

pub mod wav;

#[cfg(windows)]
pub mod com;
#[cfg(windows)]
pub mod device;
#[cfg(windows)]
pub mod loopback;
#[cfg(windows)]
pub mod mic;
#[cfg(windows)]
pub mod process;
#[cfg(any(windows, test))]
mod process_tree;
#[cfg(windows)]
mod pump;

/// Windows process id. Zero is the idle process and never a capture target.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub struct Pid(NonZeroU32);

impl Pid {
    pub fn new(raw: u32) -> Option<Self> {
        NonZeroU32::new(raw).map(Self)
    }

    pub fn get(self) -> u32 {
        self.0.get()
    }
}

impl fmt::Display for Pid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// A process tree offered for capture: one row in the probe's picker and the
/// tray's (eventual) source menu.
#[derive(Clone, Debug)]
pub struct CaptureTarget {
    pub pid: Pid,
    /// Executable name of the top-level process, e.g. `ms-teams.exe`.
    pub name: String,
    /// Whether any render session in the tree is audibly playing right now.
    pub session_active: bool,
}

/// Instant on the QueryPerformanceCounter timeline, in 100 ns units — the
/// same unit `IAudioCaptureClient::GetBuffer` reports buffer positions in.
/// Alignment math never touches wall clock (plan decision 10).
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct QpcInstant(pub i64);

impl QpcInstant {
    #[cfg(windows)]
    pub fn now() -> Self {
        use windows::Win32::System::Performance::{
            QueryPerformanceCounter, QueryPerformanceFrequency,
        };
        let mut ticks = 0i64;
        let mut freq = 0i64;
        // Never fails on XP+, per the API contract.
        unsafe {
            let _ = QueryPerformanceCounter(&mut ticks);
            let _ = QueryPerformanceFrequency(&mut freq);
        }
        // i128: ticks * 1e7 overflows i64 within hours of uptime.
        Self(((ticks as i128 * 10_000_000) / freq as i128) as i64)
    }

    pub fn millis_since(self, base: QpcInstant) -> i64 {
        (self.0 - base.0) / 10_000
    }
}

/// PCM stream description, independent of the WAVEFORMATEX raw layout.
#[derive(Clone, Copy, Debug)]
pub struct WaveFormat {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    pub float: bool,
}

/// End-of-track accounting, returned by [`TrackRecorder::stop`].
#[derive(Clone, Copy, Debug)]
pub struct TrackStats {
    pub frames_written: u64,
    /// Peak absolute amplitude in [0, 1]. Below the silence floor ⇒ the
    /// track never heard anything and the probe exits with a diagnosis.
    pub peak_amplitude: f32,
}

#[cfg(windows)]
#[derive(Debug)]
pub enum CaptureError {
    DeviceNotFound,
    Activation {
        hr: windows::core::HRESULT,
        stage: &'static str,
    },
    FormatRejected {
        requested: WaveFormat,
    },
    TargetExited(Pid),
    Io(std::io::Error),
}

#[cfg(windows)]
impl fmt::Display for CaptureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DeviceNotFound => write!(f, "no default audio device"),
            Self::Activation { hr, stage } => {
                write!(f, "{stage} failed: {hr}")
            }
            Self::FormatRejected { requested } => write!(
                f,
                "device rejected {} Hz {}ch {}-bit",
                requested.sample_rate, requested.channels, requested.bits_per_sample
            ),
            Self::TargetExited(pid) => write!(f, "target process {pid} exited"),
            Self::Io(e) => write!(f, "audio file i/o: {e}"),
        }
    }
}

#[cfg(windows)]
impl std::error::Error for CaptureError {}

#[cfg(windows)]
impl From<std::io::Error> for CaptureError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

#[cfg(windows)]
impl CaptureError {
    /// Wrap a COM failure with the activation stage it happened at.
    pub(crate) fn at(stage: &'static str) -> impl FnOnce(windows::core::Error) -> Self {
        move |e| Self::Activation {
            hr: e.code(),
            stage,
        }
    }
}

/// One capture track. Both recorders implement this; `RecordingSession`
/// only speaks the trait.
#[cfg(windows)]
pub trait TrackRecorder: Send {
    /// Begin capture into `out`. Returns once audio is flowing or the
    /// activation path has failed — never leaves a half-started thread.
    fn start(&mut self, out: &std::path::Path) -> Result<(), CaptureError>;

    /// Final flush + header patch happen here; their failures surface
    /// instead of vanishing with the worker thread.
    fn stop(&mut self) -> Result<TrackStats, CaptureError>;

    /// QPC stamp of the first delivered buffer; `None` if no audio ever
    /// arrived. `start_offset_ms` derives from deltas between these.
    fn first_buffer_at(&self) -> Option<QpcInstant>;

    /// Whether the worker ended before the session requested a stop.
    fn has_stopped(&self) -> bool;
}
