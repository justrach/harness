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

/// The split the user asked for: folder tabs on their own, the strip once
/// split, and back again when the split closes.
#[gpui::test]
fn one_panel_keeps_its_tab_row_until_the_window_splits(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let first = shell.update_in(cx, |shell, window, cx| {
        let layout = shell.panel_layout_mut(cx);
        layout.panels.truncate(1);
        let first = layout.panels[0].id;
        layout.panels[0].tabs = vec![
            PanelTab::Chat("chat-1".into()),
            PanelTab::Chat("chat-2".into()),
        ];
        layout.panels[0].active = 0;
        shell.focus_workspace_tab(first, PanelTab::Chat("chat-1".into()), window, cx);
        first
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("instrument-strip").is_none());
    assert!(at(cx, format!("panel-tab-{first}-0")).is_some());
    assert!(at(cx, format!("panel-tab-{first}-1")).is_some());
    let single = at(cx, format!("workspace-panel-body-{first}")).unwrap();

    let second = shell.update(cx, |shell, cx| {
        let layout = shell.panel_layout_mut(cx);
        let second = layout.add_panel(first);
        layout.equalize();
        cx.notify();
        second
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("instrument-strip").is_some());
    assert!(at(cx, format!("panel-tab-{first}-0")).is_none());
    assert!(at(cx, format!("instrument-slot-{second}")).is_some());
    let split = at(cx, format!("workspace-panel-body-{first}")).unwrap();
    assert_eq!(split.top(), single.top(), "the content does not jump");
    assert_eq!(split.bottom(), single.bottom(), "nor does its bottom edge");
    // The panel's fill is shaped around its selected tab. With the tab row gone
    // that shape must go too, or a white tab stays above the panel.
    shell.read_with(cx, |shell, _| {
        assert!(shell.workspace_panels.active_tab_bounds.borrow().is_empty());
    });

    // A tab row comes back with both tabs intact.
    shell.update_in(cx, |shell, window, cx| {
        shell.close_workspace_panel(second, window, cx)
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("instrument-strip").is_none());
    assert!(at(cx, format!("panel-tab-{first}-1")).is_some());
    let back = at(cx, format!("workspace-panel-body-{first}")).unwrap();
    assert_eq!(back.top(), single.top());
    assert_eq!(back.bottom(), single.bottom());
}

/// An expanded panel is still part of a split: the slots are how you get to
/// the others, so they stay.
#[gpui::test]
fn an_expanded_panel_keeps_the_strip(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, _) = three_panels(&shell, cx);
    shell.update(cx, |shell, cx| {
        shell.panel_layout_mut(cx).expanded = Some(first);
        cx.notify();
    });
    cx.run_until_parked();
    assert!(at(cx, format!("instrument-slot-{second}")).is_some());
    assert!(at(cx, format!("panel-tab-{first}-0")).is_none());
    shell.read_with(cx, |shell, cx| {
        assert!(!shell.workspace_uses_shared_header(cx));
    });
}

#[gpui::test]
fn a_slots_plus_adds_a_tab_inside_that_panel(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, _) = three_panels(&shell, cx);
    let tabs = |shell: &Entity<Shell>, id: u64, cx: &mut gpui::VisualTestContext| {
        shell.read_with(cx, |shell, cx| {
            shell
                .panel_layout(cx)
                .unwrap()
                .panel(id)
                .unwrap()
                .tabs
                .len()
        })
    };
    assert_eq!(tabs(&shell, second, cx), 1);
    // Not the focused panel: the + belongs to the slot it sits in.
    let add = at(cx, format!("instrument-slot-add-{second}")).unwrap();
    cx.simulate_click(add.center(), gpui::Modifiers::default());
    cx.run_until_parked();
    assert_eq!(tabs(&shell, second, cx), 2);
    assert_eq!(tabs(&shell, first, cx), 2, "the focused panel is untouched");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, second);
    });
}

fn settle(cx: &mut gpui::VisualTestContext) {
    cx.executor()
        .advance_clock(std::time::Duration::from_secs(2));
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        window.draw(cx).clear();
    });
    cx.run_until_parked();
}

fn assert_slots_stay_apart(ids: &[u64], cx: &mut gpui::VisualTestContext) {
    let strip = cx.debug_bounds("instrument-strip").unwrap();
    let slots: Vec<_> = ids
        .iter()
        .map(|id| at(cx, format!("instrument-slot-{id}")).unwrap())
        .collect();
    for pair in slots.windows(2) {
        assert!(pair[0].right() <= pair[1].left(), "{slots:?}");
    }
    for slot in &slots {
        assert!(slot.left() >= strip.left() && slot.right() <= strip.right());
    }
}

