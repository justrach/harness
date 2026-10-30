//! Codegraff cloud sandboxes, as pure functions (crates/ui/src/
//! codegraff_sandboxes.rs): the engine's `CodegraffSandboxes` reply read
//! into plain structs, each row's title and detail, which buttons it
//! offers, the sizes a create can pick, the running summary, and when the
//! list must be read again. Rates and machines are runners.zig's
//! (`formatRate`, `machineSpec`), the same rules.
const std = @import("std");
const json = std.json;
const rules = @import("rules.zig");
const runners = @import("runners.zig");
const Allocator = std.mem.Allocator;

/// One sandbox (`CodegraffSandbox`).
pub const Sandbox = struct {
    id: []const u8 = "",
    /// `fleet` or `daytona`.
    provider: []const u8 = "",
    name: ?[]const u8 = null,
    /// `running` | `starting` | `paused` | `stopping` | `error`.
    state: []const u8 = "",
    tier: ?[]const u8 = null,
    /// When its window ends, in ms since the epoch.
    expires_ms: ?i64 = null,
    harness: bool = false,
    device_name: ?[]const u8 = null,
    keep_running: ?bool = null,
    renew_error: ?[]const u8 = null,
    cpu: ?f64 = null,
    memory_gib: ?f64 = null,
    disk_gib: ?f64 = null,
    price_per_hour_micro_usd: ?i64 = null,
};

/// One size a new sandbox can be (`PersonalSize`).
pub const Size = struct {
    id: []const u8 = "",
    cpu: u32 = 0,
    memory_gib: u32 = 0,
    disk_gib: u32 = 0,
    price_per_hour_micro_usd: ?i64 = null,
    default: bool = false,
};

/// `CodegraffSandboxes`: `enabled` false means no cloud sandboxes here.
pub const List = struct {
    enabled: bool = false,
    sandboxes: []const Sandbox = &.{},
    sizes: []const Size = &.{},
};

/// What a create says it costs, under the size choice.
pub const create_copy = "Keeps running until you turn it off. Billed per second from your Codegraff credit.";

/// Temporary API/tool machines, apart from persistent Harness devices.
pub const temporary_copy = "For API and tool tasks, not a Harness device. Uses our fleet with Daytona fallback. Fleet sandboxes are deleted after 30 minutes; Daytona auto-stops after 30 idle minutes. Delete when done. Billed from your Codegraff credit.";

/// Turn off's label, its in-progress label, and what it does.
pub const turn_off = .{ "Turn off", "Turning off…" };
pub const turn_off_hint = "Pauses it. Memory and files are kept; billing stops.";

const billed = "Billed per second until you turn it off";

// Reading the reply. Strings go into `ar`.

fn str(ar: Allocator, o: json.ObjectMap, key: []const u8) !?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) try ar.dupe(u8, v.string) else null;
}

fn num(o: json.ObjectMap, key: []const u8) ?f64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn flag(o: json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

/// An expiry as RFC 3339 text or unix seconds; anything else is unknown.
fn expiry(v: ?json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| rules.parseTime(s),
        .integer => |i| i * 1000,
        else => null,
    };
}

pub fn parseSandbox(ar: Allocator, o: json.ObjectMap) !Sandbox {
    const price = num(o, "pricePerHourMicroUsd");
    return .{
        .id = (try str(ar, o, "id")) orelse "",
        .provider = (try str(ar, o, "provider")) orelse "",
        .name = try str(ar, o, "name"),
        .state = (try str(ar, o, "state")) orelse "",
        .tier = try str(ar, o, "tier"),
        .expires_ms = expiry(o.get("expiresAt")),
        .harness = flag(o, "harness") orelse false,
        .device_name = try str(ar, o, "deviceName"),
        .keep_running = flag(o, "keepRunning"),
        .renew_error = try str(ar, o, "renewError"),
        .cpu = num(o, "cpu"),
        .memory_gib = num(o, "memoryGiB"),
        .disk_gib = num(o, "diskGiB"),
        .price_per_hour_micro_usd = if (price) |p| @intFromFloat(p) else null,
    };
}

