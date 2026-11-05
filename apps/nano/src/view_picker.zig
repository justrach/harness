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
const stage_height: f32 = 330;

/// GPUI's menu_geometry and measure_trigger: new-chat menus prefer down
/// when 180 points fit; established chats prefer up, flipping near the top.
pub fn placement(anchor: ui.Rect, size: ui.Size, new_chat: bool, wanted: f32) struct { x: f32, y: f32, h: f32 } {
    const above = @max(0, anchor.y - 14);
    const below = @max(0, size.h - anchor.y - anchor.h - 14);
    const down = (new_chat and below >= 180) or (above < 180 and below > above);
    const h = @min(wanted, @min(640, if (down) below else above));
    const w = @min(menu_width, size.w - 16);
    return .{
        // From the chip's leading edge: it sits at the footer's left now
        // (pickers.rs `attach_overlay`, no longer `attach_overlay_end`).
        .x = std.math.clamp(anchor.x, 8, @max(8, size.w - w - 8)),
        .y = if (down) anchor.y + anchor.h + 6 else @max(8, anchor.y - h - 6),
        .h = h,
    };
}

pub fn opened(a: *App) void {
    const p = &a.view.model_picker;
    loadFavorites(a);
    p.query.clear();
    p.focus = true;
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
    if (pick.model) |id| a.pickModel(id);
    if (pick.reasoning) |level| a.pickReasoning(level);
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
    p.detail = null;
    p.hover_target = null;
    p.height = stage_height;
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
        p.stage.?.error_text = "Availability changed. Go back and select the model again.";
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
            p.stage.?.level = n;
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
    const exit = if (open) ui.motion.Frame{} else ui.motion.menuOut(c, ui.motion.catalog.menu_out.progress(@floatCast((c.time - p.closing_since.?) / ui.motion.catalog.menu_out.total())));
    ui.key(c, "model-picker-card");
    const panel = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).motion(exit).w(w).h(h).layer(5).column().p(1)
        .bg(k.composer).border(k.border).borderW(1).rounded(12).clip()));
    defer panel.end();
    if (p.stage != null) return page(c, a, k, w - 2, open);
    tabs(c, a, k, w - 2);
    // The full-bleed hairline over the search (`crate::theme::hairline(0.08)`).
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.ink(0.08) }, .none, null);
    search(c, a, k);
    modelList(c, a, k, w - 2, h - 2 - 39 - 1 - 35, open, exit);
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
        // A section's heading: the route's mark, its name.
        const head = ui.div(c).row().wFull().h(34).px(10).pt(1).gap(7).itemsCenter();
        defer head.end();
        icons.icon(c, models.providerInfo(models.route(r.model)).icon, 14, k.text, 14);
        kit.ellipsisText(c, title, .{ .size = 11, .weight = .semibold, .color = k.muted }, inner - 41);
        return .{};
    }
    const current = a.target().model orelse if (a.models.items.len > 0) a.models.items[0].id else "";
    const selected = std.mem.eql(u8, r.harness, a.target().harness) and std.mem.eql(u8, current, r.model.id);
    // `menu_row_nav`: the selected row and the keyboard's lit, a hover wash.
    var row = ui.div(c).row().wFull().h(34).px(8).gap(10).itemsCenter().rounded(8);
    row = if (selected or at == p.active or p.detail == at) row.bg(k.selected) else row.hover(k.selected);
    defer row.end();
    const hot = row.hovered();
    const pick = row.clicked();
    if (open and hot) p.active = at;
    if (!grouped) icons.icon(c, models.modelIcon(r.model), 15, k.text, 15);
    const room = inner - 16 - 24 - 10 - (if (selected) @as(f32, 22) else 0) - (if (!grouped) @as(f32, 25) else 0);
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.ellipsisText(c, r.model.label, .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = k.text }, room);
    }
    if (selected) icons.icon(c, .check, 12, k.muted, 12);
    const starred = p.favorite(r.harness, r.model.id);
    ui.key(c, "model-star");
    const star = ui.div(c).row().size(24, 24).center().rounded(5).hover(k.raised);
    var toggled = false;
    {
        defer star.end();
        toggled = star.clicked();
        icons.icon(c, if (starred) .@"star-bold" else .star, 12, k.muted, 12);
    }
    if (toggled and open) {
        p.toggleFavorite(a.gpa, r.harness, r.model.id);
        saveFavorites(a);
        c.changed = true;
    } else if (pick and open) stage(c, a, r);
    return .{ .hovered = hot, .rect = c.rects.get(c.node(row.index).id) };
}

