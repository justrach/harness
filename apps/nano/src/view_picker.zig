//! Harness's model picker, two steps (crates/ui/src/pickers/model_preview.rs,
//! after Phil Hedayatnia's preview): agent tabs, a search, and the models
//! grouped by the route they're served through, a detail card floating
//! beside the row under the pointer; a click opens the model's page, with
//! its reasoning on a slider in the maker's colour and "Use model". It
//! states only what the catalog says: no ratings or prices are made up.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const models = @import("model_picker.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;

/// `PICKER_WIDTH` and `DETAIL_WIDTH`.
pub const menu_width: f32 = 356;
const detail_width: f32 = 276;
/// The list's height; the model's page fits its content (`h_auto`,
/// 4c9766def), measured as drawn, from this first guess.
const list_height: f32 = 480;
const stage_height: f32 = 293;

/// GPUI's menu_geometry and measure_trigger: new-chat menus prefer down
/// when 180 points fit; established chats prefer up, flipping near the top.
/// Clamps the top edge below the 38pt window titlebar (`header_height + 6`)
/// so agent tabs are never clipped against the top bar.
pub fn placement(anchor: ui.Rect, size: ui.Size, new_chat: bool, wanted: f32) struct { x: f32, y: f32, h: f32 } {
    const top_margin: f32 = @import("panel_chrome.zig").header_height + 6;
    const above = @max(0, anchor.y - top_margin - 6);
    const below = @max(0, size.h - anchor.y - anchor.h - 14);
    const down = (new_chat and below >= 180) or (above < 180 and below > above);
    const h = @min(wanted, @min(640, if (down) below else above));
    const w = @min(menu_width, size.w - 16);
    return .{
        // From the chip's leading edge: it sits at the footer's left now
        // (pickers.rs `attach_overlay`, no longer `attach_overlay_end`).
        .x = std.math.clamp(anchor.x, 8, @max(8, size.w - w - 8)),
        .y = if (down) anchor.y + anchor.h + 6 else @max(top_margin, anchor.y - h - 6),
        .h = h,
    };
}

pub fn opened(a: *App) void {
    const p = &a.view.model_picker;
    loadFavorites(a);
    p.query.clear();
    p.focus = true;
    p.opened_at = null;
    p.clearStage(a.gpa);
    p.detail = null;
    p.hover_target = null;
    p.detail_rect = null;
    p.starred = a.selected == null and p.favorites.items.len > 0;
    p.reveal = true;
    p.height = list_height;
    a.ensureModels(a.target().harness);
    _ = models.ensureCatalog(a, a.target().harness, true);
    if (p.starred) for (a.harnesses.items) |h| {
        if (h.offered) _ = models.ensureCatalog(a, h.id, false);
    };
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const list = models.rows(a, arena.allocator()) catch return;
    p.active = firstModel(list);
    const current = a.target().model orelse if (a.models.items.len > 0) a.models.items[0].id else "";
    for (list, 0..) |r, i| if (r.header == null and std.mem.eql(u8, r.harness, a.target().harness) and std.mem.eql(u8, r.model.id, current)) {
        p.active = i;
        break;
    };
}

/// Apply picks before building, so catalog replacement cannot invalidate
/// labels already borrowed by this frame's composer or model rows.
pub fn prepare(a: *App) void {
    const p = &a.view.model_picker;
    const pick = p.pending orelse return;
    p.pending = null;
    defer {
        if (pick.harness) |v| a.gpa.free(v);
        if (pick.model) |v| a.gpa.free(v);
        if (pick.reasoning) |v| a.gpa.free(v);
    }
    if (pick.harness) |h| {
        if (a.selected != null and !std.mem.eql(u8, h, a.target().harness)) return;
        if (!std.mem.eql(u8, h, a.target().harness)) a.setHarness(h);
        if (pick.model == null) p.focus = true;
    }
    if (pick.model) |id| if (pick.reasoning) |level| {
        a.pickModelAndReasoning(id, level);
    } else {
        a.pickModel(id);
    } else if (pick.reasoning) |level| a.pickReasoning(level);
    if (pick.model != null or pick.reasoning != null) a.view.focus_composer = true;
}

fn queue(c: *ui.Context, a: *App, harness: ?[]const u8, model: ?[]const u8, reasoning: ?[]const u8) void {
    const p = &a.view.model_picker;
    if (a.picker == .none or p.pending != null) return;
    const h = if (harness) |v| a.gpa.dupe(u8, v) catch return else null;
    const m = if (model) |v| a.gpa.dupe(u8, v) catch {
        if (h) |owned| a.gpa.free(owned);
        return;
    } else null;
    const r = if (reasoning) |v| a.gpa.dupe(u8, v) catch {
        if (h) |owned| a.gpa.free(owned);
        if (m) |owned| a.gpa.free(owned);
        return;
    } else null;
    p.pending = .{ .harness = h, .model = m, .reasoning = r };
    c.changed = true;
    a.redraw();
}

fn reset(c: *ui.Context, a: *App) void {
    const p = &a.view.model_picker;
    p.active = 0;
    p.reveal = true;
    p.detail = null;
    p.hover_target = null;
    if (p.scroll_id != 0) c.scroll.put(c.gpa, p.scroll_id, 0) catch {};
    c.changed = true;
}

/// The model `r` as the page shows it: its levels, else its agent's
/// ladder (`with_agent_ladder`).
fn levelsOf(a: *App, harness: []const u8, m: workspace.Model) []const []const u8 {
    if (m.levels.len > 0) return m.levels;
    return if (std.mem.eql(u8, harness, a.target().harness)) a.levelsOf(m.id) else &.{};
}

