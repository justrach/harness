//! Synthetic inline-code URL rendering and native pointer/keyboard activation.
//! Run with `--features browser-fixture,gpui_platform/test-support --example
//! inline-code-link-fixture -- DIR [before]`. No network requests are made.
use gpui::{
    AppContext, Bounds, Context, IntoElement, ParentElement, Render, Styled, Window, WindowBounds,
    WindowOptions, div, point, px, size,
};
use harness_ui::{appearance, icons, markdown, settings, theme, theme_library, typography};
use markdown::render::{LinkAction, LinkActivation, LinkOutcome, LinkUi};
use std::{cell::RefCell, path::PathBuf, rc::Rc, sync::Arc, time::Duration};

const URL: &str = "http://127.0.0.1:3000/preview";
const SOURCE: &str =
    "Try `http://127.0.0.1:3000/preview`\n\nCommand stays code: `curl https://example.com`";

struct LinkFixture {
    activations: Rc<RefCell<Vec<LinkActivation>>>,
}

impl Render for LinkFixture {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx);
        let mut options = markdown::render::RenderOptions::settled("inline-code-fixture".into());
        let activations = self.activations.clone();
        options.link = Some(LinkUi {
            source_session: Some("synthetic-chat".into()),
            handler: Rc::new(move |activation, _, cx| {
                activations.borrow_mut().push(activation.clone());
                cx.refresh_windows();
                // Capture routing without opening a browser or making a request.
                LinkOutcome::Rejected
            }),
        });
        let count = self.activations.borrow().len();
        div()
            .size_full()
            .p(px(24.))
            .bg(theme.bg)
            .text_color(theme.text)
            .flex()
            .flex_col()
            .gap(px(20.))
            .child(markdown::render::render_tree(
                &markdown::parse_full(SOURCE),
                &options,
                &theme,
                window,
                &|_| None,
            ))
            .child(div().text_size(px(13.)).child(if count == 0 {
                "No clickable URL target; no activation captured.".to_owned()
            } else {
                format!("URL activation captured: {count} (pointer + keyboard).")
            }))
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    let before = std::env::args().nth(2).as_deref() == Some("before");
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let runtime = tokio::runtime::Runtime::new()?;
    let _runtime = runtime.enter();
    let failure = Arc::new(std::sync::Mutex::new(Some(
        "fixture exited before completing its assertions and capture".to_owned(),
    )));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_tokio::init(cx);
            gpui_base::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data.path().to_owned(), cx);
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
            theme_library::init(data.path().to_owned(), cx);
            appearance::init(
                appearance::AppearanceMode::Light,
                settings.theme_selection,
                settings.accent,
                settings.surface,
                cx,
            );
            let activations = Rc::new(RefCell::new(Vec::new()));
            let window = cx
                .open_window(
                    WindowOptions {
                        window_background: theme::Theme::of(cx).window_background_appearance(),
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            point(px(40.), px(60.)),
                            size(px(640.), px(180.)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| {
                        cx.new(|_| LinkFixture {
                            activations: activations.clone(),
                        })
                    },
                )
                .unwrap();
            let window: gpui::AnyWindowHandle = window.into();
            cx.activate(true);
            cx.spawn(async move |cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(500))
                    .await;
                let exercise: anyhow::Result<()> = window
                    .update(cx, |_, window, cx| {
                        window.draw(cx).clear();
                        let target = markdown::render::fixture_link(URL);
                        if before {
                            anyhow::ensure!(target.is_none(), "baseline unexpectedly has a link");
                        } else {
                            let (position, focus) =
                                target.ok_or_else(|| anyhow::anyhow!("URL has no link target"))?;
                            window.dispatch_event(
                                gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                                    button: gpui::MouseButton::Left,
                                    position,
                                    click_count: 1,
                                    ..Default::default()
                                }),
                                cx,
                            );
                            window.dispatch_event(
                                gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                                    button: gpui::MouseButton::Left,
                                    position,
                                    click_count: 1,
                                    ..Default::default()
                                }),
                                cx,
                            );
                            anyhow::ensure!(
                                activations.borrow().len() == 1,
                                "pointer did not activate"
                            );
                            window.focus(&focus, cx);
                            window.refresh();
                            window.draw(cx).clear();
                            window.dispatch_event(
                                gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                                    keystroke: gpui::Keystroke::parse("enter")?,
                                    is_held: false,
                                    prefer_character_input: false,
                                }),
                                cx,
                            );
                            window.dispatch_event(
                                gpui::PlatformInput::KeyUp(gpui::KeyUpEvent {
                                    keystroke: gpui::Keystroke::parse("enter")?,
                                }),
                                cx,
                            );
                            let log = activations.borrow();
                            anyhow::ensure!(
                                log.len() == 2,
                                "pointer and keyboard must each activate: {}",
                                log.len()
                            );
                            for activation in log.iter() {
                                anyhow::ensure!(
                                    activation.target.original == URL,
                                    "destination changed"
                                );
                                anyhow::ensure!(
                                    activation.target.navigation.as_deref() == Ok(URL),
                                    "invalid destination"
                                );
                                anyhow::ensure!(
                                    activation.action == LinkAction::Primary,
                                    "wrong action"
                                );
                                anyhow::ensure!(
                                    activation.source_session.as_deref() == Some("synthetic-chat"),
                                    "wrong owner"
                                );
                            }
                            window.blur();
                        }
                        window.refresh();
                        window.draw(cx).clear();
                        let name = if before {
                            "inline-code-before.png"
                        } else {
                            "inline-code-after.png"
                        };
                        window.render_to_image()?.save(output.join(name))?;
                        Ok(())
                    })
                    .and_then(|r| r);
                if let Err(error) = exercise {
                    // Native quit can exit the process without returning from run.
                    eprintln!("inline-code-link fixture failed: {error:#}");
                    std::process::exit(1);
                }
                *result.lock().unwrap() = None;
                println!("Inline-code URL assertions and screenshot completed.");
                let _ = window.update(cx, |_, window, _| window.remove_window());
                let _ = cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
