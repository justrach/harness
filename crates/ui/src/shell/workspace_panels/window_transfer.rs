//! A live tab handoff. Preparation borrows resource handles; source placement
//! is removed only after the destination has installed the same resource.
use super::*;
use crate::settings::SavedWorkspaceWindow;

#[path = "window_rejoin.rs"]
mod rejoin;

#[cfg(test)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum WindowTransferFailure {
    Creation,
    NativeAdoption,
    FirstPaint,
}
#[cfg(test)]
impl gpui::Global for WindowTransferFailure {}

#[derive(Clone)]
enum TabResource {
    Empty,
    Chat(Entity<Transcript>),
    Browser(Entity<crate::browser::BrowserSurface>),
    File(Entity<FilesSurface>, String),
    Explorer(Entity<FilesSurface>),
    Terminal(Entity<TerminalPanel>, Option<u64>),
    Diff(Entity<Changes>),
    Subagent {
        chat: String,
        doc: String,
        title: SharedString,
        harness: Option<harness_proto::HarnessId>,
        transcript: Entity<Transcript>,
    },
}

#[derive(Clone)]
struct WindowTabTransfer {
    tab: PanelTab,
    session: chat_tabs::ChatTab,
    source_state: Entity<AppState>,
    context_chat: Option<String>,
    owner: String,
    resource: TabResource,
    draft: Option<crate::pickers::CanvasDraft>,
    input: Option<crate::composer::WindowComposerDraft>,
    composer_layout: Option<crate::composer::InactiveComposerLayout>,
}

impl Shell {
    /// A tear-off always starts as one panel in a normal, independently sized
    /// window. Do not inherit the source's fullscreen controls or extra lane.
    pub(super) fn new_window_tab_origin(
        &self,
        session: &chat_tabs::ChatTab,
        context_chat: Option<&str>,
        viewport_width: f32,
        cx: &App,
    ) -> Point<Pixels> {
        let preferences = settings::current(cx);
        let panel_left = if preferences.sidebar_collapsed {
            GUTTER
        } else {
            preferences.sidebar_width
        };
        let buttons_end = cluster_buttons_start(
            cfg!(target_os = "macos"),
            false,
            self.linux_left_caption_count(),
        ) + CLUSTER_BUTTONS_WIDTH
            + if preferences.sidebar_collapsed {
                CHAT_HISTORY_HEADER_WIDTH
            } else {
                0.0
            };
        let session_width = if preferences.sidebar_collapsed {
            let mut destination_session = session.clone();
            destination_session.selected = context_chat.map(str::to_owned);
            let title = self.workspace_session_title(&destination_session, cx);
            Self::workspace_session_quick_width_for(
                &title,
                viewport_width,
                buttons_end,
                self.titlebar_right_pad(0.0),
                true,
                cx,
            )
        } else {
            0.0
        };
        point(
            px(panel_left.max(buttons_end + session_width + TITLEBAR_CLUSTER_PAD + 4.0)),
            px((PANEL_HEADER_HEIGHT - PANEL_TAB_HEIGHT - STACKED_CLEARANCE).max(0.0)),
        )
    }

