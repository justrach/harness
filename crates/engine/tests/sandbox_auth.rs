//! A Codegraff cloud sandbox signs in with the lease token its host keeps in a file: the edge vouches
//! for it (`POST /auth/sandbox`), refreshes ask again with whatever the file holds now
//! (`POST /auth/refresh`), nothing is written to disk, and a refused token degrades to signed out
//! until the file holds one the edge accepts.

use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use harness_engine::auth::sandbox_sign_in;
use harness_engine::{Auth, AuthConfig, AuthState};
use harness_rpc::{TokenError, TokenSource};

const TOKEN_A: &str = "cg_lt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const TOKEN_B: &str = "cg_lt_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn base64url(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(ALPHABET[(n >> 18) as usize & 63] as char);
        out.push(ALPHABET[(n >> 12) as usize & 63] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[(n >> 6) as usize & 63] as char);
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[n as usize & 63] as char);
        }
    }
    out
}

/// An unsigned JWT with a short life, so every `access_token()` call asks the edge again.
fn short_jwt() -> String {
    let claims = serde_json::json!({ "sub": "42", "iat": 1_000, "exp": 1_010, "org_id": "user-42" });
    format!("e30.{}.sig", base64url(claims.to_string().as_bytes()))
}

#[derive(Default)]
struct Edge {
    /// (path, token in the body)
    seen: Mutex<Vec<(String, String)>>,
    /// Status answered to /auth/sandbox and /auth/refresh; 200 = accept.
    status: AtomicU16,
}

async fn start_edge() -> (String, Arc<Edge>) {
    let edge = Arc::new(Edge::default());
    edge.status.store(200, Ordering::SeqCst);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let url = format!("http://{}", listener.local_addr().expect("addr"));
    let state = edge.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let state = state.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let mut len = 0;
                let body = loop {
                    let n = stream.read(&mut buf[len..]).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    len += n;
                    let text = String::from_utf8_lossy(&buf[..len]).to_string();
                    if let Some((head, rest)) = text.split_once("\r\n\r\n") {
                        let want: usize = head
                            .lines()
                            .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse().unwrap_or(0)))
                            .unwrap_or(0);
                        if rest.len() >= want {
                            break (head.to_string(), rest[..want].to_string());
                        }
                    }
                };
                let path = body.0.split_whitespace().nth(1).unwrap_or("").to_string();
                let json: serde_json::Value = serde_json::from_str(&body.1).unwrap_or_default();
                let token = json
                    .get("token")
                    .or_else(|| json.get("refreshToken"))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                state.seen.lock().unwrap().push((path.clone(), token.clone()));
                let status = state.status.load(Ordering::SeqCst);
                let (line, payload) = if status != 200 {
                    (format!("{status} Refused"), r#"{"error":"refused"}"#.to_string())
                } else if path == "/auth/sandbox" {
                    (
                        "200 OK".into(),
                        serde_json::json!({
                            "user": { "id": "42", "email": "owner@example.test" },
                            "orgId": "user-42",
                            "accessToken": short_jwt(),
                        })
                        .to_string(),
                    )
                } else if path == "/auth/refresh" {
                    ("200 OK".into(), serde_json::json!({ "accessToken": short_jwt(), "refreshToken": token }).to_string())
                } else {
                    ("404 Not Found".into(), "{}".into())
                };
                let reply = format!(
                    "HTTP/1.1 {line}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{payload}",
                    payload.len()
                );
                let _ = stream.write_all(reply.as_bytes()).await;
            });
        }
    });
    (url, edge)
}

