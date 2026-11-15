//! Custom Theme & Animated Backdrop Studio: model-backed + offline theme
//! synthesis, motion/opacity/motif controls, and curated miniature scene gallery.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const custom_themes = @import("custom_themes.zig");
const view_backdrop = @import("view_backdrop.zig");
const requests = @import("requests.zig");
const rpc = @import("rpc.zig");

pub const GalleryFilter = enum { all, dark, light, custom };

const MotionOption = struct { key: []const u8, label: []const u8 };
const OpacityOption = struct { label: []const u8, value: f64 };

const quick_prompts = [_][]const u8{
    "Kyoto rain",
    "Northern aurora",
    "Sakura paper",
    "Firefly river",
    "Matrix terminal",
    "Zen stone ripples",
};

const motion_options = [_]MotionOption{
    .{ .key = "gentle", .label = "Gentle" },
    .{ .key = "lively", .label = "Lively" },
    .{ .key = "subtle", .label = "Subtle" },
    .{ .key = "static", .label = "Static" },
    .{ .key = "off", .label = "Off" },
};

const opacity_options = [_]OpacityOption{
    .{ .label = "Subtle", .value = 0.45 },
    .{ .label = "Balanced", .value = 0.72 },
    .{ .label = "Rich", .value = 0.92 },
};

var focus_prompt_pending: bool = false;
var gallery_filter: GalleryFilter = .all;

pub fn open(a: *App) void {
    a.view.custom_theme_open = true;
    a.view.custom_theme_error.clearRetainingCapacity();
    focus_prompt_pending = true;
    a.redraw();
}

pub fn openWithPrompt(a: *App, initial_prompt: []const u8) void {
    const trimmed = std.mem.trim(u8, initial_prompt, " \t\r\n");
    a.view.custom_theme_prompt.set(trimmed);
    open(a);
    if (trimmed.len > 0) submitPrompt(a);
}

pub fn close(a: *App) void {
    a.view.custom_theme_open = false;
    a.view.custom_theme_generating = false;
    if (a.view.custom_theme_req_id) |old| {
        a.gpa.free(old);
        a.view.custom_theme_req_id = null;
    }
    focus_prompt_pending = false;
    a.redraw();
}

pub fn escape(c: *ui.Context, a: *App) bool {
    if (!a.view.custom_theme_open) return false;
    if (!c.shortcut(.{ .key = ui.Shortcut.escape })) return false;
    close(a);
    return true;
}

pub fn applyPreset(a: *App, p: custom_themes.Preset) void {
    @import("view_settings_appearance.zig").setMode(a, if (p.variant.dark) .dark else .light);
    a.settings.setTheme(p.variant.dark, p.id);
    a.settings.setBackdropScene("auto");
    a.view.custom_theme_list_dirty = true;
    a.redraw();
}

pub fn submitPrompt(a: *App) void {
    const raw = a.view.custom_theme_prompt.text();
    const prompt = std.mem.trim(u8, raw, " \t\r\n");
    a.view.custom_theme_error.clearRetainingCapacity();
    if (prompt.len == 0) {
        a.view.custom_theme_error.appendSlice(a.gpa, "Describe a mood, palette, or scene (for example: Kyoto rain at midnight).") catch {};
        a.redraw();
        return;
    }

    if (a.view.custom_theme_req_id) |old| {
        a.gpa.free(old);
        a.view.custom_theme_req_id = null;
    }

    if (a.engine.state == .connected) {
        if (a.send_(requests.generateCustomTheme(prompt, null, null), rpc.Handler.of(App, a, onGenerateReply))) |req_id| {
            a.view.custom_theme_req_id = std.fmt.allocPrint(a.gpa, "{d}", .{req_id}) catch null;
            a.view.custom_theme_generating = true;
            a.redraw();
            return;
        }
    }

    applyLocalSynthesis(a, prompt);
}

fn applyLocalSynthesis(a: *App, prompt: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const preset = custom_themes.synthesizeFromPrompt(arena.allocator(), prompt, null);
    const saved = custom_themes.saveUserTheme(a.io, a.settings.dataDir(), preset) catch |e| {
        a.view.custom_theme_error.clearRetainingCapacity();
        a.view.custom_theme_error.appendSlice(a.gpa, @errorName(e)) catch {};
        a.view.custom_theme_generating = false;
        applyPreset(a, preset);
        return;
    };
    a.view.custom_theme_generating = false;
    applyPreset(a, saved);
}

