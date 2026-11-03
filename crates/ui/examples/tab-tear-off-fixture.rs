//! Native tab transfer regression evidence with synthetic data and a loopback page.
//! cargo run -p harness-ui --example tab-tear-off-fixture \
//!   --features appshots-fixture,browser-fixture -- /tmp/harness-tab-tear-off
//! HARNESS_TAB_TEAR_OFF_HOLD=1 keeps the verified windows open for pointer review.
//! HARNESS_TAB_TEAR_OFF_DRAG_VISUALS=1 exercises production pointer dispatch and previews.
//! HARNESS_TAB_REJOIN_FIXTURE=1 exercises drops into existing empty/populated windows.
#[cfg(target_os = "macos")]
#[path = "tab-tear-off-fixture/drag_preview.rs"]
mod drag_preview;
#[cfg(target_os = "macos")]
#[path = "tab-tear-off-fixture/rejoin.rs"]
mod rejoin;

use gpui::{AppContext, AsyncApp, Bounds, WindowHandle, point, px, size};
use harness_ui::*;
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

fn manual_mode() -> bool {
    std::env::var_os("HARNESS_TAB_TEAR_OFF_MANUAL").is_some()
        || std::env::args().any(|arg| arg == "--manual")
}

fn checkpoint(output: &Path, phase: &str) -> anyhow::Result<()> {
    std::fs::write(
        output.join("fixture-progress.json"),
        serde_json::to_string_pretty(&serde_json::json!({ "phase": phase }))?,
    )?;
    Ok(())
}

fn report_failure(output: &Path, error: &str) {
    let progress = std::fs::read(output.join("fixture-progress.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
    eprintln!("native tab tear-off fixture failed: {error}");
    tracing::error!(%error, ?progress, "native tab tear-off fixture failed");
    let result = serde_json::json!({
        "passed": false,
        "error": error,
        "lastProgress": progress,
    });
    for (name, value) in [
        ("result.json", result),
        (
            "fixture-progress.json",
            serde_json::json!({
                "phase": "failed", "error": error, "lastProgress": progress
            }),
        ),
    ] {
        let write = serde_json::to_vec_pretty(&value)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| {
                std::fs::write(output.join(name), bytes).map_err(anyhow::Error::from)
            });
        if let Err(write_error) = write {
            eprintln!("could not write fixture {name}: {write_error:#}");
        }
    }
    let _ = std::io::stderr().flush();
}

async fn wait_title(
    page: &gpui::Entity<browser::BrowserSurface>,
    expected: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    loop {
        let state = page.read_with(cx, |page, _| page.page.clone());
        anyhow::ensure!(state.error.is_none(), "browser failed: {:?}", state.error);
        anyhow::ensure!(!state.title.starts_with("FAIL:"), "{}", state.title);
        if state.title == expected {
            return Ok(());
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "expected {expected:?}; got {:?}",
            state.title
        );
        pause(cx, 40).await;
    }
}

async fn capture(
    window: WindowHandle<shell::Shell>,
    output: &Path,
    name: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    capture_window(window.into(), output, name, cx).await
}

async fn capture_window(
    handle: gpui::AnyWindowHandle,
    output: &Path,
    name: &str,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    let path = output.join(format!("{name}.png"));
    #[cfg(target_os = "macos")]
    {
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        loop {
            let native_id = handle.update(cx, |_, window, cx| -> anyhow::Result<_> {
                use raw_window_handle::{HasWindowHandle as _, RawWindowHandle};
                window.draw(cx).clear();
                let RawWindowHandle::AppKit(handle) = window.window_handle()?.as_raw() else {
                    anyhow::bail!("expected a native AppKit window");
                };
                let view = unsafe { &*handle.ns_view.as_ptr().cast::<objc2_app_kit::NSView>() };
                Ok(view.window().and_then(|native| {
                    (native.isVisible() && native.windowNumber() > 0)
                        .then(|| native.windowNumber().to_string())
                }))
            })??;
            // Let AppKit process presentation while WindowServer captures;
            // never keep the GPUI window leased across the native command.
            let error = if let Some(native_id) = native_id {
                let capture_path = path.clone();
                let result = cx
                    .background_executor()
                    .spawn(async move {
                        std::process::Command::new("/usr/sbin/screencapture")
                            .args(["-x", "-o", "-l", &native_id])
                            .arg(capture_path)
                            .output()
                    })
                    .await;
                match result {
                    Ok(result) if result.status.success() => return Ok(()),
                    Ok(result) => String::from_utf8_lossy(&result.stderr).trim().to_owned(),
                    Err(error) => error.to_string(),
                }
            } else {
                "native window is not visible yet".into()
            };
            anyhow::ensure!(
                std::time::Instant::now() < deadline,
                "native screenshot {name:?} failed after presentation retries: {error}"
            );
            pause(cx, 100).await;
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        handle.update(cx, |_, window, cx| -> anyhow::Result<()> {
            window.draw(cx).clear();
            window.render_to_image()?.save(&path)?;
            Ok(())
        })??;
        Ok(())
    }
}

fn serve_page() -> anyhow::Result<String> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let origin = format!("http://{}", listener.local_addr()?);
    std::thread::spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
            let mut request = [0; 4096];
            let _ = stream.read(&mut request);
            let body = r#"<!doctype html><meta charset=utf-8><title>Transfer ready</title>
<style>body{margin:0;padding:48px;background:#f5f1e8;color:#2d3e35;font:16px/1.6 system-ui}h1{font:44px Georgia}input{font:inherit;padding:12px;width:min(340px,70vw);border:1px solid #a6afa0;border-radius:8px}.space{height:1500px}main{position:sticky;top:24px}</style>
<main><h1>Keep your place.</h1><p>This page stays alive when its tab moves.</p>
<label>Unsubmitted notes<br><input id=notes placeholder='Type a review note'></label>
</main><div class=space></div><p>Scroll position checkpoint</p>"#;
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
        }
    });
    Ok(origin)
}

