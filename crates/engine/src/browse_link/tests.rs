//! End to end against a fake browse that checks every signature the way
//! browse does (browse `Sources/Browse/Connect.swift`): pairing, the relay,
//! per-run sessions, refusals, closing a run's pages, forged answers and
//! revocation.

use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use p256::ecdsa::signature::Verifier as _;
use p256::ecdsa::{DerSignature, SigningKey};
use tokio::io::AsyncWriteExt as _;
use tokio::net::TcpListener;

use super::keystore::KeyStore;
use super::proxy::{read_request, response};
use super::{BrowseLink, wire};

#[derive(Default)]
struct Seen {
    client_key: Option<String>,
    nonce: Option<String>,
    mcp: Vec<serde_json::Value>,
    closed: Vec<String>,
}

struct FakeBrowse {
    port: u16,
    key: SigningKey,
    seen: Arc<Mutex<Seen>>,
    /// Sign answers with this instead (a squatter on the port).
    forge: Arc<Mutex<Option<SigningKey>>>,
    /// Answer everything with a signed 401 unknown_client (revoked).
    revoked: Arc<Mutex<bool>>,
}

impl FakeBrowse {
    async fn start() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let key = wire::new_key();
        let seen = Arc::new(Mutex::new(Seen::default()));
        let forge = Arc::new(Mutex::new(None::<SigningKey>));
        let revoked = Arc::new(Mutex::new(false));
        let (k, s, f, r) = (key.clone(), seen.clone(), forge.clone(), revoked.clone());
        tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let (key, seen, forge, revoked) = (k.clone(), s.clone(), f.clone(), r.clone());
                tokio::spawn(async move {
                    let Ok(Some((head, body))) = read_request(&mut stream).await else {
                        return;
                    };
                    let (status, answer, nonce) =
                        answer(&head, &body, &seen, *revoked.lock().unwrap());
                    let mut bytes = response(status, &answer);
                    if let Some(nonce) = nonce {
                        let signer = forge.lock().unwrap().clone().unwrap_or(key);
                        let digest = wire::hex(&<sha2::Sha256 as sha2::Digest>::digest(&answer));
                        let signature = wire::sign(&signer, &format!("{digest}|{nonce}"));
                        // Put X-Signature in the head.
                        let at = bytes.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
                        let header = format!("\r\nX-Signature: {signature}");
                        bytes.splice(at..at, header.into_bytes());
                    }
                    let _ = stream.write_all(&bytes).await;
                    let _ = stream.shutdown().await;
                });
            }
        });
        Self {
            port,
            key,
            seen,
            forge,
            revoked,
        }
    }

    fn browse_key(&self) -> String {
        wire::public_key_b64(&self.key)
    }

    fn publish(&self, dir: &std::path::Path) -> std::path::PathBuf {
        let path = dir.join("connect.json");
        std::fs::write(
            &path,
            serde_json::json!({
                "protocol": [wire::PROTOCOL],
                "port": self.port,
                "browse_key": self.browse_key(),
                "pid": std::process::id(),
            })
            .to_string(),
        )
        .unwrap();
        path
    }
}

