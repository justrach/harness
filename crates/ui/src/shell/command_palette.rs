//! Global action and conversation search, using the sidebar's conversation rows.
use super::*;
use crate::appearance::AppearanceMode;
use std::collections::HashMap;

mod history_actions;
use history_actions::HistoryDiscardPrompt;

const HISTORY_RESULT_LIMIT: usize = 30;
/// Other tools' conversations are listed again when the palette opens only
/// after this long; until then the last list shows at once.
const EXTERNAL_REFRESH_AFTER: std::time::Duration = std::time::Duration::from_secs(60);
const RESULTS_FADE_BAND: f32 = 18.0;

#[derive(Clone, Copy, PartialEq, Eq)]
enum PaletteNavigation {
    PreserveTabs,
    ReplaceCurrent,
    OpenInPanel(u64),
    ChatHistory(Option<u64>),
}

impl PaletteNavigation {
    fn conversations_only(self) -> bool {
        matches!(self, Self::OpenInPanel(_) | Self::ChatHistory(_))
    }

    fn is_history(self) -> bool {
        matches!(self, Self::ChatHistory(_))
    }
}

pub(super) struct CommandPalette {
    navigation: PaletteNavigation,
    search: Entity<ComposerInput>,
    focus: FocusHandle,
    previous_focus: Option<FocusHandle>,
    active: usize,
    enter_press: EnterPress,
    // Claim focus during mount so the shell does not restore the composer
    // while this input is still absent from the dispatch tree.
    focus_pending: bool,
    scroll: gpui::ScrollHandle,
    /// The results as last rendered, and the query they answer; keys act on
    /// exactly what is on screen.
    entries: Vec<Entry>,
    entries_query: String,
    history_discard: Option<HistoryDiscardPrompt>,
    history_action_focus: HashMap<String, FocusHandle>,
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

/// A conversation another tool kept on this device, as the engine lists it.
#[derive(Clone, Debug, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ExternalSession {
    source: String,
    id: String,
    cwd: Option<String>,
    title: String,
    updated_at: i64,
}

impl ExternalSession {
    fn source_label(&self) -> &str {
        match self.source.as_str() {
            "claude" => "Claude Code",
            "codex" => "Codex",
            "graff" => "graff",
            other => other,
        }
    }

    fn folder(&self) -> &str {
        self.cwd
            .as_deref()
            .and_then(|cwd| cwd.rsplit('/').find(|part| !part.is_empty()))
            .unwrap_or("")
    }
}

/// How many other-tool conversations show before the person types anything.
const EXTERNAL_IDLE_LIMIT: usize = 5;

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
    /// An unsent conversation retained when its panel tab was closed.
    ClosedDraft(String),
    /// A conversation from another tool: picking it imports it, then opens it.
    External(String, String),
    /// Import every conversation from other tools.
    ImportAll,
}

impl Entry {
    fn action(&self) -> Option<(&'static str, &'static str)> {
        match self {
            Self::NewChat => Some(("New tab", icons::PLUS)),
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
            Self::Pane(_)
            | Self::Chat(_)
            | Self::ClosedDraft(_)
            | Self::External(..)
            | Self::ImportAll => None,
        }
    }

    /// Result groups, in display order: open panes, actions, chat history.
    fn section(&self) -> u8 {
        match self {
            Self::Pane(_) => 0,
            Self::Chat(_) | Self::ClosedDraft(_) => 2,
            Self::External(..) => 3,
            _ => 1,
        }
    }
}

fn matches_query(query: &str, text: &str) -> bool {
    let text = text.to_lowercase();
    query.split_whitespace().all(|word| text.contains(word))
}

