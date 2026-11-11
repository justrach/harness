//! The surface pane right of the chat (crates/ui/src/shell.rs): a band of
//! tabs in the title bar's row (a checkout's diff, an open file), "+" to
//! add one, the picker while none is open, and the open tab's view. A file
//! shows its path as a breadcrumb, then Markdown as it reads or code with
//! line numbers and colours.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const file_icons = @import("file_icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const panels = @import("app_panels.zig");
const highlight = @import("highlight.zig");
const App = @import("app.zig").App;

pub const width: f32 = 520;
const band_h: f32 = 38;

pub fn host(c: *ui.Context, a: *App, k: theme.Colors) void {
    const col = ui.div(c).column().wFull().hFull().bg(k.background).clip();
    defer col.end();
    const t = a.panels.activeTab() orelse return picker(c, a, k);
    switch (t.kind) {
        .diffs => @import("view_diffs.zig").diffs(c, a, k),
        .file => file(c, a, k, t.path),
        .browser => if (t.browser) |b| @import("view_browser.zig").draw(c, a, k, b),
        .tool_access => @import("view_tool_access.zig").draw(c, a, k),
        .subagent => if (t.agent) |s| subagentSurface(c, a, k, s),
    }
}

fn subagentSurface(c: *ui.Context, a: *App, k: theme.Colors, s: *@import("app_subagents.zig").Agent) void {
    const aw = @import("agent_work.zig");
    const vaw = @import("view_agent_work.zig");

    // Resolve live state and model from the parent transcript + WatchToolProgress.
    var model: []const u8 = "";
    var sub_state: aw.AgentState = if (!s.frozen and !s.transcript.complete) .running else .completed;
    const parent_working = a.selectedStatus() == .working;
    for (a.transcript.entries.items) |*e| {
        for (e.parts.items) |*p| {
            if (!p.agent or !std.mem.eql(u8, p.subagent_ref, s.doc)) continue;
            const live = a.tool_progress.find(p.id);
            sub_state = aw.resolveAgentState(
                if (live) |l| l.state else null,
                p.subagent_status,
                p.resolved,
                p.is_error,
                e.status == .streaming or parent_working,
            );
            const m = aw.invocationModel(c.alloc(), p.invocation);
            if (m.len > 0) model = m;
        }
    }

    // 1. Subagent header bar.
    {
        ui.key(c, "subagent-header");
        const bar = ui.div(c).row().wFull().h(36).px(12).gap(8).itemsCenter().clip();
        defer bar.end();
        const harness = if (a.findChat(s.parent)) |chat| chat.harness orelse "graff" else "graff";
        const mark = icons.harnessMark(harness);
        icons.icon(c, mark.name, 13, mark.brand orelse k.muted, 0);
        const title_cap = @max(80, a.view.chrome.host_width - (if (model.len > 0) @as(f32, 240) else @as(f32, 160)));
        kit.fadeText(c, s.title, kit.style(c, 12.5, 18, .{ .weight = .semibold, .color = k.text }), title_cap);
        if (model.len > 0) {
            kit.fadeText(c, model, kit.style(c, 11, 16, .{ .color = k.faint }), 96);
        }
        ui.spacer(c);

        {
            const pill_bg = switch (sub_state) {
                .running => k.accent.alpha(0.14),
                .failed => k.danger.alpha(0.14),
                .completed, .cancelled => k.ink(0.06),
            };
            const pill_fg = switch (sub_state) {
                .running => k.accent,
                .failed => k.danger,
                .completed, .cancelled => k.muted,
            };
            const pill_label = switch (sub_state) {
                .running => "Running",
                .completed => "Done",
                .failed => "Failed",
                .cancelled => "Stopped",
            };
            const pill = ui.div(c).row().h(22).px(8).gap(5).itemsCenter().rounded(11).bg(pill_bg);
            if (sub_state == .running) vaw.paintSpinner(c, 10, 1.35, k.accent, k.accent.alpha(0.22));
            ui.text(c, pill_label, kit.style(c, 11, 15, .{ .weight = .medium, .color = pill_fg }));
            pill.end();
        }

        if (kit.iconButton(c, k, .close, .{ .size = 22, .icon = 11, .tip = .{ .text = "Close subagent" } })) {
            panels.closeTab(a, a.panels.active);
            return;
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);

    // 2. Scrollable subagent transcript.
    _ = @import("view_transcript.zig").entries(
        c,
        a,
        k,
        &s.transcript,
        @max(0, a.view.chrome.host_width - 2),
        !s.transcript.complete and !s.loaded,
        14,
    );

    // 3. Mid-task Steer subagent bar (routes through parent session, never FocusChat/Run on s.doc).
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    {
        ui.key(c, "subagent-steer-bar");
        const bar = ui.div(c).row().wFull().px(10).py(8).gap(6).itemsCenter().bg(k.background);
        defer bar.end();
        const box = ui.div(c).row().grow().w(0).h(30).px(9).gap(6).itemsCenter().rounded(7).border(k.border).borderW(1).bg(k.ink(0.03));
        defer box.end();
        icons.icon(c, .bot, 12, k.muted, 0);
        ui.key(c, "subagent-steer-field");
        const at = c.nodes.items.len;
        const placeholder = if (sub_state == .running)
            c.print("Steer {s}…", .{s.title})
        else
            c.print("Follow up on {s}…", .{s.title});
        const res = ui.textField(c, &a.view.subagent_steer, .{
            .bare = true,
            .width = .fill,
            .size = 12,
            .line_height = 18,
            .placeholder = placeholder,
            .placeholder_color = k.faint,
        });
        const field_id = c.node(@intCast(at)).id;
        if (a.view.subagent_steer_focus) {
            c.focus = field_id;
            c.changed = true;
            a.view.subagent_steer_focus = false;
        }
        const trimmed = std.mem.trim(u8, a.view.subagent_steer.text(), " \t\r\n");
        const can_send = trimmed.len > 0 and a.engine.state == .connected;
        var send_btn = ui.div(c).row().size(22, 22).center().rounded(11).bg(if (can_send) k.accent else k.ink(0.06));
        if (can_send) send_btn = kit.pressFeedback(send_btn.control());
        icons.icon(c, .@"arrow-up", 11, if (can_send) .hex(0xffffff) else k.faint, 0);
        const clicked_send = send_btn.clicked() and can_send;
        send_btn.end();

        if ((res.submitted or clicked_send) and can_send) {
            submitSubagentSteer(a, s, trimmed);
        }
    }
}

fn submitSubagentSteer(a: *App, s: *const @import("app_subagents.zig").Agent, text: []const u8) void {
    const prompt = std.fmt.allocPrint(a.gpa, "For subagent \"{s}\": {s}", .{ s.title, text }) catch return;
    defer a.gpa.free(prompt);
    const saved = a.gpa.dupe(u8, a.composer.text()) catch return;
    defer a.gpa.free(saved);
    if (a.selected == null or !std.mem.eql(u8, a.selected.?, s.parent)) {
        a.openChat(s.parent, null);
    }
    a.composer.set(prompt);
    const can_steer_now = a.queues() and @import("app_queue.zig").steerBlocker(a, true, false) == null;
    a.sendFollowUp(if (can_steer_now) .steer else null);
    a.composer.set(saved);
    a.view.subagent_steer.clear();
    a.redraw();
}

fn band(c: *ui.Context, a: *App, k: theme.Colors) void {
    const b = ui.div(c).row().wFull().h(band_h).px(8).gap(4).itemsCenter().clip();
    defer b.end();
    var close: ?usize = null;
    var show: ?usize = null;
    for (a.panels.tabs.items, 0..) |t, i| {
        if (t.agent) |s| if (!s.belongsTo(a.selected)) continue;
        if (t.browser) |browser| if (!browser.belongsTo(a.selected)) continue;
        ui.key(c, c.print("host-tab-{d}", .{i}));
        const on = i == a.panels.active;
        var chip = ui.div(c).row().size(112, 24).px(6).gap(5).itemsCenter().rounded(6).clip();
        chip = if (on) chip.bg(k.wash(0.10)) else chip.hover(k.wash(0.06));
        // `SurfaceTabTooltip`: a file tab's path.
        if (t.kind == .file) chip = tip.on(chip, k, .{ .text = t.path, .delay = tip.quick, .look = .tab });
        if (t.browser) |browser| chip = tip.on(chip, k, .{ .text = c.print("{s}", .{browser.address.text()}), .delay = tip.quick, .look = .tab });
        defer chip.end();
        const hot = chip.hovered();
        if (chip.clicked() and !on) show = i;
        if (t.agent) |s| {
            const harness = if (a.findChat(s.parent)) |chat| chat.harness orelse "graff" else "graff";
            const mark = icons.harnessMark(harness);
            icons.icon(c, mark.name, 12, mark.brand orelse k.muted, 0);
        } else if (t.browser != null) icons.icon(c, .globe, 12, k.muted, 0) else if (t.kind == .diffs) icons.icon(c, .list, 12, k.muted, 0) else file_icons.icon(c, t.path, false, k.dark, 12);
        const title = if (t.agent) |s| s.title else if (t.browser) |browser| browser.title.text() else if (t.kind == .diffs) a.panels.scope.label() else std.fs.path.basename(t.path);
        kit.fadeText(c, title, .{ .size = 11.5, .color = if (on) k.text else k.muted }, if (hot) 62 else 82);
        if (hot) {
            ui.spacer(c);
            const x = ui.div(c).row().size(16, 16).center().rounded(4).hover(k.wash(0.12));
            defer x.end();
            if (x.clicked()) close = i;
            icons.icon(c, .close, 10, k.muted, 0);
        }
    }
    if (kit.iconButton(c, k, .plus, .{ .size = 24, .icon = 14, .tip = .{ .text = "New surface" } })) {
        a.panels.active = a.panels.tabs.items.len;
        a.redraw();
    }
    if (close) |i| panels.closeTab(a, i) else if (show) |i| panels.showTab(a, i);
}

/// With no tab open: what can be opened here.
fn picker(c: *ui.Context, a: *App, k: theme.Colors) void {
    const area = ui.div(c).column().wFull().grow().center().gap(8);
    defer area.end();
    for ([_]bool{ true, false }) |browser| {
        const row = ui.div(c).row().w(280).h(44).px(14).gap(10).itemsCenter().rounded(10).border(k.border).borderW(1).bg(k.ink(0.02)).hover(k.ink(0.05));
        defer row.end();
        if (row.clicked()) {
            if (browser) @import("app_browser.zig").openBlank(a) else panels.addDiffsTab(a);
        }
        icons.icon(c, if (browser) .globe else .list, 15, k.muted, 0);
        ui.text(c, if (browser) "Browser" else "Diffs", .{ .size = 13, .weight = .medium, .color = k.text });
    }
}

fn file(c: *ui.Context, a: *App, k: theme.Colors, path: []const u8) void {
    {
        // The breadcrumbs' `FileEditorTooltip`: the whole path.
        const bar = tip.on(ui.div(c).row().wFull().h(32).px(12).gap(5).itemsCenter().border(k.border).borderW(0).clip(), k, .{ .text = path, .delay = tip.quick, .look = .file });
        defer bar.end();
        file_icons.icon(c, path, false, k.dark, 12);
        var it = std.mem.splitScalar(u8, path, '/');
        var first = true;
        while (it.next()) |seg| {
            if (!first) ui.text(c, "›", .{ .size = 11, .color = k.faint });
            first = false;
            ui.text(c, seg, .{ .size = 11, .color = if (it.peek() == null) k.muted else k.faint });
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const f = a.panels.file;
    if (f.loading) return centered(c, k, "Loading…");
    const text = f.text orelse return centered(c, k, f.reason orelse "This file can't be shown.");
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 24 } });
    defer ui.end(c);
    if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown"))
        return @import("view_markdown.zig").withLinks(c, k, text, a, a.selected);
    code(c, k, text, langOf(path));
}

