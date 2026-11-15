//! Cached + forced live usage probes for graff's own provider sign-ins
//! (`chatgpt-new`, `anthropic`, `xai`, and read-only `claude-agent`).

use std::future::Future;
use std::pin::Pin;
use std::time::Instant;

use chrono::{Duration as ChronoDuration, Utc};
use harness_proto::{AgentUsageWindow, GraffLoginProvider};

use crate::agent_accounts::{
    AgentAccounts, CLAUDE_PROFILE_URL, CLAUDE_USAGE_URL, CODEX_USAGE_URL, USAGE_TTL, UsageSnapshot,
    claude_endpoint, claude_plan, claude_usage_windows, codex_plan, codex_window_label, jwt_claims,
    lock, parse_when, read_json, str_field,
};
use crate::graff_logins;

const OPENAI_CODEX_USAGE_URL: &str = "https://api.openai.com/api/codex/usage";
const XAI_BILLING_URL: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";

#[cfg(test)]
thread_local! {
    static ENDPOINT_OVERRIDE: std::cell::RefCell<Option<String>> =
        const { std::cell::RefCell::new(None) };
}

fn endpoint(url: &'static str) -> String {
    #[cfg(test)]
    if let Some(base) = ENDPOINT_OVERRIDE.with(|b| b.borrow().clone()) {
        let path = url.splitn(4, '/').nth(3).unwrap_or_default();
        return format!("{base}/{path}");
    }
    url.to_string()
}

pub(crate) async fn list_with_usage(
    accounts: &AgentAccounts,
    force_usage: bool,
) -> Vec<GraffLoginProvider> {
    let home = accounts.config().graff_home.clone();
    let claude_cfg = accounts.config().claude_config_file.clone();
    let mut rows = graff_logins::list_with_claude_config(&home, Some(&claude_cfg));

    type ProbeFut<'a> =
        Pin<Box<dyn Future<Output = (usize, String, Option<UsageSnapshot>)> + Send + 'a>>;
    let mut probes: Vec<ProbeFut<'_>> = Vec::new();

    for (idx, row) in rows.iter_mut().enumerate() {
        if !row.signed_in {
            continue;
        }
        if row.id == "claude-agent" {
            if let Some(snap) = accounts.cached_claude_usage(row.account.as_deref()) {
                apply_snapshot(row, snap);
            }
            continue;
        }
        if !matches!(row.id.as_str(), "chatgpt-new" | "anthropic" | "xai") {
            continue;
        }
        let cache_key = format!(
            "graff:{}:{}",
            row.id,
            row.account.as_deref().unwrap_or("default")
        );
        if let Some((cached, at)) = lock(accounts.usage_cache()).get(&cache_key)
            && at.elapsed() < USAGE_TTL
        {
            if let Some(snap) = cached.clone() {
                apply_snapshot(row, snap);
            }
            continue;
        }
        if !force_usage {
            continue;
        }
        let id = row.id.clone();
        let need_profile = row.account.is_none() || row.plan_label.is_none();
        probes.push(Box::pin(async move {
            let snap = match id.as_str() {
                "chatgpt-new" => probe_chatgpt_new(accounts).await,
                "anthropic" => probe_anthropic(accounts, need_profile).await,
                "xai" => probe_xai(accounts).await,
                _ => None,
            };
            (idx, cache_key, snap)
        }));
    }

    if !probes.is_empty() {
        let results = futures::future::join_all(probes).await;
        for (idx, key, snap) in results {
            lock(accounts.usage_cache()).insert(key, (snap.clone(), Instant::now()));
            if let Some(s) = snap {
                apply_snapshot(&mut rows[idx], s);
            }
        }
    }

    rows
}

fn apply_snapshot(row: &mut GraffLoginProvider, snap: UsageSnapshot) {
    if !snap.windows.is_empty() {
        row.usage_windows = snap.windows;
    }
    if let Some(plan) = snap.plan_label {
        row.plan_label = Some(plan);
    }
    if snap.prepaid_cents.is_some() {
        row.prepaid_cents = snap.prepaid_cents;
    }
    if snap.reset_credits.is_some() {
        row.reset_credits = snap.reset_credits;
    }
    if row.account.is_none() {
        row.account = snap.account;
    }
    if row.display_name.is_none() {
        row.display_name = snap.display_name;
    }
    if row.organization.is_none() {
        row.organization = snap.organization;
    }
}