fn closed_draft_title(closed: &settings::SavedClosedChat) -> String {
    let text = transcript::single_line(closed.draft.input.text.trim());
    if text.is_empty() {
        "Untitled draft".into()
    } else {
        text
    }
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
    pub(super) fn toggle_chat_history(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self
            .command_palette
            .as_ref()
            .is_some_and(|p| p.navigation.is_history())
        {
            self.close_command_palette(window, cx);
            return;
        }
        // A different palette is replaced, but opening history never changes
        // the selected workspace, route, or sidebar visibility.
        if self.command_palette.is_some() {
            self.close_command_palette(window, cx);
        }
        let panel = self.panel_layout(cx).map(|layout| layout.focused);
        self.toggle_command_palette_with_navigation(
            PaletteNavigation::ChatHistory(panel),
            window,
            cx,
        );
    }

    pub(super) fn reset_command_palette_key_state(&mut self) {
        if let Some(palette) = self.command_palette.as_mut() {
            palette.enter_press.release();
        }
    }

    pub(super) fn toggle_command_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.toggle_command_palette_with_navigation(PaletteNavigation::PreserveTabs, window, cx);
    }

    pub(super) fn toggle_resume_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.toggle_command_palette_with_navigation(PaletteNavigation::ReplaceCurrent, window, cx);
    }

    pub(super) fn open_conversation_palette_in_panel(
        &mut self,
        panel: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.toggle_command_palette_with_navigation(
            PaletteNavigation::OpenInPanel(panel),
            window,
            cx,
        );
    }

    fn toggle_command_palette_with_navigation(
        &mut self,
        navigation: PaletteNavigation,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.command_palette.is_some() {
            self.close_command_palette(window, cx);
            return;
        }
        self.add_space = None;
        self.sidebar_search = None;
        let placeholder = if navigation.is_history() {
            "Search chats across projects…"
        } else if navigation.conversations_only() {
            "Search conversations…"
        } else if self
            .chat_split
            .as_ref()
            .is_some_and(|split| split.panes.len() > 1)
        {
            "Search open panes, commands and chats…"
        } else {
            "Search commands and chats…"
        };
        let search = cx.new(|cx| ComposerInput::with_context(placeholder, "PaletteSearch", cx));
        // Typing and arrowing change only the palette, so they never notify
        // Shell: the cached sidebar observes Shell and would re-render every
        // conversation row per key. The search input notifies itself on each
        // edit, which redraws its ancestors (Shell, this palette) and leaves
        // sibling caches alone; `window.refresh()` would drop every cache.
        let events = cx.subscribe(&search, |this, _, event, _| {
            if matches!(event, ComposerInputEvent::Edited)
                && let Some(palette) = this.command_palette.as_mut()
            {
                palette.active = 0;
                palette.scroll.set_offset(gpui::point(px(0.0), px(0.0)));
            }
        });
        let previous_focus = window.focused(cx);
        let stale = self
            .external_loaded_at
            .is_none_or(|at| at.elapsed() >= EXTERNAL_REFRESH_AFTER);
        if stale && !navigation.conversations_only() {
            self.load_external_sessions(cx);
        }
        self.command_palette = Some(CommandPalette {
            navigation,
            search,
            focus: cx.focus_handle(),
            previous_focus,
            active: 0,
            enter_press: EnterPress::default(),
            focus_pending: true,
            scroll: gpui::ScrollHandle::new(),
            entries: Vec::new(),
            entries_query: String::new(),
            history_discard: None,
            history_action_focus: HashMap::new(),
            _search_events: events,
        });
        cx.notify();
    }

    pub(super) fn reopen_closed_chat_from_keyboard(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.history_discard_is_open() {
            return false;
        }
        if self
            .command_palette
            .as_ref()
            .is_some_and(|palette| palette.navigation.is_history())
        {
            self.close_command_palette(window, cx);
        }
        self.reopen_closed_chat_tab(window, cx)
    }

    pub(super) fn close_command_palette(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.history_discard_is_open() {
            self.cancel_history_discard(window, cx);
            return;
        }
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
        let conversations_only = palette.navigation.conversations_only();
        let hidden = if palette.navigation.is_history() && query.is_empty() {
            settings::hidden_history_entries(cx)
        } else {
            Vec::new()
        };
        // Open panes lead: with several chats side by side, "take me to that
        // one" is the common search. Their chats leave the history list.
        let mut entries = Vec::new();
        let mut in_panes: Vec<String> = Vec::new();
        if let Some(split) = self
            .chat_split
            .as_ref()
            .filter(|_| !conversations_only && matches!(self.route, Route::Chat))
        {
            for ix in (0..split.panes.len()).filter(|&ix| ix != split.focus) {
                in_panes.extend(split.panes[ix].clone());
                let (title, project) = self.pane_label(ix, cx);
                if matches_query(&query, &format!("{title} {project}")) {
                    entries.push(Entry::Pane(ix));
                }
            }
        }
        if !conversations_only {
            entries.extend(actions_for(&query, Theme::of(cx).appearance.is_dark()));
        }
        if !conversations_only
            && !self.external_sessions.is_empty()
            && matches_query(&query, "import conversations from other tools")
        {
            entries.push(Entry::ImportAll);
        }
        let state = self.state.read(cx);
        // Global history deliberately ignores the sidebar's project filter and
        // collapsed groups. Archived conversations remain searchable too.
        let mut chats: Vec<_> = state
            .chats
            .iter()
            .filter(|chat| !in_panes.contains(&chat.id))
            .filter(|chat| !hidden.contains(&format!("chat:{}", chat.id)))
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
        if palette.navigation.is_history() {
            for closed in settings::recently_closed_chats(cx) {
                if let Some(id) = closed.chat_id.as_deref() {
                    if let Some(index) = chats.iter().position(|chat| chat.id == id) {
                        entries.push(Entry::Chat(chats.remove(index).id.clone()));
                    }
                } else {
                    if hidden.contains(&format!("draft:{}", closed.id)) {
                        continue;
                    }
                    let title = closed_draft_title(&closed);
                    let project = closed
                        .draft
                        .input
                        .target
                        .as_ref()
                        .and_then(|target| target.space.as_deref())
                        .and_then(|id| state.spaces.iter().find(|space| space.id == id))
                        .map(|space| space.display_name())
                        .unwrap_or("");
                    if matches_query(&query, &format!("{title} {project} draft")) {
                        entries.push(Entry::ClosedDraft(closed.id));
                    }
                }
            }
        }
        // Limit after filtering and sorting so every chat remains searchable.
        entries.extend(
            chats
                .into_iter()
                .take(if palette.navigation.is_history() {
                    HISTORY_RESULT_LIMIT.saturating_sub(entries.len())
                } else {
                    HISTORY_RESULT_LIMIT
                })
                .map(|chat| Entry::Chat(chat.id.clone())),
        );
        if conversations_only {
            entries.truncate(HISTORY_RESULT_LIMIT);
            return entries;
        }
        let external_limit = if query.is_empty() {
            EXTERNAL_IDLE_LIMIT
        } else {
            HISTORY_RESULT_LIMIT
        };
        entries.extend(
            self.external_sessions
                .iter()
                .filter(|row| {
                    matches_query(
                        &query,
                        &format!("{} {} {}", row.title, row.source_label(), row.folder()),
                    )
                })
                .take(external_limit)
                .map(|row| Entry::External(row.source.clone(), row.id.clone())),
        );
        entries
    }

    /// Ask the engine which conversations other tools kept on this device.
    fn load_external_sessions(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.external_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(
                    harness_rpc::methods::EXTERNAL_HISTORY_LIST,
                    serde_json::json!({ "limit": 400 }),
                )
                .await;
            this.update(cx, |shell, cx| {
                if let Some(rows) = result
                    .ok()
                    .and_then(|v| serde_json::from_value::<Vec<ExternalSession>>(v).ok())
                {
                    shell.external_sessions = rows;
                    shell.external_loaded_at = Some(std::time::Instant::now());
                    cx.notify();
                }
            })
            .ok();
        }));
    }

    /// Import conversations from other tools: the named ones (then open the first), or all.
    fn import_external(&mut self, picks: Vec<(String, String)>, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let all = picks.is_empty();
        let params = if all {
            serde_json::json!({})
        } else {
            let sessions: Vec<_> = picks
                .iter()
                .map(|(source, id)| serde_json::json!({ "source": source, "id": id }))
                .collect();
            serde_json::json!({ "sessions": sessions })
        };
        if all {
            self.sidebar_notice = Some("Importing conversations from other tools…".into());
            cx.notify();
        }
        self.external_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(harness_rpc::methods::EXTERNAL_HISTORY_IMPORT, params)
                .await;
            this.update(cx, |shell, cx| {
                let summary = result.as_ref().ok();
                let ids: Vec<String> = summary
                    .and_then(|v| v["chatIds"].as_array())
                    .map(|a| {
                        a.iter()
                            .filter_map(|v| v.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
                let errors = summary
                    .and_then(|v| v["errors"].as_array())
                    .map(Vec::len)
                    .unwrap_or(0);
                // Imported ones are in the sidebar now; stop offering them.
                shell
                    .external_sessions
                    .retain(|row| !ids.contains(&format!("ext-{}-{}", row.source, row.id)));
                match (&result, all) {
                    (Err(err), _) => {
                        shell.sidebar_notice = Some(format!("Import failed: {err}").into())
                    }
                    (Ok(_), true) => {
                        shell.sidebar_notice = Some(
                            match (ids.len(), errors) {
                                (0, 0) => "Nothing new to import".to_string(),
                                (n, 0) => format!("Imported {n} conversations"),
                                (n, e) => {
                                    format!("Imported {n} conversations; {e} could not be read")
                                }
                            }
                            .into(),
                        )
                    }
                    (Ok(_), false) => match ids.first() {
                        Some(id) => shell.open_chat(id.clone(), cx),
                        None => {
                            shell.sidebar_notice =
                                Some("That conversation could not be imported".into())
                        }
                    },
                }
                cx.notify();
            })
            .ok();
        }));
    }

    fn activate_command(&mut self, entry: Entry, window: &mut Window, cx: &mut Context<Self>) {
        if self.history_discard_is_open() {
            return;
        }
        if let Entry::Theme(mode) = entry {
            // Keep the palette open so this ordinary action updates to its next state.
            crate::appearance::set_mode(mode, cx);
            cx.notify();
            return;
        }
        // /resume is an intentional current-tab replacement, unlike global
        // search. Capture the invocation's policy before closing the palette.
        let replace_current = self
            .command_palette
            .as_ref()
            .is_some_and(|palette| palette.navigation == PaletteNavigation::ReplaceCurrent);
        let history = self
            .command_palette
            .as_ref()
            .is_some_and(|p| p.navigation.is_history());
        let panel = self
            .command_palette
            .as_ref()
            .and_then(|palette| match palette.navigation {
                PaletteNavigation::OpenInPanel(panel) => Some(panel),
                PaletteNavigation::ChatHistory(panel) => panel,
                _ => None,
            });
        self.close_command_palette(window, cx);
        if self.session_overview
            && matches!(
                &entry,
                Entry::Chat(_)
                    | Entry::ClosedDraft(_)
                    | Entry::Pane(_)
                    | Entry::NewChat
                    | Entry::External(_, _)
                    | Entry::ImportAll
            )
        {
            self.close_session_overview(window, cx);
        }
        if history && matches!(&entry, Entry::Chat(_) | Entry::ClosedDraft(_)) {
            if !matches!(self.route, Route::Chat) {
                self.close_settings(cx);
            }
            self.ensure_workspace_sessions(cx);
            self.sync_panel_workspace(cx);
            let panel = panel
                .filter(|id| {
                    self.panel_layout(cx)
                        .is_some_and(|layout| layout.panels.iter().any(|panel| panel.id == *id))
                })
                .unwrap_or_else(|| self.panel_layout(cx).unwrap().focused);
            match entry {
                Entry::Chat(id) => {
                    if !self.restore_closed_chat_in_panel(&id, panel, window, cx) {
                        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                            settings.unhide_history_entry(&format!("chat:{id}"));
                        });
                        self.settings.hidden_history_entries = settings::hidden_history_entries(cx);
                        if self
                            .state
                            .read(cx)
                            .chats
                            .iter()
                            .any(|chat| chat.id == id && chat.archived)
                        {
                            self.set_chat_archived(id.clone(), false, cx);
                        }
                        self.focus_workspace_tab(
                            panel,
                            workspace_panels::PanelTab::Chat(id.clone()),
                            window,
                            cx,
                        );
                        self.reveal_workspace_chat(id, cx);
                        self.persist_chat_tabs(cx);
                    }
                }
                Entry::ClosedDraft(id) => {
                    self.restore_closed_chat_in_panel(&id, panel, window, cx);
                }
                _ => unreachable!(),
            }
            return;
        }
        match entry {
            Entry::NewChat => {
                self.workspace_new_tab(cx);
                self.focus_workspace_new_tab(window, cx);
            }
            Entry::NewProject => self.open_add_space(cx),
            Entry::Settings => {
                let section = self.remembered_settings_section();
                self.open_settings(section, cx)
            }
            Entry::Theme(_) => unreachable!(),
            Entry::External(source, id) => self.import_external(vec![(source, id)], cx),
            Entry::ImportAll => self.import_external(Vec::new(), cx),
            Entry::Pane(ix) => self.focus_chat_pane(ix, window, cx),
            Entry::Chat(id) if panel.is_some() => {
                self.focus_workspace_tab(
                    panel.unwrap(),
                    workspace_panels::PanelTab::Chat(id.clone()),
                    window,
                    cx,
                );
                self.reveal_workspace_chat(id, cx);
                self.persist_chat_tabs(cx);
            }
            Entry::Chat(id) if replace_current => {
                self.open_chat(id, cx);
                window.focus(&self.composer.focus_handle(cx), cx);
            }
            Entry::Chat(id) => self.open_chat_in_tab(id, window, cx),
            Entry::ClosedDraft(_) => {}
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

    fn render_history_result(
        &mut self,
        entry: &Entry,
        selected: bool,
        query: &str,
        recent: &[settings::SavedClosedChat],
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.state.read(cx);
        let (key, title, project, when, draft) = match entry {
            Entry::Chat(id) => {
                let Some(chat) = state.chats.iter().find(|chat| &chat.id == id) else {
                    return div().into_any_element();
                };
                let closed = recent
                    .iter()
                    .find(|record| record.chat_id.as_ref() == Some(id));
                let time = closed.and_then(|record| {
                    chrono::DateTime::<Utc>::from_timestamp_millis(record.closed_at)
                });
                let when = time
                    .map(|at| format!("Closed {}", format_time_ago(at, Utc::now())))
                    .unwrap_or_else(|| {
                        format_time_ago(chat.last_message_at.unwrap_or(chat.created_at), Utc::now())
                    });
                (
                    id.clone(),
                    transcript::single_line(chat.title.as_deref().unwrap_or("Untitled chat")),
                    state
                        .space_for_chat(chat)
                        .map(|space| space.display_name())
                        .unwrap_or("No project")
                        .to_string(),
                    when,
                    false,
                )
            }
            Entry::ClosedDraft(id) => {
                let Some(closed) = recent.iter().find(|record| &record.id == id) else {
                    return div().into_any_element();
                };
                let project = closed
                    .draft
                    .input
                    .target
                    .as_ref()
                    .and_then(|target| target.space.as_deref())
                    .and_then(|id| state.spaces.iter().find(|space| space.id == id))
                    .map(|space| space.display_name())
                    .unwrap_or("No project")
                    .to_string();
                let when = chrono::DateTime::<Utc>::from_timestamp_millis(closed.closed_at)
                    .map(|at| format!("Closed {}", format_time_ago(at, Utc::now())))
                    .unwrap_or_default();
                (id.clone(), closed_draft_title(closed), project, when, true)
            }
            _ => return div().into_any_element(),
        };
        let detail = if draft {
            format!("Draft · {project} · {when}")
        } else {
            format!("{project} · {when}")
        };
        let restore = self.render_history_action(entry.clone(), &title, false, theme, cx);
        let discard = self.render_history_action(entry.clone(), &title, true, theme, cx);
        let entry = entry.clone();
        popover::menu_row(theme, selected, format!("history-chat-{key}"))
            .id(SharedString::from(format!("history-chat-{key}")))
            .debug_selector(move || format!("history-chat-{key}"))
            .rounded(px(popover::PALETTE_ITEM_RADIUS))
            .role(gpui::Role::Button)
            .aria_label(format!("Reopen {title}"))
            .min_h(px(48.0))
            .py(px(7.0))
            .on_click(cx.listener(move |this, _, window, cx| {
                this.activate_command(entry.clone(), window, cx)
            }))
            .child(
                icon(icons::CHAT_ROUND_LINE)
                    .size(px(16.0))
                    .flex_none()
                    .text_color(theme.text_muted),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(div().truncate().child(popover::search_highlight(
                        title.into(),
                        Some(query),
                        theme,
                    )))
                    .child(
                        div()
                            .truncate()
                            .text_size(crate::typography::ui_rems(11.0))
                            .text_color(theme.text_muted)
                            .child(SharedString::from(detail)),
                    ),
            )
            .child(
                div()
                    .flex()
                    .flex_none()
                    .items_center()
                    .gap(px(2.0))
                    .child(restore)
                    .child(discard),
            )
            .into_any_element()
    }

    pub(super) fn render_command_palette(
        &mut self,
        viewport: gpui::Size<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.history_discard_is_open() {
            return self.render_history_discard(viewport, window, cx);
        }
        let entries = self.command_entries(cx);
        let palette = self.command_palette.as_mut()?;
        palette.entries = entries.clone();
        palette.entries_query = palette.search.read(cx).text().to_string();
        if std::mem::take(&mut palette.focus_pending) {
            window.focus(&palette.search.focus_handle(cx), cx);
        }
        palette.active = palette.active.min(entries.len().saturating_sub(1));
        let active = palette.active;
        let history_only = palette.navigation.is_history();
        let resuming = matches!(palette.navigation, PaletteNavigation::OpenInPanel(_));
        let resume_close_focus = palette
            .history_action_focus
            .entry("resume-close".into())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let search = palette.search.clone();
        let query = search.read(cx).text().to_string();
        let focus = palette.focus.clone();
        let scroll = palette.scroll.clone();
        let theme = Theme::of(cx).for_popup();
        let recent = if history_only {
            settings::recently_closed_chats(cx)
        } else {
            Vec::new()
        };
        let mut history_section = None;
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
            if history_only {
                let closed = match entry {
                    Entry::ClosedDraft(_) => true,
                    Entry::Chat(id) => recent
                        .iter()
                        .any(|record| record.chat_id.as_deref() == Some(id)),
                    _ => false,
                };
                if history_section != Some(closed) {
                    history_section = Some(closed);
                    row = row.child(
                        div()
                            .px(px(16.0))
                            .pt(px(6.0))
                            .pb(px(5.0))
                            .text_size(crate::typography::ui_rems(11.0))
                            .text_color(theme.text_muted)
                            .child(if closed {
                                "Recently closed"
                            } else {
                                "All chats"
                            }),
                    );
                }
            }
            let content =
                if history_only {
                    self.render_history_result(entry, ix == active, &query, &recent, &theme, cx)
                } else if let Entry::Pane(pane) = entry {
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
                        .child(div().flex_1().min_w_0().truncate().child(
                            popover::search_highlight(title.into(), Some(&query), &theme),
                        ))
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
                } else if let Entry::ImportAll = entry {
                    let label = format!(
                        "Import {} conversations from other tools",
                        self.external_sessions.len()
                    );
                    popover::menu_row(&theme, ix == active, format!("command-import-{ix}"))
                        .id(("command-import", ix))
                        .rounded(px(popover::PALETTE_ITEM_RADIUS))
                        .role(gpui::Role::Button)
                        .aria_label(label.clone())
                        .min_h(px(30.0))
                        .py(px(4.0))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.activate_command(Entry::ImportAll, window, cx)
                        }))
                        .child(
                            div()
                                .w(px(16.0))
                                .flex_none()
                                .text_center()
                                .text_color(theme.text_muted)
                                .child(SharedString::from("↓")),
                        )
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .child(SharedString::from(label)),
                        )
                        .into_any_element()
                } else if let Entry::External(source, id) = entry {
                    let row = self
                        .external_sessions
                        .iter()
                        .find(|row| &row.source == source && &row.id == id)?;
                    let title = transcript::single_line(&row.title);
                    let when = chrono::TimeZone::timestamp_millis_opt(&Utc, row.updated_at)
                        .single()
                        .map(|at| format_time_ago(at, Utc::now()))
                        .unwrap_or_default();
                    let trailing = match row.folder() {
                        "" => format!("{} · {when}", row.source_label()),
                        folder => format!("{} · {folder} · {when}", row.source_label()),
                    };
                    let entry = entry.clone();
                    popover::menu_row(&theme, ix == active, format!("command-external-{ix}"))
                        .id(("command-external", ix))
                        .rounded(px(popover::PALETTE_ITEM_RADIUS))
                        .role(gpui::Role::Button)
                        .aria_label(format!("Import and open: {title}"))
                        .min_h(px(30.0))
                        .py(px(4.0))
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.activate_command(entry.clone(), window, cx)
                        }))
                        .child(
                            div()
                                .w(px(16.0))
                                .flex_none()
                                .text_center()
                                .text_color(theme.text_muted)
                                .child(SharedString::from("↓")),
                        )
                        .child(div().flex_1().min_w_0().truncate().child(
                            popover::search_highlight(title.into(), Some(&query), &theme),
                        ))
                        .child(
                            div()
                                .flex_none()
                                .max_w(px(260.0))
                                .truncate()
                                .text_size(crate::typography::ui_rems(11.0))
                                .text_color(theme.text_muted.opacity(0.7))
                                .child(SharedString::from(trailing)),
                        )
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
                    let pr = state
                        .change_request_for_chat(chat)
                        .cloned()
                        .map(|pr| (pr, state.change_request_provenance(chat)));
                    let harness = self
                        .settings
                        .sidebar_show_harness
                        .then(|| chat.config.as_ref().map(|c| c.harness))
                        .flatten();
                    self.render_chat_row(
                        id.clone(),
                        transcript::single_line(chat.title.as_deref().unwrap_or("New session"))
                            .into(),
                        format_time_ago(
                            chat.last_message_at.unwrap_or(chat.created_at),
                            Utc::now(),
                        )
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
                        Some(ChatRowSearch::Palette(&query)),
                        &theme,
                        cx,
                    )
                } else {
                    unreachable!()
                };
            rows.push(
                row.child(
                    div()
                        .px(px(if resuming { 12.0 } else { 8.0 }))
                        .child(content),
                ),
            );
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
                        .child(div().text_color(theme.text_muted).child(if history_only {
                            "Search a chat title, draft, project, or device."
                        } else {
                            if resuming {
                                "Search a conversation title, project, or device."
                            } else {
                                "Try a pane, command, chat title, project, or device."
                            }
                        })),
                )
            });
        let body = crate::edge_fade::edge_faded(RESULTS_FADE_BAND, true, true, body)
            .fade_overflow_y(&scroll);
        let card = if resuming {
            popover::popover_card_flush(&theme)
        } else {
            div()
                .border_1()
                .border_color(theme.border)
                .when(!theme.is_frost(), |el| el.shadow_lg())
                .bg(popover::surface_bg(&theme))
        }
        .id("command-palette")
        .debug_selector(move || {
            if resuming {
                "resume-conversation-dialog".into()
            } else {
                "command-palette".into()
            }
        })
        .when(resuming, |card| {
            card.role(gpui::Role::Dialog)
                .aria_label("Resume conversation")
        })
        .track_focus(&focus)
        .w(px((if history_only {
            420.0_f32
        } else if resuming {
            600.0_f32
        } else {
            560.0_f32
        })
        .min(f32::from(viewport.width) - 32.0)))
        .flex()
        .flex_col()
        .rounded(px(if resuming { 14.0 } else { 16.0 }))
        .text_color(theme.text)
        .on_key_down(
            cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                match event.keystroke.key.as_str() {
                    "up" | "down" => {
                        if let Some(palette) = this.command_palette.as_mut()
                            && !palette.entries.is_empty()
                        {
                            let count = palette.entries.len();
                            palette.active = if event.keystroke.key == "down" {
                                (palette.active + 1) % count
                            } else {
                                (palette.active + count - 1) % count
                            };
                            palette.scroll.scroll_to_item(palette.active);
                            // Redraw through the input, not Shell (see toggle_command_palette).
                            palette.search.update(cx, |_, cx| cx.notify());
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
                        // Typed and entered within one frame: answer the new query.
                        let stale = this
                            .command_palette
                            .as_ref()
                            .is_some_and(|p| p.entries_query != p.search.read(cx).text());
                        if stale {
                            let entries = this.command_entries(cx);
                            if let Some(palette) = this.command_palette.as_mut() {
                                palette.entries = entries;
                            }
                        }
                        if let Some(entry) = this
                            .command_palette
                            .as_ref()
                            .and_then(|p| p.entries.get(p.active))
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
        .when(history_only, |card| {
            card.child(
                div()
                    .px(px(16.0))
                    .pt(px(12.0))
                    .pb(px(4.0))
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(8.0))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(
                                div()
                                    .debug_selector(|| "chat-history-title-icon".into())
                                    .size(px(16.0))
                                    .flex_none()
                                    .child(
                                        icon(icons::CLOCK_CIRCLE)
                                            .size(px(16.0))
                                            .text_color(theme.text_muted),
                                    ),
                            )
                            .child("Chat history"),
                    )
                    .child(
                        div()
                            .id("chat-history-dismiss")
                            .debug_selector(|| "chat-history-dismiss".into())
                            .role(gpui::Role::Button)
                            .aria_label("Close Chat history")
                            .cursor_pointer()
                            .p(px(4.0))
                            .rounded(px(5.0))
                            .hover(|style| style.bg(theme.ink(0.08)))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_command_palette(window, cx)
                            }))
                            .child(
                                icon(icons::CLOSE)
                                    .size(px(12.0))
                                    .text_color(theme.text_muted),
                            ),
                    ),
            )
        })
        .when(resuming, |card| {
            card.child(
                div()
                    .px(px(20.0))
                    .pt(px(16.0))
                    .pb(px(10.0))
                    .flex()
                    .items_center()
                    .gap(px(8.0))
                    .child(
                        icon(icons::CLOCK_CIRCLE)
                            .size(px(16.0))
                            .text_color(theme.text_muted),
                    )
                    .child(
                        div()
                            .flex_1()
                            .text_size(crate::typography::ui_rems(15.0))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child("Resume conversation"),
                    )
                    .child(
                        div()
                            .id("resume-conversation-close")
                            .role(gpui::Role::Button)
                            .aria_label("Close Resume conversation")
                            .track_focus(&resume_close_focus)
                            .focus_visible(|el| el.bg(theme.element_hover))
                            .size(px(24.0))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(6.0))
                            .cursor_pointer()
                            .hover(|el| el.bg(theme.element_hover))
                            .on_key_down(cx.listener(
                                |this, event: &gpui::KeyDownEvent, window, cx| {
                                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                        this.close_command_palette(window, cx);
                                        cx.stop_propagation();
                                    }
                                },
                            ))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.close_command_palette(window, cx)
                            }))
                            .child(
                                icon(icons::CLOSE)
                                    .size(px(12.0))
                                    .text_color(theme.text_muted),
                            ),
                    ),
            )
            .child(
                div().px(px(12.0)).pb(px(8.0)).child(
                    div()
                        .id("resume-conversation-search")
                        .debug_selector(|| "resume-conversation-search".into())
                        .w_full()
                        .h(px(32.0))
                        .px(px(7.0))
                        .flex()
                        .items_center()
                        .gap(px(8.0))
                        .rounded(px(8.0))
                        .border_1()
                        .border_color(theme.border)
                        .bg(theme.surface_raised)
                        .child(popover::palette_search_icon(&theme))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_size(crate::typography::ui_rems(14.0))
                                .child(search.clone()),
                        ),
                ),
            )
        })
        .when(!resuming, |card| {
            card.child(
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
                    .when(!history_only, |row| {
                        row.child(popover::kbd_hint(
                            &theme,
                            &crate::settings::badge_combo("mod-k"),
                        ))
                    }),
            )
        })
        .child(body)
        .when(!history_only && !resuming, |card| {
            card.child(
                div()
                    .debug_selector(|| "command-palette-keyboard-hints".into())
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
            )
        });
        if resuming {
            return Some(popover::modal_glass(
                "resume-conversation-modal",
                viewport,
                card.into_any_element(),
                14.0,
            ));
        }
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
                            .when(!history_only, |el| el.bg(popover::scrim_alpha(0.35)))
                            .flex()
                            .when(!history_only, |el| el.items_center().justify_center())
                            .when(history_only, |el| {
                                let footer = matches!(self.route, Route::Chat)
                                    && !self.session_overview
                                    && !self.settings.sidebar_collapsed;
                                let width = 420.0_f32.min(f32::from(viewport.width) - 32.0);
                                let left = if footer {
                                    self.settings.sidebar_width - 44.0
                                } else {
                                    16.0
                                };
                                let left = left
                                    .max(16.0)
                                    .min((f32::from(viewport.width) - width - 16.0).max(16.0));
                                el.flex_col()
                                    .items_start()
                                    .pl(px(left))
                                    .when(footer, |el| el.justify_end().pb(px(52.0)))
                                    .when(!footer, |el| el.justify_start().pt(px(50.0)))
                            })
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
        self.search
            .update(cx, |input, cx| input.set_text(query, cx));
    }
}

