//! "Sign in with Codegraff", shared 1:1 with the graff CLI's `graff login`.
//!
//! Both use codegraff's device flow (zigrepper
//! `services/codegraff-gateway/src/device.ts`): `POST /v1/device/start`, the
//! user approves at `codegraff.com/cli/auth?code=…` in the browser, and
//! `POST /v1/device/poll` hands back a `cg_sk_` gateway key once. The key is
//! written to the CLI's own file, `~/.simple-harness-codegraff.json`
//! (`{"api_key": …}`, 0600), so signing in here signs graff in, `graff login`
//! signs the app in, and signing out here (which also revokes the key) signs
//! both out.
//!
//! The app only keeps a display cache next to its data — the account email
//! keyed by a fingerprint of the key it was fetched for — never the key.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const GATEWAY: &str = "https://gateway.codegraff.com";
/// The graff CLI's credential file, relative to the home directory.
pub const KEY_FILE: &str = ".simple-harness-codegraff.json";
const IDENTITY_FILE: &str = "codegraff-identity.json";
/// The OAuth-era store: it held an unused refresh token, so it is deleted.
const LEGACY_STORE_FILE: &str = "codegraff-auth.json";
const DEVICE_LABEL: &str = "harness-desktop";

/// `HARNESS_CODEGRAFF_GATEWAY` points at a local gateway for development.
fn gateway() -> String {
    std::env::var("HARNESS_CODEGRAFF_GATEWAY")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| GATEWAY.into())
        .trim_end_matches('/')
        .to_owned()
}

fn default_key_file() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(|home| PathBuf::from(home).join(KEY_FILE))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Identity {
    /// [`fingerprint`] of the key this identity was fetched for.
    key_fingerprint: String,
    email: Option<String>,
    user_id: Option<i64>,
    signed_in_at: i64,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CodegraffStatus {
    /// Sign-in can start (kept for older UIs; the device flow needs no
    /// client registration).
    pub configured: bool,
    pub signed_in: bool,
    pub email: Option<String>,
    pub name: Option<String>,
    /// A browser approval is outstanding.
    pub pending: bool,
    /// The last sign-in attempt's failure, if any.
    pub error: Option<String>,
}

/// Account usage from the authenticated gateway summary. No API key is returned
/// or persisted with this response.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CodegraffUsage {
    pub email: String,
    pub tier: String,
    pub credits_micro_usd: i64,
    pub spend_30d_micro_usd: i64,
    pub requests_30d: i64,
    pub prompt_tokens_30d: i64,
    pub completion_tokens_30d: i64,
    pub key_budget_monthly_micro_usd: Option<i64>,
    pub key_spend_monthly_micro_usd: i64,
    pub key_budget_resets_at: String,
}

pub struct CodegraffAuth {
    identity: PathBuf,
    key_file: Option<PathBuf>,
    gateway: String,
    pending: Mutex<Option<tokio::task::JoinHandle<()>>>,
    lookup: Mutex<Option<(String, tokio::task::JoinHandle<()>)>>,
    last_error: Mutex<Option<String>>,
}

#[derive(Deserialize)]
struct DeviceStart {
    device_code: String,
    verification_uri: String,
    verification_uri_complete: Option<String>,
    expires_in: u64,
    interval: u64,
}

#[derive(Deserialize)]
struct DevicePoll {
    status: String,
    api_key: Option<String>,
    email: Option<String>,
    user_id: Option<i64>,
    interval: Option<u64>,
}

#[derive(Deserialize)]
struct Me {
    email: Option<String>,
    user_id: Option<i64>,
}

impl CodegraffAuth {
    /// One instance per data dir, so a pending sign-in outlives the call
    /// that started it.
    pub fn shared(data_dir: &Path) -> Arc<Self> {
        static ALL: OnceLock<Mutex<HashMap<PathBuf, Arc<CodegraffAuth>>>> = OnceLock::new();
        ALL.get_or_init(Default::default)
            .lock()
            .unwrap()
            .entry(data_dir.to_path_buf())
            .or_insert_with(|| {
                let _ = std::fs::remove_file(data_dir.join(LEGACY_STORE_FILE));
                Arc::new(Self::new(data_dir, default_key_file(), gateway()))
            })
            .clone()
    }

    fn new(data_dir: &Path, key_file: Option<PathBuf>, gateway: String) -> Self {
        Self {
            identity: data_dir.join(IDENTITY_FILE),
            key_file,
            gateway,
            pending: Mutex::new(None),
            lookup: Mutex::new(None),
            last_error: Mutex::new(None),
        }
    }

