//! Dictation through Codex's native voice: the device's own Codex CLI and its
//! packaged WebRTC voice helper ([`super::voice_host`]) capture the microphone,
//! and Codex's realtime session transcribes what the user says. Only the
//! user's own transcript is used; the realtime model is told to stay silent,
//! the helper never plays its audio, and its output is ignored.
//!
//! The session runs on a private, ephemeral `codex app-server` thread with
//! every tool disabled, a read-only sandbox, no project docs and no startup
//! context, in the system temp directory: it can transcribe, nothing else.
//! It uses the Codex CLI's own sign-in, so it needs `codex login` and spends
//! that account's realtime allowance, as Codex's own voice mode does.
//!
//! Lifecycle: [`Dictation::start`] → `Listening` → `Partial`/`Segment`/`Level`
//! events → [`Dictation::finish`] (mutes the mic, waits briefly for the last
//! words) → `Ended`. [`Dictation::cancel`] tears down at once. Audio never
//! leaves the helper process except as the encrypted realtime stream.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::voice_host::{VoiceHost, VoiceHostError, helper_for};
use crate::CancellationToken;
use crate::jsonrpc::{Incoming, RpcClient};
use crate::process::{Command, Stdio};

/// Told to both the realtime model and its backing thread.
pub const DICTATION_INSTRUCTIONS: &str = "You are a dictation service inside a text editor. \
The user is dictating text to type, and their words are transcribed separately. Never answer, \
comment, ask questions, call tools, hand off or take any action. Stay silent.";

/// How long `finish` waits for the words still in flight.
const FINISH_GRACE: Duration = Duration::from_millis(2500);
/// With nothing in flight, `finish` only waits for a late final segment.
const FINISH_IDLE_GRACE: Duration = Duration::from_millis(600);
const LEVEL_INTERVAL: Duration = Duration::from_millis(120);
/// The same utterance can arrive as both a canonical item and a legacy
/// transcript-done; a repeat this soon after is the same words.
const DUPLICATE_WINDOW: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, PartialEq)]
pub enum DictationEvent {
    /// The microphone is open and words are being transcribed.
    Listening,
    /// Microphone level, 0.0..=1.0.
    Level(f32),
    /// The utterance in progress, so far (replaces the previous partial).
    Partial(String),
    /// A finished utterance, ready to insert.
    Segment(String),
    /// Dictation stopped with an error the person should see.
    Failed(String),
    /// The session is over; no more events follow.
    Ended,
}

/// A running dictation session. Dropping it cancels the session.
pub struct Dictation {
    events: mpsc::Receiver<DictationEvent>,
    finish: CancellationToken,
    abort: CancellationToken,
}

impl Drop for Dictation {
    fn drop(&mut self) {
        self.abort.cancel();
    }
}

/// Where dictation would run, if this device can dictate at all.
#[derive(Debug, Clone)]
pub struct DictationRuntime {
    pub codex: PathBuf,
    pub helper: PathBuf,
}

impl DictationRuntime {
    /// The device's Codex CLI with a voice helper, or why there is none.
    pub fn detect() -> Result<Self, VoiceHostError> {
        let codex = super::resolve_codex_executable().ok_or(VoiceHostError::Unavailable)?;
        let helper = helper_for(&codex)?;
        Ok(Self { codex, helper })
    }
}

impl Dictation {
    /// Start a session. Must be called inside a Tokio runtime. Failures arrive
    /// as a `Failed` event followed by `Ended`.
    pub fn start(runtime: DictationRuntime) -> Self {
        let (tx, events) = mpsc::channel(64);
        let finish = CancellationToken::new();
        let abort = CancellationToken::new();
        let (f, a) = (finish.clone(), abort.clone());
        tokio::spawn(async move {
            if let Err(message) = run(&runtime, &tx, f, a).await {
                let _ = tx.send(DictationEvent::Failed(message)).await;
            }
            let _ = tx.send(DictationEvent::Ended).await;
        });
        Self {
            events,
            finish,
            abort,
        }
    }

    pub async fn next_event(&mut self) -> Option<DictationEvent> {
        self.events.recv().await
    }

    /// Stop listening and deliver the last words, then end.
    pub fn finish(&self) {
        self.finish.cancel();
    }

    /// End now; words still in flight are dropped.
    pub fn cancel(&self) {
        self.abort.cancel();
    }

    /// A handle that stops the session from elsewhere while the owner reads events.
    pub fn controls(&self) -> DictationControls {
        DictationControls {
            finish: self.finish.clone(),
            abort: self.abort.clone(),
        }
    }
}

