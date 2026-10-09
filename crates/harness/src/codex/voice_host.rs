//! Codex's packaged WebRTC voice helper (`codex-resources/voice/bin/codex-voice-host`,
//! Apache-2.0, openai/codex `codex-rs/voice-host`). Audio capture, echo
//! cancellation and the encrypted media stay inside that native process; only
//! bounded SDP signaling, controls and level meters cross this pipe, as
//! big-endian length-prefixed JSON frames.
//!
//! Harness never ships this runtime: it uses the one inside the device's own
//! Codex installation (a standalone install, or the npm package's platform
//! payload), resolved from the `codex` executable.
//!
//! Adapted from upstream zeronsh/zeron `crates/voice-media` (MIT).

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{ChildStdin, ChildStdout, Command};

use crate::CancellationToken;

const MAX_FRAME: usize = 128 * 1024;
/// The first Codex release whose package carries the voice helper.
const MIN_VERSION: semver::Version = semver::Version::new(0, 159, 0);

const HELPER: &str = if cfg!(windows) {
    "bin/codex-voice-host.exe"
} else {
    "bin/codex-voice-host"
};

/// Why the helper can't be used.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum VoiceHostError {
    /// No Codex installation with a voice helper on this device.
    #[error("dictation needs the Codex CLI 0.159 or newer")]
    Unavailable,
    /// The helper is there but refused to start its runtime.
    #[error("Codex's voice runtime would not start")]
    RuntimeUnavailable,
    /// The microphone could not be opened.
    #[error("the microphone could not be opened")]
    DeviceUnavailable,
    /// The helper broke the protocol, timed out, or exited.
    #[error("Codex's voice helper stopped responding")]
    Protocol,
}

/// A running helper. Dropping it (or cancelling `stop`) kills the process.
pub struct VoiceHost {
    stop: CancellationToken,
    input: ChildStdin,
    output: ChildStdout,
    device_selection: bool,
}

