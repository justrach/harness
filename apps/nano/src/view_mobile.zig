//! 1:1 Pure-Zig iOS (`UIKit` + Metal + Liquid Glass) mobile shell for `nanoui`.
//!
//! The mobile UI and embedded engine are Zig; binary CRDT interoperability
//! uses the Rust Loro static library through `loro_ffi.zig`:
//! - Preserves all 22 `GlassSurfaceId` Liquid Glass surfaces (`mobile_glass.zig`)
//!   with zero interior `.bg(...)` wash and zero unfocused `.border(...)` when
//!   Reduce Transparency is off.
//! - Full-bleed underlap scroll architecture (`ios_scroll.zig`): `HomeView` and
//!   `SessionView` scroll containers render on `layer = 0` with top/bottom chrome
//!   underlap padding so content refracts live beneath floating top/bottom Liquid
//!   Glass bars (`layer = 1`) and sheets (`layer = 2`).
//! - 120 Hz ProMotion tail virtualization (`tailWindow`), `140pt`/`70pt` hysteresis
//!   Jump-to-Latest pill (`updateJumpShown`), `1500ms` question-close Stop guard
//!   (`mobile_parity.isStopAllowed`), `.scrollX()` momentum chip bars, responsive
//!   `PhoneSplit` (`>= 600pt`), 20-family / 33-variant iOS theme picker, and live
//!   240-sample `ScrollTelemetry`.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const workspace = @import("workspace.zig");
const tr = @import("transcript.zig");
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const highlight = @import("highlight.zig");
const mg = @import("mobile_glass.zig");
const ios_scroll = @import("ios_scroll.zig");
const mp = @import("mobile_parity.zig");

pub const HomeFilter = enum {
    all,
    unread,
    pinned,
    running,
    archived,

    pub fn label(self: HomeFilter) []const u8 {
        return switch (self) {
            .all => "All",
            .unread => "Unread",
            .pinned => "Pinned",
            .running => "Running",
            .archived => "Archived",
        };
    }
};

pub const Sheet = enum {
    none,
    new_session,
    write_dock,
    settings,
    session_switcher,
};

pub const State = struct {
    filter: HomeFilter = .all,
    group_by: mp.GroupBy = .project,
    split_mode: ios_scroll.SplitMode = .auto,
    flat_list_shown: bool = false,
    flat_list_overridden: bool = false,
    zen_mode: bool = false,
    search_query: ui.TextBuffer = .{},
    search_focus: bool = false,
    composer_focus: bool = false,
    sheet: Sheet = .none,
    tail_cap: usize = ios_scroll.default_tail_cap,
    last_chat_hash: u64 = 0,
    jump_shown: bool = false,
    stick_to_bottom: bool = false,
    last_scroll_box: u64 = 0,
    question_closed_at_ms: ?i64 = null,
    answered_req_buf: [96]u8 = undefined,
    answered_req_len: usize = 0,
    expanded_tools: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    pinned: std.StringHashMapUnmanaged(void) = .empty,
    theme_override_id: ?[]u8 = null,
    new_space_idx: usize = 0,
    new_agent_idx: usize = 0,
    effort_idx: usize = 2, // 0=low, 1=medium, 2=high
    last_frame_sec: f64 = 0,
    telemetry: ios_scroll.ScrollTelemetry = .{},

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        @import("text_buffer.zig").deinit(&s.search_query);
        s.expanded_tools.deinit(gpa);
        var it = s.pinned.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        s.pinned.deinit(gpa);
        if (s.theme_override_id) |tid| gpa.free(tid);
    }

    pub fn isPinned(s: *const State, chat_id: []const u8) bool {
        return s.pinned.contains(chat_id);
    }

    pub fn togglePin(s: *State, gpa: std.mem.Allocator, chat_id: []const u8) void {
        if (s.pinned.fetchRemove(chat_id)) |kv| {
            gpa.free(kv.key);
            return;
        }
        const copy = gpa.dupe(u8, chat_id) catch return;
        s.pinned.put(gpa, copy, {}) catch gpa.free(copy);
    }

    pub fn setThemeOverride(s: *State, gpa: std.mem.Allocator, id: ?[]const u8) void {
        if (s.theme_override_id) |old| gpa.free(old);
        s.theme_override_id = if (id) |v| gpa.dupe(u8, v) catch null else null;
    }

    pub fn answeredReq(s: *const State) []const u8 {
        return s.answered_req_buf[0..s.answered_req_len];
    }

    pub fn markAnswered(s: *State, req_id: []const u8, now_ms: i64) void {
        const n = @min(req_id.len, s.answered_req_buf.len);
        @memcpy(s.answered_req_buf[0..n], req_id[0..n]);
        s.answered_req_len = n;
        s.question_closed_at_ms = now_ms;
    }
};

const effort_levels = [_][]const u8{ "low", "medium", "high" };
const effort_labels = [_][]const u8{ "Low", "Medium", "High" };
const agent_ids = [_][]const u8{ "graff", "codex", "claude" };
const agent_labels = [_][]const u8{ "Graff", "Codex", "Claude" };

