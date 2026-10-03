//! Settings → Agents / accounts (feature-inventory §1.9): provider cards
//! (Claude Code, Codex, Cursor) with account rows — email, plan badge, Active, usage
//! meters (indigo → amber ≥80% → red ≥95%, reset time), Switch / Forget — plus
//! the add-account dialogs (paste-code and browser-poll flows) and
//! account-shaped loading skeletons. Harness retargets devices from the settings
//! sidebar (`targetDeviceId` passthrough kept plumbed, unused single-device).
//!
//! The accounts RPC surface is being implemented engine-side in parallel —
//! every call here surfaces failures as inline UI states rather than assuming
//! the methods exist.

use chrono::{DateTime, Utc};
use gpui::{
    AnyElement, ClipboardItem, Context, Entity, Hsla, SharedString, Subscription, Task, Window,
    div, prelude::*, px,
};
use std::time::Duration;

use harness_proto::{
    AgentAccount, AgentAccountsSnapshot, AgentLoginMode, AgentLoginPoll, AgentLoginStart,
    AgentLoginStatus, GRAFF_LOGIN_PROVIDERS, GraffLoginProvider, HarnessId, ReauthProvider,
};
use harness_rpc::methods;

use crate::codegraff_jobs::{CodegraffJob, job_active, job_summary};
use crate::composer::{ComposerInput, ComposerInputEvent};
use crate::popover::{self, Loadable};
use crate::settings::widgets;
use crate::state::AppState;
use crate::theme::Theme;

// ---------------------------------------------------------------------------
// Pure: usage meters + labels
// ---------------------------------------------------------------------------

pub const USAGE_WARN_FRACTION: f32 = 0.80;
pub const USAGE_CRITICAL_FRACTION: f32 = 0.95;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UsageLevel {
    /// < 80% — indigo.
    Normal,
    /// ≥ 80% — amber.
    Warn,
    /// ≥ 95% — red.
    Critical,
}

/// Threshold classification of a usage fraction. Pure.
pub fn usage_level(fraction: f32) -> UsageLevel {
    if fraction >= USAGE_CRITICAL_FRACTION {
        UsageLevel::Critical
    } else if fraction >= USAGE_WARN_FRACTION {
        UsageLevel::Warn
    } else {
        UsageLevel::Normal
    }
}

pub fn usage_color(level: UsageLevel, theme: &Theme) -> Hsla {
    match level {
        UsageLevel::Normal => theme.accent,
        UsageLevel::Warn => theme.warning,
        UsageLevel::Critical => theme.danger,
    }
}

/// Why a `ListAgentAccounts` load is happening. Pure input to
/// [`force_usage_for`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoadTrigger {
    /// Page construction — the visit's first list.
    Mount,
    /// "Click to retry" after a failed load — still the visit's first
    /// successful list.
    Retry,
    /// The explicit Refresh button.
    Refresh,
    /// After a completed add-account login flow.
    PostLogin,
    /// After Switch/Forget succeeds.
    PostAction,
}

/// Whether a load should ask the engine to probe usage (`forceUsage`). The
/// engine only hits the provider when forced; non-forced lists serve the 60s
/// usage cache or nothing (engine/src/agent_accounts.rs module docs — the
/// design expects the UI to force "on page mount/refresh"). The visit's first
/// list (mount, or retry after a failure) must force, or every first open
/// renders "Usage unavailable" until a manual Refresh — the old app fetched
/// usage on every list. Post-Switch/Forget lists ride the still-warm cache.
pub fn force_usage_for(trigger: LoadTrigger) -> bool {
    match trigger {
        LoadTrigger::Mount | LoadTrigger::Retry | LoadTrigger::Refresh | LoadTrigger::PostLogin => {
            true
        }
        LoadTrigger::PostAction => false,
    }
}

/// Compact absolute reset moment (harness settings.agents.tsx `formatReset`):
/// a local clock time ("3:45 PM") when it lands within ~22h, a short weekday
/// ("Mon") within a week, else month + day ("Sep 14") — a weekday is noise
/// when the window is a Codex free-tier MONTHLY reset weeks out. The caller
/// prefixes "resets ". Pure given `now`.
pub fn format_reset(resets_at: Option<DateTime<Utc>>, now: DateTime<Utc>) -> Option<String> {
    use chrono::Local;
    let at = resets_at?;
    let local = at.with_timezone(&Local);
    Some(if at.signed_duration_since(now).num_hours() < 22 {
        format!("resets {}", local.format("%-I:%M %p"))
    } else if at.signed_duration_since(now).num_hours() < 24 * 7 {
        format!("resets {}", local.format("%a"))
    } else {
        format!("resets {}", local.format("%b %-d"))
    })
}

/// The provider cards, in display order: (harness, name, CLI command — named
/// in the empty-state copy, harness settings.agents.tsx `PROVIDERS`).
pub const PROVIDERS: [(HarnessId, &str, &str); 3] = [
    (HarnessId::ClaudeCode, "Claude Code", "claude"),
    (HarnessId::Codex, "Codex", "codex"),
    (HarnessId::Cursor, "Cursor", "cursor-agent"),
];

#[derive(Debug, Clone, serde::Deserialize)]
struct CodegraffUsage {
    email: String,
    tier: String,
    credits_micro_usd: i64,
    spend_30d_micro_usd: i64,
    requests_30d: i64,
    key_budget_monthly_micro_usd: Option<i64>,
    key_spend_monthly_micro_usd: i64,
    key_budget_resets_at: String,
}

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(default)]
struct CodegraffJobs {
    jobs: Vec<CodegraffJob>,
}

/// While a job is still working, the list refreshes this often.
const JOBS_POLL: Duration = Duration::from_secs(20);
/// How many recent jobs the card shows.
const JOBS_SHOWN: u64 = 8;

fn format_micro_usd(amount: i64) -> String {
    let dollars = amount as f64 / 1_000_000.0;
    let decimals = if dollars.abs() < 0.01 {
        6
    } else if dollars.abs() < 1.0 {
        4
    } else {
        2
    };
    format!("${dollars:.decimals$}")
}

/// Accounts of one provider, in the engine's order (slot creation). No
/// active-first re-sort: switching accounts must not move the switched-to
/// card — the Active badge already says which one is live, and a list that
/// reshuffles under the click reads as broken. Pure.
pub fn provider_accounts(
    snapshot: &AgentAccountsSnapshot,
    harness: HarnessId,
) -> Vec<&AgentAccount> {
    snapshot
        .accounts
        .iter()
        .filter(|a| a.harness == harness)
        .collect()
}

/// graff's OpenAI (ChatGPT) sign-in is the Codex login: it reads the same
/// `auth.json`. So that row follows the active Codex account — `(signed in,
/// who)`. Pure.
pub fn openai_login(snapshot: &AgentAccountsSnapshot) -> (bool, Option<String>) {
    match provider_accounts(snapshot, HarnessId::Codex)
        .into_iter()
        .find(|account| account.active)
    {
        Some(account) => (
            true,
            account
                .email
                .clone()
                .or_else(|| account.display_name.clone()),
        ),
        None => (false, None),
    }
}

/// A graff provider's display name for the sign-in dialog title.
fn graff_provider_name(id: Option<&str>) -> &'static str {
    if id == Some("chatgpt-new") {
        return "ChatGPT (new)";
    }
    GRAFF_LOGIN_PROVIDERS
        .iter()
        .find(|(provider, _)| Some(*provider) == id)
        .map(|(_, name)| *name)
        .unwrap_or("graff")
}

/// Only these typed routes can be selected by a transcript recovery action.
fn reauth_login_route(provider: ReauthProvider) -> (HarnessId, Option<&'static str>) {
    match provider {
        ReauthProvider::ChatgptNew => (HarnessId::Graff, Some("chatgpt-new")),
        ReauthProvider::Codex => (HarnessId::Codex, None),
    }
}

// ---------------------------------------------------------------------------
// Entity
// ---------------------------------------------------------------------------

enum LoginFlow {
    /// StartAgentLogin in flight.
    Starting {
        harness: HarnessId,
        /// graff's sign-ins say which provider (`xai`, `kimi`, `zai`).
        provider: Option<String>,
        reauthenticate: bool,
    },
    /// Claude-style: open the URL, paste the code back.
    PasteCode {
        harness: HarnessId,
        start: AgentLoginStart,
        submitting: bool,
        error: Option<SharedString>,
    },
    /// Codex-style: open the URL, poll until the browser flow lands.
    Browser {
        harness: HarnessId,
        provider: Option<String>,
        reauthenticate: bool,
        start: AgentLoginStart,
        message: Option<SharedString>,
        error: Option<SharedString>,
    },
}

impl LoginFlow {
    /// Dialog title (harness: "Add Claude account" / "Add Codex account").
    fn title(&self) -> String {
        let (harness, provider, reauthenticate) = match self {
            LoginFlow::Starting {
                harness,
                provider,
                reauthenticate,
            }
            | LoginFlow::Browser {
                harness,
                provider,
                reauthenticate,
                ..
            } => (*harness, provider.as_deref(), *reauthenticate),
            LoginFlow::PasteCode { harness, .. } => (*harness, None, false),
        };
        match harness {
            HarnessId::Codex if reauthenticate => "Sign in to ChatGPT (Codex)".into(),
            HarnessId::Codex => "Add Codex account".into(),
            HarnessId::Cursor => "Connect Cursor".into(),
            HarnessId::Graff => format!("Sign in to {}", graff_provider_name(provider)),
            _ => "Add Claude account".into(),
        }
    }
}

