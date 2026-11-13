//! Device-local monitoring and safe mutation of independently-installed agent
//! CLIs (`WatchHarnessUpdates`, `CheckHarnessUpdates`, `ApplyHarnessUpdate`,
//! `CancelHarnessUpdate`, `DismissHarnessUpdate`, `SetHarnessUpdatePolicy`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tokio::sync::watch;
use tokio_util::sync::CancellationToken;

use harness_proto::{
    HarnessId, HarnessInstallSource, HarnessUpdateFailure, HarnessUpdateFailureKind,
    HarnessUpdatePhase, HarnessUpdatePolicy, HarnessUpdateStatus, version_triple,
};

use crate::now_ms;
use crate::registry::HarnessRegistry;

const CHECK_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
pub(crate) const UPDATE_TIMEOUT: Duration = Duration::from_secs(30 * 60);
pub(crate) const APPLY_REPLY_DEADLINE: Duration = Duration::from_secs(40 * 60);
const BINARY_WATCH_INTERVAL: Duration = Duration::from_secs(5 * 60);

const NONINTERACTIVE_ENV: &[(&str, &str)] = &[
    ("GIT_TERMINAL_PROMPT", "0"),
    ("GCM_INTERACTIVE", "never"),
    ("NONINTERACTIVE", "1"),
    ("npm_config_yes", "true"),
];

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct Preferences {
    policies: HashMap<HarnessId, HarnessUpdatePolicy>,
    dismissed_versions: HashMap<HarnessId, String>,
}

#[derive(Clone, Copy)]
enum LatestSource {
    Npm(&'static str),
    Github {
        repository: &'static str,
        tag_prefix: &'static str,
    },
    Command(&'static [&'static str]),
    Manual,
}

struct ProviderSpec {
    version_args: &'static [&'static str],
    latest: LatestSource,
    update_args: Option<&'static [&'static str]>,
    npm_package: Option<&'static str>,
    manual_command: &'static str,
}

fn provider(id: HarnessId) -> ProviderSpec {
    match id {
        HarnessId::ClaudeCode => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Npm("@anthropic-ai/claude-code"),
            update_args: Some(&["update"]),
            npm_package: Some("@anthropic-ai/claude-code"),
            manual_command: "claude update",
        },
        HarnessId::Codex => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Github {
                repository: "openai/codex",
                tag_prefix: "rust-v",
            },
            update_args: None,
            npm_package: Some("@openai/codex"),
            manual_command: "npm install -g @openai/codex",
        },
        HarnessId::Cursor => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: Some(&["update"]),
            npm_package: None,
            manual_command: "cursor-agent update",
        },
        HarnessId::Grok => ProviderSpec {
            version_args: &["version"],
            latest: LatestSource::Command(&["update", "--check"]),
            update_args: Some(&["update"]),
            npm_package: Some("@xai-official/grok"),
            manual_command: "grok update",
        },
        HarnessId::Hermes => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: Some(&["update", "--yes"]),
            npm_package: None,
            manual_command: "hermes update",
        },
        HarnessId::Graff => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "",
        },
        HarnessId::Pi => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Npm("@earendil-works/pi-coding-agent"),
            update_args: Some(&["update", "--self"]),
            npm_package: Some("@earendil-works/pi-coding-agent"),
            manual_command: "pi update --self",
        },
        HarnessId::Opencode => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Npm("opencode-ai"),
            update_args: Some(&["upgrade"]),
            npm_package: Some("opencode-ai"),
            manual_command: "opencode upgrade",
        },
        HarnessId::Devin => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "devin --version",
        },
        HarnessId::Antigravity => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "Update the configured Antigravity ACP server",
        },
        HarnessId::Exo => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "exo-cli --version",
        },
        HarnessId::Mock => ProviderSpec {
            version_args: &["--version"],
            latest: LatestSource::Manual,
            update_args: None,
            npm_package: None,
            manual_command: "",
        },
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct BinaryFingerprint {
    path: PathBuf,
    modified: Option<std::time::SystemTime>,
    len: u64,
}

impl BinaryFingerprint {
    fn of(executable: &Path) -> Option<Self> {
        let path = std::fs::canonicalize(executable).ok()?;
        let metadata = path.metadata().ok()?;
        Some(Self {
            path,
            modified: metadata.modified().ok(),
            len: metadata.len(),
        })
    }
}

