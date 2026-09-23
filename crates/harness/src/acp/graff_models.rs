//! graff advertises no model config option over ACP, so the picker is built
//! the way codegraff's TUI builds it: the live `graff models` catalog (provider
//! + name), narrowed to providers `graff route` reports as reachable. `--schema`
//! is SDK codegen and omits Codex seats such as `gpt-6-sol`. The pick is
//! applied as `graff acp --model <name>` at launch.

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

use harness_proto::{Model, ReasoningLevel};

use crate::HarnessError;
use crate::process::{Command, Stdio};

pub(super) fn launch_args(model: Option<&str>) -> Vec<String> {
    match model.map(str::trim).filter(|m| !m.is_empty()) {
        Some(model) => vec!["--model".into(), seat_name(model).into()],
        None => Vec::new(),
    }
}

fn seat_name(id: &str) -> &str {
    id.split_once(':')
        .filter(|(provider, name)| !provider.is_empty() && !name.is_empty() && !provider.contains('/'))
        .map(|(_, name)| name)
        .unwrap_or(id)
}

pub(super) async fn discover(exe: &Path, timeout: Duration) -> Result<Vec<Model>, HarnessError> {
    let route = run(exe, &["route"], timeout).await?;
    let (default, providers, advertised) = parse_route(&route);
    if providers.is_empty() {
        return Err(HarnessError::Protocol(
            "graff has no reachable provider — run `graff login`".into(),
        ));
    }
    let listing = run(exe, &["models"], timeout).await?;
    let mut seats = parse_models_listing(&listing);
    promote_missing_codex_seats(&mut seats, &providers);
    let models = models_from_seats(
        &seats,
        &providers,
        default.as_deref(),
        &advertised,
    );
    if models.is_empty() {
        return Err(HarnessError::Protocol(
            "graff models listed nothing for reachable providers".into(),
        ));
    }
    Ok(models)
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
                reasoning_levels: effort_levels(&seat.provider, &seat.name),
                options: Vec::new(),
            }
        })
        .collect()
}

fn effort_levels(provider: &str, name: &str) -> Vec<ReasoningLevel> {
    use ReasoningLevel::*;
    let grok = provider == "xai" || name.starts_with("grok");
    let openai = provider == "openai"
        || provider == "codex"
        || name.starts_with("gpt-")
        || name.starts_with("openai/gpt-");
    if grok {
        vec![Low, Medium, High, XHigh]
    } else if openai {
        vec![Low, Medium, High, XHigh, Ultra]
    } else {
        vec![Low, Medium, High, XHigh, Max, Ultra]
    }
}

/// One entry per bare model name. Session default, then close siblings
/// (`grok-4.7` next to `grok-4.6`), then the seats `graff route` prints,
/// with logged-in first-party providers beating OpenRouter aliases.
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
            reasoning_levels: effort_levels(provider, name),
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
        assert_eq!(models[1].description.as_deref(), Some("codex · 1050k context"));
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
            models.iter().find(|m| m.id == "gpt-5.6-sol").unwrap().description.as_deref(),
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
            .find(|m| m.label == "gpt-6-sol" && m.description.as_deref() == Some("codex · 272k context"))
            .expect("codex gpt-6-sol");
        assert_eq!(sol.id, "gpt-6-sol");
        assert!(sol.reasoning_levels.contains(&harness_proto::ReasoningLevel::Ultra));
        assert!(!models.iter().any(|m| m.label.contains(":batch")));
    }
}
