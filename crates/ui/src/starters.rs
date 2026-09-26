//! Starter prompts for the new-session canvas. Harness otherwise opens on a
//! bare composer that assumes you already have a repo and know what an agent
//! does; starters show what it can do (build, research, plan a launch) and
//! drop a ready-to-finish prompt into the composer.

use gpui::{SharedString, div, prelude::*, px};

use crate::motion;
use crate::theme::Theme;

/// One starter: a card on the first-run screen and a chip under the
/// new-session composer.
#[derive(Debug)]
pub(crate) struct Starter {
    pub id: &'static str,
    pub icon: &'static str,
    pub title: &'static str,
    /// One line on the first-run card saying what you get.
    pub blurb: &'static str,
    /// Dropped into the composer with the caret at the end, so the user only
    /// finishes the last line.
    pub prompt: &'static str,
    /// Starts outside any project: the agent makes its own folder, so it
    /// needs a writable home directory rather than an existing repo.
    pub fresh_folder: bool,
    /// Only offered when a project is picked (it's about that project).
    pub needs_project: bool,
}

pub(crate) const STARTERS: &[Starter] = &[
    Starter {
        id: "build",
        icon: crate::icons::MAGIC_STICK_3,
        title: "Build something new",
        blurb: "Describe an idea. The agent makes a folder, writes the code, and runs it.",
        prompt: "Build something new from scratch. Create a new folder for it under ~/Projects, \
                 set it up, and get a first working version running. Ask me anything you need \
                 to know before you start.\n\nMy idea: ",
        fresh_folder: true,
        needs_project: false,
    },
    Starter {
        id: "research",
        icon: crate::icons::MAGNIFER,
        title: "Research a topic",
        blurb: "Get a sourced write-up on anything, with the key takeaways up front.",
        prompt: "Research the topic below and give me a concise, well-sourced write-up: key \
                 takeaways first, then the details, with links to your sources.\n\nTopic: ",
        fresh_folder: false,
        needs_project: false,
    },
    Starter {
        id: "launch",
        icon: crate::icons::GLOBAL,
        title: "Plan a launch",
        blurb: "Positioning, a go-to-market plan, and landing page copy for your product.",
        prompt: "Help me take my product to market. Ask me about the product, who it's for, and \
                 my goals, then draft positioning, a go-to-market plan, and landing page \
                 copy.\n\nThe product: ",
        fresh_folder: false,
        needs_project: false,
    },
    Starter {
        id: "tour",
        icon: crate::icons::FILE_CODE,
        title: "Tour this project",
        blurb: "Learn what the code does, how it's organized, and where to start.",
        prompt: "Give me a tour of this project: what it does, how it's organized, how to run \
                 it, and where I'd start making changes.",
        fresh_folder: false,
        needs_project: true,
    },
];

/// The starters offered right now.
pub(crate) fn available(has_project: bool) -> impl Iterator<Item = &'static Starter> {
    STARTERS
        .iter()
        .filter(move |s| has_project || !s.needs_project)
}

/// A compact pill (icon + title) for the row under the composer.
pub(crate) fn chip(starter: &Starter, theme: &Theme) -> gpui::Stateful<gpui::Div> {
    let id: SharedString = format!("starter-chip-{}", starter.id).into();
    let ink = motion::hover_blend(&id, theme.text_muted, theme.text);
    div()
        .id(id.clone())
        .flex_none()
        .h(px(28.0))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(6.0))
        .px(px(10.0))
        .rounded(px(14.0))
        .border_1()
        .border_color(theme.border)
        .bg(motion::hover_blend(
            &id,
            gpui::transparent_black(),
            theme.element_hover,
        ))
        .on_hover(motion::hover_listener(id.clone()))
        .cursor_pointer()
        .text_size(crate::typography::ui_rems(12.0))
        .text_color(ink)
        // Icons don't inherit the text color; without their own they vanish.
        .child(
            crate::icons::icon(starter.icon)
                .size(px(13.0))
                .flex_none()
                .text_color(ink),
        )
        .child(SharedString::from(starter.title))
}

/// A first-run card: icon, title and a one-line blurb.
pub(crate) fn card(
    id: &'static str,
    icon: &'static str,
    title: &'static str,
    blurb: &'static str,
    theme: &Theme,
) -> gpui::Stateful<gpui::Div> {
    let id: SharedString = format!("starter-card-{id}").into();
    div()
        .id(id.clone())
        .w(px(240.0))
        .flex()
        .flex_col()
        .gap(px(6.0))
        .p(px(14.0))
        .rounded(px(12.0))
        .border_1()
        .border_color(theme.border)
        .bg(motion::hover_blend(
            &id,
            theme.surface_card,
            theme.surface_raised_hover,
        ))
        .on_hover(motion::hover_listener(id))
        .cursor_pointer()
        .child(
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(8.0))
                .text_size(crate::typography::ui_rems(13.0))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(theme.text)
                .child(
                    crate::icons::icon(icon)
                        .size(px(15.0))
                        .flex_none()
                        .text_color(theme.accent),
                )
                .child(SharedString::from(title)),
        )
        .child(
            div()
                .text_size(crate::typography::ui_rems(12.0))
                .line_height(crate::typography::ui_rems(17.0))
                .text_color(theme.text_muted.opacity(0.8))
                .child(SharedString::from(blurb)),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_starters_hide_without_a_project() {
        assert!(available(false).all(|s| !s.needs_project));
        assert_eq!(available(true).count(), STARTERS.len());
    }

    #[test]
    fn fresh_folder_starters_never_need_a_project() {
        assert!(
            STARTERS
                .iter()
                .all(|s| !(s.fresh_folder && s.needs_project))
        );
    }
}
