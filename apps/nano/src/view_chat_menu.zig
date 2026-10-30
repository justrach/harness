//! A session row's menu, as the GPUI app's (shell.rs `ChatMenuPage`):
//! Rename…, Pin or Unpin, Archive, Copy (a page of what to copy), and
//! Delete…, with the rename and delete dialogs (`popover::dialog_card`).
const std = @import("std");
const rules = @import("rules.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;

pub const Page = enum { root, copy };

/// The open menu: whose, where it opened, which page.
pub const Menu = struct {
    id: std.ArrayList(u8) = .empty,
    at: ui.Point = .{},
    page: Page = .root,
    open: bool = false,
};

/// The dialogs a menu row leads to.
pub const Dialogs = struct {
    rename: ?std.ArrayList(u8) = null,
    name: ui.TextBuffer = .{},
    focus_name: bool = false,
    delete: ?std.ArrayList(u8) = null,
    /// They're a project's (the project menu's Rename… and Remove…), not
    /// a session's.
    space: bool = false,

    pub fn deinit(d: *Dialogs, gpa: std.mem.Allocator) void {
        if (d.rename) |*r| r.deinit(gpa);
        if (d.delete) |*r| r.deinit(gpa);
    }
};

pub fn open(a: *App, chat_id: []const u8, at: ui.Point) void {
    const m = &a.view.chat_menu;
    m.id.clearRetainingCapacity();
    m.id.appendSlice(a.gpa, chat_id) catch return;
    m.at = at;
    m.page = .root;
    m.open = true;
}

fn close(a: *App) void {
    a.view.chat_menu.open = false;
}

/// Whether a menu or dialog of these is up, for Escape.
pub fn anyOpen(a: *const App) bool {
    return a.view.chat_menu.open or anyDialog(a);
}

/// A dialog is up: it has the keys.
pub fn anyDialog(a: *const App) bool {
    return a.view.dialogs.rename != null or a.view.dialogs.delete != null;
}

/// Rename… on a project (`open_rename_space`): its name to edit.
pub fn renameSpace(a: *App, space: workspace.Space) void {
    var id: std.ArrayList(u8) = .empty;
    id.appendSlice(a.gpa, space.id) catch return;
    if (a.view.dialogs.rename) |*old| old.deinit(a.gpa);
    a.view.dialogs.rename = id;
    a.view.dialogs.space = true;
    a.view.dialogs.name.set(space.name);
    a.view.dialogs.focus_name = true;
}

/// Remove… on a project: asks first (`delete_space_confirm`).
pub fn removeSpace(a: *App, space_id: []const u8) void {
    var id: std.ArrayList(u8) = .empty;
    id.appendSlice(a.gpa, space_id) catch return;
    if (a.view.dialogs.delete) |*old| old.deinit(a.gpa);
    a.view.dialogs.delete = id;
    a.view.dialogs.space = true;
}

/// Escape: the dialog, else the menu.
pub fn dismiss(a: *App) void {
    if (a.view.dialogs.rename != null) return endRename(a);
    if (a.view.dialogs.delete != null) return endDelete(a);
    close(a);
}

const phi: f32 = 1.618;

/// The menu and the dialogs, over everything.
pub fn overlays(c: *ui.Context, a: *App, k: theme.Colors) void {
    menu(c, a, k);
    renameDialog(c, a, k);
    deleteDialog(c, a, k);
}

fn menu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const m = &a.view.chat_menu;
    if (!m.open) return;
    const ch = a.findChat(m.id.items) orelse return close(a);
    {
        // A press anywhere else closes it (`on_mouse_down_out`).
        if (kit.pressedOutside(c, null)) return close(a);
    }
    const w: f32 = 216;
    const h = a.view.chat_menu_h orelse 200;
    const x = rules.snapToWindow(m.at.x, w, c.size.w, 8);
    const y = rules.snapToWindow(m.at.y, h, c.size.h, 8);
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(5).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer card.end();
    kit.rememberHeight(c, card, &a.view.chat_menu_h);
    switch (m.page) {
        .root => {
            const pinned = isPinned(a, ch.id);
            if (row(c, k, .pen, "Rename…", k.muted, k.text.alpha(0.9), false)) return startRename(a, ch);
            if (row(c, k, .pin, if (pinned) "Unpin" else "Pin", k.muted, k.text.alpha(0.9), false)) {
                close(a);
                return setPinned(a, ch.id, !pinned);
            }
            if (row(c, k, .@"archive-minimalistic", "Archive", k.muted, k.text.alpha(0.9), false)) {
                close(a);
                return a.setArchived(ch.id, true);
            }
            if (row(c, k, .copy, "Copy", k.muted, k.text.alpha(0.9), true)) m.page = .copy;
            separator(c, k, w);
            if (row(c, k, .@"trash-bin-minimalistic", "Delete…", k.danger, k.danger, false)) {
                close(a);
                var id: std.ArrayList(u8) = .empty;
                id.appendSlice(a.gpa, ch.id) catch return;
                if (a.view.dialogs.delete) |*old| old.deinit(a.gpa);
                a.view.dialogs.delete = id;
                a.view.dialogs.space = false;
            }
        },
        .copy => {
            if (row(c, k, .@"alt-arrow-left", "Back", k.muted, k.text.alpha(0.9), false)) m.page = .root;
            separator(c, k, w);
            if (copyPath(ch)) |path| if (row(c, k, .copy, "Path", k.muted, k.text.alpha(0.9), false)) return copied(c, a, path, "Path copied");
            if (row(c, k, .copy, "Harness conversation link", k.muted, k.text.alpha(0.9), false)) {
                var buf: [512]u8 = undefined;
                const link = conversationLink(&buf, ch.id, a.device_id orelse "") orelse return close(a);
                return copied(c, a, link, "Harness conversation link copied");
            }
            if (ch.harness_session_id) |sid| if (std.mem.trim(u8, sid, " ").len > 0) {
                if (ch.harness) |hn| if (std.mem.eql(u8, hn, "codex")) {
                    var buf: [512]u8 = undefined;
                    if (row(c, k, .copy, "Codex conversation link", k.muted, k.text.alpha(0.9), false))
                        return copied(c, a, std.fmt.bufPrint(&buf, "codex://threads/{s}", .{encode(c, std.mem.trim(u8, sid, " "))}) catch return, "Codex conversation link copied");
                };
                if (row(c, k, .copy, "Harness session ID", k.muted, k.text.alpha(0.9), false)) return copied(c, a, std.mem.trim(u8, sid, " "), "Harness session ID copied");
            };
        },
    }
}

