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

/// Projects to pick from, in a real session: the app's layouts belong to a
/// session, so they stay put when a new chat's folder changes.
fn add_projects(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) {
    shell.update(cx, |shell, cx| {
        shell.boot_restored = true;
        shell.ensure_workspace_sessions(cx);
        shell.state.update(cx, |state, _| {
            state.spaces = [("alpha", "local"), ("beta", "local"), ("gamma", "studio")]
                .into_iter()
                .map(|(id, device)| {
                    serde_json::from_value(serde_json::json!({
                        "id": id, "deviceId": device, "path": format!("/made/up/{id}"),
                        "createdAt": "2026-09-05T00:00:00Z"
                    }))
                    .unwrap()
                })
                .collect();
        });
        cx.notify();
    });
}

fn pick_folder(shell: &Entity<Shell>, panel: u64, name: &str, cx: &mut gpui::VisualTestContext) {
    let button = at(cx, format!("instrument-slot-folder-{panel}")).expect("folder button");
    cx.simulate_mouse_down(button.center(), MouseButton::Left, Default::default());
    cx.simulate_mouse_up(button.center(), MouseButton::Left, Default::default());
    cx.run_until_parked();
    let row = shell.read_with(cx, |shell, _| {
        let menu = shell.workspace_panels.menu.as_ref().expect("folder menu");
        menu.rows
            .iter()
            .position(|row| &*row.0 == name)
            .expect(name)
    });
    shell.update_in(cx, |shell, window, cx| {
        shell.activate_panel_menu(row, window, cx)
    });
    settle(cx);
}

fn folder_of(shell: &Entity<Shell>, panel: u64, cx: &mut gpui::VisualTestContext) -> String {
    shell.read_with(cx, |shell, cx| {
        let panel = shell.panel_layout(cx).unwrap().panel(panel).unwrap();
        shell
            .panel_folder(panel, cx)
            .expect("a folder")
            .0
            .to_string()
    })
}

/// The ask: split, start a new chat, change its folder at the top.
fn focused_panel(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) -> u64 {
    shell.read_with(cx, |shell, cx| shell.panel_layout(cx).unwrap().focused)
}

/// ⌘T used to open the choices page, which is a step short of a session.
#[gpui::test]
fn cmd_t_starts_a_chat_ready_to_type_in(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let before = shell.read_with(cx, |shell, cx| {
        shell.panel_layout(cx).map_or(0, |layout| {
            layout
                .panel(layout.focused)
                .map_or(0, |panel| panel.tabs.len())
        })
    });
    cx.dispatch_action(crate::shell::NewTab);
    settle(cx);
    let panel = focused_panel(&shell, cx);
    shell.read_with(cx, |shell, cx| {
        let tabs = shell.panel_layout(cx).unwrap().panel(panel).unwrap();
        assert_eq!(tabs.tabs.len(), before + 1, "exactly one new tab");
        assert!(
            matches!(tabs.selected(), Some(PanelTab::Draft(_))),
            "a chat, not the choices page: {:?}",
            tabs.selected()
        );
        assert!(shell.state.read(cx).selected_chat.is_none());
    });
    assert!(at(cx, format!("panel-new-tab-choices-{panel}")).is_none());
    cx.update(|window, cx| {
        let composer = shell.read(cx).composer.focus_handle(cx);
        assert!(composer.contains_focused(window, cx), "the cursor is in it");
    });
}

/// A + still offers everything else a tab can be.
#[gpui::test]
fn the_plus_button_keeps_the_choices_page(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (_, second, _) = three_panels(&shell, cx);
    shell.update(cx, |shell, cx| shell.workspace_new_tab_in_panel(second, cx));
    settle(cx);
    assert!(at(cx, format!("panel-new-tab-choices-{second}")).is_some());
}

