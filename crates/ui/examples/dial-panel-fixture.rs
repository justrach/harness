//! The DialKit-style dev Tune panel rendered from made-up values: motion and
//! shape tokens. No engine, no agent calls.
//!
//! `HARNESS_DIAL_SCENE=motion|shape` picks the panel.
//! `HARNESS_FIXTURE_APPEARANCE=dark|light` picks the appearance.
//! cargo run -p harness-ui --example dial-panel-fixture
use gpui::{
    AppContext, Bounds, Context, IntoElement, Render, Window, WindowBounds, WindowOptions, div,
    prelude::*, px, size,
};
use harness_ui::dial_panel::*;
use harness_ui::motion::EASE_OUT_QUINT;
use harness_ui::theme::Theme;
use harness_ui::*;

struct Fixture {
    scene: String,
}

fn tune_header(theme: &Theme, tab: usize) -> Vec<gpui::AnyElement> {
    vec![
        header(theme, "Tune", Some("dev".into()), vec![icons::CLOSE]).into_any_element(),
        segmented(theme, &["Motion", "Shape", "Surface"], tab).into_any_element(),
    ]
}

fn motion(theme: &Theme) -> gpui::Div {
    panel(theme, true)
        .children(tune_header(theme, 0))
        .child(section(theme, "Agent enter", true))
        .child(curve_card(theme, EASE_OUT_QUINT))
        .child(curve_presets(theme, 0))
        .child(section(theme, "Timing", true))
        .child(dial_row(theme, "Duration", "180 ms", 180.0 / 400.0, true))
        .child(dial_row(theme, "Stagger", "45 ms", 45.0 / 100.0, false))
        .child(dial_row(
            theme,
            "Budget",
            "460 / 800 ms",
            460.0 / 800.0,
            false,
        ))
        .child(code_row(theme, "MotionSpec::new(180, EASE_OUT_QUINT)"))
}

fn shape(theme: &Theme) -> gpui::Div {
    panel(theme, true)
        .children(tune_header(theme, 1))
        .child(section(theme, "Menu card", true))
        .child(concentric_preview(theme, 12.0, 1.0, 4.0))
        .child(axis_row(
            theme,
            &[("R", "12"), ("B", "1"), ("I", "4")],
            false,
        ))
        .child(section(theme, "Sizes", true))
        .child(dial_row(theme, "Bubble", "16 px", 16.0 / 24.0, false))
        .child(dial_row(theme, "Panel", "10 px", 10.0 / 24.0, false))
        .child(dial_row(theme, "Control", "6 px", 6.0 / 24.0, false))
        .child(dial_row(theme, "Hit area", "32 px", 32.0 / 48.0, false))
        .child(code_row(theme, "nested_radius(12, 1, 4) = 7"))
}

impl Render for Fixture {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let body = match self.scene.as_str() {
            "shape" => shape(&theme),
            _ => motion(&theme),
        };
        div()
            .size_full()
            .bg(theme.bg)
            .font_family(theme.font_sans.clone())
            .flex()
            .items_center()
            .justify_center()
            .child(body)
    }
}

fn main() -> anyhow::Result<()> {
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
    let scene = std::env::var("HARNESS_DIAL_SCENE").unwrap_or_else(|_| "motion".into());
    let light = std::env::var("HARNESS_FIXTURE_APPEARANCE").as_deref() == Ok("light");
    let height = match scene.as_str() {
        "shape" => 580.0,
        _ => 640.0,
    };
    gpui_platform::application()
        .with_assets(icons::Assets)
        .run(move |cx| {
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
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                        gpui::point(px(40.), px(40.)),
                        size(px(420.), px(height)),
                    ))),
                    ..Default::default()
                },
                |_, cx| {
                    cx.new(|_| Fixture {
                        scene: scene.clone(),
                    })
                },
            )
            .unwrap();
            cx.activate(true);
        });
    Ok(())
}
