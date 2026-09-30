//! Harness's own Sign in with ChatGPT (plan usage) for open-source apps.
//!
//! Authorization code + PKCE with a loopback redirect on this host
//! (`http://127.0.0.1:<port>/auth/callback`), dynamic client registration under
//! the app's own name, and a host id that never changes. The result lands in
//! Harness's credential store ([`super::plan`]); Graff and Codex logins are
//! never read or written.
//!
//! The browser opens on the host, so a phone only starts the sign-in, watches
//! its progress and can cancel it.

use super::plan::{self, RESOURCE, Registration, TOKEN_ENDPOINT, iso8601, now};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_util::sync::CancellationToken;

/// The name OpenAI shows the user when they approve this app.
const AGENT_NAME: &str = "Harness";
const ISSUER: &str = "https://auth.openai.com";
const AUTHORIZE_ENDPOINT: &str = "https://auth.openai.com/api/accounts/authorize";
const JWKS_ENDPOINT: &str = "https://auth.openai.com/.well-known/jwks.json";
const REVOKE_ENDPOINT: &str = "https://auth.openai.com/api/accounts/oauth/revoke";
const SCOPES: &str =
    "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
/// The user has this long to finish in the browser.
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(300);

/// Where each OpenAI endpoint lives (overridable so tests can stand one up).
#[derive(Clone, Debug)]
pub(crate) struct Endpoints {
    pub issuer: String,
    pub authorize: String,
    pub token: String,
    pub jwks: String,
    pub revoke: String,
}

impl Endpoints {
    pub(crate) fn official() -> Self {
        Self {
            issuer: ISSUER.into(),
            authorize: AUTHORIZE_ENDPOINT.into(),
            token: TOKEN_ENDPOINT.into(),
            jwks: JWKS_ENDPOINT.into(),
            revoke: REVOKE_ENDPOINT.into(),
        }
    }

    /// The published discovery document, falling back to the known endpoints.
    async fn discover() -> Self {
        let mut endpoints = Self::official();
        let Ok(response) = reqwest::Client::new()
            .get(format!("{ISSUER}/.well-known/openid-configuration"))
            .timeout(Duration::from_secs(10))
            .send()
            .await
        else {
            return endpoints;
        };
        let Ok(doc) = response.json::<Value>().await else {
            return endpoints;
        };
        // Only ever follow endpoints that stay on the issuer's origin.
        let same_origin = |v: &Value| {
            v.as_str()
                .filter(|u| u.starts_with(&format!("{ISSUER}/")))
                .map(str::to_owned)
        };
        if let Some(v) = same_origin(&doc["authorization_endpoint"]) {
            endpoints.authorize = v;
        }
        if let Some(v) = same_origin(&doc["token_endpoint"]) {
            endpoints.token = v;
        }
        if let Some(v) = same_origin(&doc["jwks_uri"]) {
            endpoints.jwks = v;
        }
        if let Some(v) = same_origin(&doc["revocation_endpoint"]) {
            endpoints.revoke = v;
        }
        endpoints
    }
}

/// What the sign-in reports while it runs.
#[derive(Clone, Debug, PartialEq)]
pub enum SignInProgress {
    /// Open this page in the browser on this computer.
    OpenBrowser(String),
}

#[derive(Clone, Debug, PartialEq)]
pub enum SignInOutcome {
    /// Signed in, and plan usage is on.
    Connected { email: Option<String> },
    /// Signed in, but the user did not allow ChatGPT plan usage.
    PlanUsageOff { email: Option<String> },
}

#[derive(Clone, Debug, PartialEq)]
pub enum SignInError {
    Cancelled,
    /// The user declined in the browser.
    Declined,
    TimedOut,
    Failed(String),
}

impl std::fmt::Display for SignInError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cancelled => f.write_str("ChatGPT sign-in was cancelled."),
            Self::Declined => f.write_str("ChatGPT sign-in was declined."),
            Self::TimedOut => f.write_str("ChatGPT sign-in timed out. Try again."),
            Self::Failed(detail) => write!(f, "ChatGPT sign-in failed: {detail}"),
        }
    }
}

impl std::error::Error for SignInError {}

fn failed(detail: impl std::fmt::Display) -> SignInError {
    SignInError::Failed(detail.to_string())
}

/// Sign in through the system browser on this host. `on_progress` is told when
/// to open the page; `cancel` abandons the attempt.
pub async fn sign_in(
    cancel: &CancellationToken,
    on_progress: impl Fn(SignInProgress),
) -> Result<SignInOutcome, SignInError> {
    sign_in_with(&Endpoints::discover().await, cancel, on_progress).await
}

