//! Synthetic split-pane link ownership regressions; no engine or network needed.
#![cfg(any(target_os = "macos", target_os = "linux"))]

use super::*;
use crate::markdown::render::{LinkAction, LinkActivation, LinkOutcome, LinkTarget};
use crate::pickers::{CanvasDraft, CanvasInput, CanvasTarget};
use gpui::{AppContext, TestAppContext};

const URL: &str = "https://example.com/split-links";

fn activation(source: Option<&str>, action: LinkAction) -> LinkActivation {
    LinkActivation {
        target: LinkTarget::new("Synthetic documentation", URL),
        source_session: source.map(str::to_owned),
        action,
    }
}

/// Three visible panes, with either an existing chat or a canvas focused in
/// the last slot. Seeding rows lets the ordinary pane-switch path run without
/// an engine, rather than mocking the ownership transition under test.
fn with_link_panes(
    cx: &mut TestAppContext,
    owner: Option<&str>,
    run: impl FnOnce(&mut Shell, &mut Window, &mut Context<Shell>),
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
        settings::init(settings::UiSettings::expanded(), dir.path(), cx);
    });
    let window = cx.add_window(|_, cx| {
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, cx| {
            state.chats = ["owner", "peer-a", "peer-b", "parked"]
                .into_iter()
                .map(|id| {
                    serde_json::from_value(serde_json::json!({
                        "id": id, "deviceId": "local", "title": "Synthetic session",
                        "cwd": "/workspace/link-tests", "archived": false,
                        "createdAt": Utc::now(),
                    }))
                    .unwrap()
                })
                .collect();
            state.select_chat(owner.map(str::to_owned), cx);
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
        shell.route = Route::Chat;
        shell.active_chat = owner.unwrap_or_default().into();
        shell.chat_split_selected = owner.map(str::to_owned);
        let split =
            chat_split::ChatSplit::split(None, SplitAxis::Horizontal, Some("peer-a".into()), None);
        shell.chat_split =
            chat_split::ChatSplit::split(split, SplitAxis::Horizontal, Some("peer-b".into()), None);
        shell.sync_chat_panes(cx);
        shell
    });
    window.update(cx, run).unwrap();
    cx.run_until_parked();
}

/// Check more than tab counts: rejection/external routing must not select a
/// peer, park a draft, reveal a panel, change its active tab, or open a file.
#[derive(Debug, PartialEq)]
struct LinkState {
    active: String,
    selected: Option<String>,
    route: Route,
    split: Option<chat_split::ChatSplit>,
    draft: CanvasDraft,
    browser_seq: u64,
    browsers: Vec<u64>,
    file_surfaces: Vec<u64>,
    file_explorers: usize,
    tabs: std::collections::HashMap<String, Vec<RightSurface>>,
    panels: std::collections::HashMap<String, ChatPanels>,
    peers: Vec<String>,
    notice: Option<SharedString>,
}

fn link_state(shell: &Shell, cx: &App) -> LinkState {
    let mut browsers: Vec<_> = shell.browsers.keys().copied().collect();
    browsers.sort_unstable();
    let mut file_surfaces: Vec<_> = shell.file_surfaces.keys().copied().collect();
    file_surfaces.sort_unstable();
    let mut peers: Vec<_> = shell.peer_chat_views.keys().cloned().collect();
    peers.sort();
    LinkState {
        active: shell.active_chat.clone(),
        selected: shell.state.read(cx).selected_chat.clone(),
        route: shell.route,
        split: shell.chat_split.clone(),
        draft: shell.current_canvas_draft(cx),
        browser_seq: shell.browser_seq,
        browsers,
        file_surfaces,
        file_explorers: shell.files.len(),
        tabs: shell.right_tabs.clone(),
        panels: shell.panels.map.clone(),
        peers,
        notice: shell.sidebar_notice.clone(),
    }
}

fn assert_rejected_unchanged(
    shell: &mut Shell,
    activation: &LinkActivation,
    window: &mut Window,
    cx: &mut Context<Shell>,
) {
    let before = link_state(shell, cx);
    assert_eq!(
        shell.activate_session_link(activation, window, cx),
        LinkOutcome::Rejected,
        "{activation:?}"
    );
    assert_eq!(link_state(shell, cx), before, "{activation:?}");
}

#[gpui::test]
fn saved_view_callbacks_reject_hidden_revoked_or_unknown_local_owners(cx: &mut TestAppContext) {
    for source in ["owner", "owner--sub--synthetic-call"] {
        for kind in [
            harness_proto::ToolViewKind::Html,
            harness_proto::ToolViewKind::McpApp,
        ] {
            for invalid in ["settings", "archived", "deleted", "partial-missing"] {
                let mut setup = None;
                with_link_panes(cx, Some("owner"), |shell, window, cx| {
                    shell
                        .state
                        .update(cx, |state, _| state.local_device_id = Some("local".into()));
                    setup = Some((cx.entity(), window.window_handle(), Shell::view_opener(cx)));
                });
                let (shell, window, opener) = setup.unwrap();
                shell.update(cx, |shell, cx| {
                    if invalid == "settings" {
                        shell.route = Route::Settings(SettingsSection::Appearance);
                    }
                    shell.state.update(cx, |state, _| {
                        state.chats_synced = invalid != "partial-missing";
                        if invalid == "archived" {
                            state
                                .chats
                                .iter_mut()
                                .find(|chat| chat.id == "owner")
                                .unwrap()
                                .archived = true;
                        } else if matches!(invalid, "deleted" | "partial-missing") {
                            state.chats.retain(|chat| chat.id != "owner");
                        }
                        // Keep the old chip callback alive before reconciliation.
                    });
                });
                let before = shell.read_with(cx, link_state);
                let view =
                    harness_proto::ToolView::new(kind, "00000000000000000000000000000001").unwrap();
                window
                    .update(cx, |_, window, cx| opener(source, &view, window, cx))
                    .unwrap();
                cx.run_until_parked();
                shell.read_with(cx, |shell, cx| {
                    assert_eq!(
                        link_state(shell, cx),
                        before,
                        "{source}, {kind:?}, {invalid}"
                    );
                });
            }
        }
    }
}

#[gpui::test]
fn saved_view_callbacks_keep_selected_owner_and_device_boundaries(cx: &mut TestAppContext) {
    for kind in [
        harness_proto::ToolViewKind::Html,
        harness_proto::ToolViewKind::McpApp,
    ] {
        for (source, device, synced, allowed) in [
            ("owner", "local", false, true),
            ("owner--sub--synthetic-call", "local", true, true),
            ("peer-a", "local", true, false),
            ("peer-a--sub--synthetic-call", "local", false, false),
            ("owner-extra", "local", true, false),
            ("", "local", true, false),
            ("owner", "remote", true, false),
            ("owner", "unknown-local", true, false),
        ] {
            let mut setup = None;
            with_link_panes(cx, Some("owner"), |shell, window, cx| {
                shell.state.update(cx, |state, _| {
                    state.local_device_id = (device != "unknown-local").then(|| "local".into());
                    state.chats_synced = synced;
                    if device == "remote" {
                        state
                            .chats
                            .iter_mut()
                            .find(|chat| chat.id == "owner")
                            .unwrap()
                            .device_id = "remote".into();
                    }
                });
                setup = Some((cx.entity(), window.window_handle(), Shell::view_opener(cx)));
            });
            let (shell, window, opener) = setup.unwrap();
            let mut expected = shell.read_with(cx, link_state);
            let view =
                harness_proto::ToolView::new(kind, "00000000000000000000000000000001").unwrap();
            window
                .update(cx, |_, window, cx| opener(source, &view, window, cx))
                .unwrap();
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                if allowed && cfg!(target_os = "macos") {
                    assert_eq!(shell.browsers.len(), 1);
                    assert_eq!(shell.right_tabs["owner"], vec![RightSurface::Browser(1)]);
                    assert_eq!(shell.resolved_right_active(cx), RightSurface::Browser(1));
                } else {
                    if matches!(device, "remote" | "unknown-local") {
                        expected.notice =
                            Some("This view is saved on another computer. Open it there.".into());
                    } else if allowed {
                        expected.notice =
                            Some("Saved views open in the browser pane on macOS for now.".into());
                    }
                    assert_eq!(
                        link_state(shell, cx),
                        expected,
                        "{source}, {device}, {kind:?}"
                    );
                }
            });
        }
    }
}

