//! Synthetic, non-Harness repositories: naming is task-derived, while cleanup
//! authority comes from local ownership metadata rather than a branch prefix.

use std::path::Path;
use std::process::Command;

use harness_engine::Repos;

fn git(cwd: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn init_repo(path: &Path) {
    std::fs::create_dir_all(path).unwrap();
    git(path, &["init", "-b", "main"]);
    git(
        path,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "--allow-empty",
            "-m",
            "initial",
        ],
    );
}

#[tokio::test]
async fn task_worktrees_are_descriptive_and_do_not_reuse_user_branches() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let task = "Fix login redirect after sign-in";
    let user_branch = "task/fix-login-redirect-after-sign-in";
    git(&repo, &["branch", user_branch]);
    std::fs::write(repo.join("uncommitted.txt"), "leave shared work alone\n").unwrap();

    let first = repos
        .create_worktree_for_task(&repo, "main", task)
        .await
        .unwrap();
    let second = repos
        .create_worktree_for_task(&repo, "main", task)
        .await
        .unwrap();
    assert_eq!(first.branch, "task/fix-login-redirect-after-sign-in-2");
    assert_eq!(second.branch, "task/fix-login-redirect-after-sign-in-3");
    assert_ne!(first.path, second.path);
    assert_eq!(git(&repo, &["branch", "--show-current"]), "main");
    assert_eq!(
        std::fs::read_to_string(repo.join("uncommitted.txt")).unwrap(),
        "leave shared work alone\n"
    );
    assert!(!Path::new(&first.path).join("uncommitted.txt").exists());

    // A user-chosen branch stays theirs, even in an application-created folder.
    let path = Path::new(&first.path);
    git(path, &["switch", user_branch]);
    assert_eq!(
        repos
            .rename_worktree_branch(path, user_branch, "Another task")
            .await
            .unwrap(),
        user_branch
    );
    repos.delete_worktree(&repo, path).await.unwrap();
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&user_branch.to_string())
    );

    // Ownership follows our title rename, so cleanup can still identify our
    // generated branch without treating every task/* branch as disposable.
    let renamed = repos
        .rename_worktree_branch(
            Path::new(&second.path),
            &second.branch,
            "Fix login callback",
        )
        .await
        .unwrap();
    assert_eq!(renamed, "task/fix-login-callback");
    repos
        .delete_worktree(&repo, Path::new(&second.path))
        .await
        .unwrap();
    let branches = repos.branches(&repo).await.unwrap();
    assert!(!branches.contains(&renamed));
    assert!(branches.contains(&user_branch.to_string()));
}

#[tokio::test]
async fn a_task_prefix_alone_does_not_authorize_renaming_or_deletion() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let path = tmp.path().join("fix-login");
    let branch = "task/fix-login";
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-b",
            branch,
            path.to_str().unwrap(),
            "main",
        ],
    );
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    // Even the original-folder naming guard matches, but there is no ownership record.
    assert_eq!(
        repos
            .rename_worktree_branch(&path, branch, "Different task")
            .await
            .unwrap(),
        branch
    );
    repos.delete_worktree(&repo, &path).await.unwrap();
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&branch.to_string())
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_chats_with_the_same_task_each_get_a_checkout() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    // Distinct Repos handles must coordinate too, not just clones of one Arc.
    let handles: Vec<_> = (0..8)
        .map(|index| {
            Repos::with_worktrees_root(
                &tmp.path().join("data"),
                "test",
                tmp.path().join(format!("worktrees-{index}")),
            )
        })
        .collect();
    let results =
        futures::future::join_all(handles.iter().map(|repos| {
            repos.create_worktree_for_task(&repo, "main", "Fix shared login redirect")
        }))
        .await;
    let failures: Vec<_> = results
        .iter()
        .filter_map(|result| result.as_ref().err())
        .collect();
    assert!(
        failures.is_empty(),
        "parallel allocation must retry/serialize collisions: {failures:?}"
    );
    let trees: Vec<_> = results.into_iter().map(Result::unwrap).collect();
    let branches: std::collections::HashSet<_> = trees.iter().map(|tree| &tree.branch).collect();
    let paths: std::collections::HashSet<_> = trees.iter().map(|tree| &tree.path).collect();
    assert_eq!(branches.len(), 8);
    assert_eq!(paths.len(), 8);
    assert!(
        branches
            .iter()
            .all(|branch| branch.starts_with("task/fix-shared-login-redirect"))
    );
    assert_eq!(git(&repo, &["branch", "--show-current"]), "main");
    for tree in trees {
        repos
            .delete_worktree(&repo, Path::new(&tree.path))
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn externally_renamed_branch_is_not_deleted_as_an_automatic_branch() {
    for chosen in [
        "feature/user-chosen-login",
        "task/user-chosen-login",
        "harness/user-chosen-login",
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("sample-app");
        init_repo(&repo);
        let repos = Repos::with_worktrees_root(
            &tmp.path().join("data"),
            "test",
            tmp.path().join("worktrees"),
        );
        let tree = repos
            .create_worktree_for_task(&repo, "main", "Fix login")
            .await
            .unwrap();
        let path = Path::new(&tree.path);
        git(path, &["branch", "-m", chosen]);
        assert_eq!(
            repos
                .rename_worktree_branch(path, &tree.branch, "Another task")
                .await
                .unwrap(),
            chosen
        );
        repos.delete_worktree(&repo, path).await.unwrap();
        assert!(
            repos
                .branches(&repo)
                .await
                .unwrap()
                .contains(&chosen.to_string()),
            "an external rename must relinquish automatic branch ownership: {chosen}"
        );
    }
}

#[tokio::test]
async fn copied_ownership_record_cannot_claim_another_worktree() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    let marker = git(
        &repo,
        &[
            "config",
            "--local",
            "--get",
            &format!("branch.{}.harness-worktree", tree.branch),
        ],
    );
    let other = tmp.path().join("fix-profile");
    let user_branch = "task/fix-profile";
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-b",
            user_branch,
            other.to_str().unwrap(),
            "main",
        ],
    );
    git(
        &repo,
        &[
            "config",
            "--local",
            &format!("branch.{user_branch}.harness-worktree"),
            &marker,
        ],
    );
    assert_eq!(
        repos
            .rename_worktree_branch(&other, user_branch, "Another task")
            .await
            .unwrap(),
        user_branch
    );
    repos.delete_worktree(&repo, &other).await.unwrap();
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&user_branch.to_string())
    );
}

