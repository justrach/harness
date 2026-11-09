//! The open chat's transcript, as the GPUI transcript draws it
//! (crates/ui/src/transcript.rs): a centred column 736 points wide, the
//! user's messages as bubbles on the right, the agent's Markdown, its tool
//! calls and reasoning folded into groups ("Ran 2 commands"), errors as
//! chips, and under each message a lane whose copy button shows on hover.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tools = @import("tools.zig");
const tr = @import("transcript.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

/// The column's width (`transcript_width`'s default).
pub const column_w: f32 = 736;

/// The column's width in a main area `w` wide, with its gutters.
pub fn columnWidth(w: f32) f32 {
    const gutter = std.math.clamp(w * 0.06, 12, 48);
    return @max(@min(column_w, w - 2 * gutter), 200);
}

/// The chat column's width: the window less the sidebar and the panels.
pub fn mainWidth(c: *ui.Context, a: *const App) f32 {
    var w = c.size.w - (if (a.view.sidebar_open) sidebar.width + 1 else 0);
    if (a.selected != null and a.panels.host_open) w -= @import("view_host.zig").width + 1;
    if (a.selected != null and a.panels.files_open) w -= @import("view_files.zig").width + 1;
    return @max(w, 300);
}

pub fn transcript(c: *ui.Context, a: *App, k: theme.Colors) void {
    const col = columnWidth(mainWidth(c, a));
    // The first row sits 64 points down the window, under the title bar.
    // Rows settle at the bottom, over the composer, until they fill it.
    const scroll = c.open(.{ .grow = 1, .width = .fill, .padding = .{ .top = 64 - sidebar.titlebar_h, .bottom = 24 + 8 + 10 }, .align_items = .center, .justify = .end, .follow_end = true, .scroll = true, .direction = .column }, null);
    defer ui.end(c);
    const scroll_rect = c.rects.get(c.node(scroll).id);
    const body = ui.div(c).column().w(col);
    defer body.end();
    const entries = a.transcript.entries.items;
    if (entries.len == 0) {
        const e = ui.div(c).row().wFull().pt(40).justifyCenter();
        defer e.end();
        ui.text(c, if (a.w_doc.id != null) "Loading…" else "Nothing here yet.", .{ .size = 13, .color = k.faint });
        return;
    }
    const streaming = entries[entries.len - 1].status == .streaming;
    for (entries, 0..) |*e, i| {
        if (i > 0) _ = c.leaf(.{ .height = .{ .px = if (e.role == .user) 16 else 8 } }, .none, null);
        ui.key(c, c.print("entry-{s}", .{e.id}));
        const prev = c.rects.get(c.peekId(null));
        if (prev) |r| if (r.h > 0) {
            e.cached_h = r.h;
        };
        if (streaming and i + 2 < entries.len and e.status != .streaming and e.cached_h > 0) {
            if (scroll_rect) |view| if (prev) |r| {
                if (r.y + r.h < view.y - 600 or r.y > view.y + view.h + 600) {
                    _ = c.leaf(.{ .width = .fill, .height = .{ .px = e.cached_h } }, .none, null);
                    continue;
                }
            };
        }
        switch (e.role) {
            .user => user(c, k, e, col),
            .assistant => assistant(c, a, k, e, i + 1 == entries.len),
            .system => system(c, k, e),
        }
    }
}

fn user(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, col: f32) void {
    const wrap = ui.div(c).column().wFull().itemsEnd();
    defer wrap.end();
    const hovered = wrap.hovered();
    {
        const bubble = ui.div(c).column().maxW(col * 0.8).bg(k.user_bubble).rounded(16).px(16).py(10).gap(6);
        defer bubble.end();
        const st = kit.style(c, 14, 22, .{ .wrap = true, .color = k.text });
        for (e.parts.items) |*p| switch (p.kind) {
            .text => ui.text(c, p.text.items, st),
            .image => attachment(c, k, .document, p.text.items),
            else => {},
        };
    }
    lane(c, k, e, hovered, true);
}

/// Under a message: 32 points held for its copy button, shown on hover.
fn lane(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, hovered: bool, right: bool) void {
    var l = ui.div(c).row().wFull().h(32).pt(8);
    if (right) l = l.justifyEnd();
    defer l.end();
    if (!hovered) return;
    if (kit.iconButton(c, k, .copy, .{ .size = 24, .radius = 6, .icon = 14 })) {
        var text: std.ArrayList(u8) = .empty;
        for (e.parts.items) |*p| if (p.kind == .text) {
            if (text.items.len > 0) text.appendSlice(c.alloc(), "\n\n") catch {};
            text.appendSlice(c.alloc(), p.text.items) catch {};
        };
        c.clipboard.write(c.clipboard.ctx, text.items);
    }
}

fn assistant(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, last: bool) void {
    const col = ui.div(c).column().wFull().gap(12);
    defer col.end();
    const hovered = col.hovered();
    var buf: [256]tools.Run = undefined;
    const rs = tools.runs(&buf, e.parts.items);
    for (rs, 0..) |r, i| {
        const p = &e.parts.items[r.start];
        ui.key(c, c.print("run-{s}-{s}", .{ e.id, p.id }));
        if (r.group) {
            const tail = e.status == .streaming and last and i + 1 == rs.len;
            group(c, a, k, e, e.parts.items[r.start..r.end], tail);
            continue;
        }
        switch (p.kind) {
            .text => @import("view_markdown.zig").markdown(c, k, p.text.items),
            .@"error" => errorChip(c, k, p.text.items),
            .image => attachment(c, k, .document, p.text.items),
            .visual => attachment(c, k, .widget, p.text.items),
            .delegation => attachment(c, k, .widget, "Delegated to a subagent"),
            .input => {
                const q = if (p.questions.len > 0) p.questions[0] else null;
                const label = if (q) |x| (if (x.question.len > 0) x.question else x.header) else "Question";
                @import("view_question.zig").chip(c, k, label, p.resolved);
            },
            else => {},
        }
    }
    if (e.status == .streaming and e.parts.items.len == 0) ui.text(c, "Working…", .{ .size = 12, .color = k.muted });
    if (e.status != .streaming) lane(c, k, e, hovered, false);
}

const row_h: f32 = 32;
const tree_w: f32 = 48;

/// A run of tool calls and reasoning, folded under one line; it opens on
/// its own while it is the tail of a streaming reply.
fn group(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, tail: bool) void {
    const key = c.print("{s}/{s}", .{ e.id, parts[0].id });
    const open = a.view.groupOpen(key, tail);
    const box = ui.div(c).column().wFull();
    defer box.end();
    {
        const h = ui.div(c).row().h(26).gap(6).pr(4).itemsCenter();
        defer h.end();
        if (h.clicked()) a.view.toggleGroup(a.gpa, key, tail);
        const slot = ui.div(c).row().size(22, 18).center();
        icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 14, k.muted, 0);
        slot.end();
        const lb = c.alloc().alloc(u8, 160) catch return;
        ui.text(c, tools.label(lb, parts), kit.style(c, 12, 18, .{ .color = if (h.hovered()) k.text else k.muted }));
    }
    if (!open) return;
    for (parts, 0..) |*p, i| {
        ui.key(c, c.print("tool-{s}", .{p.id}));
        treeRow(c, k, p, i + 1 == parts.len);
    }
}

