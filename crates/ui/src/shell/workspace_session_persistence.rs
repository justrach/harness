//! Durable session workspaces. Settings hold placement and resource descriptors;
//! a fresh process recreates tool entities only when the session is displayed.

use super::*;
use crate::pickers::{CanvasDraft, CanvasGit, CanvasInput, CanvasTarget};
use crate::settings::{
    SavedCanvasDraft, SavedCanvasGit, SavedCanvasTarget, SavedDraftAttachment, SavedPanelTab, SavedWorkspacePanel,
    SavedWorkspacePanels, SavedWindowAppshot, SavedWindowChatDraft,
};
use std::collections::{HashMap, HashSet};
use workspace_panels::{PanelTab, WorkspaceLayout, WorkspacePanel};

const DRAFT_CACHE: &str = "workspace-drafts";

/// Upgrade an old split once, at startup. Runtime sync must not reapply old
/// geometry over later workspace edits. The selected chat owns its focus slot;
/// stale duplicate references leave usable blank panes rather than extra views.
pub(super) fn legacy_workspace_panels(
    split: &chat_split::ChatSplit,
    selected: Option<&str>,
) -> SavedWorkspacePanels {
    let mut seen: HashSet<String> = selected.into_iter().map(str::to_owned).collect();
    let panels = split
        .panes
        .iter()
        .enumerate()
        .map(|(ix, chat)| {
            let chat = if ix == split.focus {
                selected.map(str::to_owned)
            } else {
                chat.clone().filter(|id| seen.insert(id.clone()))
            };
            let tab = match chat {
                Some(id) => SavedPanelTab::Chat { id },
                None => SavedPanelTab::Draft {
                    draft: SavedCanvasDraft {
                        target: split.projects.get(ix).cloned().flatten().map(|space| {
                            SavedCanvasTarget {
                                space: Some(space),
                                no_project: false,
                                device: None,
                            }
                        }),
                        ..Default::default()
                    },
                },
            };
            SavedWorkspacePanel {
                id: ix as u64,
                tabs: vec![tab],
                active: 0,
                share: split.shares[ix],
                new_panel_target: None,
            }
        })
        .collect();
    SavedWorkspacePanels {
        vertical: split.axis == SplitAxis::Vertical,
        panels,
        focused: split.focus as u64,
        expanded: None,
    }
}

fn draft_attachment_key(id: &str) -> String {
    if let Ok(id) = uuid::Uuid::parse_str(id) {
        return id.to_string();
    }
    // Intake normally supplies UUIDs; deterministic fallback also preserves
    // attachments created by importers without treating their IDs as paths.
    use std::hash::{Hash, Hasher};
    let mut a = std::collections::hash_map::DefaultHasher::new();
    id.hash(&mut a);
    let mut b = std::collections::hash_map::DefaultHasher::new();
    (id, "workspace-draft").hash(&mut b);
    uuid::Uuid::from_u128((u128::from(a.finish()) << 64) | u128::from(b.finish())).to_string()
}

