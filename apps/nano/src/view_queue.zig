//! The queue tray over the composer (crates/ui/src/queue.rs): a surface
//! with rounded top corners tucked behind the pill, one 36-point row per
//! message: its text on one line, then Remove, Edit and "Send now"; the row
//! being edited centers "Save to queue" and "Cancel" as one action group.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const queue = @import("queue.zig");
const App = @import("app.zig").App;

/// How far the pill covers the tray's foot.
pub const tuck: f32 = 26;
const row_height: f32 = 36;

pub fn tray(c: *ui.Context, a: *App, k: theme.Colors, w: f32) bool {
    if (a.queue.items.len == 0) return false;
    const box = ui.div(c).column().w(w - 32).bg(k.composer).border(k.border).borderW(1).rounded(16).pb(8 + tuck).pt(4).px(4);
    defer box.end();
    // Only message rows scroll. The padding tucked behind the composer is
    // decoration, not overflow; always leave room for one complete row.
    const chrome_height = 4 + 8 + tuck + 2;
    const rows = ui.div(c).column().wFull().maxH(@max(row_height, c.size.h * 0.3 - chrome_height))
        .scrollY().scrollbar(.{ .overlay = k.muted.alpha(0.5) });
    defer rows.end();
    const compact = w < 520;
    // Tray: 32pt outer inset, 1pt borders and 4pt horizontal padding.
    const row_width = @max(0, w - 42);
    for (a.queue.items, 0..) |r, i| {
        ui.key(c, c.print("q-{s}", .{r.id}));
        row(c, a, k, r, i + 1 == a.queue.items.len, compact, row_width);
    }
    return true;
}

const edit_actions = [_]kit.Action{
    .{ .icon = .check, .label = "Save to queue", .short_label = "Save" },
    .{ .icon = .close, .label = "Cancel" },
};

fn row(c: *ui.Context, a: *App, k: theme.Colors, r: queue.Row, newest: bool, compact: bool, width: f32) void {
    const editing = if (a.queue_edit) |e| std.mem.eql(u8, e.row, r.id) else false;
    const gap: f32 = if (compact) 4 else 8;
    const layout = kit.actionLayout(c, @max(0, width - 16), &edit_actions, 0, gap);
    var line = ui.div(c).row().wFull().h(row_height).px(8).gap(gap).itemsCenter().rounded(8);
    line = if (editing) line.bg(k.ink(0.06)).justifyCenter() else line.hover(k.ink(0.04));
    defer line.end();
    const gated = r.gate != .none;
    // Editing is not draggable; do not spend scarce action space on a handle.
    if (!editing) icons.icon(c, .@"queue-drag-handle", 13, k.muted.alpha(if (gated) 0.35 * 0.5 else 0.5), 14);
    if (!editing) {
        const col = ui.div(c).column().grow().w(0).clip();
        defer col.end();
        const title: []const u8 = switch (r.gate) {
            .editing => |who| c.print("Editing on {s}", .{who}),
            .review => "Needs review",
            .none => blk: {
                const buf = c.alloc().alloc(u8, 400) catch break :blk r.text;
                const one = queue.oneLine(buf, r.text);
                break :blk if (r.agent) c.print("Agent message · {s}", .{one}) else one;
            },
        };
        kit.fadeText(c, title, kit.style(c, 12.5, 16, .{ .color = k.text.alpha(0.9) }), 2000);
        if (r.attachments > 0 and !editing)
            ui.text(c, c.print("{d} attachment{s}", .{ r.attachments, if (r.attachments == 1) "" else "s" }), .{ .size = 11, .color = k.muted });
    }
    if (editing) {
        const enabled = !a.queue_edit.?.saving;
        if (kit.actionButton(c, k, edit_actions[0], layout.mode, enabled)) a.queueFinishEdit(.commit);
        if (kit.actionButton(c, k, edit_actions[1], layout.mode, enabled)) a.queueFinishEdit(.cancel);
        return;
    }
    if (rowButton(c, k, .@"trash-bin-minimalistic", "Remove", !gated)) a.queueRemove(r.id);
    if (!r.agent and rowButton(c, k, .pen, "Edit", !gated and a.queue_edit == null)) a.queueBeginEdit(r.id);
    const queue_mod = @import("app_queue.zig");
    if (queue_mod.rowCanSteer(a, r)) {
        if (compact) {
            if (rowButton(c, k, .@"fast-tier", "Steer into active turn", true)) queue_mod.steerRowNow(a, r.id);
        } else {
            var sb = ui.div(c).row().h(28).px(8).center().rounded(5).opacity(0.72).hover(k.ink(0.07));
            sb = tip.on(sb, k, .{ .text = "Steer into active turn", .delay = tip.quick, .look = .queue });
            defer sb.end();
            if (sb.clicked()) queue_mod.steerRowNow(a, r.id);
            ui.text(c, "Steer", .{ .size = 11.5, .color = k.muted });
        }
    }
    const can_send = a.caps.actions and !gated;
    // `QueuePrimaryAction::tooltip`, or why it waits.
    const send_tip = if (can_send) "Send now (interrupt)" else "Waiting for provider capabilities";
    const label = if (newest and c.input.cmd) "⌘ Enter" else "Send now";
    if (compact) {
        if (rowButton(c, k, .@"arrow-up", send_tip, can_send)) a.queueSendNow(r.id);
    } else {
        var b = ui.div(c).row().size(72, 28).center().rounded(5).opacity(if (can_send) 0.72 else 0.45);
        if (can_send) b = b.hover(k.ink(0.07));
        b = tip.on(b, k, .{ .text = send_tip, .delay = tip.quick, .look = .queue });
        defer b.end();
        if (b.clicked() and can_send) a.queueSendNow(r.id);
        ui.text(c, label, .{ .size = 11.5, .color = k.muted });
    }
}

/// A `queue_action`: its icon, and `label` as its tooltip.
fn rowButton(c: *ui.Context, k: theme.Colors, name: icons.Name, label: []const u8, enabled: bool) bool {
    return kit.actionButton(c, k, .{ .icon = name, .label = label }, .icons, enabled);
}
