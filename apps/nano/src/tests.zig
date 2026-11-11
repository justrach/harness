//! Every test: `zig build test`.
test {
    _ = @import("ws.zig");
    _ = @import("rpc.zig");
    _ = @import("workspace.zig");
    _ = @import("transcript.zig");
    _ = @import("engine.zig");
    _ = @import("app.zig");
    _ = @import("rules.zig");
    _ = @import("motion_rules.zig");
    _ = @import("veil.zig");
    _ = @import("tools.zig");
    _ = @import("compact.zig");
    _ = @import("steer_order.zig");
    _ = @import("prompt_history.zig");
    _ = @import("engine_start.zig");
    _ = @import("diff.zig");
    _ = @import("wizard.zig");
    _ = @import("termlog.zig");
    _ = @import("parity.zig");
    _ = @import("app_files.zig");
    _ = @import("queue.zig");
    _ = @import("app_queue.zig");
    _ = @import("chat_mode.zig");
    _ = @import("view_write.zig");
    _ = @import("archive_close.zig");
    _ = @import("tabs.zig");
    _ = @import("tests_ui.zig");
    _ = @import("tests_ui_picker.zig");
    _ = @import("tests_ui_history.zig");
    _ = @import("tests_ui_compact.zig");
    _ = @import("tests_ui_prompt_history.zig");
    _ = @import("tests_ui_caret.zig");
    _ = @import("app_drafts.zig");
    _ = @import("composer_defaults.zig");
    _ = @import("snap.zig");
    _ = @import("app_account.zig");
    _ = @import("settings.zig");
    _ = @import("shortcuts.zig");
    _ = @import("view_settings.zig");
    _ = @import("view_settings_devices.zig");
    _ = @import("view_settings_devices_updates.zig");
    _ = @import("view_settings_shortcuts.zig");
    _ = @import("view_settings_appearance.zig");
    _ = @import("view_drag.zig");
    _ = @import("view_settings_mcp.zig");
    _ = @import("bots.zig");
    _ = @import("bots_host.zig");
    _ = @import("view_bots.zig");
    _ = @import("tests_ui_bots.zig");
    _ = @import("runners.zig");
    _ = @import("view_settings_github_ci.zig");
    _ = @import("view_settings_archived.zig");
    _ = @import("agents.zig");
    _ = @import("view_settings_agents.zig");
    _ = @import("view_setup.zig");
    _ = @import("accounts.zig");
    _ = @import("view_settings_accounts.zig");
    _ = @import("view_settings_accounts_browse.zig");
    _ = @import("sandboxes.zig");
    _ = @import("app_sandboxes.zig");
    _ = @import("parity_sandboxes.zig");
    _ = @import("tests_ui_sandboxes.zig");
    _ = @import("run_errors.zig");
    _ = @import("reauth_recovery.zig");
    _ = @import("relay_callback.zig");
    _ = @import("view_reauth.zig");
    _ = @import("tests_ui_reauth.zig");
    _ = @import("pins.zig");
    _ = @import("view_chat_menu.zig");
    _ = @import("icons.zig");
    _ = @import("file_icons.zig");
    _ = @import("release.zig");
    _ = @import("view.zig");
    _ = @import("native_menu.zig");
    _ = @import("tests_ui_split.zig");
    _ = @import("tests_streaming.zig");
    _ = @import("tests_ui_streaming_visibility.zig");
    _ = @import("tests_ui_sidebar_motion.zig");
    _ = @import("markdown.zig");
    _ = @import("markdown_html.zig");
    _ = @import("highlight.zig");
    _ = @import("graff_worktree.zig");
    _ = @import("view_session_footer.zig");
    _ = @import("view_composer.zig");
    _ = @import("tests_ui_footer.zig");
    _ = @import("view_rail.zig");
    _ = @import("tests_ui_rail.zig");
    _ = @import("tests_ui_tooltips.zig");
    _ = @import("change_requests.zig");
    _ = @import("agent_updates.zig");
    _ = @import("tests_ui_change_requests.zig");
    _ = @import("palette.zig");
    _ = @import("tests_ui_palette.zig");
    _ = @import("tests_ui_setup.zig");
    _ = @import("tests_ui_archived.zig");
    _ = @import("tests_ui_devices.zig");
    _ = @import("tests_ui_hover.zig");
    _ = @import("themes.zig");
    _ = @import("model_color.zig");
    _ = @import("theme_import.zig");
    _ = @import("theme_library.zig");
    _ = @import("crash_log.zig");
    _ = @import("dictation.zig");
    _ = @import("app_dictation.zig");
    _ = @import("view_settings_theme_import.zig");
    _ = @import("profile.zig");
    _ = @import("tests_ui_input.zig");
    _ = @import("tests_attachments.zig");
    _ = @import("tests_ui_feedback.zig");
    _ = @import("tests_ui_glass.zig");
    _ = @import("surface_palette.zig");
    _ = @import("tests_ui_surfaces.zig");
    _ = @import("tests_browser_native.zig");
    _ = @import("theme.zig");
    _ = @import("view_newchat.zig");
    _ = @import("turn_work.zig");
    _ = @import("tool_diff.zig");
    _ = @import("context_window.zig");
    _ = @import("view_context.zig");
    _ = @import("tests_ui_desktop_sidebar_composer.zig");
    _ = @import("tests_ui_tool_tree.zig");
    _ = @import("tests_ui_actions_toolbar.zig");
    _ = @import("tests_ui_sessions.zig");
    _ = @import("tests_desktop_regressions.zig");
    _ = @import("view_attachment_drop.zig");
    _ = @import("tests_ui_project_setup.zig");
    _ = @import("tests_ui_open_chooser.zig");
    _ = @import("tests_ui_resize.zig");
    _ = @import("tests_ui_strip_folder_search.zig");
    _ = @import("tests_tab_layout.zig");
    _ = @import("project_paths.zig");
    _ = @import("graff_update.zig");
    _ = @import("view_updates.zig");
    _ = @import("sound.zig");
    _ = @import("chat2_wire.zig");
    _ = @import("session_doc.zig");
    _ = @import("docs_store.zig");
    _ = @import("ws_server.zig");
    _ = @import("acp_host.zig");
    _ = @import("adapters_host.zig");
    _ = @import("workspace_files_host.zig");
    _ = @import("git_host.zig");
    _ = @import("terminals_host.zig");
    _ = @import("registry_sync.zig");
    _ = @import("chat2_client.zig");
    _ = @import("auth_host.zig");
    _ = @import("agent_accounts_host.zig");
    _ = @import("run_journal.zig");
    _ = @import("mcp_server.zig");
    _ = @import("engine_host.zig");
    _ = @import("multi_machine_sync.zig");
    _ = @import("ios_scroll.zig");
    _ = @import("mobile_glass.zig");
    _ = @import("mobile_parity.zig");
    _ = @import("mobile_parity_tests.zig");
    _ = @import("ios_host.zig");
    _ = @import("view_mobile.zig");
}

