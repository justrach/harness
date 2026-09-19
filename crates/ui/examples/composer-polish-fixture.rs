//! Isolated native evidence for production completion controls and rich composer.
use gpui::{
    AppContext, AsyncApp, Bounds, Context, Entity, Focusable, Render, Window, WindowBounds,
    WindowOptions, div, prelude::*, px, size,
};
use std::{ops::Range, path::PathBuf, time::Duration};
use zeron_ui::*;

struct Fixture {
    composer: Entity<composer::Composer>,
    agents: Entity<settings::harnesses::HarnessesPage>,
    settings: bool,
    title: &'static str,
}
impl Render for Fixture {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = theme::Theme::of(cx).clone();
        div()
            .id("fixture")
            .size_full()
            .bg(theme.surface)
            .text_color(theme.text)
            .font_family(theme.font_sans.clone())
            .p(px(24.0))
            .overflow_y_scroll()
            .child(if self.settings {
                div()
                    .flex()
                    .flex_col()
                    .child(settings::widgets::page_header(&theme, "Agents", None))
                    .child(
                        self.agents
                            .update(cx, |page, cx| page.fixture_completion(cx)),
                    )
                    .into_any_element()
            } else {
                div()
                    .h_full()
                    .flex()
                    .flex_col()
                    .justify_center()
                    .gap(px(20.0))
                    .child(settings::widgets::page_header(&theme, self.title, None))
                    .child(self.composer.clone())
                    .into_any_element()
            })
    }
}

struct DraftCase {
    name: &'static str,
    title: &'static str,
    text: String,
    selection: Range<usize>,
}
impl DraftCase {
    fn at(name: &'static str, title: &'static str, text: &str, caret_after: &str) -> Self {
        let caret = text.find(caret_after).unwrap() + caret_after.len();
        Self {
            name,
            title,
            text: text.to_owned(),
            selection: caret..caret,
        }
    }
}

