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
const attachment_refs = @import("attachment_refs.zig");
const attachment_images = @import("app_attachment_images.zig");
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

/// The shared shell frame owns the actual chat allocation, including the
/// dynamic host/explorer widths; never subtract their old fixed widths.
pub fn mainWidth(c: *ui.Context, a: *const App) f32 {
    _ = c;
    return a.view.chrome.chat_width;
}

/// What lays out inside the column: GPUI's card takes the rounded seam's
/// hairline as its left border (`border_l_1`), a point of layout, while
/// its width sums and the rail's gate use the column whole.
pub fn contentWidth(c: *ui.Context, a: *const App) f32 {
    return mainWidth(c, a) - a.view.seam_inset;
}

/// The focused pane's width: the chat column's, less the other panes of a
/// split across it.
pub fn paneWidth(c: *ui.Context, a: *const App) f32 {
    const w = contentWidth(c, a);
    const s = a.tabs.layout() orelse return w;
    if (s.zoomed or s.axis != .horizontal) return w;
    return @max(0, @import("panel_chrome.zig").paneSpan(a.view.chrome.chat_width, s.shares.items[s.focus], s.panes.items.len, true) - a.view.seam_inset);
}

/// The focused pane's height under the title bar, in a split down the
/// window; null when it has the column's full height.
pub fn paneHeight(c: *ui.Context, a: *const App) ?f32 {
    const s = a.tabs.layout() orelse return null;
    if (s.zoomed or s.axis != .vertical) return null;
    _ = c;
    return @max(0, @import("panel_chrome.zig").paneSpan(a.view.chrome.height, s.shares.items[s.focus], s.panes.items.len, false) - a.view.seam_inset);
}

/// The open chat's transcript, and over its left edge the prompt rail
/// (`render_rail`, view_rail.zig): the column it is in is the rail's.
pub fn transcript(c: *ui.Context, a: *App, k: theme.Colors) void {
    const rail = @import("view_rail.zig");
    rail.step(c, &a.view.rail);
    const just_stuck = a.view.stick_end;
    const drawn = entries(c, a, k, &a.transcript, paneWidth(c, a), a.w_doc.id != null, 64 - sidebar.titlebar_h);
    rail.rail(c, k, &a.view.rail, &a.transcript, drawn.ticks, drawn.box, mainWidth(c, a));
    if (!just_stuck) recoverBlank(c, a, drawn);
    a.view.jump_box = drawn.box;
    a.view.jump_distance = drawn.from_end;
}

/// A scroll offset left over from a taller transcript can park the reader
/// in padding, with no row in the window. That is not a place to stay.
fn recoverBlank(c: *ui.Context, a: *App, drawn: Drawn) void {
    if (drawn.box == 0 or drawn.ticks.len == 0) return;
    const view = c.rects.get(drawn.box) orelse return;
    var any = false;
    var near = false;
    for (drawn.ticks) |tick| if (tick.top) |top| {
        any = true;
        if (top + 200 >= view.y - 80 and top <= view.y + view.h + 80) near = true;
    };
    if (c.scroll_max.get(drawn.box)) |max| {
        const at = c.scroll.get(drawn.box) orelse 0;
        if (at <= max + 1) near = true;
    }
    if (!any or near) return;
    // One correction. Repeating it rebuilds the window forever and the
    // beachball follows.
    if (a.view.blank_recovered == drawn.box) return;
    a.view.blank_recovered = drawn.box;
    c.scroll.put(c.gpa, drawn.box, std.math.floatMax(f32)) catch {};
    c.scroll_follow.put(c.gpa, drawn.box, true) catch {};
    a.view.jump_distance = 0;
    a.view.jump_shown = false;
    c.changed = true;
}

