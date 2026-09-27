//! Harness as a connected app of browse (justrach/browse#4, protocol
//! `v1-p256-sig`, browse `docs/connected-apps.md`): agents Harness runs use
//! the user's own browser, with their sign-ins, limited to the scopes the user
//! granted in browse.
//!
//! - Pairing: `POST /pair` with Harness's public key; both apps show the same
//!   six digits; the user confirms in browse; `/pair/status` reports the
//!   scopes. browse's key is pinned from then on.
//! - Runs: each run gets a `browse` MCP server that points at a local relay
//!   ([`proxy`]) with a token for that run. Agents can't sign, so the relay
//!   signs each request, tags `tools/call` with the run's page session, checks
//!   browse's signature on the answer, and closes the run's pages when it ends.
//! - Without browse running and paired, runs get no browse server and keep
//!   using Harness's own browser pane.

mod keystore;
mod proxy;
pub mod wire;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use harness_adapters::McpServer;
use p256::ecdsa::{SigningKey, VerifyingKey};
use serde::{Deserialize, Serialize};

use keystore::KeyStore;

const STATE_FILE: &str = "browse-link.json";
const APP_NAME: &str = "Harness";

/// Where browse says where it is while Connected apps is on.
/// `HARNESS_BROWSE_CONNECT` points at a test world's file.
fn connect_file() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("HARNESS_BROWSE_CONNECT").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(path));
    }
    let home = std::env::var_os("HOME").filter(|h| !h.is_empty())?;
    Some(PathBuf::from(home).join("Library/Application Support/browse/Agent/connect.json"))
}

/// `connect.json`: `{"protocol": [...], "port": N, "browse_key": b64, "pid": N}`.
#[derive(Debug, Clone, Deserialize, PartialEq)]
struct Found {
    #[serde(default)]
    protocol: Vec<String>,
    port: u16,
    browse_key: String,
    #[serde(default)]
    pid: Option<i32>,
}

impl Found {
    fn read(path: &Path) -> Option<Self> {
        let found: Found = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
        if !found.protocol.iter().any(|p| p == wire::PROTOCOL) {
            return None;
        }
        // A file left behind by a browse that crashed.
        #[cfg(unix)]
        if let Some(pid) = found.pid
            && unsafe { libc::kill(pid, 0) } != 0
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            return None;
        }
        Some(found)
    }
}

/// The pairing Harness keeps (`browse-link.json`, 0600). No secret: the key
/// is in the [`KeyStore`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Pairing {
    client_id: String,
    /// browse's key at pairing, pinned: answers must be signed by it.
    browse_key: String,
    scopes: Vec<String>,
    paired_at: i64,
}

/// What Settings shows.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BrowseLinkStatus {
    /// browse is running with Connected apps on.
    pub browse_running: bool,
    pub paired: bool,
    pub scopes: Vec<String>,
    /// While pairing: the six digits browse should also show.
    pub pairing_code: Option<String>,
    /// The running browse isn't the one Harness paired with.
    pub key_mismatch: bool,
    pub error: Option<String>,
}

struct Pending {
    code: String,
    task: tokio::task::JoinHandle<()>,
}

pub struct BrowseLink {
    state_file: PathBuf,
    keys: KeyStore,
    pairing: Mutex<Option<Pairing>>,
    pending: Mutex<Option<Pending>>,
    last_error: Mutex<Option<String>>,
    /// run token → run id, for the relay.
    runs: Mutex<HashMap<String, String>>,
    relay: tokio::sync::Mutex<Option<proxy::Relay>>,
    connect_file: Option<PathBuf>,
}

/// A refusal or failure talking to browse.
#[derive(Debug, Clone, PartialEq)]
pub enum LinkError {
    /// Not running, or Connected apps is off.
    Unavailable,
    /// browse doesn't know this client any more (revoked, forgotten).
    UnknownClient,
    /// The answer wasn't signed by the pinned browse key.
    Untrusted,
    /// browse refused: `(status, error code, body)`.
    Refused(u16, String, serde_json::Value),
    Transport(String),
}

