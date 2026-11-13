use super::*;
use crate::source_control::{BranchHeadContext, ProcessOutput, ProcessRunError};
use async_trait::async_trait;
use serde_json::json;
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::Mutex;

fn params(kind: Kind) -> BrowseCheckoutGitHubParams {
    BrowseCheckoutGitHubParams {
        chat_id: "synthetic-chat".into(),
        kind,
        state: None,
        number: None,
        page: None,
        expected_repository: None,
        target_device_id: None,
    }
}
fn source(remote: Option<&str>) -> CheckoutSourceContext {
    CheckoutSourceContext {
        checkout_root: PathBuf::from("/synthetic/checkout"),
        branch: BranchHeadContext::resolve("feature/unrelated", None, Some("origin"), remote),
        default_branch: None,
    }
}
fn repository() -> GitHubRepositoryIdentity {
    repository_identity(&source(Some("git@github.com:example/project.git"))).unwrap()
}
fn identity() -> CheckoutIdentity {
    CheckoutIdentity {
        id: "synthetic-checkout".into(),
        root: "/synthetic/checkout".into(),
        git_dir: "/synthetic/checkout/.git".into(),
    }
}
fn response(value: Value, link: bool) -> Vec<u8> {
    format!(
        "HTTP/2.0 200 OK\r\n{}\r\n{}",
        if link {
            "Link: <https://untrusted.invalid/ignore>; rel=\"next\"\r\n"
        } else {
            ""
        },
        value
    )
    .into_bytes()
}
fn item(number: u64) -> Value {
    json!({"number":number, "title":"Synthetic change", "state":"open", "draft":true,
        "html_url":"javascript:untrusted()", "user":{"login":"synthetic-user"},
        "created_at":"2026-01-01T00:00:00Z", "updated_at":"2026-01-02T00:00:00Z"})
}

#[derive(Default)]
struct Runner {
    calls: Mutex<Vec<ProcessRequest>>,
    outputs: Mutex<VecDeque<Result<ProcessOutput, ProcessRunError>>>,
}
#[async_trait]
impl ProcessRunner for Runner {
    async fn run(&self, request: ProcessRequest) -> Result<ProcessOutput, ProcessRunError> {
        self.calls.lock().unwrap().push(request);
        self.outputs
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected subprocess")
    }
}
fn output(stdout: Vec<u8>) -> Result<ProcessOutput, ProcessRunError> {
    Ok(ProcessOutput {
        success: true,
        stdout,
        stderr: vec![],
        stdout_truncated: false,
    })
}
impl Runner {
    fn with(outputs: Vec<Result<ProcessOutput, ProcessRunError>>) -> Arc<Self> {
        Arc::new(Self {
            outputs: Mutex::new(outputs.into()),
            ..Self::default()
        })
    }
    fn git(&self, root: &str, remote: Option<&str>) {
        let mut outputs = self.outputs.lock().unwrap();
        for text in [
            root,
            "feature/unrelated",
            "origin/feature/unrelated",
            "origin",
        ] {
            outputs.push_back(output(text.as_bytes().to_vec()));
        }
        outputs.push_back(output(remote.unwrap_or("").as_bytes().to_vec()));
        if remote.is_none() {
            outputs.push_back(output(vec![])); // fetch URL also absent
        }
        outputs.push_back(output(b"origin/main".to_vec()));
    }
}

