//! The streaming helper: a pinned `expo-device-hub` (MIT; its iOS streamer is
//! Apache-2.0), npm-installed under `<data>/tools` only when the user sets
//! simulators up, and run with the user's Node bound to loopback.
//!
//! Install stages into a sibling directory and writes a sentinel only after
//! npm exits 0, then renames into place: npm extracts files before it
//! finishes, so an entry file alone does not prove a usable tree.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use tokio::process::{Child, Command};

pub(crate) const PACKAGE: &str = "expo-device-hub";
pub(crate) const VERSION: &str = "0.12.0";
const ENTRY: [&str; 5] = ["node_modules", PACKAGE, "dist", "server", "cli.mjs"];
const SENTINEL: &str = ".install-complete";
/// Frames are downscaled on this computer (long side and JPEG quality) so a
/// steady stream stays small enough for the relay.
const MAX_DIMENSION: &str = "960";
const MJPEG_QUALITY: &str = "0.6";
const INSTALL_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const READY_TIMEOUT: Duration = Duration::from_secs(30);

pub(crate) struct Install {
    dir: PathBuf,
}

impl Install {
    pub(crate) fn new(tools_dir: &Path) -> Self {
        Self {
            dir: tools_dir.join(PACKAGE).join(VERSION),
        }
    }

    fn entry(&self) -> PathBuf {
        ENTRY.iter().fold(self.dir.clone(), |p, part| p.join(part))
    }

    pub(crate) fn is_installed(&self) -> bool {
        let sentinel = std::fs::read_to_string(self.dir.join(SENTINEL)).unwrap_or_default();
        sentinel.trim() == VERSION && self.entry().is_file()
    }

    /// npm-install the pinned version. Callers serialize installs.
    pub(crate) async fn install(&self) -> Result<(), String> {
        if self.is_installed() {
            return Ok(());
        }
        let npm = find_tool("npm").ok_or_else(|| {
            "Node.js wasn't found on this computer. Install Node.js 20 or newer, then try again."
                .to_string()
        })?;
        let parent = self
            .dir
            .parent()
            .expect("versioned install dir has a parent");
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("preparing {}: {e}", parent.display()))?;
        let _ = std::fs::remove_dir_all(&self.dir);
        let staging = parent.join(format!(".staging-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).map_err(|e| format!("preparing the install: {e}"))?;
        let result = async {
            let mut cmd = Command::new(&npm);
            cmd.args(["install", "--prefix"])
                .arg(&staging)
                .args(["--no-fund", "--no-audit", "--no-save"])
                .arg(format!("{PACKAGE}@{VERSION}"))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .kill_on_drop(true);
            if let Some(path) = tool_path() {
                cmd.env("PATH", path);
            }
            let output = tokio::time::timeout(INSTALL_TIMEOUT, cmd.output())
                .await
                .map_err(|_| "npm install timed out".to_string())?
                .map_err(|e| format!("running npm: {e}"))?;
            if !output.status.success() {
                let stderr = String::from_utf8_lossy(&output.stderr);
                let last = stderr
                    .lines()
                    .rev()
                    .find(|l| !l.trim().is_empty())
                    .unwrap_or("");
                return Err(format!("npm install failed ({}): {last}", output.status));
            }
            let staged = Install {
                dir: staging.clone(),
            };
            if !staged.entry().is_file() {
                return Err("npm install finished without the streaming helper".into());
            }
            std::fs::write(staging.join(SENTINEL), format!("{VERSION}\n"))
                .map_err(|e| format!("recording the install: {e}"))?;
            std::fs::rename(&staging, &self.dir).map_err(|e| format!("publishing the install: {e}"))
        }
        .await;
        let _ = std::fs::remove_dir_all(&staging);
        result
    }
}

/// A running hub. Dropping it kills the process.
pub(crate) struct Hub {
    child: Child,
    pub origin: String,
}

impl Hub {
    pub(crate) fn is_alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// Start the helper, logging and recording its pid under `state_dir`.
    pub(crate) async fn start(install: &Install, state_dir: &Path) -> Result<Hub, String> {
        if !install.is_installed() {
            return Err("Simulator streaming isn't set up on this computer.".into());
        }
        let log = &state_dir.join("simulator-hub.log");
        let pid_file = state_dir.join("simulator-hub.pid");
        stop_stale(&pid_file, install);
        let node = find_tool("node").ok_or_else(|| {
            "Node.js wasn't found on this computer. Install Node.js 20 or newer, then try again."
                .to_string()
        })?;
        let port = free_port().map_err(|e| format!("finding a free port: {e}"))?;
        let log_file =
            std::fs::File::create(log).map_err(|e| format!("opening the hub log: {e}"))?;
        let mut cmd = Command::new(node);
        cmd.arg(install.entry())
            .args([
                "--port",
                &port.to_string(),
                "--host",
                "127.0.0.1",
                "--platform",
                "ios",
            ])
            .args([
                "--max-dimension",
                MAX_DIMENSION,
                "--mjpeg-quality",
                MJPEG_QUALITY,
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::from(
                log_file.try_clone().map_err(|e| e.to_string())?,
            ))
            .stderr(Stdio::from(log_file))
            .kill_on_drop(true);
        if let Some(path) = tool_path() {
            cmd.env("PATH", path);
        }
        let child = cmd
            .spawn()
            .map_err(|e| format!("starting the streaming helper: {e}"))?;
        if let Some(pid) = child.id() {
            let _ = std::fs::write(&pid_file, pid.to_string());
        }
        let mut hub = Hub {
            child,
            origin: format!("http://127.0.0.1:{port}"),
        };
        let client = reqwest::Client::new();
        let deadline = Instant::now() + READY_TIMEOUT;
        loop {
            if !hub.is_alive() {
                return Err(format!(
                    "the streaming helper exited at startup (see {})",
                    log.display()
                ));
            }
            let ready = client
                .get(format!("{}/api/devices", hub.origin))
                .timeout(Duration::from_secs(2))
                .send()
                .await
                .is_ok_and(|r| r.status().is_success());
            if ready {
                return Ok(hub);
            }
            if Instant::now() > deadline {
                return Err("the streaming helper didn't start in time".into());
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    }
}

/// An engine killed without its destructors leaves its helper running on a
/// loopback port. Stop it, but only if that pid is still this install's
/// helper (pids get reused).
fn stop_stale(pid_file: &Path, install: &Install) {
    let Some(pid) = std::fs::read_to_string(pid_file)
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok())
    else {
        return;
    };
    let _ = std::fs::remove_file(pid_file);
    #[cfg(unix)]
    {
        let command = std::process::Command::new("ps")
            .args(["-o", "command=", "-p", &pid.to_string()])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        if command.contains(&*install.entry().to_string_lossy()) {
            // SAFETY: plain signal to a pid we just matched to our own helper.
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }
}

fn free_port() -> std::io::Result<u16> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port())
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