    /// The key graff would use: its credential file, else `CODEGRAFF_API_KEY`.
    fn current_key(&self) -> Option<String> {
        self.key_file
            .as_deref()
            .and_then(read_key_file)
            .or_else(|| {
                std::env::var("CODEGRAFF_API_KEY")
                    .ok()
                    .filter(|key| !key.trim().is_empty())
            })
    }

    fn load_identity(&self) -> Option<Identity> {
        serde_json::from_slice(&std::fs::read(&self.identity).ok()?).ok()
    }

    fn save_identity(&self, identity: &Identity) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(identity).map_err(std::io::Error::other)?;
        write_private(&self.identity, &bytes)
    }

    pub fn status(self: &Arc<Self>) -> CodegraffStatus {
        let key = self.current_key();
        let identity = key.as_deref().and_then(|key| {
            let identity = self.load_identity()?;
            (identity.key_fingerprint == fingerprint(key)).then_some(identity)
        });
        // Signed in by `graff login` (or a key we haven't described yet):
        // look the account up once, in the background.
        if let (Some(key), None) = (&key, &identity) {
            self.spawn_lookup(key.clone());
        }
        CodegraffStatus {
            configured: true,
            signed_in: key.is_some(),
            email: identity.and_then(|identity| identity.email),
            name: None,
            pending: self
                .pending
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|task| !task.is_finished()),
            error: self.last_error.lock().unwrap().clone(),
        }
    }

    fn spawn_lookup(self: &Arc<Self>, key: String) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let print = fingerprint(&key);
        let mut lookup = self.lookup.lock().unwrap();
        if lookup.as_ref().is_some_and(|(seen, _)| *seen == print) {
            return;
        }
        let this = self.clone();
        let task = runtime.spawn(async move {
            match this.fetch_me(&key).await {
                Ok(me) => {
                    let _ = this.save_identity(&Identity {
                        key_fingerprint: fingerprint(&key),
                        email: me.email,
                        user_id: me.user_id,
                        signed_in_at: chrono::Utc::now().timestamp(),
                    });
                }
                // Older gateways have no /v1/me: stay signed in, just nameless.
                Err(error) => tracing::debug!(%error, "codegraff account lookup failed"),
            }
        });
        *lookup = Some((print, task));
    }

    async fn fetch_me(&self, key: &str) -> Result<Me, String> {
        crate::auth::validate_secure_url("CodeGraff gateway", &self.gateway)?;
        http()
            .get(format!("{}/v1/me", self.gateway))
            .bearer_auth(key)
            .send()
            .await
            .map_err(|e| e.to_string())?
            .error_for_status()
            .map_err(|e| e.to_string())?
            .json()
            .await
            .map_err(|e| e.to_string())
    }

    pub async fn usage(&self) -> Result<Option<CodegraffUsage>, String> {
        let Some(key) = self.current_key() else {
            return Ok(None);
        };
        crate::auth::validate_secure_url("CodeGraff gateway", &self.gateway)?;
        let usage = http()
            .get(format!("{}/v1/usage/summary", self.gateway))
            .bearer_auth(key)
            .send()
            .await
            .map_err(|e| format!("couldn't reach CodeGraff: {e}"))?
            .error_for_status()
            .map_err(|e| format!("CodeGraff usage is unavailable: {e}"))?
            .json::<CodegraffUsage>()
            .await
            .map_err(|e| format!("unexpected CodeGraff usage response: {e}"))?;
        Ok(Some(usage))
    }

    /// Revoke the key server-side (best effort — an unreachable gateway must
    /// not keep anyone signed in), then remove it from graff's file.
    pub async fn sign_out(&self) {
        if let Some(pending) = self.pending.lock().unwrap().take() {
            pending.abort();
        }
        *self.last_error.lock().unwrap() = None;
        let file_key = self.key_file.as_deref().and_then(read_key_file);
        if let Some(key) = &file_key
            && crate::auth::validate_secure_url("CodeGraff gateway", &self.gateway).is_ok()
        {
            let revoked = http()
                .post(format!("{}/v1/keys/revoke", self.gateway))
                .bearer_auth(key)
                .timeout(Duration::from_secs(5))
                .send()
                .await;
            if let Err(error) = revoked {
                tracing::warn!(%error, "couldn't revoke the codegraff key; removing it locally");
            }
        }
        if let Some(path) = &self.key_file {
            let _ = std::fs::remove_file(path);
        }
        let _ = std::fs::remove_file(&self.identity);
    }

    /// Start a device sign-in: returns the approval URL for the caller to open
    /// and polls for the key in the background.
    pub async fn start_sign_in(self: &Arc<Self>) -> Result<String, String> {
        crate::auth::validate_secure_url("CodeGraff gateway", &self.gateway)?;
        if self.key_file.is_none() {
            return Err("no home directory to store the Codegraff key in".into());
        }
        // A second click replaces the first attempt.
        if let Some(previous) = self.pending.lock().unwrap().take() {
            previous.abort();
        }
        *self.last_error.lock().unwrap() = None;
        let start: DeviceStart = http()
            .post(format!("{}/v1/device/start", self.gateway))
            .json(&serde_json::json!({ "device_label": DEVICE_LABEL }))
            .send()
            .await
            .map_err(|e| format!("couldn't reach Codegraff: {e}"))?
            .error_for_status()
            .map_err(|e| format!("Codegraff refused the sign-in: {e}"))?
            .json()
            .await
            .map_err(|e| format!("unexpected Codegraff response: {e}"))?;
        let url = start
            .verification_uri_complete
            .clone()
            .unwrap_or_else(|| start.verification_uri.clone());
        crate::auth::validate_secure_url("CodeGraff approval", &url)?;
        let this = self.clone();
        let task = tokio::spawn(async move {
            if let Err(error) = this.poll(start).await {
                tracing::warn!(%error, "codegraff sign-in failed");
                *this.last_error.lock().unwrap() = Some(error);
            }
        });
        *self.pending.lock().unwrap() = Some(task);
        Ok(url)
    }

    async fn poll(&self, start: DeviceStart) -> Result<(), String> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(start.expires_in.max(1));
        let mut interval = start.interval.clamp(1, 30);
        loop {
            tokio::time::sleep(Duration::from_secs(interval)).await;
            if tokio::time::Instant::now() >= deadline {
                return Err("The sign-in link expired. Try again.".into());
            }
            let response = http()
                .post(format!("{}/v1/device/poll", self.gateway))
                .json(&serde_json::json!({ "device_code": start.device_code }))
                .send()
                .await;
            // Transient network trouble: keep polling, like `graff login`.
            let Ok(response) = response else { continue };
            let Ok(poll) = response.json::<DevicePoll>().await else {
                continue;
            };
            match poll.status.as_str() {
                "pending" => interval = poll.interval.unwrap_or(interval).clamp(1, 30),
                "ok" => {
                    let key = poll.api_key.ok_or("Codegraff approved without a key")?;
                    return self.finish(&key, poll.email, poll.user_id).await;
                }
                "denied" => return Err("Sign-in was denied in the browser.".into()),
                "expired" => return Err("The sign-in link expired. Try again.".into()),
                "consumed" => return Err("This sign-in was already used. Try again.".into()),
                "not_found" => return Err("Codegraff lost this sign-in. Try again.".into()),
                _ => {}
            }
        }
    }

    async fn finish(
        &self,
        key: &str,
        email: Option<String>,
        user_id: Option<i64>,
    ) -> Result<(), String> {
        let path = self.key_file.as_ref().ok_or("no home directory")?;
        let bytes = serde_json::to_vec_pretty(&serde_json::json!({ "api_key": key }))
            .map_err(|e| e.to_string())?;
        write_private(path, &bytes).map_err(|e| format!("couldn't save the Codegraff key: {e}"))?;
        // Older gateways omit the email from the poll; ask /v1/me instead.
        let (email, user_id) = match email {
            Some(email) => (Some(email), user_id),
            None => match self.fetch_me(key).await {
                Ok(me) => (me.email, me.user_id.or(user_id)),
                Err(_) => (None, user_id),
            },
        };
        let _ = self.save_identity(&Identity {
            key_fingerprint: fingerprint(key),
            email,
            user_id,
            signed_in_at: chrono::Utc::now().timestamp(),
        });
        Ok(())
    }
}

