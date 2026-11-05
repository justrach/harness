//! A WebSocket client (RFC 6455) for the engine's local socket: ws:// on
//! loopback only, text frames, client masking, ping/pong, close, fragments
//! reassembled. After codegraff's src/ws.zig, without TLS.
//!
//! The handshake sends no `Origin` header: the engine refuses any handshake
//! that carries one, so a web page can't reach the local socket
//! (crates/rpc/src/server.rs, `serve_ws_socket`).
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const Allocator = std.mem.Allocator;

pub const Opcode = enum(u4) {
    cont = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Error = error{
    HandshakeFailed,
    PeerClosed,
    MessageTooLong,
    BadFrame,
} || Allocator.Error || Io.Reader.Error || Io.Writer.Error;

const sock_buf_cap = 64 * 1024;
/// One reassembled message at most: a chat's transcript snapshot can be large.
pub const message_cap = 64 * 1024 * 1024;

pub const Client = struct {
    io: Io,
    stream: net.Stream,
    rd: net.Stream.Reader,
    wr: net.Stream.Writer,
    /// Frames go out from the UI thread (calls) and the reader's (pongs).
    write_lock: Io.Mutex = .init,
    rbuf: [sock_buf_cap]u8 = undefined,
    wbuf: [sock_buf_cap]u8 = undefined,

    /// Connects to `127.0.0.1:port` and upgrades `path`. Heap-allocated: the
    /// reader and writer point into its buffers.
    pub fn connect(gpa: Allocator, io: Io, port: u16, path: []const u8) Error!*Client {
        const addr = net.IpAddress.parseIp4("127.0.0.1", port) catch return error.HandshakeFailed;
        const stream = addr.connect(io, .{ .mode = .stream }) catch return error.HandshakeFailed;
        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .stream = stream, .rd = undefined, .wr = undefined };
        self.rd = net.Stream.Reader.init(stream, io, &self.rbuf);
        self.wr = net.Stream.Writer.init(stream, io, &self.wbuf);
        errdefer self.stream.close(io);
        try handshake(io, &self.rd.interface, &self.wr.interface, port, path);
        return self;
    }

    /// Closes the socket; a reader blocked on it wakes with an error.
    pub fn deinit(self: *Client, gpa: Allocator) void {
        self.stream.close(self.io);
        gpa.destroy(self);
    }

    /// Unblocks a reader without freeing anything yet.
    pub fn shutdown(self: *Client) void {
        self.stream.shutdown(self.io, .both) catch {};
    }

    pub fn sendText(self: *Client, payload: []const u8) Error!void {
        self.write_lock.lockUncancelable(self.io);
        defer self.write_lock.unlock(self.io);
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        try writeFrame(&self.wr.interface, .text, payload, mask);
        try self.wr.interface.flush();
    }

    /// One whole message into `out` (cleared first). Pings are answered and
    /// pongs skipped; a close from the peer is `error.PeerClosed`.
    pub fn readMessage(self: *Client, gpa: Allocator, out: *std.ArrayList(u8)) Error!Opcode {
        return readMessageFrom(gpa, &self.rd.interface, out, self, pong);
    }

    fn pong(self: *Client, payload: []const u8) void {
        self.write_lock.lockUncancelable(self.io);
        defer self.write_lock.unlock(self.io);
        var mask: [4]u8 = undefined;
        self.io.random(&mask);
        writeFrame(&self.wr.interface, .pong, payload, mask) catch return;
        self.wr.interface.flush() catch {};
    }
};

fn handshake(io: Io, r: *Io.Reader, w: *Io.Writer, port: u16, path: []const u8) Error!void {
    var key_raw: [16]u8 = undefined;
    io.random(&key_raw);
    var key: [24]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&key, &key_raw);
    try w.print(
        "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{ path, port, &key },
    );
    try w.flush();
    const status = r.takeDelimiterInclusive('\n') catch return error.HandshakeFailed;
    if (std.mem.indexOf(u8, status, " 101 ") == null) return error.HandshakeFailed;
    while (true) {
        const line = r.takeDelimiterInclusive('\n') catch return error.HandshakeFailed;
        if (line.len <= 2) break;
    }
}