pub fn onGenerateReply(a: *App, id: u64, reply: rpc.Reply) void {
    if (a.view.custom_theme_req_id) |expected| {
        var buf: [32]u8 = undefined;
        const id_str = std.fmt.bufPrint(&buf, "{d}", .{id}) catch return;
        if (!std.mem.eql(u8, expected, id_str)) return;
        a.gpa.free(expected);
        a.view.custom_theme_req_id = null;
    } else return;

    a.view.custom_theme_generating = false;
    const prompt = std.mem.trim(u8, a.view.custom_theme_prompt.text(), " \t\r\n");

    switch (reply) {
        .ok => |val| {
            var arena: std.heap.ArenaAllocator = .init(a.gpa);
            defer arena.deinit();
            if (custom_themes.parseGeneratedJson(arena.allocator(), val)) |preset| {
                const saved = custom_themes.saveUserTheme(a.io, a.settings.dataDir(), preset) catch preset;
                applyPreset(a, saved);
                return;
            }
            applyLocalSynthesis(a, prompt);
        },
        .err => applyLocalSynthesis(a, prompt),
        else => {},
    }
    a.redraw();
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.view.custom_theme_open) return;
    ui.key(c, "custom-theme-studio-overlay");
    const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(8).bg(.{ .a = if (k.dark) 0.42 else 0.30 }).center();
    defer scrim.end();

    const card_w = @min(660, @max(320, c.size.w - 36));
    const max_h = @max(280, c.size.h - 40);
    const card = kit.shadowLg(ui.div(c).w(card_w).maxH(max_h).column().rounded(16).bg(k.overlay).border(k.border).borderW(1).clip());
    defer card.end();
    _ = card.interaction();
    if (scrim.clicked() and !card.hovered()) {
        close(a);
        return;
    }

    // Header
    {
        const hdr = ui.div(c).row().wFull().px(20).pt(18).pb(14).gap(12).itemsCenter();
        defer hdr.end();
        {
            const titles = ui.div(c).column().w(card_w - 40 - 12 - 28).gap(3);
            defer titles.end();
            ui.text(c, "Custom themes & animated backdrops", set.st(c, 15, .{ .weight = .semibold, .color = k.text }));
            ui.text(c, "Describe any mood to synthesize a palette + scene, or choose a curated backdrop.", .{ .size = 12.5, .line_height = 18, .wrap = true, .color = k.muted });
        }
        const close_btn = ui.div(c).row().size(28, 28).center().rounded(7).border(k.border).borderW(1).bg(k.raised.alpha(0.3)).hover(k.raised);
        defer close_btn.end();
        icons.icon(c, .close, 12, k.muted, 0);
        if (close_btn.clicked()) {
            close(a);
            return;
        }
    }

    ui.div(c).wFull().h(1).bg(k.border.alpha(0.6)).end();

    // Scrollable studio body
    const body = ui.div(c).column().wFull().grow().h(0).maxH(@max(160, max_h - 86)).scrollY().px(20).py(16);
    defer body.end();
    studioBody(c, a, k, card_w - 42, true);
}

