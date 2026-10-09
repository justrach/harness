//! Terminal launches: `harness [dir]` / `codegraff [dir]` open a folder as a
//! project. Inside a macOS bundle the request is handed to LaunchServices
//! (`open -a <bundle> <link>`), so a running app receives it through the URL
//! scheme and comes forward instead of a second GUI starting as a child of
//! the terminal (which would also make TCC attribute permissions to it).

use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::time::Duration;

const GRAFF_CHECK_INTERVAL: Duration = Duration::from_secs(60 * 60);
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
/// A build outside an Applications folder (a dev bundle under `target/`) only
/// fills missing or dead links, so it never takes the terminal commands away
/// from the installed app.
pub fn install_path_shims() {
    let Some(bundle) = app_bundle() else {
        return;
    };
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return;
    };
    let installed = is_installed_app(&bundle, &home);
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
        if let Err(err) = link_if_ours(&bin.join(name), &target, installed) {
            tracing::warn!("couldn't link {name} into {}: {err}", bin.display());
        }
    }
}

/// Keep the bundled app's managed graff CLI current with CodeGraff's latest
/// stable GitHub release. This runs on the existing off-launch-path thread,
/// so a slow network never delays the GUI. A user-selected graff executable
/// remains entirely under the user's control. With auto-update off
/// (`HARNESS_GRAFF_AUTO_UPDATE=0`) the loop still runs, but only checks and
/// publishes an `Available` notice — the user installs from the card.
pub fn install_path_shims_and_auto_update_graff() {
    use harness_adapters::graff_bundle as bundle;
    install_path_shims();
    // Dev builds only: `HARNESS_DEV_GRAFF_NOTICE=0.0.302.24..0.0.302.25`
    // raises the "updated" card without an update, to preview its design.
    #[cfg(debug_assertions)]
    if let Ok(range) = std::env::var("HARNESS_DEV_GRAFF_NOTICE")
        && let Some((from, to)) = range.split_once("..")
    {
        bundle::publish_notice(bundle::GraffNotice::Updated {
            from: Some(from.to_string()).filter(|from| !from.is_empty()),
            to: to.to_string(),
        });
    }
    if !bundle::managed_updates_allowed() {
        return;
    }
    let auto_update = bundle::auto_update_enabled();
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
            bundle::note_check_started();
            if auto_update {
                match bundle::check_and_update_managed().await {
                    Ok(bundle::UpdateOutcome::Updated { from, to }) => {
                        tracing::info!(?from, %to, "graff updated from CodeGraff GitHub release");
                        bundle::publish_notice(bundle::GraffNotice::Updated { from, to });
                    }
                    Ok(bundle::UpdateOutcome::AlreadyCurrent { version }) => {
                        tracing::debug!(%version, "graff is current");
                    }
                    Err(err) => {
                        tracing::warn!(error = %err, "graff automatic update check failed")
                    }
                }
            } else {
                // Check only: surface a newer stable without installing it.
                // Beta installs manage their own channel and never see this.
                match bundle::latest_stable().await {
                    Ok(latest) => {
                        if let Some(managed) = bundle::managed_path()
                            && bundle::installed_beta_tag(&managed).is_none()
                            && let Some(latest_parts) = bundle::parse_dotted(&latest)
                        {
                            let current = bundle::version_of(&managed);
                            if current
                                .as_deref()
                                .is_none_or(|c| c < latest_parts.as_slice())
                            {
                                bundle::publish_notice(bundle::GraffNotice::Available {
                                    current: current.as_deref().map(bundle::display_version),
                                    latest,
                                });
                            }
                        }
                    }
                    Err(err) => {
                        tracing::warn!(error = %err, "graff update check failed")
                    }
                }
            }
            tokio::time::sleep(GRAFF_CHECK_INTERVAL).await;
        }
    });
}

/// An app installed in `/Applications` or `~/Applications`, as opposed to a
/// build run from wherever it was built.
fn is_installed_app(bundle: &Path, home: &Path) -> bool {
    bundle
        .parent()
        .is_some_and(|dir| dir == Path::new("/Applications") || dir == home.join("Applications"))
}

