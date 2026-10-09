//! harness-update — release checking and self-update, shared by the engine (the
//! background checker + `ApplyUpdate`), the CLI (`harness update`), and the UI
//! (the sidebar update strip + macOS bundle swap).
//!
//! Release layout (see `.github/workflows/release.yml`): the packaged macOS
//! app and managed server installs read Harness's latest stable GitHub
//! release; other installs still check `{edge}/releases/*`. `manifest.json`
//! carries the latest version plus a sha256 per artifact; `latest.txt`
//! remains a fallback for older releases.
//!
//! Install kinds and their update paths:
//! - **Managed** (`~/.harness/app/<ver>` + `current` symlink — the curl|sh
//!   installer): download the headless tarball into a new versioned dir, flip
//!   the symlink, restart the service. Same flow the installer script performs,
//!   natively.
//! - **MacApp** (running out of an app bundle): download the app tarball, swap the
//!   bundle directory, relaunch. Driven by the UI.
//! - **Unmanaged** (source builds, hand-copied binaries): report only.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context as _, bail};
use futures::StreamExt as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt as _;
use tokio::sync::watch;

#[cfg(windows)]
pub mod windows;

/// The version compiled into this binary (the workspace version).
pub const fn current_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// Background check cadence: how long after a successful check the next one is
/// due.
const CHECK_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);
/// Retry sooner after failed checks (offline boot, transient edge error):
/// 1m, 5m, 15m, then 30m for as long as they keep failing.
const CHECK_BACKOFF: [std::time::Duration; 4] = [
    std::time::Duration::from_secs(60),
    std::time::Duration::from_secs(5 * 60),
    std::time::Duration::from_secs(15 * 60),
    std::time::Duration::from_secs(30 * 60),
];
/// How often the wall clock is compared with the next due time. A monotonic
/// `sleep` stops while the machine sleeps, so a single long sleep pushes the
/// next check out by the whole night; a short tick notices on wake instead.
const CHECK_TICK: std::time::Duration = std::time::Duration::from_secs(60);
/// First check waits out engine boot (room joins, doc re-sync).
const CHECK_INITIAL_DELAY: std::time::Duration = std::time::Duration::from_secs(20);
/// While an auto-apply is deferred behind active sessions, re-probe idleness
/// this often.
const IDLE_RECHECK: std::time::Duration = std::time::Duration::from_secs(5 * 60);

// ---------------------------------------------------------------------------
// Release metadata
// ---------------------------------------------------------------------------

/// `{edge}/releases/manifest.json` — written by the release workflow.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub version: String,
    /// Artifact file name → metadata. Empty for pre-manifest releases resolved
    /// via `latest.txt` — downloads then skip checksum verification (with a log).
    #[serde(default)]
    pub files: BTreeMap<String, FileMeta>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct FileMeta {
    #[serde(default)]
    pub sha256: Option<String>,
}

/// Artifact-name platform pair matching the packaging scripts. Unsupported
/// updater targets retain their real OS name rather than impersonating Linux.
pub fn platform_key() -> (&'static str, &'static str) {
    let os = std::env::consts::OS;
    let arch = match (os, std::env::consts::ARCH) {
        ("macos", "aarch64") => "arm64",
        (_, arch) => arch,
    };
    (os, arch)
}

fn managed_updates_supported(os: &str) -> bool {
    matches!(os, "linux" | "macos")
}

fn require_managed_update_platform() -> anyhow::Result<()> {
    if !managed_updates_supported(std::env::consts::OS) {
        bail!(
            "managed updates are not supported on {}",
            std::env::consts::OS
        );
    }
    Ok(())
}

fn require_mac_app_update_platform() -> anyhow::Result<()> {
    if std::env::consts::OS != "macos" {
        bail!(
            "macOS app updates are not supported on {}",
            std::env::consts::OS
        );
    }
    Ok(())
}

/// `harness-<ver>-<os>-<arch>.tar.gz` — the headless/CLI tarball (Linux CI builds).
pub fn headless_artifact(version: &str) -> String {
    let (os, arch) = platform_key();
    format!("harness-{version}-{os}-{arch}.tar.gz")
}

/// `harness-<ver>-macos-<arch>-app.tar.gz` — the macOS app update payload.
pub fn mac_app_artifact(version: &str) -> String {
    let (_, arch) = platform_key();
    format!("harness-{version}-macos-{arch}-app.tar.gz")
}

/// Strictly-newer dotted-numeric compare (`0.1.10` > `0.1.9` > `0.1`).
/// Unparseable versions never count as newer — a garbage `latest.txt` must not
/// trigger an update loop.
pub fn version_newer(latest: &str, current: &str) -> bool {
    fn parts(v: &str) -> Option<Vec<u64>> {
        let nums: Vec<u64> = v
            .trim()
            .trim_start_matches('v')
            .split('.')
            .map(|p| p.parse().ok())
            .collect::<Option<_>>()?;
        (!nums.is_empty()).then_some(nums)
    }
    match (parts(latest), parts(current)) {
        (Some(l), Some(c)) => l > c,
        _ => false,
    }
}

/// Fetch the newest release metadata: `manifest.json`, falling back to
/// `latest.txt` (version only, no checksums) for pre-manifest releases.
pub async fn fetch_latest(edge_url: &str) -> anyhow::Result<Manifest> {
    let base = release_base(edge_url)?;
    let client = http_client()?;
    let manifest_url = format!("{base}/manifest.json");
    match client.get(&manifest_url).send().await {
        Ok(resp) if resp.status().is_success() => {
            let manifest: Manifest = resp.json().await.context("parsing manifest.json")?;
            if manifest.version.trim().is_empty() {
                bail!("manifest.json has an empty version");
            }
            return Ok(manifest);
        }
        Ok(resp) => {
            tracing::debug!(status = %resp.status(), "manifest.json unavailable; trying latest.txt")
        }
        Err(err) => tracing::debug!(error = %err, "manifest.json fetch failed; trying latest.txt"),
    }
    let latest_url = format!("{base}/latest.txt");
    let version = client
        .get(&latest_url)
        .send()
        .await
        .context("fetching latest.txt")?
        .error_for_status()
        .context("fetching latest.txt")?
        .text()
        .await
        .context("reading latest.txt")?
        .trim()
        .to_string();
    if version.is_empty() {
        bail!("latest.txt is empty");
    }
    Ok(Manifest {
        version,
        files: BTreeMap::new(),
    })
}

