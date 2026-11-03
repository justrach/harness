use super::*;
use gpui::{ExternalPaths, FileDropEvent, PlatformInput};
use std::path::PathBuf;

mod payload_tests;
mod stale_target_tests;
mod window_tests;

/// Render the production active dropzone/composer and peer panes, without
/// starting an engine or the rest of the window chrome.
struct DropPanes(Entity<Shell>);

impl Render for DropPanes {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            let width = f32::from(window.viewport_size().width);
            let main_width = shell.focused_chat_pane_width(width);
            let main = shell.render_main(window, main_width, main_width, cx);
            div()
                .size_full()
                .flex()
                .child(shell.render_chat_split(main, cx))
        })
    }
}

fn draw(cx: &mut gpui::VisualTestContext) {
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        window.draw(cx).clear();
    });
}

fn file_event(cx: &mut gpui::VisualTestContext, event: FileDropEvent) {
    cx.update(|window, cx| {
        window.dispatch_event(PlatformInput::FileDrop(event), cx);
    });
    draw(cx);
}

fn enter(cx: &mut gpui::VisualTestContext, position: Point<Pixels>, path: PathBuf) {
    enter_many(cx, position, vec![path]);
}

fn enter_many(cx: &mut gpui::VisualTestContext, position: Point<Pixels>, paths: Vec<PathBuf>) {
    file_event(
        cx,
        FileDropEvent::Entered {
            position,
            paths: ExternalPaths(paths.into()),
        },
    );
}

fn with_panes(
    cx: &mut gpui::TestAppContext,
    axis: SplitAxis,
    empty_peer: bool,
    run: impl FnOnce(Entity<Shell>, PathBuf, Point<Pixels>, Point<Pixels>, &mut gpui::VisualTestContext),
) {
    // File-drop Submit dispatches mouse-up through real transcripts, which
    // finish the process-global markdown selection. Share its test lock.
    let _selection = crate::markdown::selection::test_state_lock();
    let dir = tempfile::tempdir().unwrap();
    let image = dir.path().join("dropped.png");
    image::RgbaImage::from_pixel(2, 2, image::Rgba([40, 80, 120, 255]))
        .save(&image)
        .unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        settings::init(settings::UiSettings::expanded(), dir.path(), cx);
        crate::motion::set_reduced_motion(cx, true);
    });
    let (host, cx) = cx.add_window_view(|_, cx| {
        DropPanes(cx.new(|cx| {
            let state = cx.new(|_| AppState::new());
            state.update(cx, |state, cx| {
                state.chats = ["current", "peer"]
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "title": "Session",
                            "archived": false, "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .into();
                state.no_project = true;
                state.select_chat(Some("current".into()), cx);
                state.transcript_replayed = true;
            });
            let mut shell = Shell::new(
                state,
                EngineBootConfig {
                    data_dir: dir.path().into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            // This fixture renders the outlet directly, bypassing Shell::render's
            // synchronization of the global reduced-motion preference.
            shell.reduced_motion = crate::motion::reduced_motion(cx);
            shell.chat_split =
                ChatSplit::split(None, axis, (!empty_peer).then(|| "peer".into()), None);
            shell.sync_chat_panes(cx);
            shell.composer.update(cx, |composer, cx| {
                composer.input.update(cx, |input, cx| {
                    input.set_text("Keep the current draft", cx);
                });
                composer.add_paths(vec![image.clone()], cx);
            });
            shell
        }))
    });
    cx.simulate_resize(gpui::size(px(1000.0), px(800.0)));
    draw(cx);
    let shell = host.read_with(cx, |host, _| host.0.clone());
    let (peer, current) = match axis {
        SplitAxis::Horizontal => (
            gpui::point(px(250.0), px(200.0)),
            gpui::point(px(750.0), px(200.0)),
        ),
        SplitAxis::Vertical => (
            gpui::point(px(500.0), px(200.0)),
            gpui::point(px(500.0), px(600.0)),
        ),
    };
    run(shell, image, peer, current, cx);
}

#[gpui::test]
fn external_image_drop_activates_the_receiving_pane(cx: &mut gpui::TestAppContext) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        with_panes(cx, axis, false, |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
            });
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "peer");
                assert_eq!(composer.staged().len(), 1);
                assert!(composer.staged()[0].image.is_some());
                assert_eq!(composer.attachments["current"].len(), 1);
                assert_eq!(composer.input.read(cx).text(), "");
            });
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.select_chat_pane(1, cx);
                });
            });
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                let composer = shell.composer.read(cx);
                assert_eq!(composer.staged().len(), 1);
                assert_eq!(composer.input.read(cx).text(), "Keep the current draft");
            });
        });
    }
}

