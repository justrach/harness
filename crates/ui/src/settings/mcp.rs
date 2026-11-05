//! Settings → MCP servers: every MCP server graff starts for agents, with
//! its state and tools, and Reconnect / Sign in / On-off per server.
//!
//! The rows come from `graff mcp status --json` on the device that hosts the
//! selected project (`ListMcpServers`), so project `.mcp.json` servers show
//! beside the user-level ones. graff runs fresh for every turn, so Reconnect
//! is a real handshake that refreshes the tools the next turn sees
//! (`McpServerAction`).

use std::collections::HashSet;

use gpui::{
    AnyElement, Context, Entity, Hsla, SharedString, Subscription, Task, Window, div, prelude::*,
    px,
};

use harness_proto::{McpServerRow, McpServerState, McpServerVerb};
use harness_rpc::methods;

use crate::popover::{self, Loadable};
use crate::settings::widgets;
use crate::state::AppState;
use crate::theme::Theme;

/// Where the page looks: a device and, when a project is selected, its folder.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct McpTarget {
    pub device_id: Option<String>,
    pub cwd: Option<String>,
    pub label: Option<String>,
}

impl McpTarget {
    fn of(state: &AppState) -> Self {
        match state.selected_space_row() {
            Some(space) => Self {
                device_id: Some(space.device_id.clone()),
                cwd: Some(space.path.clone()),
                label: Some(space.display_name().to_string()),
            },
            None => Self {
                device_id: state.effective_device_id(),
                cwd: None,
                label: None,
            },
        }
    }
}

/// Request params, forwarded to the project's device when it is not this one.
pub fn params(
    target: &McpTarget,
    local: Option<&str>,
    mut value: serde_json::Value,
) -> serde_json::Value {
    if let Some(object) = value.as_object_mut() {
        if let Some(cwd) = &target.cwd {
            object.insert("cwd".into(), serde_json::json!(cwd));
        }
        if let Some(device) = target.device_id.as_deref().filter(|d| Some(*d) != local) {
            object.insert("targetDeviceId".into(), serde_json::json!(device));
        }
    }
    value
}

/// Fold an action's rows into the list: replace by name, keep the rest.
pub fn merge(rows: &mut Vec<McpServerRow>, fresh: Vec<McpServerRow>) {
    for row in fresh {
        match rows.iter_mut().find(|r| r.name == row.name) {
            Some(slot) => *slot = row,
            None => rows.push(row),
        }
    }
}

/// Status dot color for a state.
fn dot(theme: &Theme, state: McpServerState) -> Hsla {
    match state {
        McpServerState::Ready | McpServerState::OnDemand => theme.success,
        McpServerState::Connecting | McpServerState::NeedsLogin | McpServerState::Unknown => {
            theme.warning
        }
        McpServerState::Failed => theme.danger,
        McpServerState::Off | McpServerState::OptIn | McpServerState::NotStarted => {
            theme.text_muted.opacity(0.4)
        }
    }
}

pub struct McpPage {
    state: Entity<AppState>,
    scroll: widgets::PageScroll,
    target: McpTarget,
    rows: Loadable<Vec<McpServerRow>>,
    error: Option<SharedString>,
    /// Servers with an action in flight.
    busy: HashSet<String>,
    checking_all: bool,
    expanded: HashSet<String>,
    load_task: Option<Task<()>>,
    action_tasks: Vec<Task<()>>,
    _observe: Subscription,
}

