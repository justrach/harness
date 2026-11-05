//! Explorer-specific chrome and the project-less starting state.
use super::*;
use crate::{
    icons::{self, icon},
    theme::Theme,
};

pub(super) const EXPLORER_HEADER_HEIGHT: f32 = 40.0;

impl FilesSurface {
    fn explorer_focus(&mut self, id: &str, cx: &mut Context<Self>) -> FocusHandle {
        self.explorer_controls
            .entry(id.into())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone()
    }

    /// Only this explorer changes target. Existing chats, editors and drafts
    /// keep their own owners, including when the chosen project is remote.
    pub(crate) fn choose_project(&mut self, id: &str, cx: &mut Context<Self>) {
        if self.presentation.is_editor() || self.state.read(cx).space_row(id).is_none() {
            return;
        }
        self.preferred_device_id = self
            .state
            .read(cx)
            .space_row(id)
            .map(|space| space.device_id.clone());
        self.chat_id = crate::state::canvas_panel_key(Some(id));
        self.choosing_project = false;
        self.clear_search(cx);
        self.sync_target(cx);
        self.ensure_loaded(cx);
        cx.emit(FilesEvent::TitleChanged);
        cx.notify();
    }

    fn toggle_project_choices(&mut self, cx: &mut Context<Self>) {
        self.choosing_project = !self.choosing_project;
        cx.notify();
    }

