//! Per-device New Project starting folders and the Settings → Files controls.

use std::collections::HashMap;

use gpui::{
    AnyElement, Context, Entity, Focusable, SharedString, Subscription, Task, Window, div,
    prelude::*, px,
};
use harness_proto::{Device, FolderListing, Space};
use harness_rpc::methods;
use serde::{Deserialize, Serialize};

use super::{SavePolicy, widgets};
use crate::composer::{ComposerInput, ComposerInputEvent};
use crate::{
    icons,
    popover::{self, Loadable},
    state::AppState,
    theme::Theme,
};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ProjectFolderPreference {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub override_path: Option<String>,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub parent_counts: HashMap<String, u64>,
}

/// Work with the host device's path syntax, not the viewer's OS.
pub fn project_parent(path: &str) -> Option<String> {
    let path = path.replace('\\', "/");
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() || (trimmed.len() == 2 && trimmed.ends_with(':')) {
        return None;
    }
    let at = trimmed.rfind('/')?;
    if at == 0 {
        Some("/".into())
    } else if at == 2 && trimmed.as_bytes()[1] == b':' {
        Some(trimmed[..=at].into())
    } else {
        Some(trimmed[..at].into())
    }
}

pub fn valid_starting_folder(path: &str) -> bool {
    let path = path.trim();
    !path.contains(['\n', '\r', '\0'])
        && (path.starts_with('/')
            || path == "~"
            || path.starts_with("~/")
            || path.starts_with("~\\")
            || path.starts_with("\\\\")
            || (path.len() >= 3
                && path.as_bytes()[0].is_ascii_alphabetic()
                && path.as_bytes()[1] == b':'
                && matches!(path.as_bytes()[2], b'/' | b'\\')))
}

pub fn resolve_starting_folder(path: &str, home: &str) -> String {
    if path == "~" {
        home.to_string()
    } else if let Some(rest) = path.strip_prefix("~/").or_else(|| path.strip_prefix("~\\")) {
        format!("{}/{rest}", home.trim_end_matches(['/', '\\']))
    } else {
        path.to_string()
    }
}

impl ProjectFolderPreference {
    pub fn record_project(&mut self, path: &str) {
        if let Some(parent) = project_parent(path) {
            let count = self.parent_counts.entry(parent).or_default();
            *count = count.saturating_add(1);
        }
    }

    pub fn starting_folder(&self, device_id: &str, spaces: &[Space]) -> Option<String> {
        if let Some(path) = self
            .override_path
            .as_ref()
            .filter(|path| valid_starting_folder(path))
        {
            return Some(path.trim().to_string());
        }
        // Existing projects seed the default on upgrade. Use max, not sum, so
        // projects already represented in the success history aren't counted twice.
        let mut counts = HashMap::<String, u64>::new();
        for space in spaces.iter().filter(|space| space.device_id == device_id) {
            if let Some(parent) = project_parent(&space.path) {
                *counts.entry(parent).or_default() += 1;
            }
        }
        for (parent, count) in &self.parent_counts {
            if *count > 0 && valid_starting_folder(parent) {
                let value = counts.entry(parent.clone()).or_default();
                *value = (*value).max(*count);
            }
        }
        counts
            .into_iter()
            .max_by(|(a_path, a_count), (b_path, b_count)| {
                a_count.cmp(b_count).then_with(|| b_path.cmp(a_path))
            })
            .map(|(path, _)| path)
    }
}

pub fn starting_folder(device_id: &str, spaces: &[Space], cx: &gpui::App) -> Option<String> {
    super::with_current(cx, |settings| {
        settings
            .project_folders_by_device
            .get(device_id)
            .cloned()
            .unwrap_or_default()
            .starting_folder(device_id, spaces)
    })
}