/// `Option<CodegraffSandboxes>`: null when signed out (or not known).
pub fn parse(ar: Allocator, v: json.Value) !?List {
    if (v == .null) return null;
    if (v != .object) return error.Unexpected;
    const o = v.object;
    var list: std.ArrayList(Sandbox) = .empty;
    if (o.get("sandboxes")) |a| if (a == .array) for (a.array.items) |item| {
        if (item == .object) try list.append(ar, try parseSandbox(ar, item.object));
    };
    var sizes: std.ArrayList(Size) = .empty;
    if (o.get("sizes")) |a| if (a == .array) for (a.array.items) |item| {
        if (item == .object) try sizes.append(ar, try parseSize(ar, item.object));
    };
    return .{ .enabled = flag(o, "enabled") orelse false, .sandboxes = list.items, .sizes = sizes.items };
}

pub fn parseSize(ar: Allocator, s: json.ObjectMap) !Size {
    const price = num(s, "pricePerHourMicroUsd");
    return .{
        .id = (try str(ar, s, "id")) orelse "",
        .cpu = @intFromFloat(@max(num(s, "cpu") orelse 0, 0)),
        .memory_gib = @intFromFloat(@max(num(s, "memoryGiB") orelse 0, 0)),
        .disk_gib = @intFromFloat(@max(num(s, "diskGiB") orelse 0, 0)),
        .price_per_hour_micro_usd = if (price) |p| @intFromFloat(p) else null,
        .default = flag(s, "default") orelse false,
    };
}

// The rules.

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isTemporary(s: Sandbox) bool {
    return if (s.tier) |t| eq(t, "ephemeral") else false;
}

/// "4 GB", "0.5 GB".
fn formatGb(ar: Allocator, gib: f64) ![]u8 {
    if (gib == @trunc(gib)) return std.fmt.allocPrint(ar, "{d:.0} GB", .{gib});
    return std.fmt.allocPrint(ar, "{d} GB", .{@round(gib * 10.0) / 10.0});
}

/// "Standard", "Large", or the id capitalised.
pub fn sizeTitle(ar: Allocator, s: Size) ![]const u8 {
    return capitalize(ar, std.mem.trim(u8, s.id, " \t\n"));
}

/// "2 vCPU · 4 GB · 40 GB · $0.10/h".
pub fn sizeDetail(ar: Allocator, s: Size) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    if (try runners.machineSpec(ar, @floatFromInt(s.cpu), @floatFromInt(s.memory_gib))) |spec| try parts.append(ar, spec);
    if (s.disk_gib > 0) try parts.append(ar, try formatGb(ar, @floatFromInt(s.disk_gib)));
    if (s.price_per_hour_micro_usd) |p| try parts.append(ar, try runners.formatRate(ar, p));
    return std.mem.join(ar, " · ", parts.items);
}

/// The size a create uses: the one picked, else the default, else the
/// first; null with no sizes.
pub fn selectedSize(sizes: []const Size, picked: ?[]const u8) ?Size {
    if (picked) |id| for (sizes) |s| if (eq(s.id, id)) return s;
    for (sizes) |s| if (s.default) return s;
    return if (sizes.len > 0) sizes[0] else null;
}

fn live(s: Sandbox) bool {
    return eq(s.state, "running") or eq(s.state, "starting");
}

/// What the running (and starting) ones cost together per hour, when every
/// one of them says.
pub fn runningRate(list: List) ?i64 {
    var total: i64 = 0;
    var any = false;
    for (list.sandboxes) |s| if (live(s)) {
        any = true;
        total += s.price_per_hour_micro_usd orelse return null;
    };
    return if (any) total else null;
}

pub fn title(s: Sandbox) []const u8 {
    for ([_]?[]const u8{ s.name, s.device_name }) |n| if (n) |x| {
        const t = std.mem.trim(u8, x, " \t\n");
        if (t.len > 0) return t;
    };
    return if (isTemporary(s)) "Temporary sandbox" else "Cloud sandbox";
}

/// Paused fleet ones start; a running one that never got Harness is set
/// up again.
pub fn canStart(s: Sandbox) bool {
    return eq(s.provider, "fleet") and !isTemporary(s) and (eq(s.state, "paused") or (eq(s.state, "running") and !s.harness));
}

/// Start's label and its in-progress label.
pub fn startLabels(s: Sandbox) [2][]const u8 {
    return if (eq(s.state, "running")) .{ "Set up Harness", "Setting up…" } else .{ "Start", "Starting…" };
}

pub fn canStop(s: Sandbox) bool {
    return eq(s.state, "running") and !isTemporary(s);
}

