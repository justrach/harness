//! Import a local Codex transcript into the blank tab that requested it.
use super::workspace_panels::PanelTab;
use super::*;

const DEFAULT_CONTINUATION: &str = "Continue unfinished work from this conversation. Check the current workspace before making changes.";

#[derive(Clone, Debug, PartialEq, Eq)]
struct ImportTarget {
    workspace: String,
    panel: u64,
    tab: PanelTab,
}

#[derive(Clone, Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct CodexPreview {
    title: String,
    cwd: Option<String>,
    cwd_available: bool,
    updated_at: i64,
    archived: bool,
    message_count: usize,
    last_message: Option<String>,
    already_imported: bool,
    chat_id: Option<String>,
    #[serde(default)]
    warnings: Vec<String>,
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImportResult {
    chat_id: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Editing,
    Previewing,
    Ready,
    Importing,
    Opening(String),
}

pub(super) struct CodexImportFlow {
    generation: u64,
    request: u64,
    target: ImportTarget,
    reference: Entity<ComposerInput>,
    folder: Entity<ComposerInput>,
    prompt: Entity<ComposerInput>,
    preview: Option<CodexPreview>,
    phase: Phase,
    error: Option<String>,
    imported_chat: Option<String>,
    focus_pending: bool,
    return_focus: Option<FocusHandle>,
    preview_focus: FocusHandle,
    continue_focus: FocusHandle,
    cancel_focus: FocusHandle,
    folder_focus: FocusHandle,
    _inputs: Vec<Subscription>,
}

impl Shell {
    pub(super) fn open_codex_import(
        &mut self,
        panel: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.ensure_workspace_sessions(cx);
        self.sync_panel_workspace(cx);
        let empty_panel = self
            .panel_layout(cx)
            .and_then(|layout| layout.panels.iter().find(|item| item.id == panel))
            .is_some_and(|panel| {
                panel.tabs.is_empty() || matches!(panel.selected(), Some(PanelTab::Empty))
            });
        if empty_panel {
            // The same chooser is offered by an empty split panel. Give it a
            // concrete blank-tab identity before starting asynchronous work.
            self.workspace_new_tab_in_panel(panel, cx);
        }
        let Some(tab @ PanelTab::New(_)) = self
            .panel_layout(cx)
            .and_then(|layout| layout.panels.iter().find(|item| item.id == panel))
            .and_then(|panel| panel.selected())
            .cloned()
        else {
            return;
        };
        self.command_palette = None;
        self.codex_import_task = None;
        self.codex_import_folder_task = None;
        self.codex_import_generation = self.codex_import_generation.wrapping_add(1);
        let reference = cx.new(|cx| {
            ComposerInput::with_context(
                "codex://threads/… or conversation ID",
                crate::composer::CODEX_IMPORT_INPUT_CONTEXT,
                cx,
            )
            .with_single_line()
        });
        let folder = cx.new(|cx| {
            ComposerInput::with_context(
                "Choose an existing working folder",
                crate::composer::CODEX_IMPORT_INPUT_CONTEXT,
                cx,
            )
            .with_single_line()
        });
        let prompt = cx.new(|cx| {
            let mut input = ComposerInput::with_context(
                "What should graff do next?",
                crate::composer::CODEX_IMPORT_INPUT_CONTEXT,
                cx,
            );
            input.set_text(DEFAULT_CONTINUATION, cx);
            input
        });
        let reference_events = cx.subscribe(&reference, |shell, _, event, cx| {
            if matches!(event, ComposerInputEvent::Edited) {
                if let Some(flow) = shell.codex_import.as_mut() {
                    flow.request = flow.request.wrapping_add(1);
                    flow.preview = None;
                    flow.phase = Phase::Editing;
                    flow.error = None;
                    flow.imported_chat = None;
                }
                shell.codex_import_task = None;
                cx.notify();
            }
        });
        let mut inputs = vec![reference_events];
        for input in [&folder, &prompt] {
            inputs.push(cx.subscribe(input, |shell, _, event, cx| {
                if matches!(event, ComposerInputEvent::Edited) {
                    if let Some(flow) = shell.codex_import.as_mut() {
                        flow.error = None;
                    }
                    cx.notify();
                }
            }));
        }
        self.codex_import = Some(CodexImportFlow {
            generation: self.codex_import_generation,
            request: 0,
            target: ImportTarget {
                workspace: self.workspace_layout_key(cx),
                panel,
                tab,
            },
            reference,
            folder,
            prompt,
            preview: None,
            phase: Phase::Editing,
            error: None,
            imported_chat: None,
            focus_pending: true,
            return_focus: window.focused(cx),
            preview_focus: cx.focus_handle().tab_stop(true),
            continue_focus: cx.focus_handle().tab_stop(true),
            cancel_focus: cx.focus_handle().tab_stop(true),
            folder_focus: cx.focus_handle().tab_stop(true),
            _inputs: inputs,
        });
        cx.notify();
    }

