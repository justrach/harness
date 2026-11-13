//! Settings › Accounts › browse (settings/browse_link.rs): connect Harness
//! to the user's browse so agents browse with their sign-ins (the engine's
//! `BrowseLinkStatus`, `BrowseLinkPair`, `BrowseLinkDisconnect`). Pairing
//! shows six digits browse also shows; the user confirms there and picks
//! what Harness may do. On macOS, for this device only: browse pairs with
//! the engine on the Mac it runs on.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const rpc = @import("rpc.zig");
const rows = @import("view_settings_accounts_rows.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const poll_every_s: f64 = 1;

/// `BrowseLinkStatus`, its strings owned.
pub const Status = struct {
    browse_running: bool = false,
    paired: bool = false,
    scopes: [][]u8 = &.{},
    pairing_code: ?[]u8 = null,
    key_mismatch: bool = false,
    err: ?[]u8 = null,

    fn deinit(s: *Status, gpa: Allocator) void {
        for (s.scopes) |x| gpa.free(x);
        gpa.free(s.scopes);
        if (s.pairing_code) |x| gpa.free(x);
        if (s.err) |x| gpa.free(x);
        s.* = .{};
    }

    pub fn parse(gpa: Allocator, v: json.Value) !Status {
        if (v != .object) return .{};
        const o = v.object;
        var s: Status = .{
            .browse_running = flag(o, "browseRunning"),
            .paired = flag(o, "paired"),
            .key_mismatch = flag(o, "keyMismatch"),
        };
        errdefer s.deinit(gpa);
        if (text(o, "pairingCode")) |t| s.pairing_code = try gpa.dupe(u8, t);
        if (text(o, "error")) |t| s.err = try gpa.dupe(u8, t);
        if (o.get("scopes")) |list| if (list == .array) {
            var out: std.ArrayList([]u8) = .empty;
            errdefer {
                for (out.items) |x| gpa.free(x);
                out.deinit(gpa);
            }
            for (list.array.items) |x| if (x == .string) try out.append(gpa, try gpa.dupe(u8, x.string));
            s.scopes = try out.toOwnedSlice(gpa);
        };
        return s;
    }
};

fn flag(o: json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

fn text(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// What each browse scope lets agents do, in the card's words (`scope_label`).
pub fn scopeLabel(scope: []const u8) []const u8 {
    const pairs = .{ .{ "read", "Search and read" }, .{ "act-own-pages", "Act in its own pages" }, .{ "act-user-tabs", "Use your tabs" }, .{ "run-js", "Run scripts" } };
    inline for (pairs) |p| if (std.mem.eql(u8, scope, p[0])) return p[1];
    return scope;
}

/// "123456" → "123 456" (`spaced_code`).
pub fn spacedCode(buf: []u8, code: []const u8) []const u8 {
    if (code.len != 6) return code;
    return std.fmt.bufPrint(buf, "{s} {s}", .{ code[0..3], code[3..] }) catch code;
}

test "codes and scopes read well (codes_and_scopes_read_well)" {
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("012 345", spacedCode(&b, "012345"));
    try std.testing.expectEqualStrings("12", spacedCode(&b, "12"));
    try std.testing.expectEqualStrings("Use your tabs", scopeLabel("act-user-tabs"));
    try std.testing.expectEqualStrings("other", scopeLabel("other"));
}

test "a status reads its fields, and nothing from a non-object" {
    const gpa = std.testing.allocator;
    const p = try json.parseFromSlice(json.Value, gpa, "{\"paired\":true,\"browseRunning\":true,\"scopes\":[\"read\",\"run-js\"],\"error\":\"x\"}", .{});
    defer p.deinit();
    var s = try Status.parse(gpa, p.value);
    defer s.deinit(gpa);
    try std.testing.expect(s.paired and s.browse_running and !s.key_mismatch);
    try std.testing.expectEqual(@as(usize, 2), s.scopes.len);
    try std.testing.expectEqualStrings("x", s.err.?);
    var none = try Status.parse(gpa, .null);
    defer none.deinit(gpa);
    try std.testing.expect(!none.paired and none.pairing_code == null);
}

pub const State = struct {
    status: ?Status = null,
    busy: bool = false,
    err: ?[]u8 = null,
    started: bool = false,
    call: ?u64 = null,
    poll_at: ?f64 = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.status) |*x| x.deinit(gpa);
        if (s.err) |x| gpa.free(x);
    }
};

/// Shown on macOS, for this device's logins (`show_browse`).
pub fn shown(a: *const App) bool {
    return builtin.os.tag == .macos and a.view.accounts.target == null;
}

fn state(a: *App) *State {
    return &a.view.accounts.browse;
}

/// Ask for the status again; it keeps polling while a code is up.
pub fn refresh(a: *App) void {
    const s = state(a);
    s.started = true;
    if (!a.engine.up()) return;
    s.call = a.engine.call("BrowseLinkStatus", .{}, .of(App, a, onStatus));
}

fn onStatus(a: *App, id: u64, r: rpc.Reply) void {
    const s = state(a);
    if (s.call != id) return;
    s.call = null;
    switch (r) {
        .ok => |v| if (Status.parse(a.gpa, v)) |next| {
            if (s.status) |*old| old.deinit(a.gpa);
            s.status = next;
            s.poll_at = if (next.pairing_code != null) a.now + poll_every_s else null;
        } else |_| {},
        // A failed status reads as no status, as GPUI's `.ok()`.
        .err => s.poll_at = null,
        else => {},
    }
    a.redraw();
}

fn connect(a: *App) void {
    const s = state(a);
    if (s.busy or !a.engine.up()) return;
    s.busy = true;
    setErr(a, null);
    _ = a.engine.call("BrowseLinkPair", .{}, .of(App, a, onPaired));
}

fn onPaired(a: *App, _: u64, r: rpc.Reply) void {
    const s = state(a);
    switch (r) {
        .ok => {},
        .err => |e| setErr(a, e),
        else => return,
    }
    s.busy = false;
    refresh(a);
    a.redraw();
}

fn disconnect(a: *App) void {
    if (!a.engine.up()) return;
    setErr(a, null);
    _ = a.engine.call("BrowseLinkDisconnect", .{}, .of(App, a, onDisconnected));
}

fn onDisconnected(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok, .err => refresh(a),
        else => {},
    }
}

