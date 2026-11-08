//! Expanded desktop tools are the task tree itself, not a second list.
//! Results and chevrons share one row; details keep the tree's text edge.
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const tr = @import("transcript.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tools = @import("tools.zig");
const rules = @import("tool_rows.zig");
const chrome = @import("view_tool_rows.zig");
const state = @import("tool_ui_state.zig");
const transcript_view = @import("view_transcript.zig");
const file_icons = @import("file_icons.zig");

const Arrival = struct {
    row: state.Row = .{},
    progress: f32 = 1,
    connector: f32 = 1,
    next: ?f32 = null,
    predecessor: bool = false,
};

pub fn group(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, tail: bool, parent: ?[]const u8) void {
    const key = c.print("{s}/{s}/{s}", .{ parent orelse "", e.id, parts[0].id });
    const legacy = c.print("{s}/{s}", .{ e.id, parts[0].id });
    // Current GPUI on macOS keeps work behind its summary even at the
    // streaming tail; other desktop platforms retain tail auto-open.
    const auto = tail and builtin.os.tag != .macos;
    const open = a.view.groups.get(key) orelse a.view.groups.get(legacy) orelse auto;
    const box = ui.div(c).column().wFull();
    defer box.end();
    const arrivals = c.alloc().alloc(Arrival, parts.len) catch return;
    for (parts, arrivals, 0..) |p, *arrival, i| {
        const id = state.key(parent, e.id, p.id);
        const r = a.view.tool_ui.observe(a.gpa, id, e.status != .streaming or (p.kind != .reasoning and p.resolved), e.status == .streaming, c.time, 0.090 + @as(f64, @floatFromInt(@min(i, 12))) * 0.065);
        arrival.* = .{ .row = r, .progress = rules.rowProgress(r.reveal, c.time, c.reduced_motion), .connector = rules.connectorProgress(r.reveal, c.time, c.reduced_motion), .predecessor = i > 0 };
    }
    for (arrivals, 0..) |*arrival, i| if (i + 1 < arrivals.len) {
        arrival.next = arrivals[i + 1].connector;
    };
    {
        const h = kit.pressFeedback(ui.div(c).row().h(26).gap(6).pr(4).itemsCenter().rounded(4).control().hover(k.wash(0.04)));
        defer h.end();
        if (h.clicked()) a.view.toggleGroup(a.gpa, key, open);
        const slot = ui.div(c).row().size(22, 18).center();
        chrome.chevron(c, k, open, 14);
        slot.end();
        const buf = c.alloc().alloc(u8, 320) catch return;
        const active = e.status == .streaming and for (parts) |p| {
            if (p.kind == .reasoning or (p.kind == .tool and !p.resolved)) break true;
        } else false;
        chrome.title(c, k, tools.label(buf, parts), active, h.hovered());
    }
    const fold_id = state.key(parent, key, "group-fold");
    const initial_height = 2 + @as(f32, @floatFromInt(parts.len)) * rules.row_height + rules.footer_gap + rules.footer_height;
    const fold = a.view.tool_ui.fold(a.gpa, fold_id, open, if (a.view.tool_ui.folds.contains(fold_id)) 0 else initial_height, c.time, c.reduced_motion);
    if (!open and !fold.animating(c.time, c.reduced_motion)) return;
    var viewport = ui.div(c).column().wFull().clip();
    if (fold.natural > 0) viewport = viewport.h(fold.height(c.time, c.reduced_motion));
    defer viewport.end();
    const children = ui.div(c).column().wFull().pt(2);
    defer children.end();
    rememberHeight(c, a, fold_id, children.index);
    if (fold.animating(c.time, c.reduced_motion)) c.frameIn(1.0 / 30.0);
    for (parts, arrivals) |*p, arrival| {
        ui.key(c, c.print("tool-{s}", .{p.id}));
        rowImpl(c, a, k, e, p, parent, arrival);
        if ((arrival.progress < 1 or arrival.connector < 1) and !c.reduced_motion) c.frameIn(1.0 / 30.0);
    }
    const footer = ui.div(c).row().wFull().h(rules.footer_height + rules.footer_gap).pt(rules.footer_gap).pl(56).gap(12).itemsCenter();
    defer footer.end();
    {
        const summary = ui.div(c).row().grow().w(0).clip();
        defer summary.end();
        if (e.status != .streaming or !rules.live(parts)) chrome.summary(c, k, rules.diffs(c.alloc(), parts));
    }
    if (parent) |chat| {
        const access = kit.pressFeedback(ui.div(c).row().h(rules.footer_height).px(6).gap(5).itemsCenter().rounded(6).control().hover(k.ink(0.06)));
        defer access.end();
        icons.icon(c, .widget, 12, k.faint, 0);
        ui.text(c, "Tool access", kit.style(c, 11, 18, .{ .color = if (access.hovered()) k.text else k.faint }));
        if (access.clicked()) @import("view_tool_access.zig").open(a, chat);
    }
}

pub fn row(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, last: bool, parent: ?[]const u8) void {
    rowImpl(c, a, k, e, p, parent, .{ .next = if (last) null else 1 });
}

fn rowImpl(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, parent: ?[]const u8, arrival: Arrival) void {
    const agent_linked = p.agent and p.subagent_ref.len > 0 and p.subagent_title.len > 0 and parent != null;
    const view_linked = p.saved_view != null and parent != null;
    const linked = agent_linked or view_linked;
    const ordinary = p.kind == .tool and !p.agent and !view_linked;
    const detail_key = c.print("detail/{s}/{s}/{s}", .{ parent orelse "", e.id, p.id });
    const has_detail = !linked and (p.kind == .reasoning or p.invocation.len > 0 or p.output.len > 0 or p.output_ref.len > 0 or p.diff_new != null or p.stats.len > 0);
    const open = has_detail and a.view.groupOpen(detail_key, p.kind == .reasoning);
    // Older snapshots can omit resolved, but a finished turn cannot still
    // be running. Keep any real result without inventing a start time.
    var effective = p.*;
    if (e.status != .streaming) effective.resolved = true;
    const result = if (ordinary) rules.result(c.alloc(), &effective, if (e.status == .streaming) arrival.row.elapsed(c.time) else null) else rules.Result.settled;
    const running = ordinary and result == .running;
    var wrapper = ui.div(c).column().wFull();
    if (arrival.progress < 1) wrapper = wrapper.h(rules.row_height * arrival.progress).clip();
    defer wrapper.end();
    var r = ui.div(c).row().wFull().itemsStart().gap(2);
    if (linked) r = kit.pressFeedback(r.control().rounded(4).hover(k.ink(0.04)));
    defer r.end();
    if (linked and r.clicked()) {
        if (agent_linked) @import("app_subagents.zig").open(a, parent.?, p) else @import("app_browser.zig").openSaved(a, parent.?, p.saved_view.?);
    }
    const previous = c.rects.get(c.node(r.index).id);
    const height = if (previous) |rect| @max(rect.h, rules.row_height) else rules.row_height;
    {
        const rail = ui.div(c).column().absolute();
        defer rail.end();
        chrome.rail(c, k, toolIcon(p), p.is_error, height, arrival.connector, arrival.next, arrival.predecessor);
    }
    _ = c.leaf(.{ .width = .{ .px = rules.gutter }, .height = .{ .px = rules.row_height } }, .none, null);
    const content = ui.div(c).column().grow().w(0).py(2).motion(.{ .opacity = rules.connectorParts(arrival.connector, arrival.predecessor).branch, .y = -2 * (1 - arrival.progress) });
    defer content.end();
    {
        var head = ui.div(c).row().wFull().h(rules.row_height - 4).px(6).gap(8).itemsCenter().rounded(if (running) 8 else 4);
        if (running) head = head.bg(k.ink(0.06));
        if (has_detail) head = kit.pressFeedback(head.control().hover(k.ink(0.04)));
        defer head.end();
        if (has_detail and head.clicked()) a.view.toggleGroup(a.gpa, detail_key, p.kind == .reasoning);
        if (c.rects.get(c.node(head.index).id)) |rect| chrome.wash(c, k, result, rect.w, rules.row_height - 4, arrival.row.wash(c.time, c.reduced_motion));
        const color = if (p.is_error) k.danger else if (has_detail and head.hovered()) k.text else k.muted;
        ui.text(c, if (p.kind == .reasoning) "Thought process" else p.chip, kit.style(c, 15, 18, .{ .weight = if (p.agent) .medium else .regular, .color = color }));
        {
            const detail = ui.div(c).row().grow().w(0).clip().itemsCenter();
            defer detail.end();
            const rect = c.rects.get(c.node(detail.index).id);
            const room = if (rect) |b| b.w else 160;
            const raw = if (p.agent and p.text.items.len == 0) p.subagent_title else firstLine(p.text.items);
            // Quantize to desktop's 80ms pulse rather than allocating a
            // distinct path every render. No scramble with reduced motion.
            const tick: f32 = @floatCast(@mod(@floor(c.time / 0.080), 97) / 97);
            if (p.path.len > 0) {
                const name = file_icons.basename(p.path);
                fileBadge(c, a, k, p.path, if (running and !c.reduced_motion) rules.scramble(c.alloc(), name, tick) else name, room, parent);
            } else kit.fadeText(c, if (running and !c.reduced_motion) rules.scramble(c.alloc(), raw, tick) else raw, kit.style(c, if (ordinary) 12 else 15, 18, .{ .mono = ordinary, .color = k.muted }), @max(room, 0));
            if (running and !c.reduced_motion) kit.loaderFrame(c, 0.080);
        }
        // Reserving a real end column prevents a long command/path from
        // painting under either a result wash or the disclosure chevron.
        if (ordinary) chrome.trail(c, k, result, if (result.washed()) arrival.row.wash(c.time, c.reduced_motion) else 1);
        const slot = ui.div(c).row().size(18, 18).center();
        defer slot.end();
        if (linked) icons.icon(c, .@"arrow-up-right", 11, k.muted.alpha(0.8), 0) else if (has_detail) chrome.chevron(c, k, open, 12);
    }
    if (!has_detail) return;
    const fold_id = state.key(parent, detail_key, "detail-fold");
    const initial_height = 8 + @as(f32, @floatFromInt(@min(24, std.mem.count(u8, p.invocation, "\n") + @intFromBool(p.invocation.len > 0)) + @min(24, std.mem.count(u8, p.output, "\n") + @intFromBool(p.output.len > 0)) + p.stats.len)) * 18;
    const fold = a.view.tool_ui.fold(a.gpa, fold_id, open, if (a.view.tool_ui.folds.contains(fold_id)) 0 else initial_height, c.time, c.reduced_motion);
    if (!open and !fold.animating(c.time, c.reduced_motion)) return;
    var clip = ui.div(c).column().wFull().clip();
    if (fold.natural > 0) clip = clip.h(fold.height(c.time, c.reduced_motion));
    defer clip.end();
    const body = ui.div(c).column().wFull().pl(6).gap(4).pb(4);
    defer body.end();
    rememberHeight(c, a, fold_id, body.index);
    if (fold.animating(c.time, c.reduced_motion)) c.frameIn(1.0 / 30.0);
    if (p.kind == .reasoning) return @import("view_markdown.zig").withLinks(c, k, p.text.items, a, parent);
    if (p.invocation.len > 0) textDetail(c, k, p.invocation, false);
    if (p.diff_new) |new| return transcript_view.editDiff(c, k, p, new);
    if (p.stats.len > 0) return transcript_view.statRows(c, k, p.stats);
    const blob = a.tool_blobs.get(p.output_ref);
    const text = if (blob) |b| (if (b.status == .ready) b.text else p.output) else p.output;
    if (text.len > 0) textDetailLimit(c, k, text, p.is_error, if (blob != null and blob.?.status == .ready) 400 else 24);
    if (p.output_ref.len > 0 and (blob == null or blob.?.status != .ready)) {
        const loading = blob != null and blob.?.status == .loading;
        const action = ui.div(c).row().py(4).control();
        defer action.end();
        ui.text(c, if (loading) "Loading full output…" else if (blob != null and blob.?.status == .failed) "Retry full output" else "Show full output", .{ .size = 12, .color = k.muted });
        if (!loading and action.clicked()) a.fetchToolBlob(p.output_ref);
    }
}

pub fn rememberHeight(c: *ui.Context, a: *App, id: u64, index: u32) void {
    const f = a.view.tool_ui.folds.getPtr(id) orelse return;
    if (c.rects.get(c.node(index).id)) |rect| {
        if (@abs(rect.h - f.natural) > 0.5) {
            f.natural = rect.h;
            c.changed = true;
        }
    } else c.changed = true;
}

pub fn textDetail(c: *ui.Context, k: theme.Colors, text: []const u8, failed: bool) void {
    textDetailLimit(c, k, text, failed, 24);
}

pub fn textDetailLimit(c: *ui.Context, k: theme.Colors, text: []const u8, failed: bool, limit: usize) void {
    if (text.len == 0) return;
    const box = ui.div(c).column().wFull().py(4).clip();
    defer box.end();
    // Desktop's 24-line preview / 400-line expanded sidecar, with an
    // honest counted tail. Diffs have their separate 600-line ceiling.
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    const total = std.mem.count(u8, trimmed, "\n") + 1;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (n == limit) {
            ui.text(c, c.print("… {d} more lines", .{total - n}), .{ .size = 12, .color = k.faint });
            break;
        }
        n += 1;
        ui.text(c, if (line.len == 0) " " else line, kit.style(c, 12, 18, .{ .mono = true, .color = if (failed) k.danger else k.muted }));
    }
}

