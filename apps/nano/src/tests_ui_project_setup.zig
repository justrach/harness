//! Synthetic, offscreen project setup regressions. No engine or OS chooser.
const std = @import("std");
const ui = @import("nanoui").ui;
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const App = @import("app.zig").App;
const flow = @import("app_project_setup.zig");
const strip = @import("view_tab_strip.zig");

const replies =
    \\{"ListDrives":{"drives":[{"name":"Projects volume","path":"/synthetic/projects"}]},
    \\ "ListFolders":{"$seq":[
    \\  {"path":"/synthetic/home","entries":[{"name":"notes","isDir":true,"isRepo":true},{"name":"readme.txt","isDir":false,"isRepo":false}]},
    \\  {"path":"/synthetic","entries":[{"name":"notes","isDir":true,"isRepo":true}]},
    \\  {"path":"/synthetic/notes","entries":[{"name":"src","isDir":true,"isRepo":false}]}]},
    \\ "Mutate":{},"ListProjectActions":{"actions":[]}}
;
fn scene(a: *App, body: []const u8) !void {
    if (a.engine.scene) |*s| s.deinit();
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    a.engine.state = .connected;
}
fn pump(h: *Harness) void {
    _ = h.a.engine.pump();
    h.t.settle(1);
}
fn count(a: *const App, method: []const u8) !usize {
    var n: usize = 0;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const m = parsed.value.object.get("method").?.string;
        if (std.mem.eql(u8, m, method)) n += 1;
    }
    return n;
}
fn choose(h: *Harness) !void {
    try h.t.clickText("Add folder…");
    pump(h); // Home resolves on the host, then the preferred starting folder.
    pump(h);
    try testing.expect(h.a.view.project_setup.step == .folders);
    try h.t.clickText("notes");
    pump(h);
    try h.t.clickText("Use this folder");
    h.t.settle(1);
}

// Entry through the same queued menu action as the user's New project row.
test "New project opens a focused internal name-first form, without creating anything" {
    for ([_]bool{ true, false }) |dark| {
        var h: Harness = undefined;
        try h.init(dark);
        defer h.deinit();
        try scene(&h.a, replies);
        strip.queue(&h.a, .{ .add_folder = .{ .chat = 0 } });
        h.t.settle(1);
        // Menu → shared computer/folder sheet → the project form.
        try testing.expect(h.a.view.open_chooser.open);
        try testing.expect(h.t.hasText("Open a project"));
        try testing.expect(h.t.hasText("Computer"));
        try testing.expect(h.t.hasText("Folder"));
        try h.t.clickText("Open a folder…");
        h.t.settle(1);
        try testing.expect(!h.a.view.open_chooser.open);
        try testing.expect(h.a.view.project_setup.open);
        try testing.expect(h.a.view.project_setup.step == .details);
        try testing.expect(h.t.hasText("Project name"));
        try testing.expect(h.t.hasText("Working folder"));
        try testing.expect(h.t.hasText("Add folder…"));
        try testing.expect(!flow.canSubmit(&h.a));
        try testing.expectEqual(h.a.view.project_setup.field, h.t.ctx.focus);
        try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
        try testing.expectEqual(@as(usize, 0), try count(&h.a, "ListFolders"));
        try testing.expectEqualStrings("a", h.a.selected.?);
        h.t.typeText("Synthetic notebook");
        h.press(.{ .key = ui.Shortcut.enter });
        try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
        h.press(.{ .key = ui.Shortcut.tab });
        h.press(.{ .key = ui.Shortcut.enter });
        try testing.expect(h.a.view.project_setup.step == .folders);
        h.press(.{ .key = ui.Shortcut.escape });
        try testing.expect(h.a.view.project_setup.step == .details);
        pump(&h); // Cancelled reads must not reopen the browser.
        try testing.expect(h.a.view.project_setup.step == .details);
        try testing.expectEqualStrings("Synthetic notebook", h.a.view.project_setup.name.text());
        h.press(.{ .key = ui.Shortcut.escape });
        try testing.expect(!h.a.view.project_setup.open);
        try testing.expectEqualStrings("a", h.a.selected.?);
    }
}

