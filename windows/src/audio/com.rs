//! COM initialization guard. Every thread that touches WASAPI owns one.

use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_MULTITHREADED};

use crate::audio::CaptureError;

/// Balances `CoInitializeEx` with `CoUninitialize` on drop. Not `Send`:
/// COM init is per-thread state.
pub struct ComGuard {
    _not_send: std::marker::PhantomData<*const ()>,
}

impl ComGuard {
    pub fn init() -> Result<Self, CaptureError> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) }
            .ok()
            .map_err(CaptureError::at("CoInitializeEx"))?;
        Ok(Self {
            _not_send: std::marker::PhantomData,
        })
    }
}

impl Drop for ComGuard {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}
