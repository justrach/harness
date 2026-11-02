//! A parked panel keeps the same writing surface as the live composer. It is
//! deliberately read-only: the shell activates that panel before any edit or
//! send can reach the one authoritative composer.
use super::*;

#[derive(Clone, Copy, PartialEq)]
pub(crate) struct InactiveComposerLayout {
    pub width: f32,
    pub expanded: bool,
    pub width_changed_at: Option<Instant>,
}

#[derive(Clone, Default, PartialEq)]
pub(crate) struct InactiveComposerSnapshot {
    pub input: crate::pickers::CanvasInput,
    pub harness: Option<HarnessId>,
    pub model: String,
    pub reasoning: String,
    pub device: String,
    pub dictation: bool,
    pub running: bool,
    pub layout: Option<InactiveComposerLayout>,
}

pub(crate) struct InactiveComposer {
    input: Entity<ComposerInput>,
    snapshot: InactiveComposerSnapshot,
    width: f32,
    expanded: bool,
    surface: crate::new_thread_background_mask::SurfaceBounds,
    settle_task: Option<Task<()>>,
}

impl InactiveComposer {
    pub(crate) fn new(cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| {
            let mut input =
                ComposerInput::with_context("Do anything…", MESSAGE_COMPOSER_CONTEXT, cx);
            input.enable_mentions();
            input.read_only = true;
            input
        });
        Self {
            input,
            snapshot: Default::default(),
            width: COMPOSER_MAX_WIDTH,
            expanded: false,
            surface: Default::default(),
            settle_task: None,
        }
    }

    pub(crate) fn update_snapshot(
        &mut self,
        snapshot: InactiveComposerSnapshot,
        width: f32,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot == snapshot && (self.width - width).abs() < 0.5 {
            return;
        }
        if self.snapshot.input.text != snapshot.input.text {
            self.input.update(cx, |input, cx| {
                input.set_text(snapshot.input.text.clone(), cx)
            });
        }
        self.snapshot = snapshot;
        self.width = width;
        cx.notify();
    }

    #[cfg(test)]
    pub(crate) fn surface_bounds(&self) -> Option<Bounds<Pixels>> {
        self.surface.get()
    }

    pub(crate) fn layout(&self) -> InactiveComposerLayout {
        InactiveComposerLayout {
            width: self.width,
            expanded: self.expanded,
            width_changed_at: self
                .snapshot
                .layout
                .filter(|layout| (layout.width - self.width).abs() < 0.5)
                .and_then(|layout| layout.width_changed_at),
        }
    }

    fn utility(glyph: &'static str, theme: &Theme) -> gpui::Div {
        div()
            .size(px(28.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .child(
                crate::icons::icon(glyph)
                    .size(px(18.0))
                    .text_color(theme.text_muted),
            )
    }

    fn attachment_strip(&self, theme: &Theme) -> Option<gpui::Div> {
        if self.snapshot.input.stage.is_empty() {
            return None;
        }
        Some(
            div()
                .w_full()
                .flex_none()
                .flex()
                .flex_wrap()
                .gap(px(STRIP_GAP))
                .px(px(STRIP_PAD_X))
                .pt(px(STRIP_PAD_TOP))
                .children(self.snapshot.input.stage.iter().map(|attachment| {
                    let frame = div()
                        .id(SharedString::from(format!(
                            "inactive-composer-att-{}",
                            attachment.id
                        )))
                        .size(px(STRIP_THUMB))
                        .flex_none()
                        .rounded(px(8.0))
                        .overflow_hidden()
                        .border_1()
                        .border_color(crate::theme::hairline(0.10));
                    if let Some(image) = attachment.image.clone() {
                        frame.child(
                            img(image)
                                .w(px(STRIP_THUMB - 2.0))
                                .h(px(STRIP_THUMB - 2.0))
                                .rounded(px(7.0))
                                .object_fit(ObjectFit::Cover),
                        )
                    } else if attachment.unavailable.is_some() {
                        frame
                            .w(px(MISSING_ATTACHMENT_WIDTH))
                            .max_w_full()
                            .bg(crate::theme::ink(0.035))
                            .flex()
                            .flex_col()
                            .justify_center()
                            .gap(px(3.0))
                            .px(px(10.0))
                            .aria_label(format!("{} — Needs reattaching", attachment.name))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(px(11.0))
                                    .text_color(theme.text)
                                    .child(attachment.name.clone()),
                            )
                            .child(
                                div()
                                    .text_size(px(10.0))
                                    .text_color(theme.text_muted)
                                    .child("Needs reattaching"),
                            )
                    } else {
                        frame
                            .bg(crate::theme::ink(0.035))
                            .flex()
                            .flex_col()
                            .items_center()
                            .justify_center()
                            .gap(px(3.0))
                            .px(px(4.0))
                            .child(
                                crate::icons::icon(crate::icons::DOCUMENT)
                                    .size(px(18.0))
                                    .text_color(theme.text_muted),
                            )
                            .child(
                                div()
                                    .w_full()
                                    .text_center()
                                    .truncate()
                                    .text_size(px(9.5))
                                    .text_color(theme.text_muted)
                                    .child(attachment.name.clone()),
                            )
                    }
                })),
        )
    }
}

