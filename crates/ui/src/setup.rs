//! First-run setup: four questions and a ready screen, each answer writing a
//! real setting (the iOS and Android `Onboarding` flows, desktop layout).
//!
//! 1. Agent: Graff first, preselected and recommended (it rides the CodeGraff
//!    sign-in); Claude Code and Codex are optional extras, switched on or off
//!    on this computer with `SetHarnessEnabled`.
//! 2. Effort: one of Graff's models and a reasoning level, the New session
//!    defaults (the composer's sticky picks).
//! 3. Autonomy: read only, workspace or full access, saved with
//!    `SetAutonomy`. Preselects Workspace unless someone already chose.
//! 4. Notifications: desktop banners on or off. Desktop banners need no OS
//!    permission prompt here, so nothing is asked before the answer.
//! 5. Ready: a summary and two starter prompts.
//!
//! The shell shows it once on a fresh install ([`Gate`]) and Settings →
//! Agents replays it. Skip setup leaves every default as it was.

use std::path::{Path, PathBuf};

use gpui::{
    AnyElement, Context, Entity, EventEmitter, FocusHandle, Focusable, IntoElement, Render,
    SharedString, Task, Window, div, prelude::*, px,
};
use harness_engine::registry::{HarnessDescriptor, descriptor_enabled};
use harness_proto::{Autonomy, HarnessId, Model, ReasoningLevel};
use harness_rpc::methods;

use crate::popover::Loadable;
use crate::state::AppState;
use crate::theme::Theme;
use crate::typography::ui_rems;

/// The questions before the ready screen (the progress bar's length).
pub const QUESTIONS: usize = 4;
const MARKER: &str = "setup.json";

/// Whether setup still has to run on this install, kept in
/// `{data_dir}/setup.json`. An install that already has `ui-settings.json`
/// and no marker predates setup: it never sees it unless replayed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    Pending,
    Done,
}

impl Gate {
    pub fn read(data_dir: &Path) -> Self {
        match std::fs::read_to_string(marker(data_dir)) {
            Ok(text) if text.contains("\"pending\"") => Gate::Pending,
            Ok(_) => Gate::Done,
            Err(_) if crate::settings::UiSettings::path(data_dir).exists() => Gate::Done,
            // A fresh install: remember that setup is owed, so quitting halfway
            // brings it back next launch.
            Err(_) => {
                Self::write(data_dir, Gate::Pending);
                Gate::Pending
            }
        }
    }

    pub fn write(data_dir: &Path, gate: Gate) {
        let state = match gate {
            Gate::Pending => "pending",
            Gate::Done => "done",
        };
        let _ = std::fs::create_dir_all(data_dir);
        if let Err(err) = std::fs::write(marker(data_dir), format!("{{\"state\":\"{state}\"}}\n")) {
            tracing::warn!(error = %err, "setup marker write failed");
        }
    }
}

/// Whether setup opens at launch, and at which step. `HARNESS_SETUP_STEP=n`
/// opens it at step `n` (the screenshot rig); `HARNESS_SETUP_OFF` never does.
pub fn pending_at_launch(data_dir: &Path) -> Option<usize> {
    if let Some(step) = std::env::var("HARNESS_SETUP_STEP").ok().and_then(|s| s.parse().ok()) {
        return Some(step);
    }
    if cfg!(test) || std::env::var_os("HARNESS_SETUP_OFF").is_some() {
        return None;
    }
    (Gate::read(data_dir) == Gate::Pending).then_some(0)
}

fn marker(data_dir: &Path) -> PathBuf {
    data_dir.join(MARKER)
}

/// The two starters on the ready screen.
pub const STARTERS: [&str; 2] = [
    "Tour this project and tell me how it fits together",
    "Find one small bug and fix it",
];
const STARTER_LABELS: [&str; 2] = ["Tour this project", "Fix a small bug"];

const EXTRAS: [HarnessId; 2] = [HarnessId::ClaudeCode, HarnessId::Codex];

const CAPABILITIES: [&str; 4] = [
    "Read files and run searches",
    "Edit files in this project",
    "Run commands outside it",
    "Approve its own requests",
];

fn autonomy_label(level: Autonomy) -> &'static str {
    match level {
        Autonomy::ReadOnly => "Read only",
        Autonomy::Workspace => "Workspace",
        Autonomy::FullAccess => "Full access",
    }
}

fn autonomy_blurb(level: Autonomy) -> &'static str {
    match level {
        Autonomy::ReadOnly => "Reads and plans. Asks before it changes anything.",
        Autonomy::Workspace => "Edits this project. Asks before anything else.",
        Autonomy::FullAccess => "Runs anything without asking.",
    }
}

fn autonomy_allows(level: Autonomy) -> [bool; 4] {
    match level {
        Autonomy::ReadOnly => [true, false, false, false],
        Autonomy::Workspace => [true, true, false, false],
        Autonomy::FullAccess => [true, true, true, true],
    }
}

