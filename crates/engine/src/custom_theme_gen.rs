//! Generate harmonious custom themes & animated backdrop specs using an
//! enabled, lightweight harness+model, with a deterministic offline synthesizer
//! fallback when no model harness is available or a response is malformed.

use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

use harness_proto::{HarnessId, ReasoningLevel, RunRequest, SandboxLevel};
use serde::{Deserialize, Serialize};

use crate::registry::HarnessRegistry;

const ALLOWED_SCENES: &[&str] = &[
    "rain",
    "constellations",
    "waves",
    "fireflies",
    "petals",
    "aurora",
    "matrix",
    "ripples",
];

const THEME_INSTRUCTIONS: &str = "\
You design crisp UI color themes + ambient animated backdrop parameters for a coding workbench.\n\
Reply with ONLY one valid JSON object (no markdown fences, no commentary) having these exact keys:\n\
{\"name\":string,\"dark\":boolean,\"scene\":\"rain\"|\"constellations\"|\"waves\"|\"fireflies\"|\"petals\"|\"aurora\"|\"matrix\"|\"ripples\",\
\"speed\":number(0.3..2.0),\"intensity\":number(0.2..0.9),\
\"shell\":\"#rrggbb\",\"sidebar\":\"#rrggbb\",\"background\":\"#rrggbb\",\"card\":\"#rrggbb\",\
\"border\":\"#rrggbb\",\"text\":\"#rrggbb\",\"muted\":\"#rrggbb\",\"accent\":\"#rrggbb\",\
\"glowPrimary\":\"#rrggbb\",\"glowSecondary\":\"#rrggbb\"}\n\
Ensure WCAG AA readability contrast (>= 4.5:1) between text and background/shell/sidebar.";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateCustomThemeParams {
    pub prompt: String,
    #[serde(default)]
    pub dark: Option<bool>,
    #[serde(default)]
    pub harness: Option<HarnessId>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateCustomThemeResult {
    pub id: String,
    pub name: String,
    pub dark: bool,
    pub scene: String,
    pub speed: f32,
    pub intensity: f32,
    pub shell: String,
    pub sidebar: String,
    pub background: String,
    pub card: String,
    pub border: String,
    pub text: String,
    pub muted: String,
    pub accent: String,
    pub glow_primary: String,
    pub glow_secondary: String,
    pub source: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawModelTheme {
    name: Option<String>,
    dark: Option<bool>,
    scene: Option<String>,
    speed: Option<f32>,
    intensity: Option<f32>,
    shell: Option<String>,
    sidebar: Option<String>,
    background: Option<String>,
    card: Option<String>,
    border: Option<String>,
    text: Option<String>,
    muted: Option<String>,
    accent: Option<String>,
    glow_primary: Option<String>,
    glow_secondary: Option<String>,
}

pub async fn generate(
    registry: &HarnessRegistry,
    data_dir: &Path,
    params: GenerateCustomThemeParams,
) -> GenerateCustomThemeResult {
    let prompt = params.prompt.trim();
    if prompt.is_empty() {
        return synthesize_from_prompt("Calm Zen Pond", params.dark);
    }
    if let Some(model_result) = try_generate_with_model(registry, data_dir, prompt, &params).await {
        return model_result;
    }
    synthesize_from_prompt(prompt, params.dark)
}

async fn try_generate_with_model(
    registry: &HarnessRegistry,
    data_dir: &Path,
    prompt: &str,
    params: &GenerateCustomThemeParams,
) -> Option<GenerateCustomThemeResult> {
    let title_harness = registry.title_settings().harness;
    let enabled = registry.enabled_set();
    let harness_id = params
        .harness
        .or(title_harness)
        .or_else(|| {
            enabled
                .iter()
                .copied()
                .find(|id| harness_adapters::supports_titles(*id))
        })
        .or_else(|| enabled.into_iter().next())?;

    let harness = registry.resolve(harness_id).ok()?;
    let models = tokio::time::timeout(
        Duration::from_secs(5),
        crate::model_catalogs::list(data_dir, harness.clone(), false),
    )
    .await
    .ok()
    .and_then(Result::ok)
    .unwrap_or_else(|| harness.fallback_models());
    let model = crate::titles::cheapest_model(&models);

    let scratch = tempfile::tempdir().ok()?;
    let dark_note = match params.dark {
        Some(true) => "Preferred mode: dark theme.",
        Some(false) => "Preferred mode: light theme.",
        None => "Infer light or dark mode from the prompt.",
    };
    let full_prompt = format!(
        "{THEME_INSTRUCTIONS}\n{dark_note}\n\nTheme description (JSON string):\n{}",
        serde_json::to_string(prompt).ok()?
    );

    let request = RunRequest {
        turn_origin: Default::default(),
        prompt: full_prompt,
        harness: Some(harness_id),
        model,
        reasoning: Some(ReasoningLevel::Minimal),
        model_options: serde_json::Map::new(),
        cwd: scratch.path().to_string_lossy().into_owned(),
        sandbox: SandboxLevel::ReadOnly,
        auto_approve: false,
        attachments: Vec::new(),
        resume: None,
        worktree: None,
    };

    let raw = tokio::time::timeout(Duration::from_secs(20), async {
        if harness_adapters::supports_titles(harness_id) {
            crate::titles::collect_text(harness.as_ref(), request).await
        } else {
            collect_readonly_run_text(harness.as_ref(), request).await
        }
    })
    .await
    .ok()?
    .ok()?;

    parse_model_json(&raw, prompt, params.dark)
}

async fn collect_readonly_run_text(
    harness: &dyn harness_adapters::Harness,
    request: RunRequest,
) -> Result<String, crate::EngineError> {
    use futures::StreamExt;
    use harness_adapters::{CancellationToken, RunControls, SteerMessage};
    use harness_proto::{AgentEvent, DoneStatus, UserInputAnswer, UserInputQuestion};

    let (steer_tx, steer_rx) = tokio::sync::mpsc::channel::<SteerMessage>(1);
    let interrupt = CancellationToken::new();
    let _cancel_on_drop = interrupt.clone().drop_guard();
    let controls = RunControls {
        origin: None,
        request_input: Box::new(|_questions: Vec<UserInputQuestion>| {
            let (tx, rx) = tokio::sync::oneshot::channel::<Vec<UserInputAnswer>>();
            let _ = tx.send(Vec::new());
            rx
        }),
        steering: steer_rx,
        interrupt,
        mcp_servers: Vec::new(),
    };
    let mut stream = harness.run(request, controls).await?;
    let mut text = String::new();
    let mut completed = false;
    while let Some(event) = stream.next().await {
        match event? {
            AgentEvent::TextDelta { text: delta } => text.push_str(&delta),
            AgentEvent::ToolCall { .. } => {
                return Err(crate::EngineError::Other(
                    "theme generation attempted to use a tool".into(),
                ));
            }
            AgentEvent::Error { message } => {
                return Err(crate::EngineError::Other(format!(
                    "theme run error: {message}"
                )));
            }
            AgentEvent::Done { status, error, .. } => {
                if status == DoneStatus::Completed {
                    completed = true;
                    break;
                }
                return Err(crate::EngineError::Other(format!(
                    "theme run ended {status:?}: {}",
                    error.unwrap_or_default()
                )));
            }
            _ => {}
        }
    }
    drop(steer_tx);
    if completed {
        Ok(text)
    } else {
        Err(crate::EngineError::Other(
            "theme stream ended without completion".into(),
        ))
    }
}

pub fn parse_model_json(
    raw: &str,
    prompt: &str,
    dark_hint: Option<bool>,
) -> Option<GenerateCustomThemeResult> {
    let json_slice = extract_json_object(raw)?;
    let parsed: RawModelTheme = serde_json::from_str(json_slice).ok()?;
    let base = synthesize_from_prompt(prompt, parsed.dark.or(dark_hint));
    let dark = parsed.dark.unwrap_or(base.dark);

    let name = parsed
        .name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(40).collect::<String>())
        .unwrap_or(base.name);

    let scene = parsed
        .scene
        .as_deref()
        .map(|s| s.trim().to_ascii_lowercase())
        .filter(|s| ALLOWED_SCENES.contains(&s.as_str()))
        .unwrap_or(base.scene);

    let speed = parsed.speed.unwrap_or(base.speed).clamp(0.25, 2.5);
    let intensity = parsed.intensity.unwrap_or(base.intensity).clamp(0.15, 0.95);

    let background = parsed
        .background
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.background).unwrap());
    let shell = parsed
        .shell
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.shell).unwrap());
    let sidebar = parsed
        .sidebar
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.sidebar).unwrap());
    let card = parsed
        .card
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.card).unwrap());
    let border = parsed
        .border
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.border).unwrap());
    let accent = parsed
        .accent
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.accent).unwrap());

    let raw_text = parsed
        .text
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.text).unwrap());
    let text = ensure_readable_text(raw_text, background, shell, dark);

    let raw_muted = parsed
        .muted
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| parse_hex(&base.muted).unwrap());
    let muted = ensure_muted_contrast(raw_muted, background, text);

    let glow_primary = parsed
        .glow_primary
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or(accent);
    let glow_secondary = parsed
        .glow_secondary
        .as_deref()
        .and_then(parse_hex)
        .unwrap_or_else(|| mix_rgb(glow_primary, text, 0.25));

    Some(GenerateCustomThemeResult {
        id: format!("ai-{}", slugify(&name)),
        name,
        dark,
        scene,
        speed,
        intensity,
        shell: format_hex(shell),
        sidebar: format_hex(sidebar),
        background: format_hex(background),
        card: format_hex(card),
        border: format_hex(border),
        text: format_hex(text),
        muted: format_hex(muted),
        accent: format_hex(accent),
        glow_primary: format_hex(glow_primary),
        glow_secondary: format_hex(glow_secondary),
        source: "model".into(),
    })
}

