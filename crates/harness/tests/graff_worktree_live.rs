//! Live check of the Graff worktree lifecycle against the installed `graff`
//! (run with `--ignored`): `graff acp -w <name>` mints the named tree, and
//! archive/merge/remove are classified from Graff's own output (it exits 0
//! even when it refuses).

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

use harness_adapters::{GraffWorktreeAction, GraffWorktreeOutcome, run_graff_worktree_action};

fn git(cwd: &std::path::Path, args: &[&str]) {
    let out = Command::new("git").args(args).current_dir(cwd).output().unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

/// `graff acp -w <name>` + a session/new: Graff creates the named tree.
fn mint_tree(root: &std::path::Path, name: &str) -> std::path::PathBuf {
    let mut child = Command::new("graff")
        .args(["acp", "-w", name])
        .current_dir(root)
        .env("GRAFF_AUTO_ISOLATE", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("graff on PATH");
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    for (id, method, params) in [
        (1, "initialize", serde_json::json!({"protocolVersion": 1, "clientCapabilities": {}})),
        (2, "session/new", serde_json::json!({"cwd": root, "mcpServers": []})),
    ] {
        writeln!(stdin, "{}", serde_json::json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})).unwrap();
        let mut line = String::new();
        loop {
            line.clear();
            stdout.read_line(&mut line).unwrap();
            let reply: serde_json::Value = serde_json::from_str(&line).unwrap_or_default();
            if reply["id"] == id {
                break;
            }
        }
    }
    let _ = child.kill();
    root.join(".graff/worktrees").join(name)
}

#[tokio::test]
#[ignore = "needs the graff CLI"]
async fn graff_worktree_lifecycle_against_the_real_cli() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    git(&root, &["-c", "user.email=t@e", "-c", "user.name=T", "commit", "-q", "--allow-empty", "-m", "init"]);

    let tree = mint_tree(&root, "harness-live");
    assert!(tree.join(".git").is_file(), "graff minted a linked worktree at {tree:?}");

    std::fs::write(tree.join("hello.txt"), "hi\n").unwrap();
    let dirty = run_graff_worktree_action(&root, "harness-live", GraffWorktreeAction::Merge).await.unwrap();
    assert_eq!(dirty.outcome, GraffWorktreeOutcome::Failed, "{}", dirty.message);

    git(&tree, &["add", "-A"]);
    git(&tree, &["-c", "user.email=t@e", "-c", "user.name=T", "commit", "-q", "-m", "hello"]);
    let archive = run_graff_worktree_action(&root, "harness-live", GraffWorktreeAction::Archive).await.unwrap();
    assert_eq!(archive.outcome, GraffWorktreeOutcome::Kept, "{}", archive.message);

    let merge = run_graff_worktree_action(&root, "harness-live", GraffWorktreeAction::Merge).await.unwrap();
    assert_eq!(merge.outcome, GraffWorktreeOutcome::Done, "{}", merge.message);
    assert!(root.join("hello.txt").is_file(), "the work landed in the main checkout");
    assert!(!tree.exists(), "and the tree is gone");

    let missing = run_graff_worktree_action(&root, "harness-live", GraffWorktreeAction::Remove).await.unwrap();
    assert_ne!(missing.outcome, GraffWorktreeOutcome::Done, "{}", missing.message);
}
