//! Interactive inline Before & After design comparison cards for chat replies.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const images = @import("app_attachment_images.zig");
const panel_chrome = @import("view_panel_chrome.zig");
const reply_images = @import("view_reply_images.zig");

pub const Side = enum { before, after };
pub const Mode = enum { side_by_side, split };

pub const ParsedLabel = struct {
    side: Side,
    detail: []const u8,
};

pub const EntryState = struct {
    id: u64 = 0,
    mode: Mode = .side_by_side,
    split: f32 = 0.5,
    dragging: bool = false,
};

pub const State = struct {
    slots: [32]EntryState = @splat(.{}),
    count: usize = 0,
    next: usize = 0,

    pub fn entry(s: *State, id: u64) *EntryState {
        for (s.slots[0..s.count]) |*slot| {
            if (slot.id == id) return slot;
        }
        const ix = if (s.count < s.slots.len) blk: {
            const idx = s.count;
            s.count += 1;
            break :blk idx;
        } else blk: {
            const idx = s.next;
            s.next = (s.next + 1) % s.slots.len;
            break :blk idx;
        };
        s.slots[ix] = .{ .id = id };
        return &s.slots[ix];
    }
};

pub fn cardId(chat_id: ?[]const u8, a: []const u8, b: []const u8, d: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x42415f43415244);
    for ([_][]const u8{ chat_id orelse "", a, b, d }) |part| {
        h.update(std.mem.asBytes(&part.len));
        h.update(part);
    }
    return h.final();
}

/// Parses captions of the form "Before", "Before: <title>", "After — <title>", etc.
pub fn parseLabel(raw: []const u8) ?ParsedLabel {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const side: Side, const rest: []const u8 = if (startsWithIgnoreCase(trimmed, "before"))
        .{ .before, trimmed["before".len..] }
    else if (startsWithIgnoreCase(trimmed, "after"))
        .{ .after, trimmed["after".len..] }
    else
        return null;

    if (rest.len == 0) return .{ .side = side, .detail = "" };

    const after_ws = std.mem.trimStart(u8, rest, " \t");
    if (after_ws.len == 0) return .{ .side = side, .detail = "" };
    return parseWithSeparator(side, after_ws);
}

fn parseWithSeparator(side: Side, after_ws: []const u8) ?ParsedLabel {
    const body = if (after_ws[0] == ':' or after_ws[0] == '-')
        after_ws[1..]
    else if (std.mem.startsWith(u8, after_ws, "\xc2\xb7"))
        after_ws[2..]
    else if (std.mem.startsWith(u8, after_ws, "\xe2\x80\x93") or std.mem.startsWith(u8, after_ws, "\xe2\x80\x94"))
        after_ws[3..]
    else
        return null;
    return .{ .side = side, .detail = std.mem.trim(u8, body, " \t\r\n") };
}

fn startsWithIgnoreCase(hay: []const u8, prefix: []const u8) bool {
    if (hay.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..prefix.len], prefix);
}

/// Returns the pair title (possibly empty) iff `before_alt` is a Before label
/// and `after_alt` is an After label.
pub fn matchPair(before_alt: []const u8, after_alt: []const u8) ?[]const u8 {
    const b = parseLabel(before_alt) orelse return null;
    const a = parseLabel(after_alt) orelse return null;
    if (b.side != .before or a.side != .after) return null;
    return if (a.detail.len > 0) a.detail else b.detail;
}

pub fn drawPair(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    chat_id: ?[]const u8,
    id: u64,
    before_src: []const u8,
    before_alt: []const u8,
    after_src: []const u8,
    after_alt: []const u8,
    caption: []const u8,
    max_w: f32,
) void {
    const entry = a.view.before_after.entry(id);
    const card_w = @max(240, @min(max_w, 680));
    const chat = if (chat_id) |cid| a.findChat(cid) else null;
    const cwd = if (chat) |ch| ch.cwd else null;
    const before_path = reply_images.resolve(c.alloc(), cwd, before_src);
    const after_path = reply_images.resolve(c.alloc(), cwd, after_src);
    const before_img = if (before_path) |p| images.get(a, chat_id, p) else null;
    const after_img = if (after_path) |p| images.get(a, chat_id, p) else null;

    ui.key(c, c.print("design-before-after-{x}", .{id}));
    const card = ui.div(c).column().w(card_w).p(12).gap(10).rounded(12)
        .bg(if (k.dark) k.ink(0.03) else ui.Color.white.alpha(0.62))
        .border(panel_chrome.zenEdge(k)).borderW(1).clip();
    defer card.end();

    {
        const hdr = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer hdr.end();
        icons.icon(c, .@"split-columns", 14, k.accent, 0);
        ui.text(c, if (caption.len > 0) caption else "Before & after", kit.style(c, 13, 18, .{ .weight = theme.ui_medium_weight, .color = k.text }));
        ui.spacer(c);
        const seg = ui.div(c).row().p(2).gap(2).rounded(7).bg(k.ink(if (k.dark) 0.06 else 0.045));
        defer seg.end();
        if (segmentButton(c, k, "Side by side", entry.mode == .side_by_side)) {
            entry.mode = .side_by_side;
            entry.dragging = false;
            a.redraw();
        }
        if (segmentButton(c, k, "Split", entry.mode == .split)) {
            entry.mode = .split;
            a.redraw();
        }
    }

    const both_ready = (before_img != null and before_img.?.status == .ready) and
        (after_img != null and after_img.?.status == .ready);
    if (entry.mode == .split and both_ready) {
        drawSplit(c, a, k, before_img.?, after_img.?, entry, card_w - 26);
        return;
    }

    drawSideBySide(c, a, k, chat_id, before_img, before_alt, after_img, after_alt, card_w);
}

