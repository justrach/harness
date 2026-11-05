//! Synthetic model-error banner evidence with isolated data. No agent messages are sent.
//! cargo run -p harness-ui --features appshots-fixture --example error-banner-fixture -- /tmp/error-banner
//! Renders a failed turn as the one-line error banner (dark, light, narrow). With
//! `DETAILS_AT=x,y` / `RETRY_AT=x,y` (logical px) it also clicks Details and
//! Edit & retry, then checks that retry only restored the prompt.
use gpui::{
    AppContext, AsyncApp, Bounds, Modifiers, MouseButton, MouseDownEvent, MouseMoveEvent,
    MouseUpEvent, PlatformInput, WindowBounds, WindowOptions, point, px, size,
};
use std::{path::PathBuf, sync::Arc, time::Duration};
use harness_ui::*;

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}
fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    directory: &std::path::Path,
    name: &str,
) -> anyhow::Result<()> {
    window.update(cx, |_, w, cx| {
        w.draw(cx).clear();
        w.render_to_image()?
            .save(directory.join(format!("{name}.png")))?;
        Ok(())
    })?
}
fn click(window: gpui::AnyWindowHandle, cx: &mut AsyncApp, at: (f32, f32)) -> anyhow::Result<()> {
    let position = point(px(at.0), px(at.1));
    window.update(cx, |_, w, cx| {
        w.dispatch_event(
            PlatformInput::MouseMove(MouseMoveEvent {
                position,
                pressed_button: None,
                modifiers: Modifiers::default(),
            }),
            cx,
        );
        w.draw(cx).clear();
        w.dispatch_event(
            PlatformInput::MouseDown(MouseDownEvent {
                button: MouseButton::Left,
                position,
                modifiers: Modifiers::default(),
                click_count: 1,
                first_mouse: false,
            }),
            cx,
        );
        w.dispatch_event(
            PlatformInput::MouseUp(MouseUpEvent {
                button: MouseButton::Left,
                position,
                modifiers: Modifiers::default(),
                click_count: 1,
            }),
            cx,
        );
    })
}
fn coords(var: &str) -> Option<(f32, f32)> {
    let value = std::env::var(var).ok()?;
    let (x, y) = value.split_once(',')?;
    Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
}
fn port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(harness_engine::default_registry()),
            harness_proto::HarnessId::ClaudeCode,
            None,
        )
    })?;
    core.workspace.create_chat(
        "error-fixture",
        None,
        Some(&core.device_id),
        Some(harness_proto::ChatConfig {
            harness: harness_proto::HarnessId::Graff,
            model: Some("kimi/k2.6".into()),
            reasoning: None,
            model_options: Default::default(),
            sandbox: harness_proto::SandboxLevel::WorkspaceWrite,
        }),
        None,
    )?;
    core.workspace.rename_chat("error-fixture", "Launch copy")?;
    let ipc_port = port();
    let _ipc = runtime.block_on(harness_engine::serve_ipc(ipc_port, core.rpc_service()))?;
    let data = temp.path().join("ui");
    std::fs::create_dir(&data)?;
    let boot = state::EngineBootConfig {
        data_dir: data.clone(),
        ipc_port,
        edge_url: String::new(),
        edge_token: None,
        org_id: None,
        codegraff_client_id: None,
        default_harness: harness_proto::HarnessId::ClaudeCode,
    };
    let handle = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
    let chats = core.workspace.read_chats()?;
    let device = core.device_id.clone();
    let details_at = coords("DETAILS_AT");
    let retry_at = coords("RETRY_AT");

    let failure = Arc::new(std::sync::Mutex::new(None));
    let failure2 = failure.clone();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx); gpui_base::init(cx);
        let settings=settings::UiSettings::default(); settings::init(settings.clone(),data.clone(),cx);
        let fonts=typography::register_fonts(cx); typography::init(settings.ui_font_family.clone(), settings.ui_font_size, settings.terminal_font_family.clone(), settings.terminal_font_size, settings.code_font_family.clone(), settings.code_font_size, fonts, cx);
        theme_library::init(data.clone(),cx); appearance::init(appearance::AppearanceMode::Dark,settings.theme_selection,settings.accent,settings.surface,cx);
        history::init(settings.git_history_columns,settings.git_history_column_widths,settings.git_history_column_order,settings.git_history_author_display,cx);
        composer::init(cx,settings.composer_send_behavior); terminal::panel::init(cx); app_menus::init(cx);
        let state=cx.new(|_| { let mut s=state::AppState::new(); s.fixture_attachment_engine(handle); s.connection=harness_proto::view::ConnectionStatus::Ready; s.workspace_scope=Some(harness_proto::WorkspaceScope::Development); s.local_device_id=Some(device.clone()); s.devices=vec![serde_json::from_value(serde_json::json!({"id":device,"name":"This device","platform":std::env::consts::OS,"lastSeenAt":null})).unwrap()]; s.chats=chats; s.selected_chat=Some("error-fixture".into()); s.auto_selected=true; s.chats_synced=true; s.spaces_synced=true; s });
        let window=cx.open_window(WindowOptions {window_background:theme::Theme::of(cx).window_background_appearance(),window_bounds:Some(WindowBounds::Windowed(Bounds::new(gpui::point(px(20.),px(40.)),size(px(1100.),px(720.))))),..Default::default()},|_,cx|cx.new(|cx|shell::Shell::new(state.clone(),boot,cx))).unwrap();
        state.update(cx,|_,cx|cx.notify()); cx.activate(true);
        cx.spawn(async move |cx| {
            let run:anyhow::Result<()> = async {
                pause(cx,1200).await;
                state.update(cx,|s,cx| {s.receive_transcript_frame(harness_doc::TranscriptFrame::Reset {reset:serde_json::from_value(serde_json::json!([
                    {"id":"user","role":"user","parts":[{"id":"text","kind":"text","text":"Tighten the launch page hero copy to two lines."}],"createdAt":1788900000000_i64,"deviceId":device},
                    {"id":"assistant","role":"assistant","deviceId":device,"status":"aborted","createdAt":1788900001000_i64,"parts":[
                        {"id":"e1","kind":"error","message":"harness protocol error: session/prompt: api error (rate_limit_error rate_limit_exceeded): Codegraff is temporarily at capacity. Retry shortly. [cg_req_fixture0000] (code -32603)"}
                    ]}
                ])).unwrap()},cx).unwrap();cx.notify();});
                pause(cx,1500).await;
                capture(window.into(),cx,&output,"error-banner-dark-1100")?;
                cx.update(|cx|appearance::set_mode(appearance::AppearanceMode::Light,cx));pause(cx,600).await;
                capture(window.into(),cx,&output,"error-banner-light-1100")?;
                cx.update(|cx|appearance::set_mode(appearance::AppearanceMode::Dark,cx));pause(cx,400).await;
                window.update(cx,|_,w,_|w.resize(size(px(560.),px(720.))))?;pause(cx,800).await;
                capture(window.into(),cx,&output,"error-banner-dark-560")?;
                window.update(cx,|_,w,_|w.resize(size(px(1100.),px(720.))))?;pause(cx,800).await;
                let mut notes = vec!["Error banner fixture: synthetic chat on kimi/k2.6 with a rate-limit error. No real sessions, agents, or account data used.".to_string()];
                // Retry first: opening Details grows the bottom-pinned row.
                if let Some(at) = retry_at {
                    let before = state.read_with(cx,|s,_| s.transcript.len());
                    click(window.into(),cx,at)?;pause(cx,800).await;
                    capture(window.into(),cx,&output,"error-banner-retry-1100")?;
                    let after = state.read_with(cx,|s,_| s.transcript.len());
                    notes.push(format!("Clicked Edit & retry at {at:?}: transcript entries {before} -> {after} (nothing sent when equal)."));
                }
                if let Some(at) = details_at {
                    click(window.into(),cx,at)?;pause(cx,600).await;
                    capture(window.into(),cx,&output,"error-banner-details-1100")?;
                    notes.push(format!("Clicked Details at {at:?}."));
                }
                std::fs::write(output.join("result.txt"),notes.join("\n")+"\n")?;
                Ok(())
            }.await;
            if let Err(error)=run {eprintln!("Error banner fixture failed: {error:#}");*failure2.lock().unwrap()=Some(format!("{error:#}"));}
            let _=window.update(cx,|_,w,_|w.remove_window());pause(cx,100).await;cx.update(|cx|cx.quit());
        }).detach();
    });
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
