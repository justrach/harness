//! Unselected design proposals drawn by the native fixture only. No production behavior.
use super::*;
use gpui::{Bounds, Global, Hsla};

#[derive(Default)]
struct DesignPreview(String);
impl Global for DesignPreview {}

pub(super) fn attention_icon(panel: u64, tab: usize, cx: &App) -> bool {
    panel == 0
        && tab == 1
        && cx
            .try_global::<DesignPreview>()
            .is_some_and(|preview| preview.0.starts_with("attention-"))
}

fn frame(rect: Bounds<Pixels>) -> gpui::Div {
    div()
        .absolute()
        .left(rect.left())
        .top(rect.top())
        .w(rect.size.width)
        .h(rect.size.height)
}

fn cloud_card(theme: &Theme, title: &str, status: &str, color: Hsla, quick: bool) -> AnyElement {
    div()
        .h(px(72.))
        .w_full()
        .flex_none()
        .px(px(12.))
        .rounded(px(10.))
        .bg(theme.surface_raised)
        .flex()
        .items_center()
        .gap(px(10.))
        .child(
            icon(icons::MONITOR)
                .size(px(22.))
                .text_color(theme.text_muted),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .flex()
                .flex_col()
                .gap(px(5.))
                .child(
                    div()
                        .text_size(px(14.))
                        .text_color(theme.text)
                        .truncate()
                        .child(title.to_owned()),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(6.))
                        .text_size(px(12.))
                        .text_color(theme.text_muted)
                        .child(div().size(px(5.)).rounded_full().bg(color))
                        .child(status.to_owned()),
                ),
        )
        .child(if quick {
            div()
                .text_size(px(11.))
                .text_color(theme.text)
                .child("Turn off")
                .into_any_element()
        } else {
            icon(icons::ALT_ARROW_RIGHT)
                .size(px(14.))
                .text_color(theme.text_muted)
                .into_any_element()
        })
        .into_any_element()
}

impl Shell {
    pub fn fixture_reconciliation_design(
        &mut self,
        variant: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        // The harness sets up the synthetic session once. Reset only its layout
        // between proposals, so repeated captures cannot accumulate browsers.
        self.right_tabs.clear();
        self.browsers.clear();
        self.browser_subs.clear();
        self.chat_split = None;
        self.settings.sidebar_compact = false;
        self.settings.sidebar_collapsed = variant == "attention-strip-closed";
        {
            let layout = self.panel_layout_mut(cx);
            layout.axis = SplitAxis::Horizontal;
            layout.panels.truncate(2);
            // A previous proposal may have left one panel.
            if layout.panels.len() < 2 {
                let first = layout.panels[0].id;
                layout.add_panel(first);
            }
            layout.panels[0].tabs = vec![
                workspace_panels::PanelTab::Chat("launch-0".into()),
                workspace_panels::PanelTab::Chat("launch-1".into()),
            ];
            layout.panels[0].active = 0;
            layout.panels[1].tabs = vec![workspace_panels::PanelTab::Chat("launch-2".into())];
            layout.panels[1].active = 0;
        }
        self.focus_workspace_tab(
            0,
            workspace_panels::PanelTab::Chat("launch-0".into()),
            window,
            cx,
        );
        self.composer.update(cx, |composer, cx| {
            composer.set_canvas_input(
                crate::pickers::CanvasInput {
                    text: "Keep the layout calm and make the next step clear.".into(),
                    ..Default::default()
                },
                cx,
            )
        });
        if variant.starts_with("newtab-") {
            self.workspace_new_tab(cx);
            self.focus_workspace_new_tab(window, cx);
            let layout = self.panel_layout_mut(cx);
            let new_tab = layout.panels[0].selected().unwrap().clone();
            layout.panels[0].tabs = vec![new_tab];
            layout.panels[0].active = 0;
        }
        if variant == "attention-strip" || variant == "attention-strip-closed" {
            self.fixture_instrument_strip(window, cx);
        }
        if variant == "attention-single" {
            self.fixture_single_panel_tabs(window, cx);
        }
        if variant == "attention-strip-folder" {
            self.fixture_strip_folder_menu(window, cx);
        }
        cx.set_global(DesignPreview(variant.into()));
        cx.notify();
    }

