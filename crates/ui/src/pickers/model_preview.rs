//! Private model picker experiment. Never enabled in release builds.
//! Ratings, task shortlists and dollar ranges are fixtures, not measurements.
use super::*;
use crate::icons;
use gpui::{relative, rgb};
use gpui_base::ElementExt;
use gpui_base::slider::{
    Slider, SliderEvent, SliderIndicator, SliderState, SliderThumb, SliderTrack,
};
use std::time::{Duration, Instant};

pub(super) const PICKER_WIDTH: f32 = 356.0;
const DETAIL_WIDTH: f32 = 276.0;
const SLIDER_SETTLE: Duration = Duration::from_millis(150);

#[derive(Clone, Copy)]
struct SliderMotion {
    from: f32,
    to: f32,
    started: Instant,
}
impl SliderMotion {
    fn position(self, now: Instant, reduced: bool) -> f32 {
        if reduced {
            return self.to;
        }
        let progress =
            now.saturating_duration_since(self.started).as_secs_f32() / SLIDER_SETTLE.as_secs_f32();
        self.from + (self.to - self.from) * motion::EASE_OUT_EXPO.eval(progress.clamp(0.0, 1.0))
    }
    fn active(self, now: Instant) -> bool {
        now.saturating_duration_since(self.started) < SLIDER_SETTLE
    }
}

#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum TaskKind {
    #[default]
    All,
    Everyday,
    Quick,
    Debug,
    Design,
}
impl TaskKind {
    const ALL: [Self; 5] = [
        Self::All,
        Self::Everyday,
        Self::Quick,
        Self::Debug,
        Self::Design,
    ];
    fn label(self) -> &'static str {
        match self {
            Self::All => "All",
            Self::Everyday => "Everyday",
            Self::Quick => "Quick edits",
            Self::Debug => "Debugging",
            Self::Design => "UI / design",
        }
    }
    fn icon(self) -> &'static str {
        match self {
            Self::All => icons::WIDGET,
            Self::Everyday => icons::CHECKLIST,
            Self::Quick => icons::FAST_TIER,
            Self::Debug => icons::ACTION_DEBUG,
            Self::Design => icons::MAGIC_STICK_3,
        }
    }
}

#[derive(Clone)]
pub(super) struct Pending {
    harness: HarnessId,
    model: Model,
    reasoning: Option<ReasoningLevel>,
    options: serde_json::Map<String, serde_json::Value>,
}

pub(super) struct Preview {
    pub enabled: bool,
    pub viewed: Option<HarnessId>,
    pub pending: Option<Pending>,
    category: TaskKind,
    slider: Option<Entity<SliderState>>,
    slider_events: Option<Subscription>,
    slider_observer: Option<Subscription>,
    slider_motion: Option<SliderMotion>,
    slider_dragging: bool,
    detail: Option<usize>,
    detail_hovered: bool,
    hover_target: Option<usize>,
    detail_task: Option<gpui::Task<()>>,
    pub detail_bounds: Option<gpui::Bounds<gpui::Pixels>>,
    row_bounds: std::collections::HashMap<usize, gpui::Bounds<gpui::Pixels>>,
    error: Option<String>,
}
impl Default for Preview {
    fn default() -> Self {
        Self {
            enabled: cfg!(debug_assertions)
                && std::env::var("HARNESS_MODEL_PICKER_PREVIEW").as_deref() == Ok("1"),
            viewed: None,
            pending: None,
            category: TaskKind::All,
            slider: None,
            slider_events: None,
            slider_observer: None,
            slider_motion: None,
            slider_dragging: false,
            detail: None,
            detail_hovered: false,
            hover_target: None,
            detail_task: None,
            detail_bounds: None,
            row_bounds: Default::default(),
            error: None,
        }
    }
}
impl Preview {
    pub fn reset(&mut self) {
        self.viewed = None;
        self.pending = None;
        self.slider = None;
        self.slider_events = None;
        self.slider_observer = None;
        self.slider_motion = None;
        self.slider_dragging = false;
        self.hide_detail();
        self.category = TaskKind::All;
        self.error = None;
    }
    pub(super) fn hide_detail(&mut self) {
        self.detail = None;
        self.detail_hovered = false;
        self.hover_target = None;
        self.detail_task = None;
        self.detail_bounds = None;
    }
    pub fn preferred_height(&self) -> f32 {
        self.pending.as_ref().map_or(480.0, |p| {
            (380.0 + p.model.options.len() as f32 * 60.0).min(480.0)
        })
    }
    pub fn animating(&self, reduced: bool) -> bool {
        !reduced && self.slider_motion.is_some_and(|m| m.active(Instant::now()))
    }
}

// Registry presentation only. Never use this list to filter live catalogs.
// Codegraff src/provider.zig, c9c89ada4afa4f5a4d3b6a7612626ca1a747a2af.
const PROVIDERS: &[(&str, &str, &str)] = &[
    ("anthropic", "Anthropic", icons::CLAUDE_MARK),
    ("codegraff", "Codegraff", icons::GRAFF_MARK),
    ("deepseek", "DeepSeek", icons::MAKER_DEEPSEEK),
    ("openai", "OpenAI", icons::OPENAI_MARK),
    ("google", "Google", icons::MAKER_GEMINI),
    ("minimax", "MiniMax", icons::MAKER_MINIMAX),
    ("xiaomi", "Xiaomi", icons::MAKER_MIMO),
    ("kilo", "Kilo Gateway", icons::PROVIDER_KILO),
    ("groq", "Groq", icons::PROVIDER_GROQ),
    ("cerebras", "Cerebras", icons::PROVIDER_CEREBRAS),
    ("mistral", "Mistral", icons::MAKER_MISTRAL),
    ("kimi", "Kimi", icons::MAKER_KIMI),
    ("moonshot", "Moonshot", icons::MAKER_KIMI),
    ("xai", "xAI", icons::GROK_MARK),
    ("zai", "Z.ai", icons::MAKER_ZAI),
    ("meta", "Meta", icons::MAKER_META),
    ("vercel", "Vercel AI Gateway", icons::PROVIDER_VERCEL),
    ("openrouter", "OpenRouter", icons::PROVIDER_OPENROUTER),
    ("fugu", "Sakana", icons::PROVIDER_FUGU),
    ("fireworks", "Fireworks", icons::PROVIDER_FIREWORKS),
    ("mlx", "MLX", icons::PROVIDER_MLX),
    ("lmstudio", "LM Studio", icons::PROVIDER_LMSTUDIO),
    ("omlx", "oMLX", icons::PROVIDER_OMLX),
    ("chatgpt-new", "ChatGPT plan", icons::OPENAI_MARK),
    ("codex", "Codex / ChatGPT", icons::OPENAI_MARK),
];
fn route(model: &Model) -> &str {
    model
        .id
        .split_once('/')
        .map(|(route, _)| route)
        .unwrap_or_else(|| model_maker(model).unwrap_or("other"))
}
fn provider(id: &str) -> (&str, &'static str) {
    PROVIDERS
        .iter()
        .find(|(key, _, _)| *key == id)
        .map(|(_, name, icon)| (*name, *icon))
        .unwrap_or((id, icons::GLOBE))
}
fn model_icon(model: &Model) -> &'static str {
    model_maker(model)
        .and_then(maker_icon)
        .unwrap_or_else(|| provider(route(model)).1)
}
fn brand_accent(model: &Model, theme: &Theme) -> gpui::Hsla {
    // Only sourced product/brand accents. Unverified brands stay neutral.
    match model_maker(model).unwrap_or(route(model)) {
        "openai" | "codex" | "chatgpt-new" => rgb(0x66b5ff).into(),
        "anthropic" => rgb(0xd97757).into(),
        "moonshot" | "kimi" => rgb(if theme.appearance.is_dark() {
            0x00a1ff
        } else {
            0x007cff
        })
        .into(),
        "deepseek" => rgb(0x3964fe).into(),
        "google" => rgb(0x3186ff).into(),
        "minimax" => rgb(0x1887fb).into(),
        "xiaomi" => rgb(0xff6900).into(),
        "mistral" => rgb(0xff5229).into(),
        "codegraff" => rgb(0x0285ff).into(),
        "groq" => rgb(0xf43e01).into(),
        "cerebras" => gpui::hsla(15.0 / 360.0, 0.88, 0.55, 1.0),
        "kilo" => rgb(0xffdd00).into(),
        "openrouter" => gpui::hsla(239.0 / 360.0, 0.84, 0.67, 1.0),
        "fugu" => rgb(0xe10600).into(),
        "fireworks" => rgb(if theme.appearance.is_dark() {
            0xffc0e7
        } else {
            0x7a155c
        })
        .into(),
        "lmstudio" => rgb(if theme.appearance.is_dark() {
            0x7b74db
        } else {
            0x4338ca
        })
        .into(),
        "zai" | "xai" | "vercel" | "mlx" | "omlx" => theme.text,
        _ => theme.text_muted,
    }
}