impl Drop for VoiceHost {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

impl VoiceHost {
    fn command(path: &Path) -> Command {
        let mut cmd = Command::new(path);
        // Fixed allowlist, as Codex does: never inherit API keys or dynamic
        // loader / plugin overrides.
        cmd.env_clear();
        for (key, value) in std::env::vars_os() {
            if matches!(
                key.to_string_lossy().to_ascii_uppercase().as_str(),
                "SYSTEMROOT"
                    | "WINDIR"
                    | "HOME"
                    | "USERPROFILE"
                    | "LOCALAPPDATA"
                    | "APPDATA"
                    | "TEMP"
                    | "TMP"
                    | "TMPDIR"
                    | "XDG_RUNTIME_DIR"
                    | "PULSE_SERVER"
                    | "PULSE_COOKIE"
                    | "PIPEWIRE_REMOTE"
                    | "DBUS_SESSION_BUS_ADDRESS"
                    | "HTTP_PROXY"
                    | "HTTPS_PROXY"
                    | "ALL_PROXY"
                    | "NO_PROXY"
                    | "SSL_CERT_FILE"
                    | "SSL_CERT_DIR"
                    | "REQUESTS_CA_BUNDLE"
                    | "CURL_CA_BUNDLE"
            ) {
                cmd.env(key, value);
            }
        }
        // The helper's runtime refuses to initialize unless its private
        // GStreamer environment is exactly this (no registry, no scanning).
        for key in [
            "GST_PLUGIN_PATH",
            "GST_PLUGIN_PATH_1_0",
            "GST_PLUGIN_SYSTEM_PATH",
            "GST_PLUGIN_SYSTEM_PATH_1_0",
        ] {
            cmd.env(key, "");
        }
        cmd.env(
            "GST_REGISTRY",
            if cfg!(windows) { "NUL" } else { "/dev/null" },
        )
        .env("GST_REGISTRY_UPDATE", "no")
        .env("GST_REGISTRY_FORK", "no");
        #[cfg(target_os = "linux")]
        for directory in [
            "/usr/lib/x86_64-linux-gnu/alsa-lib",
            "/usr/lib/aarch64-linux-gnu/alsa-lib",
            "/usr/lib64/alsa-lib",
            "/usr/lib/alsa-lib",
        ] {
            if Path::new(directory).is_dir() {
                cmd.env("ALSA_PLUGIN_DIR", directory);
                break;
            }
        }
        if let Some(dir) = path.parent() {
            cmd.current_dir(dir);
        }
        cmd.stdin(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        cmd
    }

    /// Start the helper and its media runtime. No device is opened yet.
    pub async fn open(path: &Path, stop: CancellationToken) -> Result<Self, VoiceHostError> {
        let device_selection = helper_device_selection(path)?;
        let probe = tokio::time::timeout(
            Duration::from_secs(5),
            Self::command(path).arg("--build-commit").output(),
        )
        .await
        .map_err(|_| VoiceHostError::RuntimeUnavailable)?
        .map_err(|_| VoiceHostError::RuntimeUnavailable)?;
        let commit = std::str::from_utf8(&probe.stdout)
            .ok()
            .map(str::trim)
            .filter(|s| !s.is_empty() && s.len() <= 128 && probe.status.success())
            .ok_or(VoiceHostError::RuntimeUnavailable)?
            .to_owned();
        let mut child = Self::command(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|_| VoiceHostError::RuntimeUnavailable)?;
        let input = child.stdin.take().ok_or(VoiceHostError::Protocol)?;
        let output = child.stdout.take().ok_or(VoiceHostError::Protocol)?;
        let reaper = stop.clone();
        tokio::spawn(async move {
            tokio::select! {
                biased;
                _ = reaper.cancelled() => {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                }
                _ = child.wait() => {}
            }
        });
        let mut host = Self {
            stop,
            input,
            output,
            device_selection,
        };
        // A helper that cannot start its runtime exits here: that is the
        // runtime, not the session.
        let unavailable = |e| match e {
            VoiceHostError::Protocol => VoiceHostError::RuntimeUnavailable,
            e => e,
        };
        host.expect(
            json!({"type": "hello", "protocol": 1, "buildCommit": commit}),
            "ready",
            30,
        )
        .await
        .map_err(unavailable)?;
        host.expect(json!({"type": "initializeRuntime"}), "runtimeReady", 30)
            .await
            .map_err(unavailable)?;
        Ok(host)
    }

    /// One request, one reply. A failure (or a dropped future mid-read)
    /// leaves the pipe unusable, so it also stops the helper.
    pub async fn exchange(
        &mut self,
        message: Value,
        seconds: u64,
    ) -> Result<Value, VoiceHostError> {
        if self.stop.is_cancelled() {
            return Err(VoiceHostError::Protocol);
        }
        struct Guard(Option<CancellationToken>);
        impl Drop for Guard {
            fn drop(&mut self) {
                if let Some(stop) = &self.0 {
                    stop.cancel();
                }
            }
        }
        let mut guard = Guard(Some(self.stop.clone()));
        let result = tokio::time::timeout(Duration::from_secs(seconds), async {
            let payload = serde_json::to_vec(&message).map_err(|_| VoiceHostError::Protocol)?;
            if payload.len() > MAX_FRAME {
                return Err(VoiceHostError::Protocol);
            }
            self.input
                .write_u32(payload.len() as u32)
                .await
                .map_err(|_| VoiceHostError::Protocol)?;
            self.input
                .write_all(&payload)
                .await
                .map_err(|_| VoiceHostError::Protocol)?;
            self.input
                .flush()
                .await
                .map_err(|_| VoiceHostError::Protocol)?;
            let length = self
                .output
                .read_u32()
                .await
                .map_err(|_| VoiceHostError::Protocol)? as usize;
            if length == 0 || length > MAX_FRAME {
                return Err(VoiceHostError::Protocol);
            }
            let mut payload = vec![0; length];
            self.output
                .read_exact(&mut payload)
                .await
                .map_err(|_| VoiceHostError::Protocol)?;
            serde_json::from_slice(&payload).map_err(|_| VoiceHostError::Protocol)
        })
        .await
        .map_err(|_| VoiceHostError::Protocol)?;
        if result.is_ok() {
            guard.0 = None;
        }
        result
    }

    pub async fn expect(
        &mut self,
        message: Value,
        reply: &str,
        seconds: u64,
    ) -> Result<(), VoiceHostError> {
        if self.exchange(message, seconds).await?["type"] != reply {
            self.stop.cancel();
            return Err(VoiceHostError::Protocol);
        }
        Ok(())
    }

    /// The WebRTC offer for the realtime session.
    pub async fn offer(&mut self) -> Result<String, VoiceHostError> {
        let offer = self.exchange(json!({"type": "startTransport"}), 20).await?;
        if offer["type"] != "offer" {
            return Err(VoiceHostError::Protocol);
        }
        offer["sdp"]
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 64 * 1024)
            .map(str::to_owned)
            .ok_or(VoiceHostError::Protocol)
    }

