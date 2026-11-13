//! Bounded, host-owned Git mutations. Status deliberately disables rename detection:
//! a rename is an exact-path deletion plus addition, never a hidden second path.
use std::collections::HashMap;
use std::path::{Component, Path};
use std::process::Stdio;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

use harness_rpc::{
    ApplyCheckoutGitActionParams, CheckoutGitAction, CheckoutGitFile, CheckoutGitState,
    CheckoutGitUpstream, RpcError,
};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt};

use crate::{CheckoutIdentity, Repos, SessionsEngine, WorkspaceHost};

const MAX_OUTPUT: usize = 4 * 1024 * 1024;
const MAX_FILE: usize = 8 * 1024 * 1024;
const MAX_TOTAL: usize = 32 * 1024 * 1024;
const MAX_FILES: usize = 1000;
const MAX_MESSAGE: usize = 64 * 1024;

type Result<T> = std::result::Result<T, RpcError>;
fn fail(message: &'static str) -> RpcError {
    RpcError::Failed(message.into())
}

/// Also used around the discard RPC, so cancellation cannot release a checkout
/// while the discard service's independently owned task is still mutating it.
pub(crate) async fn mutation_guard(checkout_id: &str) -> tokio::sync::OwnedMutexGuard<()> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>>> = OnceLock::new();
    let gate = {
        let mut locks = LOCKS
            .get_or_init(Mutex::default)
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        locks.retain(|_, gate| gate.strong_count() > 0);
        if let Some(gate) = locks.get(checkout_id).and_then(Weak::upgrade) {
            gate
        } else {
            let gate = Arc::new(tokio::sync::Mutex::new(()));
            locks.insert(checkout_id.to_owned(), Arc::downgrade(&gate));
            gate
        }
    };
    gate.lock_owned().await
}

async fn read_bounded(reader: impl AsyncRead + Unpin) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .take((MAX_OUTPUT + 1) as u64)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| fail("Git output could not be read"))?;
    if bytes.len() > MAX_OUTPUT {
        return Err(fail("Git state exceeds the native workflow limit"));
    }
    Ok(bytes)
}

/// Never return stderr: hooks, credentials and transport errors can contain secrets.
async fn git(root: &Path, args: &[&str]) -> Result<(bool, Vec<u8>)> {
    let mut command = tokio::process::Command::new("git");
    command
        .current_dir(root)
        .arg("--literal-pathspecs")
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GCM_INTERACTIVE", "never")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // A host engine must not accidentally inherit a terminal's alternate index,
    // object store, injected config, repository, or pathspec interpretation.
    for key in [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_INDEX_FILE",
        "GIT_COMMON_DIR",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_PARAMETERS",
        "GIT_NAMESPACE",
        "GIT_GLOB_PATHSPECS",
        "GIT_NOGLOB_PATHSPECS",
        "GIT_ICASE_PATHSPECS",
        "GIT_LITERAL_PATHSPECS",
    ] {
        command.env_remove(key);
    }
    #[cfg(test)]
    {
        let home = TEST_GIT_HOME
            .try_with(Clone::clone)
            .map_err(|_| fail("Synthetic Git environment is required"))?;
        command
            .env("HOME", &home)
            .env("XDG_CONFIG_HOME", &home)
            .env("GIT_AUTHOR_NAME", "Synthetic Tester")
            .env("GIT_AUTHOR_EMAIL", "synthetic@example.invalid")
            .env("GIT_COMMITTER_NAME", "Synthetic Tester")
            .env("GIT_COMMITTER_EMAIL", "synthetic@example.invalid")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null");
    }
    #[cfg(unix)]
    command.process_group(0);
    let mut child = command
        .spawn()
        .map_err(|_| fail("Git could not be started"))?;
    #[cfg(unix)]
    let mut group = GitProcessGroup(child.id().map(|id| id as i32));
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let duration = if args.first() == Some(&"push") {
        120
    } else {
        30
    };
    let result = tokio::time::timeout(Duration::from_secs(duration), async {
        let (status, out, err) = tokio::try_join!(
            async { child.wait().await.map_err(|_| fail("Git process failed")) },
            read_bounded(stdout),
            read_bounded(stderr)
        )?;
        drop(err);
        Ok((status.success(), out))
    })
    .await
    .map_err(|_| fail("Git timed out; refresh state before retrying"))?;
    // Keep descendant hooks/transports bounded too, including cancellation of
    // read-only captures. Successful Git retains its normal user-defined hooks.
    #[cfg(unix)]
    if result.is_ok() {
        group.0 = None;
    }
    result
}

