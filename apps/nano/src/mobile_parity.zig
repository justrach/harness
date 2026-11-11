//! Pure mobile parity rules shared with iOS (`apps/ios/Harness`) and Android
//! (`crates/mobile`), formally verified in `lean-proofs/HarnessProofs/MobileIosParity.lean`
//! and exercised against `apps/parity/vectors/*.json` in `mobile_parity_tests.zig`.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// 1. Presence (`presence-rule.json`)
// ---------------------------------------------------------------------------

pub const live_fresh_ms: i64 = 45_000;
pub const dark_ms: i64 = 300_000;
pub const warmup_ms: i64 = 60_000;

pub const Liveness = enum {
    live,
    unknown,
    dark,

    pub fn name(l: Liveness) []const u8 {
        return switch (l) {
            .live => "live",
            .unknown => "unknown",
            .dark => "dark",
        };
    }
};

pub const PresenceStatus = enum {
    online,
    unknown,
    offline,

    pub fn name(s: PresenceStatus) []const u8 {
        return switch (s) {
            .online => "online",
            .unknown => "unknown",
            .offline => "offline",
        };
    }
};

pub fn presenceLiveness(
    now: i64,
    received: ?i64,
    connected: bool,
    joined_at: ?i64,
    row_last_seen: ?i64,
) Liveness {
    if (received) |at| {
        if (!connected) return .unknown;
        const quiet = now - at;
        if (quiet < live_fresh_ms) return .live;
        if (joined_at != null and quiet >= dark_ms) return .dark;
        return .unknown;
    }
    if (!connected) return .unknown;
    const joined = joined_at orelse return .unknown;
    if (now - joined < warmup_ms) return .unknown;
    const last = row_last_seen orelse return .unknown;
    return if (now - last >= dark_ms) .dark else .unknown;
}

pub fn presenceStatus(
    now: i64,
    received: ?i64,
    connected: bool,
    joined_at: ?i64,
    row_last_seen: ?i64,
) PresenceStatus {
    if (received) |at| {
        if (now - at < live_fresh_ms) return .online;
    }
    return switch (presenceLiveness(now, received, connected, joined_at, row_last_seen)) {
        .live => .online,
        .unknown => .unknown,
        .dark => .offline,
    };
}

pub fn presenceNextChange(
    now: i64,
    received: ?i64,
    connected: bool,
    joined_at: ?i64,
    row_last_seen: ?i64,
) ?i64 {
    var best: ?i64 = null;
    const consider = struct {
        fn f(cur: *?i64, now_ms: i64, t: i64) void {
            if (t <= now_ms) return;
            if (cur.* == null or t < cur.*.?) cur.* = t;
        }
    }.f;

    if (received) |at| {
        consider(&best, now, at + live_fresh_ms);
        if (connected and joined_at != null) consider(&best, now, at + dark_ms);
    } else if (connected) {
        if (joined_at) |j| {
            consider(&best, now, j + warmup_ms);
            if (row_last_seen) |last| consider(&best, now, last + dark_ms);
        }
    }
    return best;
}

// ---------------------------------------------------------------------------
// 2. Home Grouping (`home-grouping.json`)
// ---------------------------------------------------------------------------

pub const GroupBy = enum {
    none,
    project,
    device,

    pub fn fromStr(s: []const u8) GroupBy {
        if (std.mem.eql(u8, s, "project")) return .project;
        if (std.mem.eql(u8, s, "device")) return .device;
        return .none;
    }
};

pub const HomeChatRef = struct {
    id: []const u8,
    space_id: ?[]const u8 = null,
    device_id: []const u8,
};

pub const HomeSection = struct {
    id: []const u8,
    kind: []const u8,
    chats: [][]const u8,
};