fn http_client() -> anyhow::Result<reqwest::Client> {
    http_client_with_timeouts(
        std::time::Duration::from_secs(15),
        std::time::Duration::from_secs(30),
    )
}

fn http_client_with_timeouts(
    connect: std::time::Duration,
    read: std::time::Duration,
) -> anyhow::Result<reqwest::Client> {
    reqwest::Client::builder()
        .connect_timeout(connect)
        // Inactivity timeout, not a total download cap: slow progressing
        // updates remain viable on constrained links.
        .read_timeout(read)
        .user_agent(concat!("harness/", env!("CARGO_PKG_VERSION")))
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 10 {
                return attempt.error("too many update redirects");
            }
            if attempt.previous().iter().any(|url| url.scheme() == "https")
                && attempt.url().scheme() != "https"
            {
                return attempt.error("update redirect would downgrade HTTPS");
            }
            attempt.follow()
        }))
        .build()
        .context("building http client")
}

fn validate_release_override(value: &str) -> anyhow::Result<String> {
    let url = reqwest::Url::parse(value.trim()).context("invalid update feed URL")?;
    anyhow::ensure!(
        url.scheme() == "https" && url.host_str().is_some(),
        "update feed must use HTTPS"
    );
    anyhow::ensure!(
        url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none(),
        "update feed must be a base URL without credentials, query, or fragment"
    );
    Ok(url.as_str().trim_end_matches('/').to_owned())
}

fn release_base(edge_url: &str) -> anyhow::Result<String> {
    if let Ok(url) = std::env::var("HARNESS_RELEASES_URL")
        && !url.trim().is_empty()
    {
        return validate_release_override(&url);
    }
    #[cfg(windows)]
    if let Some(url) = windows::release_url()? {
        return Ok(url.trim_end_matches('/').to_owned());
    }
    Ok(default_release_base(edge_url, &detect_install()))
}

fn default_release_base(edge_url: &str, install: &InstallKind) -> String {
    // The desktop app and managed server installs follow Harness's stable
    // GitHub releases: the release job attaches the manifest there next to
    // every artifact, while the edge copy only moves when its upload runs.
    if matches!(
        install,
        InstallKind::MacApp { .. } | InstallKind::Managed { .. }
    ) {
        return "https://github.com/justrach/harness/releases/latest/download".into();
    }
    format!("{}/releases", edge_url.trim_end_matches('/'))
}

// ---------------------------------------------------------------------------
// Install-kind detection
// ---------------------------------------------------------------------------

/// How this binary was installed — decides the update path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallKind {
    /// `~/.harness/app/<ver>/harness` behind the `current` symlink
    /// (curl|sh installer / a previous `harness update`).
    Managed { app_root: PathBuf },
    /// Running out of a macOS `.app` bundle.
    MacApp { bundle: PathBuf },
    /// Portable Windows package with an explicit update-feed configuration.
    #[cfg(windows)]
    WindowsPortable { directory: PathBuf },
    /// Source build or hand-copied binary — updates are report-only.
    Unmanaged,
}

impl InstallKind {
    /// Whether the engine's background checker runs for this install,
    /// signed in or not.
    pub fn checks_releases(&self) -> bool {
        matches!(self, Self::MacApp { .. } | Self::Managed { .. })
    }

    pub fn supports_desktop_update(&self) -> bool {
        match self {
            Self::MacApp { .. } => true,
            #[cfg(windows)]
            Self::WindowsPortable { .. } => true,
            _ => false,
        }
    }

    pub async fn stage_desktop(
        &self,
        edge_url: &str,
        manifest: &Manifest,
        data_dir: &Path,
    ) -> anyhow::Result<PathBuf> {
        match self {
            Self::MacApp { .. } => stage_mac_app(edge_url, manifest, data_dir).await,
            #[cfg(windows)]
            Self::WindowsPortable { directory } => {
                windows::stage(edge_url, manifest, directory).await
            }
            _ => bail!("this installation does not support desktop updates"),
        }
    }

    /// Swap the staged bundle over the installed one without relaunching —
    /// the process is quitting anyway, so the next launch runs the new
    /// version. Non-desktop installs are a no-op.
    pub fn install_on_exit(&self, staged: &Path) -> anyhow::Result<()> {
        match self {
            Self::MacApp { bundle } => apply_mac_app(staged, bundle),
            #[cfg(windows)]
            Self::WindowsPortable { directory } => windows::apply(staged, directory, false),
            _ => Ok(()),
        }
    }

    /// Install and arrange a relaunch. The UI must quit after this succeeds.
    pub fn apply_desktop(&self, staged: &Path) -> anyhow::Result<()> {
        match self {
            Self::MacApp { bundle } => {
                apply_mac_app(staged, bundle)?;
                relaunch_app_after_exit(bundle);
                Ok(())
            }
            #[cfg(windows)]
            Self::WindowsPortable { directory } => windows::apply(staged, directory, true),
            _ => bail!("this installation does not support desktop updates"),
        }
    }
}

pub fn detect_install() -> InstallKind {
    let Ok(exe) = std::env::current_exe() else {
        return InstallKind::Unmanaged;
    };
    let home = std::env::var_os("HOME").map(PathBuf::from);
    detect_install_from(&exe, home.as_deref())
}

fn detect_install_from(exe: &Path, home: Option<&Path>) -> InstallKind {
    detect_install_from_for_os(exe, home, std::env::consts::OS)
}

