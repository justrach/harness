//! Global action and conversation search, using the sidebar's conversation rows.
use super::*;
use crate::appearance::AppearanceMode;

const HISTORY_RESULT_LIMIT: usize = 30;
const RESULTS_FADE_BAND: f32 = 18.0;

pub(super) struct CommandPalette {
    search: Entity<ComposerInput>,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    active: usize,
    enter_press: EnterPress,
    // Claim focus during mount so the shell does not restore the composer
    // while this input is still absent from the dispatch tree.
    focus_pending: bool,
    scroll: gpui::ScrollHandle,
    _search_events: Subscription,
}

// X11 suppresses synthetic repeat releases but sends repeated keydowns with
// is_held=false. Keep our own latch until the physical key is released.
#[derive(Default)]
struct EnterPress {
    down: bool,
}

impl EnterPress {
    fn press(&mut self, is_held: bool) -> bool {
        let was_down = std::mem::replace(&mut self.down, true);
        !was_down && !is_held
    }

    fn release(&mut self) {
        self.down = false;
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Entry {
    NewChat,
    NewProject,
    Settings,
    Theme(AppearanceMode),
    /// An unfocused split pane (index into the split); picking it moves
    /// focus there instead of pulling its chat into the current pane.
    Pane(usize),
    Chat(String),
}

impl Entry {
    fn action(&self) -> Option<(&'static str, &'static str)> {
        match self {
            Self::NewChat => Some(("New chat", icons::PEN_NEW_SQUARE)),
            Self::NewProject => Some(("New project", icons::FOLDER)),
            Self::Settings => Some(("Open settings", icons::SETTINGS_MINIMALISTIC)),
            Self::Theme(mode) => Some((
                match mode {
                    AppearanceMode::System => "Switch to system theme",
                    AppearanceMode::Light => "Switch to light theme",
                    AppearanceMode::Dark => "Switch to dark theme",
                },
                mode.icon(),
            )),
            Self::Pane(_) | Self::Chat(_) => None,
        }
    }

    /// Result groups, in display order: open panes, actions, chat history.
    fn section(&self) -> u8 {
        match self {
            Self::Pane(_) => 0,
            Self::Chat(_) => 2,
            _ => 1,
        }
    }
}

fn matches_query(query: &str, text: &str) -> bool {
    let text = text.to_lowercase();
    query.split_whitespace().all(|word| text.contains(word))
}

fn actions_for(query: &str, is_dark: bool) -> Vec<Entry> {
    [
        Entry::NewChat,
        Entry::NewProject,
        Entry::Settings,
        Entry::Theme(if is_dark {
            AppearanceMode::Light
        } else {
            AppearanceMode::Dark
        }),
    ]
    .into_iter()
    .filter(|entry| matches_query(query, entry.action().unwrap().0))
    .collect()
}

impl Shell {
    pub(super) fn reset_command_palette_key_state(&mut self) {
        if let Some(palette) = self.command_palette.as_mut() {
            palette.enter_press.release();
        }
    }

    pub(super) fn toggle_command_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.command_palette.is_some() {
            self.close_command_palette(window, cx);
            return;
        }
        self.add_space = None;
        let placeholder = if self.chat_split.as_ref().is_some_and(|split| split.panes.len() > 1) {
            "Search open panes, commands and chats…"
        } else {
            "Search commands and chats…"
        };
        let search = cx.new(|cx| ComposerInput::with_context(placeholder, "PaletteSearch", cx));
        let events = cx.subscribe(&search, |this, _, event, cx| {
            if matches!(event, ComposerInputEvent::Edited) {
                if let Some(palette) = this.command_palette.as_mut() {
                    palette.active = 0;
                    palette.scroll.set_offset(gpui::point(px(0.0), px(0.0)));
                }
                cx.notify();
            }
        });
        let previous_focus = window.focused(cx);
        self.command_palette = Some(CommandPalette {
            search,
            focus: cx.focus_handle(),
            previous_focus,
            active: 0,
            enter_press: EnterPress::default(),
            focus_pending: true,
            scroll: gpui::ScrollHandle::new(),
            _search_events: events,
        });
        cx.notify();
    }

    pub(super) fn close_command_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(palette) = self.command_palette.take() {
            if let Some(focus) = palette.previous_focus {
                window.focus(&focus, cx);
            }
            cx.notify();
        }
    }