fn copied(c: *ui.Context, a: *App, text: []const u8, note: []const u8) void {
    c.clipboard.write(c.clipboard.ctx, text);
    a.setNotice(note);
    close(a);
}

/// `menu_row`: a 16-point icon, 10 points, the label at 13; the selected
/// wash under the pointer. True when clicked.
fn row(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8, tint: ui.Color, color: ui.Color, onward: bool) bool {
    const r = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7).hover(k.selected);
    defer r.end();
    icons.icon(c, icon, 16, tint, 0);
    const t = ui.div(c).row().grow().w(0);
    {
        defer t.end();
        ui.text(c, label, .{ .size = 13, .line_height = 13 * phi, .color = if (r.hovered() and color.r == k.text.r) k.text else color });
    }
    if (onward) icons.icon(c, .@"alt-arrow-right", 14, k.muted, 0);
    return r.clicked();
}

fn separator(c: *ui.Context, k: theme.Colors, w: f32) void {
    const line: ui.Color = if (k.dark) .{ .r = 1, .g = 1, .b = 1, .a = 0.07 } else .{ .a = @min(0.07 * 1.35, 0.5) };
    const box = ui.div(c).column().wFull().py(2);
    defer box.end();
    _ = c.leaf(.{ .width = .{ .px = w - 2 }, .height = .{ .px = 1 }, .background = line, .offset = .{ .x = -4 } }, .none, null);
}

fn isPinned(a: *const App, id: []const u8) bool {
    for (a.settings.pins.items) |p| if (std.mem.eql(u8, p, id)) return true;
    return false;
}

/// Pin after the last pin, or unpin (`set_chat_pinned`).
fn setPinned(a: *App, id: []const u8, on: bool) void {
    var next: std.ArrayList([]const u8) = .empty;
    defer next.deinit(a.gpa);
    for (a.settings.pins.items) |p| if (!std.mem.eql(u8, p, id)) next.append(a.gpa, p) catch return;
    if (on) next.append(a.gpa, id) catch return;
    a.settings.setPins(next.items);
    if (on) a.view.pinned_open = true;
}

/// The chat's folder, when it's an absolute path on its host (`chat_copy_path`).
pub fn copyPath(ch: workspace.Chat) ?[]const u8 {
    const p = std.mem.trim(u8, ch.cwd orelse return null, " \t\n");
    if (p.len == 0) return null;
    const drive = p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '/' or p[2] == '\\');
    return if (p[0] == '/' or drive or std.mem.startsWith(u8, p, "\\\\")) p else null;
}