/// Code with its line numbers, coloured as the language reads.
pub fn code(c: *ui.Context, k: theme.Colors, text: []const u8, lang: []const u8) void {
    const pal = k.syntax;
    const st = kit.style(c, 12.5, 19, .{ .mono = true, .color = k.text });
    const num = kit.style(c, 11, 19, .{ .mono = true, .color = k.faint });
    var in_block: highlight.State = .{};
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |l| {
        n += 1;
        if (n > 4000) break;
        const r = ui.div(c).row().gap(12);
        defer r.end();
        {
            const g = ui.div(c).row().w(36).justifyEnd();
            defer g.end();
            ui.text(c, c.print("{d}", .{n}), num);
        }
        ui.richText(c, if (l.len == 0) " " else l, highlight.line(c.alloc(), l, lang, pal, &in_block), st);
    }
}

/// The language a path names, for colouring (`language_for_path`): a
/// Dockerfile's, a Makefile's, Cargo.lock's, else its extension's.
pub fn langOf(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    const named = [_][2][]const u8{ .{ "dockerfile", "dockerfile" }, .{ "containerfile", "dockerfile" }, .{ "makefile", "make" }, .{ "gnumakefile", "make" }, .{ "cargo.lock", "toml" } };
    for (named) |n| if (std.ascii.eqlIgnoreCase(name, n[0])) return n[1];
    const ext = std.fs.path.extension(name);
    return if (ext.len > 1) ext[1..] else "";
}

fn centered(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const box = ui.div(c).column().wFull().grow().center();
    defer box.end();
    ui.text(c, text, .{ .size = 12, .color = k.muted });
}
