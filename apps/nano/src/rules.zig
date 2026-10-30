//! Rules the sidebar and composer share with the GPUI app, as pure
//! functions: when a row's time reads "now" or "3d"
//! (crates/proto/src/view.rs), a project's monogram and its colour
//! (crates/ui/src/shell/project_icon.rs), and a reasoning level's label.
const std = @import("std");
const Color = @import("nanoui").ui.Color;

/// Milliseconds since the epoch for an RFC 3339 time in UTC
/// ("2026-10-24T12:59:20.412Z", or with an offset), else null.
pub fn parseTime(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const n = struct {
        fn n(t: []const u8) ?i64 {
            return std.fmt.parseInt(i64, t, 10) catch null;
        }
    }.n;
    const y = n(s[0..4]) orelse return null;
    const mo = n(s[5..7]) orelse return null;
    const d = n(s[8..10]) orelse return null;
    const h = n(s[11..13]) orelse return null;
    const mi = n(s[14..16]) orelse return null;
    const sec = n(s[17..19]) orelse return null;
    var i: usize = 19;
    var ms: i64 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: i64 = 100;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            ms += (s[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    var offset_min: i64 = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-') and s.len >= i + 6) {
        const oh = n(s[i + 1 .. i + 3]) orelse return null;
        const om = n(s[i + 4 .. i + 6]) orelse return null;
        offset_min = (oh * 60 + om) * (if (s[i] == '-') @as(i64, -1) else 1);
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi - offset_min) * 60_000 + sec * 1000 + ms;
}

/// A ladder's default level (`default_reasoning`): High when offered, else
/// Medium, else the first; none for an empty ladder.
pub fn defaultReasoning(levels: []const []const u8) ?[]const u8 {
    for (levels) |l| if (std.mem.eql(u8, l, "high")) return l;
    for (levels) |l| if (std.mem.eql(u8, l, "medium")) return l;
    return if (levels.len > 0) levels[0] else null;
}

test "a ladder's default level is High, else Medium, else its first" {
    try std.testing.expectEqualStrings("high", defaultReasoning(&.{ "low", "medium", "high", "xhigh" }).?);
    try std.testing.expectEqualStrings("medium", defaultReasoning(&.{ "minimal", "medium" }).?);
    try std.testing.expectEqualStrings("low", defaultReasoning(&.{ "low", "max" }).?);
    try std.testing.expect(defaultReasoning(&.{}) == null);
}

/// A chat's folder as a session row names it (`project_label`): its last
/// part, or "No project" for none or the home folder.
pub fn projectLabel(cwd: ?[]const u8) []const u8 {
    const t = std.mem.trim(u8, cwd orelse "", " \t\n\r");
    if (t.len == 0 or std.mem.eql(u8, t, "~") or std.mem.eql(u8, t, "~/")) return "No project";
    const bare = std.mem.trimEnd(u8, t, "/\\");
    const at = std.mem.lastIndexOfAny(u8, bare, "/\\");
    const name = if (at) |i| bare[i + 1 ..] else bare;
    return if (name.len == 0) t else name;
}

/// The row's "project · branch" (`chat_location`): either part may be
/// missing; null when both are.
pub fn chatLocation(buf: []u8, cwd: ?[]const u8, branch: ?[]const u8) ?[]const u8 {
    const folder = std.mem.trim(u8, cwd orelse "", " \t\n\r");
    const project: ?[]const u8 = if (folder.len > 0) projectLabel(folder) else null;
    const b = std.mem.trim(u8, branch orelse "", " \t\n\r");
    const reference: ?[]const u8 = if (b.len > 0) b else null;
    if (project) |pr| {
        if (reference) |r| return std.fmt.bufPrint(buf, "{s} \u{00B7} {s}", .{ pr, r }) catch pr;
        return pr;
    }
    return reference;
}

test "a chat's location joins project and branch" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("soccertcg \u{00B7} harness/rebalance", chatLocation(&buf, "/home/w/dev/soccertcg", "harness/rebalance").?);
    try std.testing.expectEqualStrings("soccertcg", chatLocation(&buf, "/home/w/dev/soccertcg", null).?);
    try std.testing.expectEqualStrings("main", chatLocation(&buf, null, "main").?);
    try std.testing.expect(chatLocation(&buf, null, "   ") == null);
    try std.testing.expect(chatLocation(&buf, null, null) == null);
    try std.testing.expectEqualStrings("No project", projectLabel("~/"));
    try std.testing.expectEqualStrings("app", projectLabel("/work/app/"));
}

