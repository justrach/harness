//! Synthetic wire and recovery edges for explicit Graff command intent.
use super::*;
use harness_proto::invocation::{Invocation, SkillCommand, harness_prompt};
use serde_json::{Value, json};

async fn recorded_prompts(
    harness: AcpHarness,
    prompts: &[String],
) -> (Vec<Value>, Vec<AgentEvent>) {
    let workspace = tempfile::tempdir().unwrap();
    let path = workspace.path().join("acp-requests.jsonl");
    std::fs::write(&path, "").unwrap();
    let (ctl, sender, _) = controls();
    let mut sender = Some(sender);
    let mut req = request(&harness_prompt(&prompts[0], harness.id()));
    req.cwd = workspace.path().display().to_string();
    req.model = None;
    if prompts.len() == 1 {
        sender.take();
    }
    let mut stream = harness.run(req, ctl).await.unwrap();
    let events = tokio::time::timeout(Duration::from_secs(10), async {
        let mut events = Vec::new();
        let mut completed = 0;
        while let Some(event) = stream.next().await {
            let event = event.unwrap();
            if let AgentEvent::Done { status, .. } = &event {
                assert_eq!(*status, DoneStatus::Completed, "{events:?} {event:?}");
                completed += 1;
                if let Some(next) = prompts.get(completed) {
                    sender
                        .as_ref()
                        .unwrap()
                        .send(SteerMessage {
                            prompt: harness_prompt(next, harness.id()),
                            message_id: Some(format!("synthetic-{completed}")),
                            attachments: Vec::new(),
                        })
                        .await
                        .unwrap();
                } else {
                    sender.take();
                }
            }
            events.push(event);
        }
        assert_eq!(completed, prompts.len(), "{events:?}");
        events
    })
    .await
    .expect("synthetic prompt sequence finished");
    let requests: Vec<Value> = std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let prompts = requests
        .into_iter()
        .filter(|req| req["method"] == "session/prompt")
        .map(|req| req["params"].clone())
        .collect();
    (prompts, events)
}

#[tokio::test]
async fn graff_wire_preserves_markdown_utf8_and_per_turn_intent() {
    let command = Invocation::Command {
        name: "help".into(),
    }
    .link();
    let skill = Invocation::Skill {
        name: "inspect".into(),
        path: "harness-skill:inspect".into(),
        command: Some(SkillCommand {
            name: "review".into(),
            harness: HarnessId::Graff,
        }),
    }
    .link();
    let cases = [
        (
            format!("{command} synthetic"),
            "/help synthetic".into(),
            true,
        ),
        ("/help".into(), "/help".into(), false),
        (format!("{skill} λ 🦀"), "/review λ 🦀".into(), true),
        (format!("{command}ful"), "/helpful".into(), false),
        (format!("{skill}er"), "/reviewer".into(), false),
        (format!("Discuss {command}"), "Discuss /help".into(), false),
        (format!("`{command}`"), format!("`{command}`"), false),
        (
            format!("```text\n{command}\n```"),
            format!("```text\n{command}\n```"),
            false,
        ),
        (
            "/goal is ordinary prose\r\nsecond line".into(),
            "/goal is ordinary prose\r\nsecond line".into(),
            false,
        ),
        ("\u{a0}/help 🦀".into(), "\u{a0}/help 🦀".into(), false),
        (
            "[/help](harness-invoke:bad)".into(),
            "[/help](harness-invoke:bad)".into(),
            false,
        ),
    ];
    let input: Vec<String> = cases.iter().map(|(raw, _, _)| raw.clone()).collect();
    let (wire, _) = recorded_prompts(lifecycle_fixture_for(AcpHarness::graff()), &input).await;
    assert_eq!(wire.len(), cases.len());
    for (params, (raw, expected, selected)) in wire.iter().zip(&cases) {
        assert_eq!(
            params["prompt"],
            json!([{ "type": "text", "text": expected }]),
            "{raw}"
        );
        assert_eq!(params["_meta"]["harness/command"], *selected, "{raw}");
    }
}

#[tokio::test]
async fn room_deliveries_never_gain_selected_command_intent() {
    let selected = Invocation::Command {
        name: "help".into(),
    }
    .link();
    for framed in [false, true] {
        let origin = json!({
            "room_id": "synthetic-room", "room_name": "synthetic",
            "seq": 1, "from_member": "fixture-agent", "member_kind": "graff",
            "from_user": false, "framed": framed,
        });
        let raw = format!("<!--harness-room {origin} -->\n{selected}");
        let (wire, _) = recorded_prompts(lifecycle_fixture_for(AcpHarness::graff()), &[raw]).await;
        assert_eq!(wire.len(), 1);
        assert_eq!(wire[0]["prompt"][0]["text"], "/help");
        assert_eq!(wire[0]["_meta"]["harness/room"]["framed"], framed);
        assert_eq!(wire[0]["_meta"]["harness/room"]["from_user"], false);
        assert_eq!(
            wire[0]["_meta"]["harness/command"], false,
            "advisory room text is not a user's completion acceptance"
        );
    }
}

#[tokio::test]
async fn repeated_failed_graff_restores_keep_the_reference_and_can_later_resume() {
    let workspace = tempfile::tempdir().unwrap();
    let path = workspace.path().join("acp-requests.jsonl");
    std::fs::write(&path, "").unwrap();
    let harness = lifecycle_fixture_for(AcpHarness::graff());
    for _ in 0..3 {
        let (ctl, sender, _) = controls();
        drop(sender);
        let mut req = request("synthetic retry");
        req.cwd = workspace.path().display().to_string();
        req.model = None;
        req.resume = Some("missing".into());
        let events = run_to_end(&harness, req, ctl).await;
        assert_eq!(dones(&events).len(), 1);
        assert_eq!(dones(&events)[0].0, DoneStatus::Errored);
        assert!(!events.iter().any(|e| matches!(
            e,
            AgentEvent::SessionStarted { .. }
                | AgentEvent::TextDelta { .. }
                | AgentEvent::Done {
                    session_id: Some(_),
                    ..
                }
        )));
    }
    let requests: Vec<Value> = std::fs::read_to_string(&path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(requests.len(), 3);
    assert!(
        requests
            .iter()
            .all(|r| r["method"] == "session/load" && r["params"]["sessionId"] == "missing")
    );
    let (ctl, sender, _) = controls();
    drop(sender);
    let mut req = request("require-resume");
    req.cwd = workspace.path().display().to_string();
    req.model = None;
    req.resume = Some("pi-session".into());
    let events = run_to_end(&harness, req, ctl).await;
    assert_eq!(dones(&events), vec![(DoneStatus::Completed, None)]);
    assert!(events.contains(&AgentEvent::TextDelta {
        text: "reply:require-resume".into()
    }));
    let requests: Vec<Value> = std::fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        requests
            .iter()
            .filter(|r| r["method"] == "session/new")
            .count(),
        0
    );
    assert_eq!(
        requests
            .iter()
            .filter(|r| r["method"] == "session/prompt")
            .count(),
        1
    );
}

#[tokio::test]
async fn non_graff_wire_does_not_receive_graff_command_metadata() {
    let (wire, _) = recorded_prompts(lifecycle_fixture(), &["/help ordinary prose".into()]).await;
    assert_eq!(wire.len(), 1);
    assert!(wire[0].pointer("/_meta/harness~1command").is_none());
    assert_eq!(wire[0]["prompt"][0]["text"], "/help ordinary prose");
}
