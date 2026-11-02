//! Capture the production changes cue at narrow and normal widths, using synthetic data only.
//! cargo run -p harness-ui --features appshots-fixture --example changes-card-fixture -- OUT_DIR
use gpui::{
    Bounds, Context, Render, Window, WindowBounds, WindowOptions, div, point, prelude::*, px, size,
};
use harness_ui::{
    icons,
    theme::Theme,
    turn_work::{TurnChanges, changes_cue},
    typography,
};
use std::{path::PathBuf, time::Duration};

struct Fixture;

impl Render for Fixture {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_rem_size(px(20.0));
        let theme = Theme::of(cx);
        div()
            .size_full()
            .bg(theme.bg)
            .font_family(theme.font_sans.clone())
            .flex()
            .items_end()
            .gap(px(24.0))
            .p(px(20.0))
            .children(
                [176.0, 260.0, 500.0]
                    .into_iter()
                    .enumerate()
                    .map(|(index, width)| {
                        let changes = TurnChanges {
                            files: if index == 0 {
                                vec!["example.md".into()]
                            } else {
                                vec![
                                    "src/lexer.rs".into(),
                                    "src/parser.rs".into(),
                                    "src/empty_input.rs".into(),
                                ]
                            },
                            additions: if index == 0 { 0 } else { 12345 },
                            deletions: if index == 0 { 0 } else { 6789 },
                        };
                        div()
                            .id(("fixture-cue", index))
                            .relative()
                            .w(px(width))
                            .h(px(44.0))
                            .rounded(px(12.0))
                            .border_1()
                            .border_color(theme.border)
                            .bg(theme.surface_card)
                            .child(
                                div()
                                    .p(px(10.0))
                                    .text_size(px(12.0))
                                    .text_color(theme.text_muted)
                                    .child("Composer"),
                            )
                            .child(changes_cue(&changes, index == 2, theme, |_, _, _| {}))
                    }),
            )
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            typography::register_fonts(cx);
            cx.set_global(Theme::default());
            let window = cx
                .open_window(
                    WindowOptions {
                        window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                            point(px(20.0), px(40.0)),
                            size(px(1024.0), px(360.0)),
                        ))),
                        focus: false,
                        ..Default::default()
                    },
                    |_, cx| cx.new(|_| Fixture),
                )
                .unwrap();
            let window: gpui::AnyWindowHandle = window.into();
            cx.spawn(async move |cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(500))
                    .await;
                window
                    .update(cx, |_, window, cx| {
                        window.draw(cx).clear();
                        window
                            .render_to_image()
                            .unwrap()
                            .save(output.join("changes-card.png"))
                            .unwrap();
                        window.remove_window();
                    })
                    .unwrap();
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    Ok(())
}
