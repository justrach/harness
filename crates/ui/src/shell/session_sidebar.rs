//! Workspace sessions in the left sidebar. Conversation identity belongs to
//! the tabs inside a panel; this list only selects and manages workspaces.
use super::session_icon_catalog::{self, IconChoice, IconPickerTab};
use super::session_icon_grid::{COLUMNS, IconPickerGrid, IconPickerRow};
use super::*;
use std::collections::HashMap;
use std::rc::Rc;
#[path = "session_icon_picker.rs"]
mod icon_picker;
use icon_picker::picker_placeholder;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct SessionSidebarRow {
    pub id: String,
    pub title: String,
    pub project: Option<String>,
    pub active: bool,
    pub icon: super::session_icon::SessionIcon,
    pub pinned: bool,
}

pub(super) const SESSION_ICONS: &[(&str, &str, &str)] = &[
    ("workspace", "Workspace", icons::WIDGET),
    ("chat", "Chat", icons::CHAT_ROUND_LINE),
    ("folder", "Folder", icons::FOLDER),
    ("code", "Code", icons::FILE_CODE),
    ("terminal", "Terminal", icons::TERMINAL),
    ("globe", "Web", icons::GLOBE),
    ("checklist", "Checklist", icons::CHECKLIST),
    ("star", "Star", icons::STAR),
    ("spark", "Ideas", icons::MAGIC_STICK_3),
    ("branch", "Branch", icons::GIT_BRANCH),
    ("document", "Document", icons::DOCUMENT),
    ("calendar", "Calendar", icons::CALENDAR),
];

pub(super) fn session_icon_glyph(key: Option<&str>) -> &'static str {
    SESSION_ICONS
        .iter()
        .find(|(id, _, _)| Some(*id) == key)
        .map_or(icons::WIDGET, |(_, _, glyph)| *glyph)
}

pub(super) fn session_row_hover(theme: &Theme) -> gpui::Hsla {
    // The full menu hover role is too heavy across a wide sidebar row.
    // Preserve the authored hue while keeping hover quieter than selection.
    theme.element_hover.opacity(0.45)
}

#[derive(Clone)]
struct WorkspaceSessionDrag {
    id: String,
    title: SharedString,
}

#[derive(Clone)]
struct SessionMenu {
    id: String,
    position: gpui::Point<gpui::Pixels>,
    focus: FocusHandle,
    selected: usize,
    icons: bool,
    search_input: Entity<ComposerInput>,
    picker_tab: IconPickerTab,
    category: Option<String>,
    choices: Rc<Vec<IconChoice>>,
    grid: Rc<IconPickerGrid>,
    scroll: gpui::UniformListScrollHandle,
    _search_events: Rc<Subscription>,
}

#[derive(Default)]
pub(super) struct SessionSidebarRuntime {
    controls: HashMap<String, FocusHandle>,
    rename: Option<SessionRename>,
    focus_row: Option<String>,
    menu: Option<SessionMenu>,
    drop_target: Option<(String, bool)>,
    hovered: Option<String>,
    close_pending: Option<String>,
}

impl SessionSidebarRuntime {
    pub(super) fn close_menu(&mut self) {
        self.menu = None;
        self.drop_target = None;
    }

    pub(super) fn menu_is_open(&self) -> bool {
        self.menu.is_some()
    }
    pub(super) fn is_renaming(&self) -> bool {
        self.rename.is_some()
    }
}

struct SessionRename {
    id: String,
    input: Entity<ComposerInput>,
    focus_pending: bool,
    invalid: bool,
    _events: Subscription,
}

