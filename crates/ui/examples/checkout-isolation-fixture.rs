//! Native checkout controls with synthetic data; no engine or agent requests.
//! cargo run -p harness-ui --example checkout-isolation-fixture --features appshots-fixture,project-palette-fixture -- after.png
//! Add `shared` to show the old shared-checkout default for comparison.
use gpui::{
    AppContext, Bounds, Context, Entity, Render, Window, WindowBounds, WindowOptions, div, point,
    prelude::*, px, rgb, size,
};
use harness_ui::{
    appearance, composer, icons, pickers, settings, state, theme_library, typography,
};
use std::path::PathBuf;
use std::time::Duration;

struct Preview {
    pickers: Entity<pickers::Pickers>,
}

impl Render for Preview {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let controls = self.pickers.update(cx, |pickers, cx| {
            pickers.render_new_thread_git_selectors(cx)
        });
        div()
            .size_full()
            .bg(rgb(0xf0ede5))
            .text_color(rgb(0x292823))
            .font_family(".AppleSystemUIFont")
            .p_8()
            .flex()
            .flex_col()
            .gap_5()
            .child(div().text_size(px(14.)).child("New session in"))
            .child(div().text_size(px(30.)).child("Demo project"))
            .child(
                div()
                    .w_full()
                    .h(px(90.))
                    .rounded_2xl()
                    .border_1()
                    .border_color(rgb(0xd4d0c7))
                    .p_5()
                    .text_color(rgb(0x918c7e))
                    .child("Do anything…"),
            )
            .children(controls)
    }
}

fn main() -> anyhow::Result<()> {
    let output = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .expect("output PNG path");
    let shared = std::env::args().any(|arg| arg == "shared");
    let runtime = tokio::runtime::Runtime::new()?;
    let _runtime = runtime.enter();
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx);
        gpui_base::init(cx);
        let settings = settings::UiSettings::default();
        settings::init(settings.clone(), data.clone(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(settings.ui_font_family.clone(), settings.ui_font_size,
            settings.terminal_font_family.clone(), settings.terminal_font_size,
            settings.code_font_family.clone(), settings.code_font_size, fonts, cx);
        theme_library::init(data, cx);
        appearance::init(appearance::AppearanceMode::Light, settings.theme_selection,
            settings.accent, settings.surface, cx);
        composer::init(cx, settings.composer_send_behavior);
        let state = cx.new(|_| {
            let mut state = state::AppState::new();
            state.local_device_id = Some("fixture".into());
            state.selected_space = Some("demo".into());
            state.auto_selected = true;
            state.spaces = vec![serde_json::from_value(serde_json::json!({
                "id": "demo", "deviceId": "fixture", "path": "/synthetic/demo", "name": "Demo project",
                "gitDetected": true, "createdAt": "2026-01-01T00:00:00Z"
            })).unwrap()];
            state
        });
        let picker = cx.new(|cx| {
            let mut picker = pickers::Pickers::new(state, cx);
            picker.fixture_checkout_controls(shared, cx);
            picker
        });
        let window = cx.open_window(WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(0.), px(0.)), size(px(820.), px(310.))))),
            ..Default::default()
        }, |_, cx| cx.new(|_| Preview { pickers: picker })).unwrap();
        cx.activate(true);
        cx.spawn(async move |cx| {
            cx.background_executor().timer(Duration::from_millis(600)).await;
            let window: gpui::AnyWindowHandle = window.into();
            window.update(cx, |_, window, cx| {
                window.draw(cx).clear();
                window.render_to_image().unwrap().save(&output).unwrap();
                println!("Saved synthetic checkout controls");
                cx.quit();
            }).unwrap();
        }).detach();
    });
    Ok(())
}