impl std::fmt::Display for LinkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable => write!(
                f,
                "browse isn't running with Settings › Agent › Connected apps on"
            ),
            Self::UnknownClient => write!(
                f,
                "browse no longer knows Harness; connect again in Settings"
            ),
            Self::Untrusted => write!(
                f,
                "the answer wasn't signed by the browse Harness paired with"
            ),
            Self::Refused(status, code, body) => {
                write!(f, "browse refused ({status} {code})")?;
                if let (Some(tool), Some(scope)) = (
                    body.get("tool").and_then(|v| v.as_str()),
                    body.get("scope").and_then(|v| v.as_str()),
                ) {
                    write!(f, ": {tool} needs the {scope} scope")?;
                }
                Ok(())
            }
            Self::Transport(message) => write!(f, "couldn't reach browse: {message}"),
        }
    }
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn http() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        // Loopback only; a proxy must never see these requests.
        .no_proxy()
        .build()
        .expect("reqwest client")
}

impl BrowseLink {
    /// One instance per data dir, so a pairing in progress and the relay
    /// outlive the call that started them.
    pub fn shared(data_dir: &Path) -> Arc<Self> {
        static ALL: OnceLock<Mutex<HashMap<PathBuf, Arc<BrowseLink>>>> = OnceLock::new();
        ALL.get_or_init(Default::default)
            .lock()
            .unwrap()
            .entry(data_dir.to_path_buf())
            .or_insert_with(|| {
                Arc::new(Self::new(
                    data_dir.join(STATE_FILE),
                    KeyStore::for_data_dir(data_dir),
                    connect_file(),
                ))
            })
            .clone()
    }

    fn new(state_file: PathBuf, keys: KeyStore, connect_file: Option<PathBuf>) -> Self {
        let pairing = std::fs::read(&state_file)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        Self {
            state_file,
            keys,
            pairing: Mutex::new(pairing),
            pending: Mutex::new(None),
            last_error: Mutex::new(None),
            runs: Mutex::new(HashMap::new()),
            relay: tokio::sync::Mutex::new(None),
            connect_file,
        }
    }

    fn found(&self) -> Option<Found> {
        Found::read(self.connect_file.as_deref()?)
    }

    pub fn status(&self) -> BrowseLinkStatus {
        let found = self.found();
        let pairing = self.pairing.lock().unwrap().clone();
        BrowseLinkStatus {
            browse_running: found.is_some(),
            paired: pairing.is_some(),
            scopes: pairing
                .as_ref()
                .map(|p| p.scopes.clone())
                .unwrap_or_default(),
            pairing_code: self
                .pending
                .lock()
                .unwrap()
                .as_ref()
                .map(|p| p.code.clone()),
            key_mismatch: matches!((&found, &pairing), (Some(f), Some(p)) if f.browse_key != p.browse_key),
            error: self.last_error.lock().unwrap().clone(),
        }
    }

    fn save(&self, pairing: Option<Pairing>) {
        match &pairing {
            Some(p) => {
                if let Ok(bytes) = serde_json::to_vec_pretty(p) {
                    let _ = keystore::write_private(&self.state_file, &bytes);
                }
            }
            None => {
                let _ = std::fs::remove_file(&self.state_file);
            }
        }
        *self.pairing.lock().unwrap() = pairing;
    }