impl Shell {
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_session_emoji(
        &mut self,
        phase: u8,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match phase {
            0 => {
                self.fixture_session_hierarchy(4, window, cx);
                self.open_workspace_session_menu(
                    "fixture-design-session".into(),
                    true,
                    gpui::point(px(24.0), px(112.0)),
                    window,
                    cx,
                );
                self.set_workspace_session_picker_tab(IconPickerTab::Emoji, window, cx);
            }
            1 => {
                let input = self
                    .session_sidebar
                    .menu
                    .as_ref()
                    .unwrap()
                    .search_input
                    .clone();
                input.update(cx, |input, cx| input.set_text("technologist", cx));
                self.refresh_workspace_session_icon_choices(cx);
            }
            2 => {
                let input = self
                    .session_sidebar
                    .menu
                    .as_ref()
                    .unwrap()
                    .search_input
                    .clone();
                input.update(cx, |input, cx| input.set_text("👩🏽‍💻", cx));
                self.refresh_workspace_session_icon_choices(cx);
                self.apply_workspace_session_icon_choice(0, cx);
            }
            3 => self.fixture_session_hierarchy(10, window, cx),
            4 => {
                self.fixture_session_hierarchy(4, window, cx);
                self.open_workspace_session_menu(
                    "fixture-design-session".into(),
                    true,
                    gpui::point(px(24.0), px(112.0)),
                    window,
                    cx,
                );
                self.set_workspace_session_picker_tab(IconPickerTab::Icons, window, cx);
            }
            5 => {
                let menu = self.session_sidebar.menu.as_ref().unwrap();
                let row = menu.grid.rows.iter().position(|row| matches!(row,
                    IconPickerRow::Heading { category: Some(category), .. } if category == "people_body"
                )).unwrap();
                menu.scroll
                    .scroll_to_item_strict(row.saturating_sub(2), gpui::ScrollStrategy::Top);
            }
            6 => {
                self.fixture_session_emoji(0, window, cx);
                self.set_workspace_session_icon_category("symbols", window, cx);
            }
            7 => {
                // Half-row scroll reproduces the user's truncated-bottom view.
                let menu = self.session_sidebar.menu.as_ref().unwrap();
                menu.scroll
                    .0
                    .borrow()
                    .base_handle
                    .set_offset(gpui::point(px(0.0), px(-198.0)));
            }
            8 => {
                let menu = self.session_sidebar.menu.as_ref().unwrap();
                menu.scroll.scroll_to_bottom();
            }
            _ => {}
        }
        cx.notify();
    }

    pub(super) fn dismiss_workspace_session_menu(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(menu) = self.session_sidebar.menu.take() else {
            return false;
        };
        let focus = self.session_sidebar_focus(format!("session-row-{}", menu.id), cx);
        window.focus(&focus, cx);
        cx.notify();
        true
    }

    pub(super) fn dismiss_workspace_session_rename(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.session_sidebar.is_renaming() {
            return false;
        }
        self.cancel_workspace_session_rename(window, cx);
        true
    }

    fn session_sidebar_focus(&mut self, key: String, cx: &mut Context<Self>) -> FocusHandle {
        self.session_sidebar
            .controls
            .entry(key)
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone()
    }

    fn begin_workspace_session_rename(
        &mut self,
        id: String,
        title: String,
        cx: &mut Context<Self>,
    ) {
        let input = cx.new(|cx| {
            ComposerInput::new("Session name", cx)
                .with_single_line()
                .with_muted_placeholder()
                .with_accessibility_role(gpui::Role::TextInput)
        });
        input.update(cx, |input, cx| input.set_text(title, cx));
        let events = cx.subscribe(&input, |this: &mut Self, _, event, cx| match event {
            ComposerInputEvent::Submitted | ComposerInputEvent::ModifiedSubmitted => {
                this.commit_workspace_session_rename(cx);
            }
            ComposerInputEvent::Edited => {
                if let Some(rename) = this.session_sidebar.rename.as_mut() {
                    rename.invalid = false;
                }
                cx.notify();
            }
            _ => {}
        });
        self.session_sidebar.rename = Some(SessionRename {
            id,
            input,
            focus_pending: true,
            invalid: false,
            _events: events,
        });
        cx.notify();
    }

    fn commit_workspace_session_rename(&mut self, cx: &mut Context<Self>) {
        let Some(rename) = self.session_sidebar.rename.as_ref() else {
            return;
        };
        let title = transcript::single_line(rename.input.read(cx).text());
        if title.is_empty() {
            self.session_sidebar.rename.as_mut().unwrap().invalid = true;
            cx.notify();
            return;
        }
        let id = rename.id.clone();
        self.session_sidebar.rename = None;
        self.session_sidebar.focus_row = Some(id.clone());
        self.rename_workspace_session(&id, title, cx);
        cx.notify();
    }

    fn cancel_workspace_session_rename(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(rename) = self.session_sidebar.rename.take() {
            let focus = self.session_sidebar_focus(format!("session-row-{}", rename.id), cx);
            window.focus(&focus, cx);
            cx.notify();
        }
    }

    fn render_workspace_session_rename(
        &mut self,
        row: &SessionSidebarRow,
        theme: &Theme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let rename = self.session_sidebar.rename.as_mut().unwrap();
        let input = rename.input.clone();
        let invalid = rename.invalid;
        if std::mem::take(&mut rename.focus_pending) {
            window.focus(&input.focus_handle(cx), cx);
        }
        let mut editor = div()
            .id(SharedString::from(format!("session-rename-{}", row.id)))
            .debug_selector({
                let id = row.id.clone();
                move || format!("session-rename-{id}")
            })
            .flex()
            .flex_col()
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape" {
                    this.cancel_workspace_session_rename(window, cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .h(px(32.0))
                    .px(px(5.0))
                    .rounded(px(7.0))
                    .border_1()
                    .border_color(if invalid { theme.danger } else { theme.accent })
                    .bg(theme.bg)
                    .flex()
                    .items_center()
                    .gap(px(4.0))
                    .child(div().flex_1().min_w_0().child(input))
                    .child(self.render_session_sidebar_action(
                        &row.id,
                        "save",
                        icons::CHECK,
                        "Save session name",
                        theme,
                        cx,
                    ))
                    .child(self.render_session_sidebar_action(
                        &row.id,
                        "cancel",
                        icons::CLOSE,
                        "Cancel rename",
                        theme,
                        cx,
                    )),
            );
        if invalid {
            editor = editor.child(
                div()
                    .px(px(NAV_ITEM_INSET_X))
                    .pt(px(3.0))
                    .text_size(crate::typography::ui_rems(11.0))
                    .text_color(theme.danger)
                    .child("Enter a session name"),
            );
        }
        editor.into_any_element()
    }

