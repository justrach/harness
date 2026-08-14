//! Git history pane: paged commit rows plus a topological lane graph.
//!
//! The pane is hosted by the current Changes surface for now, but owns its
//! data and rendering so it can move intact into the future right-panel tabs.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use chrono::DateTime;
use gpui::{
    AnyElement, App, ClipboardItem, Context, Entity, EventEmitter, Image, ImageFormat,
    ListAlignment, ListState, ObjectFit, PathBuilder, Render, SharedString, Subscription, Task,
    Window, canvas, container_query, div, img, list, point, prelude::*, px,
};
use zeron_proto::{GitHistoryCommit, GitHistoryPage, GitHistoryRef, GitHistoryRefKind};
use zeron_rpc::methods;

use crate::popover::{self, Popup};
use crate::settings::{GitHistoryAuthorDisplay, GitHistoryColumns, UiSettings};
use crate::state::AppState;
use crate::theme::Theme;

const HISTORY_PAGE_SIZE: usize = 100;
const HISTORY_ROW_HEIGHT: f32 = 36.0;
const HISTORY_LANE_SPACING: f32 = 12.0;
const HISTORY_NODE_RADIUS: f32 = 3.0;
const HISTORY_HEAD_RING_PADDING: f32 = 2.0;
const HISTORY_STROKE_WIDTH: f32 = 1.5;
const HISTORY_GRAPH_SATURATION: f32 = 0.72;
const HISTORY_GRAPH_SIDE_PADDING: f32 = 5.0;
const HISTORY_GRAPH_TRAILING_PADDING: f32 = 10.0;
const HISTORY_GRAPH_ROW_OVERLAP: f32 = 0.75;
const HISTORY_GRAPH_HIT_RADIUS: f32 = 5.5;
const HISTORY_GRAPH_FOCUSED_STROKE_WIDTH: f32 = 2.25;
const HISTORY_GRAPH_UNFOCUSED_OPACITY: f32 = 0.24;
const HISTORY_ROW_UNFOCUSED_OPACITY: f32 = 0.6;
const HISTORY_COMMIT_SUBJECT_MIN_WIDTH: f32 = 80.0;
const HISTORY_REF_AREA_RATIO: f32 = 0.45;
const HISTORY_REF_BADGE_MAX_WIDTH: f32 = 112.0;
const HISTORY_REF_GAP: f32 = 5.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SegmentShape {
    Through,
    Incoming,
    Outgoing,
}
#[derive(Debug, Clone, PartialEq, Eq)]
struct GraphSegment {
    from_lane: usize,
    to_lane: usize,
    color_id: usize,
    shape: SegmentShape,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct GraphRow {
    sha: String,
    node_lane: usize,
    node_color_id: usize,
    segments: Vec<GraphSegment>,
    is_head: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct GraphLayout {
    rows: Vec<GraphRow>,
    max_lane_count: usize,
}

#[derive(Debug, Clone, Copy)]
struct GraphFocus {
    color_id: usize,
    amount: f32,
}

struct HistoryColumnPreferences {
    columns: GitHistoryColumns,
    author_display: GitHistoryAuthorDisplay,
    data_dir: PathBuf,
}

impl gpui::Global for HistoryColumnPreferences {}

#[derive(Debug, Clone, Copy)]
enum OptionalHistoryColumn {
    Author,
    Date,
    Sha,
}

pub fn init(
    columns: GitHistoryColumns,
    author_display: GitHistoryAuthorDisplay,
    data_dir: PathBuf,
    cx: &mut App,
) {
    cx.set_global(HistoryColumnPreferences {
        columns,
        author_display,
        data_dir,
    });
}

pub fn configured_columns(cx: &App) -> GitHistoryColumns {
    cx.global::<HistoryColumnPreferences>().columns
}

pub fn configured_author_display(cx: &App) -> GitHistoryAuthorDisplay {
    cx.global::<HistoryColumnPreferences>().author_display
}

#[derive(Debug, Clone)]
struct ActiveLane {
    id: usize,
    color_id: usize,
    target_sha: String,
}

fn lane_index(lanes: &[ActiveLane], id: usize) -> usize {
    lanes
        .iter()
        .position(|lane| lane.id == id)
        .expect("active Git history lane exists")
}

/// Commits arrive child-before-parent from `git log --topo-order`. Active
/// lanes point at the parent commit that will eventually resolve each path.
fn layout_graph(commits: &[GitHistoryCommit], head_sha: Option<&str>) -> GraphLayout {
    let mut active_lanes: Vec<ActiveLane> = Vec::new();
    let mut next_lane_id = 0usize;
    let mut next_color_id = 0usize;
    let mut max_lane_count = 0usize;
    let mut rows = Vec::with_capacity(commits.len());

    for commit in commits {
        let before = active_lanes.clone();
        let incoming: Vec<usize> = before
            .iter()
            .enumerate()
            .filter_map(|(index, lane)| (lane.target_sha == commit.sha).then_some(index))
            .collect();
        let primary_incoming = incoming.first().copied();
        let node_lane = primary_incoming.unwrap_or(before.len());
        let primary_lane = primary_incoming.and_then(|index| before.get(index));
        let node_color_id = primary_lane.map(|lane| lane.color_id).unwrap_or_else(|| {
            let color = next_color_id;
            next_color_id += 1;
            color
        });
        let resolved_ids: HashSet<usize> = incoming.iter().map(|&index| before[index].id).collect();
        let mut next_lanes: Vec<ActiveLane> = before
            .iter()
            .filter(|lane| !resolved_ids.contains(&lane.id))
            .cloned()
            .collect();
        let mut outgoing: Vec<(usize, usize)> = Vec::new();

        let mut primary_outgoing_id = None;
        if let Some(first_parent) = commit.parent_shas.first() {
            let id = primary_lane.map(|lane| lane.id).unwrap_or_else(|| {
                let id = next_lane_id;
                next_lane_id += 1;
                id
            });
            let lane = ActiveLane {
                id,
                color_id: node_color_id,
                target_sha: first_parent.clone(),
            };
            next_lanes.insert(node_lane.min(next_lanes.len()), lane.clone());
            primary_outgoing_id = Some(id);
            outgoing.push((id, lane.color_id));
        }

        let mut parent_offset = 1usize;
        for parent_sha in commit.parent_shas.iter().skip(1) {
            if let Some(existing) = next_lanes
                .iter()
                .find(|lane| lane.target_sha == *parent_sha)
            {
                outgoing.push((existing.id, existing.color_id));
                continue;
            }
            let lane = ActiveLane {
                id: next_lane_id,
                color_id: next_color_id,
                target_sha: parent_sha.clone(),
            };
            next_lane_id += 1;
            next_color_id += 1;
            let primary_index = primary_outgoing_id
                .map(|id| lane_index(&next_lanes, id))
                .unwrap_or_else(|| node_lane.min(next_lanes.len()));
            next_lanes.insert(
                (primary_index + parent_offset).min(next_lanes.len()),
                lane.clone(),
            );
            parent_offset += 1;
            outgoing.push((lane.id, lane.color_id));
        }

        let mut segments: Vec<GraphSegment> = before
            .iter()
            .enumerate()
            .filter(|(_, lane)| !resolved_ids.contains(&lane.id))
            .map(|(from_lane, lane)| GraphSegment {
                from_lane,
                to_lane: lane_index(&next_lanes, lane.id),
                color_id: lane.color_id,
                shape: SegmentShape::Through,
            })
            .collect();
        segments.extend(incoming.iter().map(|&from_lane| GraphSegment {
            from_lane,
            to_lane: node_lane,
            color_id: before[from_lane].color_id,
            shape: SegmentShape::Incoming,
        }));
        segments.extend(outgoing.into_iter().map(|(id, color_id)| GraphSegment {
            from_lane: node_lane,
            to_lane: lane_index(&next_lanes, id),
            color_id,
            shape: SegmentShape::Outgoing,
        }));

        max_lane_count = max_lane_count
            .max(before.len())
            .max(next_lanes.len())
            .max(node_lane + 1);
        rows.push(GraphRow {
            sha: commit.sha.clone(),
            node_lane,
            node_color_id,
            segments,
            is_head: head_sha == Some(commit.sha.as_str()),
        });
        active_lanes = next_lanes;
    }

    GraphLayout {
        rows,
        max_lane_count,
    }
}

fn lane_x(lane: usize) -> f32 {
    HISTORY_GRAPH_SIDE_PADDING + HISTORY_NODE_RADIUS + lane as f32 * HISTORY_LANE_SPACING
}

fn graph_width(lane_count: usize) -> f32 {
    let count = lane_count.max(1);
    HISTORY_GRAPH_SIDE_PADDING
        + HISTORY_GRAPH_TRAILING_PADDING
        + HISTORY_NODE_RADIUS * 2.0
        + (count - 1) as f32 * HISTORY_LANE_SPACING
}

fn cubic_coordinate(start: f32, control_1: f32, control_2: f32, end: f32, t: f32) -> f32 {
    let inverse = 1.0 - t;
    inverse.powi(3) * start
        + 3.0 * inverse.powi(2) * t * control_1
        + 3.0 * inverse * t.powi(2) * control_2
        + t.powi(3) * end
}

fn point_to_segment_distance(
    point_x: f32,
    point_y: f32,
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
) -> f32 {
    let delta_x = end_x - start_x;
    let delta_y = end_y - start_y;
    let length_squared = delta_x * delta_x + delta_y * delta_y;
    if length_squared <= f32::EPSILON {
        return ((point_x - start_x).powi(2) + (point_y - start_y).powi(2)).sqrt();
    }
    let projection = (((point_x - start_x) * delta_x + (point_y - start_y) * delta_y)
        / length_squared)
        .clamp(0.0, 1.0);
    let closest_x = start_x + projection * delta_x;
    let closest_y = start_y + projection * delta_y;
    ((point_x - closest_x).powi(2) + (point_y - closest_y).powi(2)).sqrt()
}

fn segment_distance(segment: &GraphSegment, point_x: f32, point_y: f32) -> f32 {
    let middle = HISTORY_ROW_HEIGHT / 2.0;
    let from_x = lane_x(segment.from_lane);
    let to_x = lane_x(segment.to_lane);
    let (start_y, end_y, control_1_y, control_2_y) = match segment.shape {
        SegmentShape::Incoming => (
            -HISTORY_GRAPH_ROW_OVERLAP,
            middle,
            middle * 0.55,
            middle * 0.55,
        ),
        SegmentShape::Outgoing => (
            middle,
            HISTORY_ROW_HEIGHT + HISTORY_GRAPH_ROW_OVERLAP,
            middle * 1.45,
            middle * 1.45,
        ),
        SegmentShape::Through => (
            -HISTORY_GRAPH_ROW_OVERLAP,
            HISTORY_ROW_HEIGHT + HISTORY_GRAPH_ROW_OVERLAP,
            middle,
            middle,
        ),
    };
    if segment.shape == SegmentShape::Through && segment.from_lane == segment.to_lane {
        return point_to_segment_distance(point_x, point_y, from_x, start_y, to_x, end_y);
    }

    // A short polyline approximation is enough for pointer hit testing and
    // keeps the interactive target in lockstep with the painted Bezier.
    const SAMPLES: usize = 10;
    let mut closest = f32::MAX;
    let mut previous_x = from_x;
    let mut previous_y = start_y;
    for sample in 1..=SAMPLES {
        let t = sample as f32 / SAMPLES as f32;
        let current_x = cubic_coordinate(from_x, from_x, to_x, to_x, t);
        let current_y = cubic_coordinate(start_y, control_1_y, control_2_y, end_y, t);
        closest = closest.min(point_to_segment_distance(
            point_x, point_y, previous_x, previous_y, current_x, current_y,
        ));
        previous_x = current_x;
        previous_y = current_y;
    }
    closest
}

fn hovered_graph_path(row: &GraphRow, point_x: f32, point_y: f32) -> Option<usize> {
    let node_x = lane_x(row.node_lane);
    let node_y = HISTORY_ROW_HEIGHT / 2.0;
    let node_distance = ((point_x - node_x).powi(2) + (point_y - node_y).powi(2)).sqrt();
    if node_distance <= HISTORY_GRAPH_HIT_RADIUS + HISTORY_NODE_RADIUS {
        return Some(row.node_color_id);
    }

    row.segments
        .iter()
        .map(|segment| {
            (
                segment.color_id,
                segment_distance(segment, point_x, point_y),
            )
        })
        .filter(|(_, distance)| *distance <= HISTORY_GRAPH_HIT_RADIUS)
        .min_by(|left, right| left.1.total_cmp(&right.1))
        .map(|(color_id, _)| color_id)
}

fn estimated_ref_badge_width(reference: &GitHistoryRef) -> f32 {
    // 10 px icon + 2 px gap + 10 px horizontal padding + the 10 px label.
    (22.0 + reference.label.chars().count() as f32 * 5.7).min(HISTORY_REF_BADGE_MAX_WIDTH)
}

fn estimated_ref_overflow_width(hidden: usize) -> f32 {
    format!("+{hidden}").chars().count() as f32 * 5.7
}

fn ref_area_width(commit_column_width: f32) -> f32 {
    let inner = (commit_column_width - 8.0).max(0.0);
    (inner * HISTORY_REF_AREA_RATIO)
        .min((inner - HISTORY_COMMIT_SUBJECT_MIN_WIDTH - HISTORY_REF_GAP).max(0.0))
}

fn visible_ref_count(refs: &[GitHistoryRef], available_width: f32) -> usize {
    if refs.is_empty() {
        return 0;
    }

    // Start with no visible badges so the overflow target remains available
    // when even the first badge plus `+N` would exceed the ref area.
    let mut visible = 0;
    for count in 1..=refs.len() {
        let hidden = refs.len() - count;
        let item_count = count + usize::from(hidden > 0);
        let badges = refs[..count]
            .iter()
            .map(estimated_ref_badge_width)
            .sum::<f32>();
        let overflow = (hidden > 0)
            .then(|| estimated_ref_overflow_width(hidden))
            .unwrap_or_default();
        let gaps = item_count.saturating_sub(1) as f32 * HISTORY_REF_GAP;
        if badges + overflow + gaps <= available_width {
            visible = count;
        }
    }
    visible
}

fn format_date(value: &str) -> String {
    DateTime::parse_from_rfc3339(value)
        .map(|date| date.format("%b %-d, %Y").to_string())
        .unwrap_or_else(|_| "—".to_string())
}

fn ref_color(reference: &GitHistoryRef, theme: &Theme) -> gpui::Hsla {
    match reference.kind {
        GitHistoryRefKind::Branch => theme.accent,
        GitHistoryRefKind::Remote => theme.busy,
        GitHistoryRefKind::Tag => theme.warning,
    }
}

fn ref_icon(kind: GitHistoryRefKind) -> &'static str {
    match kind {
        GitHistoryRefKind::Branch => crate::icons::GIT_BRANCH,
        GitHistoryRefKind::Remote => crate::icons::CLOUD,
        GitHistoryRefKind::Tag => crate::icons::TAG,
    }
}

fn ref_description(reference: &GitHistoryRef) -> SharedString {
    let kind = match reference.kind {
        GitHistoryRefKind::Branch => "Branch",
        GitHistoryRefKind::Remote => "Remote branch",
        GitHistoryRefKind::Tag => "Tag",
    };
    format!("{kind}: {}", reference.label).into()
}

fn graph_color(mut color: gpui::Hsla) -> gpui::Hsla {
    color.s *= HISTORY_GRAPH_SATURATION;
    color
}

struct HistoryRefTooltip {
    descriptions: Vec<SharedString>,
}

impl Render for HistoryRefTooltip {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx);
        let longest = self
            .descriptions
            .iter()
            .map(|description| description.chars().count())
            .max()
            .unwrap_or_default();
        let width = (longest as f32 * 6.4 + 16.0).clamp(72.0, 360.0);
        div()
            .w(px(width))
            .px(px(8.0))
            .py(px(6.0))
            .flex()
            .flex_col()
            .gap(px(3.0))
            .rounded(px(5.0))
            .border_1()
            .border_color(theme.border_strong)
            .bg(theme.surface_raised)
            .shadow_md()
            .text_size(px(11.0))
            .text_color(theme.text_muted)
            .children(self.descriptions.iter().cloned().map(|description| {
                div()
                    .min_w_0()
                    .truncate()
                    .whitespace_nowrap()
                    .font_family(theme.font_mono.clone())
                    .child(description)
            }))
    }
}