/// A running fleet sandbox that will pause when its window ends.
pub fn canKeepRunning(s: Sandbox) bool {
    return eq(s.provider, "fleet") and !isTemporary(s) and eq(s.state, "running") and s.keep_running != null and !s.keep_running.?;
}

fn keepsRunning(s: Sandbox) bool {
    return s.keep_running != null and s.keep_running.? and renewProblem(s) == null;
}

/// The renewal failure in the app's words.
fn renewProblem(s: Sandbox) ?[]const u8 {
    const e = std.mem.trim(u8, s.renew_error orelse return null, " \t\n");
    if (e.len == 0) return null;
    if (eq(e, "insufficient_credit") or eq(e, "insufficient_credits")) return "Out of credit";
    if (eq(e, "key_budget")) return "Key budget reached";
    return "Couldn't renew";
}

/// "pauses in 24 min", "pauses in 2h 5m", "lease ended".
fn leaseRemaining(ar: Allocator, at_ms: i64, now_ms: i64) ![]const u8 {
    // chrono's `num_minutes` truncates toward zero.
    const m = @divTrunc(at_ms - now_ms, 60_000);
    if (m < 0) return "lease ended";
    if (m == 0) return "pauses in under a minute";
    if (m < 60) return std.fmt.allocPrint(ar, "pauses in {d} min", .{@as(u64, @intCast(m))});
    return std.fmt.allocPrint(ar, "pauses in {d}h {d}m", .{ @as(u64, @intCast(@divFloor(m, 60))), @as(u64, @intCast(@mod(m, 60))) });
}

/// When a running one stops on its own (`running_outlook`); null unknown.
fn runningOutlook(ar: Allocator, s: Sandbox, now_ms: i64) !?[]const u8 {
    if (isTemporary(s)) {
        if (!eq(s.provider, "fleet")) return "auto-stops after 30 idle min; delete when done";
        const ends = s.expires_ms orelse return "temporary — delete when done";
        const lease = try leaseRemaining(ar, ends, now_ms);
        return std.mem.replaceOwned(u8, ar, lease, "pauses", "deletes") catch lease;
    }
    const lease: ?[]const u8 = if (s.expires_ms) |ends| try leaseRemaining(ar, ends, now_ms) else null;
    if (renewProblem(s)) |problem| {
        return if (lease) |l| try std.fmt.allocPrint(ar, "{s} — {s}", .{ problem, l }) else problem;
    }
    if (keepsRunning(s)) return "keeps running until you turn it off";
    return lease;
}

/// "Running · Harness ready · keeps running until you turn it off".
pub fn detail(ar: Allocator, s: Sandbox, now_ms: i64) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const st = s.state;
    try parts.append(ar, if (eq(st, "running"))
        "Running"
    else if (eq(st, "starting"))
        "Starting…"
    else if (eq(st, "paused"))
        (if (eq(s.provider, "fleet")) "Paused — memory and files kept" else "Paused")
    else if (eq(st, "stopping"))
        "Stopping…"
    else if (eq(st, "error"))
        "Error"
    else if (st.len == 0 or eq(st, "unknown"))
        "Unknown state"
    else
        st);
    if (eq(st, "running")) {
        const spec = try runners.machineSpec(ar, s.cpu, s.memory_gib);
        const rate: ?[]const u8 = if (s.price_per_hour_micro_usd) |p| try runners.formatRate(ar, p) else null;
        // With its machine and rate to say, a ready one goes without "Harness ready".
        if (isTemporary(s)) {
            try parts.append(ar, if (eq(s.provider, "fleet")) "Temporary · Our fleet" else "Temporary · Daytona");
        } else if (!s.harness) {
            try parts.append(ar, "Harness not set up");
        } else if (spec == null and rate == null) {
            try parts.append(ar, "Harness ready");
        }
        if (spec) |x| try parts.append(ar, x);
        if (rate) |x| try parts.append(ar, x);
        if (try runningOutlook(ar, s, now_ms)) |o| try parts.append(ar, o);
    }
    return std.mem.join(ar, " · ", parts.items);
}

/// What the always-visible strip says while sandboxes cost credit.
pub const Summary = struct {
    label: []const u8,
    detail: []const u8,
    warning: bool,
    /// What "Turn off" pauses: every running one (none with a temporary).
    running_ids: []const []const u8,
};