    pub(super) fn close_codex_import(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(flow) = self.codex_import.take()
            && let Some(focus) = flow.return_focus
        {
            window.focus(&focus, cx);
        }
        // A completed import remains saved. Dismissal never dispatches a turn.
        self.codex_import_task = None;
        self.codex_import_folder_task = None;
        cx.notify();
    }

    fn codex_import_matches(&self, generation: u64, request: u64) -> bool {
        self.codex_import
            .as_ref()
            .is_some_and(|flow| flow.generation == generation && flow.request == request)
    }

    pub(super) fn cycle_codex_import_focus(
        &self,
        backwards: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(flow) = &self.codex_import else {
            return;
        };
        let busy = matches!(flow.phase, Phase::Importing | Phase::Opening(_));
        let mut controls = Vec::new();
        if !busy {
            controls.push(flow.reference.focus_handle(cx));
            if flow.phase != Phase::Previewing && !flow.reference.read(cx).text().trim().is_empty()
            {
                controls.push(flow.preview_focus.clone());
            }
            if flow.preview.is_some() && flow.imported_chat.is_none() {
                controls.extend([
                    flow.folder_focus.clone(),
                    flow.folder.focus_handle(cx),
                    flow.prompt.focus_handle(cx),
                ]);
            }
        }
        controls.push(flow.cancel_focus.clone());
        if flow.phase == Phase::Ready
            && (flow.imported_chat.is_some()
                || (!flow.folder.read(cx).text().trim().is_empty()
                    && !flow.prompt.read(cx).text().trim().is_empty()))
        {
            controls.push(flow.continue_focus.clone());
        }
        let current = controls.iter().position(|focus| focus.is_focused(window));
        let index = match (current, backwards) {
            (Some(index), true) => (index + controls.len() - 1) % controls.len(),
            (Some(index), false) => (index + 1) % controls.len(),
            (None, true) => controls.len() - 1,
            (None, false) => 0,
        };
        window.focus(&controls[index], cx);
    }

