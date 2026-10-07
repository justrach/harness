//! One sign-in covers the app and `graff` in the terminal: a Harness sign-in
//! on a device whose graff has no key asks the edge for one and writes it to
//! graff's own credential file; a device that has one never asks, and its key
//! is never replaced.
//!
//! One test function: graff's key file is found from HOME, which this sets.
#![cfg(unix)]

use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use harness_engine::{Auth, AuthConfig};

const MINTED: &str = "cg_sk_000000000000000000000000000000000000000000000001";

/// An edge that answers `/auth/exchange` (with a graff key when asked) and
/// records each exchange body.
async fn stub_edge() -> (String, Arc<Mutex<Vec<serde_json::Value>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let record = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            let record = record.clone();
            tokio::spawn(async move {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 8192];
                let (head, body) = loop {
                    let n = stream.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    buf.extend_from_slice(&chunk[..n]);
                    let text = String::from_utf8_lossy(&buf).to_string();
                    if let Some((head, body)) = text.split_once("\r\n\r\n") {
                        let len = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length:")
                                    .map(|v| v.trim().parse::<usize>().unwrap_or(0))
                            })
                            .unwrap_or(0);
                        if body.len() >= len {
                            break (head.to_string(), body.to_string());
                        }
                    }
                };
                let reply = if head.starts_with("POST /auth/exchange") {
                    let parsed: serde_json::Value = serde_json::from_str(&body).unwrap();
                    let asked = parsed["graffKey"] == true;
                    record.lock().unwrap().push(parsed);
                    let mut out = serde_json::json!({
                        "user": { "id": "user_1", "email": "w@example.com" },
                        "accessToken": "e30.eyJzdWIiOiJ1c2VyXzEiLCJpYXQiOjEwMDAsImV4cCI6OTk5OTk5OTk5OSwib3JnX2lkIjoib3JnXzEifQ.sig",
                        "refreshToken": "refresh-1",
                    });
                    if asked {
                        out["graffKey"] =
                            serde_json::json!({ "apiKey": MINTED, "email": "w@example.com" });
                    }
                    out.to_string()
                } else {
                    r#"{"ok":true,"auth":"codegraff"}"#.to_string()
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                    reply.len()
                );
                let _ = stream.write_all(response.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
        }
    });
    (url, seen)
}

async fn sign_in(edge: &str, data_dir: &std::path::Path) {
    let mut config = AuthConfig::new(edge, data_dir);
    config.codegraff_client_id = Some("cg_client_test".into());
    config.codegraff_api_base = "https://codegraff.example".into();
    config.callback_port = None;
    let auth = Auth::new(config);
    let url = auth.start_headless_sign_in();
    let state = url
        .split_once("state=")
        .and_then(|(_, rest)| rest.split('&').next())
        .unwrap()
        .to_string();
    auth.complete_sign_in(&format!("{state}.code"))
        .await
        .expect("sign-in");
}

#[tokio::test]
async fn harness_sign_in_signs_graff_in_without_replacing_its_key() {
    let home = tempfile::tempdir().unwrap();
    // SAFETY: the only test in this binary, so nothing else reads env meanwhile.
    unsafe {
        std::env::set_var("HOME", home.path());
        std::env::remove_var("CODEGRAFF_API_KEY");
    }
    let key_file = home.path().join(".simple-harness-codegraff.json");
    let (edge, seen) = stub_edge().await;

    // No graff key yet: the sign-in asks for one and graff gets it.
    let first = tempfile::tempdir().unwrap();
    sign_in(&edge, first.path()).await;
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0]["graffKey"], true);
        assert!(
            seen[0]["deviceLabel"]
                .as_str()
                .is_some_and(|l| !l.is_empty()),
            "names the device: {:?}",
            seen[0]
        );
    }
    let saved: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&key_file).expect("graff key written")).unwrap();
    assert_eq!(saved["api_key"], MINTED);
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&key_file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "graff's credential stays private");
    }

    // graff already has a key (its own `graff login`): never asked, never replaced.
    std::fs::write(&key_file, br#"{"api_key":"cg_sk_mine"}"#).unwrap();
    let second = tempfile::tempdir().unwrap();
    sign_in(&edge, second.path()).await;
    assert_eq!(seen.lock().unwrap()[1]["graffKey"], false);
    assert_eq!(
        std::fs::read_to_string(&key_file).unwrap(),
        r#"{"api_key":"cg_sk_mine"}"#
    );
}
