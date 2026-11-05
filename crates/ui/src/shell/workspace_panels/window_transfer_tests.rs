use super::window_transfer::WindowTransferFailure;
use super::*;
use gpui::{AppContext as _, TestAppContext, WindowHandle};

pub(super) fn setup(cx: &mut TestAppContext) -> (tempfile::TempDir, WindowHandle<Shell>) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        let settings = UiSettings::default();
        settings::init(settings.clone(), dir.path(), cx);
        crate::history::init(
            settings.git_history_columns,
            settings.git_history_column_widths,
            settings.git_history_column_order,
            settings.git_history_author_display,
            cx,
        );
        motion::set_reduced_motion(cx, true);
    });
    let source = cx.add_window(|_, cx| {
        let state = cx.new(|_| {
            let mut state = AppState::new();
            state.connection = ConnectionStatus::Ready;
            state.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
            state.selected_chat = Some("chat-a".into());
            state.auto_selected = true;
            state.chats_synced = true;
            state.spaces_synced = true;
            state.chats = ["chat-a", "chat-b"].into_iter().map(|id| serde_json::from_value(serde_json::json!({
                "id":id,"deviceId":"fixture-device","title":id,"archived":false,"createdAt":"2026-10-31T00:00:00Z"
            })).unwrap()).collect();
            state
        });
        Shell::new(state, EngineBootConfig {
            data_dir: dir.path().into(), ipc_port: 0,
            edge_url: "http://127.0.0.1:1".into(), edge_token: None,
            org_id: None, codegraff_client_id: None, default_harness: harness_proto::HarnessId::Mock,
        }, cx)
    });
    source
        .update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![
                PanelTab::Chat("chat-a".into()),
                PanelTab::Chat("chat-b".into()),
            ];
            layout.panels[0].active = 0;
            layout.last_selected = Some(Some("chat-a".into()));
            shell.composer.update(cx, |composer, cx| {
                composer.current_key = "chat-a".into();
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("An unsent draft", cx));
            });
        })
        .unwrap();
    (dir, source)
}

fn install_resource(shell: &mut Shell, tab: PanelTab, cx: &mut Context<Shell>) {
    let layout = shell.panel_layout_mut(cx);
    layout.panels[0].tabs = vec![PanelTab::Chat("chat-b".into()), tab.clone()];
    layout.panels[0].active = 1;
    layout.focused = 0;
    layout.imported.insert(tab);
}

fn failed_transfer_keeps_source(cx: &mut TestAppContext, failure: WindowTransferFailure) {
    let (_dir, source) = setup(cx);
    let (tab, browser) = source
        .update(cx, |shell, window, cx| {
            let browser = cx.new(|cx| {
                crate::browser::BrowserSurface::new(
                    shell.browser_context.clone(),
                    false,
                    window,
                    cx,
                )
            });
            shell.browsers.insert(11, browser.clone());
            let tab = PanelTab::Surface {
                owner: "chat-a".into(),
                surface: RightSurface::Browser(11),
            };
            install_resource(shell, tab.clone(), cx);
            shell.composer.update(cx, |composer, _| {
                composer.attachments.insert(
                    "chat-a".into(),
                    vec![crate::attachments::StagedAttachment {
                        #[cfg(target_os = "macos")]
                        editable: None,
                        #[cfg(target_os = "macos")]
                        unavailable_editable: None,
                        unavailable: None,
                        annotations: None,
                        id: "rollback-attachment".into(),
                        name: "draft.txt".into(),
                        image: None,
                        file: Some(std::sync::Arc::from(&b"keep these bytes"[..])),
                    }],
                );
                composer
                    .appshots
                    .insert("chat-a".into(), vec![crate::appshots::tests::shot()]);
            });
            shell.save_window_record(cx);
            (tab, browser)
        })
        .unwrap();
    let before_windows = cx.update(|cx| cx.windows().len());
    let before_records = cx.update(|cx| settings::current(cx).workspace_windows);
    let before_tabs = source
        .read_with(cx, |shell, cx| {
            shell.panel_layout(cx).unwrap().panels[0].tabs.clone()
        })
        .unwrap();
    cx.update(|cx| cx.set_global(failure));
    let result = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, tab, None, window, cx)
        })
        .unwrap();
    assert!(result.is_err());
    cx.run_until_parked();
    assert_eq!(cx.update(|cx| cx.windows().len()), before_windows);
    assert_eq!(
        cx.update(|cx| settings::current(cx).workspace_windows),
        before_records,
        "failed creation/adoption must leave no orphan window record"
    );
    source
        .read_with(cx, |shell, cx| {
            assert_eq!(shell.browsers[&11].entity_id(), browser.entity_id());
            assert_eq!(shell.panel_layout(cx).unwrap().panels[0].tabs, before_tabs);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-a")
            );
            let composer = shell.composer.read(cx);
            assert_eq!(
                composer.parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
            assert_eq!(
                composer.attachments["chat-a"][0].bytes(),
                b"keep these bytes"
            );
            assert_eq!(composer.appshots["chat-a"].len(), 1);
        })
        .unwrap();
}