    /// Start pairing: returns the six digits to show. Polls browse in the
    /// background until the user confirms, declines, or the offer expires.
    pub async fn start_pair(self: &Arc<Self>) -> Result<String, String> {
        if let Some(previous) = self.pending.lock().unwrap().take() {
            previous.task.abort();
        }
        *self.last_error.lock().unwrap() = None;
        let found = self
            .found()
            .ok_or_else(|| LinkError::Unavailable.to_string())?;
        let key = self.keys.load_or_create()?;
        let client_key = wire::public_key_b64(&key);
        let nonce = wire::nonce();
        let body = serde_json::json!({
            "client_key": client_key,
            "name": APP_NAME,
            "nonce": nonce,
            "protocol": [wire::PROTOCOL],
        });
        let response = http()
            .post(format!("http://127.0.0.1:{}/pair", found.port))
            .json(&body)
            .send()
            .await
            .map_err(|e| LinkError::Transport(e.to_string()).to_string())?;
        let status = response.status().as_u16();
        let reply: serde_json::Value = response.json().await.unwrap_or_default();
        if status != 200 {
            return Err(match reply.get("error").and_then(|v| v.as_str()) {
                Some("connected_apps_off") => {
                    "Turn on Connected apps in browse (Settings › Agent), then try again.".into()
                }
                Some("pairing_in_progress") => {
                    "browse is already pairing with another app. Finish or cancel that first."
                        .into()
                }
                other => format!("browse refused pairing ({status} {})", other.unwrap_or("")),
            });
        }
        let client_id = reply
            .get("client_id")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_owned();
        let browse_key = reply
            .get("browse_key")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_owned();
        let protocol = reply
            .get("protocol")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        // The answer to /pair isn't signed; the key it names must be the one
        // browse published, and the six digits are what stops a swap.
        if client_id.is_empty() || browse_key != found.browse_key || protocol != wire::PROTOCOL {
            return Err("browse's pairing answer didn't match what it published".into());
        }
        let code = wire::pairing_code(&browse_key, &client_key, &nonce)
            .ok_or("couldn't derive the pairing code")?;
        let expires = Duration::from_secs(
            reply
                .get("expires_in")
                .and_then(|v| v.as_u64())
                .unwrap_or(120)
                + 5,
        );
        let this = self.clone();
        let port = found.port;
        let task = tokio::spawn(async move {
            let outcome = this
                .poll_pairing(port, &key, &client_id, &browse_key, expires)
                .await;
            if let Err(error) = outcome {
                *this.last_error.lock().unwrap() = Some(error);
            }
            this.pending.lock().unwrap().take();
        });
        *self.pending.lock().unwrap() = Some(Pending {
            code: code.clone(),
            task,
        });
        Ok(code)
    }

    async fn poll_pairing(
        &self,
        port: u16,
        key: &SigningKey,
        client_id: &str,
        browse_key: &str,
        expires: Duration,
    ) -> Result<(), String> {
        let pinned = wire::parse_public_key(browse_key).ok_or("browse's key is malformed")?;
        let deadline = tokio::time::Instant::now() + expires;
        while tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let reply =
                match signed_post(port, key, client_id, &pinned, "/pair/status", b"{}").await {
                    Ok((_, body)) => body,
                    Err(LinkError::Transport(_)) => continue,
                    Err(error) => return Err(error.to_string()),
                };
            let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap_or_default();
            match reply.get("status").and_then(|v| v.as_str()) {
                Some("pending") | None => continue,
                Some("paired") => {
                    let scopes = reply
                        .get("scopes")
                        .and_then(|v| v.as_array())
                        .map(|a| {
                            a.iter()
                                .filter_map(|s| s.as_str().map(str::to_owned))
                                .collect()
                        })
                        .unwrap_or_default();
                    self.save(Some(Pairing {
                        client_id: client_id.to_owned(),
                        browse_key: browse_key.to_owned(),
                        scopes,
                        paired_at: chrono::Utc::now().timestamp(),
                    }));
                    return Ok(());
                }
                Some("declined") => return Err("Pairing was declined in browse.".into()),
                Some("expired") => return Err("The pairing code expired. Try again.".into()),
                Some(other) => return Err(format!("unexpected pairing status: {other}")),
            }
        }
        Err("browse didn't answer in time. Try again.".into())
    }

    /// Stop pairing, or forget a pairing (Disconnect). browse's own list
    /// keeps the app until the user revokes it there or it expires unused.
    pub fn disconnect(&self) {
        if let Some(pending) = self.pending.lock().unwrap().take() {
            pending.task.abort();
        }
        *self.last_error.lock().unwrap() = None;
        self.save(None);
        self.keys.delete();
        self.runs.lock().unwrap().clear();
    }

    /// The paired browse to talk to right now, if there is one.
    fn target(&self) -> Result<(Found, SigningKey, Pairing, VerifyingKey), LinkError> {
        let pairing = self
            .pairing
            .lock()
            .unwrap()
            .clone()
            .ok_or(LinkError::UnknownClient)?;
        let found = self.found().ok_or(LinkError::Unavailable)?;
        if found.browse_key != pairing.browse_key {
            return Err(LinkError::Untrusted);
        }
        let key = self.keys.load().ok_or(LinkError::UnknownClient)?;
        let pinned = wire::parse_public_key(&pairing.browse_key).ok_or(LinkError::Untrusted)?;
        Ok((found, key, pairing, pinned))
    }

    /// Signed POST to the paired browse. `UnknownClient` forgets the pairing.
    pub async fn request(&self, path: &str, body: &[u8]) -> Result<(u16, Vec<u8>), LinkError> {
        let (found, key, pairing, pinned) = self.target()?;
        let result = signed_post(found.port, &key, &pairing.client_id, &pinned, path, body).await;
        if matches!(result, Err(LinkError::UnknownClient)) {
            self.save(None);
            *self.last_error.lock().unwrap() = Some(
                "browse no longer knows Harness (revoked, or unused for 30 days). Connect again."
                    .into(),
            );
        }
        result
    }

    /// The `browse` MCP server for a run starting now, or `None` when browse
    /// isn't paired and running (the run keeps Harness's own browser pane).
    pub async fn mcp_server_for_run(self: &Arc<Self>, run_id: &str) -> Option<McpServer> {
        self.target().ok()?;
        let port = {
            let mut relay = self.relay.lock().await;
            if relay.is_none() {
                match proxy::Relay::start(Arc::downgrade(self)).await {
                    Ok(started) => *relay = Some(started),
                    Err(error) => {
                        tracing::warn!(%error, "browse relay didn't start");
                        return None;
                    }
                }
            }
            relay.as_ref()?.port()
        };
        let token = format!("{}{}", wire::nonce(), wire::nonce());
        self.runs
            .lock()
            .unwrap()
            .insert(token.clone(), run_id.to_owned());
        Some(McpServer {
            name: "browse".into(),
            url: format!("http://127.0.0.1:{port}/mcp"),
            headers: vec![("Authorization".into(), format!("Bearer {token}"))],
        })
    }

    fn run_for_token(&self, token: &str) -> Option<String> {
        self.runs.lock().unwrap().get(token).cloned()
    }

    /// The run ended: its token stops working and its pages close.
    pub fn end_run(self: &Arc<Self>, run_id: &str) {
        let had = {
            let mut runs = self.runs.lock().unwrap();
            let before = runs.len();
            runs.retain(|_, run| run != run_id);
            runs.len() != before
        };
        if !had {
            return;
        }
        let this = self.clone();
        let session = wire::session_id(run_id);
        tokio::spawn(async move {
            let body =
                serde_json::to_vec(&serde_json::json!({ "session": session })).unwrap_or_default();
            if let Err(error) = this.request("/session/close", &body).await {
                tracing::debug!(%error, "closing a run's browse pages");
            }
        });
    }
}