    pub async fn apply_answer(&mut self, sdp: &str) -> Result<(), VoiceHostError> {
        self.expect(
            json!({"type": "applyAnswer", "sdp": sdp}),
            "transportReady",
            20,
        )
        .await
    }

    /// Open the default microphone and speaker.
    pub async fn open_devices(&mut self) -> Result<(), VoiceHostError> {
        let mut message = json!({"type": "openDevices"});
        // Codex 0.161 requires `selection` even for the default devices; older
        // helpers reject the field despite sharing protocol version 1.
        if self.device_selection {
            message["selection"] = json!({});
        }
        self.expect(message, "devicesOpened", 5)
            .await
            .map_err(|_| VoiceHostError::DeviceUnavailable)
    }

    /// Dictation never plays the model's audio, so the speaker stays suppressed.
    pub async fn set_muted(&mut self, muted: bool) -> Result<(), VoiceHostError> {
        self.expect(
            json!({"type": "setAudioControls", "controls": {"microphoneMuted": muted, "speakerSuppressed": true}}),
            "audioControlsApplied",
            5,
        )
        .await
    }

    /// The microphone's current peak, 0..=u16::MAX.
    pub async fn microphone_level(&mut self) -> Result<u16, VoiceHostError> {
        let reply = self.exchange(json!({"type": "inspectAudio"}), 5).await?;
        if reply["type"] != "audioState" {
            return Err(VoiceHostError::Protocol);
        }
        reply["state"]["microphonePeak"]
            .as_u64()
            .and_then(|n| u16::try_from(n).ok())
            .ok_or(VoiceHostError::Protocol)
    }

    /// Close the peer and devices, then the process.
    pub async fn close(mut self) {
        let _ = self.exchange(json!({"type": "close"}), 2).await;
        self.stop.cancel();
    }
}

/// Codex 0.161 changed `openDevices`; the helper's version is in the voice
/// manifest next to it. A runtime without that manifest uses the original form.
fn helper_device_selection(path: &Path) -> Result<bool, VoiceHostError> {
    let voice = path
        .parent()
        .and_then(Path::parent)
        .ok_or(VoiceHostError::Unavailable)?;
    let bytes = match std::fs::read(voice.join("manifest.json")) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(_) => return Err(VoiceHostError::RuntimeUnavailable),
    };
    let manifest: Value =
        serde_json::from_slice(&bytes).map_err(|_| VoiceHostError::RuntimeUnavailable)?;
    let version = manifest["appVersion"]
        .as_str()
        .and_then(|v| semver::Version::parse(v).ok())
        .ok_or(VoiceHostError::RuntimeUnavailable)?;
    Ok(version >= semver::Version::new(0, 161, 0))
}

/// The voice helper inside the Codex installation behind `codex_executable`:
/// a standalone install (`<root>/bin/codex` + `<root>/codex-package.json`), or
/// npm's `codex` shim, whose platform package carries the same layout under
/// `node_modules/@openai/codex-<platform>/vendor/<target>/`.
pub fn helper_for(codex_executable: &Path) -> Result<PathBuf, VoiceHostError> {
    let executable = codex_executable
        .canonicalize()
        .map_err(|_| VoiceHostError::Unavailable)?;
    let mut roots = Vec::new();
    if let Some(root) = executable.parent().and_then(Path::parent) {
        roots.push(root.to_path_buf());
        // npm: <package>/bin/codex.js → <package>/node_modules/@openai/codex-*/vendor/<target>
        let scoped = root.join("node_modules").join("@openai");
        if let Ok(entries) = std::fs::read_dir(&scoped) {
            for entry in entries.flatten() {
                if entry.file_name().to_string_lossy().starts_with("codex-") {
                    if let Ok(target) = runtime_target() {
                        roots.push(entry.path().join("vendor").join(target));
                    }
                }
            }
        }
    }
    let mut found = Err(VoiceHostError::Unavailable);
    for root in roots {
        match helper_in(&root) {
            Ok(path) => return Ok(path),
            Err(VoiceHostError::Unavailable) => {}
            Err(e) => found = Err(e),
        }
    }
    found
}

