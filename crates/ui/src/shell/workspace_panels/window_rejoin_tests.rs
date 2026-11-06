use super::window_transfer::WindowTransferFailure;
use super::window_transfer_tests::setup;
use super::*;
use gpui::{AppContext as _, TestAppContext, WindowHandle};

fn detach(
    cx: &mut TestAppContext,
    source: WindowHandle<Shell>,
    tab: PanelTab,
) -> (WindowHandle<Shell>, PanelTab) {
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_new_window(0, tab, None, window, cx)
        })
        .unwrap()
        .unwrap();
    let adopted = destination
        .read_with(cx, |shell, cx| {
            shell.panel_layout(cx).unwrap().panels[0].tabs[0].clone()
        })
        .unwrap();
    (destination, adopted)
}

fn rejoin(
    cx: &mut TestAppContext,
    source: WindowHandle<Shell>,
    tab: PanelTab,
    destination: WindowHandle<Shell>,
    panel: u64,
    insert: Option<usize>,
) -> Result<PanelTab, String> {
    source
        .update(cx, |shell, window, cx| {
            shell.move_workspace_tab_to_window(0, tab, destination, panel, insert, window, cx)
        })
        .unwrap()
}

fn browser_tab(id: u64) -> PanelTab {
    PanelTab::Surface {
        owner: "chat-a".into(),
        surface: RightSurface::Browser(id),
    }
}

fn install_browser(
    cx: &mut TestAppContext,
    handle: WindowHandle<Shell>,
    id: u64,
    tabs: Vec<PanelTab>,
    active: usize,
) -> Entity<crate::browser::BrowserSurface> {
    handle
        .update(cx, |shell, window, cx| {
            let browser = cx.new(|cx| {
                crate::browser::BrowserSurface::new(
                    shell.browser_context.clone(),
                    false,
                    window,
                    cx,
                )
            });
            shell.browser_seq = shell.browser_seq.max(id);
            shell.browsers.insert(id, browser.clone());
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = tabs;
            layout.panels[0].active = active;
            layout.imported.insert(browser_tab(id));
            browser
        })
        .unwrap()
}

fn assert_empty_window(cx: &mut TestAppContext, handle: WindowHandle<Shell>) {
    handle
        .read_with(cx, |shell, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 1);
            assert!(layout.panels[0].tabs.is_empty());
            assert!(shell.state.read(cx).selected_chat.is_none());
            assert!(!shell.window_transfer_preparing);
        })
        .unwrap();
}

fn attachment(id: &str, bytes: &'static [u8]) -> crate::attachments::StagedAttachment {
    crate::attachments::StagedAttachment {
        #[cfg(target_os = "macos")]
        editable: None,
        #[cfg(target_os = "macos")]
        unavailable_editable: None,
        unavailable: None,
        annotations: None,
        id: id.into(),
        name: format!("{id}.txt"),
        image: None,
        file: Some(std::sync::Arc::from(bytes)),
    }
}

#[gpui::test]
fn window_rejoin_last_chat_returns_to_empty_original_without_another_window(
    cx: &mut TestAppContext,
) {
    let (_dir, original) = setup(cx);
    let (original_id, transcript) = original
        .update(cx, |shell, _, cx| {
            shell.panel_layout_mut(cx).panels[0].tabs = vec![PanelTab::Chat("chat-a".into())];
            (shell.window_id().to_owned(), shell.transcript.clone())
        })
        .unwrap();
    let (detached, tab) = detach(cx, original, PanelTab::Chat("chat-a".into()));
    assert_empty_window(cx, original);
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);

    assert_eq!(
        rejoin(cx, detached, tab, original, 0, Some(0)).unwrap(),
        PanelTab::Chat("chat-a".into())
    );
    cx.run_until_parked();

    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_empty_window(cx, detached);
    original
        .read_with(cx, |shell, cx| {
            assert_eq!(shell.window_id(), original_id);
            assert_eq!(shell.transcript.entity_id(), transcript.entity_id());
            assert_eq!(
                shell.panel_layout(cx).unwrap().panels[0].tabs,
                vec![PanelTab::Chat("chat-a".into())]
            );
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-a")
            );
            assert_eq!(shell.state.read(cx).chats.len(), 2);
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-a", cx).text,
                "An unsent draft"
            );
        })
        .unwrap();
    let records = cx.update(|cx| settings::current(cx).workspace_windows.unwrap());
    assert_eq!(records.len(), 2);
    assert_eq!(
        records
            .iter()
            .filter(|record| record.id == original_id)
            .count(),
        1
    );
}

