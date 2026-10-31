//! The open chat's transcript, as the GPUI transcript draws it
//! (crates/ui/src/transcript.rs): a centred column 736 points wide, the
//! user's messages as bubbles on the right, the agent's Markdown, its tool
//! calls and reasoning folded into groups ("Ran 2 commands"), errors as
//! chips, and under each message a lane whose copy button shows on hover.
//! An error signing in fixes says so and offers "Log in" (run_errors.zig);
//! a typed ChatGPT sign-in error carries its reconnect card
//! (view_reauth.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const file_icons = @import("file_icons.zig");
const kit = @import("view_kit.zig");
const tools = @import("tools.zig");
const compact = @import("compact.zig");
const tr = @import("transcript.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;
const rows_st = @import("view_settings_accounts_rows.zig").st;

/// The column's width: Settings › Appearance's conversation width
/// (`transcript_width`, 736 unless set), as of this frame.
pub var column_w: f32 = 736;

/// The column's width in a main area `w` wide, with its gutters.
pub fn columnWidth(w: f32) f32 {
    const gutter = std.math.clamp(w * 0.06, 12, 48);
    return @max(@min(column_w, w - 2 * gutter), 200);
}

/// The chat column's width: the window less the sidebar and the panels.
pub fn mainWidth(c: *ui.Context, a: *const App) f32 {
    var w = c.size.w - a.view.sidebar_width;
    if (a.selected != null and a.panels.host_open) w -= @import("view_host.zig").width + 1;
    if (a.selected != null and a.panels.files_open) w -= @import("view_files.zig").width + 1;
    return @max(w, 300);
}

/// The focused pane's width: the chat column's, less the other panes of a
/// split across it.
pub fn paneWidth(c: *ui.Context, a: *const App) f32 {
    const w = mainWidth(c, a);
    const s = a.tabs.layout() orelse return w;
    if (s.zoomed or s.axis != .horizontal) return w;
    return @max(w * s.shares.items[s.focus] - 1, 200);
}

/// The focused pane's height under the title bar, in a split down the
/// window; null when it has the column's full height.
pub fn paneHeight(c: *ui.Context, a: *const App) ?f32 {
    const s = a.tabs.layout() orelse return null;
    if (s.zoomed or s.axis != .vertical) return null;
    return (c.size.h - sidebar.titlebar_h) * s.shares.items[s.focus] - 1;
}

/// The open chat's transcript, and over its left edge the prompt rail
/// (`render_rail`, view_rail.zig): the column it is in is the rail's.
pub fn transcript(c: *ui.Context, a: *App, k: theme.Colors) void {
    const rail = @import("view_rail.zig");
    rail.step(c, &a.view.rail);
    const drawn = entries(c, a, k, &a.transcript, paneWidth(c, a), a.w_doc.id != null, 64 - sidebar.titlebar_h);
    rail.rail(c, k, &a.view.rail, &a.transcript, drawn.ticks, drawn.box, mainWidth(c, a));
}

/// What a transcript drew: its scroll box, and its prompts' rows as last
/// laid out.
pub const Drawn = struct { box: u64 = 0, ticks: []const @import("view_rail.zig").Tick = &.{} };

/// A transcript `w` wide: the open chat's, or a split pane's neighbor's.
/// The first row sits `top` points down; rows settle at the bottom, over
/// the composer, until they fill it.
pub fn entries(c: *ui.Context, a: *App, k: theme.Colors, t: *const tr.Transcript, w: f32, loading: bool, top: f32) Drawn {
    const frame = ui.div(c).column().grow().wFull().h(0);
    defer frame.end();
    const drawn = rows(c, a, k, t, w, loading, top);
    topFade(c, k);
    return drawn;
}

/// `TRANSCRIPT_FADE_BAND`: rows scrolled up fade out over the 24 points
/// under the title bar, gone by its edge (shell.rs `edge_faded`, its
/// `inset_top(TITLEBAR_HEIGHT)`), here as the column's colour laid over
/// them a point at a time.
fn topFade(c: *ui.Context, k: theme.Colors) void {
    // A tint overlay can imitate a solid background, not a native backdrop:
    // on glass it makes an opaque stripe even when there is no text here.
    if (k.frosted) return;
    const band: f32 = 24;
    var y: f32 = 0;
    while (y < band) : (y += 1) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.shell.alpha(1 - (y + 0.5) / band), .absolute = true, .offset = .{ .x = 0, .y = y } }, .none, null);
    }
}