pub struct AccountsPage {
    state: Entity<AppState>,
    scroll: widgets::PageScroll,
    /// Which device's logins are shown; `None` = this device (no passthrough).
    /// Retargeted by the page-header device switcher (harness parity: the
    /// accounts RPCs are relay-forwardable, CLI logins are per-device).
    target_device: Option<String>,
    device_menu: popover::Popup<()>,
    snapshot: Loadable<AgentAccountsSnapshot>,
    codegraff_usage: Loadable<Option<CodegraffUsage>>,
    /// Recent CodeGraff PR-agent runs (`None` when signed out).
    codegraff_jobs: Loadable<Option<CodegraffJobs>>,
    jobs_task: Option<Task<()>>,
    /// The next refresh while a job is still working.
    jobs_poll_task: Option<Task<()>>,
    /// Job id with an in-flight Cancel.
    cancelling_job: Option<String>,
    /// Account id with an in-flight Switch/Forget.
    busy_account: Option<String>,
    /// graff's own provider sign-ins (xAI, Kimi, Z.AI) on the shown device.
    graff_logins: Loadable<Vec<GraffLoginProvider>>,
    graff_task: Option<Task<()>>,
    /// Provider id with an in-flight sign-out.
    busy_graff: Option<String>,
    login: Option<LoginFlow>,
    /// The sign-in link was just copied (the button reads "Copied").
    login_url_copied: bool,
    copy_task: Option<Task<()>>,
    error: Option<SharedString>,
    code_input: Entity<ComposerInput>,
    load_task: Option<Task<()>>,
    codegraff_task: Option<Task<()>>,
    action_task: Option<Task<()>>,
    poll_task: Option<Task<()>>,
    _observe: Subscription,
    _code_events: Subscription,
}

