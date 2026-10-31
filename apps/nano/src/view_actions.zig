//! Project actions in the title bar (crates/ui/src/shell/actions_ui.rs):
//! "+ Add action" until the project has one, then the preferred action
//! (click runs it) and a chevron for the menu of them all; the editor
//! dialog adds or changes one; runs show in the dock under the chat.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const actions = @import("app_actions.zig");
const question = @import("view_question.zig");
const App = @import("app.zig").App;

pub fn iconOf(name: []const u8) icons.Name {
    const pairs = .{
        .{ "play", icons.Name.@"action-play" },   .{ "test", icons.Name.@"action-test" },
        .{ "lint", icons.Name.@"action-lint" },   .{ "configure", icons.Name.@"action-configure" },
        .{ "build", icons.Name.@"action-build" }, .{ "debug", icons.Name.@"action-debug" },
    };
    inline for (pairs) |p| if (std.mem.eql(u8, name, p[0])) return p[1];
    return .@"action-play";
}

/// The control's width, so the title bar can place it.
pub fn controlWidth(c: *ui.Context, a: *const App) f32 {
    const x = &a.actions;
    if (x.status == .idle or x.status == .loading or x.status == .unsupported) return 0;
    const label: []const u8 = if (actions.preferred(a)) |p| p.name else if (x.status == .unavailable) "Actions unavailable" else "Add action";
    const text_w = @min(c.text.width(label, .{ .size = 11.5 }), 150);
    return 7 + 13 + 5 + text_w + 7 + (if (x.list.len > 0) @as(f32, 23) else 0) + 2;
}

pub fn control(c: *ui.Context, a: *App, k: theme.Colors) void {
    const x = &a.actions;
    if (controlWidth(c, a) == 0) return;
    // `border_1` inside the box, as GPUI's: the segments a point in.
    const frame = ui.div(c).row().h(24).rounded(6).border(k.border).borderW(1).p(1).clip();
    defer frame.end();
    if (c.rects.get(c.node(frame.index).id)) |r| x.anchor = r;
    if (actions.preferred(a)) |p| {
        {
            const seg = segment(c, k);
            defer seg.end();
            if (seg.clicked() and x.status == .ready) actions.run(a, p);
            icons.icon(c, iconOf(p.icon), 13, k.muted, 0);
            kit.fadeText(c, p.name, .{ .size = 11.5, .color = k.text.alpha(0.9) }, 150);
        }
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
        const chev = ui.div(c).row().w(23).hFull().center().hover(k.ink(0.07));
        defer chev.end();
        if (chev.clicked()) x.menu = !x.menu;
        icons.icon(c, .@"alt-arrow-down", 11, k.muted, 0);
        return;
    }
    const seg = segment(c, k);
    defer seg.end();
    if (x.status == .unavailable) {
        if (seg.clicked()) x.menu = !x.menu;
        icons.icon(c, .@"danger-triangle", 13, k.danger, 0);
        ui.text(c, "Actions unavailable", .{ .size = 11.5, .color = k.text.alpha(0.9) });
        return;
    }
    if (seg.clicked()) actions.openEditor(a, null);
    icons.icon(c, .plus, 13, k.muted, 0);
    ui.text(c, "Add action", .{ .size = 11.5, .color = k.text.alpha(0.9) });
}

fn segment(c: *ui.Context, k: theme.Colors) ui.Div {
    return ui.div(c).row().hFull().px(7).gap(5).itemsCenter().hover(k.ink(0.07));
}

/// The menu under the control, and the editor dialog.
pub fn overlays(c: *ui.Context, a: *App, k: theme.Colors) void {
    const x = &a.actions;
    if (x.menu) if (x.anchor) |r| menu(c, a, k, r);
    if (x.editor != null) editor(c, a, k);
}

fn menu(c: *ui.Context, a: *App, k: theme.Colors, r: ui.Rect) void {
    const x = &a.actions;
    {
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer back.end();
        if (back.clicked()) {
            x.menu = false;
            return;
        }
    }
    const w: f32 = 280;
    const m = kit.shadowLg(ui.div(c).fixed().offset(@min(r.x, c.size.w - w - 8), r.y + r.h + 6).w(w).layer(5).column().p(4).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12));
    defer m.end();
    {
        const h = ui.div(c).row().px(8).pt(6).pb(4);
        defer h.end();
        ui.text(c, "PROJECT ACTIONS", .{ .size = 10, .weight = .medium, .color = k.muted });
    }
    if (x.status == .unavailable) {
        const e = ui.div(c).column().wFull().px(8).py(6);
        if (x.error_text) |t| ui.text(c, t, kit.style(c, 12, 17, .{ .wrap = true, .color = k.danger }));
        e.end();
        if (row(c, k, .refresh, "Retry", false)) {
            x.status = .idle;
            actions.refresh(a);
        }
    }
    for (x.list) |act| {
        ui.key(c, c.print("act-{s}", .{act.id}));
        const label = if (act.setup) c.print("{s} (setup)", .{act.name}) else act.name;
        const rr = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7).hover(k.selected);
        defer rr.end();
        const run_clicked = rr.clicked();
        icons.icon(c, iconOf(act.icon), 15, k.muted, 0);
        ui.text(c, label, .{ .size = 13, .color = k.text });
        ui.spacer(c);
        if (kit.iconButton(c, k, .@"settings-minimalistic", .{ .size = 22, .radius = 5, .icon = 14 })) {
            actions.openEditor(a, act);
            return;
        }
        if (run_clicked) return actions.run(a, act);
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    if (row(c, k, .plus, "Add action", false)) actions.openEditor(a, null);
}

