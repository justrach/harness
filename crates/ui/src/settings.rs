//! UI settings persisted to a small JSON file in the data dir — pane widths and
//! collapse flags (harness persisted the same set in localStorage).
//!
//! Loaded once at boot and then owned by [`SettingsStore`], the only production
//! writer. Frequent geometry changes are debounced; durable choices flush
//! immediately through that same writer. Corrupt or missing files fall back to
//! defaults, and loaded values are clamped so a hand-edited file can't wedge the
//! layout.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use gpui::{App, Global, Task};
use serde::{Deserialize, Serialize};
use harness_proto::{AuthState, WorkspaceScope};

pub mod accounts;
pub mod appearance;
pub mod archived;
pub mod browse_link;
pub mod mcp;
pub mod composer;
pub mod devices;
pub mod files;
pub mod github_ci;
pub mod harnesses;
pub mod notifications;
pub mod project_folders;
pub mod search;
pub mod shortcuts;
pub mod widgets;

/// Sidebar drag-resize bounds (px).
pub const SIDEBAR_MIN: f32 = 224.0;
pub const SIDEBAR_MAX: f32 = 400.0;
pub const SIDEBAR_DEFAULT: f32 = SIDEBAR_MIN;

/// Independent file explorer width preference and drag bounds (px).
pub const FILES_PANEL_DEFAULT: f32 = 286.0;
pub const FILES_PANEL_MIN: f32 = 220.0;
pub const FILES_PANEL_MAX: f32 = 440.0;

/// Surface pane floor and default (px). Runtime sizing also reserves space
/// for the conversation and any docked file explorer.
pub const RIGHT_PANE_MIN: f32 = 360.0;
pub const RIGHT_PANE_DEFAULT: f32 = 520.0;
/// Minimum width retained for the conversation when the right pane is open.
pub const CHAT_PANEL_MIN: f32 = 300.0;

/// Terminal panel height bounds: 160px … 55% of the viewport (§1.10). The
/// viewport-relative cap applies at runtime; the absolute cap here only heals
/// hand-edited files.
pub const TERMINAL_MIN_HEIGHT: f32 = 160.0;
pub const TERMINAL_MAX_VH: f32 = 0.55;
pub const TERMINAL_ABS_MAX_HEIGHT: f32 = 2000.0;
pub const TERMINAL_DEFAULT_HEIGHT: f32 = 280.0;

/// Debounce for settings writes after a drag/toggle.
pub const SAVE_DEBOUNCE_MS: u64 = 400;

pub const FILES_AUTOSAVE_DELAY_DEFAULT_MS: u64 = 900;
pub const FILES_AUTOSAVE_DELAY_MIN_MS: u64 = 100;
pub const FILES_AUTOSAVE_DELAY_MAX_MS: u64 = 10_000;

const FILE_NAME: &str = "ui-settings.json";
const NEW_THREAD_BACKGROUND_DIR: &str = "new-thread-backgrounds";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NewThreadComposerBackground {
    /// Managed copy inside Harness's device-local data directory.
    pub path: String,
    /// Original file name shown in Appearance settings.
    pub name: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NewThreadBackgroundEffect {
    #[default]
    None,
    Dither,
    Ascii,
    Halftone,
    Scanlines,
}

impl NewThreadBackgroundEffect {
    pub const ALL: [Self; 5] = [
        Self::None,
        Self::Dither,
        Self::Ascii,
        Self::Halftone,
        Self::Scanlines,
    ];

    pub const fn label(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::Dither => "Dither",
            Self::Ascii => "ASCII",
            Self::Halftone => "Halftone",
            Self::Scanlines => "Scanlines",
        }
    }

    pub const fn description(self) -> &'static str {
        match self {
            Self::None => "Shows the original artwork.",
            Self::Dither => "Rebuilds the artwork with a dithered color palette.",
            Self::Ascii => "Recreates the artwork with colored characters on black.",
            Self::Halftone => "Recreates the artwork with colored print dots on black.",
            Self::Scanlines => "Adds a pronounced horizontal display-line texture.",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct GitHistoryColumns {
    pub author: bool,
    pub date: bool,
    pub sha: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GitHistoryColumn {
    Author,
    Date,
    Sha,
}

/// Stable order for the optional Git History columns. Hidden columns remain in
/// the sequence so showing one again restores the position chosen by the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct GitHistoryColumnOrder(pub Vec<GitHistoryColumn>);

impl GitHistoryColumnOrder {
    pub fn normalized(mut self) -> Self {
        let mut columns = Vec::with_capacity(3);
        for column in self.0.drain(..) {
            if !columns.contains(&column) {
                columns.push(column);
            }
        }
        for column in [
            GitHistoryColumn::Author,
            GitHistoryColumn::Date,
            GitHistoryColumn::Sha,
        ] {
            if !columns.contains(&column) {
                columns.push(column);
            }
        }
        Self(columns)
    }
}

impl Default for GitHistoryColumnOrder {
    fn default() -> Self {
        Self(vec![
            GitHistoryColumn::Author,
            GitHistoryColumn::Date,
            GitHistoryColumn::Sha,
        ])
    }
}

/// Persisted widths for the fixed Git History data columns. The commit column
/// remains elastic and occupies the space left after these columns and the
/// topology graph, so resizing its first divider adjusts the adjacent column.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct GitHistoryColumnWidths {
    pub author: f32,
    pub date: f32,
    pub sha: f32,
}

impl GitHistoryColumnWidths {
    pub const AUTHOR_MIN: f32 = 44.0;
    pub const AUTHOR_MAX: f32 = 220.0;
    pub const DATE_MIN: f32 = 68.0;
    pub const DATE_MAX: f32 = 180.0;
    pub const SHA_MIN: f32 = 58.0;
    pub const SHA_MAX: f32 = 140.0;

    pub fn clamped(mut self) -> Self {
        let defaults = Self::default();
        self.author = clamp_or(
            self.author,
            Self::AUTHOR_MIN,
            Self::AUTHOR_MAX,
            defaults.author,
        );
        self.date = clamp_or(self.date, Self::DATE_MIN, Self::DATE_MAX, defaults.date);
        self.sha = clamp_or(self.sha, Self::SHA_MIN, Self::SHA_MAX, defaults.sha);
        self
    }
}

impl Default for GitHistoryColumnWidths {
    fn default() -> Self {
        Self {
            author: 88.0,
            date: 88.0,
            sha: 74.0,
        }
    }
}

pub const TRANSCRIPT_WIDTH_MIN: f32 = 560.0;
pub const TRANSCRIPT_WIDTH_MAX: f32 = 1200.0;
pub const TRANSCRIPT_WIDTH_DEFAULT: f32 = 736.0;
pub const TRANSCRIPT_WIDTH_STEP: f32 = 16.0;

pub fn normalize_transcript_width(width: f32) -> f32 {
    let width = clamp_or(
        width,
        TRANSCRIPT_WIDTH_MIN,
        TRANSCRIPT_WIDTH_MAX,
        TRANSCRIPT_WIDTH_DEFAULT,
    );
    TRANSCRIPT_WIDTH_MIN
        + ((width - TRANSCRIPT_WIDTH_MIN) / TRANSCRIPT_WIDTH_STEP).round() * TRANSCRIPT_WIDTH_STEP
}

pub fn transcript_width(cx: &App) -> f32 {
    cx.try_global::<SettingsStore>()
        .map(|store| store.current.transcript_width)
        .unwrap_or(TRANSCRIPT_WIDTH_DEFAULT)
}

pub fn set_transcript_width(width: f32, cx: &mut App) {
    if update(SavePolicy::Debounced, cx, |settings| {
        settings.transcript_width = normalize_transcript_width(width);
    }) {
        cx.refresh_windows();
    }
}

/// Whether a settings mutation should wait for the normal coalescing window or
/// reach disk before returning to the event loop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SavePolicy {
    Debounced,
    Immediate,
}

/// The sole in-process owner and writer of `ui-settings.json`.
///
/// Mutations land in `current` before any timer starts. Replacing a pending
/// task cancels its stale snapshot, and immediate mutations cancel the timer
/// before flushing synchronously.
pub struct SettingsStore {
    current: UiSettings,
    /// Last observed or successfully committed settings, before pending edits.
    baseline: UiSettings,
    data_dir: PathBuf,
    revision: u64,
    saved_revision: u64,
    /// In-process invalidation token for transcript code-fence layout. Unlike
    /// the persisted revision, this advances only when the global Fit choice
    /// changes, including a change back to its previous value.
    code_fences_generation: u64,
    save_task: Option<Task<()>>,
}

impl Global for SettingsStore {}

impl SettingsStore {
    /// Reconcile sequential writes by another viewport before committing. The
    /// read/rename pair is not a cross-process transaction; simultaneous writers
    /// still need shared locking or a single authoritative owner.
    fn persist(&mut self, local: UiSettings) -> io::Result<bool> {
        let document = match std::fs::read(UiSettings::path(&self.data_dir)) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(settings_json_error)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                serde_json::to_value(&self.baseline).map_err(settings_json_error)?
            }
            Err(error) => return Err(error),
        };
        let (settings, document) = merge_settings_document(&self.baseline, &local, document)
            .map_err(settings_json_error)?;
        save_settings_document(&document, &self.data_dir)?;
        // Adopt disk-only changes too: advancing just the baseline would make
        // stale current values look like new local edits on the next save.
        let changed = self.update_current(|current| *current = settings.clone());
        self.baseline = settings;
        let current = self.mark_saved(self.revision);
        debug_assert!(current, "foreground settings write cannot be overtaken");
        Ok(changed)
    }

    fn snapshot(&self) -> (UiSettings, u64) {
        (self.current.clone(), self.revision)
    }

    fn mark_saved(&mut self, revision: u64) -> bool {
        self.saved_revision = self.saved_revision.max(revision);
        self.saved_revision == self.revision
    }

    fn update_current(&mut self, mutate: impl FnOnce(&mut UiSettings)) -> bool {
        let before = self.current.clone();
        mutate(&mut self.current);
        self.current = self.current.clone().clamped();
        if self.current == before {
            return false;
        }
        if self.current.code_fences_fit_content != before.code_fences_fit_content {
            self.code_fences_generation = self.code_fences_generation.wrapping_add(1);
        }
        self.revision = self.revision.wrapping_add(1);
        true
    }
}

pub fn init(settings: UiSettings, data_dir: impl Into<PathBuf>, cx: &mut App) {
    cx.set_global(SettingsStore {
        baseline: settings.clone(),
        current: settings,
        data_dir: data_dir.into(),
        revision: 0,
        saved_revision: 0,
        code_fences_generation: 0,
        save_task: None,
    });
}

/// Read the latest settings without cloning them. Render paths read one or
/// two fields per frame (per code fence, per Shell render); `current` would
/// deep-clone every map and Vec in `UiSettings` each time.
pub fn with_current<R>(cx: &App, read: impl FnOnce(&UiSettings) -> R) -> R {
    match cx.try_global::<SettingsStore>() {
        Some(store) => read(&store.current),
        None => read(&UiSettings::default()),
    }
}

/// Latest settings, including mutations still inside the debounce window.
pub fn current(cx: &App) -> UiSettings {
    cx.try_global::<SettingsStore>()
        .map(|store| store.current.clone())
        .unwrap_or_default()
}

/// In-process invalidation token, including changes waiting to be written.
pub fn revision(cx: &App) -> u64 {
    cx.try_global::<SettingsStore>()
        .map(|store| store.revision)
        .unwrap_or(0)
}

/// Device-local closed conversations and unsent chat tabs, newest first.
/// Closing a placement does not change the conversation's synced archive flag.
pub fn recently_closed_chats(cx: &App) -> Vec<SavedClosedChat> {
    with_current(cx, |settings| settings.recently_closed_chats.clone())
}

/// Entries omitted from the default history list, but still available to search.
/// Keys use `chat:<conversation id>` or `draft:<recovery record id>`.
pub fn hidden_history_entries(cx: &App) -> Vec<String> {
    with_current(cx, |settings| settings.hidden_history_entries.clone())
}

/// Copy a selected image into Harness's device-local data directory and make it
/// the new-thread canvas background. A unique file name avoids stale image
/// caches when the background is replaced.
pub fn install_new_thread_composer_background(source: &Path, cx: &mut App) -> Result<(), String> {
    let staged = crate::attachments::stage_file(source)?;
    // Do not persist the candidate or retire the old managed file until the
    // renderer's decoder has accepted the exact bytes we are about to save.
    crate::new_thread_background_image::decode(staged.bytes()).map_err(|_| {
        "This background image is unsupported or damaged. Choose a valid image such as PNG or JPEG.".to_string()
    })?;
    let data_dir = cx
        .try_global::<SettingsStore>()
        .map(|store| store.data_dir.clone())
        .ok_or_else(|| "Unable to save the image. Restart Harness and try again.".to_string())?;
    let backgrounds_dir = data_dir.join(NEW_THREAD_BACKGROUND_DIR);
    std::fs::create_dir_all(&backgrounds_dir).map_err(|_| {
        "Unable to save the image. Check folder permissions and try again.".to_string()
    })?;

    let extension = Path::new(&staged.name)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("png");
    let destination = backgrounds_dir.join(format!(
        "new-thread-background-{}.{}",
        uuid::Uuid::new_v4(),
        extension
    ));
    let temporary = destination.with_extension(format!("{extension}.tmp"));
    if std::fs::write(&temporary, staged.bytes())
        .and_then(|_| std::fs::rename(&temporary, &destination))
        .is_err()
    {
        let _ = std::fs::remove_file(&temporary);
        return Err(
            "Unable to save the image. Check folder permissions and try again.".to_string(),
        );
    }

    let replacement = NewThreadComposerBackground {
        path: destination.to_string_lossy().into_owned(),
        name: staged.name,
    };
    let mut next = current(cx);
    let previous = next
        .new_thread_composer_background
        .replace(replacement.clone());
    // Persist the pointer before retiring the old file. `update(Immediate)`
    // updates memory first and only logs an I/O failure; for a file-backed
    // setting that order can leave disk pointing at an image we just deleted.
    if persist_settings(next, cx).is_err() {
        let _ = std::fs::remove_file(&destination);
        return Err(
            "Unable to save the image. Check folder permissions and try again.".to_string(),
        );
    }
    remove_managed_new_thread_background(previous.as_ref(), &backgrounds_dir);
    cx.refresh_windows();
    Ok(())
}

pub fn remove_new_thread_composer_background(cx: &mut App) -> Result<(), String> {
    let data_dir = cx
        .try_global::<SettingsStore>()
        .map(|store| store.data_dir.clone())
        .ok_or_else(|| "Unable to remove the image. Restart Harness and try again.".to_string())?;
    let mut next = current(cx);
    let previous = next.new_thread_composer_background.take();
    if previous.is_none() {
        return Ok(());
    }
    if persist_settings(next, cx).is_err() {
        return Err(
            "Unable to remove the image. Check folder permissions and try again.".to_string(),
        );
    }
    remove_managed_new_thread_background(
        previous.as_ref(),
        &data_dir.join(NEW_THREAD_BACKGROUND_DIR),
    );
    cx.refresh_windows();
    Ok(())
}

pub fn set_new_thread_background_effect(effect: NewThreadBackgroundEffect, cx: &mut App) {
    if update(SavePolicy::Immediate, cx, |settings| {
        settings.new_thread_background_effect = effect;
    }) {
        cx.refresh_windows();
    }
}

fn remove_managed_new_thread_background(
    background: Option<&NewThreadComposerBackground>,
    backgrounds_dir: &Path,
) {
    let Some(background) = background else {
        return;
    };
    let path = Path::new(&background.path);
    // Never delete an arbitrary legacy or hand-edited path. Only files copied
    // directly into the directory owned by this setting are disposable.
    if path.parent() == Some(backgrounds_dir) {
        let _ = std::fs::remove_file(path);
    }
}

/// Monotonic id of the global code-fence layout choice. Every transcript
/// compares this during render so inactive subagent tabs can observe all mode
/// transitions when they next become visible.
pub fn code_fences_generation(cx: &App) -> u64 {
    cx.try_global::<SettingsStore>()
        .map(|store| store.code_fences_generation)
        .unwrap_or_default()
}

/// Compact transcript mode: each turn's work folds into one collapsed
/// accordion, leaving only the reply text. Transcripts poll this during
/// render and rebuild their row split on a flip — cheap by design (a bool
/// field read, not a `current()` clone).
impl UiSettings {
    /// The defaults with the transcript expanded, for tests of expanded rows: compact mode is
    /// on by default, and folds a turn's steps away.
    #[doc(hidden)]
    pub fn expanded() -> Self {
        Self {
            transcript_compact_mode: false,
            ..Self::default()
        }
    }
}

pub fn transcript_compact_mode(cx: &App) -> bool {
    cx.try_global::<SettingsStore>()
        .map(|store| store.current.transcript_compact_mode)
        .unwrap_or_default()
}

/// Whether closing a session's tab or pane with ⌘W or its ✕ archives it.
pub fn archive_sessions_on_close(cx: &App) -> bool {
    cx.try_global::<SettingsStore>()
        .map(|store| store.current.archive_sessions_on_close)
        .unwrap_or_default()
}

/// Whether the user has picked what ⌘W does to a session; until then the
/// first ⌘W close asks (`shell/archive_choice.rs`).
pub fn archive_on_close_chosen(cx: &App) -> bool {
    cx.try_global::<SettingsStore>()
        .is_some_and(|store| store.current.archive_on_close_chosen)
}

/// The close shortcut the menu binds (`app_menus::key_bindings`: ⌘W, or
/// Ctrl+Shift+W off macOS) and the configured close-without-archiving one,
/// as badges ("⌘W", "⌥⌘W").
pub fn close_shortcut_badges(cx: &App) -> (String, String) {
    let close = if cfg!(target_os = "macos") {
        "mod-w"
    } else {
        "ctrl-shift-w"
    };
    let close_only = with_current(cx, |current| {
        badge_combo(current.keymap.get(ShortcutId::CloseTabWithoutArchiving))
    });
    (badge_combo(close), close_only)
}

/// The Settings toggle and the first-close question both land here, so
/// either one counts as the choice.
pub fn set_archive_sessions_on_close(enabled: bool, cx: &mut App) {
    update(SavePolicy::Immediate, cx, |settings| {
        settings.archive_sessions_on_close = enabled;
        settings.archive_on_close_chosen = true;
    });
}

pub fn set_sidebar_task_view(enabled: bool, cx: &mut App) {
    if update(SavePolicy::Immediate, cx, |settings| {
        settings.sidebar_task_view = enabled;
    }) {
        cx.refresh_windows();
    }
}

pub fn set_transcript_compact_mode(enabled: bool, cx: &mut App) {
    if update(SavePolicy::Immediate, cx, |settings| {
        settings.transcript_compact_mode = enabled;
    }) {
        cx.refresh_windows();
    }
}

pub fn update(policy: SavePolicy, cx: &mut App, mutate: impl FnOnce(&mut UiSettings)) -> bool {
    if !cx.has_global::<SettingsStore>() {
        return false;
    }
    if !cx.global_mut::<SettingsStore>().update_current(mutate) {
        return false;
    }
    schedule(policy, cx);
    true
}

pub fn replace(settings: UiSettings, policy: SavePolicy, cx: &mut App) -> bool {
    update(policy, cx, |current| *current = settings)
}

fn schedule(policy: SavePolicy, cx: &mut App) {
    let old_task = cx.global_mut::<SettingsStore>().save_task.take();
    drop(old_task);

    match policy {
        SavePolicy::Immediate => flush(cx),
        SavePolicy::Debounced => {
            let task = cx.spawn(async move |cx| {
                cx.background_executor()
                    .timer(Duration::from_millis(SAVE_DEBOUNCE_MS))
                    .await;
                cx.update(flush_latest);
            });
            cx.global_mut::<SettingsStore>().save_task = Some(task);
        }
    }
}

