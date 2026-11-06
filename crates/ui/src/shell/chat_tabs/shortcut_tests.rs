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
                    assert!(matches!(selected, workspace_panels::PanelTab::Draft(_)));
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
fn pane_cycle_shortcuts_move_between_panels_and_wrap(cx: &mut gpui::TestAppContext) {
    let (next, previous) = if cfg!(target_os = "macos") {
        ("mod-]", "mod-[")
    } else {
        ("ctrl-super-]", "ctrl-super-[")
    };
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    let panels = window
        .update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.sync_panel_workspace(cx);
            for chat in ["peer", "target"] {
                shell.workspace_split(SplitAxis::Horizontal, cx);
                let layout = shell.panel_layout_mut(cx);
                let focused = layout.focused;
                let panel = layout.panels.iter_mut().find(|panel| panel.id == focused);
                let panel = panel.unwrap();
                panel.tabs = vec![workspace_panels::PanelTab::Chat(chat.into())];
                panel.active = 0;
            }
            let layout = shell.panel_layout(cx).unwrap();
            let ids: Vec<_> = layout.panels.iter().map(|panel| panel.id).collect();
            let first = workspace_panels::PanelTab::Chat("current".into());
            shell.focus_workspace_tab(ids[0], first, window, cx);
            ids
        })
        .unwrap();
    assert_eq!(panels.len(), 3);
    let focus = |cx: &mut gpui::TestAppContext| {
        window
            .update(cx, |shell, _, cx| {
                (
                    shell.panel_layout(cx).unwrap().focused,
                    shell.state.read(cx).selected_chat.clone(),
                )
            })
            .unwrap()
    };
    let at = |panel: usize, chat: &str| (panels[panel], Some(chat.to_string()));

    test_support::press(cx, window, next);
    assert_eq!(focus(cx), at(1, "peer"));
    test_support::press(cx, window, next);
    assert_eq!(focus(cx), at(2, "target"));
    test_support::press(cx, window, next);
    assert_eq!(focus(cx), at(0, "current"), "wraps past the last panel");
    test_support::press(cx, window, previous);
    assert_eq!(focus(cx), at(2, "target"), "wraps before the first panel");
    test_support::press(cx, window, previous);
    assert_eq!(focus(cx), at(1, "peer"));

    // A zoomed panel fills the window, so moving on has to bring the next one
    // with it. Otherwise the keyboard lands somewhere you can't see.
    window
        .update(cx, |shell, _, cx| shell.workspace_zoom(cx))
        .unwrap();
    test_support::press(cx, window, next);
    assert_eq!(focus(cx), at(2, "target"));
    window
        .update(cx, |shell, _, cx| {
            assert_eq!(shell.panel_layout(cx).unwrap().expanded, Some(panels[2]));
        })
        .unwrap();
}

#[gpui::test]
fn a_reply_to_a_selection_joins_the_open_chats_draft_and_sends_nothing(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, _, cx| {
            shell
                .composer
                .update(cx, |composer, cx| composer.prefill("half-typed".into(), cx));
            let transcript = shell.transcript.clone();
            shell.on_transcript_event(
                transcript.clone(),
                &TranscriptEvent::ReplyToSelection {
                    chat_id: "peer".into(),
                    text: "from another chat".into(),
                },
                cx,
            );
            assert_eq!(shell.composer.read(cx).input.read(cx).text(), "half-typed");
            shell.on_transcript_event(
                transcript,
                &TranscriptEvent::ReplyToSelection {
                    chat_id: "current".into(),
                    text: "two\nlines".into(),
                },
                cx,
            );
            assert_eq!(
                shell.composer.read(cx).input.read(cx).text(),
                "half-typed\n\n> two\n> lines\n\n"
            );
            assert!(
                shell.state.read(cx).transcript.is_empty(),
                "nothing was sent"
            );
        })
        .unwrap();
}

/// Two sessions in project A and one in project B, each showing one chat.
fn seed_sessions(shell: &mut Shell, cx: &mut Context<Shell>) {
    shell.boot_restored = true;
    shell.ensure_workspace_sessions(cx);
    shell.chat_tabs.clear();
    for (id, project, chat) in [
        ("one", "a", "current"),
        ("two", "a", "peer"),
        ("three", "b", "target"),
    ] {
        shell.chat_tabs.push(ChatTab {
            id: id.into(),
            title: Some(id.into()),
            project: Some(project.into()),
            selected: Some(chat.into()),
            ..Default::default()
        });
        let mut layout = workspace_panels::WorkspaceLayout::default();
        layout.panels[0].tabs = vec![workspace_panels::PanelTab::Chat(chat.into())];
        shell.workspace_panels.layouts.insert(id.into(), layout);
    }
    shell.chat_tab = 0;
}

fn active_session(shell: &Shell) -> &str {
    &shell.chat_tabs[shell.chat_tab].id
}

#[gpui::test]
fn session_jump_shortcuts_stay_in_the_current_project(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            seed_sessions(shell, cx);
            shell.jump_to_session(1, window, cx);
            assert_eq!(active_session(shell), "two");
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
            // Slot 2 would be project B's session, which this list doesn't show.
            shell.jump_to_session(2, window, cx);
            assert_eq!(active_session(shell), "two");
        })
        .unwrap();
}

#[gpui::test]
fn session_cycle_stays_scoped_and_project_cycle_restores_selection(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            seed_sessions(shell, cx);
            shell.cycle_session(true, window, cx);
            assert_eq!(active_session(shell), "two");
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            // Wraps within project A rather than reaching project B.
            shell.cycle_session(true, window, cx);
            assert_eq!(active_session(shell), "one");
            shell.cycle_session(false, window, cx);
            assert_eq!(active_session(shell), "two");
            shell.cycle_chat_tab(true, window, cx);
            assert_eq!(active_session(shell), "three");
            assert_eq!(shell.settings.space_filter.as_deref(), Some("b"));
            shell.cycle_chat_tab(false, window, cx);
            assert_eq!(active_session(shell), "two");
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
            assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
        })
        .unwrap();
}