#[cfg(unix)]
struct GitProcessGroup(Option<i32>);
#[cfg(unix)]
impl Drop for GitProcessGroup {
    fn drop(&mut self) {
        if let Some(pid) = self.0 {
            // The child was placed in its own process group before exec.
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
    }
}

async fn required(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let (ok, out) = git(root, args).await?;
    if !ok {
        return Err(fail(
            "Git state is unavailable; inspect this checkout in a terminal",
        ));
    }
    Ok(out)
}
fn text(bytes: &[u8]) -> Result<&str> {
    std::str::from_utf8(bytes).map_err(|_| fail("Git state contains unsupported non-UTF-8 paths"))
}
fn one_line(bytes: &[u8]) -> Result<String> {
    let value = text(bytes)?.strip_suffix('\n').unwrap_or(text(bytes)?);
    if value.is_empty() || value.contains(['\n', '\r', '\0']) {
        return Err(fail("Git returned an ambiguous reference"));
    }
    Ok(value.to_owned())
}
fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 4096
        && !path.contains(['\0', '\\'])
        && Path::new(path).components().all(|c| {
            matches!(c, Component::Normal(s)
            if !s.to_string_lossy().eq_ignore_ascii_case(".git"))
        })
        && !path
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
}
fn parse_status(raw: &[u8]) -> Result<Vec<CheckoutGitFile>> {
    let mut files = Vec::new();
    for record in raw.split(|b| *b == 0).filter(|r| !r.is_empty()) {
        if record.len() < 4 || record[2] != b' ' || !record[..2].iter().all(u8::is_ascii) {
            return Err(fail("Git returned unsupported status"));
        }
        let path = text(&record[3..])?;
        if !valid_path(path) || record[..2].iter().any(|s| matches!(s, b'R' | b'C')) {
            return Err(fail("Git returned an unsupported path"));
        }
        files.push(CheckoutGitFile {
            path: path.into(),
            index_status: (record[0] as char).to_string(),
            worktree_status: (record[1] as char).to_string(),
        });
        if files.len() > MAX_FILES {
            return Err(fail("Too many changed files for the native Git workflow"));
        }
    }
    Ok(files)
}
fn hash_part(hasher: &mut Sha256, bytes: &[u8]) {
    hasher.update((bytes.len() as u64).to_le_bytes());
    hasher.update(bytes);
}

/// Descriptor-relative no-follow opens prevent an ancestor swap from following a
/// symlink outside the checkout. Special files and symlinks fail closed before read.
#[cfg(unix)]
fn file_bytes(root: &Path, relative: &str, limit: usize) -> Result<Option<Vec<u8>>> {
    use std::ffi::CString;
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::fs::MetadataExt;
    let mut dir = std::fs::File::open(root).map_err(|_| fail("Checkout is unavailable"))?;
    let parts: Vec<_> = relative.split('/').collect();
    for (i, part) in parts.iter().enumerate() {
        let part = CString::new(*part).map_err(|_| fail("Unsupported Git path"))?;
        let leaf = i + 1 == parts.len();
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | libc::O_NONBLOCK
            | if leaf { 0 } else { libc::O_DIRECTORY };
        let fd = unsafe { libc::openat(dir.as_raw_fd(), part.as_ptr(), flags) };
        if fd < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound {
                return Ok(None);
            }
            return Err(fail(
                "Symlink or unreadable path blocks the native Git workflow",
            ));
        }
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        if !leaf {
            dir = file;
            continue;
        }
        let before = file
            .metadata()
            .map_err(|_| fail("File metadata unavailable"))?;
        if !before.is_file() || before.len() > limit as u64 {
            return Err(fail("Large or special file blocks the native Git workflow"));
        }
        let mut bytes = Vec::new();
        let mut reader = file.take((limit + 1) as u64);
        reader
            .read_to_end(&mut bytes)
            .map_err(|_| fail("File could not be read"))?;
        let after = reader
            .get_ref()
            .metadata()
            .map_err(|_| fail("File metadata unavailable"))?;
        if bytes.len() > limit
            || before.len() != after.len()
            || before.mtime() != after.mtime()
            || before.mtime_nsec() != after.mtime_nsec()
            || before.mode() != after.mode()
        {
            return Err(fail("Checkout changed while reading; refresh and retry"));
        }
        // Executable-bit changes are part of the worktree snapshot too.
        let mut result = (before.mode() & 0o777).to_le_bytes().to_vec();
        result.extend_from_slice(&bytes);
        return Ok(Some(result));
    }
    Err(fail("Unsupported Git path"))
}
#[cfg(not(unix))]
fn file_bytes(_root: &Path, _relative: &str, _limit: usize) -> Result<Option<Vec<u8>>> {
    Err(fail(
        "Native Git mutations require safe descriptor-relative filesystem access on this host",
    ))
}

