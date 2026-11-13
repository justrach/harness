//! Write (crates/ui/src/composer/write.rs): the composer's draft on a full
//! page, for messages long enough to want room. It edits the composer's own
//! buffer, so the draft is the same text, and sends through the composer's
//! send. It takes over the chat pane, not a new window. Enter is a new line
//! there; ⌘↩ sends; Esc or ⌘⇧E goes back.
//!
//! The default face is the interface sans, as on desktop. Optional serif
//! and live Markdown styling still need styled editable text in nanoui;
//! do not present a font toggle that cannot change the editing face.
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
pub const toolbar_h: f32 = 40;

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
    a.view.focus_composer = false;
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
/// 32-point circle, the shortcut in its tooltip.
pub fn button(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.key(c, "composer-write");
    var buf: [24]u8 = undefined;
    const t = c.print("Expand editor  {s}", .{@import("shortcuts.zig").badge(&buf, toggle_combo)});
    if (@import("view_kit.zig").iconButton(c, k, .@"expand-arrows", .{
        .size = 28,
        .radius = 14,
        .icon = 16,
        .tip = .{ .text = t },
    })) open(a);
}

/// The page replaces the pane without painting over its rounded surface.
pub fn page(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    if (c.shortcut(.{ .key = ui.Shortcut.escape }) or c.shortcut(toggle)) return close(a);
    ui.key(c, "write-page");
    const enter = ui.motion.frame(c, .{
        .initial = .{ .opacity = 0, .scale = 0.992 },
        .target = .{ .opacity = 1, .scale = 1 },
        .transition = .{ .tween = .{ .duration = 0.14, .ease = .ease_out } },
    });
    const root = ui.div(c).column().wFull().grow().h(0).motion(enter);
    defer root.end();
    toolbar(c, a, k, w);
    if (a.noticeText()) |n| {
        const notice = column(c, w).pt(10);
        defer notice.end();
        ui.text(c, n, .{ .size = 13, .line_height = 13 * 1.618, .color = k.danger });
    }
    if (attachments.count(a) > 0) {
        const material = column(c, w).column().pb(8);
        defer material.end();
        ui.scroll(c, .{ .width = .fill, .max_height = 180, .direction = .column });
        defer ui.end(c);
        @import("view_composer_attachments.zig").strip(c, a, k, pageWidth(w));
    }
    {
        // The bare field contributes two points of vertical padding.
        const area = column(c, w).grow().h(0).pt(10).pb(10);
        defer area.end();
        const rect = c.rects.get(c.node(area.index).id);
        const lines: u16 = if (rect) |r| @intFromFloat(@max(1, @floor((r.h - 24) / line_h))) else 20;
        if (a.view.write_focus) {
            c.focus = c.peekId(null);
            a.view.write_focus = false;
        }
        const field_id = c.peekId(null);
        const prev_edit = c.edits.get(field_id);
        const prev_caret: ?usize = if (prev_edit) |e| e.caret else null;
        const prev_anchor: ?usize = if (prev_edit) |e| e.anchor else null;
        const field_index: u32 = @intCast(c.nodes.items.len);
        const r = ui.textField(c, &a.composer, .{
            .placeholder = "Do anything\u{2026}",
            .width = .fill,
            .bare = true,
            .size = text_size,
            .line_height = line_h,
            .placeholder_color = k.muted,
            .multiline = true,
            .selection_mode = .prompt,
            .max_lines = lines,
            .caret = @import("view_composer.zig").message_caret,
            .caret_color = k.accent,
        });
        c.node(field_index).style.scroll_bar = false;
        _ = c.scrollbars.remove(field_id);
        if (c.edits.get(field_id)) |e| {
            const clicked_field = c.input.pressed and c.input.button == .left and !c.input.secondary and !c.right_press and c.hot == field_id;
            const moved_selection = prev_caret != null and (e.caret != prev_caret.? or e.anchor != prev_anchor.?);
            if (clicked_field or r.changed or moved_selection) c.selection.clear();
        }
        if (r.focused and c.shortcut(.{ .key = 'a', .cmd = true })) {
            if (c.edits.getPtr(field_id)) |e| {
                e.anchor = 0;
                e.caret = a.composer.text().len;
                c.selection.clear();
                c.changed = true;
            }
        }
        // Enter always inserts a line here, regardless of composer settings.
        if (r.submitted) {
            _ = a.composer.insert(r.caret, "\n");
            a.composer.want_caret = r.caret + 1;
        }
        if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) sendFromPage(a);
    }
}

pub fn sidePadding(w: f32) f32 {
    return if (w < 480) 20 else page_side;
}

pub fn pageWidth(w: f32) f32 {
    return @max(0, @min(w - 2 * sidePadding(w), page_max_w));
}

/// The desktop column narrows its gutters to20 in a panel under480.
fn column(c: *ui.Context, w: f32) ui.Div {
    return ui.div(c).row().wFull().px(@max(0, (w - pageWidth(w)) / 2));
}

fn toolbar(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    ui.key(c, "write-toolbar");
    const bar = ui.div(c).row().wFull().h(toolbar_h).px(8).gap(6).itemsCenter();
    defer bar.end();
    // The only chrome is the same full-width divider as Browser/Changes.
    ui.key(c, "write-toolbar-divider");
    ui.div(c).absolute().offset(-8, toolbar_h - 1).w(w).h(1).bg(k.border).end();
    {
        ui.key(c, "write-attach");
        const b = tip.on(ui.div(c).row().size(28, 28).center().rounded(6).hover(k.hover), k, .{ .text = "Attach files" });
        defer b.end();
        icons.icon(c, .paperclip, 16, k.muted, 0);
        if (b.clicked()) attachments.pick(a);
    }
    if (w >= 480) {
        const label = ui.div(c).row().pl(6);
        defer label.end();
        ui.text(c, "Edit message", .{ .size = 13, .line_height = 13 * 1.618, .color = k.muted });
    }
    ui.spacer(c);
    const has = std.mem.trim(u8, a.composer.text(), " \n\t").len > 0 or attachments.count(a) > 0;
    const enabled = has and !@import("app_agent.zig").chatSendBlocked(a);
    {
        ui.key(c, "write-send");
        var b = ui.div(c).row().h(28).px(10).center().rounded(6).border(k.border).borderW(1);
        b = if (enabled) b.hover(k.hover) else b.opacity(0.45);
        var badge_buf: [24]u8 = undefined;
        const send = tip.on(b, k, .{ .text = c.print("Send now  {s}", .{@import("shortcuts.zig").badge(&badge_buf, "mod-enter")}) });
        defer send.end();
        ui.text(c, "Send now", .{ .size = 13, .line_height = 13 * 1.618, .color = k.text });
        if (enabled and send.clicked()) sendFromPage(a);
    }
    {
        ui.key(c, "write-save");
        var buf: [24]u8 = undefined;
        const b = tip.on(ui.div(c).row().h(28).px(12).center().rounded(6).bg(k.solid).hover(k.solid.alpha(0.9)), k, .{ .text = c.print("Keep this draft in the chat  Esc · {s}", .{@import("shortcuts.zig").badge(&buf, toggle_combo)}) });
        defer b.end();
        ui.text(c, "Save", .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = k.on_solid });
        if (b.clicked()) close(a);
    }
}