struct FolderEditor {
    device: Option<Device>,
    search: Entity<ComposerInput>,
    listing: Loadable<FolderListing>,
    home: Option<String>,
    notice: Option<String>,
    active: usize,
    focus_pending: bool,
    scroll: gpui::ScrollHandle,
    load_task: Option<Task<()>>,
    _events: Subscription,
}

pub struct ProjectFoldersSettings {
    state: Entity<AppState>,
    editor: Option<FolderEditor>,
    display_device: Option<String>,
    generation: u64,
    _observe: Subscription,
}

impl ProjectFoldersSettings {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&state, |_, _, cx| cx.notify());
        Self {
            state,
            editor: None,
            display_device: None,
            generation: 0,
            _observe: observe,
        }
    }

    fn edit(&mut self, cx: &mut Context<Self>) {
        let search = cx.new(|cx| {
            ComposerInput::with_context("Search devices…", "PaletteSearch", cx)
                .with_text_metrics(widgets::ROW_TITLE_SIZE, 20.0)
                .with_single_line()
        });
        let events = cx.subscribe(&search, |this: &mut Self, _, event, cx| {
            if matches!(event, ComposerInputEvent::Edited) {
                if let Some(editor) = &mut this.editor {
                    editor.active = 0;
                    editor.scroll.set_offset(gpui::Point::default());
                }
                cx.notify();
            }
        });
        self.generation += 1;
        self.editor = Some(FolderEditor {
            device: None,
            search,
            listing: Loadable::Idle,
            home: None,
            notice: None,
            active: 0,
            focus_pending: true,
            scroll: gpui::ScrollHandle::new(),
            load_task: None,
            _events: events,
        });
        cx.notify();
    }

    fn close(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        self.editor = None;
        cx.notify();
    }

    fn devices(&self, cx: &gpui::App) -> Vec<Device> {
        let Some(editor) = &self.editor else {
            return Vec::new();
        };
        let devices = &self.state.read(cx).devices;
        let names: Vec<_> = devices.iter().map(|d| d.name.as_str()).collect();
        popover::filter_indices(editor.search.read(cx).text(), &names)
            .into_iter()
            .map(|ix| devices[ix].clone())
            .collect()
    }

    fn folders(&self, cx: &gpui::App) -> Vec<harness_proto::FolderEntry> {
        let Some(editor) = &self.editor else {
            return Vec::new();
        };
        let Some(listing) = editor.listing.ready() else {
            return Vec::new();
        };
        let entries = crate::pickers::browser_rows(listing);
        let names: Vec<_> = entries.iter().map(|entry| entry.name.as_str()).collect();
        popover::filter_indices(editor.search.read(cx).text(), &names)
            .into_iter()
            .map(|ix| entries[ix].clone())
            .collect()
    }

    fn pick_device(&mut self, device: Device, cx: &mut Context<Self>) {
        if let Some(editor) = &mut self.editor {
            editor.device = Some(device);
            editor.home = None;
            editor.search.update(cx, |search, cx| {
                search.set_placeholder("Search folders…", cx);
                search.set_text("", cx);
            });
        }
        self.load(None, true, cx);
    }

    fn load(&mut self, path: Option<String>, initial: bool, cx: &mut Context<Self>) {
        let engine = self.state.read(cx).engine().cloned();
        let local = self.state.read(cx).local_device_id.clone();
        let Some(device_id) = self
            .editor
            .as_ref()
            .and_then(|e| e.device.as_ref())
            .map(|d| d.id.clone())
        else {
            return;
        };
        let preferred = initial
            .then(|| starting_folder(&device_id, &self.state.read(cx).spaces, cx))
            .flatten();
        self.generation += 1;
        let generation = self.generation;
        let editor = self.editor.as_mut().unwrap();
        editor.load_task = None;
        editor.listing = Loadable::Loading;
        editor.notice = None;
        editor.active = 0;
        editor.focus_pending = true;
        editor.scroll.set_offset(gpui::Point::default());
        editor
            .search
            .update(cx, |search, cx| search.set_text("", cx));
        let Some(engine) = engine else {
            editor.listing = Loadable::Error("Device is not connected".into());
            cx.notify();
            return;
        };
        editor.load_task = Some(cx.spawn(async move |this, cx| {
            let mut params = serde_json::Map::new();
            if local.as_deref() != Some(device_id.as_str()) {
                params.insert("targetDeviceId".into(), device_id.clone().into());
            }
            if let Some(path) = &path {
                params.insert("path".into(), path.clone().into());
            }
            let mut home = None;
            let mut fallback = false;
            let result = async {
                let value = engine
                    .client()
                    .call(
                        methods::LIST_FOLDERS,
                        serde_json::Value::Object(params.clone()),
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                let listing: FolderListing =
                    serde_json::from_value(value).map_err(|e| e.to_string())?;
                if path.is_none() {
                    home = Some(listing.path.clone());
                }
                if let Some(preferred) = preferred {
                    let target = resolve_starting_folder(&preferred, &listing.path);
                    if target != listing.path {
                        params.insert("path".into(), target.into());
                        let preferred = engine
                            .client()
                            .call(methods::LIST_FOLDERS, serde_json::Value::Object(params))
                            .await
                            .map_err(|e| e.to_string())
                            .and_then(|value| {
                                serde_json::from_value::<FolderListing>(value)
                                    .map_err(|e| e.to_string())
                            });
                        match preferred {
                            Ok(listing) => return Ok(listing),
                            Err(_) => fallback = true,
                        }
                    }
                }
                Ok(listing)
            }
            .await;
            this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                if let Some(editor) = &mut this.editor {
                    if let Some(home) = home {
                        editor.home = Some(home);
                    }
                    editor.listing = match result {
                        Ok(listing) => Loadable::Ready(listing),
                        Err(error) => Loadable::Error(error),
                    };
                    if fallback {
                        editor.notice = Some("Starting folder unavailable; opened Home.".into());
                    }
                    cx.notify();
                }
            })
            .ok();
        }));
        cx.notify();
    }

    fn save(&mut self, cx: &mut Context<Self>) {
        let Some(editor) = &self.editor else { return };
        let (Some(device), Some(listing)) = (&editor.device, editor.listing.ready()) else {
            return;
        };
        let device_id = device.id.clone();
        let path = listing.path.clone();
        super::update(SavePolicy::Immediate, cx, |settings| {
            settings
                .project_folders_by_device
                .entry(device_id.clone())
                .or_default()
                .override_path = Some(path);
        });
        self.display_device = Some(device_id);
        self.close(cx);
        cx.refresh_windows();
    }

    fn automatic(&mut self, cx: &mut Context<Self>) {
        let Some(device_id) = self
            .editor
            .as_ref()
            .and_then(|e| e.device.as_ref())
            .map(|d| d.id.clone())
        else {
            return;
        };
        super::update(SavePolicy::Immediate, cx, |settings| {
            if let Some(pref) = settings.project_folders_by_device.get_mut(&device_id) {
                pref.override_path = None;
            }
        });
        self.display_device = Some(device_id);
        self.close(cx);
        cx.refresh_windows();
    }

    fn back_to_devices(&mut self, cx: &mut Context<Self>) {
        self.generation += 1;
        if let Some(editor) = &mut self.editor {
            editor.load_task = None;
            editor.device = None;
            editor.home = None;
            editor.listing = Loadable::Idle;
            editor.notice = None;
            editor.active = 0;
            editor.focus_pending = true;
            editor.search.update(cx, |search, cx| {
                search.set_placeholder("Search devices…", cx);
                search.set_text("", cx);
            });
        }
        cx.notify();
    }

    fn up(&mut self, cx: &mut Context<Self>) {
        let path = self
            .editor
            .as_ref()
            .and_then(|e| e.listing.ready())
            .and_then(|l| project_parent(&l.path));
        if let Some(path) = path {
            self.load(Some(path), false, cx);
        } else {
            self.back_to_devices(cx);
        }
    }

    fn open_active(&mut self, cx: &mut Context<Self>) {
        let Some(editor) = &self.editor else { return };
        let active = editor.active;
        if editor.device.is_none() {
            if let Some(device) = self.devices(cx).get(active) {
                self.pick_device(device.clone(), cx);
            }
        } else if let Some(entry) = self.folders(cx).get(active) {
            let base = &editor.listing.ready().unwrap().path;
            self.load(
                Some(crate::pickers::child_path(base, &entry.name)),
                false,
                cx,
            );
        }
    }

    fn key(&mut self, event: &gpui::KeyDownEvent, cx: &mut Context<Self>) {
        let key = popover::classify_key(
            &event.keystroke.key,
            event.keystroke.modifiers.platform,
            event.keystroke.modifiers.control,
        );
        match key {
            popover::MenuKey::Escape => self.close(cx),
            popover::MenuKey::Enter => self.open_active(cx),
            popover::MenuKey::ModEnter => self.save(cx),
            popover::MenuKey::Up | popover::MenuKey::Down => {
                let count = if self.editor.as_ref().is_some_and(|e| e.device.is_none()) {
                    self.devices(cx).len()
                } else {
                    self.folders(cx).len()
                };
                if let Some(editor) = &mut self.editor {
                    editor.active = popover::menu_step(
                        Some(editor.active),
                        count,
                        if key == popover::MenuKey::Up { -1 } else { 1 },
                    )
                    .unwrap_or(0);
                    editor.scroll.scroll_to_item(editor.active);
                }
                cx.notify();
            }
            popover::MenuKey::Backspace
                if self
                    .editor
                    .as_ref()
                    .is_some_and(|e| e.search.read(cx).is_empty()) =>
            {
                self.up(cx)
            }
            _ if event.keystroke.key == "left" => self.up(cx),
            _ if event.keystroke.key == "right" => self.open_active(cx),
            _ => return,
        }
        cx.stop_propagation();
    }

    /// An absolute child of FilesSettingsPage, never the app-wide settings host.
    pub fn render_picker(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let theme = Theme::of(cx).for_popup();
        let editor = self.editor.as_mut()?;
        if std::mem::take(&mut editor.focus_pending) {
            editor.search.focus_handle(cx).focus(window, cx);
        }
        let search = editor.search.clone();
        let device = editor.device.clone();
        let listing = editor.listing.ready().cloned();
        let home = editor.home.clone();
        let error = editor.listing.error().map(str::to_string);
        let notice = editor.notice.clone();
        let active = editor.active;
        let scroll = editor.scroll.clone();
        let mut rows = Vec::new();
        if device.is_none() {
            for (ix, device) in self.devices(cx).into_iter().enumerate() {
                let online = self
                    .state
                    .read(cx)
                    .device_online(&device.id, chrono::Utc::now());
                let name = device.name.clone();
                rows.push(
                    popover::menu_row(&theme, ix == active, format!("starting-device-{ix}"))
                        .id(("starting-device", ix))
                        .h(px(36.0))
                        .flex_none()
                        .text_size(crate::typography::ui_rems(widgets::ROW_TITLE_SIZE))
                        .on_click(
                            cx.listener(move |this, _, _, cx| this.pick_device(device.clone(), cx)),
                        )
                        .child(icons::icon(icons::LAPTOP).size(px(16.0)))
                        .child(SharedString::from(name))
                        .child(div().flex_1())
                        .child(div().size(px(5.0)).rounded_full().bg(if online {
                            theme.success
                        } else {
                            theme.text_faint
                        }))
                        .into_any_element(),
                );
            }
        } else {
            for (ix, entry) in self.folders(cx).into_iter().enumerate() {
                let path = crate::pickers::child_path(&listing.as_ref().unwrap().path, &entry.name);
                rows.push(
                    popover::menu_row(&theme, ix == active, format!("starting-folder-{ix}"))
                        .id(("starting-folder", ix))
                        .h(px(36.0))
                        .flex_none()
                        .text_size(crate::typography::ui_rems(widgets::ROW_TITLE_SIZE))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.load(Some(path.clone()), false, cx)
                        }))
                        .child(icons::icon(icons::FOLDER).size(px(16.0)))
                        .child(SharedString::from(entry.name))
                        .into_any_element(),
                );
            }
        }
        let empty = if device.is_none() {
            "No matching devices"
        } else if listing.is_none() {
            "Loading folders…"
        } else {
            "No matching folders"
        };
        let results = div()
            .id("starting-folder-results")
            .max_h(px(200.0))
            .min_h(px(36.0))
            .overflow_y_scroll()
            .track_scroll(&scroll)
            .flex()
            .flex_col()
            .children(rows)
            .when(
                (if device.is_none() {
                    self.devices(cx).len()
                } else {
                    self.folders(cx).len()
                }) == 0,
                |el| {
                    el.child(
                        div()
                            .px(px(10.0))
                            .py(px(12.0))
                            .text_size(crate::typography::ui_rems(widgets::ROW_DESCRIPTION_SIZE))
                            .text_color(theme.text_muted)
                            .child(SharedString::from(
                                error.clone().unwrap_or_else(|| empty.into()),
                            )),
                    )
                },
            );
        let mut crumbs = div()
            .flex()
            .flex_wrap()
            .items_center()
            .gap(px(4.0))
            .px(px(12.0))
            .py(px(8.0))
            .text_size(crate::typography::ui_rems(widgets::ROW_DESCRIPTION_SIZE))
            .child(
                popover::btn_ghost(&theme, "Starting folder", "starting-root")
                    .id("starting-root")
                    .on_click(cx.listener(|this, _, _, cx| this.back_to_devices(cx))),
            );
        if let Some(device) = &device {
            crumbs = crumbs
                .child(SharedString::from("›"))
                .child(SharedString::from(device.name.clone()));
            if let Some(home) = home {
                let target = home.clone();
                crumbs = crumbs.child(SharedString::from("›")).child(
                    popover::btn_ghost(&theme, "Home", "starting-home")
                        .id("starting-home")
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.load(Some(target.clone()), false, cx)
                        })),
                );
                if let Some(listing) = &listing {
                    // Build from host paths (including Windows drives), not viewer paths.
                    let normalized = listing.path.replace('\\', "/");
                    let normalized_home = home.replace('\\', "/");
                    let mut trail = Vec::new();
                    let mut path = normalized.clone();
                    while path != normalized_home {
                        let label = path
                            .rsplit('/')
                            .find(|part| !part.is_empty())
                            .unwrap_or("/")
                            .to_string();
                        trail.push((label, path.clone()));
                        let Some(parent) = project_parent(&path) else {
                            break;
                        };
                        if parent == path {
                            break;
                        }
                        path = parent;
                    }
                    for (ix, (label, path)) in trail.into_iter().rev().enumerate() {
                        crumbs = crumbs.child(SharedString::from("›")).child(
                            popover::btn_ghost(&theme, &label, format!("starting-crumb-{ix}"))
                                .id(("starting-crumb", ix))
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.load(Some(path.clone()), false, cx)
                                })),
                        );
                    }
                }
            }
        }
        let can_save = listing.is_some();
        let card = div()
            .id("starting-folder-picker")
            .w_full()
            .max_w(px(520.0))
            .rounded(px(10.0))
            .border_1()
            .border_color(theme.border)
            .bg(popover::surface_bg(&theme))
            .shadow_lg()
            .overflow_hidden()
            .flex()
            .flex_col()
            .text_color(theme.text)
            .on_key_down(cx.listener(|this, event, _, cx| this.key(event, cx)))
            .child(
                div()
                    .h(px(46.0))
                    .px(px(14.0))
                    .flex()
                    .items_center()
                    .gap(px(10.0))
                    .border_b_1()
                    .border_color(theme.border)
                    .child(
                        icons::icon(icons::PALETTE_SEARCH)
                            .size(px(18.0))
                            .text_color(theme.text_muted),
                    )
                    .child(div().flex_1().min_w_0().child(search))
                    .child(
                        popover::btn_ghost(&theme, "esc", "starting-close")
                            .id("starting-close")
                            .on_click(cx.listener(|this, _, _, cx| this.close(cx))),
                    ),
            )
            .child(crumbs)
            .child(div().px(px(6.0)).pb(px(7.0)).child(results))
            .when_some(notice, |el, notice| {
                el.child(
                    div()
                        .px(px(12.0))
                        .pb(px(8.0))
                        .text_size(crate::typography::ui_rems(widgets::ROW_DESCRIPTION_SIZE))
                        .text_color(theme.text_muted)
                        .child(SharedString::from(notice)),
                )
            })
            .child(
                div()
                    .px(px(12.0))
                    .py(px(10.0))
                    .border_t_1()
                    .border_color(theme.border)
                    .flex()
                    .flex_wrap()
                    .items_center()
                    .gap(px(8.0))
                    .child(popover::key_hint_text(&theme, "↑ ↓", "Navigate"))
                    .child(popover::key_hint_text(&theme, "↵", "Open"))
                    .child(div().flex_1())
                    .when(device.is_some(), |el| {
                        el.child(
                            popover::btn_ghost(&theme, "Use automatic", "starting-automatic")
                                .id("starting-automatic")
                                .on_click(cx.listener(|this, _, _, cx| this.automatic(cx))),
                        )
                    })
                    .child(
                        popover::btn_primary(&theme, "Use this folder")
                            .id("starting-save")
                            .when(!can_save, |el| el.opacity(0.35))
                            .on_click(cx.listener(|this, _, _, cx| this.save(cx))),
                    ),
            );
        Some(
            div()
                .id("starting-folder-overlay")
                .absolute()
                .inset_0()
                .occlude()
                .bg(gpui::black().opacity(0.15))
                .px(px(22.0))
                .pt(px(36.0))
                .flex()
                .items_start()
                .justify_center()
                .on_mouse_down(
                    gpui::MouseButton::Left,
                    cx.listener(|_, _, _, cx| cx.stop_propagation()),
                )
                .on_scroll_wheel(cx.listener(|_, _, _, cx| cx.stop_propagation()))
                .child(card)
                .into_any_element(),
        )
    }
}

