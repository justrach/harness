//! "Sign in with Codegraff": OAuth 2.0 authorization code + PKCE against
//! codegraff.com's OpenID Connect provider (zigrepper
//! `frontend/src/lib/oidc.ts`). The desktop app is a public (secretless)
//! native client. The provider matches `redirect_uri` exactly, so the browser
//! comes back to a FIXED loopback address, [`CALLBACK_PORT`].
//!
//! Identity only: the grant yields the account id (`sub`) and email, never
//! credits or API keys. The refresh token (offline_access) is stored so the
//! signed-in state survives restarts.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

pub const ISSUER: &str = "https://codegraff.com";
/// Registered redirect: `http://127.0.0.1:27643/callback`.
pub const CALLBACK_PORT: u16 = 27643;
const SCOPES: &str = "openid email profile offline_access";
const STORE_FILE: &str = "codegraff-auth.json";

/// The registered public client "Harness" (zigrepper
/// `scripts/oauth-client.mjs --public`, redirect [`CALLBACK_PORT`]). Public
/// client ids aren't secrets. `HARNESS_CODEGRAFF_CLIENT_ID` overrides.
const DEFAULT_CLIENT_ID: Option<&str> = Some("cg_client_43e753878956c2cf7b5b0f53");

fn client_id() -> Option<String> {
    std::env::var("HARNESS_CODEGRAFF_CLIENT_ID")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .or_else(|| DEFAULT_CLIENT_ID.map(str::to_owned))
}

/// `HARNESS_CODEGRAFF_ISSUER` points at a local codegraff for development.
fn issuer() -> String {
    std::env::var("HARNESS_CODEGRAFF_ISSUER")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| ISSUER.into())
        .trim_end_matches('/')
        .to_owned()
}

