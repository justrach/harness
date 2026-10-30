//! Every ⌘W chat close asks whether to archive the session or just close it.
//! The answer applies only to that close, not the archive-on-close setting
//! used by ✕ buttons. The close-without-archiving shortcut (⌘⌥W) never asks.

use super::*;

#[cfg(test)]
mod tests;

/// The dialog's copy, given the two shortcuts as displayed.
pub(super) fn archive_choice_copy(close: &str, close_only: &str) -> (String, String) {
    (
        format!("Close this chat with {close}?"),
        format!(
            "Just close it to keep it in the sidebar, or archive it to move an idle session \
             to the archived shelf. This choice applies only to this close. Sessions that \
             are running, waiting for input, or still open elsewhere are never archived. \
             {close_only} always just closes without asking."
        ),
    )
}

impl Shell {
    /// ⌘W on a chat pane, tab or the last session always asks first,
    /// regardless of any saved archive-on-close preference.
    pub(crate) fn close_chat_view_by_shortcut(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.state.read(cx).selected_chat.is_some() {
            self.archive_choice_prompt = true;
            cx.notify();
            return false;
        }
        self.close_chat_view_with_archive(false, window, cx)
    }

    /// Apply the answer to this close only; leave the ✕-button setting alone.
    pub(crate) fn choose_close_archiving(
        &mut self,
        archive: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !std::mem::take(&mut self.archive_choice_prompt) {
            return false;
        }
        self.close_chat_view_with_archive(archive, window, cx)
    }

    /// Escape: nothing closes and nothing is saved; the next ⌘W asks again.
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
            .child(popover::dialog_title(theme, &title))
            .child(div().mt(px(6.0)).child(popover::dialog_body(theme, body)))
            .child(
                div()
                    .mt(px(16.0))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        popover::btn_ghost(theme, "Cancel", "archive-choice-cancel")
                            .id("archive-choice-cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dismiss_archive_choice(cx);
                            })),
                    )
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
