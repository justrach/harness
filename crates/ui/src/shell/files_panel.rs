//! Session-owned explorer chrome, independent of the surface tab host.

use super::*;
use crate::settings::{FILES_PANEL_DEFAULT, FILES_PANEL_MAX, FILES_PANEL_MIN};

pub(super) struct FilesPanelResize;

/// Resolve the explorer against the space required by its neighboring panes.
/// `visible` is the sampled animation width; the preferred width determines
/// the breakpoint so an opening drawer never changes modes halfway through.
#[derive(Debug, Clone, Copy, PartialEq)]
struct FilesPanelLayout {
    width: f32,
    reserved: f32,
    overlay: bool,
}

fn files_panel_layout(
    viewport: f32,
    sidebar: f32,
    preferred: f32,
    visible: f32,
    surfaces_open: bool,
    expanded: bool,
) -> FilesPanelLayout {
    let available = (viewport - sidebar).max(0.0);
    let content_min = if surfaces_open {
        RIGHT_PANE_MIN + if expanded { 0.0 } else { CHAT_PANEL_MIN }
    } else {
        CHAT_PANEL_MIN
    };
    let overlay = available < preferred + content_min;
    let max_width = if overlay {
        viewport.max(0.0)
    } else {
        (available - content_min).max(0.0)
    };
    let width = visible.max(0.0).min(max_width);
    FilesPanelLayout {
        width,
        reserved: if overlay { 0.0 } else { width },
        overlay,
    }
}

impl Shell {
    pub(super) fn files_panel_open(&self, cx: &App) -> bool {
        matches!(self.route, Route::Chat)
            && !self.active_chat.is_empty()
            && self.panels.get(&self.panel_key(cx)).files_open
    }

    fn files_layout(&self, visible: f32, cx: &App) -> FilesPanelLayout {
        files_panel_layout(
            self.viewport_width,
            self.eval_tween(self.sidebar_tween, self.sidebar_target()),
            self.settings.files_panel_width,
            visible,
            self.right_pane_open(cx),
            self.right_pane_expanded,
        )
    }

    pub(super) fn files_target(&self, cx: &App) -> f32 {
        self.files_layout(
            if self.files_panel_open(cx) {
                self.settings.files_panel_width
            } else {
                0.0
            },
            cx,
        )
        .width
    }

    pub(super) fn files_visible_width(&self, cx: &App) -> f32 {
        if !matches!(self.route, Route::Chat) || self.active_chat.is_empty() {
            return 0.0;
        }
        self.files_layout(self.eval_tween(self.files_tween, self.files_target(cx)), cx)
            .width
    }

    pub(super) fn files_reserved_width(&self, cx: &App) -> f32 {
        self.files_layout(self.files_visible_width(cx), cx).reserved
    }

    pub(super) fn files_overlay_width(&self, cx: &App) -> f32 {
        let layout = self.files_layout(self.files_visible_width(cx), cx);
        if layout.overlay { layout.width } else { 0.0 }
    }

    fn clear_surface_transitions(&mut self) {
        self.right_tween = None;
        self.main_takeover_tween = None;
        self.right_takeover_content_tween = None;
    }

    pub(super) fn add_files_surface(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.active_chat.is_empty() {
            return;
        }
        let key = self.panel_key(cx);
        if !self.files.contains_key(&key) {
            let files = cx.new(|cx| {
                FilesSurface::new_explorer(
                    self.state.clone(),
                    self.active_chat.clone(),
                    self.settings.files_show_all,
                    cx,
                )
            });
            let owner = key.clone();
            let sub = cx.subscribe_in(
                &files,
                window,
                move |this: &mut Self, _, event, window, cx| match event {
                    FilesEvent::OpenFile(path) if this.panel_key(cx) == owner => {
                        this.add_file_surface(path.clone(), window, cx);
                    }
                    FilesEvent::ShowAllFilesChanged(show_all) => {
                        this.set_files_show_all(*show_all, cx)
                    }
                    _ => cx.notify(),
                },
            );
            self.files.insert(key.clone(), files);
            self.files_subs.insert(key.clone(), sub);
        }
        let from = self.files_visible_width(cx);
        let was_open = self.files_panel_open(cx);
        self.panels.update(&key, |p| p.files_open = true);
        if !was_open {
            self.clear_surface_transitions();
            self.files_tween = Some(WidthTween::new(from, self.files_target(cx)));
        }
        if let Some(files) = self.files.get(&key).cloned() {
            files.update(cx, |files, cx| {
                files.ensure_loaded(cx);
                files.focus_explorer(window, cx);
            });
        }
        self.composer
            .update(cx, |composer, _| composer.focus_pending = false);
        cx.notify();
    }

