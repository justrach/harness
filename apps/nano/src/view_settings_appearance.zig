//! Settings › Appearance, as the GPUI app's (settings/appearance.rs): System,
//! Light or Dark from previews; the themes, the accent and the theme
//! library; frosted glass and the composer's background; compact mode;
//! motion; the fonts and the conversation's width. What it sets is the GPUI
//! app's own `ui-settings.json`; the appearance, accent and width apply here
//! too.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const icons = @import("icons.zig");
const set = @import("view_settings.zig");
const import_view = @import("view_settings_theme_import.zig");
const App = @import("app.zig").App;
const Color = ui.Color;

pub const Mode = enum { system, light, dark };

pub fn mode(a: *const App) Mode {
    return std.meta.stringToEnum(Mode, a.settings.text("appearance") orelse "system") orelse .system;
}

/// The accent presets in the picker's order, dark and light
/// (`AccentPreset`, theme/src/lib.rs).
pub const Preset = struct { name: []const u8, label: []const u8, dark: u24, light: u24 };
pub const presets = [_]Preset{
    .{ .name = "harness", .label = "Harness", .dark = 0x8b7cf6, .light = 0x5b43e8 },
    .{ .name = "orange", .label = "Orange", .dark = 0xfb923c, .light = 0xc2410c },
    .{ .name = "amber", .label = "Amber", .dark = 0xfbbf24, .light = 0xa16207 },
    .{ .name = "green", .label = "Green", .dark = 0x4ade80, .light = 0x15803d },
    .{ .name = "cyan", .label = "Cyan", .dark = 0x22d3ee, .light = 0x0e7490 },
    .{ .name = "blue", .label = "Blue", .dark = 0x60a5fa, .light = 0x2563eb },
    .{ .name = "pink", .label = "Pink", .dark = 0xf472b6, .light = 0xbe185d },
};

pub fn presetNamed(name: []const u8) ?Preset {
    for (presets) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

/// The page's colours with the chosen accent in place of the theme's.
pub fn withAccent(k: theme.Colors, a: *const App) theme.Colors {
    const p = presetNamed(a.settings.accent() orelse return k) orelse return k;
    var out = k;
    out.accent = Color.hex(if (k.dark) p.dark else p.light);
    out.accent_wash = out.accent.alpha(if (k.dark) 0.22 else 0.12);
    return out;
}

/// The conversation's column, 560 to 1200 by 16 (`transcriptWidth`).
pub fn transcriptWidth(a: *const App) f32 {
    const w = a.settings.number("transcriptWidth") orelse 736;
    return normalizeWidth(@floatCast(w));
}

pub fn normalizeWidth(w: f32) f32 {
    const clamped = std.math.clamp(w, 560, 1200);
    return 560 + @round((clamped - 560) / 16) * 16;
}

const phi: f32 = 1.618;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.header(c, k, "Appearance", null);
    set.subtitle(c, k, "Choose how Harness looks. These settings stay on this device.", true);
    caption(c, k, "Appearance");
    options(c, a, k);
    caption(c, k, "Theme");
    themeCard(c, a, k);
    caption(c, k, "Window and background");
    windowCard(c, a, k);
    caption(c, k, "Conversation");
    {
        const cd = card(c, k);
        defer cd.end();
        const r = set.row(c, k, true, false);
        defer r.end();
        set.tile(c, k, .@"eye-closed");
        words(c, k, "Compact mode", "Fold a turn's thinking, tool calls, and narration into one collapsed row — only the reply shows.", 32);
        if (switch_(c, k, a.settings.get(.transcript_compact_mode), 0)) a.settings.toggle(.transcript_compact_mode);
    }
    caption(c, k, "Motion");
    motionCard(c, a, k);
    fonts(c, a, k);
    import_view.warning(c, a, k);
}

/// The row's words, less the room a spacer's extra gap takes.
fn words(c: *ui.Context, k: theme.Colors, title: []const u8, meta: []const u8, trailing: f32) void {
    set.words(c, k, title, meta, trailing + 14);
}

/// A group's caption, 32 below what's above, 12 above its content.
/// This page's switches: the bare 32 by 18 switch, `ml` points after the
/// words, pinned to the row's end.
fn switch_(c: *ui.Context, k: theme.Colors, on: bool, ml: f32) bool {
    ui.spacer(c);
    const box = ui.div(c).row().pl(ml);
    defer box.end();
    const track = ui.div(c).row().w(32).h(18).roundedFull().bg(if (on) k.text else k.ink(0.15)).pl(if (on) 16 else 2).itemsCenter();
    defer track.end();
    _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (on) k.on_solid else k.ink(0.7) }, .none, null);
    return track.clicked();
}

