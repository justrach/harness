use super::*;
use crate::markdown::{render, selection};
use gpui::{MouseButton, MouseDownEvent, MouseUpEvent, Point, ScrollDelta, ScrollWheelEvent};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
use harness_proto::ToolCall;

mod archive_edges;
mod gesture_edges;
#[cfg(any(target_os = "macos", target_os = "linux"))]
mod link_owner;

/// Keep the real Shell and peer-pane capture handlers, transcript, markdown and
/// tool controls, without booting an engine or rendering unrelated chrome.
struct InteractionPanes(Entity<Shell>);

impl Render for InteractionPanes {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            let theme = Theme::of(cx).clone();
            let Some(split) = shell.chat_split.as_ref() else {
                // The split closed: one ordinary transcript pane remains.
                return div()
                    .debug_selector(|| "peer-column".into())
                    .w(px(480.0))
                    .h_full()
                    .flex()
                    .flex_col()
                    .pt(px(Theme::TITLEBAR_HEIGHT))
                    .child(div().flex_1().min_h_0().child(shell.transcript.clone()));
            };
            let (focus, len, axis) = (split.focus, split.panes.len(), split.axis);
            div()
                .size_full()
                .flex()
                .when(axis == SplitAxis::Vertical, |el| el.flex_col())
                .children((0..len).map(|ix| {
                    let pane = if ix == focus {
                        // Match the peer's geometry when its entity is promoted.
                        div()
                            .size_full()
                            .flex()
                            .flex_col()
                            .pt(px(Theme::TITLEBAR_HEIGHT))
                            .child(
                                div()
                                    .flex_none()
                                    .px(px(14.0))
                                    .pb(px(6.0))
                                    .text_size(crate::typography::ui_rems(12.0))
                                    .child(SharedString::from("Session")),
                            )
                            .child(div().flex_1().min_h_0().child(shell.transcript.clone()))
                            .into_any_element()
                    } else {
                        let id = shell.chat_split.as_ref().unwrap().panes[ix].clone();
                        shell.render_peer_chat_pane(ix, id.as_deref(), &theme, cx)
                    };
                    div()
                        .when(axis == SplitAxis::Horizontal, |el| el.w(px(480.0)).h_full())
                        .when(axis == SplitAxis::Vertical, |el| el.w_full().h(px(320.0)))
                        .flex_none()
                        .debug_selector(move || match ix {
                            0 => "peer-column".into(),
                            1 => "current-column".into(),
                            _ => format!("extra-column-{ix}"),
                        })
                        .child(pane)
                }))
        })
    }
}

fn reply(text: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        id: "reply".into(),
        role: MessageRole::Assistant,
        parts: vec![MessagePart::Text {
            id: "text".into(),
            text: text.into(),
        }],
        created_at: 0,
        device_id: "local".into(),
        status: Some(MessageStatus::Complete),
        continuation_of: None,
        duration_ms: None,
    }
}

fn with_panes(
    cx: &mut gpui::TestAppContext,
    entries: Vec<SessionMessageEntry>,
    run: impl FnOnce(
        Entity<Shell>,
        Entity<Transcript>,
        Entity<Transcript>,
        &mut gpui::VisualTestContext,
    ),
) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        settings::init(settings::UiSettings::default(), dir.path(), cx);
        crate::motion::set_reduced_motion(cx, true);
    });
    let (host, cx) = cx.add_window_view(|_, cx| {
        InteractionPanes(cx.new(|cx| {
            let state = cx.new(|_| AppState::new());
            state.update(cx, |state, cx| {
                state.chats = ["current", "peer"]
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "title": "Session",
                            "archived": false, "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .into();
                state.select_chat(Some("current".into()), cx);
                let mut current =
                    reply("Current response must not be selected instead of the peer.");
                current.id = "current-reply".into();
                state.transcript = vec![current];
                state.transcript_replayed = true;
                state.transcript_revision += 1;
                state.set_subagent_snapshot("peer".into(), entries);
            });
            let mut shell = Shell::new(
                state,
                EngineBootConfig {
                    data_dir: dir.path().into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            shell.chat_split =
                ChatSplit::split(None, SplitAxis::Horizontal, Some("peer".into()), None);
            shell.sync_chat_panes(cx);
            shell
                .transcript
                .update(cx, |transcript, cx| transcript.set_rail_enabled(false, cx));
            shell
        }))
    });
    cx.simulate_resize(gpui::size(px(960.0), px(640.0)));
    draw(cx);
    let shell = host.read_with(cx, |host, _| host.0.clone());
    let (peer, current) = shell.read_with(cx, |shell, _| {
        (
            shell.peer_chat_views["peer"].transcript.clone(),
            shell.transcript.clone(),
        )
    });
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
    });
    run(shell, peer, current, cx);
    // Parameterized gestures create multiple windows with fixture row IDs.
    // Release their painted selection owners before the next window starts.
    cx.update(|window, _| window.remove_window());
    drop(host);
    cx.run_until_parked();
}

