//! A provisional insertion into an existing window. Navigation and composer
//! adoption happen only after the destination can draw the staged live entity.
use super::*;

struct ExistingWindowSnapshot {
    layouts: HashMap<String, WorkspaceLayout>,
    drafts: HashMap<u64, crate::pickers::CanvasDraft>,
    inactive_composers: HashMap<PanelTab, Entity<crate::composer::InactiveComposer>>,
    composer_layouts: HashMap<PanelTab, crate::composer::InactiveComposerLayout>,
    right_tabs: HashMap<String, Vec<RightSurface>>,
    panels: HashMap<String, ChatPanels>,
    sequences: (u64, u64, u64, u64, u64),
    needs_persist: bool,
    preparing: bool,
    focus: Option<FocusHandle>,
    staged: Option<PanelTab>,
    previous_peer: Option<(String, Entity<Transcript>, Subscription)>,
    placeholders: Vec<PanelTab>,
}

impl Shell {
    pub(crate) fn move_workspace_tab_to_window(
        &mut self,
        source_panel: u64,
        tab: PanelTab,
        destination: gpui::WindowHandle<Shell>,
        destination_panel: u64,
        insert: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<PanelTab, String> {
        if destination.window_id() == window.window_handle().window_id() {
            return Err("Use this window's normal tab targets to move this tab.".into());
        }
        if self.pending_exit.is_some() || self.window_transfer_preparing {
            return Err("Finish the pending close or move before moving this tab.".into());
        }
        if !self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(source_panel))
            .is_some_and(|panel| panel.tabs.contains(&tab))
        {
            return Err("This tab has moved. Try dragging it again.".into());
        }
        let runtime = AppState::runtime_owner(&self.state, cx).entity_id();
        destination
            .update(cx, |target, _, cx| {
                target.validate_window_rejoin(destination_panel, &tab, runtime, cx)
            })
            .map_err(|_| "The destination window is no longer open.".to_string())??;
        let tab = self.normalize_window_terminal(source_panel, tab, cx)?;
        let transfer = self.prepare_window_tab(source_panel, &tab, cx)?;
        let source_focus = window.focused(cx);
        let mut snapshot = destination
            .update(cx, |target, target_window, cx| {
                target.snapshot_window_rejoin(target_window, cx)
            })
            .map_err(|error| error.to_string())?;
        let staged = destination
            .update(cx, |target, target_window, cx| {
                target.stage_window_rejoin(
                    &transfer,
                    destination_panel,
                    insert,
                    &mut snapshot,
                    target_window,
                    cx,
                )
            })
            .map_err(|error| error.to_string())
            .and_then(|result| result);
        let validated = staged.and_then(|adopted| {
            gpui::AnyWindowHandle::from(destination)
                .update(cx, |_, target_window, cx| {
                    target_window.draw(cx).clear();
                    #[cfg(test)]
                    if cx.try_global::<WindowTransferFailure>()
                        == Some(&WindowTransferFailure::FirstPaint)
                    {
                        return Err("The destination window could not draw this tab.".to_string());
                    }
                    Ok(adopted)
                })
                .map_err(|error| error.to_string())
                .and_then(|result| result)
        });
        match validated {
            Ok(adopted) => {
                destination
                    .update(cx, |target, target_window, cx| {
                        target.commit_window_rejoin(
                            &transfer,
                            destination_panel,
                            &adopted,
                            &snapshot,
                            target_window,
                            cx,
                        );
                    })
                    .map_err(|error| error.to_string())?;
                self.finish_window_tab_transfer(source_panel, &tab, window, cx);
                destination
                    .update(cx, |target, target_window, cx| {
                        target.window_transfer_preparing = snapshot.preparing;
                        target.save_window_record(cx);
                        target_window.activate_window();
                        target_window.refresh();
                    })
                    .map_err(|error| error.to_string())?;
                Ok(adopted)
            }
            Err(error) => {
                if let Err(rollback) = self.restore_window_tab_resource(&transfer, window, cx) {
                    // A native page that cannot be reparented back must keep
                    // one usable placement in its existing destination host.
                    let adopted = destination.update(cx, |target, target_window, cx| {
                        let adopted = match &snapshot.staged {
                            Some(tab) => tab.clone(),
                            None => target.stage_window_rejoin_after_native(&transfer, destination_panel, insert, &mut snapshot, target_window, cx),
                        };
                        target.commit_window_rejoin(&transfer, destination_panel, &adopted, &snapshot, target_window, cx);
                        target.sidebar_notice = Some(format!("The tab was kept safely in this window because it could not return to its original window: {rollback}").into());
                        adopted
                    }).map_err(|error| error.to_string())?;
                    self.finish_window_tab_transfer(source_panel, &tab, window, cx);
                    destination
                        .update(cx, |target, _, cx| {
                            target.window_transfer_preparing = snapshot.preparing;
                            target.save_window_record(cx);
                        })
                        .map_err(|error| error.to_string())?;
                    return Ok(adopted);
                }
                let _ = destination.update(cx, |target, target_window, cx| {
                    target.rollback_window_rejoin(snapshot, target_window, cx);
                });
                if let Some(focus) = source_focus {
                    window.focus(&focus, cx);
                }
                window.activate_window();
                window.refresh();
                Err(error)
            }
        }
    }

