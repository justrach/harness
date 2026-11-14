//! The agent's question, in the composer's place (crates/ui/src/composer.rs
//! `render_wizard`): its header and "1/2", the question, numbered options
//! (1–9 pick them while the answer box is empty), the answer box, and
//! "Cancel question", "Back", "Next" or "Submit".
//!
//! The panel is never taller than its pane gives the composer dock: the
//! question and the options scroll in what the header, the answer box and
//! the buttons leave (`Nano/QuestionPanel.lean`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("motion_rules.zig");
const App = @import("app.zig").App;

/// A question's ordinary inline surface needs room for a readable option
/// and its fixed controls. Tiny split panes instead use the focused chat's
/// single window-bounded outlet. No separate wizard or draft state is made.
pub fn expanded(c: *ui.Context, a: *const App) bool {
    if (a.wizard == null or a.selected == null or a.view.settings_open or a.view.write_open or a.bots.page != .none) return false;
    if (a.view.strip.expanded) |slot| if (slot != .chat) return false;
    const width = @import("view_composer.zig").dockedWidth(@import("view_transcript.zig").paneWidth(c, a), @import("view_transcript.zig").column_w);
    var height = a.view.chrome.height;
    if (a.tabs.layout()) |s| {
        if (!s.zoomed and s.axis == .vertical and a.view.strip.expanded == null) height = @import("panel_chrome.zig").paneSpan(height, s.shares.items[s.focus], s.panes.items.len, false);
    }
    const actions = @import("view_actions.zig");
    return width < 360 or height - actions.toolbarHeight(a) - actions.dockHeight(a) < 320;
}

/// Outside pane clipping, but below menus/dialogs. Only App's selected-chat
/// wizard can render here; read-only neighbors never mount an answer field.
pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!expanded(c, a)) return;
    ui.key(c, c.print("focused-question-{s}-{s}", .{ a.selected.?, a.wizard.?.request_id }));
    const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(3).bg(.{ .a = 0.3 }).center();
    defer scrim.end();
    // Consume pointer hits without cancelling: accidental outside clicks
    // must not dismiss the agent's request or discard an unfinished answer.
    _ = scrim.interaction();
    const dock = ui.div(c).column().w(@min(640, @max(0, c.size.w - 32))).maxH(@max(0, c.size.h - 32));
    defer dock.end();
    panel(c, a, k, @min(640, @max(0, c.size.w - 32)), .{ .height = c.size.h - 20, .dock = dock.index });
}

/// Where the panel may grow to (view_composer.zig `docked`).
pub const Room = struct {
    /// The dock's share of its pane's height.
    height: f32,
    /// The dock's box, which also holds its foot padding, the queue tray
    /// and dictation status.
    dock: u32,
};

/// A box's height as last laid out (`fallback` before it has been). Layout
/// runs again when this frame changes it.
fn laidHeight(c: *ui.Context, index: u32, fallback: f32) f32 {
    c.node(index).layout_dependent = true;
    return if (c.rects.get(c.node(index).id)) |r| r.h else fallback;
}

/// A box that is its content's height up to a limit set once the panel is
/// built, and scrolls past it under an overlay bar (the content keeps its
/// width, so its height doesn't depend on the limit).
fn scrolls(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).column().wFull().maxH(0).scrollY().scrollbar(.{ .overlay = k.faint.alpha(0.5) });
}

/// Over the foot of a box that scrolls on (`view`, its content
/// `content_h` tall): its last 20 points fade into the panel while more is
/// below, the transcript's `TRANSCRIPT_FADE_BAND` upside down. Drawn after
/// the box, in the frame that holds it. The panel is its own opaque
/// surface on glass too, so the tint is its colour.
fn fadeFoot(c: *ui.Context, k: theme.Colors, view: u32, content_h: f32) void {
    if (!std.math.isFinite(content_h)) return;
    const id = c.node(view).id;
    const r = c.rects.get(id) orelse return;
    if (content_h - r.h - (c.scroll.get(id) orelse 0) <= 0.5) return;
    const band: f32 = @min(20, r.h);
    var y: f32 = 0;
    while (y < band) : (y += 1) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.composer.alpha((y + 0.5) / band), .absolute = true, .offset = .{ .x = 0, .y = r.h - band + y } }, .none, null);
    }
}