/// Null while nothing runs or starts (`running_summary`).
pub fn runningSummary(ar: Allocator, list: List, now_ms: i64) !?Summary {
    if (!list.enabled) return null;
    var lives: std.ArrayList(Sandbox) = .empty;
    for (list.sandboxes) |s| if (live(s)) try lives.append(ar, s);
    if (lives.items.len == 0) return null;
    var label: []const u8 = if (lives.items.len == 1)
        (if (eq(lives.items[0].state, "starting")) "Cloud sandbox starting" else "Cloud sandbox running")
    else
        try std.fmt.allocPrint(ar, "{d} cloud sandboxes running", .{lives.items.len});
    if (runningRate(list)) |r| label = try std.fmt.allocPrint(ar, "{s} · {s}", .{ label, try runners.formatRate(ar, r) });
    var running: std.ArrayList(Sandbox) = .empty;
    for (lives.items) |s| if (canStop(s)) try running.append(ar, s);
    var problem: ?[]const u8 = null;
    for (running.items) |s| if (renewProblem(s) != null) {
        problem = try runningOutlook(ar, s, now_ms);
        break;
    };
    var temporary = false;
    for (lives.items) |s| temporary = temporary or isTemporary(s);
    var warning = false;
    const text: []const u8 = if (problem) |p| blk: {
        warning = true;
        break :blk p;
    } else if (temporary and lives.items.len == 1)
        try capitalize(ar, (try runningOutlook(ar, lives.items[0], now_ms)) orelse "Temporary sandbox")
    else if (temporary)
        "Includes temporary sandboxes — manage in Settings"
    else blk: {
        for (running.items) |s| if (!keepsRunning(s)) {
            if (try runningOutlook(ar, s, now_ms)) |lease| if (std.mem.startsWith(u8, lease, "pauses")) break :blk try capitalize(ar, lease);
            break;
        };
        break :blk billed;
    };
    var ids: std.ArrayList([]const u8) = .empty;
    if (!temporary) for (running.items) |s| try ids.append(ar, s.id);
    return .{ .label = label, .detail = text, .warning = warning, .running_ids = ids.items };
}

/// The collapsed-sidebar chip's hover text.
pub fn compactTooltip(ar: Allocator, s: Summary) ![]const u8 {
    if (eq(s.detail, billed)) return std.fmt.allocPrint(ar, "{s} — billed per second", .{s.label});
    return std.fmt.allocPrint(ar, "{s} — {s}", .{ s.label, s.detail });
}

/// Anything running, starting or stopping changes on its own, so the list
/// is read again while one is (`needs_refresh`).
pub fn needsRefresh(list: List) bool {
    if (!list.enabled) return false;
    for (list.sandboxes) |s| if (live(s) or eq(s.state, "stopping")) return true;
    return false;
}

fn capitalize(ar: Allocator, text: []const u8) ![]const u8 {
    if (text.len == 0) return "";
    const out = try ar.dupe(u8, text);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// The GPUI app's tests, case for case.

const testing = std.testing;

/// 2026-10-01 at h:m UTC.
fn at(h: i64, m: i64) i64 {
    return rules.parseTime("2026-10-01T00:00:00Z").? + (h * 60 + m) * 60_000;
}

fn sandbox(state: []const u8, harness: bool, expires: ?[]const u8) Sandbox {
    return .{ .id = "cnd_1", .provider = "fleet", .name = "Harness cloud", .state = state, .harness = harness, .expires_ms = if (expires) |e| rules.parseTime(e) else null };
}

fn kept(expires: []const u8, renew_error: ?[]const u8) Sandbox {
    var s = sandbox("running", true, expires);
    s.keep_running = renew_error == null;
    s.renew_error = renew_error;
    return s;
}

fn listOf(sbs: []const Sandbox) List {
    return .{ .enabled = true, .sandboxes = sbs };
}

test "temporary sandboxes are not persistent Harness devices" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    var temporary = sandbox("running", false, "2026-10-01T12:30:00Z");
    temporary.tier = "ephemeral";
    temporary.keep_running = false;
    temporary.name = null;
    try testing.expectEqualStrings("Temporary sandbox", title(temporary));
    try testing.expect(!canStart(temporary) and !canStop(temporary) and !canKeepRunning(temporary));
    try testing.expectEqualStrings("Running · Temporary · Our fleet · deletes in 30 min", try detail(ar, temporary, at(12, 0)));
    const summary = (try runningSummary(ar, listOf(&.{temporary}), at(12, 0))).?;
    try testing.expectEqualStrings("Deletes in 30 min", summary.detail);
    try testing.expectEqual(@as(usize, 0), summary.running_ids.len);
    const mixed = (try runningSummary(ar, listOf(&.{ temporary, kept("2026-10-01T12:30:00Z", null) }), at(12, 0))).?;
    try testing.expectEqual(@as(usize, 0), mixed.running_ids.len);
    temporary.provider = "daytona";
    temporary.expires_ms = null;
    try testing.expectEqualStrings("Running · Temporary · Daytona · auto-stops after 30 idle min; delete when done", try detail(ar, temporary, at(12, 0)));
    try testing.expect(!canStop(temporary) and !canStart(temporary));
}