#[derive(Debug, Clone)]
enum UpdatePlan {
    Homebrew {
        brew: PathBuf,
        cask: bool,
        token: String,
    },
    NpmGlobal {
        npm: PathBuf,
        prefix: PathBuf,
        package: &'static str,
    },
    Command {
        executable: PathBuf,
        args: &'static [&'static str],
    },
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn classify_source(executable: &Path) -> HarnessInstallSource {
    let real = std::fs::canonicalize(executable).unwrap_or_else(|_| executable.to_path_buf());
    let text = real.to_string_lossy();
    if text.contains("/.harness/") {
        HarnessInstallSource::ManagedByHarness
    } else if text.contains("/Cellar/") || text.contains("/Caskroom/") {
        HarnessInstallSource::Homebrew
    } else if text.contains("node_modules") {
        HarnessInstallSource::Npm
    } else if text.contains("/.cargo/bin/") {
        HarnessInstallSource::Cargo
    } else {
        HarnessInstallSource::Vendor
    }
}

fn detect_homebrew(executable: &Path) -> Option<(PathBuf, bool, String)> {
    let real = std::fs::canonicalize(executable).ok()?;
    let parts: Vec<String> = real
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    for (idx, part) in parts.iter().enumerate() {
        if (part == "Cellar" || part == "Caskroom") && idx + 1 < parts.len() {
            let token = parts[idx + 1].clone();
            if token == "node" || token.starts_with("node@") {
                return None;
            }
            let mut prefix = PathBuf::new();
            for component in real.components().take(idx) {
                prefix.push(component);
            }
            let brew = prefix.join("bin").join("brew");
            if brew.is_file() {
                return Some((brew, part == "Caskroom", token));
            }
        }
    }
    None
}

fn detect_npm_global(executable: &Path) -> Option<(PathBuf, PathBuf)> {
    let real = std::fs::canonicalize(executable).ok()?;
    let mut prefix = PathBuf::new();
    let mut found = false;
    for component in real.components() {
        if component.as_os_str() == "node_modules" {
            if prefix.file_name().is_some_and(|name| name == "lib") {
                prefix.pop();
            }
            found = true;
            break;
        }
        prefix.push(component);
    }
    if !found || prefix.as_os_str().is_empty() {
        return None;
    }
    let candidate = prefix
        .join("bin")
        .join(if cfg!(windows) { "npm.cmd" } else { "npm" });
    if candidate.is_file() {
        return Some((candidate, prefix));
    }
    None
}

fn build_update_plan(harness: HarnessId, executable: &Path) -> Result<UpdatePlan, String> {
    let spec = provider(harness);
    if let Some((brew, cask, token)) = detect_homebrew(executable) {
        return Ok(UpdatePlan::Homebrew { brew, cask, token });
    }
    if let Some(package) = spec.npm_package
        && let Some((npm, prefix)) = detect_npm_global(executable)
    {
        return Ok(UpdatePlan::NpmGlobal {
            npm,
            prefix,
            package,
        });
    }
    if let Some(args) = spec.update_args {
        return Ok(UpdatePlan::Command {
            executable: executable.to_path_buf(),
            args,
        });
    }
    Err(if spec.manual_command.is_empty() {
        "this agent manages its own updates".into()
    } else {
        spec.manual_command.into()
    })
}

pub fn extract_semver(output: &str) -> Option<String> {
    for raw in output.split(|c: char| c.is_whitespace() || matches!(c, '(' | ')' | ',' | ';')) {
        let trimmed = raw.trim_start_matches(['v', 'V']);
        if version_triple(trimmed).is_some() {
            return Some(trimmed.to_string());
        }
    }
    None
}

pub fn is_newer_version(installed: &str, latest: &str) -> bool {
    if installed == latest {
        return false;
    }
    match (version_triple(installed), version_triple(latest)) {
        (Some(cur), Some(next)) => next > cur,
        _ => false,
    }
}

struct ActiveUpdate {
    cancel: CancellationToken,
}

type ResolverFn = Arc<dyn Fn(HarnessId) -> Option<PathBuf> + Send + Sync>;