fn detect_install_from_for_os(exe: &Path, home: Option<&Path>, os: &str) -> InstallKind {
    #[cfg(windows)]
    if os == "windows" && windows::is_managed(exe) {
        return InstallKind::WindowsPortable {
            directory: exe.parent().unwrap().to_owned(),
        };
    }
    // Never interpret a coincidental Windows `%HOME%\.harness\app` layout as
    // the Unix symlink-managed installation.
    if !managed_updates_supported(os) {
        return InstallKind::Unmanaged;
    }
    if let Some(home) = home {
        // `current_exe` resolves the `current` symlink to the versioned dir.
        let app_root = home.join(".harness").join("app");
        if exe.starts_with(&app_root) {
            return InstallKind::Managed { app_root };
        }
    }
    for ancestor in exe.ancestors() {
        if ancestor.extension().is_some_and(|ext| ext == "app")
            && exe.starts_with(ancestor.join("Contents").join("MacOS"))
        {
            return InstallKind::MacApp {
                bundle: ancestor.to_path_buf(),
            };
        }
    }
    InstallKind::Unmanaged
}

// ---------------------------------------------------------------------------
// Download + verify
// ---------------------------------------------------------------------------

/// Stream `{edge}/releases/<file>` to `dest`, verifying the manifest sha256 when
/// present. Writes through a `.partial` sidecar so an interrupted download never
/// leaves a plausible-looking artifact behind.
pub async fn download_release_file(
    edge_url: &str,
    manifest: &Manifest,
    file: &str,
    dest: &Path,
) -> anyhow::Result<()> {
    let url = format!("{}/{file}", release_base(edge_url)?);
    let expected = manifest.files.get(file).and_then(|m| m.sha256.as_deref());
    if expected.is_none() {
        tracing::warn!(
            file,
            "no checksum in release metadata; skipping verification"
        );
    }
    let partial = dest.with_extension("partial");
    let resp = http_client()?
        .get(&url)
        .send()
        .await
        .with_context(|| format!("downloading {url}"))?
        .error_for_status()
        .with_context(|| format!("downloading {url}"))?;
    let mut out = tokio::fs::File::create(&partial)
        .await
        .with_context(|| format!("creating {}", partial.display()))?;
    let mut hasher = Sha256::new();
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("reading download stream")?;
        hasher.update(&chunk);
        out.write_all(&chunk).await.context("writing download")?;
    }
    out.flush().await.ok();
    drop(out);
    if let Some(expected) = expected {
        let actual = format!("{:x}", hasher.finalize());
        if !actual.eq_ignore_ascii_case(expected.trim()) {
            tokio::fs::remove_file(&partial).await.ok();
            bail!("checksum mismatch for {file}: expected {expected}, got {actual}");
        }
    }
    tokio::fs::rename(&partial, dest)
        .await
        .with_context(|| format!("moving {} into place", dest.display()))?;
    Ok(())
}

