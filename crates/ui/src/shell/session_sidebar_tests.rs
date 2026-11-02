use super::*;

#[gpui::test]
fn workspace_session_sidebar_history_keyboard_access_survives_collapse(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
    host.update(cx, |shell, _, cx| {
        shell.debug_gate = Some(GatePhase::Ready);
        shell.boot_restored = true;
        shell.reduced_motion = true;
        shell.ensure_workspace_sessions(cx);
        shell.sync_panel_workspace(cx);
        cx.notify();
    })
    .unwrap();
    let mut visual = gpui::VisualTestContext::from_window(host.into(), cx);
    visual.simulate_resize(gpui::size(px(980.0), px(760.0)));
    for (collapsed, key) in [(false, "enter"), (true, "space")] {
        host.update(cx, |shell, _, cx| {
            shell.settings.sidebar_collapsed = collapsed;
            shell.sidebar_tween = None;
            cx.notify();
        })
        .unwrap();
        visual.run_until_parked();
        visual.update(|window, cx| window.draw(cx).clear());
        host.update(cx, |shell, window, cx| {
            let focus = shell.session_sidebar.controls["chat-history"].clone();
            window.focus(&focus, cx);
        })
        .unwrap();
        visual.simulate_keystrokes(key);
        visual.run_until_parked();
        host.read_with(cx, |shell, _| {
            assert!(shell.command_palette.is_some());
            assert_eq!(shell.settings.sidebar_collapsed, collapsed);
            assert!(matches!(shell.route, Route::Chat));
        })
        .unwrap();
        visual.simulate_keystrokes("escape");
        visual.run_until_parked();
        host.read_with(cx, |shell, _| assert!(shell.command_palette.is_none()))
            .unwrap();
    }
}

#[gpui::test]
fn workspace_session_sidebar_rename_commits_to_the_session_only(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, _, cx| {
            shell.create_workspace_session(cx);
            let row = shell
                .workspace_session_sidebar_rows(cx)
                .into_iter()
                .find(|row| row.active)
                .unwrap();
            let chats_before = shell
                .state
                .read(cx)
                .chats
                .iter()
                .map(|chat| (chat.id.clone(), chat.title.clone()))
                .collect::<Vec<_>>();
            shell.begin_workspace_session_rename(row.id.clone(), row.title, cx);
            let input = shell.session_sidebar.rename.as_ref().unwrap().input.clone();
            input.update(cx, |input, cx| input.set_text("  Release planning  ", cx));
            shell.commit_workspace_session_rename(cx);
            assert!(shell.session_sidebar.rename.is_none());
            assert_eq!(
                shell
                    .workspace_session_sidebar_rows(cx)
                    .into_iter()
                    .find(|candidate| candidate.id == row.id)
                    .unwrap()
                    .title,
                "Release planning"
            );
            assert_eq!(
                shell
                    .state
                    .read(cx)
                    .chats
                    .iter()
                    .map(|chat| (chat.id.clone(), chat.title.clone()))
                    .collect::<Vec<_>>(),
                chats_before,
                "renaming a workspace session never renames its conversations"
            );
        })
        .unwrap();
}

#[gpui::test]
fn workspace_session_sidebar_empty_rename_stays_editable_and_escape_cancels(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    window
        .update(cx, |shell, window, cx| {
            shell.create_workspace_session(cx);
            let row = shell
                .workspace_session_sidebar_rows(cx)
                .into_iter()
                .find(|row| row.active)
                .unwrap();
            shell.begin_workspace_session_rename(row.id.clone(), row.title.clone(), cx);
            let input = shell.session_sidebar.rename.as_ref().unwrap().input.clone();
            input.update(cx, |input, cx| input.set_text("   ", cx));
            shell.commit_workspace_session_rename(cx);
            assert!(shell.session_sidebar.rename.as_ref().unwrap().invalid);
            assert_eq!(
                shell
                    .workspace_session_sidebar_rows(cx)
                    .into_iter()
                    .find(|candidate| candidate.id == row.id)
                    .unwrap()
                    .title,
                row.title
            );
            shell.cancel_workspace_session_rename(window, cx);
            assert!(shell.session_sidebar.rename.is_none());
            let focus = &shell.session_sidebar.controls[&format!("session-row-{}", row.id)];
            assert!(focus.is_focused(window));
        })
        .unwrap();
}

