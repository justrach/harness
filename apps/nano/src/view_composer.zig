//! The composer, as the GPUI composer draws it (crates/ui/src/composer.rs,
//! pickers.rs): one rounded pill with attach and dictate on the left, the
//! input ("Do anything…"), the model chip (the agent's mark, the model,
//! the reasoning level) and a round send button that becomes Stop while a
//! run goes with nothing typed. It expands with a line break, and always on
//! a new chat.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const attachments = @import("app_attachments.zig");
const attachmentStrip = @import("view_composer_attachments.zig").strip;
const transcript_view = @import("view_transcript.zig");
const footer_view = @import("view_session_footer.zig");
const App = @import("app.zig").App;

/// Docked under a chat's transcript: as wide as the conversation column
/// setting, less its 16-point gutters only once the pane is narrower
/// (shell.rs `composer_target_width`, less the composer's `px(SPACE_LG)`).
pub fn docked(c: *ui.Context, a: *App, k: theme.Colors) void {
    const w = dockedWidth(transcript_view.paneWidth(c, a), transcript_view.column_w);
    const queue_view = @import("view_queue.zig");
    const queued = a.queue.items.len > 0;
    // 16 points of padding, over the window's 24-point status strip; the
    // pill covers the queue tray's foot, so it moves up as much.
    const outer = ui.div(c).column().wFull().px(16).pb(if (queued) 40 - queue_view.tuck else 40).itemsCenter();
    defer outer.end();
    // Keyed: the tray coming and going must not change the input's id
    // (which would take its focus).
    dictationStatus(c, a, k, w);
    ui.key(c, "queue-tray");
    _ = queue_view.tray(c, a, k, w);
    ui.key(c, "composer");
    const lift: f32 = if (queued) -queue_view.tuck else 0;
    if (a.wizard != null) {
        const q = ui.div(c).column().offset(0, lift);
        defer q.end();
        return @import("view_question.zig").panel(c, a, k, w);
    }
    const expanded = attachments.count(a) > 0 or composerFlip(
        a.view.composer_expanded,
        c.text.width(a.composer.text(), .{ .size = 14, .line_height = 22.75 }),
        compactCapacity(c, a, w),
        std.mem.indexOfScalar(u8, a.composer.text(), '\n') != null,
    );
    a.view.composer_expanded = expanded;
    const p = ui.div(c).column().offset(0, lift);
    defer p.end();
    pill(c, a, k, w, if (expanded) .expanded else .compact, 22);
    // The session footer, in the slot the 40 points under the pill keep
    // for it (`SESSION_FOOTER_HEIGHT`, 8 under the pill); drawn over that
    // padding so the queue tray's tuck needn't move it.
    const pill_h: f32 = if (!expanded) 49 else if (a.view.composer_anchor) |r| r.h else 49;
    const f = ui.div(c).row().absolute().offset(0, pill_h + footer_view.gap);
    defer f.end();
    footer_view.footer(c, a, k, w);
}

/// `composer_target_width` less the composer's own 16-point sides: the
/// conversation width `column` while the pane has room, else the pane
/// less 32.
pub fn dockedWidth(pane_w: f32, column: f32) f32 {
    return @max(@min(column + 32, pane_w) - 32, 0);
}

test "the docked composer is the conversation's width until the pane is narrower (composer_width_shares_the_maximum_only_in_established_threads)" {
    for ([_][2]f32{ .{ 560, 560 }, .{ 736, 736 }, .{ 1200, 1200 } }) |case| {
        try std.testing.expectEqual(case[1], dockedWidth(1600, case[0]));
        try std.testing.expectEqual(@as(f32, 468), dockedWidth(500, case[0]));
        try std.testing.expectEqual(@as(f32, 0), dockedWidth(0, case[0]));
    }
}

/// The GPUI composer's `composer_flip`: decide against the compact width,
/// never the wider post-flip field, so resizing/typing cannot oscillate.
pub fn composerFlip(expanded: bool, text_width: f32, capacity: f32, newline: bool) bool {
    if (newline or capacity < 200) return true;
    return if (expanded) text_width >= capacity - 32 else text_width > capacity;
}

