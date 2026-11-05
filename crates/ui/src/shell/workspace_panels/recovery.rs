//! Closing removes a local placement. Recovery keeps the same conversation and
//! its unsent draft, without stopping runs or changing other open placements.
use super::*;
use crate::settings::{SavedClosedChat, SavedWindowChatDraft};

impl Shell {
    pub(in crate::shell) fn next_chat_close_time(&self, cx: &App) -> i64 {
        let recent = settings::recently_closed_chats(cx)
            .first()
            .map_or(0, |record| record.closed_at);
        let session = self
            .closed_chat_tabs
            .last()
            .map_or(0, |record| record.closed_at);
        Utc::now()
            .timestamp_millis()
            .max(recent.max(session).saturating_add(1))
    }

    pub(super) fn remember_closed_workspace_chat(
        &mut self,
        panel: u64,
        tab: &PanelTab,
        cx: &mut Context<Self>,
    ) {
        let Some(index) = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .and_then(|panel| panel.tabs.iter().position(|candidate| candidate == tab))
        else {
            return;
        };
        self.park_workspace_draft(cx);
        let (chat_id, draft, was_new_tab) = match tab {
            PanelTab::Chat(id) => {
                let mut draft = self.saved_chat_draft(id, cx).unwrap_or_default();
                if let Some(chat) = self.state.read(cx).chat_row(id) {
                    if let Some(config) = &chat.config {
                        draft.input.harness = Some(config.harness.clone());
                        draft.input.model = config.model.clone();
                        draft.input.reasoning = config.reasoning.clone();
                    }
                    draft.input.target = Some(crate::settings::SavedCanvasTarget {
                        space: chat.space_id.clone(),
                        no_project: chat.space_id.is_none(),
                        device: Some(chat.device_id.clone()),
                    });
                }
                (Some(id.clone()), draft, false)
            }
            PanelTab::Draft(id) | PanelTab::New(id) => {
                let input = self
                    .workspace_panels
                    .drafts
                    .get(id)
                    .map(|draft| self.save_canvas_draft(draft))
                    .unwrap_or_default();
                let active = self.panel_layout(cx).is_some_and(|layout| {
                    layout.focused == panel
                        && layout.panel(panel).and_then(|panel| panel.selected()) == Some(tab)
                });
                let appshots = if active {
                    self.saved_chat_draft("", cx)
                        .map(|draft| draft.appshots)
                        .unwrap_or_default()
                } else {
                    Vec::new()
                };
                (
                    None,
                    SavedWindowChatDraft { input, appshots },
                    matches!(tab, PanelTab::New(_)),
                )
            }
            _ => return,
        };
        let record = SavedClosedChat {
            id: uuid::Uuid::new_v4().to_string(),
            chat_id,
            window_id: self.window_id.clone(),
            session_id: self.workspace_layout_key(cx),
            panel_id: panel,
            tab_index: index,
            closed_at: self.next_chat_close_time(cx),
            draft,
            was_new_tab,
        };
        settings::update(SavePolicy::Immediate, cx, |settings| {
            settings.remember_closed_chat(record)
        });
        self.settings.recently_closed_chats = settings::recently_closed_chats(cx);
        self.settings.hidden_history_entries = settings::hidden_history_entries(cx);
    }

    fn forget_closed_chat_record(&mut self, key: &str, cx: &mut Context<Self>) {
        settings::update(SavePolicy::Immediate, cx, |settings| {
            if let Some(record) = settings
                .recently_closed_chats
                .iter()
                .find(|record| record.id == key || record.chat_id.as_deref() == Some(key))
            {
                let hidden = record.chat_id.as_ref().map_or_else(
                    || format!("draft:{}", record.id),
                    |chat| format!("chat:{chat}"),
                );
                settings.unhide_history_entry(&hidden);
            }
            settings.forget_closed_chat(key)
        });
        self.settings.recently_closed_chats = settings::recently_closed_chats(cx);
        self.settings.hidden_history_entries = settings::hidden_history_entries(cx);
    }

    pub(in crate::shell) fn hide_history_entry(
        &mut self,
        key: &str,
        cx: &mut Context<Self>,
    ) -> bool {
        let exists = if let Some(chat) = key.strip_prefix("chat:") {
            self.state.read(cx).chat_row(chat).is_some()
        } else if let Some(id) = key.strip_prefix("draft:") {
            settings::recently_closed_chats(cx)
                .iter()
                .any(|record| record.id == id && record.chat_id.is_none())
        } else {
            false
        };
        if !exists {
            return false;
        }
        settings::update(SavePolicy::Immediate, cx, |settings| {
            settings.hide_history_entry(key);
        });
        self.settings.hidden_history_entries = settings::hidden_history_entries(cx);
        cx.refresh_windows();
        true
    }