struct Inner {
    registry: Arc<HarnessRegistry>,
    order: Mutex<Vec<HarnessId>>,
    prefs_path: PathBuf,
    prefs: Mutex<Preferences>,
    statuses: Mutex<HashMap<HarnessId, HarnessUpdateStatus>>,
    status_tx: watch::Sender<Vec<HarnessUpdateStatus>>,
    cancellations: Mutex<HashMap<HarnessId, ActiveUpdate>>,
    operation_gates: Mutex<HashMap<HarnessId, Arc<tokio::sync::Mutex<()>>>>,
    checked_binaries: Mutex<HashMap<HarnessId, BinaryFingerprint>>,
    shutdown: CancellationToken,
    worker: Mutex<Option<tokio::task::JoinHandle<()>>>,
    client: reqwest::Client,
    resolver: ResolverFn,
}

#[derive(Clone)]
pub struct HarnessUpdateCoordinator {
    inner: Arc<Inner>,
}

impl HarnessUpdateCoordinator {
    pub fn new(data_dir: &Path, registry: Arc<HarnessRegistry>) -> Self {
        Self::with_resolver(
            data_dir,
            registry,
            Arc::new(harness_adapters::install::resolve_executable),
        )
    }

    pub(crate) fn with_resolver(
        data_dir: &Path,
        registry: Arc<HarnessRegistry>,
        resolver: ResolverFn,
    ) -> Self {
        let prefs_path = data_dir.join("harness-update-prefs.json");
        let prefs: Preferences = std::fs::read_to_string(&prefs_path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let order: Vec<_> = registry
            .descriptors()
            .into_iter()
            .filter(|d| d.id != HarnessId::Mock)
            .map(|d| d.id)
            .collect();
        let enabled = registry.enabled_set();
        let statuses: HashMap<_, _> = order
            .iter()
            .copied()
            .map(|harness| {
                let policy = prefs.policies.get(&harness).copied().unwrap_or_default();
                let phase = if enabled.contains(&harness) && policy != HarnessUpdatePolicy::Off {
                    HarnessUpdatePhase::Checking
                } else {
                    HarnessUpdatePhase::Dormant
                };
                let spec = provider(harness);
                (
                    harness,
                    HarnessUpdateStatus {
                        harness,
                        installed_version: None,
                        latest_version: None,
                        channel: Some("stable".into()),
                        source: HarnessInstallSource::Unknown,
                        policy,
                        phase,
                        progress: None,
                        checked_at: None,
                        error: None,
                        can_apply: spec.update_args.is_some() || spec.npm_package.is_some(),
                        manual_command: (!spec.manual_command.is_empty())
                            .then(|| spec.manual_command.to_string()),
                        wait_reason: None,
                        compatibility: None,
                        held_back: None,
                    },
                )
            })
            .collect();
        let ordered = ordered_statuses(&order, &statuses, &prefs);
        let (status_tx, _) = watch::channel(ordered);
        let client = reqwest::Client::builder()
            .user_agent("harness-engine")
            .timeout(COMMAND_TIMEOUT)
            .build()
            .unwrap_or_default();
        Self {
            inner: Arc::new(Inner {
                registry,
                order: Mutex::new(order),
                prefs_path,
                prefs: Mutex::new(prefs),
                statuses: Mutex::new(statuses),
                status_tx,
                cancellations: Mutex::new(HashMap::new()),
                operation_gates: Mutex::new(HashMap::new()),
                checked_binaries: Mutex::new(HashMap::new()),
                shutdown: CancellationToken::new(),
                worker: Mutex::new(None),
                client,
                resolver,
            }),
        }
    }

    pub fn start(&self) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let mut slot = lock(&self.inner.worker);
        if slot.is_some() {
            return;
        }
        let coordinator = self.clone();
        *slot = Some(runtime.spawn(async move {
            coordinator.check_all().await;
            let mut check_tick = tokio::time::interval(CHECK_INTERVAL);
            check_tick.tick().await;
            let mut bin_tick = tokio::time::interval(BINARY_WATCH_INTERVAL);
            bin_tick.tick().await;
            loop {
                tokio::select! {
                    _ = coordinator.inner.shutdown.cancelled() => break,
                    _ = check_tick.tick() => coordinator.check_all().await,
                    _ = bin_tick.tick() => coordinator.recheck_changed_binaries().await,
                }
            }
        }));
    }

    pub async fn shutdown(&self) {
        self.inner.shutdown.cancel();
        let cancellations: Vec<_> = lock(&self.inner.cancellations)
            .values()
            .map(|active| active.cancel.clone())
            .collect();
        for token in cancellations {
            token.cancel();
        }
        let handle = lock(&self.inner.worker).take();
        if let Some(handle) = handle {
            let _ = handle.await;
        }
    }

