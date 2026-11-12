//! Small completion menu above the existing writing plane. No new composer layout.
const std = @import("std");
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const complete = @import("composer_completion.zig");
const App = @import("app.zig").App;

fn available(c: *ui.Context, a: *App) bool {
    if (a.wizard != null or a.queue_edit != null or a.picker != .none or a.view.palette.open or a.view.settings_open or a.view.write_open) return false;
    const menu_pointer = if (c.rects.get(a.completion.menu_id)) |r| r.contains(c.input.mouse) and (c.input.pressed or c.input.released or c.input.down) else false;
    if ((c.focus != a.view.composer_id or c.focus == 0) and !menu_pointer) return false;
    const e = c.edits.get(a.view.composer_id) orelse return false;
    return e.marked == null and e.caret == e.anchor;
}

/// Called before the field/history sees these keys. Consume both the shortcut
/// and native TextOp: a physical Tab must not also traverse focus/submit.
pub fn keys(c: *ui.Context, a: *App) bool {
    if (!available(c, a)) return false;
    if (complete.historyKey(a, c)) return true;
    const e = c.edits.get(a.view.composer_id) orelse return false;
    const tok = complete.refresh(a, e.caret) orelse return false;
    const list = complete.entries(a, c.alloc(), tok) catch return false;
    var key: ?u21 = null;
    if (c.input.shortcut) |s| {
        if (s.cmd or s.ctrl or s.alt or s.shift) return false;
        key = s.key;
    }
    if (key == null) for (c.input.ops) |op| if (op == .command) {
        key = switch (op.command) {
            .insert_tab => ui.Shortcut.tab,
            .insert_newline => ui.Shortcut.enter,
            .move_up => ui.Shortcut.up,
            .move_down => ui.Shortcut.down,
            .cancel => ui.Shortcut.escape,
            else => null,
        };
        if (key != null) break;
    };
    const k = key orelse return false;
    if (k != ui.Shortcut.tab and k != ui.Shortcut.enter and k != ui.Shortcut.up and k != ui.Shortcut.down and k != ui.Shortcut.escape) return false;
    if (k != ui.Shortcut.escape and list.len == 0) return false;
    c.input.shortcut = null;
    c.input.ops = &.{};
    c.input.key = null;
    if (k == ui.Shortcut.escape) {
        a.completion.dismissed = true;
    } else if (k == ui.Shortcut.up or k == ui.Shortcut.down) {
        const at = @min(a.completion.active, list.len - 1);
        a.completion.active = if (k == ui.Shortcut.down) (at + 1) % list.len else (at + list.len - 1) % list.len;
    } else complete.accept(a, c, tok, list[@min(a.completion.active, list.len - 1)]);
    c.changed = true;
    a.redraw();
    return true;
}

/// Built from the composer's parent (outside its clipping surface), so the
/// menu overlays transcript whitespace without adding permanent chrome.
pub fn menu(c: *ui.Context, a: *App, k: theme.Colors, width: f32) void {
    if (!available(c, a)) return;
    const caret = if (c.edits.get(a.view.composer_id)) |e| e.caret else return;
    const tok = complete.refresh(a, caret) orelse return;
    const list = complete.entries(a, c.alloc(), tok) catch return;
    const shown = @min(list.len, 6);
    const extra: f32 = if (a.completion.failed or a.completion.remote) 24 else 0;
    const height: f32 = 12 + (if (shown == 0) @as(f32, 22) else @as(f32, @floatFromInt(shown)) * 46) + extra;
    const w = @max(180, @min(width, 520));
    ui.key(c, "composer-command-menu");
    const card = kit.shadowLg(ui.div(c).column().absolute().w(w).offset(0, -height - 6).bg(k.raised).border(k.border).borderW(1).rounded(12).p(6));
    defer card.end();
    a.completion.menu_id = c.node(card.index).id;
    if (list.len == 0) {
        ui.text(c, if (!a.completion.commands_done or !a.completion.skills_done) "Loading commands…" else "No matching commands", .{ .size = 12, .color = k.muted });
    }
    const active = if (list.len > 0) @min(a.completion.active, list.len - 1) else 0;
    const start = if (active >= shown and shown > 0) active - shown + 1 else 0;
    for (list[start..@min(list.len, start + shown)], start..) |entry, ix| {
        ui.keyInt(c, ix);
        const row = ui.div(c).column().wFull().h(46).px(8).justifyCenter().rounded(7).bg(if (ix == active) k.selected else .{}).hover(k.selected);
        {
            defer row.end();
            ui.text(c, c.print("{c}{s}", .{ entry.prefix(), entry.name }), .{ .size = 13, .color = k.text });
            kit.ellipsisText(c, entry.description, .{ .size = 11, .color = k.muted }, w - 28);
        }
        if (row.clicked()) {
            complete.accept(a, c, tok, entry);
            a.view.focus_composer = true;
        }
    }
    if (a.completion.remote) ui.text(c, "Discovery requires the connected execution device", .{ .size = 10, .color = k.muted }) else if (a.completion.failed) {
        const retry = ui.div(c).row().h(24).wFull().px(8).itemsCenter().rounded(7).hover(k.selected);
        {
            defer retry.end();
            ui.text(c, "Retry command discovery", .{ .size = 11, .color = k.muted });
        }
        if (retry.clicked()) complete.retry(a);
    }
}
