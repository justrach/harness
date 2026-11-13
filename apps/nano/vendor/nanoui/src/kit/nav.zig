//! Finding your way: tabs (underline, pill, segmented or outline), whose
//! marker slides to the tab chosen; breadcrumbs; pagination with ellipses;
//! and collapsibles and accordions, which open to their content's height
//! and close back, by `ui.motion`.
const std = @import("std");
const ui = @import("../ui/ui.zig");
const kit = @import("kit.zig");
const motion = ui.motion;

/// `glass`: a bar of Liquid Glass with a tinted lens of glass that slides.
pub const TabsVariant = enum { underline, pill, segmented, outline, glass };

/// A row of tabs; true when `selected.*` changed.
pub fn tabs(c: *ui.Context, items: []const []const u8, selected: *usize, opts: struct { variant: TabsVariant = .underline, size: kit.Size = .md }) bool {
    const t = kit.tokens(c);
    const size = opts.size.text();
    var bar = ui.div(c).row().itemsCenter();
    bar = switch (opts.variant) {
        .underline => bar.gap(18).wFull(),
        .pill => bar.gap(4),
        .segmented => bar.gap(2).p(3).rounded(t.radius).bg(t.surface_hover),
        .outline => bar.gap(4),
        .glass => bar.gap(2).p(4).roundedFull().glass(.{}),
    };
    const bar_rect = bar.interaction().rect;
    defer bar.end();
    // The marker first, so the tabs draw over it: under or behind the
    // tab chosen, as it was laid out last frame.
    if (bar_rect) |br| if (selected.* < items.len) {
        const tab_id = c.peekId(c.print("tab-{d}", .{selected.*}));
        if (c.rects.get(tab_id)) |r| {
            ui.key(c, "marker");
            const f = motion.frame(c, .{ .target = .{ .x = r.x - br.x, .width = r.w }, .transition = .{ .spring = motion.Spring.snappy } });
            const m = switch (opts.variant) {
                .underline => ui.div(c).absolute().offset(0, br.h - 2).h(2).rounded(1).bg(t.primary),
                .pill => ui.div(c).absolute().offset(0, (br.h - r.h) / 2).h(r.h).rounded(r.h / 2).bg(t.primary),
                .segmented => ui.div(c).absolute().offset(-3, (br.h - r.h) / 2 - 3).h(r.h).rounded(t.radius - 2).bg(t.surface).shadow(.{ .color = t.shadow.alpha(0.6), .blur = 3, .y = 1 }),
                .outline => ui.div(c).absolute().offset(0, (br.h - r.h) / 2).h(r.h).rounded(t.radius).border(t.primary),
                .glass => ui.div(c).absolute().offset(-4, (br.h - r.h) / 2 - 4).h(r.h).roundedFull().glass(.{ .tint = t.primary.alpha(0.55) }),
            };
            const marker = m.motion(f);
            marker.end();
        }
    };
    if (opts.variant == .underline) {
        // The rule under all the tabs.
        if (bar_rect) |br| _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 0, .y = br.h - 1 }, .width = .fill, .height = .{ .px = 1 }, .background = t.border }, .none, null);
    }
    var changed = false;
    for (items, 0..) |label, i| {
        ui.key(c, c.print("tab-{d}", .{i}));
        const on = i == selected.*;
        var tab = ui.div(c).row().itemsCenter().control();
        tab = if (opts.variant == .underline) tab.py(8) else tab.h(opts.size.height() - 6).px(size * 0.9);
        const it = tab.interaction();
        defer tab.end();
        if (it.clicked and !on) {
            selected.* = i;
            changed = true;
            c.changed = true;
        }
        const fg = switch (opts.variant) {
            .pill => if (on) t.primary_foreground else t.muted,
            .outline => if (on) t.primary else t.muted,
            .glass => if (on) t.primary_foreground else t.foreground,
            else => if (on) t.foreground else t.muted,
        };
        ui.text(c, label, .{ .size = size, .weight = if (on) .semibold else .medium, .color = if (it.hovered and !on) fg.mix(t.foreground, 0.5) else fg });
    }
    return changed;
}

/// A trail of places; the index clicked (the last, where you are, isn't).
pub fn breadcrumb(c: *ui.Context, items: []const []const u8) ?usize {
    const t = kit.tokens(c);
    const r = ui.div(c).row().gap(6).itemsCenter();
    defer r.end();
    var clicked: ?usize = null;
    for (items, 0..) |label, i| {
        ui.key(c, c.print("crumb-{d}", .{i}));
        const last = i + 1 == items.len;
        if (last) {
            ui.text(c, label, .{ .size = 13, .weight = .medium, .color = t.foreground });
            break;
        }
        const b = ui.div(c).control();
        const it = b.interaction();
        ui.text(c, label, .{ .size = 13, .color = if (it.hovered) t.foreground else t.muted });
        b.end();
        if (it.clicked) clicked = i;
        ui.icon(c, "chevron.right", .{ .size = 9, .color = t.muted });
    }
    return clicked;
}

