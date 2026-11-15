//! The account badge at the sidebar's foot and its menu, as the GPUI app's
//! (shell.rs `render_user_menu`, `account_menu_action`;
//! shell/codegraff_account.rs): who this is, the Codegraff sign-in, the
//! workspace's sync action, and Settings. What it shows comes from the
//! engine: its workspace scope (`EngineInfo`), the Harness account
//! (`AuthStatus`, a stream) and the Codegraff sign-in
//! (`CodegraffAuthStatus`, asked when the menu opens).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const json = std.json;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

/// Where this engine's work lives (`WorkspaceScope`).
pub const Scope = enum { local, synced, development };

/// Server-assigned / canonical Harness member card traits (value type; no heap fields).
pub const WireCardTraits = struct {
    scene: u32,
    sky: u32,
    enso: u32,
    holo: u32,
    seal: u32,
};

/// A signed-in person's identity & Harness member card fields (owned).
pub const User = struct {
    id: []u8 = &.{},
    name: ?[]u8 = null,
    email: []u8 = &.{},
    avatar_url: ?[]u8 = null,
    member_number: ?u64 = null,
    started_at: ?i64 = null,
    card_scenes: ?u32 = null,
    card_traits: ?WireCardTraits = null,

    pub fn deinit(u: *User, gpa: Allocator) void {
        if (u.id.len > 0) gpa.free(u.id);
        if (u.name) |n| gpa.free(n);
        if (u.email.len > 0) gpa.free(u.email);
        if (u.avatar_url) |url| gpa.free(url);
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
    /// The engine's rejected-refresh marker, not a provider login failure or
    /// an ordinary signed-out state. Kept on the account, across navigation.
    lost_session: bool = false,
    auth_signed_out: bool = false,
    lost_check_at: ?f64 = null,
    /// While a browser sign-in is pending: when to ask again, and when to
    /// stop asking (`POLL_EVERY`, `POLL_FOR`).
    poll_at: ?f64 = null,
    poll_until: f64 = 0,
    avatar_lock: std.atomic.Value(bool) = .init(false),
    avatar_bytes: ?[]u8 = null,
    avatar_url_loaded: ?[]u8 = null,
    avatar_pending_bytes: ?[]u8 = null,
    avatar_pending_url: ?[]u8 = null,
    avatar_fetching: bool = false,

    pub fn deinit(acc: *Account, gpa: Allocator) void {
        if (acc.user) |*u| u.deinit(gpa);
        if (acc.codegraff.who) |w| gpa.free(w);
        if (acc.avatar_bytes) |b| gpa.free(b);
        if (acc.avatar_url_loaded) |u| gpa.free(u);
        if (acc.avatar_pending_bytes) |b| gpa.free(b);
        if (acc.avatar_pending_url) |u| gpa.free(u);
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
    /// The signed-in person's full name, when the engine knows one.
    name: ?[]const u8,
    /// The menu's identity line: the email, or where the workspace lives.
    identity: []const u8,
    codegraff: CodegraffRow,
    action: ?Action,
};

/// What the badge and its menu say (`user_line`, `menu_identity`,
/// `account_menu_action` with the sync flow idle).
pub fn menu(scope: ?Scope, user: ?User, cg: Codegraff) Menu {
    const row: CodegraffRow = if (cg.signed_in) .{ .account = cg.who orelse "Signed in" } else if (cg.pending) .pending else .sign_in;
    const name: ?[]const u8 = if (user) |u| u.name orelse u.email else null;
    return switch (scope orelse .synced) {
        .local => .{ .line = "Local only", .name = name, .identity = "Stored on this device", .codegraff = row, .action = .enable_sync },
        .development => .{ .line = "Development", .name = name, .identity = "Authentication disabled", .codegraff = row, .action = null },
        .synced => blk: {
            const line: []const u8 = name orelse "Not signed in";
            break :blk .{
                .line = line,
                .name = name,
                .identity = if (user) |u| u.email else line,
                .codegraff = row,
                // A runtime that isn't known yet offers nothing.
                .action = if (scope == null) null else .sign_out,
            };
        },
    };
}

/// The account row's second line (`account_subtitle`): where the
/// workspace lives, else whether it syncs.
pub fn subtitle(scope: ?Scope, signed_in: bool) []const u8 {
    if (scope) |s| switch (s) {
        .local => return "This device",
        .development => return "Development build",
        .synced => {},
    };
    return if (signed_in) "CodeGraff account" else "Sign in to sync";
}

test "the account row says where the workspace lives (account_subtitle)" {
    try std.testing.expectEqualStrings("This device", subtitle(.local, true));
    try std.testing.expectEqualStrings("Development build", subtitle(.development, false));
    try std.testing.expectEqualStrings("CodeGraff account", subtitle(.synced, true));
    try std.testing.expectEqualStrings("Sign in to sync", subtitle(null, false));
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

fn intVal(o: json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(f) else null,
        else => null,
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
    var out: User = .{
        .id = if (str(u.object, "id")) |id_s| try gpa.dupe(u8, id_s) else &.{},
        .email = if (str(u.object, "email")) |em| try gpa.dupe(u8, em) else &.{},
    };
    errdefer out.deinit(gpa);
    if (str(u.object, "name")) |n| if (n.len > 0) {
        out.name = try gpa.dupe(u8, n);
    };
    if (str(u.object, "avatarUrl")) |url| if (url.len > 0) {
        out.avatar_url = try gpa.dupe(u8, url);
    };
    if (intVal(u.object, "memberNumber")) |n| if (n > 0) {
        out.member_number = @intCast(n);
    };
    if (intVal(u.object, "startedAt")) |s| if (s > 0) {
        out.started_at = s;
    };
    if (intVal(u.object, "cardScenes")) |cs| if (cs > 0) {
        out.card_scenes = @intCast(@min(cs, 256));
    };
    if (u.object.get("cardTraits")) |ct_val| if (ct_val == .object) {
        const ct = ct_val.object;
        if (intVal(ct, "scene")) |sc| if (intVal(ct, "sky")) |sk| if (intVal(ct, "enso")) |en| if (intVal(ct, "holo")) |ho| if (intVal(ct, "seal")) |se| {
            if (sc >= 0 and sk >= 0 and en >= 0 and ho >= 0 and se >= 0) {
                out.card_traits = .{
                    .scene = @intCast(@min(sc, 255)),
                    .sky = @intCast(@min(sk, 255)),
                    .enso = @intCast(@min(en, 255)),
                    .holo = @intCast(@min(ho, 255)),
                    .seal = @intCast(@min(se, 255)),
                };
            }
        };
    };
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
            a.external_navigation.authChanged(v);
            const recovered = a.account.lost_session and user != null;
            if (a.account.user) |*u| u.deinit(a.gpa);
            a.account.user = user;
            if (user == null) clearAvatar(&a.account, a.gpa) else maybeFetchAvatar(a);
            if (recovered) a.account.scope = .synced;
            a.account.auth_signed_out = v == .object and std.mem.eql(u8, str(v.object, "state") orelse "", "signedOut");
            refreshLostSession(a);
            // The auth stream can publish SignedOut just before the engine
            // writes its marker. Check once more after that transition settles.
            a.account.lost_check_at = if (a.account.auth_signed_out) a.now + 0.25 else null;
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

/// "Enable sync": starts workspace sync sign-in (`SignIn`) and refreshes
/// `EngineInfo` / `AuthStatus`.
pub fn enableSync(a: *App) void {
    a.view.account_menu = false;
    a.request(requests.none("SignIn"), .of(App, a, onEnableSync));
}

fn onEnableSync(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| {
            // Opening the browser is not yet a recovered session. Keep the
            // marker's local-workspace explanation until AuthStatus signs in.
            if (!a.account.lost_session) a.account.scope = .synced;
            if (v == .object) {
                if (str(v.object, "url")) |url| {
                    if (url.len > 0) _ = nanoui.shell.openUrl(url);
                }
            }
            if (a.account.w_auth) |w| {
                a.engine.cancel(w);
                a.account.w_auth = null;
            }
            watch(a);
            refresh(a);
        },
        .err => |e| {
            var buf: [200]u8 = undefined;
            a.setNotice(std.fmt.bufPrint(&buf, "Enable sync: {s}", .{e}) catch e);
        },
        else => {},
    }
    a.redraw();
}

/// "Sign out": signs out of workspace sync (`SignOut`).
pub fn signOut(a: *App) void {
    a.view.account_menu = false;
    a.request(requests.none("SignOut"), .of(App, a, onSignOut));
}

fn onSignOut(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => {
            if (a.account.user) |*u| u.deinit(a.gpa);
            a.account.user = null;
            clearAvatar(&a.account, a.gpa);
            a.account.scope = .local;
            a.account.lost_session = false;
            a.account.lost_check_at = null;
            refresh(a);
        },
        .err => |e| {
            var buf: [200]u8 = undefined;
            a.setNotice(std.fmt.bufPrint(&buf, "Sign out: {s}", .{e}) catch e);
        },
        else => {},
    }
    a.redraw();
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
    var next = a.account.lost_check_at;
    if (next) |at| if (now >= at) {
        refreshLostSession(a);
        a.account.lost_check_at = null;
        next = null;
    };
    const at = a.account.poll_at orelse return next;
    if (now >= a.account.poll_until) {
        a.account.poll_at = null;
        a.account.codegraff.pending = false;
        return next;
    }
    if (now < at) return if (next) |n| @min(n, at) else at;
    a.account.poll_at = now + poll_every;
    refresh(a);
    return if (next) |n| @min(n, a.account.poll_at.?) else a.account.poll_at;
}

fn lostSessionPath(a: *const App, buf: []u8) ?[]const u8 {
    const dir = a.settings.dataDir() orelse blk: {
        if (a.env) |env| if (env.get("HARNESS_DATA_DIR")) |dir| if (dir.len > 0) break :blk dir;
        return null;
    };
    return std.fmt.bufPrint(buf, "{s}/signed-out.notice", .{dir}) catch null;
}

fn refreshLostSession(a: *App) void {
    const previous = a.account.lost_session;
    defer if (previous != a.account.lost_session) a.redraw();
    a.account.lost_session = false;
    if (!a.account.auth_signed_out) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = lostSessionPath(a, &buf) orelse return;
    std.Io.Dir.cwd().access(a.io, path, .{}) catch return;
    a.account.lost_session = true;
}

/// Match the original strip: only the local fallback workspace, after a
/// rejected refresh, explains why the synced account's sessions aren't here.
pub fn showLostSession(a: *const App) bool {
    return a.account.scope == .local and a.account.user == null and a.account.lost_session;
}

pub fn dismissLostSession(a: *App) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (lostSessionPath(a, &buf)) |path| {
        std.Io.Dir.cwd().deleteFile(a.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                a.setNotice("Couldn't dismiss the signed-out notice. Try again.");
                return;
            },
        };
    }
    a.account.lost_session = false;
    a.account.lost_check_at = null;
    a.redraw();
}