impl McpPage {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        // A different project (or device) lists different servers.
        let observe = cx.observe(&state, |this: &mut Self, state, cx| {
            if McpTarget::of(state.read(cx)) != this.target {
                this.load(cx);
            }
            cx.notify();
        });
        let mut page = Self {
            state,
            scroll: widgets::PageScroll::default(),
            target: McpTarget::default(),
            rows: Loadable::Idle,
            error: None,
            busy: HashSet::new(),
            checking_all: false,
            expanded: HashSet::new(),
            load_task: None,
            action_tasks: Vec::new(),
            _observe: observe,
        };
        page.load(cx);
        page
    }

    fn request(&self, cx: &Context<Self>, value: serde_json::Value) -> serde_json::Value {
        let local = self.state.read(cx).local_device_id.clone();
        params(&self.target, local.as_deref(), value)
    }

    fn load(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.rows = Loadable::Error("Engine not connected".into());
            return;
        };
        self.target = McpTarget::of(self.state.read(cx));
        self.rows = Loadable::Loading;
        self.expanded.clear();
        let params = self.request(cx, serde_json::json!({}));
        self.load_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::LIST_MCP_SERVERS, params)
                .await;
            this.update(cx, |page, cx| {
                page.rows = match result.map(serde_json::from_value::<Vec<McpServerRow>>) {
                    Ok(Ok(rows)) => Loadable::Ready(rows),
                    Ok(Err(err)) => Loadable::Error(format!("Unexpected reply: {err}")),
                    Err(err) => Loadable::Error(err.to_string()),
                };
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// Run `verb` on one server (`None`: reconnect every switched-on one).
    fn act(&mut self, verb: McpServerVerb, name: Option<String>, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        match &name {
            Some(n) => {
                if !self.busy.insert(n.clone()) {
                    return;
                }
            }
            None if self.checking_all => return,
            None => self.checking_all = true,
        }
        self.error = None;
        let params = self.request(
            cx,
            serde_json::json!({ "action": verb, "name": name.clone() }),
        );
        let task = cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::MCP_SERVER_ACTION, params)
                .await;
            this.update(cx, |page, cx| {
                match &name {
                    Some(n) => {
                        page.busy.remove(n);
                    }
                    None => page.checking_all = false,
                }
                match result.map(serde_json::from_value::<Vec<McpServerRow>>) {
                    Ok(Ok(fresh)) => {
                        if let Loadable::Ready(rows) = &mut page.rows {
                            merge(rows, fresh);
                        }
                    }
                    Ok(Err(err)) => page.error = Some(format!("Unexpected reply: {err}").into()),
                    Err(err) => page.error = Some(err.to_string().into()),
                }
                cx.notify();
            })
            .ok();
        });
        // Finished tasks are cheap to hold; keep the list from growing unbounded.
        if self.action_tasks.len() > 32 && self.busy.is_empty() && !self.checking_all {
            self.action_tasks.clear();
        }
        self.action_tasks.push(task);
        cx.notify();
    }

    fn on_scroll_hovered(&mut self, hovered: &bool, _: &mut Window, cx: &mut Context<Self>) {
        if self.scroll.set_list_hovered(*hovered) {
            cx.notify();
        }
    }

    fn action_button(
        &self,
        theme: &Theme,
        id: (&'static str, usize),
        icon: &'static str,
        label: &'static str,
        busy_label: &'static str,
        busy: bool,
    ) -> gpui::Stateful<gpui::Div> {
        let hover_theme = theme.clone();
        widgets::ghost_action(theme)
            .id(id)
            .flex_none()
            .border_1()
            .border_color(theme.border)
            .when(busy, |el| el.opacity(0.5))
            .hover(move |s| widgets::ghost_hover(&hover_theme, s))
            .child(
                crate::icons::icon(icon)
                    .size(px(14.0))
                    .text_color(theme.text_muted),
            )
            .child(SharedString::from(if busy { busy_label } else { label }))
    }

    fn render_row(
        &self,
        theme: &Theme,
        ix: usize,
        row: &McpServerRow,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let accent = theme.accent;
        let busy = self.busy.contains(&row.name) || (self.checking_all && row.enabled);
        let expanded = self.expanded.contains(&row.name);
        let mut status: Vec<AnyElement> = vec![
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(6.0))
                .child(div().size(px(7.0)).rounded_full().bg(dot(theme, row.state)))
                .child(SharedString::from(row.state.label()))
                .into_any_element(),
        ];
        if row.tool_count > 0 {
            status.push(
                SharedString::from(format!(
                    "{} tool{}",
                    row.tool_count,
                    if row.tool_count == 1 { "" } else { "s" }
                ))
                .into_any_element(),
            );
        }
        if !row.origin.is_empty() {
            status.push(SharedString::from(row.origin.clone()).into_any_element());
        }
        let problem: Option<SharedString> = match (&row.error, &row.detail) {
            (_, Some(detail)) => Some(detail.clone().into()),
            (Some(error), None) => Some(error.clone().into()),
            _ => None,
        };
        let needs_login = row.state == McpServerState::NeedsLogin;
        let name = row.name.clone();
        let (name_toggle, name_reconnect, name_login, name_switch) =
            (name.clone(), name.clone(), name.clone(), name.clone());
        let enabled = row.enabled;
        let tools = row.tools.clone();

        let head = widgets::card_row(theme, ix == 0)
            .id(("mcp-row", ix))
            .cursor_pointer()
            .on_click(cx.listener(move |this, _, _, cx| {
                if !this.expanded.remove(&name_toggle) {
                    this.expanded.insert(name_toggle.clone());
                }
                cx.notify();
            }))
            .child(widgets::row_tile(
                theme,
                if row.transport == "http" {
                    crate::icons::REMOTE_SERVER
                } else {
                    crate::icons::TERMINAL
                },
            ))
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex()
                            .flex_row()
                            .items_center()
                            .gap(px(8.0))
                            .child(widgets::row_title(theme, row.name.clone()))
                            .when(!row.source.is_empty(), |el| {
                                el.child(widgets::badge(theme, row.source.clone()))
                            }),
                    )
                    .child(widgets::meta_line(theme, status))
                    .when_some(problem, |el, text| {
                        el.child(
                            div()
                                .mt(px(4.0))
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(theme.danger_muted.opacity(0.9))
                                .child(text),
                        )
                    }),
            )
            .when(needs_login, |el| {
                el.child(
                    self.action_button(
                        theme,
                        ("mcp-login", ix),
                        crate::icons::KEY_MINIMALISTIC,
                        "Sign in",
                        "Signing in…",
                        busy,
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        cx.stop_propagation();
                        this.act(McpServerVerb::Login, Some(name_login.clone()), cx);
                    })),
                )
            })
            .when(enabled, |el| {
                el.child(
                    self.action_button(
                        theme,
                        ("mcp-reconnect", ix),
                        crate::icons::RESTART,
                        "Reconnect",
                        "Connecting…",
                        busy,
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        cx.stop_propagation();
                        this.act(McpServerVerb::Reconnect, Some(name_reconnect.clone()), cx);
                    })),
                )
            })
            .child(
                div()
                    .id(("mcp-switch", ix))
                    .flex_none()
                    .size(px(40.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .role(gpui::Role::Switch)
                    .aria_label(SharedString::from(format!("Use {}", row.name)))
                    .aria_toggled(if enabled {
                        gpui::Toggled::True
                    } else {
                        gpui::Toggled::False
                    })
                    .tab_index(0)
                    .focus_visible(move |style| style.border_2().border_color(accent))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        cx.stop_propagation();
                        let verb = if enabled {
                            McpServerVerb::Disable
                        } else {
                            McpServerVerb::Enable
                        };
                        this.act(verb, Some(name_switch.clone()), cx);
                    }))
                    .child(widgets::toggle_switch(theme, enabled)),
            );

        let mut block = div().flex().flex_col().child(head);
        if expanded {
            let list = if tools.is_empty() {
                vec![
                    div()
                        .text_color(theme.text_muted.opacity(0.6))
                        .child(SharedString::from(
                            "No tools known yet. Reconnect lists them.",
                        ))
                        .into_any_element(),
                ]
            } else {
                tools
                    .into_iter()
                    .map(|tool| {
                        div()
                            .flex()
                            .flex_row()
                            .gap(px(8.0))
                            .child(
                                div()
                                    .flex_none()
                                    .font_family(theme.font_mono.clone())
                                    .text_color(theme.text)
                                    .child(SharedString::from(tool.name)),
                            )
                            .child(
                                div()
                                    .min_w_0()
                                    .truncate()
                                    .text_color(theme.text_muted.opacity(0.7))
                                    .child(SharedString::from(tool.description)),
                            )
                            .into_any_element()
                    })
                    .collect()
            };
            block = block.child(
                div()
                    .pl(px(70.0))
                    .pr(px(20.0))
                    .pb(px(12.0))
                    .flex()
                    .flex_col()
                    .gap(px(4.0))
                    .text_size(crate::typography::ui_rems(12.0))
                    .children(list),
            );
        }
        block.into_any_element()
    }
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
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let rows: Vec<McpServerRow> = self.rows.ready().cloned().unwrap_or_default();
        let count = rows.len();
        let subtitle = match &self.target.label {
            Some(project) => format!(
                "Servers graff starts for agents in {project}: this project's .mcp.json plus your user-level and imported servers. Reconnect runs a fresh handshake and refreshes the tools the next turn sees."
            ),
            None => "Servers graff starts for agents in every project: your user-level and imported servers. Pick a project to include its .mcp.json. Reconnect runs a fresh handshake and refreshes the tools the next turn sees.".to_string(),
        };
        let hover_theme = theme.clone();
        let check_all = widgets::ghost_action(&theme)
            .id("mcp-check-all")
            .border_1()
            .border_color(theme.border)
            .when(self.checking_all, |el| el.opacity(0.5))
            .hover(move |s| widgets::ghost_hover(&hover_theme, s))
            .on_click(cx.listener(|this, _, _, cx| this.act(McpServerVerb::Reconnect, None, cx)))
            .child(
                crate::icons::icon(crate::icons::REFRESH)
                    .size(px(14.0))
                    .text_color(theme.text_muted),
            )
            .child(SharedString::from(if self.checking_all {
                "Checking…"
            } else {
                "Check all"
            }));

        let body: AnyElement = match &self.rows {
            Loadable::Idle | Loadable::Loading => div()
                .mt(px(24.0))
                .text_size(crate::typography::ui_rems(12.5))
                .text_color(theme.text_muted.opacity(0.6))
                .child(SharedString::from("Loading MCP servers…"))
                .into_any_element(),
            Loadable::Error(message) => div()
                .child(widgets::error_strip(&theme, message.clone()))
                .child(
                    widgets::ghost_action(&theme)
                        .id("mcp-retry")
                        .mt(px(8.0))
                        .hover(|s| s.bg(theme.element_hover))
                        .on_click(cx.listener(|this, _, _, cx| this.load(cx)))
                        .child(SharedString::from("Retry")),
                )
                .into_any_element(),
            Loadable::Ready(_) if rows.is_empty() => div()
                .mt(px(96.0))
                .flex()
                .flex_col()
                .items_center()
                .text_center()
                .text_color(theme.text_muted.opacity(0.5))
                .child(
                    crate::icons::icon(crate::icons::REMOTE_SERVER)
                        .size(px(28.0))
                        .text_color(theme.text_muted.opacity(0.2)),
                )
                .child(
                    div()
                        .mt(px(12.0))
                        .text_size(crate::typography::ui_rems(14.0))
                        .child(SharedString::from("No MCP servers configured")),
                )
                .child(
                    div()
                        .mt(px(4.0))
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.text_muted.opacity(0.4))
                        .child(SharedString::from(
                            "Add one with `graff mcp add`, or ask an agent to.",
                        )),
                )
                .into_any_element(),
            Loadable::Ready(_) => {
                let items: Vec<AnyElement> = rows
                    .iter()
                    .enumerate()
                    .map(|(ix, row)| self.render_row(&theme, ix, row, cx))
                    .collect();
                widgets::section_card(&theme)
                    .mt(px(16.0))
                    .children(items)
                    .into_any_element()
            }
        };

        let scrollbar = popover::rail(self, "mcp-page-scrollbar", &theme, cx);
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
                                    .child(widgets::page_header(
                                        &theme,
                                        "MCP servers",
                                        (count > 0).then_some(count),
                                    ))
                                    .child(check_all),
                            )
                            .child(widgets::page_subtitle(&theme, subtitle))
                            .when_some(self.error.clone(), |el, message| {
                                el.child(
                                    widgets::error_strip(&theme, message)
                                        .id("mcp-error")
                                        .cursor_pointer()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.error = None;
                                            cx.notify();
                                        })),
                                )
                            })
                            .child(body),
                    ),
            )
            .children(scrollbar)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(name: &str, state: McpServerState) -> McpServerRow {
        McpServerRow {
            name: name.into(),
            source: "global".into(),
            transport: "stdio".into(),
            origin: name.into(),
            enabled: true,
            state,
            error: None,
            error_code: None,
            detail: None,
            auth: "none".into(),
            tool_count: 0,
            tools: Vec::new(),
        }
    }

    #[test]
    fn an_action_replaces_its_rows_and_keeps_the_rest() {
        let mut rows = vec![
            row("a", McpServerState::Failed),
            row("b", McpServerState::OnDemand),
        ];
        merge(&mut rows, vec![row("a", McpServerState::Ready)]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].state, McpServerState::Ready);
        assert_eq!(rows[1].state, McpServerState::OnDemand);
    }

    #[test]
    fn params_carry_the_project_folder_and_forward_only_to_other_devices() {
        let target = McpTarget {
            device_id: Some("remote".into()),
            cwd: Some("/work/app".into()),
            label: Some("app".into()),
        };
        let p = params(
            &target,
            Some("local"),
            serde_json::json!({ "action": "reconnect" }),
        );
        assert_eq!(p["cwd"], "/work/app");
        assert_eq!(p["targetDeviceId"], "remote");
        let here = McpTarget {
            device_id: Some("local".into()),
            ..Default::default()
        };
        let p = params(&here, Some("local"), serde_json::json!({}));
        assert!(p.get("targetDeviceId").is_none() && p.get("cwd").is_none());
    }
}