test "kept-running rows say so instead of counting down; failed renewals say why" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try testing.expectEqualStrings("Running · Harness ready · keeps running until you turn it off", try detail(ar, kept("2026-10-01T12:24:00Z", null), at(12, 0)));
    var off = kept("2026-10-01T12:24:00Z", null);
    off.keep_running = false;
    try testing.expectEqualStrings("Running · Harness ready · pauses in 24 min", try detail(ar, off, at(12, 0)));
    const cases = [_][2][]const u8{ .{ "insufficient_credit", "Out of credit" }, .{ "key_budget", "Key budget reached" }, .{ "fleet_unavailable", "Couldn't renew" }, .{ "something_new", "Couldn't renew" } };
    for (cases) |c| {
        const want = try std.fmt.allocPrint(ar, "Running · Harness ready · {s} — pauses in 4 min", .{c[1]});
        try testing.expectEqualStrings(want, try detail(ar, kept("2026-10-01T12:04:00Z", c[0]), at(12, 0)));
    }
    var no_expiry = kept("x", "insufficient_credit");
    no_expiry.expires_ms = null;
    try testing.expectEqualStrings("Running · Harness ready · Out of credit", try detail(ar, no_expiry, at(12, 0)));
    var both = kept("2026-10-01T12:04:00Z", "key_budget");
    both.keep_running = true;
    try testing.expect(std.mem.endsWith(u8, try detail(ar, both, at(12, 0)), "Key budget reached — pauses in 4 min"));
}

test "only running fleet sandboxes that will pause offer Keep running" {
    var off = kept("2026-10-01T12:04:00Z", "insufficient_credit");
    try testing.expect(canKeepRunning(off));
    off.provider = "daytona";
    try testing.expect(!canKeepRunning(off));
    try testing.expect(!canKeepRunning(kept("2026-10-01T12:04:00Z", null)));
    // Older gateways say nothing, so nothing is offered.
    try testing.expect(!canKeepRunning(sandbox("running", true, null)));
    var paused = sandbox("paused", true, null);
    paused.keep_running = false;
    try testing.expect(!canKeepRunning(paused));
}

test "the strip shows only while something runs, its most pressing word first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const now = at(12, 0);
    try testing.expect((try runningSummary(ar, listOf(&.{}), now)) == null);
    try testing.expect((try runningSummary(ar, listOf(&.{sandbox("paused", true, null)}), now)) == null);
    var off = listOf(&.{kept("2026-10-01T12:24:00Z", null)});
    off.enabled = false;
    try testing.expect((try runningSummary(ar, off, now)) == null);
    try testing.expect(!needsRefresh(off));
    const one = (try runningSummary(ar, listOf(&.{kept("2026-10-01T12:24:00Z", null)}), now)).?;
    try testing.expectEqualStrings("Cloud sandbox running", one.label);
    try testing.expectEqualStrings(billed, one.detail);
    try testing.expect(!one.warning);
    try testing.expectEqualStrings("cnd_1", one.running_ids[0]);
    try testing.expectEqualStrings("Cloud sandbox running — billed per second", try compactTooltip(ar, one));

    var other = kept("2026-10-01T12:24:00Z", null);
    other.id = "cnd_2";
    const two = (try runningSummary(ar, listOf(&.{ other, kept("2026-10-01T12:04:00Z", "insufficient_credit") }), now)).?;
    try testing.expectEqualStrings("2 cloud sandboxes running", two.label);
    try testing.expectEqualStrings("Out of credit — pauses in 4 min", two.detail);
    try testing.expect(two.warning);
    try testing.expectEqual(@as(usize, 2), two.running_ids.len);
    try testing.expectEqualStrings("2 cloud sandboxes running — Out of credit — pauses in 4 min", try compactTooltip(ar, two));
    // An older gateway: the window's end is the news.
    const old = (try runningSummary(ar, listOf(&.{sandbox("running", true, "2026-10-01T12:24:00Z")}), now)).?;
    try testing.expectEqualStrings("Pauses in 24 min", old.detail);
    const starting = (try runningSummary(ar, listOf(&.{sandbox("starting", false, null)}), now)).?;
    try testing.expectEqualStrings("Cloud sandbox starting", starting.label);
    try testing.expectEqual(@as(usize, 0), starting.running_ids.len);
}

