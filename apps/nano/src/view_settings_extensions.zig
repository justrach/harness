//! Settings › Extensions: bounded declarative panels from trusted native
//! plugins (`docs/native-extensions.md`, `extension_panel.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Allocator = std.mem.Allocator;
const json = std.json;
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const agents = @import("view_settings_agents.zig");
const ext = @import("extension_panel.zig");

const poll_interval_s: f64 = 5.0;
const row_gap: f32 = 8;

pub const State = struct {
    phase: Phase = .idle,
    refreshing: bool = false,
    arena: ?std.heap.ArenaAllocator = null,
    panels: []const json.Value = &.{},
    target: ?[]const u8 = null,
    failure: []const u8 = "",
    notice: []const u8 = "",
    busy_action: []const u8 = "",
    list_call: ?u64 = null,
    action_call: ?u64 = null,
    next_poll: ?f64 = null,

    pub const Phase = enum { idle, loading, failed, ready };

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.arena) |*ar| ar.deinit();
        if (s.target) |v| gpa.free(v);
        clearStr(gpa, &s.failure);
        clearStr(gpa, &s.notice);
        clearStr(gpa, &s.busy_action);
        s.* = .{};
    }

    pub fn replace(s: *State, gpa: Allocator, value: json.Value) !void {
        try ext.validate(value);
        var next = std.heap.ArenaAllocator.init(gpa);
        errdefer next.deinit();
        const cloned = try cloneValue(next.allocator(), value);
        const arr = if (cloned == .object) (cloned.object.get("panels") orelse .null) else .null;
        const items: []const json.Value = if (arr == .array) arr.array.items else &.{};
        if (s.arena) |*old| old.deinit();
        s.arena = next;
        s.panels = items;
        s.phase = .ready;
        s.refreshing = false;
        clearStr(gpa, &s.failure);
    }
};

fn clearStr(gpa: Allocator, slot: *[]const u8) void {
    if (slot.*.len > 0) gpa.free(slot.*);
    slot.* = "";
}

fn setStr(gpa: Allocator, slot: *[]const u8, value: []const u8) void {
    if (value.len == 0) return clearStr(gpa, slot);
    const copy = gpa.dupe(u8, value) catch return;
    clearStr(gpa, slot);
    slot.* = copy;
}

fn setOptStr(gpa: Allocator, slot: *?[]const u8, value: ?[]const u8) void {
    const next = if (value) |v| (gpa.dupe(u8, v) catch return) else null;
    if (slot.*) |old| gpa.free(old);
    slot.* = next;
}