impl Default for GitHistoryColumns {
    fn default() -> Self {
        Self {
            author: true,
            date: true,
            sha: true,
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GitHistoryAuthorDisplay {
    #[default]
    Avatar,
    Name,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ComposerSendBehavior {
    #[default]
    Enter,
    ModEnter,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum FollowUpBehavior {
    #[default]
    Queue,
    Steer,
}

/// Persist the latest revision. Safe to call at shutdown.
pub fn flush(cx: &mut App) {
    if !cx.has_global::<SettingsStore>() {
        return;
    }
    let pending = cx.global_mut::<SettingsStore>().save_task.take();
    drop(pending);
    flush_latest(cx);
}

fn flush_latest(cx: &mut App) {
    let Some(store) = cx.try_global::<SettingsStore>() else {
        return;
    };
    if store.saved_revision == store.revision {
        return;
    }
    let (settings, revision) = store.snapshot();
    if let Err(err) = persist_settings(settings, cx) {
        tracing::warn!(error = %err, revision, "failed to persist ui settings");
    }
}

/// Fallible commits keep file-backed settings in memory only after their
/// pointer is safe on disk. Normal updates already changed memory before here.
fn persist_settings(settings: UiSettings, cx: &mut App) -> io::Result<()> {
    let changed = cx.global_mut::<SettingsStore>().persist(settings)?;
    let pending = cx.global_mut::<SettingsStore>().save_task.take();
    drop(pending);
    if changed {
        cx.refresh_windows();
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SidebarOrganization {
    ByProject,
    ByDevice,
    #[default]
    InOneList,
    /// "Needs you", "Today" and "Earlier": chats waiting on you first.
    ByStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SidebarSort {
    /// Shown as "Last called": when a person last prompted each session.
    /// The name is kept for saved settings.
    #[default]
    LastUpdated,
    Created,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowGeometry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_uuid: Option<uuid::Uuid>,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl WindowGeometry {
    pub fn is_valid(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .into_iter()
            .all(f32::is_finite)
            && self.width > 0.0
            && self.height > 0.0
    }

    pub fn from_bounds(bounds: gpui::Bounds<gpui::Pixels>) -> Self {
        Self {
            display_uuid: None,
            x: bounds.origin.x.into(),
            y: bounds.origin.y.into(),
            width: bounds.size.width.into(),
            height: bounds.size.height.into(),
        }
    }

    pub fn restore(self, displays: &[Self], primary: usize) -> Option<(usize, Self)> {
        if !self.is_valid() {
            return None;
        }
        let matched = self.display_uuid.and_then(|uuid| {
            displays
                .iter()
                .position(|display| display.is_valid() && display.display_uuid == Some(uuid))
        });
        let index = matched
            .or_else(|| {
                displays
                    .get(primary)
                    .filter(|display| display.is_valid())
                    .map(|_| primary)
            })
            .or_else(|| displays.iter().position(|display| display.is_valid()))?;
        let display = displays[index];
        let mut geometry = self.fit(display);
        if self.display_uuid.is_some() && matched.is_none() {
            geometry.x = display.x + (display.width - geometry.width) / 2.0;
            geometry.y = display.y + (display.height - geometry.height) / 2.0;
        }
        geometry.display_uuid = display.display_uuid;
        Some((index, geometry))
    }

    pub fn fit(self, display: Self) -> Self {
        let width = self.width.max(900.0).min(display.width);
        let height = self.height.max(600.0).min(display.height);
        Self {
            display_uuid: self.display_uuid,
            x: self.x.clamp(display.x, display.x + display.width - width),
            y: self.y.clamp(display.y, display.y + display.height - height),
            width,
            height,
        }
    }

    pub fn bounds(self) -> gpui::Bounds<gpui::Pixels> {
        gpui::Bounds::new(
            gpui::point(gpui::px(self.x), gpui::px(self.y)),
            gpui::size(gpui::px(self.width), gpui::px(self.height)),
        )
    }
}

/// Trigger preferences belong to each harness, not the currently selected model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillCompletionSettings {
    pub dollar: bool,
    pub separate_from_slash: bool,
}

impl SkillCompletionSettings {
    pub fn for_harness(harness: harness_proto::HarnessId) -> Self {
        let native_dollar = harness == harness_proto::HarnessId::Codex;
        Self {
            dollar: native_dollar,
            separate_from_slash: native_dollar,
        }
    }
}

pub const SKILL_COMPLETION_HARNESSES: [(harness_proto::HarnessId, &str); 10] = [
    (harness_proto::HarnessId::Antigravity, "Antigravity"),
    (harness_proto::HarnessId::ClaudeCode, "Claude Code"),
    (harness_proto::HarnessId::Codex, "Codex"),
    (harness_proto::HarnessId::Cursor, "Cursor"),
    (harness_proto::HarnessId::Devin, "Devin"),
    (harness_proto::HarnessId::Grok, "Grok"),
    (harness_proto::HarnessId::Hermes, "Hermes"),
    (harness_proto::HarnessId::Graff, "graff"),
    (harness_proto::HarnessId::Pi, "Pi"),
    (harness_proto::HarnessId::Opencode, "OpenCode"),
];

/// A split chat layout as saved between launches (`shell/chat_split.rs`).
/// `panes[focus]` is the selected chat's slot (see `lastChatId`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedChatLayout {
    pub vertical: bool,
    pub panes: Vec<Option<String>>,
    pub focus: usize,
    pub shares: Vec<f32>,
    pub projects: Vec<Option<String>>,
}

/// A chat tab as saved between launches (`shell/chat_tabs.rs`).
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedChatTab {
    /// Stable workspace session identity, independent of its optional project.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_icon: Option<String>,
    pub pinned: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub layout: Option<SavedChatLayout>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub panel_layout: Option<SavedWorkspacePanels>,
}

/// A native window's navigation and placement. Session identities may appear
/// in more than one window; each record owns only that window's panel tabs.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedWorkspaceWindow {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub geometry: Option<WindowGeometry>,
    pub chat_tabs: Vec<SavedChatTab>,
    pub chat_tab: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_space_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub space_filter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_chat_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat_layout: Option<SavedChatLayout>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub open_tabs: Option<Vec<String>>,
    pub project_tabs_version: u8,
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub chat_drafts: HashMap<String, SavedWindowChatDraft>,
}

impl SavedWorkspaceWindow {
    pub fn from_settings(id: String, settings: &UiSettings) -> Self {
        Self {
            id,
            geometry: settings.window_geometry,
            chat_tabs: settings.chat_tabs.clone(),
            chat_tab: settings.chat_tab,
            last_space_id: settings.last_space_id.clone(),
            space_filter: settings.space_filter.clone(),
            last_chat_id: settings.last_chat_id.clone(),
            chat_layout: settings.chat_layout.clone(),
            open_tabs: settings.open_tabs.clone(),
            project_tabs_version: settings.project_tabs_version,
            chat_drafts: HashMap::new(),
        }
    }

    /// Seed one Shell without replacing global preferences or another window.
    pub fn apply_to_settings(&self, settings: &mut UiSettings) {
        settings.window_geometry = self.geometry;
        settings.chat_tabs = self.chat_tabs.clone();
        settings.chat_tab = self.chat_tab;
        settings.last_space_id = self.last_space_id.clone();
        settings.space_filter = self.space_filter.clone();
        settings.last_chat_id = self.last_chat_id.clone();
        settings.chat_layout = self.chat_layout.clone();
        settings.open_tabs = self.open_tabs.clone();
        settings.project_tabs_version = self.project_tabs_version;
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedWindowChatDraft {
    pub input: SavedCanvasDraft,
    pub appshots: Vec<SavedWindowAppshot>,
}

/// Recovery for one closed chat placement. `chat_id == None` is an unsent tab.
/// Attachment bytes use the existing private draft cache, never this JSON.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedClosedChat {
    pub id: String,
    pub chat_id: Option<String>,
    pub window_id: String,
    pub session_id: String,
    pub panel_id: u64,
    pub tab_index: usize,
    pub closed_at: i64,
    pub draft: SavedWindowChatDraft,
    pub was_new_tab: bool,
}

/// Screenshot bytes use the private draft cache; app icons are presentation-only.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedWindowAppshot {
    pub id: String,
    pub app_name: String,
    pub bundle_identifier: Option<String>,
    pub window_title: Option<String>,
    pub accessibility_format_version: u32,
    pub accessibility_content: String,
    pub accessibility_truncated: bool,
    pub screenshot: SavedDraftAttachment,
    pub screenshot_dimensions: Option<(u32, u32)>,
    pub captured_at: chrono::DateTime<chrono::Utc>,
}

/// Session-owned panel placement and tabs. Runtime surface handles are never saved.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedWorkspacePanels {
    pub vertical: bool,
    pub panels: Vec<SavedWorkspacePanel>,
    pub focused: u64,
    pub expanded: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedWorkspacePanel {
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_panel_target: Option<SavedCanvasTarget>,
    pub tabs: Vec<SavedPanelTab>,
    pub active: usize,
    pub share: f32,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SavedPanelTab {
    Chat {
        id: String,
    },
    Draft {
        draft: SavedCanvasDraft,
    },
    New {
        draft: SavedCanvasDraft,
    },
    Browser {
        owner: String,
        url: Option<String>,
    },
    File {
        owner: String,
        path: String,
    },
    Files {
        owner: String,
        #[serde(
            default,
            rename = "targetDeviceId",
            skip_serializing_if = "Option::is_none"
        )]
        target_device_id: Option<String>,
    },
    Terminal {
        owner: String,
        #[serde(
            default,
            rename = "targetDeviceId",
            skip_serializing_if = "Option::is_none"
        )]
        target_device_id: Option<String>,
    },
    Diff {
        owner: String,
    },
    Subagent {
        owner: String,
        doc: String,
        title: String,
    },
    #[default]
    #[serde(other)]
    Empty,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedCanvasDraft {
    pub harness: Option<harness_proto::HarnessId>,
    pub model: Option<String>,
    pub reasoning: Option<harness_proto::ReasoningLevel>,
    pub target: Option<SavedCanvasTarget>,
    pub git: Option<SavedCanvasGit>,
    pub text: String,
    pub attachments: Vec<SavedDraftAttachment>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedCanvasGit {
    pub branch: Option<String>,
    pub checkout: crate::pickers::CheckoutKind,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SavedCanvasTarget {
    pub space: Option<String>,
    pub no_project: bool,
    pub device: Option<String>,
}

/// Bytes live in the local draft cache, outside settings JSON. The cache key is a UUID,
/// not a user-controlled filename or an absolute source path.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedDraftAttachment {
    pub id: String,
    pub name: String,
    pub cache_key: String,
    pub image: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub annotations: Option<String>,
    #[cfg(target_os = "macos")]
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub editable: Option<crate::annotate::editable::SavedEditableAnnotation>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct UiSettings {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window_geometry: Option<WindowGeometry>,
    /// None migrates a legacy single window. Some([]) means all windows were
    /// explicitly closed, so old global navigation must not be migrated again.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_windows: Option<Vec<SavedWorkspaceWindow>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub recently_closed_chats: Vec<SavedClosedChat>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub hidden_history_entries: Vec<String>,
    /// Submit using Enter or the platform modifier plus Enter.
    pub composer_send_behavior: ComposerSendBehavior,
    /// How messages sent while the agent is working are handled.
    pub follow_up_behavior: FollowUpBehavior,
    /// Legacy global opt-in; per-harness preferences take precedence.
    pub skills_in_slash_menu: bool,
    pub skill_completion_by_harness:
        std::collections::HashMap<harness_proto::HarnessId, SkillCompletionSettings>,
    pub sidebar_width: f32,
    pub sidebar_collapsed: bool,
    /// Legacy: the grouped-by-project toggle predates spaces (which group by
    /// folder inherently). Kept for file compatibility; no longer read.
    pub sidebar_grouped: bool,
    /// How active sessions are partitioned in the sidebar.
    pub sidebar_organization: SidebarOrganization,
    /// Timestamp used to order active sessions (newest first).
    pub sidebar_sort: SidebarSort,
    /// Reveal context on hover instead of keeping the context line visible.
    pub sidebar_compact: bool,
    /// Optional harness branding and repository metadata shown below each
    /// session title.
    pub sidebar_show_project_label: bool,
    pub sidebar_show_project_icon: bool,
    pub sidebar_show_harness: bool,
    pub sidebar_show_branch: bool,
    /// The Archived accordion below the active session list.
    pub sidebar_show_archived: bool,
    pub sidebar_show_updated: bool,
    /// The last selected space — restored on boot when the row still exists;
    /// also the new-tab default when the sidebar filter is "All".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_space_id: Option<String>,
    /// New Project defaults and successful-add history, keyed by host device.
    #[serde(skip_serializing_if = "HashMap::is_empty")]
    pub project_folders_by_device: HashMap<String, project_folders::ProjectFolderPreference>,
    /// Last successfully launched Action per project in this viewport.
    #[serde(skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub last_project_action_by_space_id: std::collections::HashMap<String, String>,
    /// Open session tabs in visual order (drag-reorder edits in place).
    /// Device-local: a tab is a local viewport onto the synced session list.
    /// Ids of archived/deleted chats
    /// are pruned against the doc ([`Shell::sync_open_tabs`]). `None` = file
    /// written by a pre-tabs build; seeded once from the last space's sessions.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub open_tabs: Option<Vec<String>>,
    /// Sidebar session filter: a space id, or `None` for "All spaces".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub space_filter: Option<String>,
    /// The conversation sidebar lists every project's sessions. Separate from
    /// `space_filter`, which follows the active session and so can't hold it.
    pub sidebar_all_projects: bool,
    /// The sidebar lists open workspaces instead of conversations, with the
    /// All sessions dashboard beside the project switcher.
    pub sidebar_task_view: bool,
    /// The chat that was open at quit; launch reopens it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_chat_id: Option<String>,
    /// The split chat layout at quit; launch restores it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat_layout: Option<SavedChatLayout>,
    /// Closing a session's tab or pane with ⌘W or its ✕ button also archives
    /// the session (off by default). The close-without-archiving shortcut
    /// (⌘⌥W) never does, and neither does quitting or closing the window.
    #[serde(alias = "archiveSessionsOnTabClose")]
    pub archive_sessions_on_close: bool,
    /// The user has chosen [`Self::archive_sessions_on_close`], in Settings or
    /// by answering the question the first ⌘W close asks. A file that already
    /// has the setting on counts as chosen.
    pub archive_on_close_chosen: bool,
    /// The Settings section last viewed — reopened by the generic entry points
    /// (⌘, the account menu, the palette). Kept as a string so an unknown or
    /// malformed value falls back to the default section instead of costing
    /// the rest of the file.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settings_section: Option<String>,
    /// Project views at quit, in order. The legacy field name preserves settings compatibility.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub chat_tabs: Vec<SavedChatTab>,
    /// Manual dashboard order; None represents the Scratchpad. This never
    /// changes project navigation or admits inactive projects to the overview.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub session_overview_order: Vec<Option<String>>,
    pub chat_tab: usize,
    /// Saved workspace format; zero identifies older open-tab settings.
    pub project_tabs_version: u8,
    /// Device-local pins for local profiles; synced profiles use registry pins.
    #[serde(default, skip_serializing_if = "HashMap::is_empty")]
    pub sidebar_pinned_session_ids_by_profile: HashMap<String, Vec<String>>,
    /// Legacy: per-space tab order, from when tabs were the selected space's
    /// non-archived sessions. Kept for file compatibility; no longer read.
    #[serde(skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub tab_order: std::collections::HashMap<String, Vec<String>>,
    /// Legacy: manual sidebar space order, from when spaces were a sidebar
    /// list. Kept for file compatibility; no longer read.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub space_order: Vec<String>,
    /// Master switch for session notification chimes. `HARNESS_DISABLE_SOUND`
    /// overrides every per-event preference below.
    pub sound_enabled: bool,
    /// Chime when an agent run completes successfully.
    pub sound_completion_enabled: bool,
    /// Chime when an agent is waiting for user input.
    pub sound_input_enabled: bool,
    /// Chime when a run fails or the durable connection state degrades.
    pub sound_attention_enabled: bool,
    /// A soft cue when a file or image is attached to the composer by
    /// paste, drop or the file picker.
    pub attach_sound_enabled: bool,
    /// Desktop banner notifications on the same transitions.
    /// `HARNESS_DISABLE_NOTIFICATIONS` overrides.
    pub notifications_enabled: bool,
    /// Suppress the banner while a Harness window is focused (the chime covers
    /// the foreground case).
    pub notifications_background_only: bool,
    /// Upload anonymous performance histograms (`perf_stats`). On by default;
    /// `HARNESS_DISABLE_STATS` overrides.
    pub share_performance_stats: bool,
    pub files_panel_width: f32,
    pub right_pane_width: f32,
    /// Legacy: panel *open* flags are session-scoped in-memory state now
    /// (`shell::SessionPanels`, harness `sessionPanels` parity). Kept for file
    /// compatibility; no longer read or written by the shell.
    pub right_pane_open: bool,
    pub terminal_height: f32,
    /// Legacy — see [`Self::right_pane_open`].
    pub terminal_open: bool,
    /// Customizable shortcut combos (feature-inventory §1.4).
    pub keymap: KeymapConfig,
    /// macOS viewer-side Appshot capture. Device-local because the shortcut
    /// and TCC permissions belong to this desktop.
    #[cfg_attr(not(any(target_os = "macos", target_os = "linux")), serde(skip))]
    pub appshots_enabled: bool,
    #[cfg_attr(not(any(target_os = "macos", target_os = "linux")), serde(skip))]
    pub appshot_sound_enabled: bool,
    #[cfg_attr(not(any(target_os = "macos", target_os = "linux")), serde(skip))]
    pub appshot_destination: crate::appshots::AppshotDestination,
    /// Whether bare Escape stops the active agent after contextual consumers
    /// decline it. Device-local and opt-in.
    pub escape_stops_active_agent: bool,
    /// Light/dark preference. Defaults to following the OS.
    pub appearance: crate::appearance::AppearanceMode,
    /// Optional columns shown in every Git History pane.
    pub git_history_columns: GitHistoryColumns,
    /// User-adjusted widths for the resizable Git History columns.
    pub git_history_column_widths: GitHistoryColumnWidths,
    /// User-selected order for the optional Git History columns.
    pub git_history_column_order: GitHistoryColumnOrder,
    /// How authors are represented in Git History rows.
    pub git_history_author_display: GitHistoryAuthorDisplay,
    /// Interface and conversational-prose family. Device-local by design.
    pub ui_font_family: crate::typography::UiFontFamily,
    /// Base size for interface and conversational prose.
    pub ui_font_size: crate::typography::UiFontSize,
    /// Terminal family and absolute pixel size. Only fixed-width families
    /// qualify, including compatible Nerd Fonts.
    pub terminal_font_family: crate::typography::UiFontFamily,
    pub terminal_font_size: f32,
    /// Family and absolute pixel size for code, diffs, and file editors.
    pub code_font_family: crate::typography::UiFontFamily,
    pub code_font_size: f32,
    /// Independently selected light and dark theme variants.
    pub theme_selection: harness_theme::ThemeSelection,
    /// Changes pane: side-by-side diffs instead of the unified stack.
    pub diff_split: bool,
    /// Changes pane: wrap long source lines instead of scrolling horizontally.
    pub diff_wrap: bool,
    /// Changes pane: hide changes that only move whitespace.
    pub diff_ignore_whitespace: bool,
    /// Agent-sent Markdown fences: wrap long lines to the chat width instead
    /// of exposing their horizontal scroll plane.
    pub code_fences_fit_content: bool,
    /// Maximum message and docked composer surface width in logical pixels.
    /// The centered new-chat composer keeps its own width.
    pub transcript_width: f32,
    /// Open a normal web-link activation in the session Browser. Explicit
    /// context-menu actions remain available regardless of this preference.
    pub open_web_links_in_harness: bool,
    /// Compact transcript: a turn's working steps (thinking, tool calls, and
    /// the narration between them) fold into one collapsed accordion, so only
    /// the reply text stays visible.
    pub transcript_compact_mode: bool,
    /// Compact mode became the default for everyone, and a file written
    /// before that was switched on once. False only when the file lacks
    /// it; every later choice is kept (Harness Nano reads the same key).
    #[serde(default)]
    pub transcript_compact_default_applied: bool,
    /// The Write page's "Aa": the interface sans instead of the serif.
    pub write_sans: bool,
    /// Save edited workspace files automatically after the configured delay.
    pub files_autosave_enabled: bool,
    /// Idle time before an edited workspace file is saved automatically.
    pub files_autosave_delay_ms: u64,
    /// Wrap long lines in workspace file editors and previews.
    pub files_word_wrap: bool,
    /// Include hidden and ignored entries in workspace file trees.
    pub files_show_all: bool,
    /// Interactive identity overlay; imported themes default to their own accent.
    pub accent: harness_theme::AccentSelection,
    /// Glass policy, independent from the selected appearance, theme, and accent.
    pub surface: harness_theme::SurfacePreference,
    /// Optional device-local artwork behind the blank new-thread composer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_thread_composer_background: Option<NewThreadComposerBackground>,
    /// Non-destructive treatment composited inside the artwork's fade mask.
    pub new_thread_background_effect: NewThreadBackgroundEffect,
    /// Snap animations to rest. Defaults to following the OS.
    pub reduce_motion: crate::motion::ReduceMotion,
    /// Also snap animations while the main window is not focused.
    pub pause_animations_in_background: bool,
    /// The graff engine update card's dismissed version — re-raised only when
    /// a newer stable exists.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub graff_notice_dismissed: Option<String>,
    /// Restart into a downloaded Harness update on its own once nothing would
    /// be interrupted. Off, a staged update waits for a click or for quit.
    /// `HARNESS_AUTO_UPDATE=0` turns every automatic step off regardless.
    pub restart_to_install_updates: bool,
    /// Pre-theme settings used `accentColor`. Read it once, migrate to
    /// [`Self::accent`], and never write it again.
    #[serde(default, rename = "accentColor", skip_serializing)]
    legacy_accent_color: Option<crate::theme::AccentColor>,
}

impl Default for UiSettings {
    fn default() -> Self {
        Self {
            window_geometry: None,
            workspace_windows: None,
            recently_closed_chats: Vec::new(),
            hidden_history_entries: Vec::new(),
            sidebar_width: SIDEBAR_DEFAULT,
            sidebar_collapsed: false,
            sidebar_grouped: false,
            sidebar_organization: SidebarOrganization::ByProject,
            sidebar_sort: SidebarSort::LastUpdated,
            sidebar_compact: true,
            sidebar_show_project_label: false,
            sidebar_show_project_icon: false,
            sidebar_show_harness: true,
            sidebar_show_branch: true,
            sidebar_show_archived: true,
            sidebar_show_updated: true,
            last_space_id: None,
            project_folders_by_device: HashMap::new(),
            last_project_action_by_space_id: std::collections::HashMap::new(),
            open_tabs: None,
            space_filter: None,
            sidebar_all_projects: true,
            // The conversation sidebar is the default. Tests and capture
            // fixtures written for the workspace sidebar keep rendering it.
            sidebar_task_view: cfg!(any(test, feature = "appshots-fixture")),
            last_chat_id: None,
            chat_layout: None,
            archive_sessions_on_close: false,
            archive_on_close_chosen: false,
            settings_section: None,
            chat_tabs: Vec::new(),
            session_overview_order: Vec::new(),
            chat_tab: 0,
            project_tabs_version: 0,
            sidebar_pinned_session_ids_by_profile: HashMap::new(),
            tab_order: std::collections::HashMap::new(),
            space_order: Vec::new(),
            sound_enabled: true,
            sound_completion_enabled: true,
            sound_input_enabled: true,
            sound_attention_enabled: true,
            attach_sound_enabled: true,
            notifications_enabled: true,
            notifications_background_only: true,
            share_performance_stats: true,
            files_panel_width: FILES_PANEL_DEFAULT,
            right_pane_width: RIGHT_PANE_DEFAULT,
            right_pane_open: false,
            terminal_height: TERMINAL_DEFAULT_HEIGHT,
            terminal_open: false,
            keymap: KeymapConfig::default(),
            escape_stops_active_agent: false,
            composer_send_behavior: ComposerSendBehavior::default(),
            follow_up_behavior: FollowUpBehavior::default(),
            skills_in_slash_menu: false,
            skill_completion_by_harness: Default::default(),
            appshots_enabled: false,
            appshot_sound_enabled: true,
            appshot_destination: crate::appshots::AppshotDestination::Automatic,
            appearance: crate::appearance::AppearanceMode::default(),
            git_history_columns: GitHistoryColumns::default(),
            git_history_column_widths: GitHistoryColumnWidths::default(),
            git_history_column_order: GitHistoryColumnOrder::default(),
            git_history_author_display: GitHistoryAuthorDisplay::default(),
            ui_font_family: crate::typography::UiFontFamily::default(),
            ui_font_size: crate::typography::UiFontSize::default(),
            terminal_font_family: crate::typography::UiFontFamily::GeistMono,
            terminal_font_size: crate::typography::TERMINAL_FONT_SIZE_DEFAULT,
            code_font_family: crate::typography::UiFontFamily::GeistMono,
            code_font_size: crate::typography::CODE_FONT_SIZE_DEFAULT,
            theme_selection: harness_theme::ThemeSelection::default(),
            diff_split: false,
            diff_wrap: false,
            diff_ignore_whitespace: false,
            code_fences_fit_content: false,
            transcript_width: TRANSCRIPT_WIDTH_DEFAULT,
            open_web_links_in_harness: true,
            transcript_compact_mode: true,
            transcript_compact_default_applied: true,
            write_sans: true,
            files_autosave_enabled: false,
            files_autosave_delay_ms: FILES_AUTOSAVE_DELAY_DEFAULT_MS,
            files_word_wrap: false,
            files_show_all: false,
            accent: harness_theme::AccentSelection::default(),
            surface: harness_theme::SurfacePreference::default(),
            new_thread_composer_background: None,
            new_thread_background_effect: NewThreadBackgroundEffect::None,
            reduce_motion: crate::motion::ReduceMotion::System,
            pause_animations_in_background: false,
            graff_notice_dismissed: None,
            restart_to_install_updates: true,
            legacy_accent_color: None,
        }
    }
}

// ---------------------------------------------------------------------------
// Keymap (customizable shortcuts, §1.4)
// ---------------------------------------------------------------------------

/// How many sidebar rows the jump shortcuts reach (t3code's
/// `THREAD_JUMP_KEYBINDING_COMMANDS`, nine slots).
pub const JUMP_SLOTS: usize = 9;

/// Default combo per jump slot, and the label the shortcuts table shows.
const JUMP_DEFAULTS: [&str; JUMP_SLOTS] = [
    "mod-1", "mod-2", "mod-3", "mod-4", "mod-5", "mod-6", "mod-7", "mod-8", "mod-9",
];
const JUMP_LABELS: [&str; JUMP_SLOTS] = [
    "Jump to session 1",
    "Jump to session 2",
    "Jump to session 3",
    "Jump to session 4",
    "Jump to session 5",
    "Jump to session 6",
    "Jump to session 7",
    "Jump to session 8",
    "Jump to session 9",
];

/// The rebindable app shortcuts. `JumpSession(slot)` is zero-based; a slot at
/// or past [`JUMP_SLOTS`] has no combo and no label, so it reads as unbound
/// rather than panicking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShortcutId {
    CaptureAppshot,
    SaveFile,
    BrowserReload,
    ToggleSidebar,
    ToggleChanges,
    ToggleFiles,
    ToggleTerminal,
    SplitTerminal,
    SplitTerminalDown,
    NewSession,
    NewProject,
    OpenProjectPicker,
    OpenModelPicker,
    NextSession,
    PrevSession,
    ArchiveSession,
    CloseTabWithoutArchiving,
    ReopenClosedTab,
    JumpSession(usize),
}

impl ShortcutId {
    pub const ALL: [ShortcutId; 18 + JUMP_SLOTS] = [
        ShortcutId::CaptureAppshot,
        ShortcutId::SaveFile,
        ShortcutId::BrowserReload,
        ShortcutId::ToggleSidebar,
        ShortcutId::ToggleChanges,
        ShortcutId::ToggleFiles,
        ShortcutId::ToggleTerminal,
        ShortcutId::SplitTerminal,
        ShortcutId::SplitTerminalDown,
        ShortcutId::NewSession,
        ShortcutId::NewProject,
        ShortcutId::OpenProjectPicker,
        ShortcutId::OpenModelPicker,
        ShortcutId::NextSession,
        ShortcutId::PrevSession,
        ShortcutId::ArchiveSession,
        ShortcutId::CloseTabWithoutArchiving,
        ShortcutId::ReopenClosedTab,
        ShortcutId::JumpSession(0),
        ShortcutId::JumpSession(1),
        ShortcutId::JumpSession(2),
        ShortcutId::JumpSession(3),
        ShortcutId::JumpSession(4),
        ShortcutId::JumpSession(5),
        ShortcutId::JumpSession(6),
        ShortcutId::JumpSession(7),
        ShortcutId::JumpSession(8),
    ];

    pub fn available(self) -> bool {
        self != Self::CaptureAppshot || crate::appshots::is_desktop()
    }

    /// Row label (harness lib/shortcuts.ts `SHORTCUT_DEFINITIONS`, verbatim).
    pub fn label(self) -> &'static str {
        match self {
            ShortcutId::CaptureAppshot => "Capture Appshot",
            ShortcutId::SaveFile => "Save file",
            ShortcutId::BrowserReload => "Reload browser page",
            ShortcutId::ToggleSidebar => "Toggle left sidebar",
            ShortcutId::ToggleChanges => "Show or hide changes",
            ShortcutId::ToggleFiles => "Toggle files panel",
            ShortcutId::ToggleTerminal => "Toggle terminal",
            ShortcutId::SplitTerminal => "Split terminal right",
            ShortcutId::SplitTerminalDown => "Split terminal down",
            // Keep the persisted id/keymap field compatible with saved shortcuts.
            ShortcutId::NewSession => "New tab",
            ShortcutId::NewProject => "New project",
            ShortcutId::OpenProjectPicker => "Open project picker",
            ShortcutId::OpenModelPicker => "Open model picker",
            ShortcutId::NextSession => "Next tab or session",
            ShortcutId::PrevSession => "Previous tab or session",
            ShortcutId::ArchiveSession => "Archive session",
            ShortcutId::CloseTabWithoutArchiving => "Close tab without archiving",
            ShortcutId::ReopenClosedTab => "Reopen closed tab",
            ShortcutId::JumpSession(slot) => JUMP_LABELS.get(slot).copied().unwrap_or(""),
        }
    }

    pub fn default_combo(self) -> &'static str {
        self.default_combo_on(cfg!(target_os = "macos"))
    }

    /// `default_combo` for an explicit platform, so the spelling invariant is
    /// testable for both from any machine (see the tests below — the mismatch
    /// this guards against only exists off macOS).
    pub fn default_combo_on(self, mac: bool) -> &'static str {
        match self {
            ShortcutId::CaptureAppshot if mac => "ctrl-alt-space",
            ShortcutId::CaptureAppshot => "mod-alt-space",
            ShortcutId::SaveFile => "mod-s",
            ShortcutId::BrowserReload => "mod-shift-r",
            ShortcutId::ToggleSidebar => "mod-b",
            ShortcutId::ToggleChanges => "mod-r",
            ShortcutId::ToggleFiles => "mod-e",
            ShortcutId::ToggleTerminal => "mod-j",
            // Ghostty: ⌘D splits right. Off macOS, Ctrl+D is EOF to the PTY,
            // so the split uses Shift.
            ShortcutId::SplitTerminal if mac => "mod-d",
            ShortcutId::SplitTerminal => "mod-shift-d",
            ShortcutId::SplitTerminalDown if mac => "mod-shift-d",
            ShortcutId::SplitTerminalDown => "mod-alt-shift-d",
            ShortcutId::NewSession if mac => "mod-t",
            ShortcutId::NewSession => "mod-shift-t",
            ShortcutId::NewProject => "mod-shift-n",
            // Mnemonic sibling of ⌘⇧N, on the same row as the model picker's
            // ⌘/ — free of every default, browser and terminal combo.
            ShortcutId::OpenProjectPicker => "mod-shift-p",
            ShortcutId::OpenModelPicker => "mod-/",
            // Ctrl+Tab on every platform — but spelled the way THAT platform's
            // recorder spells ctrl (see `combo_from_keystroke`). Off macOS
            // ctrl IS the primary and stores as "mod"; on macOS it is its own
            // modifier, and "mod" would mean Cmd+Tab, which the OS app
            // switcher eats.
            //
            // Off macOS "ctrl-tab" and "mod-tab" resolve to the same keystroke
            // through `platform_combo`, but conflict detection compares the
            // STORED spelling — so a default the recorder cannot reproduce
            // would let a rebind onto that same physical key pass as
            // conflict-free, bind twice, and silently kill one shortcut.
            ShortcutId::NextSession if mac => "ctrl-tab",
            ShortcutId::NextSession => "mod-tab",
            ShortcutId::PrevSession if mac => "ctrl-shift-tab",
            ShortcutId::PrevSession => "mod-shift-tab",
            // Mod+A is the composer's Select all, so archiving takes the
            // shifted combo.
            ShortcutId::ArchiveSession => "mod-shift-a",
            ShortcutId::CloseTabWithoutArchiving => "mod-alt-w",
            // Off macOS Ctrl+Shift+T already opens a new tab.
            ShortcutId::ReopenClosedTab if mac => "mod-shift-t",
            ShortcutId::ReopenClosedTab => "mod-alt-shift-t",
            ShortcutId::JumpSession(slot) => JUMP_DEFAULTS.get(slot).copied().unwrap_or(""),
        }
    }

    /// The sidebar row this id jumps to, if it is a jump shortcut.
    pub fn jump_slot(self) -> Option<usize> {
        match self {
            ShortcutId::JumpSession(slot) if slot < JUMP_SLOTS => Some(slot),
            _ => None,
        }
    }
}

/// Persisted shortcut combos. Stored platform-neutral ("mod-s"); translated to
/// "cmd-s"/"ctrl-s" at bind time by [`platform_combo`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct KeymapConfig {
    #[cfg_attr(not(any(target_os = "macos", target_os = "linux")), serde(skip))]
    pub capture_appshot: String,
    pub save_file: String,
    pub browser_reload: String,
    pub toggle_sidebar: String,
    pub toggle_changes: String,
    pub toggle_files: String,
    pub toggle_terminal: String,
    pub split_terminal: String,
    pub split_terminal_down: String,
    /// New-tab shortcut; retain this serialized field name for existing keymaps.
    pub new_session: String,
    pub new_project: String,
    pub open_project_picker: String,
    pub open_model_picker: String,
    pub next_session: String,
    pub prev_session: String,
    pub archive_session: String,
    pub close_tab_without_archiving: String,
    pub reopen_closed_tab: String,
    /// One combo per jump slot, in slot order. A list rather than nine fields:
    /// [`UiSettings::load`] discards the WHOLE file on a parse error, so a
    /// fixed-length array would let one malformed entry reset every unrelated
    /// setting. [`Self::healed`] restores the length instead.
    pub jump_session: Vec<String>,
}

/// Stable key for device-local preferences that belong to one workspace
/// profile. Authentication may arrive after `EngineInfo`, so callers must
/// treat `None` as "identity not ready" and avoid destructive cleanup.
pub fn sidebar_pin_profile_key(
    scope: Option<WorkspaceScope>,
    auth: Option<&AuthState>,
    development_org_id: Option<&str>,
) -> Option<String> {
    match scope? {
        WorkspaceScope::Local => Some("local".to_string()),
        WorkspaceScope::Synced => {
            let AuthState::SignedIn {
                user,
                org_id: Some(org_id),
            } = auth?
            else {
                return None;
            };
            Some(format!("synced:{org_id}:{}", user.id))
        }
        WorkspaceScope::Development => {
            let AuthState::SignedIn { user, .. } = auth? else {
                return None;
            };
            let (user_id, token_org_id) = user
                .id
                .split_once('@')
                .map_or((user.id.as_str(), None), |(user_id, org_id)| {
                    (user_id, (!org_id.is_empty()).then_some(org_id))
                });
            if user_id.is_empty() {
                return None;
            }
            let org_id = token_org_id
                .or(development_org_id.filter(|org_id| !org_id.is_empty()))
                .unwrap_or(harness_engine::DEFAULT_ORG_ID);
            Some(format!("development:{org_id}:{user_id}"))
        }
    }
}

impl Default for KeymapConfig {
    fn default() -> Self {
        Self {
            capture_appshot: ShortcutId::CaptureAppshot.default_combo().into(),
            save_file: ShortcutId::SaveFile.default_combo().into(),
            browser_reload: ShortcutId::BrowserReload.default_combo().into(),
            toggle_sidebar: ShortcutId::ToggleSidebar.default_combo().into(),
            toggle_changes: ShortcutId::ToggleChanges.default_combo().into(),
            toggle_files: ShortcutId::ToggleFiles.default_combo().into(),
            toggle_terminal: ShortcutId::ToggleTerminal.default_combo().into(),
            split_terminal: ShortcutId::SplitTerminal.default_combo().into(),
            split_terminal_down: ShortcutId::SplitTerminalDown.default_combo().into(),
            new_session: ShortcutId::NewSession.default_combo().into(),
            new_project: ShortcutId::NewProject.default_combo().into(),
            open_project_picker: ShortcutId::OpenProjectPicker.default_combo().into(),
            open_model_picker: ShortcutId::OpenModelPicker.default_combo().into(),
            next_session: ShortcutId::NextSession.default_combo().into(),
            prev_session: ShortcutId::PrevSession.default_combo().into(),
            archive_session: ShortcutId::ArchiveSession.default_combo().into(),
            close_tab_without_archiving: ShortcutId::CloseTabWithoutArchiving.default_combo().into(),
            reopen_closed_tab: ShortcutId::ReopenClosedTab.default_combo().into(),
            jump_session: JUMP_DEFAULTS.iter().map(|c| (*c).to_string()).collect(),
        }
    }
}

impl KeymapConfig {
    pub fn get(&self, id: ShortcutId) -> &str {
        match id {
            ShortcutId::CaptureAppshot => &self.capture_appshot,
            ShortcutId::SaveFile => &self.save_file,
            ShortcutId::BrowserReload => &self.browser_reload,
            ShortcutId::ToggleSidebar => &self.toggle_sidebar,
            ShortcutId::ToggleChanges => &self.toggle_changes,
            ShortcutId::ToggleFiles => &self.toggle_files,
            ShortcutId::ToggleTerminal => &self.toggle_terminal,
            ShortcutId::SplitTerminal => &self.split_terminal,
            ShortcutId::SplitTerminalDown => &self.split_terminal_down,
            ShortcutId::NewSession => &self.new_session,
            ShortcutId::NewProject => &self.new_project,
            ShortcutId::OpenProjectPicker => &self.open_project_picker,
            ShortcutId::OpenModelPicker => &self.open_model_picker,
            ShortcutId::NextSession => &self.next_session,
            ShortcutId::PrevSession => &self.prev_session,
            ShortcutId::ArchiveSession => &self.archive_session,
            ShortcutId::CloseTabWithoutArchiving => &self.close_tab_without_archiving,
            ShortcutId::ReopenClosedTab => &self.reopen_closed_tab,
            ShortcutId::JumpSession(slot) => self
                .jump_session
                .get(slot)
                .map(String::as_str)
                .unwrap_or(""),
        }
    }

