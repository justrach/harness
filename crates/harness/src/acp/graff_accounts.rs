//! Codegraff's `graff/accounts` ACP extension, terminal `authMethods`, and
//! `_codegraff/usage.planWindows` rate-limit snapshots.

use std::time::Duration;

use harness_proto::{AgentEvent, AgentUsageWindow, HarnessId};
use serde_json::{Value, json};

use super::{AcpHarness, initialize_params, request_draining};
use crate::HarnessError;
use crate::jsonrpc::RpcClient;

/// Terminal login method ids advertised by `graff acp` during `initialize`.
pub const GRAFF_AUTH_METHOD_IDS: &[&str] = &[
    "graff-login",
    "graff-login-anthropic",
    "graff-login-claude-agent",
    "graff-login-chatgpt-new",
    "graff-login-codex",
    "graff-login-xai",
    "graff-login-kimi",
];

/// Parsed `graff/accounts` response from a live `graff acp` server.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GraffAccountsSnapshot {
    pub active_provider: Option<String>,
    pub accounts: Vec<GraffAccountStatus>,
}

/// One redacted provider entry returned by `graff/accounts`.
#[derive(Debug, Clone, PartialEq)]
pub struct GraffAccountStatus {
    pub provider: String,
    pub authenticated: bool,
    pub auth_kind: Option<String>,
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub organization: Option<String>,
    pub plan: Option<String>,
    pub prepaid_cents: Option<i64>,
    pub reset_credits: Option<f64>,
    pub note: Option<String>,
    pub windows: Vec<AgentUsageWindow>,
}

/// Return true if `initialize` advertised `codegraff/accounts` support.
pub fn supports_graff_accounts(initialized: &Value) -> bool {
    initialized
        .pointer("/_meta/codegraff~1accounts")
        .and_then(Value::as_bool)
        == Some(true)
        || initialized
            .pointer("/agentCapabilities/_meta/codegraff~1accounts")
            .and_then(Value::as_bool)
            == Some(true)
}

/// Extract advertised `authMethods` ids from an ACP `initialize` response,
/// keeping `graff-login*` terminal entries and any unknown future ids.
pub fn graff_auth_methods(initialized: &Value) -> Vec<String> {
    let mut ids = Vec::new();
    for entry in initialized
        .get("authMethods")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(id) = entry.get("id").and_then(Value::as_str) else {
            continue;
        };
        if !id.is_empty() && !ids.iter().any(|existing| existing == id) {
            ids.push(id.to_owned());
        }
    }
    ids
}

fn non_empty_str(obj: &Value, key: &str) -> Option<String> {
    obj.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn parse_window_value(row: &Value) -> Option<AgentUsageWindow> {
    let label = non_empty_str(row, "label")?;
    let used_percent = row.get("usedPercent").and_then(Value::as_f64).or_else(|| {
        row.get("remainingPercent")
            .and_then(Value::as_f64)
            .map(|rem| 100.0 - rem)
    })?;
    let resets_at_unix = row.get("resetsAtUnix").and_then(Value::as_i64);
    let reset_after_seconds = row.get("resetAfterSeconds").and_then(Value::as_i64);
    Some(AgentUsageWindow::from_percent_and_unix(
        label,
        used_percent,
        resets_at_unix,
        reset_after_seconds,
    ))
}

/// Parse a `graff/accounts` JSON-RPC result into a [`GraffAccountsSnapshot`].
pub fn parse_graff_accounts(value: &Value) -> Result<GraffAccountsSnapshot, HarnessError> {
    let rows = value
        .get("accounts")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            HarnessError::Protocol("graff/accounts omitted its accounts array".into())
        })?;
    let active_provider = non_empty_str(value, "activeProvider");
    let mut accounts = Vec::with_capacity(rows.len());
    for row in rows {
        let Some(provider) = non_empty_str(row, "provider") else {
            continue;
        };
        let windows = row
            .get("windows")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(parse_window_value)
            .collect();
        accounts.push(GraffAccountStatus {
            provider,
            authenticated: row
                .get("authenticated")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            auth_kind: non_empty_str(row, "authKind"),
            email: non_empty_str(row, "email"),
            display_name: non_empty_str(row, "displayName"),
            organization: non_empty_str(row, "organization"),
            plan: non_empty_str(row, "plan"),
            prepaid_cents: row.get("prepaidCents").and_then(Value::as_i64),
            reset_credits: row.get("resetCredits").and_then(Value::as_f64),
            note: non_empty_str(row, "note"),
            windows,
        });
    }
    Ok(GraffAccountsSnapshot {
        active_provider,
        accounts,
    })
}

