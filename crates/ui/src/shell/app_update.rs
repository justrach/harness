//! Harness's own desktop updates, after the background download: the
//! titlebar update control, the automatic restart into a staged update once
//! nothing would be interrupted, and the one-time "Updated" confirmation on
//! the version it restarted into.
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
    /// Staged. `auto` = it restarts on its own in a quiet window;
    /// `on_quit` = otherwise it installs when Harness quits.
    Ready {
        auto: bool,
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
) -> Option<(UpdateControl, String)> {
    if desktop_update {
        match flow {
            UpdateFlow::Ready(staged) => {
                return Some((
                    UpdateControl::Ready {
                        auto: env_auto_update && restart_setting,
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
        UpdateControl::Ready { auto: true, .. } => format!(
            "v{version} is ready — Harness restarts to install it when you're idle. Click to restart now."
        ),
        UpdateControl::Ready {
            auto: false,
            on_quit: true,
        } => format!("v{version} is ready — it installs when you quit. Click to restart now."),
        UpdateControl::Ready {
            auto: false,
            on_quit: false,
        } => format!("v{version} is ready. Click to restart and install it."),
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

/// The shell's app-update UI state beyond the download flow itself.
pub(super) struct AppUpdateUi {
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
    pub(super) fn publish_update_phase(&self, cx: &mut App) {
        use crate::settings::devices::{SharedUpdatePhase, UpdatePhase};
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
            return Some((
                UpdateControl::Ready {
                    auto: false,
                    on_quit: false,
                },
                "preview".into(),
            ));
        }
        update_control(
            self.state.read(cx).update.as_ref(),
            &self.update_flow,
            self.install.supports_desktop_update(),
            self.update_dismissed.as_deref(),
            harness_update::desktop_auto_update_enabled(),
            settings::with_current(cx, |s| s.restart_to_install_updates),
        )
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
        let terminals = |panel: &Option<Entity<TerminalPanel>>| {
            panel
                .as_ref()
                .map_or(0, |panel| panel.read(cx).live_tab_count())
        };
        RestartInputs {
            flow: &self.update_flow,
            enabled: harness_update::desktop_auto_update_enabled()
                && settings::with_current(cx, |s| s.restart_to_install_updates),
            postponed: self.app_update.postponed.as_deref(),
            running_turns: self.state.read(cx).local_busy_turns(Utc::now()),
            unsaved_edits: !self.all_file_edits_flushed(cx),
            unsent_input: self.has_unsent_composer_input(cx),
            live_terminals: terminals(&self.terminal) + terminals(&self.right_terminal),
            idle_for: now.saturating_duration_since(self.app_update.last_input.get()),
            frontmost: cx.active_window().is_some(),
            countdown_for: self
                .app_update
                .countdown_started
                .map(|started| now.saturating_duration_since(started)),
        }
    }

    /// Unsent composer input anywhere: the live composer (with every chat's
    /// stashed draft) and the new-session canvases parked in other tabs and
    /// split panes.
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
        self.composer.read(cx).has_unsent_input(cx)
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
                None
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

    /// The automatic restart itself. Re-checks unsaved edits at the last
    /// moment and never prompts or discards: anything unsaved puts the
    /// update back and the watcher keeps waiting.
    fn restart_into_update_now(&mut self, background: bool, cx: &mut Context<Self>) {
        if !self.all_file_edits_flushed(cx) {
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
        self.install_and_relaunch(staged, relaunch, cx);
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

#[cfg(test)]
mod tests {
    use super::*;

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
            update_control(status, flow, desktop, dismissed, true, true)
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
            Some((UpdateControl::Available, v.clone()))
        );
        assert_eq!(
            control(Some(&available), &UpdateFlow::Downloading, true, None),
            Some((UpdateControl::Downloading, v.clone()))
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
        // Staged: the staged version, even if the feed moved on since.
        assert_eq!(
            control(
                Some(&status("0.2.136", true)),
                &ready("0.2.135"),
                true,
                None
            ),
            Some((
                UpdateControl::Ready {
                    auto: true,
                    on_quit: true
                },
                v.clone()
            ))
        );
        assert_eq!(
            update_control(Some(&available), &ready("0.2.135"), true, None, true, false),
            Some((
                UpdateControl::Ready {
                    auto: false,
                    on_quit: true
                },
                v.clone()
            ))
        );
        assert_eq!(
            update_control(Some(&available), &ready("0.2.135"), true, None, false, true),
            Some((
                UpdateControl::Ready {
                    auto: false,
                    on_quit: false
                },
                v.clone()
            ))
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
    fn update_control_labels_say_what_a_click_does() {
        let label = |control| update_control_label(&control, "0.2.135");
        assert_eq!(label(UpdateControl::Downloading), "Downloading v0.2.135…");
        assert_eq!(
            label(UpdateControl::Ready {
                auto: true,
                on_quit: true
            }),
            "v0.2.135 is ready — Harness restarts to install it when you're idle. Click to restart now."
        );
        assert!(
            label(UpdateControl::Ready {
                auto: false,
                on_quit: true
            })
            .contains("installs when you quit")
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
