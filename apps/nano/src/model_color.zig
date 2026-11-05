//! A theme's colours as the theme crate keeps them (crates/theme/src/lib.rs
//! `Color`): 8-bit channels, and its arithmetic to the byte, so what nano
//! derives from a variant lands where the GPUI app's does.
const std = @import("std");
const ui = @import("nanoui").ui;

pub const Rgba = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const black: Rgba = .{};
    pub const white: Rgba = .{ .r = 255, .g = 255, .b = 255 };

    /// "#rrggbb" or "#rrggbbaa".
    pub fn parse(s: []const u8) ?Rgba {
        if ((s.len != 7 and s.len != 9) or s[0] != '#') return null;
        const n = std.fmt.parseInt(u32, s[1..], 16) catch return null;
        const v: u32 = if (s.len == 7) (n << 8) | 0xff else n;
        return .{ .r = @truncate(v >> 24), .g = @truncate(v >> 16), .b = @truncate(v >> 8), .a = @truncate(v) };
    }

    pub fn color(c: Rgba) ui.Color {
        return .{
            .r = @as(f32, @floatFromInt(c.r)) / 255,
            .g = @as(f32, @floatFromInt(c.g)) / 255,
            .b = @as(f32, @floatFromInt(c.b)) / 255,
            .a = @as(f32, @floatFromInt(c.a)) / 255,
        };
    }

    pub fn mix(c: Rgba, other: Rgba, amount: f32) Rgba {
        const t = std.math.clamp(amount, 0, 1);
        const m = struct {
            fn f(x: u8, y: u8, k: f32) u8 {
                const a: f32 = @floatFromInt(x);
                const b: f32 = @floatFromInt(y);
                return @intFromFloat(@round(a + (b - a) * k));
            }
        };
        return .{ .r = m.f(c.r, other.r, t), .g = m.f(c.g, other.g, t), .b = m.f(c.b, other.b, t), .a = m.f(c.a, other.a, t) };
    }

    pub fn blendOver(c: Rgba, background: Rgba) Rgba {
        const alpha = @as(f32, @floatFromInt(c.a)) / 255;
        const b = struct {
            fn f(front: u8, back: u8, al: f32) u8 {
                return @intFromFloat(@round(@as(f32, @floatFromInt(front)) * al + @as(f32, @floatFromInt(back)) * (1 - al)));
            }
        };
        return .{ .r = b.f(c.r, background.r, alpha), .g = b.f(c.g, background.g, alpha), .b = b.f(c.b, background.b, alpha) };
    }

    fn luminance(c: Rgba) f32 {
        const lin = struct {
            fn f(ch: u8) f32 {
                const v = @as(f32, @floatFromInt(ch)) / 255;
                return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
            }
        };
        return 0.2126 * lin.f(c.r) + 0.7152 * lin.f(c.g) + 0.0722 * lin.f(c.b);
    }

    /// WCAG contrast; a translucent colour as it shows over `background`.
    pub fn contrast(c: Rgba, background: Rgba) f32 {
        const fg = if (c.a == 255) c else c.blendOver(background);
        const a = fg.luminance();
        const b = background.luminance();
        return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
    }

    pub fn bestOn(c: Rgba) Rgba {
        return if (white.contrast(c) >= black.contrast(c)) white else black;
    }

    pub fn withAlpha(c: Rgba, alpha: f32) Rgba {
        var out = c;
        out.a = @intFromFloat(@round(std.math.clamp(alpha, 0, 1) * 255));
        return out;
    }

    /// Toward black or white, a twentieth at a time, until `minimum`
    /// contrast on `background` (`ensure_contrast`); else that extreme.
    pub fn ensureContrast(c: Rgba, background: Rgba, minimum: f32) Rgba {
        if (c.contrast(background) >= minimum) return c;
        const target = if (black.contrast(background) >= white.contrast(background)) black else white;
        var step: usize = 1;
        while (step <= 20) : (step += 1) {
            const candidate = c.mix(target, @as(f32, @floatFromInt(step)) / 20);
            if (candidate.contrast(background) >= minimum) return candidate;
        }
        return target;
    }

    pub fn eql(a: Rgba, b: Rgba) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    /// "#rrggbb", or "#rrggbbaa" when translucent (`Display`).
    pub fn hex(c: Rgba, buf: *[9]u8) []const u8 {
        return (if (c.a == 255)
            std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b })
        else
            std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a })) catch unreachable;
    }

    /// A CSS hex colour: #rgb, #rgba, #rrggbb or #rrggbbaa, spaces around
    /// it allowed (`FromStr`).
    pub fn css(text: []const u8) ?Rgba {
        const t = std.mem.trim(u8, text, " \t\n\r");
        if (t.len == 0 or t[0] != '#') return null;
        const v = t[1..];
        const nib = struct {
            fn f(ch: u8) ?u8 {
                return switch (ch) {
                    '0'...'9' => ch - '0',
                    'a'...'f' => ch - 'a' + 10,
                    'A'...'F' => ch - 'A' + 10,
                    else => null,
                };
            }
            fn pair(s: []const u8) ?u8 {
                return ((f(s[0]) orelse return null) << 4) | (f(s[1]) orelse return null);
            }
            fn one(ch: u8) ?u8 {
                const n = f(ch) orelse return null;
                return (n << 4) | n;
            }
        };
        return switch (v.len) {
            3 => .{ .r = nib.one(v[0]) orelse return null, .g = nib.one(v[1]) orelse return null, .b = nib.one(v[2]) orelse return null },
            4 => .{ .r = nib.one(v[0]) orelse return null, .g = nib.one(v[1]) orelse return null, .b = nib.one(v[2]) orelse return null, .a = nib.one(v[3]) orelse return null },
            6 => .{ .r = nib.pair(v[0..2]) orelse return null, .g = nib.pair(v[2..4]) orelse return null, .b = nib.pair(v[4..6]) orelse return null },
            8 => .{ .r = nib.pair(v[0..2]) orelse return null, .g = nib.pair(v[2..4]) orelse return null, .b = nib.pair(v[4..6]) orelse return null, .a = nib.pair(v[6..8]) orelse return null },
            else => null,
        };
    }
};

