//! Session-owned, equally ranked panels. Position belongs to a panel; selection
//! belongs to its tab bar. Moving a tab never reorders either panel.
use super::*;
use gpui::point;
#[cfg(feature = "browser-fixture")]
use gpui_base::ElementExt as _;
use instrument_strip::INSTRUMENT_STRIP;
use std::collections::{HashMap, HashSet};
mod device_picker;
mod instrument_strip;
#[cfg(all(test, feature = "dev-tab-layout"))]
mod instrument_strip_tests;
mod recovery;
mod sidebar_chat_drop;
mod tab_metadata;
#[cfg(feature = "appshots-fixture")]
mod attention_import_fixture;
mod window_subscriptions;
mod window_transfer;
mod window_drag;
mod window_drop_target;
mod window_preview;
mod shared_header;
#[cfg(feature = "appshots-fixture")]
mod shared_header_fixture;
#[cfg(feature = "appshots-fixture")]
mod tab_insertion_fixture;
#[cfg(test)]
mod panel_render_cost_tests;
#[cfg(test)]
mod shortcut_parity_tests;
#[cfg(test)]
mod sidebar_chat_drop_tests;
#[cfg(test)]
mod window_transfer_tests;
#[cfg(test)]
mod window_drag_tests;
#[cfg(test)]
mod window_rejoin_tests;
#[cfg(test)]
mod shared_header_tests;
#[cfg(test)]
mod tab_insertion_tests;
use tab_metadata::TabContext;
pub(super) use tab_metadata::TabAttention;

pub(super) const ACTION_BAR_HEIGHT: f32 = 36.0;
const GUTTER: f32 = 8.0;
const PANEL_MIN: f32 = 220.0;
const PANEL_TAB_HEIGHT: f32 = 32.0;
// Preserve the native titlebar's 21px content centerline. The selected tab's
// surface extends through the lower clearance and joins the panel body.
const PANEL_HEADER_HEIGHT: f32 = Theme::TITLEBAR_HEIGHT + Theme::TITLEBAR_TOP_PAD;
const STACKED_CLEARANCE: f32 = (PANEL_HEADER_HEIGHT - PANEL_TAB_HEIGHT) / 2.0;
const STACKED_HEADER_HEIGHT: f32 = PANEL_TAB_HEIGHT + STACKED_CLEARANCE;
const TAB_SHOULDER: f32 = 8.0;
/// The new-tab button and its gap, when it follows the last tab.
const INLINE_ADD_WIDTH: f32 = 27.0;

// A stacked chat still needs its header, actions, composer and model/status
// controls. Height-based limits keep that bottom stack usable.
const PANEL_MIN_HEIGHT: f32 = 320.0;
const THREE_PANEL_MIN_HEIGHT: f32 = 360.0;