    fn preview_codex_import(&mut self, cx: &mut Context<Self>) {
        let Some(flow) = self.codex_import.as_mut() else {
            return;
        };
        if matches!(
            flow.phase,
            Phase::Previewing | Phase::Importing | Phase::Opening(_)
        ) {
            return;
        }
        let reference = flow.reference.read(cx).text().trim().to_string();
        if reference.is_empty() {
            flow.error = Some("Paste a Codex conversation link or ID.".into());
            cx.notify();
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            flow.error = Some("Connect Harness’s engine, then try again.".into());
            cx.notify();
            return;
        };
        flow.request = flow.request.wrapping_add(1);
        let (generation, request) = (flow.generation, flow.request);
        flow.phase = Phase::Previewing;
        flow.preview = None;
        flow.error = None;
        self.codex_import_task = Some(cx.spawn(async move |this, cx| {
            // No targetDeviceId: Codex history belongs to the local engine.
            let result = engine
                .client()
                .call(
                    methods::CODEX_CONVERSATION_PREVIEW,
                    serde_json::json!({ "reference": reference }),
                )
                .await
                .map_err(|error| error.to_string())
                .and_then(|value| {
                    serde_json::from_value::<CodexPreview>(value).map_err(|error| error.to_string())
                });
            this.update(cx, |shell, cx| {
                if !shell.codex_import_matches(generation, request) {
                    return;
                }
                let flow = shell.codex_import.as_mut().unwrap();
                match result {
                    Ok(preview) => {
                        flow.folder.update(cx, |input, cx| {
                            input.set_text(preview.cwd.clone().unwrap_or_default(), cx)
                        });
                        if preview.already_imported && !preview.cwd_available {
                            flow.imported_chat = preview.chat_id.clone();
                            flow.error = Some("This conversation is already imported, but its working folder is unavailable. Open the conversation and choose its working folder before continuing.".into());
                        }
                        flow.preview = Some(preview);
                        flow.phase = Phase::Ready;
                    }
                    Err(error) => {
                        flow.phase = Phase::Editing;
                        flow.error = Some(error);
                    }
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn codex_import_target_exists(&self, target: &ImportTarget) -> bool {
        self.chat_tabs
            .iter()
            .any(|session| session.id == target.workspace)
            && self
                .workspace_panels
                .layouts
                .get(&target.workspace)
                .is_some_and(|layout| {
                    layout
                        .panels
                        .iter()
                        .any(|panel| panel.id == target.panel && panel.tabs.contains(&target.tab))
                })
    }

    fn choose_codex_import_folder(&mut self, cx: &mut Context<Self>) {
        let Some(flow) = self.codex_import.as_ref() else {
            return;
        };
        let generation = flow.generation;
        let request = flow.request;
        let receiver = cx.prompt_for_paths(gpui::PathPromptOptions {
            files: false,
            directories: true,
            multiple: false,
            prompt: Some("Use this folder".into()),
        });
        self.codex_import_folder_task = Some(cx.spawn(async move |this, cx| {
            let result = receiver.await;
            this.update(cx, |shell, cx| {
                if let Some(flow) = shell
                    .codex_import
                    .as_mut()
                    .filter(|flow| flow.generation == generation && flow.request == request)
                    && let Ok(Ok(Some(paths))) = result
                    && let Some(path) = paths.first()
                {
                    flow.folder
                        .update(cx, |input, cx| input.set_text(path.to_string_lossy(), cx));
                    cx.notify();
                }
            })
            .ok();
        }));
    }

    fn submit_codex_import(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(flow) = self.codex_import.as_ref() else {
            return;
        };
        if flow.phase != Phase::Ready {
            return;
        }
        if let Some(chat_id) = flow.imported_chat.clone() {
            let target = flow.target.clone();
            self.close_codex_import(window, cx);
            if !self.place_codex_imported_chat(&target, &chat_id, window, cx) {
                self.open_chat_in_tab(chat_id, window, cx);
            }
            return;
        }
        let target = flow.target.clone();
        if !self.codex_import_target_exists(&target) {
            self.codex_import.as_mut().unwrap().error = Some("The original tab is no longer available. Close this dialog and start the import from a new tab.".into());
            cx.notify();
            return;
        }
        let folder = flow.folder.read(cx).text().trim().to_string();
        let prompt = flow.prompt.read(cx).text().trim().to_string();
        if folder.is_empty() || prompt.is_empty() {
            self.codex_import.as_mut().unwrap().error = Some(
                if folder.is_empty() {
                    "Choose the working folder where graff should continue."
                } else {
                    "Enter an instruction for graff before continuing."
                }
                .into(),
            );
            cx.notify();
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.codex_import.as_mut().unwrap().error =
                Some("Connect Harness’s engine, then try again.".into());
            cx.notify();
            return;
        };
        let flow = self.codex_import.as_mut().unwrap();
        let reference = flow.reference.read(cx).text().trim().to_string();
        flow.request = flow.request.wrapping_add(1);
        let (generation, request) = (flow.generation, flow.request);
        flow.phase = Phase::Importing;
        flow.error = None;
        self.codex_import_task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(
                methods::CODEX_CONVERSATION_IMPORT,
                serde_json::json!({ "reference": reference, "cwd": folder }),
            ).await.map_err(|error| error.to_string()).and_then(|value| {
                serde_json::from_value::<ImportResult>(value).map_err(|error| error.to_string())
            });
            let opening = this.update(cx, |shell, cx| {
                if !shell.codex_import_matches(generation, request) { return false; }
                let flow = shell.codex_import.as_mut().unwrap();
                match result {
                    Ok(result) => { flow.phase = Phase::Opening(result.chat_id); }
                    Err(error) => { flow.phase = Phase::Ready; flow.error = Some(error); }
                }
                cx.notify();
                matches!(flow.phase, Phase::Opening(_))
            }).unwrap_or(false);
            if opening {
                cx.background_executor().timer(Duration::from_secs(15)).await;
                this.update(cx, |shell, cx| {
                    if shell.codex_import_matches(generation, request) {
                        let flow = shell.codex_import.as_mut().unwrap();
                        if let Phase::Opening(chat_id) = &flow.phase {
                            flow.imported_chat = Some(chat_id.clone());
                            flow.phase = Phase::Ready;
                            flow.error = Some("The conversation was imported, but Harness is still loading it. Open it to continue.".into());
                            cx.notify();
                        }
                    }
                }).ok();
            }
        }));
        cx.notify();
    }

    fn finish_codex_import(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(flow) = self.codex_import.as_ref() else {
            return;
        };
        let Phase::Opening(chat_id) = &flow.phase else {
            return;
        };
        let chat_id = chat_id.clone();
        if !self
            .state
            .read(cx)
            .chats
            .iter()
            .any(|chat| chat.id == chat_id)
        {
            return;
        }
        let target = flow.target.clone();
        let prompt = flow.prompt.read(cx).text().trim().to_string();
        if !self.codex_import_target_exists(&target) {
            let flow = self.codex_import.as_mut().unwrap();
            flow.phase = Phase::Ready;
            flow.imported_chat = Some(chat_id);
            flow.error = Some("The conversation was imported, but the original tab was closed or changed. Open the imported conversation to continue.".into());
            return;
        }
        self.place_codex_imported_chat(&target, &chat_id, window, cx);
        let result = self.composer.update(cx, |composer, cx| {
            composer.continue_imported_conversation(&chat_id, prompt, cx)
        });
        match result {
            Ok(()) => {
                self.codex_import = None;
                self.codex_import_task = None;
                window.focus(&self.composer.focus_handle(cx), cx);
            }
            Err(error) => {
                let flow = self.codex_import.as_mut().unwrap();
                flow.phase = Phase::Ready;
                flow.imported_chat = Some(chat_id);
                flow.error = Some(error);
            }
        }
        cx.notify();
    }

    /// Replace exactly the initiating blank tab, even after another tab was
    /// selected. An existing copy moves here rather than leaving two copies.
    fn place_codex_imported_chat(
        &mut self,
        target: &ImportTarget,
        chat_id: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.codex_import_target_exists(target) {
            return false;
        }
        self.activate_workspace_session(&target.workspace, cx);
        self.park_workspace_draft(cx);
        let chat = PanelTab::Chat(chat_id.into());
        let layout = self.panel_layout_mut(cx);
        for panel in &mut layout.panels {
            let selected = panel.selected().cloned();
            panel.tabs.retain(|tab| *tab != chat);
            panel.active = selected
                .and_then(|selected| panel.tabs.iter().position(|tab| *tab == selected))
                .unwrap_or_else(|| panel.active.min(panel.tabs.len().saturating_sub(1)));
        }
        let Some(panel) = layout
            .panels
            .iter_mut()
            .find(|panel| panel.id == target.panel)
        else {
            return false;
        };
        let Some(index) = panel.tabs.iter().position(|tab| *tab == target.tab) else {
            return false;
        };
        panel.tabs[index] = chat.clone();
        panel.active = index;
        layout.focused = target.panel;
        self.focus_workspace_tab(target.panel, chat, window, cx);
        self.persist_chat_tabs(cx);
        true
    }

    pub(super) fn render_codex_import(
        &mut self,
        viewport: gpui::Size<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        self.finish_codex_import(window, cx);
        let flow = self.codex_import.as_mut()?;
        if std::mem::take(&mut flow.focus_pending) {
            window.focus(&flow.reference.focus_handle(cx), cx);
        }
        let theme = Theme::of(cx).for_popup();
        let busy = matches!(flow.phase, Phase::Importing | Phase::Opening(_));
        let previewing = flow.phase == Phase::Previewing;
        let preview = flow.preview.clone();
        let error = flow.error.clone();
        let can_preview = !previewing && !busy && !flow.reference.read(cx).text().trim().is_empty();
        let reference = flow.reference.clone();
        let folder = flow.folder.clone();
        let prompt = flow.prompt.clone();
        let preview_focus = flow.preview_focus.clone();
        let continue_focus = flow.continue_focus.clone();
        let cancel_focus = flow.cancel_focus.clone();
        let folder_focus = flow.folder_focus.clone();
        let open_existing = flow.imported_chat.is_some();
        let can_continue = flow.phase == Phase::Ready
            && (open_existing
                || (!flow.folder.read(cx).text().trim().is_empty()
                    && !flow.prompt.read(cx).text().trim().is_empty()));
        let synced = matches!(
            self.state.read(cx).workspace_scope,
            Some(WorkspaceScope::Synced | WorkspaceScope::Development)
        );
        // The footer stays outside this bounded scroll region, including at
        // short window heights and with several import limitations to read.
        let mut card = div()
            .w_full()
            .flex_none()
            .flex()
            .flex_col()
            .on_key_down(cx.listener(|shell, event: &gpui::KeyDownEvent, window, cx| {
                if event.keystroke.key == "enter" && !event.keystroke.modifiers.shift {
                    if shell.codex_import.as_ref().is_some_and(|flow| flow.phase == Phase::Ready) {
                        shell.submit_codex_import(window, cx);
                    } else {
                        shell.preview_codex_import(cx);
                    }
                    cx.stop_propagation();
                }
            }))
            .child(popover::dialog_title(&theme, "Import conversation from Codex"))
            .child(popover::dialog_body(&theme, "Bring in a conversation saved on this device. Continue with graff using its history as context.").mt(px(6.0)));
        if !busy {
            card = card
                .child(
                    div()
                        .mt(px(18.0))
                        .child(field_label(&theme, "Conversation link or ID"))
                        .child(popover::dialog_field(reference.into_any_element()).mt(px(6.0))),
                )
                .child(
                    div().mt(px(8.0)).flex().justify_end().child(
                        popover::btn_ghost(
                            &theme,
                            if previewing {
                                "Finding conversation…"
                            } else {
                                "Find conversation"
                            },
                            "codex-preview",
                        )
                        .id("codex-import-preview")
                        .role(gpui::Role::Button)
                        .aria_label("Find Codex conversation")
                        .track_focus(&preview_focus)
                        .when(!can_preview, |button| button.opacity(0.45))
                        .on_click(cx.listener(move |shell, _, _, cx| {
                            if can_preview {
                                shell.preview_codex_import(cx);
                            }
                        }))
                        .on_key_down(cx.listener(
                            move |shell, event: &gpui::KeyDownEvent, _, cx| {
                                if can_preview
                                    && matches!(event.keystroke.key.as_str(), "enter" | "space")
                                {
                                    shell.preview_codex_import(cx);
                                    cx.stop_propagation();
                                }
                            },
                        )),
                    ),
                );
        }
        if let Some(preview) = &preview {
            let status = if preview.already_imported {
                "Already imported"
            } else {
                "Ready to import"
            };
            let archived = if preview.archived {
                " · Archived in Codex"
            } else {
                ""
            };
            let when = chrono::TimeZone::timestamp_millis_opt(&Utc, preview.updated_at)
                .single()
                .map(|at| format_time_ago(at, Utc::now()))
                .unwrap_or_default();
            card = card.child(
                div()
                    .mt(px(12.0))
                    .pt(px(14.0))
                    .border_t_1()
                    .border_color(theme.element_hover)
                    .child(
                        div()
                            .text_size(crate::typography::ui_rems(14.0))
                            .font_weight(gpui::FontWeight::MEDIUM)
                            .child(transcript::single_line(&preview.title)),
                    )
                    .child(
                        popover::dialog_body(
                            &theme,
                            format!(
                                "{} messages · {when}{archived} · {status}",
                                preview.message_count
                            ),
                        )
                        .mt(px(4.0)),
                    ),
            );
            if let Some(last_message) = &preview.last_message {
                card = card
                    .child(popover::dialog_body(&theme, preview_excerpt(last_message)).mt(px(8.0)));
            }
            if !busy && !open_existing {
                card = card
                    .child(
                        div()
                            .mt(px(16.0))
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .justify_between()
                                    .child(field_label(&theme, "Working folder"))
                                    .child(
                                        popover::btn_ghost(
                                            &theme,
                                            "Choose…",
                                            "codex-choose-folder",
                                        )
                                        .id("codex-import-folder-choose")
                                        .role(gpui::Role::Button)
                                        .aria_label("Choose working folder")
                                        .track_focus(&folder_focus)
                                        .on_click(cx.listener(|shell, _, _, cx| {
                                            shell.choose_codex_import_folder(cx)
                                        }))
                                        .on_key_down(
                                            cx.listener(
                                                |shell, event: &gpui::KeyDownEvent, _, cx| {
                                                    if matches!(
                                                        event.keystroke.key.as_str(),
                                                        "enter" | "space"
                                                    ) {
                                                        shell.choose_codex_import_folder(cx);
                                                        cx.stop_propagation();
                                                    }
                                                },
                                            ),
                                        ),
                                    ),
                            )
                            .child(popover::dialog_field(folder.into_any_element()).mt(px(4.0))),
                    )
                    .child(
                        div()
                            .mt(px(14.0))
                            .child(field_label(&theme, "What should graff do next?"))
                            .child(popover::dialog_field(prompt.into_any_element()).mt(px(6.0))),
                    );
            }
            for warning in &preview.warnings {
                card = card.child(
                    popover::dialog_body(&theme, warning.clone())
                        .mt(px(8.0))
                        .text_color(theme.warning),
                );
            }
            if !preview.cwd_available && preview.warnings.is_empty() {
                card = card.child(popover::dialog_body(&theme, "The original working folder is unavailable. Choose an existing folder before continuing.").mt(px(8.0)).text_color(theme.warning));
            }
        }
        if busy {
            card = card.child(
                popover::dialog_body(&theme, "Importing conversation and preparing graff…")
                    .mt(px(18.0)),
            );
            card = card.child(popover::dialog_body(&theme, "Closing this dialog prevents graff from starting. The imported conversation may still be saved.").mt(px(8.0)));
        }
        if let Some(error) = error {
            card = card.child(
                popover::dialog_body(&theme, error)
                    .mt(px(12.0))
                    .text_color(theme.danger),
            );
        }
        if preview.is_some() && !busy {
            card = card.child(popover::dialog_body(&theme, if synced {
                "The imported conversation will be saved and synced in your current Harness workspace. New replies use your configured graff provider."
            } else {
                "The imported conversation will be saved in this Harness workspace. New replies use your configured graff provider."
            }).mt(px(14.0)));
        }
        let footer = div()
            .id("codex-import-footer")
            .debug_selector(|| "codex-import-footer".into())
            .mt(px(16.0))
            .min_h(px(32.0))
            .flex_none()
            .flex()
            .justify_end()
            .gap(px(8.0))
            .child(
                popover::btn_ghost(
                    &theme,
                    if busy { "Close" } else { "Cancel" },
                    "codex-import-cancel",
                )
                .id("codex-import-cancel")
                .role(gpui::Role::Button)
                .aria_label(if busy {
                    "Close import"
                } else {
                    "Cancel import"
                })
                .track_focus(&cancel_focus)
                .on_click(cx.listener(|shell, _, window, cx| shell.close_codex_import(window, cx)))
                .on_key_down(cx.listener(
                    |shell, event: &gpui::KeyDownEvent, window, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            shell.close_codex_import(window, cx);
                            cx.stop_propagation();
                        }
                    },
                )),
            )
            .when(preview.is_some(), |row| {
                row.child(
                    popover::btn_primary(
                        &theme,
                        if busy {
                            "Preparing…"
                        } else if open_existing {
                            "Open conversation"
                        } else {
                            "Import and continue"
                        },
                    )
                    .id("codex-import-continue")
                    .debug_selector(|| "codex-import-continue".into())
                    .role(gpui::Role::Button)
                    .aria_label(if open_existing {
                        "Open imported conversation"
                    } else {
                        "Import and continue with graff"
                    })
                    .track_focus(&continue_focus)
                    .when(!can_continue, |button| button.opacity(0.45))
                    .on_click(cx.listener(move |shell, _, window, cx| {
                        if can_continue {
                            shell.submit_codex_import(window, cx);
                        }
                    }))
                    .on_key_down(cx.listener(
                        move |shell, event: &gpui::KeyDownEvent, window, cx| {
                            if can_continue
                                && matches!(event.keystroke.key.as_str(), "enter" | "space")
                            {
                                shell.submit_codex_import(window, cx);
                                cx.stop_propagation();
                            }
                        },
                    )),
                )
            });
        let body = div()
            .id("codex-import-body")
            .debug_selector(|| "codex-import-body".into())
            .min_h_0()
            .max_h(px((f32::from(viewport.height) - 136.0).max(80.0)))
            .flex_shrink(1.0)
            .overflow_y_scroll()
            .child(card);
        let card = popover::dialog_card(&theme)
            .id("codex-import-card")
            .role(gpui::Role::Dialog)
            .aria_label("Import conversation from Codex")
            .debug_selector(|| "codex-import-card".into())
            .w(px((f32::from(viewport.width) - 32.0).clamp(300.0, 520.0)))
            .max_h(px(f32::from(viewport.height) - 48.0))
            .overflow_hidden()
            .bg(theme.surface_overlay)
            .shadow_lg()
            .child(body)
            .child(footer);
        Some(popover::modal(
            "codex-import-dialog",
            viewport,
            card.into_any_element(),
        ))
    }
}

fn field_label(theme: &Theme, text: &str) -> gpui::Div {
    div()
        .text_size(crate::typography::ui_rems(12.0))
        .font_weight(gpui::FontWeight::MEDIUM)
        .text_color(theme.text)
        .child(SharedString::from(text.to_string()))
}

fn preview_excerpt(text: &str) -> String {
    let text = transcript::single_line(text);
    let mut excerpt: String = text.chars().take(180).collect();
    if text.chars().count() > 180 {
        excerpt.push('…');
    }
    excerpt
}

#[cfg(any(test, feature = "appshots-fixture"))]
fn synthetic_preview(archived: bool) -> CodexPreview {
    CodexPreview {
        title: "Improve the release checklist".into(),
        cwd: Some("/fixtures/launch".into()),
        cwd_available: true,
        updated_at: Utc::now().timestamp_millis() - 12 * 60 * 1000,
        archived,
        message_count: 12,
        last_message: Some("The checklist now covers the build and release notes. Next, verify the rollback steps and add the missing deployment check.".into()),
        already_imported: false,
        chat_id: None,
        warnings: vec!["Imports text messages and brief tool results. Images, attachments, and full tool output are not included.".into()],
    }
}

#[cfg(feature = "appshots-fixture")]
impl Shell {
    pub fn fixture_resume_conversation(
        &mut self,
        query: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_codex_import(window, cx);
        self.command_palette = None;
        self.fixture_codex_import("blank", window, cx);
        let panel = self.panel_layout(cx).unwrap().focused;
        self.open_conversation_palette_in_panel(panel, window, cx);
        self.command_palette
            .as_ref()
            .unwrap()
            .fixture_type(query, cx);
        cx.notify();
    }

