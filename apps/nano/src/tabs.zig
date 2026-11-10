//! The window's open chats, listed at the top of the sidebar
//! (crates/ui/src/shell/chat_tabs.rs). Choosing a session shows it in the
//! current tab, or switches to the tab already showing it; "+" opens a new
//! chat in a tab of its own; back and forward step through the tabs.
//!
//! A tab can be split into panes (shell/chat_split.rs): ⌘D to the right,
//! ⌘⇧D down. The focused pane's chat is the tab's own (`current`); the
//! other panes show theirs read only. A new chat's unsent prompt and picks
//! are parked with its pane or tab while another shows (`Draft`).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Axis = enum { horizontal, vertical };
pub const Direction = enum { left, right, up, down };

/// Every pane holds a transcript watch; a chat column isn't a terminal grid
/// (`MAX_CHAT_PANES`).
pub const max_panes = 8;
/// No pane gets squeezed below this share, less once equal shares can't
/// (`MIN_PANE_SHARE`).
const min_pane_share: f32 = 0.15;
/// One ⌃⌘+arrow moves the divider by this share (`RESIZE_STEP`).
const resize_step: f32 = 0.05;

/// A new chat's unsent prompt and what it would run on, parked with its
/// pane or tab while another is focused (`CanvasDraft`, pickers.rs). Owned.
pub const Draft = struct {
    text: []u8,
    harness: []u8,
    model: ?[]u8 = null,
    reasoning: ?[]u8 = null,
    /// The project it starts in.
    space: ?[]u8 = null,
    no_project: bool = false,
    /// Explicit execution device, including a draft outside any project.
    device: ?[]u8 = null,

    pub fn deinit(d: *Draft, gpa: Allocator) void {
        gpa.free(d.text);
        gpa.free(d.harness);
        inline for (.{ "model", "reasoning", "space", "device" }) |f| if (@field(d, f)) |x| gpa.free(x);
    }

    /// The same picks with an empty prompt: a new pane or tab starts with
    /// these, not with the prompt it was opened from (`fresh`).
    pub fn fresh(d: Draft, gpa: Allocator) !Draft {
        var out: Draft = .{ .text = try gpa.dupe(u8, ""), .harness = &.{} };
        errdefer out.deinit(gpa);
        out.harness = try gpa.dupe(u8, d.harness);
        out.no_project = d.no_project;
        inline for (.{ "model", "reasoning", "space", "device" }) |f| if (@field(d, f)) |x| {
            @field(out, f) = try gpa.dupe(u8, x);
        };
        return out;
    }
};

fn dropDraft(gpa: Allocator, d: *?Draft) void {
    if (d.*) |*x| x.deinit(gpa);
    d.* = null;
}

/// A panel's inactive tabs. Its active slot borrows the pane's live chat and
/// draft; inactive slots own both, so adding a tab never replaces a neighbor.
pub const PanelTab = struct {
    chat: ?[]u8 = null,
    draft: ?Draft = null,
    /// When this tab was last on screen (`noteShown`); 0 until shown.
    shown: u64 = 0,

    fn deinit(tab: *PanelTab, gpa: Allocator) void {
        if (tab.chat) |id| gpa.free(id);
        dropDraft(gpa, &tab.draft);
        tab.* = .{};
    }
};

/// The tab to show after closing `closed` (`active_after_close` in
/// `workspace_panels.rs`): the one already on screen if a background tab was
/// closed, else the surviving tab with the largest `shown > 0`, else the
/// neighbour at `@min(closed, shown.len - 1)`.
pub fn activeAfterClose(shown: []const u64, active: usize, closed: usize) usize {
    if (shown.len == 0) return 0;
    if (closed != active) return if (active > closed) active - 1 else @min(active, shown.len - 1);
    var best: ?usize = null;
    var best_stamp: u64 = 0;
    for (shown, 0..) |stamp, i| if (stamp > best_stamp) {
        best_stamp = stamp;
        best = i;
    };
    return best orelse @min(closed, shown.len - 1);
}

pub const PanelTabs = struct {
    items: std.ArrayList(PanelTab) = .empty,
    active: usize = 0,

    pub fn deinit(group: *PanelTabs, gpa: Allocator) void {
        for (group.items.items) |*tab| tab.deinit(gpa);
        group.items.deinit(gpa);
        group.* = .{};
    }

    pub fn count(group: PanelTabs) usize {
        return @max(1, group.items.items.len);
    }
};

