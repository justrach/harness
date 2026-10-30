//! The streaming helper: a pinned `expo-device-hub` (MIT; it vendors Expo's
//! serve-sim, Apache-2.0), npm-installed under `<data>/tools` only when the
//! user sets simulators up, and served by Harness's own host script
//! (`helper/harness-sim-host.mjs`) on the user's Node.
//!
//! **Install.** `npm ci --ignore-scripts` from a lockfile shipped in the
//! engine, which pins every package's version and sha512 integrity, into a
//! staging directory. The result is checked (the helper's own version, the
//! file the host loads), a sentinel naming the version and the lockfile's
//! hash is written, and the directory is renamed into place. A changed
//! lockfile is a new install; no package's install script ever runs.
//!
//! **Run.** The host binds 127.0.0.1 on a port it picks, answers only the
//! MJPEG stream and HID socket routes, and requires a bearer token minted for
//! each run, so other local processes can't drive simulators through it. It
//! runs in its own process group and exits when its stdin closes (the engine
//! went away). Its pid and start time go in a pid file, so the next engine can
//! stop one that a crash orphaned without ever signalling an unrelated process
//! that reused the pid.

use std::ffi::OsString;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};

pub(crate) const PACKAGE: &str = "expo-device-hub";
pub(crate) const VERSION: &str = "0.12.0";
const PACKAGE_JSON: &str = include_str!("helper/package.json");
const PACKAGE_LOCK: &str = include_str!("helper/package-lock.json");
const HOST_SCRIPT: &str = include_str!("helper/harness-sim-host.mjs");
const HOST_SCRIPT_NAME: &str = "harness-sim-host.mjs";
const MIDDLEWARE: [&str; 6] = [
    "node_modules",
    PACKAGE,
    "vendor",
    "serve-sim",
    "dist",
    "middleware.js",
];
const SENTINEL: &str = ".install-complete";
/// The host's one line on stdout once it listens (the helper's native code
/// writes its own lines there too).
const READY_PREFIX: &str = "HARNESS_SIM_HOST ";
const MIN_NODE_MAJOR: u32 = 20;
/// Frames are downscaled (long side), compressed, and rate-capped where they
/// are made, so one simulator's stream stays small enough for the relay
/// before any viewer's own cap applies.
pub(crate) const MAX_DIMENSION: u32 = 960;
const MJPEG_QUALITY: f64 = 0.6;
pub(crate) const SOURCE_FPS: u32 = 20;
const INSTALL_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const READY_TIMEOUT: Duration = Duration::from_secs(30);
const STOP_GRACE: Duration = Duration::from_secs(2);
pub(crate) const NODE_MISSING: &str =
    "Node.js wasn't found on this computer. Install Node.js 20 or newer, then try again.";

/// The SHA-256 of the shipped lockfile; part of the sentinel, so a new lockfile reinstalls.
fn lock_digest() -> String {
    format!("{:x}", Sha256::digest(PACKAGE_LOCK.as_bytes()))
}

fn sentinel_text() -> String {
    format!("{VERSION}\n{}\n", lock_digest())
}

pub(crate) struct Install {
    dir: PathBuf,
}

impl Install {
    pub(crate) fn new(tools_dir: &Path) -> Self {
        Self {
            dir: tools_dir.join(PACKAGE).join(VERSION),
        }
    }

    fn middleware(&self) -> PathBuf {
        MIDDLEWARE
            .iter()
            .fold(self.dir.clone(), |p, part| p.join(part))
    }

    pub(crate) fn host_script(&self) -> PathBuf {
        self.dir.join(HOST_SCRIPT_NAME)
    }

    pub(crate) fn is_installed(&self) -> bool {
        let sentinel = std::fs::read_to_string(self.dir.join(SENTINEL)).unwrap_or_default();
        sentinel == sentinel_text() && self.middleware().is_file()
    }

