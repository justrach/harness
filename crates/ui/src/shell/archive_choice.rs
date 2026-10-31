//! The first ⌘W chat close asks whether to archive the session or just close it.
//! The answer becomes the archive-on-close default for ⌘W and ✕ buttons.
//! The close-without-archiving shortcut (⌘⌥W) and ✕ buttons never ask.

use super::*;

#[cfg(test)]
mod tests;

/// The dialog's copy, given the two shortcuts as displayed.
pub(super) fn archive_choice_copy(close: &str, close_only: &str) -> (String, String) {
    (
        format!("What should {close} do when you close a chat?"),
        format!(
            "Just close it to keep it in the sidebar, or archive it to move an idle session \
             to the archived shelf. Your choice becomes the default for closing chats. \
             You can change it in Settings \u{2192} Archived sessions. Sessions that are \
             running, waiting for input, or still open elsewhere are never archived. \
             {close_only} always just closes without asking."
        ),
    )
}

impl Shell {
    /// The first ⌘W chat close asks for a default. Later closes follow the
    /// saved archive-on-close preference without asking again.
    pub(crate) fn close_chat_view_by_shortcut(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !settings::archive_on_close_chosen(cx) && self.state.read(cx).selected_chat.is_some() {
            self.archive_choice_prompt = true;
            cx.notify();
            return false;
        }
        self.close_chat_view_with_archive(settings::archive_sessions_on_close(cx), window, cx)
    }

    /// Save the answer as the close default, then apply it to this close.
    pub(crate) fn choose_close_archiving(
        &mut self,
        archive: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !std::mem::take(&mut self.archive_choice_prompt) {
            return false;
        }
        settings::set_archive_sessions_on_close(archive, cx);
        self.sync_independent_settings(cx);
        self.close_chat_view_with_archive(archive, window, cx)
    }

    /// Dismiss or Escape: nothing closes and nothing is saved; the next ⌘W asks again.
    pub(super) fn dismiss_archive_choice(&mut self, cx: &mut Context<Self>) -> bool {
        if !std::mem::take(&mut self.archive_choice_prompt) {
            return false;
        }
        cx.notify();
        true
    }

    pub(super) fn render_archive_choice_dialog(
        &self,
        viewport: gpui::Size<Pixels>,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if !self.archive_choice_prompt {
            return None;
        }
        let (close, close_only) = settings::close_shortcut_badges(cx);
        let (title, body) = archive_choice_copy(&close, &close_only);
        let card = popover::dialog_card(theme)
            .relative()
            .debug_selector(|| "archive-choice-card".into())
            .child(
                div()
                    .id("archive-choice-dismiss")
                    .debug_selector(|| "archive-choice-dismiss".into())
                    .absolute()
                    .top(px(8.0))
                    .right(px(8.0))
                    .size(px(20.0))
                    .rounded(px(5.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .cursor_pointer()
                    .role(gpui::Role::Button)
                    .aria_label("Dismiss close preference setup")
                    .hover(|style| style.bg(theme.ink(0.08)))
                    .on_click(cx.listener(|this, _, _, cx| {
                        cx.stop_propagation();
                        this.dismiss_archive_choice(cx);
                    }))
                    .child(
                        crate::icons::icon(crate::icons::CLOSE)
                            .size(px(12.0))
                            .text_color(theme.text_muted),
                    ),
            )
            .child(popover::dialog_title(theme, &title).mt(px(12.0)))
            .child(div().mt(px(6.0)).child(popover::dialog_body(theme, body)))
            .child(
                div()
                    .mt(px(16.0))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        popover::btn_ghost(theme, "Archive it", "archive-choice-archive")
                            .id("archive-choice-archive")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.choose_close_archiving(true, window, cx);
                            })),
                    )
                    .child(
                        popover::btn_primary(theme, "Just close it")
                            .id("archive-choice-close")
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.choose_close_archiving(false, window, cx);
                            })),
                    ),
            )
            .into_any_element();
        Some(popover::modal("archive-choice-dialog", viewport, card))
    }
}