#[derive(Clone, Copy)]
struct Profile {
    speed: u8,
    coding: u8,
    reasoning: u8,
    strength: &'static str,
    tradeoff: &'static str,
    cost: (f32, f32),
}
fn profile(model: &Model) -> Option<Profile> {
    let name = model.label.to_lowercase();
    let (speed, coding, reasoning, strength, tradeoff, cost) =
        if name.contains("haiku") || name.contains("mini") || name.contains("flash") {
            (
                5,
                3,
                3,
                "Fast, focused edits",
                "Less depth on complex tasks",
                (0.02, 0.08),
            )
        } else if name.contains("opus") || name.contains("astra") {
            (
                2,
                5,
                5,
                "Complex code and deep investigation",
                "More time and spend",
                (0.35, 1.20),
            )
        } else if name.contains("sonnet") || name.contains("gpt") || name.contains("codex") {
            (
                4,
                5,
                4,
                "Everyday coding and UI work",
                "Less depth than the largest models",
                (0.12, 0.48),
            )
        } else if name.contains("kimi")
            || name.contains("deepseek")
            || name.contains("mimo")
            || name.contains("qwen")
            || name.contains("glm")
        {
            (
                3,
                4,
                4,
                "Code and multi-step tasks",
                "Profile needs benchmarking",
                (0.05, 0.24),
            )
        } else {
            return None;
        };
    Some(Profile {
        speed,
        coding,
        reasoning,
        strength,
        tradeoff,
        cost,
    })
}
fn belongs(model: &Model, category: TaskKind) -> bool {
    if category == TaskKind::All {
        return true;
    }
    profile(model).is_some_and(|p| match category {
        TaskKind::Everyday => p.speed >= 3 && p.coding >= 4,
        TaskKind::Quick => p.speed >= 4,
        TaskKind::Debug => p.reasoning >= 4,
        TaskKind::Design => p.coding == 5,
        TaskKind::All => true,
    })
}
fn cost_text(model: &Model, level: Option<ReasoningLevel>) -> String {
    match model.billing.as_deref() {
        Some("plan") => return "Plan · usage varies".into(),
        Some("local") => return "Local · no API estimate".into(),
        _ => {}
    }
    let Some(p) = profile(model) else {
        return "Not estimated".into();
    };
    // Deliberately synthetic; this is NOT a pricing or token estimator.
    let index = level
        .and_then(|l| model.reasoning_levels.iter().position(|x| *x == l))
        .unwrap_or(0);
    let fixture_multiplier = 1.0 + index as f32 * 0.4;
    format!(
        "${:.2}–{:.2}",
        p.cost.0 * fixture_multiplier,
        p.cost.1 * fixture_multiplier
    )
}
fn validate_pending(pending: &Pending, live: Option<&Model>) -> bool {
    let Some(live) = live else {
        return false;
    };
    pending
        .reasoning
        .is_none_or(|level| live.reasoning_levels.contains(&level))
        && (live.reasoning_levels.is_empty() || pending.reasoning.is_some())
        && pending.options.iter().all(|(key, value)| {
            live.options.iter().any(|option| {
                option.id == *key
                    && option
                        .choices
                        .iter()
                        .any(|choice| value.as_str() == Some(&choice.id))
            })
        })
}

