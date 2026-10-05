//! Codegraff cloud sandboxes (the gateway's `/v1/sandboxes`) for Settings → Accounts.
//!
//! A Harness cloud sandbox is a persistent sandbox on the gateway's own `fleet` provider. After
//! it exists, `POST /v1/sandboxes/:id/harness {deviceName}` does the rest: it attaches a fresh
//! lease-bound sign-in, installs the pinned Linux build once, starts `harness headless`, and
//! waits for it to sign in, after which the sandbox shows up in the owner's device list under
//! `deviceName`. That call is idempotent and is also the second half of every wake (pausing
//! retires the token), so start = `/start` (if not running) then `/harness`.
//!
//! Fleet rows carry no name and no link to their device except the device's name, so each
//! sandbox gets a unique `deviceName`, remembered in `cloud-sandboxes.json` in the data
//! directory and joined onto the list.
//!
//! Every build offers them to an account signed in with Codegraff; the gateway decides what the
//! account may do (credit, reservations) and its errors are shown as they come.
//! [`cloud_sandboxes_enabled`] can still turn the feature off.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use reqwest::Method;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::watch;

use super::{CodegraffAuth, http, urlencode};

const FLEET: &str = "fleet";
const SANDBOX_NAME: &str = "Harness cloud";
/// The shared agent sandbox role: the gateway keeps at most one per account
/// and returns it (instead of creating another) on repeat requests.
const DEFAULT_ROLE: &str = "harness-default";
/// Lease length requested at create. Fleet leases are fixed windows the
/// gateway caps (30 min max, ~10 min on a plain resume) — activity does NOT
/// extend them, and the sandbox pauses when the window ends.
const AUTO_STOP_MINUTES: u32 = 30;
/// A device counts as online when `lastSeenAt` is this fresh — the same
/// window the Devices page uses (crates/ui `DEVICE_ONLINE_WINDOW_SECS`).
const DEVICE_ONLINE_WINDOW_SECS: i64 = 70;
const QUICK: Duration = Duration::from_secs(20);
/// Creating or waking a sandbox boots a machine.
const BOOT: Duration = Duration::from_secs(90);
/// `/harness` waits up to ~30 s for the device to sign in, plus a first-time install.
const HARNESS_STEP: Duration = Duration::from_secs(120);
const DEVICES_FILE: &str = "cloud-sandboxes.json";

/// One sandbox on the account. Tolerant: unknown fields are ignored and missing ones default.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffSandbox {
    pub id: String,
    /// `fleet` (ours) or `daytona`.
    pub provider: String,
    pub name: Option<String>,
    /// Normalised: `running` | `starting` | `paused` | `stopping` | `error` | `unknown`
    /// (the fleet says `started`; `destroyed` rows are dropped).
    pub state: String,
    pub tier: Option<String>,
    pub expires_at: Option<Value>,
    /// Harness was set up in it, so it can appear as a device.
    pub harness: bool,
    /// The name its device registers under (remembered at create time).
    pub device_name: Option<String>,
    /// Gateway-assigned role (`"harness-default"` for the shared agent
    /// sandbox ensure reuses); absent on older rows.
    pub role: Option<String>,
}

/// `enabled: false` means this build doesn't offer cloud sandboxes (the UI hides the card).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffSandboxes {
    pub enabled: bool,
    pub sandboxes: Vec<CodegraffSandbox>,
}

/// On unless `HARNESS_CLOUD_SANDBOXES=0` (or `false`) turns cloud sandboxes off.
pub fn cloud_sandboxes_enabled() -> bool {
    enabled_for(std::env::var("HARNESS_CLOUD_SANDBOXES").ok().as_deref())
}

fn enabled_for(flag: Option<&str>) -> bool {
    !matches!(flag.map(str::trim), Some("0" | "false"))
}

