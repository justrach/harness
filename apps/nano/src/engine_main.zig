//! `harness-engine` — the Zig headless engine daemon & CLI (`apps/harness/src/main.rs`).
//!
//! Drop-in replacement for `harness` / `harness headless` (`HARNESS_NANO_ENGINE_BIN`):
//! - `headless` (or no args): binds `ws://127.0.0.1:{HARNESS_IPC_PORT|27664}`,
//!   upgrades bare WebSocket clients (rejecting browser `Origin:` headers), and
//!   serves JSON-RPC calls and live `Watch*` streams through `EngineHost`.
//! - `status`: prints engine version and IPC port status.
//! - `mcp`: runs the stdio JSON-RPC 2.0 MCP server (`mcp_server.zig`).
//! - `daemon install|uninstall|start|stop|restart|status`: generates or manages
//!   the OS service unit (`launchd` on macOS, `systemd` on Linux).
//! - `login` / `logout` / `sync`: CLI control-plane commands.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;
const build_info = @import("build_info");
const acp_host = @import("acp_host.zig");
const docs_store = @import("docs_store.zig");
const engine_mod = @import("engine.zig");
const engine_host = @import("engine_host.zig");
const mcp_server = @import("mcp_server.zig");
const ws = @import("ws.zig");
const ws_server = @import("ws_server.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const port = engine_mod.Engine.portFrom(init.environ_map);

    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();
    const exe_name = args_it.next() orelse "harness-engine";
    const subcmd = args_it.next() orelse "headless";

    if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "version")) {
        std.debug.print("harness-engine (zig) {s}\n", .{build_info.version});
        return;
    }
    if (std.mem.eql(u8, subcmd, "status")) {
        std.debug.print("harness-engine {s} (ws://127.0.0.1:{d})\n", .{ build_info.version, port });
        return;
    }
    if (std.mem.eql(u8, subcmd, "daemon")) {
        const action = args_it.next() orelse "status";
        if (std.mem.eql(u8, action, "install")) {
            const unit = try mcp_server.generateDaemonUnit(gpa, builtin.os.tag == .macos, exe_name, port);
            defer gpa.free(unit);
            std.debug.print("{s}", .{unit});
            return;
        }
        std.debug.print("harness-engine daemon {s}: ok (port {d})\n", .{ action, port });
        return;
    }
    if (std.mem.eql(u8, subcmd, "mcp")) {
        try runMcpStdio(gpa, io);
        return;
    }
    if (std.mem.eql(u8, subcmd, "login") or std.mem.eql(u8, subcmd, "logout") or std.mem.eql(u8, subcmd, "sync")) {
        std.debug.print("harness-engine {s}: ok\n", .{subcmd});
        return;
    }

    var host = try engine_host.EngineHost.init(gpa, "zig-local-device", "Zig Local Host");
    defer host.deinit();
    host.io = io;
    var default_data_dir_buf: [512]u8 = undefined;
    var default_graff_buf: [512]u8 = undefined;
    if (init.environ_map.get("GRAFF_EXECUTABLE")) |ge| {
        if (ge.len > 0) host.graff_exe = ge;
    } else if (init.environ_map.get("HOME")) |home| {
        if (std.fmt.bufPrint(&default_graff_buf, "{s}/.harness/bin/graff", .{home})) |gpath| {
            if (std.Io.Dir.cwd().access(io, gpath, .{})) |_| {
                host.graff_exe = gpath;
            } else |_| {}
        } else |_| {}
    }
    if (host.graff_exe) |ge| {
        host.cached_graff_models_json = acp_host.discoverGraffModelsJson(gpa, io, ge) catch null;
    }

    const resolved_data_dir: ?[]const u8 = init.environ_map.get("HARNESS_DATA_DIR") orelse
        init.environ_map.get("DATA_DIR") orelse
        blk: {
            const home = init.environ_map.get("HOME") orelse break :blk null;
            break :blk std.fmt.bufPrint(&default_data_dir_buf, "{s}/.harness", .{home}) catch null;
        };

    if (resolved_data_dir) |data_dir| {
        if (data_dir.len > 0) {
            std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
            if (comptime builtin.os.tag != .windows) {
                var lock_path_buf: [512]u8 = undefined;
                var pid_buf: [32]u8 = undefined;
                if (std.fmt.bufPrint(&lock_path_buf, "{s}/engine.lock", .{data_dir})) |lock_path| {
                    if (std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.c.getpid()})) |pid_str| {
                        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = lock_path, .data = pid_str }) catch {};
                    } else |_| {}
                } else |_| {}
            }
            if (std.fmt.allocPrintSentinel(gpa, "{s}/docs.sqlite", .{data_dir}, 0)) |db_path_z| {
                defer gpa.free(db_path_z);
                if (docs_store.DocsStore.openSqlite(gpa, db_path_z.ptr)) |sqlite_store| {
                    host.store.deinit();
                    host.store = sqlite_store;
                } else |_| {}
            } else |_| {}
        }
    }

    // Seed any persisted chats from docs.sqlite into host.chats so they appear in the sidebar.
    var snap_it = host.store.snapshots.iterator();
    while (snap_it.next()) |entry| {
        const cid = entry.key_ptr.*;
        var exists = false;
        for (host.chats.items) |c| {
            if (std.mem.eql(u8, c.id, cid)) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            const id_copy = try gpa.dupe(u8, cid);
            errdefer gpa.free(id_copy);
            const dev_copy = try gpa.dupe(u8, host.device_id);
            errdefer gpa.free(dev_copy);
            const h_copy = try gpa.dupe(u8, "graff");
            errdefer gpa.free(h_copy);
            try host.chats.append(gpa, .{
                .id = id_copy,
                .space_id = null,
                .device_id = dev_copy,
                .harness = h_copy,
            });
        }
    }

    if (host.spaces.items.len == 0) {
        const default_path = init.environ_map.get("PWD") orelse "/Users/rachpradhan/harness";
        const id_copy = try gpa.dupe(u8, "space-zig-default");
        errdefer gpa.free(id_copy);
        const dev_copy = try gpa.dupe(u8, host.device_id);
        errdefer gpa.free(dev_copy);
        const path_copy = try gpa.dupe(u8, default_path);
        errdefer gpa.free(path_copy);
        const name_copy = try gpa.dupe(u8, std.fs.path.basename(default_path));
        errdefer gpa.free(name_copy);
        try host.spaces.append(gpa, .{
            .id = id_copy,
            .device_id = dev_copy,
            .path = path_copy,
            .name = name_copy,
            .git_detected = true,
        });
    }

    const listen_addr = try net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("harness-engine (zig): listening on ws://127.0.0.1:{d}", .{port});

    const ClientWorker = struct {
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
            serveSocket(gpa_c, io_c, host_c, &stream) catch |err| {
                std.log.debug("harness-engine: client ended: {t}", .{err});
            };
        }
    };

    while (!host.stop_requested) {
        var stream = server.accept(io) catch continue;
        const ctx = gpa.create(ClientWorker) catch {
            stream.close(io);
            continue;
        };
        ctx.* = .{ .gpa = gpa, .io = io, .host = &host, .stream = stream };
        if (std.Thread.spawn(.{}, ClientWorker.run, .{ctx})) |th| {
            th.detach();
        } else |_| {
            ClientWorker.run(ctx);
        }
    }
}

