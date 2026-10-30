use super::*;

pub(super) fn open_search(
    shell: &Entity<Shell>,
    cx: &mut gpui::VisualTestContext,
) -> Entity<ComposerInput> {
    let bounds = cx.debug_bounds("sidebar-search-toggle").unwrap();
    cx.simulate_click(bounds.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, _| {
        shell.sidebar_search.as_ref().unwrap().input.clone()
    })
}

pub(super) fn query(input: &Entity<ComposerInput>, text: &str, cx: &mut gpui::VisualTestContext) {
    cx.update(|window, cx| {
        window.focus(&input.focus_handle(cx), cx);
        input.update(cx, |input, cx| input.set_text(text, cx));
    });
    cx.run_until_parked();
}

fn held_key(key: &str, cx: &mut gpui::VisualTestContext) {
    cx.update(|window, cx| {
        window.dispatch_event(
            gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                keystroke: Keystroke::parse(key).unwrap(),
                is_held: true,
                prefer_character_input: false,
            }),
            cx,
        );
        // Complete the simulated hold; subsequent presses need a real release.
        window.dispatch_event(
            gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                keystroke: Keystroke::parse(key).unwrap(),
            }),
            cx,
        );
    });
    cx.run_until_parked();
}

#[test]
fn sidebar_search_literal_names_missing_titles_and_large_archive() {
    let mut rows = vec![
        chat("symbols", "Fix [draft].* + (v2)?", false, "one"),
        chat("emoji", "部署 🚀 sidebar", true, "two"),
        chat("untitled", "unused", false, "one"),
    ];
    rows[2].title = None;
    for (query, expected) in [
        ("[draft].*", "symbols"),
        ("(v2)?", "symbols"),
        ("部署 🚀", "emoji"),
        ("new SESSION", "untitled"),
    ] {
        assert_eq!(
            matching_chats(&rows, query, None, true, SidebarSort::Created)
                .into_iter()
                .map(|chat| chat.id.as_str())
                .collect::<Vec<_>>(),
            [expected]
        );
    }
    assert_eq!(
        matching_chats(&[], "", None, true, SidebarSort::Created).len(),
        0
    );
    let archive: Vec<_> = (0..2_000)
        .map(|i| chat(&format!("archived-{i:04}"), "Archived match", true, "one"))
        .collect();
    let found = matching_chats(&archive, "match", None, true, SidebarSort::Created);
    assert_eq!(
        found.len(),
        2_000,
        "search must not inherit the archive shelf or palette result limit"
    );
    assert_eq!(found.last().unwrap().id, "archived-1999");
}

#[gpui::test]
fn sidebar_search_supports_horizontal_caret_editing(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    press_keys(cx, "left backspace");
    assert_eq!(
        input.read_with(cx, |input, _| input.text().to_string()),
        "sidebr"
    );
    press_keys(cx, "right backspace");
    assert_eq!(
        input.read_with(cx, |input, _| input.text().to_string()),
        "sideb"
    );
}

#[gpui::test]
fn sidebar_search_whitespace_escape_clears_before_closing(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "   ", cx);
    press_keys(cx, "escape");
    cx.run_until_parked();
    shell.read_with(cx, |shell, _| {
        assert!(
            shell.sidebar_search.is_some(),
            "first Escape must clear the entered query"
        )
    });
    assert_eq!(input.read_with(cx, |input, _| input.text().to_string()), "");
    held_key("escape", cx);
    shell.read_with(cx, |shell, _| {
        assert!(
            shell.sidebar_search.is_some(),
            "holding Escape must not cascade to closing search"
        )
    });
    press_keys(cx, "escape");
    shell.read_with(cx, |shell, _| assert!(shell.sidebar_search.is_none()));
}

