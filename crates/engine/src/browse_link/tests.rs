//! End to end against a fake browse that answers and checks every request
//! the way browse does (browse `Sources/Browse/Connect.swift` and
//! `AgentTools.swift`): pairing, the relay, per-run sessions, refusals,
//! closing a run's pages, forged answers, scope changes and revocation.
//!
//! The fake never panics on what it receives. Anything else on the machine
//! may connect to a loopback port (a dev-server scanner sending `HEAD /`, for
//! one); browse answers that and carries on, and so does the fake. What
//! Harness itself gets wrong is collected in `faults` and asserted by the
//! test.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use p256::ecdsa::signature::Verifier as _;
use p256::ecdsa::{DerSignature, SigningKey};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::TcpListener;

use super::keystore::KeyStore;
use super::proxy::{Head, read_request, response};
use super::{BrowseLink, wire};

const CLIENT_ID: &str = "client-1";

#[derive(Default)]
struct Seen {
    client_key: Option<String>,
    nonce: Option<String>,
    /// Every request nonce, for browse's replay check.
    nonces: HashSet<String>,
    mcp: Vec<serde_json::Value>,
    closed: Vec<String>,
    /// What browse would refuse from Harness: unsigned, badly signed,
    /// stale, replayed, or from a web page. Must stay empty.
    faults: Vec<String>,
    /// Requests that weren't Harness's, answered as browse answers them.
    strangers: usize,
}

struct Behaviour {
    /// Sign answers with this instead (a squatter on the port).
    forge: Option<SigningKey>,
    /// Answer everything with a signed 401 unknown_client (revoked).
    revoked: bool,
    /// What the user allows Harness, as `/pair/status` reports it.
    scopes: Vec<&'static str>,
    /// The user's answer to a pairing so far: `/pair/status` before it's
    /// recorded (`pending`, `paired`, `declined`).
    pairing: &'static str,
}

struct FakeBrowse {
    port: u16,
    key: SigningKey,
    seen: Arc<Mutex<Seen>>,
    behaviour: Arc<Mutex<Behaviour>>,
}

impl FakeBrowse {
    async fn start() -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let key = wire::new_key();
        let seen = Arc::new(Mutex::new(Seen::default()));
        let behaviour = Arc::new(Mutex::new(Behaviour {
            forge: None,
            revoked: false,
            scopes: vec!["read", "act-own-pages"],
            pairing: "paired",
        }));
        let (k, s, b) = (key.clone(), seen.clone(), behaviour.clone());
        tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    continue;
                };
                let (key, seen, behaviour) = (k.clone(), s.clone(), b.clone());
                tokio::spawn(async move {
                    let Ok(Some((head, body))) = read_request(&mut stream).await else {
                        return;
                    };
                    let browse_key = wire::public_key_b64(&key);
                    let (status, answer, nonce) =
                        answer(port, &browse_key, &head, &body, &seen, &behaviour);
                    let mut bytes = response(status, &answer);
                    if let Some(nonce) = nonce {
                        let signer = behaviour.lock().unwrap().forge.clone().unwrap_or(key);
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
            behaviour,
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

    fn faults(&self) -> Vec<String> {
        self.seen.lock().unwrap().faults.clone()
    }
}

/// A signed request's headers checked as browse's `Connect.verify` does.
fn verify(head: &Head, body: &[u8], client_key: Option<&str>) -> Result<(), String> {
    let header = |name: &str| head.header(name).ok_or(format!("no {name}"));
    let id = header("x-client-id")?;
    let stamp: i64 = header("x-timestamp")?
        .parse()
        .map_err(|_| "x-timestamp isn't unix ms")?;
    let nonce = header("x-nonce")?;
    if nonce.len() != 32 || !nonce.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("nonce {nonce:?} isn't 16 bytes of hex"));
    }
    if id != CLIENT_ID {
        return Err(format!("client id {id:?}"));
    }
    if (chrono::Utc::now().timestamp_millis() - stamp).abs() > 60_000 {
        return Err("stale".into());
    }
    let client_key = client_key.ok_or("signed before pairing")?;
    let text = wire::canonical(&head.method, &head.path, body, stamp, nonce, id);
    let signature = B64
        .decode(header("x-signature")?)
        .ok()
        .and_then(|der| DerSignature::try_from(der.as_slice()).ok())
        .ok_or("x-signature isn't base64 DER")?;
    wire::parse_public_key(client_key)
        .ok_or("client key")?
        .verify(text.as_bytes(), &signature)
        .map_err(|_| "bad signature".to_owned())
}

