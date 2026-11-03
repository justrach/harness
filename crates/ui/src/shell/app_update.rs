//! Harness's own desktop updates stay quiet while they download and wait
//! for a safe restart. The titlebar control appears for manual updates,
//! failures, or a staged version postponed with "Later". A foreground
//! restart gets a countdown; a quiet background restart does not.
//!
//! The rules live in pure functions ([`update_control`],
//! [`auto_restart_decision`], [`updated_confirmation`]) with their own tests;
//! the shell only gathers their inputs and acts on the answer.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Instant;

use harness_update::Relaunch;
use serde::{Deserialize, Serialize};

use super::*;

/// How long the person must leave the app alone (no key, click, scroll or
/// pointer movement in its window) before it restarts itself while in front.
pub(super) const AUTO_RESTART_IDLE: Duration = Duration::from_secs(60);
/// The same quiet spell while another app is in front: the person is working
/// elsewhere, so a shorter one is enough to know they aren't mid-click here.
pub(super) const AUTO_RESTART_IDLE_BACKGROUND: Duration = Duration::from_secs(10);
/// The heads-up shown before an automatic restart.
pub(super) const AUTO_RESTART_COUNTDOWN: Duration = Duration::from_secs(10);
/// How often a staged update re-checks for a quiet window. Each check only
/// reads in-memory state.
const AUTO_RESTART_POLL: Duration = Duration::from_secs(15);
const COUNTDOWN_TICK: Duration = Duration::from_secs(1);
/// How long the "Updated to vX" confirmation stays before it goes by itself.
const UPDATED_CONFIRMATION_FOR: Duration = Duration::from_secs(12);
/// Written next to the UI settings right before a restart into an update
/// (and before an install on quit); the next launch reads and deletes it.
const RELAUNCH_MARKER: &str = "app-update-relaunch.json";

/// A downloaded release, staged and ready to swap in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct StagedUpdate {
    pub path: PathBuf,
    pub version: String,
}

// ---------------------------------------------------------------------------
// The titlebar control
// ---------------------------------------------------------------------------

/// What the titlebar update control shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum UpdateControl {
    /// Report-only install (managed CLI, source build): point at
    /// `harness update`; a click dismisses this version.
    Advisory,
    /// Desktop install with automatic updates off: a click downloads.
    Available,
    Downloading,
    /// Staged. `on_quit` means it also installs when Harness quits.
    Ready {
        on_quit: bool,
    },
    Failed(SharedString),
}

/// The control for this frame and the version it is about, or `None` when
/// there is nothing to show. Pure.
pub(super) fn update_control(
    status: Option<&harness_update::UpdateStatus>,
    flow: &UpdateFlow,
    desktop_update: bool,
    dismissed: Option<&str>,
    env_auto_update: bool,
    restart_setting: bool,
    postponed: Option<&str>,
) -> Option<(UpdateControl, String)> {
    if desktop_update {
        match flow {
            UpdateFlow::Ready(staged)
                if env_auto_update
                    && restart_setting
                    && postponed != Some(staged.version.as_str()) =>
            {
                return None;
            }
            UpdateFlow::Ready(staged) => {
                return Some((
                    UpdateControl::Ready {
                        on_quit: env_auto_update,
                    },
                    staged.version.clone(),
                ));
            }
            UpdateFlow::Downloading | UpdateFlow::Failed(_) | UpdateFlow::Idle => {}
        }
    }
    let status = status.filter(|status| status.update_available)?;
    let latest = status.latest_version.clone()?;
    if !desktop_update {
        return (dismissed != Some(latest.as_str())).then_some((UpdateControl::Advisory, latest));
    }
    let control = match flow {
        UpdateFlow::Idle | UpdateFlow::Downloading if env_auto_update => return None,
        UpdateFlow::Idle => UpdateControl::Available,
        UpdateFlow::Downloading => UpdateControl::Downloading,
        UpdateFlow::Failed(message) => UpdateControl::Failed(message.clone()),
        UpdateFlow::Ready(_) => unreachable!("handled above"),
    };
    Some((control, latest))
}

/// The control's tooltip, which is also its accessible label. Pure.
pub(super) fn update_control_label(control: &UpdateControl, version: &str) -> String {
    match control {
        UpdateControl::Advisory => {
            format!(
                "Harness v{version} is available. Run `harness update` to install it. Click to dismiss."
            )
        }
        UpdateControl::Available => {
            format!("Harness v{version} is available. Click to download it.")
        }
        UpdateControl::Downloading => format!("Downloading v{version}…"),
        UpdateControl::Ready { on_quit: true } => {
            format!("v{version} is ready — it installs when you quit. Click to restart now.")
        }
        UpdateControl::Ready { on_quit: false } => {
            format!("v{version} is ready. Click to restart and install it.")
        }
        UpdateControl::Failed(message) => {
            format!("Updating to v{version} failed: {message}. Click to try again.")
        }
    }
}

// ---------------------------------------------------------------------------
// The automatic restart
// ---------------------------------------------------------------------------

/// What would keep an automatic restart from happening right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RestartBlocker {
    /// An agent on this device is working or waiting on an answer.
    RunningTurns,
    /// A file editor has edits that aren't saved.
    UnsavedEdits,
    /// A composer holds text, files or captures that weren't sent.
    UnsentInput,
    /// A terminal shell is still running.
    LiveTerminals,
    /// The person used the app recently (or during the countdown).
    UserActive,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum AutoRestart {
    /// No staged update, automatic restarts are off, or "Later" was chosen
    /// for this version.
    Off,
    /// Not yet; check again later.
    Wait(RestartBlocker),
    /// Safe: run (or keep running) the countdown, then restart.
    Restart,
}

/// Everything the decision reads, gathered by the shell each check.
#[derive(Debug, Clone, Copy)]
pub(super) struct RestartInputs<'a> {
    pub flow: &'a UpdateFlow,
    /// `HARNESS_AUTO_UPDATE` allows it and the Settings toggle is on.
    pub enabled: bool,
    /// The version "Later" was chosen for.
    pub postponed: Option<&'a str>,
    pub running_turns: usize,
    pub unsaved_edits: bool,
    pub unsent_input: bool,
    pub live_terminals: usize,
    /// Since the last key, click, scroll or pointer move in the window.
    pub idle_for: Duration,
    /// Harness is the frontmost app.
    pub frontmost: bool,
    /// How long the heads-up has been counting down, if it is.
    pub countdown_for: Option<Duration>,
}

/// Whether Harness may restart into the staged update now. It never weighs
/// one blocker against another: any of them waits. Pure.
pub(super) fn auto_restart_decision(inputs: &RestartInputs) -> AutoRestart {
    let UpdateFlow::Ready(staged) = inputs.flow else {
        return AutoRestart::Off;
    };
    if !inputs.enabled || inputs.postponed == Some(staged.version.as_str()) {
        return AutoRestart::Off;
    }
    let required_idle = if inputs.frontmost {
        AUTO_RESTART_IDLE
    } else {
        AUTO_RESTART_IDLE_BACKGROUND
    };
    let blocker = if inputs.running_turns > 0 {
        Some(RestartBlocker::RunningTurns)
    } else if inputs.unsaved_edits {
        Some(RestartBlocker::UnsavedEdits)
    } else if inputs.unsent_input {
        Some(RestartBlocker::UnsentInput)
    } else if inputs.live_terminals > 0 {
        Some(RestartBlocker::LiveTerminals)
    } else if inputs.idle_for < required_idle
        // Any input after the heads-up appeared cancels it.
        || inputs.countdown_for.is_some_and(|counting| inputs.idle_for < counting)
    {
        Some(RestartBlocker::UserActive)
    } else {
        None
    };
    blocker.map_or(AutoRestart::Restart, AutoRestart::Wait)
}

