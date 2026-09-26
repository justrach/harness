//! Owned agent processes. Non-Windows builds retain Tokio's command and child.
//! Windows uses native creation-time Job Object membership, never an implicit shell.
#[cfg(not(windows))]
pub use std::process::Stdio;
#[cfg(not(windows))]
pub use tokio::process::{Child, ChildStdin, ChildStdout, Command};
#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::{Child, ChildStdin, ChildStdout, Command, Stdio};

/// Run `spawn`, retrying briefly when Linux reports the executable as busy
/// (`ETXTBSY`). A binary still open for writing somewhere can't be executed
/// for a moment: a freshly written script, or a sibling thread's fork holding
/// the write descriptor until its exec. Test fixtures hit this in CI.
pub(crate) fn retry_busy<T>(mut spawn: impl FnMut() -> std::io::Result<T>) -> std::io::Result<T> {
    let mut attempt = 0u64;
    loop {
        match spawn() {
            Err(error) if error.kind() == std::io::ErrorKind::ExecutableFileBusy && attempt < 5 => {
                attempt += 1;
                std::thread::sleep(std::time::Duration::from_millis(20 * attempt));
            }
            other => return other,
        }
    }
}

#[cfg(unix)]
pub(crate) fn signal_target(child: &Child) -> Option<i32> {
    let pid = child.id()? as i32;
    // ACP children lead a private group; other harnesses retain pid signaling.
    // SAFETY: getpgid only inspects the owned, unreaped child.
    Some(if unsafe { libc::getpgid(pid) } == pid {
        -pid
    } else {
        pid
    })
}
#[cfg(windows)]
pub(crate) fn signal_target(child: &Child) -> Option<std::sync::Arc<crate::windows_process::Job>> {
    Some(child.job.clone())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_busy_executable_is_retried_then_reported() {
        let busy = || std::io::Error::from(std::io::ErrorKind::ExecutableFileBusy);
        let mut calls = 0;
        let spawned = retry_busy(|| {
            calls += 1;
            if calls < 3 { Err(busy()) } else { Ok(calls) }
        });
        assert_eq!(spawned.unwrap(), 3);
        let mut calls = 0;
        let error = retry_busy::<()>(|| {
            calls += 1;
            Err(busy())
        })
        .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::ExecutableFileBusy);
        assert_eq!(calls, 6, "five retries, then the error");
        // Other errors are never retried.
        let mut calls = 0;
        let _ = retry_busy::<()>(|| {
            calls += 1;
            Err(std::io::Error::from(std::io::ErrorKind::NotFound))
        });
        assert_eq!(calls, 1);
    }

    #[tokio::test]
    async fn unix_launch_retains_tokio_types_and_output() {
        let mut command: tokio::process::Command = Command::new(std::env::current_exe().unwrap());
        command
            .arg("--list")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .kill_on_drop(true);
        let child: tokio::process::Child = command.spawn().unwrap();
        let result = child.wait_with_output().await.unwrap();
        assert!(result.status.success());
        assert!(
            String::from_utf8_lossy(&result.stdout)
                .contains("unix_launch_retains_tokio_types_and_output")
        );
        let result = command.output().await.unwrap();
        assert!(result.status.success());
        assert!(!result.stdout.is_empty());
    }
}
