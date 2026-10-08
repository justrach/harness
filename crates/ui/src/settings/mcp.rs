//! Settings → MCP: the MCP servers graff connects to on the selected device.
//!
//! These are graff's own config files (`~/.codegraff/mcp.json` for every
//! project, a project's `.mcp.json` for that project), edited on the device
//! that runs graff through `ListGraffMcpServers` and friends
//! (`harness_engine::graff_mcp`), so a terminal graff and Harness's graff chats
//! share one configuration. The page-header device switcher retargets the
//! calls like the Agents page; the project picker lists that device's spaces.
//!
//! Servers graff imports from other tools' configs are listed too (graff
//! reports them): they can be switched off here, and are edited in the tool
//! that defines them.
//!
//! Env and header values never come back from the device. The edit dialog
//! lists one `NAME` per line for each stored value (kept as is), and
//! `NAME=value` sets one.

use gpui::{AnyElement, App, Context, Entity, SharedString, Task, Window, div, prelude::*, px};

use harness_engine::graff_mcp::{McpListing, McpScope, McpServerView};
use harness_rpc::methods;

use crate::composer::ComposerInput;
use crate::icons::{self, icon};
use crate::popover::{self, Loadable};
use crate::settings::widgets;
use crate::state::AppState;
use crate::theme::Theme;

pub struct McpPage {
    state: Entity<AppState>,
    scroll: widgets::PageScroll,
    /// Which device's graff is shown; `None` = this device.
    target_device: Option<String>,
    device_menu_open: bool,
    device_menu_pressed_open: bool,
    /// The project (a space path on the target device) whose `.mcp.json` is
    /// listed under the global servers.
    project: Option<String>,
    project_menu_open: bool,
    project_menu_pressed_open: bool,
    listing: Loadable<McpListing>,
    task: Option<Task<()>>,
    busy: bool,
    error: Option<String>,
    dialog: Option<ServerDialog>,
    confirm_remove: Option<(McpScope, String)>,
}

struct ServerDialog {
    /// Set when editing: the server's scope and name before the edit.
    editing: Option<(McpScope, String)>,
    scope: McpScope,
    /// Connects to a URL instead of running a command.
    remote: bool,
    name: Entity<ComposerInput>,
    /// The command line, or the URL.
    target: Entity<ComposerInput>,
    /// `NAME=value` lines: env vars for a command, headers for a URL.
    secrets: Entity<ComposerInput>,
    error: Option<String>,
}

/// Split a command line into words: spaces separate, quotes group, and a
/// backslash escapes the next character outside single quotes.
pub(crate) fn split_command(line: &str) -> Result<Vec<String>, String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('\''), c) => word.push(c),
            (_, '\\') => {
                word.push(chars.next().ok_or("the command ends with a lone \\")?);
                in_word = true;
            }
            (Some(_), c) => word.push(c),
            (None, '"' | '\'') => {
                quote = Some(c);
                in_word = true;
            }
            (None, c) if c.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut word));
                    in_word = false;
                }
            }
            (None, c) => {
                word.push(c);
                in_word = true;
            }
        }
    }
    if quote.is_some() {
        return Err("a quote in the command isn't closed".into());
    }
    if in_word {
        words.push(word);
    }
    Ok(words)
}

