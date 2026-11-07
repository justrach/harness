//! nanocua on this device, for the MCP servers settings page: `nanocua ctl
//! <command> --json`, with the app's own program. Not through graff: an older
//! graff takes `graff computer …` for a prompt and sends it to a model.

use std::path::{Path, PathBuf};
use std::time::Duration;

use harness_proto::{ComputerUseAction, ComputerUseStatus};

use crate::EngineError;

const EXECUTABLE: &str = "nanocua.app/Contents/MacOS/nanocua";
/// Time to start the app, and for it to answer.
const REPLY_TIMEOUT: Duration = Duration::from_secs(20);
/// A question lasts a minute in nanocua's window.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(90);

/// Where the app can be: where graff's installer puts it, then the system's.
fn candidates(home: &Path) -> [PathBuf; 2] {
    [
        home.join("Applications").join(EXECUTABLE),
        Path::new("/Applications").join(EXECUTABLE),
    ]
}

fn program(home: &Path) -> Option<PathBuf> {
    candidates(home).into_iter().find(|p| p.is_file())
}

fn absent(supported: bool) -> ComputerUseStatus {
    ComputerUseStatus {
        supported,
        ..Default::default()
    }
}

pub async fn status(home: &Path) -> Result<ComputerUseStatus, EngineError> {
    run(home, &["status"], REPLY_TIMEOUT).await
}

pub async fn act(home: &Path, action: ComputerUseAction) -> Result<ComputerUseStatus, EngineError> {
    let timeout = if action.asks() {
        ANSWER_TIMEOUT
    } else {
        REPLY_TIMEOUT
    };
    run(home, action.ctl_args(), timeout).await
}

async fn run(
    home: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<ComputerUseStatus, EngineError> {
    if !cfg!(target_os = "macos") {
        return Ok(absent(false));
    }
    let Some(program) = program(home) else {
        return Ok(absent(true));
    };
    let mut command = harness_adapters::process::Command::new(&program);
    command
        .arg("ctl")
        .args(args)
        .arg("--json")
        .arg("--from=Harness")
        .stdin(harness_adapters::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(timeout, command.output())
        .await
        .map_err(|_| EngineError::Other("nanocua didn't answer in time.".into()))?
        .map_err(|err| EngineError::Other(format!("Could not run nanocua: {err}")))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let last = stderr
            .lines()
            .chain(stdout.lines())
            .rev()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("nanocua exited with an error");
        return Err(EngineError::Other(last.trim().to_string()));
    }
    parse(&stdout)
}

/// The status from `--json` output, on a system that has computer use.
pub fn parse(stdout: &str) -> Result<ComputerUseStatus, EngineError> {
    stdout
        .lines()
        .find(|l| l.trim_start().starts_with('{'))
        .and_then(|line| serde_json::from_str::<ComputerUseStatus>(line).ok())
        .map(|status| ComputerUseStatus {
            supported: true,
            ..status
        })
        .ok_or_else(|| {
            EngineError::Other(
                "This nanocua can't report its state yet. Update graff to manage it here.".into(),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reply_is_on_a_supported_system_and_anything_else_says_update() {
        let status =
            parse("{\"installed\":true,\"running\":false,\"outcome\":\"not_running\"}\n").unwrap();
        assert!(status.supported && status.installed && !status.running);
        assert!(parse("usage: nanocua\n").is_err());
        assert!(parse("").is_err());
    }

    #[test]
    fn the_app_in_the_users_applications_folder_comes_first() {
        let dir = tempfile::tempdir().unwrap();
        let [first, second] = candidates(dir.path());
        assert!(first.starts_with(dir.path()));
        assert_eq!(second, Path::new("/Applications").join(EXECUTABLE));
        std::fs::create_dir_all(first.parent().unwrap()).unwrap();
        std::fs::write(&first, "").unwrap();
        assert_eq!(program(dir.path()), Some(first));
    }

    /// A stand-in for the app that says what it was run with.
    #[cfg(target_os = "macos")]
    fn fake_app(home: &Path, script: &str) {
        use std::os::unix::fs::PermissionsExt;
        let [path, _] = candidates(home);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn an_action_runs_the_apps_ctl_and_says_harness_asked() {
        let dir = tempfile::tempdir().unwrap();
        fake_app(
            dir.path(),
            r#"printf '{"installed":true,"running":true,"outcome":"%s"}\n' "$*""#,
        );
        let status = act(dir.path(), ComputerUseAction::AllowWholeScreen)
            .await
            .unwrap();
        assert!(status.supported && status.running);
        assert_eq!(
            status.outcome.as_deref(),
            Some("ctl allow whole_screen --json --from=Harness")
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn a_failing_app_reports_its_last_line() {
        let dir = tempfile::tempdir().unwrap();
        fake_app(dir.path(), "echo nope >&2\nexit 3");
        let err = status(dir.path()).await.unwrap_err();
        assert!(err.to_string().contains("nope"));
    }

    #[test]
    fn no_app_has_no_buttons_and_says_whether_the_system_could_have_one() {
        assert!(absent(true).supported && !absent(true).installed);
        assert!(!absent(false).supported);
        assert!(absent(true).controls().is_empty());
    }
}