fn redirect_uri() -> String {
    format!("http://127.0.0.1:{CALLBACK_PORT}/callback")
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Stored {
    sub: String,
    email: Option<String>,
    name: Option<String>,
    refresh_token: Option<String>,
    signed_in_at: i64,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CodegraffStatus {
    /// A client id is available (sign-in can start).
    pub configured: bool,
    pub signed_in: bool,
    pub email: Option<String>,
    pub name: Option<String>,
    /// A browser sign-in is waiting for its callback.
    pub pending: bool,
    /// The last sign-in attempt's failure, if any.
    pub error: Option<String>,
}

struct Pending {
    task: tokio::task::JoinHandle<()>,
}

pub struct CodegraffAuth {
    store: PathBuf,
    pending: Mutex<Option<Pending>>,
    last_error: Mutex<Option<String>>,
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
                Arc::new(Self {
                    store: data_dir.join(STORE_FILE),
                    pending: Mutex::new(None),
                    last_error: Mutex::new(None),
                })
            })
            .clone()
    }

    fn load(&self) -> Option<Stored> {
        serde_json::from_slice(&std::fs::read(&self.store).ok()?).ok()
    }

    fn save(&self, stored: &Stored) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(stored).map_err(std::io::Error::other)?;
        std::fs::write(&self.store, bytes)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&self.store, std::fs::Permissions::from_mode(0o600))?;
        }
        Ok(())
    }

    pub fn status(&self) -> CodegraffStatus {
        let stored = self.load();
        CodegraffStatus {
            configured: client_id().is_some(),
            signed_in: stored.is_some(),
            email: stored.as_ref().and_then(|s| s.email.clone()),
            name: stored.and_then(|s| s.name),
            pending: self
                .pending
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|p| !p.task.is_finished()),
            error: self.last_error.lock().unwrap().clone(),
        }
    }

    pub fn sign_out(&self) {
        if let Some(pending) = self.pending.lock().unwrap().take() {
            pending.task.abort();
        }
        *self.last_error.lock().unwrap() = None;
        let _ = std::fs::remove_file(&self.store);
    }

    /// Start a browser sign-in: bind the loopback callback, return the
    /// authorize URL for the caller to open.
    pub async fn start_sign_in(self: &Arc<Self>) -> Result<String, String> {
        let client_id = client_id().ok_or_else(|| {
            "Codegraff sign-in isn't configured (set HARNESS_CODEGRAFF_CLIENT_ID)".to_string()
        })?;
        // A second click replaces the first attempt (and frees the port).
        let previous = self.pending.lock().unwrap().take();
        if let Some(previous) = previous {
            previous.task.abort();
            let _ = previous.task.await;
        }
        let listener = TcpListener::bind(("127.0.0.1", CALLBACK_PORT))
            .await
            .map_err(|e| format!("can't listen on 127.0.0.1:{CALLBACK_PORT}: {e}"))?;
        *self.last_error.lock().unwrap() = None;

        let verifier = random_token();
        let challenge = b64url(&Sha256::digest(verifier.as_bytes()));
        let state = random_token();
        let nonce = random_token();
        let url = authorize_url(&issuer(), &client_id, &state, &nonce, &challenge);

        let this = self.clone();
        let task = tokio::spawn(async move {
            let outcome = this.await_callback(listener, &client_id, &state, &verifier).await;
            if let Err(error) = outcome {
                tracing::warn!(%error, "codegraff sign-in failed");
                *this.last_error.lock().unwrap() = Some(error);
            }
        });
        *self.pending.lock().unwrap() = Some(Pending { task });
        Ok(url)
    }

    async fn await_callback(
        &self,
        listener: TcpListener,
        client_id: &str,
        state: &str,
        verifier: &str,
    ) -> Result<(), String> {
        loop {
            let (mut socket, _) = listener.accept().await.map_err(|e| e.to_string())?;
            let mut buf = vec![0u8; 8192];
            let n = socket.read(&mut buf).await.unwrap_or(0);
            let request = String::from_utf8_lossy(&buf[..n]);
            let Some(query) = callback_query(&request) else {
                // Favicon probes and the like: not ours, keep waiting.
                let _ = socket.write_all(http_page(404, "Not found").as_bytes()).await;
                continue;
            };
            if query.get("state").map(String::as_str) != Some(state) {
                let _ = socket
                    .write_all(http_page(400, "This sign-in link is stale. Start again from Harness.").as_bytes())
                    .await;
                continue;
            }
            if let Some(error) = query.get("error") {
                let _ = socket
                    .write_all(http_page(400, "Sign-in was cancelled. You can close this tab.").as_bytes())
                    .await;
                return Err(format!("codegraff returned {error}"));
            }
            let Some(code) = query.get("code") else {
                let _ = socket.write_all(http_page(400, "Missing code.").as_bytes()).await;
                return Err("callback without a code".into());
            };
            let result = self.finish(code, client_id, verifier).await;
            let page = match &result {
                Ok(()) => http_page(200, "Signed in to Codegraff. You can close this tab and return to Harness."),
                Err(_) => http_page(500, "Sign-in failed. Return to Harness and try again."),
            };
            let _ = socket.write_all(page.as_bytes()).await;
            return result;
        }
    }

    async fn finish(&self, code: &str, client_id: &str, verifier: &str) -> Result<(), String> {
        #[derive(Deserialize)]
        struct Tokens {
            access_token: String,
            refresh_token: Option<String>,
        }
        #[derive(Deserialize)]
        struct UserInfo {
            sub: String,
            email: Option<String>,
            name: Option<String>,
        }
        let http = reqwest::Client::new();
        let issuer = issuer();
        let response = http
            .post(format!("{issuer}/api/oauth/token"))
            .form(&[
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirect_uri().as_str()),
                ("client_id", client_id),
                ("code_verifier", verifier),
            ])
            .send()
            .await
            .map_err(|e| format!("token request failed: {e}"))?;
        if !response.status().is_success() {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            return Err(format!("token exchange rejected ({status}): {body}"));
        }
        let tokens: Tokens = response.json().await.map_err(|e| format!("bad token response: {e}"))?;
        let user: UserInfo = http
            .get(format!("{issuer}/api/oauth/userinfo"))
            .bearer_auth(&tokens.access_token)
            .send()
            .await
            .map_err(|e| format!("userinfo request failed: {e}"))?
            .error_for_status()
            .map_err(|e| format!("userinfo rejected: {e}"))?
            .json()
            .await
            .map_err(|e| format!("bad userinfo response: {e}"))?;
        self.save(&Stored {
            sub: user.sub,
            email: user.email,
            name: user.name,
            refresh_token: tokens.refresh_token,
            signed_in_at: chrono::Utc::now().timestamp(),
        })
        .map_err(|e| format!("couldn't save the sign-in: {e}"))
    }
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// 32 random bytes, base64url (a PKCE verifier is 43+ chars of this alphabet).
fn random_token() -> String {
    let mut bytes = [0u8; 32];
    bytes[..16].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes[16..].copy_from_slice(uuid::Uuid::new_v4().as_bytes());
    b64url(&bytes)
}