/// browse's side of one signed request: `(status, body, nonce to sign the
/// answer over)`. `/pair` is answered by the test's front, with browse's key.
fn answer(
    head: &super::proxy::Head,
    body: &[u8],
    seen: &Mutex<Seen>,
    revoked: bool,
) -> (u16, Vec<u8>, Option<String>) {
    let json = |v: serde_json::Value| serde_json::to_vec(&v).unwrap();
    // Everything else is signed: check it like browse does.
    let nonce = head.header("x-nonce").unwrap_or_default().to_owned();
    let client_key = seen.lock().unwrap().client_key.clone().unwrap();
    let text = wire::canonical(
        "POST",
        &head.path,
        body,
        head.header("x-timestamp").unwrap().parse().unwrap(),
        &nonce,
        head.header("x-client-id").unwrap(),
    );
    let signature = DerSignature::try_from(
        B64.decode(head.header("x-signature").unwrap())
            .unwrap()
            .as_slice(),
    )
    .unwrap();
    let valid = wire::parse_public_key(&client_key)
        .unwrap()
        .verify(text.as_bytes(), &signature)
        .is_ok();
    assert!(valid, "every request Harness sends is signed by its key");
    assert_eq!(head.header("x-client-id"), Some("client-1"));
    assert!(head.header("origin").is_none());
    if revoked {
        return (
            401,
            json(serde_json::json!({ "error": "unknown_client" })),
            Some(nonce),
        );
    }
    let request: serde_json::Value = serde_json::from_slice(body).unwrap();
    match head.path.as_str() {
        "/pair/status" => (
            200,
            json(serde_json::json!({ "status": "paired", "scopes": ["read", "act-own-pages"] })),
            Some(nonce),
        ),
        "/session/close" => {
            seen.lock()
                .unwrap()
                .closed
                .push(request["session"].as_str().unwrap().to_owned());
            (200, json(serde_json::json!({ "closed": 1 })), Some(nonce))
        }
        "/mcp" => {
            seen.lock().unwrap().mcp.push(request.clone());
            if request["params"]["name"] == "theme" {
                return (
                    403,
                    json(
                        serde_json::json!({ "error": "out_of_scope", "tool": "theme", "scope": "none" }),
                    ),
                    Some(nonce),
                );
            }
            (
                200,
                json(serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": request["id"],
                    "result": { "content": [{ "type": "text", "text": "ok" }] },
                })),
                Some(nonce),
            )
        }
        other => panic!("unexpected {other}"),
    }
}

async fn post(
    url: &str,
    token: Option<&str>,
    extra: Option<(&str, &str)>,
    body: serde_json::Value,
) -> (u16, serde_json::Value) {
    let mut request = reqwest::Client::new().post(url).json(&body);
    if let Some(token) = token {
        request = request.header("Authorization", format!("Bearer {token}"));
    }
    if let Some((name, value)) = extra {
        request = request.header(name, value);
    }
    let response = request.send().await.unwrap();
    let status = response.status().as_u16();
    (status, response.json().await.unwrap_or_default())
}

