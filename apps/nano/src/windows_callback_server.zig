//! The browser callback's Windows listener. Winsock polling must operate on
//! Winsock-owned sockets, not Zig 0.17's raw AFD handles. Bind exclusively so a
//! local login already using the callback port cannot be intercepted.
const std = @import("std");
const net = std.Io.net;
const invalid = std.math.maxInt(usize);
const Address = std.os.windows.ws2_32.sockaddr.in;

const ws = struct {
    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn WSASocketW(family: c_int, kind: c_int, protocol: c_int, info: ?*anyopaque, group: u32, flags: u32) callconv(.winapi) usize;
    extern "ws2_32" fn closesocket(fd: usize) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(fd: usize, level: c_int, option: c_int, value: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn bind(fd: usize, address: *const Address, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(fd: usize, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(fd: usize, address: *Address, len: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn ioctlsocket(fd: usize, command: c_int, value: *u32) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(fd: usize, address: ?*anyopaque, len: ?*c_int) callconv(.winapi) usize;
};

pub const Server = struct {
    socket: net.Socket,

    pub fn listen(port: u16) !Server {
        // WSADATA is at most 408 bytes on the supported Windows targets. It is
        // opaque here; reserve enough aligned storage without copying its ABI.
        var data: [512]u8 align(8) = undefined;
        if (ws.WSAStartup(0x0202, &data) != 0) return error.NetworkDown;
        errdefer _ = ws.WSACleanup();
        // Overlapped I/O, with no handle inheritance into spawned engines.
        const fd = ws.WSASocketW(2, 1, 6, null, 0, 0x01 | 0x80);
        if (fd == invalid) return error.SystemResources;
        errdefer _ = ws.closesocket(fd);
        var yes: c_int = 1;
        // SOL_SOCKET / SO_EXCLUSIVEADDRUSE, before bind.
        if (ws.setsockopt(fd, 0xffff, -5, &yes, @sizeOf(c_int)) != 0) return error.Unexpected;
        var address: Address = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        if (ws.bind(fd, &address, @sizeOf(Address)) != 0) return error.AddressInUse;
        if (ws.listen(fd, 8) != 0) return error.Unexpected;
        // Readiness is polled by the capture thread; never block accept after
        // a cancellation or a spurious readiness notification.
        var nonblocking: u32 = 1;
        if (ws.ioctlsocket(fd, @bitCast(@as(u32, 0x8004667e)), &nonblocking) != 0) return error.Unexpected;
        var len: c_int = @sizeOf(Address);
        if (ws.getsockname(fd, &address, &len) != 0) return error.Unexpected;
        return .{ .socket = .{
            .handle = @ptrFromInt(fd),
            .address = try net.IpAddress.parseIp4("127.0.0.1", std.mem.bigToNative(u16, address.port)),
        } };
    }

    pub fn deinit(s: *Server, _: std.Io) void {
        _ = ws.closesocket(@intFromPtr(s.socket.handle));
        _ = ws.WSACleanup();
    }

    pub fn accept(s: *Server, _: std.Io) !net.Stream {
        const fd = ws.accept(@intFromPtr(s.socket.handle), null, null);
        if (fd == invalid) return switch (ws.WSAGetLastError()) {
            10035 => error.WouldBlock,
            10053 => error.ConnectionAborted,
            else => error.Unexpected,
        };
        return .{ .socket = .{ .handle = @ptrFromInt(fd), .address = s.socket.address } };
    }
};

pub fn closeStream(stream: net.Stream) void {
    _ = ws.closesocket(@intFromPtr(stream.socket.handle));
}
