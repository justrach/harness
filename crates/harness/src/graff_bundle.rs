//! The graff CLI shipped inside Harness.app, and the app-managed copy that
//! the app keeps up to date on its own schedule.
//!
//! - Bundled: `Harness.app/Contents/Resources/bin/graff`, fixed per app build.
//! - Managed: `~/.harness/bin/graff`, seeded from the bundle (when the bundle
//!   is newer) and replaced by [`update_managed`] from codegraff's GitHub
//!   releases, so graff can move faster than app releases. `~/.local/bin/graff`
//!   may point here, which makes the terminal `graff` the one the app runs.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Deserialize;
use sha2::{Digest, Sha256};

const RELEASES: &str = "https://github.com/justrach/codegraff/releases/download";
const LATEST_RELEASE: &str = "https://api.github.com/repos/justrach/codegraff/releases/latest";
const MAX_TARBALL_BYTES: usize = 256 * 1024 * 1024;
static UPDATE_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
}

/// `Contents/Resources/bin/graff` next to the running executable, when this
/// process is a bundled app that ships one.
pub fn bundled() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let path = exe
        .parent()? // Contents/MacOS
        .parent()? // Contents
        .join("Resources")
        .join("bin")
        .join("graff");
    path.is_file().then_some(path)
}

/// Where the app keeps its own graff (whether or not it exists yet).
pub fn managed_path() -> Option<PathBuf> {
    crate::executable::home_dir().map(|home| home.join(".harness").join("bin").join("graff"))
}

/// `graff --version`'s dotted number as integers (`0.0.302.4` → [0,0,302,4]),
/// compared element-wise; semver can't hold graff's fourth component.
pub fn version_of(path: &Path) -> Option<Vec<u64>> {
    let output = std::process::Command::new(path)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    parse_dotted(&String::from_utf8_lossy(&output.stdout))
}

fn parse_dotted(text: &str) -> Option<Vec<u64>> {
    text.split_whitespace().find_map(|word| {
        let parts: Option<Vec<u64>> = word
            .trim_start_matches('v')
            .split('-')
            .next()?
            .split('.')
            .map(|part| part.parse().ok())
            .collect();
        parts.filter(|parts| parts.len() >= 3)
    })
}

pub fn display_version(version: &[u64]) -> String {
    version
        .iter()
        .map(u64::to_string)
        .collect::<Vec<_>>()
        .join(".")
}

fn installed_beta_tag(managed: &Path) -> Option<String> {
    if !managed.is_file() {
        return None;
    }
    let output = std::process::Command::new(managed)
        .arg("--version")
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .find_map(|word| {
            let tag = format!("v{}", word.trim_start_matches('v'));
            crate::graff_beta::beta_key(&tag).map(|_| tag)
        })
}

fn current_is_at_least_target(
    current: Option<&[u64]>,
    current_beta: Option<&str>,
    target: &[u64],
    target_beta: Option<&str>,
) -> bool {
    match target_beta {
        Some(target_beta) => match current_beta {
            Some(current_beta) => {
                crate::graff_beta::beta_key(current_beta)
                    >= crate::graff_beta::beta_key(target_beta)
            }
            None => current.is_some_and(|current| current >= target),
        },
        None => current_beta.is_none() && current.is_some_and(|current| current >= target),
    }
}

/// Copy the bundled graff over the managed one when the managed copy is
/// missing or older. Returns the managed path when one is in place.
pub fn seed_managed() -> std::io::Result<Option<PathBuf>> {
    let Some(managed) = managed_path() else {
        return Ok(None);
    };
    let Some(bundled) = bundled() else {
        return Ok(managed.is_file().then_some(managed));
    };
    if installed_beta_tag(&managed).is_some() {
        return Ok(Some(managed));
    }
    let stale = match (version_of(&bundled), version_of(&managed)) {
        (_, None) => true,
        (Some(bundled), Some(managed)) => bundled > managed,
        (None, Some(_)) => false,
    };
    if stale {
        install_file(&bundled, &managed)?;
    }
    Ok(Some(managed))
}

