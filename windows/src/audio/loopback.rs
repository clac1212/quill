//! System-audio capture. Default path: per-process-tree loopback via
//! `ActivateAudioInterfaceAsync` (plan decision 4) — captures the selected
//! app and its children regardless of output device, and nothing else.
//! Fallback (`--all-system-audio`): plain endpoint loopback on the default
//! render device, restoring macOS semantics.

use std::mem::ManuallyDrop;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::thread::JoinHandle;

use windows::core::{implement, Interface, Ref, HRESULT, PCWSTR};
use windows::Win32::Foundation::{HANDLE, WAIT_OBJECT_0};
use windows::Win32::Media::Audio::{
    eRender, ActivateAudioInterfaceAsync, IActivateAudioInterfaceAsyncOperation,
    IActivateAudioInterfaceCompletionHandler, IActivateAudioInterfaceCompletionHandler_Impl,
    IAudioCaptureClient, IAudioClient, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
    AUDCLNT_STREAMFLAGS_LOOPBACK, AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
    AUDIOCLIENT_ACTIVATION_PARAMS, AUDIOCLIENT_ACTIVATION_PARAMS_0,
    AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK, AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS,
    PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE, VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
};
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Threading::{SetEvent, WaitForSingleObject};
use windows::Win32::System::Variant::VT_BLOB;

use crate::audio::com::ComGuard;
use crate::audio::pump::{CapturePump, EventHandle, ProcessMonitor, Shared};
use crate::audio::{device, CaptureError, Pid, QpcInstant, TrackRecorder, TrackStats};

const ACTIVATION_TIMEOUT_MS: u32 = 5_000;
const BUFFER_DURATION_HNS: i64 = 2_000_000; // 200 ms

#[derive(Clone, Copy, Debug)]
pub enum LoopbackTarget {
    /// The selected process and its descendants (Teams/Zoom renderer
    /// children ride along via INCLUDE_TARGET_PROCESS_TREE).
    ProcessTree(Pid),
    /// Everything on the default render endpoint.
    Endpoint,
}

pub struct LoopbackRecorder {
    target: LoopbackTarget,
    shared: Shared,
    worker: Option<JoinHandle<Result<TrackStats, CaptureError>>>,
}

impl LoopbackRecorder {
    pub fn new(target: LoopbackTarget) -> Self {
        Self {
            target,
            shared: Shared::new(),
            worker: None,
        }
    }
}

impl TrackRecorder for LoopbackRecorder {
    fn start(&mut self, out: &Path) -> Result<(), CaptureError> {
        let target = self.target;
        let out: PathBuf = out.to_owned();
        let shared = self.shared.clone_refs();
        let (ready_tx, ready_rx) = mpsc::channel();

        let worker = std::thread::Builder::new()
            .name("quill-loopback".into())
            .spawn(move || {
                let _com = match ComGuard::init() {
                    Ok(g) => g,
                    Err(e) => return Err(e),
                };
                let target_monitor = match target {
                    LoopbackTarget::ProcessTree(pid) => Some(ProcessMonitor::open(pid)?),
                    LoopbackTarget::Endpoint => None,
                };
                let setup = activate(target);
                let (client, capture, event, channels) = match setup {
                    Ok(ctx) => ctx,
                    Err(e) => return Err(e),
                };
                CapturePump::new(
                    &client,
                    &capture,
                    &event,
                    channels,
                    &out,
                    &shared,
                    target_monitor.as_ref(),
                )
                .run(ready_tx)
            })
            .map_err(CaptureError::Io)?;
        self.worker = Some(worker);

        match ready_rx.recv() {
            Ok(()) => Ok(()),
            // Setup failed (or the thread died): the join result holds the
            // real error.
            _ => Err(self.stop().expect_err("worker signalled failure")),
        }
    }