fn run(program: &str, args: &[&str]) -> anyhow::Result<()> {
    let output = std::process::Command::new(program)
        .args(args)
        .output()
        .with_context(|| format!("running {program}"))?;
    if !output.status.success() {
        bail!(
            "{program} {} failed ({}): {}",
            args.join(" "),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Managed (symlink) installs — the daemon/VPS path
// ---------------------------------------------------------------------------

/// Download + unpack the headless tarball into `app_root/<ver>` (idempotent —
/// an already-staged version is reused). Returns the versioned dir.
pub async fn stage_headless(
    edge_url: &str,
    manifest: &Manifest,
    app_root: &Path,
) -> anyhow::Result<PathBuf> {
    // Reject unsupported targets before creating a stage or making a request.
    require_managed_update_platform()?;
    let version = &manifest.version;
    let dest = app_root.join(version);
    if dest.join("harness").exists() {
        return Ok(dest);
    }
    let file = headless_artifact(version);
    let stage = app_root.join(format!(".stage-{version}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(&stage).with_context(|| format!("creating {}", stage.display()))?;
    let result = async {
        let tarball = stage.join(&file);
        download_release_file(edge_url, manifest, &file, &tarball).await?;
        let unpacked = stage.join("unpacked");
        std::fs::create_dir_all(&unpacked)?;
        // Tarball root is the versioned stage dir (see scripts/package-linux.sh);
        // strip it exactly as install.sh does.
        run(
            "tar",
            &[
                "-xzf",
                &tarball.to_string_lossy(),
                "-C",
                &unpacked.to_string_lossy(),
                "--strip-components=1",
            ],
        )?;
        if !unpacked.join("harness").is_file() {
            bail!("tarball {file} did not contain a harness binary");
        }
        match std::fs::rename(&unpacked, &dest) {
            Ok(()) => {}
            // Lost a race with another stager — the staged copy is equivalent.
            Err(_) if dest.join("harness").exists() => {}
            Err(err) => {
                return Err(err).with_context(|| format!("moving {} into place", dest.display()));
            }
        }
        Ok(dest.clone())
    }
    .await;
    let _ = std::fs::remove_dir_all(&stage);
    result
}

/// Atomically repoint `app_root/current` at `app_root/<ver>` (symlink to a temp
/// name, then rename over — never a window with no `current`).
pub fn apply_headless(app_root: &Path, version: &str) -> anyhow::Result<()> {
    #[cfg(unix)]
    {
        let target = app_root.join(version);
        if !target.join("harness").exists() {
            bail!("{} is not a staged install", target.display());
        }
        let tmp = app_root.join(format!(".current-{}", std::process::id()));
        let _ = std::fs::remove_file(&tmp);
        std::os::unix::fs::symlink(&target, &tmp).context("creating current symlink")?;
        std::fs::rename(&tmp, app_root.join("current")).context("swapping current symlink")?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = (app_root, version);
        require_managed_update_platform()?;
        unreachable!("supported managed-update platforms are Unix")
    }
}

/// Restart the installed engine service (the same units `harness daemon` and the
/// curl|sh installer manage). Called after a symlink swap so the running daemon
/// picks up the new binary.
pub fn restart_service() -> anyhow::Result<()> {
    require_managed_update_platform()?;
    if cfg!(target_os = "macos") {
        let output = std::process::Command::new("id").arg("-u").output()?;
        let uid = String::from_utf8_lossy(&output.stdout).trim().to_string();
        run(
            "launchctl",
            &["kickstart", "-k", &format!("gui/{uid}/harness.codegraff.app")],
        )
    } else {
        run("systemctl", &["--user", "restart", "harness.service"])
    }
}

// ---------------------------------------------------------------------------
// macOS app-bundle installs — the desktop path
// ---------------------------------------------------------------------------

/// Download + unpack the app tarball into `{data_dir}/updates/<ver>/Harness.app`
/// (idempotent). Returns the staged bundle path.
pub async fn stage_mac_app(
    edge_url: &str,
    manifest: &Manifest,
    data_dir: &Path,
) -> anyhow::Result<PathBuf> {
    // Reject unsupported targets before creating a stage or making a request.
    require_mac_app_update_platform()?;
    let version = &manifest.version;
    let file = mac_app_artifact(version);
    anyhow::ensure!(
        manifest.files.get(&file).and_then(|meta| meta.sha256.as_deref()).is_some(),
        "stable macOS update is missing the {file} checksum"
    );
    let dir = data_dir.join("updates").join(version);
    if let Some(staged) = staged_mac_app(&dir) {
        return Ok(staged);
    }
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let tarball = dir.join(&file);
    download_release_file(edge_url, manifest, &file, &tarball).await?;
    run(
        "tar",
        &[
            "-xzf",
            &tarball.to_string_lossy(),
            "-C",
            &dir.to_string_lossy(),
        ],
    )?;
    std::fs::remove_file(&tarball).ok();
    staged_mac_app(&dir).ok_or_else(|| anyhow::anyhow!("app tarball {file} did not contain Harness.app"))
}

fn mac_app_has_executable(bundle: &Path) -> bool {
    let macos = bundle.join("Contents/MacOS");
    macos.join("harness").exists() || macos.join("harness").exists()
}

fn staged_mac_app(dir: &Path) -> Option<PathBuf> {
    for name in ["Harness.app", "Harnesser.app", "Harness.app"] {
        let staged = dir.join(name);
        if mac_app_has_executable(&staged) {
            return Some(staged);
        }
    }
    None
}

/// Swap the installed bundle for the staged one: `ditto` the staged copy next to
/// the target (metadata-preserving, cross-volume safe), then two renames — the
/// old bundle is restored if the second rename fails.
pub fn apply_mac_app(staged: &Path, bundle: &Path) -> anyhow::Result<()> {
    require_mac_app_update_platform()?;
    let parent = bundle
        .parent()
        .context("app bundle has no parent directory")?;
    let name = bundle
        .file_name()
        .context("app bundle has no name")?
        .to_string_lossy();
    let pid = std::process::id();
    let fresh = parent.join(format!(".{name}.new-{pid}"));
    let old = parent.join(format!(".{name}.old-{pid}"));
    let _ = std::fs::remove_dir_all(&fresh);
    run(
        "ditto",
        &[&staged.to_string_lossy(), &fresh.to_string_lossy()],
    )?;
    std::fs::rename(bundle, &old).context("moving the current app aside")?;
    if let Err(err) = std::fs::rename(&fresh, bundle) {
        let _ = std::fs::rename(&old, bundle);
        let _ = std::fs::remove_dir_all(&fresh);
        return Err(err).context("installing the new app bundle");
    }
    let _ = std::fs::remove_dir_all(&old);
    Ok(())
}

/// Detached relauncher: waits for THIS process to exit, then `open`s the bundle.
/// (Opening before exit would race the single-instance engine lock and the IPC
/// port.) The caller quits the app after this returns.
pub fn relaunch_app_after_exit(bundle: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        let pid = std::process::id();
        let script = format!(
            "while /bin/kill -0 {pid} 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"{}\"",
            bundle.display()
        );
        let mut command = std::process::Command::new("/bin/sh");
        command
            .args(["-c", &script])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .process_group(0);
        if let Err(err) = command.spawn() {
            tracing::error!(error = %err, "failed to spawn the relauncher");
        }
    }
    #[cfg(not(unix))]
    let _ = bundle;
}

// ---------------------------------------------------------------------------
// Engine-side checker
// ---------------------------------------------------------------------------

/// What the engine reports over the `UpdateStatus` stream. Version facts only —
/// download/apply progress is owned by whoever drives the update (UI or CLI).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatus {
    pub current_version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_version: Option<String>,
    #[serde(default)]
    pub update_available: bool,
    /// Epoch ms of the last successful check.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl UpdateStatus {
    fn initial() -> Self {
        Self {
            current_version: current_version().to_string(),
            latest_version: None,
            update_available: false,
            checked_at: None,
            error: None,
        }
    }
}

/// Whether a managed headless install applies updates itself. ON by default,
/// like the desktop app; `HARNESS_AUTO_UPDATE=0|false|no|off` turns it off.
fn auto_update_enabled() -> bool {
    desktop_auto_update_from(std::env::var("HARNESS_AUTO_UPDATE").ok().as_deref())
}

/// The launchd label `harness daemon install` registers (see [`restart_service`]).
const LAUNCHD_LABEL: &str = "harness.codegraff.app";

/// Is this process the service [`restart_service`] restarts? systemd sets
/// `INVOCATION_ID` for every unit it runs and launchd sets
/// `XPC_SERVICE_NAME` to the job label. An engine started by hand (a shell,
/// tmux, a container without an init) has neither and restarts itself.
fn supervised_by_service(invocation_id: Option<&str>, xpc_service: Option<&str>) -> bool {
    invocation_id.is_some_and(|id| !id.is_empty()) || xpc_service == Some(LAUNCHD_LABEL)
}

fn supervised() -> bool {
    supervised_by_service(
        std::env::var("INVOCATION_ID").ok().as_deref(),
        std::env::var("XPC_SERVICE_NAME").ok().as_deref(),
    )
}

fn reexec_tx() -> &'static watch::Sender<bool> {
    static TX: std::sync::OnceLock<watch::Sender<bool>> = std::sync::OnceLock::new();
    TX.get_or_init(|| watch::channel(false).0)
}

/// Resolves once an applied update asks this process to restart itself: it
/// is not under a service manager, or the service restart failed. The engine
/// shuts down gracefully on it, and the binary then calls [`reexec`].
pub async fn reexec_requested() {
    let mut rx = reexec_tx().subscribe();
    let _ = rx.wait_for(|requested| *requested).await;
}

/// Replace this process with the newly installed release, same arguments and
/// environment — the restart for an engine nothing else would restart. Only
/// returns on failure. Call after the runtime has shut down.
pub fn reexec() -> Option<std::io::Error> {
    if !*reexec_tx().borrow() {
        return None;
    }
    let InstallKind::Managed { app_root } = detect_install() else {
        return Some(std::io::Error::other("not a managed install"));
    };
    let exe = app_root.join("current").join("harness");
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt as _;
        tracing::info!(exe = %exe.display(), "restarting into the updated release");
        Some(
            std::process::Command::new(&exe)
                .args(std::env::args_os().skip(1))
                .exec(),
        )
    }
    #[cfg(not(unix))]
    {
        let _ = exe;
        Some(std::io::Error::other("self-restart is not supported here"))
    }
}

/// Whether the desktop app stages and installs updates on its own. ON by
/// default; `HARNESS_AUTO_UPDATE=0|false|no|off` turns it off and restores
/// the manual click-through flow.
pub fn desktop_auto_update_enabled() -> bool {
    desktop_auto_update_from(std::env::var("HARNESS_AUTO_UPDATE").ok().as_deref())
}

fn desktop_auto_update_from(value: Option<&str>) -> bool {
    !value.is_some_and(|v| {
        matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "0" | "false" | "no" | "off"
        )
    })
}