async fn eventually(mut check: impl FnMut() -> bool) {
    for _ in 0..100 {
        if check() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("timed out");
}

#[tokio::test]
async fn the_full_flow_against_a_fake_browse() {
    let dir = tempfile::tempdir().unwrap();
    let browse = FakeBrowse::start().await;
    let connect = browse.publish(dir.path());
    // Relay /pair through a front that answers it with browse's key, as the
    // real browse does, and passes everything else to the fake.
    let front = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let front_port = front.local_addr().unwrap().port();
    let browse_key = browse.browse_key();
    let fake_port = browse.port;
    let seen = browse.seen.clone();
    tokio::spawn(async move {
        loop {
            let (mut stream, _) = front.accept().await.unwrap();
            let browse_key = browse_key.clone();
            let seen = seen.clone();
            tokio::spawn(async move {
                let Ok(Some((head, body))) = read_request(&mut stream).await else {
                    return;
                };
                let bytes = if head.path == "/pair" {
                    let request: serde_json::Value = serde_json::from_slice(&body).unwrap();
                    {
                        let mut seen = seen.lock().unwrap();
                        seen.client_key = request["client_key"].as_str().map(str::to_owned);
                        seen.nonce = request["nonce"].as_str().map(str::to_owned);
                    }
                    response(
                        200,
                        &serde_json::to_vec(&serde_json::json!({
                            "protocol": wire::PROTOCOL,
                            "client_id": "client-1",
                            "browse_key": browse_key,
                            "expires_in": 120,
                        }))
                        .unwrap(),
                    )
                } else {
                    // Forward verbatim to the fake and return its answer.
                    let mut upstream = tokio::net::TcpStream::connect(("127.0.0.1", fake_port))
                        .await
                        .unwrap();
                    let mut request =
                        format!("{} {} HTTP/1.1\r\n", head.method, head.path).into_bytes();
                    for (name, value) in &head.headers {
                        request.extend_from_slice(format!("{name}: {value}\r\n").as_bytes());
                    }
                    request.extend_from_slice(b"\r\n");
                    request.extend_from_slice(&body);
                    upstream.write_all(&request).await.unwrap();
                    let mut answer = Vec::new();
                    tokio::io::AsyncReadExt::read_to_end(&mut upstream, &mut answer)
                        .await
                        .unwrap();
                    answer
                };
                let _ = stream.write_all(&bytes).await;
                let _ = stream.shutdown().await;
            });
        }
    });
    // connect.json names the front's port.
    let mut published: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&connect).unwrap()).unwrap();
    published["port"] = front_port.into();
    std::fs::write(&connect, published.to_string()).unwrap();

    let state = dir.path().join("browse-link.json");
    let link = Arc::new(BrowseLink::new(
        state.clone(),
        KeyStore::File(dir.path().join("key")),
        Some(connect.clone()),
    ));

    // Pairing: both sides derive the same six digits.
    let code = link.start_pair().await.unwrap();
    let (client_key, nonce) = {
        let seen = browse.seen.lock().unwrap();
        (
            seen.client_key.clone().unwrap(),
            seen.nonce.clone().unwrap(),
        )
    };
    assert_eq!(
        Some(code.clone()),
        wire::pairing_code(&browse.browse_key(), &client_key, &nonce)
    );
    assert_eq!(link.status().pairing_code, Some(code));
    eventually(|| link.status().paired).await;
    assert_eq!(link.status().scopes, ["read", "act-own-pages"]);
    assert!(link.status().pairing_code.is_none());
    // The pairing survives a restart; nothing secret is in its file.
    let reloaded = BrowseLink::new(
        state.clone(),
        KeyStore::File(dir.path().join("key")),
        Some(connect.clone()),
    );
    assert!(reloaded.status().paired);
    assert!(
        !std::fs::read_to_string(&state)
            .unwrap()
            .contains("key\":\"-----")
    );

    // A run's browse server, and requests through the relay.
    let server = link.mcp_server_for_run("run-1").await.unwrap();
    assert_eq!(server.name, "browse");
    let token = server.headers[0]
        .1
        .strip_prefix("Bearer ")
        .unwrap()
        .to_owned();
    let list = serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" });
    let (status, body) = post(&server.url, Some(&token), None, list.clone()).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["result"]["content"][0]["text"], "ok");
    let open = serde_json::json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": { "name": "open", "arguments": { "url": "https://example.com" } },
    });
    let (status, _) = post(&server.url, Some(&token), None, open).await;
    assert_eq!(status, 200);
    {
        let seen = browse.seen.lock().unwrap();
        assert!(
            seen.mcp[0]["params"].get("_meta").is_none(),
            "only tools/call is tagged"
        );
        assert_eq!(
            seen.mcp[1]["params"]["_meta"]["browse/session"],
            "run:run-1"
        );
    }
    // A refusal reaches the model as a tool error it can read.
    let theme = serde_json::json!({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": { "name": "theme" },
    });
    let (status, body) = post(&server.url, Some(&token), None, theme).await;
    assert_eq!(status, 200);
    assert_eq!(body["result"]["isError"], true);
    assert!(
        body["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("theme needs the none scope")
    );
    // Two requests over one kept-alive connection (graff's client reuses it).
    {
        use tokio::io::AsyncReadExt as _;
        let port: u16 = server
            .url
            .trim_start_matches("http://127.0.0.1:")
            .trim_end_matches("/mcp")
            .parse()
            .unwrap();
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .unwrap();
        let body = list.to_string();
        for _ in 0..2 {
            let request = format!(
                "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nAuthorization: Bearer {token}\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
                body.len()
            );
            stream.write_all(request.as_bytes()).await.unwrap();
            let mut head = Vec::new();
            while !head.ends_with(b"\r\n\r\n") {
                let mut byte = [0u8; 1];
                stream.read_exact(&mut byte).await.unwrap();
                head.push(byte[0]);
            }
            let head = String::from_utf8(head).unwrap();
            assert!(head.starts_with("HTTP/1.1 200"), "{head}");
            assert!(head.contains("Connection: keep-alive"), "{head}");
            let length: usize = head
                .lines()
                .find_map(|l| l.strip_prefix("Content-Length: "))
                .unwrap()
                .trim()
                .parse()
                .unwrap();
            let mut answer = vec![0u8; length];
            stream.read_exact(&mut answer).await.unwrap();
        }
    }
    // No token, another run's token, or a web page: refused by the relay.
    assert_eq!(post(&server.url, None, None, list.clone()).await.0, 401);
    assert_eq!(
        post(&server.url, Some("nope"), None, list.clone()).await.0,
        401
    );
    assert_eq!(
        post(
            &server.url,
            Some(&token),
            Some(("Origin", "https://evil.example")),
            list.clone()
        )
        .await
        .0,
        403
    );

    // A squatter's answer is refused, and the model is told why.
    *browse.forge.lock().unwrap() = Some(wire::new_key());
    let (_, body) = post(&server.url, Some(&token), None, list.clone()).await;
    assert!(
        body["error"]["message"]
            .as_str()
            .unwrap()
            .contains("wasn't signed"),
        "{body}"
    );
    *browse.forge.lock().unwrap() = None;

    // The run ends: its pages close and its token stops working.
    link.end_run("run-1");
    eventually(|| browse.seen.lock().unwrap().closed == ["run:run-1"]).await;
    assert_eq!(
        post(&server.url, Some(&token), None, list.clone()).await.0,
        401
    );

    // Revoked in browse: a signed unknown_client forgets the pairing.
    let other = link.mcp_server_for_run("run-2").await.unwrap();
    let other_token = other.headers[0]
        .1
        .strip_prefix("Bearer ")
        .unwrap()
        .to_owned();
    *browse.revoked.lock().unwrap() = true;
    let (_, body) = post(&other.url, Some(&other_token), None, list).await;
    assert!(
        body["error"]["message"]
            .as_str()
            .unwrap()
            .contains("no longer knows Harness"),
        "{body}"
    );
    assert!(!link.status().paired);
    assert!(link.status().error.is_some());
    assert!(
        link.mcp_server_for_run("run-3").await.is_none(),
        "unpaired runs get no browse server"
    );
}