#[gpui::test]
fn workspace_session_sidebar_close_requires_confirmation(cx: &mut gpui::TestAppContext) {
    let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
    let (id, before, count) = host
        .update(cx, |shell, _, cx| {
            shell.debug_gate = Some(GatePhase::Ready);
            shell.reduced_motion = true;
            shell.ensure_workspace_sessions(cx);
            shell.create_workspace_session(cx);
            let id = shell.chat_tabs[shell.chat_tab].id.clone();
            let before = shell
                .state
                .read(cx)
                .chats
                .iter()
                .map(|chat| (chat.id.clone(), chat.archived))
                .collect::<Vec<_>>();
            let count = shell.chat_tabs.len();
            shell.session_sidebar.hovered = Some(id.clone());
            (id, before, count)
        })
        .unwrap();
    // Render the sidebar and finish initial composer focus before interacting.
    let mut visual = gpui::VisualTestContext::from_window(host.into(), cx);
    visual.simulate_resize(gpui::size(px(980.0), px(760.0)));
    visual.run_until_parked();
    visual.update(|window, cx| window.draw(cx).clear());
    host.update(cx, |shell, window, cx| {
        let focus = shell.session_sidebar_focus(format!("session-close-{id}"), cx);
        window.focus(&focus, cx);
        shell.perform_session_sidebar_action(&id, "close", window, cx);
        assert_eq!(
            shell.chat_tabs.len(),
            count,
            "request must not close the session"
        );
        assert!(shell.closed_chat_tabs.is_empty());
    })
    .unwrap();
    assert!(cx.has_pending_prompt());
    cx.simulate_prompt_answer("Cancel");
    cx.run_until_parked();
    host.update(cx, |shell, window, cx| {
        assert_eq!(shell.chat_tabs.len(), count);
        assert!(shell.chat_tabs.iter().any(|tab| tab.id == id));
        assert!(shell.closed_chat_tabs.is_empty());
        assert!(shell.session_sidebar.close_pending.is_none());
        assert!(shell.session_sidebar.controls[&format!("session-close-{id}")].is_focused(window));
        shell.perform_session_sidebar_action(&id, "close", window, cx);
        // Repeated input must not queue another alert or close a different session.
        let other = shell
            .chat_tabs
            .iter()
            .find(|tab| tab.id != id)
            .unwrap()
            .id
            .clone();
        shell.perform_session_sidebar_action(&other, "close", window, cx);
    })
    .unwrap();
    cx.simulate_prompt_answer("Close session");
    cx.run_until_parked();
    assert!(!cx.has_pending_prompt());
    host.update(cx, |shell, window, cx| {
        assert_eq!(shell.chat_tabs.len(), count - 1);
        assert!(shell.chat_tabs.iter().all(|tab| tab.id != id));
        let active = &shell.chat_tabs[shell.chat_tab].id;
        assert!(
            shell.session_sidebar.controls[&format!("session-row-{active}")].is_focused(window)
        );
        assert_eq!(
            shell
                .state
                .read(cx)
                .chats
                .iter()
                .map(|chat| (chat.id.clone(), chat.archived))
                .collect::<Vec<_>>(),
            before,
            "confirmed session close preserves conversations"
        );
        assert!(shell.reopen_closed_chat_tab(window, cx));
        assert!(shell.chat_tabs.iter().any(|tab| tab.id == id));
    })
    .unwrap();
}