pub fn studioBody(c: *ui.Context, a: *App, k: theme.Colors, inner_w: f32, modal: bool) void {
    const col = ui.div(c).column().wFull().gap(14);
    defer col.end();

    // 1. Model-assisted prompt bar
    {
        const prompt_box = ui.div(c).column().wFull().gap(8);
        defer prompt_box.end();

        ui.text(c, "Create with a prompt", .{ .size = 12, .weight = .medium, .color = k.muted });
        {
            const r = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer r.end();

            {
                const field_wrap = ui.div(c).row().grow().w(0).h(36).px(12).itemsCenter().rounded(8).border(k.border).borderW(1).bg(k.ink(0.04));
                defer field_wrap.end();
                ui.key(c, if (modal) "custom-theme-prompt-modal" else "custom-theme-prompt-settings");
                const at = c.nodes.items.len;
                const res = ui.textField(c, &a.view.custom_theme_prompt, .{
                    .placeholder = "e.g. Kyoto rain at midnight, warm cedar lantern, aurora spruce…",
                    .placeholder_color = k.faint,
                    .width = .fill,
                    .bare = true,
                    .size = 13,
                    .line_height = 20,
                });
                const field_id = c.node(@intCast(at)).id;
                if (modal and focus_prompt_pending) {
                    c.focus = field_id;
                    c.changed = true;
                    focus_prompt_pending = false;
                }
                if (res.submitted and !a.view.custom_theme_generating) submitPrompt(a);
            }

            const gen_btn = kit.pressFeedback(ui.div(c).row().h(36).px(14).center().rounded(8).bg(if (a.view.custom_theme_generating) k.border else k.accent).hover(k.accent.alpha(0.88)).control());
            defer gen_btn.end();
            ui.text(c, if (a.view.custom_theme_generating) "Synthesizing…" else "Generate", .{
                .size = 12.5,
                .weight = .medium,
                .color = if (a.view.custom_theme_generating) k.muted else k.on_accent,
            });
            if (gen_btn.clicked() and !a.view.custom_theme_generating) submitPrompt(a);
        }

        if (a.view.custom_theme_error.items.len > 0) {
            ui.text(c, a.view.custom_theme_error.items, .{ .size = 11.5, .color = k.danger, .wrap = true });
        }

        // Quick idea chips
        renderQuickPromptChips(c, a, k, @max(160, inner_w - 8));
    }

    // 2. Backdrop motion, opacity & scene override
    {
        const ctrl = ui.div(c).column().wFull().gap(10).p(12).rounded(10).border(k.border).borderW(1).bg(k.ink(0.025));
        defer ctrl.end();

        // Motion row
        {
            const row = ui.div(c).row().wFull().justifyBetween().itemsCenter().gap(8);
            defer row.end();
            ui.text(c, "Backdrop motion", .{ .size = 12.5, .weight = .medium, .color = k.text });
            const pills = ui.div(c).row().gap(4);
            defer pills.end();
            const active_motion = a.settings.backdropMotionKey();
            for (motion_options) |opt| {
                const selected = std.mem.eql(u8, active_motion, opt.key);
                if (miniPill(c, k, opt.label, selected)) {
                    a.settings.setBackdropMotionKey(opt.key);
                    a.redraw();
                }
            }
        }

        // Opacity row
        {
            const row = ui.div(c).row().wFull().justifyBetween().itemsCenter().gap(8);
            defer row.end();
            ui.text(c, "Backdrop intensity", .{ .size = 12.5, .weight = .medium, .color = k.text });
            const pills = ui.div(c).row().gap(4);
            defer pills.end();
            const cur_alpha = a.settings.backdropOpacity();
            for (opacity_options) |opt| {
                const selected = @abs(cur_alpha - @as(f32, @floatCast(opt.value))) < 0.08;
                if (miniPill(c, k, opt.label, selected)) {
                    a.settings.setBackdropOpacity(opt.value);
                    a.redraw();
                }
            }
        }

        // Scene motif override chips
        ui.text(c, "Scene motif override", .{ .size = 11.5, .weight = .medium, .color = k.muted });
        renderMotifChips(c, a, k, @max(160, inner_w - 36));
    }

    // 3. Curated & generated scene gallery
    {
        const gallery = ui.div(c).column().wFull().gap(10);
        defer gallery.end();

        // Gallery header + filter tabs
        {
            const hdr = ui.div(c).row().wFull().justifyBetween().itemsCenter();
            defer hdr.end();
            ui.text(c, "Curated & generated scenes", .{ .size = 12, .weight = .medium, .color = k.muted });
            const tabs = ui.div(c).row().gap(4);
            defer tabs.end();
            const filters = [_]struct { f: GalleryFilter, label: []const u8 }{
                .{ .f = .all, .label = "All" },
                .{ .f = .dark, .label = "Dark" },
                .{ .f = .light, .label = "Light" },
                .{ .f = .custom, .label = "Generated" },
            };
            for (filters) |item| {
                if (miniPill(c, k, item.label, gallery_filter == item.f)) {
                    gallery_filter = item.f;
                    a.redraw();
                }
            }
        }

        renderPresetGrid(c, a, k, inner_w);
    }
}