fn authorize_url(issuer: &str, client_id: &str, state: &str, nonce: &str, challenge: &str) -> String {
    let query = [
        ("response_type", "code"),
        ("client_id", client_id),
        ("redirect_uri", &redirect_uri()),
        ("scope", SCOPES),
        ("state", state),
        ("nonce", nonce),
        ("code_challenge", challenge),
        ("code_challenge_method", "S256"),
    ]
    .iter()
    .map(|(k, v)| format!("{k}={}", urlencode(v)))
    .collect::<Vec<_>>()
    .join("&");
    format!("{issuer}/oauth/authorize?{query}")
}

fn urlencode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn urldecode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = (bytes[i] == b'%' && i + 2 < bytes.len())
            .then(|| std::str::from_utf8(&bytes[i + 1..i + 3]).ok())
            .flatten()
            .and_then(|h| u8::from_str_radix(h, 16).ok());
        match (bytes[i], hex) {
            (_, Some(decoded)) => {
                out.push(decoded);
                i += 3;
            }
            (b'+', None) => {
                out.push(b' ');
                i += 1;
            }
            (b, None) => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The query of a `GET /callback?...` request line, decoded.
fn callback_query(request: &str) -> Option<HashMap<String, String>> {
    let line = request.lines().next()?;
    let mut parts = line.split_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let target = parts.next()?;
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    if path != "/callback" {
        return None;
    }
    Some(
        query
            .split('&')
            .filter(|kv| !kv.is_empty())
            .map(|kv| {
                let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                (urldecode(k), urldecode(v))
            })
            .collect(),
    )
}

fn http_page(status: u16, message: &str) -> String {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        _ => "Internal Server Error",
    };
    let body = format!(
        "<!doctype html><meta charset=utf-8><title>Harness</title>\
         <body style=\"font:15px -apple-system,system-ui,sans-serif;display:grid;place-items:center;height:90vh;color:#333\">\
         <p>{}</p></body>",
        message.replace('<', "&lt;")
    );
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authorize_url_carries_pkce_and_the_fixed_loopback_redirect() {
        let url = authorize_url("https://codegraff.com", "cg_client_x", "st", "no", "ch");
        assert!(url.starts_with("https://codegraff.com/oauth/authorize?response_type=code&client_id=cg_client_x"));
        assert!(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A27643%2Fcallback"));
        assert!(url.contains("scope=openid%20email%20profile%20offline_access"));
        assert!(url.contains("code_challenge=ch&code_challenge_method=S256"));
    }

    #[test]
    fn callback_query_parses_only_the_callback_path() {
        let q = callback_query("GET /callback?code=a%2Bb&state=s1 HTTP/1.1\r\nHost: x\r\n\r\n").unwrap();
        assert_eq!(q["code"], "a+b");
        assert_eq!(q["state"], "s1");
        assert!(callback_query("GET /favicon.ico HTTP/1.1\r\n").is_none());
        assert!(callback_query("POST /callback?code=x HTTP/1.1\r\n").is_none());
    }

    #[test]
    fn random_tokens_are_long_and_distinct() {
        let (a, b) = (random_token(), random_token());
        assert_ne!(a, b);
        assert!(a.len() >= 43, "PKCE verifiers need 43+ chars");
    }

    /// Full round trip against a fake provider: authorize URL → browser hits
    /// the loopback callback → code exchanged with the PKCE verifier as a
    /// public client → userinfo → account saved.
    #[tokio::test]
    async fn sign_in_round_trip_against_a_fake_provider() {
        let provider = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let issuer = format!("http://{}", provider.local_addr().unwrap());
        let seen_token_form = Arc::new(Mutex::new(String::new()));
        let seen = seen_token_form.clone();
        tokio::spawn(async move {
            loop {
                let (mut socket, _) = provider.accept().await.unwrap();
                let mut buf = vec![0u8; 16384];
                let n = socket.read(&mut buf).await.unwrap();
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                let body = if request.starts_with("POST /api/oauth/token") {
                    *seen.lock().unwrap() = request.split("\r\n\r\n").nth(1).unwrap_or("").to_owned();
                    r#"{"access_token":"cg_at_1","token_type":"Bearer","refresh_token":"cg_rt_1"}"#
                } else {
                    r#"{"sub":"7","email":"you@codegraff.dev","name":"You"}"#
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            }
        });
        // SAFETY (env): this is the only test touching these variables.
        unsafe {
            std::env::set_var("HARNESS_CODEGRAFF_ISSUER", &issuer);
            std::env::set_var("HARNESS_CODEGRAFF_CLIENT_ID", "cg_client_test");
        }
        let dir = tempfile::tempdir().unwrap();
        let auth = CodegraffAuth::shared(dir.path());
        let url = auth.start_sign_in().await.unwrap();
        assert!(url.starts_with(&format!("{issuer}/oauth/authorize?")));
        assert!(auth.status().pending);
        let state = url.split("state=").nth(1).unwrap().split('&').next().unwrap().to_owned();

        // The "browser" follows the provider's redirect back to us.
        let page = reqwest::get(format!("{}?code=the_code&state={state}", redirect_uri()))
            .await
            .unwrap()
            .text()
            .await
            .unwrap();
        assert!(page.contains("Signed in to Codegraff"), "{page}");

        let form = seen_token_form.lock().unwrap().clone();
        assert!(form.contains("grant_type=authorization_code"), "{form}");
        assert!(form.contains("code=the_code"));
        assert!(form.contains("client_id=cg_client_test"));
        assert!(form.contains("code_verifier="));
        let status = auth.status();
        assert!(status.signed_in, "{status:?}");
        assert_eq!(status.email.as_deref(), Some("you@codegraff.dev"));
        assert_eq!(status.name.as_deref(), Some("You"));
        assert_eq!(auth.load().unwrap().refresh_token.as_deref(), Some("cg_rt_1"));
        unsafe {
            std::env::remove_var("HARNESS_CODEGRAFF_ISSUER");
            std::env::remove_var("HARNESS_CODEGRAFF_CLIENT_ID");
        }
    }

    #[test]
    fn sign_out_forgets_the_account() {
        let dir = tempfile::tempdir().unwrap();
        let auth = CodegraffAuth::shared(dir.path());
        auth.save(&Stored {
            sub: "2".into(),
            email: Some("you@example.com".into()),
            name: None,
            refresh_token: Some("cg_rt_x".into()),
            signed_in_at: 0,
        })
        .unwrap();
        let status = auth.status();
        assert!(status.signed_in);
        assert_eq!(status.email.as_deref(), Some("you@example.com"));
        auth.sign_out();
        assert!(!auth.status().signed_in);
    }
}