fn parse_sandbox(value: &Value) -> CodegraffSandbox {
    let text = |pointer: &str| {
        value
            .pointer(pointer)
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    CodegraffSandbox {
        id: text("/id").unwrap_or_default(),
        provider: text("/provider").unwrap_or_default(),
        name: text("/name"),
        state: normalise_state(text("/state").as_deref()),
        tier: text("/tier"),
        expires_at: value
            .get("expiresAt")
            .or_else(|| value.get("expires_at"))
            .filter(|v| !v.is_null())
            .cloned(),
        harness: value
            .pointer("/codegraff/harness")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        device_name: None,
        role: text("/role"),
    }
}

/// The fleet's own words (`started`, `destroyed`) in the words the rest of the app uses.
fn normalise_state(state: Option<&str>) -> String {
    match state {
        Some("started") => "running".into(),
        Some("destroyed") => "terminated".into(),
        Some(other) => other.into(),
        None => String::new(),
    }
}

/// A device name the gateway accepts (1-40 of `[A-Za-z0-9 ._-]`, first alphanumeric) that is
/// unique per sandbox, so the device list can tell two cloud sandboxes apart.
fn device_name_for(sandbox_id: &str) -> String {
    let short: String = sandbox_id
        .strip_prefix("cnd_")
        .unwrap_or(sandbox_id)
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(4)
        .collect();
    if short.is_empty() {
        SANDBOX_NAME.to_string()
    } else {
        format!("{SANDBOX_NAME} {short}")
    }
}

/// The list may be a bare array or wrapped; terminated sandboxes are gone for good.
fn parse_list(value: &Value) -> Vec<CodegraffSandbox> {
    let items = match value {
        Value::Array(items) => Some(items),
        other => ["sandboxes", "data", "items"]
            .iter()
            .find_map(|key| other.get(key).and_then(Value::as_array)),
    };
    items
        .into_iter()
        .flatten()
        .map(parse_sandbox)
        .filter(|sandbox| !sandbox.id.is_empty() && sandbox.state != "terminated")
        .collect()
}

/// A gateway call that did not succeed.
struct Failure {
    /// 0 when nothing was sent (not signed in, bad gateway URL, no network).
    status: u16,
    body: Option<Value>,
    message: Option<String>,
}

impl Failure {
    fn local(message: impl Into<String>) -> Self {
        Self {
            status: 0,
            body: None,
            message: Some(message.into()),
        }
    }

    fn error_type(&self) -> Option<&str> {
        self.body.as_ref()?.pointer("/error/type")?.as_str()
    }

    /// The gateway's own `error.message` as a sentence, else `fallback`. A few error types
    /// get app wording because the gateway's text is written for developers.
    fn sentence(&self, fallback: &str) -> String {
        let known = match self.error_type() {
            Some("insufficient_credits") => {
                Some("Your Codegraff credit is used up. Add credit and try again.")
            }
            Some("sandbox_not_running") => Some("The sandbox isn't running. Start it first."),
            Some("insufficient_scope") => {
                Some("This Codegraff sign-in can't manage sandboxes. Sign in again.")
            }
            Some("harness_cloud_unavailable") => {
                Some("Harness cloud isn't available yet. Try again later.")
            }
            _ => None,
        };
        if let Some(known) = known {
            return known.to_string();
        }
        let message = self
            .message
            .as_deref()
            .or_else(|| self.body.as_ref()?.pointer("/error/message")?.as_str())
            .map(str::trim)
            .filter(|m| !m.is_empty());
        match message {
            Some(message) => {
                let mut chars = message.chars();
                let first = chars.next().map(|c| c.to_uppercase().to_string());
                format!(
                    "{}{}.",
                    first.unwrap_or_default(),
                    chars.as_str().trim_end_matches('.')
                )
            }
            None if self.status == 0 => format!("{fallback}."),
            None => format!("{fallback} ({}).", self.status),
        }
    }
}

impl CodegraffAuth {
    async fn sandbox_call(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
        timeout: Duration,
    ) -> Result<Value, Failure> {
        self.sandbox_call_status(method, path, body, timeout)
            .await
            .map(|(_, body)| body)
    }

    /// The same call with the HTTP status kept: `POST /v1/sandboxes` uses
    /// 200 (existing default), 201 (created) and 202 (pending) deliberately.
    async fn sandbox_call_status(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
        timeout: Duration,
    ) -> Result<(u16, Value), Failure> {
        let key = self
            .current_key()
            .ok_or_else(|| Failure::local("Sign in with Codegraff first"))?;
        crate::auth::validate_secure_url("CodeGraff gateway", &self.gateway)
            .map_err(Failure::local)?;
        let mut request = http()
            .request(method, format!("{}{path}", self.gateway))
            .bearer_auth(key)
            .timeout(timeout);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request
            .send()
            .await
            .map_err(|e| Failure::local(format!("couldn't reach CodeGraff: {e}")))?;
        let status = response.status();
        let body = response.json::<Value>().await.ok();
        if status.is_success() {
            Ok((status.as_u16(), body.unwrap_or(Value::Null)))
        } else {
            Err(Failure {
                status: status.as_u16(),
                body,
                message: None,
            })
        }
    }

    fn sandbox_path(id: &str, tail: &str) -> String {
        format!("/v1/sandboxes/{}{tail}", urlencode(id))
    }

    fn devices_path(&self) -> Option<PathBuf> {
        self.identity.parent().map(|dir| dir.join(DEVICES_FILE))
    }

    /// `sandbox id → device name`, as remembered at create time.
    fn device_names(&self) -> BTreeMap<String, String> {
        self.devices_path()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save_device_names(&self, names: &BTreeMap<String, String>) {
        let Some(path) = self.devices_path() else {
            return;
        };
        let staged = path.with_extension("json.tmp");
        let written = serde_json::to_vec_pretty(names)
            .map_err(std::io::Error::other)
            .and_then(|bytes| std::fs::write(&staged, bytes))
            .and_then(|()| std::fs::rename(&staged, &path));
        if let Err(error) = written {
            tracing::warn!(%error, "could not save the cloud sandbox device names");
        }
    }

    /// The account's sandboxes (`None` when signed out). Builds that don't offer cloud
    /// sandboxes answer `enabled: false` without calling the gateway.
    pub async fn sandboxes(&self) -> Result<Option<CodegraffSandboxes>, String> {
        if self.current_key().is_none() {
            return Ok(None);
        }
        if !cloud_sandboxes_enabled() {
            return Ok(Some(CodegraffSandboxes::default()));
        }
        let value = self
            .sandbox_call(Method::GET, "/v1/sandboxes", None, QUICK)
            .await
            .map_err(|f| f.sentence("CodeGraff sandboxes are unavailable"))?;
        let names = self.device_names();
        let mut sandboxes = parse_list(&value);
        for sandbox in &mut sandboxes {
            sandbox.device_name = names.get(&sandbox.id).cloned();
            sandbox.harness = sandbox.harness || sandbox.device_name.is_some();
        }
        Ok(Some(CodegraffSandboxes {
            enabled: true,
            sandboxes,
        }))
    }

    /// Set Harness up in a running sandbox (idempotent; see the module docs). One retry,
    /// because the gateway says a failed install or start is safe to retry once.
    async fn attach_harness(&self, id: &str, device_name: &str) -> Result<(), Failure> {
        let path = Self::sandbox_path(id, "/harness");
        let body = json!({ "deviceName": device_name });
        match self
            .sandbox_call(Method::POST, &path, Some(body.clone()), HARNESS_STEP)
            .await
        {
            Err(f) if f.error_type() == Some("harness_start_failed") => self
                .sandbox_call(Method::POST, &path, Some(body), HARNESS_STEP)
                .await
                .map(drop),
            other => other.map(drop),
        }
    }

    /// Create the account's Harness cloud sandbox and set Harness up in it. If the machine
    /// exists but Harness could not start, it stays in the list: Start retries the setup.
    pub async fn create_sandbox(&self) -> Result<CodegraffSandbox, String> {
        if !cloud_sandboxes_enabled() {
            return Err("Cloud sandboxes are not available in this build.".into());
        }
        let body = json!({
            "provider": FLEET,
            "persistent": true,
            "name": SANDBOX_NAME,
            "autoStopMinutes": AUTO_STOP_MINUTES,
        });
        let created = self
            .sandbox_call(Method::POST, "/v1/sandboxes", Some(body), BOOT)
            .await
            .map_err(|f| f.sentence("CodeGraff couldn't create the sandbox"))?;
        let mut sandbox = parse_sandbox(&created);
        if sandbox.id.is_empty() {
            return Err("CodeGraff created a sandbox but didn't say which one.".into());
        }
        // Remembered before the setup call, so a failed setup retries under the same name.
        let device_name = device_name_for(&sandbox.id);
        let mut names = self.device_names();
        names.insert(sandbox.id.clone(), device_name.clone());
        self.save_device_names(&names);
        if let Err(failure) = self.attach_harness(&sandbox.id, &device_name).await {
            return Err(format!(
                "The sandbox was created, but Harness couldn't be set up in it ({}) Use Start on it to try again.",
                failure.sentence("setup failed")
            ));
        }
        sandbox.state = "running".into();
        sandbox.harness = true;
        sandbox.device_name = Some(device_name);
        Ok(sandbox)
    }

    /// Start a sandbox that isn't running (or set Harness up again in a running one): `/start`
    /// when needed, then `/harness` under the name remembered at create time.
    pub async fn start_sandbox(&self, id: &str) -> Result<(), String> {
        let current = self
            .sandbox_call(Method::GET, &Self::sandbox_path(id, ""), None, QUICK)
            .await
            .map_err(|f| f.sentence("CodeGraff couldn't read the sandbox"))?;
        if parse_sandbox(&current).state != "running" {
            self.sandbox_call(Method::POST, &Self::sandbox_path(id, "/start"), None, BOOT)
                .await
                .map_err(|f| f.sentence("CodeGraff couldn't start the sandbox"))?;
        }
        let mut names = self.device_names();
        let device_name = names
            .get(id)
            .cloned()
            .unwrap_or_else(|| device_name_for(id));
        self.attach_harness(id, &device_name).await.map_err(|f| {
            f.sentence(
                "The sandbox is running but Harness couldn't be set up in it; try Start again",
            )
        })?;
        if names.insert(id.to_owned(), device_name.clone()).is_none() {
            self.save_device_names(&names);
        }
        Ok(())
    }

    /// Pause (fleet: memory and processes are kept).
    pub async fn stop_sandbox(&self, id: &str) -> Result<(), String> {
        self.sandbox_call(Method::POST, &Self::sandbox_path(id, "/stop"), None, QUICK)
            .await
            .map(drop)
            .map_err(|f| f.sentence("CodeGraff couldn't stop the sandbox"))
    }

    pub async fn delete_sandbox(&self, id: &str) -> Result<(), String> {
        self.sandbox_call(Method::DELETE, &Self::sandbox_path(id, ""), None, QUICK)
            .await
            .map_err(|f| f.sentence("CodeGraff couldn't delete the sandbox"))?;
        let mut names = self.device_names();
        if names.remove(id).is_some() {
            self.save_device_names(&names);
        }
        Ok(())
    }

    /// Usage for one sandbox, as the gateway sends it. 501 means the provider
    /// can't report it — a fact about the sandbox, not a failure.
    pub async fn sandbox_meter(&self, id: &str) -> Result<Value, String> {
        match self
            .sandbox_call(Method::GET, &Self::sandbox_path(id, "/meter"), None, QUICK)
            .await
        {
            Err(f) if f.status == 501 => Ok(json!({ "supported": false })),
            other => other.map_err(|f| f.sentence("CodeGraff couldn't read the sandbox's usage")),
        }
    }

    /// Reuse or wake the account's Harness cloud sandbox and wait for its
    /// device to come online — the agent-facing "give me a machine to run on".
    ///
    /// Sandboxes are joined to devices by the exact `cloudSandboxId` the
    /// sandbox's engine stamps at boot, never by name. `allow_create` gates the
    /// only billed step (`POST /v1/sandboxes`); waking or reattaching an
    /// existing sandbox stays inside its bounded fleet lease. `devices` is the
    /// workspace host's device watch: the answer is the device row carrying
    /// this sandbox's id once it reports in, bounded by `wait`.
    ///
    /// Single-flight per process: `POST /v1/sandboxes` has no idempotency key,
    /// so concurrent ensures queue here instead of double-creating.
    pub async fn ensure_sandbox(
        &self,
        allow_create: bool,
        wait: Duration,
        devices: watch::Receiver<Vec<harness_proto::Device>>,
    ) -> Result<EnsuredSandbox, String> {
        static FLIGHT: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
        let _flight = FLIGHT.get_or_init(Default::default).lock().await;
        self.ensure_sandbox_inner(allow_create, wait, devices).await
    }

    async fn ensure_sandbox_inner(
        &self,
        allow_create: bool,
        wait: Duration,
        mut devices: watch::Receiver<Vec<harness_proto::Device>>,
    ) -> Result<EnsuredSandbox, String> {
        let online = |device: &harness_proto::Device| {
            device.last_seen_at.is_some_and(|at| {
                chrono::Utc::now().signed_duration_since(at).num_seconds()
                    <= DEVICE_ONLINE_WINDOW_SECS
            })
        };
        fn matched<'a>(
            devices: &'a [harness_proto::Device],
            id: &str,
        ) -> Option<&'a harness_proto::Device> {
            devices
                .iter()
                .find(|d| d.cloud_sandbox_id.as_deref() == Some(id))
        }

        // a. pick a live fleet sandbox — one a device already claims by exact
        // id beats the shared default, which beats running, then paused.
        let list = self
            .sandboxes()
            .await
            .map_err(|e| format!("list: {e}"))?
            .ok_or_else(|| "Sign in with Codegraff first.".to_string())?;
        let mut candidates: Vec<&CodegraffSandbox> = list
            .sandboxes
            .iter()
            .filter(|s| s.provider == FLEET)
            .filter(|s| !matches!(s.state.as_str(), "error" | "stopping"))
            .collect();
        candidates.sort_by_key(|s| {
            if matched(&devices.borrow(), &s.id).is_some() {
                0
            } else if s.role.as_deref() == Some(DEFAULT_ROLE) {
                1
            } else {
                match s.state.as_str() {
                    "running" => 2,
                    "paused" => 3,
                    _ => 4,
                }
            }
        });

        let deadline = tokio::time::Instant::now() + wait;

        // b. nothing to reuse — creating is billed, so it is opt-in.
        if candidates.is_empty() && !allow_create {
            return Err(
                "No cloud sandbox on this account. Creating one adds billed compute; \
                 call again with allowCreate: true to create it."
                    .into(),
            );
        }
        let (chosen, created) = match candidates.first() {
            None => self.create_default_sandbox(deadline).await?,
            Some(sandbox) => ((**sandbox).clone(), false),
        };

        // c. wake when paused; reattach Harness when it runs but its device
        // has not yet reported this sandbox id (never on the already-online
        // fast path — zero POSTs).
        let sandbox_id = chosen.id.clone();
        let mut expires_at = chosen.expires_at.clone();
        let needs_attach = matched(&devices.borrow(), &sandbox_id).is_none_or(|d| !online(d));
        let mut woke = false;
        if chosen.state == "paused" || needs_attach {
            self.start_sandbox(&sandbox_id)
                .await
                .map_err(|e| format!("setup: {e}"))?;
            woke = chosen.state == "paused";
        }

        // Cheap only when we changed something: the lease clock moved.
        if created || woke {
            if let Ok(Some(fresh)) = self.sandboxes().await {
                if let Some(s) = fresh.sandboxes.iter().find(|s| s.id == sandbox_id) {
                    expires_at = s.expires_at.clone();
                }
            }
        }

        // d. wait for the device row carrying this exact sandbox id.
        loop {
            if let Some(device) = matched(&devices.borrow(), &sandbox_id).filter(|d| online(d)) {
                return Ok(EnsuredSandbox {
                    sandbox_id,
                    device_id: device.id.clone(),
                    device_name: device.name.clone(),
                    created,
                    woke,
                    expires_at,
                });
            }
            let Some(remaining) = deadline.checked_duration_since(tokio::time::Instant::now())
            else {
                break;
            };
            if tokio::time::timeout(remaining, devices.changed())
                .await
                .is_err()
            {
                break;
            }
        }

        // Timed out: a name-matched device online means an older build that
        // cannot stamp the exact id — name it, but never return it.
        let expected_name = self
            .device_names()
            .get(&sandbox_id)
            .cloned()
            .unwrap_or_else(|| device_name_for(&sandbox_id));
        let name_match = devices
            .borrow()
            .iter()
            .find(|d| d.name == expected_name && online(d))
            .map(|d| {
                format!(
                    " A device named \"{}\" is online but did not report this sandbox id — \
                     an unverified name match; its Harness build may predate exact sandbox ids.",
                    d.name
                )
            })
            .unwrap_or_default();
        Err(format!(
            "The sandbox is running but no device has reported this sandbox id within {} s.{}",
            wait.as_secs(),
            name_match
        ))
    }

    /// Join or start the account's default agent sandbox — the only create
    /// `ensure_sandbox` performs (the Settings card's `create_sandbox` stays
    /// role-free and makes its own).
    ///
    /// `POST /v1/sandboxes {role: "harness-default"}` contract:
    /// - 200 — the existing (possibly paused) default, untouched;
    /// - 201 — a new default was created;
    /// - 202 — creation is pending under a stable `operationId`; re-POST the
    ///   SAME request to join it, never a differently-shaped one.
    /// A gateway that does not know `role` simply answers 200/201 for a fresh
    /// create, which lands in the same unified wake path.
    ///
    /// Returns the sandbox and whether it was created now (201).
    async fn create_default_sandbox(
        &self,
        deadline: tokio::time::Instant,
    ) -> Result<(CodegraffSandbox, bool), String> {
        let body = json!({
            "provider": FLEET,
            "persistent": true,
            "name": SANDBOX_NAME,
            "autoStopMinutes": AUTO_STOP_MINUTES,
            "role": DEFAULT_ROLE,
        });
        loop {
            let (status, value) = self
                .sandbox_call_status(Method::POST, "/v1/sandboxes", Some(body.clone()), BOOT)
                .await
                .map_err(|f| {
                    format!(
                        "boot: {}",
                        f.sentence("CodeGraff couldn't create the sandbox")
                    )
                })?;
            match status {
                200 | 201 => {
                    let sandbox = parse_sandbox(&value);
                    if sandbox.id.is_empty() {
                        return Err(
                            "boot: CodeGraff created a sandbox but didn't say which one.".into(),
                        );
                    }
                    return Ok((sandbox, status == 201));
                }
                202 => {
                    let operation = value
                        .get("operationId")
                        .or_else(|| value.get("operation_id"))
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let Some(remaining) =
                        deadline.checked_duration_since(tokio::time::Instant::now())
                    else {
                        return Err(format!(
                            "boot: the default sandbox is still being created (operation \
                             {operation}); call ensure_sandbox again to join it"
                        ));
                    };
                    tokio::time::sleep(remaining.min(Duration::from_secs(2))).await;
                }
                other => {
                    return Err(format!("boot: unexpected {other} creating the sandbox."));
                }
            }
        }
    }
}