async fn probe_chatgpt_new(accounts: &AgentAccounts) -> Option<UsageSnapshot> {
    let path = graff_logins::credential_path(&accounts.config().graff_home, "chatgpt-new")?;
    let json = read_json(&path)?;
    let access_token = str_field(&json, "access_token")?;
    let acct_id = chatgpt_account_id(&json, &access_token);

    let mut body = fetch_codex_json(
        accounts.http(),
        &endpoint(OPENAI_CODEX_USAGE_URL),
        &access_token,
        acct_id.as_deref(),
    )
    .await;
    if body.is_none() {
        body = fetch_codex_json(
            accounts.http(),
            &endpoint(CODEX_USAGE_URL),
            &access_token,
            acct_id.as_deref(),
        )
        .await;
    }
    parse_codex_usage_body(&body?)
}

fn chatgpt_account_id(json: &serde_json::Value, access_token: &str) -> Option<String> {
    for raw in [str_field(json, "id_token"), Some(access_token.to_string())]
        .into_iter()
        .flatten()
    {
        if let Some(claims) = jwt_claims(&raw)
            && let Some(id) = claims
                .get("https://api.openai.com/auth")
                .and_then(|oa| str_field(oa, "chatgpt_account_id"))
        {
            return Some(id);
        }
    }
    str_field(json, "account_id")
}

async fn fetch_codex_json(
    http: &reqwest::Client,
    url: &str,
    access_token: &str,
    acct_id: Option<&str>,
) -> Option<serde_json::Value> {
    let mut req = http.get(url).bearer_auth(access_token);
    if let Some(id) = acct_id {
        req = req.header("chatgpt-account-id", id);
    }
    req.send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()
}

pub(crate) fn parse_codex_usage_body(body: &serde_json::Value) -> Option<UsageSnapshot> {
    let mut windows = Vec::new();
    if let Some(rl) = body.get("rate_limit") {
        for key in ["primary_window", "secondary_window"] {
            if let Some(w) = rl.get(key)
                && let Some(used) = w.get("used_percent").and_then(json_f64)
            {
                let span = w
                    .get("limit_window_seconds")
                    .and_then(json_i64)
                    .unwrap_or(0);
                let resets_at = parse_when(w.get("reset_at")).or_else(|| {
                    w.get("reset_after_seconds")
                        .and_then(json_i64)
                        .map(|s| Utc::now() + ChronoDuration::seconds(s.max(0)))
                });
                windows.push(AgentUsageWindow {
                    label: codex_window_label(span).to_string(),
                    used_fraction: (used.clamp(0.0, 100.0) / 100.0) as f32,
                    resets_at,
                });
            }
        }
    }
    let plan_label = codex_plan(str_field(body, "plan_type").as_deref());
    let reset_credits = body
        .pointer("/rate_limit_reset_credits/available_count")
        .and_then(json_f64)
        .or_else(|| body.pointer("/credits/balance").and_then(json_f64));
    (!windows.is_empty() || plan_label.is_some() || reset_credits.is_some()).then_some(
        UsageSnapshot {
            windows,
            plan_label,
            reset_credits,
            ..Default::default()
        },
    )
}

async fn probe_anthropic(accounts: &AgentAccounts, need_profile: bool) -> Option<UsageSnapshot> {
    let path = graff_logins::existing_credential_path(&accounts.config().graff_home, "anthropic")?;
    let json = read_json(&path)?;
    let access_token = str_field(&json, "access_token")?;

    let usage_url = if cfg!(test) {
        let override_url = endpoint(CLAUDE_USAGE_URL);
        if override_url == CLAUDE_USAGE_URL {
            claude_endpoint(CLAUDE_USAGE_URL)
        } else {
            override_url
        }
    } else {
        CLAUDE_USAGE_URL.to_string()
    };

    let mut snap = match accounts
        .http()
        .get(&usage_url)
        .bearer_auth(&access_token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .send()
        .await
    {
        Ok(res) if res.status().is_success() => res
            .json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|body| claude_usage_windows(&body))
            .unwrap_or_default(),
        _ => UsageSnapshot::default(),
    };

    if need_profile {
        let profile_url = if cfg!(test) {
            endpoint(CLAUDE_PROFILE_URL)
        } else {
            CLAUDE_PROFILE_URL.to_string()
        };
        if let Ok(res) = accounts
            .http()
            .get(&profile_url)
            .bearer_auth(&access_token)
            .header("anthropic-beta", "oauth-2025-04-20")
            .send()
            .await
            && res.status().is_success()
            && let Ok(pbody) = res.json::<serde_json::Value>().await
        {
            merge_anthropic_profile(&mut snap, &pbody);
        }
    }

    (!snap.windows.is_empty()
        || snap.account.is_some()
        || snap.display_name.is_some()
        || snap.organization.is_some()
        || snap.plan_label.is_some())
    .then_some(snap)
}