fn row(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8, on: bool) bool {
    var r = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7).hover(k.selected);
    if (on) r = r.bg(k.selected);
    defer r.end();
    icons.icon(c, icon, 15, k.muted, 0);
    ui.text(c, label, .{ .size = 13, .color = k.text });
    return r.clicked();
}

fn editor(c: *ui.Context, a: *App, k: theme.Colors) void {
    const x = &a.actions;
    const e = &x.editor.?;
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) return actions.closeEditor(a);
    {
        const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(6).bg(.{ .a = 0.35 });
        defer scrim.end();
        if (scrim.clicked()) return actions.closeEditor(a);
    }
    const w: f32 = 440;
    const card = kit.shadowLg(ui.div(c).fixed().offset((c.size.w - w) / 2, @max(40, c.size.h * 0.18)).w(w).layer(7).column().p(20)
        .bg(k.composer).border(k.wash(0.10)).borderW(1).rounded(16));
    defer card.end();
    if (e.confirm_delete) return confirmDelete(c, a, k, e);
    ui.text(c, if (e.id == null) "Add action" else "Edit action", .{ .size = 15, .weight = .semibold, .color = k.text });
    fieldLabel(c, k, "Name");
    const name_at = c.nodes.items.len;
    field(c, k, &e.name, "Action name", false);
    if (e.want_focus) {
        // The field's frame is built first, the text field's box right after.
        if (name_at + 1 < c.nodes.items.len) c.focus = c.node(@intCast(name_at + 1)).id;
        e.want_focus = false;
    }
    fieldLabel(c, k, "Command");
    const command_at = c.nodes.items.len;
    field(c, k, &e.command, "Command", true);
    // Tab and Shift-Tab move between the two fields.
    if (name_at + 1 < c.nodes.items.len and command_at + 1 < c.nodes.items.len) {
        const name_id = c.node(@intCast(name_at + 1)).id;
        const command_id = c.node(@intCast(command_at + 1)).id;
        // Tab arrives as a shortcut or as a key, as the platform sends it.
        const key_tab = c.input.key == .tab;
        const fwd = c.shortcut(.{ .key = ui.Shortcut.tab }) or (key_tab and !c.input.shift);
        const back = c.shortcut(.{ .key = ui.Shortcut.tab, .shift = true }) or (key_tab and c.input.shift);
        if (fwd and c.focus == name_id) c.focus = command_id;
        if (back and c.focus == command_id) c.focus = name_id;
    }
    fieldLabel(c, k, "Icon");
    {
        const tiles = ui.div(c).row().gap(6);
        defer tiles.end();
        for (actions.icons, 0..) |n, i| {
            ui.key(c, n);
            const on = e.icon == i;
            const t = ui.div(c).row().size(34, 34).center().rounded(7).border(if (on) k.muted else k.border).borderW(1).bg(k.ink(if (on) 0.10 else 0.03));
            defer t.end();
            if (t.clicked()) e.icon = i;
            icons.icon(c, iconOf(n), 16, if (on) k.text else k.muted, 0);
        }
    }
    {
        const cb = ui.div(c).row().pt(14).gap(8).itemsCenter();
        defer cb.end();
        if (cb.clicked()) e.setup = !e.setup;
        const box = ui.div(c).row().size(16, 16).center().rounded(4).border(k.border_strong).borderW(1);
        const filled = if (e.setup) box.bg(k.text) else box;
        if (e.setup) icons.icon(c, .check, 12, k.on_solid, 0);
        filled.end();
        ui.text(c, "Run automatically on worktree creation", .{ .size = 13, .color = k.text });
    }
    if (e.err) |msg| {
        const er = ui.div(c).row().pt(10);
        defer er.end();
        ui.text(c, msg, .{ .size = 12, .color = k.danger });
    }
    const foot = ui.div(c).row().wFull().pt(18).gap(8).itemsCenter();
    defer foot.end();
    if (e.id != null) {
        var del = ui.div(c).row().px(12).py(6).rounded(8).hover(k.ink(0.06));
        defer del.end();
        if (del.clicked()) e.confirm_delete = true;
        ui.text(c, "Delete action", .{ .size = 13, .color = k.danger });
    }
    ui.spacer(c);
    if (question.button(c, k, "Cancel", false, true)) return actions.closeEditor(a);
    if (question.button(c, k, if (e.saving) "Saving…" else "Save action", true, !e.saving)) actions.save(a);
}

