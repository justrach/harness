//! Bounded, allocation-free desktop responsiveness aggregation. Only export
//! allocates. This module has no I/O, identifiers, environment or clock reads.
//! The caller owns consent, scheduling, transport and resetting delta windows.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const policy = @import("performance_policy.zig");

pub const Interaction = enum { scroll, input, animation, other };
pub const Panes = enum { single, split, many };
pub const Renderer = enum { metal, d3d11, opengl, cpu };
pub const Metric = enum { build, layout, paint, cpu, interval };
pub const Cohort = struct { interaction: Interaction, panes: Panes, renderer: Renderer };

/// Inclusive upper bounds in milliseconds; the last wire bucket is +infinity.
pub const bounds = [_]f64{ 1, 2, 4, 8.33, 16.67, 33, 50, 75, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000, 20000, 60000 };
pub const capacity = policy.capacity;
const metrics = std.meta.tags(Metric);
const interactions = std.meta.tags(Interaction);
const panes = std.meta.tags(Panes);
const renderers = std.meta.tags(Renderer);
comptime {
    if (bounds.len != policy.bucket_bounds or metrics.len * interactions.len * panes.len * renderers.len != policy.histogram_cells)
        @compileError("Telemetry dimensions changed: update Nano.Telemetry and its conformance gate");
}

const Histogram = struct {
    buckets: [bounds.len + 1]u32 = @splat(0),
    count: u32 = 0,
    sum: f64 = 0,
    max: f64 = 0,

    fn add(h: *Histogram, sample: f64) void {
        if (!std.math.isFinite(sample) or sample < 0 or h.count == capacity) return;
        const ms = @min(sample, bounds[bounds.len - 1]);
        var bucket: usize = 0;
        while (bucket < bounds.len and ms > bounds[bucket]) : (bucket += 1) {}
        h.buckets[bucket] += 1;
        h.count = policy.nextCount(h.count, true);
        h.sum += ms;
        h.max = @max(h.max, ms);
    }
};

pub const Window = struct {
    cells: [metrics.len][interactions.len][panes.len][renderers.len]Histogram = std.mem.zeroes([metrics.len][interactions.len][panes.len][renderers.len]Histogram),

    /// Samples beyond a cell's capacity are discarded, including their sum/max.
    /// Thus every exported statistic describes exactly the retained samples.
    pub fn add(w: *Window, metric: Metric, cohort: Cohort, ms: f64) void {
        w.cell(metric, cohort).add(ms);
    }

    pub fn empty(w: *const Window) bool {
        for (&w.cells) |*by_interaction| {
            for (by_interaction) |*by_panes| {
                for (by_panes) |*by_renderer| {
                    for (by_renderer) |*h| if (h.count != 0) return false;
                }
            }
        }
        return true;
    }

    fn cell(w: *Window, metric: Metric, cohort: Cohort) *Histogram {
        return &w.cells[@backingInt(metric)][@backingInt(cohort.interaction)][@backingInt(cohort.panes)][@backingInt(cohort.renderer)];
    }

    /// OTLP/HTTP JSON delta histograms. Caller frees the result. Does not drain
    /// the window: reset with `.{} ` only after the caller accepts the export.
    /// Timestamps are floored to whole minutes, clamped to the Unix epoch and
    /// ordered; nanoseconds use i128 so even extreme i64 inputs cannot overflow.
    pub fn json(w: *const Window, allocator: Allocator, version: []const u8, start_ms: i64, end_ms: i64) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const writer = &out.writer;
        const start = minuteNanos(start_ms);
        const end = @max(start, minuteNanos(end_ms));
        try writer.print(
            "{{\"resourceMetrics\":[{{\"resource\":{{\"attributes\":[" ++
                "{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"harness.desktop\"}}}}," ++
                "{{\"key\":\"service.version\",\"value\":{{\"stringValue\":\"{s}\"}}}}," ++
                "{{\"key\":\"os.type\",\"value\":{{\"stringValue\":\"{s}\"}}}}," ++
                "{{\"key\":\"host.arch\",\"value\":{{\"stringValue\":\"{s}\"}}}}]}}," ++
                "\"scopeMetrics\":[{{\"scope\":{{\"name\":\"harness.desktop\"}},\"metrics\":[",
            .{ releaseVersion(version), osType(), hostArch() },
        );
        var first_metric = true;
        for (metrics) |metric| {
            const cells = &w.cells[@backingInt(metric)];
            var first_point = true;
            for (interactions) |interaction| {
                for (panes) |pane| {
                    for (renderers) |renderer| {
                        const h = &cells[@backingInt(interaction)][@backingInt(pane)][@backingInt(renderer)];
                        if (h.count == 0) continue;
                        if (first_point) {
                            if (!first_metric) try writer.writeAll(",");
                            first_metric = false;
                            try writer.print("{{\"name\":\"harness.desktop.frame.{s}\",\"unit\":\"ms\",\"histogram\":{{\"aggregationTemporality\":1,\"dataPoints\":[", .{@tagName(metric)});
                        } else try writer.writeAll(",");
                        first_point = false;
                        try writer.print(
                            "{{\"attributes\":[" ++
                                "{{\"key\":\"harness.interaction\",\"value\":{{\"stringValue\":\"{s}\"}}}}," ++
                                "{{\"key\":\"harness.panes\",\"value\":{{\"stringValue\":\"{s}\"}}}}," ++
                                "{{\"key\":\"harness.renderer\",\"value\":{{\"stringValue\":\"{s}\"}}}}]," ++
                                "\"startTimeUnixNano\":\"{d}\",\"timeUnixNano\":\"{d}\",\"count\":\"{d}\",\"sum\":{d},\"max\":{d},\"bucketCounts\":[",
                            .{ @tagName(interaction), @tagName(pane), @tagName(renderer), start, end, h.count, h.sum, h.max },
                        );
                        for (h.buckets, 0..) |count, i| {
                            if (i != 0) try writer.writeAll(",");
                            try writer.print("\"{d}\"", .{count});
                        }
                        try writer.writeAll("],\"explicitBounds\":[");
                        for (bounds, 0..) |bound, i| {
                            if (i != 0) try writer.writeAll(",");
                            try writer.print("{d}", .{bound});
                        }
                        try writer.writeAll("]}");
                    }
                }
            }
            if (!first_point) try writer.writeAll("]}}");
        }
        try writer.writeAll("]}]}]}");
        return out.toOwnedSlice();
    }
};

