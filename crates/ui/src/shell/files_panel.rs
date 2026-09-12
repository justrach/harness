//! Session-owned explorer chrome, independent of the surface tab host.

use super::*;
use crate::settings::{FILES_PANEL_DEFAULT, FILES_PANEL_MAX, FILES_PANEL_MIN};

pub(super) struct FilesPanelResize;

impl Shell {
    pub(super) fn files_panel_open(&self, cx: &App) -> bool {
        matches!(self.route, Route::Chat)
            && !self.active_chat.is_empty()
            && self.panels.get(&self.panel_key(cx)).files_open
    }

    pub(super) fn files_target(&self, cx: &App) -> f32 {
        if self.files_panel_open(cx) {
            self.settings
                .files_panel_width
                .min((self.viewport_width - self.sidebar_target() - CHAT_PANEL_MIN).max(0.0))
        } else {
            0.0
        }
    }

    pub(super) fn files_reserved_width(&self, cx: &App) -> f32 {
        if matches!(self.route, Route::Chat) {
            self.eval_tween(self.files_tween, self.files_target(cx))
        } else {
            0.0
        }
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
        let from = self.files_reserved_width(cx);
        let was_open = self.files_panel_open(cx);
        self.panels.update(&key, |p| p.files_open = true);
        if !was_open {
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
        let from = self.files_reserved_width(cx);
        self.panels
            .update(&self.panel_key(cx), |p| p.files_open = false);
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
        let inner = div()
            .w(px(content_width))
            .h_full()
            .pt(px(Theme::TITLEBAR_HEIGHT))
            .border_l_1()
            .border_color(theme.border)
            .bg(theme.bg)
            .children(content);
        div()
            .id("files-panel")
            .h_full()
            .flex_none()
            .relative()
            .child(self.pane_container(self.files_tween, target, inner.into_any_element()))
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
