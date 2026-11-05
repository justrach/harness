//! Harness's model picker (crates/ui/src/pickers.rs): agent tabs, scoped
//! search, maker SVGs, provider groups, stars, and a pinned Reasoning tray.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const models = @import("model_picker.zig");
const App = @import("app.zig").App;

pub const menu_width: f32 = 304;

/// GPUI's menu_geometry and measure_trigger: new-chat menus prefer down
/// when 180 points fit; established chats prefer up, flipping near the top.
pub fn placement(anchor: ui.Rect, size: ui.Size, new_chat: bool, wanted: f32) struct { x: f32, y: f32, h: f32 } {
    const above = @max(0, anchor.y - 14);
    const below = @max(0, size.h - anchor.y - anchor.h - 14);
    const down = (new_chat and below >= 180) or (above < 180 and below > above);
    const h = @min(wanted, @min(640, if (down) below else above));
    const w = @min(menu_width, size.w - 16);
    return .{
        .x = std.math.clamp(anchor.x + anchor.w - w, 8, @max(8, size.w - w - 8)),
        .y = if (down) anchor.y + anchor.h + 6 else @max(8, anchor.y - h - 6),
        .h = h,
    };
}

pub fn opened(a: *App) void {
    const p = &a.view.model_picker;
    loadFavorites(a);
    p.query.clear();
    p.focus = true;
    p.reasoning_open = false;
    p.starred = a.selected == null and p.favorites.items.len > 0;
    p.reveal = true;
    p.height = if (a.levelsOf(a.target().model).len > 0) 337 else 298;
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
    p.reasoning_open = false;
    if (p.scroll_id != 0) c.scroll.put(c.gpa, p.scroll_id, 0) catch {};
    c.changed = true;
}

fn firstModel(rows: []const models.Row) usize {
    for (rows, 0..) |r, i| if (r.header == null) return i;
    return 0;
}