fn segmentButton(c: *ui.Context, k: theme.Colors, label: []const u8, active: bool) bool {
    ui.key(c, label);
    var btn = ui.div(c).row().h(22).px(8).itemsCenter().rounded(5).control();
    btn = if (active)
        btn.bg(if (k.dark) k.selected else ui.Color.white)
    else
        btn.hover(k.hover);
    defer btn.end();
    ui.text(c, label, kit.style(c, 11.5, 16, .{
        .weight = if (active) theme.ui_medium_weight else .regular,
        .color = if (active or btn.hovered()) k.text else k.muted,
    }));
    return btn.clicked();
}

fn drawSideBySide(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    chat_id: ?[]const u8,
    before_img: ?*images.Image,
    before_alt: []const u8,
    after_img: ?*images.Image,
    after_alt: []const u8,
    card_w: f32,
) void {
    const pane_w = @max(100, (card_w - 26 - 10) / 2);
    const row = ui.div(c).row().wFull().gap(10);
    defer row.end();
    drawPane(c, a, k, chat_id, "Before", false, before_img, before_alt, pane_w);
    drawPane(c, a, k, chat_id, "After", true, after_img, after_alt, pane_w);
}

fn drawPane(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    chat_id: ?[]const u8,
    badge: []const u8,
    accent: bool,
    loaded: ?*images.Image,
    alt: []const u8,
    pane_w: f32,
) void {
    ui.key(c, badge);
    const col = ui.div(c).column().grow().w(0).gap(6);
    defer col.end();
    {
        const tag_row = ui.div(c).row().wFull().itemsCenter();
        defer tag_row.end();
        const tag_bg = if (accent) k.accent_wash else k.ink(if (k.dark) 0.08 else 0.055);
        const tag_fg = if (accent) k.accent else k.muted;
        const tag = ui.div(c).row().h(20).px(7).itemsCenter().rounded(5).bg(tag_bg);
        defer tag.end();
        ui.text(c, badge, kit.style(c, 11, 15, .{ .weight = theme.ui_medium_weight, .color = tag_fg }));
    }
    const frame = ui.div(c).column().wFull().p(4).rounded(8)
        .bg(k.shell.alpha(if (k.dark) 0.55 else 0.45))
        .border(panel_chrome.zenEdge(k)).borderW(1).center().clip().control();
    defer frame.end();
    const img_max_w = if (c.rects.get(c.node(frame.index).id)) |r| @max(80, r.w - 8) else @max(80, pane_w - 8);
    if (loaded) |image| {
        if (image.status == .ready) {
            const key = imageKey(c, badge, image);
            if (ui.image(c, .{
                .key = key,
                .source = .{ .encoded = image.bytes.items },
                .max_width = img_max_w,
                .max_height = 280,
                .scale = 1,
                .radius = 6,
            })) {
                const pic = c.interact(@intCast(c.nodes.items.len - 1), .{ .focusable = true });
                if (pic.clicked or frame.clicked()) @import("view_image_preview.zig").open(a, chat_id, image);
                return;
            }
        } else if (image.status == .loading) {
            const loading = ui.div(c).row().wFull().h(120).center();
            defer loading.end();
            ui.text(c, "Loading image…", kit.style(c, 12, 16, .{ .color = k.muted }));
            return;
        }
    }
    const empty = ui.div(c).row().wFull().h(96).px(8).center();
    defer empty.end();
    ui.text(c, c.print("Image unavailable{s}{s}", .{ if (alt.len > 0) ": " else "", alt }), kit.style(c, 11.5, 16, .{ .color = k.muted, .wrap = true }));
}