/// How long ago, as a session row reads it: "now", "5m", "2h", "3d", "2w",
/// "4mo", "1y" (`relative_time`).
pub fn relativeTime(buf: []u8, now_ms: i64, then_ms: i64) []const u8 {
    const s = @divFloor(@max(now_ms - then_ms, 0), 1000);
    const m = @divFloor(s, 60);
    const h = @divFloor(m, 60);
    const d = @divFloor(h, 24);
    const out = if (s < 60)
        std.fmt.bufPrint(buf, "now", .{})
    else if (m < 60)
        std.fmt.bufPrint(buf, "{d}m", .{m})
    else if (h < 24)
        std.fmt.bufPrint(buf, "{d}h", .{h})
    else if (d < 7)
        std.fmt.bufPrint(buf, "{d}d", .{d})
    else if (d < 35)
        std.fmt.bufPrint(buf, "{d}w", .{@divFloor(d, 7)})
    else if (@divFloor(d, 30) < 12)
        std.fmt.bufPrint(buf, "{d}mo", .{@divFloor(d, 30)})
    else
        std.fmt.bufPrint(buf, "{d}y", .{@divFloor(d, 365)});
    return out catch "";
}

/// The monogram palette: slate, blue, violet, rose, amber, emerald, teal,
/// orange; dark then light.
const palette = [8][2]u24{
    .{ 0x94a3b8, 0x475569 }, .{ 0x93c5fd, 0x2563eb }, .{ 0xc4b5fd, 0x7c3aed }, .{ 0xfda4af, 0xbe123c },
    .{ 0xfcd34d, 0xa16207 }, .{ 0x6ee7b7, 0x047857 }, .{ 0x5eead4, 0x0f766e }, .{ 0xfdba74, 0xc2410c },
};

pub const Monogram = struct { letter: u8, color: Color };

/// A project's badge without artwork: its name's first letter, and a
/// colour picked by FNV-1a of its path ("home" without a project).
pub fn monogram(name: []const u8, path: ?[]const u8, dark: bool) Monogram {
    const seed = path orelse "home";
    var hash: u32 = 2166136261;
    for (seed) |b| {
        hash ^= b;
        hash *%= 16777619;
    }
    const first = if (name.len > 0) name[0] else 'H';
    return .{
        .letter = std.ascii.toUpper(first),
        .color = .hex(palette[hash % 8][if (dark) 0 else 1]),
    };
}

/// `c` with its HSL lightness moved by `dl`, kept within [lo, hi] (the
/// GPUI app's `hsla.l` edits).
pub fn shiftLightness(c: Color, dl: f32, lo: f32, hi: f32) Color {
    const mx = @max(c.r, @max(c.g, c.b));
    const mn = @min(c.r, @min(c.g, c.b));
    const l = (mx + mn) / 2;
    const d = mx - mn;
    var h: f32 = 0;
    var sat: f32 = 0;
    if (d > 0) {
        sat = d / (1 - @abs(2 * l - 1));
        h = if (mx == c.r) @mod((c.g - c.b) / d, 6) else if (mx == c.g) (c.b - c.r) / d + 2 else (c.r - c.g) / d + 4;
        h /= 6;
    }
    const nl = if (dl >= 0) @min(l + dl, hi) else @max(l + dl, lo);
    const q = (1 - @abs(2 * nl - 1)) * sat;
    const x = q * (1 - @abs(@mod(h * 6, 2) - 1));
    const m = nl - q / 2;
    const rgb: [3]f32 = switch (@as(u3, @intFromFloat(@min(5, @floor(h * 6))))) {
        0 => .{ q, x, 0 },
        1 => .{ x, q, 0 },
        2 => .{ 0, q, x },
        3 => .{ 0, x, q },
        4 => .{ x, 0, q },
        else => .{ q, 0, x },
    };
    return .{ .r = rgb[0] + m, .g = rgb[1] + m, .b = rgb[2] + m, .a = c.a };
}

