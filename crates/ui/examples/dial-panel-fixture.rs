//! DialKit-style panels rendered from made-up values: the dev Tune panel
//! (motion and shape tokens) and the Run settings card, with or without the
//! walkthrough. No engine, no agent calls.
//!
//! `HARNESS_DIAL_SCENE=motion|shape|run|walkthrough` picks the panel.
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

const RUN_PRESETS: [(&str, &str); 4] = [
    ("Fast", "Low · asks"),
    ("Careful", "Med · read-only"),
    ("Deep", "High · worktree"),
    ("Hands-off", "Auto · worktree"),
];

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

fn run(theme: &Theme, walkthrough: bool) -> gpui::Div {
    let card = panel(theme, false)
        .child(header(
            theme,
            "Run settings",
            Some("graff".into()),
            vec![icons::CLOSE],
        ))
        .child(segmented(theme, &["Presets", "Saved"], 0))
        .child(run_presets(theme, &RUN_PRESETS, 2))
        .child(divider(theme));
    let reasoning = choice_row(theme, "Reasoning", &["Low", "Med", "High"], 2);
    let sandbox = choice_row(theme, "Sandbox", &["Read", "Write", "Full"], 1);
    let approve = toggle_row(theme, "Auto-approve", false);
    let worktree = toggle_row(theme, "Worktree", true);
    let compact = dial_row(theme, "Compact", "80%", 0.8, false);
    // Holding H explains the control under the pointer; here, Sandbox.
    let hint = |control, text, on| explained(theme, control, text, walkthrough && on);
    card.child(hint(reasoning, "How hard the model thinks.", false))
        .child(hint(sandbox, "Write: edits this repo only.", true))
        .child(hint(approve, "Off: you approve each command.", false))
        .child(hint(worktree, "Own branch; main stays clean.", false))
        .child(hint(compact, "Summarise at this context use.", false))
        .child(mode_bar(
            theme,
            &[("H", if walkthrough { "Sandbox" } else { "Explain" })],
            if walkthrough { 0 } else { 9 },
        ))
}

impl Render for Fixture {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let body = match self.scene.as_str() {
            "shape" => shape(&theme),
            "run" => run(&theme, false),
            "walkthrough" => run(&theme, true),
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
        "walkthrough" => 600.0,
        "run" => 580.0,
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
