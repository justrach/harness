use super::*;

pub(super) fn workspace_layouts(
    shell: &Shell,
    cx: &App,
) -> std::collections::BTreeMap<String, Option<settings::SavedWorkspacePanels>> {
    shell
        .workspace_panels
        .layouts
        .keys()
        .map(|id| (id.clone(), shell.saved_workspace_panels(id, cx)))
        .collect()
}

#[derive(Clone, Copy)]
enum EarlyChoice {
    NewSession,
    NewTab,
    Split(SplitAxis),
}

pub(super) fn cold_start(
    cx: &mut gpui::TestAppContext,
    saved: settings::UiSettings,
) -> (tempfile::TempDir, gpui::WindowHandle<Shell>) {
    let (dir, window) = fixture(cx, false, None);
    window
        .update(cx, |shell, _, cx| {
            shell.settings = saved;
            shell.boot_restored = false;
            shell.state.update(cx, |state, cx| {
                state.select_chat(None, cx);
                // Model the untouched boot canvas, not an explicit user choice.
                state.auto_selected = false;
                state.chats_synced = false;
                for chat in &mut state.chats {
                    chat.archived = true;
                }
            });
        })
        .unwrap();
    (dir, window)
}

pub(super) fn saved_reference() -> settings::UiSettings {
    let mut saved = settings::UiSettings::default();
    saved.last_chat_id = Some("current".into());
    saved.chat_layout = Some(
        ChatSplit::split(None, SplitAxis::Horizontal, Some("peer".into()), None)
            .unwrap()
            .to_saved(),
    );
    saved
}

fn assert_early_choice_wins(cx: &mut gpui::TestAppContext, choice: EarlyChoice) {
    let (_dir, window) = cold_start(cx, saved_reference());
    let (layout, tabs, panels) = window
        .update(cx, |shell, window, cx| {
            match choice {
                EarlyChoice::NewSession => shell.open_new_session(cx),
                EarlyChoice::NewTab => shell.new_chat_tab(None, window, cx),
                EarlyChoice::Split(axis) => shell.split_chat(axis, window, cx),
            }
            // The new workspace identity is allocated lazily; establish it
            // before comparing placement across the arriving catalogue.
            shell.ensure_workspace_sessions(cx);
            let expected = (
                shell.chat_split.clone(),
                shell.chat_tabs.len(),
                workspace_layouts(shell, cx),
            );
            shell.state.update(cx, |state, cx| {
                state.apply_chats(state.chats.clone());
                cx.notify();
            });
            expected
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |shell, _, cx| {
            assert!(shell.boot_restored);
            assert!(
                shell.state.read(cx).selected_chat.is_none(),
                "late startup restoration must not override an explicit canvas choice"
            );
            assert_eq!(
                shell.chat_split, layout,
                "late sync must keep the layout the user just opened"
            );
            assert_eq!(shell.chat_tabs.len(), tabs);
            assert_eq!(
                workspace_layouts(shell, cx),
                panels,
                "late sync must preserve the new workspace panels"
            );
            assert!(shell.peer_chat_views.is_empty());
            assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
        })
        .unwrap();
}

#[gpui::test]
fn new_session_before_initial_sync_overrides_saved_archive(cx: &mut gpui::TestAppContext) {
    assert_early_choice_wins(cx, EarlyChoice::NewSession);
}

#[gpui::test]
fn new_tab_before_initial_sync_overrides_saved_archive(cx: &mut gpui::TestAppContext) {
    assert_early_choice_wins(cx, EarlyChoice::NewTab);
}

#[gpui::test]
fn new_split_before_initial_sync_overrides_saved_archive(cx: &mut gpui::TestAppContext) {
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        assert_early_choice_wins(cx, EarlyChoice::Split(axis));
    }
}

#[gpui::test]
fn selecting_archived_reference_before_sync_overrides_saved_layout(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = cold_start(cx, saved_reference());
    window
        .update(cx, |shell, window, cx| {
            shell.open_chat_in_tab("target".into(), window, cx);
            shell.state.update(cx, |state, cx| {
                state.apply_chats(state.chats.clone());
                cx.notify();
            });
        })
        .unwrap();
    cx.run_until_parked();
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("target")
            );
            assert!(shell.state.read(cx).selected_chat_row().unwrap().archived);
            assert!(shell.chat_split.is_none());
            assert!(shell.peer_chat_views.is_empty());
        })
        .unwrap();
}