#[tokio::test]
async fn github_repository_endpoints_are_fixed_get_only_and_bounded() {
    let cases = [
        (
            Kind::Pulls,
            None,
            "/repos/example/project/pulls?state=all&per_page=30&page=2",
        ),
        (
            Kind::Issues,
            None,
            "/repos/example/project/issues?state=all&per_page=30&page=2",
        ),
        (Kind::Pull, Some(7), "/repos/example/project/pulls/7"),
        (Kind::Issue, Some(7), "/repos/example/project/issues/7"),
        (
            Kind::Files,
            Some(7),
            "/repos/example/project/pulls/7/files?per_page=30&page=2",
        ),
        (
            Kind::Activity,
            Some(7),
            "/repos/example/project/issues/7/timeline?per_page=30&page=2",
        ),
    ];
    for (kind, number, endpoint) in cases {
        let detail = matches!(kind, Kind::Pull | Kind::Issue);
        let runner = Runner::with(vec![output(response(
            if detail { item(7) } else { json!([]) },
            true,
        ))]);
        let mut p = params(kind);
        p.number = number;
        p.page = Some(if detail { 1 } else { 2 });
        p.state = Some(State::All);
        p.expected_repository = Some(repository().key.clone());
        validate(&p).unwrap();
        let result = Browser::new(runner.clone())
            .query(Path::new("/synthetic/checkout"), repository(), &p)
            .await
            .unwrap();
        assert!(result.has_next_page);
        let calls = runner.calls.lock().unwrap();
        let request = &calls[0];
        assert_eq!(
            request.args,
            [
                "api",
                "--hostname",
                "github.com",
                "--method",
                "GET",
                "--include",
                "--header",
                "Accept: application/vnd.github+json",
                endpoint
            ]
        );
        assert_eq!(request.cwd, Path::new("/synthetic/checkout"));
        assert_eq!(request.output_limit, OUTPUT_LIMIT);
        assert_eq!(request.timeout, Duration::from_secs(20));
        assert!(
            request
                .env
                .contains(&("GH_PROMPT_DISABLED".into(), "1".into()))
        );
        assert!(
            !request
                .args
                .iter()
                .any(|v| v.contains("unrelated") || v.contains("untrusted"))
        );
        assert_eq!(calls.len(), 1); // Link URLs never followed.
    }
    let mut p = params(Kind::Pulls);
    assert!(endpoint(&repository(), &p).contains("state=open"));
    p.state = Some(State::Closed);
    assert!(endpoint(&repository(), &p).contains("state=closed"));
}

#[test]
fn github_repository_pagination_parses_only_headers() {
    for header in [
        "HTTP/2.0 200 OK\r\nLINK: <https://untrusted.invalid>; rel=\"next\", <x>; rel=\"last\"",
        "HTTP/1.1 200 OK\nlink: <x>; rel=\"prev next\"",
        "HTTP/2 200\nLink: <x>; rel=next",
    ] {
        assert!(has_next(header));
    }
    assert!(!has_next("HTTP/2 200\nLink: <next>; rel=\"last\""));
    assert!(!has_next("HTTP/2 200\nX-Other: next"));
    let bytes = b"HTTP/2 200\n\n[]";
    assert!(
        decode(bytes, repository(), &params(Kind::Issues))
            .unwrap()
            .items
            .is_empty()
    );
    let bytes = response(
        json!([{ "number":1,"state":"open","title":"Link: <x>; rel=next"}]),
        false,
    );
    assert!(
        !decode(&bytes, repository(), &params(Kind::Pulls))
            .unwrap()
            .has_next_page
    );
}

#[test]
fn github_repository_issue_list_filters_pull_requests_and_uses_canonical_urls() {
    let issue = item(3);
    let mut pull = item(4);
    pull["pull_request"] = json!({"url":"file:///untrusted"});
    let result = decode(
        &response(json!([issue, pull]), true),
        repository(),
        &params(Kind::Issues),
    )
    .unwrap();
    assert_eq!(result.items.len(), 1);
    assert_eq!(
        result.items[0].url,
        "https://github.com/example/project/issues/3"
    );
    assert!(result.has_next_page);
    assert!(result.files.is_empty() && result.events.is_empty() && result.detail.is_none());
    let result = decode(
        &response(json!([item(8)]), false),
        repository(),
        &params(Kind::Pulls),
    )
    .unwrap();
    assert_eq!(
        result.items[0].url,
        "https://github.com/example/project/pull/8"
    );
    assert!(result.items[0].is_draft);
    let value = serde_json::to_value(result).unwrap();
    for field in ["items", "files", "events"] {
        assert!(value[field].is_array());
    }
}