fn stacked_panel_limit(window_height: f32) -> usize {
    let available = (window_height - GUTTER).max(0.0);
    if available >= THREE_PANEL_MIN_HEIGHT * 3.0 + GUTTER * 2.0 {
        3
    } else if available >= PANEL_MIN_HEIGHT * 2.0 + GUTTER {
        2
    } else {
        1
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum PanelEdge {
    Left,
    Right,
    Top,
    Bottom,
}
impl PanelEdge {
    fn axis(self) -> SplitAxis {
        match self {
            Self::Left | Self::Right => SplitAxis::Horizontal,
            Self::Top | Self::Bottom => SplitAxis::Vertical,
        }
    }
    fn after(self) -> bool {
        matches!(self, Self::Right | Self::Bottom)
    }
    fn along(axis: SplitAxis, after: bool) -> Self {
        match (axis, after) {
            (SplitAxis::Horizontal, false) => Self::Left,
            (SplitAxis::Horizontal, true) => Self::Right,
            (SplitAxis::Vertical, false) => Self::Top,
            (SplitAxis::Vertical, true) => Self::Bottom,
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
            Self::Top => "top",
            Self::Bottom => "bottom",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct PanelFrame {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    header_height: f32,
}
impl PanelFrame {
    fn lerp(self, to: Self, t: f32) -> Self {
        Self {
            x: motion::lerp(self.x, to.x, t),
            y: motion::lerp(self.y, to.y, t),
            width: motion::lerp(self.width, to.width, t),
            height: motion::lerp(self.height, to.height, t),
            header_height: motion::lerp(self.header_height, to.header_height, t),
        }
    }
    fn collapsed(self, edge: PanelEdge) -> Self {
        match edge {
            PanelEdge::Left => Self { width: 0.0, ..self },
            PanelEdge::Right => Self {
                x: self.x + self.width,
                width: 0.0,
                ..self
            },
            PanelEdge::Top => Self {
                height: 0.0,
                ..self
            },
            PanelEdge::Bottom => Self {
                y: self.y + self.height,
                height: 0.0,
                ..self
            },
        }
    }
}

fn panel_tab_width(width: f32, count: usize) -> f32 {
    // Chat metadata, tab type and split direction never choose a different
    // resting size. Compress only when the actual tabs exhaust this strip;
    // beyond the minimum, horizontal scrolling retains readable labels.
    let count = count.max(1) as f32;
    let available = (width - 4.0 - TAB_SHOULDER - 3.0 * (count - 1.0)).max(0.0);
    (available / count).clamp(112.0, 240.0)
}

#[derive(Default)]
struct PanelHeaderState {
    hovered: bool,
    controls_hovered: bool,
    expand_hovered: bool,
    controls_visible: bool,
}

struct TabContextFades(motion::HoverFades);
impl Default for TabContextFades {
    fn default() -> Self {
        Self(motion::HoverFades::with_spec(motion::MotionSpec::new(
            180,
            motion::EASE_OUT_QUINT,
        )))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(super) enum PanelTab {
    Chat(String),
    Draft(u64),
    New(u64),
    Surface {
        owner: String,
        surface: RightSurface,
    },
    Files(String),
    FileTree(u64),
    Terminal(u64),
    TerminalDock(String),
    Empty,
}

#[derive(Clone, Debug)]
pub(super) struct WorkspacePanel {
    pub id: u64,
    pub tabs: Vec<PanelTab>,
    pub active: usize,
    pub share: f32,
}
impl WorkspacePanel {
    pub(super) fn selected(&self) -> Option<&PanelTab> {
        self.tabs.get(self.active)
    }
    fn without_tab(&self, tab: &PanelTab) -> Self {
        let mut projected = self.clone();
        let selected = self.selected().filter(|selected| *selected != tab);
        let index = self
            .tabs
            .iter()
            .position(|candidate| candidate == tab)
            .unwrap_or(0);
        projected.tabs.retain(|candidate| candidate != tab);
        projected.active = selected
            .and_then(|selected| {
                projected
                    .tabs
                    .iter()
                    .position(|candidate| candidate == selected)
            })
            .unwrap_or(
                index
                    .saturating_sub(1)
                    .min(projected.tabs.len().saturating_sub(1)),
            );
        projected
    }
}

/// What a shortcut shows or hides without closing it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum WorkspaceTool {
    Terminal,
    Files,
    Changes,
}

#[derive(Clone, Debug)]
pub(super) struct WorkspaceLayout {
    pub panels: Vec<WorkspacePanel>,
    pub axis: SplitAxis,
    pub focused: u64,
    pub expanded: Option<u64>,
    pub(super) next_id: u64,
    pub(super) last_selected: Option<Option<String>>,
    pub(super) imported: HashSet<PanelTab>,
    pub(super) hidden_tools: Vec<(usize, u64, usize, PanelTab)>,
    pub(super) stack_limit: usize,
}
impl Default for WorkspaceLayout {
    fn default() -> Self {
        Self {
            panels: vec![WorkspacePanel {
                id: 0,
                tabs: vec![],
                active: 0,
                share: 1.0,
            }],
            focused: 0,
            axis: SplitAxis::Horizontal,
            expanded: None,
            next_id: 1,
            last_selected: None,
            imported: HashSet::new(),
            hidden_tools: Vec::new(),
            stack_limit: 2,
        }
    }
}
impl WorkspaceLayout {
    /// One panel keeps its own tab row. Once split, the panels share the strip.
    /// An expanded panel is still part of a split: the strip is how you reach
    /// the others.
    fn uses_strip(&self) -> bool {
        INSTRUMENT_STRIP && self.panels.len() > 1
    }

    /// Expansion changes the visible header arrangement, never stored panels.
    fn header_panel_count(&self) -> usize {
        if self.expanded.is_some_and(|id| self.panel(id).is_some()) {
            1
        } else {
            self.panels.len()
        }
    }

    fn gap(&self) -> f32 {
        if self.axis == SplitAxis::Vertical {
            STACKED_CLEARANCE
        } else {
            GUTTER
        }
    }

    fn can_add_panel(&self, axis: SplitAxis) -> bool {
        axis == SplitAxis::Horizontal || self.panels.len() < self.stack_limit
    }

    fn fit_stacked_panels(&mut self, height: f32) {
        self.stack_limit = stacked_panel_limit(height);
        if self.axis != SplitAxis::Vertical {
            return;
        }
        if self.panels.len() > self.stack_limit {
            let overflow = self.panels.split_off(self.stack_limit);
            let target = self.panels.last_mut().unwrap();
            for panel in overflow {
                let offset = target.tabs.len();
                if self.focused == panel.id {
                    self.focused = target.id;
                    if !panel.tabs.is_empty() {
                        target.active = offset + panel.active;
                    }
                }
                if self.expanded == Some(panel.id) {
                    self.expanded = Some(target.id);
                }
                for (_, panel_id, index, _) in &mut self.hidden_tools {
                    if *panel_id == panel.id {
                        *panel_id = target.id;
                        *index += offset;
                    }
                }
                target.tabs.extend(panel.tabs);
            }
            self.equalize();
        }
        let minimum = if self.panels.len() >= 3 {
            THREE_PANEL_MIN_HEIGHT
        } else {
            PANEL_MIN_HEIGHT
        };
        let available =
            (height - GUTTER - self.gap() * self.panels.len().saturating_sub(1) as f32).max(1.0);
        if self
            .panels
            .iter()
            .any(|panel| panel.share * available < minimum)
        {
            self.equalize();
        }
    }
    fn frames(&self, width: f32, height: f32) -> HashMap<u64, PanelFrame> {
        let visible: Vec<_> = self
            .panels
            .iter()
            .filter(|p| self.expanded.is_none_or(|id| id == p.id))
            .collect();
        let horizontal = self.axis == SplitAxis::Horizontal;
        let count = visible.len();
        let extent = if horizontal { width } else { height };
        let available = (extent - self.gap() * visible.len().saturating_sub(1) as f32).max(1.0);
        let mut cursor = 0.0;
        visible
            .into_iter()
            .map(|panel| {
                let span = if self.expanded.is_some() || count == 1 {
                    extent
                } else {
                    (available * panel.share).max(if horizontal {
                        PANEL_MIN
                    } else {
                        if count >= 3 {
                            THREE_PANEL_MIN_HEIGHT
                        } else {
                            PANEL_MIN_HEIGHT
                        }
                    })
                };
                let frame = if horizontal {
                    PanelFrame {
                        x: cursor,
                        y: 0.0,
                        width: span,
                        height,
                        header_height: if self.uses_strip() {
                            0.0
                        } else {
                            PANEL_HEADER_HEIGHT
                        },
                    }
                } else {
                    PanelFrame {
                        x: 0.0,
                        y: cursor,
                        width,
                        height: span,
                        header_height: if self.uses_strip() {
                            0.0
                        } else if cursor < 1.0 {
                            PANEL_HEADER_HEIGHT
                        } else {
                            STACKED_HEADER_HEIGHT
                        },
                    }
                };
                cursor += span + self.gap();
                (panel.id, frame)
            })
            .collect()
    }
    fn panel(&self, id: u64) -> Option<&WorkspacePanel> {
        self.panels.iter().find(|p| p.id == id)
    }
    fn panel_mut(&mut self, id: u64) -> Option<&mut WorkspacePanel> {
        self.panels.iter_mut().find(|p| p.id == id)
    }
    pub(super) fn location(&self, tab: &PanelTab) -> Option<(u64, usize)> {
        self.panels
            .iter()
            .find_map(|p| p.tabs.iter().position(|t| t == tab).map(|i| (p.id, i)))
    }
    fn neighbor(&self, id: u64, right: bool) -> Option<u64> {
        let i = self.panels.iter().position(|p| p.id == id)?;
        let next = if right {
            i.checked_add(1)?
        } else {
            i.checked_sub(1)?
        };
        self.panels.get(next).map(|p| p.id)
    }
    /// The panel after or before `id`, wrapping past either end.
    fn cycled(&self, id: u64, forward: bool) -> Option<u64> {
        let len = self.panels.len();
        let i = self.panels.iter().position(|p| p.id == id)?;
        let next = if forward { i + 1 } else { i + len - 1 } % len;
        Some(self.panels[next].id).filter(|next| *next != id)
    }
    fn direction(&self, direction: chat_split::PaneDirection) -> Option<bool> {
        use chat_split::PaneDirection::*;
        match (self.axis, direction) {
            (SplitAxis::Horizontal, Left) | (SplitAxis::Vertical, Up) => Some(false),
            (SplitAxis::Horizontal, Right) | (SplitAxis::Vertical, Down) => Some(true),
            _ => None,
        }
    }
    pub(super) fn add_panel(&mut self, after: u64) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        let at = self
            .panels
            .iter()
            .position(|p| p.id == after)
            .map_or(self.panels.len(), |i| i + 1);
        self.panels.insert(
            at,
            WorkspacePanel {
                id,
                tabs: vec![],
                active: 0,
                share: 1.0,
            },
        );
        self.focused = id;
        self.expanded = None;
        self.equalize();
        id
    }
    fn equalize(&mut self) {
        let share = 1.0 / self.panels.len() as f32;
        for p in &mut self.panels {
            p.share = share;
        }
    }
    fn insert(&mut self, panel: u64, tab: PanelTab) {
        if let Some((id, ix)) = self.location(&tab) {
            self.panel_mut(id).unwrap().active = ix;
            self.focused = id;
        } else if let Some(p) = self.panel_mut(panel) {
            p.tabs.retain(|t| *t != PanelTab::Empty);
            p.active = p.active.min(p.tabs.len().saturating_sub(1));
            if !matches!(tab, PanelTab::New(_)) && matches!(p.selected(), Some(PanelTab::New(_))) {
                p.tabs[p.active] = tab;
            } else {
                p.tabs.push(tab);
                p.active = p.tabs.len() - 1;
            }
            self.focused = panel;
        }
    }
    fn reorder_panel(&mut self, id: u64, right: bool) -> bool {
        let Some(other) = self.neighbor(id, right) else {
            return false;
        };
        let a = self.panels.iter().position(|p| p.id == id).unwrap();
        let b = self.panels.iter().position(|p| p.id == other).unwrap();
        self.panels.swap(a, b);
        true
    }
    fn move_tab(&mut self, from: u64, tab: &PanelTab, to: u64, before: Option<usize>) -> bool {
        if self.panel(to).is_none() {
            return false;
        }
        let Some(source) = self.panel_mut(from) else {
            return false;
        };
        let Some(ix) = source.tabs.iter().position(|t| t == tab) else {
            return false;
        };
        let selected = source.selected().cloned();
        let moved = source.tabs.remove(ix);
        source.active = selected
            .as_ref()
            .and_then(|s| source.tabs.iter().position(|t| t == s))
            .unwrap_or(
                ix.saturating_sub(1)
                    .min(source.tabs.len().saturating_sub(1)),
            );
        let target = self.panel_mut(to).unwrap();
        let at = before
            .map(|at| if from == to && at > ix { at - 1 } else { at })
            .unwrap_or(target.tabs.len())
            .min(target.tabs.len());
        target.tabs.insert(at, moved);
        target.active = at;
        self.focused = to;
        // Keep the empty source panel available as a drop target.
        true
    }

    fn can_split_tab(&self, from: u64, tab: &PanelTab, beside: u64) -> bool {
        self.panel(beside).is_some()
            && self.panel(from).is_some_and(|source| {
                source.tabs.contains(tab) && (from != beside || source.tabs.len() > 1)
            })
    }

    fn can_split_at(&self, from: u64, tab: &PanelTab, beside: u64, edge: PanelEdge) -> bool {
        self.can_split_tab(from, tab, beside)
            && (edge.axis() == SplitAxis::Horizontal
                || self.panels.len() + 1
                    - usize::from(self.panel(from).is_some_and(|panel| panel.tabs.len() == 1))
                    <= self.stack_limit)
    }

    fn split_drop_target(
        &self,
        from: u64,
        tab: &PanelTab,
        pointer: Point<Pixels>,
        bounds: &HashMap<u64, gpui::Bounds<Pixels>>,
        active: Option<(u64, PanelEdge)>,
    ) -> Option<(u64, PanelEdge)> {
        let panels: Vec<_> = self
            .panels
            .iter()
            .filter(|panel| self.expanded.is_none_or(|expanded| expanded == panel.id))
            .filter_map(|panel| bounds.get(&panel.id).map(|rect| (panel.id, *rect)))
            .collect();
        let header_height = |rect: gpui::Bounds<Pixels>| {
            if self.uses_strip() {
                0.0
            } else if self.axis == SplitAxis::Vertical
                && self.expanded.is_none()
                && panels
                    .first()
                    .is_some_and(|(_, first)| rect.top() > first.top())
            {
                STACKED_HEADER_HEIGHT
            } else {
                PANEL_HEADER_HEIGHT
            }
        };
        if self.axis == SplitAxis::Vertical {
            if let Some((panel, PanelEdge::Bottom)) = active {
                if let Some(pair) = panels.windows(2).find(|pair| pair[0].0 == panel) {
                    let seam = (pair[0].1.bottom() + pair[1].1.top()) / 2.0;
                    if (pointer.y - seam).abs() <= px(4.0)
                        && pointer.x >= pair[0].1.left()
                        && pointer.x <= pair[0].1.right()
                        && self.can_split_tab(from, tab, panel)
                    {
                        return active;
                    }
                }
            }
        }
        // Tab centers remain transfer/reordering targets. The strip stays
        // outside the content border at every row, not inside the panel body.
        if panels.iter().any(|(_, rect)| {
            pointer.x >= rect.left()
                && pointer.x <= rect.right()
                && pointer.y >= rect.top()
                && pointer.y < rect.top() + px(header_height(*rect))
        }) {
            return None;
        }
        let body = |mut rect: gpui::Bounds<Pixels>| {
            let height = px(header_height(rect));
            rect.origin.y += height;
            rect.size.height = (rect.size.height - height).max(px(0.0));
            rect
        };
        let main = |p: Point<Pixels>, axis| {
            f32::from(if axis == SplitAxis::Horizontal {
                p.x
            } else {
                p.y
            })
        };
        let start = |r: gpui::Bounds<Pixels>, axis| main(r.origin, axis);
        let end = |r: gpui::Bounds<Pixels>, axis| main(r.bottom_right(), axis);
        let center = |r: gpui::Bounds<Pixels>, axis| main(r.center(), axis);
        let cross_inside = |r: gpui::Bounds<Pixels>, axis| {
            if axis == SplitAxis::Horizontal {
                pointer.y >= r.top() && pointer.y <= r.bottom()
            } else {
                pointer.x >= r.left() && pointer.x <= r.right()
            }
        };
        let band = |r: gpui::Bounds<Pixels>, axis| {
            ((end(r, axis) - start(r, axis)) * 0.2).clamp(40.0, 80.0)
        };
        let mut candidate = None;
        // Both edges of a seam have a single owner. Frozen rectangles make
        // this independent of the animated preview and its changing axis.
        for pair in panels.windows(2) {
            let (left, a) = pair[0];
            let (right, b) = pair[1];
            let a = body(a);
            let b = body(b);
            let at = main(pointer, self.axis);
            if cross_inside(a, self.axis)
                && cross_inside(b, self.axis)
                && at >= end(a, self.axis) - band(a, self.axis)
                && at <= start(b, self.axis) + band(b, self.axis)
            {
                candidate = if self.can_split_tab(from, tab, left) {
                    Some((left, PanelEdge::along(self.axis, true)))
                } else if self.can_split_tab(from, tab, right) {
                    Some((right, PanelEdge::along(self.axis, false)))
                } else {
                    None
                };
                if candidate.is_some() {
                    break;
                }
            }
        }
        let mut closest = f32::INFINITY;
        for (panel, rect) in &panels {
            if !self.can_split_tab(from, tab, *panel) {
                continue;
            }
            let r = body(*rect);
            for edge in [
                PanelEdge::Left,
                PanelEdge::Right,
                PanelEdge::Top,
                PanelEdge::Bottom,
            ] {
                let axis = edge.axis();
                let at = main(pointer, axis);
                let distance = if edge.after() {
                    end(r, axis) - at
                } else {
                    at - start(r, axis)
                };
                let zone = band(r, axis);
                let cross_axis = if axis == SplitAxis::Horizontal {
                    SplitAxis::Vertical
                } else {
                    SplitAxis::Horizontal
                };
                // Corners do not choose an orientation. Each edge has an
                // unambiguous middle strip, as in Arc's split targeting.
                let cross = main(pointer, cross_axis);
                let inset =
                    band(r, cross_axis).min((end(r, cross_axis) - start(r, cross_axis)) * 0.25);
                if distance >= -GUTTER
                    && distance <= zone
                    && cross >= start(r, cross_axis) + inset
                    && cross <= end(r, cross_axis) - inset
                    && distance / zone < closest
                {
                    closest = distance / zone;
                    // Preserve the canonical seam owner on the current axis.
                    if candidate.is_none() || axis != self.axis {
                        candidate = Some((*panel, edge));
                    }
                }
            }
        }
        if let Some((panel, edge)) =
            active.filter(|(panel, _)| self.can_split_tab(from, tab, *panel))
        {
            if let Some(index) = panels.iter().position(|(id, _)| *id == panel) {
                let rect = body(panels[index].1);
                let axis = edge.axis();
                let at = main(pointer, axis);
                let previous = if axis == self.axis {
                    index.checked_sub(1).map(|i| body(panels[i].1))
                } else {
                    None
                };
                let next = if axis == self.axis {
                    panels.get(index + 1).map(|(_, r)| body(*r))
                } else {
                    None
                };
                let (low, high) = if edge.after() {
                    (
                        center(rect, axis),
                        next.map_or(end(rect, axis) + GUTTER, |r| center(r, axis)),
                    )
                } else {
                    (
                        previous.map_or(start(rect, axis) - GUTTER, |r| center(r, axis)),
                        center(rect, axis),
                    )
                };
                let changing_axis = candidate.is_some_and(|(_, target)| target.axis() != axis);
                if !changing_axis && cross_inside(rect, axis) && at > low && at < high {
                    return Some((panel, edge));
                }
            }
        }
        candidate
    }

    fn split_tab(
        &mut self,
        from: u64,
        tab: &PanelTab,
        beside: u64,
        edge: PanelEdge,
    ) -> Option<u64> {
        if !self.can_split_at(from, tab, beside, edge) {
            return None;
        }
        self.axis = edge.axis();
        let to = self.add_panel(beside);
        if !edge.after() {
            self.reorder_panel(to, false);
        }
        self.move_tab(from, tab, to, None);
        // Tearing out the last tab moves its panel without leaving an empty tile.
        if self
            .panel(from)
            .is_some_and(|source| source.tabs.is_empty())
        {
            self.panels.retain(|panel| panel.id != from);
            self.equalize();
        }
        Some(to)
    }

    fn remove_tab(&mut self, panel: u64, tab: &PanelTab) {
        if let Some(p) = self.panel_mut(panel) {
            let selected = p.selected().cloned();
            p.tabs.retain(|t| t != tab);
            p.active = selected
                .and_then(|s| p.tabs.iter().position(|t| *t == s))
                .unwrap_or(p.active.min(p.tabs.len().saturating_sub(1)));
        }
    }
}

const PANEL_SPLIT_MOTION: motion::MotionSpec = motion::MotionSpec::new(240, motion::EASE_OUT_QUINT);

#[derive(Default)]
struct PanelSplitReveal {
    active: bool,
    tween: Option<WidthTween>,
}
impl PanelSplitReveal {
    fn value(&self, now: std::time::Instant, reduced: bool) -> f32 {
        let target = if self.active { 1.0 } else { 0.0 };
        let Some(tween) = self.tween.filter(|_| !reduced) else {
            return target;
        };
        let duration = PANEL_SPLIT_MOTION
            .total()
            .mul_f32(motion::speed_scale())
            .as_secs_f32();
        let raw = now.saturating_duration_since(tween.started).as_secs_f32() / duration;
        motion::lerp(tween.from, tween.to, PANEL_SPLIT_MOTION.progress(raw))
    }
    fn retarget(&mut self, active: bool, reduced: bool, now: std::time::Instant) {
        let from = self.value(now, reduced);
        self.active = active;
        self.tween = Some(WidthTween {
            from,
            to: if active { 1.0 } else { 0.0 },
            started: now,
        });
    }
    fn animating(&self, now: std::time::Instant, reduced: bool) -> bool {
        !reduced
            && self.tween.is_some_and(|tween| {
                (tween.from - tween.to).abs() > f32::EPSILON
                    && now.saturating_duration_since(tween.started)
                        < PANEL_SPLIT_MOTION.total().mul_f32(motion::speed_scale())
            })
    }
}

struct PanelLayoutTransition {
    workspace: String,
    started: std::time::Instant,
    frames: HashMap<u64, PanelFrame>,
}

/// One value drives the outer lane and the strip's control clearance. Moving
/// down precedes moving left; on reversal the clearance returns first.
struct PanelHeaderMode {
    panels: usize,
    previewing: bool,
    value: f32,
    tween: Option<WidthTween>,
}

impl PanelHeaderMode {
    fn lane_fraction(value: f32) -> f32 {
        (2.0 * value).clamp(0.0, 1.0)
    }

    fn clearance_fraction(value: f32) -> f32 {
        (2.0 * (1.0 - value)).clamp(0.0, 1.0)
    }

    fn new(panels: usize) -> Self {
        Self {
            panels,
            previewing: false,
            value: if panels == 1 { 0.0 } else { 1.0 },
            tween: None,
        }
    }

    fn update(
        &mut self,
        panels: usize,
        preview: Option<f32>,
        now: std::time::Instant,
        reduced: bool,
    ) -> (f32, bool) {
        if let Some(preview) = preview {
            self.value = preview.clamp(0.0, 1.0);
            self.tween = None;
            self.previewing = true;
        } else {
            let target = if panels == 1 { 0.0 } else { 1.0 };
            if self.panels != panels || self.previewing {
                self.tween = Some(WidthTween {
                    from: self.value,
                    to: target,
                    started: now,
                });
            }
            self.previewing = false;
            if reduced {
                self.value = target;
                self.tween = None;
            } else if let Some(tween) = self.tween {
                let duration = PANEL_SPLIT_MOTION.total().mul_f32(motion::speed_scale());
                let progress = now.saturating_duration_since(tween.started).as_secs_f32()
                    / duration.as_secs_f32();
                self.value =
                    motion::lerp(tween.from, tween.to, PANEL_SPLIT_MOTION.progress(progress));
                if progress >= 1.0 {
                    self.tween = None;
                }
            }
        }
        self.panels = panels;
        (self.value, self.tween.is_some())
    }
}

#[derive(Clone)]
struct PanelTabDrag {
    workspace: String,
    panel: u64,
    tab: PanelTab,
    title: SharedString,
}
#[derive(Clone)]
struct PanelResize {
    workspace: String,
    before: u64,
    after: u64,
    axis: SplitAxis,
    origin: f32,
    extent: f32,
    shares: (f32, f32),
}
#[derive(Clone)]
enum MenuAction {
    OpenBrowserExternal(u64),
    MoveToWindow,
    Move(u64),
    MovePanel(bool),
    AddPanel(SplitAxis),
    CloseTab,
    SelectTab(usize),
    NewTab,
    ToggleExpand,
    ClosePanel,
}
#[derive(Clone)]
pub(super) struct PanelMenu {
    panel: u64,
    tab: Option<PanelTab>,
    placement: bool,
    position: Point<Pixels>,
    rows: Vec<(SharedString, &'static str, MenuAction)>,
    selected: usize,
    focus: FocusHandle,
}

#[derive(Default)]
pub(super) struct PanelWorkspaces {
    pub(super) needs_persist: bool,
    pub layouts: HashMap<String, WorkspaceLayout>,
    pub(super) menu: Option<PanelMenu>,
    #[cfg(feature = "browser-fixture")]
    fixture_menu_bounds: std::rc::Rc<std::cell::Cell<Option<gpui::Bounds<Pixels>>>>,
    pub(super) device_menu: Option<device_picker::PanelDeviceMenu>,
    device_choices: HashMap<(String, u64), device_picker::PanelDeviceContext>,
    pub(super) pending_tools: HashMap<String, Vec<(u64, usize, crate::settings::SavedPanelTab)>>,
    target: Option<u64>,
    pub(super) seq: u64,
    pub(super) drafts: HashMap<u64, crate::pickers::CanvasDraft>,
    pub(super) terminals: HashMap<u64, Entity<TerminalPanel>>,
    pub(super) explorers: HashMap<u64, (Entity<FilesSurface>, Subscription, String)>,
    pub(super) terminal_keys: HashMap<u64, u64>,
    pub(super) peers: HashMap<String, (Entity<Transcript>, Subscription)>,
    inactive_composers: HashMap<PanelTab, Entity<crate::composer::InactiveComposer>>,
    composer_layouts: HashMap<PanelTab, crate::composer::InactiveComposerLayout>,
    controls: HashMap<String, FocusHandle>,
    scrolls: HashMap<(String, u64), gpui::ScrollHandle>,
    layout_scrolls: HashMap<String, gpui::ScrollHandle>,
    revealed_panels: HashMap<String, (u64, SplitAxis, u32, u32)>,
    revealed_tabs: HashMap<(String, u64), (Option<PanelTab>, usize, u32)>,
    headers: HashMap<(String, u64), PanelHeaderState>,
    tab_context_fades: TabContextFades,
    hovered_tab: Option<String>,
    resize: Option<PanelResize>,
    split_previews: HashMap<(String, u64, PanelEdge), PanelSplitReveal>,
    rendered_frames: HashMap<(String, u64), PanelFrame>,
    rendered_ghosts: HashMap<(String, u64, PanelEdge), PanelFrame>,
    split_drag: Option<PanelTabDrag>,
    blocked_split: bool,
    split_drag_bounds: HashMap<u64, gpui::Bounds<Pixels>>,
    layout_transition: Option<PanelLayoutTransition>,
    header_modes: HashMap<String, PanelHeaderMode>,
    pub(super) panel_bounds:
        std::rc::Rc<std::cell::RefCell<HashMap<(String, u64), gpui::Bounds<Pixels>>>>,
    pub(super) active_tab_bounds:
        std::rc::Rc<std::cell::RefCell<HashMap<(String, u64), gpui::Bounds<Pixels>>>>,
    window_tab_bounds:
        std::rc::Rc<std::cell::RefCell<HashMap<(String, u64, usize), gpui::Bounds<Pixels>>>>,
    header_tab_bounds:
        std::rc::Rc<std::cell::RefCell<HashMap<(String, u64), gpui::Bounds<Pixels>>>>,
    window_drop_hover: Option<window_drop_target::WindowDropHover>,
    pub(super) rendering: bool,
    pub(super) resource_owner: Option<String>,
    pub(super) resource_engine_owner: Option<String>,
    dragging_tab: std::rc::Rc<std::cell::Cell<bool>>,
    window_drag: Option<window_drag::TabWindowDrag>,
    drag_outside: std::rc::Rc<std::cell::Cell<bool>>,
    drag_preview_visible: std::rc::Rc<std::cell::Cell<bool>>,
}

impl Shell {
    pub(super) fn workspace_resize_active(&self) -> bool {
        self.workspace_panels.resize.is_some()
    }

    pub(super) fn workspace_layout_key(&self, cx: &App) -> String {
        self.chat_tabs
            .get(self.chat_tab)
            .filter(|tab| !tab.id.is_empty())
            .map(|tab| tab.id.clone())
            .unwrap_or_else(|| self.active_project(cx).unwrap_or_default())
    }
    pub(super) fn panel_layout(&self, cx: &App) -> Option<&WorkspaceLayout> {
        self.workspace_panels
            .layouts
            .get(&self.workspace_layout_key(cx))
    }
    pub(super) fn panel_layout_mut(&mut self, cx: &App) -> &mut WorkspaceLayout {
        self.workspace_panels.needs_persist = true;
        let key = self.workspace_layout_key(cx);
        self.workspace_panels.layouts.entry(key).or_default()
    }

    fn projected_workspace_panel(&self, panel: &WorkspacePanel, workspace: &str) -> WorkspacePanel {
        if let Some(drag) = self
            .workspace_panels
            .split_drag
            .as_ref()
            .filter(|drag| drag.workspace == workspace && drag.panel == panel.id)
        {
            if self
                .workspace_panels
                .split_previews
                .iter()
                .any(|((key, _, _), preview)| {
                    key == workspace
                        && (preview.active
                            || preview.animating(std::time::Instant::now(), self.reduced_motion))
                }) || self.workspace_panels.drag_outside.get()
            {
                return panel.without_tab(&drag.tab);
            }
        }
        panel.clone()
    }

    pub(super) fn sync_panel_workspace(&mut self, cx: &mut Context<Self>) {
        if self.window_transfer_preparing {
            return;
        }
        if !matches!(self.route, Route::Chat) {
            return;
        }
        let key = self.workspace_layout_key(cx);
        let selected = self.state.read(cx).selected_chat.clone();
        let owner = self.panel_key(cx);
        let flags = self.panels.get(&owner);
        let surfaces = self.right_tabs.get(&owner).cloned().unwrap_or_default();
        let split = self.chat_split.clone();
        let mut changed = !self.workspace_panels.layouts.contains_key(&key);
        let mut layout = self
            .workspace_panels
            .layouts
            .remove(&key)
            .unwrap_or_default();
        layout.stack_limit =
            stacked_panel_limit(self.viewport_height - self.workspace_native_titlebar_lane(layout.panels.len()));
        if layout.last_selected.as_ref() != Some(&selected) {
            changed = true;
            if let Some(chat) = &selected {
                let tab = PanelTab::Chat(chat.clone());
                // Sending from a draft promotes that same tab in place.
                if layout.last_selected == Some(None)
                    && layout.location(&tab).is_none()
                    && let Some(p) = layout.panel_mut(layout.focused)
                    && matches!(p.selected(), Some(PanelTab::Draft(_)))
                {
                    p.tabs[p.active] = tab.clone();
                }
                let target = layout.focused;
                layout.insert(target, tab);
            } else if layout.last_selected.is_none()
                || !matches!(
                    layout.panel(layout.focused).and_then(|p| p.selected()),
                    Some(PanelTab::Draft(_) | PanelTab::New(_))
                )
            {
                self.workspace_panels.seq += 1;
                layout.insert(layout.focused, PanelTab::Draft(self.workspace_panels.seq));
            }
            layout.last_selected = Some(selected.clone());
        }
        if let Some(split) = split {
            for id in split.panes.iter().flatten() {
                let tab = PanelTab::Chat(id.clone());
                if layout.location(&tab).is_none() && !layout.imported.contains(&tab) {
                    changed = true;
                    let focused = layout.focused;
                    let p = layout.add_panel(layout.panels.last().unwrap().id);
                    layout.insert(p, tab.clone());
                    layout.imported.insert(tab);
                    layout.focused = focused;
                }
            }
        }
        // Import legacy opens once. The workspace then owns placement, so a
        // closed tab cannot reappear on the next render from a stale open flag.
        let mut incoming: Vec<PanelTab> = surfaces
            .into_iter()
            .map(|surface| PanelTab::Surface {
                owner: owner.clone(),
                surface,
            })
            .collect();
        if flags.files_open {
            incoming.push(PanelTab::Files(owner.clone()));
        }
        if flags.terminal_open {
            incoming.push(PanelTab::TerminalDock(owner.clone()));
        }
        if flags.changes_open && incoming.is_empty() {
            incoming.push(PanelTab::Empty);
        }
        for tab in incoming {
            if layout.imported.contains(&tab) || layout.location(&tab).is_some() {
                continue;
            }
            changed = true;
            layout.imported.insert(tab.clone());
            let focused = layout.focused;
            let target = self
                .workspace_panels
                .target
                .take()
                .filter(|id| layout.panel(*id).is_some())
                .unwrap_or_else(|| {
                    layout
                        .panels
                        .iter()
                        .find(|p| p.tabs.iter().any(|t| matches!(t, PanelTab::Surface { .. })))
                        .map(|p| p.id)
                        .unwrap_or_else(|| layout.add_panel(focused))
                });
            layout.insert(target, tab);
            layout.focused = focused;
        }
        // A completed asynchronous file close must also remove its tab here.
        let before_fit: Vec<_> = layout
            .panels
            .iter()
            .map(|panel| {
                (
                    panel.id,
                    panel.active,
                    panel.share.to_bits(),
                    panel.tabs.len(),
                )
            })
            .collect();
        for p in &mut layout.panels {
            p.tabs.retain(|t| match t {
                PanelTab::Surface {
                    surface: RightSurface::File(id),
                    ..
                } => self.file_surfaces.contains_key(id),
                PanelTab::Surface {
                    surface: RightSurface::Browser(id),
                    ..
                } => self.browsers.contains_key(id),
                _ => true,
            });
            p.active = p.active.min(p.tabs.len().saturating_sub(1));
        }
        layout.fit_stacked_panels(self.viewport_height - self.workspace_native_titlebar_lane(layout.panels.len()));
        changed |= before_fit
            != layout
                .panels
                .iter()
                .map(|panel| {
                    (
                        panel.id,
                        panel.active,
                        panel.share.to_bits(),
                        panel.tabs.len(),
                    )
                })
                .collect::<Vec<_>>();
        self.workspace_panels.needs_persist |= changed;
        let visible_peers: HashSet<String> = layout
            .panels
            .iter()
            .filter(|p| layout.expanded.is_none_or(|id| id == p.id))
            .filter_map(
                |p| match self.projected_workspace_panel(p, &key).selected() {
                    Some(PanelTab::Chat(id)) if selected.as_ref() != Some(id) => Some(id.clone()),
                    _ => None,
                },
            )
            .collect();
        let stale: Vec<_> = self
            .workspace_panels
            .peers
            .keys()
            .filter(|id| !visible_peers.contains(*id))
            .cloned()
            .collect();
        for id in stale {
            self.workspace_panels.peers.remove(&id);
            self.state.update(cx, |s, _| s.unwatch_peer_chat(&id));
        }
        self.workspace_panels.layouts.insert(key, layout);
    }

    pub(super) fn visible_workspace_browsers(&self, cx: &App) -> HashSet<u64> {
        self.panel_layout(cx)
            .into_iter()
            .flat_map(|l| {
                l.panels
                    .iter()
                    .filter(|p| l.expanded.is_none_or(|id| id == p.id))
            })
            .filter_map(|p| {
                match self
                    .projected_workspace_panel(p, &self.workspace_layout_key(cx))
                    .selected()
                {
                    Some(PanelTab::Surface {
                        surface: RightSurface::Browser(id),
                        ..
                    }) => Some(*id),
                    _ => None,
                }
            })
            .collect()
    }

    pub(super) fn park_workspace_draft(&mut self, cx: &App) {
        if let Some(tab @ (PanelTab::Chat(_) | PanelTab::Draft(_))) = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(layout.focused))
            .and_then(|panel| panel.selected())
            .cloned()
            && let Some(layout) = self.composer.read(cx).inactive_layout()
        {
            self.workspace_panels.composer_layouts.insert(tab, layout);
        }
        let draft = self
            .panel_layout(cx)
            .and_then(|l| l.panel(l.focused))
            .and_then(|p| match p.selected() {
                Some(PanelTab::Draft(id) | PanelTab::New(id)) => Some(*id),
                _ => None,
            });
        if let Some(id) = draft {
            let value = self.current_canvas_draft(cx);
            if self.workspace_panels.drafts.get(&id) != Some(&value) {
                self.workspace_panels.drafts.insert(id, value);
                self.workspace_panels.needs_persist = true;
            }
        }
    }

    pub(super) fn current_workspace_draft_id(&self, cx: &App) -> Option<u64> {
        self.panel_layout(cx)
            .and_then(|layout| layout.panel(layout.focused))
            .and_then(|panel| {
                if let Some(PanelTab::Draft(id)) = panel.selected() {
                    Some(*id)
                } else {
                    None
                }
            })
    }

    pub(super) fn workspace_draft_is_open(&self, draft: u64, cx: &App) -> bool {
        self.panel_layout(cx)
            .is_some_and(|layout| layout.location(&PanelTab::Draft(draft)).is_some())
    }

    pub(super) fn focus_sidebar_draft(
        &mut self,
        draft: u64,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let tab = PanelTab::Draft(draft);
        if let Some((panel, _)) = self
            .panel_layout(cx)
            .and_then(|layout| layout.location(&tab))
        {
            self.focus_workspace_tab(panel, tab, window, cx);
        }
    }

    fn select_workspace_chat(&mut self, target: Option<String>, cx: &mut Context<Self>) {
        let previous = self.state.read(cx).selected_chat.clone();
        if previous == target {
            return;
        }
        let incoming = target
            .as_ref()
            .and_then(|id| self.workspace_panels.peers.remove(id));
        if let Some(id) = &previous {
            self.transcript
                .update(cx, |t, cx| t.set_split_source(Some(id.clone()), cx));
        }
        self.state
            .update(cx, |s, cx| s.select_split_chat(target.clone(), cx));
        let (transcript, events) = incoming.unwrap_or_else(|| {
            let transcript = cx.new(|cx| Transcript::new(self.state.clone(), cx));
            let links = Self::session_links(None, cx);
            let views = Self::view_opener(cx);
            let labels = Self::model_labeler(&self.composer, cx);
            transcript.update(cx, |t, _| {
                t.set_workspace_link_handler(links);
                t.set_view_opener(views);
                t.set_model_labeler(labels);
            });
            let events = cx.subscribe(&transcript, Self::on_transcript_event);
            (transcript, events)
        });
        transcript.update(cx, |t, cx| t.set_split_source(None, cx));
        let old = (
            std::mem::replace(&mut self.transcript, transcript),
            std::mem::replace(&mut self._transcript_events, events),
        );
        if let Some(id) = previous {
            self.state
                .update(cx, |s, cx| s.watch_peer_chat(id.clone(), cx));
            self.workspace_panels.peers.insert(id, old);
        }
        if let Some(id) = target {
            self.state.update(cx, |s, _| s.unwatch_peer_chat(&id));
        }
    }

    pub(super) fn focus_workspace_tab(
        &mut self,
        panel: u64,
        tab: PanelTab,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let reselected_chat = matches!(&tab, PanelTab::Chat(id)
            if self.state.read(cx).selected_chat.as_ref() == Some(id))
            && self.panel_layout(cx).is_some_and(|layout| {
                layout.focused == panel
                    && layout.panel(panel).and_then(|panel| panel.selected()) == Some(&tab)
            });
        self.park_workspace_draft(cx);
        self.activate_workspace_tab(panel, tab, window, cx);
        if reselected_chat {
            self.composer
                .update(cx, |composer, cx| composer.reveal_pending_question(cx));
        }
    }

    fn activate_workspace_tab(
        &mut self,
        panel: u64,
        tab: PanelTab,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let already_focused = self.panel_layout(cx).is_some_and(|layout| {
            layout.focused == panel
                && layout.panel(panel).and_then(|panel| panel.selected()) == Some(&tab)
        });
        let composer_layout = self
            .workspace_panels
            .inactive_composers
            .get(&tab)
            .filter(|_| !already_focused)
            .map(|preview| preview.read(cx).layout())
            .or_else(|| self.workspace_panels.composer_layouts.get(&tab).copied());
        self.panel_layout_mut(cx).insert(panel, tab.clone());
        self.workspace_panels.menu = None;
        if !matches!(tab, PanelTab::Chat(_) | PanelTab::Draft(_)) {
            self.composer.update(cx, |c, _| c.focus_pending = false);
        }
        match tab {
            PanelTab::Chat(id) => {
                let available = self.state.read(cx).chats.iter().any(|chat| chat.id == id);
                self.select_workspace_chat(Some(id.clone()), cx);
                self.panel_layout_mut(cx).last_selected = Some(Some(id));
                if available { window.focus(&self.composer.focus_handle(cx), cx); }
                else {
                    self.composer.update(cx, |composer, _| composer.focus_pending = false);
                    let focus = self.workspace_panels.controls.entry(format!("panel-header-{panel}"))
                        .or_insert_with(|| cx.focus_handle().tab_stop(true)).clone();
                    window.focus(&focus, cx);
                }
            }
            PanelTab::Draft(id) => {
                self.select_workspace_chat(None, cx);
                self.panel_layout_mut(cx).last_selected = Some(None);
                self.adopt_canvas_draft(self.workspace_panels.drafts.get(&id).cloned(), cx);
                window.focus(&self.composer.focus_handle(cx), cx);
            }
            PanelTab::New(id) => {
                self.select_workspace_chat(None, cx);
                self.panel_layout_mut(cx).last_selected = Some(None);
                self.adopt_canvas_draft(self.workspace_panels.drafts.get(&id).cloned(), cx);
                let focus = self
                    .workspace_panels
                    .controls
                    .entry(format!("panel-empty-{panel}-0"))
                    .or_insert_with(|| cx.focus_handle().tab_stop(true))
                    .clone();
                window.focus(&focus, cx);
            }
            PanelTab::Surface { surface, .. } => self.focus_right_file_editor(surface, window, cx),
            PanelTab::Terminal(id) => {
                if let Some(terminal) = self.workspace_panels.terminals.get(&id) {
                    window.focus(&terminal.read(cx).focus_handle(), cx);
                }
            }
            PanelTab::TerminalDock(_) => {
                if let Some(terminal) = &self.terminal {
                    window.focus(&terminal.read(cx).focus_handle(), cx);
                }
            }
            PanelTab::FileTree(id) => {
                if let Some((files, _, _)) = self.workspace_panels.explorers.get(&id) {
                    files.update(cx, |files, cx| files.focus_explorer(window, cx));
                }
            }
            PanelTab::Files(owner) => {
                if let Some(files) = self.files.get(&owner) {
                    files.update(cx, |files, cx| files.focus_explorer(window, cx));
                }
            }
            _ => {}
        }
        if let Some(layout) = composer_layout {
            self.composer.update(cx, |composer, cx| {
                composer.restore_inactive_layout(layout, cx)
            });
        }
        cx.notify();
    }

    /// Hide tools without closing their underlying terminal or explorer.
    pub(super) fn toggle_workspace_tool(
        &mut self,
        tool: WorkspaceTool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !matches!(self.route, Route::Chat) {
            return false;
        }
        self.park_workspace_draft(cx);
        self.sync_panel_workspace(cx);
        let matches_tool = |tab: &PanelTab| match tool {
            WorkspaceTool::Terminal => matches!(
                tab,
                PanelTab::Terminal(_)
                    | PanelTab::TerminalDock(_)
                    | PanelTab::Surface {
                        surface: RightSurface::Terminal(_),
                        ..
                    }
            ),
            WorkspaceTool::Files => matches!(tab, PanelTab::FileTree(_) | PanelTab::Files(_)),
            WorkspaceTool::Changes => matches!(
                tab,
                PanelTab::Surface {
                    surface: RightSurface::Diff(_),
                    ..
                }
            ),
        };
        let layout = self.panel_layout_mut(cx);
        let visible = layout
            .panels
            .iter()
            .filter(|p| layout.expanded.is_none_or(|id| id == p.id))
            .filter_map(|p| {
                p.selected()
                    .filter(|t| matches_tool(t))
                    .map(|t| (p.id, t.clone()))
            })
            .min_by_key(|(id, _)| *id != layout.focused);
        if let Some((id, tab)) = visible {
            let panel_index = layout.panels.iter().position(|p| p.id == id).unwrap();
            let tab_index = layout.location(&tab).unwrap().1;
            layout.remove_tab(id, &tab);
            layout.hidden_tools.push((panel_index, id, tab_index, tab));
            if layout.panel(id).is_some_and(|p| p.tabs.is_empty()) && layout.panels.len() > 1 {
                layout.panels.retain(|p| p.id != id);
                if layout.focused == id {
                    layout.focused = layout.panels[panel_index.min(layout.panels.len() - 1)].id;
                }
                layout.equalize();
            }
            layout.expanded = None;
            let focused = layout.focused;
            let next = layout.panel(focused).and_then(|p| p.selected()).cloned();
            if let Some(next) = next {
                self.focus_workspace_tab(focused, next, window, cx);
            } else {
                window.focus(&self.composer.focus_handle(cx), cx);
            }
            cx.notify();
            return true;
        }
        if let Some(ix) = layout
            .hidden_tools
            .iter()
            .rposition(|(_, _, _, tab)| matches_tool(tab))
        {
            let (position, id, tab_index, tab) = layout.hidden_tools.remove(ix);
            if layout.panel(id).is_none() {
                layout.panels.insert(
                    position.min(layout.panels.len()),
                    WorkspacePanel {
                        id,
                        tabs: vec![],
                        active: 0,
                        share: 1.0,
                    },
                );
                layout.equalize();
            }
            let panel = layout.panel_mut(id).unwrap();
            let at = tab_index.min(panel.tabs.len());
            panel.tabs.insert(at, tab.clone());
            panel.active = at;
            layout.expanded = None;
            self.focus_workspace_tab(id, tab, window, cx);
            return true;
        }
        let inactive = layout.panels.iter().find_map(|p| {
            p.tabs
                .iter()
                .find(|t| matches_tool(t))
                .cloned()
                .map(|tab| (p.id, tab))
        });
        if let Some((id, tab)) = inactive {
            layout.expanded = None;
            self.focus_workspace_tab(id, tab, window, cx);
        } else {
            match tool {
                WorkspaceTool::Terminal => self.open_workspace_terminal(cx),
                WorkspaceTool::Files => self.open_workspace_files(window, cx),
                // Changes open beside the chat, which keeps the keyboard.
                WorkspaceTool::Changes => {
                    if self.active_chat.is_empty() {
                        return false;
                    }
                    let focused = self.panel_layout_mut(cx).focused;
                    if self.show_changes_review(cx).is_none() {
                        self.add_diff_surface(cx);
                    }
                    self.sync_panel_workspace(cx);
                    self.panel_layout_mut(cx).focused = focused;
                    cx.notify();
                    return true;
                }
            }
            let layout = self.panel_layout_mut(cx);
            let id = layout.focused;
            if let Some(tab) = layout.panel(id).and_then(|p| p.selected()).cloned() {
                self.focus_workspace_tab(id, tab, window, cx);
            }
        }
        true
    }

    /// Inherit run picks and the source conversation's destination. The
    /// global project picker may have moved since that conversation opened.
    /// A sibling never inherits unsent input or a shared-checkout override.
    fn fresh_workspace_chat_draft(&self, cx: &App) -> crate::pickers::CanvasDraft {
        let mut draft = self.current_canvas_draft(cx).fresh();
        if let Some(chat) = self.state.read(cx).selected_chat_row() {
            draft.target = Some(crate::pickers::CanvasTarget {
                space: chat.space_id.clone(),
                no_project: chat.space_id.is_none(),
                device: Some(chat.device_id.clone()),
            });
        }
        draft
    }

    pub(super) fn workspace_new_tab(&mut self, cx: &mut Context<Self>) {
        if !matches!(self.route, Route::Chat) {
            self.close_settings(cx);
        }
        self.session_overview = false;
        self.command_palette = None;
        self.sync_panel_workspace(cx);
        self.park_workspace_draft(cx);
        let source = self
            .workspace_panels
            .target
            .unwrap_or_else(|| self.panel_layout(cx).map_or(0, |layout| layout.focused));
        let device = self.workspace_panel_device(source, cx);
        self.set_workspace_panel_device(source, device.clone(), cx);
        self.workspace_panels.seq += 1;
        let id = self.workspace_panels.seq;
        let mut draft = self.fresh_workspace_chat_draft(cx);
        draft.target = Some(device.canvas_target(self.state.read(cx)));
        self.workspace_panels.drafts.insert(id, draft.clone());
        let tab = PanelTab::New(id);
        let target = self.workspace_panels.target.take();
        let layout = self.panel_layout_mut(cx);
        let panel = target.unwrap_or(layout.focused);
        layout.insert(panel, tab);
        layout.last_selected = Some(None);
        self.workspace_panels.menu = None;
        self.select_workspace_chat(None, cx);
        self.adopt_canvas_draft(Some(draft), cx);
        self.composer
            .update(cx, |composer, _| composer.focus_pending = false);
        cx.notify();
    }

    pub(super) fn workspace_new_tab_in_panel(&mut self, panel: u64, cx: &mut Context<Self>) {
        self.workspace_panels.target = Some(panel);
        self.workspace_new_tab(cx);
    }

    pub(super) fn workspace_new_chat(&mut self, cx: &mut Context<Self>) {
        self.workspace_new_chat_for_device(None, cx);
    }

    fn workspace_new_chat_for_device(
        &mut self,
        device: Option<device_picker::PanelDeviceContext>,
        cx: &mut Context<Self>,
    ) {
        // Opening a chat is explicit startup intent even when the boot canvas
        // already has no selection. A late catalogue must not restore over it.
        self.state.update(cx, |state, _| state.auto_selected = true);
        self.sync_panel_workspace(cx);
        self.park_workspace_draft(cx);
        self.workspace_panels.seq += 1;
        let id = self.workspace_panels.seq;
        let mut draft = self.fresh_workspace_chat_draft(cx);
        if let Some(device) = device {
            draft.target = Some(device.canvas_target(self.state.read(cx)));
        }
        self.workspace_panels.drafts.insert(id, draft.clone());
        let target = self.workspace_panels.target.take();
        let layout = self.panel_layout_mut(cx);
        layout.insert(target.unwrap_or(layout.focused), PanelTab::Draft(id));
        layout.last_selected = Some(None);
        self.select_workspace_chat(None, cx);
        self.adopt_canvas_draft(Some(draft), cx);
        self.focus_composer(cx);
        cx.notify();
    }

    pub(super) fn focus_workspace_new_tab(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let panel = self.panel_layout_mut(cx).focused;
        let focus = self
            .workspace_panels
            .controls
            .entry(format!("panel-empty-{panel}-0"))
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        window.focus(&focus, cx);
    }

    pub(super) fn open_workspace_terminal(&mut self, cx: &mut Context<Self>) {
        self.open_workspace_terminal_for_device(None, cx);
    }

    fn open_workspace_terminal_for_device(
        &mut self,
        device: Option<device_picker::PanelDeviceContext>,
        cx: &mut Context<Self>,
    ) {
        self.park_workspace_draft(cx);
        self.sync_panel_workspace(cx);
        let owner = device
            .as_ref()
            .map(|device| device.owner.clone())
            .unwrap_or_else(|| self.state.read(cx).panel_session_key());
        let state = self.state.clone();
        let terminal = cx.new(|cx| {
            let mut t = TerminalPanel::new_embedded(state, cx);
            t.pin_session(owner);
            if let Some(device) = device {
                t.pin_device(device.remote);
            }
            t
        });
        let tab_key = terminal.update(cx, |t, cx| {
            t.set_open(true, cx);
            t.open_tab_for_selected(cx)
        });
        let Some(tab_key) = tab_key else {
            return;
        };
        self.workspace_panels.seq += 1;
        let id = self.workspace_panels.seq;
        self.workspace_panels.terminals.insert(id, terminal);
        self.workspace_panels.terminal_keys.insert(id, tab_key);
        // The new terminal takes the keyboard. A composer still waiting to
        // focus would take it back on its next render.
        self.composer
            .update(cx, |composer, _| composer.focus_pending = false);
        let target = self.workspace_panels.target.take();
        let layout = self.panel_layout_mut(cx);
        let target = target.unwrap_or_else(|| layout.add_panel(layout.focused));
        layout.insert(target, PanelTab::Terminal(id));
        layout.expanded = None;
        cx.notify();
    }

    pub(super) fn open_workspace_files(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_workspace_files_for_device(None, window, cx);
    }

    fn open_workspace_files_for_device(
        &mut self,
        device: Option<device_picker::PanelDeviceContext>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.park_workspace_draft(cx);
        self.sync_panel_workspace(cx);
        let owner = self.panel_key(cx);
        self.workspace_panels.seq += 1;
        let id = self.workspace_panels.seq;
        let state = self.state.clone();
        let show_all = self.settings.files_show_all;
        let engine_owner = device
            .as_ref()
            .map(|device| device.owner.clone())
            .unwrap_or_else(|| self.files_engine_owner(&owner, cx));
        let preferred = device
            .as_ref()
            .and_then(|device| device.full_id(self.state.read(cx)));
        let files = cx.new(|cx| {
            let mut files = FilesSurface::new_explorer(state, engine_owner, show_all, cx);
            if device.is_some() {
                files.prefer_device(preferred);
            }
            files
        });
        let source_owner = owner.clone();
        let events =
            cx.subscribe_in(
                &files,
                window,
                move |this, source, event, window, cx| match event {
                    FilesEvent::OpenFile(path) if source.read(cx).is_current_target(cx) => {
                        let location = this
                            .panel_layout(cx)
                            .and_then(|l| l.location(&PanelTab::FileTree(id)))
                            .map(|(p, _)| p);
                        if let Some(from) = location {
                            let layout = this.panel_layout_mut(cx);
                            let target = layout
                                .neighbor(from, true)
                                .or_else(|| layout.neighbor(from, false))
                                .unwrap_or_else(|| layout.add_panel(from));
                            this.workspace_panels.target = Some(target);
                            let previous_owner = this
                                .workspace_panels
                                .resource_owner
                                .replace(source_owner.clone());
                            let engine_owner = source.read(cx).session_owner().to_owned();
                            let previous_engine = this
                                .workspace_panels
                                .resource_engine_owner
                                .replace(engine_owner);
                            this.add_file_surface(path.clone(), window, cx);
                            this.workspace_panels.resource_owner = previous_owner;
                            this.workspace_panels.resource_engine_owner = previous_engine;
                            this.workspace_panels.target = None;
                        }
                    }
                    FilesEvent::AddProject => this.open_files_project(&source, cx),
                    FilesEvent::ShowAllFilesChanged(show_all) => {
                        this.set_files_show_all(*show_all, cx)
                    }
                    _ => cx.notify(),
                },
            );
        self.workspace_panels
            .explorers
            .insert(id, (files, events, owner));
        let requested = self.workspace_panels.target.take();
        let layout = self.panel_layout_mut(cx);
        let target = requested.unwrap_or_else(|| layout.add_panel(layout.focused));
        layout.insert(target, PanelTab::FileTree(id));
        cx.notify();
    }

    pub(super) fn reserve_workspace_action_terminal(
        &mut self,
        owner: String,
        title: String,
        cx: &mut Context<Self>,
    ) -> (Entity<TerminalPanel>, u64) {
        self.sync_panel_workspace(cx);
        let state = self.state.clone();
        let terminal = cx.new(|cx| {
            let mut t = TerminalPanel::new_embedded(state, cx);
            t.pin_session(owner.clone());
            t
        });
        let key = terminal.update(cx, |t, cx| {
            let key = t.reserve_tab_for_chat(owner, title, cx);
            t.set_open(true, cx);
            key
        });
        self.workspace_panels.seq += 1;
        let id = self.workspace_panels.seq;
        self.workspace_panels.terminals.insert(id, terminal.clone());
        self.workspace_panels.terminal_keys.insert(id, key);
        let layout = self.panel_layout_mut(cx);
        let focused = layout.focused;
        let target = layout
            .panels
            .iter()
            .find(|p| p.tabs.iter().any(|t| matches!(t, PanelTab::Terminal(_))))
            .map(|p| p.id)
            .unwrap_or_else(|| layout.add_panel(focused));
        layout.insert(target, PanelTab::Terminal(id));
        layout.focused = focused;
        cx.notify();
        (terminal, key)
    }

    pub(super) fn reveal_workspace_chat(&mut self, id: String, cx: &mut Context<Self>) {
        self.sync_panel_workspace(cx);
        let layout = self.panel_layout_mut(cx);
        layout.insert(layout.focused, PanelTab::Chat(id));
        layout.expanded = None;
        cx.notify();
    }

    pub(super) fn workspace_contains_owner(&self, owner: &str, cx: &App) -> bool {
        self.panel_layout(cx).is_some_and(|layout| {
            layout.panels.iter().any(|p| {
                p.tabs.iter().any(|tab| match tab {
                    PanelTab::Files(key) | PanelTab::Surface { owner: key, .. } => key == owner,
                    _ => false,
                })
            })
        })
    }

    pub(super) fn reveal_workspace_surface(
        &mut self,
        owner: String,
        surface: RightSurface,
        cx: &mut Context<Self>,
    ) {
        if !matches!(self.route, Route::Chat) {
            return;
        }
        self.park_workspace_draft(cx);
        self.sync_panel_workspace(cx);
        let tab = PanelTab::Surface { owner, surface };
        let layout = self.panel_layout_mut(cx);
        let target = layout
            .location(&tab)
            .map(|(id, _)| id)
            .unwrap_or(layout.focused);
        layout.insert(target, tab);
        if layout.expanded.is_some() {
            layout.expanded = Some(target);
        }
    }

    pub(super) fn workspace_cycle_tab(
        &mut self,
        forward: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(layout) = self.panel_layout(cx) else {
            return false;
        };
        let Some(panel) = layout.panel(layout.focused) else {
            return false;
        };
        if panel.tabs.len() < 2 {
            return false;
        }
        let ix = if forward {
            (panel.active + 1) % panel.tabs.len()
        } else {
            (panel.active + panel.tabs.len() - 1) % panel.tabs.len()
        };
        let id = panel.id;
        let tab = panel.tabs[ix].clone();
        self.focus_workspace_tab(id, tab, window, cx);
        true
    }

    pub(super) fn workspace_focus_neighbor(
        &mut self,
        right: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(layout) = self.panel_layout(cx) else {
            return false;
        };
        let Some(id) = layout.neighbor(layout.focused, right) else {
            return false;
        };
        let tab = layout.panel(id).and_then(|p| p.selected()).cloned();
        if let Some(tab) = tab {
            self.focus_workspace_tab(id, tab, window, cx);
        } else {
            self.panel_layout_mut(cx).focused = id;
            cx.notify();
        }
        true
    }

    /// ⌘] and ⌘[: the next or previous panel, wrapping. A zoomed window shows
    /// the panel it moved to, so the keyboard never lands on a hidden one.
    pub(super) fn workspace_cycle_panel(
        &mut self,
        forward: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(layout) = self.panel_layout(cx) else {
            return;
        };
        let Some(id) = layout.cycled(layout.focused, forward) else {
            return;
        };
        let tab = layout.panel(id).and_then(|p| p.selected()).cloned();
        let layout = self.panel_layout_mut(cx);
        if layout.expanded.is_some() {
            layout.expanded = Some(id);
        }
        if let Some(tab) = tab {
            self.focus_workspace_tab(id, tab, window, cx);
        } else {
            self.panel_layout_mut(cx).focused = id;
            cx.notify();
        }
    }

    /// The composer lives in the panel showing the selected chat or draft. A
    /// shortcut meant for it, pressed from a terminal or file beside it, moves
    /// there first. False when no panel on screen has a composer to go to.
    pub(super) fn focus_workspace_composer_panel(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(layout) = self.panel_layout(cx) else {
            return true;
        };
        let has_composer =
            |tab: Option<&PanelTab>| matches!(tab, Some(PanelTab::Chat(_) | PanelTab::Draft(_)));
        if layout
            .panel(layout.focused)
            .is_some_and(|panel| has_composer(panel.selected()))
        {
            return true;
        }
        let selected = self
            .state
            .read(cx)
            .selected_chat
            .clone()
            .map(PanelTab::Chat);
        let visible = || {
            layout
                .panels
                .iter()
                .filter(|panel| layout.expanded.is_none_or(|id| id == panel.id))
        };
        let target = visible()
            .find(|panel| selected.is_some() && panel.selected() == selected.as_ref())
            .or_else(|| visible().find(|panel| has_composer(panel.selected())))
            .map(|panel| (panel.id, panel.selected().cloned()));
        let Some((panel, Some(tab))) = target else {
            return false;
        };
        self.focus_workspace_tab(panel, tab, window, cx);
        true
    }

    /// The file ⌘S saves: the one in the focused panel, else the first file on
    /// screen, so a save from the composer beside an editor still lands.
    pub(super) fn workspace_file_to_save(&self, cx: &App) -> Option<u64> {
        let layout = self.panel_layout(cx)?;
        let file_in = |panel: &WorkspacePanel| match panel.selected() {
            Some(PanelTab::Surface {
                surface: RightSurface::File(id),
                ..
            }) => Some(*id),
            _ => None,
        };
        layout.panel(layout.focused).and_then(file_in).or_else(|| {
            layout
                .panels
                .iter()
                .filter(|panel| layout.expanded.is_none_or(|id| id == panel.id))
                .find_map(file_in)
        })
    }

    pub(super) fn workspace_zoom(&mut self, cx: &mut Context<Self>) {
        let layout = self.panel_layout_mut(cx);
        layout.expanded = if layout.expanded.is_some() {
            None
        } else {
            Some(layout.focused)
        };
        cx.notify();
    }

    pub(super) fn workspace_focus_direction(
        &mut self,
        direction: chat_split::PaneDirection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(after) = self
            .panel_layout(cx)
            .and_then(|layout| layout.direction(direction))
        {
            self.workspace_focus_neighbor(after, window, cx);
        }
    }

    pub(super) fn workspace_equalize(&mut self, cx: &mut Context<Self>) {
        self.panel_layout_mut(cx).equalize();
        cx.notify();
    }

    /// Multiple panels keep their own headers beneath the session controls.
    fn workspace_native_titlebar_lane(&self, panel_count: usize) -> f32 {
        if INSTRUMENT_STRIP {
            // The same height as the tab row it replaces, so a panel's content
            // stays exactly where it was when the window splits.
            return if panel_count > 1 { PANEL_HEADER_HEIGHT } else { 0.0 };
        }
        if panel_count == 1 {
            return 0.0;
        }
        let collapsed =
            1.0 - (self.sidebar_now() / self.settings.sidebar_width.max(1.0)).clamp(0.0, 1.0);
        PANEL_HEADER_HEIGHT * collapsed
    }

    pub(in crate::shell) fn workspace_header_transition_active(&self, cx: &App) -> bool {
        self.workspace_panels
            .header_modes
            .get(&self.workspace_layout_key(cx))
            .is_some_and(|mode| mode.previewing || mode.tween.is_some())
    }

    pub(super) fn workspace_resize(
        &mut self,
        direction: chat_split::PaneDirection,
        cx: &mut Context<Self>,
    ) {
        let sidebar = self.sidebar_now();
        let width = self.viewport_width - sidebar - GUTTER;
        let count = self.panel_layout(cx).map_or(1, |layout| layout.panels.len());
        let height = self.viewport_height - GUTTER - self.workspace_native_titlebar_lane(count);
        let layout = self.panel_layout_mut(cx);
        let Some(after) = layout.direction(direction) else {
            return;
        };
        let Some(index) = layout.panels.iter().position(|p| p.id == layout.focused) else {
            return;
        };
        if layout.panels.len() < 2 || layout.expanded.is_some() {
            return;
        }
        let before = index.min(layout.panels.len() - 2);
        let sum = layout.panels[before].share + layout.panels[before + 1].share;
        let extent = (if layout.axis == SplitAxis::Horizontal {
            width
        } else {
            height
        } - layout.gap() * layout.panels.len().saturating_sub(1) as f32)
            .max(1.0);
        let minimum = if layout.axis == SplitAxis::Horizontal {
            PANEL_MIN
        } else if layout.panels.len() >= 3 {
            THREE_PANEL_MIN_HEIGHT
        } else {
            PANEL_MIN_HEIGHT
        };
        let min = (minimum / extent).min(sum / 2.0);
        let share =
            (layout.panels[before].share + if after { 0.05 } else { -0.05 }).clamp(min, sum - min);
        layout.panels[before].share = share;
        layout.panels[before + 1].share = sum - share;
        cx.notify();
    }

    pub(super) fn workspace_split(&mut self, axis: SplitAxis, cx: &mut Context<Self>) {
        self.sync_panel_workspace(cx);
        if !self.panel_layout_mut(cx).can_add_panel(axis) {
            return;
        }
        self.park_workspace_draft(cx);
        let layout = self.panel_layout_mut(cx);
        layout.axis = axis;
        let beside = layout.focused;
        let id = layout.add_panel(beside);
        self.start_panel_insertion(id, beside, cx);
        self.workspace_panels.target = Some(id);
        self.workspace_new_chat(cx);
    }

    pub(crate) fn workspace_close_focused(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !matches!(self.route, Route::Chat) {
            return false;
        }
        // A close that went ahead some other way answers nothing.
        self.archive_choice_prompt = false;
        let Some(layout) = self.panel_layout(cx) else {
            return false;
        };
        let id = layout.focused;
        let tab = layout.panel(id).and_then(|p| p.selected()).cloned();
        if let Some(tab) = tab {
            self.close_workspace_tab(id, tab, window, cx);
            return true;
        }
        if layout.panels.len() > 1 {
            let layout = self.panel_layout_mut(cx);
            layout.panels.retain(|p| p.id != id);
            layout.focused = layout.panels[0].id;
            layout.expanded = None;
            layout.equalize();
            cx.notify();
            return true;
        }
        // This workspace owns the close even when its final panel is empty.
        // Falling through would close the project view and select another
        // project's tabs on the next key repeat.
        true
    }

    pub(super) fn panel_tab_label(&self, tab: &PanelTab, cx: &App) -> (SharedString, &'static str) {
        match tab {
            PanelTab::Chat(id) => (
                self.state
                    .read(cx)
                    .chats
                    .iter()
                    .find(|c| c.id == *id)
                    .map(|c| crate::state::chat_label(c, &None, "New conversation"))
                    .unwrap_or_else(|| "Conversation".into())
                    .into(),
                icons::CHAT_ROUND_LINE,
            ),
            PanelTab::Draft(_) => ("New tab".into(), icons::CHAT_ROUND_LINE),
            PanelTab::Files(_) | PanelTab::FileTree(_) => ("Files".into(), icons::FOLDER),
            PanelTab::Terminal(id) => (
                self.workspace_panels
                    .terminals
                    .get(id)
                    .and_then(|t| {
                        t.read(cx)
                            .tab_summaries(cx)
                            .first()
                            .map(|(_, title, _)| title.clone())
                    })
                    .unwrap_or_else(|| "Terminal".into()),
                icons::TERMINAL,
            ),
            PanelTab::TerminalDock(_) => ("Terminal".into(), icons::TERMINAL),
            PanelTab::Surface { surface, .. } => match surface {
                RightSurface::Browser(id) => (
                    self.browsers
                        .get(id)
                        .map(|b| b.read(cx).title())
                        .unwrap_or_else(|| "Browser".into()),
                    icons::GLOBE,
                ),
                RightSurface::File(id) => (
                    self.file_surface_paths
                        .get(id)
                        .map(|p| workspace_file_title(p))
                        .unwrap_or_else(|| "File".into()),
                    icons::FILE_CODE,
                ),
                RightSurface::Diff(id) => (
                    self.diffs
                        .get(id)
                        .map(|d| d.read(cx).tab_title())
                        .unwrap_or_else(|| "Changes".into()),
                    icons::GIT_BRANCH,
                ),
                RightSurface::Terminal(_) => ("Terminal".into(), icons::TERMINAL),
                RightSurface::Subagent(id) => (
                    self.subagent_tabs
                        .get(id)
                        .map(|t| t.title.clone())
                        .unwrap_or_else(|| "Thread".into()),
                    icons::CHAT_ROUND_LINE,
                ),
                _ => ("New tab".into(), icons::PLUS),
            },
            PanelTab::New(_) | PanelTab::Empty => ("New tab".into(), icons::PLUS),
        }
    }

    fn move_workspace_tab(
        &mut self,
        from: u64,
        tab: PanelTab,
        to: u64,
        before: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.park_workspace_draft(cx);
        let device = self.moving_new_tab_device(from, &tab, cx);
        let previous_focus = self.panel_layout_mut(cx).focused;
        if self.panel_layout_mut(cx).move_tab(from, &tab, to, before) {
            if let Some(device) = device {
                self.set_workspace_panel_device(to, device, cx);
            }
            self.panel_layout_mut(cx).focused = previous_focus;
            self.focus_workspace_tab(to, tab, window, cx);
        }
    }

    fn split_workspace_tab(
        &mut self,
        drag: &PanelTabDrag,
        beside: u64,
        edge: PanelEdge,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if drag.workspace != self.workspace_layout_key(cx) {
            return;
        }
        let (beside, edge) = self
            .workspace_panels
            .split_previews
            .iter()
            .find(|((workspace, _, _), preview)| workspace == &drag.workspace && preview.active)
            .map_or((beside, edge), |((_, panel, right), _)| (*panel, *right));
        self.park_workspace_draft(cx);
        let device = self.moving_new_tab_device(drag.panel, &drag.tab, cx);
        if let Some(panel) = self
            .panel_layout_mut(cx)
            .split_tab(drag.panel, &drag.tab, beside, edge)
        {
            if let Some(device) = device {
                self.set_workspace_panel_device(panel, device, cx);
            }
            self.start_panel_insertion(panel, beside, cx);
            self.workspace_panels.split_previews.clear();
            self.workspace_panels.split_drag_bounds.clear();
            self.focus_workspace_tab(panel, drag.tab.clone(), window, cx);
        }
    }

    fn track_workspace_tab_drag(
        &mut self,
        drag: PanelTabDrag,
        pointer: Point<Pixels>,
        cx: &mut Context<Self>,
    ) {
        let workspace = self.workspace_layout_key(cx);
        if drag.workspace != workspace {
            self.workspace_panels.blocked_split = false;
            self.workspace_panels.split_drag_bounds.clear();
            self.update_panel_split_preview(None, cx);
            return;
        }
        let new_drag = self
            .workspace_panels
            .split_drag
            .as_ref()
            .is_none_or(|previous| {
                previous.workspace != drag.workspace
                    || previous.panel != drag.panel
                    || previous.tab != drag.tab
            });
        if new_drag || self.workspace_panels.split_drag_bounds.is_empty() {
            self.workspace_panels.split_drag_bounds = self
                .workspace_panels
                .panel_bounds
                .borrow()
                .iter()
                .filter(|((key, _), _)| key == &workspace)
                .map(|((_, panel), bounds)| (*panel, *bounds))
                .collect();
        }
        let active = self
            .workspace_panels
            .split_previews
            .iter()
            .find(|((key, _, _), preview)| key == &workspace && preview.active)
            .map(|((_, panel, right), _)| (*panel, *right));
        let target = self.panel_layout(cx).and_then(|layout| {
            layout.split_drop_target(
                drag.panel,
                &drag.tab,
                pointer,
                &self.workspace_panels.split_drag_bounds,
                active,
            )
        });
        self.workspace_panels.blocked_split = target.is_some_and(|(panel, edge)| {
            !self
                .panel_layout(cx)
                .unwrap()
                .can_split_at(drag.panel, &drag.tab, panel, edge)
        });
        let target = target.filter(|_| !self.workspace_panels.blocked_split);
        self.workspace_panels.split_drag = Some(drag);
        self.update_panel_split_preview(target, cx);
    }

    fn start_panel_insertion(&mut self, new_panel: u64, beside: u64, cx: &App) {
        let workspace = self.workspace_layout_key(cx);
        let mut frames: HashMap<_, _> = self
            .workspace_panels
            .rendered_frames
            .iter()
            .filter(|((key, _), _)| key == &workspace)
            .map(|((_, panel), frame)| (*panel, *frame))
            .collect();
        if let Some((_, ghost)) =
            self.workspace_panels
                .rendered_ghosts
                .iter()
                .find(|((key, panel, edge), _)| {
                    key == &workspace
                        && *panel == beside
                        && self
                            .workspace_panels
                            .split_previews
                            .get(&(key.clone(), *panel, *edge))
                            .is_some_and(|preview| preview.active)
                })
        {
            frames.insert(new_panel, *ghost);
        }
        // Splitting one panel: its tab row becomes the strip's lane above the
        // frame, so the frame starts that much shorter and its bottom stays put.
        if INSTRUMENT_STRIP {
            for frame in frames.values_mut() {
                frame.height -= frame.header_height;
                frame.header_height = 0.0;
            }
        }
        self.workspace_panels.layout_transition = Some(PanelLayoutTransition {
            workspace,
            started: std::time::Instant::now(),
            frames,
        });
    }

    fn drop_workspace_tab(
        &mut self,
        drag: &PanelTabDrag,
        to: u64,
        before: Option<usize>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.reject_foreign_window_drag(cx) {
            return;
        }
        if drag.workspace != self.workspace_layout_key(cx) || self.workspace_panels.blocked_split {
            return;
        }
        let target = self
            .workspace_panels
            .split_previews
            .iter()
            .find(|((key, _, _), preview)| key == &drag.workspace && preview.active)
            .map(|((_, panel, edge), _)| (*panel, *edge));
        if let Some((panel, edge)) = target {
            self.split_workspace_tab(drag, panel, edge, window, cx);
        } else {
            let strip = self
                .panel_layout(cx)
                .is_some_and(WorkspaceLayout::uses_strip);
            let before = if self.workspace_panels.window_drag.is_some() && !strip {
                // The release must use the same measured slot as its cue,
                // including the right half of a tab and clipped strip bounds.
                let Some(hover) = self.panel_tab_drop_at(window.mouse_position(), window, cx)
                    .filter(|hover| hover.panel == to) else { return; };
                if hover.header { hover.before } else { before }
            } else { before };
            self.move_workspace_tab(drag.panel, drag.tab.clone(), to, before, window, cx);
        }
    }

    fn update_panel_split_preview(
        &mut self,
        target: Option<(u64, PanelEdge)>,
        cx: &mut Context<Self>,
    ) {
        let workspace = self.workspace_layout_key(cx);
        let now = std::time::Instant::now();
        let reduced = self.reduced_motion;
        let mut changed = false;
        for ((key, panel, right), preview) in &mut self.workspace_panels.split_previews {
            let active = key == &workspace && target == Some((*panel, *right));
            if preview.active != active {
                preview.retarget(active, reduced, now);
                changed = true;
            }
        }
        if let Some((panel, right)) = target {
            self.workspace_panels
                .split_previews
                .entry((workspace, panel, right))
                .or_insert_with(|| {
                    changed = true;
                    let mut preview = PanelSplitReveal::default();
                    preview.retarget(true, reduced, now);
                    preview
                });
        }
        if changed {
            cx.notify();
        }
    }

    fn render_panel_split_ghost(
        &mut self,
        panel: u64,
        edge: PanelEdge,
        frame: PanelFrame,
        reveal: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).clone();
        div()
            .id(("panel-split-ghost", (panel << 2) | edge as u64))
            .debug_selector(move || format!("panel-split-ghost-{panel}-{}", edge.name()))
            .absolute()
            .left(px(frame.x))
            .top(px(frame.y))
            .w(px(frame.width.max(0.0)))
            .h(px(frame.height.max(0.0)))
            .pt(px(frame.header_height))
            .opacity(reveal)
            .occlude()
            .on_drop::<PanelTabDrag>(cx.listener(move |this, drag, window, cx| {
                this.drop_workspace_tab(drag, panel, None, window, cx);
                cx.stop_propagation();
            }))
            .child(
                div()
                    .size_full()
                    .rounded(px(10.0))
                    .border_1()
                    .border_color(theme.text_muted.opacity(0.3))
                    .bg(theme.element_hover.opacity(0.3)),
            )
            .into_any_element()
    }

    pub(super) fn close_workspace_tab(
        &mut self,
        panel: u64,
        tab: PanelTab,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let PanelTab::Surface {
            surface: RightSurface::Diff(id),
            ..
        } = &tab
            && self.retain_pending_review_draft(*id, cx)
        {
            self.focus_workspace_tab(panel, tab, window, cx);
            return;
        }
        let closing_focused_tab = self.panel_layout(cx).is_some_and(|layout| {
            layout.focused == panel
                && layout.panel(panel).and_then(|panel| panel.selected()) == Some(&tab)
        });
        let recoverable = matches!(tab, PanelTab::Chat(_) | PanelTab::Draft(_) | PanelTab::New(_));
        if recoverable {
            self.remember_closed_workspace_chat(panel, &tab, cx);
        }
        if let PanelTab::Draft(id) | PanelTab::New(id) = &tab {
            self.workspace_panels.drafts.remove(id);
        }
        if let PanelTab::Surface { owner, surface } = &tab {
            if let RightSurface::File(id) = surface {
                if let Some(file) = self.file_surfaces.get(id).cloned() {
                    match file.update(cx, |f, cx| f.prepare_close(cx)) {
                        FilesCloseDisposition::Allow => {
                            self.complete_file_close(*surface, owner, cx)
                        }
                        _ => {
                            self.pending_file_closes.insert(*surface);
                            return;
                        }
                    }
                }
            } else if let RightSurface::Browser(id) = surface {
                if let Some(b) = self.browsers.remove(id) {
                    b.update(cx, |b, cx| b.close(cx));
                }
                self.browser_subs.remove(id);
            }
            match surface {
                RightSurface::Diff(id) => {
                    self.diffs.remove(id);
                    self.diff_subs.remove(id);
                }
                RightSurface::Subagent(id) => {
                    if let Some(tab) = self.subagent_tabs.remove(id) {
                        self.state
                            .update(cx, |s, _| s.unwatch_subagent_doc(&tab.doc_id));
                    }
                }
                RightSurface::Terminal(key) => {
                    let p = self.right_terminal_panel(cx);
                    p.update(cx, |p, cx| {
                        p.pin_session(owner.clone());
                        p.close_tab_by_key(*key, window, cx);
                    });
                }
                _ => {}
            }
            if let Some(tabs) = self.right_tabs.get_mut(owner) {
                tabs.retain(|s| s != surface);
            }
        }
        if let PanelTab::Terminal(id) = tab {
            if let (Some(t), Some(key)) = (
                self.workspace_panels.terminals.remove(&id),
                self.workspace_panels.terminal_keys.remove(&id),
            ) {
                t.update(cx, |t, cx| {
                    t.close_tab_by_key(key, window, cx);
                    // ⌘D adds a second terminal to this tab, which goes with it.
                    t.close_all_tabs(window, cx);
                });
            }
        }
        if let PanelTab::FileTree(id) = &tab {
            self.workspace_panels.explorers.remove(id);
        }
        self.workspace_panels.inactive_composers.remove(&tab);
        self.workspace_panels.composer_layouts.remove(&tab);
        self.panel_layout_mut(cx).remove_tab(panel, &tab);
        let next = self
            .panel_layout(cx)
            .and_then(|l| l.panel(panel))
            .and_then(|p| p.selected())
            .cloned();
        if closing_focused_tab {
            if let Some(next) = next {
                if recoverable {
                    // The old draft was parked before removal. Parking again
                    // now would store it under the newly selected draft tab.
                    self.activate_workspace_tab(panel, next, window, cx);
                } else {
                    self.focus_workspace_tab(panel, next, window, cx);
                }
            } else {
                self.select_workspace_chat(None, cx);
                self.panel_layout_mut(cx).last_selected = Some(None);
            }
        }
        if let PanelTab::Chat(chat) = &tab {
            // The workspace owns placement. Retire this session's legacy split
            // mirror too, so restoring/importing it cannot reopen a closed tab.
            if let Some(split) = self.chat_split.as_mut() {
                for id in split.panes.iter_mut().chain(&mut split.vanished) {
                    if id.as_deref() == Some(chat) {
                        *id = None;
                    }
                }
            }
            if self.state.read(cx).selected_chat.as_deref() == Some(chat) {
                self.select_workspace_chat(None, cx);
                self.panel_layout_mut(cx).last_selected = Some(None);
            }
            self.chat_split_selected = self.state.read(cx).selected_chat.clone();
        }
        if recoverable {
            self.persist_chat_tabs(cx);
            settings::flush(cx);
        }
        cx.notify();
    }

    pub(super) fn close_workspace_panel(&mut self, panel: u64, window: &mut Window, cx: &mut Context<Self>) {
        let Some(layout) = self.panel_layout(cx).filter(|l| l.panels.len() > 1) else {
            return;
        };
        let Some(index) = layout.panels.iter().position(|p| p.id == panel) else {
            return;
        };
        let focused = layout.focused;
        let tabs = layout.panels[index].tabs.clone();
        // Preflight before closing any tab, so a protected note does not leave
        // the panel half-closed after its other tabs have already disappeared.
        for tab in &tabs {
            if let PanelTab::Surface {
                surface: RightSurface::Diff(id),
                ..
            } = tab
                && self.retain_pending_review_draft(*id, cx)
            {
                self.focus_workspace_tab(panel, tab.clone(), window, cx);
                return;
            }
        }
        for tab in tabs {
            self.close_workspace_tab_by_button(panel, tab, window, cx);
        }
        let layout = self.panel_layout_mut(cx);
        if layout.panel(panel).is_some_and(|p| p.tabs.is_empty()) {
            layout.panels.remove(index);
            layout.expanded = None;
            layout.equalize();
        }
        layout.focused = if layout.panel(focused).is_some() {
            focused
        } else {
            layout.panels[index.min(layout.panels.len() - 1)].id
        };
        let focused = layout.focused;
        let next = layout.panel(focused).and_then(|p| p.selected()).cloned();
        if let Some(tab) = next {
            self.focus_workspace_tab(focused, tab, window, cx);
        }
        cx.notify();
    }

    pub(super) fn dismiss_workspace_panel_overlay(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if let Some(menu) = self.workspace_panels.menu.take() {
            let control = if let Some(tab) = &menu.tab {
                self.panel_layout(cx)
                    .and_then(|layout| layout.panel(menu.panel))
                    .and_then(|panel| panel.tabs.iter().position(|candidate| candidate == tab))
                    .map(|index| format!("panel-tab-{}-{index}", menu.panel))
            } else {
                Some(format!(
                    "panel-{}-{}",
                    if menu.placement {
                        "placement"
                    } else {
                        "add-tab"
                    },
                    menu.panel
                ))
            };
            if let Some(focus) =
                control.and_then(|control| self.workspace_panels.controls.get(&control))
            {
                window.focus(focus, cx);
            }
            self.workspace_panels.target = None;
            cx.notify();
            return true;
        }
        if self.panel_layout_mut(cx).expanded.take().is_some() {
            cx.notify();
            return true;
        }
        false
    }

    fn open_panel_menu(
        &mut self,
        panel: u64,
        tab: Option<PanelTab>,
        position: Point<Pixels>,
        placement: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.park_workspace_draft(cx);
        self.workspace_panels.target = None;
        let mut rows = vec![];
        let vertical = self.panel_layout_mut(cx).axis == SplitAxis::Vertical;
        let neighbor_label = |after| match (vertical, after) {
            (false, false) => "Move to left panel",
            (false, true) => "Move to right panel",
            (true, false) => "Move to panel above",
            (true, true) => "Move to panel below",
        };
        let arrow = |after| match (vertical, after) {
            (false, false) => icons::ALT_ARROW_LEFT,
            (false, true) => icons::ALT_ARROW_RIGHT,
            (true, false) => icons::ALT_ARROW_UP,
            (true, true) => icons::ALT_ARROW_DOWN,
        };
        if tab.is_some() {
            if let Some(PanelTab::Surface {
                surface: RightSurface::Browser(id),
                ..
            }) = &tab
                && let Some(label) = self
                    .browsers
                    .get(id)
                    .and_then(|browser| browser.read(cx).external_action_label())
            {
                rows.push((
                    label.into(),
                    icons::ARROW_UP_RIGHT,
                    MenuAction::OpenBrowserExternal(*id),
                ));
            }
            let layout = self.panel_layout_mut(cx);
            for after in [false, true] {
                if let Some(to) = layout.neighbor(panel, after) {
                    rows.push((neighbor_label(after).into(), arrow(after), MenuAction::Move(to)));
                }
            }
            rows.push(("Move to new window".into(), icons::ARROW_UP_RIGHT, MenuAction::MoveToWindow));
            rows.push(("Close tab".into(), icons::CLOSE, MenuAction::CloseTab));
        } else if placement {
            let layout = self.panel_layout_mut(cx);
            for after in [false, true] {
                if layout.neighbor(panel, after).is_some() {
                    let label = match (vertical, after) {
                        (false, false) => "Move left",
                        (false, true) => "Move right",
                        (true, false) => "Move up",
                        (true, true) => "Move down",
                    };
                    rows.push((label.into(), arrow(after), MenuAction::MovePanel(after)));
                }
            }
            rows.push((
                "Add panel right".into(),
                icons::ALT_ARROW_RIGHT,
                MenuAction::AddPanel(SplitAxis::Horizontal),
            ));
            rows.push((
                "Add panel below".into(),
                icons::ALT_ARROW_DOWN,
                MenuAction::AddPanel(SplitAxis::Vertical),
            ));
        } else {
            return;
        }
        let focus = cx.focus_handle();
        window.focus(&focus, cx);
        self.workspace_panels.menu = Some(PanelMenu {
            panel,
            tab,
            placement,
            position,
            rows,
            selected: 0,
            focus,
        });
        cx.notify();
    }

    fn activate_panel_menu(&mut self, index: usize, window: &mut Window, cx: &mut Context<Self>) {
        let can_stack = self
            .panel_layout(cx)
            .is_some_and(|layout| layout.can_add_panel(SplitAxis::Vertical));
        if !can_stack
            && self
                .workspace_panels
                .menu
                .as_ref()
                .and_then(|menu| menu.rows.get(index))
                .is_some_and(|(_, _, action)| {
                    matches!(action, MenuAction::AddPanel(SplitAxis::Vertical))
                })
        {
            return;
        }
        let Some(menu) = self.workspace_panels.menu.take() else {
            return;
        };
        let Some((_, _, action)) = menu.rows.get(index).cloned() else {
            return;
        };
        match action {
            MenuAction::MoveToWindow => {
                if let Some(tab) = menu.tab {
                    if let Err(error) = self.move_workspace_tab_to_new_window(menu.panel, tab, None, window, cx) {
                        self.sidebar_notice = Some(error.into());
                        cx.notify();
                    }
                }
            }
            MenuAction::OpenBrowserExternal(id) => {
                if let Some(tab) = menu.tab {
                    // Source previews must be visible before their OpenSource
                    // event is routed by the shell's browser subscription.
                    self.focus_workspace_tab(menu.panel, tab, window, cx);
                }
                if let Some(browser) = self.browsers.get(&id).cloned() {
                    browser.update(cx, |browser, cx| browser.open_external(cx));
                }
            }
            MenuAction::Move(to) => {
                if let Some(tab) = menu.tab {
                    self.move_workspace_tab(menu.panel, tab, to, None, window, cx);
                }
            }
            MenuAction::MovePanel(right) => {
                self.panel_layout_mut(cx).reorder_panel(menu.panel, right);
                if let Some(focus) = self
                    .workspace_panels
                    .controls
                    .get(&format!("panel-placement-{}", menu.panel))
                {
                    window.focus(focus, cx);
                }
            }
            MenuAction::AddPanel(axis) => {
                let device = self.workspace_panel_device(menu.panel, cx);
                self.panel_layout_mut(cx).axis = axis;
                let id = self.panel_layout_mut(cx).add_panel(menu.panel);
                self.set_workspace_panel_device(id, device, cx);
                self.start_panel_insertion(id, menu.panel, cx);
                self.composer.update(cx, |c, _| c.focus_pending = INSTRUMENT_STRIP);
                if !INSTRUMENT_STRIP {
                    let focus = self
                        .workspace_panels
                        .controls
                        .entry(format!("panel-header-{id}"))
                        .or_insert_with(|| cx.focus_handle().tab_stop(true));
                    window.focus(focus, cx);
                }
            }
            MenuAction::CloseTab => {
                if let Some(tab) = menu.tab {
                    self.close_workspace_tab_by_button(menu.panel, tab, window, cx);
                }
            }
            MenuAction::SelectTab(index) => {
                let tab = self
                    .panel_layout(cx)
                    .and_then(|layout| layout.panel(menu.panel))
                    .and_then(|panel| panel.tabs.get(index).cloned());
                if let Some(tab) = tab {
                    self.focus_workspace_tab(menu.panel, tab, window, cx);
                }
            }
            MenuAction::NewTab => {
                self.workspace_panels.target = Some(menu.panel);
                self.workspace_new_tab(cx);
                self.focus_workspace_new_tab(window, cx);
            }
            MenuAction::ToggleExpand => {
                let layout = self.panel_layout_mut(cx);
                layout.expanded = if layout.expanded == Some(menu.panel) {
                    None
                } else {
                    Some(menu.panel)
                };
            }
            MenuAction::ClosePanel => self.close_workspace_panel(menu.panel, window, cx),
        }
        self.workspace_panels.target = None;
        cx.notify();
    }

    fn render_panel_menu(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let menu = self.workspace_panels.menu.clone()?;
        let theme = Theme::of(cx).for_popup();
        let x = f32::from(menu.position.x)
            .min(self.viewport_width - 242.0)
            .max(8.0);
        let y = f32::from(menu.position.y)
            .min(self.viewport_height - (menu.rows.len() as f32 * 32.0 + 16.0))
            .max(8.0);
        let mut card = popover::popover_card(&theme)
            .w(px(234.0))
            .track_focus(&menu.focus)
            .flex()
            .flex_col()
            .on_mouse_down_out(cx.listener(|this, _, _, cx| {
                this.workspace_panels.menu = None;
                this.workspace_panels.target = None;
                cx.notify();
            }))
            .on_key_down(cx.listener(|this, event: &gpui::KeyDownEvent, window, cx| {
                let can_stack = this
                    .panel_layout(cx)
                    .is_some_and(|layout| layout.can_add_panel(SplitAxis::Vertical));
                let Some(menu) = this.workspace_panels.menu.as_mut() else {
                    return;
                };
                match event.keystroke.key.as_str() {
                    "down" | "arrowdown" | "up" | "arrowup" => {
                        let step = if matches!(event.keystroke.key.as_str(), "down" | "arrowdown") {
                            1
                        } else {
                            menu.rows.len() - 1
                        };
                        for _ in 0..menu.rows.len() {
                            menu.selected = (menu.selected + step) % menu.rows.len();
                            if can_stack
                                || !matches!(
                                    menu.rows[menu.selected].2,
                                    MenuAction::AddPanel(SplitAxis::Vertical)
                                )
                            {
                                break;
                            }
                        }
                    }
                    "enter" | "space" => {
                        let ix = menu.selected;
                        this.activate_panel_menu(ix, window, cx);
                    }
                    "escape" => {
                        let control = format!(
                            "panel-{}-{}",
                            if menu.placement {
                                "placement"
                            } else {
                                "add-tab"
                            },
                            menu.panel
                        );
                        if menu.tab.is_none() {
                            if let Some(focus) = this.workspace_panels.controls.get(&control) {
                                window.focus(focus, cx);
                            }
                        }
                        this.workspace_panels.menu = None;
                        this.workspace_panels.target = None;
                    }
                    _ => return,
                }
                cx.stop_propagation();
                cx.notify();
            }));
        for (ix, (title, glyph, action)) in menu.rows.iter().enumerate() {
            let enabled = !matches!(action, MenuAction::AddPanel(SplitAxis::Vertical))
                || self
                    .panel_layout(cx)
                    .is_some_and(|layout| layout.can_add_panel(SplitAxis::Vertical));
            card = card.child(
                popover::menu_row(
                    &theme,
                    enabled && ix == menu.selected,
                    format!("panel-menu-{ix}"),
                )
                .id(("workspace-menu-row", ix))
                .role(gpui::Role::Button)
                .aria_label(if enabled {
                    title.to_string()
                } else {
                    format!("{title}, unavailable at this window height")
                })
                .when(enabled, |row| {
                    row.on_click(cx.listener(move |this, _, window, cx| {
                        this.activate_panel_menu(ix, window, cx)
                    }))
                })
                .when(!enabled, |row| {
                    row.opacity(0.4).tooltip(|_, cx| {
                        cx.new(|_| SurfaceTabTooltip {
                            text: "Make the window taller to add another stacked panel".into(),
                        })
                        .into()
                    })
                })
                .child(icon(glyph).size(px(15.0)).text_color(theme.text_muted))
                .child(div().flex_1().child(title.clone())),
            );
        }
        #[cfg(feature = "browser-fixture")]
        let card = {
            let measured = self.workspace_panels.fixture_menu_bounds.clone();
            card.on_prepaint(move |bounds, _, _| measured.set(Some(bounds)))
        };
        Some(popover::menu_at(
            "workspace-panel-menu",
            point(px(x), px(y)),
            card.into_any_element(),
            None,
        ))
    }

    fn render_workspace_button(
        &mut self,
        id: String,
        glyph: &'static str,
        label: &'static str,
        active: bool,
        action: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
        cx: &mut Context<Self>,
    ) -> gpui::Stateful<gpui::Div> {
        let theme = Theme::of(cx).clone();
        let hover_bg = if active {
            theme.active_bg(theme.element_hover)
        } else {
            theme.element_hover
        };
        let focus = self
            .workspace_panels
            .controls
            .entry(id.clone())
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let action = std::rc::Rc::new(action);
        let key_action = action.clone();
        div()
            .id(SharedString::from(id.clone()))
            .debug_selector(move || id.clone())
            .size(px(24.0))
            .flex_none()
            .flex()
            .items_center()
            .justify_center()
            .rounded(px(5.0))
            .cursor_pointer()
            .role(gpui::Role::Button)
            .aria_label(label)
            .track_focus(&focus)
            .when(active, |s| s.bg(hover_bg))
            .hover(move |s| s.bg(hover_bg))
            .focus_visible(move |s| s.bg(hover_bg))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .on_click(cx.listener(move |this, _, window, cx| {
                cx.stop_propagation();
                action(this, window, cx);
            }))
            .on_key_down(
                cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                        key_action(this, window, cx);
                        cx.stop_propagation();
                    }
                }),
            )
            .child(icon(glyph).size(px(14.0)).text_color(if active {
                theme.text
            } else {
                theme.text_muted
            }))
    }

    fn render_workspace_header(
        &mut self,
        panel: &WorkspacePanel,
        expanded: bool,
        width: f32,
        height: f32,
        leading_inset: f32,
        trailing_inset: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // One pixel of paint overlaps the body's top border to erase the seam.
        let strip_height = height + 1.0;
        let tab_top = (height - PANEL_TAB_HEIGHT - STACKED_CLEARANCE).max(0.0);
        let controls_top = tab_top;
        let theme = Theme::of(cx).clone();
        let id = panel.id;
        let workspace = self.workspace_layout_key(cx);
        let header_focus = self
            .workspace_panels
            .controls
            .entry(format!("panel-header-{id}"))
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let scroll_key = (workspace.clone(), id);
        let menu_open = self
            .workspace_panels
            .menu
            .as_ref()
            .is_some_and(|m| m.panel == id);
        // Focus reveals them for keyboard use only: a click leaves focus behind,
        // which must not keep them up once the pointer has gone.
        let controls_focused = window.last_input_was_keyboard()
            && (header_focus.contains_focused(window, cx)
                || ["placement", "add-tab", "expand", "close"]
                    .iter()
                    .any(|name| {
                        self.workspace_panels
                            .controls
                            .get(&format!("panel-{name}-{id}"))
                            .is_some_and(|focus| focus.is_focused(window))
                    }));
        let header = self
            .workspace_panels
            .headers
            .entry(scroll_key.clone())
            .or_default();
        let controls_visible = header.hovered
            || header.controls_hovered
            || header.expand_hovered
            || controls_focused
            || menu_open;
        let fade_key = format!("panel-controls-{}-{workspace}-{id}", cx.entity_id());
        if header.controls_visible != controls_visible {
            motion::set_hover(&fade_key, controls_visible, self.reduced_motion);
            header.controls_visible = controls_visible;
        }
        let controls_t = motion::hover_t(&fade_key);
        let can_close = self.panel_layout(cx).is_some_and(|l| l.panels.len() > 1);
        let tab_width = panel_tab_width(width - leading_inset - (trailing_inset - 4.0), panel.tabs.len());
        // New tab sits right after the last tab, where the next one will open.
        // Where the hover controls would cover it, it stays with them instead.
        let other_controls: f32 = if can_close { 3.0 } else { 2.0 };
        let add_after_tabs = panel.tabs.len() as f32 * tab_width
            + panel.tabs.len().saturating_sub(1) as f32 * 3.0
            + TAB_SHOULDER
            + INLINE_ADD_WIDTH
            + other_controls * 24.0
            + (other_controls - 1.0) * 2.0
            + 8.0
            + 3.0
            <= width - leading_inset - trailing_inset;
        let control_count = match (can_close, add_after_tabs) {
            (true, false) => 4.0,
            (true, true) | (false, false) => 3.0,
            (false, true) => 2.0,
        };
        let controls_width = control_count * 24.0 + (control_count - 1.0) * 2.0 + 8.0;
        let restore_inset = if expanded {
            24.0 + if can_close { 26.0 } else { 0.0 } + 3.0
        } else {
            0.0
        };
        let controls_inset = ((controls_width + 3.0) * controls_t).max(restore_inset);
        let tab_contexts: Vec<_> = panel
            .tabs
            .iter()
            .map(|tab| {
                let (title, _) = self.panel_tab_label(tab, cx);
                self.panel_tab_context(tab, panel.id, &title, cx)
            })
            .collect();
        let attention_tabs: Vec<_> = tab_contexts
            .iter()
            .enumerate()
            .filter_map(|(index, context)| {
                context
                    .as_ref()
                    .and_then(TabContext::attention)
                    .map(|attention| (index, attention))
            })
            .collect();
        let strip_width = width - leading_inset - trailing_inset;
        let tabs_overflow = panel.tabs.len() as f32 * 112.0
            + panel.tabs.len().saturating_sub(1) as f32 * 3.0
            + TAB_SHOULDER
            > strip_width;
        let attention_hidden = tabs_overflow
            && attention_tabs.iter().any(|(index, _)| {
                let viewport = self
                    .workspace_panels
                    .header_tab_bounds
                    .borrow()
                    .get(&(workspace.clone(), id))
                    .copied();
                let bounds = self
                    .workspace_panels
                    .window_tab_bounds
                    .borrow()
                    .get(&(workspace.clone(), id, *index))
                    .copied();
                match (viewport, bounds) {
                    (Some(viewport), Some(bounds)) => {
                        bounds.left() < viewport.left() - px(1.0)
                            || bounds.right() > viewport.right() - px(44.0) + px(1.0)
                    }
                    _ => true,
                }
            });
        let attention_inset = if attention_hidden { 44.0 } else { 0.0 };
        let controls_inset = controls_inset + attention_inset;
        self.workspace_panels
            .active_tab_bounds
            .borrow_mut()
            .remove(&(workspace.clone(), id));
        // Keep the last painted positions while constructing the insertion
        // cue. Each tab's canvas replaces them during this frame's prepaint.
        self.workspace_panels.window_tab_bounds.borrow_mut().retain(
            |(key, panel_id, index), _| {
                key != &workspace || *panel_id != id || *index < panel.tabs.len()
            },
        );
        let scroll = self
            .workspace_panels
            .scrolls
            .entry(scroll_key.clone())
            .or_default()
            .clone();
        let reveal = (
            panel.selected().cloned(),
            panel.tabs.len(),
            (width - leading_inset).to_bits(),
        );
        if self.workspace_panels.revealed_tabs.get(&scroll_key) != Some(&reveal) {
            scroll.scroll_to_item(panel.active);
            self.workspace_panels
                .revealed_tabs
                .insert(scroll_key, reveal);
        }
        let mut strip = div()
            .id(("panel-tabs", id))
            .flex_1()
            .min_w_0()
            .h(px(strip_height))
            .pt(px(tab_top))
            .pr(px(TAB_SHOULDER))
            .flex()
            .items_start()
            .gap(px(3.0))
            .overflow_x_scroll()
            .track_scroll(&scroll)
            .on_drop::<PanelTabDrag>(cx.listener(move |this, drag: &PanelTabDrag, window, cx| {
                if drag.workspace == this.workspace_layout_key(cx) {
                    this.drop_workspace_tab(drag, id, None, window, cx);
                }
                cx.stop_propagation();
            }));
        for (ix, tab) in panel.tabs.iter().enumerate() {
            let (title, glyph) = self.panel_tab_label(tab, cx);
            let attention = tab_contexts[ix].as_ref().and_then(TabContext::attention);
            let glyph_color = attention.map_or(theme.text_muted, |status| status.color(&theme));
            let glyph = attention.map_or(glyph, TabAttention::glyph);
            #[cfg(feature = "appshots-fixture")]
            let (glyph, glyph_color) = if super::reconciliation_design_fixture::attention_icon(id, ix, cx) {
                (icons::INFO_CIRCLE, theme.warning)
            } else {
                (glyph, glyph_color)
            };
            let favicon = match tab {
                PanelTab::Surface {
                    surface: RightSurface::Browser(id),
                    ..
                } => self
                    .browsers
                    .get(id)
                    .and_then(|browser| browser.read(cx).favicon.clone()),
                _ => None,
            };
            let dragging_tab = self.workspace_panels.dragging_tab.clone();
            let drag_source = cx.weak_entity();
            let drag_outside = self.workspace_panels.drag_preview_visible.clone();
            let drag_icon = self.panel_tab_label(tab, cx).1;
            let drag = PanelTabDrag {
                workspace: workspace.clone(),
                panel: id,
                tab: tab.clone(),
                title: title.clone(),
            };
            let picked = tab.clone();
            let context_tab = tab.clone();
            let close = tab.clone();
            let button_close = tab.clone();
            let active = ix == panel.active;
            let focus = self
                .workspace_panels
                .controls
                .entry(format!("panel-tab-{id}-{ix}"))
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            let key_pick = picked.clone();
            let hover_key = format!("panel-tab-hover-{}-{workspace}-{id}-{ix}", cx.entity_id());
            let context = tab_contexts[ix].as_ref();
            // Keep the title row steady while a tab is being placed beside it.
            let tab_drag_active = window_drag::drag_source_window(cx).is_some();
            let context_hovered = !tab_drag_active
                && (self.workspace_panels.hovered_tab.as_deref() == Some(&hover_key)
                    || focus.is_focused(window));
            let context_progress = self.workspace_panels.tab_context_fades.0.transition_at(
                &hover_key,
                context_hovered,
                tab_drag_active || motion::reduced_motion(cx),
                std::time::Instant::now(),
            );
            let tooltip = context
                .map(|context| context.tooltip.clone())
                .unwrap_or_else(|| title.clone());
            let labels = self.render_panel_tab_labels(
                &format!("panel-tab-{id}-{ix}"),
                title.clone(),
                context,
                context_progress,
                active,
                &theme,
                cx,
            );
            let status = context.map(|context| {
                self.render_panel_tab_status(
                    &format!("panel-tab-{id}-{ix}"),
                    context,
                    context_progress,
                    &theme,
                    cx,
                )
            });
            let tab_bounds = self.workspace_panels.active_tab_bounds.clone();
            let tab_bounds_key = (workspace.clone(), id);
            let window_tab_bounds = self.workspace_panels.window_tab_bounds.clone();
            let window_tab_key = (workspace.clone(), id, ix);
            let hover_t = motion::hover_t(&hover_key);
            let next_hover_t = motion::hover_t(&format!(
                "panel-tab-hover-{}-{workspace}-{id}-{}",
                cx.entity_id(),
                ix + 1
            ));
            let separator = !active && ix + 1 < panel.tabs.len() && ix + 1 != panel.active;
            let source_dragged = cx.has_active_drag()
                && self.workspace_panels.window_drag.as_ref().is_some_and(|drag| {
                    drag.payload.panel == id && drag.payload.tab == *tab
                });
            strip = strip.child(
                div()
                    .id(("panel-tab", (id << 32) | ix as u64))
                    .debug_selector(move || format!("panel-tab-{id}-{ix}"))
                    .group(format!("panel-tab-{id}-{ix}"))
                    .flex_none()
                    .w(px(tab_width))
                    .h(px(PANEL_TAB_HEIGHT + STACKED_CLEARANCE))
                    .pb(px(STACKED_CLEARANCE))
                    .relative()
                    .when(source_dragged, |tab| tab.opacity(0.24))
                    .flex()
                    .flex_col()
                    .cursor_pointer()
                    .role(gpui::Role::Button)
                    .aria_label(tooltip.clone())
                    .track_focus(&focus)
                    .on_hover(cx.listener(move |this, hovered: &bool, window, cx| {
                        motion::set_hover(&hover_key, *hovered, motion::reduced_motion(cx));
                        if *hovered {
                            this.workspace_panels.hovered_tab = Some(hover_key.clone());
                        } else if this.workspace_panels.hovered_tab.as_deref() == Some(&hover_key) {
                            this.workspace_panels.hovered_tab = None;
                        }
                        window.redraw_root();
                    }))
                    .on_mouse_down(MouseButton::Left, |_, window, cx| {
                        window.prevent_default();
                        cx.stop_propagation();
                    })
                    .on_click(cx.listener(move |this, _, window, cx| {
                        cx.stop_propagation();
                        this.focus_workspace_tab(id, picked.clone(), window, cx);
                    }))
                    .on_key_down(cx.listener(
                        move |this, event: &gpui::KeyDownEvent, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                this.focus_workspace_tab(id, key_pick.clone(), window, cx);
                                cx.stop_propagation();
                            }
                        },
                    ))
                    .on_mouse_down(
                        MouseButton::Right,
                        cx.listener(move |this, event: &MouseDownEvent, window, cx| {
                            this.open_panel_menu(
                                id,
                                Some(context_tab.clone()),
                                event.position,
                                false,
                                window,
                                cx,
                            );
                            cx.stop_propagation();
                        }),
                    )
                    .on_mouse_down(
                        MouseButton::Middle,
                        cx.listener(move |this, _, window, cx| {
                            this.close_workspace_tab_by_button(id, close.clone(), window, cx);
                            cx.stop_propagation();
                        }),
                    )
                    .on_drag(drag, move |drag, grab, window, cx| {
                        dragging_tab.set(true);
                        cx.stop_propagation();
                        let title = drag.title.clone();
                        let _ = drag_source.update(cx, |this, cx| {
                            this.begin_window_tab_drag(drag.clone(), grab, tab_width, window, cx);
                        });
                        let source = window.window_handle().window_id();
                        let outside = drag_outside.clone();
                        cx.new(|_| window_drag::WindowTabGhost { title, icon: drag_icon, source, outside, width: tab_width })
                    })
                    .on_drop::<PanelTabDrag>(cx.listener(
                        move |this, drag: &PanelTabDrag, window, cx| {
                            if drag.workspace == this.workspace_layout_key(cx) {
                                this.drop_workspace_tab(drag, id, Some(ix), window, cx);
                            }
                            cx.stop_propagation();
                        },
                    ))
                    .tooltip({
                        let title = tooltip.clone();
                        move |_, cx| {
                            cx.new(|_| SurfaceTabTooltip {
                                text: title.clone(),
                            })
                            .into()
                        }
                    })
                    .child(
                        gpui::canvas(
                            move |bounds, _, _| {
                                window_tab_bounds.borrow_mut().insert(window_tab_key.clone(), bounds);
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .inset_0(),
                    )
                    .when(active, |tab| {
                        tab.child(
                            gpui::canvas(
                                move |bounds, _, _| {
                                    tab_bounds.borrow_mut().insert(
                                        tab_bounds_key.clone(),
                                        gpui::Bounds::new(
                                            bounds.origin + point(px(TAB_SHOULDER), px(0.0)),
                                            gpui::size(
                                                px(tab_width),
                                                px(PANEL_TAB_HEIGHT + STACKED_CLEARANCE),
                                            ),
                                        ),
                                    );
                                },
                                |_, _, _, _| {},
                            )
                            .absolute()
                            .left(px(-TAB_SHOULDER))
                            .top_0()
                            .w(px(tab_width + TAB_SHOULDER * 2.0))
                            .h(px(PANEL_TAB_HEIGHT + STACKED_CLEARANCE + 1.0)),
                        )
                    })
                    .when(separator, |tab| {
                        tab.child(
                            div()
                                .absolute()
                                .right(px(-2.0))
                                .top(px(8.0))
                                .w(px(1.0))
                                .h(px(12.0))
                                .bg(theme.border)
                                .opacity(1.0 - hover_t.max(next_hover_t)),
                        )
                    })
                    .child(
                        div()
                            .debug_selector(move || format!("panel-tab-content-{id}-{ix}"))
                            .w_full()
                            .h(px(PANEL_TAB_HEIGHT))
                            .flex_none()
                            .px(px(7.0))
                            .border_1()
                            .border_color(gpui::transparent_black())
                            .rounded(px(6.0))
                            .overflow_hidden()
                            .flex()
                            .items_center()
                            .gap(px(6.0))
                            .when(!active, |cap| cap.bg(theme.element_hover.opacity(hover_t)))
                            .when_some(attention, |cap, status| {
                                cap.bg(status.color(&theme).opacity(0.11))
                            })
                            .when(focus.is_focused(window), |cap| {
                                cap.border_color(theme.accent)
                            })
                            .child(
                                div()
                                    .id(("panel-tab-icon", (id << 32) | ix as u64))
                                    .debug_selector(move || format!("panel-tab-icon-{id}-{ix}"))
                                    .size(px(14.0))
                                    .flex_none()
                                    .relative()
                                    .top(px(if context.is_some_and(TabContext::has_context) {
                                        -6.5 * context_progress
                                    } else {
                                        0.0
                                    }))
                                    .child(if let Some(favicon) = favicon {
                                        div()
                                            .debug_selector(move || {
                                                format!("panel-tab-favicon-{id}-{ix}")
                                            })
                                            .size_full()
                                            .child(
                                                gpui::img(favicon)
                                                    .size_full()
                                                    .object_fit(gpui::ObjectFit::Contain),
                                            )
                                            .into_any_element()
                                    } else {
                                        icon(glyph)
                                            .size_full()
                                            .text_color(glyph_color)
                                            .into_any_element()
                                    }),
                            )
                            .child(labels)
                            .children(status)
                            .child(
                                div()
                                    .id(("panel-tab-close", (id << 32) | ix as u64))
                                    .debug_selector(move || format!("panel-tab-close-{id}-{ix}"))
                                    .size(px(16.0))
                                    .flex_none()
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .rounded(px(4.0))
                                    .opacity(context_progress)
                                    .when(context_progress == 0.0, |s| s.invisible())
                                    .hover(|s| s.bg(theme.ink(0.10)))
                                    .role(gpui::Role::Button)
                                    .aria_label("Close tab")
                                    .on_mouse_down(MouseButton::Left, |_, window, cx| {
                                        window.prevent_default();
                                        cx.stop_propagation();
                                    })
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        cx.stop_propagation();
                                        this.close_workspace_tab_by_button(
                                            id,
                                            button_close.clone(),
                                            window,
                                            cx,
                                        );
                                    }))
                                    .child(
                                        icon(icons::CLOSE)
                                            .size(px(11.0))
                                            .text_color(theme.text_muted),
                                    ),
                            ),
                    ),
            );
        }
        if panel.tabs.is_empty() {
            strip = strip.child(
                div()
                    .debug_selector(move || format!("panel-empty-label-{id}"))
                    .h(px(PANEL_TAB_HEIGHT))
                    .flex()
                    .items_center()
                    .px(px(8.0))
                    .text_size(crate::typography::ui_rems(12.0))
                    .text_color(theme.text_muted)
                    .child("New panel"),
            );
        }
        let mut controls = div()
            .id(("panel-controls", id))
            .debug_selector(move || format!("panel-controls-{id}"))
            .absolute()
            .right(px(trailing_inset + attention_inset))
            .top(px(controls_top))
            .w(px(controls_width))
            .h(px(PANEL_TAB_HEIGHT))
            .p(px(3.0))
            .border_1()
            .border_color(theme.border.opacity(controls_t * 0.85))
            .rounded(px(8.0))
            .bg(theme
                .surface_overlay
                .alpha(if theme.is_frost() { 0.86 } else { 1.0 })
                .opacity(controls_t))
            .shadow(vec![gpui::BoxShadow {
                color: gpui::black().opacity(
                    controls_t
                        * if theme.appearance.is_dark() {
                            0.24
                        } else {
                            0.10
                        },
                ),
                offset: point(px(0.0), px(2.0)),
                blur_radius: px(8.0),
                spread_radius: px(0.0),
                inset: false,
            }])
            .flex_none()
            .flex()
            .items_center()
            .gap(px(2.0))
            // The toolbar occludes the panel's hover hitbox. Keep its own
            // hover state so moving onto a button does not hide the toolbar.
            .on_hover(cx.listener(move |this, hovered: &bool, window, cx| {
                let workspace = this.workspace_layout_key(cx);
                this.workspace_panels
                    .headers
                    .entry((workspace, id))
                    .or_default()
                    .controls_hovered = *hovered;
                window.redraw_root();
            }))
            .when(controls_t > 0.0, |s| s.occlude())
            .when(controls_t == 0.0 && !expanded, |s| s.invisible());
        for (placement, name, glyph, label) in [
            (true, "placement", icons::SPLIT_COLUMNS, "Panel placement"),
            (false, "add-tab", icons::PLUS, "New tab in panel"),
        ] {
            let add_focus = self
                .workspace_panels
                .controls
                .entry(format!("panel-{name}-{id}"))
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            let add_bounds =
                std::rc::Rc::new(std::cell::Cell::new(gpui::Bounds::<Pixels>::default()));
            let measured_add_bounds = add_bounds.clone();
            let mouse_add_bounds = add_bounds.clone();
            let add = div()
                .id((name, id))
                .debug_selector(move || format!("panel-{name}-{id}"))
                .relative()
                .size(px(24.0))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .rounded(px(5.0))
                .cursor_pointer()
                .hover(|s| s.bg(theme.element_hover))
                .focus_visible(|s| s.bg(theme.element_hover))
                .role(gpui::Role::Button)
                .aria_label(label)
                .opacity(controls_t)
                .when(controls_t == 0.0, |s| s.invisible())
                .track_focus(&add_focus)
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |this, _: &MouseDownEvent, window, cx| {
                        if placement {
                            this.open_panel_menu(
                                id,
                                None,
                                mouse_add_bounds.get().bottom_left(),
                                placement,
                                window,
                                cx,
                            );
                        } else {
                            this.workspace_panels.target = Some(id);
                            this.workspace_new_tab(cx);
                            this.focus_workspace_new_tab(window, cx);
                        }
                        cx.stop_propagation();
                    }),
                )
                .on_key_down(
                    cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            if placement {
                                this.open_panel_menu(
                                    id,
                                    None,
                                    add_bounds.get().bottom_left(),
                                    placement,
                                    window,
                                    cx,
                                );
                            } else {
                                this.workspace_panels.target = Some(id);
                                this.workspace_new_tab(cx);
                                this.focus_workspace_new_tab(window, cx);
                            }
                            cx.stop_propagation();
                        }
                    }),
                )
                .when(!placement && add_after_tabs, |s| {
                    s.mt(px((PANEL_TAB_HEIGHT - 24.0) / 2.0))
                })
                .tooltip(move |_, cx| cx.new(|_| SurfaceTabTooltip { text: label.into() }).into())
                .child(icon(glyph).size(px(14.0)).text_color(theme.text_muted))
                .child(
                    gpui::canvas(
                        move |bounds, _, _| measured_add_bounds.set(bounds),
                        |_, _, _, _| {},
                    )
                    .absolute()
                    .inset_0(),
                );
            if !placement && add_after_tabs {
                strip = strip.child(add);
            } else {
                controls = controls.child(add);
            }
        }

        let expand_shortcut_applies = expanded
            || self
                .panel_layout(cx)
                .is_some_and(|layout| layout.focused == id);
        controls = controls.child(
            self.render_workspace_button(
                format!("panel-expand-{id}"),
                if expanded {
                    icons::COLLAPSE_ARROWS
                } else {
                    icons::EXPAND_ARROWS
                },
                if expanded {
                    "Restore panels"
                } else {
                    "Expand panel"
                },
                expanded,
                move |this, _, cx| {
                    let layout = this.panel_layout_mut(cx);
                    layout.expanded = if layout.expanded == Some(id) {
                        None
                    } else {
                        Some(id)
                    };
                    cx.notify();
                },
                cx,
            )
            .tooltip(move |window, cx| {
                let shortcut = expand_shortcut_applies
                    .then(|| {
                        window
                            .highest_precedence_binding_for_action(&ToggleChatPaneZoom)
                            .map(|binding| {
                                binding
                                    .keystrokes()
                                    .iter()
                                    .map(|key| settings::badge_combo(&key.unparse()))
                                    .collect::<Vec<_>>()
                                    .join(" ")
                            })
                    })
                    .flatten()
                    .unwrap_or_default();
                popover::shortcut_tooltip(
                    if expanded {
                        "Restore panels"
                    } else {
                        "Expand panel"
                    },
                    shortcut,
                    cx,
                )
            })
            .tooltip_show_delay(std::time::Duration::from_millis(350))
            .aria_toggled(if expanded {
                gpui::Toggled::True
            } else {
                gpui::Toggled::False
            })
            .opacity(if expanded { 1.0 } else { controls_t })
            .when(!expanded && controls_t == 0.0, |s| s.invisible())
            .when(expanded, |s| s.occlude())
            .on_hover(cx.listener(move |this, hovered: &bool, window, cx| {
                let workspace = this.workspace_layout_key(cx);
                this.workspace_panels
                    .headers
                    .entry((workspace, id))
                    .or_default()
                    .expand_hovered = *hovered;
                window.redraw_root();
            })),
        );
        if can_close {
            controls = controls.child(
                self.render_workspace_button(
                    format!("panel-close-{id}"),
                    icons::CLOSE,
                    "Close panel",
                    false,
                    move |this, window, cx| this.close_workspace_panel(id, window, cx),
                    cx,
                )
                .tooltip(|_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: "Close panel".into(),
                    })
                    .into()
                })
                .opacity(controls_t)
                .when(controls_t == 0.0, |s| s.invisible()),
            );
        }
        // A hidden request still has a route into view. Cycle through affected
        // tabs in their existing order; neither their order nor selection changes
        // merely because a request arrives.
        let attention_jump = attention_hidden.then(|| {
            let next = attention_tabs
                .iter()
                .find(|(index, _)| *index > panel.active)
                .or_else(|| attention_tabs.first())
                .copied()
                .unwrap();
            let target = panel.tabs[next.0].clone();
            let key_target = target.clone();
            let attention = next.1;
            let label = if attention_tabs.len() == 1 {
                "1 tab needs attention. Show next tab".to_string()
            } else {
                format!("{} tabs need attention. Show next tab", attention_tabs.len())
            };
            let key = format!("panel-attention-{id}");
            let focus = self
                .workspace_panels
                .controls
                .entry(key.clone())
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            div()
                .id(SharedString::from(key.clone()))
                .debug_selector(move || format!("panel-attention-{id}"))
                .absolute()
                .top(px(controls_top + 3.0))
                .right(px(trailing_inset))
                .h(px(26.0))
                .min_w(px(36.0))
                .px(px(6.0))
                .rounded(px(6.0))
                .bg(theme.surface_overlay)
                .border_1()
                .border_color(theme.border)
                .flex()
                .items_center()
                .justify_center()
                .gap(px(4.0))
                .cursor_pointer()
                .occlude()
                .role(gpui::Role::Button)
                .aria_label(label.clone())
                .track_focus(&focus)
                .hover(|el| el.bg(theme.element_hover))
                .focus_visible(|el| el.border_color(theme.accent))
                .on_mouse_down(MouseButton::Left, |_, window, cx| {
                    window.prevent_default();
                    cx.stop_propagation();
                })
                .on_click(cx.listener(move |this, _, window, cx| {
                    this.focus_workspace_tab(id, target.clone(), window, cx);
                    cx.stop_propagation();
                }))
                .on_key_down(
                    cx.listener(move |this, event: &gpui::KeyDownEvent, window, cx| {
                        if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                            this.focus_workspace_tab(id, key_target.clone(), window, cx);
                            cx.stop_propagation();
                        }
                    }),
                )
                .tooltip(move |_, cx| {
                    cx.new(|_| SurfaceTabTooltip {
                        text: label.clone().into(),
                    })
                    .into()
                })
                .child(
                    icon(attention.glyph())
                        .size(px(13.0))
                        .text_color(attention.color(&theme)),
                )
                .child(
                    div()
                        .text_size(crate::typography::ui_rems(11.0))
                        .text_color(theme.text_muted)
                        .child(attention_tabs.len().to_string()),
                )
        });
        let tab_bounds = self.workspace_panels.header_tab_bounds.clone();
        let tab_bounds_key = (workspace.clone(), id);
        div()
            .id(("workspace-panel-header", id))
            .debug_selector(move || format!("workspace-panel-header-{id}"))
            .track_focus(&header_focus)
            // Only the header brings up its controls, not the panel's content.
            // This is chrome the shell draws, so it redraws the shell alone:
            // crossing panels must not rebuild their contents.
            .on_hover(cx.listener(move |this, hovered: &bool, window, cx| {
                let workspace = this.workspace_layout_key(cx);
                this.workspace_panels
                    .headers
                    .entry((workspace, id))
                    .or_default()
                    .hovered = *hovered;
                window.redraw_root();
            }))
            .relative()
            .h(px(height))
            .pl(px(leading_inset))
            .flex_none()
            .min_w_0()
            .flex()
            .items_start()
            .pr(px(trailing_inset))
            .child(
                div().debug_selector(move || format!("workspace-panel-tab-strip-{id}"))
                    .relative().flex_1().min_w_0().h(px(strip_height)).flex().child(
                    crate::edge_fade::edge_faded(24.0, false, false, strip)
                        .fade_left(true)
                        .fade_right(true)
                        .fade_overflow_x(&scroll)
                        .inset_right(controls_inset),
                ).child(gpui::canvas(move |bounds, _, _| {
                    tab_bounds.borrow_mut().insert(tab_bounds_key.clone(), bounds);
                }, |_, _, _, _| {}).absolute().inset_0()),
            )
            .child(crate::frost::frosted(8.0, 12.0 * controls_t, controls))
            .children(attention_jump)
            .into_any_element()
    }

    fn render_workspace_content(
        &mut self,
        panel: &WorkspacePanel,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let selected_chat = self.state.read(cx).selected_chat.clone();
        let tab = panel.selected().cloned();
        // Sync absence is not a new-chat canvas: retain the slot and make its
        // unavailable state explicit until the conversation arrives or is closed.
        if let Some(PanelTab::Chat(id)) = &tab
            && !self.state.read(cx).chats.iter().any(|chat| &chat.id == id)
        {
            let theme = Theme::of(cx);
            return div().size_full().flex().flex_col().items_center().justify_center()
                .gap(px(8.0)).text_color(theme.text_muted)
                .child("Conversation unavailable")
                .child("This tab is preserved. Reconnect to load the conversation, or close it to return it to history.")
                .into_any_element();
        }
        match tab {
            Some(PanelTab::Chat(id)) if selected_chat.as_ref() == Some(&id) => {
                self.render_workspace_chat(width, height, window, cx)
            }
            Some(tab @ PanelTab::Draft(_))
                if selected_chat.is_none()
                    && self.panel_layout(cx).is_some_and(|layout| {
                        layout.focused == panel.id
                            && layout.panel(panel.id).and_then(|panel| panel.selected())
                                == Some(&tab)
                    }) =>
            {
                self.render_main(window, width, width, Some(height), cx)
            }
            Some(PanelTab::Chat(id)) => {
                if !self.workspace_panels.peers.contains_key(&id) {
                    let transcript =
                        cx.new(|cx| Transcript::for_peer_chat(self.state.clone(), id.clone(), cx));
                    let links = Self::session_links(Some(id.clone()), cx);
                    let views = Self::view_opener(cx);
                    let labels = Self::model_labeler(&self.composer, cx);
                    transcript.update(cx, |t, _| {
                        t.set_workspace_link_handler(links);
                        t.set_view_opener(views);
                        t.set_model_labeler(labels);
                    });
                    let subscription = cx.subscribe(&transcript, Self::on_transcript_event);
                    self.state
                        .update(cx, |s, cx| s.watch_peer_chat(id.clone(), cx));
                    self.workspace_panels
                        .peers
                        .insert(id.clone(), (transcript, subscription));
                }
                let transcript = self.workspace_panels.peers[&id].0.clone();
                let panel_id = panel.id;
                let activate = id.clone();
                let toolbar = self.render_project_actions_toolbar(Some(id.clone()), cx);
                let composer = self.render_inactive_workspace_composer(
                    panel.id,
                    PanelTab::Chat(id.clone()),
                    width,
                    cx,
                );
                div()
                    .id(("workspace-chat", panel.id))
                    .size_full()
                    .flex()
                    .flex_col()
                    .children(toolbar)
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, _, window, cx| {
                            this.focus_workspace_tab(
                                panel_id,
                                PanelTab::Chat(activate.clone()),
                                window,
                                cx,
                            )
                        }),
                    )
                    .child(
                        div().flex_1().min_h_0().child(
                            transcript.cached(gpui::StyleRefinement::default().size_full()),
                        ),
                    )
                    .child(composer)
                    .into_any_element()
            }
            Some(tab @ PanelTab::Draft(_)) => {
                let panel_id = panel.id;
                let composer =
                    self.render_inactive_workspace_composer(panel_id, tab.clone(), width, cx);
                div()
                    .id(("workspace-draft", panel_id))
                    .size_full()
                    .flex()
                    .flex_col()
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, _, window, cx| {
                            this.focus_workspace_tab(panel_id, tab.clone(), window, cx)
                        }),
                    )
                    .child(div().flex_1().min_h_0())
                    .child(composer)
                    .into_any_element()
            }
            Some(PanelTab::Surface { owner, surface }) => {
                self.render_workspace_surface(&owner, surface, cx)
            }
            Some(PanelTab::FileTree(id)) => self
                .workspace_panels
                .explorers
                .get(&id)
                .map(|(files, _, _)| {
                    files.update(cx, |f, cx| {
                        f.ensure_loaded(cx);
                        f.ensure_git_status(cx);
                    });
                    files.clone().into_any_element()
                })
                .unwrap_or_else(|| Empty.into_any_element()),
            Some(PanelTab::Files(owner)) => {
                if let Some(files) = self.files.get(&owner).cloned() {
                    files.update(cx, |f, cx| {
                        f.ensure_loaded(cx);
                        f.ensure_git_status(cx);
                    });
                    files.into_any_element()
                } else {
                    self.render_workspace_empty(panel.id, cx)
                }
            }
            Some(PanelTab::Terminal(id)) => self
                .workspace_panels
                .terminals
                .get(&id)
                .map(|t| t.clone().into_any_element())
                .unwrap_or_else(|| Empty.into_any_element()),
            Some(PanelTab::TerminalDock(owner)) => self
                .terminal
                .as_ref()
                .map(|t| {
                    t.update(cx, |t, _| t.pin_session(owner));
                    t.clone().into_any_element()
                })
                .unwrap_or_else(|| Empty.into_any_element()),
            _ => self.render_workspace_empty(panel.id, cx),
        }
    }

    fn render_inactive_workspace_composer(
        &mut self,
        panel: u64,
        tab: PanelTab,
        width: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = Theme::of(cx).clone();
        let composer_width = composer_target_width(width, self.settings.transcript_width, true);
        let is_draft = matches!(tab, PanelTab::Draft(_));
        let draft = match &tab {
            PanelTab::Draft(id) => self
                .workspace_panels
                .drafts
                .get(id)
                .cloned()
                .unwrap_or_default(),
            PanelTab::Chat(id) => {
                let chat = self.state.read(cx).chats.iter().find(|chat| &chat.id == id);
                crate::pickers::CanvasDraft {
                    input: Some(self.composer.read(cx).parked_chat_input(id, cx)),
                    harness: chat
                        .and_then(|chat| chat.config.as_ref().map(|config| config.harness)),
                    model: chat.and_then(|chat| {
                        chat.config.as_ref().and_then(|config| config.model.clone())
                    }),
                    reasoning: chat
                        .and_then(|chat| chat.config.as_ref().and_then(|config| config.reasoning)),
                    git: None,
                    target: chat.map(|chat| crate::pickers::CanvasTarget {
                        device: Some(chat.device_id.clone()),
                        ..Default::default()
                    }),
                }
            }
            _ => unreachable!("only conversation tabs have composers"),
        };
        let model = draft
            .harness
            .zip(draft.model.as_deref())
            .map(|(harness, model)| {
                self.composer
                    .read(cx)
                    .pickers()
                    .read(cx)
                    .model_label_for(harness, model)
            })
            .unwrap_or_else(|| "Choose model".into());
        let state = self.state.read(cx);
        let has_project = draft
            .target
            .as_ref()
            .and_then(|target| target.space.as_ref())
            .is_some();
        let device = if is_draft && !has_project {
            draft
                .target
                .as_ref()
                .and_then(|target| target.device.as_deref())
                .or(state.local_device_id.as_deref())
                .map(|id| crate::codegraff_sandboxes::friendly_device_name(state, id))
                .unwrap_or_else(|| {
                    if cfg!(target_os = "macos") {
                        "This Mac"
                    } else {
                        "This device"
                    }
                    .into()
                })
        } else {
            String::new()
        };
        let running = match &tab {
            PanelTab::Chat(id) => {
                state
                    .chats
                    .iter()
                    .find(|chat| &chat.id == id)
                    .is_some_and(|chat| {
                        state.display_status_for(chat, Utc::now())
                            == harness_proto::ChatIndicator::Working
                    })
            }
            _ => false,
        };
        let snapshot = crate::composer::InactiveComposerSnapshot {
            input: draft.input.unwrap_or_default(),
            harness: draft.harness,
            model,
            reasoning: draft
                .reasoning
                .map(crate::pickers::reasoning_label)
                .unwrap_or_default()
                .into(),
            device,
            dictation: self.composer.read(cx).inactive_dictation_visible(),
            running,
            layout: self.workspace_panels.composer_layouts.get(&tab).copied(),
        };
        let preview = self
            .workspace_panels
            .inactive_composers
            .entry(tab.clone())
            .or_insert_with(|| cx.new(crate::composer::InactiveComposer::new))
            .clone();
        preview.update(cx, |preview, cx| {
            preview.update_snapshot(snapshot, composer_width, cx)
        });
        let focus = self
            .workspace_panels
            .controls
            .entry(format!("inactive-composer-{panel}"))
            .or_insert_with(|| cx.focus_handle().tab_stop(true))
            .clone();
        let activate = tab.clone();
        let keyboard = tab.clone();
        let suggestions = is_draft.then(|| {
            div()
                .w(px(composer_width))
                .mx_auto()
                .px(px(Theme::SPACE_LG))
                .flex()
                .flex_wrap()
                .justify_center()
                .gap(px(6.0))
                .children(crate::starters::available(has_project).map(|starter| {
                    let tab = tab.clone();
                    crate::starters::chip(starter, &theme)
                        .on_mouse_down(MouseButton::Left, |_, window, cx| {
                            window.prevent_default();
                            cx.stop_propagation();
                        })
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.focus_workspace_tab(panel, tab.clone(), window, cx);
                            this.composer
                                .update(cx, |composer, cx| composer.apply_starter(starter, cx));
                        }))
                }))
        });
        div()
            .flex_none()
            .w_full()
            .flex()
            .flex_col()
            .children(suggestions)
            .child(div().h(px(Theme::STATUS_STRIP_HEIGHT)).flex_none())
            .child(
                div()
                    .relative()
                    .w(px(composer_width))
                    .mx_auto()
                    // Every keystroke redraws the shell. This panel's composer
                    // shows none of it, and costs a text layout per panel.
                    .child(
                        preview.cached_measured(
                            gpui::StyleRefinement::default().w(px(composer_width)),
                        ),
                    )
                    .child(
                        div()
                            .id(("inactive-composer-activate", panel))
                            .debug_selector(move || format!("inactive-composer-activate-{panel}"))
                            .absolute()
                            .inset_0()
                            .occlude()
                            .track_focus(&focus)
                            .role(gpui::Role::Button)
                            .aria_label("Activate this conversation composer")
                            .cursor_text()
                            .on_mouse_down(MouseButton::Left, |_, window, cx| {
                                window.prevent_default();
                                cx.stop_propagation();
                            })
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.focus_workspace_tab(panel, activate.clone(), window, cx);
                                cx.stop_propagation();
                            }))
                            .on_key_down(cx.listener(
                                move |this, event: &gpui::KeyDownEvent, window, cx| {
                                    if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                        this.focus_workspace_tab(
                                            panel,
                                            keyboard.clone(),
                                            window,
                                            cx,
                                        );
                                        cx.stop_propagation();
                                    }
                                },
                            )),
                    ),
            )
            .into_any_element()
    }

    fn render_workspace_chat(
        &mut self,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let actions = self.render_project_actions_toolbar(None, cx);
        let main_height = height
            - if actions.is_some() {
                ACTION_BAR_HEIGHT
            } else {
                0.0
            };
        let main = self.render_main(window, width, width, Some(main_height), cx);
        div()
            .size_full()
            .flex()
            .flex_col()
            .children(actions)
            .child(div().flex_1().min_h_0().flex().child(main))
            .into_any_element()
    }

    fn render_workspace_surface(
        &mut self,
        owner: &str,
        surface: RightSurface,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match surface {
            RightSurface::File(id) => self
                .file_surfaces
                .get(&id)
                .cloned()
                .map(|f| {
                    f.update(cx, |f, cx| f.ensure_loaded(cx));
                    f.into_any_element()
                })
                .unwrap_or_else(|| Empty.into_any_element()),
            RightSurface::Browser(id) => self
                .browsers
                .get(&id)
                .map(|b| b.clone().into_any_element())
                .unwrap_or_else(|| Empty.into_any_element()),
            RightSurface::Diff(id) => self
                .diffs
                .get(&id)
                .cloned()
                .map(|d| {
                    let controls = d.update(cx, |d, cx| {
                        d.ensure_content(cx);
                        d.render_header_controls(cx)
                    });
                    div()
                        .size_full()
                        .flex()
                        .flex_col()
                        .child(Changes::workspace_toolbar(Theme::of(cx)).child(controls))
                        .child(div().flex_1().min_h_0().child(d))
                        .into_any_element()
                })
                .unwrap_or_else(|| Empty.into_any_element()),
            RightSurface::Terminal(key) => {
                let panel = self.right_terminal_panel(cx);
                panel.update(cx, |p, cx| {
                    p.pin_session(owner.into());
                    p.select_tab_by_key(key, cx);
                });
                panel.into_any_element()
            }
            RightSurface::Subagent(id) => self
                .subagent_tabs
                .get(&id)
                .map(|t| t.transcript.clone().into_any_element())
                .unwrap_or_else(|| Empty.into_any_element()),
            RightSurface::Picker => {
                let id = self.panel_layout_mut(cx).focused;
                self.render_workspace_empty(id, cx)
            }
        }
    }

    fn activate_workspace_empty(
        &mut self,
        panel: u64,
        action: u8,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let device = self.workspace_panel_device(panel, cx);
        if matches!(action, 0 | 2 | 3) && !device.available(self.state.read(cx)) {
            return;
        }
        if matches!(action, 5 | 6) && !self.panel_device_matches_current_project(&device, cx) {
            return;
        }
        self.workspace_panels.device_menu = None;
        if let Some(tab) = self
            .panel_layout(cx)
            .and_then(|layout| layout.panel(panel))
            .and_then(|panel| panel.selected())
            .cloned()
        {
            self.focus_workspace_tab(panel, tab, window, cx);
        }
        self.workspace_panels.target = Some(panel);
        match action {
            0 => self.workspace_new_chat_for_device(Some(device), cx),
            1 => self.add_browser_surface(None, window, cx),
            2 => self.open_workspace_terminal_for_device(Some(device), cx),
            3 => {
                // Route the folder choice to this Files tab. The existing
                // name/folder flow creates a project only after confirmation.
                self.open_workspace_files_for_device(Some(device), window, cx);
                let files = self.workspace_panels.explorers.get(&self.workspace_panels.seq)
                    .map(|(files, _, _)| files.clone());
                if let Some(files) = files {
                    self.open_files_project(&files, cx);
                }
            },
            4 => self.open_conversation_palette_in_panel(panel, window, cx),
            5 => self.add_diff_surface(cx),
            6 => self.add_history_surface(cx),
            7 => self.open_codex_import(panel, window, cx),
            _ => return,
        };
        self.sync_panel_workspace(cx);
        self.workspace_panels.target = None;
        cx.notify();
    }

    fn render_workspace_empty(&mut self, panel: u64, cx: &mut Context<Self>) -> AnyElement {
        let theme = Theme::of(cx).clone();
        let device = self.workspace_panel_device(panel, cx);
        let device_available = device.available(self.state.read(cx));
        let device_picker = self.render_panel_device_picker(panel, cx);
        let mut buttons = div()
            .max_w(px(280.0))
            .w_full()
            .my_auto()
            .flex_none()
            .flex()
            .flex_col()
            .gap(px(4.0))
            .child(device_picker);
        let mut choices = vec![
            ("Chat", None, icons::CHAT_ROUND_LINE, 0),
            (
                "Browser",
                device.remote.is_some().then_some("On this Mac"),
                icons::GLOBE,
                1,
            ),
            ("Terminal", None, icons::TERMINAL, 2),
        ];
        if self.space_git_detected(cx) && self.panel_device_matches_current_project(&device, cx) {
            choices.extend([
                ("Changes", None, icons::GIT_BRANCH, 5),
                ("History", None, icons::CLOCK_CIRCLE, 6),
            ]);
        }
        let main_count = choices.len();
        choices.extend([
            (
                "Open a folder",
                Some("Bring an existing project"),
                icons::FOLDER,
                3,
            ),
            (
                "Import a conversation",
                Some("Continue a Codex chat in graff"),
                icons::ARROW_DOWN,
                7,
            ),
            ("Resume a conversation…", None, icons::CLOCK_CIRCLE, 4),
        ]);
        for (index, (title, subtitle, glyph, action)) in choices.into_iter().enumerate() {
            if index == main_count {
                buttons = buttons.child(div().h(px(1.0)).mx(px(12.0)).my(px(7.0)).bg(theme.border));
            }
            let enabled = device_available || !matches!(action, 0 | 2 | 3);
            let focus = self
                .workspace_panels
                .controls
                .entry(format!("panel-empty-{panel}-{action}"))
                .or_insert_with(|| cx.focus_handle().tab_stop(true))
                .clone();
            buttons = buttons.child(
                div()
                    .id(SharedString::from(format!("panel-empty-{panel}-{action}")))
                    .debug_selector(move || format!("panel-empty-{panel}-{action}"))
                    .py(px(8.0))
                    .flex_none()
                    .px(px(12.0))
                    .flex()
                    .items_start()
                    .gap(px(10.0))
                    .rounded(px(6.0))
                    .when(enabled, |row| {
                        row.cursor_pointer()
                            .hover(|s| s.bg(theme.element_hover))
                            .focus_visible(|s| s.bg(theme.element_hover))
                    })
                    .when(!enabled, |row| row.opacity(0.45))
                    .role(gpui::Role::Button)
                    .aria_label(
                        subtitle.map_or_else(
                            || title.to_string(),
                            |detail| format!("{title}. {detail}"),
                        ),
                    )
                    .track_focus(&focus)
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.activate_workspace_empty(panel, action, window, cx);
                    }))
                    .on_key_down(cx.listener(
                        move |this, event: &gpui::KeyDownEvent, window, cx| {
                            if matches!(event.keystroke.key.as_str(), "enter" | "space") {
                                this.activate_workspace_empty(panel, action, window, cx);
                                cx.stop_propagation();
                            }
                        },
                    ))
                    .child(
                        div()
                            .debug_selector(move || format!("panel-empty-{panel}-{action}-icon"))
                            .w(px(16.0))
                            .h(px(20.0))
                            .flex_none()
                            .flex()
                            .items_center()
                            .child(icon(glyph).size(px(16.0)).text_color(theme.text_muted)),
                    )
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .flex()
                            .flex_col()
                            .gap(px(1.0))
                            .child(
                                div()
                                    .debug_selector(move || {
                                        if action == 0 {
                                            format!("panel-start-chat-{panel}")
                                        } else {
                                            format!("panel-empty-{panel}-{action}-title")
                                        }
                                    })
                                    .text_size(crate::typography::ui_rems(13.0))
                                    .line_height(px(20.0))
                                    .text_color(theme.text)
                                    .child(title),
                            )
                            .when_some(subtitle, |column, detail| {
                                column.child(
                                    div()
                                        .debug_selector(move || {
                                            format!("panel-empty-{panel}-{action}-subtitle")
                                        })
                                        .text_size(crate::typography::ui_rems(12.0))
                                        .line_height(px(16.0))
                                        .text_color(theme.text_muted)
                                        .child(detail),
                                )
                            }),
                    ),
            );
        }
        div()
            .id(("panel-new-tab-choices", panel))
            .debug_selector(move || format!("panel-new-tab-choices-{panel}"))
            .size_full()
            .flex()
            .flex_col()
            .items_center()
            .overflow_y_scroll()
            .p(px(16.0))
            .child(buttons)
            .into_any_element()
    }
    pub(super) fn render_panel_workspace(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.viewport_width = f32::from(window.viewport_size().width);
        self.viewport_height = f32::from(window.viewport_size().height);
        self.restore_pending_workspace_tools(window, cx);
        self.sync_panel_workspace(cx);
        self.park_workspace_draft(cx);
        if !cx.has_active_drag() {
            self.split_drop_session = None;
            self.clear_window_tab_drag(cx);
            self.workspace_panels.blocked_split = false;
            self.workspace_panels.dragging_tab.set(false);
            self.workspace_panels.split_drag_bounds.clear();
            self.update_panel_split_preview(None, cx);
        }
        let now = std::time::Instant::now();
        self.workspace_panels
            .split_previews
            .retain(|_, preview| preview.active || preview.animating(now, self.reduced_motion));
        if self
            .workspace_panels
            .split_previews
            .values()
            .any(|preview| preview.animating(now, self.reduced_motion))
        {
            window.request_animation_frame();
        }
        let workspace_key = self.workspace_layout_key(cx);
        let insertion_t = self
            .workspace_panels
            .layout_transition
            .as_ref()
            .filter(|transition| transition.workspace == workspace_key && !self.reduced_motion)
            .map_or(1.0, |transition| {
                let duration = PANEL_SPLIT_MOTION
                    .total()
                    .mul_f32(motion::speed_scale())
                    .as_secs_f32();
                let raw = now
                    .saturating_duration_since(transition.started)
                    .as_secs_f32()
                    / duration;
                PANEL_SPLIT_MOTION.progress(raw)
            });
        if insertion_t < 1.0 {
            window.request_animation_frame();
        } else {
            self.workspace_panels.layout_transition = None;
        }
        let theme = Theme::of(cx).clone();
        let layout = self.panel_layout(cx).cloned().unwrap_or_default();
        let sidebar = self.render_sidebar(cx);
        let sidebar_now = self.sidebar_now();
        let leading =
            GUTTER * (1.0 - (sidebar_now / self.settings.sidebar_width.max(1.0)).clamp(0.0, 1.0));
        let mut visible: Vec<_> = layout
            .panels
            .iter()
            .filter(|p| layout.expanded.is_none_or(|id| id == p.id))
            .cloned()
            .collect();
        let width = (self.viewport_width - sidebar_now - leading - GUTTER).max(1.0);
        let header_panels = layout.header_panel_count();
        let preview_mode = (header_panels == 1)
            .then(|| {
                self.workspace_panels.split_drag.as_ref().and_then(|drag| {
                    self.workspace_panels
                        .split_previews
                        .iter()
                        .filter(|((key, _, _), _)| key == &workspace_key)
                        .filter_map(|((_, beside, edge), preview)| {
                            let mut proposed = layout.clone();
                            proposed
                                .split_tab(drag.panel, &drag.tab, *beside, *edge)
                                .map(|_| preview.value(now, self.reduced_motion))
                        })
                        .reduce(f32::max)
                })
            })
            .flatten();
        let (header_mode, header_animating) = self
            .workspace_panels
            .header_modes
            .entry(workspace_key.clone())
            .or_insert_with(|| PanelHeaderMode::new(header_panels))
            .update(header_panels, preview_mode, now, self.reduced_motion);
        if header_animating {
            window.request_animation_frame();
        }
        let full_titlebar_lane = self.workspace_native_titlebar_lane(2);
        let native_titlebar_lane = if INSTRUMENT_STRIP {
            if layout.uses_strip() {
                full_titlebar_lane
            } else {
                0.0
            }
        } else {
            full_titlebar_lane * PanelHeaderMode::lane_fraction(header_mode)
        };
        let header_clearance = PanelHeaderMode::clearance_fraction(header_mode);
        let height = (self.viewport_height - GUTTER - native_titlebar_lane).max(1.0);
        let originals = layout.frames(width, height);
        let mut frames = originals.clone();
        if let Some(transition) = &self.workspace_panels.layout_transition {
            for (id, frame) in &mut frames {
                let initial = transition
                    .frames
                    .get(id)
                    .copied()
                    .unwrap_or_else(|| frame.collapsed(PanelEdge::along(layout.axis, true)));
                *frame = initial.lerp(*frame, insertion_t);
            }
        }
        let mut ghosts = vec![];
        self.workspace_panels.rendered_ghosts.clear();
        if let Some(drag) = &self.workspace_panels.split_drag {
            for ((key, beside, edge), preview) in &self.workspace_panels.split_previews {
                if key != &workspace_key {
                    continue;
                }
                let t = preview.value(now, self.reduced_motion);
                let mut proposed = layout.clone();
                let Some(new_panel) = proposed.split_tab(drag.panel, &drag.tab, *beside, *edge)
                else {
                    continue;
                };
                let targets = proposed.frames(width, height);
                for (id, original) in &originals {
                    let target = targets
                        .get(id)
                        .copied()
                        .unwrap_or_else(|| original.collapsed(*edge));
                    let frame = frames.get_mut(id).unwrap();
                    frame.x += (target.x - original.x) * t;
                    frame.y += (target.y - original.y) * t;
                    frame.width += (target.width - original.width) * t;
                    frame.height += (target.height - original.height) * t;
                    frame.header_height += (target.header_height - original.header_height) * t;
                }
                let target = targets[&new_panel];
                let initial = originals
                    .get(beside)
                    .copied()
                    .unwrap_or(target)
                    .collapsed(*edge);
                let ghost = initial.lerp(target, t);
                self.workspace_panels
                    .rendered_ghosts
                    .insert((key.clone(), *beside, *edge), ghost);
                ghosts.push((*beside, *edge, ghost, t));
            }
        }
        // The strip and the tab row swap outright, in the same height: nothing
        // slides between them, however the panels' own frames are moving.
        if INSTRUMENT_STRIP {
            let header = if layout.uses_strip() {
                0.0
            } else {
                PANEL_HEADER_HEIGHT
            };
            frames
                .values_mut()
                .chain(self.workspace_panels.rendered_ghosts.values_mut())
                .chain(ghosts.iter_mut().map(|(_, _, frame, _)| frame))
                .for_each(|frame| frame.header_height = header);
        }
        // Project remaining selections while their real content reflows. Stored
        // tabs, drafts, axis and proportions change only when the drop commits.
        for panel in &mut visible {
            *panel = self.projected_workspace_panel(panel, &workspace_key);
        }
        let canvas_width = frames
            .values()
            .chain(ghosts.iter().map(|(_, _, frame, _)| frame))
            .fold(width, |extent, frame| extent.max(frame.x + frame.width));
        let canvas_height = frames
            .values()
            .chain(ghosts.iter().map(|(_, _, frame, _)| frame))
            .fold(height, |extent, frame| extent.max(frame.y + frame.height));
        let workspace_scroll = self
            .workspace_panels
            .layout_scrolls
            .entry(workspace_key.clone())
            .or_default()
            .clone();
        let reveal = (
            layout.focused,
            layout.axis,
            width.to_bits(),
            height.to_bits(),
        );
        if !cx.has_active_drag()
            && insertion_t >= 1.0
            && self.workspace_panels.revealed_panels.get(&workspace_key) != Some(&reveal)
        {
            if let Some(frame) = originals.get(&layout.focused) {
                let mut offset = workspace_scroll.offset();
                let reveal_offset =
                    |offset: f32, start: f32, span: f32, viewport: f32, total: f32| {
                        let next = if start < -offset {
                            -start
                        } else if start + span > viewport - offset {
                            viewport - start - span
                        } else {
                            offset
                        };
                        next.clamp(-(total - viewport).max(0.0), 0.0)
                    };
                offset.x = px(reveal_offset(
                    f32::from(offset.x),
                    frame.x,
                    frame.width,
                    width,
                    canvas_width,
                ));
                offset.y = px(reveal_offset(
                    f32::from(offset.y),
                    frame.y,
                    frame.height,
                    height,
                    canvas_height,
                ));
                workspace_scroll.set_offset(offset);
            }
            self.workspace_panels
                .revealed_panels
                .insert(workspace_key.clone(), reveal);
        }
        let mut canvas = div()
            .id("workspace-panel-canvas")
            .relative()
            .w(px(canvas_width))
            .h(px(canvas_height))
            .flex_none();
        self.workspace_panels.rendering = true;
        if self.state.read(cx).selected_chat.is_some() {
            let clearance = self.bottom_stack.get();
            self.transcript
                .update(cx, |t, cx| t.set_bottom_clearance(clearance, cx));
        }
        for panel in &visible {
            let frame = frames[&panel.id];
            if frame.width < 1.0 || frame.height < 1.0 {
                continue;
            }
            let workspace = workspace_key.clone();
            self.workspace_panels
                .rendered_frames
                .insert((workspace.clone(), panel.id), frame);
            let content_width = (frame.width - 2.0).max(1.0);
            if matches!(
                panel.selected(),
                Some(PanelTab::Chat(_) | PanelTab::Draft(_))
            ) {
                self.transcript.update(cx, |t, cx| {
                    t.set_rail_enabled(rail::rail_visible(content_width), cx)
                });
            }
            let row_top = native_titlebar_lane
                + frame.y
                + (frame.header_height - PANEL_TAB_HEIGHT - STACKED_CLEARANCE).max(0.0);
            let clearance = if row_top < Theme::TITLEBAR_HEIGHT {
                1.0
            } else {
                header_clearance
            };
            let panel_left = sidebar_now + leading + frame.x;
            let caption_left = self.viewport_width - self.titlebar_right_pad(0.0);
            let trailing_inset =
                4.0 + (panel_left + frame.width - caption_left).max(0.0) * clearance;
            let header = if layout.uses_strip() {
                div().into_any_element()
            } else {
                self.render_workspace_header(
                    panel,
                    layout.expanded == Some(panel.id),
                    frame.width,
                    frame.header_height,
                    self.workspace_header_controls_inset(panel_left, cx) * clearance,
                    trailing_inset,
                    window,
                    cx,
                )
            };
            let content_height = (frame.height - frame.header_height - 2.0).max(0.0);
            let content =
                self.render_workspace_content(panel, content_width, content_height, window, cx);
            let panel_id = panel.id;
            let active_drop = cx.has_active_drag() && self.workspace_panels.dragging_tab.get();
            let selected_tab = panel.selected().cloned();
            let takes_files = sidebar_chat_drop::panel_body_takes_files(
                selected_tab.as_ref(),
                self.state.read(cx).selected_chat.as_deref(),
                layout.focused == panel.id,
            );
            let chat_drop_zones = self
                .split_drop_session
                .is_some()
                .then(|| self.render_panel_chat_drop_zones(panel_id, &theme, cx));
            let body = div()
                .id(("workspace-panel-content", panel_id))
                .flex_1()
                .min_h_0()
                .m(px(1.0))
                .relative()
                .flex()
                .flex_col()
                .rounded(px(9.0))
                .bg(theme.bg)
                .overflow_hidden()
                .on_drop::<PanelTabDrag>(cx.listener(
                    move |this, drag: &PanelTabDrag, window, cx| {
                        if drag.workspace == this.workspace_layout_key(cx) {
                            this.drop_workspace_tab(drag, panel_id, None, window, cx);
                        }
                        cx.stop_propagation();
                    },
                ))
                .drag_over::<PanelTabDrag>(move |s, _, _, _| s.border_color(theme.accent))
                .when(takes_files, |body| {
                    let path_tab = selected_tab.clone();
                    body.on_drop(cx.listener(
                        move |this, paths: &gpui::ExternalPaths, window, cx| {
                            this.drop_paths_on_panel(
                                panel_id,
                                selected_tab.clone(),
                                paths.paths().to_vec(),
                                window,
                                cx,
                            );
                        },
                    ))
                    .on_drop(cx.listener(
                        move |this, path: &crate::files::WorkspacePathDrag, window, cx| {
                            this.drop_workspace_path_on_panel(
                                panel_id,
                                path_tab.clone(),
                                path,
                                window,
                                cx,
                            );
                        },
                    ))
                })
                .child(content)
                .when(takes_files, |body| {
                    body.child(
                        chat_split::attachment_drop_veil(("panel-file-drop", panel_id), &theme)
                            .drag_over::<crate::files::WorkspacePathDrag>(|style, _, _, _| {
                                style.opacity(1.0)
                            }),
                    )
                })
                .when(active_drop, |body| {
                    body.child(
                        div()
                            .id(("panel-tab-drop", panel_id))
                            .absolute()
                            .inset_0()
                            .occlude()
                            .drag_over::<PanelTabDrag>(move |s, _, _, _| {
                                s.bg(theme.accent.opacity(0.08))
                            })
                            .on_drop::<PanelTabDrag>(cx.listener(
                                move |this, drag: &PanelTabDrag, window, cx| {
                                    if drag.workspace == this.workspace_layout_key(cx) {
                                        this.drop_workspace_tab(drag, panel_id, None, window, cx);
                                    }
                                    cx.stop_propagation();
                                },
                            )),
                    )
                });
            let bounds = self.workspace_panels.panel_bounds.clone();
            let column = div()
                .id(("workspace-panel", panel_id))
                .debug_selector(move || format!("workspace-panel-{panel_id}"))
                .group(format!("workspace-panel-{panel_id}"))
                .absolute()
                .left(px(frame.x))
                .top(px(frame.y))
                .w(px(frame.width.max(0.0)))
                .h(px(frame.height.max(0.0)))
                .min_w_0()
                .min_h_0()
                .flex()
                .flex_col()
                .child(
                    div()
                        .id(("workspace-panel-body", panel_id))
                        .debug_selector(move || format!("workspace-panel-body-{panel_id}"))
                        .absolute()
                        .left_0()
                        .right_0()
                        .bottom_0()
                        .top(px(frame.header_height)),
                )
                .child(header)
                .child(body)
                .children(self.window_drop_cue(
                    &workspace,
                    panel_id,
                    frame.width,
                    frame.header_height,
                    &theme,
                ))
                .children(chat_drop_zones)
                .when(
                    layout.uses_strip() && visible.len() > 1 && layout.focused == panel_id,
                    |column| {
                        column.child(
                            div()
                                .debug_selector(move || format!("instrument-focus-{panel_id}"))
                                .absolute()
                                .inset_0()
                                .rounded(px(10.0))
                                .border(px(1.5))
                                .border_color(theme.accent.opacity(0.7)),
                        )
                    },
                )
                .child(
                    gpui::canvas(
                        move |rect, _, _| {
                            bounds
                                .borrow_mut()
                                .insert((workspace.clone(), panel_id), rect);
                        },
                        |_, _, _, _| {},
                    )
                    .absolute()
                    .inset_0(),
                );
            canvas = canvas.child(column);
        }
        // Resize handles occupy the gutters, outside the clipped panel bodies.
        // They follow the stored axis; an active tab drag uses the same gutter
        // as a split target instead of starting a resize.
        if layout.expanded.is_none() {
            for pair in visible.windows(2) {
                let before = pair[0].clone();
                let after = pair[1].clone();
                let frame = frames[&after.id];
                let panel_id = after.id;
                let workspace = workspace_key.clone();
                let horizontal = layout.axis == SplitAxis::Horizontal;
                let axis = layout.axis;
                let extent = if horizontal { width } else { height }
                    - layout.gap() * visible.len().saturating_sub(1) as f32;
                canvas = canvas.child(
                    div()
                        .id(("workspace-divider", panel_id))
                        .debug_selector(move || format!("workspace-divider-{panel_id}"))
                        .absolute()
                        .when(horizontal, |s| {
                            s.left(px(frame.x - 6.0))
                                .top(px(frame.y + frame.header_height))
                                .w(px(6.0))
                                .h(px((frame.height - frame.header_height).max(0.0)))
                                .cursor_col_resize()
                        })
                        .when(!horizontal, |s| {
                            s.left(px(frame.x))
                                .top(px(frame.y - STACKED_CLEARANCE / 2.0 - 3.0))
                                .w(px(frame.width))
                                .h(px(6.0))
                                .cursor_row_resize()
                        })
                        .occlude()
                        .on_drop::<PanelTabDrag>(cx.listener(move |this, drag, window, cx| {
                            this.drop_workspace_tab(drag, panel_id, None, window, cx);
                            cx.stop_propagation();
                        }))
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(move |this, event: &MouseDownEvent, _, cx| {
                                this.workspace_panels.resize = Some(PanelResize {
                                    workspace: workspace.clone(),
                                    before: before.id,
                                    after: after.id,
                                    axis,
                                    origin: f32::from(if horizontal {
                                        event.position.x
                                    } else {
                                        event.position.y
                                    }),
                                    extent: extent.max(1.0),
                                    shares: (before.share, after.share),
                                });
                                cx.notify();
                                cx.stop_propagation();
                            }),
                        )
                        .on_mouse_up(
                            MouseButton::Left,
                            cx.listener(|this, event: &MouseUpEvent, _, cx| {
                                this.workspace_panels.resize = None;
                                if event.click_count == 2 {
                                    this.panel_layout_mut(cx).equalize();
                                }
                                cx.notify();
                            }),
                        ),
                );
            }
        }
        for (panel, edge, frame, reveal) in ghosts {
            if reveal > 0.0 {
                canvas =
                    canvas.child(self.render_panel_split_ghost(panel, edge, frame, reveal, cx));
            }
        }
        let row = div()
            .id("workspace-panels")
            .debug_selector(|| "workspace-panels".into())
            .h_full()
            .flex_1()
            .min_w_0()
            .min_h_0()
            .pl(px(leading))
            .pr(px(GUTTER))
            .pb(px(GUTTER))
            .overflow_x_scroll()
            .overflow_y_scroll()
            .track_scroll(&workspace_scroll)
            .on_drop::<PanelTabDrag>(cx.listener(|this, drag, window, cx| {
                let focused = this.panel_layout_mut(cx).focused;
                this.drop_workspace_tab(drag, focused, None, window, cx);
                cx.stop_propagation();
            }))
            .child(canvas);
        self.workspace_panels.rendering = false;
        let shadow_panels: Vec<_> = visible
            .iter()
            .filter_map(|panel| {
                frames
                    .get(&panel.id)
                    .map(|frame| (panel.id, frame.header_height, panel.active == 0))
            })
            .collect();
        let shadow_bounds = self.workspace_panels.panel_bounds.clone();
        let shadow_tabs = self.workspace_panels.active_tab_bounds.clone();
        let shadow_workspace = workspace_key.clone();
        let shadow_theme = theme.clone();
        let shadows = gpui::canvas(
            |_, _, _| (),
            move |viewport, _, window, _| {
                // Only the shadow is allowed outside the scroll viewport. In
                // particular, panel fills and scrolled tab labels never bleed
                // onto the sidebar. Draw after the sidebar, before the panels.
                let mask = gpui::ContentMask {
                    bounds: gpui::Bounds::new(
                        viewport.origin + point(px(-16.0), px(native_titlebar_lane)),
                        gpui::size(
                            viewport.size.width + px(16.0),
                            (viewport.size.height - px(native_titlebar_lane)).max(px(0.0)),
                        ),
                    ),
                };
                let mut surfaces = Vec::with_capacity(shadow_panels.len());
                window.with_content_mask(Some(mask), |window| {
                    let bounds = shadow_bounds.borrow();
                    let tabs = shadow_tabs.borrow();
                    for (panel, header_height, flush_left) in &shadow_panels {
                        let key = (shadow_workspace.clone(), *panel);
                        let Some(mut body) = bounds.get(&key).copied() else {
                            continue;
                        };
                        if body.right() < viewport.left() || body.left() > viewport.right() {
                            continue;
                        }
                        body.origin.y += px(*header_height);
                        body.size.height -= px(*header_height);
                        let selected = tabs.get(&key).copied().map(|tab| {
                            super::panel_surface::TabGeometry::from_bounds(tab, *flush_left)
                        });
                        super::panel_surface::paint_surface_shadow(
                            body,
                            selected,
                            &shadow_theme,
                            window,
                        );
                        surfaces.push((body, selected));
                    }
                });
                // Painted together: each run of paths is its own full-window
                // multisampled pass, and a panel's contents cover its fill.
                // All prepaint callbacks have run, so the tabs are recorded.
                window.with_content_mask(Some(gpui::ContentMask { bounds: viewport }), |window| {
                    for (body, selected) in surfaces {
                        super::panel_surface::paint_surface(body, selected, &shadow_theme, window);
                    }
                });
            },
        )
        .absolute()
        .inset_0();
        let sidebar_handle = self.resize_handle(
            "sidebar-resize",
            PaneResizeKind::Sidebar,
            || SidebarResize,
            |shell, _| {
                shell.settings.sidebar_width = SIDEBAR_DEFAULT;
                shell.sidebar_edge_bounce = None;
            },
            cx,
        );
        let instrument_strip = layout.uses_strip().then(|| {
            let left = self.workspace_header_controls_inset(sidebar_now, cx).max(leading);
            let right = GUTTER.max(self.titlebar_right_pad(0.0));
            let in_a_row = layout.axis == SplitAxis::Horizontal
                && layout.expanded.is_none()
                && canvas_width <= width + 0.5
                && right <= GUTTER;
            let columns = in_a_row
                .then(|| {
                    let widths: Vec<_> = layout
                        .panels
                        .iter()
                        .map(|panel| frames.get(&panel.id).map_or(0.0, |frame| frame.width))
                        .collect();
                    Self::strip_columns(&widths, leading, left)
                })
                .flatten();
            self.render_instrument_strip(&layout, left, right, columns, window, cx)
        });
        let row = div()
            .flex_1()
            .min_w_0()
            .h_full()
            .relative()
            .pt(px(native_titlebar_lane))
            .flex()
            .child(shadows)
            .child(row)
            .children(instrument_strip);
        let overlays = self.render_overlays(window.viewport_size(), window, cx);
        let menu = self.render_panel_menu(cx);
        if self
            .workspace_panels
            .tab_context_fades
            .0
            .tick_at(std::time::Instant::now())
        {
            window.request_animation_frame();
        }
        if self.workspace_panels.needs_persist && self.boot_restored {
            self.workspace_panels.needs_persist = false;
            self.persist_chat_tabs(cx);
        }
        div()
            .size_full()
            .relative()
            .on_drag_move::<PanelTabDrag>(cx.listener(
                |this, event: &gpui::DragMoveEvent<PanelTabDrag>, window, cx| {
                    // AppKit can synthesize ordinary hover moves when the
                    // pointer-transparent preview changes native frames.
                    // Only the initiating left-button gesture may retarget it.
                    if event.event.pressed_button != Some(MouseButton::Left) {
                        return;
                    }
                    if this.forward_foreign_window_drag(event.event.position, false, window, cx) {
                        return;
                    }
                    if this.track_window_tab_drag(event.event.position, window, cx)
                        || !cx.has_active_drag()
                    {
                        return;
                    }
                    let drag = event.drag(cx).clone();
                    this.track_workspace_tab_drag(drag.clone(), event.event.position, cx);
                    this.update_internal_tab_drop_hover(&drag, event.event.position, window, cx);
                },
            ))
            .on_mouse_move(cx.listener(|this, e: &gpui::MouseMoveEvent, _, cx| {
                let Some(drag) = this.workspace_panels.resize.clone() else {
                    return;
                };
                if e.pressed_button != Some(MouseButton::Left) {
                    this.workspace_panels.resize = None;
                    cx.notify();
                    return;
                }
                let Some(layout) = this.workspace_panels.layouts.get_mut(&drag.workspace) else {
                    return;
                };
                this.workspace_panels.needs_persist = true;
                let sum = drag.shares.0 + drag.shares.1;
                let minimum = if drag.axis == SplitAxis::Horizontal {
                    PANEL_MIN
                } else if layout.panels.len() >= 3 {
                    THREE_PANEL_MIN_HEIGHT
                } else {
                    PANEL_MIN_HEIGHT
                };
                let min = (minimum / drag.extent).min(sum / 2.0);
                let position = if drag.axis == SplitAxis::Horizontal {
                    e.position.x
                } else {
                    e.position.y
                };
                let left = (drag.shares.0 + (f32::from(position) - drag.origin) / drag.extent)
                    .clamp(min, sum - min);
                if let Some(p) = layout.panel_mut(drag.before) {
                    p.share = left;
                }
                if let Some(p) = layout.panel_mut(drag.after) {
                    p.share = sum - left;
                }
                cx.notify();
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    if this.workspace_panels.resize.take().is_some() {
                        cx.notify();
                    }
                }),
            )
            .child(
                self.titlebar_drag_region(
                    "workspace-titlebar-drag",
                    div()
                        .absolute()
                        .top_0()
                        .left_0()
                        .right_0()
                        .h(px(PANEL_HEADER_HEIGHT)),
                    cx,
                ),
            )
            .child(
                div()
                    .size_full()
                    .flex()
                    .child(sidebar)
                    .child(
                        div()
                            .w(px(0.0))
                            .h_full()
                            .relative()
                            .child(sidebar_handle.left(px(-PANE_RESIZE_HITBOX_HALF_WIDTH))),
                    )
                    .child(row),
            )
            .child(self.render_titlebar_cluster(cx))
            .child(self.window_tab_drag_events(cx))
            .children(overlays)
            .children(menu)
            .into_any_element()
    }
}

