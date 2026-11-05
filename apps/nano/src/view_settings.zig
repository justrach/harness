//! The Settings page, as the GPUI app's: its sidebar (shell.rs
//! `render_settings_nav`: search, the sections under their groups, Back)
//! in place of the sessions list, and each section's page built from the
//! same kit (settings/widgets.rs). ⌘, opens it, at the section last shown.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const settings = @import("settings.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;
const Section = settings.Section;

/// GPUI's line height, as a multiple of the text's size.
const phi: f32 = 1.618;

/// Text at `size` on GPUI's line height, exactly: rounded to the point,
/// 21.03 became 22 and a card's rows slipped 1.5 points a row.
pub fn st(c: *ui.Context, size: f32, base: ui.TextStyle) ui.TextStyle {
    _ = c;
    var s = base;
    s.size = size;
    // On the device pixel, as GPUI lays lines out (half a point at 2x).
    s.line_height = @round(size * phi * 2) / 2;
    return s;
}

pub fn open(a: *App) void {
    a.view.settings_open = true;
    a.view.account_menu = false;
    a.redraw();
}

pub fn close(a: *App) void {
    a.view.settings_open = false;
    a.view.settings_search.clear();
    a.redraw();
}

fn show(a: *App, s: Section) void {
    a.settings.setSection(s);
    a.view.settings_search.clear();
    a.redraw();
}

/// The sections a search finds: those whose name has the query in it.
pub fn matches(query: []const u8, buf: []Section) []Section {
    var n: usize = 0;
    for (Section.all) |s| {
        if (containsIgnoreCase(s.label(), query)) {
            buf[n] = s;
            n += 1;
        }
    }
    return buf[0..n];
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (0..hay.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    return false;
}

/// Space above the next box (the GPUI kit's `mt`).
pub fn space(c: *ui.Context, h: f32) void {
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = h } }, .none, null);
}

/// In the sidebar's place: "Settings", the search, the sections under their
/// groups, and Back at the foot.
pub fn nav(c: *ui.Context, a: *App, k: theme.Colors) void {
    const side = ui.div(c).column().w(sidebar.width).hFull().bg(k.sidebar).pt(sidebar.titlebar_h);
    defer side.end();
    {
        const list = ui.div(c).column().wFull().grow().h(0).px(8).clip();
        defer list.end();
        {
            const h = ui.div(c).row().px(8).pt(12).pb(8);
            defer h.end();
            ui.text(c, "Settings", st(c, 11, .{ .weight = .medium, .color = k.muted.alpha(0.6) }));
        }
        {
            // 33 tall: GPUI's search is a composer input, 5 above and below.
            const s = ui.div(c).row().wFull().h(33).px(8).gap(6).itemsCenter().rounded(8).bg(k.ink(0.04));
            defer s.end();
            icons.icon(c, .magnifer, 14, k.muted, 0);
            const f = ui.div(c).row().grow().w(0);
            defer f.end();
            _ = ui.textField(c, &a.view.settings_search, .{ .placeholder = "Search settings", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .line_height = 22.75 });
        }
        const rows = ui.div(c).column().wFull().gap(2);
        defer rows.end();
        const query = std.mem.trim(u8, a.view.settings_search.text(), " ");
        if (query.len > 0) {
            var buf: [Section.all.len]Section = undefined;
            const found = matches(query, &buf);
            if (found.len == 0) {
                const e = ui.div(c).row().px(8).py(6);
                defer e.end();
                ui.text(c, "No matching settings", st(c, 12, .{ .color = k.muted }));
            }
            for (found, 0..) |s, i| if (navRow(c, k, s, i == 0)) show(a, s);
            return;
        }
        var group: []const u8 = "";
        for (Section.all) |s| {
            if (!std.mem.eql(u8, group, s.group())) {
                group = s.group();
                const h = ui.div(c).row().px(8).pt(12).pb(4);
                defer h.end();
                ui.text(c, group, st(c, 11, .{ .weight = .medium, .color = k.muted.alpha(0.6) }));
            }
            if (navRow(c, k, s, s == a.settings.section)) show(a, s);
        }
    }
    // A running cloud sandbox stays in view on every settings page too.
    @import("view_sandbox_strip.zig").strip(c, a, k, 4);
    const foot = ui.div(c).column().wFull().px(8).pb(12);
    defer foot.end();
    const back = ui.div(c).row().wFull().px(8).py(6).gap(6).itemsCenter().rounded(8).hover(k.hover);
    defer back.end();
    const hot = back.hovered();
    icons.icon(c, .@"alt-arrow-left", 16, k.muted, 0);
    ui.text(c, "Back", st(c, 13, .{ .color = if (hot) k.text else k.muted }));
    if (back.clicked()) close(a);
}