/// A reasoning level as the model chip names it.
pub fn reasoningLabel(level: []const u8) []const u8 {
    const pairs = .{
        .{ "none", "Off" },        .{ "minimal", "Minimal" }, .{ "low", "Low" },
        .{ "medium", "Medium" },   .{ "high", "High" },       .{ "xhigh", "X-High" },
        .{ "max", "Max" },         .{ "ultra", "Ultra" },     .{ "ultracode", "Ultracode" },
        .{ "ultrathink", "Ultrathink" },
    };
    inline for (pairs) |p| if (std.mem.eql(u8, level, p[0])) return p[1];
    return level;
}

/// How well `label` answers a picker's `query` (`popover::match_rank`):
/// 0 starts with it, 1 has it (or the query is empty), 2 and 3 the same
/// with only letters and digits compared, 4 every word found; null, none.
pub fn matchRank(query_in: []const u8, label: []const u8) ?u8 {
    var qb: [128]u8 = undefined;
    var lb: [256]u8 = undefined;
    const query = lower(&qb, std.mem.trim(u8, query_in, " \t"));
    if (query.len == 0) return 1;
    const l = lower(&lb, label);
    if (std.mem.startsWith(u8, l, query)) return 0;
    if (std.mem.indexOf(u8, l, query) != null) return 1;
    var cqb: [128]u8 = undefined;
    var clb: [256]u8 = undefined;
    const cq = alnum(&cqb, query);
    const cl = alnum(&clb, l);
    if (cq.len > 0 and std.mem.startsWith(u8, cl, cq)) return 2;
    if (cq.len > 0 and std.mem.indexOf(u8, cl, cq) != null) return 3;
    var words = std.mem.tokenizeAny(u8, query, " \t");
    var long = false;
    while (words.next()) |w| {
        if (w.len > 1) long = true;
        var wb: [128]u8 = undefined;
        const cw = alnum(&wb, w);
        if (std.mem.indexOf(u8, l, w) == null and (cw.len == 0 or std.mem.indexOf(u8, cl, cw) == null)) return null;
    }
    return if (long) 4 else null;
}

fn lower(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

fn alnum(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| if (std.ascii.isAlphanumeric(ch) and n < buf.len) {
        buf[n] = ch;
        n += 1;
    };
    return buf[0..n];
}

/// A menu's highlight moved `delta` rows of `count`, wrapping; from none, to
/// the edge it heads for (`popover::menu_step`).
pub fn menuStep(active: ?usize, count: usize, delta: isize) ?usize {
    if (count == 0) return null;
    const n: isize = @intCast(count);
    const from = active orelse return if (delta >= 0) 0 else count - 1;
    return @intCast(@mod(@as(isize, @intCast(from)) + delta, n));
}

/// Where a menu `size` long starting at `pos` goes in a window `limit`
/// long (`anchored().snap_to_window_with_margin`): left alone unless it
/// runs past the window's edge, then pulled back to `margin` inside it;
/// from the start, at `margin` if it's past that one.
pub fn snapToWindow(pos: f32, size: f32, limit: f32, margin: f32) f32 {
    var at = pos;
    if (at + size > limit) at -= at + size - limit + margin;
    if (at < 0) at = margin;
    return @round(at);
}

const testing = std.testing;

test "lightness moves in HSL, hue and saturation kept" {
    const c = shiftLightness(.hex(0x3a8a5c), 0.12, 0.15, 0.95);
    // #3a8a5c is hsl(145°, 41%, 38.4%); +0.12 gives about #4db479.
    try testing.expectApproxEqAbs(@as(f32, 0x4d) / 255, c.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0xb4) / 255, c.g, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0x79) / 255, c.b, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.95), shiftLightness(.white, 0.12, 0.15, 0.95).r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.15), shiftLightness(.black, -0.10, 0.15, 0.95).r, 0.001);
}

