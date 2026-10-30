use super::edge_cases::{open_search, query};
use super::*;

#[test]
fn sidebar_search_magnifier_has_a_local_visible_foreground_for_every_builtin_theme() {
    use harness_theme::{AccentSelection, SurfacePreference, ThemeRegistry};
    let registry = ThemeRegistry::builtin();
    for variant in registry.families.iter().flat_map(|family| &family.variants) {
        for surface in [
            SurfacePreference::ThemeDefault,
            SurfacePreference::Frosted,
            SurfacePreference::Opaque,
        ] {
            let theme = Theme::from_variant(variant, AccentSelection::ThemeDefault, surface);
            for size in [14.0, 16.0] {
                let mut icon = search_icon(&theme, size);
                // This is Svg::paint's actual gate: an inherited parent color
                // is insufficient and leaves this local value absent.
                let foreground = icon
                    .style()
                    .text
                    .color
                    .expect("SVG requires its own foreground to paint");
                assert_eq!(
                    foreground, theme.text_muted,
                    "{}: match adjacent sidebar icons",
                    variant.id
                );
                assert!(
                    foreground.a > 0.0,
                    "{}: foreground must not be transparent",
                    variant.id
                );
            }
        }
    }
}

#[test]
fn sidebar_search_matches_full_and_partial_ids_without_bypassing_scope() {
    let mut chats = vec![
        chat("aa11-bb22-cc33", "Unrelated title", false, "one"),
        chat("aa11-archived", "Different title", true, "one"),
        chat("aa11-other", "Another title", false, "two"),
        chat("aa11-child", "Child title", false, "one"),
    ];
    chats[3].parent_chat_id = Some(chats[0].id.clone());
    let ids = |query: &str, include_archived| {
        matching_chats(
            &chats,
            query,
            Some("one"),
            include_archived,
            SidebarSort::Created,
        )
        .into_iter()
        .map(|chat| chat.id.as_str())
        .collect::<Vec<_>>()
    };
    assert_eq!(ids("  AA11-BB22-CC33  ", false), ["aa11-bb22-cc33"]);
    assert_eq!(ids("bb22", false), ["aa11-bb22-cc33"]);
    assert_eq!(ids("AA11", false), ["aa11-bb22-cc33"]);
    assert_eq!(ids("aa11", true), ["aa11-archived", "aa11-bb22-cc33"]);
    assert!(ids("nonexistent-id", true).is_empty());
}

#[gpui::test]
fn sidebar_search_closed_does_not_take_tab_from_the_conversation(cx: &mut gpui::TestAppContext) {
    let (_dir, shell, cx) = fixture_with_conversation(cx, 400.0, true);
    cx.update(|window, cx| {
        let focus = shell.read(cx).composer.focus_handle(cx);
        window.focus(&focus, cx);
    });
    cx.simulate_input("ordinary draft");
    press_keys(cx, "tab");
    cx.update(|window, cx| {
        let shell = shell.read(cx);
        assert!(
            shell.composer.focus_handle(cx).is_focused(window),
            "Tab without a completion or list action must keep the conversation caret"
        );
        assert!(!shell.sidebar_search_trigger_focus.is_focused(window));
        assert!(shell.sidebar_search.is_none());
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
    });
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        assert!(
            shell.sidebar_search.is_none(),
            "Enter after Tab must not reveal hidden search"
        );
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
    });
}

#[gpui::test]
fn sidebar_search_archive_toggle_preserves_sidebar_row_geometry(cx: &mut gpui::TestAppContext) {
    for compact in [false, true] {
        for labels in [false, true] {
            let (_dir, shell, cx) = fixture(cx, 280.0);
            cx.update(|_, cx| {
                shell.update(cx, |shell, cx| {
                    shell.settings.sidebar_compact = compact;
                    shell.settings.sidebar_show_project_label = labels;
                    cx.notify();
                })
            });
            cx.run_until_parked();
            let normal = cx.debug_bounds("chat-active").unwrap();
            let _input = open_search(&shell, cx);
            let checkbox = cx.debug_bounds("sidebar-search-archived").unwrap();
            cx.simulate_click(checkbox.center(), Default::default());
            cx.run_until_parked();
            let result = cx.debug_bounds("palette-chat-active").unwrap();
            assert_eq!(
                result.size, normal.size,
                "archive scope must not change row presentation: compact={compact}, labels={labels}"
            );
        }
    }
}

#[gpui::test]
fn sidebar_search_archive_checkbox_uses_the_field_content_inset(cx: &mut gpui::TestAppContext) {
    for width in [224.0, 400.0] {
        let (_dir, shell, cx) = fixture(cx, width);
        let _input = open_search(&shell, cx);
        for _ in 0..2 {
            let controls = cx.debug_bounds("sidebar-search-controls").unwrap();
            let checkbox = cx.debug_bounds("sidebar-search-archived").unwrap();
            let glyph = cx.debug_bounds("sidebar-search-checkbox").unwrap();
            let label = cx.debug_bounds("sidebar-search-archive-label").unwrap();
            let field_icon = cx.debug_bounds("sidebar-search-field-icon").unwrap();
            assert_eq!(glyph.left(), controls.left() + px(Theme::SPACE_SM));
            assert_eq!(label.left(), glyph.right() + px(6.0));
            assert!((label.center().y - glyph.center().y).abs() <= px(1.0));
            // The field adds a one-pixel border around the same inner inset.
            assert!((glyph.left() - field_icon.left()).abs() <= px(1.0));
            assert!(glyph.left() > checkbox.left());
            assert!(checkbox.right() <= px(width));
            cx.simulate_click(checkbox.center(), Default::default());
            cx.run_until_parked();
        }
    }
}

#[gpui::test]
fn sidebar_search_id_query_opens_an_archived_match_without_restoring_it(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, shell, cx) = fixture(cx, 280.0);
    let input = open_search(&shell, cx);
    query(&input, "ARCHIVED", cx);
    assert!(cx.debug_bounds("sidebar-search-empty").is_some());
    let checkbox = cx.debug_bounds("sidebar-search-archived").unwrap();
    cx.simulate_click(checkbox.center(), Default::default());
    cx.update(|window, cx| window.focus(&input.focus_handle(cx), cx));
    press_keys(cx, "enter");
    shell.read_with(cx, |shell, cx| {
        let state = shell.state.read(cx);
        assert_eq!(state.selected_chat.as_deref(), Some("archived"));
        assert!(
            state
                .chats
                .iter()
                .find(|chat| chat.id == "archived")
                .unwrap()
                .archived
        );
    });
}
