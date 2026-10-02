//! The model catalog behind `model/list`, shared by every connection.
//!
//! Listing an agent's models means starting the agent (Claude Code takes about two seconds
//! cold, graff a few hundred milliseconds), and `model/list` used to wait for the slowest one
//! on every call. The catalog is now probed once per process, saved under `CODEX_HOME`, and
//! refreshed in the background, so a launch after the first answers from the saved copy and
//! the TUI never waits on an agent starting. Even working out which agents are enabled waits
//! on the login-shell PATH snapshot (about a second), so the saved copy is served first and
//! that check happens in the refresh.

use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use harness_engine::HarnessRegistry;
use harness_proto::HarnessId;
use serde_json::{Value, json};

use crate::methods::{harness_ids, harness_slug, qualified};

/// Reasoning efforts the Codex TUI knows how to parse.
const CODEX_EFFORTS: [&str; 6] = ["none", "minimal", "low", "medium", "high", "xhigh"];
const PROBE_TIMEOUT: Duration = Duration::from_secs(15);
/// A catalog older than this is refreshed in the background when the picker asks for it.
const STALE_AFTER: Duration = Duration::from_secs(300);
/// A second refresh that was queued behind a running one has nothing left to do.
const JUST_REFRESHED: Duration = Duration::from_secs(2);

#[derive(Clone)]
struct Entry {
    harness: HarnessId,
    models: Vec<Value>,
}

#[derive(Default)]
struct State {
    entries: Vec<Entry>,
    refreshed: Option<Instant>,
    loaded_from_disk: bool,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(Mutex::default)
}

/// Held while probing, so concurrent callers share one round of agent launches.
static REFRESH: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Start filling the catalog before any client connects.
pub fn prewarm(registry: Arc<HarnessRegistry>) {
    tokio::spawn(async move {
        load_from_disk();
        refresh(&registry).await;
    });
}

/// The `model/list` payload: every enabled agent's models, first agent's first model default.
pub async fn list(registry: &Arc<HarnessRegistry>) -> Vec<Value> {
    load_from_disk();
    if has_entries() {
        if is_stale() && REFRESH.try_lock().is_ok() {
            let registry = registry.clone();
            tokio::spawn(async move { refresh(&registry).await });
        }
    } else {
        // First launch on this machine: nothing to show until the agents have answered.
        refresh(registry).await;
    }
    assemble()
}

fn has_entries() -> bool {
    !state().lock().expect("model state").entries.is_empty()
}

fn is_stale() -> bool {
    let state = state().lock().expect("model state");
    state.refreshed.is_none_or(|at| at.elapsed() > STALE_AFTER)
}

fn assemble() -> Vec<Value> {
    let state = state().lock().expect("model state");
    let mut out: Vec<Value> = Vec::new();
    for entry in &state.entries {
        for model in &entry.models {
            let mut model = model.clone();
            model["isDefault"] = json!(out.is_empty());
            out.push(model);
        }
    }
    out
}

async fn refresh(registry: &Arc<HarnessRegistry>) {
    let _round = REFRESH.lock().await;
    if has_entries()
        && state()
            .lock()
            .expect("model state")
            .refreshed
            .is_some_and(|at| at.elapsed() < JUST_REFRESHED)
    {
        return;
    }
    let ids = harness_ids(registry).await;
    let probes = futures::future::join_all(ids.iter().map(|id| probe(registry.clone(), *id)));
    let results = probes.await;
    {
        let mut state = state().lock().expect("model state");
        let mut previous = std::mem::take(&mut state.entries);
        // Follow the registry's order and drop agents that are no longer enabled; a failed
        // probe keeps that agent's previous answer instead of dropping it.
        for (id, models) in ids.iter().zip(results) {
            let kept = previous
                .iter()
                .position(|e| e.harness == *id)
                .map(|at| previous.remove(at));
            match (models, kept) {
                (Some(models), _) => state.entries.push(Entry {
                    harness: *id,
                    models,
                }),
                (None, Some(entry)) => state.entries.push(entry),
                (None, None) => {}
            }
        }
        state.refreshed = Some(Instant::now());
    }
    save_to_disk();
}