#[gpui::test]
fn callback_authority_recovers_across_repeated_route_snapshot_and_selection_transitions(
    cx: &mut TestAppContext,
) {
    use crate::browser::BrowserEvent;

    for callback in ["transcript", "browser", "saved-view"] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            shell
                .state
                .update(cx, |state, _| state.local_device_id = Some("local".into()));
            shell.activate_session_link(
                &activation(Some("owner"), LinkAction::Internal),
                window,
                cx,
            );
            setup = Some((
                cx.entity(),
                window.window_handle(),
                Shell::view_opener(cx),
                shell.browsers[&1].clone(),
            ));
        });
        let (shell, window, opener, browser) = setup.unwrap();
        let original_row = shell.read_with(cx, |shell, cx| {
            shell.state.read(cx).selected_chat_row().unwrap().clone()
        });
        // These transitions deliberately precede observers/painting. Reuse the
        // exact same callbacks through revocation and recovery, not fresh ones.
        for (chat_route, row_state, synced, selected) in [
            (true, "live", true, Some("owner")),
            (false, "live", true, Some("owner")),
            (false, "archived", true, Some("owner")),
            (true, "archived", true, Some("owner")),
            (true, "archived", false, Some("owner")),
            (true, "missing", false, Some("owner")),
            (true, "missing", true, Some("owner")),
            (true, "live", true, Some("peer-a")),
            (true, "live", true, None),
            (true, "live", true, Some("owner")),
            (false, "live", false, Some("owner")),
            (true, "live", false, Some("owner")),
        ] {
            shell.update(cx, |shell, cx| {
                shell.route = if chat_route {
                    Route::Chat
                } else {
                    Route::Settings(SettingsSection::Appearance)
                };
                shell.state.update(cx, |state, _| {
                    state.chats_synced = synced;
                    state.selected_chat = selected.map(str::to_owned);
                    state.chats.retain(|chat| chat.id != "owner");
                    if row_state != "missing" {
                        let mut row = original_row.clone();
                        row.archived = row_state == "archived";
                        state.chats.push(row);
                    }
                });
                shell.set_right_active(RightSurface::Browser(1), cx);
            });
            let before = shell.read_with(cx, link_state);
            let known_live = row_state == "live";
            let allowed = chat_route
                && selected == Some("owner")
                && (known_live || (row_state == "missing" && !synced && callback != "saved-view"));
            window
                .update(cx, |_, window, cx| match callback {
                    "transcript" => shell.update(cx, |shell, cx| {
                        assert_eq!(
                            shell.activate_session_link(
                                &activation(Some("owner"), LinkAction::External),
                                window,
                                cx
                            ),
                            if allowed {
                                LinkOutcome::External(URL.into())
                            } else {
                                LinkOutcome::Rejected
                            }
                        );
                    }),
                    "browser" => browser.update(cx, |_, cx| cx.emit(BrowserEvent::NewTab(None))),
                    "saved-view" => {
                        let view = harness_proto::ToolView::new(
                            harness_proto::ToolViewKind::Html,
                            "00000000000000000000000000000001",
                        )
                        .unwrap();
                        opener("owner--sub--synthetic-call", &view, window, cx);
                    }
                    _ => unreachable!(),
                })
                .unwrap();
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                if allowed && callback != "transcript" && (callback != "saved-view" || cfg!(target_os = "macos")) {
                    assert_eq!(shell.browser_seq, before.browser_seq + 1, "{callback}, {row_state}");
                    assert_eq!(shell.browsers.len(), before.browsers.len() + 1);
                    assert_eq!(shell.resolved_right_active(cx), RightSurface::Browser(shell.browser_seq));
                } else {
                    let mut expected = before;
                    if allowed && callback == "saved-view" {
                        expected.notice = Some("Saved views open in the browser pane on macOS for now.".into());
                    }
                    assert_eq!(link_state(shell, cx), expected, "{callback}, route={chat_route}, row={row_state}, synced={synced}, selected={selected:?}");
                }
            });
        }
    }
}

#[gpui::test]
fn split_links_require_a_nonempty_source_and_a_live_unfocused_peer(cx: &mut TestAppContext) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        for source in [None, Some(""), Some("deleted-session"), Some("parked")] {
            assert_rejected_unchanged(shell, &activation(source, LinkAction::Internal), window, cx);
        }

        let link = activation(Some("peer-a"), LinkAction::Internal);
        // A layout entry alone is not an authorization: its view may already
        // have been released while an old callback is still in flight.
        let view = shell.peer_chat_views.remove("peer-a").unwrap();
        assert_rejected_unchanged(shell, &link, window, cx);
        shell.peer_chat_views.insert("peer-a".into(), view);

        // Conversely, a cached view or a parked tab is not a visible pane.
        shell.chat_tabs = vec![
            chat_tabs::ChatTab::default(),
            chat_tabs::ChatTab {
                selected: Some("peer-a".into()),
                ..Default::default()
            },
        ];
        let split = shell.chat_split.as_mut().unwrap();
        split.panes[0] = None;
        split.vanished[0] = Some("peer-a".into());
        assert!(shell.peer_chat_views.contains_key("peer-a"));
        assert_rejected_unchanged(shell, &link, window, cx);

        // The focused slot is a placeholder, never a second source of truth
        // for the selected chat, even if it temporarily retains a stale id.
        let split = shell.chat_split.as_mut().unwrap();
        split.panes[split.focus] = Some("peer-a".into());
        assert_rejected_unchanged(shell, &link, window, cx);
    });
}

#[gpui::test]
fn split_links_reject_selection_handoffs_including_canvas_mismatches(cx: &mut TestAppContext) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        let link = activation(Some("peer-a"), LinkAction::Internal);
        for (active, selected) in [
            ("owner", None),
            ("owner", Some("peer-b")),
            ("", Some("owner")),
            ("", Some("peer-a")),
        ] {
            shell.active_chat = active.into();
            shell.state.update(cx, |state, _| {
                state.selected_chat = selected.map(str::to_owned);
            });
            assert_rejected_unchanged(shell, &link, window, cx);
        }
    });
}

#[gpui::test]
fn unsafe_split_links_never_fall_back_to_files_or_promote_a_canvas(cx: &mut TestAppContext) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        // Cover both the focused workspace-file fallback and the canvas peer
        // promotion boundary, without multiplying every URL by every action.
        let cases = [
            ("javascript:alert(1)", LinkAction::Internal),
            ("data:text/html,synthetic", LinkAction::Primary),
            ("mailto:synthetic@example.com", LinkAction::External),
            ("https://user:pass@example.com/", LinkAction::Internal),
            ("https://", LinkAction::Primary),
            ("https://example.com/%GG", LinkAction::External),
        ];
        for canvas in [false, true] {
            shell.active_chat = if canvas { "" } else { "owner" }.into();
            shell.state.update(cx, |state, _| {
                state.selected_chat = (!canvas).then(|| "owner".into());
            });
            for (url, action) in cases {
                let mut link = activation(Some(if canvas { "peer-b" } else { "owner" }), action);
                link.target = LinkTarget::new("Untrusted destination", url);
                assert!(link.target.navigation.is_err(), "{url}");
                assert_rejected_unchanged(shell, &link, window, cx);
            }
        }
    });
}