/// Native browser fixtures follow the workspace's measured chrome and resize
/// state; legacy right-pane drag markers do not describe these panels.
#[cfg(feature = "browser-fixture")]
impl Shell {
    fn fixture_active_browser_panel(&self, cx: &App) -> Option<(u64, PanelTab)> {
        let surface = self.resolved_right_active(cx);
        if !matches!(surface, RightSurface::Browser(_)) {
            return None;
        }
        self.panel_layout(cx)?.panels.iter().find_map(|panel| {
            panel.tabs.iter().find_map(|tab| {
                matches!(tab, PanelTab::Surface { surface: candidate, .. } if *candidate == surface)
                    .then(|| (panel.id, tab.clone()))
            })
        })
    }

    pub(super) fn fixture_workspace_browser_menu(
        &mut self,
        open: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.workspace_panels.fixture_menu_bounds.set(None);
        if open {
            if let Some((panel, tab)) = self.fixture_active_browser_panel(cx) {
                let workspace = self.workspace_layout_key(cx);
                let tab_bounds = self
                    .workspace_panels
                    .active_tab_bounds
                    .borrow()
                    .get(&(workspace, panel))
                    .copied();
                if let Some(bounds) = tab_bounds {
                    self.open_panel_menu(
                        panel,
                        Some(tab),
                        point(bounds.left() + px(24.0), bounds.bottom()),
                        false,
                        window,
                        cx,
                    );
                }
            }
        } else {
            self.workspace_panels.menu = None;
            self.workspace_panels.target = None;
            cx.notify();
        }
    }