/// "Nothing would be interrupted by a restart right now" — wired by the engine
/// to its live-run and open-terminal registries. `None` = no gate.
pub type QuiescentCheck = Arc<dyn Fn() -> bool + Send + Sync>;

/// Delay before the next check: the full interval after a success, otherwise
/// the backoff step for `failures` in a row (1 = first failure).
fn next_check_delay(ok: bool, failures: u32) -> std::time::Duration {
    if ok {
        return CHECK_INTERVAL;
    }
    let step = (failures.max(1) as usize - 1).min(CHECK_BACKOFF.len() - 1);
    CHECK_BACKOFF[step]
}

/// Is a check due? Judged on the WALL clock, so time spent asleep counts. A due
/// time further ahead than a full interval can only mean the clock was set
/// back; that counts as due, or a wrong clock could silence checks for as long
/// as it was off.
fn check_due(now_ms: i64, due_ms: i64) -> bool {
    now_ms >= due_ms || due_ms - now_ms > CHECK_INTERVAL.as_millis() as i64
}

/// Background release checker: polls `{edge}/releases` hourly, on the wall
/// clock, and publishes [`UpdateStatus`] over a watch channel (the `UpdateStatus` RPC
/// stream). Managed installs stage + apply + restart on their own unless
/// `HARNESS_AUTO_UPDATE` turns it off — but only in a quiet window: while
/// `quiescent` reports activity, the apply defers and re-probes every
/// [`IDLE_RECHECK`].
#[derive(Clone)]
pub struct Updater {
    edge_url: String,
    status_tx: Arc<watch::Sender<UpdateStatus>>,
    check_tx: Arc<watch::Sender<u64>>,
    quiescent: Option<QuiescentCheck>,
    /// Flips to true exactly once; the check loop selects against it so
    /// cancellation lands at any await point (no tokio-util in this crate).
    shutdown_tx: Arc<watch::Sender<bool>>,
    check_task: Arc<std::sync::Mutex<Option<tokio::task::JoinHandle<()>>>>,
}

impl Updater {
    /// Spawn the check loop (must run on a tokio runtime).
    pub fn spawn(edge_url: String, quiescent: Option<QuiescentCheck>) -> Self {
        let (status_tx, _) = watch::channel(UpdateStatus::initial());
        let (check_tx, _) = watch::channel(0);
        let (shutdown_tx, _) = watch::channel(false);
        let updater = Self {
            edge_url,
            status_tx: Arc::new(status_tx),
            check_tx: Arc::new(check_tx),
            quiescent,
            shutdown_tx: Arc::new(shutdown_tx),
            check_task: Arc::new(std::sync::Mutex::new(None)),
        };
        let for_loop = updater.clone();
        let task = tokio::spawn(async move { for_loop.check_loop().await });
        *updater.check_task.lock().unwrap() = Some(task);
        updater
    }

    /// Stop the check loop and wait for it to exit — a replaced runtime must
    /// not keep polling `{edge}/releases` (or auto-applying) in the background.
    /// Idempotent, and callable from any clone.
    pub async fn shutdown(&self) {
        let _ = self.shutdown_tx.send(true);
        let task = self
            .check_task
            .lock()
            .unwrap_or_else(|err| err.into_inner())
            .take();
        if let Some(task) = task {
            let _ = task.await;
        }
    }

    pub fn watch(&self) -> watch::Receiver<UpdateStatus> {
        self.status_tx.subscribe()
    }

    /// Wake the release checker immediately, for example when authentication
    /// recovers after the process started offline.
    pub fn check_now(&self) {
        self.check_tx
            .send_modify(|epoch| *epoch = epoch.wrapping_add(1));
    }

    fn quiescent_now(&self) -> bool {
        self.quiescent.as_ref().is_none_or(|check| check())
    }