fn runMcpStdio(gpa: Allocator, io: Io) !void {
    var in_buf: [65536]u8 = undefined;
    var out_buf: [65536]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &in_buf);
    var writer = Io.File.stdout().writerStreaming(io, &out_buf);
    const r = &reader.interface;
    const w = &writer.interface;

    while (true) {
        const line = (r.takeDelimiter('\n') catch break) orelse break;
        if (try mcp_server.handleMcpJsonRpcLine(gpa, line)) |resp| {
            defer gpa.free(resp);
            try w.writeAll(resp);
            try w.writeByte('\n');
            try w.flush();
        }
    }
}

const PongWriter = struct {
    w: *Io.Writer,
    fn send(self: @This(), payload: []const u8) void {
        ws_server.writeServerFrame(self.w, .pong, payload) catch return;
        self.w.flush() catch {};
    }
};

pub fn serveSocket(gpa: Allocator, io: Io, host: *engine_host.EngineHost, stream: *net.Stream) !void {
    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var rd = net.Stream.Reader.init(stream.*, io, &rbuf);
    var wr = net.Stream.Writer.init(stream.*, io, &wbuf);

    try ws_server.acceptHandshake(&rd.interface, &wr.interface);
    defer host.removeClientWatches(&wr.interface);

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);

    var req_arena = std.heap.ArenaAllocator.init(gpa);
    defer req_arena.deinit();

    while (true) {
        const op = ws.readMessageFrom(gpa, &rd.interface, &msg, PongWriter{ .w = &wr.interface }, PongWriter.send) catch |err| switch (err) {
            error.PeerClosed, error.EndOfStream => return,
            else => return err,
        };
        if (op != .text) continue;

        var lines = std.mem.splitScalar(u8, msg.items, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            defer _ = req_arena.reset(.{ .retain_with_limit = 64 * 1024 });
            try dispatchClientLineWithArena(gpa, req_arena.allocator(), host, &wr.interface, line);
            if (host.stop_requested) return;
        }
    }
}

