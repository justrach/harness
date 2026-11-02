//! Production composer, synthetic drafts, isolated settings, no engine connection.
//! cargo run -p harness-ui --example composer-fixture --features appshots-fixture -- OUT_DIR
use gpui::{
    AppContext, Bounds, Context, Entity, Focusable, IntoElement, ParentElement, Render, Styled,
    Window, WindowBounds, WindowOptions, div, point, px, size,
};
use harness_theme::{AccentSelection, SurfacePreference};
use harness_ui::{app_menus, composer, history, icons, settings, state, theme, typography};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

struct ComposerFixture {
    composer: Entity<composer::Composer>,
}

impl Render for ComposerFixture {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx);
        div()
            .size_full()
            .bg(theme.bg)
            .font_family(theme.font_sans.clone())
            .text_color(theme.text)
            .flex()
            .flex_col()
            .justify_end()
            .pb(px(24.))
            .child(self.composer.clone())
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = Arc::new(Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_base::init(cx);
        let settings = settings::UiSettings::default();
        settings::init(settings.clone(), data.path(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(
            settings.ui_font_family, settings.ui_font_size,
            settings.terminal_font_family, settings.terminal_font_size,
            settings.code_font_family, settings.code_font_size, fonts, cx,
        );
        history::init(Default::default(), Default::default(), Default::default(), Default::default(), cx);
        app_menus::init(cx);
        composer::init(cx, settings.composer_send_behavior);
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                for (id, appearance) in [
                    ("codegraff-light", theme::Appearance::Light),
                    ("codegraff-dark", theme::Appearance::Dark),
                    ("catppuccin-mocha", theme::Appearance::Dark),
                ] {
                    for width in [840, 420] {
                        let window = cx.update(|cx| {
                            theme::Theme::install_selection(appearance, id, AccentSelection::ThemeDefault, SurfacePreference::Opaque, cx);
                            let state = cx.new(|_| {
                                let mut state = state::AppState::new();
                                state.selected_chat = Some("composer-preview".into());
                                state.chats = vec![serde_json::from_value(serde_json::json!({
                                    "id": "composer-preview", "deviceId": "fixture",
                                    "title": "Composer preview", "archived": false,
                                    "createdAt": "2026-01-01T00:00:00Z",
                                    "config": {"harness": "graff", "model": "gpt-6-sol", "reasoning": "high", "modelOptions": {}, "sandbox": "workspace-write"}
                                })).expect("synthetic chat")];
                                state.context_usage = Some(harness_proto::ContextUsage {
                                    tokens: Some(76_000),
                                    window: Some(200_000),
                                    savings: Some(harness_proto::ContextSavings {
                                        handle_bytes: 16_000,
                                        compacted_tokens: 8_000,
                                        cache_read_tokens: 24_000,
                                    }),
                                });
                                state.no_project = true;
                                state
                            });
                            cx.open_window(WindowOptions {
                                window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(40.), px(60.)), size(px(width as f32), px(400.))))),
                                titlebar: None,
                                ..Default::default()
                            }, |window, cx| {
                                cx.activate(true);
                                window.set_rem_size(px(16.));
                                window.activate_window();
                                let composer = cx.new(|cx| composer::Composer::new(state.clone(), cx));
                                composer.update(cx, |composer, cx| composer.set_available_width(width as f32, cx));
                                cx.new(|_| ComposerFixture { composer })
                            })
                        })?;
                        for (name, draft) in [
                            ("empty", ""),
                            ("compact", "Make the input feel calm"),
                            ("expanded", "Refine the composer’s spacing and focus state.\nKeep the controls quiet and the text easy to read."),
                            ("wrapped", "Refine the composer’s spacing and focus state. Keep the controls quiet and the text easy to read, even when a longer prompt wraps across several lines. Preserve keyboard navigation, selection, and input methods."),
                        ] {
                            window.update(cx, |root, window, cx| {
                                root.composer.update(cx, |composer, cx| composer.fixture_set_draft(draft, cx));
                                window.focus(&root.composer.focus_handle(cx), cx);
                            })?;
                            cx.background_executor().timer(Duration::from_millis(450)).await;
                            window.update(cx, |root, _, cx| {
                                root.composer.update(cx, |composer, cx| composer.fixture_reset_caret(cx));
                            })?;
                            let capture_window: gpui::AnyWindowHandle = window.into();
                            capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                                window.draw(cx).clear();
                                window.render_to_image()?.save(output.join(format!("{id}-{width}-{name}.png")))?;
                                Ok(())
                            })??;
                        }
                        if width == 840 && id.starts_with("codegraff") {
                            let capture_window: gpui::AnyWindowHandle = window.into();
                            capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                                window.blur();
                                window.draw(cx).clear();
                                window.render_to_image()?.save(output.join(format!("{id}-unfocused.png")))?;
                                Ok(())
                            })??;
                            window.update(cx, |root, window, cx| {
                                window.focus(&root.composer.focus_handle(cx), cx);
                            })?;
                            capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                                window.dispatch_event(gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                                    keystroke: gpui::Keystroke::parse("cmd-shift-left")?,
                                    is_held: false,
                                    prefer_character_input: false,
                                }), cx);
                                window.draw(cx).clear();
                                window.render_to_image()?.save(output.join(format!("{id}-selection.png")))?;
                                Ok(())
                            })??;
                            window.update(cx, |root, _, cx| {
                                root.composer.update(cx, |composer, cx| composer.fixture_set_draft("A caret that settles while you type.", cx));
                            })?;
                            cx.background_executor().timer(Duration::from_millis(650)).await;
                            capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                                window.draw(cx).clear();
                                window.render_to_image()?.save(output.join(format!("{id}-blink-off.png")))?;
                                harness_ui::motion::set_reduced_motion(cx, true);
                                window.refresh();
                                window.draw(cx).clear();
                                window.render_to_image()?.save(output.join(format!("{id}-reduced-motion.png")))?;
                                harness_ui::motion::set_reduced_motion(cx, false);
                                Ok(())
                            })??;
                        }
                        if id.starts_with("codegraff") {
                            let capture_window: gpui::AnyWindowHandle = window.into();
                            let (pickers, position) = window.read_with(cx, |root, cx| {
                                let composer = root.composer.read(cx);
                                (composer.pickers().clone(), composer.fixture_model_bounds().expect("model bounds").center())
                            })?;
                            // Exercise the actual footer hit targets, including
                            // the model menu after it moved out of the input.
                            capture_window.update(cx, |_, window, cx| {
                                window.dispatch_event(gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                    position: point(px(width as f32 - 45.), px(356.)),
                                    ..Default::default()
                                }), cx);
                            })?;
                            cx.background_executor().timer(Duration::from_millis(900)).await;
                            capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                                window.draw(cx).clear();
                                window.render_to_image()?.save(output.join(format!("{id}-{width}-context-details.png")))?;
                                Ok(())
                            })??;
                            capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                                window.dispatch_event(gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                    position, ..Default::default()
                                }), cx);
                                window.dispatch_event(gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                    button: gpui::MouseButton::Left, position, click_count: 1, ..Default::default()
                                }), cx);
                                window.dispatch_event(gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                    button: gpui::MouseButton::Left, position, click_count: 1, ..Default::default()
                                }), cx);
                                anyhow::ensure!(pickers.read(cx).is_open(), "footer model click must open the menu");
                                Ok(())
                            })??;
                            cx.background_executor().timer(Duration::from_millis(250)).await;
                            capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                                window.draw(cx).clear();
                                window.render_to_image()?.save(output.join(format!("{id}-{width}-model-menu.png")))?;
                                window.dispatch_event(gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                                    keystroke: gpui::Keystroke::parse("escape")?, is_held: false, prefer_character_input: false,
                                }), cx);
                                anyhow::ensure!(!pickers.read(cx).is_open(), "Escape must close the model menu");
                                Ok(())
                            })??;
                        }
                        window.update(cx, |_, window, _| window.remove_window())?;
                    }
                }
                Ok(())
            }.await;
            *result.lock().unwrap() = run.err();
            cx.update(|cx| cx.quit());
        }).detach();
    });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