/// `harness://open/chat/<id>?workspace=<locator>`, the locator the first 16
/// hex digits of SHA-256 of "Local\0device:<id>" for a local workspace
/// (links.rs `workspace_locator`, `harness_conversation_link`).
pub fn conversationLink(buf: []u8, chat_id: []const u8, device_id: []const u8) ?[]const u8 {
    if (device_id.len == 0) return null;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("Local\x00device:");
    h.update(device_id);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("harness://open/chat/") catch return null;
    encodeTo(&w, chat_id) catch return null;
    w.print("?workspace={s}", .{hex[0..16]}) catch return null;
    return w.buffered();
}

/// Percent-encoded but for letters, digits and `-_.~` (`encode_component`).
fn encodeTo(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |b| {
        if (std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == '.' or b == '~') try w.writeByte(b) else try w.print("%{X:0>2}", .{b});
    }
}

fn encode(c: *ui.Context, s: []const u8) []const u8 {
    var w: std.Io.Writer.Allocating = .init(c.alloc());
    encodeTo(&w.writer, s) catch return s;
    return w.written();
}

fn startRename(a: *App, ch: workspace.Chat) void {
    close(a);
    var id: std.ArrayList(u8) = .empty;
    id.appendSlice(a.gpa, ch.id) catch return;
    if (a.view.dialogs.rename) |*old| old.deinit(a.gpa);
    a.view.dialogs.rename = id;
    a.view.dialogs.space = false;
    a.view.dialogs.name.set(ch.title orelse "");
    a.view.dialogs.focus_name = true;
}

/// The scrim a dialog sits on, centring it. Keyed: its field keeps the
/// focus when a menu drawn before it goes.
pub fn scrim(c: *ui.Context, k: theme.Colors) ui.Div {
    ui.key(c, "dialog-scrim");
    return ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(6).bg(.{ .a = if (k.dark) 0.35 else 0.32 }).center();
}

/// The dialog card (`dialog_card`): 360 wide, 20 in (and its border),
/// rounded 16.
pub fn dialog(c: *ui.Context, k: theme.Colors) ui.Div {
    return kit.shadowLg(ui.div(c).w(360).p(21).column().rounded(16).bg(k.composer)
        .border(if (k.dark) ui.Color{ .r = 1, .g = 1, .b = 1, .a = 0.10 } else ui.Color{ .a = 0.135 }).borderW(1));
}

pub fn buttons(c: *ui.Context, k: theme.Colors, confirm: []const u8, danger: bool) enum { none, cancel, confirm } {
    _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
    const r = ui.div(c).row().wFull().gap(8).justifyEnd();
    defer r.end();
    var out: @TypeOf(buttons(c, k, confirm, danger)) = .none;
    {
        const b = ui.div(c).row().px(12).py(6).rounded(8).hover(k.ink(0.06));
        defer b.end();
        ui.text(c, "Cancel", .{ .size = 13, .line_height = kit.measured(13 * phi), .color = if (b.hovered()) k.text else k.muted });
        if (b.clicked()) out = .cancel;
    }
    const b = ui.div(c).row().px(12).py(6).rounded(8).bg(if (danger) k.danger else k.solid);
    defer b.end();
    ui.text(c, confirm, .{ .size = 13, .line_height = kit.measured(13 * phi), .weight = .medium, .color = if (danger) ui.Color.white else k.on_solid });
    if (b.clicked()) out = .confirm;
    return out;
}

fn renameDialog(c: *ui.Context, a: *App, k: theme.Colors) void {
    const id = (a.view.dialogs.rename orelse return).items;
    const back = scrim(c, k);
    defer back.end();
    const card = dialog(c, k);
    defer card.end();
    const space = a.view.dialogs.space;
    ui.text(c, if (space) "Rename project" else "Rename session", .{ .size = 15, .line_height = kit.measured(15 * phi), .weight = .semibold, .color = k.text });
    _ = c.leaf(.{ .height = .{ .px = 12 } }, .none, null);
    var submit = false;
    {
        const f = ui.div(c).row().wFull().px(13).py(9).rounded(8).border(k.ink(0.08)).borderW(1).bg(k.ink(0.04));
        defer f.end();
        const at = c.nodes.items.len;
        const r = ui.textField(c, &a.view.dialogs.name, .{ .width = .fill, .bare = true, .size = 14 });
        if (a.view.dialogs.focus_name) {
            c.focus = c.node(@intCast(at)).id;
            c.changed = true;
            a.view.dialogs.focus_name = false;
        }
        submit = r.submitted;
    }
    const pressed = buttons(c, k, "Rename", false);
    if (pressed == .cancel) return endRename(a);
    if (pressed == .confirm or submit) {
        const title = std.mem.trim(u8, a.view.dialogs.name.text(), " \t\n");
        if (title.len > 0) {
            if (space)
                a.call("Mutate", .{ .op = "renameSpace", .spaceId = id, .name = title }, .of(App, a, App.onNotice))
            else
                a.call("Mutate", .{ .op = "renameChat", .chatId = id, .title = title }, .of(App, a, App.onNotice));
        }
        endRename(a);
    }
}