#[gpui::test]
fn window_transfer_creation_failure_preserves_live_source_and_records(cx: &mut TestAppContext) {
    failed_transfer_keeps_source(cx, WindowTransferFailure::Creation);
}

#[gpui::test]
fn window_transfer_adoption_failure_rolls_back_browser_and_records(cx: &mut TestAppContext) {
    failed_transfer_keeps_source(cx, WindowTransferFailure::NativeAdoption);
}

#[gpui::test]
fn window_transfer_first_paint_failure_restores_browser_composer_and_records(
    cx: &mut TestAppContext,
) {
    failed_transfer_keeps_source(cx, WindowTransferFailure::FirstPaint);
}

#[gpui::test]
fn window_transfer_middle_chat_keeps_previewed_left_survivor_without_a_new_tab(
    cx: &mut TestAppContext,
) {
    for keep_left_chat in [true, false] {
        let (_dir, source) = setup(cx);
        let browser = source
            .update(cx, |shell, window, cx| {
                let browser = cx.new(|cx| {
                    crate::browser::BrowserSurface::new(
                        shell.browser_context.clone(),
                        false,
                        window,
                        cx,
                    )
                });
                shell.browsers.insert(11, browser);
                let tab = PanelTab::Surface {
                    owner: "chat-a".into(),
                    surface: RightSurface::Browser(11),
                };
                let mut tabs = Vec::new();
                if keep_left_chat {
                    tabs.push(PanelTab::Chat("chat-a".into()));
                }
                tabs.push(PanelTab::Chat("chat-b".into()));
                tabs.push(tab.clone());
                let layout = shell.panel_layout_mut(cx);
                layout.panels[0].tabs = tabs;
                layout.panels[0].active = usize::from(keep_left_chat);
                layout.last_selected = Some(Some("chat-b".into()));
                layout.imported.insert(tab.clone());
                shell
                    .state
                    .update(cx, |state, cx| state.select_chat(Some("chat-b".into()), cx));
                tab
            })
            .unwrap();
        let destination = source
            .update(cx, |shell, window, cx| {
                shell.move_workspace_tab_to_new_window(
                    0,
                    PanelTab::Chat("chat-b".into()),
                    None,
                    window,
                    cx,
                )
            })
            .unwrap()
            .unwrap();
        gpui::AnyWindowHandle::from(source)
            .update(cx, |_, window, cx| window.draw(cx).clear())
            .unwrap();
        cx.run_until_parked();
        source
            .read_with(cx, |shell, cx| {
                let layout = shell.panel_layout(cx).unwrap();
                let expected = if keep_left_chat {
                    vec![PanelTab::Chat("chat-a".into()), browser.clone()]
                } else {
                    vec![browser.clone()]
                };
                assert_eq!(layout.panels[0].tabs, expected);
                assert_eq!(layout.panels[0].active, 0);
                assert!(
                    !layout.panels[0]
                        .tabs
                        .iter()
                        .any(|tab| matches!(tab, PanelTab::Draft(_) | PanelTab::New(_)))
                );
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    keep_left_chat.then_some("chat-a")
                );
            })
            .unwrap();
        destination
            .read_with(cx, |shell, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("chat-b")
                )
            })
            .unwrap();
        gpui::AnyWindowHandle::from(source)
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        gpui::AnyWindowHandle::from(destination)
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
    }
}

