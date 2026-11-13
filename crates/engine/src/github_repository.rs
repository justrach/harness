//! Read-only repository browsing on the selected chat's host. The caller supplies
//! neither a checkout path nor an API endpoint; `gh` reuses the host's own login.
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use harness_rpc::{
    BrowseCheckoutGitHubParams, BrowseCheckoutGitHubResponse, GitHubRepositoryDetail,
    GitHubRepositoryEvent, GitHubRepositoryFile, GitHubRepositoryIdentity, GitHubRepositoryItem,
    GitHubRepositoryKind as Kind, GitHubRepositoryState as State, RpcError,
};
use serde::Deserialize;
use serde_json::Value;

use crate::source_control::{
    ChangeRequestError, CheckoutSourceContext, GitCheckoutInspector, ProcessRequest, ProcessRunner,
    SystemProcessRunner, classify_github_failure, classify_run_error,
};
use crate::{CheckoutIdentity, Repos, WorkspaceHost};

const OUTPUT_LIMIT: usize = 1024 * 1024;
const BODY_LIMIT: usize = 16 * 1024;
const EVENT_LIMIT: usize = 8 * 1024;
const PAGE_SIZE: usize = 30;
const LOCAL_DEADLINE: Duration = Duration::from_secs(90);
const STALE: &str = "Chat checkout or GitHub repository changed; refresh the repository browser";
fn fail(message: &'static str) -> RpcError {
    RpcError::Failed(message.into())
}
fn provider_error(error: ChangeRequestError) -> RpcError {
    RpcError::Failed(error.to_string())
}

/// The outer deadline bounds *all* pre/post Git calls as well as the provider.
/// Relay callers allow an additional ten seconds for transport overhead.
pub async fn browse(
    workspace: &WorkspaceHost,
    repos: &Repos,
    device_id: &str,
    params: BrowseCheckoutGitHubParams,
) -> Result<BrowseCheckoutGitHubResponse, RpcError> {
    tokio::time::timeout(LOCAL_DEADLINE, async {
        let browser = Browser::new(Arc::new(SystemProcessRunner));
        browse_with_context(&browser, &params, || {
            checkout(workspace, repos, device_id, &params.chat_id)
        })
        .await
    })
    .await
    .map_err(|_| provider_error(ChangeRequestError::Timeout))?
}

async fn browse_with_context<F, Fut>(
    browser: &Browser,
    params: &BrowseCheckoutGitHubParams,
    mut resolve: F,
) -> Result<BrowseCheckoutGitHubResponse, RpcError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<CheckoutIdentity, RpcError>>,
{
    validate(params)?;
    let before = resolve().await?;
    let source = browser
        .inspector
        .inspect(&before.root)
        .await
        .map_err(provider_error)?;
    let repository = repository_identity(&source).map_err(provider_error)?;
    check_expected(params, &repository)?;
    let result = browser
        .query(&source.checkout_root, repository.clone(), params)
        .await;
    // Even a provider error must not escape with a now-stale context.
    let after = resolve().await?;
    let current = browser
        .inspector
        .inspect(&after.root)
        .await
        .map_err(provider_error)?;
    let current_repository = repository_identity(&current).map_err(provider_error)?;
    check_context(&before, &after, &repository, &current_repository)?;
    result.map_err(provider_error)
}

async fn checkout(
    workspace: &WorkspaceHost,
    repos: &Repos,
    device_id: &str,
    chat_id: &str,
) -> Result<CheckoutIdentity, RpcError> {
    let chat = workspace
        .chat(chat_id)
        .map_err(|_| fail("Chat is unavailable"))?
        .ok_or_else(|| fail("Chat is unavailable"))?;
    if chat.device_id != device_id {
        return Err(fail("Chat is not hosted by this device"));
    }
    let cwd = chat
        .cwd
        .as_deref()
        .filter(|cwd| !cwd.trim().is_empty())
        .ok_or_else(|| fail("Chat has no checkout"))?;
    repos
        .checkout_identity(Path::new(cwd))
        .await
        .map_err(|_| provider_error(ChangeRequestError::RepositoryUnavailable))
}