pub fn groupHomeChats(
    arena: Allocator,
    chats: []const HomeChatRef,
    by: GroupBy,
    pinned_ids: []const []const u8,
) ![]HomeSection {
    if (chats.len == 0) return &.{};
    if (by == .none) {
        var ids: std.ArrayList([]const u8) = .empty;
        for (chats) |ch| try ids.append(arena, ch.id);
        var single: std.ArrayList(HomeSection) = .empty;
        try single.append(arena, .{
            .id = "all",
            .kind = "all",
            .chats = try ids.toOwnedSlice(arena),
        });
        return single.toOwnedSlice(arena);
    }

    var pinned_list: std.ArrayList([]const u8) = .empty;
    var rest: std.ArrayList(HomeChatRef) = .empty;

    for (chats) |ch| {
        var is_pinned = false;
        for (pinned_ids) |pid| {
            if (std.mem.eql(u8, pid, ch.id)) {
                is_pinned = true;
                break;
            }
        }
        if (is_pinned) {
            try pinned_list.append(arena, ch.id);
        } else {
            try rest.append(arena, ch);
        }
    }

    var out: std.ArrayList(HomeSection) = .empty;
    if (pinned_list.items.len > 0) {
        try out.append(arena, .{
            .id = "pinned",
            .kind = "pinned",
            .chats = try pinned_list.toOwnedSlice(arena),
        });
    }
    if (rest.items.len == 0) return out.toOwnedSlice(arena);

    switch (by) {
        .none => {
            var ids: std.ArrayList([]const u8) = .empty;
            for (rest.items) |ch| try ids.append(arena, ch.id);
            try out.append(arena, .{
                .id = "all",
                .kind = "all",
                .chats = try ids.toOwnedSlice(arena),
            });
        },
        .project => {
            const Bucket = struct { key: ?[]const u8, ids: std.ArrayList([]const u8) = .empty };
            var buckets: std.ArrayList(Bucket) = .empty;
            var projectless: std.ArrayList([]const u8) = .empty;
            for (rest.items) |ch| {
                if (ch.space_id) |sp| {
                    if (sp.len > 0) {
                        var found: ?usize = null;
                        for (buckets.items, 0..) |b, idx| {
                            if (b.key != null and std.mem.eql(u8, b.key.?, sp)) {
                                found = idx;
                                break;
                            }
                        }
                        if (found) |idx| {
                            try buckets.items[idx].ids.append(arena, ch.id);
                        } else {
                            var b: Bucket = .{ .key = sp };
                            try b.ids.append(arena, ch.id);
                            try buckets.append(arena, b);
                        }
                        continue;
                    }
                }
                try projectless.append(arena, ch.id);
            }
            for (buckets.items) |*b| {
                try out.append(arena, .{
                    .id = try std.fmt.allocPrint(arena, "project:{s}", .{b.key.?}),
                    .kind = "project",
                    .chats = try b.ids.toOwnedSlice(arena),
                });
            }
            if (projectless.items.len > 0) {
                try out.append(arena, .{
                    .id = "project:",
                    .kind = "project",
                    .chats = try projectless.toOwnedSlice(arena),
                });
            }
        },
        .device => {
            const Bucket = struct { dev: []const u8, ids: std.ArrayList([]const u8) = .empty };
            var buckets: std.ArrayList(Bucket) = .empty;
            for (rest.items) |ch| {
                var found: ?usize = null;
                for (buckets.items, 0..) |b, idx| {
                    if (std.mem.eql(u8, b.dev, ch.device_id)) {
                        found = idx;
                        break;
                    }
                }
                if (found) |idx| {
                    try buckets.items[idx].ids.append(arena, ch.id);
                } else {
                    var b: Bucket = .{ .dev = ch.device_id };
                    try b.ids.append(arena, ch.id);
                    try buckets.append(arena, b);
                }
            }
            for (buckets.items) |*b| {
                try out.append(arena, .{
                    .id = try std.fmt.allocPrint(arena, "device:{s}", .{b.dev}),
                    .kind = "device",
                    .chats = try b.ids.toOwnedSlice(arena),
                });
            }
        },
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// 3. Composer Stop Grace (`composer-stop.json`)
// ---------------------------------------------------------------------------

pub const stop_grace_ms: i64 = 1500;

pub fn isStopAllowed(now_ms: i64, question_closed_at_ms: ?i64) bool {
    const closed = question_closed_at_ms orelse return true;
    const elapsed = now_ms - closed;
    if (elapsed < 0) return true;
    return elapsed >= stop_grace_ms;
}

// ---------------------------------------------------------------------------
// 4. Localhost URL Rule (`localhost-pages.json`)
// ---------------------------------------------------------------------------

fn isIpv4Loopback(host: []const u8) bool {
    var parts = std.mem.splitScalar(u8, host, '.');
    var octets: [4]u8 = undefined;
    var i: usize = 0;
    while (parts.next()) |seg| : (i += 1) {
        if (i >= 4 or seg.len == 0) return false;
        octets[i] = std.fmt.parseInt(u8, seg, 10) catch return false;
    }
    return i == 4 and octets[0] == 127;
}

pub fn normalizeLocalhostUrl(arena: Allocator, input: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;

    var scheme_raw: []const u8 = "http";
    var rest: []const u8 = trimmed;
    if (std.mem.indexOf(u8, trimmed, "://")) |sep| {
        scheme_raw = trimmed[0..sep];
        rest = trimmed[sep + 3 ..];
    } else if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
        const before = trimmed[0..colon];
        const slash = std.mem.indexOfAny(u8, trimmed, "/?#") orelse trimmed.len;
        if (colon < slash) {
            // Either `host:port` or an unsupported scheme like `javascript:alert(1)`.
            const after_colon = trimmed[colon + 1 .. slash];
            _ = std.fmt.parseInt(u16, after_colon, 10) catch return null;
            _ = before;
        }
    }

    const is_http = std.ascii.eqlIgnoreCase(scheme_raw, "http");
    const is_https = std.ascii.eqlIgnoreCase(scheme_raw, "https");
    if (!is_http and !is_https) return null;
    const scheme = if (is_https) "https" else "http";

    const auth_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..auth_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '@') != null) return null;

    var host_raw: []const u8 = authority;
    var port: ?u16 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host_raw = authority[0 .. close + 1];
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return null;
            const p = std.fmt.parseInt(u16, authority[close + 2 ..], 10) catch return null;
            if (p == 0) return null;
            port = p;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host_raw = authority[0..colon];
        const p = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
        if (p == 0) return null;
        port = p;
    }
    if (host_raw.len == 0) return null;

    var host_lower: []const u8 = try std.ascii.allocLowerString(arena, host_raw);
    if (std.mem.eql(u8, host_lower, "0.0.0.0")) host_lower = "localhost";

    const allowed = std.mem.eql(u8, host_lower, "localhost") or
        std.mem.endsWith(u8, host_lower, ".localhost") or
        std.mem.eql(u8, host_lower, "[::1]") or
        isIpv4Loopback(host_lower);
    if (!allowed) return null;

    const default_port: u16 = if (is_https) 443 else 80;
    if (port != null and port.? == default_port) port = null;

    const tail = rest[auth_end..];
    const need_slash = tail.len == 0 or (tail[0] != '/' and tail[0] != '?' and tail[0] != '#');
    const path_prefix: []const u8 = if (tail.len == 0 or tail[0] == '?' or tail[0] == '#') "/" else if (need_slash) "/" else "";

    if (port) |p| {
        return try std.fmt.allocPrint(arena, "{s}://{s}:{d}{s}{s}", .{ scheme, host_lower, p, path_prefix, tail });
    }
    return try std.fmt.allocPrint(arena, "{s}://{s}{s}{s}", .{ scheme, host_lower, path_prefix, tail });
}

