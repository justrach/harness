//! HarnessRegistry — the engine's harness catalog: eager instances (mock) plus lazy
//! slots resolved on first use (claude-code spawns subprocess discovery; codex/cursor
//! later). Lazy slots carry a static descriptor so `ListHarnesses` never forces a spawn.
//!
//! Also owns the device's harness ENABLEMENT (Settings → Agents): which harnesses
//! this device's composer offers, persisted in `{data_dir}/harness-prefs.json`.
//! Per-device because CLI installs are — a viewer retargets the settings page at
//! another device and edits THAT device's set over the forwarded RPCs.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Mutex, MutexGuard, PoisonError,
    atomic::{AtomicBool, Ordering},
};

use serde::{Deserialize, Serialize};

use harness_adapters::{Harness, HarnessError, mock::MockHarness};
use harness_proto::{AgentEvent, DoneStatus, HarnessId, ReasoningLevel, SteeringMode};

/// What `ListHarnesses` reports per harness.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HarnessDescriptor {
    pub id: HarnessId,
    pub name: String,
    pub supports_steering: bool,
    pub steering_mode: SteeringMode,
    pub reasoning_levels: Vec<ReasoningLevel>,
    /// Whether the agent's CLI is present on the listing device (the settings
    /// enable-gate). Defaults true so catalogs from engines predating the
    /// field never read as uninstallable.
    #[serde(default = "default_installed")]
    pub installed: bool,
    /// Explicit CLI installation is available on this listing device.
    #[serde(default)]
    pub can_install: bool,
    /// Whether the listing device offers this harness (Settings → Agents).
    /// `None` — the catalog came from an engine predating the setting — means
    /// "unknown": consumers fall back to detection (see [`descriptor_enabled`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
}

impl HarnessDescriptor {
    /// Whether this harness can accept a prompt inside the turn that is
    /// currently running. Turn-boundary steering is still useful to the
    /// automatic queue drain, but it is not the non-interrupting "Steer"
    /// action exposed on an individual queued row.
    pub fn steers_mid_turn(&self) -> bool {
        self.supports_steering && self.steering_mode == SteeringMode::StepBoundary
    }
}

fn default_installed() -> bool {
    true
}

/// Whether detection alone may switch a harness on. The mock always "resolves"
/// but is a test rig, and counting it would let the last real agent be turned
/// off (the composer needs something it can actually run); the dev rig opts it
/// in through `COMET_HARNESS=mock`, which bypasses enablement in the pickers.
fn auto_enabled(id: HarnessId) -> bool {
    id != HarnessId::Mock
}

/// The agents this build offers out of the box: found ⇒ on unless the user
/// switched them off. Every other agent is OFF by default — found or not —
/// until the user turns it on in Settings → Agents (recorded as an opt-in).
pub fn default_on(id: HarnessId) -> bool {
    matches!(
        id,
        HarnessId::Graff | HarnessId::Codex | HarnessId::ClaudeCode
    )
}

/// A descriptor's effective enabled flag. `None` — a catalog from an engine
/// predating the setting — falls back to the rule a fresh device starts from
/// (installed default-on agents only; see [`HarnessRegistry::enabled_set`]).
pub fn descriptor_enabled(descriptor: &HarnessDescriptor) -> bool {
    descriptor
        .enabled
        .unwrap_or_else(|| descriptor.installed && default_on(descriptor.id))
}

fn describe(harness: &dyn Harness) -> HarnessDescriptor {
    HarnessDescriptor {
        id: harness.id(),
        name: harness.display_name().to_string(),
        supports_steering: harness.supports_steering(),
        steering_mode: harness.steering_mode(),
        reasoning_levels: harness.reasoning_levels().to_vec(),
        installed: harness.installed(),
        can_install: false,
        enabled: None,
    }
}

/// The persisted shape of `harness-prefs.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct HarnessPrefsFile {
    /// The user's explicit opt-OUTS. A found [`default_on`] agent is otherwise
    /// on, so an install of one turns itself on without a trip to Settings.
    #[serde(deserialize_with = "known_harnesses")]
    disabled: Vec<HarnessId>,
    /// The user's explicit opt-INS for agents that are off by default (see
    /// [`default_on`]). Still gated on detection: an opted-in agent whose CLI
    /// goes missing drops out until it is found again.
    #[serde(skip_serializing_if = "Vec::is_empty", deserialize_with = "known_harnesses")]
    opted_in: Vec<HarnessId>,
    titles: TitleSettings,
    graff_draft_subagents: bool,
    /// The allow-list written back when enablement was a fixed default set.
    /// Read once, folded into `disabled`, and never written again.
    #[serde(skip_serializing, deserialize_with = "known_harnesses_opt")]
    enabled: Option<Vec<HarnessId>>,
}

/// Agent ids this build knows, skipping the rest: a prefs file written by a
/// newer build (an agent added since) must not fail as a whole, which reset
/// every opt-out and opt-in to the defaults.
fn known_harnesses<'de, D>(deserializer: D) -> Result<Vec<HarnessId>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = Vec::<serde_json::Value>::deserialize(deserializer)?;
    Ok(raw
        .into_iter()
        .filter_map(|value| serde_json::from_value(value).ok())
        .collect())
}

fn known_harnesses_opt<'de, D>(deserializer: D) -> Result<Option<Vec<HarnessId>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    known_harnesses(deserializer).map(Some)
}

/// Per-device automatic session title preferences.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TitleSettings {
    /// None follows the session harness, using a supported installed fallback.
    /// An id from a newer build reads as None instead of failing the file.
    #[serde(deserialize_with = "known_harness_opt")]
    pub harness: Option<HarnessId>,
    /// None selects the cheapest model offered by the selected harness.
    pub model: Option<String>,
}

fn known_harness_opt<'de, D>(deserializer: D) -> Result<Option<HarnessId>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(raw.and_then(|value| serde_json::from_value(value).ok()))
}

type Factory = Box<dyn Fn() -> Result<Arc<dyn Harness>, HarnessError> + Send + Sync>;
type InstalledProbe = Box<dyn Fn() -> bool + Send + Sync>;

enum Slot {
    Ready(Arc<dyn Harness>),
    Lazy {
        descriptor: HarnessDescriptor,
        /// Re-run on every `descriptors()` call — a CLI installed mid-session
        /// shows up on the next settings/picker open, no restart needed.
        installed: InstalledProbe,
        factory: Factory,
    },
}