/// A click on a model: its page, the slider where its reasoning is now
/// (`preview_stage`). Another agent's model can't be staged in an open chat.
fn stage(c: *ui.Context, a: *App, r: models.Row) void {
    const p = &a.view.model_picker;
    if (p.stage != null or r.header != null) return;
    if (a.selected != null and !std.mem.eql(u8, r.harness, a.target().harness)) return;
    const harness = a.gpa.dupe(u8, r.harness) catch return;
    const id = a.gpa.dupe(u8, r.model.id) catch {
        a.gpa.free(harness);
        return;
    };
    const levels = levelsOf(a, r.harness, r.model);
    const want = a.target().reasoning orelse r.model.reasoning_default;
    var level: ?usize = null;
    if (levels.len > 0) {
        level = if (r.model.reasoning_default) |d| index(levels, d) else null;
        if (want) |w| if (index(levels, w)) |i| {
            level = i;
        };
        if (level == null) level = levels.len - 1;
    }
    p.stage = .{ .harness = harness, .model = id, .level = level };
    p.slider_seeded = false;
    p.drag_fraction = null;
    p.effort_anim = null;
    p.press_anim = null;
    p.energy_anim = null;
    p.shimmer_last = null;
    p.detail = null;
    p.hover_target = null;
    p.height = if (levels.len > 1) stage_height else 245;
    c.changed = true;
}

fn index(levels: []const []const u8, level: []const u8) ?usize {
    for (levels, 0..) |l, i| if (std.mem.eql(u8, l, level)) return i;
    return null;
}

/// The staged model as the catalog has it now, or null once it's gone.
fn staged(a: *App) ?workspace.Model {
    const st = a.view.model_picker.stage orelse return null;
    for (models.modelsFor(a, st.harness)) |m| if (std.mem.eql(u8, m.id, st.model)) return m;
    return null;
}

/// Back to the list (Escape, "Models").
fn back(c: *ui.Context, a: *App) void {
    const p = &a.view.model_picker;
    p.clearStage(a.gpa);
    p.height = list_height;
    p.focus = true;
    c.changed = true;
}

/// "Use model": its model and level, together (`preview_commit`); a model
/// the catalog dropped meanwhile says so instead.
fn commit(c: *ui.Context, a: *App) void {
    const p = &a.view.model_picker;
    const st = p.stage orelse return;
    const m = staged(a) orelse {
        if (p.stage) |*s| s.error_text = "Availability changed. Go back and select the model again.";
        c.changed = true;
        return;
    };
    const levels = levelsOf(a, st.harness, m);
    const level: ?[]const u8 = if (st.level) |i| (if (i < levels.len) levels[i] else null) else null;
    queue(c, a, st.harness, st.model, level);
}

fn firstModel(rows: []const models.Row) usize {
    for (rows, 0..) |r, i| if (r.header == null) return i;
    return 0;
}

/// AppKit's Home and End (NSHomeFunctionKey, NSEndFunctionKey).
const home_key: u21 = 0xF729;
const end_key: u21 = 0xF72B;

pub fn keys(c: *ui.Context, a: *App) void {
    const p = &a.view.model_picker;
    const S = ui.Shortcut;
    if (p.stage) |st| {
        // The page: Escape goes back, Return uses the model, the arrows,
        // Home and End move the slider (`preview_key`).
        if (c.shortcut(.{ .key = S.escape })) return back(c, a);
        if (c.shortcut(.{ .key = S.enter })) return commit(c, a);
        const m = staged(a) orelse return;
        const levels = levelsOf(a, st.harness, m);
        if (levels.len == 0) return;
        const cur = st.level orelse 0;
        const next: ?usize = if (c.shortcut(.{ .key = home_key }))
            0
        else if (c.shortcut(.{ .key = end_key }))
            levels.len - 1
        else if (c.shortcut(.{ .key = S.left }) or c.shortcut(.{ .key = S.down }))
            cur -| 1
        else if (c.shortcut(.{ .key = S.right }) or c.shortcut(.{ .key = S.up }))
            @min(cur + 1, levels.len - 1)
        else
            null;
        if (next) |n| {
            if (p.stage) |*s| s.level = n;
            c.changed = true;
        }
        return;
    }
    if (c.shortcut(.{ .key = S.escape })) {
        // A detail card first, then the picker.
        if (p.detail != null) {
            p.detail = null;
            p.hover_target = null;
            c.changed = true;
        } else {
            a.picker = .none;
            a.view.focus_composer = true;
        }
        return;
    }
    const next_agent = c.shortcut(.{ .key = S.tab, .ctrl = true });
    const prev_agent = c.shortcut(.{ .key = S.tab, .ctrl = true, .shift = true });
    if (next_agent or prev_agent) {
        if (a.selected != null) return;
        var agents: std.ArrayList([]const u8) = .empty;
        for (a.harnesses.items) |h| if (h.offered or std.mem.eql(u8, h.id, a.target().harness)) agents.append(c.alloc(), h.id) catch {};
        if (agents.items.len == 0) return;
        const at = for (agents.items, 0..) |id, i| {
            if (std.mem.eql(u8, id, a.target().harness)) break i;
        } else 0;
        const n = agents.items.len;
        const to = if (prev_agent) (at + n - 1) % n else (at + 1) % n;
        p.starred = false;
        reset(c, a);
        p.focus = true;
        queue(c, a, agents.items[to], null, null);
        return;
    }
    const down = c.shortcut(.{ .key = S.down });
    const up = c.shortcut(.{ .key = S.up });
    const enter = c.shortcut(.{ .key = S.enter });
    var picked_slot: ?usize = null;
    for (0..9) |slot| {
        if (c.shortcut(.{ .key = @as(u21, @intCast('1' + slot)), .cmd = true })) picked_slot = slot;
    }
    if (!down and !up and !enter and picked_slot == null) return;
    const list = models.rows(a, c.alloc()) catch return;
    if (picked_slot) |slot| {
        var n: usize = 0;
        for (list) |r| if (r.header == null) {
            if (n == slot) return stage(c, a, r);
            n += 1;
        };
        return;
    }
    if (list.len == 0) return;
    p.active = @min(p.active, list.len - 1);
    if (enter) return stage(c, a, list[p.active]);
    for (0..list.len) |_| {
        p.active = if (down) (p.active + 1) % list.len else (p.active + list.len - 1) % list.len;
        if (list[p.active].header == null) break;
    }
    // Keyboard navigation is an explicit preview: the card shows at once.
    p.detail = p.active;
    p.hover_target = null;
    p.reveal = true;
    c.changed = true;
}