/// Whole seconds left on the heads-up, never below 1 while it shows. Pure.
pub(super) fn countdown_seconds_left(counting_for: Duration) -> u64 {
    AUTO_RESTART_COUNTDOWN
        .saturating_sub(counting_for)
        .as_secs_f32()
        .ceil()
        .max(1.0) as u64
}

// ---------------------------------------------------------------------------
// The relaunch marker
// ---------------------------------------------------------------------------

/// Left for the next launch by a restart into an update (or an install on
/// quit): which version it should come back on, and whether it reopens
/// behind the app the person is using.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateRelaunch {
    pub version: String,
    #[serde(default)]
    pub background: bool,
}

/// The marker a launch found, set as a global by `lib.rs` before the main
/// window opens.
pub struct UpdateRelaunched(pub Option<UpdateRelaunch>);

impl gpui::Global for UpdateRelaunched {}

fn relaunch_marker_path(data_dir: &std::path::Path) -> PathBuf {
    data_dir.join(RELAUNCH_MARKER)
}

pub(super) fn write_relaunch_marker(
    data_dir: &std::path::Path,
    marker: &UpdateRelaunch,
) -> std::io::Result<()> {
    std::fs::create_dir_all(data_dir)?;
    let json = serde_json::to_vec(marker).map_err(std::io::Error::other)?;
    std::fs::write(relaunch_marker_path(data_dir), json)
}

fn remove_relaunch_marker(data_dir: &std::path::Path) {
    let _ = std::fs::remove_file(relaunch_marker_path(data_dir));
}

/// Read and delete the marker, so its confirmation shows once.
pub fn take_relaunch_marker(data_dir: &std::path::Path) -> Option<UpdateRelaunch> {
    let path = relaunch_marker_path(data_dir);
    let bytes = std::fs::read(&path).ok()?;
    let _ = std::fs::remove_file(&path);
    serde_json::from_slice(&bytes).ok()
}

/// The version to confirm "Updated to" on this launch: the marker's, but only
/// when this process really is that version — a swap that failed relaunches
/// the old one, which must not claim it updated. Pure.
pub(super) fn updated_confirmation(
    marker: Option<&UpdateRelaunch>,
    running_version: &str,
) -> Option<String> {
    marker
        .filter(|marker| marker.version == running_version)
        .map(|marker| marker.version.clone())
}

// ---------------------------------------------------------------------------
// Shell state
// ---------------------------------------------------------------------------

/// Weak window roots let readiness checks include peers without reading the
/// currently leased native window or retaining closed windows.
#[derive(Default)]
struct UpdateWindows(Vec<gpui::WeakEntity<Shell>>);
impl gpui::Global for UpdateWindows {}

struct SharedAppUpdate {
    owner: gpui::WeakEntity<Shell>,
    flow: UpdateFlow,
    dismissed: Option<String>,
    postponed: Option<String>,
}
impl gpui::Global for SharedAppUpdate {}

/// The shell's app-update UI state beyond the download flow itself.
pub(super) struct AppUpdateUi {
    entity_id: Option<gpui::EntityId>,
    /// Render an inert ready-update button for manual layout testing in a
    /// debug build. This never stages an update or starts a restart watcher.
    pub dev_preview: bool,
    /// "Later" was chosen for this version: no automatic restart for it (it
    /// still installs on quit).
    pub postponed: Option<String>,
    /// When the restart heads-up started counting down.
    pub countdown_started: Option<Instant>,
    /// The quiet-window watcher; runs while an update is staged.
    pub watch: Option<Task<()>>,
    /// The last key, click, scroll or pointer move in the window. Shared with
    /// the window-level listeners so recording input never re-renders.
    pub last_input: Rc<Cell<Instant>>,
    pub _keystrokes: Option<Subscription>,
    /// "Updated to vX", shown once after coming back on a new version.
    pub updated_to: Option<String>,
    pub updated_task: Option<Task<()>>,
}

impl AppUpdateUi {
    pub(super) fn new() -> Self {
        Self {
            entity_id: None,
            dev_preview: cfg!(debug_assertions)
                && std::env::var("HARNESS_DEV_APP_UPDATE").as_deref() == Ok("1"),
            postponed: None,
            countdown_started: None,
            watch: None,
            last_input: Rc::new(Cell::new(Instant::now())),
            _keystrokes: None,
            updated_to: None,
            updated_task: None,
        }
    }

    /// A zero-size element whose paint registers window-level pointer
    /// listeners. They run in the capture phase, before any element can stop
    /// the event, and only stamp a clock.
    pub(super) fn input_probe(&self) -> AnyElement {
        let last = self.last_input.clone();
        gpui::canvas(
            |_, _, _| {},
            move |_, _, window, _| {
                let stamp = last.clone();
                window.on_mouse_event(move |_: &gpui::MouseMoveEvent, phase, _, _| {
                    if phase == gpui::DispatchPhase::Capture {
                        stamp.set(Instant::now());
                    }
                });
                let stamp = last.clone();
                window.on_mouse_event(move |_: &MouseDownEvent, phase, _, _| {
                    if phase == gpui::DispatchPhase::Capture {
                        stamp.set(Instant::now());
                    }
                });
                let stamp = last.clone();
                window.on_mouse_event(move |_: &gpui::ScrollWheelEvent, phase, _, _| {
                    if phase == gpui::DispatchPhase::Capture {
                        stamp.set(Instant::now());
                    }
                });
            },
        )
        .absolute()
        .size_0()
        .into_any_element()
    }
}

impl Shell {
    /// Keystrokes count as use of the app wherever focus is. Called once
    /// from `Shell::new`; an interceptor sees every key before anything can
    /// stop it.
    pub(super) fn observe_update_input(&mut self, cx: &mut Context<Self>) {
        self.app_update.entity_id = Some(cx.entity_id());
        if !cx.has_global::<UpdateWindows>() {
            cx.set_global(UpdateWindows::default());
        }
        let weak = cx.weak_entity();
        let windows = &mut cx.global_mut::<UpdateWindows>().0;
        windows.retain(|window| window.upgrade().is_some());
        windows.push(weak);
        cx.observe_global::<SharedAppUpdate>(|_, cx| cx.notify())
            .detach();
        let last = self.app_update.last_input.clone();
        self.app_update._keystrokes = Some(cx.intercept_keystrokes(move |_, _, _| {
            last.set(Instant::now());
        }));
        let marker = cx
            .try_global::<UpdateRelaunched>()
            .and_then(|relaunched| relaunched.0.clone());
        if let Some(version) =
            updated_confirmation(marker.as_ref(), harness_update::current_version())
        {
            self.show_updated_confirmation(version, cx);
        }
    }

