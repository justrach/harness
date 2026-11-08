//! New conversations use the same bottom-anchored input as established
//! conversations. Suggestions are separate conversation content, not a
//! heading or cards attached to a floating expanded composer (shell.rs).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const composer = @import("view_composer.zig");
const transcript_view = @import("view_transcript.zig");
const App = @import("app.zig").App;

const Starter = struct {
    icon: icons.Name,
    title: []const u8,
    /// One line on its tile saying what you get.
    blurb: []const u8,
    prompt: []const u8,
    needs_project: bool = false,
    fresh_folder: bool = false,
};

const starters = [_]Starter{
    .{ .icon = .@"magic-stick-3", .fresh_folder = true, .title = "Build something new", .blurb = "Describe an idea. The agent makes a folder, writes the code, and runs it.", .prompt = "Build something new from scratch. Create a new folder for it under ~/Projects, set it up, and get a first working version running. Ask me anything you need to know before you start.\n\nMy idea: " },
    .{ .icon = .magnifer, .title = "Research a topic", .blurb = "Get a sourced write-up on anything, with the key takeaways up front.", .prompt = "Research the topic below and give me a concise, well-sourced write-up: key takeaways first, then the details, with links to your sources.\n\nTopic: " },
    .{ .icon = .global, .title = "Plan a launch", .blurb = "Positioning, a go-to-market plan, and landing page copy for your product.", .prompt = "Help me take my product to market. Ask me about the product, who it's for, and my goals, then draft positioning, a go-to-market plan, and landing page copy.\n\nThe product: " },
    .{ .icon = .@"file-code", .title = "Tour this project", .blurb = "Learn what the code does, how it's organized, and where to start.", .prompt = "Give me a tour of this project: what it does, how it's organized, how to run it, and where I'd start making changes.", .needs_project = true },
};

pub const suggestion_gap: f32 = 14;
pub const chip_h: f32 = 28;
pub const chip_gap: f32 = 6;

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
    const w = composer.dockedWidth(transcript_view.paneWidth(c, a), transcript_view.column_w);
    const area = ui.div(c).column().wFull().grow().h(0).itemsCenter();
    defer area.end();
    // Suggestions own only the space left above THIS frame's dock and
    // reserved status strip. A max-height based on composer_anchor fed the
    // previous input height back into layout, pushing a short pane's dock
    // off its bottom before snapping back on the following frame.
    {
        ui.scroll(c, .{ .width = .fill, .height = .{ .px = 0 }, .grow = 1, .align_items = .center, .justify = .end, .follow_end = true });
        defer ui.end(c);
        suggestions(c, a, k, w);
    }
    _ = c.leaf(.{ .height = .{ .px = 24 } }, .none, null);
    composer.docked(c, a, k);
}

const phi: f32 = 1.618;

pub fn suggestions(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    ui.key(c, "new-conversation-suggestions");
    const box = ui.div(c).column().w(w).itemsCenter().gap(suggestion_gap);
    defer box.end();
    const buf = c.alloc().alloc(u8, 128) catch return;
    const name = if (a.account.user) |u| u.name else null;
    kit.ellipsisText(c, if (a.new_chat_mode) chat_mode.heading_title else greeting(buf, name), .{ .size = 22, .line_height = 22 * phi, .weight = .semibold, .color = k.text }, w);
    starterChips(c, a, k, w);
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
    ui.text(c, if (plain) "Chat" else "Code", .{ .size = 12, .line_height = 12 * phi, .weight = theme.ui_medium_weight, .color = if (hot) k.text.alpha(0.8) else k.muted.alpha(0.7) });
    if (b.clicked()) agent.setChatMode(a, !plain);
}

