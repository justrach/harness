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

    pub fn deinit(d: *Draft, gpa: Allocator) void {
        gpa.free(d.text);
        gpa.free(d.harness);
        inline for (.{ "model", "reasoning", "space" }) |f| if (@field(d, f)) |x| gpa.free(x);
    }

    /// The same picks with an empty prompt: a new pane or tab starts with
    /// these, not with the prompt it was opened from (`fresh`).
    pub fn fresh(d: Draft, gpa: Allocator) !Draft {
        var out: Draft = .{ .text = try gpa.dupe(u8, ""), .harness = &.{} };
        errdefer out.deinit(gpa);
        out.harness = try gpa.dupe(u8, d.harness);
        inline for (.{ "model", "reasoning", "space" }) |f| if (@field(d, f)) |x| {
            @field(out, f) = try gpa.dupe(u8, x);
        };
        return out;
    }
};

fn dropDraft(gpa: Allocator, d: *?Draft) void {
    if (d.*) |*x| x.deinit(gpa);
    d.* = null;
}

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

    fn deinit(s: *Split, gpa: Allocator) void {
        for (s.panes.items) |p| if (p) |id| gpa.free(id);
        for (s.drafts.items) |*d| dropDraft(gpa, d);
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
    active: usize = 0,

    pub fn init(gpa: Allocator) Tabs {
        var t: Tabs = .{ .gpa = gpa };
        t.append() catch {};
        return t;
    }

    fn append(t: *Tabs) !void {
        try t.items.append(t.gpa, null);
        errdefer _ = t.items.pop();
        try t.splits.append(t.gpa, null);
        errdefer _ = t.splits.pop();
        try t.drafts.append(t.gpa, null);
    }

    pub fn deinit(t: *Tabs) void {
        for (t.items.items) |c| if (c) |id| t.gpa.free(id);
        t.items.deinit(t.gpa);
        for (t.splits.items) |*s| if (s.*) |*x| x.deinit(t.gpa);
        t.splits.deinit(t.gpa);
        for (t.drafts.items) |*d| dropDraft(t.gpa, d);
        t.drafts.deinit(t.gpa);
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
    pub fn find(t: *const Tabs, id: []const u8) ?struct { tab: usize, pane: ?usize } {
        if (t.paneOf(t.active, id)) |ix| return .{ .tab = t.active, .pane = ix };
        for (t.items.items, 0..) |c, i| if (c) |have| if (std.mem.eql(u8, have, id)) return .{ .tab = i, .pane = null };
        for (0..t.splits.items.len) |i| if (t.paneOf(i, id)) |ix| return .{ .tab = i, .pane = ix };
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
            return;
        };
        for (0..t.splits.items.len) |i| if (t.paneOf(i, id)) |ix| {
            t.active = i;
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
            return;
        }
        if (t.items.items[t.active]) |old| t.gpa.free(old);
        t.items.items[t.active] = copy;
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
        t.active = at;
    }

    /// A new tab after the last, shown (`create_chat_tab`'s push).
    pub fn appendTab(t: *Tabs) void {
        t.append() catch return;
        t.active = t.items.items.len - 1;
    }

    /// Closes tab `i`; the last tab left becomes a new chat instead.
    pub fn close(t: *Tabs, i: usize) void {
        if (i >= t.items.items.len) return;
        if (t.items.items.len == 1) return t.setCurrent(null);
        if (t.items.orderedRemove(i)) |id| t.gpa.free(id);
        if (t.splits.orderedRemove(i)) |s| {
            var x = s;
            x.deinit(t.gpa);
        }
        var d = t.drafts.orderedRemove(i);
        dropDraft(t.gpa, &d);
        if (t.active > i or t.active == t.items.items.len) t.active -|= 1;
    }

    pub fn canStep(t: *const Tabs, by: i32) bool {
        const to = @as(i64, @intCast(t.active)) + by;
        return to >= 0 and to < t.items.items.len;
    }

    pub fn step(t: *Tabs, by: i32) void {
        if (!t.canStep(by)) return;
        t.active = @intCast(@as(i64, @intCast(t.active)) + by);
    }

    /// A chat went away (deleted, or archived elsewhere): its tabs close,
    /// and panes showing it are left empty.
    pub fn forget(t: *Tabs, id: []const u8) void {
        for (t.splits.items) |*s| if (s.*) |*x| for (x.panes.items) |*p| if (p.*) |have| if (std.mem.eql(u8, have, id)) {
            t.gpa.free(have);
            p.* = null;
        };
        var i = t.items.items.len;
        while (i > 0) {
            i -= 1;
            if (t.items.items[i]) |have| if (std.mem.eql(u8, have, id)) t.close(i);
        }
    }

    /// Whether `split(axis)` would split: no split yet, or one along `axis`
    /// with room for another pane (`can_split`).
    pub fn canSplit(t: *const Tabs, axis: Axis) bool {
        const s = t.layout() orelse return true;
        return s.axis == axis and s.panes.items.len < max_panes;
    }

    /// `id` out of every pane and every other tab, which are left on a new
    /// chat: dragged into a new pane, a chat moves rather than shows twice
    /// (`detach_chat_from_tab_snapshots`).
    pub fn detach(t: *Tabs, id: []const u8) void {
        for (t.splits.items) |*sp| if (sp.*) |*s| for (s.panes.items) |*p| if (p.*) |have| if (std.mem.eql(u8, have, id)) {
            t.gpa.free(have);
            p.* = null;
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
    }

    /// ⌘W in a split: the focused pane closes, its share to the pane before
    /// it (or after, for the first), or all even again if they were; one
    /// pane left is no split. False with no split to close a pane of.
    pub fn closePane(t: *Tabs) bool {
        const s = t.layout() orelse return false;
        if (s.panes.items.len < 2) return false;
        if (t.items.items[t.active]) |id| t.gpa.free(id);
        const even = s.isEven();
        const closed = s.focus;
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
        if (s.panes.items.len == 1) {
            // The pane left is the tab: its parked draft goes with it.
            dropDraft(t.gpa, &t.drafts.items[t.active]);
            t.drafts.items[t.active] = s.drafts.items[0];
            s.drafts.items[0] = null;
            s.deinit(t.gpa);
            t.splits.items[t.active] = null;
        }
        return true;
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
    // "a", open in the first tab, dragged in: that tab is left on a new chat.
    t.detach("a");
    t.setCurrent("a");
    try testing.expectEqualStrings("a", t.current().?);
    try testing.expect(t.items.items[0] == null);
    try testing.expectEqualStrings("b", t.layout().?.panes.items[0].?);
}