/// ⌘D, then ⌘W, with nothing in between: back where you were in one press.
#[gpui::test]
fn one_cmd_w_closes_the_panel_cmd_d_made(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    settle(cx);
    let original = focused_panel(&shell, cx);
    let panels = |shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext| {
        shell.read_with(cx, |shell, cx| shell.panel_layout(cx).unwrap().panels.len())
    };
    let before = panels(&shell, cx);
    cx.dispatch_action(crate::shell::SplitChatRight);
    settle(cx);
    assert_eq!(panels(&shell, cx), before + 1);
    assert_ne!(focused_panel(&shell, cx), original);
    shell.update_in(cx, |shell, window, cx| {
        assert!(shell.workspace_close_focused(window, cx));
    });
    settle(cx);
    assert_eq!(
        panels(&shell, cx),
        before,
        "the panel went with its only tab"
    );
    assert_eq!(focused_panel(&shell, cx), original);
    shell.read_with(cx, |shell, cx| {
        assert!(
            shell.workspace_panels.menu.is_none(),
            "and nothing of it is left on screen"
        );
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("chat-3"),
            "the chat it was split from is selected again"
        );
    });
}

#[gpui::test]
fn the_last_panel_in_a_window_survives_its_last_tab(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    settle(cx);
    let panel = focused_panel(&shell, cx);
    shell.update_in(cx, |shell, window, cx| {
        let tabs = shell
            .panel_layout(cx)
            .unwrap()
            .panel(panel)
            .unwrap()
            .tabs
            .clone();
        for tab in tabs {
            shell.close_workspace_tab(panel, tab, window, cx);
        }
    });
    settle(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().panels.len(), 1);
    });
}

fn split_with_projects(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) -> u64 {
    add_projects(shell, cx);
    settle(cx);
    cx.dispatch_action(crate::shell::SplitChatRight);
    settle(cx);
    focused_panel(shell, cx)
}

/// The folder was only a small button in the bar, easily missed, so a split
/// came up working in the previous chat's folder.
#[gpui::test]
fn cmd_d_asks_which_folder_the_new_chat_is_in(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let panel = split_with_projects(&shell, cx);
    let menu_rows = shell.read_with(cx, |shell, _| {
        let menu = shell
            .workspace_panels
            .menu
            .as_ref()
            .expect("the menu opened");
        assert_eq!(menu.panel, panel);
        menu.rows
            .iter()
            .filter(|(_, _, action)| matches!(action, MenuAction::SetFolder(Some(_))))
            .count()
    });
    assert!(menu_rows > 0);
    let button = at(cx, format!("instrument-slot-folder-{panel}")).expect("its button");
    shell.read_with(cx, |shell, _| {
        let position = shell.workspace_panels.menu.as_ref().unwrap().position;
        assert_eq!(position, button.bottom_left(), "it hangs under that button");
    });
    cx.simulate_keystrokes("enter");
    settle(cx);
    shell.read_with(cx, |shell, _| {
        assert!(shell.workspace_panels.menu.is_none())
    });
    cx.update(|window, cx| {
        let composer = shell.read(cx).composer.focus_handle(cx);
        assert!(composer.contains_focused(window, cx), "ready to type there");
    });
}

#[gpui::test]
fn dismissing_cmd_d_s_menu_leaves_you_typing_in_the_new_chat(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    split_with_projects(&shell, cx);
    cx.simulate_keystrokes("escape");
    settle(cx);
    shell.read_with(cx, |shell, _| {
        assert!(shell.workspace_panels.menu.is_none())
    });
    cx.update(|window, cx| {
        let composer = shell.read(cx).composer.focus_handle(cx);
        assert!(composer.contains_focused(window, cx));
    });
}

fn menu_titles(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) -> Vec<String> {
    shell.read_with(cx, |shell, _| {
        let menu = shell
            .workspace_panels
            .menu
            .as_ref()
            .expect("the menu is open");
        menu.rows.iter().map(|row| row.0.to_string()).collect()
    })
}

fn highlighted(shell: &Entity<Shell>, cx: &mut gpui::VisualTestContext) -> String {
    shell.read_with(cx, |shell, _| {
        let menu = shell
            .workspace_panels
            .menu
            .as_ref()
            .expect("the menu is open");
        menu.rows[menu.selected].0.to_string()
    })
}