fn merge_anthropic_profile(snap: &mut UsageSnapshot, body: &serde_json::Value) {
    let acct = body.get("account");
    let org = body.get("organization");
    snap.account = acct
        .and_then(|a| str_field(a, "email").or_else(|| str_field(a, "email_address")))
        .or_else(|| str_field(body, "email"));
    snap.display_name = acct.and_then(|a| {
        str_field(a, "display_name")
            .or_else(|| str_field(a, "full_name"))
            .or_else(|| str_field(a, "name"))
    });
    snap.organization = org.and_then(|o| str_field(o, "name"));

    let org_type = org.and_then(|o| str_field(o, "organization_type"));
    let rate_tier = org.and_then(|o| str_field(o, "rate_limit_tier"));
    let has_max = acct
        .and_then(|a| a.get("has_claude_max"))
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    let has_pro = acct
        .and_then(|a| a.get("has_claude_pro"))
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);

    snap.plan_label = claude_plan(org_type.as_deref(), rate_tier.as_deref())
        .map(|p| format!("Claude {p}"))
        .or_else(|| has_max.then(|| "Claude Max".to_string()))
        .or_else(|| has_pro.then(|| "Claude Pro".to_string()));
}

async fn probe_xai(accounts: &AgentAccounts) -> Option<UsageSnapshot> {
    let path = graff_logins::existing_credential_path(&accounts.config().graff_home, "xai")?;
    let json = read_json(&path)?;
    let access_token = str_field(&json, "access_token")?;
    let body: serde_json::Value = accounts
        .http()
        .get(endpoint(XAI_BILLING_URL))
        .bearer_auth(&access_token)
        .header("X-XAI-Token-Auth", "xai-grok-cli")
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()?;
    parse_grok_billing(&body)
}

pub(crate) fn format_grok_tier(raw: &str) -> Option<String> {
    if raw.is_empty() {
        return None;
    }
    for (pattern, label) in [
        ("SUBSCRIPTION_TIER_SUPER_GROK", "SuperGrok"),
        ("SuperGrok", "SuperGrok"),
        ("SUBSCRIPTION_TIER_SUPER_GROK_HEAVY", "SuperGrok Heavy"),
        ("SuperGrokHeavy", "SuperGrok Heavy"),
        ("SUBSCRIPTION_TIER_GROK_PRO", "Grok Pro"),
        ("GrokPro", "Grok Pro"),
    ] {
        if raw.eq_ignore_ascii_case(pattern) {
            return Some((*label).into());
        }
    }
    let stem = raw.strip_prefix("SUBSCRIPTION_TIER_").unwrap_or(raw);
    let words: Vec<String> = stem
        .split('_')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut chars = w.chars();
            match chars.next() {
                Some(first) => {
                    format!("{}{}", first.to_uppercase(), chars.as_str().to_lowercase())
                }
                None => String::new(),
            }
        })
        .collect();
    (!words.is_empty()).then(|| words.join(" "))
}