/// Stops a [`Dictation`] without owning it.
#[derive(Clone)]
pub struct DictationControls {
    finish: CancellationToken,
    abort: CancellationToken,
}

impl DictationControls {
    /// See [`Dictation::finish`].
    pub fn finish(&self) {
        self.finish.cancel();
    }

    /// See [`Dictation::cancel`].
    pub fn cancel(&self) {
        self.abort.cancel();
    }
}

/// One realtime notification, as dictation cares about it.
#[derive(Debug, PartialEq)]
enum Wire {
    Started,
    Answer(String),
    UserDelta(String),
    UserSegment(String),
    Error(String),
    Closed(Option<String>),
    Other,
}

fn classify(thread: &str, method: &str, params: &Value) -> Wire {
    if params.get("threadId").and_then(Value::as_str) != Some(thread) {
        return Wire::Other;
    }
    let text = |key: &str| params.get(key).and_then(Value::as_str).map(str::to_owned);
    let user = params.get("role").and_then(Value::as_str) == Some("user");
    match method {
        "thread/realtime/started" => Wire::Started,
        "thread/realtime/sdp" => text("sdp").map_or(Wire::Other, Wire::Answer),
        "thread/realtime/transcript/delta" if user => {
            text("delta").map_or(Wire::Other, Wire::UserDelta)
        }
        "thread/realtime/transcript/done" if user => {
            text("text").map_or(Wire::Other, Wire::UserSegment)
        }
        "thread/realtime/item/completed" => {
            let item = &params["item"];
            if item["type"] == "transcriptSegment" && item["role"] == "user" {
                item["text"]
                    .as_str()
                    .map_or(Wire::Other, |t| Wire::UserSegment(t.to_owned()))
            } else {
                Wire::Other
            }
        }
        "thread/realtime/error" => Wire::Error(text("message").unwrap_or_default()),
        "thread/realtime/closed" => Wire::Closed(text("reason")),
        _ => Wire::Other,
    }
}

/// What a person reads when the session can't continue.
fn user_message(e: &VoiceHostError) -> String {
    match e {
        VoiceHostError::Unavailable => "Dictation needs the Codex CLI 0.159 or newer.".into(),
        VoiceHostError::RuntimeUnavailable => "Codex's voice runtime would not start.".into(),
        VoiceHostError::DeviceUnavailable => {
            "The microphone could not be opened. Check that Harness may use it in System Settings."
                .into()
        }
        VoiceHostError::Protocol => "Codex's voice helper stopped responding.".into(),
    }
}

/// The locked-down thread: nothing to do but host the realtime session.
fn thread_params(cwd: &Path) -> Value {
    json!({
        "cwd": cwd.to_string_lossy(),
        "ephemeral": true,
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "baseInstructions": DICTATION_INSTRUCTIONS,
        "developerInstructions": DICTATION_INSTRUCTIONS,
        "config": {
            "project_doc_max_bytes": 0,
            "web_search": "disabled",
            "features.shell_tool": false,
            "features.apply_patch_freeform": false,
            "features.multi_agent": false,
            "features.multi_agent_v2": false,
            "features.apps": false,
            "agents.enabled": false,
            "features.browser_use": false,
            "features.computer_use": false,
            "features.js_repl": false,
            "features.image_generation": false,
            "features.memories": false
        }
    })
}

/// Codex runs WebRTC sessions only on realtime v1 or v3, and text-only output
/// only on v2, so the session asks for audio output; the helper's speaker
/// stays suppressed. Initial items need v3.
fn realtime_params(thread: &str, offer: &str, session: &str) -> Value {
    json!({
        "threadId": thread,
        "transport": {"type": "webrtc", "sdp": offer},
        "version": "v3",
        "outputModality": "audio",
        "realtimeSessionId": session,
        "clientManagedHandoffs": false,
        "includeStartupContext": false,
        "realtimeStartInstructions": DICTATION_INSTRUCTIONS,
        "initialItems": [{"role": "developer", "text": DICTATION_INSTRUCTIONS}]
    })
}