struct HistoryAuthorTooltip {
    name: SharedString,
}

impl Render for HistoryAuthorTooltip {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx);
        let width = (self.name.chars().count() as f32 * 6.2 + 16.0).clamp(72.0, 260.0);
        div()
            .w(px(width))
            .px(px(8.0))
            .py(px(5.0))
            .rounded(px(5.0))
            .border_1()
            .border_color(theme.border_strong)
            .bg(theme.surface_raised)
            .shadow_md()
            .truncate()
            .whitespace_nowrap()
            .text_size(px(11.0))
            .text_color(theme.text_muted)
            .child(self.name.clone())
    }
}

fn history_author_name(name: &str) -> SharedString {
    if name.trim().is_empty() {
        "Unknown".into()
    } else {
        name.to_string().into()
    }
}

fn history_author_initial(name: &str) -> SharedString {
    name.chars()
        .find(|character| !character.is_whitespace())
        .map(|character| character.to_uppercase().collect::<String>())
        .unwrap_or_else(|| "?".to_string())
        .into()
}

fn decode_history_avatar(encoded: &str) -> Option<Arc<Image>> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()?;
    let format = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        ImageFormat::Png
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        ImageFormat::Jpeg
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        ImageFormat::Gif
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP") {
        ImageFormat::Webp
    } else {
        return None;
    };
    Some(Arc::new(Image::from_bytes(format, bytes)))
}

