//! The composer, as the GPUI composer draws it (crates/ui/src/composer.rs,
//! pickers.rs): one rounded pill with attach and dictate on the left, the
//! input ("Do anything…") and a round accent send button that becomes Stop
//! while a run goes with nothing typed. It expands with a line break, and
//! for multiline drafts. New chats share the dock. The model chip (the agent's mark, the model, the
//! reasoning level) leads the footer under the pill.
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

test {
    _ = @import("tests_composer_completion.zig");
}

/// Docked under a chat's transcript: as wide as the conversation column
/// setting, less its 16-point gutters only once the pane is narrower
/// (shell.rs `composer_target_width`, less the composer's `px(SPACE_LG)`).
pub fn docked(c: *ui.Context, a: *App, k: theme.Colors) void {
    // A selected chat can be visible while host/files own the keys. Do not
    // mount its answer field or replace it with a second prompt editor.
    const question = @import("app_question.zig");
    if ((a.wizard != null or question.pendingInput(a) != null) and !question.ownsActivePane(a)) return;
    // A question that cannot fit this pane has one window-bounded outlet,
    // rendered after the split tree, never a second squeezed copy here.
    if (@import("view_question.zig").expanded(c, a)) return;
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
        // The question may be taller than its pane (a split, a short
        // window): it is told the room the dock has, the pane as last laid
        // out less the bars the conversation shares it with.
        const actions = @import("view_actions.zig");
        const pane = c.node(outer.index).parent;
        c.node(pane).layout_dependent = true;
        const pane_h = if (c.rects.get(c.node(pane).id)) |r| r.h else c.size.h;
        return @import("view_question.zig").panel(c, a, k, w, .{
            .height = pane_h - actions.toolbarHeight(a) - actions.dockHeight(a),
            .dock = outer.index,
        });
    }
    const expanded = attachments.count(a) > 0 or composerFlip(
        a.view.composer_expanded,
        c.text.width(a.composer.text(), .{ .size = 14, .line_height = 22.75 }),
        compactCapacity(w, dictate.shown(a)),
        std.mem.indexOfScalar(u8, a.composer.text(), '\n') != null,
    );
    a.view.composer_expanded = expanded;
    const p = ui.div(c).column().offset(0, lift);
    defer p.end();
    pill(c, a, k, w, if (expanded) .expanded else .compact, radius);
    // The session footer, in the slot the 40 points under the pill keep
    // for it (`SESSION_FOOTER_HEIGHT`, 8 under the pill); drawn over that
    // padding so the queue tray's tuck needn't move it.
    {
        // This zero-height flow anchor follows THIS frame's pill bottom.
        // Offsetting from composer_anchor used its previous height, making
        // the footer jump into the text for one frame on every line change.
        const anchor = ui.div(c).column().w(w).h(0);
        defer anchor.end();
        const f = ui.div(c).row().absolute().offset(0, footer_view.gap);
        defer f.end();
        if (a.selected == null) @import("view_newchat.zig").footer(c, a, k, w) else footer_view.footer(c, a, k, w);
    }
    // The finished turn's "N files changed" card floats over the
    // transcript's foot, 8 clear of the pill and 8 wider either side,
    // growing upward as its names wrap.
    jumpToBottom(c, a, k, w);
    const work = @import("view_turn_work.zig");
    if (work.changes(c, a)) |t| {
        ui.key(c, "turn-work-cue");
        const cue = ui.div(c).row().absolute().offset(-8, -(work.cardHeight(c, a, t, w + 16) + work.gap));
        defer cue.end();
        work.card(c, a, k, t, w + 16);
    }
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

/// The compact input's width less 8 (`compact_capacity`): the pill less
/// its edges (2), side insets (16), attach (28), input insets (16),
/// Send's gap (8) and button (28), then the 8-point expansion reserve.
/// The mic adds its 28-point button and 2-point utility gap.
fn compactCapacity(w: f32, dictation: bool) f32 {
    return @max(0, w - 106 - (if (dictation) @as(f32, 30) else 0));
}

