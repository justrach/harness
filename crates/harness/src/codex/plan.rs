//! Harness's own "Sign in with ChatGPT" plan usage for the Codex harness.
//!
//! Harness signs in itself ([`super::chatgpt_signin`]) and keeps the result in
//! its own credential store under `~/.harness/chatgpt`; it never reads another
//! app's login. In a beta build (or with `HARNESS_CHATGPT_PLAN=1`) and with a
//! stored sign-in whose scopes include `chatgpt.tokens.use.direct`, `codex
//! app-server` is started with a Responses provider that authenticates with
//! that OAuth access token instead of Codex's own login, and asks OpenAI for
//! the account's model list. Anything else (stable build, not signed in, plan
//! usage not granted) leaves the harness exactly as before.
//!
//! Tokens are only ever read here, handed to the child through its environment
//! and refreshed in place; they never reach a log, an event or the phone.

use crate::HarnessError;
use crate::process::Command;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) const TOKEN_ENDPOINT: &str = "https://auth.openai.com/api/accounts/oauth/token";
pub(crate) const RESOURCE: &str = "https://api.openai.com/v1";
pub(crate) const PLAN_SCOPE: &str = "chatgpt.tokens.use.direct";
/// Renew this long before the hour is up.
const RENEW_WITHIN_SECS: u64 = 300;

/// A usable plan sign-in for one app-server launch.
pub(crate) struct PlanAuth {
    access_token: String,
}

impl PlanAuth {
    /// Point a `codex app-server` command at the ChatGPT-plan provider. Codex
    /// fetches the account's own model list from `/v1/models`, so no catalog
    /// is shipped from here.
    pub(crate) fn apply(&self, cmd: &mut Command) {
        for setting in [
            "model_provider=\"openai_token_sharing\"",
            "model_providers.openai_token_sharing.name=\"OpenAI Token Sharing\"",
            "model_providers.openai_token_sharing.base_url=\"https://api.openai.com/v1\"",
            "model_providers.openai_token_sharing.model_catalog_url=\"https://api.openai.com/v1/models\"",
            "features.api_key_model_discovery=true",
            "model_providers.openai_token_sharing.env_key=\"ACCESS_TOKEN\"",
            "model_providers.openai_token_sharing.wire_api=\"responses\"",
            "model_providers.openai_token_sharing.requires_openai_auth=false",
            "model_providers.openai_token_sharing.supports_websockets=false",
        ] {
            cmd.arg("-c").arg(setting);
        }
        cmd.env("ACCESS_TOKEN", &self.access_token);
        // Ambient overrides must not redirect the token to another provider.
        cmd.env_remove("OPENAI_API_KEY")
            .env_remove("OPENAI_BASE_URL");
    }
}

/// Whether Codex runs on the ChatGPT plan when a plan sign-in exists. Beta
/// builds (the staging channel) have it on and stable builds keep it off until
/// it is promoted; `HARNESS_CHATGPT_PLAN` (`1`/`on` or `0`/`off`) overrides
/// either. With no sign-in stored it never changes anything.
pub(crate) fn enabled() -> bool {
    enabled_for(
        std::env::var("HARNESS_CHATGPT_PLAN").ok().as_deref(),
        env!("CARGO_PKG_VERSION"),
    )
}

/// Whether this build runs Codex on a stored ChatGPT plan sign-in (see [`enabled`]).
pub fn plan_usage_enabled() -> bool {
    enabled()
}

fn enabled_for(flag: Option<&str>, version: &str) -> bool {
    match flag.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("1" | "true" | "on") => true,
        Some("0" | "false" | "off") => false,
        _ => version.contains("-beta"),
    }
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

pub(crate) fn store_dir() -> PathBuf {
    crate::model_context::root(
        "HARNESS_CHATGPT_HOME",
        crate::executable::home_or_current_dir().join(".harness/chatgpt"),
    )
}

fn credentials_path() -> PathBuf {
    store_dir().join("credentials.json")
}

fn registration_path() -> PathBuf {
    store_dir().join("registration.json")
}

