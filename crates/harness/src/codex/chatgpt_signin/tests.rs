//! The sign-in flow against a mock identity provider that signs real RS256
//! ID tokens. Nothing here reaches OpenAI.

use super::*;
use ring::rand::SystemRandom;
use ring::signature::{RSA_PKCS1_SHA256, RsaKeyPair};
use serde_json::json;
use std::sync::{Arc, Mutex, OnceLock};

/// A throwaway 2048-bit key used only to sign test tokens.
const KEY_B64: &str = "MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQCWq/+mtC2MxqbAI9PLCKfnoYy+SZkbj3cl01OY54x2LBAUTF7F3q/7h3M4zrcDRN5S+r5YzIm6r7iJZDXNFKq4hITBSsacKqi4IUPYniMkD3Ij6sksQekrScfR/WtPz17xTlqVX+H5sUWvqWWvNL1znUkHNseCwOlQhD+rvGBbIr7y25YqB0PKt+MHos4FS0oQBp5/ogMy92XyIvCg4jABSS2R9jvzY4I/MrKdsTBd548yyz9mFR0rIJ6ZThLr4AimScFAxrc/EKGIva02h4/fXGy873vCyiBtV0wa4A9ouKFs1KOm7SSmJnVnfA5nM6ntBqp3AO415amC5/JWFDy7AgMBAAECggEAC4G1M3j9JYwiPfg+e3n8wK7QvdOHEtjBA62A6+N7EadJzxMKBdh83hu5C/SVe3Vt+S5XDRcJya0TzcJObYwPgan1LYHVayXC3tUDhm6FRoK7d8y9cljSQtEOppXQ9TZkDM+sEU5SRqxoIwMv1dKUSVkQs7FWSUEMUG7ZIfdv8GW36burguWQM5HWR1WvZV3TJrlV2/tQqJEulcYh1Dqs+3vPV0iyCyjAiqWZO5Y+WdsKk7B8CSZwr/8t4MT0tco9F+892WhU5W/RWhXGNftUk39OuE0qysrtqaVc3RxiWZFWVpTK6F0XEHqbY05TbZXa98LhMoKKvWahew6i4CdwsQKBgQDGHsvhOBs97oGrA2jVvPYDEbKivANi+PyRSHy89IN8GaV/bhd2qalSVDJirJP8tOV7QXddSq6DMoXM6AzObX1lzxOUmfEgs6snP6+pCLTlKDkz1eTPLis/n05KLOAi9ip7y6fFjwqzfngPPfBkohi+3OFJrsv9l0OO0znhQUvsUwKBgQDCsJXblaVHbR1RLEcg/pCvkJbBB28gg4o+iwaJEsuWfHEnddwlMxQsXkiXfVcA0CsGqGLiR3d9Jua6/CU2pTW7vcYEG81wmpor+0A6t1WhakRN8dcCTt4tWGQ7JBo94QBrGAnbUsHJgthmKq97IHFHw6+vyX+07o9WsybvVWsg+QKBgQDF6vIFtgUQ43lKHAfYrgKdokpwY56GevHlOSLTqPjJOt2n5ZUvB+KMymvjQ0A7TYOKlCXoXrjje89Kme5hMeP5ltqaswa9gn9SoD6dgIMmAf7TF7SSfC7cSgrt8tKeWoiqTxL1OyaXlZnesCO8hGpwETxGXYaPeVMWFVFXA+IS3QKBgCjnQsTcntnv0c4BGHyVHz7TiOjLMAzLthrHyLq5yS43vOpGd9cU8TMVJ/kz6ziPg8qlTAkwbKlNqAI3AXaGpVBpYZXxZWs4ABYndmofpI0CL5GUstCYU1OBk6VdQ2omwJi/dyquK2qz49UrOK0MtuAV++5ZzkvsJw9XGmIENzq5AoGBALBPC7h3shcZZbrPechQnuzREU83twaT+UIL7rI12BrZTGrDRtiqsRwXMKCqx9ENStMFISfU1wQKmSsHfVUjXLfq1C/WRsbb3ru15CzEoALrz5kwgvSG7Pk2DAaiBIPDp2ihhQY2YsGryAtjaTJbd4GJPmK7syFtGjtD5vjd9d9A";