// ---------------------------------------------------------------------------
// 5. Account Deletion (`account-deletion.json`)
// ---------------------------------------------------------------------------

pub const AccountTokens = struct {
    access_token: []const u8,
    refresh_token: []const u8,
};

pub const AccountDeletionResult = union(enum) {
    deleted,
    refused: struct {
        message: []const u8,
        tokens: ?AccountTokens = null,
    },
};

pub const account_no_account_copy = "Sign in with CodeGraff to delete your account.";
pub const account_unreachable_copy = "Couldn't reach Harness. Check your connection and try again.";

pub fn parseAccountDeletion(arena: Allocator, status: u16, body: []const u8) !AccountDeletionResult {
    var parsed_opt: ?json.Value = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch null;
    if (parsed_opt != null and parsed_opt.? != .object) parsed_opt = null;

    var tokens: ?AccountTokens = null;
    if (parsed_opt) |v| {
        if (v.object.get("tokens")) |tok_v| if (tok_v == .object) {
            const at = tok_v.object.get("accessToken");
            const rt = tok_v.object.get("refreshToken");
            if (at != null and at.? == .string and rt != null and rt.? == .string) {
                tokens = .{ .access_token = at.?.string, .refresh_token = rt.?.string };
            }
        };
    }

    if (status == 200) {
        if (parsed_opt) |v| {
            if (v.object.get("deleted")) |d| if (d == .bool and d.bool) {
                return .deleted;
            };
        }
        return .{ .refused = .{
            .message = try std.fmt.allocPrint(arena, "Couldn't delete your account (HTTP {d}). Try again in a moment.", .{status}),
            .tokens = tokens,
        } };
    }

    const err_code: []const u8 = if (parsed_opt) |v| blk: {
        const ev = v.object.get("error") orelse break :blk "";
        break :blk if (ev == .string) ev.string else "";
    } else "";

    const msg_field: []const u8 = if (parsed_opt) |v| blk: {
        const mv = v.object.get("message") orelse break :blk "";
        break :blk if (mv == .string) std.mem.trim(u8, mv.string, " \t\r\n") else "";
    } else "";

    if (std.mem.eql(u8, err_code, "active_subscription")) {
        return .{ .refused = .{
            .message = if (msg_field.len > 0) msg_field else "Your account can't be deleted yet.",
            .tokens = tokens,
        } };
    }
    if (std.mem.eql(u8, err_code, "account_deletion_unavailable")) {
        return .{ .refused = .{
            .message = "Account deletion isn't available yet. Nothing was deleted.",
            .tokens = tokens,
        } };
    }
    if (std.mem.eql(u8, err_code, "rooms_unavailable")) {
        return .{ .refused = .{
            .message = "Couldn't reach your agent rooms, so nothing was deleted. Try again in a moment.",
            .tokens = tokens,
        } };
    }
    if (std.mem.eql(u8, err_code, "codegraff_unavailable")) {
        return .{ .refused = .{
            .message = "Couldn't reach CodeGraff, so your account wasn't deleted. Try again in a moment.",
            .tokens = tokens,
        } };
    }
    if (status == 401 or std.mem.eql(u8, err_code, "signed_out")) {
        return .{ .refused = .{
            .message = "Your sign-in has expired. Sign out, sign back in, then try again.",
            .tokens = tokens,
        } };
    }
    if (std.mem.eql(u8, err_code, "wrong_account")) {
        return .{ .refused = .{
            .message = "This sign-in belongs to a different account. Sign out, sign back in, then try again.",
            .tokens = tokens,
        } };
    }
    return .{ .refused = .{
        .message = try std.fmt.allocPrint(arena, "Couldn't delete your account (HTTP {d}). Try again in a moment.", .{status}),
        .tokens = tokens,
    } };
}

// ---------------------------------------------------------------------------
// 6. Image Annotations Prompt (`annotations.json`)
// ---------------------------------------------------------------------------

pub const AnnotationMark = union(enum) {
    box: struct { x: f64, y: f64, w: f64, h: f64, text: []const u8 },
    text: struct { x: f64, y: f64, text: []const u8 },
};

fn foldOneLine(arena: Allocator, s: []const u8, soften_quotes: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    for (trimmed) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
            space = true;
            continue;
        }
        if (space and out.items.len > 0) try out.append(arena, ' ');
        space = false;
        try out.append(arena, if (soften_quotes and ch == '"') '\'' else ch);
    }
    return out.toOwnedSlice(arena);
}

fn roundPx(v: f64) i64 {
    return @intFromFloat(@round(v));
}