/// Numeric, dot-separated release components only, at most 32 bytes. No
/// prefixes, prerelease/build labels, whitespace, empty or zero-padded parts.
/// Never truncate an invalid raw value: use the fixed unknown-version cohort.
fn releaseVersion(raw: []const u8) []const u8 {
    if (raw.len == 0 or raw.len > 32) return "0";
    var components = std.mem.splitScalar(u8, raw, '.');
    while (components.next()) |part| {
        if (part.len == 0 or (part.len > 1 and part[0] == '0')) return "0";
        for (part) |byte| if (byte < '0' or byte > '9') return "0";
    }
    return raw;
}

fn osType() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "windows",
        .linux => "linux",
        else => "unknown",
    };
}

fn hostArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => "arm64",
        .x86_64 => "amd64",
        .x86 => "x86",
        .arm, .armeb, .thumb, .thumbeb => "arm32",
        .riscv64 => "riscv64",
        else => "unknown",
    };
}

fn minuteNanos(ms: i64) i128 {
    return @as(i128, @divFloor(@max(ms, 0), 60_000)) * 60_000_000_000;
}

const testing = std.testing;
const test_cohort: Cohort = .{ .interaction = .scroll, .panes = .single, .renderer = .metal };

test "bucket upper bounds are inclusive and noncumulative" {
    var w: Window = .{};
    try testing.expect(w.empty());
    for (bounds, 0..) |bound, i| {
        w.add(.build, test_cohort, bound);
        try testing.expectEqual(@as(u32, 1), w.cell(.build, test_cohort).buckets[i]);
    }
    const h = w.cell(.build, test_cohort);
    try testing.expectEqual(@as(u32, 22), h.count);
    try testing.expectEqual(@as(u32, 0), h.buckets[bounds.len]);
    for (bounds[0 .. bounds.len - 1], 0..) |bound, i| {
        w.add(.build, test_cohort, bound + 0.000001);
        try testing.expectEqual(@as(u32, 2), h.buckets[i + 1]);
    }
    try testing.expect(!w.empty());
}

test "invalid samples rejected and large finite samples clamped" {
    var w: Window = .{};
    for ([_]f64{ -0.001, -1, -std.math.inf(f64), std.math.inf(f64), std.math.nan(f64) }) |ms| w.add(.paint, test_cohort, ms);
    try testing.expect(w.empty());
    w.add(.paint, test_cohort, 0);
    w.add(.paint, test_cohort, 60_001);
    w.add(.paint, test_cohort, std.math.floatMax(f64));
    const h = w.cell(.paint, test_cohort);
    try testing.expectEqual(@as(u32, 3), h.count);
    try testing.expectEqual(@as(u32, 1), h.buckets[0]);
    try testing.expectEqual(@as(u32, 2), h.buckets[bounds.len - 1]);
    try testing.expectEqual(@as(u32, 0), h.buckets[bounds.len]);
    try testing.expectEqual(@as(f64, 120_000), h.sum);
    try testing.expectEqual(@as(f64, 60_000), h.max);
}

