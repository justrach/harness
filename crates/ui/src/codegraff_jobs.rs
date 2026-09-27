//! CodeGraff PR-agent jobs (the gateway's `/v1/jobs`, via the engine's
//! `CodegraffJobs`): the row model Settings → Accounts lists, and the
//! app-wide watcher that posts a banner when a review or description lands.
//!
//! The watcher asks only for what changed (`updatedSince` cursor), so an idle
//! poll is an empty list; it runs only while banners are on, and a signed-out
//! engine answers locally without touching the gateway.

use std::collections::HashSet;
use std::time::Duration;

use gpui::{App, Entity};
use harness_rpc::methods;

use crate::state::AppState;

/// A CodeGraff PR-agent run. Tolerant: unknown fields are ignored, missing
/// ones default. Times are unix seconds.
#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(default)]
pub struct CodegraffJob {
    pub id: String,
    pub kind: String,
    pub status: String,
    pub cancellable: bool,
    pub step: Option<String>,
    pub repo: Option<String>,
    pub pr: Option<serde_json::Value>,
    pub title: Option<String>,
    /// The PR itself.
    pub url: Option<String>,
    /// The posted review comment or PR, once completed.
    pub result_url: Option<String>,
    pub error: Option<String>,
    pub updated_at: Option<f64>,
}

/// One `CodegraffJobs` answer.
#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(default)]
pub struct JobsPage {
    pub jobs: Vec<CodegraffJob>,
    pub next_updated_since: Option<f64>,
}

/// Still queued or running. Pure.
pub fn job_active(job: &CodegraffJob) -> bool {
    matches!(job.status.as_str(), "queued" | "pending" | "running")
}

fn job_kind(job: &CodegraffJob) -> &'static str {
    match job.kind.as_str() {
        "pr_review" => "PR review",
        "pr_describe" => "PR description",
        _ => "PR agent job",
    }
}

/// "owner/name #42" (either part may be missing). Pure.
fn job_place(job: &CodegraffJob) -> String {
    let pr = match &job.pr {
        Some(serde_json::Value::Number(n)) => Some(format!("#{n}")),
        Some(serde_json::Value::String(s)) if !s.is_empty() => Some(if s.starts_with('#') {
            s.clone()
        } else {
            format!("#{s}")
        }),
        _ => None,
    };
    [job.repo.clone(), pr]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" ")
}

fn job_error(job: &CodegraffJob) -> Option<String> {
    job.error.clone().filter(|error| !error.trim().is_empty())
}

/// A job row's title and its "repo #pr · status" line. Pure.
pub fn job_summary(job: &CodegraffJob) -> (String, String) {
    let kind = job_kind(job);
    let title = job
        .title
        .clone()
        .filter(|title| !title.trim().is_empty())
        .unwrap_or_else(|| kind.to_string());
    let status = match job.status.as_str() {
        "queued" | "pending" => "Queued".to_string(),
        "running" => match job.step.as_deref() {
            Some("reviewing") => "Reviewing…".into(),
            Some("describing") => "Describing…".into(),
            Some("posting") => "Posting…".into(),
            Some("working") => "Working…".into(),
            _ => "Starting…".into(),
        },
        "completed" => "Done".into(),
        "cancelled" => "Cancelled".into(),
        "error" => job_error(job)
            .map(|error| format!("Failed: {error}"))
            .unwrap_or_else(|| "Failed".into()),
        other => other.to_string(),
    };
    let place = job_place(job);
    let detail = if place.is_empty() {
        format!("{kind} · {status}")
    } else {
        format!("{place} · {status}")
    };
    (title, detail)
}

/// A finished job's banner: title, body, and the https page a click opens
/// (the posted result, else the PR). Pure.
pub fn job_banner(job: &CodegraffJob) -> (String, String, Option<String>) {
    let failed = job.status == "error";
    let title = match (job.kind.as_str(), failed) {
        (_, true) => format!("{} failed", job_kind(job)),
        ("pr_describe", false) => "PR description posted".to_string(),
        ("pr_review", false) => "PR review ready".to_string(),
        _ => "PR agent job finished".to_string(),
    };
    let detail = if failed {
        job_error(job)
    } else {
        job.title.clone().filter(|title| !title.trim().is_empty())
    };
    let body = [Some(job_place(job)).filter(|p| !p.is_empty()), detail]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" · ");
    let link = [&job.result_url, &job.url]
        .into_iter()
        .flatten()
        .find(|url| url.starts_with("https://"))
        .cloned();
    (title, body, link)
}