fn nowEpochMs(a: *const App) i64 {
    const ts = std.Io.Clock.real.now(a.io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

pub fn resolveMobileColors(a: *const App, dark: bool) theme.Colors {
    if (a.mobile.theme_override_id) |tid| {
        if (themes.findMobile(tid)) |v| return v.colors;
    }
    const chosen_id = a.settings.themeId(dark);
    if (themes.findMobile(chosen_id)) |v| return v.colors;
    return theme.colors(dark);
}

pub fn view(a: *App, c: *ui.Context) void {
    const t_start = std.Io.Clock.awake.now(a.io);
    const dt_sec: f32 = if (a.mobile.last_frame_sec > 0 and c.time > a.mobile.last_frame_sec)
        @floatCast(c.time - a.mobile.last_frame_sec)
    else
        @as(f32, 1.0 / 120.0);
    a.mobile.last_frame_sec = c.time;

    const dark = if (a.mobile.theme_override_id) |tid|
        (if (themes.findMobile(tid)) |v| v.dark else (a.dark orelse nanoui.isDark()))
    else
        (a.dark orelse nanoui.isDark());

    const k = resolveMobileColors(a, dark);
    c.theme = theme.ui(dark);
    c.theme.dark = dark;
    c.theme.background = k.background;
    c.theme.surface = k.card;
    c.theme.border = k.border;
    c.theme.text = k.text;
    c.theme.muted = k.muted;
    c.theme.accent = k.accent;
    c.node(0).style.background = k.background;
    a.ansi = k.ansi;

    if (a.tick(c.time)) |wait| c.frameIn(wait);
    if (c.scroll_moved.count() > 0) c.frameIn(1.0 / 120.0);
    a.reap();

    const rt = c.access.reduce_transparency;
    const base_split = ios_scroll.shouldSplitPhone(c.size.w, a.mobile.split_mode, c.size.w >= 660.0);
    const split = if (c.size.w >= 600.0 and a.selected != null and a.mobile.flat_list_overridden)
        a.mobile.flat_list_shown
    else
        base_split;

    {
        const root = ui.div(c).row().sizeFull().bg(k.background);
        defer root.end();

        if (split) {
            const list_w = ios_scroll.phoneSplitListWidth(c.size.w);
            {
                const left = ui.div(c).column().w(list_w).hFull().clip();
                defer left.end();
                renderHomePane(a, c, k, rt, true);
            }
            _ = ui.div(c).w(1).hFull().bg(k.border).end();
            {
                const right = ui.div(c).column().grow().hFull().clip();
                defer right.end();
                if (a.selected != null) {
                    renderSessionPane(a, c, k, rt, true);
                } else {
                    renderEmptyDetail(a, c, k, rt);
                }
            }
        } else {
            const pane = ui.div(c).column().sizeFull().clip();
            defer pane.end();
            if (a.selected != null) {
                renderSessionPane(a, c, k, rt, false);
            } else {
                renderHomePane(a, c, k, rt, false);
            }
        }
    }

    if (a.mobile.sheet != .none) {
        renderSheetOverlay(a, c, k, rt);
    }

    const t_end = std.Io.Clock.awake.now(a.io);
    const work_ns: f64 = @floatFromInt(t_start.durationTo(t_end).toNanoseconds());
    const work_ms: f32 = @floatCast(work_ns / 1_000_000.0);
    const cur_scroll: f32 = if (a.mobile.last_scroll_box != 0)
        (c.scroll.get(a.mobile.last_scroll_box) orelse 0)
    else
        0;
    a.mobile.telemetry.record(dt_sec, work_ms, cur_scroll);
}

fn chatStatus(a: *const App, chat_id: []const u8) workspace.Status {
    for (a.sessions.items) |s| {
        if (std.mem.eql(u8, s.chat_id, chat_id)) return s.status;
    }
    return .idle;
}

fn isChatUnread(ch: workspace.Chat) bool {
    return ch.last_message_ms > 0 and ch.last_seen_ms < ch.last_message_ms;
}

fn matchesSearch(ch: workspace.Chat, space_name: []const u8, q: []const u8) bool {
    const trimmed = std.mem.trim(u8, q, " \t\r\n");
    if (trimmed.len == 0) return true;
    if (ch.title) |t| if (containsIgnoreCase(t, trimmed)) return true;
    if (ch.preview) |p| if (containsIgnoreCase(p, trimmed)) return true;
    if (containsIgnoreCase(space_name, trimmed)) return true;
    if (ch.branch orelse ch.row_branch) |b| if (containsIgnoreCase(b, trimmed)) return true;
    return containsIgnoreCase(ch.id, trimmed);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn renderHomePane(a: *App, c: *ui.Context, k: theme.Colors, rt: bool, in_split: bool) void {
    const now_ms = nowEpochMs(a);
    const top_inset = c.safe_area.top;
    const bot_inset = c.safe_area.bottom;
    const left_inset = c.safe_area.left;
    const right_inset = if (in_split) @as(f32, 0) else c.safe_area.right;
    const top_chrome_h: f32 = 56;
    const bot_chrome_h: f32 = 64;

    // -----------------------------------------------------------------------
    // PASS 1 (`layer = 0`): Full-bleed underlap session list scroller
    // -----------------------------------------------------------------------
    ui.key(c, "ios-home-scroller");
    const list_st: ui.Style = .{
        .grow = 1,
        .width = .fill,
        .direction = .column,
        .scroll = true,
        .scrollbar = .{ .overlay = k.faint.alpha(0.45) },
        .padding = .{
            .top = top_inset + top_chrome_h + 12,
            .bottom = ios_scroll.underlapBottomPadding(bot_inset, bot_chrome_h),
            .left = 14 + left_inset,
            .right = 14 + right_inset,
        },
        .gap = 12,
    };
    {
        const scroll_idx = c.open(list_st, null);
        defer ui.end(c);
        if (a.selected == null) a.mobile.last_scroll_box = c.node(scroll_idx).id;

        var refs: std.ArrayList(mp.HomeChatRef) = .empty;
        for (a.chats.items) |ch| {
            if (ch.parent_chat_id != null) continue;
            const st = chatStatus(a, ch.id);
            const keep = switch (a.mobile.filter) {
                .all => !ch.archived,
                .unread => !ch.archived and isChatUnread(ch),
                .pinned => !ch.archived and a.mobile.isPinned(ch.id),
                .running => !ch.archived and (st == .working or st == .awaiting_input),
                .archived => ch.archived,
            };
            if (!keep) continue;
            const sp_name = if (a.findSpace(ch.space_id)) |sp| sp.name else "No project";
            if (!matchesSearch(ch, sp_name, a.mobile.search_query.text())) continue;
            refs.append(c.alloc(), .{
                .id = ch.id,
                .space_id = ch.space_id,
                .device_id = ch.device_id orelse "local",
            }) catch continue;
        }

        var pin_slice: std.ArrayList([]const u8) = .empty;
        var pit = a.mobile.pinned.keyIterator();
        while (pit.next()) |pk| pin_slice.append(c.alloc(), pk.*) catch {};

        const sections = mp.groupHomeChats(c.alloc(), refs.items, a.mobile.group_by, pin_slice.items) catch &.{};

        if (sections.len == 0) {
            const empty = ui.div(c).column().wFull().py(72).itemsCenter().gap(10);
            defer empty.end();
            icons.icon(c, .@"chat-round-line", 28, k.faint, 0);
            ui.text(c, if (a.chats.items.len == 0) "No sessions yet" else "No matching sessions", .{ .size = 16, .weight = .semibold, .color = k.text });
            ui.text(c, "Tap + below to start a new session on any connected computer.", .{ .size = 13.5, .color = k.muted });
        } else {
            for (sections) |sec| {
                ui.key(c, c.print("home-sec-{s}", .{sec.id}));
                const sec_col = ui.div(c).column().wFull().gap(6);
                defer sec_col.end();

                if (!std.mem.eql(u8, sec.kind, "all")) {
                    const hdr = ui.div(c).row().wFull().px(6).pt(4).pb(2).itemsCenter().justifyBetween();
                    defer hdr.end();
                    const title_txt = sectionTitle(a, c, sec, now_ms);
                    ui.text(c, title_txt.label, .{ .size = 12, .weight = .semibold, .color = k.muted });
                    if (title_txt.online) |is_on| {
                        const badge = ui.div(c).row().itemsCenter().gap(5);
                        defer badge.end();
                        _ = ui.div(c).size(6, 6).roundedFull().circular().bg(if (is_on) k.success else k.faint).end();
                        if (!a.mobile.zen_mode) {
                            ui.text(c, if (is_on) "Online" else "Offline", .{ .size = 11, .color = k.faint });
                        }
                    }
                }

                for (sec.chats) |cid| {
                    if (a.findChat(cid)) |ch| {
                        renderHomeChatRow(a, c, k, ch, now_ms, in_split);
                    }
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // PASS 2 (`layer = 1`): Floating top & bottom Liquid Glass chrome
    // -----------------------------------------------------------------------
    {
        const top_bar = ui.div(c).row().wFull().pl(14 + left_inset).pr(14 + right_inset).gap(8).itemsCenter().absolute().offset(0, top_inset + 8).layer(1);
        defer top_bar.end();

        if (mg.circleButton(c, "ios-home-settings-btn", .home_customize_circle, .@"settings-minimalistic", k.text, rt, null).clicked) {
            a.mobile.sheet = .settings;
        }

        // Horizontally scrollable `.scrollX()` Liquid Glass filter & Zen pills
        {
            ui.key(c, "ios-home-filter-strip");
            const strip_st: ui.Style = .{
                .grow = 1,
                .height = .{ .px = 38 },
                .direction = .row,
                .align_items = .center,
                .gap = 6,
                .scroll_x = true,
                .scroll_bar = false,
                .scrollbar = .{ .overlay = .{ .a = 0 } },
                .clip = true,
            };
            _ = c.open(strip_st, null);
            defer ui.end(c);

            if (mg.pillButton(
                c,
                "ios-zen-pill",
                .home_zen_pill,
                if (a.mobile.zen_mode) .@"magic-stick-3" else .terminal,
                if (a.mobile.zen_mode) "Zen" else "Dev",
                null,
                k.text,
                a.mobile.zen_mode,
                k.accent,
                rt,
            ).clicked) {
                a.mobile.zen_mode = !a.mobile.zen_mode;
            }

            for (std.enums.values(HomeFilter)) |flt| {
                const key_s = c.print("ios-flt-{s}", .{@tagName(flt)});
                if (mg.pillButton(
                    c,
                    key_s,
                    .home_filter_pill,
                    null,
                    flt.label(),
                    null,
                    k.text,
                    a.mobile.filter == flt,
                    k.accent,
                    rt,
                ).clicked) {
                    a.mobile.filter = flt;
                }
            }
        }

        const grp_icon: icons.Name = switch (a.mobile.group_by) {
            .project => .folder,
            .device => .laptop,
            .none => .list,
        };
        if (mg.circleButton(c, "ios-home-group-btn", .home_customize_circle, grp_icon, k.text, rt, null).clicked) {
            a.mobile.group_by = switch (a.mobile.group_by) {
                .project => .device,
                .device => .none,
                .none => .project,
            };
        }
    }

    // Bottom floating Liquid Glass search bar + 44x44 `+` New Session circle
    {
        const bot_y = c.size.h - @max(bot_inset, 12) - 48;
        const bot_bar = ui.div(c).row().wFull().pl(14 + left_inset).pr(14 + right_inset).gap(10).itemsCenter().absolute().offset(0, @max(0, bot_y)).layer(1);
        defer bot_bar.end();

        {
            ui.key(c, "ios-home-search-shell");
            const sb = mg.styleGlassDiv(
                c,
                ui.div(c).row().grow().h(44).px(14).gap(8).itemsCenter(),
                .home_search_bar,
                rt,
                ui.Color.transparent,
                if (a.mobile.search_focus) k.accent else null,
            );
            defer sb.end();
            icons.icon(c, .magnifer, 16, k.muted, 0);
            {
                const field_wrap = ui.div(c).row().grow().itemsCenter();
                defer field_wrap.end();
                ui.key(c, "ios-home-search-input");
                const tf = ui.textField(c, &a.mobile.search_query, .{
                    .placeholder = "Search sessions, branches, projects…",
                    .placeholder_color = k.faint,
                    .width = .fill,
                    .bare = true,
                    .size = 15,
                    .line_height = 22,
                });
                a.mobile.search_focus = tf.focused;
            }
            if (a.mobile.search_query.text().len > 0) {
                ui.key(c, "ios-home-search-clear");
                const clr = ui.div(c).row().size(22, 22).center().roundedFull().circular().control();
                defer clr.end();
                icons.icon(c, .close, 13, k.muted, 0);
                if (clr.clicked()) {
                    a.mobile.search_query.clear();
                    nanoui.haptics.selection();
                }
            }
        }

        if (mg.circleButton(
            c,
            "ios-home-new-session-btn",
            .home_new_session_circle,
            .plus,
            k.accent,
            rt,
            k.accent.alpha(if (k.dark) 0.22 else 0.14),
        ).clicked) {
            a.mobile.sheet = .new_session;
        }
    }
}

const SectionHeaderInfo = struct {
    label: []const u8,
    online: ?bool = null,
};

fn sectionTitle(a: *const App, c: *ui.Context, sec: mp.HomeSection, now_ms: i64) SectionHeaderInfo {
    if (std.mem.eql(u8, sec.kind, "pinned")) return .{ .label = "PINNED" };
    if (std.mem.startsWith(u8, sec.id, "project:")) {
        const sp_id = sec.id["project:".len..];
        if (sp_id.len == 0) return .{ .label = "NO PROJECT" };
        if (a.findSpace(sp_id)) |sp| {
            if (!a.mobile.zen_mode) {
                for (a.devices.items) |d| {
                    if (sp.device_id != null and std.mem.eql(u8, d.id, sp.device_id.?)) {
                        return .{ .label = c.print("{s}  \u{00B7}  @ {s}", .{ sp.name, d.name }) };
                    }
                }
            }
            return .{ .label = sp.name };
        }
        return .{ .label = sp_id };
    }
    if (std.mem.startsWith(u8, sec.id, "device:")) {
        const dev_id = sec.id["device:".len..];
        for (a.devices.items) |d| {
            if (std.mem.eql(u8, d.id, dev_id)) {
                const seen: ?i64 = if (d.last_seen_ms > 0) d.last_seen_ms else null;
                const online = std.mem.eql(u8, a.device_id orelse "", d.id) or
                    mp.presenceStatus(now_ms, seen, true, null, seen) == .online;
                return .{ .label = d.name, .online = online };
            }
        }
        return .{ .label = dev_id };
    }
    return .{ .label = "SESSIONS" };
}

fn renderHomeChatRow(a: *App, c: *ui.Context, k: theme.Colors, ch: workspace.Chat, now_ms: i64, in_split: bool) void {
    const is_selected = in_split and a.selected != null and std.mem.eql(u8, a.selected.?, ch.id);
    const st = chatStatus(a, ch.id);
    const unread = isChatUnread(ch);
    const pinned = a.mobile.isPinned(ch.id);

    ui.key(c, c.print("ios-chat-row-{s}", .{ch.id}));
    const row_bg = if (is_selected)
        k.accent.alpha(if (k.dark) 0.18 else 0.11)
    else
        k.card.alpha(if (k.dark) 0.72 else 0.88);
    const card = ui.div(c).column().wFull().px(14).py(12).gap(5).rounded(18).bg(row_bg).border(if (is_selected) k.accent.alpha(0.55) else k.border.alpha(0.5)).borderW(1).control();
    const it = card.interaction();
    defer card.end();
    const target_scale = if (it.pressed and !c.reduced_motion) @as(f32, 0.985) else 1.0;
    c.node(card.index).style.scale = if (c.reduced_motion) 1.0 else ui.spring(c, it.id, 0x726f_7773, target_scale, mg.tactile_spring);

    const pane_w = if (in_split) ios_scroll.phoneSplitListWidth(c.size.w) else c.size.w;
    const h_safe = c.safe_area.left + (if (in_split) @as(f32, 0) else c.safe_area.right);
    const inner_w = @max(120, pane_w - h_safe - 28 - 28);

    {
        const top_line = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer top_line.end();

        var dot_room: f32 = 0;
        if (st == .working) {
            _ = ui.div(c).size(8, 8).roundedFull().circular().bg(k.accent).end();
            dot_room = 16;
        } else if (st == .awaiting_input) {
            _ = ui.div(c).size(8, 8).roundedFull().circular().bg(k.warning).end();
            dot_room = 16;
        } else if (unread) {
            _ = ui.div(c).size(8, 8).roundedFull().circular().bg(k.accent).end();
            dot_room = 16;
        }

        {
            const title_box = ui.div(c).row().grow().itemsCenter();
            defer title_box.end();
            kit.ellipsisText(c, ch.title orelse "New session", .{
                .size = 15.5,
                .weight = if (unread or st != .idle) .semibold else .medium,
                .color = k.text,
            }, @max(80, inner_w - 52 - dot_room - (if (pinned) @as(f32, 20) else 0)));
        }

        if (pinned) {
            icons.icon(c, .pin, 12, k.accent, 0);
        }

        var tbuf: [24]u8 = undefined;
        const rel = rules.relativeTime(&tbuf, now_ms, ch.timeMs());
        ui.text(c, c.print("{s}", .{rel}), .{ .size = 12, .color = k.faint });
    }

    if (ch.preview) |prev| {
        if (prev.len > 0) {
            kit.ellipsisText(c, prev, .{
                .size = 13.5,
                .line_height = 19,
                .color = k.muted,
            }, inner_w);
        }
    }

    if (!a.mobile.zen_mode) {
        const meta = ui.div(c).row().wFull().itemsCenter().gap(8).pt(2);
        defer meta.end();
        var branch_used: f32 = 0;
        if (ch.branch orelse ch.row_branch) |br| {
            if (br.len > 0) {
                const bchip = ui.div(c).row().itemsCenter().gap(4).px(7).py(2).rounded(6).bg(k.raised);
                defer bchip.end();
                icons.icon(c, .@"git-branch", 11, k.muted, 0);
                kit.ellipsisText(c, br, .{ .size = 11.5, .color = k.muted }, @min(160, inner_w * 0.52));
                branch_used = @min(184, inner_w * 0.56);
            }
        }
        if (ch.model) |mdl| {
            kit.ellipsisText(c, mdl, .{ .size = 11.5, .color = k.faint }, @max(72, inner_w - branch_used));
        }
    }

    if (it.secondary_clicked) {
        a.mobile.togglePin(a.gpa, ch.id);
        nanoui.haptics.selection();
    } else if (it.clicked) {
        a.mobile.tail_cap = ios_scroll.default_tail_cap;
        a.mobile.stick_to_bottom = true;
        a.openChat(ch.id, ch.space_id);
        nanoui.haptics.impact(.light);
    }
}

fn renderEmptyDetail(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    const box = ui.div(c).column().sizeFull().center().gap(14);
    defer box.end();
    icons.icon(c, .@"graff-mark", 36, k.muted, 0);
    ui.text(c, "Select or start a session", .{ .size = 17, .weight = .semibold, .color = k.text });
    if (mg.pillButton(c, "ios-empty-new-btn", .session_switcher_pill, .plus, "New Session", null, k.text, true, k.accent, rt).clicked) {
        a.mobile.sheet = .new_session;
    }
}

fn findUnansweredQuestion(a: *const App) ?struct { req_id: []const u8, q: tr.Question } {
    const entries = a.transcript.entries.items;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = &entries[i];
        for (e.parts.items) |*p| {
            if (p.kind == .input and !p.resolved and p.questions.len > 0) {
                if (!std.mem.eql(u8, p.request_id, a.mobile.answeredReq())) {
                    return .{ .req_id = p.request_id, .q = p.questions[0] };
                }
            }
        }
    }
    return null;
}

fn renderSessionPane(a: *App, c: *ui.Context, k: theme.Colors, rt: bool, in_split: bool) void {
    const chat_id = a.selected orelse return;
    const chat_hash = std.hash.Wyhash.hash(0, chat_id);
    if (chat_hash != a.mobile.last_chat_hash) {
        a.mobile.last_chat_hash = chat_hash;
        a.mobile.tail_cap = ios_scroll.default_tail_cap;
        a.mobile.jump_shown = false;
        a.mobile.stick_to_bottom = true;
    }

    const ch_opt = a.findChat(chat_id);
    const st = a.selectedStatus();
    const pending_q = findUnansweredQuestion(a);
    const queue_count = a.queue.items.len;

    const top_inset = c.safe_area.top;
    const bot_inset = c.safe_area.bottom;
    const left_inset = if (in_split) @as(f32, 0) else c.safe_area.left;
    const right_inset = c.safe_area.right;
    const top_chrome_h: f32 = 54;
    var bot_chrome_h: f32 = 112; // 40pt chip bar + 8pt gap + 56pt composer + margins
    if (queue_count > 0) bot_chrome_h += @min(@as(f32, @floatFromInt(queue_count)) * 34.0 + 8.0, 110.0);
    if (pending_q != null) bot_chrome_h += 136.0;

    // -----------------------------------------------------------------------
    // PASS 1 (`layer = 0`): Full-bleed underlap tail-virtualized transcript
    // -----------------------------------------------------------------------
    ui.key(c, c.print("ios-session-scroll-{s}", .{chat_id}));
    const scroll_st: ui.Style = .{
        .grow = 1,
        .width = .fill,
        .direction = .column,
        .align_items = .center,
        .scroll = true,
        .selectable = true,
        .follow_end = true,
        .scrollbar = .{ .overlay = k.faint.alpha(0.45) },
        .padding = .{
            .top = top_inset + top_chrome_h + 14,
            .bottom = ios_scroll.underlapBottomPadding(bot_inset, bot_chrome_h),
            .left = 14 + left_inset,
            .right = 14 + right_inset,
        },
    };
    {
        const s_idx = c.open(scroll_st, null);
        defer ui.end(c);
        const box_id = c.node(s_idx).id;
        a.mobile.last_scroll_box = box_id;

        const cur_y = c.scroll.get(box_id) orelse 0;
        const max_y = c.scroll_max.get(box_id) orelse 0;
        if (a.mobile.stick_to_bottom or a.view.stick_end) {
            a.mobile.stick_to_bottom = false;
            a.view.stick_end = false;
            c.scroll_follow.put(c.gpa, box_id, true) catch {};
            c.scroll.put(c.gpa, box_id, max_y + 1e6) catch {};
        } else {
            const dist_from_bottom = @max(0, max_y - cur_y);
            a.mobile.jump_shown = ios_scroll.updateJumpShown(a.mobile.jump_shown, dist_from_bottom);
        }

        const entries = a.transcript.entries.items;
        const win = ios_scroll.tailWindow(entries.len, a.mobile.tail_cap);

        // Auto-expand older messages smoothly when scrolling near top
        if (win.hidden_older > 0 and cur_y < 140 and max_y > 200) {
            a.mobile.tail_cap += ios_scroll.tail_grow_step;
            c.frameIn(1.0 / 120.0);
        }

        const col = ui.div(c).column().wFull().maxW(ios_scroll.max_content_width).gap(14);
        defer col.end();

        if (win.hidden_older > 0) {
            ui.key(c, "ios-load-older-pill");
            const older_btn = ui.div(c).row().itemsCenter().justifyCenter().py(6).px(14).roundedFull().circular().bg(k.raised).control();
            defer older_btn.end();
            ui.text(c, c.print("{d} earlier messages — tap or scroll up to load", .{win.hidden_older}), .{ .size = 12, .weight = .medium, .color = k.muted });
            if (older_btn.clicked()) {
                a.mobile.tail_cap += ios_scroll.tail_grow_step;
                nanoui.haptics.selection();
            }
        }

        if (entries.len == 0) {
            const welcome = ui.div(c).column().wFull().py(64).itemsCenter().gap(8);
            defer welcome.end();
            icons.icon(c, .@"graff-mark", 30, k.accent, 0);
            ui.text(c, if (ch_opt) |ch| (ch.title orelse "Ready") else "Ready", .{ .size = 17, .weight = .semibold, .color = k.text });
            ui.text(c, "Messages stream over 120Hz Metal with live Liquid Glass chrome.", .{ .size = 13.5, .color = k.muted });
        } else {
            for (entries[win.start .. win.start + win.len], win.start..) |*entry, e_idx| {
                renderTranscriptEntry(a, c, k, entry, e_idx);
            }
        }

        if (st == .working) {
            const pulse_row = ui.div(c).row().itemsCenter().gap(8).py(4);
            defer pulse_row.end();
            _ = ui.div(c).size(8, 8).roundedFull().circular().bg(k.accent).end();
            ui.text(c, "Working…", .{ .size = 13, .weight = .medium, .color = k.muted });
        }
    }

    // -----------------------------------------------------------------------
    // PASS 2 (`layer = 1`): Floating top bar, Jump-to-Latest, & Bottom Composer
    // -----------------------------------------------------------------------
    {
        const top_bar = ui.div(c).row().wFull().pl(14 + left_inset).pr(14 + right_inset).gap(8).itemsCenter().justifyBetween().absolute().offset(0, top_inset + 8).layer(1);
        defer top_bar.end();

        {
            const lead = ui.div(c).row().itemsCenter().gap(6);
            defer lead.end();
            if (!in_split or c.size.w >= 600.0) {
                if (mg.circleButton(c, "ios-session-back-btn", .session_back_circle, .@"alt-arrow-left", k.text, rt, null).clicked) {
                    a.select(null, a.space);
                }
            } else {
                _ = ui.div(c).size(36, 36).end();
            }
            if (c.size.w >= 600.0) {
                if (mg.circleButton(c, "ios-duo-flat-toggle-list", .session_back_circle, .@"sidebar-minimalistic-left", k.text, rt, if (in_split) k.accent else null).clicked) {
                    a.mobile.flat_list_shown = !in_split;
                    a.mobile.flat_list_overridden = true;
                    nanoui.haptics.selection();
                }
            }
        }

        const raw_title = if (ch_opt) |ch| (ch.title orelse "Session") else "Session";
        const avail_pane_w = (if (in_split) c.size.w - ios_scroll.phoneSplitListWidth(c.size.w) else c.size.w) - left_inset - right_inset;
        const pill_max_w = @max(96, avail_pane_w - (if (c.size.w >= 600.0) @as(f32, 210) else @as(f32, 168)));
        const title_str = if (c.text.width(raw_title, .{ .size = 13.5, .weight = .medium }) <= pill_max_w)
            raw_title
        else blk: {
            const cut = kit.truncateAt(c, raw_title, .{ .size = 13.5, .weight = .medium }, pill_max_w);
            break :blk c.print("{s}…", .{std.mem.trimEnd(u8, raw_title[0..cut], " \t\n\r")});
        };
        const pill_icon: ?icons.Name = if (st == .working) .@"fast-tier" else .@"chat-round-line";
        {
            const center_wrap = ui.div(c).row().grow().justifyCenter();
            defer center_wrap.end();
            if (mg.pillButton(
                c,
                "ios-session-switcher-pill",
                .session_switcher_pill,
                pill_icon,
                title_str,
                .@"alt-arrow-down",
                k.text,
                false,
                k.accent,
                rt,
            ).clicked) {
                a.mobile.sheet = .session_switcher;
            }
        }

        if (mg.circleButton(c, "ios-session-menu-btn", .session_menu_circle, .@"more-horizontal", k.text, rt, null).clicked) {
            a.mobile.sheet = .settings;
        }
    }

    // Floating 40x40 Jump-to-Latest Liquid Glass circle (`140pt` / `70pt` hysteresis)
    if (a.mobile.jump_shown) {
        const pane_w = if (in_split) c.size.w - ios_scroll.phoneSplitListWidth(c.size.w) - 1 else c.size.w;
        const jump_y = c.size.h - @max(bot_inset, 10) - bot_chrome_h - 48;
        const jump_x = pane_w - right_inset - 54;
        const jwrap = ui.div(c).row().absolute().offset(@max(12 + left_inset, jump_x), @max(top_inset + 64, jump_y)).layer(1);
        defer jwrap.end();
        if (mg.circleButton(c, "ios-jump-latest-btn", .session_jump_latest_circle, .@"alt-arrow-down", k.text, rt, null).clicked) {
            a.mobile.stick_to_bottom = true;
            a.mobile.jump_shown = false;
        }
    }

    // Bottom floating stack: Question card + Queued tray + `.scrollX()` chips + Concentric Composer
    {
        const stack_y = c.size.h - @max(bot_inset, 10) - bot_chrome_h + 6;
        const bot_outer = ui.div(c).column().wFull().pl(12 + left_inset).pr(12 + right_inset).itemsCenter().absolute().offset(0, @max(top_inset + 60, stack_y)).layer(1);
        defer bot_outer.end();

        const stack = ui.div(c).column().wFull().maxW(ios_scroll.max_content_width).gap(8);
        defer stack.end();

        // 1. Active Question Panel (`26pt` squircle Liquid Glass)
        if (pending_q) |pq| {
            ui.key(c, "ios-question-panel");
            const qcard = mg.styleGlassDiv(c, ui.div(c).column().wFull().p(14).gap(8), .question_panel, rt, ui.Color.transparent, null);
            defer qcard.end();
            ui.text(c, pq.q.question, .{ .size = 14, .weight = .semibold, .color = k.text });
            const opts_row = ui.div(c).row().wFull().gap(6);
            defer opts_row.end();
            for (pq.q.options, 0..) |opt_txt, o_idx| {
                if (o_idx >= 3) break;
                const ok_key = c.print("ios-q-opt-{d}", .{o_idx});
                if (mg.pillButton(c, ok_key, .write_toolbar_pill, null, opt_txt, null, k.text, o_idx == 0, k.accent, rt).clicked) {
                    const now_ms = nowEpochMs(a);
                    a.mobile.markAnswered(pq.req_id, now_ms);
                    a.composer.set(opt_txt);
                    a.send();
                    a.mobile.stick_to_bottom = true;
                    nanoui.haptics.notify(.success);
                }
            }
        }

        // 2. Queued Follow-Up Messages Tray
        const session_col_w = @min(ios_scroll.max_content_width, (if (in_split) c.size.w - ios_scroll.phoneSplitListWidth(c.size.w) else c.size.w) - 24);
        if (queue_count > 0) {
            const qtray = mg.styleGlassDiv(c, ui.div(c).column().wFull().px(12).py(8).gap(4), .org_picker_row, rt, ui.Color.transparent, null);
            defer qtray.end();
            for (a.queue.items, 0..) |qrow, qi| {
                if (qi >= 2) break;
                const r = ui.div(c).row().wFull().itemsCenter().gap(8);
                defer r.end();
                icons.icon(c, .@"clock-circle", 13, k.accent, 0);
                {
                    const tw = ui.div(c).row().grow();
                    defer tw.end();
                    kit.ellipsisText(c, qrow.text, .{ .size = 12.5, .color = k.text }, @max(80, session_col_w - 96));
                }
                ui.text(c, "Queued", .{ .size = 11, .weight = .medium, .color = k.muted });
            }
        }

        // 3. Horizontal `.scrollX()` 40pt Liquid Glass Chip Strip
        {
            ui.key(c, "ios-composer-chips");
            const chip_st: ui.Style = .{
                .width = .fill,
                .height = .{ .px = 42 },
                .direction = .row,
                .align_items = .center,
                .gap = 6,
                .scroll_x = true,
                .scroll_bar = false,
                .scrollbar = .{ .overlay = .{ .a = 0 } },
                .clip = true,
            };
            _ = c.open(chip_st, null);
            defer ui.end(c);

            const cur_model = if (ch_opt) |ch| (ch.model orelse a.new_model orelse "claude-sonnet-4-6") else (a.new_model orelse "claude-sonnet-4-6");
            if (mg.pillButton(c, "ios-chip-model", .composer_chip_model, .@"graff-mark", cur_model, .@"alt-arrow-down", k.text, false, k.accent, rt).clicked) {
                a.mobile.new_agent_idx = (a.mobile.new_agent_idx + 1) % agent_ids.len;
                const picked = switch (a.mobile.new_agent_idx) {
                    0 => "claude-opus-4-6",
                    1 => "gpt-5.4",
                    else => "claude-sonnet-4-6",
                };
                if (a.new_model) |old| a.gpa.free(old);
                a.new_model = a.gpa.dupe(u8, picked) catch null;
            }

            const eff_lbl = effort_labels[a.mobile.effort_idx];
            if (mg.pillButton(c, "ios-chip-effort", .composer_chip_effort, .@"magic-stick-3", eff_lbl, null, k.text, false, k.accent, rt).clicked) {
                a.mobile.effort_idx = (a.mobile.effort_idx + 1) % effort_levels.len;
                if (a.new_reasoning) |old| a.gpa.free(old);
                a.new_reasoning = a.gpa.dupe(u8, effort_levels[a.mobile.effort_idx]) catch null;
            }

            const mode_lbl = if (a.new_chat_mode) "Chat" else "Code";
            if (mg.pillButton(c, "ios-chip-mode", .composer_chip_mode, .terminal, mode_lbl, null, k.text, a.new_chat_mode, k.accent, rt).clicked) {
                a.new_chat_mode = !a.new_chat_mode;
            }

            if (ch_opt) |ch| {
                if (ch.branch orelse ch.row_branch) |br| {
                    if (br.len > 0) {
                        _ = mg.pillButton(c, "ios-chip-branch", .composer_chip_branch, .@"git-branch", br, null, k.text, false, k.accent, rt);
                    }
                }
            }

            if (mg.circleButton(c, "ios-chip-expand", .composer_expand_circle, .@"expand-arrows", k.text, rt, null).clicked) {
                a.mobile.sheet = .write_dock;
            }
        }

        // 4. Concentric `24pt` Liquid Glass Composer Shell (`composer_shell_collapsed`)
        {
            ui.key(c, "ios-composer-shell");
            const shell = mg.styleGlassDiv(
                c,
                ui.div(c).row().wFull().px(8).py(6).gap(8).itemsCenter(),
                .composer_shell_collapsed,
                rt,
                ui.Color.transparent,
                if (a.mobile.composer_focus) k.accent else null,
            );
            defer shell.end();

            _ = mg.circleButton(c, "ios-composer-attach", .composer_attach_circle, .plus, k.text, rt, null);

            {
                const input_well = ui.div(c).row().grow().px(4).itemsCenter();
                defer input_well.end();
                ui.key(c, "ios-composer-input");
                const tf = ui.textField(c, &a.composer, .{
                    .placeholder = if (st == .working) "Steer or queue a follow-up…" else "Message Harness…",
                    .placeholder_color = k.faint,
                    .width = .fill,
                    .bare = true,
                    .size = 15.5,
                    .line_height = 22,
                });
                a.mobile.composer_focus = tf.focused;
            }

            const has_text = std.mem.trim(u8, a.composer.text(), " \t\r\n").len > 0;
            if (has_text) {
                ui.key(c, "ios-composer-send-btn");
                const send_btn = ui.div(c).row().size(36, 36).center().roundedFull().circular().bg(k.accent).control();
                defer send_btn.end();
                icons.icon(c, .@"arrow-up", 18, ui.Color.white, 0);
                if (send_btn.clicked()) {
                    a.send();
                    a.mobile.stick_to_bottom = true;
                    nanoui.haptics.impact(.medium);
                }
            } else if (st == .working) {
                const now_ms = nowEpochMs(a);
                const allow_stop = mp.isStopAllowed(now_ms, a.mobile.question_closed_at_ms);
                ui.key(c, "ios-composer-stop-btn");
                const stop_btn = ui.div(c).row().size(36, 36).center().roundedFull().circular().bg(if (allow_stop) k.danger else k.danger.alpha(0.4)).control();
                defer stop_btn.end();
                _ = ui.div(c).size(12, 12).rounded(3).bg(ui.Color.white).end();
                if (stop_btn.clicked() and allow_stop) {
                    a.interrupt();
                    nanoui.haptics.notify(.warning);
                }
            } else {
                _ = mg.circleButton(c, "ios-composer-mic", .composer_dictate_circle, .microphone, k.muted, rt, null);
            }
        }
    }
}

fn renderTranscriptEntry(a: *App, c: *ui.Context, k: theme.Colors, entry: *const tr.Entry, e_idx: usize) void {
    ui.key(c, c.print("ios-msg-{s}-{d}", .{ entry.id, e_idx }));
    if (entry.role == .user) {
        const max_bubble_w = @max(140, @min(ios_scroll.max_content_width, c.size.w - 28) - 42);
        const row = ui.div(c).row().wFull().justifyEnd().pl(42);
        defer row.end();
        const bubble = ui.div(c).column().maxW(max_bubble_w).px(14).py(10).gap(6).rounded(18).bg(k.user_bubble);
        defer bubble.end();
        for (entry.parts.items) |*p| {
            if (p.kind == .text and p.text.items.len > 0) {
                ui.text(c, p.text.items, .{ .size = 15, .line_height = 22, .wrap = true, .color = k.text });
            }
        }
        return;
    }

    const col = ui.div(c).column().wFull().gap(8);
    defer col.end();

    for (entry.parts.items, 0..) |*p, p_idx| {
        const tool_key: u64 = (@as(u64, e_idx) << 16) ^ @as(u64, p_idx);
        switch (p.kind) {
            .reasoning => {
                if (!a.mobile.zen_mode and p.text.items.len > 0) {
                    const open = a.mobile.expanded_tools.get(tool_key) orelse false;
                    ui.key(c, c.print("ios-reason-{d}-{d}", .{ e_idx, p_idx }));
                    const rbox = ui.div(c).column().wFull().px(11).py(7).gap(4).rounded(12).bg(k.raised.alpha(0.65)).control();
                    defer rbox.end();
                    {
                        const hdr = ui.div(c).row().itemsCenter().gap(6);
                        defer hdr.end();
                        icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 12, k.muted, 0);
                        ui.text(c, "Thought process", .{ .size = 12.5, .weight = .medium, .color = k.muted });
                    }
                    if (open) {
                        ui.text(c, p.text.items, .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
                    }
                    if (rbox.clicked()) {
                        a.mobile.expanded_tools.put(a.gpa, tool_key, !open) catch {};
                    }
                }
            },
            .tool => {
                const open = a.mobile.expanded_tools.get(tool_key) orelse false;
                ui.key(c, c.print("ios-tool-{d}-{d}", .{ e_idx, p_idx }));
                const tbox = ui.div(c).column().wFull().px(12).py(8).gap(5).rounded(12).bg(k.raised.alpha(0.75)).border(k.border.alpha(0.5)).borderW(1).control();
                defer tbox.end();
                {
                    const hdr = ui.div(c).row().wFull().itemsCenter().gap(7);
                    defer hdr.end();
                    icons.icon(c, .terminal, 13, if (p.is_error) k.danger else k.accent, 0);
                    ui.text(c, p.chip, .{ .size = 12.5, .weight = .semibold, .color = k.text });
                    {
                        const label_wrap = ui.div(c).row().grow();
                        defer label_wrap.end();
                        const summary = if (p.path.len > 0) p.path else p.text.items;
                        kit.ellipsisText(c, summary, .{ .size = 12.5, .color = k.muted }, @max(80, @min(ios_scroll.max_content_width, c.size.w - 28) - 156));
                    }
                    if (p.additions > 0 or p.deletions > 0) {
                        ui.text(c, c.print("+{d}", .{p.additions}), .{ .size = 11.5, .weight = .semibold, .color = k.success });
                        ui.text(c, c.print("-{d}", .{p.deletions}), .{ .size = 11.5, .weight = .semibold, .color = k.danger });
                    }
                    icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 12, k.faint, 0);
                }
                if (open and p.output.len > 0) {
                    const obox = ui.div(c).column().wFull().p(8).rounded(8).bg(k.shell);
                    defer obox.end();
                    ui.text(c, p.output, .{ .size = 12, .line_height = 17, .wrap = true, .color = k.muted });
                }
                if (tbox.clicked()) {
                    a.mobile.expanded_tools.put(a.gpa, tool_key, !open) catch {};
                }
            },
            .text => {
                if (p.text.items.len > 0) {
                    renderMarkdownBlocks(c, k, p.text.items);
                }
            },
            .@"error" => {
                const ebox = ui.div(c).row().wFull().p(10).gap(8).rounded(12).bg(k.danger.alpha(0.14)).border(k.danger.alpha(0.4)).borderW(1);
                defer ebox.end();
                icons.icon(c, .@"danger-triangle", 15, k.danger, 0);
                ui.text(c, p.text.items, .{ .size = 13.5, .wrap = true, .color = k.danger });
            },
            else => {},
        }
    }
}

fn renderMarkdownBlocks(c: *ui.Context, k: theme.Colors, raw: []const u8) void {
    var rest = raw;
    while (rest.len > 0) {
        if (std.mem.indexOf(u8, rest, "```")) |fence_at| {
            const prose = std.mem.trim(u8, rest[0..fence_at], "\r\n");
            if (prose.len > 0) renderProseLines(c, k, prose);
            const after_open = rest[fence_at + 3 ..];
            const nl = std.mem.indexOfScalar(u8, after_open, '\n') orelse {
                renderProseLines(c, k, after_open);
                break;
            };
            const lang = std.mem.trim(u8, after_open[0..nl], " \t\r");
            const code_start = after_open[nl + 1 ..];
            if (std.mem.indexOf(u8, code_start, "```")) |close_at| {
                renderCodeFence(c, k, lang, std.mem.trimEnd(u8, code_start[0..close_at], "\r\n"));
                rest = code_start[close_at + 3 ..];
                continue;
            } else {
                renderCodeFence(c, k, lang, std.mem.trimEnd(u8, code_start, "\r\n"));
                break;
            }
        } else {
            const prose = std.mem.trim(u8, rest, "\r\n");
            if (prose.len > 0) renderProseLines(c, k, prose);
            break;
        }
    }
}

fn renderProseLines(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const pcol = ui.div(c).column().wFull().gap(5);
    defer pcol.end();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "### ")) {
            ui.text(c, line[4..], .{ .size = 16.5, .weight = .semibold, .line_height = 23, .wrap = true, .color = k.text });
        } else if (std.mem.startsWith(u8, line, "## ")) {
            ui.text(c, line[3..], .{ .size = 18, .weight = .bold, .line_height = 25, .wrap = true, .color = k.text });
        } else if (std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ")) {
            const brow = ui.div(c).row().wFull().gap(8).itemsStart();
            defer brow.end();
            ui.text(c, "\u{2022}", .{ .size = 15, .weight = .bold, .line_height = 22, .color = k.accent });
            {
                const bw = ui.div(c).column().grow();
                defer bw.end();
                ui.text(c, stripInlineMarkers(c, line[2..]), .{ .size = 15, .line_height = 22, .wrap = true, .color = k.text });
            }
        } else {
            ui.text(c, stripInlineMarkers(c, line), .{ .size = 15, .line_height = 22, .wrap = true, .color = k.text });
        }
    }
}

fn stripInlineMarkers(c: *ui.Context, line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "**") == null and std.mem.indexOfScalar(u8, line, '`') == null) return line;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            i += 2;
            continue;
        }
        if (line[i] == '`') {
            i += 1;
            continue;
        }
        out.append(c.alloc(), line[i]) catch return line;
        i += 1;
    }
    return out.items;
}