    pub fn set(&mut self, id: ShortcutId, combo: String) {
        match id {
            ShortcutId::CaptureAppshot => self.capture_appshot = combo,
            ShortcutId::SaveFile => self.save_file = combo,
            ShortcutId::BrowserReload => self.browser_reload = combo,
            ShortcutId::ToggleSidebar => self.toggle_sidebar = combo,
            ShortcutId::ToggleChanges => self.toggle_changes = combo,
            ShortcutId::ToggleFiles => self.toggle_files = combo,
            ShortcutId::ToggleTerminal => self.toggle_terminal = combo,
            ShortcutId::SplitTerminal => self.split_terminal = combo,
            ShortcutId::SplitTerminalDown => self.split_terminal_down = combo,
            ShortcutId::NewSession => self.new_session = combo,
            ShortcutId::NewProject => self.new_project = combo,
            ShortcutId::OpenProjectPicker => self.open_project_picker = combo,
            ShortcutId::OpenModelPicker => self.open_model_picker = combo,
            ShortcutId::NextSession => self.next_session = combo,
            ShortcutId::PrevSession => self.prev_session = combo,
            ShortcutId::ArchiveSession => self.archive_session = combo,
            ShortcutId::CloseTabWithoutArchiving => self.close_tab_without_archiving = combo,
            ShortcutId::ReopenClosedTab => self.reopen_closed_tab = combo,
            ShortcutId::JumpSession(slot) => {
                if slot < JUMP_SLOTS {
                    if self.jump_session.len() < JUMP_SLOTS {
                        self.heal_jump_slots();
                    }
                    self.jump_session[slot] = combo;
                }
            }
        }
    }

    pub fn reset(&mut self, id: ShortcutId) {
        self.set(id, id.default_combo().to_string());
    }

    /// Restore the jump list to exactly [`JUMP_SLOTS`] entries: a hand-edited
    /// or older file may carry a short, long or absent list. Surviving entries
    /// keep their slot; missing ones take the default.
    pub fn heal_jump_slots(&mut self) {
        self.jump_session.truncate(JUMP_SLOTS);
        while self.jump_session.len() < JUMP_SLOTS {
            self.jump_session
                .push(JUMP_DEFAULTS[self.jump_session.len()].to_string());
        }
    }

    /// Cmd/Ctrl+Enter belongs to the composer on every send mode. Older
    /// settings could assign it to an app shortcut while plain Enter was the
    /// configured sender; restore only those newly-conflicting rows to their
    /// defaults and preserve every unrelated customization.
    fn heal_reserved_composer_shortcuts(&mut self) {
        for id in ShortcutId::ALL {
            if self.get(id) == "mod-enter" {
                self.reset(id);
            }
        }
    }
}

/// Build a combo string from a recorded keystroke. The primary modifier
/// (cmd on macOS, ctrl elsewhere) becomes "mod"; bare modifier presses record
/// nothing.
pub fn combo_from_keystroke(
    ctrl: bool,
    alt: bool,
    shift: bool,
    cmd: bool,
    key: &str,
) -> Option<String> {
    combo_from_keystroke_on(cfg!(target_os = "macos"), ctrl, alt, shift, cmd, key)
}

/// [`combo_from_keystroke`] for an explicit platform — the ctrl spelling is
/// platform-dependent, so both paths need to be exercisable from one machine.
pub fn combo_from_keystroke_on(
    mac: bool,
    ctrl: bool,
    alt: bool,
    shift: bool,
    cmd: bool,
    key: &str,
) -> Option<String> {
    let key = key.trim().to_lowercase();
    if key.is_empty()
        || matches!(
            key.as_str(),
            "ctrl" | "control" | "alt" | "shift" | "cmd" | "platform" | "fn"
        )
    {
        return None;
    }
    let mut parts: Vec<&str> = Vec::new();
    // On macOS ctrl stays its own modifier rather than folding into "mod":
    // re-recording Ctrl+Tab as Cmd+Tab would hand the combo to the OS app
    // switcher, which never delivers it to the window.
    let ctrl_is_primary = ctrl && !mac;
    if cmd || ctrl_is_primary {
        parts.push("mod");
    }
    if ctrl && !ctrl_is_primary {
        parts.push("ctrl");
    }
    if alt {
        parts.push("alt");
    }
    if shift {
        parts.push("shift");
    }
    parts.push(&key);
    Some(parts.join("-"))
}

/// Shortcut ids whose combos collide with another shortcut (conflict detection).
pub fn conflicted_shortcuts(keymap: &KeymapConfig) -> Vec<ShortcutId> {
    ShortcutId::ALL
        .into_iter()
        .filter(|&id| {
            let combo = keymap.get(id);
            id.available()
                && !combo.is_empty()
                && ShortcutId::ALL
                    .into_iter()
                    .any(|other| other.available() && other != id && keymap.get(other) == combo)
        })
        .collect()
}

/// The modifiers a stored combo carries, as `(mod, alt, shift)`. Everything
/// before the final segment is a modifier; the final segment is the key.
pub fn combo_modifiers(combo: &str) -> (bool, bool, bool) {
    let mut parts: Vec<&str> = combo.split('-').collect();
    parts.pop();
    (
        parts.contains(&"mod"),
        parts.contains(&"alt"),
        parts.contains(&"shift"),
    )
}

/// Whether the sidebar should show its jump hints for the currently held
/// modifiers (t3code `shouldShowThreadJumpHintsForModifiers`). The held set
/// must match a jump combo EXACTLY, so adding Shift or Alt hides the hints and
/// a chord like Cmd+Shift+4 never flashes the overlay. `primary` is the held
/// "mod" key — cmd on macOS, ctrl elsewhere.
///
/// A jump combo with no modifiers at all never shows hints: it would otherwise
/// match the resting state and pin the overlay open. Pure.
pub fn jump_hints_visible(keymap: &KeymapConfig, primary: bool, alt: bool, shift: bool) -> bool {
    if !(primary || alt || shift) {
        return false;
    }
    ShortcutId::ALL
        .into_iter()
        .filter(|id| id.jump_slot().is_some())
        .any(|id| combo_modifiers(keymap.get(id)) == (primary, alt, shift))
}

/// Cmd on macOS and Ctrl elsewhere reveals the composer's modified-submit
/// hint only while that modifier is held by itself.
pub fn modifier_send_hint_visible(primary: bool, alt: bool, shift: bool) -> bool {
    primary && !alt && !shift
}

/// Translate a stored combo into a bindable keystroke for this platform.
pub fn platform_combo(combo: &str) -> String {
    platform_combo_on(cfg!(target_os = "macos"), combo)
}

/// [`platform_combo`] for an explicit platform (see [`combo_from_keystroke_on`]).
pub fn platform_combo_on(mac: bool, combo: &str) -> String {
    let primary = if mac { "cmd" } else { "ctrl" };
    combo
        .split('-')
        .map(|part| if part == "mod" { primary } else { part })
        .collect::<Vec<_>>()
        .join("-")
}

/// Human-readable combo for the shortcuts table ("mod-s" → "Cmd+S"/"Ctrl+S").
pub fn display_combo(combo: &str) -> String {
    display_combo_on(cfg!(target_os = "macos"), combo)
}

fn display_combo_parts(combo: &str) -> Vec<&str> {
    let mut parts: Vec<_> = combo.split('-').collect();
    // The separator is also a valid key: `mod--` means Cmd/Ctrl+minus.
    if combo.ends_with("--") || combo == "-" {
        parts.pop();
        parts.pop();
        parts.push("-");
    }
    parts
}

/// [`display_combo`] for an explicit platform (see [`combo_from_keystroke_on`]).
pub fn display_combo_on(mac: bool, combo: &str) -> String {
    display_combo_parts(combo)
        .into_iter()
        .map(|part| match part {
            "mod" => if mac { "Cmd" } else { "Ctrl" }.to_string(),
            "alt" => if mac { "Opt" } else { "Alt" }.to_string(),
            "shift" => "Shift".to_string(),
            other => {
                let mut chars = other.chars();
                match chars.next() {
                    Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                    None => String::new(),
                }
            }
        })
        .collect::<Vec<_>>()
        .join("+")
}

/// Compact combo for badge surfaces (the sidebar jump hints): macOS spells
/// the modifiers as their key glyphs in canonical ⌃⌥⇧⌘ order and drops the
/// separators ("⌘1", "⇧⌘A") — the form the model picker's ⌘N chips already
/// use — while other platforms keep the textual [`display_combo`] ("Ctrl+1").
pub fn badge_combo(combo: &str) -> String {
    badge_combo_on(cfg!(target_os = "macos"), combo)
}

/// Badge for a rebindable shell action, including the binding fallback used
/// by `shell::apply_keymap` when a persisted combo cannot be parsed.
pub fn shortcut_badge(cx: &App, id: ShortcutId) -> String {
    with_current(cx, |settings| {
        let combo = settings.keymap.get(id);
        badge_combo(if gpui::Keystroke::parse(&platform_combo(combo)).is_ok() {
            combo
        } else {
            id.default_combo()
        })
    })
}

/// [`badge_combo`] for an explicit platform (see [`combo_from_keystroke_on`]).
pub fn badge_combo_on(mac: bool, combo: &str) -> String {
    if !mac {
        return display_combo_on(false, combo);
    }
    let mut parts = display_combo_parts(combo);
    let key = parts.pop().unwrap_or("");
    let mut out = String::new();
    for (names, glyph) in [
        (&["ctrl"][..], '⌃'),
        (&["alt"][..], '⌥'),
        (&["shift"][..], '⇧'),
        (&["mod", "cmd", "super"][..], '⌘'),
    ] {
        if names
            .iter()
            .any(|name| parts.iter().any(|part| part.eq_ignore_ascii_case(name)))
        {
            out.push(glyph);
        }
    }
    let mut chars = key.chars();
    if let Some(first) = chars.next() {
        out.extend(first.to_uppercase());
        out.push_str(chars.as_str());
    }
    out
}

impl UiSettings {
    pub fn remember_closed_chat(&mut self, record: SavedClosedChat) {
        let key = record.chat_id.as_ref().map_or_else(
            || format!("draft:{}", record.id),
            |chat| format!("chat:{chat}"),
        );
        self.unhide_history_entry(&key);
        // Independent windows can hold different unsent replies for one chat.
        // Deduplicate the placement, but keep any displaced input recoverable.
        for previous in &mut self.recently_closed_chats {
            if previous.id != record.id
                && record.chat_id.is_some()
                && previous.chat_id == record.chat_id
                && (!previous.draft.input.text.is_empty()
                    || !previous.draft.input.attachments.is_empty()
                    || !previous.draft.appshots.is_empty())
                && (previous.draft.input.text != record.draft.input.text
                    || previous.draft.input.attachments != record.draft.input.attachments
                    || previous.draft.appshots != record.draft.appshots)
            {
                previous.chat_id = None;
                previous.was_new_tab = false;
            }
        }
        self.recently_closed_chats.retain(|previous| {
            previous.id != record.id
                && (record.chat_id.is_none() || previous.chat_id != record.chat_id)
        });
        self.recently_closed_chats.insert(0, record);
        self.recently_closed_chats
            .sort_by_key(|record| std::cmp::Reverse(record.closed_at));
    }