const AUTONOMY_LEVELS: [Autonomy; 3] = [Autonomy::ReadOnly, Autonomy::Workspace, Autonomy::FullAccess];

fn effort_blurb(level: ReasoningLevel) -> &'static str {
    match level {
        ReasoningLevel::None | ReasoningLevel::Minimal => "Answers straight away.",
        ReasoningLevel::Low => "Quick answers and light edits.",
        ReasoningLevel::Medium => "Balanced for everyday changes.",
        ReasoningLevel::High => "Thinks before it edits. The default for real work.",
        ReasoningLevel::XHigh => "Takes its time on hard problems.",
        _ => "The most thinking it does. Slower, for the hardest work.",
    }
}

/// What the shell applies when setup finishes.
#[derive(Debug, Clone, PartialEq)]
pub struct SetupOutcome {
    /// Graff's model for new sessions: (id, label).
    pub model: Option<(String, String)>,
    pub reasoning: Option<ReasoningLevel>,
    pub notifications: bool,
    /// The starter to put in the composer, when one was picked.
    pub starter: Option<String>,
}

pub enum SetupEvent {
    Finished(SetupOutcome),
    Skipped,
}

pub struct SetupView {
    state: Entity<AppState>,
    focus: FocusHandle,
    step: usize,
    harnesses: Loadable<Vec<HarnessDescriptor>>,
    /// Extras switched on in the agent step (only installed ones can be).
    extras: Vec<HarnessId>,
    models: Loadable<Vec<Model>>,
    model: usize,
    level: Option<ReasoningLevel>,
    autonomy: Autonomy,
    autonomy_loaded: bool,
    notifications: bool,
    starter: Option<usize>,
    error: Option<String>,
    tasks: Vec<Task<()>>,
}

impl EventEmitter<SetupEvent> for SetupView {}

impl Focusable for SetupView {
    fn focus_handle(&self, _: &gpui::App) -> FocusHandle {
        self.focus.clone()
    }
}

impl SetupView {
    /// `notifications`: the current desktop-banner setting, preselected.
    /// `remembered`: the composer's remembered Graff model and effort.
    pub fn new(
        state: Entity<AppState>,
        notifications: bool,
        remembered: (Option<String>, Option<ReasoningLevel>),
        step: usize,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut view = Self {
            state,
            focus: cx.focus_handle(),
            step: step.min(QUESTIONS),
            harnesses: Loadable::Loading,
            extras: Vec::new(),
            models: Loadable::Loading,
            model: 0,
            level: remembered.1,
            autonomy: Autonomy::Workspace,
            autonomy_loaded: false,
            notifications,
            starter: None,
            error: None,
            tasks: Vec::new(),
        };
        view.load(remembered.0, cx);
        view
    }

