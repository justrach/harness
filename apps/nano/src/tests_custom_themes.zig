//! Custom themes, procedural animated backdrops, slash commands, palette
//! discovery, persistence round-trip, and idle/motion wakeup guards.
const std = @import("std");
const ui = @import("nanoui").ui;
const testing = std.testing;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const custom_themes = @import("custom_themes.zig");
const view_backdrop = @import("view_backdrop.zig");
const palette = @import("palette.zig");
const completion = @import("composer_completion.zig");

test "curated presets span all 8 motifs with 12 dark, 8 light and WCAG >= 4.5 contrast" {
    const presets = custom_themes.curated();
    try testing.expectEqual(@as(usize, 20), presets.len);

    var dark_count: usize = 0;
    var light_count: usize = 0;
    var seen_motifs: [custom_themes.Motif.all.len]bool = @splat(false);

    for (presets, 0..) |p, i| {
        if (p.variant.dark) dark_count += 1 else light_count += 1;
        seen_motifs[@intFromEnum(p.backdrop.motif)] = true;
        try testing.expect(theme.contrast(p.variant.colors.text, p.variant.colors.background) >= 4.5);
        try testing.expect(theme.contrast(p.variant.colors.text, p.variant.colors.shell) >= 4.5);
        for (presets[i + 1 ..]) |q| {
            try testing.expect(!std.mem.eql(u8, p.id, q.id));
        }
    }
    try testing.expectEqual(@as(usize, 12), dark_count);
    try testing.expectEqual(@as(usize, 8), light_count);
    for (seen_motifs) |seen| try testing.expect(seen);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "Kyoto rain at midnight",
        "Matcha tea garden on washi paper",
        "Northern aurora spruce night",
        "Morning sakura petals",
    }) |prompt| {
        const syn = custom_themes.synthesizeFromPrompt(arena.allocator(), prompt, null);
        try testing.expect(theme.contrast(syn.variant.colors.text, syn.variant.colors.background) >= 4.5);
        try testing.expect(theme.contrast(syn.variant.colors.text, syn.variant.colors.shell) >= 4.5);
    }
}

test "backdrop canvas stays under 40 nodes across all motifs and emits zero idle wakeups" {
    theme.registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = true;
    defer {
        theme.light_id = "codegraff-light";
        theme.dark_id = "codegraff-dark";
        custom_themes.clearUserThemes();
    }

    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 960, .height = 680, .dark = true });
    defer t.deinit();
    t.settle(1);

    const k = theme.colors(true);

    // Default theme + auto backdrop emits 0 nodes and 0 frame_in wakeups.
    a.settings.setTheme(true, "default");
    a.settings.setBackdropScene("auto");
    t.ctx.frame_in = null;
    {
        const before = t.ctx.nodes.items.len;
        view_backdrop.draw(&t.ctx, &a, k);
        try testing.expectEqual(@as(usize, 0), t.ctx.nodes.items.len - before);
        try testing.expect(t.ctx.frame_in == null);
    }

    // Active custom preset across all 8 motifs emits <= 40 nodes and schedules 24fps frame_in.
    for (custom_themes.Motif.all) |motif| {
        a.settings.setTheme(true, "custom-kyoto-rain");
        a.settings.setBackdropScene(@tagName(motif));
        a.settings.setBackdropMotionKey("gentle");
        t.ctx.reduced_motion = false;
        t.ctx.input.window_active = true;
        a.view.sidebar_tween = null;
        t.ctx.frame_in = null;

        const before = t.ctx.nodes.items.len;
        view_backdrop.draw(&t.ctx, &a, k);
        const added = t.ctx.nodes.items.len - before;
        try testing.expect(added > 0);
        try testing.expect(added <= 40);
        try testing.expect(t.ctx.frame_in != null);
    }

    // Off emits 0 nodes and 0 wakeups.
    a.settings.setBackdropMotionKey("off");
    t.ctx.frame_in = null;
    {
        const before = t.ctx.nodes.items.len;
        view_backdrop.draw(&t.ctx, &a, k);
        try testing.expectEqual(@as(usize, 0), t.ctx.nodes.items.len - before);
        try testing.expect(t.ctx.frame_in == null);
    }

    // Static renders nodes but schedules zero wakeups.
    a.settings.setBackdropMotionKey("static");
    t.ctx.frame_in = null;
    {
        const before = t.ctx.nodes.items.len;
        view_backdrop.draw(&t.ctx, &a, k);
        try testing.expect(t.ctx.nodes.items.len > before);
        try testing.expect(t.ctx.frame_in == null);
    }

    // Reduced motion, unfocused window, and sidebar tween all suppress frame_in wakeups.
    a.settings.setBackdropMotionKey("gentle");
    t.ctx.reduced_motion = true;
    t.ctx.frame_in = null;
    view_backdrop.draw(&t.ctx, &a, k);
    try testing.expect(t.ctx.frame_in == null);
    t.ctx.reduced_motion = false;

    t.ctx.input.window_active = false;
    t.ctx.frame_in = null;
    view_backdrop.draw(&t.ctx, &a, k);
    try testing.expect(t.ctx.frame_in == null);
    t.ctx.input.window_active = true;

    a.view.sidebar_tween = .{ .from = 0, .to = 256, .started = 0 };
    t.ctx.frame_in = null;
    view_backdrop.draw(&t.ctx, &a, k);
    try testing.expect(t.ctx.frame_in == null);
    a.view.sidebar_tween = null;
}