fn navRow(c: *ui.Context, k: theme.Colors, s: Section, selected: bool) bool {
    ui.key(c, s.key());
    var r = ui.div(c).row().wFull().px(8).py(6).gap(8).itemsCenter().rounded(8);
    r = if (selected) r.bg(k.selected) else r.hover(k.hover);
    defer r.end();
    const hot = r.hovered();
    icons.icon(c, s.icon(), 16, k.muted, 0);
    ui.text(c, s.label(), st(c, 13, .{ .weight = if (selected) .medium else .regular, .color = if (selected or hot) k.text else k.muted }));
    return r.clicked();
}

/// The open section's page.
pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    // GPUI's settings rail: shown while the page scrolls (`popover::rail`),
    // with a nanoui that has overlay bars (justrach/nanoui#21).
    var page_style: ui.Style = .{ .grow = 1, .width = .fill, .align_items = .center };
    if (@hasField(ui.Style, "scrollbar")) page_style.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
    ui.scroll(c, page_style);
    defer ui.end(c);
    // `page_column`: 768 wide at most, centred, 24 either side, 32 above.
    const col = ui.div(c).column().wFull().maxW(768).px(24).pt(32).pb(64);
    defer col.end();
    // The column's inside: wrapped text needs its width up front.
    const main_w = c.size.w - sidebar.width;
    inner_w = @min(main_w, 768) - 2 * 24;
    // Appearance's theme menu doesn't outlive its page.
    if (a.settings.section != .appearance) a.view.theme_menu = null;
    switch (a.settings.section) {
        .notifications => notifications(c, a, k),
        .files => files(c, a, k),
        .archived => {
            const archived = @import("view_settings_archived.zig");
            archived.page(c, a, k);
            archived.dialog(c, a, k);
        },
        .devices => @import("view_settings_devices.zig").page(c, a, k),
        .shortcuts => @import("view_settings_shortcuts.zig").page(c, a, k),
        .appearance => {
            const look = @import("view_settings_appearance.zig");
            look.page(c, a, k);
            look.themeMenu(c, a, k);
            const library = @import("view_settings_theme_import.zig");
            library.dialog(c, a, k);
            library.reviewDialog(c, a, k);
        },
        .mcp => @import("view_settings_mcp.zig").page(c, a, k),
        .appshots => @import("view_settings_appshots.zig").page(c, a, k),
        .github_ci => @import("view_settings_github_ci.zig").page(c, a, k),
        .harnesses => @import("view_settings_agents.zig").page(c, a, k),
        .agents => @import("view_settings_accounts.zig").page(c, a, k),
    }
}

// The kit (settings/widgets.rs).

/// The page column's inside width, this frame.
pub var inner_w: f32 = 720;

/// A card row's words: the row less its insets, tile, gaps and switch.
fn wordsWidth(trailing: f32) f32 {
    return @max(inner_w - 2 - 2 * 20 - 36 - 14 - 14 - trailing, 80);
}

pub fn header(c: *ui.Context, k: theme.Colors, title: []const u8, count: ?usize) void {
    const h = ui.div(c).row().gap(10).itemsEnd();
    defer h.end();
    ui.text(c, title, st(c, 16, .{ .weight = .semibold, .color = k.text }));
    if (count) |n| ui.text(c, c.print("{d}", .{n}), st(c, 13, .{ .color = k.muted.alpha(0.7) }));
}

/// `page_subtitle`. Pages that cap it (`max_w(512).line_height(20)`) pass
/// `capped`; the others run it the column's width on GPUI's line height.
pub fn subtitle(c: *ui.Context, k: theme.Colors, copy: []const u8, capped: bool) void {
    space(c, 4);
    const s = ui.div(c).column().w(if (capped) @min(inner_w, 512) else inner_w);
    defer s.end();
    ui.text(c, copy, .{ .size = 13, .line_height = if (capped) 20 else 13 * phi, .wrap = true, .color = k.muted });
}