fn rows(c: *ui.Context, a: *App, k: theme.Colors, t: *const tr.Transcript, w: f32, loading: bool, top: f32) Drawn {
    const col = columnWidth(w);
    // The last row clears the status strip over the composer and the fade
    // band above it (`bottom_clearance + TRANSCRIPT_FADE_BAND + 8`); the
    // composer itself is under the scroll, not over it. Its bar shows
    // while it scrolls, as GPUI's overlay rail.
    var st: ui.Style = .{ .grow = 1, .width = .fill, .padding = .{ .top = top, .bottom = 24 + 24 + 8 }, .align_items = .center, .justify = .end, .follow_end = true };
    if (@hasField(ui.Style, "scrollbar")) st.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
    const subagent = for (a.panels.tabs.items) |tab| {
        if (tab.agent) |s| if (&s.transcript == t) break s;
    } else null;
    if (subagent != null) st.justify = .start;
    st.scroll = true;
    st.direction = .column;
    const scroll = c.open(st, null);
    defer ui.end(c);
    var drawn: Drawn = .{ .box = c.node(scroll).id };
    var ticks: std.ArrayList(@import("view_rail.zig").Tick) = .empty;
    const body = ui.div(c).column().w(col);
    defer body.end();
    const entries_ = t.entries.items;
    // The chat these are, for routing a sign-in: the open one's or a pane's.
    const chat_id: ?[]const u8 = if (subagent) |s| s.parent else if (t == &a.transcript) a.selected else for (a.peers.items) |*p| {
        if (&p.transcript == t) break p.id;
    } else null;
    // Loading does not itself imply work; the session row does, even when
    // no assistant part has arrived yet.
    _ = loading;
    for (entries_, 0..) |*e, i| {
        ui.key(c, c.print("entry-{s}", .{e.id}));
        // `top_gap_for`: every entry's first row opens a turn (`SPACE_LG`).
        if (i > 0) _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
        const at: At = .{ .chat_id = chat_id, .entries = entries_, .index = i, .col = col };
        switch (e.role) {
            .user => {
                // Its row starts where the turn's gap does (`top_gap_for`).
                const r = user(c, k, e, col);
                ticks.append(c.alloc(), .{ .entry = i, .top = if (r) |x| x.y - (if (i > 0) @as(f32, 16) else 0) else null }) catch {};
            },
            .assistant => assistant(c, a, k, e, at),
            .system => system(c, a, k, e, at),
        }
    }
    if (subagent == null) {
        if (chat_id) |id| if (@import("app_send_feedback.zig").active(a, id, t)) |pending| {
            ui.key(c, c.print("pending-{s}", .{pending.message}));
            if (entries_.len > 0) _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
            const entry = pending.entry();
            _ = user(c, k, &entry, col);
        };
        @import("view_working.zig").trailer(c, a, k, chat_id, t);
    }
    drawn.ticks = ticks.items;
    return drawn;
}