fn markdown_cases() -> Vec<DraftCase> {
    let bullets = "Before the list\n- First item\n- Second item\n- Third item\nAfter the list";
    let inline = "**Bold phrase** then text\n_Italic phrase_ and `inline code`\nContinue here";
    let quoted = "> - Quoted item\n>   - Nested café 日本語\n> - [x] Finished quoted task\n> - [ ] Pending quoted task\n> ```rust\n> /* multiline\n>    comment */\n> let emoji = \"👩🏽‍💻\";\n> ```\n- Outside the quote\nContinue here";
    let crlf = "Heading with setext\r\n-\r\n\r\n- First Windows line\r\n- [x] Finished Windows task\r\n- [ ] Pending Windows task\r\n-\r\nContinue here";
    let unicode_file = zeron_proto::file_mentions::local_file_link("src/日本語/café.rs", false);
    let unicode_skill = zeron_proto::invocation::Invocation::Skill {
        name: "review-unicode".into(),
        path: "/project/.agents/skills/review-unicode/SKILL.md".into(),
        command: None,
    }
    .link();
    let unicode = format!(
        "- Review café, naïve, 日本語, e\u{301} and 👩🏽‍💻 beside {unicode_file} and {unicode_skill} while this sentence wraps across several rows.\n- Keep selection and chips aligned.\nContinue here"
    );
    vec![
        DraftCase::at(
            "bullets-before",
            "Bullets · editing preceding paragraph",
            bullets,
            "Before the list",
        ),
        DraftCase::at(
            "bullets-after",
            "Bullets · editing following paragraph",
            bullets,
            "After the list",
        ),
        DraftCase::at(
            "bullets-first",
            "Bullets · editing first item",
            bullets,
            "First item",
        ),
        DraftCase::at(
            "bullets-middle",
            "Bullets · editing middle item",
            bullets,
            "Second item",
        ),
        DraftCase::at(
            "bullets-last",
            "Bullets · editing last item",
            bullets,
            "Third item",
        ),
        DraftCase::at(
            "lists",
            "Ordered, nested, task and empty items",
            "1. Ordered item\n2. Another item\n   - Nested item\n- [x] Finished task\n- [ ] Pending task\n-\nContinue here",
            "Continue here",
        ),
        DraftCase::at(
            "tasks-active",
            "Task marker while editing its content",
            "- [x] Finished task\n- [ ] Pending task\n- Ordinary bullet\nContinue here",
            "Pending task",
        ),
        DraftCase::at(
            "inline-active",
            "Inline formatting while editing its content",
            inline,
            "Bold phrase",
        ),
        DraftCase {
            name: "inline-selection",
            title: "Selection across formatted lines",
            text: inline.to_owned(),
            selection: 2..inline.find(" and ").unwrap(),
        },
        DraftCase::at(
            "markdown",
            "Headings, quotes and inline formatting",
            "# Heading\n## Subheading\n> Quoted **strong text**\n**Bold** and _italic_ and ~~removed~~\nInline `code()` and café 日本語\n---\nContinue here",
            "Continue here",
        ),
        DraftCase::at(
            "code",
            "Code stays literal while surrounding prose renders",
            "**Outside code** and ``one ` tick``\n```rust\nlet source = \"**literal**\";\n// - no bullet here\n```\n- Render this item\nContinue here",
            "Continue here",
        ),
        DraftCase::at(
            "quoted-lists",
            "Quoted lists, tasks and multiline code",
            quoted,
            "Continue here",
        ),
        DraftCase::at(
            "quoted-task-active",
            "Editing a quoted task",
            quoted,
            "Pending quoted task",
        ),
        DraftCase::at(
            "crlf-lists",
            "Windows line endings and empty items",
            crlf,
            "Continue here",
        ),
        DraftCase::at(
            "unicode-wrap",
            "Unicode and chips across wrapped rows",
            &unicode,
            "👩🏽‍💻",
        ),
        DraftCase {
            name: "unicode-wrap-selection",
            title: "Selection across Unicode and chips",
            selection: unicode.find("café").unwrap()..unicode.find(" while this sentence").unwrap(),
            text: unicode,
        },
    ]
}

