//! graff advertises no model config option over ACP, so the picker is built
//! the way codegraff's own desktop app builds it: the catalog from
//! `graff --schema`, narrowed to the providers `graff route` reports as
//! reachable (logged in or keyed). The pick is applied at launch with
//! `graff acp --model <name>` — a bare name, which graff routes to a provider
//! exactly like its own `/model`.

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

use zeron_proto::Model;

use crate::HarnessError;
use crate::process::{Command, Stdio};

pub(super) fn launch_args(model: Option<&str>) -> Vec<String> {
    match model.map(str::trim).filter(|m| !m.is_empty()) {
        Some(model) => vec!["--model".into(), model.into()],
        None => Vec::new(),
    }
}

pub(super) async fn discover(exe: &Path, timeout: Duration) -> Result<Vec<Model>, HarnessError> {
    let route = run(exe, &["route"], timeout).await?;
    let (default, providers) = parse_route(&route);
    if providers.is_empty() {
        return Err(HarnessError::Protocol(
            "graff has no reachable provider — run `graff login`".into(),
        ));
    }
    let schema = run(exe, &["--schema"], timeout).await?;
    let schema: serde_json::Value = serde_json::from_str(&schema)
        .map_err(|e| HarnessError::Protocol(format!("graff --schema: {e}")))?;
    Ok(models_from_schema(&schema, &providers, default.as_deref()))
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
/// Returns the default model name and the provider ids in table order.
fn parse_route(text: &str) -> (Option<String>, Vec<String>) {
    let default = text.lines().find_map(|line| {
        let seat = line.trim().strip_prefix("session default:")?;
        let seat = seat.split_whitespace().next()?;
        Some(seat.split_once('/').map_or(seat, |(_, model)| model).to_string())
    });
    let providers = text
        .lines()
        .skip_while(|line| !line.trim_start().starts_with("provider"))
        .skip(1)
        .take_while(|line| !line.trim().is_empty())
        .filter_map(|line| line.split_whitespace().next().map(str::to_string))
        .collect();
    (default, providers)
}

/// One entry per bare model name (graff routes a name to its best reachable
/// provider), in provider order with graff's session default first.
fn models_from_schema(
    schema: &serde_json::Value,
    providers: &[String],
    default: Option<&str>,
) -> Vec<Model> {
    let Some(entries) = schema.get("models").and_then(|m| m.as_array()) else {
        return Vec::new();
    };
    let mut ranked: Vec<(usize, &str, &str, Option<u64>)> = entries
        .iter()
        .filter_map(|entry| {
            let provider = entry.get("provider")?.as_str()?;
            let name = entry.get("name")?.as_str()?;
            let rank = providers.iter().position(|p| p == provider)?;
            Some((rank, provider, name, entry.get("context").and_then(|c| c.as_u64())))
        })
        .collect();
    ranked.sort_by_key(|(rank, _, name, _)| (Some(*name) != default, *rank));

    let mut seen = HashSet::new();
    ranked
        .into_iter()
        .filter(|(_, _, name, _)| seen.insert(*name))
        .map(|(_, provider, name, context)| Model {
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
        let (default, providers) = parse_route(ROUTE);
        assert_eq!(default.as_deref(), Some("claude-sonnet-5"));
        assert_eq!(providers, vec!["codegraff", "codex"]);
    }

    #[test]
    fn keeps_reachable_models_default_first_and_deduplicated() {
        let schema = serde_json::json!({"models": [
            {"provider": "anthropic", "name": "claude-opus-5", "context": 1000000},
            {"provider": "codex", "name": "gpt-5.6-sol", "context": 1050000},
            {"provider": "codegraff", "name": "gpt-5.6-sol", "context": 1050000},
            {"provider": "codegraff", "name": "claude-sonnet-5", "context": 1000000},
        ]});
        let (default, providers) = parse_route(ROUTE);
        let models = models_from_schema(&schema, &providers, default.as_deref());
        let ids: Vec<&str> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, vec!["claude-sonnet-5", "gpt-5.6-sol"]);
        assert_eq!(models[1].description.as_deref(), Some("codegraff · 1050k context"));
    }

    #[test]
    fn launch_args_pass_the_bare_model() {
        assert_eq!(launch_args(Some("k3")), vec!["--model", "k3"]);
        assert!(launch_args(Some(" ")).is_empty());
        assert!(launch_args(None).is_empty());
    }
}
