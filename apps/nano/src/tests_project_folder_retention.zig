//! Settings must configure the same host-scoped starting folders New project uses.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;

test "restore starting folder Settings Edit opens a host folder picker (#272)" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.press(.{ .key = ',', .cmd = true });
    try h.t.clickText("Files");
    h.t.settle(1);
    try h.t.clickText("Edit");
    h.t.settle(1);
    try testing.expect(h.a.view.project_setup.open);
    try testing.expect(h.a.view.project_setup.step != .details);
    try testing.expect(h.a.view.settings_open);
    try testing.expectEqualStrings("local", h.a.view.project_setup.device.?);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

fn connect(h: *Harness) !void {
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"path":"/synthetic/chosen","entries":[]}}
    , .{});
    h.a.engine.state = .connected;
}

fn settleFolder(h: *Harness) void {
    for (0..3) |_| {
        _ = h.a.engine.pump();
        h.t.settle(0.2);
    }
}

test "restore starting folder only confirmation persists and never creates a project (#272)" {
    const flow = @import("app_project_setup.zig");
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try connect(&h);
    flow.openStartingFolder(&h.a);
    settleFolder(&h);
    try testing.expect(flow.ready(&h.a.view.project_setup) != null);
    try testing.expect(h.a.settings.projectFolderOverride("local") == null);
    flow.dismiss(&h.a);
    try testing.expect(h.a.settings.projectFolderOverride("local") == null);
    flow.openStartingFolder(&h.a);
    settleFolder(&h);
    flow.useFolder(&h.a);
    try testing.expect(!h.a.view.project_setup.open);
    try testing.expectEqualStrings("/synthetic/chosen", h.a.settings.projectFolderOverride("local").?);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 2), h.a.spaces.items.len);
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        try testing.expect(!std.mem.eql(u8, parsed.value.object.get("method").?.string, "Mutate"));
    }
}

test "restore starting folder automatic reset preserves learned history and other hosts (#272)" {
    const flow = @import("app_project_setup.zig");
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.apply(
        \\{"projectFoldersByDevice":{"local":{"overridePath":"/synthetic/custom","parentCounts":{"/synthetic/learned":8}},"remote":{"overridePath":"C:\\work","parentCounts":{"C:/archive":3}}}}
    );
    try connect(&h);
    flow.openStartingFolder(&h.a);
    settleFolder(&h);
    flow.resetStartingFolder(&h.a);
    try testing.expect(h.a.settings.projectFolderOverride("local") == null);
    try testing.expectEqualStrings("C:\\work", h.a.settings.projectFolderOverride("remote").?);
    const automatic = (try @import("project_paths.zig").starting(testing.allocator, h.a.settings.doc.get("projectFoldersByDevice"), "local", h.a.spaces.items)).?;
    defer testing.allocator.free(automatic);
    try testing.expectEqualStrings("/synthetic/learned", automatic);
    try testing.expect(!h.a.settings.setProjectFolderOverride("remote", "relative/path"));
    try testing.expectEqualStrings("C:\\work", h.a.settings.projectFolderOverride("remote").?);
}

test "restore starting folder override survives settings reload in synthetic directory (#272)" {
    const settings = @import("settings.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(base);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HARNESS_DATA_DIR", base);
    {
        var store = settings.Store.open(testing.allocator, testing.io, &env);
        defer store.deinit();
        try testing.expect(store.setProjectFolderOverride("remote", "C:\\synthetic\\projects"));
        try testing.expect(store.setProjectFolderOverride("local", "/synthetic/projects"));
    }
    var back = settings.Store.open(testing.allocator, testing.io, &env);
    defer back.deinit();
    try testing.expectEqualStrings("C:\\synthetic\\projects", back.projectFolderOverride("remote").?);
    try testing.expectEqualStrings("/synthetic/projects", back.projectFolderOverride("local").?);
}

test "restore starting folder Settings save survives auth recovery and New Project reload (#305)" {
    const settings = @import("settings.zig");
    const flow = @import("app_project_setup.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(relative);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, relative, testing.allocator);
    defer testing.allocator.free(base);
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try env.put("HARNESS_DATA_DIR", base);
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.settings.deinit();
    h.a.settings = settings.Store.open(testing.allocator, testing.io, &env);
    try connect(&h);
    h.press(.{ .key = ',', .cmd = true });
    try h.t.clickText("Files");
    h.t.settle(0.2);
    try h.t.clickText("Edit");
    settleFolder(&h);
    try h.t.clickText("Use this folder");
    h.t.settle(0.2);
    try testing.expectEqualStrings("/synthetic/chosen", h.a.settings.projectFolderOverride("local").?);

    // Drive the registered account stream, not a pure preference resolver.
    @import("app_account.zig").watch(&h.a);
    const watch = h.a.account.w_auth orelse return error.MissingAccountWatch;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "signed-out.notice", .data = "synthetic rejected refresh" });
    for ([_][]const u8{
        \\{"state":"signedOut"}
        ,
        \\{"state":"signedIn","user":{"id":"synthetic-account","email":"synthetic@example.invalid"}}
        ,
    }) |auth| {
        const frame = try std.fmt.allocPrint(testing.allocator, "{{\"id\":{d},\"item\":{s}}}", .{ watch, auth });
        defer testing.allocator.free(frame);
        try h.a.engine.mux.dispatch(frame);
        try testing.expectEqualStrings("/synthetic/chosen", h.a.settings.projectFolderOverride("local").?);
    }
    try testing.expectEqualStrings("synthetic@example.invalid", h.a.account.user.?.email);
    // Reopen the actual persisted store, as on restart, under the same device.
    h.a.settings.deinit();
    h.a.settings = settings.Store.open(testing.allocator, testing.io, &env);
    h.a.view.settings_open = false;
    // Home differs from Custom, so this must issue the second host lookup
    // rather than accidentally passing because a static scene returned it.
    h.a.engine.scene.?.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"path":"/synthetic/home","entries":[]}}
    , .{});
    flow.open(&h.a);
    flow.beginFolder(&h.a);
    h.a.engine.scene.?.deinit();
    h.a.engine.scene = null;
    try connect(&h);
    settleFolder(&h);
    try testing.expectEqualStrings("local", h.a.view.project_setup.device.?);
    try testing.expectEqualStrings("/synthetic/chosen", flow.ready(&h.a.view.project_setup).?.path);
    var saw_custom_lookup = false;
    for (h.a.engine.sent.items) |sent| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, sent, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.object.get("method").?.string, "ListFolders")) continue;
        const params = parsed.value.object.get("params").?.object;
        if (params.get("path")) |path| if (path == .string and std.mem.eql(u8, path.string, "/synthetic/chosen")) {
            saw_custom_lookup = true;
        };
    }
    try testing.expect(saw_custom_lookup);
}