pub fn annotationPromptBlock(arena: Allocator, file_name: []const u8, marks: []const AnnotationMark) !?[]const u8 {
    var boxes: std.ArrayList([]const u8) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;

    for (marks) |m| switch (m) {
        .box => |b| {
            const note = try foldOneLine(arena, b.text, false);
            const label = if (note.len > 0) note else "(no note)";
            try boxes.append(arena, try std.fmt.allocPrint(
                arena,
                "{d}. [box {d},{d},{d},{d}] {s}",
                .{ boxes.items.len + 1, roundPx(b.x), roundPx(b.y), roundPx(b.w), roundPx(b.h), label },
            ));
        },
        .text => |t| {
            const note = try foldOneLine(arena, t.text, true);
            if (note.len == 0) continue;
            try texts.append(arena, try std.fmt.allocPrint(
                arena,
                "- [text {d},{d}] \"{s}\"",
                .{ roundPx(t.x), roundPx(t.y), note },
            ));
        },
    };

    if (boxes.items.len == 0 and texts.items.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    const header = try std.fmt.allocPrint(arena, "Annotations on {s} (boxes are x,y,w,h in image pixels):", .{file_name});
    try buf.appendSlice(arena, header);
    for (boxes.items) |line| {
        try buf.append(arena, '\n');
        try buf.appendSlice(arena, line);
    }
    if (texts.items.len > 0) {
        try buf.appendSlice(arena, "\nText on the image:");
        for (texts.items) |line| {
            try buf.append(arena, '\n');
            try buf.appendSlice(arena, line);
        }
    }
    return try buf.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// 7. Agent Readiness (`agent-readiness.json`)
// ---------------------------------------------------------------------------

pub const AgentStatus = enum(u8) {
    missing = 0,
    can_install = 1,
    off = 2,
    ready = 3,

    pub fn name(s: AgentStatus) []const u8 {
        return switch (s) {
            .missing => "missing",
            .can_install => "canInstall",
            .off => "off",
            .ready => "ready",
        };
    }
};

pub const ReadinessState = enum {
    no_computer,
    no_agent,
    ready,

    pub fn name(s: ReadinessState) []const u8 {
        return switch (s) {
            .no_computer => "noComputer",
            .no_agent => "noAgent",
            .ready => "ready",
        };
    }
};

pub const AgentReportEntry = struct {
    id: []const u8,
    installed: bool = true,
    enabled: bool = true,
    can_install: bool = false,
};

pub const DeviceAgentInput = struct {
    id: []const u8,
    online: bool,
    agents: []const AgentReportEntry,
};

pub const TrackedAgentReadiness = struct {
    id: []const u8,
    status: AgentStatus,
    devices: [][]const u8,
};

pub const AgentReadinessSummary = struct {
    state: ReadinessState,
    agents: [3]TrackedAgentReadiness,
};

pub const tracked_agents = [3][]const u8{ "graff", "claude-code", "codex" };

fn statusOnDevice(dev: DeviceAgentInput, agent_id: []const u8) AgentStatus {
    for (dev.agents) |a| {
        if (!std.mem.eql(u8, a.id, agent_id)) continue;
        if (a.installed) return if (a.enabled) .ready else .off;
        return if (a.can_install) .can_install else .missing;
    }
    return .missing;
}

pub fn evalAgentReadiness(arena: Allocator, devices: []const DeviceAgentInput) !AgentReadinessSummary {
    var any_online = false;
    for (devices) |d| if (d.online) {
        any_online = true;
        break;
    };

    var result_agents: [3]TrackedAgentReadiness = undefined;
    var any_ready = false;

    for (tracked_agents, 0..) |aid, idx| {
        if (!any_online) {
            result_agents[idx] = .{ .id = aid, .status = .missing, .devices = &.{} };
            continue;
        }
        var best: AgentStatus = .missing;
        for (devices) |d| {
            if (!d.online) continue;
            const st = statusOnDevice(d, aid);
            if (@intFromEnum(st) > @intFromEnum(best)) best = st;
        }
        var matching: std.ArrayList([]const u8) = .empty;
        for (devices) |d| {
            if (!d.online) continue;
            if (statusOnDevice(d, aid) == best) try matching.append(arena, d.id);
        }
        if (best == .ready) any_ready = true;
        result_agents[idx] = .{
            .id = aid,
            .status = best,
            .devices = try matching.toOwnedSlice(arena),
        };
    }

    return .{
        .state = if (!any_online) .no_computer else if (any_ready) .ready else .no_agent,
        .agents = result_agents,
    };
}

// ---------------------------------------------------------------------------
// 8. Registry Projection & Viewer Tombstone Safety (`registry-projection.json`)
// ---------------------------------------------------------------------------

pub fn validPinOrderKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 8192) return false;
    if (key[key.len - 1] == '0') return false;
    for (key) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f');
        if (!ok) return false;
    }
    return true;
}

pub const ProjectedDevice = struct {
    id: []const u8,
    name: []const u8,
    capabilities: [][]const u8,
};

pub const ProjectedSpace = struct {
    id: []const u8,
    device_id: []const u8,
    path: []const u8,
    created_at: i64,
};

pub const ProjectedChat = struct {
    id: []const u8,
    device_id: []const u8,
    title: ?[]const u8,
    archived: bool,
    harness: ?[]const u8,
    model: ?[]const u8,
    room_gen: ?i64,
    space_id: ?[]const u8,
    created_at: i64,
};