fn check_context(
    before: &CheckoutIdentity,
    after: &CheckoutIdentity,
    repository: &GitHubRepositoryIdentity,
    current: &GitHubRepositoryIdentity,
) -> Result<(), RpcError> {
    if before != after || repository != current {
        return Err(fail(STALE));
    }
    Ok(())
}

fn check_expected(
    params: &BrowseCheckoutGitHubParams,
    repository: &GitHubRepositoryIdentity,
) -> Result<(), RpcError> {
    if params
        .expected_repository
        .as_ref()
        .is_some_and(|key| key != &repository.key)
    {
        return Err(fail(STALE));
    }
    Ok(())
}

fn validate(params: &BrowseCheckoutGitHubParams) -> Result<(), RpcError> {
    if params.chat_id.is_empty() || params.chat_id.len() > 1024 {
        return Err(fail("A valid chat is required"));
    }
    if !(1..=10_000).contains(&params.page.unwrap_or(1)) {
        return Err(fail("GitHub page must be between 1 and 10000"));
    }
    let list = matches!(params.kind, Kind::Pulls | Kind::Issues);
    if !list
        && !params
            .number
            .is_some_and(|number| (1..=i64::MAX as u64).contains(&number))
    {
        return Err(fail("A positive GitHub item number is required"));
    }
    if list && params.number.is_some() {
        return Err(fail("Repository lists do not accept an item number"));
    }
    if (!list || params.page.unwrap_or(1) > 1)
        && params
            .expected_repository
            .as_deref()
            .is_none_or(str::is_empty)
    {
        return Err(fail(
            "A repository key is required; refresh the repository browser",
        ));
    }
    if matches!(params.kind, Kind::Pull | Kind::Issue) && params.page.unwrap_or(1) != 1 {
        return Err(fail("GitHub item details only support page 1"));
    }
    Ok(())
}

fn valid_segment(segment: &str) -> bool {
    !segment.is_empty()
        && segment.len() <= 100
        && segment != "."
        && segment != ".."
        && segment
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
}
fn repository_identity(
    source: &CheckoutSourceContext,
) -> Result<GitHubRepositoryIdentity, ChangeRequestError> {
    let branch = &source.branch;
    let host = branch
        .host
        .as_deref()
        .ok_or(ChangeRequestError::UnsupportedRepository)?;
    let owner = branch
        .owner
        .as_deref()
        .filter(|v| valid_segment(v))
        .ok_or(ChangeRequestError::UnsupportedRepository)?;
    let name = branch
        .repository
        .as_deref()
        .filter(|v| valid_segment(v))
        .ok_or(ChangeRequestError::UnsupportedRepository)?;
    // Never pass credentials to an arbitrary host selected by repository config.
    if host != "github.com" {
        return Err(ChangeRequestError::UnsupportedRepository);
    }
    Ok(GitHubRepositoryIdentity {
        key: format!(
            "github.com/{}/{}",
            owner.to_ascii_lowercase(),
            name.to_ascii_lowercase()
        ),
        host: host.into(),
        owner: owner.into(),
        name: name.into(),
        url: format!("https://github.com/{owner}/{name}"),
    })
}

struct Browser {
    inspector: GitCheckoutInspector,
    runner: Arc<dyn ProcessRunner>,
}
impl Browser {
    fn new(runner: Arc<dyn ProcessRunner>) -> Self {
        Self {
            inspector: GitCheckoutInspector::new(runner.clone()),
            runner,
        }
    }