pub fn panel(c: *ui.Context, a: *App, k: theme.Colors, w: f32, room: Room) void {
    const wz = if (a.wizard) |*x| x else return;
    keys(c, a, wz.question().options.len, std.mem.trim(u8, a.composer.text(), " \n\t").len == 0);
    const q = wz.question();
    const typed_empty = std.mem.trim(u8, a.composer.text(), " \n\t").len == 0;
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
    // What the dock holds besides this panel, as both were last laid out
    // (its 40-point foot before the panel has been).
    const dock_h = laidHeight(c, room.dock, 0);
    const self_h = laidHeight(c, box.index, 0);
    const around = if (dock_h > 0 and self_h > 0) @max(0, dock_h - self_h) else 40;
    const max_h = rules.questionPanelMax(room.height, around);
    c.node(box.index).style.max_height = max_h;
    // The parts that stay put: the body's insets, the header, the hint, the
    // answer box and the buttons. The question and the options, each in a
    // box that scrolls, share the rest.
    var pinned: f32 = 16 + 12;
    const unknown = std.math.inf(f32);
    var question_box: u32 = undefined;
    var question_h: f32 = unknown;
    var options_box: ?u32 = null;
    var options_h: f32 = 0;
    {
        const body = ui.div(c).column().wFull().px(16).pt(16).pb(12);
        defer body.end();
        {
            const head = ui.div(c).row().gap(10).itemsCenter().control();
            defer head.end();
            pinned += laidHeight(c, head.index, 14);
            ui.text(c, tracked(c, if (q.header.len > 0) q.header else "Question"), .{ .size = 10.5, .weight = .medium, .color = k.muted.alpha(0.6) });
            if (wz.questions.len > 1) {
                const counter = ui.div(c).row().h(20).px(6).rounded(6).itemsCenter().bg(k.ink(0.06));
                defer counter.end();
                ui.text(c, c.print("{d}/{d}", .{ wz.page + 1, wz.questions.len }), .{ .size = 10, .weight = .medium, .color = k.muted.alpha(0.6) });
            }
        }
        {
            const frame = ui.div(c).column().wFull();
            defer frame.end();
            defer fadeFoot(c, k, question_box, question_h);
            // Keyed by its page: the next question starts at its top.
            ui.key(c, c.print("wizard-question-{s}-{d}", .{ wz.request_id, wz.page }));
            const view = scrolls(c, k);
            defer view.end();
            question_box = view.index;
            const q_hash = std.hash.Wyhash.hash(0, q.question);
            ui.key(c, c.print("wizard-q-{s}-{d}-{x}", .{ wz.request_id, wz.page, q_hash }));
            const qt = ui.div(c).column().wFull().pt(6);
            c.node(qt.index).style.selectable = true;
            defer qt.end();
            question_h = laidHeight(c, qt.index, unknown);
            // Agents write questions in Markdown (bold, code spans, lists),
            // as their replies (composer.rs `question_markdown`).
            @import("view_markdown.zig").markdown(c, k, q.question);
        }
        if (q.multi_select) {
            const hint = ui.div(c).row().pt(4).control();
            defer hint.end();
            pinned += laidHeight(c, hint.index, 20);
            ui.text(c, "Select one or more options.", .{ .size = 12, .color = k.muted.alpha(0.65) });
        }
        if (q.options.len > 0) {
            const frame = ui.div(c).column().wFull();
            defer frame.end();
            defer fadeFoot(c, k, options_box.?, options_h);
            ui.key(c, c.print("wizard-options-{s}-{d}", .{ wz.request_id, wz.page }));
            const view = scrolls(c, k);
            defer view.end();
            options_box = view.index;
            const list = ui.div(c).column().wFull().pt(12).gap(4).control();
            defer list.end();
            options_h = laidHeight(c, list.index, unknown);
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
        pinned += laidHeight(c, editor.index, 40);
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.wash(0.06) }, .none, null);
        const field = ui.div(c).column().wFull().pt(12).pb(4).px(4);
        defer field.end();
        const any_pick = wz.picks[wz.page].items.len > 0;
        const field_id = c.peekId(null);
        const prev_edit = c.edits.get(field_id);
        const prev_caret: ?usize = if (prev_edit) |e| e.caret else null;
        const prev_anchor: ?usize = if (prev_edit) |e| e.anchor else null;
        const field_index: u32 = @intCast(c.nodes.items.len);
        const moved = a.view.composer_id != 0 and a.view.composer_id != field_id and c.focus == a.view.composer_id;
        if ((a.view.focus_composer or moved) and !@import("view.zig").menuKeepsKeys(a)) {
            c.focus = field_id;
            a.view.focus_composer = false;
        }
        a.view.composer_id = field_id;
        a.view.composer_frame = c.frame;
        const r = ui.textField(c, &a.composer, .{
            .placeholder = if (any_pick) "Type your own answer, or leave this blank to use the selected option" else "Type your own answer, or pick an option above",
            .width = .fill,
            .bare = true,
            .size = 14,
            .multiline = true,
            .max_lines = @intFromFloat(std.math.clamp(@floor((max_h - 170) / 23), 1, 8)),
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
    {
        const foot = ui.div(c).row().wFull().px(16).pb(16).pt(4).itemsCenter().control();
        defer foot.end();
        pinned += laidHeight(c, foot.index, 50);
        if (button(c, k, "Cancel question", false, true)) act = .dismiss;
        ui.spacer(c);
        if (wz.page > 0 and button(c, k, "Back", false, true)) act = .back;
        if (button(c, k, if (wz.last()) "Submit" else "Next", true, wz.canAdvance() or !typed_empty)) act = .advance;
    }
    const share = rules.questionPanelSplit(max_h - pinned, question_h, options_h);
    c.node(question_box).style.max_height = share.question;
    if (options_box) |index| c.node(index).style.max_height = share.options;
}

/// 1–9 pick while the answer box is empty; Escape steps back a page.
fn keys(c: *ui.Context, a: *App, options: usize, typed_empty: bool) void {
    if (@import("view.zig").menuKeepsKeys(a) or a.view.account_menu or a.view.close_choice) return;
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
/// until it is answered. It ends inside its column, `col` wide: the
/// question fades to fit, and in a column too narrow for both the status
/// is left to the panel under the transcript.
pub fn chip(c: *ui.Context, k: theme.Colors, question: []const u8, resolved: bool, col: f32) void {
    const outer = ui.div(c).column().py(4).control();
    defer outer.end();
    const word_st: ui.TextStyle = .{ .size = 12, .weight = .medium, .color = k.muted };
    const question_st: ui.TextStyle = .{ .size = 12, .color = k.text.alpha(0.9) };
    const status_st: ui.TextStyle = .{ .size = 12, .color = k.muted };
    const status = "Waiting for you";
    // Two 8-point insets, the tile, "Question" and the gaps after each.
    const lead = 8 + 20 + 8 + @ceil(c.text.width("Question", word_st)) + 8 + 8;
    const fit = rules.questionChipFit(
        col,
        lead,
        @ceil(c.text.width(question, question_st)),
        if (resolved) 0 else 8 + @ceil(c.text.width(status, status_st)),
    );
    const r = ui.div(c).row().h(34).maxW(col).px(8).gap(8).itemsCenter().rounded(10).border(k.wash(0.08)).borderW(1).bg(k.ink(0.045)).clip();
    defer r.end();
    const tile = ui.div(c).row().size(20, 20).center().rounded(6).bg(k.ink(0.09));
    icons.icon(c, .@"chat-round-line", 12, k.muted, 0);
    tile.end();
    ui.text(c, "Question", word_st);
    kit.fadeText(c, question, question_st, fit.label);
    if (fit.waiting) ui.text(c, status, status_st);
}