#[gpui::test]
fn window_rejoin_uses_existing_window_even_if_new_window_creation_would_fail(
    cx: &mut TestAppContext,
) {
    let (_dir, original) = setup(cx);
    let (detached, tab) = detach(cx, original, PanelTab::Chat("chat-a".into()));
    cx.update(|cx| cx.set_global(WindowTransferFailure::Creation));
    rejoin(cx, detached, tab, original, 0, None).unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_empty_window(cx, detached);
}

#[gpui::test]
fn window_rejoin_replaces_an_empty_target_placeholder(cx: &mut TestAppContext) {
    let (_dir, original) = setup(cx);
    original
        .update(cx, |shell, _, cx| {
            shell.panel_layout_mut(cx).panels[0].tabs = vec![PanelTab::Chat("chat-a".into())];
        })
        .unwrap();
    let (detached, tab) = detach(cx, original, PanelTab::Chat("chat-a".into()));
    original
        .update(cx, |shell, _, cx| {
            shell
                .workspace_panels
                .drafts
                .insert(77, crate::pickers::CanvasDraft::default());
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::New(77)];
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
        })
        .unwrap();
    rejoin(cx, detached, tab, original, 0, None).unwrap();
    original
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.panel_layout(cx).unwrap().panels[0].tabs,
                vec![PanelTab::Chat("chat-a".into())]
            );
            assert!(!shell.workspace_panels.drafts.contains_key(&77));
        })
        .unwrap();
    assert_empty_window(cx, detached);
}

#[gpui::test]
fn window_rejoin_browser_inserts_into_populated_target_and_remaps_colliding_id(
    cx: &mut TestAppContext,
) {
    let (_dir, original) = setup(cx);
    let moving = install_browser(
        cx,
        original,
        11,
        vec![PanelTab::Chat("chat-b".into()), browser_tab(11)],
        1,
    );
    let (detached, moving_tab) = detach(cx, original, browser_tab(11));
    let moving_id = match moving_tab {
        PanelTab::Surface {
            surface: RightSurface::Browser(id),
            ..
        } => id,
        _ => panic!("browser tab must stay a browser"),
    };
    let existing = install_browser(
        cx,
        original,
        moving_id,
        vec![browser_tab(moving_id), PanelTab::Chat("chat-b".into())],
        1,
    );
    original
        .update(cx, |shell, _, cx| {
            let prior_key = shell.workspace_layout_key(cx);
            let layout = shell.workspace_panels.layouts.remove(&prior_key).unwrap();
            shell.chat_tabs[shell.chat_tab].id = "target-session".into();
            shell.chat_tabs[shell.chat_tab].title = Some("Keep the target session".into());
            shell
                .workspace_panels
                .layouts
                .insert("target-session".into(), layout);
            shell.composer.update(cx, |composer, cx| {
                composer.input.update(cx, |input, cx| {
                    input.set_text("Keep the target chat input", cx)
                });
            });
        })
        .unwrap();

    let adopted = rejoin(cx, detached, browser_tab(moving_id), original, 0, Some(1)).unwrap();
    let adopted_id = match adopted {
        PanelTab::Surface {
            surface: RightSurface::Browser(id),
            ..
        } => id,
        _ => panic!("browser tab must stay a browser"),
    };
    assert_ne!(adopted_id, moving_id);
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_empty_window(cx, detached);
    original
        .read_with(cx, |shell, cx| {
            assert_eq!(shell.chat_tabs.len(), 1);
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, "target-session");
            assert_eq!(
                shell.chat_tabs[shell.chat_tab].title.as_deref(),
                Some("Keep the target session")
            );
            assert_eq!(shell.browsers.len(), 2);
            assert_eq!(shell.browsers[&moving_id].entity_id(), existing.entity_id());
            assert_eq!(shell.browsers[&adopted_id].entity_id(), moving.entity_id());
            let panel = &shell.panel_layout(cx).unwrap().panels[0];
            assert_eq!(
                panel.tabs,
                vec![
                    browser_tab(moving_id),
                    browser_tab(adopted_id),
                    PanelTab::Chat("chat-b".into())
                ]
            );
            assert_eq!(panel.active, 1);
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("chat-b", cx).text,
                "Keep the target chat input"
            );
        })
        .unwrap();
    detached
        .read_with(cx, |shell, _| assert!(shell.browsers.is_empty()))
        .unwrap();
}