#[gpui::test]
fn archived_legacy_layout_restores_from_disk_at_every_focus(cx: &mut gpui::TestAppContext) {
    let ids = [Some("current"), Some("peer"), Some("target"), None];
    for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
        for (focus, selected) in ids.into_iter().enumerate() {
            // Seed a file written by the old split UI. Calling its retained
            // creation/focus helpers on a live workspace mixes two owners of
            // the selected conversation and does not model an upgrade.
            let dir = tempfile::tempdir().unwrap();
            let mut saved = settings::UiSettings::default();
            saved.last_chat_id = selected.map(str::to_owned);
            saved.chat_layout = Some(settings::SavedChatLayout {
                vertical: axis == SplitAxis::Vertical,
                panes: ids
                    .iter()
                    .enumerate()
                    .map(|(ix, id)| {
                        if ix == focus {
                            None
                        } else {
                            id.map(str::to_owned)
                        }
                    })
                    .collect(),
                focus,
                shares: vec![0.25, 0.33, 0.17, 0.25],
                projects: vec![Some("a".into()); 4],
            });
            saved.save(dir.path()).unwrap();
            let loaded = settings::UiSettings::load(dir.path());
            assert_eq!(loaded.last_chat_id, saved.last_chat_id);
            assert_eq!(loaded.chat_layout, saved.chat_layout);
            let (_restart_dir, restored) = cold_start(cx, loaded);
            restored
                .update(cx, |shell, _, cx| {
                    shell.state.update(cx, |state, cx| {
                        state.apply_chats(state.chats.clone());
                        cx.notify();
                    });
                })
                .unwrap();
            cx.run_until_parked();
            restored
                .update(cx, |shell, _, cx| {
                    assert_eq!(shell.state.read(cx).selected_chat.as_deref(), selected);
                    let layout = shell.chat_split.as_ref().unwrap();
                    assert_eq!(layout.axis, axis);
                    assert_eq!(layout.focus, focus);
                    assert_eq!(layout.panes.len(), 4);
                    for (ix, expected) in ids.into_iter().enumerate() {
                        assert_eq!(
                            layout.panes[ix].as_deref(),
                            if ix == focus { None } else { expected }
                        );
                    }
                    for (actual, expected) in layout
                        .shares
                        .iter()
                        .zip(&saved.chat_layout.as_ref().unwrap().shares)
                    {
                        assert!((actual - expected).abs() < 1e-6);
                    }
                    assert!(shell.state.read(cx).chats.iter().all(|chat| chat.archived));
                    assert_eq!(shell.state.read(cx).visible_chats().count(), 0);
                })
                .unwrap();
        }
    }
}

#[gpui::test]
fn legacy_saved_layout_migration_preserves_displayed_panel_geometry(cx: &mut gpui::TestAppContext) {
    let mut saved = saved_reference();
    saved.chat_layout = Some(settings::SavedChatLayout {
        vertical: true,
        panes: vec![Some("peer".into()), None, None],
        focus: 1,
        shares: vec![0.2, 0.5, 0.3],
        projects: vec![Some("a".into()); 3],
    });
    let (_dir, window) = cold_start(cx, saved);
    window
        .update(cx, |shell, _, cx| {
            shell.viewport_height = 2400.0;
            shell.state.update(cx, |state, cx| {
                state.apply_chats(state.chats.clone());
                cx.notify();
            });
            shell.boot_select_chat(cx);
            shell.sync_panel_workspace(cx);
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(
                layout.axis,
                SplitAxis::Vertical,
                "upgrading old settings must preserve the displayed split direction"
            );
            assert_eq!(
                layout.panels.len(),
                3,
                "an intentionally empty saved pane must remain available"
            );
            assert_eq!(
                layout.panels[0].selected(),
                Some(&crate::shell::workspace_panels::PanelTab::Chat(
                    "peer".into()
                ))
            );
            assert_eq!(
                layout.panels[1].selected(),
                Some(&crate::shell::workspace_panels::PanelTab::Chat(
                    "current".into()
                ))
            );
            assert_eq!(layout.focused, layout.panels[1].id);
            for (panel, expected) in layout.panels.iter().zip([0.2, 0.5, 0.3]) {
                assert!(
                    (panel.share - expected).abs() < 1e-6,
                    "saved pane proportions must survive migration"
                );
            }
        })
        .unwrap();
}