fn draw(cx: &mut gpui::VisualTestContext) {
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
}

fn key(_transcript: &Entity<Transcript>, row_key: &str) -> String {
    row_key.to_owned()
}

fn text_point(transcript: &Entity<Transcript>, row_key: &str) -> Point<gpui::Pixels> {
    render::selection_test_bounds(&key(transcript, row_key)).origin + gpui::point(px(2.0), px(9.0))
}

fn assert_peer_active(
    shell: &Entity<Shell>,
    peer: &Entity<Transcript>,
    current: &Entity<Transcript>,
    cx: &mut gpui::VisualTestContext,
) {
    draw(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
        assert_eq!(
            shell.transcript.entity_id(),
            peer.entity_id(),
            "activation must promote the interacted-with entity, not replace it"
        );
        assert_eq!(
            shell.peer_chat_views["current"].transcript.entity_id(),
            current.entity_id(),
            "the outgoing pane must retain its entity too"
        );
    });
}

#[derive(Clone, Copy, Debug)]
enum SelectionGesture {
    Drag,
    DoubleClick,
    Multiline,
    Code,
    LongPress,
}

#[gpui::test]
fn selecting_in_an_inactive_pane_activates_and_preserves_selection(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for gesture in [
        SelectionGesture::Drag,
        SelectionGesture::DoubleClick,
        SelectionGesture::Multiline,
        SelectionGesture::Code,
        SelectionGesture::LongPress,
    ] {
        let text = if matches!(gesture, SelectionGesture::Code) {
            "```text\nselectable\nsecond\n```"
        } else {
            "Selectable response text.\n\nAnother selectable paragraph."
        };
        with_panes(cx, vec![reply(text)], |shell, peer, current, cx| {
            // The peer is painted before the primary, so this also checks
            // main's existing per-transcript selection-owner isolation.
            let first = if matches!(gesture, SelectionGesture::Code) {
                "reply#text.0-code0-line0"
            } else {
                "reply#text.0:0"
            };
            let start = text_point(&peer, first);
            let count = if matches!(gesture, SelectionGesture::DoubleClick) {
                2
            } else {
                1
            };
            cx.simulate_event(MouseDownEvent {
                button: MouseButton::Left,
                position: start,
                click_count: count,
                ..Default::default()
            });
            let end = match gesture {
                SelectionGesture::DoubleClick => start,
                SelectionGesture::Multiline => {
                    text_point(&peer, "reply#text.1:1") + gpui::point(px(90.0), px(0.0))
                }
                SelectionGesture::Code => {
                    let bounds =
                        render::selection_test_bounds(&key(&peer, "reply#text.0-code0-line1"));
                    gpui::point(bounds.right(), bounds.top() + px(9.0))
                }
                _ => start + gpui::point(px(100.0), px(0.0)),
            };
            if matches!(gesture, SelectionGesture::LongPress) {
                // Desktop long-press selection is a held primary press that
                // becomes a drag, not a separate touch platform event.
                cx.background_executor
                    .advance_clock(std::time::Duration::from_millis(650));
                draw(cx);
            }
            if !matches!(gesture, SelectionGesture::DoubleClick) {
                cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            }
            let selected = selection::selected_text()
                .unwrap_or_else(|| panic!("{gesture:?} must perform the original selection"));
            assert!(!selected.is_empty(), "{gesture:?}");
            match gesture {
                SelectionGesture::DoubleClick => assert_eq!(selected, "Selectable"),
                SelectionGesture::Multiline => assert!(selected.contains("\n"), "{selected:?}"),
                SelectionGesture::Code => assert_eq!(selected, "selectable\nsecond"),
                _ => assert!(selected.starts_with("Selectable"), "{selected:?}"),
            }
            cx.simulate_event(MouseUpEvent {
                button: MouseButton::Left,
                position: end,
                click_count: count,
                ..Default::default()
            });
            assert_peer_active(&shell, &peer, &current, cx);
            assert_eq!(
                selection::selected_text(),
                Some(selected),
                "{gesture:?}: activation must not discard the completed selection"
            );
            selection::end_active_drag();
            selection::clear_if_owner(&key(&peer, first));
        });
    }
}

