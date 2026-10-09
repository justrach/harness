//! The codedb CLI that Harness keeps for its agents, the way it keeps graff.
//!
//! - Bundled: `Harness.app/Contents/Resources/bin/codedb`, fixed per app
//!   build (`scripts/package-macos.sh`), so agents have codedb from the first
//!   launch, offline included.
//! - Managed: `~/.harness/tools/bin/codedb`, seeded from the bundle when the
//!   bundle is newer, otherwise installed from codedb's GitHub
//!   releases when missing and replaced when a newer release is out. Every
//!   asset is checked against the release's `checksums.sha256` and must run
//!   `--version` before it is swapped in.
//! - Agents find it on `PATH`: [`crate::compose_path`] appends
//!   `~/.harness/tools/bin`, after the user's own directories, so a codedb
//!   the user installed themselves still wins. Not `~/.harness/bin`: a graff
//!   session puts graff's own directory first, which would shadow theirs.
//!
//! Set `HARNESS_CODEDB_AUTO_INSTALL=0` to leave codedb alone entirely.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use sha2::{Digest, Sha256};

const RELEASES: &str = "https://github.com/justrach/codedb/releases/download";
const LATEST_RELEASE: &str = "https://api.github.com/repos/justrach/codedb/releases/latest";
const MAX_ASSET_BYTES: usize = 256 * 1024 * 1024;
static INSTALL_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Installed { from: Option<String>, to: String },
    Current { version: String },
}

fn binary_name() -> &'static str {
    if cfg!(windows) {
        "codedb.exe"
    } else {
        "codedb"
    }
}

/// Where Harness keeps its codedb (whether or not it exists yet).
pub fn managed_path() -> Option<PathBuf> {
    crate::executable::home_dir().map(|home| {
        home.join(".harness")
            .join("tools")
            .join("bin")
            .join(binary_name())
    })
}

/// `Contents/Resources/bin/codedb` next to the running executable, when this
/// process is an app bundle that ships one.
pub fn bundled() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let path = exe
        .parent()? // Contents/MacOS
        .parent()? // Contents
        .join("Resources")
        .join("bin")
        .join(binary_name());
    path.is_file().then_some(path)
}

/// Copy the bundled codedb into place when the managed copy is missing or
/// older than it. No network: agents get codedb on an offline first launch.
pub fn seed_managed() -> anyhow::Result<Option<Outcome>> {
    let (Some(bundled), Some(managed)) = (bundled(), managed_path()) else {
        return Ok(None);
    };
    let Some(shipped) = version_of(&bundled) else {
        return Ok(None);
    };
    let current = version_of(&managed);
    if current.as_ref().is_some_and(|current| *current >= shipped) {
        return Ok(None);
    }
    install_bytes(&std::fs::read(&bundled)?, &managed)?;
    Ok(Some(Outcome::Installed {
        from: current.as_deref().map(display),
        to: display(&shipped),
    }))
}

/// Whether Harness may install or update codedb.
pub fn auto_install_enabled() -> bool {
    !std::env::var("HARNESS_CODEDB_AUTO_INSTALL").is_ok_and(|value| {
        matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "no" | "off"
        )
    })
}

/// codedb's release asset for this machine (`codedb-darwin-arm64`).
fn asset_name() -> Option<&'static str> {
    Some(match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => "codedb-darwin-arm64",
        ("macos", "x86_64") => "codedb-darwin-x86_64",
        ("linux", "aarch64") => "codedb-linux-arm64",
        ("linux", "x86_64") => "codedb-linux-x86_64",
        ("windows", "x86_64") => "codedb-windows-x86_64.exe",
        _ => return None,
    })
}

/// `0.2.5860` / `v0.2.5860` / `codedb 0.2.5860` → `[0, 2, 5860]`.
fn parse_version(text: &str) -> Option<Vec<u64>> {
    text.split_whitespace().find_map(|word| {
        let parts: Option<Vec<u64>> = word
            .trim_start_matches('v')
            .split('.')
            .map(|part| part.parse().ok())
            .collect();
        parts.filter(|parts| parts.len() >= 2)
    })
}

fn display(version: &[u64]) -> String {
    version
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(".")
}

/// The version an installed codedb reports, if it runs at all.
pub fn version_of(path: &Path) -> Option<Vec<u64>> {
    let output = std::process::Command::new(path)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_version(&String::from_utf8_lossy(&output.stdout))
}