pub const Split = struct {
    axis: Axis,
    /// Each pane's chat (owned); the focused pane's is its tab's, so its
    /// slot here is null.
    panes: std.ArrayList(?[]u8) = .empty,
    /// Each pane's share of the column along `axis`; they sum to 1.
    shares: std.ArrayList(f32) = .empty,
    /// Each pane's parked new-chat draft; the focused pane's is live.
    drafts: std.ArrayList(?Draft) = .empty,
    focus: usize = 0,
    /// ⌘⇧↩: the focused pane alone, the split kept.
    zoomed: bool = false,
    /// Per-panel tab groups, in pane order. Only inactive slots own data.
    groups: [max_panes]PanelTabs = @splat(.{}),

    pub fn deinit(s: *Split, gpa: Allocator) void {
        for (s.panes.items) |p| if (p) |id| gpa.free(id);
        for (s.drafts.items) |*d| dropDraft(gpa, d);
        for (&s.groups) |*group| group.deinit(gpa);
        s.panes.deinit(gpa);
        s.shares.deinit(gpa);
        s.drafts.deinit(gpa);
    }

    fn equalize(s: *Split) void {
        const share = 1 / @as(f32, @floatFromInt(s.panes.items.len));
        for (s.shares.items) |*x| x.* = share;
    }

    fn isEven(s: Split) bool {
        const share = 1 / @as(f32, @floatFromInt(s.shares.items.len));
        for (s.shares.items) |x| if (@abs(x - share) >= 1e-3) return false;
        return true;
    }

    fn minShare(s: Split) f32 {
        return @min(min_pane_share, 0.5 / @as(f32, @floatFromInt(s.panes.items.len)));
    }

    /// The pane after (or before) the focused one, round.
    pub fn cycled(s: Split, forward: bool) usize {
        const len = s.panes.items.len;
        return if (forward) (s.focus + 1) % len else (s.focus + len - 1) % len;
    }

    /// The neighbor in `d`, if the split runs that way.
    pub fn toward(s: Split, d: Direction) ?usize {
        const back = switch (s.axis) {
            .horizontal => switch (d) {
                .left => true,
                .right => false,
                else => return null,
            },
            .vertical => switch (d) {
                .up => true,
                .down => false,
                else => return null,
            },
        };
        if (back) return if (s.focus > 0) s.focus - 1 else null;
        return if (s.focus + 1 < s.panes.items.len) s.focus + 1 else null;
    }

    /// Moves the focused pane's far divider (its near one for the last
    /// pane) toward `d`; nothing when the split runs the other way.
    fn resize(s: *Split, d: Direction) void {
        const grow = switch (s.axis) {
            .horizontal => switch (d) {
                .right => true,
                .left => false,
                else => return,
            },
            .vertical => switch (d) {
                .down => true,
                .up => false,
                else => return,
            },
        };
        const a, const b = if (s.focus + 1 < s.panes.items.len) .{ s.focus, s.focus + 1 } else .{ s.focus - 1, s.focus };
        const total = s.shares.items[a] + s.shares.items[b];
        const min = @min(s.minShare(), total / 2);
        const first = std.math.clamp(s.shares.items[a] + (if (grow) resize_step else -resize_step), min, total - min);
        s.shares.items[a] = first;
        s.shares.items[b] = total - first;
        s.zoomed = false;
    }
};

/// A divider being dragged: which (before pane `divider`), where the
/// pointer started, and the shares then (`DividerDrag`).
pub const Drag = struct { divider: usize, origin: f32, start: [max_panes]f32 };

