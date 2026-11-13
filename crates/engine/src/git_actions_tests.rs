use super::*;
use std::path::PathBuf;
use std::process::Command;

async fn isolated(test: impl std::future::Future<Output = ()>) {
    let home = tempfile::tempdir().unwrap();
    TEST_GIT_HOME.scope(home.path().to_path_buf(), test).await;
}

// All Git configuration, hooks, worktrees and remotes belong to this temporary
// fixture. No test reads a developer's home configuration or mutates this checkout.
struct Fixture {
    _temp: tempfile::TempDir,
    root: PathBuf,
    home: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("repo");
        let home = temp.path().join("home");
        std::fs::create_dir(&root).unwrap();
        std::fs::create_dir(&home).unwrap();
        let fixture = Self {
            _temp: temp,
            root,
            home,
        };
        fixture.git(&["init", "-b", "main"]);
        fixture.git(&["config", "user.name", "Synthetic Tester"]);
        fixture.git(&["config", "user.email", "synthetic@example.invalid"]);
        fixture.git(&["config", "commit.gpgsign", "false"]);
        fixture
    }
    fn git(&self, args: &[&str]) -> String {
        let output = Command::new("git")
            .current_dir(&self.root)
            .args(args)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.home)
            .env("GIT_AUTHOR_NAME", "Synthetic Tester")
            .env("GIT_AUTHOR_EMAIL", "synthetic@example.invalid")
            .env("GIT_COMMITTER_NAME", "Synthetic Tester")
            .env("GIT_COMMITTER_EMAIL", "synthetic@example.invalid")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .env_remove("GIT_CONFIG_COUNT")
            .env_remove("GIT_CONFIG_PARAMETERS")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_INDEX_FILE")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "synthetic Git failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }
    fn write(&self, path: &str, content: impl AsRef<[u8]>) {
        std::fs::write(self.root.join(path), content).unwrap();
    }
    fn identity(&self) -> CheckoutIdentity {
        CheckoutIdentity {
            id: "synthetic-checkout".into(),
            root: self.root.clone(),
            git_dir: self.root.join(".git"),
        }
    }
    fn initial_commit(&self) {
        self.write("tracked", "base\n");
        self.git(&["add", "tracked"]);
        self.git(&["commit", "-m", "initial"]);
    }
    #[cfg(unix)]
    async fn state(&self) -> CheckoutGitState {
        stable_capture(&self.identity()).await.unwrap()
    }
    #[cfg(unix)]
    async fn action(&self, action: CheckoutGitAction) -> CheckoutGitState {
        let state = self.state().await;
        apply_in_checkout(&self.identity(), &state.checksum, &action)
            .await
            .unwrap()
    }
}

