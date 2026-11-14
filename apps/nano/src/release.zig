//! The newest Harness release, from the manifest its release job attaches
//! to every GitHub release (crates/update/src/lib.rs: `{base}/manifest.json`).
//! The UI owns an hourly wall-clock schedule, independent of engine updates.
//! nanoui.http uses the native system client on macOS and a bounded portable
//! client elsewhere, with results delivered on the UI thread.
const std = @import("std");
const nanoui = @import("nanoui");
const Allocator = std.mem.Allocator;

pub const manifest_url = "https://github.com/justrach/harness/releases/latest/download/manifest.json";
pub const hour_ms: i64 = 60 * 60 * 1000;

/// UI-thread state, driven by real (not awake/monotonic) milliseconds. After
/// three short retries, an outage returns to hourly checks rather than spinning.
pub const Schedule = struct {
    due_ms: ?i64 = null,
    in_flight: bool = false,
    failures: u8 = 0,

    pub fn due(s: *const Schedule, now_ms: i64) bool {
        const deadline = s.due_ms orelse return true;
        return now_ms >= deadline or deadline -| now_ms > hour_ms;
    }

    pub fn begin(s: *Schedule, now_ms: i64, manual: bool) bool {
        if (s.in_flight or (!manual and !s.due(now_ms))) return false;
        s.in_flight = true;
        return true;
    }

    pub fn complete(s: *Schedule, now_ms: i64, ok: bool) void {
        s.in_flight = false;
        s.failures = if (ok) 0 else @min(s.failures +| 1, 4);
        const delay: i64 = switch (s.failures) {
            1 => 60_000,
            2 => 5 * 60_000,
            3 => 15 * 60_000,
            else => hour_ms,
        };
        s.due_ms = now_ms +| delay;
    }

    /// Wake at least once a minute to notice sleep and wall-clock changes.
    /// This only schedules a cheap tick; begin() gates actual network work.
    pub fn delaySeconds(s: *const Schedule, now_ms: i64) f32 {
        if (s.in_flight) return 60;
        if (s.due(now_ms)) return 1;
        return @floatFromInt(@min(60, @max(1, @divFloor(s.due_ms.? -| now_ms, 1000))));
    }
};

pub const Check = struct {
    gpa: Allocator,
    io: std.Io,
    /// `version` from the last successful manifest, retained when offline.
    latest: [32]u8 = undefined,
    latest_len: usize = 0,
    schedule: Schedule = .{},
    succeeded: bool = false,
    /// Called on the UI thread after success or failure.
    done: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    pub fn version(c: *const Check) ?[]const u8 {
        return if (c.latest_len == 0) null else c.latest[0..c.latest_len];
    }

    /// Explicit startup/manual check. Concurrent requests coalesce.
    /// `c` must stay where it is until the response callback completes.
    pub fn start(c: *Check) void {
        _ = c.request(true);
    }

    pub fn startIfDue(c: *Check) bool {
        return c.request(false);
    }

    fn request(c: *Check, manual: bool) bool {
        if (!c.schedule.begin(std.Io.Clock.real.now(c.io).toMilliseconds(), manual)) return false;
        // Native NSURLSession on macOS; bounded portable client elsewhere.
        // Both deliver on the UI thread, so a worker never mutates version().
        nanoui.http.fetch(c.gpa, .{
            .url = manifest_url,
            .headers = &.{.{ .name = "User-Agent", .value = "harness-nano" }},
            .timeout = 30,
        }, c, loaded);
        return true;
    }

    fn loaded(c: *Check, r: nanoui.http.Response) void {
        c.succeeded = r.status == 200 and c.take(r.body);
        c.schedule.complete(std.Io.Clock.real.now(c.io).toMilliseconds(), c.succeeded);
        if (!c.succeeded) std.log.info("harness-nano: release manifest unavailable ({d})", .{r.status});
        if (c.done) |d| d.func(d.ctx);
    }

    /// Keeps a whole manifest version, never a truncated version string.
    fn take(c: *Check, body: []const u8) bool {
        const v = parseVersion(c.gpa, body) orelse return false;
        defer c.gpa.free(v);
        if (v.len > c.latest.len) return false;
        @memcpy(c.latest[0..v.len], v);
        c.latest_len = v.len;
        return true;
    }
};