pub const Tabs = struct {
    gpa: Allocator,
    /// Each tab's chat (owned); null is a new chat not yet sent. With a
    /// split, the focused pane's.
    items: std.ArrayList(?[]u8) = .empty,
    /// Each tab's split, alongside `items`.
    splits: std.ArrayList(?Split) = .empty,
    /// Each tab's parked new-chat draft, alongside `items`; the active
    /// tab's is live.
    drafts: std.ArrayList(?Draft) = .empty,
    /// When each tab was last on screen (`noteShown`), alongside `items`.
    /// Not saved: after a restart (`clearShown`), only the active tab is
    /// marked, so closing it falls back to its neighbour.
    shown: std.ArrayList(u64) = .empty,
    /// Recently closed chat IDs (LIFO) for Reopen closed tab (⌘⇧T).
    closed: std.ArrayList([]u8) = .empty,
    next_shown: u64 = 0,
    active: usize = 0,

    pub fn init(gpa: Allocator) Tabs {
        var t: Tabs = .{ .gpa = gpa };
        t.append() catch {};
        t.noteShown();
        return t;
    }

    fn append(t: *Tabs) !void {
        try t.items.append(t.gpa, null);
        errdefer _ = t.items.pop();
        try t.splits.append(t.gpa, null);
        errdefer _ = t.splits.pop();
        try t.drafts.append(t.gpa, null);
        errdefer _ = t.drafts.pop();
        try t.shown.append(t.gpa, 0);
    }

    pub fn deinit(t: *Tabs) void {
        for (t.items.items) |c| if (c) |id| t.gpa.free(id);
        t.items.deinit(t.gpa);
        for (t.splits.items) |*s| if (s.*) |*x| x.deinit(t.gpa);
        t.splits.deinit(t.gpa);
        for (t.drafts.items) |*d| dropDraft(t.gpa, d);
        t.drafts.deinit(t.gpa);
        t.shown.deinit(t.gpa);
        for (t.closed.items) |id| t.gpa.free(id);
        t.closed.deinit(t.gpa);
    }

    pub fn rememberClosed(t: *Tabs, id: ?[]const u8) void {
        const chat = id orelse return;
        if (chat.len == 0) return;
        var i = t.closed.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, t.closed.items[i], chat)) {
                t.gpa.free(t.closed.orderedRemove(i));
            }
        }
        const copy = t.gpa.dupe(u8, chat) catch return;
        t.closed.append(t.gpa, copy) catch t.gpa.free(copy);
    }

    pub fn popClosed(t: *Tabs) ?[]u8 {
        if (t.closed.items.len == 0) return null;
        return t.closed.pop();
    }

    pub fn bumpShown(t: *Tabs) u64 {
        t.next_shown += 1;
        return t.next_shown;
    }

    pub fn noteShown(t: *Tabs) void {
        if (t.active < t.shown.items.len) t.shown.items[t.active] = t.bumpShown();
        if (t.layout()) |s| {
            const group = &s.groups[s.focus];
            if (group.active < group.items.items.len) group.items.items[group.active].shown = t.bumpShown();
        }
    }

    /// After restoring tabs from disk: no tab has a prior-shown history except
    /// the one currently on screen, so closing it falls back to its neighbour.
    pub fn clearShown(t: *Tabs) void {
        t.next_shown = 0;
        for (t.shown.items) |*s| s.* = 0;
        for (t.splits.items) |*sp| if (sp.*) |*s| for (&s.groups) |*group| {
            for (group.items.items) |*tab| tab.shown = 0;
            if (group.active < group.items.items.len) group.items.items[group.active].shown = t.bumpShown();
        };
        t.noteShown();
    }

    /// Parks `d` with tab `i` (or, `pane` given, that pane of the active
    /// tab's split), in place of what was parked there.
    pub fn park(t: *Tabs, i: usize, pane: ?usize, d: Draft) void {
        const slot = t.draftSlot(i, pane) orelse {
            var x = d;
            return x.deinit(t.gpa);
        };
        dropDraft(t.gpa, slot);
        slot.* = d;
    }

    /// Takes what is parked with tab `i`, or with that pane of its split.
    pub fn unpark(t: *Tabs, i: usize, pane: ?usize) ?Draft {
        const slot = t.draftSlot(i, pane) orelse return null;
        defer slot.* = null;
        return slot.*;
    }

    fn draftSlot(t: *Tabs, i: usize, pane: ?usize) ?*?Draft {
        if (i >= t.drafts.items.len) return null;
        const ix = pane orelse return &t.drafts.items[i];
        const s = &(t.splits.items[i] orelse return null);
        return if (ix < s.drafts.items.len) &s.drafts.items[ix] else null;
    }

    /// Where `id` is open: its tab, and its pane there when it isn't the
    /// tab's focused one.
    pub fn find(t: *const Tabs, id: []const u8) ?struct { tab: usize, pane: ?usize, panel_tab: ?usize = null } {
        if (t.paneOf(t.active, id)) |ix| return .{ .tab = t.active, .pane = ix };
        for (t.items.items, 0..) |c, i| if (c) |have| if (std.mem.eql(u8, have, id)) return .{ .tab = i, .pane = null };
        for (0..t.splits.items.len) |i| if (t.paneOf(i, id)) |ix| return .{ .tab = i, .pane = ix };
        for (t.splits.items, 0..) |layout_state, i| if (layout_state) |s| {
            for (s.groups[0..s.panes.items.len], 0..) |group, pane| {
                for (group.items.items, 0..) |tab, ix| if (tab.chat) |chat| {
                    if (std.mem.eql(u8, chat, id)) return .{ .tab = i, .pane = pane, .panel_tab = ix };
                };
            }
        };
        return null;
    }

    pub fn current(t: *const Tabs) ?[]const u8 {
        if (t.items.items.len == 0) return null;
        return t.items.items[t.active];
    }

    /// The active tab's split, if it has one.
    pub fn layout(t: *const Tabs) ?*Split {
        if (t.splits.items.len == 0) return null;
        if (t.splits.items[t.active]) |*s| return s;
        return null;
    }

    fn paneOf(t: *const Tabs, tab: usize, id: []const u8) ?usize {
        const s = t.splits.items[tab] orelse return null;
        for (s.panes.items, 0..) |p, ix| if (p) |have| if (std.mem.eql(u8, have, id)) return ix;
        return null;
    }

    /// Shows `id`: its pane or tab where it's open, else in the current tab.
    pub fn show(t: *Tabs, id: []const u8) void {
        if (t.paneOf(t.active, id)) |ix| return t.focusPane(ix);
        for (t.items.items, 0..) |c, i| if (c) |have| if (std.mem.eql(u8, have, id)) {
            t.active = i;
            t.noteShown();
            return;
        };
        for (0..t.splits.items.len) |i| if (t.paneOf(i, id)) |ix| {
            t.active = i;
            t.noteShown();
            return t.focusPane(ix);
        };
        t.setCurrent(id);
    }

    /// The current tab now shows `id` (a new chat was just sent).
    pub fn setCurrent(t: *Tabs, id: ?[]const u8) void {
        const copy = if (id) |c| t.gpa.dupe(u8, c) catch return else null;
        if (t.items.items.len == 0) {
            t.append() catch {
                if (copy) |c| t.gpa.free(c);
                return;
            };
            t.items.items[0] = copy;
            t.active = 0;
            t.noteShown();
            return;
        }
        if (t.items.items[t.active]) |old| t.gpa.free(old);
        t.items.items[t.active] = copy;
        t.noteShown();
    }

    pub fn hasIsolatedWorkspaces(t: *const Tabs) bool {
        for (t.splits.items) |other| if (other != null) return true;
        return false;
    }

    /// Give an independent workspace a structural boundary even before its
    /// first split, so split() cannot migrate neighboring workspaces into it.
    pub fn isolateWorkspace(t: *Tabs) !void {
        if (t.splits.items[t.active] != null) return;
        var s: Split = .{ .axis = .horizontal };
        errdefer s.deinit(t.gpa);
        try s.panes.append(t.gpa, null);
        try s.shares.append(t.gpa, 1);
        try s.drafts.append(t.gpa, null);
        t.splits.items[t.active] = s;
    }

    /// A new chat in a tab of its own, after the current one.
    pub fn newTab(t: *Tabs) void {
        const at = @min(t.active + 1, t.items.items.len);
        t.items.insert(t.gpa, at, null) catch return;
        t.splits.insert(t.gpa, at, null) catch {
            _ = t.items.orderedRemove(at);
            return;
        };
        t.drafts.insert(t.gpa, at, null) catch {
            _ = t.items.orderedRemove(at);
            _ = t.splits.orderedRemove(at);
            return;
        };
        t.shown.insert(t.gpa, at, 0) catch {
            _ = t.items.orderedRemove(at);
            _ = t.splits.orderedRemove(at);
            _ = t.drafts.orderedRemove(at);
            return;
        };
        t.active = at;
        t.noteShown();
    }

    /// A new tab after the last, shown (`create_chat_tab`'s push).
    pub fn appendTab(t: *Tabs) void {
        t.append() catch return;
        t.active = t.items.items.len - 1;
        t.noteShown();
    }

    /// Closes tab `i`; the last tab left becomes a new chat instead.
    pub fn close(t: *Tabs, i: usize) void {
        if (i >= t.items.items.len) return;
        if (t.items.items.len == 1) {
            t.rememberClosed(t.items.items[0]);
            if (t.splits.items[0]) |*s| if (s.panes.items.len == 1 and s.groups[0].items.items.len <= 1) {
                s.deinit(t.gpa);
                t.splits.items[0] = null;
            };
            dropDraft(t.gpa, &t.drafts.items[0]);
            return t.setCurrent(null);
        }
        if (t.items.orderedRemove(i)) |id| {
            t.rememberClosed(id);
            t.gpa.free(id);
        }
        if (t.splits.orderedRemove(i)) |s| {
            var x = s;
            x.deinit(t.gpa);
        }
        var d = t.drafts.orderedRemove(i);
        dropDraft(t.gpa, &d);
        if (i < t.shown.items.len) _ = t.shown.orderedRemove(i);
        t.active = activeAfterClose(t.shown.items, t.active, i);
        t.noteShown();
    }

    pub fn canStep(t: *const Tabs, by: i32) bool {
        const to = @as(i64, @intCast(t.active)) + by;
        return to >= 0 and to < t.items.items.len;
    }

    pub fn step(t: *Tabs, by: i32) void {
        if (!t.canStep(by)) return;
        t.active = @intCast(@as(i64, @intCast(t.active)) + by);
        t.noteShown();
    }

    /// A chat went away (deleted, or archived elsewhere): its tabs close,
    /// and panes showing it are left empty.
    pub fn forget(t: *Tabs, id: []const u8) void {
        for (t.splits.items) |*s| if (s.*) |*x| for (x.panes.items) |*p| if (p.*) |have| if (std.mem.eql(u8, have, id)) {
            t.gpa.free(have);
            p.* = null;
        };
        for (t.splits.items) |*layout_state| if (layout_state.*) |*s| {
            for (&s.groups) |*group| {
                var ix = group.items.items.len;
                while (ix > 0) {
                    ix -= 1;
                    if (group.items.items[ix].chat) |chat| if (std.mem.eql(u8, chat, id)) {
                        var removed = group.items.orderedRemove(ix);
                        removed.deinit(t.gpa);
                        if (group.active > ix) group.active -= 1;
                    };
                }
            }
        };
        var i = t.items.items.len;
        while (i > 0) {
            i -= 1;
            if (t.items.items[i]) |have| if (std.mem.eql(u8, have, id)) t.close(i);
        }
        var ci = t.closed.items.len;
        while (ci > 0) {
            ci -= 1;
            if (std.mem.eql(u8, t.closed.items[ci], id)) {
                t.gpa.free(t.closed.orderedRemove(ci));
            }
        }
    }

    /// Whether `split(axis)` would split: no split yet, or one along `axis`
    /// with room for another pane (`can_split`).
    pub fn canSplit(t: *const Tabs, axis: Axis) bool {
        const s = t.layout() orelse return true;
        return (s.panes.items.len == 1 or s.axis == axis) and s.panes.items.len < max_panes;
    }

    /// `id` out of every pane and every other tab, which are left on a new
    /// chat: dragged into a new pane, a chat moves rather than shows twice
    /// (`detach_chat_from_tab_snapshots`).
    pub fn detach(t: *Tabs, id: []const u8) void {
        for (t.splits.items) |*sp| if (sp.*) |*s| for (s.panes.items) |*p| if (p.*) |have| if (std.mem.eql(u8, have, id)) {
            t.gpa.free(have);
            p.* = null;
        };
        for (t.splits.items) |*layout_state| if (layout_state.*) |*s| {
            for (&s.groups) |*group| for (group.items.items) |*tab| if (tab.chat) |chat| if (std.mem.eql(u8, chat, id)) {
                t.gpa.free(chat);
                tab.chat = null;
            };
        };
        for (t.items.items, 0..) |*c, i| if (i != t.active) if (c.*) |have| if (std.mem.eql(u8, have, id)) {
            t.gpa.free(have);
            c.* = null;
        };
    }

    /// ⌘D (right) or ⌘⇧D (down): the focused pane split in two, every pane
    /// then the same size, the new one a new chat with focus. Nothing at
    /// the cap or across an existing split's axis (`split_chat`).
    pub fn split(t: *Tabs, axis: Axis) !bool {
        const slot = &t.splits.items[t.active];
        if (slot.* == null) {
            var s: Split = .{ .axis = axis };
            errdefer s.deinit(t.gpa);
            try s.panes.append(t.gpa, null);
            try s.shares.append(t.gpa, 1);
            try s.drafts.append(t.gpa, null);
            slot.* = s;
        }
        const s = &slot.*.?;
        if (s.panes.items.len == 1) s.axis = axis;
        if (s.axis != axis or s.panes.items.len >= max_panes) {
            if (s.panes.items.len == 1) {
                s.deinit(t.gpa);
                slot.* = null;
            }
            return false;
        }
        const at = s.focus + 1;
        try s.panes.insert(t.gpa, at, null);
        s.shares.insert(t.gpa, at, 0) catch |e| {
            _ = s.panes.orderedRemove(at);
            return e;
        };
        s.drafts.insert(t.gpa, at, null) catch |e| {
            _ = s.panes.orderedRemove(at);
            _ = s.shares.orderedRemove(at);
            return e;
        };
        var group_at = s.panes.items.len - 1;
        while (group_at > at) : (group_at -= 1) s.groups[group_at] = s.groups[group_at - 1];
        s.groups[at] = .{};
        s.panes.items[s.focus] = t.items.items[t.active];
        t.items.items[t.active] = null;
        s.equalize();
        s.focus = at;
        s.zoomed = false;
        return true;
    }

    /// Focus pane `ix`: the tab's chat parks in the pane left behind, and
    /// `ix`'s chat becomes the tab's.
    pub fn focusPane(t: *Tabs, ix: usize) void {
        const s = t.layout() orelse return;
        if (ix >= s.panes.items.len or ix == s.focus) return;
        s.panes.items[s.focus] = t.items.items[t.active];
        t.items.items[t.active] = s.panes.items[ix];
        s.panes.items[ix] = null;
        s.focus = ix;
        s.zoomed = false;
        t.noteShown();
    }

    /// ⌘W in a split: the focused pane closes, its share to the pane before
    /// it (or after, for the first), or all even again if they were; one
    /// pane left is no split. False with no split to close a pane of.
    pub fn closePane(t: *Tabs) bool {
        const s = t.layout() orelse return false;
        if (s.panes.items.len < 2) return false;
        if (t.items.items[t.active]) |id| {
            t.rememberClosed(id);
            t.gpa.free(id);
        }
        const even = s.isEven();
        const closed = s.focus;
        s.groups[closed].deinit(t.gpa);
        var group_at = closed;
        while (group_at + 1 < s.panes.items.len) : (group_at += 1) s.groups[group_at] = s.groups[group_at + 1];
        s.groups[s.panes.items.len - 1] = .{};
        const share = s.shares.orderedRemove(closed);
        _ = s.panes.orderedRemove(closed);
        var gone = s.drafts.orderedRemove(closed);
        dropDraft(t.gpa, &gone);
        const next = @min(closed -| 1, s.panes.items.len - 1);
        s.shares.items[next] += share;
        if (even) s.equalize();
        s.focus = next;
        s.zoomed = false;
        t.items.items[t.active] = s.panes.items[next];
        s.panes.items[next] = null;
        if (s.panes.items.len == 1 and s.groups[0].count() == 1) {
            // The pane left is the tab: its parked draft goes with it.
            dropDraft(t.gpa, &t.drafts.items[t.active]);
            t.drafts.items[t.active] = s.drafts.items[0];
            s.drafts.items[0] = null;
            s.deinit(t.gpa);
            t.splits.items[t.active] = null;
        }
        t.noteShown();
        return true;
    }

    /// Add a tab to the focused panel, retaining the split, its shares, and
    /// all neighboring chats. Takes the outgoing live draft on success only.
    pub fn newPaneTab(t: *Tabs, draft: Draft) !void {
        return t.insertPaneTab(draft, false);
    }

    /// External navigation appends, unlike Cmd+T's insert-after-current.
    pub fn appendPaneTab(t: *Tabs, draft: Draft) !void {
        return t.insertPaneTab(draft, true);
    }

    fn insertPaneTab(t: *Tabs, draft: Draft, at_end: bool) !void {
        const s = t.layout() orelse return error.NoSplit;
        const group = &s.groups[s.focus];
        try group.items.ensureUnusedCapacity(t.gpa, if (group.items.items.len == 0) 2 else 1);
        if (group.items.items.len == 0) group.items.appendAssumeCapacity(.{ .shown = t.bumpShown() });
        const prev_shown = group.items.items[group.active].shown;
        group.items.items[group.active] = .{ .chat = t.items.items[t.active], .draft = draft, .shown = if (prev_shown > 0) prev_shown else t.bumpShown() };
        t.items.items[t.active] = null;
        const at = if (at_end) group.items.items.len else group.active + 1;
        group.items.insertAssumeCapacity(at, .{ .shown = t.bumpShown() });
        group.active = at;
    }

    /// Switch inside the focused panel. No tab data from another panel moves.
    /// Takes `draft` on success and returns the incoming tab's parked draft.
    pub fn selectPaneTab(t: *Tabs, ix: usize, draft: Draft) !?Draft {
        const s = t.layout() orelse return error.NoSplit;
        const group = &s.groups[s.focus];
        if (ix >= group.items.items.len or ix == group.active) return error.NoTab;
        const prev_shown = group.items.items[group.active].shown;
        group.items.items[group.active] = .{ .chat = t.items.items[t.active], .draft = draft, .shown = if (prev_shown > 0) prev_shown else t.bumpShown() };
        const incoming = group.items.items[ix];
        group.items.items[ix] = .{ .shown = t.bumpShown() };
        group.active = ix;
        t.items.items[t.active] = incoming.chat;
        return incoming.draft;
    }

    /// Close a tab without closing its panel while another tab remains.
    pub fn closePaneTab(t: *Tabs) bool {
        const s = t.layout() orelse return false;
        const group = &s.groups[s.focus];
        if (group.items.items.len <= 1) return false;
        if (t.items.items[t.active]) |id| {
            t.rememberClosed(id);
            t.gpa.free(id);
        }
        const closed = group.active;
        _ = group.items.orderedRemove(closed);
        var stamps: [64]u64 = undefined;
        const n = @min(group.items.items.len, stamps.len);
        for (group.items.items[0..n], 0..) |tab, i| stamps[i] = tab.shown;
        group.active = activeAfterClose(stamps[0..n], closed, closed);
        const incoming = group.items.items[group.active];
        group.items.items[group.active] = .{ .shown = t.bumpShown() };
        t.items.items[t.active] = incoming.chat;
        dropDraft(t.gpa, &s.drafts.items[s.focus]);
        s.drafts.items[s.focus] = incoming.draft;
        if (s.panes.items.len == 1 and group.count() == 1) {
            dropDraft(t.gpa, &t.drafts.items[t.active]);
            t.drafts.items[t.active] = s.drafts.items[0];
            s.drafts.items[0] = null;
            s.deinit(t.gpa);
            t.splits.items[t.active] = null;
        }
        return true;
    }

    /// Reorder the focused panel, carrying its tabs, draft and share together.
    pub fn movePane(t: *Tabs, after: bool) void {
        const s = t.layout() orelse return;
        const from = s.focus;
        const to = if (after) from + 1 else from -| 1;
        if (to >= s.panes.items.len or to == from) return;
        std.mem.swap(?[]u8, &s.panes.items[from], &s.panes.items[to]);
        std.mem.swap(?Draft, &s.drafts.items[from], &s.drafts.items[to]);
        std.mem.swap(f32, &s.shares.items[from], &s.shares.items[to]);
        std.mem.swap(PanelTabs, &s.groups[from], &s.groups[to]);
        s.focus = to;
    }

    /// ⌘] / ⌘[: the next pane, round.
    pub fn cyclePane(t: *Tabs, forward: bool) void {
        const s = t.layout() orelse return;
        t.focusPane(s.cycled(forward));
    }

    /// ⌥⌘+arrow: the neighbor that way.
    pub fn focusToward(t: *Tabs, d: Direction) void {
        const s = t.layout() orelse return;
        if (s.toward(d)) |ix| t.focusPane(ix);
    }

    /// ⌃⌘+arrow.
    pub fn resize(t: *Tabs, d: Direction) void {
        if (t.layout()) |s| s.resize(d);
    }

    /// The divider before pane `divider` dragged `delta` of the whole
    /// column from the shares a drag started with: only its two panes
    /// change, neither below the smallest share (`drag_divider`).
    pub fn dragDivider(t: *Tabs, d: Drag, delta: f32) void {
        const s = t.layout() orelse return;
        const sh = s.shares.items;
        if (d.divider == 0 or d.divider >= sh.len) return;
        @memcpy(sh, d.start[0..sh.len]);
        const total = d.start[d.divider - 1] + d.start[d.divider];
        const min = @min(s.minShare(), total / 2);
        const first = std.math.clamp(d.start[d.divider - 1] + delta, min, total - min);
        sh[d.divider - 1] = first;
        sh[d.divider] = total - first;
        s.zoomed = false;
    }

    /// ⌃⌘=.
    pub fn equalize(t: *Tabs) void {
        if (t.layout()) |s| {
            s.equalize();
            s.zoomed = false;
        }
    }

    /// ⌘⇧↩: the focused pane alone, or the split again.
    pub fn toggleZoom(t: *Tabs) void {
        if (t.layout()) |s| s.zoomed = !s.zoomed;
    }
};

