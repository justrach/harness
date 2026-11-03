//! Write: the composer's draft on a full page, for messages long enough to
//! want room. The page edits the composer's own input entity (so the draft,
//! its undo history and its references are the same text), draws markdown as
//! it is typed without hiding any of it (`crate::write_markdown`), and sends
//! through the composer's own send path. It takes over the chat pane, not a
//! new window; the shell swaps it in for the transcript and the composer.

use super::*;
use crate::write_markdown::WriteStyle;

actions!(
    composer,
    [
        /// Open the draft on the Write page, or bring it back to the composer.
        ToggleWriteDocument
    ]
);

/// Key context of the page around the input: Enter is a newline there and
/// the platform modifier plus Enter sends, whatever the composer's setting.
pub(super) const WRITE_DOCUMENT_CONTEXT: &str = "WriteDocument";

/// Body type on the page, at the default interface size.
pub const WRITE_TEXT_SIZE: f32 = 18.0;
/// Baseline to baseline, as a multiple of the type size.
const LINE_HEIGHT_RATIO: f32 = 1.6;
/// The text column: about 70 characters of the serif at the body size.
pub const PAGE_MAX_WIDTH: f32 = 720.0;
const PAGE_SIDE_PADDING: f32 = 40.0;

/// The shortcut that opens and closes the page, in the stored spelling
/// (`mod` is Cmd on macOS, Ctrl elsewhere). Off macOS, Ctrl+Shift+E already
/// splits a chat pane down.
pub fn toggle_combo() -> &'static str {
    if cfg!(target_os = "macos") {
        "mod-shift-e"
    } else {
        "mod-alt-e"
    }
}

pub(super) fn bindings() -> Vec<KeyBinding> {
    let page = Some("WriteDocument > MessageComposer");
    vec![
        KeyBinding::new(
            &platform_combo(toggle_combo()),
            ToggleWriteDocument,
            Some(MESSAGE_COMPOSER_CONTEXT),
        ),
        KeyBinding::new("enter", MessageNewlineOrAccept, page),
        KeyBinding::new(&platform_combo("mod-enter"), Submit, page),
    ]
}

/// The page's typeface: New York by default, the interface sans from "Aa".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WriteFace {
    pub serif: bool,
}

impl WriteFace {
    pub fn family(self, cx: &App) -> SharedString {
        if self.serif {
            serif_family(cx)
        } else {
            Theme::of(cx).font_sans.clone()
        }
    }

    pub(super) fn from_settings(cx: &App) -> Self {
        Self {
            serif: !crate::settings::with_current(cx, |settings| settings.write_sans),
        }
    }
}

/// Serif families in order of preference. New York is macOS's system serif,
/// but GPUI's font list leaves out its dot-prefixed family, so on today's
/// macOS the page lands on Charter; the rest ship with macOS too and read
/// well at the page's size.
const SERIF_FAMILIES: [&str; 5] = [
    ".New York",
    "New York",
    "Iowan Old Style",
    "Charter",
    "Georgia",
];

/// The first installed family of `SERIF_FAMILIES`. Pure, so the order is
/// testable without the platform's font list.
pub(super) fn pick_serif<'a>(installed: impl IntoIterator<Item = &'a str>) -> Option<&'static str> {
    let installed: HashSet<&str> = installed.into_iter().collect();
    SERIF_FAMILIES
        .into_iter()
        .find(|family| installed.contains(family))
}

fn serif_family(cx: &App) -> SharedString {
    static SERIF: std::sync::OnceLock<Option<&'static str>> = std::sync::OnceLock::new();
    SERIF
        .get_or_init(|| {
            let names = cx.text_system().all_font_names();
            pick_serif(names.iter().map(String::as_str))
        })
        .map(SharedString::new_static)
        .unwrap_or_else(|| Theme::of(cx).font_sans.clone())
}

/// Ramp of the page's top and bottom fades while it scrolls.
pub(super) const PAGE_FADE_BAND: f32 = 28.0;

/// Which page edges have text scrolled past them.
pub(super) fn page_fade_edges(scroll_top: f32, visible: f32, content: f32) -> (bool, bool) {
    (scroll_top > 0.5, scroll_top + visible < content - 0.5)
}