/// Pages 1 to `pages` (`page.*` counts from 0): previous, numbers with "…"
/// where they're many, next. True when the page changed.
pub fn pagination(c: *ui.Context, page: *usize, pages: usize) bool {
    if (pages == 0) return false;
    const r = ui.div(c).row().gap(4).itemsCenter();
    defer r.end();
    const before = page.*;
    ui.key(c, "prev");
    if (kit.iconButton(c, "chevron.left", .{ .size = .sm, .disabled = page.* == 0 }).clicked) page.* -= 1;
    var shown: [9]?usize = @splat(null);
    const n = slots(page.*, pages, &shown);
    for (shown[0..n], 0..) |s, k| {
        ui.key(c, c.print("pg-{d}", .{k}));
        const p = s orelse {
            const gap = ui.div(c).w(22).center();
            ui.text(c, "…", .{ .size = 13, .color = kit.tokens(c).muted });
            gap.end();
            continue;
        };
        if (kit.button(c, c.print("{d}", .{p + 1}), .{ .size = .sm, .variant = if (p == page.*) .primary else .ghost }).clicked) page.* = p;
    }
    ui.key(c, "next");
    if (kit.iconButton(c, "chevron.right", .{ .size = .sm, .disabled = page.* + 1 >= pages }).clicked) page.* += 1;
    if (page.* != before) c.changed = true;
    return page.* != before;
}

/// Which pages to show (null: "…"): the first, the last, and five around
/// the current one, at most nine slots.
pub fn slots(page: usize, pages: usize, out: *[9]?usize) usize {
    if (pages <= 9) {
        for (0..pages) |i| out[i] = i;
        return pages;
    }
    const lo = std.math.clamp(page -| 2, 1, pages - 6);
    const hi = lo + 4;
    var n: usize = 0;
    const put = struct {
        fn f(o: *[9]?usize, k: *usize, v: ?usize) void {
            o[k.*] = v;
            k.* += 1;
        }
    }.f;
    put(out, &n, 0);
    if (lo == 2) put(out, &n, 1) else if (lo > 2) put(out, &n, null);
    for (lo..hi + 1) |p| put(out, &n, p);
    if (hi + 3 == pages) put(out, &n, pages - 2) else if (hi + 3 < pages) put(out, &n, null);
    put(out, &n, pages - 1);
    return n;
}

/// An open section's content: draw in it, then `end`.
pub const Section = struct {
    outer: ui.Div,
    inner: ui.Div,
    pub fn end(s: Section) void {
        s.inner.end();
        s.outer.end();
    }
};

/// A titled section that opens to what's in it (draw that, then `end` the
/// section) while `open.*`; clicking the title toggles it.
pub fn collapsible(c: *ui.Context, id: []const u8, title: []const u8, open: *bool) ?Section {
    const t = kit.tokens(c);
    {
        ui.key(c, c.print("{s}-head", .{id}));
        const head = ui.div(c).row().wFull().gap(8).py(10).itemsCenter().control();
        const it = head.interaction();
        defer head.end();
        if (it.clicked) {
            open.* = !open.*;
            c.changed = true;
        }
        ui.text(c, title, .{ .size = 13.5, .weight = .medium, .color = t.foreground });
        ui.spacer(c);
        ui.icon(c, if (open.*) "chevron.up" else "chevron.down", .{ .size = 11, .color = t.muted });
    }
    return body(c, id, open.*);
}

/// The box that opens to its content's height.
fn body(c: *ui.Context, id: []const u8, open: bool) ?Section {
    // The content's height, as laid out last frame (its box is clipped).
    const inner_key = c.print("{s}-inner", .{id});
    c.next_key = c.print("{s}-body", .{id});
    const outer_id = c.peekId(null);
    c.next_key = null;
    var h: f32 = 0;
    if (c.rects.get(outer_id) != null) {
        // The inner box is the outer's only child: its id follows from it.
        var hash = std.hash.Wyhash.init(outer_id);
        hash.update(inner_key);
        if (c.rects.get(hash.final())) |r| h = r.h;
    }
    const f = motion.present(c, c.print("{s}-body", .{id}), open, .{
        .initial = .{ .height = 0, .opacity = 0 },
        .target = .{ .height = h, .opacity = 1 },
        .exit = .{ .height = 0, .opacity = 0 },
        .transition = .{ .tween = .{ .duration = 0.22, .ease = .ease_in_out } },
    }) orelse return null;
    const outer = ui.div(c).column().wFull().clip().motion(f);
    ui.key(c, inner_key);
    const inner = ui.div(c).column().wFull().gap(8).pb(10);
    return .{ .outer = outer, .inner = inner };
}

/// One section of an accordion: open when `open.*` is `index`; opening
/// it closes the one that was.
pub fn accordion(c: *ui.Context, id: []const u8, title: []const u8, index: usize, open: *?usize) ?Section {
    var on = open.* == index;
    const b = collapsible(c, id, title, &on);
    if (on and open.* != index) open.* = index;
    if (!on and open.* == index) open.* = null;
    return b;
}

test "pagination: the ends, those near, and ellipses" {
    var out: [9]?usize = undefined;
    try std.testing.expectEqual(@as(usize, 5), slots(0, 5, &out));
    const n = slots(10, 20, &out);
    try std.testing.expectEqualSlices(?usize, &.{ 0, null, 8, 9, 10, 11, 12, null, 19 }, out[0..n]);
    const first = slots(0, 20, &out);
    try std.testing.expectEqualSlices(?usize, &.{ 0, 1, 2, 3, 4, 5, null, 19 }, out[0..first]);
}