#[gpui::test]
fn window_transfer_keeps_browser_entity_and_source_selection_independent(cx: &mut TestAppContext) {
    let (_dir, source) = setup(cx);
    let (tab, browser) = source
        .update(cx, |shell, window, cx| {
            let browser = cx.new(|cx| {
                crate::browser::BrowserSurface::new(
                    shell.browser_context.clone(),
                    false,
                    window,
                    cx,
                )
            });
            shell.browser_seq = 11;
            shell.browsers.insert(11, browser.clone());
            let tab = PanelTab::Surface {
                owner: "chat-a".into(),
                surface: RightSurface::Browser(11),
            };
            install_resource(shell, tab.clone(), cx);
            (tab, browser)
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, tab, None, window, cx)
        })
        .unwrap()
        .unwrap();
    destination
        .read_with(cx, |shell, cx| {
            assert_eq!(shell.browsers.len(), 1);
            assert_eq!(
                shell.browsers.values().next().unwrap().entity_id(),
                browser.entity_id()
            );
            assert_eq!(shell.panel_layout(cx).unwrap().panels[0].tabs.len(), 1);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-a")
            );
        })
        .unwrap();
    source
        .read_with(cx, |shell, cx| {
            assert!(shell.browsers.is_empty());
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-b")
            );
            assert_eq!(
                shell.panel_layout(cx).unwrap().panels[0].tabs,
                vec![PanelTab::Chat("chat-b".into())]
            );
        })
        .unwrap();
}

#[gpui::test]
fn window_transfer_keeps_terminal_entity_and_owner(cx: &mut TestAppContext) {
    let (_dir, source) = setup(cx);
    let terminal = source
        .update(cx, |shell, _, cx| {
            let terminal = cx.new(|cx| {
                let mut terminal = TerminalPanel::new_embedded(shell.state.clone(), cx);
                terminal.pin_session("chat-a".into());
                terminal
            });
            shell
                .workspace_panels
                .terminals
                .insert(11, terminal.clone());
            shell.workspace_panels.terminal_keys.insert(11, 4);
            install_resource(shell, PanelTab::Terminal(11), cx);
            terminal
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, PanelTab::Terminal(11), None, window, cx)
        })
        .unwrap()
        .unwrap();
    destination
        .read_with(cx, |shell, cx| {
            let adopted = shell.workspace_panels.terminals.values().next().unwrap();
            assert_eq!(adopted.entity_id(), terminal.entity_id());
            assert_eq!(adopted.read(cx).session_owner(cx), "chat-a");
            assert_eq!(
                shell
                    .workspace_panels
                    .terminal_keys
                    .values()
                    .copied()
                    .collect::<Vec<_>>(),
                vec![4]
            );
        })
        .unwrap();
    source
        .read_with(cx, |shell, _| {
            assert!(shell.workspace_panels.terminals.is_empty())
        })
        .unwrap();
}