    fn validate_window_rejoin(
        &self,
        panel: u64,
        tab: &PanelTab,
        runtime: gpui::EntityId,
        cx: &Context<Self>,
    ) -> Result<(), String> {
        if self.pending_exit.is_some() || self.window_transfer_preparing {
            return Err("Finish the pending close or move in the destination window first.".into());
        }
        if self.route != Route::Chat
            || self.session_overview
            || !self.boot_restored
            || self.chat_tabs.is_empty()
            || !self.panel_layout(cx).is_some_and(|layout| {
                layout.panel(panel).is_some() && layout.expanded.is_none_or(|id| id == panel)
            })
        {
            return Err("The destination panel is no longer available.".into());
        }
        if AppState::runtime_owner(&self.state, cx).entity_id() != runtime {
            return Err("These windows are connected to different workspaces.".into());
        }
        if let PanelTab::Chat(_) = tab
            && self
                .workspace_panels
                .layouts
                .values()
                .any(|layout| layout.panels.iter().any(|panel| panel.tabs.contains(tab)))
        {
            return Err("This window already contains that conversation.".into());
        }
        let composer = self.composer.read(cx);
        composer.window_draft(&composer.current_key, cx)?;
        if matches!(tab, PanelTab::Draft(_) | PanelTab::New(_))
            && !composer.saved_window_draft("", cx).1.is_empty()
        {
            return Err("Finish the staged app captures in the destination canvas before moving another draft into this window.".into());
        }
        Ok(())
    }

    fn snapshot_window_rejoin(
        &mut self,
        window: &Window,
        cx: &Context<Self>,
    ) -> ExistingWindowSnapshot {
        let snapshot = ExistingWindowSnapshot {
            layouts: self.workspace_panels.layouts.clone(),
            drafts: self.workspace_panels.drafts.clone(),
            inactive_composers: self.workspace_panels.inactive_composers.clone(),
            composer_layouts: self.workspace_panels.composer_layouts.clone(),
            right_tabs: self.right_tabs.clone(),
            panels: self.panels.map.clone(),
            sequences: (
                self.workspace_panels.seq,
                self.browser_seq,
                self.file_surface_seq,
                self.diff_seq,
                self.subagent_seq,
            ),
            needs_persist: self.workspace_panels.needs_persist,
            preparing: self.window_transfer_preparing,
            focus: window.focused(cx),
            staged: None,
            previous_peer: None,
            placeholders: Vec::new(),
        };
        self.park_workspace_draft(cx);
        snapshot
    }

