//! Separate engine processes must coordinate through the repository, not just
//! through one process's Repos handles. All repositories/configuration are synthetic.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use harness_engine::Repos;

struct Worker(Child);

impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn git(path: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .current_dir(path)
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap().trim().into()
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

fn spawn_worker(root: &Path, repo: &Path, index: usize, shared_root: bool, mode: &str) -> Worker {
    let worktrees = if shared_root {
        root.join("trees")
    } else {
        root.join(format!("trees-{index}"))
    };
    Worker(
        Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "allocation_worker", "--ignored", "--nocapture"])
            .env("TASK_TEST_REPO", repo)
            .env("TASK_TEST_ROOT", root)
            .env("TASK_TEST_INDEX", index.to_string())
            .env("TASK_TEST_MODE", mode)
            .env("TASK_TEST_TREES", worktrees)
            .env("HARNESS_NO_LOGIN_SHELL", "1")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", root.join("empty-git-config"))
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap(),
    )
}

fn wait_until(mut ready: impl FnMut() -> bool) {
    let start = Instant::now();
    while !ready() {
        assert!(
            start.elapsed() < Duration::from_secs(15),
            "worker deadline exceeded"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn separate_processes_allocate_unique_branches_for_the_same_task() {
    for shared_root in [false, true] {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path();
        let repo = root.join("sample-app");
        init_repo(&repo);
        std::fs::write(root.join("empty-git-config"), "").unwrap();
        let mut workers: Vec<_> = (0..6)
            .map(|i| spawn_worker(root, &repo, i, shared_root, "allocate"))
            .collect();
        wait_until(|| (0..6).all(|i| root.join(format!("ready-{i}")).exists()));
        // Release only once all independent processes are ready to allocate.
        for worker in &mut workers {
            worker.0.stdin.take().unwrap().write_all(b"!").unwrap();
        }
        wait_until(|| {
            workers
                .iter_mut()
                .all(|worker| worker.0.try_wait().unwrap().is_some())
        });
        let statuses: Vec<_> = workers
            .iter_mut()
            .map(|worker| worker.0.wait().unwrap())
            .collect();
        let outcomes: Vec<_> = (0..6)
            .map(|i| std::fs::read_to_string(root.join(format!("result-{i}"))).unwrap())
            .collect();
        assert!(
            statuses.iter().all(|status| status.success()),
            "independent processes must all allocate successfully: {outcomes:?}"
        );
        let trees: Vec<harness_proto::Worktree> = outcomes
            .iter()
            .map(|raw| serde_json::from_str(raw).unwrap())
            .collect();
        let branches: std::collections::HashSet<_> =
            trees.iter().map(|tree| &tree.branch).collect();
        let paths: std::collections::HashSet<_> = trees.iter().map(|tree| &tree.path).collect();
        assert_eq!(branches.len(), workers.len());
        assert_eq!(paths.len(), workers.len());
        for tree in &trees {
            assert!(tree.branch.starts_with("task/fix-login-redirect"));
            assert_eq!(
                git(Path::new(&tree.path), &["branch", "--show-current"]),
                tree.branch
            );
            let record = git(
                &repo,
                &[
                    "config",
                    "--local",
                    "--get",
                    &format!("branch.{}.harness-worktree", tree.branch),
                ],
            );
            let record: serde_json::Value = serde_json::from_str(&record).unwrap();
            assert_eq!(record["branch"], tree.branch);
        }
        assert_eq!(git(&repo, &["branch", "--show-current"]), "main");
    }
}

#[test]
fn a_terminated_process_releases_its_repository_lock() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let repo = root.join("sample-app");
    init_repo(&repo);
    std::fs::write(root.join("empty-git-config"), "").unwrap();
    let lock_path = repo.join(".git/harness-worktree-mutations.lock");
    std::fs::write(&lock_path, b"persistent rendezvous").unwrap();
    let mut holder = spawn_worker(root, &repo, 0, false, "hold");
    wait_until(|| root.join("ready-0").exists());
    let mut allocator = spawn_worker(root, &repo, 1, false, "allocate");
    wait_until(|| root.join("ready-1").exists());
    allocator.0.stdin.take().unwrap().write_all(b"!").unwrap();
    // The holder owns the actual OS lock, not merely a leftover lock filename.
    std::thread::sleep(Duration::from_millis(150));
    let waited_for_holder = allocator.0.try_wait().unwrap().is_none();
    holder.0.kill().unwrap();
    holder.0.wait().unwrap();
    wait_until(|| allocator.0.try_wait().unwrap().is_some());
    let status = allocator.0.wait().unwrap();
    assert!(
        waited_for_holder,
        "a second process bypassed the repository lock"
    );
    assert!(
        status.success(),
        "allocation failed after the lock owner exited"
    );
    assert_eq!(std::fs::read(&lock_path).unwrap(), b"persistent rendezvous");
}

#[tokio::test]
async fn a_cancelled_waiter_does_not_block_retries_or_other_repositories() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path();
    let repo = root.join("sample-app");
    let other = root.join("other-app");
    init_repo(&repo);
    init_repo(&other);
    std::fs::write(root.join("empty-git-config"), "").unwrap();
    let mut holder = spawn_worker(root, &repo, 0, false, "hold");
    wait_until(|| root.join("ready-0").exists());
    let repos = Repos::with_worktrees_root(&root.join("data"), "test", root.join("trees"));
    let cancelled = tokio::time::timeout(
        Duration::from_millis(150),
        repos.create_worktree_for_task(&repo, "main", "Fix login redirect"),
    )
    .await;
    let unrelated = tokio::time::timeout(
        Duration::from_secs(5),
        repos.create_worktree_for_task(&other, "main", "Fix login redirect"),
    )
    .await;
    holder.0.stdin.take().unwrap().write_all(b"!").unwrap();
    wait_until(|| holder.0.try_wait().unwrap().is_some());
    assert!(holder.0.wait().unwrap().success());
    let retry = tokio::time::timeout(
        Duration::from_secs(5),
        repos.create_worktree_for_task(&repo, "main", "Fix login redirect"),
    )
    .await;
    assert!(
        cancelled.is_err(),
        "allocation should wait while the other process owns the lock"
    );
    assert!(
        unrelated.unwrap().is_ok(),
        "unrelated repositories must remain independent"
    );
    let tree = retry.unwrap().unwrap();
    assert_eq!(tree.branch, "task/fix-login-redirect");
    repos
        .delete_worktree(&repo, Path::new(&tree.path))
        .await
        .unwrap();
    assert_eq!(git(&repo, &["branch", "--show-current"]), "main");
}

#[test]
#[ignore = "subprocess fixture invoked by the worktree process lifecycle tests"]
fn allocation_worker() {
    use std::io::Read;
    let root = PathBuf::from(std::env::var_os("TASK_TEST_ROOT").unwrap());
    let repo = PathBuf::from(std::env::var_os("TASK_TEST_REPO").unwrap());
    let index = std::env::var("TASK_TEST_INDEX").unwrap();
    let trees = PathBuf::from(std::env::var_os("TASK_TEST_TREES").unwrap());
    let mode = std::env::var("TASK_TEST_MODE").unwrap();
    let held_lock = (mode == "hold").then(|| {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(repo.join(".git/harness-worktree-mutations.lock"))
            .unwrap();
        file.lock().unwrap();
        file
    });
    std::fs::write(root.join(format!("ready-{index}")), "ready").unwrap();
    std::io::stdin().read_exact(&mut [0]).unwrap();
    if held_lock.is_some() {
        return;
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    let result = runtime.block_on(async {
        let repos = Repos::with_worktrees_root(&root.join(format!("data-{index}")), "test", trees);
        repos
            .create_worktree_for_task(&repo, "main", "Fix login redirect")
            .await
    });
    let output = match &result {
        Ok(tree) => serde_json::to_string(tree).unwrap(),
        Err(error) => format!("{error:?}"),
    };
    std::fs::write(root.join(format!("result-{index}")), output).unwrap();
    assert!(result.is_ok(), "{result:?}");
}