/// Writes one final frame, masked with `mask` as a client must.
pub fn writeFrame(w: *Io.Writer, op: Opcode, payload: []const u8, mask: [4]u8) Io.Writer.Error!void {
    var hdr: [14]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @intFromEnum(op));
    var n: usize = 2;
    if (payload.len < 126) {
        hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xffff) {
        hdr[1] = 0x80 | 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        hdr[1] = 0x80 | 127;
        std.mem.writeInt(u64, hdr[2..10], payload.len, .big);
        n = 10;
    }
    @memcpy(hdr[n .. n + 4], &mask);
    n += 4;
    try w.writeAll(hdr[0..n]);
    var tmp: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < payload.len) {
        const chunk = @min(tmp.len, payload.len - i);
        for (0..chunk) |j| tmp[j] = payload[i + j] ^ mask[(i + j) & 3];
        try w.writeAll(tmp[0..chunk]);
        i += chunk;
    }
}

/// Reads frames from `r` until a message ends; `on_ping(ctx, payload)`
/// answers pings. Separate from `Client` so tests feed it bytes.
pub fn readMessageFrom(
    gpa: Allocator,
    r: *Io.Reader,
    out: *std.ArrayList(u8),
    ctx: anytype,
    comptime on_ping: fn (@TypeOf(ctx), []const u8) void,
) Error!Opcode {
    out.clearRetainingCapacity();
    var msg_op: ?Opcode = null;
    while (true) {
        const h = try r.takeArray(2);
        const fin = (h[0] & 0x80) != 0;
        const op: Opcode = @enumFromInt(@as(u4, @truncate(h[0] & 0x0f)));
        const masked = (h[1] & 0x80) != 0;
        var len: u64 = h[1] & 0x7f;
        if (len == 126) {
            len = std.mem.readInt(u16, try r.takeArray(2), .big);
        } else if (len == 127) {
            len = std.mem.readInt(u64, try r.takeArray(8), .big);
        }
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) mask = (try r.takeArray(4)).*;
        switch (op) {
            .ping => {
                if (len > 125) return error.BadFrame;
                const p = try r.take(@intCast(len));
                if (masked) unmask(p, mask);
                on_ping(ctx, p);
            },
            .pong => try r.discardAll(@intCast(len)),
            .close => {
                try r.discardAll(@intCast(len));
                return error.PeerClosed;
            },
            .text, .binary, .cont => {
                if (out.items.len + len > message_cap) return error.MessageTooLong;
                const start = out.items.len;
                try out.resize(gpa, start + @as(usize, @intCast(len)));
                try r.readSliceAll(out.items[start..]);
                if (masked) unmask(out.items[start..], mask);
                if (msg_op == null and op != .cont) msg_op = op;
                if (fin) return msg_op orelse .text;
            },
            else => return error.BadFrame,
        }
    }
}

fn unmask(buf: []u8, mask: [4]u8) void {
    for (buf, 0..) |*b, i| b.* ^= mask[i & 3];
}

const testing = std.testing;

fn noPing(_: void, _: []const u8) void {}

test "a masked frame reads back as its text" {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeFrame(&w, .text, "{\"id\":1}", .{ 1, 2, 3, 4 });
    var r: Io.Reader = .fixed(w.buffered());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(Opcode.text, try readMessageFrom(testing.allocator, &r, &out, {}, noPing));
    try testing.expectEqualStrings("{\"id\":1}", out.items);
}

test "fragments join, a ping between them is answered, then a close ends it" {
    // Server frames are unmasked: "ab" (not final), ping "p", "c" (final), close.
    const bytes = [_]u8{ 0x01, 2, 'a', 'b', 0x89, 1, 'p', 0x80, 1, 'c', 0x88, 0 };
    var r: Io.Reader = .fixed(&bytes);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const Seen = struct {
        n: usize = 0,
        fn ping(s: *@This(), p: []const u8) void {
            if (std.mem.eql(u8, p, "p")) s.n += 1;
        }
    };
    var seen: Seen = .{};
    try testing.expectEqual(Opcode.text, try readMessageFrom(testing.allocator, &r, &out, &seen, Seen.ping));
    try testing.expectEqualStrings("abc", out.items);
    try testing.expectEqual(@as(usize, 1), seen.n);
    try testing.expectError(error.PeerClosed, readMessageFrom(testing.allocator, &r, &out, &seen, Seen.ping));
}

test "lengths past 125 and 65535 use the longer headers" {
    const gpa = testing.allocator;
    for ([_]usize{ 200, 70_000 }) |size| {
        const payload = try gpa.alloc(u8, size);
        defer gpa.free(payload);
        @memset(payload, 'x');
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeFrame(&aw.writer, .text, payload, .{ 9, 8, 7, 6 });
        var r: Io.Reader = .fixed(aw.written());
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        _ = try readMessageFrom(gpa, &r, &out, {}, noPing);
        try testing.expectEqualSlices(u8, payload, out.items);
    }
}