pub(super) fn body_line_height(font_size: Pixels) -> Pixels {
    px((f32::from(font_size) * LINE_HEIGHT_RATIO).round())
}

/// Type size and row height of a heading line. The row is tall enough to
/// leave air above the heading as well as below it.
pub(super) fn heading_metrics(level: u8, body: Pixels, body_line: Pixels) -> (Pixels, Pixels) {
    let scale = match level {
        1 => 1.45,
        2 => 1.25,
        _ => 1.1,
    };
    let size = body * scale;
    (size, px((f32::from(size) * 1.55).round()).max(body_line))
}

/// Theme colours the styler needs, read once per layout.
pub(super) struct WritePalette {
    mono: gpui::Font,
    muted: gpui::Hsla,
    faint: gpui::Hsla,
    code_text: gpui::Hsla,
    code_wash: gpui::Hsla,
}

impl WritePalette {
    pub(super) fn new(theme: &Theme) -> Self {
        Self {
            mono: gpui::font(theme.font_mono.clone()),
            muted: theme.text_muted,
            faint: theme.text_faint,
            code_text: theme.code_text,
            code_wash: theme.code_wash,
        }
    }
}

/// Draw one run with the styles covering it, in drawing order (line styles,
/// then inline ones, then markers, whose faint ink wins).
pub(super) fn style_run(
    run: &mut TextRun,
    styles: impl IntoIterator<Item = WriteStyle>,
    palette: &WritePalette,
) {
    for style in styles {
        let mono = run.font.family == palette.mono.family;
        match style {
            WriteStyle::Heading(_) | WriteStyle::Bold if !mono => {
                run.font.weight = gpui::FontWeight::BOLD;
            }
            WriteStyle::Italic if !mono => run.font.style = gpui::FontStyle::Italic,
            WriteStyle::Quote => {
                run.color = palette.muted;
                if !mono {
                    run.font.style = gpui::FontStyle::Italic;
                }
            }
            WriteStyle::Code | WriteStyle::CodeBlock => {
                run.font = palette.mono.clone();
                run.color = palette.code_text;
                run.background_color = Some(palette.code_wash);
            }
            WriteStyle::Marker => run.color = palette.faint,
            _ => {}
        }
    }
}

impl ComposerInput {
    /// Put the draft on the Write page (`Some`) or back in the composer.
    pub(crate) fn set_write_face(&mut self, face: Option<WriteFace>, cx: &mut Context<Self>) {
        if self.write == face {
            return;
        }
        let entering = self.write.is_none() && face.is_some();
        let leaving = self.write.is_some() && face.is_none();
        self.write = face;
        if entering {
            // The page owns its own viewport; the composer's animated budget
            // comes back with its next render.
            self.write_saved_width = self.last_width;
            self.viewport_height = None;
            self.settled_viewport_height = None;
            self.overflow_top_padding = 0.0;
            self.resizing = false;
        }
        if leaving {
            // Measure the composer at its own width again, not the page's.
            self.last_width = self.write_saved_width;
        }
        self.scroll_top = 0.0;
        self.follow_cursor = true;
        self.needs_measure = true;
        self.refresh_projection();
        cx.notify();
    }

    pub(crate) fn write_face(&self) -> Option<WriteFace> {
        self.write
    }
}

impl Composer {
    pub fn write_open(&self) -> bool {
        self.write_open
    }

    pub fn toggle_write(&mut self, cx: &mut Context<Self>) {
        if self.write_open {
            self.close_write(cx);
        } else {
            self.open_write(cx);
        }
    }

    /// Open the draft on the Write page. A question borrowing the input, or
    /// a queued message being edited, keeps the composer.
    pub fn open_write(&mut self, cx: &mut Context<Self>) {
        if self.write_open || self.wizard.is_some() || self.editing_queued.is_some() {
            return;
        }
        self.write_open = true;
        self.follow_up_menu_open = false;
        let face = WriteFace::from_settings(cx);
        self.input
            .update(cx, |input, cx| input.set_write_face(Some(face), cx));
        self.focus_pending = true;
        cx.notify();
    }