#[gpui::test]
fn window_rejoin_chat_preserves_live_transcript_draft_selection_and_attachment_bytes(
    cx: &mut TestAppContext,
) {
    use gpui::EntityInputHandler as _;
    let (_dir, original) = setup(cx);
    let mut shot = crate::appshots::tests::shot();
    shot.screenshot = attachment("rejoin-appshot", b"appshot byte payload");
    let transcript = original
        .update(cx, |shell, window, cx| {
            shell.composer.update(cx, |composer, cx| {
                composer.input.update(cx, |input, cx| {
                    input.set_text("", cx);
                    input.replace_and_mark_text_in_range(
                        None,
                        "A returning draft",
                        Some(2..8),
                        window,
                        cx,
                    );
                    input.unmark_text(window, cx);
                });
                composer.attachments.insert(
                    "chat-a".into(),
                    vec![attachment("rejoin-file", b"unsent file bytes")],
                );
                composer.stage_appshot_for("chat-a".into(), shot.clone(), cx);
            });
            shell.transcript.clone()
        })
        .unwrap();
    let (detached, tab) = detach(cx, original, PanelTab::Chat("chat-a".into()));
    original
        .update(cx, |shell, _, cx| {
            shell.composer.update(cx, |composer, cx| {
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("Unrelated target draft", cx));
            });
        })
        .unwrap();

    rejoin(cx, detached, tab, original, 0, Some(0)).unwrap();

    original
        .update(cx, |shell, window, cx| {
            assert_eq!(shell.transcript.entity_id(), transcript.entity_id());
            assert_eq!(
                shell.panel_layout(cx).unwrap().panels[0].tabs,
                vec![
                    PanelTab::Chat("chat-a".into()),
                    PanelTab::Chat("chat-b".into())
                ]
            );
            shell.composer.update(cx, |composer, cx| {
                assert_eq!(
                    composer.parked_chat_input("chat-a", cx).text,
                    "A returning draft"
                );
                assert_eq!(
                    composer.parked_chat_input("chat-b", cx).text,
                    "Unrelated target draft"
                );
                assert_eq!(
                    composer.attachments["chat-a"][0].bytes(),
                    b"unsent file bytes"
                );
                assert_eq!(
                    composer.appshots["chat-a"][0].screenshot.bytes(),
                    b"appshot byte payload"
                );
                let range = composer.input.update(cx, |input, cx| {
                    input.selected_text_range(false, window, cx).unwrap()
                });
                assert_eq!(range.range, 2..8);
            });
        })
        .unwrap();
    detached
        .read_with(cx, |shell, cx| {
            let composer = shell.composer.read(cx);
            assert!(composer.parked_chat_input("chat-a", cx).text.is_empty());
            assert!(!composer.attachments.contains_key("chat-a"));
            assert!(!composer.appshots.contains_key("chat-a"));
        })
        .unwrap();
    assert_empty_window(cx, detached);
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
}

#[gpui::test]
fn window_rejoin_draft_remaps_id_and_keeps_nonempty_target_draft(cx: &mut TestAppContext) {
    let (_dir, original) = setup(cx);
    original
        .update(cx, |shell, _, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::Draft(11)];
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
            shell
                .workspace_panels
                .drafts
                .insert(11, crate::pickers::CanvasDraft::default());
            shell.composer.update(cx, |composer, cx| {
                composer.current_key.clear();
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("Returning draft", cx));
            });
        })
        .unwrap();
    let (detached, tab) = detach(cx, original, PanelTab::Draft(11));
    let PanelTab::Draft(id) = tab else {
        panic!("draft must stay a draft")
    };
    original
        .update(cx, |shell, _, cx| {
            shell.workspace_panels.seq = shell.workspace_panels.seq.max(id);
            shell
                .workspace_panels
                .drafts
                .insert(id, crate::pickers::CanvasDraft::default());
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::Draft(id)];
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
            shell.composer.update(cx, |composer, cx| {
                composer.current_key.clear();
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("Keep this target draft", cx));
            });
        })
        .unwrap();

    let adopted = rejoin(cx, detached, PanelTab::Draft(id), original, 0, None).unwrap();
    assert_ne!(adopted, PanelTab::Draft(id));
    original
        .read_with(cx, |shell, cx| {
            let panel = &shell.panel_layout(cx).unwrap().panels[0];
            assert_eq!(panel.tabs, vec![PanelTab::Draft(id), adopted]);
            assert_eq!(
                shell.workspace_panels.drafts[&id]
                    .input
                    .as_ref()
                    .unwrap()
                    .text,
                "Keep this target draft"
            );
            assert_eq!(
                shell.composer.read(cx).parked_chat_input("", cx).text,
                "Returning draft"
            );
        })
        .unwrap();
    assert_empty_window(cx, detached);
}