async fn upstream(root: &Path, branch: Option<&str>) -> Result<Option<CheckoutGitUpstream>> {
    let Some(branch) = branch else {
        return Ok(None);
    };
    let (remote_ok, remote) = git(
        root,
        &["config", "--get-all", &format!("branch.{branch}.remote")],
    )
    .await?;
    let (merge_ok, merge) = git(
        root,
        &["config", "--get-all", &format!("branch.{branch}.merge")],
    )
    .await?;
    if !remote_ok || !merge_ok {
        return Ok(None);
    }
    let remote = match one_line(&remote) {
        Ok(s) => s,
        Err(_) => return Ok(None),
    };
    let merge = match one_line(&merge) {
        Ok(s) => s,
        Err(_) => return Ok(None),
    };
    if remote.starts_with('-')
        || remote == "."
        || !remote
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    {
        return Ok(None);
    }
    let Some(branch) = merge.strip_prefix("refs/heads/") else {
        return Ok(None);
    };
    if !git(root, &["check-ref-format", &merge]).await?.0 {
        return Ok(None);
    }
    // Exactly one existing push URL. Do not accept multi-destination pushes.
    let (ok, urls) = git(root, &["remote", "get-url", "--push", "--all", &remote]).await?;
    if !ok || one_line(&urls).is_err() {
        return Ok(None);
    }
    Ok(Some(CheckoutGitUpstream {
        remote,
        branch: branch.into(),
    }))
}

async fn capture(identity: &CheckoutIdentity) -> Result<CheckoutGitState> {
    let root = &identity.root;
    let raw = required(
        root,
        &[
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
            "--no-renames",
            "--ignore-submodules=none",
        ],
    )
    .await?;
    let files = parse_status(&raw)?;
    let (has_head, head) = git(root, &["rev-parse", "--verify", "HEAD"]).await?;
    let head_sha = if has_head {
        Some(one_line(&head)?)
    } else {
        None
    };
    let (attached, branch) = git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"]).await?;
    let branch = if attached {
        Some(one_line(&branch)?)
    } else {
        None
    };
    if head_sha.is_none() && branch.is_none() {
        return Err(fail("Git HEAD is invalid"));
    }
    let index = required(root, &["ls-files", "--stage", "-z"]).await?;
    let config = required(root, &["config", "--null", "--list", "--includes"]).await?;
    let upstream = upstream(root, branch.as_deref()).await?;
    let mut hasher = Sha256::new();
    for bytes in [
        identity.id.as_bytes(),
        raw.as_slice(),
        head.as_slice(),
        branch.as_deref().unwrap_or("").as_bytes(),
        index.as_slice(),
        config.as_slice(),
    ] {
        hash_part(&mut hasher, bytes);
    }
    let mut total = 0;
    // Raw index includes flags, extensions and split-index linkage, while ls-files
    // covers the actual staged blobs even when split-index is enabled.
    let root_owned = root.clone();
    let git_dir = identity.git_dir.clone();
    let paths: Vec<_> = files.iter().map(|f| f.path.clone()).collect();
    let content_hash = tokio::task::spawn_blocking(move || -> Result<Vec<Vec<u8>>> {
        let mut contents = Vec::new();
        for path in paths {
            let bytes = file_bytes(&root_owned, &path, MAX_FILE)?;
            let mut tagged = vec![u8::from(bytes.is_some())];
            if let Some(bytes) = bytes {
                tagged.extend_from_slice(&bytes);
            }
            total += tagged.len();
            if total > MAX_TOTAL {
                return Err(fail(
                    "Changed content exceeds the native Git workflow limit",
                ));
            }
            contents.push(tagged);
        }
        contents.push(file_bytes(&git_dir, "index", MAX_OUTPUT)?.unwrap_or_default());
        Ok(contents)
    })
    .await
    .map_err(|_| fail("Git snapshot task failed"))??;
    for bytes in content_hash {
        hash_part(&mut hasher, &bytes);
    }
    let conflicts = files.iter().any(|f| {
        f.index_status == "U"
            || f.worktree_status == "U"
            || matches!(
                (f.index_status.as_str(), f.worktree_status.as_str()),
                ("A", "A") | ("D", "D")
            )
    });
    let mut blocked_reason = if conflicts {
        Some("Resolve merge conflicts in a terminal first".into())
    } else if branch.is_none() {
        Some("Detached HEAD: switch to a branch in a terminal first".into())
    } else {
        None
    };
    for marker in [
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "rebase-merge",
        "rebase-apply",
        "sequencer",
        "BISECT_LOG",
    ] {
        let present = identity.git_dir.join(marker).symlink_metadata().is_ok();
        hash_part(&mut hasher, &[u8::from(present)]);
        if present {
            blocked_reason =
                Some("Finish the in-progress Git operation in a terminal first".into());
        }
    }
    Ok(CheckoutGitState {
        checkout_id: identity.id.clone(),
        checksum: format!("{:x}", hasher.finalize()),
        branch,
        head_sha,
        files,
        upstream,
        blocked_reason,
    })
}

