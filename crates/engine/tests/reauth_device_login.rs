//! Exercise CLI dispatch, pending approval, host-only credential activation and cancellation.
#![cfg(unix)]

use base64::Engine as _;
use harness_engine::{AgentAccounts, AgentAccountsConfig};
use harness_proto::{AgentLoginMode, AgentLoginStatus};
use std::{path::Path, time::Duration};

fn config(root: &Path) -> AgentAccountsConfig {
    AgentAccountsConfig {
        data_dir: root.join("data"),
        claude_config_dir: root.join("claude"),
        claude_config_file: root.join("claude.json"),
        codex_home: root.join("codex"),
        cursor_sdk_auth_file: root.join("cursor.json"),
        graff_home: root.to_owned(),
    }
}

fn auth(access: &str) -> serde_json::Value {
    let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
        br#"{"email":"fixture@example.invalid","https://api.openai.com/auth":{"chatgpt_account_id":"same-account"}}"#,
    );
    serde_json::json!({"tokens": {
        "id_token": format!("header.{claims}.signature"),
        "access_token": access, "refresh_token": "fixture-refresh"
    }})
}

#[tokio::test]
async fn device_reauth_child() {
    let Ok(scenario) = std::env::var("REAUTH_DEVICE_SCENARIO") else {
        return;
    };
    let root = std::path::PathBuf::from(std::env::var_os("REAUTH_DEVICE_ROOT").unwrap());
    let accounts = AgentAccounts::new(config(&root));
    let live = root.join("codex/auth.json");
    let expired = auth("expired-fixture");
    let renewed = auth("renewed-fixture");
    std::fs::create_dir_all(live.parent().unwrap()).unwrap();
    std::fs::write(&live, expired.to_string()).unwrap();
    std::fs::write(root.join("renewed.json"), renewed.to_string()).unwrap();
    let result = accounts.start_codex_reauth(true).await;
    if scenario == "invalid" {
        let error = result.unwrap_err().to_string();
        assert!(error.contains("Device sign-in did not start"));
        assert!(!error.contains("fixture-private-output"));
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&std::fs::read(&live).unwrap()).unwrap(),
            expired
        );
        return;
    }
    let start = result.unwrap();
    assert_eq!(start.mode, AgentLoginMode::DeviceCode);
    assert!(start.is_safe_device_code());
    assert_eq!(start.code.as_deref(), Some("ABCD-EFGH"));
    assert_eq!(
        accounts.poll_login(&start.login_id).await.unwrap().status,
        AgentLoginStatus::Pending
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&live).unwrap()).unwrap(),
        expired
    );
    if scenario == "cancel" {
        accounts.cancel_login(&start.login_id);
        assert!(accounts.poll_login(&start.login_id).await.is_err());
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&std::fs::read(&live).unwrap()).unwrap(),
            expired
        );
    } else {
        std::fs::write(root.join("approved"), "approved").unwrap();
        let mut done = false;
        for _ in 0..100 {
            if accounts.poll_login(&start.login_id).await.unwrap().status == AgentLoginStatus::Done
            {
                done = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(done, "approved CLI credentials must activate on the host");
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&std::fs::read(&live).unwrap()).unwrap(),
            renewed
        );
    }
    assert!(
        !std::fs::read_dir(root.join("data/agent-accounts"))
            .unwrap()
            .any(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".login-")
            })
    );
}

fn probe(scenario: &str) {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let fake = dir.path().join("fake-codex");
    let script = if scenario == "invalid" {
        "#!/bin/sh\necho 'fixture-private-output'; exit 0\n"
    } else {
        "#!/bin/sh\n[ \"$1\" = login ] && [ \"$2\" = --device-auth ] || exit 7\nprintf '1. Open this link in your browser and sign in to your account\\n  https://auth.openai.com/codex/device\\n2. Enter this one-time code (expires in 15 minutes)\\n  ABCD-EFGH\\n'\nwhile [ ! -f \"$REAUTH_DEVICE_ROOT/approved\" ]; do sleep 0.05; done\ncp \"$REAUTH_DEVICE_ROOT/renewed.json\" \"$CODEX_HOME/auth.json\"\n"
    };
    std::fs::write(&fake, script).unwrap();
    std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "device_reauth_child", "--nocapture"])
        .env("CODEX_EXECUTABLE", &fake)
        .env("REAUTH_DEVICE_ROOT", dir.path())
        .env("REAUTH_DEVICE_SCENARIO", scenario)
        .env("HARNESS_NO_LOGIN_SHELL", "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn phone_approval_activates_only_host_credentials() {
    probe("approve");
}

#[test]
fn cancellation_leaves_existing_login_untouched() {
    probe("cancel");
}

#[test]
fn unsupported_device_cli_fails_without_forwarding_output() {
    probe("invalid");
}