/// What a transcript drew: its scroll box, and its prompts' rows as last
/// laid out.
pub const Drawn = struct {
    box: u64 = 0,
    ticks: []const @import("view_rail.zig").Tick = &.{},
    /// How far the reader is from the end. The jump pill shows past GPUI's
    /// `SCROLL_BUTTON_THRESHOLD_PX`.
    from_end: f32 = 0,
};

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
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.background.alpha(1 - (y + 0.5) / band), .absolute = true, .offset = .{ .x = 0, .y = y } }, .none, null);
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
    // The chat these are, for routing a sign-in: the open one's or a pane's.
    const chat_id: ?[]const u8 = if (subagent) |s| s.parent else if (t == &a.transcript) a.selected else for (a.peers.items) |*p| {
        if (&p.transcript == t) break p.id;
    } else null;
    if (subagent == null) if (chat_id) |id| ui.key(c, c.print("scroll-{s}", .{id}));
    const scroll = c.open(st, null);
    defer ui.end(c);
    var drawn: Drawn = .{ .box = c.node(scroll).id };
    // Just sent: past the end, which layout clamps to it, and moving the
    // offset there makes the box follow its end again (`follow_end`).
    if (subagent == null and t == &a.transcript and a.view.stick_end) {
        a.view.stick_end = false;
        const sync = @import("motion_rules.zig").stickEndScroll(c.scroll_max.get(drawn.box));
        c.scroll_follow.put(c.gpa, drawn.box, sync.follow) catch {};
        c.scroll.put(c.gpa, drawn.box, sync.scroll) catch {};
        c.scroll_seen.put(c.gpa, drawn.box, sync.seen) catch {};
    }
    if (c.scroll_max.get(drawn.box)) |max| {
        const at = c.scroll.get(drawn.box) orelse 0;
        drawn.from_end = @max(0, max - at);
    }
    var ticks: std.ArrayList(@import("view_rail.zig").Tick) = .empty;
    const body = ui.div(c).column().w(col);
    defer body.end();
    const entries_ = t.entries.items;
    // Loading does not itself imply work; the session row does, even when
    // no assistant part has arrived yet.
    _ = loading;
    const scroll_rect = c.rects.get(drawn.box);
    const tweening = a.view.sidebar_tween != null or a.view.split_reveal != null;
    for (entries_, 0..) |*e, i| {
        // `top_gap_for`: every entry's first row opens a turn (`SPACE_LG`).
        if (i > 0) _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
        ui.key(c, c.print("entry-{s}", .{e.id}));
        const entry_id = c.peekId(null);
        const prev = c.rects.get(entry_id);
        if (prev) |r| if (r.h > 0) {
            e.cached_h = r.h;
        };
        if (tweening and i + 2 < entries_.len and e.status != .streaming and e.cached_h > 0) {
            if (scroll_rect) |view| if (prev) |r| {
                if (@import("motion_rules.zig").skipOffscreenRow(tweening, r.y, r.y + r.h, view.y, view.y + view.h, 250)) {
                    _ = c.leaf(.{ .width = .fill, .height = .{ .px = e.cached_h } }, .none, null);
                    if (e.role == .user) {
                        ticks.append(c.alloc(), .{ .entry = i, .top = r.y - (if (i > 0) @as(f32, 16) else 0) }) catch {};
                    }
                    continue;
                }
            };
        }
        const at: At = .{ .chat_id = chat_id, .entries = entries_, .index = i, .col = col, .scroll = scroll_rect };
        switch (e.role) {
            .user => {
                // Its row starts where the turn's gap does (`top_gap_for`).
                const r = user(c, a, k, e, col, chat_id);
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
            _ = user(c, a, k, &entry, col, chat_id);
        };
        @import("view_working.zig").trailer(c, a, k, chat_id, t);
    }
    drawn.ticks = ticks.items;
    return drawn;
}

/// A prompt's bubble; where it was last laid out.
fn user(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, col: f32, chat_id: ?[]const u8) ?ui.Rect {
    const wrap = ui.div(c).column().wFull().itemsEnd();
    defer wrap.end();
    const hovered = wrap.hovered();
    {
        const bubble = ui.div(c).column().maxW(col * 0.8).bg(k.user_bubble).rounded(16).px(16).py(10).gap(6);
        defer bubble.end();
        const st = kit.style(c, 14, 22, .{ .wrap = true, .color = k.text });
        for (e.parts.items) |*p| switch (p.kind) {
            .text => {
                const parsed = attachment_refs.parse(c.alloc(), p.text.items) catch attachment_refs.Parsed{ .text = p.text.items };
                if (parsed.text.len > 0) ui.text(c, parsed.text, st);
                for (parsed.paths, 0..) |path, index| {
                    ui.key(c, c.print("user-attachment-{s}-{d}", .{ p.id, index }));
                    sentAttachment(c, a, k, chat_id, path);
                }
            },
            .image => attachment(c, k, .document, p.text.items),
            else => {},
        };
    }
    lane(c, k, e, hovered, true);
    return c.rects.get(c.node(wrap.index).id);
}

fn sentAttachment(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, path: []const u8) void {
    const tiles = @import("view_composer_attachments.zig");
    const name = @import("app_attachments.zig").displayName(path);
    const image = attachment_images.get(a, chat_id, path);
    const bytes: []const u8 = if (image) |loaded| attachment_images.tileBytes(loaded) else "";
    const tile = ui.div(c).column().w(56).gap(2);
    defer tile.end();
    {
        const thumb = ui.div(c).row().size(56, 56).center().rounded(8).border(k.border).bg(k.hover).clip();
        defer thumb.end();
        tiles.picture(c, k, c.print("{s}:{s}", .{ chat_id orelse "", path }), name, bytes);
    }
    kit.ellipsisText(c, name, .{ .size = 10, .line_height = 12, .color = k.muted }, 56);
}

