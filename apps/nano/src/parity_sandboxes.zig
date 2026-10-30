//! harness-nano's runner for apps/parity/vectors/cloud-sandbox.json: the
//! cloud sandbox rows, rates, sizes and running summaries the GPUI app runs
//! the same file for (crates/ui/src/codegraff_sandboxes.rs,
//! `the_shared_vector_rows`, `the_shared_vector_rates_sizes_and_summaries`).
//! The file is read from the repository at test time, never copied.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const sandboxes = @import("sandboxes.zig");
const runners = @import("runners.zig");
const dir = @import("parity_options").vectors_dir;

fn load(arena: std.mem.Allocator) !json.Value {
    const path = try std.fs.path.join(arena, &.{ dir, "cloud-sandbox.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, arena, .limited(4 << 20));
    return json.parseFromSliceLeaky(json.Value, arena, text, .{});
}

fn items(v: json.Value, key: []const u8) []const json.Value {
    return v.object.get(key).?.array.items;
}

fn str(v: json.Value, key: []const u8) []const u8 {
    return v.object.get(key).?.string;
}

/// The vector's `now`, in ms.
fn nowMs(v: json.Value) i64 {
    return v.object.get("now").?.integer * 1000;
}

fn expectCase(want: []const u8, got: []const u8, case: json.Value) !void {
    testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("case: {f}\n", .{std.json.fmt(case, .{})});
        return e;
    };
}

test "cloud-sandbox.json: rows' titles, details and buttons" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try load(a);
    const now = nowMs(v);
    for (items(v, "rows")) |case| {
        const s = try sandboxes.parseSandbox(a, case.object.get("sandbox").?.object);
        try expectCase(str(case, "title"), sandboxes.title(s), case);
        try expectCase(str(case, "detail"), try sandboxes.detail(a, s, now), case);
        const can_start = case.object.get("canStart").?.bool;
        try testing.expectEqual(can_start, sandboxes.canStart(s));
        try testing.expectEqual(case.object.get("canStop").?.bool, sandboxes.canStop(s));
        if (can_start) try expectCase(str(case, "startLabel"), sandboxes.startLabels(s)[0], case);
    }
}

test "cloud-sandbox.json: rates, size choices and the running strip's words" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const v = try load(a);
    for (items(v, "rates")) |case| {
        try expectCase(str(case, "text"), try runners.formatRate(a, case.object.get("microUsd").?.integer), case);
    }
    for (items(v, "sizeChoices")) |case| {
        const size = try sandboxes.parseSize(a, case.object.get("size").?.object);
        try expectCase(str(case, "title"), try sandboxes.sizeTitle(a, size), case);
        try expectCase(str(case, "detail"), try sandboxes.sizeDetail(a, size), case);
    }
    const now = nowMs(v);
    for (items(v, "summaries")) |case| {
        var list: std.ArrayList(sandboxes.Sandbox) = .empty;
        for (items(case, "sandboxes")) |s| try list.append(a, try sandboxes.parseSandbox(a, s.object));
        const sum = (try sandboxes.runningSummary(a, .{ .enabled = true, .sandboxes = list.items }, now)).?;
        try expectCase(str(case, "label"), sum.label, case);
        try expectCase(str(case, "detail"), sum.detail, case);
        try expectCase(str(case, "tooltip"), try sandboxes.compactTooltip(a, sum), case);
    }
}
