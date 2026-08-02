//! Portable policy for mapping an audio-session process to a capture root.

use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug)]
pub(crate) struct ProcInfo {
    pub(crate) name: String,
    pub(crate) parent: u32,
}

/// Select the narrowest useful ancestor for process-tree loopback.
///
/// A visible top-level-window owner is an application boundary. Shell,
/// terminal, and service hosts are traversal boundaries and are never selected.
/// If no window owner exists, climb only through the same executable name.
pub(crate) fn capture_root(
    pid: u32,
    procs: &HashMap<u32, ProcInfo>,
    window_pids: &HashSet<u32>,
) -> u32 {
    let mut current = pid;
    for _ in 0..32 {
        let Some(info) = procs.get(&current) else {
            break;
        };
        if is_host_boundary(&info.name) {
            break;
        }
        if window_pids.contains(&current) {
            return current;
        }
        if info.parent == 0 || info.parent == current {
            break;
        }
        current = info.parent;
    }

    same_executable_root(pid, procs)
}

fn same_executable_root(pid: u32, procs: &HashMap<u32, ProcInfo>) -> u32 {
    let Some(start) = procs.get(&pid) else {
        return pid;
    };
    let mut current = pid;
    for _ in 0..32 {
        let Some(info) = procs.get(&current) else {
            break;
        };
        match procs.get(&info.parent) {
            Some(parent)
                if info.parent != current && parent.name.eq_ignore_ascii_case(&start.name) =>
            {
                current = info.parent;
            }
            _ => break,
        }
    }
    current
}

fn is_host_boundary(name: &str) -> bool {
    const HOSTS: &[&str] = &[
        "cmd.exe",
        "explorer.exe",
        "powershell.exe",
        "pwsh.exe",
        "services.exe",
        "svchost.exe",
        "wininit.exe",
        "winlogon.exe",
        "windowsterminal.exe",
    ];
    HOSTS.iter().any(|host| name.eq_ignore_ascii_case(host))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proc(name: &str, parent: u32) -> ProcInfo {
        ProcInfo {
            name: name.into(),
            parent,
        }
    }

    #[test]
    fn different_name_renderer_resolves_to_window_owner() {
        let procs = HashMap::from([
            (10, proc("ms-teams.exe", 20)),
            (11, proc("msedgewebview2.exe", 10)),
            (20, proc("explorer.exe", 0)),
        ]);
        let windows = HashSet::from([10, 20]);

        assert_eq!(capture_root(11, &procs, &windows), 10);
        assert_ne!(capture_root(11, &procs, &windows), 20);
    }

    #[test]
    fn nearest_window_owner_wins() {
        let procs = HashMap::from([
            (10, proc("call.exe", 20)),
            (11, proc("renderer.exe", 10)),
            (20, proc("launcher.exe", 30)),
            (30, proc("explorer.exe", 0)),
        ]);
        let windows = HashSet::from([10, 20, 30]);

        assert_eq!(capture_root(11, &procs, &windows), 10);
        assert_ne!(capture_root(11, &procs, &windows), 20);
    }

    #[test]
    fn terminal_is_never_selected_for_headless_child() {
        let procs = HashMap::from([
            (10, proc("call.exe", 20)),
            (20, proc("pwsh.exe", 30)),
            (30, proc("windowsterminal.exe", 0)),
        ]);
        let windows = HashSet::from([20, 30]);

        assert_eq!(capture_root(10, &procs, &windows), 10);
        assert_ne!(capture_root(10, &procs, &windows), 20);
    }

    #[test]
    fn headless_same_executable_children_collapse() {
        let procs = HashMap::from([
            (10, proc("signal.exe", 20)),
            (11, proc("signal.exe", 10)),
            (20, proc("explorer.exe", 0)),
        ]);

        assert_eq!(capture_root(11, &procs, &HashSet::new()), 10);
        assert_ne!(capture_root(11, &procs, &HashSet::new()), 20);
    }

    #[test]
    fn missing_process_and_parent_cycle_are_bounded() {
        let procs = HashMap::from([(10, proc("call.exe", 11)), (11, proc("call.exe", 10))]);

        assert_eq!(capture_root(99, &procs, &HashSet::new()), 99);
        assert!(matches!(capture_root(10, &procs, &HashSet::new()), 10 | 11));
    }
}