/// The inverse of [`split_command`], for showing a stored command to edit.
pub(crate) fn join_command(words: &[String]) -> String {
    words
        .iter()
        .map(|w| {
            if !w.is_empty() && !w.contains(|c: char| c.is_whitespace() || "\"'\\".contains(c)) {
                w.clone()
            } else {
                format!("'{}'", w.replace('\'', r"'\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// `NAME=value` sets a value; a bare `NAME` keeps the stored one (JSON null).
pub(crate) fn parse_secrets(
    text: &str,
) -> Result<serde_json::Map<String, serde_json::Value>, String> {
    let mut out = serde_json::Map::new();
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let (key, value) = match line.split_once('=') {
            Some((key, value)) => (key.trim(), serde_json::Value::from(value)),
            None => (line, serde_json::Value::Null),
        };
        if key.is_empty() || key.contains(char::is_whitespace) {
            return Err(format!("{line:?}: write NAME=value, one per line"));
        }
        out.insert(key.to_string(), value);
    }
    Ok(out)
}

impl McpPage {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let mut page = Self {
            state,
            scroll: widgets::PageScroll::default(),
            target_device: None,
            device_menu_open: false,
            device_menu_pressed_open: false,
            project: None,
            project_menu_open: false,
            project_menu_pressed_open: false,
            listing: Loadable::Idle,
            task: None,
            busy: false,
            error: None,
            dialog: None,
            confirm_remove: None,
        };
        page.call(methods::LIST_GRAFF_MCP_SERVERS, serde_json::json!({}), cx);
        page
    }

    /// Params for the target device and the chosen project.
    fn params(&self, mut value: serde_json::Value) -> serde_json::Value {
        if let Some(object) = value.as_object_mut() {
            if let Some(target) = &self.target_device {
                object.insert("targetDeviceId".into(), target.clone().into());
            }
            if let Some(project) = &self.project {
                object.insert("cwd".into(), project.clone().into());
            }
        }
        value
    }

    /// Every method answers with the fresh listing.
    fn call(&mut self, method: &'static str, params: serde_json::Value, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let params = self.params(params);
        let listing_call = method == methods::LIST_GRAFF_MCP_SERVERS;
        if listing_call && !matches!(self.listing, Loadable::Ready(_)) {
            self.listing = Loadable::Loading;
        }
        self.busy = true;
        self.task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(method, params).await;
            this.update(cx, |page, cx| {
                page.busy = false;
                match result.map_err(|e| e.to_string()).and_then(|v| {
                    serde_json::from_value::<McpListing>(v).map_err(|e| e.to_string())
                }) {
                    Ok(listing) => {
                        page.listing = Loadable::Ready(listing);
                        page.error = None;
                        if !listing_call {
                            page.dialog = None;
                        }
                    }
                    Err(err) => {
                        let err = if err.contains("unknown method") {
                            "Update Harness on this device to edit graff's MCP servers here.".into()
                        } else {
                            err
                        };
                        if listing_call && !matches!(page.listing, Loadable::Ready(_)) {
                            page.listing = Loadable::Error(err);
                        } else if let Some(dialog) = page.dialog.as_mut() {
                            dialog.error = Some(err);
                        } else {
                            page.error = Some(err);
                        }
                    }
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        self.listing = Loadable::Idle;
        self.dialog = None;
        self.confirm_remove = None;
        self.error = None;
        self.call(methods::LIST_GRAFF_MCP_SERVERS, serde_json::json!({}), cx);
    }

    fn set_target_device(&mut self, target: Option<String>, cx: &mut Context<Self>) {
        self.device_menu_open = false;
        if self.target_device != target {
            self.target_device = target;
            // A project path belongs to one device.
            self.project = None;
            self.reload(cx);
        }
        cx.notify();
    }

    fn set_project(&mut self, project: Option<String>, cx: &mut Context<Self>) {
        self.project_menu_open = false;
        if self.project != project {
            self.project = project;
            self.reload(cx);
        }
        cx.notify();
    }

    fn effective_device(&self, cx: &App) -> Option<String> {
        self.target_device
            .clone()
            .or_else(|| self.state.read(cx).local_device_id.clone())
    }

    /// The target device's projects: (path, name).
    fn projects(&self, cx: &App) -> Vec<(String, String)> {
        let device = self.effective_device(cx);
        let mut projects: Vec<(String, String)> = self
            .state
            .read(cx)
            .spaces
            .iter()
            .filter(|s| Some(s.device_id.as_str()) == device.as_deref())
            .map(|s| (s.path.clone(), s.display_name().to_string()))
            .collect();
        projects.sort_by(|a, b| a.1.to_lowercase().cmp(&b.1.to_lowercase()));
        projects.dedup_by(|a, b| a.0 == b.0);
        projects
    }

    fn open_dialog(&mut self, server: Option<&McpServerView>, cx: &mut Context<Self>) {
        let input = |placeholder: &'static str, text: String, cx: &mut Context<Self>| {
            let input = cx.new(|cx| ComposerInput::new(placeholder, cx));
            input.update(cx, |input, cx| input.set_text(text, cx));
            input
        };
        let (editing, scope, remote, name, target, secrets) = match server {
            Some(s) => {
                let target = match &s.url {
                    Some(url) => url.clone(),
                    None => {
                        let mut words = vec![s.command.clone().unwrap_or_default()];
                        words.extend(s.args.iter().cloned());
                        join_command(&words)
                    }
                };
                let keys = if s.url.is_some() {
                    &s.header_keys
                } else {
                    &s.env_keys
                };
                (
                    Some((s.scope, s.name.clone())),
                    s.scope,
                    s.url.is_some(),
                    s.name.clone(),
                    target,
                    keys.join("\n"),
                )
            }
            None => (
                None,
                if self.project.is_some() {
                    McpScope::Project
                } else {
                    McpScope::Global
                },
                false,
                String::new(),
                String::new(),
                String::new(),
            ),
        };
        self.dialog = Some(ServerDialog {
            editing,
            scope,
            remote,
            name: input("Name, e.g. files", name, cx),
            target: input("Command or URL", target, cx),
            secrets: input("NAME=value, one per line", secrets, cx),
            error: None,
        });
        cx.notify();
    }

    /// The `SetGraffMcpServer` params the open dialog describes.
    fn dialog_request(&self, cx: &App) -> Result<serde_json::Value, String> {
        let dialog = self.dialog.as_ref().ok_or("no dialog")?;
        let name = dialog.name.read(cx).text().trim().to_string();
        let target = dialog.target.read(cx).text().trim().to_string();
        let secrets = parse_secrets(dialog.secrets.read(cx).text())?;
        let mut server = serde_json::json!({ "name": name });
        if let Some((_, previous)) = &dialog.editing {
            server["previousName"] = previous.clone().into();
        }
        if dialog.remote {
            server["url"] = target.into();
            server["headers"] = secrets.into();
        } else {
            let mut words = split_command(&target)?;
            if words.is_empty() {
                return Err("enter the command that starts the server".into());
            }
            server["command"] = words.remove(0).into();
            server["args"] = words.into();
            server["env"] = secrets.into();
        }
        Ok(serde_json::json!({ "scope": dialog.scope, "server": server }))
    }

    fn submit_dialog(&mut self, cx: &mut Context<Self>) {
        match self.dialog_request(cx) {
            Ok(params) => self.call(methods::SET_GRAFF_MCP_SERVER, params, cx),
            Err(err) => {
                if let Some(dialog) = self.dialog.as_mut() {
                    dialog.error = Some(err);
                }
                cx.notify();
            }
        }
    }

    fn render_device_switcher(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let (mut devices, local_id) = {
            let s = self.state.read(cx);
            (s.devices.clone(), s.local_device_id.clone())
        };
        devices.retain(|d| !matches!(d.platform.as_str(), "ios" | "android" | "web"));
        devices.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        let effective = self.effective_device(cx);
        let label: SharedString = devices
            .iter()
            .find(|d| Some(d.id.as_str()) == effective.as_deref())
            .map(|d| d.name.clone().into())
            .unwrap_or_else(|| "This device".into());
        let open = self.device_menu_open;
        let mut trigger = menu_trigger(theme, "mcp-device-switcher", icons::LAPTOP, label, open)
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(|this, _, _, _| this.device_menu_pressed_open = this.device_menu_open),
            )
            .on_click(cx.listener(|this, _, _, cx| {
                let pressed_open = std::mem::take(&mut this.device_menu_pressed_open);
                this.device_menu_open = !pressed_open && !this.device_menu_open;
                cx.notify();
            }));
        if open {
            let theme = &theme.for_popup();
            let menu = popover::popover_card(theme)
                .w(px(220.0))
                .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                    this.device_menu_open = false;
                    cx.notify();
                }))
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(popover::menu_heading(theme, "Devices"))
                .children(devices.into_iter().enumerate().map(|(ix, d)| {
                    let is_local = local_id.as_deref() == Some(d.id.as_str());
                    let active = Some(d.id.as_str()) == effective.as_deref();
                    let id = d.id.clone();
                    popover::menu_row(theme, active, format!("mcp-device-row-{ix}"))
                        .id(("mcp-device-row", ix))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.set_target_device((!is_local).then(|| id.clone()), cx);
                        }))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .child(SharedString::from(d.name.clone())),
                        )
                        .when(is_local, |el| {
                            el.child(
                                div()
                                    .flex_none()
                                    .text_size(crate::typography::ui_rems(10.5))
                                    .text_color(theme.text_muted)
                                    .child(SharedString::from("You")),
                            )
                        })
                }))
                .into_any_element();
            trigger = trigger.child(popover::anchored_menu("mcp-device-menu", menu, None));
        }
        trigger.into_any_element()
    }

    fn render_project_picker(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let projects = self.projects(cx);
        let label: SharedString = self
            .project
            .as_ref()
            .map(|path| {
                projects
                    .iter()
                    .find(|(p, _)| p == path)
                    .map(|(_, name)| name.clone())
                    .unwrap_or_else(|| path.clone())
            })
            .unwrap_or_else(|| "Choose a project".into())
            .into();
        let open = self.project_menu_open;
        let mut trigger = menu_trigger(theme, "mcp-project-picker", icons::FOLDER, label, open)
            .on_mouse_down(
                gpui::MouseButton::Left,
                cx.listener(|this, _, _, _| {
                    this.project_menu_pressed_open = this.project_menu_open
                }),
            )
            .on_click(cx.listener(|this, _, _, cx| {
                let pressed_open = std::mem::take(&mut this.project_menu_pressed_open);
                this.project_menu_open = !pressed_open && !this.project_menu_open;
                cx.notify();
            }));
        let current = self.project.clone();
        if open {
            let theme = &theme.for_popup();
            let none_active = current.is_none();
            let menu = popover::popover_card(theme)
                .w(px(260.0))
                .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                    this.project_menu_open = false;
                    cx.notify();
                }))
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(popover::menu_heading(theme, "Projects on this device"))
                .child(
                    popover::menu_row(theme, none_active, "mcp-project-none")
                        .id("mcp-project-none")
                        .on_click(cx.listener(|this, _, _, cx| this.set_project(None, cx)))
                        .child(SharedString::from("No project")),
                )
                .children(projects.into_iter().enumerate().map(|(ix, (path, name))| {
                    let active = current.as_deref() == Some(path.as_str());
                    popover::menu_row(theme, active, format!("mcp-project-row-{ix}"))
                        .id(("mcp-project-row", ix))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.set_project(Some(path.clone()), cx)
                        }))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .child(SharedString::from(name)),
                        )
                }))
                .into_any_element();
            trigger = trigger.child(popover::anchored_menu_below("mcp-project-menu", menu, None));
        }
        trigger.into_any_element()
    }

    fn render_server(
        &self,
        theme: &Theme,
        ix: usize,
        first: bool,
        server: &McpServerView,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let summary = match (&server.url, &server.command) {
            (Some(url), _) => url.clone(),
            (None, Some(command)) => {
                let mut words = vec![command.clone()];
                words.extend(server.args.iter().cloned());
                join_command(&words)
            }
            (None, None) => "(no command)".into(),
        };
        let mut meta = vec![div().child(SharedString::from(summary)).into_any_element()];
        let keys = if server.url.is_some() {
            &server.header_keys
        } else {
            &server.env_keys
        };
        if !keys.is_empty() {
            let what = if server.url.is_some() {
                "headers"
            } else {
                "env"
            };
            meta.push(
                div()
                    .child(SharedString::from(format!("{what}: {}", keys.join(", "))))
                    .into_any_element(),
            );
        }
        if server.overrides_global {
            meta.push(
                div()
                    .child(SharedString::from("replaces the global one"))
                    .into_any_element(),
            );
        }
        let key = (server.scope, server.name.clone());
        let confirming = self.confirm_remove.as_ref() == Some(&key);
        let busy = self.busy;
        let toggle_key = key.clone();
        let enabled = server.enabled;
        let toggle = widgets::toggle_switch(theme, enabled)
            .id(("mcp-toggle", ix))
            .when(busy, |el| el.opacity(0.4))
            .when(!busy, |el| {
                el.cursor_pointer().on_click(cx.listener(move |this, _, _, cx| {
                    this.call(
                        methods::SET_GRAFF_MCP_SERVER_ENABLED,
                        serde_json::json!({ "scope": toggle_key.0, "name": toggle_key.1, "enabled": !enabled }),
                        cx,
                    );
                }))
            });
        let edit_server = server.clone();
        let actions: AnyElement = if server.scope == McpScope::Imported {
            div().into_any_element()
        } else if confirming {
            let remove_key = key.clone();
            div()
                .flex()
                .flex_row()
                .gap(px(6.0))
                .child(
                    popover::btn_ghost(theme, "Keep", format!("mcp-keep-{ix}"))
                        .id(("mcp-keep", ix))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.confirm_remove = None;
                            cx.notify();
                        })),
                )
                .child(
                    popover::btn_danger(theme, "Remove")
                        .id(("mcp-remove-confirm", ix))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.confirm_remove = None;
                            this.call(
                                methods::REMOVE_GRAFF_MCP_SERVER,
                                serde_json::json!({ "scope": remove_key.0, "name": remove_key.1 }),
                                cx,
                            );
                        })),
                )
                .into_any_element()
        } else {
            div()
                .flex()
                .flex_row()
                .gap(px(2.0))
                .child(
                    widgets::ghost_action(theme)
                        .id(("mcp-edit", ix))
                        .hover(|s| widgets::ghost_hover(theme, s))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.open_dialog(Some(&edit_server), cx)
                        }))
                        .child(SharedString::from("Edit")),
                )
                .child(
                    widgets::ghost_action(theme)
                        .id(("mcp-remove", ix))
                        .hover(|s| widgets::ghost_hover(theme, s))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.confirm_remove = Some(key.clone());
                            cx.notify();
                        }))
                        .child(SharedString::from("Remove")),
                )
                .into_any_element()
        };
        widgets::card_row(theme, first)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .when(!enabled, |el| el.opacity(0.55))
                    .child(widgets::row_title(theme, server.name.clone()))
                    .child(widgets::meta_line(theme, meta)),
            )
            .child(actions)
            .child(toggle)
            .into_any_element()
    }

    fn render_card(
        &self,
        theme: &Theme,
        title: String,
        path: Option<String>,
        servers: &[(usize, &McpServerView)],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut card = widgets::section_card(theme).child(
            div()
                .px(px(20.0))
                .pt(px(14.0))
                .pb(px(10.0))
                .child(widgets::row_title(theme, title))
                .children(path.map(|p| widgets::page_subtitle(theme, p))),
        );
        if servers.is_empty() {
            card = card.child(
                widgets::card_row(theme, false).child(
                    div()
                        .text_color(theme.text_muted)
                        .child(SharedString::from("No servers yet")),
                ),
            );
        }
        // The card's heading sits above the first row, so every row draws its top rule.
        for (ix, server) in servers {
            card = card.child(self.render_server(theme, *ix, false, server, cx));
        }
        card.into_any_element()
    }

    fn render_dialog(
        &mut self,
        viewport: gpui::Size<gpui::Pixels>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let theme = Theme::of(cx).for_popup();
        let dialog = self.dialog.as_ref()?;
        let has_project = self.project.is_some();
        let editing = dialog.editing.is_some();
        let pill = |label: &'static str, selected: bool, id: &'static str| {
            let pill = if selected {
                widgets::badge_active(&theme, label)
            } else {
                widgets::badge(&theme, label)
            };
            pill.id(id).when(!selected, |el| {
                el.cursor_pointer().hover(|s| s.text_color(theme.text))
            })
        };
        let scope_row = div()
            .flex()
            .flex_row()
            .gap(px(6.0))
            .child(
                pill(
                    "Every project",
                    dialog.scope == McpScope::Global,
                    "mcp-scope-global",
                )
                .when(editing, |el| {
                    el.opacity(if dialog.scope == McpScope::Global {
                        1.0
                    } else {
                        0.35
                    })
                })
                .when(!editing, |el| {
                    el.on_click(cx.listener(|this, _, _, cx| {
                        if let Some(d) = this.dialog.as_mut() {
                            d.scope = McpScope::Global;
                        }
                        cx.notify();
                    }))
                }),
            )
            .when(has_project || dialog.scope == McpScope::Project, |row| {
                row.child(
                    pill(
                        "This project",
                        dialog.scope == McpScope::Project,
                        "mcp-scope-project",
                    )
                    .when(editing, |el| {
                        el.opacity(if dialog.scope == McpScope::Project {
                            1.0
                        } else {
                            0.35
                        })
                    })
                    .when(!editing, |el| {
                        el.on_click(cx.listener(|this, _, _, cx| {
                            if let Some(d) = this.dialog.as_mut() {
                                d.scope = McpScope::Project;
                            }
                            cx.notify();
                        }))
                    }),
                )
            });
        let kind_row = div()
            .flex()
            .flex_row()
            .gap(px(6.0))
            .child(
                pill("Runs a command", !dialog.remote, "mcp-kind-command").on_click(cx.listener(
                    |this, _, _, cx| {
                        if let Some(d) = this.dialog.as_mut() {
                            d.remote = false;
                        }
                        cx.notify();
                    },
                )),
            )
            .child(
                pill("Connects to a URL", dialog.remote, "mcp-kind-url").on_click(cx.listener(
                    |this, _, _, cx| {
                        if let Some(d) = this.dialog.as_mut() {
                            d.remote = true;
                        }
                        cx.notify();
                    },
                )),
            );
        let (target_label, secrets_label) = if dialog.remote {
            (
                "URL",
                "Headers (NAME=value per line; a bare NAME keeps its stored value)",
            )
        } else {
            (
                "Command",
                "Environment (NAME=value per line; a bare NAME keeps its stored value)",
            )
        };
        let field = |label: &str, input: AnyElement| {
            div()
                .mt(px(12.0))
                .flex()
                .flex_col()
                .gap(px(6.0))
                .child(widgets::field_label(&theme, label.to_string()))
                .child(popover::dialog_field(input))
        };
        let busy = self.busy;
        let card = popover::dialog_card(&theme)
            .w(px(520.0))
            .child(popover::dialog_title(
                &theme,
                if editing {
                    "Edit MCP server"
                } else {
                    "Add MCP server"
                },
            ))
            .child(div().mt(px(12.0)).child(scope_row))
            .child(div().mt(px(8.0)).child(kind_row))
            .child(field("Name", dialog.name.clone().into_any_element()))
            .child(field(
                target_label,
                dialog.target.clone().into_any_element(),
            ))
            .child(field(
                secrets_label,
                dialog.secrets.clone().into_any_element(),
            ))
            .children(
                dialog
                    .error
                    .clone()
                    .map(|e| widgets::error_strip(&theme, e).mt(px(12.0))),
            )
            .child(
                div()
                    .mt(px(16.0))
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(8.0))
                    .child(
                        popover::btn_ghost(&theme, "Cancel", "mcp-dialog-cancel")
                            .id("mcp-dialog-cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.dialog = None;
                                cx.notify();
                            })),
                    )
                    .child(
                        popover::btn_primary(&theme, if editing { "Save" } else { "Add" })
                            .id("mcp-dialog-save")
                            .when(busy, |el| el.opacity(0.5))
                            .when(!busy, |el| {
                                el.on_click(cx.listener(|this, _, _, cx| this.submit_dialog(cx)))
                            }),
                    ),
            )
            .into_any_element();
        Some(popover::modal("mcp-server-dialog", viewport, card))
    }

    fn on_scroll_hovered(&mut self, hovered: &bool, _: &mut Window, cx: &mut Context<Self>) {
        if self.scroll.set_list_hovered(*hovered) {
            cx.notify();
        }
    }
}