pub(crate) fn parse_grok_billing(body: &serde_json::Value) -> Option<UsageSnapshot> {
    let plan_label = str_field(body, "subscriptionTier").and_then(|t| format_grok_tier(&t));
    let prepaid_cents = body
        .get("prepaidBalance")
        .and_then(|pb| pb.get("val"))
        .and_then(json_i64);

    let mut windows = Vec::new();
    let mut reset_credits = None;

    if let Some(items) = body.get("productUsage").and_then(|v| v.as_array()) {
        let target = items
            .iter()
            .find(|item| {
                matches!(
                    str_field(item, "product").as_deref(),
                    Some("PRODUCT_GROK_BUILD" | "GrokBuild")
                )
            })
            .or_else(|| (items.len() == 1).then_some(&items[0]));
        if let Some(item) = target
            && let Some(pct) = item.get("creditUsagePercent").and_then(json_f64)
        {
            let cp = item.get("currentPeriod");
            let label = match cp.and_then(|c| str_field(c, "period")).as_deref() {
                Some(p) if p.eq_ignore_ascii_case("daily") => "Daily",
                Some(p) if p.eq_ignore_ascii_case("weekly") => "Week",
                Some(p) if p.eq_ignore_ascii_case("monthly") => "Month",
                _ => "Credits",
            };
            windows.push(AgentUsageWindow {
                label: label.to_string(),
                used_fraction: (pct.clamp(0.0, 100.0) / 100.0) as f32,
                resets_at: cp.and_then(|c| parse_when(c.get("end"))),
            });
        }
    }

    if windows.is_empty()
        && let Some(mpc) = body.get("monthlyPlanCredits")
        && let Some(prod) = mpc
            .get("PRODUCT_GROK_BUILD")
            .or_else(|| mpc.get("GrokBuild"))
        && let Some(total) = prod.get("total").and_then(json_f64)
        && total > 0.0
    {
        let remaining = prod.get("remaining").and_then(json_f64).unwrap_or(total);
        let used = (total - remaining).clamp(0.0, total);
        reset_credits = Some(total);
        windows.push(AgentUsageWindow {
            label: "Credits".to_string(),
            used_fraction: (used / total) as f32,
            resets_at: parse_when(prod.get("nextResetDate")),
        });
    }

    (!windows.is_empty()
        || plan_label.is_some()
        || prepaid_cents.is_some()
        || reset_credits.is_some())
    .then_some(UsageSnapshot {
        windows,
        plan_label,
        prepaid_cents,
        reset_credits,
        ..Default::default()
    })
}

fn json_f64(value: &serde_json::Value) -> Option<f64> {
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|s| s.parse::<f64>().ok()))
}

