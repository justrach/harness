use super::*;

fn assistant_entry(
    id: &str,
    status: MessageStatus,
    parts: Vec<MessagePart>,
) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role: MessageRole::Assistant,
        parts,
        created_at: 0,
        device_id: "dev".into(),
        status: Some(status),
        continuation_of: None,
        duration_ms: None,
    }
}

fn text(id: &str, value: &str) -> MessagePart {
    MessagePart::Text {
        id: id.into(),
        text: value.into(),
    }
}

fn tool(id: &str) -> MessagePart {
    MessagePart::Tool {
        id: id.into(),
        call: ToolCall::Exec {
            command: "ls".into(),
        },
        is_error: false,
        resolved: true,
        output: None,
        diff: None,
        output_ref: None,
        output_bytes: None,
        diff_ref: None,
        diff_stats: None,
        subagent_ref: None,
        subagent_status: None,
        subagent_tail: None,
        view: None,
    }
}

#[gpui::test]
fn steer_echo_sits_after_tool_and_confirms_once_before_continuation(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        cx.new(|_| AppState::new())
    });
    let transcript = cx.new(|cx| Transcript::new(state.clone(), cx));

    let prior = assistant_entry("tool-turn", MessageStatus::Complete, vec![tool("call")]);
    let mut echoed_prompt = assistant_entry(
        "steer-prompt",
        MessageStatus::Complete,
        vec![text("prompt-text", "Check this result.")],
    );
    echoed_prompt.role = MessageRole::User;
    echoed_prompt.status = None;

    state.update(cx, |state, _| {
        state.selected_chat = Some("chat".into());
        state.transcript_replayed = true;
        state.transcript = vec![prior.clone()];
        state.push_echo("chat", echoed_prompt.clone());
    });
    transcript.update(cx, |this, cx| this.sync(cx));

    let (pending_rows, pending_id) = transcript.read_with(cx, |this, _| {
        assert_eq!(this.rows.len(), 2);
        assert!(matches!(this.rows[0].kind, RowKind::ToolGroup { .. }));
        let RowKind::User { pending: true, .. } = this.rows[1].kind else {
            panic!("steer echo must follow the latest tool result as a pending user row");
        };
        (this.rows.len(), this.rows[1].id.clone())
    });
    assert_eq!(pending_rows, 2);

    let mut confirmed_prompt = echoed_prompt.clone();
    confirmed_prompt.status = None;
    state.update(cx, |state, _| {
        state.remove_echo("chat", "steer-prompt");
        state.transcript = vec![prior.clone(), confirmed_prompt];
        state.transcript_revision += 1;
    });
    transcript.update(cx, |this, cx| this.sync(cx));

    transcript.read_with(cx, |this, _| {
        assert_eq!(this.rows.len(), 2, "confirmation must leave one prompt row");
        assert!(matches!(this.rows[0].kind, RowKind::ToolGroup { .. }));
        let RowKind::User { pending: false, .. } = this.rows[1].kind else {
            panic!("confirmed prompt must be rendered as an ordinary user row");
        };
        assert_eq!(
            this.rows[1].id, pending_id,
            "confirmation keeps row identity"
        );
    });

    let continuation = assistant_entry(
        "continued-answer",
        MessageStatus::Streaming,
        vec![text("answer-text", "Continuing below the prompt.")],
    );
    state.update(cx, |state, _| {
        state.transcript.push(continuation);
        state.transcript_revision += 1;
    });
    transcript.update(cx, |this, cx| this.sync(cx));
    transcript.read_with(cx, |this, _| {
        assert_eq!(this.rows.len(), 3);
        assert!(matches!(this.rows[0].kind, RowKind::ToolGroup { .. }));
        assert!(matches!(
            this.rows[1].kind,
            RowKind::User { pending: false, .. }
        ));
        assert!(matches!(
            this.rows[2].kind,
            RowKind::Markdown { .. } | RowKind::LiveMarkdown { .. }
        ));
        assert_eq!(
            this.rows[1].id, pending_id,
            "continuation does not move the prompt row"
        );
    });
}

#[gpui::test]
fn ordinary_transcript_without_echo_does_not_invent_a_pending_user_row(
    cx: &mut gpui::TestAppContext,
) {
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        cx.new(|_| AppState::new())
    });
    let transcript = cx.new(|cx| Transcript::new(state.clone(), cx));
    let mut ordinary_user = assistant_entry(
        "ordinary-user",
        MessageStatus::Complete,
        vec![text("ordinary-text", "A normal queued prompt.")],
    );
    ordinary_user.role = MessageRole::User;
    ordinary_user.status = None;
    let answer = assistant_entry(
        "ordinary-answer",
        MessageStatus::Complete,
        vec![text("answer-text", "Done.")],
    );
    state.update(cx, |state, _| {
        state.selected_chat = Some("chat".into());
        state.transcript_replayed = true;
        state.transcript = vec![ordinary_user, answer];
    });
    transcript.update(cx, |this, cx| this.sync(cx));

    transcript.read_with(cx, |this, _| {
        assert_eq!(this.rows.len(), 2);
        assert!(matches!(
            this.rows[0].kind,
            RowKind::User { pending: false, .. }
        ));
        assert!(matches!(this.rows[1].kind, RowKind::Markdown { .. }));
        assert!(
            this.rows
                .iter()
                .all(|row| !matches!(row.kind, RowKind::User { pending: true, .. }))
        );
    });
}