fn cache_draft_attachment(
    folder: &std::path::Path,
    key: &str,
    bytes: &[u8],
) -> std::io::Result<()> {
    use std::io::Write as _;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt as _, PermissionsExt as _};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(folder)?;
        std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(not(unix))]
    std::fs::create_dir_all(folder)?;
    let path = folder.join(key);
    if path.exists() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }
        return Ok(());
    }
    let temporary = folder.join(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(bytes)?;
        std::fs::rename(&temporary, &path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

impl Shell {
    pub(super) fn saved_window_chat_drafts(
        &self,
        cx: &App,
    ) -> HashMap<String, SavedWindowChatDraft> {
        let owners: HashSet<_> = self
            .workspace_panels
            .layouts
            .values()
            .flat_map(|layout| &layout.panels)
            .flat_map(|panel| &panel.tabs)
            .filter_map(|tab| {
                if let PanelTab::Chat(chat) = tab {
                    Some(chat.clone())
                } else {
                    None
                }
            })
            .collect();
        owners
            .into_iter()
            .filter_map(|chat| self.saved_chat_draft(&chat, cx).map(|draft| (chat, draft)))
            .collect()
    }

    pub(super) fn saved_chat_draft(&self, chat: &str, cx: &App) -> Option<SavedWindowChatDraft> {
        let (input, appshots) = self.composer.read(cx).saved_window_draft(chat, cx);
        if input.text.is_empty() && input.stage.is_empty() && appshots.is_empty() {
            return None;
        }
        let input = self.save_canvas_draft(&CanvasDraft {
            input: Some(input),
            ..Default::default()
        });
        let appshots = appshots
            .into_iter()
            .map(|shot| {
                let screenshot = self
                    .save_canvas_draft(&CanvasDraft {
                        input: Some(CanvasInput {
                            text: String::new(),
                            stage: vec![shot.screenshot],
                        }),
                        ..Default::default()
                    })
                    .attachments
                    .into_iter()
                    .next()
                    .unwrap();
                SavedWindowAppshot {
                    id: shot.id,
                    app_name: shot.app_name,
                    bundle_identifier: shot.bundle_identifier,
                    window_title: shot.window_title,
                    accessibility_format_version: shot.accessibility.format_version,
                    accessibility_content: shot.accessibility.content,
                    accessibility_truncated: shot.accessibility.truncated,
                    screenshot,
                    screenshot_dimensions: shot.screenshot_dimensions,
                    captured_at: shot.captured_at,
                }
            })
            .collect();
        Some(SavedWindowChatDraft { input, appshots })
    }

    pub(super) fn restore_window_chat_drafts(
        &mut self,
        saved: &HashMap<String, SavedWindowChatDraft>,
        cx: &mut Context<Self>,
    ) {
        let mut missing = false;
        for (chat, draft) in saved {
            let input = self
                .restored_canvas_draft(&draft.input)
                .input
                .unwrap_or_default();
            missing |= input.stage.iter().any(|attachment| attachment.unavailable.is_some());
            let appshots = draft
                .appshots
                .iter()
                .filter_map(|shot| {
                    let mut restored = self
                        .restored_canvas_draft(&SavedCanvasDraft {
                            attachments: vec![shot.screenshot.clone()],
                            ..Default::default()
                        })
                        .input
                        .unwrap_or_default()
                        .stage;
                    let screenshot = restored.pop()?;
                    Some(crate::appshots::CapturedAppshot {
                        id: shot.id.clone(),
                        app_name: shot.app_name.clone(),
                        bundle_identifier: shot.bundle_identifier.clone(),
                        window_title: shot.window_title.clone(),
                        accessibility: crate::appshots::AccessibilitySnapshot {
                            format_version: shot.accessibility_format_version,
                            content: shot.accessibility_content.clone(),
                            truncated: shot.accessibility_truncated,
                        },
                        screenshot,
                        screenshot_dimensions: shot.screenshot_dimensions,
                        app_icon: None,
                        captured_at: shot.captured_at,
                    })
                })
                .collect::<Vec<_>>();
            missing |= appshots.len() < draft.appshots.len()
                || appshots.iter().any(|shot| shot.screenshot.unavailable.is_some());
            self.composer.update(cx, |composer, cx| {
                composer.restore_saved_window_draft(chat.clone(), input, appshots, cx)
            });
        }
        if missing {
            self.sidebar_notice = Some(
                "Some draft attachments could not be restored. Reattach them before sending."
                    .into(),
            );
        }
    }

    pub(super) fn saved_workspace_panels(
        &self,
        session: &str,
        cx: &App,
    ) -> Option<SavedWorkspacePanels> {
        let layout = self.workspace_panels.layouts.get(session)?;
        let pending: HashMap<_, _> = self
            .workspace_panels
            .pending_tools
            .get(session)
            .into_iter()
            .flatten()
            .map(|(panel, index, tab)| ((*panel, *index), tab))
            .collect();
        let fallback_owner = self
            .chat_tabs
            .iter()
            .find(|tab| tab.id == session)
            .map(|tab| {
                tab.selected.clone().unwrap_or_else(|| {
                    format!(
                        "{}{}",
                        crate::state::CANVAS_PANEL_PREFIX,
                        tab.project.as_deref().unwrap_or_default()
                    )
                })
            })
            .unwrap_or_else(|| self.state.read(cx).panel_session_key());
        Some(SavedWorkspacePanels {
            vertical: layout.axis == SplitAxis::Vertical,
            focused: layout.focused,
            expanded: layout.expanded,
            panels: layout
                .panels
                .iter()
                .map(|panel| SavedWorkspacePanel {
                    id: panel.id,
                    new_panel_target: self.saved_workspace_panel_device(session, panel.id, cx),
                    active: panel.active,
                    share: panel.share,
                    tabs: panel
                        .tabs
                        .iter()
                        .enumerate()
                        .map(|(index, tab)| {
                            pending
                                .get(&(panel.id, index))
                                .map(|tab| (*tab).clone())
                                .unwrap_or_else(|| self.saved_panel_tab(tab, &fallback_owner, cx))
                        })
                        .collect(),
                })
                .collect(),
        })
    }

    fn saved_panel_tab(&self, tab: &PanelTab, fallback_owner: &str, cx: &App) -> SavedPanelTab {
        match tab {
            PanelTab::Chat(id) => SavedPanelTab::Chat { id: id.clone() },
            PanelTab::New(id) => SavedPanelTab::New {
                draft: self.save_canvas_draft(
                    &self
                        .workspace_panels
                        .drafts
                        .get(id)
                        .cloned()
                        .unwrap_or_default(),
                ),
            },
            PanelTab::Draft(id) => SavedPanelTab::Draft {
                draft: self.save_canvas_draft(
                    &self
                        .workspace_panels
                        .drafts
                        .get(id)
                        .cloned()
                        .unwrap_or_default(),
                ),
            },
            PanelTab::Surface { owner, surface } => match surface {
                RightSurface::Browser(id) => SavedPanelTab::Browser {
                    owner: owner.clone(),
                    url: self
                        .browsers
                        .get(id)
                        .and_then(|browser| browser.read(cx).page.url.clone()),
                },
                RightSurface::File(id) => self
                    .file_surfaces
                    .get(id)
                    .and_then(|file| {
                        let file = file.read(cx);
                        file.attachment_path().map(|path| SavedPanelTab::File {
                            owner: file.session_owner().to_owned(),
                            path: path.to_owned(),
                        })
                    })
                    .unwrap_or_default(),
                RightSurface::Terminal(_) => {
                    let owner = if owner.starts_with("workspace:") {
                        fallback_owner.to_owned()
                    } else {
                        owner.clone()
                    };
                    let target_device_id = self
                        .right_terminal
                        .as_ref()
                        .map(|terminal| terminal.read(cx).device_target_for_owner(&owner, cx))
                        .unwrap_or_else(|| self.state.read(cx).terminal_target_device(&owner))
                        .or_else(|| self.state.read(cx).local_device_id.clone());
                    SavedPanelTab::Terminal {
                        owner,
                        target_device_id,
                    }
                }
                RightSurface::Diff(_) => SavedPanelTab::Diff {
                    owner: owner.clone(),
                },
                RightSurface::Subagent(id) => self
                    .subagent_tabs
                    .get(id)
                    .map(|tab| SavedPanelTab::Subagent {
                        owner: tab.chat_id.clone(),
                        doc: tab.doc_id.clone(),
                        title: tab.title.to_string(),
                    })
                    .unwrap_or_default(),
                RightSurface::Picker => SavedPanelTab::Empty,
            },
            PanelTab::Files(owner) => SavedPanelTab::Files {
                target_device_id: self
                    .files
                    .get(owner)
                    .and_then(|files| files.read(cx).preferred_device_id(cx)),
                owner: self
                    .files
                    .get(owner)
                    .map(|files| files.read(cx).session_owner().to_owned())
                    .unwrap_or_else(|| self.files_engine_owner(owner, cx)),
            },
            PanelTab::FileTree(id) => SavedPanelTab::Files {
                target_device_id: self
                    .workspace_panels
                    .explorers
                    .get(id)
                    .and_then(|(files, _, _)| files.read(cx).preferred_device_id(cx)),
                owner: self
                    .workspace_panels
                    .explorers
                    .get(id)
                    .map(|(files, _, _)| files.read(cx).session_owner().to_owned())
                    .unwrap_or_else(|| fallback_owner.into()),
            },
            PanelTab::Terminal(id) => {
                SavedPanelTab::Terminal {
                    target_device_id: self.workspace_panels.terminals.get(id).and_then(
                        |terminal| {
                            terminal
                                .read(cx)
                                .device_target(cx)
                                .or_else(|| self.state.read(cx).local_device_id.clone())
                        },
                    ),
                    owner: self
                        .workspace_panels
                        .terminals
                        .get(id)
                        .map(|terminal| terminal.read(cx).session_owner(cx))
                        .unwrap_or_else(|| fallback_owner.into()),
                }
            }
            PanelTab::TerminalDock(owner) => {
                let owner = if owner.starts_with("workspace:") {
                    fallback_owner.to_owned()
                } else {
                    owner.clone()
                };
                let target_device_id = self
                    .terminal
                    .as_ref()
                    .map(|terminal| terminal.read(cx).device_target_for_owner(&owner, cx))
                    .unwrap_or_else(|| self.state.read(cx).terminal_target_device(&owner))
                    .or_else(|| self.state.read(cx).local_device_id.clone());
                SavedPanelTab::Terminal {
                    owner,
                    target_device_id,
                }
            }
            PanelTab::Empty => SavedPanelTab::Empty,
        }
    }

    pub(super) fn save_canvas_draft(&self, draft: &CanvasDraft) -> SavedCanvasDraft {
        SavedCanvasDraft {
            harness: draft.harness.clone(),
            model: draft.model.clone(),
            reasoning: draft.reasoning.clone(),
            target: draft.target.as_ref().map(|target| SavedCanvasTarget {
                space: target.space.clone(),
                no_project: target.no_project,
                device: target.device.clone(),
            }),
            git: draft.git.as_ref().map(|git| SavedCanvasGit { branch: git.branch.clone(), checkout: git.checkout.clone() }),
            text: draft
                .input
                .as_ref()
                .map(|input| input.text.clone())
                .unwrap_or_default(),
            attachments: draft
                .input
                .as_ref()
                .into_iter()
                .flat_map(|input| &input.stage)
                .map(|attachment| {
                    if let Some(reference) = &attachment.unavailable { return reference.clone(); }
                    #[cfg(target_os = "macos")]
                    let editable = if let Some(editable) = &attachment.editable {
                        Some(match editable.save(&self.data_dir.join(DRAFT_CACHE)) {
                            Ok(saved) => saved,
                            Err(error) => {
                                tracing::warn!(%error, "could not cache an annotation original");
                                // Preserve the document/reference even if the disk is
                                // unavailable. Restoration must show a recovery state,
                                // never silently edit an already-flattened image.
                                editable.saved_reference()
                            }
                        })
                    } else {
                        attachment.unavailable_editable.clone()
                    };
                    let key = draft_attachment_key(&attachment.id);
                    #[cfg(target_os = "macos")]
                    let key = if editable.is_some() {
                        crate::annotate::editable::flattened_cache_key(attachment.bytes())
                    } else {
                        key
                    };
                    if let Err(error) = cache_draft_attachment(
                        &self.data_dir.join(DRAFT_CACHE),
                        &key,
                        attachment.bytes(),
                    ) {
                        tracing::warn!(%error, "could not cache a staged workspace attachment");
                    }
                    SavedDraftAttachment {
                        id: attachment.id.clone(),
                        name: attachment.name.clone(),
                        cache_key: key,
                        image: attachment.image.is_some(),
                        annotations: attachment.annotations.as_ref().map(|value| value.to_string()),
                        #[cfg(target_os = "macos")]
                        editable,
                    }
                })
                .collect(),
        }
    }

    pub(super) fn restored_canvas_draft(&self, draft: &SavedCanvasDraft) -> CanvasDraft {
        let stage = draft
            .attachments
            .iter()
            .map(|attachment| {
                // Validate the cache key before reading; an unsafe or missing reference
                // remains recoverable instead of silently becoming a text-only draft.
                let bytes = uuid::Uuid::parse_str(&attachment.cache_key).ok()
                    .and_then(|key| std::fs::read(self.data_dir.join(DRAFT_CACHE).join(key.to_string())).ok());
                let Some(bytes) = bytes else {
                    return crate::attachments::StagedAttachment {
                        id: attachment.id.clone(), name: attachment.name.clone(),
                        image: None, file: None,
                        annotations: attachment.annotations.clone().map(Into::into),
                        unavailable: Some(attachment.clone()),
                        #[cfg(target_os = "macos")]
                        editable: None,
                        #[cfg(target_os = "macos")]
                        unavailable_editable: attachment.editable.clone(),
                    };
                };
                let (image, file) = if attachment.image {
                    let format = crate::attachments::format_by_extension(std::path::Path::new(
                        &attachment.name,
                    ))
                    .unwrap_or(gpui::ImageFormat::Png);
                    (
                        Some(std::sync::Arc::new(gpui::Image::from_bytes(format, bytes))),
                        None,
                    )
                } else {
                    (None, Some(std::sync::Arc::<[u8]>::from(bytes)))
                };
                #[cfg(target_os = "macos")]
                let (editable, unavailable_editable) = match &attachment.editable {
                    Some(saved) => match saved.restore(&self.data_dir.join(DRAFT_CACHE)) {
                        Ok(editable) => (Some(editable), None),
                        Err(error) => {
                            tracing::warn!(%error, "could not restore an annotation original");
                            (None, Some(saved.clone()))
                        }
                    },
                    None => (None, None),
                };
                crate::attachments::StagedAttachment {
                    id: attachment.id.clone(),
                    name: attachment.name.clone(),
                    image,
                    file,
                    annotations: attachment.annotations.clone().map(Into::into),
                    unavailable: None,
                    #[cfg(target_os = "macos")]
                    editable,
                    #[cfg(target_os = "macos")]
                    unavailable_editable,
                }
            })
            .collect();
        CanvasDraft {
            harness: draft.harness.clone(),
            model: draft.model.clone(),
            reasoning: draft.reasoning.clone(),
            target: draft.target.as_ref().map(|target| CanvasTarget {
                space: target.space.clone(),
                no_project: target.no_project,
                device: target.device.clone(),
            }),
            git: draft.git.as_ref().map(|git| CanvasGit { branch: git.branch.clone(), checkout: git.checkout.clone() }),
            input: Some(CanvasInput {
                text: draft.text.clone(),
                stage,
            }),
        }
    }

    pub(super) fn restore_workspace_panels(
        &mut self,
        session: &str,
        saved: &SavedWorkspacePanels,
        cx: &mut Context<Self>,
    ) {
        if saved.panels.is_empty() {
            return;
        }
        let mut layout = WorkspaceLayout::default();
        layout.axis = if saved.vertical {
            SplitAxis::Vertical
        } else {
            SplitAxis::Horizontal
        };
        layout.panels.clear();
        let mut ids = HashSet::new();
        let mut pending = Vec::new();
        for saved_panel in &saved.panels {
            if !ids.insert(saved_panel.id) {
                continue;
            }
            if let Some(target) = &saved_panel.new_panel_target {
                self.restore_workspace_panel_device(session, saved_panel.id, target, cx);
            }
            let mut tabs = Vec::new();
            let mut selected = None;
            for (old_index, tab) in saved_panel.tabs.iter().enumerate() {
                let index = tabs.len();
                let restored = match tab {
                    SavedPanelTab::Chat { id } => PanelTab::Chat(id.clone()),
                    SavedPanelTab::Draft { draft } => {
                        self.workspace_panels.seq += 1;
                        let id = self.workspace_panels.seq;
                        let restored = self.restored_canvas_draft(draft);
                        if restored.input.as_ref().is_some_and(|input| input.stage.iter().any(|attachment| attachment.unavailable.is_some()))
                        {
                            self.sidebar_notice = Some("Some draft attachments could not be restored. Reattach them before sending.".into());
                        }
                        self.workspace_panels.drafts.insert(id, restored);
                        PanelTab::Draft(id)
                    }
                    SavedPanelTab::New { draft } => {
                        self.workspace_panels.seq += 1;
                        let id = self.workspace_panels.seq;
                        let restored = self.restored_canvas_draft(draft);
                        self.workspace_panels.drafts.insert(id, restored);
                        PanelTab::New(id)
                    }
                    SavedPanelTab::Empty => PanelTab::Empty,
                    descriptor => {
                        pending.push((saved_panel.id, index, descriptor.clone()));
                        PanelTab::Empty
                    }
                };
                if old_index == saved_panel.active {
                    selected = Some(index);
                }
                tabs.push(restored);
            }
            let active = selected
                .unwrap_or(saved_panel.active)
                .min(tabs.len().saturating_sub(1));
            layout.panels.push(WorkspacePanel {
                id: saved_panel.id,
                tabs,
                active,
                share: if saved_panel.share.is_finite() && saved_panel.share > 0.0 {
                    saved_panel.share
                } else {
                    1.0
                },
            });
        }
        if layout.panels.is_empty() {
            return;
        }
        let total: f64 = layout.panels.iter().map(|panel| f64::from(panel.share)).sum();
        for panel in &mut layout.panels {
            panel.share = (f64::from(panel.share) / total) as f32;
        }
        layout.next_id = layout
            .panels
            .iter()
            .map(|panel| panel.id)
            .max()
            .unwrap_or(0)
            .saturating_add(1);
        layout.focused = if ids.contains(&saved.focused) {
            saved.focused
        } else {
            layout.panels[0].id
        };
        layout.expanded = saved.expanded.filter(|id| ids.contains(id));
        layout.last_selected = Some(
            self.chat_tabs
                .iter()
                .find(|tab| tab.id == session)
                .and_then(|tab| tab.selected.clone()),
        );
        let focused_draft = layout
            .panels
            .iter()
            .find(|panel| panel.id == layout.focused)
            .and_then(|panel| panel.selected())
            .and_then(|tab| match tab {
                PanelTab::Draft(id) | PanelTab::New(id) => {
                    self.workspace_panels.drafts.get(id).cloned()
                }
                _ => None,
            });
        if let Some(tab) = self.chat_tabs.iter_mut().find(|tab| tab.id == session)
            && let Some(draft) = focused_draft
        {
            tab.draft = Some(draft);
        }
        self.workspace_panels.needs_persist = true;
        self.workspace_panels.layouts.insert(session.into(), layout);
        self.workspace_panels
            .pending_tools
            .insert(session.into(), pending);
    }

    pub(super) fn restore_pending_workspace_tools(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let session = self.workspace_layout_key(cx);
        let Some(pending) = self.workspace_panels.pending_tools.remove(&session) else {
            return;
        };
        if pending.is_empty() {
            return;
        }
        let Some(mut layout) = self.workspace_panels.layouts.get(&session).cloned() else {
            return;
        };
        let old_owner = self.workspace_panels.resource_owner.clone();
        let old_engine_owner = self.workspace_panels.resource_engine_owner.clone();
        let ui_owner = format!("workspace:{session}");
        let mut unresolved = Vec::new();
        for (panel, index, descriptor) in pending {
            if !layout.panels.iter().any(|target| target.id == panel && target.tabs.get(index) == Some(&PanelTab::Empty)) { continue; }
            let retained_descriptor = descriptor.clone();
            let owner = match &descriptor {
                SavedPanelTab::Browser { owner, .. }
                | SavedPanelTab::File { owner, .. }
                | SavedPanelTab::Files { owner, .. }
                | SavedPanelTab::Terminal { owner, .. }
                | SavedPanelTab::Diff { owner }
                | SavedPanelTab::Subagent { owner, .. } => owner.clone(),
                _ => continue,
            };
            self.workspace_panels.resource_owner = Some(ui_owner.clone());
            self.workspace_panels.resource_engine_owner = match &descriptor {
                SavedPanelTab::File { .. } | SavedPanelTab::Files { .. } => Some(owner.clone()),
                _ => None,
            };
            let tab = match descriptor {
                SavedPanelTab::Browser { url, .. } => {
                    self.add_browser_surface(url, window, cx);
                    PanelTab::Surface {
                        owner: ui_owner.clone(),
                        surface: RightSurface::Browser(self.browser_seq),
                    }
                }
                SavedPanelTab::File { path, .. } => {
                    self.add_file_surface(path.clone(), window, cx);
                    self.file_surface_keys
                        .get(&(
                            ui_owner.clone(),
                            self.files_engine_owner(&ui_owner, cx),
                            path,
                        ))
                        .copied()
                        .map(|id| PanelTab::Surface {
                            owner: ui_owner.clone(),
                            surface: RightSurface::File(id),
                        })
                        .unwrap_or(PanelTab::Empty)
                }
                SavedPanelTab::Files {
                    target_device_id, ..
                } => {
                    self.open_workspace_files(window, cx);
                    if let Some(files) = self
                        .workspace_panels
                        .explorers
                        .get(&self.workspace_panels.seq)
                        .map(|(files, _, _)| files.clone())
                    {
                        files.update(cx, |files, _| files.prefer_device(target_device_id));
                    }
                    PanelTab::FileTree(self.workspace_panels.seq)
                }
                SavedPanelTab::Terminal {
                    target_device_id, ..
                } => {
                    let pinned_target = target_device_id.map(|id| {
                        (self.state.read(cx).local_device_id.as_deref() != Some(id.as_str()))
                            .then_some(id)
                    });
                    let state = self.state.clone();
                    let terminal = cx.new(|cx| {
                        let mut terminal = TerminalPanel::new_embedded(state, cx);
                        terminal.pin_session(owner);
                        if let Some(target) = pinned_target {
                            terminal.pin_device(target);
                        }
                        terminal
                    });
                    let key = terminal.update(cx, |terminal, cx| {
                        terminal.set_open(true, cx);
                        terminal.open_tab_for_selected(cx)
                    });
                    if let Some(key) = key {
                        self.workspace_panels.seq += 1;
                        let id = self.workspace_panels.seq;
                        self.workspace_panels.terminals.insert(id, terminal);
                        self.workspace_panels.terminal_keys.insert(id, key);
                        PanelTab::Terminal(id)
                    } else {
                        PanelTab::Empty
                    }
                }
                SavedPanelTab::Diff { .. } => {
                    self.add_diff_surface(cx);
                    PanelTab::Surface {
                        owner: ui_owner.clone(),
                        surface: RightSurface::Diff(self.diff_seq),
                    }
                }
                SavedPanelTab::Subagent { doc, title, .. } => {
                    let source = if self.active_chat == owner { Some(self.transcript.clone()) }
                        else { self.workspace_panels.peers.get(&owner).map(|(view, _)| view.clone())
                            .or_else(|| self.peer_chat_views.get(&owner).map(|peer| peer.transcript.clone())) };
                    let Some(source) = source else { unresolved.push((panel, index, retained_descriptor)); continue; };
                    self.add_subagent_surface(owner.clone(), doc.clone(), title, false, source, cx);
                    self.subagent_tabs
                        .iter()
                        .find(|(_, tab)| tab.doc_id == doc)
                        .map(|(id, _)| PanelTab::Surface {
                            owner: ui_owner.clone(),
                            surface: RightSurface::Subagent(*id),
                        })
                        .unwrap_or(PanelTab::Empty)
                }
                _ => continue,
            };
            if let Some(target) = layout.panels.iter_mut().find(|target| target.id == panel)
                && let Some(slot) = target.tabs.get_mut(index)
            {
                *slot = tab.clone();
            }
            if tab == PanelTab::Empty { unresolved.push((panel, index, retained_descriptor)); } else { layout.imported.insert(tab); }
        }
        if !unresolved.is_empty() { self.workspace_panels.pending_tools.insert(session.clone(), unresolved); }
        self.workspace_panels.resource_owner = old_owner;
        self.workspace_panels.resource_engine_owner = old_engine_owner;
        self.workspace_panels.needs_persist = true;
        self.workspace_panels.layouts.insert(session, layout);
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::chat_tabs::ChatTab;

    #[cfg(target_os = "macos")]
    #[gpui::test]
    fn workspace_editable_annotation_round_trip_preserves_revisions_and_missing_original(
        cx: &mut gpui::TestAppContext,
    ) {
        use crate::annotate::{Annotated, Annotations, EditableAnnotation, MarkColor};
        use std::sync::Arc;

        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, _, _| {
                let mut source = std::io::Cursor::new(Vec::new());
                image::DynamicImage::new_rgb8(64, 64)
                    .write_to(&mut source, image::ImageFormat::Png)
                    .unwrap();
                let original = Arc::new(gpui::Image::from_bytes(
                    gpui::ImageFormat::Png,
                    source.into_inner(),
                ));
                let mut document = Annotations::default();
                document
                    .add_stroke(vec![(8.0, 8.0), (40.0, 24.0)], 4.0, MarkColor::Red)
                    .unwrap();
                let first_png = crate::annotate::flatten(&original.bytes, &document, 1.0).unwrap();
                let attachment = Annotated {
                    name: "review-annotated.png".into(),
                    png: first_png.clone(),
                    notes: None,
                    editable: Some(EditableAnnotation {
                        original_name: "review.png".into(),
                        original: original.clone(),
                        document: document.clone(),
                    }),
                }
                .into_staged();
                let id = attachment.id.clone();
                let draft = CanvasDraft {
                    input: Some(CanvasInput {
                        text: "Keep my unsent prompt".into(),
                        stage: vec![attachment],
                    }),
                    ..Default::default()
                };
                let first = shell.save_canvas_draft(&draft);
                let first: SavedCanvasDraft =
                    serde_json::from_str(&serde_json::to_string(&first).unwrap()).unwrap();
                let mut restored = shell.restored_canvas_draft(&first);
                let input = restored.input.as_mut().unwrap();
                assert_eq!(input.text, "Keep my unsent prompt");
                let attachment = &mut input.stage[0];
                assert_eq!(attachment.id, id);
                assert_eq!(attachment.bytes(), first_png);
                let editable = attachment.editable.as_mut().unwrap();
                assert_eq!(editable.original.bytes, original.bytes);
                assert_eq!(editable.document, document);
                let comment = editable
                    .document
                    .add_comment((50.0, 50.0), MarkColor::Blue)
                    .unwrap();
                editable.document.commit_text(comment, "Move this button");
                let second_png =
                    crate::annotate::flatten(&editable.original.bytes, &editable.document, 1.0)
                        .unwrap();
                attachment.annotations =
                    crate::annotate::prompt_block(&attachment.name, &editable.document)
                        .map(Into::into);
                attachment.image = Some(Arc::new(gpui::Image::from_bytes(
                    gpui::ImageFormat::Png,
                    second_png.clone(),
                )));
                let second = shell.save_canvas_draft(&restored);
                assert_ne!(
                    first.attachments[0].cache_key,
                    second.attachments[0].cache_key
                );
                assert_eq!(
                    first.attachments[0]
                        .editable
                        .as_ref()
                        .unwrap()
                        .original_cache_key,
                    second.attachments[0]
                        .editable
                        .as_ref()
                        .unwrap()
                        .original_cache_key
                );
                assert_eq!(
                    shell.restored_canvas_draft(&first).input.unwrap().stage[0].bytes(),
                    first_png
                );
                let second_input = shell.restored_canvas_draft(&second).input.unwrap();
                assert_eq!(second_input.stage[0].id, id);
                assert_eq!(second_input.stage[0].bytes(), second_png);
                assert_eq!(
                    second_input.stage[0]
                        .annotations
                        .as_deref()
                        .unwrap()
                        .matches("Move this button")
                        .count(),
                    1
                );

                // A legacy draft can contain flattened marks and their prompt
                // notes without the new original/document field. Preserve the
                // notes and image, but do not reopen them as a fresh document.
                let mut legacy = second.clone();
                legacy.attachments[0].editable = None;
                let legacy_draft = shell.restored_canvas_draft(&legacy);
                let legacy_attachment = &legacy_draft.input.as_ref().unwrap().stage[0];
                assert_eq!(legacy_attachment.bytes(), second_png);
                assert!(legacy_attachment.editing_unavailable());
                assert_eq!(
                    shell.save_canvas_draft(&legacy_draft).attachments[0].annotations,
                    legacy.attachments[0].annotations
                );

                let reference = second.attachments[0].editable.as_ref().unwrap();
                std::fs::remove_file(
                    shell
                        .data_dir
                        .join(DRAFT_CACHE)
                        .join("annotation-originals")
                        .join(&reference.original_cache_key),
                )
                .unwrap();
                let missing = shell.restored_canvas_draft(&second);
                let attachment = &missing.input.as_ref().unwrap().stage[0];
                assert_eq!(attachment.bytes(), second_png);
                assert!(
                    attachment.unavailable.is_none(),
                    "the flattened attachment can still be sent"
                );
                assert!(attachment.editable.is_none());
                assert_eq!(attachment.unavailable_editable.as_ref(), Some(reference));
                let preview = crate::attachments::PreviewImage::new(
                    attachment.name.clone(),
                    attachment.image.clone().unwrap(),
                )
                .with_editable_state(
                    attachment.editable.clone(),
                    attachment.editing_unavailable(),
                );
                assert!(
                    preview.edit_unavailable(),
                    "missing originals must never reopen flattened pixels as an editable document"
                );
                assert_eq!(
                    shell.save_canvas_draft(&missing).attachments[0]
                        .editable
                        .as_ref(),
                    Some(reference)
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn window_chat_drafts_round_trip_active_parked_bytes_and_appshots(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, _, cx| {
                shell.chat_tabs = vec![ChatTab {
                    id: "window-session".into(),
                    ..Default::default()
                }];
                // The navigation fixture seeds its own layout containing
                // "current". This test owns exactly the session below.
                shell.workspace_panels.layouts.clear();
                let mut layout = WorkspaceLayout::default();
                layout.panels[0].tabs = vec![
                    PanelTab::Chat("current".into()),
                    PanelTab::Chat("peer".into()),
                ];
                shell
                    .workspace_panels
                    .layouts
                    .insert("window-session".into(), layout);
                let shot = crate::appshots::tests::shot();
                shell.composer.update(cx, |composer, cx| {
                    composer.current_key = "current".into();
                    composer.restore_saved_window_draft(
                        "current".into(),
                        CanvasInput {
                            text: "Active draft survives".into(),
                            stage: vec![crate::attachments::StagedAttachment {
                                #[cfg(target_os = "macos")]
                                editable: None,
                                #[cfg(target_os = "macos")]
                                unavailable_editable: None,
                                unavailable: None,
                                annotations: None,
                                id: "window-draft-file".into(),
                                name: "notes.txt".into(),
                                image: None,
                                file: Some(std::sync::Arc::from(&b"retained attachment bytes"[..])),
                            }],
                        },
                        vec![shot.clone()],
                        cx,
                    );
                    composer.restore_saved_window_draft(
                        "peer".into(),
                        CanvasInput {
                            text: "Parked draft survives".into(),
                            ..Default::default()
                        },
                        Vec::new(),
                        cx,
                    );
                    composer.restore_saved_window_draft(
                        "unowned".into(),
                        CanvasInput {
                            text: "This other window owns me".into(),
                            ..Default::default()
                        },
                        Vec::new(),
                        cx,
                    );
                });
                let saved = shell.saved_window_chat_drafts(cx);
                assert_eq!(saved.len(), 2);
                assert!(!saved.contains_key("unowned"));
                let json = serde_json::to_string(&saved).unwrap();
                assert!(!json.contains("retained attachment bytes"));
                let saved: HashMap<String, SavedWindowChatDraft> =
                    serde_json::from_str(&json).unwrap();
                shell.composer.update(cx, |composer, cx| {
                    composer.remove_window_draft("current", cx);
                    composer.remove_window_draft("peer", cx);
                });
                shell.restore_window_chat_drafts(&saved, cx);
                shell.composer.read_with(cx, |composer, cx| {
                    let (active, appshots) = composer.saved_window_draft("current", cx);
                    assert_eq!(active.text, "Active draft survives");
                    assert_eq!(active.stage[0].bytes(), b"retained attachment bytes");
                    assert_eq!(appshots[0].id, shot.id);
                    assert_eq!(appshots[0].accessibility, shot.accessibility);
                    assert_eq!(
                        appshots[0].screenshot_dimensions,
                        shot.screenshot_dimensions
                    );
                    assert_eq!(appshots[0].captured_at, shot.captured_at);
                    assert_eq!(
                        composer.saved_window_draft("peer", cx).0.text,
                        "Parked draft survives"
                    );
                });
                // Removing a moved conversation from this window's layout also
                // removes its saved draft record even before memory is reclaimed.
                shell
                    .workspace_panels
                    .layouts
                    .get_mut("window-session")
                    .unwrap()
                    .panels[0]
                    .tabs
                    .remove(0);
                assert!(!shell.saved_window_chat_drafts(cx).contains_key("current"));
                let key = &saved["current"].input.attachments[0].cache_key;
                std::fs::remove_file(shell.data_dir.join(DRAFT_CACHE).join(key)).unwrap();
                shell.restore_window_chat_drafts(&saved, cx);
                assert!(
                    shell
                        .sidebar_notice
                        .as_deref()
                        .unwrap()
                        .contains("Reattach")
                );
                let restored = shell.composer.read(cx).saved_window_draft("current", cx).0;
                assert_eq!(restored.stage.len(), 1);
                assert_eq!(restored.stage[0].unavailable.as_ref(), Some(&saved["current"].input.attachments[0]));
                assert_eq!(restored.text, "Active draft survives");
            })
            .unwrap();
    }

    #[gpui::test]
    fn workspace_session_panels_round_trip_tabs_drafts_attachments_and_pending_tools(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window
            .update(cx, |shell, _, cx| {
                shell.chat_tabs = vec![ChatTab {
                    id: "workspace-a".into(),
                    ..Default::default()
                }];
                let draft = CanvasDraft {
                    harness: Some(harness_proto::HarnessId::Mock),
                    model: Some("test-model".into()),
                    target: Some(CanvasTarget {
                        space: Some("a".into()),
                        ..Default::default()
                    }),
                    input: Some(CanvasInput {
                        text: "An unsent prompt survives the next launch".into(),
                        stage: vec![crate::attachments::StagedAttachment {
                            #[cfg(target_os = "macos")]
                            editable: None,
                            #[cfg(target_os = "macos")]
                            unavailable_editable: None,
                            unavailable: None,
                            annotations: None,
                            id: "../imported attachment".into(),
                            name: "notes.txt".into(),
                            image: None,
                            file: Some(std::sync::Arc::from(&b"draft attachment bytes"[..])),
                        }],
                    }),
                    ..Default::default()
                };
                let saved_draft = shell.save_canvas_draft(&draft);
                assert!(uuid::Uuid::parse_str(&saved_draft.attachments[0].cache_key).is_ok());
                let cache_file = shell
                    .data_dir
                    .join(DRAFT_CACHE)
                    .join(&saved_draft.attachments[0].cache_key);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt as _;
                    assert_eq!(
                        std::fs::metadata(shell.data_dir.join(DRAFT_CACHE))
                            .unwrap()
                            .permissions()
                            .mode()
                            & 0o777,
                        0o700
                    );
                    assert_eq!(
                        std::fs::metadata(&cache_file).unwrap().permissions().mode() & 0o777,
                        0o600
                    );
                }
                let saved = SavedWorkspacePanels {
                    vertical: true,
                    focused: 7,
                    expanded: Some(7),
                    panels: vec![
                        SavedWorkspacePanel {
                            new_panel_target: None,
                            id: 3,
                            active: 1,
                            share: 0.4,
                            tabs: vec![
                                SavedPanelTab::Chat {
                                    id: "current".into(),
                                },
                                SavedPanelTab::Chat { id: "peer".into() },
                            ],
                        },
                        SavedWorkspacePanel {
                            new_panel_target: None,
                            id: 7,
                            active: 0,
                            share: 0.6,
                            tabs: vec![
                                SavedPanelTab::Draft {
                                    draft: saved_draft.clone(),
                                },
                                SavedPanelTab::New {
                                    draft: SavedCanvasDraft {
                                        model: Some("blank-one-model".into()),
                                        ..Default::default()
                                    },
                                },
                                SavedPanelTab::New {
                                    draft: SavedCanvasDraft {
                                        model: Some("blank-two-model".into()),
                                        ..Default::default()
                                    },
                                },
                                SavedPanelTab::Browser {
                                    owner: "current".into(),
                                    url: Some("https://example.test/docs".into()),
                                },
                                SavedPanelTab::Files {
                                    target_device_id: None,
                                    owner: "current".into(),
                                },
                                SavedPanelTab::Terminal {
                                    target_device_id: None,
                                    owner: "current".into(),
                                },
                            ],
                        },
                    ],
                };
                let json = serde_json::to_string(&saved).unwrap();
                assert!(!json.contains("draft attachment bytes"));
                let saved: SavedWorkspacePanels = serde_json::from_str(&json).unwrap();
                shell.workspace_panels = Default::default();
                shell.restore_workspace_panels("workspace-a", &saved, cx);
                let layout = &shell.workspace_panels.layouts["workspace-a"];
                assert_eq!(layout.axis, SplitAxis::Vertical);
                assert_eq!(layout.focused, 7);
                assert_eq!(layout.expanded, Some(7));
                assert_eq!(layout.panels.len(), 2);
                assert_eq!(
                    layout.panels[0].selected(),
                    Some(&PanelTab::Chat("peer".into()))
                );
                assert_eq!(layout.panels[1].tabs.len(), 6);
                assert!(matches!(layout.panels[1].tabs[1], PanelTab::New(_)));
                assert!(matches!(layout.panels[1].tabs[2], PanelTab::New(_)));
                assert_ne!(layout.panels[1].tabs[1], layout.panels[1].tabs[2]);
                let restored = shell.chat_tabs[0].draft.as_ref().unwrap();
                assert_eq!(restored.model.as_deref(), Some("test-model"));
                let input = restored.input.as_ref().unwrap();
                assert_eq!(input.text, draft.input.as_ref().unwrap().text);
                assert_eq!(input.stage[0].bytes(), b"draft attachment bytes");
                assert_eq!(shell.workspace_panels.pending_tools["workspace-a"].len(), 3);
                assert_eq!(
                    shell.saved_workspace_panels("workspace-a", cx),
                    Some(saved.clone())
                );
                std::fs::remove_file(cache_file).unwrap();
                shell.restore_workspace_panels("workspace-a", &saved, cx);
                let restored = shell.chat_tabs[0]
                    .draft
                    .as_ref()
                    .unwrap()
                    .input
                    .as_ref()
                    .unwrap();
                assert_eq!(restored.text, "An unsent prompt survives the next launch");
                assert_eq!(restored.stage.len(), 1);
                assert_eq!(restored.stage[0].unavailable.as_ref(), Some(&saved_draft.attachments[0]));
                assert_eq!(shell.saved_workspace_panels("workspace-a", cx), Some(saved.clone()));
                assert!(
                    shell
                        .sidebar_notice
                        .as_deref()
                        .unwrap()
                        .contains("Reattach")
                );
                let mut blank_focused = saved;
                blank_focused.panels[1].active = 1;
                shell.restore_workspace_panels("workspace-a", &blank_focused, cx);
                assert_eq!(
                    shell.chat_tabs[0].draft.as_ref().unwrap().model.as_deref(),
                    Some("blank-one-model"),
                    "a focused blank tab restores its own picks rather than the session's previous draft"
                );
            })
            .unwrap();
    }
    #[gpui::test]
    fn workspace_restore_keeps_unavailable_and_archived_slots_through_sync(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, window) = chat_tabs::navigation_tests::fixture(cx, false, None);
        window.update(cx, |shell, _, cx| {
            shell.chat_tabs = vec![ChatTab {
                id: "pending-workspace".into(),
                selected: Some("awaiting-sync".into()),
                ..Default::default()
            }];
            shell.state.update(cx, |state, cx| {
                state.chats_synced = true;
                state.chats.iter_mut().find(|chat| chat.id == "current").unwrap().archived = true;
                state.select_chat(Some("awaiting-sync".into()), cx);
            });
            let saved = SavedWorkspacePanels {
                focused: 0,
                panels: vec![SavedWorkspacePanel {
                    new_panel_target: None,
                    id: 0, active: 1, share: 1.0,
                    tabs: vec![SavedPanelTab::Chat { id: "current".into() },
                        SavedPanelTab::Chat { id: "awaiting-sync".into() }],
                }],
                ..Default::default()
            };
            shell.restore_workspace_panels("pending-workspace", &saved, cx);
            shell.sync_panel_workspace(cx);
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.panels[0].tabs, vec![PanelTab::Chat("current".into()), PanelTab::Chat("awaiting-sync".into())]);
            assert_eq!(layout.panels[0].active, 1);
            assert_eq!(shell.saved_workspace_panels("pending-workspace", cx), Some(saved));
        }).unwrap();
    }

}