fn json_i64(value: &serde_json::Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|s| s.parse::<i64>().ok()))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;
    use crate::agent_accounts::AgentAccountsConfig;
    use crate::graff_logins::{CHATGPT_PLAN_SCOPE, credential_path};

    fn test_config(home: &std::path::Path) -> AgentAccountsConfig {
        AgentAccountsConfig {
            data_dir: home.join("data"),
            claude_config_dir: home.join("claude"),
            claude_config_file: home.join("claude.json"),
            codex_home: home.join("codex"),
            cursor_sdk_auth_file: home.join("cursor.json"),
            graff_home: home.to_path_buf(),
        }
    }

    async fn mock_usage_server() -> (String, Arc<AtomicUsize>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let hits = Arc::new(AtomicUsize::new(0));
        let counted = hits.clone();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let (mut req, mut buf) = (Vec::new(), [0u8; 4096]);
                while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                    match stream.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => req.extend_from_slice(&buf[..n]),
                    }
                }
                let line = String::from_utf8_lossy(
                    req.split(|b| *b == b'\r' || *b == b'\n')
                        .next()
                        .unwrap_or_default(),
                );
                let path = line.split_whitespace().nth(1).unwrap_or("");
                counted.fetch_add(1, Ordering::SeqCst);
                let body = if path == "/api/codex/usage" {
                    r#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":28,"limit_window_seconds":18000,"reset_at":"2027-01-14T15:45:00Z"},"secondary_window":{"used_percent":62,"limit_window_seconds":604800,"reset_at":"2027-01-20T09:00:00Z"}},"credits":{"balance":12.5}}"#
                } else if path == "/api/oauth/usage" {
                    r#"{"five_hour":{"utilization":18.0,"resets_at":"2027-01-14T15:45:00Z"},"seven_day":{"utilization":54.0,"resets_at":"2027-01-20T09:00:00Z"},"fable":{"utilization":85.0,"resets_at":"2027-01-20T09:00:00Z"}}"#
                } else if path == "/api/oauth/profile" {
                    r#"{"account":{"email":"ops@acme.test","display_name":"Ops User","has_claude_max":true},"organization":{"name":"Acme Labs","organization_type":"claude_max"}}"#
                } else if path.starts_with("/v1/billing") {
                    r#"{"subscriptionTier":"SUBSCRIPTION_TIER_GROK_PRO","prepaidBalance":{"val":"1542"},"productUsage":[{"product":"PRODUCT_GROK_BUILD","creditUsagePercent":22.5,"currentPeriod":{"period":"weekly","end":"2027-02-03T02:40:00Z"}}]}"#
                } else {
                    ""
                };
                let reply = if body.is_empty() {
                    "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                        .to_string()
                } else {
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    )
                };
                let _ = stream.write_all(reply.as_bytes()).await;
            }
        });
        (base, hits)
    }

    fn write_json(path: std::path::PathBuf, val: serde_json::Value) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, val.to_string()).unwrap();
    }

    #[tokio::test]
    async fn probes_chatgpt_anthropic_and_xai_and_caches_for_non_forced_reads() {
        let (base, hits) = mock_usage_server().await;
        ENDPOINT_OVERRIDE.with(|url| *url.borrow_mut() = Some(base));
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();

        write_json(
            credential_path(home, "chatgpt-new").unwrap(),
            serde_json::json!({"email":"ada@example.test","access_token":"cg-tok","scopes":[CHATGPT_PLAN_SCOPE]}),
        );
        write_json(
            home.join(".anthropic/credentials/graff-oauth.json"),
            serde_json::json!({"access_token":"ant-tok"}),
        );
        write_json(
            credential_path(home, "xai").unwrap(),
            serde_json::json!({"email":"ada@example.test","access_token":"xai-tok"}),
        );

        let accounts = AgentAccounts::new(test_config(home));
        let offline = list_with_usage(&accounts, false).await;
        assert_eq!(hits.load(Ordering::SeqCst), 0);
        assert!(
            offline
                .iter()
                .find(|r| r.id == "xai")
                .unwrap()
                .usage_windows
                .is_empty()
        );

        let forced = list_with_usage(&accounts, true).await;
        let first_hits = hits.load(Ordering::SeqCst);
        assert_eq!(first_hits, 4);

        let cg_row = forced.iter().find(|r| r.id == "chatgpt-new").unwrap();
        assert_eq!(cg_row.plan_label.as_deref(), Some("ChatGPT Plus"));
        assert_eq!(cg_row.reset_credits, Some(12.5));
        assert_eq!(cg_row.usage_windows.len(), 2);
        assert_eq!(cg_row.usage_windows[0].label, "Session");

        let ant_row = forced.iter().find(|r| r.id == "anthropic").unwrap();
        assert_eq!(ant_row.account.as_deref(), Some("ops@acme.test"));
        assert_eq!(ant_row.organization.as_deref(), Some("Acme Labs"));
        assert_eq!(ant_row.plan_label.as_deref(), Some("Claude Max"));
        assert_eq!(ant_row.usage_windows.len(), 3);
        assert_eq!(ant_row.usage_windows[2].label, "Fable");

        let xai_row = forced.iter().find(|r| r.id == "xai").unwrap();
        assert_eq!(xai_row.plan_label.as_deref(), Some("Grok Pro"));
        assert_eq!(xai_row.prepaid_cents, Some(1542));
        assert_eq!(xai_row.usage_windows.len(), 1);
        assert_eq!(xai_row.usage_windows[0].label, "Week");

        let cached = list_with_usage(&accounts, false).await;
        assert_eq!(hits.load(Ordering::SeqCst), first_hits);
        assert_eq!(
            cached.iter().find(|r| r.id == "xai").unwrap().prepaid_cents,
            Some(1542)
        );
    }

    #[test]
    fn parses_xai_monthly_plan_credits_fallback() {
        let body = serde_json::json!({
            "subscriptionTier": "SUBSCRIPTION_TIER_SUPER_GROK_HEAVY",
            "prepaidBalance": { "val": 1250 },
            "monthlyPlanCredits": {
                "PRODUCT_GROK_BUILD": { "total": 50.0, "remaining": 32.5, "nextResetDate": "2027-02-01T00:00:00Z" }
            }
        });
        let snap = parse_grok_billing(&body).unwrap();
        assert_eq!(snap.plan_label.as_deref(), Some("SuperGrok Heavy"));
        assert_eq!(snap.prepaid_cents, Some(1250));
        assert_eq!(snap.reset_credits, Some(50.0));
        assert_eq!(snap.windows.len(), 1);
        assert_eq!(snap.windows[0].label, "Credits");
        assert!((snap.windows[0].used_fraction - 0.35).abs() < 1e-5);
    }
}