fn caption(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    set.space(c, 32);
    set.fieldLabel(c, k, label);
    set.space(c, 12);
}

/// `section_card` with its top margin taken off.
fn card(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
}

// System, Light, Dark.

fn options(c: *ui.Context, a: *App, k: theme.Colors) void {
    const r = ui.div(c).row().wFull().gap(16);
    defer r.end();
    const current = mode(a);
    const w = (set.inner_w - 32) / 3;
    inline for (.{ .{ Mode.system, "System" }, .{ Mode.light, "Light" }, .{ Mode.dark, "Dark" } }) |o| {
        const selected = current == o[0];
        const col = ui.div(c).column().w(w).gap(8).itemsCenter();
        defer col.end();
        {
            const frame = ui.div(c).row().wFull().h(148).p(1).rounded(6).border(if (selected) k.accent else k.border).borderW(1).clip();
            defer frame.end();
            const inner_w = w - 2;
            switch (o[0]) {
                .light => miniature(c, theme.colors(false), inner_w, .all),
                .dark => miniature(c, theme.colors(true), inner_w, .all),
                .system => {
                    miniature(c, theme.colors(false), inner_w / 2, .left);
                    miniature(c, theme.colors(true), inner_w / 2, .right);
                },
            }
            if (frame.clicked()) setMode(a, o[0]);
        }
        const cap = ui.div(c).row().gap(6).itemsCenter();
        defer cap.end();
        // GPUI's caption icon is given no colour and draws nothing; its
        // room stays.
        _ = c.leaf(.{ .width = .{ .px = 16 }, .height = .{ .px = 16 } }, .none, null);
        ui.text(c, o[1], .{ .size = 13, .line_height = 13 * phi, .weight = if (selected) .medium else .regular, .color = if (selected) k.accent else k.muted });
        if (cap.clicked()) setMode(a, o[0]);
    }
}

pub fn setMode(a: *App, m: Mode) void {
    a.settings.setText("appearance", @tagName(m));
    a.dark = switch (m) {
        .system => null,
        .light => false,
        .dark => true,
    };
}

pub const Corners = enum { all, left, right };

/// A window in little: a sidebar of four bars and a pane of four lines.
pub fn miniature(c: *ui.Context, t: theme.Colors, w: f32, corners: Corners) void {
    _ = corners;
    const line = t.text.alpha(0.22);
    const strong = t.text.alpha(0.34);
    const root = ui.div(c).row().w(w).hFull().bg(t.shell);
    defer root.end();
    {
        const side = ui.div(c).column().w(44).hFull().gap(7).px(8).pt(14);
        defer side.end();
        for ([_]f32{ 0.7, 1, 0.85, 1 }, 0..) |f, i| bar(c, 28 * f, if (i == 0) strong else line);
    }
    const pane = ui.div(c).column().grow().w(0).hFull().py(8).pr(8);
    defer pane.end();
    const box = ui.div(c).column().wFull().grow().h(0).rounded(6).border(t.border).borderW(1).bg(t.background).p(11).gap(7);
    defer box.end();
    const inner = w - 44 - 8 - 22 - 2;
    for ([_]f32{ 0.62, 0.88, 0.76, 0.52 }, 0..) |f, i| bar(c, inner * f, if (i == 0) strong else line);
}

fn bar(c: *ui.Context, w: f32, color: Color) void {
    _ = c.leaf(.{ .width = .{ .px = w }, .height = .{ .px = 5 }, .radius = 3, .background = color }, .none, null);
}

// The theme card.