pub const ProjectedSession = struct {
    chat_id: []const u8,
    device_id: []const u8,
    status: []const u8,
};

pub const RegistryProjection = struct {
    devices: []ProjectedDevice,
    spaces: []ProjectedSpace,
    chats: []ProjectedChat,
    sessions: []ProjectedSession,
    pinned: [][]const u8,
};

fn jStr(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn jStrAllowEmpty(o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn jInt(o: json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn jBool(o: json.ObjectMap, k: []const u8) ?bool {
    const v = o.get(k) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn validSessionStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "working") or
        std.mem.eql(u8, s, "idle") or
        std.mem.eql(u8, s, "awaiting_input") or
        std.mem.eql(u8, s, "errored") or
        std.mem.eql(u8, s, "completed");
}

pub fn projectRegistry(arena: Allocator, rows: []const json.Value) !RegistryProjection {
    var devices: std.ArrayList(ProjectedDevice) = .empty;
    var spaces: std.ArrayList(ProjectedSpace) = .empty;
    var chats: std.ArrayList(ProjectedChat) = .empty;
    var sessions: std.ArrayList(ProjectedSession) = .empty;
    const PinCandidate = struct { id: []const u8, order_key: []const u8 };
    var pin_candidates: std.ArrayList(PinCandidate) = .empty;
    var pins_initialized = false;

    for (rows) |row_v| {
        if (row_v != .object) continue;
        const ro = row_v.object;
        if (jBool(ro, "deleted") orelse false) continue;
        const kind = jStr(ro, "kind") orelse continue;
        const row_id = jStr(ro, "id") orelse continue;
        const fields_v = ro.get("fields") orelse continue;
        if (fields_v != .object) continue;
        const f = fields_v.object;

        if (std.mem.eql(u8, kind, "devices")) {
            const name = jStr(f, "name") orelse row_id;
            var caps: std.ArrayList([]const u8) = .empty;
            if (f.get("capabilities")) |cv| if (cv == .array) {
                for (cv.array.items) |item| if (item == .string) {
                    try caps.append(arena, item.string);
                };
            };
            try devices.append(arena, .{
                .id = row_id,
                .name = name,
                .capabilities = try caps.toOwnedSlice(arena),
            });
        } else if (std.mem.eql(u8, kind, "spaces")) {
            const dev_id = jStr(f, "deviceId") orelse continue;
            const path = jStr(f, "path") orelse continue;
            try spaces.append(arena, .{
                .id = row_id,
                .device_id = dev_id,
                .path = path,
                .created_at = jInt(f, "createdAt") orelse 0,
            });
        } else if (std.mem.eql(u8, kind, "chats")) {
            const dev_id = jStr(f, "deviceId") orelse continue;
            var harness: ?[]const u8 = null;
            var model: ?[]const u8 = null;
            if (f.get("config")) |cfg_v| if (cfg_v == .object) {
                harness = jStr(cfg_v.object, "harness") orelse "claude-code";
                model = jStr(cfg_v.object, "model");
            };
            try chats.append(arena, .{
                .id = row_id,
                .device_id = dev_id,
                .title = jStr(f, "title"),
                .archived = jBool(f, "archived") orelse false,
                .harness = harness,
                .model = model,
                .room_gen = jInt(f, "roomGen"),
                .space_id = jStr(f, "spaceId"),
                .created_at = jInt(f, "createdAt") orelse 0,
            });
        } else if (std.mem.eql(u8, kind, "sessions")) {
            const chat_id = jStr(f, "chatId") orelse row_id;
            const dev_id = jStr(f, "deviceId") orelse continue;
            const st = jStr(f, "status") orelse continue;
            if (!validSessionStatus(st)) continue;
            try sessions.append(arena, .{ .chat_id = chat_id, .device_id = dev_id, .status = st });
        } else if (std.mem.eql(u8, kind, "preferences") and std.mem.eql(u8, row_id, "sidebarPins")) {
            pins_initialized = true;
        } else if (std.mem.eql(u8, kind, "sidebarPins")) {
            if (!(jBool(f, "pinned") orelse false)) continue;
            const key = jStr(f, "orderKey") orelse continue;
            if (!validPinOrderKey(key)) continue;
            try pin_candidates.append(arena, .{ .id = row_id, .order_key = key });
        }
    }

    std.mem.sort(ProjectedDevice, devices.items, {}, struct {
        fn less(_: void, a: ProjectedDevice, b: ProjectedDevice) bool {
            const c = std.mem.order(u8, a.name, b.name);
            return if (c != .eq) c == .lt else std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);

    std.mem.sort(ProjectedSpace, spaces.items, {}, struct {
        fn less(_: void, a: ProjectedSpace, b: ProjectedSpace) bool {
            if (a.created_at != b.created_at) return a.created_at < b.created_at;
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);

    std.mem.sort(ProjectedChat, chats.items, {}, struct {
        fn less(_: void, a: ProjectedChat, b: ProjectedChat) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);

    std.mem.sort(ProjectedSession, sessions.items, {}, struct {
        fn less(_: void, a: ProjectedSession, b: ProjectedSession) bool {
            return std.mem.order(u8, a.chat_id, b.chat_id) == .lt;
        }
    }.less);

    var pinned_out: std.ArrayList([]const u8) = .empty;
    if (pins_initialized) {
        std.mem.sort(PinCandidate, pin_candidates.items, {}, struct {
            fn less(_: void, a: PinCandidate, b: PinCandidate) bool {
                const c = std.mem.order(u8, a.order_key, b.order_key);
                return if (c != .eq) c == .lt else std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.less);
        for (pin_candidates.items) |p| try pinned_out.append(arena, p.id);
    }

    return .{
        .devices = try devices.toOwnedSlice(arena),
        .spaces = try spaces.toOwnedSlice(arena),
        .chats = try chats.toOwnedSlice(arena),
        .sessions = try sessions.toOwnedSlice(arena),
        .pinned = try pinned_out.toOwnedSlice(arena),
    };
}

/// Viewer `updateChat` rule: a phone never invents a chat row that isn't live in the registry.
pub fn viewerCanMutateChat(exists: bool, deleted: bool) bool {
    return exists and !deleted;
}

// ---------------------------------------------------------------------------
// 9. Transcript & Queue Decode (`transcript-decode.json`)
// ---------------------------------------------------------------------------

pub const DecodedEntry = struct {
    id: []const u8,
    role: []const u8,
    status: []const u8,
    device_id: []const u8,
    created_at: i64,
    parts: [][]const u8,

    pub fn headerLine(e: DecodedEntry, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}|{s}|{s}|{s}|{d}", .{ e.id, e.role, e.status, e.device_id, e.created_at });
    }
};

fn formatToolField(arena: Allocator, key: []const u8, val: json.Value) !?[]const u8 {
    return switch (val) {
        .string => |s| try std.fmt.allocPrint(arena, "{s}=s:{s}", .{ key, s }),
        .bool => |b| try std.fmt.allocPrint(arena, "{s}=b:{s}", .{ key, if (b) "true" else "false" }),
        .integer => |n| try std.fmt.allocPrint(arena, "{s}=n:{d}", .{ key, n }),
        .float => |f| try std.fmt.allocPrint(arena, "{s}=n:{d}", .{ key, @as(i64, @intFromFloat(@trunc(f))) }),
        .array => |arr| blk: {
            if (std.mem.eql(u8, key, "items")) {
                var tasks: std.ArrayList([]const u8) = .empty;
                for (arr.items) |it| {
                    if (it != .object) continue;
                    const txt = jStr(it.object, "text") orelse continue;
                    const done = jBool(it.object, "done") orelse false;
                    try tasks.append(arena, try std.fmt.allocPrint(arena, "{s}{c}", .{ txt, if (done) @as(u8, '+') else '-' }));
                }
                const joined = try std.mem.join(arena, ",", tasks.items);
                break :blk try std.fmt.allocPrint(arena, "{s}=tasks:{s}", .{ key, joined });
            }
            break :blk try std.fmt.allocPrint(arena, "{s}=list:{d}", .{ key, arr.items.len });
        },
        else => null,
    };
}

fn decodePartSummary(arena: Allocator, part_v: json.Value) !?[]const u8 {
    if (part_v != .object) return null;
    const o = part_v.object;
    const id = jStr(o, "id") orelse return null;
    const kind = jStr(o, "kind") orelse return null;

    if (std.mem.eql(u8, kind, "text")) {
        const text = jStrAllowEmpty(o, "text") orelse return null;
        return try std.fmt.allocPrint(arena, "text {s} {s}", .{ id, text });
    }
    if (std.mem.eql(u8, kind, "reasoning")) {
        const text = jStrAllowEmpty(o, "reasoning") orelse return null;
        return try std.fmt.allocPrint(arena, "reasoning {s} {s}", .{ id, text });
    }
    if (std.mem.eql(u8, kind, "tool")) {
        const call_v = o.get("call") orelse return null;
        if (call_v != .object) return null;
        const call_kind = jStr(call_v.object, "kind") orelse return null;
        const resolved = o.get("isError") != null;
        const is_err = jBool(o, "isError") orelse false;
        var fields: std.ArrayList([]const u8) = .empty;
        var it = call_v.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "kind")) continue;
            if (try formatToolField(arena, kv.key_ptr.*, kv.value_ptr.*)) |formatted| {
                try fields.append(arena, formatted);
            }
        }
        std.mem.sort([]const u8, fields.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                const eq_a = std.mem.indexOfScalar(u8, a, '=') orelse a.len;
                const eq_b = std.mem.indexOfScalar(u8, b, '=') orelse b.len;
                return std.mem.order(u8, a[0..eq_a], b[0..eq_b]) == .lt;
            }
        }.less);
        const joined = try std.mem.join(arena, ",", fields.items);
        return try std.fmt.allocPrint(
            arena,
            "tool {s} {s} resolved={s} error={s} fields={s}",
            .{ id, call_kind, if (resolved) "true" else "false", if (is_err) "true" else "false", joined },
        );
    }
    if (std.mem.eql(u8, kind, "image")) {
        const path = jStrAllowEmpty(o, "path") orelse "";
        const name = jStrAllowEmpty(o, "name") orelse "";
        const mime = jStrAllowEmpty(o, "mimeType") orelse "";
        const valid_mime = std.mem.eql(u8, mime, "image/png") or
            std.mem.eql(u8, mime, "image/jpeg") or
            std.mem.eql(u8, mime, "image/webp") or
            std.mem.eql(u8, mime, "image/gif");
        const valid = std.mem.startsWith(u8, path, "/") and
            std.mem.indexOfScalar(u8, path, 0) == null and
            name.len > 0 and
            valid_mime;
        if (!valid) return try std.fmt.allocPrint(arena, "error {s} Generated image unavailable reauth=-", .{id});
        return try std.fmt.allocPrint(arena, "image {s} {s} {s} {s}", .{ id, path, name, mime });
    }
    if (std.mem.eql(u8, kind, "input")) {
        const resolved = jBool(o, "resolved") orelse false;
        const req_id = jStr(o, "requestId") orelse id;
        var q_count: usize = 0;
        if (o.get("questions")) |qv| if (qv == .array) {
            var all_valid = true;
            for (qv.array.items) |q| {
                if (q != .object) {
                    all_valid = false;
                    break;
                }
                const qo = q.object;
                if (jStr(qo, "id") == null or jStr(qo, "header") == null or jStr(qo, "question") == null) {
                    all_valid = false;
                    break;
                }
                const opts = qo.get("options") orelse {
                    all_valid = false;
                    break;
                };
                if (opts != .array) {
                    all_valid = false;
                    break;
                }
            }
            if (all_valid) q_count = qv.array.items.len;
        };
        return try std.fmt.allocPrint(
            arena,
            "input {s} request={s} questions={d} resolved={s}",
            .{ id, req_id, q_count, if (resolved) "true" else "false" },
        );
    }
    if (std.mem.eql(u8, kind, "error")) {
        const message = jStrAllowEmpty(o, "message") orelse "";
        const reauth_raw = jStrAllowEmpty(o, "reauth") orelse "";
        const reauth = if (std.mem.eql(u8, reauth_raw, "chatgpt-new") or std.mem.eql(u8, reauth_raw, "codex")) reauth_raw else "-";
        return try std.fmt.allocPrint(arena, "error {s} {s} reauth={s}", .{ id, message, reauth });
    }
    return null;
}

pub fn decodeSessionEntries(arena: Allocator, messages: []const json.Value) ![]DecodedEntry {
    const Builder = struct {
        id: []const u8,
        role: []const u8,
        status: []const u8,
        device_id: []const u8,
        created_at: i64,
        parts: std.ArrayList([]const u8) = .empty,
    };
    var roots: std.ArrayList(Builder) = .empty;

    for (messages) |mv| {
        if (mv != .object) continue;
        const o = mv.object;
        const id = jStr(o, "id") orelse continue;
        const role = jStr(o, "role") orelse continue;
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) continue;

        var decoded_parts: std.ArrayList([]const u8) = .empty;
        if (o.get("parts")) |pv| if (pv == .array) {
            for (pv.array.items) |part_v| {
                if (try decodePartSummary(arena, part_v)) |s| try decoded_parts.append(arena, s);
            }
        };

        if (jStr(o, "continuationOf")) |root_id| {
            var attached = false;
            for (roots.items) |*r| {
                if (std.mem.eql(u8, r.id, root_id)) {
                    try r.parts.appendSlice(arena, decoded_parts.items);
                    attached = true;
                    break;
                }
            }
            if (attached) continue;
        }

        try roots.append(arena, .{
            .id = id,
            .role = role,
            .status = jStr(o, "status") orelse "complete",
            .device_id = jStrAllowEmpty(o, "deviceId") orelse "",
            .created_at = jInt(o, "createdAt") orelse 0,
            .parts = decoded_parts,
        });
    }

    var out: std.ArrayList(DecodedEntry) = .empty;
    for (roots.items) |*r| {
        try out.append(arena, .{
            .id = r.id,
            .role = r.role,
            .status = r.status,
            .device_id = r.device_id,
            .created_at = r.created_at,
            .parts = try r.parts.toOwnedSlice(arena),
        });
    }
    return out.toOwnedSlice(arena);
}

pub fn decodeSessionQueue(arena: Allocator, queue_items: []const json.Value) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (queue_items) |qv| {
        if (qv != .object) continue;
        const o = qv.object;
        const raw_id = jStrAllowEmpty(o, "id") orelse continue;
        const id = std.mem.trim(u8, raw_id, " \t");
        if (id.len == 0) continue;
        const text = jStrAllowEmpty(o, "text") orelse continue;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) continue;

        const hold = jBool(o, "holdForTurnEnd") orelse false;
        const issued_by = jStrAllowEmpty(o, "issuedBy") orelse "";
        const issued_at = jInt(o, "issuedAt") orelse 0;
        var att_count: usize = 0;
        if (o.get("attachments")) |av| if (av == .array) {
            for (av.array.items) |item| if (item == .string) {
                att_count += 1;
            };
        };

        var gate_desc: []const u8 = "-";
        if (o.get("deliveryGate")) |gv| if (gv == .object) {
            const gk = jStrAllowEmpty(gv.object, "kind") orelse "";
            if (std.mem.eql(u8, gk, "editing")) {
                const owner = jStr(gv.object, "ownerDeviceId") orelse "another device";
                const exp = jInt(gv.object, "expiresAtMs") orelse 0;
                gate_desc = try std.fmt.allocPrint(arena, "editing {s} {d}", .{ owner, exp });
            } else {
                // Unknown gates and `reviewRequired` both fail closed as review.
                const owner = jStr(gv.object, "ownerDeviceId") orelse "another device";
                gate_desc = try std.fmt.allocPrint(arena, "review {s}", .{owner});
            }
        };

        try out.append(arena, try std.fmt.allocPrint(
            arena,
            "{s}|{s}|{s}|{s}|{s}|{d}|{d}",
            .{ id, text, if (hold) "true" else "false", gate_desc, issued_by, issued_at, att_count },
        ));
    }
    return out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// 10. Message Queue Pure Rules (`message-queue.json`)
// ---------------------------------------------------------------------------

pub const attachment_only_text = "See the attached image(s).";

pub fn queueLabel(buf: []u8, count: i64) ?[]const u8 {
    if (count <= 0) return null;
    return std.fmt.bufPrint(buf, "{d} queued", .{count}) catch null;
}

pub fn queueNeighbour(from: i64, direction: i64, count: i64) ?i64 {
    if (count <= 0 or from < 0 or from >= count) return null;
    const next = from + direction;
    if (next < 0 or next >= count) return null;
    return next;
}

pub fn queueEditedText(text: []const u8, has_attachments: bool) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len > 0) return trimmed;
    return if (has_attachments) attachment_only_text else null;
}

