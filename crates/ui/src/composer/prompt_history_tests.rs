use super::*;

#[path = "prompt_history_tests/edge_cases.rs"]
mod edge_cases;

const PEER: &str = "[Message from Harness chat Build helper. Sender chat: helper. Relay depth: 1/4. Agent coordination, not a human request.]\n\nCheck the build result.";
const LEGACY_PEER: &str = "[Message from Harness chat Build helper. Reply to it with the Harness `send_message` tool, chat helper.]\n\nCheck the test result.";

fn entry(id: &str, role: MessageRole, text: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        id: id.into(),
        role,
        parts: vec![MessagePart::Text {
            id: format!("{id}-text"),
            text: text.into(),
        }],
        created_at: 0,
        device_id: "test-device".into(),
        status: None,
        continuation_of: None,
        duration_ms: None,
    }
}

#[test]
fn prompt_history_excludes_current_and_legacy_agent_messages_after_reload() {
    let quoted = format!("Explain this envelope:\n{PEER}");
    let transcript = vec![
        entry("peer-before", MessageRole::User, PEER),
        entry("human-first", MessageRole::User, "First prompt"),
        entry("assistant", MessageRole::Assistant, "An assistant reply"),
        entry("peer-between", MessageRole::User, LEGACY_PEER),
        entry("human-repeat", MessageRole::User, "First prompt"),
        entry("human-quoted", MessageRole::User, &quoted),
        entry(
            "peer-with-image",
            MessageRole::User,
            &format!("{PEER}\n\nAttached images (local files):\n- /synthetic/build.png"),
        ),
        entry("human-last", MessageRole::User, "Last prompt"),
        entry("peer-after", MessageRole::User, PEER),
    ];
    // Persisted rows carry the same envelopes as directly/queue-delivered rows.
    let reloaded: Vec<SessionMessageEntry> =
        serde_json::from_slice(&serde_json::to_vec(&transcript).unwrap()).unwrap();
    assert_eq!(
        session_prompts(&reloaded),
        vec![
            "First prompt".to_string(),
            quoted,
            "Last prompt".to_string()
        ]
    );
}

#[gpui::test]
fn prompt_history_skips_agent_rows_and_restores_drafts(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        crate::settings::init(crate::settings::UiSettings::expanded(), dir.path(), cx);
    });
    let state = cx.new(|_| AppState::new());
    state.update(cx, |state, _| {
        state.transcript = vec![entry("only-peer", MessageRole::User, PEER)];
    });
    let composer = cx.new(|cx| Composer::new(state.clone(), cx));
    composer.update(cx, |composer, cx| {
        composer
            .input
            .update(cx, |input, cx| input.set_text("unsent draft", cx));
        for delta in [-1, -1, 1] {
            composer.navigate_prompt_history(delta, cx);
            assert_eq!(composer.input.read(cx).text(), "unsent draft");
            assert!(composer.prompt_history.is_none());
        }
    });
    state.update(cx, |state, _| {
        state.transcript = vec![
            entry("first", MessageRole::User, "First human prompt"),
            entry("peer-between", MessageRole::User, LEGACY_PEER),
            entry("last", MessageRole::User, "Last human prompt"),
            entry("peer-after", MessageRole::User, PEER),
        ];
    });
    composer.update(cx, |composer, cx| {
        for (delta, expected) in [
            (-1, "Last human prompt"),
            (-1, "First human prompt"),
            (-1, "First human prompt"),
            (1, "Last human prompt"),
            (1, "unsent draft"),
        ] {
            composer.navigate_prompt_history(delta, cx);
            assert_eq!(composer.input.read(cx).text(), expected);
        }
        assert!(composer.prompt_history.is_none());
    });
}