pub fn synthesize_from_prompt(prompt: &str, dark_hint: Option<bool>) -> GenerateCustomThemeResult {
    let lower = prompt.to_ascii_lowercase();
    let dark = dark_hint.unwrap_or_else(|| infer_dark(&lower));
    let scene = infer_scene(&lower);
    let (h, s, name) = infer_palette_seed(prompt, &lower, scene);

    let (bg, shell, sidebar, card, border, text, muted, accent, glow1, glow2) = if dark {
        let bg = hsl_to_rgb(h, s * 0.35, 0.085);
        let shell = hsl_to_rgb(h, s * 0.32, 0.065);
        let sidebar = hsl_to_rgb(h, s * 0.34, 0.075);
        let card = hsl_to_rgb(h, s * 0.30, 0.115);
        let border = hsl_to_rgb(h, s * 0.25, 0.19);
        let text = hsl_to_rgb(h, s * 0.14, 0.93);
        let muted = hsl_to_rgb(h, s * 0.15, 0.65);
        let accent = hsl_to_rgb((h + 18.0) % 360.0, (s * 0.95).clamp(0.45, 0.88), 0.62);
        let glow1 = hsl_to_rgb(h, 0.78, 0.60);
        let glow2 = hsl_to_rgb((h + 44.0) % 360.0, 0.72, 0.56);
        (
            bg, shell, sidebar, card, border, text, muted, accent, glow1, glow2,
        )
    } else {
        let bg = hsl_to_rgb(h, s * 0.28, 0.965);
        let shell = hsl_to_rgb(h, s * 0.26, 0.935);
        let sidebar = hsl_to_rgb(h, s * 0.24, 0.945);
        let card = hsl_to_rgb(h, s * 0.22, 0.985);
        let border = hsl_to_rgb(h, s * 0.20, 0.84);
        let text = hsl_to_rgb(h, s * 0.22, 0.13);
        let muted = hsl_to_rgb(h, s * 0.16, 0.40);
        let accent = hsl_to_rgb((h + 14.0) % 360.0, (s * 0.90).clamp(0.45, 0.82), 0.44);
        let glow1 = hsl_to_rgb(h, 0.72, 0.54);
        let glow2 = hsl_to_rgb((h + 40.0) % 360.0, 0.68, 0.52);
        (
            bg, shell, sidebar, card, border, text, muted, accent, glow1, glow2,
        )
    };

    let text = ensure_readable_text(text, bg, shell, dark);
    let muted = ensure_muted_contrast(muted, bg, text);

    GenerateCustomThemeResult {
        id: format!("ai-{}", slugify(&name)),
        name,
        dark,
        scene: scene.into(),
        speed: if matches!(scene, "matrix" | "rain") {
            1.1
        } else {
            0.85
        },
        intensity: if dark { 0.65 } else { 0.52 },
        shell: format_hex(shell),
        sidebar: format_hex(sidebar),
        background: format_hex(bg),
        card: format_hex(card),
        border: format_hex(border),
        text: format_hex(text),
        muted: format_hex(muted),
        accent: format_hex(accent),
        glow_primary: format_hex(glow1),
        glow_secondary: format_hex(glow2),
        source: "synthesizer".into(),
    }
}

