//! Requests to another device through its device room on the edge (`harness-rpc`'s `LinkCache`: one cached link per
//! device, dialed lazily, a cooldown after failed dials, and no dial at all to a device the registry says is dark).
//! The calls are the ones the iOS `WorkspaceStore` makes over its `DeviceRelayClient`, with the same filters and
//! deadlines.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use harness_rpc::RpcError;
use harness_rpc::device_room::{LinkCache, LinkCacheConfig, PeerLiveness, TokenError, TokenSource};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::edge::Edge;
use crate::presence::PeerLivenessRecord;

/// `DeviceRelayClient.call`'s default deadline.
pub(crate) const CALL_TIMEOUT: Duration = Duration::from_secs(10);

/// What went wrong with a request to a device. The messages are the iOS app's (`RelayError`).
#[derive(Debug, Clone, PartialEq, thiserror::Error, uniffi::Error)]
pub enum RelayError {
    #[error("Not connected to the device")]
    NotConnected,
    #[error("The device is offline")]
    HostOffline,
    #[error("{reason}")]
    Rpc { reason: String },
    #[error("The device didn't respond")]
    Timeout,
}

impl RelayError {
    /// An older host that does not have the method (`isUnknownChangeRequestMethod`).
    pub fn is_unknown_method(&self) -> bool {
        matches!(self, Self::Rpc { reason } if reason.to_lowercase().starts_with("unknown method:"))
    }

    fn breaks_link(&self) -> bool {
        matches!(self, Self::NotConnected | Self::HostOffline | Self::Timeout)
    }
}

impl From<RpcError> for RelayError {
    fn from(err: RpcError) -> Self {
        match err {
            RpcError::UnknownMethod(method) => Self::Rpc {
                reason: format!("unknown method: {method}"),
            },
            RpcError::BadParams(reason) | RpcError::Failed(reason) => Self::Rpc { reason },
            RpcError::Transport(reason) if reason.contains("offline") => Self::HostOffline,
            RpcError::Transport(_) | RpcError::Closed => Self::NotConnected,
        }
    }
}

struct Bearer(Edge);

#[async_trait]
impl TokenSource for Bearer {
    async fn token(&self) -> Result<String, TokenError> {
        match self.0.bearer().await {
            Ok(token) => Ok(token),
            Err(harness_sync::SyncError::Auth(_)) => Err(TokenError::SignedOut),
            Err(other) => Err(TokenError::TemporarilyUnavailable(other.to_string())),
        }
    }
}

pub type Liveness = Arc<dyn Fn(&str) -> PeerLivenessRecord + Send + Sync>;

pub(crate) struct Relay {
    links: Arc<LinkCache>,
}

impl Relay {
    /// Must be created inside the core's runtime (the cache listens for wake and online events on it).
    pub fn new(edge: &Edge, liveness: Liveness) -> Self {
        let mut config =
            LinkCacheConfig::new(edge.base().to_owned(), Arc::new(Bearer(edge.clone())));
        config.liveness = Some(Arc::new(move |device: &str| match liveness(device) {
            PeerLivenessRecord::Live => PeerLiveness::Live,
            PeerLivenessRecord::Dark => PeerLiveness::Dark,
            PeerLivenessRecord::Unknown => PeerLiveness::Unknown,
        }));
        Self {
            links: LinkCache::new(config),
        }
    }

    /// A beat arrived from the device: a dial it was cooling down from may go now.
    pub fn peer_alive(&self, device_id: &str) {
        self.links.reset_cooldown(device_id);
    }