    /// Install the pinned helper; `log` gets npm's output. Callers serialize installs.
    pub(crate) async fn install(&self, log: &Path) -> Result<(), String> {
        if self.is_installed() {
            return Ok(());
        }
        let node = find_tool("node").ok_or(NODE_MISSING)?;
        check_node_version(&node).await?;
        let npm = find_tool("npm").ok_or(NODE_MISSING)?;
        let parent = self
            .dir
            .parent()
            .expect("versioned install dir has a parent");
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("preparing {}: {e}", parent.display()))?;
        let staging = parent.join(format!(
            ".staging-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&staging).map_err(|e| format!("preparing the install: {e}"))?;
        let result = self.install_into(&staging, &npm, log).await;
        let _ = std::fs::remove_dir_all(&staging);
        result
    }

    async fn install_into(&self, staging: &Path, npm: &Path, log: &Path) -> Result<(), String> {
        let write = |name: &str, text: &str| {
            std::fs::write(staging.join(name), text)
                .map_err(|e| format!("preparing the install: {e}"))
        };
        write("package.json", PACKAGE_JSON)?;
        write("package-lock.json", PACKAGE_LOCK)?;
        let mut cmd = Command::new(npm);
        cmd.args([
            "ci",
            "--ignore-scripts",
            "--omit=dev",
            "--no-audit",
            "--no-fund",
            "--no-update-notifier",
        ])
        .current_dir(staging)
        .env("npm_config_ignore_scripts", "true")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
        if let Some(path) = tool_path() {
            cmd.env("PATH", path);
        }
        let output = tokio::time::timeout(INSTALL_TIMEOUT, cmd.output())
            .await
            .map_err(|_| "Setting up timed out: npm didn't finish in 10 minutes.".to_string())?
            .map_err(|e| format!("Couldn't run npm: {e}"))?;
        if let Some(parent) = log.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(log, [&output.stdout[..], &output.stderr[..]].concat());
        if !output.status.success() {
            return Err(npm_failure(&output.stderr, log));
        }
        let installed = installed_version(&staging.join("node_modules").join(PACKAGE));
        if installed.as_deref() != Some(VERSION) {
            return Err(format!(
                "npm installed {PACKAGE} {} instead of {VERSION}.",
                installed.as_deref().unwrap_or("nothing")
            ));
        }
        let staged = Install {
            dir: staging.to_path_buf(),
        };
        if !staged.middleware().is_file() {
            return Err("npm finished without the streaming helper's files.".into());
        }
        write(HOST_SCRIPT_NAME, HOST_SCRIPT)?;
        write(SENTINEL, &sentinel_text())?;
        if self.dir.exists() {
            std::fs::remove_dir_all(&self.dir)
                .map_err(|e| format!("replacing the old install: {e}"))?;
        }
        std::fs::rename(staging, &self.dir).map_err(|e| format!("finishing the install: {e}"))
    }
}

/// npm's own reason, and where the rest of its output is.
fn npm_failure(stderr: &[u8], log: &Path) -> String {
    let stderr = String::from_utf8_lossy(stderr);
    let errors: Vec<&str> = stderr
        .lines()
        .filter_map(|l| {
            let l = l.trim();
            l.strip_prefix("npm error ")
                .or_else(|| l.strip_prefix("npm ERR! "))
        })
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("A complete log"))
        .collect();
    let detail = |l: &str| {
        !["code ", "syscall ", "errno "]
            .iter()
            .any(|p| l.starts_with(p))
    };
    let reason = errors
        .iter()
        .copied()
        .find(|l| detail(l))
        .or(errors.first().copied())
        .or_else(|| stderr.lines().rev().map(str::trim).find(|l| !l.is_empty()))
        .unwrap_or("no output");
    format!(
        "npm couldn't install the streaming helper: {reason} (full output in {})",
        log.display()
    )
}

fn installed_version(package_dir: &Path) -> Option<String> {
    let text = std::fs::read_to_string(package_dir.join("package.json")).ok()?;
    let json: serde_json::Value = serde_json::from_str(&text).ok()?;
    json.get("version")?.as_str().map(str::to_string)
}

async fn check_node_version(node: &Path) -> Result<(), String> {
    let output = Command::new(node)
        .arg("--version")
        .stdin(Stdio::null())
        .output()
        .await
        .map_err(|_| NODE_MISSING.to_string())?;
    let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
    match node_major(&version) {
        Some(major) if major >= MIN_NODE_MAJOR => Ok(()),
        _ => Err(format!(
            "Simulator streaming needs Node.js {MIN_NODE_MAJOR} or newer; this computer has {}.",
            if version.is_empty() {
                "an unknown version"
            } else {
                &version
            }
        )),
    }
}

fn node_major(version: &str) -> Option<u32> {
    version
        .trim()
        .trim_start_matches('v')
        .split('.')
        .next()?
        .parse()
        .ok()
}

/// How the engine reaches a running host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Endpoint {
    pub origin: String,
    pub token: String,
}