fn infer_dark(lower: &str) -> bool {
    let light_cues = [
        "light", "paper", "morning", "daylight", "dawn", "snow", "cream", "linen", "sun", "washi",
        "sakura", "spring", "matcha",
    ];
    let dark_cues = [
        "dark",
        "night",
        "midnight",
        "neon",
        "obsidian",
        "space",
        "cosmos",
        "stars",
        "noir",
        "void",
        "aurora",
        "matrix",
        "cyberpunk",
        "firefl",
        "lantern",
        "sumi",
    ];
    let light_hits = light_cues.iter().filter(|k| lower.contains(*k)).count();
    let dark_hits = dark_cues.iter().filter(|k| lower.contains(*k)).count();
    if light_hits > dark_hits { false } else { true }
}

fn infer_scene(lower: &str) -> &'static str {
    if contains_any(
        lower,
        &["sakura", "cherry", "petal", "blossom", "plum", "spring"],
    ) {
        "petals"
    } else if contains_any(
        lower,
        &["rain", "cyberpunk", "storm", "neon", "tokyo", "drizzle"],
    ) {
        "rain"
    } else if contains_any(
        lower,
        &[
            "star",
            "space",
            "cosmos",
            "galaxy",
            "nebula",
            "constellation",
            "orbit",
        ],
    ) {
        "constellations"
    } else if contains_any(lower, &["wave", "ocean", "sea", "surf", "tide", "ukiyo"]) {
        "waves"
    } else if contains_any(
        lower,
        &[
            "firefl", "forest", "meadow", "moss", "cedar", "bamboo", "river",
        ],
    ) {
        "fireflies"
    } else if contains_any(
        lower,
        &["aurora", "northern", "arctic", "glacial", "polar", "nordic"],
    ) {
        "aurora"
    } else if contains_any(
        lower,
        &["matrix", "hacker", "terminal", "code", "glyph", "cyber"],
    ) {
        "matrix"
    } else if contains_any(
        lower,
        &["zen", "koi", "pond", "rippl", "water", "lotus", "stone"],
    ) {
        "ripples"
    } else {
        let mut h: u32 = 2166136261;
        for b in lower.bytes() {
            h ^= u32::from(b);
            h = h.wrapping_mul(16777619);
        }
        ALLOWED_SCENES[(h as usize) % ALLOWED_SCENES.len()]
    }
}