#[test]
fn github_repository_detail_clips_utf8_body_and_preserves_summary() {
    let mut p = params(Kind::Pull);
    p.number = Some(5);
    let mut value = item(5);
    value["body"] = json!("🦀".repeat(BODY_LIMIT));
    value["base"] = json!({"ref":"main"});
    value["head"] = json!({"ref":"feature/synthetic"});
    value["additions"] = json!(42);
    value["deletions"] = json!(3);
    value["changed_files"] = json!(2);
    value["merged_at"] = json!("2026-01-03T00:00:00Z");
    let result = decode(&response(value, false), repository(), &p).unwrap();
    assert!(result.truncated);
    let detail = result.detail.unwrap();
    assert_eq!(detail.body.len(), BODY_LIMIT);
    assert_eq!(detail.state, "merged");
    assert_eq!(detail.base_ref.as_deref(), Some("main"));
    assert_eq!(detail.head_ref.as_deref(), Some("feature/synthetic"));
    assert_eq!(detail.additions, Some(42));
    assert_eq!(detail.deletions, Some(3));
    assert_eq!(detail.changed_files, Some(2));
    assert_eq!(detail.url, "https://github.com/example/project/pull/5");
    assert_eq!(clip("🦀🦀", 5, &mut false), "🦀");
}

#[test]
fn github_repository_files_mark_clipped_and_omitted_patches() {
    let p = params(Kind::Files);
    let result = decode(&response(json!([
        {"filename":"new.rs","previous_filename":"old.rs","status":"renamed","additions":1,"deletions":2,"patch":"x".repeat(BODY_LIMIT+1)},
        {"filename":"binary.png","status":"added","additions":0,"deletions":0},
        {"filename":"small.rs","status":"modified","additions":1,"deletions":0,"patch":"+small"}
    ]), false), repository(), &p).unwrap();
    assert!(result.truncated);
    assert_eq!(result.files[0].patch.as_ref().unwrap().len(), BODY_LIMIT);
    assert!(result.files[0].patch_truncated);
    assert_eq!(result.files[0].previous_filename.as_deref(), Some("old.rs"));
    assert!(result.files[1].patch.is_none() && result.files[1].patch_truncated);
    assert!(!result.files[2].patch_truncated);
}

#[test]
fn github_repository_timeline_is_clipped_and_never_loads_external_assets() {
    let result = decode(&response(json!([
        {"id":1,"event":"commented","user":{"login":"synthetic-commenter"},"body":"x".repeat(EVENT_LIMIT+1),"created_at":"2026-01-01T00:00:00Z"},
        {"id":"event-2","event":"committed","actor":{"login":"synthetic-actor"},"commit_id":"0123456789abcdef"},
        {"event":"committed","sha":"abcdef123456","author":{"name":"Synthetic Author","date":"2026-01-02T00:00:00Z"},"message":"Preserve native keyboard focus"},
        {"id":4,"event":"reviewed","user":{"login":"synthetic-reviewer"},"state":"approved","submitted_at":"2026-01-03T00:00:00Z","body":"Looks good"}
    ]), false), repository(), &params(Kind::Activity)).unwrap();
    assert!(result.truncated);
    assert_eq!(result.events[0].body.as_ref().unwrap().len(), EVENT_LIMIT);
    assert_eq!(result.events[0].author, "synthetic-commenter");
    assert_eq!(result.events[1].author, "synthetic-actor");
    assert_eq!(
        result.events[1].commit_sha.as_deref(),
        Some("0123456789abcdef")
    );
    assert_eq!(result.events[2].commit_sha.as_deref(), Some("abcdef123456"));
    assert_eq!(result.events[2].author, "Synthetic Author");
    assert_eq!(result.events[2].created_at, "2026-01-02T00:00:00Z");
    assert_eq!(
        result.events[2].body.as_deref(),
        Some("Preserve native keyboard focus")
    );
    assert_eq!(result.events[3].event, "reviewed: approved");
    assert_eq!(result.events[3].created_at, "2026-01-03T00:00:00Z");
}

#[test]
fn github_repository_only_accepts_safe_github_com_remotes() {
    for remote in [
        None,
        Some("/synthetic/repo"),
        Some("https://example.invalid/owner/repo"),
        Some("https://github.com/owner/.."),
        Some("https://github.com/owner/repo%2fescape"),
        Some("https://github.com/owner/repo?query"),
        Some("https://github.com/owner/repo#fragment"),
    ] {
        assert_eq!(
            repository_identity(&source(remote)),
            Err(ChangeRequestError::UnsupportedRepository)
        );
    }
    for remote in [
        "git@github.com:example/project.git",
        "https://github.com/example/project",
        "ssh://git@github.com/example/project.git",
    ] {
        assert_eq!(
            repository_identity(&source(Some(remote))).unwrap(),
            repository()
        );
    }
}