test "composer expansion uses GPUI's width threshold and collapse hysteresis" {
    try std.testing.expectEqual(@as(f32, 204), compactCapacity(340, true));
    try std.testing.expectEqual(@as(f32, 198), compactCapacity(334, true));
    try std.testing.expectEqual(@as(f32, 234), compactCapacity(340, false));
    try std.testing.expectEqual(@as(f32, 0), compactCapacity(0, true));
    try std.testing.expect(!composerFlip(false, 300, 300, false));
    try std.testing.expect(composerFlip(false, 301, 300, false));
    try std.testing.expect(composerFlip(true, 280, 300, false));
    try std.testing.expect(!composerFlip(true, 267, 300, false));
    try std.testing.expect(composerFlip(false, 0, 199, false));
    try std.testing.expect(composerFlip(false, 0, 400, true));
}

pub const Shape = enum { compact, expanded };

/// The pill's corners, docked or on a new chat (`COMPOSER_RADIUS`, 16
/// since 0fe89ff0a).
pub const radius: f32 = 16;

/// `TEXTAREA_MIN`, and the expanded pill it gives (`COMPOSER_MIN_HEIGHT`).
pub const textarea_min: f32 = 60;
pub const expanded_min: f32 = textarea_min + 42 + 2;

pub fn pill(c: *ui.Context, a: *App, k: theme.Colors, w: f32, shape: Shape, corner: f32) void {
    @import("view_composer_completion.zig").menu(c, a, k, w);
    // `border_1` takes its point from inside the box in GPUI: the pill is
    // 49 tall compact (`COMPACT_TOTAL_HEIGHT`), 60 + 42 + 2 = 104 expanded
    // (`COMPOSER_MIN_HEIGHT`), its controls a point in from each edge.
    // The accent at 0.55 while the field has the keys (`pill_border`); the
    // field's id is last frame's, which `keepFocus` keeps current.
    if (a.view.focus_composer and a.view.composer_id != 0) c.focus = a.view.composer_id;
    const focused = a.view.composer_id != 0 and c.focus == a.view.composer_id;
    const edge = if (focused) k.accent.alpha(0.55) else k.border;
    ui.key(c, "composer-surface");
    //0.2.172 keeps the writing plane opaque over a glass shell. Use the
    // selected theme before the shell's translucent material is applied.
    const fill = if (k.frosted) theme.colors(k.dark).pill() else k.pill();
    const p = kit.shadowLg(ui.div(c).w(w).bg(fill).border(edge).borderW(1).rounded(corner).p(1)).bg(fill).clip();
    const box = if (shape == .compact) p.column().h(49) else p.column();
    defer box.end();
    // The whole writing plane focuses the input, including its padding.
    // Picker controls keep their own focus when they open.
    if (box.clicked() and a.picker == .none and !a.view.write_open) {
        a.view.focus_composer = true;
        c.selection.clear();
    }
    if (c.rects.get(c.node(box.index).id)) |r| a.view.composer_anchor = r else if (a.window == null) c.animationFrame();
    if (shape == .expanded) attachmentStrip(c, a, k, w);
    {
        // Keep the field's keyed ancestry in both shapes. Only styles and
        // neighboring controls change: focus, selection, undo and caret do
        // not need to be recreated when the first newline expands the pill.
        ui.key(c, "composer-text-area");
        const area = if (shape == .compact)
            ui.div(c).row().wFull().h(47).px(8).itemsCenter()
        else
            ui.div(c).row().wFull();
        if (shape == .expanded) c.node(area.index).style.min_height = textarea_min;
        defer area.end();
        if (shape == .compact) attachButtons(c, a, k);
        {
            ui.key(c, "composer-text-inner");
            const base = ui.div(c).column().grow().w(0);
            // Preserve GPUI's expanded baseline and bare-field padding.
            const inner = if (shape == .compact) base else base.px(16).pt(16 - 1.5).pb(4 + 1.5 - 4);
            defer inner.end();
            input(c, a, k, shape);
        }
        if (shape == .compact) send(c, a, k);
    }
    if (shape == .compact) return;
    // Expanded: attach (and the mic) at the start, Send at the end.
    const actions = ui.div(c).row().wFull().h(42).px(12).pt(2).pb(8).itemsCenter();
    defer actions.end();
    attachButtons(c, a, k);
    // Keep the expand button mounted whenever the composer is expanded
    // (`fixed_write_button_survives_focus_blur` in `Nano/FrameSchedule.lean`),
    // so `ui.textField` blurring `c.focus` on `mouseDown` never unmounts
    // `composer-write` before `mouseUp` completes `clicked()`.
    _ = c.leaf(.{ .width = .{ .px = 2 } }, .none, null);
    @import("view_write.zig").button(c, a, k);
    if (a.view.write_open) a.view.focus_composer = false;
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
    const base = ui.div(c).row().size(28, 28).center().roundedFull().circular();
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
    const box = if (shape == .compact) ui.div(c).row().wFull().px(8).pt(1).itemsCenter() else ui.div(c).column().wFull();
    defer box.end();
    const placeholder = if (a.engine.state != .connected)
        @import("engine_start.zig").waiting(a)
    else if (a.queue_edit != null)
        "Edit queued message…"
    else
        "Do anything…";
    attachments.paste(c, a);
    const field_id = c.peekId(null);
    keepFocus(c, a, field_id);
    // Native popup keys precede the field's Tab traversal and Return submit.
    _ = @import("view_composer_completion.zig").keys(c, a);
    @import("composer_completion.zig").beforeEdit(a, c);
    const prev_edit = c.edits.get(field_id);
    const prev_caret: ?usize = if (prev_edit) |e| e.caret else null;
    const prev_anchor: ?usize = if (prev_edit) |e| e.anchor else null;
    const viewport = transcript_view.paneHeight(c, a) orelse c.size.h;
    const max_lines: u16 = @intFromFloat(@max(1, @min(11, @floor(viewport * 0.35 / 22.75))));
    const field_index: u32 = @intCast(c.nodes.items.len);
    const r = ui.textField(c, &a.composer, .{
        .placeholder = placeholder,
        .width = .fill,
        .bare = true,
        .size = 14,
        // GPUI's composer: 22.75-point lines; with mentions on, its
        // placeholder is muted, not faint (`ComposerInput::render`).
        .line_height = 22.75,
        .placeholder_color = k.muted,
        .multiline = true,
        .max_lines = if (shape == .compact) 1 else max_lines,
        .caret = message_caret,
        .caret_color = k.accent,
    });
    c.node(field_index).style.scroll_bar = false;
    _ = c.scrollbars.remove(field_id);
    _ = c.anims.remove(field_id);
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
    // "Send messages with" (Settings › Shortcuts): Enter sends, or starts a
    // new line and ⌘↩ sends (`composerSendBehavior`).
    a.view.composer_caret = r.caret;
    @import("composer_completion.zig").afterEdit(a, c, r.changed);
    const on_enter = @import("view_settings_shortcuts.zig").sendsOnEnter(a);
    if (r.submitted) {
        // Shift-Return is always a newline. The field owns this translation,
        // but keep the app boundary safe if a native submit arrives with the
        // modifier still set: it must never send the draft.
        if (on_enter and !c.input.shift) {
            a.send();
        } else {
            _ = a.composer.insert(r.caret, "\n");
            a.composer.want_caret = r.caret + 1;
        }
    }
    // ⌘↩ with something typed sends; with Enter sending, during a run it
    // takes the other follow-up, as ⌘⌥↩ always does (`on_modified_submit`,
    // `on_follow_up_shortcut`).
    const queue_mod = @import("app_queue.zig");
    const has_content = std.mem.trim(u8, a.composer.text(), " \n\t").len > 0 or attachments.count(a) > 0;
    const other = queue_mod.opposite(queue_mod.followUpBehavior(a));
    if (has_content and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) {
        if (on_enter and a.queues() and a.queue_edit == null) a.sendFollowUp(other) else a.send();
    }
    if (has_content and a.queues() and a.queue_edit == null and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true, .alt = true })) {
        a.sendFollowUp(other);
    }
    recall(c, a, field_id);
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