    async fn query(
        &self,
        root: &Path,
        repository: GitHubRepositoryIdentity,
        params: &BrowseCheckoutGitHubParams,
    ) -> Result<BrowseCheckoutGitHubResponse, ChangeRequestError> {
        let output = self
            .runner
            .run(ProcessRequest {
                program: "gh".into(),
                args: vec![
                    "api".into(),
                    "--hostname".into(),
                    "github.com".into(),
                    "--method".into(),
                    "GET".into(),
                    "--include".into(),
                    "--header".into(),
                    "Accept: application/vnd.github+json".into(),
                    endpoint(&repository, params),
                ],
                cwd: root.into(),
                env: vec![
                    ("GH_HOST".into(), "github.com".into()),
                    ("GH_PROMPT_DISABLED".into(), "1".into()),
                    ("GH_PAGER".into(), "cat".into()),
                ],
                timeout: Duration::from_secs(20),
                output_limit: OUTPUT_LIMIT,
            })
            .await
            .map_err(classify_run_error)?;
        if !output.success {
            return Err(classify_github_failure(&output.stderr));
        }
        if output.stdout_truncated || output.stdout.len() > OUTPUT_LIMIT {
            return Err(ChangeRequestError::Decode);
        }
        decode(&output.stdout, repository, params)
    }
}

fn endpoint(repository: &GitHubRepositoryIdentity, params: &BrowseCheckoutGitHubParams) -> String {
    let base = format!("/repos/{}/{}", repository.owner, repository.name);
    let number = params.number.unwrap_or(0);
    let page = params.page.unwrap_or(1);
    match params.kind {
        Kind::Pulls | Kind::Issues => {
            let resource = if params.kind == Kind::Pulls {
                "pulls"
            } else {
                "issues"
            };
            let state = match params.state.unwrap_or_default() {
                State::Open => "open",
                State::Closed => "closed",
                State::All => "all",
            };
            format!("{base}/{resource}?state={state}&per_page={PAGE_SIZE}&page={page}")
        }
        Kind::Pull => format!("{base}/pulls/{number}"),
        Kind::Issue => format!("{base}/issues/{number}"),
        Kind::Files => format!("{base}/pulls/{number}/files?per_page={PAGE_SIZE}&page={page}"),
        Kind::Activity => {
            format!("{base}/issues/{number}/timeline?per_page={PAGE_SIZE}&page={page}")
        }
    }
}

fn headers_and_body(bytes: &[u8]) -> Result<(&str, &str), ChangeRequestError> {
    let text = std::str::from_utf8(bytes).map_err(|_| ChangeRequestError::Decode)?;
    let (headers, body) = text
        .split_once("\r\n\r\n")
        .or_else(|| text.split_once("\n\n"))
        .ok_or(ChangeRequestError::Decode)?;
    let mut status = headers.lines().next().unwrap_or("").split_whitespace();
    if !status.next().is_some_and(|v| v.starts_with("HTTP/")) {
        return Err(ChangeRequestError::Decode);
    }
    match status.next().and_then(|v| v.parse::<u16>().ok()) {
        Some(200..=299) => Ok((headers, body)),
        Some(401) => Err(ChangeRequestError::Authentication),
        Some(429) => Err(ChangeRequestError::RateLimited),
        Some(_) => Err(ChangeRequestError::CommandFailed),
        None => Err(ChangeRequestError::Decode),
    }
}
fn has_next(headers: &str) -> bool {
    headers
        .lines()
        .filter_map(|line| line.split_once(':'))
        .filter(|(name, _)| name.eq_ignore_ascii_case("link"))
        .any(|(_, value)| {
            value.split(',').any(|link| {
                link.split(';')
                    .skip(1)
                    .filter_map(|part| part.trim().split_once('='))
                    .any(|(name, value)| {
                        name.trim().eq_ignore_ascii_case("rel")
                            && value
                                .trim()
                                .trim_matches('"')
                                .split_whitespace()
                                .any(|rel| rel == "next")
                    })
            })
        })
}
fn clip(value: &str, limit: usize, truncated: &mut bool) -> String {
    if value.len() <= limit {
        return value.into();
    }
    *truncated = true;
    let mut end = limit;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].into()
}
fn field(value: &Value, key: &str, limit: usize, truncated: &mut bool) -> String {
    clip(
        value.get(key).and_then(Value::as_str).unwrap_or(""),
        limit,
        truncated,
    )
}
fn author(value: &Value, key: &str, truncated: &mut bool) -> String {
    field(&value[key], "login", 256, truncated)
}