    pub fn fixture_browser_menu_bounds(&self) -> Option<gpui::Bounds<Pixels>> {
        self.workspace_panels.fixture_menu_bounds.get()
    }

    pub(super) fn fixture_workspace_expand_browser(&mut self, cx: &mut Context<Self>) {
        if let Some((panel, _)) = self.fixture_active_browser_panel(cx) {
            let layout = self.panel_layout_mut(cx);
            layout.expanded = (layout.expanded != Some(panel)).then_some(panel);
            cx.notify();
        }
    }

    pub(super) fn fixture_workspace_toggle_browser_visibility(&mut self, cx: &mut Context<Self>) {
        if let Some((panel, _)) = self.fixture_active_browser_panel(cx) {
            let layout = self.panel_layout_mut(cx);
            layout.expanded = if layout.expanded.is_some() {
                None
            } else {
                layout
                    .panels
                    .iter()
                    .find(|candidate| candidate.id != panel)
                    .map(|other| other.id)
            };
            cx.notify();
        }
    }

    pub(super) fn fixture_workspace_resize_browser(&mut self, width: f32, cx: &mut Context<Self>) {
        let Some((panel, _)) = self.fixture_active_browser_panel(cx) else {
            return;
        };
        let extent = self.viewport_width - self.sidebar_now() - GUTTER;
        let layout = self.panel_layout_mut(cx);
        if layout.axis != SplitAxis::Horizontal || layout.panels.len() < 2 || layout.expanded.is_some() {
            return;
        }
        let extent = (extent - layout.gap() * layout.panels.len().saturating_sub(1) as f32).max(1.0);
        let minimum = PANEL_MIN / extent;
        let target = (width / extent).clamp(
            minimum,
            (1.0 - minimum * (layout.panels.len() - 1) as f32).max(minimum),
        );
        let remainder: f32 = layout
            .panels
            .iter()
            .filter(|p| p.id != panel)
            .map(|p| p.share)
            .sum();
        for candidate in &mut layout.panels {
            candidate.share = if candidate.id == panel {
                target
            } else {
                candidate.share / remainder * (1.0 - target)
            };
        }
        cx.notify();
    }