#[gpui::test]
fn workspace_session_sidebar_menu_close_confirms_last_session(cx: &mut gpui::TestAppContext) {
    let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
    let id = host
        .update(cx, |shell, window, cx| {
            shell.ensure_workspace_sessions(cx);
            let id = shell.chat_tabs[shell.chat_tab].id.clone();
            assert_eq!(shell.chat_tabs.len(), 1);
            shell.open_workspace_session_menu(
                id.clone(),
                false,
                gpui::point(px(20.), px(80.)),
                window,
                cx,
            );
            shell.activate_workspace_session_menu(3, window, cx);
            assert!(shell.session_sidebar.menu.is_none());
            assert_eq!(shell.chat_tabs[0].id, id);
            id
        })
        .unwrap();
    assert!(cx.has_pending_prompt());
    cx.simulate_prompt_answer("Close session");
    cx.run_until_parked();
    host.read_with(cx, |shell, _| {
        assert_eq!(
            shell.chat_tabs.len(),
            1,
            "last close leaves a usable empty session"
        );
        assert_ne!(shell.chat_tabs[0].id, id);
        assert_eq!(shell.closed_chat_tabs.last().unwrap().tab.id, id);
    })
    .unwrap();
}

#[gpui::test]
fn workspace_session_sidebar_icon_and_pin_survive_parking_restore_and_reopen(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
    host.update(cx, |shell, _, cx| {
        shell.create_workspace_session(cx);
        let id = shell.chat_tabs[shell.chat_tab].id.clone();
        shell.set_workspace_session_icon(&id, Some("star"), cx);
        shell.set_workspace_session_pinned(&id, true, cx);
        shell.create_workspace_session(cx);
        shell.activate_workspace_session(&id, cx);
        let parked = shell.park_chat_tab(cx);
        assert_eq!(parked.session_icon.as_deref(), Some("star"));
        assert!(parked.pinned);
        let bytes = serde_json::to_vec(&shell.settings.chat_tabs).unwrap();
        shell.settings.chat_tabs = serde_json::from_slice(&bytes).unwrap();
        shell.chat_tabs.clear();
        assert!(shell.restore_project_tabs(cx));
        let restored = shell.chat_tabs.iter().find(|tab| tab.id == id).unwrap();
        assert_eq!(restored.session_icon.as_deref(), Some("star"));
        assert!(restored.pinned);
        assert_eq!(shell.chat_tabs[shell.chat_tab].id, id);
        shell.close_workspace_session(&id, cx);
        assert!(shell.reopen_closed_chat_tab_without_window(cx));
        let reopened = &shell.chat_tabs[shell.chat_tab];
        assert_eq!(reopened.id, id);
        assert_eq!(reopened.session_icon.as_deref(), Some("star"));
        assert!(reopened.pinned);
    })
    .unwrap();
}

#[gpui::test]
fn workspace_session_sidebar_emoji_survives_parking_restore_and_reopen(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
    host.update(cx, |shell, _, cx| {
        for emoji in ["👩🏽‍💻", "🇸🇬", "👨‍👩‍👧‍👦"] {
            let key = session_icon::emoji_key(emoji).unwrap();
            shell.create_workspace_session(cx);
            let id = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.set_workspace_session_icon(&id, Some(&key), cx);
            // An invalid edit must not replace the existing complete icon.
            shell.set_workspace_session_icon(&id, Some("emoji:🚀🐱"), cx);
            shell.create_workspace_session(cx);
            shell.activate_workspace_session(&id, cx);
            assert_eq!(
                shell.park_chat_tab(cx).session_icon.as_deref(),
                Some(key.as_str())
            );

            let bytes = serde_json::to_vec(&shell.settings.chat_tabs).unwrap();
            shell.settings.chat_tabs = serde_json::from_slice(&bytes).unwrap();
            shell.chat_tabs.clear();
            assert!(shell.restore_project_tabs(cx));
            let restored = shell.chat_tabs.iter().find(|tab| tab.id == id).unwrap();
            assert_eq!(restored.session_icon.as_deref(), Some(key.as_str()));
            let row = shell
                .workspace_session_sidebar_rows(cx)
                .into_iter()
                .find(|row| row.id == id)
                .unwrap();
            assert_eq!(row.icon, session_icon::SessionIcon::Emoji(emoji.into()));

            shell.close_workspace_session(&id, cx);
            assert!(shell.reopen_closed_chat_tab_without_window(cx));
            let reopened = &shell.chat_tabs[shell.chat_tab];
            assert_eq!(reopened.id, id);
            assert_eq!(reopened.session_icon.as_deref(), Some(key.as_str()));
        }
    })
    .unwrap();
}

