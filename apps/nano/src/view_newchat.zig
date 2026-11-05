//! A new chat, before its first message (crates/ui/src/composer.rs,
//! composer_dock.rs, starters.rs): the composer floats a little below the
//! middle, expanded, under a greeting ("Hi Rach. What should Graff do?")
//! and "Working in" the project's name (which picks another). The footer
//! under it leads with the model chip; while nothing is typed, a 2×2 grid
//! of starter tiles sits below.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const composer = @import("view_composer.zig");
const transcript_view = @import("view_transcript.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

/// The heading's height: the greeting, the 4 under it and "Working in".
const heading_h: f32 = 24 * phi + 4 + 13 * phi;

const Starter = struct {
    icon: icons.Name,
    title: []const u8,
    /// One line on its tile saying what you get.
    blurb: []const u8,
    prompt: []const u8,
    needs_project: bool = false,
};

const starters = [_]Starter{
    .{ .icon = .@"magic-stick-3", .title = "Build something new", .blurb = "Describe an idea. The agent makes a folder, writes the code, and runs it.", .prompt = "Build something new from scratch. Create a new folder for it under ~/Projects, set it up, and get a first working version running. Ask me anything you need to know before you start.\n\nMy idea: " },
    .{ .icon = .magnifer, .title = "Research a topic", .blurb = "Get a sourced write-up on anything, with the key takeaways up front.", .prompt = "Research the topic below and give me a concise, well-sourced write-up: key takeaways first, then the details, with links to your sources.\n\nTopic: " },
    .{ .icon = .global, .title = "Plan a launch", .blurb = "Positioning, a go-to-market plan, and landing page copy for your product.", .prompt = "Help me take my product to market. Ask me about the product, who it's for, and my goals, then draft positioning, a go-to-market plan, and landing page copy.\n\nThe product: " },
    .{ .icon = .@"file-code", .title = "Tour this project", .blurb = "Learn what the code does, how it's organized, and where to start.", .prompt = "Give me a tour of this project: what it does, how it's organized, how to run it, and where I'd start making changes.", .needs_project = true },
};

/// A tile's height and the gap between tiles, across and down
/// (`TILE_HEIGHT`, `TILE_GAP`).
const tile_h: f32 = 64;
const tile_gap: f32 = 8;

/// The greeting over the composer (`starters::greeting`): "Hi Rach. What
/// should Graff do?", by the first name only and never by an email; else
/// just the question.
pub fn greeting(buf: []u8, name: ?[]const u8) []const u8 {
    const question = "What should Graff do?";
    const n = std.mem.trim(u8, name orelse return question, " \t\n");
    var words = std.mem.tokenizeAny(u8, n, " \t\n");
    const first = words.next() orelse return question;
    if (std.mem.indexOfScalar(u8, first, '@') != null) return question;
    return std.fmt.bufPrint(buf, "Hi {s}. {s}", .{ first, question }) catch question;
}

test "the greeting uses the first name only (greeting_uses_the_first_name_only)" {
    var b: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Hi Rach. What should Graff do?", greeting(&b, "Rach Pradhan"));
    try std.testing.expectEqualStrings("What should Graff do?", greeting(&b, "  "));
    try std.testing.expectEqualStrings("What should Graff do?", greeting(&b, "rach@example.com"));
    try std.testing.expectEqualStrings("What should Graff do?", greeting(&b, null));
}

pub fn canvas(c: *ui.Context, a: *App, k: theme.Colors) void {
    // The composer's column is the main column's, 768 at most, with 16 on
    // either side of the pill (`composer_target_width`).
    const main_w = transcript_view.paneWidth(c, a);
    const w = @min(main_w, 768) - 32;
    // The pill's top (`DockedComposer::prepaint`): its box, the pill and
    // the 40 the footer takes under it, centred and 8 down, from the area
    // under the title bar. It follows the pill as the draft grows.
    const box_h = (if (a.view.composer_anchor) |r| @max(r.h, composer.expanded_min) else composer.expanded_min) + 40;
    var pill_top = (c.size.h - box_h) * 0.5 + 8 - sidebar.titlebar_h;
    // In a pane of a split down the window, centred in the pane.
    if (transcript_view.paneHeight(c, a)) |h| pill_top = (h - box_h) * 0.5 + 8;
    const area = ui.div(c).column().wFull().grow().itemsCenter();
    defer area.end();
    // The heading ends 42 above the pill (its 60-point slot, bottom-aligned,
    // 28 + 14 over the pill).
    _ = c.leaf(.{ .height = .{ .px = @max(pill_top - 42 - heading_h, 0) } }, .none, null);
    heading(c, a, k, w - 20);
    _ = c.leaf(.{ .height = .{ .px = 42 - 28 } }, .none, null);
    pickersAbove(c, a, k, w - 20);
    _ = c.leaf(.{ .height = .{ .px = 8 } }, .none, null);
    composer.pill(c, a, k, w, .expanded, composer.radius);
    // The footer, 8 under the pill: the model chip, then for a git
    // project the checkout and the ref a session starts from.
    _ = c.leaf(.{ .height = .{ .px = 8 } }, .none, null);
    footer(c, a, k, w);
    // The grid's slot, 12 under the composer's box: 52 under the pill.
    _ = c.leaf(.{ .height = .{ .px = 52 - 8 - 24 } }, .none, null);
    // Only while nothing at all is typed, a space included.
    if (a.composer.text().len == 0) starterGrid(c, a, k, w);
}

const phi: f32 = 1.618;

/// `render_new_thread_heading`: the greeting, then "Working in" and the
/// project (or "Working in your home folder"), which picks another.
fn heading(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const box = ui.div(c).column().w(w).gap(4);
    defer box.end();
    // The frame keeps the words: not a buffer on this stack.
    const buf = c.alloc().alloc(u8, 128) catch return;
    const name = if (a.account.user) |u| u.name else null;
    const plain = a.selected == null and a.new_chat_mode;
    kit.ellipsisText(c, if (plain) chat_mode.heading_title else greeting(buf, name), .{ .size = 24, .line_height = 24 * phi, .weight = .semibold, .color = k.text }, w);
    if (plain) {
        // A plain chat has no project to name or pick: it says what it is.
        ui.text(c, chat_mode.heading_eyebrow, .{ .size = 13, .line_height = 13 * phi, .color = k.muted });
        return;
    }
    const space = a.newChatSpace();
    const t = ui.div(c).row().gap(4).itemsCenter();
    defer t.end();
    const hot = t.hovered();
    if (t.clicked() and a.spaces.items.len > 0) a.view.space_menu = !a.view.space_menu;
    if (c.rects.get(c.node(t.index).id)) |r| a.view.space_anchor = r;
    const color = if (hot) k.text else k.muted;
    ui.text(c, if (space != null) "Working in" else "Working in your home folder", .{ .size = 13, .line_height = 13 * phi, .color = color });
    if (space) |s| kit.ellipsisText(c, s.name, .{ .size = 13, .line_height = 13 * phi, .weight = .medium, .color = color }, w - 80 - 16);
    icons.icon(c, .@"alt-arrow-down", 12, k.muted.alpha(0.6), 0);
}

/// Over the pill's right end: the device the session runs on and its
/// project (`footer_chip`s).
fn pickersAbove(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const r = ui.div(c).row().w(w).h(20).gap(4).justifyEnd();
    defer r.end();
    const space = a.newChatSpace();
    modeSwitch(c, a, k);
    if (footerChip(c, k, .monitor, a.deviceName(a.device_id))) a.setNotice("Choosing a device isn't in Harness Nano yet.");
    if (!a.new_chat_mode) if (footerChip(c, k, .folder, if (space) |s| s.name else "No project") and a.spaces.items.len > 0) {
        a.view.space_menu = !a.view.space_menu;
    };
}

const chat_mode = @import("chat_mode.zig");
const agent = @import("app_agent.zig");

/// Chat | Code (`render_chat_mode_switch`): which the new session is; a
/// click switches. Dimmed while no Auto tier is on offer, saying why.
fn modeSwitch(c: *ui.Context, a: *App, k: theme.Colors) void {
    const plain = a.new_chat_mode;
    const unavailable = !plain and agent.chatAvailability(a) == .unavailable;
    const hint = if (plain) "Plain chat. Click for a coding session" else if (unavailable) chat_mode.unavailable_note else "Coding session. Click for a plain chat";
    ui.key(c, "picker-chat-mode");
    var b = ui.div(c).row().h(20).px(8).gap(6).itemsCenter().rounded(6).hover(k.hover);
    if (unavailable) b = b.opacity(0.5);
    b = @import("view_tooltip.zig").on(b, k, .{ .text = hint });
    defer b.end();
    const hot = b.hovered();
    icons.icon(c, if (plain) .@"chat-round-line" else .@"file-code", 12, k.muted.alpha(0.7), 0);
    ui.text(c, if (plain) "Chat" else "Code", .{ .size = 12, .line_height = 12 * phi, .weight = .medium, .color = if (hot) k.text.alpha(0.8) else k.muted.alpha(0.7) });
    if (b.clicked()) agent.setChatMode(a, !plain);
}

/// `composer-footer` on a new chat: `px(10)`, the model chip, then for a
/// git project the checkout and the ref a session starts from.
fn footer(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const r = ui.div(c).row().w(w).h(24).px(10).gap(4).itemsCenter().clip();
    defer r.end();
    composer.chip(c, a, k);
    // A plain chat's note (the Auto (smart) cost, or why it can't run).
    if (agent.chatNote(a)) |note| kit.ellipsisText(c, note, .{ .size = 11.5, .line_height = 11.5 * phi, .color = k.muted }, w - 200);
    const space = a.newChatSpace() orelse return;
    if (!space.git) return;
    // `checkout_label`: a fresh worktree by default, else the project's own.
    if (footerChipAt(c, k, if (a.new_checkout_local) .folder else .@"folder-with-files", checkoutLabel(a.new_checkout_local), &a.view.checkout_anchor)) a.view.checkout_menu = !a.view.checkout_menu;
    if (footerChip(c, k, .@"git-branch", "Select ref")) a.setNotice("Choosing a ref isn't in Harness Nano yet.");
}

pub fn checkoutLabel(local: bool) []const u8 {
    return if (local) "Current checkout" else "New worktree";
}

/// A quiet chip: an icon, its words and a chevron (`footer_chip`).
fn footerChip(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8) bool {
    return footerChipAt(c, k, icon, label, null);
}

/// As `footerChip`, keeping where it was laid out for a menu to hang from.
fn footerChipAt(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8, anchor: ?*?ui.Rect) bool {
    const b = ui.div(c).row().h(20).maxW(280).px(8).gap(6).itemsCenter().rounded(6).hover(k.hover);
    defer b.end();
    if (anchor) |p| if (c.rects.get(c.node(b.index).id)) |r| {
        p.* = r;
    };
    const hot = b.hovered();
    icons.icon(c, icon, 12, k.muted.alpha(0.7), 0);
    ui.text(c, label, .{ .size = 12, .line_height = 12 * phi, .weight = .medium, .color = if (hot) k.text.alpha(0.8) else k.muted.alpha(0.7) });
    icons.icon(c, .@"alt-arrow-down", 12, k.muted.alpha(0.5), 0);
    return b.clicked();
}

/// The starters under an empty composer (`render_starter_chips`): two to
/// a row, 8 apart either way; a lone last tile keeps its half width.
fn starterGrid(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const has_project = a.newChatSpace() != null;
    var shown: [starters.len]Starter = undefined;
    var n: usize = 0;
    for (starters) |s| {
        if (s.needs_project and !has_project) continue;
        shown[n] = s;
        n += 1;
    }
    const tile_w = @max(0, (w - tile_gap) / 2);
    const box = ui.div(c).column().w(w).gap(tile_gap);
    defer box.end();
    var i: usize = 0;
    while (i < n) : (i += 2) {
        const row = ui.div(c).row().w(w).gap(tile_gap);
        defer row.end();
        for (shown[i..@min(n, i + 2)]) |s| tile(c, a, k, s, tile_w);
    }
}

/// `starters::tile`: a solid card, the accent icon and the title over a
/// one-line blurb. GPUI's `border_1` sits inside the box, so its `px(14)`
/// starts a point in.
fn tile(c: *ui.Context, a: *App, k: theme.Colors, s: Starter, w: f32) void {
    ui.key(c, s.title);
    var t = ui.div(c).column().w(w).h(tile_h).px(14 + 1).gap(4).justifyCenter().rounded(10).border(k.border).borderW(1).bg(k.card);
    if (t.hovered()) t = t.bg(k.raised);
    defer t.end();
    if (t.clicked()) a.composer.set(s.prompt);
    const room = @max(0, w - 2 * 15);
    {
        const head = ui.div(c).row().gap(8).itemsCenter();
        defer head.end();
        icons.icon(c, s.icon, 15, k.accent, 0);
        kit.ellipsisText(c, s.title, .{ .size = 13, .line_height = 13 * phi, .weight = .medium, .color = k.text }, @max(0, room - 15 - 8));
    }
    kit.ellipsisText(c, s.blurb, .{ .size = 12, .line_height = 12 * phi, .color = k.muted }, room);
}
