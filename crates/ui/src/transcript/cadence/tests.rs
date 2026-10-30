use super::*;

fn assert_update(view: &Transcript, n: usize) {
    let paragraphs: Vec<String> =
        view.rows
            .iter()
            .filter_map(|row| match &row.kind {
                RowKind::LiveMarkdown { tree, block_ix, .. }
                | RowKind::Markdown { tree, block_ix } => match &tree.blocks[*block_ix].block {
                    Block::Paragraph { runs } => {
                        Some(runs.iter().map(|run| run.text.as_str()).collect())
                    }
                    _ => None,
                },
                _ => None,
            })
            .collect();
    assert_eq!(paragraphs, vec![format!("Update {n}")]);
}

struct Panes(Entity<Transcript>, Entity<Transcript>);
impl Render for Panes {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .children([&self.0, &self.1].map(|view| {
                div().w(px(400.0)).h_full().child(
                    view.clone()
                        .cached(gpui::StyleRefinement::default().size_full()),
                )
            }))
    }
}

fn reply(n: usize) -> SessionMessageEntry {
    SessionMessageEntry {
        id: "reply".into(),
        role: MessageRole::Assistant,
        parts: vec![MessagePart::Text {
            id: "text".into(),
            text: format!("Update {n}"),
        }],
        created_at: 0,
        device_id: "test".into(),
        status: Some(MessageStatus::Streaming),
        continuation_of: None,
        duration_ms: None,
    }
}

fn draw(cx: &mut gpui::VisualTestContext) {
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.simulate_next_frame(cx);
        // Do not refresh the whole window: that deliberately invalidates the
        // cached views whose scheduling this regression measures.
        let _ = window.draw(cx);
    });
    cx.run_until_parked();
}

fn with_panes(
    cx: &mut gpui::TestAppContext,
    run: impl FnOnce(
        Entity<AppState>,
        Entity<Transcript>,
        Entity<Transcript>,
        &mut gpui::VisualTestContext,
    ),
) {
    let _selection = crate::markdown::selection::test_state_lock();
    let dir = tempfile::tempdir().unwrap();
    let state = cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::dark());
        crate::settings::init(crate::settings::UiSettings::default(), dir.path(), cx);
        motion::set_reduced_motion(cx, true);
        cx.new(|_| {
            let mut state = AppState::new();
            state.selected_chat = Some("focused".into());
            state.transcript_replayed = true;
            state.transcript = vec![reply(0)];
            state.set_subagent_snapshot("peer".into(), vec![reply(0)]);
            state
        })
    });
    let (panes, cx) = cx.add_window_view(|_, cx| {
        Panes(
            cx.new(|cx| Transcript::new(state.clone(), cx)),
            cx.new(|cx| Transcript::for_peer_chat(state.clone(), "peer".into(), cx)),
        )
    });
    cx.simulate_resize(size(px(800.0), px(600.0)));
    draw(cx);
    let (focused, peer) = panes.read_with(cx, |p, _| (p.0.clone(), p.1.clone()));
    run(state, focused, peer, cx);
    cx.update(|window, _| window.remove_window());
    drop(panes);
    cx.run_until_parked();
}

fn deliver(state: &Entity<AppState>, n: usize, cx: &mut gpui::VisualTestContext) {
    state.update(cx, |state, cx| {
        state.transcript = vec![reply(n)];
        state.set_subagent_snapshot("peer".into(), vec![reply(n)]);
        cx.notify();
    });
}

#[gpui::test]
fn background_pane_bounds_real_renders_under_the_same_120hz_stream(cx: &mut gpui::TestAppContext) {
    with_panes(cx, |state, focused, peer, cx| {
        let before = |view: &Entity<Transcript>, cx: &gpui::VisualTestContext| {
            view.read_with(cx, |view, _| view.pane_cadence.renders)
        };
        let focused_start = before(&focused, cx);
        let peer_start = before(&peer, cx);
        for n in 1..=120 {
            cx.executor().advance_clock(Duration::from_micros(8_334));
            deliver(&state, n, cx);
            draw(cx);
        }
        cx.executor().advance_clock(BACKGROUND_FRAME_INTERVAL);
        draw(cx);
        let focused_frames = before(&focused, cx) - focused_start;
        let peer_frames = before(&peer, cx) - peer_start;
        println!("120 updates: focused={focused_frames} renders, background={peer_frames} renders");
        assert!(
            focused_frames >= 100,
            "focused stream stalled: {focused_frames}"
        );
        assert!(
            (9..=12).contains(&peer_frames),
            "background renders: {peer_frames}"
        );
        assert!(
            focused_frames >= peer_frames * 5,
            "{focused_frames} vs {peer_frames}"
        );
        peer.read_with(cx, |peer, cx| {
            assert_eq!(
                peer.last_source.as_ref().unwrap().2,
                state.read(cx).transcript_revision
            );
            assert_update(peer, 120);
            assert!(peer.pane_cadence.pending.is_none());
        });
        // With no new content or active animation there is no polling timer.
        let settled = before(&peer, cx);
        cx.executor().advance_clock(Duration::from_secs(2));
        draw(cx);
        assert_eq!(before(&peer, cx), settled);
    });
}