/// A long list of folders needs a text box: type to narrow it, Enter to pick.
#[gpui::test]
fn typing_in_the_folder_menu_narrows_it_and_enter_picks(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let panel = split_with_projects(&shell, cx);
    assert!(menu_titles(&shell, cx).contains(&"alpha".to_string()));
    cx.simulate_input("bet");
    settle(cx);
    assert_eq!(
        menu_titles(&shell, cx),
        ["beta", "Don't work in a project", "New project…"],
        "the actions stay under whatever matches"
    );
    assert_eq!(highlighted(&shell, cx), "beta");
    cx.simulate_keystrokes("enter");
    settle(cx);
    shell.read_with(cx, |shell, _| {
        assert!(shell.workspace_panels.menu.is_none())
    });
    assert_eq!(folder_of(&shell, panel, cx), "beta");
}

#[gpui::test]
fn enter_with_no_matching_folder_changes_nothing_by_accident(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let panel = split_with_projects(&shell, cx);
    let before = folder_of(&shell, panel, cx);
    cx.simulate_input("no such folder");
    settle(cx);
    assert_eq!(
        menu_titles(&shell, cx),
        ["Don't work in a project", "New project…"]
    );
    assert!(cx.debug_bounds("panel-menu-no-matches").is_some());
    assert_eq!(
        highlighted(&shell, cx),
        "New project…",
        "not the row that would drop the folder"
    );
    assert_eq!(folder_of(&shell, panel, cx), before);
}

/// A space is text here, not "activate the highlighted row" as in other menus.
#[gpui::test]
fn the_folder_menu_takes_spaces_and_arrows(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    split_with_projects(&shell, cx);
    cx.simulate_keystrokes("space");
    settle(cx);
    shell.read_with(cx, |shell, _| {
        assert!(
            shell.workspace_panels.menu.is_some(),
            "a space picked a row"
        )
    });
    cx.update(|window, cx| {
        let shell = shell.read(cx);
        let menu = shell.workspace_panels.menu.as_ref().unwrap();
        let input = menu.search.as_ref().unwrap().input.focus_handle(cx);
        assert!(input.is_focused(window), "the text box has the keyboard");
    });
    let start = highlighted(&shell, cx);
    cx.simulate_keystrokes("down");
    settle(cx);
    assert_ne!(highlighted(&shell, cx), start);
    cx.simulate_keystrokes("up");
    settle(cx);
    assert_eq!(highlighted(&shell, cx), start);
}

/// The folder is on the chat box too, with the same searchable list.
#[gpui::test]
fn a_new_chats_box_has_a_folder_dropdown_with_search(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    settle(cx);
    assert!(
        cx.debug_bounds("draft-project-target").is_none(),
        "a chat that has started can't move"
    );
    add_projects(&shell, cx);
    cx.dispatch_action(crate::shell::NewTab);
    settle(cx);
    let chip = cx
        .debug_bounds("draft-project-target")
        .expect("the dropdown");
    cx.simulate_mouse_down(chip.center(), MouseButton::Left, Default::default());
    cx.simulate_mouse_up(chip.center(), MouseButton::Left, Default::default());
    settle(cx);
    let pickers = shell.read_with(cx, |shell, cx| shell.composer.read(cx).pickers().clone());
    pickers.read_with(cx, |pickers, _| assert!(pickers.project_menu_open()));
    assert!(
        cx.debug_bounds("space-row-0").is_some(),
        "its list is on screen"
    );
    cx.simulate_input("bet");
    settle(cx);
    assert!(
        cx.debug_bounds("space-row-1").is_none(),
        "typing narrows it"
    );
    cx.simulate_keystrokes("enter");
    settle(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.state.read(cx).selected_space.as_deref(), Some("beta"));
    });
    assert!(
        cx.debug_bounds("draft-project-target").is_some(),
        "it stays, now naming the folder"
    );
}

/// With no projects there is nothing to ask.
#[gpui::test]
fn cmd_d_without_projects_goes_straight_to_the_chat(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    settle(cx);
    cx.dispatch_action(crate::shell::SplitChatRight);
    settle(cx);
    shell.read_with(cx, |shell, _| {
        assert!(shell.workspace_panels.menu.is_none())
    });
    cx.update(|window, cx| {
        let composer = shell.read(cx).composer.focus_handle(cx);
        assert!(composer.contains_focused(window, cx));
    });
}