/// browse's answer to one request: `(status, body, nonce to sign the answer
/// over)`.
fn answer(
    port: u16,
    browse_key: &str,
    head: &Head,
    body: &[u8],
    seen: &Mutex<Seen>,
    behaviour: &Mutex<Behaviour>,
) -> (u16, Vec<u8>, Option<String>) {
    let json = |v: serde_json::Value| serde_json::to_vec(&v).unwrap();
    let mut seen = seen.lock().unwrap();
    let harness = head.header("x-client-id").is_some() || head.path.starts_with("/pair");
    if head.method != "POST" || !harness {
        // Not a connected app's: browse's own agent's token check refuses it.
        seen.strangers += 1;
        return (
            if head.method == "POST" { 401 } else { 405 },
            Vec::new(),
            None,
        );
    }
    if head.header("origin").is_some() || head.header("host") != Some(&format!("127.0.0.1:{port}"))
    {
        seen.faults.push(format!("{}: Origin or Host", head.path));
        return (
            403,
            json(serde_json::json!({ "error": "bad_origin" })),
            None,
        );
    }
    if head.path == "/pair" {
        let request: serde_json::Value = serde_json::from_slice(body).unwrap_or_default();
        let offers_protocol = request["protocol"]
            .as_array()
            .is_some_and(|p| p.iter().any(|v| v == wire::PROTOCOL));
        if request["name"] != "Harness" || !offers_protocol {
            seen.faults.push(format!("/pair {request}"));
            return (
                400,
                json(serde_json::json!({ "error": "bad_request" })),
                None,
            );
        }
        seen.client_key = request["client_key"].as_str().map(str::to_owned);
        seen.nonce = request["nonce"].as_str().map(str::to_owned);
        return (
            200,
            json(serde_json::json!({
                "protocol": wire::PROTOCOL,
                "client_id": CLIENT_ID,
                "browse_key": browse_key,
                "expires_in": 120,
            })),
            None,
        );
    }
    let nonce = head.header("x-nonce").unwrap_or_default().to_owned();
    if let Err(fault) = verify(head, body, seen.client_key.as_deref()) {
        seen.faults.push(format!("{}: {fault}", head.path));
        return (
            401,
            json(serde_json::json!({ "error": "bad_signature" })),
            Some(nonce),
        );
    }
    if !seen.nonces.insert(nonce.clone()) {
        seen.faults.push(format!("{}: nonce reused", head.path));
        return (
            401,
            json(serde_json::json!({ "error": "replayed" })),
            Some(nonce),
        );
    }
    let behaviour = behaviour.lock().unwrap();
    if behaviour.revoked {
        return (
            401,
            json(serde_json::json!({ "error": "unknown_client" })),
            Some(nonce),
        );
    }
    let request: serde_json::Value = serde_json::from_slice(body).unwrap_or_default();
    match head.path.as_str() {
        "/pair/status" if behaviour.pairing != "paired" => (
            200,
            json(serde_json::json!({ "status": behaviour.pairing })),
            Some(nonce),
        ),
        "/pair/status" => (
            200,
            json(serde_json::json!({ "status": "paired", "scopes": behaviour.scopes })),
            Some(nonce),
        ),
        "/session/close" => {
            let session = request["session"].as_str().unwrap_or_default().to_owned();
            seen.closed.push(session);
            (200, json(serde_json::json!({ "closed": 1 })), Some(nonce))
        }
        "/mcp" => {
            seen.mcp.push(request.clone());
            let tool = request["params"]["name"].as_str().unwrap_or_default();
            let refusal = match tool {
                "theme" => Some(
                    serde_json::json!({ "error": "out_of_scope", "tool": "theme", "scope": "none" }),
                ),
                "run_js" if !behaviour.scopes.contains(&"run-js") => Some(
                    serde_json::json!({ "error": "out_of_scope", "tool": "run_js", "scope": "run-js" }),
                ),
                "read" if request["params"]["arguments"]["page"] == "t1" => {
                    Some(serde_json::json!({ "error": "declined" }))
                }
                _ => None,
            };
            if let Some(refusal) = refusal {
                return (403, json(refusal), Some(nonce));
            }
            if request.get("id").is_none() {
                // A notification: nothing to say, and that is signed too.
                return (202, Vec::new(), Some(nonce));
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
        _ => (
            404,
            json(serde_json::json!({ "error": "not_found" })),
            Some(nonce),
        ),
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

/// Raw bytes to `port`, and the status line of the answer.
async fn raw(port: u16, request: &str) -> String {
    let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut answer = Vec::new();
    let _ = stream.read_to_end(&mut answer).await;
    String::from_utf8_lossy(&answer)
        .lines()
        .next()
        .unwrap_or_default()
        .to_owned()
}

async fn eventually(mut check: impl FnMut() -> bool) {
    for _ in 0..200 {
        if check() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("timed out");
}

fn token_of(server: &harness_adapters::McpServer) -> String {
    server.headers[0]
        .1
        .strip_prefix("Bearer ")
        .unwrap()
        .to_owned()
}

fn tool_text(body: &serde_json::Value) -> String {
    assert_eq!(body["result"]["isError"], true, "{body}");
    body["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// Pair `link` and wait until it's recorded.
async fn pair(link: &Arc<BrowseLink>) {
    link.start_pair().await.unwrap();
    eventually(|| link.status().paired).await;
}

#[tokio::test]
async fn the_full_flow_against_a_fake_browse() {
    let dir = tempfile::tempdir().unwrap();
    let browse = FakeBrowse::start().await;
    let connect = browse.publish(dir.path());
    let state = dir.path().join("browse-link.json");
    let link = Arc::new(BrowseLink::new(
        state.clone(),
        KeyStore::File(dir.path().join("key")),
        Some(connect.clone()),
    ));

    // Something else on the machine probing browse's port (a dev-server
    // scanner's `HEAD /`) is answered and changes nothing.
    let probe = format!(
        "HEAD / HTTP/1.1\r\nHost: localhost:{}\r\nConnection: close\r\n\r\n",
        browse.port
    );
    assert!(raw(browse.port, &probe).await.starts_with("HTTP/1.1 405"));

    // Pairing: both sides derive the same six digits, shown until the user
    // answers in browse.
    browse.behaviour.lock().unwrap().pairing = "pending";
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
    assert_eq!(link.status().pairing_code, Some(code.clone()));
    // Asked at least once and still pending: the code stays up.
    eventually(|| !browse.seen.lock().unwrap().nonces.is_empty()).await;
    assert_eq!(link.status().pairing_code, Some(code));
    assert!(!link.status().paired);
    browse.behaviour.lock().unwrap().pairing = "paired";
    eventually(|| link.status().paired).await;
    assert_eq!(link.status().scopes, ["read", "act-own-pages"]);
    assert!(link.status().pairing_code.is_none());
    // The pairing survives a restart, and its file holds nothing secret:
    // browse's id and public key, the scopes, and when.
    let reloaded = BrowseLink::new(
        state.clone(),
        KeyStore::File(dir.path().join("key")),
        Some(connect.clone()),
    );
    assert!(reloaded.status().paired);
    let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(&state).unwrap()).unwrap();
    let mut fields: Vec<_> = saved.as_object().unwrap().keys().cloned().collect();
    fields.sort();
    assert_eq!(fields, ["browseKey", "clientId", "pairedAt", "scopes"]);
    let secret = std::fs::read(dir.path().join("key")).unwrap();
    let text = saved.to_string();
    assert!(!text.contains(&B64.encode(&secret)) && !text.contains(&wire::hex(&secret)));

    // A run's browse server, and requests through the relay.
    let server = link.mcp_server_for_run("run-1").await.unwrap();
    assert_eq!(server.name, "browse");
    assert!(server.url.starts_with("http://127.0.0.1:"));
    let relay: u16 = server
        .url
        .trim_start_matches("http://127.0.0.1:")
        .trim_end_matches("/mcp")
        .parse()
        .unwrap();
    let token = token_of(&server);
    assert_eq!(token.len(), 64, "256 random bits");
    let list = serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" });
    let (status, body) = post(&server.url, Some(&token), None, list.clone()).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["result"]["content"][0]["text"], "ok");
    let open = serde_json::json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {
            "name": "open", "arguments": { "url": "https://example.com" },
            // An agent can't pick another run's pages.
            "_meta": { "browse/session": "run:someone-else" },
        },
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
    // A notification is answered with browse's signed, empty 202.
    let initialized =
        serde_json::json!({ "jsonrpc": "2.0", "method": "notifications/initialized" });
    assert_eq!(
        post(&server.url, Some(&token), None, initialized).await.0,
        202
    );

    // Refusals reach the model as tool errors it can read.
    let call = |id: u64, name: &str, arguments: serde_json::Value| {
        serde_json::json!({
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": { "name": name, "arguments": arguments },
        })
    };
    let (status, body) = post(
        &server.url,
        Some(&token),
        None,
        call(3, "theme", serde_json::json!({})),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(
        tool_text(&body),
        "browse doesn't let connected apps use theme"
    );
    let (_, body) = post(
        &server.url,
        Some(&token),
        None,
        call(4, "run_js", serde_json::json!({ "code": "1" })),
    )
    .await;
    assert!(
        tool_text(&body).starts_with("run_js needs the run-js scope"),
        "{body}"
    );
    let (_, body) = post(
        &server.url,
        Some(&token),
        None,
        call(5, "read", serde_json::json!({ "page": "t1" })),
    )
    .await;
    assert_eq!(
        tool_text(&body),
        "the user didn't allow Harness to use their tabs in browse"
    );

    // Two requests over one kept-alive connection (graff's client reuses it).
    {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", relay))
            .await
            .unwrap();
        let body = list.to_string();
        for _ in 0..2 {
            let request = format!(
                "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{relay}\r\nAuthorization: Bearer {token}\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
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
    // No token, a wrong or truncated one, a web page, another Host, another
    // method, or a stranger's probe: refused by the relay.
    assert_eq!(post(&server.url, None, None, list.clone()).await.0, 401);
    assert_eq!(
        post(&server.url, Some("nope"), None, list.clone()).await.0,
        401
    );
    assert_eq!(
        post(&server.url, Some(&token[..63]), None, list.clone())
            .await
            .0,
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
    let rebound = format!(
        "POST /mcp HTTP/1.1\r\nHost: evil.example:{relay}\r\nAuthorization: Bearer {token}\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"
    );
    assert!(raw(relay, &rebound).await.starts_with("HTTP/1.1 403"));
    let get = format!("GET /mcp HTTP/1.1\r\nHost: 127.0.0.1:{relay}\r\nConnection: close\r\n\r\n");
    assert!(raw(relay, &get).await.starts_with("HTTP/1.1 405"));
    let probe = format!("HEAD / HTTP/1.1\r\nHost: localhost:{relay}\r\nConnection: close\r\n\r\n");
    assert!(raw(relay, &probe).await.starts_with("HTTP/1.1 404"));

    // A squatter's answer is refused, and the model is told why.
    browse.behaviour.lock().unwrap().forge = Some(wire::new_key());
    let (_, body) = post(&server.url, Some(&token), None, list.clone()).await;
    assert!(
        body["error"]["message"]
            .as_str()
            .unwrap()
            .contains("wasn't signed"),
        "{body}"
    );
    browse.behaviour.lock().unwrap().forge = None;

    // The user allows more in browse: Settings shows it on its next look.
    browse.behaviour.lock().unwrap().scopes = vec!["read", "act-own-pages", "run-js"];
    link.refresh().await;
    assert_eq!(link.status().scopes, ["read", "act-own-pages", "run-js"]);

    // The run ends: its pages close and its token stops working.
    link.end_run("run-1");
    eventually(|| browse.seen.lock().unwrap().closed == ["run:run-1"]).await;
    assert_eq!(
        post(&server.url, Some(&token), None, list.clone()).await.0,
        401
    );

    // Revoked in browse: a signed unknown_client forgets the pairing.
    let other = link.mcp_server_for_run("run-2").await.unwrap();
    browse.behaviour.lock().unwrap().revoked = true;
    let (_, body) = post(&other.url, Some(&token_of(&other)), None, list).await;
    assert!(
        body["error"]["message"]
            .as_str()
            .unwrap()
            .contains("no longer knows Harness"),
        "{body}"
    );
    assert!(!link.status().paired);
    assert!(link.status().error.is_some());
    assert!(!state.exists());
    assert!(
        link.mcp_server_for_run("run-3").await.is_none(),
        "unpaired runs get no browse server"
    );

    // Paired again, then revoked while no run is going: Settings' next look
    // finds out.
    browse.behaviour.lock().unwrap().revoked = false;
    pair(&link).await;
    browse.behaviour.lock().unwrap().revoked = true;
    link.refresh().await;
    assert!(!link.status().paired);

    assert_eq!(browse.faults(), Vec::<String>::new());
    // At least the probe above; the machine may have sent more.
    assert!(browse.seen.lock().unwrap().strangers >= 1);
}

#[tokio::test]
async fn a_cancelled_pairing_stays_cancelled() {
    let dir = tempfile::tempdir().unwrap();
    let browse = FakeBrowse::start().await;
    let link = Arc::new(BrowseLink::new(
        dir.path().join("browse-link.json"),
        KeyStore::File(dir.path().join("key")),
        Some(browse.publish(dir.path())),
    ));
    // Declined in browse: Settings says so.
    browse.behaviour.lock().unwrap().pairing = "declined";
    link.start_pair().await.unwrap();
    eventually(|| link.status().pairing_code.is_none()).await;
    assert_eq!(
        link.status().error.as_deref(),
        Some("Pairing was declined in browse.")
    );
    assert!(!link.status().paired);

    // Connect, then Connect again: the second code is the one up, and the
    // first pairing's end doesn't take it down.
    browse.behaviour.lock().unwrap().pairing = "pending";
    link.start_pair().await.unwrap();
    let second = link.start_pair().await.unwrap();
    assert_eq!(link.status().pairing_code, Some(second.clone()));
    assert!(link.status().error.is_none());
    let asked = browse.seen.lock().unwrap().nonces.len();
    eventually(|| browse.seen.lock().unwrap().nonces.len() > asked + 1).await;
    assert_eq!(link.status().pairing_code, Some(second));
    browse.behaviour.lock().unwrap().pairing = "paired";
    eventually(|| link.status().paired).await;
    link.disconnect();

    // Cancel while browse is still asking: nothing is recorded afterwards,
    // even once browse would have said yes.
    link.start_pair().await.unwrap();
    link.disconnect();
    assert!(link.status().pairing_code.is_none());
    let polls = browse.seen.lock().unwrap().nonces.len();
    tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
    assert!(!link.status().paired);
    assert_eq!(
        browse.seen.lock().unwrap().nonces.len(),
        polls,
        "no more polling"
    );
    assert_eq!(browse.faults(), Vec::<String>::new());
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