test "saturation keeps count sum max and buckets consistent per cell" {
    var w: Window = .{};
    for (0..capacity + 5) |_| w.add(.cpu, test_cohort, 2);
    w.add(.cpu, test_cohort, 60_000);
    const h = w.cell(.cpu, test_cohort);
    try testing.expectEqual(capacity, h.count);
    try testing.expectEqual(capacity, h.buckets[1]);
    try testing.expectEqual(@as(f64, capacity * 2), h.sum);
    try testing.expectEqual(@as(f64, 2), h.max);
    w.add(.interval, test_cohort, 4);
    try testing.expectEqual(@as(u32, 1), w.cell(.interval, test_cohort).count);
    w = .{};
    try testing.expect(w.empty());
    // All dimensions and buckets have fixed storage, independent of history.
    try testing.expect(@sizeOf(Window) < 64 * 1024);
}

fn expectKeys(value: std.json.Value, keys: []const []const u8) !void {
    try testing.expectEqual(keys.len, value.object.count());
    for (keys) |key| try testing.expect(value.object.contains(key));
}

fn expectAttribute(value: std.json.Value, key: []const u8, text: []const u8) !void {
    try expectKeys(value, &.{ "key", "value" });
    try testing.expectEqualStrings(key, value.object.get("key").?.string);
    const attr = value.object.get("value").?;
    try expectKeys(attr, &.{"stringValue"});
    try testing.expectEqualStrings(text, attr.object.get("stringValue").?.string);
}

fn numeric(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .number_string => |v| std.fmt.parseFloat(f64, v) catch unreachable,
        else => unreachable,
    };
}

test "OTLP delta wire schema has additive counts and exact allowed attributes" {
    var w: Window = .{};
    for (metrics) |metric| {
        for (interactions) |interaction| {
            for (panes) |pane| {
                for (renderers) |renderer| {
                    const cohort: Cohort = .{ .interaction = interaction, .panes = pane, .renderer = renderer };
                    for ([_]f64{ 1, 1.5, 8.33, 120_000 }) |ms| w.add(metric, cohort, ms);
                }
            }
        }
    }
    const encoded = try w.json(testing.allocator, "0.2.123", 1_700_000_012_345, 1_700_000_123_456);
    defer testing.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, encoded, .{});
    defer parsed.deinit();
    try expectKeys(parsed.value, &.{"resourceMetrics"});
    const resources = parsed.value.object.get("resourceMetrics").?.array.items;
    try testing.expectEqual(@as(usize, 1), resources.len);
    try expectKeys(resources[0], &.{ "resource", "scopeMetrics" });
    const resource = resources[0].object.get("resource").?;
    try expectKeys(resource, &.{"attributes"});
    const attrs = resource.object.get("attributes").?.array.items;
    try testing.expectEqual(@as(usize, 4), attrs.len);
    try expectAttribute(attrs[0], "service.name", "harness.desktop");
    try expectAttribute(attrs[1], "service.version", "0.2.123");
    try expectAttribute(attrs[2], "os.type", osType());
    try expectAttribute(attrs[3], "host.arch", hostArch());
    const scopes = resources[0].object.get("scopeMetrics").?.array.items;
    try testing.expectEqual(@as(usize, 1), scopes.len);
    try expectKeys(scopes[0], &.{ "scope", "metrics" });
    const scope = scopes[0].object.get("scope").?;
    try expectKeys(scope, &.{"name"});
    try testing.expectEqualStrings("harness.desktop", scope.object.get("name").?.string);
    const wire_metrics = scopes[0].object.get("metrics").?.array.items;
    try testing.expectEqual(metrics.len, wire_metrics.len);
    var total: u64 = 0;
    for (wire_metrics, metrics) |wire_metric, metric| {
        try expectKeys(wire_metric, &.{ "name", "unit", "histogram" });
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "harness.desktop.frame.{s}", .{@tagName(metric)});
        try testing.expectEqualStrings(name, wire_metric.object.get("name").?.string);
        try testing.expectEqualStrings("ms", wire_metric.object.get("unit").?.string);
        const histogram = wire_metric.object.get("histogram").?;
        try expectKeys(histogram, &.{ "aggregationTemporality", "dataPoints" });
        try testing.expectEqual(@as(i64, 1), histogram.object.get("aggregationTemporality").?.integer);
        const points = histogram.object.get("dataPoints").?.array.items;
        try testing.expectEqual(interactions.len * panes.len * renderers.len, points.len);
        var index: usize = 0;
        for (interactions) |interaction| {
            for (panes) |pane| {
                for (renderers) |renderer| {
                    const point = points[index];
                    index += 1;
                    try expectKeys(point, &.{ "attributes", "startTimeUnixNano", "timeUnixNano", "count", "sum", "max", "bucketCounts", "explicitBounds" });
                    const point_attrs = point.object.get("attributes").?.array.items;
                    try testing.expectEqual(@as(usize, 3), point_attrs.len);
                    try expectAttribute(point_attrs[0], "harness.interaction", @tagName(interaction));
                    try expectAttribute(point_attrs[1], "harness.panes", @tagName(pane));
                    try expectAttribute(point_attrs[2], "harness.renderer", @tagName(renderer));
                    try testing.expectEqualStrings("1699999980000000000", point.object.get("startTimeUnixNano").?.string);
                    try testing.expectEqualStrings("1700000100000000000", point.object.get("timeUnixNano").?.string);
                    const count = try std.fmt.parseInt(u64, point.object.get("count").?.string, 10);
                    try testing.expectEqual(@as(u64, 4), count);
                    const buckets = point.object.get("bucketCounts").?.array.items;
                    try testing.expectEqual(bounds.len + 1, buckets.len);
                    var bucket_sum: u64 = 0;
                    for (buckets, 0..) |bucket, i| {
                        const n = try std.fmt.parseInt(u64, bucket.string, 10);
                        const expected: u64 = if (i == 0 or i == 1 or i == 3 or i == 21) 1 else 0;
                        try testing.expectEqual(expected, n);
                        bucket_sum += n;
                    }
                    try testing.expectEqual(count, bucket_sum);
                    total += count;
                    const wire_bounds = point.object.get("explicitBounds").?.array.items;
                    try testing.expectEqual(bounds.len, wire_bounds.len);
                    for (wire_bounds, bounds) |bound, expected| try testing.expectEqual(expected, numeric(bound));
                    try testing.expectApproxEqAbs(@as(f64, 60_010.83), numeric(point.object.get("sum").?), 0.000001);
                    try testing.expectEqual(@as(f64, 60_000), numeric(point.object.get("max").?));
                }
            }
        }
    }
    try testing.expectEqual(@as(u64, metrics.len * interactions.len * panes.len * renderers.len * 4), total);
    try testing.expect(!w.empty()); // Encoding is nondestructive.
}

