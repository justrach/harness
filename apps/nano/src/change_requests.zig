//! A checkout's pull request, as the GPUI app finds and shows it
//! (crates/ui/src/change_requests.rs): which branches to watch
//! (`desired_watch_targets`), each `WatchCheckoutChangeRequest` frame kept
//! by its target (`ChangeRequestClientState`), the PR a chat may show
//! (`change_request_for_chat`, rechecked against device, checkout, folder
//! and branch), whether it's the chat's own or found from a shared branch
//! (#357), and the badge's words and tone. Pure, so the Rust tests run here
//! too, ported below.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const workspace = @import("workspace.zig");
const Chat = workspace.Chat;
const Space = workspace.Space;
const Source = workspace.Source;

/// `ChangeRequestState`.
pub const State = enum { open, closed, merged };

/// `ChangeRequestSummary`.
pub const Summary = struct {
    provider: []const u8,
    number: u64,
    title: []const u8,
    url: []const u8,
    state: State,
    base_ref: []const u8,
    head_ref: []const u8,
};

/// `CheckoutChangeRequestStatus`: the latest lookup for one checkout and
/// branch; no `change_request` is a lookup that found none.
pub const Status = struct {
    checkout_id: []const u8,
    device_id: []const u8,
    cwd: []const u8,
    branch: []const u8,
    change_request: ?Summary = null,
};

/// `ChangeRequestWatchKey`: one host-side watch, shared by every chat on it.
pub const WatchKey = struct {
    device_id: []const u8,
    cwd: []const u8,
    branch: []const u8,
    checkout_id: ?[]const u8,

    pub fn eql(x: WatchKey, y: WatchKey) bool {
        return std.mem.eql(u8, x.device_id, y.device_id) and std.mem.eql(u8, x.cwd, y.cwd) and
            std.mem.eql(u8, x.branch, y.branch) and optEql(x.checkout_id, y.checkout_id);
    }

    pub fn dupe(k: WatchKey, a: Allocator) !WatchKey {
        return .{
            .device_id = try a.dupe(u8, k.device_id),
            .cwd = try a.dupe(u8, k.cwd),
            .branch = try a.dupe(u8, k.branch),
            .checkout_id = if (k.checkout_id) |c| try a.dupe(u8, c) else null,
        };
    }
};

fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

fn device(chat: Chat) []const u8 {
    return chat.device_id orelse "";
}

// ── the badge ────────────────────────────────────────────────────────

/// `ChangeRequestBadgeTone`: success, the accent (`code_text`), danger.
pub const Tone = enum { open, merged, closed };

/// `ChangeRequestBadgeModel`.
pub const Model = struct {
    /// "#90", in the allocator `model` was given.
    number: []const u8,
    state_label: []const u8,
    /// The title on one line: returns and newlines read as spaces.
    title: []const u8,
    tone: Tone,
};

pub fn toneOf(s: State) Tone {
    return switch (s) {
        .open => .open,
        .merged => .merged,
        .closed => .closed,
    };
}

pub fn model(a: Allocator, s: Summary) Model {
    var m: Model = .{
        .number = std.fmt.allocPrint(a, "#{d}", .{s.number}) catch "#",
        .state_label = switch (s.state) {
            .open => "Open",
            .merged => "Merged",
            .closed => "Closed",
        },
        .tone = toneOf(s.state),
        .title = s.title,
    };
    if (std.mem.indexOfAny(u8, s.title, "\r\n") != null) if (a.dupe(u8, s.title)) |t| {
        for (t) |*ch| if (ch.* == '\r' or ch.* == '\n') {
            ch.* = ' ';
        };
        m.title = t;
    } else |_| {};
    return m;
}

