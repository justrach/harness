//! Read-only, host-resolved GitHub repository browsing. No endpoint or cwd input.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum GitHubRepositoryKind {
    Pulls,
    Issues,
    Pull,
    Issue,
    Files,
    Activity,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum GitHubRepositoryState {
    #[default]
    Open,
    Closed,
    All,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BrowseCheckoutGitHubParams {
    pub chat_id: String,
    pub kind: GitHubRepositoryKind,
    pub state: Option<GitHubRepositoryState>,
    pub number: Option<u64>,
    pub page: Option<usize>,
    pub expected_repository: Option<String>,
    pub target_device_id: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubRepositoryIdentity {
    pub key: String,
    pub host: String,
    pub owner: String,
    pub name: String,
    pub url: String,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubRepositoryItem {
    pub number: u64,
    pub title: String,
    pub url: String,
    pub state: String,
    pub is_draft: bool,
    pub author: String,
    pub updated_at: String,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubRepositoryDetail {
    pub number: u64,
    pub title: String,
    pub url: String,
    pub state: String,
    pub body: String,
    pub author: String,
    pub created_at: String,
    pub updated_at: String,
    pub is_draft: bool,
    pub base_ref: Option<String>,
    pub head_ref: Option<String>,
    pub additions: Option<u64>,
    pub deletions: Option<u64>,
    pub changed_files: Option<u64>,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubRepositoryFile {
    pub filename: String,
    pub status: String,
    pub additions: u64,
    pub deletions: u64,
    pub patch: Option<String>,
    pub previous_filename: Option<String>,
    /// Missing (binary/omitted) and clipped patches are not complete diffs.
    pub patch_truncated: bool,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHubRepositoryEvent {
    pub id: String,
    pub event: String,
    pub author: String,
    pub created_at: String,
    pub body: Option<String>,
    pub commit_sha: Option<String>,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowseCheckoutGitHubResponse {
    pub repository: GitHubRepositoryIdentity,
    pub kind: GitHubRepositoryKind,
    pub items: Vec<GitHubRepositoryItem>,
    pub detail: Option<GitHubRepositoryDetail>,
    pub files: Vec<GitHubRepositoryFile>,
    pub events: Vec<GitHubRepositoryEvent>,
    pub page: usize,
    pub has_next_page: bool,
    pub truncated: bool,
}