pub struct GitHistory {
    state: Entity<AppState>,
    started: bool,
    target_key: Option<String>,
    commits: Vec<GitHistoryCommit>,
    head_sha: Option<String>,
    next_cursor: Option<usize>,
    total_count: Option<usize>,
    head_commit_count: Option<usize>,
    loading: bool,
    error: Option<SharedString>,
    graph: GraphLayout,
    list: ListState,
    hovered_path: Option<usize>,
    graph_hover_active: bool,
    graph_hover_clear_task: Option<Task<()>>,
    avatar_images: HashMap<String, Arc<Image>>,
    column_menu: Popup<gpui::Point<gpui::Pixels>>,
    author_menu: Popup<gpui::Point<gpui::Pixels>>,
    copied_sha: Option<String>,
    request_task: Option<Task<()>>,
    copy_task: Option<Task<()>>,
    fetching_all: bool,
    fetch_for: Option<String>,
    fetch_error: Option<SharedString>,
    fetch_task: Option<Task<()>>,
    _observe: Subscription,
}

pub enum GitHistoryEvent {
    FetchSucceeded,
    /// A commit row was clicked — the host opens it as its own diff tab.
    OpenCommit(GitHistoryCommit),
}

impl EventEmitter<GitHistoryEvent> for GitHistory {}

pub struct GitHistoryCount {
    history: Entity<GitHistory>,
    _observe: Subscription,
}

pub struct GitHistoryFetchButton {
    history: Entity<GitHistory>,
    _observe: Subscription,
}

impl GitHistoryFetchButton {
    pub fn new(history: Entity<GitHistory>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&history, |_, _, cx| cx.notify());
        Self {
            history,
            _observe: observe,
        }
    }
}

impl Render for GitHistoryFetchButton {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let fetching = self.history.read(cx).fetching_all;
        let history = self.history.clone();
        div()
            .id("history-fetch-all")
            .h(px(24.0))
            .px(px(8.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .gap(px(6.0))
            .rounded(px(6.0))
            .bg(if fetching {
                crate::theme::wash(0.05)
            } else {
                crate::motion::hover_blend(
                    "history-fetch-all",
                    crate::theme::wash(0.0),
                    crate::theme::wash(0.14),
                )
            })
            .occlude()
            .on_mouse_down(gpui::MouseButton::Left, |_, window, _| {
                window.prevent_default()
            })
            .when(!fetching, |element| {
                element
                    .cursor_pointer()
                    .on_hover(crate::motion::hover_listener("history-fetch-all"))
                    .on_click(move |_, _, cx| {
                        cx.stop_propagation();
                        history.update(cx, |history, cx| history.fetch_all(cx));
                    })
            })
            .child(if fetching {
                crate::loaders::mini_gradient_spinner(
                    "history-fetch-all-spinner",
                    1.75,
                    cx.entity_id(),
                    cx,
                )
                .into_any_element()
            } else {
                crate::icons::icon(crate::icons::CLOUD)
                    .size(px(12.0))
                    .text_color(theme.text_muted.opacity(0.75))
                    .into_any_element()
            })
            .child(
                div()
                    .whitespace_nowrap()
                    .text_size(px(11.0))
                    .text_color(if fetching {
                        theme.text_faint
                    } else {
                        theme.text_muted
                    })
                    .child(if fetching { "Fetching…" } else { "Fetch all" }),
            )
    }
}

impl GitHistoryCount {
    pub fn new(history: Entity<GitHistory>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&history, |_, _, cx| cx.notify());
        Self {
            history,
            _observe: observe,
        }
    }
}

impl Render for GitHistoryCount {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx);
        let history = self.history.read(cx);
        let count = history.commit_count();
        let branch = history.current_branch(cx);
        div()
            .h_full()
            .min_w_0()
            .flex()
            .items_center()
            .gap(px(10.0))
            .when_some(count, |element, count| {
                element.child(
                    div()
                        .flex_none()
                        .whitespace_nowrap()
                        .text_size(px(11.0))
                        .text_color(theme.text_muted)
                        .child(SharedString::from(format!(
                            "{count} commit{}",
                            if count == 1 { "" } else { "s" }
                        ))),
                )
            })
            .when_some(branch, |element, branch| {
                element.child(
                    div()
                        .min_w_0()
                        .truncate()
                        .font_family(theme.font_mono.clone())
                        .text_size(px(11.5))
                        .text_color(theme.text_dim)
                        .child(SharedString::from(branch)),
                )
            })
    }
}

impl GitHistory {
    pub fn new(state: Entity<AppState>, cx: &mut Context<Self>) -> Self {
        let observe = cx.observe(&state, |this, _, cx| {
            if this.started {
                this.ensure_loaded(cx);
            }
        });
        Self {
            state,
            started: false,
            target_key: None,
            commits: Vec::new(),
            head_sha: None,
            next_cursor: None,
            total_count: None,
            head_commit_count: None,
            loading: false,
            error: None,
            graph: GraphLayout::default(),
            list: ListState::new(0, ListAlignment::Top, px(HISTORY_ROW_HEIGHT * 5.0)),
            hovered_path: None,
            graph_hover_active: false,
            graph_hover_clear_task: None,
            avatar_images: HashMap::new(),
            column_menu: Popup::default(),
            author_menu: Popup::default(),
            copied_sha: None,
            request_task: None,
            copy_task: None,
            fetching_all: false,
            fetch_for: None,
            fetch_error: None,
            fetch_task: None,
            _observe: observe,
        }
    }

    fn context(&self, cx: &App) -> Option<(String, String, Option<String>)> {
        let state = self.state.read(cx);
        let chat = state.selected_chat_row()?;
        let cwd = chat.cwd.clone()?;
        let target = (state.local_device_id.as_deref() != Some(chat.device_id.as_str()))
            .then(|| chat.device_id.clone());
        let key = format!("{}|{cwd}", target.as_deref().unwrap_or("local"));
        Some((key, cwd, target))
    }