fn themeCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = card(c, k);
    defer cd.end();
    inline for (.{ .{ .sun, "Light theme", false }, .{ .moon, "Dark theme", true } }, 0..) |t, i| {
        const r = set.row(c, k, i == 0, false);
        defer r.end();
        set.tile(c, k, t[0]);
        words(c, k, t[1], "Used whenever this appearance is active.", 218);
        ui.spacer(c);
        const id = a.settings.themeId(t[2]);
        const v = themes.find(id);
        const open = a.view.theme_menu != null and a.view.theme_menu.? == t[2];
        const rect = picker(c, k, if (v) |x| x.colors else theme.builtin(t[2]), if (v) |x| x.name else id, open);
        if (rect.clicked) {
            a.view.theme_menu = if (open) null else t[2];
            // A theme the GPUI app added since shows in the menu.
            if (!open) a.view.theme_reload = true;
            a.view.theme_anchor = rect.at;
            c.changed = true;
        }
        if (open) a.view.theme_anchor = rect.at;
    }
    {
        const r = set.row(c, k, false, false);
        defer r.end();
        set.tile(c, k, .tuning);
        const chosen = if (a.settings.accent()) |n| presetNamed(n) else null;
        const meta = if (chosen) |p| c.print("{s} · Controls, glyphs, selections, code, and activity.", .{p.label}) else "Theme default · Uses the palette's intended color.";
        words(c, k, "Accent color", meta, 10 + 8 * 30 + 7 * 6);
        ui.spacer(c);
        const sw = ui.div(c).row().pl(10).gap(6);
        defer sw.end();
        if (swatch(c, k, null, chosen == null)) a.settings.setAccent(null);
        for (presets) |p| if (swatch(c, k, p, chosen != null and std.mem.eql(u8, chosen.?.name, p.name))) a.settings.setAccent(p.name);
    }
    {
        const r = set.row(c, k, false, false);
        defer r.end();
        set.tile(c, k, .@"folder-with-files");
        words(c, k, "Theme library", "Import or link custom themes.", 92);
        ui.spacer(c);
        const b = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
        defer b.end();
        ui.text(c, "Add theme", .{ .size = 13, .line_height = 13 * phi, .weight = .medium, .color = k.on_solid });
        if (b.clicked()) import_view.open(a);
    }
    import_view.libraryRows(c, a, k);
}

/// The theme picker's trigger: the variant's swatch, its name, and the
/// up-down arrow (`render_theme_selector`).
fn picker(c: *ui.Context, k: theme.Colors, t: theme.Colors, name: []const u8, open: bool) struct { clicked: bool, at: ?ui.Rect } {
    var p = ui.div(c).row().w(218).h(34).px(11).gap(8).itemsCenter().rounded(8).border(if (open) k.border_strong else k.border).borderW(1).bg(k.raised.alpha(if (open) 0.75 else 0.42));
    if (!open) p = p.hover(k.raised);
    defer p.end();
    preview(c, k, t);
    const n = ui.div(c).row().grow().w(0).clip();
    {
        defer n.end();
        ui.text(c, name, .{ .size = 12.5, .line_height = 12.5 * phi, .weight = .medium, .color = k.text });
    }
    icons.icon(c, .@"sort-vertical", 14, k.muted.alpha(if (open) 0.9 else 0.45), 0);
    return .{ .clicked = p.clicked(), .at = c.rects.get(c.node(p.index).id) };
}

/// `palette_preview`: the variant's shell, background and accent in a
/// bordered 30 by 18 chip.
pub fn preview(c: *ui.Context, k: theme.Colors, t: theme.Colors) void {
    _ = k;
    const sw = ui.div(c).row().size(30, 18).p(1).rounded(5).border(t.border).borderW(1).clip();
    defer sw.end();
    for ([_]Color{ t.shell, t.background, t.accent }) |col| _ = c.leaf(.{ .width = .{ .px = 28.0 / 3.0 }, .height = .fill, .background = col }, .none, null);
}

