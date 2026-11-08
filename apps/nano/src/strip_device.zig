//! codegraff_sandboxes::friendly_device_name, including its deliberately
//! conservative cloud-name association. Labels never change a routing ID.
const std = @import("std");
const workspace = @import("workspace.zig");
const sandboxes = @import("sandboxes.zig");

pub fn localLabel() []const u8 {
    return if (@import("builtin").os.tag == .macos) "This Mac" else "This device";
}

pub fn label(id: ?[]const u8, local: ?[]const u8, devices: []const workspace.Device, list: ?sandboxes.List) []const u8 {
    const want = id orelse return localLabel();
    if (local) |mine| if (std.mem.eql(u8, mine, want)) return localLabel();
    const device = for (devices) |d| {
        if (std.mem.eql(u8, d.id, want)) break d;
    } else return "Unknown device";
    const name = std.mem.trim(u8, device.name, " \t\r\n");
    if (cloudName(device, devices, list)) |cloud| return cloud;
    return if (name.len == 0) "Unknown device" else name;
}

fn cloudName(device: workspace.Device, devices: []const workspace.Device, list: ?sandboxes.List) ?[]const u8 {
    if (!std.mem.eql(u8, device.platform, "linux") or std.mem.trim(u8, device.name, " \t\r\n").len == 0) return null;
    var ids: usize = 0;
    var names: usize = 0;
    for (devices) |d| {
        if (std.mem.eql(u8, d.id, device.id)) ids += 1;
        if (std.mem.eql(u8, d.platform, "linux") and std.mem.eql(u8, d.name, device.name)) names += 1;
    }
    if (ids != 1 or names != 1) return null;
    const known = list orelse return null;
    if (!known.enabled) return null;
    var match: ?sandboxes.Sandbox = null;
    for (known.sandboxes) |sandbox| {
        const registration = std.mem.trim(u8, sandbox.device_name orelse continue, " \t\r\n");
        if (!std.mem.eql(u8, registration, device.name)) continue;
        if (match != null) return null;
        match = sandbox;
    }
    const sandbox = match orelse return null;
    if (!std.mem.eql(u8, sandbox.provider, "fleet") or !sandbox.harness or sandboxes.isTemporary(sandbox)) return null;
    const name = std.mem.trim(u8, sandbox.name orelse return null, " \t\r\n");
    return if (name.len > 0) name else null;
}

test "strip device labels preserve local identity and reject ambiguous cloud registration names" {
    const devices = [_]workspace.Device{
        .{ .id = "local", .name = "A synthetic Mac" },
        .{ .id = "remote", .name = "registration", .platform = "linux" },
    };
    const cloud = sandboxes.Sandbox{ .id = "s", .name = "Build box", .provider = "fleet", .device_name = "registration", .harness = true };
    const list = sandboxes.List{ .enabled = true, .sandboxes = &.{cloud} };
    try std.testing.expectEqualStrings(localLabel(), label("local", "local", &devices, list));
    try std.testing.expectEqualStrings("Unknown device", label("missing", "local", &devices, list));
    try std.testing.expectEqualStrings("Build box", label("remote", "local", &devices, list));
    try std.testing.expectEqualStrings("registration", label("remote", "local", &devices, .{ .enabled = true, .sandboxes = &.{ cloud, cloud } }));
    const duplicates = devices ++ [_]workspace.Device{.{ .id = "other", .name = "registration", .platform = "linux" }};
    try std.testing.expectEqualStrings("registration", label("remote", "local", &duplicates, list));
}
