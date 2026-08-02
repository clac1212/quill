//! Capture-target discovery: processes with audio render sessions, not a
//! raw process list, deduped so a multi-process app (Teams, browsers) shows
//! as one row keyed by its top-level parent.

use std::collections::{HashMap, HashSet};

use windows::core::{Interface, BOOL};
use windows::Win32::Foundation::{CloseHandle, HWND, LPARAM};
use windows::Win32::Media::Audio::{
    eRender, AudioSessionStateActive, IAudioSessionControl2, IAudioSessionManager2,
};
use windows::Win32::System::Com::CLSCTX_ALL;
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowThreadProcessId, IsWindowVisible,
};

use crate::audio::process_tree::{capture_root, ProcInfo};
use crate::audio::{device, CaptureError, CaptureTarget, Pid};

/// Enumerate processes with render sessions across every active render
/// endpoint (a session on a non-default device still counts), then collapse
/// each to the topmost ancestor with the same executable name.
pub fn capture_targets() -> Result<Vec<CaptureTarget>, CaptureError> {
    let procs = process_snapshot()?;
    let window_pids = visible_window_pids()?;
    let mut session_pids: HashMap<u32, bool> = HashMap::new();

    for endpoint in device::active_endpoints(eRender)? {
        let manager: IAudioSessionManager2 = unsafe { endpoint.Activate(CLSCTX_ALL, None) }
            .map_err(CaptureError::at("Activate(IAudioSessionManager2)"))?;
        let sessions = unsafe { manager.GetSessionEnumerator() }
            .map_err(CaptureError::at("GetSessionEnumerator"))?;
        let count = unsafe { sessions.GetCount() }.map_err(CaptureError::at("GetCount"))?;
        for i in 0..count {
            let Ok(control) = (unsafe { sessions.GetSession(i) }) else {
                continue;
            };
            let Ok(control2) = control.cast::<IAudioSessionControl2>() else {
                continue;
            };
            // System-sounds session has no single process; skip it.
            let Ok(pid) = (unsafe { control2.GetProcessId() }) else {
                continue;
            };
            if pid == 0 {
                continue;
            }
            let active = unsafe { control.GetState() }
                .map(|s| s == AudioSessionStateActive)
                .unwrap_or(false);
            *session_pids.entry(pid).or_insert(false) |= active;
        }
    }

    let mut by_top: HashMap<u32, CaptureTarget> = HashMap::new();
    for (pid, active) in session_pids {
        let Some(info) = procs.get(&pid) else {
            continue; // exited between session scan and snapshot
        };
        let top = capture_root(pid, &procs, &window_pids);
        let Some(top_pid) = Pid::new(top) else {
            continue;
        };
        let entry = by_top.entry(top).or_insert_with(|| CaptureTarget {
            pid: top_pid,
            name: procs
                .get(&top)
                .map_or_else(|| info.name.clone(), |p| p.name.clone()),
            session_active: false,
        });
        entry.session_active |= active;
    }

    let mut targets: Vec<CaptureTarget> = by_top.into_values().collect();
    targets.sort_by_key(|t| t.name.to_lowercase());
    Ok(targets)
}

fn process_snapshot() -> Result<HashMap<u32, ProcInfo>, CaptureError> {
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }
        .map_err(CaptureError::at("CreateToolhelp32Snapshot"))?;
    let mut procs = HashMap::new();
    let mut entry = PROCESSENTRY32W {
        dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
        ..Default::default()
    };
    unsafe {
        if Process32FirstW(snapshot, &mut entry).is_ok() {
            loop {
                let len = entry
                    .szExeFile
                    .iter()
                    .position(|&c| c == 0)
                    .unwrap_or(entry.szExeFile.len());
                procs.insert(
                    entry.th32ProcessID,
                    ProcInfo {
                        name: String::from_utf16_lossy(&entry.szExeFile[..len]),
                        parent: entry.th32ParentProcessID,
                    },
                );
                if Process32NextW(snapshot, &mut entry).is_err() {
                    break;
                }
            }
        }
        let _ = CloseHandle(snapshot);
    }
    Ok(procs)
}

fn visible_window_pids() -> Result<HashSet<u32>, CaptureError> {
    let mut pids = HashSet::new();
    // SAFETY: EnumWindows invokes the callback synchronously. `pids` remains
    // alive and exclusively borrowed for the full call, and the callback casts
    // the LPARAM back to its original `HashSet<u32>` type.
    unsafe {
        EnumWindows(
            Some(collect_visible_window_pid),
            LPARAM((&raw mut pids).cast::<core::ffi::c_void>() as isize),
        )
    }
    .map_err(CaptureError::at("EnumWindows"))?;
    Ok(pids)
}

unsafe extern "system" fn collect_visible_window_pid(hwnd: HWND, state: LPARAM) -> BOOL {
    // SAFETY: `state` is created by `visible_window_pids` from a live,
    // exclusively borrowed HashSet and EnumWindows does not retain it.
    let pids = unsafe { &mut *(state.0 as *mut HashSet<u32>) };
    if unsafe { IsWindowVisible(hwnd) }.as_bool() {
        let mut pid = 0;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&raw mut pid)) };
        if pid != 0 {
            pids.insert(pid);
        }
    }
    BOOL(1)
}
