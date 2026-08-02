//! Shared event-driven capture loop: both recorders drain an
//! `IAudioCaptureClient` into the crash-safe WAV writer here. Input is
//! interleaved f32 at 48 kHz (both paths request that format); output is
//! averaged-down 16-bit mono.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Arc;

use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Media::Audio::{
    IAudioCaptureClient, IAudioClient, AUDCLNT_BUFFERFLAGS_SILENT,
};
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};

use crate::audio::wav::WavWriter;
use crate::audio::{CaptureError, TrackStats};

pub(crate) const OUTPUT_SAMPLE_RATE: u32 = 48_000;
const WAIT_SLICE_MS: u32 = 200;

/// State shared between a recorder handle (app side) and its worker thread.
pub(crate) struct Shared {
    pub stop: Arc<AtomicBool>,
    /// QPC position (100 ns units) of the first captured frame, as reported
    /// by `GetBuffer` — not the dequeue time. 0 = no audio yet; a real QPC
    /// reading is never 0 at runtime.
    pub first_buffer_qpc: Arc<AtomicI64>,
}

impl Shared {
    pub fn new() -> Self {
        Self {
            stop: Arc::new(AtomicBool::new(false)),
            first_buffer_qpc: Arc::new(AtomicI64::new(0)),
        }
    }

    pub fn clone_refs(&self) -> Self {
        Self {
            stop: Arc::clone(&self.stop),
            first_buffer_qpc: Arc::clone(&self.first_buffer_qpc),
        }
    }
}

/// Auto-reset event with close-on-drop, for `SetEventHandle` and the
/// activation completion signal.
pub(crate) struct EventHandle(HANDLE);

impl EventHandle {
    pub fn new() -> Result<Self, CaptureError> {
        unsafe { CreateEventW(None, false, false, None) }
            .map(Self)
            .map_err(CaptureError::at("CreateEventW"))
    }

    pub fn raw(&self) -> HANDLE {
        self.0
    }
}

impl Drop for EventHandle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

/// Run until `shared.stop`: wait on the client's event, drain every pending
/// packet, downmix, append. Returns the final stats after a last drain and
/// the writer's closing header patch.
pub(crate) fn run(
    client: &IAudioClient,
    capture: &IAudioCaptureClient,
    event: &EventHandle,
    channels: u16,
    out: &Path,
    shared: &Shared,
) -> Result<TrackStats, CaptureError> {
    let mut writer = WavWriter::create(out, OUTPUT_SAMPLE_RATE)?;
    unsafe { client.Start() }.map_err(CaptureError::at("IAudioClient::Start"))?;

    let mut mono: Vec<i16> = Vec::new();
    while !shared.stop.load(Ordering::Acquire) {
        unsafe { WaitForSingleObject(event.raw(), WAIT_SLICE_MS) };
        drain(capture, channels, &mut mono, &mut writer, shared)?;
    }

    let _ = unsafe { client.Stop() };
    drain(capture, channels, &mut mono, &mut writer, shared)?;
    writer.finish().map_err(Into::into)
}

fn drain(
    capture: &IAudioCaptureClient,
    channels: u16,
    mono: &mut Vec<i16>,
    writer: &mut WavWriter,
    shared: &Shared,
) -> Result<(), CaptureError> {
    loop {
        let packet = unsafe { capture.GetNextPacketSize() }
            .map_err(CaptureError::at("GetNextPacketSize"))?;
        if packet == 0 {
            return Ok(());
        }

        let mut data: *mut u8 = std::ptr::null_mut();
        let mut frames = 0u32;
        let mut flags = 0u32;
        let mut qpc_position = 0u64;
        unsafe {
            capture.GetBuffer(
                &mut data,
                &mut frames,
                &mut flags,
                None,
                Some(&mut qpc_position),
            )
        }
        .map_err(CaptureError::at("GetBuffer"))?;

        if frames > 0
            && qpc_position != 0
            && shared.first_buffer_qpc.load(Ordering::Relaxed) == 0
        {
            shared
                .first_buffer_qpc
                .store(qpc_position as i64, Ordering::Release);
        }

        mono.clear();
        if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 {
            mono.resize(frames as usize, 0);
        } else {
            let samples = unsafe {
                std::slice::from_raw_parts(data as *const f32, frames as usize * channels as usize)
            };
            for frame in samples.chunks_exact(channels as usize) {
                let avg = frame.iter().sum::<f32>() / channels as f32;
                mono.push((avg.clamp(-1.0, 1.0) * 32767.0) as i16);
            }
        }

        // Write before release, but always release: the buffer must go back
        // to the engine even when the disk write fails.
        let write_result = writer.write_samples(mono);
        unsafe { capture.ReleaseBuffer(frames) }.map_err(CaptureError::at("ReleaseBuffer"))?;
        write_result?;
    }
}
