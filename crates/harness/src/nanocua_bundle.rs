//! nanocua.app, the computer-use app graff's agents connect to. It lives in
//! `~/Applications`, where graff looks for it and where macOS's grants follow it.
//! It gets there two ways: `Harness.app/Contents/Resources/nanocua.app` when the
//! app starts, and a graff release tarball when graff updates.

use std::path::Path;

const APP: &str = "nanocua.app";

/// The app's version from its Info.plist, as integers.
fn version_of(app: &Path) -> Option<Vec<u64>> {
    let output = std::process::Command::new("plutil")
        .args(["-extract", "CFBundleShortVersionString", "raw", "-o", "-"])
        .arg(app.join("Contents/Info.plist"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    crate::graff_bundle::parse_dotted(String::from_utf8_lossy(&output.stdout).trim())
}

/// Whether what's installed should give way: never for a newer app, which a graff
/// update may have put there, or for one whose version can't be read.
pub fn should_seed(
    bundled: Option<&[u64]>,
    installed: Option<&[u64]>,
    has_installed: bool,
) -> bool {
    match (bundled, installed) {
        (_, _) if !has_installed => true,
        (Some(bundled), Some(installed)) => bundled > installed,
        _ => false,
    }
}

/// Puts the bundled app in `applications` when it's missing or older.
pub fn seed(resources: &Path, applications: &Path) -> anyhow::Result<bool> {
    let bundled = resources.join(APP);
    if !cfg!(target_os = "macos") || !bundled.is_dir() {
        return Ok(false);
    }
    let target = applications.join(APP);
    if !should_seed(
        version_of(&bundled).as_deref(),
        version_of(&target).as_deref(),
        target.exists(),
    ) {
        return Ok(false);
    }
    install(resources, applications)
}

/// Puts the `nanocua.app` in `from` into `applications`. A folder without one (a
/// tarball CI didn't sign) leaves any installed app alone. `ditto` keeps the
/// signature, which macOS's permissions are tied to.
pub fn install(from: &Path, applications: &Path) -> anyhow::Result<bool> {
    if !cfg!(target_os = "macos") {
        return Ok(false);
    }
    let source = from.join(APP);
    if !source.is_dir() {
        return Ok(false);
    }
    std::fs::create_dir_all(applications)?;
    let target = applications.join(APP);
    let staged = applications.join(".nanocua.app.new");
    let aside = applications.join(".nanocua.app.old");
    let _ = std::fs::remove_dir_all(&staged);
    let status = std::process::Command::new("ditto")
        .arg(&source)
        .arg(&staged)
        .status()?;
    anyhow::ensure!(status.success(), "couldn't copy nanocua.app");
    let _ = std::fs::remove_dir_all(&aside);
    let had_one = target.exists();
    if had_one {
        std::fs::rename(&target, &aside)?;
    }
    if let Err(error) = std::fs::rename(&staged, &target) {
        if had_one {
            let _ = std::fs::rename(&aside, &target);
        }
        return Err(error.into());
    }
    let _ = std::fs::remove_dir_all(&aside);
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_missing_or_older_app_is_replaced() {
        let (v1, v2): (&[u64], &[u64]) = (&[0, 302, 71], &[0, 302, 72]);
        assert!(should_seed(Some(v2), None, false));
        assert!(should_seed(None, None, false));
        assert!(should_seed(Some(v2), Some(v1), true));
        assert!(
            !should_seed(Some(v1), Some(v2), true),
            "a graff update got further"
        );
        assert!(!should_seed(Some(v1), Some(v1), true));
        assert!(
            !should_seed(Some(v2), None, true),
            "an unreadable app is left alone"
        );
        assert!(!should_seed(None, Some(v1), true));
    }

    #[cfg(target_os = "macos")]
    fn fake_app(folder: &Path, version: &str) {
        let contents = folder.join(APP).join("Contents");
        std::fs::create_dir_all(&contents).unwrap();
        std::fs::write(
            contents.join("Info.plist"),
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>{version}</string></dict></plist>"#
            ),
        )
        .unwrap();
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_tarball_replaces_the_installed_app_and_no_app_changes_nothing() {
        let unpacked = tempfile::tempdir().unwrap();
        let apps = tempfile::tempdir().unwrap();
        let target = apps.path().join("Apps");
        let installed = target.join(APP);

        assert!(!install(unpacked.path(), &target).unwrap());
        assert!(!installed.exists());

        fake_app(unpacked.path(), "1.0.0");
        assert!(install(unpacked.path(), &target).unwrap());
        assert_eq!(version_of(&installed), Some(vec![1, 0, 0]));

        fake_app(unpacked.path(), "2.0.0");
        assert!(install(unpacked.path(), &target).unwrap());
        assert_eq!(version_of(&installed), Some(vec![2, 0, 0]));
        assert!(!target.join(".nanocua.app.new").exists());
        assert!(!target.join(".nanocua.app.old").exists());

        // A later tarball with no app leaves the signed one in place.
        std::fs::remove_dir_all(unpacked.path().join(APP)).unwrap();
        assert!(!install(unpacked.path(), &target).unwrap());
        assert_eq!(version_of(&installed), Some(vec![2, 0, 0]));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn starting_the_app_installs_its_nanocua_but_never_goes_backwards() {
        let resources = tempfile::tempdir().unwrap();
        let apps = tempfile::tempdir().unwrap();
        let installed = apps.path().join(APP);

        // A Harness build without one.
        assert!(!seed(resources.path(), apps.path()).unwrap());

        fake_app(resources.path(), "0.302.71");
        assert!(seed(resources.path(), apps.path()).unwrap());
        assert_eq!(version_of(&installed), Some(vec![0, 302, 71]));

        // Same version: nothing to do, so the signed copy isn't churned.
        assert!(!seed(resources.path(), apps.path()).unwrap());

        // A graff update moved it on: the older bundle doesn't win.
        fake_app(apps.path(), "0.302.90");
        assert!(!seed(resources.path(), apps.path()).unwrap());
        assert_eq!(version_of(&installed), Some(vec![0, 302, 90]));
    }
}