#[gpui::test]
fn background_pane_input_and_promotion_do_not_wait_for_the_budget(cx: &mut gpui::TestAppContext) {
    with_panes(cx, |state, _, peer, cx| {
        deliver(&state, 1, cx);
        cx.run_until_parked();
        peer.read_with(cx, |peer, _| assert!(peer.pane_cadence.pending.is_some()));
        let initial = peer.read_with(cx, |peer, _| peer.pane_cadence.renders);
        peer.update(cx, |_, cx| cx.notify()); // explicit hover/selection/scroll input
        draw(cx);
        assert_eq!(
            peer.read_with(cx, |peer, _| peer.pane_cadence.renders),
            initial + 1
        );
        state.update(cx, |state, _| {
            state.selected_chat = Some("peer".into());
            state.transcript = state.sub_transcript("peer").to_vec();
        });
        peer.update(cx, |peer, cx| peer.set_split_source(None, cx));
        draw(cx);
        peer.read_with(cx, |peer, _| {
            assert!(!peer.pane_cadence.background);
            assert!(peer.pane_cadence.pending.is_none());
            assert_update(peer, 1);
        });
        let promoted = peer.read_with(cx, |peer, _| peer.pane_cadence.renders);
        cx.executor().advance_clock(BACKGROUND_FRAME_INTERVAL * 2);
        draw(cx);
        assert_eq!(
            peer.read_with(cx, |peer, _| peer.pane_cadence.renders),
            promoted,
            "cancelled background callback repainted the promoted pane"
        );
    });
}

#[gpui::test]
fn background_pane_hidden_updates_wait_without_timers_and_catch_up_on_show(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(cx, |state, _, peer, cx| {
        deliver(&state, 1, cx);
        cx.run_until_parked();
        peer.update(cx, |peer, cx| peer.set_background_pane_visible(false, cx));
        let start = peer.read_with(cx, |peer, _| peer.pane_cadence.renders);
        for n in 2..=20 {
            deliver(&state, n, cx);
            cx.executor().advance_clock(BACKGROUND_FRAME_INTERVAL);
            draw(cx);
            peer.read_with(cx, |peer, _| assert!(peer.pane_cadence.pending.is_none()));
        }
        assert_eq!(
            peer.read_with(cx, |peer, _| peer.pane_cadence.renders),
            start
        );
        peer.update(cx, |peer, cx| peer.set_background_pane_visible(true, cx));
        draw(cx);
        peer.read_with(cx, |peer, _| {
            assert_update(peer, 20);
            assert!(peer.pane_cadence.pending.is_none());
        });
    });
}

#[gpui::test]
fn background_pane_animation_requests_share_the_same_frame_budget(cx: &mut gpui::TestAppContext) {
    with_panes(cx, |_, focused, peer, cx| {
        let focused_start = focused.read_with(cx, |view, _| view.pane_cadence.renders);
        let peer_start = peer.read_with(cx, |view, _| view.pane_cadence.renders);
        for _ in 0..120 {
            cx.executor().advance_clock(Duration::from_micros(8_334));
            cx.update(|window, cx| {
                motion::request_view_frame(focused.entity_id(), window, cx);
                motion::request_view_frame(peer.entity_id(), window, cx);
            });
            draw(cx);
        }
        cx.executor().advance_clock(BACKGROUND_FRAME_INTERVAL);
        draw(cx);
        let focused_frames =
            focused.read_with(cx, |view, _| view.pane_cadence.renders) - focused_start;
        let peer_frames = peer.read_with(cx, |view, _| view.pane_cadence.renders) - peer_start;
        assert!(
            focused_frames >= 100,
            "focused animation stalled: {focused_frames}"
        );
        assert!(
            (9..=12).contains(&peer_frames),
            "background animation renders: {peer_frames}"
        );
        assert!(
            focused_frames >= peer_frames * 5,
            "{focused_frames} vs {peer_frames}"
        );
    });
}
