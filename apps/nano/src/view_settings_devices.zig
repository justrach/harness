//! Settings › Devices, as the GPUI app's (settings/devices.rs): this build's
//! version, then a card of the workspace's devices, each with its platform
//! on a tile that carries its presence, a quiet line of platform, version,
//! when it was last seen and added, and its id; this one marked.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const set = @import("view_settings.zig");
const kit = @import("view_kit.zig");
const account = @import("app_account.zig");
const workspace = @import("workspace.zig");
const rpc = @import("rpc.zig");
const dialogs = @import("view_chat_menu.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const phi: f32 = 1.618;

/// What the page keeps between frames.
pub const Page = struct {
    /// The device being renamed, and its name as typed.
    rename: std.ArrayList(u8) = .empty,
    renaming: bool = false,
    name: ui.TextBuffer = .{},
    focus_name: bool = false,
    /// The device whose id chip says "Copied", until `copied_until`.
    copied: std.ArrayList(u8) = .empty,
    copied_until: f64 = 0,
    /// The device whose Remove asks for a second click.
    confirm_remove: std.ArrayList(u8) = .empty,
    /// The strip under the version; a click clears it.
    failure: std.ArrayList(u8) = .empty,

    pub fn deinit(p: *Page, gpa: Allocator) void {
        p.rename.deinit(gpa);
        p.copied.deinit(gpa);
        p.confirm_remove.deinit(gpa);
        p.failure.deinit(gpa);
    }
};

fn setTo(gpa: Allocator, list: *std.ArrayList(u8), s: []const u8) void {
    list.clearRetainingCapacity();
    list.appendSlice(gpa, s) catch {};
}

fn openRename(a: *App, d: workspace.Device) void {
    const p = &a.view.devices;
    setTo(a.gpa, &p.rename, d.id);
    p.renaming = true;
    p.name.set(d.name);
    p.focus_name = true;
}

fn submitRename(a: *App) void {
    const p = &a.view.devices;
    p.renaming = false;
    const name = std.mem.trim(u8, p.name.text(), " \t\r\n");
    if (name.len == 0) return;
    a.call("Mutate", .{ .op = "renameDevice", .deviceId = p.rename.items, .name = name }, .of(App, a, onRenamed));
}

fn onRenamed(a: *App, _: u64, r: rpc.Reply) void {
    if (r == .err) fail(a, "Rename failed: {s}", .{r.err});
    a.redraw();
}

/// An offline device off the list (a finished cloud sandbox, a computer
/// that's gone); it comes back if that device starts Harness again.
fn forget(a: *App, id: []const u8) void {
    a.call("Mutate", .{ .op = "forgetDevice", .deviceId = id }, .of(App, a, onForgotten));
    a.view.devices.confirm_remove.clearRetainingCapacity();
}

fn onForgotten(a: *App, _: u64, r: rpc.Reply) void {
    if (r == .err) fail(a, "Couldn't remove the device: {s}", .{r.err});
    a.redraw();
}

fn fail(a: *App, comptime fmt: []const u8, args: anytype) void {
    const p = &a.view.devices;
    p.failure.clearRetainingCapacity();
    p.failure.print(a.gpa, fmt, args) catch {};
}

/// Escape closes the Rename dialog; false when it wasn't open.
pub fn escape(c: *ui.Context, a: *App) bool {
    const p = &a.view.devices;
    if (!p.renaming or !c.shortcut(.{ .key = ui.Shortcut.escape })) return false;
    p.renaming = false;
    return true;
}

/// Seen this recently, a device is online (`DEVICE_ONLINE_WINDOW_SECS`).
const online_window_ms: i64 = 70 * 1000;

pub fn online(last_seen_ms: i64, now_ms: i64) bool {
    return last_seen_ms > 0 and now_ms - last_seen_ms <= online_window_ms;
}

/// "just now", "5m ago", "3h ago", "2d ago", or "never seen"
/// (`format_last_seen`).
pub fn lastSeen(buf: []u8, then_ms: i64, now_ms: i64) []const u8 {
    if (then_ms == 0) return "never seen";
    const s = @divFloor(@max(now_ms - then_ms, 0), 1000);
    return (if (s < 60)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m ago", .{@divFloor(s, 60)})
    else if (s < 86_400)
        std.fmt.bufPrint(buf, "{d}h ago", .{@divFloor(s, 3600)})
    else
        std.fmt.bufPrint(buf, "{d}d ago", .{@divFloor(s, 86_400)})) catch "";
}

/// What the page says the list is (`devices_subtitle`).
pub fn subtitle(scope: ?account.Scope) []const u8 {
    return switch (scope orelse .development) {
        .local => "Manage device details stored in this local workspace.",
        .synced => "Manage device names and inspect synced device metadata.",
        .development => "Manage device names for this workspace.",
    };
}

pub fn platformLabel(p: []const u8) []const u8 {
    const names = .{ .{ "macos", "macOS" }, .{ "darwin", "macOS" }, .{ "linux", "Linux" }, .{ "windows", "Windows" }, .{ "web", "Web" }, .{ "ios", "iOS" }, .{ "android", "Android" } };
    inline for (names) |n| if (std.mem.eql(u8, p, n[0])) return n[1];
    return p;
}

fn platformIcon(p: []const u8) icons.Name {
    if (std.mem.eql(u8, p, "macos") or std.mem.eql(u8, p, "darwin")) return .laptop;
    if (std.mem.eql(u8, p, "web")) return .global;
    if (std.mem.eql(u8, p, "ios") or std.mem.eql(u8, p, "android")) return .smartphone;
    return .monitor;
}

/// The id chip's text: `abcd1234…wxyz` for a long id (`short_id`).
pub fn shortId(buf: []u8, id: []const u8) []const u8 {
    if (id.len <= 12) return id;
    return std.fmt.bufPrint(buf, "{s}…{s}", .{ id[0..8], id[id.len - 4 ..] }) catch id;
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const devices = a.devices.items;
    set.header(c, k, "Devices", if (devices.len > 0) devices.len else null);
    set.subtitle(c, k, subtitle(a.account.scope), false);
    {
        // This build's version: a row on the page, not in a card. Harness
        // Nano doesn't update itself (`update_summary` without an updater).
        const r = set.row(c, k, true, false);
        defer r.end();
        set.tile(c, k, .refresh);
        set.words(c, k, c.print("Harness v{s}", .{@import("build_info").version}), "This build doesn't update itself. Install the latest release to update.", 0);
    }
    const p = &a.view.devices;
    if (p.failure.items.len > 0) {
        if (@import("view_settings_accounts_rows.zig").errorStrip(c, k, p.failure.items, false)) p.failure.clearRetainingCapacity();
    }
    if (p.copied.items.len > 0) {
        if (c.time >= p.copied_until) p.copied.clearRetainingCapacity() else c.frameIn(@floatCast(p.copied_until - c.time));
    }
    defer renameDialog(c, a, k);
    const card = set.card(c, k);
    defer card.end();
    if (devices.len == 0) {
        const e = ui.div(c).row().wFull().px(20).py(40).justifyCenter();
        defer e.end();
        ui.text(c, "No devices registered", set.st(c, 14, .{ .color = k.muted.alpha(0.6) }));
        return;
    }
    const now = a.nowMs();
    for (devices, 0..) |d, ix| {
        ui.key(c, d.id);
        const local = if (a.device_id) |me| std.mem.eql(u8, me, d.id) else false;
        const on = online(d.last_seen_ms, now);
        const r = set.row(c, k, ix == 0, false);
        defer r.end();
        presenceTile(c, k, platformIcon(d.platform), on);
        {
            const w = ui.div(c).column().grow().w(0).gap(1);
            defer w.end();
            ui.text(c, d.name, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
            meta(c, a, k, d, on, now);
        }
        if (local) ui.text(c, if (a.account.scope == .local) "Local only" else "This device", .{ .size = 10.5, .line_height = 10.5 * 1.618, .color = k.muted });
        if (action(c, k, .pen, "Rename", false)) openRename(a, d);
        // Only offline devices, never this one: the engine refuses an online
        // one, which would vanish until it restarted. A second click removes.
        if (!on and !local) {
            const confirming = std.mem.eql(u8, p.confirm_remove.items, d.id);
            if (action(c, k, null, if (confirming) "Remove?" else "Remove", confirming)) {
                if (confirming) forget(a, d.id) else setTo(a.gpa, &p.confirm_remove, d.id);
            }
        }
    }
}

/// The platform's tile with presence on its corner: a dot ringed in the
/// card's tone, green and glowing online, faint offline.
fn presenceTile(c: *ui.Context, k: theme.Colors, icon: icons.Name, on: bool) void {
    const t = ui.div(c).row().size(36, 36).center().rounded(10).border(k.border).borderW(1).bg(k.ink(0.03));
    defer t.end();
    icons.icon(c, icon, 16, k.muted, 0);
    var dot = ui.div(c).absolute().offset(36 - 9 + 3, 36 - 9 + 3).size(9, 9).roundedFull().border(k.shell).borderW(2);
    dot = if (on) dot.bg(k.success).shadow(.{ .color = k.success.alpha(0.55), .blur = 6 }) else dot.bg(k.ink(0.22));
    dot.end();
}

/// platform · version · last seen (offline) · added · id, quiet, joined by
/// dots fainter still (`meta_line`).
fn meta(c: *ui.Context, a: *App, k: theme.Colors, d: workspace.Device, on: bool, now: i64) void {
    const line = ui.div(c).row().gap(8).itemsCenter();
    defer line.end();
    const st = set.st(c, 12, .{ .color = k.muted.alpha(0.65) });
    var first = true;
    const Frag = struct {
        fn sep(cx: *ui.Context, kk: theme.Colors, is_first: *bool) void {
            if (!is_first.*) ui.text(cx, "·", set.st(cx, 12, .{ .color = kk.muted.alpha(0.3) }));
            is_first.* = false;
        }
    };
    Frag.sep(c, k, &first);
    ui.text(c, platformLabel(d.platform), st);
    if (d.version) |v| if (v.len > 0) {
        Frag.sep(c, k, &first);
        ui.text(c, c.print("v{s}", .{v}), st);
    };
    var buf: [32]u8 = undefined;
    if (!on) {
        Frag.sep(c, k, &first);
        ui.text(c, c.print("Last seen {s}", .{lastSeen(&buf, d.last_seen_ms, now)}), st);
    }
    if (d.created_ms != 0) {
        Frag.sep(c, k, &first);
        ui.text(c, c.print("Added {s}", .{lastSeen(&buf, d.created_ms, now)}), st);
    }
    Frag.sep(c, k, &first);
    // The id chip: a click copies the whole id, and it says so a moment.
    const p = &a.view.devices;
    const copied = std.mem.eql(u8, p.copied.items, d.id);
    const chip = ui.div(c).row();
    defer chip.end();
    var idb: [64]u8 = undefined;
    const color = if (copied) k.success_muted.alpha(0.9) else if (chip.hovered()) k.muted else k.muted.alpha(0.5);
    ui.text(c, if (copied) "Copied" else c.print("{s}", .{shortId(&idb, d.id)}), .{ .size = 10.5, .line_height = 12 * 1.618, .mono = true, .color = color });
    if (chip.clicked()) {
        c.clipboard.write(c.clipboard.ctx, d.id);
        setTo(a.gpa, &p.copied, d.id);
        p.copied_until = c.time + 1.5;
        c.frameIn(1.5);
    }
}

/// "Rename device": the name in a field, Cancel and Rename.
fn renameDialog(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.devices;
    if (!p.renaming) return;
    const back = dialogs.scrim(c, k);
    defer back.end();
    const card = dialogs.dialog(c, k);
    defer card.end();
    ui.text(c, "Rename device", .{ .size = 15, .line_height = kit.measured(15 * phi), .weight = .semibold, .color = k.text });
    _ = c.leaf(.{ .height = .{ .px = 12 } }, .none, null);
    var submit = false;
    {
        const f = ui.div(c).row().wFull().px(13).py(9).rounded(8).border(k.ink(0.08)).borderW(1).bg(k.ink(0.04));
        defer f.end();
        const at = c.nodes.items.len;
        const r = ui.textField(c, &p.name, .{ .placeholder = "Device name", .width = .fill, .bare = true, .size = 14 });
        if (p.focus_name) {
            c.focus = c.node(@intCast(at)).id;
            c.changed = true;
            p.focus_name = false;
        }
        submit = r.submitted;
    }
    switch (dialogs.buttons(c, k, "Rename", false)) {
        .none => if (submit) submitRename(a),
        .cancel => p.renaming = false,
        .confirm => submitRename(a),
    }
}

/// `ghost_action` at 70%, full under the pointer; red and full when it
/// asks to be sure.
fn action(c: *ui.Context, k: theme.Colors, icon: ?icons.Name, label: []const u8, asking: bool) bool {
    var b = ui.div(c).row().px(10).py(6).gap(6).itemsCenter().rounded(8).hover(k.ink(0.06));
    const hot = b.hovered();
    b = b.opacity(if (hot or asking) 1 else 0.7);
    defer b.end();
    if (icon) |i| icons.icon(c, i, 14, k.muted, 0);
    ui.text(c, label, set.st(c, 12, .{ .color = if (hot) k.text else if (asking) k.danger else k.muted }));
    return b.clicked();
}

const testing = std.testing;

test "presence, last seen, the subtitle and the id chip as the GPUI app's" {
    try testing.expect(online(1_000_000, 1_000_000 + 70_000));
    try testing.expect(!online(1_000_000, 1_000_000 + 71_000));
    try testing.expect(!online(0, 5));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("never seen", lastSeen(&buf, 0, 1));
    try testing.expectEqualStrings("just now", lastSeen(&buf, 1000, 30_000));
    try testing.expectEqualStrings("5m ago", lastSeen(&buf, 0 + 1, 5 * 60_000 + 1));
    try testing.expectEqualStrings("2d ago", lastSeen(&buf, 1, 2 * 86_400_000 + 1));
    try testing.expectEqualStrings("Manage device details stored in this local workspace.", subtitle(.local));
    try testing.expectEqualStrings("macOS", platformLabel("darwin"));
    try testing.expectEqualStrings("plan9", platformLabel("plan9"));
    try testing.expectEqualStrings("abcdefgh…wxyz", shortId(&buf, "abcdefgh12345678wxyz"));
    try testing.expectEqualStrings("short", shortId(&buf, "short"));
}
