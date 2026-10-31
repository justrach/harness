//! Close-and-archive evidence with isolated, synthetic data: Settings →
//! Archived sessions, then the first ⌘W before a close default is chosen.
//!
//! `cargo run -p harness-ui --features appshots-fixture --example archive-choice-fixture -- <dir> [light|all-themes]`
//! Check the all-themes captures with `python3 scripts/check-archive-choice-themes.py <dir>`.
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{path::PathBuf, sync::Arc, time::Duration};

const CHAT: &str = "archive-choice-fixture";

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
    window.update(cx, |_, window, cx| {
        window.draw(cx).clear();
        window
            .render_to_image()?
            .save(directory.join(format!("{name}.png")))?;
        Ok(())
    })?
}

async fn capture_theme_matrix(
    window: gpui::WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
    output: &std::path::Path,
) -> anyhow::Result<()> {
    use harness_theme::{AccentPreset, AccentSelection, SurfacePreference, ThemeRegistry};

    let mut variants: Vec<_> = ThemeRegistry::builtin()
        .families
        .iter()
        .flat_map(|family| family.variants.clone())
        .collect();
    // Exercise the custom-theme runtime path without loading anyone's library.
    let custom: Vec<_> = harness_theme::Appearance::ALL
        .into_iter()
        .map(|appearance| {
            let mut variant = variants
                .iter()
                .find(|v| v.appearance == appearance)
                .unwrap()
                .clone();
            variant.id = format!("fixture-custom-{appearance:?}").to_lowercase();
            variant.family_id = "fixture-custom".into();
            variant.name = format!("Synthetic custom {appearance:?}");
            // Deliberately poor source contrast must be hardened at runtime.
            variant.colors.on_solid = variant.colors.solid;
            variant
        })
        .collect();
    harness_theme::replace_custom_families(vec![harness_theme::ThemeFamily {
        id: "fixture-custom".into(),
        name: "Synthetic custom".into(),
        variants: custom.clone(),
    }]);
    let builtin_count = variants.len();
    variants.extend(custom);
    let mut captures = Vec::new();
    let mut contrast_cases = 0;
    let mut minimum_contrast = f32::MAX;
    for variant in &variants {
        let ui_appearance = if variant.appearance.is_dark() {
            theme::Appearance::Dark
        } else {
            theme::Appearance::Light
        };
        for surface in SurfacePreference::ALL {
            for accent in std::iter::once(AccentSelection::ThemeDefault)
                .chain(AccentPreset::ALL.into_iter().map(AccentSelection::Preset))
            {
                let palette =
                    theme::Theme::for_selection(ui_appearance, &variant.id, accent, surface);
                let contrast = theme::contrast_ratio(palette.on_solid, palette.solid);
                anyhow::ensure!(
                    contrast >= 4.5,
                    "{} {surface:?} {accent:?}: button label contrast {contrast:.2}:1",
                    variant.id
                );
                minimum_contrast = minimum_contrast.min(contrast);
                contrast_cases += 1;
            }
            let fill = cx.update(|cx| {
                // Off-screen captures need the runtime palette, not native
                // appearance notifications or durable settings writes.
                theme::Theme::install_selection(
                    ui_appearance,
                    &variant.id,
                    AccentSelection::ThemeDefault,
                    surface,
                    cx,
                );
                cx.refresh_windows();
                let palette = theme::Theme::of(cx);
                assert_eq!(palette.variant_id.as_ref(), variant.id.as_str());
                let fill = palette.solid.to_rgb();
                [fill.r, fill.g, fill.b].map(|c| (c * 255.0).round() as u8)
            });
            pause(cx, 200).await;
            let name = format!("{}-{surface:?}", variant.id).to_lowercase();
            capture(window.into(), cx, output, &name)?;
            captures.push(serde_json::json!({
                "file": format!("{name}.png"),
                "theme": variant.name,
                "surface": format!("{surface:?}"),
                "fill": fill,
            }));
        }
    }
    let report = serde_json::json!({
        "builtin_variants": builtin_count,
        "synthetic_custom_variants": variants.len() - builtin_count,
        "contrast_cases": contrast_cases,
        "minimum_contrast": minimum_contrast,
        "captures": captures,
    });
    std::fs::write(
        output.join("theme-matrix.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!(
        "{} themes, {} rendered cases, {contrast_cases} contrast checks; minimum {minimum_contrast:.2}:1",
        variants.len(),
        captures.len()
    );
    Ok(())
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let mode = std::env::args().nth(2);
    let light = mode.as_deref() == Some("light");
    let all_themes = mode.as_deref() == Some("all-themes");
    let suffix = if light { "light" } else { "dark" };
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &temp.path().join("engine"),
            Arc::new(harness_engine::default_registry()),
            harness_proto::HarnessId::Mock,
            None,
        )
    })?;
    core.workspace
        .create_chat(CHAT, None, Some(&core.device_id), None, None)?;
    core.workspace.rename_chat(CHAT, "Tidy the changelog")?;
    let ipc_port = std::net::TcpListener::bind("127.0.0.1:0")?
        .local_addr()?
        .port();
    let _ipc = runtime.block_on(harness_engine::serve_ipc(ipc_port, core.rpc_service()))?;
    let data = temp.path().join("ui");
    std::fs::create_dir(&data)?;
    let boot = EngineBootConfig {
        data_dir: data.clone(),
        ipc_port,
        edge_url: String::new(),
        edge_token: None,
        org_id: None,
        codegraff_client_id: None,
        default_harness: harness_proto::HarnessId::Mock,
    };
    let engine = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
    let chats = core.workspace.read_chats()?;
    let device = core.device_id.clone();
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            // No saved choice: the first ⌘W asks for the close default.
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data.clone(), cx);
            let fonts = typography::register_fonts(cx);
            typography::init(
                settings.ui_font_family.clone(),
                settings.ui_font_size,
                settings.terminal_font_family.clone(),
                settings.terminal_font_size,
                settings.code_font_family.clone(),
                settings.code_font_size,
                fonts,
                cx,
            );
            theme_library::init(data.clone(), cx);
            appearance::init(
                if light {
                    appearance::AppearanceMode::Light
                } else {
                    appearance::AppearanceMode::Dark
                },
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            composer::init(cx, settings.composer_send_behavior);
            terminal::panel::init(cx);
            app_menus::init(cx);
            let state = cx.new(|_| {
                let mut s = state::AppState::new();
                s.fixture_attachment_engine(engine);
                s.connection = harness_proto::view::ConnectionStatus::Ready;
                s.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
                s.no_project = true;
                s.local_device_id = Some(device.clone());
                s.devices = vec![
                    serde_json::from_value(serde_json::json!({
                        "id": device, "name": "Studio", "platform": std::env::consts::OS,
                        "lastSeenAt": null
                    }))
                    .unwrap(),
                ];
                s.chats = chats;
                s.selected_chat = Some(CHAT.into());
                s.auto_selected = true;
                s.chats_synced = true;
                s.spaces_synced = true;
                s
            });
            let window = cx
                .open_window(
                    WindowOptions {
                        window_background: theme::Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(20.), px(40.)),
                            size(px(1100.), px(720.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx)),
                )
                .unwrap();
            cx.activate(true);
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    pause(cx, 1500).await;
                    window.update(cx, |shell, _, cx| shell.fixture_archived_settings(true, cx))?;
                    pause(cx, 900).await;
                    capture(
                        window.into(),
                        cx,
                        &output,
                        &format!("archive-settings-{suffix}"),
                    )?;
                    window.update(cx, |shell, _, cx| {
                        shell.fixture_archived_settings(false, cx)
                    })?;
                    pause(cx, 600).await;
                    capture(
                        window.into(),
                        cx,
                        &output,
                        &format!("archive-chat-{suffix}"),
                    )?;
                    // Exercise the ⌘W close path even without native app focus.
                    window.update(cx, |shell, window, cx| {
                        shell.fixture_first_chat_close(window, cx);
                    })?;
                    pause(cx, 900).await;
                    capture(
                        window.into(),
                        cx,
                        &output,
                        &format!("archive-cmd-w-{suffix}"),
                    )?;
                    if all_themes {
                        capture_theme_matrix(window, cx, &output).await?;
                    }
                    Ok(())
                }
                .await;
                *result.lock().unwrap() = run.err();
                let _ = window.update(cx, |_, w, _| w.remove_window());
                pause(cx, 100).await;
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