    pub(super) fn show_updated_confirmation(&mut self, version: String, cx: &mut Context<Self>) {
        self.app_update.updated_to = Some(version);
        self.app_update.updated_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(UPDATED_CONFIRMATION_FOR)
                .await;
            this.update(cx, |shell, cx| {
                shell.app_update.updated_to = None;
                cx.notify();
            })
            .ok();
        }));
        cx.notify();
    }

    /// Publish the flow for Settings → Devices' version card, so it offers
    /// the same next step as the titlebar control. Called each render; the
    /// global (and its observers) only change when the phase does.
    pub(super) fn publish_update_phase(&self, cx: &mut Context<Self>) {
        use crate::settings::devices::{SharedUpdatePhase, UpdatePhase};
        if !self.owns_app_services(cx) {
            return;
        }
        if cx.try_global::<SharedAppUpdate>().is_none_or(|shared| {
            shared.owner.entity_id() != cx.entity_id()
                || shared.flow != self.update_flow
                || shared.dismissed != self.update_dismissed
                || shared.postponed != self.app_update.postponed
        }) {
            cx.set_global(SharedAppUpdate {
                owner: cx.weak_entity(),
                flow: self.update_flow.clone(),
                dismissed: self.update_dismissed.clone(),
                postponed: self.app_update.postponed.clone(),
            });
        }
        let phase = match &self.update_flow {
            UpdateFlow::Idle => UpdatePhase::Idle,
            UpdateFlow::Downloading => UpdatePhase::Downloading,
            UpdateFlow::Ready(staged) => UpdatePhase::Ready(staged.version.clone()),
            UpdateFlow::Failed(message) => UpdatePhase::Failed(message.to_string()),
        };
        if cx
            .try_global::<SharedUpdatePhase>()
            .is_none_or(|shared| shared.0 != phase)
        {
            cx.set_global(SharedUpdatePhase(phase));
        }
    }

    fn update_control_now(&self, cx: &App) -> Option<(UpdateControl, String)> {
        if self.app_update.dev_preview {
            return Some((UpdateControl::Ready { on_quit: false }, "preview".into()));
        }
        let shared = cx.try_global::<SharedAppUpdate>().filter(|shared| {
            shared.owner.upgrade().is_some()
                && Some(shared.owner.entity_id()) != self.app_update.entity_id
        });
        let flow = shared.map_or(&self.update_flow, |shared| &shared.flow);
        let control = update_control(
            self.state.read(cx).update.as_ref(),
            flow,
            self.install.supports_desktop_update(),
            shared.map_or(self.update_dismissed.as_deref(), |shared| {
                shared.dismissed.as_deref()
            }),
            harness_update::desktop_auto_update_enabled(),
            settings::with_current(cx, |s| s.restart_to_install_updates),
            shared.map_or(self.app_update.postponed.as_deref(), |shared| {
                shared.postponed.as_deref()
            }),
        );
        // Automatic restart can wait indefinitely for an idle moment. Keep a
        // manual restart in the titlebar while it waits.
        if let UpdateFlow::Ready(staged) = flow
            && self.install.supports_desktop_update()
        {
            if self.app_update.countdown_started.is_some() {
                return None;
            }
            return Some(control.unwrap_or_else(|| {
                (
                    UpdateControl::Ready { on_quit: true },
                    staged.version.clone(),
                )
            }));
        }
        control
    }

    /// Width the titlebar's left cluster gains while the update control
    /// shows, for the rows that start past the cluster.
    pub(super) fn titlebar_update_slot(&self, cx: &App) -> f32 {
        if self.update_control_now(cx).is_some() {
            TITLEBAR_ACTION_SLOT_WIDTH
        } else {
            0.0
        }
    }

    /// The update control in the titlebar's left cluster, at the cluster's
    /// 24px button geometry. Hidden when there is no update.
    pub(super) fn render_update_control(
        &mut self,
        theme: &Theme,
        control_gap: f32,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let (control, version) = self.update_control_now(cx)?;
        let label = if self.app_update.dev_preview {
            "Update button preview — no download, install or restart.".into()
        } else {
            update_control_label(&control, &version)
        };
        let tone = match control {
            UpdateControl::Downloading => theme.text_muted,
            UpdateControl::Failed(_) => theme.danger,
            UpdateControl::Advisory | UpdateControl::Available | UpdateControl::Ready { .. } => {
                theme.accent
            }
        };
        let ready = matches!(control, UpdateControl::Ready { .. });
        let clickable =
            !self.app_update.dev_preview && !matches!(control, UpdateControl::Downloading);
        let fade_key = "window-control-titlebar-update";
        let mut button = div()
            .id("titlebar-update")
            .debug_selector(|| "titlebar-update".into())
            .role(gpui::Role::Button)
            .aria_label(label.clone())
            .tooltip(crate::settings::widgets::text_tooltip(label))
            .relative()
            .size(px(24.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(6.0))
            .bg(motion::hover_blend(
                fade_key,
                theme.glass_hover().opacity(0.0),
                theme.glass_hover(),
            ))
            .on_hover(motion::hover_listener(fade_key))
            // Over the titlebar drag strip: carve the button out of it (see
            // `window_control_button`).
            .occlude()
            .on_mouse_down(MouseButton::Left, |_, window, _| window.prevent_default())
            .child(
                icon(icons::DOWNLOAD_MINIMALISTIC)
                    .size(px(16.0))
                    .text_color(if matches!(control, UpdateControl::Downloading) {
                        tone.opacity(0.7)
                    } else {
                        tone
                    }),
            )
            .when(ready, |el| {
                el.child(
                    div()
                        .absolute()
                        .top(px(3.0))
                        .right(px(3.0))
                        .size(px(6.0))
                        .rounded_full()
                        .bg(theme.accent),
                )
            });
        if clickable {
            button = button
                .cursor_pointer()
                .on_click(cx.listener(|this, _, _, cx| {
                    cx.stop_propagation();
                    this.on_update_control_click(cx);
                }));
        } else {
            button = button.on_click(|_, _, cx| cx.stop_propagation());
        }
        Some(
            div()
                .flex_none()
                .ml(px(control_gap))
                .child(button)
                .into_any_element(),
        )
    }

    /// Start re-checking for a quiet window while an update is staged.
    pub(super) fn watch_for_quiet_restart(&mut self, cx: &mut Context<Self>) {
        self.app_update.countdown_started = None;
        self.app_update.watch = Some(cx.spawn(async move |this, cx| {
            loop {
                let next = this
                    .update(cx, |shell, cx| shell.auto_restart_tick(cx))
                    .ok()
                    .flatten();
                let Some(delay) = next else { break };
                cx.background_executor().timer(delay).await;
            }
        }));
    }

    fn restart_inputs_now<'a>(&'a self, now: Instant, cx: &App) -> RestartInputs<'a> {
        let mut inputs = RestartInputs {
            flow: &self.update_flow,
            enabled: harness_update::desktop_auto_update_enabled()
                && settings::with_current(cx, |s| s.restart_to_install_updates),
            postponed: self.app_update.postponed.as_deref(),
            running_turns: 0,
            unsaved_edits: false,
            unsent_input: false,
            live_terminals: 0,
            idle_for: Duration::MAX,
            frontmost: cx.active_window().is_some(),
            countdown_for: self
                .app_update
                .countdown_started
                .map(|started| now.saturating_duration_since(started)),
        };
        self.add_window_restart_inputs(&mut inputs, now, cx);
        if let Some(windows) = cx.try_global::<UpdateWindows>() {
            for peer in windows.0.iter().filter_map(|window| window.upgrade()) {
                if Some(peer.entity_id()) != self.app_update.entity_id {
                    peer.read(cx)
                        .add_window_restart_inputs(&mut inputs, now, cx);
                }
            }
        }
        inputs
    }

    fn add_window_restart_inputs(&self, inputs: &mut RestartInputs<'_>, now: Instant, cx: &App) {
        inputs.running_turns += self.state.read(cx).local_busy_turns(Utc::now());
        inputs.unsaved_edits |= !self.all_file_edits_flushed(cx);
        inputs.unsent_input |= self.has_unsent_composer_input(cx);
        let mut terminals = std::collections::HashSet::new();
        for terminal in self
            .terminal
            .iter()
            .chain(self.right_terminal.iter())
            .chain(self.workspace_panels.terminals.values())
        {
            if terminals.insert(terminal.entity_id()) {
                inputs.live_terminals += terminal.read(cx).live_tab_count();
            }
        }
        inputs.idle_for = inputs
            .idle_for
            .min(now.saturating_duration_since(self.app_update.last_input.get()));
    }

    /// Unsent composer input anywhere: the live composer (with every chat's
    /// stashed draft), new-session canvases parked in other tabs and split
    /// panes, and review comments that have not been sent yet.
    pub(super) fn has_unsent_composer_input(&self, cx: &App) -> bool {
        let parked = |draft: &Option<crate::pickers::CanvasDraft>| {
            draft
                .as_ref()
                .and_then(|draft| draft.input.as_ref())
                .is_some_and(|input| !input.text.trim().is_empty() || !input.stage.is_empty())
        };
        let split = |split: &Option<chat_split::ChatSplit>| {
            split
                .as_ref()
                .is_some_and(|split| split.drafts.iter().any(parked))
        };
        self.state.read(cx).has_review_comments()
            || self
                .diffs
                .values()
                .any(|changes| changes.read(cx).has_pending_review_draft(cx))
            || self.composer.read(cx).has_unsent_input(cx)
            || self.workspace_panels.drafts.values().any(|draft| {
                draft
                    .input
                    .as_ref()
                    .is_some_and(|input| !input.text.trim().is_empty() || !input.stage.is_empty())
            })
            || split(&self.chat_split)
            || self
                .chat_tabs
                .iter()
                .any(|tab| parked(&tab.draft) || split(&tab.split))
    }

    /// One check of the quiet-window watcher. Returns when to check next, or
    /// `None` once nothing is staged.
    fn auto_restart_tick(&mut self, cx: &mut Context<Self>) -> Option<Duration> {
        if !matches!(self.update_flow, UpdateFlow::Ready(_)) {
            if self.app_update.countdown_started.take().is_some() {
                cx.notify();
            }
            return None;
        }
        let now = Instant::now();
        let decision = auto_restart_decision(&self.restart_inputs_now(now, cx));
        match (decision, self.app_update.countdown_started) {
            (AutoRestart::Restart, None) if cx.active_window().is_none() => {
                self.restart_into_update_now(true, cx);
                self.still_staged()
            }
            (AutoRestart::Restart, None) => {
                self.app_update.countdown_started = Some(now);
                cx.notify();
                Some(COUNTDOWN_TICK)
            }
            (AutoRestart::Restart, Some(started))
                if now.saturating_duration_since(started) >= AUTO_RESTART_COUNTDOWN =>
            {
                self.app_update.countdown_started = None;
                let background = cx.active_window().is_none();
                self.restart_into_update_now(background, cx);
                self.still_staged()
            }
            (AutoRestart::Restart, Some(_)) => {
                cx.notify();
                Some(COUNTDOWN_TICK)
            }
            (_, Some(_)) => {
                self.app_update.countdown_started = None;
                cx.notify();
                Some(AUTO_RESTART_POLL)
            }
            (_, None) => Some(AUTO_RESTART_POLL),
        }
    }

    /// A last-moment blocker leaves the staged update in place. Keep the
    /// watcher alive so removing that blocker can allow a later restart.
    fn still_staged(&self) -> Option<Duration> {
        matches!(self.update_flow, UpdateFlow::Ready(_)).then_some(AUTO_RESTART_POLL)
    }

    /// The automatic restart itself. Re-checks unsaved edits at the last
    /// moment and never prompts or discards: anything unsaved puts the
    /// update back and the watcher keeps waiting.
    fn restart_into_update_now(&mut self, background: bool, cx: &mut Context<Self>) {
        if auto_restart_decision(&self.restart_inputs_now(Instant::now(), cx))
            != AutoRestart::Restart
        {
            return;
        }
        let UpdateFlow::Ready(staged) = std::mem::replace(&mut self.update_flow, UpdateFlow::Idle)
        else {
            return;
        };
        let relaunch = if background {
            Relaunch::Background
        } else {
            Relaunch::Foreground
        };
        self.defer_update_install(staged, relaunch, true, cx);
    }

    /// Swap the staged bundle in, arm the relauncher and quit. The marker
    /// tells the next launch to confirm the version (and, for a background
    /// restart, not to take focus).
    pub(super) fn install_and_relaunch(
        &mut self,
        staged: StagedUpdate,
        relaunch: Relaunch,
        cx: &mut Context<Self>,
    ) {
        if let Some(owner) = self.app_services_peer(cx) {
            cx.defer(move |cx| {
                let _ = owner.update(cx, |shell, cx| {
                    shell.install_and_relaunch(staged, relaunch, cx)
                });
            });
            return;
        }
        self.defer_update_install(staged, relaunch, false, cx);
    }

    fn defer_update_install(
        &mut self,
        staged: StagedUpdate,
        relaunch: Relaunch,
        automatic: bool,
        cx: &mut Context<Self>,
    ) {
        self.update_flow = UpdateFlow::Ready(staged.clone());
        if !automatic {
            // A cancelled save dialog must not turn into an automatic restart.
            self.app_update.postponed = Some(staged.version.clone());
            self.app_update.watch = None;
            self.app_update.countdown_started = None;
        }
        let owner = cx.weak_entity();
        cx.defer(move |cx| {
            if automatic {
                let _ = owner.update(cx, |shell, cx| {
                    if auto_restart_decision(&shell.restart_inputs_now(Instant::now(), cx))
                        == AutoRestart::Restart
                    {
                        shell.perform_update_install(staged, relaunch, cx);
                    } else {
                        shell.watch_for_quiet_restart(cx);
                    }
                });
                return;
            }
            // Outside the initiating Shell lease, every window can use its
            // existing Save/Discard/Cancel flow before any bundle is changed.
            if !prepare_windows_for_update(&staged, cx) {
                return;
            }
            let _ = owner.update(cx, |shell, cx| {
                shell.perform_update_install(staged, relaunch, cx)
            });
        });
        cx.notify();
    }

    fn perform_update_install(
        &mut self,
        staged: StagedUpdate,
        relaunch: Relaunch,
        cx: &mut Context<Self>,
    ) {
        self.update_flow = UpdateFlow::Idle;
        // Publish this window's tabs and layout so the quit's settings flush
        // writes them for the relaunch to restore.
        self.schedule_save(cx);
        let marker = UpdateRelaunch {
            version: staged.version.clone(),
            background: relaunch == Relaunch::Background,
        };
        if let Err(err) = write_relaunch_marker(&self.data_dir, &marker) {
            tracing::warn!(error = %err, "couldn't record the update relaunch");
        }
        match self
            .install
            .apply_desktop_relaunching(&staged.path, relaunch)
        {
            Ok(()) => crate::app_menus::quit_after_save(cx),
            Err(err) => {
                tracing::error!(error = %err, "update apply failed");
                remove_relaunch_marker(&self.data_dir);
                self.update_flow = UpdateFlow::Failed(format!("{err:#}").into());
                cx.notify();
            }
        }
    }

    /// "Later" on the heads-up: no automatic restart for this version.
    fn postpone_auto_restart(&mut self, cx: &mut Context<Self>) {
        if let UpdateFlow::Ready(staged) = &self.update_flow {
            self.app_update.postponed = Some(staged.version.clone());
        }
        self.app_update.countdown_started = None;
        cx.notify();
    }

    /// The bottom-right card: the restart heads-up while it counts down,
    /// otherwise the one-time "Updated" confirmation.
    pub(super) fn render_app_update_card(
        &mut self,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let ui = crate::typography::ui_rems;
        let countdown =
            self.app_update
                .countdown_started
                .and_then(|started| match &self.update_flow {
                    UpdateFlow::Ready(staged) => Some((
                        staged.version.clone(),
                        countdown_seconds_left(Instant::now().saturating_duration_since(started)),
                    )),
                    _ => None,
                });
        let (selector, title, body, buttons): (&'static str, String, String, AnyElement) =
            if let Some((version, seconds)) = countdown {
                let buttons = div()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(6.0))
                    .child(
                        popover::btn_ghost(theme, "Later", "app-update-later-fade")
                            .id("app-update-later")
                            .debug_selector(|| "app-update-later".into())
                            .on_click(cx.listener(|this, _, _, cx| this.postpone_auto_restart(cx))),
                    )
                    .child(
                        popover::btn_primary(theme, "Restart now")
                            .id("app-update-restart-now")
                            .debug_selector(|| "app-update-restart-now".into())
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.app_update.countdown_started = None;
                                if let UpdateFlow::Ready(staged) =
                                    std::mem::replace(&mut this.update_flow, UpdateFlow::Idle)
                                {
                                    this.apply_staged_update(staged, cx);
                                }
                            })),
                    )
                    .into_any_element();
                (
                    "app-update-countdown",
                    format!("Restarting to update to v{version} in {seconds}s"),
                    "Your windows, tabs and chats come back where they are. Using Harness cancels it."
                        .to_string(),
                    buttons,
                )
            } else {
                let version = self.app_update.updated_to.clone()?;
                let notes = format!("https://github.com/justrach/harness/releases/tag/v{version}");
                let buttons = div()
                    .flex()
                    .flex_row()
                    .justify_end()
                    .gap(px(6.0))
                    .child(
                        popover::btn_ghost(theme, "Release notes", "app-updated-notes-fade")
                            .id("app-updated-notes")
                            .on_click(move |_, _, cx| cx.open_url(&notes)),
                    )
                    .child(
                        popover::btn_primary(theme, "Got it")
                            .id("app-updated-dismiss")
                            .debug_selector(|| "app-updated-dismiss".into())
                            .cursor_pointer()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.app_update.updated_to = None;
                                this.app_update.updated_task = None;
                                cx.notify();
                            })),
                    )
                    .into_any_element();
                (
                    "app-updated",
                    format!("Updated to v{version}"),
                    "You're on the new version.".to_string(),
                    buttons,
                )
            };
        let header = div()
            .flex()
            .flex_row()
            .items_center()
            .gap(px(10.0))
            .child(
                div()
                    .size(px(30.0))
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_center()
                    .rounded(px(8.0))
                    .bg(theme.accent_wash)
                    .child(
                        icon(if selector == "app-updated" {
                            icons::CHECK
                        } else {
                            icons::RESTART
                        })
                        .size(px(16.0))
                        .text_color(theme.accent),
                    ),
            )
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .text_size(ui(13.0))
                    .font_weight(gpui::FontWeight::SEMIBOLD)
                    .text_color(theme.text)
                    .child(title),
            );
        Some(
            popover::popover_card(theme)
                .id(selector)
                .debug_selector(move || selector.into())
                .role(gpui::Role::Status)
                .occlude()
                .absolute()
                .right(px(16.0))
                .bottom(px(16.0))
                .w(px(340.0))
                .p(px(14.0))
                .flex()
                .flex_col()
                .gap(px(10.0))
                .child(header)
                .child(
                    div()
                        .text_size(ui(11.5))
                        .line_height(px(16.0))
                        .text_color(theme.text_muted)
                        .child(body),
                )
                .child(buttons)
                .into_any_element(),
        )
    }
}