test "the list is read again only while something can change on its own" {
    try testing.expect(!needsRefresh(listOf(&.{sandbox("paused", true, null)})));
    for ([_][]const u8{ "running", "starting", "stopping" }) |state| try testing.expect(needsRefresh(listOf(&.{sandbox(state, true, null)})));
}

test "rows: the lease's end, paused state kept, unix-second expiries, in-between states" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try testing.expectEqualStrings("Running · Harness ready · pauses in 24 min", try detail(ar, sandbox("running", true, "2026-10-01T12:24:00Z"), at(12, 0)));
    try testing.expect(std.mem.endsWith(u8, try detail(ar, sandbox("running", true, "2026-10-01T14:05:00Z"), at(12, 0)), "pauses in 2h 5m"));
    try testing.expectEqualStrings("Running · Harness not set up · lease ended", try detail(ar, sandbox("running", false, "2026-10-01T11:00:00Z"), at(12, 0)));
    const paused = sandbox("paused", true, "2026-10-01T12:24:00Z");
    try testing.expectEqualStrings("Paused — memory and files kept", try detail(ar, paused, at(12, 0)));
    var daytona = paused;
    daytona.provider = "daytona";
    try testing.expectEqualStrings("Paused", try detail(ar, daytona, at(12, 0)));
    const p = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"state": "running", "provider": "fleet", "expiresAt": 1790856600}, {"state": "running", "provider": "fleet", "expiresAt": "soon"}]
    , .{});
    defer p.deinit();
    const unix = try parseSandbox(ar, p.value.array.items[0].object);
    try testing.expect(std.mem.endsWith(u8, try detail(ar, unix, 1790856000_000), "pauses in 10 min"));
    try testing.expectEqualStrings("Running · Harness not set up", try detail(ar, try parseSandbox(ar, p.value.array.items[1].object), at(12, 0)));
    for ([_][]const u8{ "starting", "stopping", "error" }) |state| {
        const s = sandbox(state, false, null);
        try testing.expect(!canStart(s) and !canStop(s));
    }
    try testing.expectEqualStrings("Starting…", try detail(ar, sandbox("starting", false, null), at(12, 0)));
    try testing.expectEqualStrings("Stopping…", try detail(ar, sandbox("stopping", false, null), at(12, 0)));
}

test "start, set up, stop: which fleet sandboxes offer what" {
    const unready = sandbox("running", false, null);
    try testing.expect(canStart(unready));
    try testing.expectEqualStrings("Set up Harness", startLabels(unready)[0]);
    try testing.expectEqualStrings("Setting up…", startLabels(unready)[1]);
    try testing.expectEqualStrings("Start", startLabels(sandbox("paused", true, null))[0]);
    try testing.expect(canStart(sandbox("paused", true, null)));
    try testing.expect(!canStart(sandbox("running", true, null)));
    var daytona = sandbox("paused", false, null);
    daytona.provider = "daytona";
    try testing.expect(!canStart(daytona));
    try testing.expect(canStop(sandbox("running", true, null)));
    try testing.expect(!canStop(sandbox("paused", true, null)));
}