test "custom theme persistence round-trip, slash completion, and palette preservation" {
    defer {
        theme.light_id = "codegraff-light";
        theme.dark_id = "codegraff-dark";
        custom_themes.clearUserThemes();
        themes.loadLibrary(testing.io, "/nonexistent");
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer testing.allocator.free(dir);

    {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const created = custom_themes.synthesizeFromPrompt(arena.allocator(), "Kyoto Moss Lantern", true);
        _ = try custom_themes.saveUserTheme(testing.io, dir, created);
    }

    // Clear in-memory cache and reload from disk via themes.loadLibrary.
    custom_themes.clearUserThemes();
    themes.loadLibrary(testing.io, dir);
    const reloaded = themes.find("ai-kyoto-moss-lantern") orelse return error.MissingPersistedCustomTheme;
    try testing.expectEqualStrings("Kyoto Moss Lantern", reloaded.name);
    try testing.expect(custom_themes.findBackdrop("ai-kyoto-moss-lantern", "auto", reloaded.colors) != null);

    // Command palette preserves 5 core entries on empty query, and filters custom scenes on non-empty queries.
    try testing.expectEqual(@as(usize, 5), palette.actionsFor("", true).len);
    const studio_hits = palette.actionsFor("studio", true);
    var found_studio = false;
    for (studio_hits.slice()) |e| if (e == .custom_theme_studio) {
        found_studio = true;
    };
    try testing.expect(found_studio);

    const kyoto_hits = palette.actionsFor("kyoto", true);
    var found_kyoto = false;
    for (kyoto_hits.slice()) |e| if (e == .custom_theme and std.mem.eql(u8, e.custom_theme, "custom-kyoto-rain")) {
        found_kyoto = true;
    };
    try testing.expect(found_kyoto);

    // Slash completion includes `/custom-theme` and `/zen`, and `/custom-theme` synthesis runs end-to-end.
    theme.registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = true;
    a.settings.applyUiMode(.zen);
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1080, .height = 760, .dark = true });
    defer t.deinit();
    t.settle(1);

    // Before command discovery finishes, native commands use the `harness:` namespace; once ready, `/custom-theme` is direct.
    a.composer.set("/custom");
    a.composer.want_caret = 7;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tok = @import("completion_rules.zig").token("/custom", 7).?;
    const pre_rows = try completion.entries(&a, arena.allocator(), tok);
    var found_namespaced = false;
    for (pre_rows) |r| if (std.mem.eql(u8, r.name, "harness:custom-theme")) {
        found_namespaced = true;
    };
    try testing.expect(found_namespaced);

    a.completion.commands_done = true;
    const rows = try completion.entries(&a, arena.allocator(), tok);
    var found_slash = false;
    for (rows) |r| if (std.mem.eql(u8, r.name, "custom-theme")) {
        found_slash = true;
    };
    try testing.expect(found_slash);

    // Disconnected `/custom-theme` execution synthesizes locally without failing or sending chat.
    a.composer.set("/custom-theme Cyberpunk Tokyo Rain");
    a.sendFollowUp(null);
    t.settle(1);
    try testing.expect(a.view.custom_theme_open);
    try testing.expectEqualStrings("ai-cyberpunk-tokyo-rain", a.settings.themeId(a.dark orelse true));

    // Connected `/custom-theme` with an engine scene sends `GenerateCustomTheme` RPC and applies the reply.
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"GenerateCustomTheme":{"id":"rpc-sakura-mist","name":"RPC Sakura Mist","dark":false,"scene":"petals","speed":0.9,"intensity":0.58,"shell":"#f7f1ee","sidebar":"#faf5f3","background":"#fffaf8","card":"#fbf2ef","border":"#e6d6d2","text":"#261a1c","muted":"#735c60","accent":"#c83e6b","glowPrimary":"#f472b6","glowSecondary":"#fb7185","source":"model"}}
    , .{});
    a.engine.state = .connected;
    a.composer.set("/custom-theme Alpine Glaze");
    a.sendFollowUp(null);
    try testing.expect(a.view.custom_theme_generating);
    var saw_rpc = false;
    for (a.engine.sent.items) |frame| {
        if (std.mem.indexOf(u8, frame, "\"GenerateCustomTheme\"") != null) saw_rpc = true;
    }
    try testing.expect(saw_rpc);
    _ = a.engine.pump();
    try testing.expect(!a.view.custom_theme_generating);
    try testing.expectEqualStrings("rpc-sakura-mist", a.settings.themeId(false));

    // `/zen` command toggles workspace mode cleanly.
    const before_mode = a.settings.uiMode();
    a.composer.set("/zen");
    a.sendFollowUp(null);
    try testing.expect(a.settings.uiMode() != before_mode);

    // Settings > Appearance exposes both the upgraded Workspace mode card and Custom themes studio.
    @import("view_custom_theme_studio.zig").close(&a);
    @import("view_settings.zig").open(&a);
    a.settings.section = .appearance;
    t.settle(1);
    try testing.expect(t.hasText("Workspace mode"));
    try testing.expect(t.hasText("Custom themes & animated backdrops"));
    try testing.expect(t.hasText("Kyoto Rain"));
}