pub(crate) fn now() -> u64 {
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

pub(crate) fn grants_plan(record: &Value) -> bool {
    record["scopes"]
        .as_array()
        .is_some_and(|s| s.iter().any(|s| s == PLAN_SCOPE))
}

/// This host's stable, opaque `ext_agent_host_id`, created once. Not a secret.
pub(crate) fn host_id() -> Result<String, HarnessError> {
    let path = store_dir().join("host-id");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim();
        if existing.starts_with("urn:uuid:") {
            return Ok(existing.to_owned());
        }
    }
    let id = format!("urn:uuid:{}", uuid::Uuid::new_v4());
    std::fs::create_dir_all(store_dir())?;
    write_atomic(&path, id.as_bytes())?;
    Ok(id)
}

/// The account registration kept across sign-outs, so signing in again reuses
/// the issued client instead of registering another.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Registration {
    pub client_id: String,
    pub subject: String,
    pub email: Option<String>,
}

pub(crate) fn read_registration() -> Option<Registration> {
    let record = read(&registration_path())?;
    Some(Registration {
        client_id: str_field(&record, "client_id")?.to_owned(),
        subject: str_field(&record, "subject")?.to_owned(),
        email: str_field(&record, "email").map(str::to_owned),
    })
}

pub(crate) async fn save_registration(registration: &Registration) -> Result<(), HarnessError> {
    let _lock = lock().await?;
    let record = serde_json::json!({
        "client_id": registration.client_id,
        "subject": registration.subject,
        "email": registration.email,
    });
    write_json(&registration_path(), &record)
}

pub(crate) fn read_credentials() -> Option<Value> {
    read(&credentials_path())
}

/// Replace the credential record whole (tokens, expiry and scopes together).
pub(crate) async fn save_credentials(record: &Value) -> Result<(), HarnessError> {
    let _lock = lock().await?;
    write_json(&credentials_path(), record)
}

/// What the app shows for the ChatGPT plan connection. Reads only.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Status {
    pub signed_in: bool,
    pub plan_usage: bool,
    /// This computer has signed in before (the registration outlives a sign-out),
    /// so a sign-in now is not the first one.
    pub registered: bool,
    /// This build runs Codex on the plan when signed in (beta builds, or the
    /// `HARNESS_CHATGPT_PLAN` switch); stable builds keep the feature out of sight.
    pub enabled: bool,
    pub email: Option<String>,
}

pub fn status() -> Status {
    let registered = read_registration().is_some();
    let enabled = enabled();
    let Some(record) = read_credentials() else {
        return Status {
            registered,
            enabled,
            ..Status::default()
        };
    };
    Status {
        signed_in: str_field(&record, "refresh_token").is_some()
            || str_field(&record, "access_token").is_some(),
        plan_usage: grants_plan(&record),
        registered,
        enabled,
        email: str_field(&record, "email").map(str::to_owned),
    }
}

/// The signed-in account's stable id, for keying the model catalog. Reads only.
pub(crate) fn subject() -> Option<String> {
    if !enabled() {
        return None;
    }
    let record = read_credentials()?;
    if !grants_plan(&record) {
        return None;
    }
    str_field(&record, "subject").map(str::to_owned)
}

/// One writer at a time across every Harness process on this host: a rotating
/// refresh token must never be spent twice. Held until dropped.
async fn lock() -> Result<std::fs::File, HarnessError> {
    let path = store_dir().join("credentials.lock");
    tokio::task::spawn_blocking(move || -> std::io::Result<std::fs::File> {
        std::fs::create_dir_all(store_dir())?;
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options.open(path)?;
        file.lock()?;
        Ok(file)
    })
    .await
    .map_err(|e| HarnessError::Protocol(format!("credential lock: {e}")))?
    .map_err(HarnessError::from)
}

fn write_json(path: &Path, record: &Value) -> Result<(), HarnessError> {
    let bytes = serde_json::to_vec_pretty(record)
        .map_err(|e| HarnessError::Protocol(format!("ChatGPT credential record: {e}")))?;
    write_atomic(path, &bytes)
}