/// The SHA-256 the release lists for `asset`.
fn listed_checksum(checksums: &str, asset: &str) -> Option<String> {
    checksums.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let digest = parts.next()?;
        let name = parts.next()?.trim_start_matches('*');
        (name == asset && digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
            .then(|| digest.to_ascii_lowercase())
    })
}

fn client() -> reqwest::Result<reqwest::Client> {
    reqwest::Client::builder()
        .user_agent("harness-codedb-installer")
        .timeout(Duration::from_secs(10 * 60))
        .build()
}

async fn latest_release(client: &reqwest::Client) -> anyhow::Result<(String, Vec<u64>)> {
    let release: GitHubRelease = client
        .get(LATEST_RELEASE)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let version = parse_version(&release.tag_name)
        .ok_or_else(|| anyhow::anyhow!("codedb release has an invalid version tag"))?;
    Ok((release.tag_name, version))
}

async fn fetch(client: &reqwest::Client, url: &str) -> anyhow::Result<Vec<u8>> {
    let bytes = client
        .get(url)
        .send()
        .await?
        .error_for_status()?
        .bytes()
        .await?;
    anyhow::ensure!(
        bytes.len() <= MAX_ASSET_BYTES,
        "codedb download is too large"
    );
    Ok(bytes.to_vec())
}

/// Install codedb when it is missing, or replace it when a newer release is
/// out. A failed check leaves the installed copy untouched.
pub async fn ensure_managed() -> anyhow::Result<Outcome> {
    let _lock = INSTALL_LOCK.lock().await;
    let managed = managed_path().ok_or_else(|| anyhow::anyhow!("no home directory"))?;
    let asset = asset_name().ok_or_else(|| anyhow::anyhow!("no codedb build for this platform"))?;
    let client = client()?;
    let (tag, latest) = latest_release(&client).await?;
    let current = version_of(&managed);
    if let Some(current) = &current
        && *current >= latest
    {
        return Ok(Outcome::Current {
            version: display(current),
        });
    }
    let checksums =
        String::from_utf8(fetch(&client, &format!("{RELEASES}/{tag}/checksums.sha256")).await?)?;
    let expected = listed_checksum(&checksums, asset)
        .ok_or_else(|| anyhow::anyhow!("codedb {tag} lists no checksum for {asset}"))?;
    let bytes = fetch(&client, &format!("{RELEASES}/{tag}/{asset}")).await?;
    let actual = format!("{:x}", Sha256::digest(&bytes));
    anyhow::ensure!(
        actual == expected,
        "codedb {tag} download failed its checksum"
    );
    install_bytes(&bytes, &managed)?;
    Ok(Outcome::Installed {
        from: current.as_deref().map(display),
        to: display(&latest),
    })
}

/// Stage beside the target, require the staged binary to run, then rename
/// over it, so a codedb an agent is running keeps its (unlinked) inode.
fn install_bytes(bytes: &[u8], target: &Path) -> anyhow::Result<()> {
    let dir = target
        .parent()
        .ok_or_else(|| anyhow::anyhow!("managed codedb path has no parent"))?;
    std::fs::create_dir_all(dir)?;
    let staged = dir.join(format!(".codedb.{}.tmp", uuid::Uuid::new_v4()));
    std::fs::write(&staged, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
    }
    if version_of(&staged).is_none() {
        let _ = std::fs::remove_file(&staged);
        anyhow::bail!("the downloaded codedb does not run on this computer");
    }
    std::fs::rename(&staged, target).inspect_err(|_| {
        let _ = std::fs::remove_file(&staged);
    })?;
    Ok(())
}

/// How often a long-running Harness looks for a newer codedb: graff's cadence.
pub const CHECK_INTERVAL: Duration = Duration::from_secs(60 * 60);
const INITIAL_DELAY: Duration = Duration::from_secs(30);

/// When the last codedb check started; the hourly loop and
/// [`maybe_check_soon`] share it so they never overlap.
static LAST_CHECK: std::sync::Mutex<Option<std::time::Instant>> = std::sync::Mutex::new(None);
const CHECK_DEBOUNCE: Duration = Duration::from_secs(10 * 60);

fn claim_check() -> bool {
    let mut last = LAST_CHECK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if last.is_some_and(|when| when.elapsed() < CHECK_DEBOUNCE) {
        return false;
    }
    *last = Some(std::time::Instant::now());
    true
}

