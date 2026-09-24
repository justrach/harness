//! Terminal launches: `harness [dir]` / `codegraff [dir]` open a folder as a
//! project. Inside a macOS bundle the request is handed to LaunchServices
//! (`open -a <bundle> <link>`), so a running app receives it through the URL
//! scheme and comes forward instead of a second GUI starting as a child of
//! the terminal (which would also make TCC attribute permissions to it).

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::Duration;

const GRAFF_CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
const GRAFF_CHECK_INITIAL_DELAY: Duration = Duration::from_secs(30);

/// What the headed start should open: a `harness://` link passed through, a
/// folder link for a directory argument, or — for a bare terminal launch —
/// the working directory (skipped for `~` and `/`, which are never projects).
pub fn resolve_open_arg(
    arg: Option<String>,
    from_terminal: bool,
) -> Result<Option<String>, String> {
    match arg {
        Some(arg) if arg.starts_with("harness://") => Ok(Some(arg)),
        Some(arg) => {
            let path = std::fs::canonicalize(&arg).map_err(|err| format!("{arg}: {err}"))?;
            // A file opens its folder (`harness src/main.rs`).
            let folder = if path.is_dir() {
                path
            } else {
                path.parent()
                    .map(Path::to_path_buf)
                    .ok_or_else(|| format!("{arg}: not a folder"))?
            };
            Ok(Some(folder_link(&folder)))
        }
        None if from_terminal => {
            let Ok(cwd) = std::env::current_dir().and_then(std::fs::canonicalize) else {
                return Ok(None);
            };
            let home = std::env::var_os("HOME").and_then(|home| std::fs::canonicalize(home).ok());
            if cwd.parent().is_none() || home.as_deref() == Some(cwd.as_path()) {
                return Ok(None);
            }
            Ok(Some(folder_link(&cwd)))
        }
        None => Ok(None),
    }
}

fn folder_link(path: &Path) -> String {
    harness_ui::links::folder_open_link(&path.to_string_lossy())
}

/// Whether stdin is a terminal: LaunchServices starts apps with stdin on
/// /dev/null, so a TTY means a person typed the command.
pub fn from_terminal() -> bool {
    std::io::stdin().is_terminal()
}

/// The `.app` this binary lives in, following the `~/.local/bin` symlinks.
pub fn app_bundle() -> Option<PathBuf> {
    let exe = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
    exe.ancestors()
        .find(|dir| dir.extension().is_some_and(|ext| ext == "app"))
        .map(Path::to_path_buf)
}

/// macOS terminal launch from a bundle: forward to LaunchServices and return
/// true (the caller exits). Anywhere else the caller starts the UI itself.
pub fn hand_off_to_bundle(link: Option<&str>) -> bool {
    if !cfg!(target_os = "macos") || !from_terminal() {
        return false;
    }
    let Some(bundle) = app_bundle() else {
        return false;
    };
    let mut open = std::process::Command::new("/usr/bin/open");
    open.arg("-a").arg(&bundle);
    if let Some(link) = link {
        open.arg(link);
    }
    match open.status() {
        Ok(status) if status.success() => true,
        Ok(status) => {
            eprintln!("harness: `open -a {}` failed ({status})", bundle.display());
            false
        }
        Err(err) => {
            eprintln!("harness: couldn't run open: {err}");
            false
        }
    }
}

/// Put `harness`, `codegraff`, and `graff` on the PATH via `~/.local/bin`
/// symlinks into the bundle / the app-managed graff, and refresh that managed
/// graff from the bundle. Only links we own are ever replaced: an existing
/// regular file or a foreign symlink (a user's own graff install) is left alone.
pub fn install_path_shims() {
    let Some(bundle) = app_bundle() else {
        return;
    };
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return;
    };
    let bin = home.join(".local").join("bin");
    let app_exe = bundle.join("Contents").join("MacOS").join("harness");
    let managed_graff = match harness_adapters::graff_bundle::seed_managed() {
        Ok(path) => path,
        Err(err) => {
            tracing::warn!("couldn't refresh the managed graff: {err}");
            harness_adapters::graff_bundle::managed_path().filter(|path| path.is_file())
        }
    };
    let mut links = vec![("harness", app_exe.clone()), ("codegraff", app_exe)];
    links.extend(managed_graff.map(|graff| ("graff", graff)));
    if let Err(err) = std::fs::create_dir_all(&bin) {
        tracing::warn!("couldn't create {}: {err}", bin.display());
        return;
    }
    for (name, target) in links {
        if let Err(err) = link_if_ours(&bin.join(name), &target) {
            tracing::warn!("couldn't link {name} into {}: {err}", bin.display());
        }
    }
}

/// Keep the bundled app's managed graff CLI current with CodeGraff's latest
/// stable GitHub release. This runs on the existing off-launch-path thread,
/// so a slow network never delays the GUI. A user-selected graff executable
/// remains entirely under the user's control.
pub fn install_path_shims_and_auto_update_graff() {
    install_path_shims();
    if app_bundle().is_none()
        || std::env::var_os("GRAFF_EXECUTABLE").is_some_and(|value| !value.is_empty())
        || std::env::var("HARNESS_GRAFF_AUTO_UPDATE").is_ok_and(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "0" | "false" | "no" | "off"
            )
        })
    {
        return;
    }
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            tracing::warn!(%err, "couldn't start graff update checker");
            return;
        }
    };
    runtime.block_on(async {
        tokio::time::sleep(GRAFF_CHECK_INITIAL_DELAY).await;
        loop {
            match harness_adapters::graff_bundle::check_and_update_managed().await {
                Ok(harness_adapters::graff_bundle::UpdateOutcome::Updated { from, to }) => {
                    tracing::info!(?from, %to, "graff updated from CodeGraff GitHub release");
                }
                Ok(harness_adapters::graff_bundle::UpdateOutcome::AlreadyCurrent { version }) => {
                    tracing::debug!(%version, "graff is current");
                }
                Err(err) => tracing::warn!(error = %err, "graff automatic update check failed"),
            }
            tokio::time::sleep(GRAFF_CHECK_INTERVAL).await;
        }
    });
}