pub struct HarnessRegistry {
    pub(crate) installs: crate::rpc::Installations,
    slots: Mutex<HashMap<HarnessId, Slot>>,
    order: Mutex<Vec<HarnessId>>,
    /// This device's enabled set; `None` inner value = the default set.
    prefs: Mutex<HarnessPrefsFile>,
    graff_draft_subagents: Arc<AtomicBool>,
    /// Where the prefs persist; `None` (tests, bare registries) skips writes.
    prefs_path: Mutex<Option<PathBuf>>,
}

impl Default for HarnessRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl HarnessRegistry {
    pub fn new() -> Self {
        Self {
            installs: Default::default(),
            slots: Mutex::new(HashMap::new()),
            order: Mutex::new(Vec::new()),
            prefs: Mutex::new(HarnessPrefsFile::default()),
            graff_draft_subagents: Arc::new(AtomicBool::new(false)),
            prefs_path: Mutex::new(None),
        }
    }

    fn slots(&self) -> MutexGuard<'_, HashMap<HarnessId, Slot>> {
        self.slots.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn order(&self) -> MutexGuard<'_, Vec<HarnessId>> {
        self.order.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn prefs(&self) -> MutexGuard<'_, HarnessPrefsFile> {
        self.prefs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Load `harness-prefs.json` from the engine data dir and remember the
    /// path for writes. Corrupt/missing files fall back to the default set.
    pub fn load_prefs(&self, data_dir: &Path) {
        let path = data_dir.join("harness-prefs.json");
        let loaded = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str::<HarnessPrefsFile>(&text).ok())
            .unwrap_or_default();
        self.graff_draft_subagents
            .store(loaded.graff_draft_subagents, Ordering::Relaxed);
        *self.prefs() = loaded;
        *self
            .prefs_path
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(path);
        self.migrate_legacy_prefs();
    }

    /// Fold a legacy allow-list into the opt-out/opt-in shape: a registered
    /// default-on harness missing from it was a deliberate "no", so it stays
    /// off; an off-by-default harness listed in it was a deliberate "yes", so
    /// it becomes an opt-in. Rewrites the file once, which is what lets later
    /// installs of default-on agents auto-enable.
    fn migrate_legacy_prefs(&self) {
        let legacy = { self.prefs().enabled.take() };
        let Some(legacy) = legacy else { return };
        let registered: Vec<HarnessId> = self.order().iter().copied().collect();
        let disabled: Vec<HarnessId> = registered
            .into_iter()
            .filter(|id| default_on(*id) && !legacy.contains(id))
            .collect();
        let mut opted_in: Vec<HarnessId> = Vec::new();
        for id in legacy {
            if auto_enabled(id) && !default_on(id) && !opted_in.contains(&id) {
                opted_in.push(id);
            }
        }
        {
            let mut prefs = self.prefs();
            prefs.disabled = disabled;
            prefs.opted_in = opted_in;
        }
        self.persist_prefs();
    }

    /// What this device offers: every harness whose CLI is FOUND and that is
    /// either [`default_on`] or opted in by the user, minus the user's
    /// explicit opt-outs. Installing a default-on agent is all it takes for
    /// it to appear in the composer; any other agent also needs a Settings
    /// toggle.
    pub fn enabled_set(&self) -> Vec<HarnessId> {
        // Both guards drop before the installed probes run: `descriptors()`
        // takes `slots` then `order`, so holding `order` across a probe (which
        // takes `slots`) would invert the lock order.
        let registered: Vec<HarnessId> = self.order().iter().copied().collect();
        let (disabled, opted_in) = {
            let prefs = self.prefs();
            (prefs.disabled.clone(), prefs.opted_in.clone())
        };
        registered
            .into_iter()
            .filter(|id| {
                auto_enabled(*id)
                    && !disabled.contains(id)
                    && (default_on(*id) || opted_in.contains(id))
                    && self.installed_for(*id)
            })
            .collect()
    }

    /// Whether this device's CLI probe passes for `id` (no spawn, no resolve).
    fn installed_for(&self, id: HarnessId) -> bool {
        match self.slots().get(&id) {
            Some(Slot::Ready(harness)) => harness.installed(),
            Some(Slot::Lazy { installed, .. }) => installed(),
            None => false,
        }
    }

    /// Flip one harness's enablement and persist. Refuses unknown harnesses,
    /// enabling one whose CLI is missing (the settings gate, enforced where
    /// the state lives), and disabling the last enabled harness — everything
    /// enabled is installed and so runnable, so the last one standing is
    /// always worth protecting (the composer needs something to run). A
    /// harness whose CLI is missing is never enabled in the first place, so
    /// turning it off is a clean no-op. When no default-on agent is found the
    /// set starts empty and the user enables an installed one from Settings.
    pub fn set_enabled(&self, id: HarnessId, on: bool) -> Result<(), String> {
        if !self.slots().contains_key(&id) {
            return Err(format!("unknown harness {id:?}"));
        }
        if on && !auto_enabled(id) {
            return Err(format!("{id:?} cannot be enabled from Settings"));
        }
        if on && !self.installed_for(id) {
            return Err(format!("{id:?} CLI is not installed on this device"));
        }
        let enabled = self.enabled_set();
        match (on, enabled.contains(&id)) {
            (true, false) => {
                let mut prefs = self.prefs();
                prefs.disabled.retain(|h| *h != id);
                if !default_on(id) && !prefs.opted_in.contains(&id) {
                    prefs.opted_in.push(id);
                }
            }
            (false, true) => {
                if enabled.len() == 1 {
                    return Err("cannot disable the last enabled harness".into());
                }
                let mut prefs = self.prefs();
                prefs.opted_in.retain(|h| *h != id);
                // Off-by-default agents need no opt-out once the opt-in is
                // gone; a default-on one records the "no".
                if default_on(id) && !prefs.disabled.contains(&id) {
                    prefs.disabled.push(id);
                }
            }
            _ => return Ok(()),
        }
        self.persist_prefs();
        Ok(())
    }

    /// Best-effort atomic write (temp + rename, the ui-settings pattern).
    fn persist_prefs(&self) {
        let Some(path) = self
            .prefs_path
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
        else {
            return;
        };
        let json = match serde_json::to_string_pretty(&*self.prefs()) {
            Ok(json) => json,
            Err(err) => {
                tracing::warn!(error = %err, "harness-prefs serialize failed");
                return;
            }
        };
        let tmp = path.with_extension("json.tmp");
        if let Err(err) = std::fs::write(&tmp, json).and_then(|()| std::fs::rename(&tmp, &path)) {
            tracing::warn!(error = %err, "harness-prefs save failed");
        }
    }

    pub fn title_settings(&self) -> TitleSettings {
        self.prefs().titles.clone()
    }

    pub fn graff_draft_subagents(&self) -> bool {
        self.prefs().graff_draft_subagents
    }

    pub fn set_graff_draft_subagents(&self, enabled: bool) {
        self.prefs().graff_draft_subagents = enabled;
        self.graff_draft_subagents.store(enabled, Ordering::Relaxed);
        self.persist_prefs();
    }

    pub fn set_title_settings(&self, mut settings: TitleSettings) -> Result<(), String> {
        if let Some(id) = settings.harness {
            if !harness_adapters::supports_titles(id) || !self.enabled_set().contains(&id) {
                return Err("Choose an enabled harness that supports title generation".into());
            }
        } else if settings.model.is_some() {
            return Err("Choose a title harness before choosing a model".into());
        }
        settings.model = settings.model.filter(|model| !model.trim().is_empty());
        self.prefs().titles = settings;
        self.persist_prefs();
        Ok(())
    }

    pub fn register(&self, harness: Arc<dyn Harness>) {
        let id = harness.id();
        if self.slots().insert(id, Slot::Ready(harness)).is_none() {
            self.order().push(id);
        }
    }

    /// Register a slot resolved on first `resolve` (the factory result is
    /// cached). `installed` is the CLI-presence probe run per `descriptors()`
    /// call; it must never spawn.
    pub fn register_lazy(
        &self,
        descriptor: HarnessDescriptor,
        installed: InstalledProbe,
        factory: Factory,
    ) {
        let id = descriptor.id;
        if self
            .slots()
            .insert(
                id,
                Slot::Lazy {
                    descriptor,
                    installed,
                    factory,
                },
            )
            .is_none()
        {
            self.order().push(id);
        }
    }

    pub fn resolve(&self, id: HarnessId) -> Result<Arc<dyn Harness>, HarnessError> {
        let mut slots = self.slots();
        match slots.get(&id) {
            Some(Slot::Ready(harness)) => Ok(harness.clone()),
            Some(Slot::Lazy { factory, .. }) => {
                let harness = factory()?;
                slots.insert(id, Slot::Ready(harness.clone()));
                Ok(harness)
            }
            None => Err(HarnessError::NotInstalled(format!("{id:?}"))),
        }
    }

    /// Catalog for `ListHarnesses` — never forces a lazy resolve.
    pub fn descriptors(&self) -> Vec<HarnessDescriptor> {
        let enabled = self.enabled_set();
        let slots = self.slots();
        self.order()
            .iter()
            .filter_map(|id| {
                let mut descriptor = match slots.get(id) {
                    Some(Slot::Ready(harness)) => describe(harness.as_ref()),
                    Some(Slot::Lazy {
                        descriptor,
                        installed,
                        ..
                    }) => HarnessDescriptor {
                        installed: installed(),
                        ..descriptor.clone()
                    },
                    None => return None,
                };
                descriptor.enabled = Some(enabled.contains(id));
                descriptor.can_install = harness_adapters::install::can_install(*id);
                Some(descriptor)
            })
            .collect()
    }
}

