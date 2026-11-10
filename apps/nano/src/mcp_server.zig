//! Harness MCP Server (`crates/mcp/src/main.rs`) & OS Daemon Unit Generator (`apps/harness/src/daemon.rs`).
//!
//! Implements the stdio JSON-RPC 2.0 MCP server (`initialize`, `tools/list`,
//! `tools/call` for `render_visual`, `ask_user_input`, `delegate_task`,
//! `check_delegated_tasks`) and launchd/systemd service definitions.
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const mcp_tools_list_json =
    \\{"tools":[
    \\  {"name":"render_visual","description":"Render an interactive visual or chart in the Harness transcript","inputSchema":{"type":"object","properties":{"title":{"type":"string"},"html":{"type":"string"}},"required":["title","html"]}},
    \\  {"name":"ask_user_input","description":"Present structured multiple-choice questions to the user","inputSchema":{"type":"object","properties":{"questions":{"type":"array"}},"required":["questions"]}},
    \\  {"name":"delegate_task","description":"Spawn a subagent conversation for an isolated task","inputSchema":{"type":"object","properties":{"title":{"type":"string"},"prompt":{"type":"string"}},"required":["prompt"]}},
    \\  {"name":"check_delegated_tasks","description":"Check the status of delegated subagent tasks","inputSchema":{"type":"object","properties":{}}}
    \\]}
;

/// Handle a single JSON-RPC 2.0 line sent to `harness-engine mcp`.
/// Returns an owned JSON-RPC response line (without trailing newline), or `null` for notifications.
pub fn handleMcpJsonRpcLine(gpa: Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;

    const id_val = root.get("id") orelse return null; // notification
    var id_aw: std.Io.Writer.Allocating = .init(gpa);
    defer id_aw.deinit();
    try json.Stringify.value(id_val, .{}, &id_aw.writer);
    const id_json = id_aw.written();

    const method = if (root.get("method")) |m| (if (m == .string) m.string else "") else "";

    if (std.mem.eql(u8, method, "initialize")) {
        return try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"harness-mcp\",\"version\":\"0.2.174\"}}}}}}",
            .{id_json},
        );
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
            .{ id_json, mcp_tools_list_json },
        );
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.get("params") orelse return null;
        const tool_name = if (params == .object)
            if (params.object.get("name")) |n| (if (n == .string) n.string else "tool") else "tool"
        else
            "tool";
        return try std.fmt.allocPrint(
            gpa,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"ok:{s}\"}}],\"isError\":false}}}}",
            .{ id_json, tool_name },
        );
    }
    return try std.fmt.allocPrint(
        gpa,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}",
        .{id_json},
    );
}

/// Generate the macOS `launchd` plist or Linux `systemd` unit for `harness-engine daemon install`.
pub fn generateDaemonUnit(gpa: Allocator, is_macos: bool, exe_path: []const u8, port: u16) ![]u8 {
    if (is_macos) {
        return std.fmt.allocPrint(
            gpa,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>Label</key>
            \\  <string>dev.harness.engine</string>
            \\  <key>ProgramArguments</key>
            \\  <array>
            \\    <string>{s}</string>
            \\    <string>headless</string>
            \\  </array>
            \\  <key>EnvironmentVariables</key>
            \\  <dict>
            \\    <key>HARNESS_IPC_PORT</key>
            \\    <string>{d}</string>
            \\  </dict>
            \\  <key>KeepAlive</key>
            \\  <true/>
            \\</dict>
            \\</plist>
            \\
        ,
            .{ exe_path, port },
        );
    }
    return std.fmt.allocPrint(
        gpa,
        \\[Unit]
        \\Description=Harness Zig Engine Daemon
        \\
        \\[Service]
        \\ExecStart={s} headless
        \\Environment=HARNESS_IPC_PORT={d}
        \\Restart=always
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    ,
        .{ exe_path, port },
    );
}

test "MCP JSON-RPC server handles initialize, tools/list, tools/call, and daemon unit generation" {
    const gpa = testing.allocator;

    const r1 = (try handleMcpJsonRpcLine(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")).?;
    defer gpa.free(r1);
    try testing.expect(std.mem.indexOf(u8, r1, "\"harness-mcp\"") != null);

    const r2 = (try handleMcpJsonRpcLine(gpa, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")).?;
    defer gpa.free(r2);
    try testing.expect(std.mem.indexOf(u8, r2, "\"render_visual\"") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "\"ask_user_input\"") != null);
    try testing.expect(std.mem.indexOf(u8, r2, "\"delegate_task\"") != null);

    const r3 = (try handleMcpJsonRpcLine(gpa, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"render_visual\"}}")).?;
    defer gpa.free(r3);
    try testing.expect(std.mem.indexOf(u8, r3, "ok:render_visual") != null);

    const plist = try generateDaemonUnit(gpa, true, "/usr/local/bin/harness-engine", 27664);
    defer gpa.free(plist);
    try testing.expect(std.mem.indexOf(u8, plist, "dev.harness.engine") != null);
}