    fn prepare_window_tab(
        &mut self,
        panel: u64,
        tab: &PanelTab,
        cx: &mut Context<Self>,
    ) -> Result<WindowTabTransfer, String> {
        self.park_workspace_draft(cx);
        if !self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .is_some_and(|panel| panel.tabs.contains(tab))
        {
            return Err("This tab has moved. Try dragging it again.".into());
        }
        if self.pending_exit.is_some() {
            return Err("Finish the pending close before moving this tab.".into());
        }
        let session = self.park_chat_tab(cx);
        let owner = match tab {
            PanelTab::Surface { owner, .. }
            | PanelTab::Files(owner)
            | PanelTab::TerminalDock(owner) => owner.clone(),
            _ => self.panel_key(cx),
        };
        let mut context_chat = self
            .state
            .read(cx)
            .chats
            .iter()
            .find(|chat| chat.id == owner)
            .map(|chat| chat.id.clone())
            .or_else(|| self.state.read(cx).selected_chat.clone());
        let mut draft = None;
        let mut input = None;
        let mut source_state = self.state.clone();
        let missing = || "This tab is still opening. Try moving it again shortly.".to_string();
        let resource = match tab {
            PanelTab::Chat(chat) => {
                context_chat = Some(chat.clone());
                input = Some(self.composer.read(cx).window_draft(chat, cx)?);
                let transcript = if self.state.read(cx).selected_chat.as_ref() == Some(chat) {
                    self.transcript.clone()
                } else if let Some((transcript, _)) = self.workspace_panels.peers.get(chat) {
                    transcript.clone()
                } else {
                    cx.new(|cx| Transcript::for_peer_chat(self.state.clone(), chat.clone(), cx))
                };
                TabResource::Chat(transcript)
            }
            PanelTab::Draft(id) | PanelTab::New(id) => {
                draft = self.workspace_panels.drafts.get(id).cloned();
                if let Some(context) = self.moving_new_tab_device(panel, tab, cx) {
                    draft.get_or_insert_with(Default::default).target =
                        Some(context.canvas_target(self.state.read(cx)));
                }
                let focused = self.panel_layout(cx).is_some_and(|layout| {
                    layout.focused == panel
                        && layout.panel(panel).and_then(|panel| panel.selected()) == Some(tab)
                });
                if focused {
                    input = Some(self.composer.read(cx).window_draft("", cx)?);
                }
                context_chat = None;
                TabResource::Empty
            }
            PanelTab::FileTree(id) => {
                let files = self
                    .workspace_panels
                    .explorers
                    .get(id)
                    .ok_or_else(missing)?;
                TabResource::Explorer(files.0.clone())
            }
            PanelTab::Files(owner) => {
                TabResource::Explorer(self.files.get(owner).cloned().ok_or_else(missing)?)
            }
            PanelTab::Terminal(id) => TabResource::Terminal(
                self.workspace_panels
                    .terminals
                    .get(id)
                    .cloned()
                    .ok_or_else(missing)?,
                self.workspace_panels.terminal_keys.get(id).copied(),
            ),
            PanelTab::TerminalDock(_) => {
                return Err("This terminal is using a shared drawer. Open an independent terminal tab before moving it to a window.".into());
            }
            PanelTab::Surface { surface, .. } => match surface {
                RightSurface::Browser(id) => {
                    TabResource::Browser(self.browsers.get(id).cloned().ok_or_else(missing)?)
                }
                RightSurface::File(id) => {
                    if self.pending_file_closes.contains(surface) {
                        return Err("Finish the pending file close before moving this tab.".into());
                    }
                    TabResource::File(
                        self.file_surfaces.get(id).cloned().ok_or_else(missing)?,
                        self.file_surface_paths
                            .get(id)
                            .cloned()
                            .ok_or_else(missing)?,
                    )
                }
                RightSurface::Diff(id) => {
                    let changes = self.diffs.get(id).cloned().ok_or_else(missing)?;
                    source_state = changes.read(cx).window_state();
                    // A manual review remains bound to its originating chat,
                    // even after another panel changes the window selection.
                    context_chat = changes.read(cx).context_chat_id(cx);
                    TabResource::Diff(changes)
                }
                RightSurface::Subagent(id) => {
                    let tab = self.subagent_tabs.get(id).ok_or_else(missing)?;
                    if tab._fetch.is_some()
                        && self
                            .state
                            .read(cx)
                            .transcript_baseline(&tab.doc_id)
                            .is_none()
                    {
                        return Err(
                            "This transcript is still loading. Try moving it again shortly.".into(),
                        );
                    }
                    TabResource::Subagent {
                        chat: tab.chat_id.clone(),
                        doc: tab.doc_id.clone(),
                        title: tab.title.clone(),
                        harness: tab.harness,
                        transcript: tab.transcript.clone(),
                    }
                }
                RightSurface::Terminal(_) => {
                    return Err("This terminal is using a shared host. Open an independent terminal tab before moving it to a window.".into());
                }
                RightSurface::ToolAccess(_) => {
                    return Err("Close Tool access before moving this tab to a window.".into());
                }
                RightSurface::Picker => TabResource::Empty,
            },
            PanelTab::Empty => TabResource::Empty,
        };
        Ok(WindowTabTransfer {
            tab: tab.clone(),
            session,
            source_state,
            context_chat,
            owner,
            resource,
            draft,
            input,
            composer_layout: self.workspace_panels.composer_layouts.get(tab).copied(),
        })
    }