/// Same footer and model anchor as an established conversation. A draft
/// adds mode, an explicit execution computer, and its project/checkout.
pub fn footer(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const r = ui.div(c).row().w(w).h(24).px(10).gap(4).itemsCenter().clip();
    defer r.end();
    composer.chip(c, a, k);
    {
        const slot = ui.div(c).row().grow().w(0).hFull().px(10).gap(4).itemsCenter().clip();
        defer slot.end();
        modeSwitch(c, a, k);
        // Keep the execution target beside the draft, not only in the
        // titlebar. Picking another host clears an incompatible project.
        const strip = @import("view_tab_strip.zig");
        var computer: ?ui.Rect = null;
        ui.key(c, "picker-computer");
        if (footerChipAt(c, k, .monitor, c.print("Run on: {s}", .{strip.deviceLabel(a, strip.device(a, strip.active(a)))}), &computer))
            strip.open(a, .device, strip.active(a), computer);
        if (a.newChatSpace()) |space| {
            projectChip(c, a, k, space.name);
            if (space.git) {
                if (footerChipAt(c, k, if (a.new_checkout_local) .folder else .@"folder-with-files", checkoutLabel(a.new_checkout_local), &a.view.checkout_anchor)) a.view.checkout_menu = !a.view.checkout_menu;
                if (footerChip(c, k, .@"git-branch", "Select ref")) a.setNotice("Choosing a ref isn't in Harness Nano yet.");
            }
        } else {
            projectChip(c, a, k, "No project");
        }
    }
    if (agent.chatNote(a)) |note| kit.ellipsisText(c, note, .{ .size = 11.5, .line_height = 11.5 * phi, .color = k.muted }, @max(0, w - 200));
}

/// Desktop exposes project choice only before sending a coding session.
/// The shared strip owns its searchable menu and panel-local mutation.
fn projectChip(c: *ui.Context, a: *App, k: theme.Colors, label: []const u8) void {
    if (a.new_chat_mode) return;
    ui.key(c, "picker-project");
    if (footerChipAt(c, k, .folder, label, &a.view.space_anchor)) {
        if (a.view.strip.menu == .folder and a.view.strip.footer_folder) {
            a.view.strip.menu = null;
            a.view.space_menu = false;
        } else {
            a.view.space_menu = true;
        }
        a.redraw();
    }
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
    ui.text(c, label, .{ .size = 12, .line_height = 12 * phi, .weight = theme.ui_medium_weight, .color = if (hot) k.text.alpha(0.8) else k.muted.alpha(0.7) });
    icons.icon(c, .@"alt-arrow-down", 12, k.muted.alpha(0.5), 0);
    return b.clicked();
}

/// The same 28px outlined chips as starters::chip, flex-wrapped with
/// measured titles. A narrow panel never gets two clipped fixed cards.
fn starterChips(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    var shown: [starters.len]Starter = undefined;
    var widths: [starters.len]f32 = undefined;
    var n: usize = 0;
    for (starters) |s| {
        if (s.needs_project and a.newChatSpace() == null) continue;
        shown[n] = s;
        // GPUI's text element rounds its intrinsic width up to a point.
        widths[n] = @min(w, @ceil(c.text.width(s.title, .{ .size = 12 })) + 20 + 2 + 13 + 6);
        n += 1;
    }
    const box = ui.div(c).column().w(w).gap(chip_gap).itemsCenter();
    defer box.end();
    var start: usize = 0;
    while (start < n) {
        const end = chipRowEnd(widths[0..n], start, w);
        const row = ui.div(c).row().gap(chip_gap).itemsCenter();
        defer row.end();
        for (shown[start..end], widths[start..end]) |s, cw| {
            ui.key(c, s.title);
            const b = ui.div(c).row().h(chip_h).w(cw).px(11).gap(6).itemsCenter().rounded(14).border(k.border).borderW(1).hover(k.hover);
            defer b.end();
            const ink = if (b.hovered()) k.text else k.muted;
            icons.icon(c, s.icon, 13, ink, 0);
            kit.ellipsisText(c, s.title, .{ .size = 12, .line_height = 12 * phi, .color = ink }, @max(0, cw - 22 - 13 - 6));
            if (b.clicked()) {
                if (s.fresh_folder) a.new_no_project = true;
                a.composer.set(s.prompt);
                a.view.focus_composer = true;
                a.redraw();
            }
        }
        start = end;
    }
}

/// End-exclusive wrapped row; even a too-wide chip must make progress.
pub fn chipRowEnd(widths: []const f32, start: usize, available: f32) usize {
    var end = start;
    var used: f32 = 0;
    while (end < widths.len) : (end += 1) {
        const next = used + (if (end > start) chip_gap else @as(f32, 0)) + widths[end];
        if (end > start and next > available) break;
        used = next;
    }
    return end;
}