impl Render for ProjectFoldersSettings {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let device_id = self
            .display_device
            .clone()
            .or_else(|| self.state.read(cx).local_device_id.clone());
        let preferred = device_id
            .as_deref()
            .and_then(|id| starting_folder(id, &self.state.read(cx).spaces, cx));
        let overridden = super::with_current(cx, |settings| {
            device_id
                .as_ref()
                .and_then(|id| settings.project_folders_by_device.get(id))
                .is_some_and(|pref| pref.override_path.is_some())
        });
        let description = format!(
            "{} · {}",
            if overridden { "Custom" } else { "Automatic" },
            preferred.as_deref().unwrap_or("Home")
        );
        widgets::card_row(&theme, false)
            .child(widgets::row_tile(&theme, icons::FOLDER))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(widgets::row_title(&theme, "New project starting folder"))
                    .child(widgets::meta_line(
                        &theme,
                        vec![
                            div()
                                .truncate()
                                .child(SharedString::from(description))
                                .into_any_element(),
                        ],
                    )),
            )
            .child(
                popover::btn_ghost(&theme, "Edit", "project-folder-edit")
                    .id("project-folder-edit")
                    .on_click(cx.listener(|this, _, _, cx| this.edit(cx))),
            )
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frequency_override_reset_and_persistence() {
        let mut pref = ProjectFolderPreference::default();
        pref.record_project("/projects/one");
        pref.record_project("/projects/two");
        pref.record_project("/other/recent");
        assert_eq!(
            pref.starting_folder("local", &[]).as_deref(),
            Some("/projects")
        );
        pref.override_path = Some("~/work".into());
        let mut restored: ProjectFolderPreference =
            serde_json::from_str(&serde_json::to_string(&pref).unwrap()).unwrap();
        assert_eq!(
            restored.starting_folder("local", &[]).as_deref(),
            Some("~/work")
        );
        restored.override_path = None;
        assert_eq!(
            restored.starting_folder("local", &[]).as_deref(),
            Some("/projects")
        );
        assert_eq!(
            resolve_starting_folder("~/work", "/home/test"),
            "/home/test/work"
        );
        assert_eq!(
            resolve_starting_folder("~\\work", "C:\\Users\\test"),
            "C:\\Users\\test/work"
        );
    }

    #[test]
    fn existing_projects_are_device_scoped_and_not_double_counted() {
        let spaces: Vec<Space> = serde_json::from_value(serde_json::json!([
            {"id":"one", "deviceId":"local", "path":"/projects/one", "createdAt":chrono::Utc::now()},
            {"id":"two", "deviceId":"local", "path":"/projects/two", "createdAt":chrono::Utc::now()},
            {"id":"three", "deviceId":"remote", "path":"/remote/three", "createdAt":chrono::Utc::now()}
        ])).unwrap();
        let mut pref = ProjectFolderPreference::default();
        assert_eq!(
            pref.starting_folder("local", &spaces).as_deref(),
            Some("/projects")
        );
        assert_eq!(
            pref.starting_folder("remote", &spaces).as_deref(),
            Some("/remote")
        );
        assert!(pref.starting_folder("unknown", &spaces).is_none());
        pref.record_project("/projects/one");
        pref.record_project("/projects/two");
        for ix in 0..3 {
            pref.record_project(&format!("/other/{ix}"));
        }
        assert_eq!(
            pref.starting_folder("local", &spaces).as_deref(),
            Some("/other")
        );
    }

    #[gpui::test]
    fn settings_picker_browses_host_folders_and_persists_only_on_confirm(
        cx: &mut gpui::TestAppContext,
    ) {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let _guard = runtime.enter();
        let (out, mut requests) = tokio::sync::mpsc::channel(16);
        let (replies, inbound) = tokio::sync::mpsc::channel(16);
        let engine =
            crate::state::EngineHandle::from_test_client(harness_rpc::RpcClient::new(out, inbound));
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| super::super::init(super::super::UiSettings::default(), dir.path(), cx));
        let device: Device = serde_json::from_value(serde_json::json!({
            "id":"remote", "name":"Server", "platform":"linux", "lastSeenAt":null
        }))
        .unwrap();
        let page = cx.new(|cx| {
            let state = cx.new(|_| {
                let mut state = AppState::new();
                state.local_device_id = Some("local".into());
                state.devices = vec![device.clone()];
                state.set_test_engine(engine);
                state
            });
            ProjectFoldersSettings::new(state, cx)
        });
        let reply = |id: serde_json::Value, value: serde_json::Value| {
            runtime.block_on(async {
                replies
                    .send(serde_json::json!({"id":id,"ok":value}).to_string())
                    .await
                    .unwrap();
                tokio::time::timeout(std::time::Duration::from_secs(1), async {
                    while replies.capacity() < replies.max_capacity() {
                        tokio::task::yield_now().await;
                    }
                })
                .await
                .unwrap();
            });
        };
        page.update(cx, |page, cx| {
            page.edit(cx);
            assert!(page.editor.as_ref().unwrap().device.is_none());
            page.save(cx); // A device must be selected and its listing loaded first.
            assert!(page.editor.is_some());
            page.open_active(cx);
        });
        cx.run_until_parked();
        let home: serde_json::Value = serde_json::from_str(&requests.try_recv().unwrap()).unwrap();
        assert_eq!(home["method"], methods::LIST_FOLDERS);
        assert_eq!(home["params"]["targetDeviceId"], "remote");
        assert!(home["params"].get("path").is_none());
        reply(
            home["id"].clone(),
            serde_json::json!({"path":"/home/test", "entries":[
            {"name":"Work","isDir":true,"isRepo":false},
            {"name":"notes.txt","isDir":false,"isRepo":false}
        ],"truncated":false}),
        );
        cx.run_until_parked();
        page.update(cx, |page, cx| {
            assert_eq!(page.folders(cx).len(), 1); // Files are never folder choices.
            page.editor
                .as_ref()
                .unwrap()
                .search
                .update(cx, |input, cx| input.set_text("wor", cx));
            assert_eq!(page.folders(cx)[0].name, "Work");
            page.open_active(cx);
        });
        cx.run_until_parked();
        let work: serde_json::Value = serde_json::from_str(&requests.try_recv().unwrap()).unwrap();
        assert_eq!(work["params"]["path"], "/home/test/Work");
        assert_eq!(work["params"]["targetDeviceId"], "remote");
        reply(
            work["id"].clone(),
            serde_json::json!({"path":"/home/test/Work", "entries":[],"truncated":false}),
        );
        cx.run_until_parked();
        page.update(cx, |page, cx| {
            assert!(
                super::super::UiSettings::load(dir.path())
                    .project_folders_by_device
                    .is_empty()
            );
            page.save(cx);
            assert!(page.editor.is_none());
            assert_eq!(
                super::super::UiSettings::load(dir.path()).project_folders_by_device["remote"]
                    .override_path
                    .as_deref(),
                Some("/home/test/Work")
            );
            page.edit(cx);
            page.pick_device(device.clone(), cx);
        });
        cx.run_until_parked();
        let canceled: serde_json::Value =
            serde_json::from_str(&requests.try_recv().unwrap()).unwrap();
        page.update(cx, |page, cx| page.close(cx));
        reply(
            canceled["id"].clone(),
            serde_json::json!({"path":"/home/test", "entries":[],"truncated":false}),
        );
        cx.run_until_parked();
        page.update(cx, |page, cx| {
            assert!(page.editor.is_none());
            assert_eq!(
                super::super::UiSettings::load(dir.path()).project_folders_by_device["remote"]
                    .override_path
                    .as_deref(),
                Some("/home/test/Work")
            );
            page.edit(cx);
            page.editor.as_mut().unwrap().device = Some(device.clone());
            page.automatic(cx);
            let restored = super::super::UiSettings::load(dir.path());
            assert!(
                restored.project_folders_by_device["remote"]
                    .override_path
                    .is_none()
            );
            assert!(!restored.project_folders_by_device.contains_key("local"));
        });
    }

    #[test]
    fn host_paths_and_validation() {
        assert_eq!(
            project_parent("/projects/repo/").as_deref(),
            Some("/projects")
        );
        assert_eq!(project_parent("C:\\work\\repo").as_deref(), Some("C:/work"));
        assert_eq!(project_parent("C:/repo").as_deref(), Some("C:/"));
        assert_eq!(project_parent("C:/"), None);
        assert_eq!(project_parent("/"), None);
        for path in ["/projects", "~/work", "~", "C:\\work", "\\\\server\\share"] {
            assert!(valid_starting_folder(path));
        }
        for path in ["", "relative", "~other/work", "C:relative", "/bad\npath"] {
            assert!(!valid_starting_folder(path));
        }
        let mut pref = ProjectFolderPreference::default();
        pref.record_project("/");
        assert!(pref.starting_folder("local", &[]).is_none());
    }
}