pub fn popover(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.model_picker;
    var open = a.picker != .none;
    if (open) {
        p.anchor = a.view.chip_anchor;
        p.visible = true;
        p.closing_since = null;
    } else {
        if (!p.visible) return;
        if (p.closing_since == null) p.closing_since = c.time;
        if (c.reduced_motion or c.time - p.closing_since.? >= ui.motion.catalog.menu_out.total()) {
            p.visible = false;
            p.closing_since = null;
            p.anchor = null;
            p.clearStage(a.gpa);
            p.detail = null;
            return;
        }
    }
    const anchor = p.anchor orelse return;
    const w = @min(menu_width, c.size.w - 16);
    const geometry = placement(anchor, c.size, a.selected == null, p.height);
    const h = geometry.h;
    const x = geometry.x;
    const y = geometry.y;
    if (open) {
        ui.key(c, "model-picker-backdrop");
        const backdrop = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer backdrop.end();
        if (backdrop.clicked()) {
            a.picker = .none;
            a.view.focus_composer = true;
            p.closing_since = c.time;
            open = false;
            c.changed = true;
        }
    }
    // GPUI retains the menu while MENU_OUT fades and lifts it by two points.
    // It no longer owns focus or accepts picks during that short exit.
    var motion = if (open) ui.motion.Frame{} else ui.motion.menuOut(c, ui.motion.catalog.menu_out.progress(@floatCast((c.time - p.closing_since.?) / ui.motion.catalog.menu_out.total())));
    if (open) {
        if (p.opened_at == null) p.opened_at = c.time;
        const total = ui.motion.catalog.menu_in.total();
        const raw: f32 = @floatCast(std.math.clamp((c.time - (p.opened_at orelse c.time)) / total, 0, 1));
        const entered = ui.motion.Easing.css_ease_out.sample(raw)[0];
        motion.opacity *= 0.3 + 0.7 * entered;
        motion.y -= 2 * (1 - entered);
        if (raw < 1) c.animationFrame();
    } else {
        p.opened_at = null;
    }
    ui.key(c, "model-picker-card");
    const panel = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).motion(motion).w(w).h(h).layer(5).column().p(1)
        .bg(k.composer).border(k.border).borderW(1).rounded(12).clip()));
    defer panel.end();
    if (p.stage != null) return page(c, a, k, w - 2, open);
    tabs(c, a, k, w - 2);
    // The full-bleed hairline over the search (`crate::theme::hairline(0.08)`).
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.ink(0.08) }, .none, null);
    search(c, a, k);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.ink(0.06) }, .none, null);
    modelList(c, a, k, w - 2, h - 2 - 39 - 1 - 35 - 1 - 1 - 28, open, motion);
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.ink(0.08) }, .none, null);
    pickerFooter(c, k);
}

fn keycap(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const box = ui.div(c).row().px(5).py(1).rounded(4).bg(k.ink(if (k.dark) 0.06 else 0.04)).border(k.border).borderW(1).itemsCenter();
    defer box.end();
    ui.text(c, text, .{ .size = 10, .line_height = 13, .mono = true, .weight = .medium, .color = k.muted });
}

fn pickerFooter(c: *ui.Context, k: theme.Colors) void {
    const bar = ui.div(c).row().wFull().h(28).px(10).gap(10).itemsCenter().bg(k.ink(if (k.dark) 0.02 else 0.015));
    defer bar.end();
    {
        const nav = ui.div(c).row().gap(4).itemsCenter();
        defer nav.end();
        keycap(c, k, "↑↓");
        ui.text(c, "Navigate", .{ .size = 10.5, .line_height = 14, .color = k.muted });
    }
    {
        const sel = ui.div(c).row().gap(4).itemsCenter();
        defer sel.end();
        keycap(c, k, "↵");
        ui.text(c, "Configure", .{ .size = 10.5, .line_height = 14, .color = k.muted });
    }
    ui.spacer(c);
    {
        const esc = ui.div(c).row().gap(4).itemsCenter();
        defer esc.end();
        keycap(c, k, "esc");
        ui.text(c, "Close", .{ .size = 10.5, .line_height = 14, .color = k.muted });
    }
}

/// The models: a 34-point row each, in sections by route while browsing
/// one agent's catalog, flat for a search or the starred.
fn modelList(c: *ui.Context, a: *App, k: theme.Colors, w: f32, list_h: f32, open: bool, exit: ui.motion.Frame) void {
    const p = &a.view.model_picker;
    const rows = models.rows(a, c.alloc()) catch return;
    if (rows.len > 0 and (p.active >= rows.len or rows[p.active].header != null)) p.active = firstModel(rows);
    if (p.detail) |d| if (d >= rows.len or rows[d].header != null) {
        p.detail = null;
    };
    const grouped = for (rows) |r| {
        if (r.header != null) break true;
    } else false;
    const row_h: f32 = 34;
    var hovered: ?usize = null;
    var detail_row: ?ui.Rect = null;
    {
        var style: ui.Style = .{ .width = .fill, .height = .{ .px = @max(30, list_h) }, .padding = .{ .left = 6, .right = 6, .top = 1, .bottom = 6 } };
        if (@hasField(ui.Style, "scrollbar")) style.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
        ui.key(c, "model-picker-list");
        const at = c.nodes.items.len;
        ui.scroll(c, style);
        defer ui.end(c);
        const id = c.node(@intCast(at)).id;
        p.scroll_id = id;
        var offset = c.scroll.get(id) orelse 0;
        if (p.reveal) {
            const top = @as(f32, @floatFromInt(p.active)) * row_h;
            if (top < offset) offset = top else if (top + row_h > offset + list_h - 8) offset = top + row_h - list_h + 8;
            c.scroll.put(c.gpa, id, @max(0, offset)) catch {};
            p.reveal = false;
        }
        offset = std.math.clamp(offset, 0, @max(0, @as(f32, @floatFromInt(rows.len)) * row_h + 6 - list_h));
        const first = @min(rows.len, @as(usize, @intFromFloat(@floor(@max(0, offset - row_h) / row_h))));
        const last = @min(rows.len, first + @as(usize, @intFromFloat(@ceil(list_h / row_h))) + 3);
        space(c, @as(f32, @floatFromInt(first)) * row_h);
        for (rows[first..last], first..) |r, i| {
            ui.key(c, c.print("model-result-{s}-{s}-{d}-{any}", .{ r.harness, r.model.id, i, r.header != null }));
            const got = modelRow(c, a, k, r, i, grouped, w - 12, open);
            if (got.hovered) hovered = i;
            if (p.detail == i) detail_row = got.rect;
        }
        space(c, @as(f32, @floatFromInt(rows.len - last)) * row_h);
        if (rows.len == 0) {
            const empty = ui.div(c).column().wFull().py(24).px(8).itemsCenter();
            defer empty.end();
            const loading = if (p.catalogs.get(a.target().harness)) |cat| cat.loading else false;
            ui.text(c, if (p.starred) "No starred models yet — hit a row’s star" else if (loading) "Loading models…" else "No models found", .{ .size = 12, .color = k.muted });
        }
    }
    if (open) hoverDetail(c, a, hovered);
    if (p.detail) |d| if (detail_row) |r| detail(c, a, k, rows[d], r, exit) else {
        p.detail_rect = null;
    } else p.detail_rect = null;
}