    pub(crate) fn move_workspace_tab_to_new_window(
        &mut self,
        panel: u64,
        tab: PanelTab,
        pointer: Option<(Point<Pixels>, Point<Pixels>)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<gpui::WindowHandle<Shell>, String> {
        if self.pending_exit.is_some() {
            return Err("Finish the pending close before moving this tab.".into());
        }
        if !self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .is_some_and(|panel| panel.tabs.contains(&tab))
        {
            return Err("This tab has moved. Try dragging it again.".into());
        }
        let tab = self.normalize_window_terminal(panel, tab, cx)?;
        let transfer = self.prepare_window_tab(panel, &tab, cx)?;
        #[cfg(test)]
        if cx.try_global::<WindowTransferFailure>() == Some(&WindowTransferFailure::Creation) {
            return Err("Could not create the new window.".into());
        }
        let state = cx.new(|cx| AppState::for_window(&self.state, cx));
        let mut record = SavedWorkspaceWindow {
            id: uuid::Uuid::new_v4().to_string(),
            geometry: pointer.and_then(|(pointer, grab)| {
                let fitted = crate::workspace_window_geometry_at(
                    pointer,
                    point(px(0.0), px(0.0)),
                    window,
                    cx,
                )?;
                let anchor = self.new_window_tab_origin(
                    &transfer.session,
                    transfer.context_chat.as_deref(),
                    fitted.width,
                    cx,
                ) + grab;
                crate::workspace_window_geometry_at(pointer, anchor, window, cx)
            }),
            last_space_id: transfer.session.project.clone(),
            space_filter: self.settings.space_filter.clone(),
            project_tabs_version: 2,
            ..Default::default()
        };
        if record.geometry.is_none() {
            let mut geometry = crate::settings::WindowGeometry::from_bounds(window.bounds());
            geometry.x += 32.0;
            geometry.y += 32.0;
            geometry.display_uuid = window.display(cx).and_then(|display| display.uuid().ok());
            record.geometry = Some(geometry);
        }
        let source_focus = window.focused(cx);
        let destination = crate::open_workspace_window(state, self.boot.clone(), record, cx)?;
        let adopted = destination.update(cx, |destination, window, cx| {
            destination.adopt_window_tab(&transfer, window, cx)
        });
        let installed = matches!(&adopted, Ok(Ok(_)));
        let validated = adopted
            .map_err(|error| error.to_string())
            .and_then(|result| result)
            .and_then(|_| {
                // Draw without leasing the destination Shell: its renderer
                // must be free to borrow the root and shared live resource.
                gpui::AnyWindowHandle::from(destination)
                    .update(cx, |_, window, cx| {
                        window.draw(cx).clear();
                        #[cfg(test)]
                        if cx.try_global::<WindowTransferFailure>()
                            == Some(&WindowTransferFailure::FirstPaint)
                        {
                            return Err("The new window could not draw this tab.".to_string());
                        }
                        Ok(())
                    })
                    .map_err(|error| error.to_string())
                    .and_then(|result| result)
            });
        match validated {
            Ok(()) => {
                self.finish_window_tab_transfer(panel, &tab, window, cx);
                destination
                    .update(cx, |destination, window, cx| {
                        destination.window_transfer_preparing = false;
                        destination.save_window_record(cx);
                        window.activate_window();
                        window.refresh();
                    })
                    .map_err(|error| error.to_string())?;
                Ok(destination)
            }
            Err(error) => {
                if let Err(rollback) = self.restore_window_tab_resource(&transfer, window, cx) {
                    // The native page remains in the prepared destination.
                    // Commit that single placement rather than close its host
                    // or leave the live resource listed in both windows.
                    if !installed {
                        destination
                            .update(cx, |destination, window, cx| {
                                destination.install_window_tab(&transfer, window, cx)
                            })
                            .map_err(|error| error.to_string())??;
                    }
                    self.finish_window_tab_transfer(panel, &tab, window, cx);
                    destination.update(cx, |destination, window, cx| {
                        destination.window_transfer_preparing = false;
                        destination.sidebar_notice = Some(format!(
                            "The tab was kept safely in this window because it could not return to the original window: {rollback}"
                        ).into());
                        destination.save_window_record(cx);
                        window.activate_window();
                        window.refresh();
                    }).map_err(|error| error.to_string())?;
                    return Ok(destination);
                }
                let _ = destination.update(cx, |_, window, _| window.remove_window());
                if let Some(focus) = source_focus {
                    window.focus(&focus, cx);
                }
                window.activate_window();
                window.refresh();
                Err(error)
            }
        }
    }

    /// Source maps and event subscriptions are retained until commit. Restore
    /// the window-local resource bindings after a provisional destination draw
    /// fails, then closing that destination drops its temporary subscriptions.
    fn restore_window_tab_resource(
        &mut self,
        transfer: &WindowTabTransfer,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        match &transfer.resource {
            TabResource::Browser(browser) => {
                browser.update(cx, |browser, cx| browser.move_to_window(window, cx))?;
            }
            TabResource::Chat(transcript) => {
                let links = Self::session_links(None, cx);
                let views = Self::view_opener(cx);
                let labels = Self::model_labeler(&self.composer, cx);
                let peer = if let PanelTab::Chat(chat) = &transfer.tab {
                    (self.state.read(cx).selected_chat.as_ref() != Some(chat)).then(|| chat.clone())
                } else {
                    None
                };
                transcript.update(cx, |transcript, cx| {
                    transcript.rebind_window_state(self.state.clone(), cx);
                    transcript.set_split_source(peer, cx);
                    transcript.set_workspace_link_handler(links);
                    transcript.set_view_opener(views);
                    transcript.set_model_labeler(labels);
                });
            }
            TabResource::Subagent {
                chat, transcript, ..
            } => {
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
                changes.update(cx, |changes, cx| {
                    changes.rebind_window_state(transfer.source_state.clone(), cx)
                });
            }
            TabResource::Empty => {}
        }
        Ok(())
    }

    fn normalize_window_terminal(
        &mut self,
        panel: u64,
        tab: PanelTab,
        cx: &mut Context<Self>,
    ) -> Result<PanelTab, String> {
        let index = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .and_then(|panel| panel.tabs.iter().position(|candidate| candidate == &tab))
            .ok_or_else(|| "This tab has moved. Try dragging it again.".to_string())?;
        let legacy = match &tab {
            PanelTab::TerminalDock(owner) => self
                .terminal
                .clone()
                .map(|host| (host, owner.clone(), None)),
            PanelTab::Surface {
                owner,
                surface: RightSurface::Terminal(key),
            } => self
                .right_terminal
                .clone()
                .map(|host| (host, owner.clone(), Some(*key))),
            _ => return Ok(tab),
        }
        .ok_or_else(|| {
            "This terminal is still opening. Try moving it again shortly.".to_string()
        })?;
        let (host, key) = legacy.0.update(cx, |host, cx| {
            host.take_window_tabs(&legacy.1, legacy.2, cx)
        })?;
        self.workspace_panels.seq += 1;
        let id = self.workspace_panels.seq;
        self.workspace_panels.terminals.insert(id, host);
        self.workspace_panels.terminal_keys.insert(id, key);
        let replacement = PanelTab::Terminal(id);
        let layout = self.panel_layout_mut(cx);
        layout
            .panel_mut(panel)
            .expect("validated terminal source panel")
            .tabs[index] = replacement.clone();
        layout.imported.insert(tab.clone());
        match &tab {
            PanelTab::TerminalDock(owner) => self
                .panels
                .update(owner, |panels| panels.terminal_open = false),
            PanelTab::Surface { owner, surface } => {
                if let Some(tabs) = self.right_tabs.get_mut(owner) {
                    tabs.retain(|candidate| candidate != surface);
                }
            }
            _ => {}
        }
        Ok(replacement)
    }

    fn adopt_window_tab(
        &mut self,
        transfer: &WindowTabTransfer,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<PanelTab, String> {
        self.window_transfer_preparing = true;
        // Do all fallible native preparation before changing either layout.
        if let TabResource::Browser(browser) = &transfer.resource {
            browser.update(cx, |browser, cx| browser.move_to_window(window, cx))?;
        }
        #[cfg(test)]
        if cx.try_global::<WindowTransferFailure>() == Some(&WindowTransferFailure::NativeAdoption)
        {
            return Err("Could not attach this tab to the new window.".into());
        }
        self.install_window_tab(transfer, window, cx)
    }

    fn install_window_tab(
        &mut self,
        transfer: &WindowTabTransfer,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Result<PanelTab, String> {
        self.boot_restored = true;
        self.space_boot_applied = true;
        self.route = Route::Chat;
        self.session_overview = false;
        self.chat_tabs = vec![transfer.session.clone()];
        self.chat_tab = 0;
        self.chat_split = None;
        self.settings.last_space_id = transfer.session.project.clone();
        if let Some(chat) = &transfer.context_chat {
            self.state.update(cx, |state, cx| {
                state.adopt_window_chat(&transfer.source_state, chat.clone(), cx)
            });
        } else {
            self.state
                .update(cx, |state, cx| state.select_chat(None, cx));
        }
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
                self.transcript = transcript.clone();
                self._transcript_events = cx.subscribe(transcript, Self::on_transcript_event);
                transfer.tab.clone()
            }
            TabResource::Browser(browser) => {
                self.browser_seq += 1;
                let id = self.browser_seq;
                let events = self.subscribe_window_browser(id, owner.clone(), browser, window, cx);
                self.browsers.insert(id, browser.clone());
                self.browser_subs.insert(id, events);
                self.right_tabs
                    .entry(owner.clone())
                    .or_default()
                    .push(RightSurface::Browser(id));
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Browser(id),
                }
            }
            TabResource::File(file, path) => {
                file.update(cx, |file, cx| {
                    file.rebind_window_state(self.state.clone(), cx)
                });
                self.file_surface_seq += 1;
                let id = self.file_surface_seq;
                let engine_owner = file.read(cx).session_owner().to_owned();
                let events = self.subscribe_window_file(id, owner.clone(), file, window, cx);
                self.file_surfaces.insert(id, file.clone());
                self.file_surface_paths.insert(id, path.clone());
                self.file_surface_keys
                    .insert((owner.clone(), engine_owner, path.clone()), id);
                self.file_surface_subs.insert(id, events);
                self.right_tabs
                    .entry(owner.clone())
                    .or_default()
                    .push(RightSurface::File(id));
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::File(id),
                }
            }
            TabResource::Explorer(files) => {
                files.update(cx, |files, cx| {
                    files.rebind_window_state(self.state.clone(), cx)
                });
                self.workspace_panels.seq += 1;
                let id = self.workspace_panels.seq;
                let events = self.subscribe_window_explorer(id, owner.clone(), files, window, cx);
                self.workspace_panels
                    .explorers
                    .insert(id, (files.clone(), events, owner.clone()));
                PanelTab::FileTree(id)
            }
            TabResource::Terminal(terminal, key) => {
                terminal.update(cx, |terminal, cx| {
                    terminal.rebind_window_state(self.state.clone(), cx)
                });
                self.workspace_panels.seq += 1;
                let id = self.workspace_panels.seq;
                self.workspace_panels.terminals.insert(id, terminal.clone());
                if let Some(key) = key {
                    self.workspace_panels.terminal_keys.insert(id, *key);
                }
                PanelTab::Terminal(id)
            }
            TabResource::Diff(changes) => {
                changes.update(cx, |changes, cx| {
                    changes.rebind_window_state(self.state.clone(), cx)
                });
                self.workspace_panels.resource_owner = Some(owner.clone());
                self.register_diff_surface(changes.clone(), cx);
                self.workspace_panels.resource_owner = None;
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Diff(self.diff_seq),
                }
            }
            TabResource::Subagent {
                chat,
                doc,
                title,
                harness,
                transcript,
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
                self.right_tabs
                    .entry(owner.clone())
                    .or_default()
                    .push(RightSurface::Subagent(id));
                PanelTab::Surface {
                    owner,
                    surface: RightSurface::Subagent(id),
                }
            }
        };
        let mut layout = WorkspaceLayout::default();
        layout.last_selected = Some(self.state.read(cx).selected_chat.clone());
        layout.panels[0].tabs.push(tab.clone());
        layout.imported.insert(tab.clone());
        self.workspace_panels
            .layouts
            .insert(transfer.session.id.clone(), layout);
        if let Some(draft) = &transfer.draft {
            self.adopt_canvas_draft(Some(draft.clone()), cx);
        }
        if let Some(layout) = transfer.composer_layout {
            self.workspace_panels
                .composer_layouts
                .insert(tab.clone(), layout);
        }
        self.activate_workspace_tab(0, tab.clone(), window, cx);
        if let Some(input) = &transfer.input {
            let key = if let PanelTab::Chat(chat) = &tab {
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
        Ok(tab)
    }

    fn finish_window_tab_transfer(
        &mut self,
        panel: u64,
        tab: &PanelTab,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let moving_active = self.panel_layout(cx).is_some_and(|layout| {
            layout.focused == panel
                && layout.panel(panel).and_then(|panel| panel.selected()) == Some(tab)
        });
        let remaining_active = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .map(|panel| panel.without_tab(tab).active);
        match tab {
            PanelTab::Surface { owner, surface } => {
                match surface {
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
                        if let Some(tab) = self.subagent_tabs.remove(id) {
                            self.state
                                .update(cx, |state, _| state.unwatch_subagent_doc(&tab.doc_id));
                        }
                    }
                    _ => {}
                }
                if let Some(tabs) = self.right_tabs.get_mut(owner) {
                    tabs.retain(|candidate| candidate != surface);
                }
            }
            PanelTab::Draft(id) | PanelTab::New(id) => {
                self.workspace_panels.drafts.remove(id);
            }
            PanelTab::Terminal(id) => {
                self.workspace_panels.terminals.remove(id);
                self.workspace_panels.terminal_keys.remove(id);
            }
            PanelTab::FileTree(id) => {
                self.workspace_panels.explorers.remove(id);
            }
            PanelTab::Files(owner) => {
                self.files.remove(owner);
                self.files_subs.remove(owner);
                self.panels
                    .update(owner, |panels| panels.files_open = false);
            }
            PanelTab::Chat(chat) => {
                self.workspace_panels.peers.remove(chat);
                self.state
                    .update(cx, |state, _| state.unwatch_peer_chat(chat));
            }
            _ => {}
        }
        self.workspace_panels.inactive_composers.remove(tab);
        self.workspace_panels.composer_layouts.remove(tab);
        if let PanelTab::Chat(chat) = tab {
            self.composer
                .update(cx, |composer, cx| composer.remove_window_draft(chat, cx));
            if self.state.read(cx).selected_chat.as_ref() == Some(chat) {
                let transcript = cx.new(|cx| Transcript::new(self.state.clone(), cx));
                let links = Self::session_links(None, cx);
                let views = Self::view_opener(cx);
                let labels = Self::model_labeler(&self.composer, cx);
                transcript.update(cx, |transcript, _| {
                    transcript.set_workspace_link_handler(links);
                    transcript.set_view_opener(views);
                    transcript.set_model_labeler(labels);
                });
                self.transcript = transcript;
                self._transcript_events = cx.subscribe(&self.transcript, Self::on_transcript_event);
            }
        } else if moving_active && matches!(tab, PanelTab::Draft(_) | PanelTab::New(_)) {
            self.composer
                .update(cx, |composer, cx| composer.remove_window_draft("", cx));
        }
        let layout = self.panel_layout_mut(cx);
        layout.remove_tab(panel, tab);
        if let Some(remaining) = remaining_active
            && let Some(source) = layout.panel_mut(panel)
        {
            source.active = remaining.min(source.tabs.len().saturating_sub(1));
        }
        layout.imported.insert(tab.clone());
        if layout.panels.len() > 1
            && layout
                .panel(panel)
                .is_some_and(|panel| panel.tabs.is_empty())
        {
            layout.panels.retain(|candidate| candidate.id != panel);
            if layout.focused == panel {
                layout.focused = layout.panels[0].id;
            }
            layout.expanded = None;
            layout.equalize();
        }
        let focused = layout.focused;
        let next = layout
            .panel(focused)
            .and_then(|panel| panel.selected())
            .cloned();
        if moving_active {
            if let PanelTab::Chat(chat) = tab {
                // The moved transcript is now destination-bound; replace the
                // source's primary view before selecting its surviving tab.
                self.state
                    .update(cx, |state, cx| state.select_chat(None, cx));
                let _ = chat;
            }
            if let Some(next) = next {
                self.activate_workspace_tab(focused, next, window, cx);
                // Tool tabs can legitimately survive without a selected chat.
                // Keep the import bridge from interpreting that intentional
                // selection as a request to manufacture a fresh draft tab.
                let selected = self.state.read(cx).selected_chat.clone();
                self.panel_layout_mut(cx).last_selected = Some(selected);
            } else {
                self.state
                    .update(cx, |state, cx| state.select_chat(None, cx));
                self.panel_layout_mut(cx).last_selected = Some(None);
                self.composer.update(cx, |composer, cx| {
                    composer.set_canvas_input(Default::default(), cx)
                });
            }
        }
        self.persist_chat_tabs(cx);
        cx.notify();
    }

    fn subscribe_window_explorer(
        &mut self,
        id: u64,
        owner: String,
        files: &Entity<FilesSurface>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Subscription {
        cx.subscribe_in(
            files,
            window,
            move |this, source, event, window, cx| match event {
                FilesEvent::OpenFile(path) if source.read(cx).is_current_target(cx) => {
                    if let Some((from, _)) = this
                        .panel_layout(cx)
                        .and_then(|layout| layout.location(&PanelTab::FileTree(id)))
                    {
                        let layout = this.panel_layout_mut(cx);
                        let target = layout
                            .neighbor(from, true)
                            .or_else(|| layout.neighbor(from, false))
                            .unwrap_or_else(|| layout.add_panel(from));
                        this.workspace_panels.target = Some(target);
                        let previous = this.workspace_panels.resource_owner.replace(owner.clone());
                        let previous_engine = this
                            .workspace_panels
                            .resource_engine_owner
                            .replace(source.read(cx).session_owner().to_owned());
                        this.add_file_surface(path.clone(), window, cx);
                        this.workspace_panels.resource_owner = previous;
                        this.workspace_panels.resource_engine_owner = previous_engine;
                        this.workspace_panels.target = None;
                    }
                }
                FilesEvent::AddProject => this.open_files_project(&source, cx),
                FilesEvent::ShowAllFilesChanged(show_all) => this.set_files_show_all(*show_all, cx),
                _ => cx.notify(),
            },
        )
    }
}
