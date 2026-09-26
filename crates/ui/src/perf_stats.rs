//! Anonymous performance stats — field RUM for the four journeys "How we made
//! Claude.ai faster" tracks (launch, conversation start/load, message send)
//! plus streaming latency and frame health.
//!
//! Samples aggregate locally into fixed log-spaced histograms (bounds pinned
//! to the telemetry worker's `DESKTOP_STATS_BUCKETS_MS`) and upload as one
//! small batch per window to `POST /v1/harness/stats`, where they merge into
//! fleet p50/p75/p95. A batch carries only a random per-install id (its own
//! file — never the sync device id), the app version, a coarse OS/arch, and
//! bucket counts: no account, chat, path, prompt, or content.
//!
//! Off when Settings → Notifications → "Share anonymous performance stats" is
//! off, when `HARNESS_DISABLE_STATS` is set, and in debug builds unless
//! `HARNESS_STATS_ENDPOINT` points somewhere explicitly.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use gpui::App;

/// Bucket upper bounds in ms; the last bucket is everything above. Must stay
/// identical to zigrepper services/harness-telemetry/src/desktop_stats.ts.
pub const BUCKETS_MS: [f64; 22] = [
    1.0, 2.0, 4.0, 8.33, 16.67, 33.0, 50.0, 75.0, 100.0, 150.0, 200.0, 300.0, 500.0, 750.0, 1000.0,
    1500.0, 2000.0, 3000.0, 5000.0, 10000.0, 20000.0, 60000.0,
];
const BUCKET_COUNT: usize = BUCKETS_MS.len() + 1;