/// With the sidebar closed, the window centres the focused tab's title in the
/// title bar. The strip fills that row, so the two used to draw over each other.
#[gpui::test]
fn the_strip_has_the_title_row_to_itself(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, third) = three_panels(&shell, cx);
    shell.update(cx, |shell, cx| {
        shell.settings.sidebar_collapsed = true;
        cx.notify();
    });
    settle(cx);
    assert!(
        cx.debug_bounds("workspace-titlebar-identity").is_none(),
        "the title is already in the focused slot"
    );
    assert_slots_stay_apart(&[first, second, third], cx);
    let switcher = cx.debug_bounds("workspace-session-quick-switcher").unwrap();
    let slot = at(cx, format!("instrument-slot-{first}")).unwrap();
    assert!(slot.left() >= switcher.right(), "{slot:?} {switcher:?}");
}

/// More panels than fit: they scroll sideways, but every slot stays on screen,
/// narrower, with its contents clipped to it.
#[gpui::test]
fn slots_stay_apart_when_the_panels_do_not_fit(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let ids = shell.update(cx, |shell, cx| {
        let layout = shell.panel_layout_mut(cx);
        layout.axis = SplitAxis::Horizontal;
        while layout.panels.len() < 9 {
            let last = layout.panels.last().unwrap().id;
            layout.add_panel(last);
        }
        layout.equalize();
        cx.notify();
        layout_ids(shell.panel_layout(cx).unwrap())
    });
    settle(cx);
    assert_slots_stay_apart(&ids, cx);
}

fn layout_ids(layout: &WorkspaceLayout) -> Vec<u64> {
    layout.panels.iter().map(|panel| panel.id).collect()
}

#[gpui::test]
fn a_slot_names_the_device_its_panel_is_on(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, _) = three_panels(&shell, cx);
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, _| {
            state.devices = vec![harness_proto::Device {
                id: "studio".into(),
                name: "Studio computer".into(),
                platform: "macos".into(),
                last_seen_at: Some(Utc::now()),
                created_at: None,
                version: None,
                cursor_sdk_version: None,
                capabilities: vec![],
            }];
            let chat = state.chats.iter_mut().find(|chat| chat.id == "chat-3");
            chat.unwrap().device_id = "studio".into();
        });
        cx.notify();
    });
    settle(cx);
    shell.read_with(cx, |shell, cx| {
        let here = if cfg!(target_os = "macos") {
            "This Mac"
        } else {
            "This device"
        };
        assert_eq!(shell.panel_device_label(first, cx), here);
        assert_eq!(shell.panel_device_label(second, cx), "Studio computer");
    });
    assert!(at(cx, format!("instrument-slot-device-{first}")).is_some());
    assert!(at(cx, format!("instrument-slot-device-{second}")).is_some());
}

/// More panels than fit means no column to line up with and very little room,
/// which is when telling computers apart matters most.
#[gpui::test]
fn the_device_shows_however_narrow_the_slot(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let ids = shell.update(cx, |shell, cx| {
        let layout = shell.panel_layout_mut(cx);
        layout.axis = SplitAxis::Horizontal;
        while layout.panels.len() < 9 {
            let last = layout.panels.last().unwrap().id;
            layout.add_panel(last);
        }
        layout.equalize();
        cx.notify();
        layout_ids(shell.panel_layout(cx).unwrap())
    });
    settle(cx);
    for id in ids {
        let slot = at(cx, format!("instrument-slot-{id}")).unwrap();
        let device = at(cx, format!("instrument-slot-device-{id}")).expect("device shown");
        assert!(device.size.width > px(0.0), "{id} has room for it");
        assert!(device.left() >= slot.left() && device.right() <= slot.right());
    }
}

/// With one panel there is no strip, but the folder tabs can be from another
/// computer just the same.
#[gpui::test]
fn one_panel_names_its_device_beside_its_tabs(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let first = shell.update_in(cx, |shell, window, cx| {
        let layout = shell.panel_layout_mut(cx);
        layout.panels.truncate(1);
        let first = layout.panels[0].id;
        layout.panels[0].tabs = vec![
            PanelTab::Chat("chat-1".into()),
            PanelTab::Chat("chat-2".into()),
        ];
        layout.panels[0].active = 0;
        shell.focus_workspace_tab(first, PanelTab::Chat("chat-1".into()), window, cx);
        first
    });
    settle(cx);
    let device = at(cx, format!("workspace-panel-device-{first}")).expect("device shown");
    let tabs = at(cx, format!("workspace-panel-tab-strip-{first}")).unwrap();
    assert!(device.size.width > px(0.0));
    assert!(tabs.right() <= device.left(), "{tabs:?} {device:?}");
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