#[derive(Deserialize)]
struct RawItem {
    number: u64,
    title: String,
    state: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    user: Value,
    #[serde(default)]
    created_at: String,
    #[serde(default)]
    updated_at: String,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    base: Value,
    #[serde(default)]
    head: Value,
    #[serde(default)]
    additions: Option<u64>,
    #[serde(default)]
    deletions: Option<u64>,
    #[serde(default)]
    changed_files: Option<u64>,
    #[serde(default)]
    pull_request: Option<Value>,
    #[serde(default)]
    merged_at: Option<String>,
}
fn item_url(repository: &GitHubRepositoryIdentity, kind: Kind, number: u64) -> String {
    let resource = if matches!(kind, Kind::Pull | Kind::Pulls) {
        "pull"
    } else {
        "issues"
    };
    format!("{}/{resource}/{number}", repository.url)
}
fn raw_item(value: Value) -> Result<RawItem, ChangeRequestError> {
    let item: RawItem = serde_json::from_value(value).map_err(|_| ChangeRequestError::Decode)?;
    if item.number == 0
        || item.number > i64::MAX as u64
        || !matches!(item.state.as_str(), "open" | "closed")
    {
        return Err(ChangeRequestError::Decode);
    }
    Ok(item)
}
fn item_state(item: &RawItem) -> String {
    if item.merged_at.is_some() {
        "merged".into()
    } else {
        item.state.clone()
    }
}
fn decode(
    bytes: &[u8],
    repository: GitHubRepositoryIdentity,
    params: &BrowseCheckoutGitHubParams,
) -> Result<BrowseCheckoutGitHubResponse, ChangeRequestError> {
    let (headers, body) = headers_and_body(bytes)?;
    let value: Value = serde_json::from_str(body).map_err(|_| ChangeRequestError::Decode)?;
    let mut response = BrowseCheckoutGitHubResponse {
        repository,
        kind: params.kind,
        items: vec![],
        detail: None,
        files: vec![],
        events: vec![],
        page: params.page.unwrap_or(1),
        has_next_page: has_next(headers),
        truncated: false,
    };
    let truncated = &mut response.truncated;
    if matches!(params.kind, Kind::Pull | Kind::Issue) {
        let item = raw_item(value)?;
        if Some(item.number) != params.number
            || (params.kind == Kind::Issue && item.pull_request.is_some())
        {
            return Err(ChangeRequestError::Decode);
        }
        response.detail = Some(GitHubRepositoryDetail {
            number: item.number,
            title: clip(&item.title, 4096, truncated),
            url: item_url(&response.repository, params.kind, item.number),
            state: item_state(&item),
            body: clip(item.body.as_deref().unwrap_or(""), BODY_LIMIT, truncated),
            author: field(&item.user, "login", 256, truncated),
            created_at: clip(&item.created_at, 128, truncated),
            updated_at: clip(&item.updated_at, 128, truncated),
            is_draft: item.draft,
            base_ref: item
                .base
                .get("ref")
                .and_then(Value::as_str)
                .map(|v| clip(v, 4096, truncated)),
            head_ref: item
                .head
                .get("ref")
                .and_then(Value::as_str)
                .map(|v| clip(v, 4096, truncated)),
            additions: item.additions,
            deletions: item.deletions,
            changed_files: item.changed_files,
        });
    } else {
        let values = value.as_array().ok_or(ChangeRequestError::Decode)?;
        if values.len() > PAGE_SIZE {
            *truncated = true;
        }
        for value in values.iter().take(PAGE_SIZE) {
            match params.kind {
                Kind::Pulls | Kind::Issues => {
                    let item = raw_item(value.clone())?;
                    if params.kind == Kind::Issues && item.pull_request.is_some() {
                        continue;
                    }
                    response.items.push(GitHubRepositoryItem {
                        number: item.number,
                        title: clip(&item.title, 4096, truncated),
                        url: item_url(&response.repository, params.kind, item.number),
                        state: item_state(&item),
                        is_draft: item.draft,
                        author: field(&item.user, "login", 256, truncated),
                        updated_at: clip(&item.updated_at, 128, truncated),
                    });
                }
                Kind::Files => {
                    let patch = value.get("patch").and_then(Value::as_str);
                    let mut patch_truncated = patch.is_none();
                    let patch = patch.map(|v| clip(v, BODY_LIMIT, &mut patch_truncated));
                    *truncated |= patch_truncated;
                    response.files.push(GitHubRepositoryFile {
                        filename: required_text(value, "filename", 4096, truncated)?,
                        status: required_text(value, "status", 128, truncated)?,
                        additions: value["additions"]
                            .as_u64()
                            .ok_or(ChangeRequestError::Decode)?,
                        deletions: value["deletions"]
                            .as_u64()
                            .ok_or(ChangeRequestError::Decode)?,
                        patch,
                        previous_filename: value
                            .get("previous_filename")
                            .and_then(Value::as_str)
                            .map(|v| clip(v, 4096, truncated)),
                        patch_truncated,
                    });
                }
                Kind::Activity => {
                    if !value.is_object() {
                        return Err(ChangeRequestError::Decode);
                    }
                    let id = value
                        .get("id")
                        .map(|v| match v {
                            Value::String(v) => v.clone(),
                            Value::Number(v) => v.to_string(),
                            _ => String::new(),
                        })
                        .unwrap_or_default();
                    let actor = if value["actor"].is_object() {
                        "actor"
                    } else {
                        "user"
                    };
                    let mut name = author(value, actor, truncated);
                    if name.is_empty() {
                        name = field(&value["author"], "login", 256, truncated);
                    }
                    if name.is_empty() {
                        name = field(&value["author"], "name", 256, truncated);
                    }
                    let mut event = required_text(value, "event", 128, truncated)?;
                    if event == "reviewed" {
                        if let Some(state) = value["state"].as_str().filter(|s| {
                            matches!(
                                *s,
                                "approved"
                                    | "changes_requested"
                                    | "commented"
                                    | "dismissed"
                                    | "pending"
                            )
                        }) {
                            event.push_str(": ");
                            event.push_str(state);
                        }
                    }
                    let created = value["created_at"]
                        .as_str()
                        .or_else(|| value["submitted_at"].as_str())
                        .or_else(|| value["author"]["date"].as_str())
                        .unwrap_or("");
                    let body = value["body"].as_str().or_else(|| {
                        (event == "committed")
                            .then(|| value["message"].as_str())
                            .flatten()
                    });
                    response.events.push(GitHubRepositoryEvent {
                        id: clip(&id, 256, truncated),
                        event,
                        author: name,
                        created_at: clip(created, 128, truncated),
                        body: body.map(|v| clip(v, EVENT_LIMIT, truncated)),
                        commit_sha: value
                            .get("commit_id")
                            .and_then(Value::as_str)
                            .or_else(|| value["sha"].as_str())
                            .map(|v| clip(v, 128, truncated)),
                    });
                }
                _ => unreachable!(),
            }
        }
    }
    // JSON escaping can multiply even short strings. Bound the serialized result,
    // not just input bytes. Omitted page entries are explicitly marked incomplete.
    while serde_json::to_vec(&response)
        .map_err(|_| ChangeRequestError::Decode)?
        .len()
        > OUTPUT_LIMIT
    {
        response.truncated = true;
        if response.files.pop().is_some()
            || response.events.pop().is_some()
            || response.items.pop().is_some()
        {
            continue;
        }
        return Err(ChangeRequestError::Decode);
    }
    Ok(response)
}
fn required_text(
    value: &Value,
    key: &str,
    limit: usize,
    truncated: &mut bool,
) -> Result<String, ChangeRequestError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(|v| clip(v, limit, truncated))
        .ok_or(ChangeRequestError::Decode)
}

#[cfg(test)]
#[path = "github_repository_tests.rs"]
mod tests;