/// The manifest's `version`, trimmed, or null.
pub fn parseVersion(gpa: Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(struct { version: []const u8 = "" }, gpa, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const v = std.mem.trim(u8, parsed.value.version, " \n\tv");
    if (v.len == 0) return null;
    return gpa.dupe(u8, v) catch null;
}

test "native updater checks hourly after sleep without overlapping or per-frame requests" {
    if (!@hasDecl(Check, "startIfDue")) return error.NativeReleaseCheckHasNoCadence;
    if (@hasDecl(Check, "startIfDue")) {
        var s: @FieldType(Check, "schedule") = .{};
        const interval_ms: i64 = 60 * 60 * 1000;
        try std.testing.expect(s.begin(1000, false));
        try std.testing.expect(!s.begin(1001, true)); // Manual and timer coalesce.
        s.complete(1000, true);
        for (0..10_000) |i| try std.testing.expect(!s.begin(1001 + @as(i64, @intCast(i)), false));
        try std.testing.expect(!s.begin(1000 + interval_ms - 1, false));
        try std.testing.expect(s.begin(1000 + interval_ms, false));
        s.complete(1000 + interval_ms, true);
        // Sleeping for hours creates one check, never a catch-up burst.
        try std.testing.expect(s.begin(1000 + 12 * interval_ms, false));
        try std.testing.expect(!s.begin(1000 + 12 * interval_ms, false));
        s.complete(1000 + 12 * interval_ms, true);
        // A clock adjustment backwards must not suppress checks indefinitely.
        try std.testing.expect(s.begin(0, false));
    }
}

test "the manifest's version, and none from a manifest without one" {
    const gpa = std.testing.allocator;
    const v = parseVersion(gpa, "{\"version\":\"0.2.136\",\"artifacts\":{}}").?;
    defer gpa.free(v);
    try std.testing.expectEqualStrings("0.2.136", v);
    try std.testing.expect(parseVersion(gpa, "{\"version\":\" \"}") == null);
    try std.testing.expect(parseVersion(gpa, "not json") == null);
}

test "native updater failed or malformed manifests preserve the last successful version" {
    var c: Check = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    try std.testing.expect(c.take("{\"version\":\"1.2.3\"}"));
    try std.testing.expect(!c.take("{\"version\":\"123456789012345678901234567890123\"}"));
    c.schedule.in_flight = true;
    Check.loaded(&c, .{ .status = 503, .body = "" });
    try std.testing.expect(!c.succeeded);
    try std.testing.expect(!c.schedule.in_flight);
    try std.testing.expectEqual(@as(u8, 1), c.schedule.failures);
    try std.testing.expectEqualStrings("1.2.3", c.version().?);
    Check.loaded(&c, .{ .status = 200, .body = "not json" });
    try std.testing.expect(!c.succeeded);
    try std.testing.expectEqual(@as(u8, 2), c.schedule.failures);
    Check.loaded(&c, .{ .status = 200, .body = "{\"version\":\"1.2.4\"}" });
    try std.testing.expect(c.succeeded);
    try std.testing.expectEqual(@as(u8, 0), c.schedule.failures);
    try std.testing.expectEqualStrings("1.2.4", c.version().?);
}

test "native updater retries are bounded and success resets the hourly cadence" {
    var s: Schedule = .{};
    var now: i64 = 10_000;
    const delays = [_]i64{ 60_000, 5 * 60_000, 15 * 60_000, hour_ms, hour_ms };
    for (delays) |delay| {
        try std.testing.expect(s.begin(now, false));
        s.complete(now, false);
        try std.testing.expectEqual(now + delay, s.due_ms.?);
        try std.testing.expect(!s.begin(now + delay - 1, false));
        try std.testing.expectEqual(@as(f32, 60), s.delaySeconds(now));
        now += delay;
    }
    try std.testing.expect(s.begin(now, false));
    s.complete(now, true);
    try std.testing.expectEqual(@as(u8, 0), s.failures);
    try std.testing.expectEqual(now + hour_ms, s.due_ms.?);
    // Explicit checks do not wait for the hour, but still coalesce.
    try std.testing.expect(s.begin(now + 1, true));
    try std.testing.expect(!s.begin(now + 2, true));
}
