//! Harness's default palettes, Codegraff Dark and Codegraff Light, as the
//! GPUI app derives its roles from them (crates/theme/src/builtins.rs,
//! crates/ui/src/theme.rs): both are opaque, so the window and the main
//! column are painted in `shell`; the sidebar lays a wash over it. Geist for
//! words, Geist Mono for code.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Colors = struct {
    dark: bool,
    frosted: bool = false,
    recommended_frosted: bool = false,
    /// Original theme roles, before compositing for opaque paint.
    input_tint: Color = .transparent,
    overlay: Color = .transparent,
    card: Color = .transparent,
    panel: Color = .transparent,
    background: Color,
    /// The window and the main column.
    shell: Color,
    /// The sidebar: shell under wash(0.05).
    sidebar: Color,
    raised: Color,
    text: Color,
    muted: Color,
    faint: Color,
    /// A session row's time and the header's "project @ device".
    subline: Color,
    accent: Color,
    /// Accent behind inline code and selections.
    accent_wash: Color,
    /// The snake spinner's three rows: accent lighter, accent, deeper.
    glyph: [3]Color,
    danger: Color,
    danger_muted: Color,
    warning: Color,
    success: Color,
    /// `success.mix(text, 0.25)`.
    success_muted: Color,
    border: Color,
    border_strong: Color,
    /// element_hover: a control under the pointer.
    hover: Color,
    /// The selected session row: wash(.11) dark, wash(.06) light.
    selected: Color,
    user_bubble: Color,
    /// The composer's fill: `input` flattened on the background.
    composer: Color,
    /// Code panels.
    code_bg: Color,
    code_header: Color,
    /// white (dark) or black (light): a project badge's tone.
    tone: Color,
    /// The 16 colours a terminal's escape codes name.
    ansi: [16]Color,
    /// A primary button's fill and text.
    solid: Color,
    on_solid: Color,
    /// Changed lines in a diff.
    diff_add: Color,
    diff_del: Color,
    /// Codegraff's twelve syntax roles and the GPUI palette's Markdown six.
    syntax: @import("highlight.zig").Palette,

    /// White at `a` in dark, black at `a` in light.
    pub fn ink(k: Colors, a: f32) Color {
        return (if (k.dark) white else black).alpha(a);
    }

    /// The near-white (dark) or near-black (light) wash at `a`.
    pub fn wash(k: Colors, a: f32) Color {
        return (if (k.dark) Color.hex(0xebebeb) else Color.hex(0x1a1a1a)).alpha(a);
    }
};

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
const black: Color = .{};

/// The variants Settings › Appearance picked (`themeSelection`), by id.
pub var light_id: []const u8 = "codegraff-light";
pub var dark_id: []const u8 = "codegraff-dark";

/// The picked variant's palette for the appearance (themes.zig), else
/// Codegraff's.
pub fn colors(dark: bool) Colors {
    if (@import("themes.zig").find(if (dark) dark_id else light_id)) |v| if (v.dark == dark) return v.colors;
    return builtin(dark);
}