/// `ChangeRequestProvenance` (#357): a PR is found from the chat's branch,
/// not recorded against the chat, so it's the chat's own only when nobody
/// else works on that branch.
pub const Provenance = union(enum) {
    /// Its own checkout: not the project's folder, and no other chat in it.
    own_branch,
    /// The project's folder, or a checkout `other_chats` others share.
    shared_branch: usize,

    /// A merged or closed PR found from a shared branch is the branch's
    /// history, not this chat's status: no state colour.
    pub fn mutes(p: Provenance, s: Summary) bool {
        return p == .shared_branch and s.state != .open;
    }

    /// The tooltip's last line, for a shared branch.
    pub fn note(p: Provenance, a: Allocator, s: Summary) ?[]const u8 {
        const others = switch (p) {
            .own_branch => return null,
            .shared_branch => |n| n,
        };
        const tail = if (s.state == .open) ". Not necessarily this chat's." else ". Not necessarily from this chat.";
        return switch (others) {
            0 => std.fmt.allocPrint(a, "Found from branch {s}{s}", .{ s.head_ref, tail }),
            1 => std.fmt.allocPrint(a, "Found from branch {s}, also used by 1 other chat{s}", .{ s.head_ref, tail }),
            else => std.fmt.allocPrint(a, "Found from branch {s}, also used by {d} other chats{s}", .{ s.head_ref, others, tail }),
        } catch null;
    }
};

/// `change_request_provenance`: a chat without a current source context,
/// or without a project to compare against, counts as shared: ownership is
/// shown, not assumed.
pub fn provenance(chat: Chat, chats: []const Chat, spaces: []const Space) Provenance {
    const checkout: ?[]const u8 = if (currentSource(chat)) |s| s.checkout_id else null;
    var others: usize = 0;
    if (checkout) |co| for (chats) |o| {
        if (std.mem.eql(u8, o.id, chat.id) or o.archived) continue;
        if (!std.mem.eql(u8, device(o), device(chat))) continue;
        const src = currentSource(o) orelse continue;
        if (std.mem.eql(u8, src.checkout_id, co)) others += 1;
    };
    const space: ?Space = if (chat.space_id) |id| for (spaces) |s| {
        if (std.mem.eql(u8, s.id, id)) break s;
    } else null else null;
    if (checkout) |co| if (space) |s| if (others == 0 and !optEql(s.checkout_id, co)) return .own_branch;
    return .{ .shared_branch = others };
}

// ── which PR a chat shows ────────────────────────────────────────────

/// `current_source_context` (#356): the source context while it says where
/// the chat runs now; not when the latest run couldn't observe its
/// checkout, nor after a move to a folder no run has seen yet.
pub fn currentSource(chat: Chat) ?Source {
    const src = chat.source orelse return null;
    if (chat.source_unavailable) return null;
    if (chat.cwd) |cwd| {
        const trim = "/\\";
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, cwd, trim), std.mem.trimEnd(u8, src.cwd, trim))) return null;
    }
    return src;
}

/// `conversation_branch`: the current source context's branch, not blank.
pub fn conversationBranch(chat: Chat) ?[]const u8 {
    const src = currentSource(chat) orelse return null;
    return if (std.mem.trim(u8, src.branch, " \t\r\n").len == 0) null else src.branch;
}

/// `change_request_for_chat`: a snapshot for this chat's device, root,
/// branch and checkout, trusting no cache key alone; its PR, if it found one.
pub fn forChat(chat: Chat, snapshots: []const Status) ?Summary {
    const branch = std.mem.trim(u8, conversationBranch(chat) orelse return null, " \t\r\n");
    if (branch.len == 0) return null;
    const src = currentSource(chat) orelse return null;
    for (snapshots) |s| {
        if (std.mem.eql(u8, s.device_id, device(chat)) and std.mem.eql(u8, s.cwd, src.repo_root) and
            std.mem.eql(u8, s.branch, branch) and s.checkout_id.len != 0 and std.mem.eql(u8, s.checkout_id, src.checkout_id))
            return s.change_request;
    }
    return null;
}

/// `desired_watch_targets`: active chats' current checkouts with a branch,
/// on devices that serve the watch, each once.
pub fn desiredTargets(a: Allocator, chats: []const Chat, state: *const ClientState) ![]WatchKey {
    var out: std.ArrayList(WatchKey) = .empty;
    for (chats) |chat| {
        if (chat.archived or !state.isSupported(device(chat))) continue;
        const src = currentSource(chat) orelse continue;
        if (std.mem.trim(u8, src.branch, " \t\r\n").len == 0) continue;
        const key: WatchKey = .{ .device_id = device(chat), .cwd = src.repo_root, .branch = src.branch, .checkout_id = src.checkout_id };
        for (out.items) |k| {
            if (k.eql(key)) break;
        } else try out.append(a, key);
    }
    return out.toOwnedSlice(a);
}

