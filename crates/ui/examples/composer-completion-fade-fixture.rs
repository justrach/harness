//! Capture the production composer for slash completion next to prompt text
//! (#575) and for a draft whose only overflow is a trailing blank row (#578).
//! Synthetic data only: no engine, temporary settings.
//! cargo run -p harness-ui --example composer-completion-fade-fixture --features appshots-fixture -- OUT_DIR
use gpui::{AppContext, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let data = tempfile::tempdir()?;
    let failure = Arc::new(Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_base::init(cx);
            let settings = settings::UiSettings::default();
            settings::init(settings.clone(), data.path(), cx);
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
            cx.set_global(theme::Theme::dark());
            history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
            app_menus::init(cx);
            composer::init(cx, settings.composer_send_behavior);
            let state = cx.new(|_| {
                let mut state = state::AppState::new();
                state.no_project = true;
                state
            });
            let (width, height) = (768.0, 420.0);
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            gpui::point(px(30.), px(40.)),
                            size(px(width), px(height)),
                        ))),
                        ..Default::default()
                    },
                    |_, cx| cx.new(|cx| composer::Composer::new(state.clone(), cx)),
                )
                .unwrap();
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    let settle = Duration::from_millis(600);
                    let capture_window: gpui::AnyWindowHandle = window.into();
                    let capture = |name: &str, cx: &mut gpui::AsyncApp| -> anyhow::Result<()> {
                        let path = output.join(name);
                        capture_window.update(cx, |_, window, cx| -> anyhow::Result<()> {
                            window.draw(cx).clear();
                            window.render_to_image()?.save(&path)?;
                            Ok(())
                        })??;
                        Ok(())
                    };
                    window.update(cx, |composer, _, cx| {
                        composer.set_available_width(width, cx);
                        composer.set_available_height(height, cx);
                    })?;

                    // #575: `/goal|prompt text remains`, then accept with Tab.
                    let draft = "/goalprompt text remains";
                    window.update(cx, |composer, _, cx| {
                        composer.fixture_offer_commands(draft, 5, &["goal", "goals-review"], cx);
                    })?;
                    cx.background_executor().timer(settle).await;
                    capture("575-typed.png", cx)?;
                    window.update(cx, |composer, _, cx| composer.fixture_accept_completion(cx))?;
                    cx.background_executor().timer(settle).await;
                    capture("575-accepted.png", cx)?;
                    let (text, caret) =
                        window.update(cx, |composer, _, cx| composer.fixture_input_text(cx))?;
                    println!("575 accepted: {text:?} caret {caret}");

                    // #578: eleven rows and one trailing newline, caret at EOF,
                    // then one row (22.75px) toward the start by wheel.
                    let rows = (1..=11)
                        .map(|row| format!("Synthetic draft row {row:02}"))
                        .collect::<Vec<_>>()
                        .join("\n");
                    let draft = format!("{rows}\n");
                    window.update(cx, |composer, _, cx| composer.fixture_set_draft(&draft, cx))?;
                    cx.background_executor().timer(settle).await;
                    let end =
                        window.update(cx, |composer, _, cx| composer.fixture_input_scroll(cx))?;
                    println!("578 at EOF: scroll {:.2} fades {:?}", end.0, end.1);
                    capture("578-eof.png", cx)?;
                    window.update(cx, |composer, window, cx| {
                        composer.fixture_scroll_input(22.75, window, cx)
                    })?;
                    cx.background_executor().timer(settle).await;
                    let up =
                        window.update(cx, |composer, _, cx| composer.fixture_input_scroll(cx))?;
                    println!("578 one row up: scroll {:.2} fades {:?}", up.0, up.1);
                    capture("578-one-row-up.png", cx)?;

                    // Soft-wrapped whitespace belongs to the same logical
                    // line, but must not count as hidden written text.
                    for (name, suffix) in [
                        ("spaces", " ".repeat(400)),
                        ("em-spaces", "\u{2003}".repeat(100)),
                        ("mixed-spaces", " \u{2003}".repeat(100)),
                    ] {
                        let draft = format!("{rows}{suffix}\n");
                        window.update(cx, |composer, _, cx| {
                            composer.fixture_set_draft_at_last_glyph(&draft, cx)
                        })?;
                        cx.background_executor().timer(settle).await;
                        let position = window
                            .update(cx, |composer, _, cx| composer.fixture_input_scroll(cx))?;
                        println!(
                            "578 wrapped {name}: scroll {:.2} fades {:?}",
                            position.0, position.1
                        );
                        capture(&format!("578-wrapped-{name}.png"), cx)?;
                    }
                    Ok(())
                }
                .await;
                if let Err(error) = run {
                    *result.lock().unwrap() = Some(format!("{error:#}"));
                }
                let _ = window.update(cx, |_, window, _| window.remove_window());
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}