#[gpui::test]
fn releasing_a_selection_over_an_inactive_pane_does_not_activate_it(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    with_panes(
        cx,
        vec![reply("Selectable response text.")],
        |shell, peer, current, cx| {
            let start = text_point(&current, "current-reply#text.0:0")
                + gpui::point(px(60.0), px(0.0));
            let end = text_point(&peer, "reply#text.0:0");
            cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
            cx.simulate_mouse_move(
                start + gpui::point(px(100.0), px(0.0)),
                Some(MouseButton::Left),
                Default::default(),
            );
            assert!(selection::selected_text().is_some());
            // Include a frame during the drag: activation tracking must survive
            // the re-render caused by updating the selection.
            draw(cx);
            cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            let selected = selection::selected_text().expect("B's selection must survive crossing into A");
            cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
            draw(cx);
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("current"));
                assert_eq!(shell.transcript.entity_id(), current.entity_id());
                assert_eq!(shell.peer_chat_views["peer"].transcript.entity_id(), peer.entity_id());
            });
            assert_eq!(selection::selected_text(), Some(selected));
            selection::end_active_drag();
            selection::clear_if_owner(&key(&current, "current-reply#text.0:0"));
        },
    );
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[gpui::test]
fn peer_link_menu_actions_open_the_requested_destination(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    let url = "https://example.com/split-link";
    for canvas in [false, true] {
        for label in ["Open in Harness", "Open in external browser"] {
            with_panes(
                cx,
                vec![reply(&format!("[Documentation]({url})"))],
                |shell, peer, _, cx| {
                    // This fixture renders the panes directly, not Shell's
                    // normal render path that synchronizes its active chat.
                    shell.update(cx, |shell, cx| {
                        shell.on_state_changed(&shell.state.clone(), cx);
                    });
                    if canvas {
                        shell.update(cx, |shell, cx| {
                            shell
                                .state
                                .update(cx, |state, cx| state.select_chat(None, cx));
                            shell.on_state_changed(&shell.state.clone(), cx);
                        });
                        draw(cx);
                    }
                    let source = text_point(&peer, "reply#text.0:0");
                    cx.simulate_mouse_move(source, None, Default::default());
                    cx.background_executor
                        .advance_clock(std::time::Duration::from_millis(650));
                    draw(cx);
                    cx.simulate_mouse_down(source, MouseButton::Right, Default::default());
                    cx.simulate_mouse_up(source, MouseButton::Right, Default::default());
                    draw(cx);
                    cx.background_executor
                        .advance_clock(std::time::Duration::from_millis(200));
                    draw(cx);
                    let row = cx.debug_bounds(label).expect("painted link menu action");
                    cx.simulate_click(row.center(), Default::default());
                    draw(cx);
                    if label == "Open in external browser" {
                        assert_eq!(cx.opened_url().as_deref(), Some(url));
                    } else {
                        shell.read_with(cx, |shell, cx| {
                            assert!(
                                shell.right_pane_open(cx),
                                "{label}, canvas={canvas}: active={}, selected={:?}, focus={}, browsers={}, chat_route={}",
                                shell.active_chat,
                                shell.state.read(cx).selected_chat,
                                shell.chat_split.as_ref().unwrap().focus,
                                shell.browsers.len(),
                                matches!(shell.route, Route::Chat)
                            );
                            assert_eq!(
                                shell.browsers[&shell.browser_seq]
                                    .read(cx)
                                    .page
                                    .url
                                    .as_deref(),
                                Some(url)
                            );
                        });
                    }
                },
            );
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn prepare_link_panes(
    shell: &Entity<Shell>,
    canvas: bool,
    internal: bool,
    cx: &mut gpui::VisualTestContext,
) {
    shell.update(cx, |shell, cx| {
        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
            settings.open_web_links_in_harness = internal;
        });
        if canvas {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
        }
        shell.on_state_changed(&shell.state.clone(), cx);
    });
    draw(cx);
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn open_peer_link_menu(peer: &Entity<Transcript>, row: &str, cx: &mut gpui::VisualTestContext) {
    let source = text_point(peer, row);
    cx.simulate_mouse_move(source, None, Default::default());
    cx.background_executor
        .advance_clock(std::time::Duration::from_millis(650));
    draw(cx);
    cx.simulate_mouse_down(source, MouseButton::Right, Default::default());
    cx.simulate_mouse_up(source, MouseButton::Right, Default::default());
    draw(cx);
    cx.background_executor
        .advance_clock(std::time::Duration::from_millis(200));
    draw(cx);
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[gpui::test]
fn promoted_peer_links_still_work_after_focus_moves_away_and_back(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for menu in [false, true] {
        with_panes(
            cx,
            vec![reply(
                "[Documentation](https://example.com/focus-round-trip)",
            )],
            |shell, peer, current, cx| {
                prepare_link_panes(&shell, false, true, cx);
                for count in 1..=3 {
                    if menu {
                        open_peer_link_menu(&peer, "reply#text.0:0", cx);
                        let row = cx.debug_bounds("Open in Harness").unwrap();
                        cx.simulate_click(row.center(), Default::default());
                    } else {
                        cx.simulate_click(text_point(&peer, "reply#text.0:0"), Default::default());
                    }
                    assert_peer_active(&shell, &peer, &current, cx);
                    shell.read_with(cx, |shell, cx| {
                        assert_eq!(shell.active_chat, "peer");
                        assert_eq!(shell.right_tabs["peer"].len(), count);
                        assert!(!shell.right_tabs.contains_key("current"));
                        assert!(shell.right_pane_open(cx));
                    });
                    // Demote the same entity through a real pointer release.
                    let point = text_point(&current, "current-reply#text.0:0");
                    cx.simulate_click(point, Default::default());
                    draw(cx);
                    shell.read_with(cx, |shell, cx| {
                        assert_eq!(shell.active_chat, "current");
                        assert_eq!(shell.transcript.entity_id(), current.entity_id());
                        assert_eq!(
                            shell.peer_chat_views["peer"].transcript.entity_id(),
                            peer.entity_id()
                        );
                        assert!(!shell.right_pane_open(cx));
                    });
                }
            },
        );
    }
}

/// How a promoted peer transcript ends up showing another chat as primary.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[derive(Clone, Copy, Debug)]
enum PromotedPrimaryPath {
    /// ⌘W on the promoted pane: the split closes and the same entity shows
    /// the remaining chat in a single pane.
    ClosePane,
    /// Close as above, then pick a third chat in the single pane.
    CloseThenNavigate,
    /// Keep the split and pick a third chat in the promoted (focused) pane.
    NavigateInSplit,
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[derive(Clone, Copy, Debug)]
enum LinkGesture {
    Click,
    OpenInHarness,
    OpenExternal,
}

/// Show `entries` as the selected chat's replayed transcript.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn show_primary_chat(
    shell: &Entity<Shell>,
    chat: &str,
    entries: Vec<SessionMessageEntry>,
    cx: &mut gpui::VisualTestContext,
) {
    shell.update(cx, |shell, cx| {
        shell.state.update(cx, |state, cx| {
            if state.selected_chat.as_deref() != Some(chat) {
                state.select_chat(Some(chat.into()), cx);
            }
            state.transcript = entries;
            state.transcript_replayed = true;
            state.transcript_revision += 1;
            cx.notify();
        });
        shell.on_state_changed(&shell.state.clone(), cx);
    });
    draw(cx);
}

/// #456: a peer transcript is created with its chat as a fixed link owner.
/// Promoting it keeps the entity (selection, folds, scroll) as the primary
/// transcript, which then follows the selection to other chats. Its links
/// must belong to the chat it now shows, not to the pane it came from.
#[cfg(any(target_os = "macos", target_os = "linux"))]
#[gpui::test]
fn promoted_peer_transcript_links_follow_the_chat_it_shows_after_navigation(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let mut failures = Vec::new();
    for path in [
        PromotedPrimaryPath::ClosePane,
        PromotedPrimaryPath::CloseThenNavigate,
        PromotedPrimaryPath::NavigateInSplit,
    ] {
        for gesture in [
            LinkGesture::Click,
            LinkGesture::OpenInHarness,
            LinkGesture::OpenExternal,
        ] {
            let url = format!("https://example.com/promoted/{path:?}/{gesture:?}");
            with_panes(
                cx,
                vec![reply("[Peer docs](https://example.com/peer-docs)")],
                |shell, peer, _current, cx| {
                    shell.update(cx, |shell, cx| {
                        shell.state.update(cx, |state, _| {
                            state.chats.push(
                                serde_json::from_value(serde_json::json!({
                                    "id": "other", "deviceId": "local", "title": "Session",
                                    "archived": false, "createdAt": Utc::now(),
                                }))
                                .unwrap(),
                            );
                        });
                    });
                    prepare_link_panes(&shell, false, true, cx);
                    // Promote the peer entity into the primary pane.
                    shell.update(cx, |shell, cx| {
                        assert!(shell.select_chat_pane(0, cx));
                        shell.on_state_changed(&shell.state.clone(), cx);
                    });
                    draw(cx);
                    shell.read_with(cx, |shell, _| {
                        assert_eq!(shell.active_chat, "peer");
                        assert_eq!(shell.transcript.entity_id(), peer.entity_id());
                    });
                    let mut link = reply(&format!("[Docs]({url})"));
                    link.id = "nav-link".into();
                    let shown = match path {
                        PromotedPrimaryPath::ClosePane => "current",
                        PromotedPrimaryPath::CloseThenNavigate
                        | PromotedPrimaryPath::NavigateInSplit => "other",
                    };
                    if !matches!(path, PromotedPrimaryPath::NavigateInSplit) {
                        cx.update(|window, cx| {
                            shell.update(cx, |shell, cx| {
                                assert!(
                                    shell.close_focused_chat_pane_without_archiving(window, cx)
                                );
                            })
                        });
                        draw(cx);
                        shell.read_with(cx, |shell, _| assert!(shell.chat_split.is_none()));
                    }
                    show_primary_chat(&shell, shown, vec![link], cx);
                    let owner = shell.read_with(cx, |shell, cx| {
                        assert_eq!(shell.active_chat, shown, "{path:?}");
                        assert_eq!(
                            shell.transcript.entity_id(),
                            peer.entity_id(),
                            "{path:?}: the promoted entity is still the primary transcript"
                        );
                        assert!(shell.browsers.is_empty());
                        shell
                            .transcript
                            .read(cx)
                            .link_ui()
                            .and_then(|link| link.source_session)
                    });
                    let previous_url = cx.opened_url();
                    if !render::selection_test_entries()
                        .iter()
                        .any(|(key, _, _)| key == "nav-link#text.0:0")
                    {
                        let keys: Vec<_> = render::selection_test_entries()
                            .into_iter()
                            .map(|(key, text, _)| (key, text))
                            .collect();
                        panic!(
                            "{path:?}/{gesture:?}: link row not painted; owner {owner:?}; \
                             registered {keys:?}"
                        );
                    }
                    match gesture {
                        LinkGesture::Click => {
                            cx.simulate_click(
                                text_point(&peer, "nav-link#text.0:0"),
                                Default::default(),
                            );
                        }
                        LinkGesture::OpenInHarness | LinkGesture::OpenExternal => {
                            open_peer_link_menu(&peer, "nav-link#text.0:0", cx);
                            let label = if matches!(gesture, LinkGesture::OpenInHarness) {
                                "Open in Harness"
                            } else {
                                "Open in external browser"
                            };
                            let row = cx
                                .debug_bounds(label)
                                .unwrap_or_else(|| panic!("{path:?}/{gesture:?}: painted {label}"));
                            cx.simulate_click(row.center(), Default::default());
                        }
                    }
                    draw(cx);
                    let routed = if matches!(gesture, LinkGesture::OpenExternal) {
                        cx.opened_url().as_deref() == Some(url.as_str())
                    } else {
                        let opened = shell.read_with(cx, |shell, cx| {
                            shell.browsers.len() == 1
                                && shell
                                    .right_tabs
                                    .get(shown)
                                    .is_some_and(|tabs| tabs.len() == 1)
                                && shell.right_pane_open(cx)
                                && shell.browsers[&shell.browser_seq]
                                    .read(cx)
                                    .page
                                    .url
                                    .as_deref()
                                    == Some(url.as_str())
                        });
                        opened && cx.opened_url() == previous_url
                    };
                    if !routed || owner.as_deref() != Some(shown) {
                        failures.push(format!(
                            "{path:?}/{gesture:?}: showing {shown:?}, link owner {owner:?}, \
                             routed={routed}"
                        ));
                    }
                },
            );
        }
    }
    assert!(
        failures.is_empty(),
        "links in a promoted peer transcript were rejected:\n{}",
        failures.join("\n")
    );
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[gpui::test]
fn peer_primary_links_follow_preferences_after_hover_and_repeated_clicks(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    for canvas in [false, true] {
        for internal in [false, true] {
            for hover in [false, true] {
                let url = format!("https://example.com/primary/{canvas}/{internal}/{hover}");
                with_panes(
                    cx,
                    vec![reply(&format!("[Documentation]({url})"))],
                    |shell, peer, _, cx| {
                        prepare_link_panes(&shell, canvas, internal, cx);
                        let previous_url = cx.opened_url();
                        for clicks in 1..=2 {
                            let source = text_point(&peer, "reply#text.0:0");
                            if hover {
                                cx.simulate_mouse_move(source, None, Default::default());
                                cx.background_executor
                                    .advance_clock(std::time::Duration::from_millis(650));
                                draw(cx);
                            }
                            cx.simulate_click(source, Default::default());
                            draw(cx);
                            shell.read_with(cx, |shell, cx| {
                                if internal {
                                    assert_eq!(
                                        shell.browsers.len(),
                                        clicks,
                                        "canvas={canvas}, hover={hover}"
                                    );
                                    assert!(shell.right_pane_open(cx));
                                    assert_eq!(
                                        shell.browsers[&shell.browser_seq]
                                            .read(cx)
                                            .page
                                            .url
                                            .as_deref(),
                                        Some(url.as_str())
                                    );
                                } else {
                                    assert!(shell.browsers.is_empty());
                                }
                            });
                            if internal {
                                assert_eq!(cx.opened_url(), previous_url);
                            } else {
                                assert_eq!(cx.opened_url().as_deref(), Some(url.as_str()));
                            }
                        }
                    },
                );
            }
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[gpui::test]
fn peer_link_menu_actions_ignore_existing_text_highlights(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    let url = "https://example.com/highlighted-link";
    for highlight_peer in [false, true] {
        for label in ["Open in Harness", "Open in external browser"] {
            with_panes(
                cx,
                vec![reply(&format!(
                    "Selectable response text.\n\n[Documentation]({url})"
                ))],
                |shell, peer, current, cx| {
                    prepare_link_panes(&shell, false, true, cx);
                    let (selected, row) = if highlight_peer {
                        (&peer, "reply#text.0:0")
                    } else {
                        (&current, "current-reply#text.0:0")
                    };
                    let start = text_point(selected, row);
                    let end = start + gpui::point(px(90.0), px(0.0));
                    cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
                    cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
                    cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
                    draw(cx);
                    assert!(selection::selected_text().is_some());
                    open_peer_link_menu(&peer, "reply#text.1:1", cx);
                    let row_bounds = cx.debug_bounds(label).expect("painted link menu action");
                    cx.simulate_click(row_bounds.center(), Default::default());
                    draw(cx);
                    if label == "Open in Harness" {
                        shell.read_with(cx, |shell, cx| {
                            assert_eq!(shell.browsers.len(), 1);
                            assert_eq!(
                                shell.browsers[&shell.browser_seq]
                                    .read(cx)
                                    .page
                                    .url
                                    .as_deref(),
                                Some(url)
                            );
                        });
                    } else {
                        assert_eq!(cx.opened_url().as_deref(), Some(url));
                    }
                    selection::end_active_drag();
                    selection::clear_if_owner(&key(selected, row));
                },
            );
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[gpui::test]
fn peer_link_menu_escape_copy_and_reopen_do_not_navigate(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    let url = "https://example.com/copy?first=1&second=two#section";
    for canvas in [false, true] {
        with_panes(
            cx,
            vec![reply(&format!("[Documentation]({url})"))],
            |shell, peer, _, cx| {
                prepare_link_panes(&shell, canvas, true, cx);
                let previous_url = cx.opened_url();
                open_peer_link_menu(&peer, "reply#text.0:0", cx);
                cx.simulate_keystrokes("escape");
                draw(cx);
                assert!(cx.debug_bounds("Open in Harness").is_none());
                for _ in 0..2 {
                    open_peer_link_menu(&peer, "reply#text.0:0", cx);
                    let row = cx.debug_bounds("Copy link address").expect("copy action");
                    cx.simulate_click(row.center(), Default::default());
                    draw(cx);
                    cx.update(|_, cx| {
                        assert_eq!(
                            cx.read_from_clipboard().unwrap().text().as_deref(),
                            Some(url)
                        )
                    });
                    assert_eq!(cx.opened_url(), previous_url);
                    shell.read_with(cx, |shell, cx| {
                        assert!(shell.browsers.is_empty());
                        assert_eq!(
                            shell.state.read(cx).selected_chat.as_deref(),
                            if canvas { None } else { Some("current") }
                        );
                    });
                }
            },
        );
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
#[gpui::test]
fn peer_link_menu_unsafe_destinations_only_allow_copy(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for target in [
        "javascript:alert(1)",
        "data:text/html,hello",
        "file:///etc/passwd",
    ] {
        with_panes(
            cx,
            vec![reply(&format!("[Unsafe destination]({target})"))],
            |shell, peer, _, cx| {
                prepare_link_panes(&shell, true, true, cx);
                let previous_url = cx.opened_url();
                for label in [
                    "Open in Harness",
                    "Open in external browser",
                    "Copy link address",
                ] {
                    open_peer_link_menu(&peer, "reply#text.0:0", cx);
                    let row = cx
                        .debug_bounds(label)
                        .expect("painted disabled or copy action");
                    cx.simulate_click(row.center(), Default::default());
                    draw(cx);
                    assert_eq!(cx.opened_url(), previous_url);
                    shell.read_with(cx, |shell, cx| {
                        assert!(shell.browsers.is_empty());
                        assert!(shell.state.read(cx).selected_chat.is_none());
                    });
                    if label == "Copy link address" {
                        cx.update(|_, cx| {
                            assert_eq!(
                                cx.read_from_clipboard().unwrap().text().as_deref(),
                                Some(target)
                            )
                        });
                    }
                }
            },
        );
    }
}

#[gpui::test]
fn every_mouse_button_activates_an_inactive_pane_on_release(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for button in [MouseButton::Left, MouseButton::Right, MouseButton::Middle] {
        with_panes(
            cx,
            vec![reply("Selectable response text.")],
            |shell, peer, current, cx| {
                // Use actual selectable text rather than an inert test-only button.
                let point = text_point(&peer, "reply#text.0:0");
                cx.simulate_mouse_down(point, button, Default::default());
                cx.simulate_mouse_up(point, button, Default::default());
                assert_peer_active(&shell, &peer, &current, cx);
                selection::end_active_drag();
                selection::clear_if_owner(&key(&peer, "reply#text.0:0"));
            },
        );
    }
}

#[gpui::test]
fn an_old_highlight_does_not_block_a_click_in_another_pane(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(
        cx,
        vec![reply("Selectable response text.")],
        |shell, peer, current, cx| {
            let start = text_point(&current, "current-reply#text.0:0");
            let end = start + gpui::point(px(90.0), px(0.0));
            cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
            cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
            assert!(selection::selected_text().is_some());
            let pane = cx.debug_bounds("peer-column").unwrap();
            cx.simulate_click(
                pane.origin + gpui::point(px(100.0), px(Theme::TITLEBAR_HEIGHT + 6.0)),
                Default::default(),
            );
            assert_peer_active(&shell, &peer, &current, cx);
            selection::clear_if_owner(&key(&current, "current-reply#text.0:0"));
        },
    );
}

#[gpui::test]
fn first_disclosure_click_both_activates_and_toggles_the_real_tool_group(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let mut entry = reply("");
    entry.parts = vec![MessagePart::Tool {
        id: "call".into(),
        call: ToolCall::Exec {
            command: "pwd".into(),
        },
        is_error: false,
        resolved: true,
        output: None,
        diff: None,
        view: None,
        output_ref: None,
        output_bytes: None,
        diff_ref: None,
        diff_stats: None,
        subagent_ref: None,
        subagent_status: None,
        subagent_tail: None,
    }];
    with_panes(cx, vec![entry], |shell, peer, current, cx| {
        for opening in [true, false] {
            if !opening {
                shell.update(cx, |shell, cx| {
                    assert!(shell.select_chat_pane(1, cx));
                });
                draw(cx);
            }
            let row_id = peer.read_with(cx, |transcript, _| transcript.rows()[0].id.clone());
            let header = cx
                .debug_bounds("transcript-tool-group-header")
                .expect("painted tool header");
            cx.simulate_click(header.center(), Default::default());
            assert_peer_active(&shell, &peer, &current, cx);
            peer.read_with(cx, |transcript, _| {
                assert_eq!(
                    transcript.test_fold_open(&row_id),
                    Some(opening),
                    "the first click must toggle, not merely focus",
                );
            });
        }
    });
}

#[gpui::test]
fn composer_send_targets_the_promoted_transcript(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(
        cx,
        vec![reply("Selectable response text.")],
        |shell, peer, current, cx| {
            shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(0, cx)));
            assert_peer_active(&shell, &peer, &current, cx);
            assert!(current.read_with(cx, |transcript, _| transcript.is_pinned()));
            let composer = shell.read_with(cx, |shell, _| shell.composer.clone());
            composer.update(cx, |_, cx| {
                cx.emit(ComposerEvent::Sent {
                    chat_id: "peer".into(),
                    message_id: "new-prompt".into(),
                });
            });
            cx.run_until_parked();
            assert!(
                !peer.read_with(cx, |transcript, _| transcript.is_pinned()),
                "own-send must anchor in the promoted transcript"
            );
            assert!(
                current.read_with(cx, |transcript, _| transcript.is_pinned()),
                "own-send must not target the old primary entity"
            );
        },
    );
}

#[gpui::test]
fn first_jump_click_both_activates_and_scrolls_the_same_transcript(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    let text = (0..40)
        .map(|ix| format!("Paragraph {ix} contains enough response text for scrolling.\n\n"))
        .collect::<String>();
    with_panes(cx, vec![reply(&text)], |shell, peer, current, cx| {
        let pane = cx.debug_bounds("peer-column").unwrap();
        cx.simulate_event(ScrollWheelEvent {
            position: pane.center(),
            delta: ScrollDelta::Pixels(gpui::point(px(0.0), px(10000.0))),
            ..Default::default()
        });
        draw(cx);
        peer.read_with(cx, |transcript, _| {
            assert!(
                transcript.jump_button_shown(),
                "scrolling away must expose the real jump control"
            );
            assert!(!transcript.is_pinned());
        });
        let before = peer.read_with(cx, |transcript, _| {
            transcript.list_state().logical_scroll_top()
        });
        // render_peer_chat_pane places its 30px pill 16px above the bottom.
        cx.simulate_click(
            gpui::point(pane.center().x, pane.bottom() - px(31.0)),
            Default::default(),
        );
        assert_peer_active(&shell, &peer, &current, cx);
        peer.read_with(cx, |transcript, _| {
            assert!(
                transcript.is_pinned(),
                "the original jump action must run on the activation click"
            );
            assert!(!transcript.jump_button_shown());
            let after = transcript.list_state().logical_scroll_top();
            assert!(
                after.item_ix > before.item_ix
                    || (after.item_ix == before.item_ix
                        && after.offset_in_item > before.offset_in_item),
                "the click must actually advance the viewport: {before:?} -> {after:?}"
            );
        });
    });
}