    pub fn fixture_browser_panel_targets(
        &self,
        browser: u64,
        cx: &App,
    ) -> Option<(gpui::Bounds<Pixels>, gpui::Bounds<Pixels>)> {
        let workspace = self.workspace_layout_key(cx);
        let layout = self.panel_layout(cx)?;
        if layout.axis != SplitAxis::Horizontal || layout.expanded.is_some() {
            return None;
        }
        let (panel_index, panel, tab_index) =
            layout.panels.iter().enumerate().find_map(|(index, panel)| {
                panel
                    .tabs
                    .iter()
                    .position(|tab| {
                        matches!(tab,
                            PanelTab::Surface { surface: RightSurface::Browser(id), .. } if *id == browser
                        )
                    })
                    .map(|tab| (index, panel, tab))
            })?;
        if panel_index == 0 {
            return None;
        }
        let key = (workspace.clone(), panel.id);
        let bounds = *self.workspace_panels.panel_bounds.borrow().get(&key)?;
        let frame = self.workspace_panels.rendered_frames.get(&key)?;
        let tab = *self
            .workspace_panels
            .window_tab_bounds
            .borrow()
            .get(&(workspace, panel.id, tab_index))?;
        let divider = gpui::Bounds::new(
            point(
                bounds.left() - px(6.0),
                bounds.top() + px(frame.header_height),
            ),
            gpui::size(
                px(6.0),
                (bounds.size.height - px(frame.header_height)).max(px(0.0)),
            ),
        );
        Some((tab, divider))
    }