#[cfg(feature = "appshots-fixture")]
impl Shell {
    pub(super) fn fixture_chat_history_palette_state(&self, cx: &App) -> serde_json::Value {
        let entries: Vec<_> = self
            .command_entries(cx)
            .iter()
            .map(|entry| match entry {
                Entry::Chat(id) => {
                    let chat = self
                        .state
                        .read(cx)
                        .chats
                        .iter()
                        .find(|chat| &chat.id == id)
                        .cloned();
                    serde_json::json!({"kind":"chat", "id":id, "chatId":id,
                    "title":chat.as_ref().and_then(|chat| chat.title.as_deref()),
                    "archived":chat.as_ref().is_some_and(|chat| chat.archived)})
                }
                Entry::ClosedDraft(id) => serde_json::json!({"kind":"closed", "id":id}),
                Entry::External(_, id) => serde_json::json!({"kind":"external", "id":id}),
                _ => serde_json::json!({"kind":"action"}),
            })
            .collect();
        serde_json::json!({
            "open":self.command_palette.is_some(),
            "historyOnly":self.command_palette.as_ref().is_some_and(|p| p.navigation.is_history()),
            "query":self.command_palette.as_ref().map(|p| p.search.read(cx).text().to_string()),
            "entries":entries,
            "discardOpen":self.history_discard_is_open(),
            "discardBusy":self.history_discard_is_busy(),
        })
    }