impl Pickers {
    pub(super) fn preview_viewed(&self, cx: &App) -> Option<HarnessId> {
        if self.harness_locked(cx) {
            self.effective_harness(cx)
        } else {
            self.preview.viewed.or_else(|| self.effective_harness(cx))
        }
    }
    pub(super) fn preview_reset_rows(&mut self, cx: &mut Context<Self>) {
        self.preview.hide_detail();
        self.preview.row_bounds.clear();
        *self.model_rows_cache.borrow_mut() = None;
        self.active = 0;
        self.model_scroll_base().set_offset(gpui::Point::default());
        self.active = model_slot_row(&self.model_rows(cx), 0).unwrap_or(0);
        cx.notify();
    }
    pub(super) fn preview_rows(&self, cx: &App) -> std::sync::Arc<Vec<ModelRowData>> {
        let key = ModelRowsKey {
            preview_category: Some(self.preview.category),
            query: self.search.read(cx).text().trim().to_string(),
            rail: self.model_rail,
            effective: self.preview_viewed(cx),
            locked: self.harness_locked(cx),
            catalog_rev: self.catalog_rev,
            selected: self.effective_model_id(cx).map(str::to_owned),
        };
        if let Some((old, rows)) = self.model_rows_cache.borrow().as_ref()
            && *old == key
        {
            return rows.clone();
        }
        let mut flat = Vec::new();
        for d in self.rail_descriptors(cx) {
            if self.model_rail == ModelRail::Harness && Some(d.id) != key.effective {
                continue;
            }
            if let Some(models) = self.models.get(&d.id).and_then(|l| l.ready()) {
                for model in models {
                    if self.model_rail == ModelRail::Favorites
                        && !self.defaults.is_favorite(d.id, &model.id)
                    {
                        continue;
                    }
                    if !belongs(model, self.preview.category) {
                        continue;
                    }
                    let haystack = format!(
                        "{} {} {}",
                        model.label,
                        model.id,
                        model.description.as_deref().unwrap_or("")
                    );
                    if !key.query.is_empty() && popover::match_rank(&key.query, &haystack).is_none()
                    {
                        continue;
                    }
                    flat.push(ModelRowData {
                        harness: d.id,
                        harness_name: d.name.clone().into(),
                        model: model.clone(),
                        selected_only: false,
                        header: None,
                    });
                }
            }
        }
        let grouped = self.preview.category == TaskKind::All
            && self.model_rail == ModelRail::Harness
            && key.query.is_empty();
        let rows = if grouped {
            let mut routes = Vec::<String>::new();
            for row in &flat {
                let id = route(&row.model);
                if !routes.iter().any(|r| r == id) {
                    routes.push(id.into());
                }
            }
            let mut rows = Vec::new();
            for id in routes {
                let mut section = flat
                    .iter()
                    .filter(|r| route(&r.model) == id)
                    .cloned()
                    .peekable();
                if let Some(first) = section.peek() {
                    let mut header = first.clone();
                    header.header = Some(provider(&id).0.to_owned().into());
                    rows.push(header);
                }
                rows.extend(section);
            }
            rows
        } else {
            flat
        };
        let rows = std::sync::Arc::new(rows);
        *self.model_rows_cache.borrow_mut() = Some((key, rows.clone()));
        rows
    }
    pub(super) fn preview_stage(&mut self, index: usize, cx: &mut Context<Self>) {
        // A shortcut cannot replace the pending model while adjusting reasoning.
        if self.preview.pending.is_some() {
            return;
        }
        let Some(row) = self
            .model_rows(cx)
            .get(index)
            .cloned()
            .filter(|r| r.header.is_none() && !r.selected_only)
        else {
            return;
        };
        if self.harness_locked(cx) && self.effective_harness(cx) != Some(row.harness) {
            return;
        }
        let reasoning = clamp_reasoning(self.effective_reasoning(cx), &row.model.reasoning_levels);
        let options = if self.effective_harness(cx) == Some(row.harness)
            && self.effective_model_id(cx) == Some(&row.model.id)
        {
            offered_options(&row.model, self.explicit_options(cx))
        } else {
            offered_options(
                &row.model,
                self.defaults
                    .model_options_for(row.harness, &row.model.id)
                    .cloned()
                    .unwrap_or_default(),
            )
        };
        let index = reasoning
            .and_then(|r| row.model.reasoning_levels.iter().position(|x| *x == r))
            .unwrap_or(0);
        let slider = cx.new(|_| {
            SliderState::new()
                .min(0.0)
                .max(row.model.reasoning_levels.len().saturating_sub(1).max(1) as f32)
                .step(1.0)
                .default_value(index as f32)
        });
        self.preview.pending = Some(Pending {
            harness: row.harness,
            model: row.model,
            reasoning,
            options,
        });
        self.preview.hide_detail();
        self.preview.slider_motion = None;
        self.preview.slider_dragging = false;
        self.preview.slider_events = Some(cx.subscribe(&slider, |this, slider, event, cx| {
            let Some(p) = &mut this.preview.pending else {
                return;
            };
            let value = match event {
                SliderEvent::Change(value) | SliderEvent::Release(value) => *value,
            };
            p.reasoning = p
                .model
                .reasoning_levels
                .get(value.end().round() as usize)
                .copied();
            let target = value.end().round()
                / p.model.reasoning_levels.len().saturating_sub(1).max(1) as f32;
            match event {
                SliderEvent::Change(_) => {
                    this.preview.slider_dragging = true;
                    this.preview.slider_motion = None;
                }
                SliderEvent::Release(_) => {
                    this.preview.slider_dragging = false;
                    this.preview.slider_motion = Some(SliderMotion {
                        from: slider.read(cx).percentage().end,
                        to: target,
                        started: Instant::now(),
                    });
                }
            }
            cx.notify();
        }));
        // The shared slider's accessibility actions call set_value, not Change.
        self.preview.slider_observer = Some(cx.observe(&slider, |this, slider, cx| {
            let Some(p) = &mut this.preview.pending else {
                return;
            };
            let level = p
                .model
                .reasoning_levels
                .get(slider.read(cx).value().end().round() as usize)
                .copied();
            if p.reasoning != level {
                p.reasoning = level;
                this.preview.slider_motion = None;
                cx.notify();
            }
        }));
        self.preview.slider = Some(slider);
        self.preview.error = None;
        self.focus_on_mount = true;
        cx.notify();
    }
    pub(super) fn preview_commit(&mut self, cx: &mut Context<Self>) {
        let Some(p) = self.preview.pending.clone() else {
            return;
        };
        let live = self
            .models
            .get(&p.harness)
            .and_then(|l| l.ready())
            .and_then(|models| models.iter().find(|m| m.id == p.model.id));
        if !validate_pending(&p, live)
            || (self.harness_locked(cx) && self.effective_harness(cx) != Some(p.harness))
        {
            self.preview.error =
                Some("Availability changed. Go back and select the model again.".into());
            cx.notify();
            return;
        }
        if self.state.read(cx).selected_chat.is_some() {
            self.update_chat_config(cx, move |config| {
                config.model = Some(p.model.id);
                config.reasoning = p.reasoning;
                config.model_options = p.options;
            });
        } else {
            self.config.harness = Some(p.harness);
            self.config.model = Some(p.model.id.clone());
            self.config.reasoning = p.reasoning;
            self.defaults.harness = Some(p.harness);
            self.defaults.reasoning = p.reasoning;
            *self.defaults.model_options_mut(p.harness, &p.model.id) = p.options;
            self.defaults
                .remember_model(p.harness, p.model.id, p.model.label);
            self.save_defaults();
        }
        self.animate_close(cx);
    }
    fn preview_back(&mut self, cx: &mut Context<Self>) {
        self.preview.pending = None;
        self.preview.slider = None;
        self.preview.slider_events = None;
        self.preview.slider_observer = None;
        self.preview.slider_motion = None;
        self.preview.slider_dragging = false;
        self.preview.error = None;
        self.focus_on_mount = true;
        cx.notify();
    }
    pub(super) fn preview_key(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if self.open_kind() != Some(PickerKind::HarnessModel) {
            return false;
        }
        if self.preview.pending.is_none() {
            // Details stay absent on open; keyboard navigation is an explicit preview.
            if matches!(event.keystroke.key.as_str(), "up" | "down") {
                let delta = if event.keystroke.key == "up" { -1 } else { 1 };
                let rows = self.model_rows(cx);
                let eligible: Vec<usize> = rows
                    .iter()
                    .enumerate()
                    .filter(|(_, r)| r.header.is_none())
                    .map(|(i, _)| i)
                    .collect();
                if let Some(position) = eligible.iter().position(|i| *i == self.active) {
                    let next =
                        (position as isize + delta).rem_euclid(eligible.len() as isize) as usize;
                    self.active = eligible[next];
                    self.model_scroll
                        .scroll_to_item(self.active, gpui::ScrollStrategy::Top);
                    self.preview.detail_task = None;
                    self.preview.detail = Some(self.active);
                    cx.notify();
                    cx.stop_propagation();
                    return true;
                }
            }
            if event.keystroke.key == "escape" && self.preview.detail.is_some() {
                self.preview.hide_detail();
                cx.notify();
                cx.stop_propagation();
                return true;
            }
            return false;
        }
        match event.keystroke.key.as_str() {
            "escape" => self.preview_back(cx),
            "enter" => self.preview_commit(cx),
            // Slider owns pointer/a11y; keyboard updates the same staged value.
            "left" | "down" | "right" | "up" | "home" | "end" => {
                let p = self.preview.pending.as_mut().unwrap();
                let levels = &p.model.reasoning_levels;
                if !levels.is_empty() {
                    let current = p
                        .reasoning
                        .and_then(|r| levels.iter().position(|x| *x == r))
                        .unwrap_or(0);
                    let index = match event.keystroke.key.as_str() {
                        "home" => 0,
                        "end" => levels.len() - 1,
                        "left" | "down" => current.saturating_sub(1),
                        _ => (current + 1).min(levels.len() - 1),
                    };
                    p.reasoning = Some(levels[index]);
                    if let Some(slider) = &self.preview.slider {
                        let now = Instant::now();
                        let from = self
                            .preview
                            .slider_motion
                            .map(|m| m.position(now, cx.reduce_motion()))
                            .unwrap_or(slider.read(cx).percentage().end);
                        slider.update(cx, |slider, cx| slider.set_value(index as f32, window, cx));
                        self.preview.slider_motion = Some(SliderMotion {
                            from,
                            to: index as f32 / levels.len().saturating_sub(1).max(1) as f32,
                            started: now,
                        });
                        self.preview.slider_dragging = false;
                    }
                }
            }
            // Don't let model-slot or agent-tab shortcuts affect a pending choice.
            _ if event.keystroke.modifiers.secondary()
                || (event.keystroke.modifiers.control && event.keystroke.key == "tab") => {}
            _ => return false,
        }
        cx.stop_propagation();
        cx.notify();
        true
    }
    fn preview_hover_row(&mut self, index: usize, entered: bool, cx: &mut Context<Self>) {
        if entered {
            self.active = index;
            self.preview.hover_target = Some(index);
            let delay = if self.preview.detail.is_some() {
                60
            } else {
                180
            };
            self.preview.detail_task = Some(cx.spawn(async move |this, cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(delay))
                    .await;
                let _ = this.update(cx, |this, cx| {
                    if this.open.is_open()
                        && this.preview.pending.is_none()
                        && this.preview.hover_target == Some(index)
                    {
                        this.preview.detail = Some(index);
                        this.preview.detail_bounds = None;
                        cx.notify();
                    }
                });
            }));
        } else if self.preview.hover_target == Some(index) {
            self.preview.hover_target = None;
            self.preview_hide_detail_soon(cx);
        }
        cx.notify();
    }
    fn preview_hide_detail_soon(&mut self, cx: &mut Context<Self>) {
        self.preview.detail_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(160))
                .await;
            let _ = this.update(cx, |this, cx| {
                if !this.preview.detail_hovered {
                    this.preview.hide_detail();
                    cx.notify();
                }
            });
        }));
    }
    pub(super) fn render_model_preview(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::of(cx).for_popup();
        let footer = div()
            .flex_none()
            .px(px(14.0))
            .py(px(8.0))
            .text_size(crate::typography::ui_rems(10.0))
            .text_color(theme.text_muted)
            .child("Preview · Dummy data · Do not merge");
        if let Some(p) = self.preview.pending.clone() {
            return div()
                .size_full()
                .flex()
                .flex_col()
                .child(self.preview_reasoning(p, &theme, cx))
                .child(footer)
                .into_any_element();
        }
        let viewed = self.preview_viewed(cx);
        let descriptors = self.rail_descriptors(cx);
        let tabs = self.render_harness_tabs(
            &descriptors,
            viewed,
            self.model_rail == ModelRail::Favorites,
            &theme,
            cx,
        );
        let categories = div()
            .id("preview-categories")
            .flex_none()
            .flex()
            .flex_wrap()
            .gap(px(4.0))
            .p(px(8.0))
            .children(TaskKind::ALL.into_iter().enumerate().map(|(ix, category)| {
                div()
                    .id(("preview-category", ix))
                    .role(gpui::Role::Button)
                    .aria_label(category.label())
                    .flex_none()
                    .h(px(30.0))
                    .px(px(10.0))
                    .rounded(px(6.0))
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .text_size(crate::typography::ui_rems(12.0))
                    .cursor_pointer()
                    .bg(if category == self.preview.category {
                        theme.surface_raised
                    } else {
                        theme.surface_overlay.opacity(0.0)
                    })
                    .hover(|s| s.bg(theme.surface_raised))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.preview.category = category;
                        this.preview_reset_rows(cx);
                    }))
                    .child(
                        icons::icon(category.icon())
                            .size(px(13.0))
                            .text_color(theme.text),
                    )
                    .child(category.label())
            }));
        let rows = self.model_rows(cx);
        let grouped = rows.iter().any(|r| r.header.is_some());
        let entity = cx.entity();
        let row_data = rows.clone();
        let list = gpui::uniform_list("preview-models", rows.len(), move |range, window, app| {
            entity.update(app, |this, cx| {
                range
                    .filter_map(|ix| {
                        row_data
                            .get(ix)
                            .map(|row| this.preview_row(ix, row, grouped, window, cx))
                    })
                    .collect::<Vec<_>>()
            })
        })
        .size_full()
        .px(px(6.0))
        .track_scroll(&self.model_scroll);
        let empty = match viewed.and_then(|h| self.models.get(&h)) {
            Some(Loadable::Error(message)) => self.retry_row(
                "preview-retry",
                message,
                PickerKind::HarnessModel,
                &theme,
                cx,
            ),
            Some(Loadable::Ready(_)) if self.preview.category != TaskKind::All => {
                empty_list_note(&theme, "No curated matches. Try All.")
            }
            Some(Loadable::Ready(_)) => empty_list_note(&theme, "No models found"),
            _ => empty_list_note(&theme, "Loading models…"),
        };
        div()
            .size_full()
            .flex()
            .flex_col()
            .text_color(theme.text)
            .child(tabs)
            .child(categories)
            .child(
                div()
                    .h(px(36.0))
                    .flex_none()
                    .px(px(12.0))
                    .flex()
                    .items_center()
                    .gap(px(8.0))
                    .child(
                        icons::icon(icons::MAGNIFER)
                            .size(px(14.0))
                            .text_color(theme.text_muted),
                    )
                    .child(div().flex_1().child(self.search.clone())),
            )
            .child(
                div().flex_1().min_h_0().flex().child(
                    div()
                        .relative()
                        .flex_1()
                        .min_w_0()
                        .h_full()
                        .when(rows.is_empty(), |el| el.child(empty))
                        .when(!rows.is_empty(), |el| el.child(list)),
                ),
            )
            .child(footer)
            .into_any_element()
    }
    fn preview_row(
        &mut self,
        ix: usize,
        row: &ModelRowData,
        grouped: bool,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).for_popup();
        let base = div()
            .w_full()
            .h(px(34.0))
            .px(px(10.0))
            .flex()
            .items_center()
            .gap(px(7.0));
        if let Some(title) = &row.header {
            return base
                .text_size(crate::typography::ui_rems(11.0))
                .font_weight(gpui::FontWeight::SEMIBOLD)
                .text_color(theme.text_muted)
                .child(
                    icons::icon(provider(route(&row.model)).1)
                        .size(px(14.0))
                        .text_color(theme.text),
                )
                .child(title.clone())
                .into_any_element();
        }
        let selected = self.effective_harness(cx) == Some(row.harness)
            && self.effective_model_id(cx) == Some(&row.model.id);
        let favorite = self.defaults.is_favorite(row.harness, &row.model.id);
        let harness = row.harness;
        let id = row.model.id.clone();
        let detail = if self.preview.detail == Some(ix) {
            let left = self.preview.row_bounds.get(&ix).is_some_and(|bounds| {
                f32::from(window.viewport_size().width - bounds.right()) < DETAIL_WIDTH + 16.0
                    && f32::from(bounds.left()) >= DETAIL_WIDTH + 16.0
            });
            let entity = cx.entity();
            let card = div()
                .id("preview-hover-card")
                .on_hover(cx.listener(|this, entered, _, cx| {
                    this.preview.detail_hovered = *entered;
                    if *entered {
                        this.preview.detail_task = None;
                    } else {
                        this.preview_hide_detail_soon(cx);
                    }
                }))
                .on_prepaint(move |bounds, _, cx| {
                    entity.update(cx, |this, _| this.preview.detail_bounds = Some(bounds));
                })
                .child(self.preview_detail(row, &theme));
            Some(popover::nested_menu(
                format!("preview-detail-{ix}"),
                card.into_any_element(),
                left,
            ))
        } else {
            None
        };
        let entity = cx.entity();
        let row = popover::menu_row_nav(
            &theme,
            selected,
            self.active == ix,
            format!("preview-row-{ix}"),
        )
        .w_full()
        .h(px(34.0))
        .py(px(0.0))
        .relative()
        .id(("preview-model", ix))
        .role(gpui::Role::Button)
        .aria_label(row.model.label.clone())
        .on_click(cx.listener(move |this, _, _, cx| this.preview_stage(ix, cx)))
        .when(!grouped, |el| {
            el.child(
                icons::icon(model_icon(&row.model))
                    .size(px(15.0))
                    .text_color(theme.text),
            )
        })
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .child(row.model.label.clone()),
        )
        .when(selected, |el| {
            el.child(
                icons::icon(icons::CHECK)
                    .size(px(12.0))
                    .text_color(theme.text_muted),
            )
        })
        .child(
            div()
                .id(("preview-star", ix))
                .role(gpui::Role::Button)
                .aria_label(if favorite {
                    "Unstar model"
                } else {
                    "Star model"
                })
                .size(px(24.0))
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(5.0))
                .hover(|s| s.bg(theme.surface_raised_hover))
                .on_click(cx.listener(move |this, _, _, cx| {
                    cx.stop_propagation();
                    this.toggle_model_favorite(harness, &id, cx);
                }))
                .child(
                    icons::icon(if favorite {
                        icons::STAR_BOLD
                    } else {
                        icons::STAR
                    })
                    .size(px(12.0))
                    .text_color(theme.text_muted),
                ),
        )
        .into_any_element();
        // The shared row owns its hover fade; the stable wrapper owns disclosure.
        div()
            .id(("preview-model-hover", ix))
            .relative()
            .w_full()
            .h(px(34.0))
            .on_prepaint(move |bounds, _, cx| {
                entity.update(cx, |this, _| {
                    this.preview.row_bounds.insert(ix, bounds);
                });
            })
            .on_hover(
                cx.listener(move |this, hovered, _, cx| this.preview_hover_row(ix, *hovered, cx)),
            )
            .child(row)
            .when_some(detail, |el, detail| el.child(detail))
            .into_any_element()
    }
    fn preview_detail(&self, row: &ModelRowData, theme: &Theme) -> AnyElement {
        let model = &row.model;
        let mut panel = popover::popover_card(theme)
            .id("preview-detail")
            .w(px(DETAIL_WIDTH))
            .flex_none()
            .max_h(px(360.0))
            .overflow_y_scroll()
            .p(px(16.0))
            .flex()
            .flex_col()
            .gap(px(12.0))
            .text_size(crate::typography::ui_rems(11.0))
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(8.0))
                    .child(
                        icons::icon(model_icon(model))
                            .size(px(20.0))
                            .text_color(theme.text),
                    )
                    .child(div().min_w_0().child(model.label.clone())),
            )
            .child(
                div()
                    .text_color(theme.text_muted)
                    .child(format!("via {}", provider(route(model)).0)),
            );
        if let Some(p) = profile(model) {
            for (label, value) in [
                ("Speed", p.speed),
                ("Coding", p.coding),
                ("Reasoning", p.reasoning),
            ] {
                panel = panel.child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .child(label)
                        .child(div().flex().gap(px(3.0)).children((0..5).map(|i| {
                            div()
                                .w(px(12.0))
                                .h(px(4.0))
                                .rounded(px(2.5))
                                .bg(if i < value {
                                    theme.text_muted
                                } else {
                                    theme.surface_raised
                                })
                        }))),
                );
            }
            panel = panel
                .child(div().child(p.strength))
                .child(div().text_color(theme.text_muted).child(p.tradeoff));
        } else {
            panel = panel.child(
                div()
                    .text_color(theme.text_muted)
                    .child("Profile not rated yet"),
            );
        }
        panel
            .child(
                div()
                    .flex()
                    .justify_between()
                    .child("Task cost")
                    .child(cost_text(model, None)),
            )
            .when_some(model.description.clone(), |el, description| {
                el.child(
                    div()
                        .pt(px(12.0))
                        .border_t_1()
                        .border_color(theme.border)
                        .text_color(theme.text_muted)
                        .child(description),
                )
            })
            .into_any_element()
    }
    fn preview_reasoning(
        &mut self,
        p: Pending,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let accent = brand_accent(&p.model, theme);
        let binary = binary_reasoning_switch(Some(&p.model));
        let label = p
            .reasoning
            .map(|l| reasoning_label_for_model(l, binary))
            .unwrap_or("Model default");
        let mut body = div()
            .id("preview-options")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .p(px(16.0))
            .flex()
            .flex_col()
            .gap(px(16.0))
            .child(
                div()
                    .id("preview-back")
                    .role(gpui::Role::Button)
                    .aria_label("Back to models")
                    .flex()
                    .items_center()
                    .gap(px(6.0))
                    .text_size(crate::typography::ui_rems(12.0))
                    .cursor_pointer()
                    .on_click(cx.listener(|this, _, _, cx| this.preview_back(cx)))
                    .child(
                        icons::icon(icons::ARROW_LEFT)
                            .size(px(14.0))
                            .text_color(theme.text),
                    )
                    .child("Models"),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap(px(12.0))
                    .child(
                        icons::icon(model_icon(&p.model))
                            .size(px(20.0))
                            .text_color(theme.text),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap(px(4.0))
                            .child(
                                div()
                                    .text_size(crate::typography::ui_rems(16.0))
                                    .font_weight(gpui::FontWeight::SEMIBOLD)
                                    .child(p.model.label.clone()),
                            )
                            .child(
                                div()
                                    .text_size(crate::typography::ui_rems(11.0))
                                    .text_color(theme.text_muted)
                                    .child(format!("via {}", provider(route(&p.model)).0)),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .justify_between()
                    .text_size(crate::typography::ui_rems(13.0))
                    .child(if binary { "Thinking" } else { "Reasoning" })
                    .child(label),
            );
        if p.model.reasoning_levels.len() > 1
            && let Some(slider) = &self.preview.slider
        {
            let raw = slider.read(cx).percentage().end;
            let percent = self
                .preview
                .slider_motion
                .map(|m| m.position(Instant::now(), cx.reduce_motion()))
                .unwrap_or(raw);
            let count = p.model.reasoning_levels.len();
            let thumb = if self.preview.slider_dragging {
                30.0
            } else {
                28.0
            };
            let track = SliderTrack::new(slider)
                .relative()
                .size_full()
                .child(
                    div()
                        .absolute()
                        .top(px(5.0))
                        .left(px(-14.0))
                        .right(px(-14.0))
                        .h(px(24.0))
                        .rounded(px(12.0))
                        .bg(theme.surface_raised),
                )
                .child(
                    SliderIndicator::new(slider)
                        .absolute()
                        .top(px(5.0))
                        .w_full()
                        .h(px(24.0))
                        .child(
                            div()
                                .absolute()
                                .top_0()
                                .bottom_0()
                                .left(px(-14.0))
                                .right(relative(1.0 - percent))
                                .mr(px(-14.0))
                                .rounded(px(12.0))
                                .bg(accent),
                        ),
                )
                .children((0..count).map(|i| {
                    div()
                        .absolute()
                        .top(px(15.0))
                        .left(relative(i as f32 / (count - 1) as f32))
                        .ml(px(-2.0))
                        .size(px(4.0))
                        .rounded(px(2.0))
                        .bg(if i as f32 / (count - 1) as f32 <= percent {
                            theme.on_solid.opacity(0.55)
                        } else {
                            theme.text_muted.opacity(0.4)
                        })
                }))
                .child(
                    SliderThumb::new(slider)
                        .absolute()
                        .top(px((34.0 - thumb) / 2.0))
                        .left(relative(percent))
                        .ml(px(-thumb / 2.0))
                        .size(px(thumb))
                        .rounded(px(thumb / 2.0))
                        .bg(rgb(0xfffefa))
                        .border_1()
                        .border_color(theme.border)
                        .shadow_sm(),
                );
            body = body
                .child(
                    div()
                        .px(px(14.0))
                        .child(Slider::new(slider).w_full().h(px(34.0)).child(track)),
                )
                .child(
                    div()
                        .flex()
                        .justify_between()
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.text_muted)
                        .child(if binary { "Off" } else { "Faster" })
                        .child(if binary { "On" } else { "Deeper" }),
                );
        } else {
            body = body.child(
                div()
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .child("This model has no adjustable reasoning level."),
            );
        }
        for (index, option) in p.model.options.iter().enumerate() {
            let selected = p
                .options
                .get(&option.id)
                .and_then(|v| v.as_str())
                .unwrap_or(&option.default_choice);
            let choices = option
                .choices
                .iter()
                .enumerate()
                .map(|(choice_index, choice)| {
                    let id = option.id.clone();
                    let value = choice.id.clone();
                    let default = choice.id == option.default_choice;
                    div()
                        .id(SharedString::from(format!(
                            "preview-option-{index}-{choice_index}"
                        )))
                        .role(gpui::Role::Button)
                        .aria_label(choice.label.clone())
                        .px(px(10.0))
                        .py(px(6.0))
                        .rounded(px(6.0))
                        .cursor_pointer()
                        .bg(if selected == choice.id {
                            theme.surface_raised
                        } else {
                            theme.surface_overlay.opacity(0.0)
                        })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(p) = &mut this.preview.pending {
                                if default {
                                    p.options.remove(&id);
                                } else {
                                    p.options.insert(id.clone(), value.clone().into());
                                }
                                cx.notify();
                            }
                        }))
                        .child(choice.label.clone())
                });
            body = body.child(
                div()
                    .text_size(crate::typography::ui_rems(12.0))
                    .flex()
                    .flex_col()
                    .gap(px(6.0))
                    .child(option.label.clone())
                    .child(div().flex().flex_wrap().gap(px(4.0)).children(choices)),
            );
        }
        body = body
            .child(
                div()
                    .flex()
                    .justify_between()
                    .text_size(crate::typography::ui_rems(12.0))
                    .child("Example task cost")
                    .child(cost_text(&p.model, p.reasoning)),
            )
            .when_some(self.preview.error.clone(), |el, error| {
                el.child(
                    div()
                        .text_size(crate::typography::ui_rems(12.0))
                        .text_color(theme.danger)
                        .child(error),
                )
            });
        div()
            .flex_1()
            .min_h_0()
            .flex()
            .flex_col()
            .text_color(theme.text)
            .child(body)
            .child(
                div().flex_none().px(px(16.0)).pb(px(12.0)).child(
                    popover::btn_primary(theme, "Use model")
                        .id("preview-use-model")
                        .role(gpui::Role::Button)
                        .aria_label("Use model")
                        .w_full()
                        .flex()
                        .items_center()
                        .justify_center()
                        .on_click(cx.listener(|this, _, _, cx| this.preview_commit(cx))),
                ),
            )
            .into_any_element()
    }
}

