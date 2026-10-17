//! A send made with the edge unreachable is a durable local write: the commands and queue rows sit in the chat's
//! outbox, in the shape the host drains, and survive a restart until the room takes them.

use std::collections::HashMap;
use std::sync::Arc;

use harness_doc::{SessionCommandPayload, SessionDoc};
use harness_mobile::records::{SessionSnapshot, UserInputAnswerRecord, WorkspaceSnapshot};
use harness_mobile::{CoreConfig, CoreListener, MobileCore, NewChatConfig, TokenSource};

struct Bearer;
impl TokenSource for Bearer {
    fn bearer(&self) -> Option<String> {
        Some("u1@org1".into())
    }
}

struct Quiet;
impl CoreListener for Quiet {
    fn workspace_changed(&self, _: WorkspaceSnapshot) {}
    fn session_changed(&self, _: SessionSnapshot) {}
    fn connectivity_changed(&self, _: harness_mobile::ConnectivitySnapshot) {}
}

fn open_core(data: &std::path::Path) -> Arc<MobileCore> {
    MobileCore::new(
        CoreConfig {
            // Nothing listens here: every dial fails.
            edge_url: "http://127.0.0.1:9".into(),
            org_id: "org1".into(),
            user_id: "u1".into(),
            device_id: "android-test".into(),
            data_dir: data.to_string_lossy().into_owned(),
        },
        Arc::new(Bearer),
        Arc::new(Quiet),
    )
    .unwrap()
}

/// What the host would see: the outbox's batches imported into an empty doc.
fn outbox(data: &std::path::Path, chat_id: &str) -> SessionDoc {
    let store = harness_sync::DocsStore::open(data).unwrap();
    let doc = loro::LoroDoc::new();
    for (_, bytes) in store.pending_chat_updates(chat_id).unwrap() {
        doc.import(&bytes).unwrap();
    }
    SessionDoc::from_doc(doc)
}

#[test]
fn sends_made_offline_wait_in_the_outbox_across_a_restart() {
    let data = tempfile::tempdir().unwrap();
    let core = open_core(data.path());
    core.start();
    let chat_id = core.create_chat(
        "mac-host".into(),
        None,
        "/repo".into(),
        NewChatConfig {
            harness: "graff".into(),
            model: Some("m1".into()),
            reasoning: Some("high".into()),
            model_options: HashMap::from([("serviceTier".into(), "fast".into())]),
            sandbox: None,
        },
        None,
    );

    let message_id = core.send_run(chat_id.clone(), "Port it".into(), vec![]);
    let steer_id = core.send_steer(chat_id.clone(), "Also the tests".into());
    core.respond_input(
        chat_id.clone(),
        "req-1".into(),
        vec![UserInputAnswerRecord {
            question_id: "q1".into(),
            labels: vec!["Yes".into()],
        }],
    );
    core.interrupt(chat_id.clone());
    let first = core
        .enqueue_message(chat_id.clone(), "next".into(), vec![], true)
        .unwrap();
    let second = core
        .enqueue_message(chat_id.clone(), "after that".into(), vec![], false)
        .unwrap();
    assert!(
        core.enqueue_message(chat_id.clone(), "  ".into(), vec![], true)
            .is_none()
    );
    assert!(core.move_queued(chat_id.clone(), second.clone(), 0));
    assert!(
        !core.move_queued(chat_id.clone(), second.clone(), 0),
        "already there"
    );

    // The phone's own copy shows the queue at once.
    let snapshot = core.open_session(chat_id.clone());
    assert_eq!(
        snapshot
            .queue
            .iter()
            .map(|row| row.id.clone())
            .collect::<Vec<_>>(),
        [second.clone(), first.clone()]
    );
    core.stop();
    drop(core);

    let sent = outbox(data.path(), &chat_id);
    let commands = sent.read_commands().unwrap();
    assert_eq!(commands.len(), 4);
    assert!(commands.iter().all(|c| c.issued_by == "android-test"));
    let SessionCommandPayload::Run {
        request,
        message_id: run_id,
    } = &commands[0].payload
    else {
        panic!("a run first: {:?}", commands[0].payload)
    };
    assert_eq!(run_id, &message_id);
    assert_eq!(request.prompt, "Port it");
    assert_eq!(request.cwd, "/repo");
    assert_eq!(request.harness, Some(harness_proto::HarnessId::Graff));
    assert_eq!(request.model.as_deref(), Some("m1"));
    assert_eq!(request.reasoning, Some(harness_proto::ReasoningLevel::High));
    assert_eq!(request.model_options["serviceTier"], "fast");
    assert!(matches!(
        &commands[1].payload,
        SessionCommandPayload::Steer { prompt, message_id: Some(id) } if prompt == "Also the tests" && id == &steer_id
    ));
    assert!(matches!(
        &commands[2].payload,
        SessionCommandPayload::RespondInput { request_id, answers }
            if request_id == "req-1" && answers[0].labels == ["Yes"]
    ));
    assert!(matches!(
        commands[3].payload,
        SessionCommandPayload::Interrupt {}
    ));
    let queue = sent.read_queue().unwrap();
    assert_eq!(
        queue
            .iter()
            .map(|row| (row.id.as_str(), row.hold_for_turn_end))
            .collect::<Vec<_>>(),
        [(second.as_str(), false), (first.as_str(), true)]
    );

    // A restart keeps both the local copy and the unsent batches.
    let again = open_core(data.path());
    again.start();
    let reopened = again.open_session(chat_id.clone());
    assert_eq!(reopened.queue.len(), 2);
    assert!(again.remove_queued(chat_id.clone(), first.clone()));
    again.stop();
    drop(again);
    assert_eq!(
        outbox(data.path(), &chat_id).read_commands().unwrap().len(),
        4
    );
    assert_eq!(outbox(data.path(), &chat_id).read_queue().unwrap().len(), 1);
}
