//! Settings › Shortcuts, as the GPUI app's (settings/shortcuts.rs,
//! settings/completion.rs): how Enter sends, composer completion, every
//! rebindable shortcut by group (click its chip, press the keys), the
//! window's fixed keys, and Escape stopping the agent. Rebinding writes the
//! GPUI app's own `keymap`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const set = @import("view_settings.zig");
const shortcuts = @import("shortcuts.zig");
const App = @import("app.zig").App;

/// While a chip waits for keys: the next combination is the shortcut's
/// (Escape cancels). The window's own keys stand aside meanwhile.
pub fn recording(a: *const App) bool {
    return a.view.settings_open and a.view.recording != null;
}

/// From the window's keys, first thing each frame: a combination pressed
/// while a chip records.
pub fn capture(c: *ui.Context, a: *App) void {
    const ix = a.view.recording orelse return;
    const s = c.input.shortcut orelse return;
    if (s.key == ui.Shortcut.escape and !s.cmd and !s.ctrl and !s.alt) {
        _ = c.shortcut(s);
        a.view.recording = null;
        return;
    }
    var buf: [64]u8 = undefined;
    const combo = shortcuts.fromShortcut(&buf, s) orelse {
        _ = c.shortcut(s);
        return refuse(a, "Use Control, Option or Command with a letter, number, function key or navigation key.");
    };
    _ = c.shortcut(s);
    var shown: [64]u8 = undefined;
    if (shortcuts.reserved(combo)) return refuse(a, c.print("{s} is reserved for the composer.", .{shortcuts.display(&shown, combo)}));
    // One past the page's shortcuts: the Appshots page's.
    for (shortcuts.all ++ [_]shortcuts.Shortcut{shortcuts.appshot}, 0..) |other, j| if (j != ix and std.mem.eql(u8, a.settings.combo(other), combo)) {
        return refuse(a, c.print("{s} is already assigned to {s}.", .{ shortcuts.display(&shown, combo), other.title }));
    };
    a.settings.setCombo(if (ix == shortcuts.all.len) shortcuts.appshot else shortcuts.all[ix], combo);
    a.view.recording = null;
    a.view.shortcut_notice.clearRetainingCapacity();
}

fn refuse(a: *App, why: []const u8) void {
    a.view.recording = null;
    a.view.shortcut_notice.clearRetainingCapacity();
    a.view.shortcut_notice.appendSlice(a.gpa, why) catch {};
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    header(c, a, k);
    sendCard(c, a, k);
    set.space(c, 28);
    completion(c, a, k);
    set.space(c, 28);
    {
        const groups = ui.div(c).column().wFull().gap(28);
        defer groups.end();
        inline for (comptime std.enums.values(shortcuts.Group)) |g| group(c, a, k, g);
        fixedGroup(c, k);
    }
    {
        set.space(c, 12);
        const h = ui.div(c).row().wFull().px(4).itemsCenter();
        defer h.end();
        strut(c, 20);
        const note = if (a.view.recording != null) "Press Escape to cancel." else if (a.view.shortcut_notice.items.len > 0) a.view.shortcut_notice.items else "Shortcuts must be unique.";
        ui.text(c, note, set.st(c, 12, .{ .color = k.muted }));
    }
    escapeCard(c, a, k);
}

fn header(c: *ui.Context, a: *App, k: theme.Colors) void {
    const r = ui.div(c).row().wFull().gap(24);
    defer r.end();
    {
        const left = ui.div(c).column().grow().w(0);
        defer left.end();
        set.header(c, k, "Keyboard shortcuts", null);
        set.subtitle(c, k, "Click a binding, then press the key combination you want to use. Changes apply immediately and stay on this device.", true);
    }
    const changed = a.settings.keymapChanged() or a.settings.get(.escape_stops_active_agent) or !sendsOnEnter(a);
    const live = changed and a.view.recording == null;
    var b = ui.div(c).row().px(10).py(6).gap(6).itemsCenter().rounded(8);
    if (live) b = b.hover(k.ink(0.04)) else b = b.opacity(0.35);
    defer b.end();
    const hot = live and b.hovered();
    icons.icon(c, .restart, 14, if (hot) k.text else k.muted, 0);
    ui.text(c, "Restore defaults", set.st(c, 12, .{ .color = if (hot) k.text else k.muted }));
    if (live and b.clicked()) {
        a.settings.resetKeymap();
        a.settings.set(.escape_stops_active_agent, false);
        a.settings.setText("composerSendBehavior", "enter");
        a.view.shortcut_notice.clearRetainingCapacity();
    }
}