fn drawSplit(
    c: *ui.Context,
    a: *App,
    k: theme.Colors,
    before_img: *images.Image,
    after_img: *images.Image,
    entry: *EntryState,
    avail_w: f32,
) void {
    const before_key = imageKey(c, "Before", before_img);
    const after_key = imageKey(c, "After", after_img);
    const natural = ui.imageSize(c, after_key, after_img.bytes.items) orelse ui.imageSize(c, before_key, before_img.bytes.items) orelse {
        _ = ui.image(c, .{ .key = after_key, .source = .{ .encoded = after_img.bytes.items }, .max_width = avail_w, .max_height = 420, .scale = 1, .radius = 8 });
        c.frameIn(0);
        return;
    };
    const fit = @min(avail_w / @max(1, natural.w), @as(f32, 420) / @max(1, natural.h));
    const stage_w = @max(120, natural.w * fit);
    const stage_h = @max(60, natural.h * fit);

    const stage_row = ui.div(c).row().wFull().center();
    defer stage_row.end();

    ui.key(c, "before-after-split-stage");
    const stage = ui.div(c).row().size(stage_w, stage_h).rounded(8).border(panel_chrome.zenEdge(k)).borderW(1).clip().control();
    defer stage.end();

    if (c.input.pressed and stage.hovered()) entry.dragging = true;
    if (!c.input.down) entry.dragging = false;
    if (entry.dragging or stage.clicked()) {
        if (c.rects.get(c.node(stage.index).id)) |sr| {
            entry.split = std.math.clamp((c.input.mouse.x - sr.x) / @max(1, sr.w), 0.05, 0.95);
            a.redraw();
        }
    }

    const split_w = @max(1, stage_w * entry.split);
    _ = ui.image(c, .{
        .key = after_key,
        .source = .{ .encoded = after_img.bytes.items },
        .box = .{ .w = stage_w, .h = stage_h },
    });
    {
        const overlay = ui.div(c).absolute().offset(0, 0).size(split_w, stage_h).clip();
        defer overlay.end();
        _ = ui.image(c, .{
            .key = before_key,
            .source = .{ .encoded = before_img.bytes.items },
            .box = .{ .w = split_w, .h = stage_h },
            .part = .{ 0, 0, entry.split, 1 },
        });
    }
    ui.div(c).absolute().offset(@max(0, split_w - 1), 0).size(2, stage_h).bg(k.accent).end();
    {
        const handle = ui.div(c).absolute().offset(std.math.clamp(split_w - 13, 2, stage_w - 28), @max(0, stage_h / 2 - 13))
            .size(26, 26).center().roundedFull().bg(k.background).border(k.accent).borderW(1.5);
        defer handle.end();
        ui.text(c, "‹›", kit.style(c, 11, 14, .{ .weight = .semibold, .color = k.text }));
    }
    cornerBadge(c, k, "Before", 8, false, 0);
    cornerBadge(c, k, "After", stage_w - 50, true, 0);
}

fn cornerBadge(c: *ui.Context, k: theme.Colors, label: []const u8, x: f32, accent: bool, _: f32) void {
    const bg = k.background.alpha(0.9);
    const border = if (accent) k.accent.alpha(0.45) else panel_chrome.zenEdge(k);
    const fg = if (accent) k.accent else k.text;
    const box = ui.div(c).absolute().offset(@max(8, x), 8).h(20).px(7).itemsCenter().rounded(5).bg(bg).border(border).borderW(1);
    defer box.end();
    ui.text(c, label, kit.style(c, 10.5, 14, .{ .weight = theme.ui_medium_weight, .color = fg }));
}

fn imageKey(c: *ui.Context, side: []const u8, image: *const images.Image) []const u8 {
    return c.print("before-after:{s}:{s}:{s}:{x}", .{ side, image.device, image.path, image.content_hash });
}

test "parseLabel and matchPair identify Before/After labels without matching normal prose" {
    const t = std.testing;
    try t.expectEqualStrings("", matchPair("Before", "After").?);
    try t.expectEqualStrings("Zen Settings header", matchPair("Before: Zen Settings header", "After: Zen Settings header").?);
    try t.expectEqualStrings("Header", matchPair("BEFORE — Header", "after — Header").?);
    try t.expectEqualStrings("Nav", matchPair("before · Nav", "After").?);
    try t.expect(matchPair("After", "Before") == null);
    try t.expect(matchPair("Before screenshot", "After screenshot") == null);
    try t.expect(matchPair("build pane", "test output") == null);
}