fn infer_palette_seed(prompt: &str, lower: &str, scene: &str) -> (f32, f32, String) {
    let base_hue = if contains_any(lower, &["sakura", "cherry", "rose", "blossom", "pink"]) {
        340.0
    } else if contains_any(
        lower,
        &[
            "amber", "gold", "lantern", "warm", "autumn", "sunset", "momiji",
        ],
    ) {
        32.0
    } else if contains_any(
        lower,
        &[
            "matcha", "bamboo", "forest", "moss", "emerald", "jade", "matrix",
        ],
    ) {
        142.0
    } else if contains_any(
        lower,
        &["ocean", "kyoto", "indigo", "cobalt", "midnight", "rain"],
    ) {
        215.0
    } else if contains_any(
        lower,
        &["violet", "purple", "nebula", "lavender", "amethyst"],
    ) {
        268.0
    } else if contains_any(lower, &["crimson", "vermilion", "red", "ruby", "torii"]) {
        6.0
    } else {
        let mut h: u32 = 5381;
        for b in lower.bytes() {
            h = h.wrapping_mul(33).wrapping_add(u32::from(b));
        }
        (h % 360) as f32
    };

    let sat = if contains_any(
        lower,
        &["pastel", "muted", "paper", "washi", "calm", "mist"],
    ) {
        0.48
    } else if contains_any(lower, &["neon", "vivid", "cyber", "electric"]) {
        0.86
    } else if matches!(scene, "petals" | "aurora") {
        0.66
    } else {
        0.60
    };

    let words: Vec<&str> = prompt.split_whitespace().take(3).collect();
    let title = if words.is_empty() {
        "Custom Zen".to_string()
    } else {
        words
            .into_iter()
            .map(title_case_word)
            .collect::<Vec<_>>()
            .join(" ")
    };

    (base_hue, sat, title)
}