    fn command_entries(&self, cx: &App) -> Vec<Entry> {
        let Some(palette) = &self.command_palette else {
            return Vec::new();
        };
        let query = palette.search.read(cx).text().trim().to_lowercase();
        // Open panes lead: with several chats side by side, "take me to that
        // one" is the common search. Their chats leave the history list.
        let mut entries = Vec::new();
        let mut in_panes: Vec<String> = Vec::new();
        if let Some(split) = self.chat_split.as_ref().filter(|_| matches!(self.route, Route::Chat)) {
            for ix in (0..split.panes.len()).filter(|&ix| ix != split.focus) {
                in_panes.extend(split.panes[ix].clone());
                let (title, project) = self.pane_label(ix, cx);
                if matches_query(&query, &format!("{title} {project}")) {
                    entries.push(Entry::Pane(ix));
                }
            }
        }
        entries.extend(actions_for(&query, Theme::of(cx).appearance.is_dark()));
        let state = self.state.read(cx);
        // Global history deliberately ignores the sidebar's project filter and
        // collapsed groups. Archived conversations remain searchable too.
        let mut chats: Vec<_> = state
            .chats
            .iter()
            .filter(|chat| !in_panes.contains(&chat.id))
            .filter(|chat| {
                let project = state
                    .space_for_chat(chat)
                    .map(|s| s.display_name())
                    .unwrap_or("~");
                let device = state.device_name(&chat.device_id).unwrap_or("");
                let branch =
                    crate::change_requests::conversation_branch(chat, &state.spaces).unwrap_or("");
                let pr = state
                    .change_request_for_chat(chat)
                    .map(|pr| {
                        format!(
                            "#{} {} {} {}",
                            pr.number, pr.title, pr.head_ref, pr.base_ref
                        )
                    })
                    .unwrap_or_default();
                matches_query(
                    &query,
                    &format!(
                        "{} {project} {device} {branch} {pr}",
                        chat.title.as_deref().unwrap_or("New session")
                    ),
                )
            })
            .collect();
        chats.sort_by(|a, b| spaces::compare_sidebar_chats(self.settings.sidebar_sort, a, b));
        // Limit after filtering and sorting so every chat remains searchable.
        entries.extend(
            chats
                .into_iter()
                .take(HISTORY_RESULT_LIMIT)
                .map(|chat| Entry::Chat(chat.id.clone())),
        );
        entries
    }

    fn activate_command(&mut self, entry: Entry, window: &mut Window, cx: &mut Context<Self>) {
        if let Entry::Theme(mode) = entry {
            // Keep the palette open so this ordinary action updates to its next state.
            crate::appearance::set_mode(mode, cx);
            cx.notify();
            return;
        }
        self.close_command_palette(window, cx);
        match entry {
            Entry::NewChat => self.open_new_session(cx),
            Entry::NewProject => self.open_add_space(cx),
            Entry::Settings => self.open_settings(SettingsSection::Devices, cx),
            Entry::Theme(_) => unreachable!(),
            Entry::Pane(ix) => self.focus_chat_pane(ix, window, cx),
            Entry::Chat(id) => {
                if !self.reveal_chat_in_tabs(&id, window, cx) {
                    self.open_chat(id, cx)
                }
            }
        }
    }

    /// A split pane's chat title and project, as the pane strip shows them.
    fn pane_label(&self, ix: usize, cx: &App) -> (String, String) {
        let state = self.state.read(cx);
        let Some(split) = self.chat_split.as_ref() else {
            return ("New session".into(), String::new());
        };
        let chat = split.panes[ix]
            .as_deref()
            .and_then(|id| state.chats.iter().find(|chat| chat.id == id));
        let title = chat
            .map(|chat| {
                transcript::single_line(chat.title.as_deref().unwrap_or("Untitled session"))
            })
            .unwrap_or_else(|| "New session".into());
        let project = chat
            .and_then(|chat| state.space_for_chat(chat))
            .or_else(|| {
                split.projects[ix]
                    .as_deref()
                    .and_then(|id| state.spaces.iter().find(|s| s.id == id))
            })
            .map(|space| space.display_name().to_string())
            .unwrap_or_default();
        (title, project)
    }