#[tokio::test]
async fn without_browse_runs_get_no_server_and_pairing_says_why() {
    let dir = tempfile::tempdir().unwrap();
    let link = Arc::new(BrowseLink::new(
        dir.path().join("browse-link.json"),
        KeyStore::File(dir.path().join("key")),
        Some(dir.path().join("missing-connect.json")),
    ));
    assert!(!link.status().browse_running);
    assert!(link.mcp_server_for_run("run").await.is_none());
    let error = link.start_pair().await.unwrap_err();
    assert!(error.contains("Connected apps"), "{error}");
}

/// Against a real browse test world (not run by default):
/// `HARNESS_BROWSE_LIVE_WORLD=harness cargo test -p harness-engine --lib live_browse -- --ignored --nocapture`
/// with browse running as that world and Connected apps on. Approves the
/// pairing with browse's bench driver.
#[tokio::test]
#[ignore]
async fn live_browse_pairs_opens_reads_and_closes() {
    let world = std::env::var("HARNESS_BROWSE_LIVE_WORLD").expect("HARNESS_BROWSE_LIVE_WORLD");
    let home = std::env::var("HOME").unwrap();
    let connect = std::path::PathBuf::from(format!(
        "{home}/Library/Application Support/browse ({world})/Agent/connect.json"
    ));
    let dir = tempfile::tempdir().unwrap();
    let link = Arc::new(BrowseLink::new(
        dir.path().join("browse-link.json"),
        KeyStore::File(dir.path().join("key")),
        Some(connect),
    ));
    assert!(
        link.status().browse_running,
        "start browse as world {world}"
    );
    let code = link.start_pair().await.unwrap();
    println!("pairing code {code}");
    let approved = tokio::process::Command::new("./bench")
        .args(["--world", &world, "ui", "connect", "yes"])
        .current_dir(format!("{home}/browse"))
        .status()
        .await
        .unwrap();
    assert!(approved.success(), "bench approval");
    for _ in 0..200 {
        if link.status().paired || link.status().error.is_some() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let status = link.status();
    println!("status {status:?}");
    assert!(status.paired, "{status:?}");

    let server = link.mcp_server_for_run("live-run").await.unwrap();
    let token = server.headers[0]
        .1
        .strip_prefix("Bearer ")
        .unwrap()
        .to_owned();
    let (s, list) = post(
        &server.url,
        Some(&token),
        None,
        serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }),
    )
    .await;
    let names: Vec<_> = list["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_owned())
        .collect();
    println!("tools/list {s}: {names:?}");
    assert!(names.contains(&"open".to_owned()));
    let (s, opened) = post(
        &server.url,
        Some(&token),
        None,
        serde_json::json!({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": { "name": "open", "arguments": { "url": "https://example.com" } },
        }),
    )
    .await;
    println!(
        "open {s}: {}",
        opened.to_string().chars().take(300).collect::<String>()
    );
    let (s, read) = post(
        &server.url,
        Some(&token),
        None,
        serde_json::json!({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": { "name": "read", "arguments": {} },
        }),
    )
    .await;
    let text = read.to_string();
    println!("read {s}: {}", text.chars().take(400).collect::<String>());
    assert!(text.contains("Example Domain"), "{text}");
    let (_, js) = post(
        &server.url,
        Some(&token),
        None,
        serde_json::json!({
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": { "name": "run_js", "arguments": { "code": "1+1" } },
        }),
    )
    .await;
    println!(
        "run_js (not granted by default): {}",
        js.to_string().chars().take(300).collect::<String>()
    );
    link.end_run("live-run");
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    assert_eq!(post(&server.url, Some(&token), None, list).await.0, 401);
    link.disconnect();
}