pub fn fieldLabel(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    ui.text(c, label, st(c, 13, .{ .weight = .medium, .color = k.text }));
}

/// `section_card`: 24 points down, rounded 12, a hairline edge. In GPUI a
/// border insets what's inside it; here it's drawn over the box, so the
/// box pads by its width.
pub fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    space(c, 24);
    return ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
}

/// `card_row`: 20 by 14 inside, a line above all but the first.
pub fn row(c: *ui.Context, k: theme.Colors, first: bool, dim: bool) ui.Div {
    if (!first) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    var r = ui.div(c).row().wFull().px(20).py(14).gap(14).itemsCenter().hover(k.ink(0.015));
    if (dim) r = r.opacity(0.55);
    return r;
}

/// `row_tile`: a 36-point tile around a 16-point icon.
pub fn tile(c: *ui.Context, k: theme.Colors, icon: icons.Name) void {
    const t = ui.div(c).row().size(36, 36).center().rounded(10).border(k.border).borderW(1).bg(k.ink(0.03));
    defer t.end();
    icons.icon(c, icon, 16, k.muted, 0);
}

/// The title and the quiet line under it.
pub fn words(c: *ui.Context, k: theme.Colors, title: []const u8, meta: []const u8, trailing: f32) void {
    const w = ui.div(c).column().w(wordsWidth(trailing)).gap(1);
    defer w.end();
    ui.text(c, title, st(c, 13, .{ .weight = .medium, .color = k.text }));
    ui.text(c, meta, st(c, 12, .{ .wrap = true, .color = k.muted.alpha(0.65) }));
}

/// `toggle_switch` in its 40-point target: true when clicked.
pub fn toggle(c: *ui.Context, k: theme.Colors, on: bool, enabled: bool) bool {
    const target = ui.div(c).row().size(40, 40).center();
    defer target.end();
    const track = ui.div(c).row().w(32).h(18).roundedFull().bg(if (on) k.text else k.ink(0.15)).pl(if (on) 16 else 2).itemsCenter();
    defer track.end();
    _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (on) k.on_solid else k.ink(0.7) }, .none, null);
    return enabled and target.clicked();
}

/// A row: tile, title and line, and its switch.
fn switchRow(c: *ui.Context, a: *App, k: theme.Colors, comptime flag: settings.Flag, icon: icons.Name, title: []const u8, meta: []const u8, first: bool, enabled: bool) void {
    ui.key(c, @tagName(flag));
    const r = row(c, k, first, !enabled);
    defer r.end();
    tile(c, k, icon);
    words(c, k, title, meta, 40);
    if (toggle(c, k, a.settings.get(flag), enabled)) {
        a.settings.toggle(flag);
        a.redraw();
    }
}

/// A row whose switch is the bare `toggle_switch` at its edge, with no
/// 40-point target around it (Settings › Files').
fn bareSwitchRow(c: *ui.Context, a: *App, k: theme.Colors, comptime flag: settings.Flag, icon: icons.Name, title: []const u8, meta: []const u8, first: bool) void {
    ui.key(c, @tagName(flag));
    const r = row(c, k, first, false);
    defer r.end();
    tile(c, k, icon);
    words(c, k, title, meta, 32);
    const on = a.settings.get(flag);
    const track = ui.div(c).row().w(32).h(18).roundedFull().bg(if (on) k.text else k.ink(0.15)).pl(if (on) 16 else 2).itemsCenter();
    defer track.end();
    _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (on) k.on_solid else k.ink(0.7) }, .none, null);
    if (track.clicked()) {
        a.settings.toggle(flag);
        a.redraw();
    }
}

/// `btn_ghost`: muted text, a wash under the pointer.
pub fn ghost(c: *ui.Context, k: theme.Colors, label: []const u8) bool {
    const b = ui.div(c).row().px(12).py(6).rounded(8).hover(k.ink(0.06));
    defer b.end();
    ui.text(c, label, st(c, 13, .{ .color = if (b.hovered()) k.text else k.muted }));
    return b.clicked();
}

// The pages.