    pub fn fixture_workspace_resizing(&self) -> bool {
        self.workspace_resize_active()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn panel_workspace_tab_size_changes_only_when_tabs_exhaust_available_space() {
        assert_eq!(panel_tab_width(320.0, 1), 240.0);
        assert_eq!(panel_tab_width(580.0, 1), 240.0);
        assert_eq!(panel_tab_width(1200.0, 1), 240.0);
        assert_eq!(panel_tab_width(1200.0, 4), 240.0);
        assert!(panel_tab_width(580.0, 3) < 240.0);
        assert_eq!(panel_tab_width(320.0, 8), 112.0);
    }
    #[test]
    fn panel_workspace_height_capacity_uses_logical_window_height_and_caps_at_three() {
        for (height, limit) in [
            (600.0, 1),
            (655.0, 1),
            (656.0, 2),
            (700.0, 2),
            (760.0, 2),
            (900.0, 2),
            (1103.0, 2),
            (1104.0, 3),
            (1440.0, 3),
            (2160.0, 3),
        ] {
            assert_eq!(stacked_panel_limit(height), limit, "height {height}");
        }
        let mut layout = WorkspaceLayout::default();
        layout.insert(0, PanelTab::Terminal(1));
        let other = layout.add_panel(0);
        layout.insert(other, PanelTab::Terminal(2));
        assert!(
            layout.can_split_at(0, &PanelTab::Terminal(1), other, PanelEdge::Bottom),
            "repositioning a sole tab does not add a row"
        );
        layout.insert(0, PanelTab::Terminal(3));
        assert!(!layout.can_split_at(0, &PanelTab::Terminal(1), other, PanelEdge::Bottom));
        assert!(layout.can_split_at(0, &PanelTab::Terminal(1), other, PanelEdge::Right));
    }
    #[test]
    fn panel_workspace_split_motion_reverses_from_its_current_size_and_respects_reduced_motion() {
        let now = std::time::Instant::now();
        let duration = PANEL_SPLIT_MOTION.total().mul_f32(motion::speed_scale());
        let mut preview = PanelSplitReveal::default();
        preview.retarget(true, false, now);
        assert_eq!(preview.value(now, false), 0.0);
        let midpoint = now + duration / 2;
        let partial = preview.value(midpoint, false);
        assert!(partial > 0.0 && partial < 1.0);
        preview.retarget(false, false, midpoint);
        assert_eq!(preview.value(midpoint, false), partial);
        assert_eq!(preview.value(midpoint + duration, false), 0.0);
        preview.retarget(true, true, now);
        assert_eq!(preview.value(now, true), 1.0);
        assert!(!preview.animating(now, true));
    }

    #[test]
    fn panel_workspace_reorders_whole_panels_without_changing_tabs_or_selection() {
        let mut l = WorkspaceLayout::default();
        l.insert(0, PanelTab::Chat("one".into()));
        l.insert(0, PanelTab::Chat("two".into()));
        let second = l.add_panel(0);
        l.insert(second, PanelTab::Terminal(4));
        l.expanded = Some(0);
        assert!(l.reorder_panel(0, true));
        assert_eq!(l.panels[1].id, 0);
        assert_eq!(l.panels[1].active, 1);
        assert_eq!(l.panels[1].tabs.len(), 2);
        assert_eq!(l.expanded, Some(0));
        assert!(!l.reorder_panel(0, true));
    }
    #[test]
    fn panel_workspace_tab_transfer_retains_both_panels_and_correct_active_tabs() {
        let mut l = WorkspaceLayout::default();
        let a = PanelTab::Chat("a".into());
        let b = PanelTab::Chat("b".into());
        l.insert(0, a.clone());
        l.insert(0, b.clone());
        let right = l.add_panel(0);
        l.insert(right, PanelTab::Terminal(3));
        assert!(l.move_tab(0, &b, right, Some(0)));
        assert_eq!(l.panel(0).unwrap().selected(), Some(&a));
        assert_eq!(l.panel(right).unwrap().selected(), Some(&b));
        assert_eq!(l.focused, right);
        l.move_tab(0, &a, right, None);
        assert_eq!(l.panels.len(), 2);
        assert!(l.panel(0).unwrap().tabs.is_empty());
        assert_eq!(l.panel(right).unwrap().selected(), Some(&a));
    }
    #[test]
    fn panel_workspace_neighbors_and_same_bar_insertion_are_directional() {
        let mut l = WorkspaceLayout::default();
        for id in [1, 2, 3] {
            l.insert(0, PanelTab::Terminal(id));
        }
        assert_eq!(l.neighbor(0, false), None);
        assert_eq!(l.neighbor(0, true), None);
        let right = l.add_panel(0);
        assert_eq!(l.neighbor(0, true), Some(right));
        assert_eq!(l.neighbor(right, true), None);
        l.move_tab(0, &PanelTab::Terminal(1), 0, Some(3));
        assert_eq!(
            l.panel(0).unwrap().tabs,
            vec![
                PanelTab::Terminal(2),
                PanelTab::Terminal(3),
                PanelTab::Terminal(1)
            ]
        );
        assert!(!l.move_tab(0, &PanelTab::Terminal(7), right, None));
    }

    #[test]
    fn panel_workspace_edge_split_extracts_one_tab_on_either_side() {
        for right in [false, true] {
            let mut layout = WorkspaceLayout::default();
            layout.insert(0, PanelTab::Terminal(1));
            layout.insert(0, PanelTab::Terminal(2));
            layout.expanded = Some(0);
            let new = layout
                .split_tab(
                    0,
                    &PanelTab::Terminal(2),
                    0,
                    PanelEdge::along(SplitAxis::Horizontal, right),
                )
                .unwrap();
            assert_eq!(
                layout.panels.iter().map(|p| p.id).collect::<Vec<_>>(),
                if right { vec![0, new] } else { vec![new, 0] }
            );
            assert_eq!(layout.panel(0).unwrap().tabs, vec![PanelTab::Terminal(1)]);
            assert_eq!(layout.panel(new).unwrap().tabs, vec![PanelTab::Terminal(2)]);
            assert_eq!(layout.focused, new);
            assert_eq!(layout.expanded, None);
            assert!(layout.panels.iter().all(|p| p.share == 0.5));
        }
    }

    #[test]
    fn panel_workspace_edge_split_removes_the_empty_source_and_rejects_invalid_drops() {
        let mut layout = WorkspaceLayout::default();
        layout.insert(0, PanelTab::Terminal(1));
        assert_eq!(
            layout.split_tab(0, &PanelTab::Terminal(1), 0, PanelEdge::Right),
            None
        );
        let beside = layout.add_panel(0);
        layout.insert(beside, PanelTab::Terminal(2));
        assert_eq!(
            layout.split_tab(0, &PanelTab::Terminal(7), beside, PanelEdge::Right),
            None
        );
        assert_eq!(
            layout.split_tab(0, &PanelTab::Terminal(1), 99, PanelEdge::Right),
            None
        );
        assert_eq!(layout.panels.len(), 2);
        let new = layout
            .split_tab(0, &PanelTab::Terminal(1), beside, PanelEdge::Right)
            .unwrap();
        assert_eq!(
            layout.panels.iter().map(|p| p.id).collect::<Vec<_>>(),
            vec![beside, new]
        );
        assert_eq!(layout.location(&PanelTab::Terminal(1)), Some((new, 0)));
        assert_eq!(layout.location(&PanelTab::Terminal(2)), Some((beside, 0)));
        assert!(layout.panels.iter().all(|p| !p.tabs.is_empty()));
    }
}

#[cfg(feature = "appshots-fixture")]
impl Shell {
    pub fn fixture_files_review(&mut self, phase: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.workspace_panels.explorers.is_empty() {
            self.ensure_workspace_sessions(cx);
            self.open_workspace_files(window, cx);
            let layout = self.panel_layout_mut(cx);
            let id = layout.focused;
            layout.panels.retain(|panel| panel.id == id);
            let tab = layout.panels[0].tabs.iter().find(|tab| matches!(tab, PanelTab::FileTree(_))).unwrap().clone();
            layout.panels[0].tabs = vec![tab];
            layout.panels[0].active = 0;
        }
        let files = self.workspace_panels.explorers.values().next().unwrap().0.clone();
        files.update(cx, |files, cx| files.fixture_explorer(phase, cx));
        window.blur();
        cx.notify();
    }

    pub fn fixture_panel_layout(&mut self, phase: u8, window: &mut Window, cx: &mut Context<Self>) {
        if phase == 0 {
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let owner = self.panel_key(cx);
            let key = crate::project_actions::ProjectActionsKey {
                device_id: self
                    .state
                    .read(cx)
                    .selected_chat_row()
                    .unwrap()
                    .device_id
                    .clone(),
                space_id: "launch".into(),
            };
            self.project_actions.active = Some(key.clone());
            self.project_actions.cache.insert(
                key,
                crate::project_actions::ProjectActionsStatus::Ready(
                    harness_proto::ProjectActionsSnapshot {
                        space_id: "launch".into(),
                        actions: [("Preview", "preview"), ("Run tests", "tests")]
                            .into_iter()
                            .map(|(name, id)| harness_proto::ProjectAction {
                                id: id.into(),
                                name: name.into(),
                                command: "true".into(),
                                icon: harness_proto::ProjectActionIcon::Play,
                                run_on_worktree_create: false,
                            })
                            .collect(),
                        importable_actions: vec![],
                        project_file_issue: None,
                    },
                ),
            );
            self.add_browser_surface(None, window, cx);
            // Render the real browser shell without any external navigation.
            self.add_files_surface(window, cx);
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            let files = PanelTab::Files(owner);
            if let Some((from, _)) = layout.location(&files) {
                let to = layout.add_panel(layout.panels.last().unwrap().id);
                layout.move_tab(from, &files, to, None);
            }
            layout.focused = 0;
        } else if phase == 1 {
            let layout = self.panel_layout_mut(cx);
            layout.reorder_panel(0, true);
        } else if phase == 2 {
            let layout = self.panel_layout_mut(cx);
            let to = layout.neighbor(0, true).unwrap_or(layout.panels[0].id);
            let tab = layout.panel(0).unwrap().tabs[0].clone();
            self.move_workspace_tab(0, tab, to, None, window, cx);
        } else if phase == 3 {
            let layout = self.panel_layout_mut(cx);
            layout.expanded = Some(layout.focused);
        } else if phase == 4 {
            self.panel_layout_mut(cx).expanded = None;
        } else if phase == 5 {
            let layout = self.panel_layout_mut(cx);
            let id = layout.focused;
            let tab = layout.panel(id).and_then(|p| p.selected()).cloned();
            self.open_panel_menu(id, tab, point(px(650.0), px(42.0)), false, window, cx);
        } else if phase == 6 {
            self.workspace_panels.menu = None;
            self.workspace_new_chat(cx);
        } else if phase == 7 || phase == 8 {
            self.toggle_files_panel(window, cx);
        } else if phase == 9 {
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            layout.add_panel(0);
            layout.focused = 0;
        } else if phase == 10 {
            if let Some(focus) = self.workspace_panels.controls.get("panel-close-1") {
                window.focus(focus, cx);
            }
        } else if phase == 11 {
            self.close_workspace_panel(1, window, cx);
        } else if phase == 13 || phase == 15 {
            let id = if phase == 13 {
                0
            } else {
                self.panel_layout_mut(cx).focused
            };
            if let Some(focus) = self
                .workspace_panels
                .controls
                .get(&format!("panel-placement-{id}"))
            {
                window.focus(focus, cx);
            }
        } else if phase == 14 {
            let index = self.workspace_panels.menu.as_ref().unwrap().rows.len() - 1;
            self.activate_panel_menu(index, window, cx);
        } else if phase == 16 {
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            let middle = layout.add_panel(0);
            layout.add_panel(middle);
            for (ix, panel) in layout.panels.iter_mut().enumerate() {
                panel.tabs = vec![
                    PanelTab::Chat(format!("launch-{ix}")),
                    PanelTab::Draft(100 + ix as u64),
                    PanelTab::Chat(format!("mobile-{ix}")),
                ];
                panel.active = 0;
            }
            layout.focused = 0;
            window.blur();
        } else if phase == 12 {
            // Each capture starts with the same two synthetic conversations,
            // even after a prior split changed the shared fixture selection.
            self.select_workspace_chat(Some("launch-0".into()), cx);
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            layout.insert(0, PanelTab::Chat("launch-1".into()));
            layout.panel_mut(0).unwrap().active = 0;
        } else if phase == 30 {
            self.select_workspace_chat(Some("launch-0".into()), cx);
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            let right = layout.add_panel(0);
            layout.insert(right, PanelTab::Chat("launch-1".into()));
            layout.panel_mut(0).unwrap().tabs = [
                "launch-0",
                "launch-2",
                "mobile-0",
                "mobile-1",
                "mobile-2",
                "backend-0",
                "backend-1",
                "backend-2",
            ]
            .into_iter()
            .map(|id| PanelTab::Chat(id.into()))
            .collect();
            layout.focused = 0;
            window.blur();
        } else if phase == 40 || phase == 41 {
            self.select_workspace_chat(Some("launch-0".into()), cx);
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            layout.insert(0, PanelTab::Chat("launch-1".into()));
            let other = layout.add_panel(0);
            layout.insert(other, PanelTab::Chat("launch-2".into()));
            layout.panel_mut(0).unwrap().active = 0;
            layout.focused = 0;
            layout.axis = if phase == 41 {
                SplitAxis::Vertical
            } else {
                SplitAxis::Horizontal
            };
            window.blur();
        } else if phase == 45 || phase == 46 {
            self.select_workspace_chat(Some("launch-0".into()), cx);
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            let lower = layout.add_panel(0);
            layout.insert(lower, PanelTab::Chat("launch-1".into()));
            layout.axis = SplitAxis::Vertical;
            layout.focused = if phase == 45 { lower } else { 0 };
            self.workspace_new_chat(cx);
        } else if phase == 47 {
            let layout = self.panel_layout_mut(cx);
            layout.expanded = Some(layout.focused);
        } else if phase == 48 {
            let panel = self.panel_layout_mut(cx).focused;
            self.focus_workspace_tab(panel, PanelTab::Chat("launch-1".into()), window, cx);
        } else if phase == 49 {
            self.fixture_panel_layout(0, window, cx);
            let owner = self.panel_key(cx);
            let docs_id = self.browser_seq;
            self.browsers[&docs_id].update(cx, |browser, cx| {
                browser.page.url = Some("https://docs.example.test".into());
                browser.page.title = "Project docs".into();
                browser.favicon = Some(std::sync::Arc::new(gpui::Image::from_bytes(
                    gpui::ImageFormat::Png,
                    include_bytes!("../../assets/file-icons/files/nuxt.png").to_vec(),
                )));
                cx.emit(crate::browser::BrowserEvent::Changed);
                cx.notify();
            });
            self.add_browser_surface(None, window, cx);
            let blank_id = self.browser_seq;
            self.workspace_new_chat(cx);
            let layout = self.panel_layout_mut(cx);
            let draft = layout
                .panel(layout.focused)
                .unwrap()
                .selected()
                .unwrap()
                .clone();
            layout.panels.truncate(1);
            layout.axis = SplitAxis::Vertical;
            let upper_id = layout.panels[0].id;
            let upper = &mut layout.panels[0];
            upper.tabs = vec![
                PanelTab::Chat("launch-0".into()),
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Browser(docs_id),
                },
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Browser(blank_id),
                },
            ];
            upper.active = 0;
            let lower = layout.add_panel(upper_id);
            layout.panel_mut(lower).unwrap().tabs = vec![
                draft.clone(),
                PanelTab::Terminal(u64::MAX),
                PanelTab::Files(owner),
            ];
            layout.panel_mut(lower).unwrap().active = 0;
            layout.focused = lower;
            self.focus_workspace_tab(lower, draft, window, cx);
        } else if phase == 50 {
            self.select_workspace_chat(Some("launch-0".into()), cx);
            self.workspace_panels = Default::default();
            self.sync_panel_workspace(cx);
            let layout = self.panel_layout_mut(cx);
            layout.add_panel(0);
            layout.axis = SplitAxis::Vertical;
            for (ix, panel) in layout.panels.iter_mut().enumerate() {
                let project = if ix == 0 { "launch" } else { "mobile" };
                panel.tabs = (0..3)
                    .map(|tab| PanelTab::Chat(format!("{project}-{tab}")))
                    .collect();
                panel.active = 0;
            }
            layout.focused = 0;
            window.blur();
        } else if phase == 51 || phase == 52 {
            for panel in &mut self.panel_layout_mut(cx).panels {
                panel.active = usize::from(phase - 50);
            }
            window.blur();
        } else if phase == 53 {
            self.panel_layout_mut(cx).axis = SplitAxis::Horizontal;
            window.blur();
        } else if phase == 54 {
            if let Some(focus) = self.workspace_panels.controls.get("panel-tab-0-1") {
                window.focus(focus, cx);
            }
        } else if phase == 43 {
            self.open_panel_menu(0, None, point(px(500.0), px(60.0)), true, window, cx);
        } else if phase == 44 {
            self.workspace_panels.menu = None;
        } else if phase == 31 {
            if let Some(scroll) = self
                .workspace_panels
                .scrolls
                .get(&(self.workspace_layout_key(cx), 0))
            {
                scroll.set_offset(point(px(-72.0), px(0.0)));
            }
        }
        cx.notify();
    }

    pub fn fixture_panel_limit_state(&self, cx: &App) -> (usize, usize) {
        let layout = self.panel_layout(cx).unwrap();
        (
            layout.stack_limit,
            layout.panels.iter().map(|panel| panel.tabs.len()).sum(),
        )
    }

    pub fn fixture_panel_visible_bounds(&self, cx: &App) -> Vec<gpui::Bounds<Pixels>> {
        let workspace = self.workspace_layout_key(cx);
        let layout = self.panel_layout(cx).unwrap();
        let bounds = self.workspace_panels.panel_bounds.borrow();
        let mut visible = vec![];
        for panel in &layout.panels {
            if let (Some(rect), Some(frame)) = (
                bounds.get(&(workspace.clone(), panel.id)),
                self.workspace_panels
                    .rendered_frames
                    .get(&(workspace.clone(), panel.id)),
            ) {
                let mut rect = *rect;
                rect.origin.y += px(frame.header_height);
                rect.size.height -= px(frame.header_height);
                visible.push(rect);
            }
        }
        visible
    }

    pub fn fixture_panel_axis_state(
        &self,
        cx: &App,
    ) -> (
        bool,
        Vec<(u64, gpui::Bounds<Pixels>)>,
        Option<(u64, &'static str)>,
    ) {
        let workspace = self.workspace_layout_key(cx);
        let layout = self.panel_layout(cx).unwrap();
        let bounds = self.workspace_panels.panel_bounds.borrow();
        let frames = layout
            .panels
            .iter()
            .filter_map(|panel| {
                bounds
                    .get(&(workspace.clone(), panel.id))
                    .map(|bounds| (panel.id, *bounds))
            })
            .collect();
        let target = self
            .workspace_panels
            .split_previews
            .iter()
            .find(|((key, _, _), preview)| key == &workspace && preview.active)
            .map(|((_, panel, edge), _)| (*panel, edge.name()));
        (layout.axis == SplitAxis::Vertical, frames, target)
    }

    pub fn fixture_panel_stability_state(
        &self,
        cx: &App,
    ) -> (Point<Pixels>, gpui::Bounds<Pixels>, Option<(u64, bool)>) {
        let workspace = self.workspace_layout_key(cx);
        let scroll = &self.workspace_panels.scrolls[&(workspace.clone(), 0)];
        let active = self
            .workspace_panels
            .split_previews
            .iter()
            .find(|((key, _, _), preview)| key == &workspace && preview.active)
            .map(|((_, panel, right), _)| (*panel, right.after()));
        (scroll.offset(), scroll.bounds(), active)
    }
}

