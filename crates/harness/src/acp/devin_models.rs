//! Devin's ACP session starts with a bundled catalog and refreshes it later.
//! `models list` waits for the account catalog before writing JSON, so use it
//! instead of racing `session/new` against `config_option_update` notifications.

use std::path::Path;
use std::time::Duration;

use serde::Deserialize;
use tokio::sync::Mutex;
use tokio::time::Instant;

use harness_proto::Model;

use crate::HarnessError;
use crate::jsonrpc::{Incoming, RpcClient};
use crate::process::{Command, Stdio};

pub(super) struct ModelSelection {
    pub model: String,
    pub thought_level: Option<&'static str>,
    pub speed: Option<&'static str>,
}

const EFFORT_SUFFIXES: [&str; 6] = ["-xhigh", "-medium", "-none", "-low", "-high", "-max"];

fn split_effort(id: &str) -> (&str, Option<&'static str>) {
    if id.contains("-sidekick-") {
        return (id, None);
    }
    for suffix in EFFORT_SUFFIXES {
        if let Some(stem) = id.strip_suffix(suffix)
            && !stem.is_empty()
        {
            return (stem, Some(&suffix[1..]));
        }
    }
    (id, None)
}

struct ParsedVariant<'a> {
    family: &'a str,
    sidekick: Option<&'a str>,
    thought_level: Option<&'static str>,
    speed: Option<&'static str>,
}

fn parse_variant(id: &str) -> ParsedVariant<'_> {
    if id.starts_with("fusion-") {
        if let Some((lead, sidekick)) = id.split_once("-sidekick-")
            && !sidekick.is_empty()
        {
            let (lead, speed) = match lead.strip_suffix("-fast") {
                Some(stripped) if !stripped.is_empty() => (stripped, "fast"),
                _ => (lead, "standard"),
            };
            if let (stem, Some(effort)) = split_effort(lead) {
                return ParsedVariant {
                    family: stem,
                    sidekick: Some(sidekick),
                    thought_level: Some(effort),
                    speed: Some(speed),
                };
            }
        }
        return ParsedVariant {
            family: id,
            sidekick: None,
            thought_level: None,
            speed: None,
        };
    }
    let (stem, effort) = split_effort(id);
    ParsedVariant {
        family: stem,
        sidekick: None,
        thought_level: effort,
        speed: None,
    }
}

fn resolve(requested: &str, candidates: &[&str], grouped: bool) -> Option<ModelSelection> {
    let parsed = parse_variant(requested);
    if candidates.contains(&requested) {
        return Some(ModelSelection {
            model: requested.to_owned(),
            thought_level: grouped.then_some(parsed.thought_level).flatten(),
            speed: grouped.then_some(parsed.speed).flatten(),
        });
    }
    if !grouped {
        return None;
    }
    parsed.thought_level?;
    candidates
        .iter()
        .find(|candidate| {
            let advertised = parse_variant(candidate);
            advertised.family == parsed.family && advertised.sidekick == parsed.sidekick
        })
        .map(|candidate| ModelSelection {
            model: (*candidate).to_owned(),
            thought_level: parsed.thought_level,
            speed: parsed.speed,
        })
}

fn selection_from_session(response: &serde_json::Value, requested: &str) -> Option<ModelSelection> {
    let config_options = response
        .get("configOptions")
        .and_then(serde_json::Value::as_array);
    let grouped = config_options.is_some_and(|options| {
        options.iter().any(|option| {
            option.get("category").and_then(serde_json::Value::as_str) == Some("thought_level")
        })
    });
    let choices: Vec<&str> = config_options
        .and_then(|options| {
            options.iter().find(|option| {
                option.get("category").and_then(serde_json::Value::as_str) == Some("model")
            })
        })
        .and_then(|option| option.get("options").and_then(serde_json::Value::as_array))
        .map(|choices| {
            choices
                .iter()
                .filter_map(|choice| choice.get("value").and_then(serde_json::Value::as_str))
                .collect()
        })
        .unwrap_or_default();
    if !choices.is_empty() {
        return resolve(requested, &choices, grouped);
    }
    let legacy: Vec<&str> = response
        .get("models")
        .and_then(|models| models.get("availableModels"))
        .and_then(serde_json::Value::as_array)
        .map(|models| models.as_slice())
        .unwrap_or_default()
        .iter()
        .filter_map(|model| model.get("modelId").and_then(serde_json::Value::as_str))
        .collect();
    resolve(requested, &legacy, grouped)
}