fn http() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("harness/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("construct CodeGraff auth HTTP client")
}

/// graff's credential file: `{"api_key": …}` (extra fields are ignored, as
/// graff itself does).
fn read_key_file(path: &Path) -> Option<String> {
    let value: serde_json::Value = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    value
        .get("api_key")?
        .as_str()
        .map(str::trim)
        .filter(|key| !key.is_empty())
        .map(str::to_owned)
}

/// Identifies which key a cached identity belongs to without storing it.
fn fingerprint(key: &str) -> String {
    format!("{:x}", Sha256::digest(key.as_bytes()))[..16].to_owned()
}

/// Write via a fresh 0600 temp file and rename, so a crash never leaves a
/// half-written or world-readable credential, and a symlink cannot redirect it.
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".codegraff-{}.tmp", uuid::Uuid::new_v4().simple()));
    let result = (|| {
        use std::io::Write as _;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// A fake gateway: answers device start/poll, /v1/me, usage, and revoke, and
    /// records every request line + body it saw.
    async fn fake_gateway(poll_body: &'static str) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buf = vec![0u8; 16384];
                let n = socket.read(&mut buf).await.unwrap();
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                log.lock().unwrap().push(request.clone());
                let body = if request.starts_with("POST /v1/device/start") {
                    r#"{"device_code":"dc","user_code":"ABCD-EFGH","verification_uri":"https://codegraff.com/cli/auth","verification_uri_complete":"https://codegraff.com/cli/auth?code=ABCD-EFGH","expires_in":600,"interval":1}"#
                } else if request.starts_with("POST /v1/device/poll") {
                    poll_body
                } else if request.starts_with("GET /v1/me") {
                    r#"{"user_id":7,"email":"me@codegraff.dev","tier":"free","credits_micro_usd":0,"key_id":1,"scopes":["api"]}"#
                } else if request.starts_with("GET /v1/usage/summary") {
                    r#"{"email":"me@codegraff.dev","tier":"pro","credits_micro_usd":5000000,"spend_30d_micro_usd":1200000,"requests_30d":9,"prompt_tokens_30d":1000,"completion_tokens_30d":500,"key_budget_monthly_micro_usd":8000000,"key_spend_monthly_micro_usd":2000000,"key_budget_resets_at":"2026-10-01T00:00:00.000Z"}"#
                } else {
                    r#"{"ok":true,"key_id":1}"#
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            }
        });
        (base, seen)
    }

    fn auth_in(dir: &Path, gateway: String) -> Arc<CodegraffAuth> {
        Arc::new(CodegraffAuth::new(
            dir,
            Some(dir.join("home").join(KEY_FILE)),
            gateway,
        ))
    }

    #[tokio::test]
    async fn device_sign_in_writes_graffs_key_file() {
        let (gateway, seen) = fake_gateway(
            r#"{"status":"ok","api_key":"cg_sk_test","user_id":7,"device_label":"harness-desktop","email":"you@codegraff.dev"}"#,
        )
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), gateway);
        let url = auth.start_sign_in().await.unwrap();
        assert_eq!(url, "https://codegraff.com/cli/auth?code=ABCD-EFGH");
        assert!(auth.status().pending);
        let pending = auth.pending.lock().unwrap().take().unwrap();
        pending.await.unwrap();

        let key_file = dir.path().join("home").join(KEY_FILE);
        let written: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&key_file).unwrap()).unwrap();
        assert_eq!(written, serde_json::json!({ "api_key": "cg_sk_test" }));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                key_file.metadata().unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let status = auth.status();
        assert!(status.signed_in, "{status:?}");
        assert_eq!(status.email.as_deref(), Some("you@codegraff.dev"));
        let requests = seen.lock().unwrap().join("\n");
        assert!(
            requests.contains(r#""device_label":"harness-desktop""#),
            "{requests}"
        );
        assert!(requests.contains(r#""device_code":"dc""#), "{requests}");
        // The identity cache never holds the key.
        let cache = std::fs::read_to_string(dir.path().join(IDENTITY_FILE)).unwrap();
        assert!(!cache.contains("cg_sk_test"));
    }

    #[tokio::test]
    async fn a_graff_login_key_signs_the_app_in_and_fetches_the_email() {
        let (gateway, seen) = fake_gateway(r#"{"status":"pending"}"#).await;
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), gateway);
        write_private(
            &dir.path().join("home").join(KEY_FILE),
            br#"{"api_key":"cg_sk_from_cli"}"#,
        )
        .unwrap();
        let status = auth.status();
        assert!(status.signed_in);
        assert_eq!(status.email, None);
        let lookup = auth.lookup.lock().unwrap().take().unwrap().1;
        lookup.await.unwrap();
        assert_eq!(auth.status().email.as_deref(), Some("me@codegraff.dev"));
        assert!(
            seen.lock()
                .unwrap()
                .iter()
                .any(|r| r.starts_with("GET /v1/me") && r.contains("Bearer cg_sk_from_cli"))
        );
        // A different key (another `graff login`) doesn't inherit the email.
        write_private(
            &dir.path().join("home").join(KEY_FILE),
            br#"{"api_key":"cg_sk_other"}"#,
        )
        .unwrap();
        assert_eq!(auth.status().email, None);
    }

    #[tokio::test]
    async fn usage_reads_the_signed_in_graff_accounts_summary() {
        let (gateway, seen) = fake_gateway(r#"{"status":"pending"}"#).await;
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), gateway);
        write_private(
            &dir.path().join("home").join(KEY_FILE),
            br#"{"api_key":"cg_sk_usage_test"}"#,
        )
        .unwrap();

        let usage = auth.usage().await.unwrap().unwrap();
        assert_eq!(usage.email, "me@codegraff.dev");
        assert_eq!(usage.credits_micro_usd, 5_000_000);
        assert_eq!(usage.spend_30d_micro_usd, 1_200_000);
        assert_eq!(usage.key_budget_monthly_micro_usd, Some(8_000_000));
        assert!(seen.lock().unwrap().iter().any(|request| {
            request.starts_with("GET /v1/usage/summary")
                && request.contains("Bearer cg_sk_usage_test")
        }));
        assert!(!serde_json::to_string(&usage)
            .unwrap()
            .contains("cg_sk_usage_test"));
    }

    #[cfg(unix)]
    #[test]
    fn private_key_write_replaces_symlink_without_following_it() {
        use std::os::unix::fs::{PermissionsExt, symlink};

        let dir = tempfile::tempdir().unwrap();
        let outside = dir.path().join("outside");
        std::fs::write(&outside, b"unchanged").unwrap();
        let key = dir.path().join(KEY_FILE);
        symlink(&outside, &key).unwrap();

        write_private(&key, b"private-key").unwrap();
        assert_eq!(std::fs::read(&outside).unwrap(), b"unchanged");
        assert_eq!(std::fs::read(&key).unwrap(), b"private-key");
        assert_eq!(key.metadata().unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[tokio::test]
    async fn sign_out_revokes_and_signs_graff_out_too() {
        let (gateway, seen) = fake_gateway(r#"{"status":"pending"}"#).await;
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), gateway);
        let key_file = dir.path().join("home").join(KEY_FILE);
        write_private(&key_file, br#"{"api_key":"cg_sk_bye"}"#).unwrap();
        auth.sign_out().await;
        assert!(!key_file.exists());
        assert!(
            seen.lock()
                .unwrap()
                .iter()
                .any(|r| r.starts_with("POST /v1/keys/revoke") && r.contains("Bearer cg_sk_bye"))
        );
    }

    #[tokio::test]
    async fn sign_out_still_forgets_the_key_when_the_gateway_is_down() {
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), "http://127.0.0.1:9".into());
        let key_file = dir.path().join("home").join(KEY_FILE);
        write_private(&key_file, br#"{"api_key":"cg_sk_offline"}"#).unwrap();
        auth.sign_out().await;
        assert!(!key_file.exists());
    }

    #[tokio::test]
    async fn denied_approval_surfaces_an_error() {
        let (gateway, _) = fake_gateway(r#"{"status":"denied"}"#).await;
        let dir = tempfile::tempdir().unwrap();
        let auth = auth_in(dir.path(), gateway);
        auth.start_sign_in().await.unwrap();
        let pending = auth.pending.lock().unwrap().take().unwrap();
        pending.await.unwrap();
        let status = auth.status();
        assert!(!status.signed_in);
        assert!(status.error.unwrap().contains("denied"));
    }

    #[test]
    fn key_file_reader_matches_graff() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(KEY_FILE);
        std::fs::write(&path, r#"{"api_key":" cg_sk_x ","email":"extra@ok"}"#).unwrap();
        assert_eq!(read_key_file(&path).as_deref(), Some("cg_sk_x"));
        std::fs::write(&path, r#"{"api_key":""}"#).unwrap();
        assert_eq!(read_key_file(&path), None);
        std::fs::write(&path, "not json").unwrap();
        assert_eq!(read_key_file(&path), None);
    }
}