pub(crate) async fn sign_in_with(
    endpoints: &Endpoints,
    cancel: &CancellationToken,
    on_progress: impl Fn(SignInProgress),
) -> Result<SignInOutcome, SignInError> {
    let host_id = plan::host_id().map_err(failed)?;
    let registration = plan::read_registration();
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.map_err(failed)?;
    let port = listener.local_addr().map_err(failed)?.port();
    let redirect_uri = format!("http://127.0.0.1:{port}/auth/callback");
    let (verifier, challenge) = pkce();
    let (state, nonce) = (random_token(), random_token());

    let mut query: Vec<(&str, &str)> = vec![
        ("response_type", "code"),
        (
            "client_id",
            registration
                .as_ref()
                .map_or("dynamic_agent_client", |r| r.client_id.as_str()),
        ),
        ("ext_agent_host_id", &host_id),
        ("redirect_uri", &redirect_uri),
        ("scope", SCOPES),
        ("resource", RESOURCE),
        ("state", &state),
        ("nonce", &nonce),
        ("code_challenge_method", "S256"),
        ("code_challenge", &challenge),
    ];
    match registration.as_ref().and_then(|r| r.email.as_deref()) {
        // A returning account never sends the app name.
        Some(email) => query.push(("login_hint", email)),
        None if registration.is_none() => query.push(("agent_name_hint", AGENT_NAME)),
        None => {}
    }
    let url = reqwest::Url::parse_with_params(&endpoints.authorize, &query).map_err(failed)?;
    on_progress(SignInProgress::OpenBrowser(url.to_string()));

    let (params, mut stream) = tokio::select! {
        () = cancel.cancelled() => return Err(SignInError::Cancelled),
        waited = tokio::time::timeout(CALLBACK_TIMEOUT, wait_for_callback(&listener, &state)) => {
            waited.map_err(|_| SignInError::TimedOut)??
        }
    };

    let result = finish(
        endpoints,
        &params,
        registration.as_ref(),
        &host_id,
        &redirect_uri,
        &verifier,
        &nonce,
    )
    .await;
    respond(&mut stream, result.is_ok()).await;
    result
}

/// Everything after the browser comes back: exchange, validate, store.
async fn finish(
    endpoints: &Endpoints,
    params: &HashMap<String, String>,
    registration: Option<&Registration>,
    host_id: &str,
    redirect_uri: &str,
    verifier: &str,
    nonce: &str,
) -> Result<SignInOutcome, SignInError> {
    if let Some(error) = params.get("error") {
        return Err(if error == "access_denied" {
            SignInError::Declined
        } else {
            failed(error)
        });
    }
    let code = params
        .get("code")
        .ok_or_else(|| failed("no code returned"))?;
    // A new registration hands back its issued client; a returning one must
    // keep the client it already has.
    let client_id = match (registration, params.get("client_id")) {
        (Some(r), Some(returned)) if *returned != r.client_id => {
            return Err(failed("the sign-in returned a different client"));
        }
        (Some(r), _) => r.client_id.clone(),
        (None, Some(returned)) => returned.clone(),
        (None, None) => return Err(failed("registration was not completed")),
    };

    let response = reqwest::Client::new()
        .post(&endpoints.token)
        .form(&[
            ("grant_type", "authorization_code"),
            ("client_id", client_id.as_str()),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirect_uri),
            ("resource", RESOURCE),
        ])
        .timeout(Duration::from_secs(30))
        .send()
        .await
        .map_err(failed)?;
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    if !status.is_success() {
        return Err(match body["error"].as_str() {
            Some("invalid_grant") => failed("the approval expired; try again"),
            Some(code) => failed(code),
            None => failed(format!("token exchange returned HTTP {status}")),
        });
    }
    let (Some(access), Some(id_token)) = (body["access_token"].as_str(), body["id_token"].as_str())
    else {
        return Err(failed("the token response was incomplete"));
    };

    let jwks: Value = reqwest::Client::new()
        .get(&endpoints.jwks)
        .timeout(Duration::from_secs(15))
        .send()
        .await
        .map_err(failed)?
        .json()
        .await
        .map_err(failed)?;
    let claims = verify_id_token(id_token, &jwks, &endpoints.issuer, &client_id, nonce, now())
        .map_err(failed)?;
    let subject = claims["sub"].as_str().unwrap_or_default().to_owned();
    if let Some(r) = registration
        && r.subject != subject
    {
        return Err(failed("that is a different ChatGPT account"));
    }
    let email = claims["email"]
        .as_str()
        .map(str::to_owned)
        .or_else(|| registration.and_then(|r| r.email.clone()));

    let scopes: Vec<&str> = body["scope"]
        .as_str()
        .or_else(|| params.get("scope").map(String::as_str))
        .unwrap_or_default()
        .split_whitespace()
        .collect();
    let t = now();
    let mut record = serde_json::json!({
        "email": email,
        "issuer": endpoints.issuer,
        "subject": subject,
        "client_id": client_id,
        "ext_agent_host_id": host_id,
        "id_token": id_token,
        "access_token": access,
        "token_type": body["token_type"].as_str().unwrap_or("Bearer"),
        "expires_at": t + body["expires_in"].as_u64().unwrap_or(3600),
        "scopes": scopes,
        "saved_at": iso8601(t),
    });
    if let Some(refresh) = body["refresh_token"].as_str() {
        record["refresh_token"] = refresh.into();
    }
    if let Some(e) = body["earliest_refresh_at"].as_u64() {
        record["earliest_refresh_at"] = (if e > 1_000_000_000 { e } else { t + e }).into();
    }
    let plan_usage = plan::grants_plan(&record);

    plan::save_registration(&Registration {
        client_id: client_id.clone(),
        subject,
        email: email.clone(),
    })
    .await
    .map_err(failed)?;
    // Signed in but without plan usage is kept, marked off, never used.
    plan::save_credentials(&record).await.map_err(failed)?;
    Ok(if plan_usage {
        SignInOutcome::Connected { email }
    } else {
        SignInOutcome::PlanUsageOff { email }
    })
}