/// The detail card beside its row (`preview_detail`, `nested_menu`): 10
/// right of the row, or left when the window hasn't room.
fn detail(c: *ui.Context, a: *App, k: theme.Colors, r: models.Row, row: ui.Rect, exit: ui.motion.Frame) void {
    const p = &a.view.model_picker;
    const m = r.model;
    const right = row.x + row.w + 10;
    const left = c.size.w - right < detail_width + 8 and row.x - 10 >= detail_width + 8;
    const x = if (left) row.x - 10 - detail_width else @min(right, @max(8, c.size.w - detail_width - 8));
    const est: f32 = if (p.detail_rect) |d| d.h else 160;
    const y = std.math.clamp(row.y, 8, @max(8, c.size.h - est - 8));
    ui.key(c, "model-detail-card");
    const card = kit.shadowLg(ui.div(c).fixed().offset(x, y).motion(exit).w(detail_width).layer(7).column().p(16 + 1).gap(12)
        .bg(k.composer).border(k.border).borderW(1).rounded(12));
    defer card.end();
    if (c.rects.get(c.node(card.index).id)) |rect| p.detail_rect = rect;
    const inner = detail_width - 34;
    const st: ui.TextStyle = .{ .size = 11, .line_height = 11 * 1.618, .weight = .medium, .color = k.text };
    {
        const head = ui.div(c).row().gap(8).itemsCenter();
        defer head.end();
        icons.icon(c, models.modelIcon(m), 20, k.text, 20);
        kit.ellipsisText(c, m.label, st, inner - 28);
    }
    var muted = st;
    muted.color = k.muted;
    ui.text(c, c.print("via {s}", .{models.providerInfo(models.route(m)).name}), muted);
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
        ui.text(c, value, muted);
    };
    if (m.description) |d| {
        const desc = ui.div(c).column().wFull().gap(12);
        defer desc.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        var wrap = muted;
        wrap.wrap = true;
        ui.text(c, d, wrap);
    }
}

/// The model's page (`preview_reasoning`): back to the models, the model
/// and its route, its reasoning on a slider in the maker's colour, and
/// "Use model".
fn page(c: *ui.Context, a: *App, k: theme.Colors, w: f32, open: bool) void {
    const p = &a.view.model_picker;
    const st = p.stage.?;
    ui.key(c, "model-page");
    // The card wants its content's own height (`h_auto`), capped by the
    // room there is (`max_h`): the controls are measured as laid out, not
    // as the card stretched them, so a short window scrolls them instead.
    var natural: f32 = 2;
    var measured: u8 = 0;
    const content = ui.div(c).column().wFull().grow().h(0);
    defer {
        content.end();
        if (measured == 2 and @abs(natural - p.height) > 0.5) {
            p.height = natural;
            c.changed = true;
        }
    }
    // A model the catalog dropped keeps its page, to say so on commit.
    const m: workspace.Model = staged(a) orelse .{ .id = st.model, .label = st.model };
    const levels = levelsOf(a, st.harness, m);
    const is_binary = models.binary(levels);
    const accent: ui.Color = if (models.brandHex(m, st.harness, k.dark)) |hx| ui.Color.hex(hx) else k.text;
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
            ui.key(c, "model-page-back");
            const b = ui.div(c).row().gap(6).itemsCenter();
            defer b.end();
            if (b.clicked() and open) back(c, a);
            icons.icon(c, .@"arrow-left", 14, k.text, 14);
            ui.text(c, "Models", .{ .size = 12, .line_height = 12 * 1.618, .color = if (b.hovered()) k.text else k.text.alpha(0.9) });
        }
        {
            const head = ui.div(c).row().gap(12).itemsCenter();
            defer head.end();
            icons.icon(c, models.modelIcon(m), 20, k.text, 20);
            const words = ui.div(c).column().gap(4);
            defer words.end();
            // GPUI's own line height, φ, everywhere on this page.
            kit.ellipsisText(c, m.label, .{ .size = 16, .line_height = 16 * 1.618, .weight = .semibold, .color = k.text }, w - 32 - 32);
            ui.text(c, c.print("via {s}", .{models.providerInfo(models.route(m)).name}), .{ .size = 11, .line_height = 11 * 1.618, .color = k.muted });
        }
        {
            const r = ui.div(c).row().wFull().itemsCenter();
            defer r.end();
            const st13: ui.TextStyle = .{ .size = 13, .line_height = 13 * 1.618, .color = k.text };
            ui.text(c, if (is_binary) "Thinking" else "Reasoning", st13);
            ui.spacer(c);
            const label = if (st.level) |i| (if (i < levels.len) models.levelLabel(levels[i], is_binary) else "Model default") else "Model default";
            ui.text(c, label, st13);
        }
        if (levels.len > 1) {
            slider(c, a, k, accent, levels.len, w - 32 - 28, open);
            const ends = ui.div(c).row().wFull();
            defer ends.end();
            ui.text(c, if (is_binary) "Off" else "Faster", .{ .size = 11, .line_height = 11 * 1.618, .color = k.muted });
            ui.spacer(c);
            ui.text(c, if (is_binary) "On" else "Deeper", .{ .size = 11, .line_height = 11 * 1.618, .color = k.muted });
        } else {
            ui.text(c, "This model has no adjustable reasoning level.", .{ .size = 12, .line_height = 12 * 1.618, .wrap = true, .color = k.muted });
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
    var b = ui.div(c).row().wFull().px(12).py(6).center().rounded(8).bg(k.solid);
    if (b.hovered()) b = b.opacity(0.9);
    defer b.end();
    if (b.clicked() and open) commit(c, a);
    ui.text(c, "Use model", .{ .size = 13, .line_height = 13 * 1.618, .weight = .medium, .color = k.on_solid });
}