#[gpui::test]
fn cancelling_an_inactive_pane_drag_does_not_activate_it(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, current, cx| {
            enter(cx, peer, image.clone());
            file_event(cx, FileDropEvent::Exited);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                let composer = shell.composer.read(cx);
                assert_eq!(composer.staged().len(), 1);
                assert!(!composer.attachments.contains_key("peer"));
            });
            // The production active-pane handler still works after a cancelled drag.
            enter(cx, current, image);
            file_event(cx, FileDropEvent::Submit { position: current });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "current");
                assert_eq!(composer.staged().len(), 2);
                assert!(!composer.attachments.contains_key("peer"));
            });
        },
    );
}

#[gpui::test]
fn external_image_drop_also_activates_an_empty_pane(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        true,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
                assert!(shell.state.read(cx).selected_chat.is_none());
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "");
                assert_eq!(composer.staged().len(), 1);
                assert_eq!(composer.attachments["current"].len(), 1);
            });
        },
    );
}

#[gpui::test]
fn a_batch_keeps_valid_files_and_reports_invalid_files_in_the_target(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            let dir = image.parent().unwrap();
            let jpeg = dir.join("second image.JPEG");
            image::RgbImage::from_pixel(2, 2, image::Rgb([120, 80, 40]))
                .save(&jpeg)
                .unwrap();
            let pdf = dir.join("notes.pdf");
            std::fs::write(&pdf, b"%PDF-1.7 test").unwrap();
            let folder = dir.join("folder");
            std::fs::create_dir(&folder).unwrap();
            let missing = dir.join("missing.png");
            enter_many(cx, peer, vec![image.clone(), folder, jpeg, pdf, missing]);
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "peer");
                let staged = composer.staged();
                assert_eq!(
                    staged.iter().map(|a| a.name.as_str()).collect::<Vec<_>>(),
                    ["dropped.png", "second image.JPEG", "notes.pdf"]
                );
                assert!(staged[0].image.is_some());
                assert!(staged[1].image.is_some());
                assert!(staged[2].file.is_some());
                assert!(
                    composer
                        .failure
                        .as_ref()
                        .unwrap()
                        .contains("missing.png could not be read")
                );
                assert_eq!(composer.attachments["current"].len(), 1);
            });
        },
    );
}

#[gpui::test]
fn rejected_files_do_not_leak_attachments_or_errors_to_the_previous_session(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            let too_large = image.parent().unwrap().join("too-large.png");
            std::fs::File::create(&too_large)
                .unwrap()
                .set_len(crate::attachments::MAX_ATTACHMENT_BYTES + 1)
                .unwrap();
            enter(cx, peer, too_large);
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "peer");
                assert!(composer.staged().is_empty());
                assert!(composer.failure.as_ref().unwrap().contains("too large"));
                assert_eq!(composer.attachments["current"].len(), 1);
            });
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.select_chat_pane(1, cx);
                })
            });
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "current");
                assert_eq!(composer.staged().len(), 1);
                assert_eq!(composer.input.read(cx).text(), "Keep the current draft");
            });
        },
    );
}

#[gpui::test]
fn the_final_drop_position_not_the_first_hover_selects_the_destination(
    cx: &mut gpui::TestAppContext,
) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        with_panes(cx, axis, false, |shell, image, peer, current, cx| {
            enter(cx, peer, image.clone());
            file_event(cx, FileDropEvent::Pending { position: current });
            file_event(cx, FileDropEvent::Submit { position: current });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
                let composer = shell.composer.read(cx);
                assert_eq!(composer.staged().len(), 2);
                assert!(!composer.attachments.contains_key("peer"));
            });
            enter(cx, current, image);
            file_event(cx, FileDropEvent::Pending { position: peer });
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
                let composer = shell.composer.read(cx);
                assert_eq!(composer.staged().len(), 1);
                assert_eq!(composer.attachments["current"].len(), 2);
            });
        });
    }
}

