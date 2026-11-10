//! The agent's question, in the composer's place (crates/ui/src/composer.rs
//! `render_wizard`): its header and "1/2", the question, numbered options
//! (1–9 pick them while the answer box is empty), the answer box, and
//! "Cancel question", "Back", "Next" or "Submit".
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const App = @import("app.zig").App;

pub fn panel(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const wz = if (a.wizard) |*x| x else return;
    const q = wz.question();
    const typed_empty = std.mem.trim(u8, a.composer.text(), " \n\t").len == 0;
    keys(c, a, q.options.len, typed_empty);
    // Submit and Cancel close the wizard `wz` and `q` point into, so a
    // button's action waits until the panel is drawn.
    var act: enum { none, advance, back, dismiss } = .none;
    defer switch (act) {
        .none => {},
        .advance => a.wizardAdvance(),
        .back => a.wizardBack(),
        .dismiss => a.wizardDismiss(),
    };
    const box = kit.shadowLg(ui.div(c).column().w(w).bg(k.composer).border(k.border).borderW(1).rounded(@import("view_composer.zig").radius));
    defer box.end();
    {
        const body = ui.div(c).column().wFull().px(16).pt(16).pb(12);
        defer body.end();
        {
            const head = ui.div(c).row().gap(10).itemsCenter().control();
            defer head.end();
            ui.text(c, tracked(c, if (q.header.len > 0) q.header else "Question"), .{ .size = 10.5, .weight = .medium, .color = k.muted.alpha(0.6) });
            if (wz.questions.len > 1) {
                const counter = ui.div(c).row().h(20).px(6).rounded(6).itemsCenter().bg(k.ink(0.06));
                defer counter.end();
                ui.text(c, c.print("{d}/{d}", .{ wz.page + 1, wz.questions.len }), .{ .size = 10, .weight = .medium, .color = k.muted.alpha(0.6) });
            }
        }
        {
            const q_hash = std.hash.Wyhash.hash(0, q.question);
            ui.key(c, c.print("wizard-q-{s}-{d}-{x}", .{ wz.request_id, wz.page, q_hash }));
            const qt = ui.div(c).column().wFull().pt(6);
            c.node(qt.index).style.selectable = true;
            defer qt.end();
            // Agents write questions in Markdown (bold, code spans, lists),
            // as their replies (composer.rs `question_markdown`).
            @import("view_markdown.zig").markdown(c, k, q.question);
        }
        if (q.multi_select) {
            const hint = ui.div(c).row().pt(4).control();
            defer hint.end();
            ui.text(c, "Select one or more options.", .{ .size = 12, .color = k.muted.alpha(0.65) });
        }
        if (q.options.len > 0) {
            const list = ui.div(c).column().wFull().pt(12).gap(4).control();
            defer list.end();
            for (q.options, 0..) |opt, i| {
                ui.key(c, c.print("opt-{d}-{d}", .{ wz.page, i }));
                const on = wz.picked(i) and typed_empty;
                var r = ui.div(c).row().wFull().px(14).py(10).gap(12).itemsCenter().rounded(12).control();
                r = if (on) r.bg(k.ink(0.09)).border(k.ink(0.16)).borderW(1) else r.bg(k.ink(0.025)).hover(k.ink(0.06));
                defer r.end();
                if (r.clicked()) a.wizardPick(i);
                if (i < 9) {
                    const n = ui.div(c).row().size(22, 22).center().rounded(6).bg(k.ink(if (on) 0.16 else 0.05));
                    defer n.end();
                    ui.text(c, c.print("{d}", .{i + 1}), .{ .size = 11, .color = if (on) k.text else k.muted.alpha(0.6) });
                }
                ui.text(c, opt, kit.style(c, 13.5, 19, .{ .wrap = true, .weight = .medium, .color = if (on) k.text else k.text.alpha(0.9) }));
            }
        }
    }
    {
        const editor = ui.div(c).column().wFull().px(16);
        defer editor.end();
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.wash(0.06) }, .none, null);
        const field = ui.div(c).column().wFull().pt(12).pb(4).px(4);
        defer field.end();
        const any_pick = wz.picks[wz.page].items.len > 0;
        const field_id = c.peekId(null);
        const prev_edit = c.edits.get(field_id);
        const prev_caret: ?usize = if (prev_edit) |e| e.caret else null;
        const prev_anchor: ?usize = if (prev_edit) |e| e.anchor else null;
        const field_index: u32 = @intCast(c.nodes.items.len);
        const r = ui.textField(c, &a.composer, .{
            .placeholder = if (any_pick) "Type your own answer, or leave this blank to use the selected option" else "Type your own answer, or pick an option above",
            .width = .fill,
            .bare = true,
            .size = 14,
            .multiline = true,
            .max_lines = 8,
        });
        c.node(field_index).style.scroll_bar = false;
        _ = c.scrollbars.remove(field_id);
        if (c.edits.get(field_id)) |e| {
            const clicked_field = c.input.pressed and c.input.button == .left and !c.input.secondary and !c.right_press and c.hot == field_id;
            const moved_selection = prev_caret != null and (e.caret != prev_caret.? or e.anchor != prev_anchor.?);
            if (clicked_field or r.changed or moved_selection) c.selection.clear();
        }
        if (r.focused and c.shortcut(.{ .key = 'a', .cmd = true })) {
            if (c.edits.getPtr(field_id)) |e| {
                e.anchor = 0;
                e.caret = a.composer.text().len;
                c.selection.clear();
                c.changed = true;
            }
        }
        if (r.submitted) act = .advance;
    }
    const foot = ui.div(c).row().wFull().px(16).pb(16).pt(4).itemsCenter().control();
    defer foot.end();
    if (button(c, k, "Cancel question", false, true)) act = .dismiss;
    ui.spacer(c);
    if (wz.page > 0 and button(c, k, "Back", false, true)) act = .back;
    if (button(c, k, if (wz.last()) "Submit" else "Next", true, wz.canAdvance() or !typed_empty)) act = .advance;
}