#[gpui::test]
fn multi_peer_links_follow_preferences_and_internal_tabs_belong_to_the_source(
    cx: &mut TestAppContext,
) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        let peer_a = shell.peer_chat_views["peer-a"].transcript.entity_id();
        let peer_b = shell.peer_chat_views["peer-b"].transcript.entity_id();
        for (source, prefer_internal, action, internal) in [
            ("peer-a", false, LinkAction::Primary, false),
            ("peer-b", false, LinkAction::Internal, true),
            ("peer-a", true, LinkAction::Primary, true),
            ("peer-b", true, LinkAction::External, false),
        ] {
            settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                settings.open_web_links_in_harness = prefer_internal;
            });
            let before = link_state(shell, cx);
            let outcome =
                shell.activate_session_link(&activation(Some(source), action), window, cx);
            if internal {
                assert_eq!(outcome, LinkOutcome::Internal);
                assert_eq!(shell.browsers.len(), before.browsers.len() + 1);
                let id = shell.browser_seq;
                assert_eq!(
                    shell.right_tabs[source].last(),
                    Some(&RightSurface::Browser(id))
                );
                assert_eq!(shell.browsers[&id].read(cx).page.url.as_deref(), Some(URL));
                assert_eq!(shell.active_chat, source);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some(source));
                assert!(shell.right_pane_open(cx));
                assert_eq!(
                    shell.transcript.entity_id(),
                    if source == "peer-a" { peer_a } else { peer_b }
                );
            } else {
                assert_eq!(outcome, LinkOutcome::External(URL.into()));
                assert_eq!(link_state(shell, cx), before);
            }
            assert!(!shell.right_tabs.contains_key("owner"));
        }
        assert_eq!(shell.right_tabs["peer-a"].len(), 1);
        assert_eq!(shell.right_tabs["peer-b"].len(), 1);

        // Reuse a source callback after another pane takes focus. Navigation
        // must reveal the source's own tab, not strand it in the old host.
        let link = activation(Some("peer-a"), LinkAction::Internal);
        assert!(shell.select_chat_pane(1, cx));
        shell.on_state_changed(&shell.state.clone(), cx);
        assert_eq!(shell.active_chat, "peer-b");
        assert_eq!(shell.transcript.entity_id(), peer_b);
        for count in 2..=3 {
            assert_eq!(
                shell.activate_session_link(&link, window, cx),
                LinkOutcome::Internal
            );
            assert_eq!(shell.right_tabs["peer-a"].len(), count);
            assert_eq!(shell.right_tabs["peer-b"].len(), 1);
            assert_eq!(shell.active_chat, "peer-a");
            assert!(shell.right_pane_open(cx));
            assert_eq!(shell.transcript.entity_id(), peer_a);
        }
    });
}

#[gpui::test]
fn canvas_link_promotion_parks_the_draft_and_repeated_links_keep_the_new_owner(
    cx: &mut TestAppContext,
) {
    with_link_panes(cx, None, |shell, window, cx| {
        shell.adopt_canvas_draft(
            Some(CanvasDraft {
                harness: Some(harness_proto::HarnessId::Mock),
                model: Some("synthetic-model".into()),
                reasoning: Some(harness_proto::ReasoningLevel::High),
                target: Some(CanvasTarget {
                    space: None,
                    no_project: true,
                    device: Some("local".into()),
                }),
                input: Some(CanvasInput {
                    text: "Unsent synthetic canvas draft".into(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            cx,
        );
        let draft = shell.current_canvas_draft(cx);
        assert_eq!(draft.model.as_deref(), Some("synthetic-model"));
        assert_eq!(
            draft.input.as_ref().unwrap().text,
            "Unsent synthetic canvas draft"
        );
        let peer_a = shell.peer_chat_views["peer-a"].transcript.entity_id();
        let peer_b = shell.peer_chat_views["peer-b"].transcript.entity_id();
        let link = activation(Some("peer-b"), LinkAction::Primary);

        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
            settings.open_web_links_in_harness = false;
        });
        let before = link_state(shell, cx);
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::External(URL.into())
        );
        assert_eq!(
            link_state(shell, cx),
            before,
            "external links must leave the canvas live"
        );

        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
            settings.open_web_links_in_harness = true;
        });
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        assert_eq!(shell.active_chat, "peer-b");
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("peer-b")
        );
        assert_eq!(shell.transcript.entity_id(), peer_b);
        assert_eq!(
            shell.peer_chat_views["peer-a"].transcript.entity_id(),
            peer_a
        );
        let split = shell.chat_split.as_ref().unwrap();
        assert_eq!(
            split.focus, 1,
            "promote the source, not the first available peer"
        );
        assert_eq!(split.panes, vec![Some("peer-a".into()), None, None]);
        assert_eq!(split.drafts[2].as_ref(), Some(&draft));
        assert!(!shell.right_tabs.contains_key(""));
        assert!(!shell.right_tabs.contains_key("peer-a"));
        assert_eq!(shell.right_tabs["peer-b"].len(), 1);
        let first = shell.browser_seq;

        let layout = shell.chat_split.clone();
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        assert_ne!(shell.browser_seq, first);
        assert_eq!(shell.right_tabs["peer-b"].len(), 2);
        assert_eq!(
            shell.chat_split, layout,
            "repeat activation must not park the draft again"
        );

        assert!(shell.select_chat_pane(2, cx));
        shell.on_state_changed(&shell.state.clone(), cx);
        assert!(shell.active_chat.is_empty());
        assert!(shell.state.read(cx).selected_chat.is_none());
        assert_eq!(shell.current_canvas_draft(cx), draft);
        assert_eq!(shell.right_tabs["peer-b"].len(), 2);
        assert!(!shell.right_pane_open(cx));
    });
}

#[gpui::test]
fn queued_browser_navigation_and_close_batches_obey_delivery_order(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for order in [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
    ] {
        for url in [None, Some(URL.to_owned())] {
            let mut setup = None;
            with_link_panes(cx, Some("owner"), |shell, window, cx| {
                shell.activate_session_link(
                    &activation(Some("peer-a"), LinkAction::Internal),
                    window,
                    cx,
                );
                let id = shell.browser_seq;
                setup = Some((cx.entity(), id, shell.browsers[&id].clone()));
            });
            let (shell, id, browser) = setup.unwrap();
            let events = [
                BrowserEvent::NewTab(url),
                BrowserEvent::OpenSource("/workspace/link-tests/batched.rs".into()),
                BrowserEvent::Close,
            ];
            // Queue all three before allowing subscriptions to run. The first
            // navigation changes the selected surface, revoking the old page's
            // authority for the next event; Close must still clean it up.
            browser.update(cx, |_, cx| {
                for index in order {
                    cx.emit(events[index].clone());
                }
            });
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                assert!(!shell.browsers.contains_key(&id), "{order:?}");
                assert!(!shell.browser_subs.contains_key(&id));
                assert!(!shell.right_tabs["peer-a"].contains(&RightSurface::Browser(id)));
                assert_eq!(shell.active_chat, "peer-a");
                assert_eq!(shell.browsers.len(), usize::from(order[0] == 0));
                assert_eq!(shell.file_surfaces.len(), usize::from(order[0] == 1));
                assert_eq!(shell.right_tabs["peer-a"].len(), usize::from(order[0] != 2));
                assert_eq!(shell.right_pane_open(cx), order[0] != 2);
                assert_eq!(shell.browser_seq, id + u64::from(order[0] == 0));
            });
        }
    }
}