fn renderQuickPromptChips(c: *ui.Context, a: *App, k: theme.Colors, max_w: f32) void {
    var i: usize = 0;
    while (i < quick_prompts.len) {
        const row = ui.div(c).row().gap(6);
        defer row.end();
        var used: f32 = 0;
        while (i < quick_prompts.len) {
            const label = quick_prompts[i];
            const chip_w = c.text.width(label, .{ .size = 11 }) + 22;
            if (used > 0 and used + chip_w > max_w) break;
            used += chip_w + 6;
            const chip = ui.div(c).row().px(9).py(4).roundedFull().border(k.border).borderW(1).bg(k.ink(0.03)).hover(k.ink(0.08)).control();
            defer chip.end();
            ui.text(c, label, .{ .size = 11, .color = k.muted });
            if (chip.clicked()) openWithPrompt(a, label);
            i += 1;
        }
    }
}

fn renderMotifChips(c: *ui.Context, a: *App, k: theme.Colors, max_w: f32) void {
    const cur = a.settings.backdropScene();
    const Item = struct { key: []const u8, label: []const u8 };
    var items: [1 + custom_themes.Motif.all.len]Item = undefined;
    items[0] = .{ .key = "auto", .label = "Auto (Theme)" };
    for (custom_themes.Motif.all, 0..) |m, idx| {
        items[1 + idx] = .{ .key = @tagName(m), .label = m.label() };
    }

    var i: usize = 0;
    while (i < items.len) {
        const row = ui.div(c).row().gap(5);
        defer row.end();
        var used: f32 = 0;
        while (i < items.len) {
            const item = items[i];
            const chip_w = c.text.width(item.label, .{ .size = 11.5, .weight = .medium }) + 24;
            if (used > 0 and used + chip_w > max_w) break;
            used += chip_w + 5;
            const active = std.mem.eql(u8, cur, item.key) or (std.mem.eql(u8, item.key, "auto") and cur.len == 0);
            if (miniPill(c, k, item.label, active)) {
                a.settings.setBackdropScene(item.key);
                a.redraw();
            }
            i += 1;
        }
    }
}

fn renderPresetGrid(c: *ui.Context, a: *App, k: theme.Colors, inner_w: f32) void {
    const gap: f32 = 8;
    const cols: usize = if (inner_w >= 540) 3 else if (inner_w >= 340) 2 else 1;
    const card_w = @max(120, @floor((inner_w - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols))));
    const active_id = a.settings.themeId(k.dark);
    const include_default = gallery_filter != .custom;

    var filtered: [96]*const custom_themes.Preset = undefined;
    var count: usize = 0;

    for (custom_themes.userPresets()) |*p| {
        if (matchesFilter(p, gallery_filter) and count < filtered.len) {
            filtered[count] = p;
            count += 1;
        }
    }
    for (custom_themes.curated()) |*p| {
        if (matchesFilter(p, gallery_filter) and count < filtered.len) {
            filtered[count] = p;
            count += 1;
        }
    }

    const total = count + @intFromBool(include_default);
    if (total == 0) {
        ui.text(c, "No generated scenes yet. Enter a prompt above to create your first custom theme.", .{ .size = 12, .color = k.muted, .wrap = true });
        return;
    }

    var slot: usize = 0;
    while (slot < total) {
        const row = ui.div(c).row().wFull().gap(gap);
        defer row.end();
        var col: usize = 0;
        while (col < cols and slot < total) : ({
            col += 1;
            slot += 1;
        }) {
            if (include_default and slot == 0) {
                systemDefaultCard(c, a, k, card_w);
            } else {
                const p = filtered[slot - @intFromBool(include_default)];
                const selected = std.mem.eql(u8, active_id, p.id) and k.dark == p.variant.dark;
                ui.key(c, c.print("preset-card-{s}", .{p.id}));
                presetCard(c, a, k, p, card_w, selected);
            }
        }
    }
}