/// The message caret (composer.rs, the input's paint: "a rounded accent
/// bar, inset from the line box"): 3 points wide, 2 short of the line box
/// top and bottom, 1.5 round, in the primary accent (the user's accent
/// override included). It blinks at 500 ms and is solid after an edit or
/// a caret move, as nanoui's caret already does.
/// GPUI's insertion caret: a hairline on the glyph, not a 3-point block.
pub const message_caret: ui.TextFieldCaret = .{ .width = 1.5, .inset = 1, .radius = 0.75 };

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
    if (next) |t| {
        a.composer.set(t);
        c.selection.clear();
    }
}

/// The composer has the keys after the window moves to another chat, pane
/// or tab (`focus_composer`), and keeps them when its field moves in the
/// layout (into a split's pane, or taller with a second line), which
/// gives the field another id.
fn keepFocus(c: *ui.Context, a: *App, id: u64) void {
    const moved = a.view.composer_id != 0 and id != a.view.composer_id and c.focus == a.view.composer_id;
    a.view.composer_frame = c.frame;
    if (a.view.focus_composer or moved) {
        const pill_unfocused = a.view.composer_id == 0 or c.focus != a.view.composer_id;
        c.focus = id;
        if (pill_unfocused) c.changed = true;
        a.view.focus_composer = false;
    }
    a.view.composer_id = id;
}