async fn probe(registry: Arc<HarnessRegistry>, id: HarnessId) -> Option<Vec<Value>> {
    let started = Instant::now();
    // Resolving can wait on the login-shell PATH snapshot, so keep it off the async threads.
    let harness = {
        let registry = registry.clone();
        tokio::task::spawn_blocking(move || registry.resolve(id))
            .await
            .ok()?
            .ok()?
    };
    let models = match tokio::time::timeout(PROBE_TIMEOUT, harness.models()).await {
        Ok(Ok(models)) => models,
        Ok(Err(error)) => {
            tracing::warn!(?id, %error, "model list failed");
            return None;
        }
        Err(_) => {
            tracing::warn!(?id, "model list timed out");
            return None;
        }
    };
    tracing::info!(
        ?id,
        ms = started.elapsed().as_millis() as u64,
        "models probed"
    );
    let name = harness.display_name().to_owned();
    Some(
        models
            .iter()
            .map(|model| {
                let efforts: Vec<String> = model
                    .reasoning_levels
                    .iter()
                    .filter_map(|level| serde_json::to_value(level).ok())
                    .filter_map(|v| v.as_str().map(str::to_owned))
                    .filter(|level| CODEX_EFFORTS.contains(&level.as_str()))
                    .collect();
                let default_effort = if efforts.iter().any(|e| e == "medium") {
                    "medium".to_owned()
                } else {
                    efforts.first().cloned().unwrap_or_else(|| "medium".into())
                };
                let id = qualified(id, &model.id);
                json!({
                    "id": id,
                    "model": id,
                    "displayName": format!("{name} · {}", model.label),
                    "description": model.description.clone().unwrap_or_default(),
                    "hidden": false,
                    "isDefault": false,
                    "defaultReasoningEffort": default_effort,
                    "supportedReasoningEfforts": efforts
                        .iter()
                        .map(|e| json!({ "reasoningEffort": e, "description": "" }))
                        .collect::<Vec<_>>(),
                    "inputModalities": ["text", "image"],
                })
            })
            .collect(),
    )
}

fn cache_path() -> std::path::PathBuf {
    crate::config::codex_home().join("model-cache.json")
}

/// Read the saved catalog once per process; a missing or unreadable file is just a cold start.
fn load_from_disk() {
    let mut state = state().lock().expect("model state");
    if std::mem::replace(&mut state.loaded_from_disk, true) {
        return;
    }
    let Ok(text) = std::fs::read_to_string(cache_path()) else {
        return;
    };
    let Ok(saved) = serde_json::from_str::<Value>(&text) else {
        return;
    };
    for item in saved["entries"].as_array().into_iter().flatten() {
        let harness = item["harness"]
            .as_str()
            .and_then(|slug| serde_json::from_value(Value::String(slug.to_owned())).ok());
        let models = item["models"].as_array().cloned();
        if let (Some(harness), Some(models)) = (harness, models) {
            state.entries.push(Entry { harness, models });
        }
    }
}

fn save_to_disk() {
    let entries: Vec<Value> = state()
        .lock()
        .expect("model state")
        .entries
        .iter()
        .map(|e| json!({ "harness": harness_slug(e.harness), "models": e.models }))
        .collect();
    let path = cache_path();
    let Some(dir) = path.parent() else { return };
    let staged = dir.join(format!(".model-cache-{}.tmp", std::process::id()));
    let body = json!({ "version": 1, "entries": entries }).to_string();
    let written = std::fs::create_dir_all(dir)
        .and_then(|()| std::fs::write(&staged, body))
        .and_then(|()| std::fs::rename(&staged, &path));
    if let Err(error) = written {
        tracing::warn!(%error, "could not save the model cache");
    }
}