const testing = std.testing;

pub const lost_session_copy = "You've been signed out. Sign back in to sync your sessions.";

test "lost Harness session notice survives a local restart and uses workspace sign-in" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "signed-out.notice", .data = "synthetic rejection" });
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(base);
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.settings.path = try std.fs.path.join(testing.allocator, &.{ base, "nano-ui-settings.json" });
    a.account.scope = .local;
    const auth = try json.parseFromSlice(json.Value, testing.allocator, "{\"state\":\"signedOut\"}", .{});
    defer auth.deinit();
    onAuth(&a, 1, .{ .item = auth.value });
    @import("theme.zig").registerFonts();
    const Screen = struct {
        fn view(app: *App, c: *nanoui.ui.Context) void {
            @import("view_settings_accounts.zig").page(c, app, @import("theme.zig").colors(true));
        }
    };
    var t: nanoui.ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, Screen.view), .{ .width = 950, .height = 850 });
    defer t.deinit();
    t.settle(0.2);
    try testing.expect(t.hasText(lost_session_copy));
    // The recovery is the Harness workspace's SignIn, never a provider's
    // CodegraffSignIn or graff reauthentication flow.
    a.engine.scene = try json.parseFromSlice(json.Value, testing.allocator, "{\"SignIn\":{}}", .{});
    try t.clickText(lost_session_copy);
    t.settle(0.1);
    try testing.expect(a.engine.sent.items.len > 0);
    const sent = try json.parseFromSlice(json.Value, testing.allocator, a.engine.sent.items[a.engine.sent.items.len - 1], .{});
    defer sent.deinit();
    try testing.expectEqualStrings("SignIn", sent.value.object.get("method").?.string);
    try t.clickText("×");
    t.settle(0.1);
    try testing.expect(!t.hasText(lost_session_copy));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "signed-out.notice", .{}));
    onAuth(&a, 1, .{ .item = auth.value });
    try testing.expect(!showLostSession(&a));
}

