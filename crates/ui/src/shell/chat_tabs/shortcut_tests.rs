use super::*;

#[gpui::test]
fn new_tab_shortcut_stays_in_the_focused_panel_and_session(cx: &mut gpui::TestAppContext) {
    for combo in [
        crate::settings::ShortcutId::NewSession.default_combo(),
        "mod-alt-t",
    ] {
        let (_dir, window) = navigation_tests::fixture(cx, false, None);
        let (session, session_count, focused, tab_count, other_panels) = window
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                shell.workspace_split(SplitAxis::Horizontal, cx);
                shell.settings.keymap.new_session = combo.into();
                apply_keymap(
                    cx,
                    &shell.settings.keymap,
                    shell.settings.composer_send_behavior,
                );
                window.activate_window();
                let layout = shell.panel_layout(cx).unwrap();
                let focused = layout.focused;
                (
                    shell.chat_tabs[shell.chat_tab].id.clone(),
                    shell.chat_tabs.len(),
                    focused,
                    layout
                        .panels
                        .iter()
                        .find(|panel| panel.id == focused)
                        .unwrap()
                        .tabs
                        .len(),
                    layout
                        .panels
                        .iter()
                        .filter(|panel| panel.id != focused)
                        .map(|panel| (panel.id, panel.tabs.clone()))
                        .collect::<Vec<_>>(),
                )
            })
            .unwrap();
        let mut previous = None;
        for (ix, editor_focused) in [true, false].into_iter().enumerate() {
            window
                .update(cx, |shell, window, cx| {
                    let focus = if editor_focused {
                        shell.composer.focus_handle(cx)
                    } else {
                        shell.shortcut_focus.clone()
                    };
                    window.focus(&focus, cx);
                })
                .unwrap();
            cx.update_window(window.into(), |_, window, cx| window.draw(cx).clear())
                .unwrap();
            cx.simulate_keystrokes(window.into(), &platform_combo(combo));
            cx.run_until_parked();
            window
                .update(cx, |shell, _, cx| {
                    assert_eq!(shell.chat_tabs.len(), session_count);
                    assert_eq!(shell.chat_tabs[shell.chat_tab].id, session);
                    let layout = shell.panel_layout(cx).unwrap();
                    assert_eq!(layout.focused, focused);
                    let panel = layout
                        .panels
                        .iter()
                        .find(|panel| panel.id == focused)
                        .unwrap();
                    assert_eq!(panel.tabs.len(), tab_count + ix + 1);
                    let selected = panel.selected().cloned().unwrap();
                    assert!(matches!(selected, workspace_panels::PanelTab::New(_)));
                    assert_ne!(
                        previous.as_ref(),
                        Some(&selected),
                        "each shortcut creates its own tab"
                    );
                    previous = Some(selected);
                    for (id, tabs) in &other_panels {
                        assert_eq!(
                            &layout
                                .panels
                                .iter()
                                .find(|panel| panel.id == *id)
                                .unwrap()
                                .tabs,
                            tabs
                        );
                    }
                    assert!(
                        shell.workspace_panels.menu.is_none(),
                        "tab choices belong inside the panel"
                    );
                })
                .unwrap();
        }
        window
            .update(cx, |_, window, _| window.remove_window())
            .unwrap();
    }
}

#[gpui::test]
fn session_jump_shortcuts_stay_in_the_current_project(cx: &mut gpui::TestAppContext) {
    for split in [false, true] {
        let (_dir, window) = navigation_tests::fixture(cx, split, None);
        window
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                shell.persist_chat_tabs(cx);
                let slot = shell
                    .sidebar_visible_order(cx)
                    .iter()
                    .position(|id| id == "peer")
                    .unwrap();
                shell.jump_to_session(slot, window, cx);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                assert_eq!(shell.chat_tab_labels(cx), [SharedString::from("A")]);
                assert_eq!(shell.chat_tabs.len(), 1);
                assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
            })
            .unwrap();
    }
}

#[gpui::test]
fn session_cycle_stays_scoped_and_project_cycle_restores_selection(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.persist_chat_tabs(cx);
            shell.cycle_session(true, window, cx);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            assert_eq!(shell.chat_tabs.len(), 1);
            shell.open_project_tab(Some("b".into()), cx);
            shell.cycle_chat_tab(false, window, cx);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
            shell.cycle_chat_tab(true, window, cx);
            assert_eq!(shell.settings.space_filter.as_deref(), Some("b"));
        })
        .unwrap();
}