impl Pickers {
    /// Offline visual fixture: no engine, real accounts, or inference calls.
    #[cfg(feature = "appshots-fixture")]
    pub fn model_picker_fixture(
        state: Entity<AppState>,
        legacy: bool,
        large: bool,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut this = Self::new(state, cx);
        this.preview.enabled = !legacy && cfg!(debug_assertions);
        this.config.harness = Some(HarnessId::Graff);
        this.config.model = Some("anthropic/claude-sonnet-4.6".into());
        this.config.reasoning = Some(ReasoningLevel::High);
        this.harnesses = Loadable::Ready(
            [HarnessId::Graff, HarnessId::ClaudeCode, HarnessId::Codex]
                .into_iter()
                .map(|id| HarnessDescriptor {
                    id,
                    name: match id {
                        HarnessId::Graff => "graff",
                        HarnessId::ClaudeCode => "Claude Code",
                        _ => "Codex",
                    }
                    .into(),
                    installed: true,
                    can_install: false,
                    enabled: Some(true),
                    reasoning_levels: Vec::new(),
                    steering_mode: harness_proto::SteeringMode::StepBoundary,
                    supports_steering: false,
                })
                .collect(),
        );
        let samples = [
            (
                "anthropic/claude-sonnet-4.6",
                "Claude Sonnet 4.6",
                "anthropic",
            ),
            ("anthropic/claude-opus-4.6", "Claude Opus 4.6", "anthropic"),
            (
                "anthropic/claude-haiku-4.5",
                "Claude Haiku 4.5",
                "anthropic",
            ),
            ("openai/gpt-5.4", "GPT-5.4", "openai"),
            ("openai/gpt-5-mini", "GPT-5 mini", "openai"),
            ("kimi/kimi-k2.5", "Kimi K2.5", "moonshot"),
            ("google/gemini-flash", "Gemini Flash", "google"),
        ];
        let make = |id: String, label: String, maker: Option<String>| Model {
            id,
            label,
            maker,
            description: Some("200k context · Text & images · Fixture".into()),
            reasoning_levels: vec![
                ReasoningLevel::Low,
                ReasoningLevel::Medium,
                ReasoningLevel::High,
                ReasoningLevel::XHigh,
            ],
            options: Vec::new(),
            billing: Some("api".into()),
        };
        let mut models: Vec<Model> = samples
            .iter()
            .map(|(id, label, maker)| make((*id).into(), (*label).into(), Some((*maker).into())))
            .collect();
        models[2].reasoning_levels.clear();
        models[5].reasoning_levels = vec![ReasoningLevel::None, ReasoningLevel::High];
        models[0].options = vec![harness_proto::ModelOption {
            id: "context".into(),
            label: "Context window".into(),
            default_choice: "standard".into(),
            choices: vec![
                harness_proto::ModelOptionChoice {
                    id: "standard".into(),
                    label: "200k".into(),
                },
                harness_proto::ModelOptionChoice {
                    id: "long".into(),
                    label: "1M".into(),
                },
            ],
        }];
        for (id, label, _) in PROVIDERS {
            if models.iter().any(|m| route(m) == *id) {
                continue;
            }
            let mut model = make(
                format!("{id}/example-model"),
                format!("{label} example"),
                None,
            );
            model.reasoning_levels.clear();
            if ["mlx", "omlx", "lmstudio"].contains(id) {
                model.billing = Some("local".into());
            }
            if ["codex", "chatgpt-new"].contains(id) {
                model.billing = Some("plan".into());
            }
            models.push(model);
        }
        models.push(make(
            "custom-router/custom-model".into(),
            "Custom model".into(),
            None,
        ));
        if large {
            for i in 0..7000 {
                models.push(make(
                    format!("custom-router/model-{i}"),
                    format!("Catalog model {i:04}"),
                    None,
                ));
            }
        }
        this.models
            .insert(HarnessId::ClaudeCode, Loadable::Ready(models[..3].to_vec()));
        this.models
            .insert(HarnessId::Codex, Loadable::Ready(models[3..5].to_vec()));
        this.models
            .insert(HarnessId::Graff, Loadable::Ready(models));
        this.open.open(PickerKind::HarnessModel);
        this.open_model_height = if legacy {
            model_menu_height(this.setting_groups(cx).len())
        } else {
            480.0
        };
        this.boot_focus_pending = true;
        this.active = this.selected_model_index(cx);
        this
    }
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_preview_model(&mut self, id: &str, cx: &mut Context<Self>) {
        if let Some(index) = self
            .model_rows(cx)
            .iter()
            .position(|row| row.header.is_none() && row.model.id == id)
        {
            self.preview_stage(index, cx);
        }
    }
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_show_model_details(&mut self, id: &str, cx: &mut Context<Self>) {
        // Pin the requested synthetic snapshot state at capture time. Native
        // focus/mouse updates from other desktop windows must not change it.
        self.preview.detail_task = None;
        self.preview.hover_target = None;
        self.preview.detail_hovered = true;
        self.preview.detail = self
            .model_rows(cx)
            .iter()
            .position(|row| row.header.is_none() && row.model.id == id);
        cx.notify();
    }
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_model_position(&self, id: &str, cx: &App) -> Option<gpui::Point<gpui::Pixels>> {
        let index = self
            .model_rows(cx)
            .iter()
            .position(|r| r.header.is_none() && r.model.id == id)?;
        self.preview.row_bounds.get(&index).map(|b| b.center())
    }
    #[cfg(feature = "appshots-fixture")]
    pub fn fixture_slider_position(
        &self,
        percent: Option<f32>,
        cx: &App,
    ) -> Option<gpui::Point<gpui::Pixels>> {
        let slider = self.preview.slider.as_ref()?.read(cx);
        let bounds = slider.bounds();
        Some(gpui::point(
            bounds.left() + bounds.size.width * percent.unwrap_or(slider.percentage().end),
            bounds.center().y,
        ))
    }
}