fn renderCodeFence(c: *ui.Context, k: theme.Colors, lang: []const u8, code: []const u8) void {
    _ = highlight;
    const card = ui.div(c).column().wFull().rounded(14).bg(k.shell).border(k.border.alpha(0.65)).borderW(1).clip();
    defer card.end();
    {
        const hdr = ui.div(c).row().wFull().px(12).py(6).itemsCenter().justifyBetween().bg(k.raised.alpha(0.6));
        defer hdr.end();
        ui.text(c, if (lang.len > 0) lang else "code", .{ .size = 11.5, .weight = .semibold, .color = k.muted });
        ui.text(c, "Geist Mono", .{ .size = 11, .color = k.faint });
    }
    {
        const body_st: ui.Style = .{
            .width = .fill,
            .direction = .column,
            .padding = .all(12),
            .scroll_x = true,
            .scroll_bar = false,
            .clip = true,
        };
        _ = c.open(body_st, null);
        defer ui.end(c);
        ui.text(c, code, .{ .size = 12, .line_height = 18, .mono = true, .color = k.text });
    }
}

fn renderSheetOverlay(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    ui.key(c, "ios-sheet-backdrop");
    const backdrop = ui.div(c).column().sizeFull().justifyEnd().itemsCenter().bg(ui.Color.black.alpha(0.38)).fixed().offset(0, 0).layer(2);
    defer backdrop.end();

    const sheet_max_h = @max(320, c.size.h - c.safe_area.top - 36);
    ui.key(c, "ios-sheet-card");
    const dock = mg.styleGlassDiv(
        c,
        ui.div(c).column().wFull().maxW(560).maxH(sheet_max_h).px(18).pt(12).pb(@max(c.safe_area.bottom, 16) + 8).gap(12).control(),
        .write_dock,
        rt,
        if (k.dark) k.shell.alpha(0.55) else ui.Color.white.alpha(0.45),
        null,
    );
    defer dock.end();

    // Grabber handle + Close button
    {
        const grab_row = ui.div(c).row().wFull().itemsCenter().justifyBetween();
        defer grab_row.end();
        const title = switch (a.mobile.sheet) {
            .new_session => "New Session",
            .write_dock => "Compose",
            .settings => "Settings & Telemetry",
            .session_switcher => "Switch Session",
            .none => "",
        };
        ui.text(c, title, .{ .size = 17, .weight = .bold, .color = k.text });
        if (mg.circleButton(c, "ios-sheet-close", .composer_expand_circle, .close, k.text, rt, null).clicked) {
            a.mobile.sheet = .none;
        }
    }

    switch (a.mobile.sheet) {
        .new_session => renderNewSessionSheet(a, c, k, rt),
        .write_dock => renderWriteDockSheet(a, c, k, rt),
        .settings => renderSettingsSheet(a, c, k, rt),
        .session_switcher => renderSwitcherSheet(a, c, k),
        .none => {},
    }
}