fn token_file(dir: &std::path::Path, token: &str) -> std::path::PathBuf {
    let path = dir.join("access.json");
    std::fs::write(&path, format!(r#"{{"apiKey":"{token}","modelBaseUrl":"https://gateway.example"}}"#)).unwrap();
    path
}

fn config(edge: &str, data: &std::path::Path, file: &std::path::Path) -> AuthConfig {
    let mut config = AuthConfig::new(edge, data);
    config.codegraff_client_id = Some("cg_client_test".into());
    config.callback_port = None;
    config.sandbox_token_file = Some(file.to_path_buf());
    config
}

#[tokio::test]
async fn a_sandbox_signs_in_from_its_token_file_and_writes_nothing_to_disk() {
    let (edge_url, edge) = start_edge().await;
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).unwrap();
    let file = token_file(dir.path(), TOKEN_A);

    let session = sandbox_sign_in(&edge_url, &file).await.expect("edge answers").expect("a token is present");
    let auth = Auth::new(config(&edge_url, &data, &file).with_sandbox_session(session));
    assert!(auth.loaded_codegraff_session(), "the engine opens the synced workspace on its first start");
    assert!(matches!(auth.state(), AuthState::SignedIn { user, org_id }
        if user.email == "owner@example.test" && org_id.as_deref() == Some("user-42")));
    assert_eq!(auth.user_id().as_deref(), Some("42"));
    assert!(auth.access_token().await.is_ok());
    assert!(!data.join("session.json").exists(), "the lease token is the identity; no session file");
    assert_eq!(edge.seen.lock().unwrap()[0], ("/auth/sandbox".to_string(), TOKEN_A.to_string()));
}

#[tokio::test]
async fn an_existing_session_file_is_ignored_and_a_missing_token_means_signed_out() {
    let (edge_url, _edge) = start_edge().await;
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(
        data.join("session.json"),
        r#"{"refreshToken":"harness_rt_x","user":{"id":"9","email":"other@example.test"},"orgId":"user-9"}"#,
    )
    .unwrap();
    let missing = dir.path().join("none.json");
    assert!(sandbox_sign_in(&edge_url, &missing).await.expect("no error").is_none());
    let auth = Auth::new(config(&edge_url, &data, &missing));
    assert_eq!(auth.state(), AuthState::SignedOut, "another account's session file is not used");
    assert!(!auth.loaded_codegraff_session());
}

#[tokio::test]
async fn a_malformed_token_is_never_sent() {
    let (edge_url, edge) = start_edge().await;
    let dir = tempfile::tempdir().unwrap();
    for bad in ["cg_sk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "cg_lt_short", "nonsense", ""] {
        let file = token_file(dir.path(), bad);
        assert!(sandbox_sign_in(&edge_url, &file).await.expect("no error").is_none(), "{bad}");
    }
    assert!(edge.seen.lock().unwrap().is_empty(), "nothing reached the edge");
}

#[tokio::test]
async fn a_refresh_sends_the_token_the_file_holds_now() {
    let (edge_url, edge) = start_edge().await;
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).unwrap();
    let file = token_file(dir.path(), TOKEN_A);
    let session = sandbox_sign_in(&edge_url, &file).await.unwrap().unwrap();
    let auth = Auth::new(config(&edge_url, &data, &file).with_sandbox_session(session));

    // The host re-attaches after a resume: the file now holds a new token.
    token_file(dir.path(), TOKEN_B);
    assert!(auth.access_token().await.is_ok());
    let seen = edge.seen.lock().unwrap().clone();
    assert_eq!(seen.last().unwrap(), &("/auth/refresh".to_string(), TOKEN_B.to_string()));
    assert!(!data.join("session.json").exists());
}

#[tokio::test]
async fn a_refused_token_signs_out_and_the_next_good_token_signs_back_in() {
    let (edge_url, edge) = start_edge().await;
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    std::fs::create_dir_all(&data).unwrap();
    let file = token_file(dir.path(), TOKEN_A);
    let session = sandbox_sign_in(&edge_url, &file).await.unwrap().unwrap();
    let auth = Auth::new(config(&edge_url, &data, &file).with_sandbox_session(session));

    edge.status.store(401, Ordering::SeqCst); // the sandbox was paused: its token is revoked
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(5), auth.access_token()).await.unwrap(),
        Err(TokenError::SignedOut)
    );
    assert_eq!(auth.state(), AuthState::SignedOut);
    assert!(auth.resign_sandbox().await.is_err(), "still refused while the edge says no");

    edge.status.store(200, Ordering::SeqCst); // resumed and re-attached
    token_file(dir.path(), TOKEN_B);
    auth.resign_sandbox().await.expect("signed back in");
    assert!(matches!(auth.state(), AuthState::SignedIn { .. }));
    assert!(auth.access_token().await.is_ok());
    assert!(!data.join("session.json").exists());
}