/// The model chip: what the next message runs on, 24 tall at the footer's
/// leading edge (`PickerKind::HarnessModel`'s trigger). Returns the width
/// it takes this frame, for the footer to share out the rest.
pub fn chip(c: *ui.Context, a: *App, k: theme.Colors) f32 {
    const mp = @import("model_picker.zig");
    const t = a.target();
    const room = @max(80, transcript_view.paneWidth(c, a) - 32 - 100);
    const max_chip_w = @min(248, room);
    const chat_harness = if (a.selected) |id| (if (a.findChat(id)) |ch| ch.harness != null else false) else false;
    const unresolved = a.harnesses.items.len == 0 and !chat_harness and a.harnesses_failed;
    const label_loading = !unresolved and a.models.items.len == 0 and t.model == null;
    const failed = if (label_loading) (if (a.view.model_picker.catalogs.get(t.harness)) |cat| cat.failed else false) else false;
    const label_text = if (!unresolved and !label_loading) a.modelLabel(t.model) else "";
    const suffix_text: ?[]const u8 = if (!unresolved and !label_loading) (if (t.reasoning) |level| rules.reasoningLabel(level) else null) else null;
    const st_measure: ui.TextStyle = .{ .size = 12, .line_height = 12 * 1.618, .weight = theme.ui_medium_weight };
    var wanted_w: f32 = 12 + 16;
    if (!unresolved) {
        if (label_loading) {
            if (!failed) wanted_w += 6 + 56;
        } else {
            wanted_w += 6 + @ceil(c.text.width(label_text, st_measure));
            if (suffix_text) |sfx| wanted_w += 6 + @ceil(c.text.width(sfx, st_measure));
        }
    }
    const target_w = @min(wanted_w, max_chip_w);
    const width_sample = mp.ScalarTransition.sample(&a.view.model_picker.chip_width, target_w, c.time, c.reduced_motion);
    if (width_sample.moving) c.frameIn(1.0 / 120.0);

    var base = ui.div(c).row().h(24).maxW(max_chip_w).px(6).gap(6).itemsCenter().rounded(8).clip();
    if (width_sample.moving) base = base.w(width_sample.value);
    // At rest it is its content: the glyph (the 5-point loader until an
    // agent is known) in its insets, the label's gap (kept even for no
    // label), and the words.
    const glyph_w: f32 = if (!unresolved and a.harnesses.items.len == 0 and !chat_harness) 5 else 16;
    const drawn_w = if (width_sample.moving) @min(width_sample.value, max_chip_w) else @min(@max(wanted_w - 16, 12 + 6) + glyph_w, max_chip_w);
    // GPUI's trigger uses on_hover: closing by keyboard doesn't move the
    // pointer and must not clear the wash until the pointer actually moves.
    const b = kit.listenerHover(&a.view.hovers, if (a.picker != .none) base.bg(k.hover) else base, k.hover).div;
    defer b.end();
    if (b.clicked()) a.togglePickerCompact();
    if (c.rects.get(c.node(b.index).id)) |r| a.view.chip_anchor = r;
    // Before the engine lists them: the glyph spinner for an agent not yet
    // known (an open chat's is: its own), a pulsing bar for its model
    // (`trigger_chip` loading, `chip_icon_loading`).
    // The list failed and nothing names an agent: GPUI's `effective_harness`
    // is none, so a muted terminal and no label, not a loader.
    // Its label is always a child, empty or not, so its gap stays.
    if (unresolved) {
        icons.icon(c, .terminal, 16, k.muted, 0);
        _ = c.leaf(.{ .width = .{ .px = 0 } }, .none, null);
        return drawn_w;
    }
    if (a.harnesses.items.len == 0 and !chat_harness) {
        kit.snake(c, k);
    } else if (chipMaker(a)) |maker| {
        // With the two-step picker, the model's maker names it, untinted
        // (muted); the agent's mark only when no maker is known (pickers.rs
        // `model_maker`/`maker_icon` over `model_chip_icon`).
        icons.icon(c, maker, 16, k.muted, 0);
    } else {
        const mark = icons.harnessMark(t.harness);
        icons.icon(c, mark.name, 16, mark.brand orelse k.muted, 0);
    }
    if (label_loading) {
        // A failed catalog has nothing to name: no label, no ghost bar.
        if (failed) _ = c.leaf(.{ .width = .{ .px = 0 } }, .none, null) else skeleton(c);
        return drawn_w;
    }
    // `hover_blend`: the label brightens under the pointer, rolling Scritto-style when changed.
    // Re-read after `togglePickerCompact` in case opening the picker synced `a.models`.
    const live_t = a.target();
    const live_label = if (!unresolved and !label_loading) a.modelLabel(live_t.model) else label_text;
    const live_suffix: ?[]const u8 = if (!unresolved and !label_loading) (if (live_t.reasoning) |level| rules.reasoningLabel(level) else null) else suffix_text;
    kit.rollText(c, "composer-model-label", live_label, .{ .size = 12, .line_height = 12 * 1.618, .weight = theme.ui_medium_weight, .color = if (b.hovered()) k.text else k.text.alpha(0.9) });
    if (live_suffix) |sfx| kit.rollText(c, "composer-effort-suffix", sfx, .{ .size = 12, .line_height = 12 * 1.618, .weight = theme.ui_medium_weight, .color = k.muted.alpha(0.7) });
    return drawn_w;
}

