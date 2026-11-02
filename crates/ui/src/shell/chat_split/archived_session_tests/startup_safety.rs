use super::persistence::{cold_start, saved_reference};
use super::*;

#[gpui::test]
fn typing_on_boot_canvas_prevents_late_archive_restoration(cx: &mut gpui::TestAppContext) {
    for text in ["A new question", " ", "First line\nSecond line"] {
        let (_dir, window) = cold_start(cx, saved_reference());
        window
            .update(cx, |shell, _, cx| {
                shell.composer.update(cx, |composer, cx| {
                    composer
                        .input
                        .update(cx, |input, cx| input.set_text(text, cx));
                });
            })
            .unwrap();
        cx.run_until_parked();
        complete_initial_sync(window, cx);
        window
            .update(cx, |shell, _, cx| {
                assert!(
                    shell.state.read(cx).selected_chat.is_none(),
                    "a draft on the boot canvas is new-session intent"
                );
                assert_eq!(shell.composer.read(cx).input.read(cx).text(), text);
                assert!(shell.chat_split.is_none());
                assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
            })
            .unwrap();
    }
}

#[gpui::test]
fn staged_file_on_boot_canvas_prevents_late_archive_restoration(cx: &mut gpui::TestAppContext) {
    for image in [false, true] {
        let (dir, window) = cold_start(cx, saved_reference());
        let path = dir
            .path()
            .join(if image { "draft.png" } else { "draft.txt" });
        if image {
            image::RgbaImage::from_pixel(2, 2, image::Rgba([20, 40, 80, 255]))
                .save(&path)
                .unwrap();
        } else {
            std::fs::write(&path, "A file for a new conversation").unwrap();
        }
        let attachment = window
            .update(cx, |shell, _, cx| {
                shell
                    .composer
                    .update(cx, |composer, cx| composer.add_paths(vec![path], cx));
                let composer = shell.composer.read(cx);
                assert_eq!(composer.staged().len(), 1);
                composer.staged()[0].id.clone()
            })
            .unwrap();
        complete_initial_sync(window, cx);
        window
            .update(cx, |shell, _, cx| {
                assert!(
                    shell.state.read(cx).selected_chat.is_none(),
                    "staging content must keep the new-session canvas selected"
                );
                let composer = shell.composer.read(cx);
                assert_eq!(composer.staged().len(), 1);
                assert_eq!(composer.staged()[0].id, attachment);
                assert!(shell.chat_split.is_none());
                assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
            })
            .unwrap();
    }
}

#[gpui::test]
fn failed_or_empty_file_staging_does_not_suppress_archive_restoration(
    cx: &mut gpui::TestAppContext,
) {
    for missing in [false, true] {
        let (dir, window) = cold_start(cx, saved_reference());
        window
            .update(cx, |shell, _, cx| {
                let paths = if missing {
                    vec![dir.path().join("missing.txt")]
                } else {
                    vec![]
                };
                shell
                    .composer
                    .update(cx, |composer, cx| composer.add_paths(paths, cx));
                assert!(shell.composer.read(cx).staged().is_empty());
            })
            .unwrap();
        complete_initial_sync(window, cx);
        window
            .update(cx, |shell, _, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
                assert_eq!(
                    shell.chat_split.as_ref().unwrap().panes[0].as_deref(),
                    Some("peer")
                );
            })
            .unwrap();
    }
}

#[gpui::test]
fn appshot_on_boot_canvas_prevents_late_archive_restoration(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = cold_start(cx, saved_reference());
    let shot = crate::appshots::tests::shot();
    window
        .update(cx, |shell, _, cx| {
            shell
                .composer
                .update(cx, |composer, cx| composer.stage_appshot(shot.clone(), cx));
        })
        .unwrap();
    complete_initial_sync(window, cx);
    window
        .update(cx, |shell, _, cx| {
            assert!(shell.state.read(cx).selected_chat.is_none());
            let composer = shell.composer.read(cx);
            assert_eq!(composer.staged_appshots().len(), 1);
            assert_eq!(composer.staged_appshots()[0].id, shot.id);
            assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
        })
        .unwrap();
}