/// `WatchCheckoutChangeRequest`'s params (`watch_params`): the checkout's
/// root and branch, routed to its host unless that's this device.
pub const WatchParams = struct { cwd: []const u8, branch: []const u8, targetDeviceId: ?[]const u8 = null };

pub fn watchParams(target: WatchKey, local_device: ?[]const u8) WatchParams {
    const routed = if (local_device) |l| !std.mem.eql(u8, l, target.device_id) else true;
    return .{ .cwd = target.cwd, .branch = target.branch, .targetDeviceId = if (routed) target.device_id else null };
}

/// `MergeChangeRequest`'s params (`merge_params`): the checkout and branch
/// the badge watches, on the chat's device. The host merges only while
/// `number` is still the branch's open PR.
pub const MergeParams = struct { cwd: []const u8, branch: []const u8, targetDeviceId: ?[]const u8 = null, number: u64 };

pub fn mergeParams(chat: Chat, number: u64, local_device: ?[]const u8) ?MergeParams {
    const src = chat.source orelse return null;
    if (std.mem.trim(u8, src.branch, " \t\r\n").len == 0) return null;
    const w = watchParams(.{ .device_id = device(chat), .cwd = src.repo_root, .branch = src.branch, .checkout_id = null }, local_device);
    return .{ .cwd = w.cwd, .branch = w.branch, .targetDeviceId = w.targetDeviceId, .number = number };
}

// ── frames ───────────────────────────────────────────────────────────

