//! Native history captures and production key/pointer dispatch on synthetic data.
use super::shared_header::{capture_native, dispatch};
use super::*;
use gpui::{AnyWindowHandle, MouseButton, Pixels, PlatformInput, WindowHandle};

const DRAFT: &str = "Keep this unsent note when I close and reopen the chat.";

pub(super) fn actions_only() -> bool {
    std::env::var("HARNESS_HISTORY_ACTIONS_ONLY").as_deref() == Ok("1")
}

fn optional_bounds(
    handle: WindowHandle<shell::Shell>,
    selector: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<Option<Bounds<Pixels>>> {
    Ok(AnyWindowHandle::from(handle).update(cx, |_, window, cx| {
        // Cached sidebar paint replays its scene without repopulating debug
        // selectors. Inspect a freshly rendered frame, including absence.
        window.refresh();
        window.draw(cx).clear();
        window.debug_bounds(selector)
    })?)
}

fn bounds(
    handle: WindowHandle<shell::Shell>,
    selector: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<Bounds<Pixels>> {
    optional_bounds(handle, selector, cx)?
        .ok_or_else(|| anyhow::anyhow!("missing rendered selector {selector:?}"))
}

fn state(
    handle: WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
) -> anyhow::Result<serde_json::Value> {
    Ok(handle.read_with(cx, |shell, cx| shell.fixture_chat_history_state(cx))?)
}

fn click(
    handle: WindowHandle<shell::Shell>,
    selector: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let position = bounds(handle, selector, cx)?.center();
    dispatch(
        handle,
        PlatformInput::MouseMove(gpui::MouseMoveEvent {
            position,
            ..Default::default()
        }),
        cx,
    )?;
    dispatch(
        handle,
        PlatformInput::MouseDown(gpui::MouseDownEvent {
            position,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )?;
    dispatch(
        handle,
        PlatformInput::MouseUp(gpui::MouseUpEvent {
            position,
            button: MouseButton::Left,
            click_count: 1,
            ..Default::default()
        }),
        cx,
    )
}

async fn press(
    handle: WindowHandle<shell::Shell>,
    key: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    // CloseTab is global and resolves App::active_window. Shell-local actions
    // below use this explicit window's dispatch tree even when AppKit has
    // transferred foreground ownership. This fixture does not send OS keys.
    let requires_active_window = matches!(key, "cmd-w" | "ctrl-shift-w");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while !actions_only() {
        let (native_active, app_active) = handle.update(cx, |_, window, cx| {
            (
                window.is_window_active(),
                cx.active_window()
                    .is_some_and(|active| active.window_id() == window.window_handle().window_id()),
            )
        })?;
        if native_active && app_active {
            break;
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "fixture window was not active before {key}: nativeActive={native_active}, appActive={app_active}"
        );
        handle.update(cx, |_, window, cx| {
            cx.activate(true);
            window.activate_window();
        })?;
        pause(cx, 80).await;
        if !requires_active_window {
            let active = handle.update(cx, |_, window, _| window.is_window_active())?;
            if !active {
                eprintln!(
                    "Fixture {key}: explicit Shell event dispatch while native window is inactive; OS shortcut routing is outside this fixture's scope"
                );
            }
            break;
        }
    }
    let keystroke = gpui::Keystroke::parse(key)?;
    dispatch(
        handle,
        PlatformInput::KeyDown(gpui::KeyDownEvent {
            keystroke: keystroke.clone(),
            is_held: false,
            prefer_character_input: false,
        }),
        cx,
    )?;
    dispatch(
        handle,
        PlatformInput::KeyUp(gpui::KeyUpEvent { keystroke }),
        cx,
    )
}

fn assert_history(value: &serde_json::Value) -> anyhow::Result<()> {
    let palette = &value["palette"];
    anyhow::ensure!(
        palette["open"] == true && palette["historyOnly"] == true,
        "clock did not open the chat history view: {value}"
    );
    anyhow::ensure!(
        palette["entries"].as_array().is_some_and(|entries| entries
            .iter()
            .all(|entry| { !matches!(entry["kind"].as_str(), Some("action" | "external")) })),
        "history includes command or external-import entries: {value}"
    );
    Ok(())
}

fn has_chat(value: &serde_json::Value, id: &str) -> bool {
    value["palette"]["entries"]
        .as_array()
        .is_some_and(|entries| {
            entries
                .iter()
                .any(|entry| entry["id"] == id || entry["chatId"] == id)
        })
}

async fn run(
    handle: WindowHandle<shell::Shell>,
    tone: &str,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<Vec<serde_json::Value>> {
    let mut records = vec![];
    for (width, height) in [(1200.0, 760.0), (980.0, 700.0), (760.0, 700.0)] {
        for collapsed in [false, true] {
            for kind in ["one-tab", "expanded-split"] {
                handle.update(cx, |shell, window, cx| {
                    window.resize(size(px(width), px(height)));
                    shell.fixture_chat_history_case(kind, collapsed, width < 1200.0, window, cx);
                })?;
                pause(cx, 280).await;
                let selector = if collapsed {
                    "titlebar-chat-history"
                } else {
                    "sidebar-chat-history"
                };
                let absent = if collapsed {
                    "sidebar-chat-history"
                } else {
                    "titlebar-chat-history"
                };
                let clock = bounds(handle, selector, cx)?;
                let duplicate = optional_bounds(handle, absent, cx)?;
                anyhow::ensure!(duplicate.is_none(), "both history entry points are visible");
                let body = bounds(handle, "workspace-panel-body-0", cx)?;
                anyhow::ensure!(
                    (f32::from(body.top()) - 42.0).abs() < 1.0,
                    "history clock changed compact header height: {body:?}"
                );
                anyhow::ensure!(
                    clock.left() >= px(0.0) && clock.right() <= px(width),
                    "history clock is outside the window: {clock:?}"
                );
                let location = if collapsed { "collapsed" } else { "expanded" };
                let name = format!("chat-history-{tone}-{width}-{kind}-{location}");
                capture_native(handle, output, &name, cx).await?;
                click(handle, selector, cx)?;
                pause(cx, 240).await;
                let open = state(handle, cx)?;
                assert_history(&open)?;
                bounds(handle, "chat-history-title-icon", cx)?;
                anyhow::ensure!(
                    optional_bounds(handle, "command-palette-keyboard-hints", cx)?.is_none(),
                    "Chat history still renders the keyboard-hint footer"
                );
                anyhow::ensure!(
                    open["sidebarCollapsed"] == collapsed,
                    "opening history changed sidebar visibility"
                );
                capture_native(handle, output, &format!("{name}-popup"), cx).await?;
                records.push(serde_json::json!({"capture":name,"state":open,"bodyTop":f32::from(body.top())}));
                press(handle, "escape", cx).await?;
                pause(cx, 100).await;
                anyhow::ensure!(
                    state(handle, cx)?["palette"]["open"] == false,
                    "Escape did not close history"
                );
            }
        }
    }

    handle.update(cx, |shell, window, cx| {
        window.resize(size(px(1200.0), px(760.0)));
        shell.fixture_chat_history_case("one-tab", false, false, window, cx);
    })?;
    pause(cx, 240).await;
    click(handle, "sidebar-chat-history", cx)?;
    pause(cx, 150).await;
    for (query, id, name) in [
        ("offline", "mobile-1", "search-other-project"),
        ("onboarding", "mobile-0", "search-archived"),
    ] {
        handle.update(cx, |shell, window, cx| {
            shell.fixture_command_palette(Some(query), window, cx)
        })?;
        pause(cx, 180).await;
        let found = state(handle, cx)?;
        assert_history(&found)?;
        anyhow::ensure!(
            has_chat(&found, id),
            "history query {query:?} did not find {id}: {found}"
        );
        if id == "mobile-0" {
            anyhow::ensure!(
                found["palette"]["entries"]
                    .as_array()
                    .is_some_and(|entries| entries
                        .iter()
                        .any(|entry| entry["id"] == id && entry["archived"] == true)),
                "archived search result lost its archived state: {found}"
            );
        }
        capture_native(handle, output, &format!("chat-history-{tone}-{name}"), cx).await?;
        records.push(serde_json::json!({"query":query,"state":found}));
    }
    press(handle, "escape", cx).await?;
    pause(cx, 120).await;

    handle.update(cx, |shell, window, cx| {
        shell.fixture_chat_history_case("one-tab", true, false, window, cx)
    })?;
    pause(cx, 240).await;
    let prepared = state(handle, cx)?;
    anyhow::ensure!(
        prepared["selectedChat"] == "launch-0" && prepared["currentKey"] == "launch-0",
        "roundtrip editor does not belong to the selected chat: {prepared}"
    );
    handle.update(cx, |shell, window, cx| {
        shell.fixture_chat_history_draft(DRAFT, window, cx)
    })?;
    pause(cx, 120).await;
    let before = state(handle, cx)?;
    anyhow::ensure!(
        before["selectedChat"] == "launch-0"
            && before["currentKey"] == "launch-0"
            && before["draft"] == DRAFT
            && before["liveDraft"] == DRAFT,
        "roundtrip fixture was not prepared: {before}"
    );
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-before-close"),
        cx,
    )
    .await?;
    press(
        handle,
        if cfg!(target_os = "macos") {
            "cmd-w"
        } else {
            "ctrl-shift-w"
        },
        cx,
    )
    .await?;
    pause(cx, 240).await;
    let closed = state(handle, cx)?;
    anyhow::ensure!(
        closed["selectedChat"] != "launch-0" && !closed["tabs"].to_string().contains("launch-0"),
        "close shortcut left the chat open: {closed}"
    );
    anyhow::ensure!(
        closed["launchArchived"] == false,
        "closing the tab archived its conversation"
    );
    anyhow::ensure!(
        closed["closedRecord"]["draft"]["input"]["text"] == DRAFT
            && closed["savedClosedRecord"] == closed["closedRecord"],
        "close did not persist the same chat and unsent draft to temporary settings: {closed}"
    );
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-after-close"),
        cx,
    )
    .await?;
    click(handle, "titlebar-chat-history", cx)?;
    pause(cx, 180).await;
    let recent = state(handle, cx)?;
    assert_history(&recent)?;
    anyhow::ensure!(
        has_chat(&recent, "launch-0"),
        "closed chat is missing from history: {recent}"
    );
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-recently-closed"),
        cx,
    )
    .await?;
    // Exercise the advertised shortcut while the history search owns focus.
    // Reopening must dismiss the popup as well as restore the conversation.
    press(
        handle,
        if cfg!(target_os = "macos") {
            "cmd-shift-t"
        } else {
            "ctrl-shift-t"
        },
        cx,
    )
    .await?;
    pause(cx, 260).await;
    let reopened = state(handle, cx)?;
    anyhow::ensure!(
        reopened["palette"]["open"] == false,
        "reopen shortcut left Chat history open: {reopened}"
    );
    for field in [
        "selectedChat",
        "sessionId",
        "panelIds",
        "tabs",
        "focusedPanel",
        "draft",
        "currentKey",
        "liveDraft",
    ] {
        anyhow::ensure!(
            before[field] == reopened[field],
            "reopen did not restore {field}: before={before}, after={reopened}"
        );
    }
    anyhow::ensure!(
        reopened["closedRecord"].is_null() && reopened["savedClosedRecord"].is_null(),
        "reopen left the consumed recovery entry in settings: {reopened}"
    );
    capture_native(handle, output, &format!("chat-history-{tone}-reopened"), cx).await?;
    records.push(serde_json::json!({"roundtrip":{"before":before,"closed":closed,"history":recent,"reopened":reopened}}));
    records.extend(exercise_actions(handle, tone, output, cx).await?);
    Ok(records)
}

async fn exercise_actions(
    handle: WindowHandle<shell::Shell>,
    tone: &str,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<Vec<serde_json::Value>> {
    let mut records = vec![];
    if actions_only() {
        anyhow::ensure!(
            handle.update(cx, |shell, window, cx| shell
                .fixture_chat_history_close(window, cx))?,
            "targeted fixture setup did not close the synthetic chat"
        );
    } else {
        press(
            handle,
            if cfg!(target_os = "macos") {
                "cmd-w"
            } else {
                "ctrl-shift-w"
            },
            cx,
        )
        .await?;
    }
    pause(cx, 180).await;
    let closed = state(handle, cx)?;
    anyhow::ensure!(
        closed["selectedChat"].is_null()
            && closed["closedRecord"]["draft"]["input"]["text"] == DRAFT,
        "action fixture did not close its synthetic draft: {closed}"
    );
    click(handle, "titlebar-chat-history", cx)?;
    pause(cx, 160).await;
    bounds(handle, "chat-history-title-icon", cx)?;
    anyhow::ensure!(
        optional_bounds(handle, "command-palette-keyboard-hints", cx)?.is_none(),
        "Chat history still renders the keyboard-hint footer"
    );
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-actions-popup"),
        cx,
    )
    .await?;
    click(handle, "history-discard-launch-0", cx)?;
    pause(cx, 160).await;
    let prompt = state(handle, cx)?;
    anyhow::ensure!(
        prompt["palette"]["discardOpen"] == true
            && prompt["selectedChat"].is_null()
            && prompt["tabs"] == closed["tabs"],
        "Discard restored the chat or failed to open its confirmation: {prompt}"
    );
    bounds(handle, "history-discard-dialog", cx)?;
    bounds(handle, "history-discard-warning", cx)?;
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-discard-warning"),
        cx,
    )
    .await?;
    // Default keyboard focus must be Cancel, never a destructive button.
    press(handle, "enter", cx).await?;
    pause(cx, 160).await;
    let cancelled = state(handle, cx)?;
    anyhow::ensure!(
        cancelled["palette"]["discardOpen"] == false
            && cancelled["palette"]["open"] == true
            && cancelled["closedRecord"] == closed["closedRecord"]
            && cancelled["savedClosedRecord"] == closed["savedClosedRecord"]
            && cancelled["allChats"] == closed["allChats"],
        "default Enter did not cancel without changes: {cancelled}"
    );
    click(handle, "history-discard-launch-0", cx)?;
    pause(cx, 100).await;
    press(handle, "escape", cx).await?;
    pause(cx, 100).await;
    let escaped = state(handle, cx)?;
    anyhow::ensure!(
        escaped["palette"]["discardOpen"] == false
            && escaped["palette"]["open"] == true
            && escaped["closedRecord"] == closed["closedRecord"],
        "Escape did not cancel discard safely: {escaped}"
    );
    click(handle, "history-discard-launch-0", cx)?;
    pause(cx, 100).await;
    click(handle, "history-discard-hide", cx)?;
    pause(cx, 160).await;
    let hidden = state(handle, cx)?;
    anyhow::ensure!(
        !has_chat(&hidden, "launch-0")
            && hidden["palette"]["discardOpen"] == false
            && hidden["closedRecord"] == closed["closedRecord"]
            && hidden["savedClosedRecord"] == closed["savedClosedRecord"]
            && hidden["allChats"] == closed["allChats"],
        "Hide did not remove only the default-list entry: {hidden}"
    );
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-hidden-from-list"),
        cx,
    )
    .await?;
    handle.update(cx, |shell, window, cx| {
        shell.fixture_command_palette(Some("Refine the launch"), window, cx)
    })?;
    pause(cx, 140).await;
    let found = state(handle, cx)?;
    anyhow::ensure!(
        has_chat(&found, "launch-0"),
        "hidden conversation cannot be found by searching: {found}"
    );
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-hidden-search-result"),
        cx,
    )
    .await?;
    click(handle, "history-restore-launch-0", cx)?;
    pause(cx, 200).await;
    let restored = state(handle, cx)?;
    anyhow::ensure!(
        restored["palette"]["open"] == false
            && restored["selectedChat"] == "launch-0"
            && restored["liveDraft"] == DRAFT
            && restored["closedRecord"].is_null(),
        "Restore button did not recover the same chat and draft: {restored}"
    );
    records.push(serde_json::json!({"discardCancelHideRestore":{"closed":closed,"prompt":prompt,"cancelled":cancelled,"hidden":hidden,"found":found,"restored":restored}}));

    handle.update(cx, |shell, _, cx| shell.fixture_chat_history_unsent(cx))?;
    click(handle, "titlebar-chat-history", cx)?;
    pause(cx, 140).await;
    let unsent = state(handle, cx)?;
    anyhow::ensure!(
        !unsent["unsentRecord"].is_null() && has_chat(&unsent, "fixture-unsent-history"),
        "synthetic unsent draft was not seeded: {unsent}"
    );
    click(handle, "history-discard-fixture-unsent-history", cx)?;
    pause(cx, 120).await;
    anyhow::ensure!(
        state(handle, cx)?["palette"]["discardOpen"] == true,
        "unsent discard confirmation did not open"
    );
    bounds(handle, "history-discard-warning", cx)?;
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-discard-unsent-warning"),
        cx,
    )
    .await?;
    click(handle, "history-discard-confirm", cx)?;
    pause(cx, 180).await;
    let discarded = state(handle, cx)?;
    anyhow::ensure!(
        discarded["unsentRecord"].is_null()
            && discarded["savedUnsentRecord"].is_null()
            && !has_chat(&discarded, "fixture-unsent-history")
            && discarded["palette"]["discardOpen"] == false
            && discarded["allChats"] == unsent["allChats"]
            && discarded["selectedChat"] == "launch-0"
            && discarded["liveDraft"] == DRAFT,
        "discarding an unsent record changed another conversation or failed: {discarded}"
    );
    records.push(serde_json::json!({"discardUnsent":{"before":unsent,"after":discarded}}));

    let (delete_id, query) = if tone == "dark" {
        ("backend-0", "request caching")
    } else {
        ("backend-2", "service docs")
    };
    handle.update(cx, |shell, window, cx| {
        shell.fixture_command_palette(Some(query), window, cx)
    })?;
    pause(cx, 160).await;
    let before_delete = state(handle, cx)?;
    anyhow::ensure!(
        has_chat(&before_delete, delete_id),
        "temporary saved-chat deletion target is unavailable: {before_delete}"
    );
    click(handle, &format!("history-discard-{delete_id}"), cx)?;
    pause(cx, 120).await;
    bounds(handle, "history-discard-warning", cx)?;
    capture_native(
        handle,
        output,
        &format!("chat-history-{tone}-delete-permanently-warning"),
        cx,
    )
    .await?;
    click(handle, "history-discard-confirm", cx)?;
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        pause(cx, 100).await;
        let current = state(handle, cx)?;
        if current["palette"]["discardOpen"] == false {
            break;
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "temporary engine did not confirm saved-chat deletion: {current}"
        );
    }
    let confirm = handle.update(cx, |shell, _, cx| {
        shell.fixture_chat_history_confirm_deletion(delete_id.into(), cx)
    })?;
    let timeout = cx.background_executor().timer(Duration::from_secs(5));
    let engine_chats = match futures::future::select(Box::pin(confirm), Box::pin(timeout)).await {
        futures::future::Either::Left((result, _)) => result.map_err(anyhow::Error::msg)?,
        futures::future::Either::Right(_) => anyhow::bail!(
            "temporary engine did not return its authoritative post-delete chat snapshot"
        ),
    };
    pause(cx, 100).await;
    let deleted = state(handle, cx)?;
    anyhow::ensure!(
        !engine_chats.iter().any(|id| id == delete_id) && !has_chat(&deleted, delete_id),
        "deleted chat remains in the engine or reconciled history: engine={engine_chats:?}, state={deleted}"
    );
    anyhow::ensure!(
        deleted["allChats"].as_array().unwrap().len() + 1
            == before_delete["allChats"].as_array().unwrap().len()
            && deleted["selectedChat"] == "launch-0"
            && deleted["liveDraft"] == DRAFT,
        "permanent deletion changed unrelated chats or the active draft: {deleted}"
    );
    capture_native(handle, output, &format!("chat-history-{tone}-deleted"), cx).await?;
    records.push(serde_json::json!({"deleteTemporarySavedChat":{"id":delete_id,"before":before_delete,"after":deleted,"authoritativeEngineChatIds":engine_chats,"projectionRefresh":"Fixture-only reconciliation from the initial real WatchChats snapshot; live production subscription delivery is not tested."}}));
    press(handle, "escape", cx).await?;
    Ok(records)
}

