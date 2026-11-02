//! Settings › Archived sessions (settings/archived.rs): the archive-on-close
//! switch, each archived chat with Unarchive on hover, and a confirmed
//! Delete all (a `deleteChat` Mutate per chat, one after another).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rpc = @import("rpc.zig");
const rules = @import("rules.zig");
const set = @import("view_settings.zig");
const dialogs = @import("view_chat_menu.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const phi: f32 = 1.618;

pub const Page = struct {
    /// The chat an Unarchive is in flight for.
    busy: ?[]u8 = null,
    /// The strip under the switch; empty for none. A click clears it.
    failure: std.ArrayList(u8) = .empty,
    /// The archived ids when Delete all was clicked: the dialog deletes
    /// exactly these, never a chat archived while it was open.
    confirm: ?[][]u8 = null,
    /// What Delete all has still to delete, and how many it couldn't.
    queue: std.ArrayList([]u8) = .empty,
    deleting: bool = false,
    failed: usize = 0,
    /// Delete all's focus ring, as last drawn (its width is the column's).
    ring: f32 = 0,

    pub fn deinit(p: *Page, gpa: Allocator) void {
        if (p.busy) |b| gpa.free(b);
        p.failure.deinit(gpa);
        freeIds(gpa, p.confirm);
        for (p.queue.items) |id| gpa.free(id);
        p.queue.deinit(gpa);
    }
};

fn freeIds(gpa: Allocator, ids: ?[][]u8) void {
    const list = ids orelse return;
    for (list) |id| gpa.free(id);
    gpa.free(list);
}

fn fail(a: *App, comptime fmt: []const u8, args: anytype) void {
    const p = &a.view.archived;
    p.failure.clearRetainingCapacity();
    p.failure.print(a.gpa, fmt, args) catch {};
}

fn unarchive(a: *App, chat_id: []const u8) void {
    const p = &a.view.archived;
    if (p.busy) |b| a.gpa.free(b);
    p.busy = a.gpa.dupe(u8, chat_id) catch null;
    p.failure.clearRetainingCapacity();
    a.request(@import("requests.zig").setChatArchived(chat_id, false), .of(App, a, onUnarchived));
}

fn onUnarchived(a: *App, _: u64, r: rpc.Reply) void {
    const p = &a.view.archived;
    if (p.busy) |b| a.gpa.free(b);
    p.busy = null;
    if (r == .err) fail(a, "Unarchive failed: {s}", .{r.err});
    a.redraw();
}

fn requestDeleteAll(a: *App) void {
    const p = &a.view.archived;
    if (p.deleting) return;
    var ids: std.ArrayList([]u8) = .empty;
    for (a.chats.items) |ch| if (ch.archived) {
        const id = a.gpa.dupe(u8, ch.id) catch continue;
        ids.append(a.gpa, id) catch a.gpa.free(id);
    };
    if (ids.items.len == 0) return ids.deinit(a.gpa);
    freeIds(a.gpa, p.confirm);
    p.confirm = ids.toOwnedSlice(a.gpa) catch null;
}

/// Escape closes the Delete all dialog; false when none was open.
pub fn escape(c: *ui.Context, a: *App) bool {
    const p = &a.view.archived;
    if (p.confirm == null or !c.shortcut(.{ .key = ui.Shortcut.escape })) return false;
    freeIds(a.gpa, p.confirm);
    p.confirm = null;
    return true;
}

fn deleteAll(a: *App) void {
    const p = &a.view.archived;
    const ids = p.confirm orelse return;
    p.confirm = null;
    defer a.gpa.free(ids);
    if (p.deleting) return freeIds(a.gpa, ids);
    p.failure.clearRetainingCapacity();
    p.deleting = true;
    p.failed = 0;
    // Deleted first to last: the queue is taken from its end.
    var i = ids.len;
    while (i > 0) {
        i -= 1;
        p.queue.append(a.gpa, ids[i]) catch a.gpa.free(ids[i]);
    }
    next(a);
}

/// The next confirmed chat still archived (unarchived since, here or on
/// another device, it's spared), or the end of the run.
fn next(a: *App) void {
    const p = &a.view.archived;
    while (p.queue.pop()) |id| {
        defer a.gpa.free(id);
        const ch = a.findChat(id) orelse continue;
        if (!ch.archived) continue;
        a.call("Mutate", .{ .op = "deleteChat", .chatId = id }, .of(App, a, onDeleted));
        return;
    }
    p.deleting = false;
    if (p.failed == 1)
        fail(a, "Couldn\u{2019}t delete 1 archived session. Try again.", .{})
    else if (p.failed > 1)
        fail(a, "Couldn\u{2019}t delete {d} archived sessions. Try again.", .{p.failed});
    a.redraw();
}

fn onDeleted(a: *App, _: u64, r: rpc.Reply) void {
    if (r == .err) a.view.archived.failed += 1;
    next(a);
}

pub fn deleteAllBody(buf: []u8, count: usize) []const u8 {
    return if (count == 1)
        "1 archived session will be permanently deleted. This can\u{2019}t be undone."
    else
        std.fmt.bufPrint(buf, "{d} archived sessions will be permanently deleted. This can\u{2019}t be undone.", .{count}) catch "";
}

// Rendering.

/// Delete all's fill (`btn_danger` with the trash glyph; the theme's
/// `danger_strong` is its `danger`): 12 by 6 in, rounded 8.
fn deleteAllW(c: *ui.Context, label: []const u8) f32 {
    return 2 * 12 + 14 + 6 + c.text.width(label, .{ .size = 13, .weight = .medium });
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.archived;
    var count: usize = 0;
    for (a.chats.items) |ch| if (ch.archived) {
        count += 1;
    };
    {
        // Delete all sits bottom-right, level with the subtitle.
        const head = ui.div(c).row().wFull().gap(16).itemsEnd();
        defer head.end();
        const label = if (p.deleting) "Deleting…" else "Delete all";
        const button_w: f32 = if (count > 0) 16 + deleteAllW(c, label) + 2 * p.ring else 0;
        {
            const col = ui.div(c).column().w(set.inner_w - button_w);
            defer col.end();
            set.header(c, k, "Archived sessions", if (count > 0) count else null);
            set.space(c, 4);
            ui.text(c, "Hidden from the sidebar until you unarchive or delete them. Unarchiving puts a session back on its device.", .{ .size = 13, .line_height = 13 * phi, .wrap = true, .color = k.muted });
        }
        if (count > 0) {
            var b = ui.div(c).row().gap(6).itemsCenter().rounded(8).bg(k.danger);
            // Focused from its click, it rings once keys are used.
            const ring: f32 = if (kit.focusRing(c, b, k.accent, 2)) 2 else 0;
            if (ring != p.ring) {
                p.ring = ring;
                c.animating = true;
            }
            b = b.px(12 + ring).py(6 + ring);
            // Half while deleting; 0.9 under the pointer.
            if (p.deleting) b = b.opacity(0.5) else if (b.hovered()) b = b.opacity(0.9);
            defer b.end();
            icons.icon(c, .@"trash-bin-minimalistic", 14, ui.Color.white, 0);
            ui.text(c, label, set.st(c, 13, .{ .weight = .medium, .color = ui.Color.white }));
            if (!p.deleting and b.clicked()) requestDeleteAll(a);
        }
    }
    {
        const cd = set.card(c, k);
        defer cd.end();
        const r = set.row(c, k, true, false);
        defer r.end();
        {
            const w = ui.div(c).column().w(@max(set.inner_w - 2 - 2 * 20 - 14 - 40, 80)).gap(4);
            defer w.end();
            ui.text(c, "Archive sessions when closing tabs or panes", set.st(c, 13, .{ .weight = .medium, .color = k.text }));
            ui.text(c, "Closing a session tab or pane with ⌘W or its ✕ button archives it if idle, unless it is still open in another tab or pane in this app. ⌥⌘W always closes without archiving. Running sessions and sessions waiting for input remain in the sidebar. Closing the app or a window does not archive sessions.", set.st(c, 12, .{ .wrap = true, .color = k.muted }));
        }
        if (set.toggle(c, k, a.settings.get(.archive_sessions_on_close), true)) {
            a.settings.toggle(.archive_sessions_on_close);
            a.redraw();
        }
    }
    if (p.failure.items.len > 0) {
        if (@import("view_settings_accounts_rows.zig").errorStrip(c, k, p.failure.items, false)) p.failure.clearRetainingCapacity();
    }
    if (count == 0) {
        set.space(c, 96);
        const e = ui.div(c).column().wFull().itemsCenter();
        defer e.end();
        icons.icon(c, .@"archive-minimalistic", 28, k.muted.alpha(0.2), 0);
        set.space(c, 12);
        const t = ui.div(c).row();
        {
            defer t.end();
            ui.text(c, "Nothing archived", set.st(c, 14, .{ .color = k.muted.alpha(0.5) }));
        }
        set.space(c, 4);
        const s = ui.div(c).row();
        defer s.end();
        ui.text(c, "Right-click a session in the sidebar to archive it.", set.st(c, 12, .{ .color = k.muted.alpha(0.4) }));
        return;
    }
    set.space(c, 24);
    const list = ui.div(c).column().wFull().gap(2);
    defer list.end();
    for (a.chats.items) |ch| if (ch.archived) row(c, a, k, ch);
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, ch: @import("workspace.zig").Chat) void {
    const p = &a.view.archived;
    ui.key(c, ch.id);
    const busy = if (p.busy) |b| std.mem.eql(u8, b, ch.id) else false;
    const r = ui.div(c).row().wFull().px(12).py(8).gap(12).itemsCenter().rounded(8).hover(k.ink(0.03));
    defer r.end();
    const hot = r.hovered();
    {
        const t = ui.div(c).row().size(32, 32).center().rounded(6).border(k.border).borderW(1);
        defer t.end();
        icons.icon(c, .@"archive-minimalistic", 16, k.muted.alpha(0.6), 0);
    }
    {
        const w = ui.div(c).column().grow().w(0);
        defer w.end();
        {
            const top = ui.div(c).row().gap(8).itemsCenter();
            defer top.end();
            kit.ellipsisText(c, ch.title orelse "Untitled session", set.st(c, 13, .{ .weight = .medium, .color = k.text }), 420);
            const then = if (ch.last_message_ms != 0) ch.last_message_ms else ch.created_ms;
            const ago = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, a.nowMs(), then);
            ui.text(c, ago, set.st(c, 11, .{ .color = k.muted.alpha(0.5) }));
        }
        set.space(c, 2);
        // device · location; an unknown device has no fragment at all.
        const meta = ui.div(c).row().gap(6).itemsCenter();
        defer meta.end();
        const tone = set.st(c, 11, .{ .color = k.muted.alpha(0.55) });
        const device: ?[]const u8 = for (a.devices.items) |d| {
            if (ch.device_id != null and std.mem.eql(u8, d.id, ch.device_id.?)) break d.name;
        } else null;
        const location = rules.chatLocation(c.alloc().alloc(u8, 256) catch &.{}, ch.cwd, ch.row_branch);
        if (device) |d| ui.text(c, d, tone);
        if (device != null and location != null) ui.text(c, "·", tone);
        if (location) |l| ui.text(c, l, tone);
    }
    var u = ui.div(c).row().px(11).py(5).gap(6).itemsCenter().rounded(6).border(k.border).borderW(1).hover(k.raised);
    u = u.opacity(if (busy) 0.4 else if (hot) 1 else 0);
    defer u.end();
    const lit = u.hovered();
    icons.icon(c, .@"archive-up-minimalistic", 14, k.muted, 0);
    ui.text(c, if (busy) "Unarchiving…" else "Unarchive", set.st(c, 12, .{ .color = if (lit) k.text else k.muted }));
    if (hot and !busy and u.clicked()) unarchive(a, ch.id);
}

/// "Delete all archived sessions?", over the page.
pub fn dialog(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.archived;
    const ids = p.confirm orelse return;
    const back = dialogs.scrim(c, k);
    defer back.end();
    const card = dialogs.dialog(c, k);
    defer card.end();
    ui.text(c, "Delete all archived sessions?", .{ .size = 15, .line_height = kit.measured(15 * phi), .weight = .semibold, .color = k.text });
    _ = c.leaf(.{ .height = .{ .px = 6 } }, .none, null);
    // Drawn after this returns: the words live as long as the frame.
    ui.text(c, deleteAllBody(c.alloc().alloc(u8, 128) catch &.{}, ids.len), .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
    switch (dialogs.buttons(c, k, "Delete all", true)) {
        .none => {},
        .cancel => {
            freeIds(a.gpa, p.confirm);
            p.confirm = null;
        },
        .confirm => deleteAll(a),
    }
}

test "Delete all's copy counts one and many" {
    var buf: [128]u8 = undefined;
    try std.testing.expect(std.mem.startsWith(u8, deleteAllBody(&buf, 1), "1 archived session will"));
    try std.testing.expect(std.mem.startsWith(u8, deleteAllBody(&buf, 146), "146 archived sessions will"));
}
