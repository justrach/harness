//! External entry points use the preserving opener, never resume's replacing
//! route. Workspace authority matches the shipped links.rs contract exactly.
const std = @import("std");
const App = @import("app.zig").App;
const Scope = @import("app_account.zig").Scope;
const Allocator = std.mem.Allocator;
const prefix = "harness://open/chat/";
const max_component = 4096;

pub const Presenter = struct {
    ctx: *anyopaque,
    show: *const fn (*anyopaque) void,
};
const Pending = struct { chat: []u8, workspace: [16]u8 };
pub const State = struct {
    pending: ?Pending = null,
    synced: ?[16]u8 = null,
    development: ?[16]u8 = null,
    presenter: ?Presenter = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.clear(gpa);
        s.* = .{};
    }
    fn clear(s: *State, gpa: Allocator) void {
        if (s.pending) |p| gpa.free(p.chat);
        s.pending = null;
    }

    /// AuthStatus's real user ID and organization, not email/display identity.
    /// Retain only opaque digests; signed-out/needs-organization has no authority.
    pub fn authChanged(s: *State, value: std.json.Value) void {
        s.synced = null;
        s.development = null;
        if (!std.mem.eql(u8, string(value, "state") orelse return, "signedIn")) return;
        const user = if (value == .object) value.object.get("user") orelse return else return;
        const id = string(user, "id") orelse return;
        if (id.len == 0) return;
        const org_value = value.object.get("orgId");
        const org: []const u8 = if (org_value) |v| switch (v) {
            .null => "personal",
            .string => v.string,
            else => return,
        } else "personal";
        s.synced = accountLocator(.synced, id, org);
        s.development = accountLocator(.development, id, org);
    }

    pub fn locator(s: *const State, a: *const App) ?[16]u8 {
        return switch (a.account.scope orelse return null) {
            .local => localLocator(a.device_id orelse return null),
            .synced => s.synced,
            .development => s.development,
        };
    }

    pub fn conversationLink(s: *const State, buf: []u8, a: *const App, chat: []const u8) ?[]const u8 {
        const workspace = s.locator(a) orelse return null;
        return formatLink(buf, chat, &workspace);
    }

    pub fn openURL(s: *State, a: *App, url: []const u8) void {
        const link = parse(a.gpa, url) catch {
            a.setSidebarNotice("Not a valid Harness conversation link", null);
            return;
        };
        defer a.gpa.free(link.chat);
        s.openTarget(a, link.chat, &link.workspace);
    }

    /// Notification payloads carry the same opaque workspace fence as links.
    /// No App pointer or callback pointer is serialized into a notification.
    pub fn openTarget(s: *State, a: *App, chat: []const u8, workspace: []const u8) void {
        if (!validChat(chat) or !validLocator(workspace)) return;
        const owned = a.gpa.dupe(u8, chat) catch return;
        s.clear(a.gpa);
        var p: Pending = .{ .chat = owned, .workspace = undefined };
        @memcpy(&p.workspace, workspace);
        s.pending = p;
        s.settle(a);
    }

    /// Called after engine replies, before the tree. Late identity/chat frames
    /// re-evaluate the same owned target, and successful navigation consumes it.
    pub fn settle(s: *State, a: *App) void {
        const pending = s.pending orelse return;
        const current = s.locator(a) orelse return;
        if (!std.mem.eql(u8, &current, &pending.workspace)) {
            s.clear(a.gpa);
            a.setSidebarNotice("This conversation link belongs to another workspace", null);
            return;
        }
        if (a.findChat(pending.chat) == null) {
            if (a.chats_synced) {
                s.clear(a.gpa);
                a.setSidebarNotice("The linked conversation was not found", null);
            }
            return;
        }
        // Consume before showing a missing native window: its initial render
        // can re-enter tick/settle. Native callbacks mutate only pre-tree.
        s.pending = null;
        defer a.gpa.free(pending.chat);
        const was = a.view.in_pre_tree;
        a.view.in_pre_tree = true;
        a.view.palette.open = false;
        a.picker = .none;
        a.view.strip.menu = null;
        a.view.write_open = false;
        a.openChatInTab(pending.chat);
        a.view.in_pre_tree = was;
        if (s.presenter) |presenter| presenter.show(presenter.ctx);
        a.redraw();
    }
};