/// A link is ours when it points into a Harness `.app` or `~/.harness/bin`.
/// `replace_live` false keeps one of ours whose target still exists.
fn link_if_ours(link: &Path, target: &Path, replace_live: bool) -> std::io::Result<()> {
    match std::fs::read_link(link) {
        Ok(current) if current == target => return Ok(()),
        Ok(current) => {
            let live = link.exists();
            let current = current.to_string_lossy();
            let ours = (current.contains(".app/Contents/")
                && (current.contains("Harness") || current.contains("harness")))
                || current.contains("/.harness/bin/");
            if !ours || (live && !replace_live) {
                return Ok(());
            }
            std::fs::remove_file(link)?;
        }
        // The old Codegraff GUI's launcher script: Harness is the Codegraff
        // desktop app now, so `codegraff` opens it. Any other regular file
        // stays untouched.
        Err(_) if link.symlink_metadata().is_ok() => {
            if !replace_live || !is_codegraff_launcher(link) {
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

/// The launcher scripts the old Codegraff GUI wrote, under either header it
/// has used.
fn is_codegraff_launcher(path: &Path) -> bool {
    const HEADERS: [&str; 2] = [
        "# Codegraff GUI terminal launcher",
        "# codegraff — open a path in the Codegraff desktop app",
    ];
    // The scripts are a few hundred bytes; don't read a large binary.
    if std::fs::metadata(path).map_or(true, |meta| meta.len() > 4096) {
        return false;
    }
    std::fs::read_to_string(path)
        .is_ok_and(|script| HEADERS.iter().any(|header| script.contains(header)))
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
    fn installed_app_takes_over_both_codegraff_launcher_scripts() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("Harness.app/Contents/MacOS/harness");
        let old_app = dir.path().join("Codegraff");
        std::fs::write(&old_app, "").unwrap();
        for (name, header) in [
            ("launcher", "# Codegraff GUI terminal launcher"),
            (
                "code-style",
                "# codegraff — open a path in the Codegraff desktop app (code-style).",
            ),
        ] {
            let script = format!("#!/bin/sh\n{header}\nAPP_BIN=\"{}\"\n", old_app.display());
            let link = dir.path().join(name);
            std::fs::write(&link, &script).unwrap();
            // A dev build leaves it for the installed app.
            link_if_ours(&link, &target, false).unwrap();
            assert_eq!(std::fs::read_to_string(&link).unwrap(), script);
            // The installed app replaces it even while the old app exists.
            link_if_ours(&link, &target, true).unwrap();
            assert_eq!(std::fs::read_link(&link).unwrap(), target);
        }
    }

    #[cfg(unix)]
    #[test]
    fn dev_builds_only_fill_missing_or_dead_links() {
        let dir = tempfile::tempdir().unwrap();
        let installed = dir
            .path()
            .join("Applications/Harness.app/Contents/MacOS/harness");
        std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
        std::fs::write(&installed, "").unwrap();
        let dev = dir
            .path()
            .join("target/macos-dev/Harness.app/Contents/MacOS/harness");
        let link = dir.path().join("harness");
        std::os::unix::fs::symlink(&installed, &link).unwrap();
        link_if_ours(&link, &dev, false).unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), installed);
        // Once the installed app is gone, the dev build may take the link.
        std::fs::remove_file(&installed).unwrap();
        link_if_ours(&link, &dev, false).unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), dev);
        // And the installed app takes the dev build's link back.
        link_if_ours(&link, &installed, true).unwrap();
        assert_eq!(std::fs::read_link(&link).unwrap(), installed);
    }

    #[test]
    fn only_applications_folders_count_as_installed() {
        let home = Path::new("/Users/me");
        assert!(is_installed_app(
            Path::new("/Applications/Harness.app"),
            home
        ));
        assert!(is_installed_app(
            Path::new("/Users/me/Applications/Harness.app"),
            home
        ));
        assert!(!is_installed_app(
            Path::new("/tmp/harness-run/target/macos-dev/Harness.app"),
            home
        ));
    }

    #[cfg(unix)]
    #[test]
    fn shims_never_replace_foreign_files_or_links() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("Harness.app/Contents/MacOS/harness");
        // Fresh: created.
        let fresh = dir.path().join("harness");
        link_if_ours(&fresh, &target, true).unwrap();
        assert_eq!(std::fs::read_link(&fresh).unwrap(), target);
        // A user's own binary: untouched.
        let own = dir.path().join("graff");
        std::fs::write(&own, "mine").unwrap();
        link_if_ours(&own, &target, true).unwrap();
        assert_eq!(std::fs::read_to_string(&own).unwrap(), "mine");
        // A foreign symlink: untouched.
        let foreign = dir.path().join("codegraff");
        std::os::unix::fs::symlink("/opt/elsewhere/codegraff", &foreign).unwrap();
        link_if_ours(&foreign, &target, true).unwrap();
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
        link_if_ours(&stale, &target, true).unwrap();
        assert_eq!(std::fs::read_link(&stale).unwrap(), target);
    }

    #[test]
    fn bare_non_terminal_launch_opens_nothing() {
        assert_eq!(resolve_open_arg(None, false).unwrap(), None);
    }
}
