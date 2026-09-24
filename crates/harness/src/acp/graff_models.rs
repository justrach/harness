//! Graff's `graff/models` ACP extension supplies the active account's model
//! rows and per-model effort ladders without starting inference. Qualified
//! row ids pin the provider at launch. Older binaries that lack the extension
//! retain the route/schema catalog without invented effort support.

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

use harness_proto::{Model, ReasoningLevel};
use serde_json::{Value, json};

use super::{AcpHarness, initialize_params, reasoning_from_value, request_draining};
use crate::jsonrpc::RpcClient;
use crate::process::{Command, Stdio};
use crate::{CatalogFailure, CatalogFailureCode, HarnessError, HarnessId};

pub(super) fn launch_args(model: Option<&str>) -> Vec<String> {
    match model.map(str::trim).filter(|m| !m.is_empty()) {
        Some(model) => vec!["--model".into(), seat_name(model).into()],
        None => Vec::new(),
    }
}

fn seat_name(id: &str) -> &str {
    id.split_once(':')
        .filter(|(provider, name)| {
            !provider.is_empty() && !name.is_empty() && !provider.contains('/')
        })
        .map(|(_, name)| name)
        .unwrap_or(id)
}

fn effort_value(level: ReasoningLevel) -> &'static str {
    match level {
        ReasoningLevel::None => "none",
        ReasoningLevel::Minimal => "minimal",
        ReasoningLevel::Low => "low",
        ReasoningLevel::Medium => "medium",
        ReasoningLevel::High => "high",
        ReasoningLevel::XHigh => "xhigh",
        ReasoningLevel::Max => "max",
        ReasoningLevel::Ultra => "ultra",
        ReasoningLevel::Ultracode => "ultracode",
        ReasoningLevel::Ultrathink => "ultrathink",
    }
}

pub(super) fn effort_name(level: ReasoningLevel) -> &'static str {
    effort_value(level)
}

pub(super) fn effort_values(
    reasoning: Option<ReasoningLevel>,
    _model: Option<&str>,
) -> Vec<&'static str> {
    reasoning.map(effort_value).into_iter().collect()
}

fn thought_option(response: &Value) -> Option<&Value> {
    response
        .get("configOptions")?
        .as_array()?
        .iter()
        .find(|option| {
            option.get("category").and_then(Value::as_str) == Some("thought_level")
                && option.get("type").and_then(Value::as_str) == Some("select")
        })
}

pub(super) fn is_thought_option(session: &Value, id: &str) -> bool {
    thought_option(session)
        .and_then(|option| option.get("id"))
        .and_then(Value::as_str)
        == Some(id)
}

pub(super) fn validate_effort(
    session: &Value,
    reasoning: Option<ReasoningLevel>,
) -> Result<(), HarnessError> {
    let Some(level) = reasoning else {
        return Ok(());
    };
    let wanted = effort_value(level);
    let offered = thought_option(session).is_some_and(|option| {
        option
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|id| !id.is_empty())
            && option.get("currentValue").and_then(Value::as_str).is_some()
            && option
                .get("options")
                .and_then(Value::as_array)
                .is_some_and(|options| {
                    options
                        .iter()
                        .any(|choice| choice.get("value").and_then(Value::as_str) == Some(wanted))
                })
    });
    if offered {
        Ok(())
    } else {
        Err(HarnessError::Protocol(format!(
            "graff does not offer thought level {wanted} for the current model"
        )))
    }
}

pub(super) fn verify_effort_set(response: &Value, wanted: &str) -> Result<(), HarnessError> {
    if thought_option(response)
        .and_then(|option| option.get("currentValue"))
        .and_then(Value::as_str)
        == Some(wanted)
    {
        Ok(())
    } else {
        Err(HarnessError::Protocol(format!(
            "graff did not apply thought level {wanted}"
        )))
    }
}

pub(super) fn verify_resumed_model(catalog: &Value, requested: &str) -> Result<(), HarnessError> {
    let Some((provider, name)) = requested.split_once('/') else {
        return Ok(()); // Preserve legacy bare-name resolution.
    };
    let current = catalog.get("current");
    if current
        .and_then(|value| value.get("provider"))
        .and_then(Value::as_str)
        == Some(provider)
        && current
            .and_then(|value| value.get("model"))
            .and_then(Value::as_str)
            == Some(name)
    {
        Ok(())
    } else {
        Err(HarnessError::Protocol(format!(
            "graff restored a different model; {requested} requires a new session"
        )))
    }
}