#[gpui::test]
fn repeated_drops_preserve_both_panes_existing_drafts_and_focus_the_composer(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, current, cx| {
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.select_chat_pane(0, cx);
                    shell.composer.update(cx, |composer, cx| {
                        composer.add_paths(vec![image.clone()], cx);
                        composer
                            .input
                            .update(cx, |input, cx| input.set_text("Peer draft", cx));
                    });
                    shell.select_chat_pane(1, cx);
                })
            });
            draw(cx);
            for (position, expected, count) in [
                (peer, "peer", 2),
                (current, "current", 2),
                (peer, "peer", 3),
            ] {
                enter(cx, position, image.clone());
                file_event(cx, FileDropEvent::Submit { position });
                shell.read_with(cx, |shell, cx| {
                    let composer = shell.composer.read(cx);
                    assert_eq!(composer.current_key, expected);
                    assert_eq!(composer.staged().len(), count);
                    assert_eq!(
                        composer.input.read(cx).text(),
                        if expected == "peer" {
                            "Peer draft"
                        } else {
                            "Keep the current draft"
                        }
                    );
                });
                cx.update(|window, cx| {
                    shell.read_with(cx, |shell, cx| {
                        assert!(shell.composer.read(cx).focus_handle(cx).is_focused(window));
                    })
                });
            }
        },
    );
}

#[gpui::test]
fn an_empty_external_payload_does_not_activate_a_pane(cx: &mut gpui::TestAppContext) {
    with_panes(cx, SplitAxis::Horizontal, false, |shell, _, peer, _, cx| {
        enter_many(cx, peer, vec![]);
        file_event(cx, FileDropEvent::Submit { position: peer });
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            assert!(!shell.composer.read(cx).attachments.contains_key("peer"));
        });
    });
}

#[gpui::test]
fn every_pane_accepts_drops_in_maximum_and_uneven_layouts(cx: &mut gpui::TestAppContext) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for shares in [
            vec![0.15, 0.55, 0.30],
            vec![1.0 / MAX_CHAT_PANES as f32; MAX_CHAT_PANES],
        ] {
            with_panes(cx, axis, false, |shell, image, _, _, cx| {
                let ids: Vec<String> = (0..shares.len() - 1)
                    .map(|ix| format!("grid-{ix}"))
                    .chain(std::iter::once("current".into()))
                    .collect();
                cx.update(|_, cx| {
                    shell.update(cx, |shell, cx| {
                        shell.state.update(cx, |state, _| {
                            state.chats.extend(ids[..ids.len() - 1].iter().map(|id| {
                                serde_json::from_value(serde_json::json!({
                                    "id": id, "deviceId": "local", "title": "Session",
                                    "archived": false, "createdAt": Utc::now(),
                                }))
                                .unwrap()
                            }));
                        });
                        let mut split = None;
                        for id in &ids[..ids.len() - 1] {
                            split = ChatSplit::split(split, axis, Some(id.clone()), None);
                        }
                        split.as_mut().unwrap().shares = shares.clone();
                        shell.chat_split = split;
                        shell.chat_split_selected = Some("current".into());
                        shell.sync_chat_panes(cx);
                    })
                });
                draw(cx);
                let mut start = 0.0;
                for (ix, (id, share)) in ids.iter().zip(&shares).enumerate() {
                    let middle = start + share / 2.0;
                    let position = match axis {
                        SplitAxis::Horizontal => gpui::point(px(1000.0 * middle), px(200.0)),
                        SplitAxis::Vertical => gpui::point(px(500.0), px(800.0 * middle)),
                    };
                    start += share;
                    enter(cx, position, image.clone());
                    file_event(cx, FileDropEvent::Submit { position });
                    shell.read_with(cx, |shell, cx| {
                        assert_eq!(
                            shell.chat_split.as_ref().unwrap().focus,
                            ix,
                            "wrong target for {axis:?} layout {shares:?}"
                        );
                        assert_eq!(shell.state.read(cx).selected_chat.as_ref(), Some(id));
                        let composer = shell.composer.read(cx);
                        assert_eq!(composer.staged().len(), if id == "current" { 2 } else { 1 });
                        let total: usize = composer.attachments.values().map(Vec::len).sum();
                        assert_eq!(total, ix + 2, "one attachment per drop, no duplicates");
                    });
                }
            });
        }
    }
}