    async fn check_loop(&self) {
        // The installed app and managed server installs follow Harness's
        // release feed; source builds and copied binaries never check.
        if !cfg!(test) && !detect_install().checks_releases() {
            return;
        }
        let mut shutdown = self.shutdown_tx.subscribe();
        // Shutdown must cut the loop at ANY await point — including mid
        // `check_once()` / `auto_apply_when_idle()` HTTP — so the whole body
        // races the flag rather than checking it between iterations.
        tokio::select! {
            _ = shutdown.wait_for(|stop| *stop) => {}
            _ = async {
                let mut checks = self.check_tx.subscribe();
                tokio::select! {
                    _ = tokio::time::sleep(CHECK_INITIAL_DELAY) => {}
                    _ = checks.changed() => {}
                }
                let mut failures = 0u32;
                loop {
                    let ok = self.check_once().await;
                    failures = if ok { 0 } else { failures.saturating_add(1) };
                    if ok
                        && self.status_tx.borrow().update_available
                        && auto_update_enabled()
                        && let InstallKind::Managed { .. } = detect_install()
                    {
                        self.auto_apply_when_idle().await;
                    }
                    let due = now_ms()
                        .saturating_add(next_check_delay(ok, failures).as_millis() as i64);
                    // Short ticks against the wall clock, not one long sleep:
                    // waking from sleep checks within a tick.
                    loop {
                        tokio::select! {
                            _ = tokio::time::sleep(CHECK_TICK) => {
                                if check_due(now_ms(), due) {
                                    break;
                                }
                            }
                            _ = checks.changed() => break,
                        }
                    }
                }
            } => {}
        }
    }

    /// Sessions must never die to an update: pre-stage the download now
    /// (harmless while busy), wait for a quiet window (no live runs, no open
    /// terminals), then apply — which re-fetches the manifest (so a long defer
    /// lands on whatever is newest) and reuses the staged dir, keeping the
    /// idle→restart gap to well under a second.
    async fn auto_apply_when_idle(&self) {
        if let InstallKind::Managed { app_root } = detect_install() {
            match fetch_latest(&self.edge_url).await {
                Ok(manifest) if version_newer(&manifest.version, current_version()) => {
                    if let Err(err) = stage_headless(&self.edge_url, &manifest, &app_root).await {
                        tracing::warn!(error = %err, "auto-update staging failed");
                        return;
                    }
                }
                Ok(_) => return,
                Err(err) => {
                    tracing::warn!(error = %err, "auto-update staging fetch failed");
                    return;
                }
            }
        }
        let mut deferred = false;
        while !self.quiescent_now() {
            if !deferred {
                deferred = true;
                tracing::info!("auto-update deferred: sessions or terminals active");
            }
            tokio::time::sleep(IDLE_RECHECK).await;
        }
        match self.apply().await {
            Ok(version) => {
                tracing::info!(%version, "auto-update applied; restarting")
            }
            Err(err) => tracing::warn!(error = %err, "auto-update failed"),
        }
    }

    /// One check; returns false on fetch failure (retry sooner).
    async fn check_once(&self) -> bool {
        match fetch_latest(&self.edge_url).await {
            Ok(manifest) => {
                let status = UpdateStatus {
                    current_version: current_version().to_string(),
                    update_available: version_newer(&manifest.version, current_version()),
                    latest_version: Some(manifest.version),
                    checked_at: Some(now_ms()),
                    error: None,
                };
                if status.update_available {
                    tracing::info!(
                        latest = status.latest_version.as_deref().unwrap_or(""),
                        current = %status.current_version,
                        "update available"
                    );
                }
                self.status_tx.send_replace(status);
                true
            }
            Err(err) => {
                tracing::debug!(error = %err, "update check failed");
                self.status_tx
                    .send_modify(|s| s.error = Some(format!("{err:#}")));
                false
            }
        }
    }