/// Atomic replace: copy beside the target, mark executable, rename over it —
/// a running `graff acp` keeps its (unlinked) inode.
fn install_file(source: &Path, target: &Path) -> std::io::Result<()> {
    let dir = target.parent().expect("managed path has a parent");
    std::fs::create_dir_all(dir)?;
    let staged = dir.join(format!(".graff.{}.tmp", uuid::Uuid::new_v4()));
    std::fs::copy(source, &staged)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o755))?;
    }
    std::fs::rename(&staged, target)
}

/// codegraff's release asset for this machine (`graff-aarch64-macos.tar.gz`).
fn asset_name() -> Option<String> {
    let arch = match std::env::consts::ARCH {
        "aarch64" => "aarch64",
        "x86_64" => "x86_64",
        _ => return None,
    };
    let os = match std::env::consts::OS {
        "macos" => "macos",
        "linux" => "linux",
        _ => return None,
    };
    Some(format!("graff-{arch}-{os}.tar.gz"))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateOutcome {
    Updated { from: Option<String>, to: String },
    AlreadyCurrent { version: String },
}

/// Check CodeGraff's latest stable GitHub release before fetching any assets.
/// GitHub's `/releases/latest` excludes prereleases, so an automatic update
/// never silently changes the user to a beta channel.
pub async fn check_and_update_managed() -> anyhow::Result<UpdateOutcome> {
    let managed = managed_path().ok_or_else(|| anyhow::anyhow!("no home directory"))?;
    if let Some(tag) = installed_beta_tag(&managed) {
        return Ok(UpdateOutcome::AlreadyCurrent { version: tag });
    }
    let client = reqwest::Client::builder()
        .user_agent("harness-graff-updater")
        .timeout(Duration::from_secs(15 * 60))
        .build()?;
    let release: GitHubRelease = client
        .get(LATEST_RELEASE)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    let latest = parse_dotted(&release.tag_name)
        .ok_or_else(|| anyhow::anyhow!("CodeGraff release has an invalid version tag"))?;
    anyhow::ensure!(
        release
            .tag_name
            .strip_prefix('v')
            .and_then(crate::graff_beta::numeric_version)
            .is_some(),
        "CodeGraff release has an invalid stable version tag"
    );
    if let Some(current) = version_of(&managed)
        && current >= latest
    {
        return Ok(UpdateOutcome::AlreadyCurrent {
            version: display_version(&current),
        });
    }
    let outcome = install_release(&client, &release.tag_name, false, false).await?;
    if matches!(outcome, UpdateOutcome::Updated { .. }) {
        crate::executable::invalidate_versions(&["graff"]);
    }
    Ok(outcome)
}

/// Download the latest graff release, verify it against the release's
/// SHA256SUMS, check the binary runs, and swap it in as the managed copy.
pub async fn update_managed() -> anyhow::Result<UpdateOutcome> {
    let client = reqwest::Client::builder()
        .user_agent("harness-graff-updater")
        .timeout(Duration::from_secs(15 * 60))
        .build()?;
    let release: GitHubRelease = client
        .get(LATEST_RELEASE)
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    anyhow::ensure!(
        release
            .tag_name
            .strip_prefix('v')
            .and_then(crate::graff_beta::numeric_version)
            .is_some(),
        "invalid stable release tag"
    );
    install_release(&client, &release.tag_name, false, true).await
}

/// Explicit opt-in to the newest published beta of the newest release branch.
/// The app's background updater will leave this channel alone on later launches.
pub async fn update_managed_beta() -> anyhow::Result<UpdateOutcome> {
    anyhow::ensure!(
        !std::env::var_os("GRAFF_EXECUTABLE").is_some_and(|value| !value.is_empty()),
        "a custom Graff executable is selected; unset GRAFF_EXECUTABLE to use the managed beta"
    );
    let client = reqwest::Client::builder()
        .user_agent("harness-graff-updater")
        .timeout(Duration::from_secs(15 * 60))
        .build()?;
    let tag = crate::graff_beta::latest_tag(&client).await?;
    install_release(&client, &tag, true, true).await
}

async fn install_release(
    client: &reqwest::Client,
    tag: &str,
    beta: bool,
    allow_channel_switch: bool,
) -> anyhow::Result<UpdateOutcome> {
    let _lock = UPDATE_LOCK.lock().await;
    let managed = managed_path().ok_or_else(|| anyhow::anyhow!("no home directory"))?;
    if !beta
        && !allow_channel_switch
        && let Some(tag) = installed_beta_tag(&managed)
    {
        return Ok(UpdateOutcome::AlreadyCurrent { version: tag });
    }
    let asset = asset_name().ok_or_else(|| anyhow::anyhow!("no graff build for this platform"))?;
    let url = format!("{RELEASES}/{tag}");
    let sums = client
        .get(format!("{url}/SHA256SUMS"))
        .send()
        .await?
        .error_for_status()?
        .text()
        .await?;
    let expected = expected_sha(&sums, &asset)
        .ok_or_else(|| anyhow::anyhow!("{asset} is missing from the release's SHA256SUMS"))?;
    let mut response = client
        .get(format!("{url}/{asset}"))
        .send()
        .await?
        .error_for_status()?;
    let mut tarball = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        anyhow::ensure!(
            tarball.len().saturating_add(chunk.len()) <= MAX_TARBALL_BYTES,
            "graff download is unexpectedly large"
        );
        tarball.extend_from_slice(&chunk);
    }
    let actual = format!("{:x}", Sha256::digest(&tarball));
    anyhow::ensure!(
        actual == expected,
        "checksum mismatch for {asset} (expected {expected}, got {actual})"
    );

    let tag = tag.to_string();
    let outcome = tokio::task::spawn_blocking(move || -> anyhow::Result<UpdateOutcome> {
        let parent = managed.parent().expect("managed path has a parent");
        std::fs::create_dir_all(parent)?;
        let work = parent.join(format!(".graff-update.{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&work)?;
        let result = (|| {
            let archive = work.join(&asset);
            std::fs::write(&archive, &tarball)?;
            let status = std::process::Command::new("tar")
                .arg("-xzf")
                .arg(&archive)
                .arg("-C")
                .arg(&work)
                .status()?;
            anyhow::ensure!(status.success(), "couldn't unpack {asset}");
            // Release tarballs nest `graff-<target>/graff`; hand-repacked ones
            // put it at the root.
            let nested = work.join(asset.trim_end_matches(".tar.gz")).join("graff");
            let binary = if nested.is_file() {
                nested
            } else {
                work.join("graff")
            };
            anyhow::ensure!(binary.is_file(), "{asset} has no graff binary");
            let fetched = version_of(&binary)
                .ok_or_else(|| anyhow::anyhow!("the downloaded graff didn't run"))?;
            if beta {
                anyhow::ensure!(
                    installed_beta_tag(&binary).as_deref() == Some(tag.as_str()),
                    "downloaded graff version does not match {tag}"
                );
            }
            // Recheck after the download so overlapping manual and automatic
            // updates cannot replace a newer managed copy with an older one.
            let current = version_of(&managed);
            let old_beta = installed_beta_tag(&managed);
            if !beta
                && !allow_channel_switch
                && let Some(old_beta) = old_beta.as_deref()
            {
                return Ok(UpdateOutcome::AlreadyCurrent {
                    version: old_beta.to_string(),
                });
            }
            if beta
                && current_is_at_least_target(
                    current.as_deref(),
                    old_beta.as_deref(),
                    &fetched,
                    Some(&tag),
                )
            {
                if let Some(old_beta) = old_beta {
                    return Ok(UpdateOutcome::AlreadyCurrent { version: old_beta });
                }
                anyhow::bail!(
                    "the installed stable Graff is at least as new as the available beta"
                );
            }
            if !beta
                && current_is_at_least_target(
                    current.as_deref(),
                    old_beta.as_deref(),
                    &fetched,
                    None,
                )
            {
                return Ok(UpdateOutcome::AlreadyCurrent {
                    version: display_version(current.as_deref().unwrap_or(&fetched)),
                });
            }
            install_file(&binary, &managed)?;
            Ok(UpdateOutcome::Updated {
                from: current.as_deref().map(display_version),
                to: if beta {
                    tag.clone()
                } else {
                    display_version(&fetched)
                },
            })
        })();
        let _ = std::fs::remove_dir_all(&work);
        result
    })
    .await??;
    if matches!(outcome, UpdateOutcome::Updated { .. }) {
        crate::executable::invalidate_versions(&["graff"]);
    }
    Ok(outcome)
}

fn expected_sha(sums: &str, asset: &str) -> Option<String> {
    sums.lines().find_map(|line| {
        let mut fields = line.split_whitespace();
        let sha = fields.next()?;
        let name = fields.next()?.trim_start_matches('*');
        (name == asset && sha.len() == 64).then(|| sha.to_ascii_lowercase())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dotted_versions_compare_all_four_parts() {
        let current = parse_dotted("graff 0.0.302.4\n\nWhat's new").unwrap();
        assert_eq!(current, vec![0, 0, 302, 4]);
        assert!(parse_dotted("graff 0.0.302.10").unwrap() > current);
        assert!(parse_dotted("graff 0.0.303.0").unwrap() > current);
        assert_eq!(display_version(&current), "0.0.302.4");
        assert_eq!(
            parse_dotted("graff 0.0.302.6-beta.26.1"),
            Some(vec![0, 0, 302, 6])
        );
        assert!(parse_dotted("no version here").is_none());
    }

    #[test]
    #[cfg(unix)]
    fn beta_channel_is_read_from_the_installed_binary() {
        let dir = tempfile::tempdir().unwrap();
        let managed = dir.path().join("graff");
        assert_eq!(installed_beta_tag(&managed), None);
        std::fs::write(&managed, "#!/bin/sh\necho 'graff 0.0.302.6-beta.26.1'\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&managed, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            installed_beta_tag(&managed).as_deref(),
            Some("v0.0.302.6-beta.26.1")
        );
    }

    #[test]
    fn beta_update_does_not_downgrade_stable_or_newer_beta() {
        let stable = [0, 0, 302, 6];
        let previous = [0, 0, 302, 5];
        let target = "v0.0.302.6-beta.26.1";
        assert!(current_is_at_least_target(
            Some(&stable),
            None,
            &stable,
            Some(target)
        ));
        assert!(!current_is_at_least_target(
            Some(&previous),
            None,
            &stable,
            Some(target)
        ));
        assert!(current_is_at_least_target(
            Some(&stable),
            Some("v0.0.302.6-beta.27.1"),
            &stable,
            Some(target)
        ));
        assert!(!current_is_at_least_target(
            Some(&stable),
            Some("v0.0.302.6-beta.25.1"),
            &stable,
            Some(target)
        ));
        assert!(!current_is_at_least_target(
            Some(&stable),
            Some(target),
            &stable,
            None
        ));
    }

    #[test]
    fn checksum_lines_match_the_exact_asset() {
        let sums = "aa  graff-x86_64-macos.tar.gz\n\
                    a80b48c5f8ddf124a5c679c475819a506dfdc5ad8f47b76db9aacc2a2fff1268  graff-aarch64-macos.tar.gz\n";
        assert_eq!(
            expected_sha(sums, "graff-aarch64-macos.tar.gz").as_deref(),
            Some("a80b48c5f8ddf124a5c679c475819a506dfdc5ad8f47b76db9aacc2a2fff1268")
        );
        assert!(expected_sha(sums, "graff-x86_64-macos.tar.gz").is_none());
        assert!(expected_sha(sums, "graff-aarch64-linux.tar.gz").is_none());
    }

    /// Network: `cargo test -p harness-adapters graff_bundle -- --ignored`.
    /// Touches the real ~/.harness/bin/graff.
    #[tokio::test]
    #[ignore]
    async fn update_managed_fetches_and_verifies_the_latest_release() {
        let outcome = update_managed().await.unwrap();
        eprintln!("{outcome:?}");
        assert!(version_of(&managed_path().unwrap()).is_some());
    }

    #[test]
    fn install_replaces_atomically_and_marks_executable() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("src");
        std::fs::write(&source, "new").unwrap();
        let target = dir.path().join("bin").join("graff");
        install_file(&source, &target).unwrap();
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "new");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                target.metadata().unwrap().permissions().mode() & 0o777,
                0o755
            );
        }
    }
}