    pub fn ensure_loaded(&mut self, cx: &mut Context<Self>) {
        self.started = true;
        let Some((key, cwd, target)) = self.context(cx) else {
            self.fetch_task = None;
            self.fetching_all = false;
            self.fetch_for = None;
            self.fetch_error = None;
            self.target_key = None;
            self.commits.clear();
            self.total_count = None;
            self.head_commit_count = None;
            self.graph = GraphLayout::default();
            self.list.reset(0);
            self.hovered_path = None;
            self.graph_hover_active = false;
            self.graph_hover_clear_task = None;
            self.avatar_images.clear();
            self.loading = false;
            return;
        };
        if self.target_key.as_deref() == Some(key.as_str()) {
            if !self.loading && self.commits.is_empty() && self.error.is_none() {
                self.fetch_page(key, cwd, target, 0, true, cx);
            }
            return;
        }
        self.request_task = None;
        self.fetch_task = None;
        self.fetching_all = false;
        self.fetch_for = None;
        self.fetch_error = None;
        self.loading = false;
        self.target_key = Some(key.clone());
        self.commits.clear();
        self.head_sha = None;
        self.next_cursor = None;
        self.total_count = None;
        self.head_commit_count = None;
        self.error = None;
        self.graph = GraphLayout::default();
        self.list.reset(0);
        self.hovered_path = None;
        self.graph_hover_active = false;
        self.graph_hover_clear_task = None;
        self.avatar_images.clear();
        self.fetch_page(key, cwd, target, 0, true, cx);
    }

    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        let Some((key, cwd, target)) = self.context(cx) else {
            return;
        };
        self.target_key = Some(key.clone());
        self.fetch_page(key, cwd, target, 0, true, cx);
    }

    pub fn fetch_all(&mut self, cx: &mut Context<Self>) {
        if self.fetching_all {
            return;
        }
        let Some((key, cwd, target)) = self.context(cx) else {
            return;
        };
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.fetching_all = true;
        self.fetch_for = Some(key.clone());
        self.fetch_error = None;
        cx.notify();
        self.fetch_task = Some(cx.spawn(async move |this, cx| {
            let mut params = serde_json::Map::new();
            params.insert("repoPath".into(), serde_json::Value::String(cwd.clone()));
            if let Some(target) = target.clone() {
                params.insert("targetDeviceId".into(), serde_json::Value::String(target));
            }
            let result = engine
                .client()
                .call(methods::FETCH_ALL, serde_json::Value::Object(params))
                .await;
            this.update(cx, |history, cx| {
                if history.fetch_for.as_deref() != Some(key.as_str()) {
                    return;
                }
                history.fetching_all = false;
                history.fetch_for = None;
                match result {
                    Ok(_) => {
                        history.fetch_error = None;
                        // Cancel a pre-fetch history request so the next page
                        // is guaranteed to observe the updated remote refs.
                        history.request_task = None;
                        history.loading = false;
                        history.fetch_page(key, cwd, target, 0, true, cx);
                        cx.emit(GitHistoryEvent::FetchSucceeded);
                    }
                    Err(error) => history.fetch_error = Some(error.to_string().into()),
                }
                cx.notify();
            })
            .ok();
        }));
    }

    pub fn commit_count(&self) -> Option<usize> {
        self.head_commit_count
    }

    fn current_branch(&self, cx: &App) -> Option<String> {
        self.state
            .read(cx)
            .selected_chat_row()
            .and_then(|chat| chat.branch.clone())
    }

    fn load_older(&mut self, cx: &mut Context<Self>) {
        let Some(cursor) = self.next_cursor else {
            return;
        };
        let Some((key, cwd, target)) = self.context(cx) else {
            return;
        };
        self.fetch_page(key, cwd, target, cursor, false, cx);
    }

    fn resolve_avatars(
        &mut self,
        key: String,
        cwd: String,
        target: Option<String>,
        cursor: usize,
        cx: &mut Context<Self>,
    ) {
        let mut unique_authors = HashMap::new();
        for commit in &self.commits {
            let email = commit.author_email.trim().to_ascii_lowercase();
            if !email.is_empty() {
                unique_authors
                    .entry(email)
                    .or_insert_with(|| (commit.sha.clone(), commit.author_email.clone()));
            }
        }
        let authors: Vec<_> = unique_authors
            .into_values()
            .map(|(sha, email)| serde_json::json!({ "sha": sha, "email": email }))
            .collect();
        if authors.is_empty() {
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        let mut params = serde_json::Map::new();
        params.insert("cwd".into(), serde_json::Value::String(cwd));
        params.insert("authors".into(), serde_json::Value::Array(authors));
        params.insert("cursor".into(), serde_json::json!(cursor));
        params.insert("limit".into(), serde_json::json!(HISTORY_PAGE_SIZE));
        if let Some(target) = target {
            params.insert("targetDeviceId".into(), serde_json::Value::String(target));
        }
        cx.spawn(async move |this, cx| {
            let result = engine
                .client()
                .call(
                    methods::RESOLVE_GIT_AVATARS,
                    serde_json::Value::Object(params),
                )
                .await;
            this.update(cx, |history, cx| {
                if history.target_key.as_deref() != Some(key.as_str()) {
                    return;
                }
                if let Ok(avatars) = result.and_then(|value| {
                    serde_json::from_value::<HashMap<String, String>>(value)
                        .map_err(|error| zeron_rpc::RpcError::Failed(error.to_string()))
                }) {
                    history.avatar_images.extend(avatars.into_iter().filter_map(
                        |(email, encoded)| {
                            decode_history_avatar(&encoded).map(|image| (email, image))
                        },
                    ));
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
    }

    fn fetch_page(
        &mut self,
        key: String,
        cwd: String,
        target: Option<String>,
        cursor: usize,
        reset: bool,
        cx: &mut Context<Self>,
    ) {
        if self.loading {
            return;
        }
        let Some(engine) = self.state.read(cx).engine().cloned() else {
            return;
        };
        self.loading = true;
        self.error = None;
        cx.notify();
        self.request_task = Some(cx.spawn(async move |this, cx| {
            let mut params = serde_json::Map::new();
            params.insert("cwd".into(), serde_json::Value::String(cwd.clone()));
            params.insert("cursor".into(), serde_json::json!(cursor));
            params.insert("limit".into(), serde_json::json!(HISTORY_PAGE_SIZE));
            if let Some(target) = target.clone() {
                params.insert("targetDeviceId".into(), serde_json::Value::String(target));
            }
            let result = engine
                .client()
                .call(methods::LIST_GIT_HISTORY, serde_json::Value::Object(params))
                .await;
            this.update(cx, |history, cx| {
                if history.target_key.as_deref() != Some(key.as_str()) {
                    return;
                }
                history.loading = false;
                match result.and_then(|value| {
                    serde_json::from_value::<GitHistoryPage>(value)
                        .map_err(|error| zeron_rpc::RpcError::Failed(error.to_string()))
                }) {
                    Ok(page) => {
                        let old_commit_count = history.commits.len();
                        let old_item_count =
                            old_commit_count + usize::from(history.next_cursor.is_some());
                        if reset {
                            history.commits = page.commits;
                            history.total_count = page.total_count;
                            history.head_commit_count = page.head_commit_count;
                        } else {
                            let mut seen: HashSet<String> = history
                                .commits
                                .iter()
                                .map(|commit| commit.sha.clone())
                                .collect();
                            history.commits.extend(
                                page.commits
                                    .into_iter()
                                    .filter(|commit| seen.insert(commit.sha.clone())),
                            );
                            if page.total_count.is_some() {
                                history.total_count = page.total_count;
                            }
                            if page.head_commit_count.is_some() {
                                history.head_commit_count = page.head_commit_count;
                            }
                        }
                        history.head_sha = page.head_sha;
                        history.next_cursor = page.next_cursor;
                        history.graph = layout_graph(&history.commits, history.head_sha.as_deref());
                        let new_item_count =
                            history.commits.len() + usize::from(history.next_cursor.is_some());
                        if reset {
                            history
                                .list
                                .reset_with_uniform_height(new_item_count, px(HISTORY_ROW_HEIGHT));
                        } else {
                            history.list.splice(
                                old_commit_count..old_item_count,
                                new_item_count - old_commit_count,
                            );
                        }
                        history.resolve_avatars(
                            key.clone(),
                            cwd.clone(),
                            target.clone(),
                            cursor,
                            cx,
                        );
                    }
                    Err(error) => history.error = Some(error.to_string().into()),
                }
                cx.notify();
            })
            .ok();
        }));
    }

    fn copy_sha(&mut self, sha: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(sha.clone()));
        self.copied_sha = Some(sha);
        self.copy_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1_200))
                .await;
            this.update(cx, |history, cx| {
                history.copied_sha = None;
                cx.notify();
            })
            .ok();
        }));
    }

    fn graph_hover_key(cx: &Context<Self>) -> String {
        format!("history-graph-focus-{}", cx.entity_id())
    }

    fn graph_focus(&self, cx: &Context<Self>) -> Option<GraphFocus> {
        self.hovered_path.map(|color_id| GraphFocus {
            color_id,
            amount: crate::motion::hover_t(&Self::graph_hover_key(cx)),
        })
    }

    fn set_graph_hover(&mut self, path: Option<usize>, cx: &mut Context<Self>) {
        if let Some(path) = path {
            if self.graph_hover_active && self.hovered_path == Some(path) {
                return;
            }
            self.graph_hover_clear_task = None;
            self.graph_hover_active = true;
            self.hovered_path = Some(path);
            crate::motion::set_hover(
                &Self::graph_hover_key(cx),
                true,
                crate::motion::reduced_motion(cx),
            );
            cx.notify();
            return;
        }

        if !self.graph_hover_active {
            return;
        }
        self.graph_hover_active = false;
        let reduced_motion = crate::motion::reduced_motion(cx);
        crate::motion::set_hover(&Self::graph_hover_key(cx), false, reduced_motion);
        if reduced_motion {
            self.hovered_path = None;
            self.graph_hover_clear_task = None;
        } else {
            let fading_path = self.hovered_path;
            let duration = crate::motion::HOVER_FADE
                .total()
                .mul_f32(crate::motion::speed_scale());
            self.graph_hover_clear_task = Some(cx.spawn(async move |this, cx| {
                cx.background_executor().timer(duration).await;
                this.update(cx, |history, cx| {
                    if !history.graph_hover_active && history.hovered_path == fading_path {
                        history.hovered_path = None;
                        history.graph_hover_clear_task = None;
                        cx.notify();
                    }
                })
                .ok();
            }));
        }
        cx.notify();
    }

    fn update_graph_hover(
        &mut self,
        row_index: usize,
        position: gpui::Point<gpui::Pixels>,
        cx: &mut Context<Self>,
    ) {
        let Some(bounds) = self.list.bounds_for_item(row_index) else {
            self.set_graph_hover(None, cx);
            return;
        };
        let Some(row) = self.graph.rows.get(row_index) else {
            self.set_graph_hover(None, cx);
            return;
        };
        let local_x = f32::from(position.x - bounds.left());
        let local_y = f32::from(position.y - bounds.top());
        self.set_graph_hover(hovered_graph_path(row, local_x, local_y), cx);
    }

    fn toggle_column(&mut self, column: OptionalHistoryColumn, cx: &mut Context<Self>) {
        let (columns, data_dir) = {
            let preferences = cx.global_mut::<HistoryColumnPreferences>();
            match column {
                OptionalHistoryColumn::Author => {
                    preferences.columns.author = !preferences.columns.author
                }
                OptionalHistoryColumn::Date => preferences.columns.date = !preferences.columns.date,
                OptionalHistoryColumn::Sha => preferences.columns.sha = !preferences.columns.sha,
            }
            (preferences.columns, preferences.data_dir.clone())
        };
        Self::persist_columns(columns, &data_dir);
        cx.refresh_windows();
        cx.notify();
    }

    fn reset_columns(&mut self, cx: &mut Context<Self>) {
        let columns = GitHistoryColumns::default();
        let data_dir = {
            let preferences = cx.global_mut::<HistoryColumnPreferences>();
            preferences.columns = columns;
            preferences.data_dir.clone()
        };
        Self::persist_columns(columns, &data_dir);
        cx.refresh_windows();
        cx.notify();
    }

    fn persist_columns(columns: GitHistoryColumns, data_dir: &std::path::Path) {
        // Reload before writing because Shell and Appearance own other fields
        // in this same file and may have persisted them since boot.
        let mut settings = UiSettings::load(data_dir);
        settings.git_history_columns = columns;
        if let Err(error) = settings.save(data_dir) {
            tracing::warn!(%error, "could not persist Git history columns");
        }
    }

    fn open_column_menu(&mut self, position: gpui::Point<gpui::Pixels>, cx: &mut Context<Self>) {
        self.close_author_menu(cx);
        self.column_menu.open(position);
        cx.notify();
    }

    fn close_column_menu(&mut self, cx: &mut Context<Self>) {
        if self.column_menu.begin_close() {
            popover::reap_popup(cx, |history: &mut Self| &mut history.column_menu);
        }
    }

    fn open_author_menu(&mut self, position: gpui::Point<gpui::Pixels>, cx: &mut Context<Self>) {
        self.close_column_menu(cx);
        self.author_menu.open(position);
        cx.notify();
    }

    fn close_author_menu(&mut self, cx: &mut Context<Self>) {
        if self.author_menu.begin_close() {
            popover::reap_popup(cx, |history: &mut Self| &mut history.author_menu);
        }
    }

    fn toggle_author_display(&mut self, cx: &mut Context<Self>) {
        let (display, data_dir) = {
            let preferences = cx.global_mut::<HistoryColumnPreferences>();
            preferences.author_display = match preferences.author_display {
                GitHistoryAuthorDisplay::Avatar => GitHistoryAuthorDisplay::Name,
                GitHistoryAuthorDisplay::Name => GitHistoryAuthorDisplay::Avatar,
            };
            (preferences.author_display, preferences.data_dir.clone())
        };
        let mut settings = UiSettings::load(&data_dir);
        settings.git_history_author_display = display;
        if let Err(error) = settings.save(&data_dir) {
            tracing::warn!(%error, "could not persist Git history author display");
        }
        cx.refresh_windows();
        cx.notify();
    }

    fn render_author_menu(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let show_name = configured_author_display(cx) == GitHistoryAuthorDisplay::Name;
        popover::popover_card(theme)
            .w(px(116.0))
            .p(px(3.0))
            .rounded(px(9.0))
            .on_mouse_down_out(cx.listener(|this, _, _, cx| this.close_author_menu(cx)))
            .child(
                popover::menu_row(theme, false, "history-author-display-name")
                    .id("history-author-display-name")
                    .gap(px(0.0))
                    .px(px(7.0))
                    .py(px(4.0))
                    .rounded(px(6.0))
                    .text_size(px(11.5))
                    .on_click(cx.listener(|this, _, _, cx| {
                        cx.stop_propagation();
                        this.toggle_author_display(cx);
                        this.close_author_menu(cx);
                    }))
                    .child(div().flex_1().child("Name"))
                    .child(div().w(px(12.0)).flex_none().flex().justify_end().when(
                        show_name,
                        |element| {
                            element.child(
                                crate::icons::icon(crate::icons::CHECK)
                                    .size(px(10.0))
                                    .text_color(theme.text_muted),
                            )
                        },
                    )),
            )
            .into_any_element()
    }

    fn render_column_menu(&mut self, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let columns = configured_columns(cx);
        let option =
            |label: &'static str,
             checked: bool,
             column: OptionalHistoryColumn,
             index: usize,
             cx: &mut Context<Self>| {
                popover::menu_row(
                    theme,
                    false,
                    SharedString::from(format!("history-column-option-{index}")),
                )
                .id(("history-column-option", index))
                .gap(px(0.0))
                .px(px(7.0))
                .py(px(4.0))
                .rounded(px(6.0))
                .text_size(px(11.5))
                .on_click(cx.listener(move |this, _, _, cx| {
                    cx.stop_propagation();
                    this.toggle_column(column, cx);
                }))
                .child(div().flex_1().child(label))
                .child(div().w(px(12.0)).flex_none().flex().justify_end().when(
                    checked,
                    |element| {
                        element.child(
                            crate::icons::icon(crate::icons::CHECK)
                                .size(px(10.0))
                                .text_color(theme.text_muted),
                        )
                    },
                ))
            };
        let defaults = GitHistoryColumns::default();
        let can_reset = columns != defaults;

        popover::popover_card(theme)
            .w(px(132.0))
            .p(px(3.0))
            .rounded(px(9.0))
            .on_mouse_down_out(cx.listener(|this, _, _, cx| this.close_column_menu(cx)))
            .child(
                div()
                    .flex()
                    .flex_col()
                    .gap(px(1.0))
                    .child(option(
                        "Author",
                        columns.author,
                        OptionalHistoryColumn::Author,
                        0,
                        cx,
                    ))
                    .child(option(
                        "Date",
                        columns.date,
                        OptionalHistoryColumn::Date,
                        1,
                        cx,
                    ))
                    .child(option(
                        "SHA",
                        columns.sha,
                        OptionalHistoryColumn::Sha,
                        2,
                        cx,
                    ))
                    .when(can_reset, |menu| {
                        menu.child(
                            div()
                                .h(px(1.0))
                                .mx(px(5.0))
                                .my(px(2.0))
                                .bg(crate::theme::hairline(0.08)),
                        )
                        .child(
                            popover::menu_row(theme, false, "history-columns-reset")
                                .id("history-columns-reset")
                                .px(px(7.0))
                                .py(px(4.0))
                                .rounded(px(6.0))
                                .text_size(px(11.5))
                                .text_color(theme.text_muted)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    cx.stop_propagation();
                                    this.reset_columns(cx);
                                    this.close_column_menu(cx);
                                }))
                                .child("Reset"),
                        )
                    }),
            )
            .into_any_element()
    }

    fn graph_paths(&self, theme: &Theme, focus: Option<GraphFocus>) -> AnyElement {
        let palette = [
            graph_color(theme.accent),
            graph_color(theme.busy),
            graph_color(theme.success),
            graph_color(theme.warning),
            graph_color(theme.danger),
            graph_color(theme.text_muted),
        ];
        let rows = self.graph.rows.clone();
        let list = self.list.clone();
        canvas(
            |_, _, _| (),
            move |viewport_bounds, _, window, _| {
                let middle = HISTORY_ROW_HEIGHT / 2.0;
                let pass_count = if focus.is_some() { 2 } else { 1 };
                for pass in 0..pass_count {
                    let selected_pass = focus.is_some() && pass == 1;
                    for (color_index, color) in palette.iter().enumerate() {
                        let stroke_width = focus
                            .filter(|_| selected_pass)
                            .map(|focus| {
                                HISTORY_STROKE_WIDTH
                                    + (HISTORY_GRAPH_FOCUSED_STROKE_WIDTH
                                        - HISTORY_STROKE_WIDTH)
                                        * focus.amount
                            })
                            .unwrap_or(HISTORY_STROKE_WIDTH);
                        let mut builder = PathBuilder::stroke(px(stroke_width));
                        let mut has_segments = false;

                        for (index, row) in rows.iter().enumerate() {
                            let Some(row_bounds) = list.bounds_for_item(index) else {
                                continue;
                            };
                            if row_bounds.bottom() < viewport_bounds.top()
                                || row_bounds.top() > viewport_bounds.bottom()
                            {
                                continue;
                            }
                            for segment in row.segments.iter().filter(|segment| {
                                segment.color_id % palette.len() == color_index
                                    && focus.is_none_or(|focus| {
                                        (segment.color_id == focus.color_id) == selected_pass
                                    })
                            }) {
                                has_segments = true;
                                let from_x = lane_x(segment.from_lane);
                                let to_x = lane_x(segment.to_lane);
                                let origin = row_bounds.origin;
                                match segment.shape {
                                SegmentShape::Incoming => {
                                    builder.move_to(point(
                                        origin.x + px(from_x),
                                        origin.y - px(HISTORY_GRAPH_ROW_OVERLAP),
                                    ));
                                    builder.cubic_bezier_to(
                                        point(origin.x + px(to_x), origin.y + px(middle)),
                                        point(origin.x + px(from_x), origin.y + px(middle * 0.55)),
                                        point(origin.x + px(to_x), origin.y + px(middle * 0.55)),
                                    );
                                }
                                SegmentShape::Outgoing => {
                                    builder.move_to(point(
                                        origin.x + px(from_x),
                                        origin.y + px(middle),
                                    ));
                                    builder.cubic_bezier_to(
                                        point(
                                            origin.x + px(to_x),
                                            origin.y
                                                + px(
                                                    HISTORY_ROW_HEIGHT
                                                        + HISTORY_GRAPH_ROW_OVERLAP,
                                                ),
                                        ),
                                        point(
                                            origin.x + px(from_x),
                                            origin.y + px(middle * 1.45),
                                        ),
                                        point(
                                            origin.x + px(to_x),
                                            origin.y + px(middle * 1.45),
                                        ),
                                    );
                                }
                                SegmentShape::Through => {
                                    builder.move_to(point(
                                        origin.x + px(from_x),
                                        origin.y - px(HISTORY_GRAPH_ROW_OVERLAP),
                                    ));
                                    let end = point(
                                        origin.x + px(to_x),
                                        origin.y
                                            + px(HISTORY_ROW_HEIGHT + HISTORY_GRAPH_ROW_OVERLAP),
                                    );
                                    if segment.from_lane == segment.to_lane {
                                        builder.line_to(end);
                                    } else {
                                        builder.cubic_bezier_to(
                                            end,
                                            point(origin.x + px(from_x), origin.y + px(middle)),
                                            point(origin.x + px(to_x), origin.y + px(middle)),
                                        );
                                    }
                                }
                                }
                            }
                        }

                        if has_segments && let Ok(path) = builder.build() {
                            let mut paint_color = *color;
                            if let Some(focus) = focus
                                && !selected_pass
                            {
                                paint_color.a *= 1.0
                                    - (1.0 - HISTORY_GRAPH_UNFOCUSED_OPACITY) * focus.amount;
                            }
                            window.paint_path(path, paint_color);
                        }
                    }
                }
            },
        )
        .absolute()
        .inset_0()
        .into_any_element()
    }

    fn graph_cell(
        &mut self,
        row_index: usize,
        row: GraphRow,
        lane_count: usize,
        focus: Option<GraphFocus>,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let width = graph_width(lane_count);
        let palette = [
            graph_color(theme.accent),
            graph_color(theme.busy),
            graph_color(theme.success),
            graph_color(theme.warning),
            graph_color(theme.danger),
            graph_color(theme.text_muted),
        ];
        let mut color = palette[row.node_color_id % palette.len()];
        let selected = focus.is_some_and(|focus| focus.color_id == row.node_color_id);
        if let Some(focus) = focus
            && !selected
        {
            color.a *= 1.0 - (1.0 - HISTORY_GRAPH_UNFOCUSED_OPACITY) * focus.amount;
        }
        let node_radius = HISTORY_NODE_RADIUS
            + focus
                .filter(|_| selected)
                .map(|focus| focus.amount * 0.75)
                .unwrap_or_default();
        let node_x = lane_x(row.node_lane);
        let node = div()
            .absolute()
            .left(px(node_x - node_radius))
            .top(px(HISTORY_ROW_HEIGHT / 2.0 - node_radius))
            .size(px(node_radius * 2.0))
            .rounded_full()
            .bg(color);
        div()
            .id(("history-graph-cell", row_index))
            .relative()
            .w(px(width))
            .h(px(HISTORY_ROW_HEIGHT))
            .flex_none()
            .on_mouse_move(
                cx.listener(move |this, event: &gpui::MouseMoveEvent, _, cx| {
                    this.update_graph_hover(row_index, event.position, cx);
                }),
            )
            .on_hover(cx.listener(|this, hovered: &bool, _, cx| {
                if !*hovered {
                    this.set_graph_hover(None, cx);
                }
            }))
            .when(row.is_head, |element| {
                element.child(
                    div()
                        .absolute()
                        .left(px(node_x - node_radius - HISTORY_HEAD_RING_PADDING))
                        .top(px(HISTORY_ROW_HEIGHT / 2.0
                            - node_radius
                            - HISTORY_HEAD_RING_PADDING))
                        .size(px((node_radius + HISTORY_HEAD_RING_PADDING) * 2.0))
                        .rounded_full()
                        .border_1()
                        .border_color(color)
                        .bg(theme.bg),
                )
            })
            .child(node)
            .into_any_element()
    }

    fn render_ref(
        reference: GitHistoryRef,
        row_index: usize,
        ref_index: usize,
        theme: &Theme,
    ) -> AnyElement {
        let color = ref_color(&reference, theme);
        let icon = ref_icon(reference.kind);
        let description = ref_description(&reference);
        div()
            .id(SharedString::from(format!(
                "history-ref-{row_index}-{ref_index}"
            )))
            .h(px(16.0))
            .max_w(px(112.0))
            .px(px(5.0))
            .flex_none()
            .flex()
            .items_center()
            .gap(px(2.0))
            .rounded(px(4.0))
            .bg(color.opacity(0.07))
            .text_size(px(10.0))
            .text_color(color.opacity(0.9))
            .child(
                crate::icons::icon(icon)
                    .size(px(10.0))
                    .mt(px(1.0))
                    .text_color(color.opacity(0.78)),
            )
            .child(
                div()
                    .min_w_0()
                    .truncate()
                    .child(SharedString::from(reference.label)),
            )
            .tooltip(move |_, cx| {
                cx.new(|_| HistoryRefTooltip {
                    descriptions: vec![description.clone()],
                })
                .into()
            })
            .tooltip_show_delay(Duration::from_millis(350))
            .into_any_element()
    }

    fn render_ref_area(
        refs: Vec<GitHistoryRef>,
        row_index: usize,
        available_width: f32,
        theme: &Theme,
    ) -> AnyElement {
        let visible_count = visible_ref_count(&refs, available_width);
        let hidden_refs: Vec<_> = refs.iter().skip(visible_count).cloned().collect();
        let hidden_count = hidden_refs.len();
        let hidden_descriptions: Vec<_> = hidden_refs.iter().map(ref_description).collect();

        div()
            .max_w(px(available_width))
            .min_w_0()
            .overflow_hidden()
            .flex()
            .items_center()
            .gap(px(HISTORY_REF_GAP))
            .children(refs.into_iter().take(visible_count).enumerate().map(
                |(ref_index, reference)| Self::render_ref(reference, row_index, ref_index, theme),
            ))
            .when(hidden_count > 0, |element| {
                element.child(
                    div()
                        .id(("history-ref-overflow", row_index))
                        .flex_none()
                        .text_size(px(10.0))
                        .text_color(theme.text_faint)
                        .child(SharedString::from(format!("+{hidden_count}")))
                        .tooltip(move |_, cx| {
                            cx.new(|_| HistoryRefTooltip {
                                descriptions: hidden_descriptions.clone(),
                            })
                            .into()
                        })
                        .tooltip_show_delay(Duration::from_millis(350)),
                )
            })
            .into_any_element()
    }

    fn render_row(
        &mut self,
        index: usize,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if index >= self.commits.len() {
            let theme = Theme::of(cx).clone();
            let has_error = self.error.is_some();
            let label = if self.loading {
                "Loading…"
            } else if has_error {
                "Retry"
            } else {
                "Load more"
            };
            let button = div()
                .id("history-load-older")
                .h(px(28.0))
                .px(px(11.0))
                .flex()
                .items_center()
                .justify_center()
                .gap(px(6.0))
                .rounded(px(7.0))
                .border_1()
                .border_color(theme.border.opacity(0.85))
                .bg(theme.surface_raised.opacity(0.72))
                .text_size(px(11.0))
                .text_color(if self.loading {
                    theme.text_faint
                } else {
                    theme.text_muted
                })
                .when(!self.loading, |element| {
                    element
                        .cursor_pointer()
                        .hover(|style| {
                            style
                                .bg(theme.element_hover)
                                .border_color(theme.border_strong.opacity(0.75))
                                .text_color(theme.text)
                        })
                        .on_click(cx.listener(|this, _, _, cx| this.load_older(cx)))
                })
                .when(!self.loading, |element| {
                    element.child(
                        crate::icons::icon(if has_error {
                            crate::icons::REFRESH
                        } else {
                            crate::icons::ALT_ARROW_DOWN
                        })
                        .size(px(11.0))
                        .flex_none()
                        .text_color(theme.text_faint),
                    )
                })
                .child(SharedString::from(label));
            return div()
                .w_full()
                .h(px(48.0))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .child(button)
                .into_any_element();
        }
        let Some(commit) = self.commits.get(index).cloned() else {
            return gpui::Empty.into_any_element();
        };
        let Some(graph_row) = self.graph.rows.get(index).cloned() else {
            return gpui::Empty.into_any_element();
        };
        let theme = Theme::of(cx).clone();
        let sha = commit.sha.clone();
        let open_commit = commit.clone();
        let copied = self.copied_sha.as_deref() == Some(sha.as_str());
        let commit_subject = if commit.subject.is_empty() {
            "(no subject)".to_string()
        } else {
            commit.subject
        };
        let commit_refs = commit.refs;
        let commit_theme = theme.clone();
        let columns = configured_columns(cx);
        let author_display = configured_author_display(cx);
        let author_name = history_author_name(&commit.author_name);
        let author_initial = history_author_initial(&author_name);
        let avatar_image = self
            .avatar_images
            .get(&commit.author_email.trim().to_ascii_lowercase())
            .cloned();
        let has_avatar = avatar_image.is_some();
        let graph_focus = self.graph_focus(cx);
        let row_is_focused =
            graph_focus.is_some_and(|focus| focus.color_id == graph_row.node_color_id);
        let row_content_opacity = graph_focus
            .filter(|_| !row_is_focused)
            .map(|focus| 1.0 - (1.0 - HISTORY_ROW_UNFOCUSED_OPACITY) * focus.amount)
            .unwrap_or(1.0);
        let focused_row_wash = graph_focus
            .filter(|_| row_is_focused)
            .map(|focus| crate::theme::ink(0.018 * focus.amount));
        let graph_lane_count = self.graph.max_lane_count;

        div()
            .id(("history-row", index))
            .h(px(HISTORY_ROW_HEIGHT))
            .w_full()
            .flex_none()
            .flex()
            .flex_row()
            .items_center()
            .border_b_1()
            .border_color(crate::theme::hairline(0.04))
            .text_size(px(11.0))
            .cursor_pointer()
            .when_some(focused_row_wash, |element, wash| element.bg(wash))
            .hover(|style| style.bg(crate::theme::ink(0.025)))
            // A commit row click opens the commit as its own diff tab (the
            // host — the right pane's surface strip — listens; user request).
            .on_click(cx.listener(move |_, _, _, cx| {
                cx.emit(GitHistoryEvent::OpenCommit(open_commit.clone()));
            }))
            .child(self.graph_cell(index, graph_row, graph_lane_count, graph_focus, &theme, cx))
            .child(
                container_query(move |size, _, _| {
                    let refs_width = ref_area_width(f32::from(size.width));
                    div()
                        .size_full()
                        .flex()
                        .items_center()
                        .gap(px(HISTORY_REF_GAP))
                        .pr(px(8.0))
                        .opacity(row_content_opacity)
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(px(12.0))
                                .text_color(commit_theme.text)
                                .child(SharedString::from(commit_subject.clone())),
                        )
                        .when(!commit_refs.is_empty(), |element| {
                            element.child(Self::render_ref_area(
                                commit_refs.clone(),
                                index,
                                refs_width,
                                &commit_theme,
                            ))
                        })
                })
                .flex_1()
                .min_w(px(HISTORY_COMMIT_SUBJECT_MIN_WIDTH))
                .overflow_hidden(),
            )
            .when(columns.author, |element| {
                element.child(
                    div()
                        .w(px(88.0))
                        .flex_none()
                        .opacity(row_content_opacity)
                        .when(
                            author_display == GitHistoryAuthorDisplay::Avatar,
                            |author| {
                                let tooltip_name = author_name.clone();
                                author.flex().items_center().justify_center().child(
                                    div()
                                        .id(("history-author-avatar", index))
                                        .size(px(20.0))
                                        .flex_none()
                                        .flex()
                                        .items_center()
                                        .justify_center()
                                        .overflow_hidden()
                                        .rounded_full()
                                        .border_1()
                                        .border_color(crate::theme::hairline(0.12))
                                        .bg(crate::theme::wash(0.08))
                                        .when_some(avatar_image, |avatar, image| {
                                            avatar.child(
                                                img(image).size_full().object_fit(ObjectFit::Cover),
                                            )
                                        })
                                        .when(!has_avatar, |avatar| {
                                            avatar
                                                .text_size(px(9.0))
                                                .text_color(theme.text_faint)
                                                .child(author_initial)
                                        })
                                        .tooltip(move |_, cx| {
                                            cx.new(|_| HistoryAuthorTooltip {
                                                name: tooltip_name.clone(),
                                            })
                                            .into()
                                        })
                                        .tooltip_show_delay(Duration::from_millis(300)),
                                )
                            },
                        )
                        .when(author_display == GitHistoryAuthorDisplay::Name, |author| {
                            author
                                .pr(px(8.0))
                                .truncate()
                                .text_color(theme.text_muted)
                                .child(author_name)
                        }),
                )
            })
            .when(columns.date, |element| {
                element.child(
                    div()
                        .w(px(88.0))
                        .flex_none()
                        .truncate()
                        .pr(px(8.0))
                        .text_size(px(10.5))
                        .opacity(row_content_opacity)
                        .text_color(theme.text_muted)
                        .child(SharedString::from(format_date(&commit.authored_at))),
                )
            })
            .when(columns.sha, |element| {
                element.child(
                    div()
                        .id(SharedString::from(format!("history-sha-{index}")))
                        .w(px(68.0))
                        .h(px(24.0))
                        .mr(px(6.0))
                        .flex_none()
                        .flex()
                        .items_center()
                        .rounded(px(4.0))
                        .cursor_pointer()
                        .opacity(row_content_opacity)
                        .hover(|style| style.bg(crate::theme::ink(0.07)))
                        .font_family(theme.font_mono.clone())
                        .text_size(px(10.5))
                        .text_color(if copied {
                            theme.accent
                        } else {
                            theme.text_muted
                        })
                        .on_click(cx.listener(move |this, _, _, cx| {
                            // The sha chip must not ALSO open the commit tab.
                            cx.stop_propagation();
                            this.copy_sha(sha.clone(), cx)
                        }))
                        .child(SharedString::from(if copied {
                            "Copied".to_string()
                        } else {
                            commit.sha.chars().take(7).collect()
                        })),
                )
            })
            .into_any_element()
    }
}