    /// Back to the composer, with the text where it was.
    pub fn close_write(&mut self, cx: &mut Context<Self>) {
        if !self.write_open {
            return;
        }
        self.write_open = false;
        self.input
            .update(cx, |input, cx| input.set_write_face(None, cx));
        self.focus_pending = true;
        cx.notify();
    }

    /// After a submit from the page: a sent draft clears the input, and the
    /// page goes with it. A refused send (no engine, blocked) leaves both.
    pub(super) fn close_write_if_sent(&mut self, cx: &mut Context<Self>) {
        if self.write_open && self.input.read(cx).text().is_empty() {
            self.close_write(cx);
        }
    }

    /// Send from the page: the composer's own submit (send, queue or steer,
    /// with attachments), then back to the chat.
    pub fn send_from_write(&mut self, cx: &mut Context<Self>) {
        self.on_submit(cx);
        self.close_write_if_sent(cx);
    }

    pub(super) fn toggle_write_face(&mut self, cx: &mut Context<Self>) {
        let serif = WriteFace::from_settings(cx).serif;
        crate::settings::update(crate::settings::SavePolicy::Immediate, cx, |settings| {
            settings.write_sans = serif;
        });
        let face = WriteFace { serif: !serif };
        self.input.update(cx, |input, cx| {
            if input.write_face().is_some() {
                input.set_write_face(Some(face), cx);
            }
        });
        cx.notify();
    }

    /// The composer's way in: an expand button with the shortcut in its
    /// tooltip.
    pub(super) fn render_write_button(
        &self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let tip: SharedString = format!(
            "Write in full screen  {}",
            crate::settings::badge_combo(toggle_combo())
        )
        .into();
        div()
            .id("composer-write")
            .debug_selector(|| "composer-write".into())
            .role(Role::Button)
            .aria_label("Write in full screen")
            .size(px(28.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded_full()
            .cursor_pointer()
            .bg(motion::hover_blend(
                "composer-write",
                gpui::transparent_black(),
                crate::theme::ink(0.10),
            ))
            .on_hover(motion::hover_listener("composer-write"))
            .tooltip(move |_, cx| cx.new(|_| AppshotActionTooltip(tip.clone())).into())
            .on_click(cx.listener(|this, _, _, cx| this.open_write(cx)))
            .child(
                crate::icons::icon(crate::icons::EXPAND_ARROWS)
                    .size(px(16.0))
                    .text_color(theme.text_muted),
            )
            .into_any_element()
    }

    /// The page, for the shell to put where the transcript was. `top_inset`
    /// clears the window's overlaid titlebar.
    pub fn render_write_page(
        &mut self,
        top_inset: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        if std::mem::take(&mut self.focus_pending) {
            let focus = self.input.focus_handle(cx);
            window.focus(&focus, cx);
        }
        let theme = Theme::of(cx).clone();
        let text = self.input.read(cx).text().to_string();
        let words =
            crate::write_markdown::word_count_label(crate::write_markdown::word_count(&text));
        let serif = self
            .input
            .read(cx)
            .write_face()
            .is_some_and(|face| face.serif);
        let column = |el: gpui::Div| {
            el.w_full()
                .max_w(px(PAGE_MAX_WIDTH + 2.0 * PAGE_SIDE_PADDING))
                .mx_auto()
                .px(px(PAGE_SIDE_PADDING))
        };
        let quiet_button = |id: &'static str| {
            div()
                .id(id)
                .debug_selector(move || id.into())
                .role(Role::Button)
                .h(px(28.0))
                .px(px(8.0))
                .flex()
                .items_center()
                .rounded(px(7.0))
                .cursor_pointer()
                .text_color(theme.text_muted)
                .hover(|el| el.bg(crate::theme::ink(0.06)).text_color(theme.text))
        };
        let shortcut = crate::settings::badge_combo(toggle_combo());
        let top_bar = column(div())
            .flex_none()
            .h(px(44.0))
            .relative()
            .flex()
            .items_center()
            .justify_between()
            .text_size(crate::typography::ui_rems(13.0))
            .child(
                quiet_button("write-done")
                    .ml(px(-8.0))
                    .aria_label("Done, back to the chat")
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child("Done")
                    .tooltip(move |_, cx| {
                        cx.new(|_| {
                            AppshotActionTooltip(
                                format!("Back to the chat  Esc · {shortcut}").into(),
                            )
                        })
                        .into()
                    })
                    .on_click(cx.listener(|this, _, _, cx| this.close_write(cx))),
            )
            .child(
                div()
                    .id("write-words")
                    .debug_selector(|| "write-words".into())
                    .absolute()
                    .left_0()
                    .right_0()
                    .flex()
                    .justify_center()
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(theme.text_faint)
                    .child(words),
            )
            .child(
                quiet_button("write-font")
                    .mr(px(-8.0))
                    .aria_label(if serif {
                        "Use sans-serif type"
                    } else {
                        "Use serif type"
                    })
                    .when(serif, |el| {
                        el.font_family(WriteFace { serif: true }.family(cx))
                            .text_size(crate::typography::ui_rems(16.0))
                    })
                    .when(!serif, |el| {
                        el.font_weight(gpui::FontWeight::MEDIUM)
                            .text_size(crate::typography::ui_rems(14.0))
                    })
                    .child("Aa")
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_write_face(cx))),
            );