/// A running host. [`Hub::stop`] ends it gracefully; dropping it kills its process group.
pub(crate) struct Hub {
    child: Child,
    /// Held open for the host's lifetime: it exits when this closes.
    stdin: Option<ChildStdin>,
    pid: Option<u32>,
    pid_file: PathBuf,
    pub endpoint: Endpoint,
}

impl Hub {
    pub(crate) fn is_alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// Start the host, logging under `state_dir` and recording its pid there.
    pub(crate) async fn start(
        install: &Install,
        state_dir: &Path,
        developer_dir: Option<&Path>,
    ) -> Result<Hub, String> {
        if !install.is_installed() {
            return Err("Simulator streaming isn't set up on this computer.".into());
        }
        let pid_file = state_dir.join("simulator-hub.pid");
        let host_script = install.host_script();
        stop_stale(&pid_file, &host_script).await;
        let node = find_tool("node").ok_or(NODE_MISSING)?;
        std::fs::write(&host_script, HOST_SCRIPT)
            .map_err(|e| format!("writing the streaming host: {e}"))?;
        let log_path = state_dir.join("simulator-hub.log");
        let log = std::fs::File::create(&log_path)
            .map_err(|e| format!("opening the streaming helper's log: {e}"))?;
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let stream = serde_json::json!({
            "maxDimension": MAX_DIMENSION,
            "mjpegQuality": MJPEG_QUALITY,
            "mjpegFps": SOURCE_FPS,
        });
        let mut cmd = Command::new(node);
        cmd.arg(&host_script)
            .arg(install.middleware())
            .current_dir(&install.dir)
            .env("HARNESS_SIM_TOKEN", &token)
            .env("HARNESS_SIM_STREAM", stream.to_string())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log.try_clone().map_err(|e| {
                format!("opening the streaming helper's log: {e}")
            })?))
            .kill_on_drop(true);
        #[cfg(unix)]
        cmd.process_group(0);
        if let Some(path) = tool_path() {
            cmd.env("PATH", path);
        }
        if let Some(dir) = developer_dir {
            cmd.env("DEVELOPER_DIR", dir);
        }
        let mut child = cmd
            .spawn()
            .map_err(|e| format!("starting the streaming helper: {e}"))?;
        let pid = child.id();
        if let Some(pid) = pid
            && let Some(identity) = process_identity(pid as i32)
        {
            let _ = std::fs::write(&pid_file, format!("{pid} {}\n", identity.started));
        }
        let stdout = child.stdout.take().expect("stdout is piped");
        let mut hub = Hub {
            stdin: child.stdin.take(),
            child,
            pid,
            pid_file,
            endpoint: Endpoint {
                origin: String::new(),
                token,
            },
        };
        let mut lines = BufReader::new(stdout).lines();
        let mut log_lines = log;
        let port = tokio::time::timeout(READY_TIMEOUT, async {
            while let Ok(Some(line)) = lines.next_line().await {
                if let Some(ready) = line.strip_prefix(READY_PREFIX) {
                    return serde_json::from_str::<serde_json::Value>(ready)
                        .ok()
                        .and_then(|v| v.get("port")?.as_u64())
                        .and_then(|p| u16::try_from(p).ok());
                }
                let _ = writeln!(log_lines, "{line}");
            }
            None
        })
        .await
        .map_err(|_| "the streaming helper didn't start in time".to_string())?
        .ok_or_else(|| {
            format!(
                "the streaming helper exited at startup (see {})",
                log_path.display()
            )
        })?;
        // Keep draining stdout (into the log) so the helper never blocks on a full pipe.
        tokio::spawn(async move {
            while let Ok(Some(line)) = lines.next_line().await {
                let _ = writeln!(log_lines, "{line}");
            }
        });
        hub.endpoint.origin = format!("http://127.0.0.1:{port}");
        Ok(hub)
    }

    /// Close stdin (the host exits on its own), then kill what's left.
    pub(crate) async fn stop(mut self) {
        self.stdin.take();
        if tokio::time::timeout(STOP_GRACE, self.child.wait())
            .await
            .is_err()
        {
            self.kill_group();
            let _ = self.child.wait().await;
        }
    }

    fn kill_group(&mut self) {
        // Only while the child is unreaped: until then its pid can't be reused.
        if let (Some(pid), Ok(None)) = (self.pid, self.child.try_wait()) {
            signal_group(pid as i32, Signal::Kill);
        }
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.stdin.take();
        self.kill_group();
        let _ = std::fs::remove_file(&self.pid_file);
    }
}

