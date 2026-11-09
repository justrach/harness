//! Synthetic headless coverage of the shell's sliding sidebar geometry.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const chrome = @import("panel_chrome.zig");
const testing = std.testing;
const sidebar_width = @import("settings.zig").sidebar_default;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        h.a.dark = false;
        h.a.settings.setText("surface", "opaque");
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"synthetic","deviceId":"d","title":"Synthetic sidebar chat","archived":false},
            \\ {"id":"other","deviceId":"d","title":"Other synthetic chat","archived":false}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("synthetic", null);
        const messages = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[
            \\ {"id":"u1","role":"user","parts":[{"id":"p","kind":"text","text":"First synthetic prompt"}]},
            \\ {"id":"answer","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic sidebar answer"}]},
            \\ {"id":"u2","role":"user","parts":[{"id":"p","kind":"text","text":"Second synthetic prompt"}]}]}
        , .{});
        defer messages.deinit();
        try h.a.transcript.apply(messages.value);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = false });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn sidebarHasText(h: *Harness, label: []const u8) bool {
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |text| if (node.rect.x < h.a.settings.sidebarWidth() and std.mem.eql(u8, text.str, label)) return true,
            else => {},
        };
        return false;
    }

    fn toggle(h: *Harness) void {
        _ = h.t.shortcut(.{ .key = 'b', .cmd = true });
    }

    /// The instrument strip's active tab label (titlebar lane, above the
    /// sidebar's 38-point content start): what the ⌘B tween must carry.
    fn stripTabX(h: *Harness) ?f32 {
        for (h.t.ctx.nodes.items) |node| switch (node.content) {
            .text => |text| if (node.rect.y < 38 and std.mem.eql(u8, text.str, "Synthetic sidebar chat")) return node.rect.x,
            else => {},
        };
        return null;
    }

    fn stripTabXAt(h: *Harness, at: []const u8) !f32 {
        _ = at;
        return stripTabX(h) orelse error.MissingStripTab;
    }

    fn origin(h: *Harness) f32 {
        // The chat allocation now excludes the trailing workspace gutter;
        // subtracting it from the window no longer measures sidebar motion.
        return h.a.view.sidebar_width;
    }

    fn geometry(h: *Harness) !void {
        const x = h.origin();
        const panel_x = h.a.view.chrome.x;
        var main = false;
        var side = false;
        var header = false;
        var body = false;
        var rail_ticks: usize = 0;
        for (h.t.ctx.nodes.items) |node| {
            const r = node.rect;
            if (@abs(r.x - x) < 1 and @abs(r.w - (1200 - x)) < 1 and r.h == 780) main = true;
            if (r.w == sidebar_width and r.h == 780 and std.meta.eql(node.style.background, @import("theme.zig").colors(false).sidebar)) {
                try testing.expectApproxEqAbs(x - sidebar_width, r.x, 1);
                side = true;
            }
            if (node.style.radius == chrome.body_radius and @abs(r.x - panel_x) < 1 and @abs(r.y - chrome.header_height) < 1 and @abs(r.h - h.a.view.chrome.height) < 1) body = true;
            // The panel's own one-point border, then the rail's16px inset.
            if (r.h == 2 and r.w == 12 and @abs(r.x - (panel_x + 1 + 16)) < 1) rail_ticks += 1;
            switch (node.content) {
                .text => |text| if (std.mem.eql(u8, text.str, "Synthetic sidebar chat") and r.y < 38) {
                    // Active folder tabs follow the animated panel origin,
                    // clearing only the live titlebar controls when collapsed.
                    const left = @max(@import("view_tab_strip.zig").leftInset(&h.a), h.a.view.chrome.leading);
                    try testing.expectApproxEqAbs(x + left + 8 + 14 + 6, r.x, 1);
                    header = true;
                },
                else => {},
            }
        }
        try testing.expect(main and (side or x == 0) and header and body);
        try testing.expectEqual(@as(usize, 2), rail_ticks);
        // Read final layout rather than the composer's previous-frame anchor.
        var composer = false;
        for (h.t.ctx.nodes.items) |node| {
            if (node.rect.w == 736 and node.rect.h == 49) {
                try testing.expectApproxEqAbs(panel_x + (h.a.view.chrome.chat_width - 736) / 2, node.rect.x, 1);
                composer = true;
            }
        }
        try testing.expect(composer);
        const answer = h.t.findText("Synthetic sidebar answer") orelse return error.MissingVisibleReply;
        try testing.expect(answer.y >= 38 and answer.y + answer.h < h.t.size.h - 89);
    }
};