/// The card follows the pointer: 180 ms on a row before it shows, 60 once
/// one is showing; it stays while the pointer is over it, and goes 160 ms
/// after the pointer leaves both (`preview_hover_row`).
fn hoverDetail(c: *ui.Context, a: *App, hovered: ?usize) void {
    const p = &a.view.model_picker;
    const m = c.input.mouse;
    const over_card = if (p.detail_rect) |r| m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h else false;
    if (hovered) |i| {
        if (p.hover_target != i) {
            p.hover_target = i;
            p.hover_since = c.time;
        }
        if (p.detail == i) return;
        const wait: f64 = if (p.detail != null) 0.06 else 0.18;
        const waited = c.time - p.hover_since;
        if (waited >= wait) {
            p.detail = i;
            c.changed = true;
        } else c.frameIn(@floatCast(wait - waited));
        return;
    }
    if (over_card or p.detail == null) return;
    if (p.hover_target != null) {
        p.hover_target = null;
        p.hover_since = c.time;
    }
    const waited = c.time - p.hover_since;
    if (waited >= 0.16) {
        p.detail = null;
        c.changed = true;
    } else c.frameIn(@floatCast(0.16 - waited));
}

fn modelRow(c: *ui.Context, a: *App, k: theme.Colors, r: models.Row, at: usize, grouped: bool, inner: f32, open: bool) struct { hovered: bool = false, rect: ?ui.Rect = null } {
    const p = &a.view.model_picker;
    if (r.header) |title| {
        // A section's heading: the route's mark, its name, and a subtle
        // plan badge when included in the user's subscription.
        const head = ui.div(c).row().wFull().h(34).px(10).pt(2).gap(7).itemsCenter();
        defer head.end();
        icons.icon(c, models.providerInfo(models.route(r.model)).icon, 13, k.muted, 13);
        kit.ellipsisText(c, title, .{ .size = 11, .weight = .semibold, .color = k.muted }, inner - 96);
        ui.spacer(c);
        if (models.billingRank(r.model.billing) == 0) {
            const pill = ui.div(c).row().px(6).py(1).rounded(4).bg(k.accent_wash);
            defer pill.end();
            ui.text(c, "Plan", .{ .size = 10, .line_height = 13, .weight = .semibold, .color = k.accent });
        }
        return .{};
    }
    const current = a.target().model orelse if (a.models.items.len > 0) a.models.items[0].id else "";
    const selected = std.mem.eql(u8, r.harness, a.target().harness) and std.mem.eql(u8, current, r.model.id);
    // `menu_row_nav`: the selected row and the keyboard's lit, a hover wash.
    var row = ui.div(c).row().wFull().h(34).px(8).gap(9).itemsCenter().rounded(8);
    row = if (selected or at == p.active or p.detail == at) row.bg(k.selected) else row.hover(k.selected);
    defer row.end();
    const hot = row.hovered();
    const pick = row.clicked();
    if (open and hot) p.active = at;
    const icon_sz: f32 = if (grouped) 14 else 15;
    icons.icon(c, models.modelIcon(r.model), icon_sz, if (hot or selected) k.text else k.muted.alpha(0.8), icon_sz);
    const ctx_buf = c.alloc().alloc(u8, 24) catch return .{};
    const ctx_tag: ?[]const u8 = rowContextBadge(ctx_buf, r.model);
    const tag_w: f32 = if (ctx_tag) |t| c.text.width(t, .{ .size = 10, .mono = true }) + 16 else 0;
    const room = inner - 16 - 24 - 9 - 23 - tag_w - (if (selected) @as(f32, 20) else 0);
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.ellipsisText(c, r.model.label, .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = if (hot or selected) k.text else k.text.alpha(0.92) }, @max(40, room));
    }
    if (ctx_tag) |tag| {
        const badge = ui.div(c).row().px(5).py(1).rounded(4).bg(k.ink(if (k.dark) 0.05 else 0.035));
        defer badge.end();
        ui.text(c, tag, .{ .size = 10, .line_height = 13, .mono = true, .color = k.muted.alpha(0.85) });
    }
    if (selected) icons.icon(c, .check, 12, k.accent, 12);
    const starred = p.favorite(r.harness, r.model.id);
    ui.key(c, "model-star");
    const star = ui.div(c).row().size(24, 24).center().rounded(5).hover(k.raised);
    var toggled = false;
    {
        defer star.end();
        toggled = star.clicked();
        icons.icon(c, if (starred) .@"star-bold" else .star, 12, if (starred) k.accent else k.muted, 12);
    }
    if (toggled and open) {
        p.toggleFavorite(a.gpa, r.harness, r.model.id);
        saveFavorites(a);
        c.changed = true;
    } else if (pick and open) stage(c, a, r);
    return .{ .hovered = hot, .rect = c.rects.get(c.node(row.index).id) };
}