/// A second full capture detects concurrent edits during the multi-command read.
async fn stable_capture(identity: &CheckoutIdentity) -> Result<CheckoutGitState> {
    let first = capture(identity).await?;
    let second = capture(identity).await?;
    if first != second {
        return Err(fail("Checkout changed while reading; refresh and retry"));
    }
    Ok(second)
}

async fn resolve(
    workspace: &WorkspaceHost,
    repos: &Repos,
    device: &str,
    chat_id: &str,
) -> Result<CheckoutIdentity> {
    let chat = workspace
        .chat(chat_id)
        .map_err(|_| fail("Chat is unavailable"))?
        .ok_or_else(|| fail("Chat not found"))?;
    if chat.device_id != device {
        return Err(fail("Chat is not hosted by this device"));
    }
    let cwd = chat.cwd.ok_or_else(|| fail("Chat has no checkout"))?;
    repos
        .checkout_identity(Path::new(&cwd))
        .await
        .map_err(|_| fail("Chat checkout is unavailable"))
}
async fn agent_active(
    workspace: &WorkspaceHost,
    repos: &Repos,
    sessions: &SessionsEngine,
    device: &str,
    identity: &CheckoutIdentity,
) -> bool {
    let chats = workspace.watch_chats().borrow().clone();
    for chat in chats {
        if chat.device_id != device
            || !sessions.session_status(&chat.id).is_some_and(|s| {
                matches!(
                    s.status,
                    harness_proto::SessionStatus::Working
                        | harness_proto::SessionStatus::AwaitingInput
                )
            })
        {
            continue;
        }
        if chat.checkout_id.as_deref() == Some(&identity.id) {
            return true;
        }
        if let Some(cwd) = chat.cwd {
            match repos.checkout_identity(Path::new(&cwd)).await {
                Ok(candidate) if candidate.id == identity.id => return true,
                // Fail closed when an active local chat's checkout cannot be resolved.
                Err(_) => return true,
                _ => {}
            }
        }
    }
    false
}

pub async fn get_state(
    workspace: &WorkspaceHost,
    repos: &Repos,
    sessions: &SessionsEngine,
    device: &str,
    chat_id: &str,
) -> Result<CheckoutGitState> {
    let identity = resolve(workspace, repos, device, chat_id).await?;
    let mut state = stable_capture(&identity).await?;
    if agent_active(workspace, repos, sessions, device, &identity).await {
        state.blocked_reason = Some("An agent is active in this working tree".into());
    }
    Ok(state)
}

pub async fn apply(
    workspace: WorkspaceHost,
    repos: Repos,
    sessions: SessionsEngine,
    device: String,
    params: ApplyCheckoutGitActionParams,
) -> Result<CheckoutGitState> {
    // Own the entire operation (including the gate), not just the subprocess.
    tokio::spawn(async move {
        let _guard = mutation_guard(&params.checkout_id).await;
        let identity = resolve(&workspace, &repos, &device, &params.chat_id).await?;
        if identity.id != params.checkout_id {
            return Err(fail("Chat checkout changed; refresh and retry"));
        }
        if agent_active(&workspace, &repos, &sessions, &device, &identity).await {
            return Err(fail("An agent is active in this working tree"));
        }
        let state = confirmed_state(&identity, &params.expected_checksum).await?;
        // Capturing can take time. Recheck both chat ownership and active local
        // runs immediately before handing control to the mutating subprocess.
        let current = resolve(&workspace, &repos, &device, &params.chat_id).await?;
        if current.id != identity.id || current.root != identity.root {
            return Err(fail("Chat checkout changed; refresh and retry"));
        }
        if agent_active(&workspace, &repos, &sessions, &device, &identity).await {
            return Err(fail("An agent is active in this working tree"));
        }
        execute_confirmed_action(&identity, state, &params.action).await
    })
    .await
    .map_err(|_| fail("Git mutation task failed; refresh state before retrying"))?
}