    pub(in crate::shell) fn discard_closed_chat_record(
        &mut self,
        expected: &SavedClosedChat,
        cx: &mut Context<Self>,
    ) -> bool {
        let mut discarded = false;
        settings::update(SavePolicy::Immediate, cx, |settings| {
            discarded = settings.discard_closed_chat(expected);
        });
        self.settings.recently_closed_chats = settings::recently_closed_chats(cx);
        self.settings.hidden_history_entries = settings::hidden_history_entries(cx);
        if discarded {
            cx.refresh_windows();
        }
        discarded
    }

    /// Permanent history deletion follows the existing deleteChat engine path.
    /// Keep local drafts and recovery intact until the engine accepts it.
    pub(in crate::shell) fn delete_history_chat(
        &mut self,
        chat_id: String,
        cx: &mut Context<Self>,
    ) -> gpui::Task<Result<(), String>> {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return gpui::Task::ready(Err("Engine not connected. Reconnect and try again.".into()));
        };
        let data_dir = self.data_dir.clone();
        cx.spawn(async move |_this, cx| {
            engine.client().call(methods::MUTATE,
                serde_json::json!({ "op": "deleteChat", "chatId": chat_id }),
            ).await.map_err(|error| error.to_string())?;
            // The confirmed deletion is authoritative; sync absence alone is not.
            cx.update(|cx| {
                for handle in cx.windows().into_iter().filter_map(|window| window.downcast::<Shell>()) {
                    let _ = handle.update(cx, |shell, _, cx| {
                        if shell.data_dir == data_dir { shell.finish_history_chat_deletion(&chat_id, cx); }
                    });
                }
            });
            Ok(())
        })
    }

    pub(in crate::shell) fn finish_history_chat_deletion(
        &mut self,
        chat_id: &str,
        cx: &mut Context<Self>,
    ) {
        let browsers: Vec<_> = self.right_tabs.get(chat_id).into_iter().flatten().filter_map(|surface| {
            if let RightSurface::Browser(id) = surface { Some(*id) } else { None }
        }).collect();
        for id in browsers { self.release_browser_surface(id, cx); }
        let deleted = PanelTab::Chat(chat_id.to_owned());
        for layout in self.workspace_panels.layouts.values_mut() {
            for panel in &mut layout.panels { *panel = panel.without_tab(&deleted); }
            layout.imported.remove(&deleted);
            if layout.last_selected.as_ref().and_then(|id| id.as_deref()) == Some(chat_id) {
                layout.last_selected = Some(None);
            }
        }
        let clear_tab = |tab: &mut chat_tabs::ChatTab| {
            if tab.selected.as_deref() == Some(chat_id) { tab.selected = None; }
            if let Some(split) = &mut tab.split {
                for id in split.panes.iter_mut().chain(&mut split.vanished) {
                    if id.as_deref() == Some(chat_id) { *id = None; }
                }
            }
        };
        for tab in &mut self.chat_tabs { clear_tab(tab); }
        for closed in &mut self.closed_chat_tabs { clear_tab(&mut closed.tab); closed.archived.retain(|id| id != chat_id); }
        if let Some(split) = &mut self.chat_split {
            for id in split.panes.iter_mut().chain(&mut split.vanished) {
                if id.as_deref() == Some(chat_id) { *id = None; }
            }
        }
        self.composer.update(cx, |composer, cx| {
            composer.remove_window_draft(chat_id, cx);
            composer.purge_chat(chat_id, cx);
        });
        if self.state.read(cx).selected_chat.as_deref() == Some(chat_id) {
            // Another chat in the same panel takes over, as when closing a tab.
            let next = self.panel_layout(cx).and_then(|layout| {
                match layout.panel(layout.focused)?.selected()? {
                    PanelTab::Chat(id) => Some(id.clone()),
                    _ => None,
                }
            });
            if next.is_some() {
                self.panel_layout_mut(cx).last_selected = Some(next.clone());
            }
            self.state.update(cx, |state, cx| state.select_chat(next, cx));
            self.chat_split_on_state_changed(cx);
        }
        self.workspace_panels.needs_persist = true;
        self.persist_chat_tabs(cx);
        settings::update(SavePolicy::Immediate, cx, |settings| {
            settings.recently_closed_chats.retain(|record| record.chat_id.as_deref() != Some(chat_id));
            settings.hidden_history_entries.retain(|key| key != &format!("chat:{chat_id}"));
        });
        self.settings.recently_closed_chats = settings::recently_closed_chats(cx);
        self.settings.hidden_history_entries = settings::hidden_history_entries(cx);
        cx.refresh_windows();
    }

    /// A newer live draft wins focus, but the older closed input remains
    /// recoverable as its own unsent tab. Consuming the chat record lets the
    /// next Cmd-Shift-T progress instead of repeatedly focusing the same chat.
    fn consume_open_chat_recovery(
        &mut self,
        chat: &str,
        record: Option<&SavedClosedChat>,
        live: &SavedWindowChatDraft,
        cx: &mut Context<Self>,
    ) -> bool {
        let earlier_draft = record
            .filter(|record| {
                let saved = &record.draft;
                let nonempty = !saved.input.text.is_empty()
                    || !saved.input.attachments.is_empty()
                    || !saved.appshots.is_empty();
                nonempty
                    && (saved.input.text != live.input.text
                        || saved.input.attachments != live.input.attachments
                        || saved.appshots != live.appshots)
            })
            .map(|record| SavedClosedChat {
                id: uuid::Uuid::new_v4().to_string(),
                chat_id: None,
                was_new_tab: false,
                ..record.clone()
            });
        let retained = earlier_draft.is_some();
        settings::update(SavePolicy::Immediate, cx, |settings| {
            settings.forget_closed_chat(chat);
            settings.unhide_history_entry(&format!("chat:{chat}"));
            if let Some(draft) = earlier_draft {
                settings.remember_closed_chat(draft);
            }
        });
        self.settings.recently_closed_chats = settings::recently_closed_chats(cx);
        self.settings.hidden_history_entries = settings::hidden_history_entries(cx);
        if retained {
            self.sidebar_notice = Some(
                "Opened the existing chat. Its earlier draft is available in Chat history.".into(),
            );
            cx.notify();
        }
        retained
    }

    pub(in crate::shell) fn open_chat_placement(&self, chat: &str) -> Option<(String, u64)> {
        let tab = PanelTab::Chat(chat.to_owned());
        self.chat_tabs.iter().find_map(|session| {
            let key = if session.id.is_empty() {
                session.project.clone().unwrap_or_default()
            } else {
                session.id.clone()
            };
            self.workspace_panels
                .layouts
                .get(&key)
                .and_then(|layout| layout.location(&tab))
                .map(|(panel, _)| (session.id.clone(), panel))
        })
    }

    fn reveal_recovery_chat(
        &mut self,
        chat: &str,
        session: &str,
        panel: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.show_open_chat(chat, session, panel, window, cx);
        self.unarchive_recovered_chat(chat, cx);
        self.persist_chat_tabs(cx);
    }

    fn show_open_chat(
        &mut self,
        chat: &str,
        session: &str,
        panel: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if !matches!(self.route, Route::Chat) {
            self.close_settings(cx);
        }
        self.activate_workspace_session(session, cx);
        self.panel_layout_mut(cx).expanded = None;
        self.focus_workspace_tab(panel, PanelTab::Chat(chat.into()), window, cx);
        self.persist_chat_tabs(cx);
        window.activate_window();
    }

    /// A chat already open in another window, and not this one, is shown there
    /// instead of opening a second copy. True when it was.
    pub(crate) fn reveal_chat_in_other_window(
        &mut self,
        chat: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.open_chat_placement(chat).is_some() {
            return false;
        }
        let current = window.window_handle().window_id();
        let other = cx.windows().into_iter().find_map(|candidate| {
            if candidate.window_id() == current {
                return None;
            }
            let handle = candidate.downcast::<Shell>()?;
            let (session, panel) = handle.read(cx).ok()?.open_chat_placement(chat)?;
            Some((handle, session, panel))
        });
        let Some((handle, session, panel)) = other else {
            return false;
        };
        handle
            .update(cx, |shell, window, cx| {
                shell.show_open_chat(chat, &session, panel, window, cx);
            })
            .is_ok()
    }

    fn unarchive_recovered_chat(&mut self, chat: &str, cx: &mut Context<Self>) {
        if self
            .state
            .read(cx)
            .chat_row(chat)
            .is_some_and(|chat| chat.archived)
        {
            self.set_chat_archived(chat.into(), false, cx);
        }
    }

    /// Focus an existing placement rather than creating a duplicate or applying
    /// a stale recovery draft over the user's newer edits in that placement.
    fn reveal_existing_recovery_chat(
        &mut self,
        chat: &str,
        record: Option<&SavedClosedChat>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if let Some((session, panel)) = self.open_chat_placement(chat) {
            let live = self.saved_chat_draft(chat, cx).unwrap_or_default();
            self.reveal_recovery_chat(chat, &session, panel, window, cx);
            self.consume_open_chat_recovery(chat, record, &live, cx);
            return true;
        }
        let current = window.window_handle().window_id();
        let other = cx.windows().into_iter().find_map(|candidate| {
            if candidate.window_id() == current {
                return None;
            }
            let handle = candidate.downcast::<Shell>()?;
            let shell = handle.read(cx).ok()?;
            let (session, panel) = shell.open_chat_placement(chat)?;
            let live = shell.saved_chat_draft(chat, cx).unwrap_or_default();
            Some((handle, session, panel, live))
        });
        let Some((handle, session, panel, live)) = other else {
            return false;
        };
        if handle
            .update(cx, |shell, window, cx| {
                shell.reveal_recovery_chat(chat, &session, panel, window, cx);
            })
            .is_err()
        {
            return false;
        }
        if self.consume_open_chat_recovery(chat, record, &live, cx) {
            let notice = self.sidebar_notice.clone();
            let _ = handle.update(cx, |shell, _, cx| {
                shell.sidebar_notice = notice;
                cx.notify();
            });
        }
        true
    }

    pub(in crate::shell) fn reopen_recently_closed_chat(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        for record in settings::recently_closed_chats(cx) {
            if self.restore_closed_chat(&record.id, window, cx) {
                return true;
            }
        }
        false
    }

    /// Cmd-Shift-T restores original placement where it still exists.
    pub(in crate::shell) fn restore_closed_chat(
        &mut self,
        key: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        self.restore_closed_chat_at(key, None, window, cx)
    }

    /// History opens a recovered chat in the requested current panel. An
    /// existing placement elsewhere is focused instead of duplicated.
    pub(in crate::shell) fn restore_closed_chat_in_panel(
        &mut self,
        key: &str,
        panel: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        self.restore_closed_chat_at(key, Some(panel), window, cx)
    }

    fn restore_closed_chat_at(
        &mut self,
        key: &str,
        requested_panel: Option<u64>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let record = settings::recently_closed_chats(cx)
            .into_iter()
            .find(|record| record.id == key || record.chat_id.as_deref() == Some(key));
        let chat = record
            .as_ref()
            .and_then(|record| record.chat_id.as_deref())
            .unwrap_or(key);
        if self.reveal_existing_recovery_chat(chat, record.as_ref(), window, cx) {
            return true;
        }
        let Some(record) = record else { return false };
        // A temporarily unavailable device/chat can become available later.
        // Leave its recovery record intact rather than treating it as deleted.
        if record
            .chat_id
            .as_deref()
            .is_some_and(|chat| self.state.read(cx).chat_row(chat).is_none())
        {
            return false;
        }
        if requested_panel.is_none() && record.window_id != self.window_id {
            let current = window.window_handle().window_id();
            let destination = cx.windows().into_iter().find_map(|candidate| {
                if candidate.window_id() == current {
                    return None;
                }
                let handle = candidate.downcast::<Shell>()?;
                let shell = handle.read(cx).ok()?;
                (shell.window_id == record.window_id
                    && shell
                        .chat_tabs
                        .iter()
                        .any(|session| session.id == record.session_id))
                .then_some(handle)
            });
            if let Some(handle) = destination {
                return handle
                    .update(cx, |shell, window, cx| {
                        shell.restore_closed_chat_at(&record.id, None, window, cx)
                    })
                    .unwrap_or(false);
            }
        }
        // Unsent tabs share the composer's canvas capture slot. Parking their
        // text does not park captures, so avoid replacing a newer staged set.
        if record.chat_id.is_none()
            && self.saved_chat_draft("", cx).is_some_and(|current| {
                !current.appshots.is_empty() && current.appshots != record.draft.appshots
            })
        {
            self.sidebar_notice =
                Some("Finish or remove the staged captures before reopening this draft.".into());
            cx.notify();
            return false;
        }
        if !matches!(self.route, Route::Chat) {
            self.close_settings(cx);
        }
        self.ensure_workspace_sessions(cx);
        self.park_workspace_draft(cx);
        let original_session = requested_panel.is_none()
            && self
                .chat_tabs
                .iter()
                .any(|session| session.id == record.session_id);
        if original_session {
            self.activate_workspace_session(&record.session_id, cx);
        }
        self.sync_panel_workspace(cx);
        self.park_workspace_draft(cx);
        let layout = self.panel_layout_mut(cx);
        let preferred = requested_panel.or(original_session.then_some(record.panel_id));
        let panel = preferred
            .filter(|id| layout.panel(*id).is_some())
            .unwrap_or(layout.focused);
        let same_panel = original_session && panel == record.panel_id;
        let tab = if let Some(chat) = &record.chat_id {
            PanelTab::Chat(chat.clone())
        } else {
            self.workspace_panels.seq += 1;
            let id = self.workspace_panels.seq;
            let draft = self.restored_canvas_draft(&record.draft.input);
            self.workspace_panels.drafts.insert(id, draft);
            if record.was_new_tab {
                PanelTab::New(id)
            } else {
                PanelTab::Draft(id)
            }
        };
        let layout = self.panel_layout_mut(cx);
        let target = layout
            .panel_mut(panel)
            .expect("recovery uses an existing panel");
        target.tabs.retain(|tab| *tab != PanelTab::Empty);
        let at = if same_panel {
            record.tab_index.min(target.tabs.len())
        } else {
            target.tabs.len()
        };
        target.tabs.insert(at, tab.clone());
        target.active = at;
        layout.focused = panel;
        layout.expanded = None;
        // Parking happened before insertion: do not park the displaced input
        // into the newly inserted draft by using focus_workspace_tab here.
        self.activate_workspace_tab(panel, tab, window, cx);
        let draft_key = record.chat_id.clone().unwrap_or_default();
        self.restore_window_chat_drafts(&HashMap::from([(draft_key, record.draft.clone())]), cx);
        if let Some(chat) = &record.chat_id {
            self.unarchive_recovered_chat(chat, cx);
        }
        self.forget_closed_chat_record(&record.id, cx);
        self.persist_chat_tabs(cx);
        settings::flush(cx);
        window.activate_window();
        cx.notify();
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pickers::CanvasInput;

    fn prepare(shell: &mut Shell, cx: &mut Context<Shell>) {
        shell.boot_restored = true;
        shell.ensure_workspace_sessions(cx);
        shell.sync_panel_workspace(cx);
        shell.persist_chat_tabs(cx);
    }

    #[gpui::test]
    fn closed_chat_draft_discard_preserves_live_input_and_hidden_recovery_still_reopens(
        cx: &mut gpui::TestAppContext,
    ) {
        let (dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                let record = SavedClosedChat {
                    id: "closed-draft".into(),
                    draft: SavedWindowChatDraft {
                        input: crate::settings::SavedCanvasDraft {
                            text: "Old unsent draft".into(),
                            ..Default::default()
                        },
                        ..Default::default()
                    },
                    ..Default::default()
                };
                settings::update(SavePolicy::Immediate, cx, |settings| {
                    settings.remember_closed_chat(record.clone());
                });
                let shot = crate::appshots::tests::shot();
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(
                        "current".into(),
                        CanvasInput {
                            text: "Keep my live reply".into(),
                            ..Default::default()
                        },
                        vec![shot.clone()],
                        cx,
                    );
                });
                assert!(shell.hide_history_entry("draft:closed-draft", cx));
                assert!(shell.hide_history_entry("draft:closed-draft", cx));
                assert_eq!(
                    settings::hidden_history_entries(cx),
                    vec!["draft:closed-draft"]
                );
                assert!(!shell.hide_history_entry("draft:missing-draft", cx));
                assert!(shell.discard_closed_chat_record(&record, cx));
                assert!(!shell.discard_closed_chat_record(&record, cx));
                let (input, captures) = shell.composer.read(cx).saved_window_draft("current", cx);
                assert_eq!(input.text, "Keep my live reply");
                assert_eq!(captures[0].id, shot.id);
                assert!(settings::recently_closed_chats(cx).is_empty());
                assert!(settings::hidden_history_entries(cx).is_empty());
                assert!(
                    settings::UiSettings::load(dir.path())
                        .recently_closed_chats
                        .is_empty()
                );

                let panel = shell.panel_layout(cx).unwrap().focused;
                shell.close_workspace_tab(panel, PanelTab::Chat("current".into()), window, cx);
                assert!(shell.hide_history_entry("chat:current", cx));
                assert!(shell.hide_history_entry("chat:current", cx));
                assert!(!shell.hide_history_entry("chat:missing-chat", cx));
                assert!(shell.reopen_recently_closed_chat(window, cx));
                assert!(settings::hidden_history_entries(cx).is_empty());
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn closed_chat_permanent_discard_preserves_recovery_until_engine_success(
        cx: &mut gpui::TestAppContext,
    ) {
        use futures::FutureExt;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let (out, mut requests) = tokio::sync::mpsc::channel(128);
        let (replies, inbound) = tokio::sync::mpsc::channel(128);
        let engine =
            crate::state::EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
        let (dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, _, cx| {
                prepare(shell, cx);
                shell
                    .state
                    .update(cx, |state, _| state.set_test_engine(engine));
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(
                        "current".into(),
                        CanvasInput {
                            text: "Keep until deletion succeeds".into(),
                            ..Default::default()
                        },
                        vec![crate::appshots::tests::shot()],
                        cx,
                    );
                });
                settings::update(SavePolicy::Immediate, cx, |settings| {
                    settings.remember_closed_chat(SavedClosedChat {
                        id: "closed-current".into(),
                        chat_id: Some("current".into()),
                        ..Default::default()
                    });
                    settings.remember_closed_chat(SavedClosedChat {
                        id: "keep-unsent".into(),
                        ..Default::default()
                    });
                    settings.hide_history_entry("chat:current");
                    settings.hide_history_entry("draft:keep-unsent");
                });
            })
            .unwrap();
        let (workspace_id, project, workspace_count) = window.update(cx, |shell, _, cx| {
            (shell.chat_tabs[shell.chat_tab].id.clone(), shell.active_project(cx), shell.chat_tabs.len())
        }).unwrap();
        for succeeds in [false, true] {
            let task = window
                .update(cx, |shell, _, cx| {
                    shell.delete_history_chat("current".into(), cx)
                })
                .unwrap();
            cx.run_until_parked();
            let request = loop {
                let request: serde_json::Value =
                    serde_json::from_str(&requests.try_recv().unwrap()).unwrap();
                if request["method"] == methods::MUTATE {
                    break request;
                }
            };
            assert_eq!(
                request["params"],
                serde_json::json!({"op":"deleteChat", "chatId":"current"})
            );
            window
                .update(cx, |shell, _, cx| {
                    assert_eq!(settings::recently_closed_chats(cx).len(), 2);
                    assert_eq!(
                        shell.state.read(cx).selected_chat.as_deref(),
                        Some("current")
                    );
                    let (input, captures) =
                        shell.composer.read(cx).saved_window_draft("current", cx);
                    assert_eq!(input.text, "Keep until deletion succeeds");
                    assert_eq!(captures.len(), 1);
                })
                .unwrap();
            runtime.block_on(async {
                let reply = if succeeds {
                    serde_json::json!({"id": request["id"], "ok": {"ok":true}})
                } else {
                    serde_json::json!({"id": request["id"], "err": "deletion rejected"})
                };
                replies.send(reply.to_string()).await.unwrap();
                tokio::time::timeout(std::time::Duration::from_secs(1), async {
                    while replies.capacity() < replies.max_capacity() {
                        tokio::task::yield_now().await;
                    }
                })
                .await
                .unwrap();
            });
            cx.run_until_parked();
            let outcome = task
                .now_or_never()
                .expect("deletion completed after its response");
            assert_eq!(outcome.is_ok(), succeeds);
            window
                .update(cx, |shell, _, cx| {
                    assert_eq!(shell.chat_tabs.len(), workspace_count);
                    assert_eq!(shell.chat_tabs[shell.chat_tab].id, workspace_id);
                    assert_eq!(shell.active_project(cx), project);
                    if succeeds {
                        assert!(shell.state.read(cx).selected_chat.is_none());
                        assert!(shell.workspace_panels.layouts.values().all(|layout| layout.panels.iter().all(|panel| !panel.tabs.contains(&PanelTab::Chat("current".into())))));
                        assert_eq!(settings::recently_closed_chats(cx).len(), 1);
                        assert_eq!(settings::recently_closed_chats(cx)[0].id, "keep-unsent");
                        assert_eq!(
                            settings::hidden_history_entries(cx),
                            vec!["draft:keep-unsent"]
                        );
                        let (input, captures) =
                            shell.composer.read(cx).saved_window_draft("current", cx);
                        assert!(input.text.is_empty());
                        assert!(captures.is_empty());
                    } else {
                        assert_eq!(settings::recently_closed_chats(cx).len(), 2);
                        assert_eq!(settings::hidden_history_entries(cx).len(), 2);
                        let (input, captures) =
                            shell.composer.read(cx).saved_window_draft("current", cx);
                        assert_eq!(input.text, "Keep until deletion succeeds");
                        assert_eq!(captures.len(), 1);
                    }
                    assert_eq!(
                        settings::UiSettings::load(dir.path()).recently_closed_chats,
                        settings::recently_closed_chats(cx)
                    );
                })
                .unwrap();
        }
    }

    #[gpui::test]
    fn closed_chat_recovers_same_conversation_and_cached_draft_after_settings_reload(
        cx: &mut gpui::TestAppContext,
    ) {
        let (dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                let session = shell.workspace_layout_key(cx);
                let panel = shell.panel_layout(cx).unwrap().focused;
                let attachment = crate::attachments::StagedAttachment {
                    #[cfg(target_os = "macos")]
                    editable: None,
                    #[cfg(target_os = "macos")]
                    unavailable_editable: None,
                    unavailable: None,
                    annotations: None,
                    id: uuid::Uuid::new_v4().to_string(),
                    name: "notes.txt".into(),
                    image: None,
                    file: Some(std::sync::Arc::from(&b"retained attachment"[..])),
                };
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(
                        "current".into(),
                        CanvasInput {
                            text: "My unsent reply".into(),
                            stage: vec![attachment],
                        },
                        vec![],
                        cx,
                    );
                });
                shell.close_workspace_tab(panel, PanelTab::Chat("current".into()), window, cx);
                assert!(
                    shell
                        .panel_layout(cx)
                        .unwrap()
                        .location(&PanelTab::Chat("current".into()))
                        .is_none()
                );
                assert!(shell.state.read(cx).selected_chat.is_none());
                assert!(!shell.state.read(cx).chat_row("current").unwrap().archived);
                assert_eq!(
                    settings::recently_closed_chats(cx)[0].draft.input.text,
                    "My unsent reply"
                );
                // Drop the in-memory composer copy and reload the durable record.
                shell.composer.update(cx, |composer, cx| {
                    composer.remove_window_draft("current", cx)
                });
                let saved = settings::UiSettings::load(dir.path());
                settings::init(saved, dir.path(), cx);
                assert!(shell.reopen_recently_closed_chat(window, cx));
                assert_eq!(shell.workspace_layout_key(cx), session);
                assert_eq!(
                    shell
                        .panel_layout(cx)
                        .unwrap()
                        .location(&PanelTab::Chat("current".into())),
                    Some((panel, 0))
                );
                let draft = shell.composer.read(cx).parked_chat_input("current", cx);
                assert_eq!(draft.text, "My unsent reply");
                assert_eq!(draft.stage[0].bytes(), b"retained attachment");
                assert!(settings::recently_closed_chats(cx).is_empty());
            })
            .unwrap();
    }

    #[gpui::test]
    fn closed_chat_reopen_focuses_existing_placement_without_overwriting_newer_draft(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                let panel = shell.panel_layout(cx).unwrap().focused;
                shell.close_workspace_tab(panel, PanelTab::Chat("current".into()), window, cx);
                let record = settings::recently_closed_chats(cx)[0].clone();
                assert!(shell.reopen_recently_closed_chat(window, cx));
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(
                        "current".into(),
                        CanvasInput {
                            text: "Newer draft".into(),
                            ..Default::default()
                        },
                        vec![],
                        cx,
                    );
                });
                settings::update(SavePolicy::Immediate, cx, |settings| {
                    settings.remember_closed_chat(record)
                });
                assert!(shell.restore_closed_chat_in_panel("current", panel, window, cx));
                assert_eq!(
                    shell
                        .panel_layout(cx)
                        .unwrap()
                        .panels
                        .iter()
                        .flat_map(|panel| &panel.tabs)
                        .filter(|tab| **tab == PanelTab::Chat("current".into()))
                        .count(),
                    1
                );
                assert_eq!(
                    shell
                        .composer
                        .read(cx)
                        .parked_chat_input("current", cx)
                        .text,
                    "Newer draft"
                );
                assert!(settings::recently_closed_chats(cx).is_empty());
                // History must deduplicate even after the recovery record was consumed.
                assert!(shell.restore_closed_chat_in_panel("current", panel, window, cx));
            })
            .unwrap();
    }

    #[gpui::test]
    fn closed_chat_conflicting_draft_becomes_an_independent_recovery_and_reopen_progresses(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                let panel = shell.panel_layout(cx).unwrap().focused;
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(
                        "current".into(),
                        CanvasInput {
                            text: "Earlier unsent reply".into(),
                            ..Default::default()
                        },
                        vec![],
                        cx,
                    );
                });
                shell.close_workspace_tab(panel, PanelTab::Chat("current".into()), window, cx);
                let earlier = settings::recently_closed_chats(cx)[0].clone();
                assert!(shell.reopen_recently_closed_chat(window, cx));
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(
                        "current".into(),
                        CanvasInput {
                            text: "Newer unsent reply".into(),
                            ..Default::default()
                        },
                        vec![],
                        cx,
                    );
                });
                settings::update(SavePolicy::Immediate, cx, |settings| {
                    settings.remember_closed_chat(earlier)
                });
                assert!(shell.reopen_recently_closed_chat(window, cx));
                assert_eq!(
                    shell
                        .composer
                        .read(cx)
                        .parked_chat_input("current", cx)
                        .text,
                    "Newer unsent reply"
                );
                let retained = settings::recently_closed_chats(cx);
                assert_eq!(retained.len(), 1);
                assert!(retained[0].chat_id.is_none());
                assert_eq!(retained[0].draft.input.text, "Earlier unsent reply");
                assert_eq!(
                    retained[0]
                        .draft
                        .input
                        .target
                        .as_ref()
                        .unwrap()
                        .space
                        .as_deref(),
                    Some("a")
                );
                assert!(shell.reopen_recently_closed_chat(window, cx));
                assert_eq!(
                    shell.current_canvas_draft(cx).input.unwrap().text,
                    "Earlier unsent reply"
                );
                assert_eq!(
                    shell
                        .composer
                        .read(cx)
                        .parked_chat_input("current", cx)
                        .text,
                    "Newer unsent reply"
                );
                assert!(settings::recently_closed_chats(cx).is_empty());
            })
            .unwrap();
    }

    #[gpui::test]
    fn closed_chat_unsent_recovery_preserves_the_displaced_draft_and_uses_a_safe_panel(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                shell.workspace_new_tab(cx);
                shell.composer.update(cx, |composer, cx| {
                    composer.set_canvas_input(
                        CanvasInput {
                            text: "Closed unsent question".into(),
                            ..Default::default()
                        },
                        cx,
                    )
                });
                let panel = shell.panel_layout(cx).unwrap().focused;
                let tab = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panel(panel)
                    .unwrap()
                    .selected()
                    .unwrap()
                    .clone();
                shell.close_workspace_tab(panel, tab, window, cx);
                let record = settings::recently_closed_chats(cx)[0].clone();
                assert!(record.chat_id.is_none());
                assert_eq!(record.draft.input.text, "Closed unsent question");
                shell.workspace_new_tab(cx);
                shell.composer.update(cx, |composer, cx| {
                    composer.set_canvas_input(
                        CanvasInput {
                            text: "Keep the newer question too".into(),
                            ..Default::default()
                        },
                        cx,
                    )
                });
                let newer = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panel(panel)
                    .unwrap()
                    .selected()
                    .unwrap()
                    .clone();
                assert!(shell.restore_closed_chat_in_panel(&record.id, u64::MAX, window, cx));
                let PanelTab::New(newer_id) = newer else {
                    panic!("new tab")
                };
                assert_eq!(
                    shell.workspace_panels.drafts[&newer_id]
                        .input
                        .as_ref()
                        .unwrap()
                        .text,
                    "Keep the newer question too"
                );
                assert!(
                    shell
                        .panel_layout(cx)
                        .unwrap()
                        .location(&PanelTab::New(newer_id))
                        .is_some()
                );
                assert_eq!(
                    shell.current_canvas_draft(cx).input.unwrap().text,
                    "Closed unsent question"
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn closed_chat_unsent_recovery_keeps_conflicting_staged_captures_until_retry(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                shell.workspace_new_tab(cx);
                shell.composer.update(cx, |composer, cx| {
                    composer.set_canvas_input(
                        CanvasInput {
                            text: "Recover this older question".into(),
                            ..Default::default()
                        },
                        cx,
                    )
                });
                let panel = shell.panel_layout(cx).unwrap().focused;
                let tab = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panel(panel)
                    .unwrap()
                    .selected()
                    .unwrap()
                    .clone();
                shell.close_workspace_tab(panel, tab, window, cx);
                let record = settings::recently_closed_chats(cx)[0].clone();
                assert!(record.draft.appshots.is_empty());
                shell.workspace_new_tab(cx);
                let newer = CanvasInput {
                    text: "Keep this question and its capture".into(),
                    ..Default::default()
                };
                let shot = crate::appshots::tests::shot();
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(
                        String::new(),
                        newer.clone(),
                        vec![shot.clone()],
                        cx,
                    )
                });
                let before_tabs = shell
                    .panel_layout(cx)
                    .unwrap()
                    .panel(panel)
                    .unwrap()
                    .tabs
                    .clone();
                let before_session = shell.workspace_layout_key(cx);
                assert!(!shell.restore_closed_chat_in_panel(&record.id, panel, window, cx));
                assert_eq!(shell.workspace_layout_key(cx), before_session);
                assert_eq!(
                    shell.panel_layout(cx).unwrap().panel(panel).unwrap().tabs,
                    before_tabs
                );
                assert_eq!(settings::recently_closed_chats(cx), vec![record.clone()]);
                let (input, captures) = shell.composer.read(cx).saved_window_draft("", cx);
                assert_eq!(input.text, newer.text);
                assert_eq!(captures.len(), 1);
                assert_eq!(captures[0].id, shot.id);
                assert_eq!(captures[0].screenshot.bytes(), shot.screenshot.bytes());
                assert_eq!(
                    shell.sidebar_notice.as_deref(),
                    Some("Finish or remove the staged captures before reopening this draft.")
                );

                // Removing the staged capture permits a later retry; the older
                // record was not consumed by the blocked attempt.
                shell.composer.update(cx, |composer, cx| {
                    composer.restore_saved_window_draft(String::new(), newer, vec![], cx)
                });
                assert!(shell.restore_closed_chat_in_panel(&record.id, panel, window, cx));
                assert_eq!(
                    shell.current_canvas_draft(cx).input.unwrap().text,
                    "Recover this older question"
                );
                assert!(settings::recently_closed_chats(cx).is_empty());
            })
            .unwrap();
    }

    #[gpui::test]
    fn closed_chat_does_not_return_from_a_legacy_split_after_layout_reload(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, true, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                let session = shell.workspace_layout_key(cx);
                let peer = PanelTab::Chat("peer".into());
                let (panel, _) = shell.panel_layout(cx).unwrap().location(&peer).unwrap();
                shell.close_workspace_tab(panel, peer.clone(), window, cx);
                let saved = shell.saved_workspace_panels(&session, cx).unwrap();
                assert!(
                    !shell
                        .chat_split
                        .as_ref()
                        .unwrap()
                        .panes
                        .iter()
                        .any(|chat| chat.as_deref() == Some("peer"))
                );
                shell.workspace_panels.layouts.clear();
                shell.restore_workspace_panels(&session, &saved, cx);
                shell.sync_panel_workspace(cx);
                assert!(
                    shell.panel_layout(cx).unwrap().location(&peer).is_none(),
                    "legacy split descriptors must not re-import the closed conversation"
                );
                assert!(shell.restore_closed_chat("peer", window, cx));
                assert!(shell.panel_layout(cx).unwrap().location(&peer).is_some());
            })
            .unwrap();
    }

    #[gpui::test]
    fn closed_chat_and_workspace_reopen_follow_close_order(cx: &mut gpui::TestAppContext) {
        let (_dir, window) = crate::shell::chat_tabs::navigation_tests::fixture(cx, false, None);
        cx.run_until_parked();
        window
            .update(cx, |shell, window, cx| {
                prepare(shell, cx);
                let session = shell.workspace_layout_key(cx);
                let panel = shell.panel_layout(cx).unwrap().focused;
                shell.close_workspace_tab(panel, PanelTab::Chat("current".into()), window, cx);
                shell.close_workspace_session(&session, cx);
                assert!(shell.reopen_closed_chat_tab(window, cx));
                assert_eq!(shell.workspace_layout_key(cx), session);
                assert_eq!(
                    settings::recently_closed_chats(cx).len(),
                    1,
                    "the newer whole-session close reopens before its older closed chat"
                );
                assert!(shell.reopen_closed_chat_tab(window, cx));
                assert_eq!(
                    shell.state.read(cx).selected_chat.as_deref(),
                    Some("current")
                );
                assert!(settings::recently_closed_chats(cx).is_empty());
            })
            .unwrap();
    }
}
