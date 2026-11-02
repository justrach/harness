//! Cloud sandbox rows for Settings → Accounts (the engine's `CodegraffSandboxes`).
//!
//! Pure row text and button rules, so the card stays a thin renderer: a paused fleet sandbox
//! can be started, a running one turned off (or, if Harness was never set up in it, set up), and
//! any of them deleted. A running sandbox costs credit until it is turned off, so
//! [`running_summary`] also drives the always-visible "Cloud sandbox running" strip.
//!
//! Gateways that know sizes say what each sandbox is (vCPU, memory) and what it costs per hour;
//! every view shows that rate ("$0.10/h", summed over running sandboxes) and a create offers the
//! sizes. Older gateways say neither, and every text reads as it did before.

use chrono::{DateTime, Utc};
use serde_json::Value;

/// One sandbox, as the engine sends it. Tolerant of fields added later.
#[derive(Debug, Clone, Default, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffSandbox {
    pub id: String,
    /// `fleet` or `daytona`.
    pub provider: String,
    pub name: Option<String>,
    /// `running` | `starting` | `paused` | `stopping` | `error` (the engine's words).
    pub state: String,
    pub tier: Option<String>,
    pub expires_at: Option<Value>,
    /// Harness was set up in it, so it can show up as a device.
    pub harness: bool,
    /// The name its device registers under; the gateway gives fleet sandboxes no name.
    pub device_name: Option<String>,
    /// The gateway renews its window until it is turned off. `None` when the gateway doesn't
    /// know the setting (read as off).
    pub keep_running: Option<bool>,
    /// Why the last renewal failed; it pauses when its current window ends.
    pub renew_error: Option<String>,
    /// Its machine, when the gateway says.
    pub cpu: Option<f64>,
    #[serde(rename = "memoryGiB")]
    pub memory_gib: Option<f64>,
    #[serde(rename = "diskGiB")]
    pub disk_gib: Option<f64>,
    /// What it costs per hour while running, in micro-USD.
    pub price_per_hour_micro_usd: Option<i64>,
}

/// One size a new sandbox can be.
#[derive(Debug, Clone, Default, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct PersonalSize {
    /// `standard`, `large`, …
    pub id: String,
    pub cpu: u32,
    #[serde(rename = "memoryGiB")]
    pub memory_gib: u32,
    #[serde(rename = "diskGiB")]
    pub disk_gib: u32,
    pub price_per_hour_micro_usd: Option<i64>,
    pub default: bool,
}

/// `enabled: false` means this build doesn't offer cloud sandboxes.
#[derive(Debug, Clone, Default, serde::Deserialize, PartialEq)]
#[serde(default)]
pub struct CodegraffSandboxes {
    pub enabled: bool,
    pub sandboxes: Vec<CodegraffSandbox>,
    /// The sizes a new sandbox can be; empty on gateways without sizes (no size choice shown).
    pub sizes: Vec<PersonalSize>,
}

/// What a create says it costs, under the size choice.
pub const CREATE_COPY: &str =
    "Keeps running until you turn it off. Billed per second from your Codegraff credit.";

/// Temporary API/tool machines are deliberately separate from persistent Harness devices.
pub const TEMPORARY_COPY: &str = "For API and tool tasks, not a Harness device. Uses our fleet with Daytona fallback. Fleet sandboxes are deleted after 30 minutes; Daytona auto-stops after 30 idle minutes. Delete when done. Billed from your Codegraff credit.";

pub fn is_temporary(sandbox: &CodegraffSandbox) -> bool {
    sandbox.tier.as_deref() == Some("ephemeral")
}

/// An hourly price: "$0.10/h", "$0.125/h", "$1.50/h". Pure.
pub fn format_rate(micro_usd: i64) -> String {
    let dollars = micro_usd.max(0) as f64 / 1_000_000.0;
    let mut text = format!("{dollars:.3}");
    // Cents always show; a third decimal only when it says something.
    if text.ends_with('0') {
        text.pop();
    }
    format!("${text}/h")
}

/// "4 GB", "0.5 GB".
fn format_gb(gib: f64) -> String {
    if gib.fract() == 0.0 {
        format!("{gib:.0} GB")
    } else {
        format!("{} GB", (gib * 10.0).round() / 10.0)
    }
}

/// "2 vCPU · 4 GB" when both are known. Pure.
pub fn machine_spec(cpu: Option<f64>, memory_gib: Option<f64>) -> Option<String> {
    let (cpu, memory) = (cpu.filter(|c| *c > 0.0)?, memory_gib.filter(|m| *m > 0.0)?);
    let cpu = if cpu.fract() == 0.0 {
        format!("{cpu:.0}")
    } else {
        cpu.to_string()
    };
    Some(format!("{cpu} vCPU · {}", format_gb(memory)))
}

/// "Standard", "Large", or the id capitalised. Pure.
pub fn size_title(size: &PersonalSize) -> String {
    capitalize(size.id.trim())
}

/// "2 vCPU · 4 GB · 40 GB · $0.10/h". Pure.
pub fn size_detail(size: &PersonalSize) -> String {
    let mut parts = vec![
        machine_spec(Some(f64::from(size.cpu)), Some(f64::from(size.memory_gib)))
            .unwrap_or_default(),
    ];
    if size.disk_gib > 0 {
        parts.push(format_gb(f64::from(size.disk_gib)));
    }
    if let Some(price) = size.price_per_hour_micro_usd {
        parts.push(format_rate(price));
    }
    parts.retain(|part| !part.is_empty());
    parts.join(" · ")
}