fn title_case_word(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str()),
        None => String::new(),
    }
}

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| haystack.contains(needle))
}

fn extract_json_object(raw: &str) -> Option<&str> {
    let start = raw.find('{')?;
    let end = raw.rfind('}')?;
    (end >= start).then(|| &raw[start..=end])
}

fn parse_hex(raw: &str) -> Option<[u8; 3]> {
    let trimmed = raw.trim().trim_start_matches('#');
    if trimmed.len() == 3 {
        let mut out = [0u8; 3];
        for (i, ch) in trimmed.bytes().enumerate() {
            let v = u8::from_str_radix(std::str::from_utf8(&[ch, ch]).ok()?, 16).ok()?;
            out[i] = v;
        }
        return Some(out);
    }
    if trimmed.len() != 6 && trimmed.len() != 8 {
        return None;
    }
    let r = u8::from_str_radix(&trimmed[0..2], 16).ok()?;
    let g = u8::from_str_radix(&trimmed[2..4], 16).ok()?;
    let b = u8::from_str_radix(&trimmed[4..6], 16).ok()?;
    Some([r, g, b])
}

fn format_hex(rgb: [u8; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", rgb[0], rgb[1], rgb[2])
}

fn slugify(name: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for ch in name.chars() {
        if out.len() >= 36 {
            break;
        }
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash && !out.is_empty() {
            out.push('-');
            prev_dash = true;
        }
    }
    let trimmed = out.trim_end_matches('-').to_string();
    if trimmed.is_empty() {
        "custom-theme".into()
    } else {
        trimmed
    }
}

fn relative_luminance(rgb: [u8; 3]) -> f32 {
    fn channel(v: u8) -> f32 {
        let s = f32::from(v) / 255.0;
        if s <= 0.03928 {
            s / 12.92
        } else {
            ((s + 0.055) / 1.055).powf(2.4)
        }
    }
    0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2])
}

pub fn contrast_ratio(a: [u8; 3], b: [u8; 3]) -> f32 {
    let la = relative_luminance(a);
    let lb = relative_luminance(b);
    let (hi, lo) = if la >= lb { (la, lb) } else { (lb, la) };
    (hi + 0.05) / (lo + 0.05)
}

fn ensure_readable_text(text: [u8; 3], bg: [u8; 3], shell: [u8; 3], dark: bool) -> [u8; 3] {
    if contrast_ratio(text, bg) >= 4.5 && contrast_ratio(text, shell) >= 4.5 {
        return text;
    }
    let anchor = if dark { [244, 244, 248] } else { [20, 22, 26] };
    for step in 1..=10 {
        let candidate = mix_rgb(text, anchor, step as f32 / 10.0);
        if contrast_ratio(candidate, bg) >= 4.5 && contrast_ratio(candidate, shell) >= 4.5 {
            return candidate;
        }
    }
    anchor
}

