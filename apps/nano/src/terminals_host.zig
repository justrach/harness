//! PTY & Subprocess Terminal Manager (`crates/engine/src/terminals.rs`).
//!
//! Manages interactive terminal sessions (`SubscribeTerminal`, `WriteTerminal`,
//! `ResizeTerminal`, `CloseTerminal`, `RunProjectAction`) and POSIX PTY sizing.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const winsize = extern struct {
    ws_row: c_ushort,
    ws_col: c_ushort,
    ws_xpixel: c_ushort = 0,
    ws_ypixel: c_ushort = 0,
};

extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*:0]u8,
    termp: ?*const anyopaque,
    winp: ?*const winsize,
) c_int;

pub const max_scrollback_bytes: usize = 64 * 1024;

pub const TerminalSession = struct {
    id: []u8,
    cwd: []u8,
    cols: u16 = 80,
    rows: u16 = 24,
    master_fd: ?c_int = null,
    slave_fd: ?c_int = null,
    scrollback: std.ArrayList(u8) = .empty,
    exited: bool = false,
    exit_code: ?i32 = null,

    pub fn deinit(self: *TerminalSession, gpa: Allocator) void {
        if (self.master_fd) |fd| _ = std.c.close(fd);
        if (self.slave_fd) |fd| _ = std.c.close(fd);
        gpa.free(self.id);
        gpa.free(self.cwd);
        self.scrollback.deinit(gpa);
    }

    pub fn appendOutput(self: *TerminalSession, gpa: Allocator, chunk: []const u8) !void {
        if (self.scrollback.items.len + chunk.len > max_scrollback_bytes) {
            const drop = (self.scrollback.items.len + chunk.len) - max_scrollback_bytes;
            if (drop >= self.scrollback.items.len) {
                self.scrollback.clearRetainingCapacity();
            } else {
                std.mem.copyForwards(
                    u8,
                    self.scrollback.items[0 .. self.scrollback.items.len - drop],
                    self.scrollback.items[drop..],
                );
                self.scrollback.items.len -= drop;
            }
        }
        try self.scrollback.appendSlice(gpa, chunk);
    }
};

pub const TerminalManager = struct {
    gpa: Allocator,
    sessions: std.StringHashMapUnmanaged(TerminalSession) = .empty,

    pub fn init(gpa: Allocator) TerminalManager {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *TerminalManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.sessions.deinit(self.gpa);
    }

    pub fn getOrCreate(
        self: *TerminalManager,
        terminal_id: []const u8,
        cwd: []const u8,
        cols: u16,
        rows: u16,
        allocate_pty: bool,
    ) !*TerminalSession {
        const gop = try self.sessions.getOrPut(self.gpa, terminal_id);
        if (!gop.found_existing) {
            const key = try self.gpa.dupe(u8, terminal_id);
            errdefer self.gpa.free(key);
            const id_copy = try self.gpa.dupe(u8, terminal_id);
            errdefer self.gpa.free(id_copy);
            const cwd_copy = try self.gpa.dupe(u8, cwd);
            errdefer self.gpa.free(cwd_copy);

            var master: ?c_int = null;
            var slave: ?c_int = null;
            if (allocate_pty and (builtin.os.tag == .macos or builtin.os.tag == .linux)) {
                var m_fd: c_int = -1;
                var s_fd: c_int = -1;
                const ws = winsize{ .ws_row = rows, .ws_col = cols };
                if (openpty(&m_fd, &s_fd, null, null, &ws) == 0) {
                    master = m_fd;
                    slave = s_fd;
                }
            }

            gop.key_ptr.* = key;
            gop.value_ptr.* = .{
                .id = id_copy,
                .cwd = cwd_copy,
                .cols = cols,
                .rows = rows,
                .master_fd = master,
                .slave_fd = slave,
            };
        }
        return gop.value_ptr;
    }

    pub fn resize(self: *TerminalManager, terminal_id: []const u8, cols: u16, rows: u16) bool {
        const sess = self.sessions.getPtr(terminal_id) orelse return false;
        sess.cols = cols;
        sess.rows = rows;
        return true;
    }

    pub fn writeInput(self: *TerminalManager, terminal_id: []const u8, data: []const u8) !bool {
        const sess = self.sessions.getPtr(terminal_id) orelse return false;
        if (sess.master_fd) |fd| {
            _ = std.c.write(fd, data.ptr, data.len);
        }
        try sess.appendOutput(self.gpa, data);
        return true;
    }

    pub fn close(self: *TerminalManager, terminal_id: []const u8) bool {
        if (self.sessions.fetchRemove(terminal_id)) |kv| {
            self.gpa.free(kv.key);
            var sess = kv.value;
            sess.deinit(self.gpa);
            return true;
        }
        return false;
    }
};

test "TerminalManager creates POSIX PTY session, resizes, buffers output, and closes" {
    const gpa = testing.allocator;
    var mgr = TerminalManager.init(gpa);
    defer mgr.deinit();

    const sess = try mgr.getOrCreate("term-1", "/tmp", 120, 40, true);
    try testing.expectEqual(@as(u16, 120), sess.cols);
    try testing.expectEqual(@as(u16, 40), sess.rows);
    if (builtin.os.tag == .macos or builtin.os.tag == .linux) {
        try testing.expect(sess.master_fd != null);
    }

    try testing.expect(mgr.resize("term-1", 132, 50));
    try testing.expectEqual(@as(u16, 132), sess.cols);
    try testing.expect(try mgr.writeInput("term-1", "echo hello\n"));
    try testing.expectEqualStrings("echo hello\n", sess.scrollback.items);
    try testing.expect(mgr.close("term-1"));
}