/// Whether the footer has a follow-up switch to draw.
pub fn followUpShown(a: *const App) bool {
    return @import("app_queue.zig").targetSteersMidTurn(a);
}

/// "Steer" or "Queue", as the follow-up switch says it.
pub fn followUpLabel(a: *const App) []const u8 {
    return if (@import("app_queue.zig").followUpBehavior(a) == .steer) "Steer" else "Queue";
}

/// Follow-up mode switch in the composer footer: shows whether a message
/// sent during a live turn will Steer or Queue, and toggles on click.
/// `glyph_only` leaves its word to the tooltip where the footer is narrow.
pub fn followUpChip(c: *ui.Context, a: *App, k: theme.Colors, glyph_only: bool) void {
    const queue_mod = @import("app_queue.zig");
    if (!followUpShown(a)) return;
    const mode = queue_mod.followUpBehavior(a);
    const is_steer = mode == .steer;
    const hint = if (is_steer)
        "Follow-ups steer into the active turn. Click to queue for the next turn"
    else
        "Follow-ups wait in the queue until the turn finishes. Click to steer immediately";
    ui.key(c, "composer-follow-up-chip");
    var b = ui.div(c).row().h(20).px(8).gap(5).itemsCenter().rounded(6).hover(k.hover);
    b = @import("view_tooltip.zig").on(b, k, .{ .text = hint });
    defer b.end();
    const hot = b.hovered();
    const color = if (hot) k.text.alpha(0.85) else if (is_steer) k.text.alpha(0.78) else k.muted.alpha(0.7);
    icons.icon(c, if (is_steer) .@"fast-tier" else .@"queue-drag-handle", 12, color, 0);
    if (!glyph_only) ui.text(c, followUpLabel(a), .{
        .size = 12,
        .line_height = 12 * 1.618,
        .weight = theme.ui_medium_weight,
        .color = color,
    });
    if (b.clicked()) queue_mod.toggleFollowUp(a);
}