fn field(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// A `CheckoutChangeRequestStatus` frame, its strings in `a`; null when it
/// isn't one (dropped, as the GPUI app drops a malformed frame).
pub fn parseStatus(a: Allocator, v: json.Value) ?Status {
    if (v != .object) return null;
    const o = v.object;
    if (field(o, "updatedAt") == null) return null;
    var s: Status = .{
        .checkout_id = a.dupe(u8, field(o, "checkoutId") orelse return null) catch return null,
        .device_id = a.dupe(u8, field(o, "deviceId") orelse return null) catch return null,
        .cwd = a.dupe(u8, field(o, "cwd") orelse return null) catch return null,
        .branch = a.dupe(u8, field(o, "branch") orelse return null) catch return null,
    };
    const cr = o.get("changeRequest") orelse return s;
    if (cr == .null) return s;
    if (cr != .object) return null;
    const c = cr.object;
    const n = c.get("number") orelse return null;
    if (n != .integer or n.integer < 0) return null;
    const st = field(c, "state") orelse return null;
    s.change_request = .{
        .provider = a.dupe(u8, field(c, "provider") orelse return null) catch return null,
        .number = @intCast(n.integer),
        .title = a.dupe(u8, field(c, "title") orelse return null) catch return null,
        .url = a.dupe(u8, field(c, "url") orelse return null) catch return null,
        .state = std.meta.stringToEnum(State, st) orelse return null,
        .base_ref = a.dupe(u8, field(c, "baseRef") orelse return null) catch return null,
        .head_ref = a.dupe(u8, field(c, "headRef") orelse return null) catch return null,
    };
    return s;
}

/// `ChangeRequestMergeResult`, else the GPUI app's words for one it can't read.
pub const MergeResult = struct { merged: bool, message: []const u8 };

pub fn parseMergeResult(v: json.Value) MergeResult {
    const unreadable: MergeResult = .{ .merged = false, .message = "The host sent an unreadable merge result" };
    if (v != .object) return unreadable;
    const m = v.object.get("merged") orelse return unreadable;
    if (m != .bool) return unreadable;
    return .{ .merged = m.bool, .message = field(v.object, "message") orelse return unreadable };
}

// ── what the client keeps ────────────────────────────────────────────

/// `ChangeRequestClientState`: each watch's latest frame, and the devices
/// whose engine refused the watch (with the version that did).
pub const ClientState = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    unsupported: std.ArrayList(Unsupported) = .empty,
    /// `entries`' statuses, in order, for `forChat`.
    view: std.ArrayList(Status) = .empty,

    const Entry = struct { arena: std.heap.ArenaAllocator, key: WatchKey, status: Status };
    const Unsupported = struct { device: []u8, version: ?[]u8 };

    pub fn init(gpa: Allocator) ClientState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *ClientState) void {
        for (s.entries.items) |*e| e.arena.deinit();
        s.entries.deinit(s.gpa);
        for (s.unsupported.items) |u| freeUnsupported(s.gpa, u);
        s.unsupported.deinit(s.gpa);
        s.view.deinit(s.gpa);
    }

    fn freeUnsupported(gpa: Allocator, u: Unsupported) void {
        gpa.free(u.device);
        if (u.version) |v| gpa.free(v);
    }

    pub fn isSupported(s: *const ClientState, device_id: []const u8) bool {
        for (s.unsupported.items) |u| if (std.mem.eql(u8, u.device, device_id)) return false;
        return true;
    }

    /// The device's engine doesn't know the watch: no targets on it, and
    /// none of its snapshots shown.
    pub fn markUnsupported(s: *ClientState, device_id: []const u8, version: ?[]const u8) void {
        const d = s.gpa.dupe(u8, device_id) catch return;
        const v: ?[]u8 = if (version) |x| s.gpa.dupe(u8, x) catch null else null;
        for (s.unsupported.items) |*u| {
            if (!std.mem.eql(u8, u.device, device_id)) continue;
            freeUnsupported(s.gpa, u.*);
            u.* = .{ .device = d, .version = v };
            break;
        } else s.unsupported.append(s.gpa, .{ .device = d, .version = v }) catch freeUnsupported(s.gpa, .{ .device = d, .version = v });
        var i: usize = 0;
        while (i < s.entries.items.len) {
            if (std.mem.eql(u8, s.entries.items[i].key.device_id, device_id)) {
                s.entries.items[i].arena.deinit();
                _ = s.entries.orderedRemove(i);
            } else i += 1;
        }
        s.refresh();
    }

    /// `clear_unsupported_on_version_change`: a refusal describes one
    /// running engine; a host on another version is asked again.
    pub fn clearUnsupportedOnVersionChange(s: *ClientState, device_id: []const u8, version: ?[]const u8) bool {
        for (s.unsupported.items, 0..) |u, i| {
            if (!std.mem.eql(u8, u.device, device_id)) continue;
            if (optEql(u.version, version)) return false;
            freeUnsupported(s.gpa, u);
            _ = s.unsupported.orderedRemove(i);
            return true;
        }
        return false;
    }

    /// A frame replaces the last for its target. `status` is copied.
    pub fn store(s: *ClientState, key: WatchKey, status: Status) !void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const k = try key.dupe(a);
        var st: Status = .{
            .checkout_id = try a.dupe(u8, status.checkout_id),
            .device_id = try a.dupe(u8, status.device_id),
            .cwd = try a.dupe(u8, status.cwd),
            .branch = try a.dupe(u8, status.branch),
        };
        if (status.change_request) |c| st.change_request = .{
            .provider = try a.dupe(u8, c.provider),
            .number = c.number,
            .title = try a.dupe(u8, c.title),
            .url = try a.dupe(u8, c.url),
            .state = c.state,
            .base_ref = try a.dupe(u8, c.base_ref),
            .head_ref = try a.dupe(u8, c.head_ref),
        };
        for (s.entries.items) |*e| if (e.key.eql(key)) {
            e.arena.deinit();
            e.* = .{ .arena = arena, .key = k, .status = st };
            return s.refresh();
        };
        try s.entries.append(s.gpa, .{ .arena = arena, .key = k, .status = st });
        s.refresh();
    }

    /// Forgets snapshots no chat watches any more.
    pub fn retainTargets(s: *ClientState, targets: []const WatchKey) void {
        var i: usize = 0;
        while (i < s.entries.items.len) {
            const keep = for (targets) |t| {
                if (t.eql(s.entries.items[i].key)) break true;
            } else false;
            if (keep) i += 1 else {
                s.entries.items[i].arena.deinit();
                _ = s.entries.orderedRemove(i);
            }
        }
        s.refresh();
    }

    fn refresh(s: *ClientState) void {
        s.view.clearRetainingCapacity();
        for (s.entries.items) |e| s.view.append(s.gpa, e.status) catch return;
    }

    pub fn forChat(s: *const ClientState, chat: Chat) ?Summary {
        return @import("change_requests.zig").forChat(chat, s.view.items);
    }
};