fn key() -> RsaKeyPair {
    let der = base64::engine::general_purpose::STANDARD
        .decode(KEY_B64)
        .unwrap();
    RsaKeyPair::from_pkcs8(&der).unwrap()
}

fn jwt(claims: &Value) -> String {
    let header = B64.encode(br#"{"alg":"RS256","kid":"k1","typ":"JWT"}"#);
    let payload = B64.encode(serde_json::to_vec(claims).unwrap());
    let signing = format!("{header}.{payload}");
    let pair = key();
    let mut signature = vec![0; pair.public().modulus_len()];
    pair.sign(
        &RSA_PKCS1_SHA256,
        &SystemRandom::new(),
        signing.as_bytes(),
        &mut signature,
    )
    .unwrap();
    format!("{signing}.{}", B64.encode(signature))
}

fn jwks() -> Value {
    let pair = key();
    let public: ring::rsa::PublicKeyComponents<Vec<u8>> = pair.public().into();
    json!({ "keys": [{
        "kty": "RSA", "kid": "k1", "use": "sig", "alg": "RS256",
        "n": B64.encode(&public.n),
        "e": B64.encode(&public.e),
    }] })
}

fn claims(issuer: &str, audience: &str, nonce: &str, sub: &str) -> Value {
    json!({
        "iss": issuer, "aud": audience, "nonce": nonce, "sub": sub,
        "email": "me@example.com", "exp": now() + 3600,
    })
}

#[test]
fn an_id_token_must_be_signed_by_a_published_key_for_this_attempt() {
    let ok = jwt(&claims("https://idp", "client", "n1", "user-1"));
    let check = |token: &str, iss: &str, aud: &str, nonce: &str, at: u64| {
        verify_id_token(token, &jwks(), iss, aud, nonce, at)
    };
    let verified = check(&ok, "https://idp", "client", "n1", now()).unwrap();
    assert_eq!(verified["sub"], "user-1");

    assert!(
        check(&ok, "https://other", "client", "n1", now()).is_err(),
        "issuer"
    );
    assert!(
        check(&ok, "https://idp", "someone-else", "n1", now()).is_err(),
        "audience"
    );
    assert!(
        check(&ok, "https://idp", "client", "n2", now()).is_err(),
        "nonce"
    );
    assert!(
        check(&ok, "https://idp", "client", "n1", now() + 7200).is_err(),
        "expiry"
    );

    // Change one payload byte: the signature no longer matches.
    let mut parts: Vec<String> = ok.split('.').map(str::to_owned).collect();
    let forged = claims("https://idp", "client", "n1", "user-2");
    parts[1] = B64.encode(serde_json::to_vec(&forged).unwrap());
    assert!(
        check(&parts.join("."), "https://idp", "client", "n1", now()).is_err(),
        "signature"
    );

    // An unsigned or differently-signed token is refused outright.
    let none = format!("{}.{}.", B64.encode(br#"{"alg":"none"}"#), parts[1]);
    assert!(
        check(&none, "https://idp", "client", "n1", now()).is_err(),
        "alg none"
    );
    assert!(check("not-a-token", "https://idp", "client", "n1", now()).is_err());
}

#[test]
fn audience_may_be_a_list() {
    let mut c = claims("https://idp", "x", "n", "u");
    c["aud"] = json!(["other", "client"]);
    assert!(verify_id_token(&jwt(&c), &jwks(), "https://idp", "client", "n", now()).is_ok());
}

#[test]
fn pkce_challenge_is_the_sha256_of_the_verifier() {
    let (verifier, challenge) = pkce();
    assert!(
        verifier.len() >= 43 && verifier.len() <= 128,
        "RFC 7636 length"
    );
    assert_eq!(challenge, B64.encode(Sha256::digest(verifier.as_bytes())));
    assert_ne!(pkce().0, verifier, "fresh every time");
}

#[test]
fn the_declined_message_is_the_one_the_phones_key_on() {
    // The phone shows its "you didn't approve" screen for exactly this message.
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../apps/parity/vectors/chatgpt-sign-in.json"
    );
    let vector: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
    assert_eq!(vector["declinedMessage"], SignInError::Declined.to_string());
}

// ---------------------------------------------------------------------------
// A small HTTP server standing in for OpenAI
// ---------------------------------------------------------------------------

pub(crate) type Handler = Arc<dyn Fn(&str, &str) -> (u16, String) + Send + Sync>;

/// Serve `handler(method + " " + path, body) -> (status, json)`; returns the base URL.
pub(crate) async fn serve(handler: Handler) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let handler = handler.clone();
            tokio::spawn(async move {
                let mut buffer = Vec::new();
                let mut chunk = [0u8; 4096];
                let (head_end, length) = loop {
                    let n = socket.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    buffer.extend_from_slice(&chunk[..n]);
                    if let Some(p) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buffer[..p]).to_lowercase();
                        let length = head
                            .lines()
                            .find_map(|l| l.strip_prefix("content-length:"))
                            .and_then(|v| v.trim().parse::<usize>().ok())
                            .unwrap_or(0);
                        break (p + 4, length);
                    }
                };
                while buffer.len() < head_end + length {
                    let n = socket.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buffer.extend_from_slice(&chunk[..n]);
                }
                let text = String::from_utf8_lossy(&buffer).into_owned();
                let mut line = text.lines().next().unwrap_or("").split_whitespace();
                let route = format!(
                    "{} {}",
                    line.next().unwrap_or(""),
                    line.next().unwrap_or("")
                );
                let body = text.get(head_end..).unwrap_or("");
                let (status, json) = handler(&route, body);
                let response = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{json}",
                    json.len()
                );
                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    base
}