fn rowContextBadge(buf: []u8, m: workspace.Model) ?[]const u8 {
    if (m.context) |n| return models.contextLabel(buf, n);
    const desc = m.description orelse return null;
    var it = std.mem.tokenizeAny(u8, desc, " \t·,()");
    var prev: ?[]const u8 = null;
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "context")) {
            if (prev) |p| if (p.len >= 2 and p.len <= 8 and std.ascii.isDigit(p[0])) return p;
        }
        prev = tok;
    }
    return null;
}

/// The detail card beside its row (`preview_detail`, `nested_menu`): 10
/// right of the row, or left when the window hasn't room.
fn detail(c: *ui.Context, a: *App, k: theme.Colors, r: models.Row, row: ui.Rect, exit: ui.motion.Frame) void {
    const p = &a.view.model_picker;
    const m = r.model;
    const right = row.x + row.w + 10;
    const left = c.size.w - right < detail_width + 8 and row.x - 10 >= detail_width + 8;
    const x = if (left) row.x - 10 - detail_width else @min(right, @max(8, c.size.w - detail_width - 8));
    const est: f32 = if (p.detail_rect) |d| d.h else 172;
    const top_margin: f32 = @import("panel_chrome.zig").header_height + 6;
    const y = std.math.clamp(row.y, top_margin, @max(top_margin, c.size.h - est - 8));
    ui.key(c, "model-detail-card");
    const card = kit.shadowLg(ui.div(c).fixed().offset(x, y).motion(exit).w(detail_width).layer(7).column().p(16 + 1).gap(11)
        .bg(k.composer).border(k.border).borderW(1).rounded(12));
    defer card.end();
    if (c.rects.get(c.node(card.index).id)) |rect| p.detail_rect = rect;
    const inner = detail_width - 34;
    const st: ui.TextStyle = .{ .size = 11, .line_height = kit.measured(11 * 1.618), .weight = .medium, .color = k.text };
    var muted = st;
    muted.color = k.muted;
    {
        const head = ui.div(c).row().gap(10).itemsCenter();
        defer head.end();
        {
            const tile = ui.div(c).row().size(32, 32).center().rounded(8).bg(k.ink(if (k.dark) 0.05 else 0.035)).border(k.border).borderW(1);
            defer tile.end();
            icons.icon(c, models.modelIcon(m), 17, k.text, 17);
        }
        const col = ui.div(c).column().gap(1);
        defer col.end();
        kit.ellipsisText(c, m.label, .{ .size = 13, .line_height = 17, .weight = .semibold, .color = k.text }, inner - 42);
        ui.text(c, c.print("via {s}", .{models.providerInfo(models.route(m)).name}), muted);
    }
    // Only what the catalog says.
    const range_buf = c.alloc().alloc(u8, 48) catch return;
    const ctx_buf = c.alloc().alloc(u8, 24) catch return;
    const levels = levelsOf(a, r.harness, m);
    const facts = [_]struct { []const u8, ?[]const u8 }{
        .{ "Reasoning", models.reasoningRange(range_buf, levels) },
        .{ "Context", if (m.context) |n| models.contextLabel(ctx_buf, n) else null },
        .{ "Billing", if (m.billing) |b| models.billingLabel(b) else null },
    };
    for (facts) |f| if (f[1]) |value| {
        const line_ = ui.div(c).row().wFull().itemsCenter();
        defer line_.end();
        ui.text(c, f[0], st);
        ui.spacer(c);
        const chip = ui.div(c).row().px(6).py(1).rounded(5).bg(k.ink(if (k.dark) 0.05 else 0.035));
        defer chip.end();
        ui.text(c, value, muted);
    };
    if (m.description) |d| {
        const desc = ui.div(c).column().wFull().gap(10);
        defer desc.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        // Wrapped lines keep their exact spacing: only the block is rounded.
        var wrap = muted;
        wrap.wrap = true;
        wrap.line_height = 11 * 1.618;
        ui.text(c, d, wrap);
    }
}