/// Pairs with a live browse world and holds a run's relay open for an agent
/// driven from outside (not run by default): writes the MCP server as JSON to
/// `HARNESS_BROWSE_LIVE_OUT`, then waits `HARNESS_BROWSE_LIVE_HOLD` seconds.
#[tokio::test]
#[ignore]
async fn live_browse_relay_for_an_agent() {
    let world = std::env::var("HARNESS_BROWSE_LIVE_WORLD").expect("HARNESS_BROWSE_LIVE_WORLD");
    let out = std::env::var("HARNESS_BROWSE_LIVE_OUT").expect("HARNESS_BROWSE_LIVE_OUT");
    let hold: u64 = std::env::var("HARNESS_BROWSE_LIVE_HOLD")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(240);
    let home = std::env::var("HOME").unwrap();
    let dir = tempfile::tempdir().unwrap();
    let link = Arc::new(BrowseLink::new(
        dir.path().join("browse-link.json"),
        KeyStore::File(dir.path().join("key")),
        Some(
            format!("{home}/Library/Application Support/browse ({world})/Agent/connect.json")
                .into(),
        ),
    ));
    link.start_pair().await.unwrap();
    tokio::process::Command::new("./bench")
        .args(["--world", &world, "ui", "connect", "yes"])
        .current_dir(format!("{home}/browse"))
        .status()
        .await
        .unwrap();
    eventually(|| link.status().paired).await;
    let server = link.mcp_server_for_run("agent-run").await.unwrap();
    std::fs::write(
        &out,
        serde_json::json!({
            "type": "http",
            "name": server.name,
            "url": server.url,
            "headers": server.headers.iter().map(|(n, v)| serde_json::json!({ "name": n, "value": v })).collect::<Vec<_>>(),
        })
        .to_string(),
    )
    .unwrap();
    println!("relay ready at {}", server.url);
    tokio::time::sleep(std::time::Duration::from_secs(hold)).await;
    link.end_run("agent-run");
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    link.disconnect();
}