#[gpui::test]
fn zooming_during_a_drag_does_not_send_files_to_a_hidden_pane(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_chat_pane_zoom(cx)));
            draw(cx);
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
                assert!(shell.chat_split.as_ref().unwrap().zoomed);
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "current");
                assert_eq!(composer.staged().len(), 2);
                assert!(!composer.attachments.contains_key("peer"));
            });
        },
    );
}

#[gpui::test]
fn dropping_in_an_archived_pane_stages_without_unarchiving(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.state.update(cx, |state, cx| {
                        state.chats_synced = true;
                        state
                            .chats
                            .iter_mut()
                            .find(|chat| chat.id == "peer")
                            .unwrap()
                            .archived = true;
                        cx.notify();
                    });
                })
            });
            draw(cx);
            enter(cx, peer, image);
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                let state = shell.state.read(cx);
                assert_eq!(state.selected_chat.as_deref(), Some("peer"));
                assert!(state.selected_chat_row().unwrap().archived);
                assert_eq!(shell.composer.read(cx).staged().len(), 1);
            });
        },
    );
}

#[gpui::test]
fn dropping_into_another_pane_clears_queue_edit_before_attaching(cx: &mut gpui::TestAppContext) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            enter(cx, peer, image);
            // Model an in-flight queue edit with its normal draft parked underneath.
            // The drop must restore that draft in the source, not attach to the edit.
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.composer.update(cx, |composer, cx| {
                        let original = composer.attachments.remove("current").unwrap();
                        composer.queue_edit_draft =
                            Some(("Keep the current draft".into(), original, vec![]));
                        composer.editing_queued = Some("editing-row".into());
                        composer.queue_edit_chat_id = Some("current".into());
                        composer.queue_edit_finishing = true;
                        composer
                            .input
                            .update(cx, |input, cx| input.set_text("Queued edit", cx));
                    });
                })
            });
            file_event(cx, FileDropEvent::Submit { position: peer });
            shell.read_with(cx, |shell, cx| {
                let composer = shell.composer.read(cx);
                assert_eq!(composer.current_key, "peer");
                assert!(composer.editing_queued.is_none());
                assert!(!composer.queue_edit_finishing);
                assert!(composer.queue_edit_draft.is_none());
                assert_eq!(composer.staged().len(), 1);
                assert_eq!(composer.attachments["current"].len(), 1);
                assert_eq!(composer.input.read(cx).text(), "");
            });
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.select_chat_pane(1, cx);
                })
            });
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.composer.read(cx).input.read(cx).text(),
                    "Keep the current draft"
                );
            });
        },
    );
}

#[gpui::test]
fn rapid_enter_and_submit_before_repaint_still_use_the_target_session(
    cx: &mut gpui::TestAppContext,
) {
    with_panes(
        cx,
        SplitAxis::Horizontal,
        false,
        |shell, image, peer, _, cx| {
            cx.update(|window, cx| {
                window.dispatch_event(
                    PlatformInput::FileDrop(FileDropEvent::Entered {
                        position: peer,
                        paths: ExternalPaths(vec![image].into()),
                    }),
                    cx,
                );
                window.dispatch_event(
                    PlatformInput::FileDrop(FileDropEvent::Submit { position: peer }),
                    cx,
                );
                // State observers have not flushed yet: the handler must have
                // synchronously bound the composer before touching attachments.
                shell.read_with(cx, |shell, cx| {
                    let composer = shell.composer.read(cx);
                    assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                    assert_eq!(composer.current_key, "peer");
                    assert_eq!(composer.staged().len(), 1);
                    assert_eq!(composer.attachments["current"].len(), 1);
                });
            });
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
                assert_eq!(shell.composer.read(cx).staged().len(), 1);
            });
        },
    );
}