pub(crate) fn form(body: &str) -> HashMap<String, String> {
    reqwest::Url::parse(&format!("http://x/?{body}"))
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect()
}

// ---------------------------------------------------------------------------
// Whole sign-ins
// ---------------------------------------------------------------------------

static STORE: OnceLock<tempfile::TempDir> = OnceLock::new();
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// One shared store directory; every test starts from an empty one.
fn fresh_store() {
    let dir = STORE.get_or_init(|| {
        let dir = tempfile::tempdir().unwrap();
        // SAFETY: set once, before any test reads it, under SERIAL.
        unsafe { std::env::set_var("HARNESS_CHATGPT_HOME", dir.path()) };
        dir
    });
    for entry in std::fs::read_dir(dir.path()).unwrap() {
        let path = entry.unwrap().path();
        if path.file_name().is_some_and(|n| n != "host-id") {
            let _ = std::fs::remove_file(path);
        }
    }
}

#[derive(Clone, Copy)]
enum Browser {
    Approves,
    ForgedRequestFirst,
    Declines,
    Silent,
}

#[derive(Default)]
struct Seen {
    authorize: Option<HashMap<String, String>>,
    token: Option<HashMap<String, String>>,
    revoke: Option<HashMap<String, String>>,
}

struct Run {
    result: Result<SignInOutcome, SignInError>,
    seen: Arc<Mutex<Seen>>,
    endpoints: Endpoints,
}

impl Run {
    fn authorize(&self) -> HashMap<String, String> {
        self.seen.lock().unwrap().authorize.clone().unwrap()
    }
    fn token(&self) -> Option<HashMap<String, String>> {
        self.seen.lock().unwrap().token.clone()
    }
    fn revoke(&self) -> Option<HashMap<String, String>> {
        self.seen.lock().unwrap().revoke.clone()
    }
}