/// The open theme menu under its trigger: "Light themes" or "Dark themes",
/// then every variant of that appearance; picking one applies it.
pub fn themeMenu(c: *ui.Context, a: *App, k: theme.Colors) void {
    const dark = a.view.theme_menu orelse return;
    const at = a.view.theme_anchor orelse return;
    const kit = @import("view_kit.zig");
    if (kit.pressedOutside(c, at)) {
        a.view.theme_menu = null;
        return;
    }
    const w: f32 = 260;
    // Know the menu's height before showing it: using last frame's height
    // moves its rows between mouse-down and mouse-up on the first pick.
    var count: usize = 0;
    for (themes.all()) |v| if (v.dark == dark) {
        count += 1;
    };
    const heading_h = c.text.lineHeight(set.st(c, 10, .{ .weight = .medium })) + 10;
    const row_h = @max(18, c.text.lineHeight(set.st(c, 13, .{}))) + 12;
    const rows_h = @as(f32, @floatFromInt(count)) * (row_h + 2) - 2;
    const rows_max = @max(0, c.size.h - 16 - 10 - heading_h - 2);
    const h = 10 + heading_h + 2 + @min(rows_h, rows_max);
    const rules = @import("rules.zig");
    // Hung from the trigger's padding box, as GPUI's anchored menus are.
    const x = rules.snapToWindow(at.x + 1, w, c.size.w, 8);
    const y = rules.snapToWindow(at.y + at.h + 4.5, h, c.size.h, 8);
    ui.key(c, "appearance-theme-menu");
    const m = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(4 + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer m.end();
    {
        const hd = ui.div(c).row().wFull().px(8).pt(6).pb(4);
        defer hd.end();
        ui.text(c, if (dark) "D\u{200A}A\u{200A}R\u{200A}K\u{200A} \u{200A}T\u{200A}H\u{200A}E\u{200A}M\u{200A}E\u{200A}S" else "L\u{200A}I\u{200A}G\u{200A}H\u{200A}T\u{200A} \u{200A}T\u{200A}H\u{200A}E\u{200A}M\u{200A}E\u{200A}S", set.st(c, 10, .{ .weight = .medium, .color = k.muted }));
    }
    ui.scroll(c, .{ .width = .fill, .max_height = rows_max, .direction = .column, .gap = 2, .scrollbar = .{ .overlay = k.faint.alpha(0.5) } });
    defer ui.end(c);
    const picked = a.settings.themeId(dark);
    for (themes.all()) |*v| if (v.dark == dark) {
        ui.key(c, c.print("theme-{s}", .{v.id}));
        const active = std.mem.eql(u8, v.id, picked);
        const base = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7);
        // `menu_row`'s hover is a listener's: a menu opening under a still
        // pointer doesn't light the row there.
        const lh = kit.listenerHover(&a.view.hovers, if (active) base.bg(k.selected) else base, k.selected);
        const row = lh.div;
        defer row.end();
        const hot = lh.hovered;
        preview(c, k, v.colors);
        {
            const n = ui.div(c).row().grow().w(0).clip();
            defer n.end();
            ui.text(c, v.name, set.st(c, 13, .{ .color = if (active or hot) k.text else k.text.alpha(0.9) }));
        }
        if (active) icons.icon(c, .check, 14, k.accent, 0);
        if (row.clicked()) {
            a.settings.setTheme(dark, v.id);
            a.view.theme_menu = null;
            c.changed = true;
            a.redraw();
        }
    };
}

/// One accent: a 30-point chip over a 2-point underline in its colour when
/// chosen. The theme's own shows the glyph's three bars on its wash.
fn swatch(c: *ui.Context, k: theme.Colors, p: ?Preset, selected: bool) bool {
    const col = ui.div(c).column().w(30).gap(2);
    defer col.end();
    const accent = if (p) |pre| Color.hex(if (k.dark) pre.dark else pre.light) else k.accent;
    const chip = ui.div(c).row().size(30, 30).p(3).rounded(8).border(if (selected) k.border_strong else k.border).borderW(1).bg(k.raised.alpha(0.42));
    {
        defer chip.end();
        if (p != null) {
            _ = c.leaf(.{ .width = .{ .px = 24 }, .height = .{ .px = 24 }, .radius = 6, .background = accent }, .none, null);
        } else {
            const wash = ui.div(c).row().size(24, 24).rounded(6).bg(k.accent_wash).gap(2).center();
            defer wash.end();
            for ([_]f32{ 13, 16, 11 }, [_]Color{ k.glyph[0], k.glyph[1], k.glyph[2] }) |h, g| _ = c.leaf(.{ .width = .{ .px = 4 }, .height = .{ .px = h }, .radius = 2, .background = g }, .none, null);
        }
    }
    _ = c.leaf(.{ .width = .{ .px = 30 }, .height = .{ .px = 2 }, .background = if (selected) accent else Color{ .a = 0 } }, .none, null);
    return chip.clicked();
}

// Window and background.

fn windowCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = card(c, k);
    defer cd.end();
    {
        const r = set.row(c, k, true, false);
        defer r.end();
        const frosted = @import("surface_palette.zig").requested(a.settings.text("surface"), k.recommended_frosted);
        set.tile(c, k, .widget);
        words(c, k, "Frosted glass", if (frosted) "Blurs and tints what sits behind the window, where supported." else "Solid surfaces in every theme.", 42);
        if (switch_(c, k, frosted, 10)) {
            a.settings.setText("surface", if (frosted) "opaque" else "frosted");
            c.changed = true;
        }
    }
    const r = set.row(c, k, false, false);
    defer r.end();
    set.tile(c, k, .@"file-image");
    // Choose image's own width: 10 before it, 10 a side, its words.
    words(c, k, "New thread composer background", "Add an image behind the composer on empty new threads.", 10 + 2 * 10 + @ceil(c.text.width("Choose image", .{ .size = 11.5 })));
    ui.spacer(c);
    const act = ui.div(c).row().pl(10).gap(6);
    defer act.end();
    if (compactAction(c, k, "Choose image")) a.setNotice("A composer background isn't in Harness Nano yet: use Harness.");
}