const observed_marker = "\n\nApplications mentioned by the user (untrusted observed content):\n";
const attached_marker = "\n\nAttached images (local files:";

pub fn queueVisibleText(text: []const u8, has_attachments: bool) []const u8 {
    var visible = text;
    if (std.mem.indexOf(u8, visible, observed_marker)) |idx| visible = visible[0..idx];
    if (std.mem.indexOf(u8, visible, attached_marker)) |idx| visible = visible[0..idx];
    const trimmed = std.mem.trim(u8, visible, " \t\r\n");
    if (trimmed.len > 0) return trimmed;
    return if (has_attachments) attachment_only_text else "";
}

pub fn queuePrimaryAction(supports_actions: bool, pending: bool, gate: ?[]const u8) ?[]const u8 {
    if (!supports_actions or pending or gate != null) return null;
    return "sendNow";
}

pub fn queueAcknowledged(action: []const u8, reply: json.Value) bool {
    if (reply != .object) return false;
    if (std.mem.eql(u8, action, "remove")) return jBool(reply.object, "removed") orelse false;
    if (std.mem.eql(u8, action, "sendNow")) return jBool(reply.object, "sent") orelse false;
    return false;
}

pub fn queueComposerEdit(arena: Allocator, lease_text: []const u8, has_attachments: bool, commit: []const u8) !?[]const u8 {
    const base = queueEditedText(commit, has_attachments) orelse return null;
    if (std.mem.indexOf(u8, lease_text, observed_marker)) |obs_idx| {
        var tail = lease_text[obs_idx..];
        if (std.mem.indexOf(u8, tail, attached_marker)) |att_idx| {
            tail = tail[0..att_idx];
        }
        return try std.fmt.allocPrint(arena, "{s}{s}", .{ base, tail });
    }
    return base;
}