#[gpui::test]
fn workspace_session_sidebar_reorder_preserves_active_draft_and_visit_history(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
    host.update(cx, |shell, _, cx| {
        shell.boot_restored = true;
        shell.chat_tabs = ["a", "b", "c", "d"]
            .into_iter()
            .map(|id| chat_tabs::ChatTab {
                id: id.into(),
                title: Some(id.into()),
                ..Default::default()
            })
            .collect();
        shell.chat_tab = 1;
        shell.chat_tab_history = vec![0, 2, 1];
        shell.composer.update(cx, |composer, cx| {
            composer.set_canvas_input(
                crate::pickers::CanvasInput {
                    text: "Keep this unsent draft".into(),
                    ..Default::default()
                },
                cx,
            )
        });
        let draft = shell.current_canvas_draft(cx);
        shell.set_workspace_session_pinned("c", true, cx);
        assert_eq!(
            shell
                .workspace_session_sidebar_rows(cx)
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["c", "a", "b", "d"]
        );
        shell.move_workspace_session("d", "a", true, cx);
        assert_eq!(
            shell
                .workspace_session_sidebar_rows(cx)
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["c", "d", "a", "b"]
        );
        assert_eq!(shell.chat_tabs[shell.chat_tab].id, "b");
        assert_eq!(shell.current_canvas_draft(cx), draft);
        assert_eq!(
            shell
                .chat_tab_history
                .iter()
                .map(|ix| shell.chat_tabs[*ix].id.as_str())
                .collect::<Vec<_>>(),
            ["a", "c", "b"]
        );
        assert_eq!(
            shell.settings.session_overview_order,
            ["c", "d", "a", "b"].map(|id| Some(id.into()))
        );
        shell.move_workspace_session("d", "c", true, cx);
        assert!(
            shell
                .chat_tabs
                .iter()
                .find(|tab| tab.id == "d")
                .unwrap()
                .pinned
        );
        assert_eq!(
            shell
                .workspace_session_sidebar_rows(cx)
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["d", "c", "a", "b"]
        );
        shell.set_workspace_session_pinned("d", false, cx);
        assert_eq!(
            shell
                .workspace_session_sidebar_rows(cx)
                .iter()
                .map(|row| row.id.as_str())
                .collect::<Vec<_>>(),
            ["c", "d", "a", "b"]
        );
    })
    .unwrap();
}

#[gpui::test]
fn workspace_session_sidebar_menu_edits_target_without_switching_sessions(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
    host.update(cx, |shell, window, cx| {
        shell.create_workspace_session(cx);
        let target = shell.chat_tabs[shell.chat_tab].id.clone();
        shell.create_workspace_session(cx);
        let active = shell.chat_tabs[shell.chat_tab].id.clone();
        shell.open_workspace_session_menu(
            target.clone(),
            false,
            gpui::point(px(16.0), px(64.0)),
            window,
            cx,
        );
        shell.activate_workspace_session_menu(2, window, cx);
        assert!(
            shell
                .chat_tabs
                .iter()
                .find(|tab| tab.id == target)
                .unwrap()
                .pinned
        );
        assert_eq!(shell.chat_tabs[shell.chat_tab].id, active);
        shell.open_workspace_session_menu(
            target.clone(),
            true,
            gpui::point(px(16.0), px(64.0)),
            window,
            cx,
        );
        shell.activate_workspace_session_menu(3, window, cx);
        assert_eq!(
            shell
                .chat_tabs
                .iter()
                .find(|tab| tab.id == target)
                .unwrap()
                .session_icon
                .as_deref(),
            Some("code")
        );
        assert_eq!(shell.chat_tabs[shell.chat_tab].id, active);
        assert!(!shell.session_sidebar.menu_is_open());
    })
    .unwrap();
}

struct SessionMenuHost {
    shell: Entity<Shell>,
    _updates: Subscription,
}

impl Render for SessionMenuHost {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.shell.update(cx, |shell, cx| {
            div()
                .size_full()
                .when_some(shell.render_workspace_session_menu(cx), |el, menu| {
                    el.child(menu)
                })
        })
    }
}