    pub fn forget_closed_chat(&mut self, id: &str) {
        self.recently_closed_chats
            .retain(|record| record.id != id && record.chat_id.as_deref() != Some(id));
    }

    /// Discard only the unsent recovery the user actually confirmed. A newer
    /// close or a changed record must not be removed by a stale dialog.
    pub fn discard_closed_chat(&mut self, expected: &SavedClosedChat) -> bool {
        if expected.chat_id.is_some() {
            return false;
        }
        let Some(index) = self
            .recently_closed_chats
            .iter()
            .position(|record| record == expected)
        else {
            return false;
        };
        self.recently_closed_chats.remove(index);
        self.hidden_history_entries
            .retain(|key| key != &format!("draft:{}", expected.id));
        true
    }

    pub fn hide_history_entry(&mut self, key: &str) -> bool {
        if !key
            .strip_prefix("chat:")
            .or_else(|| key.strip_prefix("draft:"))
            .is_some_and(|id| !id.is_empty())
            || self
                .hidden_history_entries
                .iter()
                .any(|hidden| hidden == key)
        {
            return false;
        }
        self.hidden_history_entries.push(key.to_owned());
        true
    }

    pub fn unhide_history_entry(&mut self, key: &str) {
        self.hidden_history_entries.retain(|hidden| hidden != key);
    }

    /// Migration is represented by absence, rather than an empty collection,
    /// so a later launch cannot resurrect explicitly closed legacy windows.
    pub fn restorable_workspace_windows(&self) -> Vec<SavedWorkspaceWindow> {
        self.workspace_windows
            .clone()
            .unwrap_or_else(|| vec![SavedWorkspaceWindow::from_settings("main".into(), self)])
    }

    /// Update only one record against the canonical settings snapshot. This
    /// deliberately does not deduplicate sessions across independent windows.
    pub fn upsert_workspace_window(&mut self, record: SavedWorkspaceWindow) {
        if record.id.trim().is_empty() {
            return;
        }
        let windows = self.workspace_windows.get_or_insert_with(Vec::new);
        if let Some(existing) = windows.iter_mut().find(|window| window.id == record.id) {
            *existing = record;
        } else {
            windows.push(record);
        }
    }

    pub fn remove_workspace_window(&mut self, id: &str) {
        self.workspace_windows
            .get_or_insert_with(Vec::new)
            .retain(|window| window.id != id);
    }

    /// Reset presentation only; keep organization, ordering, sections and width.
    pub fn reset_sidebar_display(&mut self) {
        self.sidebar_compact = true;
        self.sidebar_show_project_icon = false;
        self.sidebar_show_project_label = false;
        self.sidebar_show_harness = true;
        self.sidebar_show_branch = true;
        self.sidebar_show_updated = true;
    }

    pub fn sidebar_pins(&self, profile_key: &str) -> &[String] {
        self.sidebar_pinned_session_ids_by_profile
            .get(profile_key)
            .map(Vec::as_slice)
            .unwrap_or_default()
    }

    pub fn sidebar_pins_mut(&mut self, profile_key: String) -> &mut Vec<String> {
        self.sidebar_pinned_session_ids_by_profile
            .entry(profile_key)
            .or_default()
    }

    pub fn skill_completion(&self, harness: harness_proto::HarnessId) -> SkillCompletionSettings {
        self.skill_completion_by_harness
            .get(&harness)
            .copied()
            .unwrap_or_else(|| {
                let mut settings = SkillCompletionSettings::for_harness(harness);
                if self.skills_in_slash_menu {
                    settings.separate_from_slash = false;
                }
                settings
            })
    }

    /// Whether this session event may produce audio. Appshot capture has its
    /// own feature-local preference once the Appshots contribution lands.
    pub fn session_sound_enabled(&self, sound: crate::sound::Sound) -> bool {
        self.sound_enabled
            && match sound {
                crate::sound::Sound::Done => self.sound_completion_enabled,
                crate::sound::Sound::Request => self.sound_input_enabled,
                crate::sound::Sound::Attention => self.sound_attention_enabled,
            }
    }

    /// Clamp widths into their legal ranges (also heals NaN to defaults).
    pub fn clamped(mut self) -> Self {
        self.transcript_width = normalize_transcript_width(self.transcript_width);
        self.window_geometry = self.window_geometry.filter(|geometry| geometry.is_valid());
        if let Some(windows) = self.workspace_windows.as_mut() {
            let mut ids = std::collections::HashSet::new();
            windows.retain_mut(|window| {
                if window.id.trim().is_empty() || !ids.insert(window.id.clone()) {
                    return false;
                }
                window.geometry = window.geometry.filter(|geometry| geometry.is_valid());
                window.chat_tab = window
                    .chat_tab
                    .min(window.chat_tabs.len().saturating_sub(1));
                true
            });
        }
        self.sidebar_width = clamp_or(
            self.sidebar_width,
            SIDEBAR_MIN,
            SIDEBAR_MAX,
            SIDEBAR_DEFAULT,
        );
        // The right pane has no persisted upper bound: its live drag clamps
        // against the current window, which is unavailable while loading.
        self.files_panel_width = clamp_or(
            self.files_panel_width,
            FILES_PANEL_MIN,
            FILES_PANEL_MAX,
            FILES_PANEL_DEFAULT,
        );
        self.right_pane_width = min_or(self.right_pane_width, RIGHT_PANE_MIN, RIGHT_PANE_DEFAULT);
        self.terminal_height = clamp_or(
            self.terminal_height,
            TERMINAL_MIN_HEIGHT,
            TERMINAL_ABS_MAX_HEIGHT,
            TERMINAL_DEFAULT_HEIGHT,
        );
        self.files_autosave_delay_ms = self
            .files_autosave_delay_ms
            .clamp(FILES_AUTOSAVE_DELAY_MIN_MS, FILES_AUTOSAVE_DELAY_MAX_MS);
        self.terminal_font_size = clamp_or(
            self.terminal_font_size,
            crate::typography::FONT_SIZE_MIN,
            crate::typography::FONT_SIZE_MAX,
            crate::typography::TERMINAL_FONT_SIZE_DEFAULT,
        );
        self.code_font_size = clamp_or(
            self.code_font_size,
            crate::typography::FONT_SIZE_MIN,
            crate::typography::FONT_SIZE_MAX,
            crate::typography::CODE_FONT_SIZE_DEFAULT,
        );
        self.git_history_column_widths = self.git_history_column_widths.clamped();
        self.git_history_column_order = self.git_history_column_order.normalized();
        self.ui_font_size = self.ui_font_size.normalized();
        self.keymap.heal_jump_slots();
        self.keymap.heal_reserved_composer_shortcuts();
        self
    }

    /// Load from `{data_dir}/ui-settings.json`; defaults on any failure.
    /// A new install shows less (as #417 and #614 did): a turn's tool steps
    /// fold into one line and sidebar rows drop branch names. Both stay one
    /// toggle away, and existing settings files keep what they chose.
    pub fn first_run() -> Self {
        Self {
            sidebar_show_branch: false,
            ..Self::default()
        }
    }

    pub fn load(data_dir: &Path) -> Self {
        match std::fs::read_to_string(Self::path(data_dir)) {
            Ok(text) => match serde_json::from_str(&text)
                .and_then(|mut value| Self::decode_document(&mut value))
            {
                Ok(settings) => settings,
                Err(err) => {
                    tracing::warn!(error = %err, "ui-settings corrupt; using defaults");
                    Self::default()
                }
            },
            Err(_) => Self::default(),
        }
    }

    /// Unlike startup's defaults-on-error wrapper, persistence must propagate
    /// decode failures rather than overwrite an existing malformed document.
    fn decode_document(value: &mut serde_json::Value) -> serde_json::Result<Self> {
        if let Some(settings) = value.as_object_mut() {
            // Existing upstream files inherited Geist; the local
            // workspace format inherited System UI. Preserve that
            // effective choice when a legacy file omitted the font.
            // A new installation still uses the platform default.
            if !settings.contains_key("uiFontFamily") {
                let local_workspace_format = settings.contains_key("workspaceWindows")
                    || settings
                        .get("projectTabsVersion")
                        .and_then(serde_json::Value::as_u64)
                        .is_some_and(|version| version >= 2)
                    || settings
                        .get("chatTabs")
                        .and_then(serde_json::Value::as_array)
                        .is_some_and(|tabs| {
                            tabs.iter().any(|tab| {
                                tab.get("id")
                                    .and_then(serde_json::Value::as_str)
                                    .is_some_and(|id| !id.is_empty())
                            })
                        });
                settings.insert(
                    "uiFontFamily".into(),
                    serde_json::json!(if local_workspace_format {
                        "system"
                    } else {
                        "geist"
                    }),
                );
            }
            let previous_sound = settings
                .get("soundEnabled")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(true);
            settings
                .entry("appshotSoundEnabled")
                .or_insert(serde_json::Value::Bool(previous_sound));
            // The files-editor size was the first user-facing code
            // size; it now drives every code surface.
            if let Some(legacy) = settings.remove("filesEditorFontSize") {
                settings.entry("codeFontSize").or_insert(legacy);
            }
        }
        // Replace the retired new-session default with the unified
        // new-tab shortcut, without changing custom bindings.
        if let Some(keymap) = value
            .get_mut("keymap")
            .and_then(serde_json::Value::as_object_mut)
            && keymap.get("newSession").and_then(serde_json::Value::as_str) == Some("mod-n")
        {
            keymap.insert(
                "newSession".into(),
                serde_json::json!(ShortcutId::NewSession.default_combo()),
            );
        }
        if let Some(keymap) = value
            .get_mut("keymap")
            .and_then(serde_json::Value::as_object_mut)
            && !keymap.contains_key("saveFile")
        {
            // Reserve customized chords before assigning any new defaults.
            // An older map may already use Cmd+S/B/R for another action.
            let mut migrating = vec![(ShortcutId::SaveFile, "saveFile", "", "mod-shift-s")];
            for (id, field, old, fallback) in [
                (
                    ShortcutId::ToggleSidebar,
                    "toggleSidebar",
                    "mod-s",
                    "mod-shift-b",
                ),
                (
                    ShortcutId::ToggleChanges,
                    "toggleChanges",
                    "mod-b",
                    "mod-shift-r",
                ),
            ] {
                if keymap
                    .get(field)
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or(old)
                    == old
                {
                    migrating.push((id, field, old, fallback));
                }
            }
            for (_, field, _, _) in &migrating {
                keymap.insert((*field).into(), serde_json::json!(""));
            }
            let mut resolved: KeymapConfig =
                serde_json::from_value(serde_json::Value::Object(keymap.clone()))?;
            for (id, field, old, fallback) in migrating {
                let combo = [id.default_combo(), old, fallback]
                    .into_iter()
                    .find(|candidate| {
                        !candidate.is_empty()
                            && !ShortcutId::ALL.iter().any(|other| {
                                let existing = resolved.get(*other);
                                !existing.is_empty()
                                    && platform_combo(existing) == platform_combo(candidate)
                            })
                    })
                    .unwrap_or("");
                resolved.set(id, combo.into());
                keymap.insert(field.into(), serde_json::json!(combo));
            }
        }
        // A shortcut added after the file was written takes its
        // default only when that combo is free: a user who had
        // already bound the same chord elsewhere keeps their
        // binding and the new row arrives unbound.
        if let Some(keymap) = value
            .get_mut("keymap")
            .and_then(serde_json::Value::as_object_mut)
        {
            for (id, field) in [(ShortcutId::ToggleFiles, "toggleFiles")] {
                let default = platform_combo(id.default_combo());
                let taken = !keymap.contains_key(field)
                    && keymap.values().any(|existing| {
                        existing
                            .as_str()
                            .is_some_and(|combo| platform_combo(combo) == default)
                    });
                if taken {
                    keymap.insert(field.into(), serde_json::json!(""));
                }
            }
        }
        // A malformed `settingsSection` must not cost the rest of
        // the file: drop it and the default section applies.
        if let Some(map) = value.as_object_mut()
            && map.get("settingsSection").is_some_and(|v| !v.is_string())
        {
            map.remove("settingsSection");
        }
        serde_json::from_value::<UiSettings>(value.clone())
            .map(|settings| settings.migrated().clamped())
    }

    /// Write a complete snapshot. Production stores reconcile first; fixtures
    /// may use this directly to seed an isolated settings file.
    pub fn save(&self, data_dir: &Path) -> io::Result<()> {
        save_settings_document(self, data_dir)
    }

    fn migrated(mut self) -> Self {
        if self.accent == harness_theme::AccentSelection::ThemeDefault
            && let Some(accent) = self.legacy_accent_color.take()
        {
            self.accent = harness_theme::AccentSelection::Preset(accent.into());
        }
        self.legacy_accent_color = None;
        // Turning archive-on-close on was a choice; don't ask about it again.
        self.archive_on_close_chosen |= self.archive_sessions_on_close;
        // Compact mode is the default now: a file from before it was turns
        // it on once, whatever it said. What's chosen after that stays.
        if !self.transcript_compact_default_applied {
            self.transcript_compact_mode = true;
            self.transcript_compact_default_applied = true;
        }
        self
    }

    pub fn path(data_dir: &Path) -> PathBuf {
        data_dir.join(FILE_NAME)
    }
}

/// Apply only the store's local delta to the latest disk document. Settings
/// are top-level conflict units, as in the existing window preference merge;
/// omitted values participate so explicit resets remove the old key.
fn merge_settings_document(
    baseline: &UiSettings,
    local: &UiSettings,
    mut document: serde_json::Value,
) -> serde_json::Result<(UiSettings, serde_json::Value)> {
    if !document.is_object() {
        return Err(serde::de::Error::custom(
            "ui settings must be a JSON object",
        ));
    }
    let latest = UiSettings::decode_document(&mut document)?;
    let baseline = serde_json::to_value(baseline)?;
    let local = serde_json::to_value(local)?;
    let latest = serde_json::to_value(latest)?;
    let baseline = baseline
        .as_object()
        .expect("settings serialize as an object");
    let local = local.as_object().expect("settings serialize as an object");
    // Materialize migrated/defaulted fields (including compact mode's marker)
    // without dropping unknown keys, even inside an unchanged known object.
    overlay_normalized_settings(&mut document, latest);
    let output = document
        .as_object_mut()
        .expect("settings decode from an object");
    output.remove("accentColor");
    let keys: std::collections::HashSet<_> = baseline.keys().chain(local.keys()).collect();
    for key in keys {
        if baseline.get(key) == local.get(key) {
            continue;
        }
        if let Some(value) = local.get(key) {
            output.insert(key.clone(), value.clone());
        } else {
            output.remove(key);
        }
    }
    let settings = serde_json::from_value::<UiSettings>(document.clone())?.clamped();
    Ok((settings, document))
}

fn overlay_normalized_settings(target: &mut serde_json::Value, normalized: serde_json::Value) {
    match (target, normalized) {
        (serde_json::Value::Object(target), serde_json::Value::Object(normalized)) => {
            for (key, value) in normalized {
                if let Some(existing) = target.get_mut(&key) {
                    overlay_normalized_settings(existing, value);
                } else {
                    target.insert(key, value);
                }
            }
        }
        (target, normalized) => *target = normalized,
    }
}

fn settings_json_error(error: serde_json::Error) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}

fn save_settings_document(settings: &impl Serialize, data_dir: &Path) -> io::Result<()> {
    std::fs::create_dir_all(data_dir)?;
    let path = UiSettings::path(data_dir);
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(settings).map_err(settings_json_error)?;
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, &path)
}

fn clamp_or(value: f32, min: f32, max: f32, default: f32) -> f32 {
    if value.is_finite() {
        value.clamp(min, max)
    } else {
        default
    }
}