#[gpui::test]
fn legacy_saved_workspaces_preserve_unknown_chats_and_blank_duplicate_slots(
    cx: &mut gpui::TestAppContext,
) {
    let mut saved = saved_reference();
    saved.chat_tabs = vec![settings::SavedChatTab {
        id: "legacy-workspace".into(),
        selected: Some("current".into()),
        project: Some("a".into()),
        layout: Some(settings::SavedChatLayout {
            vertical: true,
            panes: vec![Some("current".into()), Some("offline-chat".into()), None],
            focus: 2,
            shares: vec![0.2, 0.3, 0.5],
            projects: vec![Some("a".into()); 3],
        }),
        ..Default::default()
    }];
    let (_dir, window) = cold_start(cx, saved);
    window
        .update(cx, |shell, _, cx| {
            shell.viewport_height = 2400.0;
            shell
                .state
                .update(cx, |state, _| state.apply_chats(state.chats.clone()));
            shell.boot_select_chat(cx);
            shell.sync_panel_workspace(cx);
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.axis, SplitAxis::Vertical);
            assert_eq!(layout.panels.len(), 3);
            assert_eq!(layout.focused, layout.panels[2].id);
            assert!(matches!(
                layout.panels[0].selected(),
                Some(crate::shell::workspace_panels::PanelTab::Draft(_))
            ));
            assert_eq!(
                workspace_chat_ids(shell, cx),
                vec!["offline-chat".to_owned(), "current".to_owned()]
            );
            for (panel, expected) in layout.panels.iter().zip([0.2, 0.3, 0.5]) {
                assert!((panel.share - expected).abs() < 1e-6);
            }
            // Existing small-window safeguards may combine panels but must keep
            // every chat and the draft that replaced a stale duplicate.
            shell.viewport_height = 600.0;
            shell.sync_panel_workspace(cx);
            let layout = shell.panel_layout(cx).unwrap();
            assert!(layout.panels.len() < 3);
            assert_eq!(
                workspace_chat_ids(shell, cx),
                vec!["offline-chat".to_owned(), "current".to_owned()]
            );
            assert!(
                layout
                    .panels
                    .iter()
                    .flat_map(|panel| &panel.tabs)
                    .any(|tab| matches!(tab, crate::shell::workspace_panels::PanelTab::Draft(_)))
            );
        })
        .unwrap();
}

#[gpui::test]
fn current_saved_workspace_layout_takes_precedence_over_legacy_peers(
    cx: &mut gpui::TestAppContext,
) {
    let current = settings::SavedWorkspacePanels {
        panels: vec![settings::SavedWorkspacePanel {
            id: 42,
            tabs: vec![settings::SavedPanelTab::Chat {
                id: "current".into(),
            }],
            active: 0,
            share: 1.0,
            new_panel_target: None,
        }],
        focused: 42,
        ..Default::default()
    };
    let mut saved = saved_reference();
    saved.chat_tabs = vec![settings::SavedChatTab {
        id: "current-workspace".into(),
        selected: Some("current".into()),
        project: Some("a".into()),
        layout: saved.chat_layout.clone(),
        panel_layout: Some(current.clone()),
        ..Default::default()
    }];
    let (_dir, window) = cold_start(cx, saved);
    window
        .update(cx, |shell, _, cx| {
            shell
                .state
                .update(cx, |state, _| state.apply_chats(state.chats.clone()));
            shell.boot_select_chat(cx);
            for _ in 0..3 {
                shell.sync_panel_workspace(cx);
            }
            assert_eq!(
                shell.saved_workspace_panels("current-workspace", cx),
                Some(current)
            );
            assert_eq!(workspace_chat_ids(shell, cx), vec!["current".to_owned()]);
            assert!(
                shell.chat_split.is_none(),
                "old peer references must not reappear later"
            );
        })
        .unwrap();
}