/// The model's page (`preview_reasoning`): back to the models, the model
/// and its route, its reasoning on a slider in the maker's colour, and
/// "Use model".
fn page(c: *ui.Context, a: *App, k: theme.Colors, w: f32, open: bool) void {
    const p = &a.view.model_picker;
    const st = p.stage orelse return;
    const harness_id = c.print("{s}", .{st.harness});
    const model_id = c.print("{s}", .{st.model});
    const fallback_level = st.level orelse 0;
    ui.key(c, "model-page");
    // The card wants its content's own height (`h_auto`), capped by the
    // room there is (`max_h`): the controls are measured as laid out, not
    // as the card stretched them, so a short window scrolls them instead.
    var natural: f32 = 2;
    var measured: u8 = 0;
    const content = ui.div(c).column().wFull().grow().h(0);
    defer {
        content.end();
        if (p.stage != null and measured == 2 and @abs(natural - p.height) > 0.5) {
            p.height = natural;
            c.changed = true;
        }
    }
    // A model the catalog dropped keeps its page, to say so on commit.
    const m: workspace.Model = staged(a) orelse .{ .id = model_id, .label = model_id };
    const levels = levelsOf(a, harness_id, m);
    const is_binary = models.binary(levels);
    const raw_accent: ui.Color = if (models.brandHex(m, harness_id, k.dark)) |hx| ui.Color.hex(hx) else k.accent;
    // Ensure high contrast on warm light surfaces when the brand hex is a
    // light sky blue (`0x66b5ff`).
    const accent: ui.Color = if (!k.dark and raw_accent.b > 0.85 and raw_accent.r > 0.3)
        ui.Color.hex(0x2563eb)
    else
        raw_accent;
    {
        const body = ui.div(c).column().wFull().grow().h(0).clip();
        defer body.end();
        const inner = ui.div(c).column().wFull().p(16).gap(16);
        defer inner.end();
        if (c.rects.get(c.node(inner.index).id)) |r| {
            natural += r.h;
            measured += 1;
        }
        {
            const top_row = ui.div(c).row().wFull().itemsCenter();
            defer top_row.end();
            ui.key(c, "model-page-back");
            const b = ui.div(c).row().h(26).px(8).gap(6).itemsCenter().rounded(6).bg(k.ink(if (k.dark) 0.04 else 0.03)).hover(k.hover);
            if (b.clicked() and open) back(c, a);
            icons.icon(c, .@"arrow-left", 13, k.text, 13);
            ui.text(c, "Models", .{ .size = 12, .line_height = 12 * 1.618, .weight = .medium, .color = if (b.hovered()) k.text else k.text.alpha(0.9) });
            b.end();
            ui.spacer(c);
            keycap(c, k, "esc");
        }
        {
            const head = ui.div(c).row().gap(12).itemsCenter();
            defer head.end();
            const tile = ui.div(c).row().size(38, 38).center().rounded(10).bg(k.ink(if (k.dark) 0.05 else 0.035)).border(k.border).borderW(1);
            icons.icon(c, models.modelIcon(m), 20, k.text, 20);
            tile.end();
            const words = ui.div(c).column().gap(3);
            defer words.end();
            // GPUI's own line height, φ, everywhere on this page.
            kit.ellipsisText(c, m.label, .{ .size = 16, .line_height = 16 * 1.618, .weight = .semibold, .color = k.text }, w - 32 - 50);
            ui.text(c, c.print("via {s}", .{models.providerInfo(models.route(m)).name}), .{ .size = 11, .line_height = 11 * 1.618, .weight = .medium, .color = k.muted });
        }
        {
            const r = ui.div(c).row().wFull().itemsCenter();
            defer r.end();
            // Medium, as everything in the card inherits (`popover_frame`).
            const st13: ui.TextStyle = .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = k.text };
            ui.text(c, if (is_binary) "Thinking" else "Reasoning", st13);
            ui.spacer(c);
            const cur_level = if (p.stage) |s| s.level else st.level;
            const label = if (cur_level) |i| (if (i < levels.len) models.levelLabel(levels[i], is_binary) else "Model default") else "Model default";
            const badge = ui.div(c).row().px(8).py(2).rounded(6).bg(accent.alpha(0.14)).border(accent.alpha(0.28)).borderW(1).clip();
            defer badge.end();
            kit.rollText(c, "model-picker-effort-badge", label, .{ .size = 12.5, .line_height = 18, .weight = .semibold, .color = k.text });
        }
        if (levels.len > 1) {
            slider(c, a, k, accent, levels.len, w - 32 - 28, open, fallback_level);
            const ends = ui.div(c).row().wFull().itemsCenter();
            defer ends.end();
            ui.text(c, if (is_binary) "Off" else "Faster", .{ .size = 11, .line_height = 11 * 1.618, .weight = .medium, .color = k.muted });
            ui.spacer(c);
            ui.text(c, if (is_binary) "On" else "Deeper", .{ .size = 11, .line_height = 11 * 1.618, .weight = .medium, .color = k.muted });
        } else {
            ui.text(c, "This model has no adjustable reasoning level.", .{ .size = 12, .line_height = 12 * 1.618, .weight = .medium, .wrap = true, .color = k.muted });
        }
        if (st.error_text) |e| ui.text(c, e, .{ .size = 12, .line_height = 12 * 1.618, .wrap = true, .color = k.danger });
    }
    const foot = ui.div(c).row().wFull().px(16).pb(12);
    defer foot.end();
    if (c.rects.get(c.node(foot.index).id)) |r| {
        natural += r.h;
        measured += 1;
    }
    ui.key(c, "model-use");
    var b = ui.div(c).row().wFull().h(36).px(12).gap(8).center().rounded(8).bg(k.solid);
    if (b.hovered()) b = b.opacity(0.9);
    defer b.end();
    if (b.clicked() and open) commit(c, a);
    ui.text(c, "Use model", .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = k.on_solid });
}