/// What [`CodegraffAuth::ensure_sandbox`] answers: the sandbox plus the device
/// row that verifiably belongs to it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnsuredSandbox {
    pub sandbox_id: String,
    pub device_id: String,
    pub device_name: String,
    pub created: bool,
    pub woke: bool,
    pub expires_at: Option<Value>,
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::{Arc, Mutex};

    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::super::{KEY_FILE, write_private};
    use super::*;

    #[test]
    fn every_build_offers_sandboxes_unless_the_flag_turns_them_off() {
        assert!(enabled_for(None), "on in every build");
        assert!(enabled_for(Some("1")));
        assert!(enabled_for(Some("")));
        assert!(!enabled_for(Some("0")));
        assert!(!enabled_for(Some(" false ")));
    }

    #[test]
    fn lists_use_the_apps_state_words_and_drop_destroyed_rows() {
        let wrapped = json!({"sandboxes": [
            {"id": "cnd_1", "provider": "fleet", "state": "started", "expiresAt": 1790000000,
             "future": 1},
            {"id": "cnd_2", "provider": "fleet", "state": "destroyed"},
            {"id": "sb_3", "provider": "daytona", "state": "terminated"},
            {"id": "cnd_4", "state": "paused"},
            {"id": "cnd_5", "state": "starting"},
        ]});
        let parsed = parse_list(&wrapped);
        let states: Vec<_> = parsed
            .iter()
            .map(|s| (s.id.as_str(), s.state.as_str()))
            .collect();
        assert_eq!(
            states,
            [
                ("cnd_1", "running"),
                ("cnd_4", "paused"),
                ("cnd_5", "starting")
            ]
        );
        assert!(parsed[0].expires_at.is_some());
        assert_eq!(
            parse_list(&json!([{"id": "a", "state": "started"}])).len(),
            1
        );
        assert!(parse_list(&json!({"error": "nope"})).is_empty());
    }

    #[test]
    fn device_names_are_valid_and_unique_per_sandbox() {
        let a = device_name_for("cnd_ab12cd34ef56");
        let b = device_name_for("cnd_ff00cd34ef56");
        assert_eq!(a, "Harness cloud ab12");
        assert_ne!(a, b);
        for name in [&a, &b, &device_name_for("odd id!!")] {
            assert!((1..=40).contains(&name.len()));
            assert!(name.starts_with(|c: char| c.is_ascii_alphanumeric()));
            assert!(
                name.chars()
                    .all(|c| c.is_ascii_alphanumeric() || " ._-".contains(c))
            );
        }
        assert_eq!(device_name_for(""), "Harness cloud");
    }

    #[test]
    fn failures_speak_in_app_words_or_the_gateways() {
        let credits = Failure {
            status: 402,
            body: Some(json!({"error": {"type": "insufficient_credits", "message": "x"}})),
            message: None,
        };
        assert!(
            credits
                .sentence("x")
                .starts_with("Your Codegraff credit is used up")
        );
        let limit = Failure {
            status: 429,
            body: Some(
                json!({"error": {"type": "fleet_limit", "message": "the fleet sandbox limit is reached"}}),
            ),
            message: None,
        };
        assert_eq!(limit.sentence("x"), "The fleet sandbox limit is reached.");
        let bare = Failure {
            status: 500,
            body: None,
            message: None,
        };
        assert_eq!(
            bare.sentence("CodeGraff couldn't stop the sandbox"),
            "CodeGraff couldn't stop the sandbox (500)."
        );
    }

    /// A fake gateway. Each request takes the first matching route not yet used; when every
    /// match is used, the last one repeats. Every request is recorded in full.
    async fn fake(
        routes: Vec<(&'static str, u16, &'static str)>,
    ) -> (String, Arc<Mutex<Vec<String>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let used = Arc::new(Mutex::new(vec![false; routes.len()]));
        tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut buf = vec![0u8; 16384];
                let n = socket.read(&mut buf).await.unwrap();
                let request = String::from_utf8_lossy(&buf[..n]).to_string();
                let line = request.lines().next().unwrap_or_default().to_owned();
                log.lock().unwrap().push(request);
                let matching: Vec<usize> = (0..routes.len())
                    .filter(|&i| line.starts_with(routes[i].0))
                    .collect();
                let (status, body) = {
                    let mut used = used.lock().unwrap();
                    let pick = matching
                        .iter()
                        .copied()
                        .find(|&i| !used[i])
                        .or_else(|| matching.last().copied());
                    match pick {
                        Some(i) => {
                            used[i] = true;
                            (routes[i].1, routes[i].2)
                        }
                        None => (404, "{}"),
                    }
                };
                let response = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.write_all(response.as_bytes()).await.unwrap();
            }
        });
        (base, seen)
    }

    fn signed_in(dir: &Path, gateway: String) -> Arc<CodegraffAuth> {
        let key_file = dir.join("home").join(KEY_FILE);
        write_private(&key_file, br#"{"api_key":"cg_sk_test"}"#).unwrap();
        Arc::new(CodegraffAuth::new(dir, Some(key_file), gateway))
    }

    fn lines(seen: &Arc<Mutex<Vec<String>>>) -> Vec<String> {
        seen.lock()
            .unwrap()
            .iter()
            .map(|r| {
                r.lines()
                    .next()
                    .unwrap_or_default()
                    .trim_end_matches(" HTTP/1.1")
                    .to_owned()
            })
            .collect()
    }

    fn enable() {
        // SAFETY: every test that needs the flag sets the same value.
        unsafe { std::env::set_var("HARNESS_CLOUD_SANDBOXES", "1") };
    }

    #[tokio::test]
    async fn create_makes_a_fleet_sandbox_then_sets_harness_up_under_a_unique_name() {
        let (gateway, seen) = fake(vec![
            (
                "POST /v1/sandboxes ",
                201,
                r#"{"id":"cnd_ab12cd","provider":"fleet","state":"started","tier":"persistent","expiresAt":1790000000}"#,
            ),
            (
                "POST /v1/sandboxes/cnd_ab12cd/harness ",
                200,
                r#"{"id":"cnd_ab12cd","harness":{"running":true,"signedIn":true}}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let made = auth.create_sandbox().await.unwrap();
        assert_eq!(made.state, "running");
        assert_eq!(made.device_name.as_deref(), Some("Harness cloud ab12"));
        assert!(made.harness);
        let sent = seen.lock().unwrap().clone();
        assert!(sent[0].contains("Bearer cg_sk_test"));
        for needle in [
            r#""provider":"fleet""#,
            r#""persistent":true"#,
            r#""autoStopMinutes":30"#,
        ] {
            assert!(sent[0].contains(needle), "{needle} in {}", sent[0]);
        }
        assert!(
            !sent[0].contains(r#""harness""#),
            "the create call must not ask for the old flag"
        );
        assert!(sent[1].contains(r#""deviceName":"Harness cloud ab12""#));
        assert!(
            lines(&seen).iter().all(|l| !l.contains("/codegraff")),
            "{:?}",
            lines(&seen)
        );
        // The name is remembered, and the list joins it back on.
        assert_eq!(
            auth.device_names().get("cnd_ab12cd").map(String::as_str),
            Some("Harness cloud ab12")
        );
    }

    #[tokio::test]
    async fn a_failed_setup_keeps_the_sandbox_and_says_to_use_start() {
        let (gateway, seen) = fake(vec![
            (
                "POST /v1/sandboxes ",
                201,
                r#"{"id":"cnd_aa","provider":"fleet","state":"started"}"#,
            ),
            (
                "POST /v1/sandboxes/cnd_aa/harness ",
                503,
                r#"{"error":{"type":"harness_cloud_unavailable","message":"no pinned build"}}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let error = auth.create_sandbox().await.unwrap_err();
        assert!(
            error.contains("was created") && error.contains("Use Start"),
            "{error}"
        );
        assert!(
            lines(&seen).iter().all(|l| !l.starts_with("DELETE")),
            "nothing is deleted"
        );
        assert!(
            auth.device_names().contains_key("cnd_aa"),
            "so Start reuses the name"
        );
    }

    #[tokio::test]
    async fn a_failed_install_is_retried_once() {
        let (gateway, seen) = fake(vec![
            (
                "POST /v1/sandboxes/cnd_1/harness ",
                502,
                r#"{"error":{"type":"harness_start_failed","message":"Harness could not be installed/started in the sandbox."}}"#,
            ),
            ("POST /v1/sandboxes/cnd_1/harness ", 200, r#"{"id":"cnd_1"}"#),
            ("GET /v1/sandboxes/cnd_1 ", 200, r#"{"id":"cnd_1","state":"started"}"#),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        auth.start_sandbox("cnd_1").await.unwrap();
        let harness_calls = lines(&seen)
            .iter()
            .filter(|l| l.contains("/harness"))
            .count();
        assert_eq!(harness_calls, 2);
    }

    #[tokio::test]
    async fn waking_starts_a_paused_sandbox_then_sets_harness_up_never_the_old_attach() {
        let (gateway, seen) = fake(vec![
            (
                "GET /v1/sandboxes/cnd_1 ",
                200,
                r#"{"id":"cnd_1","state":"paused"}"#,
            ),
            (
                "POST /v1/sandboxes/cnd_1/start ",
                200,
                r#"{"state":"started"}"#,
            ),
            (
                "POST /v1/sandboxes/cnd_1/harness ",
                200,
                r#"{"id":"cnd_1"}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        let mut names = BTreeMap::new();
        names.insert("cnd_1".to_string(), "Harness cloud 0001".to_string());
        auth.save_device_names(&names);
        auth.start_sandbox("cnd_1").await.unwrap();
        assert_eq!(
            lines(&seen),
            [
                "GET /v1/sandboxes/cnd_1",
                "POST /v1/sandboxes/cnd_1/start",
                "POST /v1/sandboxes/cnd_1/harness"
            ]
        );
        assert!(seen.lock().unwrap()[2].contains(r#""deviceName":"Harness cloud 0001""#));
    }

    #[tokio::test]
    async fn a_running_sandbox_skips_start() {
        let (gateway, seen) = fake(vec![
            (
                "GET /v1/sandboxes/cnd_1 ",
                200,
                r#"{"id":"cnd_1","state":"started"}"#,
            ),
            (
                "POST /v1/sandboxes/cnd_1/harness ",
                200,
                r#"{"id":"cnd_1"}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        auth.start_sandbox("cnd_1").await.unwrap();
        assert!(lines(&seen).iter().all(|l| !l.contains("/start")));
    }

    #[tokio::test]
    async fn a_failed_setup_after_start_says_so_instead_of_claiming_success() {
        let (gateway, _) = fake(vec![
            ("GET /v1/sandboxes/cnd_1 ", 200, r#"{"state":"paused"}"#),
            ("POST /v1/sandboxes/cnd_1/start ", 200, r#"{}"#),
            ("POST /v1/sandboxes/cnd_1/harness ", 500, r#"{}"#),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        let error = auth.start_sandbox("cnd_1").await.unwrap_err();
        assert!(error.contains("couldn't be set up"), "{error}");
    }

    #[tokio::test]
    async fn the_list_joins_the_remembered_device_name_and_delete_forgets_it() {
        let (gateway, _) = fake(vec![
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started"},{"id":"cnd_2","provider":"fleet","state":"paused"}]}"#,
            ),
            ("DELETE /v1/sandboxes/cnd_1 ", 200, r#"{}"#),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let mut names = BTreeMap::new();
        names.insert("cnd_1".to_string(), "Harness cloud 0001".to_string());
        auth.save_device_names(&names);
        let list = auth.sandboxes().await.unwrap().unwrap();
        assert_eq!(
            list.sandboxes[0].device_name.as_deref(),
            Some("Harness cloud 0001")
        );
        assert!(list.sandboxes[0].harness);
        assert_eq!(list.sandboxes[1].device_name, None);
        assert!(!list.sandboxes[1].harness);
        auth.delete_sandbox("cnd_1").await.unwrap();
        assert!(auth.device_names().is_empty());
    }

    #[tokio::test]
    async fn signed_out_lists_nothing_and_never_calls_the_gateway() {
        let (gateway, seen) = fake(vec![]).await;
        let dir = tempfile::tempdir().unwrap();
        let auth = Arc::new(CodegraffAuth::new(
            dir.path(),
            Some(dir.path().join("none")),
            gateway,
        ));
        enable();
        assert_eq!(auth.sandboxes().await.unwrap(), None);
        assert!(seen.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn stop_delete_and_ids_stay_one_path_segment() {
        let (gateway, seen) = fake(vec![
            ("POST /v1/sandboxes/cnd_1/stop ", 200, r#"{}"#),
            ("DELETE /v1/sandboxes/..%2Fx ", 200, r#"{}"#),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        auth.stop_sandbox("cnd_1").await.unwrap();
        auth.delete_sandbox("../x").await.unwrap();
        assert!(
            lines(&seen)
                .iter()
                .any(|l| l == "DELETE /v1/sandboxes/..%2Fx")
        );
    }

    // ---- the shared contract: apps/parity/vectors/cloud-sandbox.json -------------------------

    fn vector() -> Value {
        serde_json::from_str(include_str!(
            "../../../../apps/parity/vectors/cloud-sandbox.json"
        ))
        .unwrap()
    }

    #[test]
    fn the_shared_vector_state_words_and_hidden_rows() {
        let vector = vector();
        for (gateway, app) in vector["stateWords"].as_object().unwrap() {
            assert_eq!(
                normalise_state(Some(gateway)),
                app.as_str().unwrap(),
                "{gateway}"
            );
        }
        for hidden in vector["hiddenStates"].as_array().unwrap() {
            let list = json!([{"id": "x", "state": hidden}]);
            assert!(parse_list(&list).is_empty(), "{hidden} rows are dropped");
        }
    }

    #[test]
    fn the_shared_vector_device_names() {
        for case in vector()["deviceNames"].as_array().unwrap() {
            assert_eq!(
                device_name_for(case["id"].as_str().unwrap()),
                case["name"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn the_shared_vector_error_words() {
        for case in vector()["errors"].as_array().unwrap() {
            let status = case["status"].as_u64().unwrap() as u16;
            let message = case["message"].as_str();
            let failure = if status == 0 {
                Failure {
                    status,
                    body: None,
                    message: message.map(str::to_owned),
                }
            } else {
                Failure {
                    status,
                    body: (case["type"].is_string() || message.is_some()).then(
                        || json!({"error": {"type": case["type"], "message": case["message"]}}),
                    ),
                    message: None,
                }
            };
            assert_eq!(
                failure.sentence(case["fallback"].as_str().unwrap()),
                case["sentence"].as_str().unwrap(),
                "{case}"
            );
        }
    }

    /// `METHOD path` and the JSON body of every request the fake gateway saw.
    fn recorded(seen: &Arc<Mutex<Vec<String>>>) -> Vec<(String, Option<Value>)> {
        seen.lock()
            .unwrap()
            .iter()
            .map(|request| {
                let line = request.lines().next().unwrap_or_default();
                let call = line.trim_end_matches(" HTTP/1.1").to_owned();
                let body = request
                    .split_once("\r\n\r\n")
                    .and_then(|(_, body)| serde_json::from_str(body.trim()).ok());
                (call, body)
            })
            .collect()
    }

    /// A plan from the vector with `{id}` and `{deviceName}` filled in.
    fn expand(plan: &Value, id: &str, device_name: &str) -> Vec<(String, Option<Value>)> {
        fn fill(value: &Value, id: &str, name: &str) -> Value {
            match value {
                Value::String(text) => {
                    Value::String(text.replace("{id}", id).replace("{deviceName}", name))
                }
                Value::Object(map) => Value::Object(
                    map.iter()
                        .map(|(k, v)| (k.clone(), fill(v, id, name)))
                        .collect(),
                ),
                other => other.clone(),
            }
        }
        plan.as_array()
            .unwrap()
            .iter()
            .map(|call| {
                (
                    format!(
                        "{} {}",
                        call["method"].as_str().unwrap(),
                        fill(&call["path"], id, device_name).as_str().unwrap()
                    ),
                    call.get("body").map(|body| fill(body, id, device_name)),
                )
            })
            .collect()
    }

    #[tokio::test]
    async fn the_engine_makes_exactly_the_calls_the_shared_plans_name() {
        let vector = vector();
        let plans = &vector["plans"];
        let id = "cnd_ab12cd34ef56";
        let name = "Harness cloud ab12";

        let (gateway, seen) = fake(vec![
            (
                "POST /v1/sandboxes ",
                201,
                r#"{"id":"cnd_ab12cd34ef56","provider":"fleet","state":"started"}"#,
            ),
            ("POST /v1/sandboxes/cnd_ab12cd34ef56/harness ", 200, r#"{}"#),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        auth.create_sandbox().await.unwrap();
        assert_eq!(
            recorded(&seen),
            expand(&plans["create"], id, name),
            "create"
        );

        for (label, state) in [
            ("startWhenPaused", "paused"),
            ("startWhenRunning", "started"),
        ] {
            let get = format!(r#"{{"id":"{id}","state":"{state}"}}"#);
            let get: &'static str = Box::leak(get.into_boxed_str());
            let (gateway, seen) = fake(vec![
                ("GET /v1/sandboxes/cnd_ab12cd34ef56 ", 200, get),
                ("POST /v1/sandboxes/cnd_ab12cd34ef56/start ", 200, r#"{}"#),
                ("POST /v1/sandboxes/cnd_ab12cd34ef56/harness ", 200, r#"{}"#),
            ])
            .await;
            let dir = tempfile::tempdir().unwrap();
            let auth = signed_in(dir.path(), gateway);
            let mut names = BTreeMap::new();
            names.insert(id.to_string(), name.to_string());
            auth.save_device_names(&names);
            auth.start_sandbox(id).await.unwrap();
            assert_eq!(recorded(&seen), expand(&plans[label], id, name), "{label}");
        }

        let (gateway, seen) = fake(vec![
            ("POST /v1/sandboxes/cnd_ab12cd34ef56/stop ", 200, r#"{}"#),
            ("DELETE /v1/sandboxes/cnd_ab12cd34ef56 ", 200, r#"{}"#),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        auth.stop_sandbox(id).await.unwrap();
        auth.delete_sandbox(id).await.unwrap();
        let mut expected = expand(&plans["stop"], id, name);
        expected.extend(expand(&plans["delete"], id, name));
        assert_eq!(recorded(&seen), expected, "stop then delete");

        for never in plans["neverCalled"].as_array().unwrap() {
            let never = never.as_str().unwrap();
            assert!(
                recorded(&seen)
                    .iter()
                    .all(|(call, _)| !call.contains(never)),
                "{never} must never be called"
            );
        }
    }

    fn cloud_device(id: &str, sandbox: Option<&str>, name: &str) -> harness_proto::Device {
        harness_proto::Device {
            id: id.into(),
            name: name.into(),
            platform: "linux".into(),
            last_seen_at: Some(chrono::Utc::now()),
            created_at: Some(chrono::Utc::now()),
            version: None,
            cursor_sdk_version: None,
            capabilities: Vec::new(),
            cloud_sandbox_id: sandbox.map(str::to_owned),
        }
    }

    fn device_watch(
        list: Vec<harness_proto::Device>,
    ) -> watch::Receiver<Vec<harness_proto::Device>> {
        watch::channel(list).1
    }

    fn posts(seen: &Arc<Mutex<Vec<String>>>) -> Vec<String> {
        lines(seen)
            .into_iter()
            .filter(|l| l.starts_with("POST"))
            .collect()
    }

    #[tokio::test]
    async fn ensure_reuses_a_running_sandbox_with_an_online_device_without_posting() {
        let (gateway, seen) = fake(vec![(
            "GET /v1/sandboxes ",
            200,
            r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started","expiresAt":1790000000}]}"#,
        )])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let devices = device_watch(vec![cloud_device(
            "dev-9",
            Some("cnd_1"),
            "Harness cloud 1",
        )]);
        let ensured = auth
            .ensure_sandbox(false, Duration::from_secs(5), devices)
            .await
            .unwrap();
        assert_eq!(ensured.sandbox_id, "cnd_1");
        assert_eq!(ensured.device_id, "dev-9");
        assert_eq!(ensured.device_name, "Harness cloud 1");
        assert!(!ensured.created && !ensured.woke);
        assert_eq!(ensured.expires_at, Some(json!(1790000000)));
        assert_eq!(posts(&seen), Vec::<String>::new(), "no POSTs at all");
    }

    #[tokio::test]
    async fn ensure_wakes_a_paused_sandbox_and_reports_woke() {
        let (gateway, seen) = fake(vec![
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"paused"}]}"#,
            ),
            ("GET /v1/sandboxes/cnd_1 ", 200, r#"{"id":"cnd_1","state":"paused"}"#),
            ("POST /v1/sandboxes/cnd_1/start ", 200, r#"{"state":"started"}"#),
            ("POST /v1/sandboxes/cnd_1/harness ", 200, r#"{}"#),
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started","expiresAt":1790001234}]}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let devices = device_watch(vec![cloud_device(
            "dev-9",
            Some("cnd_1"),
            "Harness cloud 1",
        )]);
        let ensured = auth
            .ensure_sandbox(false, Duration::from_secs(5), devices)
            .await
            .unwrap();
        assert!(ensured.woke && !ensured.created);
        assert_eq!(ensured.expires_at, Some(json!(1790001234)));
        let posts = posts(&seen);
        assert!(
            posts.iter().any(|l| l == "POST /v1/sandboxes/cnd_1/start")
                && posts
                    .iter()
                    .any(|l| l == "POST /v1/sandboxes/cnd_1/harness"),
            "{posts:?}"
        );
    }

    #[tokio::test]
    async fn ensure_without_allow_create_never_creates() {
        let (gateway, seen) = fake(vec![("GET /v1/sandboxes ", 200, r#"{"sandboxes":[]}"#)]).await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let error = auth
            .ensure_sandbox(false, Duration::from_secs(1), device_watch(vec![]))
            .await
            .unwrap_err();
        assert!(error.contains("allowCreate"), "{error}");
        assert!(posts(&seen).is_empty(), "no POST /v1/sandboxes");
    }

    #[tokio::test]
    async fn ensure_with_allow_create_creates_once() {
        let (gateway, seen) = fake(vec![
            ("GET /v1/sandboxes ", 200, r#"{"sandboxes":[]}"#),
            (
                "POST /v1/sandboxes ",
                201,
                r#"{"id":"cnd_new","provider":"fleet","state":"started","expiresAt":1790000000}"#,
            ),
            (
                "GET /v1/sandboxes/cnd_new ",
                200,
                r#"{"id":"cnd_new","state":"started"}"#,
            ),
            ("POST /v1/sandboxes/cnd_new/harness ", 200, r#"{}"#),
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_new","provider":"fleet","state":"started"}]}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let devices = device_watch(vec![cloud_device(
            "dev-9",
            Some("cnd_new"),
            "Harness cloud new",
        )]);
        let ensured = auth
            .ensure_sandbox(true, Duration::from_secs(5), devices)
            .await
            .unwrap();
        assert!(ensured.created && !ensured.woke);
        assert_eq!(ensured.sandbox_id, "cnd_new");
        let creates = lines(&seen)
            .iter()
            .filter(|l| l.as_str() == "POST /v1/sandboxes")
            .count();
        assert_eq!(creates, 1);
    }

    #[tokio::test]
    async fn concurrent_ensures_create_exactly_one_sandbox() {
        let (gateway, seen) = fake(vec![
            ("GET /v1/sandboxes ", 200, r#"{"sandboxes":[]}"#),
            (
                "POST /v1/sandboxes ",
                201,
                r#"{"id":"cnd_1","provider":"fleet","state":"started"}"#,
            ),
            (
                "GET /v1/sandboxes/cnd_1 ",
                200,
                r#"{"id":"cnd_1","state":"started"}"#,
            ),
            ("POST /v1/sandboxes/cnd_1/harness ", 200, r#"{}"#),
            // The first ensure's refresh after creating.
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started"}]}"#,
            ),
            // The second ensure's list, after the first created the sandbox.
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started"}]}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let (tx, rx) = watch::channel(vec![cloud_device(
            "dev-9",
            Some("cnd_1"),
            "Harness cloud 1",
        )]);
        let (a, b) = tokio::join!(
            auth.ensure_sandbox(true, Duration::from_secs(5), rx.clone()),
            auth.ensure_sandbox(true, Duration::from_secs(5), rx),
        );
        a.unwrap();
        b.unwrap();
        drop(tx);
        let creates = lines(&seen)
            .iter()
            .filter(|l| l.as_str() == "POST /v1/sandboxes")
            .count();
        assert_eq!(creates, 1, "{:?}", lines(&seen));
    }

    #[tokio::test]
    async fn ensure_times_out_on_a_name_only_match_and_says_so() {
        let (gateway, seen) = fake(vec![
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_ab12","provider":"fleet","state":"started"}]}"#,
            ),
            (
                "GET /v1/sandboxes/cnd_ab12 ",
                200,
                r#"{"id":"cnd_ab12","state":"started"}"#,
            ),
            ("POST /v1/sandboxes/cnd_ab12/harness ", 200, r#"{}"#),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        // An online device wearing the expected name but no exact id — an
        // old build that predates cloudSandboxId.
        let mut device = cloud_device("dev-old", None, "Harness cloud ab12");
        device.name = "Harness cloud ab12".into();
        let devices = device_watch(vec![device]);
        let error = auth
            .ensure_sandbox(false, Duration::from_millis(300), devices)
            .await
            .unwrap_err();
        assert!(
            error.contains("no device has reported this sandbox id"),
            "{error}"
        );
        assert!(error.contains("\"Harness cloud ab12\""), "{error}");
        assert!(error.contains("unverified name match"), "{error}");
        // It reattached Harness on the running sandbox (setup), never created.
        assert!(
            posts(&seen).iter().all(|l| l != "POST /v1/sandboxes"),
            "{:?}",
            posts(&seen)
        );
    }

    #[tokio::test]
    async fn ensure_joins_a_pending_default_and_reports_created() {
        let (gateway, seen) = fake(vec![
            ("GET /v1/sandboxes ", 200, r#"{"sandboxes":[]}"#),
            (
                "POST /v1/sandboxes ",
                202,
                r#"{"operationId":"op_9","state":"pending"}"#,
            ),
            (
                "POST /v1/sandboxes ",
                202,
                r#"{"operationId":"op_9","state":"pending"}"#,
            ),
            (
                "POST /v1/sandboxes ",
                201,
                r#"{"id":"cnd_1","provider":"fleet","state":"started","role":"harness-default"}"#,
            ),
            ("GET /v1/sandboxes/cnd_1 ", 200, r#"{"id":"cnd_1","state":"started"}"#),
            ("POST /v1/sandboxes/cnd_1/harness ", 200, r#"{}"#),
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started","role":"harness-default"}]}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let devices = device_watch(vec![cloud_device(
            "dev-9",
            Some("cnd_1"),
            "Harness cloud 1",
        )]);
        let ensured = auth
            .ensure_sandbox(true, Duration::from_secs(30), devices)
            .await
            .unwrap();
        assert!(ensured.created && !ensured.woke);
        assert_eq!(ensured.sandbox_id, "cnd_1");
        // Every retry is the SAME role request — never a differently-shaped one.
        let creates: Vec<String> = seen
            .lock()
            .unwrap()
            .iter()
            .filter(|r| r.starts_with("POST /v1/sandboxes "))
            .cloned()
            .collect();
        assert_eq!(creates.len(), 3, "{creates:?}");
        for request in &creates {
            assert!(request.contains(r#""role":"harness-default""#), "{request}");
        }
    }

    #[tokio::test]
    async fn ensure_wakes_a_returned_default_without_creating() {
        let (gateway, seen) = fake(vec![
            ("GET /v1/sandboxes ", 200, r#"{"sandboxes":[]}"#),
            // 200: the account's paused default, returned without waking it.
            (
                "POST /v1/sandboxes ",
                200,
                r#"{"id":"cnd_1","provider":"fleet","state":"paused","role":"harness-default"}"#,
            ),
            ("GET /v1/sandboxes/cnd_1 ", 200, r#"{"id":"cnd_1","state":"paused"}"#),
            ("POST /v1/sandboxes/cnd_1/start ", 200, r#"{"state":"started"}"#),
            ("POST /v1/sandboxes/cnd_1/harness ", 200, r#"{}"#),
            (
                "GET /v1/sandboxes ",
                200,
                r#"{"sandboxes":[{"id":"cnd_1","provider":"fleet","state":"started","expiresAt":1790001234,"role":"harness-default"}]}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let devices = device_watch(vec![cloud_device(
            "dev-9",
            Some("cnd_1"),
            "Harness cloud 1",
        )]);
        let ensured = auth
            .ensure_sandbox(true, Duration::from_secs(5), devices)
            .await
            .unwrap();
        assert!(!ensured.created && ensured.woke);
        assert_eq!(ensured.expires_at, Some(json!(1790001234)));
        let posts = posts(&seen);
        assert!(
            posts.iter().any(|l| l == "POST /v1/sandboxes/cnd_1/start")
                && posts
                    .iter()
                    .any(|l| l == "POST /v1/sandboxes/cnd_1/harness"),
            "{posts:?}"
        );
    }

    #[tokio::test]
    async fn ensure_reports_a_still_pending_default_at_the_deadline() {
        let (gateway, seen) = fake(vec![
            ("GET /v1/sandboxes ", 200, r#"{"sandboxes":[]}"#),
            (
                "POST /v1/sandboxes ",
                202,
                r#"{"operationId":"op_7","state":"pending"}"#,
            ),
        ])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        enable();
        let error = auth
            .ensure_sandbox(true, Duration::from_millis(100), device_watch(vec![]))
            .await
            .unwrap_err();
        assert!(error.contains("still being created"), "{error}");
        assert!(error.contains("op_7"), "{error}");
        // Only same-role retries — never /start or /harness on nothing.
        for line in posts(&seen) {
            assert_eq!(line, "POST /v1/sandboxes");
        }
    }

    #[tokio::test]
    async fn a_meter_the_provider_cannot_report_is_unsupported_not_an_error() {
        let (gateway, _seen) = fake(vec![(
            "GET /v1/sandboxes/cnd_1/meter ",
            501,
            r#"{"error":{"type":"not_implemented","message":"no meter"}}"#,
        )])
        .await;
        let dir = tempfile::tempdir().unwrap();
        let auth = signed_in(dir.path(), gateway);
        let meter = auth.sandbox_meter("cnd_1").await.unwrap();
        assert_eq!(meter, json!({ "supported": false }));
    }
}