/// The selected model's maker mark, or the catalog's first model's when
/// none is picked, as the label resolves it.
fn chipMaker(a: *App) ?icons.Name {
    const mp = @import("model_picker.zig");
    const t = a.target();
    const list = mp.modelsFor(a, t.harness);
    const id = t.model orelse (if (list.len > 0) list[0].id else return null);
    for (list) |m| if (std.mem.eql(u8, m.id, id)) return mp.makerIcon(m);
    return null;
}

/// A label still loading: a 56 by 11 bar whose opacity breathes between
/// 0.35 and 0.75 every 2.4 s (popover.rs `skeleton_bar`).
fn skeleton(c: *ui.Context) void {
    const phase = @sin(@as(f32, @floatCast(c.time)) * std.math.tau / 2.4) * 0.5 + 0.5;
    kit.loaderFrame(c, 1.0 / 30.0);
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
    // Filled with the primary accent, its glyph contrast-checked on it
    // (`render_send_button`, `on_primary_accent`). `.circular()` renders a
    // true analytical Euclidean circle rather than a squircle polygon.
    var b = ui.div(c).row().size(28, 28).center().roundedFull().circular().bg(k.accent);
    b = b.opacity(if (blocked) 0.35 else if (b.hovered()) 0.85 else 1);
    defer b.end();
    if (b.clicked() and !blocked and (stop or !empty)) {
        if (stop) a.interrupt() else a.send();
    }
    if (stop) {
        _ = c.leaf(.{ .width = .{ .px = 11 }, .height = .{ .px = 11 }, .radius = 3, .background = k.onAccent() }, .none, null);
    } else {
        icons.icon(c, .@"arrow-up", 14, k.onAccent(), 0);
    }
}

const jump_show: f32 = 320;
const jump_hide: f32 = 70;

/// GPUI's labeled pill, six pixels above the composer (`render_jump_to_bottom`
/// uses `top(-36)` on a 30-point chip). Shown once the reader is 320 points
/// off the end, and kept until they are within 70.
fn jumpToBottom(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const box = a.view.jump_box;
    if (box == 0) return;
    const show = if (a.view.jump_shown) a.view.jump_distance > jump_hide else a.view.jump_distance > jump_show;
    a.view.jump_shown = show;
    if (!show) return;
    ui.key(c, "jump-to-bottom");
    const row = ui.div(c).row().absolute().offset(0, -36).w(w).justifyCenter();
    defer row.end();
    const jump_chip = kit.shadowLg(ui.div(c).row().h(30).pl(11).pr(13).gap(6).itemsCenter().rounded(15).circular().bg(k.composer).border(k.border).borderW(1));
    defer jump_chip.end();
    icons.icon(c, .@"alt-arrow-down", 13, k.muted, 0);
    ui.text(c, "Scroll to bottom", kit.style(c, 13, 18, .{ .color = k.text }));
    if (jump_chip.clicked()) {
        c.scroll.put(c.gpa, box, std.math.floatMax(f32)) catch {};
        c.scroll_follow.put(c.gpa, box, true) catch {};
        a.view.jump_shown = false;
        a.view.jump_distance = 0;
        c.changed = true;
    }
}