/// `compact_action`: a small bordered button.
fn compactAction(c: *ui.Context, k: theme.Colors, label: []const u8) bool {
    // Padding plus the border, which GPUI insets by too.
    const b = ui.div(c).row().h(28).px(10).itemsCenter().rounded(7).border(k.border).borderW(1).bg(k.raised.alpha(0.34));
    defer b.end();
    ui.text(c, label, .{ .size = 11.5, .line_height = 11.5 * phi, .color = if (b.hovered()) k.text else k.muted });
    return b.clicked();
}

// Motion.

fn motionCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = card(c, k);
    defer cd.end();
    {
        const r = set.row(c, k, true, false);
        defer r.end();
        const value = a.settings.text("reduceMotion") orelse "system";
        set.tile(c, k, .@"magic-stick-3");
        const copy = if (std.mem.eql(u8, value, "on"))
            "Animations skip straight to their final state."
        else if (std.mem.eql(u8, value, "off"))
            "Animations play even if the system asks for less motion."
        else
            "Following the system, which currently allows motion.";
        // The choices' width: 10 before them, each 10 in a side (its
        // border with them), its words (laid out to the whole point), 6
        // between.
        var seg_w: f32 = 10 + 2 * 6;
        inline for (.{ .{ "System", "system" }, .{ "On", "on" }, .{ "Off", "off" } }) |o| {
            const selected = std.mem.eql(u8, value, o[1]);
            seg_w += 2 * 10 + @ceil(c.text.width(o[0], .{ .size = 11, .weight = if (selected) .medium else .regular }));
        }
        words(c, k, "Reduce motion", copy, seg_w);
        ui.spacer(c);
        const seg = ui.div(c).row().pl(10).gap(6);
        defer seg.end();
        inline for (.{ .{ "System", "system" }, .{ "On", "on" }, .{ "Off", "off" } }) |o| {
            const selected = std.mem.eql(u8, value, o[1]);
            var chip = ui.div(c).row().h(28).px(10).itemsCenter().rounded(7).borderW(1);
            chip = if (selected) chip.border(k.accent).bg(k.accent_wash) else chip.border(k.border).bg(k.raised.alpha(0.28)).hover(k.raised);
            defer chip.end();
            ui.text(c, o[0], .{ .size = 11, .line_height = 11 * phi, .weight = if (selected) .medium else .regular, .color = if (selected) k.accent else k.muted });
            if (!selected and chip.clicked()) a.settings.setText("reduceMotion", o[1]);
        }
    }
    const r = set.row(c, k, false, false);
    defer r.end();
    set.tile(c, k, .@"action-play");
    words(c, k, "Pause animations in background", "Hold animations still while Harness isn't the focused window. Saves CPU and battery.", 42);
    if (switch_(c, k, a.settings.get(.pause_animations_in_background), 10)) a.settings.toggle(.pause_animations_in_background);
}

// Fonts and the conversation's width.

fn fonts(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.space(c, 36);
    const box = ui.div(c).column().wFull().gap(18);
    defer box.end();
    const rows = .{
        .{ "Interface font", "Menus, sidebars, and conversation text.", "uiFontFamily", "geist", "uiFontSize", 16.0 },
        .{ "Terminal font", "Terminal panes and shell output. Fixed-width families only.", "terminalFontFamily", "geistMono", "terminalFontSize", 13.0 },
        .{ "Code & diff font", "Code blocks, diffs, and workspace file editors.", "codeFontFamily", "geistMono", "codeFontSize", 12.5 },
    };
    inline for (rows) |f| {
        const r = ui.div(c).row().wFull().gap(24).itemsCenter();
        defer r.end();
        {
            // `flex_1`: the row less the pair and the gap; the words at
            // most 520 wide.
            const lw = set.inner_w - 24 - 220 - 8 - 128;
            const l = ui.div(c).column().w(lw).gap(4);
            defer l.end();
            set.fieldLabel(c, k, f[0]);
            const dw = ui.div(c).column().w(@min(lw, 520));
            defer dw.end();
            ui.text(c, f[1], .{ .size = 12, .line_height = 18, .wrap = true, .color = k.muted });
        }
        const family = a.settings.text(f[2]) orelse f[3];
        const size = a.settings.number(f[4]) orelse f[5];
        const pair = ui.div(c).row().gap(8);
        defer pair.end();
        if (dropdown(c, k, 220, familyLabel(family))) a.setNotice("Choosing a font isn't in Harness Nano yet: use Harness.");
        if (dropdown(c, k, 128, c.print("{d} px", .{size}))) a.setNotice("Choosing a size isn't in Harness Nano yet: use Harness.");
    }
    widthRow(c, a, k);
}