/// The production registry: MockHarness (hidden from production pickers) plus a lazy
/// `claude-code` slot resolved through `harness_adapters` on first use (subprocess
/// discovery only happens when a run/model call actually needs it).
pub fn default_registry() -> HarnessRegistry {
    // Warm the login-shell PATH snapshot in the background so the first
    // claude/codex resolve doesn't pay the shell-startup latency inline.
    harness_adapters::shell_env::prewarm();
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(MockHarness {
        script: vec![
            AgentEvent::TextDelta {
                text: "## Streaming pipeline\n\nEvery turn flows through the same path:\n\n".into(),
            },
            AgentEvent::TextDelta {
                text: "1. **Doc command** — the composer queues a durable `run` entry\n2. **Host executor** — the chat's host device marks it processed, then dispatches\n3. **Fold** — events fold into parts and diff into the Loro doc every 120ms\n\n".into(),
            },
            AgentEvent::ToolCall {
                id: "mock-tool-1".into(),
                call: harness_proto::ToolCall::Exec {
                    command: "cargo test --workspace".into(),
                },
            },
            AgentEvent::ToolResult {
                id: "mock-tool-1".into(),
                is_error: false,
                output: None,
                diff: None,
            },
            AgentEvent::ToolCall {
                id: "mock-tool-2".into(),
                call: harness_proto::ToolCall::Exec {
                    command: "git log -5 --oneline --decorate && git merge-base HEAD origin/main"
                        .into(),
                },
            },
            AgentEvent::ToolResult {
                id: "mock-tool-2".into(),
                is_error: false,
                output: None,
                diff: None,
            },
            AgentEvent::TextDelta {
                text: "The `SegmentWriter` appends into `LoroText` so the oplog stays RLE-merged:\n\n```rust\nfolded = fold_event_into_parts(&folded, &event);\nwriter.sync(&folded)?; // 120ms coalesced commits\n```\n\nSynced to every device through the session room. *Mock harness reporting in.*".into(),
            },
            AgentEvent::Done {
                status: DoneStatus::Completed,
                result: None,
                error: None,
                session_id: None,
            },
        ],
    }));
    // graff over ACP (`graff acp`), registered first so it leads the picker.
    // Turn-boundary steering. Per-model effort comes from the live catalog;
    // session/new does not yet advertise thought_level.
    let graff_draft_subagents = registry.graff_draft_subagents.clone();
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Graff,
            name: "graff".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: vec![
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
                ReasoningLevel::Max,
                ReasoningLevel::Ultra,
            ],
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::AcpHarness::graff().installed()),
        Box::new(move || {
            Ok(Arc::new(
                harness_adapters::AcpHarness::graff()
                    .with_graff_draft_subagents(graff_draft_subagents.clone()),
            ) as Arc<dyn Harness>)
        }),
    );
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::ClaudeCode,
            name: "Claude Code".into(),
            supports_steering: true,
            steering_mode: SteeringMode::StepBoundary,
            // Must mirror ClaudeHarness exactly — the descriptor-stability
            // rule (see the codex test below).
            reasoning_levels: vec![
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
                ReasoningLevel::Max,
            ],
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::ClaudeHarness::new().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::ClaudeHarness::new()) as Arc<dyn Harness>)),
    );
    // Codex, same lazy pattern: the static descriptor mirrors AcpHarness::codex()
    // exactly (`describe()` after the first resolve must not change the
    // catalog entry) — "Codex" per the original HARNESS_LABEL, StepBoundary
    // steering via native `turn/steer`, and the unified reasoning ladder from
    // harness_adapters::codex::catalog. CLI discovery only happens when a
    // run/model call actually resolves the slot.
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Codex,
            name: "Codex".into(),
            supports_steering: true,
            steering_mode: SteeringMode::StepBoundary,
            reasoning_levels: vec![
                ReasoningLevel::Minimal,
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
                ReasoningLevel::Max,
                ReasoningLevel::Ultra,
            ],
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::CodexHarness::new().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::CodexHarness::new()) as Arc<dyn Harness>)),
    );
    // Cursor via the pinned @cursor/sdk shim (NOT ACP — that surface strips
    // subagent transcripts), same lazy pattern: the static descriptor mirrors
    // CursorHarness exactly. Turn-boundary steering; no effort ladder.
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Cursor,
            name: "Cursor".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: Vec::new(),
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::CursorHarness::new().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::CursorHarness::new()) as Arc<dyn Harness>)),
    );
    // Devin over ACP (`devin acp`), same lazy pattern: the static descriptor
    // mirrors AcpHarness::devin() exactly. No steering extension (turn
    // boundaries) and no effort ladder — Devin bakes effort into the
    // advertised model ids instead of a `thought_level` option.
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Devin,
            name: "Devin".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: Vec::new(),
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::AcpHarness::devin().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::AcpHarness::devin()) as Arc<dyn Harness>)),
    );
    // Grok Build over ACP, same lazy pattern: the static descriptor mirrors
    // AcpHarness::grok() exactly. No `_session/steering` extension yet, so
    // steers deliver at turn boundaries; the effort ladder applies per
    // session via the `thought_level` config option.
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Grok,
            name: "Grok".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: vec![
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
            ],
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::AcpHarness::grok().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::AcpHarness::grok()) as Arc<dyn Harness>)),
    );
    // Hermes Agent over ACP (`hermes acp`), same lazy pattern: the static
    // descriptor mirrors AcpHarness::hermes() exactly. No steering extension
    // (turn boundaries) and no effort ladder — Hermes exposes no effort
    // config over ACP today (hybrid reasoning is model-internal).
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Hermes,
            name: "Hermes".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: Vec::new(),
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::AcpHarness::hermes().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::AcpHarness::hermes()) as Arc<dyn Harness>)),
    );
    // pi over ACP (community `pi-acp` adapter), same lazy pattern: the static
    // descriptor mirrors AcpHarness::pi() exactly — turn-boundary steering,
    // pi's thinking ladder minus its "off" tier.
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Pi,
            name: "Pi".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: vec![
                ReasoningLevel::Minimal,
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
                ReasoningLevel::Max,
            ],
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::AcpHarness::pi().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::AcpHarness::pi()) as Arc<dyn Harness>)),
    );
    // opencode over its NATIVE HTTP/SSE protocol (the one the opencode
    // desktop app speaks — `opencode serve` + the /global/event bus), same
    // lazy pattern: the static descriptor mirrors OpencodeHarness exactly.
    // Turn-boundary steering; the effort ladder rides model VARIANTS (the
    // run sends the first advertised variant id for the picked level).
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Opencode,
            name: "OpenCode".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: vec![
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
                ReasoningLevel::Max,
            ],
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::OpencodeHarness::new().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::OpencodeHarness::new()) as Arc<dyn Harness>)),
    );
    // antigravity over acp (google's agy_acp_server), same lazy pattern: the
    // static descriptor mirrors AcpHarness::antigravity() exactly. No steering
    // extension (turn boundaries), and effort is baked into the model ids, so
    // the ladder lives on each model rather than the harness.
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Antigravity,
            name: "Antigravity".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: Vec::new(),
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::AcpHarness::antigravity().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::AcpHarness::antigravity()) as Arc<dyn Harness>)),
    );
    // Exo over ACP through Harness's own bridge (`harness exo-acp` → Exo's
    // agent-cli socket), same lazy pattern: the static descriptor mirrors
    // AcpHarness::exo() exactly. One whole reply per exchange, so steers
    // wait for the turn boundary; Exo owns its model and effort.
    registry.register_lazy(
        HarnessDescriptor {
            id: HarnessId::Exo,
            name: "Exo".into(),
            supports_steering: true,
            steering_mode: SteeringMode::TurnBoundary,
            reasoning_levels: Vec::new(),
            installed: true,
            can_install: false,
            enabled: None,
        },
        Box::new(|| harness_adapters::AcpHarness::exo().installed()),
        Box::new(|| Ok(Arc::new(harness_adapters::AcpHarness::exo()) as Arc<dyn Harness>)),
    );
    registry
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn graff_draft_subagents_defaults_off_and_survives_reload() {
        let data = tempfile::tempdir().unwrap();
        let registry = default_registry();
        registry.load_prefs(data.path());
        assert!(!registry.graff_draft_subagents());
        assert!(!registry.graff_draft_subagents.load(Ordering::Relaxed));

        registry.set_graff_draft_subagents(true);
        assert!(registry.graff_draft_subagents.load(Ordering::Relaxed));
        let reloaded = default_registry();
        reloaded.load_prefs(data.path());
        assert!(reloaded.graff_draft_subagents());
        assert!(reloaded.graff_draft_subagents.load(Ordering::Relaxed));

        reloaded.set_graff_draft_subagents(false);
        let again = default_registry();
        again.load_prefs(data.path());
        assert!(!again.graff_draft_subagents());
    }

    #[test]
    fn mid_turn_steering_requires_support_and_a_step_boundary() {
        let mut descriptor = HarnessDescriptor {
            id: HarnessId::Mock,
            name: "Mock".into(),
            supports_steering: true,
            steering_mode: SteeringMode::StepBoundary,
            reasoning_levels: Vec::new(),
            installed: true,
            can_install: false,
            enabled: Some(true),
        };
        assert!(descriptor.steers_mid_turn());

        descriptor.steering_mode = SteeringMode::TurnBoundary;
        assert!(!descriptor.steers_mid_turn());

        descriptor.steering_mode = SteeringMode::StepBoundary;
        descriptor.supports_steering = false;
        assert!(!descriptor.steers_mid_turn());
    }

    #[test]
    fn lazy_slot_lists_without_resolving() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let registry = HarnessRegistry::new();
        let calls = Arc::new(AtomicUsize::new(0));
        let counted = calls.clone();
        registry.register_lazy(
            HarnessDescriptor {
                id: HarnessId::Mock,
                name: "Lazy Mock".into(),
                supports_steering: true,
                steering_mode: SteeringMode::StepBoundary,
                reasoning_levels: vec![],
                installed: true,
                can_install: false,
                enabled: None,
            },
            Box::new(|| false),
            Box::new(move || {
                counted.fetch_add(1, Ordering::SeqCst);
                Err(HarnessError::NotInstalled("nope".into()))
            }),
        );
        let listed = registry.descriptors();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "Lazy Mock");
        // The listing runs the probe, not the stored placeholder.
        assert!(!listed[0].installed);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            0,
            "listing must not force a resolve"
        );
        assert!(registry.resolve(HarnessId::Mock).is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    /// The descriptor-stability rule, for every slot at once: a lazy slot's
    /// static descriptor (what Settings and pickers show before a run) must
    /// mirror the harness it resolves to. Grok's ladder drifted once — the
    /// spec gained XHigh, the descriptor did not.
    #[test]
    fn every_static_descriptor_mirrors_its_resolved_harness() {
        let registry = default_registry();
        for descriptor in registry.descriptors() {
            let harness = registry.resolve(descriptor.id).unwrap();
            let resolved = describe(harness.as_ref());
            assert_eq!(descriptor.name, resolved.name, "{:?} name", descriptor.id);
            assert_eq!(
                descriptor.supports_steering, resolved.supports_steering,
                "{:?} steering support",
                descriptor.id
            );
            assert_eq!(
                descriptor.steering_mode, resolved.steering_mode,
                "{:?} steering mode",
                descriptor.id
            );
            assert_eq!(
                descriptor.reasoning_levels, resolved.reasoning_levels,
                "{:?} reasoning ladder",
                descriptor.id
            );
        }
    }

    #[test]
    fn default_registry_lists_mock_claude_codex_and_grok_slots() {
        let registry = default_registry();
        let ids: Vec<HarnessId> = registry.descriptors().iter().map(|d| d.id).collect();
        assert_eq!(
            ids,
            vec![
                HarnessId::Mock,
                HarnessId::Graff,
                HarnessId::ClaudeCode,
                HarnessId::Codex,
                HarnessId::Cursor,
                HarnessId::Devin,
                HarnessId::Grok,
                HarnessId::Hermes,
                HarnessId::Pi,
                HarnessId::Opencode,
                HarnessId::Antigravity,
                HarnessId::Exo
            ]
        );
        assert!(registry.resolve(HarnessId::Mock).is_ok());
        assert!(registry.resolve(HarnessId::ClaudeCode).is_ok());
        // A codex-configured chat resolves the right harness (construction is
        // cheap; CLI discovery is deferred to models()/run()).
        let codex = registry.resolve(HarnessId::Codex).unwrap();
        assert_eq!(codex.id(), HarnessId::Codex);
        // Grok resolves through the shared ACP harness; its descriptor must
        // mirror the resolved harness (descriptor-stability rule).
        let grok = registry.resolve(HarnessId::Grok).unwrap();
        assert_eq!(grok.id(), HarnessId::Grok);
        assert_eq!(grok.display_name(), "Grok");
        assert_eq!(grok.steering_mode(), SteeringMode::TurnBoundary);
        assert_eq!(
            grok.reasoning_levels(),
            &[
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh
            ]
        );
        // Cursor, Devin, Hermes and Pi mirror their specs the same way.
        let cursor = registry.resolve(HarnessId::Cursor).unwrap();
        assert_eq!(cursor.id(), HarnessId::Cursor);
        assert_eq!(cursor.display_name(), "Cursor");
        assert_eq!(cursor.steering_mode(), SteeringMode::TurnBoundary);
        assert!(cursor.reasoning_levels().is_empty());
        let devin = registry.resolve(HarnessId::Devin).unwrap();
        assert_eq!(devin.id(), HarnessId::Devin);
        assert_eq!(devin.display_name(), "Devin");
        assert_eq!(devin.steering_mode(), SteeringMode::TurnBoundary);
        assert!(devin.reasoning_levels().is_empty());
        let hermes = registry.resolve(HarnessId::Hermes).unwrap();
        assert_eq!(hermes.id(), HarnessId::Hermes);
        assert_eq!(hermes.display_name(), "Hermes");
        assert_eq!(hermes.steering_mode(), SteeringMode::TurnBoundary);
        assert!(hermes.reasoning_levels().is_empty());
        let exo = registry.resolve(HarnessId::Exo).unwrap();
        assert_eq!(exo.id(), HarnessId::Exo);
        assert_eq!(exo.display_name(), "Exo");
        assert_eq!(exo.steering_mode(), SteeringMode::TurnBoundary);
        assert!(exo.reasoning_levels().is_empty());
        let opencode = registry.resolve(HarnessId::Opencode).unwrap();
        assert_eq!(opencode.id(), HarnessId::Opencode);
        assert_eq!(opencode.display_name(), "OpenCode");
        assert_eq!(opencode.steering_mode(), SteeringMode::TurnBoundary);
        assert_eq!(
            opencode.reasoning_levels(),
            &[
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
                ReasoningLevel::Max,
            ]
        );
        let antigravity = registry.resolve(HarnessId::Antigravity).unwrap();
        assert_eq!(antigravity.id(), HarnessId::Antigravity);
        assert_eq!(antigravity.display_name(), "Antigravity");
        assert_eq!(antigravity.steering_mode(), SteeringMode::TurnBoundary);
        assert!(antigravity.reasoning_levels().is_empty());
        let pi = registry.resolve(HarnessId::Pi).unwrap();
        assert_eq!(pi.id(), HarnessId::Pi);
        assert_eq!(pi.display_name(), "Pi");
        assert_eq!(pi.steering_mode(), SteeringMode::TurnBoundary);
        assert_eq!(
            pi.reasoning_levels(),
            &[
                ReasoningLevel::Minimal,
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
                ReasoningLevel::Max
            ]
        );
    }

    /// Catalogs serialized by engines that predate the `installed`/`enabled`
    /// fields must keep deserializing — installed, and enabled per the
    /// detection fallback.
    #[test]
    fn descriptor_without_new_fields_parses_with_fallbacks() {
        let parse = |id: &str| -> HarnessDescriptor {
            serde_json::from_str(&format!(
                r#"{{
                    "id": "{id}",
                    "name": "x",
                    "supportsSteering": true,
                    "steeringMode": "step-boundary",
                    "reasoningLevels": []
                }}"#
            ))
            .unwrap()
        };
        let claude = parse("claude-code");
        assert!(claude.installed);
        assert!(!claude.can_install);
        assert_eq!(claude.enabled, None);
        // Unknown enablement follows the fresh-device rule: a found
        // default-on CLI is offered...
        assert!(descriptor_enabled(&claude));
        // ...a found off-by-default one is not...
        assert!(parse("grok").installed);
        assert!(!descriptor_enabled(&parse("grok")));
        // ...and one this device never found is not.
        let missing = HarnessDescriptor {
            installed: false,
            can_install: false,
            ..parse("codex")
        };
        assert!(!descriptor_enabled(&missing));
    }

    /// A registry slot for the tests below: installed probe fixed, factory
    /// never expected to run.
    fn test_slot(registry: &HarnessRegistry, id: HarnessId, installed: bool) {
        registry.register_lazy(
            HarnessDescriptor {
                id,
                name: format!("{id:?}"),
                supports_steering: true,
                steering_mode: SteeringMode::StepBoundary,
                reasoning_levels: vec![],
                installed: true,
                can_install: false,
                enabled: None,
            },
            Box::new(move || installed),
            Box::new(|| Err(HarnessError::NotInstalled("test slot".into()))),
        );
    }

    /// A prefs file from a newer build names agents this build lacks; the
    /// known entries (and the titles) still load instead of the whole file
    /// falling back to defaults.
    #[test]
    fn prefs_from_a_newer_build_keep_their_known_entries() {
        let prefs: HarnessPrefsFile = serde_json::from_str(
            r#"{"disabled":["codex","future-agent"],"optedIn":["grok","another-new-one"],
                "titles":{"harness":"future-agent","model":"m"}}"#,
        )
        .unwrap();
        assert_eq!(prefs.disabled, vec![HarnessId::Codex]);
        assert_eq!(prefs.opted_in, vec![HarnessId::Grok]);
        assert_eq!(prefs.titles.harness, None);
        assert_eq!(prefs.titles.model.as_deref(), Some("m"));
        let legacy: HarnessPrefsFile =
            serde_json::from_str(r#"{"enabled":["claude-code","future-agent"]}"#).unwrap();
        assert_eq!(legacy.enabled, Some(vec![HarnessId::ClaudeCode]));
        let empty: HarnessPrefsFile = serde_json::from_str("{}").unwrap();
        assert!(empty.disabled.is_empty() && empty.enabled.is_none());
    }

    /// `descriptors()` stamps the per-device enabled flag; `set_enabled`
    /// guards the gate (no enabling missing CLIs, no disabling the last one)
    /// and persists across a reload.
    #[test]
    fn enablement_stamps_guards_and_persists() {
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.load_prefs(dir.path());
        test_slot(&registry, HarnessId::ClaudeCode, true);
        test_slot(&registry, HarnessId::Codex, true);
        test_slot(&registry, HarnessId::Grok, true);
        test_slot(&registry, HarnessId::Hermes, false);

        // With no prefs file at all, the found default-on CLIs are on; the
        // found off-by-default one and the missing one are off.
        let flags: Vec<(HarnessId, Option<bool>)> = registry
            .descriptors()
            .into_iter()
            .map(|d| (d.id, d.enabled))
            .collect();
        assert_eq!(
            flags,
            vec![
                (HarnessId::ClaudeCode, Some(true)),
                (HarnessId::Codex, Some(true)),
                (HarnessId::Grok, Some(false)),
                (HarnessId::Hermes, Some(false)),
            ]
        );

        // The gate: a missing CLI can't be enabled; unknown ids refuse.
        assert!(registry.set_enabled(HarnessId::Hermes, true).is_err());
        assert!(registry.set_enabled(HarnessId::Pi, true).is_err());
        assert!(registry.set_enabled(HarnessId::Mock, true).is_err());
        // Installed CLIs toggle both ways (Grok via an opt-in); no-op flips
        // are fine.
        registry.set_enabled(HarnessId::Grok, true).unwrap();
        registry.set_enabled(HarnessId::Grok, true).unwrap();
        registry.set_enabled(HarnessId::Codex, false).unwrap();
        registry.set_enabled(HarnessId::ClaudeCode, false).unwrap();
        // Grok is the last one standing — refusing keeps the composer usable.
        assert!(registry.set_enabled(HarnessId::Grok, false).is_err());
        assert_eq!(registry.enabled_set(), vec![HarnessId::Grok]);

        // A fresh registry over the same data dir reads the persisted opt-outs.
        let reloaded = HarnessRegistry::new();
        reloaded.load_prefs(dir.path());
        test_slot(&reloaded, HarnessId::ClaudeCode, true);
        test_slot(&reloaded, HarnessId::Codex, true);
        test_slot(&reloaded, HarnessId::Grok, true);
        assert_eq!(reloaded.enabled_set(), vec![HarnessId::Grok]);
    }

    /// A DEFAULT-ON agent installed after the user has already edited
    /// Settings turns itself on, while the ones they switched off stay off —
    /// and an off-by-default agent that appears stays off until opted in.
    #[test]
    fn newly_found_default_on_harnesses_enable_themselves_without_reviving_opt_outs() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.load_prefs(dir.path());
        test_slot(&registry, HarnessId::ClaudeCode, true);
        test_slot(&registry, HarnessId::Codex, true);
        // Not installed yet — the probes flip when the user installs the CLIs.
        let found = Arc::new(AtomicBool::new(false));
        for (id, name) in [(HarnessId::Graff, "graff"), (HarnessId::Grok, "Grok")] {
            let probe = Arc::clone(&found);
            registry.register_lazy(
                HarnessDescriptor {
                    id,
                    name: name.into(),
                    supports_steering: true,
                    steering_mode: SteeringMode::TurnBoundary,
                    reasoning_levels: vec![],
                    installed: true,
                    can_install: false,
                    enabled: None,
                },
                Box::new(move || probe.load(Ordering::SeqCst)),
                Box::new(|| Err(HarnessError::NotInstalled("test slot".into()))),
            );
        }
        registry.set_enabled(HarnessId::Codex, false).unwrap();
        assert_eq!(registry.enabled_set(), vec![HarnessId::ClaudeCode]);

        // The CLIs appear mid-session; no restart, no visit to Settings.
        // graff is default-on and joins; Grok is off by default and doesn't.
        found.store(true, Ordering::SeqCst);
        assert_eq!(
            registry.enabled_set(),
            vec![HarnessId::ClaudeCode, HarnessId::Graff]
        );
        // The opt-out survives the reload that picks the new agent up.
        let reloaded = HarnessRegistry::new();
        reloaded.load_prefs(dir.path());
        test_slot(&reloaded, HarnessId::ClaudeCode, true);
        test_slot(&reloaded, HarnessId::Codex, true);
        test_slot(&reloaded, HarnessId::Graff, true);
        test_slot(&reloaded, HarnessId::Grok, true);
        assert_eq!(
            reloaded.enabled_set(),
            vec![HarnessId::ClaudeCode, HarnessId::Graff]
        );
    }

    /// Only Graff, Codex and Claude Code are on out of the box; every other
    /// found agent needs an explicit opt-in, which persists — and turning it
    /// back off drops the opt-in instead of accumulating an opt-out.
    #[test]
    fn default_on_agents_enable_and_others_need_an_opt_in() {
        let all = [
            HarnessId::Graff,
            HarnessId::ClaudeCode,
            HarnessId::Codex,
            HarnessId::Cursor,
            HarnessId::Devin,
            HarnessId::Grok,
            HarnessId::Hermes,
            HarnessId::Pi,
            HarnessId::Opencode,
            HarnessId::Antigravity,
            HarnessId::Exo,
        ];
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.load_prefs(dir.path());
        for id in all {
            test_slot(&registry, id, true);
        }
        let defaults = vec![HarnessId::Graff, HarnessId::ClaudeCode, HarnessId::Codex];
        assert_eq!(registry.enabled_set(), defaults);
        for id in all {
            assert_eq!(default_on(id), defaults.contains(&id), "{id:?}");
        }
        assert!(!default_on(HarnessId::Mock));

        registry.set_enabled(HarnessId::Cursor, true).unwrap();
        registry.set_enabled(HarnessId::Pi, true).unwrap();
        registry.set_enabled(HarnessId::Codex, false).unwrap();
        let expected = vec![
            HarnessId::Graff,
            HarnessId::ClaudeCode,
            HarnessId::Cursor,
            HarnessId::Pi,
        ];
        assert_eq!(registry.enabled_set(), expected);

        // Round trip: the file records exactly the opt-ins and opt-outs.
        let text = std::fs::read_to_string(dir.path().join("harness-prefs.json")).unwrap();
        let file: HarnessPrefsFile = serde_json::from_str(&text).unwrap();
        assert_eq!(file.opted_in, vec![HarnessId::Cursor, HarnessId::Pi]);
        assert_eq!(file.disabled, vec![HarnessId::Codex]);
        let reloaded = HarnessRegistry::new();
        reloaded.load_prefs(dir.path());
        for id in all {
            test_slot(&reloaded, id, true);
        }
        assert_eq!(reloaded.enabled_set(), expected);

        // Opting back out removes the opt-in; no opt-out is recorded for an
        // agent that is off by default anyway.
        reloaded.set_enabled(HarnessId::Pi, false).unwrap();
        let text = std::fs::read_to_string(dir.path().join("harness-prefs.json")).unwrap();
        let file: HarnessPrefsFile = serde_json::from_str(&text).unwrap();
        assert_eq!(file.opted_in, vec![HarnessId::Cursor]);
        assert_eq!(file.disabled, vec![HarnessId::Codex]);

        // An empty opt-in list is omitted from the file entirely.
        let empty = serde_json::to_string(&HarnessPrefsFile::default()).unwrap();
        assert!(!empty.contains("optedIn"), "{empty}");
    }

    /// No default-on agent is installed: nothing starts enabled, but an
    /// installed off-by-default agent can still be turned on from Settings,
    /// and then it is protected as the last one standing.
    #[test]
    fn without_default_agents_settings_can_still_enable_others() {
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.load_prefs(dir.path());
        test_slot(&registry, HarnessId::Graff, false);
        test_slot(&registry, HarnessId::ClaudeCode, false);
        test_slot(&registry, HarnessId::Codex, false);
        test_slot(&registry, HarnessId::Opencode, true);
        assert_eq!(registry.enabled_set(), Vec::<HarnessId>::new());

        registry.set_enabled(HarnessId::Opencode, true).unwrap();
        assert_eq!(registry.enabled_set(), vec![HarnessId::Opencode]);
        assert!(registry.set_enabled(HarnessId::Opencode, false).is_err());
    }

    #[test]
    fn antigravity_opt_out_wins_over_a_stale_opt_in() {
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.load_prefs(dir.path());
        test_slot(&registry, HarnessId::ClaudeCode, true);
        test_slot(&registry, HarnessId::Antigravity, true);
        let prefs: HarnessPrefsFile =
            serde_json::from_str(r#"{"optedIn":["antigravity"],"disabled":["antigravity"]}"#)
                .unwrap();
        *registry.prefs() = prefs;
        assert_eq!(registry.enabled_set(), vec![HarnessId::ClaudeCode]);

        registry.set_enabled(HarnessId::Antigravity, true).unwrap();
        let both = vec![HarnessId::ClaudeCode, HarnessId::Antigravity];
        assert_eq!(registry.enabled_set(), both);

        let reloaded = HarnessRegistry::new();
        reloaded.load_prefs(dir.path());
        test_slot(&reloaded, HarnessId::ClaudeCode, true);
        test_slot(&reloaded, HarnessId::Antigravity, true);
        assert_eq!(reloaded.enabled_set(), both);

        reloaded.set_enabled(HarnessId::Antigravity, false).unwrap();
        assert_eq!(reloaded.enabled_set(), vec![HarnessId::ClaudeCode]);
    }

    #[cfg(unix)]
    #[test]
    fn antigravity_detection_subprocess() {
        let Ok(expected) = std::env::var("HARNESS_TEST_AGY_INSTALLED") else {
            return;
        };
        let registry = HarnessRegistry::new();
        let data = tempfile::tempdir().unwrap();
        registry.load_prefs(data.path());
        registry.register(Arc::new(harness_adapters::AcpHarness::antigravity()));
        let expected = expected == "true";
        assert_eq!(registry.descriptors()[0].installed, expected);
        // Off by default either way; only an installed server can opt in.
        assert!(!registry.enabled_set().contains(&HarnessId::Antigravity));
        assert_eq!(
            registry.set_enabled(HarnessId::Antigravity, true).is_ok(),
            expected
        );
        assert_eq!(
            registry.enabled_set().contains(&HarnessId::Antigravity),
            expected
        );
        assert_eq!(descriptor_enabled(&registry.descriptors()[0]), expected);
    }

    #[cfg(unix)]
    #[test]
    fn antigravity_server_path_controls_detection_and_enablement() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let bin = home.path().join("bin");
        std::fs::create_dir(&bin).unwrap();
        let cli = bin.join("agy");
        std::fs::write(&cli, "#!/bin/sh\nexit 91\n").unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
        let server = bin.join("agy_acp_server.par");
        for installed in [false, true] {
            if installed {
                std::fs::write(&server, "#!/bin/sh\nexit 91\n").unwrap();
                std::fs::set_permissions(&server, std::fs::Permissions::from_mode(0o755)).unwrap();
            }
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "registry::tests::antigravity_detection_subprocess",
                    "--nocapture",
                ])
                .env("HOME", home.path())
                .env("PATH", &bin)
                .env_remove("ANTIGRAVITY_ACP_EXECUTABLE")
                .env("HARNESS_NO_LOGIN_SHELL", "1")
                .env("HARNESS_TEST_AGY_INSTALLED", installed.to_string())
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stdout)
            );
        }
    }

    /// The mock resolves on every machine, so detection alone would enable it
    /// and let the last REAL agent be switched off — leaving a composer with
    /// nothing runnable behind a guard that thinks it is covered.
    #[test]
    fn detection_never_enables_the_mock() {
        let registry = default_registry();
        let enabled = registry.enabled_set();
        assert!(!enabled.contains(&HarnessId::Mock), "{enabled:?}");
        let mock = registry
            .descriptors()
            .into_iter()
            .find(|d| d.id == HarnessId::Mock)
            .expect("mock slot");
        assert!(mock.installed);
        assert_eq!(mock.enabled, Some(false));
    }

    /// A prefs file from the fixed-default era is an allow-list: a registered
    /// default-on agent absent from it was a deliberate "no", so it converts
    /// to an opt-out rather than silently re-enabling on the next launch; an
    /// off-by-default agent listed in it was a deliberate "yes", so it
    /// becomes an opt-in.
    #[test]
    fn legacy_allow_list_migrates_to_opt_outs_and_opt_ins() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("harness-prefs.json"),
            r#"{ "enabled": ["claude-code", "grok"] }"#,
        )
        .unwrap();
        let registry = HarnessRegistry::new();
        test_slot(&registry, HarnessId::ClaudeCode, true);
        test_slot(&registry, HarnessId::Codex, true);
        test_slot(&registry, HarnessId::Grok, true);
        test_slot(&registry, HarnessId::Hermes, true);
        registry.load_prefs(dir.path());
        assert_eq!(
            registry.enabled_set(),
            vec![HarnessId::ClaudeCode, HarnessId::Grok]
        );

        // The rewritten file is the new shape, and the legacy key is gone.
        let text = std::fs::read_to_string(dir.path().join("harness-prefs.json")).unwrap();
        assert!(!text.contains("\"enabled\""), "{text}");
        let file: HarnessPrefsFile = serde_json::from_str(&text).unwrap();
        assert_eq!(file.disabled, vec![HarnessId::Codex]);
        assert_eq!(file.opted_in, vec![HarnessId::Grok]);
        // A default-on agent registered after the migration is new, not a
        // past "no"; an off-by-default one still waits for an opt-in.
        test_slot(&registry, HarnessId::Graff, true);
        test_slot(&registry, HarnessId::Cursor, true);
        assert_eq!(
            registry.enabled_set(),
            vec![HarnessId::ClaudeCode, HarnessId::Grok, HarnessId::Graff]
        );
    }

    /// The fresh-machine shape (#128): no CLIs installed at all. Enablement is
    /// gated on detection, so nothing is enabled to begin with — no
    /// dimmed default toggles to dismiss — and switching an uninstalled
    /// harness "off" is a clean no-op, not an error.
    #[test]
    fn machine_without_clis_enables_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.load_prefs(dir.path());
        test_slot(&registry, HarnessId::ClaudeCode, false);
        test_slot(&registry, HarnessId::Codex, false);

        assert_eq!(registry.enabled_set(), Vec::<HarnessId>::new());
        registry.set_enabled(HarnessId::Codex, false).unwrap();
        registry.set_enabled(HarnessId::ClaudeCode, false).unwrap();
        assert_eq!(registry.enabled_set(), Vec::<HarnessId>::new());

        let reloaded = HarnessRegistry::new();
        reloaded.load_prefs(dir.path());
        assert_eq!(reloaded.enabled_set(), Vec::<HarnessId>::new());
    }

    /// The Codex lazy descriptor must be indistinguishable from `describe()`
    /// after the first resolve — otherwise the catalog entry silently changes
    /// the moment the harness is used (name/ladder flip in the picker rail).
    /// (KNOWN GAP, predates this slot: the claude-code descriptor advertises
    /// `[Ultrathink]` while the resolved adapter reports `[Low..Max]` — left
    /// as-is here; flagged for its own pass.)
    #[test]
    fn codex_lazy_descriptor_matches_resolved_harness() {
        let registry = default_registry();
        let before = registry
            .descriptors()
            .into_iter()
            .find(|d| d.id == HarnessId::Codex)
            .unwrap();
        registry.resolve(HarnessId::Codex).unwrap();
        let after = registry
            .descriptors()
            .into_iter()
            .find(|d| d.id == HarnessId::Codex)
            .unwrap();
        assert_eq!(before.name, after.name);
        assert_eq!(before.supports_steering, after.supports_steering);
        assert_eq!(before.steering_mode, after.steering_mode);
        assert_eq!(before.reasoning_levels, after.reasoning_levels);
    }
}

