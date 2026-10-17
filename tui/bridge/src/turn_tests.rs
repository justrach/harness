use super::*;
use crate::wire::ThreadState;
use harness_proto::HarnessId;

fn thread() -> ThreadState {
    ThreadState {
        history: Default::default(),
        cwd: "/tmp".into(),
        harness: HarnessId::Graff,
        model: None,
        resume: None,
        interrupt: None,
        turn_id: None,
        steer: None,
        steers: Default::default(),
        steerable: false,
    }
}

fn conn_with(state: ThreadState) -> Arc<Conn> {
    let (conn, _rx) = Conn::for_test(Arc::new(harness_engine::HarnessRegistry::new()));
    conn.threads.lock().unwrap().insert("t1".into(), state);
    conn
}

fn steer_params(expected: &str) -> Value {
    json!({
        "threadId": "t1",
        "clientUserMessageId": "c1",
        "expectedTurnId": expected,
        "input": [{ "type": "text", "text": "also check the tests" }],
    })
}

#[test]
fn no_running_turn_tells_the_tui_to_start_one() {
    let conn = conn_with(thread());
    let (reply, _) = steer(&conn, steer_params("turn-1"));
    assert_eq!(reply.err().unwrap().message, "no active turn to steer");
}

#[test]
fn a_stale_turn_id_names_the_running_turn() {
    let (tx, _rx) = mpsc::channel(STEER_MAILBOX);
    let conn = conn_with(ThreadState {
        turn_id: Some("turn-2".into()),
        steer: Some(tx),
        steerable: true,
        ..thread()
    });
    let (reply, _) = steer(&conn, steer_params("turn-1"));
    assert_eq!(
        reply.err().unwrap().message,
        "expected active turn id `turn-1` but found `turn-2`"
    );
}

#[test]
fn an_agent_without_steering_gets_a_not_steerable_turn_error() {
    let (tx, _rx) = mpsc::channel(STEER_MAILBOX);
    let conn = conn_with(ThreadState {
        turn_id: Some("turn-1".into()),
        steer: Some(tx),
        ..thread()
    });
    let (reply, _) = steer(&conn, steer_params("turn-1"));
    let data = reply.err().unwrap().data.unwrap();
    assert_eq!(
        data["codexErrorInfo"]["activeTurnNotSteerable"]["turnKind"],
        "review"
    );
}

#[test]
fn an_accepted_steer_reaches_the_agent_and_is_echoed_when_taken() {
    let (tx, mut rx) = mpsc::channel(STEER_MAILBOX);
    let conn = conn_with(ThreadState {
        turn_id: Some("turn-1".into()),
        steer: Some(tx),
        steerable: true,
        ..thread()
    });
    let (reply, _) = steer(&conn, steer_params("turn-1"));
    assert_eq!(reply.ok().unwrap(), json!({ "turnId": "turn-1" }));
    let message = rx.try_recv().unwrap();
    assert_eq!(message.prompt, "also check the tests");
    assert_eq!(message.message_id.as_deref(), Some("c1"));

    let turn = Turn {
        conn: conn.clone(),
        thread_id: "t1".into(),
        turn_id: "turn-1".into(),
        message: None,
        reasoning: None,
        tools: HashMap::new(),
        cwd: "/tmp".into(),
    };
    // The agent's turn ends with the steer still queued: keep the Codex
    // turn open for it, and close the mailbox.
    assert!(turn.close_steering(true));
    assert!(conn.threads.lock().unwrap()["t1"].steer.is_none());
    let mut turn = turn;
    turn.on_steered();
    assert!(conn.threads.lock().unwrap()["t1"].steers.is_empty());
    assert!(!turn.close_steering(true));
}

#[test]
fn an_interrupted_turn_drops_its_queued_steers() {
    let (tx, _rx) = mpsc::channel(STEER_MAILBOX);
    let conn = conn_with(ThreadState {
        turn_id: Some("turn-1".into()),
        steer: Some(tx),
        steerable: true,
        ..thread()
    });
    let _ = steer(&conn, steer_params("turn-1"));
    let turn = Turn {
        conn: conn.clone(),
        thread_id: "t1".into(),
        turn_id: "turn-1".into(),
        message: None,
        reasoning: None,
        tools: HashMap::new(),
        cwd: "/tmp".into(),
    };
    assert!(!turn.close_steering(false));
    assert!(conn.threads.lock().unwrap()["t1"].steers.is_empty());
}