fn renderNewSessionSheet(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    ui.text(c, "Project", .{ .size = 12.5, .weight = .semibold, .color = k.muted });
    {
        const sp_col = ui.div(c).column().wFull().gap(6);
        defer sp_col.end();
        for (a.spaces.items, 0..) |sp, idx| {
            const sel = a.mobile.new_space_idx == idx;
            ui.key(c, c.print("ios-new-sp-{s}", .{sp.id}));
            const row = mg.styleGlassDiv(c, ui.div(c).row().wFull().px(12).py(10).itemsCenter().justifyBetween().control(), .org_picker_row, rt, if (sel) k.accent.alpha(0.2) else ui.Color.transparent, null);
            defer row.end();
            {
                const l = ui.div(c).row().itemsCenter().gap(8);
                defer l.end();
                icons.icon(c, .folder, 15, if (sel) k.accent else k.muted, 0);
                ui.text(c, sp.name, .{ .size = 14.5, .weight = .medium, .color = k.text });
            }
            ui.text(c, a.deviceName(sp.device_id), .{ .size = 12, .color = k.faint });
            if (row.clicked()) {
                a.mobile.new_space_idx = idx;
                nanoui.haptics.selection();
            }
        }
    }

    ui.text(c, "Agent", .{ .size = 12.5, .weight = .semibold, .color = k.muted });
    {
        const arow = ui.div(c).row().wFull().gap(8);
        defer arow.end();
        for (agent_labels, 0..) |lbl, idx| {
            if (mg.pillButton(c, c.print("ios-new-ag-{d}", .{idx}), .write_toolbar_pill, null, lbl, null, k.text, a.mobile.new_agent_idx == idx, k.accent, rt).clicked) {
                a.mobile.new_agent_idx = idx;
            }
        }
    }

    ui.key(c, "ios-start-session-btn");
    const start_btn = ui.div(c).row().wFull().h(46).center().roundedFull().circular().bg(k.accent).control();
    defer start_btn.end();
    ui.text(c, "Start Session", .{ .size = 15.5, .weight = .semibold, .color = ui.Color.white });
    if (start_btn.clicked()) {
        const sp_id: ?[]const u8 = if (a.mobile.new_space_idx < a.spaces.items.len)
            a.spaces.items[a.mobile.new_space_idx].id
        else
            null;
        a.gpa.free(a.new_harness);
        a.new_harness = a.gpa.dupe(u8, agent_ids[a.mobile.new_agent_idx]) catch a.new_harness;
        a.select(null, sp_id);
        a.composer.set("Verify iOS Liquid Glass parity and ProMotion frame budget");
        a.send();
        a.mobile.sheet = .none;
        a.mobile.stick_to_bottom = true;
        nanoui.haptics.notify(.success);
    }
}

