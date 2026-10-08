//! Dictation end to end against an offline `codex app-server` and voice helper
//! (`tests/fixtures/fake-codex-realtime.py`, `fake-codex-voice-host.py`): the
//! realtime handshake, which words become text, and how a session ends.

#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use harness_adapters::{Dictation, DictationEvent, DictationRuntime};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn executable(path: &Path, body: &str) {
    std::fs::write(path, body).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A Codex install of fakes in its own temp dir: a wrapper that runs the
/// fake app-server with this test's log and mode, and the fake helper at the
/// real package path.
fn runtime(dir: &Path, mode: &str) -> DictationRuntime {
    let codex = dir.join("codex");
    executable(
        &codex,
        &format!(
            "#!/bin/sh\nexport FAKE_DICTATION_LOG='{}'\nexport FAKE_DICTATION_MODE='{mode}'\nexec python3 '{}' \"$@\"\n",
            dir.join("codex.jsonl").display(),
            fixture("fake-codex-realtime.py").display()
        ),
    );
    let helper = dir.join("codex-resources/voice/bin/codex-voice-host");
    std::fs::create_dir_all(helper.parent().unwrap()).unwrap();
    std::fs::copy(fixture("fake-codex-voice-host.py"), &helper).unwrap();
    std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
    DictationRuntime { codex, helper }
}

fn lines(path: &Path) -> Vec<serde_json::Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

/// Events until `stop` matches (or the session ends), levels dropped.
async fn until(
    dictation: &mut Dictation,
    stop: impl Fn(&DictationEvent) -> bool,
) -> Vec<DictationEvent> {
    let mut seen = Vec::new();
    tokio::time::timeout(Duration::from_secs(20), async {
        while let Some(event) = dictation.next_event().await {
            let done = stop(&event) || event == DictationEvent::Ended;
            if !matches!(event, DictationEvent::Level(_)) {
                seen.push(event);
            }
            if done {
                break;
            }
        }
    })
    .await
    .expect("dictation events");
    seen
}

#[tokio::test]
async fn the_users_words_become_text_once_and_finish_keeps_what_was_in_flight() {
    let dir = tempfile::tempdir().unwrap();
    let mut dictation = Dictation::start(runtime(dir.path(), ""));
    let first = until(&mut dictation, |e| {
        *e == DictationEvent::Partial("and more".into())
    })
    .await;
    assert_eq!(
        first,
        vec![
            DictationEvent::Listening,
            DictationEvent::Partial("hello".into()),
            DictationEvent::Partial("hello world".into()),
            // The canonical item and the legacy transcript-done are one utterance;
            // the assistant's reply never shows up.
            DictationEvent::Segment("hello world".into()),
            DictationEvent::Partial("and more".into()),
        ]
    );
    dictation.finish();
    let rest = until(&mut dictation, |_| false).await;
    assert_eq!(
        rest,
        vec![
            DictationEvent::Segment("and more".into()),
            DictationEvent::Ended
        ]
    );

    let codex = lines(&dir.path().join("codex.jsonl"));
    let method = |m: &str| codex.iter().find(|l| l["method"] == m).cloned();
    let thread = method("thread/start").expect("thread/start")["params"].clone();
    assert_eq!(thread["ephemeral"], true);
    assert_eq!(thread["sandbox"], "read-only");
    assert_eq!(thread["config"]["features.shell_tool"], false);
    let realtime = method("thread/realtime/start").expect("realtime start")["params"].clone();
    assert_eq!(realtime["transport"]["sdp"], "fixture-offer");
    assert_eq!(realtime["outputModality"], "text");
    assert_eq!(realtime["includeStartupContext"], false);
    assert!(method("thread/realtime/stop").is_some(), "{codex:?}");

    let helper = lines(&dir.path().join("helper.jsonl"));
    let kinds: Vec<_> = helper
        .iter()
        .map(|f| f["type"].as_str().unwrap().to_owned())
        .filter(|k| k != "inspectAudio")
        .collect();
    assert_eq!(
        kinds,
        [
            "hello",
            "initializeRuntime",
            "startTransport",
            "applyAnswer",
            "openDevices",
            "setAudioControls",
            "setAudioControls",
            "close"
        ]
    );
    // Listening unmutes the mic; finishing mutes it. The speaker never plays.
    let controls: Vec<_> = helper
        .iter()
        .filter(|f| f["type"] == "setAudioControls")
        .map(|f| f["controls"].clone())
        .collect();
    assert_eq!(controls[0]["microphoneMuted"], false);
    assert_eq!(controls[1]["microphoneMuted"], true);
    assert!(controls.iter().all(|c| c["speakerSuppressed"] == true));
}

#[tokio::test]
async fn a_refused_session_says_why_and_ends() {
    let dir = tempfile::tempdir().unwrap();
    let mut dictation = Dictation::start(runtime(dir.path(), "fail-start"));
    let events = until(&mut dictation, |_| false).await;
    assert!(
        matches!(events.as_slice(), [DictationEvent::Failed(m), DictationEvent::Ended] if m.contains("not signed in")),
        "{events:?}"
    );
}

#[tokio::test]
async fn stopping_before_the_microphone_opens_ends_quietly() {
    let dir = tempfile::tempdir().unwrap();
    let mut dictation = Dictation::start(runtime(dir.path(), ""));
    dictation.finish();
    let events = until(&mut dictation, |_| false).await;
    assert_eq!(events.last(), Some(&DictationEvent::Ended), "{events:?}");
    assert!(
        !events
            .iter()
            .any(|e| matches!(e, DictationEvent::Failed(_))),
        "{events:?}"
    );
}
