//! Shortcuts that must act on panels, not on the dock and right pane they replaced.
use super::*;
use crate::shell::chat_tabs::navigation_tests::fixture;

fn panel_shell(cx: &mut gpui::TestAppContext) -> (tempfile::TempDir, gpui::WindowHandle<Shell>) {
    let (dir, window) = fixture(cx, false, None);
    window
        .update(cx, |shell, _, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.sync_panel_workspace(cx);
        })
        .unwrap();
    (dir, window)
}

fn file_tab(shell: &Shell, id: u64, cx: &App) -> (u64, PanelTab) {
    let layout = shell.panel_layout(cx).unwrap();
    let tab = layout
        .panels
        .iter()
        .flat_map(|panel| &panel.tabs)
        .find(|tab| {
            matches!(tab, PanelTab::Surface { surface: RightSurface::File(open), .. } if *open == id)
        })
        .expect("the file has a panel tab")
        .clone();
    (layout.location(&tab).unwrap().0, tab)
}

#[gpui::test]
fn cmd_s_saves_the_file_on_screen_not_the_last_one_opened(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    window
        .update(cx, |shell, window, cx| {
            assert_eq!(shell.workspace_file_to_save(cx), None);
            shell.add_file_surface("/fixtures/a/first.rs".into(), window, cx);
            let first = shell.file_surface_seq;
            shell.sync_panel_workspace(cx);
            shell.add_file_surface("/fixtures/a/second.rs".into(), window, cx);
            let second = shell.file_surface_seq;
            shell.sync_panel_workspace(cx);
            assert_ne!(first, second);

            let (panel, tab) = file_tab(shell, first, cx);
            shell.focus_workspace_tab(panel, tab, window, cx);
            assert_eq!(shell.workspace_file_to_save(cx), Some(first));
            let (panel, tab) = file_tab(shell, second, cx);
            shell.focus_workspace_tab(panel, tab, window, cx);
            assert_eq!(shell.workspace_file_to_save(cx), Some(second));

            // From the composer beside it, the file on screen still saves.
            let (first_panel, _) = file_tab(shell, second, cx);
            let chat = PanelTab::Chat("current".into());
            let (chat_panel, _) = shell.panel_layout(cx).unwrap().location(&chat).unwrap();
            assert_ne!(chat_panel, first_panel);
            shell.focus_workspace_tab(chat_panel, chat, window, cx);
            assert_eq!(shell.workspace_file_to_save(cx), Some(second));
        })
        .unwrap();
}

#[gpui::test]
fn terminal_split_keys_act_on_the_panel_terminal_in_place(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    let terminal = window
        .update(cx, |shell, window, cx| {
            assert!(shell.toggle_workspace_tool(WorkspaceTool::Terminal, window, cx));
            let layout = shell.panel_layout(cx).unwrap();
            let Some(PanelTab::Terminal(id)) = layout.panel(layout.focused).unwrap().selected()
            else {
                panic!("the terminal is the focused tab");
            };
            let id = *id;
            let terminal = shell.workspace_panels.terminals[&id].clone();
            assert!(terminal.read(cx).focus_handle().is_focused(window));

            shell.split_terminal(SplitAxis::Horizontal, window, cx);
            assert!(terminal.read(cx).is_split(cx), "⌘D splits this terminal");
            let layout = shell.panel_layout(cx).unwrap();
            assert!(
                layout.location(&PanelTab::Terminal(id)).is_some(),
                "⌘D used to hide it instead"
            );
            assert!(shell.terminal.is_none(), "and start a dock nobody can see");
            assert_eq!(terminal.read(cx).tab_summaries(cx).len(), 2);

            shell.close_terminal_split(window, cx);
            assert!(!terminal.read(cx).is_split(cx), "⌘⇧W closes the split");
            assert_eq!(terminal.read(cx).tab_summaries(cx).len(), 1);
            terminal
        })
        .unwrap();

    // Closing the tab of a split terminal leaves neither side running.
    window
        .update(cx, |shell, window, cx| {
            // The shell's test draw doesn't mount panels, which drops focus.
            window.focus(&terminal.read(cx).focus_handle(), cx);
            shell.split_terminal(SplitAxis::Vertical, window, cx);
            assert_eq!(terminal.read(cx).tab_summaries(cx).len(), 2);
            let layout = shell.panel_layout(cx).unwrap();
            let id = layout.focused;
            let tab = layout.panel(id).unwrap().selected().unwrap().clone();
            shell.close_workspace_tab(id, tab, window, cx);
            assert!(terminal.read(cx).tab_summaries(cx).is_empty());
        })
        .unwrap();
}

#[gpui::test]
fn terminal_split_keys_leave_everything_alone_without_a_focused_terminal(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = panel_shell(cx);
    window
        .update(cx, |shell, window, cx| {
            let before = shell.panel_layout(cx).unwrap().panels.len();
            shell.split_terminal(SplitAxis::Horizontal, window, cx);
            shell.close_terminal_split(window, cx);
            assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), before);
            assert!(shell.terminal.is_none());
            assert!(shell.workspace_panels.terminals.is_empty());
        })
        .unwrap();
}