// ── the GPUI app's tests, ported ─────────────────────────────────────

const testing = std.testing;

fn chatOf(id: []const u8, dev: []const u8, cwd: ?[]const u8) Chat {
    return .{ .id = id, .device_id = dev, .title = null, .space_id = "space", .archived = false, .preview = null, .harness = null, .model = null, .cwd = cwd, .row_branch = "feature/pr" };
}

fn spaceOf(dev: []const u8) Space {
    return .{ .id = "space", .device_id = dev, .path = "/project", .name = "project", .git = true, .checkout_id = "checkout" };
}

fn snapshot(dev: []const u8, cwd: []const u8, checkout: []const u8) Status {
    return .{ .checkout_id = checkout, .device_id = dev, .cwd = cwd, .branch = "feature/pr", .change_request = .{
        .provider = "github",
        .number = 90,
        .title = "Add pull request badges",
        .url = "https://github.com/acme/harness/pull/90",
        .state = .open,
        .base_ref = "main",
        .head_ref = "feature/pr",
    } };
}

fn withSource(chat: Chat, branch: []const u8) Chat {
    var c = chat;
    c.source = .{ .checkout_id = "checkout", .repo_root = "/repo", .cwd = "/repo", .branch = branch };
    return c;
}

fn numberOf(s: ?Summary) ?u64 {
    return if (s) |x| x.number else null;
}

fn targetCount(chats: []const Chat, state: *const ClientState) !usize {
    const t = try desiredTargets(testing.allocator, chats, state);
    defer testing.allocator.free(t);
    return t.len;
}

test "#357: a branch's PR is a chat's own only in its own checkout" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spaces = [_]Space{spaceOf("local")};
    const inWorktree = struct {
        fn f(id: []const u8, checkout: []const u8) Chat {
            var c = withSource(chatOf(id, "local", "/repo"), "feature/pr");
            c.source.?.checkout_id = checkout;
            return c;
        }
    }.f;
    const own = inWorktree("own", "worktree-1");
    try testing.expectEqual(Provenance.own_branch, provenance(own, &.{own}, &spaces));
    const peer = inWorktree("peer", "worktree-1");
    // Two chats in one checkout share its branch.
    try testing.expectEqual(Provenance{ .shared_branch = 1 }, provenance(own, &.{ own, peer }, &spaces));
    // The project's own folder is shared by whoever checks a branch out there.
    const main = inWorktree("main", "checkout");
    try testing.expectEqual(Provenance{ .shared_branch = 0 }, provenance(main, &.{main}, &spaces));
    // No project to compare against: not assumed to be the chat's.
    try testing.expectEqual(Provenance{ .shared_branch = 0 }, provenance(own, &.{own}, &.{}));

    var merged = snapshot("local", "/repo", "checkout").change_request.?;
    merged.state = .merged;
    const open = snapshot("local", "/repo", "checkout").change_request.?;
    const shared: Provenance = .{ .shared_branch = 2 };
    try testing.expect(shared.mutes(merged));
    try testing.expect(!shared.mutes(open));
    try testing.expect(!(Provenance{ .own_branch = {} }).mutes(merged));
    try testing.expect((Provenance{ .own_branch = {} }).note(a, merged) == null);
    try testing.expectEqualStrings("Found from branch feature/pr, also used by 2 other chats. Not necessarily from this chat.", shared.note(a, merged).?);
    try testing.expectEqualStrings("Found from branch feature/pr. Not necessarily this chat's.", (Provenance{ .shared_branch = 0 }).note(a, open).?);
    try testing.expectEqualStrings("Found from branch feature/pr, also used by 1 other chat. Not necessarily this chat's.", (Provenance{ .shared_branch = 1 }).note(a, open).?);
}

