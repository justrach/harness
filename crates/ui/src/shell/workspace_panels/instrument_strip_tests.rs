use super::*;
use crate::shell::typing_tests::shell_with_chats;

const NEW_TAB_ROOM_FOR_TEST: f32 = 24.0 + GUTTER;

/// Selectors here carry a panel id; the lookup wants a static string.
fn at(cx: &mut gpui::VisualTestContext, selector: String) -> Option<gpui::Bounds<Pixels>> {
    cx.debug_bounds(selector.leak())
}

/// Three panels side by side; the first holds two chats.
fn three_panels(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) -> (u64, u64, u64) {
    let ids = shell.update_in(cx, |shell, window, cx| {
        let layout = shell.panel_layout_mut(cx);
        layout.axis = SplitAxis::Horizontal;
        let first = layout.panels[0].id;
        let second = layout.add_panel(first);
        let third = layout.add_panel(second);
        layout.equalize();
        let chats = [
            (first, vec!["chat-1", "chat-2"]),
            (second, vec!["chat-3"]),
            (third, vec!["chat-4"]),
        ];
        for (id, tabs) in chats {
            let panel = layout.panel_mut(id).unwrap();
            panel.tabs = tabs
                .into_iter()
                .map(|chat| PanelTab::Chat(chat.into()))
                .collect();
            panel.active = 0;
        }
        shell.focus_workspace_tab(first, PanelTab::Chat("chat-1".into()), window, cx);
        (first, second, third)
    });
    cx.run_until_parked();
    ids
}

#[gpui::test]
fn each_panel_gets_one_slot_and_no_tab_row(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, third) = three_panels(&shell, cx);
    let strip = cx.debug_bounds("instrument-strip").unwrap();
    for id in [first, second, third] {
        let slot = at(cx, format!("instrument-slot-{id}")).unwrap();
        assert!(slot.top() >= strip.top() && slot.bottom() <= strip.bottom());
        assert!(at(cx, format!("workspace-panel-header-{id}")).is_none());
        assert!(at(cx, format!("panel-tab-{id}-0")).is_none());
        let panel = at(cx, format!("workspace-panel-{id}")).unwrap();
        assert!(
            panel.top() >= strip.bottom(),
            "panels start under the strip"
        );
    }
    // Only the focused panel carries the ring.
    assert!(at(cx, format!("instrument-focus-{first}")).is_some());
    assert!(at(cx, format!("instrument-focus-{second}")).is_none());
}

#[gpui::test]
fn each_slot_sits_directly_above_its_panel(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, third) = three_panels(&shell, cx);
    for id in [second, third] {
        let slot = at(cx, format!("instrument-slot-{id}")).unwrap();
        let panel = at(cx, format!("workspace-panel-{id}")).unwrap();
        assert!(
            (slot.left() - panel.left()).abs() <= px(1.0),
            "{id} starts with its panel"
        );
    }
    let slot = at(cx, format!("instrument-slot-{first}")).unwrap();
    let panel = at(cx, format!("workspace-panel-{first}")).unwrap();
    assert!(
        (slot.right() - panel.right()).abs() <= px(1.0),
        "the first one ends with its panel"
    );
}

#[test]
fn slots_stop_following_columns_when_one_would_be_too_narrow() {
    assert_eq!(
        Shell::strip_columns(&[400.0, 400.0], 0.0, 0.0),
        Some(vec![400.0, 400.0 - NEW_TAB_ROOM_FOR_TEST])
    );
    // A window-corner button pushes the first slot in by its width.
    assert_eq!(
        Shell::strip_columns(&[400.0, 400.0], 10.0, 110.0),
        Some(vec![300.0, 400.0 - NEW_TAB_ROOM_FOR_TEST])
    );
    assert_eq!(Shell::strip_columns(&[100.0, 400.0], 0.0, 60.0), None);
    assert_eq!(Shell::strip_columns(&[], 0.0, 0.0), None);
}

#[gpui::test]
fn pressing_a_slot_focuses_its_panel(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (_, second, _) = three_panels(&shell, cx);
    let slot = at(cx, format!("instrument-slot-{second}")).unwrap();
    cx.simulate_click(slot.center(), gpui::Modifiers::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, second);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("chat-3")
        );
    });
}