#[cfg(test)]
mod title_tests {
    use super::*;

    #[test]
    fn title_preferences_persist_and_validate_harness_model_pairs() {
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.load_prefs(dir.path());
        registry.register(Arc::new(
            harness_adapters::ClaudeHarness::new()
                .with_executable(std::env::current_exe().unwrap()),
        ));
        let settings = TitleSettings {
            harness: Some(HarnessId::ClaudeCode),
            model: Some("haiku-test".into()),
        };
        registry.set_title_settings(settings.clone()).unwrap();
        let reloaded = HarnessRegistry::new();
        reloaded.load_prefs(dir.path());
        assert_eq!(reloaded.title_settings(), settings);
        assert!(
            registry
                .set_title_settings(TitleSettings {
                    harness: None,
                    model: Some("orphan".into())
                })
                .is_err()
        );
        assert!(
            registry
                .set_title_settings(TitleSettings {
                    harness: Some(HarnessId::Cursor),
                    model: None
                })
                .is_err()
        );
        assert_eq!(registry.title_settings(), settings);
        registry
            .set_title_settings(TitleSettings::default())
            .unwrap();
        reloaded.load_prefs(dir.path());
        assert_eq!(reloaded.title_settings(), TitleSettings::default());
    }

    #[test]
    fn old_harness_preferences_default_to_automatic_titles() {
        let prefs: HarnessPrefsFile = serde_json::from_str(r#"{"disabled":["codex"]}"#).unwrap();
        assert_eq!(prefs.titles, TitleSettings::default());
        assert_eq!(prefs.disabled, vec![HarnessId::Codex]);
    }
}