async fn exercise(
    source: WindowHandle<shell::Shell>,
    runtime_state: gpui::Entity<state::AppState>,
    boot: EngineBootConfig,
    origin: String,
    output: &Path,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    checkpoint(output, "preparing-source")?;
    pause(cx, 700).await;
    let (panel, tab, page) = source.update(cx, |shell, window, cx| {
        shell.fixture_tear_off_prepare(origin, window, cx)
    })?;
    wait_title(&page, "Transfer ready", cx).await?;
    page.update(cx, |page, _| page.fixture_eval(
        "window.transferToken='same-live-page';document.querySelector('#notes').value='An unsaved review note';document.querySelector('#notes').focus();history.pushState({transfer:true},'', '#checkpoint');window.scrollTo(0,480);document.title='Transfer seeded';"
    ));
    wait_title(&page, "Transfer seeded", cx).await?;
    #[cfg(target_os = "macos")]
    page.read_with(cx, |page, _| page.fixture_focus());
    #[cfg(target_os = "macos")]
    let native_identity = page.read_with(cx, |page, _| page.fixture_native_identity());
    #[cfg(target_os = "macos")]
    anyhow::ensure!(native_identity.is_some(), "browser has no native page");
    let manual_rejoin = std::env::var_os("HARNESS_TAB_REJOIN_MANUAL").is_some();
    if manual_mode() && manual_rejoin {
        source.update(cx, |shell, _, cx| shell.fixture_rejoin_browser_only(cx))?;
    }
    if manual_mode() {
        let status = source.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
        std::fs::write(
            output.join("manual-ready.json"),
            serde_json::to_string_pretty(&serde_json::json!({
                "ready": true, "panel": panel, "browserTabIndex": if manual_rejoin { 0 } else { tab }, "source": status
            }))?,
        )?;
        checkpoint(output, "manual-ready")?;
        #[cfg(target_os = "macos")]
        if manual_rejoin {
            // Keep the original visible on a laptop display. This is fixture
            // arrangement only; the pointer still performs the actual move.
            cx.spawn(async move |cx| {
                for _ in 0..600 {
                    let detached = cx.update(|cx| {
                        cx.windows()
                            .into_iter()
                            .filter_map(|handle| handle.downcast::<shell::Shell>())
                            .find(|handle| handle.window_id() != source.window_id())
                    });
                    if let Some(detached) = detached {
                        let native = gpui::AnyWindowHandle::from(detached)
                            .update(cx, |_, window, _| {
                                use raw_window_handle::{HasWindowHandle, RawWindowHandle};
                                let RawWindowHandle::AppKit(handle) =
                                    HasWindowHandle::window_handle(window).ok()?.as_raw()
                                else {
                                    return None;
                                };
                                let view = unsafe {
                                    &*handle.ns_view.as_ptr().cast::<objc2_app_kit::NSView>()
                                };
                                view.window()
                            })
                            .ok()
                            .flatten();
                        // AppKit resize callbacks run outside the GPUI lease.
                        if let Some(native) = native {
                            native.setContentSize(objc2_foundation::NSSize::new(700.0, 650.0));
                        }
                        break;
                    }
                    pause(cx, 100).await;
                }
            })
            .detach();
        }
        return Ok(());
    }
    if std::env::var_os("HARNESS_TAB_REJOIN_FIXTURE").is_some() {
        #[cfg(target_os = "macos")]
        return rejoin::exercise(source, page, output, cx).await;
        #[cfg(not(target_os = "macos"))]
        anyhow::bail!("native rejoin evidence currently requires macOS");
    }
    capture(source, output, "before-source", cx).await?;
    if std::env::var_os("HARNESS_TAB_TEAR_OFF_DRAG_VISUALS").is_some() {
        #[cfg(target_os = "macos")]
        return drag_preview::exercise(source, panel, page, output, cx).await;
        #[cfg(not(target_os = "macos"))]
        anyhow::bail!("native drag preview evidence currently requires macOS");
    }
    let before_error = source.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    let rejected = source.update(cx, |shell, window, cx| {
        shell.fixture_detach_panel_tab(panel, usize::MAX, window, cx)
    })?;
    anyhow::ensure!(
        rejected.is_err(),
        "invalid destination unexpectedly moved a tab"
    );
    anyhow::ensure!(
        source.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))? == before_error,
        "rejected transfer changed the source"
    );
    let destination = source
        .update(cx, |shell, window, cx| {
            shell.fixture_detach_panel_tab(panel, tab, window, cx)
        })?
        .map_err(anyhow::Error::msg)?;
    checkpoint(output, "browser-transferred")?;
    pause(cx, 450).await;
    let adopted = destination
        .read_with(cx, |shell, _| shell.fixture_browser_entity())?
        .ok_or_else(|| anyhow::anyhow!("destination browser missing"))?;
    anyhow::ensure!(
        page.entity_id() == adopted.entity_id(),
        "browser entity was recreated"
    );
    #[cfg(target_os = "macos")]
    anyhow::ensure!(
        adopted.read_with(cx, |page, _| page.fixture_native_identity()) == native_identity,
        "native browser page was recreated"
    );
    #[cfg(target_os = "macos")]
    anyhow::ensure!(
        adopted.read_with(cx, |page, _| page.fixture_focused()),
        "transferred native page lost keyboard focus"
    );
    adopted.update(cx, |page, _| page.fixture_eval(
        "document.title=(window.transferToken==='same-live-page'&&document.querySelector('#notes').value==='An unsaved review note'&&document.activeElement?.id==='notes'&&window.scrollY>200&&history.state?.transfer)?'PASS: live state':'FAIL: state lost during transfer';"
    ));
    wait_title(&adopted, "PASS: live state", cx).await?;
    source.update(cx, |shell, window, cx| {
        shell.fixture_transfer_select_chat("fixture-b", window, cx)
    })?;
    let source_state = source.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    anyhow::ensure!(
        source_state["selectedChat"] == "fixture-b",
        "source selection did not change independently"
    );
    anyhow::ensure!(
        source_state["draft"] == "Keep this unsent transfer draft",
        "browser transfer changed chat draft"
    );
    anyhow::ensure!(
        source_state["browsers"] == 0,
        "source retained moved browser"
    );
    adopted.update(cx, |page, _| page.fixture_history(false));
    pause(cx, 200).await;
    adopted.update(cx, |page, _| page.fixture_eval(
        "document.title=(!history.state?.transfer&&window.transferToken==='same-live-page'&&document.querySelector('#notes').value==='An unsaved review note')?'PASS: history retained':'FAIL: history lost';"
    ));
    wait_title(&adopted, "PASS: history retained", cx).await?;
    capture(source, output, "after-source", cx).await?;
    capture(destination, output, "after-browser-window", cx).await?;
    let chat_window = source
        .update(cx, |shell, window, cx| {
            shell.fixture_detach_panel_tab(panel, 0, window, cx)
        })?
        .map_err(anyhow::Error::msg)?;
    pause(cx, 300).await;
    let chat = chat_window.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx))?;
    anyhow::ensure!(
        chat["draft"] == "Keep this unsent transfer draft",
        "chat transfer lost draft"
    );
    anyhow::ensure!(
        chat["attachmentBytes"] == 29,
        "chat transfer lost attachment bytes"
    );
    capture(chat_window, output, "after-chat-window", cx).await?;
    checkpoint(output, "chat-transferred")?;
    let source_id = source_state["windowId"].as_str().unwrap().to_owned();
    source.update(cx, |shell, window, cx| -> anyhow::Result<()> {
        anyhow::ensure!(
            shell.prepare_window_close(cx),
            "synthetic source close was unexpectedly blocked"
        );
        window.remove_window();
        Ok(())
    })??;
    pause(cx, 150).await;
    let source_closed = cx.update(|cx| {
        !settings::current(cx)
            .restorable_workspace_windows()
            .iter()
            .any(|record| record.id == source_id)
    });
    anyhow::ensure!(
        source_closed,
        "closed source retained a canonical window record"
    );
    adopted.update(cx, |page, _| page.fixture_eval(
        "document.title=(window.transferToken==='same-live-page'&&document.querySelector('#notes').value==='An unsaved review note')?'PASS: source closed':'FAIL: source close lost live page';"
    ));
    wait_title(&adopted, "PASS: source closed", cx).await?;
    capture(destination, output, "browser-after-source-close", cx).await?;
    checkpoint(output, "source-closed")?;

    let browser_record =
        destination.update(cx, |shell, _, cx| shell.fixture_transfer_save_record(cx))?;
    let chat_record =
        chat_window.update(cx, |shell, _, cx| shell.fixture_transfer_save_record(cx))?;
    anyhow::ensure!(
        browser_record.id != chat_record.id,
        "independent windows share an identity"
    );
    anyhow::ensure!(
        browser_record.chat_tabs[0].id == chat_record.chat_tabs[0].id,
        "detachment changed workspace session identity"
    );
    anyhow::ensure!(
        browser_record.chat_drafts.is_empty(),
        "browser window persisted a draft owned by the moved chat"
    );
    let saved_chat_draft = chat_record
        .chat_drafts
        .get("fixture-a")
        .ok_or_else(|| anyhow::anyhow!("moved chat has no durable draft descriptor"))?;
    anyhow::ensure!(
        saved_chat_draft.input.text == "Keep this unsent transfer draft"
            && saved_chat_draft.input.attachments.len() == 1,
        "moved chat persisted an incomplete draft descriptor"
    );
    cx.update(|cx| -> anyhow::Result<()> {
        settings::flush(cx);
        settings::current(cx).save(output)?;
        Ok(())
    })?;
    let persisted = settings::UiSettings::load(output).restorable_workspace_windows();
    anyhow::ensure!(
        persisted.len() == 2,
        "saved settings must contain exactly the two destination windows"
    );
    checkpoint(output, "descriptors-saved")?;
    let restored = cx.update(|cx| -> anyhow::Result<Vec<WindowHandle<shell::Shell>>> {
        let mut restored = Vec::new();
        // Keep a native window alive throughout descriptor restoration. This
        // exercises the production close/create path without ending the app's
        // event loop between the final close and the subsequent open.
        for (handle, id) in [
            (destination, &browser_record.id),
            (chat_window, &chat_record.id),
        ] {
            let record = persisted
                .iter()
                .find(|record| &record.id == id)
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("persisted window {id:?} missing"))?;
            handle.update(cx, |shell, window, cx| -> anyhow::Result<()> {
                anyhow::ensure!(
                    shell.prepare_window_close(cx),
                    "synthetic destination close blocked"
                );
                window.remove_window();
                Ok(())
            })??;
            let state = shell::Shell::fixture_fork_window_state(&runtime_state, cx);
            restored.push(
                shell::Shell::fixture_open_workspace_window(
                    state.clone(),
                    boot.clone(),
                    record,
                    cx,
                )
                .map_err(anyhow::Error::msg)?,
            );
            // This fixture has no engine/watch tasks. Publish the synthetic
            // Ready catalog frame that production receives from those watches
            // so the new Shell can run its ordinary boot navigation restore.
            state.update(cx, |_, cx| cx.notify());
        }
        Ok(restored)
    })?;
    checkpoint(output, "descriptors-opened")?;
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let restored_status = loop {
        let statuses = restored
            .iter()
            .map(|window| window.read_with(cx, |shell, cx| shell.fixture_transfer_status(cx)))
            .collect::<Result<Vec<_>, _>>()?;
        let sessions_ready = statuses.iter().all(|status| {
            status["sessionId"]
                .as_str()
                .is_some_and(|id| !id.is_empty())
        });
        if sessions_ready
            && statuses
                .iter()
                .any(|status| status["selectedTabKind"] == "chat")
            && statuses
                .iter()
                .any(|status| status["selectedTabKind"] == "browser" && status["browsers"] == 1)
        {
            break statuses;
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "restored session layouts did not become ready: {statuses:?}"
        );
        pause(cx, 40).await;
    };
    checkpoint(output, "session-layouts-restored")?;
    let restored_chat = restored_status
        .iter()
        .find(|status| status["selectedTabKind"] == "chat")
        .ok_or_else(|| {
            anyhow::anyhow!("restored selected chat tab missing: {restored_status:?}")
        })?;
    anyhow::ensure!(
        restored_chat["draft"] == "Keep this unsent transfer draft",
        "descriptor restore lost the moved chat draft"
    );
    anyhow::ensure!(
        restored_chat["attachmentBytes"] == 29,
        "descriptor restore lost draft attachment bytes"
    );
    anyhow::ensure!(
        restored_status
            .iter()
            .any(|status| status["selectedTabKind"] == "browser"),
        "restored selected browser tab missing"
    );
    // Restoration can finish in the state observer before AppKit has ordered
    // the new windows on screen. Let its queued presentation finish before
    // asking WindowServer for the native screenshots.
    pause(cx, 200).await;
    for (index, window) in restored.into_iter().enumerate() {
        capture(window, output, &format!("restored-window-{index}"), cx).await?;
    }
    std::fs::write(
        output.join("result.json"),
        serde_json::to_string_pretty(&serde_json::json!({
            "passed": true,
            "checks": ["same browser entity", "same native page", "JS object", "unsubmitted form", "scroll", "history", "independent source selection", "draft and attachment adoption", "invalid transfer rollback", "native events after source close", "closed-source record removed", "two-window descriptor restoration"],
            "restoreScope": "Restoration recreates descriptors; live JS preservation is checked only during transfer.",
            "source": source_state,
            "chat": chat,
            "restored": restored_status
        }))?,
    )?;
    checkpoint(output, "complete")?;
    Ok(())
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(
        std::env::args()
            .skip(1)
            .find(|arg| arg != "--manual")
            .or_else(|| std::env::var("HARNESS_TAB_TEAR_OFF_OUTPUT").ok())
            .unwrap_or_else(|| "/tmp/harness-tab-tear-off".into()),
    );
    std::fs::create_dir_all(&output)?;
    for artifact in ["result.json", "manual-ready.json", "fixture-progress.json"] {
        let path = output.join(artifact);
        if path.exists() {
            std::fs::remove_file(path)?;
        }
    }
    checkpoint(&output, "starting")?;
    let result_output = output.clone();
    let storage = tempfile::tempdir()?;
    let data = storage.path().to_path_buf();
    let origin = serve_page()?;
    let completion = Arc::new(Mutex::new(None));
    let outcome = completion.clone();
    gpui_platform::application().with_quit_mode(gpui::QuitMode::Explicit).with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx);
        gpui_base::init(cx);
        let mut settings = settings::UiSettings::default();
        if std::env::var("HARNESS_FIXTURE_THEME").as_deref() == Ok("warm") {
            settings.theme_selection.light = "warm-harp-light".into();
            settings.theme_selection.dark = "warm-harp-dark".into();
        }
        if std::env::var("HARNESS_FIXTURE_THEME").as_deref() == Ok("dracula") {
            settings.theme_selection.dark = "dracula".into();
        }
        settings.reduce_motion = if std::env::var_os("HARNESS_FIXTURE_REDUCED_MOTION").is_some() {
            motion::ReduceMotion::On
        } else {
            motion::ReduceMotion::System
        };
        settings::init(settings.clone(), data.clone(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(settings.ui_font_family.clone(), settings.ui_font_size, settings.terminal_font_family.clone(), settings.terminal_font_size, settings.code_font_family.clone(), settings.code_font_size, fonts, cx);
        theme_library::init(data.clone(), cx);
        let appearance = if std::env::var("HARNESS_FIXTURE_TONE").as_deref() == Ok("light") { appearance::AppearanceMode::Light } else { appearance::AppearanceMode::Dark };
        appearance::init(appearance, settings.theme_selection, settings.accent, settings.surface, cx);
        history::init(settings.git_history_columns, settings.git_history_column_widths, settings.git_history_column_order, settings.git_history_author_display, cx);
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);
        let state = cx.new(|_| {
            let mut state = state::AppState::new();
            state.connection = harness_proto::view::ConnectionStatus::Ready;
            state.workspace_scope = Some(harness_proto::WorkspaceScope::Local);
            state.local_device_id = Some("fixture-device".into());
            state.selected_chat = Some("fixture-a".into());
            state.auto_selected = true;
            state.chats_synced = true;
            state.spaces_synced = true;
            state.chats = ["fixture-a", "fixture-b"].into_iter().map(|id| serde_json::from_value(serde_json::json!({
                "id":id,"deviceId":"fixture-device","title":if id == "fixture-a" {"Review the transfer"} else {"Plan the next step"},"archived":false,"createdAt":"2026-10-31T00:00:00Z"
            })).unwrap()).collect();
            state
        });
        let boot = EngineBootConfig { data_dir: data, ipc_port: 0, edge_url: String::new(), edge_token: None, org_id: None, codegraff_client_id: None, default_harness: HarnessId::Mock };
        let width=std::env::var("HARNESS_FIXTURE_WIDTH").ok().and_then(|value|value.parse::<f32>().ok()).unwrap_or(1200.0);
        let height=std::env::var("HARNESS_FIXTURE_HEIGHT").ok().and_then(|value|value.parse::<f32>().ok()).unwrap_or(760.0);
        let record = settings::SavedWorkspaceWindow {
            id: "fixture-original-window".into(),
            last_chat_id: Some("fixture-a".into()),
            geometry: Some(settings::WindowGeometry::from_bounds(Bounds::new(point(px(80.),px(80.)),size(px(width),px(height))))),
            ..Default::default()
        };
        let source = shell::Shell::fixture_open_workspace_window(state.clone(), boot.clone(), record, cx).unwrap();
        state.update(cx, |_,cx| cx.notify());
        cx.set_menus(app_menus::app_menus());
        cx.activate(true);
        cx.spawn(async move |cx| {
            let result = exercise(source, state, boot, origin, &output, cx)
                .await
                .map_err(|error| format!("{error:#}"));
            if let Err(error) = &result {
                // AppKit's terminate routine can exit the process directly;
                // code after Application::run is not an error-reporting path.
                report_failure(&output, error);
                *completion.lock().unwrap() = Some(Err(error.clone()));
                std::process::exit(1);
            }
            *completion.lock().unwrap() = Some(result);
            if std::env::var_os("HARNESS_TAB_TEAR_OFF_HOLD").is_none() && !manual_mode() {
                cx.update(|cx| cx.quit());
            }
        }).detach();
    });
    let result = outcome.lock().unwrap().take().unwrap_or_else(|| {
        Err(
            "application exited before the native fixture completed; inspect fixture-progress.json"
                .into(),
        )
    });
    if let Err(error) = result {
        report_failure(&result_output, &error);
        anyhow::bail!(error);
    }
    Ok(())
}