#[cfg(test)]
mod interaction_tests {
    use super::*;
    use gpui::{AppContext, TestAppContext, VisualTestContext};
    struct Host {
        shell: Entity<Shell>,
        _dir: tempfile::TempDir,
    }
    impl Render for Host {
        fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            self.shell
                .update(cx, |shell, cx| shell.render_panel_workspace(window, cx))
        }
    }
    fn setup(cx: &mut TestAppContext) -> (Entity<Shell>, &mut VisualTestContext) {
        let dir = tempfile::tempdir().unwrap();
        cx.update(|cx| {
            gpui_base::init(cx);
            cx.set_global(Theme::default());
            crate::app_menus::init(cx);
            let settings = crate::settings::UiSettings::default();
            crate::history::init(
                settings.git_history_columns,
                settings.git_history_column_widths,
                settings.git_history_column_order,
                settings.git_history_author_display,
                cx,
            );
            motion::set_reduced_motion(cx, true);
        });
        let (host, cx) = cx.add_window_view(|_, cx| {
            let shell = cx.new(|cx| {
                let state = cx.new(|_| AppState::new());
                let mut shell = Shell::new(
                    state,
                    EngineBootConfig {
                        data_dir: dir.path().into(),
                        ipc_port: 0,
                        edge_url: "http://127.0.0.1:1".into(),
                        edge_token: None,
                        org_id: None,
                        codegraff_client_id: None,
                        default_harness: harness_proto::HarnessId::Mock,
                    },
                    cx,
                );
                shell.reduced_motion = true;
                let mut layout = WorkspaceLayout::default();
                layout.last_selected = Some(None);
                layout.insert(0, PanelTab::Terminal(1));
                let next = layout.add_panel(0);
                layout.insert(next, PanelTab::Terminal(2));
                layout.focused = 0;
                shell.workspace_panels.layouts.insert(String::new(), layout);
                shell
            });
            Host { shell, _dir: dir }
        });
        let shell = host.read_with(cx, |h, _| h.shell.clone());
        cx.update(|w, cx| w.draw(cx).clear());
        (shell, cx)
    }
    #[gpui::test]
    fn panel_workspace_new_tab_button_follows_the_last_tab_on_hover(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
            panel.tabs = vec![PanelTab::Terminal(1), PanelTab::Terminal(3)];
            panel.active = 0;
            cx.notify();
        });
        cx.run_until_parked();
        // The same hover state hides the button; a hidden element still records
        // its own bounds, but children of the hidden controls record none.
        assert!(cx.debug_bounds("panel-placement-0").is_none());
        let last = cx.debug_bounds("panel-tab-0-1").unwrap();
        let header = cx.debug_bounds("workspace-panel-header-0").unwrap();
        cx.simulate_mouse_move(header.center(), None, Default::default());
        cx.run_until_parked();
        let add = cx.debug_bounds("panel-add-tab-0").unwrap();
        let placement = cx.debug_bounds("panel-placement-0").unwrap();
        assert!(add.left() >= last.right());
        assert!(add.left() - last.right() <= px(4.0));
        assert!(add.right() < placement.left());
        // Against the tab's content: its box extends down to join the panel.
        let icon = cx.debug_bounds("panel-tab-icon-0-1").unwrap();
        assert_eq!(add.center().y, icon.center().y);
        assert_eq!(
            cx.debug_bounds("panel-tab-0-1").unwrap(),
            last,
            "showing it doesn't move the tabs"
        );
    }

    #[gpui::test]
    fn panel_workspace_first_tab_shares_the_panel_left_edge(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        let mut icon_inset = None;
        for collapsed in [false, true] {
            shell.update_in(cx, |s, _, cx| {
                s.settings.sidebar_collapsed = collapsed;
                let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
                panel.tabs = vec![PanelTab::Terminal(1), PanelTab::Terminal(3)];
                panel.active = 0;
                cx.notify();
            });
            cx.run_until_parked();
            let body = cx.debug_bounds("workspace-panel-body-0").unwrap();
            let first = cx.debug_bounds("panel-tab-0-0").unwrap();
            let next = cx.debug_bounds("panel-tab-0-1").unwrap();
            assert_eq!(
                first.left(),
                body.left(),
                "the first selected tab shares the panel's vertical edge"
            );
            assert_eq!(first.size.width, next.size.width);
            assert_eq!(first.bottom(), body.top());
            let icon = cx.debug_bounds("panel-tab-icon-0-0").unwrap();
            let inset = icon.left() - first.left();
            if let Some(open_inset) = icon_inset {
                assert_eq!(
                    inset, open_inset,
                    "controls never enlarge a tab's content inset"
                );
            } else {
                icon_inset = Some(inset);
            }
            if collapsed {
                assert_eq!(first.top(), px(PANEL_HEADER_HEIGHT + STACKED_CLEARANCE));
                assert_eq!(
                    first.left(),
                    px(GUTTER),
                    "the canvas keeps the full window width"
                );
                for selector in ["toggle-sidebar", "workspace-session-quick-switcher"] {
                    let control = cx.debug_bounds(selector).unwrap();
                    assert!(
                        control.bottom() < first.top(),
                        "window controls sit above tabs"
                    );
                }
            } else {
                assert_eq!(first.top(), px(STACKED_CLEARANCE));
            }
        }
    }

    #[gpui::test]
    fn panel_workspace_tab_context_follows_each_conversation_and_ignores_legacy_display_choices(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, window, cx| {
            s.state.update(cx, |state, _| {
                state.chats = [("one", "first-model", "feature/one"), ("two", "second-model", "feature/two")]
                    .into_iter().map(|(id, model, branch)| serde_json::from_value(serde_json::json!({
                        "id": id, "deviceId": "fixture", "title": id,
                        "createdAt": Utc::now(), "archived": false, "branch": branch,
                        "sourceContext": { "checkoutId": "fixture", "repoRoot": "/fixture", "cwd": "/fixture", "branch": branch, "observedAt": Utc::now() },
                        "config": { "harness": "graff", "model": model, "reasoning": null, "sandbox": "workspace-write" }
                    })).unwrap()).collect();
            });
            let one = s.panel_tab_context(&PanelTab::Chat("one".into()), 0, &"One".into(), cx).unwrap();
            let two = s.panel_tab_context(&PanelTab::Chat("two".into()), 0, &"Two".into(), cx).unwrap();
            assert_eq!(one.model.as_deref(), Some("first-model"));
            assert_eq!(two.model.as_deref(), Some("second-model"));
            assert_eq!(one.branch.as_deref(), Some("feature/one"));
            assert_eq!(two.branch.as_deref(), Some("feature/two"));
            assert!(two.tooltip.contains("second-model"));
            assert!(!two.tooltip.contains("first-model"));

            // Older sidebar preferences cannot hide the fixed tab context.
            s.settings.sidebar_compact = false;
            s.settings.sidebar_show_branch = false;
            s.settings.sidebar_show_harness = false;
            s.settings.sidebar_show_updated = true;
            s.settings.sidebar_show_project_icon = true;
            s.settings.sidebar_show_project_label = true;
            let context = s.panel_tab_context(&PanelTab::Chat("two".into()), 0, &"Two".into(), cx).unwrap();
            assert!(context.harness.is_some());
            assert_eq!(context.model.as_deref(), Some("second-model"));
            assert_eq!(context.branch.as_deref(), Some("feature/two"));
            assert!(!context.tooltip.contains("Project:"));
            assert!(!context.tooltip.contains("Updated"));
        });
    }

    #[gpui::test]
    fn panel_workspace_single_tabs_and_empty_labels_keep_a_shared_size_and_centerline(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1200.0), px(1200.0)));
        for axis in [SplitAxis::Horizontal, SplitAxis::Vertical] {
            shell.update_in(cx, |s, _, cx| {
                s.state.update(cx, |state, _| {
                    state.chats = vec![serde_json::from_value(serde_json::json!({
                        "id": "sizing", "deviceId": "fixture", "title": "Review the release",
                        "createdAt": Utc::now(), "archived": false, "branch": "feature/release",
                        "config": { "harness": "graff", "model": "fixture-model", "reasoning": null, "sandbox": "workspace-write" }
                    })).unwrap()];
                });
                let layout = s.panel_layout_mut(cx);
                layout.axis = axis;
                layout.panel_mut(0).unwrap().tabs = vec![PanelTab::Chat("sizing".into())];
                layout.panel_mut(1).unwrap().tabs = vec![PanelTab::New(99)];
                cx.notify();
            });
            cx.run_until_parked();
            let chat = cx.debug_bounds("panel-tab-content-0-0").unwrap();
            let blank = cx.debug_bounds("panel-tab-content-1-0").unwrap();
            assert_eq!(chat.size, blank.size);
            assert_eq!(chat.size, gpui::size(px(240.0), px(PANEL_TAB_HEIGHT)));
            let center =
                blank.center().y - cx.debug_bounds("workspace-panel-header-1").unwrap().top();
            shell.update_in(cx, |s, _, cx| {
                s.panel_layout_mut(cx).panel_mut(1).unwrap().tabs.clear();
                cx.notify();
            });
            cx.run_until_parked();
            let empty = cx.debug_bounds("panel-empty-label-1").unwrap();
            let header = cx.debug_bounds("workspace-panel-header-1").unwrap();
            assert_eq!(empty.center().y - header.top(), center);
        }
    }

    #[gpui::test]
    fn panel_workspace_tab_context_always_reveals_on_hover_without_resizing_tabs(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        cx.update(|_, cx| motion::set_reduced_motion(cx, true));
        shell.update_in(cx, |s, _, cx| {
            s.state.update(cx, |state, _| {
                state.chats = vec![serde_json::from_value(serde_json::json!({
                    "id": "metadata", "deviceId": "fixture", "title": "Review the release",
                    "createdAt": Utc::now(), "archived": false, "branch": "feature/release",
                    "sourceContext": { "checkoutId": "fixture", "repoRoot": "/fixture", "cwd": "/fixture", "branch": "feature/release", "observedAt": Utc::now() },
                    "config": { "harness": "graff", "model": "fixture-model", "reasoning": null, "sandbox": "workspace-write" }
                })).unwrap()];
            });
            s.settings.sidebar_compact = false;
            let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
            panel.tabs = vec![PanelTab::Chat("metadata".into())];
            panel.active = 0;
            cx.notify();
        });
        cx.run_until_parked();
        let tab = cx.debug_bounds("panel-tab-0-0").unwrap();
        let title = cx.debug_bounds("panel-tab-0-0-title").unwrap();
        let idle_icon = cx.debug_bounds("panel-tab-icon-0-0").unwrap();
        assert!((f32::from(idle_icon.center().y - title.center().y)).abs() < 0.5);
        assert!(cx.debug_bounds("panel-tab-display-0").is_none());
        cx.simulate_mouse_move(tab.center(), None, Default::default());
        cx.run_until_parked();
        let revealed = cx.debug_bounds("panel-tab-0-0-title").unwrap();
        assert_eq!(cx.debug_bounds("panel-tab-0-0"), Some(tab));
        assert!((f32::from(title.top() - revealed.top()) - 6.5).abs() < 0.5);
        let branch = cx.debug_bounds("panel-tab-0-0-branch").unwrap();
        assert_eq!(branch.left(), revealed.left());
        let icon = cx.debug_bounds("panel-tab-icon-0-0").unwrap();
        assert!((f32::from(icon.center().y - revealed.center().y)).abs() < 0.5);
        assert!(cx.debug_bounds("panel-tab-0-0-model").is_some());
        let body = cx.debug_bounds("workspace-panel-body-0").unwrap();
        cx.simulate_mouse_move(body.center(), None, Default::default());
        cx.run_until_parked();
        assert_eq!(cx.debug_bounds("panel-tab-0-0"), Some(tab));
        assert_eq!(cx.debug_bounds("panel-tab-0-0-title"), Some(title));
        let hidden_close = cx.debug_bounds("panel-tab-close-0-0").unwrap();
        cx.simulate_click(hidden_close.center(), Default::default());
        cx.run_until_parked();
        assert!(
            shell.read_with(cx, |s, cx| {
                s.panel_layout(cx)
                    .unwrap()
                    .panel(0)
                    .unwrap()
                    .tabs
                    .contains(&PanelTab::Chat("metadata".into()))
            }),
            "a hidden close slot cannot close the active tab"
        );
    }

    #[gpui::test]
    fn panel_workspace_hover_details_share_title_edge_and_stay_grouped(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        cx.update(|_, cx| motion::set_reduced_motion(cx, true));
        shell.update_in(cx, |s, _, cx| {
            s.state.update(cx, |state, _| {
                state.chats = vec![serde_json::from_value(serde_json::json!({
                    "id": "aligned", "deviceId": "fixture", "title": "Review the release",
                    "createdAt": Utc::now(), "archived": false,
                    "sourceContext": { "checkoutId": "fixture", "repoRoot": "/fixture", "cwd": "/fixture", "branch": "feature/release-preview", "observedAt": Utc::now() },
                    "config": { "harness": "graff", "model": "fixture-model", "reasoning": null, "sandbox": "workspace-write" }
                })).unwrap()];
            });
            s.settings.reset_sidebar_display();
            s.settings.sidebar_compact = false;
            let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
            panel.tabs = vec![PanelTab::Chat("aligned".into())];
            panel.active = 0;
            cx.notify();
        });
        for width in [1200.0, 980.0, 620.0] {
            cx.simulate_resize(gpui::size(px(width), px(760.0)));
            cx.run_until_parked();
            let body = cx.debug_bounds("workspace-panel-body-0").unwrap();
            cx.simulate_mouse_move(body.center(), None, Default::default());
            cx.run_until_parked();
            let tab = cx.debug_bounds("panel-tab-0-0").unwrap();
            cx.simulate_mouse_move(tab.center(), None, Default::default());
            cx.run_until_parked();
            let title = cx.debug_bounds("panel-tab-0-0-title").unwrap();
            let branch = cx.debug_bounds("panel-tab-0-0-branch").unwrap();
            let agent = cx.debug_bounds("panel-tab-0-0-agent").unwrap();
            let model = cx.debug_bounds("panel-tab-0-0-model").unwrap();
            assert!(cx.debug_bounds("panel-tab-0-0-updated").is_none());
            assert!(cx.debug_bounds("panel-tab-0-0-project").is_none());
            let icon = cx.debug_bounds("panel-tab-icon-0-0").unwrap();
            assert_eq!(title.left(), branch.left());
            assert!((f32::from(agent.left() - branch.right()) - 6.0).abs() < 0.5);
            assert!(model.right() <= title.right());
            assert!((f32::from(icon.center().y - title.center().y)).abs() < 0.5);
            let tab = cx.debug_bounds("panel-tab-0-0").unwrap();
            cx.simulate_mouse_move(tab.center(), None, Default::default());
            cx.run_until_parked();
            for (selector, before) in [
                ("panel-tab-0-0-branch", branch),
                ("panel-tab-0-0-model", model),
            ] {
                assert_eq!(cx.debug_bounds(selector), Some(before));
            }
        }
    }

    #[gpui::test]
    fn panel_workspace_tab_icons_stay_visible_as_browser_favicons_change(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1600.0), px(900.0)));
        let browser = shell.update_in(cx, |s, window, cx| {
            s.add_browser_surface(None, window, cx);
            let browser_id = s.browser_seq;
            let browser = s.browsers[&browser_id].clone();
            let owner = s.panel_key(cx);
            let layout = s.panel_layout_mut(cx);
            layout.axis = SplitAxis::Vertical;
            layout.panel_mut(0).unwrap().tabs = vec![
                PanelTab::Chat("chat".into()),
                PanelTab::Draft(1),
                PanelTab::Files(owner.clone()),
                PanelTab::Terminal(1),
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Browser(browser_id),
                },
                PanelTab::Surface {
                    owner: owner.clone(),
                    surface: RightSurface::Diff(1),
                },
                PanelTab::Surface {
                    owner,
                    surface: RightSurface::Subagent(1),
                },
                PanelTab::Empty,
            ];
            layout.panel_mut(0).unwrap().active = 0;
            layout.focused = 1;
            cx.notify();
            browser
        });
        cx.run_until_parked();
        for selector in [
            "panel-tab-icon-0-0",
            "panel-tab-icon-0-1",
            "panel-tab-icon-0-2",
            "panel-tab-icon-0-3",
            "panel-tab-icon-0-4",
            "panel-tab-icon-0-5",
            "panel-tab-icon-0-6",
            "panel-tab-icon-0-7",
        ] {
            let icon = cx.debug_bounds(selector).unwrap();
            assert_eq!(icon.size, gpui::size(px(14.0), px(14.0)));
        }
        assert!(cx.debug_bounds("panel-tab-favicon-0-4").is_none());
        let original = cx.debug_bounds("panel-tab-0-4").unwrap();
        browser.update(cx, |browser, cx| {
            browser.page.url = Some("https://docs.example.test".into());
            browser.favicon = Some(std::sync::Arc::new(gpui::Image::from_bytes(
                gpui::ImageFormat::Png,
                include_bytes!("../../assets/file-icons/files/nuxt.png").to_vec(),
            )));
            cx.emit(crate::browser::BrowserEvent::Changed);
            cx.notify();
        });
        cx.run_until_parked();
        assert_eq!(
            cx.debug_bounds("panel-tab-favicon-0-4").unwrap().size,
            gpui::size(px(14.0), px(14.0)),
        );
        assert_eq!(cx.debug_bounds("panel-tab-0-4").unwrap(), original);
        browser.update(cx, |browser, cx| {
            browser.favicon = None;
            cx.emit(crate::browser::BrowserEvent::Changed);
            cx.notify();
        });
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-tab-favicon-0-4").is_none());
        assert!(cx.debug_bounds("panel-tab-icon-0-4").is_some());
        assert_eq!(cx.debug_bounds("panel-tab-0-4").unwrap(), original);
    }

    #[gpui::test]
    fn panel_workspace_repeated_close_stays_in_current_project(cx: &mut TestAppContext) {
        for without_archiving in [false, true] {
            for split in [false, true] {
                let (_dir, window) =
                    super::super::chat_tabs::navigation_tests::fixture(cx, false, Some(false));
                // Already answered, so ⌘W closes instead of asking first.
                cx.update(|cx| crate::settings::set_archive_sessions_on_close(false, cx));
                let parked = window
                    .update(cx, |shell, window, cx| {
                        window.activate_window();
                        shell.boot_restored = true;
                        shell.persist_chat_tabs(cx);
                        shell.sync_panel_workspace(cx);
                        let layout = shell.panel_layout_mut(cx);
                        layout.insert(0, PanelTab::Terminal(100));
                        if split {
                            let panel = layout.add_panel(0);
                            layout.insert(panel, PanelTab::Terminal(101));
                        }
                        let mut other = WorkspaceLayout::default();
                        other.insert(0, PanelTab::Chat("target".into()));
                        other.insert(0, PanelTab::Terminal(200));
                        shell.workspace_panels.layouts.insert("b".into(), other);
                        shell.chat_tabs[1].clone()
                    })
                    .unwrap();
                // Close every tab and any extra empty panel, then keep pressing
                // the actual app action as a held/repeated close shortcut does.
                for _ in 0..8 {
                    cx.update(|cx| {
                        if without_archiving {
                            cx.dispatch_action(&crate::app_menus::CloseTabWithoutArchiving);
                        } else {
                            cx.dispatch_action(&crate::app_menus::CloseTab);
                        }
                    });
                    cx.run_until_parked();
                    window
                        .update(cx, |shell, _, cx| {
                            assert_eq!(shell.active_project(cx).as_deref(), Some("a"));
                            assert_eq!(shell.chat_tab, 0);
                            assert_eq!(shell.chat_tabs.len(), 2);
                            assert_eq!(shell.chat_tabs[1], parked);
                            assert!(shell.closed_chat_tabs.is_empty());
                            let other = &shell.workspace_panels.layouts["b"];
                            assert_eq!(
                                other.panel(0).unwrap().tabs,
                                [PanelTab::Chat("target".into()), PanelTab::Terminal(200)]
                            );
                        })
                        .unwrap();
                }
                window
                    .update(cx, |shell, window, cx| {
                        let layout = shell.panel_layout(cx).unwrap();
                        assert_eq!(layout.panels.len(), 1);
                        assert!(layout.panels[0].tabs.is_empty());
                        window.remove_window();
                    })
                    .unwrap();
            }
        }
    }

    #[gpui::test]
    fn panel_workspace_hover_close_removes_only_the_clicked_tab(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            s.panel_layout_mut(cx).insert(0, PanelTab::Terminal(3));
            s.panel_layout_mut(cx).panel_mut(0).unwrap().active = 0;
            cx.notify();
        });
        cx.run_until_parked();
        let tab = cx.debug_bounds("panel-tab-0-1").unwrap();
        cx.simulate_mouse_move(tab.center(), None, Default::default());
        cx.run_until_parked();
        assert_eq!(cx.debug_bounds("panel-tab-0-1").unwrap(), tab);
        let close = cx.debug_bounds("panel-tab-close-0-1").unwrap().center();
        cx.simulate_mouse_down(close, MouseButton::Left, Default::default());
        cx.simulate_mouse_up(close, MouseButton::Left, Default::default());
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.panel(0).unwrap().tabs, [PanelTab::Terminal(1)]);
            assert_eq!(
                layout.panel(0).unwrap().selected(),
                Some(&PanelTab::Terminal(1))
            );
            assert_eq!(layout.panel(1).unwrap().tabs, [PanelTab::Terminal(2)]);
        });
    }

    fn install_focus_test_terminals(shell: &mut Shell, cx: &mut Context<Shell>) {
        for id in [1, 2, 3] {
            let state = shell.state.clone();
            let terminal = cx.new(|cx| {
                let mut terminal = TerminalPanel::new_embedded(state, cx);
                terminal.pin_session("focus-test".into());
                terminal
            });
            let key = terminal.update(cx, |terminal, cx| {
                terminal.set_open(true, cx);
                terminal.reserve_tab_for_chat("focus-test".into(), "Terminal", cx)
            });
            shell.workspace_panels.terminals.insert(id, terminal);
            shell.workspace_panels.terminal_keys.insert(id, key);
        }
    }

    fn assert_background_close_preserves_focus(cx: &mut TestAppContext, button: MouseButton) {
        for background_panel in [0, 1] {
            let (shell, cx) = setup(cx);
            let focus = shell.update_in(cx, |shell, window, cx| {
                install_focus_test_terminals(shell, cx);
                let layout = shell.panel_layout_mut(cx);
                layout.insert(background_panel, PanelTab::Terminal(3));
                layout.panel_mut(background_panel).unwrap().active = 0;
                layout.focused = 0;
                // Keeping focus within the current header also verifies that
                // closing an inactive tab in that panel doesn't refocus its body.
                let focus = shell.workspace_panels.controls["panel-header-0"].clone();
                window.focus(&focus, cx);
                cx.notify();
                focus
            });
            cx.run_until_parked();
            let (tab_id, close_id) = if background_panel == 0 {
                ("panel-tab-0-1", "panel-tab-close-0-1")
            } else {
                ("panel-tab-1-1", "panel-tab-close-1-1")
            };
            let tab = cx.debug_bounds(tab_id).unwrap();
            cx.simulate_mouse_move(tab.center(), None, Default::default());
            cx.run_until_parked();
            let position = if button == MouseButton::Left {
                cx.debug_bounds(close_id).unwrap().center()
            } else {
                tab.center()
            };
            cx.simulate_mouse_down(position, button, Default::default());
            cx.simulate_mouse_up(position, button, Default::default());
            cx.run_until_parked();
            shell.update_in(cx, |shell, window, cx| {
                let layout = shell.panel_layout(cx).unwrap();
                assert_eq!(layout.focused, 0);
                assert_eq!(
                    layout.panel(0).unwrap().selected(),
                    Some(&PanelTab::Terminal(1))
                );
                assert_eq!(
                    layout.panel(1).unwrap().selected(),
                    Some(&PanelTab::Terminal(2))
                );
                assert!(layout.location(&PanelTab::Terminal(3)).is_none());
                assert!(focus.is_focused(window));
                // This is the first rung of the actual Cmd+W action. It must
                // still close the original focused panel's tab.
                assert!(shell.workspace_close_focused(window, cx));
                let layout = shell.panel_layout(cx).unwrap();
                assert!(layout.panel(0).unwrap().tabs.is_empty());
                assert_eq!(layout.panel(1).unwrap().tabs, [PanelTab::Terminal(2)]);
                window.remove_window();
            });
        }
    }

    #[gpui::test]
    fn panel_workspace_background_close_button_preserves_keyboard_focus(cx: &mut TestAppContext) {
        assert_background_close_preserves_focus(cx, MouseButton::Left);
    }

    #[gpui::test]
    fn panel_workspace_background_middle_click_preserves_keyboard_focus(cx: &mut TestAppContext) {
        assert_background_close_preserves_focus(cx, MouseButton::Middle);
    }

    #[gpui::test]
    fn panel_workspace_active_tab_close_focuses_its_survivor(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        let survivor = shell.update_in(cx, |shell, window, cx| {
            install_focus_test_terminals(shell, cx);
            shell.panel_layout_mut(cx).insert(0, PanelTab::Terminal(3));
            shell.focus_workspace_tab(0, PanelTab::Terminal(1), window, cx);
            shell.workspace_panels.terminals[&3].read(cx).focus_handle()
        });
        cx.run_until_parked();
        let tab = cx.debug_bounds("panel-tab-0-0").unwrap();
        cx.simulate_mouse_move(tab.center(), None, Default::default());
        cx.run_until_parked();
        let close = cx.debug_bounds("panel-tab-close-0-0").unwrap().center();
        cx.simulate_mouse_down(close, MouseButton::Left, Default::default());
        cx.simulate_mouse_up(close, MouseButton::Left, Default::default());
        cx.run_until_parked();
        shell.update_in(cx, |shell, window, cx| {
            let layout = shell.panel_layout(cx).unwrap();
            assert_eq!(layout.focused, 0);
            assert_eq!(
                layout.panel(0).unwrap().selected(),
                Some(&PanelTab::Terminal(3))
            );
            assert!(survivor.is_focused(window));
        });
    }

    #[gpui::test]
    fn panel_workspace_hover_controls_overlay_tabs_without_moving_the_scroll_viewport(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1600.0), px(900.0)));
        shell.update_in(cx, |s, _, cx| {
            s.reduced_motion = true;
            let layout = s.panel_layout_mut(cx);
            layout.add_panel(1);
            let panel = layout.panel_mut(0).unwrap();
            panel.tabs = (1..=10).map(PanelTab::Terminal).collect();
            panel.active = 9;
            cx.notify();
        });
        cx.run_until_parked();
        let scroll = shell.read_with(cx, |s, _| {
            s.workspace_panels.scrolls[&(String::new(), 0)].clone()
        });
        scroll.set_offset(point(px(-72.0), px(0.0)));
        cx.update(|window, _| window.refresh());
        cx.run_until_parked();
        let manual_offset = scroll.offset();
        let body = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let first = cx.debug_bounds("panel-tab-0-0").unwrap();
        let second = cx.debug_bounds("panel-tab-0-1").unwrap();
        let idle_width = scroll.bounds().size.width;
        assert_eq!(first.size.width, second.size.width);
        assert_eq!(first.size.width, px(112.0));
        assert_eq!(idle_width, body.size.width - px(4.0));
        assert!(cx.debug_bounds("panel-placement-0").is_none());

        // The panel's content doesn't bring them up; only its header does.
        cx.simulate_mouse_move(body.center(), None, Default::default());
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-placement-0").is_none());
        let header = cx.debug_bounds("workspace-panel-header-0").unwrap();
        cx.simulate_mouse_move(header.center(), None, Default::default());
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-placement-0").is_some());
        assert_eq!(scroll.bounds().size.width, idle_width);
        assert_eq!(scroll.offset(), manual_offset);
        let controls = cx.debug_bounds("panel-controls-0").unwrap();
        assert!((f32::from(body.right() - controls.right()) - 4.0).abs() < 1.0);
        assert_eq!(cx.debug_bounds("panel-tab-0-0").unwrap(), first);
        assert_eq!(cx.debug_bounds("panel-tab-0-1").unwrap(), second);

        for name in [
            "panel-placement-0",
            "panel-add-tab-0",
            "panel-expand-0",
            "panel-close-0",
        ] {
            let button = cx.debug_bounds(name).unwrap();
            cx.simulate_mouse_move(button.center(), None, Default::default());
            cx.run_until_parked();
            assert!(
                cx.debug_bounds("panel-placement-0").is_some(),
                "controls disappeared while hovering {name}"
            );
            assert_eq!(scroll.bounds().size.width, idle_width);
            assert_eq!(scroll.offset(), manual_offset);
            let gap = point(button.right() + px(1.0), button.center().y);
            cx.simulate_mouse_move(gap, None, Default::default());
            cx.run_until_parked();
            assert!(cx.debug_bounds("panel-placement-0").is_some());
        }

        // Moving down into the content puts them away.
        cx.simulate_mouse_move(body.center(), None, Default::default());
        cx.run_until_parked();
        assert_eq!(scroll.bounds().size.width, idle_width);
        assert_eq!(scroll.offset(), manual_offset);
        assert!(cx.debug_bounds("panel-placement-0").is_none());
        // Focus left behind by a click doesn't keep them up.
        shell.update_in(cx, |s, window, cx| {
            let focus = s.workspace_panels.controls["panel-header-0"].clone();
            window.focus(&focus, cx);
        });
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-placement-0").is_none());
        assert_eq!(scroll.offset(), manual_offset);
        // Reaching them from the keyboard does.
        cx.simulate_keystrokes("tab");
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-placement-0").is_some());
        shell.update_in(cx, |_, window, _| {
            window.blur();
        });
        cx.simulate_resize(gpui::size(px(980.0), px(700.0)));
        cx.run_until_parked();
        assert_eq!(
            cx.debug_bounds("panel-tab-0-0").unwrap().size.width,
            px(112.0)
        );
        assert_eq!(
            cx.debug_bounds("panel-tab-0-1").unwrap().size.width,
            px(112.0)
        );
    }

    #[gpui::test]
    fn panel_workspace_reveals_selected_tabs_without_pinning_manual_scroll(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
            panel.tabs = (1..=8).map(PanelTab::Terminal).collect();
            panel.active = 7;
            cx.notify();
        });
        cx.run_until_parked();
        let scroll = shell.read_with(cx, |s, _| {
            s.workspace_panels.scrolls[&(String::new(), 0)].clone()
        });
        let last = cx.debug_bounds("panel-tab-0-7").unwrap();
        assert!(last.size.width >= px(112.0));
        assert!(last.size.width <= px(160.0));
        assert!(last.left() >= scroll.bounds().left());
        assert!(last.right() <= scroll.bounds().right());

        scroll.set_offset(point(px(0.0), px(0.0)));
        cx.update(|window, _| window.refresh());
        cx.run_until_parked();
        assert_eq!(scroll.offset().x, px(0.0));
        assert!(cx.debug_bounds("panel-tab-0-7").unwrap().right() > scroll.bounds().right());

        shell.update_in(cx, |s, window, cx| {
            s.focus_workspace_tab(0, PanelTab::Terminal(1), window, cx);
        });
        cx.run_until_parked();
        let first = cx.debug_bounds("panel-tab-0-0").unwrap();
        assert!(first.left() >= scroll.bounds().left());
        assert!(first.right() <= scroll.bounds().right());
    }

    #[gpui::test]
    fn panel_workspace_tool_shortcuts_hide_and_restore_the_same_instances(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, window, cx| {
            let state = s.state.clone();
            let terminal = cx.new(|cx| TerminalPanel::new_embedded(state, cx));
            s.workspace_panels.terminals.insert(77, terminal.clone());
            let mut layout = WorkspaceLayout::default();
            layout.last_selected = Some(None);
            layout.insert(0, PanelTab::Terminal(77));
            s.workspace_panels.layouts.insert(String::new(), layout);
            s.toggle_terminal(window, cx);
            assert!(
                s.panel_layout(cx)
                    .unwrap()
                    .location(&PanelTab::Terminal(77))
                    .is_none()
            );
            assert_eq!(s.workspace_panels.terminals[&77], terminal);
            s.toggle_terminal(window, cx);
            assert_eq!(
                s.panel_layout(cx)
                    .unwrap()
                    .location(&PanelTab::Terminal(77)),
                Some((0, 0))
            );
            assert_eq!(s.workspace_panels.terminals[&77], terminal);

            s.toggle_files_panel(window, cx);
            let layout = s.panel_layout(cx).unwrap();
            let panel = layout.focused;
            let tab = layout.panel(panel).unwrap().selected().unwrap().clone();
            let PanelTab::FileTree(id) = tab else {
                panic!("shortcut must open a workspace file tree")
            };
            let files = s.workspace_panels.explorers[&id].0.clone();
            s.toggle_files_panel(window, cx);
            assert!(s.panel_layout(cx).unwrap().location(&tab).is_none());
            assert_eq!(s.workspace_panels.explorers[&id].0, files);
            s.toggle_files_panel(window, cx);
            assert_eq!(s.panel_layout(cx).unwrap().location(&tab), Some((panel, 0)));
            assert_eq!(s.workspace_panels.explorers[&id].0, files);
        });
    }

    #[gpui::test]
    fn panel_workspace_equal_body_edges_and_context_destinations(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        let a = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let b = cx.debug_bounds("workspace-panel-body-1").unwrap();
        assert_eq!(a.top(), b.top());
        assert_eq!(a.bottom(), b.bottom());
        assert_eq!(f32::from(a.top()), PANEL_HEADER_HEIGHT);
        let tab = cx.debug_bounds("panel-tab-0-0").unwrap();
        cx.simulate_mouse_down(tab.center(), MouseButton::Right, Default::default());
        shell.read_with(cx, |s, _| {
            let menu = s.workspace_panels.menu.as_ref().unwrap();
            assert_eq!(menu.rows[0].0, "Move to right panel");
            assert!(!menu.rows.iter().any(|r| r.0 == "Move to left panel"));
        });
        shell.update_in(cx, |s, w, cx| s.activate_panel_menu(0, w, cx));
        shell.read_with(cx, |s, cx| {
            let l = s.panel_layout(cx).unwrap();
            assert!(l.panels[0].tabs.is_empty());
            assert_eq!(
                l.panels[1].tabs,
                vec![PanelTab::Terminal(2), PanelTab::Terminal(1)]
            );
        });
    }

    #[gpui::test]
    fn panel_workspace_close_button_removes_an_empty_panel_and_keeps_the_last(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            s.panel_layout_mut(cx).panel_mut(1).unwrap().tabs.clear();
            cx.notify();
        });
        cx.run_until_parked();
        let body = cx.debug_bounds("workspace-panel-body-1").unwrap();
        let header = cx.debug_bounds("workspace-panel-header-1").unwrap();
        cx.simulate_mouse_move(header.center(), None, Default::default());
        let close = cx.debug_bounds("panel-close-1").unwrap();
        cx.simulate_mouse_move(close.center(), None, Default::default());
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-close-1").is_some());
        cx.simulate_click(close.center(), Default::default());
        cx.run_until_parked();
        shell.update_in(cx, |s, window, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 1);
            assert_eq!(layout.focused, 0);
            assert_eq!(layout.panels[0].tabs, vec![PanelTab::Terminal(1)]);
            assert_eq!(layout.panels[0].share, 1.0);
            s.close_workspace_panel(0, window, cx);
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 1);
        });
        cx.update(|window, cx| window.draw(cx).clear());
        assert!(cx.debug_bounds("panel-close-0").is_none());
    }

    #[gpui::test]
    fn panel_workspace_placement_menu_moves_whole_panels_and_omits_missing_neighbors(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
            panel.tabs.push(PanelTab::Terminal(3));
            panel.active = 1;
            cx.notify();
        });
        cx.run_until_parked();
        assert!(cx.debug_bounds("workspace-add-panel").is_none());
        let header = cx.debug_bounds("workspace-panel-header-0").unwrap();
        cx.simulate_mouse_move(header.center(), None, Default::default());
        cx.run_until_parked();
        let placement = cx.debug_bounds("panel-placement-0").unwrap();
        cx.simulate_mouse_down(placement.center(), MouseButton::Left, Default::default());
        shell.read_with(cx, |s, cx| {
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 2);
            let menu = s.workspace_panels.menu.as_ref().unwrap();
            assert_eq!(menu.position, placement.bottom_left());
            assert_eq!(
                menu.rows.iter().map(|r| &*r.0).collect::<Vec<_>>(),
                ["Move right", "Add panel right", "Add panel below"]
            );
        });
        cx.simulate_keystrokes("enter");
        shell.read_with(cx, |s, cx| {
            let l = s.panel_layout(cx).unwrap();
            assert_eq!(l.panels.iter().map(|p| p.id).collect::<Vec<_>>(), [1, 0]);
            assert_eq!(
                l.panel(0).unwrap().tabs,
                [PanelTab::Terminal(1), PanelTab::Terminal(3)]
            );
            assert_eq!(l.panel(0).unwrap().active, 1);
            assert_eq!(l.panel(1).unwrap().tabs, [PanelTab::Terminal(2)]);
        });
        // The command returns focus to the same placement button.
        cx.simulate_keystrokes("space");
        shell.read_with(cx, |s, _| {
            let menu = s.workspace_panels.menu.as_ref().unwrap();
            assert_eq!(
                menu.rows.iter().map(|r| &*r.0).collect::<Vec<_>>(),
                ["Move left", "Add panel right", "Add panel below"]
            );
        });
        cx.simulate_keystrokes("enter");
        shell.read_with(cx, |s, cx| {
            assert_eq!(s.panel_layout(cx).unwrap().panels[0].id, 0);
        });
    }

    #[gpui::test]
    fn panel_workspace_placement_adds_an_empty_panel_beside_its_source(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, window, cx| {
            // Selection and expansion must not redirect where the new panel appears.
            s.panel_layout_mut(cx).expanded = Some(0);
            s.panel_layout_mut(cx).focused = 1;
            let focus = s.workspace_panels.controls["panel-placement-0"].clone();
            window.focus(&focus, cx);
        });
        cx.simulate_keystrokes("enter");
        cx.simulate_keystrokes("down");
        cx.simulate_keystrokes("enter");
        shell.read_with(cx, |s, cx| {
            let l = s.panel_layout(cx).unwrap();
            assert_eq!(l.panels.iter().map(|p| p.id).collect::<Vec<_>>(), [0, 2, 1]);
            assert_eq!(l.focused, 2);
            assert_eq!(l.expanded, None);
            assert!(l.panel(2).unwrap().tabs.is_empty());
            assert_eq!(l.panel(0).unwrap().tabs, [PanelTab::Terminal(1)]);
            assert_eq!(l.panel(1).unwrap().tabs, [PanelTab::Terminal(2)]);
            assert!(
                l.panels
                    .iter()
                    .all(|p| (p.share - 1.0 / 3.0).abs() < f32::EPSILON)
            );
            assert!(s.workspace_panels.menu.is_none());
            assert!(s.workspace_panels.target.is_none());
        });
        shell.update_in(cx, |s, window, cx| {
            s.close_workspace_panel(2, window, cx);
            s.close_workspace_panel(1, window, cx);
            s.open_panel_menu(0, None, point(px(300.0), px(38.0)), true, window, cx);
            let menu = s.workspace_panels.menu.as_ref().unwrap();
            assert_eq!(
                menu.rows.iter().map(|r| &*r.0).collect::<Vec<_>>(),
                ["Add panel right", "Add panel below"]
            );
        });
        cx.simulate_keystrokes("escape");
        shell.read_with(cx, |s, cx| {
            assert!(s.workspace_panels.menu.is_none());
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 1);
        });
    }

    #[gpui::test]
    fn panel_workspace_header_controls_work_from_the_keyboard(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, window, cx| {
            let focus = s.workspace_panels.controls["panel-add-tab-1"].clone();
            window.focus(&focus, cx);
        });
        cx.simulate_keystrokes("enter");
        shell.read_with(cx, |s, cx| {
            assert!(s.workspace_panels.menu.is_none());
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.focused, 1);
            assert!(matches!(
                layout.panel(1).unwrap().selected(),
                Some(PanelTab::New(_))
            ));
        });
        assert!(cx.debug_bounds("panel-empty-1-0").is_some());
        // The first choice is keyboard-focused. Starting a chat replaces the
        // blank tab in place, without another intermediate menu or tab.
        cx.simulate_keystrokes("enter");
        shell.read_with(cx, |s, cx| {
            let panel = s.panel_layout(cx).unwrap().panel(1).unwrap();
            assert_eq!(panel.tabs.len(), 2);
            assert!(matches!(panel.selected(), Some(PanelTab::Draft(_))));
            assert!(!panel.tabs.iter().any(|tab| matches!(tab, PanelTab::New(_))));
        });
        shell.update_in(cx, |s, window, cx| {
            let layout = s.panel_layout_mut(cx);
            layout.insert(1, PanelTab::Terminal(3));
            layout.focused = 0;
            let focus = s.workspace_panels.controls["panel-close-1"].clone();
            window.focus(&focus, cx);
        });
        cx.simulate_keystrokes("space");
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 1);
            assert_eq!(layout.panels[0].tabs, vec![PanelTab::Terminal(1)]);
            assert_eq!(layout.focused, 0);
        });
    }
    #[gpui::test]
    fn panel_workspace_keeps_unsent_input_when_splitting_and_transferring(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, window, cx| {
            s.workspace_new_chat(cx);
            let layout = s.panel_layout(cx).unwrap();
            let original_panel = layout.focused;
            let draft = layout
                .panel(original_panel)
                .unwrap()
                .selected()
                .unwrap()
                .clone();
            s.composer.update(cx, |c, cx| {
                c.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Keep this unfinished thought".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            s.workspace_split(SplitAxis::Horizontal, cx);
            assert!(s.composer.read(cx).canvas_input(cx).text.is_empty());
            s.focus_workspace_tab(original_panel, draft.clone(), window, cx);
            assert_eq!(
                s.composer.read(cx).canvas_input(cx).text,
                "Keep this unfinished thought"
            );
            let neighbor = s
                .panel_layout(cx)
                .unwrap()
                .neighbor(original_panel, true)
                .unwrap();
            s.move_workspace_tab(original_panel, draft, neighbor, None, window, cx);
            assert_eq!(
                s.composer.read(cx).canvas_input(cx).text,
                "Keep this unfinished thought"
            );
        });
    }

    #[gpui::test]
    fn panel_workspace_expanded_restore_stays_visible_away_from_the_panel(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1200.0), px(900.0)));
        cx.run_until_parked();
        let left = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let right = cx.debug_bounds("workspace-panel-body-1").unwrap();
        let header = cx.debug_bounds("workspace-panel-header-1").unwrap();
        cx.simulate_mouse_move(header.center(), None, Default::default());
        cx.run_until_parked();
        let expand = cx.debug_bounds("panel-expand-1").unwrap();
        cx.simulate_mouse_move(expand.center(), None, Default::default());
        cx.simulate_mouse_down(expand.center(), MouseButton::Left, Default::default());
        let release = expand.center() + point(px(1.0), px(0.0));
        cx.simulate_mouse_move(release, Some(MouseButton::Left), Default::default());
        cx.simulate_mouse_up(release, MouseButton::Left, Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            assert_eq!(s.panel_layout(cx).unwrap().expanded, Some(1));
        });
        assert!(cx.debug_bounds("workspace-panel-body-0").is_none());

        shell.update_in(cx, |_, window, _| window.blur());
        cx.simulate_mouse_move(point(px(10.0), px(100.0)), None, Default::default());
        cx.run_until_parked();
        let restore = cx.debug_bounds("panel-expand-1").unwrap();
        // Debug bounds include hidden elements. Click without a preceding
        // hover reveal to prove that Restore remains available on its own.
        cx.simulate_click(restore.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.expanded, None);
            assert_eq!(layout.panels[0].tabs, [PanelTab::Terminal(1)]);
            assert_eq!(layout.panels[1].tabs, [PanelTab::Terminal(2)]);
        });
        assert_eq!(cx.debug_bounds("workspace-panel-body-0").unwrap(), left);
        assert_eq!(cx.debug_bounds("workspace-panel-body-1").unwrap(), right);

        cx.simulate_mouse_move(point(px(10.0), px(100.0)), None, Default::default());
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-expand-1").is_none());
    }

    #[gpui::test]
    fn panel_workspace_hidden_controls_do_not_block_tabs_while_expanded(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1200.0), px(900.0)));
        shell.update_in(cx, |s, _, cx| {
            let layout = s.panel_layout_mut(cx);
            let panel = layout.panel_mut(1).unwrap();
            panel.tabs = (2..12).map(PanelTab::Terminal).collect();
            panel.active = 0;
            layout.expanded = Some(1);
            cx.notify();
        });
        cx.simulate_mouse_move(point(px(10.0), px(100.0)), None, Default::default());
        cx.run_until_parked();
        let controls = cx.debug_bounds("panel-controls-1").unwrap();
        let position = point(controls.left() + px(12.0), controls.center().y);
        let target = [
            "panel-tab-1-0",
            "panel-tab-1-1",
            "panel-tab-1-2",
            "panel-tab-1-3",
            "panel-tab-1-4",
            "panel-tab-1-5",
            "panel-tab-1-6",
            "panel-tab-1-7",
            "panel-tab-1-8",
            "panel-tab-1-9",
        ]
        .into_iter()
        .position(|selector| {
            cx.debug_bounds(selector)
                .is_some_and(|bounds| bounds.contains(&position))
        })
        .expect("a tab should occupy the hidden placement button's space");
        assert_ne!(target, 0);
        cx.simulate_mouse_down(position, MouseButton::Left, Default::default());
        cx.simulate_mouse_up(position, MouseButton::Left, Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.panel(1).unwrap().active, target);
            assert_eq!(layout.expanded, Some(1));
        });
    }

    #[gpui::test]
    fn panel_workspace_drag_to_body_and_expand_restore_preserve_tabs(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        let start = cx.debug_bounds("panel-tab-0-0").unwrap().center();
        let end = cx.debug_bounds("workspace-panel-body-1").unwrap().center();
        cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
        cx.simulate_mouse_move(
            start + point(px(12.0), px(4.0)),
            Some(MouseButton::Left),
            Default::default(),
        );
        cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
        cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
        shell.update_in(cx, |s, _, cx| {
            let l = s.panel_layout(cx).unwrap();
            assert_eq!(l.location(&PanelTab::Terminal(1)), Some((1, 1)));
            s.workspace_zoom(cx);
        });
        cx.update(|w, cx| w.draw(cx).clear());
        assert!(cx.debug_bounds("workspace-panel-body-0").is_none());
        shell.update_in(cx, |s, window, cx| {
            assert!(s.dismiss_workspace_panel_overlay(window, cx));
            assert_eq!(
                s.panel_layout(cx).unwrap().location(&PanelTab::Terminal(1)),
                Some((1, 1))
            );
        });
        cx.update(|w, cx| w.draw(cx).clear());
        assert!(cx.debug_bounds("workspace-panel-body-0").is_some());
    }

    fn drag_tab_to_edge(cx: &mut TestAppContext, edge: PanelEdge) {
        let (shell, cx) = setup(cx);
        if edge.axis() == SplitAxis::Vertical {
            cx.simulate_resize(gpui::size(px(1200.0), px(1200.0)));
        }
        shell.update_in(cx, |s, _, cx| {
            s.panel_layout_mut(cx).insert(0, PanelTab::Terminal(3));
            s.panel_layout_mut(cx).panel_mut(0).unwrap().active = 0;
            cx.notify();
        });
        cx.run_until_parked();
        let start = cx.debug_bounds("panel-tab-0-0").unwrap().center();
        let body = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let end = match edge {
            PanelEdge::Left => point(body.left() + px(4.0), body.center().y),
            PanelEdge::Right => point(body.right() - px(4.0), body.center().y),
            PanelEdge::Top => point(body.center().x, body.top() + px(4.0)),
            PanelEdge::Bottom => point(body.center().x, body.bottom() - px(4.0)),
        };
        cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
        cx.simulate_mouse_move(
            start + point(px(12.0), px(4.0)),
            Some(MouseButton::Left),
            Default::default(),
        );
        cx.run_until_parked();
        cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 2)
        });
        cx.run_until_parked();
        let retained = cx.debug_bounds("workspace-panel-0").unwrap();
        let ghost = cx
            .debug_bounds(match edge {
                PanelEdge::Left => "panel-split-ghost-0-left",
                PanelEdge::Right => "panel-split-ghost-0-right",
                PanelEdge::Top => "panel-split-ghost-0-top",
                PanelEdge::Bottom => "panel-split-ghost-0-bottom",
            })
            .unwrap();
        if edge.axis() == SplitAxis::Horizontal {
            assert!((f32::from(retained.size.width - ghost.size.width)).abs() < 1.0);
            assert!(retained.size.width < body.size.width);
            let gap = if edge.after() {
                ghost.left() - retained.right()
            } else {
                retained.left() - ghost.right()
            };
            assert!((f32::from(gap) - GUTTER).abs() < 1.0);
        } else {
            assert!((f32::from(retained.size.height - ghost.size.height)).abs() < 1.0);
            assert!(retained.size.height < body.size.height);
            let gap = if edge.after() {
                ghost.top() - retained.bottom()
            } else {
                retained.top() - ghost.bottom()
            };
            assert!((f32::from(gap) - STACKED_CLEARANCE).abs() < 1.0);
        }
        shell.read_with(cx, |s, cx| {
            assert_eq!(
                s.panel_layout(cx).unwrap().panel(0).unwrap().selected(),
                Some(&PanelTab::Terminal(1))
            );
        });
        assert!(cx.debug_bounds("panel-tab-0-1").is_none());
        cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
        cx.run_until_parked();
        let committed = cx.debug_bounds("workspace-panel-2").unwrap();
        assert_eq!(
            committed, ghost,
            "the drop must commit exactly the previewed frame"
        );
        if edge.axis() == SplitAxis::Vertical {
            let mut surfaces = [
                cx.debug_bounds("workspace-panel-body-0").unwrap(),
                cx.debug_bounds("workspace-panel-body-1").unwrap(),
                cx.debug_bounds("workspace-panel-body-2").unwrap(),
            ];
            surfaces.sort_by(|a, b| a.top().partial_cmp(&b.top()).unwrap());
            for pair in surfaces.windows(2) {
                assert!(
                    (f32::from(pair[1].top() - pair[0].bottom())
                        - (STACKED_CLEARANCE + STACKED_HEADER_HEIGHT))
                        .abs()
                        < 1.0,
                    "visible surfaces: {surfaces:?}"
                );
            }
            assert!(surfaces.last().unwrap().bottom() <= px(1192.0));
        }
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(
                layout.panels.iter().map(|p| p.id).collect::<Vec<_>>(),
                if edge.after() {
                    vec![0, 2, 1]
                } else {
                    vec![2, 0, 1]
                }
            );
            assert_eq!(layout.location(&PanelTab::Terminal(1)), Some((2, 0)));
            assert_eq!(layout.panel(0).unwrap().tabs, vec![PanelTab::Terminal(3)]);
            assert_eq!(layout.focused, 2);
            assert_eq!(layout.axis, edge.axis());
        });
    }

    #[gpui::test]
    fn panel_workspace_split_preview_keeps_the_remaining_browser_visible(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            let tab = |id| PanelTab::Surface {
                owner: String::new(),
                surface: RightSurface::Browser(id),
            };
            let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
            panel.tabs = vec![tab(41), tab(42)];
            panel.active = 0;
            s.workspace_panels.split_drag = Some(PanelTabDrag {
                workspace: String::new(),
                panel: 0,
                tab: tab(41),
                title: "Browser".into(),
            });
            s.update_panel_split_preview(Some((0, PanelEdge::Right)), cx);
            assert_eq!(s.visible_workspace_browsers(cx), HashSet::from([42]));
            s.update_panel_split_preview(None, cx);
            assert_eq!(s.visible_workspace_browsers(cx), HashSet::from([41]));
        });
    }

    #[gpui::test]
    fn panel_workspace_split_preview_keeps_the_remaining_chat_watched(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            s.state
                .update(cx, |state, _| state.selected_chat = Some("first".into()));
            let layout = s.panel_layout_mut(cx);
            layout.last_selected = Some(Some("first".into()));
            let source = layout.panel_mut(0).unwrap();
            source.tabs = vec![
                PanelTab::Chat("first".into()),
                PanelTab::Chat("second".into()),
            ];
            source.active = 0;
            let transcript =
                cx.new(|cx| Transcript::for_peer_chat(s.state.clone(), "second".into(), cx));
            let events = cx.subscribe(&transcript, Shell::on_transcript_event);
            s.workspace_panels
                .peers
                .insert("second".into(), (transcript.clone(), events));
            s.workspace_panels.split_drag = Some(PanelTabDrag {
                workspace: String::new(),
                panel: 0,
                tab: PanelTab::Chat("first".into()),
                title: "First".into(),
            });
            s.update_panel_split_preview(Some((0, PanelEdge::Right)), cx);
            s.sync_panel_workspace(cx);
            assert_eq!(s.workspace_panels.peers["second"].0, transcript);
            assert_eq!(
                s.panel_layout(cx).unwrap().panel(0).unwrap().selected(),
                Some(&PanelTab::Chat("first".into()))
            );
            s.update_panel_split_preview(None, cx);
            s.sync_panel_workspace(cx);
            assert!(!s.workspace_panels.peers.contains_key("second"));
        });
    }

    fn cancel_split_preview(cx: &mut TestAppContext, target: PanelEdge) {
        let (shell, cx) = setup(cx);
        if target.axis() == SplitAxis::Vertical {
            cx.simulate_resize(gpui::size(px(1200.0), px(1200.0)));
        }
        shell.update_in(cx, |s, _, cx| {
            s.panel_layout_mut(cx).insert(0, PanelTab::Terminal(3));
            s.panel_layout_mut(cx).panel_mut(0).unwrap().active = 0;
            cx.notify();
        });
        cx.run_until_parked();
        let start = cx.debug_bounds("panel-tab-0-0").unwrap().center();
        let before = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let edge = if target == PanelEdge::Right {
            point(before.right() - px(4.0), before.center().y)
        } else {
            point(before.center().x, before.bottom() - px(4.0))
        };
        cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
        cx.simulate_mouse_move(
            start + point(px(12.0), px(4.0)),
            Some(MouseButton::Left),
            Default::default(),
        );
        cx.simulate_mouse_move(edge, Some(MouseButton::Left), Default::default());
        cx.run_until_parked();
        let preview = cx.debug_bounds("workspace-panel-body-0").unwrap();
        if target == PanelEdge::Right {
            assert!(preview.size.width < before.size.width);
        } else {
            assert!(preview.size.height < before.size.height);
        }
        shell.read_with(cx, |s, cx| {
            assert_eq!(s.panel_layout(cx).unwrap().axis, SplitAxis::Horizontal)
        });
        // Back over the retained content: the slot closes while the drag continues.
        let center = point(before.left() + before.size.width * 0.35, before.center().y);
        cx.simulate_mouse_move(center, Some(MouseButton::Left), Default::default());
        cx.run_until_parked();
        assert_eq!(cx.debug_bounds("workspace-panel-body-0").unwrap(), before);
        cx.simulate_mouse_up(
            point(px(5.0), px(5.0)),
            MouseButton::Left,
            Default::default(),
        );
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(
                layout.panel(0).unwrap().tabs,
                [PanelTab::Terminal(1), PanelTab::Terminal(3)]
            );
            assert!(s.workspace_panels.split_previews.is_empty());
        });
    }

    #[gpui::test]
    fn panel_workspace_ghost_preview_cancels_without_changing_tabs(cx: &mut TestAppContext) {
        cancel_split_preview(cx, PanelEdge::Right);
    }

    #[gpui::test]
    fn panel_workspace_stacked_preview_cancels_without_changing_axis_or_tabs(
        cx: &mut TestAppContext,
    ) {
        cancel_split_preview(cx, PanelEdge::Bottom);
    }

    #[gpui::test]
    fn panel_workspace_drag_to_right_edge_creates_a_panel(cx: &mut TestAppContext) {
        drag_tab_to_edge(cx, PanelEdge::Right);
    }

    #[gpui::test]
    fn panel_workspace_drag_to_left_edge_creates_a_panel(cx: &mut TestAppContext) {
        drag_tab_to_edge(cx, PanelEdge::Left);
    }

    #[gpui::test]
    fn panel_workspace_drag_to_top_edge_creates_a_stacked_panel(cx: &mut TestAppContext) {
        drag_tab_to_edge(cx, PanelEdge::Top);
    }

    #[gpui::test]
    fn panel_workspace_drag_to_bottom_edge_creates_a_stacked_panel(cx: &mut TestAppContext) {
        drag_tab_to_edge(cx, PanelEdge::Bottom);
    }

    fn drag_across_seam(cx: &mut TestAppContext, axis: SplitAxis) {
        let (shell, cx) = setup(cx);
        if axis == SplitAxis::Vertical {
            cx.simulate_resize(gpui::size(px(1200.0), px(1200.0)));
        }
        shell.update_in(cx, |s, _, cx| {
            s.panel_layout_mut(cx).axis = axis;
            let panel = s.panel_layout_mut(cx).panel_mut(0).unwrap();
            panel.tabs.push(PanelTab::Terminal(3));
            cx.notify();
        });
        cx.run_until_parked();
        let start = cx.debug_bounds("panel-tab-0-0").unwrap().center();
        let left = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let right = cx.debug_bounds("workspace-panel-body-1").unwrap();
        let seam = if axis == SplitAxis::Horizontal {
            point((left.right() + right.left()) / 2.0, left.center().y)
        } else {
            // Panel bounds include the next row's header; the gutter is above it.
            let next = cx.debug_bounds("workspace-panel-1").unwrap();
            point(left.center().x, (left.bottom() + next.top()) / 2.0)
        };
        let edge = PanelEdge::along(axis, true);
        cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
        cx.simulate_mouse_move(
            start + point(px(12.0), px(4.0)),
            Some(MouseButton::Left),
            Default::default(),
        );
        cx.run_until_parked();
        let mut ghost_bounds = None;
        for delta in [0.0, -3.0, 3.0, -1.0, 1.0, 0.0] {
            cx.simulate_mouse_move(
                seam + if axis == SplitAxis::Horizontal {
                    point(px(delta), px(0.0))
                } else {
                    point(px(0.0), px(delta))
                },
                Some(MouseButton::Left),
                Default::default(),
            );
            cx.run_until_parked();
            shell.read_with(cx, |s, cx| {
                let active: Vec<_> = s
                    .workspace_panels
                    .split_previews
                    .iter()
                    .filter(|(_, preview)| preview.active)
                    .map(|((_, panel, right), _)| (*panel, *right))
                    .collect();
                assert_eq!(active, vec![(0, edge)]);
                assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 2);
                assert_eq!(
                    s.workspace_panels.split_drag_bounds[&0].right(),
                    left.right()
                );
                assert_eq!(
                    s.workspace_panels.split_drag_bounds[&1].left(),
                    right.left()
                );
            });
            let ghost = cx
                .debug_bounds(match edge {
                    PanelEdge::Left => "panel-split-ghost-0-left",
                    PanelEdge::Right => "panel-split-ghost-0-right",
                    PanelEdge::Top => "panel-split-ghost-0-top",
                    PanelEdge::Bottom => "panel-split-ghost-0-bottom",
                })
                .unwrap();
            if let Some(previous) = ghost_bounds {
                assert_eq!(ghost, previous);
            }
            ghost_bounds = Some(ghost);
        }
        cx.simulate_mouse_up(seam, MouseButton::Left, Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(
                layout
                    .panels
                    .iter()
                    .map(|panel| panel.id)
                    .collect::<Vec<_>>(),
                vec![0, 2, 1]
            );
            assert_eq!(layout.location(&PanelTab::Terminal(1)), Some((2, 0)));
        });
    }

    #[gpui::test]
    fn panel_workspace_dragging_across_a_seam_keeps_one_stable_insertion(cx: &mut TestAppContext) {
        drag_across_seam(cx, SplitAxis::Horizontal);
    }

    #[gpui::test]
    fn panel_workspace_dragging_across_a_stacked_seam_keeps_one_stable_insertion(
        cx: &mut TestAppContext,
    ) {
        drag_across_seam(cx, SplitAxis::Vertical);
    }

    #[gpui::test]
    fn panel_workspace_inactive_composer_keeps_geometry_and_its_draft(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1200.0), px(900.0)));
        let tabs = shell.update_in(cx, |s, _, cx| {
            s.state.update(cx, |state, _| state.no_project = true);
            let mut tabs = Vec::new();
            for panel in [0, 1] {
                s.workspace_panels.target = Some(panel);
                s.workspace_new_chat(cx);
                tabs.push(
                    s.panel_layout(cx)
                        .unwrap()
                        .panel(panel)
                        .unwrap()
                        .selected()
                        .unwrap()
                        .clone(),
                );
            }
            tabs
        });
        cx.run_until_parked();
        let attachment = crate::attachments::StagedAttachment {
            #[cfg(target_os = "macos")]
            editable: None,
            #[cfg(target_os = "macos")]
            unavailable_editable: None,
            unavailable: None,
            annotations: None,
            id: "panel-composer-fixture".into(),
            name: "draft-notes.txt".into(),
            image: None,
            file: Some(std::sync::Arc::from(&b"Synthetic attachment"[..])),
        };
        for width in [1200.0, 980.0] {
            cx.simulate_resize(gpui::size(px(width), px(900.0)));
            for input in [
                crate::pickers::CanvasInput::default(),
                crate::pickers::CanvasInput {
                    text: "A draft that belongs to the left panel".into(),
                    stage: Vec::new(),
                },
                crate::pickers::CanvasInput {
                    text: "First line\nSecond line\nThird line".into(),
                    stage: vec![attachment.clone()],
                },
                crate::pickers::CanvasInput {
                    text: "A long draft wraps naturally and retains its complete writing surface. "
                        .repeat(12),
                    stage: Vec::new(),
                },
            ] {
                shell.update_in(cx, |s, window, cx| {
                    s.focus_workspace_tab(0, tabs[0].clone(), window, cx);
                    s.composer.update(cx, |composer, cx| {
                        composer.set_canvas_input(input.clone(), cx)
                    });
                });
                cx.run_until_parked();
                let active = shell.read_with(cx, |s, cx| {
                    s.composer.read(cx).surface_bounds().get().unwrap()
                });
                shell.update_in(cx, |s, window, cx| {
                    s.focus_workspace_tab(1, tabs[1].clone(), window, cx);
                });
                cx.run_until_parked();
                let parked = shell.read_with(cx, |s, cx| {
                    s.workspace_panels.inactive_composers[&tabs[0]]
                        .read(cx)
                        .surface_bounds()
                        .unwrap()
                });
                assert_eq!(
                    parked, active,
                    "parking a draft must preserve its full geometry at width {width}"
                );
                let activate = cx.debug_bounds("inactive-composer-activate-0").unwrap();
                // Even a click in the send-control corner only activates this
                // panel. It cannot submit through the other panel's composer.
                cx.simulate_click(
                    gpui::point(parked.right() - px(20.0), parked.bottom() - px(22.0)),
                    Default::default(),
                );
                cx.run_until_parked();
                shell.read_with(cx, |s, cx| {
                    assert!(activate.contains(&parked.center()));
                    assert_eq!(s.panel_layout(cx).unwrap().focused, 0);
                    assert_eq!(s.composer.read(cx).canvas_input(cx), input);
                    assert_eq!(s.composer.read(cx).surface_bounds().get().unwrap(), parked);
                    assert!(s.state.read(cx).selected_chat.is_none());
                });
            }
        }
    }

    #[gpui::test]
    fn panel_workspace_inactive_composer_reactivates_at_its_resized_geometry(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1200.0), px(900.0)));
        let input = crate::pickers::CanvasInput {
            text: "This parked draft should wrap with its own panel width, then keep that exact shape when activated. ".repeat(4),
            stage: Vec::new(),
        };
        let tabs = shell.update_in(cx, |s, _, cx| {
            s.state.update(cx, |state, _| state.no_project = true);
            let mut tabs = Vec::new();
            for panel in [0, 1] {
                s.workspace_panels.target = Some(panel);
                s.workspace_new_chat(cx);
                tabs.push(
                    s.panel_layout(cx)
                        .unwrap()
                        .panel(panel)
                        .unwrap()
                        .selected()
                        .unwrap()
                        .clone(),
                );
                if panel == 0 {
                    s.composer.update(cx, |composer, cx| {
                        composer.set_canvas_input(input.clone(), cx)
                    });
                }
            }
            tabs
        });
        cx.run_until_parked();
        for width in [1100.0, 900.0, 1300.0] {
            cx.simulate_resize(gpui::size(px(width), px(900.0)));
            cx.run_until_parked();
            let parked = shell.read_with(cx, |s, cx| {
                s.workspace_panels.inactive_composers[&tabs[0]]
                    .read(cx)
                    .surface_bounds()
                    .unwrap()
            });
            cx.simulate_click(parked.center(), Default::default());
            cx.run_until_parked();
            shell.read_with(cx, |s, cx| {
                assert_eq!(s.composer.read(cx).canvas_input(cx), input);
                assert_eq!(s.composer.read(cx).surface_bounds().get().unwrap(), parked,
                    "activating a panel resized while inactive must retain its measured geometry at width {width}");
            });
            shell.update_in(cx, |s, window, cx| {
                s.focus_workspace_tab(1, tabs[1].clone(), window, cx)
            });
            cx.run_until_parked();
        }
    }

    #[gpui::test]
    fn panel_workspace_new_conversation_input_stays_inside_stacked_panels(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        for height in [900.0, 700.0, 1100.0] {
            cx.simulate_resize(gpui::size(px(980.0), px(height)));
            for panel in [1, 0] {
                shell.update_in(cx, |s, _, cx| {
                    s.state.update(cx, |state, _| state.no_project = true);
                    let layout = s.panel_layout_mut(cx);
                    layout.axis = SplitAxis::Vertical;
                    layout.expanded = None;
                    layout.focused = panel;
                    s.workspace_new_chat(cx);
                });
                cx.run_until_parked();
                for expanded in [false, true] {
                    if expanded {
                        shell.update_in(cx, |s, _, cx| {
                            s.panel_layout_mut(cx).expanded = Some(panel);
                            cx.notify();
                        });
                        cx.run_until_parked();
                    }
                    let body = cx
                        .debug_bounds(if panel == 0 {
                            "workspace-panel-body-0"
                        } else {
                            "workspace-panel-body-1"
                        })
                        .unwrap();
                    let input = shell.read_with(cx, |s, cx| {
                        s.composer.read(cx).surface_bounds().get().unwrap()
                    });
                    assert!(
                        input.top() >= body.top() && input.bottom() <= body.bottom(),
                        "input must fit panel {panel} at height {height}, expanded={expanded}: {input:?} inside {body:?}"
                    );
                    assert!(input.left() >= body.left() && input.right() <= body.right());
                    assert_eq!(input.size.height, px(crate::composer::COMPACT_TOTAL_HEIGHT));
                    let footer = cx.debug_bounds("composer-footer").unwrap();
                    assert!(footer.bottom() <= body.bottom());
                    assert!(body.bottom() - footer.bottom() <= px(Theme::SPACE_LG + 2.0));
                    let suggestions = cx.debug_bounds("new-conversation-suggestions").unwrap();
                    assert!(suggestions.bottom() <= input.top());
                    assert!(cx.debug_bounds("new-thread-heading-group").is_none());
                }
            }
        }
    }

    #[gpui::test]
    fn panel_workspace_new_conversation_keeps_the_dock_when_suggestions_retire(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(980.0), px(700.0)));
        shell.update_in(cx, |s, _, cx| {
            s.state.update(cx, |state, _| state.no_project = true);
            let layout = s.panel_layout_mut(cx);
            layout.axis = SplitAxis::Vertical;
            layout.focused = 1;
            s.workspace_new_chat(cx);
        });
        cx.run_until_parked();
        assert!(cx.debug_bounds("draft-device-target").is_some());
        let original = shell.read_with(cx, |s, cx| {
            s.composer.read(cx).surface_bounds().get().unwrap()
        });
        let starter = cx.debug_bounds("starter-build").unwrap();
        cx.simulate_click(starter.center(), Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            assert_eq!(
                s.composer.read(cx).canvas_input(cx).text,
                crate::starters::available(false).next().unwrap().prompt
            );
        });
        assert!(cx.debug_bounds("new-conversation-suggestions").is_some());
        // Draft text can grow normally; sending clears it and promotes the
        // same panel to a conversation without moving its empty input.
        shell.update_in(cx, |s, _, cx| {
            s.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(Default::default(), cx)
            });
            s.state.update(cx, |state, cx| {
                // This transition represents a completed first send. A missing
                // registry row deliberately renders its recovery placeholder,
                // leaving the last composer measurement untouched.
                state.chats.push(serde_json::from_value(serde_json::json!({
                    "id": "first", "deviceId": "local", "archived": false,
                    "createdAt": "2026-09-01T00:00:00Z", "title": "Synthetic conversation"
                })).unwrap());
                state.select_chat(Some("first".into()), cx);
            });
        });
        cx.run_until_parked();
        assert!(cx.debug_bounds("new-conversation-suggestions").is_none());
        let started = shell.read_with(cx, |s, cx| {
            assert!(s.composer.read(cx).parked_chat_input("first", cx).text.is_empty());
            s.composer.read(cx).surface_bounds().get().unwrap()
        });
        assert_eq!(started, original);
        shell.update_in(cx, |s, _, cx| s.workspace_new_chat(cx));
        cx.run_until_parked();
        assert!(cx.debug_bounds("new-conversation-suggestions").is_some());
    }

    #[gpui::test]
    fn panel_workspace_stacked_headers_transfer_tabs_and_dividers_resize_rows(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            s.panel_layout_mut(cx).axis = SplitAxis::Vertical;
            cx.notify();
        });
        cx.run_until_parked();
        let upper = cx.debug_bounds("workspace-panel-0").unwrap();
        let lower = cx.debug_bounds("workspace-panel-1").unwrap();
        assert_eq!(upper.size.width, lower.size.width);
        assert!((f32::from(lower.top() - upper.bottom()) - STACKED_CLEARANCE).abs() < 0.5);
        let upper_tab = cx.debug_bounds("panel-tab-content-0-0").unwrap();
        let lower_tab = cx.debug_bounds("panel-tab-content-1-0").unwrap();
        let upper_connection = cx.debug_bounds("panel-tab-0-0").unwrap();
        let lower_connection = cx.debug_bounds("panel-tab-1-0").unwrap();
        let upper_body = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let lower_body = cx.debug_bounds("workspace-panel-body-1").unwrap();
        assert_eq!(upper_tab.top() - upper.top(), px(STACKED_CLEARANCE));
        assert_eq!(upper_body.top() - upper_tab.bottom(), px(STACKED_CLEARANCE));
        assert_eq!(lower_tab.top() - upper_body.bottom(), px(STACKED_CLEARANCE));
        assert_eq!(lower_body.top() - lower_tab.bottom(), px(STACKED_CLEARANCE));
        assert_eq!(upper_connection.bottom(), upper_body.top());
        assert_eq!(lower_connection.bottom(), lower_body.top());
        assert_eq!(
            upper_tab.center().y - upper.top(),
            px(21.0),
            "keep native traffic-light alignment"
        );
        let divider = cx.debug_bounds("workspace-divider-1").unwrap().center();
        cx.simulate_mouse_down(divider, MouseButton::Left, Default::default());
        cx.simulate_mouse_move(
            divider + point(px(0.0), px(35.0)),
            Some(MouseButton::Left),
            Default::default(),
        );
        cx.simulate_mouse_up(
            divider + point(px(0.0), px(35.0)),
            MouseButton::Left,
            Default::default(),
        );
        cx.run_until_parked();
        let resized = cx.debug_bounds("workspace-panel-0").unwrap();
        assert!((f32::from(resized.size.height - upper.size.height) - 35.0).abs() < 1.0);
        assert_eq!(resized.size.width, upper.size.width);
        let lower = cx.debug_bounds("workspace-panel-1").unwrap();
        assert!((f32::from(lower.top() - resized.bottom()) - STACKED_CLEARANCE).abs() < 0.5);
        let start = cx.debug_bounds("panel-tab-0-0").unwrap().center();
        let end = cx.debug_bounds("panel-tab-1-0").unwrap().center();
        cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
        cx.simulate_mouse_move(
            start + point(px(12.0), px(4.0)),
            Some(MouseButton::Left),
            Default::default(),
        );
        cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
        cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.axis, SplitAxis::Vertical);
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(layout.location(&PanelTab::Terminal(1)), Some((1, 0)));
        });
    }

    #[gpui::test]
    fn panel_workspace_height_limit_blocks_shortcut_menu_and_drag_without_losing_a_draft(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(980.0), px(700.0)));
        shell.update_in(cx, |s, window, cx| {
            s.panel_layout_mut(cx).axis = SplitAxis::Vertical;
            s.workspace_new_chat(cx);
            s.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Keep this draft at the height limit".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            let draft = s
                .panel_layout(cx)
                .unwrap()
                .panel(0)
                .unwrap()
                .selected()
                .unwrap()
                .clone();
            s.workspace_split(SplitAxis::Vertical, cx);
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 2);
            assert_eq!(
                s.composer.read(cx).canvas_input(cx).text,
                "Keep this draft at the height limit"
            );
            s.open_panel_menu(0, None, point(px(300.0), px(38.0)), true, window, cx);
            let index = s.workspace_panels.menu.as_ref().unwrap().rows.len() - 1;
            s.activate_panel_menu(index, window, cx);
            assert!(
                s.workspace_panels.menu.is_some(),
                "disabled menu action stays open"
            );
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 2);
            s.workspace_panels.menu = None;
            let drag = PanelTabDrag {
                workspace: String::new(),
                panel: 0,
                tab: draft,
                title: "Draft".into(),
            };
            s.split_workspace_tab(&drag, 0, PanelEdge::Bottom, window, cx);
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 2);
            assert_eq!(
                s.composer.read(cx).canvas_input(cx).text,
                "Keep this draft at the height limit"
            );
        });
        cx.run_until_parked();
        let upper = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let lower = cx.debug_bounds("workspace-panel-body-1").unwrap();
        let lower_tab = cx.debug_bounds("panel-tab-content-1-0").unwrap();
        let connected_tab = cx.debug_bounds("panel-tab-1-0").unwrap();
        let lower_header = cx.debug_bounds("workspace-panel-header-1").unwrap();
        assert!(
            (f32::from(lower_tab.top() - upper.bottom()) - STACKED_CLEARANCE).abs() < 0.5,
            "the tab content keeps five pixels above it"
        );
        assert!(
            (f32::from(lower.top() - lower_tab.bottom()) - STACKED_CLEARANCE).abs() < 0.5,
            "the content stays centered while the active surface extends to the panel"
        );
        assert_eq!(lower_tab.size.height, px(PANEL_TAB_HEIGHT));
        assert_eq!(connected_tab.bottom(), lower.top());
        assert_eq!(lower_header.bottom(), lower.top());
        assert!(lower.bottom() <= px(692.0));
        let before = shell.read_with(cx, |s, cx| {
            s.panel_layout(cx).unwrap().panel(0).unwrap().tabs.clone()
        });
        let start = cx.debug_bounds("panel-tab-0-0").unwrap().center();
        let end = point(upper.center().x, upper.bottom() - px(4.0));
        cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
        cx.simulate_mouse_move(
            start + point(px(12.0), px(4.0)),
            Some(MouseButton::Left),
            Default::default(),
        );
        cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
        cx.run_until_parked();
        assert!(cx.debug_bounds("panel-split-ghost-0-bottom").is_none());
        cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            assert_eq!(
                s.panel_layout(cx).unwrap().panel(0).unwrap().tabs,
                before,
                "a blocked split must not silently transfer or reorder the tab"
            )
        });
    }

    #[gpui::test]
    fn panel_workspace_shrinking_a_tall_window_keeps_overflow_tabs_and_focused_draft(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1200.0), px(1200.0)));
        shell.update_in(cx, |s, _, cx| {
            s.workspace_split(SplitAxis::Vertical, cx);
            s.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Keep this when the window gets shorter".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            let layout = s.panel_layout_mut(cx);
            // Put the focused draft in the final row, which must be folded in.
            layout.reorder_panel(layout.focused, true);
            assert_eq!(layout.panels.len(), 3);
            cx.notify();
        });
        cx.run_until_parked();
        cx.simulate_resize(gpui::size(px(980.0), px(700.0)));
        cx.run_until_parked();
        shell.read_with(cx, |s, cx| {
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.panels.len(), 2);
            assert_eq!(layout.focused, 1);
            assert!(matches!(
                layout.panel(1).unwrap().selected(),
                Some(PanelTab::Draft(_))
            ));
            assert_eq!(layout.location(&PanelTab::Terminal(1)), Some((0, 0)));
            assert_eq!(layout.location(&PanelTab::Terminal(2)), Some((1, 0)));
            assert_eq!(
                s.composer.read(cx).canvas_input(cx).text,
                "Keep this when the window gets shorter"
            );
        });
        let upper = cx.debug_bounds("workspace-panel-body-0").unwrap();
        let lower = cx.debug_bounds("workspace-panel-body-1").unwrap();
        assert!(
            (f32::from(lower.top() - upper.bottom()) - (STACKED_CLEARANCE + STACKED_HEADER_HEIGHT))
                .abs()
                < 0.5
        );
        assert!(lower.bottom() <= px(692.0));
    }

    #[gpui::test]
    fn panel_workspace_split_shortcuts_and_directional_navigation_follow_both_axes(
        cx: &mut TestAppContext,
    ) {
        use chat_split::PaneDirection::*;
        let (shell, cx) = setup(cx);
        cx.simulate_resize(gpui::size(px(1200.0), px(1200.0)));
        shell.update_in(cx, |s, window, cx| {
            s.split_chat(SplitAxis::Vertical, window, cx);
            let layout = s.panel_layout(cx).unwrap();
            assert_eq!(layout.axis, SplitAxis::Vertical);
            let added = layout.focused;
            s.focus_chat_pane_toward(Left, window, cx);
            assert_eq!(
                s.panel_layout(cx).unwrap().focused,
                added,
                "wrong axis must not change focus"
            );
            s.focus_chat_pane_toward(Up, window, cx);
            assert_ne!(s.panel_layout(cx).unwrap().focused, added);
            s.focus_chat_pane_toward(Down, window, cx);
            assert_eq!(s.panel_layout(cx).unwrap().focused, added);
            s.resize_chat_pane(Up, cx);
            assert!(
                s.panel_layout(cx)
                    .unwrap()
                    .panels
                    .iter()
                    .any(|panel| (panel.share - 1.0 / 3.0).abs() > 0.01)
            );
            s.equalize_chat_panes(cx);
            assert!(
                s.panel_layout(cx)
                    .unwrap()
                    .panels
                    .iter()
                    .all(|panel| (panel.share - 1.0 / 3.0).abs() < 0.001)
            );
            s.split_chat(SplitAxis::Horizontal, window, cx);
            assert_eq!(s.panel_layout(cx).unwrap().axis, SplitAxis::Horizontal);
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 4);
        });
    }

    #[gpui::test]
    fn panel_workspace_edge_split_keeps_the_draft_and_rejects_another_workspace(
        cx: &mut TestAppContext,
    ) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, window, cx| {
            s.workspace_new_chat(cx);
            let tab = s
                .panel_layout(cx)
                .unwrap()
                .panel(0)
                .unwrap()
                .selected()
                .unwrap()
                .clone();
            s.composer.update(cx, |composer, cx| {
                composer.set_canvas_input(
                    crate::pickers::CanvasInput {
                        text: "Keep this draft when moving it".into(),
                        ..Default::default()
                    },
                    cx,
                )
            });
            let mut drag = PanelTabDrag {
                workspace: "another-project".into(),
                panel: 0,
                tab,
                title: "Draft".into(),
            };
            s.split_workspace_tab(&drag, 0, PanelEdge::Right, window, cx);
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 2);
            drag.workspace = String::new();
            s.split_workspace_tab(&drag, 0, PanelEdge::Right, window, cx);
            assert_eq!(s.panel_layout(cx).unwrap().panels.len(), 3);
            assert_eq!(
                s.panel_layout(cx).unwrap().location(&drag.tab),
                Some((2, 0))
            );
            assert_eq!(
                s.composer.read(cx).canvas_input(cx).text,
                "Keep this draft when moving it"
            );
        });
    }
    #[gpui::test]
    fn panel_workspace_import_links_align_icons_with_titles(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            let layout = s.panel_layout_mut(cx);
            layout.panels.truncate(1);
            layout.panels[0].tabs = vec![PanelTab::New(901)];
            layout.panels[0].active = 0;
            layout.focused = 0;
            cx.notify();
        });
        for width in [1200.0, 620.0] {
            cx.simulate_resize(gpui::size(px(width), px(700.0)));
            cx.run_until_parked();
            for (icon_selector, title_selector, subtitle_selector) in [
                (
                    "panel-empty-0-3-icon",
                    "panel-empty-0-3-title",
                    Some("panel-empty-0-3-subtitle"),
                ),
                (
                    "panel-empty-0-7-icon",
                    "panel-empty-0-7-title",
                    Some("panel-empty-0-7-subtitle"),
                ),
                ("panel-empty-0-4-icon", "panel-empty-0-4-title", None),
            ] {
                let icon = cx.debug_bounds(icon_selector).unwrap();
                let title = cx.debug_bounds(title_selector).unwrap();
                assert!((f32::from(icon.center().y - title.center().y)).abs() < 0.5);
                if let Some(subtitle_selector) = subtitle_selector {
                    let subtitle = cx.debug_bounds(subtitle_selector).unwrap();
                    assert_eq!(title.left(), subtitle.left());
                    assert!((f32::from(subtitle.top() - title.bottom()) - 1.0).abs() < 0.5);
                }
            }
            assert!(cx.debug_bounds("panel-empty-0-4-subtitle").is_none());
        }
    }

    #[gpui::test]
    fn panel_workspace_open_folder_targets_files_before_confirmation(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, window, cx| {
            let spaces_before = s.state.read(cx).spaces.len();
            s.activate_workspace_empty(0, 3, window, cx);
            assert!(
                s.add_space.is_some(),
                "Open a folder opens the project flow"
            );
            let id = s.workspace_panels.seq;
            assert!(s.workspace_panels.explorers.contains_key(&id));
            assert_eq!(
                s.panel_layout(cx).unwrap().panel(0).unwrap().selected(),
                Some(&PanelTab::FileTree(id))
            );
            assert_eq!(s.state.read(cx).spaces.len(), spaces_before);
            assert_eq!(
                s.panel_layout(cx).unwrap().panel(1).unwrap().selected(),
                Some(&PanelTab::Terminal(2))
            );
        });
    }

    #[gpui::test]
    fn panel_workspace_attention_survives_reading_and_preserves_tab_order(cx: &mut TestAppContext) {
        let (shell, cx) = setup(cx);
        shell.update_in(cx, |s, _, cx| {
            let now = Utc::now();
            s.state.update(cx, |state, cx| {
                state.chats = vec![
                    serde_json::from_value(serde_json::json!({
                        "id":"attention", "deviceId":"fixture", "title":"Review the change",
                        "createdAt":now, "lastMessageAt":now, "archived":false
                    }))
                    .unwrap(),
                ];
                state.sessions = vec![harness_proto::Session {
                    chat_id: "attention".into(),
                    device_id: "fixture".into(),
                    status: harness_proto::SessionStatus::Errored,
                    started_at: Some(now),
                    updated_at: now,
                    last_completed_turn: None,
                    last_completed_peer_only: false,
                }];
                state.mark_chat_seen("attention", cx);
            });
            let tab = PanelTab::Chat("attention".into());
            let order = vec![PanelTab::New(900), tab.clone(), PanelTab::Terminal(1)];
            s.panel_layout_mut(cx).panels[0].tabs = order.clone();
            let context = s
                .panel_tab_context(&tab, 0, &"Review the change".into(), cx)
                .unwrap();
            assert_eq!(context.attention(), Some(TabAttention::Error));
            s.state.update(cx, |state, _| {
                state.sessions[0].status = harness_proto::SessionStatus::AwaitingInput
            });
            assert_eq!(
                s.panel_tab_context(&tab, 0, &"Review the change".into(), cx)
                    .unwrap()
                    .attention(),
                Some(TabAttention::Input)
            );
            s.state.update(cx, |state, _| {
                state.sessions[0].status = harness_proto::SessionStatus::Idle
            });
            assert_eq!(
                s.panel_tab_context(&tab, 0, &"Review the change".into(), cx)
                    .unwrap()
                    .attention(),
                None
            );
            assert_eq!(s.panel_layout(cx).unwrap().panels[0].tabs, order);
        });
    }
}