impl Render for InactiveComposer {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let pill_width = (self.width - 2.0 * Theme::SPACE_LG - PILL_BORDER_V).max(1.0);
        let compact_input_width = docked_compact_input_width(self.width, self.snapshot.dictation);
        let mut style = window.text_style();
        style.font_family = theme.font_sans.clone();
        style.font_size = crate::typography::ui_rems(INPUT_TEXT_SIZE).into();
        style.color = if self.snapshot.input.text.is_empty() {
            theme.text_muted
        } else {
            theme.text
        };
        // Measure with the same shaped input and compact capacity as the live
        // composer. Explicit newlines and wrapping therefore retain their
        // height even before this parked panel has ever received focus.
        self.input.update(cx, |input, cx| {
            input.layout_text(px(compact_input_width), &style, window, cx);
        });
        let parked_layout = self
            .snapshot
            .layout
            .filter(|layout| (layout.width - self.width).abs() < 0.5);
        let resize_remaining = parked_layout
            .and_then(|layout| layout.width_changed_at)
            .and_then(|changed| {
                Duration::from_millis(RESIZE_SETTLE_MS).checked_sub(changed.elapsed())
            });
        if let Some(remaining) = resize_remaining
            && self.settle_task.is_none()
        {
            self.settle_task = Some(cx.spawn(async move |this, cx| {
                cx.background_executor()
                    .timer(remaining + Duration::from_millis(20))
                    .await;
                this.update(cx, |preview, cx| {
                    preview.settle_task = None;
                    cx.notify();
                })
                .ok();
            }));
        }
        self.expanded = composer_flip(
            parked_layout.map_or(self.expanded, |layout| layout.expanded),
            self.input.read(cx).measured_text_width(),
            compact_input_width - 8.0,
            self.input.read(cx).has_newline(),
            resize_remaining.is_some(),
        );
        if self.expanded {
            self.input.update(cx, |input, cx| {
                input.layout_text(px((pill_width - 32.0).max(1.0)), &style, window, cx);
            });
        }
        let content_height = self.input.read(cx).measured_content_height();
        let base_height = docked_composer_height(self.expanded, content_height);
        let strip_height = staged_attachment_strip_height(&self.snapshot.input.stage, pill_width);
        let textarea_height = base_height - PILL_BORDER_V - ACTIONS_ROW_HEIGHT;
        self.input.update(cx, |input, _| {
            let height = if self.expanded {
                (textarea_height - TEXTAREA_PAD_V).max(0.0)
            } else {
                INPUT_LINE_HEIGHT
            };
            input.viewport_height = Some(height);
            input.settled_viewport_height = Some(height);
            input.resizing = false;
            input.overflow_top_padding = if self.expanded { 16.0 } else { 0.0 };
        });
        let utilities = div()
            .flex_none()
            .flex()
            .items_center()
            .gap(px(ACTION_UTILITY_GAP))
            .child(Self::utility(crate::icons::PAPERCLIP, &theme))
            .when(self.snapshot.dictation, |row| {
                row.child(Self::utility(crate::icons::MICROPHONE, &theme))
            });
        let has_input =
            !self.snapshot.input.text.trim().is_empty() || !self.snapshot.input.stage.is_empty();
        let stop = self.snapshot.running && !has_input;
        let send = div()
            .size(px(28.0))
            .flex_none()
            .rounded_full()
            .bg(theme.accent)
            .flex()
            .items_center()
            .justify_center()
            .when(!stop && !has_input, |button| button.opacity(0.35))
            .when(stop, |button| {
                button.child(
                    div()
                        .size(px(11.0))
                        .rounded(px(3.0))
                        .bg(theme.on_primary_accent()),
                )
            })
            .when(!stop, |button| {
                button.child(
                    crate::icons::icon(crate::icons::ARROW_UP)
                        .size(px(14.0))
                        .text_color(theme.on_primary_accent()),
                )
            });
        let pill = div()
            .id("inactive-composer-surface")
            .relative()
            .h(px(base_height + strip_height))
            .rounded(px(COMPOSER_RADIUS))
            .border_1()
            .border_color(theme.border)
            .bg(theme.composer_bg())
            .shadow(theme.composer_shadows())
            .overflow_hidden()
            .flex()
            .flex_col()
            .children(self.attachment_strip(&theme));
        let pill = if self.expanded {
            pill.child(
                div()
                    .h(px(textarea_height))
                    .flex_none()
                    .overflow_hidden()
                    .px(px(16.0))
                    .pt(px(16.0))
                    .pb(px(4.0))
                    .child(self.input.clone()),
            )
            .child(
                div()
                    .absolute()
                    .left_0()
                    .right_0()
                    .bottom_0()
                    .h(px(ACTIONS_ROW_HEIGHT))
                    .flex()
                    .items_center()
                    .gap(px(ACTION_PRIMARY_GAP))
                    .px(px(12.0))
                    .pt(px(2.0))
                    .pb(px(ACTIONS_BOTTOM_PAD))
                    .child(div().flex_1().child(utilities))
                    .child(send),
            )
        } else {
            pill.justify_end().child(
                div()
                    .h(px(COMPACT_TOTAL_HEIGHT - PILL_BORDER_V))
                    .flex()
                    .items_center()
                    .child(div().pl(px(8.0)).child(utilities))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .px(px(8.0))
                            .child(self.input.clone()),
                    )
                    .child(
                        div()
                            .flex_none()
                            .pl(px(ACTION_PRIMARY_GAP))
                            .pr(px(8.0))
                            .child(send),
                    ),
            )
        };
        let measured = self.surface.clone();
        let pill = div().relative().child(pill).child(
            gpui::canvas(
                move |bounds, _, _| measured.set(Some(bounds)),
                |_, _, _, _| {},
            )
            .absolute()
            .inset_0(),
        );
        let mut model = div()
            .min_w_0()
            .max_w(px(248.0))
            .flex()
            .items_center()
            .gap(px(4.0))
            .text_size(crate::typography::ui_rems(12.0))
            .text_color(theme.text);
        if let Some(harness) = self.snapshot.harness {
            let (glyph, tint) = crate::pickers::harness_brand_icon(harness);
            model = model.child(
                crate::icons::icon(glyph)
                    .size(px(14.0))
                    .text_color(tint.unwrap_or(theme.text_muted)),
            );
        }
        model = model.child(
            div()
                .min_w_0()
                .truncate()
                .child(self.snapshot.model.clone()),
        );
        if !self.snapshot.reasoning.is_empty() {
            model = model.child(
                div()
                    .flex_none()
                    .text_color(theme.text_muted)
                    .child(self.snapshot.reasoning.clone()),
            );
        }
        model = model.child(
            crate::icons::icon(crate::icons::ALT_ARROW_DOWN)
                .size(px(10.0))
                .text_color(theme.text_muted),
        );
        let footer = div()
            .h(px(SESSION_FOOTER_HEIGHT))
            .mb(px(-Theme::SPACE_SM))
            .px(px(10.0))
            .flex()
            .items_center()
            .gap(px(4.0))
            .child(model)
            .when(!self.snapshot.device.is_empty(), |row| {
                row.child(
                    div()
                        .debug_selector(|| "inactive-composer-device-control".into())
                        .min_w(px(crate::pickers::DEVICE_SELECTOR_MIN_WIDTH))
                        .max_w(px(280.0))
                        .flex()
                        .items_center()
                        .gap(px(4.0))
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.text_muted)
                        .child(
                            crate::icons::icon(crate::icons::MONITOR)
                                .size(px(12.0))
                                .flex_none()
                                .text_color(theme.text_muted),
                        )
                        .child(
                            div()
                                .min_w_0()
                                .truncate()
                                .child(self.snapshot.device.clone()),
                        )
                        .child(
                            crate::icons::icon(crate::icons::ALT_ARROW_DOWN)
                                .debug_selector(|| "inactive-composer-device-caret".into())
                                .size(px(12.0))
                                .flex_none()
                                .text_color(theme.text_muted),
                        ),
                )
            })
            .child(div().flex_1());
        div()
            .w_full()
            .max_w(px(self.width))
            .mx_auto()
            .flex()
            .flex_col()
            .gap(px(Theme::SPACE_SM))
            .px(px(Theme::SPACE_LG))
            .pb(px(Theme::SPACE_LG))
            .child(pill)
            .child(footer)
    }
}