test "#356: only a current source context finds a pull request" {
    var state: ClientState = .init(testing.allocator);
    defer state.deinit();
    const current = withSource(chatOf("chat", "local", "/repo"), "feature/pr");
    const snap = [_]Status{snapshot("local", "/repo", "checkout")};
    try testing.expect(forChat(current, &snap) != null);

    var unavailable = current;
    unavailable.source_unavailable = true;
    try testing.expect(forChat(unavailable, &snap) == null);
    try testing.expect(conversationBranch(unavailable) == null);
    try testing.expectEqual(@as(usize, 0), try targetCount(&.{unavailable}, &state));

    var moved = current;
    moved.cwd = "/elsewhere";
    try testing.expect(forChat(moved, &snap) == null);
    try testing.expectEqual(@as(usize, 0), try targetCount(&.{moved}, &state));

    // The same folder spelled with a trailing slash.
    var trailing = current;
    trailing.cwd = "/repo/";
    try testing.expect(forChat(trailing, &snap) != null);
}

test "a shared checkout keeps conversation branches independent" {
    var state: ClientState = .init(testing.allocator);
    defer state.deinit();
    const first = withSource(chatOf("first", "local", "/repo"), "feature/one");
    const second = withSource(chatOf("second", "local", "/repo"), "feature/two");
    const targets = try desiredTargets(testing.allocator, &.{ first, second }, &state);
    defer testing.allocator.free(targets);
    try testing.expectEqual(@as(usize, 2), targets.len);
    try testing.expectEqualStrings("feature/one", targets[0].branch);
    try testing.expectEqualStrings("feature/two", targets[1].branch);

    var first_snapshot = snapshot("local", "/repo", "checkout");
    first_snapshot.branch = "feature/one";
    try testing.expectEqual(@as(?u64, 90), numberOf(forChat(first, &.{first_snapshot})));
    try testing.expect(forChat(second, &.{first_snapshot}) == null);
}

test "merge targets the badge's checkout and routes to the chat's device" {
    const local = withSource(chatOf("chat", "local", "/repo/wt"), "feature/pr");
    const p = mergeParams(local, 90, "local").?;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.Stringify.value(p, .{ .emit_null_optional_fields = false }, &w);
    try testing.expectEqualStrings("{\"cwd\":\"/repo\",\"branch\":\"feature/pr\",\"number\":90}", w.buffered());
    const remote = withSource(chatOf("chat", "remote", "/repo"), "feature/pr");
    try testing.expectEqualStrings("remote", mergeParams(remote, 90, "local").?.targetDeviceId.?);
    try testing.expect(mergeParams(chatOf("chat", "local", "/repo"), 90, "local") == null);
}

test "a source-context chat finds its local snapshot; a remote chat needs the same device" {
    const chat = withSource(chatOf("chat", "local", "/repo"), "feature/pr");
    try testing.expectEqual(@as(?u64, 90), numberOf(forChat(chat, &.{snapshot("local", "/repo", "checkout")})));
    const remote = withSource(chatOf("chat", "remote", "/repo"), "feature/pr");
    try testing.expect(forChat(remote, &.{snapshot("local", "/repo", "checkout")}) == null);
}

test "a mismatched checkout rejects a matching folder" {
    var chat = withSource(chatOf("chat", "local", "/repo"), "feature/pr");
    chat.source.?.checkout_id = "new-checkout";
    try testing.expect(forChat(chat, &.{snapshot("local", "/repo", "old-checkout")}) == null);
}

test "without a source context, legacy branch metadata finds nothing" {
    var state: ClientState = .init(testing.allocator);
    defer state.deinit();
    // A worktree.
    const tree = chatOf("chat", "local", "/repo");
    try testing.expect(forChat(tree, &.{snapshot("local", "/repo", "checkout")}) == null);
    try testing.expect(conversationBranch(tree) == null);
    try testing.expectEqual(@as(usize, 0), try targetCount(&.{tree}, &state));
    // The project's root.
    const root = chatOf("chat", "local", null);
    try testing.expect(forChat(root, &.{snapshot("local", "/project", "checkout")}) == null);
    try testing.expectEqual(@as(usize, 0), try targetCount(&.{root}, &state));
}