/// Check for a newer codedb now, as graff's updater does: when a graff
/// session starts and when graff itself was just updated. At most one check
/// every ten minutes; never blocks, and does nothing without a tokio runtime.
pub fn maybe_check_soon() {
    if !auto_install_enabled() {
        return;
    }
    let Ok(handle) = tokio::runtime::Handle::try_current() else {
        return;
    };
    if !claim_check() {
        return;
    }
    handle.spawn(async {
        match ensure_managed().await {
            Ok(Outcome::Installed { from, to }) => {
                tracing::info!(?from, %to, "codedb updated from its GitHub release");
            }
            Ok(Outcome::Current { .. }) => {}
            Err(error) => tracing::warn!(%error, "codedb update check failed"),
        }
    });
}

/// Keep codedb installed and current for the life of the process, on the
/// current tokio runtime. Never blocks start-up.
pub async fn keep_current() {
    if !auto_install_enabled() {
        return;
    }
    match seed_managed() {
        Ok(Some(Outcome::Installed { from, to })) => {
            tracing::info!(?from, %to, "codedb installed from the app bundle");
        }
        Ok(_) => {}
        Err(error) => tracing::warn!(%error, "couldn't install the bundled codedb"),
    }
    tokio::time::sleep(INITIAL_DELAY).await;
    loop {
        claim_check();
        match ensure_managed().await {
            Ok(Outcome::Installed { from, to }) => {
                tracing::info!(?from, %to, "codedb installed from its GitHub release");
            }
            Ok(Outcome::Current { version }) => tracing::debug!(%version, "codedb is current"),
            Err(error) => tracing::warn!(%error, "codedb install check failed"),
        }
        tokio::time::sleep(CHECK_INTERVAL).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_parse_from_tags_and_cli_output() {
        assert_eq!(parse_version("v0.2.5860"), Some(vec![0, 2, 5860]));
        assert_eq!(parse_version("codedb 0.2.5860\n"), Some(vec![0, 2, 5860]));
        assert_eq!(parse_version("codedb dev"), None);
        assert!(parse_version("v0.2.5860") > parse_version("0.2.5859"));
    }

    #[test]
    fn the_checksum_is_the_one_listed_for_this_asset() {
        let list = "\
fd8568a0bd9cb73583cf20b6f0a817cef44795b250a98391419ef7c8049f7518  codedb-darwin-arm64
af44d5f02a6c9a2890368993d47ff7a7fa7250ddd22785e4e9cb2fbcaa3a7d0e *codedb-linux-x86_64
not-a-digest  codedb-linux-arm64
";
        assert_eq!(
            listed_checksum(list, "codedb-darwin-arm64").as_deref(),
            Some("fd8568a0bd9cb73583cf20b6f0a817cef44795b250a98391419ef7c8049f7518")
        );
        assert!(listed_checksum(list, "codedb-linux-x86_64").is_some());
        assert_eq!(listed_checksum(list, "codedb-linux-arm64"), None);
        assert_eq!(listed_checksum(list, "codedb-darwin-x86_64"), None);
    }

    #[test]
    fn a_binary_that_does_not_run_is_never_installed() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("bin").join("codedb");
        assert!(install_bytes(b"not a program", &target).is_err());
        assert!(!target.exists());
        let leftovers = std::fs::read_dir(dir.path().join("bin")).unwrap().count();
        assert_eq!(leftovers, 0, "the staged file is cleaned up");
    }

    /// Network: installs the real latest release. Run with a throwaway HOME:
    /// `HOME=$(mktemp -d) cargo test -p harness-adapters --lib codedb_bundle -- --ignored`.
    #[tokio::test]
    #[ignore]
    async fn the_latest_release_installs_then_reads_as_current() {
        let installed = ensure_managed().await.expect("install");
        assert!(
            matches!(installed, Outcome::Installed { from: None, .. }),
            "{installed:?}"
        );
        let again = ensure_managed().await.expect("check");
        assert!(matches!(again, Outcome::Current { .. }), "{again:?}");
    }

    #[cfg(unix)]
    #[test]
    fn a_runnable_binary_is_swapped_in() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("bin").join("codedb");
        install_bytes(b"#!/bin/sh\necho 'codedb 0.2.9'\n", &target).unwrap();
        assert_eq!(version_of(&target), Some(vec![0, 2, 9]));
    }
}