/// The reasoning slider: a 24-point pill track, filled to the level in
/// the model's colour, a dot per level, a white thumb; a press or a drag
/// anywhere on it picks the nearest level, and the thumb settles in 150 ms.
fn slider(c: *ui.Context, a: *App, k: theme.Colors, accent: ui.Color, n: usize, tw: f32, open: bool) void {
    const p = &a.view.model_picker;
    const level = p.stage.?.level orelse 0;
    const last: f32 = @floatFromInt(n - 1);
    const target = @as(f32, @floatFromInt(level)) / last;
    const percent = if (p.dragging) target else ui.motion.number(c, "model-slider", target, .{ .tween = .{ .duration = 0.15, .ease = .{ .bezier = .{ 0.16, 1, 0.3, 1 } } } });
    const pad = ui.div(c).row().wFull().px(14);
    defer pad.end();
    ui.key(c, "model-slider-track");
    const track = ui.div(c).w(tw).h(34);
    defer track.end();
    if (c.rects.get(c.node(track.index).id)) |r| p.track = r;
    if (open and track.hovered() and c.input.pressed) p.dragging = true;
    if (p.dragging) {
        if (p.track) |r| {
            const at = std.math.clamp((c.input.mouse.x - r.x) / @max(1, r.w), 0, 1);
            const next: usize = @intFromFloat(@round(at * last));
            if (next != level) {
                p.stage.?.level = next;
                c.changed = true;
            }
        }
        if (!c.input.down or c.input.released) {
            p.dragging = false;
            c.changed = true;
        }
    }
    ui.div(c).absolute().offset(-14, 5).size(tw + 28, 24).rounded(12).bg(k.raised).end();
    ui.div(c).absolute().offset(-14, 5).size(percent * tw + 28, 24).rounded(12).bg(accent).end();
    for (0..n) |i| {
        const f = @as(f32, @floatFromInt(i)) / last;
        const dot = if (f <= percent + 0.001) k.on_solid.alpha(0.55) else k.muted.alpha(0.4);
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = 4 }, .height = .{ .px = 4 }, .radius = 2, .background = dot, .offset = .{ .x = f * tw - 2, .y = 15 } }, .none, null);
    }
    const th: f32 = if (p.dragging) 30 else 28;
    ui.div(c).absolute().offset(percent * tw - th / 2, (34 - th) / 2).size(th, th).roundedFull().bg(ui.Color.hex(0xfffefa)).border(k.border).borderW(1).shadowSm().end();
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