test "titles fall back, and the engine's answer parses" {
    var s = sandbox("running", true, null);
    s.name = "  ";
    try testing.expectEqualStrings("Cloud sandbox", title(s));
    s.device_name = "Harness cloud ab12";
    try testing.expectEqualStrings("Harness cloud ab12", title(s));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"enabled": true, "sandboxes": [{"id": "cnd_1", "provider": "fleet", "state": "paused", "future": 1}]}
    , .{});
    defer p.deinit();
    const list = (try parse(arena.allocator(), p.value)).?;
    try testing.expect(list.enabled);
    try testing.expectEqualStrings("paused", list.sandboxes[0].state);
    const empty = try json.parseFromSlice(json.Value, testing.allocator, "{}", .{});
    defer empty.deinit();
    try testing.expect(!(try parse(arena.allocator(), empty.value)).?.enabled);
    try testing.expect((try parse(arena.allocator(), .null)) == null);
}

test "rows show the machine and rate; the summed rate only when every running one has a price" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const priced = struct {
        fn f(id: []const u8, state: []const u8, price: ?i64) Sandbox {
            var s = sandbox(state, true, null);
            s.id = id;
            s.keep_running = true;
            s.price_per_hour_micro_usd = price;
            s.cpu = 2;
            s.memory_gib = 4;
            return s;
        }
    }.f;
    const row = priced("cnd_1", "running", 100_000);
    try testing.expectEqualStrings("Running · 2 vCPU · 4 GB · $0.10/h · keeps running until you turn it off", try detail(ar, row, at(12, 0)));
    var unready = row;
    unready.harness = false;
    try testing.expect(std.mem.startsWith(u8, try detail(ar, unready, at(12, 0)), "Running · Harness not set up · 2 vCPU · 4 GB · $0.10/h"));
    var unpriced = row;
    unpriced.price_per_hour_micro_usd = null;
    try testing.expectEqualStrings("Running · 2 vCPU · 4 GB · keeps running until you turn it off", try detail(ar, unpriced, at(12, 0)));
    const now = at(12, 0);
    const one = (try runningSummary(ar, listOf(&.{priced("a", "running", 100_000)}), now)).?;
    try testing.expectEqualStrings("Cloud sandbox running · $0.10/h", one.label);
    try testing.expectEqualStrings("Cloud sandbox running · $0.10/h — billed per second", try compactTooltip(ar, one));
    const two = (try runningSummary(ar, listOf(&.{ priced("a", "running", 100_000), priced("b", "running", 200_000), priced("c", "paused", 900_000) }), now)).?;
    try testing.expectEqualStrings("2 cloud sandboxes running · $0.30/h", two.label);
    const partly = listOf(&.{ priced("a", "running", 100_000), priced("b", "running", null) });
    try testing.expect(runningRate(partly) == null);
    try testing.expectEqualStrings("2 cloud sandboxes running", (try runningSummary(ar, partly, now)).?.label);
    const starting = (try runningSummary(ar, listOf(&.{priced("a", "starting", 100_000)}), now)).?;
    try testing.expectEqualStrings("Cloud sandbox starting · $0.10/h", starting.label);
    try testing.expect(runningRate(listOf(&.{})) == null);
}

test "a create offers the sizes with the default preselected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const p = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"enabled": true, "sandboxes": [], "sizes": [
        \\ {"id": "standard", "cpu": 2, "memoryGiB": 4, "diskGiB": 40, "pricePerHourMicroUsd": 100000, "default": true},
        \\ {"id": "large", "cpu": 4, "memoryGiB": 8, "diskGiB": 40, "pricePerHourMicroUsd": 200000}]}
    , .{});
    defer p.deinit();
    const sizes = (try parse(ar, p.value)).?.sizes;
    try testing.expectEqual(@as(usize, 2), sizes.len);
    try testing.expectEqualStrings("standard", selectedSize(sizes, null).?.id);
    try testing.expectEqualStrings("large", selectedSize(sizes, "large").?.id);
    try testing.expectEqualStrings("standard", selectedSize(sizes, "gone").?.id);
    try testing.expect(selectedSize(&.{}, null) == null);
    try testing.expectEqualStrings("Large", try sizeTitle(ar, sizes[1]));
    try testing.expectEqualStrings("2 vCPU · 4 GB · 40 GB · $0.10/h", try sizeDetail(ar, sizes[0]));
    try testing.expectEqualStrings("4 vCPU · 8 GB · 40 GB · $0.20/h", try sizeDetail(ar, sizes[1]));
    try testing.expectEqualStrings("1 vCPU · 2 GB", try sizeDetail(ar, .{ .id = "x", .cpu = 1, .memory_gib = 2 }));
}