/// Query signed-in accounts and usage windows from a `graff acp` child.
pub async fn discover_accounts(
    harness: &AcpHarness,
    probe: bool,
    timeout: Duration,
) -> Result<GraffAccountsSnapshot, HarnessError> {
    let cwd = crate::scratch::ScratchDir::new("graff-account-discovery")?;
    let (_scratch, mut child, _stderr) = harness
        .spawn_agent(cwd.path().to_str(), false, &[], None)
        .await?;
    let (client, mut incoming) = match (child.stdin.take(), child.stdout.take()) {
        (Some(stdin), Some(stdout)) => RpcClient::new(stdin, stdout),
        _ => {
            child.shutdown(harness.kill_grace).await;
            return Err(HarnessError::Protocol(
                "graff account discovery has no stdio".into(),
            ));
        }
    };
    let result = tokio::time::timeout(timeout, async {
        let init = request_draining(
            &client,
            &mut incoming,
            "initialize",
            initialize_params(HarnessId::Graff),
        )
        .await?;
        if !supports_graff_accounts(&init) {
            return Err(HarnessError::Protocol(
                "graff/accounts capability is not advertised by this graff build".into(),
            ));
        }
        let reply = request_draining(
            &client,
            &mut incoming,
            "graff/accounts",
            json!({ "probe": probe }),
        )
        .await?;
        parse_graff_accounts(&reply)
    })
    .await;
    child.shutdown(harness.kill_grace).await;
    result.map_err(|_| HarnessError::Protocol("graff account discovery timed out".into()))?
}

/// Parse `_codegraff/usage` notification `params.usage.planWindows` into
/// [`AgentUsageWindow`] records.
pub fn parse_codegraff_usage_windows(params: &Value) -> Vec<AgentUsageWindow> {
    params
        .get("usage")
        .and_then(|u| u.get("planWindows"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(parse_window_value)
        .collect()
}

pub(super) fn usage_events(params: &Value) -> Vec<AgentEvent> {
    let windows = parse_codegraff_usage_windows(params);
    if windows.is_empty() {
        return Vec::new();
    }
    let provider = params
        .get("usage")
        .and_then(|u| non_empty_str(u, "provider"))
        .or_else(|| non_empty_str(params, "provider"));
    vec![AgentEvent::PlanUsage { provider, windows }]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_accounts_capability_and_auth_methods() {
        let init = json!({
            "protocolVersion": 1,
            "authMethods": [
                {"id": "graff-login"},
                {"id": "graff-login-anthropic"},
                {"id": "graff-login-claude-agent"},
                {"id": "graff-login-chatgpt-new"},
                {"id": "graff-login-codex"},
                {"id": "graff-login-xai"},
                {"id": "graff-login-kimi"}
            ],
            "_meta": {"codegraff/accounts": true}
        });
        assert!(supports_graff_accounts(&init));
        let methods = graff_auth_methods(&init);
        for id in GRAFF_AUTH_METHOD_IDS {
            assert!(methods.iter().any(|m| m == id), "missing {id}");
        }
        assert!(!supports_graff_accounts(&json!({"protocolVersion": 1})));
    }

    #[test]
    fn parses_graff_accounts_and_codegraff_plan_windows() {
        let reply = json!({
            "activeProvider": "anthropic",
            "accounts": [
                {
                    "provider": "anthropic",
                    "authenticated": true,
                    "authKind": "oauth",
                    "email": "ada@example.test",
                    "displayName": "Ada Lovelace",
                    "organization": "Acme Labs",
                    "plan": "Claude Max 20x",
                    "windows": [
                        {"label": "Session", "usedPercent": 24.0, "resetsAtUnix": 1_800_000_000},
                        {"label": "Fable", "remainingPercent": 15.0, "resetAfterSeconds": 7200}
                    ]
                },
                {
                    "provider": "xai",
                    "authenticated": true,
                    "authKind": "oauth",
                    "email": "ada@example.test",
                    "plan": "SuperGrok Heavy",
                    "prepaidCents": 1250,
                    "resetCredits": 50.0
                }
            ]
        });
        let snap = parse_graff_accounts(&reply).unwrap();
        assert_eq!(snap.active_provider.as_deref(), Some("anthropic"));
        assert_eq!(snap.accounts.len(), 2);
        assert_eq!(snap.accounts[0].organization.as_deref(), Some("Acme Labs"));
        assert_eq!(snap.accounts[0].windows.len(), 2);
        assert_eq!(snap.accounts[0].windows[0].label, "Session");
        assert!((snap.accounts[0].windows[0].used_fraction - 0.24).abs() < 1e-4);
        assert_eq!(snap.accounts[0].windows[1].label, "Fable");
        assert!((snap.accounts[0].windows[1].used_fraction - 0.85).abs() < 1e-4);
        assert_eq!(snap.accounts[1].prepaid_cents, Some(1250));

        let usage_notif = json!({
            "sessionId": "s1",
            "usage": {
                "provider": "codex",
                "planWindows": [
                    {"label": "Session", "usedPercent": 35.0, "remainingPercent": 65.0, "resetsAtUnix": 1_800_001_200}
                ]
            }
        });
        let events = usage_events(&usage_notif);
        assert_eq!(events.len(), 1);
        match &events[0] {
            AgentEvent::PlanUsage { provider, windows } => {
                assert_eq!(provider.as_deref(), Some("codex"));
                assert_eq!(windows.len(), 1);
                assert_eq!(windows[0].label, "Session");
                assert!((windows[0].used_fraction - 0.35).abs() < 1e-4);
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }
}
