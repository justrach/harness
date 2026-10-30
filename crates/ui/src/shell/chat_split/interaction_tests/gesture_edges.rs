use super::*;

// Distinct message IDs keep the global selection registry and test bounds
// faithful to real sessions, even when every pane displays identical text.
fn entry_for(view: &Entity<Transcript>, text: &str) -> SessionMessageEntry {
    let mut entry = reply(text);
    entry.id = format!("pane-{:?}", view.entity_id());
    entry
}

fn key(view: &Entity<Transcript>, row: &str) -> String {
    row.replacen("reply#", &format!("pane-{:?}#", view.entity_id()), 1)
}

fn text_point(view: &Entity<Transcript>, row: &str) -> Point<gpui::Pixels> {
    let key = key(view, row);
    let entries = render::selection_test_entries();
    let bounds = entries.iter().find(|entry| entry.0 == key)
        .unwrap_or_else(|| panic!("missing {key}; painted keys: {:?}", entries.iter().map(|e| &e.0).collect::<Vec<_>>()));
    bounds.2.origin + gpui::point(px(2.0), px(9.0))
}

fn with_layout(
    cx: &mut gpui::TestAppContext,
    axis: SplitAxis,
    count: usize,
    focus: usize,
    text: &str,
    run: impl FnOnce(Entity<Shell>, &mut gpui::VisualTestContext),
) {
    with_panes(cx, vec![reply(text)], |shell, _, _, cx| {
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.transcript = vec![entry_for(&shell.transcript, text)];
                state.transcript_revision += 1;
                state.set_peer_chat_snapshot(
                    "peer".into(),
                    vec![entry_for(&shell.peer_chat_views["peer"].transcript, text)],
                );
                if count == 3 {
                    let mut third = state.chats[0].clone();
                    third.id = "third".into();
                    state.chats.push(third);
                    state.set_peer_chat_snapshot("third".into(), vec![reply(text)]);
                }
                cx.notify();
            });
            let split = shell.chat_split.as_mut().unwrap();
            split.axis = axis;
            if count == 3 {
                split.panes.push(Some("third".into()));
                split.projects.push(None);
                split.drafts.push(None);
                split.vanished.push(None);
                split.shares.push(0.0);
                split.equalize();
            }
            shell.sync_chat_panes(cx);
        });
        // Let preparation and the peer's 100ms passive-update budget settle
        // before replacing its fixture snapshot and promoting a source pane.
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(100));
        draw(cx);
        shell.update(cx, |shell, cx| {
            if count == 3 {
                shell.state.update(cx, |state, cx| {
                    state.set_peer_chat_snapshot(
                        "third".into(),
                        vec![entry_for(&shell.peer_chat_views["third"].transcript, text)],
                    );
                    cx.notify();
                });
            }
            if focus != 1 {
                assert!(shell.select_chat_pane(focus, cx));
            }
        });
        let size = match axis {
            SplitAxis::Horizontal => gpui::size(px(480.0 * count as f32), px(640.0)),
            SplitAxis::Vertical => gpui::size(px(960.0), px(320.0 * count as f32)),
        };
        cx.simulate_resize(size);
        // Finish fixture delivery before measuring gesture hit targets. No
        // clocks advance during the gestures: direct input remains immediate.
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(100));
        draw(cx);
        run(shell, cx);
    });
}

fn pane_view(shell: &Entity<Shell>, ix: usize, cx: &gpui::VisualTestContext) -> Entity<Transcript> {
    shell.read_with(cx, |shell, _| {
        let split = shell.chat_split.as_ref().unwrap();
        if ix == split.focus {
            shell.transcript.clone()
        } else {
            shell.peer_chat_views[split.panes[ix].as_deref().unwrap()]
                .transcript
                .clone()
        }
    })
}

fn assert_focus(shell: &Entity<Shell>, ix: usize, cx: &mut gpui::VisualTestContext) {
    draw(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split.as_ref().unwrap().focus, ix);
        let expected = ["peer", "current", "third"][ix];
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some(expected)
        );
    });
}