test "Cmd+B has an intermediate main viewport width rather than unmounting immediately" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expectApproxEqAbs(sidebar_width, h.origin(), 0.01);
    h.toggle();
    h.t.advance(0.08);
    try testing.expect(h.origin() > 0 and h.origin() < sidebar_width);
    try h.geometry();
    h.t.advance(0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    try h.geometry();
    const composer_id = h.a.view.composer_id;
    h.toggle();
    h.t.advance(0.08);
    try testing.expect(h.origin() > 0 and h.origin() < sidebar_width);
    try h.geometry();
    try testing.expectEqual(composer_id, h.a.view.composer_id);
    // Clipped-off sidebar rows cannot intercept chat-column input.
    const row = h.t.findText("Other synthetic chat") orelse return error.MissingSidebarRow;
    h.t.click(h.origin() + 16, row.y + row.h / 2);
    try testing.expectEqualStrings("synthetic", h.a.selected.?);
    h.t.advance(0.3);
    try testing.expectApproxEqAbs(sidebar_width, h.origin(), 0.01);
    try h.geometry();
}

test "Cmd+B moves on every display frame and eases into rest" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.toggle();
    var previous = h.origin();
    var first_delta: ?f32 = null;
    var last_delta: f32 = 0;
    var frames: usize = 0;
    while (previous > 0.01 and frames < 120) : (frames += 1) {
        h.t.frame();
        const now = h.origin();
        try testing.expect(now >= 0 and now <= previous + 0.01);
        const delta = previous - now;
        if (now > 0.01) try testing.expect(delta > 0.001);
        if (delta > 0) {
            if (first_delta == null) first_delta = delta;
            last_delta = delta;
        }
        previous = now;
    }
    try testing.expect(frames >= 8);
    try testing.expectApproxEqAbs(@as(f32, 0), previous, 0.01);
    try testing.expect(first_delta.? > last_delta);

    h.toggle();
    previous = 0;
    first_delta = null;
    last_delta = 0;
    frames = 0;
    while (previous < sidebar_width - 0.01 and frames < 120) : (frames += 1) {
        h.t.frame();
        const now = h.origin();
        try testing.expect(now >= previous - 0.01 and now <= sidebar_width + 0.01);
        const delta = now - previous;
        if (now < sidebar_width - 0.01) try testing.expect(delta > 0.001);
        if (delta > 0) {
            if (first_delta == null) first_delta = delta;
            last_delta = delta;
        }
        previous = now;
    }
    try testing.expect(frames >= 8);
    try testing.expectApproxEqAbs(sidebar_width, previous, 0.01);
    try testing.expect(first_delta.? > last_delta);
}

test "sidebar reversals sample the current width and settle without idle animation frames" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.view.sidebar_open = false;
    h.t.time = h.t.ctx.time;
    h.t.frame();
    h.t.time = h.t.ctx.time + 0.1;
    h.t.frame();
    // Exact CSS ease-out's halfway sample (not a cubic ease-out shortcut).
    try testing.expectApproxEqAbs(sidebar_width * (80.73 / 256.0), h.origin(), 0.1);
    const closing = h.origin();
    // Retarget at the very same sample time; shortcut() itself advances
    // the Tester's clock across key-down/up frames.
    h.a.view.sidebar_open = true;
    h.t.time = h.t.ctx.time;
    h.t.frame();
    try testing.expectApproxEqAbs(closing, h.origin(), 0.01);
    h.t.advance(0.05);
    try testing.expect(h.origin() > closing and h.origin() < sidebar_width);
    const opening = h.origin();
    h.a.view.sidebar_open = false;
    h.t.time = h.t.ctx.time;
    h.t.frame();
    try testing.expectApproxEqAbs(opening, h.origin(), 0.01);
    h.t.advance(0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    h.t.ctx.focus = 0;
    h.t.settle(1);
    try testing.expect(!h.t.ctx.animating);
    h.t.advance(1);
    try testing.expect(!h.t.ctx.animating);
}