fn string(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn digest(h: *std.crypto.hash.sha2.Sha256) [16]u8 {
    var bytes: [32]u8 = undefined;
    h.final(&bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return hex[0..16].*;
}
pub fn localLocator(device: []const u8) ?[16]u8 {
    if (device.len == 0) return null;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("Local\x00device:");
    h.update(device);
    return digest(&h);
}
fn accountLocator(scope: Scope, user: []const u8, org: []const u8) [16]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(if (scope == .synced) "Synced\x00user:" else "Development\x00user:");
    h.update(user);
    h.update(":org:");
    h.update(org);
    return digest(&h);
}
fn validChat(chat: []const u8) bool {
    return chat.len > 0 and chat.len <= max_component and std.mem.indexOfScalar(u8, chat, 0) == null and std.unicode.utf8ValidateSlice(chat);
}
fn validLocator(locator: []const u8) bool {
    if (locator.len != 16) return false;
    for (locator) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}
fn decode(gpa: Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len > max_component * 3) return error.InvalidLink;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = if (encoded[i] == '%') blk: {
            if (i + 2 >= encoded.len) return error.InvalidLink;
            const b = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch return error.InvalidLink;
            i += 2;
            break :blk b;
        } else encoded[i];
        try out.append(gpa, byte);
    }
    return out.toOwnedSlice(gpa);
}
pub fn formatLink(buf: []u8, chat: []const u8, workspace: []const u8) ?[]const u8 {
    if (!validChat(chat) or !validLocator(workspace)) return null;
    var writer: std.Io.Writer = .fixed(buf);
    writer.writeAll(prefix) catch return null;
    for (chat) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') writer.writeByte(byte) catch return null else writer.print("%{X:0>2}", .{byte}) catch return null;
    }
    writer.print("?workspace={s}", .{workspace}) catch return null;
    return writer.buffered();
}

const Link = struct { chat: []u8, workspace: [16]u8 };
fn parse(gpa: Allocator, url: []const u8) !Link {
    if (!std.mem.startsWith(u8, url, prefix)) return error.InvalidLink;
    const rest = url[prefix.len..];
    const question = std.mem.indexOfScalar(u8, rest, '?') orelse return error.InvalidLink;
    const raw = rest[0..question];
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, '/') != null) return error.InvalidLink;
    const chat = try decode(gpa, raw);
    errdefer gpa.free(chat);
    if (!validChat(chat)) return error.InvalidLink;
    var query = std.mem.splitScalar(u8, rest[question + 1 ..], '&');
    while (query.next()) |part| if (std.mem.startsWith(u8, part, "workspace=")) {
        const workspace = try decode(gpa, part["workspace=".len..]);
        defer gpa.free(workspace);
        if (!validLocator(workspace)) return error.InvalidLink;
        return .{ .chat = chat, .workspace = workspace[0..16].* };
    };
    return error.InvalidLink;
}

const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
fn localLink(buf: []u8, chat: []const u8, device: []const u8) []const u8 {
    return @import("view_chat_menu.zig").conversationLink(buf, chat, device).?;
}

