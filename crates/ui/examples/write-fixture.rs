//! The Write page beside the composer it opens from, on synthetic chats with
//! isolated settings and no engine connection.
//! cargo run -p harness-ui --example write-fixture --features appshots-fixture -- OUT_DIR
use gpui::{
    AppContext, Bounds, Context, Entity, Focusable, IntoElement, ParentElement, Render, Styled,
    Window, WindowBounds, WindowOptions, div, point, prelude::FluentBuilder, px, size,
};
use harness_theme::{AccentSelection, SurfacePreference};
use harness_ui::{app_menus, composer, history, icons, settings, state, theme, typography};
use std::{path::PathBuf, time::Duration};

const DRAFT: &str = "# Renderer notes\n\nOkay so before you go further, a few thoughts on the renderer. I think the frame pacing should follow the audio clock, not the display.\n\n## Keep it under 30s\n\n- Cap the reel at `30s`, cut the intro to 2s\n- **Never** re-encode frames we already have, even when the cache looks cold\n- Reuse the hotkey from `main.zig`\n\n> Open question: should the offscreen renderer share the *same* clock?\n\n```\nlet frame = clock.next();\n```\n";

struct WriteFixture {
    composer: Entity<composer::Composer>,
}

impl Render for WriteFixture {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx).clone();
        let page = self.composer.read(cx).write_open().then(|| {
            self.composer.update(cx, |composer, cx| {
                composer.render_write_page(12., window, cx)
            })
        });
        let open = page.is_some();
        let bubble = div()
            .self_end()
            .max_w(px(420.))
            .px(px(14.))
            .py(px(10.))
            .rounded(px(14.))
            .bg(theme.surface_raised)
            .border_1()
            .border_color(theme.border)
            .text_size(px(14.))
            .line_height(px(21.))
            .child("Can you write that out as an HTML file and open it up for me to see?");
        let reply = div()
            .text_size(px(14.))
            .line_height(px(22.))
            .text_color(theme.text)
            .child("Picking up the build: next come the app index, the UI, the hotkey, and an offscreen video renderer. I'm checking how the renderer paces its frames first.");
        div()
            .size_full()
            .bg(theme.bg)
            .font_family(theme.font_sans.clone())
            .text_color(theme.text)
            .flex()
            .flex_col()
            .children(page)
            .when(!open, |el| {
                el.child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .w_full()
                        .max_w(px(760.))
                        .mx_auto()
                        .px(px(32.))
                        .pt(px(28.))
                        .flex()
                        .flex_col()
                        .gap(px(18.))
                        .child(bubble)
                        .child(reply),
                )
                .child(div().pb(px(24.)).child(self.composer.clone()))
            })
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
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
        let serif = composer::WriteFace { serif: true }.family(cx);
        eprintln!("write page serif family: {serif}");
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                for (id, appearance, width) in [
                    ("codegraff-light", theme::Appearance::Light, 960),
                    ("codegraff-dark", theme::Appearance::Dark, 960),
                    ("codegraff-light", theme::Appearance::Light, 560),
                ] {
                    let window = cx.update(|cx| {
                        theme::Theme::install_selection(appearance, id, AccentSelection::ThemeDefault, SurfacePreference::Opaque, cx);
                        let state = cx.new(|_| {
                            let mut state = state::AppState::new();
                            state.selected_chat = Some("write-preview".into());
                            state.chats = vec![serde_json::from_value(serde_json::json!({
                                "id": "write-preview", "deviceId": "fixture",
                                "title": "Reel renderer", "archived": false,
                                "createdAt": "2026-01-01T00:00:00Z",
                                "config": {"harness": "graff", "model": "gpt-6-sol", "reasoning": "high", "modelOptions": {}, "sandbox": "workspace-write"}
                            })).expect("synthetic chat")];
                            state.no_project = true;
                            state
                        });
                        cx.open_window(WindowOptions {
                            window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(40.), px(60.)), size(px(width as f32), px(720.))))),
                            titlebar: None,
                            ..Default::default()
                        }, |window, cx| {
                            cx.activate(true);
                            window.set_rem_size(px(16.));
                            window.activate_window();
                            let composer = cx.new(|cx| composer::Composer::new(state.clone(), cx));
                            composer.update(cx, |composer, cx| composer.set_available_width(width.min(760) as f32, cx));
                            cx.new(|_| WriteFixture { composer })
                        })
                    })?;
                    let capture = |name: String, cx: &mut gpui::AsyncApp| -> anyhow::Result<()> {
                        let capture_window: gpui::AnyWindowHandle = window.into();
                        capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.draw(cx).clear();
                            window.render_to_image()?.save(output.join(name))?;
                            Ok(())
                        })?
                    };
                    let mode = if appearance == theme::Appearance::Light { "light" } else { "dark" };
                    window.update(cx, |root, window, cx| {
                        root.composer.update(cx, |composer, cx| composer.fixture_set_draft(DRAFT, cx));
                        window.focus(&root.composer.focus_handle(cx), cx);
                    })?;
                    cx.background_executor().timer(Duration::from_millis(500)).await;
                    window.update(cx, |root, _, cx| {
                        root.composer.update(cx, |composer, cx| composer.fixture_reset_caret(cx));
                    })?;
                    capture(format!("before-{mode}-{width}.png"), cx)?;

                    window.update(cx, |root, _, cx| {
                        root.composer.update(cx, |composer, cx| composer.open_write(cx));
                    })?;
                    cx.background_executor().timer(Duration::from_millis(300)).await;
                    window.update(cx, |root, _, cx| {
                        root.composer.update(cx, |composer, cx| composer.fixture_reset_caret(cx));
                    })?;
                    capture(format!("after-{mode}-{width}.png"), cx)?;

                    if width == 960 && mode == "light" {
                        window.update(cx, |root, _, cx| {
                            root.composer.update(cx, |composer, cx| composer.fixture_toggle_write_face(cx));
                        })?;
                        cx.background_executor().timer(Duration::from_millis(200)).await;
                        capture(format!("after-{mode}-{width}-sans.png"), cx)?;
                        window.update(cx, |root, _, cx| {
                            root.composer.update(cx, |composer, cx| composer.fixture_toggle_write_face(cx));
                        })?;
                        // Done: back in the composer with the same draft.
                        window.update(cx, |root, _, cx| {
                            root.composer.update(cx, |composer, cx| composer.close_write(cx));
                        })?;
                        cx.background_executor().timer(Duration::from_millis(300)).await;
                        capture(format!("done-{mode}-{width}.png"), cx)?;
                    }
                    window.update(cx, |_, window, _| window.remove_window())?;
                }
                Ok(())
            }
            .await;
            if let Err(error) = run {
                eprintln!("write fixture failed: {error:#}");
                std::process::exit(1);
            }
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
    Ok(())
}