async fn attempt(browser: Browser, sub: &'static str, scope: &'static str) -> Run {
    let seen = Arc::new(Mutex::new(Seen::default()));
    let issuer = Arc::new(Mutex::new(String::new()));
    let handler: Handler = {
        let (seen, issuer) = (seen.clone(), issuer.clone());
        Arc::new(move |route, body| match route {
            "GET /jwks" => (200, jwks().to_string()),
            "POST /token" => {
                let form = form(body);
                let mut seen = seen.lock().unwrap();
                let nonce = seen.authorize.as_ref().unwrap()["nonce"].clone();
                let id_token = jwt(&claims(
                    &issuer.lock().unwrap(),
                    &form["client_id"],
                    &nonce,
                    sub,
                ));
                seen.token = Some(form);
                let reply = json!({
                    "access_token": "access-1", "refresh_token": "refresh-1",
                    "id_token": id_token, "token_type": "Bearer",
                    "expires_in": 3600, "scope": scope,
                });
                (200, reply.to_string())
            }
            "POST /revoke" => {
                seen.lock().unwrap().revoke = Some(form(body));
                (200, String::new())
            }
            _ => (404, "{}".into()),
        })
    };
    let base = serve(handler).await;
    *issuer.lock().unwrap() = base.clone();
    let endpoints = Endpoints {
        issuer: base.clone(),
        authorize: format!("{base}/authorize"),
        token: format!("{base}/token"),
        jwks: format!("{base}/jwks"),
        revoke: format!("{base}/revoke"),
    };

    let cancel = CancellationToken::new();
    let on_progress = {
        let seen = seen.clone();
        move |SignInProgress::OpenBrowser(url): SignInProgress| {
            let query = form(reqwest::Url::parse(&url).unwrap().query().unwrap());
            let (redirect, state) = (query["redirect_uri"].clone(), query["state"].clone());
            seen.lock().unwrap().authorize = Some(query);
            tokio::spawn(async move {
                match browser {
                    Browser::Silent => {}
                    Browser::Declines => {
                        let _ =
                            reqwest::get(format!("{redirect}?error=access_denied&state={state}"))
                                .await;
                    }
                    Browser::Approves | Browser::ForgedRequestFirst => {
                        if matches!(browser, Browser::ForgedRequestFirst) {
                            let _ = reqwest::get(format!("{redirect}?code=evil&state=wrong")).await;
                            let _ =
                                reqwest::get(redirect.replace("/auth/callback", "/favicon.ico"))
                                    .await;
                        }
                        let _ = reqwest::get(format!(
                            "{redirect}?code=abc&state={state}&client_id=oaiapp_test"
                        ))
                        .await;
                    }
                }
            });
        }
    };
    let result = if matches!(browser, Browser::Silent) {
        let canceller = cancel.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            canceller.cancel();
        });
        sign_in_with(&endpoints, &cancel, on_progress).await
    } else {
        sign_in_with(&endpoints, &cancel, on_progress).await
    };
    Run {
        result,
        seen,
        endpoints,
    }
}

const ALL: &str = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";

#[tokio::test]
async fn first_sign_in_registers_the_app_and_stores_the_session() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    let run = attempt(Browser::Approves, "user-1", ALL).await;
    assert_eq!(
        run.result,
        Ok(SignInOutcome::Connected {
            email: Some("me@example.com".into())
        })
    );

    let asked = run.authorize();
    assert_eq!(asked["client_id"], "dynamic_agent_client");
    assert_eq!(asked["agent_name_hint"], "Harness");
    assert_eq!(asked["response_type"], "code");
    assert_eq!(asked["code_challenge_method"], "S256");
    assert_eq!(asked["resource"], "https://api.openai.com/v1");
    assert!(asked["redirect_uri"].starts_with("http://127.0.0.1:"));
    assert!(asked["redirect_uri"].ends_with("/auth/callback"));
    assert!(
        asked["scope"]
            .split(' ')
            .any(|s| s == "chatgpt.tokens.use.direct")
    );
    assert!(asked["ext_agent_host_id"].starts_with("urn:uuid:"));
    assert!(!asked.contains_key("login_hint"));

    let exchanged = run.token().unwrap();
    assert_eq!(exchanged["grant_type"], "authorization_code");
    assert_eq!(exchanged["client_id"], "oaiapp_test");
    assert_eq!(exchanged["code"], "abc");
    assert_eq!(exchanged["redirect_uri"], asked["redirect_uri"]);
    assert_eq!(
        B64.encode(Sha256::digest(exchanged["code_verifier"].as_bytes())),
        asked["code_challenge"],
        "the exchange proves the PKCE verifier"
    );

    let record = plan::read_credentials().unwrap();
    assert_eq!(record["access_token"], "access-1");
    assert_eq!(record["refresh_token"], "refresh-1");
    assert_eq!(record["client_id"], "oaiapp_test");
    assert_eq!(record["ext_agent_host_id"], asked["ext_agent_host_id"]);
    assert!(plan::grants_plan(&record));
    let status = plan::status();
    assert!(status.signed_in && status.plan_usage);
    assert_eq!(status.email.as_deref(), Some("me@example.com"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(plan::store_dir().join("credentials.json"))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}

#[tokio::test]
async fn signing_in_again_reuses_the_client_and_host_and_sends_hints() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    let first = attempt(Browser::Approves, "user-1", ALL).await;
    let host = first.authorize()["ext_agent_host_id"].clone();

    let again = attempt(Browser::Approves, "user-1", ALL).await;
    assert!(matches!(again.result, Ok(SignInOutcome::Connected { .. })));
    let asked = again.authorize();
    assert_eq!(
        asked["client_id"], "oaiapp_test",
        "the issued client, not the entrypoint"
    );
    assert!(!asked.contains_key("agent_name_hint"));
    assert_eq!(asked["login_hint"], "me@example.com");
    assert_eq!(asked["ext_agent_host_id"], host);
}