pub fn keys(c: *ui.Context, a: *App) void {
    const p = &a.view.model_picker;
    const S = ui.Shortcut;
    if (c.shortcut(.{ .key = S.escape })) {
        if (p.reasoning_open) p.reasoning_open = false else {
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
        const index = for (agents.items, 0..) |id, i| {
            if (std.mem.eql(u8, id, a.target().harness)) break i;
        } else 0;
        const n = agents.items.len;
        const to = if (prev_agent) (index + n - 1) % n else (index + 1) % n;
        p.starred = false;
        reset(c, a);
        p.focus = true;
        queue(c, a, agents.items[to], null, null);
        return;
    }
    if (c.shortcut(.{ .key = S.right })) {
        p.reasoning_open = a.levelsOf(a.target().model).len > 0;
        return;
    }
    if (c.shortcut(.{ .key = S.left }) and p.reasoning_open) {
        p.reasoning_open = false;
        return;
    }
    const down = c.shortcut(.{ .key = S.down });
    const up = c.shortcut(.{ .key = S.up });
    const enter = c.shortcut(.{ .key = S.enter });
    if (p.reasoning_open) {
        if (!down and !up and !enter) return;
        const levels = a.levelsOf(a.target().model);
        if (levels.len == 0) return;
        if (enter) return queue(c, a, null, null, levels[@min(p.active, levels.len - 1)]);
        p.active = if (down) (p.active + 1) % levels.len else (p.active + levels.len - 1) % levels.len;
        c.changed = true;
        return;
    }
    var picked_slot: ?usize = null;
    for (0..9) |slot| {
        if (c.shortcut(.{ .key = @as(u21, @intCast('1' + slot)), .cmd = true })) picked_slot = slot;
    }
    if (!down and !up and !enter and picked_slot == null) return;
    const list = models.rows(a, c.alloc()) catch return;
    if (picked_slot) |slot| {
        var n: usize = 0;
        for (list) |r| if (r.header == null) {
            if (n == slot) return queue(c, a, r.harness, r.model.id, null);
            n += 1;
        };
        return;
    }
    if (list.len == 0) return;
    p.active = @min(p.active, list.len - 1);
    if (enter) {
        const r = list[p.active];
        if (r.header == null) queue(c, a, r.harness, r.model.id, null);
        return;
    }
    for (0..list.len) |_| {
        p.active = if (down) (p.active + 1) % list.len else (p.active + list.len - 1) % list.len;
        if (list[p.active].header == null) break;
    }
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
            return;
        }
    }
    const anchor = p.anchor orelse return;
    const levels = a.levelsOf(a.target().model);
    const w = @min(menu_width, c.size.w - 16);
    const geometry = placement(anchor, c.size, a.selected == null, p.height);
    const h = geometry.h;
    const tray_h: f32 = if (levels.len > 0) @min(39, h - 112) else 0;
    const list_h = @max(30, h - 82 - tray_h);
    const x = geometry.x;
    const y = geometry.y;
    if (open) {
        ui.key(c, "model-picker-backdrop");
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer back.end();
        if (back.clicked()) {
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
    tabs(c, a, k, w - 2);
    line(c, k);
    search(c, a, k);
    line(c, k);
    const list = models.rows(a, c.alloc()) catch return;
    if (list.len > 0 and (p.active >= list.len or list[p.active].header != null)) p.active = firstModel(list);
    {
        var style: ui.Style = .{ .width = .fill, .height = .{ .px = list_h }, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 }, .background = k.ink(0.02) };
        if (@hasField(ui.Style, "scrollbar")) style.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
        ui.key(c, "model-picker-list");
        const at = c.nodes.items.len;
        ui.scroll(c, style);
        defer ui.end(c);
        const id = c.node(@intCast(at)).id;
        p.scroll_id = id;
        const row_h: f32 = if (p.starred) 49 else 34;
        var offset = c.scroll.get(id) orelse 0;
        if (p.reveal) {
            const top = @as(f32, @floatFromInt(p.active)) * row_h;
            if (top < offset) offset = top else if (top + row_h > offset + list_h - 8) offset = top + row_h - list_h + 8;
            c.scroll.put(c.gpa, id, @max(0, offset)) catch {};
            p.reveal = false;
        }
        offset = std.math.clamp(offset, 0, @max(0, @as(f32, @floatFromInt(list.len)) * row_h + 8 - list_h));
        const first = @min(list.len, @as(usize, @intFromFloat(@floor(@max(0, offset - row_h) / row_h))));
        const last = @min(list.len, first + @as(usize, @intFromFloat(@ceil(list_h / row_h))) + 3);
        space(c, @as(f32, @floatFromInt(first)) * row_h);
        var slot: usize = 0;
        for (list[0..first]) |r| if (r.header == null) {
            slot += 1;
        };
        for (list[first..last], first..) |r, i| {
            ui.key(c, c.print("model-result-{s}-{s}-{d}", .{ r.harness, r.model.id, i }));
            modelRow(c, a, k, r, i, slot, row_h, w - 10);
            if (r.header == null) slot += 1;
        }
        space(c, @as(f32, @floatFromInt(list.len - last)) * row_h);
        if (list.len == 0) {
            const empty = ui.div(c).column().wFull().py(24).px(8).itemsCenter();
            defer empty.end();
            const loading = if (p.catalogs.get(a.target().harness)) |cat| cat.loading else false;
            ui.text(c, if (p.starred) "No starred models yet — hit a row’s star" else if (loading) "Loading models…" else "No models found", .{ .size = 12, .color = k.muted });
        }
    }
    if (tray_h > 0) {
        line(c, k);
        const foot = ui.div(c).row().wFull().h(tray_h - 1).px(12).gap(10).itemsCenter().hover(k.hover);
        defer foot.end();
        if (foot.clicked() and open) {
            p.reasoning_open = !p.reasoning_open;
            p.active = 0;
            c.changed = true;
        }
        ui.text(c, "Reasoning", .{ .size = 13, .weight = .medium, .color = k.text.alpha(0.9) });
        ui.spacer(c);
        if (a.target().reasoning) |level| ui.text(c, rules.reasoningLabel(level), .{ .size = 13, .weight = .medium, .color = k.muted });
        icons.icon(c, .@"alt-arrow-right", 12, k.muted, 12);
    }
    if (p.reasoning_open and levels.len > 0) {
        const sw: f32 = 172;
        const sx = if (x + w + sw + 4 <= c.size.w - 8) x + w + 4 else @max(8, x - sw - 4);
        const sh = @as(f32, @floatFromInt(levels.len)) * 30 + 8;
        const sy = std.math.clamp(y + h - tray_h, 8, @max(8, c.size.h - sh - 8));
        const sub = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(sx, sy).motion(exit).w(sw).column().p(4).layer(6).bg(k.composer).border(k.border).borderW(1).rounded(10)));
        defer sub.end();
        for (levels, 0..) |level, i| {
            ui.key(c, c.print("model-reasoning-{s}", .{level}));
            const on = if (a.target().reasoning) |v| std.mem.eql(u8, v, level) else false;
            const r = ui.div(c).row().wFull().h(30).px(8).itemsCenter().rounded(7).hover(k.hover);
            defer r.end();
            if (r.clicked()) queue(c, a, null, null, level);
            ui.text(c, rules.reasoningLabel(level), .{ .size = 12, .color = if (i == p.active) k.text else k.muted });
            ui.spacer(c);
            if (on) icons.icon(c, .check, 12, k.accent, 12);
        }
    }
}