#[tokio::test]
async fn a_directory_collision_keeps_existing_bytes_and_uses_a_suffix() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let root = tmp.path().join("worktrees");
    let occupied = root.join("sample-app/fix-login");
    std::fs::create_dir_all(&occupied).unwrap();
    std::fs::write(occupied.join("keep.txt"), b"not a worktree\n").unwrap();
    let repos = Repos::with_worktrees_root(&tmp.path().join("data"), "test", root);
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    assert_eq!(tree.branch, "task/fix-login-2");
    assert_eq!(
        std::fs::read(occupied.join("keep.txt")).unwrap(),
        b"not a worktree\n"
    );
    assert!(!occupied.join(".git").exists());
}

#[tokio::test]
async fn a_locked_worktree_refuses_cleanup_without_discarding_its_branch_or_files() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    let path = Path::new(&tree.path);
    std::fs::write(path.join("keep.txt"), b"worktree intentionally locked\n").unwrap();
    git(
        &repo,
        &[
            "worktree",
            "lock",
            "--reason",
            "synthetic active task",
            &tree.path,
        ],
    );
    let result = repos.delete_worktree(&repo, path).await;
    assert!(
        result.is_err(),
        "a lock must not be bypassed with extra force or recursive removal"
    );
    assert_eq!(
        std::fs::read(path.join("keep.txt")).unwrap(),
        b"worktree intentionally locked\n"
    );
    assert!(repos.branches(&repo).await.unwrap().contains(&tree.branch));
    git(&repo, &["worktree", "unlock", &tree.path]);
    // The failed removal must release both locks so an explicit later retry works.
    repos.delete_worktree(&repo, path).await.unwrap();
    assert!(!repos.branches(&repo).await.unwrap().contains(&tree.branch));
}

#[cfg(unix)]
#[tokio::test]
async fn a_failing_checkout_hook_preserves_the_files_it_already_wrote() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let hooks = tmp.path().join("hooks");
    std::fs::create_dir(&hooks).unwrap();
    let hook = hooks.join("post-checkout");
    std::fs::write(
        &hook,
        "#!/bin/sh\nprintf 'hook-created work\\n' > keep.txt\nexit 1\n",
    )
    .unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    git(
        &repo,
        &[
            "config",
            "--local",
            "core.hooksPath",
            hooks.to_str().unwrap(),
        ],
    );
    let root = tmp.path().join("worktrees");
    let repos = Repos::with_worktrees_root(&tmp.path().join("data"), "test", root.clone());
    let result = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await;
    assert!(result.is_err());
    let partial = root.join("sample-app/fix-login");
    assert_eq!(
        std::fs::read(partial.join("keep.txt")).unwrap(),
        b"hook-created work\n"
    );
    assert!(partial.join(".git").is_file());
    assert_eq!(
        git(&partial, &["branch", "--show-current"]),
        "task/fix-login"
    );
    // Once the hook is repaired, retry must not reuse or erase the partial checkout.
    std::fs::remove_file(&hook).unwrap();
    let retry = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    assert_eq!(retry.branch, "task/fix-login-2");
    repos.delete_worktree(&repo, &partial).await.unwrap();
    // Failed creation never recorded ownership; cleanup cannot claim this branch.
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&"task/fix-login".to_string())
    );
}