test "external navigation original link encoding and authority reject malformed or foreign input" {
    try testing.expectEqualStrings("9b427a350f67833a", &localLocator("local").?);
    try testing.expectEqualStrings("447f50b4cbb5e75b", &accountLocator(.synced, "synthetic-user", "personal"));
    try testing.expectEqualStrings("0312f75830b71f5d", &accountLocator(.development, "synthetic-user", "synthetic-org"));
    var buf: [512]u8 = undefined;
    const parsed = try parse(testing.allocator, localLink(&buf, "chat/space café", "local"));
    defer testing.allocator.free(parsed.chat);
    try testing.expectEqualStrings("chat/space café", parsed.chat);
    try testing.expectEqualSlices(u8, &localLocator("local").?, &parsed.workspace);
    for ([_][]const u8{ "https://example.invalid", "harness://open/chat/a", "harness://open/chat/%GG?workspace=0000000000000000", "harness://open/chat/%00?workspace=0000000000000000", "harness://open/chat/%FF?workspace=0000000000000000", "harness://open/chat/a/b?workspace=0000000000000000" }) |url| {
        try testing.expectError(error.InvalidLink, parse(testing.allocator, url));
    }
}

test "external navigation deferred links wait for identity and chats then preserve the original workspace once" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    h.a.composer.set("Synthetic source draft");
    var buf: [256]u8 = undefined;
    s.openURL(&h.a, localLink(&buf, "b", "local"));
    try testing.expect(s.pending != null);
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.a.account.scope = .local;
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[{\"id\":\"a\",\"deviceId\":\"local\"}]", .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    s.settle(&h.a);
    try testing.expect(s.pending != null);
    const synced = try std.json.parseFromSlice(std.json.Value, testing.allocator, "[{\"id\":\"a\",\"deviceId\":\"local\"},{\"id\":\"b\",\"deviceId\":\"remote\",\"spaceId\":\"remote-project\"}]", .{});
    defer synced.deinit();
    try h.a.chats.replace(synced.value);
    h.a.chats_synced = true;
    s.settle(&h.a);
    try testing.expect(s.pending == null);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.tabs.find("a") != null);
    const count = h.a.tabs.items.items.len;
    s.settle(&h.a);
    try testing.expectEqual(count, h.a.tabs.items.items.len);
    h.a.openChatInTab("a");
    try testing.expectEqualStrings("Synthetic source draft", h.a.composer.text());
}

test "external navigation wrong workspace missing target and invalid links never replace selection" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    h.a.account.scope = .local;
    h.a.chats_synced = true;
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ localLink(&buf, "b", "another-device"), "harness://open/chat/%GG?workspace=0000000000000000" }) |url| {
        s.openURL(&h.a, url);
        try testing.expect(s.pending == null);
        try testing.expectEqualStrings("a", h.a.selected.?);
    }
    s.openURL(&h.a, localLink(&buf, "missing", "local"));
    try testing.expect(s.pending == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
}

test "external navigation synced workspace requires signed-in user ID and correct organization" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    var s: State = .{};
    defer s.deinit(testing.allocator);
    h.a.account.scope = .synced;
    const locator = accountLocator(.synced, "synthetic-user", "synthetic-org");
    s.openTarget(&h.a, "b", &locator);
    try testing.expect(s.pending != null);
    const auth = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"state\":\"signedIn\",\"user\":{\"id\":\"synthetic-user\",\"email\":\"unused@example.invalid\"},\"orgId\":\"different-org\"}", .{});
    defer auth.deinit();
    s.authChanged(auth.value);
    s.settle(&h.a);
    try testing.expect(s.pending == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
    const personal = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"state\":\"signedIn\",\"user\":{\"id\":\"synthetic-user\"},\"orgId\":null}", .{});
    defer personal.deinit();
    s.authChanged(personal.value);
    const own = s.locator(&h.a).?;
    try testing.expectEqualSlices(u8, &accountLocator(.synced, "synthetic-user", "personal"), &own);
    s.openTarget(&h.a, "b", &own);
    try testing.expectEqualStrings("b", h.a.selected.?);
    const out = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"state\":\"signedOut\"}", .{});
    defer out.deinit();
    s.authChanged(out.value);
    try testing.expect(s.locator(&h.a) == null);
}
