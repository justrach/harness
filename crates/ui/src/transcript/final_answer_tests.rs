use super::*;

fn text(id: &str, body: &str) -> MessagePart {
    MessagePart::Text {
        id: id.into(),
        text: body.into(),
    }
}

fn tool() -> MessagePart {
    serde_json::from_value(serde_json::json!({
        "id": "check", "kind": "tool", "resolved": true,
        "call": {"kind": "exec", "command": "cargo test parser"}
    }))
    .unwrap()
}

fn reply() -> SessionMessageEntry {
    SessionMessageEntry {
        id: "answer".into(),
        role: MessageRole::Assistant,
        parts: vec![
            text("progress", "Checking the parser."),
            tool(),
            text("final", "The parser change is ready.\n\nAll 24 tests pass."),
            text("tail", "No blocking findings."),
        ],
        created_at: 1,
        device_id: "fixture".into(),
        status: Some(MessageStatus::Complete),
        continuation_of: None,
        duration_ms: Some(94_000),
    }
}

fn rows(entry: &SessionMessageEntry, compact: bool) -> Vec<Row> {
    rows_for_entry(entry, false, compact, &mut |_, body| {
        Arc::new(parse_full(body))
    })
}

#[test]
fn final_answer_marks_only_the_first_block_of_the_trailing_reply() {
    let entry = reply();
    let complete = rows(&entry, false);
    let marked: Vec<_> = complete
        .iter()
        .filter(|row| row.final_answer.is_some())
        .collect();
    assert_eq!(marked.len(), 1);
    assert_eq!(marked[0].id.as_ref(), "answer#final.0");
    assert_eq!(
        marked[0].final_answer.as_ref().unwrap().worked_secs,
        Some(94)
    );
    assert!(marked[0].final_answer.as_ref().unwrap().show_label);
    let mut live = entry.clone();
    live.status = Some(MessageStatus::Streaming);
    let streaming = rows(&live, false);
    assert!(streaming.iter().all(|row| row.final_answer.is_none()));
    assert_eq!(
        streaming.iter().map(|r| &r.id).collect::<Vec<_>>(),
        complete.iter().map(|r| &r.id).collect::<Vec<_>>(),
        "completion preserves virtualized row identities"
    );
}

#[test]
fn final_answer_requires_a_completed_answer_not_a_progress_tail() {
    let mut entry = reply();
    for status in [
        None,
        Some(MessageStatus::Streaming),
        Some(MessageStatus::Aborted),
    ] {
        entry.status = status;
        assert!(
            rows(&entry, false)
                .iter()
                .all(|row| row.final_answer.is_none())
        );
    }
    entry = reply();
    entry.parts.push(tool());
    assert!(
        rows(&entry, false)
            .iter()
            .all(|row| row.final_answer.is_none())
    );
    entry = reply();
    entry.parts.push(MessagePart::Error {
        id: "error".into(),
        message: "Request failed".into(),
        reauth: None,
    });
    assert!(
        rows(&entry, false)
            .iter()
            .all(|row| row.final_answer.is_none())
    );
    entry = reply();
    entry.parts.push(MessagePart::Input {
        id: "input".into(),
        request_id: "question".into(),
        questions: vec![],
        resolved: false,
    });
    assert!(
        rows(&entry, false)
            .iter()
            .all(|row| row.final_answer.is_none())
    );
    entry = reply();
    if let MessagePart::Tool {
        subagent_status, ..
    } = &mut entry.parts[1]
    {
        *subagent_status = Some(SubagentStatus::Running);
    }
    assert!(
        rows(&entry, false)
            .iter()
            .all(|row| row.final_answer.is_none())
    );
    entry = reply();
    if let MessagePart::Tool { resolved, .. } = &mut entry.parts[1] {
        *resolved = false;
    }
    assert!(
        rows(&entry, false)
            .iter()
            .all(|row| row.final_answer.is_none())
    );
    entry = reply();
    entry.role = MessageRole::User;
    assert!(
        rows(&entry, false)
            .iter()
            .all(|row| row.final_answer.is_none())
    );
}