#[gpui::test]
fn window_transfer_keeps_file_entity_and_path(cx: &mut TestAppContext) {
    let (_dir, source) = setup(cx);
    let (tab, file) = source
        .update(cx, |shell, _, cx| {
            let file = cx.new(|cx| {
                FilesSurface::new_editor(
                    shell.state.clone(),
                    "chat-a".into(),
                    "notes.txt".into(),
                    false,
                    1000,
                    13.0,
                    false,
                    false,
                    cx,
                )
            });
            shell.file_surfaces.insert(11, file.clone());
            shell.file_surface_paths.insert(11, "notes.txt".into());
            let tab = PanelTab::Surface {
                owner: "chat-a".into(),
                surface: RightSurface::File(11),
            };
            install_resource(shell, tab.clone(), cx);
            (tab, file)
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, tab, None, window, cx)
        })
        .unwrap()
        .unwrap();
    destination
        .read_with(cx, |shell, _| {
            assert_eq!(
                shell.file_surfaces.values().next().unwrap().entity_id(),
                file.entity_id()
            );
            assert_eq!(
                shell.file_surface_paths.values().next().unwrap(),
                "notes.txt"
            );
        })
        .unwrap();
    source
        .read_with(cx, |shell, _| assert!(shell.file_surfaces.is_empty()))
        .unwrap();
}

#[gpui::test]
fn window_transfer_markdown_anchor_keeps_panel_and_engine_owners(cx: &mut TestAppContext) {
    let (dir, source) = setup(cx);
    let (tab, file) = source
        .update(cx, |shell, window, cx| {
            shell.state.update(cx, |state, _| {
                state.local_device_id = Some("fixture-device".into());
                for chat in &mut state.chats {
                    chat.cwd = Some(dir.path().join(&chat.id).to_string_lossy().into_owned());
                }
            });
            let owner = shell.panel_key(cx);
            shell.add_file_surface("README.md".into(), window, cx);
            let id = shell.file_surface_keys[&(owner.clone(), "chat-a".into(), "README.md".into())];
            let file = shell.file_surfaces[&id].clone();
            // The file retains chat-a's checkout even when another chat owns
            // the selected conversation in the window being detached from.
            shell.focus_workspace_tab(0, PanelTab::Chat("chat-b".into()), window, cx);
            let tab = PanelTab::Surface {
                owner,
                surface: RightSurface::File(id),
            };
            install_resource(shell, tab.clone(), cx);
            (tab, file)
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, tab, None, window, cx)
        })
        .unwrap()
        .unwrap();
    let owner = destination
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-b")
            );
            assert_eq!(file.read(cx).session_owner(), "chat-a");
            assert!(file.read(cx).is_current_target(cx));
            shell.panel_key(cx)
        })
        .unwrap();

    let mut opened = None;
    for anchor in ["installation", "examples"] {
        file.update(cx, |_, cx| {
            cx.emit(FilesEvent::OpenFileAtAnchor {
                path: "guide.md".into(),
                anchor: anchor.into(),
            });
        });
        cx.run_until_parked();
        destination
            .read_with(cx, |shell, cx| {
                let id =
                    shell.file_surface_keys[&(owner.clone(), "chat-a".into(), "guide.md".into())];
                let target = &shell.file_surfaces[&id];
                assert_eq!(
                    target.read(cx).test_pending_markdown_anchor(),
                    Some(("guide.md".into(), anchor.into()))
                );
                assert_eq!(target.read(cx).session_owner(), "chat-a");
                if let Some(previous) = opened.replace(target.entity_id()) {
                    assert_eq!(previous, target.entity_id(), "reuse the same editor");
                }
                assert_eq!(shell.file_surfaces.len(), 2);
                assert!(shell.workspace_panels.resource_owner.is_none());
                assert!(shell.workspace_panels.resource_engine_owner.is_none());
            })
            .unwrap();
        source
            .read_with(cx, |shell, _| assert!(shell.file_surfaces.is_empty()))
            .unwrap();
    }

    // Queued link events must be rejected after hiding the source or before
    // the editor has accepted a changed checkout target.
    for stale_target in [false, true] {
        destination
            .update(cx, |shell, _, cx| {
                shell.route = if stale_target {
                    Route::Chat
                } else {
                    Route::Settings(SettingsSection::Appearance)
                };
                if stale_target {
                    shell.state.update(cx, |state, _| {
                        state
                            .chats
                            .iter_mut()
                            .find(|chat| chat.id == "chat-a")
                            .unwrap()
                            .cwd =
                            Some(dir.path().join("changed-checkout").to_string_lossy().into());
                    });
                    assert!(!file.read(cx).is_current_target(cx));
                }
            })
            .unwrap();
        file.update(cx, |_, cx| {
            cx.emit(FilesEvent::OpenFileAtAnchor {
                path: "must-not-open.md".into(),
                anchor: "ignored".into(),
            });
        });
        cx.run_until_parked();
        destination
            .read_with(cx, |shell, _| {
                assert_eq!(shell.file_surfaces.len(), 2);
                assert!(shell.workspace_panels.resource_owner.is_none());
                assert!(shell.workspace_panels.resource_engine_owner.is_none());
            })
            .unwrap();
    }
}

