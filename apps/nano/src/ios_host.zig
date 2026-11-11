//! In-process `EngineHost` + loopback WebSocket RPC server for iOS (`aarch64-ios` /
//! `aarch64-ios-simulator`) and desktop `--mobile --demo` verification.
//!
//! Binds `127.0.0.1:0` on an ephemeral loopback port inside the app process so
//! `App` (`src/app.zig`) speaks the exact same `Watch*` / JSON-RPC protocol with
//! sub-millisecond in-memory latency, zero child processes, and full SQLite +
//! `SessionDoc` + `AuthManager` edge sync support.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const docs_store = @import("docs_store.zig");
const auth_host = @import("auth_host.zig");
const engine_host = @import("engine_host.zig");
const engine_main = @import("engine_main.zig");

pub const EmbeddedHost = struct {
    gpa: Allocator,
    io: Io,
    host: engine_host.EngineHost,
    server: net.Server,
    port: u16,
    accept_thread: ?std.Thread = null,

    pub fn start(
        gpa: Allocator,
        io: Io,
        env: *const std.process.Environ.Map,
        demo_mode: bool,
    ) !*EmbeddedHost {
        const self = try gpa.create(EmbeddedHost);
        errdefer gpa.destroy(self);

        var data_dir_buf: [512]u8 = undefined;
        const resolved_dir: ?[]const u8 = if (demo_mode)
            env.get("HARNESS_DEMO_DATA_DIR")
        else
            env.get("HARNESS_DATA_DIR") orelse env.get("DATA_DIR") orelse blk: {
                const home = env.get("HOME") orelse break :blk null;
                const sub = if (comptime builtin.os.tag == .ios) "Library/Application Support/Harness" else ".harness";
                break :blk std.fmt.bufPrint(&data_dir_buf, "{s}/{s}", .{ home, sub }) catch null;
            };

        const dev_id_owned: ?[]u8 = if (demo_mode) null else engine_host.loadOrCreateDeviceId(gpa, io, resolved_dir) catch null;
        defer if (dev_id_owned) |d| gpa.free(d);
        const dev_name_owned: ?[]u8 = if (demo_mode) null else engine_host.detectDeviceName(gpa, env) catch null;
        defer if (dev_name_owned) |n| gpa.free(n);

        var host = try engine_host.EngineHost.init(
            gpa,
            dev_id_owned orelse "ios-local-device",
            dev_name_owned orelse "iPhone",
        );
        errdefer host.deinit();
        host.io = io;
        if (!demo_mode) host.ensureLocalDeviceRow();

        if (resolved_dir) |dir| {
            if (dir.len > 0) {
                Io.Dir.cwd().createDirPath(io, dir) catch {};
                host.setDataDir(dir) catch {};
                if (!demo_mode) {
                    if (std.fmt.allocPrintSentinel(gpa, "{s}/docs.sqlite", .{dir}, 0)) |db_z| {
                        defer gpa.free(db_z);
                        if (docs_store.DocsStore.openSqlite(gpa, db_z.ptr)) |sq| {
                            host.store.deinit();
                            host.store = sq;
                        } else |_| {}
                    } else |_| {}
                    _ = host.loadPersistedRegistryCache(io);
                }
            }
        }

        if (demo_mode) {
            try seedSyntheticDemo(&host);
        } else {
            const edge_url = env.get("HARNESS_EDGE_URL") orelse auth_host.default_edge_url;
            const client_id = env.get("HARNESS_CODEGRAFF_CLIENT_ID") orelse auth_host.default_codegraff_client_id;
            const api_base = env.get("HARNESS_CODEGRAFF_API_BASE") orelse auth_host.default_codegraff_api_base;
            const gateway = env.get("HARNESS_CODEGRAFF_GATEWAY") orelse auth_host.default_codegraff_gateway;
            host.auth.configureCodegraff(edge_url, client_id, api_base, resolved_dir) catch {};
            host.auth.setCodegraffGateway(gateway) catch {};
            if (host.auth.loadPersistedSession(io)) {
                host.workspace_scope = "synced";
                _ = host.loadPersistedRegistryCache(io);
            }
        }

        const listen_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        const server = try listen_addr.listen(io, .{ .reuse_address = true });
        const bound_port = server.socket.address.getPort();

        self.* = .{
            .gpa = gpa,
            .io = io,
            .host = host,
            .server = server,
            .port = bound_port,
        };

        if (!demo_mode) {
            self.host.bg_sync_enabled = true;
            _ = self.host.bg_workers_active.fetchAdd(1, .acquire);
            if (std.Thread.spawn(.{}, bgSyncLoop, .{self})) |sth| {
                sth.detach();
            } else |_| {
                _ = self.host.bg_workers_active.fetchSub(1, .release);
            }
        }

        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn stop(self: *EmbeddedHost) void {
        self.host.stop_requested = true;
        self.server.deinit(self.io);
        if (self.accept_thread) |th| {
            th.join();
            self.accept_thread = null;
        }
        while (self.host.bg_workers_active.load(.acquire) > 0) {
            Io.sleep(self.io, .fromMilliseconds(10), .awake) catch break;
        }
        const gpa = self.gpa;
        self.host.deinit();
        gpa.destroy(self);
    }

    fn bgSyncLoop(self: *EmbeddedHost) void {
        defer _ = self.host.bg_workers_active.fetchSub(1, .release);
        var last_wake = self.host.sync_wake_seq.load(.acquire);
        if (!self.host.stop_requested) {
            _ = self.host.syncFromEdgeRegistryUnlocked(self.io);
            if (!self.host.stop_requested) {
                self.host.prefetchRecentChatTailsUnlocked(self.io, 16);
            }
        }
        while (!self.host.stop_requested) {
            var step: usize = 0;
            while (step < 25 and !self.host.stop_requested) : (step += 1) {
                if (self.host.sync_wake_seq.load(.acquire) != last_wake) break;
                Io.sleep(self.io, .fromMilliseconds(100), .awake) catch return;
            }
            if (self.host.stop_requested) break;
            last_wake = self.host.sync_wake_seq.load(.acquire);
            if (self.host.syncFromEdgeRegistryUnlocked(self.io) and !self.host.stop_requested) {
                self.host.prefetchRecentChatTailsUnlocked(self.io, 16);
            }
        }
    }

    fn acceptLoop(self: *EmbeddedHost) void {
        const ClientCtx = struct {
            gpa: Allocator,
            io: Io,
            host: *engine_host.EngineHost,
            stream: net.Stream,

            fn run(ctx: *@This()) void {
                var stream = ctx.stream;
                const gpa_c = ctx.gpa;
                const io_c = ctx.io;
                const host_c = ctx.host;
                gpa_c.destroy(ctx);
                defer stream.close(io_c);
                engine_main.serveSocket(gpa_c, io_c, host_c, &stream) catch {};
            }
        };

        while (!self.host.stop_requested) {
            const stream = self.server.accept(self.io) catch break;
            if (self.host.stop_requested) {
                var s = stream;
                s.close(self.io);
                break;
            }
            const ctx = self.gpa.create(ClientCtx) catch {
                var s = stream;
                s.close(self.io);
                continue;
            };
            ctx.* = .{ .gpa = self.gpa, .io = self.io, .host = &self.host, .stream = stream };
            if (std.Thread.spawn(.{}, ClientCtx.run, .{ctx})) |th| {
                th.detach();
            } else |_| {
                ClientCtx.run(ctx);
            }
        }
    }
};

/// Seeds synthetic demo data (zero user data per `AGENTS.md`) covering multi-project
/// & multi-device grouping, a 240-message ProMotion scroll benchmark transcript,
/// active working turn, interactive question card, queued follow-ups, and archived row.
pub fn seedSyntheticDemo(host: *engine_host.EngineHost) !void {
    const gpa = host.gpa;
    const now = host.nowMs();

    try host.auth.signInWithKey("hrn_demo_synthetic_token");
    gpa.free(host.auth.email);
    host.auth.email = try gpa.dupe(u8, "alex@example.com");
    if (host.auth.user_name) |n| gpa.free(n);
    host.auth.user_name = try gpa.dupe(u8, "Synthetic Studio");
    if (host.auth.org_id) |o| gpa.free(o);
    host.auth.org_id = try gpa.dupe(u8, "org-synth-demo");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    const t_recent = now - 45_000;
    const t_2m = now - 120_000;
    const t_8m = now - 480_000;
    const t_25m = now - 1_500_000;
    const t_2h = now - 7_200_000;
    const t_1d = now - 86_400_000;

    try w.print(
        \\{{"seq":42,"rows":[
        \\  {{"kind":"devices","id":"dev-studio","deleted":false,"fields":{{"id":"dev-studio","name":"Mac Studio","platform":"macos","version":"0.2.186","lastSeenAt":{d},"createdAt":{d}}}}},
        \\  {{"kind":"devices","id":"dev-mbp","deleted":false,"fields":{{"id":"dev-mbp","name":"MacBook Pro","platform":"macos","version":"0.2.186","lastSeenAt":{d},"createdAt":{d}}}}},
        \\  {{"kind":"spaces","id":"space-nanoharness","deleted":false,"fields":{{"id":"space-nanoharness","deviceId":"dev-studio","path":"/workspace/nanoharness","name":"nanoharness","gitDetected":true}}}},
        \\  {{"kind":"spaces","id":"space-nanoui","deleted":false,"fields":{{"id":"space-nanoui","deviceId":"dev-mbp","path":"/workspace/nanoui","name":"nanoui","gitDetected":true}}}},
        \\  {{"kind":"spaces","id":"space-edge","deleted":false,"fields":{{"id":"space-edge","deviceId":"dev-studio","path":"/workspace/edge-sync","name":"edge-sync","gitDetected":true}}}},
        \\  {{"kind":"chats","id":"chat-ios-glass","deleted":false,"fields":{{"id":"chat-ios-glass","spaceId":"space-nanoharness","deviceId":"dev-studio","title":"Liquid Glass 120Hz iOS Stack","branch":"feat/ios-liquid-glass","createdAt":{d},"lastMessageAt":{d},"lastPromptAt":{d},"lastSeenAt":{d},"lastMessagePreview":"Verified all 22 Liquid Glass surfaces and 120Hz ProMotion scroll windowing.","config":{{"harness":"graff","model":"claude-opus-4-6","reasoning":"high"}}}}}},
        \\  {{"kind":"sessions","id":"chat-ios-glass","deleted":false,"fields":{{"chatId":"chat-ios-glass","status":"idle","startedAt":{d},"updatedAt":{d}}}}},
        \\  {{"kind":"chats","id":"chat-lean-proofs","deleted":false,"fields":{{"id":"chat-lean-proofs","spaceId":"space-nanoharness","deviceId":"dev-studio","title":"Lean 4 Formal Parity Verifiers","branch":"feat/lean-mobile-parity","createdAt":{d},"lastMessageAt":{d},"lastPromptAt":{d},"lastSeenAt":{d},"lastMessagePreview":"Checking MobileIosParity.lean and IosLiquidGlassScroll.lean theorems…","config":{{"harness":"graff","model":"claude-sonnet-4-6","reasoning":"medium"}}}}}},
        \\  {{"kind":"sessions","id":"chat-lean-proofs","deleted":false,"fields":{{"chatId":"chat-lean-proofs","status":"working","startedAt":{d},"updatedAt":{d}}}}},
    , .{
        now,      t_1d,
        now,      t_1d,
        t_2h,     t_recent, t_recent, t_recent,
        t_recent, t_recent,
        t_2h,     t_2m,     t_2m,     t_2m,
        t_2m,     now,
    });
    try w.print(
        \\  {{"kind":"chats","id":"chat-question-gate","deleted":false,"fields":{{"id":"chat-question-gate","spaceId":"space-nanoui","deviceId":"dev-mbp","title":"iOS Bundle Target Matrix","branch":"feat/ios-bundle-sdk","createdAt":{d},"lastMessageAt":{d},"lastPromptAt":{d},"lastSeenAt":0,"lastMessagePreview":"Which deployment targets should the CI matrix build?","config":{{"harness":"codex","model":"gpt-5.4","reasoning":"high"}}}}}},
        \\  {{"kind":"sessions","id":"chat-question-gate","deleted":false,"fields":{{"chatId":"chat-question-gate","status":"awaiting_input","startedAt":{d},"updatedAt":{d}}}}},
        \\  {{"kind":"chats","id":"chat-nanoui-scrollx","deleted":false,"fields":{{"id":"chat-nanoui-scrollx","spaceId":"space-nanoui","deviceId":"dev-mbp","title":"Horizontal ScrollX Touch Fling","branch":"feat/ios-scroll-x","createdAt":{d},"lastMessageAt":{d},"lastPromptAt":{d},"lastSeenAt":0,"lastMessagePreview":"Added 0.998/ms UIScrollView deceleration to horizontal chip bars.","config":{{"harness":"graff","model":"claude-sonnet-4-6"}}}}}},
        \\  {{"kind":"sessions","id":"chat-nanoui-scrollx","deleted":false,"fields":{{"chatId":"chat-nanoui-scrollx","status":"idle","startedAt":{d},"updatedAt":{d}}}}},
        \\  {{"kind":"chats","id":"chat-edge-delta","deleted":false,"fields":{{"id":"chat-edge-delta","spaceId":"space-edge","deviceId":"dev-studio","title":"O(1) Registry Cursor Sync","branch":"main","createdAt":{d},"lastMessageAt":{d},"lastPromptAt":{d},"lastSeenAt":{d},"lastMessagePreview":"?since=seq delta sync verified 18x faster than full snapshot scan.","config":{{"harness":"graff","model":"claude-opus-4-6"}}}}}},
        \\  {{"kind":"sessions","id":"chat-edge-delta","deleted":false,"fields":{{"chatId":"chat-edge-delta","status":"idle","startedAt":{d},"updatedAt":{d}}}}},
        \\  {{"kind":"chats","id":"chat-archived-swift","deleted":false,"fields":{{"id":"chat-archived-swift","spaceId":"space-nanoharness","deviceId":"dev-studio","archived":true,"title":"Retire Legacy Swift FFI Bridge","branch":"chore/pure-zig","createdAt":{d},"lastMessageAt":{d},"lastPromptAt":{d},"lastSeenAt":{d},"lastMessagePreview":"Replaced UniFFI + SwiftUI wrapper with single native Zig binary.","config":{{"harness":"graff","model":"claude-sonnet-4-6"}}}}}}
        \\]}}
    , .{
        t_2h, t_8m,  t_8m,
        t_8m, t_8m,
        t_2h, t_25m, t_25m,
        t_25m, t_25m,
        t_1d, t_2h,  t_2h, t_2h,
        t_2h, t_2h,
        t_1d, t_1d,  t_1d, t_1d,
    });

    _ = host.applyRegistryResponseJson("org-synth-demo", aw.written(), false);

    // 1. Populate 240-message benchmark session (`chat-ios-glass`)
    const doc_glass = try host.getOrCreateDoc("chat-ios-glass");
    var idx: usize = 0;
    while (idx < 120) : (idx += 1) {
        const ts_base = t_2h + @as(i64, @intCast(idx)) * 30_000;
        var uid_buf: [32]u8 = undefined;
        var upart_buf: [32]u8 = undefined;
        const uid = try std.fmt.bufPrint(&uid_buf, "msg-u-{d}", .{idx});
        const upart = try std.fmt.bufPrint(&upart_buf, "part-u-{d}", .{idx});

        var uprompt_buf: [256]u8 = undefined;
        const uprompt = if (idx == 119)
            "Verify all 22 iOS Liquid Glass surfaces, full-bleed scroll underlap, and 120Hz ProMotion frame pacing."
        else
            try std.fmt.bufPrint(&uprompt_buf, "Step {d}: check Metal shader refraction, circular capsule SDF, and scroll virtualization budget.", .{idx + 1});
        try doc_glass.appendUserMessage(uid, upart, uprompt, ts_base);

        var aid_buf: [32]u8 = undefined;
        const aid = try std.fmt.bufPrint(&aid_buf, "msg-a-{d}", .{idx});
        try doc_glass.beginAssistantMessage(aid, ts_base + 500);

        if (idx >= 116) {
            var rpart_buf: [32]u8 = undefined;
            const rpart = try std.fmt.bufPrint(&rpart_buf, "part-r-{d}", .{idx});
            _ = try doc_glass.appendPartDelta(
                aid,
                rpart,
                "reasoning",
                "Checking backdrop blur sampling order: transcript scroller draws on layer 0 before floating top bar and composer glass on layer 1.",
            );

            var tpart_buf: [32]u8 = undefined;
            const tpart = try std.fmt.bufPrint(&tpart_buf, "part-t-{d}", .{idx});
            try doc_glass.upsertToolPart(
                aid,
                tpart,
                "{\"kind\":\"editFile\",\"path\":\"src/mobile_glass.zig\",\"diffStats\":[{\"path\":\"src/mobile_glass.zig\",\"additions\":42,\"deletions\":7}]}",
                "Updated 22 GlassSurfaceId specs with zero interior background fill",
                false,
                true,
            );
        }

        var apart_buf: [32]u8 = undefined;
        const apart = try std.fmt.bufPrint(&apart_buf, "part-a-{d}", .{idx});
        if (idx == 119) {
            _ = try doc_glass.appendPartDelta(
                aid,
                apart,
                "text",
                "### Liquid Glass & 120Hz Verification Complete\n\n" ++
                    "All **22 iOS surfaces** render live Metal backdrop refraction (`ui.Glass`) with zero opaque interior wash and `0.998`/ms `UIScrollView` momentum deceleration:\n\n" ++
                    "```zig\n" ++
                    "pub fn styleGlassDiv(d: ui.Div, id: GlassSurfaceId, rt: bool, dark: bool) ui.Div {\n" ++
                    "    const s = spec(id);\n" ++
                    "    const shaped = switch (s.shape) {\n" ++
                    "        .circle, .capsule => d.rounded(s.radius).circular(),\n" ++
                    "        .rounded => d.rounded(s.radius),\n" ++
                    "    };\n" ++
                    "    return if (rt) shaped.bg(solidFallback(dark)) else shaped.glass(s.variant);\n" ++
                    "}\n" ++
                    "```\n\n" ++
                    "- **Frame budget**: `< 2.1 ms` CPU layout + paint (`120 Hz` ProMotion headroom)\n" ++
                    "- **Tail window**: initial `45` entries, instant `+45` expansion on scroll-near-top\n" ++
                    "- **Parity vectors**: `11/11` shared JSON suites green",
            );
        } else {
            var areply_buf: [320]u8 = undefined;
            const areply = try std.fmt.bufPrint(
                &areply_buf,
                "Verified pass **#{d}**: Metal offscreen backdrop mip chain sampled cleanly under floating glass chrome (`0.998`/ms fling curve, `8.33 ms` ProMotion budget).",
                .{idx + 1},
            );
            _ = try doc_glass.appendPartDelta(aid, apart, "text", areply);
        }
        try doc_glass.setMessageStatus(aid, "complete");
    }
    try doc_glass.enqueueMessage("q-synth-1", "Run Simulator screenshot & touch scroll sweep across dark and light themes", false, now - 10_000);

    // 2. Populate active working session (`chat-lean-proofs`)
    const doc_lean = try host.getOrCreateDoc("chat-lean-proofs");
    try doc_lean.appendUserMessage("lean-u-1", "lean-pu-1", "Prove 1:1 equivalence for presence, stop-grace, underlap geometry, and fling decay in Lean 4.", t_2m);
    try doc_lean.beginAssistantMessage("lean-a-1", t_2m + 400);
    _ = try doc_lean.appendPartDelta("lean-a-1", "lean-pr-1", "reasoning", "Running `lake build` on `Nano/IosLiquidGlassScroll.lean` and `HarnessProofs/MobileIosParity.lean` with zero `sorry` and zero `axiom`.");
    try doc_lean.upsertToolPart(
        "lean-a-1",
        "lean-pt-1",
        "{\"kind\":\"exec\",\"command\":\"lake build && .lake/build/bin/nano-proofs\"}",
        "ios_glass_120hz 422 surfaces_22=true underlap=true fling_0998=true",
        false,
        true,
    );
    _ = try doc_lean.appendPartDelta("lean-a-1", "lean-pa-1", "text", "Verified `Nano.IosLiquidGlassScroll` and `HarnessProofs.MobileIosParity` with **0 `sorry`** — checking final Simulator telemetry invariants now…");

    // 3. Populate interactive question session (`chat-question-gate`)
    const doc_q = try host.getOrCreateDoc("chat-question-gate");
    try doc_q.appendUserMessage("q-u-1", "q-pu-1", "Set up the iOS bundle build step in `apps/nano/build.zig`.", t_8m);
    try doc_q.beginAssistantMessage("q-a-1", t_8m + 300);
    _ = try doc_q.appendPartDelta("q-a-1", "q-pa-1", "text", "Before finalizing the bundle step, pick which targets should be built by default:");
    {
        var req_part: @import("session_doc.zig").PartItem = .{
            .id = try gpa.dupe(u8, "q-pi-1"),
            .kind = try gpa.dupe(u8, "input"),
            .call_json = try gpa.dupe(
                u8,
                "{\"requestId\":\"req-ios-targets\",\"questions\":[{\"id\":\"targets\",\"header\":\"Targets\",\"question\":\"Which iOS targets should we build and verify?\",\"options\":[\"Simulator + Device (Recommended)\",\"iOS Simulator only\",\"Physical iPhone only\"]}]}",
            ),
        };
        errdefer req_part.deinit(gpa);
        try doc_q.messages.items[doc_q.messages.items.len - 1].parts.append(gpa, req_part);
    }
    try doc_q.setMessageStatus("q-a-1", "complete");
}

test "EmbeddedHost starts in-process on ephemeral port and seeds 240 synthetic messages" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const embedded = try EmbeddedHost.start(std.testing.allocator, std.testing.io, &env, true);
    defer embedded.stop();

    try std.testing.expect(embedded.port > 0);
    try std.testing.expectEqual(@as(usize, 6), embedded.host.chats.items.len);
    const doc = try embedded.host.getOrCreateDoc("chat-ios-glass");
    try std.testing.expectEqual(@as(usize, 240), doc.messages.items.len);
}