    pub fn watch(&self) -> watch::Receiver<Vec<HarnessUpdateStatus>> {
        self.inner.status_tx.subscribe()
    }

    pub fn snapshot(&self) -> Vec<HarnessUpdateStatus> {
        self.inner.status_tx.borrow().clone()
    }

    pub fn recheck_changed_binaries_soon(&self) {
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let coordinator = self.clone();
        runtime.spawn(async move {
            coordinator.recheck_changed_binaries().await;
        });
    }

    async fn recheck_changed_binaries(&self) {
        let order = lock(&self.inner.order).clone();
        for harness in order {
            let current = (self.inner.resolver)(harness).and_then(|p| BinaryFingerprint::of(&p));
            let changed = lock(&self.inner.checked_binaries).get(&harness).cloned() != current;
            if changed {
                let _ = self.check_one(harness).await;
            }
        }
    }

    pub async fn check_all(&self) {
        let order = lock(&self.inner.order).clone();
        let enabled = self.inner.registry.enabled_set();
        for harness in order {
            let policy = lock(&self.inner.prefs)
                .policies
                .get(&harness)
                .copied()
                .unwrap_or_default();
            if policy == HarnessUpdatePolicy::Off || !enabled.contains(&harness) {
                self.mutate(harness, |status| {
                    status.policy = policy;
                    status.phase = HarnessUpdatePhase::Dormant;
                    status.error = None;
                });
                continue;
            }
            let _ = self.check_one(harness).await;
        }
    }

    pub async fn check_one(&self, harness: HarnessId) -> Result<(), String> {
        let gate = self.gate_for(harness);
        let _guard = gate.lock().await;
        let policy = lock(&self.inner.prefs)
            .policies
            .get(&harness)
            .copied()
            .unwrap_or_default();
        if policy == HarnessUpdatePolicy::Off {
            self.mutate(harness, |status| {
                status.policy = policy;
                status.phase = HarnessUpdatePhase::Dormant;
                status.error = None;
            });
            return Ok(());
        }
        let Some(executable) = (self.inner.resolver)(harness) else {
            lock(&self.inner.checked_binaries).remove(&harness);
            self.mutate(harness, |status| {
                status.installed_version = None;
                status.latest_version = None;
                status.phase = HarnessUpdatePhase::Dormant;
                status.error = None;
                status.checked_at = Some(now_ms());
            });
            return Ok(());
        };
        if let Some(fp) = BinaryFingerprint::of(&executable) {
            lock(&self.inner.checked_binaries).insert(harness, fp);
        }
        self.mutate(harness, |status| {
            status.phase = HarnessUpdatePhase::Checking;
            status.error = None;
        });

        let source = classify_source(&executable);
        let plan_res = build_update_plan(harness, &executable);
        let can_apply = plan_res.is_ok();
        let manual_command = plan_res.err().filter(|msg| !msg.is_empty());

        let spec = provider(harness);
        let installed = run_capture(&executable, spec.version_args, COMMAND_TIMEOUT)
            .await
            .ok()
            .and_then(|out| extract_semver(&out));

        let Some(installed_ver) = installed else {
            self.mutate(harness, |status| {
                status.source = source;
                status.can_apply = can_apply;
                status.manual_command = manual_command;
                status.phase = HarnessUpdatePhase::Current;
                status.checked_at = Some(now_ms());
            });
            return Ok(());
        };

        let latest = match self.fetch_latest(harness, &executable).await {
            Ok(ver) => ver,
            Err(message) => {
                self.mutate(harness, |status| {
                    status.installed_version = Some(installed_ver);
                    status.source = source;
                    status.can_apply = can_apply;
                    status.manual_command = manual_command;
                    status.phase = HarnessUpdatePhase::Failed;
                    status.checked_at = Some(now_ms());
                    status.error = Some(HarnessUpdateFailure {
                        message,
                        retryable: true,
                        kind: HarnessUpdateFailureKind::Check,
                    });
                });
                return Ok(());
            }
        };

        let phase = match latest.as_deref() {
            Some(lat) if is_newer_version(&installed_ver, lat) => {
                if can_apply {
                    HarnessUpdatePhase::Available
                } else {
                    HarnessUpdatePhase::ManualActionRequired
                }
            }
            _ => HarnessUpdatePhase::Current,
        };

        self.mutate(harness, |status| {
            status.installed_version = Some(installed_ver);
            status.latest_version = latest;
            status.source = source;
            status.can_apply = can_apply;
            status.manual_command = manual_command;
            status.phase = phase;
            status.error = None;
            status.checked_at = Some(now_ms());
        });
        Ok(())
    }