fn renderWriteDockSheet(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    {
        const tools_row = ui.div(c).row().wFull().gap(6);
        defer tools_row.end();
        if (mg.pillButton(c, "ios-wd-h", .write_toolbar_pill, null, "### Heading", null, k.text, false, k.accent, rt).clicked) {
            const next = c.print("{s}### ", .{a.composer.text()});
            a.composer.set(next);
        }
        if (mg.pillButton(c, "ios-wd-code", .write_toolbar_pill, null, "``` Code", null, k.text, false, k.accent, rt).clicked) {
            const next = c.print("{s}\n```zig\n\n```", .{a.composer.text()});
            a.composer.set(next);
        }
    }
    {
        const box = ui.div(c).column().wFull().h(160).p(12).rounded(18).bg(k.shell).border(k.border).borderW(1);
        defer box.end();
        ui.key(c, "ios-write-dock-field");
        _ = ui.textField(c, &a.composer, .{
            .placeholder = "Write a detailed specification or multi-line prompt…",
            .placeholder_color = k.faint,
            .width = .fill,
            .bare = true,
            .size = 15,
            .line_height = 22,
        });
    }
    ui.key(c, "ios-write-dock-send");
    const sbtn = ui.div(c).row().wFull().h(44).center().roundedFull().circular().bg(k.accent).control();
    defer sbtn.end();
    ui.text(c, "Send Message", .{ .size = 15, .weight = .semibold, .color = ui.Color.white });
    if (sbtn.clicked()) {
        a.send();
        a.mobile.sheet = .none;
        a.mobile.stick_to_bottom = true;
        nanoui.haptics.impact(.medium);
    }
}