#[gpui::test]
fn workspace_session_sidebar_context_and_icon_menus_render(cx: &mut gpui::TestAppContext) {
    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    let shell = window
        .update(cx, |shell, _, cx| {
            shell.create_workspace_session(cx);
            cx.entity()
        })
        .unwrap();
    let (_, cx) = cx.add_window_view(|_, cx| {
        let updates = cx.observe(&shell, |_, _, cx| cx.notify());
        SessionMenuHost {
            shell: shell.clone(),
            _updates: updates,
        }
    });
    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.open_workspace_session_menu(
                shell.chat_tabs[shell.chat_tab].id.clone(),
                false,
                gpui::point(px(16.0), px(64.0)),
                window,
                cx,
            );
        });
        window.draw(cx).clear();
    });
    assert!(cx.debug_bounds("workspace-session-menu").is_some());
    for index in 0..4 {
        assert!(
            cx.debug_bounds(format!("workspace-session-menu-row-{index}").leak())
                .is_some()
        );
    }

    cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            shell.activate_workspace_session_menu(1, window, cx);
            shell.set_workspace_session_picker_tab(
                super::super::session_icon_catalog::IconPickerTab::Icons,
                window,
                cx,
            );
        });
        window.draw(cx).clear();
    });
    for index in 0..SESSION_ICONS.len() {
        assert!(
            cx.debug_bounds(format!("session-icon-choice-{index}").leak())
                .is_some()
        );
    }
}