    pub async fn call(
        &self,
        device_id: &str,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, RelayError> {
        let result = async {
            let client = self
                .links
                .client(device_id)
                .await
                .map_err(RelayError::from)?;
            match tokio::time::timeout(timeout, client.call(method, params)).await {
                Ok(reply) => reply.map_err(RelayError::from),
                Err(_) => Err(RelayError::Timeout),
            }
        }
        .await;
        if let Err(err) = &result
            && err.breaks_link()
        {
            // The next call dials a fresh link.
            self.links.invalidate(device_id);
        }
        result
    }

    pub async fn call_as<T: serde::de::DeserializeOwned>(
        &self,
        device_id: &str,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<T, RelayError> {
        let value = self.call(device_id, method, params, timeout).await?;
        serde_json::from_value(value).map_err(|e| RelayError::Rpc {
            reason: e.to_string(),
        })
    }

    /// A stream of items; the server acknowledges first, so an older host's unknown method is reported as such.
    pub async fn stream(
        &self,
        device_id: &str,
        method: &str,
        params: Value,
    ) -> Result<harness_rpc::RpcSubscription, RelayError> {
        let client = self
            .links
            .client(device_id)
            .await
            .map_err(RelayError::from)?;
        let result =
            tokio::time::timeout(CALL_TIMEOUT, client.subscribe_checked(method, params)).await;
        let result = match result {
            Ok(subscription) => subscription.map_err(RelayError::from),
            Err(_) => Err(RelayError::Timeout),
        };
        if let Err(err) = &result
            && err.breaks_link()
        {
            self.links.invalidate(device_id);
        }
        result
    }

    pub fn disconnect_all(&self) {
        self.links.disconnect_all();
    }
}

// ── the calls, with iOS's records and filters ───────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct FolderEntryRecord {
    pub name: String,
    pub is_dir: bool,
    pub is_repo: bool,
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
pub struct FolderListingRecord {
    pub path: String,
    pub entries: Vec<FolderEntryRecord>,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct HarnessInfoRecord {
    pub id: String,
    pub label: String,
    pub supports_steering: Option<bool>,
    pub steering_mode: Option<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AgentDescriptorRecord {
    pub id: String,
    pub installed: bool,
    pub can_install: bool,
    pub enabled: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
pub struct ModelOptionChoiceRecord {
    pub id: String,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ModelOptionRecord {
    pub id: String,
    pub label: String,
    pub choices: Vec<ModelOptionChoiceRecord>,
    pub default_choice: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfoRecord {
    pub id: String,
    pub label: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub reasoning_levels: Vec<String>,
    #[serde(default)]
    pub options: Vec<ModelOptionRecord>,
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct RepoRefRecord {
    pub name: String,
    #[serde(default)]
    pub current: bool,
    #[serde(default)]
    pub worktree_path: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireHarness {
    id: String,
    name: String,
    installed: Option<bool>,
    can_install: Option<bool>,
    enabled: Option<bool>,
    supports_steering: Option<bool>,
    steering_mode: Option<String>,
}

/// The three agents a fresh device offers out of the box (the engine's `default_on`).
const DEFAULT_ON_AGENTS: [&str; 3] = ["graff", "claude-code", "codex"];

/// What the composer may offer: installed and enabled (Settings > Agents on that computer), never the mock.
fn offered(list: Vec<WireHarness>) -> Vec<HarnessInfoRecord> {
    list.into_iter()
        .filter(|h| {
            h.id != "mock"
                && h.installed.unwrap_or(true)
                && h.enabled
                    .unwrap_or_else(|| DEFAULT_ON_AGENTS.contains(&h.id.as_str()))
        })
        .map(|h| HarnessInfoRecord {
            id: h.id,
            label: h.name,
            supports_steering: h.supports_steering,
            steering_mode: h.steering_mode,
        })
        .collect()
}

impl Relay {
    /// `ListFolders`: nil path is the device's home. The engine caps at 500 entries and hides dotfiles.
    pub async fn list_folders(
        &self,
        device_id: &str,
        path: Option<String>,
    ) -> Result<FolderListingRecord, RelayError> {
        let params = match path {
            Some(path) => json!({ "path": path }),
            None => json!({}),
        };
        self.call_as(device_id, "ListFolders", params, CALL_TIMEOUT)
            .await
    }

    pub async fn list_harnesses(
        &self,
        device_id: &str,
    ) -> Result<Vec<HarnessInfoRecord>, RelayError> {
        let wire: Vec<WireHarness> = self
            .call_as(device_id, "ListHarnesses", json!({}), CALL_TIMEOUT)
            .await?;
        Ok(offered(wire))
    }

    /// Every agent the device reports, found or not, on or off: what onboarding needs to say what is missing.
    pub async fn agent_descriptors(
        &self,
        device_id: &str,
    ) -> Result<Vec<AgentDescriptorRecord>, RelayError> {
        let wire: Vec<WireHarness> = self
            .call_as(device_id, "ListHarnesses", json!({}), CALL_TIMEOUT)
            .await?;
        Ok(wire
            .into_iter()
            .map(|h| AgentDescriptorRecord {
                id: h.id,
                installed: h.installed.unwrap_or(true),
                can_install: h.can_install.unwrap_or(false),
                enabled: h.enabled,
            })
            .collect())
    }

    pub async fn list_models(
        &self,
        device_id: &str,
        harness: &str,
    ) -> Result<Vec<ModelInfoRecord>, RelayError> {
        self.call_as(
            device_id,
            "ListModels",
            json!({ "harness": harness }),
            CALL_TIMEOUT,
        )
        .await
    }

    /// `GetGraffCompactAt`: the percent of the context window where the device's graff chats compact; `None` is
    /// graff's default.
    pub async fn graff_compact_at(&self, device_id: &str) -> Result<Option<u8>, RelayError> {
        self.call_as(device_id, "GetGraffCompactAt", json!({}), CALL_TIMEOUT)
            .await
    }

    /// `SetGraffCompactAt`: `None` restores the default. Answers with the value the device kept.
    pub async fn set_graff_compact_at(
        &self,
        device_id: &str,
        pct: Option<u8>,
    ) -> Result<Option<u8>, RelayError> {
        self.call_as(
            device_id,
            "SetGraffCompactAt",
            json!({ "pct": pct }),
            CALL_TIMEOUT,
        )
        .await
    }

    pub async fn list_refs(
        &self,
        device_id: &str,
        repo_path: &str,
    ) -> Result<Vec<RepoRefRecord>, RelayError> {
        self.call_as(
            device_id,
            "ListRefs",
            json!({ "repoPath": repo_path }),
            CALL_TIMEOUT,
        )
        .await
    }

    /// `git checkout` in a folder on the device; git's message on failure.
    pub async fn switch_ref(
        &self,
        device_id: &str,
        repo_path: &str,
        ref_name: &str,
    ) -> Result<(), RelayError> {
        self.call(
            device_id,
            "SwitchRef",
            json!({ "repoPath": repo_path, "refName": ref_name }),
            CALL_TIMEOUT,
        )
        .await
        .map(|_| ())
    }

    /// A fresh worktree off the base ref; its path.
    pub async fn create_worktree(
        &self,
        device_id: &str,
        space_id: &str,
        repo_path: &str,
        branch: &str,
    ) -> Result<String, RelayError> {
        #[derive(Deserialize)]
        struct Reply {
            path: String,
        }
        let reply: Reply = self
            .call_as(
                device_id,
                "CreateWorktree",
                json!({ "repoPath": repo_path, "branch": branch, "spaceId": space_id }),
                CALL_TIMEOUT,
            )
            .await?;
        Ok(reply.path)
    }

    /// `Mutate {op: createSpace}` on the owning host, which applies the row to its own registry.
    pub async fn create_space_on_host(
        &self,
        device_id: &str,
        space_id: &str,
        path: &str,
        git_detected: bool,
    ) -> Result<(), RelayError> {
        self.call(
            device_id,
            "Mutate",
            json!({
                "op": "createSpace",
                "spaceId": space_id,
                "deviceId": device_id,
                "path": path,
                "gitDetected": git_detected,
            }),
            CALL_TIMEOUT,
        )
        .await
        .map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_composer_offers_installed_enabled_agents_with_the_default_trio_on() {
        let wire: Vec<WireHarness> = serde_json::from_value(json!([
            {"id": "graff", "name": "Graff"},
            {"id": "codex", "name": "Codex", "installed": false},
            {"id": "claude-code", "name": "Claude Code", "enabled": false},
            {"id": "opencode", "name": "OpenCode"},
            {"id": "pi", "name": "Pi", "enabled": true, "supportsSteering": true, "steeringMode": "queue"},
            {"id": "mock", "name": "Mock", "enabled": true},
        ]))
        .unwrap();
        let ids: Vec<String> = offered(wire).into_iter().map(|h| h.id).collect();
        assert_eq!(ids, ["graff", "pi"]);
    }

    #[test]
    fn errors_read_like_the_ios_app_and_unknown_methods_are_recognized() {
        assert_eq!(
            RelayError::from(RpcError::Closed).to_string(),
            "Not connected to the device"
        );
        assert_eq!(
            RelayError::from(RpcError::Transport(
                "peer d: device is offline (no recent presence)".into()
            )),
            RelayError::HostOffline
        );
        assert!(
            RelayError::from(RpcError::UnknownMethod("WatchCheckoutChangeRequest".into()))
                .is_unknown_method()
        );
        assert!(!RelayError::Timeout.is_unknown_method());
        assert_eq!(RelayError::Timeout.to_string(), "The device didn't respond");
    }
}
