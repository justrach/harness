//! Repair a global npm install of Codex that lacks its native binary.
//!
//! `@openai/codex` ships the binary as an optional dependency
//! (`@openai/codex-darwin-arm64`, `@openai/codex-linux-x64` and friends). An
//! install made without optional dependencies (`--omit=optional`, some machine
//! images, npm's optional-dependency lockfile bug) leaves a `codex` whose
//! launcher throws "Missing optional dependency" on every start, so no Codex
//! run can begin. Reinstalling that same version with optional dependencies
//! fixes it.

use std::path::Path;
use std::time::{Duration, Instant};

use crate::process::{Command, Stdio};

const MISSING: &str = "Missing optional dependency";
const PACKAGE: &str = "@openai/codex";
/// A failed repair is retried after this long: a network blip mid-install
/// must not leave Codex broken until the engine restarts.
const RETRY_AFTER: Duration = Duration::from_secs(10 * 60);
const PROBE_TIMEOUT: Duration = Duration::from_secs(20);
const INSTALL_TIMEOUT: Duration = Duration::from_secs(300);

/// What [`repair_with`] found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Repair {
    /// Codex starts (or fails some other way): nothing for a reinstall to fix.
    NotNeeded,
    /// Codex was missing its binary and starts now.
    Repaired { version: String },
}

/// The once-per-engine install check: done once it passes; a failed repair
/// is retried after [`RETRY_AFTER`]. Runs that start while a repair is in
/// progress wait for it.
#[derive(Default)]
pub(crate) struct Check {
    state: tokio::sync::Mutex<CheckState>,
}

#[derive(Default)]
enum CheckState {
    #[default]
    Unchecked,
    Passed,
    FailedAt(Instant),
}

static CHECK: std::sync::LazyLock<Check> = std::sync::LazyLock::new(Check::default);

/// Before the first Codex run: repair a global npm Codex that can't start
/// because its native binary is missing. Never fails the run itself: a
/// Codex that still can't start reports its own error when spawned. The
/// reinstall runs as the user only, never with escalated privileges: a
/// global prefix the user can't write to (a root-owned /usr/local) fails,
/// is logged, and leaves Codex's own error to surface.
pub(crate) async fn ensure_starts(codex: &Path) {
    if cfg!(windows) {
        return;
    }
    CHECK
        .ensure(codex, || async {
            let Some(npm) = crate::adapter_install::find_npm() else {
                return Ok(Repair::NotNeeded);
            };
            repair_with(codex, &npm).await
        })
        .await;
}

impl Check {
    async fn ensure<F, Fut>(&self, codex: &Path, repair: F)
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = Result<Repair, String>>,
    {
        let mut state = self.state.lock().await;
        match *state {
            CheckState::Passed => return,
            CheckState::FailedAt(at) if at.elapsed() < RETRY_AFTER => return,
            _ => {}
        }
        // The cheap probe first: a healthy Codex never looks for npm.
        if !matches!(probe(codex).await, Probe::MissingBinary) {
            *state = CheckState::Passed;
            return;
        }
        *state = match repair().await {
            Ok(Repair::NotNeeded) => CheckState::Passed,
            Ok(Repair::Repaired { version }) => {
                tracing::info!(%version, "reinstalled Codex with its native binary");
                CheckState::Passed
            }
            Err(error) => {
                tracing::warn!(%error, "Codex is missing its native binary and the reinstall failed");
                CheckState::FailedAt(Instant::now())
            }
        };
    }
}