#[gpui::test]
fn reordered_browser_fallback_transfers_navigation_authority_to_the_visible_tab(
    cx: &mut TestAppContext,
) {
    use crate::browser::BrowserEvent;

    for fallback_first in [false, true] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            let mut browsers = Vec::new();
            for _ in 0..3 {
                shell.activate_session_link(
                    &activation(Some("peer-a"), LinkAction::Internal),
                    window,
                    cx,
                );
                browsers.push((
                    shell.browser_seq,
                    shell.browsers[&shell.browser_seq].clone(),
                ));
            }
            // Move the second browser to the first slot, without changing the
            // third browser's active selection.
            shell.reorder_right_tabs(1, 0, cx);
            setup = Some((cx.entity(), browsers));
        });
        let (shell, browsers) = setup.unwrap();
        browsers[2]
            .1
            .update(cx, |_, cx| cx.emit(BrowserEvent::Close));
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(
                shell.resolved_right_active(cx),
                RightSurface::Browser(browsers[1].0)
            );
        });
        // The stored selection is now Picker, so authorization must use the
        // actual fallback tab, not the stale pick or the pre-drag slot index.
        for index in if fallback_first { [1, 0] } else { [0, 1] } {
            browsers[index]
                .1
                .update(cx, |_, cx| cx.emit(BrowserEvent::NewTab(None)));
        }
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.browser_seq, 4);
            assert_eq!(shell.browsers.len(), 3);
            assert_eq!(shell.resolved_right_active(cx), RightSurface::Browser(4));
            assert_eq!(
                shell.right_tabs["peer-a"],
                vec![
                    RightSurface::Browser(browsers[1].0),
                    RightSurface::Browser(browsers[0].0),
                    RightSurface::Browser(4),
                ]
            );
        });
    }
}

#[gpui::test]
fn deleting_a_chat_releases_its_browser_tabs_and_queued_callbacks(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for foreground in [false, true] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            let mut deleted = Vec::new();
            for owner in ["peer-a", "peer-a", "peer-b"] {
                shell.activate_session_link(
                    &activation(Some(owner), LinkAction::Internal),
                    window,
                    cx,
                );
                if owner == "peer-a" {
                    deleted.push((
                        shell.browser_seq,
                        shell.browsers[&shell.browser_seq].clone(),
                    ));
                }
            }
            let surviving = shell.browser_seq;
            if foreground {
                assert!(shell.select_chat_pane(0, cx));
                shell.on_state_changed(&shell.state.clone(), cx);
            }
            shell.delete_chat("peer-a".into(), window, cx);
            setup = Some((cx.entity(), deleted, surviving));
        });
        let (shell, deleted, surviving) = setup.unwrap();
        shell.read_with(cx, |shell, _| {
            assert_eq!(shell.browsers.len(), 1);
            assert_eq!(shell.browser_subs.len(), 1);
            assert!(shell.browsers.contains_key(&surviving));
            assert_eq!(
                shell.right_tabs["peer-b"],
                vec![RightSurface::Browser(surviving)]
            );
            for (id, _) in &deleted {
                assert!(
                    shell
                        .right_tabs
                        .values()
                        .all(|tabs| !tabs.contains(&RightSurface::Browser(*id))),
                    "deleted browser {id} left a dangling tab registration"
                );
            }
            assert!(!shell.panels.get("peer-a").changes_open);
            assert_eq!(
                shell.panels.get("peer-a").right_active,
                RightSurface::Picker
            );
        });
        let before = shell.read_with(cx, link_state);
        for (_, browser) in deleted {
            browser.update(cx, |_, cx| {
                cx.emit(BrowserEvent::NewTab(Some(URL.into())));
                cx.emit(BrowserEvent::OpenSource(
                    "/workspace/link-tests/deleted.rs".into(),
                ));
                cx.emit(BrowserEvent::Close);
            });
        }
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| assert_eq!(link_state(shell, cx), before));
    }
}

#[gpui::test]
fn hidden_transcript_callbacks_cannot_navigate_from_settings(cx: &mut TestAppContext) {
    for source in ["owner", "peer-a"] {
        for action in [
            LinkAction::Primary,
            LinkAction::Internal,
            LinkAction::External,
        ] {
            for target in [URL, "/workspace/link-tests/hidden.rs"] {
                with_link_panes(cx, Some("owner"), |shell, window, cx| {
                    let mut link = activation(Some(source), action);
                    link.target = LinkTarget::new("Synthetic hidden destination", target);
                    let transcript = shell.transcript.entity_id();
                    shell.route = Route::Settings(SettingsSection::Appearance);
                    // A menu/pointer callback may already be queued when the
                    // route hides all transcripts, without changing selection.
                    assert_rejected_unchanged(shell, &link, window, cx);
                    assert_eq!(shell.transcript.entity_id(), transcript);
                    shell.route = Route::Chat;
                    assert_eq!(
                        shell.activate_session_link(
                            &activation(Some(source), LinkAction::External),
                            window,
                            cx
                        ),
                        LinkOutcome::External(URL.into()),
                    );
                });
            }
        }
    }
}

#[gpui::test]
fn revoked_browser_owners_still_close_without_taking_keyboard_focus(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for (archived, synced) in [(true, false), (true, true), (false, true)] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            shell.activate_session_link(
                &activation(Some("peer-a"), LinkAction::Internal),
                window,
                cx,
            );
            setup = Some((
                cx.entity(),
                window.window_handle(),
                shell.browsers[&shell.browser_seq].clone(),
            ));
        });
        let (shell, window, browser) = setup.unwrap();
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, _| {
                state.chats_synced = synced;
                if archived {
                    state
                        .chats
                        .iter_mut()
                        .find(|chat| chat.id == "peer-a")
                        .unwrap()
                        .archived = true;
                } else {
                    state.chats.retain(|chat| chat.id != "peer-a");
                }
                // Hold reconciliation so the revoked browser still has a
                // subscription and a selected, open host when events arrive.
            });
        });
        let focus = window
            .update(cx, |_, window, cx| {
                let composer = shell.read(cx).composer.clone();
                let focus = cx.focus_handle();
                window.replace_root(cx, |_, _| BrowserFocusFixture {
                    composer,
                    other: focus.clone(),
                });
                let _ = window.draw(cx);
                window.focus(&focus, cx);
                focus
            })
            .unwrap();
        let mut expected = shell.read_with(cx, link_state);
        expected.browsers.clear();
        expected.tabs.get_mut("peer-a").unwrap().clear();
        let panel = expected.panels.get_mut("peer-a").unwrap();
        panel.right_active = RightSurface::Picker;
        panel.changes_open = false;
        browser.update(cx, |_, cx| {
            cx.emit(BrowserEvent::Changed);
            cx.emit(BrowserEvent::NewTab(None));
            cx.emit(BrowserEvent::OpenSource(
                "/workspace/link-tests/revoked.rs".into(),
            ));
            cx.emit(BrowserEvent::Close);
        });
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(
                link_state(shell, cx),
                expected,
                "archived={archived}, synced={synced}"
            );
            assert!(shell.browser_subs.is_empty());
        });
        window
            .update(cx, |_, window, _| {
                assert!(
                    focus.is_focused(window),
                    "revoked-owner cleanup stole focus"
                );
            })
            .unwrap();
        // A repeated close from the retained entity is harmless, including
        // while the revoked owner is still selected in AppState.
        browser.update(cx, |_, cx| cx.emit(BrowserEvent::Close));
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| assert_eq!(link_state(shell, cx), expected));
    }
}