/// A link is ours when it points into a Harness `.app` or `~/.harness/bin`.
fn link_if_ours(link: &Path, target: &Path) -> std::io::Result<()> {
    match std::fs::read_link(link) {
        Ok(current) if current == target => return Ok(()),
        Ok(current) => {
            let current = current.to_string_lossy();
            let ours = (current.contains(".app/Contents/")
                && (current.contains("Harness") || current.contains("harness")))
                || current.contains("/.harness/bin/");
            if !ours {
                return Ok(());
            }
            std::fs::remove_file(link)?;
        }
        // The old Codegraff GUI's launcher script is replaced only once the
        // app it starts is gone; any other regular file stays untouched.
        Err(_) if link.symlink_metadata().is_ok() => {
            if !is_orphaned_codegraff_launcher(link) {
                return Ok(());
            }
            std::fs::remove_file(link)?;
        }
        Err(_) => {}
    }
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link)
    }
    #[cfg(not(unix))]
    {
        Ok(())
    }
}

/// `# Codegraff GUI terminal launcher` scripts name their app in `APP_BIN='…'`.
fn is_orphaned_codegraff_launcher(path: &Path) -> bool {
    let Ok(script) = std::fs::read_to_string(path) else {
        return false;
    };
    if !script.contains("# Codegraff GUI terminal launcher") {
        return false;
    }
    script
        .lines()
        .find_map(|line| line.trim().strip_prefix("APP_BIN="))
        .map(|value| value.trim_matches(|c| c == '\'' || c == '"'))
        .is_some_and(|app| !Path::new(app).exists())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn harness_links_pass_through() {
        let link = "harness://open/chat/a?workspace=b".to_string();
        assert_eq!(
            resolve_open_arg(Some(link.clone()), true).unwrap(),
            Some(link)
        );
    }

    #[test]
    fn directory_argument_becomes_folder_link() {
        let dir = tempfile::tempdir().unwrap();
        let link = resolve_open_arg(Some(dir.path().to_string_lossy().into()), true)
            .unwrap()
            .unwrap();
        let path = harness_ui::links::parse_folder_open_link(&link).unwrap();
        assert_eq!(Path::new(&path), std::fs::canonicalize(dir.path()).unwrap());
    }

    #[test]
    fn file_opens_its_folder_and_missing_paths_error() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("f.txt");
        std::fs::write(&file, "x").unwrap();
        let link = resolve_open_arg(Some(file.to_string_lossy().into()), true)
            .unwrap()
            .unwrap();
        let path = harness_ui::links::parse_folder_open_link(&link).unwrap();
        assert_eq!(Path::new(&path), std::fs::canonicalize(dir.path()).unwrap());
        assert!(resolve_open_arg(Some("/definitely/not/here".into()), true).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn codegraff_launcher_is_replaced_only_when_its_app_is_gone() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("Harness.app/Contents/MacOS/harness");
        let script = |app: &Path| {
            format!(
                "#!/bin/sh\n# Codegraff GUI terminal launcher\nAPP_BIN='{}'\n",
                app.display()
            )
        };
        let live_app = dir.path().join("Codegraff");
        std::fs::write(&live_app, "").unwrap();
        let live = dir.path().join("codegraff");
        std::fs::write(&live, script(&live_app)).unwrap();
        link_if_ours(&live, &target).unwrap();
        assert!(
            std::fs::read_link(&live).is_err(),
            "live launcher must stay"
        );
        let orphan = dir.path().join("codegraff-orphan");
        std::fs::write(
            &orphan,
            script(&dir.path().join("Gone.app/Contents/MacOS/Codegraff")),
        )
        .unwrap();
        link_if_ours(&orphan, &target).unwrap();
        assert_eq!(std::fs::read_link(&orphan).unwrap(), target);
    }

    #[cfg(unix)]
    #[test]
    fn shims_never_replace_foreign_files_or_links() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("Harness.app/Contents/MacOS/harness");
        // Fresh: created.
        let fresh = dir.path().join("harness");
        link_if_ours(&fresh, &target).unwrap();
        assert_eq!(std::fs::read_link(&fresh).unwrap(), target);
        // A user's own binary: untouched.
        let own = dir.path().join("graff");
        std::fs::write(&own, "mine").unwrap();
        link_if_ours(&own, &target).unwrap();
        assert_eq!(std::fs::read_to_string(&own).unwrap(), "mine");
        // A foreign symlink: untouched.
        let foreign = dir.path().join("codegraff");
        std::os::unix::fs::symlink("/opt/elsewhere/codegraff", &foreign).unwrap();
        link_if_ours(&foreign, &target).unwrap();
        assert_eq!(
            std::fs::read_link(&foreign).unwrap(),
            Path::new("/opt/elsewhere/codegraff")
        );
        // Our stale link (an older bundle location): repointed.
        let stale = dir.path().join("stale");
        std::os::unix::fs::symlink(
            "/Applications/Old/Harness.app/Contents/MacOS/harness",
            &stale,
        )
        .unwrap();
        link_if_ours(&stale, &target).unwrap();
        assert_eq!(std::fs::read_link(&stale).unwrap(), target);
    }

    #[test]
    fn bare_non_terminal_launch_opens_nothing() {
        assert_eq!(resolve_open_arg(None, false).unwrap(), None);
    }
}
