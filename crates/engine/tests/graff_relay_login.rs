//! graff's ChatGPT recovery finished on another device (a phone), end to end
//! against a fake `graff` that listens on a loopback callback like the real
//! one: the host hands out OpenAI's page with its browser muted, refuses a
//! redirect that isn't this sign-in's, and delivers the right one to graff.
//!
//! One test function: resolving `graff` reads process env, and this sets it.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::time::Duration;

use harness_engine::{AgentAccounts, AgentAccountsConfig};
use harness_proto::{AgentLoginMode, AgentLoginStatus};

/// `graff login chatgpt-new`: prints the authorize page for a callback on a
/// free loopback port, serves that one callback, and signs in only for
/// `code=good` with the right state.
fn fake_graff(dir: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("fake-graff");
    std::fs::write(
        &path,
        r#"#!/usr/bin/env python3
import http.server, os, shutil, sys, urllib.parse
if sys.argv[1:2] == ["--version"]:
    print("graff 0.0.302.18"); sys.exit(0)
if sys.argv[1:3] != ["login", "chatgpt-new"]:
    sys.exit(64)
home = os.environ["HOME"]
with open(os.path.join(home, "open-resolved"), "w") as f:
    f.write(shutil.which("open") or "")
outcome = {}
class Callback(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        outcome["ok"] = (url.path == "/auth/callback" and query.get("state") == ["st4te"]
                         and query.get("code") == ["good"] and query.get("client_id") == ["issued"])
        self.send_response(200); self.end_headers(); self.wfile.write(b"done")
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Callback)
redirect = "http://127.0.0.1:%d/auth/callback" % server.server_address[1]
page = "https://auth.openai.com/api/accounts/authorize?" + urllib.parse.urlencode({
    "client_id": "dynamic_agent_client", "response_type": "code", "redirect_uri": redirect,
    "state": "st4te", "code_challenge": "c", "code_challenge_method": "S256"})
print("\nSign in with ChatGPT (your browser should open it):\n\n" + page + "\n", flush=True)
print("waiting for the sign-in on " + redirect + " …", flush=True)
server.handle_request()
if outcome.get("ok"):
    os.makedirs(os.path.join(home, ".graff", "credentials"), exist_ok=True)
    with open(os.path.join(home, ".graff", "credentials", "chatgpt-new.json"), "w") as f:
        f.write('{"access_token":"fixture","scopes":["chatgpt.tokens.use.direct"]}')
    print("✓ signed in to ChatGPT as fixture; plan usage is on.", flush=True)
else:
    print("✗ ChatGPT sign-in failed: rejected", flush=True)
"#,
    )
    .expect("fake graff");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    path
}

#[tokio::test]
async fn chatgpt_recovery_finishes_on_another_device() {
    let root = tempfile::tempdir().unwrap();
    let fake = fake_graff(root.path());
    // SAFETY: the only test in this binary, so nothing else reads env meanwhile.
    unsafe { std::env::set_var("GRAFF_EXECUTABLE", &fake) };
    let home = root.path().join("graff-home");
    std::fs::create_dir_all(&home).unwrap();
    let accounts = AgentAccounts::new(AgentAccountsConfig {
        data_dir: root.path().join("data"),
        claude_config_dir: root.path().join("claude"),
        claude_config_file: root.path().join("claude.json"),
        codex_home: root.path().join("codex"),
        cursor_sdk_auth_file: root.path().join("cursor-sdk").join("auth.json"),
        graff_home: home.clone(),
    });

    // Only graff's ChatGPT sign-in can be finished elsewhere.
    assert!(accounts.start_graff_reauth("xai", true).await.is_err());

    let start = accounts
        .start_graff_reauth("chatgpt-new", true)
        .await
        .expect("relayed start");
    assert_eq!(start.mode, AgentLoginMode::RelayBrowser);
    assert!(
        start
            .url
            .starts_with("https://auth.openai.com/api/accounts/authorize?")
    );
    assert_eq!(start.code, None);
    // The host's browser stayed shut: graff found the muted opener.
    let opener = std::fs::read_to_string(home.join("open-resolved")).unwrap();
    assert!(opener.contains(".noop-open"), "{opener}");
    // A second ask from the phone attaches to the same sign-in.
    let again = accounts
        .start_graff_reauth("chatgpt-new", true)
        .await
        .unwrap();
    assert_eq!(again.login_id, start.login_id);

    let page = reqwest::Url::parse(&start.url).unwrap();
    let redirect = page
        .query_pairs()
        .find(|(k, _)| k == "redirect_uri")
        .map(|(_, v)| v.into_owned())
        .unwrap();
    let login = start.login_id.as_str();
    assert!(
        accounts
            .complete_relayed_login("not-a-login", &redirect)
            .await
            .is_none()
    );
    for bad in [
        format!("{redirect}?code=good&state=old&client_id=issued"),
        format!("{redirect}?state=st4te"),
        "http://evil.test/auth/callback?code=good&state=st4te".to_string(),
    ] {
        let refused = accounts.complete_relayed_login(login, &bad).await.unwrap();
        assert!(refused.is_err(), "{bad}");
    }
    // Refusals never reached graff: it is still waiting.
    let poll = accounts.poll_login(login).await.unwrap();
    assert_eq!(poll.status, AgentLoginStatus::Pending);

    accounts
        .complete_relayed_login(
            login,
            &format!("{redirect}?code=good&state=st4te&client_id=issued"),
        )
        .await
        .unwrap()
        .expect("delivered to graff");
    let mut status = AgentLoginStatus::Pending;
    for _ in 0..100 {
        status = accounts.poll_login(login).await.unwrap().status;
        if status != AgentLoginStatus::Pending {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(status, AgentLoginStatus::Done);
    assert!(
        accounts
            .list_graff_logins()
            .iter()
            .any(|row| row.id == "chatgpt-new" && row.signed_in)
    );

    // An ordinary sign-in from Settings on another computer relays the same way.
    let fresh = accounts
        .start_graff_login_relayed("chatgpt-new")
        .await
        .expect("relayed sign-in");
    assert_eq!(fresh.mode, AgentLoginMode::RelayBrowser);
    assert_ne!(fresh.login_id, start.login_id);
    assert!(
        fresh
            .url
            .starts_with("https://auth.openai.com/api/accounts/authorize?")
    );
}