impl Render for GitHistory {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.ensure_loaded(cx);
        let theme = Theme::of(cx).clone();
        let graph_column = graph_width(self.graph.max_lane_count);
        let graph_focus = self.graph_focus(cx);
        let columns = configured_columns(cx);
        let column_menu_position = self.column_menu.get().copied();
        let column_menu = column_menu_position.map(|position| {
            let closing = self.column_menu.closing_since();
            let menu = self.render_column_menu(&theme, cx);
            (position, menu, closing)
        });
        let author_menu_position = self.author_menu.get().copied();
        let author_menu = author_menu_position.map(|position| {
            let closing = self.author_menu.closing_since();
            let menu = self.render_author_menu(&theme, cx);
            (position, menu, closing)
        });

        let body: AnyElement = if self.target_key.is_none() {
            div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .text_size(px(12.0))
                .text_color(theme.text_faint)
                .child("No repository selected")
                .into_any_element()
        } else if self.loading && self.commits.is_empty() {
            div()
                .flex_1()
                .flex()
                .flex_col()
                .items_center()
                .justify_center()
                .gap(px(8.0))
                .child(crate::loaders::gradient_spinner(
                    "history-loading",
                    &theme,
                    3.0,
                    cx.entity_id(),
                    cx,
                ))
                .child(
                    div()
                        .text_size(px(12.0))
                        .text_color(theme.text_faint)
                        .child("Loading history…"),
                )
                .into_any_element()
        } else if self.commits.is_empty() {
            let message = self
                .error
                .clone()
                .unwrap_or_else(|| SharedString::from("No commits found"));
            div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .px(px(20.0))
                .text_size(px(12.0))
                .text_color(if self.error.is_some() {
                    theme.warning
                } else {
                    theme.text_faint
                })
                .child(message)
                .into_any_element()
        } else {
            div()
                .relative()
                .flex_1()
                .min_h_0()
                .child(self.graph_paths(&theme, graph_focus))
                .child(
                    list(self.list.clone(), cx.processor(Self::render_row))
                        .size_full()
                        .with_sizing_behavior(gpui::ListSizingBehavior::Auto),
                )
                .into_any_element()
        };