#[test]
fn github_repository_rejects_invalid_numbers_pages_and_unfenced_detail() {
    for number in [None, Some(0), Some(u64::MAX)] {
        let mut p = params(Kind::Pull);
        p.number = number;
        assert!(validate(&p).is_err());
    }
    for page in [0, 10_001, usize::MAX] {
        let mut p = params(Kind::Pulls);
        p.page = Some(page);
        assert!(validate(&p).is_err());
    }
    let mut next_page = params(Kind::Pulls);
    next_page.page = Some(2);
    assert!(validate(&next_page).is_err());
    next_page.expected_repository = Some(repository().key);
    validate(&next_page).unwrap();
    let mut p = params(Kind::Issue);
    p.number = Some(1);
    assert!(validate(&p).is_err());
    p.expected_repository = Some(repository().key);
    validate(&p).unwrap();
    p.page = Some(2);
    assert!(validate(&p).is_err());
    let mut p = params(Kind::Issues);
    p.number = Some(1);
    assert!(validate(&p).is_err());
    assert!(
        serde_json::from_value::<BrowseCheckoutGitHubParams>(
            json!({"chatId":"synthetic", "kind":"pulls", "cwd":"/untrusted"})
        )
        .is_err()
    );
}

#[tokio::test]
async fn github_repository_provider_errors_are_fixed_and_redacted() {
    let cases = [
        (
            Err(ProcessRunError::Spawn(std::io::ErrorKind::NotFound)),
            ChangeRequestError::CliUnavailable,
        ),
        (Err(ProcessRunError::Timeout), ChangeRequestError::Timeout),
        (Err(ProcessRunError::Io), ChangeRequestError::CommandFailed),
        (
            Ok(ProcessOutput {
                success: false,
                stdout: vec![],
                stderr: b"Bad credentials synthetic-private-marker".to_vec(),
                stdout_truncated: false,
            }),
            ChangeRequestError::Authentication,
        ),
        (
            Ok(ProcessOutput {
                success: false,
                stdout: vec![],
                stderr: b"API rate limit reached synthetic-private-marker".to_vec(),
                stdout_truncated: false,
            }),
            ChangeRequestError::RateLimited,
        ),
        (
            Ok(ProcessOutput {
                success: false,
                stdout: vec![],
                stderr: b"synthetic-private-marker".to_vec(),
                stdout_truncated: false,
            }),
            ChangeRequestError::CommandFailed,
        ),
        (
            Ok(ProcessOutput {
                success: true,
                stdout: b"synthetic-private-marker".to_vec(),
                stderr: vec![],
                stdout_truncated: false,
            }),
            ChangeRequestError::Decode,
        ),
        (
            Ok(ProcessOutput {
                success: true,
                stdout: response(json!([]), false),
                stderr: vec![],
                stdout_truncated: true,
            }),
            ChangeRequestError::Decode,
        ),
    ];
    for (output, expected) in cases {
        let browser = Browser::new(Runner::with(vec![output]));
        let error = browser
            .query(Path::new("/synthetic"), repository(), &params(Kind::Pulls))
            .await
            .unwrap_err();
        assert_eq!(error, expected);
        assert!(!error.to_string().contains("synthetic-private-marker"));
    }
    for bytes in [
        b"HTTP/2 401\n\n{}".as_slice(),
        b"HTTP/2 429\n\n{}",
        b"HTTP/2 500\n\n{}",
        b"HTTP/2 200\n\nnot-json",
    ] {
        assert!(decode(bytes, repository(), &params(Kind::Pulls)).is_err());
    }
}