    pub async fn apply(&self, harness: HarnessId) -> Result<Option<String>, String> {
        let gate = self.gate_for(harness);
        let _guard = gate.lock().await;
        let executable = (self.inner.resolver)(harness)
            .ok_or_else(|| "agent CLI is not installed on this device".to_string())?;
        let plan = build_update_plan(harness, &executable)?;
        let cancel = CancellationToken::new();
        let previous_phase = lock(&self.inner.statuses)
            .get(&harness)
            .map(|s| s.phase)
            .unwrap_or(HarnessUpdatePhase::Available);
        lock(&self.inner.cancellations).insert(
            harness,
            ActiveUpdate {
                cancel: cancel.clone(),
            },
        );
        self.mutate(harness, |status| {
            status.phase = HarnessUpdatePhase::Installing;
            status.error = None;
        });

        let run_res = execute_plan(&plan, &cancel).await;
        lock(&self.inner.cancellations).remove(&harness);

        if cancel.is_cancelled() {
            self.mutate(harness, |status| {
                status.phase = previous_phase;
                status.error = None;
            });
            return Err("update cancelled".into());
        }

        if let Err(message) = run_res {
            self.mutate(harness, |status| {
                status.phase = HarnessUpdatePhase::Failed;
                status.error = Some(HarnessUpdateFailure {
                    message: message.clone(),
                    retryable: true,
                    kind: HarnessUpdateFailureKind::Install,
                });
            });
            return Err(message);
        }

        self.mutate(harness, |status| {
            status.phase = HarnessUpdatePhase::Verifying;
        });

        let post_exe = (self.inner.resolver)(harness).unwrap_or(executable);
        if let Some(fp) = BinaryFingerprint::of(&post_exe) {
            lock(&self.inner.checked_binaries).insert(harness, fp);
        }
        let verified = run_capture(&post_exe, provider(harness).version_args, COMMAND_TIMEOUT)
            .await
            .ok()
            .and_then(|out| extract_semver(&out));

        self.mutate(harness, |status| {
            if let Some(ver) = &verified {
                status.installed_version = Some(ver.clone());
                status.latest_version = Some(ver.clone());
            }
            status.phase = HarnessUpdatePhase::Updated;
            status.error = None;
            status.checked_at = Some(now_ms());
        });
        Ok(verified)
    }

    pub fn cancel(&self, harness: HarnessId) -> bool {
        if let Some(active) = lock(&self.inner.cancellations).get(&harness) {
            active.cancel.cancel();
            true
        } else {
            false
        }
    }

    pub fn dismiss(&self, harness: HarnessId, version: Option<String>) -> Vec<HarnessUpdateStatus> {
        {
            let mut prefs = lock(&self.inner.prefs);
            let target = version.or_else(|| {
                lock(&self.inner.statuses)
                    .get(&harness)
                    .and_then(|s| s.latest_version.clone())
            });
            if let Some(ver) = target {
                prefs.dismissed_versions.insert(harness, ver);
            } else {
                prefs.dismissed_versions.remove(&harness);
            }
            save_prefs(&self.inner.prefs_path, &prefs);
        }
        self.publish()
    }

    pub fn set_policy(
        &self,
        harness: HarnessId,
        policy: HarnessUpdatePolicy,
    ) -> Vec<HarnessUpdateStatus> {
        {
            let mut prefs = lock(&self.inner.prefs);
            prefs.policies.insert(harness, policy);
            save_prefs(&self.inner.prefs_path, &prefs);
        }
        self.mutate(harness, |status| {
            status.policy = policy;
            if policy == HarnessUpdatePolicy::Off {
                status.phase = HarnessUpdatePhase::Dormant;
                status.error = None;
            }
        });
        self.snapshot()
    }