fn shell_snapshot(cx: &mut TestAppContext, handle: WindowHandle<Shell>) -> serde_json::Value {
    handle
        .read_with(cx, |shell, cx| {
            let mut browsers = shell.browsers.iter().map(|(id, browser)| (*id, format!("{:?}", browser.entity_id()))).collect::<Vec<_>>();
            browsers.sort();
            let composer = shell.composer.read(cx);
            serde_json::json!({
                "windowId": shell.window_id(),
                "selectedChat": shell.state.read(cx).selected_chat,
                "tabs": shell.panel_layout(cx).unwrap().panels.iter().map(|panel| (panel.id, format!("{:?}", panel.tabs), panel.active)).collect::<Vec<_>>(),
                "browsers": browsers,
                "chatAInput": composer.parked_chat_input("chat-a", cx).text,
                "chatBInput": composer.parked_chat_input("chat-b", cx).text,
                "blankInput": composer.parked_chat_input("", cx).text,
                "chatTabs": format!("{:?}", shell.chat_tabs),
                "chatTab": shell.chat_tab,
                "lastSpaceId": shell.settings.last_space_id,
                "preparing": shell.window_transfer_preparing,
            })
        })
        .unwrap()
}

fn failed_rejoin_keeps_both_windows(cx: &mut TestAppContext, failure: WindowTransferFailure) {
    let (_dir, original) = setup(cx);
    let browser = install_browser(
        cx,
        original,
        11,
        vec![PanelTab::Chat("chat-b".into()), browser_tab(11)],
        1,
    );
    let (detached, tab) = detach(cx, original, browser_tab(11));
    for handle in [original, detached] {
        handle
            .update(cx, |shell, _, cx| {
                shell.park_workspace_draft(cx);
                shell.park_chat_tab(cx);
                shell.save_window_record(cx);
            })
            .unwrap();
    }
    let original_before = shell_snapshot(cx, original);
    let detached_before = shell_snapshot(cx, detached);
    let records_before = cx.update(|cx| settings::current(cx).workspace_windows);
    cx.update(|cx| cx.set_global(failure));

    assert!(rejoin(cx, detached, tab, original, 0, Some(0)).is_err());
    cx.run_until_parked();

    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
    assert_eq!(shell_snapshot(cx, original), original_before);
    assert_eq!(shell_snapshot(cx, detached), detached_before);
    assert_eq!(
        cx.update(|cx| settings::current(cx).workspace_windows),
        records_before
    );
    detached
        .read_with(cx, |shell, _| {
            assert_eq!(
                shell.browsers.values().next().unwrap().entity_id(),
                browser.entity_id()
            );
        })
        .unwrap();
    original
        .read_with(cx, |shell, _| assert!(shell.browsers.is_empty()))
        .unwrap();
}

#[gpui::test]
fn window_rejoin_native_adoption_failure_preserves_both_windows_and_records(
    cx: &mut TestAppContext,
) {
    failed_rejoin_keeps_both_windows(cx, WindowTransferFailure::NativeAdoption);
}

#[gpui::test]
fn window_rejoin_first_paint_failure_restores_target_and_live_source(cx: &mut TestAppContext) {
    failed_rejoin_keeps_both_windows(cx, WindowTransferFailure::FirstPaint);
}

#[gpui::test]
fn window_rejoin_stale_target_panel_preserves_source_and_target(cx: &mut TestAppContext) {
    let (_dir, original) = setup(cx);
    let (detached, tab) = detach(cx, original, PanelTab::Chat("chat-a".into()));
    let before = (shell_snapshot(cx, original), shell_snapshot(cx, detached));
    assert!(rejoin(cx, detached, tab, original, u64::MAX, Some(0)).is_err());
    assert_eq!(
        (shell_snapshot(cx, original), shell_snapshot(cx, detached)),
        before
    );
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
}

#[gpui::test]
fn window_rejoin_closed_target_does_not_lose_the_source_tab(cx: &mut TestAppContext) {
    let (_dir, original) = setup(cx);
    let (detached, tab) = detach(cx, original, PanelTab::Chat("chat-a".into()));
    gpui::AnyWindowHandle::from(original)
        .update(cx, |_, window, _| window.remove_window())
        .unwrap();
    let before = shell_snapshot(cx, detached);
    assert!(rejoin(cx, detached, tab, original, 0, None).is_err());
    assert_eq!(shell_snapshot(cx, detached), before);
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
}

