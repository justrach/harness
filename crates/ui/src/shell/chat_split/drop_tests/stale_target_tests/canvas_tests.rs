use super::*;
use crate::pickers::{CanvasDraft, CanvasTarget};

mod fallback_tests;

fn focus_canvas(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) {
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            assert!(shell.select_chat_pane(0, cx));
        });
    });
    draw(cx);
}

#[gpui::test]
fn an_active_canvas_retargeted_before_repaint_rejects_the_old_drop(cx: &mut gpui::TestAppContext) {
    for changed_field in ["space", "no_project", "device"] {
        with_panes(
            cx,
            SplitAxis::Horizontal,
            true,
            |shell, image, canvas, _, cx| {
                focus_canvas(&shell, cx);
                enter(cx, canvas, image);
                submit_before_repaint(&shell, cx, canvas, |shell, _, cx| {
                    shell.state.update(cx, |state, _| match changed_field {
                        "space" => state.selected_space = Some("another-space".into()),
                        "no_project" => state.no_project = !state.no_project,
                        "device" => state.selected_device = Some("another-device".into()),
                        _ => unreachable!(),
                    });
                });
                assert_no_new_attachment(&shell, cx);
            },
        );
    }
}

#[gpui::test]
fn changing_an_inactive_canvas_project_before_repaint_rejects_its_old_drop(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        true,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            submit_before_repaint(&shell, cx, peer, |shell, _, _| {
                shell.chat_split.as_mut().unwrap().projects[0] = Some("another-space".into());
            });
            assert_no_new_attachment(&shell, cx);
            shell.read_with(cx, |shell, _| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1)
            });
        },
    );
}

#[gpui::test]
fn changing_an_inactive_canvas_parked_target_rejects_its_old_drop(cx: &mut gpui::TestAppContext) {
    for no_project in [false, true] {
        with_panes(
            cx,
            SplitAxis::Horizontal,
            true,
            |shell, image, peer, _, cx| {
                enter(cx, peer, image);
                submit_before_repaint(&shell, cx, peer, |shell, _, _| {
                    shell.chat_split.as_mut().unwrap().drafts[0] = Some(CanvasDraft {
                        target: Some(CanvasTarget {
                            space: Some("another-space".into()),
                            no_project,
                            device: Some("another-device".into()),
                        }),
                        ..Default::default()
                    });
                });
                assert_no_new_attachment(&shell, cx);
            },
        );
    }
}

#[gpui::test]
fn closing_a_canvas_tab_cannot_reuse_its_old_drop_target_at_the_same_index(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        true,
        |shell, image, _, active, cx| {
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.chat_split = None;
                    shell
                        .state
                        .update(cx, |state, cx| state.select_chat(None, cx));
                    let first = uuid::Uuid::new_v4();
                    let replacement = uuid::Uuid::new_v4();
                    shell.chat_tab = 0;
                    shell.chat_tab_id = first;
                    shell.chat_tabs = vec![
                        ChatTab {
                            id: first.to_string(),
                            ..Default::default()
                        },
                        ChatTab {
                            id: replacement.to_string(),
                            ..Default::default()
                        },
                    ];
                    shell.sync_chat_panes(cx);
                });
            });
            draw(cx);
            enter(cx, active, image);
            submit_before_repaint(&shell, cx, active, |shell, window, cx| {
                assert!(shell.close_chat_tab(window, cx));
            });
            assert_no_new_attachment(&shell, cx);
            shell.read_with(cx, |shell, _| {
                assert_eq!(shell.chat_tab, 0);
                assert_eq!(shell.chat_tabs.len(), 1, "the other session remains open");
                assert_eq!(shell.chat_tabs[0].id, shell.chat_tab_id.to_string());
            });
        },
    );
}

#[gpui::test]
fn changing_only_canvas_model_picks_does_not_discard_a_valid_drop(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        true,
        |shell, image, canvas, _, cx| {
            focus_canvas(&shell, cx);
            enter(cx, canvas, image);
            submit_before_repaint(&shell, cx, canvas, |shell, _, cx| {
                let mut draft = shell.current_canvas_draft(cx);
                draft.model = Some("another-model".into());
                shell.adopt_canvas_draft(Some(draft), cx);
            });
            shell.read_with(cx, |shell, cx| {
                assert!(shell.state.read(cx).selected_chat.is_none());
                assert_eq!(shell.composer.read(cx).staged().len(), 1);
                assert_eq!(shell.composer.read(cx).attachments["current"].len(), 1);
            });
        },
    );
}

#[gpui::test]
fn a_sidebar_filter_change_does_not_retarget_an_existing_session_drop(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, _, active, cx| {
            enter(cx, active, image);
            submit_before_repaint(&shell, cx, active, |shell, _, cx| {
                shell.set_space_filter(Some("another-space".into()), cx);
            });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert_eq!(shell.composer.read(cx).staged().len(), 2);
            });
        },
    );
}

#[gpui::test]
fn a_freshly_painted_canvas_target_accepts_a_drop_after_retargeting(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        true,
        |shell, image, canvas, _, cx| {
            focus_canvas(&shell, cx);
            enter(cx, canvas, image);
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.state.update(cx, |state, _| {
                        state.selected_device = Some("another-device".into());
                    });
                });
            });
            draw(cx);
            file_event(cx, FileDropEvent::Submit { position: canvas });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.composer.read(cx).staged().len(), 1);
                assert_eq!(
                    shell.state.read(cx).selected_device.as_deref(),
                    Some("another-device")
                );
            });
        },
    );
}