fn notifications(c: *ui.Context, a: *App, k: theme.Colors) void {
    header(c, k, "Notifications", null);
    subtitle(c, k, "Choose which session events can play a sound, and when desktop notifications appear.", true);
    const sound = a.settings.get(.sound_enabled);
    const desktop = a.settings.get(.notifications_enabled);
    {
        const cd = card(c, k);
        defer cd.end();
        switchRow(c, a, k, .sound_enabled, .@"volume-loud", "Session sounds", "Allow sounds for the selected session events below. With desktop notifications on, sounds in the background follow Focus.", true, true);
        switchRow(c, a, k, .sound_completion_enabled, .check, "Task completed", "Play a sound when an agent finishes a run.", false, sound);
        switchRow(c, a, k, .sound_input_enabled, .@"chat-round-line", "Input required", "Play a sound when an agent needs your response.", false, sound);
        switchRow(c, a, k, .sound_attention_enabled, .@"danger-triangle", "Errors and disconnections", "Play a sound when a run fails or the connection remains unavailable.", false, sound);
        switchRow(c, a, k, .notifications_enabled, .bell, "Desktop notifications", "Show a system banner on the same events, so pings reach you while Harness is in the background.", false, true);
        switchRow(c, a, k, .notifications_background_only, .monitor, "Only when in the background", "Skip the banner while a Harness window is focused.", false, desktop);
    }
    fieldLabel(c, k, "Privacy");
    const cd = card(c, k);
    defer cd.end();
    switchRow(c, a, k, .share_performance_stats, .@"fast-tier", "Share anonymous performance stats", "Send launch, load, send, and streaming timings so Harness can get faster. Timings only: no account, chats, paths, or content.", true, true);
}

fn files(c: *ui.Context, a: *App, k: theme.Colors) void {
    header(c, k, "Files", null);
    subtitle(c, k, "Control how workspace files are displayed and saved while you edit.", true);
    const cd = card(c, k);
    defer cd.end();
    bareSwitchRow(c, a, k, .files_autosave_enabled, .folder, "Autosave", "Save edited workspace files to disk automatically.", true);
    bareSwitchRow(c, a, k, .files_word_wrap, .list, "Word wrap", "Wrap long lines in every workspace file.", true);
    bareSwitchRow(c, a, k, .files_show_all, .eye, "Show all files", "Include hidden and ignored files in every file tree.", false);
    const r = row(c, k, false, false);
    defer r.end();
    tile(c, k, .folder);
    // Edit's own width: 12 a side and its words.
    words(c, k, "New project starting folder", c.print("Automatic · {s}", .{startingFolder(a) orelse "Home"}), 24 + @ceil(c.text.width("Edit", .{ .size = 13 })));
    if (ghost(c, k, "Edit")) a.setNotice("Choosing a starting folder isn't in Harness Nano yet: use Harness.");
}

/// The folder new projects start in, with none chosen: the folder most of
/// this device's projects sit in (`ProjectFolderPreference::starting_folder`;
/// ties go to the path first in order).
pub fn startingFolder(a: *const App) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_n: usize = 0;
    for (a.spaces.items) |s| {
        if (a.device_id) |d| if (s.device_id) |sd| if (!std.mem.eql(u8, d, sd)) continue;
        const parent = projectParent(s.path) orelse continue;
        var n: usize = 0;
        for (a.spaces.items) |o| if (projectParent(o.path)) |p| if (std.mem.eql(u8, p, parent)) {
            n += 1;
        };
        if (n > best_n or (n == best_n and best != null and std.mem.order(u8, parent, best.?) == .lt)) {
            best = parent;
            best_n = n;
        }
    }
    return best;
}

/// The folder a project's folder is in (`project_parent`).
pub fn projectParent(path: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, path, "/");
    if (t.len == 0) return null;
    const at = std.mem.lastIndexOfScalar(u8, t, '/') orelse return null;
    return if (at == 0) "/" else t[0..at];
}

const testing = std.testing;

test "a search finds sections by name; the starting folder's parent rule" {
    var buf: [Section.all.len]Section = undefined;
    const found = matches("not", &buf);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(Section.notifications, found[0]);
    try testing.expectEqual(@as(usize, 0), matches("zzz", &buf).len);
    try testing.expectEqualStrings("/work", projectParent("/work/fieldnotes/").?);
    try testing.expectEqualStrings("/", projectParent("/tmp").?);
    try testing.expect(projectParent("relative") == null);
}