test "times parse in UTC and with offsets" {
    try testing.expectEqual(@as(?i64, 0), parseTime("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1_792_846_760_412), parseTime("2026-10-24T12:59:20.412Z"));
    try testing.expectEqual(parseTime("2026-10-24T12:59:20Z"), parseTime("2026-10-24T20:59:20+08:00"));
    try testing.expectEqual(@as(?i64, null), parseTime("yesterday"));
}

test "relative time reads as the sidebar's" {
    var b: [16]u8 = undefined;
    const now: i64 = 10_000_000_000;
    const cases = .{
        .{ 59, "now" },        .{ 60, "1m" },                  .{ 3599, "59m" },
        .{ 3600, "1h" },       .{ 86_400 * 6, "6d" },          .{ 86_400 * 7, "1w" },
        .{ 86_400 * 34, "4w" }, .{ 86_400 * 35, "1mo" },       .{ 86_400 * 400, "1y" },
    };
    inline for (cases) |cse| try testing.expectEqualStrings(cse[1], relativeTime(&b, now, now - cse[0] * 1000));
}

test "a monogram is the name's letter in a colour fixed by the path" {
    const a = monogram("web-dashboard", "/w/web-dashboard", true);
    try testing.expectEqual(@as(u8, 'W'), a.letter);
    const b = monogram("web-dashboard", "/w/web-dashboard", true);
    try testing.expectEqual(a.color, b.color);
    try testing.expectEqual(@as(u8, 'H'), monogram("", null, false).letter);
}

test "reasoning labels" {
    try testing.expectEqualStrings("Medium", reasoningLabel("medium"));
    try testing.expectEqualStrings("X-High", reasoningLabel("xhigh"));
}

test "a picker ranks matches as the GPUI app's" {
    try testing.expectEqual(@as(?u8, 0), matchRank("re", "release"));
    try testing.expectEqual(@as(?u8, 1), matchRank("lease", "release"));
    try testing.expectEqual(@as(?u8, null), matchRank("x", "release"));
    try testing.expectEqual(@as(?u8, 1), matchRank("", "anything"));
    try testing.expectEqual(@as(?u8, 2), matchRank("grok 4.7", "grok-4.7"));
    try testing.expectEqual(@as(?u8, 2), matchRank("Grok 4.7", "grok-4.7"));
    try testing.expectEqual(@as(?u8, 4), matchRank("sol 6", "gpt-5.6-sol"));
    try testing.expectEqual(@as(?u8, 4), matchRank("Sol 6", "GPT-5.6-Sol"));
}

test "a menu's highlight wraps and enters at the edge" {
    try testing.expectEqual(@as(?usize, null), menuStep(null, 0, 1));
    try testing.expectEqual(@as(?usize, null), menuStep(3, 0, 1));
    try testing.expectEqual(@as(?usize, 0), menuStep(null, 3, 1));
    try testing.expectEqual(@as(?usize, 2), menuStep(null, 3, -1));
    try testing.expectEqual(@as(?usize, 0), menuStep(2, 3, 1));
    try testing.expectEqual(@as(?usize, 2), menuStep(0, 3, -1));
    try testing.expectEqual(@as(?usize, 2), menuStep(1, 3, 1));
}

test "a menu moves only when it runs past the window, then to its margin" {
    // Up to the window's edge: where it was (GPUI doesn't keep the margin then).
    try testing.expectEqual(@as(f32, 980), snapToWindow(980, 220, 1200, 8));
    // Past it: its far edge 8 inside.
    try testing.expectEqual(@as(f32, 972), snapToWindow(990, 220, 1200, 8));
    // Past the near edge: at the margin.
    try testing.expectEqual(@as(f32, 8), snapToWindow(-30, 220, 1200, 8));
    // Wider than the window: the near edge wins.
    try testing.expectEqual(@as(f32, 8), snapToWindow(100, 1300, 1200, 8));
}