/// `format_timestamp`: "Jul 1, 3:45 PM", `offset_s` from UTC.
pub fn formatTimestamp(buf: []u8, ms: i64, offset_s: i64) []const u8 {
    const accounts = @import("accounts.zig");
    const at = ms + offset_s * 1000;
    const day = accounts.monthDay(@divFloor(at, 86_400_000));
    const in_day = @mod(at, 86_400_000);
    const h = @divFloor(in_day, 3_600_000);
    const m = @divFloor(@mod(in_day, 3_600_000), 60_000);
    const h12: u64 = @intCast(if (@mod(h, 12) == 0) 12 else @mod(h, 12));
    return std.fmt.bufPrint(buf, "{s} {d}, {d}:{d:0>2} {s}", .{ accounts.month_names[day.month - 1], day.day, h12, @as(u64, @intCast(m)), if (h < 12) "AM" else "PM" }) catch "";
}

test "a message's timestamp reads as the GPUI app's" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Jan 1, 12:00 AM", formatTimestamp(&b, 0, 0));
    // 2026-07-01 15:45 UTC.
    try std.testing.expectEqualStrings("Jul 1, 3:45 PM", formatTimestamp(&b, 1782920700000, 0));
    try std.testing.expectEqualStrings("Jul 1, 11:45 PM", formatTimestamp(&b, 1782920700000, 8 * 3600));
    try std.testing.expectEqualStrings("Jul 2, 12:05 AM", formatTimestamp(&b, 1782920700000 + 20 * 60_000, 8 * 3600));
}

/// Whether the pointer is in the padding the last row carries under it: the
/// clearance that takes it down behind the composer, which nothing there
/// occludes (`bottom_pad`). A menu or the picker over it does.
fn underLastRow(c: *ui.Context, a: *const App, row: ?ui.Rect, scroll: ?ui.Rect) bool {
    const r = row orelse return false;
    const pane = scroll orelse return false;
    const m = c.input.mouse;
    if (@import("view.zig").menuKeepsKeys(a) or a.view.account_menu) return false;
    return m.x >= pane.x and m.x < pane.x + pane.w and m.y >= r.y + r.h and m.y < c.size.h;
}

/// Under a message: 32 points held for its time and copy button, shown on
/// hover (`strip`).
fn lane(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, hovered: bool, right: bool) void {
    var l = ui.div(c).row().wFull().h(32).pt(8).gap(8).itemsCenter();
    if (right) l = l.justifyEnd();
    defer l.end();
    if (!hovered) return;
    if (e.created_ms != 0) {
        const buf = c.alloc().alloc(u8, 32) catch return;
        ui.text(c, formatTimestamp(buf, e.created_ms, @import("accounts.zig").localOffset(e.created_ms)), .{ .size = 12, .line_height = 12 * 1.618, .color = k.muted.alpha(0.55) });
    }
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
    /// The scroll box as last laid out.
    scroll: ?ui.Rect = null,
};

fn assistant(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    const last = at.index + 1 == at.entries.len;
    const col = ui.div(c).column().wFull();
    defer col.end();
    const hovered = col.hovered() or (last and underLastRow(c, a, c.rects.get(c.node(col.index).id), at.scroll));
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
/// and the narration between them stay visible while the turn runs, then
/// fold behind one line. Finished work can be opened again. Saved views
/// stay rows after it; questions, errors and
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
    const legacy = c.print("{s}#work", .{e.id});
    const key = c.print("{s}/{s}", .{ at.chat_id orelse "", legacy });
    const live = e.status == .streaming;
    const live_key = c.print("{s}/live", .{key});
    const settled_key = c.print("{s}/settled", .{key});
    // A resumed turn starts a fresh live phase. Choices made while running
    // must not pin the completed work open; reopening it afterwards is local
    // to the settled phase. Legacy keys still work for loaded history.
    if (live) {
        for ([_][]const u8{ key, legacy, settled_key }) |old_key| {
            if (a.view.groups.fetchRemove(old_key)) |kv| a.gpa.free(kv.key);
        }
    } else {
        if (a.view.groups.fetchRemove(live_key)) |kv| a.gpa.free(kv.key);
    }
    const override = if (live) live_key else settled_key;
    const open = a.view.groups.get(override) orelse if (live) true else (a.view.groups.get(key) orelse a.view.groups.get(legacy) orelse false);
    const box = ui.div(c).column().wFull();
    defer box.end();
    {
        const h = kit.pressFeedback(ui.div(c).row().h(26).gap(6).pr(4).itemsCenter().rounded(4).control().hover(k.wash(0.04)));
        defer h.end();
        if (h.clicked()) a.view.toggleGroup(a.gpa, override, open);
        const slot = ui.div(c).row().size(22, 18).center();
        @import("view_tool_rows.zig").chevron(c, k, open, 14);
        slot.end();
        const st = kit.style(c, 15, 18, .{ .color = if (h.hovered()) k.text else k.muted });
        const settled = if (e.status != .streaming) compact.workedSecs(e) else null;
        if (settled) |s| {
            const lb = c.alloc().alloc(u8, 48) catch return;
            ui.text(c, compact.workedFor(lb, s), st);
        } else {
            const lb = c.alloc().alloc(u8, 160) catch return;
            const active = e.status == .streaming and for (work) |p| {
                if (p.kind == .reasoning or (p.kind == .tool and !p.resolved)) break true;
            } else false;
            @import("view_tool_rows.zig").title(c, k, tools.label(lb, work), active, h.hovered());
        }
    }
    const state = @import("tool_ui_state.zig");
    const fold_id = state.key(at.chat_id, key, "compact-fold");
    const estimate = 12 + @as(f32, @floatFromInt(work.len)) * 32;
    const fold = a.view.tool_ui.fold(a.gpa, fold_id, open, if (a.view.tool_ui.folds.contains(fold_id)) 0 else estimate, c.time, c.reduced_motion);
    if (!open and !fold.animating(c.time, c.reduced_motion)) return;
    var viewport = ui.div(c).column().wFull().clip();
    if (fold.natural > 0) viewport = viewport.h(fold.height(c.time, c.reduced_motion));
    defer viewport.end();
    const body = ui.div(c).column().wFull().pt(12).gap(12);
    defer body.end();
    @import("view_tool_tree.zig").rememberHeight(c, a, fold_id, body.index);
    if (fold.animating(c.time, c.reduced_motion)) c.frameIn(1.0 / 30.0);
    partRows(c, a, k, e, work, at, false, .{ .part = null });
}