/// While a watched job is still working, look again this often.
const ACTIVE_POLL: Duration = Duration::from_secs(20);
/// Nothing working (also the recheck while signed out or banners are off).
const IDLE_POLL: Duration = Duration::from_secs(60);
const ERROR_POLL: Duration = Duration::from_secs(120);
/// A full page means more changes are queued behind it.
const CATCH_UP: Duration = Duration::from_secs(2);
const PAGE: usize = 25;

/// The watcher's cursor state. Pure: fed poll answers, it says what finished
/// and when to look next.
#[derive(Debug, Default)]
pub struct JobWatch {
    /// `None` until a baseline poll set it.
    cursor: Option<i64>,
    /// Jobs last seen working.
    active: HashSet<String>,
    /// Already announced (or finished before the watch began): the cursor is
    /// inclusive, so a job can come back on the next page.
    settled: HashSet<String>,
    full_page: bool,
}

impl JobWatch {
    pub fn params(&self) -> serde_json::Value {
        match self.cursor {
            Some(since) => serde_json::json!({ "limit": PAGE, "updatedSince": since }),
            None => serde_json::json!({ "limit": PAGE }),
        }
    }

    /// Fold in one poll; returns the jobs that just finished. The first poll
    /// is only a baseline — what had already finished stays quiet, and a
    /// job the user cancelled needs no banner.
    pub fn apply(&mut self, page: JobsPage) -> Vec<CodegraffJob> {
        let baseline = self.cursor.is_none();
        self.full_page = !baseline && page.jobs.len() >= PAGE;
        let latest = page
            .jobs
            .iter()
            .filter_map(|job| job.updated_at)
            .map(|at| at as i64)
            .max();
        if self.settled.len() > 512 {
            self.settled.clear();
        }
        let mut finished = Vec::new();
        for job in page.jobs {
            if job_active(&job) {
                self.active.insert(job.id);
                continue;
            }
            self.active.remove(&job.id);
            if self.settled.insert(job.id.clone()) && !baseline && job.status != "cancelled" {
                finished.push(job);
            }
        }
        self.cursor = page
            .next_updated_since
            .map(|at| at as i64)
            .or(latest)
            .or(self.cursor);
        finished
    }