    pub(super) fn render_reconciliation_design(
        &self,
        window: &mut Window,
        cx: &Context<Self>,
    ) -> Vec<AnyElement> {
        let Some(preview) = cx.try_global::<DesignPreview>() else {
            return vec![];
        };
        let mode = preview.0.as_str();
        let theme = Theme::of(cx);
        let mut result = vec![];
        let bodies = self.fixture_panel_visible_bounds(cx);
        if mode.starts_with("focus-") {
            if let Some(body) = bodies.first().copied() {
                let color = theme.accent;
                let width = match mode {
                    "focus-minimal" => 1.,
                    "focus-loud" => 3.,
                    _ => 2.,
                };
                let mut border = frame(body).rounded(px(10.));
                if mode == "focus-top" {
                    border = border.h(px(2.)).bg(color);
                } else {
                    border = border.border(px(width)).border_color(
                        color.opacity(if mode == "focus-minimal" { 0.65 } else { 1. }),
                    );
                }
                result.push(border.into_any_element());
                if mode == "focus-loud" {
                    result.push(
                        div()
                            .absolute()
                            .left(body.left() + px(1.))
                            .top(body.top() + px(1.))
                            .w(body.size.width - px(2.))
                            .h(px(24.))
                            .rounded_t(px(8.))
                            .bg(color.opacity(0.15))
                            .flex()
                            .justify_end()
                            .items_center()
                            .px(px(10.))
                            .text_size(px(11.))
                            .text_color(theme.text)
                            .child("Active panel")
                            .into_any_element(),
                    );
                }
            }
        }
        if mode.starts_with("attention-") {
            if let Some(bounds) = window.debug_bounds("panel-tab-0-1") {
                let rect = Bounds::new(
                    bounds.origin + gpui::point(px(2.), px(2.)),
                    gpui::size(bounds.size.width - px(4.), px(30.)),
                );
                if mode != "attention-a" && !mode.starts_with("attention-strip") && mode != "attention-single" {
                    result.push(
                        frame(rect)
                            .rounded(px(7.))
                            .bg(theme.warning.opacity(if mode == "attention-c" {
                                0.22
                            } else {
                                0.11
                            }))
                            .into_any_element(),
                    );
                }
            }
        }
        if mode.starts_with("cloud-") {
            let rows = if mode == "cloud-states" { 4 } else { 1 };
            let mut shelf = div()
                .absolute()
                .left(px(12.))
                .bottom(px(56.))
                .w(px(self.settings.sidebar_width - 24.))
                .flex()
                .flex_col()
                .gap(px(8.));
            if rows == 4 {
                for (name, status, color) in [
                    ("Studio computer", "Running", theme.success),
                    ("Build computer", "Paused", theme.text_muted),
                    ("Review computer", "Starting…", theme.accent),
                    ("Test computer", "Needs attention", theme.warning),
                ] {
                    shelf = shelf.child(cloud_card(theme, name, status, color, false));
                }
                shelf = shelf.child(
                    div()
                        .mt(px(3.))
                        .px(px(12.))
                        .text_size(px(12.))
                        .text_color(theme.text_muted)
                        .child("Temporary tool machines · 2 running"),
                );
            } else {
                shelf = shelf.child(cloud_card(
                    theme,
                    if mode == "cloud-c" {
                        "Cloud computers"
                    } else {
                        "Studio computer"
                    },
                    if mode == "cloud-c" {
                        "2 running · 1 paused"
                    } else {
                        "Running"
                    },
                    theme.success,
                    mode == "cloud-b",
                ));
            }
            result.push(shelf.into_any_element());
        }
        if mode.starts_with("newtab-") {
            if let Some(body) = bodies.first().copied() {
                let wide = f32::from(body.size.width) > 400.;
                let mut choices = div()
                    .w_full()
                    .max_w(px(360.))
                    .flex()
                    .flex_col()
                    .gap(px(12.))
                    .child(
                        div()
                            .text_size(px(22.))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .text_color(theme.text)
                            .child("Start here"),
                    );
                for (label, glyph) in [
                    ("New chat", icons::CHAT_ROUND_LINE),
                    ("Browser", icons::GLOBE),
                    ("Terminal", icons::TERMINAL),
                ] {
                    choices = choices.child(
                        div()
                            .h(px(36.))
                            .flex()
                            .items_center()
                            .gap(px(10.))
                            .text_color(theme.text)
                            .text_size(px(14.))
                            .child(icon(glyph).size(px(16.)).text_color(theme.text_muted))
                            .child(label),
                    );
                }
                if mode == "newtab-links" {
                    choices = choices.child(div().h(px(1.)).my(px(6.)).bg(theme.border));
                    for (label, detail, glyph) in [
                        ("Open a folder", "Bring an existing project", icons::FOLDER),
                        (
                            "Import a conversation",
                            "Continue a Codex chat in graff",
                            icons::ARROW_DOWN,
                        ),
                    ] {
                        choices = choices.child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(10.))
                                .py(px(6.))
                                .child(icon(glyph).size(px(16.)).text_color(theme.text_muted))
                                .child(
                                    div()
                                        .flex()
                                        .flex_col()
                                        .gap(px(3.))
                                        .child(
                                            div()
                                                .text_size(px(14.))
                                                .text_color(theme.text)
                                                .child(label),
                                        )
                                        .child(
                                            div()
                                                .text_size(px(12.))
                                                .text_color(theme.text_muted)
                                                .child(detail),
                                        ),
                                ),
                        );
                    }
                } else {
                    let mut tiles = div()
                        .mt(px(6.))
                        .flex()
                        .gap(px(8.))
                        .when(!wide, |el| el.flex_col());
                    for (label, detail, glyph) in [
                        ("Open a folder", "Use a project", icons::FOLDER),
                        ("Import a chat", "From Codex", icons::ARROW_DOWN),
                    ] {
                        tiles = tiles.child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .p(px(12.))
                                .rounded(px(10.))
                                .bg(theme.surface_raised)
                                .flex()
                                .flex_col()
                                .gap(px(8.))
                                .child(icon(glyph).size(px(19.)).text_color(theme.text_muted))
                                .child(div().text_size(px(14.)).text_color(theme.text).child(label))
                                .child(
                                    div()
                                        .text_size(px(12.))
                                        .text_color(theme.text_muted)
                                        .child(detail),
                                ),
                        );
                    }
                    choices = choices.child(tiles);
                }
                choices = choices.child(
                    div()
                        .mt(px(4.))
                        .text_size(px(12.))
                        .text_color(theme.text_muted)
                        .child("Resume a conversation…"),
                );
                result.push(
                    frame(body)
                        .rounded(px(9.))
                        .bg(theme.bg)
                        .flex()
                        .items_center()
                        .justify_center()
                        .p(px(28.))
                        .child(choices)
                        .into_any_element(),
                );
            }
        }
        result
    }
}