/// Reinstall `codex`'s npm package when its binary is missing. `Err` when the
/// reinstall ran and Codex still can't start.
pub(crate) async fn repair_with(codex: &Path, npm: &Path) -> Result<Repair, String> {
    match probe(codex).await {
        Probe::Starts | Probe::Fails(_) => return Ok(Repair::NotNeeded),
        Probe::MissingBinary => {}
    }
    let version = installed_version(codex).unwrap_or_else(|| "latest".into());
    let spec = format!("{PACKAGE}@{version}");
    let args = [
        "install",
        "-g",
        "--include=optional",
        "--no-audit",
        "--no-fund",
        spec.as_str(),
    ];
    let output = run(npm, &args).await?;
    if !output.status.success() {
        return Err(format!(
            "reinstalling {spec} failed: {}",
            tail(&String::from_utf8_lossy(&output.stderr))
        ));
    }
    match probe(codex).await {
        Probe::Starts => Ok(Repair::Repaired { version }),
        Probe::MissingBinary => Err(format!("{spec} still has no native binary")),
        Probe::Fails(error) => Err(format!("Codex still can't start: {error}")),
    }
}

enum Probe {
    Starts,
    MissingBinary,
    Fails(String),
}

async fn probe(codex: &Path) -> Probe {
    let mut cmd = command(codex);
    cmd.arg("--version");
    match tokio::time::timeout(PROBE_TIMEOUT, cmd.output()).await {
        Ok(Ok(out)) if out.status.success() => Probe::Starts,
        Ok(Ok(out)) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if stderr.contains(MISSING) {
                Probe::MissingBinary
            } else {
                Probe::Fails(tail(&stderr))
            }
        }
        Ok(Err(err)) => Probe::Fails(err.to_string()),
        Err(_) => Probe::Fails("codex --version timed out".into()),
    }
}

/// The version of the npm package behind `codex`
/// (`…/node_modules/@openai/codex/bin/codex.js`, usually through a symlink).
fn installed_version(codex: &Path) -> Option<String> {
    let script = std::fs::canonicalize(codex).ok()?;
    let manifest = script.parent()?.parent()?.join("package.json");
    let value: serde_json::Value = serde_json::from_slice(&std::fs::read(manifest).ok()?).ok()?;
    if value["name"] != PACKAGE {
        return None;
    }
    let version = value["version"].as_str()?;
    version
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '+'))
        .then(|| version.to_string())
}

/// `npm args…`, as the user.
async fn run(npm: &Path, args: &[&str]) -> Result<std::process::Output, String> {
    let mut cmd = command(npm);
    cmd.args(args);
    tokio::time::timeout(INSTALL_TIMEOUT, cmd.output())
        .await
        .map_err(|_| format!("{} timed out", npm.display()))?
        .map_err(|err| format!("{}: {err}", npm.display()))
}

/// The same PATH a Codex run gets (npm launchers are `env node` scripts).
fn command(program: &Path) -> Command {
    let mut cmd = Command::new(program);
    crate::apply_run_environment(&mut cmd, None);
    crate::compose_child_path(&mut cmd, program);
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    cmd
}