    pub(super) fn fixture_command_palette_enter(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let entries = self.command_entries(cx);
        if let Some(entry) = self
            .command_palette
            .as_ref()
            .and_then(|p| entries.get(p.active))
            .cloned()
        {
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

    #[gpui::test]
    fn chat_history_palette_preserves_sidebar_and_route_until_selection(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, window, cx| {
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                for collapsed in [false, true] {
                    shell.settings.sidebar_collapsed = collapsed;
                    let selected = shell.state.read(cx).selected_chat.clone();
                    shell.toggle_chat_history(window, cx);
                    assert!(
                        shell
                            .command_palette
                            .as_ref()
                            .unwrap()
                            .navigation
                            .is_history()
                    );
                    assert_eq!(shell.settings.sidebar_collapsed, collapsed);
                    assert_eq!(shell.state.read(cx).selected_chat, selected);
                    assert!(
                        shell
                            .command_entries(cx)
                            .iter()
                            .all(|entry| matches!(entry, Entry::Chat(_) | Entry::ClosedDraft(_)))
                    );
                    shell.close_command_palette(window, cx);
                    assert_eq!(shell.settings.sidebar_collapsed, collapsed);
                }
                shell.toggle_command_palette(window, cx);
                shell.toggle_chat_history(window, cx);
                assert!(
                    shell
                        .command_palette
                        .as_ref()
                        .unwrap()
                        .navigation
                        .is_history()
                );
                shell.toggle_chat_history(window, cx);
                assert!(shell.command_palette.is_none());
            })
            .unwrap();
    }

    #[gpui::test]
    fn chat_history_palette_searches_archived_chats_outside_project_filter(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, window, cx| {
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                shell.state.update(cx, |state, _| {
                    let chat = state
                        .chats
                        .iter_mut()
                        .find(|chat| chat.id == "target")
                        .unwrap();
                    chat.archived = true;
                    chat.title = Some("Recover the archived launch notes".into());
                });
                assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
                shell.toggle_chat_history(window, cx);
                shell
                    .command_palette
                    .as_ref()
                    .unwrap()
                    .search
                    .update(cx, |input, cx| input.set_text("archived launch", cx));
                assert_eq!(
                    shell.command_entries(cx),
                    vec![Entry::Chat("target".into())]
                );
                shell.close_command_palette(window, cx);
                assert_eq!(shell.settings.space_filter.as_deref(), Some("a"));
            })
            .unwrap();
    }