#[gpui::test]
fn cached_navigation_survives_an_incomplete_chat_snapshot(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for source in ["owner", "peer-a"] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            assert_eq!(
                shell.activate_session_link(
                    &activation(Some(source), LinkAction::Internal),
                    window,
                    cx
                ),
                LinkOutcome::Internal,
            );
            setup = Some((
                cx.entity(),
                window.window_handle(),
                shell.browsers[&shell.browser_seq].clone(),
            ));
        });
        let (shell, window, browser) = setup.unwrap();
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, _| {
                state.chats_synced = false;
                state.chats.retain(|chat| chat.id != source);
            });
        });
        let before = shell.read_with(cx, link_state);
        window
            .update(cx, |_, window, cx| {
                shell.update(cx, |shell, cx| {
                    assert_eq!(
                        shell.activate_session_link(
                            &activation(Some(source), LinkAction::External),
                            window,
                            cx
                        ),
                        LinkOutcome::External(URL.into()),
                    );
                });
            })
            .unwrap();
        shell.read_with(cx, |shell, cx| assert_eq!(link_state(shell, cx), before));
        browser.update(cx, |_, cx| cx.emit(BrowserEvent::NewTab(None)));
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.active_chat, source);
            assert_eq!(shell.browsers.len(), 2);
            assert_eq!(
                shell.resolved_right_active(cx),
                RightSurface::Browser(shell.browser_seq)
            );
        });
    }
}

#[gpui::test]
fn transcript_callbacks_reject_deleted_or_archived_sources_before_layout_reconciliation(
    cx: &mut TestAppContext,
) {
    for source in ["owner", "peer-a"] {
        for archived in [false, true] {
            for action in [
                LinkAction::Primary,
                LinkAction::Internal,
                LinkAction::External,
            ] {
                with_link_panes(cx, Some("owner"), |shell, window, cx| {
                    let row = shell.state.update(cx, |state, _| {
                        state.chats_synced = true;
                        let index = state
                            .chats
                            .iter()
                            .position(|chat| chat.id == source)
                            .unwrap();
                        let row = state.chats[index].clone();
                        if archived {
                            state.chats[index].archived = true;
                        } else {
                            state.chats.remove(index);
                        }
                        // Stop between the authoritative snapshot and Shell's
                        // observer/next paint: the old transcript still exists.
                        row
                    });
                    assert_rejected_unchanged(shell, &activation(Some(source), action), window, cx);
                    // Restoring the row also restores authority; rejecting one
                    // stale callback must not permanently disable this view.
                    shell.state.update(cx, |state, _| {
                        state.chats.retain(|chat| chat.id != source);
                        state.chats.push(row);
                    });
                    assert_eq!(
                        shell.activate_session_link(
                            &activation(Some(source), LinkAction::External),
                            window,
                            cx
                        ),
                        LinkOutcome::External(URL.into()),
                    );
                });
            }
        }
    }
}

#[gpui::test]
fn browser_callbacks_recheck_owner_liveness_before_snapshot_cleanup(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for archived in [false, true] {
        for event in [
            BrowserEvent::NewTab(None),
            BrowserEvent::OpenSource("/workspace/link-tests/handoff.rs".into()),
        ] {
            let mut setup = None;
            with_link_panes(cx, Some("owner"), |shell, window, cx| {
                shell.activate_session_link(
                    &activation(Some("peer-a"), LinkAction::Internal),
                    window,
                    cx,
                );
                setup = Some((cx.entity(), shell.browsers[&shell.browser_seq].clone()));
            });
            let (shell, browser) = setup.unwrap();
            let row = shell.update(cx, |shell, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats_synced = true;
                    let index = state
                        .chats
                        .iter()
                        .position(|chat| chat.id == "peer-a")
                        .unwrap();
                    let row = state.chats[index].clone();
                    if archived {
                        state.chats[index].archived = true;
                    } else {
                        state.chats.remove(index);
                    }
                    // No notify yet: event delivery must be safe even before
                    // the observer releases a deleted owner's browser host.
                    row
                })
            });
            let before = shell.read_with(cx, link_state);
            browser.update(cx, |_, cx| cx.emit(event.clone()));
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    link_state(shell, cx),
                    before,
                    "archived={archived}, {event:?}"
                );
            });
            shell.update(cx, |shell, cx| {
                shell.state.update(cx, |state, _| {
                    state.chats.retain(|chat| chat.id != "peer-a");
                    state.chats.push(row);
                });
            });
            browser.update(cx, |_, cx| cx.emit(event.clone()));
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| match event {
                BrowserEvent::NewTab(_) => {
                    assert_eq!(shell.browsers.len(), 2);
                    assert_eq!(
                        shell.resolved_right_active(cx),
                        RightSurface::Browser(shell.browser_seq)
                    );
                }
                BrowserEvent::OpenSource(_) => {
                    assert_eq!(shell.file_surfaces.len(), 1);
                    assert!(matches!(
                        shell.resolved_right_active(cx),
                        RightSurface::File(_)
                    ));
                }
                _ => unreachable!(),
            });
        }
    }
}

#[gpui::test]
fn browser_cleanup_waits_for_authoritative_chat_deletion_not_archive_or_partial_sync(
    cx: &mut TestAppContext,
) {
    use crate::browser::BrowserEvent;

    for foreground in [false, true] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            let mut deleted = Vec::new();
            for owner in ["peer-a", "peer-a", "peer-b"] {
                shell.activate_session_link(
                    &activation(Some(owner), LinkAction::Internal),
                    window,
                    cx,
                );
                if owner == "peer-a" {
                    deleted.push((
                        shell.browser_seq,
                        shell.browsers[&shell.browser_seq].clone(),
                    ));
                }
            }
            setup = Some((cx.entity(), deleted));
        });
        let (shell, deleted) = setup.unwrap();
        let original = shell.read_with(cx, link_state);
        // A partial/cold-start chat list is not evidence of deletion.
        let row = shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state.chats_synced = false;
                let index = state
                    .chats
                    .iter()
                    .position(|chat| chat.id == "peer-a")
                    .unwrap();
                let row = state.chats.remove(index);
                cx.notify();
                row
            })
        });
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| assert_eq!(link_state(shell, cx), original));
        // Archiving parks a session; it must not destroy its browser tabs.
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                let mut row = row;
                row.archived = true;
                state.chats.push(row);
                state.chats_synced = true;
                cx.notify();
            });
        });
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            for (id, _) in &deleted {
                assert!(shell.browsers.contains_key(id));
                assert!(shell.browser_subs.contains_key(id));
            }
            assert_eq!(shell.right_tabs, original.tabs);
            assert_eq!(shell.panels.map, original.panels);
        });
        // Restore the row before deleting it in a later authoritative snapshot,
        // as can happen when another client deletes a foreground or parked chat.
        shell.update(cx, |shell, cx| {
            shell.state.update(cx, |state, cx| {
                state
                    .chats
                    .iter_mut()
                    .find(|chat| chat.id == "peer-a")
                    .unwrap()
                    .archived = false;
                cx.notify();
            });
        });
        cx.run_until_parked();
        shell.update(cx, |shell, cx| {
            if foreground {
                assert!(shell.select_chat_pane(0, cx));
                shell.on_state_changed(&shell.state.clone(), cx);
            }
            shell.state.update(cx, |state, cx| {
                state.chats.retain(|chat| chat.id != "peer-a");
                if foreground {
                    state.select_chat(Some("peer-b".into()), cx);
                }
                cx.notify();
            });
        });
        cx.run_until_parked();
        shell.read_with(cx, |shell, _| {
            for (id, _) in &deleted {
                assert!(
                    !shell.browsers.contains_key(id),
                    "snapshot deletion leaked browser {id}"
                );
                assert!(!shell.browser_subs.contains_key(id));
                assert!(!shell.right_tabs["peer-a"].contains(&RightSurface::Browser(*id)));
            }
            assert!(!shell.panels.get("peer-a").changes_open);
            assert_eq!(shell.browsers.len(), 1);
            assert_eq!(shell.right_tabs["peer-b"], original.tabs["peer-b"]);
            assert_eq!(shell.panels.get("peer-b"), original.panels["peer-b"]);
        });
        let before = shell.read_with(cx, link_state);
        for (_, browser) in deleted {
            browser.update(cx, |_, cx| {
                cx.emit(BrowserEvent::NewTab(None));
                cx.emit(BrowserEvent::Close);
            });
        }
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| assert_eq!(link_state(shell, cx), before));
    }
}