/// The size a create uses: the one picked, else the default (else the first). `None` when the
/// gateway offers no sizes. Pure.
pub fn selected_size<'a>(
    sizes: &'a [PersonalSize],
    picked: Option<&str>,
) -> Option<&'a PersonalSize> {
    picked
        .and_then(|id| sizes.iter().find(|s| s.id == id))
        .or_else(|| sizes.iter().find(|s| s.default))
        .or_else(|| sizes.first())
}

/// What the running (and starting) sandboxes cost together per hour, when every one of them
/// says. Pure.
pub fn running_rate(list: &CodegraffSandboxes) -> Option<i64> {
    let live: Vec<&CodegraffSandbox> = list
        .sandboxes
        .iter()
        .filter(|s| matches!(s.state.as_str(), "running" | "starting"))
        .collect();
    if live.is_empty() {
        return None;
    }
    live.iter()
        .map(|s| s.price_per_hour_micro_usd)
        .sum::<Option<i64>>()
}

pub fn sandbox_title(sandbox: &CodegraffSandbox) -> String {
    [&sandbox.name, &sandbox.device_name]
        .into_iter()
        .flatten()
        .map(|name| name.trim())
        .find(|name| !name.is_empty())
        .unwrap_or(if is_temporary(sandbox) {
            "Temporary sandbox"
        } else {
            "Cloud sandbox"
        })
        .to_string()
}

/// A display label only: routing always keeps the original device ID. Cloud
/// titles replace registration names only when the gateway reports a unique,
/// explicit association. Paused/offline computers retain their recognizable name.
pub fn friendly_device_name(state: &crate::state::AppState, device_id: &str) -> String {
    if state.local_device_id.as_deref() == Some(device_id) {
        return if cfg!(target_os = "macos") {
            "This Mac"
        } else {
            "This device"
        }
        .into();
    }
    let Some(device) = state.devices.iter().find(|device| device.id == device_id) else {
        return "Unknown device".into();
    };
    cloud_device_display_name(device, &state.devices, state.cloud_sandboxes())
        .unwrap_or_else(|| {
            let name = device.name.trim();
            if name.is_empty() {
                "Unknown device"
            } else {
                name
            }
        })
        .to_owned()
}

fn cloud_device_display_name<'a>(
    device: &harness_proto::Device,
    devices: &[harness_proto::Device],
    list: Option<&'a CodegraffSandboxes>,
) -> Option<&'a str> {
    if device.platform != "linux"
        || device.name.trim().is_empty()
        || devices.iter().filter(|other| other.id == device.id).count() != 1
        || devices
            .iter()
            .filter(|other| other.platform == "linux" && other.name == device.name)
            .count()
            != 1
    {
        return None;
    }
    let mut matches = list
        .filter(|list| list.enabled)?
        .sandboxes
        .iter()
        .filter(|sandbox| {
            sandbox.device_name.as_deref().map(str::trim) == Some(device.name.as_str())
        });
    let sandbox = matches.next()?;
    if matches.next().is_some()
        || sandbox.provider != "fleet"
        || !sandbox.harness
        || is_temporary(sandbox)
    {
        return None;
    }
    sandbox
        .name
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
}

/// Only our own (fleet) sandboxes have Harness set up in them: a paused one is started, and a
/// running one that never got Harness (a create that half-failed) is set up again.
pub fn can_start(sandbox: &CodegraffSandbox) -> bool {
    sandbox.provider == "fleet"
        && !is_temporary(sandbox)
        && (sandbox.state == "paused" || (sandbox.state == "running" && !sandbox.harness))
}

/// The button's label and its in-progress label.
pub fn start_labels(sandbox: &CodegraffSandbox) -> (&'static str, &'static str) {
    if sandbox.state == "running" {
        ("Set up Harness", "Setting up…")
    } else {
        ("Start", "Starting…")
    }
}

pub fn can_stop(sandbox: &CodegraffSandbox) -> bool {
    sandbox.state == "running" && !is_temporary(sandbox)
}

/// The turn-off button's label, its in-progress label, and what it does.
pub const TURN_OFF: (&str, &str) = ("Turn off", "Turning off…");
pub const TURN_OFF_HINT: &str = "Pauses it. Memory and files are kept; billing stops.";

/// A running fleet sandbox the gateway says will pause when its window ends can be kept
/// running again (after a failed renewal, say). Gateways that don't know the setting say
/// nothing, so nothing is offered.
pub fn can_keep_running(sandbox: &CodegraffSandbox) -> bool {
    sandbox.provider == "fleet"
        && !is_temporary(sandbox)
        && sandbox.state == "running"
        && sandbox.keep_running == Some(false)
}

fn keeps_running(sandbox: &CodegraffSandbox) -> bool {
    sandbox.keep_running == Some(true) && renew_problem(sandbox).is_none()
}

/// The renewal failure in the app's words.
fn renew_problem(sandbox: &CodegraffSandbox) -> Option<&'static str> {
    let error = sandbox.renew_error.as_deref().map(str::trim)?;
    Some(match error {
        "" => return None,
        "insufficient_credit" | "insufficient_credits" => "Out of credit",
        "key_budget" => "Key budget reached",
        _ => "Couldn't renew",
    })
}