#[tokio::test]
async fn an_invalid_base_does_not_leave_a_branch_or_checkout() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let root = tmp.path().join("worktrees");
    let repos = Repos::with_worktrees_root(&tmp.path().join("data"), "test", root.clone());
    assert!(
        repos
            .create_worktree_for_task(&repo, "missing-base", "Fix login")
            .await
            .is_err()
    );
    assert!(!root.join("sample-app/fix-login").exists());
    assert_eq!(repos.branches(&repo).await.unwrap(), ["main"]);
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    assert_eq!(tree.branch, "task/fix-login");
}

#[tokio::test(flavor = "multi_thread")]
async fn concurrent_repositories_with_the_same_basename_cannot_share_a_folder() {
    let tmp = tempfile::tempdir().unwrap();
    let left = tmp.path().join("left/sample-app");
    let right = tmp.path().join("right/sample-app");
    init_repo(&left);
    init_repo(&right);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let (left_tree, right_tree) = tokio::join!(
        repos.create_worktree_for_task(&left, "main", "Fix login"),
        repos.create_worktree_for_task(&right, "main", "Fix login"),
    );
    let left_tree = left_tree.unwrap();
    let right_tree = right_tree.unwrap();
    assert_ne!(left_tree.path, right_tree.path);
    for (repo, tree) in [(&left, left_tree), (&right, right_tree)] {
        let actual = git(Path::new(&tree.path), &["rev-parse", "--git-common-dir"]);
        assert_eq!(
            std::fs::canonicalize(actual).unwrap(),
            repo.join(".git").canonicalize().unwrap()
        );
        assert_eq!(git(repo, &["branch", "--show-current"]), "main");
    }
}

#[tokio::test]
async fn missing_or_corrupt_ownership_records_preserve_the_branch() {
    for marker in [
        None,
        Some("not-json"),
        Some("{}"),
        Some("{\"git_dir\":false,\"branch\":\"task/fix-login\"}"),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("sample-app");
        init_repo(&repo);
        let repos = Repos::with_worktrees_root(
            &tmp.path().join("data"),
            "test",
            tmp.path().join("worktrees"),
        );
        let tree = repos
            .create_worktree_for_task(&repo, "main", "Fix login")
            .await
            .unwrap();
        let key = format!("branch.{}.harness-worktree", tree.branch);
        match marker {
            Some(marker) => {
                git(&repo, &["config", "--local", &key, marker]);
            }
            None => {
                git(&repo, &["config", "--local", "--unset", &key]);
            }
        }
        let path = Path::new(&tree.path);
        assert_eq!(
            repos
                .rename_worktree_branch(path, &tree.branch, "Different title")
                .await
                .unwrap(),
            tree.branch
        );
        repos.delete_worktree(&repo, path).await.unwrap();
        assert!(repos.branches(&repo).await.unwrap().contains(&tree.branch));
    }
}

#[tokio::test]
async fn ownership_survives_a_new_manager_but_not_an_external_rename_back_to_task_namespace() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let root = tmp.path().join("worktrees");
    let repos = Repos::with_worktrees_root(&tmp.path().join("data"), "old-device", root.clone());
    let managed = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    let renamed = repos
        .create_worktree_for_task(&repo, "main", "Fix profile")
        .await
        .unwrap();
    git(
        Path::new(&renamed.path),
        &["branch", "-m", "task/user-selected-profile"],
    );
    drop(repos);
    let repos = Repos::with_worktrees_root(&tmp.path().join("data"), "new-device", root);
    repos
        .delete_worktree(&repo, Path::new(&managed.path))
        .await
        .unwrap();
    repos
        .delete_worktree(&repo, Path::new(&renamed.path))
        .await
        .unwrap();
    let branches = repos.branches(&repo).await.unwrap();
    assert!(!branches.contains(&managed.branch));
    assert!(branches.contains(&"task/user-selected-profile".to_string()));
}

#[cfg(unix)]
#[tokio::test]
async fn a_prepare_script_rename_is_returned_as_the_actual_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    std::fs::create_dir(repo.join(".agents")).unwrap();
    std::fs::write(
        repo.join(".agents/prepare"),
        "#!/bin/sh\ngit branch -m feature/setup-selected\n",
    )
    .unwrap();
    git(&repo, &["add", ".agents/prepare"]);
    git(
        &repo,
        &[
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.com",
            "commit",
            "-m",
            "synthetic setup",
        ],
    );
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    let actual = git(Path::new(&tree.path), &["branch", "--show-current"]);
    repos
        .delete_worktree(&repo, Path::new(&tree.path))
        .await
        .unwrap();
    assert_eq!(actual, "feature/setup-selected");
    assert_eq!(
        tree.branch, actual,
        "setup changes must be reflected in returned metadata"
    );
    assert!(repos.branches(&repo).await.unwrap().contains(&actual));
}

