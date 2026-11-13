//! A child that gets the login shell's PATH must still start with
//! `posix_spawn`, not `fork`.
//!
//! The standard library falls back to `fork` + `exec` when a command sets
//! `PATH` and names its program without a directory (`git`, `gh`): it then
//! has to search the child's PATH itself. In the engine, `fork` copies a
//! process with hundreds of threads and holds every malloc zone's lock while
//! it does, so each `git` the engine ran stalled the whole runtime, and a
//! busy engine spent seconds at a time at several cores in `fork`.
//!
//! `fork` runs the `pthread_atfork` handlers and `posix_spawn` does not, so
//! a handler counts which one happened. This file holds a single test so no
//! other test in the binary forks while it counts.
#![cfg(unix)]

use std::process::Stdio;
use std::sync::atomic::{AtomicUsize, Ordering};

static FORKS: AtomicUsize = AtomicUsize::new(0);

extern "C" fn count_fork() {
    FORKS.fetch_add(1, Ordering::SeqCst);
}

async fn forks_to_run(mut cmd: tokio::process::Command) -> usize {
    cmd.arg("-c")
        .arg("exit 0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let before = FORKS.load(Ordering::SeqCst);
    assert!(cmd.status().await.expect("sh runs").success());
    FORKS.load(Ordering::SeqCst) - before
}

#[tokio::test]
async fn a_login_shell_child_starts_without_fork() {
    // SAFETY: registers a handler that only bumps an atomic counter.
    assert_eq!(
        unsafe { libc::pthread_atfork(Some(count_fork), None, None) },
        0
    );

    // The old shape: a bare program name plus a PATH override forks.
    let mut old = tokio::process::Command::new("sh");
    harness_adapters::compose_login_shell_path(&mut old);
    assert!(
        forks_to_run(old).await >= 1,
        "a bare name with PATH set is expected to fork; if std stopped doing that, this test no longer shows anything"
    );

    // The same child, same PATH, through the helper: no fork.
    let cmd = harness_adapters::login_shell_command("sh");
    assert!(
        std::path::Path::new(cmd.as_std().get_program()).is_absolute(),
        "the program is resolved against the composed PATH"
    );
    assert!(
        cmd.as_std()
            .get_envs()
            .any(|(k, v)| k == "PATH" && v.is_some())
    );
    assert_eq!(
        forks_to_run(cmd).await,
        0,
        "login_shell_command must not fork"
    );
}