pub(super) async fn discover(
    harness: &AcpHarness,
    exe: &Path,
    timeout: Duration,
) -> Result<Vec<Model>, HarnessError> {
    match discover_acp(harness, timeout).await {
        Ok(catalog) => models_from_acp(&catalog),
        Err(error) if extension_unavailable(&error) => discover_legacy(exe, timeout).await,
        Err(error) => Err(error),
    }
}

fn extension_unavailable(error: &HarnessError) -> bool {
    matches!(error, HarnessError::Protocol(message)
        if message.starts_with("graff/models:") && message.ends_with("(code -32601)"))
}

async fn discover_acp(harness: &AcpHarness, timeout: Duration) -> Result<Value, HarnessError> {
    let cwd = crate::scratch::ScratchDir::new("graff-model-discovery")?;
    let (_scratch, mut child, _stderr) =
        harness.spawn_agent(cwd.path().to_str(), false, &[]).await?;
    let (client, mut incoming) = match (child.stdin.take(), child.stdout.take()) {
        (Some(stdin), Some(stdout)) => RpcClient::new(stdin, stdout),
        _ => {
            child.shutdown(harness.kill_grace).await;
            return Err(HarnessError::Protocol(
                "graff discovery has no stdio".into(),
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
        if init.get("protocolVersion").and_then(Value::as_u64) != Some(1) {
            return Err(HarnessError::Protocol(
                "graff model discovery requires ACP v1".into(),
            ));
        }
        request_draining(
            &client,
            &mut incoming,
            "session/new",
            json!({
                "cwd": cwd.path().to_string_lossy(), "mcpServers": []
            }),
        )
        .await?;
        request_draining(&client, &mut incoming, "graff/models", json!({})).await
    })
    .await;
    child.shutdown(harness.kill_grace).await;
    result.map_err(|_| HarnessError::Protocol("graff model discovery timed out".into()))?
}

fn models_from_acp(catalog: &Value) -> Result<Vec<Model>, HarnessError> {
    let rows = catalog
        .get("models")
        .and_then(Value::as_array)
        .ok_or_else(|| HarnessError::Protocol("graff/models omitted its model rows".into()))?;
    let current = catalog.get("current");
    let mut seen = HashSet::new();
    let mut models = Vec::new();
    for row in rows {
        if row.get("authenticated").and_then(Value::as_bool) != Some(true) {
            continue;
        }
        let (Some(provider), Some(name)) = (
            row.get("provider").and_then(Value::as_str),
            row.get("name").and_then(Value::as_str),
        ) else {
            continue;
        };
        if provider.is_empty() || name.is_empty() || !seen.insert((provider, name)) {
            continue;
        }
        let mut reasoning_levels = Vec::new();
        for value in row
            .get("effortLevels")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(level) = value.as_str().and_then(reasoning_from_value)
                && !reasoning_levels.contains(&level)
            {
                reasoning_levels.push(level);
            }
        }
        let description = match row.get("context").and_then(Value::as_u64) {
            Some(context) => format!("{provider} · {}k context", context / 1000),
            None => provider.to_owned(),
        };
        let model = Model {
            id: format!("{provider}/{name}"),
            label: name.to_owned(),
            description: Some(description),
            reasoning_levels,
            options: Vec::new(),
        };
        if current.is_some_and(|c| {
            c.get("provider").and_then(Value::as_str) == Some(provider)
                && c.get("model").and_then(Value::as_str) == Some(name)
        }) {
            models.insert(0, model);
        } else {
            models.push(model);
        }
    }
    if models.is_empty() {
        return Err(no_authenticated_models());
    }
    Ok(models)
}

async fn discover_legacy(exe: &Path, timeout: Duration) -> Result<Vec<Model>, HarnessError> {
    let route = run(exe, &["route"], timeout).await?;
    let (default, providers, advertised) = parse_route(&route);
    if providers.is_empty() {
        return Err(no_authenticated_models());
    }
    let listing = run(exe, &["models"], timeout).await?;
    let mut seats = parse_models_listing(&listing);
    promote_missing_codex_seats(&mut seats, &providers);
    let models = models_from_seats(&seats, &providers, default.as_deref(), &advertised);
    if models.is_empty() {
        return Err(HarnessError::Protocol(
            "graff models listed nothing for reachable providers".into(),
        ));
    }
    Ok(models)
}

fn no_authenticated_models() -> HarnessError {
    CatalogFailure {
        code: CatalogFailureCode::AuthRequired,
        message: "graff has no reachable provider — run `graff login`".into(),
    }
    .into()
}

async fn run(exe: &Path, args: &[&str], timeout: Duration) -> Result<String, HarnessError> {
    let mut cmd = Command::new(exe);
    cmd.args(args);
    crate::compose_child_path(&mut cmd, exe);
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let output = tokio::time::timeout(timeout, cmd.output())
        .await
        .map_err(|_| HarnessError::Protocol(format!("graff {} timed out", args.join(" "))))??;
    if !output.status.success() {
        return Err(HarnessError::Protocol(format!(
            "graff {} failed ({}): {}",
            args.join(" "),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// `graff route` prints the session default and a table of reachable
/// providers:
///
/// ```text
/// session default: codegraff/claude-sonnet-5 · auth: OAuth/login · billing: metered
///
/// provider     auth           billing        frontier / mid / small
/// codegraff    OAuth/login    metered        claude-opus-5 / …
/// ```
///
/// Returns the default model name, provider ids in table order, and the
/// frontier/mid/small seats those providers advertise (skipping `-` and
/// "no tier ladder" rows).
fn parse_route(text: &str) -> (Option<String>, Vec<String>, Vec<String>) {
    let default = text.lines().find_map(|line| {
        let seat = line.trim().strip_prefix("session default:")?;
        let seat = seat.split_whitespace().next()?;
        Some(
            seat.split_once('/')
                .map_or(seat, |(_, model)| model)
                .to_string(),
        )
    });
    let mut providers = Vec::new();
    let mut advertised = Vec::new();
    let mut seen_models = HashSet::new();
    for line in text
        .lines()
        .skip_while(|line| !line.trim_start().starts_with("provider"))
        .skip(1)
        .take_while(|line| !line.trim().is_empty())
    {
        let Some((provider, models)) = parse_provider_row(line) else {
            continue;
        };
        providers.push(provider);
        for model in models {
            if seen_models.insert(model.clone()) {
                advertised.push(model);
            }
        }
    }
    (default, providers, advertised)
}

fn parse_provider_row(line: &str) -> Option<(String, Vec<String>)> {
    let mut parts = line.split_whitespace();
    let provider = parts.next()?.to_string();
    if provider == "usage:" {
        return None;
    }
    let mut saw_billing = false;
    for part in parts.by_ref() {
        if matches!(part, "metered" | "subscription" | "unpriced") {
            saw_billing = true;
            break;
        }
    }
    if !saw_billing {
        return Some((provider, Vec::new()));
    }
    let rest = parts.collect::<Vec<_>>().join(" ");
    if rest.is_empty() || rest.starts_with('(') {
        return Some((provider, Vec::new()));
    }
    let models = rest
        .split(" / ")
        .map(str::trim)
        .filter(|model| !model.is_empty() && *model != "-")
        .map(str::to_string)
        .collect();
    Some((provider, models))
}

#[derive(Clone, Debug)]
struct Seat {
    provider: String,
    name: String,
    context: Option<u64>,
}

fn parse_models_listing(text: &str) -> Vec<Seat> {
    let mut provider = String::new();
    let mut seats = Vec::new();
    for line in text.lines() {
        if let Some(name) = parse_listing_provider(line) {
            provider = name.to_string();
            continue;
        }
        if provider.is_empty() {
            continue;
        }
        let Some((name, context)) = parse_listing_model(line) else {
            continue;
        };
        if name.contains(':') {
            continue;
        }
        seats.push(Seat {
            provider: provider.clone(),
            name: name.to_string(),
            context,
        });
    }
    seats
}

fn parse_listing_provider(line: &str) -> Option<&str> {
    let line = line.trim();
    let line = line.strip_suffix(':')?;
    if line.is_empty() || line.contains(" ctx") {
        return None;
    }
    Some(line.split(" (").next().unwrap_or(line).trim())
}

fn parse_listing_model(line: &str) -> Option<(&str, Option<u64>)> {
    let line = line.trim();
    if line.is_empty() || line.ends_with(':') {
        return None;
    }
    let mut parts = line.split_whitespace();
    let name = parts.next()?;
    let context = parts
        .next()
        .and_then(|n| n.parse().ok())
        .filter(|_| parts.next() == Some("ctx"));
    Some((name, context))
}

/// Codex's account snapshot often omits baked seats the TUI still shows
/// (`gpt-6-sol`). If OpenRouter lists `openai/gpt-6-sol` and Codex is logged
/// in, surface the Codex row so search is not only gateway slugs.
fn promote_missing_codex_seats(seats: &mut Vec<Seat>, providers: &[String]) {
    if !providers.iter().any(|provider| provider == "codex") {
        return;
    }
    let have: HashSet<&str> = seats
        .iter()
        .filter(|seat| seat.provider == "codex")
        .map(|seat| seat.name.as_str())
        .collect();
    let missing: Vec<String> = seats
        .iter()
        .filter(|seat| seat.provider == "openrouter")
        .filter_map(|seat| seat.name.strip_prefix("openai/"))
        .filter(|name| !name.contains('/') && !have.contains(name))
        .map(str::to_string)
        .collect();
    for name in missing {
        seats.push(Seat {
            provider: "codex".into(),
            name,
            context: Some(272_000),
        });
    }
}

fn is_alias(name: &str) -> bool {
    name.contains('/') || name.contains(':')
}

fn close_sibling(default: &str, name: &str) -> bool {
    let Some((prefix, _)) = default.rsplit_once('.') else {
        return false;
    };
    let Some(rest) = name.strip_prefix(prefix) else {
        return false;
    };
    name != default && !rest.contains('-')
}

fn provider_pref(provider: &str, table_rank: usize) -> usize {
    const HOME: &[&str] = &["codex", "xai", "openai", "anthropic", "kimi", "codegraff"];
    HOME.iter()
        .position(|home| *home == provider)
        .unwrap_or(100 + table_rank)
}

fn models_from_seats(
    seats: &[Seat],
    providers: &[String],
    default: Option<&str>,
    advertised: &[String],
) -> Vec<Model> {
    let mut ranked: Vec<&Seat> = seats
        .iter()
        .filter(|seat| providers.iter().any(|provider| provider == &seat.provider))
        .collect();
    ranked.sort_by_key(|seat| {
        (
            Some(seat.name.as_str()) != default,
            default.is_none_or(|default| !close_sibling(default, &seat.name)),
            !advertised.iter().any(|model| model == &seat.name),
            is_alias(&seat.name),
            provider_pref(&seat.provider, 0),
            seat.name.clone(),
            seat.provider.clone(),
        )
    });
    let mut seen = HashSet::new();
    let mut used_names = HashSet::new();
    ranked
        .into_iter()
        .filter(|seat| seen.insert((seat.provider.clone(), seat.name.clone())))
        .map(|seat| {
            let id = if used_names.insert(seat.name.clone()) {
                seat.name.clone()
            } else {
                format!("{}:{}", seat.provider, seat.name)
            };
            Model {
                id,
                label: seat.name.clone(),
                description: Some(match seat.context {
                    Some(context) => format!("{} · {}k context", seat.provider, context / 1000),
                    None => seat.provider.clone(),
                }),
                reasoning_levels: Vec::new(),
                options: Vec::new(),
            }
        })
        .collect()
}

/// One entry per bare model name. Session default, then close siblings
/// (`grok-4.7` next to `grok-4.6`), then the seats `graff route` prints,
/// with logged-in first-party providers beating OpenRouter aliases.
#[cfg(test)]
fn models_from_schema(
    schema: &serde_json::Value,
    providers: &[String],
    default: Option<&str>,
    advertised: &[String],
) -> Vec<Model> {
    let Some(entries) = schema.get("models").and_then(|m| m.as_array()) else {
        return Vec::new();
    };
    let mut ranked: Vec<(usize, usize, &str, &str, Option<u64>)> = entries
        .iter()
        .filter_map(|entry| {
            let provider = entry.get("provider")?.as_str()?;
            let name = entry.get("name")?.as_str()?;
            let rank = providers.iter().position(|p| p == provider)?;
            Some((
                provider_pref(provider, rank),
                rank,
                provider,
                name,
                entry.get("context").and_then(|c| c.as_u64()),
            ))
        })
        .collect();
    ranked.sort_by_key(|(pref, rank, _, name, _)| {
        (
            Some(*name) != default,
            default.is_none_or(|default| !close_sibling(default, name)),
            !advertised.iter().any(|model| model == name),
            is_alias(name),
            *pref,
            *rank,
            *name,
        )
    });

    let mut seen = HashSet::new();
    ranked
        .into_iter()
        .filter(|(_, _, _, name, _)| seen.insert(*name))
        .map(|(_, _, provider, name, context)| Model {
            id: name.to_string(),
            label: name.to_string(),
            description: Some(match context {
                Some(context) => format!("{provider} · {}k context", context / 1000),
                None => provider.to_string(),
            }),
            reasoning_levels: Vec::new(),
            options: Vec::new(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROUTE: &str = "session default: codegraff/claude-sonnet-5 · auth: OAuth/login · billing: metered\n\n\
        provider     auth           billing        frontier / mid / small\n\
        codegraff    OAuth/login    metered        claude-opus-5 / gpt-5.6-sol / gpt-5.6-luna\n\
        codex        OAuth/login    subscription   gpt-5.6-sol / - / gpt-5.6-luna\n\n\
        usage: graff route <model> [<model>…]\n";

    #[test]
    fn parses_route_table() {
        let (default, providers, advertised) = parse_route(ROUTE);
        assert_eq!(default.as_deref(), Some("claude-sonnet-5"));
        assert_eq!(providers, vec!["codegraff", "codex"]);
        assert_eq!(
            advertised,
            vec!["claude-opus-5", "gpt-5.6-sol", "gpt-5.6-luna"]
        );
    }

    #[test]
    fn keeps_reachable_models_default_first_and_deduplicated() {
        let schema = serde_json::json!({"models": [
            {"provider": "anthropic", "name": "claude-opus-5", "context": 1000000},
            {"provider": "codex", "name": "gpt-5.6-sol", "context": 1050000},
            {"provider": "codegraff", "name": "gpt-5.6-sol", "context": 1050000},
            {"provider": "codegraff", "name": "claude-sonnet-5", "context": 1000000},
        ]});
        let (default, providers, advertised) = parse_route(ROUTE);
        let models = models_from_schema(&schema, &providers, default.as_deref(), &advertised);
        let ids: Vec<&str> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, vec!["claude-sonnet-5", "gpt-5.6-sol"]);
        assert_eq!(
            models[1].description.as_deref(),
            Some("codex · 1050k context")
        );
    }

    #[test]
    fn default_sibling_then_route_seats() {
        const ROUTE: &str = "session default: xai/grok-4.6 · auth: OAuth/login · billing: subscription\n\n\
            provider     auth           billing        frontier / mid / small\n\
            codegraff    OAuth/login    metered        claude-opus-5 / gpt-5.6-sol / grok-4.6\n\
            xai          OAuth/login    subscription   grok-4.7 / grok-4.6 / -\n\n";
        let schema = serde_json::json!({"models": [
            {"provider": "codegraff", "name": "claude-opus-5", "context": 1000000},
            {"provider": "codegraff", "name": "grok-4.6", "context": 500000},
            {"provider": "codegraff", "name": "grok-4.7", "context": 500000},
            {"provider": "xai", "name": "grok-4.7", "context": 500000},
            {"provider": "openrouter", "name": "openai/gpt-5.6-sol:batch", "context": 1050000},
            {"provider": "codegraff", "name": "gpt-5.6-sol", "context": 1050000},
        ]});
        let (default, providers, advertised) = parse_route(ROUTE);
        let models = models_from_schema(&schema, &providers, default.as_deref(), &advertised);
        let ids: Vec<&str> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["grok-4.6", "grok-4.7", "claude-opus-5", "gpt-5.6-sol"]
        );
        assert_eq!(
            models
                .iter()
                .find(|m| m.id == "gpt-5.6-sol")
                .unwrap()
                .description
                .as_deref(),
            Some("codegraff · 1050k context")
        );
    }

    #[test]
    fn launch_args_pass_the_bare_model() {
        assert_eq!(launch_args(Some("k3")), vec!["--model", "k3"]);
        assert_eq!(
            launch_args(Some("codex:gpt-6-sol")),
            vec!["--model", "gpt-6-sol"]
        );
        assert_eq!(launch_args(Some("kimi/k3")), vec!["--model", "kimi/k3"]);
        assert!(launch_args(Some(" ")).is_empty());
        assert!(launch_args(None).is_empty());
    }

    #[test]
    fn listing_keeps_codex_sol_ahead_of_openrouter_slugs() {
        const LISTING: &str = "\
model catalog — 8 entries\n\n\
codex (dynamic cache):\n\
  gpt-5.6-sol                           270000 ctx   (subscription)\n\
openrouter:\n\
  openai/gpt-6-sol                     1050000 ctx   (unpriced)\n\
  openai/gpt-6-sol:batch               1050000 ctx   (unpriced)\n\
";
        const ROUTE: &str = "session default: xai/grok-4.6 · auth: OAuth/login · billing: subscription\n\n\
            provider     auth           billing        frontier / mid / small\n\
            codex        OAuth/login    subscription   gpt-5.6-sol / - / -\n\
            openrouter   secure store   metered        x-ai/grok-4.5 / - / -\n\n";
        let (default, providers, advertised) = parse_route(ROUTE);
        let mut seats = parse_models_listing(LISTING);
        promote_missing_codex_seats(&mut seats, &providers);
        let models = models_from_seats(&seats, &providers, default.as_deref(), &advertised);
        let labels: Vec<&str> = models.iter().map(|m| m.label.as_str()).collect();
        assert!(labels.contains(&"gpt-6-sol"), "{labels:?}");
        let sol = models
            .iter()
            .find(|m| {
                m.label == "gpt-6-sol" && m.description.as_deref() == Some("codex · 272k context")
            })
            .expect("codex gpt-6-sol");
        assert_eq!(sol.id, "gpt-6-sol");
        assert!(sol.reasoning_levels.is_empty());
        assert!(!models.iter().any(|m| m.label.contains(":batch")));
    }

    #[test]
    fn only_unknown_extension_can_use_legacy_discovery() {
        assert!(extension_unavailable(&HarnessError::Protocol(
            "graff/models: method not found: graff/models (code -32601)".into()
        )));
        for message in [
            "graff/models: authentication required (code -32001)",
            "graff/models: app-server exited before responding",
            "session/new: method not found (code -32601)",
            "graff/models: malformed (code -32601): detail",
        ] {
            assert!(!extension_unavailable(&HarnessError::Protocol(
                message.into()
            )));
        }
    }

    #[test]
    fn explicit_effort_requires_advertised_value_and_confirmed_set() {
        let session = json!({"configOptions": [{"id":"thought_level", "type":"select",
            "category":"thought_level", "currentValue":"medium", "options":[
                {"value":"low"}, {"value":"medium"}, {"value":"high"}]}]});
        assert!(validate_effort(&session, Some(ReasoningLevel::High)).is_ok());
        assert!(validate_effort(&session, Some(ReasoningLevel::Ultra)).is_err());
        assert!(validate_effort(&json!({"configOptions": []}), Some(ReasoningLevel::Low)).is_err());
        assert!(validate_effort(&session, None).is_ok());
        assert_eq!(effort_values(Some(ReasoningLevel::High), None), ["high"]);
        let applied = json!({"configOptions": [{"id":"thought_level", "type":"select",
            "category":"thought_level", "currentValue":"high"}]});
        assert!(verify_effort_set(&applied, "high").is_ok());
        assert!(verify_effort_set(&session, "high").is_err());
    }

    #[test]
    fn acp_catalog_pins_provider_and_uses_only_each_rows_ladder() {
        let catalog = json!({"current": {"provider": "first", "model": "shared"}, "models": [
            {"provider": "second", "name": "shared", "authenticated": true,
             "context": 200000, "effortLevels": ["low", "low", "medium", "turbo", "high"]},
            {"provider": "first", "name": "shared", "authenticated": true,
             "context": 100000, "effortLevels": ["low", "xhigh", "ultra"]},
            {"provider": "third", "name": "plain", "authenticated": true,
             "context": 50000, "effortLevels": []},
            {"provider": "fourth", "name": "hidden", "authenticated": false,
             "effortLevels": ["max"]},
            {"provider": "second", "name": "shared", "authenticated": true,
             "effortLevels": ["ultra"]}
        ]});
        let models = models_from_acp(&catalog).unwrap();
        assert_eq!(
            models.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            ["first/shared", "second/shared", "third/plain"]
        );
        assert_eq!(
            models[0].reasoning_levels,
            [
                harness_proto::ReasoningLevel::Low,
                harness_proto::ReasoningLevel::XHigh,
                harness_proto::ReasoningLevel::Ultra
            ]
        );
        assert_eq!(
            models[1].reasoning_levels,
            [
                harness_proto::ReasoningLevel::Low,
                harness_proto::ReasoningLevel::Medium,
                harness_proto::ReasoningLevel::High
            ]
        );
        assert!(models[2].reasoning_levels.is_empty());
    }
}