test "auth_host.formatRfc3339Ms round-trips 1:1 with rules.parseTime" {
    const std = @import("std");
    const auth_host = @import("auth_host.zig");
    const rules = @import("rules.zig");
    const samples = [_]i64{
        0,
        1_700_000_000_123,
        1_794_334_057_524,
        1_799_884_800_000, // 2027-01-14T00:00:00.000Z
        1_835_395_200_999, // 2028-02-29 leap day
    };
    for (samples) |ms| {
        var buf: [32]u8 = undefined;
        const formatted = auth_host.formatRfc3339Ms(&buf, ms);
        try std.testing.expectEqual(@as(?i64, ms), rules.parseTime(formatted));
    }
}

test "Sync performance shape: O(1) hash-indexed + ?since=seq delta cursor is >= 10x faster than O(N^2) full rescan" {
    const std = @import("std");
    const engine_host = @import("engine_host.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const chat_count: usize = 350;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("{\"seq\":702,\"rows\":[");
    try w.writeAll("{\"kind\":\"devices\",\"id\":\"dev-synth-1\",\"deleted\":false,\"fields\":{\"id\":\"dev-synth-1\",\"name\":\"Synth MacBook\",\"platform\":\"macos\",\"lastSeenAt\":1794300000000,\"createdAt\":1794300000000}},");
    try w.writeAll("{\"kind\":\"spaces\",\"id\":\"space-synth-1\",\"deleted\":false,\"fields\":{\"id\":\"space-synth-1\",\"deviceId\":\"dev-synth-1\",\"path\":\"/tmp/synth-repo\",\"name\":\"synth-repo\",\"gitDetected\":true}}");
    for (0..chat_count) |i| {
        const ts: i64 = 1794300000000 + @as(i64, @intCast(i));
        try w.print(
            ",{{\"kind\":\"chats\",\"id\":\"chat-synth-{d}\",\"deleted\":false,\"fields\":{{\"id\":\"chat-synth-{d}\",\"spaceId\":\"space-synth-1\",\"deviceId\":\"dev-synth-1\",\"title\":\"Initial Chat {d}\",\"createdAt\":1794300000000,\"lastMessageAt\":{d},\"config\":{{\"harness\":\"graff\",\"model\":\"graff-sonnet\"}}}}}}",
            .{ i, i, i, ts },
        );
    }
    for (0..chat_count) |i| {
        const ts: i64 = 1794300100000 + @as(i64, @intCast(i));
        try w.print(
            ",{{\"kind\":\"sessions\",\"id\":\"chat-synth-{d}\",\"deleted\":false,\"fields\":{{\"chatId\":\"chat-synth-{d}\",\"status\":\"idle\",\"startedAt\":{d},\"updatedAt\":{d}}}}}",
            .{ i, i, ts, ts },
        );
    }
    try w.writeAll("]}");
    const full_json = aw.written();

    const quiet_delta = "{\"seq\":702,\"rows\":[]}";
    const update_delta =
        "{\"seq\":703,\"rows\":[" ++
        "{\"kind\":\"chats\",\"id\":\"chat-synth-42\",\"deleted\":false,\"fields\":{\"id\":\"chat-synth-42\",\"spaceId\":\"space-synth-1\",\"deviceId\":\"dev-synth-1\",\"title\":\"Renamed Fast Delta\",\"createdAt\":1794300000000,\"lastMessageAt\":1794399999000,\"config\":{\"harness\":\"graff\"}}}," ++
        "{\"kind\":\"sessions\",\"id\":\"chat-synth-42\",\"deleted\":false,\"fields\":{\"chatId\":\"chat-synth-42\",\"status\":\"working\",\"startedAt\":1794399998000,\"updatedAt\":1794399999000}}" ++
        "]}";
    const tombstone_delta =
        "{\"seq\":704,\"rows\":[{\"kind\":\"chats\",\"id\":\"chat-synth-7\",\"deleted\":true,\"fields\":{}}]}";

    // Also build the final full snapshot matching seq 704 for the naive O(N^2) rescan baseline.
    var aw_final: std.Io.Writer.Allocating = .init(gpa);
    defer aw_final.deinit();
    const wf = &aw_final.writer;
    try wf.writeAll("{\"seq\":704,\"rows\":[");
    try wf.writeAll("{\"kind\":\"devices\",\"id\":\"dev-synth-1\",\"deleted\":false,\"fields\":{\"id\":\"dev-synth-1\",\"name\":\"Synth MacBook\",\"platform\":\"macos\",\"lastSeenAt\":1794300000000,\"createdAt\":1794300000000}},");
    try wf.writeAll("{\"kind\":\"spaces\",\"id\":\"space-synth-1\",\"deleted\":false,\"fields\":{\"id\":\"space-synth-1\",\"deviceId\":\"dev-synth-1\",\"path\":\"/tmp/synth-repo\",\"name\":\"synth-repo\",\"gitDetected\":true}}");
    for (0..chat_count) |i| {
        if (i == 7) {
            try wf.writeAll(",{\"kind\":\"chats\",\"id\":\"chat-synth-7\",\"deleted\":true,\"fields\":{}}");
        } else if (i == 42) {
            try wf.writeAll(",{\"kind\":\"chats\",\"id\":\"chat-synth-42\",\"deleted\":false,\"fields\":{\"id\":\"chat-synth-42\",\"spaceId\":\"space-synth-1\",\"deviceId\":\"dev-synth-1\",\"title\":\"Renamed Fast Delta\",\"createdAt\":1794300000000,\"lastMessageAt\":1794399999000,\"config\":{\"harness\":\"graff\"}}}");
        } else {
            const ts: i64 = 1794300000000 + @as(i64, @intCast(i));
            try wf.print(
                ",{{\"kind\":\"chats\",\"id\":\"chat-synth-{d}\",\"deleted\":false,\"fields\":{{\"id\":\"chat-synth-{d}\",\"spaceId\":\"space-synth-1\",\"deviceId\":\"dev-synth-1\",\"title\":\"Initial Chat {d}\",\"createdAt\":1794300000000,\"lastMessageAt\":{d},\"config\":{{\"harness\":\"graff\",\"model\":\"graff-sonnet\"}}}}}}",
                .{ i, i, i, ts },
            );
        }
    }
    for (0..chat_count) |i| {
        if (i == 7) {
            try wf.writeAll(",{\"kind\":\"chats\",\"id\":\"chat-synth-7\",\"deleted\":true,\"fields\":{}}");
        } else if (i == 42) {
            try wf.writeAll(",{\"kind\":\"sessions\",\"id\":\"chat-synth-42\",\"deleted\":false,\"fields\":{\"chatId\":\"chat-synth-42\",\"status\":\"working\",\"startedAt\":1794399998000,\"updatedAt\":1794399999000}}");
        } else {
            const ts: i64 = 1794300100000 + @as(i64, @intCast(i));
            try wf.print(
                ",{{\"kind\":\"sessions\",\"id\":\"chat-synth-{d}\",\"deleted\":false,\"fields\":{{\"chatId\":\"chat-synth-{d}\",\"status\":\"idle\",\"startedAt\":{d},\"updatedAt\":{d}}}}}",
                .{ i, i, ts, ts },
            );
        }
    }
    try wf.writeAll("]}");
    const full_final_json = aw_final.written();

    var host_slow = try engine_host.EngineHost.init(gpa, "dev-local", "Local");
    defer host_slow.deinit();
    var host_fast = try engine_host.EngineHost.init(gpa, "dev-local", "Local");
    defer host_fast.deinit();

    const t0 = std.Io.Clock.awake.now(io);
    for (0..19) |_| {
        _ = host_slow.applyRegistryRowsNaiveLinearForBench(full_json);
    }
    _ = host_slow.applyRegistryRowsNaiveLinearForBench(full_final_json);
    const t1 = std.Io.Clock.awake.now(io);

    const t2 = std.Io.Clock.awake.now(io);
    try std.testing.expect(host_fast.applyRegistryResponseJson("org-synth-1", full_json, false));
    for (0..17) |_| {
        try std.testing.expect(!host_fast.applyRegistryResponseJson("org-synth-1", quiet_delta, false));
    }
    try std.testing.expect(host_fast.applyRegistryResponseJson("org-synth-1", update_delta, false));
    try std.testing.expect(host_fast.applyRegistryResponseJson("org-synth-1", tombstone_delta, false));
    const t3 = std.Io.Clock.awake.now(io);

    const slow_ns: i96 = t0.durationTo(t1).toNanoseconds();
    const fast_ns: i96 = @max(@as(i96, 1), t2.durationTo(t3).toNanoseconds());

    try std.testing.expectEqual(@as(u64, 704), host_fast.registry_seq);
    try std.testing.expectEqual(@as(usize, chat_count - 1), host_fast.chats.items.len);
    try std.testing.expectEqual(host_slow.chats.items.len, host_fast.chats.items.len);

    var found_42 = false;
    for (host_fast.chats.items) |c| {
        try std.testing.expect(!std.mem.eql(u8, c.id, "chat-synth-7"));
        if (std.mem.eql(u8, c.id, "chat-synth-42")) {
            found_42 = true;
            try std.testing.expectEqualStrings("Renamed Fast Delta", c.title.?);
            try std.testing.expectEqual(@as(i64, 1794399999000), c.last_message_at_ms);
            try std.testing.expectEqualStrings("working", c.activity_status.?);
        }
    }
    try std.testing.expect(found_42);

    // Shape assertion (`AGENTS.md`): O(1) hash-indexed + delta cursor path must be >= 10x faster.
    try std.testing.expect(fast_ns * 10 <= slow_ns);
}

test "Zero-latency SSD registry-cache.json + tail disk cache round-trip with 0 leaks" {
    const std = @import("std");
    const engine_host = @import("engine_host.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const tmp_dir = "/tmp/harness-zig-synth-ssd-sync-cache-test";
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);

    {
        var writer_host = try engine_host.EngineHost.init(gpa, "dev-local", "Local");
        defer writer_host.deinit();
        writer_host.io = io;
        try writer_host.setDataDir(tmp_dir);

        const payload =
            "{\"seq\":88,\"rows\":[" ++
            "{\"kind\":\"devices\",\"id\":\"dev-remote-1\",\"deleted\":false,\"fields\":{\"id\":\"dev-remote-1\",\"name\":\"Remote Host\",\"platform\":\"linux\",\"lastSeenAt\":1794300001000,\"createdAt\":1794300001000}}," ++
            "{\"kind\":\"spaces\",\"id\":\"space-remote-1\",\"deleted\":false,\"fields\":{\"id\":\"space-remote-1\",\"deviceId\":\"dev-remote-1\",\"path\":\"/srv/app\",\"name\":\"app\",\"gitDetected\":true}}," ++
            "{\"kind\":\"chats\",\"id\":\"chat-remote-1\",\"deleted\":false,\"fields\":{\"id\":\"chat-remote-1\",\"spaceId\":\"space-remote-1\",\"deviceId\":\"dev-remote-1\",\"title\":\"Instant Warm Boot\",\"createdAt\":1794300002000,\"lastMessageAt\":1794300003000,\"config\":{\"harness\":\"graff\",\"model\":\"graff-sonnet\"}}}," ++
            "{\"kind\":\"sessions\",\"id\":\"chat-remote-1\",\"deleted\":false,\"fields\":{\"chatId\":\"chat-remote-1\",\"status\":\"idle\",\"startedAt\":1794300003000,\"updatedAt\":1794300003000}}" ++
            "]}";
        try std.testing.expect(writer_host.applyRegistryResponseJson("org-personal", payload, true));

        const tail_msgs = try gpa.dupe(u8, "[{\"id\":\"m1\",\"role\":\"user\",\"content\":\"hello instant ssd\",\"timestamp\":\"2026-11-10T18:00:03.000Z\"}]");
        try std.testing.expect(writer_host.storeCachedTailInMemoryOwned("chat-remote-1", tail_msgs, true) != null);
    }

    // Boot a brand-new cold EngineHost with ZERO network access and restore everything from SSD.
    var cold_host = try engine_host.EngineHost.init(gpa, "dev-local", "Local");
    defer cold_host.deinit();
    cold_host.io = io;
    try cold_host.setDataDir(tmp_dir);

    try std.testing.expect(cold_host.loadPersistedRegistryCache(io));
    try std.testing.expectEqual(@as(u64, 88), cold_host.registry_seq);
    try std.testing.expectEqual(@as(usize, 1), cold_host.spaces.items.len);
    try std.testing.expectEqual(@as(usize, 1), cold_host.chats.items.len);
    try std.testing.expectEqualStrings("Instant Warm Boot", cold_host.chats.items[0].title.?);
    try std.testing.expectEqual(@as(i64, 1794300003000), cold_host.chats.items[0].last_message_at_ms);

    const restored_tail = cold_host.lookupCachedTailJson("chat-remote-1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, restored_tail, "hello instant ssd") != null);
}

test "Delta chat update never reads freed ChatRecord.id key in chat_idx (UAF regression)" {
    const std = @import("std");
    const engine_host = @import("engine_host.zig");

    // Back every allocation with an independent OS page (`std.heap.page_allocator`) so `free`
    // immediately `munmap`s the page—deterministically reproducing the exact ReleaseSafe
    // `SafeAllocator` bucket-unmap condition when `existing.id` is freed during delta upsert.
    const UnmapCheckAllocator = struct {
        live_allocs: usize = 0,

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const ptr = std.heap.page_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
            self.live_allocs += 1;
            return ptr;
        }

        fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            _ = ctx;
            return std.heap.page_allocator.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            _ = ctx;
            return std.heap.page_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.live_allocs -= 1;
            std.heap.page_allocator.rawFree(memory, alignment, ret_addr);
        }

        fn allocator(self: *@This()) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .remap = remap,
                    .free = free,
                },
            };
        }
    };

    var guard: UnmapCheckAllocator = .{};
    const gpa = guard.allocator();

    {
        var host = try engine_host.EngineHost.init(gpa, "dev-local", "Local");
        defer host.deinit();

        const seed =
            "{\"seq\":1,\"rows\":[" ++
            "{\"kind\":\"spaces\",\"id\":\"space-uaf-1\",\"deleted\":false,\"fields\":{\"id\":\"space-uaf-1\",\"deviceId\":\"dev-local\",\"path\":\"/tmp/synth\",\"name\":\"synth\",\"gitDetected\":true}}," ++
            "{\"kind\":\"chats\",\"id\":\"chat-uaf-target\",\"deleted\":false,\"fields\":{\"id\":\"chat-uaf-target\",\"spaceId\":\"space-uaf-1\",\"deviceId\":\"dev-local\",\"title\":\"Before Delta\",\"createdAt\":1794300000000,\"lastMessageAt\":1794300001000,\"config\":{\"harness\":\"graff\"}}}" ++
            "]}";
        try std.testing.expect(host.applyRegistryResponseJson("org-synth", seed, false));

        // Delta updating the already-indexed chat twice in one batch plus attaching session state.
        const delta =
            "{\"seq\":2,\"rows\":[" ++
            "{\"kind\":\"chats\",\"id\":\"chat-uaf-target\",\"deleted\":false,\"fields\":{\"id\":\"chat-uaf-target\",\"spaceId\":\"space-uaf-1\",\"deviceId\":\"dev-local\",\"title\":\"After Delta 1\",\"createdAt\":1794300000000,\"lastMessageAt\":1794300002000,\"config\":{\"harness\":\"graff\"}}}," ++
            "{\"kind\":\"chats\",\"id\":\"chat-uaf-target\",\"deleted\":false,\"fields\":{\"id\":\"chat-uaf-target\",\"spaceId\":\"space-uaf-1\",\"deviceId\":\"dev-local\",\"title\":\"After Delta 2\",\"createdAt\":1794300000000,\"lastMessageAt\":1794300003000,\"config\":{\"harness\":\"graff\"}}}," ++
            "{\"kind\":\"sessions\",\"id\":\"chat-uaf-target\",\"deleted\":false,\"fields\":{\"chatId\":\"chat-uaf-target\",\"status\":\"working\",\"startedAt\":1794300002500,\"updatedAt\":1794300003000}}" ++
            "]}";
        try std.testing.expect(host.applyRegistryResponseJson("org-synth", delta, false));
        try std.testing.expectEqual(@as(usize, 1), host.chats.items.len);
        try std.testing.expectEqualStrings("After Delta 2", host.chats.items[0].title.?);
        try std.testing.expectEqualStrings("working", host.chats.items[0].activity_status.?);
    }

    try std.testing.expectEqual(@as(usize, 0), guard.live_allocs);
}