/// The current desktop renders expanded results in the task tree itself.
fn group(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, tail: bool, parent: ?[]const u8) void {
    @import("view_tool_tree.zig").group(c, a, k, e, parts, tail, parent);
}

fn treeRow(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, last: bool, parent: ?[]const u8) void {
    @import("view_tool_tree.zig").row(c, a, k, e, p, last, parent);
}

/// An opened edit: its hunks as the Changes pane draws them, numbers,
/// markers and syntax colors (`ToolDetail::Diff`).
pub fn editDiff(c: *ui.Context, k: theme.Colors, p: *const tr.Part, new: []const u8) void {
    const f = @import("tool_diff.zig").file(c.alloc(), p.path, p.diff_old, new) catch return;
    if (f.hunks.len == 0) return;
    ui.key(c, c.print("edit-diff-{s}", .{p.id}));
    const box = ui.div(c).column().wFull().py(4).clip();
    defer box.end();
    @import("view_diffs.zig").body(c, k, &f);
}

/// A thinned edit's files, one row each: its icon, path and counts
/// (`ToolDetail::Stats`).
pub fn statRows(c: *ui.Context, k: theme.Colors, stats: []const tr.Stat) void {
    const box = ui.div(c).column().wFull().py(4);
    defer box.end();
    const mono: ui.TextStyle = .{ .size = 12, .mono = true, .color = k.faint };
    for (stats) |s| {
        const r = ui.div(c).row().wFull().h(18).gap(8).itemsCenter();
        defer r.end();
        file_icons.icon(c, s.path, false, k.dark, 14);
        {
            const path = ui.div(c).row().grow().w(0).clip();
            defer path.end();
            ui.text(c, s.path, mono);
        }
        var st = mono;
        st.color = k.success;
        ui.text(c, c.print("+{d}", .{s.additions}), st);
        st.color = k.danger;
        ui.text(c, c.print("−{d}", .{s.deletions}), st);
    }
}

fn toolIcon(p: *const tr.Part) icons.Name {
    return @import("view_tool_tree.zig").toolIcon(p);
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

/// `error_chip`: the message wraps; a refusal the provider account fixes says
/// so in the label, and with a chat to route it carries its button under the
/// message: "Log in" (`sign_in_for_chat`) or "Update key" (`update_key_for_chat`).
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
    if (b.clicked()) switch (p) {
        .key_rejected => @import("app_reauth.zig").updateKeyForChat(a, id),
        else => @import("app_reauth.zig").signInForChat(a, id),
    };
}

fn attachment(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8) void {
    const row = ui.div(c).row().gap(6).itemsCenter();
    defer row.end();
    icons.icon(c, icon, 14, k.muted, 0);
    ui.text(c, label, .{ .size = 12, .color = k.muted });
}

fn system(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    const col = ui.div(c).column().wFull();
    defer col.end();
    for (e.parts.items) |*p| switch (p.kind) {
        .text => ui.text(c, p.text.items, kit.style(c, 12, 18, .{ .wrap = true, .color = k.faint })),
        .@"error" => errorPart(c, a, k, e, p, at),
        else => {},
    };
}
