//! RFC 6455 WebSocket server handshake & unmasked frame writer for the Zig
//! engine's local IPC socket (`ws://127.0.0.1:{HARNESS_IPC_PORT|27664}`),
//! mirroring `crates/rpc/src/server.rs`.
//!
//! Rejects any handshake carrying an `Origin` header (`403 Forbidden`) so a
//! browser page cannot dial the local engine socket.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const ws = @import("ws.zig");

pub const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const HandshakeError = error{
    OriginForbidden,
    MissingWebSocketKey,
    BadRequest,
} || Io.Reader.Error || Io.Writer.Error;

/// Compute RFC 6455 `Sec-WebSocket-Accept` for a trimmed `Sec-WebSocket-Key`.
pub fn computeAcceptKey(sec_key: []const u8, out: *[28]u8) void {
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(sec_key);
    sha1.update(ws_guid);
    var digest: [20]u8 = undefined;
    sha1.final(&digest);
    _ = std.base64.standard.Encoder.encode(out, &digest);
}

/// Read the HTTP/1.1 upgrade request from `r`, reject cross-origin browser
/// dials carrying `Origin:`, and write the `101 Switching Protocols` response.
pub fn acceptHandshake(r: *Io.Reader, w: *Io.Writer) HandshakeError!void {
    const req_line = r.takeDelimiterInclusive('\n') catch return error.BadRequest;
    if (!std.mem.startsWith(u8, req_line, "GET ")) return error.BadRequest;

    var key_buf: [128]u8 = undefined;
    var key_len: usize = 0;
    var saw_origin = false;

    while (true) {
        const line_raw = r.takeDelimiterInclusive('\n') catch return error.BadRequest;
        const line = std.mem.trimEnd(u8, line_raw, "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "origin")) {
            saw_origin = true;
        } else if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
            if (val.len <= key_buf.len) {
                @memcpy(key_buf[0..val.len], val);
                key_len = val.len;
            }
        }
    }

    if (saw_origin) {
        try w.writeAll("HTTP/1.1 403 Forbidden\r\nContent-Length: 31\r\nConnection: close\r\n\r\norigin not allowed on local IPC");
        try w.flush();
        return error.OriginForbidden;
    }
    if (key_len == 0) return error.MissingWebSocketKey;

    var accept: [28]u8 = undefined;
    computeAcceptKey(key_buf[0..key_len], &accept);
    try w.print(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
        .{&accept},
    );
    try w.flush();
}

/// Write an unmasked server WebSocket frame (RFC 6455 §5.1: a server MUST NOT
/// mask any frames that it sends to the client).
pub fn writeServerFrame(w: *Io.Writer, op: ws.Opcode, payload: []const u8) Io.Writer.Error!void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @intFromEnum(op));
    var n: usize = 2;
    if (payload.len < 126) {
        hdr[1] = @intCast(payload.len);
    } else if (payload.len <= 0xffff) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
        n = 10;
    }
    try w.writeAll(hdr[0..n]);
    try w.writeAll(payload);
}

fn noPing(_: void, _: []const u8) void {}

test "computeAcceptKey matches RFC 6455 section 4.2.2 vector" {
    var accept: [28]u8 = undefined;
    computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &accept);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "acceptHandshake upgrades bare client and rejects Origin header" {
    const ok_req =
        "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:27664\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    var r1: Io.Reader = .fixed(ok_req);
    var out1: [512]u8 = undefined;
    var w1: Io.Writer = .fixed(&out1);
    try acceptHandshake(&r1, &w1);
    try testing.expect(std.mem.indexOf(u8, w1.buffered(), "101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, w1.buffered(), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    const browser_req =
        "GET / HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:27664\r\n" ++
        "Origin: https://evil.example\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";
    var r2: Io.Reader = .fixed(browser_req);
    var out2: [512]u8 = undefined;
    var w2: Io.Writer = .fixed(&out2);
    try testing.expectError(error.OriginForbidden, acceptHandshake(&r2, &w2));
    try testing.expect(std.mem.indexOf(u8, w2.buffered(), "403 Forbidden") != null);
}

test "writeServerFrame round-trips through ws.readMessageFrom" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeServerFrame(&w, .text, "{\"id\":1,\"ok\":{\"ready\":true}}");
    var r: Io.Reader = .fixed(w.buffered());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(ws.Opcode.text, try ws.readMessageFrom(testing.allocator, &r, &out, {}, noPing));
    try testing.expectEqualStrings("{\"id\":1,\"ok\":{\"ready\":true}}", out.items);
}
