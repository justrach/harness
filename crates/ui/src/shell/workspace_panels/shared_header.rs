//! One visible panel shares the native session row without padding tab labels.
use super::*;

impl Shell {
    pub(in crate::shell) fn workspace_uses_shared_header(&self, cx: &App) -> bool {
        matches!(self.route, Route::Chat)
            && !self.session_overview
            && self
                .panel_layout(cx)
                .is_some_and(|layout| layout.header_panel_count() == 1 && !layout.uses_strip())
    }

    pub(in crate::shell) fn workspace_titlebar_buttons_end(&self, cx: &App) -> f32 {
        self.eval_tween(
            self.titlebar_tween,
            cluster_buttons_start(
                cfg!(target_os = "macos"),
                self.fullscreen.unwrap_or(false),
                self.linux_left_caption_count(),
            ),
        ) + CLUSTER_BUTTONS_WIDTH
            + self.chat_history_header_width()
            + self.titlebar_update_slot(cx)
            + self.cloud_header_width(cx)
    }

    pub(super) fn workspace_header_controls_inset(&self, panel_left: f32, cx: &App) -> f32 {
        let session_width = if self.settings.sidebar_collapsed {
            self.workspace_session_quick_width(cx)
        } else {
            0.0
        };
        (self.workspace_titlebar_buttons_end(cx) + session_width + TITLEBAR_CLUSTER_PAD + 4.0
            - panel_left)
            .max(0.0)
    }
}