#[gpui::test]
fn sidebar_search_archive_toggle_ignores_key_repeat(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    cx.update(|window, cx| {
        let focus = shell
            .read(cx)
            .sidebar_search
            .as_ref()
            .unwrap()
            .archive_focus
            .clone();
        window.focus(&focus, cx)
    });
    press_keys(cx, "space");
    shell.read_with(cx, |shell, _| {
        assert!(shell.sidebar_search.as_ref().unwrap().include_archived)
    });
    held_key("space", cx);
    shell.read_with(cx, |shell, _| {
        assert!(
            shell.sidebar_search.as_ref().unwrap().include_archived,
            "a held checkbox key must not toggle the archive filter repeatedly"
        )
    });
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, _| {
        assert!(!shell.sidebar_search.as_ref().unwrap().include_archived)
    });
    held_key("enter", cx);
    shell.read_with(cx, |shell, _| {
        assert!(!shell.sidebar_search.as_ref().unwrap().include_archived)
    });
}

#[gpui::test]
fn sidebar_search_wraps_resets_and_tolerates_empty_results(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    press_keys(cx, "up");
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.sidebar_search.as_ref().unwrap().active, 1)
    });
    press_keys(cx, "down");
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.sidebar_search.as_ref().unwrap().active, 0)
    });
    press_keys(cx, "down");
    query(&input, "polish", cx);
    shell.read_with(cx, |shell, _| {
        assert_eq!(shell.sidebar_search.as_ref().unwrap().active, 0)
    });
    query(&input, "not present", cx);
    press_keys(cx, "up down enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.sidebar_search.as_ref().unwrap().active, 0);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
        assert!(shell.chat_tabs.is_empty());
    });
    query(&input, "experiments", cx);
    held_key("enter", cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        )
    });
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("archived")
        )
    });
}

#[gpui::test]
fn sidebar_search_project_change_resets_cursor_and_scroll(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats = (0..80)
                    .map(|i| {
                        chat(
                            &format!("note-{i:02}"),
                            "Sidebar note",
                            false,
                            if i < 40 { "one" } else { "two" },
                        )
                    })
                    .collect();
                cx.notify();
            })
        })
    });
    cx.run_until_parked();
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    press_keys(cx, "down down down down down");
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell
                .sidebar_search
                .as_ref()
                .unwrap()
                .scroll
                .set_offset(gpui::point(px(0.0), px(-900.0)));
            shell.set_space_filter(Some("two".into()), cx);
        })
    });
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        let search = shell.sidebar_search.as_ref().unwrap();
        assert_eq!(
            search.active, 0,
            "a different project is a fresh result scope"
        );
        assert_eq!(search.scroll.offset().y, px(0.0));
        assert_eq!(shell.sidebar_search_ids(cx).len(), 40);
        assert_eq!(shell.sidebar_search_ids(cx)[0], "note-40");
    });
}

#[gpui::test]
fn sidebar_search_live_rename_archive_and_delete(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    press_keys(cx, "down");
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats.retain(|chat| chat.id != "archived");
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "active")
                    .unwrap()
                    .title = Some("Renamed away".into());
                cx.notify();
            })
        })
    });
    cx.run_until_parked();
    assert!(cx.debug_bounds("sidebar-search-empty").is_some());
    press_keys(cx, "down enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.sidebar_search.as_ref().unwrap().active, 0);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
    });
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats.push(chat(
                    "incoming",
                    "Sidebar from another device",
                    true,
                    "project",
                ));
                cx.notify();
            })
        })
    });
    cx.run_until_parked();
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("incoming")
        );
        assert!(
            shell
                .state
                .read(cx)
                .chats
                .iter()
                .find(|chat| chat.id == "incoming")
                .unwrap()
                .archived
        );
    });
}

#[gpui::test]
fn sidebar_search_mouse_pick_updates_keyboard_cursor(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    cx.run_until_parked();
    let archived = cx.debug_bounds("palette-chat-archived").unwrap();
    cx.simulate_click(archived.center(), Default::default());
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("archived")
        );
        assert_eq!(
            shell.sidebar_search.as_ref().unwrap().active,
            1,
            "mouse and keyboard cursor must identify the same result"
        );
    });
}

