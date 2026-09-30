//! Sign in with ChatGPT (plan usage) for the Codex harness.
//!
//! Opt-in: set `HARNESS_CHATGPT_PLAN=1` and, when the host holds a valid
//! ChatGPT sign-in whose scopes include `chatgpt.tokens.use.direct`, `codex
//! app-server` is started with a Responses provider that authenticates with
//! that OAuth access token instead of Codex's own login. Anything else (flag
//! off, no file, plan usage not granted) leaves the harness exactly as before.
//!
//! The credential record is the one `graff login chatgpt` writes on this host.
//! Tokens are only ever read here, handed to the child through its environment
//! and refreshed in place; they never reach a log, an event or the phone.

use crate::HarnessError;
use crate::process::Command;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const TOKEN_ENDPOINT: &str = "https://auth.openai.com/api/accounts/oauth/token";
const RESOURCE: &str = "https://api.openai.com/v1";
const PLAN_SCOPE: &str = "chatgpt.tokens.use.direct";
/// Renew this long before the hour is up.
const RENEW_WITHIN_SECS: u64 = 300;

/// Serialises refreshes in this process so a rotating refresh token is never
/// spent twice.
static REFRESH: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A usable plan sign-in for one app-server launch.
pub(crate) struct PlanAuth {
    access_token: String,
    /// Bundled model catalog with `tool_search` switched off (see [`catalog`]).
    catalog: Option<PathBuf>,
}

impl PlanAuth {
    /// Point a `codex app-server` command at the ChatGPT-plan provider.
    pub(crate) fn apply(&self, cmd: &mut Command) {
        if let Some(catalog) = &self.catalog
            && let Ok(path) = serde_json::to_string(&catalog.to_string_lossy())
        {
            cmd.arg("-c").arg(format!("model_catalog_json={path}"));
        }
        for setting in [
            "model_provider=\"openai_chatgpt_plan\"",
            "model_providers.openai_chatgpt_plan.name=\"ChatGPT plan\"",
            "model_providers.openai_chatgpt_plan.base_url=\"https://api.openai.com/v1\"",
            "model_providers.openai_chatgpt_plan.env_key=\"ACCESS_TOKEN\"",
            "model_providers.openai_chatgpt_plan.wire_api=\"responses\"",
            "model_providers.openai_chatgpt_plan.requires_openai_auth=false",
            "model_providers.openai_chatgpt_plan.supports_websockets=false",
        ] {
            cmd.arg("-c").arg(setting);
        }
        cmd.env("ACCESS_TOKEN", &self.access_token);
    }
}

pub(crate) fn enabled() -> bool {
    std::env::var("HARNESS_CHATGPT_PLAN")
        .is_ok_and(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "on"))
}

fn credentials_path() -> PathBuf {
    crate::model_context::root(
        "HARNESS_CHATGPT_CREDENTIALS",
        crate::executable::home_or_current_dir().join(".openai/credentials/graff-oauth.json"),
    )
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn read(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

fn str_field<'a>(record: &'a Value, key: &str) -> Option<&'a str> {
    record.get(key)?.as_str().filter(|s| !s.is_empty())
}

fn grants_plan(record: &Value) -> bool {
    record["scopes"]
        .as_array()
        .is_some_and(|s| s.iter().any(|s| s == PLAN_SCOPE))
}

/// The signed-in account's stable id, for keying the model catalog. Reads only.
pub(crate) fn subject() -> Option<String> {
    if !enabled() {
        return None;
    }
    let record = read(&credentials_path())?;
    if !grants_plan(&record) {
        return None;
    }
    str_field(&record, "subject").map(str::to_owned)
}

/// A fresh access token for the plan provider, or `None` to fall back to
/// Codex's own sign-in (flag off, not signed in, or plan usage not granted).
pub(crate) async fn prepare(exe: &Path) -> Result<Option<PlanAuth>, HarnessError> {
    if !enabled() {
        return Ok(None);
    }
    let _guard = REFRESH.lock().await;
    let path = credentials_path();
    let Some(mut record) = read(&path) else {
        tracing::warn!("ChatGPT plan sign-in is on but no sign-in was found on this host");
        return Ok(None);
    };
    if !grants_plan(&record) {
        tracing::warn!("ChatGPT sign-in has no plan usage; using Codex's own sign-in");
        return Ok(None);
    }
    let expires_at = record["expires_at"].as_u64().unwrap_or(0);
    let earliest = record["earliest_refresh_at"].as_u64().unwrap_or(0);
    let t = now();
    if t + RENEW_WITHIN_SECS >= expires_at && (t >= earliest || t >= expires_at) {
        record = refresh(&path, record).await?;
    }
    let Some(token) = str_field(&record, "access_token") else {
        return Ok(None);
    };
    Ok(Some(PlanAuth {
        access_token: token.to_owned(),
        catalog: catalog(exe).await,
    }))
}

