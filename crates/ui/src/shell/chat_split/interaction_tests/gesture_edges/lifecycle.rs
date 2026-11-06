use super::*;

#[gpui::test]
fn canvas_project_replacement_cancels_a_held_pane_press(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for button in [MouseButton::Left, MouseButton::Right, MouseButton::Middle] {
            for return_to_original in [false, true] {
                with_layout(cx, axis, 3, 1, "Selectable response text.", |shell, cx| {
                    shell.update(cx, |shell, cx| {
                        let split = shell.chat_split.as_mut().unwrap();
                        split.panes[0] = None;
                        split.projects[0] = Some("original-project".into());
                        shell.sync_chat_panes(cx);
                        cx.notify();
                    });
                    draw(cx);
                    let point = cx.debug_bounds("peer-column").unwrap().center();
                    cx.simulate_mouse_down(point, button, Default::default());
                    shell.update(cx, |shell, cx| {
                        shell.chat_split.as_mut().unwrap().projects[0] =
                            Some("replacement-project".into());
                        shell.sync_chat_panes(cx);
                        if return_to_original {
                            shell.chat_split.as_mut().unwrap().projects[0] =
                                Some("original-project".into());
                            shell.sync_chat_panes(cx);
                        }
                        cx.notify();
                    });
                    draw(cx);
                    cx.simulate_mouse_up(point, button, Default::default());
                    assert_focus(&shell, 1, cx);
                    // Rejecting a stale gesture must not disable a new click
                    // on the same empty pane, or lose its project routing.
                    cx.simulate_click(point, Default::default());
                    draw(cx);
                    shell.read_with(cx, |shell, cx| {
                        assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
                        assert_eq!(shell.state.read(cx).selected_chat, None);
                        let project = if return_to_original {
                            "original-project"
                        } else {
                            "replacement-project"
                        };
                        assert_eq!(shell.settings.space_filter.as_deref(), Some(project));
                    });
                });
            }
        }
    }
}

#[gpui::test]
fn pane_navigation_round_trips_do_not_revive_a_held_press(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for change in ["focus", "tab", "sessions", "zoom"] {
            with_layout(cx, axis, 3, 1, "Selectable response text.", |shell, cx| {
                let peer = pane_view(&shell, 0, cx);
                let point = text_point(&peer, "reply#text.0:0");
                cx.simulate_mouse_down(point, MouseButton::Left, Default::default());
                shell.update(cx, |shell, cx| {
                    match change {
                        "focus" => {
                            assert!(shell.select_chat_pane(2, cx));
                            assert!(shell.select_chat_pane(1, cx));
                        }
                        "tab" => {
                            let original = shell.chat_tab_id;
                            shell.chat_tab_id = uuid::Uuid::new_v4();
                            shell.sync_chat_panes(cx);
                            shell.chat_tab_id = original;
                        }
                        "sessions" => {
                            shell.chat_split.as_mut().unwrap().panes.swap(0, 2);
                            shell.sync_chat_panes(cx);
                            shell.chat_split.as_mut().unwrap().panes.swap(0, 2);
                        }
                        "zoom" => {
                            toggle_legacy_pane_zoom(shell, cx);
                            toggle_legacy_pane_zoom(shell, cx);
                        }
                        _ => unreachable!(),
                    }
                    shell.sync_chat_panes(cx);
                    cx.notify();
                });
                draw(cx);
                cx.simulate_mouse_up(point, MouseButton::Left, Default::default());
                assert_focus(&shell, 1, cx);
                clear_selection(&peer, "reply#text.0:0");
                cx.simulate_click(point, Default::default());
                assert_focus(&shell, 0, cx);
                clear_selection(&pane_view(&shell, 0, cx), "reply#text.0:0");
            });
        }
    }
}

#[gpui::test]
fn harmless_refreshes_preserve_a_held_selection_and_its_pane(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for change in ["metadata", "streaming", "shares"] {
            with_layout(cx, axis, 3, 1, "Selectable response text.", |shell, cx| {
                let peer = pane_view(&shell, 0, cx);
                let current = pane_view(&shell, 1, cx);
                let start = text_point(&peer, "reply#text.0:0");
                let end = start + gpui::point(px(95.0), px(0.0));
                cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
                cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
                let selected = selection::selected_text().expect("real source selection");
                shell.update(cx, |shell, cx| {
                    match change {
                        "metadata" => shell.state.update(cx, |state, cx| {
                            state.chats.reverse();
                            for chat in &mut state.chats {
                                chat.title = Some("Updated synthetic title".into());
                            }
                            cx.notify();
                        }),
                        "streaming" => shell.state.update(cx, |state, cx| {
                            state.set_peer_chat_snapshot(
                                "peer".into(),
                                vec![entry_for(
                                    &peer,
                                    "Selectable response text. More streamed text.",
                                )],
                            );
                            cx.notify();
                        }),
                        "shares" => {
                            let split = shell.chat_split.as_mut().unwrap();
                            split.shares = vec![0.4, 0.3, 0.3];
                            split.equalize();
                        }
                        _ => unreachable!(),
                    }
                    shell.sync_chat_panes(cx);
                    cx.notify();
                });
                draw(cx);
                cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
                assert_focus(&shell, 0, cx);
                assert_eq!(selection::selected_text(), Some(selected));
                assert_eq!(pane_view(&shell, 0, cx).entity_id(), peer.entity_id());
                assert_eq!(pane_view(&shell, 1, cx).entity_id(), current.entity_id());
                clear_selection(&peer, "reply#text.0:0");
            });
        }
    }
}

#[gpui::test]
fn mismatched_button_releases_cancel_without_stealing_pane_focus(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    let buttons = [MouseButton::Left, MouseButton::Right, MouseButton::Middle];
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for press in buttons {
            for release in buttons.into_iter().filter(|button| *button != press) {
                with_layout(cx, axis, 2, 1, "Selectable response text.", |shell, cx| {
                    let peer = pane_view(&shell, 0, cx);
                    let point = text_point(&peer, "reply#text.0:0");
                    cx.simulate_mouse_down(point, press, Default::default());
                    cx.simulate_mouse_up(point, release, Default::default());
                    assert_focus(&shell, 1, cx);
                    cx.simulate_mouse_up(point, press, Default::default());
                    assert_focus(&shell, 1, cx);
                    clear_selection(&peer, "reply#text.0:0");
                    cx.simulate_click(point, Default::default());
                    assert_focus(&shell, 0, cx);
                    clear_selection(&peer, "reply#text.0:0");
                });
            }
        }
    }
}