impl AccountsPage {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&state, |_, _, cx| cx.notify());
        let code_input = cx.new(|cx| ComposerInput::new("Paste the authorization code", cx));
        let code_events = cx.subscribe(&code_input, |this: &mut Self, _, event, cx| {
            if matches!(event, ComposerInputEvent::Submitted) {
                this.submit_code(cx);
            }
        });
        let mut page = Self {
            state,
            scroll: widgets::PageScroll::default(),
            target_device: None,
            device_menu: popover::Popup::default(),
            snapshot: Loadable::Idle,
            codegraff_usage: Loadable::Idle,
            codegraff_jobs: Loadable::Idle,
            jobs_task: None,
            jobs_poll_task: None,
            cancelling_job: None,
            busy_account: None,
            graff_logins: Loadable::Idle,
            graff_task: None,
            busy_graff: None,
            login: None,
            login_url_copied: false,
            copy_task: None,
            error: None,
            code_input,
            load_task: None,
            codegraff_task: None,
            action_task: None,
            poll_task: None,
            _observe: observe,
            _code_events: code_events,
        };
        // Force the usage probe on the visit's first list — a plain list
        // returns no usage windows on a cold engine cache, which rendered
        // every account as "Usage unavailable" until a manual Refresh. The
        // Loading skeleton (meter ghosts) covers the probe latency, so
        // "Usage unavailable" is reserved for a probe that genuinely failed.
        page.load(force_usage_for(LoadTrigger::Mount), cx);
        page
    }

    /// Retarget the page at another device's logins: every accounts RPC is
    /// relay-forwardable, so the whole page — list, usage probes, switch,
    /// forget, login flows — follows the passthrough.
    fn close_device_menu(&mut self, cx: &mut Context<Self>) {
        if self.device_menu.begin_close() {
            popover::reap_popup(cx, |page: &mut Self| &mut page.device_menu);
            cx.notify();
        }
    }

    fn set_target_device(&mut self, target: Option<String>, cx: &mut Context<Self>) {
        self.close_device_menu(cx);
        if self.target_device == target {
            cx.notify();
            return;
        }
        // Cancel against the OLD host before retargeting, and drop any start
        // request/poll so its completion cannot replace the new host's flow.
        self.cancel_login(cx);
        self.target_device = target;
        // A different device = a different accounts world: drop in-flight
        // login/action state and reload with a forced usage probe (the new
        // device's cache is cold).
        self.login = None;
        self.busy_account = None;
        self.busy_graff = None;
        // Another device's sign-ins: never show the last device's rows.
        self.graff_logins = Loadable::Idle;
        self.error = None;
        self.load(force_usage_for(LoadTrigger::Mount), cx);
    }

    /// Params with the `targetDeviceId` passthrough merged in.
    fn params(&self, value: serde_json::Value) -> serde_json::Value {
        let mut value = value;
        if let (Some(target), Some(object)) = (&self.target_device, value.as_object_mut()) {
            object.insert("targetDeviceId".into(), serde_json::json!(target));
        }
        value
    }

    fn on_scroll_hovered(&mut self, hovered: &bool, _: &mut Window, cx: &mut Context<Self>) {
        if self.scroll.set_list_hovered(*hovered) {
            cx.notify();
        }
    }

    /// The page-header device switcher (harness device-switcher.tsx): a quiet
    /// trigger — platform glyph · name · presence dot · sort glyph — opening a
    /// dropdown of every registered device. Selecting one retargets the page.
    fn render_device_switcher(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        use crate::icons::{self, icon};
        let (mut devices, local_id) = {
            let s = self.state.read(cx);
            (s.devices.clone(), s.local_device_id.clone())
        };
        // Stable row order (registration time, then id) — harness's switcher
        // sorts the same way so rows never reshuffle on heartbeats.
        devices.sort_by(|a, b| {
            a.created_at
                .cmp(&b.created_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        let effective = self.target_device.clone().or_else(|| local_id.clone());
        let selected = devices
            .iter()
            .find(|d| Some(d.id.as_str()) == effective.as_deref())
            .cloned();
        let platform_glyph = |platform: &str| match platform {
            "macos" | "darwin" => icons::LAPTOP,
            "ios" | "android" => icons::SMARTPHONE,
            _ => icons::MONITOR,
        };
        let trigger_glyph = platform_glyph(
            selected
                .as_ref()
                .map(|d| d.platform.as_str())
                .unwrap_or("macos"),
        );
        let trigger_label: SharedString = selected
            .as_ref()
            .map(|d| d.name.clone().into())
            .unwrap_or_else(|| SharedString::from("This device"));
        let emerald = theme.success;
        let open = self.device_menu.is_open();

        let mut trigger =
            div()
                .id("accounts-device-switcher")
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
                .on_mouse_down(
                    gpui::MouseButton::Left,
                    cx.listener(|this, _, _, _| this.device_menu.note_trigger_press()),
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    // A press that found the menu open closes it (the card's
                    // mouse-down-out already began the close) — never reopen.
                    if this.device_menu.take_press_was_open() {
                        this.close_device_menu(cx);
                    } else {
                        this.device_menu.open(());
                    }
                    cx.notify();
                }))
                .child(
                    icon(trigger_glyph)
                        .size(px(16.0))
                        .flex_none()
                        .text_color(theme.text_muted),
                )
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(crate::typography::ui_rems(12.5))
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .text_color(theme.text)
                        .child(trigger_label),
                )
                .child(div().size(px(6.0)).rounded_full().flex_none().bg(
                    if effective == local_id {
                        emerald
                    } else {
                        crate::theme::ink(0.2)
                    },
                ))
                .child(
                    icon(icons::SORT_VERTICAL)
                        .size(px(14.0))
                        .flex_none()
                        .text_color(theme.text_muted.opacity(if open { 0.9 } else { 0.4 })),
                );

        if self.device_menu.get().is_some() {
            let closing = self.device_menu.closing_since();
            let menu = popover::popover_card(theme)
                .w(px(220.0))
                .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                    this.close_device_menu(cx);
                }))
                .flex()
                .flex_col()
                .gap(px(2.0))
                .child(popover::menu_heading(theme, "Devices"))
                .children(devices.into_iter().enumerate().map(|(ix, d)| {
                    let is_active = Some(d.id.as_str()) == effective.as_deref();
                    let is_local = local_id.as_deref() == Some(d.id.as_str());
                    let glyph = platform_glyph(&d.platform);
                    let name: SharedString = d.name.clone().into();
                    let pick_local = is_local;
                    let pick_id = d.id.clone();
                    popover::menu_row(theme, is_active, format!("accounts-device-row-{ix}"))
                        .id(("accounts-device-row", ix))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            // Local device = no passthrough (calls stay direct).
                            let target = (!pick_local).then(|| pick_id.clone());
                            this.set_target_device(target, cx);
                        }))
                        .child(
                            icon(glyph)
                                .size(px(16.0))
                                .flex_none()
                                .text_color(theme.text_muted),
                        )
                        .child(div().flex_1().min_w_0().truncate().child(name))
                        .when(is_local, |el| {
                            el.child(
                                div()
                                    .flex_none()
                                    .text_size(crate::typography::ui_rems(10.5))
                                    .text_color(theme.text_muted.opacity(0.35))
                                    .child(SharedString::from("You")),
                            )
                        })
                        .child(
                            div()
                                .size(px(6.0))
                                .rounded_full()
                                .flex_none()
                                .bg(if is_local {
                                    emerald
                                } else {
                                    crate::theme::ink(0.2)
                                }),
                        )
                }))
                .into_any_element();
            trigger = trigger.child(popover::anchored_menu(
                "accounts-device-menu",
                menu,
                closing,
            ));
        }
        trigger.into_any_element()
    }

    fn load(&mut self, force_usage: bool, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.snapshot = Loadable::Error("Engine not connected".into());
            return;
        };
        self.snapshot = Loadable::Loading;
        self.load_codegraff_usage(cx);
        self.load_codegraff_jobs(cx);
        self.load_graff_logins(cx);
        let params = self.params(serde_json::json!({ "forceUsage": force_usage }));
        self.load_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::LIST_AGENT_ACCOUNTS, params)
                .await;
            this.update(cx, |page, cx| {
                page.snapshot = match result {
                    Ok(value) => match serde_json::from_value::<AgentAccountsSnapshot>(value) {
                        Ok(snapshot) => Loadable::Ready(snapshot),
                        Err(err) => Loadable::Error(err.to_string()),
                    },
                    Err(err) => Loadable::Error(err.to_string()),
                };
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn load_graff_logins(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.graff_logins = Loadable::Error("Engine not connected".into());
            return;
        };
        // Rows stay on screen through a reload; only a first load shows the
        // skeleton.
        if !matches!(self.graff_logins, Loadable::Ready(_)) {
            self.graff_logins = Loadable::Loading;
        }
        let params = self.params(serde_json::json!({}));
        self.graff_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::LIST_GRAFF_LOGINS, params)
                .await;
            this.update(cx, |page, cx| {
                page.graff_logins = match result {
                    Ok(value) => match serde_json::from_value::<Vec<GraffLoginProvider>>(value) {
                        Ok(rows) => Loadable::Ready(rows),
                        Err(err) => Loadable::Error(err.to_string()),
                    },
                    Err(err) => Loadable::Error(err.to_string()),
                };
                cx.notify();
            })
            .ok();
        }));
    }

    fn load_codegraff_usage(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.codegraff_usage = Loadable::Error("Engine not connected".into());
            return;
        };
        self.codegraff_usage = Loadable::Loading;
        let params = self.params(serde_json::json!({}));
        self.codegraff_task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(methods::CODEGRAFF_USAGE, params).await;
            this.update(cx, |page, cx| {
                page.codegraff_usage = match result {
                    Ok(value) => match serde_json::from_value::<Option<CodegraffUsage>>(value) {
                        Ok(usage) => Loadable::Ready(usage),
                        Err(err) => Loadable::Error(err.to_string()),
                    },
                    Err(err) => Loadable::Error(err.to_string()),
                };
                cx.notify();
            })
            .ok();
        }));
    }

    /// The account's recent PR-agent runs. While any is still working, the
    /// list refreshes itself every [`JOBS_POLL`] for as long as the page is
    /// open (the tasks drop with it).
    fn load_codegraff_jobs(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        if matches!(self.codegraff_jobs, Loadable::Idle) {
            self.codegraff_jobs = Loadable::Loading;
        }
        let params = self.params(serde_json::json!({ "limit": JOBS_SHOWN }));
        self.jobs_task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(methods::CODEGRAFF_JOBS, params).await;
            this.update(cx, |page, cx| {
                page.codegraff_jobs = match result {
                    Ok(value) => match serde_json::from_value::<Option<CodegraffJobs>>(value) {
                        Ok(jobs) => Loadable::Ready(jobs),
                        Err(err) => Loadable::Error(err.to_string()),
                    },
                    Err(err) => Loadable::Error(err.to_string()),
                };
                let working = matches!(
                    &page.codegraff_jobs,
                    Loadable::Ready(Some(jobs)) if jobs.jobs.iter().any(job_active)
                );
                page.jobs_poll_task = working.then(|| {
                    cx.spawn(async move |this, cx| {
                        cx.background_executor().timer(JOBS_POLL).await;
                        this.update(cx, |page, cx| page.load_codegraff_jobs(cx))
                            .ok();
                    })
                });
                cx.notify();
            })
            .ok();
        }));
    }

    fn cancel_codegraff_job(&mut self, id: String, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.cancelling_job = Some(id.clone());
        self.error = None;
        let params = self.params(serde_json::json!({ "id": id }));
        self.action_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::CODEGRAFF_CANCEL_JOB, params)
                .await;
            this.update(cx, |page, cx| {
                page.cancelling_job = None;
                if let Err(err) = result {
                    page.error = Some(format!("{err}").into());
                }
                page.load_codegraff_jobs(cx);
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// The PR-agent jobs card; nothing while signed out or with no jobs.
    fn render_codegraff_jobs(&self, theme: &Theme, cx: &mut Context<Self>) -> Option<AnyElement> {
        let Loadable::Ready(Some(jobs)) = &self.codegraff_jobs else {
            return None;
        };
        if jobs.jobs.is_empty() {
            return None;
        }
        let rows = jobs.jobs.iter().enumerate().map(|(ix, job)| {
            let (title, detail) = job_summary(job);
            let cancelling = self.cancelling_job.as_deref() == Some(job.id.as_str());
            let cancel = (job.cancellable && job_active(job)).then(|| {
                let id = job.id.clone();
                widgets::ghost_action(theme)
                    .id(("codegraff-job-cancel", ix))
                    .hover(|s| widgets::ghost_hover(theme, s))
                    .when(cancelling, |el| el.opacity(0.5))
                    .when(!cancelling, |el| {
                        el.on_click(cx.listener(move |page, _, _, cx| {
                            page.cancel_codegraff_job(id.clone(), cx)
                        }))
                    })
                    .child(if cancelling {
                        "Cancelling…"
                    } else {
                        "Cancel"
                    })
            });
            let open = job
                .result_url
                .clone()
                .filter(|url| url.starts_with("https://"))
                .map(|url| {
                    widgets::ghost_action(theme)
                        .id(("codegraff-job-open", ix))
                        .hover(|s| widgets::ghost_hover(theme, s))
                        .on_click(cx.listener(move |_, _, _, cx| cx.open_url(&url)))
                        .child("Open")
                });
            div()
                .id(("codegraff-job", ix))
                .px(px(20.0))
                .py(px(10.0))
                .flex()
                .flex_row()
                .items_center()
                .gap(px(12.0))
                .when(ix > 0, |row| row.border_t_1().border_color(theme.border))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .flex()
                        .flex_col()
                        .child(widgets::row_title(theme, title))
                        .child(
                            div()
                                .mt(px(2.0))
                                .truncate()
                                .text_size(crate::typography::ui_rems(11.5))
                                .text_color(theme.text_muted)
                                .child(detail),
                        ),
                )
                .children(cancel)
                .children(open)
        });
        Some(
            div()
                .mt(px(16.0))
                .flex()
                .flex_col()
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(12.0))
                        .font_weight(gpui::FontWeight::MEDIUM)
                        .text_color(theme.text_muted)
                        .child("PR agent jobs"),
                )
                .child(widgets::section_card(theme).mt(px(8.0)).children(rows))
                .into_any_element(),
        )
    }

    /// Switch / Forget an account.
    fn account_action(
        &mut self,
        method: &'static str,
        account: &AgentAccount,
        cx: &mut Context<Self>,
    ) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.busy_account = Some(account.id.clone());
        self.error = None;
        // Tolerant param shape: both `id` and `accountId` plus the harness.
        let params = self.params(serde_json::json!({
            "id": account.id,
            "accountId": account.id,
            "harness": account.harness,
        }));
        self.action_task = Some(cx.spawn(async move |this, cx| {
            let result = engine.client().call(method, params).await;
            this.update(cx, |page, cx| {
                page.busy_account = None;
                match result {
                    Ok(_) => page.load(force_usage_for(LoadTrigger::PostAction), cx),
                    Err(err) => page.error = Some(format!("{err}").into()),
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    // ---- add-account flows ----

    /// Transcript recovery always supplies the chat's execution host,
    /// including for a local chat. Never use the viewer's current selection.
    pub(crate) fn start_reauth(
        &mut self,
        host: String,
        provider: ReauthProvider,
        cx: &mut Context<Self>,
    ) {
        self.cancel_login(cx);
        self.set_target_device(Some(host), cx);
        let (harness, provider) = reauth_login_route(provider);
        self.begin_login(harness, provider.map(str::to_string), true, cx);
    }

    #[cfg(test)]
    pub(crate) fn login_target(&self) -> Option<&str> {
        self.target_device.as_deref()
    }

    #[cfg(test)]
    pub(crate) fn recovery_params(&self, provider: ReauthProvider) -> serde_json::Value {
        let (harness, provider) = reauth_login_route(provider);
        self.login_params(harness, provider, true)
    }

    fn login_params(
        &self,
        harness: HarnessId,
        provider: Option<&str>,
        reauthenticate: bool,
    ) -> serde_json::Value {
        let mut params = serde_json::json!({ "harness": harness });
        if reauthenticate {
            params["reauthenticate"] = serde_json::json!(true);
            if harness == HarnessId::Codex {
                params["deviceAuth"] = serde_json::json!(true);
            }
        }
        if let Some(provider) = provider {
            params["provider"] = serde_json::json!(provider);
        }
        self.params(params)
    }

    fn start_login(&mut self, harness: HarnessId, cx: &mut Context<Self>) {
        self.begin_login(harness, None, false, cx);
    }

    /// graff's own sign-in for one provider (`xai`, `kimi`, `zai`).
    fn start_graff_login(&mut self, provider: &str, cx: &mut Context<Self>) {
        self.begin_login(HarnessId::Graff, Some(provider.to_string()), false, cx);
    }

    /// Sign out of one graff provider (removes graff's credential on the shown
    /// device); the reply is the refreshed list.
    fn sign_out_graff(&mut self, provider: String, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.busy_graff = Some(provider.clone());
        self.error = None;
        let params = self.params(serde_json::json!({ "provider": provider }));
        self.action_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::SIGN_OUT_GRAFF_LOGIN, params)
                .await;
            this.update(cx, |page, cx| {
                page.busy_graff = None;
                match result.and_then(|value| {
                    serde_json::from_value::<Vec<GraffLoginProvider>>(value)
                        .map_err(|e| harness_rpc::RpcError::Failed(e.to_string()))
                }) {
                    Ok(rows) => page.graff_logins = Loadable::Ready(rows),
                    Err(err) => page.error = Some(format!("Sign out failed: {err}").into()),
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn begin_login(
        &mut self,
        harness: HarnessId,
        provider: Option<String>,
        reauthenticate: bool,
        cx: &mut Context<Self>,
    ) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.error = Some("Engine not connected".into());
            cx.notify();
            return;
        };
        self.login = Some(LoginFlow::Starting {
            harness,
            provider: provider.clone(),
            reauthenticate,
        });
        self.error = None;
        let params = self.login_params(harness, provider.as_deref(), reauthenticate);
        let mut cancel_params = self.params(serde_json::json!({}));
        self.action_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::START_AGENT_LOGIN, params)
                .await
                .and_then(|value| {
                    serde_json::from_value::<AgentLoginStart>(value)
                        .map_err(|e| harness_rpc::RpcError::Failed(e.to_string()))
                });
            let result = match result {
                Ok(start)
                    if reauthenticate
                        && !(harness == HarnessId::Codex && start.is_safe_device_code())
                        && (start.mode != AgentLoginMode::HostBrowser
                            || !start.url.is_empty()
                            || start.code.is_some()
                            || start.login_id.is_empty()) =>
                {
                    cancel_params["loginId"] = serde_json::json!(start.login_id);
                    let _ = engine
                        .client()
                        .call(methods::CANCEL_AGENT_LOGIN, cancel_params)
                        .await;
                    Err(harness_rpc::RpcError::Failed(
                        "Update Harness on the execution device to use desktop sign-in recovery."
                            .into(),
                    ))
                }
                result => result,
            };
            this.update(cx, |page, cx| {
                match result {
                    Ok(start) => {
                        if start.mode != AgentLoginMode::HostBrowser && !start.url.is_empty() {
                            cx.open_url(&start.url);
                        }
                        match start.mode {
                            AgentLoginMode::PasteCode => {
                                page.code_input
                                    .update(cx, |input, cx| input.set_text("", cx));
                                page.login = Some(LoginFlow::PasteCode {
                                    harness,
                                    start,
                                    submitting: false,
                                    error: None,
                                });
                            }
                            AgentLoginMode::Browser
                            | AgentLoginMode::HostBrowser
                            | AgentLoginMode::DeviceCode => {
                                page.login = Some(LoginFlow::Browser {
                                    harness,
                                    provider,
                                    reauthenticate,
                                    start,
                                    message: None,
                                    error: None,
                                });
                                page.spawn_poll(cx);
                            }
                        }
                    }
                    Err(err) => {
                        page.login = None;
                        page.error = Some(format!("Login failed to start: {err}").into());
                    }
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn submit_code(&mut self, cx: &mut Context<Self>) {
        let Some(LoginFlow::PasteCode {
            start, submitting, ..
        }) = &mut self.login
        else {
            return;
        };
        if *submitting {
            return;
        }
        let code = self.code_input.read(cx).text().trim().to_string();
        if code.is_empty() {
            return;
        }
        let login_id = start.login_id.clone();
        *submitting = true;
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let params = self.params(serde_json::json!({ "loginId": login_id, "code": code }));
        self.action_task = Some(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::COMPLETE_AGENT_LOGIN, params)
                .await;
            this.update(cx, |page, cx| {
                match result {
                    Ok(_) => {
                        page.login = None;
                        page.load(force_usage_for(LoadTrigger::PostLogin), cx);
                    }
                    Err(err) => {
                        if let Some(LoginFlow::PasteCode {
                            submitting, error, ..
                        }) = &mut page.login
                        {
                            *submitting = false;
                            *error = Some(format!("{err}").into());
                        }
                    }
                }
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// The browser-wait poll loop: PollAgentLogin every 1.5s until Done/Error.
    fn spawn_poll(&mut self, cx: &mut Context<Self>) {
        let Some(LoginFlow::Browser { start, .. }) = &self.login else {
            return;
        };
        let login_id = start.login_id.clone();
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let params = self.params(serde_json::json!({ "loginId": login_id }));
        self.poll_task = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(1500))
                    .await;
                let result = engine
                    .client()
                    .call(methods::POLL_AGENT_LOGIN, params.clone())
                    .await;
                let outcome = this.update(cx, |page, cx| {
                    let Some(LoginFlow::Browser { message, error, .. }) = &mut page.login else {
                        return true; // dialog dismissed — stop polling
                    };
                    match result.as_ref().ok().and_then(|value| {
                        serde_json::from_value::<AgentLoginPoll>(value.clone()).ok()
                    }) {
                        Some(poll) => match poll.status {
                            AgentLoginStatus::Done => {
                                page.login = None;
                                page.load(force_usage_for(LoadTrigger::PostLogin), cx);
                                cx.notify();
                                true
                            }
                            AgentLoginStatus::Error => {
                                *error = Some(
                                    poll.message
                                        .unwrap_or_else(|| "Login failed".to_string())
                                        .into(),
                                );
                                cx.notify();
                                true
                            }
                            AgentLoginStatus::Pending => {
                                if let Some(text) = poll.message {
                                    *message = Some(text.into());
                                }
                                cx.notify();
                                false
                            }
                        },
                        None => {
                            let text = match &result {
                                Err(err) => format!("Poll failed: {err}"),
                                Ok(_) => "Poll failed: malformed reply".to_string(),
                            };
                            *error = Some(text.into());
                            cx.notify();
                            true
                        }
                    }
                });
                match outcome {
                    Ok(true) | Err(_) => break,
                    Ok(false) => {}
                }
            }
        }));
    }

    fn cancel_login(&mut self, cx: &mut Context<Self>) {
        let login_id = match &self.login {
            Some(LoginFlow::PasteCode { start, .. }) | Some(LoginFlow::Browser { start, .. }) => {
                Some(start.login_id.clone())
            }
            _ => None,
        };
        self.login = None;
        self.poll_task = None;
        self.action_task = None;
        if let (Some(login_id), Some(engine)) = (login_id, self.state.read(cx).engine().cloned()) {
            let params = self.params(serde_json::json!({ "loginId": login_id }));
            cx.spawn(async move |_, _| {
                if let Err(err) = engine
                    .client()
                    .call(methods::CANCEL_AGENT_LOGIN, params)
                    .await
                {
                    tracing::debug!(error = %err, "CancelAgentLogin failed (best-effort)");
                }
            })
            .detach();
        }
        cx.notify();
    }

    // ---- render pieces ----

    /// One usage window (harness settings.agents.tsx `UsageMeter`): label ·
    /// 5px rounded-full bar (indigo → amber ≥80% → red ≥95%) · "NN% used" ·
    /// quiet reset time.
    fn render_usage_meter(
        &self,
        window: &harness_proto::AgentUsageWindow,
        theme: &Theme,
        now: DateTime<Utc>,
    ) -> AnyElement {
        let fraction = window.used_fraction.clamp(0.0, 1.0);
        let level = usage_level(fraction);
        let fill = usage_color(level, theme).opacity(match level {
            UsageLevel::Normal => 0.8,
            _ => 0.85,
        });
        let reset = format_reset(window.resets_at, now);
        div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.0))
            .text_size(crate::typography::ui_rems(11.5))
            .text_color(theme.text_muted.opacity(0.7))
            .child(
                div()
                    .w(px(48.0))
                    .flex_none()
                    .truncate()
                    .child(SharedString::from(window.label.clone())),
            )
            .child(
                div()
                    .flex_1()
                    .min_w(px(56.0))
                    .max_w(px(230.0))
                    .h(px(5.0))
                    .rounded_full()
                    .overflow_hidden()
                    .bg(crate::theme::ink(0.07))
                    .when(fraction > 0.0, |el| {
                        el.child(
                            div()
                                .h_full()
                                // A 1.5% floor keeps tiny non-zero usage
                                // visible (harness `max(used, 1.5)%`).
                                .w(gpui::relative(fraction.max(0.015)))
                                .rounded_full()
                                .bg(fill),
                        )
                    }),
            )
            .child(
                div()
                    .w(px(64.0))
                    .flex_none()
                    .text_right()
                    .child(SharedString::from(format!(
                        "{}% used",
                        (fraction * 100.0).round() as u32
                    ))),
            )
            .when_some(reset, |el, reset| {
                el.child(
                    div()
                        .flex_none()
                        .truncate()
                        .text_color(theme.text_muted.opacity(0.45))
                        .child(SharedString::from(reset)),
                )
            })
            .into_any_element()
    }

    /// One account row (harness settings.agents.tsx `AccountRow`): initial
    /// avatar, email + usage meters left; badges over the Switch/Forget
    /// actions right-anchored.
    fn render_account_row(
        &self,
        account: &AgentAccount,
        ix: usize,
        first: bool,
        theme: &Theme,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_busy = self.busy_account.as_deref() == Some(account.id.as_str());
        let email: SharedString = account
            .email
            .clone()
            .or_else(|| account.display_name.clone())
            .unwrap_or_else(|| "Unknown account".into())
            .into();
        let initial: SharedString = email
            .chars()
            .next()
            .map(|c| c.to_uppercase().to_string())
            .unwrap_or_else(|| "?".into())
            .into();
        let switch_account = account.clone();
        let forget_account = account.clone();

        let badges = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(6.0))
            .when(account.active, |el| {
                el.child(widgets::badge_active(theme, "Active"))
            })
            .when_some(account.plan_label.clone(), |el, plan| {
                el.child(widgets::badge(theme, plan))
            });

        // Actions only on INACTIVE accounts (harness `{!account.active && …}`):
        // an icon-only Forget (trash, hover → foreground) then Switch, which
        // reads "Switching…" while the activate round-trips.
        let actions: Option<gpui::Div> = (!account.active).then(|| {
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .child(
                    div()
                        .id(("account-forget", ix))
                        .rounded(px(6.0))
                        .px(px(6.0))
                        .py(px(4.0))
                        .text_color(theme.text_muted)
                        .cursor_pointer()
                        .when(is_busy, |el| el.opacity(0.5))
                        .hover(|s| s.bg(crate::theme::ink(0.06)).text_color(theme.text))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.account_action(methods::FORGET_AGENT_ACCOUNT, &forget_account, cx);
                        }))
                        .child(
                            crate::icons::icon(crate::icons::TRASH_BIN_MINIMALISTIC)
                                .size(px(14.0))
                                .text_color(theme.text_muted),
                        ),
                )
                .when(account.switchable, |el| {
                    el.child(
                        crate::popover::btn_primary(
                            theme,
                            if is_busy { "Switching…" } else { "Switch" },
                        )
                        .id(("account-switch", ix))
                        .px(px(8.0))
                        .py(px(4.0))
                        .rounded(px(6.0))
                        .text_size(crate::typography::ui_rems(11.5))
                        .when(is_busy, |el| el.opacity(0.5))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.account_action(
                                methods::ACTIVATE_AGENT_ACCOUNT,
                                &switch_account,
                                cx,
                            );
                        })),
                    )
                })
        });

        div()
            .px(px(20.0))
            .py(px(14.0))
            .when(!first, |el| el.border_t_1().border_color(theme.border))
            .flex()
            .flex_row()
            .items_stretch()
            .gap(px(12.0))
            .child(
                // Initial avatar: size-8 rounded-full border bg-white/[0.03].
                div()
                    .flex_none()
                    .self_center()
                    .size(px(32.0))
                    .rounded_full()
                    .border_1()
                    .border_color(theme.border)
                    .bg(crate::theme::ink(0.03))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(crate::typography::ui_rems(12.0))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(theme.text_muted)
                    .child(initial),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(widgets::row_title(theme, email))
                    .map(|el| {
                        // Meters XOR the quiet fallback line — never both
                        // (harness: `usage ? meters : "Usage unavailable"…`).
                        if account.usage_windows.is_empty() {
                            el.child(
                                div()
                                    .mt(px(6.0))
                                    .truncate()
                                    .text_size(crate::typography::ui_rems(11.5))
                                    .text_color(theme.text_muted.opacity(0.6))
                                    .child(SharedString::from(if account.switchable {
                                        "Usage unavailable"
                                    } else {
                                        "Credentials unavailable"
                                    })),
                            )
                        } else {
                            el.child(
                                div().mt(px(6.0)).flex().flex_col().gap(px(4.0)).children(
                                    account
                                        .usage_windows
                                        .iter()
                                        .map(|w| self.render_usage_meter(w, theme, now)),
                                ),
                            )
                        }
                    }),
            )
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_col()
                    .items_end()
                    .justify_between()
                    .gap(px(8.0))
                    .child(badges)
                    .children(actions),
            )
            .into_any_element()
    }

    /// The new ChatGPT route is separate from legacy Codex and remains
    /// available even if an account-list probe fails. Stored credentials are
    /// not evidence that a token is valid; sign-in can always be requested.
    fn render_chatgpt_section(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        div()
            .mt(px(24.0))
            .flex()
            .flex_col()
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.0))
                    .child(
                        crate::icons::icon(crate::icons::OPENAI_MARK)
                            .size(px(16.0))
                            .text_color(theme.text_muted),
                    )
                    .child(widgets::row_title(theme, "ChatGPT (new)")),
            )
            .child(
                widgets::section_card(theme)
                    .mt(px(8.0))
                    .child(self.render_graff_row(
                        1000,
                        Some("chatgpt-new"),
                        "ChatGPT (graff)",
                        "Separate from Codex · graff login chatgpt-new · token validity checked when used".into(),
                        false,
                        theme,
                        cx,
                    )),
            )
            .into_any_element()
    }

    /// graff's other provider sign-ins plus the LEGACY shared Codex login.
    /// Credential detection here does not validate the stored token.
    fn render_graff_logins_section(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let header = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.0))
            .child(
                div()
                    .size(px(24.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        crate::icons::icon(crate::icons::GRAFF_MARK)
                            .size(px(16.0))
                            .text_color(theme.text_muted),
                    ),
            )
            .child(
                div()
                    .text_size(crate::typography::ui_rems(14.0))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(theme.text)
                    .child("graff providers"),
            );

        let body: AnyElement = match &self.graff_logins {
            Loadable::Idle | Loadable::Loading => {
                self.render_skeleton_row(("graff-logins", 0), false, true, theme, cx)
            }
            Loadable::Error(error) => div()
                .px(px(20.0))
                .py(px(24.0))
                .text_size(crate::typography::ui_rems(12.0))
                .text_color(theme.text_muted)
                .child(format!("graff sign-ins unavailable: {error}"))
                .into_any_element(),
            Loadable::Ready(providers) => {
                let openai = match self.snapshot.ready() {
                    None => "Checking…".to_string(),
                    Some(snapshot) => match openai_login(snapshot) {
                        (true, Some(who)) => {
                            format!("Credentials stored for {who} · legacy Codex login")
                        }
                        (true, None) => "Credentials stored · legacy Codex login".to_string(),
                        (false, _) => "Not signed in — add a Codex account below".to_string(),
                    },
                };
                let openai_signed_in = self
                    .snapshot
                    .ready()
                    .is_some_and(|snapshot| openai_login(snapshot).0);
                // (provider id — `None` for the shared Codex login —, name,
                // status line, signed in)
                let mut entries: Vec<(Option<&str>, &str, String, bool)> = providers
                    .iter()
                    .filter(|p| p.id != "chatgpt-new")
                    .map(|p| {
                        let status = if p.signed_in {
                            "Signed in on this device"
                        } else {
                            "Not signed in"
                        };
                        (
                            Some(p.id.as_str()),
                            p.name.as_str(),
                            status.to_string(),
                            p.signed_in,
                        )
                    })
                    .collect();
                entries.insert(
                    entries.len().min(1),
                    (None, "ChatGPT (legacy Codex)", openai, openai_signed_in),
                );
                div()
                    .children(entries.into_iter().enumerate().map(
                        |(ix, (provider, name, status, signed_in))| {
                            self.render_graff_row(ix, provider, name, status, signed_in, theme, cx)
                        },
                    ))
                    .into_any_element()
            }
        };
        div()
            .mt(px(24.0))
            .flex()
            .flex_col()
            .child(header)
            .child(widgets::section_card(theme).mt(px(8.0)).child(body))
            .into_any_element()
    }

    #[allow(clippy::too_many_arguments)]
    fn render_graff_row(
        &self,
        ix: usize,
        provider: Option<&str>,
        name: &str,
        status: String,
        signed_in: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let initial: SharedString = name
            .chars()
            .next()
            .map(|c| c.to_uppercase().to_string())
            .unwrap_or_else(|| "?".into())
            .into();
        let busy = provider.is_some() && self.busy_graff.as_deref() == provider;
        let actions = provider.map(str::to_string).map(|id| {
            let sign_out_id = id.clone();
            div()
                .flex()
                .flex_row()
                .items_center()
                .gap(px(4.0))
                .when(signed_in, |el| {
                    el.child(
                        div()
                            .id(("graff-signout", ix))
                            .rounded(px(6.0))
                            .px(px(6.0))
                            .py(px(4.0))
                            .text_color(theme.text_muted)
                            .cursor_pointer()
                            .when(busy, |el| el.opacity(0.5))
                            .hover(|s| s.bg(crate::theme::ink(0.06)).text_color(theme.text))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.sign_out_graff(sign_out_id.clone(), cx);
                            }))
                            .child(
                                crate::icons::icon(crate::icons::TRASH_BIN_MINIMALISTIC)
                                    .size(px(14.0))
                                    .text_color(theme.text_muted),
                            ),
                    )
                })
                .child(
                    crate::popover::btn_primary(
                        theme,
                        if signed_in {
                            "Sign in again"
                        } else {
                            "Sign in"
                        },
                    )
                    .id(("graff-signin", ix))
                    .px(px(8.0))
                    .py(px(4.0))
                    .rounded(px(6.0))
                    .text_size(crate::typography::ui_rems(11.5))
                    .when(busy, |el| el.opacity(0.5))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.start_graff_login(&id, cx);
                    })),
                )
        });
        div()
            .px(px(20.0))
            .py(px(14.0))
            .when(ix > 0, |el| el.border_t_1().border_color(theme.border))
            .flex()
            .flex_row()
            .items_center()
            .gap(px(12.0))
            .child(
                div()
                    .flex_none()
                    .size(px(32.0))
                    .rounded_full()
                    .border_1()
                    .border_color(theme.border)
                    .bg(crate::theme::ink(0.03))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(crate::typography::ui_rems(12.0))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(theme.text_muted)
                    .child(initial),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .child(widgets::row_title(
                        theme,
                        SharedString::from(name.to_string()),
                    ))
                    .child(
                        div()
                            .mt(px(4.0))
                            .truncate()
                            .text_size(crate::typography::ui_rems(11.5))
                            .text_color(theme.text_muted.opacity(0.6))
                            .child(SharedString::from(status)),
                    ),
            )
            .child(
                div()
                    .flex_none()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(8.0))
                    .when(signed_in, |el| {
                        el.child(widgets::badge_active(theme, "Signed in"))
                    })
                    .children(actions),
            )
            .into_any_element()
    }

    fn render_codegraff_section(
        &self,
        theme: &Theme,
        now: DateTime<Utc>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let header = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(8.0))
            .child(
                div()
                    .size(px(24.0))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(
                        crate::icons::icon(crate::icons::GRAFF_MARK)
                            .size(px(16.0))
                            .text_color(theme.text_muted),
                    ),
            )
            .child(
                div()
                    .text_size(crate::typography::ui_rems(14.0))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(theme.text)
                    .child("CodeGraff"),
            )
            .child(div().flex_1())
            .child(
                widgets::ghost_action(theme)
                    .id("codegraff-view-usage")
                    .hover(|s| widgets::ghost_hover(theme, s))
                    .on_click(cx.listener(|_, _, _, cx| {
                        cx.open_url("https://codegraff.com/dashboard/usage")
                    }))
                    .child("View usage"),
            );

        let body: AnyElement = match &self.codegraff_usage {
            Loadable::Idle | Loadable::Loading => {
                self.render_skeleton_row(("codegraff-usage", 0), false, true, theme, cx)
            }
            Loadable::Error(error) => div()
                .px(px(20.0))
                .py(px(24.0))
                .text_size(crate::typography::ui_rems(12.0))
                .text_color(theme.text_muted)
                .child(format!("CodeGraff usage unavailable: {error}"))
                .into_any_element(),
            Loadable::Ready(None) => div()
                .px(px(20.0))
                .py(px(24.0))
                .text_size(crate::typography::ui_rems(13.0))
                .text_color(theme.text_muted)
                .child("Sign in with Codegraff from the account menu to see your usage.")
                .into_any_element(),
            Loadable::Ready(Some(usage)) => {
                let initial: SharedString = usage
                    .email
                    .chars()
                    .next()
                    .map(|c| c.to_uppercase().to_string())
                    .unwrap_or_else(|| "?".into())
                    .into();
                let budget_meter = usage.key_budget_monthly_micro_usd.map(|limit| {
                    let resets_at = DateTime::parse_from_rfc3339(&usage.key_budget_resets_at)
                        .ok()
                        .map(|at| at.with_timezone(&Utc));
                    harness_proto::AgentUsageWindow {
                        label: "Key budget".into(),
                        used_fraction: if limit <= 0 {
                            1.0
                        } else {
                            (usage.key_spend_monthly_micro_usd as f64 / limit as f64)
                                .clamp(0.0, 1.0) as f32
                        },
                        resets_at,
                    }
                });
                div()
                    .px(px(20.0))
                    .py(px(14.0))
                    .flex()
                    .flex_row()
                    .items_stretch()
                    .gap(px(12.0))
                    .child(
                        div()
                            .flex_none()
                            .self_center()
                            .size(px(32.0))
                            .rounded_full()
                            .border_1()
                            .border_color(theme.border)
                            .bg(crate::theme::ink(0.03))
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_size(crate::typography::ui_rems(12.0))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(theme.text_muted)
                            .child(initial),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .child(widgets::row_title(theme, usage.email.clone()))
                            .child(
                                div()
                                    .mt(px(6.0))
                                    .flex()
                                    .flex_col()
                                    .gap(px(4.0))
                                    .text_size(crate::typography::ui_rems(11.5))
                                    .text_color(theme.text_muted)
                                    .child("Graff CLI account on this device")
                                    .child(format!(
                                        "{} credits available",
                                        format_micro_usd(usage.credits_micro_usd)
                                    ))
                                    .child(format!(
                                        "{} spent · {} requests in 30 days",
                                        format_micro_usd(usage.spend_30d_micro_usd),
                                        usage.requests_30d
                                    ))
                                    .when_some(budget_meter, |el, meter| {
                                        el.child(self.render_usage_meter(&meter, theme, now))
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .flex_none()
                            .flex()
                            .flex_row()
                            .items_start()
                            .gap(px(6.0))
                            .child(widgets::badge_active(theme, "Active"))
                            .child(widgets::badge(theme, usage.tier.clone())),
                    )
                    .into_any_element()
            }
        };

        div()
            .mt(px(24.0))
            .flex()
            .flex_col()
            .child(header)
            .child(widgets::section_card(theme).mt(px(8.0)).child(body))
            .children(self.render_codegraff_jobs(theme, cx))
            .into_any_element()
    }

    /// Copy the sign-in link for a browser other than the one that opened.
    fn copy_login_url(&mut self, url: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(url));
        self.login_url_copied = true;
        self.copy_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1500))
                .await;
            this.update(cx, |page, cx| {
                page.login_url_copied = false;
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    fn render_login_dialog(
        &mut self,
        viewport: gpui::Size<gpui::Pixels>,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let theme = Theme::of(cx).for_popup();
        let red_text = theme.danger_muted.opacity(0.9); // red-300
        let login = self.login.as_ref()?;
        let title = login.title();
        let url_link =
            |id: &'static str, label: &'static str, url: &str, cx: &mut Context<Self>| {
                let open_url = url.to_string();
                // "Reopen the …" text link (harness: `text-[12px]
                // text-muted-foreground/60 hover:underline`).
                div()
                    .id(id)
                    .mt(px(6.0))
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .truncate()
                    .cursor_pointer()
                    .hover(|s| s.text_color(theme.text))
                    .on_click(cx.listener(move |_, _, _, cx| {
                        cx.open_url(&open_url);
                    }))
                    .child(SharedString::from(label))
            };
        let copied = self.login_url_copied;
        // The link itself, for signing in from a browser other than the one
        // that opened: dialog text isn't selectable, so it comes with Copy.
        let url_field = |url: &str, cx: &mut Context<Self>| {
            let copy_url = url.to_string();
            div()
                .mt(px(12.0))
                .flex()
                .flex_col()
                .gap(px(6.0))
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.text_muted)
                        .child(SharedString::from("Or copy this link into any browser")),
                )
                .child(
                    div()
                        .flex()
                        .flex_row()
                        .items_center()
                        .gap(px(8.0))
                        .pl(px(10.0))
                        .pr(px(4.0))
                        .py(px(4.0))
                        .rounded(px(8.0))
                        .border_1()
                        .border_color(theme.border)
                        .bg(crate::theme::ink(0.03))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .font_family(theme.font_mono.clone())
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(theme.text)
                                .child(SharedString::from(url.to_string())),
                        )
                        .child(
                            popover::btn_ghost(
                                &theme,
                                if copied { "Copied" } else { "Copy" },
                                "login-copy-url",
                            )
                            .id("login-copy-url")
                            .flex_none()
                            .py(px(3.0))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.copy_login_url(copy_url.clone(), cx)
                            })),
                        ),
                )
        };
        let body: AnyElement = match login {
            LoginFlow::Starting { .. } => div()
                .mt(px(8.0))
                .child(popover::skeleton_rows(
                    "login-starting",
                    &theme,
                    2,
                    cx.entity_id(),
                    cx,
                ))
                .into_any_element(),
            LoginFlow::PasteCode {
                start,
                submitting,
                error,
                ..
            } => {
                let submitting = *submitting;
                div()
                    .flex()
                    .flex_col()
                    .child(div().mt(px(8.0)).child(popover::dialog_body(
                        &theme,
                        "A browser window opened. Sign in to the account you want to add, \
                         approve access, then paste the code Anthropic shows you below. Your \
                         current login is untouched until you switch.",
                    )))
                    .child(url_link(
                        "login-open-url",
                        "Reopen the authorization page",
                        &start.url,
                        cx,
                    ))
                    .child(url_field(&start.url, cx))
                    .child(
                        div().mt(px(12.0)).child(
                            popover::dialog_field(self.code_input.clone().into_any_element())
                                .font_family(theme.font_mono.clone())
                                .text_size(crate::typography::ui_rems(13.0)),
                        ),
                    )
                    .when_some(error.clone(), |el, message| {
                        el.child(
                            div()
                                .mt(px(8.0))
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(red_text)
                                .child(message),
                        )
                    })
                    .child(
                        div()
                            .mt(px(16.0))
                            .flex()
                            .flex_row()
                            .justify_end()
                            .gap(px(8.0))
                            .child(
                                popover::btn_ghost(&theme, "Cancel", "login-cancel")
                                    .id("login-cancel")
                                    .on_click(cx.listener(|this, _, _, cx| this.cancel_login(cx))),
                            )
                            .child(
                                popover::btn_primary(
                                    &theme,
                                    if submitting {
                                        "Verifying…"
                                    } else {
                                        "Add account"
                                    },
                                )
                                .id("login-submit-code")
                                .when(submitting, |el| el.opacity(0.5))
                                .on_click(cx.listener(|this, _, _, cx| this.submit_code(cx))),
                            ),
                    )
                    .into_any_element()
            }
            LoginFlow::Browser {
                harness,
                provider,
                reauthenticate,
                start,
                message,
                error,
            } => {
                let has_error = error.is_some();
                let body: SharedString = if start.mode == AgentLoginMode::DeviceCode {
                    "Open the ChatGPT sign-in page and enter the one-time code below. \
                     You can approve on this device or your iPhone. Credentials are saved \
                     only on the execution device shown above, and your failed turn is not replayed."
                        .into()
                } else if start.mode == AgentLoginMode::HostBrowser {
                    "Complete sign-in in the browser on the execution device shown above. \
                     ChatGPT's local callback must finish on that desktop. Your failed turn \
                     will not be sent again automatically."
                        .into()
                } else {
                    match harness {
                        HarnessId::Cursor => {
                            "Finish signing in to Cursor in your browser. This mints a \
                         harness-named API key you can revoke any time from Cursor's \
                         dashboard — it is separate from `cursor-agent login`."
                                .into()
                        }
                        HarnessId::Graff => format!(
                            "Finish signing in to {} in your browser. graff saves the login \
                         itself, so nothing is copied into Harness.",
                            graff_provider_name(provider.as_deref())
                        )
                        .into(),
                        HarnessId::Codex if *reauthenticate => {
                            "Finish signing in to ChatGPT in your browser. The renewed login \
                         replaces the expired Codex login on this device. Your failed turn \
                         will not be sent again automatically."
                                .into()
                        }
                        _ => "Finish signing in to OpenAI in your browser. The new login is \
                         captured in an isolated profile — your current session is untouched \
                         until you switch."
                            .into(),
                    }
                };
                div()
                    .flex()
                    .flex_col()
                    .child(div().mt(px(8.0)).child(popover::dialog_body(&theme, body)))
                    // Device-code sign-ins (xAI, Kimi): the page asks for this.
                    .when_some(start.code.clone(), |el, code| {
                        el.child(
                            div()
                                .mt(px(12.0))
                                .flex()
                                .flex_col()
                                .gap(px(6.0))
                                .child(
                                    div()
                                        .text_size(crate::typography::ui_rems(12.0))
                                        .text_color(theme.text_muted)
                                        .child(SharedString::from("Confirm this code on the page")),
                                )
                                .child(
                                    div()
                                        .self_start()
                                        .px(px(12.0))
                                        .py(px(8.0))
                                        .rounded(px(8.0))
                                        .border_1()
                                        .border_color(theme.border)
                                        .bg(crate::theme::ink(0.03))
                                        .font_family(theme.font_mono.clone())
                                        .text_size(crate::typography::ui_rems(18.0))
                                        .font_weight(gpui::FontWeight::SEMIBOLD)
                                        .text_color(theme.text)
                                        .child(SharedString::from(code)),
                                ),
                        )
                    })
                    .when(!start.url.is_empty(), |el| {
                        el.child(url_link(
                            "login-open-url-browser",
                            "Reopen the sign-in page",
                            &start.url,
                            cx,
                        ))
                        .child(url_field(&start.url, cx))
                    })
                    .when(!has_error, |el| {
                        el.child(
                            div()
                                .mt(px(16.0))
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(8.0))
                                .child(crate::loaders::gradient_spinner(
                                    "login-poll",
                                    &theme,
                                    3.0,
                                    cx.entity_id(),
                                    cx,
                                ))
                                .child(
                                    div()
                                        .text_size(crate::typography::ui_rems(12.5))
                                        .text_color(theme.text_muted)
                                        .child(message.clone().unwrap_or_else(|| {
                                            SharedString::from("Waiting for the browser…")
                                        })),
                                ),
                        )
                    })
                    .when_some(error.clone(), |el, message| {
                        el.child(
                            div()
                                .mt(px(12.0))
                                .text_size(crate::typography::ui_rems(12.0))
                                .text_color(red_text)
                                .child(message),
                        )
                    })
                    .child(
                        div().mt(px(16.0)).flex().flex_row().justify_end().child(
                            popover::btn_ghost(
                                &theme,
                                if has_error { "Close" } else { "Cancel" },
                                "login-cancel",
                            )
                            .id("login-cancel")
                            .on_click(cx.listener(|this, _, _, cx| this.cancel_login(cx))),
                        ),
                    )
                    .into_any_element()
            }
        };
        let host = self.target_device.as_deref().map(|id| {
            self.state
                .read(cx)
                .device_name(id)
                .unwrap_or(id)
                .to_string()
        });
        let card = popover::dialog_card(&theme)
            .child(popover::dialog_title(&theme, &title))
            .when_some(host, |el, host| {
                el.child(popover::dialog_body(
                    &theme,
                    format!("Signing in on {host}"),
                ))
            })
            .child(body)
            .into_any_element();
        Some(popover::modal("add-account-dialog", viewport, card))
    }

    /// A ghost account row (harness settings.agents.tsx `SkeletonRow`): avatar,
    /// email line, two usage-meter ghosts, a badge — same geometry as the real
    /// row so loaded data lands without a layout jump. `dim` fades row two.
    fn render_skeleton_row(
        &self,
        _id: (&'static str, usize),
        dim: bool,
        first: bool,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        use crate::motion;
        let delta = motion::pulse_delta(&motion::HARNESS_PULSE, cx.entity_id(), cx);
        let ghost = |w: gpui::Length, h: f32, round_full: bool| {
            div()
                .w(w)
                .h(px(h))
                .flex_none()
                .map(|el| {
                    if round_full {
                        el.rounded_full()
                    } else {
                        el.rounded(px(4.0))
                    }
                })
                .bg(crate::theme::ink(0.05))
        };
        let meters = div()
            .mt(px(8.0))
            .flex()
            .flex_col()
            .gap(px(7.0))
            .children((0..2).map(|_| {
                div()
                    .flex()
                    .flex_row()
                    .items_center()
                    .gap(px(8.0))
                    .child(ghost(px(48.0).into(), 9.0, false))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(56.0))
                            .max_w(px(230.0))
                            .h(px(5.0))
                            .rounded_full()
                            .bg(crate::theme::ink(0.04)),
                    )
                    .child(ghost(px(64.0).into(), 9.0, false))
            }));
        let inner = div()
            .flex()
            .flex_row()
            .items_stretch()
            .gap(px(12.0))
            .child(
                div()
                    .flex_none()
                    .self_center()
                    .size(px(32.0))
                    .rounded_full()
                    .bg(crate::theme::ink(0.05)),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .child(ghost(px(176.0).into(), 13.0, false).max_w(gpui::relative(0.6)))
                    .child(meters),
            )
            .child(div().flex_none().flex().flex_col().items_end().child(ghost(
                px(64.0).into(),
                21.0,
                true,
            )));
        div()
            .px(px(20.0))
            .py(px(14.0))
            .when(!first, |el| el.border_t_1().border_color(theme.border))
            .when(dim, |el| el.opacity(0.6))
            .child(inner.opacity(0.55 + 0.35 * motion::pulse_wave(delta)))
            .into_any_element()
    }
}