fn prepare_windows_for_update(staged: &StagedUpdate, cx: &mut App) -> bool {
    let windows: Vec<_> = cx
        .try_global::<UpdateWindows>()
        .into_iter()
        .flat_map(|windows| &windows.0)
        .filter_map(|window| window.upgrade())
        .collect();
    let mut ready = true;
    let mut blocked = None;
    for window in windows {
        let window_ready = window.update(cx, |shell, cx| {
            shell.prepare_exit(PendingExit::InstallUpdate(staged.clone()), cx)
        });
        if !window_ready {
            blocked.get_or_insert(window.entity_id());
        }
        ready &= window_ready;
    }
    if let Some(blocked) = blocked {
        for window in cx
            .windows()
            .into_iter()
            .filter_map(|window| window.downcast::<Shell>())
        {
            if window
                .entity(cx)
                .is_ok_and(|shell| shell.entity_id() == blocked)
            {
                let _ = window.update(cx, |_, window, _| window.activate_window());
                break;
            }
        }
    }
    ready
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer_window(
        source: gpui::WindowHandle<Shell>,
        cx: &mut gpui::TestAppContext,
    ) -> gpui::WindowHandle<Shell> {
        let (state, boot) = source
            .read_with(cx, |shell, _| (shell.state.clone(), shell.boot.clone()))
            .unwrap();
        cx.add_window(|_, cx| {
            let state = cx.new(|cx| AppState::for_window(&state, cx));
            Shell::new(state, boot, cx)
        })
    }

    #[gpui::test]
    fn peer_windows_read_the_owners_update_phase_without_overwriting_it(
        cx: &mut gpui::TestAppContext,
    ) {
        use crate::settings::devices::{SharedUpdatePhase, UpdatePhase};
        let (_dir, owner) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let peer = peer_window(owner, cx);
        for window in [owner, peer] {
            window
                .update(cx, |shell, _, cx| {
                    shell.app_update.dev_preview = false;
                    shell.install = harness_update::InstallKind::MacApp {
                        bundle: PathBuf::from("/nonexistent/Harness.app"),
                    };
                    shell
                        .state
                        .update(cx, |state, _| state.update = Some(status("9.9.9", true)));
                })
                .unwrap();
        }
        owner
            .update(cx, |shell, _, cx| {
                assert!(shell.owns_app_services(cx));
                shell.update_flow = UpdateFlow::Downloading;
                shell.publish_update_phase(cx);
            })
            .unwrap();
        peer.update(cx, |shell, _, cx| {
            assert!(matches!(shell.update_flow, UpdateFlow::Idle));
            shell.publish_update_phase(cx);
            assert_eq!(cx.global::<SharedUpdatePhase>().0, UpdatePhase::Downloading);
            if harness_update::desktop_auto_update_enabled() {
                assert!(shell.update_control_now(cx).is_none());
            } else {
                assert_eq!(
                    shell.update_control_now(cx).unwrap().0,
                    UpdateControl::Downloading
                );
            }
        })
        .unwrap();
        owner
            .update(cx, |shell, _, cx| {
                shell.update_flow = ready("9.9.9");
                shell.publish_update_phase(cx);
            })
            .unwrap();
        peer.update(cx, |shell, _, cx| {
            shell.publish_update_phase(cx);
            assert_eq!(cx.global::<SharedUpdatePhase>().0, UpdatePhase::Ready("9.9.9".into()));
            assert!(matches!(shell.update_control_now(cx), Some((UpdateControl::Ready { .. }, version)) if version == "9.9.9"));
            assert!(matches!(shell.update_flow, UpdateFlow::Idle), "peers display the flow without owning its staged installer");
        }).unwrap();
        owner
            .update(cx, |shell, _, cx| {
                shell.postpone_auto_restart(cx);
                shell.publish_update_phase(cx);
            })
            .unwrap();
        peer.update(cx, |shell, _, cx| {
            shell.publish_update_phase(cx);
            assert_eq!(cx.global::<SharedAppUpdate>().postponed.as_deref(), Some("9.9.9"));
            assert!(shell.app_update.postponed.is_none(), "the peer reads the owner's Later choice");
            assert!(matches!(shell.update_control_now(cx), Some((UpdateControl::Ready { .. }, version)) if version == "9.9.9"));
        }).unwrap();
        owner
            .update(cx, |shell, _, cx| {
                shell.update_flow = UpdateFlow::Failed("offline".into());
                shell.publish_update_phase(cx);
            })
            .unwrap();
        peer.read_with(cx, |shell, cx| {
            assert_eq!(
                shell.update_control_now(cx),
                Some((UpdateControl::Failed("offline".into()), "9.9.9".into()))
            );
        })
        .unwrap();
    }

    #[gpui::test]
    fn automatic_restart_keeps_polling_after_a_peer_blocks_the_final_check(
        cx: &mut gpui::TestAppContext,
    ) {
        let (dir, owner) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let peer = peer_window(owner, cx);
        let now = Instant::now();
        for window in [owner, peer] {
            window
                .update(cx, |shell, _, _| {
                    shell
                        .app_update
                        .last_input
                        .set(now - Duration::from_secs(120));
                })
                .unwrap();
        }
        owner
            .update(cx, |shell, _, cx| {
                shell.update_flow = ready("9.9.9");
                assert_eq!(
                    auto_restart_decision(&RestartInputs {
                        enabled: true,
                        ..shell.restart_inputs_now(now, cx)
                    }),
                    AutoRestart::Restart
                );
            })
            .unwrap();
        peer.update(cx, |shell, _, _| {
            shell.workspace_panels.drafts.insert(
                99,
                crate::pickers::CanvasDraft {
                    input: Some(crate::pickers::CanvasInput {
                        text: "Keep this unsent note".into(),
                        stage: Vec::new(),
                    }),
                    ..Default::default()
                },
            );
        })
        .unwrap();
        owner
            .update(cx, |shell, _, cx| {
                shell.restart_into_update_now(true, cx);
                assert!(matches!(shell.update_flow, UpdateFlow::Ready(_)));
                assert_eq!(shell.still_staged(), Some(AUTO_RESTART_POLL));
                assert_eq!(shell.auto_restart_tick(cx), Some(AUTO_RESTART_POLL));
                assert!(shell.app_update.countdown_started.is_none());
                shell.update_flow = UpdateFlow::Failed("installer failed".into());
                assert_eq!(shell.still_staged(), None);
                assert_eq!(shell.auto_restart_tick(cx), None);
            })
            .unwrap();
        assert!(!dir.path().join(RELAUNCH_MARKER).exists());
    }

    #[gpui::test]
    fn automatic_restart_waits_for_review_comments_from_another_chat(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, owner) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let comment = crate::comments::ReviewComment::new(
            "src/example.rs",
            crate::comments::CommentSide::New,
            12,
            "Please keep this review note",
        );
        owner
            .update(cx, |shell, _, cx| {
                shell.update_flow = ready("9.9.9");
                shell
                    .app_update
                    .last_input
                    .set(Instant::now() - Duration::from_secs(120));
                shell.state.update(cx, |state, _| {
                    state.add_review_comment("unselected-chat", comment.clone());
                });
                assert_eq!(
                    auto_restart_decision(&RestartInputs {
                        enabled: true,
                        ..shell.restart_inputs_now(Instant::now(), cx)
                    }),
                    AutoRestart::Wait(RestartBlocker::UnsentInput)
                );
                shell.state.update(cx, |state, _| {
                    state.remove_review_comment("unselected-chat", &comment.id);
                });
                assert!(!shell.has_unsent_composer_input(cx));
            })
            .unwrap();
    }

    #[gpui::test]
    fn automatic_restart_waits_for_a_typed_diff_comment_after_switching_chats(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, owner) = chat_tabs::navigation_tests::fixture(cx, false, None);
        owner
            .update(cx, |shell, window, cx| {
                shell.update_flow = ready("9.9.9");
                shell
                    .app_update
                    .last_input
                    .set(Instant::now() - Duration::from_secs(120));
                let changes = cx.new(|cx| Changes::new(shell.state.clone(), cx));
                changes.update(cx, |changes, cx| {
                    changes.review_working_tree("current".into(), cx);
                    changes.test_open_review_draft("Keep this unfinished review note", window, cx);
                });
                shell.diffs.insert(99, changes);
                shell
                    .state
                    .update(cx, |state, cx| state.select_chat(Some("peer".into()), cx));
            })
            .unwrap();
        cx.run_until_parked();
        owner
            .read_with(cx, |shell, cx| {
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
                assert!(
                    !shell.state.read(cx).has_review_comments(),
                    "the note is still being typed, not staged"
                );
                assert!(shell.has_unsent_composer_input(cx));
                assert_eq!(
                    auto_restart_decision(&RestartInputs {
                        enabled: true,
                        ..shell.restart_inputs_now(Instant::now(), cx)
                    }),
                    AutoRestart::Wait(RestartBlocker::UnsentInput)
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn restart_readiness_includes_peer_panel_drafts_and_latest_pointer_input(
        cx: &mut gpui::TestAppContext,
    ) {
        let (_dir, owner) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let peer = peer_window(owner, cx);
        let now = Instant::now();
        owner
            .update(cx, |shell, _, _| {
                shell.update_flow = ready("9.9.9");
                shell
                    .app_update
                    .last_input
                    .set(now - Duration::from_secs(120));
            })
            .unwrap();
        peer.update(cx, |shell, _, _| {
            shell
                .app_update
                .last_input
                .set(now - Duration::from_secs(2));
            shell.workspace_panels.drafts.insert(
                99,
                crate::pickers::CanvasDraft {
                    input: Some(crate::pickers::CanvasInput {
                        text: "Unsent review note".into(),
                        stage: Vec::new(),
                    }),
                    ..Default::default()
                },
            );
        })
        .unwrap();
        owner
            .update(cx, |shell, _, cx| {
                let inputs = shell.restart_inputs_now(now, cx);
                assert!(inputs.unsent_input);
                assert_eq!(inputs.idle_for, Duration::from_secs(2));
                assert_eq!(
                    auto_restart_decision(&RestartInputs {
                        enabled: true,
                        ..inputs
                    }),
                    AutoRestart::Wait(RestartBlocker::UnsentInput)
                );
            })
            .unwrap();
        peer.update(cx, |shell, _, _| shell.workspace_panels.drafts.clear())
            .unwrap();
        owner
            .update(cx, |shell, _, cx| {
                let inputs = shell.restart_inputs_now(now, cx);
                assert!(!inputs.unsent_input);
                assert_eq!(
                    auto_restart_decision(&RestartInputs {
                        enabled: true,
                        ..inputs
                    }),
                    AutoRestart::Wait(RestartBlocker::UserActive)
                );
            })
            .unwrap();
    }

    #[gpui::test]
    fn manual_update_waits_for_a_dirty_peer_before_attempting_the_install(
        cx: &mut gpui::TestAppContext,
    ) {
        let (dir, owner) = chat_tabs::navigation_tests::fixture(cx, false, None);
        let peer = peer_window(owner, cx);
        peer.update(cx, |shell, _, cx| {
            let state = shell.state.clone();
            let files = cx.new(|cx| {
                let mut files =
                    FilesSurface::new(state, "current".into(), false, 1000, 13.0, false, false, cx);
                files.seed_pending_exit_test_document(false);
                files
            });
            shell.file_surfaces.insert(0, files);
            shell
                .file_surface_keys
                .insert(("current".into(), "current".into(), "test.rs".into()), 0);
        })
        .unwrap();
        owner
            .update(cx, |shell, _, cx| {
                assert!(shell.owns_app_services(cx));
                shell.install = harness_update::InstallKind::MacApp {
                    bundle: PathBuf::from("/nonexistent/Harness.app"),
                };
                assert!(shell.restart_inputs_now(Instant::now(), cx).unsaved_edits);
                shell.apply_staged_update(
                    StagedUpdate {
                        path: PathBuf::from("/nonexistent/staged"),
                        version: "9.9.9".into(),
                    },
                    cx,
                );
            })
            .unwrap();
        cx.run_until_parked();
        owner
            .read_with(cx, |shell, _| {
                assert!(
                    matches!(shell.update_flow, UpdateFlow::Ready(_)),
                    "no install attempt may replace Ready while the peer has unsaved edits"
                )
            })
            .unwrap();
        peer.update(cx, |shell, _, cx| {
            assert!(matches!(
                shell.pending_exit,
                Some(PendingExit::InstallUpdate(_))
            ));
            shell.cancel_file_close(RightSurface::File(0), cx);
            assert!(shell.pending_exit.is_none());
        })
        .unwrap();
        assert!(!dir.path().join(RELAUNCH_MARKER).exists());
    }

    fn status(latest: &str, available: bool) -> harness_update::UpdateStatus {
        harness_update::UpdateStatus {
            current_version: "0.2.134".into(),
            latest_version: Some(latest.into()),
            update_available: available,
            checked_at: None,
            error: None,
            host: None,
        }
    }

    fn ready(version: &str) -> UpdateFlow {
        UpdateFlow::Ready(StagedUpdate {
            path: PathBuf::from("/tmp/staged"),
            version: version.into(),
        })
    }

    #[test]
    fn the_update_control_follows_the_flow_and_hides_without_an_update() {
        let available = status("0.2.135", true);
        let control = |status: Option<&harness_update::UpdateStatus>,
                       flow: &UpdateFlow,
                       desktop: bool,
                       dismissed: Option<&str>| {
            update_control(status, flow, desktop, dismissed, true, true, None)
        };
        assert_eq!(control(None, &UpdateFlow::Idle, true, None), None);
        assert_eq!(
            control(
                Some(&status("0.2.134", false)),
                &UpdateFlow::Idle,
                true,
                None
            ),
            None
        );
        let v = "0.2.135".to_string();
        assert_eq!(
            control(Some(&available), &UpdateFlow::Idle, true, None),
            None
        );
        assert_eq!(
            control(Some(&available), &UpdateFlow::Downloading, true, None),
            None
        );
        assert_eq!(
            control(
                Some(&available),
                &UpdateFlow::Failed("offline".into()),
                true,
                None
            ),
            Some((UpdateControl::Failed("offline".into()), v.clone()))
        );
        // Automatic updates stay quiet even if the feed moved on since.
        assert_eq!(
            control(
                Some(&status("0.2.136", true)),
                &ready("0.2.135"),
                true,
                None
            ),
            None
        );
        assert_eq!(
            update_control(
                Some(&available),
                &ready("0.2.135"),
                true,
                None,
                true,
                false,
                None
            ),
            Some((UpdateControl::Ready { on_quit: true }, v.clone()))
        );
        assert_eq!(
            update_control(
                Some(&available),
                &ready("0.2.135"),
                true,
                None,
                false,
                true,
                None
            ),
            Some((UpdateControl::Ready { on_quit: false }, v.clone()))
        );
        // Report-only installs stay advisory until that version is dismissed.
        assert_eq!(
            control(Some(&available), &UpdateFlow::Idle, false, None),
            Some((UpdateControl::Advisory, v.clone()))
        );
        assert_eq!(
            control(Some(&available), &UpdateFlow::Idle, false, Some("0.2.135")),
            None
        );
        assert_eq!(
            control(
                Some(&status("0.2.136", true)),
                &UpdateFlow::Idle,
                false,
                Some("0.2.135")
            ),
            Some((UpdateControl::Advisory, "0.2.136".into()))
        );
    }

    #[test]
    fn manual_updates_and_later_keep_their_next_action_visible() {
        let available = status("0.2.136", true);
        assert_eq!(
            update_control(
                Some(&available),
                &UpdateFlow::Idle,
                true,
                None,
                false,
                true,
                None
            ),
            Some((UpdateControl::Available, "0.2.136".into()))
        );
        assert_eq!(
            update_control(
                Some(&available),
                &UpdateFlow::Downloading,
                true,
                None,
                false,
                true,
                None
            ),
            Some((UpdateControl::Downloading, "0.2.136".into()))
        );
        // Later applies only to that staged version, independently of the feed.
        assert_eq!(
            update_control(
                Some(&available),
                &ready("0.2.135"),
                true,
                None,
                true,
                true,
                Some("0.2.135")
            ),
            Some((UpdateControl::Ready { on_quit: true }, "0.2.135".into()))
        );
        assert_eq!(
            update_control(
                None,
                &ready("0.2.135"),
                true,
                None,
                true,
                true,
                Some("0.2.135")
            ),
            Some((UpdateControl::Ready { on_quit: true }, "0.2.135".into()))
        );
        assert_eq!(
            update_control(
                Some(&available),
                &ready("0.2.136"),
                true,
                None,
                true,
                true,
                Some("0.2.135")
            ),
            None
        );
    }

    #[test]
    fn update_control_labels_say_what_a_click_does() {
        let label = |control| update_control_label(&control, "0.2.135");
        assert_eq!(label(UpdateControl::Downloading), "Downloading v0.2.135…");
        assert!(label(UpdateControl::Ready { on_quit: true }).contains("installs when you quit"));
        assert!(
            label(UpdateControl::Ready { on_quit: false }).contains("Click to restart and install")
        );
        assert!(
            label(UpdateControl::Failed("offline".into())).contains("offline. Click to try again.")
        );
        assert!(label(UpdateControl::Advisory).contains("`harness update`"));
        assert!(label(UpdateControl::Available).contains("Click to download"));
    }

    fn quiet(flow: &UpdateFlow) -> RestartInputs<'_> {
        RestartInputs {
            flow,
            enabled: true,
            postponed: None,
            running_turns: 0,
            unsaved_edits: false,
            unsent_input: false,
            live_terminals: 0,
            idle_for: Duration::from_secs(120),
            frontmost: true,
            countdown_for: None,
        }
    }

    #[test]
    fn auto_restart_needs_a_staged_update_and_the_setting() {
        let staged = ready("0.2.135");
        assert_eq!(auto_restart_decision(&quiet(&staged)), AutoRestart::Restart);
        for flow in [
            UpdateFlow::Idle,
            UpdateFlow::Downloading,
            UpdateFlow::Failed("x".into()),
        ] {
            assert_eq!(auto_restart_decision(&quiet(&flow)), AutoRestart::Off);
        }
        let off = RestartInputs {
            enabled: false,
            ..quiet(&staged)
        };
        assert_eq!(auto_restart_decision(&off), AutoRestart::Off);
        // "Later" holds for that version only.
        let later = RestartInputs {
            postponed: Some("0.2.135"),
            ..quiet(&staged)
        };
        assert_eq!(auto_restart_decision(&later), AutoRestart::Off);
        let newer = ready("0.2.136");
        let later_older = RestartInputs {
            postponed: Some("0.2.135"),
            ..quiet(&newer)
        };
        assert_eq!(auto_restart_decision(&later_older), AutoRestart::Restart);
    }

    #[test]
    fn auto_restart_waits_for_anything_a_restart_would_interrupt() {
        let staged = ready("0.2.135");
        let wait = |inputs: RestartInputs| auto_restart_decision(&inputs);
        assert_eq!(
            wait(RestartInputs {
                running_turns: 1,
                ..quiet(&staged)
            }),
            AutoRestart::Wait(RestartBlocker::RunningTurns)
        );
        assert_eq!(
            wait(RestartInputs {
                unsaved_edits: true,
                ..quiet(&staged)
            }),
            AutoRestart::Wait(RestartBlocker::UnsavedEdits)
        );
        assert_eq!(
            wait(RestartInputs {
                unsent_input: true,
                ..quiet(&staged)
            }),
            AutoRestart::Wait(RestartBlocker::UnsentInput)
        );
        assert_eq!(
            wait(RestartInputs {
                live_terminals: 2,
                ..quiet(&staged)
            }),
            AutoRestart::Wait(RestartBlocker::LiveTerminals)
        );
        // A run outranks being idle: nothing is weighed against it.
        assert_eq!(
            wait(RestartInputs {
                running_turns: 1,
                idle_for: Duration::from_secs(3600),
                frontmost: false,
                ..quiet(&staged)
            }),
            AutoRestart::Wait(RestartBlocker::RunningTurns)
        );
    }

    #[test]
    fn auto_restart_waits_for_the_person_to_step_away() {
        let staged = ready("0.2.135");
        let at = |idle: u64, frontmost: bool| {
            auto_restart_decision(&RestartInputs {
                idle_for: Duration::from_secs(idle),
                frontmost,
                ..quiet(&staged)
            })
        };
        let active = AutoRestart::Wait(RestartBlocker::UserActive);
        // In front: a minute without input.
        assert_eq!(at(5, true), active);
        assert_eq!(at(59, true), active);
        assert_eq!(at(60, true), AutoRestart::Restart);
        // Behind another app: a shorter quiet spell is enough.
        assert_eq!(at(5, false), active);
        assert_eq!(at(10, false), AutoRestart::Restart);
    }

    #[test]
    fn input_during_the_countdown_cancels_it() {
        let staged = ready("0.2.135");
        let counting = |idle: u64, counting: u64, frontmost: bool| {
            auto_restart_decision(&RestartInputs {
                idle_for: Duration::from_secs(idle),
                countdown_for: Some(Duration::from_secs(counting)),
                frontmost,
                ..quiet(&staged)
            })
        };
        assert_eq!(counting(65, 5, true), AutoRestart::Restart);
        // Input 2s ago, 5s into the countdown — even behind another app.
        assert_eq!(
            counting(2, 5, false),
            AutoRestart::Wait(RestartBlocker::UserActive)
        );
        assert_eq!(counting(15, 5, false), AutoRestart::Restart);
    }

    #[test]
    fn the_countdown_reads_whole_seconds_down_to_one() {
        assert_eq!(countdown_seconds_left(Duration::ZERO), 10);
        assert_eq!(countdown_seconds_left(Duration::from_millis(1500)), 9);
        assert_eq!(countdown_seconds_left(Duration::from_millis(9900)), 1);
        assert_eq!(countdown_seconds_left(Duration::from_secs(30)), 1);
    }

    #[test]
    fn the_relaunch_marker_is_read_once_and_confirms_only_the_version_running() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(take_relaunch_marker(dir.path()), None);
        let marker = UpdateRelaunch {
            version: "0.2.135".into(),
            background: true,
        };
        write_relaunch_marker(dir.path(), &marker).unwrap();
        let json = std::fs::read_to_string(dir.path().join(RELAUNCH_MARKER)).unwrap();
        assert_eq!(json, r#"{"version":"0.2.135","background":true}"#);
        assert_eq!(take_relaunch_marker(dir.path()), Some(marker.clone()));
        assert_eq!(take_relaunch_marker(dir.path()), None);

        assert_eq!(
            updated_confirmation(Some(&marker), "0.2.135"),
            Some("0.2.135".into())
        );
        // The swap failed and the old version came back: say nothing.
        assert_eq!(updated_confirmation(Some(&marker), "0.2.134"), None);
        assert_eq!(updated_confirmation(None, "0.2.135"), None);
    }
}