fn compactCapacity(c: *ui.Context, a: *App, w: f32) f32 {
    const target = a.target();
    const st: ui.TextStyle = .{ .size = 12, .weight = .medium };
    var chip_w: f32 = 12 + 16;
    if (a.models.items.len == 0 and target.model == null) {
        chip_w += 6 + 56;
    } else {
        chip_w += 6 + c.text.width(a.modelLabel(target.model), st);
        if (target.reasoning) |level| chip_w += 6 + c.text.width(rules.reasoningLabel(level), st);
    }
    return @max(0, w - 100 - (if (dictate.shown(a)) @as(f32, 30) else 0) - @min(248, chip_w));
}

test "composer expansion uses GPUI's width threshold and collapse hysteresis" {
    try std.testing.expect(!composerFlip(false, 300, 300, false));
    try std.testing.expect(composerFlip(false, 301, 300, false));
    try std.testing.expect(composerFlip(true, 280, 300, false));
    try std.testing.expect(!composerFlip(true, 267, 300, false));
    try std.testing.expect(composerFlip(false, 0, 199, false));
    try std.testing.expect(composerFlip(false, 0, 400, true));
}

pub const Shape = enum { compact, expanded };

pub fn pill(c: *ui.Context, a: *App, k: theme.Colors, w: f32, shape: Shape, radius: f32) void {
    // `border_1` takes its point from inside the box in GPUI: the pill is
    // 49 tall compact (`COMPACT_TOTAL_HEIGHT`), 76 + 42 + 2 expanded
    // (`COMPOSER_MIN_HEIGHT`), its controls a point in from each edge.
    const p = kit.shadowLg(ui.div(c).w(w).bg(k.composer).border(k.border).borderW(1).rounded(radius).p(1)).bg(k.composer).clip();
    const box = if (shape == .compact) p.row().h(49).px(8 + 1).itemsCenter() else p.column();
    defer box.end();
    if (c.rects.get(c.node(box.index).id)) |r| a.view.composer_anchor = r;
    if (shape == .compact) {
        attachButtons(c, a, k);
        input(c, a, k, .compact);
        chip(c, a, k);
        send(c, a, k);
        return;
    }
    attachmentStrip(c, a, k, w);
    {
        // At least 76 tall, as GPUI's text area, growing with its lines.
        const area = ui.div(c).row().wFull();
        defer area.end();
        _ = c.leaf(.{ .width = .{ .px = 0 }, .height = .{ .px = 76 } }, .none, null);
        // `pt(16)`, less the point and a half GPUI's input draws its first
        // line above nano's (measured: parity/scenes/settings-*.json).
        const inner = ui.div(c).column().grow().w(0).px(16).pt(16 - 1.5).pb(4 + 1.5);
        defer inner.end();
        input(c, a, k, .expanded);
    }
    // Expanded, the model sits after the paperclip, at most 45% of the
    // pill; Send keeps the end (`morph_cluster`).
    const actions = ui.div(c).row().wFull().h(42).px(12).pt(2).pb(8).itemsCenter();
    defer actions.end();
    attachButtons(c, a, k);
    {
        const m = ui.div(c).row().pl(2).maxW(w * 0.45).clip();
        defer m.end();
        chip(c, a, k);
    }
    ui.spacer(c);
    send(c, a, k);
}

const dictate = @import("app_dictation.zig");

fn attachButtons(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (kit.iconButton(c, k, .paperclip, .{ .size = 28, .radius = 14, .icon = 18 }))
        attachments.pick(a);
    // The mic shows where the device's Codex voice was found, and while a
    // session is live.
    if (!dictate.shown(a)) return;
    _ = c.leaf(.{ .width = .{ .px = 2 } }, .none, null);
    if (micButton(c, a, k)) dictate.toggle(a);
}

/// `render_dictation_button`: listening, a red wash as loud as the mic
/// and a red mic; starting or finishing, a faint one.
fn micButton(c: *ui.Context, a: *App, k: theme.Colors) bool {
    const s = &a.dictation;
    const listening = s.running != null and s.listening and !s.finishing;
    const busy = s.running != null and !listening;
    const level = std.math.clamp(s.level, 0, 1);
    ui.key(c, "composer-dictate");
    const base = ui.div(c).row().size(28, 28).center().roundedFull();
    const b = if (listening) base.bg(k.danger.alpha(0.10 + 0.30 * level)) else kit.listenerHover(&a.view.hovers, base, k.ink(0.10)).div;
    defer b.end();
    icons.icon(c, .microphone, 17, if (listening) k.danger else if (busy) k.faint else k.muted, 0);
    return b.clicked();
}

