//! Native menu evidence using production components and synthetic content.
//! cargo run -p harness-ui --example menu-fixture --features appshots-fixture -- /tmp/menu-review
use gpui::{
    AppContext, Bounds, Context, InteractiveElement, IntoElement, ParentElement, Render, Styled,
    Window, WindowBounds, WindowOptions, div, point, prelude::FluentBuilder, px, size,
};
use harness_theme::{AccentSelection, SurfacePreference};
use harness_ui::{icons, motion, popover, settings, theme, typography};
use std::{path::PathBuf, sync::Arc, time::Duration};

struct MenuFixture {
    nested: bool,
    left: bool,
}

impl Render for MenuFixture {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if motion::hover_fades_active() {
            window.request_animation_frame();
        }
        let theme = theme::Theme::of(cx);
        let mut menu = popover::popover_card(theme).w(px(236.));
        for (index, (label, shortcut)) in [
            ("New chat", "⌘N"),
            ("Rename…", ""),
            ("Move to project", "›"),
            ("Archive", "⌘⇧A"),
        ]
        .into_iter()
        .enumerate()
        {
            if index == 3 {
                menu = menu.child(popover::menu_separator());
            }
            let mut row = popover::menu_row_nav(
                theme,
                index == 0,
                self.nested && index == 2,
                format!("menu-row-{index}"),
            )
            .relative()
            .id(("menu-row", index))
            .child(div().flex_1().child(label))
            .child(div().text_color(theme.text_muted).child(shortcut));
            if self.nested && index == 2 {
                let mut child = popover::nested_menu_card(theme)
                    .flex()
                    .flex_col()
                    .gap(px(2.));
                for (choice, name) in ["Launch", "Mobile app", "Backend"].into_iter().enumerate() {
                    child = child.child(
                        popover::menu_row_nav(
                            theme,
                            choice == 0,
                            false,
                            format!("nested-choice-{choice}"),
                        )
                        .id(("nested-choice", choice))
                        .child(
                            icons::icon(icons::FOLDER)
                                .size(px(15.))
                                .text_color(theme.text_muted),
                        )
                        .child(div().flex_1().child(name))
                        .child(div().w(px(14.)).when(choice == 0, |el| {
                            el.child(
                                icons::icon(icons::CHECK)
                                    .size(px(14.))
                                    .text_color(theme.text_muted),
                            )
                        })),
                    );
                }
                row = row.child(popover::nested_menu(
                    "nested-fixture",
                    child.into_any_element(),
                    self.left,
                ));
            }
            menu = menu.child(row);
        }
        div()
            .size_full()
            .relative()
            .bg(theme.bg)
            .font_family(theme.font_sans.clone())
            .text_size(px(14.))
            .text_color(theme.text)
            .child(
                div()
                    .absolute()
                    .inset(px(24.))
                    .p(px(20.))
                    .bg(theme.surface_card)
                    .rounded(px(10.))
                    .flex()
                    .flex_col()
                    .gap(px(18.))
                    .child("Launch plan")
                    .child("Refine the page hierarchy and simplify navigation.")
                    .child("Review the content, spacing, and next steps.")
                    .child("Keep the interface clear and easy to scan."),
            )
            .child(popover::menu_at(
                "menu-fixture",
                point(
                    px(if self.nested {
                        if self.left { 424. } else { 24. }
                    } else {
                        100.
                    }),
                    px(82.),
                ),
                menu.into_any_element(),
                None,
            ))
    }
}

fn main() -> anyhow::Result<()> {
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let nested = std::env::args().any(|arg| arg == "--nested");
    let left = std::env::args().any(|arg| arg == "--left");
    let failure = Arc::new(std::sync::Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
            gpui_base::init(cx);
            let settings = settings::UiSettings::default();
            let fonts = typography::register_fonts(cx);
            typography::init(
                settings.ui_font_family,
                settings.ui_font_size,
                settings.terminal_font_family,
                settings.terminal_font_size,
                settings.code_font_family,
                settings.code_font_size,
                fonts,
                cx,
            );
            cx.spawn(async move |cx| {
                let run: anyhow::Result<()> = async {
                    for (id, appearance) in [
                        ("codegraff-light", theme::Appearance::Light),
                        ("codegraff-dark", theme::Appearance::Dark),
                        ("warm-harp-light", theme::Appearance::Light),
                        ("warm-harp-dark", theme::Appearance::Dark),
                        ("catppuccin-mocha", theme::Appearance::Dark),
                    ] {
                        if nested && !id.starts_with("warm-harp") {
                            continue;
                        }
                        for (mode, surface) in [
                            ("frosted", SurfacePreference::Frosted),
                            ("opaque", SurfacePreference::Opaque),
                        ] {
                            let window: gpui::AnyWindowHandle = cx
                                .update(|cx| {
                                    theme::Theme::install_selection(
                                        appearance,
                                        id,
                                        AccentSelection::ThemeDefault,
                                        surface,
                                        cx,
                                    );
                                    cx.open_window(
                                        WindowOptions {
                                            window_bounds: Some(WindowBounds::Windowed(
                                                Bounds::new(
                                                    point(px(40.), px(60.)),
                                                    size(
                                                        px(if nested { 680. } else { 480. }),
                                                        px(320.),
                                                    ),
                                                ),
                                            )),
                                            titlebar: None,
                                            ..Default::default()
                                        },
                                        |window, cx| {
                                            window.set_rem_size(px(16.));
                                            cx.new(|_| MenuFixture { nested, left })
                                        },
                                    )
                                })?
                                .into();
                            cx.background_executor()
                                .timer(Duration::from_millis(400))
                                .await;
                            window.update(cx, |_, window, cx| {
                                window.draw(cx).clear();
                                window
                                    .render_to_image()?
                                    .save(output.join(format!("{id}-{mode}-rest.png")))?;
                                window.dispatch_event(
                                    gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                                        position: point(px(160.), px(130.)),
                                        pressed_button: None,
                                        modifiers: Default::default(),
                                    }),
                                    cx,
                                );
                                anyhow::Ok(())
                            })??;
                            cx.background_executor()
                                .timer(Duration::from_millis(350))
                                .await;
                            window.update(cx, |_, window, cx| {
                                window.draw(cx).clear();
                                window
                                    .render_to_image()?
                                    .save(output.join(format!("{id}-{mode}-hover.png")))?;
                                window.remove_window();
                                anyhow::Ok(())
                            })??;
                        }
                    }
                    Ok(())
                }
                .await;
                *result.lock().unwrap() = run.err();
                cx.update(|cx| cx.quit());
            })
            .detach();
        });
    if let Some(error) = failure.lock().unwrap().take() {
        return Err(error);
    }
    Ok(())
}
