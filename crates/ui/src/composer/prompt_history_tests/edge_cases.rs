use super::*;

#[path = "sequences.rs"]
mod sequences;

#[path = "interruptions.rs"]
mod interruptions;

fn composer_with_history(
    cx: &mut gpui::TestAppContext,
) -> (
    tempfile::TempDir,
    Entity<AppState>,
    gpui::WindowHandle<Composer>,
) {
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
        state.selected_chat = Some("history-chat".into());
        state.transcript = vec![
            entry("first", MessageRole::User, "First prompt"),
            entry("last", MessageRole::User, "Last prompt"),
        ];
    });
    let window = cx.add_window(|_, cx| Composer::new(state.clone(), cx));
    window
        .update(cx, |composer, _, cx| {
            composer
                .input
                .update(cx, |input, cx| input.set_text("unsent draft", cx));
        })
        .unwrap();
    (dir, state, window)
}

#[test]
fn prompt_history_excludes_tagged_room_deliveries() {
    use harness_proto::room_delivery::{self, RoomOrigin};
    for external in [false, true] {
        let room = room_delivery::format(
            &RoomOrigin {
                room_id: "room-test".into(),
                room_name: "build".into(),
                seq: 1,
                from_member: "helper".into(),
                member_kind: "graff".into(),
                from_user: false,
                framed: false,
                external,
                from_display: None,
                from_github: None,
                from_fingerprint: None,
            },
            "Check the build result.",
        );
        let quoted = format!("Explain this room message:\n{room}");
        assert_eq!(
            session_prompts(&[
                entry("room", MessageRole::User, &room),
                entry("human", MessageRole::User, &quoted),
            ]),
            vec![quoted],
            "room mail is not a human prompt, but a human quoting it is"
        );
    }
}

#[gpui::test]
fn prompt_history_live_append_does_not_shift_the_recalled_cursor(cx: &mut gpui::TestAppContext) {
    let (_dir, state, window) = composer_with_history(cx);
    window
        .update(cx, |composer, _, cx| {
            composer.navigate_prompt_history(-1, cx);
            assert_eq!(composer.input.read(cx).text(), "Last prompt");
        })
        .unwrap();
    state.update(cx, |state, _| {
        state
            .transcript
            .push(entry("new", MessageRole::User, "New remote prompt"));
    });
    window
        .update(cx, |composer, _, cx| {
            for (delta, expected) in [
                (-1, "First prompt"),
                (1, "Last prompt"),
                (1, "unsent draft"),
                (-1, "New remote prompt"),
            ] {
                composer.navigate_prompt_history(delta, cx);
                assert_eq!(composer.input.read(cx).text(), expected);
            }
        })
        .unwrap();
}

#[gpui::test]
fn prompt_history_live_clear_does_not_panic_or_lose_the_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, state, window) = composer_with_history(cx);
    window
        .update(cx, |composer, _, cx| {
            composer.navigate_prompt_history(-1, cx);
            composer.navigate_prompt_history(-1, cx);
        })
        .unwrap();
    state.update(cx, |state, _| state.transcript.clear());
    window
        .update(cx, |composer, _, cx| {
            // Finish the browsing snapshot even if a replay replaces the live tail.
            composer.navigate_prompt_history(1, cx);
            assert_eq!(composer.input.read(cx).text(), "Last prompt");
            composer.navigate_prompt_history(1, cx);
            assert_eq!(composer.input.read(cx).text(), "unsent draft");
            composer.navigate_prompt_history(-1, cx);
            assert_eq!(composer.input.read(cx).text(), "unsent draft");
        })
        .unwrap();
}

#[gpui::test]
fn prompt_history_editing_a_recall_starts_a_new_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, _state, window) = composer_with_history(cx);
    window
        .update(cx, |composer, window, cx| {
            composer.navigate_prompt_history(-1, cx);
            composer.input.update(cx, |input, cx| {
                input.replace_text_in_range(None, " edited", window, cx);
            });
            assert_eq!(composer.input.read(cx).text(), "Last prompt edited");
            composer.navigate_prompt_history(-1, cx);
            assert_eq!(composer.input.read(cx).text(), "Last prompt");
            composer.navigate_prompt_history(1, cx);
            assert_eq!(composer.input.read(cx).text(), "Last prompt edited");
        })
        .unwrap();
}

#[gpui::test]
fn prompt_history_chat_switch_restores_each_chats_own_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, state, window) = composer_with_history(cx);
    window
        .update(cx, |composer, _, cx| {
            composer.navigate_prompt_history(-1, cx)
        })
        .unwrap();
    state.update(cx, |state, _| {
        state.selected_chat = Some("other-chat".into());
        state.transcript = vec![entry("other", MessageRole::User, "Other chat prompt")];
    });
    window
        .update(cx, |composer, _, cx| {
            composer.on_state_changed(cx);
            assert!(composer.input.read(cx).text().is_empty());
            composer.navigate_prompt_history(-1, cx);
            assert_eq!(composer.input.read(cx).text(), "Other chat prompt");
            composer.navigate_prompt_history(1, cx);
            assert!(composer.input.read(cx).text().is_empty());
        })
        .unwrap();
    state.update(cx, |state, _| {
        state.selected_chat = Some("history-chat".into());
        state.transcript = vec![entry("last", MessageRole::User, "Last prompt")];
    });
    window
        .update(cx, |composer, _, cx| {
            composer.on_state_changed(cx);
            assert_eq!(composer.input.read(cx).text(), "unsent draft");
        })
        .unwrap();
}

#[test]
fn prompt_history_excludes_legacy_deliveries_from_multiline_sender_titles() {
    for title in ["Build\nhelper", "Build\rhelper", "Build\r\nhelper"] {
        for template in [PEER, LEGACY_PEER] {
            let peer = template.replacen("Build helper", title, 1);
            assert!(
                session_prompts(&[entry("peer", MessageRole::User, &peer)]).is_empty(),
                "persisted multiline sender title: {title:?}"
            );
        }
    }
}

#[test]
fn prompt_history_keeps_unicode_whitespace_and_malformed_or_quoted_headers() {
    let prompts = [
        "  café 🧪\n第二行  ",
        "[Message from Harness chat Missing envelope terminator",
        "[Message from Harness chat Unknown]\n\nOrdinary text",
        "<!--harness-room {not json} -->\nOrdinary text",
        "```text\n[Message from Harness chat helper. Sender chat: helper. Agent coordination, not a human request.]\n\nQuoted\n```",
    ];
    let entries: Vec<_> = prompts
        .iter()
        .enumerate()
        .map(|(i, text)| entry(&i.to_string(), MessageRole::User, text))
        .collect();
    assert_eq!(session_prompts(&entries), prompts);
}