fn ensure_muted_contrast(muted: [u8; 3], bg: [u8; 3], text: [u8; 3]) -> [u8; 3] {
    if contrast_ratio(muted, bg) >= 3.0 {
        return muted;
    }
    for step in 1..=8 {
        let candidate = mix_rgb(muted, text, step as f32 / 8.0);
        if contrast_ratio(candidate, bg) >= 3.0 {
            return candidate;
        }
    }
    mix_rgb(muted, text, 0.55)
}

fn mix_rgb(a: [u8; 3], b: [u8; 3], t: f32) -> [u8; 3] {
    let inv = 1.0 - t;
    [
        (f32::from(a[0]) * inv + f32::from(b[0]) * t).round() as u8,
        (f32::from(a[1]) * inv + f32::from(b[1]) * t).round() as u8,
        (f32::from(a[2]) * inv + f32::from(b[2]) * t).round() as u8,
    ]
}

fn hsl_to_rgb(h_deg: f32, s: f32, l: f32) -> [u8; 3] {
    let h = ((h_deg % 360.0) + 360.0) % 360.0 / 360.0;
    let s = s.clamp(0.0, 1.0);
    let l = l.clamp(0.0, 1.0);
    if s == 0.0 {
        let v = (l * 255.0).round() as u8;
        return [v, v, v];
    }
    let q = if l < 0.5 {
        l * (1.0 + s)
    } else {
        l + s - l * s
    };
    let p = 2.0 * l - q;
    let r = hue_to_rgb(p, q, h + 1.0 / 3.0);
    let g = hue_to_rgb(p, q, h);
    let b = hue_to_rgb(p, q, h - 1.0 / 3.0);
    [
        (r * 255.0).round() as u8,
        (g * 255.0).round() as u8,
        (b * 255.0).round() as u8,
    ]
}

fn hue_to_rgb(p: f32, q: f32, mut t: f32) -> f32 {
    if t < 0.0 {
        t += 1.0;
    }
    if t > 1.0 {
        t -= 1.0;
    }
    if t < 1.0 / 6.0 {
        p + (q - p) * 6.0 * t
    } else if t < 1.0 / 2.0 {
        q
    } else if t < 2.0 / 3.0 {
        p + (q - p) * (2.0 / 3.0 - t) * 6.0
    } else {
        p
    }
}