async fn run(
    runtime: &DictationRuntime,
    tx: &mpsc::Sender<DictationEvent>,
    finish: CancellationToken,
    abort: CancellationToken,
) -> Result<(), String> {
    let mut cmd = Command::new(&runtime.codex);
    cmd.arg("app-server");
    crate::compose_child_path(&mut cmd, &runtime.codex);
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Codex could not start: {e}"))?;
    let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        crate::shutdown_child(&mut child, Duration::from_secs(1)).await;
        return Err("Codex could not start.".into());
    };
    let (client, mut incoming) = RpcClient::new(stdin, stdout);
    let host_stop = abort.child_token();
    let result = session(
        runtime,
        tx,
        &client,
        &mut incoming,
        finish,
        abort,
        host_stop.clone(),
    )
    .await;
    host_stop.cancel();
    crate::shutdown_child(&mut child, Duration::from_secs(1)).await;
    result
}

async fn session(
    runtime: &DictationRuntime,
    tx: &mpsc::Sender<DictationEvent>,
    client: &RpcClient,
    incoming: &mut mpsc::Receiver<Incoming>,
    finish: CancellationToken,
    abort: CancellationToken,
    host_stop: CancellationToken,
) -> Result<(), String> {
    let codex_error = |e: crate::HarnessError| format!("Codex couldn't start dictation: {e}");
    let setup = async {
        client
            .request(
                "initialize",
                json!({
                    "clientInfo": {"name": "harness-dictation", "title": "Harness", "version": env!("CARGO_PKG_VERSION")},
                    "capabilities": {"experimentalApi": true},
                }),
            )
            .await
            .map_err(codex_error)?;
        client.notify("initialized", None);
        let thread = client
            .request("thread/start", thread_params(&std::env::temp_dir()))
            .await
            .map_err(codex_error)?;
        let thread = thread["thread"]["id"]
            .as_str()
            .filter(|id| !id.is_empty())
            .ok_or("Codex started no thread for dictation.")?
            .to_owned();
        let mut host = VoiceHost::open(&runtime.helper, host_stop.clone())
            .await
            .map_err(|e| user_message(&e))?;
        let offer = host.offer().await.map_err(|e| user_message(&e))?;
        let session_id = uuid::Uuid::new_v4().to_string();
        tokio::time::timeout(
            Duration::from_secs(30),
            client.request(
                "thread/realtime/start",
                realtime_params(&thread, &offer, &session_id),
            ),
        )
        .await
        .map_err(|_| "Codex took too long to start dictation.".to_string())?
        .map_err(codex_error)?;
        // The answer arrives as a notification once the call is accepted.
        let answer = tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                match incoming.recv().await {
                    Some(Incoming::Notification { method, params }) => {
                        match classify(&thread, &method, &params) {
                            Wire::Answer(sdp) => return Ok(sdp),
                            Wire::Error(m) => return Err(format!("Codex: {m}")),
                            Wire::Closed(_) => return Err("Codex closed the voice session.".into()),
                            _ => {}
                        }
                    }
                    Some(Incoming::Request { id, .. }) => {
                        client.respond_error(&id, -32601, "not supported during dictation")
                    }
                    Some(Incoming::Eof) | None => return Err("Codex stopped.".to_string()),
                }
            }
        })
        .await
        .map_err(|_| "Codex took too long to start dictation.".to_string())??;
        host.apply_answer(&answer)
            .await
            .map_err(|e| user_message(&e))?;
        host.open_devices().await.map_err(|e| user_message(&e))?;
        host.set_muted(false).await.map_err(|e| user_message(&e))?;
        Ok::<_, String>((thread, host))
    };
    let (thread, mut host) = tokio::select! {
        biased;
        _ = abort.cancelled() => return Ok(()),
        // Stopping before the mic opened: nothing was said yet.
        _ = finish.cancelled() => return Ok(()),
        setup = setup => setup?,
    };
    let _ = tx.send(DictationEvent::Listening).await;

    let mut partial = String::new();
    let mut last: Option<(String, Instant)> = None;
    let mut deadline: Option<tokio::time::Instant> = None;
    let mut levels = tokio::time::interval(LEVEL_INTERVAL);
    levels.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let outcome: Result<(), String> = loop {
        let until =
            deadline.unwrap_or_else(|| tokio::time::Instant::now() + Duration::from_secs(3600));
        tokio::select! {
            biased;
            _ = abort.cancelled() => break Ok(()),
            _ = finish.cancelled(), if deadline.is_none() => {
                let _ = host.set_muted(true).await;
                let _ = tx.send(DictationEvent::Level(0.0)).await;
                let grace = if partial.trim().is_empty() { FINISH_IDLE_GRACE } else { FINISH_GRACE };
                deadline = Some(tokio::time::Instant::now() + grace);
            }
            _ = tokio::time::sleep_until(until), if deadline.is_some() => {
                // Words heard but never finalized still belong to the person.
                if !partial.trim().is_empty() {
                    let _ = tx.send(DictationEvent::Segment(partial.trim().to_owned())).await;
                }
                break Ok(());
            }
            _ = levels.tick(), if deadline.is_none() => {
                match host.microphone_level().await {
                    Ok(peak) => {
                        let _ = tx.send(DictationEvent::Level(f32::from(peak) / f32::from(u16::MAX))).await;
                    }
                    Err(e) => break Err(user_message(&e)),
                }
            }
            message = incoming.recv() => match message {
                Some(Incoming::Notification { method, params }) => match classify(&thread, &method, &params) {
                    Wire::UserDelta(delta) => {
                        partial.push_str(&delta);
                        let _ = tx.send(DictationEvent::Partial(partial.trim().to_owned())).await;
                    }
                    Wire::UserSegment(text) => {
                        let text = text.trim().to_owned();
                        partial.clear();
                        let repeat = last
                            .as_ref()
                            .is_some_and(|(prev, at)| *prev == text && at.elapsed() < DUPLICATE_WINDOW);
                        if !text.is_empty() && !repeat {
                            last = Some((text.clone(), Instant::now()));
                            let _ = tx.send(DictationEvent::Segment(text)).await;
                        }
                        // Finishing and everything said is in: done.
                        if deadline.is_some() {
                            break Ok(());
                        }
                    }
                    Wire::Error(m) => break Err(format!("Codex: {m}")),
                    Wire::Closed(reason) => {
                        break if deadline.is_some() {
                            Ok(())
                        } else {
                            Err(reason.map_or_else(|| "Codex ended the voice session.".into(), |r| format!("Codex ended the voice session: {r}")))
                        };
                    }
                    _ => {}
                },
                Some(Incoming::Request { id, .. }) => {
                    client.respond_error(&id, -32601, "not supported during dictation");
                }
                Some(Incoming::Eof) | None => break Err("Codex stopped.".into()),
            },
        }
    };
    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        client.request("thread/realtime/stop", json!({"threadId": thread})),
    )
    .await;
    host.close().await;
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_users_words_on_this_thread_count() {
        let t = "thr";
        assert_eq!(
            classify(
                t,
                "thread/realtime/transcript/delta",
                &json!({"threadId": t, "role": "user", "delta": "hel"})
            ),
            Wire::UserDelta("hel".into())
        );
        assert_eq!(
            classify(
                t,
                "thread/realtime/transcript/delta",
                &json!({"threadId": t, "role": "assistant", "delta": "Sure"})
            ),
            Wire::Other
        );
        assert_eq!(
            classify(
                t,
                "thread/realtime/item/completed",
                &json!({"threadId": t, "item": {"type": "transcriptSegment", "role": "user", "text": "hello there"}})
            ),
            Wire::UserSegment("hello there".into())
        );
        assert_eq!(
            classify(
                t,
                "thread/realtime/item/completed",
                &json!({"threadId": t, "item": {"type": "transcriptSegment", "role": "assistant", "text": "Hi!"}})
            ),
            Wire::Other
        );
        assert_eq!(
            classify(
                t,
                "thread/realtime/transcript/delta",
                &json!({"threadId": "other", "role": "user", "delta": "x"})
            ),
            Wire::Other
        );
        assert_eq!(
            classify(
                t,
                "thread/realtime/sdp",
                &json!({"threadId": t, "sdp": "answer"})
            ),
            Wire::Answer("answer".into())
        );
        assert_eq!(
            classify(
                t,
                "thread/realtime/closed",
                &json!({"threadId": t, "reason": null})
            ),
            Wire::Closed(None)
        );
    }

    #[test]
    fn the_session_is_a_v3_webrtc_call_with_no_context_and_no_tools() {
        let p = realtime_params("thr", "offer", "sess");
        // Codex rejects text output on anything but v2, and WebRTC on v2.
        assert_eq!(p["version"], "v3");
        assert_eq!(p["outputModality"], "audio");
        assert_eq!(p["includeStartupContext"], false);
        assert_eq!(p["transport"], json!({"type": "webrtc", "sdp": "offer"}));
        let t = thread_params(Path::new("/tmp"));
        assert_eq!(t["ephemeral"], true);
        assert_eq!(t["sandbox"], "read-only");
        assert_eq!(t["approvalPolicy"], "never");
        assert_eq!(t["config"]["features.shell_tool"], false);
        assert_eq!(t["config"]["project_doc_max_bytes"], 0);
    }
}