#[gpui::test]
fn sidebar_search_reveals_existing_tab_without_unarchiving(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    cx.update(|_, cx| {
        shell.update(cx, |shell, cx| {
            shell.chat_tabs = vec![
                Default::default(),
                crate::shell::chat_tabs::ChatTab {
                    selected: Some("archived".into()),
                    ..Default::default()
                },
            ];
            cx.notify();
        })
    });
    cx.run_until_parked();
    let input = open_search(&shell, cx);
    query(&input, "experiments", cx);
    cx.update(|_, cx| shell.update(cx, |shell, cx| shell.toggle_sidebar_search_archived(cx)));
    for _ in 0..3 {
        cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
        press_keys(cx, "enter");
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.chat_tabs.len(), 2);
            assert_eq!(shell.chat_tab, 1);
            assert!(
                shell
                    .state
                    .read(cx)
                    .chats
                    .iter()
                    .find(|chat| chat.id == "archived")
                    .unwrap()
                    .archived
            );
        });
    }
}

#[gpui::test]
fn sidebar_search_roundtrips_themes_widths_and_disclosures(cx: &mut gpui::TestAppContext) {
    for light in [false, true] {
        for width in [224.0, 400.0] {
            let (_dir, shell, cx) = fixture(cx, width);
            cx.update(|_, cx| {
                cx.set_global(if light { Theme::light() } else { Theme::dark() });
                shell.update(cx, |shell, cx| {
                    shell.pinned_open = false;
                    shell.sessions_open = false;
                    shell.archived_open = false;
                    shell.sidebar_collapsed_groups.insert("local".into());
                    cx.notify();
                });
            });
            cx.run_until_parked();
            let input = open_search(&shell, cx);
            query(&input, "sidebar", cx);
            let clear = cx.debug_bounds("sidebar-search-clear").unwrap();
            assert!(clear.right() <= px(width));
            cx.simulate_click(clear.center(), Default::default());
            cx.run_until_parked();
            assert_eq!(input.read_with(cx, |input, _| input.text().to_string()), "");
            shell.read_with(cx, |shell, _| {
                assert!(!shell.pinned_open && !shell.sessions_open && !shell.archived_open);
                assert!(shell.sidebar_collapsed_groups.contains("local"));
            });
            press_keys(cx, "escape");
            cx.run_until_parked();
            let reopened = open_search(&shell, cx);
            assert_eq!(
                reopened.read_with(cx, |input, _| input.text().to_string()),
                ""
            );
            shell.read_with(cx, |shell, _| {
                assert!(!shell.sidebar_search.as_ref().unwrap().include_archived)
            });
        }
    }
}

#[gpui::test]
fn sidebar_search_keyboard_tab_order_and_cmd_b(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "sidebar", cx);
    press_keys(cx, "tab");
    cx.update(|window, cx| {
        assert!(
            shell
                .read(cx)
                .sidebar_search
                .as_ref()
                .unwrap()
                .clear_focus
                .is_focused(window)
        )
    });
    press_keys(cx, "tab");
    cx.update(|window, cx| {
        assert!(
            shell
                .read(cx)
                .sidebar_search
                .as_ref()
                .unwrap()
                .archive_focus
                .is_focused(window)
        )
    });
    press_keys(cx, "shift-tab shift-tab");
    cx.update(|window, cx| {
        assert!(
            input.focus_handle(cx).is_focused(window),
            "reverse Tab must return to the search field"
        )
    });
    press_keys(cx, &platform_combo("mod-b"));
    cx.run_until_parked();
    shell.read_with(cx, |shell, _| {
        assert!(shell.settings.sidebar_collapsed);
        assert!(shell.sidebar_search.is_none());
    });
    assert!(cx.debug_bounds("sidebar-search-controls").is_none());
}

mod stability;