/// A freshly discovered variant may also arrive after `session/new` in the
/// process that runs the prompt. Wait for that exact id; the generic ACP
/// family fallback could otherwise silently select a different GPT model.
pub(super) async fn wait_for_model(
    client: &RpcClient,
    incoming: &mut tokio::sync::mpsc::Receiver<Incoming>,
    session_id: &str,
    response: &mut serde_json::Value,
    model: &str,
) -> Result<ModelSelection, HarnessError> {
    let wait = async {
        loop {
            if let Some(selection) = selection_from_session(response, model) {
                return Ok(selection);
            }
            match incoming.recv().await {
                Some(Incoming::Notification { method, params })
                    if method == "session/update"
                        && params.get("sessionId").and_then(serde_json::Value::as_str)
                            == Some(session_id)
                        && params["update"]["sessionUpdate"] == "config_option_update" =>
                {
                    if params["update"]["configOptions"].is_array() {
                        response["configOptions"] = params["update"]["configOptions"].clone();
                    }
                }
                Some(Incoming::Request { id, method, params }) => {
                    super::handle_server_request(client, id, &method, &params);
                }
                Some(_) => {}
                None => {
                    return Err(HarnessError::Protocol(
                        "Devin exited while refreshing models".into(),
                    ));
                }
            }
        }
    };
    tokio::time::timeout(super::DEFAULT_MODEL_DISCOVERY_TIMEOUT, wait)
        .await
        .map_err(|_| {
            HarnessError::Protocol(format!(
                "Devin did not advertise requested model {model} after refreshing"
            ))
        })?
}

fn config_option<'a>(
    response: &'a serde_json::Value,
    category: &str,
) -> Option<&'a serde_json::Value> {
    response
        .get("configOptions")
        .and_then(serde_json::Value::as_array)?
        .iter()
        .find(|option| option.get("category").and_then(serde_json::Value::as_str) == Some(category))
}

fn config_option_by_id<'a>(
    response: &'a serde_json::Value,
    id: &str,
    category: &str,
) -> Option<&'a serde_json::Value> {
    response
        .get("configOptions")
        .and_then(serde_json::Value::as_array)?
        .iter()
        .find(|option| {
            option.get("id").and_then(serde_json::Value::as_str) == Some(id)
                && option.get("category").and_then(serde_json::Value::as_str) == Some(category)
        })
}

fn absorb_config_options(
    response: &mut serde_json::Value,
    result: &serde_json::Value,
    required: bool,
) -> Result<(), HarnessError> {
    if result
        .get("configOptions")
        .is_some_and(serde_json::Value::is_array)
    {
        response["configOptions"] = result["configOptions"].clone();
        return Ok(());
    }
    if required {
        return Err(HarnessError::Protocol(
            "Devin did not return refreshed config options".into(),
        ));
    }
    Ok(())
}

async fn set_config_option(
    client: &RpcClient,
    incoming: &mut tokio::sync::mpsc::Receiver<Incoming>,
    session_id: &str,
    config_id: &str,
    value: &str,
) -> Result<serde_json::Value, HarnessError> {
    super::request_draining(
        client,
        incoming,
        "session/set_config_option",
        serde_json::json!({
            "sessionId": session_id,
            "configId": config_id,
            "value": value,
        }),
    )
    .await
}