/// When a running sandbox stops on its own: "keeps running until you turn it off", "pauses in
/// 24 min", or a failed renewal ("Out of credit — pauses in 4 min"). `None` when unknown.
fn running_outlook(sandbox: &CodegraffSandbox, now: DateTime<Utc>) -> Option<String> {
    if is_temporary(sandbox) {
        return Some(if sandbox.provider == "fleet" {
            sandbox
                .expires_at
                .as_ref()
                .and_then(|at| lease_remaining(at, now))
                .map(|lease| lease.replace("pauses", "deletes"))
                .unwrap_or_else(|| "temporary — delete when done".into())
        } else {
            "auto-stops after 30 idle min; delete when done".into()
        });
    }
    let lease = sandbox
        .expires_at
        .as_ref()
        .and_then(|at| lease_remaining(at, now));
    match (renew_problem(sandbox), lease) {
        (Some(problem), Some(lease)) => Some(format!("{problem} — {lease}")),
        (Some(problem), None) => Some(problem.to_string()),
        _ if keeps_running(sandbox) => Some("keeps running until you turn it off".to_string()),
        (None, lease) => lease,
    }
}

/// "Running · Harness ready · keeps running until you turn it off". Pure.
pub fn sandbox_detail(sandbox: &CodegraffSandbox, now: DateTime<Utc>) -> String {
    let mut parts = vec![match sandbox.state.as_str() {
        "running" => "Running".to_string(),
        "starting" => "Starting…".to_string(),
        // A fleet pause keeps the machine's memory and disk.
        "paused" if sandbox.provider == "fleet" => "Paused — memory and files kept".to_string(),
        "paused" => "Paused".to_string(),
        "stopping" => "Stopping…".to_string(),
        "error" => "Error".to_string(),
        other if other.is_empty() || other == "unknown" => "Unknown state".to_string(),
        other => other.to_string(),
    }];
    if sandbox.state == "running" {
        let spec = machine_spec(sandbox.cpu, sandbox.memory_gib);
        let rate = sandbox.price_per_hour_micro_usd.map(format_rate);
        // With its machine and rate to say, a ready sandbox goes without "Harness ready".
        if is_temporary(sandbox) {
            parts.push(
                if sandbox.provider == "fleet" {
                    "Temporary · Our fleet"
                } else {
                    "Temporary · Daytona"
                }
                .into(),
            );
        } else if !sandbox.harness {
            parts.push("Harness not set up".into());
        } else if spec.is_none() && rate.is_none() {
            parts.push("Harness ready".into());
        }
        parts.extend(spec);
        parts.extend(rate);
        if let Some(outlook) = running_outlook(sandbox, now) {
            parts.push(outlook);
        }
    }
    parts.join(" · ")
}

/// Detail-card copy separates lifecycle from the compact state label. Only reported
/// pricing and known persistence guarantees are shown; temporary jobs are never devices.
pub fn computer_lifecycle(sandbox: &CodegraffSandbox, now: DateTime<Utc>) -> String {
    if is_temporary(sandbox) {
        return if sandbox.provider == "fleet" {
            "Temporary task machine, not a Harness computer. Deleted after 30 minutes. Manage it to copy its ID or delete it sooner.".into()
        } else {
            "Temporary task machine, not a Harness computer. Stops after 30 idle minutes. Manage it to copy its ID or delete it.".into()
        };
    }
    match sandbox.state.as_str() {
        "paused" if sandbox.provider == "fleet" => "Memory and files are kept. Billing is paused. Start it when you’re ready to work again.".into(),
        "starting" => "Your computer is starting. This status updates as it becomes ready.".into(),
        "stopping" => "Your computer is turning off. Wait for the paused status before assuming billing has stopped.".into(),
        "running" => {
            if let Some(problem) = renew_problem(sandbox) {
                let ending = running_outlook(sandbox,now).unwrap_or_else(|| problem.into());
                return format!("{ending}. Check your Codegraff credit in Accounts. The computer may pause when its current window ends.");
            }
            let outlook=running_outlook(sandbox,now).map(|v|capitalize(&v)).unwrap_or_else(||"Running on your Codegraff account".into());
            if sandbox.provider == "fleet" {
                format!("{outlook}. Billed per second while running. Turning it off keeps memory and files.")
            } else {
                format!("{outlook}. Billed per second while running.")
            }
        }
        "error" => "The computer reported an error. Open Accounts to inspect or manage it.".into(),
        _ => "The current state is not available. Open Accounts to refresh and manage this computer.".into(),
    }
}

const BILLED: &str = "Billed per second until you turn it off";

/// What the always-visible strip says while sandboxes cost credit.
#[derive(Debug, Clone, PartialEq)]
pub struct RunningSummary {
    /// "Cloud sandbox running · $0.10/h" / "2 cloud sandboxes running · $0.20/h" (the rate when
    /// every running sandbox says what it costs).
    pub label: String,
    /// "Billed per second until you turn it off", "Pauses in 24 min", or a failed renewal.
    pub detail: String,
    /// The detail is a problem (a failed renewal): show it in the warning color.
    pub warning: bool,
    /// What "Turn off" pauses: every running sandbox.
    pub running_ids: Vec<String>,
}