    fn load(&mut self, remembered_model: Option<String>, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            self.harnesses = Loadable::Error("Harness is still starting".into());
            self.models = Loadable::Error("Harness is still starting".into());
            return;
        };
        let client = engine.clone();
        self.tasks.push(cx.spawn(async move |this, cx| {
            let result = client
                .client()
                .call(methods::LIST_HARNESSES, serde_json::json!({}))
                .await
                .map_err(|e| e.to_string())
                .and_then(|v| serde_json::from_value::<Vec<HarnessDescriptor>>(v).map_err(|e| e.to_string()));
            this.update(cx, |view, cx| {
                match result {
                    Ok(list) => {
                        view.extras = EXTRAS
                            .into_iter()
                            .filter(|id| {
                                list.iter().any(|d| d.id == *id && d.installed && descriptor_enabled(d))
                            })
                            .collect();
                        view.harnesses = Loadable::Ready(list);
                    }
                    Err(error) => view.harnesses = Loadable::Error(error),
                }
                cx.notify();
            })
            .ok();
        }));
        let client = engine.clone();
        self.tasks.push(cx.spawn(async move |this, cx| {
            let result = client
                .client()
                .call(methods::LIST_MODELS, serde_json::json!({ "harness": HarnessId::Graff, "force": false }))
                .await
                .map_err(|e| e.to_string())
                .and_then(|v| serde_json::from_value::<Vec<Model>>(v).map_err(|e| e.to_string()));
            this.update(cx, |view, cx| {
                match result {
                    Ok(list) => {
                        let list: Vec<Model> = list.into_iter().take(3).collect();
                        view.model = remembered_model
                            .as_deref()
                            .and_then(|id| list.iter().position(|m| m.id == id))
                            .unwrap_or(0);
                        view.models = Loadable::Ready(list);
                        view.fit_level();
                    }
                    Err(error) => view.models = Loadable::Error(error),
                }
                cx.notify();
            })
            .ok();
        }));
        self.tasks.push(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::GET_AUTONOMY, serde_json::json!({}))
                .await
                .map_err(|e| e.to_string());
            this.update(cx, |view, cx| {
                if let Ok(value) = result {
                    let chosen = value.get("chosen").and_then(|v| v.as_bool()).unwrap_or(false);
                    if chosen
                        && let Some(level) = value
                            .get("autonomy")
                            .and_then(|v| serde_json::from_value::<Autonomy>(v.clone()).ok())
                    {
                        view.autonomy = level;
                    }
                    view.autonomy_loaded = true;
                }
                cx.notify();
            })
            .ok();
        }));
    }

    fn ladder(&self) -> Vec<ReasoningLevel> {
        let model_levels = self
            .models
            .ready()
            .and_then(|models| models.get(self.model))
            .map(|m| m.reasoning_levels.clone())
            .unwrap_or_default();
        if !model_levels.is_empty() {
            return model_levels;
        }
        self.harnesses
            .ready()
            .and_then(|list| list.iter().find(|d| d.id == HarnessId::Graff))
            .map(|d| d.reasoning_levels.clone())
            .unwrap_or_default()
    }

    /// Keep the effort on the model's ladder: High when it has it, else the middle.
    fn fit_level(&mut self) {
        let ladder = self.ladder();
        if ladder.is_empty() {
            self.level = None;
            return;
        }
        if self.level.is_some_and(|level| ladder.contains(&level)) {
            return;
        }
        self.level = Some(if ladder.contains(&ReasoningLevel::High) {
            ReasoningLevel::High
        } else {
            ladder[ladder.len() / 2]
        });
    }

    fn step_effort(&mut self, delta: isize, cx: &mut Context<Self>) {
        let ladder = self.ladder();
        let Some(index) = self.level.and_then(|l| ladder.iter().position(|x| *x == l)) else {
            return;
        };
        let next = (index as isize + delta).clamp(0, ladder.len() as isize - 1) as usize;
        self.level = Some(ladder[next]);
        cx.notify();
    }

    fn descriptor(&self, id: HarnessId) -> Option<&HarnessDescriptor> {
        self.harnesses.ready()?.iter().find(|d| d.id == id)
    }

    fn toggle_extra(&mut self, id: HarnessId, cx: &mut Context<Self>) {
        if let Some(index) = self.extras.iter().position(|x| *x == id) {
            self.extras.remove(index);
        } else {
            self.extras.push(id);
        }
        cx.notify();
    }

    /// Write what the current step decided, then move on.
    fn next(&mut self, cx: &mut Context<Self>) {
        self.error = None;
        match self.step {
            0 => self.apply_extras(cx),
            2 => self.apply_autonomy(cx),
            _ => {}
        }
        if self.step >= QUESTIONS {
            self.finish(cx);
            return;
        }
        self.step += 1;
        cx.notify();
    }

    fn back(&mut self, cx: &mut Context<Self>) {
        if self.step > 0 {
            self.step -= 1;
            cx.notify();
        }
    }

    fn apply_extras(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let changes: Vec<(HarnessId, bool)> = EXTRAS
            .into_iter()
            .filter_map(|id| {
                let descriptor = self.descriptor(id)?;
                let on = self.extras.contains(&id);
                let was = descriptor.installed && descriptor_enabled(descriptor);
                (on != was && (descriptor.installed || !on)).then_some((id, on))
            })
            .collect();
        for (harness, enabled) in changes {
            let engine = engine.clone();
            self.tasks.push(cx.spawn(async move |this, cx| {
                let result = engine
                    .client()
                    .call(methods::SET_HARNESS_ENABLED, serde_json::json!({ "harness": harness, "enabled": enabled }))
                    .await;
                this.update(cx, |view, cx| {
                    match result {
                        Ok(value) => {
                            if let Ok(list) = serde_json::from_value::<Vec<HarnessDescriptor>>(value) {
                                view.harnesses = Loadable::Ready(list);
                            }
                        }
                        Err(error) => view.error = Some(error.to_string()),
                    }
                    cx.notify();
                })
                .ok();
            }));
        }
    }

    fn apply_autonomy(&mut self, cx: &mut Context<Self>) {
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let autonomy = self.autonomy;
        self.tasks.push(cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(methods::SET_AUTONOMY, serde_json::json!({ "autonomy": autonomy }))
                .await;
            if let Err(error) = result {
                this.update(cx, |view, cx| {
                    view.error = Some(format!("Couldn't save the access level: {error}"));
                    cx.notify();
                })
                .ok();
            }
        }));
    }

    fn outcome(&self) -> SetupOutcome {
        SetupOutcome {
            model: self
                .models
                .ready()
                .and_then(|models| models.get(self.model))
                .map(|m| (m.id.clone(), m.label.clone())),
            reasoning: self.level,
            notifications: self.notifications,
            starter: self.starter.map(|i| STARTERS[i].to_string()),
        }
    }

    fn finish(&mut self, cx: &mut Context<Self>) {
        cx.emit(SetupEvent::Finished(self.outcome()));
    }

    fn on_key(&mut self, event: &gpui::KeyDownEvent, _: &mut Window, cx: &mut Context<Self>) {
        let key = event.keystroke.key.as_str();
        let plain = !event.keystroke.modifiers.platform && !event.keystroke.modifiers.control;
        if !plain {
            return;
        }
        match key {
            "enter" => self.next(cx),
            "escape" => self.back(cx),
            "left" if self.step == 1 => self.step_effort(-1, cx),
            "right" if self.step == 1 => self.step_effort(1, cx),
            "left" if self.step == 2 => self.shift_autonomy(-1, cx),
            "right" if self.step == 2 => self.shift_autonomy(1, cx),
            _ => return,
        }
        cx.stop_propagation();
    }

    fn shift_autonomy(&mut self, delta: isize, cx: &mut Context<Self>) {
        let index = AUTONOMY_LEVELS.iter().position(|l| *l == self.autonomy).unwrap_or(1) as isize;
        self.autonomy = AUTONOMY_LEVELS[(index + delta).clamp(0, 2) as usize];
        cx.notify();
    }

    // ----- rendering ------------------------------------------------------

    fn question(&self) -> (&'static str, &'static str) {
        match self.step {
            0 => (
                "Start with Graff",
                "Graff is already connected through your CodeGraff sign-in. Add Claude Code or Codex too if you use them.",
            ),
            1 => (
                "How hard should it think?",
                "Your default for new Graff sessions. Change it per message from the composer.",
            ),
            2 => (
                "How much can it do without asking?",
                "Applies to every agent on this computer. Change it any time in Settings > Agents.",
            ),
            3 => (
                "Ping you when it needs you?",
                "A desktop banner when a session waits on you or finishes while Harness is in the background.",
            ),
            _ => ("Your first agent is ready", "Graff is live on this computer."),
        }
    }

    fn render_progress(&self, theme: &Theme) -> AnyElement {
        if self.step >= QUESTIONS {
            return div().h(px(18.0)).into_any_element();
        }
        let mut bars = div().flex().items_center().gap(px(4.0));
        for index in 0..QUESTIONS {
            bars = bars.child(
                div()
                    .w(px(36.0))
                    .h(px(3.0))
                    .rounded(px(2.0))
                    .bg(if index <= self.step { theme.text } else { theme.border }),
            );
        }
        div()
            .flex()
            .items_center()
            .gap(px(16.0))
            .child(bars)
            .child(
                div()
                    .text_size(ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .child(format!("{}/{}", self.step + 1, QUESTIONS)),
            )
            .into_any_element()
    }

    fn primary_button(&self, theme: &Theme, label: &'static str, cx: &mut Context<Self>) -> AnyElement {
        div()
            .id("setup-next")
            .flex()
            .items_center()
            .justify_center()
            .gap(px(6.0))
            .h(px(40.0))
            .px(px(28.0))
            .rounded(px(20.0))
            .bg(theme.solid)
            .text_color(theme.on_solid)
            .text_size(ui_rems(14.0))
            .font_weight(gpui::FontWeight::SEMIBOLD)
            .cursor_pointer()
            .hover(|s| s.opacity(0.9))
            .on_click(cx.listener(|this, _, _, cx| this.next(cx)))
            .child(label)
            .child(crate::icons::icon(crate::icons::ARROW_RIGHT).size(px(14.0)).text_color(theme.on_solid))
            .into_any_element()
    }

    fn render_left(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let (title, subtitle) = self.question();
        let last = self.step >= QUESTIONS;
        let mut footer = div().flex().items_center().gap(px(18.0)).child(self.primary_button(
            theme,
            if last { "Start a session" } else { "Next" },
            cx,
        ));
        if last {
            footer = footer.child(
                div()
                    .text_size(ui_rems(13.0))
                    .text_color(theme.text_muted)
                    .child("Change any of this in Settings"),
            );
        } else {
            footer = footer.child(
                div()
                    .id("setup-skip")
                    .text_size(ui_rems(13.0))
                    .text_color(theme.text_muted)
                    .cursor_pointer()
                    .hover(|s| s.text_color(theme.text))
                    .on_click(cx.listener(|_, _, _, cx| cx.emit(SetupEvent::Skipped)))
                    .child("Skip setup"),
            );
        }
        let back = (self.step > 0).then(|| {
            div()
                .id("setup-back")
                .flex()
                .items_center()
                .gap(px(4.0))
                .text_size(ui_rems(13.0))
                .text_color(theme.text_muted)
                .cursor_pointer()
                .hover(|s| s.text_color(theme.text))
                .on_click(cx.listener(|this, _, _, cx| this.back(cx)))
                .child(crate::icons::icon(crate::icons::ARROW_LEFT).size(px(13.0)).text_color(theme.text_muted))
                .child("Back")
        });
        div()
            .w(px(420.0))
            .flex_none()
            .h_full()
            .flex()
            .flex_col()
            .justify_between()
            .px(px(40.0))
            .pt(px(56.0))
            .pb(px(28.0))
            .bg(theme.bg)
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(self.render_progress(theme))
                    .children(back),
            )
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(12.0))
                    .child(
                        div()
                            .text_size(ui_rems(30.0))
                            .line_height(ui_rems(36.0))
                            .font_weight(gpui::FontWeight::BOLD)
                            .text_color(theme.text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(ui_rems(14.0))
                            .line_height(ui_rems(21.0))
                            .text_color(theme.text_muted)
                            .child(subtitle),
                    )
                    .children(self.error.clone().map(|e| crate::settings::widgets::error_strip(theme, e))),
            )
            .child(footer)
            .into_any_element()
    }

    fn check_circle(theme: &Theme, on: bool) -> gpui::Div {
        let ring = div()
            .size(px(22.0))
            .rounded_full()
            .flex()
            .items_center()
            .justify_center();
        if on {
            ring.bg(theme.solid).child(
                crate::icons::icon(crate::icons::CHECK).size(px(13.0)).text_color(theme.on_solid),
            )
        } else {
            ring.border_1().border_color(theme.border_strong)
        }
    }

    fn card(theme: &Theme, selected: bool) -> gpui::Div {
        div()
            .rounded(px(12.0))
            .border_1()
            .border_color(if selected { theme.text } else { theme.border })
            .bg(theme.surface_card)
            .p(px(14.0))
    }

    fn status_line(theme: &Theme, ok: bool, text: impl Into<SharedString>) -> gpui::Div {
        div()
            .flex()
            .items_center()
            .gap(px(6.0))
            .text_size(ui_rems(12.0))
            .text_color(theme.text_muted)
            .child(
                div()
                    .size(px(6.0))
                    .rounded_full()
                    .bg(if ok { theme.success } else { theme.text_faint }),
            )
            .child(text.into())
    }

    fn agent_card(&self, theme: &Theme, id: HarnessId, cx: &mut Context<Self>) -> AnyElement {
        let (icon_path, tint) = crate::pickers::harness_brand_icon(id);
        let graff = id == HarnessId::Graff;
        let descriptor = self.descriptor(id);
        let installed = descriptor.is_some_and(|d| d.installed);
        let selected = graff || self.extras.contains(&id);
        let name: SharedString = descriptor
            .map(|d| d.name.clone())
            .unwrap_or_else(|| match id {
                HarnessId::Graff => "Graff".into(),
                HarnessId::ClaudeCode => "Claude Code".into(),
                _ => "OpenAI Codex".into(),
            })
            .into();
        let status = if graff {
            Self::status_line(theme, true, "Connected with CodeGraff")
        } else if self.harnesses.ready().is_none() {
            Self::status_line(theme, false, "Checking this computer…")
        } else if !installed {
            Self::status_line(theme, false, "Not installed. Install it from Settings > Agents")
        } else if selected {
            Self::status_line(theme, true, "Optional, on")
        } else {
            Self::status_line(theme, true, "Optional, ready")
        };
        let mut mark = crate::icons::icon(icon_path).size(px(20.0));
        mark = match tint {
            Some(tint) => mark.text_color(tint),
            None => mark.text_color(theme.text),
        };
        let mut title = div()
            .flex()
            .items_center()
            .gap(px(8.0))
            .text_size(ui_rems(15.0))
            .font_weight(gpui::FontWeight::SEMIBOLD)
            .text_color(theme.text)
            .child(name);
        if graff {
            title = title.child(
                div()
                    .px(px(7.0))
                    .py(px(1.0))
                    .rounded(px(5.0))
                    .bg(theme.solid)
                    .text_color(theme.on_solid)
                    .text_size(ui_rems(11.0))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .child("Recommended"),
            );
        }
        let pickable = !graff && installed;
        Self::card(theme, selected)
            .id(SharedString::from(format!("setup-agent-{id:?}")))
            .flex_1()
            .min_w(px(220.0))
            .h(px(118.0))
            .flex()
            .flex_col()
            .justify_between()
            .when(!graff && !installed && self.harnesses.ready().is_some(), |el| el.opacity(0.6))
            .when(pickable, |el| {
                el.cursor_pointer()
                    .hover(|s| s.border_color(theme.text_muted))
                    .on_click(cx.listener(move |this, _, _, cx| this.toggle_extra(id, cx)))
            })
            .child(
                div()
                    .flex()
                    .items_start()
                    .justify_between()
                    .child(
                        div()
                            .size(px(36.0))
                            .rounded(px(9.0))
                            .bg(theme.element_hover)
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(mark),
                    )
                    .child(Self::check_circle(theme, selected)),
            )
            .child(div().flex().flex_col().gap(px(3.0)).child(title).child(status))
            .into_any_element()
    }

    fn render_agents(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap(px(12.0))
            .w(px(480.0))
            .child(self.agent_card(theme, HarnessId::Graff, cx))
            .child(
                div()
                    .mt(px(6.0))
                    .text_size(ui_rems(11.0))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(theme.text_muted)
                    .child("OPTIONAL EXTRAS"),
            )
            .child(
                div()
                    .flex()
                    .gap(px(12.0))
                    .child(self.agent_card(theme, HarnessId::ClaudeCode, cx))
                    .child(self.agent_card(theme, HarnessId::Codex, cx)),
            )
            .child(
                div()
                    .text_size(ui_rems(12.0))
                    .text_color(theme.text_faint)
                    .child("No extras are fine: Graff does everything here. Add more later in Settings > Agents."),
            )
            .into_any_element()
    }

    fn round_button(theme: &Theme, id: &'static str, glyph: &'static str) -> gpui::Stateful<gpui::Div> {
        div()
            .id(id)
            .size(px(34.0))
            .rounded_full()
            .border_1()
            .border_color(theme.border)
            .flex()
            .items_center()
            .justify_center()
            .text_size(ui_rems(18.0))
            .text_color(theme.text)
            .cursor_pointer()
            .hover(|s| s.bg(theme.element_hover))
            .child(glyph)
    }

    fn render_effort(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let mut tabs = div()
            .flex()
            .p(px(3.0))
            .gap(px(3.0))
            .rounded(px(10.0))
            .bg(theme.element_hover);
        match &self.models {
            Loadable::Ready(models) if !models.is_empty() => {
                for (index, model) in models.iter().enumerate() {
                    let selected = index == self.model;
                    tabs = tabs.child(
                        div()
                            .id(("setup-model", index))
                            .flex_1()
                            .px(px(12.0))
                            .py(px(6.0))
                            .rounded(px(8.0))
                            .text_size(ui_rems(13.0))
                            .text_color(if selected { theme.text } else { theme.text_muted })
                            .when(selected, |el| el.bg(theme.surface_card).font_weight(gpui::FontWeight::MEDIUM))
                            .flex()
                            .justify_center()
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.model = index;
                                this.fit_level();
                                cx.notify();
                            }))
                            .child(model.label.clone()),
                    );
                }
            }
            Loadable::Error(error) => {
                tabs = tabs.child(div().px(px(10.0)).py(px(6.0)).text_size(ui_rems(12.0)).text_color(theme.text_muted).child(format!("Couldn't list Graff's models: {error}")));
            }
            _ => {
                tabs = tabs.child(div().px(px(10.0)).py(px(6.0)).text_size(ui_rems(12.0)).text_color(theme.text_muted).child("Loading Graff's models…"));
            }
        }
        let ladder = self.ladder();
        let index = self.level.and_then(|l| ladder.iter().position(|x| *x == l));
        let mut bar = div().flex().gap(px(4.0)).w_full();
        for (i, level) in ladder.iter().copied().enumerate() {
            let filled = index.is_some_and(|at| i <= at);
            bar = bar.child(
                div()
                    .id(("setup-effort", i))
                    .flex_1()
                    .h(px(10.0))
                    .rounded(px(5.0))
                    .bg(if filled { theme.text } else { theme.border })
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.level = Some(level);
                        cx.notify();
                    })),
            );
        }
        let (label, blurb, position) = match (self.level, index) {
            (Some(level), Some(at)) => (
                crate::pickers::reasoning_label(level).to_string(),
                effort_blurb(level).to_string(),
                format!("Level {} of {}", at + 1, ladder.len()),
            ),
            _ => ("Default".to_string(), "Graff picks how hard to think.".to_string(), String::new()),
        };
        div()
            .w(px(480.0))
            .flex()
            .flex_col()
            .gap(px(22.0))
            .child(
                div()
                    .text_size(ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .child("Graff's models from your CodeGraff account"),
            )
            .child(tabs)
            .child(
                Self::card(theme, false)
                    .p(px(24.0))
                    .flex()
                    .flex_col()
                    .gap(px(16.0))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .justify_between()
                            .child(
                                Self::round_button(theme, "setup-effort-less", "−")
                                    .on_click(cx.listener(|this, _, _, cx| this.step_effort(-1, cx))),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .items_center()
                                    .child(
                                        div()
                                            .text_size(ui_rems(34.0))
                                            .font_weight(gpui::FontWeight::BOLD)
                                            .text_color(theme.text)
                                            .child(label),
                                    )
                                    .child(div().text_size(ui_rems(12.0)).text_color(theme.text_muted).child(position)),
                            )
                            .child(
                                Self::round_button(theme, "setup-effort-more", "+")
                                    .on_click(cx.listener(|this, _, _, cx| this.step_effort(1, cx))),
                            ),
                    )
                    .child(bar)
                    .child(
                        div()
                            .flex()
                            .justify_center()
                            .text_size(ui_rems(13.0))
                            .text_color(theme.text_muted)
                            .child(blurb),
                    ),
            )
            .child(
                div()
                    .text_size(ui_rems(12.0))
                    .text_color(theme.text_faint)
                    .child("← / → change the level."),
            )
            .into_any_element()
    }

    fn render_autonomy(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let at = AUTONOMY_LEVELS.iter().position(|l| *l == self.autonomy).unwrap_or(1);
        let mut stops = div().flex().w_full();
        for (i, level) in AUTONOMY_LEVELS.into_iter().enumerate() {
            let selected = i == at;
            stops = stops.child(
                div()
                    .id(("setup-autonomy", i))
                    .flex_1()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(8.0))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.autonomy = level;
                        cx.notify();
                    }))
                    .child(
                        div()
                            .size(px(if selected { 18.0 } else { 12.0 }))
                            .rounded_full()
                            .bg(if i <= at { theme.text } else { theme.border_strong }),
                    )
                    .child(
                        div()
                            .text_size(ui_rems(12.0))
                            .text_color(if selected { theme.text } else { theme.text_muted })
                            .when(selected, |el| el.font_weight(gpui::FontWeight::SEMIBOLD))
                            .child(autonomy_label(level)),
                    ),
            );
        }
        let allows = autonomy_allows(self.autonomy);
        let mut list = Self::card(theme, false).flex().flex_col().gap(px(12.0)).p(px(18.0));
        for (i, capability) in CAPABILITIES.into_iter().enumerate() {
            let on = allows[i];
            list = list.child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(10.0))
                    .child(Self::check_circle(theme, on).size(px(18.0)))
                    .child(
                        div()
                            .text_size(ui_rems(13.0))
                            .text_color(if on { theme.text } else { theme.text_faint })
                            .child(capability),
                    ),
            );
        }
        div()
            .w(px(480.0))
            .flex()
            .flex_col()
            .gap(px(22.0))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(6.0))
                    .child(
                        div()
                            .text_size(ui_rems(34.0))
                            .font_weight(gpui::FontWeight::BOLD)
                            .text_color(theme.text)
                            .child(autonomy_label(self.autonomy)),
                    )
                    .child(
                        div()
                            .text_size(ui_rems(13.0))
                            .text_color(theme.text_muted)
                            .child(autonomy_blurb(self.autonomy)),
                    ),
            )
            .child(
                div()
                    .relative()
                    .w_full()
                    .child(
                        div()
                            .absolute()
                            .top(px(8.0))
                            .left(px(80.0))
                            .right(px(80.0))
                            .h(px(2.0))
                            .bg(theme.border),
                    )
                    .child(stops),
            )
            .child(list)
            .into_any_element()
    }

    fn choice_card(
        &self,
        theme: &Theme,
        id: &'static str,
        selected: bool,
        icon_path: &'static str,
        title: &'static str,
        body: &'static str,
    ) -> gpui::Stateful<gpui::Div> {
        Self::card(theme, selected)
            .id(id)
            .flex()
            .items_center()
            .gap(px(14.0))
            .cursor_pointer()
            .hover(|s| s.border_color(theme.text_muted))
            .child(
                div()
                    .size(px(36.0))
                    .rounded(px(9.0))
                    .bg(theme.element_hover)
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(crate::icons::icon(icon_path).size(px(18.0)).text_color(theme.text)),
            )
            .child(
                div()
                    .flex_1()
                    .flex()
                    .flex_col()
                    .gap(px(2.0))
                    .child(
                        div()
                            .text_size(ui_rems(15.0))
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(theme.text)
                            .child(title),
                    )
                    .child(div().text_size(ui_rems(12.0)).text_color(theme.text_muted).child(body)),
            )
            .child(Self::check_circle(theme, selected))
    }

    fn render_notify(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        div()
            .w(px(480.0))
            .flex()
            .flex_col()
            .gap(px(12.0))
            .child(
                self.choice_card(
                    theme,
                    "setup-notify-yes",
                    self.notifications,
                    crate::icons::BELL,
                    "Yes, ping me",
                    "When a session needs your input, finishes, or fails.",
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.notifications = true;
                    cx.notify();
                })),
            )
            .child(
                self.choice_card(
                    theme,
                    "setup-notify-no",
                    !self.notifications,
                    crate::icons::CHECK,
                    "No, I'll check in",
                    "Sessions still show their status in the sidebar.",
                )
                .on_click(cx.listener(|this, _, _, cx| {
                    this.notifications = false;
                    cx.notify();
                })),
            )
            .child(
                div()
                    .text_size(ui_rems(12.0))
                    .text_color(theme.text_faint)
                    .child("Sounds and the background-only rule live in Settings > Notifications."),
            )
            .into_any_element()
    }

    fn summary_row(theme: &Theme, key: &'static str, value: impl Into<SharedString>) -> gpui::Div {
        div()
            .flex()
            .flex_col()
            .gap(px(2.0))
            .flex_1()
            .child(div().text_size(ui_rems(11.0)).text_color(theme.text_muted).child(key))
            .child(
                div()
                    .text_size(ui_rems(14.0))
                    .font_weight(gpui::FontWeight::MEDIUM)
                    .text_color(theme.text)
                    .child(value.into()),
            )
    }

    fn render_ready(&self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let outcome = self.outcome();
        let mut agents = vec!["Graff".to_string()];
        for id in &self.extras {
            if let Some(d) = self.descriptor(*id) {
                agents.push(d.name.clone());
            }
        }
        let model = outcome.model.map(|m| m.1).unwrap_or_else(|| "Default".into());
        let thinking = outcome
            .reasoning
            .map(|l| crate::pickers::reasoning_label(l).to_string())
            .unwrap_or_else(|| "Default".into());
        let mut chips = div().flex().flex_wrap().gap(px(8.0));
        for (index, label) in STARTER_LABELS.into_iter().enumerate() {
            let selected = self.starter == Some(index);
            chips = chips.child(
                div()
                    .id(("setup-starter", index))
                    .px(px(14.0))
                    .py(px(8.0))
                    .rounded(px(18.0))
                    .border_1()
                    .border_color(if selected { theme.text } else { theme.border })
                    .bg(if selected { theme.element_active } else { theme.surface_card })
                    .text_size(ui_rems(13.0))
                    .text_color(theme.text)
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.starter = if this.starter == Some(index) { None } else { Some(index) };
                        cx.notify();
                    }))
                    .child(label),
            );
        }
        div()
            .w(px(480.0))
            .flex()
            .flex_col()
            .gap(px(18.0))
            .child(
                Self::card(theme, false)
                    .p(px(20.0))
                    .flex()
                    .flex_col()
                    .gap(px(16.0))
                    .child(
                        div()
                            .flex()
                            .child(Self::summary_row(theme, "Agents", agents.join(", ")))
                            .child(Self::summary_row(theme, "Model", model)),
                    )
                    .child(
                        div()
                            .flex()
                            .child(Self::summary_row(theme, "Thinking", thinking))
                            .child(Self::summary_row(theme, "Access", autonomy_label(self.autonomy))),
                    )
                    .child(
                        div().flex().child(Self::summary_row(
                            theme,
                            "Notifications",
                            if self.notifications { "Desktop banners on" } else { "Off" },
                        )),
                    ),
            )
            .child(
                div()
                    .text_size(ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .child("Start with a prompt, or open an empty session"),
            )
            .child(chips)
            .into_any_element()
    }
}