#[gpui::test]
fn window_transfer_rejected_queue_edit_preserves_source_and_window_count(cx: &mut TestAppContext) {
    let (_dir, source) = setup(cx);
    source
        .update(cx, |shell, _, cx| {
            shell.composer.update(cx, |composer, _| {
                composer.queue_edit_pending_id = Some("queued-row".into());
            })
        })
        .unwrap();
    let before = cx.update(|cx| cx.windows().len());
    let result = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(
                0,
                PanelTab::Chat("chat-a".into()),
                None,
                window,
                cx,
            )
        })
        .unwrap();
    assert!(result.is_err());
    assert_eq!(cx.update(|cx| cx.windows().len()), before);
    source
        .read_with(cx, |shell, cx| {
            assert_eq!(shell.panel_layout(cx).unwrap().panels[0].tabs.len(), 2);
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
}

#[gpui::test]
fn window_transfer_inactive_chat_moves_its_draft_without_overwriting_source_input(
    cx: &mut TestAppContext,
) {
    let (_dir, source) = setup(cx);
    source
        .update(cx, |shell, window, cx| {
            shell.focus_workspace_tab(0, PanelTab::Chat("chat-b".into()), window, cx);
        })
        .unwrap();
    source
        .update(cx, |shell, _, cx| {
            shell.composer.update(cx, |composer, cx| {
                composer.input.update(cx, |input, cx| {
                    input.set_text("Keep the source chat's input", cx)
                });
            });
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(
                0,
                PanelTab::Chat("chat-a".into()),
                None,
                window,
                cx,
            )
        })
        .unwrap()
        .unwrap();
    destination
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    source
        .read_with(cx, |shell, cx| {
            let composer = shell.composer.read(cx);
            assert!(composer.parked_chat_input("chat-a", cx).text.is_empty());
            assert_eq!(
                composer.parked_chat_input("chat-b", cx).text,
                "Keep the source chat's input"
            );
        })
        .unwrap();
}

#[gpui::test]
fn window_transfer_last_blank_tab_leaves_one_empty_source_panel(cx: &mut TestAppContext) {
    let (_dir, source) = setup(cx);
    source
        .update(cx, |shell, _, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::New(11)];
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
            shell
                .workspace_panels
                .drafts
                .insert(11, crate::pickers::CanvasDraft::default());
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, PanelTab::New(11), None, window, cx)
        })
        .unwrap()
        .unwrap();
    source
        .read_with(cx, |shell, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 1);
            assert!(layout.panels[0].tabs.is_empty());
            assert!(shell.state.read(cx).selected_chat.is_none());
        })
        .unwrap();
    destination
        .read_with(cx, |shell, cx| {
            let tabs = &shell.panel_layout(cx).unwrap().panels[0].tabs;
            assert_eq!(tabs.len(), 1);
            assert!(matches!(tabs[0], PanelTab::New(_)));
        })
        .unwrap();
}