test "folder navigation, cancel and Back only edit the project draft" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try scene(&h.a, replies);
    h.a.addFolder();
    h.t.settle(1);
    h.t.typeText("Draft name");
    try choose(&h);
    try testing.expectEqualStrings("/synthetic/notes", h.a.view.project_setup.folder.?.path);
    try testing.expectEqualStrings("Draft name", h.a.view.project_setup.name.text());
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
    try testing.expectEqualStrings("a", h.a.selected.?);
    try h.t.clickText("Change…");
    pump(&h);
    try h.t.clickText("Locations");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Home"));
    try testing.expect(h.t.hasText("Projects volume"));
    try h.t.clickText("Devices");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Build box"));
    try h.t.clickText("Back");
    h.t.settle(1);
    try testing.expect(h.a.view.project_setup.step == .details);
    try testing.expectEqualStrings("/synthetic/notes", h.a.view.project_setup.folder.?.path);
    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(!h.a.view.project_setup.open);
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
    try testing.expectEqual(@as(usize, 2), h.a.spaces.items.len);
}

test "successful project submit carries selected remote host, path and name and waits for acknowledgement" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    try scene(&h.a, replies);
    h.a.newTab();
    h.a.pickDraftDevice("remote");
    h.a.addFolder();
    h.t.settle(1);
    h.t.typeText("  Remote notebook  ");
    try choose(&h);
    // The remote choice, never the local viewer's filesystem, supplies git.
    try testing.expect(h.a.view.project_setup.folder.?.git);
    flow.submit(&h.a);
    // Hold the synthetic acknowledgement while drawing and dismissing the
    // busy form. App.tick normally delivers scene replies at each frame.
    const held = try h.a.engine.queued.toOwnedSlice(testing.allocator);
    defer {
        for (held) |frame| testing.allocator.free(frame);
        testing.allocator.free(held);
    }
    h.t.settle(1);
    try testing.expect(h.a.view.project_setup.busy);
    try testing.expect(h.a.view.project_setup.open);
    try testing.expect(h.t.hasText("Creating…"));
    try testing.expectEqual(@as(usize, 2), h.a.spaces.items.len);
    try testing.expect(h.a.space == null);
    try testing.expectEqual(@as(usize, 1), try count(&h.a, "Mutate"));
    var checked = false;
    for (h.a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        const method = o.get("method").?.string;
        const p = o.get("params").?.object;
        if (std.mem.eql(u8, method, "ListFolders") or std.mem.eql(u8, method, "ListDrives"))
            try testing.expectEqualStrings("remote", p.get("targetDeviceId").?.string);
        if (!std.mem.eql(u8, method, "Mutate")) continue;
        checked = true;
        try testing.expectEqualStrings("createSpace", p.get("op").?.string);
        try testing.expectEqualStrings("remote", p.get("deviceId").?.string);
        try testing.expectEqualStrings("/synthetic/notes", p.get("path").?.string);
        try testing.expectEqualStrings("Remote notebook", p.get("name").?.string);
        try testing.expect(p.get("gitDetected").?.bool);
    }
    try testing.expect(checked);
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(h.a.view.project_setup.open); // Cannot abandon an in-flight save.
    flow.submit(&h.a);
    try testing.expectEqual(@as(usize, 1), try count(&h.a, "Mutate"));
    for (held) |frame| try h.a.engine.mux.dispatch(frame);
    h.t.settle(1);
    try testing.expect(!h.a.view.project_setup.open);
    try testing.expectEqual(@as(usize, 3), h.a.spaces.items.len);
    const selected = h.a.newChatSpace() orelse return error.NoAcknowledgedProject;
    try testing.expectEqualStrings("remote", selected.device_id.?);
    try testing.expectEqualStrings("/synthetic/notes", selected.path);
    try testing.expectEqualStrings("Remote notebook", selected.name);
}

test "an existing device and folder require Open project, never create or rename" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try scene(&h.a,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"path":"/synthetic/fieldnotes","entries":[]}}
    );
    h.a.addFolder();
    h.t.settle(1);
    try h.t.clickText("Add folder…");
    pump(&h);
    pump(&h);
    try h.t.clickText("Use this folder");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Open project"));
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
    // Name is intentionally blank: existing projects don't need a new name.
    try h.t.clickText("Open project");
    h.t.settle(1);
    try testing.expect(!h.a.view.project_setup.open);
    try testing.expectEqualStrings("local-project", h.a.space.?);
    try testing.expectEqualStrings("fieldnotes", h.a.newChatSpace().?.name);
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
}