#[test]
fn final_answer_keeps_media_and_uses_only_recorded_time() {
    let mut entry = reply();
    entry.parts.push(MessagePart::Image {
        id: "image".into(),
        path: "figure.png".into(),
        name: "Figure".into(),
        mime_type: "image/png".into(),
    });
    entry.parts.push(text("empty", " \n"));
    for duration in [None, Some(0), Some(-1)] {
        entry.duration_ms = duration;
        let rows = rows(&entry, false);
        let marker = rows.iter().find_map(|r| r.final_answer.as_ref()).unwrap();
        assert_eq!(
            marker.worked_secs, None,
            "do not guess an elapsed duration from history"
        );
        assert!(
            rows.iter()
                .any(|r| matches!(r.kind, RowKind::GeneratedImage { .. }))
        );
    }
}

#[test]
fn final_answer_keeps_compact_history_accessible_without_a_duplicate_label() {
    let entry = reply();
    let rows = rows(&entry, true);
    let markers: Vec<_> = rows.iter().filter(|r| r.final_answer.is_some()).collect();
    assert_eq!(
        markers.len(),
        1,
        "nested work must not acquire its own final-answer decoration"
    );
    assert!(markers[0].compact_fold.is_none());
    assert!(!markers[0].final_answer.as_ref().unwrap().show_label);
    let detailed = self::rows(&entry, false);
    for (from, to) in [(&detailed, &rows), (&rows, &detailed)] {
        let answer_ix = from.iter().position(|r| r.final_answer.is_some()).unwrap();
        let (changed, _) = diff_rows(from, to).unwrap();
        assert!(
            changed.contains(&answer_ix),
            "switching Compact mode must remeasure the changed answer heading"
        );
    }
    assert!(rows.iter().any(|r| r.compact_fold.is_some()));
    assert!(rows.iter().any(|r| matches!(
        r.kind,
        RowKind::ToolGroup {
            compact_shell: true,
            ..
        }
    )));
    let only_text = SessionMessageEntry {
        parts: vec![text("final", "Ready.")],
        ..entry
    };
    assert!(
        self::rows(&only_text, true)[0]
            .final_answer
            .as_ref()
            .unwrap()
            .show_label
    );
}

#[test]
fn final_answer_duration_changes_invalidate_the_prepared_row() {
    let mut entry = reply();
    let mut preparation = TranscriptPreparation::default();
    let mut prepare = |entry: &SessionMessageEntry| {
        preparation
            .prepare(&harness_doc::TranscriptUpdate {
                frame: harness_doc::TranscriptFrame::reset(std::slice::from_ref(entry)),
                context_usage: None,
                replay_baseline: None,
            })
            .unwrap()
            .rows[&entry.id]
            .iter()
            .find(|r| r.final_answer.is_some())
            .unwrap()
            .clone()
    };
    let first = prepare(&entry);
    entry.duration_ms = Some(140_000);
    let second = prepare(&entry);
    assert_eq!(first.id, second.id);
    assert_ne!(first.version, second.version);
    assert_eq!(second.final_answer.unwrap().worked_secs, Some(140));
}

#[gpui::test]
fn final_answer_heading_appears_only_after_completion(cx: &mut gpui::TestAppContext) {
    struct Host(Entity<Transcript>);
    impl Render for Host {
        fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
            div().size_full().child(self.0.clone())
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        cx.new(|_| AppState::new())
    });
    state.update(cx, |state, cx| {
        state.select_chat(Some("fixture".into()), cx)
    });
    let (_, cx) = cx.add_window_view(|_, cx| Host(cx.new(|cx| Transcript::new(state.clone(), cx))));
    cx.simulate_resize(size(px(700.), px(800.)));
    let mut preparation = TranscriptPreparation::default();
    for complete in [false, true, false] {
        let mut entry = reply();
        entry.status = Some(if complete {
            MessageStatus::Complete
        } else {
            MessageStatus::Streaming
        });
        let update = harness_doc::TranscriptUpdate {
            frame: harness_doc::TranscriptFrame::reset(&[entry]),
            context_usage: None,
            replay_baseline: None,
        };
        let prepared = preparation.prepare(&update).unwrap();
        state.update(cx, |state, cx| {
            state
                .receive_opening_transcript_update(update, false, cx)
                .unwrap();
            state
                .prepared_transcripts
                .insert("fixture".into(), prepared);
        });
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
        cx.run_until_parked();
        cx.update(|window, cx| {
            window.refresh();
            window.draw(cx).clear();
        });
        assert_eq!(
            cx.debug_bounds("transcript-final-answer-heading").is_some(),
            complete
        );
    }
}