#[gpui::test]
fn deleting_background_browsers_preserves_mixed_surfaces_and_keyboard_focus(
    cx: &mut TestAppContext,
) {
    for active_browser in [false, true] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            shell.activate_session_link(
                &activation(Some("peer-a"), LinkAction::Internal),
                window,
                cx,
            );
            let browser = RightSurface::Browser(shell.browser_seq);
            shell.add_diff_surface(cx);
            let diff = shell.resolved_right_active(cx);
            assert!(shell.open_workspace_file_link("/workspace/link-tests/keep.rs", window, cx));
            let file = shell.resolved_right_active(cx);
            assert!(matches!(file, RightSurface::File(_)));
            if active_browser {
                shell.set_right_active(browser, cx);
            }
            shell.activate_session_link(
                &activation(Some("peer-b"), LinkAction::Internal),
                window,
                cx,
            );
            setup = Some((cx.entity(), window.window_handle(), diff, file));
        });
        let (shell, window, diff, file) = setup.unwrap();
        let focus = window
            .update(cx, |_, window, cx| {
                let composer = shell.read(cx).composer.clone();
                let focus = cx.focus_handle();
                window.replace_root(cx, |_, _| BrowserFocusFixture {
                    composer,
                    other: focus.clone(),
                });
                let _ = window.draw(cx);
                window.focus(&focus, cx);
                focus
            })
            .unwrap();
        let mut expected = shell.read_with(cx, link_state);
        let deleted = expected.tabs["peer-a"]
            .iter()
            .find_map(|surface| {
                if let RightSurface::Browser(id) = surface {
                    Some(*id)
                } else {
                    None
                }
            })
            .unwrap();
        expected.browsers.retain(|id| *id != deleted);
        expected.tabs.insert("peer-a".into(), vec![diff, file]);
        // The isolated fixture intentionally has no engine; deleteChat reports
        // that connection status independently of local surface cleanup.
        expected.notice = Some("Engine not connected".into());
        if active_browser {
            expected.panels.get_mut("peer-a").unwrap().right_active = RightSurface::Picker;
        }
        window
            .update(cx, |_, window, cx| {
                shell.update(cx, |shell, cx| {
                    shell.delete_chat("peer-a".into(), window, cx)
                });
            })
            .unwrap();
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(link_state(shell, cx), expected);
            assert_eq!(shell.diffs.len(), 1);
            assert_eq!(
                shell.file_surface_paths.values().next().map(String::as_str),
                Some("keep.rs")
            );
        });
        window
            .update(cx, |_, window, _| assert!(focus.is_focused(window)))
            .unwrap();
    }
}

#[gpui::test]
fn queued_browser_events_cannot_recreate_tabs_during_chat_deletion(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for event in [
        BrowserEvent::NewTab(None),
        BrowserEvent::OpenSource("/workspace/link-tests/race.rs".into()),
        BrowserEvent::Close,
    ] {
        for queue_before_delete in [false, true] {
            let mut setup = None;
            with_link_panes(cx, Some("owner"), |shell, window, cx| {
                shell.activate_session_link(
                    &activation(Some("peer-a"), LinkAction::Internal),
                    window,
                    cx,
                );
                setup = Some((
                    cx.entity(),
                    window.window_handle(),
                    shell.browsers[&shell.browser_seq].clone(),
                ));
            });
            let (shell, window, browser) = setup.unwrap();
            window
                .update(cx, |_, window, cx| {
                    // Both operations share one GPUI update: subscriptions must not
                    // deliver a previously queued navigation after deletion teardown.
                    if queue_before_delete {
                        browser.update(cx, |_, cx| cx.emit(event.clone()));
                    }
                    shell.update(cx, |shell, cx| {
                        shell.delete_chat("peer-a".into(), window, cx)
                    });
                    if !queue_before_delete {
                        browser.update(cx, |_, cx| cx.emit(event.clone()));
                    }
                })
                .unwrap();
            cx.run_until_parked();
            shell.read_with(cx, |shell, _| {
                assert!(
                    shell.browsers.is_empty(),
                    "{event:?}, before={queue_before_delete}"
                );
                assert!(shell.browser_subs.is_empty());
                assert!(shell.right_tabs["peer-a"].is_empty());
                assert!(shell.file_surfaces.is_empty());
                assert_eq!(shell.browser_seq, 1);
            });
        }
    }
}

fn hide_browser_navigation_host(shell: &mut Shell, hidden_by: &str, cx: &mut Context<Shell>) {
    assert_eq!(shell.active_chat, "peer-a");
    match hidden_by {
        "closed-host" => shell.set_surfaces_open(false, cx),
        "settings" => shell.route = Route::Settings(SettingsSection::Appearance),
        "selection-handoff" | "canvas-handoff" => shell.state.update(cx, |state, _| {
            // Deliberately stop between AppState selection and Shell sync.
            state.selected_chat = (hidden_by == "selection-handoff").then(|| "peer-b".into());
        }),
        _ => unreachable!(),
    }
}

#[gpui::test]
fn browser_navigation_events_require_a_visible_consistently_selected_host(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for hidden_by in [
        "closed-host",
        "settings",
        "selection-handoff",
        "canvas-handoff",
    ] {
        for event in [
            BrowserEvent::NewTab(Some("https://example.com/queued-popup".into())),
            BrowserEvent::OpenSource("/workspace/link-tests/queued-source.rs".into()),
        ] {
            let mut setup = None;
            with_link_panes(cx, Some("owner"), |shell, window, cx| {
                assert_eq!(
                    shell.activate_session_link(
                        &activation(Some("peer-a"), LinkAction::Internal),
                        window,
                        cx
                    ),
                    LinkOutcome::Internal
                );
                let browser = shell.browsers[&shell.browser_seq].clone();
                setup = Some((cx.entity(), browser));
            });
            let (shell, browser) = setup.unwrap();
            // Let initial promotion notifications settle before simulating a
            // later in-flight handoff, so this really tests inconsistent state.
            shell.update(cx, |shell, cx| {
                hide_browser_navigation_host(shell, hidden_by, cx)
            });
            let before = shell.read_with(cx, link_state);
            // A native/action event can have been queued while the page was
            // live, before the host disappeared or selection began changing.
            browser.update(cx, |_, cx| cx.emit(event.clone()));
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                assert_eq!(link_state(shell, cx), before, "{hidden_by}: {event:?}")
            });

            // The same live browser regains navigation authority when its
            // owner and host are visible again; do not permanently mute it.
            shell.update(cx, |shell, cx| {
                shell.route = Route::Chat;
                shell
                    .state
                    .update(cx, |state, _| state.selected_chat = Some("peer-a".into()));
                shell.on_state_changed(&shell.state.clone(), cx);
                shell.set_surfaces_open(true, cx);
            });
            cx.run_until_parked();
            browser.update(cx, |_, cx| cx.emit(event.clone()));
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.active_chat, "peer-a");
                assert!(shell.right_pane_open(cx));
                match event {
                    BrowserEvent::NewTab(_) => {
                        assert_eq!(shell.browsers.len(), 2);
                        assert!(shell.file_surfaces.is_empty());
                        assert_eq!(
                            shell.resolved_right_active(cx),
                            RightSurface::Browser(shell.browser_seq)
                        );
                    }
                    BrowserEvent::OpenSource(_) => {
                        assert_eq!(shell.browsers.len(), 1);
                        assert_eq!(shell.file_surfaces.len(), 1);
                        assert!(matches!(
                            shell.resolved_right_active(cx),
                            RightSurface::File(_)
                        ));
                        assert_eq!(
                            shell.file_surface_paths.values().next().map(String::as_str),
                            Some("queued-source.rs")
                        );
                    }
                    _ => unreachable!(),
                }
            });
        }
    }
}