test "a different branch hides the snapshot" {
    var chat = withSource(chatOf("chat", "local", "/repo"), "feature/other");
    chat.row_branch = "feature/pr";
    try testing.expect(forChat(chat, &.{snapshot("local", "/repo", "checkout")}) == null);
}

test "shared chats watch once, and the last archive removes the target" {
    var state: ClientState = .init(testing.allocator);
    defer state.deinit();
    const first = withSource(chatOf("one", "local", "/repo"), "feature/pr");
    var second = withSource(chatOf("two", "local", "/repo"), "feature/pr");
    try testing.expectEqual(@as(usize, 1), try targetCount(&.{ first, second }, &state));
    second.archived = true;
    try testing.expectEqual(@as(usize, 1), try targetCount(&.{ first, second }, &state));
    var gone = first;
    gone.archived = true;
    try testing.expectEqual(@as(usize, 0), try targetCount(&.{ gone, second }, &state));
}

test "an unsupported device has no targets nor a visible snapshot" {
    const chat = withSource(chatOf("chat", "old-engine", "/repo"), "feature/pr");
    var state: ClientState = .init(testing.allocator);
    defer state.deinit();
    try state.store(.{ .device_id = "old-engine", .cwd = "/repo", .branch = "feature/pr", .checkout_id = "checkout" }, snapshot("old-engine", "/repo", "checkout"));
    try testing.expect(state.forChat(chat) != null);
    state.markUnsupported("old-engine", "0.2.2");
    try testing.expect(state.forChat(chat) == null);
    try testing.expectEqual(@as(usize, 0), try targetCount(&.{chat}, &state));
}

test "a host upgrade asks a previously unsupported device again" {
    const chat = withSource(chatOf("chat", "host", "/repo"), "feature/pr");
    var state: ClientState = .init(testing.allocator);
    defer state.deinit();
    state.markUnsupported("host", "0.2.2");
    try testing.expect(!state.isSupported("host"));
    try testing.expect(!state.clearUnsupportedOnVersionChange("host", "0.2.2"));
    try testing.expect(state.clearUnsupportedOnVersionChange("host", "0.2.3"));
    try testing.expect(state.isSupported("host"));
    try testing.expectEqual(@as(usize, 1), try targetCount(&.{chat}, &state));
}

test "a successful lookup that found none clears the previous PR" {
    const chat = withSource(chatOf("chat", "local", "/repo"), "feature/pr");
    const key: WatchKey = .{ .device_id = "local", .cwd = "/repo", .branch = "feature/pr", .checkout_id = "checkout" };
    var state: ClientState = .init(testing.allocator);
    defer state.deinit();
    try state.store(key, snapshot("local", "/repo", "checkout"));
    try testing.expect(state.forChat(chat) != null);
    var none = snapshot("local", "/repo", "checkout");
    none.change_request = null;
    try state.store(key, none);
    try testing.expect(state.forChat(chat) == null);
    // Unwatched, its snapshot goes.
    try state.store(key, snapshot("local", "/repo", "checkout"));
    state.retainTargets(&.{});
    try testing.expect(state.forChat(chat) == null);
}

test "local and remote watch params route to the checkout's host" {
    const target: WatchKey = .{ .device_id = "host", .cwd = "/repo", .branch = "feature/pr", .checkout_id = "checkout" };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.Stringify.value(watchParams(target, "host"), .{ .emit_null_optional_fields = false }, &w);
    try testing.expectEqualStrings("{\"cwd\":\"/repo\",\"branch\":\"feature/pr\"}", w.buffered());
    w = .fixed(&buf);
    try json.Stringify.value(watchParams(target, "viewport"), .{ .emit_null_optional_fields = false }, &w);
    try testing.expectEqualStrings("{\"cwd\":\"/repo\",\"branch\":\"feature/pr\",\"targetDeviceId\":\"host\"}", w.buffered());
    // This device not known yet: routed, as the GPUI app routes it.
    try testing.expectEqualStrings("host", watchParams(target, null).targetDeviceId.?);
}

