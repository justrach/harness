//! Source-byte selection snapshots for native accessibility consumers.
//! Read the current tree, not the paint cache: selected endpoints and
//! intermediate paragraphs may be outside the visible viewport.
const std = @import("std");
const Context = @import("context.zig").Context;
const types = @import("types.zig");

pub const Snapshot = struct {
    value: []const u8,
    range: [2]usize,
    field_id: ?u64 = null,
    rect: types.Rect = .{},

    pub fn selected(s: Snapshot) []const u8 {
        return s.value[s.range[0]..s.range[1]];
    }
};

pub fn field(c: *const Context) ?Snapshot {
    const f = c.focused_text orelse return null;
    if (f.anchor > f.text.len or f.caret > f.text.len) return null;
    return .{ .value = f.text, .range = .{ @min(f.anchor, f.caret), @max(f.anchor, f.caret) }, .field_id = f.id };
}

const Gather = struct {
    value: std.ArrayList(u8) = .empty,
    anchor: ?usize = null,
    focus: ?usize = null,
    anchor_index: u32 = 0,

    fn walk(g: *Gather, c: *const Context, arena: std.mem.Allocator, ix: u32, inherited: bool) !void {
        const n = c.nodes.items[ix];
        const selectable = (inherited or n.style.selectable) and !n.style.control;
        if (selectable and n.content == .text and n.content.text.str.len > 0) {
            const str = n.content.text.str;
            if (g.value.items.len > 0) try g.value.append(arena, '\n');
            const base = g.value.items.len;
            if (c.selection.anchor.?.id == n.id and c.selection.anchor.?.at <= str.len) {
                g.anchor = base + c.selection.anchor.?.at;
                g.anchor_index = ix;
            }
            if (c.selection.focus.?.id == n.id and c.selection.focus.?.at <= str.len) g.focus = base + c.selection.focus.?.at;
            try g.value.appendSlice(arena, str);
        }
        var child = n.first_child;
        while (child != std.math.maxInt(u32)) : (child = c.nodes.items[child].next) try g.walk(c, arena, child, selectable);
    }
};

/// All selectable source text in reading order, with the selected byte
/// range inside it. Allocation belongs to the caller's short-lived arena.
pub fn page(c: *const Context, arena: std.mem.Allocator) !?Snapshot {
    const a = c.selection.anchor orelse return null;
    const b = c.selection.focus orelse return null;
    if (std.meta.eql(a, b) or c.nodes.items.len == 0) return null;
    var g: Gather = .{};
    try g.walk(c, arena, 0, false);
    const start = g.anchor orelse return null;
    const end = g.focus orelse return null;
    if (start == end) return null;
    var ix = g.anchor_index;
    var rect = c.nodes.items[ix].rect;
    while (ix != 0) {
        const n = c.nodes.items[ix];
        if (n.style.scroll) {
            rect = n.rect;
            break;
        }
        ix = n.parent;
    }
    return .{ .value = g.value.items, .range = .{ @min(start, end), @max(start, end) }, .rect = rect };
}

/// Match Copy ownership: a nonempty focused editor selection wins; an
/// empty composer caret must not hide a selected transcript or question.
pub fn active(c: *const Context, arena: std.mem.Allocator) !?Snapshot {
    const f = field(c);
    if (f) |s| if (s.range[0] != s.range[1]) return s;
    return (try page(c, arena)) orelse f;
}

/// Only selection ownership/ranges change the notification key. Painting,
/// hovering and streaming beyond a selected range do not repeatedly move
/// native focus or announce a fresh selection.
pub fn key(c: *const Context) u64 {
    var h: std.hash.Wyhash = .init(0x4158_5345_4c45_4354);
    for ([_]?@import("selection.zig").Point{ c.selection.anchor, c.selection.focus }) |point| {
        if (point) |p| {
            h.update(&.{1});
            h.update(std.mem.asBytes(&p.id));
            h.update(std.mem.asBytes(&p.at));
        } else h.update(&.{0});
    }
    if (c.focused_text) |f| {
        h.update(std.mem.asBytes(&f.id));
        h.update(std.mem.asBytes(&f.anchor));
        h.update(std.mem.asBytes(&f.caret));
    }
    return h.final();
}