    pub fn delay(&self) -> Duration {
        if self.full_page {
            CATCH_UP
        } else if self.active.is_empty() {
            IDLE_POLL
        } else {
            ACTIVE_POLL
        }
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// Start the app-wide watcher (once per app, not per window).
pub fn watch(state: Entity<AppState>, cx: &mut App) {
    cx.spawn(async move |cx| {
        let mut watch = JobWatch::default();
        // Let launch settle before the first look.
        let mut delay = ACTIVE_POLL;
        loop {
            cx.background_executor().timer(delay).await;
            let engine = cx.update(|cx| {
                crate::settings::current(cx)
                    .notifications_enabled
                    .then(|| state.read(cx).engine().cloned())
                    .flatten()
            });
            let Some(engine) = engine else {
                watch.reset();
                delay = IDLE_POLL;
                continue;
            };
            let result = engine
                .client()
                .call(methods::CODEGRAFF_JOBS, watch.params())
                .await
                .map_err(|err| err.to_string())
                .and_then(|value| {
                    serde_json::from_value::<Option<JobsPage>>(value).map_err(|e| e.to_string())
                });
            let page = match result {
                Ok(Some(page)) => page,
                // Signed out of CodeGraff.
                Ok(None) => {
                    watch.reset();
                    delay = IDLE_POLL;
                    continue;
                }
                Err(error) => {
                    tracing::debug!(%error, "CodeGraff jobs poll failed");
                    delay = ERROR_POLL;
                    continue;
                }
            };
            let finished = watch.apply(page);
            delay = watch.delay();
            if finished.is_empty() {
                continue;
            }
            cx.update(|cx| {
                let settings = crate::settings::current(cx);
                if settings.notifications_background_only && cx.active_window().is_some() {
                    return;
                }
                for job in &finished {
                    let (title, body, link) = job_banner(job);
                    crate::notify::post(&title, &body, link.as_deref());
                }
            });
        }
    })
    .detach();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(value: serde_json::Value) -> CodegraffJob {
        serde_json::from_value(value).unwrap()
    }

    fn page(jobs: Vec<serde_json::Value>, next: Option<i64>) -> JobsPage {
        serde_json::from_value(serde_json::json!({
            "jobs": jobs,
            "next_updated_since": next,
        }))
        .unwrap()
    }

    #[test]
    fn watcher_announces_only_what_finishes_after_it_started() {
        let mut watch = JobWatch::default();
        assert_eq!(watch.params(), serde_json::json!({ "limit": PAGE }));
        // Baseline: an old finished job stays quiet, a running one is tracked.
        let finished = watch.apply(page(
            vec![
                serde_json::json!({"id": "old", "status": "completed", "updated_at": 90}),
                serde_json::json!({"id": "run", "status": "running", "updated_at": 95}),
            ],
            Some(100),
        ));
        assert!(finished.is_empty());
        assert_eq!(watch.delay(), ACTIVE_POLL);
        assert_eq!(
            watch.params(),
            serde_json::json!({ "limit": PAGE, "updatedSince": 100 })
        );

        // An idle poll moves the cursor and changes nothing.
        assert!(watch.apply(page(vec![], Some(120))).is_empty());
        assert_eq!(watch.delay(), ACTIVE_POLL);

        // It finishes: announced once, even when the inclusive cursor
        // returns it again; the old job never is.
        let done = serde_json::json!({"id": "run", "status": "completed", "updated_at": 130});
        let finished = watch.apply(page(vec![done.clone()], Some(130)));
        assert_eq!(finished.len(), 1);
        assert_eq!(watch.delay(), IDLE_POLL);
        assert!(watch.apply(page(vec![done], Some(140))).is_empty());
        let old_again = serde_json::json!({"id": "old", "status": "completed", "updated_at": 140});
        assert!(watch.apply(page(vec![old_again], Some(150))).is_empty());

        // A job that started and failed between polls still gets a banner; a
        // cancelled one doesn't.
        let finished = watch.apply(page(
            vec![
                serde_json::json!({"id": "fast", "status": "error", "updated_at": 160}),
                serde_json::json!({"id": "stop", "status": "cancelled", "updated_at": 161}),
            ],
            Some(170),
        ));
        assert_eq!(
            finished.iter().map(|j| j.id.as_str()).collect::<Vec<_>>(),
            ["fast"]
        );
    }

    #[test]
    fn a_full_page_catches_up_right_away() {
        let mut watch = JobWatch::default();
        watch.apply(page(vec![], Some(10)));
        let jobs = (0..PAGE)
            .map(|i| serde_json::json!({"id": format!("j{i}"), "status": "completed", "updated_at": 20}))
            .collect();
        assert_eq!(watch.apply(page(jobs, Some(20))).len(), PAGE);
        assert_eq!(watch.delay(), CATCH_UP);
    }

    #[test]
    fn banners_say_what_landed_and_link_to_it() {
        let review = job(serde_json::json!({
            "id": "a", "kind": "pr_review", "status": "completed", "repo": "acme/api",
            "pr": 42, "title": "Fix login", "url": "https://github.com/acme/api/pull/42",
            "result_url": "https://github.com/acme/api/pull/42#review-1",
        }));
        assert_eq!(
            job_banner(&review),
            (
                "PR review ready".into(),
                "acme/api #42 · Fix login".into(),
                Some("https://github.com/acme/api/pull/42#review-1".into())
            )
        );
        let failed = job(serde_json::json!({
            "id": "b", "kind": "pr_describe", "status": "error", "repo": "acme/api",
            "pr": 7, "error": "no access", "url": "https://github.com/acme/api/pull/7",
        }));
        assert_eq!(
            job_banner(&failed),
            (
                "PR description failed".into(),
                "acme/api #7 · no access".into(),
                Some("https://github.com/acme/api/pull/7".into())
            )
        );
        // Only https pages are ever opened from a banner.
        let odd = job(serde_json::json!({"id": "c", "status": "completed", "url": "file:///etc"}));
        assert_eq!(job_banner(&odd).2, None);
    }
}