impl Render for SetupView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let right = match self.step {
            0 => self.render_agents(&theme, cx),
            1 => self.render_effort(&theme, cx),
            2 => self.render_autonomy(&theme, cx),
            3 => self.render_notify(&theme, cx),
            _ => self.render_ready(&theme, cx),
        };
        div()
            .id("setup")
            .track_focus(&self.focus)
            .key_context("Setup")
            .on_key_down(cx.listener(Self::on_key))
            .size_full()
            .flex()
            .flex_row()
            .bg(theme.bg)
            .text_color(theme.text)
            .font_family(theme.font_sans.clone())
            .child(self.render_left(&theme, cx))
            .child(div().w(px(1.0)).h_full().bg(theme.border))
            .child(
                div()
                    .flex_1()
                    .h_full()
                    .bg(theme.surface)
                    .flex()
                    .items_center()
                    .justify_center()
                    .pt(px(28.0))
                    .child(right),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_install_owes_setup_until_it_is_done() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(Gate::read(dir.path()), Gate::Pending);
        // Quitting halfway keeps it owed, even once settings were written.
        std::fs::write(crate::settings::UiSettings::path(dir.path()), "{}").unwrap();
        assert_eq!(Gate::read(dir.path()), Gate::Pending);
        Gate::write(dir.path(), Gate::Done);
        assert_eq!(Gate::read(dir.path()), Gate::Done);
    }

    #[test]
    fn an_existing_install_never_sees_setup_uninvited() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(crate::settings::UiSettings::path(dir.path()), "{}").unwrap();
        assert_eq!(Gate::read(dir.path()), Gate::Done);
        assert!(!marker(dir.path()).exists());
    }

    #[test]
    fn autonomy_levels_widen_in_order() {
        let counts: Vec<usize> = AUTONOMY_LEVELS
            .iter()
            .map(|l| autonomy_allows(*l).iter().filter(|x| **x).count())
            .collect();
        assert_eq!(counts, vec![1, 2, 4]);
    }
}