fn min_or(value: f32, min: f32, default: f32) -> f32 {
    if value.is_finite() {
        value.max(min)
    } else {
        default
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[gpui::test]
    fn settings_store_unrelated_save_preserves_external_sidebar_choice(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let initial = UiSettings {
            sidebar_organization: SidebarOrganization::InOneList,
            ..Default::default()
        };
        initial.save(dir.path()).unwrap();
        cx.update(|cx| {
            init(UiSettings::load(dir.path()), dir.path(), cx);
            let path = UiSettings::path(dir.path());
            let mut external: serde_json::Value =
                serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            external["sidebarOrganization"] = serde_json::json!("byProject");
            external["futureSetting"] = serde_json::json!({"preserve": [1, 2]});
            std::fs::write(&path, serde_json::to_vec(&external).unwrap()).unwrap();

            assert!(update(SavePolicy::Immediate, cx, |settings| {
                settings.sidebar_width = 300.0;
            }));
            let saved = UiSettings::load(dir.path());
            assert_eq!(saved.sidebar_organization, SidebarOrganization::ByProject);
            assert_eq!(saved.sidebar_width, 300.0);
            assert_eq!(current(cx), saved);
            assert!(update(SavePolicy::Debounced, cx, |settings| {
                settings.sound_enabled = false;
            }));
            external = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            external["sidebarOrganization"] = serde_json::json!("byDevice");
            std::fs::write(&path, serde_json::to_vec(&external).unwrap()).unwrap();
            flush(cx);
            let saved = UiSettings::load(dir.path());
            assert_eq!(saved.sidebar_organization, SidebarOrganization::ByDevice);
            assert!(!saved.sound_enabled);
            assert_eq!(current(cx), saved);
            assert!(update(SavePolicy::Immediate, cx, |settings| {
                settings.sidebar_width = 310.0;
            }));
            let saved: serde_json::Value =
                serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
            assert_eq!(saved["sidebarOrganization"], "byDevice");
            assert_eq!(
                saved["futureSetting"],
                serde_json::json!({"preserve": [1, 2]})
            );
        });
    }

    #[test]
    fn settings_document_merge_preserves_choices_resets_and_disk_deletions() {
        let baseline = UiSettings {
            sidebar_organization: SidebarOrganization::ByProject,
            new_thread_composer_background: Some(NewThreadComposerBackground {
                path: "synthetic.png".into(),
                name: "synthetic.png".into(),
            }),
            graff_notice_dismissed: Some("old".into()),
            last_project_action_by_space_id: HashMap::from([("synthetic".into(), "build".into())]),
            ..Default::default()
        };
        let mut local = baseline.clone();
        local.sidebar_organization = SidebarOrganization::InOneList;
        local.new_thread_composer_background = None;
        local.last_project_action_by_space_id.clear();
        let mut disk = serde_json::to_value(&baseline).unwrap();
        disk["sidebarOrganization"] = serde_json::json!("byDevice");
        disk["soundEnabled"] = serde_json::json!(false);
        disk["futureSetting"] = serde_json::json!({"keep": 17});
        disk["keymap"]["futureAction"] = serde_json::json!("mod-future");
        disk.as_object_mut().unwrap().remove("graffNoticeDismissed");
        let (merged, document) = merge_settings_document(&baseline, &local, disk).unwrap();
        assert_eq!(merged.sidebar_organization, SidebarOrganization::InOneList);
        assert!(!merged.sound_enabled);
        assert!(merged.new_thread_composer_background.is_none());
        assert!(document.get("newThreadComposerBackground").is_none());
        assert!(merged.last_project_action_by_space_id.is_empty());
        assert!(document.get("lastProjectActionBySpaceId").is_none());
        assert!(merged.graff_notice_dismissed.is_none());
        assert!(document.get("graffNoticeDismissed").is_none());
        assert_eq!(document["futureSetting"], serde_json::json!({"keep": 17}));
        assert_eq!(document["keymap"]["futureAction"], "mod-future");

        let mut local = baseline.clone();
        local.transcript_compact_mode = false;
        let (merged, document) = merge_settings_document(
            &baseline,
            &local,
            serde_json::json!({"transcriptCompactMode": false, "accentColor": "cyan"}),
        )
        .unwrap();
        assert!(!merged.transcript_compact_mode);
        assert_eq!(document["transcriptCompactDefaultApplied"], true);
        assert!(document.get("accentColor").is_none());
        let mut document = document;
        let loaded = UiSettings::decode_document(&mut document).unwrap();
        assert!(!loaded.transcript_compact_mode);
        assert_eq!(loaded.accent, merged.accent);
    }

    #[gpui::test]
    fn settings_store_failed_save_keeps_baseline_and_retries_external_choices(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let initial = UiSettings {
            sidebar_organization: SidebarOrganization::InOneList,
            ..Default::default()
        };
        initial.save(dir.path()).unwrap();
        cx.update(|cx| {
            init(initial.clone(), dir.path(), cx);
            assert!(update(SavePolicy::Debounced, cx, |settings| {
                settings.sidebar_width = 300.0;
            }));
            let path = UiSettings::path(dir.path());
            let mut external = initial.clone();
            external.sidebar_organization = SidebarOrganization::ByProject;
            external.code_fences_fit_content = true;
            external.save(dir.path()).unwrap();
            let before = std::fs::read(&path).unwrap();
            let temporary = path.with_extension("json.tmp");
            std::fs::create_dir(&temporary).unwrap();
            flush(cx);
            let store = cx.global::<SettingsStore>();
            assert_eq!(store.baseline, initial);
            assert_eq!(store.saved_revision, 0);
            assert_ne!(store.revision, store.saved_revision);
            assert_eq!(store.current.sidebar_width, 300.0);
            assert_eq!(
                store.current.sidebar_organization,
                SidebarOrganization::InOneList
            );
            assert_eq!(std::fs::read(&path).unwrap(), before);
            std::fs::remove_dir(&temporary).unwrap();
            flush(cx);
            let store = cx.global::<SettingsStore>();
            assert_eq!(
                store.current.sidebar_organization,
                SidebarOrganization::ByProject
            );
            assert_eq!(store.current.sidebar_width, 300.0);
            assert_eq!(store.current, store.baseline);
            assert_eq!(store.revision, store.saved_revision);
            assert_eq!(store.code_fences_generation, 1);
            assert_eq!(UiSettings::load(dir.path()), store.current);
        });
    }

    #[gpui::test]
    fn settings_store_rejects_corrupt_disk_without_losing_pending_edits(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            let initial = UiSettings::default();
            init(initial.clone(), dir.path(), cx);
            for corrupt in ["not JSON", "[]", r#"{"sidebarOrganization":17}"#] {
                std::fs::write(UiSettings::path(dir.path()), corrupt).unwrap();
                update(SavePolicy::Debounced, cx, |settings| {
                    settings.sidebar_width = 300.0;
                });
                flush(cx);
                let store = cx.global::<SettingsStore>();
                assert_eq!(store.baseline, initial);
                assert_ne!(store.revision, store.saved_revision);
                assert_eq!(store.current.sidebar_width, 300.0);
                assert_eq!(
                    std::fs::read_to_string(UiSettings::path(dir.path())).unwrap(),
                    corrupt
                );
            }
        });
    }

    #[test]
    fn skill_completion_defaults_overrides_and_persistence_are_per_harness() {
        use harness_proto::HarnessId;
        let dir = tempfile::tempdir().unwrap();
        let mut settings = UiSettings::default();
        for (harness, _) in SKILL_COMPLETION_HARNESSES {
            let preferences = settings.skill_completion(harness);
            assert_eq!(preferences.dollar, harness == HarnessId::Codex);
            assert_eq!(preferences.separate_from_slash, harness == HarnessId::Codex);
        }
        settings.skill_completion_by_harness.insert(
            HarnessId::ClaudeCode,
            SkillCompletionSettings {
                dollar: true,
                separate_from_slash: true,
            },
        );
        settings.skill_completion_by_harness.insert(
            HarnessId::Opencode,
            SkillCompletionSettings {
                dollar: true,
                separate_from_slash: false,
            },
        );
        settings.save(dir.path()).unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(
            settings.skill_completion_by_harness,
            loaded.skill_completion_by_harness
        );
        assert!(loaded.skill_completion(HarnessId::ClaudeCode).dollar);
        assert!(!loaded.skill_completion(HarnessId::Cursor).dollar);
        let legacy: UiSettings = serde_json::from_str(r#"{"skillsInSlashMenu":true}"#).unwrap();
        assert!(
            !legacy
                .skill_completion(HarnessId::Codex)
                .separate_from_slash
        );
        assert!(legacy.skill_completion(HarnessId::Codex).dollar);
    }

    #[test]
    fn settings_section_persists_and_a_bad_value_costs_nothing() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(UiSettings::default().settings_section, None);
        let mut settings = UiSettings::default();
        settings.settings_section = Some("appearance".into());
        settings.save(dir.path()).unwrap();
        assert_eq!(
            UiSettings::load(dir.path()).settings_section.as_deref(),
            Some("appearance")
        );

        // A value of the wrong type is dropped; the rest of the file survives.
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth":300,"settingsSection":5}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.settings_section, None);
        assert_eq!(loaded.sidebar_width, 300.0);

        // An unknown name loads as-is (the shell falls back when it reads it).
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth":300,"settingsSection":"nope"}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.settings_section.as_deref(), Some("nope"));
        assert_eq!(loaded.sidebar_width, 300.0);
    }

    #[test]
    fn closed_chat_history_round_trips_drafts_and_deduplicates_conversations() {
        let mut settings: UiSettings = serde_json::from_str("{}").unwrap();
        assert!(settings.recently_closed_chats.is_empty());
        let mut chat = SavedClosedChat {
            id: "close-one".into(),
            chat_id: Some("chat-one".into()),
            window_id: "window-one".into(),
            session_id: "session-one".into(),
            panel_id: 7,
            tab_index: 2,
            closed_at: 1234,
            draft: SavedWindowChatDraft {
                input: SavedCanvasDraft {
                    text: "Keep this unsent reply".into(),
                    ..Default::default()
                },
                ..Default::default()
            },
            ..Default::default()
        };
        settings.remember_closed_chat(chat.clone());
        settings.remember_closed_chat(SavedClosedChat {
            id: "unsent-one".into(),
            ..Default::default()
        });
        settings.remember_closed_chat(SavedClosedChat {
            id: "unsent-two".into(),
            ..Default::default()
        });
        chat.id = "close-again".into();
        chat.closed_at = 1235;
        settings.remember_closed_chat(chat.clone());
        assert_eq!(settings.recently_closed_chats.len(), 3);
        assert_eq!(settings.recently_closed_chats[0], chat);
        let dir = tempfile::tempdir().unwrap();
        settings.save(dir.path()).unwrap();
        let mut loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.recently_closed_chats, settings.recently_closed_chats);
        loaded.forget_closed_chat("chat-one");
        assert_eq!(loaded.recently_closed_chats.len(), 2);
        loaded.forget_closed_chat("unsent-one");
        assert_eq!(loaded.recently_closed_chats[0].id, "unsent-two");
    }

    #[test]
    fn closed_chat_repeated_closes_preserve_different_window_drafts() {
        let mut settings = UiSettings::default();
        let first = SavedClosedChat {
            id: "close-a".into(),
            chat_id: Some("same-chat".into()),
            window_id: "window-a".into(),
            closed_at: 1,
            draft: SavedWindowChatDraft {
                input: SavedCanvasDraft {
                    text: "Draft from window A".into(),
                    ..Default::default()
                },
                ..Default::default()
            },
            ..Default::default()
        };
        let mut second = first.clone();
        second.id = "close-b".into();
        second.window_id = "window-b".into();
        second.closed_at = 2;
        second.draft.input.text = "Draft from window B".into();
        settings.remember_closed_chat(first);
        settings.remember_closed_chat(second);
        assert_eq!(settings.recently_closed_chats.len(), 2);
        assert_eq!(
            settings.recently_closed_chats[0].chat_id.as_deref(),
            Some("same-chat")
        );
        assert_eq!(settings.recently_closed_chats[1].chat_id, None);
        assert_eq!(
            settings.recently_closed_chats[1].draft.input.text,
            "Draft from window A"
        );
        settings.forget_closed_chat("same-chat");
        assert_eq!(settings.recently_closed_chats.len(), 1);
        assert_eq!(
            settings.recently_closed_chats[0].draft.input.text,
            "Draft from window A"
        );
    }

    #[test]
    fn closed_chat_hide_and_exact_draft_discard_persist_without_accepting_stale_confirmation() {
        let mut settings = UiSettings::default();
        let original = SavedClosedChat {
            id: "draft-one".into(),
            draft: SavedWindowChatDraft {
                input: SavedCanvasDraft {
                    text: "Earlier input".into(),
                    ..Default::default()
                },
                ..Default::default()
            },
            ..Default::default()
        };
        settings.remember_closed_chat(original.clone());
        assert!(settings.hide_history_entry("draft:draft-one"));
        assert!(!settings.hide_history_entry("draft:draft-one"));
        assert!(!settings.hide_history_entry("draft:"));
        let mut current = original.clone();
        current.draft.input.text = "Newer input".into();
        settings.remember_closed_chat(current.clone());
        assert!(
            settings.hidden_history_entries.is_empty(),
            "a new close is visible again"
        );
        settings.hide_history_entry("draft:draft-one");
        settings.hide_history_entry("chat:keep");
        assert!(!settings.discard_closed_chat(&original));
        let mut wrong_id = current.clone();
        wrong_id.id = "different".into();
        assert!(!settings.discard_closed_chat(&wrong_id));
        let chat = SavedClosedChat {
            id: "saved-chat".into(),
            chat_id: Some("keep".into()),
            ..Default::default()
        };
        settings.remember_closed_chat(chat.clone());
        settings.hide_history_entry("chat:keep");
        assert!(
            !settings.discard_closed_chat(&chat),
            "saved chats require engine deletion"
        );
        let dir = tempfile::tempdir().unwrap();
        settings.save(dir.path()).unwrap();
        let mut loaded = UiSettings::load(dir.path());
        assert_eq!(
            loaded.hidden_history_entries,
            settings.hidden_history_entries
        );
        assert!(loaded.discard_closed_chat(&current));
        assert!(!loaded.discard_closed_chat(&current));
        assert_eq!(loaded.recently_closed_chats, vec![chat]);
        assert_eq!(loaded.hidden_history_entries, vec!["chat:keep"]);
        loaded.save(dir.path()).unwrap();
        assert_eq!(
            UiSettings::load(dir.path()).recently_closed_chats,
            loaded.recently_closed_chats
        );
    }

    #[test]
    fn existing_settings_keep_effective_interface_font_when_legacy_field_is_missing() {
        use crate::typography::UiFontFamily;
        let dir = tempfile::tempdir().unwrap();
        for (saved, expected) in [
            (
                serde_json::json!({"sidebarWidth": 288}),
                UiFontFamily::Geist,
            ),
            (
                serde_json::json!({"workspaceWindows": [], "sidebarWidth": 288}),
                UiFontFamily::System,
            ),
            (
                serde_json::json!({"projectTabsVersion": 2}),
                UiFontFamily::System,
            ),
            (
                serde_json::json!({"chatTabs": [{"id":"workspace-one"}]}),
                UiFontFamily::System,
            ),
            (
                serde_json::json!({"uiFontFamily":"geist", "workspaceWindows": []}),
                UiFontFamily::Geist,
            ),
            (
                serde_json::json!({"uiFontFamily":"system"}),
                UiFontFamily::System,
            ),
        ] {
            std::fs::write(UiSettings::path(dir.path()), saved.to_string()).unwrap();
            let restored = UiSettings::load(dir.path());
            assert_eq!(restored.ui_font_family, expected, "{saved}");
            restored.save(dir.path()).unwrap();
            assert_eq!(UiSettings::load(dir.path()).ui_font_family, expected);
        }
        let empty = tempfile::tempdir().unwrap();
        assert_eq!(
            UiSettings::load(empty.path()).ui_font_family,
            UiFontFamily::default()
        );
    }

    #[test]
    fn saved_draft_preserves_checkout_choice_and_attachment_annotations() {
        for checkout in ["local", "newWorktree"] {
            let saved = serde_json::json!({
                "git":{"branch":"feature/example", "checkout":checkout},
                "text":"Review the annotated draft",
                "attachments":[{"id":"attachment-one", "name":"example.png",
                    "cacheKey":"00000000-0000-4000-8000-000000000001", "image":true,
                    "annotations":"1. Keep this label."}]
            });
            let draft: SavedCanvasDraft = serde_json::from_value(saved.clone()).unwrap();
            let written = serde_json::to_value(draft).unwrap();
            assert_eq!(written["git"], saved["git"]);
            assert_eq!(written["attachments"], saved["attachments"]);
        }
        let legacy: SavedCanvasDraft = serde_json::from_value(serde_json::json!({
            "attachments":[{"id":"old", "name":"old.txt", "cacheKey":"old-key", "image":false}]
        }))
        .unwrap();
        assert!(legacy.git.is_none());
        assert!(legacy.attachments[0].annotations.is_none());
    }

    #[test]
    fn archive_sessions_on_close_defaults_off_and_persists() {
        assert!(!UiSettings::default().archive_sessions_on_close);
        let mut settings: UiSettings = serde_json::from_str("{}").unwrap();
        assert!(!settings.archive_sessions_on_close);
        let dir = tempfile::tempdir().unwrap();
        for enabled in [true, false] {
            settings.archive_sessions_on_close = enabled;
            settings.save(dir.path()).unwrap();
            assert_eq!(
                UiSettings::load(dir.path()).archive_sessions_on_close,
                enabled
            );

            // Earlier builds persisted the tab-only name. Load it, then write
            // only the canonical key so the preference survives migration.
            std::fs::write(
                UiSettings::path(dir.path()),
                serde_json::json!({ "archiveSessionsOnTabClose": enabled }).to_string(),
            )
            .unwrap();
            let migrated = UiSettings::load(dir.path());
            assert_eq!(migrated.archive_sessions_on_close, enabled);
            migrated.save(dir.path()).unwrap();
            let saved: serde_json::Value = serde_json::from_str(
                &std::fs::read_to_string(UiSettings::path(dir.path())).unwrap(),
            )
            .unwrap();
            assert_eq!(saved["archiveSessionsOnClose"], enabled);
            assert!(saved.get("archiveSessionsOnTabClose").is_none());
            assert_eq!(
                UiSettings::load(dir.path()).archive_sessions_on_close,
                enabled
            );
        }
    }

    #[test]
    fn archive_on_close_choice_persists_and_counts_an_enabled_setting() {
        assert!(!UiSettings::default().archive_on_close_chosen);
        let dir = tempfile::tempdir().unwrap();
        use serde_json::json;
        for (file, chosen) in [
            (json!({}), false),
            (json!({ "archiveSessionsOnClose": false }), false),
            // Already on before the question existed: never asked.
            (json!({ "archiveSessionsOnClose": true }), true),
            (json!({ "archiveSessionsOnTabClose": true }), true),
            (
                json!({ "archiveSessionsOnClose": false, "archiveOnCloseChosen": true }),
                true,
            ),
        ] {
            std::fs::write(UiSettings::path(dir.path()), file.to_string()).unwrap();
            let loaded = UiSettings::load(dir.path());
            assert_eq!(loaded.archive_on_close_chosen, chosen, "{file}");
            loaded.save(dir.path()).unwrap();
            let saved: serde_json::Value = serde_json::from_str(
                &std::fs::read_to_string(UiSettings::path(dir.path())).unwrap(),
            )
            .unwrap();
            assert_eq!(saved["archiveOnCloseChosen"], chosen, "{file}");
            assert_eq!(UiSettings::load(dir.path()).archive_on_close_chosen, chosen);
        }
    }

    #[test]
    fn slash_skills_are_opt_in_and_persist() {
        let old: UiSettings = serde_json::from_str("{}").unwrap();
        assert!(!old.skills_in_slash_menu);
        let dir = tempfile::tempdir().unwrap();
        let mut settings = old;
        settings.skills_in_slash_menu = true;
        settings.save(dir.path()).unwrap();
        assert!(UiSettings::load(dir.path()).skills_in_slash_menu);
    }

    #[test]
    fn composer_send_behavior_is_opt_in_for_old_and_partial_settings() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth": 300, "soundEnabled": false}"#,
        )
        .unwrap();

        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.composer_send_behavior, ComposerSendBehavior::Enter);
        assert!(loaded.open_web_links_in_harness);
        assert!(loaded.new_thread_composer_background.is_none());
        assert_eq!(
            loaded.new_thread_background_effect,
            NewThreadBackgroundEffect::None
        );
        assert_eq!(loaded.reduce_motion, crate::motion::ReduceMotion::System);
        assert!(!loaded.pause_animations_in_background);
        assert_eq!(loaded.sidebar_width, 300.0);
        assert!(!loaded.sound_enabled);
        for sound in [
            crate::sound::Sound::Done,
            crate::sound::Sound::Request,
            crate::sound::Sound::Attention,
        ] {
            assert!(!loaded.session_sound_enabled(sound));
        }
    }

    #[test]
    fn follow_up_behavior_defaults_ignores_obsolete_key_and_round_trips() {
        let missing: UiSettings = serde_json::from_str("{}").unwrap();
        assert_eq!(missing.follow_up_behavior, FollowUpBehavior::Queue);

        let obsolete: UiSettings =
            serde_json::from_str(r#"{"activeTurnSendBehavior":"steer"}"#).unwrap();
        assert_eq!(obsolete.follow_up_behavior, FollowUpBehavior::Queue);

        let dir = tempfile::tempdir().unwrap();
        for behavior in [FollowUpBehavior::Queue, FollowUpBehavior::Steer] {
            let mut settings = UiSettings::default();
            settings.follow_up_behavior = behavior;
            settings.save(dir.path()).unwrap();
            let persisted = std::fs::read_to_string(UiSettings::path(dir.path())).unwrap();
            assert!(persisted.contains(&format!(
                r#""followUpBehavior": "{}""#,
                match behavior {
                    FollowUpBehavior::Queue => "queue",
                    FollowUpBehavior::Steer => "steer",
                }
            )));
            assert_eq!(UiSettings::load(dir.path()).follow_up_behavior, behavior);
        }
    }

    #[test]
    fn window_geometry_round_trips_and_legacy_settings_default() {
        let dir = tempfile::tempdir().unwrap();
        let geometry = WindowGeometry {
            display_uuid: None,
            x: -1500.0,
            y: 40.0,
            width: 1200.0,
            height: 800.0,
        };
        let settings = UiSettings {
            window_geometry: Some(geometry),
            ..Default::default()
        };
        settings.save(dir.path()).unwrap();
        assert_eq!(UiSettings::load(dir.path()).window_geometry, Some(geometry));
        assert_eq!(WindowGeometry::from_bounds(geometry.bounds()), geometry);
        let legacy: UiSettings = serde_json::from_str(r#"{"sidebarWidth":300}"#).unwrap();
        assert_eq!(legacy.window_geometry, None);
        assert_eq!(legacy.sidebar_width, 300.0);
    }

    #[test]
    fn workspace_window_records_migrate_legacy_navigation_once() {
        let mut settings = UiSettings {
            last_chat_id: Some("conversation-a".into()),
            last_space_id: Some("project-a".into()),
            chat_tabs: vec![SavedChatTab {
                id: "session-a".into(),
                selected: Some("conversation-a".into()),
                ..Default::default()
            }],
            project_tabs_version: 2,
            ..Default::default()
        };
        let legacy = settings.restorable_workspace_windows();
        assert_eq!(legacy.len(), 1);
        assert_eq!(legacy[0].id, "main");
        assert_eq!(legacy[0].chat_tabs, settings.chat_tabs);
        assert_eq!(legacy[0].last_chat_id, settings.last_chat_id);
        assert_eq!(legacy[0].last_space_id, settings.last_space_id);
        settings.upsert_workspace_window(legacy[0].clone());
        settings.remove_workspace_window("main");
        assert_eq!(settings.workspace_windows, Some(Vec::new()));
        assert!(settings.restorable_workspace_windows().is_empty());
        let encoded = serde_json::to_string(&settings).unwrap();
        let reloaded: UiSettings = serde_json::from_str(&encoded).unwrap();
        assert!(reloaded.restorable_workspace_windows().is_empty());
    }

    #[test]
    fn workspace_window_records_round_trip_shared_session_with_independent_tabs() {
        let dir = tempfile::tempdir().unwrap();
        let mut settings = UiSettings::default();
        for (window, chat, x) in [("left", "chat-a", 40.0), ("right", "chat-b", 800.0)] {
            settings.upsert_workspace_window(SavedWorkspaceWindow {
                id: window.into(),
                geometry: Some(WindowGeometry {
                    display_uuid: Some(uuid::Uuid::from_u128(1)),
                    x,
                    y: 40.0,
                    width: 980.0,
                    height: 700.0,
                }),
                chat_tabs: vec![SavedChatTab {
                    id: "same-session".into(),
                    selected: Some(chat.into()),
                    ..Default::default()
                }],
                last_chat_id: Some(chat.into()),
                project_tabs_version: 2,
                ..Default::default()
            });
        }
        settings.save(dir.path()).unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.workspace_windows, settings.workspace_windows);
        let windows = loaded.restorable_workspace_windows();
        assert_eq!(windows.len(), 2);
        assert_eq!(windows[0].chat_tabs[0].id, windows[1].chat_tabs[0].id);
        assert_ne!(windows[0].last_chat_id, windows[1].last_chat_id);
        assert_ne!(windows[0].geometry, windows[1].geometry);
    }

    #[test]
    fn workspace_window_records_merge_interleaved_updates_and_close() {
        let mut settings = UiSettings::default();
        let mut left = SavedWorkspaceWindow {
            id: "left".into(),
            ..Default::default()
        };
        let mut right = SavedWorkspaceWindow {
            id: "right".into(),
            ..Default::default()
        };
        settings.upsert_workspace_window(left.clone());
        settings.upsert_workspace_window(right.clone());
        left.last_chat_id = Some("left-chat".into());
        settings.upsert_workspace_window(left.clone());
        right.last_chat_id = Some("right-chat".into());
        settings.upsert_workspace_window(right.clone());
        assert_eq!(
            settings.restorable_workspace_windows(),
            vec![left, right.clone()]
        );
        settings.remove_workspace_window("left");
        right.space_filter = Some("project-b".into());
        settings.upsert_workspace_window(right.clone());
        assert_eq!(settings.restorable_workspace_windows(), vec![right]);
    }

    #[test]
    fn workspace_window_record_overlay_preserves_preferences_and_other_windows() {
        let mut settings = UiSettings {
            sidebar_width: 310.0,
            sound_enabled: false,
            workspace_windows: Some(vec![SavedWorkspaceWindow {
                id: "other".into(),
                ..Default::default()
            }]),
            ..Default::default()
        };
        let windows = settings.workspace_windows.clone();
        let record = SavedWorkspaceWindow {
            id: "focused".into(),
            last_chat_id: Some("focused-chat".into()),
            space_filter: Some("focused-project".into()),
            ..Default::default()
        };
        record.apply_to_settings(&mut settings);
        assert_eq!(settings.last_chat_id, record.last_chat_id);
        assert_eq!(settings.space_filter, record.space_filter);
        assert_eq!(settings.workspace_windows, windows);
        assert_eq!(settings.sidebar_width, 310.0);
        assert!(!settings.sound_enabled);
    }

    #[test]
    fn workspace_window_records_heal_invalid_geometry_and_duplicate_window_ids() {
        let record = SavedWorkspaceWindow {
            id: "valid".into(),
            geometry: Some(WindowGeometry {
                display_uuid: None,
                x: f32::NAN,
                y: 0.0,
                width: 980.0,
                height: 700.0,
            }),
            chat_tab: usize::MAX,
            ..Default::default()
        };
        let settings = UiSettings {
            workspace_windows: Some(vec![
                record.clone(),
                record,
                SavedWorkspaceWindow::default(),
            ]),
            ..Default::default()
        }
        .clamped();
        let windows = settings.restorable_workspace_windows();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].geometry, None);
        assert_eq!(windows[0].chat_tab, 0);
    }

    #[test]
    fn window_geometry_restores_display_identity_with_overlapping_local_coordinates() {
        let primary = WindowGeometry {
            display_uuid: Some(uuid::Uuid::from_u128(1)),
            x: 0.0,
            y: 25.0,
            width: 1920.0,
            height: 1080.0,
        };
        let secondary = WindowGeometry {
            display_uuid: Some(uuid::Uuid::from_u128(2)),
            ..primary
        };
        let saved = WindowGeometry {
            x: 100.0,
            y: 80.0,
            width: 1200.0,
            height: 800.0,
            ..secondary
        };
        let encoded = serde_json::to_string(&saved).unwrap();
        let saved: WindowGeometry = serde_json::from_str(&encoded).unwrap();
        assert_eq!(saved.restore(&[primary, secondary], 0), Some((1, saved)));
        assert_eq!(saved.restore(&[secondary, primary], 1), Some((0, saved)));
    }

    #[test]
    fn window_geometry_recenters_when_saved_display_is_disconnected() {
        let primary = WindowGeometry {
            display_uuid: Some(uuid::Uuid::from_u128(1)),
            x: 0.0,
            y: 25.0,
            width: 1440.0,
            height: 900.0,
        };
        let saved = WindowGeometry {
            display_uuid: Some(uuid::Uuid::from_u128(2)),
            x: 500.0,
            y: 300.0,
            width: 1200.0,
            height: 800.0,
        };
        assert_eq!(
            saved.restore(&[primary], 0),
            Some((
                0,
                WindowGeometry {
                    display_uuid: primary.display_uuid,
                    x: 120.0,
                    y: 75.0,
                    ..saved
                }
            ))
        );
        assert_eq!(saved.restore(&[], 0), None);
        let oversized = WindowGeometry {
            width: 2400.0,
            height: 1600.0,
            ..saved
        };
        assert_eq!(oversized.restore(&[primary], 0), Some((0, primary)));
    }

    #[test]
    fn window_geometry_without_display_identity_uses_primary() {
        let saved: WindowGeometry =
            serde_json::from_str(r#"{"x":100,"y":80,"width":1200,"height":800}"#).unwrap();
        assert_eq!(saved.display_uuid, None);
        let display = WindowGeometry {
            display_uuid: Some(uuid::Uuid::from_u128(1)),
            x: 0.0,
            y: 25.0,
            width: 1920.0,
            height: 1080.0,
        };
        assert_eq!(
            saved.restore(&[display, display], 1),
            Some((
                1,
                WindowGeometry {
                    display_uuid: display.display_uuid,
                    ..saved
                }
            ))
        );
    }

    #[test]
    fn window_geometry_rejects_invalid_values_without_resetting_settings() {
        let valid = WindowGeometry {
            display_uuid: None,
            x: 40.0,
            y: 50.0,
            width: 1200.0,
            height: 800.0,
        };
        for geometry in [
            WindowGeometry {
                x: f32::NAN,
                ..valid
            },
            WindowGeometry {
                y: f32::INFINITY,
                ..valid
            },
            WindowGeometry {
                width: 0.0,
                ..valid
            },
            WindowGeometry {
                height: -1.0,
                ..valid
            },
        ] {
            let settings = UiSettings {
                window_geometry: Some(geometry),
                sidebar_width: 300.0,
                ..Default::default()
            }
            .clamped();
            assert_eq!(settings.window_geometry, None);
            assert_eq!(settings.sidebar_width, 300.0);
        }
    }

    #[test]
    fn window_geometry_preserves_position_on_negative_coordinate_display() {
        let display = WindowGeometry {
            display_uuid: None,
            x: -1920.0,
            y: -200.0,
            width: 1920.0,
            height: 1080.0,
        };
        let geometry = WindowGeometry {
            display_uuid: None,
            x: -1800.0,
            y: -100.0,
            width: 1200.0,
            height: 800.0,
        };
        assert_eq!(geometry.fit(display), geometry);
    }

    #[test]
    fn window_geometry_fits_smaller_display_and_keeps_titlebar_visible() {
        let display = WindowGeometry {
            display_uuid: None,
            x: 0.0,
            y: 25.0,
            width: 1280.0,
            height: 720.0,
        };
        let geometry = WindowGeometry {
            display_uuid: None,
            x: 2000.0,
            y: -1000.0,
            width: 2000.0,
            height: 1500.0,
        };
        assert_eq!(geometry.fit(display), display);
        let small = WindowGeometry {
            width: 800.0,
            height: 500.0,
            ..display
        };
        assert_eq!(geometry.fit(small), small);
        let tiny = WindowGeometry {
            width: 100.0,
            height: 100.0,
            ..display
        };
        assert_eq!(tiny.fit(display).width, 900.0);
        assert_eq!(tiny.fit(display).height, 600.0);
    }

    #[test]
    fn unknown_keys_from_a_newer_build_are_ignored() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth":300.0,"someFutureKey":"whatever","anotherOne":{"nested":1}}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.sidebar_width, 300.0);
        assert_eq!(
            loaded.terminal_font_family,
            crate::typography::UiFontFamily::GeistMono
        );
        assert_eq!(
            loaded.terminal_font_size,
            crate::typography::TERMINAL_FONT_SIZE_DEFAULT
        );
        assert_eq!(
            loaded.code_font_family,
            crate::typography::UiFontFamily::GeistMono
        );
        assert_eq!(
            loaded.code_font_size,
            crate::typography::CODE_FONT_SIZE_DEFAULT
        );
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn appshot_shortcut_defaults_round_trip_and_reset() {
        assert_eq!(
            ShortcutId::CaptureAppshot.default_combo_on(true),
            "ctrl-alt-space"
        );
        assert_eq!(
            ShortcutId::CaptureAppshot.default_combo_on(false),
            "mod-alt-space"
        );
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"keymap":{"newSession":"mod-shift-n"}}"#,
        )
        .unwrap();
        let mut settings = UiSettings::load(dir.path());
        assert_eq!(
            settings.keymap.capture_appshot,
            ShortcutId::CaptureAppshot.default_combo()
        );
        assert_eq!(settings.keymap.new_session, "mod-shift-n");
        settings
            .keymap
            .set(ShortcutId::CaptureAppshot, "mod-alt-k".into());
        std::fs::write(
            UiSettings::path(dir.path()),
            serde_json::to_vec(&settings).unwrap(),
        )
        .unwrap();
        let mut restored = UiSettings::load(dir.path());
        assert_eq!(restored.keymap.capture_appshot, "mod-alt-k");
        restored.keymap.reset(ShortcutId::CaptureAppshot);
        assert_eq!(
            restored.keymap.capture_appshot,
            ShortcutId::CaptureAppshot.default_combo()
        );
    }

    #[test]
    fn appshot_settings_are_serialized_only_on_desktop() {
        let value = serde_json::to_value(UiSettings::default()).unwrap();
        for key in [
            "appshotsEnabled",
            "appshotSoundEnabled",
            "appshotDestination",
        ] {
            assert_eq!(
                value.get(key).is_some(),
                crate::appshots::is_desktop(),
                "{key}"
            );
        }
        assert_eq!(
            value["keymap"].get("captureAppshot").is_some(),
            crate::appshots::is_desktop()
        );
    }

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn appshot_sound_migrates_mute_and_persists_independently() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(UiSettings::path(dir.path()), r#"{"soundEnabled":false}"#).unwrap();
        let mut loaded = UiSettings::load(dir.path());
        assert!(!loaded.appshot_sound_enabled);
        loaded.appshot_sound_enabled = true;
        std::fs::write(
            UiSettings::path(dir.path()),
            serde_json::to_vec(&loaded).unwrap(),
        )
        .unwrap();
        let restored = UiSettings::load(dir.path());
        assert!(restored.appshot_sound_enabled);
        assert!(!restored.sound_enabled);
    }

    #[test]
    fn background_cleanup_only_removes_files_owned_by_the_setting() {
        let dir = tempfile::tempdir().unwrap();
        let backgrounds = dir.path().join(NEW_THREAD_BACKGROUND_DIR);
        std::fs::create_dir(&backgrounds).unwrap();
        let managed = backgrounds.join("new-thread-background-owned.png");
        let unrelated = dir.path().join("keep.png");
        std::fs::write(&managed, b"managed").unwrap();
        std::fs::write(&unrelated, b"unrelated").unwrap();

        remove_managed_new_thread_background(
            Some(&NewThreadComposerBackground {
                path: unrelated.to_string_lossy().into_owned(),
                name: "keep.png".into(),
            }),
            &backgrounds,
        );
        assert!(unrelated.exists());
        remove_managed_new_thread_background(
            Some(&NewThreadComposerBackground {
                path: managed.to_string_lossy().into_owned(),
                name: "owned.png".into(),
            }),
            &backgrounds,
        );
        assert!(!managed.exists());
    }

    #[gpui::test]
    fn invalid_background_replacement_preserves_previous_image_and_settings(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let original = dir.path().join("original.png");
        image::RgbaImage::from_pixel(8, 8, image::Rgba([20, 100, 200, 255]))
            .save(&original)
            .unwrap();
        cx.update(|cx| {
            init(UiSettings::default(), dir.path(), cx);
            install_new_thread_composer_background(&original, cx).unwrap();
            let before = current(cx);
            let previous = PathBuf::from(&before.new_thread_composer_background.as_ref().unwrap().path);
            let saved = std::fs::read(UiSettings::path(dir.path())).unwrap();
            let previous_bytes = std::fs::read(&previous).unwrap();
            for (name, bytes) in [
                ("replacement.svg", br#"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>"#.as_slice()),
                ("corrupt.png", b"not a PNG".as_slice()),
                ("truncated.png", &previous_bytes[..previous_bytes.len() / 2]),
            ] {
                let candidate = dir.path().join(name);
                std::fs::write(&candidate, bytes).unwrap();
                let result = install_new_thread_composer_background(&candidate, cx);
                assert!(result.is_err(), "accepted invalid replacement: {name}");
                assert_eq!(current(cx), before);
                assert_eq!(std::fs::read(UiSettings::path(dir.path())).unwrap(), saved);
                assert_eq!(std::fs::read(&previous).unwrap(), previous_bytes);
                assert_eq!(std::fs::read_dir(dir.path().join(NEW_THREAD_BACKGROUND_DIR)).unwrap().count(), 1);
                assert!(candidate.exists(), "source files must never be deleted");
            }
        });
    }

    #[gpui::test]
    fn valid_background_replacement_persists_renderable_image_before_retiring_previous(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let first = dir.path().join("first.png");
        let second = dir.path().join("second.jpg");
        image::RgbaImage::from_pixel(8, 8, image::Rgba([20, 100, 200, 255]))
            .save(&first)
            .unwrap();
        image::RgbImage::from_pixel(12, 10, image::Rgb([200, 100, 20]))
            .save(&second)
            .unwrap();
        cx.update(|cx| {
            let initial = UiSettings {
                sidebar_organization: SidebarOrganization::InOneList,
                new_thread_background_effect: NewThreadBackgroundEffect::Ascii,
                ..Default::default()
            };
            init(initial, dir.path(), cx);
            install_new_thread_composer_background(&first, cx).unwrap();
            let old_path = current(cx).new_thread_composer_background.unwrap().path;
            let mut external = UiSettings::load(dir.path());
            external.sidebar_organization = SidebarOrganization::ByProject;
            external.save(dir.path()).unwrap();
            install_new_thread_composer_background(&second, cx).unwrap();
            let settings = current(cx);
            let replacement = settings.new_thread_composer_background.as_ref().unwrap();
            assert_ne!(replacement.path, old_path);
            assert_eq!(
                settings.sidebar_organization,
                SidebarOrganization::ByProject
            );
            let saved_image = std::fs::read(&replacement.path).unwrap();
            assert_eq!(saved_image, std::fs::read(&second).unwrap());
            let decoded = crate::new_thread_background_image::decode(&saved_image).unwrap();
            assert_eq!((decoded.width(), decoded.height()), (12, 10));
            assert_eq!(UiSettings::load(dir.path()), settings);
            assert_eq!(
                settings.new_thread_background_effect,
                NewThreadBackgroundEffect::Ascii
            );
            assert!(!Path::new(&old_path).exists());
            assert!(first.exists() && second.exists());
            assert_eq!(
                std::fs::read_dir(dir.path().join(NEW_THREAD_BACKGROUND_DIR))
                    .unwrap()
                    .count(),
                1
            );
            let mut external = settings.clone();
            external.sidebar_organization = SidebarOrganization::ByDevice;
            external.save(dir.path()).unwrap();
            remove_new_thread_composer_background(cx).unwrap();
            assert_eq!(
                current(cx).sidebar_organization,
                SidebarOrganization::ByDevice
            );
            assert!(current(cx).new_thread_composer_background.is_none());
            assert_eq!(UiSettings::load(dir.path()), current(cx));
            assert!(!Path::new(&replacement.path).exists());
        });
    }

    #[gpui::test]
    fn background_commit_failure_preserves_previous_pointer_and_image(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let image = dir.path().join("synthetic.png");
        image::RgbaImage::from_pixel(8, 8, image::Rgba([20, 100, 200, 255]))
            .save(&image)
            .unwrap();
        cx.update(|cx| {
            init(UiSettings::default(), dir.path(), cx);
            install_new_thread_composer_background(&image, cx).unwrap();
            let before = current(cx);
            let path = UiSettings::path(dir.path());
            let saved = std::fs::read(&path).unwrap();
            let previous = &before.new_thread_composer_background.as_ref().unwrap().path;
            let temporary = path.with_extension("json.tmp");
            std::fs::create_dir(&temporary).unwrap();
            assert!(install_new_thread_composer_background(&image, cx).is_err());
            assert!(remove_new_thread_composer_background(cx).is_err());
            assert_eq!(current(cx), before);
            assert_eq!(cx.global::<SettingsStore>().baseline, before);
            assert_eq!(std::fs::read(&path).unwrap(), saved);
            assert!(Path::new(previous).exists());
            assert_eq!(
                std::fs::read_dir(dir.path().join(NEW_THREAD_BACKGROUND_DIR))
                    .unwrap()
                    .count(),
                1
            );
            std::fs::remove_dir(&temporary).unwrap();
        });
    }

    #[gpui::test]
    fn invalid_initial_background_import_does_not_create_managed_files_or_settings(
        cx: &mut gpui::TestAppContext,
    ) {
        let dir = tempfile::tempdir().unwrap();
        let candidate = dir.path().join("corrupt.png");
        std::fs::write(&candidate, b"not a PNG").unwrap();
        cx.update(|cx| {
            init(UiSettings::default(), dir.path(), cx);
            assert!(install_new_thread_composer_background(&candidate, cx).is_err());
            assert!(current(cx).new_thread_composer_background.is_none());
            assert!(!dir.path().join(NEW_THREAD_BACKGROUND_DIR).exists());
            assert!(!UiSettings::path(dir.path()).exists());
            assert!(candidate.exists());
        });
    }

    #[test]
    fn obsolete_steering_preference_does_not_reset_other_settings() {
        let loaded: UiSettings = serde_json::from_str(
            r#"{"activeTurnSendBehavior":"steer","sidebarWidth":300,"soundEnabled":false}"#,
        )
        .unwrap();
        assert_eq!(loaded.sidebar_width, 300.0);
        assert!(!loaded.sound_enabled);
        assert!(
            serde_json::to_value(&loaded)
                .unwrap()
                .get("activeTurnSendBehavior")
                .is_none()
        );
    }

    #[test]
    fn round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let settings = UiSettings {
            window_geometry: None,
            workspace_windows: None,
            recently_closed_chats: Vec::new(),
            hidden_history_entries: Vec::new(),
            sidebar_width: 300.0,
            sidebar_collapsed: true,
            sidebar_grouped: true,
            sidebar_organization: SidebarOrganization::ByDevice,
            sidebar_sort: SidebarSort::Created,
            sidebar_compact: false,
            sidebar_show_project_icon: false,
            sidebar_show_project_label: false,
            sidebar_show_harness: false,
            sidebar_show_branch: false,
            sidebar_show_archived: false,
            sidebar_show_updated: true,
            last_space_id: Some("space-1".into()),
            project_folders_by_device: HashMap::from([(
                "local".into(),
                project_folders::ProjectFolderPreference {
                    override_path: Some("~/Projects".into()),
                    parent_counts: HashMap::from([("/projects".into(), 3)]),
                },
            )]),
            last_project_action_by_space_id: std::collections::HashMap::from([(
                "space-1".into(),
                "dev".into(),
            )]),
            open_tabs: Some(vec!["b".to_string(), "a".to_string()]),
            space_filter: Some("space-1".into()),
            sidebar_all_projects: true,
            sidebar_task_view: true,
            last_chat_id: Some("b".into()),
            chat_layout: Some(SavedChatLayout {
                vertical: false,
                panes: vec![Some("a".into()), None],
                focus: 1,
                shares: vec![0.4, 0.6],
                projects: vec![Some("space-1".into()), None],
            }),
            archive_sessions_on_close: true,
            archive_on_close_chosen: true,
            settings_section: Some("appearance".into()),
            chat_tabs: vec![
                SavedChatTab {
                    selected: Some("a".into()),
                    project: Some("space-1".into()),
                    layout: None,
                    ..Default::default()
                },
                SavedChatTab::default(),
            ],
            chat_tab: 1,
            project_tabs_version: 1,
            session_overview_order: vec![None, Some("space-1".into())],
            sidebar_pinned_session_ids_by_profile: HashMap::from([
                (
                    "local".to_string(),
                    vec!["local-2".to_string(), "local-1".to_string()],
                ),
                (
                    "synced:org-1:user-1".to_string(),
                    vec!["synced-1".to_string()],
                ),
            ]),
            tab_order: std::collections::HashMap::from([(
                "space-1".to_string(),
                vec!["b".to_string(), "a".to_string()],
            )]),
            space_order: vec!["space-2".to_string(), "space-1".to_string()],
            sound_enabled: false,
            sound_completion_enabled: false,
            sound_input_enabled: true,
            sound_attention_enabled: false,
            attach_sound_enabled: false,
            notifications_enabled: false,
            notifications_background_only: false,
            share_performance_stats: false,
            files_panel_width: 310.0,
            right_pane_width: 700.0,
            right_pane_open: true,
            terminal_height: 320.0,
            terminal_open: true,
            keymap: KeymapConfig {
                toggle_sidebar: "mod-shift-s".into(),
                ..KeymapConfig::default()
            },
            escape_stops_active_agent: true,
            composer_send_behavior: ComposerSendBehavior::ModEnter,
            follow_up_behavior: FollowUpBehavior::Steer,
            skills_in_slash_menu: true,
            skill_completion_by_harness: Default::default(),
            appshots_enabled: false,
            appshot_sound_enabled: true,
            // The destination is only persisted where Appshots exist (macOS and
            // Linux); elsewhere the field is `serde(skip)` and reloads as the
            // default, so the round trip must expect exactly that.
            appshot_destination: if cfg!(any(target_os = "macos", target_os = "linux")) {
                crate::appshots::AppshotDestination::NewSession
            } else {
                crate::appshots::AppshotDestination::Automatic
            },
            appearance: crate::appearance::AppearanceMode::Light,
            git_history_columns: GitHistoryColumns {
                author: false,
                date: true,
                sha: false,
            },
            git_history_column_widths: GitHistoryColumnWidths {
                author: 132.0,
                date: 104.0,
                sha: 82.0,
            },
            git_history_column_order: GitHistoryColumnOrder(vec![
                GitHistoryColumn::Sha,
                GitHistoryColumn::Author,
                GitHistoryColumn::Date,
            ]),
            git_history_author_display: GitHistoryAuthorDisplay::Name,
            ui_font_family: crate::typography::UiFontFamily::Installed("Arial".into()),
            ui_font_size: crate::typography::UiFontSize::ALL[5],
            theme_selection: harness_theme::ThemeSelection {
                light: "catppuccin-latte".into(),
                dark: "catppuccin-mocha".into(),
            },
            diff_split: true,
            diff_wrap: true,
            diff_ignore_whitespace: true,
            code_fences_fit_content: true,
            transcript_width: 960.0,
            open_web_links_in_harness: false,
            transcript_compact_mode: true,
            transcript_compact_default_applied: true,
            write_sans: true,
            files_autosave_enabled: true,
            files_autosave_delay_ms: 1_500,
            files_word_wrap: true,
            terminal_font_family: crate::typography::UiFontFamily::Installed("Menlo".into()),
            terminal_font_size: 15.0,
            code_font_family: crate::typography::UiFontFamily::Geist,
            code_font_size: 11.0,
            files_show_all: true,
            accent: harness_theme::AccentSelection::Preset(harness_theme::AccentPreset::Cyan),
            surface: harness_theme::SurfacePreference::Frosted,
            new_thread_composer_background: Some(NewThreadComposerBackground {
                path: "/tmp/harness/new-thread-background.png".into(),
                name: "background.png".into(),
            }),
            new_thread_background_effect: NewThreadBackgroundEffect::Ascii,
            reduce_motion: crate::motion::ReduceMotion::On,
            pause_animations_in_background: true,
            graff_notice_dismissed: Some("0.0.9".into()),
            restart_to_install_updates: false,
            legacy_accent_color: None,
        };
        settings.save(dir.path()).unwrap();
        let json = std::fs::read_to_string(UiSettings::path(dir.path())).unwrap();
        assert!(json.contains(r#""diffWrap": true"#));
        assert_eq!(UiSettings::load(dir.path()), settings);
        assert!(json.contains(r#""codeFencesFitContent": true"#));
        assert!(json.contains(r#""openWebLinksInHarness": false"#));
        assert!(json.contains(r#""newThreadBackgroundEffect": "ascii""#));
        assert!(json.contains(r#""reduceMotion": "on""#));
        assert!(json.contains(r#""pauseAnimationsInBackground": true"#));
        assert!(json.contains(r#""terminalFontFamily": "installed:Menlo""#));
        assert!(json.contains(r#""terminalFontSize": 15.0"#));
        assert!(json.contains(r#""codeFontFamily": "geist""#));
        assert!(json.contains(r#""codeFontSize": 11.0"#));
        assert!(json.contains(r#""restartToInstallUpdates": false"#));
    }

    #[test]
    fn restart_to_install_updates_defaults_on_and_round_trips() {
        let legacy: UiSettings = serde_json::from_str("{}").unwrap();
        assert!(legacy.restart_to_install_updates);
        let off: UiSettings =
            serde_json::from_str(r#"{"restartToInstallUpdates": false}"#).unwrap();
        assert!(!off.restart_to_install_updates);
        let dir = tempfile::tempdir().unwrap();
        off.save(dir.path()).unwrap();
        assert!(!UiSettings::load(dir.path()).restart_to_install_updates);
    }

    #[test]
    fn stale_revision_cannot_be_considered_the_latest_save() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = SettingsStore {
            current: UiSettings::default(),
            baseline: UiSettings::default(),
            data_dir: dir.path().to_path_buf(),
            revision: 0,
            saved_revision: 0,
            code_fences_generation: 0,
            save_task: None,
        };

        store.current.sidebar_width = 300.0;
        store.revision += 1;
        let (stale, stale_revision) = store.snapshot();

        store.current.ui_font_family = crate::typography::UiFontFamily::Installed("Arial".into());
        store.revision += 1;
        stale.save(dir.path()).unwrap();
        assert!(!store.mark_saved(stale_revision));

        let (latest, latest_revision) = store.snapshot();
        latest.save(dir.path()).unwrap();
        assert!(store.mark_saved(latest_revision));
        let reloaded = UiSettings::load(dir.path());
        assert_eq!(reloaded.sidebar_width, 300.0);
        assert_eq!(
            reloaded.ui_font_family,
            crate::typography::UiFontFamily::Installed("Arial".into())
        );
    }

    #[test]
    fn transcript_width_loads_legacy_defaults_and_normalizes_persisted_values() {
        let legacy: UiSettings = serde_json::from_str("{}").unwrap();
        assert_eq!(legacy.transcript_width, 736.0);
        for (value, expected) in [
            (100.0, 560.0),
            (2000.0, 1200.0),
            (745.0, 752.0),
            (f32::NAN, 736.0),
        ] {
            let settings = UiSettings {
                transcript_width: value,
                ..Default::default()
            }
            .clamped();
            assert_eq!(settings.transcript_width, expected);
        }
        let dir = tempfile::tempdir().unwrap();
        let settings = UiSettings {
            transcript_width: 1024.0,
            ..Default::default()
        };
        settings.save(dir.path()).unwrap();
        assert_eq!(UiSettings::load(dir.path()).transcript_width, 1024.0);
    }

    #[test]
    fn code_fence_generation_tracks_every_mode_transition_only() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = SettingsStore {
            current: UiSettings::default(),
            baseline: UiSettings::default(),
            data_dir: dir.path().to_path_buf(),
            revision: 0,
            saved_revision: 0,
            code_fences_generation: 0,
            save_task: None,
        };

        assert!(store.update_current(|settings| settings.sidebar_width = 300.0));
        assert_eq!(store.code_fences_generation, 0);

        assert!(store.update_current(|settings| settings.code_fences_fit_content = true));
        assert_eq!(store.code_fences_generation, 1);
        assert!(store.update_current(|settings| settings.code_fences_fit_content = false));
        assert_eq!(store.code_fences_generation, 2);

        assert!(!store.update_current(|settings| settings.code_fences_fit_content = false));
        assert_eq!(store.code_fences_generation, 2);
    }

    #[test]
    fn sidebar_display_defaults_and_preferences_round_trip() {
        let settings: UiSettings = serde_json::from_str("{}").unwrap();
        assert!(settings.sidebar_compact);
        assert!(!settings.sidebar_show_project_icon);
        assert!(!settings.sidebar_show_project_label);
        assert!(settings.sidebar_show_harness);
        assert!(settings.sidebar_show_branch);
        assert!(settings.sidebar_show_updated);
        assert!(settings.sidebar_show_archived);
        let customized = UiSettings {
            sidebar_compact: false,
            sidebar_show_archived: false,
            sidebar_show_project_icon: true,
            sidebar_show_project_label: true,
            sidebar_show_harness: false,
            sidebar_show_branch: false,
            sidebar_show_updated: false,
            sidebar_organization: SidebarOrganization::ByProject,
            ..settings
        };
        let restored: UiSettings =
            serde_json::from_str(&serde_json::to_string(&customized).unwrap()).unwrap();
        assert_eq!(restored.clamped(), customized);
    }

    #[test]
    fn sidebar_simple_reset_preserves_organization_and_legacy_preferences_load() {
        let mut settings: UiSettings = serde_json::from_str(
            r#"{"sidebarShowHarness":true,"sidebarShowBranch":true,"sidebarShowProjectIcon":true,"sidebarShowProjectLabel":true,"sidebarCompact":false,"sidebarWidth":300,"sidebarOrganization":"byProject","sidebarSort":"created"}"#,
        ).unwrap();
        assert!(!settings.sidebar_compact);
        assert!(settings.sidebar_show_harness && settings.sidebar_show_branch);
        assert!(settings.sidebar_show_project_icon && settings.sidebar_show_project_label);
        assert_eq!(
            serde_json::to_value(&settings).unwrap()["sidebarCompact"],
            false
        );
        settings.sidebar_show_harness = false;
        settings.sidebar_show_branch = false;
        settings.sidebar_show_updated = false;
        settings.reset_sidebar_display();
        assert!(settings.sidebar_compact);
        assert!(settings.sidebar_show_harness && settings.sidebar_show_branch);
        assert!(!settings.sidebar_show_project_icon && !settings.sidebar_show_project_label);
        assert!(settings.sidebar_show_updated);
        assert_eq!(settings.sidebar_width, 300.0);
        assert_eq!(
            settings.sidebar_organization,
            SidebarOrganization::ByProject
        );
        assert_eq!(settings.sidebar_sort, SidebarSort::Created);
    }

    #[test]
    fn sidebar_compact_preserves_explicit_visibility_preferences() {
        for compact in [false, true] {
            let settings: UiSettings = serde_json::from_value(serde_json::json!({
                "sidebarCompact": compact,
                "sidebarShowHarness": false,
                "sidebarShowBranch": false,
                "sidebarShowUpdated": false,
            }))
            .unwrap();
            assert_eq!(settings.sidebar_compact, compact);
            assert!(!settings.sidebar_show_harness);
            assert!(!settings.sidebar_show_branch);
            assert!(!settings.sidebar_show_updated);
            let saved = serde_json::to_value(settings).unwrap();
            assert_eq!(saved["sidebarCompact"], compact);
        }
    }

    #[test]
    fn project_organization_survives_loading() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarOrganization":"byProject"}"#,
        )
        .unwrap();

        assert_eq!(
            UiSettings::load(dir.path()).sidebar_organization,
            SidebarOrganization::ByProject
        );
    }

    /// A settings file written before light mode existed has no `appearance`
    /// key; it must load as "follow the OS" rather than failing the whole parse
    /// and resetting every other preference to defaults.
    #[test]
    fn settings_without_appearance_default_to_system() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth": 300, "soundEnabled": false}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.appearance, crate::appearance::AppearanceMode::System);
        assert_eq!(loaded.accent, harness_theme::AccentSelection::ThemeDefault);
        assert_eq!(loaded.surface, harness_theme::SurfacePreference::ThemeDefault);
        assert_eq!(loaded.sidebar_width, 300.0);
        assert!(loaded.sidebar_pinned_session_ids_by_profile.is_empty());
        assert!(!loaded.sound_enabled, "other keys still parse");
        assert!(loaded.sound_completion_enabled);
        assert!(loaded.sound_input_enabled);
        assert!(loaded.sound_attention_enabled);
        assert!(
            loaded.attach_sound_enabled,
            "older settings default the attachment cue on"
        );
        assert_eq!(
            loaded.files_autosave_delay_ms,
            FILES_AUTOSAVE_DELAY_DEFAULT_MS
        );
        assert!(!loaded.files_autosave_enabled);
        assert!(!loaded.files_word_wrap);
        assert_eq!(
            loaded.code_font_size,
            crate::typography::CODE_FONT_SIZE_DEFAULT
        );
        assert_eq!(
            loaded.terminal_font_size,
            crate::typography::TERMINAL_FONT_SIZE_DEFAULT
        );
        assert!(!loaded.files_show_all);
        assert!(
            loaded.notifications_enabled,
            "pre-banner files default banners on"
        );
        assert!(
            loaded.share_performance_stats,
            "pre-stats files default sharing on"
        );
        assert!(
            loaded.notifications_background_only,
            "pre-banner files default background-only on"
        );
        assert!(
            !loaded.escape_stops_active_agent,
            "preference files default Escape stopping off"
        );
        assert_eq!(
            loaded.git_history_columns,
            GitHistoryColumns::default(),
            "pre-column files show the complete History table"
        );
        assert_eq!(
            loaded.git_history_column_widths,
            GitHistoryColumnWidths::default(),
            "pre-resize files use the original History column widths"
        );
        assert_eq!(
            loaded.git_history_column_order,
            GitHistoryColumnOrder::default(),
            "pre-reorder files use the original History column order"
        );
        assert_eq!(
            loaded.git_history_author_display,
            GitHistoryAuthorDisplay::Avatar,
            "pre-author-display files default to avatars"
        );
    }

    #[test]
    fn session_sound_preferences_round_trip_and_gate_each_event() {
        let settings = UiSettings {
            sound_enabled: true,
            sound_completion_enabled: false,
            sound_input_enabled: true,
            sound_attention_enabled: false,
            ..Default::default()
        };
        assert!(!settings.session_sound_enabled(crate::sound::Sound::Done));
        assert!(settings.session_sound_enabled(crate::sound::Sound::Request));
        assert!(!settings.session_sound_enabled(crate::sound::Sound::Attention));

        let value = serde_json::to_value(&settings).unwrap();
        let restored: UiSettings = serde_json::from_value(value).unwrap();
        assert_eq!(restored, settings);

        let muted = UiSettings {
            sound_enabled: false,
            ..settings
        };
        assert!(!muted.session_sound_enabled(crate::sound::Sound::Request));
    }

    #[test]
    fn attachment_sound_defaults_on_and_retains_an_explicit_opt_out() {
        let settings: UiSettings = serde_json::from_str("{}").unwrap();
        assert!(settings.attach_sound_enabled);
        let mut settings = settings;
        settings.attach_sound_enabled = false;
        let restored: UiSettings =
            serde_json::from_value(serde_json::to_value(&settings).unwrap()).unwrap();
        assert!(!restored.attach_sound_enabled);
    }

    #[test]
    fn legacy_accent_color_migrates_to_an_explicit_preset() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(UiSettings::path(dir.path()), r#"{"accentColor":"cyan"}"#).unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(
            loaded.accent,
            harness_theme::AccentSelection::Preset(harness_theme::AccentPreset::Cyan)
        );
        loaded.save(dir.path()).unwrap();
        let saved = std::fs::read_to_string(UiSettings::path(dir.path())).unwrap();
        assert!(!saved.contains("accentColor"));
    }

    #[test]
    fn legacy_upstream_settings_without_ui_font_keep_geist() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth": 300, "soundEnabled": false}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(
            loaded.ui_font_family,
            crate::typography::UiFontFamily::Geist
        );
        assert_eq!(loaded.sidebar_width, 300.0);
        assert!(!loaded.sound_enabled);
        assert!(!loaded.diff_wrap);
        assert_eq!(
            loaded.ui_font_size,
            crate::typography::UiFontSize::default()
        );

        // An explicit choice of the previous default remains a user choice.
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"uiFontFamily": "geist", "sidebarWidth": 300}"#,
        )
        .unwrap();
        let explicit = UiSettings::load(dir.path());
        assert_eq!(
            explicit.ui_font_family,
            crate::typography::UiFontFamily::Geist
        );
        assert_eq!(explicit.sidebar_width, 300.0);
    }

    #[test]
    fn unsupported_ui_font_size_snaps_to_the_nearest_choice() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"uiFontSize": 19, "soundEnabled": false}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.ui_font_size.pixels(), 18.0);
        assert!(!loaded.sound_enabled);
    }

    #[test]
    fn unknown_ui_font_falls_back_without_resetting_settings() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth": 300, "uiFontFamily": "futureSans"}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(
            loaded.ui_font_family,
            crate::typography::UiFontFamily::default()
        );
        assert_eq!(loaded.sidebar_width, 300.0);
    }

    #[test]
    fn missing_and_corrupt_files_yield_defaults() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(UiSettings::load(dir.path()), UiSettings::default());
        std::fs::write(UiSettings::path(dir.path()), "{not json").unwrap();
        assert_eq!(UiSettings::load(dir.path()), UiSettings::default());
    }

    #[test]
    fn compact_mode_turns_on_once_for_existing_files_then_keeps_the_choice() {
        let dir = tempfile::tempdir().unwrap();
        // Written before compact mode was the default, with it off.
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"transcriptCompactMode":false,"sidebarWidth":300}"#,
        )
        .unwrap();
        let mut loaded = UiSettings::load(dir.path());
        assert!(loaded.transcript_compact_mode);
        assert!(loaded.transcript_compact_default_applied);
        assert_eq!(loaded.sidebar_width, 300.0);
        // Turned off again after that: it stays off.
        loaded.transcript_compact_mode = false;
        loaded.save(dir.path()).unwrap();
        assert!(!UiSettings::load(dir.path()).transcript_compact_mode);
        // Harness Nano writes single keys; its marker counts the same.
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"transcriptCompactMode":false,"transcriptCompactDefaultApplied":true}"#,
        )
        .unwrap();
        assert!(!UiSettings::load(dir.path()).transcript_compact_mode);
    }

    fn signed_in(user_id: &str, org_id: Option<&str>) -> AuthState {
        AuthState::SignedIn {
            user: harness_proto::UserProfile {
                id: user_id.to_string(),
                email: format!("{user_id}@example.com"),
                name: None,
            },
            org_id: org_id.map(str::to_string),
        }
    }

    #[test]
    fn sidebar_pin_profile_keys_include_the_full_workspace_identity() {
        assert_eq!(
            sidebar_pin_profile_key(Some(WorkspaceScope::Local), None, None).as_deref(),
            Some("local")
        );
        assert_eq!(
            sidebar_pin_profile_key(
                Some(WorkspaceScope::Synced),
                Some(&signed_in("user-1", Some("org-1"))),
                None,
            )
            .as_deref(),
            Some("synced:org-1:user-1")
        );
        assert_eq!(
            sidebar_pin_profile_key(
                Some(WorkspaceScope::Development),
                Some(&signed_in("dev-user@dev-org-2", None)),
                Some("ignored-org"),
            )
            .as_deref(),
            Some("development:dev-org-2:dev-user")
        );
        assert_eq!(
            sidebar_pin_profile_key(
                Some(WorkspaceScope::Development),
                Some(&signed_in("dev-user", None)),
                Some("configured-org"),
            )
            .as_deref(),
            Some("development:configured-org:dev-user")
        );
    }

    #[test]
    fn sidebar_pin_profile_key_waits_for_a_complete_remote_identity() {
        assert_eq!(
            sidebar_pin_profile_key(Some(WorkspaceScope::Synced), None, None),
            None
        );
        assert_eq!(
            sidebar_pin_profile_key(
                Some(WorkspaceScope::Synced),
                Some(&signed_in("user-1", None)),
                None,
            ),
            None
        );
        assert_eq!(
            sidebar_pin_profile_key(Some(WorkspaceScope::Development), None, None),
            None
        );
    }

    #[test]
    fn local_synced_local_switch_restores_each_profiles_pins() {
        let mut settings = UiSettings::default();
        settings
            .sidebar_pins_mut("local".to_string())
            .extend(["local-1".to_string(), "local-2".to_string()]);
        settings
            .sidebar_pins_mut("synced:org-1:user-1".to_string())
            .push("synced-1".to_string());

        assert_eq!(settings.sidebar_pins("local"), ["local-1", "local-2"]);
        assert_eq!(settings.sidebar_pins("synced:org-1:user-1"), ["synced-1"]);
        assert_eq!(settings.sidebar_pins("local"), ["local-1", "local-2"]);
    }

    #[test]
    fn account_switch_restores_each_accounts_pins() {
        let mut settings = UiSettings::default();
        settings
            .sidebar_pins_mut("synced:org-a:user-a".to_string())
            .push("a-1".to_string());
        settings
            .sidebar_pins_mut("synced:org-b:user-b".to_string())
            .push("b-1".to_string());

        assert_eq!(settings.sidebar_pins("synced:org-a:user-a"), ["a-1"]);
        assert_eq!(settings.sidebar_pins("synced:org-b:user-b"), ["b-1"]);
        assert_eq!(settings.sidebar_pins("synced:org-a:user-a"), ["a-1"]);
    }

    #[test]
    fn files_panel_width_defaults_roundtrips_and_clamps() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(UiSettings::path(dir.path()), r#"{"sidebarWidth":256}"#).unwrap();
        assert_eq!(
            UiSettings::load(dir.path()).files_panel_width,
            FILES_PANEL_DEFAULT
        );
        for (value, expected) in [
            (310.0, 310.0),
            (1.0, FILES_PANEL_MIN),
            (900.0, FILES_PANEL_MAX),
            (f32::NAN, FILES_PANEL_DEFAULT),
        ] {
            let settings = UiSettings {
                files_panel_width: value,
                ..Default::default()
            }
            .clamped();
            assert_eq!(settings.files_panel_width, expected);
            let encoded = serde_json::to_string(&settings).unwrap();
            let decoded: UiSettings = serde_json::from_str(&encoded).unwrap();
            assert_eq!(decoded.files_panel_width, expected);
        }
    }

    #[test]
    fn loaded_values_are_clamped() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth": 10000, "rightPaneWidth": 1}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.sidebar_width, SIDEBAR_MAX);
        assert_eq!(loaded.right_pane_width, RIGHT_PANE_MIN);
        assert!(!loaded.code_fences_fit_content);
        assert_eq!(
            UiSettings {
                sidebar_width: 1.0,
                ..Default::default()
            }
            .clamped()
            .sidebar_width,
            SIDEBAR_MIN
        );
        assert_eq!(
            UiSettings {
                files_autosave_delay_ms: 1,
                ..Default::default()
            }
            .clamped()
            .files_autosave_delay_ms,
            FILES_AUTOSAVE_DELAY_MIN_MS
        );
        assert_eq!(
            UiSettings {
                code_font_size: 100.0,
                ..Default::default()
            }
            .clamped()
            .code_font_size,
            crate::typography::FONT_SIZE_MAX
        );
        assert_eq!(
            UiSettings {
                terminal_font_size: 1.0,
                ..Default::default()
            }
            .clamped()
            .terminal_font_size,
            crate::typography::FONT_SIZE_MIN
        );
        assert_eq!(
            UiSettings {
                code_font_size: f32::NAN,
                ..Default::default()
            }
            .clamped()
            .code_font_size,
            crate::typography::CODE_FONT_SIZE_DEFAULT
        );
    }

    #[test]
    fn legacy_files_editor_font_size_becomes_the_code_font_size() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"filesEditorFontSize": 15.0}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.code_font_size, 15.0);
        assert_eq!(
            loaded.terminal_font_size,
            crate::typography::TERMINAL_FONT_SIZE_DEFAULT
        );
    }

    #[test]
    fn git_history_column_widths_are_clamped_and_nan_heals() {
        let widths = GitHistoryColumnWidths {
            author: 10_000.0,
            date: f32::NAN,
            sha: 1.0,
        }
        .clamped();
        assert_eq!(widths.author, GitHistoryColumnWidths::AUTHOR_MAX);
        assert_eq!(widths.date, GitHistoryColumnWidths::default().date);
        assert_eq!(widths.sha, GitHistoryColumnWidths::SHA_MIN);
    }

    #[test]
    fn git_history_column_order_deduplicates_and_restores_missing_columns() {
        let order = GitHistoryColumnOrder(vec![
            GitHistoryColumn::Sha,
            GitHistoryColumn::Sha,
            GitHistoryColumn::Author,
        ])
        .normalized();
        assert_eq!(
            order,
            GitHistoryColumnOrder(vec![
                GitHistoryColumn::Sha,
                GitHistoryColumn::Author,
                GitHistoryColumn::Date,
            ])
        );
    }

    #[test]
    fn large_right_pane_width_is_preserved() {
        let loaded = UiSettings {
            right_pane_width: 2400.0,
            ..Default::default()
        }
        .clamped();
        assert_eq!(loaded.right_pane_width, 2400.0);
    }

    #[test]
    fn nan_heals_to_default() {
        let healed = UiSettings {
            sidebar_width: f32::NAN,
            ..Default::default()
        }
        .clamped();
        assert_eq!(healed.sidebar_width, SIDEBAR_DEFAULT);
    }

    #[test]
    fn defaults_match_harness() {
        let d = UiSettings::default();
        assert_eq!(d.sidebar_width, SIDEBAR_MIN);
        assert_eq!(d.right_pane_width, 520.0);
        assert_eq!(d.terminal_height, 280.0);
        assert!(!d.sidebar_collapsed && !d.right_pane_open && !d.terminal_open);
        assert!(!d.escape_stops_active_agent);
    }

    #[test]
    fn legacy_panel_defaults_migrate_and_custom_shortcuts_survive() {
        let dir = tempfile::tempdir().unwrap();
        for (sidebar, right, expected_sidebar, expected_right) in [
            ("mod-s", "mod-b", "mod-b", "mod-r"),
            ("mod-shift-x", "mod-alt-b", "mod-shift-x", "mod-alt-b"),
        ] {
            std::fs::write(
                UiSettings::path(dir.path()),
                serde_json::json!({
                    "keymap": {"toggleSidebar": sidebar, "toggleChanges": right}
                })
                .to_string(),
            )
            .unwrap();
            let settings = UiSettings::load(dir.path());
            assert_eq!(settings.keymap.toggle_sidebar, expected_sidebar);
            assert_eq!(settings.keymap.toggle_changes, expected_right);
            assert_eq!(settings.keymap.save_file, "mod-s");
        }
        // Once the new map has been saved, old chords can be assigned deliberately.
        let mut settings = UiSettings::default();
        settings.keymap.save_file = "mod-shift-s".into();
        settings.keymap.toggle_sidebar = "mod-s".into();
        settings.save(dir.path()).unwrap();
        assert_eq!(UiSettings::load(dir.path()).keymap, settings.keymap);
    }

    #[test]
    fn legacy_migration_reserves_custom_chords_and_survives_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        for (custom, expected_save) in [
            ("mod-s", "mod-shift-s"),
            ("mod-b", "mod-s"),
            ("mod-r", "mod-s"),
        ] {
            std::fs::write(UiSettings::path(dir.path()), serde_json::json!({
                "keymap": {"toggleSidebar": "mod-shift-b", "toggleChanges": "mod-b", "newSession": custom}
            }).to_string()).unwrap();
            let loaded = UiSettings::load(dir.path());
            assert_eq!(loaded.keymap.new_session, custom);
            assert_eq!(loaded.keymap.toggle_sidebar, "mod-shift-b");
            assert_eq!(loaded.keymap.save_file, expected_save);
            assert!(conflicted_shortcuts(&loaded.keymap).is_empty());
            loaded.save(dir.path()).unwrap();
            assert_eq!(UiSettings::load(dir.path()).keymap, loaded.keymap);
        }
        // If every candidate is already custom-bound, leave the new action
        // unbound rather than steal a working shortcut from another action.
        std::fs::write(UiSettings::path(dir.path()), serde_json::json!({
            "keymap": {"toggleSidebar": "mod-shift-s", "newSession": "mod-s", "toggleChanges": "mod-r"}
        }).to_string()).unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.keymap.save_file, "");
        assert_eq!(loaded.keymap.new_session, "mod-s");
        assert!(conflicted_shortcuts(&loaded.keymap).is_empty());
    }

    #[test]
    fn new_project_shortcut_migrates_and_persists() {
        let mut keymap: KeymapConfig =
            serde_json::from_str(r#"{"newSession":"mod-alt-n"}"#).unwrap();
        assert_eq!(keymap.get(ShortcutId::NewProject), "mod-shift-n");
        assert_eq!(keymap.get(ShortcutId::NewSession), "mod-alt-n");
        keymap.set(ShortcutId::NewProject, "mod-alt-p".into());
        let mut restored: KeymapConfig =
            serde_json::from_str(&serde_json::to_string(&keymap).unwrap()).unwrap();
        assert_eq!(restored.get(ShortcutId::NewProject), "mod-alt-p");
        restored.reset(ShortcutId::NewProject);
        assert_eq!(restored.get(ShortcutId::NewProject), "mod-shift-n");
    }

    #[test]
    fn keymap_defaults_and_reset() {
        let mut keymap = KeymapConfig::default();
        assert_eq!(keymap.get(ShortcutId::SaveFile), "mod-s");
        keymap.set(ShortcutId::SaveFile, "mod-shift-s".into());
        keymap.reset(ShortcutId::SaveFile);
        assert_eq!(keymap.get(ShortcutId::SaveFile), "mod-s");
        assert_eq!(keymap.get(ShortcutId::ToggleSidebar), "mod-b");
        assert_eq!(keymap.get(ShortcutId::ToggleChanges), "mod-r");
        assert_eq!(keymap.get(ShortcutId::ToggleTerminal), "mod-j");
        let ctrl = if cfg!(target_os = "macos") {
            "ctrl"
        } else {
            "mod"
        };
        assert_eq!(keymap.get(ShortcutId::NextSession), format!("{ctrl}-tab"));
        assert_eq!(
            keymap.get(ShortcutId::PrevSession),
            format!("{ctrl}-shift-tab")
        );
        assert_eq!(
            keymap.get(ShortcutId::NewSession),
            ShortcutId::NewSession.default_combo()
        );
        assert_eq!(keymap.get(ShortcutId::ArchiveSession), "mod-shift-a");
        keymap.set(ShortcutId::ToggleSidebar, "mod-shift-x".into());
        assert_eq!(keymap.get(ShortcutId::ToggleSidebar), "mod-shift-x");
        keymap.reset(ShortcutId::ToggleSidebar);
        assert_eq!(keymap.get(ShortcutId::ToggleSidebar), "mod-b");
        keymap.set(ShortcutId::ArchiveSession, "mod-shift-y".into());
        assert_eq!(keymap.get(ShortcutId::ArchiveSession), "mod-shift-y");
        keymap.reset(ShortcutId::ArchiveSession);
        assert_eq!(keymap.get(ShortcutId::ArchiveSession), "mod-shift-a");
    }

    #[test]
    fn close_tab_without_archiving_shortcut_is_platform_aware_and_rebindable() {
        let id = ShortcutId::CloseTabWithoutArchiving;
        assert_eq!(platform_combo_on(true, id.default_combo_on(true)), "cmd-alt-w");
        assert_eq!(platform_combo_on(false, id.default_combo_on(false)), "ctrl-alt-w");
        let mut keymap: KeymapConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(keymap.get(id), "mod-alt-w");
        keymap.set(id, "mod-alt-x".into());
        let saved = serde_json::to_string(&keymap).unwrap();
        let restored: KeymapConfig = serde_json::from_str(&saved).unwrap();
        assert_eq!(restored.get(id), "mod-alt-x");
        keymap.reset(id);
        assert_eq!(keymap.get(id), "mod-alt-w");
    }

    #[test]
    fn reopen_closed_tab_shortcut_avoids_the_new_tab_key_on_each_platform() {
        let id = ShortcutId::ReopenClosedTab;
        assert_eq!(
            platform_combo_on(true, id.default_combo_on(true)),
            "cmd-shift-t"
        );
        assert_eq!(
            platform_combo_on(false, id.default_combo_on(false)),
            "ctrl-alt-shift-t"
        );
        for mac in [true, false] {
            assert_ne!(
                id.default_combo_on(mac),
                ShortcutId::NewSession.default_combo_on(mac)
            );
        }
        let keymap: KeymapConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(keymap.get(id), id.default_combo());
    }

    #[test]
    fn every_shortcut_default_is_unique_and_bindable() {
        // A new shortcut must not ship in conflict with an existing one, and
        // its default must parse on this platform.
        assert!(conflicted_shortcuts(&KeymapConfig::default()).is_empty());
        for id in ShortcutId::ALL {
            assert!(
                gpui::Keystroke::parse(&platform_combo(id.default_combo())).is_ok(),
                "{:?} default combo does not parse",
                id
            );
        }
    }

    #[test]
    fn combo_recording() {
        // How this platform spells a recorded ctrl (see `combo_from_keystroke_on`).
        let ctrl_combo = |suffix: &str| {
            if cfg!(target_os = "macos") {
                format!("ctrl-{suffix}")
            } else {
                format!("mod-{suffix}")
            }
        };
        assert_eq!(
            combo_from_keystroke(true, false, false, false, "s"),
            Some(ctrl_combo("s"))
        );
        assert_eq!(
            combo_from_keystroke(false, false, false, true, "s"),
            Some("mod-s".into())
        );
        assert_eq!(
            combo_from_keystroke(true, false, true, false, "tab"),
            Some(ctrl_combo("shift-tab"))
        );
        assert_eq!(
            combo_from_keystroke(true, true, true, false, "K"),
            Some(ctrl_combo("alt-shift-k"))
        );
        // Plain keys record without modifiers (Esc is filtered by the caller).
        assert_eq!(
            combo_from_keystroke(false, false, false, false, "f5"),
            Some("f5".into())
        );
        // Bare modifier presses record nothing.
        assert_eq!(
            combo_from_keystroke(true, false, false, false, "ctrl"),
            None
        );
        assert_eq!(
            combo_from_keystroke(false, false, true, false, "shift"),
            None
        );
        assert_eq!(combo_from_keystroke(false, false, false, false, ""), None);
    }

    #[test]
    fn every_default_is_spelled_the_way_the_recorder_spells_it() {
        // The invariant `default_combo_on` documents. Checked for BOTH
        // platforms because the hazard only exists off macOS, so a single-OS
        // CI run would never see it.
        for mac in [true, false] {
            for id in ShortcutId::ALL {
                let combo = id.default_combo_on(mac);
                // Via the platform spelling, where modifier names are
                // unambiguous, so the decode can't inherit the bug it checks.
                let bound = platform_combo_on(mac, combo);
                let mut parts: Vec<&str> = bound.split('-').collect();
                let key = parts.pop().expect("a combo always ends in a key");
                let recorded = combo_from_keystroke_on(
                    mac,
                    parts.contains(&"ctrl"),
                    parts.contains(&"alt"),
                    parts.contains(&"shift"),
                    parts.contains(&"cmd"),
                    key,
                );
                assert_eq!(
                    recorded.as_deref(),
                    Some(combo),
                    "{} default {combo:?} is unreachable from the recorder (mac={mac})",
                    id.label()
                );
            }
        }
    }

    #[test]
    fn defaults_are_distinct_physical_keys() {
        // Distinct STRINGS is not enough — two defaults could still resolve to
        // the same keystroke through `platform_combo`.
        let mut seen = std::collections::HashSet::new();
        for id in ShortcutId::ALL {
            let bound = platform_combo(id.default_combo());
            assert!(seen.insert(bound.clone()), "{bound:?} bound twice");
        }
    }

    #[test]
    fn conflict_detection() {
        let mut keymap = KeymapConfig::default();
        assert!(conflicted_shortcuts(&keymap).is_empty());
        keymap.set(ShortcutId::ToggleChanges, "mod-b".into());
        let conflicts = conflicted_shortcuts(&keymap);
        assert!(conflicts.contains(&ShortcutId::ToggleSidebar));
        assert!(conflicts.contains(&ShortcutId::ToggleChanges));
        assert!(!conflicts.contains(&ShortcutId::ToggleTerminal));
        keymap.reset(ShortcutId::ToggleChanges);
        assert!(conflicted_shortcuts(&keymap).is_empty());
    }

    #[test]
    fn combo_translation() {
        let primary = if cfg!(target_os = "macos") {
            "cmd"
        } else {
            "ctrl"
        };
        assert_eq!(platform_combo("mod-s"), format!("{primary}-s"));
        assert_eq!(platform_combo("alt-f4"), "alt-f4");
        let display_primary = if cfg!(target_os = "macos") {
            "Cmd"
        } else {
            "Ctrl"
        };
        assert_eq!(
            display_combo("mod-shift-s"),
            format!("{display_primary}+Shift+S")
        );
        assert_eq!(display_combo("f5"), "F5");
        assert_eq!(display_combo_on(true, "mod-alt-up"), "Cmd+Opt+Up");
        assert_eq!(display_combo_on(false, "mod-alt-up"), "Ctrl+Alt+Up");
        // Literal ctrl passes through untouched — the macOS spelling of
        // session cycling.
        assert_eq!(platform_combo("ctrl-shift-tab"), "ctrl-shift-tab");
        assert_eq!(display_combo("ctrl-shift-tab"), "Ctrl+Shift+Tab");
    }

    #[test]
    fn keymap_survives_old_settings_files() {
        // Files written before the keymap existed load with defaults.
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(UiSettings::path(dir.path()), r#"{"sidebarWidth": 300}"#).unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.keymap, KeymapConfig::default());
        assert!(!loaded.sidebar_grouped);
        assert!(!loaded.escape_stops_active_agent);
    }

    #[test]
    fn escape_stopping_is_opt_in_for_old_and_partial_settings() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth": 300, "soundEnabled": false}"#,
        )
        .unwrap();

        let loaded = UiSettings::load(dir.path());
        assert!(!loaded.escape_stops_active_agent);
        assert_eq!(loaded.sidebar_width, 300.0);
        assert!(!loaded.sound_enabled);
    }

    #[test]
    fn jump_slots_get_set_and_reset() {
        let mut keymap = KeymapConfig::default();
        assert_eq!(keymap.get(ShortcutId::JumpSession(0)), "mod-1");
        assert_eq!(keymap.get(ShortcutId::JumpSession(8)), "mod-9");
        // Past the last slot there is no shortcut, not a panic.
        assert_eq!(keymap.get(ShortcutId::JumpSession(9)), "");
        assert_eq!(ShortcutId::JumpSession(9).jump_slot(), None);
        assert_eq!(ShortcutId::JumpSession(0).jump_slot(), Some(0));
        assert_eq!(ShortcutId::ArchiveSession.jump_slot(), None);

        keymap.set(ShortcutId::JumpSession(2), "mod-alt-3".into());
        assert_eq!(keymap.get(ShortcutId::JumpSession(2)), "mod-alt-3");
        keymap.reset(ShortcutId::JumpSession(2));
        assert_eq!(keymap.get(ShortcutId::JumpSession(2)), "mod-3");
        // A write past the last slot is dropped, and grows nothing.
        keymap.set(ShortcutId::JumpSession(9), "mod-0".into());
        assert_eq!(keymap.jump_session.len(), JUMP_SLOTS);
    }

    #[test]
    fn short_or_long_jump_lists_heal_to_the_slot_count() {
        // Short: surviving entries keep their slot, the rest take defaults.
        let mut keymap = KeymapConfig {
            jump_session: vec!["mod-alt-1".into()],
            ..KeymapConfig::default()
        };
        keymap.heal_jump_slots();
        assert_eq!(keymap.jump_session.len(), JUMP_SLOTS);
        assert_eq!(keymap.get(ShortcutId::JumpSession(0)), "mod-alt-1");
        assert_eq!(keymap.get(ShortcutId::JumpSession(1)), "mod-2");

        // Long: the tail is dropped.
        let mut keymap = KeymapConfig {
            jump_session: (0..20).map(|i| format!("mod-{i}")).collect(),
            ..KeymapConfig::default()
        };
        keymap.heal_jump_slots();
        assert_eq!(keymap.jump_session.len(), JUMP_SLOTS);

        // Absent: the whole list comes back.
        let mut keymap = KeymapConfig {
            jump_session: Vec::new(),
            ..KeymapConfig::default()
        };
        keymap.heal_jump_slots();
        assert_eq!(keymap.jump_session, KeymapConfig::default().jump_session);
    }

    #[test]
    fn a_malformed_jump_list_heals_without_losing_other_settings() {
        // Healing happens on load, so an odd jumpSession must not cost the
        // user their sidebar width or their other combos.
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"sidebarWidth": 300, "keymap": {"toggleSidebar": "mod-shift-x", "jumpSession": ["mod-alt-1", "mod-alt-2"]}}"#,
        )
        .unwrap();
        let loaded = UiSettings::load(dir.path());
        assert_eq!(loaded.sidebar_width, 300.0);
        assert_eq!(loaded.keymap.get(ShortcutId::ToggleSidebar), "mod-shift-x");
        assert_eq!(loaded.keymap.get(ShortcutId::JumpSession(0)), "mod-alt-1");
        assert_eq!(loaded.keymap.get(ShortcutId::JumpSession(8)), "mod-9");
        assert_eq!(loaded.keymap.jump_session.len(), JUMP_SLOTS);
    }

    #[test]
    fn legacy_modifier_enter_shortcut_heals_without_losing_other_customizations() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"keymap": {"newSession": "mod-enter", "toggleSidebar": "mod-shift-x"}}"#,
        )
        .unwrap();

        let loaded = UiSettings::load(dir.path());
        assert_eq!(
            loaded.keymap.get(ShortcutId::NewSession),
            ShortcutId::NewSession.default_combo()
        );
        assert_eq!(loaded.keymap.get(ShortcutId::ToggleSidebar), "mod-shift-x");
    }

    #[test]
    fn jump_hints_need_an_exact_modifier_match() {
        let keymap = KeymapConfig::default();
        // Mod alone matches mod-1..9.
        assert!(jump_hints_visible(&keymap, true, false, false));
        // Extra modifiers are a different chord (Cmd+Shift+4 screenshots).
        assert!(!jump_hints_visible(&keymap, true, false, true));
        assert!(!jump_hints_visible(&keymap, true, true, false));
        // Nothing held, nothing shown.
        assert!(!jump_hints_visible(&keymap, false, false, false));
        // Alt alone is not a jump modifier by default.
        assert!(!jump_hints_visible(&keymap, false, true, false));

        // Rebinding moves the trigger with it.
        let mut rebound = KeymapConfig::default();
        for slot in 0..JUMP_SLOTS {
            rebound.set(ShortcutId::JumpSession(slot), format!("mod-alt-{slot}"));
        }
        assert!(!jump_hints_visible(&rebound, true, false, false));
        assert!(jump_hints_visible(&rebound, true, true, false));

        // A jump combo with no modifiers must not pin the overlay open.
        let mut bare = KeymapConfig::default();
        bare.set(ShortcutId::JumpSession(0), "f5".into());
        assert!(!jump_hints_visible(&bare, false, false, false));
    }

    #[test]
    fn modifier_send_hint_needs_only_the_primary_modifier() {
        assert!(modifier_send_hint_visible(true, false, false));
        assert!(!modifier_send_hint_visible(false, false, false));
        assert!(!modifier_send_hint_visible(true, true, false));
        assert!(!modifier_send_hint_visible(true, false, true));
    }

    #[test]
    fn badge_combos_use_mac_glyphs_and_linux_text() {
        // macOS: glyphs in canonical ⌃⌥⇧⌘ order, no separators — the model
        // picker's ⌘N chip form.
        assert_eq!(badge_combo_on(true, "mod-2"), "⌘2");
        assert_eq!(badge_combo_on(true, "mod-shift-a"), "⇧⌘A");
        assert_eq!(badge_combo_on(true, "mod-alt-3"), "⌥⌘3");
        assert_eq!(badge_combo_on(true, "cmd-shift-n"), "⇧⌘N");
        assert_eq!(badge_combo_on(true, "super-b"), "⌘B");
        assert_eq!(badge_combo_on(true, "cmd--"), "⌘-");
        assert_eq!(badge_combo_on(false, "mod--"), "Ctrl+-");
        assert_eq!(badge_combo_on(true, "-"), "-");
        // A literal ctrl segment (macOS recorder spelling) is ⌃.
        assert_eq!(badge_combo_on(true, "ctrl-tab"), "⌃Tab");
        // Elsewhere the textual form stands.
        assert_eq!(badge_combo_on(false, "mod-2"), "Ctrl+2");
        assert_eq!(badge_combo_on(false, "mod-shift-a"), "Ctrl+Shift+A");
    }

    #[test]
    fn combo_modifiers_reads_the_stored_form() {
        assert_eq!(combo_modifiers("mod-1"), (true, false, false));
        assert_eq!(combo_modifiers("mod-alt-shift-k"), (true, true, true));
        assert_eq!(combo_modifiers("f5"), (false, false, false));
        assert_eq!(combo_modifiers("shift-tab"), (false, false, true));
    }

    #[test]
    fn a_new_shortcut_default_yields_to_an_existing_custom_binding() {
        // Upgrade path: a file that predates the files-panel shortcut and had
        // already put its default chord on another action keeps that binding
        // and the new row arrives unbound rather than double-bound.
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"keymap": {"saveFile": "mod-s", "toggleTerminal": "mod-e"}}"#,
        )
        .unwrap();
        let keymap = UiSettings::load(dir.path()).keymap;
        assert_eq!(keymap.get(ShortcutId::ToggleTerminal), "mod-e");
        assert_eq!(keymap.get(ShortcutId::ToggleFiles), "");
        assert!(conflicted_shortcuts(&keymap).is_empty());

        // With the chord free, the new row takes its default.
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"keymap": {"saveFile": "mod-s", "toggleTerminal": "mod-j"}}"#,
        )
        .unwrap();
        let keymap = UiSettings::load(dir.path()).keymap;
        assert_eq!(keymap.get(ShortcutId::ToggleFiles), "mod-e");
    }

    #[test]
    fn a_keymap_missing_newer_shortcuts_keeps_its_customizations() {
        // Upgrade path: a file from a build that predates session cycling and
        // archiving carries the user's rebinds and defaults only the new rows.
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            UiSettings::path(dir.path()),
            r#"{"keymap": {"toggleSidebar": "mod-shift-x"}}"#,
        )
        .unwrap();
        let keymap = UiSettings::load(dir.path()).keymap;
        assert_eq!(keymap.get(ShortcutId::ToggleSidebar), "mod-shift-x");
        assert_eq!(keymap.get(ShortcutId::ToggleTerminal), "mod-j");
        assert_eq!(
            keymap.get(ShortcutId::NextSession),
            ShortcutId::NextSession.default_combo()
        );
        assert_eq!(keymap.get(ShortcutId::ArchiveSession), "mod-shift-a");
    }

    #[test]
    fn terminal_height_clamps_on_load() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(UiSettings::path(dir.path()), r#"{"terminalHeight": 5}"#).unwrap();
        assert_eq!(
            UiSettings::load(dir.path()).terminal_height,
            TERMINAL_MIN_HEIGHT
        );
        std::fs::write(UiSettings::path(dir.path()), r#"{"terminalHeight": 99999}"#).unwrap();
        assert_eq!(
            UiSettings::load(dir.path()).terminal_height,
            TERMINAL_ABS_MAX_HEIGHT
        );
    }
}