pub(super) async fn configure_model(
    client: &RpcClient,
    incoming: &mut tokio::sync::mpsc::Receiver<Incoming>,
    session_id: &str,
    response: &mut serde_json::Value,
    requested: &str,
    selection: &ModelSelection,
) -> Result<bool, HarnessError> {
    let Some(model_option) = config_option(response, "model").cloned() else {
        return Ok(false);
    };
    let model_config_id = model_option
        .get("id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| HarnessError::Protocol("Devin's model config option has no id".into()))?
        .to_owned();
    if model_option
        .get("currentValue")
        .and_then(serde_json::Value::as_str)
        != Some(selection.model.as_str())
    {
        let result = set_config_option(
            client,
            incoming,
            session_id,
            &model_config_id,
            &selection.model,
        )
        .await
        .map_err(|error| {
            HarnessError::Protocol(format!(
                "agent rejected requested model {requested}: {error}"
            ))
        })?;
        absorb_config_options(response, &result, selection.thought_level.is_some())?;
    }
    let Some(level) = selection.thought_level else {
        return Ok(true);
    };
    let thought = config_option(response, "thought_level")
        .cloned()
        .ok_or_else(|| {
            HarnessError::Protocol(format!(
                "Devin did not advertise a thought_level option for model {}",
                selection.model
            ))
        })?;
    let choices: Vec<&str> = thought
        .get("options")
        .and_then(serde_json::Value::as_array)
        .map(|choices| choices.as_slice())
        .unwrap_or_default()
        .iter()
        .filter_map(|choice| choice.get("value").and_then(serde_json::Value::as_str))
        .collect();
    if !choices.contains(&level) {
        return Err(HarnessError::Protocol(format!(
            "Devin does not offer requested thinking level {level} for model {}",
            selection.model
        )));
    }
    let thought_config_id = thought
        .get("id")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            HarnessError::Protocol("Devin's thought_level config option has no id".into())
        })?
        .to_owned();
    if thought
        .get("currentValue")
        .and_then(serde_json::Value::as_str)
        != Some(level)
    {
        let result = set_config_option(client, incoming, session_id, &thought_config_id, level)
            .await
            .map_err(|error| {
                HarnessError::Protocol(format!(
                    "Devin rejected requested thinking level {level}: {error}"
                ))
            })?;
        absorb_config_options(response, &result, true)?;
    }
    if let Some(speed) = selection.speed {
        let speed_option = config_option_by_id(response, "speed", "model_config")
            .cloned()
            .ok_or_else(|| {
                HarnessError::Protocol(format!(
                    "Devin did not advertise a speed option for model {}",
                    selection.model
                ))
            })?;
        let speed_choices: Vec<&str> = speed_option
            .get("options")
            .and_then(serde_json::Value::as_array)
            .map(|choices| choices.as_slice())
            .unwrap_or_default()
            .iter()
            .filter_map(|choice| choice.get("value").and_then(serde_json::Value::as_str))
            .collect();
        if !speed_choices.contains(&speed) {
            return Err(HarnessError::Protocol(format!(
                "Devin does not offer requested speed {speed} for model {}",
                selection.model
            )));
        }
        let speed_config_id = speed_option
            .get("id")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| HarnessError::Protocol("Devin's speed config option has no id".into()))?
            .to_owned();
        if speed_option
            .get("currentValue")
            .and_then(serde_json::Value::as_str)
            != Some(speed)
        {
            let result = set_config_option(client, incoming, session_id, &speed_config_id, speed)
                .await
                .map_err(|error| {
                    HarnessError::Protocol(format!(
                        "Devin rejected requested speed {speed}: {error}"
                    ))
                })?;
            absorb_config_options(response, &result, true)?;
        }
    }
    let model_ok = config_option(response, "model")
        .and_then(|option| option.get("currentValue"))
        .and_then(serde_json::Value::as_str)
        == Some(selection.model.as_str());
    let thought_ok = config_option(response, "thought_level")
        .and_then(|option| option.get("currentValue"))
        .and_then(serde_json::Value::as_str)
        == Some(level);
    let speed_ok = match selection.speed {
        Some(speed) => {
            config_option_by_id(response, "speed", "model_config")
                .and_then(|option| option.get("currentValue"))
                .and_then(serde_json::Value::as_str)
                == Some(speed)
        }
        None => true,
    };
    if !(model_ok && thought_ok && speed_ok) {
        let detail = match selection.speed {
            Some(speed) => format!(
                "Devin did not confirm model {} at thinking level {level} and speed {speed}",
                selection.model
            ),
            None => format!(
                "Devin did not confirm model {} at thinking level {level}",
                selection.model
            ),
        };
        return Err(HarnessError::Protocol(detail));
    }
    Ok(true)
}

#[derive(Default)]
pub(super) struct Catalog {
    // Only overlapping callers share a result. A later picker open always
    // probes again, including after errors, login changes, or model rollouts.
    latest: Mutex<Option<(Instant, Vec<Model>)>>,
}