#[tokio::test]
async fn another_account_never_replaces_the_saved_one() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    attempt(Browser::Approves, "user-1", ALL).await;
    let other = attempt(Browser::Approves, "user-2", ALL).await;
    assert!(
        matches!(other.result, Err(SignInError::Failed(_))),
        "{:?}",
        other.result
    );
    assert_eq!(plan::read_registration().unwrap().subject, "user-1");
}

#[tokio::test]
async fn a_sign_in_without_plan_usage_is_kept_but_marked_off() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    let run = attempt(
        Browser::Approves,
        "user-1",
        "openid profile email offline_access",
    )
    .await;
    assert_eq!(
        run.result,
        Ok(SignInOutcome::PlanUsageOff {
            email: Some("me@example.com".into())
        })
    );
    let status = plan::status();
    assert!(status.signed_in);
    assert!(!status.plan_usage);
}

#[tokio::test]
async fn declining_in_the_browser_stores_nothing() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    let run = attempt(Browser::Declines, "user-1", ALL).await;
    assert_eq!(run.result, Err(SignInError::Declined));
    assert!(run.token().is_none(), "no code exchange after a decline");
    assert!(!plan::status().signed_in);
}

#[tokio::test]
async fn cancelling_stops_the_attempt() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    let run = attempt(Browser::Silent, "user-1", ALL).await;
    assert_eq!(run.result, Err(SignInError::Cancelled));
    assert!(!plan::status().signed_in);
}

#[tokio::test]
async fn a_forged_or_stray_request_does_not_end_the_attempt() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    let run = attempt(Browser::ForgedRequestFirst, "user-1", ALL).await;
    assert!(
        matches!(run.result, Ok(SignInOutcome::Connected { .. })),
        "{:?}",
        run.result
    );
    assert_eq!(
        run.token().unwrap()["code"],
        "abc",
        "the forged code was never used"
    );
}

#[tokio::test]
async fn signing_out_revokes_the_session_and_keeps_the_registration() {
    let _serial = SERIAL.lock().await;
    fresh_store();
    let run = attempt(Browser::Approves, "user-1", ALL).await;
    let revoked = sign_out_with(&run.endpoints).await.unwrap();
    assert!(revoked);
    assert!(plan::read_credentials().is_none());
    assert!(!plan::status().signed_in);
    assert_eq!(plan::read_registration().unwrap().client_id, "oaiapp_test");

    let sent = run.revoke().expect("OpenAI was told to end the session");
    assert_eq!(sent["token"], "refresh-1");
    assert_eq!(sent["token_type_hint"], "refresh_token");
    assert_eq!(sent["client_id"], "oaiapp_test");
}
