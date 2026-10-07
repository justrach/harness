//! An idle checkout must not keep re-capturing its diff.
//!
//! Every capture runs git, and git opens files under the watched root and git
//! dir. Linux's inotify backend reports those opens and closes as Access
//! events; when the diff-sync watcher kicked on them, each capture scheduled
//! the next one and an idle checkout re-synced every debounce window forever.
//! A `git` shim on PATH counts the captures the engine runs while nothing in
//! the checkout changes. On macOS (FSEvents reports no opens) this passes
//! either way; it guards the Linux path.
#![cfg(unix)]

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use harness_engine::{EngineCore, HarnessRegistry};

/// One per capture: the untracked-files listing in `capture_diff_against`.
const CAPTURE_MARKER: &str = "--no-optional-locks status --porcelain=v1";

fn git(cwd: &Path, args: &[&str]) {
    let output = std::process::Command::new("git")
        .args(args)
        .current_dir(cwd)
        .env("GIT_AUTHOR_NAME", "test")
        .env("GIT_AUTHOR_EMAIL", "test@test")
        .env("GIT_COMMITTER_NAME", "test")
        .env("GIT_COMMITTER_EMAIL", "test@test")
        .output()
        .expect("git spawns");
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// Put a logging `git` in front of the real one for this whole test process.
fn install_git_shim(dir: &Path) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt as _;

    let real = std::process::Command::new("sh")
        .args(["-c", "command -v git"])
        .output()
        .expect("sh runs");
    let real = String::from_utf8(real.stdout).unwrap().trim().to_string();
    assert!(!real.is_empty(), "git on PATH");
    let bin = dir.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let log = dir.join("git.log");
    std::fs::write(&log, "").unwrap();
    let shim = bin.join("git");
    std::fs::write(
        &shim,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nexec '{}' \"$@\"\n",
            log.display(),
            real
        ),
    )
    .unwrap();
    std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = std::env::var("PATH").unwrap_or_default();
    // SAFETY: the only test in this binary; set before the engine spawns
    // anything that reads PATH.
    unsafe { std::env::set_var("PATH", format!("{}:{path}", bin.display())) };
    log
}

fn captures(log: &Path) -> usize {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter(|line| line.contains(CAPTURE_MARKER))
        .count()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn idle_checkout_does_not_resync_itself() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let tmp_path = tmp.path().canonicalize().unwrap();
    let log = install_git_shim(&tmp_path);

    let repo = tmp_path.join("repo");
    std::fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-b", "main"]);
    std::fs::write(repo.join("src/lib.rs"), "fn one() {}\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-m", "initial"]);
    std::fs::write(repo.join("src/lib.rs"), "fn one() {}\nfn two() {}\n").unwrap();
    std::fs::write(repo.join("src/new.rs"), "fn three() {}\n").unwrap();

    let data = tmp_path.join("data");
    std::fs::create_dir_all(&data).unwrap();
    let core = EngineCore::assemble(
        &data,
        Arc::new(HarnessRegistry::new()),
        harness_proto::HarnessId::Mock,
        None,
    )
    .expect("engine assembles");
    core.workspace
        .create_space(
            "space-1",
            &core.device_id,
            &repo.to_string_lossy(),
            None,
            true,
        )
        .expect("space row");
    core.workspace
        .create_chat("chat-1", Some("space-1"), None, None, None)
        .expect("chat row");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while !core
        .workspace
        .watch_chats()
        .borrow()
        .iter()
        .any(|c| c.id == "chat-1")
    {
        assert!(tokio::time::Instant::now() < deadline, "chat row landed");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    core.diff_sync.reconcile_now().await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(120);
    while core.diff_sync.watch_diffs().borrow().is_empty() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "first diff published"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // Let the startup kicks (initial capture + the one after the watchers
    // attach) drain, then watch the checkout sit idle.
    tokio::time::sleep(Duration::from_secs(3)).await;
    let before = captures(&log);
    tokio::time::sleep(Duration::from_secs(4)).await;
    let during_idle = captures(&log) - before;
    assert_eq!(
        during_idle, 0,
        "an idle checkout re-captured its diff {during_idle} times in 4s \
         ({before} captures before the idle window)"
    );

    // A real edit still refreshes it.
    std::fs::write(repo.join("src/lib.rs"), "fn edited() {}\n").unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    while captures(&log) == before {
        assert!(
            tokio::time::Instant::now() < deadline,
            "an edit never triggered a capture"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    core.shutdown().await;
}