fn clear_selection(view: &Entity<Transcript>, row: &str) {
    selection::end_active_drag();
    selection::clear_if_owner(&key(view, row));
}

#[gpui::test]
fn cross_pane_prose_and_code_drags_preserve_every_source_position_on_both_axes(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for source in 0..3 {
            for target in (0..3).filter(|&ix| ix != source) {
                for (text, row) in [
                    ("Selectable response text.", "reply#text.0:0"),
                    (
                        "```text\nselectable code\nsecond line\n```",
                        "reply#text.0-code0-line0",
                    ),
                ] {
                    with_layout(cx, axis, 3, source, text, |shell, cx| {
                        let origin = pane_view(&shell, source, cx);
                        let destination = pane_view(&shell, target, cx);
                        // Anchor inside the text, not at its first character:
                        // dragging left/up can legitimately shrink a start-of-text
                        // selection to empty before the release is processed.
                        let start = text_point(&origin, row) + gpui::point(px(60.0), px(0.0));
                        let end = text_point(&destination, row);
                        cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
                        cx.simulate_mouse_move(
                            start + gpui::point(px(90.0), px(0.0)),
                            Some(MouseButton::Left),
                            Default::default(),
                        );
                        assert!(selection::selected_text().is_some());
                        draw(cx);
                        cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
                        let selected = selection::selected_text().unwrap_or_else(|| {
                            panic!("{axis:?} {source}->{target} {row}: source stays selected")
                        });
                        cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
                        assert_focus(&shell, source, cx);
                        assert_eq!(
                            pane_view(&shell, source, cx).entity_id(),
                            origin.entity_id()
                        );
                        assert_eq!(
                            pane_view(&shell, target, cx).entity_id(),
                            destination.entity_id()
                        );
                        assert_eq!(selection::selected_text(), Some(selected));
                        clear_selection(&origin, row);
                    });
                }
            }
        }
    }
}

#[gpui::test]
fn cross_pane_releases_with_each_button_allow_a_fresh_click_afterward(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for button in [MouseButton::Left, MouseButton::Right, MouseButton::Middle] {
            with_layout(cx, axis, 2, 1, "Selectable response text.", |shell, cx| {
                let origin = pane_view(&shell, 1, cx);
                let peer = pane_view(&shell, 0, cx);
                let start = text_point(&origin, "reply#text.0:0");
                let end = text_point(&peer, "reply#text.0:0");
                cx.simulate_mouse_down(start, button, Default::default());
                cx.simulate_mouse_move(end, Some(button), Default::default());
                cx.simulate_mouse_up(end, button, Default::default());
                assert_focus(&shell, 1, cx);
                cx.simulate_mouse_down(end, button, Default::default());
                draw(cx);
                cx.simulate_mouse_up(end, button, Default::default());
                assert_focus(&shell, 0, cx);
                assert_eq!(pane_view(&shell, 0, cx).entity_id(), peer.entity_id());
                clear_selection(&origin, "reply#text.0:0");
                clear_selection(&peer, "reply#text.0:0");
            });
        }
    }
}

#[gpui::test]
fn a_selection_can_leave_and_reenter_its_inactive_origin_before_release(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        with_layout(cx, axis, 2, 1, "Selectable response text.", |shell, cx| {
            let peer = pane_view(&shell, 0, cx);
            let current = pane_view(&shell, 1, cx);
            let start = text_point(&peer, "reply#text.0:0");
            let end = start + gpui::point(px(95.0), px(0.0));
            cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
            cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            cx.simulate_mouse_move(
                text_point(&current, "reply#text.0:0"),
                Some(MouseButton::Left),
                Default::default(),
            );
            draw(cx);
            cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            let selected = selection::selected_text().expect("reentered origin selects text");
            cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
            assert_focus(&shell, 0, cx);
            assert_eq!(pane_view(&shell, 0, cx).entity_id(), peer.entity_id());
            assert_eq!(selection::selected_text(), Some(selected));
            clear_selection(&peer, "reply#text.0:0");
        });
    }
}

