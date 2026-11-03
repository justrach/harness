//! Write (crates/ui/src/composer/write.rs): the composer's draft on a full
//! page, for messages long enough to want room. It edits the composer's own
//! buffer, so the draft is the same text, and sends through the composer's
//! send. It takes over the chat pane, not a new window. Enter is a new line
//! there; ⌘↩ sends; Esc or ⌘⇧E goes back.
//!
//! Not here yet: the serif face and its "Aa" switch, and Markdown drawn as
//! it's typed. nanoui's text field has one face and no styled runs, so the
//! page uses the interface sans, as GPUI's does after "Aa".
const std = @import("std");
const builtin = @import("builtin");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const tip = @import("view_tooltip.zig");
const attachments = @import("app_attachments.zig");
const App = @import("app.zig").App;

/// `WRITE_TEXT_SIZE`, its line (`LINE_HEIGHT_RATIO` 1.6, rounded), the
/// column (`PAGE_MAX_WIDTH`) and its sides (`PAGE_SIDE_PADDING`).
pub const text_size: f32 = 18;
pub const line_h: f32 = 29;
const page_max_w: f32 = 720;
const page_side: f32 = 40;

/// `toggle_combo`: off macOS Ctrl+Shift+E already splits a pane down.
pub const toggle: ui.Shortcut = if (builtin.os.tag == .macos) .{ .key = 'e', .cmd = true, .shift = true } else .{ .key = 'e', .cmd = true, .alt = true };
const toggle_combo = if (builtin.os.tag == .macos) "mod-shift-e" else "mod-alt-e";

/// Words with a letter or digit in them, split at whitespace (`word_count`).
pub fn wordCount(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| {
        for (w) |ch| if (std.ascii.isAlphanumeric(ch) or ch >= 0x80) {
            n += 1;
            break;
        };
    }
    return n;
}

pub fn wordCountLabel(buf: []u8, n: usize) []const u8 {
    if (n == 1) return "1 word";
    return std.fmt.bufPrint(buf, "{d} words", .{n}) catch "";
}

test "words are counted as Write counts them (word_count)" {
    try std.testing.expectEqual(@as(usize, 0), wordCount(""));
    try std.testing.expectEqual(@as(usize, 4), wordCount("# Title\n\n- one **two**\n- `3`"));
    var b: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1 word", wordCountLabel(&b, 1));
    try std.testing.expectEqualStrings("214 words", wordCountLabel(&b, 214));
}

/// Open the draft on the page; a question or a queued edit keeps the
/// composer (`open_write`).
pub fn open(a: *App) void {
    if (a.view.write_open or a.wizard != null or a.queue_edit != null) return;
    a.view.write_open = true;
    a.view.write_focus = true;
    a.picker = .none;
    a.redraw();
}

/// Back to the composer, with the text where it was.
pub fn close(a: *App) void {
    if (!a.view.write_open) return;
    a.view.write_open = false;
    a.view.focus_composer = true;
    a.redraw();
}

fn sendFromPage(a: *App) void {
    a.send();
    // A sent draft clears the buffer, and the page goes with it.
    if (a.composer.text().len == 0) close(a);
}

/// The composer's way in (`render_write_button`): expand arrows in a
/// 28-point circle, the shortcut in its tooltip.
pub fn button(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.key(c, "composer-write");
    var buf: [24]u8 = undefined;
    const t = c.print("Write in full screen  {s}", .{@import("shortcuts.zig").badge(&buf, toggle_combo)});
    const b = tip.on(@import("view_kit.zig").listenerHover(&a.view.hovers, ui.div(c).row().size(28, 28).center().roundedFull(), k.ink(0.10)).div, k, .{ .text = t });
    defer b.end();
    icons.icon(c, .@"expand-arrows", 16, k.muted, 0);
    if (b.clicked()) open(a);
}