test "lost Harness session notice follows the real marker and synthetic auth transitions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(base);
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.settings.path = try std.fs.path.join(testing.allocator, &.{ base, "nano-ui-settings.json" });
    a.account.scope = .local;
    const out = try json.parseFromSlice(json.Value, testing.allocator, "{\"state\":\"signedOut\"}", .{});
    defer out.deinit();
    const signed = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"state":"signedIn","user":{"id":"synthetic","email":"synthetic@example.invalid"}}
    , .{});
    defer signed.deinit();
    // No marker: a normal signed-out account is not an expired session.
    onAuth(&a, 1, .{ .item = out.value });
    try testing.expect(!showLostSession(&a));
    // A rejected refresh publishes SignedOut immediately before its marker.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "signed-out.notice", .data = "synthetic rejection" });
    _ = tick(&a, a.now + 0.3);
    try testing.expect(showLostSession(&a));
    try testing.expect(a.account.lost_check_at == null); // no indefinite idle polling
    onEnableSync(&a, 2, .{ .ok = .null });
    try testing.expect(showLostSession(&a)); // browser acceptance is not sign-in
    a.account.scope = .synced;
    try testing.expect(!showLostSession(&a)); // don't claim local sessions vanished while synced
    a.account.scope = .local;
    try testing.expect(showLostSession(&a));
    // A successful account transition clears the UI even if its marker
    // deletion hasn't been observed yet. Backend auth tests prove removal.
    onAuth(&a, 1, .{ .item = signed.value });
    try testing.expect(!showLostSession(&a));
    try testing.expectEqual(@as(?Scope, .synced), a.account.scope);
    try testing.expect(a.account.lost_check_at == null);
    try tmp.dir.deleteFile(testing.io, "signed-out.notice");
    onAuth(&a, 1, .{ .item = out.value });
    try testing.expect(!showLostSession(&a));
    // Explicit SignOut, not forced loss, also stays quiet.
    onSignOut(&a, 2, .{ .ok = .null });
    try testing.expect(!showLostSession(&a));
    // Provider status is independent of Harness account loss.
    a.account.codegraff.signed_in = false;
    a.account.codegraff.pending = true;
    try testing.expect(!showLostSession(&a));
}

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
    try testing.expectEqualStrings("Ada", synced.name.?);
    try testing.expectEqualStrings("ada@example.com", synced.identity);
    const local_user = menu(.local, .{ .name = &name, .email = &email }, .{});
    try testing.expectEqualStrings("Local only", local_user.line);
    try testing.expectEqualStrings("Ada", local_user.name.?);
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

    const rich = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"state":"signedIn","user":{"id":"42","email":"ada@example.com","name":"Ada Lovelace","avatarUrl":"https://cdn.example.com/a.png","memberNumber":42,"startedAt":1700000000,"cardScenes":12},"orgId":"org_42"}
    , .{});
    defer rich.deinit();
    var ru = (try readUser(testing.allocator, rich.value)).?;
    defer ru.deinit(testing.allocator);
    try testing.expectEqualStrings("42", ru.id);
    try testing.expectEqualStrings("Ada Lovelace", ru.name.?);
    try testing.expectEqualStrings("https://cdn.example.com/a.png", ru.avatar_url.?);
    try testing.expectEqual(@as(?u64, 42), ru.member_number);
    try testing.expectEqual(@as(?i64, 1700000000), ru.started_at);
    try testing.expectEqual(@as(?u32, 12), ru.card_scenes);
    try testing.expectEqual(@as(?WireCardTraits, null), ru.card_traits);
}