/// `render_dictation_status`: one quiet caption over the composer while
/// dictating, as the queue's notice.
pub fn dictationStatus(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const s = &a.dictation;
    if (s.running == null) return;
    const dot = if (s.finishing or !s.listening) k.faint else k.danger;
    const text = if (s.finishing)
        "Finishing dictation…"
    else if (!s.listening)
        "Starting dictation…"
    else if (s.partial.items.len == 0)
        "Listening — click the mic to stop"
    else
        c.print("Listening — {s}", .{s.partial.items});
    const row = ui.div(c).row().w(w).px(8).pt(6).gap(6).itemsCenter();
    defer row.end();
    _ = c.leaf(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = dot }, .none, null);
    kit.ellipsisText(c, text, .{ .size = 11, .line_height = 14, .color = k.faint }, w - 16 - 11);
}

fn input(c: *ui.Context, a: *App, k: theme.Colors, shape: Shape) void {
    // Compact, GPUI's line sits half a point lower than nano's centred one.
    const box = if (shape == .compact) ui.div(c).row().grow().w(0).px(8).pt(1).itemsCenter() else ui.div(c).column().wFull();
    defer box.end();
    const placeholder = if (a.engine.state != .connected)
        @import("engine_start.zig").waiting(a)
    else if (a.queue_edit != null)
        "Edit queued message…"
    else
        "Do anything…";
    attachments.paste(c, a);
    const at = c.nodes.items.len;
    const viewport = transcript_view.paneHeight(c, a) orelse c.size.h;
    const max_lines: u16 = @intFromFloat(@max(1, @min(11, @floor(viewport * 0.35 / 22.75))));
    const r = ui.textField(c, &a.composer, .{
        .placeholder = placeholder,
        .width = .fill,
        .bare = true,
        .size = 14,
        // GPUI's composer: 22.75-point lines, its placeholder faint.
        .line_height = 22.75,
        .placeholder_color = k.faint,
        .multiline = true,
        .max_lines = if (shape == .compact) 1 else max_lines,
    });
    // "Send messages with" (Settings › Shortcuts): Enter sends, or starts a
    // new line and ⌘↩ sends (`composerSendBehavior`).
    a.view.composer_caret = r.caret;
    const on_enter = @import("view_settings_shortcuts.zig").sendsOnEnter(a);
    if (r.submitted) {
        if (on_enter) a.send() else {
            _ = a.composer.insert(r.caret, "\n");
            a.composer.want_caret = r.caret + 1;
        }
    }
    if (!on_enter and (std.mem.trim(u8, a.composer.text(), " \n\t").len > 0 or attachments.count(a) > 0) and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) a.send();
    recall(c, a, c.node(@intCast(at)).id);
    keepFocus(c, a, c.node(@intCast(at)).id);
    // ⌘↩ with nothing typed sends the newest queued message now.
    if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }) and std.mem.trim(u8, a.composer.text(), " \n\t").len == 0) {
        if (a.queue.items.len > 0) a.queueSendNow(a.queue.items[a.queue.items.len - 1].id);
    }
    if (a.queue_edit != null and c.shortcut(.{ .key = ui.Shortcut.escape })) a.queueFinishEdit(.cancel);
    if (a.noticeText()) |n| {
        const line = ui.div(c).row().pt(4);
        defer line.end();
        ui.text(c, n, .{ .size = 11, .color = k.danger });
    }
}

/// ↑ at the text's start or ↓ at its end steps through the chat's earlier
/// prompts (`history_step`, `navigate_prompt_history`), unless a question,
/// a queued edit or the model picker has the composer. The key comes as a
/// shortcut before the field sees it, so the caret hasn't moved yet.
fn recall(c: *ui.Context, a: *App, id: u64) void {
    if (a.wizard != null or a.queue_edit != null or a.picker != .none) return;
    const s = c.input.shortcut orelse return;
    if (s.cmd or s.ctrl or s.alt or s.shift) return;
    const delta: i8 = if (s.key == ui.Shortcut.up) -1 else if (s.key == ui.Shortcut.down) 1 else return;
    const f = c.focused_text orelse return;
    if (f.id != id) return;
    const history = @import("prompt_history.zig");
    const text = a.composer.text();
    if (!history.wantsStep(&a.prompt_nav, text, delta, f.caret, f.anchor, f.marked != null)) return;
    _ = c.shortcut(s);
    const next = a.prompt_nav.step(a.gpa, a.transcript.entries.items, text, delta) catch return;
    if (next) |t| a.composer.set(t);
}

