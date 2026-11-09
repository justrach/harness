//! A slow frame writes one line to ~/.harness/logs/harness-nano-frames.log.
//! Instruments can attach too; this is the trace that stays after the
//! gesture. Off unless HARNESS_NANO_PROFILE=1, so a normal launch stays quiet.
const std = @import("std");
const builtin = @import("builtin");

extern fn kdebug_signpost(code: u32, arg1: usize, arg2: usize, arg3: usize, arg4: usize) c_int;
const App = @import("app.zig").App;

var on: bool = false;
var file: ?std.Io.File = null;
var last_ms: f64 = 0;
var until: f64 = 0;

pub fn start(a: *App) void {
    const env = a.env orelse return;
    const v = env.get("HARNESS_NANO_PROFILE") orelse return;
    if (!(std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true"))) return;
    const dir = a.settings.dataDir() orelse return;
    const path = std.fmt.allocPrint(a.gpa, "{s}/harness-nano-frames.log", .{dir}) catch return;
    defer a.gpa.free(path);
    file = std.Io.Dir.cwd().createFile(a.io, path, .{ .truncate = true }) catch return;
    on = true;
    note(a, "profile on");
}

pub fn note(a: *App, what: []const u8) void {
    if (!on) return;
    until = a.now + 2;
    const f = file orelse return;
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{d:.3} {s}\n", .{ a.now, what }) catch return;
    f.writeStreamingAll(a.io, line) catch {};
}

/// A frame slower than 8 ms. The gesture that hitch is in this line.
pub fn frame(a: *App, c: *const @import("nanoui").ui.Context) void {
    if (!on) return;
    const s = c.stats;
    const total = s.build_ms + s.layout_ms + s.paint_ms;
    const watching = a.now < until;
    if (total < 8 and !c.animating and !watching) {
        last_ms = total;
        return;
    }
    if (total < 2 and !watching) return;
    last_ms = total;
    var buf: [220]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "frame build={d:.1} layout={d:.1} paint={d:.1} nodes={d} anim={d} retained={d}\n", .{
        s.build_ms, s.layout_ms, s.paint_ms, s.nodes, @intFromBool(c.animating), @intFromBool(s.retained),
    }) catch return;
    const f = file orelse return;
    f.writeStreamingAll(a.io, line) catch {};
    if (builtin.os.tag == .macos and total >= 8) {
        _ = kdebug_signpost(1, @intFromFloat(s.build_ms * 10), @intFromFloat(s.layout_ms * 10), @intFromFloat(s.paint_ms * 10), s.nodes);
    }
}