    fn render_session_sidebar_action(
        &mut self,
        id: &str,
        action: &'static str,
        glyph: &'static str,
        label: &'static str,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        let id = id.to_owned();
        let key = format!("session-{action}-{id}");
        let focus = self.session_sidebar_focus(key.clone(), cx);
        let perform_id = id.clone();
        let debug_id = id.clone();
        div()
            .id(SharedString::from(key))
            .debug_selector(move || format!("session-{action}-{debug_id}"))
            .size(px(22.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(5.0))
            .role(gpui::Role::Button)
            .aria_label(label)
            .track_focus(&focus)
            .focus_visible(|el| el.opacity(1.0).bg(theme.glass_hover()))
            .hover(|el| el.bg(theme.glass_hover()))
            .cursor_pointer()
            .on_mouse_down(MouseButton::Left, |_, window, cx| {
                window.prevent_default();
                cx.stop_propagation();
            })
            .on_click(cx.listener(move |this, _, window, cx| {
                this.perform_session_sidebar_action(&perform_id, action, window, cx);
                cx.stop_propagation();
            }))
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        this.perform_session_sidebar_action(id.as_str(), action, window, cx);
                        cx.stop_propagation();
                    }
                }),
            )
            .child(icon(glyph).size(px(13.0)).text_color(theme.text_muted))
            .tooltip(move |_, cx| cx.new(|_| SurfaceTabTooltip { text: label.into() }).into())
    }

    fn perform_session_sidebar_action(
        &mut self,
        id: &str,
        action: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            "rename" => {
                if let Some(row) = self
                    .workspace_session_sidebar_rows(cx)
                    .into_iter()
                    .find(|row| row.id == id)
                {
                    self.begin_workspace_session_rename(row.id, row.title, cx);
                }
            }
            "close" => {
                self.request_workspace_session_close(id, window, cx);
            }
            "save" => self.commit_workspace_session_rename(cx),
            "cancel" => self.cancel_workspace_session_rename(window, cx),
            _ => {}
        }
    }

    fn request_workspace_session_close(
        &mut self,
        id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.session_sidebar.close_pending.is_some() {
            return;
        }
        let Some(row) = self
            .workspace_session_sidebar_rows(cx)
            .into_iter()
            .find(|row| row.id == id)
        else {
            return;
        };
        let restore_focus = [format!("session-close-{id}"), format!("session-row-{id}")]
            .iter()
            .any(|key| {
                self.session_sidebar
                    .controls
                    .get(key)
                    .is_some_and(|focus| focus.is_focused(window))
            });
        self.session_sidebar.close_pending = Some(row.id.clone());
        let answer = window.prompt(
            gpui::PromptLevel::Warning,
            &format!("Close “{}”?", row.title),
            Some("This will close the session and its panels and tabs. Your conversations won’t be deleted, and running agents will keep working."),
            &["Close session", "Cancel"],
            cx,
        );
        cx.spawn_in(window, async move |this, cx| {
            let confirmed = matches!(answer.await, Ok(0));
            let _ = this.update_in(cx, |this, window, cx| {
                if this.session_sidebar.close_pending.as_deref() != Some(row.id.as_str()) {
                    return;
                }
                this.session_sidebar.close_pending = None;
                if !confirmed {
                    return;
                }
                this.session_sidebar.rename = None;
                this.close_workspace_session(&row.id, cx);
                if restore_focus {
                    this.composer
                        .update(cx, |composer, _| composer.focus_pending = false);
                }
                if restore_focus && this.settings.sidebar_collapsed {
                    window.focus(&this.composer.focus_handle(cx), cx);
                } else if restore_focus
                    && let Some(active) = this
                        .workspace_session_sidebar_rows(cx)
                        .into_iter()
                        .find(|row| row.active)
                {
                    let focus =
                        this.session_sidebar_focus(format!("session-row-{}", active.id), cx);
                    window.focus(&focus, cx);
                }
            });
        })
        .detach();
    }

    pub(super) fn open_workspace_session_menu(
        &mut self,
        id: String,
        icons: bool,
        position: gpui::Point<gpui::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let picker_tab = if self
            .chat_tabs
            .iter()
            .find(|tab| tab.id == id)
            .and_then(|tab| tab.session_icon.as_deref())
            .is_some_and(|key| key.starts_with("emoji:"))
        {
            IconPickerTab::Emoji
        } else {
            IconPickerTab::Icons
        };
        let search_input = cx.new(|cx| {
            ComposerInput::with_context(picker_placeholder(picker_tab), "PaletteSearch", cx)
                .with_single_line()
                .with_tab_stop(true)
                .with_muted_placeholder()
                .with_accessibility_role(gpui::Role::TextInput)
        });
        let events = cx.subscribe(&search_input, |this: &mut Self, _, event, cx| match event {
            ComposerInputEvent::Submitted | ComposerInputEvent::ModifiedSubmitted => {
                if let Some(menu) = this.session_sidebar.menu.as_ref().filter(|menu| menu.icons)
                    && !menu.search_input.read(cx).has_marked_text()
                {
                    this.apply_workspace_session_icon_choice(menu.selected, cx);
                }
            }
            ComposerInputEvent::Edited => {
                this.refresh_workspace_session_icon_choices(cx);
            }
            _ => {}
        });
        let focus = cx.focus_handle();
        if icons {
            window.focus(&search_input.focus_handle(cx), cx);
        } else {
            window.focus(&focus, cx);
        }
        let choices = session_icon_catalog::choices(picker_tab, "");
        let grid = IconPickerGrid::new(&choices, picker_tab, false);
        self.session_sidebar.menu = Some(SessionMenu {
            id,
            position,
            focus,
            selected: 0,
            icons,
            search_input,
            picker_tab,
            category: None,
            choices: Rc::new(choices),
            grid: Rc::new(grid),
            scroll: gpui::UniformListScrollHandle::new(),
            _search_events: Rc::new(events),
        });
        cx.notify();
    }

    fn activate_workspace_session_menu(
        &mut self,
        index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(menu) = self.session_sidebar.menu.clone() else {
            return;
        };
        if menu.icons {
            self.apply_workspace_session_icon_choice(index, cx);
        } else {
            match index {
                0 => {
                    self.session_sidebar.menu = None;
                    self.perform_session_sidebar_action(&menu.id, "rename", window, cx);
                }
                1 => {
                    if let Some(menu) = self.session_sidebar.menu.as_mut() {
                        menu.icons = true;
                        menu.selected = 0;
                        window.focus(&menu.search_input.focus_handle(cx), cx);
                    }
                }
                2 => {
                    let pinned = self
                        .chat_tabs
                        .iter()
                        .find(|tab| tab.id == menu.id)
                        .is_some_and(|tab| tab.pinned);
                    self.set_workspace_session_pinned(&menu.id, !pinned, cx);
                    self.session_sidebar.menu = None;
                    self.session_sidebar.focus_row = Some(menu.id);
                }
                3 => {
                    self.session_sidebar.menu = None;
                    let focus = self.session_sidebar_focus(format!("session-row-{}", menu.id), cx);
                    window.focus(&focus, cx);
                    self.request_workspace_session_close(&menu.id, window, cx);
                }
                _ => {}
            }
        }
        cx.notify();
    }

    fn render_workspace_session_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.session_sidebar.menu.clone()?;
        if !self.chat_tabs.iter().any(|tab| tab.id == menu.id) {
            self.session_sidebar.menu = None;
            return None;
        }
        let theme = Theme::of(cx).for_popup();
        let pinned = self
            .chat_tabs
            .iter()
            .find(|tab| tab.id == menu.id)
            .is_some_and(|tab| tab.pinned);
        let mut card = popover::popover_card(&theme)
            .id("workspace-session-menu")
            .debug_selector(|| "workspace-session-menu".into())
            .w(px(if menu.icons { 360.0 } else { 234.0 }))
            .track_focus(&menu.focus)
            .flex()
            .flex_col()
            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                this.session_sidebar.menu = None;
                cx.notify();
            }))
            .capture_key_down(cx.listener(Self::workspace_session_menu_key_down));
        if menu.icons {
            // Let the scrolling list reach the actual popover edge. A bottom
            // inset otherwise creates a ledge that slices through emoji rows.
            card = card
                .pb(px(0.0))
                .child(self.render_workspace_session_icon_picker(&menu, &theme, cx));
        } else {
            for (ix, (title, glyph)) in [
                ("Rename", icons::PEN),
                ("Change icon", icons::WIDGET),
                (
                    if pinned {
                        "Unpin session"
                    } else {
                        "Pin session"
                    },
                    icons::PIN,
                ),
                ("Close session", icons::CLOSE),
            ]
            .into_iter()
            .enumerate()
            {
                card = card.child(
                    popover::menu_row_nav(
                        &theme,
                        false,
                        ix == menu.selected,
                        format!("session-menu-row-{ix}"),
                    )
                    .id(("workspace-session-menu-row", ix))
                    .debug_selector(move || format!("workspace-session-menu-row-{ix}"))
                    .role(gpui::Role::Button)
                    .aria_label(title)
                    .on_mouse_move(cx.listener(move |this, _, _, cx| {
                        if let Some(menu) = this.session_sidebar.menu.as_mut()
                            && menu.selected != ix
                        {
                            menu.selected = ix;
                            cx.notify();
                        }
                    }))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.activate_workspace_session_menu(ix, window, cx)
                    }))
                    .child(icon(glyph).size(px(15.0)).text_color(theme.text_muted))
                    .child(div().flex_1().child(title)),
                );
            }
        }
        Some(popover::menu_at(
            "workspace-session-context-menu",
            menu.position,
            card.into_any_element(),
            None,
        ))
    }

    fn render_workspace_session_row(
        &mut self,
        row: SessionSidebarRow,
        theme: &Theme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if self
            .session_sidebar
            .rename
            .as_ref()
            .is_some_and(|rename| rename.id == row.id)
        {
            return self.render_workspace_session_rename(&row, theme, window, cx);
        }
        let attention = self.workspace_session_attention(&row.id, cx);
        let attention_button = attention.as_ref().map(|(panel, tab, status)| {
            let status = *status;
            let panel = *panel;
            let tab = tab.clone();
            let key_tab = tab.clone();
            let session = row.id.clone();
            let key_session = session.clone();
            let label = format!("{}: {}. Open chat", row.title, status.label());
            let focus = self.session_sidebar_focus(format!("session-attention-{}", row.id), cx);
            div()
                .id(SharedString::from(format!("session-attention-{}", row.id)))
                .debug_selector({
                    let id = row.id.clone();
                    move || format!("session-attention-{id}")
                })
                .size(px(20.0))
                .flex_none()
                .rounded(px(4.0))
                .flex()
                .items_center()
                .justify_center()
                .role(gpui::Role::Button)
                .aria_label(label.clone())
                .track_focus(&focus)
                .hover(|el| el.bg(session_row_hover(theme)))
                .focus_visible(|el| el.bg(session_row_hover(theme)))
                .on_mouse_down(MouseButton::Left, |_, window, cx| {
                    window.prevent_default();
                    cx.stop_propagation();
                })
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.activate_workspace_session(&session, cx);
                    this.focus_workspace_tab(panel, tab.clone(), window, cx);
                    cx.stop_propagation();
                }))
                .on_key_down(
                    cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            this.activate_workspace_session(&key_session, cx);
                            this.focus_workspace_tab(panel, key_tab.clone(), window, cx);
                            cx.stop_propagation();
                        }
                    }),
                )
                .tooltip(move |_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: label.clone().into(),
                    })
                    .into()
                })
                .child(
                    icon(status.glyph())
                        .size(px(13.0))
                        .text_color(status.color(theme)),
                )
        });
        let focus = self.session_sidebar_focus(format!("session-row-{}", row.id), cx);
        if self.session_sidebar.focus_row.as_ref() == Some(&row.id) {
            self.session_sidebar.focus_row = None;
            window.focus(&focus, cx);
        }
        let show_controls = self.session_sidebar.hovered.as_ref() == Some(&row.id)
            || focus.contains_focused(window, cx)
            || self
                .session_sidebar
                .menu
                .as_ref()
                .is_some_and(|menu| menu.id == row.id);
        let close = self
            .render_session_sidebar_action(
                &row.id,
                "close",
                icons::CLOSE,
                "Close session",
                theme,
                cx,
            )
            .when(!show_controls, |el| el.invisible());
        let activate = row.id.clone();
        let key_activate = row.id.clone();
        let rename_id = row.id.clone();
        let rename_title = row.title.clone();
        let key_title = row.title.clone();
        let icon_id = row.id.clone();
        let menu_id = row.id.clone();
        let hover_id = row.id.clone();
        let target_id = row.id.clone();
        let drop_id = row.id.clone();
        let debug_id = row.id.clone();
        let drop_target = self
            .session_sidebar
            .drop_target
            .as_ref()
            .filter(|(id, _)| id == &row.id)
            .map(|(_, before)| *before);
        let shell = cx.entity();
        div()
            .id(SharedString::from(format!("workspace-session-{}", row.id)))
            .debug_selector(move || format!("workspace-session-{debug_id}"))
            .relative()
            .h(px(32.0))
            .w_full()
            .min_w_0()
            .px(px(NAV_ITEM_INSET_X))
            .flex()
            .items_center()
            .gap(px(7.0))
            .rounded(px(7.0))
            .role(gpui::Role::Button)
            .aria_label(format!(
                "{}, {}{}session",
                row.title,
                if row.active { "current " } else { "" },
                if row.pinned { "pinned " } else { "" }
            ))
            .aria_selected(row.active)
            .track_focus(&focus)
            .focus_visible(|el| el.bg(session_row_hover(theme)))
            .when(row.active, |el| {
                el.bg(theme.sidebar_selected_bg())
                    .when(theme.is_harp(), |el| {
                        el.shadow(theme.sidebar_selected_shadows())
                    })
            })
            .when(!row.active, |el| {
                el.hover(|el| el.bg(session_row_hover(theme)))
            })
            .cursor_pointer()
            .on_hover(cx.listener(move |this, hovered: &bool, _, cx| {
                if *hovered {
                    this.session_sidebar.hovered = Some(hover_id.clone());
                } else if this.session_sidebar.hovered.as_ref() == Some(&hover_id) {
                    this.session_sidebar.hovered = None;
                }
                cx.notify();
            }))
            .on_click(cx.listener(move |this, event: &gpui::ClickEvent, _, cx| {
                if !event.standard_click() {
                    return;
                }
                this.session_sidebar.rename = None;
                this.activate_workspace_session(&activate, cx);
            }))
            .on_mouse_down(
                MouseButton::Right,
                cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                    this.open_workspace_session_menu(
                        menu_id.clone(),
                        false,
                        event.position,
                        window,
                        cx,
                    );
                    cx.stop_propagation();
                }),
            )
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    match event.keystroke.key.as_str() {
                        "enter" | "space" => this.activate_workspace_session(&key_activate, cx),
                        "f2" => this.begin_workspace_session_rename(
                            key_activate.clone(),
                            key_title.clone(),
                            cx,
                        ),
                        "f10" if event.keystroke.modifiers.shift => this
                            .open_workspace_session_menu(
                                key_activate.clone(),
                                false,
                                window.mouse_position(),
                                window,
                                cx,
                            ),
                        "contextmenu" => this.open_workspace_session_menu(
                            key_activate.clone(),
                            false,
                            window.mouse_position(),
                            window,
                            cx,
                        ),
                        "up" | "down" if event.keystroke.modifiers.alt => {
                            let rows = this.workspace_session_sidebar_rows(cx);
                            if let Some(index) = rows.iter().position(|row| row.id == key_activate)
                            {
                                let before = event.keystroke.key == "up";
                                let target = if before {
                                    index.checked_sub(1)
                                } else {
                                    index.checked_add(1)
                                };
                                if let Some(target) = target.and_then(|index| rows.get(index)) {
                                    this.move_workspace_session(
                                        &key_activate,
                                        &target.id,
                                        before,
                                        cx,
                                    );
                                }
                            }
                        }
                        _ => return,
                    }
                    cx.stop_propagation();
                }),
            )
            .on_drag(
                WorkspaceSessionDrag {
                    id: row.id.clone(),
                    title: row.title.clone().into(),
                },
                move |payload, _, _, cx| {
                    shell.update(cx, |shell, cx| {
                        shell.session_sidebar.drop_target = None;
                        shell.session_sidebar.menu = None;
                        cx.notify();
                    });
                    cx.stop_propagation();
                    cx.new(|_| SurfaceTabGhost {
                        title: payload.title.clone(),
                    })
                },
            )
            .on_drag_move::<WorkspaceSessionDrag>(cx.listener(
                move |this, event: &gpui::DragMoveEvent<WorkspaceSessionDrag>, _, cx| {
                    if event.bounds.contains(&event.event.position)
                        && event.drag(cx).id != target_id
                    {
                        let before = event.event.position.y < event.bounds.center().y;
                        let target = Some((target_id.clone(), before));
                        if this.session_sidebar.drop_target != target {
                            this.session_sidebar.drop_target = target;
                            cx.notify();
                        }
                    }
                },
            ))
            .on_drop(
                cx.listener(move |this, drag: &WorkspaceSessionDrag, _, cx| {
                    let before = this
                        .session_sidebar
                        .drop_target
                        .take()
                        .filter(|(id, _)| id == &drop_id)
                        .is_none_or(|(_, before)| before);
                    this.move_workspace_session(&drag.id, &drop_id, before, cx);
                    cx.stop_propagation();
                }),
            )
            .child(
                div()
                    .id(SharedString::from(format!("session-icon-{}", row.id)))
                    .size(px(20.0))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(4.0))
                    .role(gpui::Role::Button)
                    .aria_label(format!("Change {} icon", row.title))
                    .hover(|el| el.bg(session_row_hover(theme)))
                    .on_mouse_down(MouseButton::Left, |_, window, cx| {
                        window.prevent_default();
                        cx.stop_propagation();
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.open_workspace_session_menu(
                            icon_id.clone(),
                            true,
                            window.mouse_position(),
                            window,
                            cx,
                        );
                        cx.stop_propagation();
                    }))
                    .child(row.icon.render(14.0, theme.text_muted))
                    .when(!self.session_sidebar.menu_is_open(), |el| {
                        el.tooltip(|_, cx| {
                            cx.new(|_| SurfaceTabTooltip {
                                text: "Change session icon".into(),
                            })
                            .into()
                        })
                    }),
            )
            .child(
                div()
                    .id(SharedString::from(format!("session-name-{}", row.id)))
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(crate::typography::ui_rems(13.0))
                    .text_color(theme.text)
                    .on_click(cx.listener(move |this, event: &gpui::ClickEvent, _, cx| {
                        if event.click_count() >= 2 {
                            this.begin_workspace_session_rename(
                                rename_id.clone(),
                                rename_title.clone(),
                                cx,
                            );
                            cx.stop_propagation();
                        }
                    }))
                    .child(row.title.clone()),
            )
            .children(attention_button)
            .when(row.pinned, |el| {
                el.child(
                    icon(icons::PIN)
                        .size(px(12.0))
                        .flex_none()
                        .text_color(theme.text_muted),
                )
            })
            .child(close)
            .when_some(drop_target, |el, before| {
                el.child(
                    div()
                        .absolute()
                        .left(px(4.0))
                        .right(px(4.0))
                        .h(px(2.0))
                        .bg(theme.accent)
                        .when(before, |el| el.top_0())
                        .when(!before, |el| el.bottom_0()),
                )
            })
            .when(!self.session_sidebar.menu_is_open(), |el| {
                el.tooltip(move |_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: row.title.clone().into(),
                    })
                    .into()
                })
            })
            .into_any_element()
    }

    pub(super) fn chat_history_in_titlebar(&self) -> bool {
        self.settings.sidebar_collapsed
            || self.session_overview
            || !matches!(self.route, Route::Chat)
    }

    pub(super) fn chat_history_header_width(&self) -> f32 {
        if self.chat_history_in_titlebar() {
            CHAT_HISTORY_HEADER_WIDTH
        } else {
            0.0
        }
    }

    pub(super) fn render_chat_history_button(
        &mut self,
        id: &'static str,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        // One focus identity follows the action between its visible locations.
        let focus = self.session_sidebar_focus("chat-history".into(), cx);
        let focus = if self.session_overview {
            self.overview_background_focus(focus)
        } else {
            focus.tab_stop(self.command_palette.is_none())
        };
        window_control_button(
            id,
            icons::CLOCK_CIRCLE,
            theme,
            cx.listener(|this, _, window, cx| this.toggle_chat_history(window, cx)),
        )
        .role(gpui::Role::Button)
        .aria_label("Chat history")
        .track_focus(&focus)
        .focus_visible(|el| el.bg(theme.glass_hover()))
        .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                this.toggle_chat_history(window, cx);
                cx.stop_propagation();
            }
        }))
        .tooltip(|_, cx| {
            cx.new(|_| SurfaceTabTooltip {
                text: "Chat history".into(),
            })
            .into()
        })
        .tooltip_show_delay(std::time::Duration::from_millis(350))
    }

    fn render_workspace_session_new(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let key = "sidebar-session-create";
        let focus = self.session_sidebar_focus(key.into(), cx);
        div()
            .id(key)
            .debug_selector(move || key.into())
            .role(gpui::Role::Button)
            .aria_label("New session")
            .track_focus(&focus)
            .focus_visible(|el| el.bg(theme.glass_hover()))
            .flex_none()
            .size(px(26.0))
            .border_1()
            .border_color(theme.text_muted.opacity(0.45))
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(6.0))
            .cursor_pointer()
            .hover(|el| el.bg(theme.glass_hover()))
            .on_click(cx.listener(|this, _, _, cx| this.create_workspace_session(cx)))
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, _, cx| {
                if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                    this.create_workspace_session(cx);
                    cx.stop_propagation();
                }
            }))
            .child(
                icon(icons::PLUS)
                    .size(px(16.0))
                    .text_color(theme.text_muted),
            )
            .tooltip(|_, cx| {
                cx.new(|_| SurfaceTabTooltip {
                    text: "New session".into(),
                })
                .into()
            })
            .into_any_element()
    }

    pub(super) fn render_workspace_session_sidebar(
        &mut self,
        theme: &Theme,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.focus_sidebar_search(window, cx);
        if !cx.has_active_drag() {
            self.session_sidebar.drop_target = None;
        }
        if self.boot_restored {
            self.ensure_workspace_sessions(cx);
        }
        let rows: Vec<_> = self
            .workspace_session_sidebar_rows(cx)
            .into_iter()
            .filter(|row| {
                self.settings
                    .space_filter
                    .as_ref()
                    .is_none_or(|project| row.project.as_ref() == Some(project))
            })
            .collect();
        if self
            .session_sidebar
            .rename
            .as_ref()
            .is_some_and(|rename| !rows.iter().any(|row| row.id == rename.id))
        {
            self.session_sidebar.rename = None;
        }
        let mut list = div()
            .id("workspace-session-list")
            .debug_selector(|| "workspace-session-list".into())
            .flex()
            .flex_col()
            .gap(px(SIDEBAR_LIST_GAP));
        for row in rows {
            list = list.child(self.render_workspace_session_row(row, theme, window, cx));
        }
        let scroll = crate::edge_fade::edge_faded(
            SIDEBAR_GLASS_FADE_BAND,
            true,
            true,
            div()
                .id("workspace-session-scroll")
                .flex_1()
                .min_h_0()
                .size_full()
                .overflow_y_scroll()
                .track_scroll(&self.sidebar_scroll)
                .px(px(SIDEBAR_GUTTER))
                .pt(px(SIDEBAR_LIST_PAD_TOP))
                .child(list),
        )
        .fade_overflow_y(&self.sidebar_scroll);
        let (user, scope) = {
            let state = self.state.read(cx);
            (state.auth_user().cloned(), state.workspace_scope)
        };
        let (user_line, identity): (SharedString, SharedString) = match scope {
            Some(WorkspaceScope::Local) => (
                if matches!(self.sync_flow, SyncFlow::RestartPending { .. }) {
                    "Sync ready after restart"
                } else {
                    "Local only"
                }
                .into(),
                "Stored on this device".into(),
            ),
            Some(WorkspaceScope::Development) => {
                ("Development".into(), "Authentication disabled".into())
            }
            Some(WorkspaceScope::Synced) | None => {
                let line: SharedString = user
                    .as_ref()
                    .map(|user| {
                        user.name
                            .clone()
                            .unwrap_or_else(|| user.email.clone())
                            .into()
                    })
                    .unwrap_or_else(|| "Not signed in".into());
                let identity = user
                    .as_ref()
                    .map(|user| user.email.clone().into())
                    .unwrap_or_else(|| line.clone());
                (line, identity)
            }
        };
        let user_menu = self.render_user_menu(user_line, identity, theme, cx);
        let session_menu = self.render_workspace_session_menu(cx);
        // Find is an on-demand view. Keep the workspace list unchanged until
        // search is invoked, and use its existing conversation result routing.
        let search_controls = self.render_sidebar_search_controls(theme, cx);
        let scroll = self
            .render_sidebar_search_results(theme, cx)
            .unwrap_or_else(|| scroll.into_any_element());
        div()
            .w(px(self.settings.sidebar_width))
            .h_full()
            .flex()
            .flex_col()
            .child(self.render_session_switcher(theme, cx))
            .when_some(search_controls, |sidebar, controls| sidebar.child(controls))
            .child(div().flex_1().min_h_0().child(scroll))
            .when(cfg!(target_os = "macos"), |el| {
                el.when_some(self.render_cloud_sandbox_strip(theme, cx), |el, card| el.child(card))
            })
            .when_some(self.render_connection_pill(theme, cx), |el, pill| {
                el.child(pill)
            })
            .when_some(self.render_signed_out_strip(theme, cx), |el, strip| {
                el.child(strip)
            })
            .when_some(self.sidebar_notice.clone(), |el, notice| {
                el.child(
                    div()
                        .id("sidebar-notice")
                        .mx(px(SIDEBAR_GUTTER))
                        .mb(px(Theme::SPACE_SM))
                        .px(px(Theme::SPACE_SM))
                        .py(px(4.0))
                        .rounded(px(Theme::CONTROL_RADIUS))
                        .border_1()
                        .border_color(theme.danger)
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.danger)
                        .cursor_pointer()
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.sidebar_notice = None;
                            cx.notify();
                        }))
                        .child(notice),
                )
            })
            .child(
                div()
                    .h(px(44.0))
                    .px(px(SIDEBAR_GUTTER))
                    .flex_none()
                    .flex()
                    .items_center()
                    .child(user_menu)
                    .child(div().flex_1())
                    .when(!self.chat_history_in_titlebar(), |el| {
                        el.child(
                            self.render_chat_history_button("sidebar-chat-history", theme, cx)
                                .size(px(26.0))
                                .mr(px(6.0)),
                        )
                    })
                    .child(self.render_workspace_session_new(theme, cx)),
            )
            .when_some(session_menu, |el, menu| el.child(menu))
            .into_any_element()
    }
}

#[cfg(test)]
#[path = "session_sidebar_tests.rs"]
mod tests;