        let has_content = composer_has_content(
            &text,
            self.staged().len() + self.staged_appshots().len(),
            self.staged_comments(cx).len(),
        );
        let enabled = has_content && !self.send_blocked(cx);
        let label = match self.button_mode(cx) {
            SendButtonMode::Queue => "Queue",
            _ => "Send",
        };
        let send_hint = crate::settings::badge_combo("mod-enter");
        let send = div()
            .id("write-send")
            .debug_selector(|| "write-send".into())
            .role(Role::Button)
            .aria_label(if label == "Queue" {
                "Queue message"
            } else {
                "Send message"
            })
            .h(px(32.0))
            .px(px(14.0))
            .flex()
            .items_center()
            .gap(px(6.0))
            .rounded_full()
            .text_size(crate::typography::ui_rems(13.0))
            .font_weight(gpui::FontWeight::SEMIBOLD)
            .when(enabled, |el| {
                el.bg(theme.accent)
                    .text_color(theme.on_primary_accent())
                    .cursor_pointer()
                    .hover(|el| el.opacity(0.88))
                    .on_click(cx.listener(|this, _, _, cx| this.send_from_write(cx)))
            })
            .when(!enabled, |el| {
                el.bg(crate::theme::ink(0.08)).text_color(theme.text_faint)
            })
            .child(label)
            .child(
                crate::icons::icon(crate::icons::ARROW_UP)
                    .size(px(13.0))
                    .text_color(if enabled {
                        theme.on_primary_accent()
                    } else {
                        theme.text_faint
                    }),
            );
        let attach = div()
            .id("write-attach")
            .debug_selector(|| "write-attach".into())
            .role(Role::Button)
            .aria_label("Attach files")
            .size(px(32.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded_full()
            .cursor_pointer()
            .hover(|el| el.bg(crate::theme::ink(0.08)))
            .on_click(cx.listener(|this, _, _, cx| this.open_file_picker(cx)))
            .child(
                crate::icons::icon(crate::icons::PAPERCLIP)
                    .size(px(18.0))
                    .text_color(theme.text_muted),
            );
        let failure = self.failure.clone().filter(|_| {
            self.failure_key
                .as_ref()
                .is_none_or(|key| *key == self.current_key)
        });
        let strip = self.render_attachment_strip(&theme, cx);
        let appshot_strip = self.render_appshot_strip(&theme, window, cx);
        let dock = column(div()).flex_none().pb(px(16.0)).child(
            div()
                .relative()
                .flex()
                .flex_col()
                .rounded(px(COMPOSER_RADIUS))
                .border_1()
                .border_color(theme.border)
                .bg(theme.composer_bg())
                .shadow(theme.composer_shadows())
                .children(appshot_strip)
                .children(strip)
                .child(
                    div()
                        .h(px(48.0))
                        .px(px(8.0))
                        .flex()
                        .items_center()
                        .gap(px(8.0))
                        .child(attach)
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(if failure.is_some() {
                                    theme.danger
                                } else {
                                    theme.text_faint
                                })
                                .child(failure.unwrap_or_else(|| {
                                    format!("{send_hint} to {}", label.to_lowercase()).into()
                                })),
                        )
                        .child(send),
                )
                // Completion menus float above the dock, as above the
                // composer.
                .children(self.render_file_mention_popup(&theme, cx))
                .children(self.render_slash_popup(&theme, cx)),
        );

        div()
            .id("write-page")
            .debug_selector(|| "write-page".into())
            .key_context(WRITE_DOCUMENT_CONTEXT)
            .size_full()
            .flex()
            .flex_col()
            .pt(px(top_inset))
            .bg(theme.composer_bg())
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                // The input's own Escape closes an open completion menu first
                // and stops there.
                if event.keystroke.key == "escape"
                    && this.mention.token.is_none()
                    && this.slash.token.is_none()
                {
                    this.close_write(cx);
                    cx.stop_propagation();
                }
            }))
            .child(top_bar)
            .child(
                column(div())
                    .flex_1()
                    .min_h_0()
                    .pt(px(12.0))
                    .pb(px(12.0))
                    .child(self.input.clone()),
            )
            .child(dock)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serif_prefers_new_york_then_other_book_faces() {
        assert_eq!(
            pick_serif(["Geist", "Georgia", ".New York", "Charter"]),
            Some(".New York")
        );
        assert_eq!(pick_serif(["Georgia", "Charter"]), Some("Charter"));
        assert_eq!(pick_serif(["Geist"]), None);
    }

    #[test]
    fn the_page_fades_only_edges_with_text_past_them() {
        assert_eq!(page_fade_edges(0.0, 400.0, 300.0), (false, false));
        assert_eq!(page_fade_edges(0.0, 400.0, 900.0), (false, true));
        assert_eq!(page_fade_edges(500.0, 400.0, 900.0), (true, false));
        assert_eq!(page_fade_edges(200.0, 400.0, 900.0), (true, true));
    }

    #[test]
    fn headings_are_larger_and_their_rows_taller() {
        let body = px(18.0);
        let line = body_line_height(body);
        assert_eq!(line, px(29.0));
        let (h1, h1_line) = heading_metrics(1, body, line);
        let (h2, h2_line) = heading_metrics(2, body, line);
        let (h3, h3_line) = heading_metrics(3, body, line);
        assert!(h1 > h2 && h2 > h3 && h3 > body);
        assert!(h1_line > h2_line && h2_line >= h3_line && h3_line >= line);
    }

    #[test]
    fn markers_draw_faint_over_their_line_style_and_code_is_mono() {
        let theme = Theme::dark();
        let palette = WritePalette::new(&theme);
        let base = TextRun {
            len: 1,
            font: gpui::font("Serif"),
            color: theme.text,
            background_color: None,
            underline: None,
            strikethrough: None,
        };
        let mut marker = base.clone();
        style_run(
            &mut marker,
            [WriteStyle::Heading(1), WriteStyle::Marker],
            &palette,
        );
        assert_eq!(marker.color, theme.text_faint);
        assert_eq!(marker.font.weight, gpui::FontWeight::BOLD);

        let mut code = base.clone();
        style_run(&mut code, [WriteStyle::Code, WriteStyle::Bold], &palette);
        assert_eq!(code.font.family, theme.font_mono);
        assert_eq!(code.color, theme.code_text);
        assert_eq!(code.background_color, Some(theme.code_wash));
        assert_ne!(code.font.weight, gpui::FontWeight::BOLD);

        let mut quote = base;
        style_run(
            &mut quote,
            [WriteStyle::Quote, WriteStyle::Italic],
            &palette,
        );
        assert_eq!(quote.color, theme.text_muted);
        assert_eq!(quote.font.style, gpui::FontStyle::Italic);
    }
}