fn tabs(c: *ui.Context, a: *App, k: theme.Colors, width: f32) void {
    const p = &a.view.model_picker;
    ui.key(c, "model-picker-tabs");
    const viewport = ui.div(c).row().wFull().h(39).clip();
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
    const row = ui.div(c).row().wFull().h(39).px(10).gap(8).itemsCenter();
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
    const r = ui.textField(c, &p.query, .{ .placeholder = placeholder, .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .weight = .medium, .line_height = 22.75 });
    const id = c.node(@intCast(at)).id;
    if (p.focus or c.focus != id) {
        c.focus = id;
        c.changed = true;
        p.focus = false;
    }
    if (r.changed) reset(c, a);
}

fn modelRow(c: *ui.Context, a: *App, k: theme.Colors, r: models.Row, index: usize, slot: usize, height: f32, inner: f32) void {
    const p = &a.view.model_picker;
    const wrap = ui.div(c).column().wFull().h(height).pb(2);
    defer wrap.end();
    if (r.header) |title| {
        const head = ui.div(c).row().wFull().h(height - 2).px(8).pb(6).itemsEnd();
        defer head.end();
        kit.ellipsisText(c, title, .{ .size = 11, .weight = .semibold, .color = k.muted }, inner - 16);
        return;
    }
    const current = a.target().model orelse if (a.models.items.len > 0) a.models.items[0].id else "";
    const selected = std.mem.eql(u8, r.harness, a.target().harness) and std.mem.eql(u8, current, r.model.id);
    var row = ui.div(c).row().wFull().h(height - 2).px(8).gap(10).itemsCenter().rounded(8);
    if (selected) row = row.bg(k.selected).border(k.ink(if (a.dark orelse @import("nanoui").isDark()) 0.09 else 0.07)).borderW(1) else if (index == p.active) row = row.bg(k.ink(0.05));
    defer row.end();
    const pick = row.clicked();
    if (a.picker != .none and row.hovered()) p.active = index;
    {
        const body = ui.div(c).column().grow().w(0).gap(2).clip();
        defer body.end();
        {
            const title = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
            defer title.end();
            const makers = std.mem.eql(u8, r.harness, "graff") or std.mem.eql(u8, r.harness, "opencode");
            if (!p.starred and makers) {
                if (models.makerIcon(r.model)) |icon| icons.icon(c, icon, 14, k.muted, 14) else _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 } }, .none, null);
            }
            const hint = slotHint(c, slot);
            const hint_w = if (slot < 9) 10 + @floor(c.text.width(hint, .{ .size = 10, .mono = true }) + 1) + 10 else 0;
            const available = inner - 16 - 22 - 10 - hint_w - (if (!p.starred and makers) @as(f32, 20) else 0);
            const label_w = @min(c.text.width(r.model.label, .{ .size = 12.5, .weight = .medium }), available);
            kit.ellipsisText(c, r.model.label, .{ .size = 12.5, .weight = .medium, .color = k.text }, label_w);
            if (!p.starred) if (r.model.description) |d| kit.ellipsisText(c, d, .{ .size = 11, .weight = .medium, .color = k.muted }, @max(0, available - label_w - 6));
        }
        if (p.starred) {
            const sub = ui.div(c).row().wFull().gap(6).itemsCenter();
            defer sub.end();
            const mark = icons.harnessMark(r.harness);
            icons.icon(c, mark.name, 11, mark.brand orelse k.muted, 11);
            kit.ellipsisText(c, a.harnessName(r.harness), .{ .size = 11, .color = k.muted }, inner - 65);
        }
    }
    if (slot < 9) kit.kbdHint(c, k, slotHint(c, slot));
    const starred = p.favorite(r.harness, r.model.id);
    ui.key(c, "model-star");
    const star = ui.div(c).row().size(22, 22).center().rounded(6).hover(k.hover);
    var toggled = false;
    {
        defer star.end();
        toggled = star.clicked();
        icons.icon(c, if (starred) .@"star-bold" else .star, 13, if (starred) k.accent else k.muted, 13);
    }
    if (toggled and a.picker != .none) {
        p.toggleFavorite(a.gpa, r.harness, r.model.id);
        saveFavorites(a);
        c.changed = true;
    } else if (pick) queue(c, a, r.harness, r.model.id, null);
}

fn slotHint(c: *ui.Context, slot: usize) []const u8 {
    return c.print(if (@import("builtin").os.tag == .macos) "⌘{d}" else "Ctrl+{d}", .{slot + 1});
}

fn line(c: *ui.Context, k: theme.Colors) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border.alpha(0.6) }, .none, null);
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