test "v200 synthetic PR screenshots" {
    const raw_dir = std.c.getenv("NANO_V200_SNAP_DIR") orelse return;
    const out_dir = std.mem.span(raw_dir);
    defer {
        theme.light_id = "codegraff-light";
        theme.dark_id = "codegraff-dark";
        custom_themes.clearUserThemes();
    }
    theme.registerFonts();

    const now_ms: i64 = @intCast(@divFloor(std.Io.Clock.real.now(testing.io).nanoseconds, std.time.ns_per_ms));

    // 1. Light Zen sidebar with right-aligned [⋯] and crisp Sidebar view options popover.
    {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = false;
        a.settings.applyUiMode(.zen);
        a.view.sidebar_open = true;
        const json_chats = try std.fmt.allocPrint(testing.allocator,
            \\[
            \\ {{"id":"syn-1","deviceId":"syn-dev","title":"Design system typography","cwd":"/synthetic/design","archived":false,"updatedAt":{d},"config":{{"harness":"graff"}}}},
            \\ {{"id":"syn-2","deviceId":"syn-dev","title":"Sidebar motion proof","cwd":"/synthetic/motion","archived":false,"updatedAt":{d},"config":{{"harness":"graff"}}}},
            \\ {{"id":"syn-3","deviceId":"syn-dev","title":"Release checklist","cwd":"/synthetic/release","archived":false,"updatedAt":{d},"config":{{"harness":"graff"}}}}
            \\]
        , .{ now_ms - 120_000, now_ms - 600_000, now_ms - 3_600_000 });
        defer testing.allocator.free(json_chats);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_chats, .{});
        defer chats.deinit();
        try a.chats.replace(chats.value);
        a.openChat("syn-1", null);

        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 960, .height = 680, .dark = false });
        defer t.deinit();
        t.settle(0.5);

        const more = a.view.more_anchor orelse return error.MissingMoreAnchor;
        t.moveTo(more.x + more.w / 2, more.y + more.h / 2);
        t.click(more.x + more.w / 2, more.y + more.h / 2);
        t.settle(0.3);

        var path_buf: [512]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&path_buf, "{s}/after-more-popover-light.png", .{out_dir}));
    }

    // 2. Upgraded Settings > Appearance (Custom themes & animated backdrops + Workspace mode cards).
    {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = true;
        a.settings.setTheme(true, "custom-kyoto-rain");
        @import("view_settings.zig").open(&a);
        a.settings.section = .appearance;

        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1120, .height = 1320, .dark = true });
        defer t.deinit();
        t.settle(0.5);
        // Scroll down so both Custom themes & animated backdrops and Workspace mode cards are framed.
        if (t.findText("Theme")) |anchor| {
            t.scroll(anchor.x + 20, anchor.y + 40, -480);
            t.settle(0.2);
        }

        var path_buf: [512]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&path_buf, "{s}/after-settings-appearance.png", .{out_dir}));
    }

    // 3. Dark Zen workspace showing Kyoto Rain theme + procedural rain backdrop canvas.
    {
        var a: App = .init(testing.allocator, testing.io, 1);
        defer a.deinit();
        a.offscreen = true;
        a.dark = true;
        a.settings.applyUiMode(.zen);
        a.settings.setTheme(true, "custom-kyoto-rain");
        a.settings.setBackdropScene("auto");
        a.settings.setBackdropMotionKey("gentle");
        a.settings.setBackdropOpacity(0.85);
        a.view.sidebar_open = true;
        const json_chats = try std.fmt.allocPrint(testing.allocator,
            \\[
            \\ {{"id":"syn-a","deviceId":"syn-dev","title":"Kyoto rain palette","cwd":"/synthetic/themes","archived":false,"updatedAt":{d},"config":{{"harness":"graff"}}}},
            \\ {{"id":"syn-b","deviceId":"syn-dev","title":"Backdrop scheduler verification","cwd":"/synthetic/perf","archived":false,"updatedAt":{d},"config":{{"harness":"graff"}}}}
            \\]
        , .{ now_ms - 120_000, now_ms - 480_000 });
        defer testing.allocator.free(json_chats);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_chats, .{});
        defer chats.deinit();
        try a.chats.replace(chats.value);

        var t: ui.Tester = undefined;
        try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 1040, .height = 700, .dark = true });
        defer t.deinit();
        t.settle(0.4);

        var path_buf: [512]u8 = undefined;
        try t.screenshot(try std.fmt.bufPrint(&path_buf, "{s}/after-kyoto-rain-backdrop.png", .{out_dir}));
    }
}
