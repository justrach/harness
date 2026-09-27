//! Opening a split without losing the active session's destination.

use super::*;

impl Shell {
    /// Split and show `open` in the new, focused pane (`None` = a fresh
    /// new-session canvas, Ghostty's new surface).
    pub(in crate::shell) fn split_chat_opening(
        &mut self,
        axis: SplitAxis,
        open: Option<String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !matches!(self.route, Route::Chat) {
            return;
        }
        // A split is always a split, however narrow (Ghostty's rule): ⌘T is
        // the way to a tab. Turning a narrow ⌘D into a tab read as panes
        // jumping into tabs of their own (user report, 2026-09-26).
        let selected = self.state.read(cx).selected_chat.clone();
        // Dragging the chat you are in moves it; the pane it leaves empties.
        let parked = selected.clone().filter(|id| open.as_ref() != Some(id));
        let project = self.settings.space_filter.clone();
        let mut draft = self.current_canvas_draft(cx);
        // The global project picker can have moved since this session opened.
        // Split the active session's destination, not that unrelated pick.
        // An empty canvas still inherits its own explicit folder selection.
        if let Some(chat) = self.state.read(cx).selected_chat_row() {
            draft.target = Some(crate::pickers::CanvasTarget {
                space: chat.space_id.clone(),
                no_project: chat.space_id.is_none(),
                device: Some(chat.device_id.clone()),
            });
        }
        // Split a copy: a refused split (at the cap, or across axes) must
        // leave the existing layout alone, not drop every pane.
        let Some(mut split) = ChatSplit::split(self.chat_split.clone(), axis, parked, project)
        else {
            return;
        };
        // The pane left behind keeps its picks, and a fresh canvas starts
        // from them — never from whichever canvas was picked in last.
        split.drafts[split.focus - 1] = Some(draft.clone());
        self.chat_split = Some(split);
        self.chat_split_selected = None;
        let fresh = open.is_none();
        self.state.update(cx, |s, cx| s.select_chat(open, cx));
        self.adopt_canvas_draft(fresh.then_some(draft), cx);
        self.sync_chat_panes(cx);
        window.focus(&self.composer.focus_handle(cx), cx);
        cx.notify();
    }
}

#[cfg(test)]
mod tests;