async fn pause(cx: &mut AsyncApp) {
    cx.background_executor()
        .timer(Duration::from_millis(400))
        .await;
}
fn main() -> anyhow::Result<()> {
    let runtime = tokio::runtime::Runtime::new()?;
    let _guard = runtime.enter();
    let output = PathBuf::from(std::env::args().nth(1).expect("output directory"));
    std::fs::create_dir_all(&output)?;
    let temp = tempfile::tempdir()?;
    let data = temp.path().to_path_buf();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx); gpui_base::init(cx);
        let prefs = settings::UiSettings::default();
        settings::init(prefs.clone(), data.clone(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(prefs.ui_font_family.clone(), prefs.ui_font_size, prefs.terminal_font_family.clone(), prefs.terminal_font_size, prefs.code_font_family.clone(), prefs.code_font_size, fonts, cx);
        theme_library::init(data.clone(), cx);
        appearance::init(appearance::AppearanceMode::Dark, prefs.theme_selection, prefs.accent, prefs.surface, cx);
        composer::init(cx, prefs.composer_send_behavior);
        let state = cx.new(|_| state::AppState::new());
        let composer = cx.new(|cx| composer::Composer::new(state.clone(), cx));
        let agents = cx.new(|cx| settings::harnesses::HarnessesPage::new(state.clone(), cx));
        let skill = zeron_proto::invocation::Invocation::Skill { name: "review-changes".into(), path: "/project/.agents/skills/review-changes/SKILL.md".into(), command: None }.link();
        let file = zeron_proto::file_mentions::local_file_link("src/composer.rs", false);
        let long_file = zeron_proto::file_mentions::local_file_link("src/components/very-long-internationalized-component-name.test.tsx", false);
        let draft = format!("Review {file} with {skill}\nAlso check {long_file}\n**Keep the layout calm** and _easy to edit_.\n- Preserve keyboard navigation\n- Check café and 日本語\n```rust\nlet chips = render(&draft);\n```\nContinue here");
        composer.update(cx, |view, cx| view.fixture_rich_draft(&draft, cx));
        let window = cx.open_window(WindowOptions { window_bounds: Some(WindowBounds::Windowed(Bounds::new(gpui::point(px(40.), px(40.)), size(px(840.), px(960.))))), ..Default::default() }, |_, cx| cx.new(|_| Fixture { composer, agents, settings: true, title: "Composer" })).unwrap();
        cx.activate(true);
        cx.spawn(async move |cx| {
            for light in [false, true] {
                cx.update(|cx| appearance::set_mode(if light { appearance::AppearanceMode::Light } else { appearance::AppearanceMode::Dark }, cx));
                for settings in [true, false] {
                    for width in [840., 440.] {
                        window.update(cx, |view, w, cx| {
                            view.settings = settings;
                            w.resize(size(px(width), px(960.)));
                            if !settings {
                                w.activate_window();
                                w.focus(&view.composer.focus_handle(cx), cx);
                            }
                            cx.notify();
                        }).unwrap();
                        pause(cx).await;
                        let name = format!("{}-{}-{}.png", if settings { "agents" } else { "composer" }, if light { "light" } else { "dark" }, width as u32);
                        let capture_window: gpui::AnyWindowHandle = window.into();
                        capture_window.update(cx, |_, w, cx| { w.draw(cx).clear(); w.render_to_image().unwrap().save(output.join(name)).unwrap(); }).unwrap();
                    }
                }
            }
            // Each editing case gets a wide dark and narrow light capture. The
            // shared composer case above covers the complementary combinations.
            for case in markdown_cases() {
                for (light, width) in [(false, 840.), (true, 440.)] {
                    cx.update(|cx| appearance::set_mode(if light { appearance::AppearanceMode::Light } else { appearance::AppearanceMode::Dark }, cx));
                    window.update(cx, |view, w, cx| {
                        view.settings = false;
                        view.title = case.title;
                        view.composer.update(cx, |composer, cx| composer.fixture_rich_selection(&case.text, case.selection.clone(), cx));
                        w.resize(size(px(width), px(960.)));
                        w.activate_window();
                        w.focus(&view.composer.focus_handle(cx), cx);
                        cx.notify();
                    }).unwrap();
                    pause(cx).await;
                    let name = format!("{}-{}-{}.png", case.name, if light { "light" } else { "dark" }, width as u32);
                    let capture_window: gpui::AnyWindowHandle = window.into();
                    capture_window.update(cx, |_, w, cx| { w.draw(cx).clear(); w.render_to_image().unwrap().save(output.join(name)).unwrap(); }).unwrap();
                    if case.name == "bullets-after" && !light {
                        // Exercise production cursor navigation without resetting
                        // the draft or explicitly refreshing its projection.
                        for (name, up, count) in [("bullets-arrow-up", true, 3), ("bullets-arrow-down", false, 1)] {
                            for _ in 0..count {
                                capture_window.update(cx, |_, w, cx| {
                                    if up { w.dispatch_action(Box::new(composer::Up), cx); }
                                    else { w.dispatch_action(Box::new(composer::Down), cx); }
                                }).unwrap();
                                pause(cx).await;
                            }
                            window.update(cx, |view, _, cx| {
                                view.title = if up { "Bullets · after ArrowUp navigation" } else { "Bullets · after ArrowDown navigation" };
                                cx.notify();
                            }).unwrap();
                            let name = format!("{name}-dark-840.png");
                            capture_window.update(cx, |_, w, cx| { w.draw(cx).clear(); w.render_to_image().unwrap().save(output.join(name)).unwrap(); }).unwrap();
                        }
                    }
                }
            }
            cx.update(|cx| cx.quit());
        }).detach();
    });
    Ok(())
}