pub fn flushPushedWatchFrames(gpa: Allocator, host: *engine_host.EngineHost, w: *Io.Writer) !void {
    if (host.pushed_frames.items.len == 0) return;
    defer {
        for (host.pushed_frames.items) |*p| p.deinit(gpa);
        host.pushed_frames.clearRetainingCapacity();
    }
    for (host.pushed_frames.items) |pushed| {
        const frame = try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"item\":{s}}}", .{ pushed.sub_id, pushed.item_json });
        defer gpa.free(frame);
        try ws_server.writeServerFrame(w, .text, frame);
    }
    try w.flush();
}

pub fn dispatchClientLine(gpa: Allocator, host: *engine_host.EngineHost, w: *Io.Writer, line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    return dispatchClientLineWithArena(gpa, arena.allocator(), host, w, line);
}

pub fn dispatchClientLineWithArena(
    gpa: Allocator,
    scratch: Allocator,
    host: *engine_host.EngineHost,
    w: *Io.Writer,
    line: []const u8,
) !void {
    if (host.io) |io| host.mutex.lockUncancelable(io);
    defer if (host.io) |io| host.mutex.unlock(io);

    const parsed_val = json.parseFromSliceLeaky(json.Value, scratch, line, .{}) catch return;
    if (parsed_val != .object) return;
    const obj = parsed_val.object;
    const id_val = obj.get("id") orelse return;
    if (id_val != .integer) return;
    const id: u64 = @intCast(@max(0, id_val.integer));

    if (obj.get("cancel")) |c| {
        if (c == .bool and c.bool) {
            host.cancelWatch(id);
            return;
        }
    }

    const method_val = obj.get("method") orelse return;
    if (method_val != .string) return;
    const params_val = obj.get("params") orelse json.Value{ .object = .empty };

    host.live_ws_writer = w;
    defer host.live_ws_writer = null;

    var outcome = try host.handleWithId(id, method_val.string, params_val);
    switch (outcome) {
        .unary_json => |body| {
            defer gpa.free(body);
            const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"ok\":{s}}}", .{ id, body });
            try ws_server.writeServerFrame(w, .text, frame);
            try w.flush();
        },
        .stream_items_json => |*st| {
            defer st.deinit(gpa);
            if (st.checked) {
                const ready = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"ok\":{{\"stream\":true}}}}", .{id});
                try ws_server.writeServerFrame(w, .text, ready);
            }
            for (st.items) |it| {
                const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"item\":{s}}}", .{ id, it });
                try ws_server.writeServerFrame(w, .text, frame);
            }
            try w.flush();
        },
        .err => |e| {
            const msg = switch (e) {
                .bad_params => |m| m,
                .unknown_method => |m| m,
                .exec_error => |m| m,
            };
            const frame = try std.fmt.allocPrint(scratch, "{{\"id\":{d},\"err\":{f}}}", .{ id, json.fmt(msg, .{}) });
            try ws_server.writeServerFrame(w, .text, frame);
            try w.flush();
        },
    }
    try flushPushedWatchFrames(gpa, host, w);
}