    pub(super) fn render_command_palette(
        &mut self,
        viewport: gpui::Size<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let entries = self.command_entries(cx);
        let palette = self.command_palette.as_mut()?;
        if std::mem::take(&mut palette.focus_pending) {
            window.focus(&palette.search.focus_handle(cx), cx);
        }
        palette.active = palette.active.min(entries.len().saturating_sub(1));
        let active = palette.active;
        let search = palette.search.clone();
        let query = search.read(cx).text().to_string();
        let focus = palette.focus.clone();
        let scroll = palette.scroll.clone();
        let theme = Theme::of(cx).for_popup();
        let mut rows = Vec::new();
        for (ix, entry) in entries.iter().enumerate() {
            // End spacing belongs to the content, so it scrolls out of the
            // fade instead of leaving a permanent gutter beside the chrome.
            let mut row = div()
                .id(("command-result", ix))
                .flex_none()
                .when(ix == 0, |row| row.pt(px(8.0)))
                .when(ix + 1 == entries.len(), |row| row.pb(px(8.0)));
            if ix > 0 && entries[ix - 1].section() != entry.section() {
                row = row.child(spaces::sidebar_separator(&theme).w_full().my(px(8.0)));
            }
            let content = if let Entry::Pane(pane) = entry {
                let pane = *pane;
                let (title, project) = self.pane_label(pane, cx);
                let glyph = self
                    .chat_split
                    .as_ref()
                    .map(|split| chat_split::pane_glyph(split.axis, pane, split.panes.len()))
                    .unwrap_or("▣");
                popover::menu_row(&theme, ix == active, format!("command-pane-{ix}"))
                    .id(("command-pane", ix))
                    .rounded(px(popover::PALETTE_ITEM_RADIUS))
                    .role(gpui::Role::Button)
                    .aria_label(format!("Go to pane: {title}"))
                    .min_h(px(30.0))
                    .py(px(4.0))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.activate_command(Entry::Pane(pane), window, cx)
                    }))
                    .child(
                        div()
                            .w(px(16.0))
                            .flex_none()
                            .text_center()
                            .text_color(theme.text_muted)
                            .child(SharedString::from(glyph)),
                    )
                    .child(div().flex_1().min_w_0().truncate().child(popover::search_highlight(
                        title.into(),
                        Some(&query),
                        &theme,
                    )))
                    .when(!project.is_empty(), |row| {
                        row.child(
                            div()
                                .flex_none()
                                .max_w(px(160.0))
                                .truncate()
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(theme.text_muted)
                                .child(SharedString::from(project)),
                        )
                    })
                    .child(
                        div()
                            .flex_none()
                            .text_size(crate::typography::ui_rems(11.0))
                            .text_color(theme.text_muted.opacity(0.7))
                            .child(SharedString::from("Go to pane")),
                    )
                    .into_any_element()
            } else if let Some((label, glyph)) = entry.action() {
                let shortcut = match entry {
                    Entry::NewChat | Entry::NewProject => {
                        let id = if *entry == Entry::NewChat {
                            ShortcutId::NewSession
                        } else {
                            ShortcutId::NewProject
                        };
                        let combo = self.settings.keymap.get(id);
                        let valid = Keystroke::parse(&platform_combo(combo)).is_ok();
                        Some(crate::settings::badge_combo(if valid {
                            combo
                        } else {
                            id.default_combo()
                        }))
                    }
                    Entry::Settings => Some(crate::settings::badge_combo("mod-,")),
                    _ => None,
                };
                let entry = entry.clone();
                popover::menu_row(&theme, ix == active, format!("command-action-{ix}"))
                    .id(("command-action", ix))
                    .rounded(px(popover::PALETTE_ITEM_RADIUS))
                    .role(gpui::Role::Button)
                    .aria_label(label)
                    .min_h(px(30.0))
                    .py(px(4.0))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.activate_command(entry.clone(), window, cx)
                    }))
                    .child(
                        icon(glyph)
                            .size(px(16.0))
                            .flex_none()
                            .text_color(theme.text_muted),
                    )
                    .child(div().flex_1().min_w_0().child(popover::search_highlight(
                        label.into(),
                        Some(&query),
                        &theme,
                    )))
                    .when_some(shortcut, |row, shortcut| {
                        row.child(popover::kbd_hint(&theme, &shortcut))
                    })
                    .into_any_element()
            } else if let Entry::Chat(id) = entry {
                let state = self.state.read(cx);
                let chat = state.chats.iter().find(|chat| &chat.id == id)?;
                let project = match (state.space_for_chat(chat), chat.space_id.as_deref()) {
                    (Some(space), _) => space.display_name(),
                    (None, None) => "~",
                    _ => "?",
                };
                let folder = match state.device_name(&chat.device_id) {
                    Some(device) => format!("{project} @ {device}"),
                    None => project.to_string(),
                };
                let branch = self
                    .settings
                    .sidebar_show_branch
                    .then(|| crate::change_requests::conversation_branch(chat, &state.spaces))
                    .flatten()
                    .map(str::trim)
                    .filter(|branch| !branch.is_empty())
                    .map(SharedString::from);
                let pr = self
                    .settings
                    .sidebar_show_pull_request
                    .then(|| state.change_request_for_chat(chat).cloned())
                    .flatten();
                let harness = self
                    .settings
                    .sidebar_show_harness
                    .then(|| chat.config.as_ref().map(|c| c.harness))
                    .flatten();
                self.render_chat_row(
                    id.clone(),
                    transcript::single_line(chat.title.as_deref().unwrap_or("New session")).into(),
                    format_time_ago(chat.last_message_at.unwrap_or(chat.created_at), Utc::now())
                        .into(),
                    folder.into(),
                    branch,
                    pr,
                    harness,
                    state.display_status_for(chat, Utc::now()),
                    ix == active,
                    chat.archived,
                    false,
                    None,
                    None,
                    Some(&query),
                    &theme,
                    cx,
                )
            } else {
                unreachable!()
            };
            rows.push(row.child(div().px(px(8.0)).child(content)));
        }
        let height = (f32::from(viewport.height) - 180.0).clamp(100.0, 360.0);
        let body = div()
            .id("command-results")
            .min_h_0()
            .max_h(px(height))
            .overflow_y_scroll()
            .track_scroll(&scroll)
            .flex()
            .flex_col()
            .gap(px(SIDEBAR_LIST_GAP))
            .children(rows)
            .when(entries.is_empty(), |el| {
                el.child(
                    div()
                        .w_full()
                        .py(px(24.0))
                        .px(px(16.0))
                        .flex()
                        .flex_col()
                        .items_center()
                        .gap(px(6.0))
                        .text_size(crate::typography::ui_rems(13.0))
                        .child("No results")
                        .child(
                            div()
                                .text_color(theme.text_muted)
                                .child("Try a pane, command, chat title, project, or device."),
                        ),
                )
            });
        let body = crate::edge_fade::edge_faded(RESULTS_FADE_BAND, true, true, body)
            .fade_overflow_y(&scroll);
        let card = div()
            .id("command-palette")
            .track_focus(&focus)
            .w(px(560.0_f32.min(f32::from(viewport.width) - 32.0)))
            .flex()
            .flex_col()
            .rounded(px(16.0))
            .border_1()
            .border_color(theme.border)
            .when(!theme.is_frost(), |el| el.shadow_lg())
            .bg(popover::surface_bg(&theme))
            .text_color(theme.text)
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    match event.keystroke.key.as_str() {
                        "up" | "down" => {
                            let count = this.command_entries(cx).len();
                            if count > 0
                                && let Some(palette) = this.command_palette.as_mut()
                            {
                                palette.active = if event.keystroke.key == "down" {
                                    (palette.active + 1) % count
                                } else {
                                    (palette.active + count - 1) % count
                                };
                                palette.scroll.scroll_to_item(palette.active);
                                cx.notify();
                            }
                        }
                        "enter" => {
                            let activate = this
                                .command_palette
                                .as_mut()
                                .is_some_and(|palette| palette.enter_press.press(event.is_held));
                            if !activate {
                                cx.stop_propagation();
                                return;
                            }
                            let entries = this.command_entries(cx);
                            if let Some(entry) = this
                                .command_palette
                                .as_ref()
                                .and_then(|p| entries.get(p.active))
                                .cloned()
                            {
                                this.activate_command(entry, window, cx);
                            }
                        }
                        "escape" => this.close_command_palette(window, cx),
                        _ => return,
                    }
                    cx.stop_propagation();
                }),
            )
            .on_key_up(cx.listener(|this, event: &gpui::KeyUpEvent, _, cx| {
                if event.keystroke.key == "enter" {
                    if let Some(palette) = this.command_palette.as_mut() {
                        palette.enter_press.release();
                    }
                    cx.stop_propagation();
                }
            }))
            .on_mouse_down_out(
                cx.listener(|this, _, window, cx| this.close_command_palette(window, cx)),
            )
            .child(
                div()
                    .min_h(px(44.0))
                    .flex_none()
                    .px(px(16.0))
                    .py(px(8.0))
                    .flex()
                    .items_center()
                    .gap(px(10.0))
                    .border_b_1()
                    .border_color(crate::theme::hairline(0.06))
                    .child(popover::palette_search_icon(&theme))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(crate::typography::ui_rems(14.0))
                            .child(search),
                    )
                    .child(popover::kbd_hint(
                        &theme,
                        &crate::settings::badge_combo("mod-k"),
                    )),
            )
            .child(body)
            .child(
                div()
                    .flex_none()
                    .px(px(16.0))
                    .py(px(7.0))
                    .border_t_1()
                    .border_color(crate::theme::hairline(0.06))
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap(px(12.0))
                    .child(command_key_hint(&theme, "↑ ↓", "Navigate"))
                    .child(command_key_hint(&theme, "↵", "Select"))
                    .child(command_key_hint(&theme, "Esc", "Close")),
            );
        // Match the composer's 16px backdrop blur, including its opaque fallback.
        let card = crate::frost::frosted(16.0, crate::frost::MENU_BLUR, card);
        Some(
            gpui::deferred(
                gpui::anchored()
                    .position(gpui::point(px(0.0), px(0.0)))
                    .child(
                        div()
                            .occlude()
                            .w(viewport.width)
                            .h(viewport.height)
                            // Match glass modals: quiet the background while
                            // preserving its color through the frosted palette.
                            .bg(popover::scrim_alpha(0.35))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(card),
                    ),
            )
            .priority(2)
            .into_any_element(),
        )
    }
}