/// Plan usage accepts only `web_search` and function/custom tools, and Codex
/// adds its `tool_search` tool per model (`supports_search_tool`), which the
/// API then rejects with `subscription_sharing_unsupported_capability`. There
/// is no global switch, so hand Codex its own bundled catalog with that flag
/// off. Cached per CLI version under `~/.harness/codex-plan`.
async fn catalog(exe: &Path) -> Option<PathBuf> {
    let version = crate::executable::binary_version(exe)
        .map_or_else(|| "unknown".to_owned(), |v| v.to_string());
    let path = crate::executable::home_or_current_dir()
        .join(".harness/codex-plan")
        .join(format!("catalog-{version}.json"));
    if path.is_file() {
        return Some(path);
    }
    let exe = exe.to_owned();
    let target = path.clone();
    let built = tokio::task::spawn_blocking(move || -> Result<(), String> {
        let out = std::process::Command::new(&exe)
            .args(["debug", "models", "--bundled"])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .map_err(|e| e.to_string())?;
        if !out.status.success() {
            return Err(format!("codex debug models exited with {}", out.status));
        }
        let mut catalog: Value = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
        let models = catalog["models"]
            .as_array_mut()
            .ok_or("bundled catalog has no models")?;
        for model in models {
            model["supports_search_tool"] = false.into();
        }
        std::fs::create_dir_all(target.parent().ok_or("no parent")?).map_err(|e| e.to_string())?;
        write_atomic(&target, &catalog).map_err(|e| e.to_string())
    })
    .await;
    match built {
        Ok(Ok(())) => Some(path),
        Ok(Err(error)) => {
            tracing::warn!(%error, "could not build the plan model catalog");
            None
        }
        Err(_) => None,
    }
}

async fn refresh(path: &Path, mut record: Value) -> Result<Value, HarnessError> {
    let (Some(client_id), Some(refresh_token)) = (
        str_field(&record, "client_id"),
        str_field(&record, "refresh_token"),
    ) else {
        return Err(expired());
    };
    let response = reqwest::Client::new()
        .post(TOKEN_ENDPOINT)
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", client_id),
            ("refresh_token", refresh_token),
            ("resource", RESOURCE),
        ])
        .send()
        .await
        .map_err(|e| HarnessError::Protocol(format!("ChatGPT token refresh failed: {e}")))?;
    let status = response.status();
    let body: Value = response
        .bytes()
        .await
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or(Value::Null);
    if !status.is_success() {
        // invalid_grant means the 30-day session is gone; anything else is
        // transient and the old file stays untouched.
        return Err(if body["error"] == "invalid_grant" {
            expired()
        } else {
            HarnessError::Protocol(format!("ChatGPT token refresh failed (HTTP {status})"))
        });
    }
    let Some(access) = body["access_token"].as_str().filter(|s| !s.is_empty()) else {
        return Err(HarnessError::Protocol(
            "ChatGPT token refresh returned no access token".into(),
        ));
    };
    let t = now();
    let expires_in = body["expires_in"].as_u64().unwrap_or(3600);
    record["access_token"] = access.into();
    // The refresh token rotates: the replacement must land with the new access token.
    for key in ["refresh_token", "id_token", "token_type"] {
        if let Some(v) = body[key].as_str().filter(|s| !s.is_empty()) {
            record[key] = v.into();
        }
    }
    if let Some(scope) = body["scope"].as_str().filter(|s| !s.is_empty()) {
        record["scopes"] = scope.split_whitespace().collect::<Vec<_>>().into();
    }
    record["expires_at"] = (t + expires_in).into();
    if let Some(e) = body["earliest_refresh_at"].as_u64() {
        // Absolute epoch seconds, or a delay from now.
        record["earliest_refresh_at"] = (if e > 1_000_000_000 { e } else { t + e }).into();
    }
    write_atomic(path, &record)?;
    Ok(record)
}

fn expired() -> HarnessError {
    HarnessError::Protocol(
        "ChatGPT sign-in expired; run `graff login chatgpt` on this computer".into(),
    )
}

/// Replace the record in one rename, owner-only, so a crash never leaves a
/// half-written file next to a spent refresh token.
fn write_atomic(path: &Path, record: &Value) -> Result<(), HarnessError> {
    use std::io::Write;
    let tmp = path.with_extension("json.tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp)?;
    let bytes = serde_json::to_vec_pretty(record)
        .map_err(|e| HarnessError::Protocol(format!("ChatGPT credential record: {e}")))?;
    file.write_all(&bytes)?;
    file.sync_all()?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_scope_gates_the_provider() {
        let with = serde_json::json!({ "scopes": ["openid", PLAN_SCOPE] });
        let without = serde_json::json!({ "scopes": ["openid", "email"] });
        assert!(grants_plan(&with));
        assert!(!grants_plan(&without));
        assert!(!grants_plan(&Value::Null));
    }

    #[test]
    fn a_record_is_replaced_whole_and_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("oauth.json");
        write_atomic(&path, &serde_json::json!({ "access_token": "a" })).unwrap();
        write_atomic(&path, &serde_json::json!({ "access_token": "b" })).unwrap();
        assert_eq!(read(&path).unwrap()["access_token"], "b");
        assert!(!path.with_extension("json.tmp").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }
}