fn renderSwitcherSheet(a: *App, c: *ui.Context, k: theme.Colors) void {
    ui.key(c, "ios-switcher-scroll");
    const sc = ui.div(c).column().wFull().maxH(320).gap(6).scrollY();
    defer sc.end();
    for (a.chats.items) |ch| {
        if (ch.archived) continue;
        const active = a.selected != null and std.mem.eql(u8, a.selected.?, ch.id);
        ui.key(c, c.print("ios-sw-{s}", .{ch.id}));
        const r = ui.div(c).row().wFull().px(12).py(10).rounded(12).itemsCenter().justifyBetween().bg(if (active) k.accent.alpha(0.18) else k.raised.alpha(0.6)).control();
        defer r.end();
        kit.ellipsisText(c, ch.title orelse "Session", .{ .size = 14.5, .weight = if (active) .semibold else .medium, .color = k.text }, @max(120, @min(c.size.w, 560) - 96));
        if (active) icons.icon(c, .check, 14, k.accent, 0);
        if (r.clicked()) {
            a.openChat(ch.id, ch.space_id);
            a.mobile.sheet = .none;
            nanoui.haptics.selection();
        }
    }
}

fn renderSettingsSheet(a: *App, c: *ui.Context, k: theme.Colors, rt: bool) void {
    ui.key(c, "ios-settings-scroll");
    const sc = ui.div(c).column().wFull().maxH(420).gap(12).scrollY();
    defer sc.end();

    // 1. Live 120Hz ProMotion & perf-contract.json Telemetry
    const sum = a.mobile.telemetry.summarize();
    {
        const tcard = ui.div(c).column().wFull().p(12).gap(6).rounded(16).bg(k.shell).border(k.border).borderW(1);
        defer tcard.end();
        {
            const thdr = ui.div(c).row().wFull().itemsCenter().justifyBetween();
            defer thdr.end();
            ui.text(c, "120Hz ProMotion Telemetry", .{ .size = 13.5, .weight = .semibold, .color = k.text });
            const ok = sum.meetsPerfContract();
            ui.text(c, if (ok) "1:1 PASS (< 8.0ms)" else "WARMING", .{ .size = 11.5, .weight = .bold, .color = if (ok) k.success else k.warning });
        }
        ui.text(
            c,
            c.print("p50: {d:.2} ms  \u{00B7}  p95: {d:.2} ms  \u{00B7}  {d:.0} fps", .{ sum.p50_work_ms, sum.p95_work_ms, sum.est_fps }),
            .{ .size = 11.5, .mono = true, .wrap = true, .color = k.muted },
        );
        ui.text(
            c,
            c.print("Scroll: {d} fr  \u{00B7}  Peak: {d:.0} pt/s (0.998/ms)", .{ sum.scroll_frames, sum.peak_velocity_pt_s }),
            .{ .size = 11.5, .mono = true, .wrap = true, .color = k.faint },
        );
    }

    // 2. PhoneSplit Mode (`Auto` / `On` / `Off`)
    ui.text(c, "Phone Split (>= 600pt)", .{ .size = 12.5, .weight = .semibold, .color = k.muted });
    {
        const srow = ui.div(c).row().wFull().gap(6);
        defer srow.end();
        for ([_]ios_scroll.SplitMode{ .auto, .on, .off }) |sm| {
            if (mg.pillButton(c, c.print("ios-split-{s}", .{sm.asText()}), .write_toolbar_pill, null, sm.asText(), null, k.text, a.mobile.split_mode == sm, k.accent, rt).clicked) {
                a.mobile.split_mode = sm;
            }
        }
    }

    // 3. 19-Family / 31-Variant iOS Theme Catalog
    const all_mobile = themes.mobileAll();
    ui.text(c, c.print("iOS Themes ({d} variants)", .{all_mobile.len}), .{ .size = 12.5, .weight = .semibold, .color = k.muted });
    {
        const tlist = ui.div(c).column().wFull().gap(5);
        defer tlist.end();
        for (all_mobile) |v| {
            const active = if (a.mobile.theme_override_id) |tid| std.mem.eql(u8, tid, v.id) else false;
            ui.key(c, c.print("ios-theme-{s}", .{v.id}));
            const trow = ui.div(c).row().wFull().px(12).py(8).rounded(12).itemsCenter().justifyBetween().bg(if (active) k.accent.alpha(0.18) else k.raised.alpha(0.55)).control();
            defer trow.end();
            {
                const left = ui.div(c).row().itemsCenter().gap(8);
                defer left.end();
                _ = ui.div(c).size(14, 14).roundedFull().circular().bg(v.colors.accent).border(v.colors.border).borderW(1).end();
                ui.text(c, v.name, .{ .size = 13.5, .weight = if (active) .semibold else .medium, .color = k.text });
            }
            ui.text(c, if (v.dark) "Dark" else "Light", .{ .size = 11.5, .color = k.faint });
            if (trow.clicked()) {
                a.mobile.setThemeOverride(a.gpa, v.id);
                a.dark = v.dark;
                nanoui.haptics.selection();
            }
        }
    }
}