    async fn fetch_latest(
        &self,
        harness: HarnessId,
        executable: &Path,
    ) -> Result<Option<String>, String> {
        match provider(harness).latest {
            LatestSource::Manual => Ok(None),
            LatestSource::Command(args) => {
                let out = run_capture(executable, args, COMMAND_TIMEOUT).await?;
                Ok(extract_semver(&out))
            }
            LatestSource::Npm(package) => {
                let encoded = package.replace('/', "%2F");
                let url = format!("https://registry.npmjs.org/{encoded}/latest");
                let resp = self
                    .inner
                    .client
                    .get(url)
                    .send()
                    .await
                    .map_err(|e| format!("npm registry lookup failed: {e}"))?;
                if !resp.status().is_success() {
                    return Err(format!("npm registry HTTP {}", resp.status()));
                }
                let body: serde_json::Value = resp
                    .json()
                    .await
                    .map_err(|e| format!("invalid npm registry JSON: {e}"))?;
                Ok(body
                    .get("version")
                    .and_then(|v| v.as_str())
                    .and_then(extract_semver))
            }
            LatestSource::Github {
                repository,
                tag_prefix,
            } => {
                let url = format!("https://api.github.com/repos/{repository}/releases/latest");
                let resp = self
                    .inner
                    .client
                    .get(url)
                    .header("Accept", "application/vnd.github+json")
                    .send()
                    .await
                    .map_err(|e| format!("GitHub release lookup failed: {e}"))?;
                if !resp.status().is_success() {
                    return Err(format!("GitHub releases HTTP {}", resp.status()));
                }
                let body: serde_json::Value = resp
                    .json()
                    .await
                    .map_err(|e| format!("invalid GitHub release JSON: {e}"))?;
                let tag = body
                    .get("tag_name")
                    .and_then(|v| v.as_str())
                    .unwrap_or_default();
                let stripped = tag.strip_prefix(tag_prefix).unwrap_or(tag);
                Ok(extract_semver(stripped))
            }
        }
    }

    fn gate_for(&self, harness: HarnessId) -> Arc<tokio::sync::Mutex<()>> {
        lock(&self.inner.operation_gates)
            .entry(harness)
            .or_insert_with(|| Arc::new(tokio::sync::Mutex::new(())))
            .clone()
    }

    fn mutate(&self, harness: HarnessId, f: impl FnOnce(&mut HarnessUpdateStatus)) {
        {
            let mut statuses = lock(&self.inner.statuses);
            if let Some(status) = statuses.get_mut(&harness) {
                f(status);
            }
        }
        let _ = self.publish();
    }

    fn publish(&self) -> Vec<HarnessUpdateStatus> {
        let order = lock(&self.inner.order).clone();
        let statuses = lock(&self.inner.statuses);
        let prefs = lock(&self.inner.prefs);
        let snapshot = ordered_statuses(&order, &statuses, &prefs);
        self.inner.status_tx.send_replace(snapshot.clone());
        snapshot
    }
}

fn ordered_statuses(
    order: &[HarnessId],
    statuses: &HashMap<HarnessId, HarnessUpdateStatus>,
    prefs: &Preferences,
) -> Vec<HarnessUpdateStatus> {
    order
        .iter()
        .filter_map(|id| {
            let mut status = statuses.get(id)?.clone();
            if status.phase == HarnessUpdatePhase::Available
                && let (Some(latest), Some(dismissed)) = (
                    status.latest_version.as_deref(),
                    prefs.dismissed_versions.get(id).map(String::as_str),
                )
                && latest == dismissed
            {
                status.phase = HarnessUpdatePhase::Current;
            }
            Some(status)
        })
        .collect()
}

fn save_prefs(path: &Path, prefs: &Preferences) {
    if let Ok(json) = serde_json::to_string_pretty(prefs) {
        let _ = std::fs::write(path, json);
    }
}