pub fn familyLabel(v: []const u8) []const u8 {
    if (std.mem.eql(u8, v, "geist")) return "Geist";
    if (std.mem.eql(u8, v, "geistMono")) return "Geist Mono";
    if (std.mem.eql(u8, v, "system")) return "System UI";
    if (std.mem.startsWith(u8, v, "installed:")) return v["installed:".len..];
    return v;
}

/// A closed dropdown: its value and a chevron.
fn dropdown(c: *ui.Context, k: theme.Colors, w: f32, label: []const u8) bool {
    const d = ui.div(c).row().w(w).h(36).px(12).gap(8).itemsCenter().rounded(9).border(k.border).borderW(1).bg(k.ink(0.025));
    defer d.end();
    const n = ui.div(c).row().grow().w(0);
    {
        defer n.end();
        ui.text(c, label, .{ .size = 14, .line_height = 14 * phi, .color = k.text });
    }
    icons.icon(c, .@"alt-arrow-down", 14, k.muted, 0);
    return d.clicked();
}

/// "Conversation width": a slider from 560 to 1,200 points by 16; its
/// readout and range show only while it's handled.
fn widthRow(c: *ui.Context, a: *App, k: theme.Colors) void {
    const r = ui.div(c).row().wFull().gap(20).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).column().w(set.inner_w - 20 - 240).gap(4);
        defer l.end();
        set.fieldLabel(c, k, "Conversation width");
        ui.text(c, "Maximum width of messages and the composer in conversations. Adapts to smaller windows.", .{ .size = 12, .line_height = 18, .wrap = true, .color = k.muted });
    }
    const col = ui.div(c).column().w(240).gap(4);
    defer col.end();
    const width = transcriptWidth(a);
    // The readout above it ("736 px", Reset) shows only while it's handled;
    // its room is kept.
    _ = c.leaf(.{ .width = .{ .px = 240 }, .height = .{ .px = 16 } }, .none, null);
    {
        const slider = ui.div(c).row().w(240).h(28);
        const it = slider.interaction();
        defer slider.end();
        const frac = (width - 560) / 640;
        const track = ui.div(c).absolute().offset(7, 12).w(226).h(4).roundedFull().bg(k.border);
        {
            defer track.end();
            _ = c.leaf(.{ .width = .{ .px = 226 * frac }, .height = .fill, .radius = 2, .background = k.accent }, .none, null);
        }
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 7 + 226 * frac - 7, .y = 12 - 5 }, .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = k.accent }, .none, null);
        if (it.pressed) if (it.rect) |rect| {
            const f = std.math.clamp((c.input.mouse.x - rect.x - 7) / 226, 0, 1);
            const w = normalizeWidth(560 + f * 640);
            if (w != width) a.settings.setNumber("transcriptWidth", w);
        };
    }
    _ = c.leaf(.{ .width = .{ .px = 240 }, .height = .{ .px = 14 } }, .none, null);
}

const testing = std.testing;

test "appearance values as the GPUI app keeps them" {
    try testing.expectEqual(@as(f32, 736), normalizeWidth(736));
    try testing.expectEqual(@as(f32, 560), normalizeWidth(100));
    try testing.expectEqual(@as(f32, 1200), normalizeWidth(5000));
    try testing.expectEqual(@as(f32, 752), normalizeWidth(750));
    // Halfway rounds away from 560, as Rust's `round` does.
    try testing.expectEqual(@as(f32, 1008), normalizeWidth(1000));
    try testing.expectEqualStrings("Geist Mono", familyLabel("geistMono"));
    try testing.expectEqualStrings("Menlo", familyLabel("installed:Menlo"));
    try testing.expectEqual(@as(u24, 0xfb923c), presetNamed("orange").?.dark);
    try testing.expect(presetNamed("teal") == null);
}
