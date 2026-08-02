//! Microphone capture: WASAPI shared-mode client on the default input,
//! requesting the same 48 kHz stereo f32 format as the loopback path with
//! AUTOCONVERTPCM so the engine resamples whatever the device native rate is.

use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::thread::JoinHandle;

use windows::Win32::Media::Audio::{
    eCapture, IAudioCaptureClient, IAudioClient, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
};
use windows::Win32::System::Com::CLSCTX_ALL;

use crate::audio::com::ComGuard;
use crate::audio::pump::{CapturePump, EventHandle, Shared};
use crate::audio::{device, CaptureError, QpcInstant, TrackRecorder, TrackStats};

const BUFFER_DURATION_HNS: i64 = 2_000_000; // 200 ms

pub struct MicRecorder {
    shared: Shared,
    worker: Option<JoinHandle<Result<TrackStats, CaptureError>>>,
}

impl MicRecorder {
    pub fn new() -> Self {
        Self {
            shared: Shared::new(),
            worker: None,
        }
    }
}

impl Default for MicRecorder {
    fn default() -> Self {
        Self::new()
    }
}

impl TrackRecorder for MicRecorder {
    fn start(&mut self, out: &Path) -> Result<(), CaptureError> {
        let out: PathBuf = out.to_owned();
        let shared = self.shared.clone_refs();
        let (ready_tx, ready_rx) = mpsc::channel();

        let worker = std::thread::Builder::new()
            .name("quill-mic".into())
            .spawn(move || {
                let _com = match ComGuard::init() {
                    Ok(g) => g,
                    Err(e) => return Err(e),
                };
                let (client, capture, event, channels) = match activate() {
                    Ok(ctx) => ctx,
                    Err(e) => return Err(e),
                };
                CapturePump::new(&client, &capture, &event, channels, &out, &shared, None)
                    .run(ready_tx)
            })
            .map_err(CaptureError::Io)?;
        self.worker = Some(worker);

        match ready_rx.recv() {
            Ok(()) => Ok(()),
            _ => Err(self.stop().expect_err("worker signalled failure")),
        }
    }

    fn stop(&mut self) -> Result<TrackStats, CaptureError> {
        let Some(worker) = self.worker.take() else {
            return Err(CaptureError::Io(std::io::Error::other(
                "mic recorder was never started",
            )));
        };
        self.shared.stop.store(true, Ordering::Release);
        worker.join().unwrap_or_else(|_| {
            Err(CaptureError::Io(std::io::Error::other(
                "mic worker panicked",
            )))
        })
    }

    fn first_buffer_at(&self) -> Option<QpcInstant> {
        let qpc = self.shared.first_buffer_qpc.load(Ordering::Acquire);
        (qpc != 0).then_some(QpcInstant(qpc))
    }

    fn has_stopped(&self) -> bool {
        self.worker.as_ref().is_some_and(JoinHandle::is_finished)
    }
}

type CaptureCtx = (IAudioClient, IAudioCaptureClient, EventHandle, u16);

fn activate() -> Result<CaptureCtx, CaptureError> {
    let endpoint = device::default_endpoint(eCapture)?;
    let client: IAudioClient = unsafe { endpoint.Activate(CLSCTX_ALL, None) }
        .map_err(CaptureError::at("Activate(IAudioClient)"))?;

    let format = device::capture_waveformatex();
    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            BUFFER_DURATION_HNS,
            0,
            &format,
            None,
        )
    }
    .map_err(CaptureError::at("IAudioClient::Initialize(mic)"))?;

    let event = EventHandle::new()?;
    unsafe { client.SetEventHandle(event.raw()) }.map_err(CaptureError::at("SetEventHandle"))?;
    let capture: IAudioCaptureClient = unsafe { client.GetService() }
        .map_err(CaptureError::at("GetService(IAudioCaptureClient)"))?;
    Ok((client, capture, event, format.nChannels))
}