/// One call in an open group: the tree's trunk and elbow, its icon, its
/// chip and what it ran.
fn treeRow(c: *ui.Context, k: theme.Colors, p: *const tr.Part, last: bool) void {
    const line = k.wash(0.12);
    const r = ui.div(c).row().wFull().gap(8).itemsStart();
    defer r.end();
    {
        const g = ui.div(c).column().w(tree_w).h(row_h);
        defer g.end();
        // Trunk down from the header (to the elbow on the last row), then
        // the branch out to the icon.
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = if (last) row_h / 2 else row_h }, .background = line, .absolute = true, .offset = .{ .x = 12, .y = 0 } }, .none, null);
        _ = c.leaf(.{ .width = .{ .px = 15 }, .height = .{ .px = 1 }, .background = line, .absolute = true, .offset = .{ .x = 13, .y = row_h / 2 } }, .none, null);
        const ic = ui.div(c).row().absolute().offset(30, (row_h - 18) / 2);
        defer ic.end();
        icons.icon(c, toolIcon(p), 16, if (p.is_error) k.danger else k.muted, 18);
    }
    const body = ui.div(c).column().grow().w(0).justifyCenter().gap(4).py(7);
    defer body.end();
    const head = ui.div(c).row().gap(8).itemsCenter();
    {
        defer head.end();
        const chip = if (p.kind == .reasoning) "Thought process" else p.chip;
        ui.text(c, chip, .{ .size = 12, .weight = .medium, .color = k.text.alpha(0.8) });
        if (p.kind == .tool) {
            const d = firstLine(p.text.items);
            kit.fadeText(c, d, .{ .size = 12, .mono = p.tool == .exec, .color = if (p.is_error) k.danger else k.muted }, 560);
            if (!p.resolved) kit.snake(c, k);
        }
    }
    if (p.kind == .reasoning) {
        const lines = limitLines(p.text.items, 24);
        ui.text(c, lines, kit.style(c, 12, 18, .{ .wrap = true, .italic = true, .color = k.muted }));
    }
}