/// The composer has the keys after the window moves to another chat, pane
/// or tab (`focus_composer`), and keeps them when its field moves in the
/// layout (into a split's pane, or taller with a second line), which
/// gives the field another id.
fn keepFocus(c: *ui.Context, a: *App, id: u64) void {
    const moved = a.view.composer_id != 0 and id != a.view.composer_id and c.focus == a.view.composer_id;
    if (a.view.focus_composer or moved) {
        c.focus = id;
        // Built again at once, focused: the next key finds it.
        c.changed = true;
        a.view.focus_composer = false;
    }
    a.view.composer_id = id;
}

/// The model chip: what the next message runs on.
fn chip(c: *ui.Context, a: *App, k: theme.Colors) void {
    const t = a.target();
    const base = ui.div(c).row().h(32).maxW(248).px(6).gap(6).itemsCenter().rounded(8).clip();
    // GPUI's trigger uses on_hover: closing by keyboard doesn't move the
    // pointer and must not clear the wash until the pointer actually moves.
    const b = kit.listenerHover(&a.view.hovers, if (a.picker != .none) base.bg(k.hover) else base, k.hover).div;
    defer b.end();
    if (b.clicked()) a.togglePicker();
    if (c.rects.get(c.node(b.index).id)) |r| a.view.chip_anchor = r;
    // Before the engine lists them: the glyph spinner for an agent not yet
    // known (an open chat's is: its own), a pulsing bar for its model
    // (`trigger_chip` loading, `chip_icon_loading`).
    const chat_harness = if (a.selected) |id| (if (a.findChat(id)) |ch| ch.harness != null else false) else false;
    if (a.harnesses.items.len == 0 and !chat_harness) {
        kit.snake(c, k);
    } else {
        const mark = icons.harnessMark(t.harness);
        icons.icon(c, mark.name, 16, mark.brand orelse k.muted, 0);
    }
    if (a.models.items.len == 0 and t.model == null) return skeleton(c);
    ui.text(c, a.modelLabel(t.model), .{ .size = 12, .line_height = 12 * 1.618, .weight = .medium, .color = k.text.alpha(0.9) });
    if (t.reasoning) |level| ui.text(c, rules.reasoningLabel(level), .{ .size = 12, .line_height = 12 * 1.618, .weight = .medium, .color = k.muted.alpha(0.7) });
}

/// A label still loading: a 56 by 11 bar whose opacity breathes between
/// 0.35 and 0.75 every 2.4 s (popover.rs `skeleton_bar`).
fn skeleton(c: *ui.Context) void {
    const phase = @sin(@as(f32, @floatCast(c.time)) * std.math.tau / 2.4) * 0.5 + 0.5;
    c.frameIn(1.0 / 30.0);
    _ = c.leaf(.{ .width = .{ .px = 56 }, .height = .{ .px = 11 }, .radius = 5.5, .background = .{ .r = 1, .g = 1, .b = 1, .a = 0.08 * (0.35 + 0.4 * phase) } }, .none, null);
}

/// Send (or queue, while a run goes); Stop with nothing typed mid-run.
fn send(c: *ui.Context, a: *App, k: theme.Colors) void {
    const empty = std.mem.trim(u8, a.composer.text(), " \n\t").len == 0 and attachments.count(a) == 0;
    const running = a.selectedStatus() == .working;
    const stop = running and empty;
    // Dimmed only when it can't send at all; an empty box just does nothing.
    const blocked = !stop and (a.engine.state != .connected or !attachments.ready(a));
    const pad = ui.div(c).row().pl(8);
    defer pad.end();
    var b = ui.div(c).row().size(28, 28).center().roundedFull().bg(k.text);
    b = b.opacity(if (blocked) 0.35 else if (b.hovered()) 0.85 else 1);
    defer b.end();
    if (b.clicked() and !blocked and (stop or !empty)) {
        if (stop) a.interrupt() else a.send();
    }
    if (stop) {
        _ = c.leaf(.{ .width = .{ .px = 11 }, .height = .{ .px = 11 }, .radius = 3, .background = k.shell }, .none, null);
    } else {
        icons.icon(c, .@"arrow-up", 14, k.background, 0);
    }
}