pub fn valid_scene_set(scene: &str) -> bool {
    let _ = HashSet::<&str>::new();
    ALLOWED_SCENES.contains(&scene)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use futures::StreamExt;
    use harness_adapters::{Harness, HarnessError, RunControls};
    use harness_proto::{AgentEvent, DoneStatus, Model};

    struct MockThemeHarness {
        reply: String,
    }

    #[async_trait::async_trait]
    impl Harness for MockThemeHarness {
        fn id(&self) -> HarnessId {
            HarnessId::Codex
        }
        fn display_name(&self) -> &str {
            "Theme mock"
        }
        fn supports_steering(&self) -> bool {
            false
        }
        fn steering_mode(&self) -> harness_proto::SteeringMode {
            harness_proto::SteeringMode::TurnBoundary
        }
        fn reasoning_levels(&self) -> &[ReasoningLevel] {
            &[]
        }
        async fn models(&self) -> Result<Vec<Model>, HarnessError> {
            Ok(vec![Model {
                id: "mini-model".into(),
                label: "Mini".into(),
                description: None,
                reasoning_levels: vec![],
                options: vec![],
                maker: None,
                billing: None,
                context: None,
            }])
        }
        async fn run(
            &self,
            _: RunRequest,
            _: RunControls,
        ) -> Result<
            futures::stream::BoxStream<'static, Result<AgentEvent, HarnessError>>,
            HarnessError,
        > {
            Ok(futures::stream::iter(vec![
                Ok(AgentEvent::TextDelta {
                    text: self.reply.clone(),
                }),
                Ok(AgentEvent::Done {
                    status: DoneStatus::Completed,
                    result: None,
                    error: None,
                    session_id: None,
                }),
            ])
            .boxed())
        }
        async fn run_title(
            &self,
            _: RunRequest,
            _: RunControls,
        ) -> Result<
            futures::stream::BoxStream<'static, Result<AgentEvent, HarnessError>>,
            HarnessError,
        > {
            Ok(futures::stream::iter(vec![
                Ok(AgentEvent::TextDelta {
                    text: self.reply.clone(),
                }),
                Ok(AgentEvent::Done {
                    status: DoneStatus::Completed,
                    result: None,
                    error: None,
                    session_id: None,
                }),
            ])
            .boxed())
        }
    }

    #[test]
    fn parses_fenced_model_json_and_repairs_low_contrast_text() {
        let raw = r##"Here is your theme:
```json
{
  "name": "Neon Alley",
  "dark": true,
  "scene": "rain",
  "speed": 1.35,
  "intensity": 0.72,
  "shell": "#090c14",
  "sidebar": "#0d111c",
  "background": "#101624",
  "card": "#172034",
  "border": "#283655",
  "text": "#181d2c",
  "muted": "#232a3d",
  "accent": "#22d3ee",
  "glowPrimary": "#22d3ee",
  "glowSecondary": "#f472b6"
}
```"##;
        let parsed = parse_model_json(raw, "neon cyberpunk rain", Some(true)).unwrap();
        assert_eq!(parsed.name, "Neon Alley");
        assert_eq!(parsed.scene, "rain");
        assert_eq!(parsed.source, "model");
        let bg = parse_hex(&parsed.background).unwrap();
        let text = parse_hex(&parsed.text).unwrap();
        assert!(contrast_ratio(text, bg) >= 4.5);
    }

    #[test]
    fn synthesizer_produces_accessible_dark_and_light_themes() {
        let dark = synthesize_from_prompt("Midnight sakura blossoms in rain", None);
        assert_eq!(dark.source, "synthesizer");
        assert_eq!(dark.scene, "petals");
        assert!(
            contrast_ratio(
                parse_hex(&dark.text).unwrap(),
                parse_hex(&dark.background).unwrap()
            ) >= 4.5
        );

        let light = synthesize_from_prompt("Morning washi paper waves", None);
        assert!(!light.dark);
        assert_eq!(light.scene, "waves");
        assert!(
            contrast_ratio(
                parse_hex(&light.text).unwrap(),
                parse_hex(&light.background).unwrap()
            ) >= 4.5
        );
    }

    #[tokio::test]
    async fn generate_uses_model_output_then_falls_back_on_garbage() {
        let dir = tempfile::tempdir().unwrap();
        let registry = HarnessRegistry::new();
        registry.register(Arc::new(MockThemeHarness {
            reply: r##"{"name":"Aurora Mist","dark":true,"scene":"aurora","speed":0.9,"intensity":0.7,"shell":"#081018","sidebar":"#0b1520","background":"#0e1a28","card":"#132336","border":"#233b54","text":"#ecf6ff","muted":"#9bb8d3","accent":"#34d399","glowPrimary":"#34d399","glowSecondary":"#38bdf8"}"##.into(),
        }));
        let ok = generate(
            &registry,
            dir.path(),
            GenerateCustomThemeParams {
                prompt: "nordic aurora".into(),
                dark: Some(true),
                harness: Some(HarnessId::Codex),
            },
        )
        .await;
        assert_eq!(ok.source, "model");
        assert_eq!(ok.name, "Aurora Mist");
        assert_eq!(ok.scene, "aurora");

        let fallback_reg = HarnessRegistry::new();
        fallback_reg.register(Arc::new(MockThemeHarness {
            reply: "not json at all".into(),
        }));
        let fb = generate(
            &fallback_reg,
            dir.path(),
            GenerateCustomThemeParams {
                prompt: "deep space constellations".into(),
                dark: Some(true),
                harness: Some(HarnessId::Codex),
            },
        )
        .await;
        assert_eq!(fb.source, "synthesizer");
        assert_eq!(fb.scene, "constellations");
    }
}