#[tokio::test]
async fn legacy_original_branches_can_be_titled_and_acquire_precise_ownership() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let path = tmp.path().join("legacy-checkout");
    let old_branch = "harness/legacy-checkout";
    git(
        &repo,
        &[
            "worktree",
            "add",
            "-b",
            old_branch,
            path.to_str().unwrap(),
            "main",
        ],
    );
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let old_head = git(&path, &["rev-parse", "HEAD"]);
    let branch = repos
        .rename_worktree_branch(&path, old_branch, "Fix login")
        .await
        .unwrap();
    assert_eq!(branch, "task/fix-login");
    assert_eq!(git(&path, &["rev-parse", "HEAD"]), old_head);
    let owner = git(
        &repo,
        &[
            "config",
            "--local",
            "--get",
            "branch.task/fix-login.harness-worktree",
        ],
    );
    let owner: serde_json::Value = serde_json::from_str(&owner).unwrap();
    assert_eq!(owner["branch"], branch);
    assert!(owner["git_dir"].as_str().is_some());
    repos.delete_worktree(&repo, &path).await.unwrap();
    assert!(!repos.branches(&repo).await.unwrap().contains(&branch));
    assert_eq!(git(&repo, &["branch", "--show-current"]), "main");
}

#[tokio::test]
async fn cleanup_refuses_primary_checkouts_and_unregistered_directories() {
    for primary in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let repo = tmp.path().join("sample-app");
        init_repo(&repo);
        let plain = tmp.path().join("ordinary-folder");
        std::fs::create_dir(&plain).unwrap();
        let target = if primary { &repo } else { &plain };
        std::fs::write(target.join("keep.txt"), b"never delete these bytes\n").unwrap();
        let repos = Repos::with_worktrees_root(
            &tmp.path().join("data"),
            "test",
            tmp.path().join("worktrees"),
        );
        let result = repos.delete_worktree(&repo, target).await;
        assert!(
            result.is_err(),
            "Git's refusal must not become a recursive directory deletion"
        );
        assert_eq!(
            std::fs::read(target.join("keep.txt")).unwrap(),
            b"never delete these bytes\n"
        );
        assert!(repo.join(".git").is_dir());
    }
}

#[tokio::test]
async fn cleanup_cannot_remove_a_foreign_worktree_or_its_namesake_branch() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    let foreign = tmp.path().join("other-app");
    init_repo(&repo);
    init_repo(&foreign);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let tree = repos
        .create_worktree_for_task(&foreign, "main", "Fix login")
        .await
        .unwrap();
    git(&repo, &["branch", &tree.branch]);
    let path = Path::new(&tree.path);
    std::fs::write(path.join("keep.txt"), b"foreign work\n").unwrap();
    let result = repos.delete_worktree(&repo, path).await;
    assert!(result.is_err());
    assert_eq!(
        std::fs::read(path.join("keep.txt")).unwrap(),
        b"foreign work\n"
    );
    assert!(repos.branches(&repo).await.unwrap().contains(&tree.branch));
    assert!(
        repos
            .branches(&foreign)
            .await
            .unwrap()
            .contains(&tree.branch)
    );
}

#[tokio::test]
async fn case_only_ref_collisions_preserve_user_refs_during_creation_and_titling() {
    let tmp = tempfile::tempdir().unwrap();
    let repo = tmp.path().join("sample-app");
    init_repo(&repo);
    let user_branch = "TASK/FIX-LOGIN";
    git(&repo, &["branch", user_branch]);
    let original = git(&repo, &["rev-parse", user_branch]);
    let repos = Repos::with_worktrees_root(
        &tmp.path().join("data"),
        "test",
        tmp.path().join("worktrees"),
    );
    let tree = repos
        .create_worktree_for_task(&repo, "main", "Fix login")
        .await
        .unwrap();
    assert_eq!(
        tree.branch, "task/fix-login-2",
        "case-only ref collisions need portable names too"
    );
    let renamed = repos
        .rename_worktree_branch(Path::new(&tree.path), &tree.branch, "Fix login")
        .await
        .unwrap();
    assert!(renamed.starts_with("task/fix-login-"));
    assert_eq!(renamed.len(), "task/fix-login-".len() + 6);
    assert_eq!(git(&repo, &["rev-parse", user_branch]), original);
    assert!(
        repos
            .branches(&repo)
            .await
            .unwrap()
            .contains(&user_branch.to_string())
    );
}
