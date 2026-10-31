//! The account badge at the sidebar's foot and its menu, as the GPUI app's
//! (shell.rs `render_user_menu`, `account_menu_action`;
//! shell/codegraff_account.rs): who this is, the Codegraff sign-in, the
//! workspace's sync action, and Settings. What it shows comes from the
//! engine: its workspace scope (`EngineInfo`), the Harness account
//! (`AuthStatus`, a stream) and the Codegraff sign-in
//! (`CodegraffAuthStatus`, asked when the menu opens).
const std = @import("std");
const nanoui = @import("nanoui");
const json = std.json;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

/// Where this engine's work lives (`WorkspaceScope`).
pub const Scope = enum { local, synced, development };

/// A signed-in person's name and email (owned).
pub const User = struct {
    name: ?[]u8 = null,
    email: []u8 = &.{},

    fn deinit(u: *User, gpa: Allocator) void {
        if (u.name) |n| gpa.free(n);
        gpa.free(u.email);
    }
};

/// The Codegraff sign-in (`CodegraffStatus`); `who` owned.
pub const Codegraff = struct {
    signed_in: bool = false,
    pending: bool = false,
    who: ?[]u8 = null,
};

pub const Account = struct {
    scope: ?Scope = null,
    user: ?User = null,
    codegraff: Codegraff = .{},
    w_auth: ?u64 = null,
    /// While a browser sign-in is pending: when to ask again, and when to
    /// stop asking (`POLL_EVERY`, `POLL_FOR`).
    poll_at: ?f64 = null,
    poll_until: f64 = 0,

    pub fn deinit(acc: *Account, gpa: Allocator) void {
        if (acc.user) |*u| u.deinit(gpa);
        if (acc.codegraff.who) |w| gpa.free(w);
    }
};

const poll_every = 1.5;
const poll_for = 600.0;

/// The row under the identity line for the Codegraff sign-in.
pub const CodegraffRow = union(enum) {
    /// "Codegraff · who", its globe in the accent: opens Settings › Agents.
    account: []const u8,
    /// "Waiting for browser… (click to reopen)", dimmed.
    pending,
    /// "Sign in with Codegraff".
    sign_in,
};

/// The workspace's own action row (`AccountMenuAction`), with no sync flow
/// under way.
pub const Action = enum { enable_sync, sign_out };

pub const Menu = struct {
    /// The badge's line: its first letter is the badge's.
    line: []const u8,
    /// The menu's first line, muted.
    identity: []const u8,
    codegraff: CodegraffRow,
    action: ?Action,
};

/// What the badge and its menu say (`user_line`, `menu_identity`,
/// `account_menu_action` with the sync flow idle).
pub fn menu(scope: ?Scope, user: ?User, cg: Codegraff) Menu {
    const row: CodegraffRow = if (cg.signed_in) .{ .account = cg.who orelse "Signed in" } else if (cg.pending) .pending else .sign_in;
    return switch (scope orelse .synced) {
        .local => .{ .line = "Local only", .identity = "Stored on this device", .codegraff = row, .action = .enable_sync },
        .development => .{ .line = "Development", .identity = "Authentication disabled", .codegraff = row, .action = null },
        .synced => blk: {
            const line: []const u8 = if (user) |u| (u.name orelse u.email) else "Not signed in";
            break :blk .{
                .line = line,
                .identity = if (user) |u| u.email else line,
                .codegraff = row,
                // A runtime that isn't known yet offers nothing.
                .action = if (scope == null) null else .sign_out,
            };
        },
    };
}

/// The badge's letter: the line's first, upper case (`initial`).
pub fn initial(line: []const u8) u8 {
    const t = std.mem.trim(u8, line, " ");
    return if (t.len == 0) '?' else std.ascii.toUpper(t[0]);
}

pub fn readScope(info: json.ObjectMap) ?Scope {
    const v = info.get("workspaceScope") orelse return null;
    return if (v == .string) std.meta.stringToEnum(Scope, v.string) else null;
}

/// `CodegraffAuthStatus`'s reply.
pub fn readCodegraff(gpa: Allocator, v: json.Value) !Codegraff {
    if (v != .object) return .{};
    const o = v.object;
    const who = str(o, "email") orelse str(o, "name");
    return .{
        .signed_in = flag(o, "signedIn"),
        .pending = flag(o, "pending"),
        .who = if (who) |w| try gpa.dupe(u8, w) else null,
    };
}