    /// Stage + apply the newest release on THIS device (managed installs only),
    /// then restart the service after a short delay so the caller's RPC reply
    /// flushes before systemd/launchd kills this process.
    pub async fn apply(&self) -> anyhow::Result<String> {
        let InstallKind::Managed { app_root } = detect_install() else {
            bail!(
                "this install is not update-managed — the desktop app updates from its UI; \
                 source builds update via git"
            );
        };
        let manifest = fetch_latest(&self.edge_url).await?;
        if !version_newer(&manifest.version, current_version()) {
            bail!("already up to date ({})", current_version());
        }
        stage_headless(&self.edge_url, &manifest, &app_root).await?;
        apply_headless(&app_root, &manifest.version)?;
        tokio::spawn(async {
            tokio::time::sleep(std::time::Duration::from_millis(800)).await;
            if supervised() {
                match restart_service() {
                    Ok(()) => return,
                    Err(err) => {
                        tracing::warn!(error = %err, "service restart failed — restarting in place")
                    }
                }
            }
            reexec_tx().send_replace(true);
        });
        Ok(manifest.version)
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_auto_update_defaults_on_and_honours_off_values() {
        assert!(desktop_auto_update_from(None));
        assert!(desktop_auto_update_from(Some("")));
        assert!(desktop_auto_update_from(Some("1")));
        assert!(!desktop_auto_update_from(Some("0")));
        assert!(!desktop_auto_update_from(Some(" OFF ")));
        assert!(!desktop_auto_update_from(Some("false")));
        assert!(!desktop_auto_update_from(Some("no")));
    }

    #[test]
    fn servers_and_the_app_check_releases_but_source_builds_never_do() {
        assert!(
            InstallKind::Managed {
                app_root: PathBuf::from("/home/u/.harness/app")
            }
            .checks_releases()
        );
        assert!(
            InstallKind::MacApp {
                bundle: PathBuf::from("/Applications/Harness.app")
            }
            .checks_releases()
        );
        assert!(!InstallKind::Unmanaged.checks_releases());
    }

    #[test]
    fn only_the_installed_service_counts_as_supervised() {
        // systemd unit
        assert!(supervised_by_service(Some("3f2a9c"), None));
        // `harness daemon install` launchd job
        assert!(supervised_by_service(None, Some("harness.codegraff.app")));
        // a shell, tmux or a container without an init
        assert!(!supervised_by_service(None, None));
        assert!(!supervised_by_service(Some(""), None));
        // a terminal app's own launchd job is not the Harness service
        assert!(!supervised_by_service(
            None,
            Some("application.com.apple.Terminal")
        ));
    }

    #[test]
    fn nothing_restarts_in_place_unless_an_update_asked_for_it() {
        assert!(reexec().is_none());
    }

    #[test]
    fn install_on_exit_is_a_no_op_for_non_desktop_installs() {
        let staged = tempfile::tempdir().unwrap();
        assert!(
            InstallKind::Unmanaged
                .install_on_exit(staged.path())
                .is_ok()
        );
        assert_eq!(
            std::fs::read_dir(staged.path()).unwrap().count(),
            0,
            "a non-desktop install touches nothing"
        );
    }

    #[test]
    fn a_success_waits_the_full_interval() {
        assert_eq!(next_check_delay(true, 0), CHECK_INTERVAL);
        assert_eq!(next_check_delay(true, 7), CHECK_INTERVAL);
    }

    #[test]
    fn failures_back_off_one_five_fifteen_then_thirty_minutes() {
        let minutes = |failures| next_check_delay(false, failures).as_secs() / 60;
        assert_eq!(
            (1..=6).map(minutes).collect::<Vec<_>>(),
            [1, 5, 15, 30, 30, 30]
        );
        assert_eq!(minutes(0), 1, "never below the first step");
        assert_eq!(minutes(u32::MAX), 30);
    }

    #[test]
    fn due_time_is_judged_on_the_wall_clock() {
        let hour = CHECK_INTERVAL.as_millis() as i64;
        let due = 10_000_000 + hour;
        assert!(!check_due(due - 1, due), "not due while the clock is short");
        assert!(check_due(due, due));
        // A night asleep: the clock jumped past the due time. One long
        // monotonic sleep would not have noticed; a tick against the wall
        // clock does.
        assert!(check_due(due + 8 * hour, due));
    }

    #[test]
    fn a_clock_set_back_does_not_silence_checks() {
        let hour = CHECK_INTERVAL.as_millis() as i64;
        let now = 10_000_000;
        // Just scheduled, a full interval ahead: not due.
        assert!(!check_due(now, now + hour));
        // The clock moved back a day, so the due time looks a day ahead: due.
        assert!(check_due(now - 24 * hour, now + hour));
    }

    #[tokio::test]
    async fn stalled_update_headers_and_body_time_out_but_progressing_body_survives() {
        use std::time::Duration;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        for stall_body in [false, true] {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = [0; 4096];
                socket.read(&mut request).await.unwrap();
                if stall_body {
                    socket
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nx")
                        .await
                        .unwrap();
                }
                tokio::time::sleep(Duration::from_secs(2)).await;
            });
            let client =
                http_client_with_timeouts(Duration::from_millis(200), Duration::from_millis(100))
                    .unwrap();
            let request = async {
                client
                    .get(format!("http://{address}"))
                    .send()
                    .await?
                    .bytes()
                    .await
            };
            let error = tokio::time::timeout(Duration::from_secs(1), request)
                .await
                .expect("bounded read")
                .unwrap_err();
            assert!(error.is_timeout());
            server.abort();
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            socket.read(&mut request).await.unwrap();
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n")
                .await
                .unwrap();
            for _ in 0..10 {
                socket.write_all(b"x").await.unwrap();
                tokio::time::sleep(Duration::from_millis(40)).await;
            }
        });
        let client =
            http_client_with_timeouts(Duration::from_secs(1), Duration::from_millis(200)).unwrap();
        assert_eq!(
            client
                .get(format!("http://{address}"))
                .send()
                .await
                .unwrap()
                .bytes()
                .await
                .unwrap()
                .len(),
            10
        );
        server.await.unwrap();
    }

    #[tokio::test]
    async fn stalled_update_tls_handshake_has_a_connect_deadline() {
        use std::time::Duration;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (_socket, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_secs(2)).await;
        });
        let client =
            http_client_with_timeouts(Duration::from_millis(100), Duration::from_secs(30)).unwrap();
        let error = tokio::time::timeout(
            Duration::from_secs(1),
            client.get(format!("https://{address}")).send(),
        )
        .await
        .expect("bounded TLS handshake")
        .unwrap_err();
        assert!(error.is_timeout());
        server.abort();
    }

    #[test]
    fn update_feed_override_requires_an_https_base_url() {
        assert_eq!(
            validate_release_override(" https://example.com/releases/ ").unwrap(),
            "https://example.com/releases"
        );
        for url in [
            "http://example.com/releases",
            "file:///tmp/update",
            "https://user:password@example.com",
            "https://example.com?feed=x",
            "https://example.com/#fragment",
        ] {
            assert!(validate_release_override(url).is_err(), "accepted {url}");
        }
    }

    #[test]
    fn version_compare() {
        assert!(version_newer("0.1.1", "0.1.0"));
        assert!(version_newer("0.2.0", "0.1.9"));
        assert!(version_newer("0.1.10", "0.1.9"));
        assert!(version_newer("v0.1.1", "0.1.0"));
        assert!(version_newer("0.1.0.1", "0.1.0"));
        assert!(!version_newer("0.1.0", "0.1.0"));
        assert!(!version_newer("0.1.0", "0.1.1"));
        // Garbage never counts as newer.
        assert!(!version_newer("", "0.1.0"));
        assert!(!version_newer("nightly", "0.1.0"));
    }

    #[test]
    fn install_kind_detection() {
        assert_eq!(
            detect_install_from_for_os(
                Path::new("/home/u/.harness/app/0.1.1/harness"),
                Some(Path::new("/home/u")),
                "linux",
            ),
            InstallKind::Managed {
                app_root: PathBuf::from("/home/u/.harness/app")
            }
        );
        assert_eq!(
            detect_install_from_for_os(
                Path::new("/Applications/Harness.app/Contents/MacOS/harness"),
                Some(Path::new("/Users/u")),
                "macos",
            ),
            InstallKind::MacApp {
                bundle: PathBuf::from("/Applications/Harness.app")
            }
        );
        // A path merely containing `.app` without the bundle layout is not a bundle.
        assert_eq!(
            detect_install_from_for_os(Path::new("/tmp/foo.app/harness"), None, "macos"),
            InstallKind::Unmanaged
        );
        assert_eq!(
            detect_install_from_for_os(
                Path::new("/src/target/release/harness"),
                Some(Path::new("/home/u")),
                "linux",
            ),
            InstallKind::Unmanaged
        );
    }

    #[test]
    fn artifact_names_match_packaging() {
        let (os, arch) = platform_key();
        assert!(headless_artifact("0.2.0").starts_with("harness-0.2.0-"));
        assert_eq!(
            headless_artifact("0.2.0"),
            format!("harness-0.2.0-{os}-{arch}.tar.gz")
        );
        assert_eq!(
            mac_app_artifact("0.2.0"),
            format!("harness-0.2.0-macos-{arch}-app.tar.gz")
        );
    }

    #[test]
    fn installed_apps_and_servers_use_published_stable_manifest() {
        let app = InstallKind::MacApp {
            bundle: PathBuf::from("/Applications/Harness.app"),
        };
        assert!(app.supports_desktop_update());
        assert_eq!(
            default_release_base("https://example.test", &app),
            "https://github.com/justrach/harness/releases/latest/download"
        );
        let server = InstallKind::Managed {
            app_root: PathBuf::from("/home/u/.harness/app"),
        };
        assert_eq!(
            default_release_base("https://example.test", &server),
            "https://github.com/justrach/harness/releases/latest/download"
        );
        assert_eq!(
            default_release_base("https://example.test/", &InstallKind::Unmanaged),
            "https://example.test/releases"
        );
    }

    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn mac_app_update_requires_a_manifest_checksum_before_staging() {
        let data = tempfile::tempdir().unwrap();
        let manifest = Manifest {
            version: "0.2.86".into(),
            files: BTreeMap::new(),
        };
        let error = stage_mac_app("https://example.test", &manifest, data.path())
            .await
            .unwrap_err();
        assert!(error.to_string().contains("missing the harness-0.2.86"));
        assert!(!data.path().join("updates").exists());
    }

    #[cfg(windows)]
    #[test]
    fn windows_is_not_misclassified_as_linux() {
        assert_eq!(platform_key().0, "windows");
    }

    #[cfg(windows)]
    #[test]
    fn windows_install_is_always_unmanaged() {
        assert_eq!(
            detect_install_from(
                Path::new(r"C:\Users\u\.harness\app\0.2.0\harness.exe"),
                Some(Path::new(r"C:\Users\u")),
            ),
            InstallKind::Unmanaged
        );
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn windows_rejects_platform_specific_updates_before_side_effects() {
        let tmp = tempfile::tempdir().unwrap();
        let manifest = Manifest {
            version: "9.9.9".into(),
            files: BTreeMap::new(),
        };
        let app_root = tmp.path().join("app");
        let data_dir = tmp.path().join("data");

        let managed_err = stage_headless("http://127.0.0.1:1", &manifest, &app_root)
            .await
            .unwrap_err();
        assert!(managed_err.to_string().contains("not supported on windows"));
        assert!(!app_root.exists(), "managed staging must not touch disk");

        let mac_err = stage_mac_app("http://127.0.0.1:1", &manifest, &data_dir)
            .await
            .unwrap_err();
        assert!(mac_err.to_string().contains("not supported on windows"));
        assert!(!data_dir.exists(), "macOS staging must not touch disk");

        assert!(
            apply_headless(&app_root, &manifest.version)
                .unwrap_err()
                .to_string()
                .contains("not supported on windows")
        );
        assert!(
            apply_mac_app(&data_dir.join("Harness.app"), &data_dir.join("Installed.app"))
                .unwrap_err()
                .to_string()
                .contains("not supported on windows")
        );
        assert!(
            restart_service()
                .unwrap_err()
                .to_string()
                .contains("not supported on windows")
        );
    }

    #[test]
    fn manifest_parses_with_and_without_files() {
        let full: Manifest = serde_json::from_str(
            r#"{"version":"0.1.1","files":{"harness-0.1.1-linux-x86_64.tar.gz":{"sha256":"abc"}}}"#,
        )
        .unwrap();
        assert_eq!(full.version, "0.1.1");
        assert_eq!(
            full.files["harness-0.1.1-linux-x86_64.tar.gz"]
                .sha256
                .as_deref(),
            Some("abc")
        );
        let bare: Manifest = serde_json::from_str(r#"{"version":"0.1.1"}"#).unwrap();
        assert!(bare.files.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn headless_symlink_swap() {
        let tmp = tempfile::tempdir().unwrap();
        let app_root = tmp.path().join("app");
        for ver in ["0.1.0", "0.1.1"] {
            std::fs::create_dir_all(app_root.join(ver)).unwrap();
            std::fs::write(app_root.join(ver).join("harness"), ver).unwrap();
        }
        apply_headless(&app_root, "0.1.0").unwrap();
        assert_eq!(
            std::fs::read_link(app_root.join("current")).unwrap(),
            app_root.join("0.1.0")
        );
        // Swap over an existing symlink.
        apply_headless(&app_root, "0.1.1").unwrap();
        assert_eq!(
            std::fs::read_link(app_root.join("current")).unwrap(),
            app_root.join("0.1.1")
        );
        // Unstaged version refuses.
        assert!(apply_headless(&app_root, "0.2.0").is_err());
    }
}