test "badge models cover open, merged and closed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { State, []const u8, Tone }{
        .{ .open, "Open", .open },
        .{ .merged, "Merged", .merged },
        .{ .closed, "Closed", .closed },
    };
    for (cases) |case| {
        var s = snapshot("local", "/repo", "checkout").change_request.?;
        s.state = case[0];
        s.title = "First line\nSecond line";
        const m = model(arena.allocator(), s);
        try testing.expectEqualStrings("#90", m.number);
        try testing.expectEqualStrings(case[1], m.state_label);
        try testing.expectEqual(case[2], m.tone);
        try testing.expectEqualStrings("First line Second line", m.title);
    }
}

test "a frame reads as the engine sends it, camelCase; a malformed one is dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, State }{ .{ "open", .open }, .{ "closed", .closed }, .{ "merged", .merged } }) |case| {
        const text = try std.fmt.allocPrint(a,
            \\{{"checkoutId":"checkout-1","deviceId":"device-1","cwd":"/repo","branch":"feature/change","updatedAt":"2026-08-15T12:30:00Z",
            \\ "changeRequest":{{"provider":"github","number":90,"title":"Model checkout change request status","url":"https://github.com/acme/harness/pull/90","state":"{s}","baseRef":"main","headRef":"feature/change"}}}}
        , .{case[0]});
        const s = parseStatus(a, try json.parseFromSliceLeaky(json.Value, a, text, .{})).?;
        try testing.expectEqualStrings("checkout-1", s.checkout_id);
        try testing.expectEqual(case[1], s.change_request.?.state);
        try testing.expectEqualStrings("main", s.change_request.?.base_ref);
        try testing.expectEqualStrings("feature/change", s.change_request.?.head_ref);
    }
    const none = parseStatus(a, try json.parseFromSliceLeaky(json.Value, a,
        \\{"checkoutId":"c","deviceId":"d","cwd":"/r","branch":"b","changeRequest":null,"updatedAt":"2026-08-15T12:30:00Z"}
    , .{})).?;
    try testing.expect(none.change_request == null);
    try testing.expect(parseStatus(a, try json.parseFromSliceLeaky(json.Value, a,
        \\{"checkoutId":"c","deviceId":"d","cwd":"/r","branch":"b","changeRequest":{"number":1,"state":"draft"},"updatedAt":"t"}
    , .{})) == null);
    try testing.expect(parseStatus(a, try json.parseFromSliceLeaky(json.Value, a,
        \\{"checkoutId":"c","deviceId":"d","cwd":"/r"}
    , .{})) == null);
}

test "a merge result, else the words for one that can't be read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = parseMergeResult(try json.parseFromSliceLeaky(json.Value, a, "{\"merged\":false,\"message\":\"Required status checks are pending\"}", .{}));
    try testing.expect(!ok.merged);
    try testing.expectEqualStrings("Required status checks are pending", ok.message);
    try testing.expectEqualStrings("The host sent an unreadable merge result", parseMergeResult(.null).message);
}

test "a chat's source context and a project's checkout are read from their rows" {
    var chats: workspace.Chats = .init(testing.allocator);
    defer chats.deinit();
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"id":"a","deviceId":"d","cwd":"/r/wt","sourceContext":{"checkoutId":"wt-1","repoRoot":"/r","cwd":"/r/wt","branch":"feat/x","observedAt":"2026-10-01T00:00:00Z"}},
        \\ {"id":"b","deviceId":"d","cwd":"/r","sourceContextUnavailableAt":"2026-10-01T00:00:00Z","sourceContext":{"checkoutId":"c","repoRoot":"/r","cwd":"/r","branch":"main"}}]
    , .{});
    defer parsed.deinit();
    try chats.replace(parsed.value);
    try testing.expectEqualStrings("wt-1", currentSource(chats.items[0]).?.checkout_id);
    try testing.expectEqualStrings("/r", currentSource(chats.items[0]).?.repo_root);
    try testing.expect(chats.items[1].source != null);
    try testing.expect(currentSource(chats.items[1]) == null);
    var spaces: workspace.Spaces = .init(testing.allocator);
    defer spaces.deinit();
    var sp = try json.parseFromSlice(json.Value, testing.allocator, "[{\"id\":\"s\",\"path\":\"/r\",\"checkoutId\":\"c\"}]", .{});
    defer sp.deinit();
    try spaces.replace(sp.value);
    try testing.expectEqualStrings("c", spaces.items[0].checkout_id.?);
}