#[gpui::test]
fn workspace_session_sidebar_icon_picker_search_tabs_clear_and_keyboard_work(
    cx: &mut gpui::TestAppContext,
) {
    use super::super::session_icon_catalog::IconPickerTab;

    let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    cx.update(|cx| crate::composer::init(cx, Default::default()));
    let (shell, target, active) = window
        .update(cx, |shell, _, cx| {
            shell.create_workspace_session(cx);
            let target = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.set_workspace_session_icon(&target, Some("star"), cx);
            shell.create_workspace_session(cx);
            let active = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.set_workspace_session_icon(&active, Some("code"), cx);
            (cx.entity(), target, active)
        })
        .unwrap();
    let (_, cx) = cx.add_window_view(|_, cx| {
        let updates = cx.observe(&shell, |_, _, cx| cx.notify());
        SessionMenuHost {
            shell: shell.clone(),
            _updates: updates,
        }
    });
    let open = |cx: &mut gpui::VisualTestContext| {
        cx.update(|window, cx| {
            shell.update(cx, |shell, cx| {
                shell.open_workspace_session_menu(
                    target.clone(),
                    true,
                    gpui::point(px(16.0), px(64.0)),
                    window,
                    cx,
                );
                let input = shell
                    .session_sidebar
                    .menu
                    .as_ref()
                    .unwrap()
                    .search_input
                    .clone();
                window.focus(&input.focus_handle(cx), cx);
            });
            window.draw(cx).clear();
        });
        assert!(cx.debug_bounds("session-icon-search").is_some());
    };
    let click = |cx: &mut gpui::VisualTestContext, selector: &'static str| {
        cx.update(|window, cx| window.draw(cx).clear());
        let bounds = cx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("missing {selector}"));
        cx.simulate_click(bounds.center(), gpui::Modifiers::default());
        cx.update(|window, cx| window.draw(cx).clear());
    };
    let assert_icon = |cx: &mut gpui::VisualTestContext, key: Option<&str>| {
        cx.update(|_, cx| {
            let shell = shell.read(cx);
            assert_eq!(
                shell
                    .chat_tabs
                    .iter()
                    .find(|tab| tab.id == target)
                    .unwrap()
                    .session_icon
                    .as_deref(),
                key
            );
            assert_eq!(
                shell.chat_tabs[shell.chat_tab].id, active,
                "editing an inactive session must not activate it"
            );
            assert_eq!(
                shell.chat_tabs[shell.chat_tab].session_icon.as_deref(),
                Some("code")
            );
        });
    };

    open(cx);
    cx.update(|_, cx| {
        assert_eq!(
            shell
                .read(cx)
                .session_sidebar
                .menu
                .as_ref()
                .unwrap()
                .picker_tab,
            IconPickerTab::Icons
        )
    });
    click(cx, "session-icon-tab-emoji");
    assert!(
        cx.debug_bounds("session-icon-heading-smileys_emotion")
            .is_some()
    );
    let card = cx.debug_bounds("workspace-session-menu").unwrap();
    let viewport = cx.debug_bounds("session-icon-scroll-viewport").unwrap();
    assert!(
        card.bottom() - viewport.bottom() <= px(1.0),
        "the scroll clip must meet the card border without a padded ledge"
    );
    cx.simulate_keystrokes("down right");
    cx.update(|window, cx| {
        let shell = shell.read(cx);
        let menu = shell.session_sidebar.menu.as_ref().unwrap();
        assert!(menu.focus.is_focused(window), "Down enters the grid");
        assert_eq!(menu.selected, 1, "Right moves one grid cell");
    });
    cx.simulate_keystrokes("up");
    cx.update(|window, cx| {
        let shell = shell.read(cx);
        let menu = shell.session_sidebar.menu.as_ref().unwrap();
        assert!(
            menu.search_input.focus_handle(cx).is_focused(window),
            "Up from the first row returns to search"
        );
    });
    let first_person = cx.update(|window, cx| {
        shell.update(cx, |shell, cx| {
            let menu = shell.session_sidebar.menu.as_mut().unwrap();
            let first_person = menu
                .choices
                .iter()
                .position(|choice| choice.category.as_deref() == Some("people_body"))
                .unwrap();
            menu.selected = first_person - 1;
            window.focus(&menu.focus, cx);
            first_person
        })
    });
    cx.simulate_keystrokes("down");
    cx.update(|window, cx| {
        assert_eq!(
            shell
                .read(cx)
                .session_sidebar
                .menu
                .as_ref()
                .unwrap()
                .selected,
            first_person,
            "Down crosses the category heading without skipping a choice"
        );
        window.draw(cx).clear();
    });
    assert!(
        cx.debug_bounds("session-icon-heading-people_body")
            .is_some()
    );
    cx.simulate_keystrokes("up");
    cx.update(|_, cx| {
        assert_eq!(
            shell
                .read(cx)
                .session_sidebar
                .menu
                .as_ref()
                .unwrap()
                .selected,
            first_person - 1
        )
    });
    click(cx, "session-icon-category-people_body");
    assert!(
        cx.debug_bounds("session-icon-heading-people_body")
            .is_some()
    );
    cx.update(|_, cx| {
        assert!(
            shell
                .read(cx)
                .session_sidebar
                .menu
                .as_ref()
                .unwrap()
                .choices
                .iter()
                .all(|choice| choice.category.as_deref() == Some("people_body"))
        )
    });
    cx.simulate_input("rocket");
    cx.simulate_keystrokes("left right space");
    cx.update(|_, cx| {
        let shell = shell.read(cx);
        let menu = shell.session_sidebar.menu.as_ref().unwrap();
        assert_eq!(
            menu.selected, 0,
            "input arrows must not move the icon-grid cursor"
        );
        assert_eq!(menu.search_input.read(cx).text().trim(), "rocket");
        assert_eq!(menu.choices[0].key, "emoji:🚀");
    });
    assert_icon(cx, Some("star"));
    cx.simulate_keystrokes("enter");
    cx.update(|_, cx| assert!(shell.read(cx).session_sidebar.menu.is_none()));
    assert_icon(cx, Some("emoji:🚀"));

    open(cx);
    cx.simulate_input("🚀🐱");
    cx.simulate_keystrokes("enter");
    cx.update(|_, cx| {
        assert!(
            shell
                .read(cx)
                .session_sidebar
                .menu
                .as_ref()
                .unwrap()
                .choices
                .is_empty()
        )
    });
    assert_icon(cx, Some("emoji:🚀"));
    cx.simulate_keystrokes("escape");
    cx.update(|_, cx| assert!(shell.read(cx).session_sidebar.menu.is_none()));

    open(cx);
    cx.simulate_input("👩🏽‍💻");
    cx.update(|_, cx| {
        assert_eq!(
            shell
                .read(cx)
                .session_sidebar
                .menu
                .as_ref()
                .unwrap()
                .choices[0]
                .key,
            "emoji:👩🏽‍💻"
        )
    });
    click(cx, "session-icon-choice-0");
    cx.update(|_, cx| assert!(shell.read(cx).session_sidebar.menu.is_none()));
    assert_icon(cx, Some("emoji:👩🏽‍💻"));

    open(cx);
    cx.simulate_input("rocket");
    click(cx, "session-icon-tab-icons");
    cx.update(|_, cx| {
        let shell = shell.read(cx);
        let menu = shell.session_sidebar.menu.as_ref().unwrap();
        assert_eq!(menu.picker_tab, IconPickerTab::Icons);
        assert!(
            menu.search_input.read(cx).text().is_empty(),
            "changing tabs resets the search"
        );
        assert_eq!(menu.choices.len(), SESSION_ICONS.len());
        assert_eq!(menu.selected, 0);
    });
    cx.simulate_input("web");
    click(cx, "session-icon-choice-0");
    assert_icon(cx, Some("globe"));

    open(cx);
    cx.simulate_input("code");
    click(cx, "session-icon-tab-emoji");
    cx.update(|_, cx| {
        let shell = shell.read(cx);
        let menu = shell.session_sidebar.menu.as_ref().unwrap();
        assert!(menu.search_input.read(cx).text().is_empty());
        assert!(menu.choices.len() > 3000);
    });
    cx.simulate_input("🇸🇬");
    cx.simulate_keystrokes("escape");
    cx.update(|_, cx| assert!(shell.read(cx).session_sidebar.menu.is_none()));
    assert_icon(cx, Some("globe"));

    open(cx);
    click(cx, "session-icon-clear");
    cx.update(|_, cx| assert!(shell.read(cx).session_sidebar.menu.is_none()));
    assert_icon(cx, None);
}