#[gpui::test]
fn stale_saved_peer_cannot_duplicate_the_focused_archived_session(cx: &mut gpui::TestAppContext) {
    let mut saved = saved_reference();
    saved.chat_layout.as_mut().unwrap().panes[0] = Some("current".into());
    let (_dir, window) = cold_start(cx, saved);
    complete_initial_sync(window, cx);
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            shell.sync_panel_workspace(cx);
            let displayed = workspace_chat_ids(shell, cx);
            assert_eq!(
                displayed,
                vec!["current".to_owned()],
                "migration must display the focused conversation only once"
            );
            assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
        })
        .unwrap();
}

#[gpui::test]
fn duplicate_saved_peers_restore_at_most_one_view_each(cx: &mut gpui::TestAppContext) {
    for vertical in [false, true] {
        for focus in 0..4 {
            for selected in [Some("current"), Some("peer"), None] {
                let mut saved = saved_reference();
                saved.last_chat_id = selected.map(str::to_owned);
                saved.chat_layout = Some(settings::SavedChatLayout {
                    vertical,
                    panes: vec![
                        Some("peer".into()),
                        Some("peer".into()),
                        Some("target".into()),
                        None,
                    ],
                    focus,
                    shares: vec![0.25; 4],
                    projects: vec![],
                });
                let (_dir, window) = cold_start(cx, saved);
                complete_initial_sync(window, cx);
                window
                    .update(cx, |shell, _, cx| {
                        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), selected);
                        shell.sync_panel_workspace(cx);
                        let views = workspace_chat_ids(shell, cx);
                        let unique: std::collections::HashSet<_> =
                            views.iter().map(String::as_str).collect();
                        assert_eq!(
                            views.len(),
                            unique.len(),
                            "one session must not occupy multiple restored panes"
                        );
                        // Repair must retain other live references, not erase the layout.
                        assert!(unique.contains("peer"));
                        assert_eq!(unique.contains("target"), focus != 2);
                        assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
                    })
                    .unwrap();
            }
        }
    }
}

#[gpui::test]
fn unavailable_and_archived_chats_survive_repeated_disk_restarts(cx: &mut gpui::TestAppContext) {
    let mut saved = saved_reference();
    for _ in 0..3 {
        let (dir, window) = cold_start(cx, saved);
        // A remote device's absent row is not a confirmed deletion.
        window
            .update(cx, |shell, _, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats.retain(|chat| chat.id != "current");
                });
            })
            .unwrap();
        complete_initial_sync(window, cx);
        saved = window
            .update(cx, |shell, _, cx| {
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                shell.sync_panel_workspace(cx);
                let mut chats = workspace_chat_ids(shell, cx);
                chats.sort();
                assert_eq!(chats, vec!["current".to_owned(), "peer".to_owned()]);
                assert!(shell.state.read(cx).chat_row("peer").unwrap().archived);
                shell.persist_chat_tabs(cx);
                shell.settings.clone()
            })
            .unwrap();
        saved.save(dir.path()).unwrap();
        saved = settings::UiSettings::load(dir.path());
    }
}