impl popover::ScrollRailHost for AccountsPage {
    fn rail_bar(&mut self) -> &mut popover::MenuScrollbarState {
        self.scroll.rail_bar()
    }

    fn rail_scroll(&self) -> Option<gpui::ScrollHandle> {
        self.scroll.rail_scroll()
    }
}

impl Render for AccountsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let now = Utc::now();
        let dialog = self.render_login_dialog(window.viewport_size(), cx);
        let refreshing = matches!(self.snapshot, Loadable::Loading);
        let account_count = self
            .snapshot
            .ready()
            .map(|s| {
                s.accounts.len()
                    + usize::from(matches!(self.codegraff_usage, Loadable::Ready(Some(_))))
            })
            .filter(|&n| n > 0);

        let provider_icon = |harness: HarnessId| match harness {
            HarnessId::Codex => (crate::icons::OPENAI_MARK, None),
            HarnessId::Cursor => (crate::icons::CURSOR_MARK, None),
            HarnessId::Devin => (crate::icons::DEVIN_MARK, None),
            HarnessId::Grok => (crate::icons::GROK_MARK, None),
            HarnessId::Hermes => (crate::icons::HERMES_MARK, None),
            HarnessId::Pi => (crate::icons::PI_MARK, None),
            HarnessId::Opencode => (crate::icons::OPENCODE_MARK, None),
            HarnessId::Antigravity => (crate::icons::ANTIGRAVITY_MARK, None),
            HarnessId::Exo => (crate::icons::EXO_MARK, None),
            _ => (
                crate::icons::CLAUDE_MARK,
                Some(crate::icons::claude_brand()),
            ),
        };
        // Brand mark inside a 24px centered box (harness: `grid size-6
        // place-items-center [&_svg]:size-4`).
        let provider_mark = |harness: HarnessId, theme: &Theme| {
            let (mark, tint) = provider_icon(harness);
            div()
                .flex_none()
                .size(px(24.0))
                .flex()
                .items_center()
                .justify_center()
                .child(
                    crate::icons::icon(mark)
                        .size(px(16.0))
                        .text_color(tint.unwrap_or(theme.text_muted)),
                )
        };

        // One section per provider (harness settings.agents.tsx `ProviderSection`):
        // brand header + Add account, then the account rows card.
        let sections: Vec<AnyElement> = match &self.snapshot {
            Loadable::Idle | Loadable::Loading => PROVIDERS
                .into_iter()
                .map(|(harness, name, _cli)| {
                    let skeleton_id = match harness {
                        HarnessId::Codex => "accounts-skeleton-codex",
                        HarnessId::Cursor => "accounts-skeleton-cursor",
                        _ => "accounts-skeleton-claude",
                    };
                    div()
                        .mt(px(24.0))
                        .flex()
                        .flex_col()
                        .child(
                            div()
                                .flex()
                                .flex_row()
                                .items_center()
                                .gap(px(8.0))
                                .child(provider_mark(harness, &theme))
                                .child(
                                    div()
                                        .text_size(crate::typography::ui_rems(14.0))
                                        .font_weight(gpui::FontWeight::MEDIUM)
                                        .text_color(theme.text)
                                        .child(SharedString::from(name)),
                                ),
                        )
                        .child(
                            // Ghost rows shaped like real ones (row two dimmed)
                            // so the card keeps its size while data develops.
                            widgets::section_card(&theme)
                                .mt(px(8.0))
                                .child(self.render_skeleton_row(
                                    (skeleton_id, 0),
                                    false,
                                    true,
                                    &theme,
                                    cx,
                                ))
                                .child(self.render_skeleton_row(
                                    (skeleton_id, 1),
                                    true,
                                    false,
                                    &theme,
                                    cx,
                                )),
                        )
                        .into_any_element()
                })
                .collect(),
            Loadable::Error(message) => {
                let message = message.clone();
                vec![
                    widgets::error_strip(&theme, message)
                        .id("accounts-load-error")
                        .cursor_pointer()
                        .on_click(cx.listener(|this, _, _, cx| {
                            // Retry IS the visit's first successful list — force usage.
                            this.load(force_usage_for(LoadTrigger::Retry), cx)
                        }))
                        .child(
                            div()
                                .mt(px(4.0))
                                .text_size(crate::typography::ui_rems(11.5))
                                .text_color(theme.text_muted)
                                .child(SharedString::from("Click to retry")),
                        )
                        .into_any_element(),
                ]
            }
            Loadable::Ready(snapshot) => {
                let snapshot = snapshot.clone();
                PROVIDERS
                    .into_iter()
                    .map(|(harness, name, cli)| {
                        let accounts = provider_accounts(&snapshot, harness);
                        // EVERY warning renders its own strip (harness maps them).
                        let warnings: Vec<String> = snapshot
                            .warnings
                            .iter()
                            .filter(|w| w.harness == harness)
                            .map(|w| w.message.clone())
                            .collect();
                        let rows: Vec<AnyElement> = accounts
                            .iter()
                            .enumerate()
                            .map(|(ix, account)| {
                                self.render_account_row(account, ix, ix == 0, &theme, now, cx)
                            })
                            .collect();
                        let add_id: SharedString = format!("add-account-{name}").into();
                        let card = widgets::section_card(&theme).mt(px(8.0));
                        let empty_copy = match harness {
                            // Cursor's app login is SEPARATE from `cursor-agent
                            // login` — pointing at the CLI would send users to a
                            // sign-in that does not light this up.
                            HarnessId::Cursor => format!(
                                "{name} isn't connected on this device — connect it to run \
                                 Cursor sessions."
                            ),
                            _ => format!(
                                "No {name} login detected on this device — sign in \
                                 with \u{201C}{cli}\u{201D} or add an account."
                            ),
                        };
                        let card = if rows.is_empty() {
                            card.child(
                                div()
                                    .px(px(20.0))
                                    .py(px(32.0))
                                    .text_center()
                                    .text_size(crate::typography::ui_rems(14.0))
                                    .text_color(theme.text_muted.opacity(0.6))
                                    .child(SharedString::from(empty_copy)),
                            )
                        } else {
                            card.children(rows)
                        };
                        div()
                            .mt(px(24.0))
                            .flex()
                            .flex_col()
                            .child(
                                div()
                                    .flex()
                                    .flex_row()
                                    .items_center()
                                    .gap(px(8.0))
                                    .child(provider_mark(harness, &theme))
                                    .child(
                                        div()
                                            .text_size(crate::typography::ui_rems(14.0))
                                            .font_weight(gpui::FontWeight::MEDIUM)
                                            .text_color(theme.text)
                                            .child(SharedString::from(name)),
                                    )
                                    .child(div().flex_1())
                                    .child(
                                        widgets::ghost_action(&theme)
                                            .id(add_id)
                                            .hover(|s| widgets::ghost_hover(&theme, s))
                                            .on_click(cx.listener(move |this, _, _, cx| {
                                                this.start_login(harness, cx);
                                            }))
                                            .child(
                                                crate::icons::icon(crate::icons::ADD_CIRCLE)
                                                    .size(px(16.0))
                                                    .text_color(theme.text_muted),
                                            )
                                            .child(SharedString::from("Add account")),
                                    ),
                            )
                            .children(
                                warnings
                                    .into_iter()
                                    .map(|warning| widgets::warning_strip(&theme, warning)),
                            )
                            .child(card)
                            .into_any_element()
                    })
                    .collect()
            }
        };

        let scrollbar = popover::rail(self, "accounts-page-scrollbar", &theme, cx);
        div()
            .id("accounts-page-host")
            .relative()
            .size_full()
            .on_hover(cx.listener(Self::on_scroll_hovered))
            .child(
                div()
                    .id("accounts-page")
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
                                    .gap(px(10.0))
                                    .child(widgets::page_header(&theme, "Accounts", account_count))
                                    .child(div().flex_1())
                                    .child(
                                        // `text-[12.5px]` + leading 16px Refresh icon,
                                        // dimmed while a refresh is in flight (harness
                                        // `disabled:opacity-50`).
                                        widgets::ghost_action(&theme)
                                            .id("accounts-refresh")
                                            .flex_none()
                                            .text_size(crate::typography::ui_rems(12.5))
                                            .hover(|s| widgets::ghost_hover(&theme, s))
                                            .when(refreshing, |el| el.opacity(0.5))
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.load(
                                                    force_usage_for(LoadTrigger::Refresh),
                                                    cx,
                                                )
                                            }))
                                            .child(
                                                crate::icons::icon(crate::icons::REFRESH)
                                                    .size(px(16.0))
                                                    .text_color(theme.text_muted),
                                            )
                                            .child(SharedString::from("Refresh")),
                                    )
                                    .child(self.render_device_switcher(&theme, cx)),
                            )
                            .child(widgets::page_subtitle(
                                &theme,
                                "CodeGraff usage, graff's provider sign-ins, and the Claude Code, Codex, and Cursor logins on this device. Harness keeps local agent logins backed up and can swap between them.",
                            ))
                            .when_some(self.error.clone(), |el, message| {
                                el.child(
                                    widgets::error_strip(&theme, message)
                                        .id("accounts-action-error")
                                        .cursor_pointer()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.error = None;
                                            cx.notify();
                                        })),
                                )
                            })
                            .child(self.render_codegraff_section(&theme, now, cx))
                            .child(self.render_chatgpt_section(&theme, cx))
                            .child(self.render_graff_logins_section(&theme, cx))
                            .children(sections)
                            // Footer note (harness: `mt-6 text-[12px] leading-relaxed
                            // text-muted-foreground/60`).
                            .child(
                                div()
                                    .mt(px(24.0))
                                    .text_size(crate::typography::ui_rems(12.0))
                                    .line_height(px(19.0))
                                    .text_color(theme.text_muted.opacity(0.6))
                                    .child(SharedString::from(
                                        "Switching rewrites the CLI\u{2019}s stored login, so new \
                                         agent sessions use the selected account immediately. On \
                                         macOS, an already-running Claude Code can hold the previous \
                                         login for up to ~30 seconds (Keychain cache).",
                                    )),
                            ),
                    ),
            )
            .children(scrollbar)
            .when_some(dialog, |el, dialog| el.child(dialog))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeDelta;

    fn job(value: serde_json::Value) -> CodegraffJob {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn job_rows_name_the_pr_and_where_the_run_is() {
        let running = job(serde_json::json!({
            "id": "j1", "kind": "pr_review", "status": "running", "step": "posting",
            "cancellable": false, "repo": "acme/api", "pr": 42, "title": "Fix login",
            "unknown_field": true,
        }));
        assert!(job_active(&running));
        assert_eq!(
            job_summary(&running),
            ("Fix login".into(), "acme/api #42 · Posting…".into())
        );

        // No title falls back to the kind; a failure carries its reason.
        let failed = job(serde_json::json!({
            "id": "j2", "kind": "pr_describe", "status": "error", "error": "no access",
        }));
        assert!(!job_active(&failed));
        assert_eq!(
            job_summary(&failed),
            (
                "PR description".into(),
                "PR description · Failed: no access".into()
            )
        );

        let queued = job(serde_json::json!({"id": "j3", "status": "pending", "pr": "#7"}));
        assert!(job_active(&queued));
        assert_eq!(job_summary(&queued).1, "#7 · Queued");
    }

    #[test]
    fn first_load_of_a_visit_forces_the_usage_probe() {
        // The engine only probes usage when forced (M5c); without forcing on
        // mount, the first Accounts open always rendered "Usage unavailable".
        assert!(force_usage_for(LoadTrigger::Mount));
        // A retry after a failed load is still the visit's first successful
        // list — same requirement.
        assert!(force_usage_for(LoadTrigger::Retry));
        // Explicit refresh and a just-completed login always re-probe.
        assert!(force_usage_for(LoadTrigger::Refresh));
        assert!(force_usage_for(LoadTrigger::PostLogin));
        // Switch/Forget re-lists ride the still-warm 60s cache.
        assert!(!force_usage_for(LoadTrigger::PostAction));
    }

    #[test]
    fn usage_thresholds_match_harness() {
        assert_eq!(usage_level(0.0), UsageLevel::Normal);
        assert_eq!(usage_level(0.79), UsageLevel::Normal);
        assert_eq!(usage_level(0.80), UsageLevel::Warn);
        assert_eq!(usage_level(0.94), UsageLevel::Warn);
        assert_eq!(usage_level(0.95), UsageLevel::Critical);
        assert_eq!(usage_level(1.0), UsageLevel::Critical);
    }

    #[test]
    fn usage_colors_map_to_theme_accents() {
        let theme = Theme::dark();
        assert_eq!(usage_color(UsageLevel::Normal, &theme), theme.accent);
        assert_eq!(usage_color(UsageLevel::Warn, &theme), theme.warning);
        assert_eq!(usage_color(UsageLevel::Critical, &theme), theme.danger);
    }

    #[test]
    fn reset_formatting_is_absolute() {
        use chrono::Local;
        let now = Utc::now();
        assert_eq!(format_reset(None, now), None);
        // Within ~22h: a local clock time ("resets 3:45 PM").
        let soon = now + TimeDelta::minutes(125);
        assert_eq!(
            format_reset(Some(soon), now),
            Some(format!(
                "resets {}",
                soon.with_timezone(&Local).format("%-I:%M %p")
            ))
        );
        // Within a week: a short weekday ("resets Mon").
        let later = now + TimeDelta::days(3);
        assert_eq!(
            format_reset(Some(later), now),
            Some(format!(
                "resets {}",
                later.with_timezone(&Local).format("%a")
            ))
        );
        // Beyond a week (Codex free tier resets ~monthly): month + day
        // ("resets Sep 14") — a weekday 4 weeks out carries no information.
        let monthly = now + TimeDelta::days(26);
        assert_eq!(
            format_reset(Some(monthly), now),
            Some(format!(
                "resets {}",
                monthly.with_timezone(&Local).format("%b %-d")
            ))
        );
    }

    #[test]
    fn provider_grouping_keeps_engine_order_even_when_active_is_later() {
        let account = |id: &str, harness: HarnessId, active: bool| AgentAccount {
            id: id.into(),
            harness,
            email: None,
            plan_label: None,
            active,
            usage_windows: vec![],
            display_name: None,
            organization: None,
            auth_kind: None,
            switchable: true,
            saved_at: None,
        };
        let snapshot = AgentAccountsSnapshot {
            accounts: vec![
                account("c1", HarnessId::ClaudeCode, false),
                account("x1", HarnessId::Codex, false),
                account("c2", HarnessId::ClaudeCode, true),
            ],
            warnings: vec![],
        };
        let claude = provider_accounts(&snapshot, HarnessId::ClaudeCode);
        let ids: Vec<&str> = claude.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(
            ids,
            ["c1", "c2"],
            "engine (creation) order holds — switching must not move a card"
        );
        assert_eq!(provider_accounts(&snapshot, HarnessId::Codex).len(), 1);
        assert!(provider_accounts(&snapshot, HarnessId::Cursor).is_empty());
    }

    fn codex_account(id: &str, active: bool, email: Option<&str>) -> AgentAccount {
        AgentAccount {
            id: id.into(),
            harness: HarnessId::Codex,
            email: email.map(str::to_string),
            plan_label: None,
            active,
            usage_windows: vec![],
            display_name: None,
            organization: None,
            auth_kind: None,
            switchable: true,
            saved_at: None,
        }
    }

    #[test]
    fn graffs_openai_row_follows_the_active_codex_account() {
        // Saved but not live: graff reads the live auth.json, so not signed in.
        let saved_only = AgentAccountsSnapshot {
            accounts: vec![codex_account("x1", false, Some("a@x.test"))],
            warnings: vec![],
        };
        assert_eq!(openai_login(&saved_only), (false, None));
        assert_eq!(
            openai_login(&AgentAccountsSnapshot::default()),
            (false, None)
        );

        let live = AgentAccountsSnapshot {
            accounts: vec![
                codex_account("x1", false, Some("a@x.test")),
                codex_account("x2", true, Some("b@x.test")),
            ],
            warnings: vec![],
        };
        assert_eq!(openai_login(&live), (true, Some("b@x.test".to_string())));

        // A live login with no email still counts as signed in.
        let anonymous = AgentAccountsSnapshot {
            accounts: vec![codex_account("x3", true, None)],
            warnings: vec![],
        };
        assert_eq!(openai_login(&anonymous), (true, None));
    }

    #[test]
    fn login_dialog_titles_name_the_graff_provider() {
        let graff = |provider: Option<&str>| LoginFlow::Starting {
            harness: HarnessId::Graff,
            provider: provider.map(str::to_string),
            reauthenticate: false,
        };
        assert_eq!(graff(Some("xai")).title(), "Sign in to xAI");
        assert_eq!(graff(Some("kimi")).title(), "Sign in to Kimi");
        assert_eq!(graff(Some("zai")).title(), "Sign in to Z.AI");
        assert_eq!(
            graff(Some("chatgpt-new")).title(),
            "Sign in to ChatGPT (new)"
        );
        assert_eq!(graff(None).title(), "Sign in to graff");
        assert_eq!(graff(Some("nope")).title(), "Sign in to graff");
        // The other harnesses keep their titles.
        let starting = |harness| LoginFlow::Starting {
            harness,
            provider: None,
            reauthenticate: false,
        };
        assert_eq!(starting(HarnessId::Codex).title(), "Add Codex account");
        assert_eq!(
            LoginFlow::Starting {
                harness: HarnessId::Codex,
                provider: None,
                reauthenticate: true,
            }
            .title(),
            "Sign in to ChatGPT (Codex)"
        );
        assert_eq!(starting(HarnessId::Cursor).title(), "Connect Cursor");
        assert_eq!(
            starting(HarnessId::ClaudeCode).title(),
            "Add Claude account"
        );
    }
}