#[gpui::test]
fn window_rejoin_same_window_rejects_without_duplicate_placement(cx: &mut TestAppContext) {
    let (_dir, source) = setup(cx);
    let before = shell_snapshot(cx, source);
    assert!(rejoin(cx, source, PanelTab::Chat("chat-a".into()), source, 0, None).is_err());
    assert_eq!(shell_snapshot(cx, source), before);
    assert_eq!(cx.update(|cx| cx.windows().len()), 1);
}

#[gpui::test]
fn window_rejoin_duplicate_chat_rejects_without_overwriting_either_draft(cx: &mut TestAppContext) {
    let (_dir, original) = setup(cx);
    let (detached, tab) = detach(cx, original, PanelTab::Chat("chat-a".into()));
    original
        .update(cx, |shell, window, cx| {
            shell.panel_layout_mut(cx).panels[0]
                .tabs
                .push(PanelTab::Chat("chat-a".into()));
            shell.focus_workspace_tab(0, PanelTab::Chat("chat-a".into()), window, cx);
            shell.composer.update(cx, |composer, cx| {
                composer.input.update(cx, |input, cx| {
                    input.set_text("Existing target chat draft", cx)
                });
            });
        })
        .unwrap();
    let before = (shell_snapshot(cx, original), shell_snapshot(cx, detached));
    assert!(rejoin(cx, detached, tab, original, 0, None).is_err());
    assert_eq!(
        (shell_snapshot(cx, original), shell_snapshot(cx, detached)),
        before
    );
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
}

#[gpui::test]
fn window_rejoin_rejects_target_canvas_appshots_without_losing_either_draft(
    cx: &mut TestAppContext,
) {
    let (_dir, original) = setup(cx);
    original
        .update(cx, |shell, _, cx| {
            shell
                .state
                .update(cx, |state, cx| state.select_chat(None, cx));
            shell
                .workspace_panels
                .drafts
                .insert(11, crate::pickers::CanvasDraft::default());
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::Draft(11)];
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
            shell.composer.update(cx, |composer, cx| {
                composer.current_key.clear();
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("Detached draft input", cx));
                composer.attachments.insert(
                    String::new(),
                    vec![attachment("source-canvas", b"source canvas file bytes")],
                );
            });
        })
        .unwrap();
    let (detached, tab) = detach(cx, original, PanelTab::Draft(11));
    let mut shot = crate::appshots::tests::shot();
    shot.screenshot = attachment("target-canvas-appshot", b"target canvas capture bytes");
    original
        .update(cx, |shell, _, cx| {
            shell
                .workspace_panels
                .drafts
                .insert(77, crate::pickers::CanvasDraft::default());
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::Draft(77)];
            layout.panels[0].active = 0;
            layout.last_selected = Some(None);
            shell.composer.update(cx, |composer, cx| {
                composer.current_key.clear();
                composer.input.update(cx, |input, cx| {
                    input.set_text("Target draft with a capture", cx)
                });
                composer.stage_appshot_for(String::new(), shot.clone(), cx);
            });
        })
        .unwrap();
    let before = (shell_snapshot(cx, original), shell_snapshot(cx, detached));
    let records_before = cx.update(|cx| settings::current(cx).workspace_windows);

    let error = rejoin(cx, detached, tab, original, 0, None).unwrap_err();
    assert!(error.contains("staged app captures"));
    assert_eq!(
        (shell_snapshot(cx, original), shell_snapshot(cx, detached)),
        before
    );
    assert_eq!(
        cx.update(|cx| settings::current(cx).workspace_windows),
        records_before
    );
    original
        .read_with(cx, |shell, cx| {
            let captures = &shell.composer.read(cx).appshots[""];
            assert_eq!(captures.len(), 1);
            assert_eq!(captures[0].id, shot.id);
            assert_eq!(
                captures[0].screenshot.bytes(),
                b"target canvas capture bytes"
            );
            assert!(shell.workspace_panels.drafts.contains_key(&77));
        })
        .unwrap();
    detached
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.composer.read(cx).attachments[""][0].bytes(),
                b"source canvas file bytes"
            );
        })
        .unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
}