test "version filtering rejects hostile and non-release values without leaking raw text" {
    const hostile = [_][]const u8{ "", "v0.2.3", "0.2.3-dev", "0.2.3+private", "0.2.3\n", "0.2.3\"},\"id\":\"synthetic", "1..2", ".1", "1.", "01.2.3", "1/2/3", "0.2.3 synthetic", "123456789012345678901234567890123", "\x00", "\xff" };
    var w: Window = .{};
    for (hostile) |version| {
        try testing.expectEqualStrings("0", releaseVersion(version));
        const encoded = try w.json(testing.allocator, version, 0, 0);
        defer testing.allocator.free(encoded);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, encoded, .{});
        defer parsed.deinit();
        const rm = parsed.value.object.get("resourceMetrics").?.array.items[0];
        const attrs = rm.object.get("resource").?.object.get("attributes").?.array.items;
        try expectAttribute(attrs[1], "service.version", "0");
        const wire_metrics = rm.object.get("scopeMetrics").?.array.items[0].object.get("metrics").?.array.items;
        try testing.expectEqual(@as(usize, 0), wire_metrics.len);
    }
    for ([_][]const u8{ "0", "1.2.3", "0.0.302.25", "12345678901234567890123456789012" }) |version| try testing.expectEqualStrings(version, releaseVersion(version));
}

test "timestamps are coarse ordered nonnegative and overflow safe" {
    try testing.expectEqual(@as(i128, 0), minuteNanos(std.math.minInt(i64)));
    try testing.expectEqual(@as(i128, 0), minuteNanos(59_999));
    try testing.expectEqual(@as(i128, 60_000_000_000), minuteNanos(60_000));
    try testing.expectEqual(minuteNanos(60_000), minuteNanos(119_999));
    try testing.expectEqual(@as(i128, 0), @mod(minuteNanos(std.math.maxInt(i64)), 60_000_000_000));
    var w: Window = .{};
    w.add(.interval, test_cohort, 16.67);
    const encoded = try w.json(testing.allocator, "1.2.3", std.math.maxInt(i64), -1);
    defer testing.allocator.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, encoded, .{});
    defer parsed.deinit();
    const point = parsed.value.object.get("resourceMetrics").?.array.items[0].object.get("scopeMetrics").?.array.items[0].object.get("metrics").?.array.items[0].object.get("histogram").?.object.get("dataPoints").?.array.items[0];
    const start = try std.fmt.parseInt(i128, point.object.get("startTimeUnixNano").?.string, 10);
    const end = try std.fmt.parseInt(i128, point.object.get("timeUnixNano").?.string, 10);
    try testing.expectEqual(minuteNanos(std.math.maxInt(i64)), start);
    try testing.expectEqual(start, end);
}