#[gpui::test]
fn a_slot_switches_which_panel_is_expanded(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, _) = three_panels(&shell, cx);
    shell.update(cx, |shell, cx| {
        shell.panel_layout_mut(cx).expanded = Some(first);
        cx.notify();
    });
    cx.run_until_parked();
    let slot = at(cx, format!("instrument-slot-{second}")).unwrap();
    cx.simulate_click(slot.center(), gpui::Modifiers::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().expanded, Some(second));
    });
}

#[gpui::test]
fn the_slot_menu_lists_a_panels_tabs_and_its_actions(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, _) = three_panels(&shell, cx);
    let menu_titles = |shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext| {
        shell.read_with(cx, |shell, _| {
            let menu = shell.workspace_panels.menu.as_ref().unwrap();
            menu.rows
                .iter()
                .map(|row| row.0.to_string())
                .collect::<Vec<_>>()
        })
    };
    // A panel with one tab has nothing to list, only its actions.
    shell.update_in(cx, |shell, window, cx| {
        shell.open_strip_menu(second, point(px(100.0), px(100.0)), window, cx)
    });
    cx.run_until_parked();
    let titles = menu_titles(&shell, cx);
    assert_eq!(titles[0], "New tab");
    for action in [
        "Split right",
        "Split down",
        "Expand panel",
        "Close tab",
        "Close panel",
    ] {
        assert!(
            titles.iter().any(|title| title == action),
            "{action} missing"
        );
    }

    // With two, they come first, and picking one selects it.
    shell.update_in(cx, |shell, window, cx| {
        shell.open_strip_menu(first, point(px(100.0), px(100.0)), window, cx)
    });
    cx.run_until_parked();
    assert_eq!(
        menu_titles(&shell, cx)[0..2],
        ["Chat number 1", "Chat number 2"]
    );
    shell.update_in(cx, |shell, window, cx| {
        shell.activate_panel_menu(1, window, cx)
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        let layout = shell.panel_layout(cx).unwrap();
        assert_eq!(layout.panel(first).unwrap().active, 1);
        assert!(shell.workspace_panels.menu.is_none());
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("chat-2")
        );
    });
}

#[gpui::test]
fn dragging_a_slot_onto_another_moves_its_tab_there(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, _) = three_panels(&shell, cx);
    let start = at(cx, format!("instrument-slot-{first}")).unwrap().center();
    let target = at(cx, format!("instrument-slot-{second}"))
        .unwrap()
        .center();
    cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
    cx.simulate_mouse_move(
        start + point(px(12.0), px(4.0)),
        Some(MouseButton::Left),
        Default::default(),
    );
    cx.run_until_parked();
    cx.simulate_mouse_move(target, Some(MouseButton::Left), Default::default());
    cx.run_until_parked();
    cx.simulate_mouse_up(target, MouseButton::Left, Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        let layout = shell.panel_layout(cx).unwrap();
        assert_eq!(
            layout.panel(first).unwrap().tabs,
            vec![PanelTab::Chat("chat-2".into())]
        );
        assert!(
            layout
                .panel(second)
                .unwrap()
                .tabs
                .contains(&PanelTab::Chat("chat-1".into()))
        );
    });
}

#[test]
fn the_slot_keys_leave_the_session_and_tab_jumps_alone() {
    let keymap = gpui::Keymap::new(crate::shell::chat_split::chat_split_bindings(true));
    let stack = [gpui::KeyContext::parse("Shell").unwrap()];
    let bound = |key: &str| {
        let (matched, _) =
            keymap.bindings_for_input(&[gpui::Keystroke::parse(key).unwrap()], &stack);
        matched
            .first()
            .map(|binding| binding.action().boxed_clone())
    };
    assert!(bound("cmd-alt-3").unwrap().partial_eq(&FocusPanelSlot3));
    assert!(bound("cmd-3").is_none(), "⌘3 stays the session jump");
    assert!(
        !bound("ctrl-3").unwrap().partial_eq(&FocusPanelSlot3),
        "⌃3 stays the chat tab"
    );
}

#[gpui::test]
fn a_number_key_reaches_the_slot_at_that_position(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (_, _, third) = three_panels(&shell, cx);
    shell.update_in(cx, |shell, window, cx| {
        shell.focus_strip_position(2, window, cx)
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, third);
    });
    // Past the last slot does nothing.
    shell.update_in(cx, |shell, window, cx| {
        shell.focus_strip_position(5, window, cx)
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, third);
    });
}