/// The page-header picker button: icon, label, and the up/down chevron.
fn menu_trigger(
    theme: &Theme,
    id: &'static str,
    glyph: &'static str,
    label: SharedString,
    open: bool,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .flex_none()
        .h(px(28.0))
        .px(px(8.0))
        .rounded(px(6.0))
        .flex()
        .flex_row()
        .items_center()
        .gap(px(6.0))
        .cursor_pointer()
        .bg(if open {
            crate::theme::ink(0.06)
        } else {
            gpui::transparent_black()
        })
        .when(!open, |el| el.hover(|s| s.bg(crate::theme::ink(0.04))))
        .child(
            icon(glyph)
                .size(px(16.0))
                .flex_none()
                .text_color(theme.text_muted),
        )
        .child(
            div()
                .min_w_0()
                .max_w(px(220.0))
                .truncate()
                .text_size(crate::typography::ui_rems(12.5))
                .font_weight(gpui::FontWeight::MEDIUM)
                .text_color(theme.text)
                .child(label),
        )
        .child(
            icon(icons::SORT_VERTICAL)
                .size(px(14.0))
                .flex_none()
                .text_color(theme.text_muted.opacity(if open { 0.9 } else { 0.4 })),
        )
}

impl popover::ScrollRailHost for McpPage {
    fn rail_bar(&mut self) -> &mut popover::MenuScrollbarState {
        self.scroll.rail_bar()
    }