    fn stop(&mut self) -> Result<TrackStats, CaptureError> {
        let Some(worker) = self.worker.take() else {
            return Err(CaptureError::Io(std::io::Error::other(
                "loopback recorder was never started",
            )));
        };
        self.shared.stop.store(true, Ordering::Release);
        worker.join().unwrap_or_else(|_| {
            Err(CaptureError::Io(std::io::Error::other(
                "loopback worker panicked",
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

fn activate(target: LoopbackTarget) -> Result<CaptureCtx, CaptureError> {
    let format = device::capture_waveformatex();
    let (client, flags) = match target {
        LoopbackTarget::ProcessTree(pid) => (
            activate_process_client(pid)?,
            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        ),
        LoopbackTarget::Endpoint => {
            let endpoint = device::default_endpoint(eRender)?;
            let client: IAudioClient =
                unsafe { endpoint.Activate(windows::Win32::System::Com::CLSCTX_ALL, None) }
                    .map_err(CaptureError::at("Activate(IAudioClient)"))?;
            (
                client,
                AUDCLNT_STREAMFLAGS_LOOPBACK
                    | AUDCLNT_STREAMFLAGS_EVENTCALLBACK
                    | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
                    | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            )
        }
    };

    unsafe {
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            flags,
            BUFFER_DURATION_HNS,
            0,
            &format,
            None,
        )
    }
    .map_err(|e| match target {
        _ if e.code() == windows::Win32::Media::Audio::AUDCLNT_E_UNSUPPORTED_FORMAT => {
            CaptureError::FormatRejected {
                requested: crate::audio::WaveFormat {
                    sample_rate: format.nSamplesPerSec,
                    channels: format.nChannels,
                    bits_per_sample: format.wBitsPerSample,
                    float: true,
                },
            }
        }
        _ => CaptureError::Activation {
            hr: e.code(),
            stage: "IAudioClient::Initialize(loopback)",
        },
    })?;

    let event = EventHandle::new()?;
    unsafe { client.SetEventHandle(event.raw()) }.map_err(CaptureError::at("SetEventHandle"))?;
    let capture: IAudioCaptureClient = unsafe { client.GetService() }
        .map_err(CaptureError::at("GetService(IAudioCaptureClient)"))?;
    Ok((client, capture, event, format.nChannels))
}

/// The async activation dance for the process-loopback virtual device: blob
/// PROPVARIANT carrying AUDIOCLIENT_ACTIVATION_PARAMS, completion handler
/// signalling an event, result unwrapped from the operation object.
fn activate_process_client(pid: Pid) -> Result<IAudioClient, CaptureError> {
    let params = AUDIOCLIENT_ACTIVATION_PARAMS {
        ActivationType: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
        Anonymous: AUDIOCLIENT_ACTIVATION_PARAMS_0 {
            ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
                TargetProcessId: pid.get(),
                ProcessLoopbackMode: PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE,
            },
        },
    };
    let prop = blob_propvariant(&params);

    let done = EventHandle::new()?;
    let handler: IActivateAudioInterfaceCompletionHandler = ActivationSignal {
        event: done.raw().0 as isize,
    }
    .into();

    let operation: IActivateAudioInterfaceAsyncOperation = unsafe {
        ActivateAudioInterfaceAsync(
            PCWSTR(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK.as_ptr()),
            &IAudioClient::IID,
            Some(&*prop),
            &handler,
        )
    }
    .map_err(CaptureError::at("ActivateAudioInterfaceAsync"))?;

    let wait = unsafe { WaitForSingleObject(done.raw(), ACTIVATION_TIMEOUT_MS) };
    if wait != WAIT_OBJECT_0 {
        return Err(CaptureError::Activation {
            hr: HRESULT(0),
            stage: "activation completion timed out",
        });
    }

    let mut hr = HRESULT(0);
    let mut activated: Option<windows::core::IUnknown> = None;
    unsafe { operation.GetActivateResult(&mut hr, &mut activated) }
        .map_err(CaptureError::at("GetActivateResult"))?;
    hr.ok()
        .map_err(CaptureError::at("process loopback activation"))?;
    activated
        .ok_or(CaptureError::Activation {
            hr: HRESULT(0),
            stage: "activation returned no interface",
        })?
        .cast::<IAudioClient>()
        .map_err(CaptureError::at("cast to IAudioClient"))
}

#[implement(IActivateAudioInterfaceCompletionHandler)]
struct ActivationSignal {
    /// Raw event handle as isize: HANDLE itself is not Sync and the COM
    /// callback arrives on a worker thread.
    event: isize,
}

impl IActivateAudioInterfaceCompletionHandler_Impl for ActivationSignal_Impl {
    fn ActivateCompleted(
        &self,
        _operation: Ref<'_, IActivateAudioInterfaceAsyncOperation>,
    ) -> windows::core::Result<()> {
        unsafe {
            let _ = SetEvent(HANDLE(self.event as *mut core::ffi::c_void));
        }
        Ok(())
    }
}

/// PROPVARIANT of type VT_BLOB pointing at the activation params.
/// Constructed by layout-compatible transmute because the windows-rs
/// PROPVARIANT exposes no blob constructor; ManuallyDrop because
/// PropVariantClear would try to CoTaskMemFree our stack pointer.
fn blob_propvariant(params: &AUDIOCLIENT_ACTIVATION_PARAMS) -> ManuallyDrop<PROPVARIANT> {
    #[repr(C)]
    struct BlobPropVariant {
        vt: u16,
        reserved: [u16; 3],
        cb_size: u32,
        _pad: u32,
        data: *const AUDIOCLIENT_ACTIVATION_PARAMS,
    }
    const _: () =
        assert!(std::mem::size_of::<BlobPropVariant>() == std::mem::size_of::<PROPVARIANT>());

    let raw = BlobPropVariant {
        vt: VT_BLOB.0,
        reserved: [0; 3],
        cb_size: std::mem::size_of::<AUDIOCLIENT_ACTIVATION_PARAMS>() as u32,
        _pad: 0,
        data: params,
    };
    ManuallyDrop::new(unsafe { std::mem::transmute::<BlobPropVariant, PROPVARIANT>(raw) })
}