/// One signed request to browse at `port`, its answer's signature checked
/// against `pinned`.
async fn signed_post(
    port: u16,
    key: &SigningKey,
    client_id: &str,
    pinned: &VerifyingKey,
    path: &str,
    body: &[u8],
) -> Result<(u16, Vec<u8>), LinkError> {
    let headers = wire::sign_request(key, client_id, path, body, now_ms());
    let response = http()
        .post(format!("http://127.0.0.1:{port}{path}"))
        .header("Content-Type", "application/json")
        .header("X-Client-Id", &headers.client_id)
        .header("X-Timestamp", headers.timestamp_ms.to_string())
        .header("X-Nonce", &headers.nonce)
        .header("X-Signature", &headers.signature)
        .body(body.to_vec())
        .send()
        .await
        .map_err(|e| {
            if e.is_connect() {
                LinkError::Unavailable
            } else {
                LinkError::Transport(e.to_string())
            }
        })?;
    let status = response.status().as_u16();
    let signature = response
        .headers()
        .get("x-signature")
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned);
    let answer = response
        .bytes()
        .await
        .map_err(|e| LinkError::Transport(e.to_string()))?
        .to_vec();
    let error = serde_json::from_slice::<serde_json::Value>(&answer)
        .ok()
        .filter(|_| status >= 400);
    let code = error
        .as_ref()
        .and_then(|e| e.get("error"))
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_owned();
    // Checked before anything is believed, refusals included: an unsigned
    // "unknown_client" from whatever holds the port must not unpair Harness.
    if !wire::answer_is_signed(pinned, &answer, &headers.nonce, signature.as_deref()) {
        return Err(LinkError::Untrusted);
    }
    if status == 401 && code == "unknown_client" {
        return Err(LinkError::UnknownClient);
    }
    if status >= 400 {
        return Err(LinkError::Refused(status, code, error.unwrap_or_default()));
    }
    Ok((status, answer))
}

#[cfg(test)]
mod tests;