/// Paint both focus destinations so GPUI can retain their focus across frames.
struct BrowserFocusFixture {
    composer: Entity<crate::composer::Composer>,
    other: FocusHandle,
}

impl Render for BrowserFocusFixture {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(
                div()
                    .track_focus(&self.other)
                    .child("Synthetic settings control"),
            )
            .child(self.composer.clone())
    }
}

#[gpui::test]
fn browser_close_remains_allowed_when_navigation_is_blocked(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for hidden_by in [
        "visible-host",
        "closed-host",
        "settings",
        "selection-handoff",
        "canvas-handoff",
    ] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            assert_eq!(
                shell.activate_session_link(
                    &activation(Some("peer-a"), LinkAction::Internal),
                    window,
                    cx
                ),
                LinkOutcome::Internal
            );
            let browser = shell.browsers[&shell.browser_seq].clone();
            setup = Some((cx.entity(), browser, window.window_handle()));
        });
        let (shell, browser, window) = setup.unwrap();
        if hidden_by != "visible-host" {
            shell.update(cx, |shell, cx| {
                hide_browser_navigation_host(shell, hidden_by, cx)
            });
        }
        let (unrelated_control, composer_focus) = window
            .update(cx, |_, window, cx| {
                let composer = shell.read(cx).composer.clone();
                let composer_focus = composer.focus_handle(cx);
                let focus = cx.focus_handle();
                window.replace_root(cx, |_, _| BrowserFocusFixture {
                    composer,
                    other: focus.clone(),
                });
                let _ = window.draw(cx);
                window.focus(&focus, cx);
                assert!(focus.is_focused(window));
                (focus, composer_focus)
            })
            .unwrap();
        if hidden_by == "visible-host" {
            shell.read_with(cx, |shell, cx| {
                assert!(shell.browser_host_is_active("peer-a", shell.browser_seq, cx))
            });
        }
        let mut expected = shell.read_with(cx, link_state);
        expected.browsers.clear();
        expected.tabs.get_mut("peer-a").unwrap().clear();
        let panel = expected.panels.get_mut("peer-a").unwrap();
        panel.right_active = RightSurface::Picker;
        panel.changes_open = false;
        browser.update(cx, |_, cx| cx.emit(BrowserEvent::Close));
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(link_state(shell, cx), expected, "{hidden_by}");
            assert!(shell.browser_subs.is_empty());
        });
        window
            .update(cx, |_, window, _| {
                if hidden_by == "visible-host" {
                    assert!(
                        composer_focus.is_focused(window),
                        "visible active close must restore composer focus"
                    );
                } else {
                    assert!(
                        unrelated_control.is_focused(window),
                        "{hidden_by}: hidden browser close stole keyboard focus"
                    );
                }
            })
            .unwrap();
    }
}

#[gpui::test]
fn browser_close_batches_preserve_a_parked_canvas_in_every_delivery_order(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for order in [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
    ] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            let mut browsers = Vec::new();
            for owner in ["peer-a", "peer-a", "peer-b"] {
                assert_eq!(
                    shell.activate_session_link(
                        &activation(Some(owner), LinkAction::Internal),
                        window,
                        cx
                    ),
                    LinkOutcome::Internal
                );
                browsers.push((
                    owner,
                    shell.browser_seq,
                    shell.browsers[&shell.browser_seq].clone(),
                ));
            }
            shell.new_chat_tab(None, window, cx);
            shell.on_state_changed(&shell.state.clone(), cx);
            shell.adopt_canvas_draft(
                Some(CanvasDraft {
                    harness: Some(harness_proto::HarnessId::Mock),
                    model: Some("synthetic-model".into()),
                    target: Some(CanvasTarget {
                        space: None,
                        no_project: true,
                        device: Some("local".into()),
                    }),
                    input: Some(CanvasInput {
                        text: "Keep this unsent draft while browser closes arrive".into(),
                        ..Default::default()
                    }),
                    ..Default::default()
                }),
                cx,
            );
            setup = Some((cx.entity(), browsers));
        });
        let (shell, browsers) = setup.unwrap();
        let mut expected = shell.read_with(cx, link_state);
        assert!(expected.active.is_empty());
        for index in order {
            let (owner, id, browser) = &browsers[index];
            let surface = RightSurface::Browser(*id);
            expected.browsers.retain(|other| other != id);
            let tabs = expected.tabs.get_mut(*owner).unwrap();
            tabs.retain(|other| *other != surface);
            let panel = expected.panels.get_mut(*owner).unwrap();
            if panel.right_active == surface {
                panel.right_active = RightSurface::Picker;
            }
            if tabs.is_empty() {
                panel.changes_open = false;
            }
            browser.update(cx, |_, cx| cx.emit(BrowserEvent::Close));
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                assert_eq!(
                    link_state(shell, cx),
                    expected,
                    "order={order:?}, closing={id}"
                );
                assert!(!shell.browser_subs.contains_key(id));
            });
        }
        // Retained entities must not regain navigation authority after close.
        for (_, _, browser) in &browsers {
            for event in [
                BrowserEvent::NewTab(Some(URL.into())),
                BrowserEvent::OpenSource("/workspace/link-tests/stale.rs".into()),
                BrowserEvent::Close,
            ] {
                browser.update(cx, |_, cx| cx.emit(event));
            }
        }
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(link_state(shell, cx), expected);
            assert!(shell.browser_subs.is_empty());
        });
    }
}

#[gpui::test]
fn closing_a_browser_preserves_a_surviving_diff_and_does_not_steal_focus(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for background in [false, true] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            assert_eq!(
                shell.activate_session_link(
                    &activation(Some("peer-a"), LinkAction::Internal),
                    window,
                    cx
                ),
                LinkOutcome::Internal
            );
            let id = shell.browser_seq;
            let browser = shell.browsers[&id].clone();
            shell.add_diff_surface(cx);
            let diff = shell.resolved_right_active(cx);
            assert!(matches!(diff, RightSurface::Diff(_)));
            if background {
                assert!(shell.select_chat_pane(1, cx));
                shell.on_state_changed(&shell.state.clone(), cx);
            }
            setup = Some((cx.entity(), browser, id, diff));
        });
        let (shell, browser, id, diff) = setup.unwrap();
        let other_panel = shell.read_with(cx, |shell, _| shell.panels.get("peer-b"));
        browser.update(cx, |_, cx| cx.emit(BrowserEvent::Close));
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(
                shell.active_chat,
                if background { "peer-b" } else { "peer-a" }
            );
            assert_eq!(shell.right_tabs["peer-a"], vec![diff]);
            assert_eq!(shell.panels.get("peer-a").right_active, diff);
            assert!(shell.panels.get("peer-a").changes_open);
            assert!(!shell.browsers.contains_key(&id));
            assert_eq!(shell.panels.get("peer-b"), other_panel);
            assert_eq!(shell.diffs.len(), 1);
            if !background {
                assert_eq!(shell.resolved_right_active(cx), diff);
            }
        });
    }
}