/// `None` while nothing is running (or starting): the strip is hidden. Every provider counts,
/// since every running sandbox is billed. Pure.
pub fn running_summary(list: &CodegraffSandboxes, now: DateTime<Utc>) -> Option<RunningSummary> {
    if !list.enabled {
        return None;
    }
    let live: Vec<&CodegraffSandbox> = list
        .sandboxes
        .iter()
        .filter(|s| matches!(s.state.as_str(), "running" | "starting"))
        .collect();
    if live.is_empty() {
        return None;
    }
    let mut label = match live.len() {
        1 if live[0].state == "starting" => "Cloud sandbox starting".to_string(),
        1 => "Cloud sandbox running".to_string(),
        n => format!("{n} cloud sandboxes running"),
    };
    if let Some(rate) = running_rate(list) {
        label = format!("{label} · {}", format_rate(rate));
    }
    let running: Vec<&CodegraffSandbox> = live.iter().copied().filter(|s| can_stop(s)).collect();
    // The most pressing word wins: a failed renewal, then a window about to end, then billing.
    let problem = running
        .iter()
        .find(|s| renew_problem(s).is_some())
        .and_then(|s| running_outlook(s, now));
    let temporary = live.iter().any(|s| is_temporary(s));
    let (detail, warning) = match problem {
        Some(problem) => (problem, true),
        None if temporary && live.len() == 1 => (
            capitalize(
                &running_outlook(live[0], now).unwrap_or_else(|| "Temporary sandbox".into()),
            ),
            false,
        ),
        None if temporary => (
            "Includes temporary sandboxes — manage in Settings".into(),
            false,
        ),
        None => match running
            .iter()
            .find(|s| !keeps_running(s))
            .and_then(|s| running_outlook(s, now))
        {
            Some(lease) if lease.starts_with("pauses") => (capitalize(&lease), false),
            _ => (BILLED.to_string(), false),
        },
    };
    Some(RunningSummary {
        label,
        detail,
        warning,
        // A mixed list must not imply "Turn off" stops temporary machines too. The strip
        // opens Settings, where each temporary sandbox has an explicit Delete action.
        running_ids: if temporary {
            Vec::new()
        } else {
            running.iter().map(|s| s.id.clone()).collect()
        },
    })
}

/// The collapsed-sidebar chip's hover text: "Cloud sandbox running — billed per second", or
/// the summary's own news ("… — Out of credit — pauses in 4 min"). Pure.
pub fn compact_tooltip(summary: &RunningSummary) -> String {
    if summary.detail == BILLED {
        format!("{} — billed per second", summary.label)
    } else {
        format!("{} — {}", summary.label, summary.detail)
    }
}