    pub(super) fn toggle_files_panel(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.files_panel_open(cx) {
            self.add_files_surface(window, cx);
            return;
        }
        let from = self.files_visible_width(cx);
        self.panels
            .update(&self.panel_key(cx), |p| p.files_open = false);
        self.clear_surface_transitions();
        self.files_tween = Some(WidthTween::new(from, 0.0));
        window.focus(&self.composer.focus_handle(cx), cx);
        if self.right_pane_open(cx) {
            self.focus_right_file_editor(self.resolved_right_active(cx), window, cx);
        }
        cx.notify();
    }

    pub(super) fn on_files_panel_drag(
        &mut self,
        event: &gpui::DragMoveEvent<FilesPanelResize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.settings.files_panel_width = (f32::from(window.viewport_size().width)
            - f32::from(event.event.position.x))
        .clamp(FILES_PANEL_MIN, FILES_PANEL_MAX);
        self.files_tween = None;
        self.clear_surface_transitions();
        self.schedule_save(cx);
        cx.notify();
    }

    pub(super) fn render_files_panel(&mut self, cx: &mut Context<Self>) -> AnyElement {
        if !matches!(self.route, Route::Chat)
            || self.active_chat.is_empty()
            || (!self.files_panel_open(cx) && !self.tween_active(self.files_tween))
        {
            return Empty.into_any_element();
        }
        let theme = Theme::of(cx).clone();
        let content = self.files.get(&self.panel_key(cx)).cloned();
        if let Some(files) = &content {
            files.update(cx, |files, cx| files.ensure_loaded(cx));
        }
        let target = self.files_target(cx);
        let content_width =
            stable_panel_content_width(target, self.active_tween_endpoints(self.files_tween));
        let overlay = self.files_layout(target, cx).overlay;
        let inner = div()
            .w(px(content_width))
            .h_full()
            .pt(px(Theme::TITLEBAR_HEIGHT))
            .occlude()
            .border_l_1()
            .border_color(theme.border)
            .bg(theme.bg)
            .children(content);
        div()
            .id("files-panel")
            .h_full()
            .flex_none()
            .relative()
            .when(overlay, |panel| panel.absolute().right_0().top_0())
            .child(
                div()
                    .h_full()
                    .w(px(self.files_visible_width(cx)))
                    .overflow_hidden()
                    .child(inner),
            )
            .when(
                self.files_panel_open(cx) && !self.tween_active(self.files_tween),
                |panel| {
                    panel.child(
                        self.resize_handle(
                            "files-panel-resize",
                            || FilesPanelResize,
                            |shell, _| shell.settings.files_panel_width = FILES_PANEL_DEFAULT,
                            cx,
                        )
                        .left(px(-PANE_RESIZE_HITBOX_HALF_WIDTH)),
                    )
                },
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{AppContext, TestAppContext};

    #[test]
    fn files_layout_reserves_space_or_overlays_without_squeezing_the_chat() {
        let docked = files_panel_layout(1400.0, 256.0, 286.0, 286.0, true, false);
        assert_eq!(
            docked,
            FilesPanelLayout {
                width: 286.0,
                reserved: 286.0,
                overlay: false
            }
        );
        let narrow = files_panel_layout(1100.0, 256.0, 286.0, 286.0, true, false);
        assert_eq!(
            narrow,
            FilesPanelLayout {
                width: 286.0,
                reserved: 0.0,
                overlay: true
            }
        );
        assert_eq!(right_pane_max_width(1100.0 - narrow.reserved, 256.0), 544.0);
        // Without a surface, the same window can dock Files beside the chat.
        assert!(!files_panel_layout(1100.0, 256.0, 286.0, 286.0, false, false).overlay);
        // Takeover may collapse the chat but reserves room for Files.
        let expanded = files_panel_layout(1100.0, 256.0, 286.0, 286.0, true, true);
        assert!(!expanded.overlay);
        assert_eq!(
            right_pane_takeover_width(1100.0 - expanded.reserved, 256.0),
            558.0
        );
    }

    #[test]
    fn files_layout_keeps_its_mode_through_animation_and_clamps_tiny_windows() {
        for width in [0.0, 1.0, 140.0, 286.0] {
            let layout = files_panel_layout(1100.0, 256.0, 286.0, width, true, false);
            assert!(layout.overlay);
            assert_eq!(layout.width, width);
            assert_eq!(layout.reserved, 0.0);
        }
        for viewport in [0.0, 120.0, 280.0, 600.0, 1000.0, 1600.0] {
            for sidebar in [0.0, 256.0, 400.0] {
                for surfaces in [false, true] {
                    for expanded in [false, true] {
                        let layout =
                            files_panel_layout(viewport, sidebar, 286.0, 286.0, surfaces, expanded);
                        assert!(layout.width >= 0.0 && layout.width <= viewport);
                        assert!(layout.reserved >= 0.0 && layout.reserved <= layout.width);
                        if !layout.overlay {
                            let content = viewport - sidebar - layout.reserved;
                            let required = if surfaces {
                                RIGHT_PANE_MIN + if expanded { 0.0 } else { CHAT_PANEL_MIN }
                            } else {
                                CHAT_PANEL_MIN
                            };
                            assert!(content >= required);
                        }
                    }
                }
            }
        }
    }

    #[gpui::test]
    fn explorer_and_editor_panels_have_independent_session_lifetimes(cx: &mut TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
            crate::app_menus::init(cx);
        });
        let window = cx.add_window(|_, cx| {
            let state = cx.new(|_| AppState::new());
            Shell::new(
                state,
                EngineBootConfig {
                    data_dir: dir.path().into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    workos_client_id: None,
                    default_harness: zeron_proto::HarnessId::Mock,
                },
                cx,
            )
        });
        window
            .update(cx, |shell, window, cx| {
                shell.add_files_surface(window, cx);
                assert!(
                    shell.files.is_empty(),
                    "the new-session canvas has no explorer"
                );
                shell.active_chat = "first".into();
                shell.add_files_surface(window, cx);
                let explorer = shell.files["first"].entity_id();
                assert!(shell.files_panel_open(cx));
                assert!(!shell.right_pane_open(cx));
                assert!(shell.right_surface_rows(cx).is_empty());
                shell.add_files_surface(window, cx);
                assert_eq!(shell.files["first"].entity_id(), explorer);
                shell.add_file_surface("src/main.rs".into(), window, cx);
                shell.add_file_surface("src/main.rs".into(), window, cx);
                assert_eq!(shell.file_surfaces.len(), 1);
                assert_eq!(shell.right_surface_rows(cx).len(), 1);
                assert!(shell.right_pane_open(cx));
                shell.toggle_files_panel(window, cx);
                assert!(!shell.files_panel_open(cx));
                assert!(shell.right_pane_open(cx));
                assert_eq!(shell.file_surfaces.len(), 1);
                assert!(shell.pending_file_closes.is_empty());
                shell.active_chat = "second".into();
                assert!(!shell.files_panel_open(cx));
                shell.add_files_surface(window, cx);
                assert_ne!(shell.files["second"].entity_id(), explorer);
                shell.active_chat = "first".into();
                assert!(!shell.files_panel_open(cx));
                shell.add_files_surface(window, cx);
                assert_eq!(shell.files["first"].entity_id(), explorer);
                shell.route = Route::Settings(SettingsSection::Files);
                assert!(!shell.files_panel_open(cx));
                assert_eq!(shell.files_reserved_width(cx), 0.0);
                shell.route = Route::Chat;
                assert!(shell.files_panel_open(cx));
            })
            .unwrap();
    }
}
