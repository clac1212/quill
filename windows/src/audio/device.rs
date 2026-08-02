//! Endpoint lookup and format queries over IMMDeviceEnumerator.

use windows::Win32::Media::Audio::{
    eConsole, EDataFlow, IMMDevice, IMMDeviceEnumerator, MMDeviceEnumerator, DEVICE_STATE_ACTIVE,
    WAVEFORMATEX,
};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_ALL};

use crate::audio::CaptureError;

pub fn enumerator() -> Result<IMMDeviceEnumerator, CaptureError> {
    unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
        .map_err(CaptureError::at("CoCreateInstance(MMDeviceEnumerator)"))
}

/// Default console endpoint for the given flow (render or capture).
pub fn default_endpoint(flow: EDataFlow) -> Result<IMMDevice, CaptureError> {
    let enumerator = enumerator()?;
    unsafe { enumerator.GetDefaultAudioEndpoint(flow, eConsole) }
        .map_err(|_| CaptureError::DeviceNotFound)
}

/// All active endpoints for a flow — process.rs walks every render endpoint
/// so sessions playing to a non-default device still show up.
pub fn active_endpoints(flow: EDataFlow) -> Result<Vec<IMMDevice>, CaptureError> {
    let enumerator = enumerator()?;
    let collection = unsafe { enumerator.EnumAudioEndpoints(flow, DEVICE_STATE_ACTIVE) }
        .map_err(CaptureError::at("EnumAudioEndpoints"))?;
    let count = unsafe { collection.GetCount() }.map_err(CaptureError::at("GetCount"))?;
    let mut devices = Vec::with_capacity(count as usize);
    for i in 0..count {
        devices.push(unsafe { collection.Item(i) }.map_err(CaptureError::at("Item"))?);
    }
    Ok(devices)
}

/// The fixed format both capture paths request: 48 kHz stereo f32
/// (plan decision 5). Process loopback requires the client to name a format;
/// the mic path requests the same one with AUTOCONVERTPCM.
pub fn capture_waveformatex() -> WAVEFORMATEX {
    const WAVE_FORMAT_IEEE_FLOAT: u16 = 3;
    let channels = 2u16;
    let sample_rate = 48_000u32;
    let bits = 32u16;
    let block_align = channels * bits / 8;
    WAVEFORMATEX {
        wFormatTag: WAVE_FORMAT_IEEE_FLOAT,
        nChannels: channels,
        nSamplesPerSec: sample_rate,
        nAvgBytesPerSec: sample_rate * block_align as u32,
        nBlockAlign: block_align,
        wBitsPerSample: bits,
        cbSize: 0,
    }
}
