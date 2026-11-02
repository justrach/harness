//! A terminal's output as a log: the lines a program printed, with the
//! colours and weights its escape codes set (SGR: 16 colours, 256, true
//! colour, bold, dim, italic). A carriage return goes back to the start of
//! the line, so progress bars overwrite themselves; other escape codes
//! (cursor moves, titles) are dropped. Keeps the last `max_lines`.
const std = @import("std");
const Color = @import("nanoui").ui.Color;
const Allocator = std.mem.Allocator;

pub const max_lines = 5000;

pub const Style = struct {
    fg: ?Color = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
};

pub const Run = struct { start: u32, end: u32, style: Style };

pub const Line = struct {
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,

    fn deinit(l: *Line, gpa: Allocator) void {
        l.text.deinit(gpa);
        l.runs.deinit(gpa);
    }
};

pub const Log = struct {
    gpa: Allocator,
    lines: std.ArrayList(Line) = .empty,
    /// The 16 colours escape codes name (the theme's ANSI palette).
    palette: [16]Color,
    style: Style = .{},
    /// Where the next character goes on the last line (after a \r).
    col: usize = 0,
    state: enum { text, esc, csi, osc, osc_esc } = .text,
    params: std.ArrayList(u8) = .empty,
    utf8: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_want: u8 = 0,

    pub fn deinit(l: *Log) void {
        for (l.lines.items) |*x| x.deinit(l.gpa);
        l.lines.deinit(l.gpa);
        l.params.deinit(l.gpa);
    }

    fn last(l: *Log) *Line {
        if (l.lines.items.len == 0) l.lines.append(l.gpa, .{}) catch {};
        return &l.lines.items[l.lines.items.len - 1];
    }

    pub fn feed(l: *Log, bytes: []const u8) void {
        for (bytes) |b| l.byte(b);
    }

    fn byte(l: *Log, b: u8) void {
        switch (l.state) {
            .text => switch (b) {
                0x1b => l.state = .esc,
                '\n' => l.newLine(),
                '\r' => l.col = 0,
                0x08 => l.col -|= 1,
                '\t' => l.put("    "),
                else => if (b >= 0x20) l.utf8Byte(b),
            },
            .esc => {
                l.state = switch (b) {
                    '[' => .csi,
                    ']' => .osc,
                    else => .text,
                };
                l.params.clearRetainingCapacity();
            },
            .csi => if (b >= 0x40 and b <= 0x7e) {
                if (b == 'm') l.sgr();
                l.state = .text;
            } else l.params.append(l.gpa, b) catch {},
            .osc => switch (b) {
                0x07 => l.state = .text,
                0x1b => l.state = .osc_esc,
                else => {},
            },
            .osc_esc => l.state = .text,
        }
    }

    fn utf8Byte(l: *Log, b: u8) void {
        if (l.utf8_want == 0) {
            const n = std.unicode.utf8ByteSequenceLength(b) catch return;
            if (n == 1) return l.put(&.{b});
            l.utf8[0] = b;
            l.utf8_len = 1;
            l.utf8_want = n;
            return;
        }
        l.utf8[l.utf8_len] = b;
        l.utf8_len += 1;
        if (l.utf8_len == l.utf8_want) {
            l.utf8_want = 0;
            l.put(l.utf8[0..l.utf8_len]);
        }
    }

    /// Writes `s` at the column, over what was there after a \r.
    fn put(l: *Log, s: []const u8) void {
        const line = l.last();
        if (l.col < line.text.items.len) {
            // Overwriting after a carriage return: the line is cut here.
            line.text.shrinkRetainingCapacity(l.col);
            var keep: usize = 0;
            for (line.runs.items) |*r| {
                if (r.start >= l.col) continue;
                r.end = @min(r.end, @as(u32, @intCast(l.col)));
                line.runs.items[keep] = r.*;
                keep += 1;
            }
            line.runs.shrinkRetainingCapacity(keep);
        }
        const start: u32 = @intCast(line.text.items.len);
        line.text.appendSlice(l.gpa, s) catch return;
        l.col = line.text.items.len;
        const st = l.style;
        if (st.fg == null and !st.bold and !st.dim and !st.italic) return;
        if (line.runs.items.len > 0) {
            const prev = &line.runs.items[line.runs.items.len - 1];
            if (prev.end == start and std.meta.eql(prev.style, st)) {
                prev.end = @intCast(line.text.items.len);
                return;
            }
        }
        line.runs.append(l.gpa, .{ .start = start, .end = @intCast(line.text.items.len), .style = st }) catch {};
    }

    fn newLine(l: *Log) void {
        _ = l.last();
        l.lines.append(l.gpa, .{}) catch {};
        l.col = 0;
        if (l.lines.items.len > max_lines) {
            var gone = l.lines.orderedRemove(0);
            gone.deinit(l.gpa);
        }
    }

    fn sgr(l: *Log) void {
        var nums: [16]u32 = undefined;
        var n: usize = 0;
        var it = std.mem.splitAny(u8, l.params.items, ";:");
        while (it.next()) |p| {
            if (n == nums.len) break;
            nums[n] = std.fmt.parseInt(u32, p, 10) catch 0;
            n += 1;
        }
        if (n == 0) {
            nums[0] = 0;
            n = 1;
        }
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const v = nums[i];
            switch (v) {
                0 => l.style = .{},
                1 => l.style.bold = true,
                2 => l.style.dim = true,
                3 => l.style.italic = true,
                22 => {
                    l.style.bold = false;
                    l.style.dim = false;
                },
                23 => l.style.italic = false,
                30...37 => l.style.fg = l.palette[v - 30],
                90...97 => l.style.fg = l.palette[v - 90 + 8],
                39 => l.style.fg = null,
                38 => if (i + 2 < n and nums[i + 1] == 5) {
                    l.style.fg = color256(l.palette, @intCast(@min(nums[i + 2], 255)));
                    i += 2;
                } else if (i + 4 < n and nums[i + 1] == 2) {
                    l.style.fg = .{ .r = f(nums[i + 2]), .g = f(nums[i + 3]), .b = f(nums[i + 4]) };
                    i += 4;
                },
                else => {},
            }
        }
    }

    fn f(v: u32) f32 {
        return @as(f32, @floatFromInt(@min(v, 255))) / 255;
    }
};