/// What tells a running process apart from a later one that got the same pid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProcessIdentity {
    /// Start time in the platform's own unit (µs since the epoch on macOS,
    /// clock ticks since boot on Linux); only ever compared for equality.
    pub started: u64,
    pub command: String,
}

/// The process's start time and command line, if it is running.
pub(crate) fn process_identity(pid: i32) -> Option<ProcessIdentity> {
    if pid <= 1 {
        return None;
    }
    let started = process_start(pid)?;
    let output = std::process::Command::new("/bin/ps")
        .args(["-o", "command=", "-p", &pid.to_string()])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let command = String::from_utf8_lossy(&output.stdout).trim().to_string();
    (!command.is_empty()).then_some(ProcessIdentity { started, command })
}

#[cfg(target_os = "macos")]
fn process_start(pid: i32) -> Option<u64> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: `info` is a properly sized, writable proc_bsdinfo.
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    (read == size).then(|| info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
}

#[cfg(target_os = "linux")]
fn process_start(pid: i32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // Field 22, counted after the parenthesized command (which may hold spaces).
    stat.rsplit_once(')')?
        .1
        .split_whitespace()
        .nth(19)?
        .parse()
        .ok()
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn process_start(_pid: i32) -> Option<u64> {
    None
}

/// True only if `pid` is still the helper host recorded with `started`: the
/// same start time, and a command line running this install's host script.
pub(crate) fn is_recorded_host(pid: i32, started: u64, host_script: &Path) -> bool {
    let script = host_script.to_string_lossy();
    process_identity(pid).is_some_and(|id| id.started == started && id.command.contains(&*script))
}

#[derive(Clone, Copy)]
enum Signal {
    Term,
    Kill,
}

/// Signal `pid`'s process group when it leads one (the host does), else just `pid`.
fn signal_group(pid: i32, signal: Signal) {
    if pid <= 1 {
        return;
    }
    #[cfg(unix)]
    {
        let signal = match signal {
            Signal::Term => libc::SIGTERM,
            Signal::Kill => libc::SIGKILL,
        };
        // SAFETY: plain signals to a pid the caller has matched to its own helper.
        unsafe {
            if libc::getpgid(pid) == pid {
                libc::killpg(pid, signal);
            } else {
                libc::kill(pid, signal);
            }
        }
    }
    #[cfg(not(unix))]
    let _ = signal;
}

/// An engine killed without its destructors may leave its host running
/// (normally it exits when its stdin closes). Stop it, but only if the pid
/// still names that host: pids are reused.
pub(crate) async fn stop_stale(pid_file: &Path, host_script: &Path) {
    let recorded = std::fs::read_to_string(pid_file).ok().and_then(|text| {
        let mut parts = text.split_whitespace();
        Some((
            parts.next()?.parse::<i32>().ok()?,
            parts.next()?.parse::<u64>().ok()?,
        ))
    });
    let _ = std::fs::remove_file(pid_file);
    let Some((pid, started)) = recorded else {
        return;
    };
    if !is_recorded_host(pid, started, host_script) {
        return;
    }
    signal_group(pid, Signal::Term);
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if !is_recorded_host(pid, started, host_script) {
            return;
        }
    }
    signal_group(pid, Signal::Kill);
}

/// The PATH to run Node tools with: the login shell's (an app opened from the
/// Dock gets a bare PATH), then this process's, then the usual install spots.
fn tool_path() -> Option<OsString> {
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(login) = harness_adapters::shell_env::login_shell_path() {
        dirs.extend(std::env::split_paths(login));
    }
    if let Some(own) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&own));
    }
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    std::env::join_paths(dirs).ok()
}