fn rejoined_diff(
    cx: &mut TestAppContext,
    original: WindowHandle<Shell>,
) -> (WindowHandle<Shell>, PanelTab, Entity<Changes>) {
    let changes = original
        .update(cx, |shell, _, cx| {
            let changes = cx.new(|cx| Changes::new(shell.state.clone(), cx));
            shell.diff_seq = 11;
            shell.diffs.insert(11, changes.clone());
            let tab = PanelTab::Surface {
                owner: "chat-a".into(),
                surface: RightSurface::Diff(11),
            };
            let layout = shell.panel_layout_mut(cx);
            layout.panels[0].tabs = vec![PanelTab::Chat("chat-b".into()), tab.clone()];
            layout.panels[0].active = 1;
            layout.imported.insert(tab);
            changes
        })
        .unwrap();
    let (detached, tab) = detach(
        cx,
        original,
        PanelTab::Surface {
            owner: "chat-a".into(),
            surface: RightSurface::Diff(11),
        },
    );
    let returned = rejoin(cx, detached, tab, original, 0, None).unwrap();
    (detached, returned, changes)
}

#[gpui::test]
fn window_rejoin_failed_second_diff_move_preserves_its_pinned_chat_context(
    cx: &mut TestAppContext,
) {
    let (_dir, original) = setup(cx);
    let (detached, returned, changes) = rejoined_diff(cx, original);
    let pinned = changes.read_with(cx, |changes, _| changes.window_state());
    original
        .read_with(cx, |shell, cx| {
            assert_ne!(shell.state.entity_id(), pinned.entity_id());
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-b")
            );
            assert_eq!(pinned.read(cx).selected_chat.as_deref(), Some("chat-a"));
        })
        .unwrap();
    let before = (shell_snapshot(cx, original), shell_snapshot(cx, detached));
    cx.update(|cx| cx.set_global(WindowTransferFailure::FirstPaint));

    assert!(rejoin(cx, original, returned.clone(), detached, 0, None).is_err());

    assert_eq!(
        (shell_snapshot(cx, original), shell_snapshot(cx, detached)),
        before
    );
    changes.read_with(cx, |changes, cx| {
        let state = changes.window_state();
        assert_eq!(state.entity_id(), pinned.entity_id());
        assert_eq!(state.read(cx).selected_chat.as_deref(), Some("chat-a"));
    });
    original
        .read_with(cx, |shell, cx| {
            let PanelTab::Surface {
                surface: RightSurface::Diff(id),
                ..
            } = returned
            else {
                panic!("diff must stay a diff")
            };
            assert_eq!(shell.diffs[&id].entity_id(), changes.entity_id());
            assert!(
                shell.panel_layout(cx).unwrap().panels[0]
                    .tabs
                    .contains(&PanelTab::Surface {
                        owner: "chat-a".into(),
                        surface: RightSurface::Diff(id)
                    })
            );
        })
        .unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
}

#[gpui::test]
fn window_rejoin_history_commit_opens_in_the_moved_diff_checkout(cx: &mut TestAppContext) {
    let (_dir, original) = setup(cx);
    let (_detached, returned, changes) = rejoined_diff(cx, original);
    let PanelTab::Surface {
        surface: RightSurface::Diff(existing_id),
        ..
    } = returned
    else {
        panic!("diff must stay a diff")
    };
    let commit = harness_proto::GitHistoryCommit {
        sha: "0123456789abcdef".into(),
        parent_shas: vec!["fedcba9876543210".into()],
        subject: "A synthetic change".into(),
        author_name: "Fixture Author".into(),
        author_email: "fixture@example.invalid".into(),
        authored_at: "2026-10-31T00:00:00Z".into(),
        refs: vec![],
    };
    changes.update(cx, |_, cx| {
        cx.emit(crate::changes::ChangesEvent::OpenCommit(commit))
    });
    cx.run_until_parked();

    original
        .read_with(cx, |shell, cx| {
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("chat-b")
            );
            assert_eq!(shell.diffs.len(), 2);
            let (&new_id, commit_changes) = shell
                .diffs
                .iter()
                .find(|(id, _)| **id != existing_id)
                .unwrap();
            assert_eq!(
                commit_changes
                    .read(cx)
                    .window_state()
                    .read(cx)
                    .selected_chat
                    .as_deref(),
                Some("chat-a")
            );
            assert!(
                shell.panel_layout(cx).unwrap().panels[0]
                    .tabs
                    .contains(&PanelTab::Surface {
                        owner: "chat-a".into(),
                        surface: RightSurface::Diff(new_id)
                    })
            );
        })
        .unwrap();
    assert_eq!(cx.update(|cx| cx.windows().len()), 2);
}