#[gpui::test]
fn a_new_chats_slot_changes_its_folder(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (_, second, _) = three_panels(&shell, cx);
    add_projects(&shell, cx);
    shell.update(cx, |shell, cx| shell.workspace_new_tab_in_panel(second, cx));
    settle(cx);

    let button = at(cx, format!("instrument-slot-folder-{second}")).expect("folder button");
    cx.simulate_mouse_down(button.center(), MouseButton::Left, Default::default());
    cx.simulate_mouse_up(button.center(), MouseButton::Left, Default::default());
    cx.run_until_parked();
    let titles = shell.read_with(cx, |shell, _| {
        let menu = shell.workspace_panels.menu.as_ref().expect("folder menu");
        menu.rows
            .iter()
            .map(|row| row.0.to_string())
            .collect::<Vec<_>>()
    });
    assert!(titles.iter().any(|title| title == "alpha"), "{titles:?}");
    assert!(titles.iter().any(|title| title == "beta"), "{titles:?}");
    assert!(
        !titles.iter().any(|title| title == "gamma"),
        "another computer's project can't be picked here: {titles:?}"
    );
    assert_eq!(titles.last().map(String::as_str), Some("New project…"));
    shell.read_with(cx, |shell, _| {
        let menu = shell.workspace_panels.menu.as_ref().unwrap();
        assert_eq!(
            menu.position,
            button.bottom_left(),
            "it hangs under the button"
        );
    });
    shell.update(cx, |shell, cx| {
        shell.workspace_panels.menu = None;
        cx.notify();
    });
    settle(cx);

    pick_folder(&shell, second, "beta", cx);
    assert_eq!(folder_of(&shell, second, cx), "beta");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, second);
        assert_eq!(shell.state.read(cx).selected_space.as_deref(), Some("beta"));
        assert_eq!(
            shell.settings.space_filter, None,
            "the sidebar stays as it was"
        );
    });

    // Starting the chat keeps it, and the composer sends there.
    shell.update_in(cx, |shell, window, cx| {
        shell.activate_workspace_empty(second, 0, window, cx)
    });
    settle(cx);
    assert_eq!(folder_of(&shell, second, cx), "beta");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.state.read(cx).selected_space.as_deref(), Some("beta"));
    });

    // Opting out works, and the button stays.
    pick_folder(&shell, second, "Don't work in a project", cx);
    assert_eq!(folder_of(&shell, second, cx), "No project");
    assert!(at(cx, format!("instrument-slot-folder-{second}")).is_some());
}

/// Two new chats side by side each keep their own folder.
#[gpui::test]
fn each_new_chat_keeps_its_own_folder(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (first, second, _) = three_panels(&shell, cx);
    add_projects(&shell, cx);
    for panel in [first, second] {
        shell.update_in(cx, |shell, window, cx| {
            shell.workspace_panels.target = Some(panel);
            shell.workspace_new_chat(cx);
            let _ = (window, cx);
        });
    }
    settle(cx);
    pick_folder(&shell, first, "alpha", cx);
    pick_folder(&shell, second, "beta", cx);
    assert_eq!(folder_of(&shell, first, cx), "alpha");
    assert_eq!(folder_of(&shell, second, cx), "beta");
    shell.update_in(cx, |shell, window, cx| {
        shell.focus_strip_slot(first, window, cx)
    });
    settle(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_space.as_deref(),
            Some("alpha")
        );
    });
    assert_eq!(folder_of(&shell, second, cx), "beta");
}

/// A chat that has started can't move, so it only says where it is.
#[gpui::test]
fn a_started_chat_names_its_folder_without_offering_to_change_it(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (_, second, _) = three_panels(&shell, cx);
    add_projects(&shell, cx);
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, _| {
            let chat = state.chats.iter_mut().find(|chat| chat.id == "chat-3");
            chat.unwrap().space_id = Some("alpha".into());
        });
        cx.notify();
    });
    settle(cx);
    assert!(at(cx, format!("instrument-slot-folder-name-{second}")).is_some());
    assert!(at(cx, format!("instrument-slot-folder-{second}")).is_none());
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

