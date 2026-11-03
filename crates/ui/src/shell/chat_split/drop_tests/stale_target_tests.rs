use super::*;
use crate::shell::chat_tabs::ChatTab;

mod canvas_tests;

/// Change navigation/layout and submit in the same update. No frame or state
/// observer flush is allowed between the change and the old mounted handler.
fn submit_before_repaint(
    shell: &Entity<Shell>,
    cx: &mut gpui::VisualTestContext,
    position: Point<Pixels>,
    change: impl FnOnce(&mut Shell, &mut Window, &mut Context<Shell>),
) {
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| change(shell, window, cx));
        window.dispatch_event(
            PlatformInput::FileDrop(FileDropEvent::Submit { position }),
            cx,
        );
    });
    draw(cx);
}

fn assert_no_new_attachment(shell: &Entity<Shell>, cx: &gpui::VisualTestContext) {
    shell.read_with(cx, |shell, cx| {
        let composer = shell.composer.read(cx);
        assert_eq!(
            composer.attachments.values().map(Vec::len).sum::<usize>(),
            1,
            "a stale drop must not attach to any old or new destination"
        );
        assert_eq!(composer.attachments["current"].len(), 1);
        assert!(composer.failure.is_none());
    });
}

#[gpui::test]
fn authoritative_deletion_is_checked_before_selection_observers_run(cx: &mut gpui::TestAppContext) {
    for target_peer in [true, false] {
        with_panes(
            cx,
            SplitAxis::Horizontal,
            false,
            |shell, image, peer, active, cx| {
                let position = if target_peer { peer } else { active };
                let deleted = if target_peer { "peer" } else { "current" };
                enter(cx, position, image);
                submit_before_repaint(&shell, cx, position, |shell, _, cx| {
                    shell.state.update(cx, |state, _| {
                        state.chats_synced = true;
                        state.chats.retain(|chat| chat.id != deleted);
                    });
                });
                assert_no_new_attachment(&shell, cx);
            },
        );
    }
}

#[gpui::test]
fn stale_peer_and_active_handlers_do_not_attach_after_opening_settings(
    cx: &mut gpui::TestAppContext,
) {
    for target_peer in [true, false] {
        with_panes(
            cx,
            SplitAxis::Horizontal,
            false,
            |shell, image, peer, active, cx| {
                let position = if target_peer { peer } else { active };
                enter(cx, position, image);
                submit_before_repaint(&shell, cx, position, |shell, _, _| {
                    shell.route = Route::Settings(SettingsSection::Appearance);
                });
                assert_no_new_attachment(&shell, cx);
                shell.read_with(cx, |shell, cx| {
                    assert_eq!(shell.route, Route::Settings(SettingsSection::Appearance));
                    assert_eq!(
                        shell.state.read(cx).selected_chat.as_deref(),
                        Some("current")
                    );
                });
            },
        );
    }
}

#[gpui::test]
fn a_deleted_peer_cannot_receive_files_as_an_accidental_new_canvas(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            submit_before_repaint(&shell, cx, peer, |shell, _, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats_synced = true;
                    state.chats.retain(|chat| chat.id != "peer");
                });
                shell.chat_split_on_state_changed(cx);
            });
            assert_no_new_attachment(&shell, cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                )
            });
        },
    );
}

#[gpui::test]
fn replacing_a_peer_before_repaint_cannot_redirect_its_old_drop(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            submit_before_repaint(&shell, cx, peer, |shell, _, cx| {
                shell.state.update(cx, |state, _| {
                    let mut replacement = state
                        .chats
                        .iter()
                        .find(|chat| chat.id == "peer")
                        .unwrap()
                        .clone();
                    replacement.id = "replacement".into();
                    state.chats.push(replacement);
                });
                shell.chat_split.as_mut().unwrap().panes[0] = Some("replacement".into());
                shell.sync_chat_panes(cx);
            });
            assert_no_new_attachment(&shell, cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                )
            });
        },
    );
}