    /// Deterministic dialog states; never reads history or sends an agent turn.
    pub fn fixture_codex_import(
        &mut self,
        phase: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.close_codex_import(window, cx);
        self.command_palette = None;
        let selected_blank = self
            .panel_layout(cx)
            .and_then(|layout| {
                layout
                    .panels
                    .iter()
                    .find(|panel| panel.id == layout.focused)
            })
            .is_some_and(|panel| matches!(panel.selected(), Some(PanelTab::New(_))));
        if !selected_blank {
            self.workspace_new_tab(cx);
        }
        if phase == "blank" {
            window.blur();
            return;
        }
        let panel = self.panel_layout(cx).unwrap().focused;
        self.open_codex_import(panel, window, cx);
        let flow = self.codex_import.as_mut().unwrap();
        // Fixture fields are static; no queued edit can invalidate the state.
        flow._inputs.clear();
        flow.reference.update(cx, |input, cx| {
            input.set_text("codex://threads/11111111-1111-4111-8111-111111111111", cx)
        });
        if phase != "entry" {
            let mut preview = synthetic_preview(phase == "archived");
            if phase == "missing" {
                preview.cwd_available = false;
                preview.warnings.push("The original working folder is unavailable. Choose an existing working folder before continuing.".into());
            }
            if phase == "long-history" {
                preview.message_count = 640;
                preview.warnings.push("The initial request and most recent conversation will be used to continue; some earlier content will be omitted.".into());
            }
            flow.folder.update(cx, |input, cx| {
                input.set_text(preview.cwd.clone().unwrap_or_default(), cx)
            });
            flow.preview = Some(preview);
            flow.phase = Phase::Ready;
        }
        if phase == "error" {
            flow.preview = None;
            flow.phase = Phase::Editing;
            flow.error = Some("This conversation was not found on this device. Check its ID, or use the device where it was saved.".into());
        }
        flow.focus_pending = false;
        window.blur();
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open_fixture(
        shell: &mut Shell,
        window: &mut Window,
        cx: &mut Context<Shell>,
    ) -> ImportTarget {
        shell.boot_restored = true;
        shell.ensure_workspace_sessions(cx);
        shell.workspace_new_tab(cx);
        let panel = shell.panel_layout(cx).unwrap().focused;
        shell.open_codex_import(panel, window, cx);
        shell.codex_import.as_ref().unwrap().target.clone()
    }

    #[gpui::test]
    fn codex_import_from_an_empty_split_panel_creates_its_own_blank_target(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            shell.boot_restored = true;
            shell.ensure_workspace_sessions(cx);
            shell.sync_panel_workspace(cx);
            shell.workspace_split(SplitAxis::Vertical, cx);
            let destination = shell.panel_layout(cx).unwrap().focused;
            shell
                .panel_layout_mut(cx)
                .panels
                .iter_mut()
                .find(|panel| panel.id == destination)
                .unwrap()
                .tabs
                .clear();
            shell.open_codex_import(destination, window, cx);
            let target = shell.codex_import.as_ref().unwrap().target.clone();
            assert_eq!(target.panel, destination);
            assert!(matches!(target.tab, PanelTab::New(_)));
            assert!(shell.codex_import_target_exists(&target));
            assert_eq!(
                shell
                    .panel_layout(cx)
                    .unwrap()
                    .panels
                    .iter()
                    .find(|panel| panel.id == destination)
                    .unwrap()
                    .tabs,
                vec![target.tab]
            );
        })
        .unwrap();
    }