fn cloneValue(alloc: Allocator, v: json.Value) Allocator.Error!json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try alloc.dupe(u8, s) },
        .string => |s| .{ .string = try alloc.dupe(u8, s) },
        .array => |arr| blk: {
            var out = json.Array.init(alloc);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try cloneValue(alloc, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: json.ObjectMap = .empty;
            try out.ensureTotalCapacity(alloc, obj.count());
            var it = obj.iterator();
            while (it.next()) |e| {
                out.putAssumeCapacityNoClobber(try alloc.dupe(u8, e.key_ptr.*), try cloneValue(alloc, e.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

fn isLocalSpace(a: *const App, sp: @import("workspace.zig").Space) bool {
    const host = a.device_id orelse return true;
    const dev = sp.device_id orelse return true;
    return std.mem.eql(u8, host, dev);
}

pub fn targetSpaceId(a: *const App) ?[]const u8 {
    if (a.space) |sp| {
        if (a.spaces.items.len == 0) return sp;
        if (a.findSpace(sp)) |found| if (isLocalSpace(a, found)) return sp;
    }
    if (a.selected) |cid| if (a.findChat(cid)) |chat| if (chat.space_id) |sp| {
        if (a.findSpace(sp)) |found| if (isLocalSpace(a, found)) return sp;
    };
    for (a.spaces.items) |sp| if (isLocalSpace(a, sp)) return sp.id;
    return a.space orelse if (a.spaces.items.len > 0) a.spaces.items[0].id else null;
}

pub fn load(a: *App) void {
    const s = &a.extensions;
    const space_id = targetSpaceId(a) orelse {
        s.refreshing = false;
        s.phase = .failed;
        setOptStr(a.gpa, &s.target, null);
        setStr(a.gpa, &s.failure, "Open or add a local project folder to load native extensions.");
        a.redraw();
        return;
    };
    setOptStr(a.gpa, &s.target, space_id);
    if (s.phase == .idle or s.panels.len == 0) {
        s.phase = .loading;
        s.refreshing = false;
    } else {
        s.refreshing = true;
    }
    s.list_call = null;
    if (a.engine.call("ListNativeExtensions", .{ .spaceId = space_id }, .of(App, a, onList))) |id| {
        s.list_call = id;
    }
    a.redraw();
}

fn matchCall(slot: *?u64, id: u64) bool {
    if (slot.*) |expected| {
        if (id != expected) return false;
        slot.* = null;
        return true;
    }
    return id == 0;
}

fn onList(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.extensions;
    if (!matchCall(&s.list_call, id)) return;
    s.refreshing = false;
    switch (r) {
        .ok => |val| s.replace(a.gpa, val) catch |err| {
            const msg = if (err == error.InvalidExtensionPanel)
                "Extension panel payload violated layout schema limits."
            else
                "Out of memory while reading extension panel payload.";
            if (s.panels.len == 0) {
                s.phase = .failed;
                setStr(a.gpa, &s.failure, msg);
            } else {
                setStr(a.gpa, &s.notice, msg);
            }
        },
        .err => |msg| {
            if (s.panels.len == 0) {
                s.phase = .failed;
                setStr(a.gpa, &s.failure, msg);
            } else {
                setStr(a.gpa, &s.notice, msg);
            }
        },
        else => return,
    }
    a.redraw();
}

fn invoke(a: *App, plugin: []const u8, action: []const u8) void {
    const s = &a.extensions;
    if (s.busy_action.len > 0) return;
    const space_id = targetSpaceId(a) orelse return;
    var key_buf: [160]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ plugin, action }) catch action;
    setStr(a.gpa, &s.busy_action, key);
    clearStr(a.gpa, &s.notice);
    s.action_call = null;
    if (a.engine.call("InvokeNativeExtension", .{
        .spaceId = space_id,
        .plugin = plugin,
        .action = action,
    }, .of(App, a, onAction))) |id| {
        s.action_call = id;
    }
    a.redraw();
}

fn onAction(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.extensions;
    if (!matchCall(&s.action_call, id)) return;
    clearStr(a.gpa, &s.busy_action);
    switch (r) {
        .ok => {
            s.next_poll = null;
            load(a);
            return;
        },
        .err => |msg| setStr(a.gpa, &s.notice, msg),
        else => return,
    }
    a.redraw();
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |x| return if (b) |y| std.mem.eql(u8, x, y) else false;
    return b == null;
}

fn tickPoll(c: *ui.Context, a: *App) void {
    const s = &a.extensions;
    if (s.phase == .idle or (s.target != null and !optEql(s.target, targetSpaceId(a)))) {
        s.next_poll = c.time + poll_interval_s;
        load(a);
    }
    if (a.offscreen or a.engine.scene != null) return;
    if (s.next_poll == null) s.next_poll = c.time + poll_interval_s;
    const due = s.next_poll.?;
    if (c.time >= due) {
        if (!s.refreshing and s.list_call == null and s.action_call == null) {
            s.next_poll = c.time + poll_interval_s;
            load(a);
        } else {
            c.frameIn(0.25);
        }
    } else {
        c.frameIn(@floatCast(@max(due - c.time, 0.05)));
    }
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.extensions;
    tickPoll(c, a);

    const avail_w = @max(set.inner_w - 2 - 40, 160);
    set.header(c, k, "Extensions", if (s.phase == .ready) s.panels.len else null);
    set.subtitle(c, k, "Bounded status panels from trusted plugins in .harness/settings.json.", false);

    switch (s.phase) {
        .idle, .loading => {
            const cd = set.card(c, k);
            defer cd.end();
            const in = ui.div(c).column().wFull().p(16);
            defer in.end();
            skeleton(c, k, 3);
        },
        .failed => {
            _ = agents.errorStrip(c, k, s.failure, set.inner_w);
            set.space(c, 8);
            const r = ui.div(c).row();
            defer r.end();
            if (set.ghost(c, k, "Retry")) load(a);
        },
        .ready => {
            if (s.notice.len > 0) _ = agents.errorStrip(c, k, s.notice, set.inner_w);
            if (s.panels.len == 0) {
                const cd = set.card(c, k);
                defer cd.end();
                const in = ui.div(c).column().w(avail_w + 40).px(20).py(16).gap(6);
                defer in.end();
                ui.text(c, "No trusted runtime plugins enabled", set.st(c, 13.5, .{ .weight = .medium, .color = k.text }));
                ui.text(c, "Add a trusted entry under runtime_plugins in .harness/settings.json for this project or your home configuration.", set.st(c, 12.5, .{ .wrap = true, .color = k.muted }));
                const bar = ui.div(c).row().pt(4);
                defer bar.end();
                if (actionButton(c, k, "Refresh", false, s.refreshing)) load(a);
                return;
            }
            for (s.panels, 0..) |panel, ix| {
                ui.key(c, c.print("ext-panel-{d}", .{ix}));
                if (ix > 0) set.space(c, 16);
                renderPanel(c, a, k, panel, avail_w);
            }
        },
    }
}

fn renderPanel(c: *ui.Context, a: *App, k: theme.Colors, panel: json.Value, avail_w: f32) void {
    const s = &a.extensions;
    const plugin = ext.str(panel, "plugin");
    const title = ext.str(panel, "title");
    const cd = set.card(c, k);
    defer cd.end();
    const in = ui.div(c).column().w(avail_w + 40).px(20).py(14).gap(9);
    defer in.end();
    {
        const hdr = ui.div(c).row().w(avail_w).justifyBetween().itemsCenter().gap(10);
        defer hdr.end();
        const badge_w = @min(2 * 9 + c.text.width(plugin, .{ .size = 11, .mono = true }) + 4, avail_w * 0.45);
        const title_w = @max(avail_w - badge_w - 10, 80);
        {
            const tb = ui.div(c).row().w(title_w).itemsCenter().gap(8);
            defer tb.end();
            kit.ellipsisText(c, title, set.st(c, 14, .{ .weight = .medium, .color = k.text }), title_w);
        }
        {
            const b = ui.div(c).row().maxW(badge_w).px(9).py(2).roundedFull().border(k.border).borderW(1).bg(k.ink(0.03));
            defer b.end();
            kit.ellipsisText(c, plugin, set.st(c, 11, .{ .mono = true, .color = k.muted }), @max(badge_w - 18, 20));
        }
    }
    _ = c.leaf(.{ .width = .{ .px = avail_w }, .height = .{ .px = 1 }, .background = k.ink(0.08) }, .none, null);
    const root = if (panel == .object) (panel.object.get("root") orelse .null) else .null;
    renderNode(c, a, k, s, plugin, root, avail_w, 0);
}

fn renderNode(c: *ui.Context, a: *App, k: theme.Colors, s: *State, plugin: []const u8, node: json.Value, w: f32, depth: usize) void {
    if (depth >= ext.max_depth or node != .object) return;
    const kind = ext.str(node, "kind");
    if (std.mem.eql(u8, kind, "column")) {
        const kids = childrenOf(node);
        const col = ui.div(c).column().w(w).gap(7);
        defer col.end();
        for (kids, 0..) |child, ix| {
            ui.key(c, c.print("col-{d}", .{ix}));
            renderNode(c, a, k, s, plugin, child, w, depth + 1);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "row")) {
        const kids = childrenOf(node);
        if (kids.len == 0) return;
        if (allKind(kids, "stat")) return renderStatGrid(c, k, kids, w);
        if (allKind(kids, "button")) return renderButtonRow(c, a, k, s, plugin, kids, w);
        renderMixedRow(c, a, k, s, plugin, kids, w, depth + 1);
        return;
    }
    if (std.mem.eql(u8, kind, "text")) {
        const txt = ext.str(node, "text");
        if (txt.len == 0) return;
        const box = ui.div(c).column().w(w);
        defer box.end();
        const col = statusColor(k, txt) orelse k.muted;
        ui.text(c, txt, set.st(c, 12.5, .{ .wrap = true, .color = col }));
        return;
    }
    if (std.mem.eql(u8, kind, "stat")) {
        const label = ext.str(node, "label");
        const value = ext.str(node, "value");
        const row = ui.div(c).row().w(w).justifyBetween().itemsCenter().gap(10).py(1);
        defer row.end();
        const dot_col = if (hasStatusCue(label, value)) statusColor(k, value) else null;
        const need_label = (if (dot_col != null) @as(f32, 14) else 0) + c.text.width(label, .{ .size = 12.5 }) + 4;
        const label_w = @min(@max(need_label, 44), @max(w * 0.56, 44));
        const value_w = @max(w - label_w - 10, 60);
        {
            const lb = ui.div(c).row().w(label_w).itemsCenter().gap(7);
            defer lb.end();
            if (dot_col) |dc| kit.dot(c, 7, dc);
            kit.ellipsisText(c, label, set.st(c, 12.5, .{ .color = k.muted }), if (dot_col != null) @max(label_w - 14, 40) else label_w);
        }
        {
            const vb = ui.div(c).row().w(value_w).justifyEnd().itemsCenter();
            defer vb.end();
            const vc = dot_col orelse statusColor(k, value) orelse k.text;
            kit.ellipsisText(c, value, set.st(c, 12.5, .{ .mono = looksMono(value), .weight = if (dot_col != null) .medium else .regular, .color = vc }), value_w);
        }
        return;
    }
    if (std.mem.eql(u8, kind, "button")) {
        const label = ext.str(node, "label");
        const action = ext.str(node, "action");
        const disabled = s.busy_action.len > 0;
        const active = isBusy(s.busy_action, plugin, action);
        if (actionButton(c, k, label, disabled, active)) invoke(a, plugin, action);
    }
}

fn renderStatGrid(c: *ui.Context, k: theme.Colors, kids: []const json.Value, w: f32) void {
    const max_cols: usize = @max(@as(usize, 1), @min(kids.len, @as(usize, @intFromFloat(@floor((w + row_gap) / 140)))));
    var start: usize = 0;
    const outer = ui.div(c).column().w(w).gap(row_gap);
    defer outer.end();
    while (start < kids.len) {
        const end = @min(start + max_cols, kids.len);
        const count = end - start;
        const tile_w = @max((w - row_gap * @as(f32, @floatFromInt(count - 1))) / @as(f32, @floatFromInt(count)), 60);
        const row = ui.div(c).row().w(w).gap(row_gap);
        defer row.end();
        for (kids[start..end], start..) |child, ix| {
            ui.key(c, c.print("tile-{d}", .{ix}));
            const tile = ui.div(c).column().w(tile_w).px(12).py(7).gap(2).rounded(8).bg(k.ink(0.03)).border(k.ink(0.08)).borderW(1);
            defer tile.end();
            const label = ext.str(child, "label");
            const value = ext.str(child, "value");
            const inner = @max(tile_w - 24, 30);
            kit.ellipsisText(c, label, set.st(c, 11.5, .{ .color = k.muted }), inner);
            const dot_col = if (hasStatusCue(label, value)) statusColor(k, value) else null;
            const vr = ui.div(c).row().w(inner).itemsCenter().gap(6);
            defer vr.end();
            if (dot_col) |dc| kit.dot(c, 7, dc);
            const vc = dot_col orelse statusColor(k, value) orelse k.text;
            kit.ellipsisText(c, value, set.st(c, 13.5, .{ .mono = looksMono(value), .weight = .medium, .color = vc }), if (dot_col != null) @max(inner - 13, 20) else inner);
        }
        start = end;
    }
}

fn renderButtonRow(c: *ui.Context, a: *App, k: theme.Colors, s: *State, plugin: []const u8, kids: []const json.Value, w: f32) void {
    const col = ui.div(c).column().w(w).gap(row_gap);
    defer col.end();
    var ix: usize = 0;
    while (ix < kids.len) {
        const line = ui.div(c).row().w(w).gap(row_gap).itemsCenter();
        defer line.end();
        var used: f32 = 0;
        var count: usize = 0;
        while (ix < kids.len) {
            const label = ext.str(kids[ix], "label");
            const action = ext.str(kids[ix], "action");
            const active = isBusy(s.busy_action, plugin, action);
            const bw = @min(btnWidth(c, label, active), w);
            const need = bw + (if (count > 0) row_gap else 0);
            if (count > 0 and used + need > w) break;
            used += need;
            count += 1;
            ui.key(c, c.print("btn-{d}", .{ix}));
            if (actionButton(c, k, label, s.busy_action.len > 0, active)) invoke(a, plugin, action);
            ix += 1;
        }
    }
}

fn renderMixedRow(c: *ui.Context, a: *App, k: theme.Colors, s: *State, plugin: []const u8, kids: []const json.Value, w: f32, depth: usize) void {
    const cols_only = allKind(kids, "column");
    const side_by_side = cols_only and kids.len == 2 and w >= 440;
    if (side_by_side) {
        const col_w = @max((w - 12) / 2, 160);
        const r = ui.div(c).row().w(w).gap(12).itemsStart();
        defer r.end();
        for (kids, 0..) |child, ix| {
            ui.key(c, c.print("split-{d}", .{ix}));
            const sub = ui.div(c).column().w(col_w).px(14).py(9).rounded(8).bg(k.ink(0.025)).border(k.ink(0.08)).borderW(1);
            defer sub.end();
            renderNode(c, a, k, s, plugin, child, @max(col_w - 28, 120), depth);
        }
        return;
    }
    const stack = ui.div(c).column().w(w).gap(8);
    defer stack.end();
    for (kids, 0..) |child, ix| {
        ui.key(c, c.print("mix-{d}", .{ix}));
        renderNode(c, a, k, s, plugin, child, w, depth);
    }
}

fn btnWidth(c: *ui.Context, label: []const u8, active: bool) f32 {
    const pad: f32 = if (active) 34 else 26;
    return pad + c.text.width(label, .{ .size = 12, .weight = .medium });
}

fn actionButton(c: *ui.Context, k: theme.Colors, label: []const u8, disabled: bool, active: bool) bool {
    var box = ui.div(c).row();
    if (disabled and !active) box = box.opacity(0.45);
    defer box.end();
    const b = ui.div(c).row().px(12).py(6).gap(6).rounded(8).itemsCenter().bg(k.background).border(k.border).borderW(1);
    const drawn = if (!disabled) b.hover(k.ink(0.05)).control() else b;
    defer drawn.end();
    if (!disabled) _ = kit.focusRing(c, drawn, k.accent, 2);
    if (active) kit.miniSpinner(c, k.muted);
    ui.text(c, label, set.st(c, 12, .{ .weight = .medium, .color = if (disabled) k.muted else k.text }));
    return !disabled and drawn.clicked();
}

fn childrenOf(node: json.Value) []const json.Value {
    const arr = if (node == .object) (node.object.get("children") orelse .null) else .null;
    return if (arr == .array) arr.array.items else &.{};
}

fn allKind(kids: []const json.Value, kind: []const u8) bool {
    for (kids) |child| if (!std.mem.eql(u8, ext.str(child, "kind"), kind)) return false;
    return true;
}

fn isBusy(busy: []const u8, plugin: []const u8, action: []const u8) bool {
    if (busy.len == 0 or busy.len != plugin.len + 1 + action.len) return false;
    return std.mem.startsWith(u8, busy, plugin) and busy[plugin.len] == ':' and std.mem.endsWith(u8, busy, action);
}

fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const Tone = enum { success, warning, danger };

fn skeleton(c: *ui.Context, k: theme.Colors, count: usize) void {
    const delta: f32 = @floatCast(@mod(c.time / 2.4, 1.0));
    kit.loaderFrame(c, 1.0 / 30.0);
    const col = ui.div(c).column().wFull().gap(6).py(4);
    defer col.end();
    for (0..count) |i| {
        const phase = @mod(delta - @as(f32, @floatFromInt(i)) * 0.08, 1.0);
        const wave = 0.5 - 0.5 * @cos(phase * std.math.tau);
        const bar = ui.div(c).row().wFull().h(28).rounded(6).bg(k.ink(0.04)).opacity(0.35 + 0.4 * wave);
        bar.end();
    }
}

fn toneOf(s: []const u8) ?Tone {
    if (startsWithCI(s, "online") or startsWithCI(s, "running") or startsWithCI(s, "ready") or startsWithCI(s, "free") or startsWithCI(s, "idle") or startsWithCI(s, "succeeded") or startsWithCI(s, "local")) return .success;
    if (startsWithCI(s, "busy") or startsWithCI(s, "held") or startsWithCI(s, "fallback") or startsWithCI(s, "low") or startsWithCI(s, "starting")) return .warning;
    if (startsWithCI(s, "offline") or startsWithCI(s, "paused") or startsWithCI(s, "error") or startsWithCI(s, "failed") or startsWithCI(s, "unconfigured")) return .danger;
    return null;
}

fn hasStatusCue(label: []const u8, value: []const u8) bool {
    if (containsCI(label, "status") or
        containsCI(label, "routing") or
        containsCI(label, "heartbeat") or
        containsCI(label, "state") or
        containsCI(label, "online") or
        containsCI(label, "lock"))
        return true;
    return toneOf(value) != null;
}

fn statusColor(k: theme.Colors, s: []const u8) ?ui.Color {
    return switch (toneOf(s) orelse return null) {
        .success => k.success,
        .warning => k.warning,
        .danger => k.danger,
    };
}

fn startsWithCI(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn looksMono(s: []const u8) bool {
    if (s.len == 0 or s.len > 48) return false;
    var digits: usize = 0;
    for (s) |ch| if (std.ascii.isDigit(ch)) {
        digits += 1;
    };
    return digits > 0 and (std.mem.indexOfScalar(u8, s, '%') != null or
        std.mem.indexOfScalar(u8, s, ':') != null or
        std.mem.indexOf(u8, s, "GiB") != null or
        std.mem.indexOf(u8, s, "MiB") != null or
        std.mem.indexOfScalar(u8, s, '/') != null);
}