/// `harden_model_foreground`: `color` toward the preferred target, then
/// black, then white, a hundredth at a time, until it has `minimum`
/// contrast against every background; else the best it reached.
pub fn harden(color: Rgba, backgrounds: []const Rgba, minimum: f32, preferred: ?Rgba) Rgba {
    const least = struct {
        fn f(candidate: Rgba, bgs: []const Rgba) f32 {
            var m: f32 = std.math.inf(f32);
            for (bgs) |bg| m = @min(m, candidate.contrast(bg));
            return m;
        }
    };
    if (least.f(color, backgrounds) >= minimum) return color;
    var targets: [3]Rgba = undefined;
    var n: usize = 0;
    if (preferred) |p| {
        targets[n] = p;
        n += 1;
    }
    targets[n] = Rgba.black;
    targets[n + 1] = Rgba.white;
    n += 2;
    var best = color;
    var best_contrast = least.f(color, backgrounds);
    for (targets[0..n]) |target| {
        var step: usize = 1;
        while (step <= 100) : (step += 1) {
            const candidate = color.mix(target, @as(f32, @floatFromInt(step)) / 100);
            const c = least.f(candidate, backgrounds);
            if (c > best_contrast) {
                best = candidate;
                best_contrast = c;
            }
            if (c >= minimum) return candidate;
        }
    }
    return best;
}

const testing = std.testing;

test "the theme crate's arithmetic: mix, blend, contrast, and hardening" {
    const a = Rgba.parse("#7fa86b").?;
    const t = Rgba.parse("#edeae2").?;
    // Rust rounds halves away from zero: 154.5 is 155.
    try testing.expectEqual(Rgba.parse("#9bb989").?, a.mix(t, 0.25));
    try testing.expectEqual(Rgba{ .r = 128, .g = 128, .b = 128 }, (Rgba{ .r = 255, .g = 255, .b = 255, .a = 128 }).blendOver(Rgba.black));
    try testing.expectApproxEqAbs(@as(f32, 21), Rgba.white.contrast(Rgba.black), 0.01);
    try testing.expectEqual(Rgba.white, Rgba.parse("#232328").?.bestOn());
    // Grey text on a dark ground is lifted until it reads at 4.5:1.
    const lifted = harden(Rgba.parse("#444444").?, &.{Rgba.parse("#1e1e1e").?}, 4.5, null);
    try testing.expect(lifted.contrast(Rgba.parse("#1e1e1e").?) >= 4.5);
    // Already readable: untouched.
    try testing.expectEqual(t, harden(t, &.{Rgba.parse("#16140f").?}, 4.5, null));
}