#[test]
fn git_actions_status_rejects_traversal_and_represents_rename_as_two_paths() {
    assert!(parse_status(b" M ../escape\0").is_err());
    assert!(parse_status(b"?? .git/config\0").is_err());
    assert!(parse_status(b"R  dest\0source\0").is_err());
    let files = parse_status(b"D  old\0?? new\0").unwrap();
    assert_eq!(files.len(), 2);
    assert_eq!(files[0].index_status, "D");
    assert_eq!(files[1].worktree_status, "?");
    assert!(parse_status(b"?? :(glob)*\0").is_ok());
    assert!(
        serde_json::from_str::<CheckoutGitAction>(r#"{"kind":"push","remote":"other"}"#).is_err()
    );
}

#[cfg(unix)]
#[tokio::test]
async fn git_actions_unborn_exact_paths_and_partially_staged_commit() {
    isolated(async {
        let f = Fixture::new();
        f.write(":(glob)*", "literal\n");
        f.write("other", "leave untracked\n");
        let s = f
            .action(CheckoutGitAction::Stage {
                path: ":(glob)*".into(),
            })
            .await;
        assert_eq!(
            s.files
                .iter()
                .find(|f| f.path == "other")
                .unwrap()
                .index_status,
            "?"
        );
        f.write(":(glob)*", "second edit before unborn unstage\n");
        f.action(CheckoutGitAction::Unstage {
            path: ":(glob)*".into(),
        })
        .await;
        f.write(":(glob)*", "literal\n");
        f.action(CheckoutGitAction::Stage {
            path: ":(glob)*".into(),
        })
        .await;
        f.write(":(glob)*", "unstaged second edit\n");
        let s = f
            .action(CheckoutGitAction::Commit {
                message: "subject\n\n  preserved body  \n".into(),
            })
            .await;
        assert!(s.head_sha.is_some());
        assert_eq!(f.git(&["show", "HEAD::(glob)*"]), "literal\n");
        assert_eq!(
            std::fs::read_to_string(f.root.join(":(glob)*")).unwrap(),
            "unstaged second edit\n"
        );
        assert_eq!(
            f.git(&["show", "-s", "--format=%B", "HEAD"]),
            "subject\n\n  preserved body  \n\n"
        );
    })
    .await;
}

#[cfg(unix)]
#[tokio::test]
async fn git_actions_checksum_fences_binary_second_edits_index_head_and_config() {
    isolated(async {
        let f = Fixture::new();
        f.initial_commit();
        f.write("tracked", b"first\0binary");
        let first = f.state().await;
        f.write("tracked", b"other\0binary");
        let second = f.state().await;
        assert_ne!(first.checksum, second.checksum);
        assert!(
            apply_in_checkout(
                &f.identity(),
                &first.checksum,
                &CheckoutGitAction::Stage {
                    path: "tracked".into()
                }
            )
            .await
            .is_err()
        );
        f.git(&["add", "tracked"]);
        let indexed = f.state().await;
        assert_ne!(second.checksum, indexed.checksum);
        f.git(&["config", "remote.synthetic.url", "../remote-one"]);
        let configured = f.state().await;
        assert_ne!(indexed.checksum, configured.checksum);
        f.git(&["commit", "-m", "binary"]);
        assert_ne!(configured.checksum, f.state().await.checksum);
    })
    .await;
}

#[cfg(unix)]
#[tokio::test]
async fn git_actions_rename_is_explicit_and_unstage_preserves_worktree() {
    isolated(async {
        let f = Fixture::new();
        f.initial_commit();
        std::fs::rename(f.root.join("tracked"), f.root.join("renamed")).unwrap();
        let state = f.state().await;
        assert_eq!(state.files.len(), 2);
        f.action(CheckoutGitAction::Stage {
            path: "tracked".into(),
        })
        .await;
        assert_eq!(f.git(&["diff", "--cached", "--name-only"]), "tracked\n");
        f.action(CheckoutGitAction::Unstage {
            path: "tracked".into(),
        })
        .await;
        assert_eq!(f.git(&["diff", "--cached", "--name-only"]), "");
        assert!(f.root.join("renamed").is_file());
        assert!(!f.root.join("tracked").exists());
    })
    .await;
}

#[cfg(unix)]
#[tokio::test]
async fn git_actions_push_only_existing_upstream_to_local_bare_remote() {
    isolated(async {
        let f = Fixture::new();
        f.initial_commit();
        let state = f.state().await;
        assert!(state.upstream.is_none());
        assert!(
            apply_in_checkout(&f.identity(), &state.checksum, &CheckoutGitAction::Push {})
                .await
                .is_err()
        );
        let bare = f._temp.path().join("remote.git");
        f.git(&["init", "--bare", bare.to_str().unwrap()]);
        f.git(&["remote", "add", "fixture", bare.to_str().unwrap()]);
        f.git(&["push", "-u", "fixture", "main:destination"]);
        let state = f.state().await;
        assert_eq!(
            state.upstream,
            Some(CheckoutGitUpstream {
                remote: "fixture".into(),
                branch: "destination".into()
            })
        );
        f.write("tracked", "new\n");
        f.action(CheckoutGitAction::Stage {
            path: "tracked".into(),
        })
        .await;
        f.action(CheckoutGitAction::Commit {
            message: "second".into(),
        })
        .await;
        // Mirror remotes fail closed instead of overriding the user's setting.
        f.git(&["config", "remote.fixture.mirror", "true"]);
        let mirror_state = f.state().await;
        assert!(
            apply_in_checkout(
                &f.identity(),
                &mirror_state.checksum,
                &CheckoutGitAction::Push {}
            )
            .await
            .is_err()
        );
        f.git(&["config", "remote.fixture.mirror", "false"]);
        // Configured follow-tags must not expand this one-ref push.
        f.git(&["config", "push.followTags", "true"]);
        f.git(&["tag", "-a", "fixture-tag", "-m", "synthetic tag"]);
        f.git(&["branch", "unrelated"]);
        f.action(CheckoutGitAction::Push {}).await;
        assert_eq!(
            f.git(&["rev-parse", "HEAD"]),
            f.git(&[
                "--git-dir",
                bare.to_str().unwrap(),
                "rev-parse",
                "refs/heads/destination"
            ])
        );
        assert_eq!(
            f.git(&[
                "--git-dir",
                bare.to_str().unwrap(),
                "for-each-ref",
                "--format=%(refname)"
            ]),
            "refs/heads/destination\n"
        );
        let old = f.state().await;
        f.git(&["config", "branch.main.merge", "refs/heads/other"]);
        assert!(
            apply_in_checkout(&f.identity(), &old.checksum, &CheckoutGitAction::Push {})
                .await
                .is_err()
        );
    })
    .await;
}

#[cfg(unix)]
#[tokio::test]
async fn git_actions_push_pins_confirmed_sha_if_head_advances_after_fence() {
    isolated(async {
        let f = Fixture::new();
        f.initial_commit();
        let bare = f._temp.path().join("remote.git");
        f.git(&["init", "--bare", bare.to_str().unwrap()]);
        f.git(&["remote", "add", "fixture", bare.to_str().unwrap()]);
        f.git(&["push", "-u", "fixture", "main"]);
        f.write("tracked", "confirmed\n");
        f.git(&["add", "tracked"]);
        f.git(&["commit", "-m", "confirmed commit"]);
        let confirmed = f.state().await;
        let confirmed_head = confirmed.head_sha.clone().unwrap();
        // Model an external writer between the final fence and process spawn.
        f.write("tracked", "later external edit\n");
        f.git(&["add", "tracked"]);
        f.git(&["commit", "-m", "not confirmed for publication"]);
        execute_confirmed_action(&f.identity(), confirmed, &CheckoutGitAction::Push {})
            .await
            .unwrap();
        assert_ne!(f.git(&["rev-parse", "HEAD"]).trim(), confirmed_head);
        assert_eq!(
            f.git(&[
                "--git-dir",
                bare.to_str().unwrap(),
                "rev-parse",
                "refs/heads/main"
            ])
            .trim(),
            confirmed_head
        );
    })
    .await;
}

#[cfg(unix)]
#[tokio::test]
async fn git_actions_detached_and_conflicts_block_mutations() {
    isolated(async {
        let f = Fixture::new();
        f.initial_commit();
        f.git(&["checkout", "--detach"]);
        f.write("tracked", "changed\n");
        let state = f.state().await;
        assert!(state.blocked_reason.unwrap().contains("Detached"));
        f.git(&["checkout", "main"]);
        f.git(&["add", "tracked"]);
        f.git(&["commit", "-m", "main change"]);
        f.git(&["checkout", "-b", "other", "HEAD~1"]);
        f.write("tracked", "conflict\n");
        f.git(&["add", "tracked"]);
        f.git(&["commit", "-m", "other change"]);
        // Expected merge conflict; use the bounded runner without requiring success.
        assert!(!git(&f.root, &["merge", "main"]).await.unwrap().0);
        let state = f.state().await;
        assert!(state.blocked_reason.is_some());
        assert!(
            apply_in_checkout(
                &f.identity(),
                &state.checksum,
                &CheckoutGitAction::Commit {
                    message: "not allowed".into()
                }
            )
            .await
            .is_err()
        );
    })
    .await;
}

#[cfg(unix)]
#[tokio::test]
async fn git_actions_symlink_fifo_oversize_and_hook_fail_closed() {
    isolated(async {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let f = Fixture::new();
        f.initial_commit();
        symlink(&f.home, f.root.join("link")).unwrap();
        assert!(stable_capture(&f.identity()).await.is_err());
        std::fs::remove_file(f.root.join("link")).unwrap();
        let fifo = std::ffi::CString::new(f.root.join("pipe").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        assert!(file_bytes(&f.root, "pipe", MAX_FILE).is_err());
        std::fs::remove_file(f.root.join("pipe")).unwrap();
        f.write("large", vec![0; MAX_FILE + 1]);
        assert!(stable_capture(&f.identity()).await.is_err());
        std::fs::remove_file(f.root.join("large")).unwrap();
        let hook = f.root.join(".git/hooks/pre-commit");
        std::fs::write(
            &hook,
            "#!/bin/sh\necho 'secret-fixture-value' >&2\nexit 1\n",
        )
        .unwrap();
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        f.write("tracked", "changed\n");
        f.action(CheckoutGitAction::Stage {
            path: "tracked".into(),
        })
        .await;
        let state = f.state().await;
        let err = apply_in_checkout(
            &f.identity(),
            &state.checksum,
            &CheckoutGitAction::Commit {
                message: "hook failure".into(),
            },
        )
        .await
        .unwrap_err();
        assert!(!err.to_string().contains("secret-fixture-value"));
        assert_eq!(f.git(&["log", "--format=%s"]), "initial\n");
    })
    .await;
}

#[cfg(not(unix))]
#[tokio::test]
async fn git_actions_unsupported_host_refuses_actions_without_mutating_checkout() {
    isolated(async {
        let f = Fixture::new();
        f.initial_commit();
        f.write("tracked", "working changes kept\n");
        let head = f.git(&["rev-parse", "HEAD"]);
        let index = f.git(&["ls-files", "--stage"]);
        for action in [
            CheckoutGitAction::Stage { path: "tracked".into() },
            CheckoutGitAction::Unstage { path: "tracked".into() },
            CheckoutGitAction::Commit { message: "must not commit".into() },
            CheckoutGitAction::Push {},
        ] {
            let error = apply_in_checkout(&f.identity(), "unsupported-host-fence", &action)
                .await
                .unwrap_err();
            assert!(error.to_string().contains(
                "Native Git mutations require safe descriptor-relative filesystem access on this host"
            ));
            assert_eq!(f.git(&["rev-parse", "HEAD"]), head);
            assert_eq!(f.git(&["ls-files", "--stage"]), index);
            assert_eq!(std::fs::read_to_string(f.root.join("tracked")).unwrap(), "working changes kept\n");
        }
    })
    .await;
}

#[tokio::test]
async fn git_actions_checkout_gate_survives_caller_cancellation() {
    isolated(async {
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        let caller = tokio::spawn(async move {
            tokio::spawn(async move {
                let _guard = mutation_guard("gate-cancellation-fixture").await;
                entered_tx.send(()).unwrap();
                let _ = release_rx.await;
            })
            .await
            .unwrap();
        });
        entered_rx.await.unwrap();
        caller.abort();
        let waiter = tokio::spawn(async { mutation_guard("gate-cancellation-fixture").await });
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!waiter.is_finished());
        release_tx.send(()).unwrap();
        drop(waiter.await.unwrap());
    })
    .await;
}