/// Sign out: revoke the renewable session, then clear the tokens either way.
/// Returns whether OpenAI confirmed the revocation; the registration and host
/// id stay so signing in again reuses them.
pub async fn sign_out() -> Result<bool, SignInError> {
    sign_out_with(&Endpoints::discover().await).await
}

pub(crate) async fn sign_out_with(endpoints: &Endpoints) -> Result<bool, SignInError> {
    let Some(record) = plan::read_credentials() else {
        return Ok(true);
    };
    let mut revoked = record["refresh_token"].as_str().is_none();
    if let (Some(refresh), Some(client_id)) = (
        record["refresh_token"].as_str(),
        record["client_id"].as_str(),
    ) {
        for attempt in 0..3u64 {
            let sent = reqwest::Client::new()
                .post(&endpoints.revoke)
                .form(&[
                    ("token", refresh),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", client_id),
                ])
                .timeout(Duration::from_secs(10))
                .send()
                .await;
            match sent {
                Ok(r) if r.status().is_success() => {
                    revoked = true;
                    break;
                }
                // A definite refusal will not change; a network or 5xx failure might.
                Ok(r) if !r.status().is_server_error() => break,
                _ => tokio::time::sleep(Duration::from_millis(500 * (attempt + 1))).await,
            }
        }
    }
    plan::clear_credentials().await.map_err(failed)?;
    Ok(revoked)
}

// ---------------------------------------------------------------------------
// Callback listener
// ---------------------------------------------------------------------------

/// Accept requests until one is the real callback (`/auth/callback` carrying
/// this attempt's `state`). Anything else is answered and ignored, so a stray
/// or forged request cannot end the attempt.
async fn wait_for_callback(
    listener: &TcpListener,
    state: &str,
) -> Result<(HashMap<String, String>, TcpStream), SignInError> {
    loop {
        let (mut stream, _) = listener.accept().await.map_err(failed)?;
        let Some(target) = read_request_target(&mut stream).await else {
            continue;
        };
        let Ok(url) = reqwest::Url::parse(&format!("http://127.0.0.1{target}")) else {
            continue;
        };
        if url.path() != "/auth/callback" {
            let _ = stream
                .write_all(
                    b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                )
                .await;
            continue;
        }
        let params: HashMap<String, String> = url.query_pairs().into_owned().collect();
        if params.get("state").map(String::as_str) != Some(state) {
            respond(&mut stream, false).await;
            continue;
        }
        return Ok((params, stream));
    }
}

/// The request target of a `GET`, or `None` for anything malformed.
async fn read_request_target(stream: &mut TcpStream) -> Option<String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 1024];
    let read = async {
        while !buffer.windows(4).any(|w| w == b"\r\n\r\n") && buffer.len() < 8192 {
            let n = stream.read(&mut chunk).await.ok()?;
            if n == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..n]);
        }
        Some(())
    };
    tokio::time::timeout(Duration::from_secs(5), read)
        .await
        .ok()??;
    let head = String::from_utf8_lossy(&buffer);
    let mut parts = head.lines().next()?.split_whitespace();
    (parts.next()? == "GET").then(|| parts.next().map(str::to_owned))?
}