        div()
            .size_full()
            .flex()
            .flex_col()
            .when_some(self.fetch_error.clone(), |element, error| {
                element.child(
                    div()
                        .h(px(28.0))
                        .flex_none()
                        .flex()
                        .items_center()
                        .px(px(8.0))
                        .border_b_1()
                        .border_color(theme.danger.opacity(0.16))
                        .bg(theme.danger.opacity(0.05))
                        .truncate()
                        .text_size(px(11.0))
                        .text_color(theme.danger_muted)
                        .child(SharedString::from(format!("Fetch failed: {error}"))),
                )
            })
            .when_some(
                self.error.clone().filter(|_| !self.commits.is_empty()),
                |element, error| {
                    element.child(
                        div()
                            .h(px(28.0))
                            .flex_none()
                            .flex()
                            .items_center()
                            .px(px(8.0))
                            .border_b_1()
                            .border_color(theme.danger.opacity(0.16))
                            .bg(theme.danger.opacity(0.05))
                            .truncate()
                            .text_size(px(11.0))
                            .text_color(theme.danger_muted)
                            .child(error),
                    )
                },
            )
            .when(!self.commits.is_empty(), |element| {
                element.child(
                    div()
                        .id("history-column-header")
                        .group("history-column-header")
                        .relative()
                        .h(px(24.0))
                        .flex_none()
                        .flex()
                        .items_center()
                        .border_b_1()
                        .border_color(crate::theme::hairline(0.06))
                        .text_size(px(9.5))
                        .text_color(theme.text_faint)
                        .child(div().w(px(graph_column)).flex_none())
                        .child(div().flex_1().min_w(px(80.0)).child("Commit"))
                        .when(columns.author, |header| {
                            header.child(
                                div()
                                    .id("history-author-header")
                                    .w(px(88.0))
                                    .h_full()
                                    .flex_none()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .on_mouse_down(
                                        gpui::MouseButton::Right,
                                        cx.listener(
                                            |this, event: &gpui::MouseDownEvent, window, cx| {
                                                window.prevent_default();
                                                cx.stop_propagation();
                                                this.open_author_menu(event.position, cx);
                                            },
                                        ),
                                    )
                                    .child("Author"),
                            )
                        })
                        .when(columns.date, |header| {
                            header.child(div().w(px(88.0)).flex_none().child("Date"))
                        })
                        .when(columns.sha, |header| {
                            header.child(div().w(px(74.0)).flex_none().child("SHA"))
                        })
                        .child(
                            div()
                                .id("history-columns-button")
                                .absolute()
                                .right(px(3.0))
                                .top(px(2.0))
                                .size(px(20.0))
                                .flex()
                                .items_center()
                                .justify_center()
                                .rounded(px(5.0))
                                .cursor_pointer()
                                .opacity(0.0)
                                .group_hover("history-column-header", |style| style.opacity(1.0))
                                .when(self.column_menu.is_open(), |button| button.opacity(1.0))
                                .hover(|style| style.bg(crate::theme::ink(0.08)))
                                .on_mouse_down(
                                    gpui::MouseButton::Left,
                                    cx.listener(
                                        |this, event: &gpui::MouseDownEvent, window, cx| {
                                            window.prevent_default();
                                            cx.stop_propagation();
                                            this.open_column_menu(event.position, cx);
                                        },
                                    ),
                                )
                                .child(
                                    crate::icons::icon(crate::icons::CHECKLIST)
                                        .size(px(12.0))
                                        .text_color(theme.text_muted),
                                ),
                        ),
                )
            })
            .child(body)
            .when_some(column_menu, |element, (position, menu, closing)| {
                element.child(popover::menu_at(
                    "history-columns-menu",
                    position,
                    menu,
                    closing,
                ))
            })
            .when_some(author_menu, |element, (position, menu, closing)| {
                element.child(popover::menu_at(
                    "history-author-menu",
                    position,
                    menu,
                    closing,
                ))
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn commit(sha: &str, parents: &[&str]) -> GitHistoryCommit {
        GitHistoryCommit {
            sha: sha.into(),
            parent_shas: parents.iter().map(|value| (*value).into()).collect(),
            subject: sha.into(),
            author_name: "Test".into(),
            author_email: "test@example.com".into(),
            authored_at: "2026-08-12T12:00:00Z".into(),
            refs: Vec::new(),
        }
    }

    #[test]
    fn author_avatar_fallback_uses_the_first_visible_initial() {
        assert_eq!(history_author_name(""), SharedString::from("Unknown"));
        assert_eq!(history_author_initial("  josé"), SharedString::from("J"));
        assert_eq!(history_author_initial("   "), SharedString::from("?"));
    }

    #[test]
    fn github_avatar_payload_decodes_into_a_gpui_image() {
        let encoded = base64::engine::general_purpose::STANDARD.encode(b"\xff\xd8\xffpayload");
        let image = decode_history_avatar(&encoded).expect("jpeg payload");
        assert_eq!(image.format, ImageFormat::Jpeg);
        assert!(decode_history_avatar("not base64").is_none());
    }

    #[test]
    fn graph_splits_and_rejoins_merge_lanes() {
        let commits = vec![
            commit("merge", &["main", "feature"]),
            commit("main", &["base"]),
            commit("feature", &["base"]),
            commit("base", &[]),
        ];
        let graph = layout_graph(&commits, Some("merge"));
        assert_eq!(graph.rows.len(), commits.len());
        assert!(graph.max_lane_count >= 2);
        assert!(graph.rows[0].is_head);
        assert_eq!(graph.rows[0].segments.len(), 2);
        assert_eq!(graph.rows[3].segments.len(), 2);
        assert_eq!(graph.rows[3].node_lane, 0);
    }

    #[test]
    fn appending_older_commits_preserves_the_loaded_prefix_layout() {
        let prefix = vec![commit("tip", &["parent"]), commit("parent", &["root"])];
        let before = layout_graph(&prefix, Some("tip"));
        let mut all = prefix.clone();
        all.push(commit("root", &[]));
        let after = layout_graph(&all, Some("tip"));
        assert_eq!(before.rows, after.rows[..before.rows.len()]);
    }

    #[test]
    fn graph_palette_only_reduces_saturation() {
        let source = gpui::hsla(0.62, 0.8, 0.55, 0.9);
        let muted = graph_color(source);
        assert_eq!(muted.h, source.h);
        assert_eq!(muted.l, source.l);
        assert_eq!(muted.a, source.a);
        assert!((muted.s - source.s * HISTORY_GRAPH_SATURATION).abs() < f32::EPSILON);
    }

    #[test]
    fn graph_hover_detects_vertical_and_curved_paths() {
        let vertical = GraphRow {
            sha: "vertical".into(),
            node_lane: 0,
            node_color_id: 1,
            segments: vec![GraphSegment {
                from_lane: 1,
                to_lane: 1,
                color_id: 7,
                shape: SegmentShape::Through,
            }],
            is_head: false,
        };
        assert_eq!(hovered_graph_path(&vertical, lane_x(1), 5.0), Some(7));

        let curved_segment = GraphSegment {
            from_lane: 0,
            to_lane: 1,
            color_id: 9,
            shape: SegmentShape::Outgoing,
        };
        let middle = HISTORY_ROW_HEIGHT / 2.0;
        let curve_x = cubic_coordinate(lane_x(0), lane_x(0), lane_x(1), lane_x(1), 0.5);
        let curve_y = cubic_coordinate(
            middle,
            middle * 1.45,
            middle * 1.45,
            HISTORY_ROW_HEIGHT + HISTORY_GRAPH_ROW_OVERLAP,
            0.5,
        );
        let curved = GraphRow {
            sha: "curved".into(),
            node_lane: 0,
            node_color_id: 1,
            segments: vec![curved_segment],
            is_head: false,
        };
        assert_eq!(hovered_graph_path(&curved, curve_x, curve_y), Some(9));
    }

    #[test]
    fn graph_hover_prefers_the_node_and_ignores_empty_space() {
        let row = GraphRow {
            sha: "node".into(),
            node_lane: 1,
            node_color_id: 11,
            segments: vec![GraphSegment {
                from_lane: 0,
                to_lane: 1,
                color_id: 4,
                shape: SegmentShape::Incoming,
            }],
            is_head: false,
        };
        assert_eq!(
            hovered_graph_path(&row, lane_x(1), HISTORY_ROW_HEIGHT / 2.0),
            Some(11)
        );
        assert_eq!(hovered_graph_path(&row, graph_width(4) - 1.0, 2.0), None);
    }

    #[test]
    fn ref_badges_expand_with_the_available_width() {
        let reference = |label: &str| GitHistoryRef {
            kind: GitHistoryRefKind::Branch,
            label: label.into(),
        };
        let refs = vec![reference("main"), reference("tag"), reference("origin")];
        assert_eq!(visible_ref_count(&[], 100.0), 0);
        assert_eq!(visible_ref_count(&refs, 70.0), 1);
        assert_eq!(visible_ref_count(&refs, 115.0), 2);
        assert_eq!(visible_ref_count(&refs, 200.0), 3);
    }

    #[test]
    fn ref_badges_preserve_overflow_when_the_first_badge_is_too_wide() {
        let reference = |label: &str| GitHistoryRef {
            kind: GitHistoryRefKind::Branch,
            label: label.into(),
        };
        let refs = vec![
            reference("feature/accessibility-polish"),
            reference("main"),
            reference("origin/main"),
            reference("upstream/main"),
            reference("v0.1.53"),
            reference("HEAD"),
        ];

        assert_eq!(visible_ref_count(&refs, 120.0), 0);
    }

    #[test]
    fn ref_area_preserves_subject_space_and_caps_at_forty_five_percent() {
        assert_eq!(ref_area_width(80.0), 0.0);
        assert!((ref_area_width(200.0) - 86.4).abs() < 0.001);
        assert!((ref_area_width(400.0) - 176.4).abs() < 0.001);
    }

    #[test]
    fn ref_tooltip_describes_each_reference_kind() {
        let reference = |kind: GitHistoryRefKind, label: &str| GitHistoryRef {
            kind,
            label: label.into(),
        };
        assert_eq!(
            ref_description(&reference(GitHistoryRefKind::Branch, "main")),
            "Branch: main"
        );
        assert_eq!(
            ref_description(&reference(GitHistoryRefKind::Remote, "origin/main")),
            "Remote branch: origin/main"
        );
        assert_eq!(
            ref_description(&reference(GitHistoryRefKind::Tag, "v0.1.52")),
            "Tag: v0.1.52"
        );
    }
}