    #[gpui::test]
    fn chat_history_palette_recent_closes_lead_and_restore_without_duplicate_tabs(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                let session = shell.chat_tabs[shell.chat_tab].id.clone();
                assert!(shell.workspace_close_focused(window, cx));
                shell.toggle_chat_history(window, cx);
                assert_eq!(
                    shell.command_entries(cx).first(),
                    Some(&Entry::Chat("current".into()))
                );
                shell.activate_command(Entry::Chat("current".into()), window, cx);
                assert_eq!(shell.chat_tabs[shell.chat_tab].id, session);
                for _ in 0..2 {
                    shell.toggle_chat_history(window, cx);
                    shell.activate_command(Entry::Chat("current".into()), window, cx);
                }
                assert_eq!(
                    shell
                        .panel_layout(cx)
                        .unwrap()
                        .panels
                        .iter()
                        .flat_map(|panel| &panel.tabs)
                        .filter(|tab| **tab == workspace_panels::PanelTab::Chat("current".into()))
                        .count(),
                    1
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn chat_history_palette_keyboard_recovery_dismisses_history_when_session_is_gone(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                assert!(shell.workspace_close_focused(window, cx));
                settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                    for record in &mut settings.recently_closed_chats {
                        record.session_id = "removed-session".into();
                    }
                });
                shell.toggle_chat_history(window, cx);
                assert!(shell.reopen_closed_chat_from_keyboard(window, cx));
                assert!(shell.command_palette.is_none());
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn overview_command_selection_reveals_the_conversation(cx: &mut gpui::TestAppContext) {
        use crate::shell::chat_tabs::navigation_tests::{assert_target_preserved, fixture};
        let (_dir, window) = fixture(cx, true, Some(true));
        window
            .update(cx, |shell, window, cx| {
                shell.boot_restored = true;
                let layout = shell.chat_split.clone();
                shell.open_session_overview(window, cx);
                shell.toggle_command_palette(window, cx);
                assert!(shell.session_overview);
                assert!(shell.command_palette.is_some());
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );

                shell.activate_command(Entry::Chat("target".into()), window, cx);

                assert!(!shell.session_overview);
                assert!(shell.command_palette.is_none());
                assert_target_preserved(shell, cx);
                assert_eq!(shell.chat_tabs[0].split, layout);
            })
            .unwrap();
    }