fn tail(text: &str) -> String {
    let text = text.trim();
    let start = text.char_indices().rev().nth(399).map_or(0, |(i, _)| i);
    text[start..].to_string()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;

    fn script(path: &Path, body: &str) {
        std::fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    /// A global install laid out like npm's: `bin/codex` → the package's
    /// launcher, which fails until the platform package "arrives".
    fn install(dir: &Path) -> PathBuf {
        let package = dir.join("lib/node_modules/@openai/codex");
        std::fs::create_dir_all(package.join("bin")).unwrap();
        std::fs::write(
            package.join("package.json"),
            r#"{"name":"@openai/codex","version":"0.163.0"}"#,
        )
        .unwrap();
        let fixed = dir.join("fixed");
        script(
            &package.join("bin/codex.js"),
            &format!(
                "if [ -f '{}' ]; then echo 'codex-cli 0.163.0'; exit 0; fi\n\
                 echo 'Error: Missing optional dependency @openai/codex-darwin-arm64. Reinstall Codex' >&2; exit 1",
                fixed.display()
            ),
        );
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        let codex = dir.join("bin/codex");
        std::os::unix::fs::symlink(package.join("bin/codex.js"), &codex).unwrap();
        codex
    }

    /// An npm stand-in that logs its arguments and "installs" the binary.
    fn fixing_npm(dir: &Path) -> (PathBuf, PathBuf) {
        let npm = dir.join("npm");
        let calls = dir.join("calls");
        script(
            &npm,
            &format!(
                "echo \"$@\" >> '{}'; touch '{}'",
                calls.display(),
                dir.join("fixed").display()
            ),
        );
        (npm, calls)
    }

    #[tokio::test]
    async fn reinstalls_the_same_version_with_optional_dependencies() {
        let dir = tempfile::tempdir().unwrap();
        let codex = install(dir.path());
        let (npm, calls) = fixing_npm(dir.path());
        let outcome = repair_with(&codex, &npm).await;
        assert_eq!(
            outcome,
            Ok(Repair::Repaired {
                version: "0.163.0".into()
            })
        );
        let calls = std::fs::read_to_string(calls).unwrap();
        assert_eq!(
            calls.trim(),
            "install -g --include=optional --no-audit --no-fund @openai/codex@0.163.0"
        );
        // Healthy now: nothing more to do.
        assert_eq!(repair_with(&codex, &npm).await, Ok(Repair::NotNeeded));
    }

    /// A global prefix the user can't write to fails as the user: one plain
    /// npm attempt, its error reported, no privileged retry.
    #[tokio::test]
    async fn a_refused_global_prefix_fails_without_escalating() {
        let dir = tempfile::tempdir().unwrap();
        let codex = install(dir.path());
        let npm = dir.path().join("npm");
        let calls = dir.path().join("calls");
        script(
            &npm,
            &format!(
                "echo \"$@\" >> '{}'; echo 'npm error code EACCES' >&2; exit 243",
                calls.display()
            ),
        );
        let outcome = repair_with(&codex, &npm).await;
        let error = outcome.expect_err("a refused install is an error");
        assert!(error.contains("EACCES"), "{error}");
        assert_eq!(std::fs::read_to_string(&calls).unwrap().lines().count(), 1);
        assert!(!dir.path().join("fixed").exists());
    }

    #[tokio::test]
    async fn other_failures_are_left_alone() {
        let dir = tempfile::tempdir().unwrap();
        let codex = dir.path().join("codex");
        script(&codex, "echo 'some other crash' >&2; exit 1");
        let npm = dir.path().join("npm");
        let calls = dir.path().join("calls");
        script(
            &npm,
            &format!("echo called >> '{}'; exit 1", calls.display()),
        );
        assert_eq!(repair_with(&codex, &npm).await, Ok(Repair::NotNeeded));
        assert!(!calls.exists(), "npm ran for an unrelated failure");
    }

    /// The check runs the repair at most once per engine once it passes, and
    /// a healthy Codex never reaches npm at all.
    #[tokio::test]
    async fn the_check_repairs_once_and_then_stays_out_of_the_way() {
        let dir = tempfile::tempdir().unwrap();
        let codex = install(dir.path());
        let (npm, calls) = fixing_npm(dir.path());
        let check = Check::default();
        for _ in 0..2 {
            check.ensure(&codex, || repair_with(&codex, &npm)).await;
        }
        assert_eq!(std::fs::read_to_string(&calls).unwrap().lines().count(), 1);

        let healthy = tempfile::tempdir().unwrap();
        let codex = healthy.path().join("codex");
        script(&codex, "echo 'codex-cli 0.163.0'");
        let check = Check::default();
        check
            .ensure(&codex, || async { panic!("a healthy Codex never repairs") })
            .await;
    }

    /// A failed reinstall is not retried on every run.
    #[tokio::test]
    async fn a_failed_repair_backs_off() {
        let dir = tempfile::tempdir().unwrap();
        let codex = install(dir.path());
        let npm = dir.path().join("npm");
        let calls = dir.path().join("calls");
        script(
            &npm,
            &format!(
                "echo \"$@\" >> '{}'; echo 'npm error network' >&2; exit 1",
                calls.display()
            ),
        );
        let check = Check::default();
        for _ in 0..3 {
            check.ensure(&codex, || repair_with(&codex, &npm)).await;
        }
        assert_eq!(std::fs::read_to_string(&calls).unwrap().lines().count(), 1);
    }
}