test "the strip lane rides the Cmd+B tween instead of jumping at the press" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const open_x = try h.stripTabXAt("open");
    // Fully closed: the lane rests clear of the titlebar controls.
    h.toggle();
    h.t.advance(0.3);
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    const closed_x = try h.stripTabXAt("closed");
    try testing.expect(closed_x < open_x);
    // Opening: the press frame samples the same resting lane (the history
    // clearance flips with the tween, not with `sidebar_open`), and every
    // later frame may move only as far as the seam it follows — 1 + the
    // 28-point clearance across the tween, with a point of layout rounding.
    h.toggle();
    var prev_x = closed_x;
    var prev_w = h.origin();
    var x = try h.stripTabXAt("opening press");
    try testing.expect(@abs(x - prev_x) <= @abs(h.origin() - prev_w) * 1.2 + 1);
    var guard: usize = 0;
    while (h.origin() < sidebar_width - 0.01 and guard < 600) : (guard += 1) {
        h.t.frame();
        const w = h.origin();
        x = try h.stripTabXAt("opening");
        try testing.expect(@abs(x - prev_x) <= @abs(w - prev_w) * 1.2 + 1);
        prev_x = x;
        prev_w = w;
    }
    try testing.expectApproxEqAbs(sidebar_width, h.origin(), 0.01);
    try testing.expectApproxEqAbs(open_x, try h.stripTabXAt("open settled"), 1);
    // Closing samples the same continuous lane, press frame included.
    h.toggle();
    x = try h.stripTabXAt("closing press");
    try testing.expect(@abs(x - prev_x) <= @abs(h.origin() - prev_w) * 1.2 + 1);
    prev_x = x;
    prev_w = h.origin();
    guard = 0;
    while (h.origin() > 0.01 and guard < 600) : (guard += 1) {
        h.t.frame();
        const w = h.origin();
        x = try h.stripTabXAt("closing");
        try testing.expect(@abs(x - prev_x) <= @abs(w - prev_w) * 1.2 + 1);
        prev_x = x;
        prev_w = w;
    }
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    try testing.expectApproxEqAbs(closed_x, try h.stripTabXAt("closed settled"), 1);
}

test "mouse and keyboard close search together and restore composer focus" {
    for ([_]bool{ false, true }) |mouse| {
        var h: Harness = undefined;
        try h.init();
        defer h.deinit();
        @import("view_sidebar_search.zig").toggle(&h.a);
        h.t.settle(1);
        try testing.expect(h.a.view.search.field_focused);
        if (mouse) h.t.click(100, 21) else h.toggle();
        h.t.frame();
        try testing.expect(!h.a.view.sidebar_open);
        try testing.expect(!h.a.view.search.open);
        try testing.expect(!h.a.view.search.focus);
        try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
        h.t.advance(0.08);
        try testing.expect(h.origin() > 0 and h.origin() < sidebar_width);
    }
}

test "Cmd+B preserves file search focus while the sidebar search is open" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    @import("view_sidebar_search.zig").toggle(&h.a);
    h.t.settle(1);
    h.a.panels.files_open = true;
    h.t.settle(1);
    try h.t.clickText("Search files");
    const focused = h.t.ctx.focus;
    try testing.expect(focused != 0 and focused != h.a.view.composer_id);
    try testing.expect(!@import("view_sidebar_search.zig").hasFocus(&h.a));
    h.toggle();
    h.t.frame();
    try testing.expect(!h.a.view.search.open);
    try testing.expectEqual(focused, h.t.ctx.focus);
}