    #[gpui::test]
    fn panel_history_picker_opens_and_refocuses_conversations_in_the_same_session(
        cx: &mut gpui::TestAppContext,
    ) {
        use crate::shell::chat_tabs::navigation_tests::fixture;
        use crate::shell::workspace_panels::PanelTab;
        let (_dir, window) = fixture(cx, false, None);
        window
            .update(cx, |shell, window, cx| {
                shell.ensure_workspace_sessions(cx);
                shell.sync_panel_workspace(cx);
                let session = shell.chat_tabs[shell.chat_tab].id.clone();
                let sessions = shell.chat_tabs.len();
                shell.workspace_split(SplitAxis::Vertical, cx);
                let destination = shell.panel_layout(cx).unwrap().focused;
                shell.open_conversation_palette_in_panel(destination, window, cx);
                assert!(
                    shell
                        .command_entries(cx)
                        .iter()
                        .all(|entry| matches!(entry, Entry::Chat(_)))
                );
                shell.activate_command(Entry::Chat("target".into()), window, cx);
                let first = shell
                    .panel_layout(cx)
                    .unwrap()
                    .location(&PanelTab::Chat("target".into()))
                    .unwrap();
                assert_eq!(first.0, destination);
                assert_eq!(shell.chat_tabs.len(), sessions);
                assert_eq!(shell.chat_tabs[shell.chat_tab].id, session);
                assert!(
                    shell
                        .panel_layout(cx)
                        .unwrap()
                        .location(&PanelTab::Chat("current".into()))
                        .is_some()
                );

                let origin = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panels
                    .iter()
                    .find(|panel| panel.id != destination)
                    .unwrap()
                    .id;
                shell.open_conversation_palette_in_panel(origin, window, cx);
                shell.activate_command(Entry::Chat("target".into()), window, cx);
                let layout = shell.panel_layout(cx).unwrap();
                assert_eq!(
                    layout.location(&PanelTab::Chat("target".into())),
                    Some(first)
                );
                assert_eq!(layout.focused, destination);
                assert_eq!(
                    layout
                        .panels
                        .iter()
                        .flat_map(|panel| &panel.tabs)
                        .filter(|tab| **tab == PanelTab::Chat("target".into()))
                        .count(),
                    1
                );
                assert_eq!(shell.chat_tabs.len(), sessions);
                assert_eq!(shell.chat_tabs[shell.chat_tab].id, session);
            })
            .unwrap();
    }