/// An `AuthStatus` item: the user when signed in (or choosing an
/// organization), else none.
pub fn readUser(gpa: Allocator, v: json.Value) !?User {
    if (v != .object) return null;
    const state = str(v.object, "state") orelse return null;
    if (std.mem.eql(u8, state, "signedOut")) return null;
    const u = v.object.get("user") orelse return null;
    if (u != .object) return null;
    var out: User = .{ .email = try gpa.dupe(u8, str(u.object, "email") orelse "") };
    errdefer out.deinit(gpa);
    if (str(u.object, "name")) |n| out.name = try gpa.dupe(u8, n);
    return out;
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn flag(o: json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

/// On connect: the Harness account, watched.
pub fn watch(a: *App) void {
    if (a.account.w_auth != null) return;
    a.account.w_auth = a.send_(requests.none("AuthStatus"), .of(App, a, onAuth));
}

fn onAuth(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .item => |v| {
            const user = readUser(a.gpa, v) catch return;
            if (a.account.user) |*u| u.deinit(a.gpa);
            a.account.user = user;
        },
        .done, .err => a.account.w_auth = null,
        .ok => {},
    }
    a.redraw();
}

/// The menu opened: the Codegraff sign-in asked again
/// (`refresh_codegraff_status`).
pub fn refresh(a: *App) void {
    a.request(requests.none("CodegraffAuthStatus"), .of(App, a, onCodegraff));
}

fn onCodegraff(a: *App, _: u64, r: rpc.Reply) void {
    const v = switch (r) {
        .ok => |v| v,
        else => return,
    };
    const got = readCodegraff(a.gpa, v) catch return;
    var acc = &a.account;
    if (acc.codegraff.who) |w| a.gpa.free(w);
    // A browser sign-in stays pending here until the engine says it's done.
    const pending = acc.poll_at != null and !got.signed_in;
    acc.codegraff = got;
    if (pending) acc.codegraff.pending = true;
    // A sign-in just finished: the account may already have a sandbox
    // running.
    if (got.signed_in and !got.pending and acc.poll_at != null) @import("app_sandboxes.zig").refresh(a);
    if (got.signed_in) acc.poll_at = null;
    a.redraw();
}

/// "Sign in with Codegraff": the engine starts it, the browser finishes it,
/// and the menu asks until it's done (`codegraff_sign_in`).
pub fn signIn(a: *App) void {
    a.view.account_menu = false;
    a.request(requests.none("CodegraffSignIn"), .of(App, a, onSignIn));
}

fn onSignIn(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| {
            const url = if (v == .object) str(v.object, "url") else null;
            _ = nanoui.shell.openUrl(url orelse return);
            a.account.codegraff.pending = true;
            a.account.poll_at = a.now + poll_every;
            a.account.poll_until = a.now + poll_for;
        },
        .err => |e| {
            var buf: [200]u8 = undefined;
            a.setNotice(std.fmt.bufPrint(&buf, "Codegraff sign-in: {s}", .{e}) catch e);
        },
        else => {},
    }
    a.redraw();
}

/// From the app's tick: asks again while a sign-in is pending. When next.
pub fn tick(a: *App, now: f64) ?f64 {
    const at = a.account.poll_at orelse return null;
    if (now >= a.account.poll_until) {
        a.account.poll_at = null;
        a.account.codegraff.pending = false;
        return null;
    }
    if (now < at) return at;
    a.account.poll_at = now + poll_every;
    refresh(a);
    return a.account.poll_at;
}

const testing = std.testing;

test "the menu as the GPUI app's for each workspace scope" {
    const local = menu(.local, null, .{});
    try testing.expectEqualStrings("Local only", local.line);
    try testing.expectEqualStrings("Stored on this device", local.identity);
    try testing.expectEqual(@as(?Action, .enable_sync), local.action);
    try testing.expect(local.codegraff == .sign_in);
    try testing.expectEqual(@as(u8, 'L'), initial(local.line));

    var email = "ada@example.com".*;
    var name = "Ada".*;
    const synced = menu(.synced, .{ .name = &name, .email = &email }, .{ .signed_in = true, .who = &email });
    try testing.expectEqualStrings("Ada", synced.line);
    try testing.expectEqualStrings("ada@example.com", synced.identity);
    try testing.expectEqual(@as(?Action, .sign_out), synced.action);
    try testing.expectEqualStrings("ada@example.com", synced.codegraff.account);

    const dev = menu(.development, null, .{ .pending = true });
    try testing.expectEqualStrings("Authentication disabled", dev.identity);
    try testing.expectEqual(@as(?Action, null), dev.action);
    try testing.expect(dev.codegraff == .pending);

    const unknown = menu(null, null, .{});
    try testing.expectEqualStrings("Not signed in", unknown.line);
    try testing.expectEqual(@as(?Action, null), unknown.action);
    try testing.expectEqual(@as(u8, '?'), initial("  "));
}

test "the engine's replies: scope, Codegraff status, the Harness account" {
    const info = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"deviceId":"d","workspaceScope":"development"}
    , .{});
    defer info.deinit();
    try testing.expectEqual(@as(?Scope, .development), readScope(info.value.object));

    const st = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"configured":true,"signedIn":true,"name":"Ada","pending":false}
    , .{});
    defer st.deinit();
    const cg = try readCodegraff(testing.allocator, st.value);
    defer testing.allocator.free(cg.who.?);
    try testing.expect(cg.signed_in);
    try testing.expectEqualStrings("Ada", cg.who.?);

    const auth = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"state":"signedIn","user":{"id":"u","email":"ada@example.com","name":null},"orgId":null}
    , .{});
    defer auth.deinit();
    var u = (try readUser(testing.allocator, auth.value)).?;
    defer u.deinit(testing.allocator);
    try testing.expectEqualStrings("ada@example.com", u.email);
    try testing.expect(u.name == null);

    const out = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"state":"signedOut"}
    , .{});
    defer out.deinit();
    try testing.expect((try readUser(testing.allocator, out.value)) == null);
}