pub fn queueEditTerminal(results: []const []const u8) bool {
    for (results) |r| {
        if (std.mem.eql(u8, r, "missing") or std.mem.eql(u8, r, "lost")) return true;
    }
    return false;
}

pub fn queueMove(items: [][]const u8, row: []const u8, to_index: i64, relative: bool) void {
    if (items.len <= 1) return;
    var idx_opt: ?usize = null;
    for (items, 0..) |it, idx| {
        if (std.mem.eql(u8, it, row)) {
            idx_opt = idx;
            break;
        }
    }
    const from = idx_opt orelse return;
    const raw_target: i64 = if (relative) @as(i64, @intCast(from)) + to_index else to_index;
    const clamped: usize = @intCast(std.math.clamp(raw_target, 0, @as(i64, @intCast(items.len - 1))));
    if (from == clamped) return;
    const saved = items[from];
    if (from < clamped) {
        var i = from;
        while (i < clamped) : (i += 1) items[i] = items[i + 1];
    } else {
        var i = from;
        while (i > clamped) : (i -= 1) items[i] = items[i - 1];
    }
    items[clamped] = saved;
}

// ---------------------------------------------------------------------------
// 11. Performance Contract (`perf-contract.json`)
// ---------------------------------------------------------------------------

pub const PerfSpan = enum {
    startup_first_frame,
    nav_open,
    transcript_rows,
    markdown_parse,
    home_group,
    send_apply,
    main_stall,

    pub fn key(s: PerfSpan) []const u8 {
        return switch (s) {
            .startup_first_frame => "startup.firstFrame",
            .nav_open => "nav.open",
            .transcript_rows => "transcript.rows",
            .markdown_parse => "markdown.parse",
            .home_group => "home.group",
            .send_apply => "send.apply",
            .main_stall => "main.stall",
        };
    }

    pub fn budgetMs(s: PerfSpan) i64 {
        return switch (s) {
            .startup_first_frame => 1000,
            .nav_open => 100,
            .transcript_rows => 8,
            .markdown_parse => 4,
            .home_group => 4,
            .send_apply => 8,
            .main_stall => 100,
        };
    }

    pub fn wireName(s: PerfSpan) []const u8 {
        return switch (s) {
            .startup_first_frame => "app_launch_ms",
            .nav_open => "conversation_load_ms",
            .transcript_rows => "transcript_rows_ms",
            .markdown_parse => "markdown_parse_ms",
            .home_group => "home_group_ms",
            .send_apply => "send_apply_ms",
            .main_stall => "main_stall_ms",
        };
    }
};