#[gpui::test]
fn early_startup_choice_replaces_stale_layout_on_disk(cx: &mut gpui::TestAppContext) {
    fn persisted_workspace_layouts(
        shell: &Shell,
        cx: &App,
    ) -> std::collections::BTreeMap<String, Option<settings::SavedWorkspacePanels>> {
        shell
            .chat_tabs
            .iter()
            .map(|tab| (tab.id.clone(), shell.saved_workspace_panels(&tab.id, cx)))
            .collect()
    }

    for choice in 0..4 {
        let (dir, window) = cold_start(cx, saved_reference());
        window
            .update(cx, |shell, window, cx| match choice {
                0 => shell.open_new_session(cx),
                1 => shell.new_chat_tab(None, window, cx),
                2 => shell.split_chat(SplitAxis::Vertical, window, cx),
                _ => shell.open_chat_in_tab("target".into(), window, cx),
            })
            .unwrap();
        complete_initial_sync(window, cx);
        let (saved, selected, layout) = window
            .update(cx, |shell, _, cx| {
                let layout = shell.chat_split.as_ref().map(ChatSplit::to_saved);
                assert_eq!(
                    shell.settings.chat_layout, layout,
                    "suppressed restoration must also replace the stale saved layout"
                );
                let selected = shell.state.read(cx).selected_chat.clone();
                assert_eq!(shell.settings.last_chat_id, selected);
                shell.sync_panel_workspace(cx);
                shell.persist_chat_tabs(cx);
                // The navigation fixture can retain a runtime layout under its
                // old project key. Only actual workspace identities are saved.
                let panels = persisted_workspace_layouts(shell, cx);
                let saved_panels: std::collections::BTreeMap<_, _> = shell
                    .settings
                    .chat_tabs
                    .iter()
                    .map(|tab| (tab.id.clone(), tab.panel_layout.clone()))
                    .collect();
                assert!(!saved_panels.contains_key("a"));
                assert_eq!(panels.len(), shell.chat_tabs.len());
                assert_eq!(saved_panels.len(), shell.settings.chat_tabs.len());
                assert_eq!(
                    panels, saved_panels,
                    "the saved settings must contain each complete workspace layout"
                );
                (shell.settings.clone(), selected, panels)
            })
            .unwrap();
        saved.save(dir.path()).unwrap();
        // A restart has only the restored window. Keeping the source alive
        // across a new SettingsStore mixes two independent fixture profiles.
        window
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        cx.run_until_parked();
        let (_restart_dir, restarted) = cold_start(cx, settings::UiSettings::load(dir.path()));
        complete_initial_sync(restarted, cx);
        restarted
            .update(cx, |shell, _, cx| {
                assert_eq!(shell.state.read(cx).selected_chat, selected);
                shell.sync_panel_workspace(cx);
                let restored = persisted_workspace_layouts(shell, cx);
                assert_eq!(restored.len(), shell.chat_tabs.len());
                assert_eq!(shell.chat_tabs.len(), saved.chat_tabs.len());
                assert_eq!(
                    restored, layout,
                    "the user's new workspace must survive the next restart"
                );
                assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
            })
            .unwrap();
        restarted
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
        cx.run_until_parked();
    }
}

#[gpui::test]
fn boot_canvas_draft_also_blocks_automatic_active_session_fallback(cx: &mut gpui::TestAppContext) {
    let mut saved = saved_reference();
    saved.last_chat_id = None;
    saved.chat_layout = None;
    let (_dir, window) = cold_start(cx, saved);
    window
        .update(cx, |shell, _, cx| {
            shell.state.update(cx, |state, _| {
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "target")
                    .unwrap()
                    .archived = false;
            });
            shell.composer.update(cx, |composer, cx| {
                composer.input.update(cx, |input, cx| {
                    input.set_text("A new conversation, not the most recent one", cx)
                });
            });
        })
        .unwrap();
    complete_initial_sync(window, cx);
    window
        .update(cx, |shell, _, cx| {
            assert!(shell.state.read(cx).selected_chat.is_none());
            assert_eq!(
                shell.composer.read(cx).input.read(cx).text(),
                "A new conversation, not the most recent one"
            );
            assert_eq!(shell.state.read(cx).visible_chats().count(), 1);
        })
        .unwrap();
}

fn complete_initial_sync(window: gpui::WindowHandle<Shell>, cx: &mut gpui::TestAppContext) {
    window
        .update(cx, |shell, _, cx| {
            shell.state.update(cx, |state, cx| {
                state.apply_chats(state.chats.clone());
                cx.notify();
            });
        })
        .unwrap();
    cx.run_until_parked();
}
