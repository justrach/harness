use super::*;

fn assert_no_duplicate_actions(cx: &mut gpui::VisualTestContext) {
    assert!(cx.debug_bounds("sidebar-new-chat").is_none());
    // While search is open this selector belongs to the actual search input,
    // so only check its absence when search has been closed.
    assert!(cx.debug_bounds("sidebar-search-field").is_none());
}

fn seed_draft(shell: &Entity<Shell>, text: &str, cx: &mut gpui::VisualTestContext) {
    // The shortcut fixture has no agent catalog: seed its editor directly,
    // then exercise the real sidebar controls and key dispatch below.
    let input = shell.read_with(cx, |shell, cx| shell.composer.read(cx).input.clone());
    input.update(cx, |input, cx| input.set_text(text, cx));
    // Refresh the shell's cached chrome so debug bounds include its controls,
    // not just the editor subtree invalidated by the seeded text.
    shell.update(cx, |_, cx| cx.notify());
    cx.run_until_parked();
    input.read_with(cx, |input, _| assert_eq!(input.text(), text));
}

#[gpui::test]
fn sidebar_control_removal_layout_survives_empty_compact_and_many_tab_states(
    cx: &mut gpui::TestAppContext,
) {
    for width in [SIDEBAR_MIN, SIDEBAR_MAX] {
        for compact in [false, true] {
            for tab_count in [1, 25] {
                for populated in [false, true] {
                    let (_dir, shell, cx) = shortcut_fixture(cx);
                    shell.update(cx, |shell, cx| {
                        shell.settings.sidebar_width = width;
                        shell.settings.sidebar_compact = compact;
                        shell.chat_tabs = vec![Default::default(); tab_count];
                        if populated {
                            shell.state.update(cx, |state, cx| {
                                state.chats =
                                    vec![chat("current", "Current session", false, "one")];
                                state.select_chat(Some("current".into()), cx);
                            });
                        }
                        cx.notify();
                    });
                    cx.run_until_parked();
                    assert_no_duplicate_actions(cx);
                    let filter = cx.debug_bounds("spaces-filter").unwrap();
                    let trigger = cx.debug_bounds("sidebar-search-toggle").unwrap();
                    assert!(trigger.left() >= filter.right());
                    assert!(trigger.right() <= px(width));
                    assert!(filter.right() <= px(width));

                    let input = super::super::edge_cases::open_search(&shell, cx);
                    super::super::edge_cases::query(&input, "no matching session", cx);
                    assert!(cx.debug_bounds("sidebar-search-empty").is_some());
                    press_keys(cx, "escape escape");
                    assert_no_duplicate_actions(cx);
                    let restored = cx.debug_bounds("spaces-filter").unwrap();
                    assert_eq!(restored.size, filter.size);
                    assert_eq!(restored.left(), filter.left());
                    // Text layout may round by half a pixel between frames;
                    // the removed action block must not return as a gap.
                    assert!(
                        (restored.top() - filter.top()).abs() <= px(1.0),
                        "closing search must not leave a gap: width={width}, compact={compact}, tabs={tab_count}, populated={populated}"
                    );
                    shell.read_with(cx, |shell, cx| {
                        assert_eq!(shell.chat_tabs.len(), tab_count);
                        assert_eq!(
                            shell.state.read(cx).selected_chat.as_deref(),
                            populated.then_some("current")
                        );
                    });
                }
            }
        }
    }
}