const testing = std.testing;

test "show switches to an open tab, else replaces the current one" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    try testing.expectEqualStrings("a", t.current().?);
    t.newTab();
    try testing.expect(t.current() == null);
    t.show("b");
    try testing.expectEqual(@as(usize, 2), t.items.items.len);
    t.show("a");
    try testing.expectEqual(@as(usize, 0), t.active);
    try testing.expect(!t.canStep(-1));
    t.step(1);
    try testing.expectEqualStrings("b", t.current().?);
}

test "closing keeps a tab, and the active one stays in range" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    t.newTab();
    t.show("b");
    t.close(1);
    try testing.expectEqualStrings("a", t.current().?);
    t.close(0);
    try testing.expectEqual(@as(usize, 1), t.items.items.len);
    try testing.expect(t.current() == null);
    t.show("c");
    t.forget("c");
    try testing.expect(t.current() == null);
}

test "⌘D makes even panes and focuses the new chat; focus swaps; ⌘W closes a pane" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    try testing.expect(try t.split(.horizontal));
    try testing.expect(t.current() == null);
    try testing.expectEqual(@as(usize, 2), t.layout().?.panes.items.len);
    try testing.expectEqual(@as(f32, 0.5), t.layout().?.shares.items[0]);
    t.setCurrent("b");
    // Across the split's axis: nothing.
    try testing.expect(!try t.split(.vertical));
    try testing.expect(try t.split(.horizontal));
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), t.layout().?.shares.items[2], 1e-6);
    t.focusToward(.left);
    try testing.expectEqualStrings("b", t.current().?);
    // In this tab's split: its pane takes focus.
    t.show("a");
    try testing.expectEqualStrings("a", t.current().?);
    try testing.expectEqual(@as(usize, 0), t.layout().?.focus);
    t.resize(.right);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0 + 0.05), t.layout().?.shares.items[0], 1e-6);
    // a's pane closes; uneven, so its share goes to b's.
    try testing.expect(t.closePane());
    try testing.expectEqualStrings("b", t.current().?);
    try testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), t.layout().?.shares.items[0], 1e-6);
    t.cyclePane(true);
    try testing.expect(t.current() == null);
    try testing.expect(t.closePane());
    try testing.expect(t.layout() == null);
    try testing.expectEqualStrings("b", t.current().?);
    try testing.expect(!t.closePane());
}