/// Replace the file in one rename, owner-only, so a crash never leaves a
/// half-written record next to a spent refresh token.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), HarnessError> {
    use std::io::Write;
    let tmp = path.with_extension("tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&tmp)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// Remove the stored tokens (the registration and host id stay for next time).
pub(crate) async fn clear_credentials() -> Result<(), HarnessError> {
    let _lock = lock().await?;
    match std::fs::remove_file(credentials_path()) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}

// ---------------------------------------------------------------------------
// Access token for a launch
// ---------------------------------------------------------------------------

fn needs_refresh(record: &Value, t: u64) -> bool {
    let expires_at = record["expires_at"].as_u64().unwrap_or(0);
    let earliest = record["earliest_refresh_at"].as_u64().unwrap_or(0);
    t + RENEW_WITHIN_SECS >= expires_at && (t >= earliest || t >= expires_at)
}

/// A fresh access token for the plan provider, or `None` to fall back to
/// Codex's own sign-in (flag off, not signed in, or plan usage not granted).
pub(crate) async fn prepare() -> Result<Option<PlanAuth>, HarnessError> {
    if !enabled() {
        return Ok(None);
    }
    let Some(mut record) = read_credentials() else {
        tracing::warn!("ChatGPT plan usage is on but Harness is not signed in to ChatGPT");
        return Ok(None);
    };
    if !grants_plan(&record) {
        tracing::warn!("ChatGPT sign-in has no plan usage; using Codex's own sign-in");
        return Ok(None);
    }
    if needs_refresh(&record, now()) {
        let _lock = lock().await?;
        // Another process may have refreshed while this one waited.
        if let Some(latest) = read_credentials() {
            record = latest;
        }
        if needs_refresh(&record, now()) {
            record = refresh(&credentials_path(), record, TOKEN_ENDPOINT).await?;
        }
    }
    let Some(token) = str_field(&record, "access_token") else {
        return Ok(None);
    };
    Ok(Some(PlanAuth {
        access_token: token.to_owned(),
    }))
}

/// Codes that mean the renewable session is gone (docs: refresh errors).
const DEAD_SESSION: [&str; 6] = [
    "invalid_grant",
    "invalid_refresh_token",
    "token_expired",
    "refresh_token_expired",
    "refresh_token_invalidated",
    "refresh_token_reused",
];

/// Caller holds the credential lock.
async fn refresh(path: &Path, mut record: Value, endpoint: &str) -> Result<Value, HarnessError> {
    let (Some(client_id), Some(refresh_token)) = (
        str_field(&record, "client_id"),
        str_field(&record, "refresh_token"),
    ) else {
        return Err(expired());
    };
    let response = reqwest::Client::new()
        .post(endpoint)
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
        // Anything else is transient and the stored record stays untouched.
        let code = body["error"].as_str().or(body["error"]["code"].as_str());
        return Err(if code.is_some_and(|c| DEAD_SESSION.contains(&c)) {
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
    record["expires_at"] = (t + body["expires_in"].as_u64().unwrap_or(3600)).into();
    if let Some(e) = body["earliest_refresh_at"].as_u64() {
        // Absolute epoch seconds, or a delay from now.
        record["earliest_refresh_at"] = (if e > 1_000_000_000 { e } else { t + e }).into();
    }
    record["saved_at"] = iso8601(t).into();
    write_json(path, &record)?;
    Ok(record)
}

fn expired() -> HarnessError {
    HarnessError::Protocol("ChatGPT sign-in expired; sign in to ChatGPT again in Harness".into())
}

/// `YYYY-MM-DDTHH:MM:SSZ` for a Unix time.
pub(crate) fn iso8601(secs: u64) -> String {
    let (days, rem) = ((secs / 86_400) as i64, secs % 86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_beta_channel_has_plan_usage_on_and_stable_has_it_off() {
        // Stable: off unless asked for.
        assert!(!enabled_for(None, "0.2.99"));
        assert!(enabled_for(Some("1"), "0.2.99"));
        assert!(enabled_for(Some("on"), "0.2.99"));
        // Beta: on unless switched off.
        assert!(enabled_for(None, "0.2.100-beta.1"));
        assert!(!enabled_for(Some("0"), "0.2.100-beta.1"));
        assert!(!enabled_for(Some("off"), "0.2.100-beta.1"));
        // An unrecognised value falls back to the channel's default.
        assert!(!enabled_for(Some("maybe"), "0.2.99"));
        assert!(enabled_for(Some("maybe"), "0.2.100-beta.1"));
        // Only the beta tag turns it on, not any prerelease.
        assert!(!enabled_for(None, "0.2.100-rc.1"));
    }

    #[test]
    fn plan_scope_gates_the_provider() {
        let with = serde_json::json!({ "scopes": ["openid", PLAN_SCOPE] });
        let without = serde_json::json!({ "scopes": ["openid", "email"] });
        assert!(grants_plan(&with));
        assert!(!grants_plan(&without));
        assert!(!grants_plan(&Value::Null));
    }

    #[test]
    fn renewal_waits_for_the_window_and_the_earliest_time() {
        let record = |expires, earliest| serde_json::json!({ "expires_at": expires, "earliest_refresh_at": earliest });
        assert!(!needs_refresh(&record(10_000, 0), 1_000));
        assert!(needs_refresh(&record(10_000, 0), 9_800));
        assert!(!needs_refresh(&record(10_000, 9_900), 9_800));
        assert!(needs_refresh(&record(10_000, 9_900), 10_001));
    }

    #[test]
    fn dates_are_utc_iso() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(1_790_032_532), "2026-09-21T23:15:32Z");
        assert_eq!(iso8601(951_827_696), "2000-02-29T12:34:56Z");
    }

    #[test]
    fn a_record_is_replaced_whole_and_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("oauth.json");
        write_json(&path, &serde_json::json!({ "access_token": "a" })).unwrap();
        write_json(&path, &serde_json::json!({ "access_token": "b" })).unwrap();
        assert_eq!(read(&path).unwrap()["access_token"], "b");
        assert!(!path.with_extension("tmp").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[tokio::test]
    async fn refresh_rotates_the_session_and_a_dead_one_leaves_the_record_alone() {
        use super::super::chatgpt_signin::tests::{Handler, form, serve};
        use std::sync::{Arc, Mutex};

        let seen = Arc::new(Mutex::new(None));
        let alive = Arc::new(Mutex::new(true));
        let handler: Handler = {
            let (seen, alive) = (seen.clone(), alive.clone());
            Arc::new(move |_, body| {
                *seen.lock().unwrap() = Some(form(body));
                if *alive.lock().unwrap() {
                    let reply = serde_json::json!({
                        "access_token": "access-2", "refresh_token": "refresh-2",
                        "token_type": "Bearer", "expires_in": 3600,
                        "scope": "openid chatgpt.tokens.use.direct",
                    });
                    (200, reply.to_string())
                } else {
                    (400, r#"{"error":"refresh_token_reused"}"#.into())
                }
            })
        };
        let endpoint = format!("{}/token", serve(handler).await);
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("credentials.json");
        let record = serde_json::json!({
            "client_id": "oaiapp_test", "refresh_token": "refresh-1",
            "access_token": "access-1", "expires_at": 5, "subject": "user-1",
            "scopes": ["openid"],
        });
        write_json(&path, &record).unwrap();

        let refreshed = refresh(&path, record.clone(), &endpoint).await.unwrap();
        let sent = seen.lock().unwrap().clone().unwrap();
        assert_eq!(sent["grant_type"], "refresh_token");
        assert_eq!(
            sent["client_id"], "oaiapp_test",
            "the issued client, never the entrypoint"
        );
        assert_eq!(sent["refresh_token"], "refresh-1");
        assert_eq!(sent["resource"], "https://api.openai.com/v1");
        assert!(
            !sent.contains_key("scope"),
            "the grant is retained, not re-requested"
        );
        assert_eq!(refreshed["access_token"], "access-2");
        assert_eq!(refreshed["refresh_token"], "refresh-2");
        assert_eq!(refreshed["subject"], "user-1", "unrelated fields survive");
        assert!(grants_plan(&refreshed));
        assert_eq!(
            read(&path).unwrap()["refresh_token"],
            "refresh-2",
            "stored together"
        );

        *alive.lock().unwrap() = false;
        let before = std::fs::read(&path).unwrap();
        let dead = refresh(&path, refreshed, &endpoint).await.unwrap_err();
        assert!(
            dead.to_string().contains("sign in to ChatGPT again"),
            "{dead}"
        );
        assert_eq!(
            std::fs::read(&path).unwrap(),
            before,
            "a dead session changes nothing"
        );
    }
}
