//! Cloud sandbox rows for Settings → Accounts (the engine's `CodegraffSandboxes`).
//!
//! Pure row text and button rules, so the card stays a thin renderer: a paused fleet sandbox
//! can be started, a running one stopped (or, if Harness was never set up in it, set up), and
//! any of them deleted.

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
    pub expires_at: Option<Value>,
    /// Harness was set up in it, so it can show up as a device.
    pub harness: bool,
    /// The name its device registers under; the gateway gives fleet sandboxes no name.
    pub device_name: Option<String>,
}

/// `enabled: false` means this build doesn't offer cloud sandboxes.
#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(default)]
pub struct CodegraffSandboxes {
    pub enabled: bool,
    pub sandboxes: Vec<CodegraffSandbox>,
}

pub fn sandbox_title(sandbox: &CodegraffSandbox) -> String {
    [&sandbox.name, &sandbox.device_name]
        .into_iter()
        .flatten()
        .map(|name| name.trim())
        .find(|name| !name.is_empty())
        .unwrap_or("Cloud sandbox")
        .to_string()
}

/// Only our own (fleet) sandboxes have Harness set up in them: a paused one is started, and a
/// running one that never got Harness (a create that half-failed) is set up again.
pub fn can_start(sandbox: &CodegraffSandbox) -> bool {
    sandbox.provider == "fleet"
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
    sandbox.state == "running"
}

/// "Running · Harness ready · pauses in 24 min". Pure.
pub fn sandbox_detail(sandbox: &CodegraffSandbox, now: DateTime<Utc>) -> String {
    let mut parts = vec![match sandbox.state.as_str() {
        "running" => "Running".to_string(),
        "starting" => "Starting…".to_string(),
        "paused" => "Paused".to_string(),
        "stopping" => "Stopping…".to_string(),
        "error" => "Error".to_string(),
        other if other.is_empty() || other == "unknown" => "Unknown state".to_string(),
        other => other.to_string(),
    }];
    if sandbox.state == "running" {
        if sandbox.harness {
            parts.push("Harness ready".into());
        } else {
            parts.push("Harness not set up".into());
        }
        if let Some(lease) = sandbox
            .expires_at
            .as_ref()
            .and_then(|at| lease_remaining(at, now))
        {
            parts.push(lease);
        }
    }
    parts.join(" · ")
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
    fn paused_rows_say_only_paused() {
        let paused = sandbox("paused", true, Some("2026-10-01T12:24:00Z"));
        assert_eq!(sandbox_detail(&paused, at(12, 0)), "Paused");
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