#[gpui::test]
fn cmd_r_shows_and_hides_changes_beside_the_chat(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    let changes = |shell: &Shell, cx: &App| {
        let layout = shell.panel_layout(cx).unwrap();
        layout
            .panels
            .iter()
            .flat_map(|panel| &panel.tabs)
            .filter(|tab| {
                matches!(
                    tab,
                    PanelTab::Surface {
                        surface: RightSurface::Diff(_),
                        ..
                    }
                )
            })
            .count()
    };
    window
        .update(cx, |shell, window, cx| {
            let chat = PanelTab::Chat("current".into());
            let (chat_panel, _) = shell.panel_layout(cx).unwrap().location(&chat).unwrap();
            shell.focus_workspace_tab(chat_panel, chat, window, cx);
            let press = |shell: &mut Shell, window: &mut Window, cx: &mut Context<Shell>| {
                shell.toggle_workspace_tool(WorkspaceTool::Changes, window, cx);
            };
            press(shell, window, cx);
            assert_eq!(changes(shell, cx), 1, "the first press shows changes");
            assert!(
                shell.diffs.values().all(|diff| diff.read(cx).in_review()),
                "with Discard all and Done reviewing, which have no other way in"
            );
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2, "beside the chat, not over it");
            let chat = PanelTab::Chat("current".into());
            assert_eq!(
                layout.location(&chat).map(|(id, _)| id),
                Some(layout.focused)
            );
            let diffs = shell.diffs.len();

            press(shell, window, cx);
            assert_eq!(changes(shell, cx), 0, "the second press hides them");
            assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), 1);

            press(shell, window, cx);
            assert_eq!(
                changes(shell, cx),
                1,
                "and the third brings the same ones back"
            );
            assert_eq!(shell.diffs.len(), diffs);
        })
        .unwrap();
}

#[gpui::test]
fn a_finished_turn_with_edits_shows_no_changes_card(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    window
        .update(cx, |shell, _, cx| {
            shell.debug_gate = Some(GatePhase::Ready);
            shell.state.update(cx, |state, _| {
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "current")
                    .unwrap()
                    .cwd = Some("/fixtures/a".into());
                state.transcript = serde_json::from_value(serde_json::json!([
                    {"id":"prompt", "role":"user", "parts":[], "createdAt":0, "deviceId":"local"},
                    {"id":"reply", "role":"assistant", "createdAt":1, "deviceId":"local", "parts":[{
                        "kind":"tool", "id":"edit", "resolved":true, "isError":false,
                        "call": harness_proto::ToolCall::EditFile {
                            path: "src/a.rs".into(),
                            old_string: None,
                            new_string: None,
                        },
                    }]},
                ]))
                .unwrap();
            });
        })
        .unwrap();
    let mut visual = gpui::VisualTestContext::from_window(window.into(), cx);
    visual.update(|window, cx| {
        window.refresh();
        window.draw(cx).clear();
    });
    assert!(visual.debug_bounds("composer-footer").is_some());
    assert!(visual.debug_bounds("turn-changes-review").is_none());
}

#[gpui::test]
fn cmd_r_with_no_chat_open_does_nothing(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    window
        .update(cx, |shell, window, cx| {
            shell.active_chat.clear();
            assert!(!shell.toggle_workspace_tool(WorkspaceTool::Changes, window, cx));
            assert!(shell.diffs.is_empty());
        })
        .unwrap();
}

#[test]
fn every_name_for_reopening_a_tab_agrees() {
    assert_eq!(
        crate::settings::ShortcutId::ReopenClosedTab.label(),
        "Reopen closed tab"
    );
}

/// `current` focused beside a terminal, with the terminal holding the keyboard.
fn terminal_beside_chat(shell: &mut Shell, window: &mut Window, cx: &mut Context<Shell>) -> u64 {
    assert!(shell.toggle_workspace_tool(WorkspaceTool::Terminal, window, cx));
    let layout = shell.panel_layout(cx).unwrap();
    let focused = layout.focused;
    assert!(matches!(
        layout.panel(focused).unwrap().selected(),
        Some(PanelTab::Terminal(_))
    ));
    focused
}

#[gpui::test]
fn composer_shortcuts_move_to_the_panel_that_has_the_composer(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    window
        .update(cx, |shell, window, cx| {
            let chat = PanelTab::Chat("current".into());
            let (chat_panel, _) = shell.panel_layout(cx).unwrap().location(&chat).unwrap();
            let terminal_panel = terminal_beside_chat(shell, window, cx);
            assert_ne!(chat_panel, terminal_panel);

            assert!(shell.focus_workspace_composer_panel(window, cx));
            assert_eq!(shell.panel_layout(cx).unwrap().focused, chat_panel);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );

            // Already there: nothing moves.
            assert!(shell.focus_workspace_composer_panel(window, cx));
            assert_eq!(shell.panel_layout(cx).unwrap().focused, chat_panel);

            // Zoomed on the terminal, the chat isn't on screen to go to.
            let terminal_tab = {
                let layout = shell.panel_layout(cx).unwrap();
                layout
                    .panel(terminal_panel)
                    .unwrap()
                    .selected()
                    .unwrap()
                    .clone()
            };
            shell.focus_workspace_tab(terminal_panel, terminal_tab, window, cx);
            shell.workspace_zoom(cx);
            assert!(!shell.focus_workspace_composer_panel(window, cx));
            assert_eq!(shell.panel_layout(cx).unwrap().focused, terminal_panel);
        })
        .unwrap();
}