#[cfg(feature = "appshots-fixture")]
impl CommandPalette {
    pub(super) fn fixture_type(&self, query: &str, cx: &mut App) {
        self.search.update(cx, |input, cx| input.set_text(query, cx));
    }
}

#[cfg(feature = "appshots-fixture")]
impl Shell {
    pub(super) fn fixture_command_palette_enter(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let entries = self.command_entries(cx);
        if let Some(entry) = self.command_palette.as_ref().and_then(|p| entries.get(p.active)).cloned() {
            self.activate_command(entry, window, cx);
        }
    }
}

fn command_key_hint(theme: &Theme, keys: &str, label: &'static str) -> gpui::Div {
    div()
        .flex()
        .items_center()
        .gap(px(5.0))
        .child(popover::kbd_hint(theme, keys))
        .child(
            div()
                .text_size(crate::typography::ui_rems(10.0))
                .text_color(theme.text_muted)
                .child(label),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::appearance::AppearanceMode;

    #[test]
    fn x11_unflagged_enter_repeats_activate_once_until_release() {
        let mut enter = EnterPress::default();
        // The pinned X11 backend drops synthetic repeat releases and emits
        // every repeated KeyDownEvent with is_held=false.
        assert!(enter.press(false));
        for _ in 0..35 {
            assert!(!enter.press(false));
        }
        enter.release();
        assert!(enter.press(false));
    }

    #[test]
    fn flagged_enter_repeats_do_not_activate() {
        let mut enter = EnterPress::default();
        assert!(!enter.press(true));
        assert!(!enter.press(false));
        enter.release();
        assert!(enter.press(false));
        assert!(!enter.press(true));
    }

    #[test]
    fn action_search_hides_empty_section_and_preserves_order() {
        assert_eq!(
            actions_for("", true),
            vec![
                Entry::NewChat,
                Entry::NewProject,
                Entry::Settings,
                Entry::Theme(AppearanceMode::Light)
            ]
        );
        assert_eq!(
            actions_for("new", true),
            vec![Entry::NewChat, Entry::NewProject]
        );
        assert_eq!(actions_for("settings", true), vec![Entry::Settings]);
        assert_eq!(
            actions_for("theme", true),
            vec![Entry::Theme(AppearanceMode::Light)]
        );
        assert!(actions_for("deployment", true).is_empty());
    }

    #[test]
    fn theme_action_targets_the_opposite_resolved_appearance() {
        assert_eq!(
            actions_for("theme", true),
            vec![Entry::Theme(AppearanceMode::Light)]
        );
        assert_eq!(
            actions_for("theme", false),
            vec![Entry::Theme(AppearanceMode::Dark)]
        );
        assert_eq!(
            actions_for("light", true),
            vec![Entry::Theme(AppearanceMode::Light)]
        );
        assert_eq!(
            actions_for("dark", false),
            vec![Entry::Theme(AppearanceMode::Dark)]
        );
    }

    #[test]
    fn open_panes_lead_then_actions_then_history() {
        let order = [
            Entry::Pane(2),
            Entry::NewChat,
            Entry::Chat("a".into()),
        ];
        assert!(order.windows(2).all(|w| w[0].section() < w[1].section()));
        assert_eq!(Entry::Pane(0).action(), None);
    }

    #[test]
    fn search_matches_words_across_chat_metadata() {
        assert!(matches_query(
            "mac auth",
            "Fix authentication Harness @ MacBook main"
        ));
        assert!(matches_query("  ", "Any chat"));
        assert!(!matches_query("mac windows", "Harness @ MacBook"));
    }
}
