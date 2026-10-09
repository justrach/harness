//! Real `graff login chatgpt-new`, relayed: the host reads graff's actual
//! output and delivers a redirect to its actual loopback listener. No sign-in
//! happens: the delivered redirect is OpenAI's "access denied" answer, which
//! graff must take as the end of the attempt. Uses a throwaway graff home.
//! Requires `graff` on PATH (or GRAFF_EXECUTABLE) and loopback port 1455–1459.
//! cargo test -p harness-engine --test real_graff_relay_login -- --ignored --nocapture
#![cfg(unix)]

use std::time::Duration;

use harness_engine::{AgentAccounts, AgentAccountsConfig};
use harness_proto::{AgentLoginMode, AgentLoginStatus};

#[tokio::test]
#[ignore = "runs the real graff CLI (contacts no account; signs nothing in)"]
async fn real_graff_takes_a_relayed_redirect() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("graff-home");
    std::fs::create_dir_all(home.join(".graff").join("credentials")).unwrap();
    let accounts = AgentAccounts::new(AgentAccountsConfig {
        data_dir: root.path().join("data"),
        claude_config_dir: root.path().join("claude"),
        claude_config_file: root.path().join("claude.json"),
        codex_home: root.path().join("codex"),
        cursor_sdk_auth_file: root.path().join("cursor-sdk").join("auth.json"),
        graff_home: home,
    });
    let start = accounts
        .start_graff_reauth("chatgpt-new", true)
        .await
        .expect("real graff hands out its sign-in page");
    assert_eq!(start.mode, AgentLoginMode::RelayBrowser);
    let page = reqwest::Url::parse(&start.url).unwrap();
    assert_eq!(page.host_str(), Some("auth.openai.com"));
    let param = |name: &str| {
        page.query_pairs()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.into_owned())
            .unwrap()
    };
    let (redirect, state) = (param("redirect_uri"), param("state"));
    eprintln!("redirect {redirect}");

    let refused = accounts
        .complete_relayed_login(&start.login_id, &format!("{redirect}?code=x&state=wrong"))
        .await
        .unwrap();
    assert!(refused.is_err());
    assert_eq!(
        accounts.poll_login(&start.login_id).await.unwrap().status,
        AgentLoginStatus::Pending,
        "a refused redirect never reaches graff"
    );

    accounts
        .complete_relayed_login(
            &start.login_id,
            &format!("{redirect}?error=access_denied&state={state}"),
        )
        .await
        .unwrap()
        .expect("graff's listener took the redirect");
    let mut poll = None;
    for _ in 0..100 {
        let now = accounts.poll_login(&start.login_id).await.unwrap();
        if now.status != AgentLoginStatus::Pending {
            poll = Some(now);
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let poll = poll.expect("graff ended the attempt");
    eprintln!("graff: {poll:?}");
    assert_eq!(
        poll.status,
        AgentLoginStatus::Error,
        "a denial never signs in"
    );
}