#[gpui::test]
fn sidebar_control_removal_search_and_collapse_cycles_preserve_unsent_draft(
    cx: &mut gpui::TestAppContext,
) {
    for width in [SIDEBAR_MIN, SIDEBAR_MAX] {
        let (_dir, shell, cx) = shortcut_fixture(cx);
        shell.update(cx, |shell, cx| {
            shell.settings.sidebar_width = width;
            shell.chat_tabs = vec![Default::default()];
            cx.notify();
        });
        seed_draft(&shell, "keep this unsent draft", cx);
        for _ in 0..3 {
            let input = super::super::edge_cases::open_search(&shell, cx);
            super::super::edge_cases::query(&input, "missing", cx);
            let archive = cx.debug_bounds("sidebar-search-archived").unwrap();
            cx.simulate_click(archive.center(), Default::default());
            cx.run_until_parked();
            let trigger = cx.debug_bounds("sidebar-search-toggle").unwrap();
            cx.simulate_click(trigger.center(), Default::default());
            cx.run_until_parked();
            assert_no_duplicate_actions(cx);
            cx.update(|window, cx| {
                assert!(
                    shell
                        .read(cx)
                        .sidebar_search_trigger_focus
                        .is_focused(window)
                );
            });

            press_keys(cx, &platform_combo("mod-b"));
            shell.read_with(cx, |shell, _| assert!(shell.settings.sidebar_collapsed));
            press_keys(cx, &platform_combo("mod-f"));
            cx.update(|window, cx| {
                let shell = shell.read(cx);
                let search = shell.sidebar_search.as_ref().unwrap();
                assert!(!shell.settings.sidebar_collapsed);
                assert!(search.input.focus_handle(cx).is_focused(window));
                assert_eq!(search.input.read(cx).text(), "");
                assert!(
                    !search.include_archived,
                    "a new search resets its archive scope"
                );
            });
            press_keys(cx, "escape");
            assert_no_duplicate_actions(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_tabs.len(), 1);
                assert!(shell.state.read(cx).selected_chat.is_none());
                assert_eq!(
                    shell.composer.read(cx).input.read(cx).text(),
                    "keep this unsent draft"
                );
            });
        }
    }
}

#[gpui::test]
fn sidebar_control_removal_retained_new_tab_actions_preserve_split_and_draft(
    cx: &mut gpui::TestAppContext,
) {
    for collapsed in [false, true] {
        for split in [false, true] {
            for keyboard in [false, true] {
                let (_dir, shell, cx) = shortcut_fixture(cx);
                shell.update(cx, |shell, cx| {
                    shell.state.update(cx, |state, cx| {
                        state.chats = vec![
                            chat("current", "Current session", false, "one"),
                            chat("peer", "Peer session", false, "one"),
                        ];
                        state.select_chat(Some("current".into()), cx);
                    });
                    if split {
                        shell.chat_split = chat_split::ChatSplit::split(
                            None,
                            SplitAxis::Horizontal,
                            Some("peer".into()),
                            None,
                        );
                    }
                    cx.notify();
                });
                cx.run_until_parked();
                seed_draft(&shell, "draft in the original chat", cx);
                let layout = shell.read_with(cx, |shell, _| shell.chat_split.clone());
                let input = super::super::edge_cases::open_search(&shell, cx);
                super::super::edge_cases::query(&input, "no matching session", cx);
                if collapsed {
                    press_keys(cx, &platform_combo("mod-b"));
                }
                if keyboard {
                    // New chat is Ctrl+Shift+T off macOS; use this platform's default.
                    press_keys(
                        cx,
                        &platform_combo(crate::settings::ShortcutId::NewSession.default_combo()),
                    );
                } else {
                    let plus = cx.debug_bounds("titlebar-new-session").unwrap();
                    cx.simulate_click(plus.center(), Default::default());
                    cx.run_until_parked();
                }
                shell.read_with(cx, |shell, cx| {
                    assert_eq!(
                        shell.chat_tabs.len(),
                        2,
                        "one activation opens exactly one tab"
                    );
                    assert_eq!(shell.chat_tab, 1);
                    assert!(shell.state.read(cx).selected_chat.is_none());
                    assert!(shell.chat_split.is_none());
                    assert_eq!(shell.chat_tabs[0].selected.as_deref(), Some("current"));
                    assert_eq!(shell.chat_tabs[0].split, layout);
                    assert_eq!(shell.composer.read(cx).input.read(cx).text(), "");
                });
                shell.update_in(cx, |shell, window, cx| shell.switch_chat_tab(0, window, cx));
                cx.run_until_parked();
                shell.read_with(cx, |shell, cx| {
                    assert_eq!(
                        shell.state.read(cx).selected_chat.as_deref(),
                        Some("current")
                    );
                    assert_eq!(shell.chat_split, layout);
                    assert_eq!(
                        shell.composer.read(cx).input.read(cx).text(),
                        "draft in the original chat",
                        "draft restored: collapsed={collapsed}, split={split}, keyboard={keyboard}"
                    );
                });
            }
        }
    }
}