test "readUser decodes optional cardTraits object" {
    const raw =
        \\{"state":"signedIn","user":{"id":"u1","email":"alex@example.com","memberNumber":42,"cardScenes":20,"cardTraits":{"scene":13,"sky":9,"enso":1,"holo":3,"seal":2}},"orgId":null}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, raw, .{});
    defer parsed.deinit();
    var ru = (try readUser(testing.allocator, parsed.value)).?;
    defer ru.deinit(testing.allocator);
    try testing.expectEqual(@as(?u64, 42), ru.member_number);
    try testing.expectEqual(@as(?u32, 20), ru.card_scenes);
    try testing.expect(ru.card_traits != null);
    const ct = ru.card_traits.?;
    try testing.expectEqual(@as(u32, 13), ct.scene);
    try testing.expectEqual(@as(u32, 9), ct.sky);
    try testing.expectEqual(@as(u32, 1), ct.enso);
    try testing.expectEqual(@as(u32, 3), ct.holo);
    try testing.expectEqual(@as(u32, 2), ct.seal);
}

fn lockAvatar(acc: *Account) void {
    while (acc.avatar_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockAvatar(acc: *Account) void {
    acc.avatar_lock.store(false, .release);
}

fn clearAvatar(acc: *Account, gpa: Allocator) void {
    if (acc.avatar_bytes) |b| gpa.free(b);
    acc.avatar_bytes = null;
    if (acc.avatar_url_loaded) |u| gpa.free(u);
    acc.avatar_url_loaded = null;
    lockAvatar(acc);
    if (acc.avatar_pending_bytes) |b| gpa.free(b);
    acc.avatar_pending_bytes = null;
    if (acc.avatar_pending_url) |u| gpa.free(u);
    acc.avatar_pending_url = null;
    acc.avatar_fetching = false;
    unlockAvatar(acc);
}

fn maybeFetchAvatar(a: *App) void {
    const user = a.account.user orelse return clearAvatar(&a.account, a.gpa);
    const url = user.avatar_url orelse return clearAvatar(&a.account, a.gpa);
    if (!std.mem.startsWith(u8, url, "https://")) return;
    if (a.account.avatar_url_loaded) |loaded| {
        if (std.mem.eql(u8, loaded, url)) return;
    }
    clearAvatar(&a.account, a.gpa);
    if (a.offscreen or builtin.is_test) return;
    lockAvatar(&a.account);
    if (a.account.avatar_fetching) {
        unlockAvatar(&a.account);
        return;
    }
    a.account.avatar_fetching = true;
    unlockAvatar(&a.account);
    const dup = a.gpa.dupe(u8, url) catch {
        lockAvatar(&a.account);
        a.account.avatar_fetching = false;
        unlockAvatar(&a.account);
        return;
    };
    const t = std.Thread.spawn(.{}, avatarWorker, .{ a, dup }) catch {
        a.gpa.free(dup);
        lockAvatar(&a.account);
        a.account.avatar_fetching = false;
        unlockAvatar(&a.account);
        return;
    };
    t.detach();
}

fn avatarWorker(a: *App, url: []u8) void {
    defer a.gpa.free(url);
    const res = std.process.run(a.gpa, a.io, .{
        .argv = &.{ "/usr/bin/curl", "-fsSL", "--max-time", "5", "--max-filesize", "2097152", "--", url },
        .stdout_limit = .limited(2 << 20),
        .stderr_limit = .limited(4096),
    }) catch {
        lockAvatar(&a.account);
        a.account.avatar_fetching = false;
        unlockAvatar(&a.account);
        return;
    };
    defer a.gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0 and res.stdout.len > 0,
        else => false,
    };
    if (!ok) {
        a.gpa.free(res.stdout);
        lockAvatar(&a.account);
        a.account.avatar_fetching = false;
        unlockAvatar(&a.account);
        return;
    }
    const done_url = a.gpa.dupe(u8, url) catch {
        a.gpa.free(res.stdout);
        lockAvatar(&a.account);
        a.account.avatar_fetching = false;
        unlockAvatar(&a.account);
        return;
    };
    lockAvatar(&a.account);
    if (a.account.avatar_pending_bytes) |old| a.gpa.free(old);
    if (a.account.avatar_pending_url) |old| a.gpa.free(old);
    a.account.avatar_pending_bytes = res.stdout;
    a.account.avatar_pending_url = done_url;
    a.account.avatar_fetching = false;
    unlockAvatar(&a.account);
    _ = nanoui.App.onMain(a, avatarDelivered);
}

fn avatarDelivered(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx orelse return));
    lockAvatar(&a.account);
    const bytes = a.account.avatar_pending_bytes;
    const url = a.account.avatar_pending_url;
    a.account.avatar_pending_bytes = null;
    a.account.avatar_pending_url = null;
    unlockAvatar(&a.account);
    if (bytes) |b| {
        if (a.account.avatar_bytes) |old| a.gpa.free(old);
        a.account.avatar_bytes = b;
    }
    if (url) |u| {
        if (a.account.avatar_url_loaded) |old| a.gpa.free(old);
        a.account.avatar_url_loaded = u;
    }
    a.redraw();
}