pub fn sendsOnEnter(a: *const App) bool {
    const v = a.settings.text("composerSendBehavior") orelse return true;
    return !std.mem.eql(u8, v, "mod-enter");
}

/// A card holding one tall row: a title, a quiet line, and a control.
fn tallRow(c: *ui.Context, k: theme.Colors, title: []const u8, copy: []const u8, trailing: f32) MinRow {
    // `card_row` (14 above and below) with `min_h(84)` on its box.
    const r = minRow(c, 84 - 28, 20, 14, 14);
    {
        const w = ui.div(c).column().w(@max(set.inner_w - 2 - 40 - 14 - trailing, 80));
        defer w.end();
        ui.text(c, title, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
        set.space(c, 4);
        const d = ui.div(c).column().w(@min(430, set.inner_w - 2 - 40 - 14 - trailing));
        defer d.end();
        ui.text(c, copy, .{ .size = 11.5, .line_height = 17, .wrap = true, .color = k.muted.alpha(0.65) });
    }
    return r;
}

fn sendCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.space(c, 32 - 24);
    const cd = set.card(c, k);
    defer cd.end();
    const r = tallRow(c, k, "Send messages with", "Choose whether Enter sends immediately or starts a new paragraph. Cmd/Ctrl+Enter always submits; with an empty composer it sends the most recently queued message. Shift+Enter always inserts a line break.", 170);
    defer r.end();
    ui.spacer(c);
    const on_enter = sendsOnEnter(a);
    const ctl = ui.div(c).row().gap(10).itemsCenter();
    defer ctl.end();
    if (!on_enter) {
        const reset = ui.div(c).row().size(26, 26).center().rounded(7).hover(k.ink(0.04));
        defer reset.end();
        icons.icon(c, .restart, 13, k.muted, 0);
        if (reset.clicked()) a.settings.setText("composerSendBehavior", "enter");
    }
    const track = ui.div(c).row().p(2).rounded(9).bg(k.ink(0.04));
    defer track.end();
    inline for (.{ .{ "Enter", "enter", true }, .{ "⌘ Enter", "mod-enter", false } }) |opt| {
        const selected = on_enter == opt[2];
        var seg = ui.div(c).row().minW(72).px(12).py(6).rounded(7).justifyCenter();
        // The selected one's border is outside, as GPUI's: a point larger.
        seg = if (selected) seg.bg(k.background).border(k.border.alpha(0.8)).borderW(1).p(1).px(13).py(7) else seg;
        defer seg.end();
        const hot = seg.hovered();
        ui.text(c, opt[0], .{ .size = 12, .line_height = 12 * 1.618, .mono = true, .color = if (selected or hot) k.text else k.muted });
        if (!selected and seg.clicked()) a.settings.setText("composerSendBehavior", opt[1]);
    }
}

fn completion(c: *ui.Context, a: *App, k: theme.Colors) void {
    const box = ui.div(c).column().wFull().gap(12);
    defer box.end();
    {
        const h = ui.div(c).column().wFull().gap(4);
        defer h.end();
        set.fieldLabel(c, k, "Composer completion");
        const s = ui.div(c).column().w(@min(set.inner_w, 512));
        defer s.end();
        ui.text(c, "For active agents on this device. Completion preferences apply across your devices.", .{ .size = 13, .line_height = 20, .wrap = true, .color = k.muted });
    }
    if (a.harnesses.items.len > 0) {
        // Per-agent switches ($ for skills, / commands) aren't here yet.
        set.subtitle(c, k, "Completion for each agent isn't in Harness Nano yet: set it in Harness.", false);
        return;
    }
    const r = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer r.end();
    {
        const l = ui.div(c).column();
        defer l.end();
        set.space(c, 4);
        ui.text(c, "Unable to load active agents.", set.st(c, 13, .{ .color = k.muted }));
    }
    const retry = ui.div(c).row().px(11).py(7).rounded(8);
    defer retry.end();
    ui.text(c, "Retry", set.st(c, 12, .{ .color = k.muted }));
    if (retry.clicked()) a.request(@import("requests.zig").none("ListHarnesses"), .of(App, a, App.onNotice));
}