#[cfg(all(test, feature = "appshots-fixture"))]
mod tests {
    use super::*;
    #[test]
    fn preview_slider_settle_has_intermediate_frames_and_respects_reduced_motion() {
        let now = Instant::now();
        let motion = SliderMotion {
            from: 0.42,
            to: 1.0 / 3.0,
            started: now,
        };
        assert_eq!(motion.position(now, false), motion.from);
        let mid = motion.position(now + Duration::from_millis(50), false);
        assert!(mid < motion.from && mid > motion.to);
        assert!((motion.position(now + SLIDER_SETTLE, false) - motion.to).abs() < 0.0001);
        assert_eq!(motion.position(now, true), motion.to);
        assert!(!motion.active(now + SLIDER_SETTLE));
    }

    #[gpui::test]
    fn preview_details_only_float_after_hover_and_survive_pointer_transfer(
        cx: &mut gpui::TestAppContext,
    ) {
        struct HoverFixture(Entity<Pickers>);
        impl Render for HoverFixture {
            fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
                div()
                    .size_full()
                    .p(px(20.0))
                    .child(self.0.update(cx, |p, cx| {
                        let content = p.render_model_preview(cx);
                        p.popover_frame_flush(PICKER_WIDTH, content, cx)
                    }))
            }
        }
        cx.update(|cx| cx.set_global(Theme::light()));
        let handle = cx.add_window(|_, cx| {
            let state = cx.new(|_| AppState::new());
            let picker = cx.new(|cx| Pickers::model_picker_fixture(state, false, false, cx));
            picker.update(cx, |p, _| {
                p.menu_geometry.insert(
                    PickerKind::HarnessModel,
                    popover::MenuGeometry {
                        height: 480.0,
                        below: false,
                    },
                );
            });
            HoverFixture(picker)
        });
        let picker = handle.read_with(cx, |f, _| f.0.clone()).unwrap();
        cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
            .unwrap();
        assert!(picker.read_with(cx, |p, _| p.preview.detail.is_none()));
        let position = picker.read_with(cx, |p, cx| {
            p.fixture_model_position("anthropic/claude-sonnet-4.6", cx)
                .unwrap()
        });
        cx.update_window(handle.into(), |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position,
                    ..Default::default()
                }),
                cx,
            );
        })
        .unwrap();
        assert!(picker.read_with(cx, |p, _| p.preview.detail.is_none()));
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(200));
        cx.run_until_parked();
        cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
            .unwrap();
        let (card, row) = picker.read_with(cx, |p, _| {
            (
                p.preview.detail_bounds.unwrap(),
                p.preview.row_bounds[&p.preview.detail.unwrap()],
            )
        });
        assert!(
            card.left() >= row.right(),
            "details must float beside, not occupy the list"
        );
        assert!(f32::from(row.size.width) < PICKER_WIDTH);
        cx.update_window(handle.into(), |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position: card.center(),
                    ..Default::default()
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                    position: card.center(),
                    button: gpui::MouseButton::Left,
                    ..Default::default()
                }),
                cx,
            );
        })
        .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(250));
        cx.run_until_parked();
        picker.read_with(cx, |p, _| {
            assert!(p.open.is_open());
            assert!(p.preview.detail.is_some());
        });
        cx.update_window(handle.into(), |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position: gpui::point(px(0.0), px(0.0)),
                    ..Default::default()
                }),
                cx,
            );
        })
        .unwrap();
        cx.run_until_parked();
        cx.executor().advance_clock(Duration::from_millis(200));
        cx.run_until_parked();
        assert!(picker.read_with(cx, |p, _| p.preview.detail.is_none()));
    }
    fn fixture(cx: &mut gpui::TestAppContext, large: bool) -> (Entity<AppState>, Entity<Pickers>) {
        cx.update(|cx| cx.set_global(Theme::dark()));
        let state = cx.new(|_| AppState::new());
        let picker = cx.new(|cx| Pickers::model_picker_fixture(state.clone(), false, large, cx));
        (state, picker)
    }
    #[gpui::test]
    fn preview_back_and_agent_browsing_do_not_change_run_config(cx: &mut gpui::TestAppContext) {
        let (_, picker) = fixture(cx, false);
        picker.update(cx, |p, cx| {
            let before = p.resolved(cx).chat_config();
            p.pick_harness(HarnessId::Codex, cx);
            assert_eq!(p.resolved(cx).chat_config(), before);
            p.fixture_preview_model("openai/gpt-5.4", cx);
            p.preview.pending.as_mut().unwrap().reasoning = Some(ReasoningLevel::Low);
            assert_eq!(p.resolved(cx).chat_config(), before);
            p.preview_back(cx);
            assert_eq!(p.resolved(cx).chat_config(), before);
            assert!(p.preview.pending.is_none());
            p.fixture_preview_model("openai/gpt-5.4", cx);
            p.preview.pending.as_mut().unwrap().reasoning = Some(ReasoningLevel::Low);
            p.preview_commit(cx);
            assert_eq!(p.resolved(cx).harness, Some(HarnessId::Codex));
            assert_eq!(p.resolved(cx).model.as_deref(), Some("openai/gpt-5.4"));
            assert_eq!(p.resolved(cx).reasoning, Some(ReasoningLevel::Low));
        });
    }
    #[gpui::test]
    fn preview_existing_chat_applies_model_effort_options_together(cx: &mut gpui::TestAppContext) {
        let (state, picker) = fixture(cx, false);
        state.update(cx, |s, _| {
            s.chats = vec![serde_json::from_value(serde_json::json!({"id":"preview-chat","deviceId":"preview","title":"Synthetic chat","archived":false,"createdAt":"2026-10-23T00:00:00Z","config":{"harness":"graff","model":"anthropic/claude-sonnet-4.6","reasoning":"high","sandbox":"workspace-write"}})).unwrap()];
            s.selected_chat = Some("preview-chat".into());
        });
        picker.update(cx, |p, cx| {
            p.config.model = None;
            p.config.reasoning = None;
            let before = state.read(cx).selected_chat_row().unwrap().config.clone();
            p.pick_harness(HarnessId::Codex, cx);
            assert_eq!(p.preview_viewed(cx), Some(HarnessId::Graff));
            p.fixture_preview_model("anthropic/claude-sonnet-4.6", cx);
            let pending = p.preview.pending.as_mut().unwrap();
            pending.reasoning = Some(ReasoningLevel::Medium);
            pending.options.insert("context".into(), "long".into());
            assert_eq!(state.read(cx).selected_chat_row().unwrap().config, before);
            p.preview_commit(cx);
            let config = state
                .read(cx)
                .selected_chat_row()
                .unwrap()
                .config
                .as_ref()
                .unwrap();
            assert_eq!(config.harness, HarnessId::Graff);
            assert_eq!(config.reasoning, Some(ReasoningLevel::Medium));
            assert_eq!(config.model_options["context"], "long");
        });
    }
    #[gpui::test]
    fn preview_removed_catalog_capability_blocks_commit(cx: &mut gpui::TestAppContext) {
        let (_, picker) = fixture(cx, false);
        picker.update(cx, |p, cx| {
            let before = p.resolved(cx).chat_config();
            p.fixture_preview_model("openai/gpt-5.4", cx);
            // The catalog changes while the second screen is open.
            if let Some(Loadable::Ready(models)) = p.models.get_mut(&HarnessId::Graff) {
                models
                    .iter_mut()
                    .find(|m| m.id == "openai/gpt-5.4")
                    .unwrap()
                    .reasoning_levels = vec![ReasoningLevel::Low];
            }
            p.preview_commit(cx);
            assert!(p.preview.error.is_some());
            assert_eq!(p.resolved(cx).chat_config(), before);
        });
    }
    #[gpui::test]
    fn preview_large_catalog_keeps_custom_routes_and_scopes_search(cx: &mut gpui::TestAppContext) {
        let (_, picker) = fixture(cx, true);
        picker.update(cx, |p, cx| {
            let rows = p.model_rows(cx);
            assert!(rows.iter().filter(|r| r.header.is_none()).count() > 7000);
            for (route_id, _, _) in PROVIDERS {
                assert!(
                    rows.iter()
                        .any(|r| r.header.is_some() && route(&r.model) == *route_id)
                );
            }
            assert!(
                rows.iter()
                    .any(|r| r.model.id == "custom-router/custom-model")
            );
            p.search
                .update(cx, |input, cx| input.set_text("Catalog model 6999", cx));
            let rows = p.model_rows(cx);
            assert_eq!(rows.len(), 1);
            assert_eq!(rows[0].model.id, "custom-router/model-6999");
            p.pick_harness(HarnessId::Codex, cx);
            assert!(p.model_rows(cx).is_empty());
        });
    }
    #[gpui::test]
    fn preview_reopening_all_does_not_reuse_a_shortlist_cache(cx: &mut gpui::TestAppContext) {
        let (_, picker) = fixture(cx, false);
        picker.update(cx, |p, cx| {
            let all = p.model_rows(cx).len();
            p.preview.category = TaskKind::Quick;
            let quick = p.model_rows(cx).len();
            assert!(quick > 0 && quick < all);
            p.preview.reset();
            assert_eq!(p.model_rows(cx).len(), all);
        });
    }

    #[gpui::test]
    fn preview_binary_and_fixed_models_use_only_advertised_levels(cx: &mut gpui::TestAppContext) {
        let (_, picker) = fixture(cx, false);
        picker.update(cx, |p, cx| {
            p.fixture_preview_model("kimi/kimi-k2.5", cx);
            assert!(binary_reasoning_switch(Some(
                &p.preview.pending.as_ref().unwrap().model
            )));
            p.preview_back(cx);
            p.fixture_preview_model("anthropic/claude-haiku-4.5", cx);
            assert!(p.preview.pending.as_ref().unwrap().reasoning.is_none());
            // An agent-wide ladder must not invent options for this model.
            if let Loadable::Ready(descriptors) = &mut p.harnesses {
                descriptors[0].reasoning_levels = vec![ReasoningLevel::High];
            }
            p.preview_commit(cx);
            assert_eq!(p.resolved(cx).reasoning, None);
        });
    }
    #[gpui::test]
    fn preview_pointer_drag_and_keyboard_share_staged_reasoning(cx: &mut gpui::TestAppContext) {
        struct PointerFixture(Entity<Pickers>);
        impl Render for PointerFixture {
            fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
                div()
                    .size_full()
                    .p(px(20.0))
                    .child(self.0.update(cx, |p, cx| {
                        let content = p.render_model_preview(cx);
                        p.popover_frame_flush(PICKER_WIDTH, content, cx)
                    }))
            }
        }
        cx.update(|cx| cx.set_global(Theme::dark()));
        let handle = cx.add_window(|window, cx| {
            let state = cx.new(|_| AppState::new());
            let picker = cx.new(|cx| Pickers::model_picker_fixture(state, false, false, cx));
            picker.update(cx, |p, cx| {
                p.menu_geometry.insert(
                    PickerKind::HarnessModel,
                    popover::MenuGeometry {
                        height: 480.0,
                        below: false,
                    },
                );
                p.fixture_preview_model("openai/gpt-5.4", cx);
                window.focus(&p.focus, cx);
            });
            PointerFixture(picker)
        });
        cx.update_window(handle.into(), |_, window, cx| window.draw(cx).clear())
            .unwrap();
        let picker = handle
            .read_with(cx, |fixture, _| fixture.0.clone())
            .unwrap();
        let (bounds, percent) = picker.read_with(cx, |p, cx| {
            let slider = p.preview.slider.as_ref().unwrap().read(cx);
            (slider.bounds(), slider.percentage().end)
        });
        assert!(bounds.size.width > px(100.0));
        let from = gpui::point(
            bounds.left() + bounds.size.width * percent,
            bounds.center().y,
        );
        let to = gpui::point(bounds.left() + px(2.0), bounds.center().y);
        cx.update_window(handle.into(), |_, window, cx| {
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position: from,
                    ..Default::default()
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseDown(gpui::MouseDownEvent {
                    button: gpui::MouseButton::Left,
                    position: from,
                    click_count: 1,
                    ..Default::default()
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position: to,
                    pressed_button: Some(gpui::MouseButton::Left),
                    ..Default::default()
                }),
                cx,
            );
            window.draw(cx).clear();
            window.dispatch_event(
                gpui::PlatformInput::MouseMove(gpui::MouseMoveEvent {
                    position: to,
                    pressed_button: Some(gpui::MouseButton::Left),
                    ..Default::default()
                }),
                cx,
            );
            window.dispatch_event(
                gpui::PlatformInput::MouseUp(gpui::MouseUpEvent {
                    button: gpui::MouseButton::Left,
                    position: to,
                    click_count: 1,
                    ..Default::default()
                }),
                cx,
            );
            window.draw(cx).clear();
        })
        .unwrap();
        picker.read_with(cx, |p, cx| {
            assert_eq!(
                p.preview.pending.as_ref().unwrap().reasoning,
                Some(ReasoningLevel::Low)
            );
            assert_eq!(
                p.effective_model_id(cx),
                Some("anthropic/claude-sonnet-4.6")
            );
        });
        cx.simulate_keystrokes(handle.into(), "right right");
        picker.read_with(cx, |p, cx| {
            assert_eq!(
                p.preview.pending.as_ref().unwrap().reasoning,
                Some(ReasoningLevel::High)
            );
            assert_eq!(
                p.preview.slider.as_ref().unwrap().read(cx).value().end(),
                2.0
            );
        });
        cx.simulate_keystrokes(handle.into(), "escape");
        picker.read_with(cx, |p, cx| {
            assert!(p.preview.pending.is_none());
            assert_eq!(
                p.effective_model_id(cx),
                Some("anthropic/claude-sonnet-4.6")
            );
        });
    }

    #[test]
    fn preview_unknown_usage_is_not_zero_and_plans_are_not_api_costs() {
        let mut model = Model {
            id: "custom/model".into(),
            label: "Custom".into(),
            description: None,
            reasoning_levels: Vec::new(),
            options: Vec::new(),
            maker: None,
            billing: None,
        };
        assert_eq!(cost_text(&model, None), "Not estimated");
        model.label = "GPT example".into();
        model.billing = Some("plan".into());
        assert!(!cost_text(&model, None).contains('$'));
        model.billing = Some("local".into());
        assert!(!cost_text(&model, None).contains('$'));
    }
}