fn setErr(a: *App, e: ?[]const u8) void {
    const s = state(a);
    if (s.err) |old| a.gpa.free(old);
    s.err = if (e) |t| a.gpa.dupe(u8, t) catch null else null;
}

/// The section: "browse" with its globe, 24 under what's above, and its
/// card 8 under that.
pub fn card(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = state(a);
    if (!s.started) refresh(a);
    if (s.poll_at) |t| {
        if (a.now >= t) {
            s.poll_at = null;
            refresh(a);
        } else c.frameIn(@floatCast(t - a.now));
    }
    @import("view_settings.zig").space(c, 24);
    {
        const h = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer h.end();
        rows.sectionHead(c, k, .globe, null, "browse");
    }
    const cd = rows.card(c, k, 8);
    defer cd.end();
    const body = ui.div(c).column().wFull().px(20).py(14).gap(10);
    defer body.end();
    const status: Status = s.status orelse .{};
    if (status.pairing_code) |code| {
        var buf: [8]u8 = undefined;
        ui.text(c, c.print("{s}", .{spacedCode(&buf, code)}), rows.st(c, 26, .{ .weight = .semibold, .color = k.text }));
        note(c, k, "Check that browse shows the same code, then allow Harness there and choose what it may do.");
        if (rows.ghost(c, k, .{ .label = "Cancel" })) disconnect(a);
    } else if (status.paired) {
        {
            const badges = ui.div(c).row().gap(6).itemsCenter();
            defer badges.end();
            rows.badgeActive(c, k, "Connected");
            for (status.scopes) |scope| rows.badge(c, k, scopeLabel(scope));
        }
        note(c, k, if (status.key_mismatch)
            "A different browse is running than the one Harness connected to. Disconnect and connect again."
        else if (status.browse_running)
            "New agent runs get browse's tools, with your sign-ins. Each run has its own pages, closed when it ends."
        else
            "browse isn't running with Connected apps on, so agents use Harness's own browser for now.");
        note(c, k, "Change what Harness may do, or revoke it, in browse \u{203a} Settings \u{203a} Agent \u{203a} Connected apps.");
        if (rows.ghost(c, k, .{ .label = "Disconnect" })) disconnect(a);
    } else if (status.browse_running) {
        note(c, k, "Let agents use browse, with your sign-ins. You'll confirm a code in browse and choose what Harness may do.");
        if (rows.ghost(c, k, .{ .label = if (s.busy) "Connecting\u{2026}" else "Connect" }) and !s.busy) connect(a);
    } else {
        note(c, k, "Open browse and turn on Settings \u{203a} Agent \u{203a} Connected apps to let agents use it with your sign-ins.");
        if (rows.ghost(c, k, .{ .label = "Check again" })) refresh(a);
    }
    const e = s.err orelse status.err;
    if (e) |msg| _ = rows.errorStrip(c, k, msg, false);
}

/// A muted line at 12 on 18 (`note`), wrapped to the card.
fn note(c: *ui.Context, k: theme.Colors, words: []const u8) void {
    const w = ui.div(c).column().w(rows.rowInner());
    defer w.end();
    var style = rows.st(c, 12, .{ .wrap = true, .color = k.muted });
    style.line_height = 18;
    ui.text(c, words, style);
}