#[gpui::test]
fn changing_tabs_invalidates_old_handlers_even_with_identical_chat_ids(
    cx: &mut gpui::TestAppContext,
) {
    for target_peer in [true, false] {
        with_panes(
            cx,
            SplitAxis::Horizontal,
            false,
            |shell, image, peer, active, cx| {
                let position = if target_peer { peer } else { active };
                enter(cx, position, image);
                submit_before_repaint(&shell, cx, position, |shell, window, cx| {
                    let tab = ChatTab {
                        id: uuid::Uuid::new_v4().to_string(),
                        split: shell.chat_split.clone(),
                        selected: shell.state.read(cx).selected_chat.clone(),
                        project: shell.settings.space_filter.clone(),
                        draft: None,
                        ..Default::default()
                    };
                    shell.chat_tabs = vec![tab.clone(), tab];
                    shell.switch_chat_tab(1, window, cx);
                });
                assert_no_new_attachment(&shell, cx);
                shell.read_with(cx, |shell, _| assert_eq!(shell.chat_tab, 1));
            },
        );
    }
}

#[gpui::test]
fn an_active_session_replacement_does_not_inherit_the_old_composers_drop(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, _, active, cx| {
            enter(cx, active, image);
            submit_before_repaint(&shell, cx, active, |shell, _, cx| {
                shell.state.update(cx, |state, cx| {
                    let mut replacement = state
                        .chats
                        .iter()
                        .find(|chat| chat.id == "current")
                        .unwrap()
                        .clone();
                    replacement.id = "replacement".into();
                    state.chats.push(replacement);
                    state.select_chat(Some("replacement".into()), cx);
                });
                shell.chat_split_on_state_changed(cx);
            });
            assert_no_new_attachment(&shell, cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("replacement")
                )
            });
        },
    );
}

#[gpui::test]
fn zooming_before_repaint_does_not_reactivate_a_now_hidden_peer(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            submit_before_repaint(&shell, cx, peer, |shell, _, cx| {
                zoom_legacy_panes(shell, cx)
            });
            assert_no_new_attachment(&shell, cx);
            shell.read_with(cx, |shell, cx| {
                assert!(shell.chat_split.as_ref().unwrap().zoomed);
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
            });
        },
    );
}

#[gpui::test]
fn resizing_before_repaint_invalidates_old_spatial_drop_targets(cx: &mut gpui::TestAppContext) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        with_panes(cx, axis, false, |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            submit_before_repaint(&shell, cx, peer, |shell, _, _| {
                shell.chat_split.as_mut().unwrap().shares = vec![0.15, 0.85];
            });
            assert_no_new_attachment(&shell, cx);
        });
    }
}

#[gpui::test]
fn closing_the_split_before_repaint_discards_its_old_peer_drop(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            submit_before_repaint(&shell, cx, peer, |shell, _, cx| {
                shell.chat_split = None;
                shell.sync_chat_panes(cx);
            });
            assert_no_new_attachment(&shell, cx);
        },
    );
}

#[gpui::test]
fn unrelated_state_updates_do_not_invalidate_a_still_visible_target(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            submit_before_repaint(&shell, cx, peer, |shell, _, cx| {
                shell.state.update(cx, |state, cx| {
                    state
                        .chats
                        .iter_mut()
                        .find(|chat| chat.id == "peer")
                        .unwrap()
                        .title = Some("Updated title".into());
                    cx.notify();
                });
            });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                assert_eq!(shell.composer.read(cx).staged().len(), 1);
                assert_eq!(shell.composer.read(cx).attachments["current"].len(), 1);
            });
        },
    );
}

#[gpui::test]
fn a_newly_rendered_layout_accepts_drops_after_a_resize(cx: &mut gpui::TestAppContext) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        with_panes(cx, axis, false, |shell, image, _, _, cx| {
            cx.update(|_, cx| {
                shell.update(cx, |shell, _| {
                    shell.chat_split.as_mut().unwrap().shares = vec![0.15, 0.85];
                })
            });
            draw(cx);
            let position = match axis {
                SplitAxis::Horizontal => gpui::point(px(75.0), px(200.0)),
                SplitAxis::Vertical => gpui::point(px(500.0), px(60.0)),
            };
            enter(cx, position, image);
            file_event(cx, FileDropEvent::Submit { position });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                assert_eq!(shell.composer.read(cx).staged().len(), 1);
            });
        });
    }
}