/// xterm's 256 colours: the palette, a 6×6×6 cube, 24 greys.
pub fn color256(palette: [16]Color, i: u8) Color {
    if (i < 16) return palette[i];
    if (i < 232) {
        const n = i - 16;
        const levels = [6]f32{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = levels[n / 36] / 255, .g = levels[(n / 6) % 6] / 255, .b = levels[n % 6] / 255 };
    }
    const g = @as(f32, @floatFromInt(8 + 10 * @as(u32, i - 232))) / 255;
    return .{ .r = g, .g = g, .b = g };
}

const testing = std.testing;

fn plain() [16]Color {
    var p: [16]Color = undefined;
    for (&p, 0..) |*c, i| c.* = .{ .r = @as(f32, @floatFromInt(i)) / 16 };
    return p;
}

test "colours, a reset, and lines" {
    var l: Log = .{ .gpa = testing.allocator, .palette = plain() };
    defer l.deinit();
    l.feed("ok \x1b[1;32mPASS\x1b[0m done\nnext");
    try testing.expectEqual(@as(usize, 2), l.lines.items.len);
    const first = l.lines.items[0];
    try testing.expectEqualStrings("ok PASS done", first.text.items);
    try testing.expectEqual(@as(usize, 1), first.runs.items.len);
    try testing.expectEqual(@as(u32, 3), first.runs.items[0].start);
    try testing.expectEqual(@as(u32, 7), first.runs.items[0].end);
    try testing.expect(first.runs.items[0].style.bold);
    try testing.expectEqualStrings("next", l.lines.items[1].text.items);
}

test "a carriage return overwrites the line; other escapes are dropped" {
    var l: Log = .{ .gpa = testing.allocator, .palette = plain() };
    defer l.deinit();
    l.feed("\x1b]0;title\x07 10%\r 50%\r100%\x1b[2K\n");
    try testing.expectEqualStrings("100%", l.lines.items[0].text.items);
    l.feed("é\n");
    try testing.expectEqualStrings("é", l.lines.items[1].text.items);
}