/// The harness-telemetry worker on its codegraff.com domain (the
/// workers.dev address serves the same worker, for older builds).
const DEFAULT_ENDPOINT: &str = "https://otel.codegraff.com/v1/harness/stats";
const SCHEMA: &str = "harness.desktop.stats.v1";
const INSTALL_ID_FILE: &str = "stats-install-id";
/// First upload soon after launch so short sessions still report; then a
/// steady cadence. Empty windows send nothing.
const FIRST_FLUSH: Duration = Duration::from_secs(5 * 60);
const FLUSH_EVERY: Duration = Duration::from_secs(15 * 60);
/// A gap this long between transcript frames is idle time, not a frame.
const MAX_FRAME_GAP_MS: f64 = 250.0;
/// A turn that never reports back is abandoned rather than leaked.
const MAX_TURN_AGE: Duration = Duration::from_secs(60 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Metric {
    /// Process start → first rendered main-window frame.
    AppLaunch,
    /// Chat selected → its transcript is on screen.
    ConversationLoad,
    /// Composer submit → the host wrote the message (turn accepted).
    MessageSend,
    /// Composer submit → first assistant output for that turn.
    FirstToken,
    /// Composer submit → the run finished.
    Turn,
    /// Interval between transcript frames while a reply streams.
    Frame,
}

impl Metric {
    const ALL: [Metric; 6] = [
        Metric::AppLaunch,
        Metric::ConversationLoad,
        Metric::MessageSend,
        Metric::FirstToken,
        Metric::Turn,
        Metric::Frame,
    ];

    fn name(self) -> &'static str {
        match self {
            Metric::AppLaunch => "app_launch_ms",
            Metric::ConversationLoad => "conversation_load_ms",
            Metric::MessageSend => "message_send_ms",
            Metric::FirstToken => "first_token_ms",
            Metric::Turn => "turn_ms",
            Metric::Frame => "frame_ms",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
struct Histogram {
    count: u64,
    sum_ms: f64,
    max_ms: f64,
    buckets: [u64; BUCKET_COUNT],
}

impl Default for Histogram {
    fn default() -> Self {
        Self {
            count: 0,
            sum_ms: 0.0,
            max_ms: 0.0,
            buckets: [0; BUCKET_COUNT],
        }
    }
}

impl Histogram {
    fn add(&mut self, ms: f64) {
        let ms = ms.max(0.0);
        let ix = BUCKETS_MS
            .iter()
            .position(|&bound| ms <= bound)
            .unwrap_or(BUCKETS_MS.len());
        self.buckets[ix] += 1;
        self.count += 1;
        self.sum_ms += ms;
        self.max_ms = self.max_ms.max(ms);
    }
}

struct TurnTimer {
    message_id: String,
    started: Instant,
    accepted: bool,
    first_output: bool,
}

struct Recorder {
    window_start_ms: u64,
    metrics: HashMap<Metric, Histogram>,
    turns: HashMap<String, TurnTimer>,
    loading: Option<(String, Instant)>,
    last_frame: Option<Instant>,
    launched: bool,
}

impl Recorder {
    fn new() -> Self {
        Self {
            window_start_ms: now_ms(),
            metrics: HashMap::new(),
            turns: HashMap::new(),
            loading: None,
            last_frame: None,
            launched: false,
        }
    }

    fn add(&mut self, metric: Metric, ms: f64) {
        if ms.is_finite() {
            self.metrics.entry(metric).or_default().add(ms);
        }
    }
}

static RECORDER: Mutex<Option<Recorder>> = Mutex::new(None);
static PROCESS_START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn with<R>(f: impl FnOnce(&mut Recorder) -> R) -> R {
    let mut guard = RECORDER.lock().unwrap_or_else(PoisonError::into_inner);
    f(guard.get_or_insert_with(Recorder::new))
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn ms_since(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

/// Pin the launch clock as early as possible in `run_app`.
pub fn mark_process_start() {
    PROCESS_START.get_or_init(Instant::now);
}

/// The main window painted its first frame.
pub fn first_window_frame() {
    let Some(start) = PROCESS_START.get().copied() else {
        return;
    };
    with(|r| {
        if !r.launched {
            r.launched = true;
            r.add(Metric::AppLaunch, ms_since(start));
        }
    });
}

/// A chat was selected; its load completes at [`conversation_ready`].
pub fn conversation_selected(chat_id: &str) {
    with(|r| r.loading = Some((chat_id.to_owned(), Instant::now())));
}

pub fn conversation_ready(chat_id: &str) {
    with(|r| {
        if let Some((loading, started)) = r.loading.take() {
            if loading == chat_id {
                r.add(Metric::ConversationLoad, ms_since(started));
            } else {
                r.loading = Some((loading, started));
            }
        }
    });
}

/// Composer submit for `message_id` in `chat_id`.
pub fn turn_started(chat_id: &str, message_id: &str) {
    with(|r| {
        r.turns.retain(|_, t| t.started.elapsed() < MAX_TURN_AGE);
        r.turns.insert(
            chat_id.to_owned(),
            TurnTimer {
                message_id: message_id.to_owned(),
                started: Instant::now(),
                accepted: false,
                first_output: false,
            },
        );
    });
}

/// The host wrote the sent message back (the turn is accepted).
pub fn turn_accepted(chat_id: &str, message_id: &str) {
    with(|r| {
        let Some(t) = r.turns.get_mut(chat_id) else {
            return;
        };
        if t.message_id != message_id || t.accepted {
            return;
        }
        t.accepted = true;
        let ms = ms_since(t.started);
        r.add(Metric::MessageSend, ms);
    });
}

/// Whether `chat_id` still waits on the first assistant output — lets the
/// caller skip the transcript scan once it has been seen.
pub fn awaiting_first_output(chat_id: &str) -> Option<String> {
    with(|r| {
        r.turns
            .get(chat_id)
            .filter(|t| !t.first_output)
            .map(|t| t.message_id.clone())
    })
}

pub fn turn_first_output(chat_id: &str) {
    with(|r| {
        let Some(t) = r.turns.get_mut(chat_id) else {
            return;
        };
        if t.first_output {
            return;
        }
        t.first_output = true;
        let ms = ms_since(t.started);
        r.add(Metric::FirstToken, ms);
    });
}

/// The run ended; `completed` = it finished normally (failed runs and input
/// requests are not turn latencies).
pub fn turn_finished(chat_id: &str, completed: bool) {
    with(|r| {
        if let Some(t) = r.turns.remove(chat_id)
            && completed
        {
            r.add(Metric::Turn, ms_since(t.started));
        }
    });
}

/// A transcript frame rendered. `streaming` = a reply is live; only those
/// intervals measure smoothness (idle repaints are not frames of motion).
pub fn transcript_frame(streaming: bool) {
    let now = Instant::now();
    with(|r| {
        let last = r.last_frame.replace(now);
        if !streaming {
            r.last_frame = None;
            return;
        }
        if let Some(last) = last {
            let ms = now.duration_since(last).as_secs_f64() * 1000.0;
            if ms <= MAX_FRAME_GAP_MS {
                r.add(Metric::Frame, ms);
            }
        }
    });
}

#[derive(serde::Serialize, Debug, PartialEq)]
struct MetricPayload {
    name: &'static str,
    count: u64,
    sum_ms: f64,
    max_ms: f64,
    buckets: Vec<u64>,
}

#[derive(serde::Serialize, Debug)]
struct BatchPayload {
    schema: &'static str,
    install_id: String,
    app_version: &'static str,
    os: &'static str,
    arch: &'static str,
    window_start_ms: u64,
    window_end_ms: u64,
    metrics: Vec<MetricPayload>,
}

/// Swap out the current window's histograms; `None` when nothing was sampled.
fn take_window() -> Option<(u64, u64, Vec<MetricPayload>)> {
    with(|r| {
        let start = r.window_start_ms;
        let end = now_ms();
        r.window_start_ms = end;
        let taken = std::mem::take(&mut r.metrics);
        let metrics: Vec<_> = Metric::ALL
            .iter()
            .filter_map(|m| {
                let h = taken.get(m).filter(|h| h.count > 0)?;
                Some(MetricPayload {
                    name: m.name(),
                    count: h.count,
                    sum_ms: (h.sum_ms * 100.0).round() / 100.0,
                    max_ms: (h.max_ms * 100.0).round() / 100.0,
                    buckets: h.buckets.to_vec(),
                })
            })
            .collect();
        (!metrics.is_empty()).then_some((start, end.max(start), metrics))
    })
}

fn os() -> &'static str {
    match std::env::consts::OS {
        "macos" => "macos",
        "linux" => "linux",
        "windows" => "windows",
        _ => "other",
    }
}

fn arch() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "aarch64",
        "x86_64" => "x86_64",
        _ => "other",
    }
}

/// A random v4 id kept in its own file, so stats can count installs without
/// being joinable to the sync device id or an account.
fn install_id(data_dir: &Path) -> Option<String> {
    let path = data_dir.join(INSTALL_ID_FILE);
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim().to_ascii_lowercase();
        if uuid::Uuid::parse_str(&existing).is_ok_and(|id| id.get_version_num() == 4) {
            return Some(existing);
        }
    }
    let id = uuid::Uuid::new_v4().to_string();
    std::fs::write(&path, &id).ok()?;
    Some(id)
}

fn endpoint() -> Option<String> {
    if std::env::var_os("HARNESS_DISABLE_STATS").is_some_and(|v| !v.is_empty() && v != "0") {
        return None;
    }
    match std::env::var("HARNESS_STATS_ENDPOINT") {
        Ok(url) if !url.is_empty() => Some(url),
        // Dev builds would skew the fleet numbers; opt in explicitly.
        _ if cfg!(debug_assertions) => None,
        _ => Some(DEFAULT_ENDPOINT.to_owned()),
    }
}

/// Start the periodic uploader. Recording is always local and cheap; only
/// the upload is gated on the setting, re-read at every flush.
pub fn start(data_dir: PathBuf, cx: &mut App) {
    let Some(endpoint) = endpoint() else {
        return;
    };
    cx.spawn(async move |cx| {
        let mut wait = FIRST_FLUSH;
        loop {
            cx.background_executor().timer(wait).await;
            wait = FLUSH_EVERY;
            let enabled = cx.update(|cx| crate::settings::current(cx).share_performance_stats);
            // Drop the window either way: a disabled period is never sent later.
            let Some((start, end, metrics)) = take_window() else {
                continue;
            };
            if !enabled {
                continue;
            }
            let data_dir = data_dir.clone();
            let endpoint = endpoint.clone();
            let task = cx.update(|cx| {
                gpui_tokio::Tokio::spawn(cx, async move {
                    let Some(install_id) = install_id(&data_dir) else {
                        return;
                    };
                    let batch = BatchPayload {
                        schema: SCHEMA,
                        install_id,
                        app_version: env!("CARGO_PKG_VERSION"),
                        os: os(),
                        arch: arch(),
                        window_start_ms: start,
                        window_end_ms: end,
                        metrics,
                    };
                    upload(&endpoint, &batch).await;
                })
            });
            let _ = task.await;
        }
    })
    .detach();
}

async fn upload(endpoint: &str, batch: &BatchPayload) {
    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .user_agent(concat!("harness/", env!("CARGO_PKG_VERSION")))
        .build()
    {
        Ok(client) => client,
        Err(err) => {
            tracing::debug!(error = %err, "perf stats: client build failed");
            return;
        }
    };
    let mut request = client.post(endpoint).json(batch);
    if let Ok(key) = std::env::var("HARNESS_STATS_KEY")
        && !key.is_empty()
    {
        request = request.header("x-harness-key", key);
    }
    match request.send().await {
        Ok(resp) if resp.status().is_success() => {}
        Ok(resp) => tracing::debug!(status = %resp.status(), "perf stats: upload rejected"),
        Err(err) => tracing::debug!(error = %err, "perf stats: upload failed"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The recorder is process-global; tests touching it run one at a time.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn reset() -> std::sync::MutexGuard<'static, ()> {
        let guard = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
        *RECORDER.lock().unwrap_or_else(PoisonError::into_inner) = None;
        guard
    }

    #[test]
    fn histogram_buckets_match_the_worker_contract() {
        let mut h = Histogram::default();
        for ms in [0.5, 8.33, 8.34, 16.0, 90_000.0] {
            h.add(ms);
        }
        assert_eq!(BUCKET_COUNT, 23);
        assert_eq!(h.buckets[0], 1);
        assert_eq!(h.buckets[3], 1, "8.33 is inside the 120Hz budget bucket");
        assert_eq!(h.buckets[4], 2);
        assert_eq!(h.buckets[BUCKET_COUNT - 1], 1, "overflow bucket");
        assert_eq!(h.buckets.iter().sum::<u64>(), h.count);
        assert_eq!(h.max_ms, 90_000.0);
    }

    #[test]
    fn journeys_record_once_and_windows_drain() {
        let _guard = reset();
        turn_started("c", "m");
        turn_accepted("c", "other");
        turn_accepted("c", "m");
        turn_accepted("c", "m");
        assert_eq!(awaiting_first_output("c").as_deref(), Some("m"));
        turn_first_output("c");
        turn_first_output("c");
        assert_eq!(awaiting_first_output("c"), None);
        turn_finished("c", true);
        turn_started("c", "m2");
        turn_finished("c", false);
        conversation_selected("a");
        conversation_selected("b");
        conversation_ready("a");
        conversation_ready("b");
        let (_, _, metrics) = take_window().expect("samples recorded");
        let count = |name: &str| metrics.iter().find(|m| m.name == name).map(|m| m.count);
        assert_eq!(count("message_send_ms"), Some(1));
        assert_eq!(count("first_token_ms"), Some(1));
        assert_eq!(
            count("turn_ms"),
            Some(1),
            "failed runs are not turn latencies"
        );
        assert_eq!(
            count("conversation_load_ms"),
            Some(1),
            "only the latest selection"
        );
        assert!(take_window().is_none(), "a drained window sends nothing");
    }

    #[test]
    fn frames_only_count_while_streaming() {
        let _guard = reset();
        transcript_frame(false);
        transcript_frame(false);
        assert!(take_window().is_none());
        transcript_frame(true);
        transcript_frame(true);
        let (_, _, metrics) = take_window().unwrap();
        assert_eq!(metrics[0].name, "frame_ms");
        assert_eq!(metrics[0].count, 1);
    }

    #[test]
    fn install_id_is_a_stable_v4_uuid() {
        let dir = tempfile::tempdir().unwrap();
        let first = install_id(dir.path()).unwrap();
        assert_eq!(install_id(dir.path()).unwrap(), first);
        assert_eq!(uuid::Uuid::parse_str(&first).unwrap().get_version_num(), 4);
        std::fs::write(dir.path().join(INSTALL_ID_FILE), "junk").unwrap();
        assert_ne!(install_id(dir.path()).unwrap(), first, "junk is replaced");
    }
}