#[gpui::test]
fn saved_blank_tabs_do_not_come_back_as_sessions(cx: &mut gpui::TestAppContext) {
    use crate::settings::SavedChatTab;
    let (_dir, window) = fixture(cx, false, None);
    let session = |id: &str, selected: Option<&str>| SavedChatTab {
        id: id.into(),
        selected: selected.map(Into::into),
        ..Default::default()
    };
    let restore = |saved: Vec<SavedChatTab>, active: usize, cx: &mut gpui::TestAppContext| {
        window
            .update(cx, |shell, _, cx| {
                shell.settings.project_tabs_version = 1;
                shell.settings.chat_tabs = saved;
                shell.settings.chat_tab = active;
                assert!(shell.restore_project_tabs(cx));
                let ids: Vec<_> = shell.chat_tabs.iter().map(|tab| tab.id.clone()).collect();
                (ids, shell.chat_tab)
            })
            .unwrap()
    };
    // #342: the active index pointed at one of the blanks.
    let saved = vec![
        session("a", Some("current")),
        SavedChatTab::default(),
        session("b", Some("peer")),
        SavedChatTab::default(),
        session("c", Some("target")),
    ];
    let (ids, active) = restore(saved.clone(), 3, cx);
    assert_eq!(ids, ["a", "b", "c"]);
    assert_eq!(active, 1, "the nearest kept tab before it takes over");
    let (_, active) = restore(saved, 4, cx);
    assert_eq!(active, 2, "a kept tab keeps its place");
    // A blank first tab hands over to the first kept one after it.
    let (ids, active) = restore(
        vec![SavedChatTab::default(), session("a", Some("current"))],
        0,
        cx,
    );
    assert_eq!((ids, active), (vec!["a".to_string()], 0));
    // A session the person made stays, even with nothing in it yet.
    let (ids, _) = restore(
        vec![session("a", Some("current")), session("empty", None)],
        0,
        cx,
    );
    assert_eq!(ids, ["a", "empty"]);
}

#[gpui::test]
fn deleting_the_open_chat_lands_on_the_panels_next_chat(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    window
        .update(cx, |shell, window, cx| {
            let peer = PanelTab::Chat("peer".into());
            let panel = shell.panel_layout(cx).unwrap().focused;
            shell.panel_layout_mut(cx).insert(panel, peer.clone());
            shell.focus_workspace_tab(panel, peer, window, cx);
            shell.on_state_changed(&shell.state.clone(), cx);
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));

            shell.finish_history_chat_deletion("peer", cx);
            shell.on_state_changed(&shell.state.clone(), cx);
            shell.sync_panel_workspace(cx);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            let layout = shell.panel_layout(cx).unwrap();
            let tabs = &layout.panel(panel).unwrap().tabs;
            assert_eq!(
                tabs,
                &[PanelTab::Chat("current".into())],
                "no new draft tab appears in its place"
            );
        })
        .unwrap();
}

#[gpui::test]
fn deleting_the_last_chat_in_a_panel_selects_nothing(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = panel_shell(cx);
    window
        .update(cx, |shell, _, cx| {
            shell.finish_history_chat_deletion("current", cx);
            shell.on_state_changed(&shell.state.clone(), cx);
            assert_eq!(shell.state.read(cx).selected_chat, None);
        })
        .unwrap();
}

#[gpui::test]
fn a_chat_open_in_another_window_is_shown_there_not_opened_twice(cx: &mut gpui::TestAppContext) {
    let (_first_dir, first) = panel_shell(cx);
    let (_second_dir, second) = panel_shell(cx);
    first
        .update(cx, |shell, _, cx| {
            let panel = shell.panel_layout(cx).unwrap().focused;
            shell
                .panel_layout_mut(cx)
                .insert(panel, PanelTab::Chat("peer".into()));
            shell.workspace_panels.needs_persist = true;
        })
        .unwrap();
    second
        .update(cx, |shell, window, cx| {
            shell.open_chat_in_tab("peer".into(), window, cx);
            assert!(
                shell.open_chat_placement("peer").is_none(),
                "no second copy"
            );
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            // Open nowhere else, a chat opens right here.
            shell.open_chat_in_tab("parked".into(), window, cx);
            shell.sync_panel_workspace(cx);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("parked")
            );
        })
        .unwrap();
    first
        .update(cx, |shell, _, cx| {
            assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
        })
        .unwrap();
}