fn fileBadge(c: *ui.Context, a: *App, k: theme.Colors, path: []const u8, name: []const u8, width: f32, parent: ?[]const u8) void {
    const relative: ?[]const u8 = blk: {
        const chat_id = parent orelse break :blk null;
        if (a.selected == null or !std.mem.eql(u8, a.selected.?, chat_id)) break :blk null;
        const chat = a.findChat(chat_id) orelse break :blk null;
        break :blk rules.workspacePath(c.alloc(), chat.cwd orelse break :blk null, path);
    };
    var badge = ui.div(c).row().h(22).pl(1).pr(6).gap(6).itemsCenter().rounded(5).bg(k.ink(0.06));
    if (relative != null) badge = badge.control().hover(k.ink(0.10));
    defer badge.end();
    // A display-only badge must not claim the parent disclosure's hit.
    if (relative) |file| if (badge.clicked()) @import("app_files.zig").openFile(a, file);
    {
        const well = ui.div(c).row().size(20, 20).center().rounded(4).bg(ui.Color.hex(if (k.dark) 0x000000 else 0xffffff).alpha(0.16));
        defer well.end();
        file_icons.icon(c, path, false, k.dark, 14);
    }
    kit.fadeText(c, name, kit.style(c, 12, 18, .{ .mono = true, .color = k.muted }), @max(width - 33, 0));
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

pub fn toolIcon(p: *const tr.Part) icons.Name {
    if (p.kind == .reasoning) return .@"chat-round-line";
    if (p.agent or std.mem.eql(u8, p.chip, "Agent") or std.mem.eql(u8, p.chip, "Waiting on")) return .bot;
    return switch (p.tool) {
        .exec => .terminal,
        .readFile, .applyPatch => .document,
        .writeFile => .@"document-add",
        .editFile => .pen,
        .search => .magnifer,
        .glob => .@"folder-with-files",
        .webFetch, .webSearch => .global,
        .todo => .checklist,
        .mcp, .unknown => icons.namedTool(p.text.items),
    };
}