fn systemDefaultCard(c: *ui.Context, a: *App, k: theme.Colors, card_w: f32) void {
    const appearance = @import("view_settings_appearance.zig");
    const selected = appearance.isSystemDefault(a);
    ui.key(c, "preset-card-system-default");
    const box = kit.pressFeedback(ui.div(c)
        .w(card_w)
        .p(6)
        .column()
        .gap(6)
        .rounded(10)
        .border(if (selected) k.accent else k.border)
        .borderW(if (selected) 1.5 else 1)
        .bg(if (selected) k.accent_wash else k.ink(0.02))
        .hover(k.ink(0.05))
        .control());
    defer box.end();

    const thumb_w = @max(60, card_w - 14);
    {
        const thumb = ui.div(c).row().w(thumb_w).h(54).rounded(7).border(k.border).borderW(1).clip();
        defer thumb.end();
        appearance.miniature(c, theme.builtin(false), thumb_w / 2, .left);
        appearance.miniature(c, theme.builtin(true), thumb_w / 2, .right);
    }

    {
        const meta = ui.div(c).column().wFull().gap(2);
        defer meta.end();
        {
            const top = ui.div(c).row().wFull().gap(5).itemsCenter();
            defer top.end();
            icons.icon(c, .monitor, 11, if (selected) k.accent else k.muted, 0);
            const title_w = @max(40, thumb_w - 28);
            {
                const title_box = ui.div(c).grow().w(0);
                defer title_box.end();
                kit.ellipsisText(c, "Default System", .{ .size = 12, .weight = .medium, .color = k.text }, title_w);
            }
            if (selected) icons.icon(c, .check, 11, k.accent, 0);
        }
        kit.ellipsisText(c, "Auto Light & Dark · Clean", .{ .size = 10.5, .color = k.muted }, thumb_w);
    }

    if (box.clicked()) appearance.applySystemDefault(a);
}

fn matchesFilter(p: *const custom_themes.Preset, f: GalleryFilter) bool {
    return switch (f) {
        .all => true,
        .dark => p.variant.dark,
        .light => !p.variant.dark,
        .custom => p.is_custom,
    };
}

fn presetCard(c: *ui.Context, a: *App, k: theme.Colors, p: *const custom_themes.Preset, card_w: f32, selected: bool) void {
    const box = kit.pressFeedback(ui.div(c)
        .w(card_w)
        .p(6)
        .column()
        .gap(6)
        .rounded(10)
        .border(if (selected) k.accent else k.border)
        .borderW(if (selected) 1.5 else 1)
        .bg(if (selected) k.accent_wash else k.ink(0.02))
        .hover(k.ink(0.05))
        .control());
    defer box.end();

    const thumb_w = @max(60, card_w - 14);
    {
        const thumb = ui.div(c).w(thumb_w).h(54).rounded(7).bg(p.variant.colors.background).border(p.variant.colors.border).borderW(1).clip();
        defer thumb.end();
        view_backdrop.miniature(c, p.backdrop, thumb_w, 54, p.variant.dark);
    }

    {
        const meta = ui.div(c).column().wFull().gap(2);
        defer meta.end();
        {
            const top = ui.div(c).row().wFull().gap(5).itemsCenter();
            defer top.end();
            kit.dot(c, 7, p.variant.colors.accent);
            const title_w = @max(40, thumb_w - 28);
            {
                const title_box = ui.div(c).grow().w(0);
                defer title_box.end();
                kit.ellipsisText(c, p.name, .{ .size = 12, .weight = .medium, .color = k.text }, title_w);
            }
            if (selected) icons.icon(c, .check, 11, k.accent, 0);
        }
        const sub = if (p.is_custom) c.print("{s} · AI", .{p.backdrop.motif.label()}) else p.subtitle;
        kit.ellipsisText(c, sub, .{ .size = 10.5, .color = k.muted }, thumb_w);
    }

    if (box.clicked()) applyPreset(a, p.*);
}

fn miniPill(c: *ui.Context, k: theme.Colors, label: []const u8, active: bool) bool {
    const pill = ui.div(c)
        .row()
        .px(8)
        .py(3.5)
        .rounded(6)
        .border(if (active) k.accent else k.border)
        .borderW(1)
        .bg(if (active) k.accent_wash else k.ink(0.03))
        .hover(if (active) k.accent_wash else k.ink(0.07))
        .control();
    defer pill.end();
    ui.text(c, label, .{ .size = 11.5, .weight = if (active) .medium else .regular, .color = if (active) k.text else k.muted });
    return pill.clicked();
}