/// The page, in the pane's place.
pub fn page(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    if (c.shortcut(.{ .key = ui.Shortcut.escape }) or c.shortcut(toggle)) return close(a);
    ui.key(c, "write-page");
    const root = ui.div(c).column().wFull().grow().h(0).bg(k.pill());
    defer root.end();
    {
        // Done, the word count in the middle.
        const bar = column(c, w).h(44).itemsCenter();
        defer bar.end();
        var d = ui.div(c).row().h(28).px(8).itemsCenter().rounded(7).offset(-8, 0).hover(k.ink(0.06));
        var buf: [24]u8 = undefined;
        d = tip.on(d, k, .{ .text = c.print("Back to the chat  Esc \u{b7} {s}", .{@import("shortcuts.zig").badge(&buf, toggle_combo)}) });
        {
            defer d.end();
            ui.key(c, "write-done");
            ui.text(c, "Done", .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = if (d.hovered()) k.text else k.muted });
            if (d.clicked()) return close(a);
        }
        const mid = ui.div(c).row().absolute().offset(0, 0).w(w).h(44).justifyCenter().itemsCenter();
        defer mid.end();
        var nb: [32]u8 = undefined;
        ui.text(c, wordCountLabel(&nb, wordCount(a.composer.text())), .{ .size = 12, .line_height = 12 * 1.618, .color = k.faint });
    }
    {
        const area = column(c, w).grow().h(0).pt(12).pb(12);
        defer area.end();
        const at = c.nodes.items.len;
        const rect = c.rects.get(c.node(area.index).id);
        const lines: u16 = if (rect) |r| @intFromFloat(@max(1, @floor((r.h - 24) / line_h))) else 20;
        const r = ui.textField(c, &a.composer, .{
            .placeholder = "Do anything\u{2026}",
            .width = .fill,
            .bare = true,
            .size = text_size,
            .line_height = line_h,
            .placeholder_color = k.muted,
            .multiline = true,
            .max_lines = lines,
            .caret = @import("view_composer.zig").message_caret,
            .caret_color = k.accent,
        });
        const id = c.node(@intCast(at)).id;
        if (a.view.write_focus) {
            c.focus = id;
            c.changed = true;
            a.view.write_focus = false;
        }
        // Enter is a new line on the page, whatever the composer's setting.
        if (r.submitted) {
            _ = a.composer.insert(r.caret, "\n");
            a.composer.want_caret = r.caret + 1;
        }
        if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) sendFromPage(a);
    }
    dock(c, a, k, w);
}

/// The page's column: `PAGE_MAX_WIDTH` and its sides, centred.
fn column(c: *ui.Context, w: f32) ui.Div {
    const cw = @min(w, page_max_w + 2 * page_side);
    return ui.div(c).row().wFull().px(page_side + @max(0, (w - cw) / 2));
}

/// The paperclip, the send hint (or why it failed), and Send.
fn dock(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const outer = column(c, w).pb(16).column();
    defer outer.end();
    const box = @import("view_kit.zig").shadowLg(ui.div(c).column().wFull().rounded(22).border(k.border).borderW(1).bg(k.pill()));
    defer box.end();
    const row = ui.div(c).row().wFull().h(48).px(8).gap(8).itemsCenter();
    defer row.end();
    {
        ui.key(c, "write-attach");
        const b = ui.div(c).row().size(32, 32).center().roundedFull().hover(k.ink(0.08));
        defer b.end();
        icons.icon(c, .paperclip, 18, k.muted, 0);
        if (b.clicked()) attachments.pick(a);
    }
    const queue = a.queues();
    const label = if (queue) "Queue" else "Send";
    {
        const hint = ui.div(c).row().grow().w(0).clip();
        defer hint.end();
        var buf: [24]u8 = undefined;
        if (a.noticeText()) |n|
            ui.text(c, n, .{ .size = 12, .line_height = 12 * 1.618, .color = k.danger })
        else
            ui.text(c, c.print("{s} to {s}", .{ @import("shortcuts.zig").badge(&buf, "mod-enter"), if (queue) "queue" else "send" }), .{ .size = 12, .line_height = 12 * 1.618, .color = k.faint });
    }
    const has = std.mem.trim(u8, a.composer.text(), " \n\t").len > 0 or attachments.count(a) > 0;
    const enabled = has and !@import("app_agent.zig").chatSendBlocked(a);
    ui.key(c, "write-send");
    var s = ui.div(c).row().h(32).px(14).gap(6).itemsCenter().roundedFull();
    s = if (enabled) s.bg(k.accent) else s.bg(k.ink(0.08));
    if (enabled and s.hovered()) s = s.opacity(0.88);
    defer s.end();
    const fg = if (enabled) k.onAccent() else k.faint;
    ui.text(c, label, .{ .size = 13, .line_height = 13 * 1.618, .weight = .semibold, .color = fg });
    icons.icon(c, .@"arrow-up", 13, fg, 0);
    if (enabled and s.clicked()) sendFromPage(a);
}