/// Windows draws its buttons over the last panel's corner. Only the last slot
/// gives way, so the others still sit directly above their panels.
#[test]
fn window_buttons_only_narrow_the_last_slot() {
    assert_eq!(
        Shell::strip_columns(&[400.0, 400.0], 0.0, 0.0, GUTTER + 100.0),
        Some(vec![400.0, 400.0 - NEW_TAB_ROOM_FOR_TEST - 100.0])
    );
    assert_eq!(
        Shell::strip_columns(&[400.0, 200.0], 0.0, 0.0, GUTTER + 138.0),
        None,
        "the last slot would be too narrow to line up"
    );
}

/// A slot with no room for both gives up its + before its computer's name.
#[test]
fn a_shared_slots_room_decides_whether_it_keeps_its_plus() {
    let room = |slots| Shell::strip_slot_room(1200.0, 100.0, 76.0, slots);
    assert_eq!(room(2), (1200.0 - 100.0 - 76.0 - 24.0 - 4.0) / 2.0);
    assert!(room(2) >= instrument_strip::SLOT_ROOM_FOR_ADD);
    assert!(room(9) < instrument_strip::SLOT_ROOM_FOR_ADD);
    assert!(Shell::strip_slot_room(0.0, 0.0, 0.0, 0).is_finite());
}

#[test]
fn slots_stop_following_columns_when_one_would_be_too_narrow() {
    assert_eq!(
        Shell::strip_columns(&[400.0, 400.0], 0.0, 0.0, GUTTER),
        Some(vec![400.0, 400.0 - NEW_TAB_ROOM_FOR_TEST])
    );
    // A window-corner button pushes the first slot in by its width.
    assert_eq!(
        Shell::strip_columns(&[400.0, 400.0], 10.0, 110.0, GUTTER),
        Some(vec![300.0, 400.0 - NEW_TAB_ROOM_FOR_TEST])
    );
    assert_eq!(
        Shell::strip_columns(&[100.0, 400.0], 0.0, 60.0, GUTTER),
        None
    );
    assert_eq!(Shell::strip_columns(&[], 0.0, 0.0, GUTTER), None);
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
fn a_new_tabs_slot_can_be_pressed_and_closed(cx: &mut gpui::TestAppContext) {
    let dir = tempfile::tempdir().unwrap();
    let (shell, cx) = shell_with_chats(cx, &dir);
    let (_, second, _) = three_panels(&shell, cx);
    shell.update_in(cx, |shell, _, cx| {
        let panel = shell.panel_layout_mut(cx).panel_mut(second).unwrap();
        panel.tabs = vec![PanelTab::New(77)];
        panel.active = 0;
    });
    settle(cx);
    // The title line: the folder chip under it opens its own menu.
    let slot = at(cx, format!("instrument-slot-{second}")).unwrap();
    let title = slot.origin + gpui::point(gpui::px(40.0), gpui::px(6.0));
    cx.simulate_click(title, gpui::Modifiers::default());
    settle(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.panel_layout(cx).unwrap().focused, second);
    });
    let close = at(cx, format!("instrument-slot-close-{second}")).unwrap();
    cx.simulate_click(close.center(), gpui::Modifiers::default());
    settle(cx);
    shell.read_with(cx, |shell, cx| {
        let layout = shell.panel_layout(cx).unwrap();
        assert_eq!(layout.panels.len(), 2);
        assert!(layout.panel(second).is_none(), "one press and it's gone");
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
    // Ctrl+Alt is AltGr on Windows, where it types characters.
    let keymap = gpui::Keymap::new(crate::shell::chat_split::chat_split_bindings(false));
    let bound = |key: &str| {
        let (matched, _) =
            keymap.bindings_for_input(&[gpui::Keystroke::parse(key).unwrap()], &stack);
        matched
            .first()
            .map(|binding| binding.action().boxed_clone())
    };
    assert!(bound("alt-shift-3").unwrap().partial_eq(&FocusPanelSlot3));
    assert!(bound("ctrl-alt-3").is_none());
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
