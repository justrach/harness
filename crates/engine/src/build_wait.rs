//! Explicit, per-run queue signals from `scripts/heavy-build.sh`.
//!
//! A wrapper creates `<pid>` containing its initial Unix-second timestamp only
//! while it is waiting for the shared build lock. No output/CPU heuristic can
//! establish this state. The private directory dies with the owning run.

use std::path::Path;

pub(crate) struct BuildWaitMonitor {
    directory: tempfile::TempDir,
}

impl BuildWaitMonitor {
    pub(crate) fn new() -> std::io::Result<Self> {
        Ok(Self {
            directory: tempfile::Builder::new()
                .prefix("harness-build-wait-")
                .tempdir()?,
        })
    }

    pub(crate) fn path(&self) -> &Path {
        self.directory.path()
    }

    pub(crate) fn since(&self, now: i64) -> Option<i64> {
        // A run cannot need unbounded status work. The wrapper itself is small;
        // more than 64 simultaneously queued builds is already exceptional.
        std::fs::read_dir(self.path())
            .ok()?
            .take(64)
            .filter_map(|entry| {
                let entry = entry.ok()?;
                if !entry.file_type().ok()?.is_file() || entry.metadata().ok()?.len() > 32 {
                    return None;
                }
                let pid = entry.file_name().to_str()?.parse::<u32>().ok()?;
                if !process_alive(pid) {
                    return None;
                }
                let since = std::fs::read_to_string(entry.path())
                    .ok()?
                    .trim()
                    .parse::<i64>()
                    .ok()?;
                (since > 0 && since <= now).then_some(since)
            })
            .min()
    }
}

#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    if pid == 0 || pid > i32::MAX as u32 {
        return false;
    }
    // Signal zero checks existence without sending a signal. EPERM is also a
    // live process, although normally these wrappers belong to our own user.
    (unsafe { libc::kill(pid as i32, 0) == 0 })
        || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(windows)]
fn process_alive(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    if pid == 0 {
        return false;
    }
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return false;
        }
        let mut exit_code = 0;
        let alive = GetExitCodeProcess(process, &mut exit_code) != 0 && exit_code == 259;
        CloseHandle(process);
        alive
    }
}

#[cfg(not(any(unix, windows)))]
fn process_alive(_: u32) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_wait_requires_an_explicit_live_marker_and_clears_on_acquisition() {
        let monitor = BuildWaitMonitor::new().unwrap();
        assert_eq!(monitor.since(1_000), None, "silence is not a queue signal");
        let marker = monitor.path().join(std::process::id().to_string());
        std::fs::write(&marker, "760\n").unwrap();
        assert_eq!(monitor.since(1_000), Some(760));
        assert_eq!(
            monitor.since(1_030),
            Some(760),
            "the wait's clock does not restart"
        );
        std::fs::remove_file(marker).unwrap();
        assert_eq!(monitor.since(1_030), None);
    }

    #[test]
    fn build_wait_ignores_dead_invalid_and_future_markers() {
        let monitor = BuildWaitMonitor::new().unwrap();
        for (name, value) in [("0", "1"), ("2147483647", "1"), ("not-a-pid", "1")] {
            std::fs::write(monitor.path().join(name), value).unwrap();
        }
        let own = monitor.path().join(std::process::id().to_string());
        for value in [
            "",
            "not-a-time",
            "-1",
            "0",
            "1001",
            "123456789012345678901234567890123456789",
        ] {
            std::fs::write(&own, value).unwrap();
            assert_eq!(monitor.since(1_000), None, "invalid marker {value:?}");
        }
    }

    #[test]
    fn build_wait_is_run_scoped_and_uses_earliest_wait() {
        let first = BuildWaitMonitor::new().unwrap();
        let second = BuildWaitMonitor::new().unwrap();
        let pid = std::process::id();
        std::fs::write(first.path().join(pid.to_string()), "800").unwrap();
        std::fs::write(first.path().join(format!("0{pid}")), "700").unwrap();
        assert_eq!(first.since(1_000), Some(700));
        assert_eq!(second.since(1_000), None);
        let retired = first.path().to_path_buf();
        drop(first);
        assert!(
            !retired.exists(),
            "retiring a run removes even orphaned markers"
        );
    }

    #[cfg(unix)]
    #[test]
    fn build_wait_does_not_follow_marker_symlinks() {
        let monitor = BuildWaitMonitor::new().unwrap();
        let target = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(target.path(), "760").unwrap();
        std::os::unix::fs::symlink(
            target.path(),
            monitor.path().join(std::process::id().to_string()),
        )
        .unwrap();
        assert_eq!(monitor.since(1_000), None);
    }
}