async fn confirmed_state(identity: &CheckoutIdentity, checksum: &str) -> Result<CheckoutGitState> {
    let state = stable_capture(identity).await?;
    if state.checksum != checksum {
        return Err(fail("Checkout changed; refresh and retry"));
    }
    if let Some(reason) = &state.blocked_reason {
        return Err(RpcError::Failed(reason.clone()));
    }
    Ok(state)
}

#[cfg(test)]
async fn apply_in_checkout(
    identity: &CheckoutIdentity,
    checksum: &str,
    action: &CheckoutGitAction,
) -> Result<CheckoutGitState> {
    let state = confirmed_state(identity, checksum).await?;
    execute_confirmed_action(identity, state, action).await
}

async fn execute_confirmed_action(
    identity: &CheckoutIdentity,
    state: CheckoutGitState,
    action: &CheckoutGitAction,
) -> Result<CheckoutGitState> {
    let root = &identity.root;
    let success = match action {
        CheckoutGitAction::Stage { path } | CheckoutGitAction::Unstage { path } => {
            let file = state
                .files
                .iter()
                .find(|f| f.path == *path)
                .ok_or_else(|| fail("Path is not in the confirmed changed-file list"))?;
            match action {
                CheckoutGitAction::Stage { .. } => {
                    if file.worktree_status == " " {
                        return Err(fail("Path has no unstaged changes"));
                    }
                    git(root, &["add", "--", path]).await?.0
                }
                _ => {
                    if file.index_status == " " || file.index_status == "?" {
                        return Err(fail("Path has no staged changes"));
                    }
                    if state.head_sha.is_some() {
                        git(root, &["reset", "--quiet", "HEAD", "--", path])
                            .await?
                            .0
                    } else {
                        git(root, &["rm", "--cached", "--force", "--quiet", "--", path])
                            .await?
                            .0
                    }
                }
            }
        }
        CheckoutGitAction::Commit { message } => {
            if message.trim().is_empty() || message.len() > MAX_MESSAGE || message.contains('\0') {
                return Err(fail("Commit message must be nonempty and at most 64 KiB"));
            }
            if !state
                .files
                .iter()
                .any(|f| f.index_status != " " && f.index_status != "?")
            {
                return Err(fail("Stage changes before committing"));
            }
            git(root, &["commit", "--cleanup=verbatim", "-m", message])
                .await?
                .0
        }
        CheckoutGitAction::Push {} => {
            if state.head_sha.is_none() {
                return Err(fail("Create a commit before pushing"));
            }
            let upstream = state.upstream.ok_or_else(|| {
                fail("No single existing upstream is configured; set one in a terminal first")
            })?;
            let (mirror_set, mirror) = git(
                root,
                &[
                    "config",
                    "--bool",
                    "--get",
                    &format!("remote.{}.mirror", upstream.remote),
                ],
            )
            .await?;
            if mirror_set && one_line(&mirror)? == "true" {
                return Err(fail(
                    "Push is unavailable for mirror remotes; use a terminal",
                ));
            }
            // Pin the source too: another writer can advance HEAD after the
            // final snapshot check but before Git starts. Publish only the
            // commit the user saw in the confirmation, never that later HEAD.
            let refspec = format!(
                "{}:refs/heads/{}",
                state.head_sha.as_deref().expect("checked above"),
                upstream.branch
            );
            git(
                root,
                &[
                    "push",
                    "--porcelain",
                    "--no-force",
                    "--no-mirror",
                    "--no-follow-tags",
                    "--",
                    &upstream.remote,
                    &refspec,
                ],
            )
            .await?
            .0
        }
    };
    if !success {
        return Err(fail(
            "Git action failed; inspect hooks, identity, authentication or remote state in a terminal, then refresh",
        ));
    }
    stable_capture(identity).await
}

#[cfg(test)]
tokio::task_local! { static TEST_GIT_HOME: std::path::PathBuf; }

#[cfg(test)]
#[path = "git_actions_tests.rs"]
mod tests;