test "project save errors retain the name and folder, allow retry and never select an unacknowledged project" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try scene(&h.a,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"path":"/synthetic/new-notes","entries":[]},
        \\ "Mutate":{"$seq":[{"$err":"Synthetic save failure"},{}]}}
    );
    h.a.addFolder();
    h.t.settle(1);
    h.t.typeText("Retry notes");
    try h.t.clickText("Add folder…");
    pump(&h);
    pump(&h);
    try h.t.clickText("Use this folder");
    h.t.settle(1);
    try h.t.clickText("Create project");
    pump(&h);
    try testing.expect(h.a.view.project_setup.open and !h.a.view.project_setup.busy);
    try testing.expect(h.t.hasText("Synthetic save failure"));
    try testing.expectEqualStrings("Retry notes", h.a.view.project_setup.name.text());
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 2), h.a.spaces.items.len);
    try h.t.clickText("Create project");
    pump(&h);
    try testing.expect(!h.a.view.project_setup.open);
}

test "folder loading, failures and cancelled replies never permit a stale folder to be used" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try scene(&h.a,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"$seq":[
        \\ {"path":"/synthetic/home","entries":[]},
        \\ {"path":"/synthetic","entries":[]},
        \\ {"$err":"Synthetic folder unavailable"},
        \\ {"path":"/synthetic/later","entries":[]}]}}
    );
    h.a.addFolder();
    h.t.settle(1);
    try h.t.clickText("Add folder…");
    pump(&h);
    pump(&h);
    try testing.expect(flow.ready(&h.a.view.project_setup) != null);
    flow.browse(&h.a, "/synthetic/missing", false);
    const held = try h.a.engine.queued.toOwnedSlice(testing.allocator);
    defer {
        for (held) |frame| testing.allocator.free(frame);
        testing.allocator.free(held);
    }
    h.t.settle(1);
    try testing.expect(h.t.hasText("Loading folders…"));
    flow.useFolder(&h.a);
    try testing.expect(h.a.view.project_setup.folder == null);
    for (held) |frame| try h.a.engine.mux.dispatch(frame);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Synthetic folder unavailable"));
    try testing.expect(flow.ready(&h.a.view.project_setup) == null);
    flow.useFolder(&h.a);
    try testing.expect(h.a.view.project_setup.folder == null);
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
    flow.browse(&h.a, "/synthetic/later", false);
    flow.details(&h.a);
    pump(&h);
    try testing.expect(h.a.view.project_setup.step == .details);
    try testing.expect(h.a.view.project_setup.folder == null);
}

test "folder keyboard completion, Return, left and Cmd Return navigate without creating a project" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try scene(&h.a,
        \\{"ListDrives":{"drives":[]},"ListFolders":{"$seq":[
        \\ {"path":"/synthetic/home","entries":[]},
        \\ {"path":"/synthetic","entries":[{"name":"notes","isDir":true,"isRepo":true},{"name":"readme.txt","isDir":false}]},
        \\ {"path":"/synthetic/notes","entries":[]},
        \\ {"path":"/synthetic","entries":[{"name":"notes","isDir":true,"isRepo":true}]}]}}
    );
    h.a.addFolder();
    h.t.settle(1);
    try h.t.clickText("Add folder…");
    pump(&h);
    pump(&h);
    try testing.expect(!h.t.hasText("readme.txt"));
    h.t.typeText("not");
    h.press(.{ .key = ui.Shortcut.tab });
    try testing.expectEqualStrings("notes", h.a.view.project_setup.query.text());
    h.press(.{ .key = ui.Shortcut.enter });
    pump(&h);
    try testing.expectEqualStrings("/synthetic/notes", flow.ready(&h.a.view.project_setup).?.path);
    try testing.expect(h.a.view.project_setup.folder == null);
    h.press(.{ .key = ui.Shortcut.left });
    pump(&h);
    try testing.expectEqualStrings("/synthetic", flow.ready(&h.a.view.project_setup).?.path);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true });
    try testing.expect(h.a.view.project_setup.step == .details);
    // The chord uses the OPEN folder, not the highlighted notes subfolder.
    try testing.expectEqualStrings("/synthetic", h.a.view.project_setup.folder.?.path);
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
}

test "an unavailable explicit computer cannot silently browse on the local viewer" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    try scene(&h.a, replies);
    h.a.newTab();
    h.a.pickDraftDevice("unavailable-computer");
    h.a.addFolder();
    h.t.settle(1);
    try h.t.clickText("Add folder…");
    h.t.settle(1);
    try testing.expect(h.a.view.project_setup.step == .devices);
    try testing.expect(h.t.hasText("This computer is unavailable. Choose another device."));
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "ListFolders"));
    try testing.expectEqual(@as(usize, 0), try count(&h.a, "Mutate"));
}