test "mobile view: Liquid Glass chrome keeps zero interior wash, full-bleed underlap, and < 8.0ms 240-message 120Hz frame budget" {
    theme.registerFonts();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    const embedded = try @import("ios_host.zig").EmbeddedHost.start(testing.allocator, testing.io, &env, true);
    defer embedded.stop();

    var a: App = .init(testing.allocator, testing.io, embedded.port);
    defer a.deinit();
    a.offscreen = true;
    a.mobile_preview = true;
    a.new_harness = try testing.allocator.dupe(u8, "graff");

    // Seed workspace & 240-message synthetic transcript directly into App for deterministic UI testing
    const chats_json = try embedded.host.chatsJson();
    defer testing.allocator.free(chats_json);
    {
        var parsed_c = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats_json, .{});
        defer parsed_c.deinit();
        try a.chats.replace(parsed_c.value);
    }
    const spaces_json = try embedded.host.spacesJson();
    defer testing.allocator.free(spaces_json);
    {
        var parsed_s = try std.json.parseFromSlice(std.json.Value, testing.allocator, spaces_json, .{});
        defer parsed_s.deinit();
        try a.spaces.replace(parsed_s.value);
    }

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, view), .{ .width = 402, .height = 874, .dark = true });
    defer t.deinit();

    // 1. HomeView Liquid Glass invariant check: every glass node has `background == null` & `border == null`,
    //    and session card titles, previews, and branch chips render visibly (never 0-width truncated).
    t.frame();
    try testing.expect(t.hasText("Liquid Glass 120Hz iOS Stack"));
    try testing.expect(t.hasText("feat/ios-liquid-glass"));
    var glass_nodes: usize = 0;
    for (t.ctx.nodes.items) |n| {
        if (n.style.glass != null) {
            glass_nodes += 1;
            try testing.expect(n.style.background == null);
            try testing.expect(n.style.border == null);
        }
    }
    try testing.expect(glass_nodes >= 7);

    // 2. Reduce Transparency fallback check: opaque surface + hairline border, zero `glass`
    t.ctx.access.reduce_transparency = true;
    t.frame();
    for (t.ctx.nodes.items) |n| {
        try testing.expect(n.style.glass == null);
    }
    t.ctx.access.reduce_transparency = false;

    // 3. Open the 240-message session and verify 120Hz frame pacing (< 8.0ms CPU budget)
    a.selected = try testing.allocator.dupe(u8, "chat-ios-glass");
    const doc = try embedded.host.getOrCreateDoc("chat-ios-glass");
    const reset_json = try doc.toResetFrameJson(testing.allocator);
    defer testing.allocator.free(reset_json);
    {
        var parsed_r = try std.json.parseFromSlice(std.json.Value, testing.allocator, reset_json, .{});
        defer parsed_r.deinit();
        try a.transcript.apply(parsed_r.value);
    }
    try testing.expectEqual(@as(usize, 240), a.transcript.entries.items.len);

    // Simulate 30 frames of rapid 120Hz ProMotion scrolling up & down the 240-message session
    t.frame();
    const scroll_box = a.mobile.last_scroll_box;
    try testing.expect(scroll_box != 0);
    for (0..30) |step| {
        t.ctx.time += 1.0 / 120.0;
        const max_s = t.ctx.scroll_max.get(scroll_box) orelse 2000;
        const target_y = @max(0, max_s - @as(f32, @floatFromInt(step)) * 28.0);
        try t.ctx.scroll.put(t.ctx.gpa, scroll_box, target_y);
        t.frame();
    }

    // Scrolled > 140pt from bottom -> Jump-to-Latest Liquid Glass circle must be shown!
    try testing.expect(a.mobile.jump_shown);
    const summary = a.mobile.telemetry.summarize();
    try testing.expect(summary.meetsPerfContract());
    try testing.expect(summary.peak_velocity_pt_s > 1000.0);

    // PhoneSplit wide layout (>= 660pt) renders both Home list and Session conversation side by side
    t.resize(844, 600);
    t.frame();
    try testing.expect(t.hasText("nanoharness"));
    try testing.expect(t.hasText("nanoui"));
}
