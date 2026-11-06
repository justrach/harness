//! Native screenshot catalog of production menu render paths. Fixture-only.
use crate::{
    state::{AppState, EngineBootConfig},
    theme::Theme,
};
use gpui::{AnyElement, App, Context, Entity, Render, Window, div, prelude::*, px};

pub const CASES: &[(&str, &str)] = &[
    ("account", "Account menu"),
    ("chat", "Chat context menu"),
    ("chat-copy", "Chat Copy menu"),
    ("project-context", "Project context menu"),
    ("section-context", "Section context menu"),
    ("project-filter", "Project selector"),
    ("sidebar", "Sidebar view options"),
    ("sidebar-organize", "Sidebar · Organize"),
    ("sidebar-sort", "Sidebar · Sort"),
    ("sidebar-show", "Sidebar · Expanded details"),
    ("project-actions", "Project actions"),
    ("add-panel", "Add panel"),
    ("device", "Composer device picker"),
    ("project", "Composer project picker"),
    ("branch", "Branch picker"),
    ("checkout", "Checkout picker"),
    ("model", "Model picker"),
    ("model-reasoning", "Model · Reasoning"),
    ("model-context", "Model · Context window"),
    ("files-context", "File editor context menu"),
    ("link-context", "Link context menu"),
    ("history-author", "Git history author menu"),
    ("history-columns", "Git history columns menu"),
    ("diff-scope", "Diff scope menu"),
    ("diff-ref", "Diff base branch menu"),
    ("accounts-device", "Accounts device selector"),
    ("harnesses-device", "Agents device selector"),
    ("keep-awake-off", "Keep awake · default off"),
    ("keep-awake-on", "Keep awake · enabled"),
    ("keep-awake-remote", "Keep awake · Studio computer"),
    (
        "keep-awake-unsupported",
        "Keep awake · unsupported computer",
    ),
    ("titles-harness", "Session title agent"),
    ("titles-model", "Session title model"),
    ("ui-font", "Interface font"),
    ("ui-size", "Interface font size"),
    ("terminal-font", "Terminal font"),
    ("terminal-size", "Terminal font size"),
    ("code-font", "Code font"),
    ("code-size", "Code font size"),
    ("theme-light", "Light theme selector"),
    ("theme-dark", "Dark theme selector"),
    ("mention", "File mention completion"),
    ("slash", "Slash command completion"),
];

type RenderMenu = Box<dyn FnMut(&mut Window, &mut App) -> AnyElement>;
pub struct MenuReview {
    label: &'static str,
    case: &'static str,
    render_menu: RenderMenu,
}

impl MenuReview {
    pub fn new(
        case: &'static str,
        label: &'static str,
        state: Entity<AppState>,
        boot: EngineBootConfig,
        cx: &mut Context<Self>,
    ) -> Self {
        let render_menu: RenderMenu = match case {
            "link-context" => Box::new(|_, _| crate::markdown::review_link()),
            "history-author" | "history-columns" => {
                let view = cx.new(|cx| crate::history::GitHistory::new(state, cx));
                Box::new(move |_, cx| view.update(cx, |v, cx| v.review_menu(case, cx)))
            }
            "diff-scope" | "diff-ref" => {
                let view = cx.new(|cx| crate::changes::Changes::new(state, cx));
                Box::new(move |window, cx| view.update(cx, |v, cx| v.review_menu(case, window, cx)))
            }
            "ui-font" | "ui-size" | "terminal-font" | "terminal-size" | "code-font"
            | "code-size" | "theme-light" | "theme-dark" => {
                let view = cx.new(crate::settings::appearance::AppearancePage::new);
                Box::new(move |_, cx| view.update(cx, |v, cx| v.review_menu(case, cx)))
            }
            "accounts-device" => {
                let view = cx.new(|cx| crate::settings::accounts::AccountsPage::new(state, cx));
                Box::new(move |_, cx| view.update(cx, |v, cx| v.review_menu(cx)))
            }
            "harnesses-device"
            | "titles-harness"
            | "titles-model"
            | "keep-awake-off"
            | "keep-awake-on"
            | "keep-awake-remote"
            | "keep-awake-unsupported" => {
                let view = cx.new(|cx| crate::settings::harnesses::HarnessesPage::new(state, cx));
                Box::new(move |_, cx| view.update(cx, |v, cx| v.review_menu(case, cx)))
            }
            "device" | "project" | "branch" | "checkout" | "model" | "model-reasoning"
            | "model-context" => {
                let view = cx.new(|cx| crate::pickers::Pickers::new(state, cx));
                Box::new(move |_, cx| view.update(cx, |v, cx| v.review_menu(case, cx)))
            }
            "files-context" => {
                let view = cx.new(|cx| {
                    crate::files::FilesSurface::new_explorer(state, "launch-0".into(), false, cx)
                });
                Box::new(move |window, cx| view.update(cx, |v, cx| v.review_menu(window, cx)))
            }
            "mention" | "slash" => {
                let view = cx.new(|cx| crate::composer::Composer::new(state, cx));
                Box::new(move |_, cx| view.update(cx, |v, cx| v.review_menu(case, cx)))
            }
            _ => {
                let view = cx.new(|cx| crate::shell::Shell::new(state, boot, cx));
                Box::new(move |window, cx| view.update(cx, |v, cx| v.review_menu(case, window, cx)))
            }
        };
        Self {
            label,
            case,
            render_menu,
        }
    }
}
impl Render for MenuReview {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let content = (self.render_menu)(window, cx);
        div()
            .size_full()
            .relative()
            .bg(theme.bg)
            .text_color(theme.text)
            .font_family(theme.font_sans.clone())
            .child(
                div()
                    .absolute()
                    .left(px(32.))
                    .top(px(22.))
                    .text_size(px(16.))
                    .child(self.label),
            )
            .child(
                div()
                    .absolute()
                    .left(px(32.))
                    .top(px(48.))
                    .text_size(px(12.))
                    .text_color(theme.text_muted)
                    .child("Production menu · synthetic data"),
            )
            .child(
                div()
                    .absolute()
                    .left(px(64.))
                    .top(px(if matches!(self.case, "mention" | "slash") {
                        500.
                    } else {
                        110.
                    }))
                    .w(px(if self.case.starts_with("keep-awake-") {
                        768.
                    } else if self.case.starts_with("titles-") {
                        520.
                    } else if self.case == "add-panel" {
                        450.
                    } else if matches!(self.case, "mention" | "slash") {
                        480.
                    } else {
                        260.
                    }))
                    .child(content),
            )
    }
}