test "Rust byProject settings retain project disclosures filters pins and display choices" {
    const settings = @import("settings.zig");
    const menus = @import("view_sidebar_menus.zig");
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expect(h.a.settings.path == null);
    const spaces = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"alpha","deviceId":"d","path":"/synthetic/Alpha project"},
        \\ {"id":"beta","deviceId":"d","path":"/synthetic/Beta project"}]
    , .{});
    defer spaces.deinit();
    try h.a.spaces.replace(spaces.value);
    const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"synthetic","deviceId":"d","spaceId":"alpha","title":"Alpha session","archived":false},
        \\ {"id":"other","deviceId":"d","spaceId":"beta","title":"Beta session","archived":false},
        \\ {"id":"pin","deviceId":"d","spaceId":"alpha","title":"Pinned session","archived":false}]
    , .{});
    defer chats.deinit();
    try h.a.chats.replace(chats.value);
    // This is the exact organization key/value serialized by Rust v0.2.173.
    h.a.settings.apply(
        \\{"sidebarOrganization":"byProject","sidebarGrouped":false,"sidebarCompact":true,"sidebarShowProjectIcon":false,"sidebarShowProjectLabel":false,"sidebarPinnedSessionIdsByProfile":{"local":["pin"]}}
    );
    h.t.settle(1);
    try testing.expectEqual(settings.Organization.by_project, h.a.settings.organization());
    try testing.expect(!h.sidebarHasText("Sessions"));
    try testing.expect(h.sidebarHasText("Alpha project") and h.sidebarHasText("Beta project"));
    try testing.expect(h.sidebarHasText("Alpha session") and h.sidebarHasText("Beta session"));
    const pin = h.t.findText("Pinned session") orelse return error.MissingPinnedSession;
    try testing.expect(pin.y < h.t.findText("Alpha project").?.y);
    try h.t.clickText("Alpha project");
    h.t.settle(1);
    try testing.expect(h.sidebarHasText("Alpha project (1)"));
    try testing.expect(!h.sidebarHasText("Alpha session"));
    try testing.expect(h.sidebarHasText("Pinned session") and h.sidebarHasText("Beta session"));
    h.a.setSpaceFilter("alpha");
    h.t.settle(1);
    try testing.expect(!h.sidebarHasText("Beta session"));
    try testing.expect(h.sidebarHasText("Alpha project (1)"));
    try h.t.clickText("Alpha project (1)");
    h.t.settle(1);
    try testing.expect(h.sidebarHasText("Alpha session") and h.sidebarHasText("Pinned session"));
    h.a.setSpaceFilter(null);
    menus.choose(&h.a, .project_icon);
    menus.choose(&h.a, .location);
    menus.choose(&h.a, .branch);
    h.t.settle(1);
    try testing.expectEqual(settings.Organization.by_project, h.a.settings.organization());
    try testing.expect(h.sidebarHasText("Beta session"));
    try testing.expect(h.a.settings.get(.sidebar_show_project_icon));
    try testing.expect(h.a.settings.get(.sidebar_show_project_label));
    try testing.expect(!h.a.settings.get(.sidebar_show_branch));
    // An explicit flat-list preference must never be treated as a migration.
    menus.choose(&h.a, .in_one_list);
    h.t.settle(1);
    try testing.expect(h.sidebarHasText("Sessions"));
    try testing.expectEqualStrings("inOneList", h.a.settings.text("sidebarOrganization").?);
    menus.choose(&h.a, .by_project);
    h.t.settle(1);
    try testing.expect(!h.sidebarHasText("Sessions"));
    try testing.expectEqualStrings("byProject", h.a.settings.text("sidebarOrganization").?);
    try testing.expect(h.sidebarHasText("Alpha session") and h.sidebarHasText("Beta session"));
    try testing.expectEqualStrings("pin", h.a.settings.pins.items[0]);
}

test "Settings keeps its full navigation and reduced motion snaps both directions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.ctx.reduced_motion = true;
    h.toggle();
    try testing.expectApproxEqAbs(@as(f32, 0), h.origin(), 0.01);
    h.toggle();
    try testing.expectApproxEqAbs(sidebar_width, h.origin(), 0.01);
    h.toggle();
    _ = h.t.shortcut(.{ .key = ',', .cmd = true });
    try testing.expect(h.a.view.settings_open);
    try testing.expectApproxEqAbs(sidebar_width, h.origin(), 0.01);
    h.toggle();
    h.toggle();
    try testing.expectApproxEqAbs(sidebar_width, h.origin(), 0.01);
    h.t.ctx.focus = 0;
    h.t.frame();
    try testing.expect(!h.t.ctx.animating);
}

test "Cmd+B culls offscreen transcript entries during the sidebar tween" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(gpa, "{\"reset\":[");
    for (0..80) |i| {
        if (i > 0) try text.appendSlice(gpa, ",");
        try text.appendSlice(gpa, try std.fmt.allocPrint(gpa,
            \\{{"id":"u-{d}","role":"user","parts":[{{"id":"p","kind":"text","text":"Synthetic prompt {d}"}}]}},
            \\{{"id":"a-{d}","role":"assistant","status":"complete","parts":[{{"id":"p","kind":"text","text":"Synthetic reply {d} with a body line."}}]}}
        , .{ i, i, i, i }));
    }
    try text.appendSlice(gpa, "]}");
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text.items, .{});
    try h.a.transcript.apply(parsed.value);
    h.t.settle(1);
    const settled_nodes = h.t.ctx.stats.nodes;
    h.toggle();
    h.t.advance(0.08);
    try testing.expect(h.a.view.sidebar_tween != null);
    const tween_nodes = h.t.ctx.stats.nodes;
    try testing.expect(tween_nodes * 2 < settled_nodes);
    try testing.expect(h.t.hasText("Synthetic reply 79 with a body line."));
    h.t.advance(0.3);
    try testing.expect(h.a.view.sidebar_tween == null);
    try testing.expect(h.t.ctx.stats.nodes > tween_nodes * 2);
    h.toggle();
    h.t.advance(0.3);
    try testing.expect(h.t.ctx.stats.nodes >= settled_nodes - 1);
}