fn toolIcon(p: *const tr.Part) icons.Name {
    if (p.kind == .reasoning) return .@"magic-stick-3";
    return switch (p.tool) {
        .exec => .terminal,
        .readFile => .document,
        .writeFile, .editFile, .applyPatch => .pen,
        .search, .glob => .magnifer,
        .webFetch, .webSearch => .globe,
        .todo => .checklist,
        .mcp, .unknown => .widget,
    };
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn limitLines(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    for (s, 0..) |ch, i| if (ch == '\n') {
        count += 1;
        if (count == n) return s[0..i];
    };
    return s;
}

/// An error, as the transcript's notice chip draws it (`notice.rs`).
fn errorChip(c: *ui.Context, k: theme.Colors, message: []const u8) void {
    const outer = ui.div(c).column().wFull().py(4);
    defer outer.end();
    const chip = ui.div(c).column().wFull().rounded(10).px(10).py(8).gap(6).border(k.danger.alpha(0.16)).borderW(1).bg(k.danger.alpha(0.05));
    defer chip.end();
    {
        const h = ui.div(c).row().gap(6).itemsCenter();
        defer h.end();
        const tile = ui.div(c).row().size(20, 20).center().rounded(6).bg(k.danger.alpha(0.12));
        icons.icon(c, .@"danger-triangle", 12, k.danger_muted.alpha(0.8), 0);
        tile.end();
        ui.text(c, "Error", .{ .size = 12, .weight = .medium, .color = k.danger_muted.alpha(0.8) });
    }
    ui.text(c, message, kit.style(c, 12, 18, .{ .wrap = true, .color = k.text.alpha(0.8) }));
}

fn attachment(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8) void {
    const row = ui.div(c).row().gap(6).itemsCenter();
    defer row.end();
    icons.icon(c, icon, 14, k.muted, 0);
    ui.text(c, label, .{ .size = 12, .color = k.muted });
}

fn system(c: *ui.Context, k: theme.Colors, e: *const tr.Entry) void {
    for (e.parts.items) |*p| switch (p.kind) {
        .text => ui.text(c, p.text.items, kit.style(c, 12, 18, .{ .wrap = true, .color = k.faint })),
        .@"error" => errorChip(c, k, p.text.items),
        else => {},
    };
}