async fn run_capture(
    executable: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<String, String> {
    let mut cmd = Command::new(executable);
    harness_adapters::compose_login_shell_path(&mut cmd);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for (k, v) in NONINTERACTIVE_ENV {
        cmd.env(k, v);
    }
    let output = tokio::time::timeout(timeout, cmd.output())
        .await
        .map_err(|_| format!("command `{}` timed out", executable.display()))?
        .map_err(|e| format!("failed to launch `{}`: {e}", executable.display()))?;
    let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
    if !output.stderr.is_empty() {
        if !combined.is_empty() {
            combined.push('\n');
        }
        combined.push_str(&String::from_utf8_lossy(&output.stderr));
    }
    if !output.status.success() && combined.trim().is_empty() {
        return Err(format!("command exited with {}", output.status));
    }
    Ok(combined)
}

async fn execute_plan(plan: &UpdatePlan, cancel: &CancellationToken) -> Result<(), String> {
    let mut cmd = match plan {
        UpdatePlan::Homebrew { brew, cask, token } => {
            let mut c = Command::new(brew);
            c.arg("upgrade")
                .arg(if *cask { "--cask" } else { "--formula" })
                .arg(token);
            c
        }
        UpdatePlan::NpmGlobal {
            npm,
            prefix,
            package,
        } => {
            let mut c = Command::new(npm);
            c.arg("install")
                .arg("-g")
                .arg("--prefix")
                .arg(prefix)
                .arg(format!("{package}@latest"));
            c
        }
        UpdatePlan::Command { executable, args } => {
            let mut c = Command::new(executable);
            c.args(*args);
            c
        }
    };
    harness_adapters::compose_login_shell_path(&mut cmd);
    cmd.stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    for (k, v) in NONINTERACTIVE_ENV {
        cmd.env(k, v);
    }

    let child = cmd
        .spawn()
        .map_err(|e| format!("failed to start updater: {e}"))?;
    let output = tokio::select! {
        _ = cancel.cancelled() => return Err("update cancelled".into()),
        res = tokio::time::timeout(UPDATE_TIMEOUT, child.wait_with_output()) => {
            res.map_err(|_| "updater timed out".to_string())?
                .map_err(|e| format!("updater failed: {e}"))?
        }
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let detail = stderr.trim();
        let msg = if !detail.is_empty() {
            detail
        } else {
            stdout.trim()
        };
        return Err(if msg.is_empty() {
            format!("updater exited with {}", output.status)
        } else {
            msg.lines().last().unwrap_or(msg).to_string()
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_semver_and_compares_strictly() {
        assert_eq!(
            extract_semver("claude 2.1.319 (Claude Code)"),
            Some("2.1.319".into())
        );
        assert_eq!(extract_semver("pi v1.5.0"), Some("1.5.0".into()));
        assert!(is_newer_version("2.1.319", "2.1.322"));
        assert!(!is_newer_version("2.1.322", "2.1.322"));
        assert!(!is_newer_version("2.1.322", "2.1.319"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn synthetic_cli_check_apply_and_dismiss_round_trip() {
        use std::os::unix::fs::PermissionsExt as _;

        let dir = tempfile::tempdir().unwrap();
        let state_file = dir.path().join("ver.txt");
        std::fs::write(&state_file, "1.2.0").unwrap();
        let cli = dir.path().join("grok");
        let script = format!(
            "#!/bin/sh\nif [ \"$1\" = \"version\" ]; then\n  cat \"{}\"\n  exit 0\nfi\nif [ \"$1\" = \"update\" ] && [ \"$2\" = \"--check\" ]; then\n  echo \"1.3.1\"\n  exit 0\nfi\nif [ \"$1\" = \"update\" ]; then\n  printf \"1.3.1\" > \"{}\"\n  exit 0\nfi\nexit 1\n",
            state_file.display(),
            state_file.display()
        );
        std::fs::write(&cli, script).unwrap();
        std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();

        let registry = Arc::new(crate::default_registry());
        registry.load_prefs(dir.path());
        let cli_path = cli.clone();
        let coord = HarnessUpdateCoordinator::with_resolver(
            dir.path(),
            registry,
            Arc::new(move |id| (id == HarnessId::Grok).then(|| cli_path.clone())),
        );

        coord.check_one(HarnessId::Grok).await.unwrap();
        let grok = coord
            .snapshot()
            .into_iter()
            .find(|s| s.harness == HarnessId::Grok)
            .unwrap();
        assert_eq!(grok.phase, HarnessUpdatePhase::Available);
        assert_eq!(grok.installed_version.as_deref(), Some("1.2.0"));
        assert_eq!(grok.latest_version.as_deref(), Some("1.3.1"));
        assert!(grok.can_apply);

        let after_dismiss = coord.dismiss(HarnessId::Grok, Some("1.3.1".into()));
        let dismissed = after_dismiss
            .into_iter()
            .find(|s| s.harness == HarnessId::Grok)
            .unwrap();
        assert_eq!(dismissed.phase, HarnessUpdatePhase::Current);

        let updated = coord.apply(HarnessId::Grok).await.unwrap();
        assert_eq!(updated.as_deref(), Some("1.3.1"));
        let final_row = coord
            .snapshot()
            .into_iter()
            .find(|s| s.harness == HarnessId::Grok)
            .unwrap();
        assert_eq!(final_row.phase, HarnessUpdatePhase::Updated);
        assert_eq!(final_row.installed_version.as_deref(), Some("1.3.1"));
    }
}
