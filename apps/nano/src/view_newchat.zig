//! A new chat, before its first message (crates/ui/src/composer.rs,
//! composer_dock.rs, starters.rs): the composer floats a little below the
//! middle, expanded, under "New session in" and the project's name (which
//! picks another), with starter prompts below it while it is empty.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const composer = @import("view_composer.zig");
const transcript_view = @import("view_transcript.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

/// The heading's height: its two lines and the 2 between them.
const heading_h: f32 = 12 * 1.618 + 2 + 22 * 1.618;

const Starter = struct { icon: icons.Name, title: []const u8, prompt: []const u8, needs_project: bool = false };

const starters = [_]Starter{
    .{ .icon = .@"magic-stick-3", .title = "Build something new", .prompt = "Build something new from scratch. Create a new folder for it under ~/Projects, set it up, and get a first working version running. Ask me anything you need to know before you start.\n\nMy idea: " },
    .{ .icon = .magnifer, .title = "Research a topic", .prompt = "Research the topic below and give me a concise, well-sourced write-up: key takeaways first, then the details, with links to your sources.\n\nTopic: " },
    .{ .icon = .global, .title = "Plan a launch", .prompt = "Help me take my product to market. Ask me about the product, who it's for, and my goals, then draft positioning, a go-to-market plan, and landing page copy.\n\nThe product: " },
    .{ .icon = .@"file-code", .title = "Tour this project", .prompt = "Give me a tour of this project: what it does, how it's organized, how to run it, and where I'd start making changes.", .needs_project = true },
};

pub fn canvas(c: *ui.Context, a: *App, k: theme.Colors) void {
    // The composer's column is the main column's, 768 at most, with 16 on
    // either side of the pill (`composer_target_width`).
    const main_w = transcript_view.paneWidth(c, a);
    const w = @min(main_w, 768) - 32;
    // The pill's top: half the window less 72 (`DockedComposer::prepaint`:
    // its 160-point box centred, 8 down), from the area under the title bar.
    var pill_top = c.size.h * 0.5 - 72 - sidebar.titlebar_h;
    // In a pane of a split down the window, centred in the pane.
    if (transcript_view.paneHeight(c, a)) |h| pill_top = h * 0.5 - 72;
    const area = ui.div(c).column().wFull().grow().itemsCenter();
    defer area.end();
    // The heading ends 42 above the pill; it's 57 tall.
    _ = c.leaf(.{ .height = .{ .px = @max(pill_top - 42 - heading_h, 0) } }, .none, null);
    heading(c, a, k, w - 20);
    _ = c.leaf(.{ .height = .{ .px = 42 - 28 } }, .none, null);
    pickersAbove(c, a, k, w - 20);
    _ = c.leaf(.{ .height = .{ .px = 8 } }, .none, null);
    composer.pill(c, a, k, w, .expanded, 26);
    _ = c.leaf(.{ .height = .{ .px = 10 } }, .none, null);
    pickersBelow(c, a, k, w - 20);
    _ = c.leaf(.{ .height = .{ .px = 44 - 10 - 20 } }, .none, null);
    // Only while nothing at all is typed, a space included.
    if (a.composer.text().len == 0) starterRow(c, a, k, w);
}

const phi: f32 = 1.618;

fn heading(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const box = ui.div(c).column().w(w).gap(2);
    defer box.end();
    const space = a.newChatSpace();
    ui.text(c, if (space != null) "New session in" else "New session in your home folder", .{ .size = 12, .line_height = 12 * phi, .color = k.muted.alpha(0.7) });
    const t = ui.div(c).row().gap(6).itemsCenter();
    defer t.end();
    const hot = t.hovered();
    if (t.clicked() and a.spaces.items.len > 0) a.view.space_menu = !a.view.space_menu;
    if (c.rects.get(c.node(t.index).id)) |r| a.view.space_anchor = r;
    ui.text(c, if (space) |s| s.name else "No project", .{ .size = 22, .line_height = 22 * phi, .weight = .semibold, .color = if (hot) k.text else k.text.alpha(0.9) });
    icons.icon(c, .@"alt-arrow-down", 16, k.muted.alpha(0.6), 0);
}

/// Over the pill's right end: the device the session runs on and its
/// project (`footer_chip`s).
fn pickersAbove(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const r = ui.div(c).row().w(w).h(20).gap(4).justifyEnd();
    defer r.end();
    const space = a.newChatSpace();
    if (footerChip(c, k, .monitor, a.deviceName(a.device_id))) a.setNotice("Choosing a device isn't in Harness Nano yet.");
    if (footerChip(c, k, .folder, if (space) |s| s.name else "No project") and a.spaces.items.len > 0) a.view.space_menu = !a.view.space_menu;
}

/// Under the pill's left end, for a git project: the checkout and the ref
/// a session starts from.
fn pickersBelow(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const r = ui.div(c).row().w(w).h(20).gap(4);
    defer r.end();
    const space = a.newChatSpace() orelse return;
    if (!space.git) return;
    if (footerChip(c, k, .folder, "Current checkout")) a.setNotice("Choosing a checkout isn't in Harness Nano yet.");
    if (footerChip(c, k, .@"git-branch", "Select ref")) a.setNotice("Choosing a ref isn't in Harness Nano yet.");
}

/// A quiet chip: an icon, its words and a chevron (`footer_chip`).
fn footerChip(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8) bool {
    const b = ui.div(c).row().h(20).maxW(280).px(8).gap(6).itemsCenter().rounded(6).hover(k.hover);
    defer b.end();
    const hot = b.hovered();
    icons.icon(c, icon, 12, k.muted.alpha(0.7), 0);
    ui.text(c, label, .{ .size = 12, .line_height = 12 * phi, .weight = .medium, .color = if (hot) k.text.alpha(0.8) else k.muted.alpha(0.7) });
    icons.icon(c, .@"alt-arrow-down", 12, k.muted.alpha(0.5), 0);
    return b.clicked();
}

/// The starters under an empty composer, as chips in rows that wrap at
/// the composer's width, each row centred, 6 points apart either way
/// (`render_starter_chips`: flex_wrap, justify_center, gap 6).
fn starterRow(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const st: ui.TextStyle = .{ .size = 12 };
    const has_project = a.newChatSpace() != null;
    var shown: [starters.len]Starter = undefined;
    var n: usize = 0;
    for (starters) |s| {
        if (s.needs_project and !has_project) continue;
        shown[n] = s;
        n += 1;
    }
    const box = ui.div(c).column().w(w).gap(6).itemsCenter();
    defer box.end();
    var i: usize = 0;
    while (i < n) {
        // As many chips as fit on this row; always at least one.
        var end = i + 1;
        var used = chipWidth(c, shown[i], st);
        while (end < n) : (end += 1) {
            const next = used + 6 + chipWidth(c, shown[end], st);
            if (next > w) break;
            used = next;
        }
        const row = ui.div(c).row().gap(6).justifyCenter();
        defer row.end();
        for (shown[i..end]) |s| chip(c, a, k, s, st);
        i = end;
    }
}

/// A chip's width: 10 points either side, the 13-point icon, 6 between.
/// Its border, `px(10)` inside it, the icon, the gap and the title.
fn chipWidth(c: *ui.Context, s: Starter, st: ui.TextStyle) f32 {
    return 1 + 10 + 13 + 6 + c.text.width(s.title, st) + 10 + 1;
}

fn chip(c: *ui.Context, a: *App, k: theme.Colors, s: Starter, st: ui.TextStyle) void {
    ui.key(c, s.title);
    // GPUI's `border_1` sits inside the box, so its `px(10)` starts a point in.
    const ch = ui.div(c).row().h(28).px(10 + 1).gap(6).itemsCenter().rounded(14).border(k.border).borderW(1).hover(k.hover);
    defer ch.end();
    const hot = ch.hovered();
    if (ch.clicked()) a.composer.set(s.prompt);
    icons.icon(c, s.icon, 13, if (hot) k.text else k.muted, 0);
    var t = st;
    t.color = if (hot) k.text else k.muted;
    ui.text(c, s.title, t);
}