fn confirmDelete(c: *ui.Context, a: *App, k: theme.Colors, e: *actions.Editor) void {
    ui.text(c, "Delete action?", .{ .size = 15, .weight = .semibold, .color = k.text });
    const body = ui.div(c).row().pt(8);
    ui.text(c, c.print("“{s}” will be permanently deleted.", .{std.mem.trim(u8, e.name.text(), " ")}), .{ .size = 13, .color = k.muted });
    body.end();
    const foot = ui.div(c).row().wFull().pt(18).gap(8).justifyEnd();
    defer foot.end();
    if (question.button(c, k, "Cancel", false, true)) e.confirm_delete = false;
    var del = ui.div(c).row().px(12).py(6).rounded(8).bg(k.danger);
    defer del.end();
    if (del.clicked()) actions.delete(a);
    ui.text(c, "Delete", .{ .size = 13, .weight = .medium, .color = .{ .r = 1, .g = 1, .b = 1 } });
}

fn fieldLabel(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const l = ui.div(c).row().pt(12).pb(5);
    defer l.end();
    ui.text(c, text, .{ .size = 12, .weight = .medium, .color = k.muted });
}

fn field(c: *ui.Context, k: theme.Colors, buf: *ui.TextBuffer, placeholder: []const u8, command: bool) void {
    const f = ui.div(c).column().wFull().px(12).py(8).rounded(8).bg(k.ink(0.04)).border(k.border).borderW(1).minW(0);
    const sized = if (command) f.h(88) else f;
    defer sized.end();
    _ = ui.textField(c, buf, .{ .placeholder = placeholder, .width = .fill, .bare = true, .size = 14, .multiline = command, .max_lines = 4 });
}

/// The dock under the chat: a tab per run, its output as a log.
pub fn dock(c: *ui.Context, a: *App, k: theme.Colors) void {
    const x = &a.actions;
    if (!x.dock_open or x.runs.items.len == 0) return;
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const d = ui.div(c).column().wFull().h(280).bg(k.background);
    defer d.end();
    {
        const strip = ui.div(c).row().wFull().h(32).px(8).gap(4).itemsCenter();
        defer strip.end();
        var close: ?usize = null;
        for (x.runs.items, 0..) |r, i| {
            ui.key(c, c.print("run-{d}", .{i}));
            const on = i == x.dock_active;
            var t = ui.div(c).row().h(24).px(8).gap(6).itemsCenter().rounded(6).opacity(if (r.exited != null) 0.55 else 1);
            t = if (on) t.bg(k.wash(0.10)) else t.hover(k.wash(0.06));
            defer t.end();
            if (t.clicked()) x.dock_active = i;
            icons.icon(c, .terminal, 12, k.muted, 0);
            ui.text(c, r.name, .{ .size = 11.5, .color = if (on) k.text else k.muted });
            const xb = ui.div(c).row().size(16, 16).center().rounded(4).hover(k.wash(0.12));
            defer xb.end();
            if (xb.clicked()) close = i;
            icons.icon(c, .close, 10, k.muted, 0);
        }
        if (close) |i| return actions.closeRun(a, i);
        ui.spacer(c);
        if (kit.iconButton(c, k, .close, .{ .size = 24, .icon = 12 })) x.dock_open = false;
    }
    const r = &x.runs.items[@min(x.dock_active, x.runs.items.len - 1)];
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .left = 14, .right = 14, .top = 4, .bottom = 10 }, .follow_end = true });
    defer ui.end(c);
    const st = kit.style(c, 12, 18, .{ .mono = true, .color = k.text });
    for (r.log.lines.items) |*l| {
        var spans: std.ArrayList(ui.Span) = .empty;
        for (l.runs.items) |run_| spans.append(c.alloc(), .{
            .start = run_.start,
            .end = run_.end,
            .color = if (run_.style.fg) |fg| (if (run_.style.dim) fg.alpha(0.6) else fg) else if (run_.style.dim) k.muted else null,
            .weight = if (run_.style.bold) .semibold else null,
            .italic = run_.style.italic,
        }) catch {};
        ui.richText(c, if (l.text.items.len == 0) " " else l.text.items, spans.items, st);
    }
}