#[gpui::test]
fn window_transfer_draft_keeps_selection_and_clears_source_appshots(cx: &mut TestAppContext) {
    use gpui::EntityInputHandler as _;
    let (_dir, source) = setup(cx);
    let shot = crate::appshots::tests::shot();
    source
        .update(cx, |shell, window, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::Draft(11)];
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
            shell
                .workspace_panels
                .drafts
                .insert(11, crate::pickers::CanvasDraft::default());
            shell.composer.update(cx, |composer, cx| {
                composer.current_key.clear();
                composer.input.update(cx, |input, cx| {
                    input.set_text("", cx);
                    input.replace_and_mark_text_in_range(
                        None,
                        "A transfer draft",
                        Some(2..7),
                        window,
                        cx,
                    );
                    input.unmark_text(window, cx);
                });
                composer.stage_appshot_for(String::new(), shot.clone(), cx);
            });
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, PanelTab::Draft(11), None, window, cx)
        })
        .unwrap()
        .unwrap();
    destination
        .update(cx, |shell, window, cx| {
            shell.composer.update(cx, |composer, cx| {
                assert_eq!(composer.parked_chat_input("", cx).text, "A transfer draft");
                assert_eq!(composer.staged_appshots()[0].id, shot.id);
                let selection = composer.input.update(cx, |input, cx| {
                    input.selected_text_range(false, window, cx).unwrap()
                });
                assert_eq!(selection.range, 2..7);
            });
        })
        .unwrap();
    source
        .read_with(cx, |shell, cx| {
            assert!(shell.composer.read(cx).staged_appshots().is_empty());
        })
        .unwrap();
}

#[gpui::test]
fn window_transfer_bound_review_adopts_origin_comments_when_another_chat_is_selected(
    cx: &mut TestAppContext,
) {
    use crate::comments::{CommentSide, ReviewComment};

    let (_dir, source) = setup(cx);
    let origin_note = ReviewComment::new(
        "src/origin.rs",
        CommentSide::New,
        3,
        "Keep this review note",
    );
    let other_note = ReviewComment::new(
        "src/other.rs",
        CommentSide::New,
        8,
        "Leave the other chat alone",
    );
    let (tab, changes) = source
        .update(cx, |shell, window, cx| {
            let changes = cx.new(|cx| {
                let mut changes = Changes::new(shell.state.clone(), cx);
                changes.review_working_tree("chat-a".into(), cx);
                changes
            });
            shell.focus_workspace_tab(0, PanelTab::Chat("chat-b".into()), window, cx);
            shell.state.update(cx, |state, cx| {
                state.add_review_comment("chat-a", origin_note.clone());
                state.add_review_comment("chat-b", other_note.clone());
                cx.notify();
            });
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-b")
            );
            assert_eq!(
                changes.read(cx).context_chat_id(cx).as_deref(),
                Some("chat-a")
            );
            shell.diff_seq = 11;
            shell.diffs.insert(11, changes.clone());
            let tab = PanelTab::Surface {
                owner: shell.panel_key(cx),
                surface: RightSurface::Diff(11),
            };
            install_resource(shell, tab.clone(), cx);
            (tab, changes)
        })
        .unwrap();
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, tab, None, window, cx)
        })
        .unwrap()
        .unwrap();
    destination
        .read_with(cx, |shell, cx| {
            let moved = shell.diffs.values().next().expect("review tab moved");
            assert_eq!(moved.entity_id(), changes.entity_id());
            assert_eq!(
                moved.read(cx).context_chat_id(cx).as_deref(),
                Some("chat-a")
            );
            let state = shell.state.read(cx);
            assert_eq!(state.selected_chat.as_deref(), Some("chat-a"));
            assert_eq!(state.review_comments("chat-a"), &[origin_note.clone()]);
            assert!(
                state.review_comments("chat-b").is_empty(),
                "the destination must not adopt the unrelated selected chat's comments"
            );
        })
        .unwrap();
    source
        .read_with(cx, |shell, cx| {
            assert!(shell.diffs.is_empty());
            let state = shell.state.read(cx);
            assert_eq!(state.selected_chat.as_deref(), Some("chat-b"));
            assert_eq!(state.review_comments("chat-b"), &[other_note]);
            assert_eq!(state.review_comments("chat-a"), &[origin_note]);
        })
        .unwrap();
}