fn helper_in(root: &Path) -> Result<PathBuf, VoiceHostError> {
    let Ok(bytes) = std::fs::read(root.join("codex-package.json")) else {
        return Err(VoiceHostError::Unavailable);
    };
    let package: Value = serde_json::from_slice(&bytes).map_err(|_| VoiceHostError::Unavailable)?;
    let version = package["version"]
        .as_str()
        .and_then(|v| semver::Version::parse(v).ok())
        .ok_or(VoiceHostError::Unavailable)?;
    if package["layoutVersion"] != 1 || version < MIN_VERSION {
        return Err(VoiceHostError::Unavailable);
    }
    let path = root.join("codex-resources/voice").join(HELPER);
    // The runtime only initializes from its real codex-resources/voice
    // directory, so a symlinked helper is as good as missing.
    if path.canonicalize().ok().as_ref() != Some(&path) || !path.is_file() {
        return Err(VoiceHostError::Unavailable);
    }
    Ok(path)
}

fn runtime_target() -> Result<&'static str, VoiceHostError> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Ok("aarch64-apple-darwin"),
        ("macos", "x86_64") => Ok("x86_64-apple-darwin"),
        ("linux", "x86_64") => Ok("x86_64-unknown-linux-musl"),
        ("linux", "aarch64") => Ok("aarch64-unknown-linux-musl"),
        ("windows", "x86_64") => Ok("x86_64-pc-windows-msvc"),
        ("windows", "aarch64") => Ok("aarch64-pc-windows-msvc"),
        _ => Err(VoiceHostError::Unavailable),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn package(root: &Path, version: &str, helper: bool) -> PathBuf {
        let codex = root.join("bin/codex");
        std::fs::create_dir_all(codex.parent().unwrap()).unwrap();
        std::fs::write(&codex, "").unwrap();
        std::fs::write(
            root.join("codex-package.json"),
            json!({"layoutVersion": 1, "version": version}).to_string(),
        )
        .unwrap();
        if helper {
            let path = root.join("codex-resources/voice").join(HELPER);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, "").unwrap();
        }
        codex
    }

    #[test]
    fn helper_resolves_from_a_standalone_install() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("codex");
        let codex = package(&root, "0.160.0", true);
        assert_eq!(
            helper_for(&codex).unwrap(),
            root.join("codex-resources/voice").join(HELPER)
        );
        package(&root, "0.158.9", true);
        assert_eq!(helper_for(&codex).unwrap_err(), VoiceHostError::Unavailable);
    }

    #[test]
    fn helper_resolves_through_the_npm_shim() {
        let temp = tempfile::tempdir().unwrap();
        let pkg = temp.path().canonicalize().unwrap().join("codex");
        let shim = pkg.join("bin/codex.js");
        std::fs::create_dir_all(shim.parent().unwrap()).unwrap();
        std::fs::write(&shim, "").unwrap();
        let Ok(target) = runtime_target() else { return };
        let vendor = pkg
            .join("node_modules/@openai/codex-test-platform/vendor")
            .join(target);
        package(&vendor, "0.160.0", true);
        assert_eq!(
            helper_for(&shim).unwrap(),
            vendor.join("codex-resources/voice").join(HELPER)
        );
    }

    #[test]
    fn a_package_without_the_helper_is_unavailable() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("codex");
        let codex = package(&root, "0.160.0", false);
        assert_eq!(helper_for(&codex).unwrap_err(), VoiceHostError::Unavailable);
    }

    #[test]
    fn device_selection_follows_the_helper_version() {
        let temp = tempfile::tempdir().unwrap();
        let voice = temp.path().join("codex-resources/voice");
        let helper = voice.join(HELPER);
        std::fs::create_dir_all(helper.parent().unwrap()).unwrap();
        assert!(!helper_device_selection(&helper).unwrap());
        for (version, expected) in [("0.160.0", false), ("0.161.0", true), ("0.170.2", true)] {
            std::fs::write(
                voice.join("manifest.json"),
                json!({"appVersion": version}).to_string(),
            )
            .unwrap();
            assert_eq!(
                helper_device_selection(&helper).unwrap(),
                expected,
                "{version}"
            );
        }
        std::fs::write(voice.join("manifest.json"), "{").unwrap();
        assert!(helper_device_selection(&helper).is_err());
    }
}