    fn rail_scroll(&self) -> Option<gpui::ScrollHandle> {
        self.scroll.rail_scroll()
    }
}

impl Render for McpPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let switcher = self.render_device_switcher(&theme, cx);
        let picker = self.render_project_picker(&theme, cx);
        let dialog = self.render_dialog(window.viewport_size(), cx);
        let scrollbar = popover::rail(self, "mcp-page-scrollbar", &theme, cx);

        let body: AnyElement = match &self.listing {
            Loadable::Idle | Loadable::Loading => widgets::page_subtitle(&theme, "Loading…")
                .mt(px(24.0))
                .into_any_element(),
            Loadable::Error(err) => widgets::error_strip(&theme, err.clone())
                .mt(px(24.0))
                .into_any_element(),
            Loadable::Ready(listing) => {
                let listing = listing.clone();
                let indexed: Vec<(usize, &McpServerView)> =
                    listing.servers.iter().enumerate().collect();
                let global: Vec<_> = indexed
                    .iter()
                    .copied()
                    .filter(|(_, s)| s.scope == McpScope::Global)
                    .collect();
                let project: Vec<_> = indexed
                    .iter()
                    .copied()
                    .filter(|(_, s)| s.scope == McpScope::Project)
                    .collect();
                let imported: Vec<_> = indexed
                    .iter()
                    .copied()
                    .filter(|(_, s)| s.scope == McpScope::Imported)
                    .collect();
                let mut column = div().flex().flex_col();
                if listing.invalid_global {
                    column = column.child(widgets::warning_strip(&theme, format!("{} isn't a valid MCP config, so it isn't shown. Fix it by hand; Harness won't change it.", listing.global_path)).mt(px(16.0)));
                }
                if listing.invalid_project
                    && let Some(path) = &listing.project_path
                {
                    column = column.child(widgets::warning_strip(&theme, format!("{path} isn't a valid MCP config, so it isn't shown. Fix it by hand; Harness won't change it.")).mt(px(16.0)));
                }
                column = column.child(self.render_card(
                    &theme,
                    "Every project".into(),
                    Some(listing.global_path.clone()),
                    &global,
                    cx,
                ));
                if let Some(path) = &listing.project_path {
                    let name = self
                        .project
                        .as_ref()
                        .and_then(|p| self.projects(cx).into_iter().find(|(path, _)| path == p))
                        .map(|(_, name)| name)
                        .unwrap_or_else(|| "This project".into());
                    column = column.child(self.render_card(
                        &theme,
                        name,
                        Some(path.clone()),
                        &project,
                        cx,
                    ));
                }
                let imported_note = listing.imported_note.clone().unwrap_or_else(|| {
                    "graff also connects these, from Claude, Cursor, Grok and plugin configs on this device. \
                     Switch one off here; edit it in the tool that defines it."
                        .into()
                });
                if !imported.is_empty() || listing.imported_note.is_some() {
                    column = column.child(self.render_card(
                        &theme,
                        "From other tools".into(),
                        Some(imported_note),
                        &imported,
                        cx,
                    ));
                }
                column.into_any_element()
            }
        };
        let error = self
            .error
            .clone()
            .map(|e| widgets::error_strip(&theme, e).mt(px(16.0)));

        div()
            .id("mcp-page-host")
            .relative()
            .size_full()
            .on_hover(cx.listener(Self::on_scroll_hovered))
            .child(
                div()
                    .id("mcp-page")
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll.scroll)
                    .child(
                        widgets::page_column()
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .justify_between()
                                    .child(widgets::page_header(&theme, "MCP", None))
                                    .child(switcher),
                            )
                            .child(
                                widgets::page_subtitle(
                                    &theme,
                                    "The MCP servers graff connects to on the selected device, in its own config files, so graff in a terminal sees the same ones. \
                                     Servers you add join running graff chats; one you remove or turn off leaves with the next chat.",
                                )
                                .max_w(px(512.0))
                                .line_height(px(20.0)),
                            )
                            .child(
                                div()
                                    .mt(px(16.0))
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .justify_between()
                                    .child(picker)
                                    .child(
                                        popover::btn_primary(&theme, "Add server")
                                            .id("mcp-add")
                                            .on_click(cx.listener(|this, _, _, cx| this.open_dialog(None, cx))),
                                    ),
                            )
                            .children(error)
                            .child(body),
                    ),
            )
            .children(scrollbar)
            .children(dialog)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listing() -> McpListing {
        serde_json::from_value(serde_json::json!({
            "globalPath": "/home/me/.codegraff/mcp.json",
            "projectPath": "/work/app/.mcp.json",
            "invalidGlobal": false,
            "invalidProject": true,
            "servers": [
                {"name": "docs", "scope": "global", "enabled": true, "overridesGlobal": false,
                 "command": null, "args": [], "url": "https://docs.example/mcp",
                 "envKeys": [], "headerKeys": ["Authorization"]},
                {"name": "files", "scope": "project", "enabled": false, "overridesGlobal": false,
                 "command": "/bin/files", "args": ["--root", "my dir"], "url": null,
                 "envKeys": ["TOKEN"], "headerKeys": []},
                {"name": "from-claude", "scope": "imported", "enabled": true, "overridesGlobal": false,
                 "command": "npx", "args": ["-y", "some-server"], "url": null,
                 "envKeys": [], "headerKeys": []}
            ]
        }))
        .unwrap()
    }

    #[gpui::test]
    fn the_page_renders_its_servers_menus_and_editor(cx: &mut gpui::TestAppContext) {
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
        });
        let (page, cx) = cx.add_window_view(|_, cx| {
            let state = cx.new(|_| AppState::new());
            McpPage::new(state, cx)
        });
        page.update(cx, |page, cx| {
            page.project = Some("/work/app".into());
            page.listing = Loadable::Ready(listing());
            page.device_menu_open = true;
            page.project_menu_open = true;
            page.confirm_remove = Some((McpScope::Global, "docs".into()));
            cx.notify();
        });
        cx.simulate_resize(gpui::size(px(1100.0), px(800.0)));
        cx.run_until_parked();

        // Editing the project server: its command and kept env name come back.
        page.update(cx, |page, cx| {
            let files = listing().servers[1].clone();
            page.open_dialog(Some(&files), cx);
        });
        cx.simulate_resize(gpui::size(px(1000.0), px(800.0)));
        cx.run_until_parked();
        let request = page
            .read_with(cx, |page, cx| page.dialog_request(cx))
            .unwrap();
        assert_eq!(
            request,
            serde_json::json!({"scope": "project", "server": {
                "name": "files", "previousName": "files", "command": "/bin/files",
                "args": ["--root", "my dir"], "env": {"TOKEN": null}
            }})
        );

        // Adding a URL server with a header value.
        page.update(cx, |page, cx| {
            page.open_dialog(None, cx);
            let dialog = page.dialog.as_mut().unwrap();
            dialog.remote = true;
            dialog.scope = McpScope::Global;
            let (name, target, secrets) = (
                dialog.name.clone(),
                dialog.target.clone(),
                dialog.secrets.clone(),
            );
            name.update(cx, |i, cx| i.set_text("search", cx));
            target.update(cx, |i, cx| i.set_text("https://search.example/mcp", cx));
            secrets.update(cx, |i, cx| i.set_text("Authorization=Bearer t", cx));
        });
        cx.run_until_parked();
        let request = page
            .read_with(cx, |page, cx| page.dialog_request(cx))
            .unwrap();
        assert_eq!(
            request,
            serde_json::json!({"scope": "global", "server": {
                "name": "search", "url": "https://search.example/mcp",
                "headers": {"Authorization": "Bearer t"}
            }})
        );
    }

    #[test]
    fn command_lines_split_on_spaces_and_respect_quotes() {
        assert_eq!(
            split_command("npx -y @scope/server --root .").unwrap(),
            ["npx", "-y", "@scope/server", "--root", "."]
        );
        assert_eq!(
            split_command(r#"node "my server.js" 'a b' c\ d"#).unwrap(),
            ["node", "my server.js", "a b", "c d"]
        );
        assert_eq!(split_command("  ").unwrap(), Vec::<String>::new());
        assert_eq!(split_command(r#"run """#).unwrap(), ["run", ""]);
        assert!(split_command("run 'open").is_err());
    }

    #[test]
    fn a_stored_command_round_trips_through_the_editor() {
        let words: Vec<String> = ["/bin/srv", "--name", "a b", "it's", ""]
            .map(String::from)
            .to_vec();
        assert_eq!(split_command(&join_command(&words)).unwrap(), words);
    }

    #[test]
    fn secrets_set_values_or_keep_stored_ones() {
        let parsed = parse_secrets("TOKEN=abc=def\n  KEEP  \n\nEMPTY=\n").unwrap();
        assert_eq!(parsed["TOKEN"], "abc=def");
        assert!(parsed["KEEP"].is_null());
        assert_eq!(parsed["EMPTY"], "");
        assert!(parse_secrets("=x").is_err());
        assert!(parse_secrets("TWO WORDS").is_err());
    }
}
