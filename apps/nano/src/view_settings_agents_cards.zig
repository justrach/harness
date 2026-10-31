//! Settings › Agents' header switcher and the cards around the list
//! (harnesses.rs `render_device_switcher`, `render_screen_access`,
//! `render_graff_draft_subagents`, `render_titles`).
const std = @import("std");
const rules = @import("rules.zig");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const shots = @import("view_settings_appshots.zig");
const workspace = @import("workspace.zig");
const agents = @import("agents.zig");
const page = @import("view_settings_agents.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const title = page.title;
const subtitleIn = page.subtitleIn;
const toggle = page.toggle;
const badge = page.badge;
const badgeW = page.badgeW;
const actionW = page.actionW;
const card = page.card;
const cardInner = page.cardInner;
const errorStrip = page.errorStrip;
const Page = page.Page;
const setTarget = page.setTarget;
const loadDraft = page.loadDraft;
const loadTitles = page.loadTitles;

// The device switcher (`render_device_switcher`).

fn platformIcon(p: []const u8) icons.Name {
    if (std.mem.eql(u8, p, "macos") or std.mem.eql(u8, p, "darwin")) return .laptop;
    if (std.mem.eql(u8, p, "ios") or std.mem.eql(u8, p, "android")) return .smartphone;
    return .monitor;
}

/// The devices by when they were added, then id.
pub fn sortedDevices(alloc: Allocator, devices: []const workspace.Device) []workspace.Device {
    const out = alloc.dupe(workspace.Device, devices) catch return &.{};
    std.sort.insertion(workspace.Device, out, {}, struct {
        fn lt(_: void, x: workspace.Device, y: workspace.Device) bool {
            if (x.created_ms != y.created_ms) return x.created_ms < y.created_ms;
            return std.mem.order(u8, x.id, y.id) == .lt;
        }
    }.lt);
    return out;
}

fn eqlOpt(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

pub fn switcher(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.agents;
    const effective: ?[]const u8 = p.target orelse a.device_id;
    var selected: ?workspace.Device = null;
    for (a.devices.items) |d| if (eqlOpt(d.id, effective)) {
        selected = d;
    };
    const open = p.device_menu;
    ui.key(c, "agents-device-switcher");
    var t = ui.div(c).row().h(28).px(8).gap(6).itemsCenter().rounded(6);
    t = if (open) t.bg(k.ink(0.06)) else t.hover(k.ink(0.04));
    defer t.end();
    if (c.rects.get(c.node(t.index).id)) |r| p.device_anchor = r;
    icons.icon(c, platformIcon(if (selected) |d| d.platform else "macos"), 16, k.muted, 0);
    kit.ellipsisText(c, if (selected) |d| d.name else "This device", set.st(c, 12.5, .{ .weight = .medium, .color = k.text }), 240);
    kit.dot(c, 6, if (eqlOpt(effective, a.device_id)) k.success else k.ink(0.2));
    icons.icon(c, .@"sort-vertical", 14, k.muted.alpha(if (open) 0.9 else 0.4), 0);
    if (t.clicked()) {
        p.device_menu = !open;
        a.redraw();
    }
}

/// "Devices", then a row each; picking one shows it (this one: no
/// passthrough).
pub fn deviceMenu(c: *ui.Context, a: *App, k: theme.Colors, at: ui.Rect) void {
    const p = &a.view.agents;
    {
        // A press anywhere else closes it (`on_mouse_down_out`).
        if (kit.pressedOutside(c, at)) {
            p.device_menu = false;
            return a.redraw();
        }
    }
    const w: f32 = 220;
    // `anchored_menu`: pinned at the trigger's top left, 6 down (over it),
    // moved only when it would leave the window.
    const x = rules.snapToWindow(at.x, w, c.size.w, 8);
    const y = at.y + 6;
    ui.key(c, "agents-device-menu");
    const m = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(4 + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer m.end();
    {
        const hd = ui.div(c).row().wFull().px(8).pt(6).pb(4);
        defer hd.end();
        ui.text(c, "D\u{200A}E\u{200A}V\u{200A}I\u{200A}C\u{200A}E\u{200A}S", set.st(c, 10, .{ .weight = .medium, .color = k.muted }));
    }
    const effective: ?[]const u8 = p.target orelse a.device_id;
    for (sortedDevices(c.alloc(), a.devices.items)) |d| {
        ui.key(c, c.print("agents-device-{s}", .{d.id}));
        const active = eqlOpt(d.id, effective);
        const local = eqlOpt(d.id, a.device_id);
        var r = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7);
        r = if (active) r.bg(k.selected) else r.hover(k.selected);
        defer r.end();
        const hot = r.hovered();
        icons.icon(c, platformIcon(d.platform), 16, k.muted, 0);
        const you: f32 = if (local) 10 + c.text.width("You", .{ .size = 10.5 }) else 0;
        {
            const n = ui.div(c).row().grow().w(0);
            defer n.end();
            kit.ellipsisText(c, d.name, set.st(c, 13, .{ .color = if (active or hot) k.text else k.text.alpha(0.9) }), w - 10 - 16 - 16 - 10 - 6 - 10 - you);
        }
        if (local) ui.text(c, "You", set.st(c, 10.5, .{ .color = k.muted }));
        kit.dot(c, 6, if (local) k.success else k.ink(0.2));
        if (r.clicked()) setTarget(a, if (local) null else d.id);
    }
}

// The cards around the list.

/// Screen Recording for agents (`render_screen_access`): agents run under
/// Harness, so their screenshots use its macOS grant.
pub fn screenAccess(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (comptime @import("builtin").os.tag != .macos) return;
    const p = &a.view.agents;
    const granted = shots.capabilities().capture == .ready;
    const status = if (granted) "Allowed" else "Off";
    const allow = !granted and !p.screen_requested;
    const after = !granted and p.screen_requested;
    var controls_w = badgeW(c, status);
    if (allow) controls_w += 8 + actionW(c, "Allow");
    if (after) controls_w += 8 + actionW(c, "Open System Settings") + 8 + actionW(c, "Restart Harness");
    const description = if (granted)
        "Agents can take screenshots, for example to check a UI they built."
    else if (p.screen_requested)
        "Turn on Harness under Screen Recording, then restart Harness. Running agents stop on restart; your chats are kept."
    else
        "Lets agents take screenshots, for example to check a UI they built. macOS asks once, and the change applies after Harness restarts.";
    const inner = cardInner();
    // The words take what the controls leave, at least 200; less, and
    // the controls wrap under them.
    const fits = inner - 12 - controls_w >= 200;
    const words_w = if (fits) inner - 12 - controls_w else inner;
    {
        const cd = set.card(c, k);
        defer cd.end();
        var in = ui.div(c).p(16).wFull().gap(12);
        in = if (fits) in.row().itemsCenter() else in.column();
        defer in.end();
        {
            // `gap(4)` above `page_subtitle`'s own 4.
            const col = ui.div(c).column().w(words_w);
            defer col.end();
            title(c, k, "Screen Recording", words_w);
            set.space(c, 4);
            subtitleIn(c, k, description, words_w);
        }
        const ctl = ui.div(c).row().gap(8).itemsCenter();
        defer ctl.end();
        badge(c, k, status).end();
        if (allow) if (shots.action(c, k, "Allow")) {
            shots.request("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGRequestScreenCaptureAccess");
            p.screen_requested = true;
        };
        if (after) {
            if (shots.action(c, k, "Open System Settings")) _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture");
            if (shots.action(c, k, "Restart Harness")) a.setNotice("Restarting isn't in Harness Nano yet: quit and open it again.");
        }
    }
    set.space(c, 4);
}

/// graff's child agents (`render_graff_draft_subagents`).
pub fn draftCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.agents;
    const ready = p.draft == .ready;
    const cd = card(c, k, 20);
    defer cd.end();
    const r = ui.div(c).row().wFull().p(16).gap(12).itemsCenter();
    defer r.end();
    const w = cardInner() - 12 - 32;
    {
        const col = ui.div(c).column().w(w);
        defer col.end();
        title(c, k, "Experimental Graff ACP child agents", w);
        subtitleIn(c, k, "Show live transcripts of Graff's foreground child agents while the parent turn runs. Background agents still show only in their parent's tool row. Needs Graff 0.0.302.5 or later; transcripts aren't restored when a session reloads yet.", w);
    }
    if (toggle(c, k, ready and p.draft_on, ready and !p.draft_saving)) loadDraft(a, !p.draft_on);
}

/// The device's autonomy, three pills, and Replay setup under it
/// (`render_autonomy`).
pub fn autonomyCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const setup = @import("view_setup.zig");
    const p = &a.view.agents;
    const w = cardInner();
    const cd = card(c, k, 20);
    defer cd.end();
    {
        const in = ui.div(c).column().wFull().p(16).gap(2);
        defer in.end();
        title(c, k, "Autonomy", w);
        subtitleIn(c, k, "How much agents on this device can do without asking. Applies to new runs of Codex, Claude Code and ACP agents.", w);
        set.space(c, 8);
        const ready = p.autonomy == .ready;
        const busy = !ready or p.autonomy_saving;
        {
            const pills = ui.div(c).row().gap(6).itemsCenter();
            defer pills.end();
            for (setup.Autonomy.all) |x| {
                const selected = ready and p.autonomy_level == x;
                ui.key(c, c.print("autonomy-level-{s}", .{x.wire()}));
                var pill = ui.div(c).row().roundedFull();
                pill = if (selected) pill.px(8).py(2).bg(k.success.alpha(0.12)) else pill.px(9).py(3).border(k.border).borderW(1);
                if (busy) pill = pill.opacity(0.35);
                defer pill.end();
                const hot = !busy and !selected and pill.hovered();
                ui.text(c, x.label(), set.st(c, 10.5, .{ .color = if (selected) k.success_muted.alpha(0.9) else if (hot) k.text else k.muted }));
                if (!busy and !selected and pill.clicked()) page.loadAutonomy(a, x);
            }
        }
        const note: []const u8 = switch (p.autonomy) {
            .ready => if (p.autonomy_chosen) p.autonomy_level.blurb() else c.print("{s} The default until you pick one.", .{p.autonomy_level.blurb()}),
            .failed => "Update Harness on that computer to set this.",
            else => "",
        };
        if (note.len > 0) {
            set.space(c, 6);
            const n = ui.div(c).column().w(w);
            defer n.end();
            ui.text(c, note, set.st(c, 12, .{ .wrap = true, .color = k.muted }));
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const r = ui.div(c).row().wFull().p(16).gap(12).itemsCenter();
    defer r.end();
    const tw = w - 12 - actionW(c, "Replay setup");
    {
        const col = ui.div(c).column().w(tw);
        defer col.end();
        title(c, k, "First-run setup", tw);
        subtitleIn(c, k, "Agent, effort, autonomy and notifications, one question at a time.", tw);
    }
    ui.key(c, "replay-setup");
    if (shots.action(c, k, "Replay setup")) setup.open(a, 0);
}

/// The session-title agent and model (`render_titles`).
pub fn titlesCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.agents;
    const w = cardInner();
    const cd = card(c, k, 20);
    defer cd.end();
    const in = ui.div(c).column().wFull().p(16);
    defer in.end();
    title(c, k, "Session titles", w);
    subtitleIn(c, k, "Choose the agent and model for automatic titles on this device. Claude Code and Codex support restricted title generation.", w);
    if (p.titles != .ready) {
        set.space(c, 8);
        const m = ui.div(c).column().w(w);
        defer m.end();
        ui.text(c, if (p.titles == .failed) p.titles_failure.items else "Loading title settings…", set.st(c, 14, .{ .wrap = true, .color = k.text }));
        return;
    }
    for ([_]bool{ false, true }) |is_model| titleRow(c, a, k, is_model, w);
    if (p.models == .failed) _ = errorStrip(c, k, p.models_failure.items, w);
}

fn modelLabel(p: *const Page, id: []const u8) []const u8 {
    if (p.models == .ready) if (p.title_models) |ms| for (ms.items) |m| if (std.mem.eql(u8, m.id, id)) return m.label;
    return id;
}

fn titleRow(c: *ui.Context, a: *App, k: theme.Colors, is_model: bool, w: f32) void {
    const p = &a.view.agents;
    const label = if (is_model)
        (if (p.title_model) |m| modelLabel(p, m) else "Automatic (cheapest model)")
    else
        agents.titleHarnessLabel(p.title_harness);
    const interactive = !p.title_saving and (!is_model or p.title_harness != null);
    ui.key(c, if (is_model) "title-model" else "title-harness");
    set.space(c, 12);
    title(c, k, if (is_model) "Title model" else "Title harness", w);
    {
        var g = ui.div(c).row().wFull().px(10).py(6).rounded(8);
        if (interactive) g = g.hover(k.ink(0.06)) else g = g.opacity(0.5);
        defer g.end();
        ui.text(c, label, set.st(c, 12, .{ .color = if (interactive and g.hovered()) k.text else k.muted }));
        if (interactive and g.clicked()) {
            p.title_menu = if (p.title_menu == is_model) null else is_model;
            a.redraw();
        }
    }
    if (p.title_menu != is_model) return;
    const list = ui.div(c).column().wFull().maxH(240).scrollY();
    defer list.end();
    // "Automatic", then each model, or each agent on, installed and able
    // to title.
    if (choiceRow(c, k, "Automatic", p.title_model == null and (is_model or p.title_harness == null))) {
        loadTitles(a, .{ .harness = if (is_model) p.title_harness else null, .model = null });
    }
    if (is_model) {
        if (p.models == .ready) if (p.title_models) |ms| for (ms.items) |m| {
            const on = if (p.title_model) |cur| std.mem.eql(u8, cur, m.id) else false;
            ui.key(c, c.print("title-choice-model-{s}", .{m.id}));
            if (choiceRow(c, k, m.label, on)) loadTitles(a, .{ .harness = p.title_harness, .model = m.id });
        };
    } else if (p.phase == .ready) for (p.descriptors()) |d| {
        if (!(agents.descriptorEnabled(d) and d.installed and agents.supportsTitles(d.id) and d.id != .mock)) continue;
        ui.key(c, c.print("title-choice-harness-{s}", .{d.id.wire()}));
        if (choiceRow(c, k, d.name, p.title_harness == d.id and p.title_model == null)) loadTitles(a, .{ .harness = d.id, .model = null });
    };
}

/// `menu_row`: the selected wash when chosen or under the pointer.
fn choiceRow(c: *ui.Context, k: theme.Colors, label: []const u8, active: bool) bool {
    var r = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7);
    r = if (active) r.bg(k.selected) else r.hover(k.selected);
    defer r.end();
    ui.text(c, label, set.st(c, 13, .{ .color = if (active or r.hovered()) k.text else k.text.alpha(0.9) }));
    return r.clicked();
}