/// A prompt's bubble; where it was last laid out.
fn user(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, col: f32) ?ui.Rect {
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
    return c.rects.get(c.node(wrap.index).id);
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

/// Where an entry is: its chat, its place among the entries, the column.
const At = struct {
    chat_id: ?[]const u8,
    entries: []const tr.Entry,
    index: usize,
    col: f32,
};

fn assistant(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    const last = at.index + 1 == at.entries.len;
    const col = ui.div(c).column().wFull();
    defer col.end();
    const hovered = col.hovered();
    // Its parts 12 apart; the lane right under the last (the row's
    // `strip`, with no gap of its own).
    const parts_box = ui.div(c).column().wFull().gap(12);
    const answer: Answer = .{ .part = if (compact.finalAnswerPart(e)) |i| &e.parts.items[i] else null };
    if (a.settings.get(.transcript_compact_mode))
        compactParts(c, a, k, e, at, answer)
    else
        partRows(c, a, k, e, e.parts.items, at, last, answer);
    if (e.status == .streaming and e.parts.items.len == 0) ui.text(c, "Working…", .{ .size = 12, .color = k.muted });
    parts_box.end();
    if (e.status != .streaming) lane(c, k, e, hovered, false);
}

/// The part a finished reply's answer starts at, which a divider heads,
/// and whether the divider says how long the turn worked (compact mode's
/// work line already does).
const Answer = struct {
    part: ?*const tr.Part,
    label: bool = true,
};

/// Parts as rows: tool calls and reasoning folded into groups, the rest
/// one row each. `auto` lets a streaming reply's tail group open itself.
fn partRows(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, at: At, auto: bool, answer: Answer) void {
    const buf = c.alloc().alloc(tools.Run, parts.len) catch {
        ui.text(c, "Unable to render reply: out of memory", .{ .size = 12, .color = k.danger });
        return;
    };
    for (tools.runs(buf, parts)) |r| {
        const p = &parts[r.start];
        ui.key(c, c.print("run-{s}-{s}", .{ e.id, p.id }));
        if (r.group) {
            // ACP often creates its answer placeholder before its first
            // text chunk. An empty placeholder must not hide live work.
            const tail = e.status == .streaming and auto and for (parts[r.end..]) |next| {
                if (next.kind != .text or std.mem.trim(u8, next.text.items, " \t\r\n").len > 0) break false;
            } else true;
            group(c, a, k, e, parts[r.start..r.end], tail, at.chat_id);
            continue;
        }
        part(c, a, k, e, p, at, answer);
    }
}

fn part(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, at: At, answer: Answer) void {
    switch (p.kind) {
        .text => {
            if (answer.part == p) {
                const box = ui.div(c).column().wFull();
                defer box.end();
                answerHeading(c, k, e, answer.label);
                @import("view_markdown.zig").withLinks(c, k, p.text.items, a, at.chat_id);
            } else @import("view_markdown.zig").withLinks(c, k, p.text.items, a, at.chat_id);
        },
        .tool => treeRow(c, a, k, e, p, true, at.chat_id),
        .@"error" => errorPart(c, a, k, e, p, at),
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

/// Above a finished reply's answer (GPUI's `final_answer` heading): a thin
/// divider, 12 points over the answer, under a muted "Worked for …" (or
/// "Final answer") unless compact mode's work line already says it.
fn answerHeading(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, label: bool) void {
    const h = ui.div(c).column().wFull().pb(12);
    defer h.end();
    if (label) {
        const l = ui.div(c).row().wFull().pt(8).pb(12);
        defer l.end();
        var buf: [48]u8 = undefined;
        const text = if (compact.workedSecs(e)) |s| compact.workedFor(&buf, s) else "Final answer";
        ui.text(c, c.print("{s}", .{text}), kit.style(c, 13, 18, .{ .color = k.muted }));
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}

/// Compact mode (GPUI's `compact_shell`): the turn's thinking, tool calls
/// and the narration between them under one closed line where the first
/// of them was; it opens to the rows they'd be without compact mode, and
/// never on its own. Saved views stay rows after it; questions, errors and
/// the reply keep their places.
fn compactParts(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At, answer_in: Answer) void {
    const items = e.parts.items;
    const reply = compact.replyStart(items, e.status == .streaming);
    var work: std.ArrayList(tr.Part) = .empty;
    var views: std.ArrayList(tr.Part) = .empty;
    var first: ?usize = null;
    for (items, 0..) |*p, i| if (compact.isWork(i, p, reply)) {
        if (first == null) first = i;
        // Read-only copies: the rows draw from them this frame only.
        (if (compact.isView(p)) &views else &work).append(c.alloc(), p.*) catch return;
    };
    var answer = answer_in;
    answer.label = work.items.len == 0;
    for (items, 0..) |*p, i| {
        if (compact.isWork(i, p, reply)) {
            if (i != first.?) continue;
            if (work.items.len > 0) {
                ui.key(c, c.print("work-{s}", .{e.id}));
                workLine(c, a, k, e, work.items, at);
            }
            if (views.items.len > 0) partRows(c, a, k, e, views.items, at, false, answer);
            continue;
        }
        ui.key(c, c.print("part-{s}-{s}", .{ e.id, p.id }));
        part(c, a, k, e, p, at, answer);
    }
}

/// The compact work line: a group's header that says what's running while
/// the turn works, then "Worked for …" once it has.
fn workLine(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, work: []const tr.Part, at: At) void {
    const key = c.print("{s}#work", .{e.id});
    const open = a.view.groupOpen(key, false);
    const box = ui.div(c).column().wFull().gap(12);
    defer box.end();
    {
        const h = kit.pressFeedback(ui.div(c).row().h(26).gap(6).pr(4).itemsCenter().rounded(4).control().hover(k.wash(0.04)));
        defer h.end();
        if (h.clicked()) a.view.toggleGroup(a.gpa, key, false);
        const slot = ui.div(c).row().size(22, 18).center();
        icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 14, k.muted, 0);
        slot.end();
        const st = kit.style(c, 12, 18, .{ .color = if (h.hovered()) k.text else k.muted });
        const settled = if (e.status != .streaming) compact.workedSecs(e) else null;
        if (settled) |s| {
            const lb = c.alloc().alloc(u8, 48) catch return;
            ui.text(c, compact.workedFor(lb, s), st);
        } else {
            const lb = c.alloc().alloc(u8, 160) catch return;
            const active = e.status == .streaming and for (work) |p| {
                if (p.kind == .reasoning or (p.kind == .tool and !p.resolved)) break true;
            } else false;
            kit.activityText(c, k, tools.label(lb, work), st, active);
        }
    }
    if (!open) return;
    const reveal = ui.motion.frame(c, (ui.motion.MotionSpec{ .duration_ms = 140, .curve = ui.motion.Easing.css_ease_out }).animate(.{ .opacity = 0.65, .y = -2 }, .{ .opacity = 1, .y = 0 }));
    const body = ui.div(c).column().wFull().gap(12).motion(reveal);
    defer body.end();
    partRows(c, a, k, e, work, at, false, .{ .part = null });
}

const row_h: f32 = 32;
const tree_w: f32 = 48;

/// A run of tool calls and reasoning, folded under one line; it opens on
/// its own while it is the tail of a streaming reply.
fn group(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, tail: bool, parent: ?[]const u8) void {
    const key = c.print("{s}/{s}", .{ e.id, parts[0].id });
    const open = a.view.groupOpen(key, tail);
    const box = ui.div(c).column().wFull();
    defer box.end();
    {
        const h = kit.pressFeedback(ui.div(c).row().h(26).gap(6).pr(4).itemsCenter().rounded(4).control().hover(k.wash(0.04)));
        defer h.end();
        if (h.clicked()) a.view.toggleGroup(a.gpa, key, tail);
        const slot = ui.div(c).row().size(22, 18).center();
        icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 14, k.muted, 0);
        slot.end();
        const lb = c.alloc().alloc(u8, 160) catch return;
        const active = e.status == .streaming and for (parts) |p| {
            if (p.kind == .reasoning or (p.kind == .tool and !p.resolved)) break true;
        } else false;
        kit.activityText(c, k, tools.label(lb, parts), kit.style(c, 12, 18, .{ .color = if (h.hovered()) k.text else k.muted }), active);
    }
    if (!open) return;
    const reveal = ui.motion.frame(c, (ui.motion.MotionSpec{ .duration_ms = 120, .curve = ui.motion.Easing.css_ease_out }).animate(.{ .opacity = 0.65, .y = -2 }, .{ .opacity = 1, .y = 0 }));
    const children = ui.div(c).column().wFull().motion(reveal);
    defer children.end();
    for (parts, 0..) |*p, i| {
        ui.key(c, c.print("tool-{s}", .{p.id}));
        treeRow(c, a, k, e, p, i + 1 == parts.len, parent);
    }
}

/// One call in an open group: the tree's trunk and elbow, its icon, its
/// chip and what it ran.
fn treeRow(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, last: bool, parent: ?[]const u8) void {
    const line = k.wash(0.12);
    const agent_linked = p.agent and p.subagent_ref.len > 0 and p.subagent_title.len > 0 and parent != null;
    const view_linked = p.saved_view != null and parent != null;
    const linked = agent_linked or view_linked;
    const base_row = ui.div(c).row().wFull().gap(8).itemsStart().rounded(5);
    const r = if (linked) kit.pressFeedback(base_row.control().hover(k.wash(0.06))) else base_row;
    defer r.end();
    if (linked and r.clicked()) {
        if (agent_linked) @import("app_subagents.zig").open(a, parent.?, p) else @import("app_browser.zig").openSaved(a, parent.?, p.saved_view.?);
    }
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
    // Fill the row's remaining width before measuring wrapped reasoning
    // and output. A fixed zero width measures them one glyph per line,
    // leaving phantom height that follow-end scrolls the messages past.
    // A 22-point file badge still fits GPUI's 32-point tool row.
    const body = ui.div(c).column().wFull().justifyCenter().gap(4).py(if (p.path.len > 0) 5 else 7);
    defer body.end();
    const detail_key = c.print("detail/{s}/{s}", .{ e.id, p.id });
    const has_output = p.output.len > 0 or p.output_ref.len > 0;
    const base = ui.div(c).row().gap(8).itemsCenter().pr(4).rounded(4);
    const head = if (!linked and has_output) kit.pressFeedback(base.control().hover(k.wash(0.04))) else base;
    {
        defer head.end();
        if (!linked and has_output and head.clicked()) a.view.toggleGroup(a.gpa, detail_key, false);
        const chip = if (p.kind == .reasoning) "Thought process" else p.chip;
        const active = !p.is_error and (if (p.agent) p.subagent_status == .running else e.status == .streaming and !p.resolved);
        kit.activityText(c, k, chip, kit.style(c, 12, 18, .{ .weight = if (toolIcon(p) == .bot) .medium else .regular, .color = if (p.is_error) k.danger else k.muted }), active);
        if (p.kind == .tool) {
            const d = firstLine(if (p.agent and p.text.items.len == 0) p.subagent_title else p.text.items);
            if (p.path.len > 0) fileBadge(c, k, p.path, p.is_error) else kit.fadeText(c, d, .{ .size = 12, .mono = p.tool == .exec, .color = if (p.is_error) k.danger else k.muted }, 560);
            if (linked) icons.icon(c, .@"arrow-up-right", 12, k.faint, 0);
        }
    }
    if (p.kind == .reasoning) {
        @import("view_markdown.zig").withLinks(c, k, p.text.items, a, parent);
    }
    if (!linked and has_output and a.view.groupOpen(detail_key, false)) {
        const output = ui.div(c).column().wFull().p(8).rounded(6).bg(k.wash(0.04));
        defer output.end();
        const blob = a.tool_blobs.get(p.output_ref);
        const text = if (blob) |b| (if (b.status == .ready) b.text else p.output) else p.output;
        if (text.len > 0) ui.text(c, text, kit.style(c, 12, 18, .{ .wrap = true, .mono = true, .color = if (p.is_error) k.danger else k.muted }));
        if (p.output_ref.len > 0 and (blob == null or blob.?.status != .ready)) {
            const loading = blob != null and blob.?.status == .loading;
            const action = ui.div(c).row().py(4);
            defer action.end();
            ui.text(c, if (loading) "Loading full output…" else if (blob != null and blob.?.status == .failed) "Retry full output" else "Show full output", .{ .size = 12, .color = k.muted });
            if (!loading and action.clicked()) a.fetchToolBlob(p.output_ref);
        }
    }
}

/// The GPUI tool header's filename badge, including its untinted identity.
fn fileBadge(c: *ui.Context, k: theme.Colors, path: []const u8, failed: bool) void {
    const badge = ui.div(c).row().h(22).pl(1).pr(6).gap(6).itemsCenter().rounded(5).bg(k.ink(0.06));
    defer badge.end();
    {
        const well = ui.div(c).row().size(20, 20).center().rounded(4).bg(ui.Color.hex(if (k.dark) 0x000000 else 0xffffff).alpha(0.16));
        defer well.end();
        file_icons.icon(c, path, false, k.dark, 14);
    }
    kit.fadeText(c, file_icons.basename(path), kit.style(c, 12, 18, .{ .color = if (failed) k.danger else k.text.alpha(0.85) }), 520);
}

fn toolIcon(p: *const tr.Part) icons.Name {
    if (p.kind == .reasoning) return .@"magic-stick-3";
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
        .unknown => icons.namedTool(p.text.items),
        .mcp => .widget,
    };
}

test "tool rows use the GPUI transcript's original Harness SVGs" {
    const cases = .{
        .{ tr.ToolKind.exec, icons.Name.terminal },
        .{ tr.ToolKind.readFile, icons.Name.document },
        .{ tr.ToolKind.applyPatch, icons.Name.document },
        .{ tr.ToolKind.writeFile, icons.Name.@"document-add" },
        .{ tr.ToolKind.editFile, icons.Name.pen },
        .{ tr.ToolKind.search, icons.Name.magnifer },
        .{ tr.ToolKind.glob, icons.Name.@"folder-with-files" },
        .{ tr.ToolKind.webFetch, icons.Name.global },
        .{ tr.ToolKind.webSearch, icons.Name.global },
        .{ tr.ToolKind.todo, icons.Name.checklist },
        .{ tr.ToolKind.mcp, icons.Name.widget },
    };
    inline for (cases) |case| {
        const p: tr.Part = .{ .id = &.{}, .kind = .tool, .tool = case[0] };
        try std.testing.expectEqual(case[1], toolIcon(&p));
    }
    for ([_][]const u8{ "Agent", "Waiting on" }) |label| {
        for ([_]tr.ToolKind{ .unknown, .mcp }) |kind| {
            const p: tr.Part = .{ .id = &.{}, .kind = .tool, .tool = kind, .chip = label };
            try std.testing.expectEqual(icons.Name.bot, toolIcon(&p));
        }
    }
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

/// An error part: a typed sign-in error's reconnect card, else the chip.
fn errorPart(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, at: At) void {
    const row_id = c.print("{s}#{s}", .{ e.id, p.id });
    // Harness-generated; the chip is one line.
    const message = singleLine(c, p.text.items);
    const provider = p.reauth orelse return errorChip(c, a, k, at.chat_id, message);
    // The chat moved on: a person's message after this error.
    const later = for (at.entries[at.index + 1 ..]) |x| {
        if (x.role == .user) break true;
    } else false;
    @import("view_reauth.zig").card(c, a, k, .{ .chat_id = at.chat_id, .row_id = row_id, .message = message, .provider = provider, .later_activity = later, .col = at.col });
}

/// `single_line`: every run of whitespace as one space, none at the ends.
fn singleLine(c: *ui.Context, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n\x0b\x0c");
    while (it.next()) |w| {
        if (out.items.len > 0) out.append(c.alloc(), ' ') catch return s;
        out.appendSlice(c.alloc(), w) catch return s;
    }
    return out.items;
}

/// `notice_chip` with its tile (notice.rs): the danger triangle, `label`,
/// Copy, then the message wrapped. The caller adds what goes under it and
/// ends it.
pub fn noticeChip(c: *ui.Context, k: theme.Colors, label: []const u8, message: []const u8) ui.Div {
    // GPUI's edge insets what's inside it; here it's drawn over the box.
    const chip = ui.div(c).column().wFull().rounded(10).px(10 + 1).py(8 + 1).gap(6).border(k.danger.alpha(0.16)).borderW(1).bg(k.danger.alpha(0.05));
    {
        const h = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer h.end();
        const tile = ui.div(c).row().size(20, 20).center().rounded(6).bg(k.danger.alpha(0.12));
        icons.icon(c, .@"danger-triangle", 12, k.danger_muted.alpha(0.8), 0);
        tile.end();
        ui.text(c, label, .{ .size = 12, .weight = .medium, .color = k.danger_muted.alpha(0.8) });
        ui.spacer(c);
        const copy = ui.div(c).row().size(20, 20).center().rounded(6).hover(k.danger.alpha(0.12));
        icons.icon(c, .copy, 12, k.danger_muted.alpha(0.8), 0);
        copy.end();
        if (copy.clicked()) c.clipboard.write(c.clipboard.ctx, message);
    }
    // GPUI's line height (phi), as the GPUI renderer draws the chip.
    ui.text(c, message, rows_st(c, 12, .{ .wrap = true, .color = k.text.alpha(0.8) }));
    return chip;
}

/// `error_chip`: the message wraps; a refusal that signing in fixes says so
/// in the label, and with a chat to route it carries "Log in" under the
/// message (`sign_in_for_chat`).
fn errorChip(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, message: []const u8) void {
    const run_errors = @import("run_errors.zig");
    // The ChatGPT plan's own limit has its plan-usage card in the GPUI app,
    // never "Log in".
    const problem = if (run_errors.isPlanUsageLimit(message)) null else run_errors.providerProblem(message);
    const outer = ui.div(c).column().wFull().py(4);
    defer outer.end();
    const chip = noticeChip(c, k, if (problem) |p| p.label() else "Error", message);
    defer chip.end();
    const p = problem orelse return;
    const id = chat_id orelse return;
    const r = ui.div(c).row().pt(2);
    defer r.end();
    // `btn_primary` at px(10) py(5) rounded(7), 12 points.
    const b = ui.div(c).row().px(10).py(5).rounded(7).bg(k.solid);
    defer b.end();
    ui.text(c, p.actionLabel(), rows_st(c, 12, .{ .weight = .medium, .color = k.on_solid }));
    if (b.clicked()) @import("app_reauth.zig").signInForChat(a, id);
}

fn attachment(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8) void {
    const row = ui.div(c).row().gap(6).itemsCenter();
    defer row.end();
    icons.icon(c, icon, 14, k.muted, 0);
    ui.text(c, label, .{ .size = 12, .color = k.muted });
}

fn system(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    for (e.parts.items) |*p| switch (p.kind) {
        .text => ui.text(c, p.text.items, kit.style(c, 12, 18, .{ .wrap = true, .color = k.faint })),
        .@"error" => errorPart(c, a, k, e, p, at),
        else => {},
    };
}