fn group(c: *ui.Context, a: *App, k: theme.Colors, comptime g: shortcuts.Group) void {
    const box = ui.div(c).column().wFull().gap(8);
    defer box.end();
    set.fieldLabel(c, k, g.label());
    const cd = ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
    defer cd.end();
    var first_row = true;
    for (shortcuts.all, 0..) |sc, ix| if (sc.group == g) {
        ui.key(c, c.print("sc-{d}", .{ix}));
        if (!first_row) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        row(c, a, k, sc, ix, first_row);
        first_row = false;
    };
}

fn row(c: *ui.Context, a: *App, k: theme.Colors, sc: shortcuts.Shortcut, ix: usize, first: bool) void {
    // GPUI's separator is the row's top border, inside its 72.
    const r = minRow(c, if (first) 72 else 71, 20, 0, 20);
    defer r.end();
    {
        const w = ui.div(c).column().w(@max(set.inner_w - 2 - 40 - 20 - 96 - 70, 80));
        defer w.end();
        ui.text(c, sc.title, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
        set.space(c, 2);
        ui.text(c, sc.description, set.st(c, 12, .{ .wrap = true, .color = k.muted }));
    }
    ui.spacer(c);
    const combo = a.settings.combo(sc);
    const recording_this = a.view.recording == ix;
    if (!recording_this and !std.mem.eql(u8, combo, sc.default)) {
        const reset = ui.div(c).row().itemsCenter();
        defer reset.end();
        strut(c, 24);
        const hot = reset.hovered();
        ui.text(c, "Reset", set.st(c, 11, .{ .color = if (hot) k.text else k.muted.alpha(0.7) }));
        if (reset.clicked()) a.settings.setCombo(sc, null);
    }
    var chip = ui.div(c).row().minW(96).px(13).py(7).rounded(8).justifyCenter().borderW(1);
    chip = if (recording_this) chip.bg(k.text).border(k.text.alpha(0.3)) else chip.bg(k.background).border(k.border).hover(k.ink(0.03));
    defer chip.end();
    var buf: [64]u8 = undefined;
    const label = if (recording_this) "Press keys…" else shortcuts.display(&buf, combo);
    ui.text(c, c.print("{s}", .{label}), .{ .size = 12, .line_height = 12 * 1.618, .mono = true, .color = if (recording_this) k.on_solid else k.text });
    if (chip.clicked()) {
        a.view.recording = if (recording_this) null else ix;
        a.view.shortcut_notice.clearRetainingCapacity();
    }
}

fn fixedGroup(c: *ui.Context, k: theme.Colors) void {
    const box = ui.div(c).column().wFull().gap(8);
    defer box.end();
    set.fieldLabel(c, k, shortcuts.fixed_label);
    const cd = ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
    defer cd.end();
    for (shortcuts.fixed, 0..) |f, i| {
        if (i > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        const r = minRow(c, if (i == 0) 48 else 47, 20, 0, 20);
        defer r.end();
        ui.text(c, f.title, set.st(c, 13, .{ .color = k.text }));
        ui.spacer(c);
        ui.text(c, f.keys, .{ .size = 12, .line_height = 12 * 1.618, .mono = true, .color = k.muted });
    }
}

fn escapeCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const cd = set.card(c, k);
    defer cd.end();
    const r = tallRow(c, k, "Stop active agent with Escape", "When no dialog, menu, picker, or terminal handles Escape, stop the agent in the active session.", 40);
    defer r.end();
    ui.spacer(c);
    if (set.toggle(c, k, a.settings.get(.escape_stops_active_agent), true)) a.settings.toggle(.escape_stops_active_agent);
}

/// A strut with no width: its row is at least `h` tall. Only in rows
/// without a gap, or the gap would push what follows along.
fn strut(c: *ui.Context, h: f32) void {
    _ = c.leaf(.{ .width = .{ .px = 0 }, .height = .{ .px = h } }, .none, null);
}

/// A row at least `h` tall (`min_h`), its children `gap` apart: a strut
/// beside an inner row that takes the rest.
const MinRow = struct {
    outer: ui.Div,
    inner: ui.Div,
    fn end(m: MinRow) void {
        m.inner.end();
        m.outer.end();
    }
};

fn minRow(c: *ui.Context, h: f32, px: f32, py: f32, gap: f32) MinRow {
    const outer = ui.div(c).row().wFull().px(px).py(py).itemsCenter();
    strut(c, h);
    return .{ .outer = outer, .inner = ui.div(c).row().grow().w(0).gap(gap).itemsCenter() };
}