/// The reasoning slider (`crates/ui/src/pickers/compact.rs`): a 26-point
/// circular capsule rail, filled to the level in the model's colour with a
/// flowing light-wave shimmer and breathing halo on deeper effort stops,
/// stop dots that light up as the animated fill front reaches them, and a
/// circular thumb that tracks the pointer continuously while dragging and
/// glides from the exact release pointer position to the snapped stop over
/// 200ms (`RESIZE` curve).
fn slider(c: *ui.Context, a: *App, k: theme.Colors, accent: ui.Color, n: usize, tw: f32, open: bool, fallback_level: usize) void {
    const p = &a.view.model_picker;
    const last: f32 = @floatFromInt(n - 1);
    const pad = ui.div(c).row().wFull().px(14);
    defer pad.end();
    ui.key(c, "model-slider-track");
    const track = ui.div(c).w(tw).h(34);
    defer track.end();
    const track_id = c.node(track.index).id;
    if (c.rects.get(track_id)) |r| p.track = r;
    var level = if (p.stage) |s| (s.level orelse 0) else fallback_level;
    if (open and track.hovered() and c.input.pressed) p.dragging = true;
    if (p.dragging) {
        if (p.track) |r| {
            const at = std.math.clamp((c.input.mouse.x - r.x) / @max(1, r.w), 0, 1);
            p.drag_fraction = at;
            const next: usize = @intFromFloat(@round(at * last));
            if (next != level) {
                level = next;
                if (p.stage) |*s| s.level = next;
                c.changed = true;
            }
        }
        if (!c.input.down or c.input.released) {
            p.dragging = false;
            p.drag_fraction = null;
            c.changed = true;
        }
    }
    const target = @as(f32, @floatFromInt(level)) / last;
    const effort_sample = models.ScalarTransition.sample(&p.effort_anim, target, c.time, c.reduced_motion);
    var fraction = effort_sample.value;
    if (p.dragging) {
        fraction = p.drag_fraction orelse target;
        // Root the release animation at the actual pointer position, not the previous stop.
        p.effort_anim = .{ .from = fraction, .to = fraction, .started = c.time };
    }
    const press_sample = models.ScalarTransition.sample(&p.press_anim, if (p.dragging) 1.0 else 0.0, c.time, c.reduced_motion);
    const press = press_sample.value;
    const target_energy: f32 = if (n > 1 and level >= 2) target else if (n == 2 and level == 1) 0.75 else 0.0;
    const energy_sample = models.ScalarTransition.sample(&p.energy_anim, target_energy, c.time, c.reduced_motion);
    const intensity = energy_sample.value;
    if (effort_sample.moving or press_sample.moving or energy_sample.moving) {
        c.frameIn(1.0 / 120.0);
    }
    var breath: f32 = 0.0;
    if (intensity > 0.001 and !c.reduced_motion) {
        const dt: f32 = if (p.shimmer_last) |prev| @floatCast(std.math.clamp(c.time - prev, 0.0, 0.1)) else 0.0;
        p.shimmer_last = c.time;
        p.shimmer_phase = @mod(p.shimmer_phase + dt * (0.32 + 0.22 * intensity), 1.0);
        breath = 0.5 + 0.5 * @sin(std.math.tau * p.shimmer_phase);
        if (!effort_sample.moving and !press_sample.moving and !energy_sample.moving) {
            c.frameIn(1.0 / 60.0);
        }
    } else {
        p.shimmer_last = null;
    }

    // Track rail.
    ui.div(c).absolute().offset(-14, 4).size(tw + 28, 26).rounded(13).circular().bg(k.ink(if (k.dark) 0.08 else 0.055)).border(k.border).borderW(1).end();

    // Accent fill + flowing light-wave shimmer (`effort_fill`).
    const fill_w = fraction * tw + 28;
    const fill_bg = ui.motion.effects.mix(accent, ui.Color.hex(0xffffff), intensity * (0.08 + 0.12 * breath));
    {
        const fill_box = ui.div(c).absolute().offset(-14, 4).size(fill_w, 26).rounded(13).circular().bg(fill_bg).clip();
        defer fill_box.end();
        if (intensity > 0.001 and fill_w > 26) {
            const lifted = ui.motion.effects.mix(accent, ui.Color.hex(0xffffff), 0.45);
            const shifted = ui.Color{
                .r = @min(1.0, accent.r * 0.85 + 0.15),
                .g = @min(1.0, accent.g * 0.90 + 0.14),
                .b = @min(1.0, accent.b * 0.95 + 0.18),
                .a = 1.0,
            };
            const center_x = fraction * tw + 14.0;
            const step_w: f32 = 6.0;
            var x: f32 = 0.0;
            while (x < fill_w) : (x += step_w) {
                const sw = @min(step_w, fill_w - x);
                const xm = x + sw * 0.5;
                const slow = 0.5 + 0.5 * @sin(std.math.tau * (xm / 150.0 - 2.0 * p.shimmer_phase));
                const quick = 0.5 + 0.5 * @sin(std.math.tau * (xm / 64.0 - 3.0 * p.shimmer_phase) + 1.7);
                const glow_base = 0.65 * slow + 0.35 * quick;
                const glow = glow_base * glow_base;
                const charge = @exp(-@max(0.0, center_x - xm) / 40.0) * (0.6 + 0.4 * breath);
                const lead = std.math.clamp(xm / 28.0, 0.0, 1.0);
                const alpha = std.math.clamp(intensity * ((0.08 + 0.34 * glow) * lead + 0.22 * charge), 0.0, 1.0);
                const sc = ui.motion.effects.mix(shifted, lifted, slow).alpha(alpha);
                ui.div(c).absolute().offset(x, 0).size(sw, 26).bg(sc).end();
            }
        }
    }

    // Stops: filled stops follow the animated front, never jumping ahead of the thumb.
    for (0..n) |i| {
        const f = @as(f32, @floatFromInt(i)) / last;
        const dot = if (f <= fraction) ui.Color.hex(0xffffff).alpha(0.45) else k.muted.alpha(0.32);
        ui.div(c).absolute().offset(f * tw - 2.0, 15.0).size(4, 4).roundedFull().circular().bg(dot).end();
    }

    // Thumb: breathing accent halo on deeper effort + press elevation shadow + crisp circular handle.
    const th: f32 = 28;
    const tx = fraction * tw - th / 2;
    const ty = (34 - th) / 2;
    const live = intensity * (0.55 + 0.45 * breath);
    if (intensity > 0.001) {
        ui.div(c).absolute().offset(tx, ty).size(th, th).roundedFull().circular()
            .shadow(.{ .color = accent.alpha(0.35 * live), .y = 1, .blur = 10 }).end();
    }
    if (press > 0.001) {
        ui.div(c).absolute().offset(tx, ty).size(th, th).roundedFull().circular()
            .shadow(.{ .color = ui.Color.black.alpha(0.12 * press), .y = 2.0 * press, .blur = 8 }).end();
    }
    ui.div(c).absolute().offset(tx, ty).size(th, th).roundedFull().circular()
        .bg(ui.Color.hex(0xfffefa)).border(k.border).borderW(1).shadowSm().end();
}

