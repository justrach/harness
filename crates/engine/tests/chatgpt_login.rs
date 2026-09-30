//! Harness's own ChatGPT plan sign-in through the engine: it starts without a
//! CLI, reports progress to a poller (a phone), can be cancelled, and the
//! signed-in state and sign-out read and clear Harness's own credential store.
//!
//! One test function: the store location is process env.
#![cfg(unix)]

use std::path::Path;
use std::time::Duration;

use harness_engine::{AgentAccounts, AgentAccountsConfig};
use harness_proto::{AgentLoginMode, AgentLoginStatus};

fn test_accounts(root: &Path) -> AgentAccounts {
    let home = root.join("graff-home");
    std::fs::create_dir_all(&home).expect("graff home");
    AgentAccounts::new(AgentAccountsConfig {
        data_dir: root.join("data"),
        claude_config_dir: root.join("claude"),
        claude_config_file: root.join("claude.json"),
        codex_home: root.join("codex"),
        cursor_sdk_auth_file: root.join("cursor-sdk").join("auth.json"),
        graff_home: home,
    })
}

#[tokio::test]
async fn the_chatgpt_sign_in_runs_inside_harness() {
    let root = tempfile::tempdir().expect("root");
    let store = root.path().join("chatgpt");
    // SAFETY: the only test in this binary, set before anything reads them.
    unsafe {
        std::env::set_var("HARNESS_CHATGPT_HOME", &store);
        std::env::set_var("HARNESS_NO_BROWSER", "1");
    }
    let accounts = test_accounts(root.path());

    // Not signed in yet.
    let status = accounts.chatgpt_plan_status();
    assert!(!status.signed_in && !status.plan_usage);

    // Starting needs no CLI and no url: the browser opens on this computer.
    let start = accounts.start_chatgpt_login();
    assert_eq!(start.mode, AgentLoginMode::Browser);
    assert!(start.url.is_empty());

    // A poller sees it waiting for the browser.
    let mut waiting = None;
    for _ in 0..150 {
        let poll = accounts.poll_login(&start.login_id).await.expect("poll");
        assert_eq!(poll.status, AgentLoginStatus::Pending, "{poll:?}");
        if poll.message.is_some() {
            waiting = poll.message;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(
        waiting.as_deref(),
        Some("Finish signing in in your browser.")
    );

    // Cancelling ends it, and nothing was stored.
    accounts.cancel_login(&start.login_id);
    assert!(accounts.poll_login(&start.login_id).await.is_err());
    assert!(!accounts.chatgpt_plan_status().signed_in);
    assert!(!store.join("credentials.json").exists());

    // A stored sign-in with plan usage reads as connected, then signs out.
    std::fs::create_dir_all(&store).expect("store");
    std::fs::write(
        store.join("credentials.json"),
        r#"{"email":"me@example.com","access_token":"a","scopes":["openid","chatgpt.tokens.use.direct"]}"#,
    )
    .expect("credentials");
    let status = accounts.chatgpt_plan_status();
    assert!(status.signed_in && status.plan_usage);
    assert_eq!(status.email.as_deref(), Some("me@example.com"));

    assert!(accounts.sign_out_chatgpt().await.expect("sign out"));
    assert!(!accounts.chatgpt_plan_status().signed_in);
}