#[test]
fn workspace_session_sidebar_legacy_metadata_has_safe_defaults() {
    let old: crate::settings::SavedChatTab =
        serde_json::from_str(r#"{"id":"old","title":"Existing session"}"#).unwrap();
    assert!(!old.pinned);
    assert!(old.session_icon.is_none());
    assert_eq!(session_icon_glyph(None), icons::WIDGET);
    assert_eq!(session_icon_glyph(Some("removed-icon")), icons::WIDGET);
}

#[gpui::test]
fn workspace_session_projectless_defaults_preserve_previous_session_and_explicit_project(
    cx: &mut gpui::TestAppContext,
) {
    let (dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
    crate::settings::composer::ComposerDefaults {
        no_project: true,
        device: Some("remote".into()),
        ..Default::default()
    }
    .save(dir.path())
    .unwrap();
    window
        .update(cx, |shell, _, cx| {
            shell.ensure_workspace_sessions(cx);
            let previous = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.settings.space_filter = None;
            shell.create_workspace_session(cx);
            let projectless = shell.chat_tabs[shell.chat_tab].id.clone();
            assert!(shell.state.read(cx).no_project);
            assert!(shell.chat_tabs[shell.chat_tab].project.is_none());
            assert_eq!(
                shell.state.read(cx).effective_device_id().as_deref(),
                Some("remote")
            );

            shell.activate_workspace_session(&previous, cx);
            assert_eq!(
                shell.chat_tabs[shell.chat_tab].project.as_deref(),
                Some("a")
            );
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
            assert!(!shell.state.read(cx).no_project);
            shell.activate_workspace_session(&projectless, cx);
            assert!(shell.state.read(cx).no_project);
            assert_eq!(
                shell.state.read(cx).effective_device_id().as_deref(),
                Some("remote")
            );

            // An explicit project choice wins over the saved opt-out.
            shell.set_space_filter(Some("b".into()), cx);
            shell.create_workspace_session(cx);
            assert_eq!(
                shell.chat_tabs[shell.chat_tab].project.as_deref(),
                Some("b")
            );
            assert_eq!(shell.state.read(cx).selected_space.as_deref(), Some("b"));
            assert!(!shell.state.read(cx).no_project);
        })
        .unwrap();
}