fn tabs(c: *ui.Context, a: *App, k: theme.Colors, width: f32) void {
    const p = &a.view.model_picker;
    ui.key(c, "model-picker-tabs");
    // It takes the wheel itself: the chat scrolling behind the card mustn't.
    const viewport = ui.div(c).row().wFull().h(39).clip().wheel();
    defer viewport.end();
    const current = a.target().harness;
    var total: f32 = 8 + tabWidth(c, "Starred", 15) + 2;
    var selected_x: f32 = 4;
    var selected_w = tabWidth(c, "Starred", 15);
    for (a.harnesses.items) |h| {
        if (!offered(a, h.id, h.offered)) continue;
        const tw = tabWidth(c, h.name, 16);
        if (!p.starred and std.mem.eql(u8, h.id, current)) {
            selected_x = total - 4;
            selected_w = tw;
        }
        total += tw + 2;
    }
    if (p.focus) {
        if (selected_x < p.tab_offset) p.tab_offset = selected_x;
        if (selected_x + selected_w > p.tab_offset + width) p.tab_offset = selected_x + selected_w - width;
    }
    if (a.picker != .none and viewport.hovered()) {
        c.wants_wheel = true;
        const delta = if (c.input.scroll.x != 0) c.input.scroll.x else c.input.scroll.y;
        if (delta != 0) {
            p.tab_offset -= delta;
            c.changed = true;
        }
    }
    p.tab_offset = std.math.clamp(p.tab_offset, 0, @max(0, total - width));
    const track = ui.div(c).row().absolute().offset(-p.tab_offset, 0).h(39).px(4).gap(2).itemsCenter();
    defer track.end();
    if (tab(c, k, .@"star-bold", null, "Starred", p.starred) and a.picker != .none) {
        p.starred = true;
        reset(c, a);
        for (a.harnesses.items) |h| {
            if (offered(a, h.id, h.offered)) _ = models.ensureCatalog(a, h.id, false);
        }
    }
    for (a.harnesses.items) |h| {
        if (!offered(a, h.id, h.offered)) continue;
        ui.key(c, c.print("model-agent-{s}", .{h.id}));
        const mark = icons.harnessMark(h.id);
        if (tab(c, k, mark.name, mark.brand, h.name, !p.starred and std.mem.eql(u8, h.id, current)) and a.picker != .none) {
            p.starred = false;
            p.focus = true;
            reset(c, a);
            queue(c, a, h.id, null, null);
        }
    }
}

fn offered(a: *const App, id: []const u8, enabled: bool) bool {
    if (a.selected != null) return std.mem.eql(u8, id, a.target().harness);
    return enabled or std.mem.eql(u8, id, a.target().harness);
}

fn tabWidth(c: *ui.Context, label: []const u8, icon: f32) f32 {
    return 16 + icon + 5 + c.text.width(label, .{ .size = 12, .weight = .medium });
}

fn tab(c: *ui.Context, k: theme.Colors, icon: icons.Name, tint: ?ui.Color, label: []const u8, on: bool) bool {
    const tw = tabWidth(c, label, if (icon == .@"star-bold") 15 else 16);
    const b = ui.div(c).column().w(tw).h(39).itemsCenter().justifyCenter();
    defer b.end();
    const row = ui.div(c).row().h(32).wFull().px(8).gap(5).itemsCenter().rounded(8).hover(k.hover);
    const hit = row.clicked();
    {
        defer row.end();
        icons.icon(c, icon, if (icon == .@"star-bold") 15 else 16, tint orelse if (on) k.text else k.muted, 0);
        ui.text(c, label, .{ .size = 12, .weight = .medium, .color = k.text });
    }
    if (on) ui.div(c).absolute().offset(6, 37.5).size(tw - 12, 2).rounded(1).bg(k.accent).end();
    return hit;
}

fn search(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.model_picker;
    const row = ui.div(c).row().wFull().h(35).px(12).pt(1).gap(8).itemsCenter();
    defer row.end();
    icons.icon(c, .magnifer, 14, k.muted, 14);
    const f = ui.div(c).row().grow().w(0).itemsCenter();
    defer f.end();
    ui.key(c, "model-picker-search");
    const placeholder = if (a.selected == null) "Search models… · Ctrl+Tab agents" else "Search models…";
    if (a.picker == .none) {
        const query = p.query.text();
        ui.text(c, if (query.len > 0) query else placeholder, .{ .size = 14, .weight = .medium, .line_height = 22.75, .color = if (query.len > 0) k.text else k.faint });
        return;
    }
    const at = c.nodes.items.len;
    const r = ui.textField(c, &p.query, .{ .placeholder = placeholder, .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .weight = .medium, .line_height = 22.75, .caret = @import("view_composer.zig").message_caret, .caret_color = k.accent });
    const id = c.node(@intCast(at)).id;
    if (p.focus or c.focus != id) {
        c.focus = id;
        c.changed = true;
        p.focus = false;
    }
    if (r.changed) reset(c, a);
}

fn space(c: *ui.Context, height: f32) void {
    if (height > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = height } }, .none, null);
}

fn defaultsPath(a: *App, gpa: std.mem.Allocator) ?[]u8 {
    const dir = a.settings.dataDir() orelse return null;
    return std.fs.path.join(gpa, &.{ dir, "composer-defaults.json" }) catch null;
}

fn loadFavorites(a: *App) void {
    const p = &a.view.model_picker;
    if (p.loaded_favorites) return;
    p.loaded_favorites = true;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    const path = defaultsPath(a, gpa) orelse return;
    const body = std.Io.Dir.cwd().readFileAlloc(a.io, path, gpa, .limited(8 << 20)) catch return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{}) catch return;
    if (root != .object) return;
    const favorites = root.object.get("favorites") orelse return;
    if (favorites != .array) return;
    for (favorites.array.items) |f| {
        if (f != .object) continue;
        const h = f.object.get("harness") orelse continue;
        const m = f.object.get("model") orelse continue;
        if (h == .string and m == .string and !p.favorite(h.string, m.string)) p.toggleFavorite(a.gpa, h.string, m.string);
    }
}

fn saveFavorites(a: *App) void {
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    const path = defaultsPath(a, gpa) orelse return;
    const body = std.Io.Dir.cwd().readFileAlloc(a.io, path, gpa, .limited(8 << 20)) catch "{}";
    const value = std.json.Stringify.valueAlloc(gpa, a.view.model_picker.favorites.items, .{}) catch return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, gpa, value, .{}) catch return;
    const out = @import("settings.zig").merged(gpa, body, "favorites", parsed) catch return;
    const tmp = std.fmt.allocPrint(gpa, "{s}.nano-{d}.tmp", .{ path, std.Io.Clock.real.now(a.io).toNanoseconds() }) catch return;
    std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = tmp, .data = out }) catch return;
    std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, a.io) catch {};
}