    #[gpui::test]
    fn codex_import_traps_tab_and_escape_preserves_the_blank(cx: &mut gpui::TestAppContext) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            let target = open_fixture(shell, window, cx);
            let input = shell
                .codex_import
                .as_ref()
                .unwrap()
                .reference
                .focus_handle(cx);
            window.focus(&input, cx);
            shell.cycle_codex_import_focus(true, window, cx);
            assert!(
                shell
                    .codex_import
                    .as_ref()
                    .unwrap()
                    .cancel_focus
                    .is_focused(window)
            );
            shell.cycle_codex_import_focus(false, window, cx);
            assert!(input.is_focused(window));
            assert!(shell.overlay_owns_keyboard(cx));
            shell.on_key_down_capture(
                &gpui::KeyDownEvent {
                    keystroke: gpui::Keystroke::parse("escape").unwrap(),
                    is_held: false,
                    prefer_character_input: false,
                },
                window,
                cx,
            );
            assert!(shell.codex_import.is_none());
            assert!(shell.codex_import_target_exists(&target));
        })
        .unwrap();
    }

    #[gpui::test]
    fn codex_import_replaces_the_initiating_blank_after_another_tab_is_selected(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            let target = open_fixture(shell, window, cx);
            shell.workspace_new_tab(cx);
            let other_blank = shell
                .panel_layout(cx)
                .unwrap()
                .panels
                .iter()
                .find(|panel| panel.id == target.panel)
                .unwrap()
                .selected()
                .unwrap()
                .clone();
            assert_ne!(other_blank, target.tab);
            assert!(shell.place_codex_imported_chat(&target, "target", window, cx));
            let panel = shell
                .panel_layout(cx)
                .unwrap()
                .panels
                .iter()
                .find(|panel| panel.id == target.panel)
                .unwrap();
            assert!(!panel.tabs.contains(&target.tab));
            assert!(panel.tabs.contains(&other_blank));
            assert_eq!(panel.selected(), Some(&PanelTab::Chat("target".into())));
        })
        .unwrap();
    }

    #[gpui::test]
    fn codex_import_restores_its_workspace_and_preserves_a_different_sessions_draft(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            let target = open_fixture(shell, window, cx);
            shell.create_workspace_session(cx);
            let other = shell.chat_tabs[shell.chat_tab].id.clone();
            shell.workspace_new_chat(cx);
            shell.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Keep this separate draft".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            assert!(shell.place_codex_imported_chat(&target, "target", window, cx));
            assert_eq!(shell.chat_tabs[shell.chat_tab].id, target.workspace);
            shell.activate_workspace_session(&other, cx);
            assert_eq!(
                shell.current_canvas_draft(cx).input.unwrap().text,
                "Keep this separate draft"
            );
        })
        .unwrap();
    }

    #[gpui::test]
    fn codex_import_does_not_replace_a_changed_target_or_dispatch_after_it_closed(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            let target = open_fixture(shell, window, cx);
            shell.workspace_new_chat(cx);
            let before = shell.panel_layout(cx).unwrap().panels[0].tabs.clone();
            assert!(!shell.codex_import_target_exists(&target));
            shell.codex_import.as_mut().unwrap().phase = Phase::Opening("target".into());
            shell.finish_codex_import(window, cx);
            assert_eq!(shell.panel_layout(cx).unwrap().panels[0].tabs, before);
            let flow = shell.codex_import.as_ref().unwrap();
            assert_eq!(flow.imported_chat.as_deref(), Some("target"));
            assert!(flow.error.as_ref().unwrap().contains("closed or changed"));
            assert!(shell.state.read(cx).selected_chat.is_none());
        })
        .unwrap();
    }

    #[gpui::test]
    fn codex_import_moves_an_already_open_chat_into_the_requested_blank(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        host.update(cx, |shell, window, cx| {
            let target = open_fixture(shell, window, cx);
            shell.panel_layout_mut(cx).panels[0]
                .tabs
                .insert(0, PanelTab::Chat("target".into()));
            assert!(shell.place_codex_imported_chat(&target, "target", window, cx));
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(
                layout
                    .panels
                    .iter()
                    .flat_map(|panel| &panel.tabs)
                    .filter(|tab| **tab == PanelTab::Chat("target".into()))
                    .count(),
                1
            );
            assert!(
                !layout
                    .panels
                    .iter()
                    .flat_map(|panel| &panel.tabs)
                    .any(|tab| *tab == target.tab)
            );
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("target")
            );
        })
        .unwrap();
    }

    #[gpui::test]
    fn codex_import_edit_invalidates_a_preview_and_rejects_stale_responses(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, host) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let (generation, request) = host
            .update(cx, |shell, window, cx| {
                open_fixture(shell, window, cx);
                let flow = shell.codex_import.as_mut().unwrap();
                flow.preview = Some(synthetic_preview(false));
                flow.phase = Phase::Ready;
                let identity = (flow.generation, flow.request);
                flow.reference
                    .update(cx, |input, cx| input.set_text("a different reference", cx));
                identity
            })
            .unwrap();
        cx.run_until_parked();
        host.update(cx, |shell, window, cx| {
            assert!(!shell.codex_import_matches(generation, request));
            let flow = shell.codex_import.as_ref().unwrap();
            assert_eq!(flow.phase, Phase::Editing);
            assert!(flow.preview.is_none());
            shell.preview_codex_import(cx);
            assert!(
                shell
                    .codex_import
                    .as_ref()
                    .unwrap()
                    .error
                    .as_ref()
                    .unwrap()
                    .contains("engine")
            );
            shell.close_codex_import(window, cx);
            assert!(!shell.codex_import_matches(generation, request));
        })
        .unwrap();
    }
}