fn endRename(a: *App) void {
    if (a.view.dialogs.rename) |*r| r.deinit(a.gpa);
    a.view.dialogs.rename = null;
}

fn deleteDialog(c: *ui.Context, a: *App, k: theme.Colors) void {
    const id = (a.view.dialogs.delete orelse return).items;
    if (a.view.dialogs.space) return removeSpaceDialog(c, a, k, id);
    const back = scrim(c, k);
    defer back.end();
    const card = dialog(c, k);
    defer card.end();
    const title = if (a.findChat(id)) |ch| (ch.title orelse "New session") else "New session";
    ui.text(c, "Delete session?", .{ .size = 15, .line_height = kit.measured(15 * phi), .weight = .semibold, .color = k.text });
    _ = c.leaf(.{ .height = .{ .px = 6 } }, .none, null);
    ui.text(c, c.print("\u{201C}{s}\u{201D} will be permanently deleted. This can\u{2019}t be undone.", .{firstLine(title)}), .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
    const pressed = buttons(c, k, "Delete", true);
    if (pressed == .cancel) return endDelete(a);
    if (pressed == .confirm) {
        a.call("Mutate", .{ .op = "deleteChat", .chatId = id }, .of(App, a, App.onNotice));
        a.tabs.forget(id);
        endDelete(a);
    }
}

/// "Remove project?" (`delete_space_confirm`): what goes with it, then
/// `deleteSpace`.
fn removeSpaceDialog(c: *ui.Context, a: *App, k: theme.Colors, id: []const u8) void {
    const back = scrim(c, k);
    defer back.end();
    const card = dialog(c, k);
    defer card.end();
    const space = a.findSpace(id);
    ui.text(c, "Remove project?", .{ .size = 15, .line_height = kit.measured(15 * phi), .weight = .semibold, .color = k.text });
    _ = c.leaf(.{ .height = .{ .px = 6 } }, .none, null);
    ui.text(c, removeCopy(c, a, id, space), .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
    const pressed = buttons(c, k, "Remove", true);
    if (pressed == .cancel) return endDelete(a);
    if (pressed == .confirm) {
        a.call("Mutate", .{ .op = "deleteSpace", .spaceId = id }, .of(App, a, App.onNotice));
        endDelete(a);
    }
}

/// How many sessions go with the project, and from which device.
fn removeCopy(c: *ui.Context, a: *const App, id: []const u8, space: ?workspace.Space) []const u8 {
    var count: usize = 0;
    for (a.chats.items) |ch| if (!ch.archived and ch.parent_chat_id == null and ch.space_id != null and std.mem.eql(u8, ch.space_id.?, id)) {
        count += 1;
    };
    const name = if (space) |s| s.name else "this project";
    const device = if (space) |s| known: {
        for (a.devices.items) |d| if (s.device_id != null and std.mem.eql(u8, d.id, s.device_id.?)) break :known d.name;
        break :known "its device";
    } else "its device";
    return if (count == 1)
        c.print("Removing \u{201C}{s}\u{201D} permanently deletes its 1 session on {s}. This can\u{2019}t be undone.", .{ name, device })
    else
        c.print("Removing \u{201C}{s}\u{201D} permanently deletes its {d} sessions on {s}. This can\u{2019}t be undone.", .{ name, count, device });
}

fn endDelete(a: *App) void {
    if (a.view.dialogs.delete) |*r| r.deinit(a.gpa);
    a.view.dialogs.delete = null;
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

const testing = std.testing;

test "the conversation link and the copied path as the GPUI app's" {
    var buf: [512]u8 = undefined;
    const link = conversationLink(&buf, "chat 1", "dev").?;
    try testing.expect(std.mem.startsWith(u8, link, "harness://open/chat/chat%201?workspace="));
    try testing.expectEqual(@as(usize, "harness://open/chat/chat%201?workspace=".len + 16), link.len);
    try testing.expect(conversationLink(&buf, "x", "") == null);
    var ch: workspace.Chat = .{ .id = "c", .title = null, .space_id = null, .archived = false, .preview = null, .harness = null, .model = null, .cwd = " /work/fieldnotes " };
    try testing.expectEqualStrings("/work/fieldnotes", copyPath(ch).?);
    ch.cwd = "relative/path";
    try testing.expect(copyPath(ch) == null);
    ch.cwd = "C:\\work";
    try testing.expect(copyPath(ch) != null);
}