/// Codegraff Dark and Codegraff Light, as the GPUI app resolves them.
pub fn builtin(dark: bool) Colors {
    if (dark) {
        const accent = Color.hex(0xe8a33d);
        const muted = Color.hex(0x9a9384);
        return .{
            .dark = true,
            .background = .hex(0x16140f),
            .shell = .hex(0x1f1c16),
            .sidebar = .hex(0x292721),
            .raised = .hex(0x2a261e),
            .input_tint = Color.hex(0x2a261e).alpha(184.0 / 255.0),
            .overlay = .hex(0x231f19),
            .card = .hex(0x1f1c16),
            .panel = .hex(0x1f1c16),
            .text = .hex(0xedeae2),
            .muted = muted,
            .faint = .hex(0x5c564b),
            .subline = .hex(0x5d584d),
            .accent = accent,
            .accent_wash = accent.alpha(0.22),
            .glyph = .{ .hex(0xeebd73), accent, .hex(0xbe8632) },
            .danger = .hex(0xd2674f),
            .danger_muted = .hex(0xda8c78),
            .warning = .hex(0xd9a441),
            .success = .hex(0x7fa86b),
            .success_muted = .hex(0x9bb989),
            .border = white.alpha(0.10),
            .border_strong = white.alpha(0.18),
            .hover = white.alpha(0.11),
            .selected = Color.hex(0xebebeb).alpha(0.11),
            .user_bubble = .hex(0x2f2c27),
            .composer = .hex(0x24211a),
            .code_bg = white.alpha(0.035),
            .code_header = white.alpha(0.02),
            .tone = white,
            .ansi = hexes(.{ 0x16140f, 0xd2674f, 0x7fa86b, 0xd9a441, 0x8a9bb0, 0xbd80e4, 0x7fa86b, 0xedeae2, 0x5c564b, 0xd2674f, 0x7fa86b, 0xe8a33d, 0x8a9bb0, 0xbd80e4, 0x9a9384, 0xfaf8f3 }),
            .solid = .hex(0xebebef),
            .on_solid = black,
            .diff_add = .hex(0x7fa86b),
            .diff_del = .hex(0xd2674f),
            .syntax = syntax(.{ 0x5c564b, 0xe8a33d, 0x7fa86b, 0xd9a441, 0xedeae2, 0xe8a33d, 0xedeae2, 0xedeae2, 0x9a9384, 0xd2674f, 0xd9a441, 0xd2674f }, .{ 0x8f96ed, 0x1eb787, 0xe679b4, 0xdba924, 0xe679b4, 0x8f96ed }),
        };
    }
    const accent = Color.hex(0xc77d20);
    return .{
        .dark = false,
        .background = .hex(0xfaf8f3),
        .shell = .hex(0xf0ece3),
        .sidebar = .hex(0xe5e1d9),
        .raised = .hex(0xe7e1d5),
        .input_tint = .hex(0xf0ece3),
        .overlay = .hex(0xf0ece3),
        .card = .hex(0xf0ece3),
        .panel = .hex(0xf0ece3),
        .text = .hex(0x1a1813),
        .muted = .hex(0x6b6557),
        .faint = .hex(0xa8a090),
        .subline = .hex(0xada89d),
        .accent = accent,
        .accent_wash = accent.alpha(0.12),
        .glyph = .{ .hex(0xd09346), accent, .hex(0x935d18) },
        .danger = .hex(0xb14228),
        .danger_muted = .hex(0x873622),
        .warning = .hex(0x9a6e1b),
        .success = .hex(0x5c7e47),
        .success_muted = .hex(0x4c653a),
        .border = black.alpha(0.12),
        .border_strong = black.alpha(0.22),
        .hover = black.alpha(0.06),
        .selected = Color.hex(0x1a1a1a).alpha(0.06),
        .user_bubble = .hex(0xe8e4db),
        .composer = .hex(0xf0ece3),
        .code_bg = black.alpha(0.035),
        .code_header = black.alpha(0.02),
        .tone = black,
        .ansi = hexes(.{ 0x1a1813, 0xb14228, 0x5c7e47, 0x9a6e1b, 0x3b6fb0, 0x7a4ea3, 0x2f8f9d, 0x6b6557, 0xa8a090, 0xb14228, 0x5c7e47, 0xc77d20, 0x3b6fb0, 0x7a4ea3, 0x2f8f9d, 0x1a1813 }),
        .solid = .hex(0x232328),
        .on_solid = white,
        .diff_add = .hex(0x5c7e47),
        .diff_del = .hex(0xb14228),
        .syntax = syntax(.{ 0xa8a090, 0xc77d20, 0x5c7e47, 0x9a6e1b, 0x1a1813, 0xc77d20, 0x1a1813, 0x1a1813, 0x6b6557, 0xb14228, 0x9a6e1b, 0xb14228 }, .{ 0x5754b4, 0x0f5b41, 0x8d2f58, 0x7c451e, 0x8d2f58, 0x5754b4 }),
    };
}

/// builtins.rs's `syntax` seeds (comment, keyword, string, number, type,
/// function, property, variable, punctuation, tag, attribute, invalid),
/// then `SyntaxPalette::dark`/`light`'s Markdown hues (heading, raw, link,
/// reference, emphasis, strong), their oklch through `git_graph_tone`.
fn syntax(comptime roles: [12]u24, comptime markup: [6]u24) @import("highlight.zig").Palette {
    const r = roles;
    const m = markup;
    return .{
        .comment = .hex(r[0]),
        .keyword = .hex(r[1]),
        .string = .hex(r[2]),
        .number = .hex(r[3]),
        .type = .hex(r[4]),
        .function = .hex(r[5]),
        .property = .hex(r[6]),
        .variable = .hex(r[7]),
        .punctuation = .hex(r[8]),
        .tag = .hex(r[9]),
        .attribute = .hex(r[10]),
        .invalid = .hex(r[11]),
        .markup_heading = .hex(m[0]),
        .markup_raw = .hex(m[1]),
        .markup_link = .hex(m[2]),
        .markup_reference = .hex(m[3]),
        .markup_emphasis = .hex(m[4]),
        .markup_strong = .hex(m[5]),
    };
}

fn hexes(comptime v: [16]u24) [16]Color {
    var out: [16]Color = undefined;
    for (v, 0..) |h, i| out[i] = .hex(h);
    return out;
}

pub fn ui(dark: bool) nanoui.ui.Theme {
    const k = colors(dark);
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = k.shell;
    t.surface = k.composer;
    t.surface_hover = k.hover;
    t.text = k.text;
    t.muted = k.muted;
    t.border = k.border;
    t.accent = k.accent;
    t.accent_hover = k.accent.mix(if (dark) white else black, 0.14);
    t.accent_text = black;
    t.track = k.raised;
    t.danger = k.danger;
    t.success = k.success;
    t.font = "Geist";
    t.mono_font = "Geist Mono";
    return t;
}

var fonts_registered = false;

/// Geist and Geist Mono from the GPUI app's own files, before any window:
/// most Macs don't have them installed, and a missing family falls back
/// to the system's font, wider and lighter.
pub fn registerFonts() void {
    if (fonts_registered) return;
    fonts_registered = true;
    for (@import("fonts").all) |f| _ = @import("nanoui").ui.registerFont(f);
}
