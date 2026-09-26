//! Screen Recording access for agents.
//!
//! Agents run as children of Harness, so macOS judges their screenshots
//! (`screencapture`, ScreenCaptureKit) against HARNESS's Screen Recording
//! grant. macOS never prompts on a child's behalf: without the grant the tool
//! just fails with "could not create image from rect". Harness watches live
//! tool results for that denial and offers to ask for access itself (the only
//! request macOS will turn into a prompt). Grants apply after a relaunch.

use harness_proto::ToolCall;

/// An agent was just refused a screenshot in `chat_id`; the composer offers
/// to fix it. `requested` flips once the user asked macOS for access, after
/// which only a relaunch (or System Settings) can finish the job.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Notice {
    pub chat_id: String,
    pub requested: bool,
}

/// Where the grant lives in System Settings.
#[cfg(target_os = "macos")]
pub(crate) const SETTINGS_URL: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture";

/// [`SETTINGS_URL`] where the platform has one (lets callers stay cfg-free).
#[cfg(target_os = "macos")]
pub(crate) const SETTINGS_URL_OPT: Option<&str> = Some(SETTINGS_URL);
#[cfg(not(target_os = "macos"))]
pub(crate) const SETTINGS_URL_OPT: Option<&str> = None;

/// Output text macOS produces when a capture is refused for lack of access:
/// the `screencapture` CLI, and ScreenCaptureKit's TCC error (-3801).
const DENIAL_MARKERS: &[&str] = &[
    "could not create image from rect",
    "declined TCCs",
    "declined TCC",
    "SCStreamErrorDomain Code=-3801",
];

/// Whether this platform gates screenshots behind a grant Harness can request.
pub(crate) fn supported() -> bool {
    cfg!(target_os = "macos")
}

/// Whether Harness (and so its agents) may capture the screen.
pub(crate) fn granted() -> bool {
    #[cfg(target_os = "macos")]
    {
        core_graphics::access::ScreenCaptureAccess.preflight()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

/// Ask macOS for access. Shows the system prompt the first time; returns
/// false without prompting once the user has answered before, in which case
/// the caller should open [`SETTINGS_URL`].
pub(crate) fn request() -> bool {
    #[cfg(target_os = "macos")]
    {
        core_graphics::access::ScreenCaptureAccess.request()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

/// Whether a finished tool call failed because macOS refused a screenshot.
pub(crate) fn is_denial(call: &ToolCall, output: Option<&str>) -> bool {
    let Some(output) = output else {
        return false;
    };
    let marked = DENIAL_MARKERS.iter().any(|marker| output.contains(marker));
    // The CLI message is specific enough alone; guard the TCC wording with a
    // capture-ish command so a `cat` of this very file can't trip it.
    marked
        && match call {
            ToolCall::Exec { command } => {
                output.contains(DENIAL_MARKERS[0])
                    || ["screencapture", "screenshot", "ScreenCapture", "capture"]
                        .iter()
                        .any(|word| command.contains(word))
            }
            _ => false,
        }
}

/// The running app bundle (`…/Harness.app`), for a relaunch.
pub(crate) fn running_bundle(install: &harness_update::InstallKind) -> Option<std::path::PathBuf> {
    if let harness_update::InstallKind::MacApp { bundle } = install {
        return Some(bundle.clone());
    }
    // Dev bundles (scripts/run-macos-dev.sh) aren't a managed install, but
    // still run from `X.app/Contents/MacOS/harness`.
    let exe = std::env::current_exe().ok()?;
    let bundle = exe.parent()?.parent()?.parent()?;
    (bundle.extension()? == "app").then(|| bundle.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exec(command: &str) -> ToolCall {
        ToolCall::Exec {
            command: command.into(),
        }
    }

    #[test]
    fn recognizes_the_screencapture_denial() {
        assert!(is_denial(
            &exec("screencapture -x /tmp/shot.png"),
            Some("Exit code 1\ncould not create image from rect"),
        ));
        assert!(is_denial(
            &exec("python3 shot.py"),
            Some("could not create image from rect"),
        ));
        assert!(is_denial(
            &exec("swift capture.swift"),
            Some("Error: The user declined TCCs for application, window, display capture"),
        ));
    }

    #[test]
    fn ignores_unrelated_output() {
        assert!(!is_denial(&exec("screencapture -x a.png"), None));
        assert!(!is_denial(
            &exec("cargo build"),
            Some("error[E0609]: no field")
        ));
        assert!(!is_denial(
            &exec("cat notes.md"),
            Some("the user declined TCCs")
        ));
        assert!(!is_denial(
            &ToolCall::ReadFile {
                path: "screen_access.rs".into()
            },
            Some("could not create image from rect"),
        ));
    }
}