test "a split stops at eight panes; a chat in another tab's pane is shown there" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    for (0..max_panes - 1) |_| try testing.expect(try t.split(.vertical));
    try testing.expect(!try t.split(.vertical));
    try testing.expectEqual(@as(usize, max_panes), t.layout().?.panes.items.len);
    t.newTab();
    t.show("a");
    try testing.expectEqual(@as(usize, 0), t.active);
    try testing.expectEqualStrings("a", t.current().?);
    // Gone for good: its tab closes, and this one is left.
    t.forget("a");
    try testing.expectEqual(@as(usize, 1), t.items.items.len);
    try testing.expect(t.current() == null);
}

test "dragging a divider moves only its two panes, never below the minimum" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    _ = try t.split(.horizontal);
    _ = try t.split(.horizontal);
    var d: Drag = .{ .divider = 1, .origin = 0, .start = @splat(0) };
    @memcpy(d.start[0..3], t.layout().?.shares.items);
    t.dragDivider(d, 0.1);
    const sh = t.layout().?.shares.items;
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0 + 0.1), sh[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0 - 0.1), sh[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), sh[2], 1e-6);
    t.dragDivider(d, 0.9);
    try testing.expectApproxEqAbs(@as(f32, 0.15), t.layout().?.shares.items[1], 1e-6);
}

test "a dragged chat moves into its new pane, out of every other place" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    t.newTab();
    t.show("b");
    try testing.expect(t.canSplit(.vertical));
    try testing.expect(try t.split(.horizontal));
    try testing.expect(!t.canSplit(.vertical));
    // Splitting only splits the active tab; moving "a" from tab 0 into tab 1's
    // second pane clears tab 0 without disturbing tab 1's first pane ("b").
    t.detach("a");
    t.setCurrent("a");
    try testing.expectEqualStrings("a", t.current().?);
    try testing.expectEqual(@as(usize, 2), t.items.items.len);
    try testing.expect(t.items.items[0] == null);
    const layout_state = t.layout().?;
    try testing.expectEqualStrings("b", layout_state.panes.items[0].?);
    const found = t.find("a").?;
    try testing.expectEqual(@as(usize, 1), found.tab);
    try testing.expect(found.pane == null and found.panel_tab == null);
}