impl Catalog {
    pub(super) async fn refresh(
        &self,
        exe: &Path,
        timeout: Duration,
    ) -> Result<Vec<Model>, HarnessError> {
        let requested_at = Instant::now();
        let mut latest = self.latest.lock().await;
        if let Some((completed_at, models)) = &*latest
            && *completed_at >= requested_at
        {
            return Ok(models.clone());
        }
        let mut cmd = Command::new(exe);
        cmd.args(["models", "list", "--format", "json"]);
        crate::compose_child_path(&mut cmd, exe);
        cmd.stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let output = tokio::time::timeout(timeout, cmd.output())
            .await
            .map_err(|_| HarnessError::Protocol("Devin model discovery timed out".into()))??;
        if !output.status.success() {
            return Err(HarnessError::Protocol(format!(
                "Devin models list failed ({}): {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
        let models = parse_catalog(&output.stdout)?;
        *latest = Some((Instant::now(), models.clone()));
        Ok(models)
    }
}

#[derive(Deserialize)]
struct ModelList {
    families: Vec<Family>,
}

#[derive(Deserialize)]
struct Family {
    variants: Vec<Variant>,
}

#[derive(Deserialize)]
struct Variant {
    model_uid: String,
    label: String,
    cost_summary: Option<String>,
}

fn parse_catalog(bytes: &[u8]) -> Result<Vec<Model>, HarnessError> {
    let catalog: ModelList = serde_json::from_slice(bytes)
        .map_err(|error| HarnessError::Protocol(format!("invalid Devin model catalog: {error}")))?;
    let mut models = Vec::new();
    for variant in catalog.families.into_iter().flat_map(|f| f.variants) {
        if variant.model_uid.trim().is_empty() || variant.label.trim().is_empty() {
            return Err(HarnessError::Protocol(
                "invalid empty Devin model id or label".into(),
            ));
        }
        if models.iter().any(|m: &Model| m.id == variant.model_uid) {
            continue;
        }
        models.push(Model {
            id: variant.model_uid,
            label: variant.label,
            description: variant.cost_summary,
            // Devin encodes effort and fast mode in the exact variant id.
            reasoning_levels: Vec::new(),
            options: Vec::new(),
            maker: None,
            billing: None,
        });
    }
    if models.is_empty() {
        return Err(HarnessError::Protocol(
            "Devin returned an empty model catalog".into(),
        ));
    }
    Ok(models)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_exact_variants_without_turning_family_aliases_into_models() {
        let models = parse_catalog(br#"{"families":[{
            "family_uid":"gpt-6-astra", "aliases":["astra"], "variants":[
                {"model_uid":"gpt-6-astra-medium","label":"GPT-6 Astra Medium Thinking","cost_summary":"Account pricing"},
                {"model_uid":"gpt-6-astra-high","label":"GPT-6 Astra High Thinking"},
                {"model_uid":"gpt-6-astra-high","label":"Duplicate"}
            ]
        }]}"#).unwrap();
        assert_eq!(models.len(), 2);
        assert_eq!(models[0].id, "gpt-6-astra-medium");
        assert_eq!(models[0].label, "GPT-6 Astra Medium Thinking");
        assert_eq!(models[0].description.as_deref(), Some("Account pricing"));
        assert_eq!(models[1].id, "gpt-6-astra-high");
        assert!(
            models
                .iter()
                .all(|m| m.reasoning_levels.is_empty() && m.options.is_empty())
        );
    }

    #[test]
    fn resolves_grouped_family_stems_strictly() {
        let candidates = ["swe-1-7", "swe-2-high", "adaptive"];
        let selected = resolve("swe-2-max", &candidates, true).unwrap();
        assert_eq!(selected.model, "swe-2-high");
        assert_eq!(selected.thought_level, Some("max"));
        let selected = resolve("swe-2-high", &candidates, true).unwrap();
        assert_eq!(selected.model, "swe-2-high");
        assert_eq!(selected.thought_level, Some("high"));
        let selected = resolve("swe-1-7-max", &candidates, true).unwrap();
        assert_eq!(selected.model, "swe-1-7");
        assert_eq!(selected.thought_level, Some("max"));
        let selected = resolve("adaptive", &candidates, true).unwrap();
        assert_eq!(selected.model, "adaptive");
        assert_eq!(selected.thought_level, None);
        assert!(resolve("swe-2", &candidates, true).is_none());
        assert!(resolve("swe-2-max", &candidates, false).is_none());
        assert_eq!(
            resolve("swe-2-high", &candidates, false)
                .unwrap()
                .thought_level,
            None
        );
        assert!(resolve("swe-2-turbo", &candidates, true).is_none());
        assert!(resolve("gpt-5-max", &candidates, true).is_none());
        assert!(resolve("swe-9-high", &candidates, true).is_none());
    }

    #[test]
    fn resolves_paired_fusion_variants_by_family_and_sidekick() {
        let candidates = [
            "fusion-lead-model-1-high-sidekick-worker-model-2-high",
            "fusion-lead-model-1-high-sidekick-worker-model-2-medium",
            "swe-2-high",
        ];
        let rep_medium = "fusion-lead-model-1-high-sidekick-worker-model-2-medium";
        let selected = resolve(
            "fusion-lead-model-1-medium-sidekick-worker-model-2-medium",
            &candidates,
            true,
        )
        .unwrap();
        assert_eq!(selected.model, rep_medium);
        assert_eq!(selected.thought_level, Some("medium"));
        assert_eq!(selected.speed, Some("standard"));
        let selected = resolve(
            "fusion-lead-model-1-medium-fast-sidekick-worker-model-2-medium",
            &candidates,
            true,
        )
        .unwrap();
        assert_eq!(selected.model, rep_medium);
        assert_eq!(selected.thought_level, Some("medium"));
        assert_eq!(selected.speed, Some("fast"));
        let selected = resolve(rep_medium, &candidates, true).unwrap();
        assert_eq!(selected.model, rep_medium);
        assert_eq!(selected.thought_level, Some("high"));
        assert_eq!(selected.speed, Some("standard"));
        let selected = resolve(
            "fusion-lead-model-1-medium-sidekick-worker-model-2-high",
            &candidates,
            true,
        )
        .unwrap();
        assert_eq!(selected.model, candidates[0]);
        assert_eq!(selected.thought_level, Some("medium"));
        for (requested, effort) in [
            (
                "fusion-lead-model-1-xhigh-sidekick-worker-model-2-medium",
                "xhigh",
            ),
            (
                "fusion-lead-model-1-max-sidekick-worker-model-2-medium",
                "max",
            ),
        ] {
            let selected = resolve(requested, &candidates, true).unwrap();
            assert_eq!(selected.model, rep_medium);
            assert_eq!(selected.thought_level, Some(effort));
            assert_eq!(selected.speed, Some("standard"));
        }
        for id in [
            "fusion-lead-model-2-medium-sidekick-worker-model-2-medium",
            "fusion-lead-model-1-medium-sidekick-worker-model-3-medium",
            "fusion-lead-model-1-medium-sidekick-worker-model-2-low",
            "fusion-lead-model-1-medium-sidekick-swe-2-medium",
        ] {
            assert!(resolve(id, &candidates, true).is_none(), "{id}");
        }
        assert!(
            resolve(
                "fusion-lead-model-1-medium-sidekick-worker-model-2-medium",
                &candidates,
                false
            )
            .is_none()
        );
        let exact = resolve(rep_medium, &candidates, false).unwrap();
        assert_eq!(exact.model, rep_medium);
        assert!(exact.thought_level.is_none() && exact.speed.is_none());
        let standalone = resolve("swe-2-max", &candidates, true).unwrap();
        assert_eq!(standalone.model, "swe-2-high");
        assert!(standalone.speed.is_none());
    }

    #[test]
    fn paired_fusion_requires_recognized_lead_effort() {
        let candidates = [
            "fusion-lead-model-1-high-sidekick-worker-model-2-medium",
            "fusion-lead-model-1-high",
        ];
        for id in [
            "fusion-lead-model-1-turbo-sidekick-worker-model-2-medium",
            "fusion-lead-model-1-sidekick-worker-model-2-medium",
            "fusion-lead-model-1-medium-sidekick-",
            "fusion-lead-model-1-medium",
        ] {
            assert!(resolve(id, &candidates, true).is_none(), "{id}");
        }
        let exact = resolve("fusion-lead-model-1-high", &candidates, true).unwrap();
        assert_eq!(exact.model, "fusion-lead-model-1-high");
        assert!(exact.thought_level.is_none() && exact.speed.is_none());
    }

    #[test]
    fn sidekick_ids_stay_exact_only() {
        let candidates = ["swe-2-sidekick-high", "swe-2-high"];
        assert!(resolve("swe-2-sidekick-max", &candidates, true).is_none());
        assert!(resolve("swe-2-sidekick", &candidates, true).is_none());
        let selected = resolve("swe-2-sidekick-high", &candidates, true).unwrap();
        assert_eq!(selected.model, "swe-2-sidekick-high");
        assert_eq!(selected.thought_level, None);
    }

    #[test]
    fn invalid_or_empty_catalogs_are_retryable_errors() {
        for bytes in [
            "not json",
            "{}",
            r#"{"families":[]}"#,
            r#"{"families":[{"variants":[{"label":"Missing id"}]}]}"#,
            r#"{"families":[{"variants":[{"model_uid":"","label":"Empty id"}]}]}"#,
        ] {
            assert!(parse_catalog(bytes.as_bytes()).is_err(), "{bytes}");
        }
    }
}