    #[gpui::test]
    fn chat_search_results_preserve_tabs_and_reveal_parked_panes(cx: &mut gpui::TestAppContext) {
        use crate::shell::chat_tabs::navigation_tests::{assert_target_preserved, fixture};
        for parked in [None, Some(false), Some(true)] {
            let (_dir, window) = fixture(cx, true, parked);
            window
                .update(cx, |shell, window, cx| {
                    let layout = shell.chat_split.clone();
                    for _ in 0..2 {
                        shell.toggle_command_palette(window, cx);
                        shell.activate_command(Entry::Chat("target".into()), window, cx);
                        assert!(shell.command_palette.is_none());
                        assert_target_preserved(shell, cx);
                        assert_eq!(shell.chat_tabs[0].split, layout);
                    }
                })
                .unwrap();
        }
    }

    #[gpui::test]
    fn resume_search_reveals_the_conversations_project(cx: &mut gpui::TestAppContext) {
        use crate::shell::chat_tabs::navigation_tests::{assert_target_preserved, fixture};
        for split in [false, true] {
            for parked in [None, Some(false), Some(true)] {
                let (_dir, window) = fixture(cx, split, parked);
                let layout = window
                    .update(cx, |shell, _, _| shell.chat_split.clone())
                    .unwrap();
                for _ in 0..2 {
                    window
                        .update(cx, |shell, window, cx| {
                            shell.pending_workspace_command =
                                Some(crate::composer::WorkspaceCommand::Resume);
                            let _ = shell.render(window, cx);
                            assert!(shell.command_palette.is_some());
                            shell.activate_command(Entry::Chat("target".into()), window, cx);
                            assert!(shell.command_palette.is_none());
                        })
                        .unwrap();
                    cx.run_until_parked();
                    window
                        .update(cx, |shell, _, cx| {
                            assert_target_preserved(shell, cx);
                            assert_eq!(shell.chat_tabs[0].split, layout);
                            assert_eq!(shell.settings.space_filter.as_deref(), Some("b"));
                        })
                        .unwrap();
                }
                window
                    .update(cx, |shell, window, cx| {
                        shell.toggle_resume_palette(window, cx);
                        shell.close_command_palette(window, cx);
                        shell.toggle_command_palette(window, cx);
                        shell.activate_command(Entry::Chat("current".into()), window, cx);
                        assert_eq!(shell.chat_tab, 0);
                        assert_eq!(shell.chat_split, layout);
                        assert_eq!(
                            shell.state.read(cx).selected_chat.as_deref(),
                            Some("current")
                        );
                    })
                    .unwrap();
            }
        }
    }

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
        let order = [Entry::Pane(2), Entry::NewChat, Entry::Chat("a".into())];
        assert!(order.windows(2).all(|w| w[0].section() < w[1].section()));
        assert_eq!(Entry::Pane(0).action(), None);
    }

    #[test]
    fn other_tools_conversations_come_after_chat_history() {
        let order = [
            Entry::Chat("a".into()),
            Entry::External("claude".into(), "s1".into()),
        ];
        assert!(order[0].section() < order[1].section());
        assert_eq!(Entry::ImportAll.section(), Entry::NewChat.section());
    }

    #[test]
    fn an_external_row_names_its_tool_and_folder() {
        let row: ExternalSession = serde_json::from_value(serde_json::json!({
            "source": "codex", "id": "c1", "cwd": "/work/app/", "title": "add a retry",
            "updatedAt": 1, "startedAt": 0, "size": 10, "path": "/x"
        }))
        .unwrap();
        assert_eq!(row.source_label(), "Codex");
        assert_eq!(row.folder(), "app");
    }

    #[gpui::test]
    fn resume_reuses_the_owning_project_and_keeps_other_views(cx: &mut gpui::TestAppContext) {
        for split in [false, true] {
            for parked in [None, Some(false), Some(true)] {
                let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, split, parked);
                window
                    .update(cx, |shell, window, cx| {
                        let layout = shell.chat_split.clone();
                        shell.toggle_resume_palette(window, cx);
                        shell.activate_command(Entry::Chat("target".into()), window, cx);
                        chat_tabs::navigation_tests::assert_target_preserved(shell, cx);
                        assert_eq!(shell.chat_tabs[0].split, layout);
                    })
                    .unwrap();
            }
        }
    }

    #[gpui::test]
    fn typing_in_the_palette_leaves_the_sidebar_cached(cx: &mut gpui::TestAppContext) {
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
            crate::app_menus::init(cx);
            crate::history::init(
                Default::default(),
                Default::default(),
                Default::default(),
                Default::default(),
                cx,
            );
        });
        let data_dir = dir.path().to_path_buf();
        let (shell, cx) = cx.add_window_view(|_, cx| {
            let state = cx.new(|_| AppState::new());
            Shell::new(
                state,
                EngineBootConfig {
                    data_dir,
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            )
        });
        shell.update_in(cx, |shell, window, cx| {
            shell.state.update(cx, |state, _| {
                state.workspace_scope = Some(WorkspaceScope::Local);
                state.local_device_id = Some("local".into());
                state.chats_synced = true;
                state.chats = (0..200)
                    .map(|i| {
                        serde_json::from_value(serde_json::json!({
                            "id": format!("chat-{i}"), "title": format!("Chat number {i}"),
                            "deviceId": "local", "archived": false,
                            "createdAt": "2026-09-20T00:00:00Z"
                        }))
                        .unwrap()
                    })
                    .collect();
            });
            shell.debug_gate = Some(GatePhase::Ready);
            shell.toggle_command_palette(window, cx);
        });
        cx.simulate_resize(gpui::size(px(1200.0), px(800.0)));
        // Let the sidebar's open animation settle: a moving width re-renders it.
        for _ in 0..3 {
            cx.executor()
                .advance_clock(std::time::Duration::from_secs(2));
            cx.run_until_parked();
        }
        let before = crate::shell::SIDEBAR_RENDERS.with(|n| n.get());
        assert!(before > 0, "the window drew the sidebar");
        for query in ["c", "ch", "chat 1", "chat 19"] {
            shell.update(cx, |shell, cx| {
                let search = shell.command_palette.as_ref().unwrap().search.clone();
                search.update(cx, |input, cx| input.set_text(query, cx));
            });
            cx.run_until_parked();
        }
        let (query, entries) = shell.read_with(cx, |shell, _| {
            let palette = shell.command_palette.as_ref().unwrap();
            (palette.entries_query.clone(), palette.entries.clone())
        });
        assert_eq!(query, "chat 19", "the palette redrew for the last query");
        assert!(entries.contains(&Entry::Chat("chat-19".into())));
        assert_eq!(
            crate::shell::SIDEBAR_RENDERS.with(|n| n.get()),
            before,
            "typing in the palette re-rendered the sidebar"
        );

        // The window's first key event settles focus once; count from after it.
        cx.simulate_keystrokes("down");
        cx.run_until_parked();
        let before = crate::shell::SIDEBAR_RENDERS.with(|n| n.get());
        cx.simulate_keystrokes("down down up");
        cx.run_until_parked();
        let active = shell.read_with(cx, |shell, _| {
            shell.command_palette.as_ref().unwrap().active
        });
        assert_eq!(active, 2, "arrows moved the selection");
        assert_eq!(
            crate::shell::SIDEBAR_RENDERS.with(|n| n.get()),
            before,
            "arrowing through results re-rendered the sidebar"
        );
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