#[gpui::test]
fn browser_close_after_peer_focus_change_cleans_only_its_owner(cx: &mut TestAppContext) {
    use crate::browser::BrowserEvent;

    for keep_another_tab in [false, true] {
        let mut setup = None;
        with_link_panes(cx, Some("owner"), |shell, window, cx| {
            let link = activation(Some("peer-a"), LinkAction::Internal);
            assert_eq!(
                shell.activate_session_link(&link, window, cx),
                LinkOutcome::Internal
            );
            if keep_another_tab {
                assert_eq!(
                    shell.activate_session_link(&link, window, cx),
                    LinkOutcome::Internal
                );
            }
            let closing = shell.browser_seq;
            let browser = shell.browsers[&closing].clone();
            assert_eq!(
                shell.activate_session_link(
                    &activation(Some("peer-b"), LinkAction::Internal),
                    window,
                    cx
                ),
                LinkOutcome::Internal
            );
            setup = Some((
                cx.entity(),
                browser,
                closing,
                shell.browser_seq,
                shell.panels.get("peer-b"),
            ));
        });
        let (shell, browser, closing, other, other_panel) = setup.unwrap();
        browser.update(cx, |_, cx| cx.emit(BrowserEvent::Close));
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.active_chat, "peer-b");
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("peer-b")
            );
            assert_eq!(
                shell.resolved_right_active(cx),
                RightSurface::Browser(other)
            );
            assert_eq!(shell.panels.get("peer-b"), other_panel);
            assert_eq!(
                shell.right_tabs["peer-b"],
                vec![RightSurface::Browser(other)]
            );
            assert!(shell.browsers.contains_key(&other));
            assert!(!shell.browsers.contains_key(&closing));
            assert!(!shell.browser_subs.contains_key(&closing));
            assert!(!shell.right_tabs["peer-a"].contains(&RightSurface::Browser(closing)));
            assert_eq!(
                shell.right_tabs["peer-a"].len(),
                usize::from(keep_another_tab)
            );
            assert_eq!(shell.panels.get("peer-a").changes_open, keep_another_tab);
        });
        // A released subscription cannot close a second tab on duplicate delivery.
        let before = shell.read_with(cx, link_state);
        browser.update(cx, |_, cx| cx.emit(BrowserEvent::Close));
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| assert_eq!(link_state(shell, cx), before));
    }
}

#[gpui::test]
fn browser_navigation_events_cannot_leak_into_another_peer_after_promotion(
    cx: &mut TestAppContext,
) {
    use crate::browser::BrowserEvent;

    let mut setup = None;
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        let link = activation(Some("peer-a"), LinkAction::Internal);
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        let old = shell.browsers[&shell.browser_seq].clone();
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        let active = shell.browsers[&shell.browser_seq].clone();
        setup = Some((cx.entity(), old, active));
    });
    let (shell, old, active) = setup.unwrap();
    for background_owner in [false, true] {
        if background_owner {
            shell.update(cx, |shell, cx| {
                assert!(shell.select_chat_pane(1, cx));
                shell.on_state_changed(&shell.state.clone(), cx);
            });
            cx.run_until_parked();
        }
        let before = shell.read_with(cx, link_state);
        for browser in if background_owner {
            vec![&old, &active]
        } else {
            vec![&old]
        } {
            for event in [
                BrowserEvent::NewTab(Some(URL.into())),
                BrowserEvent::OpenSource("/workspace/link-tests/source.rs".into()),
            ] {
                browser.update(cx, |_, cx| cx.emit(event));
                cx.run_until_parked();
                shell.read_with(cx, |shell, cx| assert_eq!(link_state(shell, cx), before));
            }
        }
    }
    shell.update(cx, |shell, cx| {
        assert!(shell.select_chat_pane(0, cx));
        shell.on_state_changed(&shell.state.clone(), cx);
    });
    cx.run_until_parked();
    active.update(cx, |_, cx| cx.emit(BrowserEvent::NewTab(Some(URL.into()))));
    cx.run_until_parked();
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.active_chat, "peer-a");
        assert_eq!(shell.right_tabs["peer-a"].len(), 3);
        assert!(!shell.right_tabs.contains_key("peer-b"));
        assert_eq!(
            shell.resolved_right_active(cx),
            RightSurface::Browser(shell.browser_seq)
        );
        assert!(shell.right_pane_open(cx));
    });
}

#[gpui::test]
fn link_callbacks_follow_sources_across_focus_zoom_and_chat_tab_round_trips(
    cx: &mut TestAppContext,
) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        let link = activation(Some("peer-a"), LinkAction::Internal);
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        let first = shell.browser_seq;

        // A menu callback retained while another pane is zoomed cannot navigate
        // until its source is visible again.
        assert!(shell.select_chat_pane(1, cx));
        shell.on_state_changed(&shell.state.clone(), cx);
        shell.toggle_chat_pane_zoom(cx);
        assert_rejected_unchanged(shell, &link, window, cx);
        shell.toggle_chat_pane_zoom(cx);
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        assert_eq!(shell.right_tabs["peer-a"].len(), 2);

        // Parked layouts and browsers do not authorize a hidden transcript.
        // Restoring the tab should make a fresh activation work normally.
        shell.new_chat_tab(Some("parked".into()), window, cx);
        shell.on_state_changed(&shell.state.clone(), cx);
        assert_eq!(shell.active_chat, "parked");
        assert!(shell.browsers.contains_key(&first));
        assert_rejected_unchanged(shell, &link, window, cx);
        shell.switch_chat_tab(0, window, cx);
        shell.on_state_changed(&shell.state.clone(), cx);
        assert_eq!(shell.active_chat, "peer-a");
        assert!(shell.right_pane_open(cx));
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        assert_eq!(shell.right_tabs["peer-a"].len(), 3);
        assert!(!shell.right_tabs.contains_key("parked"));
    });
}

#[gpui::test]
fn alternating_peer_links_preserve_each_owners_active_browser_and_transcript(
    cx: &mut TestAppContext,
) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        let owner_view = shell.transcript.entity_id();
        let a_view = shell.peer_chat_views["peer-a"].transcript.entity_id();
        let b_view = shell.peer_chat_views["peer-b"].transcript.entity_id();
        let mut latest = std::collections::HashMap::new();
        for (turn, (source, entity)) in [
            ("peer-a", a_view),
            ("owner", owner_view),
            ("peer-b", b_view),
            ("peer-a", a_view),
            ("peer-b", b_view),
            ("owner", owner_view),
        ]
        .into_iter()
        .enumerate()
        {
            let mut link = activation(Some(source), LinkAction::Internal);
            let url = format!("https://example.com/owners/{source}/{turn}");
            link.target = LinkTarget::new("Synthetic page", &url);
            assert_eq!(
                shell.activate_session_link(&link, window, cx),
                LinkOutcome::Internal
            );
            assert_eq!(shell.active_chat, source);
            assert_eq!(shell.transcript.entity_id(), entity);
            assert!(shell.right_pane_open(cx));
            assert_eq!(
                shell.resolved_right_active(cx),
                RightSurface::Browser(shell.browser_seq)
            );
            latest.insert(source, shell.browser_seq);
            assert_eq!(
                shell.browsers[&shell.browser_seq]
                    .read(cx)
                    .page
                    .url
                    .as_deref(),
                Some(url.as_str())
            );
        }
        for (index, source, entity) in [
            (0, "peer-a", a_view),
            (1, "peer-b", b_view),
            (2, "owner", owner_view),
        ] {
            assert!(shell.select_chat_pane(index, cx));
            shell.on_state_changed(&shell.state.clone(), cx);
            assert_eq!(shell.active_chat, source);
            assert_eq!(shell.transcript.entity_id(), entity);
            assert_eq!(shell.right_tabs[source].len(), 2);
            assert_eq!(
                shell.resolved_right_active(cx),
                RightSurface::Browser(latest[source])
            );
            assert!(shell.right_pane_open(cx));
        }
    });
}