    pub(super) fn render_project_choices(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> gpui::Div {
        let projects: Vec<_> = self
            .state
            .read(cx)
            .spaces
            .iter()
            .filter(|project| {
                self.preferred_device_id
                    .as_deref()
                    .is_none_or(|id| project.device_id == id)
            })
            .cloned()
            .collect();
        let add_focus = self.explorer_focus("add-project", cx);
        let mut choices = div()
            .id("files-project-choices")
            .w_full()
            .max_h(px(300.0))
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap(px(4.0));
        for project in projects {
            let id = project.id.clone();
            let key_id = id.clone();
            let focus = self.explorer_focus(&id, cx);
            let device = self
                .state
                .read(cx)
                .device_name(&project.device_id)
                .unwrap_or("Unavailable device")
                .to_owned();
            choices = choices.child(
                div()
                    .id(SharedString::from(format!("files-project-{id}")))
                    .debug_selector({
                        let id = id.clone();
                        move || format!("files-project-{id}")
                    })
                    .track_focus(&focus)
                    .role(gpui::Role::Button)
                    .aria_label(format!("Browse {}", project.display_name()))
                    .w_full()
                    .min_h(px(56.0))
                    .flex_none()
                    .px(px(12.0))
                    .py(px(8.0))
                    .rounded(px(8.0))
                    .flex()
                    .items_center()
                    .gap(px(12.0))
                    .cursor_pointer()
                    .bg(theme.element_hover.opacity(0.5))
                    .hover(|s| s.bg(theme.element_hover))
                    .focus_visible(|s| s.border_1().border_color(theme.accent))
                    .on_click(cx.listener(move |this, _, _, cx| this.choose_project(&id, cx)))
                    .on_key_down(cx.listener(move |this, event: &gpui::KeyDownEvent, _, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            this.choose_project(&key_id, cx);
                            cx.stop_propagation();
                        }
                    }))
                    .child(
                        icon(icons::FOLDER)
                            .size(px(20.0))
                            .flex_none()
                            .text_color(theme.text_muted),
                    )
                    .child(
                        div()
                            .min_w_0()
                            .flex_1()
                            .flex()
                            .flex_col()
                            .gap(px(3.0))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(13.0))
                                    .text_color(theme.text)
                                    .child(project.display_name().to_owned()),
                            )
                            .child(
                                div()
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(11.0))
                                    .text_color(theme.text_muted)
                                    .child(format!("{device} · {}", project.path)),
                            ),
                    ),
            );
        }
        div().size_full().px(px(24.0)).flex().items_center().justify_center()
            .child(div().w_full().max_w(px(440.0)).flex().flex_col().gap(px(16.0))
                .child(icon(icons::FOLDER).size(px(28.0)).text_color(theme.text_muted))
                .child(div().flex().flex_col().gap(px(6.0))
                    .child(div().text_size(crate::typography::ui_rems(18.0)).font_weight(gpui::FontWeight::MEDIUM).text_color(theme.text).child("Choose a folder to browse"))
                    .child(div().text_size(crate::typography::ui_rems(13.0)).text_color(theme.text_muted).child("Open an existing project or add a folder. You don’t need to start a conversation.")))
                .child(choices)
                .child(div().id("files-add-project").debug_selector(|| "files-add-project".into())
                    .track_focus(&add_focus).role(gpui::Role::Button).aria_label("Add project folder")
                    .h(px(36.0)).px(px(12.0)).rounded(px(8.0)).flex().items_center().justify_center().gap(px(8.0))
                    .bg(theme.text).text_color(theme.bg).text_size(crate::typography::ui_rems(13.0)).cursor_pointer()
                    .focus_visible(|s| s.border_2().border_color(theme.accent))
                    .on_click(cx.listener(|_, _, _, cx| cx.emit(FilesEvent::AddProject)))
                    .on_key_down(cx.listener(|_, event: &gpui::KeyDownEvent, _, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") { cx.emit(FilesEvent::AddProject); cx.stop_propagation(); }
                    }))
                    .child(icon(icons::PLUS).size(px(16.0)).text_color(theme.bg)).child("Add folder…")))
    }

    pub(super) fn render_explorer_header(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        use gpui::Focusable;
        let has_folder = self.request_context.is_some();
        let include_ignored = self.tree.include_ignored();
        let cwd = self
            .request_context
            .as_ref()
            .map(|c| c.cwd.clone())
            .unwrap_or_default();
        let name = cwd
            .trim_end_matches(['/', '\\'])
            .rsplit(['/', '\\'])
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("Choose folder")
            .to_owned();
        let root_focus = self.explorer_focus("root", cx);
        let refresh_focus = self.explorer_focus("refresh", cx);
        let visibility_focus = self.explorer_focus("visibility", cx);
        let search_focus = self.search.focus_handle(cx);
        div()
            .id("files-explorer-header")
            .debug_selector(|| "files-explorer-header".into())
            .h(px(EXPLORER_HEADER_HEIGHT))
            .w_full()
            .flex_none()
            .px(px(8.0))
            .flex()
            .items_center()
            .gap(px(4.0))
            .bg(theme.bg)
            .border_b_1()
            .border_color(theme.border)
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    this.choosing_project = false;
                    this.close_search(cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .id("files-choose-project")
                    .track_focus(&root_focus)
                    .role(gpui::Role::Button)
                    .aria_label("Choose project folder")
                    .max_w(px(180.0))
                    .min_w_0()
                    .h(px(28.0))
                    .px(px(6.0))
                    .rounded(px(6.0))
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .cursor_pointer()
                    .hover(|s| s.bg(theme.element_hover))
                    .focus_visible(|s| {
                        s.bg(theme.element_hover)
                            .border_1()
                            .border_color(theme.accent)
                    })
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_project_choices(cx)))
                    .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            this.toggle_project_choices(cx);
                            cx.stop_propagation();
                        }
                    }))
                    .tooltip(move |_, cx| {
                        cx.new(|_| preview::FileEditorTooltip {
                            text: if cwd.is_empty() {
                                "Choose a project folder".into()
                            } else {
                                cwd.clone().into()
                            },
                        })
                        .into()
                    })
                    .child(
                        icon(icons::FOLDER)
                            .size(px(16.0))
                            .flex_none()
                            .text_color(theme.text_muted),
                    )
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .text_size(crate::typography::ui_rems(13.0))
                            .text_color(theme.text)
                            .child(name),
                    )
                    .child(
                        icon(icons::ALT_ARROW_DOWN)
                            .size(px(10.0))
                            .flex_none()
                            .text_color(theme.text_muted),
                    ),
            )
            .when(has_folder, |bar| {
                bar.child(
                    crate::surface_chrome::input()
                        .id("files-search")
                        .debug_selector(|| "files-search".into())
                        .h(px(28.0))
                        .bg(theme.element_hover.opacity(0.5))
                        .overflow_hidden()
                        .cursor_text()
                        .hover(|s| s.bg(theme.element_hover))
                        .on_mouse_down(gpui::MouseButton::Left, move |_, window, cx| {
                            window.focus(&search_focus, cx);
                            cx.stop_propagation();
                        })
                        .child(
                            icon(icons::MAGNIFER)
                                .size(px(14.0))
                                .flex_none()
                                .text_color(theme.text_muted),
                        )
                        .child(
                            div()
                                .min_w_0()
                                .flex_1()
                                .overflow_hidden()
                                .child(self.search.clone()),
                        ),
                )
            })
            .when(has_folder, |bar| {
                bar.child(
                    toolbar_button("files-refresh", "Refresh files")
                        .size(px(28.0))
                        .track_focus(&refresh_focus)
                        .focus_visible(|s| {
                            s.bg(theme.element_hover)
                                .border_1()
                                .border_color(theme.accent)
                        })
                        .on_click(cx.listener(|this, _, _, cx| this.refresh(cx)))
                        .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                this.refresh(cx);
                                cx.stop_propagation();
                            }
                        }))
                        .child(
                            icon(icons::REFRESH)
                                .size(px(16.0))
                                .text_color(theme.text_muted),
                        ),
                )
            })
            .when(has_folder, |bar| {
                bar.child(
                    toolbar_button(
                        "files-toggle-ignored",
                        if include_ignored {
                            "Hide hidden and ignored files"
                        } else {
                            "Show hidden and ignored files"
                        },
                    )
                    .debug_selector(|| "files-toggle-ignored".into())
                    .size(px(28.0))
                    .track_focus(&visibility_focus)
                    .when(include_ignored, |s| s.bg(theme.element_hover))
                    .focus_visible(|s| {
                        s.bg(theme.element_hover)
                            .border_1()
                            .border_color(theme.accent)
                    })
                    .on_click(cx.listener(|this, _, _, cx| this.toggle_ignored(cx)))
                    .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            this.toggle_ignored(cx);
                            cx.stop_propagation();
                        }
                    }))
                    .child(
                        icon(if include_ignored {
                            icons::EYE
                        } else {
                            icons::EYE_CLOSED
                        })
                        .size(px(16.0))
                        .text_color(theme.text_muted),
                    ),
                )
            })
            .into_any_element()
    }
}
