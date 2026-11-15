//! Data-only native extension panels. Values and string slices borrow the caller's
//! JSON arena. No scripts, HTML evaluation, subprocesses, or native code loading.
//! Root depth is zero; text budget includes the title, labels and stat values,
//! but not kind names, plugin IDs or action IDs (matching the engine contract).
const std = @import("std");
pub const Value = std.json.Value;
pub const ValidationError = error{InvalidExtensionPanel};

pub const max_panels = 16;
pub const max_nodes = 64;
pub const max_depth = 8;
pub const max_text_bytes = 8192;

/// Safe renderer lookup, even on unvalidated input. Missing/wrong types are empty.
pub fn str(node: Value, key: []const u8) []const u8 {
    if (node != .object) return "";
    const value = node.object.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

fn requiredString(node: Value, key: []const u8) ValidationError![]const u8 {
    if (node != .object) return error.InvalidExtensionPanel;
    const value = node.object.get(key) orelse return error.InvalidExtensionPanel;
    if (value != .string) return error.InvalidExtensionPanel;
    return value.string;
}

fn identifier(id: []const u8) bool {
    if (id.len == 0 or id.len > 64 or id[0] == '-') return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.' and c != '-') return false;
    }
    return true;
}

/// Validate the versioned list transport, including the engine-added plugin ID.
pub fn validate(list: Value) ValidationError!void {
    if (list != .object) return error.InvalidExtensionPanel;
    const version = list.object.get("version") orelse return error.InvalidExtensionPanel;
    if (version != .integer or version.integer != 1) return error.InvalidExtensionPanel;
    const panels = list.object.get("panels") orelse return error.InvalidExtensionPanel;
    if (panels != .array or panels.array.items.len > max_panels) return error.InvalidExtensionPanel;
    for (panels.array.items) |panel| {
        if (!identifier(try requiredString(panel, "plugin"))) return error.InvalidExtensionPanel;
        try validatePanel(panel);
    }
}

/// Engine panel payloads omit plugin; validate() checks that list-level identity.
/// Extra fields are ignored, never interpreted, as in the engine validator.
pub fn validatePanel(panel: Value) ValidationError!void {
    const title = try requiredString(panel, "title");
    if (title.len == 0 or title.len > 120) return error.InvalidExtensionPanel;
    const root = panel.object.get("root") orelse return error.InvalidExtensionPanel;
    var budget: Budget = .{ .bytes = title.len };
    try validateNode(root, 0, &budget);
}

const Budget = struct {
    nodes: usize = 0,
    bytes: usize,

    fn add(self: *Budget, text: []const u8) ValidationError!void {
        // Subtraction prevents overflow even for caller-constructed JSON Values.
        if (text.len > max_text_bytes - self.bytes) return error.InvalidExtensionPanel;
        self.bytes += text.len;
    }
};

fn validateNode(node: Value, depth: usize, budget: *Budget) ValidationError!void {
    if (depth > max_depth or budget.nodes >= max_nodes) return error.InvalidExtensionPanel;
    budget.nodes += 1;
    const kind = try requiredString(node, "kind");
    if (std.mem.eql(u8, kind, "row") or std.mem.eql(u8, kind, "column")) {
        const children = node.object.get("children") orelse return error.InvalidExtensionPanel;
        if (children != .array) return error.InvalidExtensionPanel;
        for (children.array.items) |child| try validateNode(child, depth + 1, budget);
    } else if (std.mem.eql(u8, kind, "text")) {
        try budget.add(try requiredString(node, "text"));
    } else if (std.mem.eql(u8, kind, "stat")) {
        try budget.add(try requiredString(node, "label"));
        try budget.add(try requiredString(node, "value"));
    } else if (std.mem.eql(u8, kind, "button")) {
        try budget.add(try requiredString(node, "label"));
        if (!identifier(try requiredString(node, "action"))) return error.InvalidExtensionPanel;
    } else return error.InvalidExtensionPanel;
}

test "native extension panel shared canonical JSON vectors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const vectors = try std.json.parseFromSliceLeaky(Value, arena.allocator(), @embedFile("extension_panel_vectors.json"), .{});
    const cases = vectors.object.get("cases").?.array.items;
    try std.testing.expect(cases.len >= 30);
    for (cases) |case| {
        const input = case.object.get("input").?;
        const expected = case.object.get("valid").?.bool;
        const actual = if (validate(input)) |_| true else |_| false;
        if (actual != expected) std.debug.print("vector failed: {s}\n", .{str(case, "name")});
        try std.testing.expectEqual(expected, actual);
    }
}

test "native extension panel payload matches engine plugin-free contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const panel = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"title":"Status","root":{"kind":"text","text":"Ready"}}
    , .{});
    try validatePanel(panel);
    try std.testing.expectError(error.InvalidExtensionPanel, validate(panel));
    try std.testing.expectError(error.InvalidExtensionPanel, validatePanel(.null));
}

test "native extension panel string access is safe on arbitrary values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const node = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"text":"Ready","value":3,"empty":""}
    , .{});
    try std.testing.expectEqualStrings("Ready", str(node, "text"));
    try std.testing.expectEqualStrings("", str(node, "value"));
    try std.testing.expectEqualStrings("", str(node, "missing"));
    try std.testing.expectEqualStrings("", str(node, "empty"));
    try std.testing.expectEqualStrings("", str(.null, "text"));
    try std.testing.expectEqualStrings("", str(.{ .integer = 3 }, "text"));
}