pub(super) async fn exercise(
    handle: WindowHandle<shell::Shell>,
    tone: &str,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let background = actions_only();
    let result = if background {
        async {
            handle.update(cx, |shell, window, cx| {
                window.resize(size(px(1200.0), px(760.0)));
                shell.fixture_chat_history_case("one-tab", true, false, window, cx);
            })?;
            pause(cx, 200).await;
            handle.update(cx, |shell, window, cx| {
                shell.fixture_chat_history_draft(DRAFT, window, cx)
            })?;
            pause(cx, 100).await;
            let prepared = state(handle, cx)?;
            anyhow::ensure!(
                prepared["selectedChat"] == "launch-0"
                    && prepared["currentKey"] == "launch-0"
                    && prepared["liveDraft"] == DRAFT,
                "background action fixture is not prepared: {prepared}"
            );
            exercise_actions(handle, tone, output, cx).await
        }
        .await
    } else {
        run(handle, tone, output, cx).await
    };
    let scope = if background {
        "Background native-window captures and production row/dialog pointer/key dispatch with synthetic temporary data. Close is targeted fixture setup; CmdW/CmdShiftT and OS shortcut routing are not covered by this actions-only run."
    } else {
        "Production Shell pointer/keyboard dispatch and native-window captures with synthetic temporary data. Global close requires the active fixture window; Shell-local keys use the explicit window dispatch tree. Actual OS shortcut routing is a separate check."
    };
    let mut checks = vec![
        "history title clock and no hint footer",
        "discard does not restore and Enter/Escape cancel safely",
        "Hide retains saved chat/draft and search finds it again",
        "Restore button recovers the same chat/draft",
        "unsent discard removes only its recovery record",
        "permanent deletion confirms through the temporary engine",
    ];
    if !background {
        checks.extend([
            "one history clock in expanded/collapsed sidebar",
            "single and expanded panels retain 42px shared header",
            "history opens without sidebar changes",
            "Escape closes history",
            "search across projects and archived chats",
            "CmdW/CmdShiftT restore same chat, session, panel and unsent draft",
        ]);
    }
    let report = match &result {
        Ok(cases) => serde_json::json!({
            "passed":true,
            "scope":scope,
            "actionsOnly":background,
            "checks":checks,
            "cases":cases,
        }),
        Err(error) => serde_json::json!({"passed":false,"error":format!("{error:#}")}),
    };
    std::fs::write(
        output.join(format!("chat-history-{tone}-result.json")),
        serde_json::to_vec_pretty(&report)?,
    )?;
    result.map(|_| ())
}
