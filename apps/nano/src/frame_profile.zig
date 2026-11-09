//! Frame and redraw logger in ~/.harness/logs/harness-nano-frames.log.
//! Enabled by default on desktop launch (disable with HARNESS_NANO_PROFILE=0)
//! so redraw bursts, multi-pass rebuilds, animation frames, and gesture
//! latencies are always visible.
const std = @import("std");
const builtin = @import("builtin");

extern fn kdebug_signpost(code: u32, arg1: usize, arg2: usize, arg3: usize, arg4: usize) c_int;
const App = @import("app.zig").App;

var on: bool = false;
var file: ?std.Io.File = null;
var last_ms: f64 = 0;
var until: f64 = 0;
var passes: u32 = 0;
var redraws: u32 = 0;
var last_frame: ?u64 = null;
var last_passes: u32 = 0;
var last_redraws: u32 = 0;
var last_note_buf: [64]u8 = undefined;
var last_note_len: usize = 0;

pub fn start(a: *App) void {
    if (a.env) |env| {
        if (env.get("HARNESS_NANO_PROFILE")) |v| {
            if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false")) return;
        }
    }
    const dir = a.settings.dataDir() orelse return;
    const logs_dir = std.fmt.allocPrint(a.gpa, "{s}/logs", .{dir}) catch return;
    defer a.gpa.free(logs_dir);
    std.Io.Dir.cwd().createDirPath(a.io, logs_dir) catch {};
    const path = std.fmt.allocPrint(a.gpa, "{s}/harness-nano-frames.log", .{logs_dir}) catch return;
    defer a.gpa.free(path);
    file = std.Io.Dir.cwd().createFile(a.io, path, .{ .truncate = true }) catch
        (blk: {
            const fallback = std.fmt.allocPrint(a.gpa, "{s}/harness-nano-frames.log", .{dir}) catch break :blk null;
            defer a.gpa.free(fallback);
            break :blk std.Io.Dir.cwd().createFile(a.io, fallback, .{ .truncate = true }) catch null;
        });
    if (file == null) return;
    on = true;
    note(a, "profile-start");
}

pub fn beginPass() void {
    if (!on) return;
    passes +|= 1;
}

pub fn countRedraw() void {
    if (!on) return;
    redraws +|= 1;
}

pub fn note(a: *App, what: []const u8) void {
    if (!on) return;
    until = a.now + 2.0;
    const n = @min(what.len, last_note_buf.len);
    @memcpy(last_note_buf[0..n], what[0..n]);
    last_note_len = n;
    const f = file orelse return;
    const pane: usize = if (a.tabs.layout()) |s| s.focus else 0;
    var buf: [240]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d:.3} event={s} tab={d} pane={d}\n", .{
        a.now,
        what,
        a.tabs.active,
        pane,
    }) catch return;
    f.writeStreamingAll(a.io, line) catch {};
}

pub fn frame(a: *App, c: *const @import("nanoui").ui.Context) void {
    if (!on) return;
    const p = if (passes > 0) passes else 1;
    passes = 0;
    const r = redraws;
    redraws = 0;
    if (last_frame) |prev| {
        if (prev == c.frame) {
            last_passes +|= p;
            last_redraws +|= r;
            return;
        }
    } else {
        last_frame = c.frame;
        last_passes = p;
        last_redraws = r;
        return;
    }
    const logged_frame = last_frame.?;
    const pass_count = if (last_passes > 0) last_passes else 1;
    const redraw_count = last_redraws;
    last_frame = c.frame;
    last_passes = p;
    last_redraws = r;
    const s = c.stats;
    const total = s.build_ms + s.layout_ms + s.paint_ms;
    const watching = a.now < until;
    const scroll_n = c.scroll_moved.count();
    if (!watching and total < 4.0 and pass_count <= 1 and !c.animating and scroll_n == 0) {
        last_ms = total;
        return;
    }
    last_ms = total;
    const pane: usize = if (a.tabs.layout()) |sp| sp.focus else 0;
    const menu_name = if (a.view.strip.menu) |m| @tagName(m) else "none";
    const act = if (last_note_len > 0) last_note_buf[0..last_note_len] else "-";
    defer if (!c.animating and scroll_n == 0) {
        last_note_len = 0;
    };
    var buf: [320]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "{d:.3} frame=#{d} total={d:.2}ms (build={d:.2} layout={d:.2} paint={d:.2}) passes={d} nodes={d} anim={d} scroll={d} retained={d} redraws={d} tab={d} pane={d} menu={s} act={s}\n",
        .{
            a.now,
            logged_frame,
            total,
            s.build_ms,
            s.layout_ms,
            s.paint_ms,
            pass_count,
            s.nodes,
            @intFromBool(c.animating),
            scroll_n,
            @intFromBool(s.retained),
            redraw_count,
            a.tabs.active,
            pane,
            menu_name,
            act,
        },
    ) catch return;
    const f = file orelse return;
    f.writeStreamingAll(a.io, line) catch {};
    if (builtin.os.tag == .macos and total >= 8) {
        _ = kdebug_signpost(1, @intFromFloat(s.build_ms * 10), @intFromFloat(s.layout_ms * 10), @intFromFloat(s.paint_ms * 10), s.nodes);
    }
}
