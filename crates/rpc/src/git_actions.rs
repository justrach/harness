//! Host-authoritative, checksum-fenced Git workflow. No caller-supplied cwd or remote.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GetCheckoutGitStateParams {
    pub chat_id: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyCheckoutGitActionParams {
    pub chat_id: String,
    pub checkout_id: String,
    pub expected_checksum: String,
    pub action: CheckoutGitAction,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum CheckoutGitAction {
    Stage { path: String },
    Unstage { path: String },
    Commit { message: String },
    Push {},
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutGitFile {
    pub path: String,
    pub index_status: String,
    pub worktree_status: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutGitUpstream {
    pub remote: String,
    pub branch: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutGitState {
    pub checkout_id: String,
    pub checksum: String,
    pub branch: Option<String>,
    pub head_sha: Option<String>,
    pub files: Vec<CheckoutGitFile>,
    pub upstream: Option<CheckoutGitUpstream>,
    pub blocked_reason: Option<String>,
}