async fn respond(stream: &mut TcpStream, ok: bool) {
    let (status, title, line) = if ok {
        (
            "200 OK",
            "You're signed in",
            "You can close this tab and return to Harness.",
        )
    } else {
        (
            "400 Bad Request",
            "Sign-in didn't finish",
            "Return to Harness and try again.",
        )
    };
    let body = format!(
        "<!doctype html><meta charset=utf-8><title>Harness</title>\
         <body style=\"font:16px system-ui;margin:20vh auto;max-width:28rem;text-align:center\">\
         <h1 style=\"font-size:1.25rem\">{title}</h1><p>{line}</p>"
    );
    let response = format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/html; charset=utf-8\r\ncache-control: no-store\r\n\
         content-security-policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'\r\n\
         referrer-policy: no-referrer\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

// ---------------------------------------------------------------------------
// PKCE and ID-token validation
// ---------------------------------------------------------------------------

fn random_token() -> String {
    let bytes: Vec<u8> = uuid::Uuid::new_v4()
        .as_bytes()
        .iter()
        .chain(uuid::Uuid::new_v4().as_bytes())
        .copied()
        .collect();
    B64.encode(bytes)
}

/// A fresh PKCE `(verifier, S256 challenge)` pair.
fn pkce() -> (String, String) {
    let verifier = format!("{}{}", random_token(), random_token());
    let challenge = B64.encode(Sha256::digest(verifier.as_bytes()));
    (verifier, challenge)
}

/// Verify an ID token the way the docs require: RS256 signature against the
/// issuer's published keys, then issuer, audience (this client), expiry and the
/// attempt's nonce. Returns the claims.
pub(crate) fn verify_id_token(
    token: &str,
    jwks: &Value,
    issuer: &str,
    client_id: &str,
    nonce: &str,
    now: u64,
) -> Result<Value, String> {
    let mut parts = token.split('.');
    let (Some(header_part), Some(payload), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err("the ID token is malformed".into());
    };
    let decode = |part: &str| {
        B64.decode(part)
            .map_err(|_| "the ID token is malformed".to_owned())
    };
    let header: Value = serde_json::from_slice(&decode(header_part)?).map_err(|e| e.to_string())?;
    if header["alg"] != "RS256" {
        return Err("the ID token uses an unsupported signature".into());
    }
    let key = jwks["keys"]
        .as_array()
        .and_then(|keys| {
            keys.iter()
                .find(|k| k["kid"] == header["kid"] && k["kty"] == "RSA")
        })
        .ok_or("the ID token was signed by an unknown key")?;
    let (Some(n), Some(e)) = (key["n"].as_str(), key["e"].as_str()) else {
        return Err("the signing key is incomplete".into());
    };
    let der = rsa_public_key_der(&decode(n)?, &decode(e)?)?;
    ring::signature::UnparsedPublicKey::new(&ring::signature::RSA_PKCS1_2048_8192_SHA256, der)
        .verify(
            format!("{header_part}.{payload}").as_bytes(),
            &decode(signature)?,
        )
        .map_err(|_| "the ID token signature is not valid".to_owned())?;

    let claims: Value = serde_json::from_slice(&decode(payload)?).map_err(|e| e.to_string())?;
    if claims["iss"] != issuer {
        return Err("the ID token has the wrong issuer".into());
    }
    let audience = &claims["aud"];
    if !(audience == client_id
        || audience
            .as_array()
            .is_some_and(|all| all.iter().any(|a| a == client_id)))
    {
        return Err("the ID token is for a different client".into());
    }
    // A few seconds of clock tolerance, as usual.
    if claims["exp"].as_u64().is_none_or(|exp| exp + 5 < now) {
        return Err("the ID token has expired".into());
    }
    if claims["nonce"] != nonce {
        return Err("the ID token does not match this sign-in".into());
    }
    if claims["sub"].as_str().is_none_or(str::is_empty) {
        return Err("the ID token has no subject".into());
    }
    Ok(claims)
}

/// DER `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
fn rsa_public_key_der(modulus: &[u8], exponent: &[u8]) -> Result<Vec<u8>, String> {
    fn length(n: usize, out: &mut Vec<u8>) {
        if n < 128 {
            out.push(n as u8);
        } else {
            let bytes = n.to_be_bytes();
            let bytes = &bytes[bytes.iter().position(|b| *b != 0).unwrap_or(0)..];
            out.push(0x80 | bytes.len() as u8);
            out.extend_from_slice(bytes);
        }
    }
    fn integer(bytes: &[u8], out: &mut Vec<u8>) -> Result<(), String> {
        let start = bytes
            .iter()
            .position(|b| *b != 0)
            .ok_or("the signing key is empty")?;
        let bytes = &bytes[start..];
        let pad = usize::from(bytes[0] & 0x80 != 0);
        out.push(0x02);
        length(bytes.len() + pad, out);
        out.extend(std::iter::repeat_n(0, pad));
        out.extend_from_slice(bytes);
        Ok(())
    }
    let mut body = Vec::new();
    integer(modulus, &mut body)?;
    integer(exponent, &mut body)?;
    let mut der = vec![0x30];
    length(body.len(), &mut der);
    der.extend(body);
    Ok(der)
}

#[cfg(test)]
pub(crate) mod tests;