fn find_tool(name: &str) -> Option<PathBuf> {
    let path = tool_path()?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(name))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_lockfile_pins_the_helper_and_every_package_by_hash() {
        let lock: serde_json::Value = serde_json::from_str(PACKAGE_LOCK).unwrap();
        let manifest: serde_json::Value = serde_json::from_str(PACKAGE_JSON).unwrap();
        assert_eq!(manifest["dependencies"][PACKAGE], VERSION, "exact version");
        assert_eq!(lock["packages"][""]["dependencies"][PACKAGE], VERSION);
        let packages = lock["packages"].as_object().unwrap();
        assert_eq!(
            packages[&format!("node_modules/{PACKAGE}")]["version"],
            VERSION
        );
        for (name, entry) in packages.iter().filter(|(name, _)| !name.is_empty()) {
            let integrity = entry["integrity"].as_str().unwrap_or_default();
            assert!(
                integrity.starts_with("sha512-"),
                "{name} has no sha512 integrity"
            );
            let resolved = entry["resolved"].as_str().unwrap_or_default();
            assert!(
                resolved.starts_with("https://registry.npmjs.org/"),
                "{name} resolves from {resolved}"
            );
        }
    }

    #[test]
    fn a_new_lockfile_or_version_is_a_new_install() {
        let dir = tempfile::tempdir().unwrap();
        let install = Install::new(dir.path());
        std::fs::create_dir_all(install.middleware().parent().unwrap()).unwrap();
        std::fs::write(install.middleware(), "").unwrap();
        assert!(!install.is_installed(), "no sentinel");
        std::fs::write(install.dir.join(SENTINEL), format!("{VERSION}\n")).unwrap();
        assert!(!install.is_installed(), "an older engine's sentinel");
        std::fs::write(install.dir.join(SENTINEL), sentinel_text()).unwrap();
        assert!(install.is_installed());
        std::fs::remove_file(install.middleware()).unwrap();
        assert!(!install.is_installed(), "files gone");
    }

    #[test]
    fn node_versions_below_20_are_refused() {
        assert_eq!(node_major("v24.10.0\n"), Some(24));
        assert_eq!(node_major("v18.20.1"), Some(18));
        assert_eq!(node_major("garbage"), None);
    }

    #[test]
    fn an_npm_failure_names_npms_reason_and_the_log() {
        let log = Path::new("/data/tools/simulator-setup.log");
        let stderr = b"npm warn deprecated x@1\nnpm error code ENOTFOUND\nnpm error syscall getaddrinfo\nnpm error network request to https://registry.npmjs.org/ws failed\nnpm error A complete log of this run can be found in: /x.log\n";
        assert_eq!(
            npm_failure(stderr, log),
            "npm couldn't install the streaming helper: network request to https://registry.npmjs.org/ws failed (full output in /data/tools/simulator-setup.log)"
        );
        assert_eq!(
            npm_failure(b"npm ERR! code EINTEGRITY\n", log),
            "npm couldn't install the streaming helper: code EINTEGRITY (full output in /data/tools/simulator-setup.log)"
        );
        assert!(npm_failure(b"", log).contains(": no output ("));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_stale_pid_file_never_stops_an_unrelated_process() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join(HOST_SCRIPT_NAME);
        let pid_file = dir.path().join("simulator-hub.pid");

        // An unrelated process that happens to hold the recorded pid.
        let mut other = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = other.id() as i32;
        let started = process_identity(pid).unwrap().started;
        std::fs::write(&pid_file, format!("{pid} {started}\n")).unwrap();
        stop_stale(&pid_file, &script).await;
        assert!(
            other.try_wait().unwrap().is_none(),
            "wrong command: left alone"
        );
        assert!(!pid_file.exists());

        // Our host's command line, but a different start time: a reused pid.
        // (`; :` keeps sh from exec'ing sleep, so the script stays in its command line.)
        let mut host = std::process::Command::new("sh")
            .args(["-c", "sleep 30; :", script.to_str().unwrap()])
            .spawn()
            .unwrap();
        let host_pid = host.id() as i32;
        let host_started = process_identity(host_pid).unwrap().started;
        std::fs::write(&pid_file, format!("{host_pid} {}\n", host_started + 1)).unwrap();
        stop_stale(&pid_file, &script).await;
        assert!(
            host.try_wait().unwrap().is_none(),
            "wrong start time: left alone"
        );

        // Garbage in the pid file, or pid 1, is ignored.
        std::fs::write(&pid_file, "1 0\n").unwrap();
        stop_stale(&pid_file, &script).await;
        std::fs::write(&pid_file, "not a pid").unwrap();
        stop_stale(&pid_file, &script).await;

        // The recorded host itself is stopped.
        std::fs::write(&pid_file, format!("{host_pid} {host_started}\n")).unwrap();
        stop_stale(&pid_file, &script).await;
        let status = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(status) = host.try_wait().unwrap() {
                    return status;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .expect("the recorded host stopped");
        assert!(!status.success());

        other.kill().unwrap();
        let _ = other.wait();
    }
}