/// Anything running, starting or stopping changes on its own (billing, renewals, pauses), so
/// the list is re-read while one is. Pure.
pub fn needs_refresh(list: &CodegraffSandboxes) -> bool {
    list.enabled
        && list
            .sandboxes
            .iter()
            .any(|s| matches!(s.state.as_str(), "running" | "starting" | "stopping"))
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn lease_remaining(expires_at: &Value, now: DateTime<Utc>) -> Option<String> {
    let at = match expires_at {
        Value::String(text) => DateTime::parse_from_rfc3339(text).ok()?.with_timezone(&Utc),
        Value::Number(seconds) => DateTime::from_timestamp(seconds.as_i64()?, 0)?,
        _ => return None,
    };
    let minutes = (at - now).num_minutes();
    Some(match minutes {
        m if m < 0 => "lease ended".to_string(),
        0 => "pauses in under a minute".to_string(),
        m if m < 60 => format!("pauses in {m} min"),
        m => format!("pauses in {}h {}m", m / 60, m % 60),
    })
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    fn at(h: u32, m: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 1, h, m, 0).unwrap()
    }

    fn sandbox(state: &str, harness: bool, expires: Option<&str>) -> CodegraffSandbox {
        CodegraffSandbox {
            id: "cnd_1".into(),
            provider: "fleet".into(),
            name: Some("Harness cloud".into()),
            state: state.into(),
            expires_at: expires.map(|e| Value::String(e.into())),
            harness,
            device_name: None,
            keep_running: None,
            renew_error: None,
            ..Default::default()
        }
    }

    fn kept(expires: &str, renew_error: Option<&str>) -> CodegraffSandbox {
        CodegraffSandbox {
            keep_running: Some(renew_error.is_none()),
            renew_error: renew_error.map(str::to_owned),
            ..sandbox("running", true, Some(expires))
        }
    }

    fn named_cloud_device() -> harness_proto::Device {
        serde_json::from_value(serde_json::json!({
            "id": "studio-device",
            "name": "harness-cloud-studio",
            "platform": "linux"
        }))
        .unwrap()
    }

    fn named_cloud_list() -> CodegraffSandboxes {
        CodegraffSandboxes {
            enabled: true,
            sandboxes: vec![CodegraffSandbox {
                name: Some("Studio computer".into()),
                device_name: Some("harness-cloud-studio".into()),
                ..sandbox("paused", true, None)
            }],
            ..Default::default()
        }
    }

    #[test]
    fn friendly_device_name_uses_only_an_explicit_unique_cloud_association() {
        let device = named_cloud_device();
        let devices = vec![device.clone()];
        let mut list = named_cloud_list();
        // A paused computer keeps the same recognizable label.
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&list)),
            Some("Studio computer")
        );
        list.sandboxes[0].state = "running".into();
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&list)),
            Some("Studio computer")
        );
        list.sandboxes[0].device_name = None;
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&list)),
            None
        );
        list.sandboxes[0].device_name = Some("a-different-device".into());
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&list)),
            None
        );
        assert_eq!(cloud_device_display_name(&device, &devices, None), None);
        let mut non_linux = device;
        non_linux.platform = "macos".into();
        assert_eq!(
            cloud_device_display_name(&non_linux, &[non_linux.clone()], Some(&named_cloud_list())),
            None
        );
    }

    #[test]
    fn friendly_device_name_rejects_ambiguous_or_unusable_cloud_labels() {
        let device = named_cloud_device();
        let devices = vec![device.clone()];
        let list = named_cloud_list();
        let mut duplicate_device = device.clone();
        duplicate_device.id = "other-device".into();
        assert_eq!(
            cloud_device_display_name(&device, &[device.clone(), duplicate_device], Some(&list)),
            None
        );
        let mut duplicate_list = list.clone();
        duplicate_list.sandboxes.push(list.sandboxes[0].clone());
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&duplicate_list)),
            None
        );
        let mut invalid = list.clone();
        invalid.enabled = false;
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&invalid)),
            None
        );
        invalid = list.clone();
        invalid.sandboxes[0].name = Some("   ".into());
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&invalid)),
            None
        );
        invalid = list.clone();
        invalid.sandboxes[0].provider = "daytona".into();
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&invalid)),
            None
        );
        invalid = list.clone();
        invalid.sandboxes[0].harness = false;
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&invalid)),
            None
        );
        invalid = list;
        invalid.sandboxes[0].tier = Some("ephemeral".into());
        assert_eq!(
            cloud_device_display_name(&device, &devices, Some(&invalid)),
            None
        );
    }

    #[test]
    fn friendly_device_name_preserves_local_and_unassociated_device_identity() {
        let mut state = crate::state::AppState::new();
        state.local_device_id = Some("local".into());
        state.devices.push(named_cloud_device());
        assert_eq!(
            friendly_device_name(&state, "studio-device"),
            "harness-cloud-studio"
        );
        assert_eq!(friendly_device_name(&state, "missing"), "Unknown device");
        assert_eq!(
            friendly_device_name(&state, "local"),
            if cfg!(target_os = "macos") {
                "This Mac"
            } else {
                "This device"
            }
        );
    }

    #[test]
    fn temporary_sandboxes_are_not_persistent_harness_devices() {
        let mut temporary = sandbox("running", false, Some("2026-10-01T12:30:00Z"));
        temporary.tier = Some("ephemeral".into());
        temporary.keep_running = Some(false);
        temporary.name = None;
        assert_eq!(sandbox_title(&temporary), "Temporary sandbox");
        assert!(!can_start(&temporary));
        assert!(!can_stop(&temporary));
        assert!(!can_keep_running(&temporary));
        assert_eq!(
            sandbox_detail(&temporary, at(12, 0)),
            "Running · Temporary · Our fleet · deletes in 30 min"
        );
        let mut list = CodegraffSandboxes {
            enabled: true,
            sandboxes: vec![temporary.clone()],
            sizes: vec![],
        };
        let summary = running_summary(&list, at(12, 0)).unwrap();
        assert_eq!(summary.detail, "Deletes in 30 min");
        assert!(summary.running_ids.is_empty());
        list.sandboxes.push(kept("2026-10-01T12:30:00Z", None));
        assert!(
            running_summary(&list, at(12, 0))
                .unwrap()
                .running_ids
                .is_empty()
        );
        temporary.provider = "daytona".into();
        temporary.expires_at = None;
        assert_eq!(
            sandbox_detail(&temporary, at(12, 0)),
            "Running · Temporary · Daytona · auto-stops after 30 idle min; delete when done"
        );
        assert!(!can_stop(&temporary));
        assert!(!can_start(&temporary));
    }

    #[test]
    fn kept_running_rows_say_so_instead_of_counting_down() {
        assert_eq!(
            sandbox_detail(&kept("2026-10-01T12:24:00Z", None), at(12, 0)),
            "Running · Harness ready · keeps running until you turn it off"
        );
        // Keep-running off on a gateway that knows it: the countdown, as before.
        let mut off = kept("2026-10-01T12:24:00Z", None);
        off.keep_running = Some(false);
        assert_eq!(
            sandbox_detail(&off, at(12, 0)),
            "Running · Harness ready · pauses in 24 min"
        );
    }

    #[test]
    fn failed_renewals_say_why_and_when_it_pauses() {
        for (error, words) in [
            ("insufficient_credit", "Out of credit"),
            ("key_budget", "Key budget reached"),
            ("fleet_unavailable", "Couldn't renew"),
            ("something_new", "Couldn't renew"),
        ] {
            assert_eq!(
                sandbox_detail(&kept("2026-10-01T12:04:00Z", Some(error)), at(12, 0)),
                format!("Running · Harness ready · {words} — pauses in 4 min"),
                "{error}"
            );
        }
        let mut no_expiry = kept("x", Some("insufficient_credit"));
        no_expiry.expires_at = None;
        assert_eq!(
            sandbox_detail(&no_expiry, at(12, 0)),
            "Running · Harness ready · Out of credit"
        );
        // A renew error wins over a keep-running flag that hasn't caught up.
        let mut both = kept("2026-10-01T12:04:00Z", Some("key_budget"));
        both.keep_running = Some(true);
        assert!(sandbox_detail(&both, at(12, 0)).ends_with("Key budget reached — pauses in 4 min"));
    }

    #[test]
    fn only_running_fleet_sandboxes_that_will_pause_offer_keep_running() {
        let mut off = kept("2026-10-01T12:04:00Z", Some("insufficient_credit"));
        assert!(can_keep_running(&off));
        off.provider = "daytona".into();
        assert!(!can_keep_running(&off));
        assert!(!can_keep_running(&kept("2026-10-01T12:04:00Z", None)));
        assert!(
            !can_keep_running(&sandbox("running", true, None)),
            "older gateways say nothing, so nothing is offered"
        );
        let mut paused = sandbox("paused", true, None);
        paused.keep_running = Some(false);
        assert!(!can_keep_running(&paused));
    }

    fn list(sandboxes: Vec<CodegraffSandbox>) -> CodegraffSandboxes {
        CodegraffSandboxes {
            enabled: true,
            sandboxes,
            sizes: Vec::new(),
        }
    }

    #[test]
    fn the_strip_shows_only_while_something_runs() {
        let now = at(12, 0);
        assert_eq!(running_summary(&list(vec![]), now), None);
        assert_eq!(
            running_summary(&list(vec![sandbox("paused", true, None)]), now),
            None
        );
        let mut off = list(vec![kept("2026-10-01T12:24:00Z", None)]);
        off.enabled = false;
        assert_eq!(running_summary(&off, now), None, "feature off");
        assert!(!needs_refresh(&off));

        let one = running_summary(&list(vec![kept("2026-10-01T12:24:00Z", None)]), now).unwrap();
        assert_eq!(one.label, "Cloud sandbox running");
        assert_eq!(one.detail, "Billed per second until you turn it off");
        assert!(!one.warning);
        assert_eq!(one.running_ids, ["cnd_1"]);
    }

    #[test]
    fn the_strip_puts_the_most_pressing_word_first() {
        let now = at(12, 0);
        let mut other = kept("2026-10-01T12:24:00Z", None);
        other.id = "cnd_2".into();
        let failing = kept("2026-10-01T12:04:00Z", Some("insufficient_credit"));
        let two = running_summary(&list(vec![other.clone(), failing]), now).unwrap();
        assert_eq!(two.label, "2 cloud sandboxes running");
        assert_eq!(two.detail, "Out of credit — pauses in 4 min");
        assert!(two.warning);
        assert_eq!(two.running_ids, ["cnd_2", "cnd_1"]);

        // An older gateway: no keep-running word, so the window's end is the news.
        let old = running_summary(
            &list(vec![sandbox("running", true, Some("2026-10-01T12:24:00Z"))]),
            now,
        )
        .unwrap();
        assert_eq!(old.detail, "Pauses in 24 min");
        assert!(!old.warning);

        let starting = running_summary(&list(vec![sandbox("starting", false, None)]), now).unwrap();
        assert_eq!(starting.label, "Cloud sandbox starting");
        assert!(starting.running_ids.is_empty(), "nothing to turn off yet");
    }

    #[test]
    fn the_collapsed_chip_says_what_it_costs_or_what_is_wrong() {
        let now = at(12, 0);
        let one = running_summary(&list(vec![kept("2026-10-01T12:24:00Z", None)]), now).unwrap();
        assert_eq!(
            compact_tooltip(&one),
            "Cloud sandbox running — billed per second"
        );
        let failing = running_summary(
            &list(vec![kept(
                "2026-10-01T12:04:00Z",
                Some("insufficient_credit"),
            )]),
            now,
        )
        .unwrap();
        assert_eq!(
            compact_tooltip(&failing),
            "Cloud sandbox running — Out of credit — pauses in 4 min"
        );
    }

    #[test]
    fn the_list_is_re_read_only_while_something_can_change_on_its_own() {
        assert!(!needs_refresh(&list(vec![sandbox("paused", true, None)])));
        for state in ["running", "starting", "stopping"] {
            assert!(
                needs_refresh(&list(vec![sandbox(state, true, None)])),
                "{state}"
            );
        }
    }

    #[test]
    fn running_rows_show_harness_and_when_the_lease_ends() {
        let running = sandbox("running", true, Some("2026-10-01T12:24:00Z"));
        assert_eq!(
            sandbox_detail(&running, at(12, 0)),
            "Running · Harness ready · pauses in 24 min"
        );
        let long = sandbox("running", true, Some("2026-10-01T14:05:00Z"));
        assert!(sandbox_detail(&long, at(12, 0)).ends_with("pauses in 2h 5m"));
        let late = sandbox("running", false, Some("2026-10-01T11:00:00Z"));
        assert_eq!(
            sandbox_detail(&late, at(12, 0)),
            "Running · Harness not set up · lease ended"
        );
    }

    #[test]
    fn paused_rows_say_their_state_is_kept() {
        let paused = sandbox("paused", true, Some("2026-10-01T12:24:00Z"));
        assert_eq!(
            sandbox_detail(&paused, at(12, 0)),
            "Paused — memory and files kept"
        );
        let mut daytona = paused.clone();
        daytona.provider = "daytona".into();
        assert_eq!(sandbox_detail(&daytona, at(12, 0)), "Paused");
    }

    #[test]
    fn expiry_can_be_unix_seconds_and_bad_values_are_ignored() {
        let mut s = sandbox("running", false, None);
        s.expires_at = Some(serde_json::json!(at(12, 10).timestamp()));
        assert!(sandbox_detail(&s, at(12, 0)).ends_with("pauses in 10 min"));
        s.expires_at = Some(serde_json::json!("soon"));
        assert_eq!(
            sandbox_detail(&s, at(12, 0)),
            "Running · Harness not set up"
        );
    }

    #[test]
    fn in_between_states_have_no_buttons_and_say_what_is_happening() {
        for state in ["starting", "stopping", "error"] {
            let s = sandbox(state, false, None);
            assert!(!can_start(&s) && !can_stop(&s), "{state}");
        }
        assert_eq!(
            sandbox_detail(&sandbox("starting", false, None), at(12, 0)),
            "Starting…"
        );
        assert_eq!(
            sandbox_detail(&sandbox("stopping", false, None), at(12, 0)),
            "Stopping…"
        );
    }

    #[test]
    fn a_running_sandbox_without_harness_offers_setup_instead_of_start() {
        let unready = sandbox("running", false, None);
        assert!(can_start(&unready));
        assert_eq!(start_labels(&unready), ("Set up Harness", "Setting up…"));
        assert_eq!(
            start_labels(&sandbox("paused", true, None)),
            ("Start", "Starting…")
        );
    }

    #[test]
    fn only_startable_fleet_sandboxes_start_and_only_running_ones_stop() {
        assert!(can_start(&sandbox("paused", true, None)));
        assert!(!can_start(&sandbox("running", true, None)));
        let mut daytona = sandbox("paused", false, None);
        daytona.provider = "daytona".into();
        assert!(!can_start(&daytona));
        assert!(can_stop(&sandbox("running", true, None)));
        assert!(!can_stop(&sandbox("paused", true, None)));
    }

    #[test]
    fn titles_fall_back_and_the_engine_answer_parses() {
        let mut s = sandbox("running", true, None);
        s.name = Some("  ".into());
        assert_eq!(sandbox_title(&s), "Cloud sandbox");
        s.device_name = Some("Harness cloud ab12".into());
        assert_eq!(
            sandbox_title(&s),
            "Harness cloud ab12",
            "the gateway gives no name"
        );
        let parsed: Option<CodegraffSandboxes> = serde_json::from_value(serde_json::json!({
            "enabled": true,
            "sandboxes": [{"id": "cnd_1", "provider": "fleet", "state": "paused", "future": 1}]
        }))
        .unwrap();
        let parsed = parsed.unwrap();
        assert!(parsed.enabled);
        assert_eq!(parsed.sandboxes[0].state, "paused");
        let off: Option<CodegraffSandboxes> =
            serde_json::from_value(serde_json::json!({})).unwrap();
        assert!(!off.unwrap().enabled);
    }

    fn priced(id: &str, state: &str, price: Option<i64>) -> CodegraffSandbox {
        CodegraffSandbox {
            id: id.into(),
            keep_running: Some(true),
            price_per_hour_micro_usd: price,
            cpu: Some(2.0),
            memory_gib: Some(4.0),
            ..sandbox(state, true, None)
        }
    }

    #[test]
    fn rates_read_as_dollars_per_hour() {
        assert_eq!(format_rate(100_000), "$0.10/h");
        assert_eq!(format_rate(125_000), "$0.125/h");
        assert_eq!(format_rate(2_000_000), "$2.00/h");
        assert_eq!(format_rate(-5), "$0.00/h");
        assert_eq!(
            machine_spec(Some(2.0), Some(4.0)).as_deref(),
            Some("2 vCPU · 4 GB")
        );
        assert_eq!(
            machine_spec(Some(0.5), Some(0.5)).as_deref(),
            Some("0.5 vCPU · 0.5 GB")
        );
        assert_eq!(machine_spec(Some(2.0), None), None);
        assert_eq!(machine_spec(None, Some(4.0)), None);
    }

    #[test]
    fn running_rows_show_the_machine_and_rate_instead_of_harness_ready() {
        let row = priced("cnd_1", "running", Some(100_000));
        assert_eq!(
            sandbox_detail(&row, at(12, 0)),
            "Running · 2 vCPU · 4 GB · $0.10/h · keeps running until you turn it off"
        );
        let mut unready = row.clone();
        unready.harness = false;
        assert!(
            sandbox_detail(&unready, at(12, 0))
                .starts_with("Running · Harness not set up · 2 vCPU · 4 GB · $0.10/h")
        );
        let mut unpriced = row.clone();
        unpriced.price_per_hour_micro_usd = None;
        assert_eq!(
            sandbox_detail(&unpriced, at(12, 0)),
            "Running · 2 vCPU · 4 GB · keeps running until you turn it off"
        );
    }

    #[test]
    fn the_strip_adds_the_summed_rate_only_when_every_running_one_has_a_price() {
        let now = at(12, 0);
        let one = running_summary(&list(vec![priced("a", "running", Some(100_000))]), now).unwrap();
        assert_eq!(one.label, "Cloud sandbox running · $0.10/h");
        assert_eq!(
            compact_tooltip(&one),
            "Cloud sandbox running · $0.10/h — billed per second"
        );
        let two = running_summary(
            &list(vec![
                priced("a", "running", Some(100_000)),
                priced("b", "running", Some(200_000)),
                priced("c", "paused", Some(900_000)),
            ]),
            now,
        )
        .unwrap();
        assert_eq!(two.label, "2 cloud sandboxes running · $0.30/h");
        let partly = list(vec![
            priced("a", "running", Some(100_000)),
            priced("b", "running", None),
        ]);
        assert_eq!(running_rate(&partly), None);
        assert_eq!(
            running_summary(&partly, now).unwrap().label,
            "2 cloud sandboxes running"
        );
        let starting =
            running_summary(&list(vec![priced("a", "starting", Some(100_000))]), now).unwrap();
        assert_eq!(starting.label, "Cloud sandbox starting · $0.10/h");
        assert_eq!(running_rate(&list(vec![])), None);
    }

    #[test]
    fn a_create_offers_the_sizes_with_the_default_preselected() {
        let sizes: Vec<PersonalSize> = serde_json::from_value(serde_json::json!([
            {"id": "standard", "cpu": 2, "memoryGiB": 4, "diskGiB": 40,
             "pricePerHourMicroUsd": 100000, "default": true},
            {"id": "large", "cpu": 4, "memoryGiB": 8, "diskGiB": 40,
             "pricePerHourMicroUsd": 200000}
        ]))
        .unwrap();
        assert_eq!(selected_size(&sizes, None).unwrap().id, "standard");
        assert_eq!(selected_size(&sizes, Some("large")).unwrap().id, "large");
        assert_eq!(selected_size(&sizes, Some("gone")).unwrap().id, "standard");
        assert_eq!(selected_size(&[], None), None);
        assert_eq!(size_title(&sizes[1]), "Large");
        assert_eq!(size_detail(&sizes[0]), "2 vCPU · 4 GB · 40 GB · $0.10/h");
        let bare = PersonalSize {
            id: "x".into(),
            cpu: 1,
            memory_gib: 2,
            ..Default::default()
        };
        assert_eq!(size_detail(&bare), "1 vCPU · 2 GB");
        let parsed: CodegraffSandboxes = serde_json::from_value(serde_json::json!({
            "enabled": true, "sandboxes": [], "sizes": sizes_json()
        }))
        .unwrap();
        assert_eq!(parsed.sizes.len(), 2);
    }

    fn sizes_json() -> Value {
        vector()["personalSizes"]["sizes"].clone()
    }

    fn vector() -> Value {
        serde_json::from_str(include_str!(
            "../../../apps/parity/vectors/cloud-sandbox.json"
        ))
        .unwrap()
    }

    #[test]
    fn the_shared_vector_rates_sizes_and_summaries() {
        let vector = vector();
        for case in vector["rates"].as_array().unwrap() {
            assert_eq!(
                format_rate(case["microUsd"].as_i64().unwrap()),
                case["text"].as_str().unwrap()
            );
        }
        for case in vector["sizeChoices"].as_array().unwrap() {
            let size: PersonalSize = serde_json::from_value(case["size"].clone()).unwrap();
            assert_eq!(size_title(&size), case["title"].as_str().unwrap());
            assert_eq!(size_detail(&size), case["detail"].as_str().unwrap());
        }
        let now = DateTime::from_timestamp(vector["now"].as_i64().unwrap(), 0).unwrap();
        for case in vector["summaries"].as_array().unwrap() {
            let list = CodegraffSandboxes {
                enabled: true,
                sandboxes: serde_json::from_value(case["sandboxes"].clone()).unwrap(),
                sizes: Vec::new(),
            };
            let summary = running_summary(&list, now).unwrap();
            assert_eq!(summary.label, case["label"].as_str().unwrap(), "{case}");
            assert_eq!(summary.detail, case["detail"].as_str().unwrap(), "{case}");
            assert_eq!(
                compact_tooltip(&summary),
                case["tooltip"].as_str().unwrap(),
                "{case}"
            );
        }
    }

    #[test]
    fn the_shared_vector_rows() {
        let vector: Value = serde_json::from_str(include_str!(
            "../../../apps/parity/vectors/cloud-sandbox.json"
        ))
        .unwrap();
        let now = DateTime::from_timestamp(vector["now"].as_i64().unwrap(), 0).unwrap();
        for case in vector["rows"].as_array().unwrap() {
            let sandbox: CodegraffSandbox =
                serde_json::from_value(case["sandbox"].clone()).unwrap();
            assert_eq!(
                sandbox_title(&sandbox),
                case["title"].as_str().unwrap(),
                "{case}"
            );
            assert_eq!(
                sandbox_detail(&sandbox, now),
                case["detail"].as_str().unwrap(),
                "{case}"
            );
            assert_eq!(
                can_start(&sandbox),
                case["canStart"].as_bool().unwrap(),
                "{case}"
            );
            assert_eq!(
                can_stop(&sandbox),
                case["canStop"].as_bool().unwrap(),
                "{case}"
            );
            if case["canStart"].as_bool().unwrap() {
                assert_eq!(
                    start_labels(&sandbox).0,
                    case["startLabel"].as_str().unwrap(),
                    "{case}"
                );
            }
        }
    }
}