#[gpui::test]
fn an_abandoned_peer_press_cannot_claim_a_later_drag_from_the_active_pane(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for release_outside in [false, true] {
            with_layout(cx, axis, 2, 1, "Selectable response text.", |shell, cx| {
                let peer = pane_view(&shell, 0, cx);
                let current = pane_view(&shell, 1, cx);
                let peer_point = text_point(&peer, "reply#text.0:0");
                let current_point = text_point(&current, "reply#text.0:0");
                let release = if release_outside {
                    gpui::point(px(-20.0), px(-20.0))
                } else {
                    current_point
                };
                cx.simulate_mouse_down(peer_point, MouseButton::Left, Default::default());
                cx.simulate_mouse_move(release, Some(MouseButton::Left), Default::default());
                cx.simulate_mouse_up(release, MouseButton::Left, Default::default());
                assert_focus(&shell, 1, cx);
                clear_selection(&peer, "reply#text.0:0");
                // The earlier release did not visit the peer's mouse-up handler.
                // A new press in the active pane must invalidate that old claim.
                cx.simulate_mouse_down(current_point, MouseButton::Left, Default::default());
                draw(cx);
                cx.simulate_mouse_move(peer_point, Some(MouseButton::Left), Default::default());
                cx.simulate_mouse_up(peer_point, MouseButton::Left, Default::default());
                assert_focus(&shell, 1, cx);
                clear_selection(&current, "reply#text.0:0");
                cx.simulate_click(peer_point, Default::default());
                assert_focus(&shell, 0, cx);
                clear_selection(&peer, "reply#text.0:0");
            });
        }
    }
}

#[gpui::test]
fn releases_without_a_matching_press_do_not_activate_a_peer(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        with_layout(cx, axis, 2, 1, "Selectable response text.", |shell, cx| {
            let peer = pane_view(&shell, 0, cx);
            let point = text_point(&peer, "reply#text.0:0");
            for button in [MouseButton::Left, MouseButton::Right, MouseButton::Middle] {
                cx.simulate_mouse_up(point, button, Default::default());
                assert_focus(&shell, 1, cx);
            }
            cx.simulate_mouse_down(point, MouseButton::Left, Default::default());
            cx.simulate_mouse_up(point, MouseButton::Right, Default::default());
            assert_focus(&shell, 1, cx);
            cx.simulate_mouse_up(point, MouseButton::Left, Default::default());
            assert_focus(&shell, 1, cx);
            clear_selection(&peer, "reply#text.0:0");
            cx.simulate_click(point, Default::default());
            assert_focus(&shell, 0, cx);
            clear_selection(&peer, "reply#text.0:0");
        });
    }
}

#[gpui::test]
fn dragging_between_two_inactive_peers_does_not_activate_the_release_target(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        with_layout(cx, axis, 3, 1, "Selectable response text.", |shell, cx| {
            let source = pane_view(&shell, 0, cx);
            let destination = pane_view(&shell, 2, cx);
            let start = text_point(&source, "reply#text.0:0");
            let end = text_point(&destination, "reply#text.0:0");
            cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
            cx.simulate_mouse_move(
                start + gpui::point(px(80.0), px(0.0)),
                Some(MouseButton::Left),
                Default::default(),
            );
            draw(cx);
            cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            let selected = selection::selected_text().expect("source peer has a selection");
            cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
            draw(cx);
            shell.read_with(cx, |shell, _| {
                assert_ne!(shell.chat_split.as_ref().unwrap().focus, 2);
            });
            assert_eq!(selection::selected_text(), Some(selected));
            assert_eq!(
                pane_view(&shell, 2, cx).entity_id(),
                destination.entity_id()
            );
            clear_selection(&source, "reply#text.0:0");
        });
    }
}
