//! graff's own provider sign-ins end to end, against a fake `graff`: the link
//! and code reach the caller, graff's exit 0 on a refusal is not a success, a
//! finished sign-in shows as signed in, and cancelling leaves an existing login
//! alone.
//!
//! One test function: resolving `graff` reads process env, and this sets it.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::time::Duration;

use harness_engine::{AgentAccounts, AgentAccountsConfig};
use harness_proto::{AgentLoginMode, AgentLoginStatus};

fn test_accounts(root: &Path) -> (AgentAccounts, PathBuf) {
    let home = root.join("graff-home");
    std::fs::create_dir_all(&home).expect("graff home");
    let config = AgentAccountsConfig {
        data_dir: root.join("data"),
        claude_config_dir: root.join("claude"),
        claude_config_file: root.join("claude.json"),
        codex_home: root.join("codex"),
        cursor_sdk_auth_file: root.join("cursor-sdk").join("auth.json"),
        graff_home: home.clone(),
    };
    (AgentAccounts::new(config), home)
}

/// A `graff` that behaves like the real `graff login`, per provider:
/// - xai:  prints link + code, writes its credential, prints `✓`
/// - kimi: prints link + code, then `✗ …` and exits 0 (the real quirk)
/// - zai:  prints a link (no code) and parks until killed
fn fake_graff(dir: &Path) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join("fake-graff");
    std::fs::write(
        &path,
        r#"#!/bin/sh
[ "$1" = "--version" ] && { echo "graff 0.0.302.6"; exit 0; }
[ "$1" = login ] || exit 64
case "$2" in
xai)
  printf '\nTo log in to Grok (xAI), open this URL (browser should open automatically):\n\n  https://accounts.x.ai/device?user_code=ABCD-1234\n\nand confirm the code:  ABCD-1234\n\nwaiting for authorization…\n'
  command -v open > "$HOME/open-resolved"
  sleep 1
  mkdir -p "$HOME/.xai/credentials"
  printf '{"access_token":"a"}' > "$HOME/.xai/credentials/graff-oauth.json"
  printf '✓ logged into Grok (xAI)\n'
  ;;
kimi)
  printf '\nTo log in to Kimi, open this URL (browser should open automatically):\n\n  https://www.kimi.com/authorize?c=Q\n\nand confirm the code:  Q\n\nwaiting for authorization…\n'
  sleep 1
  printf '✗ the code expired — run `graff login kimi` again\n'
  ;;
zai)
  printf '\nTo log in to Z.AI Coding Plan, open this URL (browser should open automatically):\n\n  https://chat.z.ai/cli/authorize?flow=f1\n\nwaiting for authorization…\n'
  exec sleep 30
  ;;
esac
"#,
    )
    .expect("fake graff");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    path
}

/// Poll until the flow leaves Pending (or give up).
async fn settle(accounts: &AgentAccounts, login_id: &str) -> harness_proto::AgentLoginPoll {
    for _ in 0..100 {
        let poll = accounts.poll_login(login_id).await.expect("poll");
        if poll.status != AgentLoginStatus::Pending {
            return poll;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("sign-in never settled");
}

fn signed_in(accounts: &AgentAccounts) -> Vec<(String, bool)> {
    accounts
        .list_graff_logins()
        .into_iter()
        .map(|row| (row.id, row.signed_in))
        .collect()
}

#[tokio::test]
async fn graff_provider_sign_ins_end_to_end() {
    let root = tempfile::tempdir().unwrap();
    let fake = fake_graff(root.path());
    // SAFETY: the only test in this binary, so nothing else reads env meanwhile.
    unsafe { std::env::set_var("GRAFF_EXECUTABLE", &fake) };
    let (accounts, home) = test_accounts(root.path());

    // Nothing signed in yet, in provider order.
    assert_eq!(
        signed_in(&accounts),
        [
            ("xai".into(), false),
            ("kimi".into(), false),
            ("zai".into(), false)
        ]
    );
    let names: Vec<_> = accounts
        .list_graff_logins()
        .into_iter()
        .map(|r| r.name)
        .collect();
    assert_eq!(names, ["xAI", "Kimi", "Z.AI"]);

    // xAI: the link and code come back, graff's own opener is muted, and the
    // sign-in finishes once graff has written the credential.
    let start = accounts.start_graff_login("xai").await.expect("start xai");
    assert_eq!(
        start.url,
        "https://accounts.x.ai/device?user_code=ABCD-1234"
    );
    assert_eq!(start.code.as_deref(), Some("ABCD-1234"));
    assert_eq!(start.mode, AgentLoginMode::Browser);
    let poll = settle(&accounts, &start.login_id).await;
    assert_eq!(poll.status, AgentLoginStatus::Done, "{:?}", poll.message);
    assert_eq!(
        signed_in(&accounts),
        [
            ("xai".into(), true),
            ("kimi".into(), false),
            ("zai".into(), false)
        ]
    );
    let opener =
        std::fs::read_to_string(home.join("open-resolved")).expect("graff ran `command -v open`");
    assert!(
        opener.contains(".noop-open"),
        "graff's `open` must resolve to the muted stand-in, got {opener:?}"
    );
    // A settled flow is gone.
    assert!(accounts.poll_login(&start.login_id).await.is_err());

    // Kimi: graff exits 0 after `✗ …`. That is a failure, in graff's words,
    // and nothing is signed in.
    let start = accounts
        .start_graff_login("kimi")
        .await
        .expect("start kimi");
    assert_eq!(start.code.as_deref(), Some("Q"));
    let poll = settle(&accounts, &start.login_id).await;
    assert_eq!(poll.status, AgentLoginStatus::Error);
    assert_eq!(
        poll.message.as_deref(),
        Some("the code expired — run `graff login kimi` again")
    );
    assert!(!signed_in(&accounts)[1].1);

    // Z.AI prints no code. Cancelling kills graff and leaves the login that
    // was already there exactly as it was.
    let zai_credential = home.join(".zai/credentials/graff-oauth.json");
    std::fs::create_dir_all(zai_credential.parent().unwrap()).unwrap();
    std::fs::write(&zai_credential, "existing").unwrap();
    let start = accounts.start_graff_login("zai").await.expect("start zai");
    assert_eq!(start.url, "https://chat.z.ai/cli/authorize?flow=f1");
    assert_eq!(start.code, None);
    accounts.cancel_login(&start.login_id);
    assert!(accounts.poll_login(&start.login_id).await.is_err());
    assert_eq!(
        std::fs::read_to_string(&zai_credential).unwrap(),
        "existing"
    );

    // Signing out drops a sign-in still waiting on that provider, so it can't
    // write the credential back.
    let start = accounts
        .start_graff_login("zai")
        .await
        .expect("restart zai");
    let rows = accounts.sign_out_graff_login("zai").expect("sign out zai");
    assert!(!rows[2].signed_in);
    assert!(!zai_credential.exists());
    assert!(accounts.poll_login(&start.login_id).await.is_err());

    // Sign out of xAI: gone, and the others are untouched.
    let rows = accounts.sign_out_graff_login("xai").expect("sign out xai");
    assert!(rows.iter().all(|row| !row.signed_in));
    assert!(!home.join(".xai/credentials/graff-oauth.json").exists());

    // Only graff's own providers can be named.
    for other in ["codex", "codegraff", "../xai", ""] {
        assert!(
            accounts.start_graff_login(other).await.is_err(),
            "{other:?}"
        );
        assert!(accounts.sign_out_graff_login(other).is_err(), "{other:?}");
    }
}