    fn stage_window_rejoin(
        &mut self,
        transfer: &WindowTabTransfer,
        panel: u64,
        insert: Option<usize>,
        snapshot: &mut ExistingWindowSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<PanelTab, String> {
        self.window_transfer_preparing = true;
        if let TabResource::Browser(browser) = &transfer.resource {
            browser.update(cx, |browser, cx| browser.move_to_window(window, cx))?;
        }
        #[cfg(test)]
        if cx.try_global::<WindowTransferFailure>() == Some(&WindowTransferFailure::NativeAdoption)
        {
            return Err("Could not attach this tab to the destination window.".into());
        }
        Ok(self.stage_window_rejoin_after_native(transfer, panel, insert, snapshot, window, cx))
    }

    fn stage_window_rejoin_after_native(
        &mut self,
        transfer: &WindowTabTransfer,
        panel: u64,
        insert: Option<usize>,
        snapshot: &mut ExistingWindowSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> PanelTab {
        let owner = transfer.owner.clone();
        let tab = match &transfer.resource {
            TabResource::Empty => match transfer.tab {
                PanelTab::Draft(_) | PanelTab::New(_) => {
                    self.workspace_panels.seq += 1;
                    let id = self.workspace_panels.seq;
                    if let Some(draft) = &transfer.draft {
                        self.workspace_panels.drafts.insert(id, draft.clone());
                    }
                    if matches!(transfer.tab, PanelTab::New(_)) {
                        PanelTab::New(id)
                    } else {
                        PanelTab::Draft(id)
                    }
                }
                _ => PanelTab::Empty,
            },
            TabResource::Chat(transcript) => {
                let chat = transfer
                    .context_chat
                    .as_ref()
                    .expect("chat transfer context")
                    .clone();
                if let Some((old, events)) = self.workspace_panels.peers.remove(&chat) {
                    snapshot.previous_peer = Some((chat.clone(), old, events));
                }
                let events = cx.subscribe(transcript, Self::on_transcript_event);
                self.workspace_panels
                    .peers
                    .insert(chat, (transcript.clone(), events));
                transfer.tab.clone()
            }
            TabResource::Browser(browser) => {
                self.browser_seq += 1;
                let id = self.browser_seq;
                let events = self.subscribe_window_browser(id, owner.clone(), browser, window, cx);
                self.browsers.insert(id, browser.clone());
                self.browser_subs.insert(id, events);
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Browser(id),
                }
            }
            TabResource::File(file, path) => {
                self.file_surface_seq += 1;
                let id = self.file_surface_seq;
                let events = self.subscribe_window_file(id, owner.clone(), file, window, cx);
                self.file_surfaces.insert(id, file.clone());
                self.file_surface_paths.insert(id, path.clone());
                self.file_surface_keys
                    .entry((
                        owner.clone(),
                        file.read(cx).session_owner().to_owned(),
                        path.clone(),
                    ))
                    .or_insert(id);
                self.file_surface_subs.insert(id, events);
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::File(id),
                }
            }
            TabResource::Explorer(files) => {
                self.workspace_panels.seq += 1;
                let id = self.workspace_panels.seq;
                let events = self.subscribe_window_explorer(id, owner.clone(), files, window, cx);
                self.workspace_panels
                    .explorers
                    .insert(id, (files.clone(), events, owner.clone()));
                PanelTab::FileTree(id)
            }
            TabResource::Terminal(terminal, key) => {
                self.workspace_panels.seq += 1;
                let id = self.workspace_panels.seq;
                self.workspace_panels.terminals.insert(id, terminal.clone());
                if let Some(key) = key {
                    self.workspace_panels.terminal_keys.insert(id, *key);
                }
                PanelTab::Terminal(id)
            }
            TabResource::Diff(changes) => {
                self.diff_seq += 1;
                let id = self.diff_seq;
                let events = self.subscribe_rejoined_window_diff(changes, owner.clone(), cx);
                self.diffs.insert(id, changes.clone());
                self.diff_subs.insert(id, events);
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Diff(id),
                }
            }
            TabResource::Subagent {
                chat,
                doc,
                title,
                harness,
                transcript,
            } => {
                self.subagent_seq += 1;
                let id = self.subagent_seq;
                let events = cx.subscribe(transcript, Self::on_transcript_event);
                self.subagent_tabs.insert(
                    id,
                    SubagentTab {
                        chat_id: chat.clone(),
                        doc_id: doc.clone(),
                        title: title.clone(),
                        harness: *harness,
                        transcript: transcript.clone(),
                        _fetch: None,
                        _events: events,
                    },
                );
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Subagent(id),
                }
            }
        };
        if let PanelTab::Surface { surface, .. } = &tab {
            self.right_tabs.entry(owner).or_default().push(*surface);
        }
        let placeholders = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .map(|panel| {
                panel
                    .tabs
                    .iter()
                    .filter(|tab| {
                        matches!(tab, PanelTab::Empty)
                            || (panel.tabs.len() == 1 && self.window_rejoin_blank_tab(tab, cx))
                    })
                    .cloned()
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let layout = self.panel_layout_mut(cx);
        let target = layout.panel_mut(panel).expect("validated rejoin panel");
        target.tabs.retain(|tab| !placeholders.contains(tab));
        let index = insert.unwrap_or(target.tabs.len()).min(target.tabs.len());
        target.tabs.insert(index, tab.clone());
        target.active = index;
        layout.focused = panel;
        layout.imported.insert(tab.clone());
        snapshot.placeholders = placeholders;
        snapshot.staged = Some(tab.clone());
        tab
    }

    fn subscribe_rejoined_window_diff(
        &self,
        changes: &Entity<Changes>,
        owner: String,
        cx: &mut Context<Self>,
    ) -> Subscription {
        cx.subscribe(changes, move |this, source, event, cx| match event {
            crate::changes::ChangesEvent::OpenCommit(commit) => {
                // A moved history tab can belong to a different checkout
                // from the destination window's selected conversation.
                let state = source.read(cx).window_state();
                let changes = cx.new(|cx| Changes::for_commit(state, commit.clone(), cx));
                this.diff_seq += 1;
                let id = this.diff_seq;
                let events = this.subscribe_rejoined_window_diff(&changes, owner.clone(), cx);
                this.diffs.insert(id, changes);
                this.diff_subs.insert(id, events);
                let surface = RightSurface::Diff(id);
                this.right_tabs
                    .entry(owner.clone())
                    .or_default()
                    .push(surface);
                let previous_owner = this.workspace_panels.resource_owner.replace(owner.clone());
                this.set_right_active(surface, cx);
                this.workspace_panels.resource_owner = previous_owner;
                cx.notify();
            }
            crate::changes::ChangesEvent::DoneReview(handle) => {
                let id = this.diffs.iter().find_map(|(id, changes)| {
                    (changes.entity_id() == source.entity_id()).then_some(*id)
                });
                if let Some(id) = id {
                    let shell = cx.entity();
                    let handle = *handle;
                    cx.defer(move |cx| {
                        let _ = cx.update_window(handle, |_, window, cx| {
                            shell.update(cx, |shell, cx| {
                                shell.finish_changes_review(id, window, cx)
                            });
                        });
                    });
                }
            }
            crate::changes::ChangesEvent::DiscardWorkingTree(request) => {
                if this.discard_working_tree_task.is_none() {
                    this.discard_working_tree =
                        Some(DiscardWorkingTreeFlow::Confirm(request.clone()));
                    cx.notify();
                }
            }
        })
    }

    fn window_rejoin_blank_tab(&self, tab: &PanelTab, cx: &App) -> bool {
        match tab {
            PanelTab::Empty => true,
            PanelTab::Draft(id) | PanelTab::New(id) => {
                let empty_input = self
                    .workspace_panels
                    .drafts
                    .get(id)
                    .and_then(|draft| draft.input.as_ref())
                    .is_none_or(|input| input.text.is_empty() && input.stage.is_empty());
                empty_input
                    && self
                        .composer
                        .read(cx)
                        .saved_window_draft("", cx)
                        .1
                        .is_empty()
            }
            _ => false,
        }
    }

    fn commit_window_rejoin(
        &mut self,
        transfer: &WindowTabTransfer,
        panel: u64,
        tab: &PanelTab,
        snapshot: &ExistingWindowSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match &transfer.resource {
            TabResource::Chat(transcript) => {
                let chat = transfer
                    .context_chat
                    .as_ref()
                    .expect("chat context")
                    .clone();
                self.select_workspace_chat(Some(chat.clone()), cx);
                // The selected chat can already be the tool tab's context
                // without having a chat placement in this window.
                if self.transcript.entity_id() != transcript.entity_id() {
                    self.workspace_panels.peers.remove(&chat);
                    self.transcript = transcript.clone();
                    self._transcript_events = cx.subscribe(transcript, Self::on_transcript_event);
                }
                self.state.update(cx, |state, cx| {
                    state.adopt_window_chat(&transfer.source_state, chat, cx)
                });
                let links = Self::session_links(None, cx);
                let views = Self::view_opener(cx);
                let labels = Self::model_labeler(&self.composer, cx);
                transcript.update(cx, |transcript, cx| {
                    transcript.rebind_window_state(self.state.clone(), cx);
                    transcript.set_split_source(None, cx);
                    transcript.set_workspace_link_handler(links);
                    transcript.set_view_opener(views);
                    transcript.set_model_labeler(labels);
                });
            }
            TabResource::File(files, _) | TabResource::Explorer(files) => {
                files.update(cx, |files, cx| {
                    files.rebind_window_state(self.state.clone(), cx)
                });
            }
            TabResource::Terminal(terminal, _) => {
                terminal.update(cx, |terminal, cx| {
                    terminal.rebind_window_state(self.state.clone(), cx)
                });
            }
            TabResource::Diff(changes) => {
                let state = cx.new(|cx| AppState::for_window(&transfer.source_state, cx));
                if let Some(chat) = &transfer.context_chat {
                    state.update(cx, |state, cx| {
                        state.adopt_window_chat(&transfer.source_state, chat.clone(), cx)
                    });
                }
                changes.update(cx, |changes, cx| changes.rebind_window_state(state, cx));
            }
            TabResource::Subagent {
                chat,
                doc,
                transcript,
                ..
            } => {
                self.state.update(cx, |state, cx| {
                    state.adopt_window_doc(&transfer.source_state, doc.clone(), cx)
                });
                let links = Self::session_links(Some(chat.clone()), cx);
                let views = Self::view_opener(cx);
                let labels = Self::model_labeler(&self.composer, cx);
                transcript.update(cx, |transcript, cx| {
                    transcript.rebind_window_state(self.state.clone(), cx);
                    transcript.set_workspace_link_handler(links);
                    transcript.set_view_opener(views);
                    transcript.set_model_labeler(labels);
                });
            }
            TabResource::Browser(_) | TabResource::Empty => {}
        }
        for placeholder in &snapshot.placeholders {
            if let PanelTab::Draft(id) | PanelTab::New(id) = placeholder {
                self.workspace_panels.drafts.remove(id);
            }
            self.workspace_panels.inactive_composers.remove(placeholder);
            self.workspace_panels.composer_layouts.remove(placeholder);
        }
        if let Some(layout) = transfer.composer_layout {
            self.workspace_panels
                .composer_layouts
                .insert(tab.clone(), layout);
        }
        self.activate_workspace_tab(panel, tab.clone(), window, cx);
        if let Some(input) = &transfer.input {
            let key = if let PanelTab::Chat(chat) = tab {
                chat.clone()
            } else {
                String::new()
            };
            self.composer.update(cx, |composer, cx| {
                composer.adopt_window_draft(key, input.clone(), cx)
            });
        }
        self.workspace_panels.needs_persist = true;
        cx.notify();
    }

    fn rollback_window_rejoin(
        &mut self,
        snapshot: ExistingWindowSnapshot,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(tab) = &snapshot.staged {
            match tab {
                PanelTab::Surface { surface, .. } => match surface {
                    RightSurface::Browser(id) => {
                        self.browsers.remove(id);
                        self.browser_subs.remove(id);
                    }
                    RightSurface::File(id) => {
                        self.file_surfaces.remove(id);
                        self.file_surface_paths.remove(id);
                        self.file_surface_subs.remove(id);
                        self.file_surface_keys.retain(|_, value| value != id);
                    }
                    RightSurface::Diff(id) => {
                        self.diffs.remove(id);
                        self.diff_subs.remove(id);
                    }
                    RightSurface::Subagent(id) => {
                        self.subagent_tabs.remove(id);
                    }
                    _ => {}
                },
                PanelTab::Chat(chat) => {
                    self.workspace_panels.peers.remove(chat);
                }
                PanelTab::Terminal(id) => {
                    self.workspace_panels.terminals.remove(id);
                    self.workspace_panels.terminal_keys.remove(id);
                }
                PanelTab::FileTree(id) => {
                    self.workspace_panels.explorers.remove(id);
                }
                _ => {}
            }
        }
        if let Some((chat, transcript, events)) = snapshot.previous_peer {
            self.workspace_panels
                .peers
                .insert(chat, (transcript, events));
        }
        self.workspace_panels.layouts = snapshot.layouts;
        self.workspace_panels.drafts = snapshot.drafts;
        self.workspace_panels.inactive_composers = snapshot.inactive_composers;
        self.workspace_panels.composer_layouts = snapshot.composer_layouts;
        self.workspace_panels.needs_persist = snapshot.needs_persist;
        self.right_tabs = snapshot.right_tabs;
        self.panels.map = snapshot.panels;
        (
            self.workspace_panels.seq,
            self.browser_seq,
            self.file_surface_seq,
            self.diff_seq,
            self.subagent_seq,
        ) = snapshot.sequences;
        self.window_transfer_preparing = snapshot.preparing;
        if let Some(focus) = snapshot.focus {
            window.focus(&focus, cx);
        }
        window.refresh();
        cx.notify();
    }
}