/// 1–9 pick while the answer box is empty; Escape steps back a page.
fn keys(c: *ui.Context, a: *App, options: usize, typed_empty: bool) void {
    if (typed_empty) {
        var i: usize = 0;
        while (i < @min(options, 9)) : (i += 1) {
            if (c.shortcut(.{ .key = @as(u21, '1') + @as(u21, @intCast(i)) })) a.wizardPick(i);
        }
    }
    if (typed_empty and c.shortcut(.{ .key = ui.Shortcut.escape })) a.wizardBack();
}

/// A header as the desktop sets it: upper case, hair spaces between letters.
fn tracked(c: *ui.Context, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |ch, i| {
        if (i > 0) out.appendSlice(c.alloc(), "\u{200A}") catch {};
        out.append(c.alloc(), std.ascii.toUpper(ch)) catch {};
    }
    return out.items;
}

/// A dialog button: the primary one solid, the others ghosts.
pub fn button(c: *ui.Context, k: theme.Colors, label: []const u8, primary: bool, enabled: bool) bool {
    var b = ui.div(c).row().px(if (primary) 16 else 12).py(6).rounded(8).itemsCenter().control();
    b = if (primary) b.bg(k.solid) else b.hover(k.ink(0.06));
    if (!enabled) b = b.opacity(0.4);
    defer b.end();
    const hot = b.hovered();
    const color = if (primary) k.on_solid else if (hot) k.text else k.muted;
    ui.text(c, label, .{ .size = 13, .weight = if (primary) .medium else .regular, .color = color });
    return b.clicked() and enabled;
}

/// The question as the transcript keeps it: a chip, "Waiting for you"
/// until it is answered.
pub fn chip(c: *ui.Context, k: theme.Colors, question: []const u8, resolved: bool) void {
    const outer = ui.div(c).column().py(4).control();
    defer outer.end();
    const r = ui.div(c).row().h(34).px(8).gap(8).itemsCenter().rounded(10).border(k.wash(0.08)).borderW(1).bg(k.ink(0.045)).clip();
    defer r.end();
    const tile = ui.div(c).row().size(20, 20).center().rounded(6).bg(k.ink(0.09));
    icons.icon(c, .@"chat-round-line", 12, k.muted, 0);
    tile.end();
    ui.text(c, "Question", .{ .size = 12, .weight = .medium, .color = k.muted });
    kit.fadeText(c, question, .{ .size = 12, .color = k.text.alpha(0.9) }, 420);
    if (!resolved) ui.text(c, "Waiting for you", .{ .size = 12, .color = k.muted });
}