#[tokio::test]
async fn github_repository_rechecks_context_after_provider_and_fences_next_page() {
    let runner = Runner::with(vec![]);
    runner.git(
        "/synthetic/checkout",
        Some("git@github.com:example/project.git"),
    );
    runner
        .outputs
        .lock()
        .unwrap()
        .push_back(output(response(json!([item(1)]), false)));
    runner.git(
        "/synthetic/checkout",
        Some("git@github.com:example/changed.git"),
    );
    let error = browse_with_context(&Browser::new(runner.clone()), &params(Kind::Pulls), || {
        std::future::ready(Ok(identity()))
    })
    .await
    .unwrap_err();
    assert_eq!(error.to_string(), STALE);
    let calls = runner.calls.lock().unwrap();
    assert_eq!(calls.iter().filter(|v| v.program == "gh").count(), 1);
    assert_eq!(calls.last().unwrap().program, "git");
    drop(calls);

    let runner = Runner::with(vec![]);
    runner.git(
        "/synthetic/checkout",
        Some("git@github.com:example/changed.git"),
    );
    let mut p = params(Kind::Pulls);
    p.page = Some(2);
    p.expected_repository = Some(repository().key);
    let error = browse_with_context(&Browser::new(runner.clone()), &p, || {
        std::future::ready(Ok(identity()))
    })
    .await
    .unwrap_err();
    assert_eq!(error.to_string(), STALE);
    assert!(
        runner
            .calls
            .lock()
            .unwrap()
            .iter()
            .all(|v| v.program == "git")
    );
}

#[tokio::test]
async fn github_repository_rechecks_canonical_checkout_and_returns_repo_wide_results() {
    for changed_checkout in [false, true] {
        let runner = Runner::with(vec![]);
        runner.git(
            "/synthetic/checkout",
            Some("git@github.com:example/project.git"),
        );
        runner
            .outputs
            .lock()
            .unwrap()
            .push_back(output(response(json!([item(1)]), false)));
        runner.git(
            "/synthetic/checkout",
            Some("git@github.com:example/project.git"),
        );
        let mut calls = 0;
        let result = browse_with_context(&Browser::new(runner), &params(Kind::Pulls), || {
            calls += 1;
            let mut checkout = identity();
            if changed_checkout && calls == 2 {
                checkout.git_dir = "/synthetic/other/.git".into();
            }
            std::future::ready(Ok(checkout))
        })
        .await;
        assert_eq!(calls, 2);
        if changed_checkout {
            assert_eq!(result.unwrap_err().to_string(), STALE);
        } else {
            assert_eq!(result.unwrap().items.len(), 1);
        }
    }
}

#[tokio::test]
async fn github_repository_missing_or_unsupported_remote_never_runs_gh() {
    for remote in [None, Some("https://example.invalid/example/project")] {
        let runner = Runner::with(vec![]);
        runner.git("/synthetic/checkout", remote);
        let result =
            browse_with_context(&Browser::new(runner.clone()), &params(Kind::Pulls), || {
                std::future::ready(Ok(identity()))
            })
            .await;
        assert_eq!(
            result.unwrap_err().to_string(),
            ChangeRequestError::UnsupportedRepository.to_string()
        );
        assert!(
            runner
                .calls
                .lock()
                .unwrap()
                .iter()
                .all(|request| request.program == "git")
        );
    }
}

#[test]
fn github_repository_caps_page_and_serialized_output_and_rejects_bad_shapes() {
    // Even metadata made entirely of JSON-escaped control characters stays
    // under the wire cap; fields and provider page cardinality are bounded.
    let files = (0..PAGE_SIZE)
        .map(|_| {
            json!({
                "filename":"\u{0001}".repeat(4096), "status":"modified", "additions":1,
                "deletions":0, "patch":"\u{0001}".repeat(BODY_LIMIT)
            })
        })
        .collect::<Vec<_>>();
    let result = decode(
        &response(json!(files), false),
        repository(),
        &params(Kind::Files),
    )
    .unwrap();
    assert!(result.truncated);
    assert!(result.files.len() < PAGE_SIZE);
    assert!(serde_json::to_vec(&result).unwrap().len() <= OUTPUT_LIMIT);
    let values: Vec<_> = (1..=40).map(item).collect();
    let result = decode(
        &response(json!(values), false),
        repository(),
        &params(Kind::Pulls),
    )
    .unwrap();
    assert!(result.truncated);
    assert_eq!(result.items.len(), PAGE_SIZE);
    assert!(serde_json::to_vec(&result).unwrap().len() <= OUTPUT_LIMIT);
    for value in [
        json!({}),
        json!([{"number":0,"title":"invalid","state":"open"}]),
        json!([{"number":1,"title":"invalid","state":"other"}]),
    ] {
        assert!(decode(&response(value, false), repository(), &params(Kind::Pulls)).is_err());
    }
    let mut p = params(Kind::Pull);
    p.number = Some(2);
    assert!(decode(&response(item(1), false), repository(), &p).is_err());
}
