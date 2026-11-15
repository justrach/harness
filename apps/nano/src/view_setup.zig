//! First-run setup, as the GPUI app's (crates/ui/src/setup.rs): four
//! questions, then a ready page, over the whole window. Graff comes first
//! and picked (it signs in with CodeGraff); Claude Code and Codex are
//! extras. Each answer sets the real setting: the extras through
//! `SetHarnessEnabled`, the default effort as the new chat's model and
//! level, the device's autonomy through `SetAutonomy`, and Settings ›
//! Notifications' switch. It shows once: `setup.json` in the data folder
//! (the GPUI app's marker, shared) says whether it is pending or done; a
//! folder with no settings yet is a first run. Settings › Agents' Replay
//! setup opens it again; `HARNESS_SETUP_STEP=n` opens it at question n.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const rules = @import("rules.zig");
const workspace = @import("workspace.zig");
const agent = @import("app_agent.zig");
const App = @import("app.zig").App;

pub const questions: usize = 4;

/// Off until GPUI's desktop onboarding (`feat/desktop-onboarding`) is on
/// main: Nano matches main's GPUI, which neither runs first-run setup at
/// launch nor shows Settings › Agents' Autonomy card. `HARNESS_SETUP_STEP`
/// still opens it, for working on it.
pub const enabled = true;

/// What agents on a device may do without asking (`harness_proto::Autonomy`).
pub const Autonomy = enum {
    read_only,
    workspace,
    full_access,

    pub const all = [_]Autonomy{ .read_only, .workspace, .full_access };

    pub fn wire(x: Autonomy) []const u8 {
        return switch (x) {
            .read_only => "read-only",
            .workspace => "workspace",
            .full_access => "full-access",
        };
    }

    pub fn parse(s: []const u8) ?Autonomy {
        for (all) |x| if (std.mem.eql(u8, s, x.wire())) return x;
        return null;
    }

    pub fn label(x: Autonomy) []const u8 {
        return switch (x) {
            .read_only => "Read only",
            .workspace => "Workspace",
            .full_access => "Full access",
        };
    }

    pub fn blurb(x: Autonomy) []const u8 {
        return switch (x) {
            .read_only => "Reads and plans. Asks before it changes anything.",
            .workspace => "Edits this project. Asks before anything else.",
            .full_access => "Runs anything without asking.",
        };
    }

    /// How many of `capabilities` it has, in order.
    fn allowed(x: Autonomy) usize {
        return switch (x) {
            .read_only => 1,
            .workspace => 2,
            .full_access => 4,
        };
    }
};

/// A `GetAutonomy` / `SetAutonomy` reply.
pub const Read = struct { autonomy: Autonomy, chosen: bool };

pub fn readAutonomy(v: json.Value) ?Read {
    if (v != .object) return null;
    const x = v.object.get("autonomy") orelse return null;
    if (x != .string) return null;
    const au = Autonomy.parse(x.string) orelse return null;
    const chosen = if (v.object.get("chosen")) |c| c == .bool and c.bool else false;
    return .{ .autonomy = au, .chosen = chosen };
}

const Extra = struct {
    id: []const u8,
    name: []const u8,
    summary_name: []const u8,
    cli: []const u8,
    cmd: []const u8,
    icon: icons.Name,
};

const extra_list = [_]Extra{
    .{
        .id = "claude-code",
        .name = "Claude Code",
        .summary_name = "Claude Code",
        .cli = "claude CLI",
        .cmd = "curl -fsSL https://claude.ai/install.sh | bash",
        .icon = .@"claude-mark",
    },
    .{
        .id = "codex",
        .name = "ChatGPT · OpenAI Codex",
        .summary_name = "OpenAI Codex",
        .cli = "codex CLI",
        .cmd = "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        .icon = .@"openai-mark",
    },
};

const starters = [_][]const u8{ "Tour this project and tell me how it fits together", "Find one small bug and fix it" };
const starter_labels = [_][]const u8{ "Tour this project", "Fix a small bug" };
const capabilities = [_][]const u8{ "Read files and run searches", "Edit files in this project", "Run commands outside it", "Approve its own requests" };

pub const Setup = struct {
    step: usize = 0,
    /// The extras switched on, and as the engine last had them.
    extras_on: [2]bool = .{ false, false },
    extras_was: [2]bool = .{ false, false },
    extras_seen: bool = false,
    /// Which CLI index (`0` = Claude Code, `1` = Codex) is currently installing.
    installing: ?usize = null,
    install_both_pending: bool = false,
    install_call: ?u64 = null,
    refresh_call: ?u64 = null,
    copied: ?usize = null,
    copied_until: f64 = 0,
    /// The picked one of Graff's first three models.
    model: usize = 0,
    /// The picked rung of its ladder; null is its default.
    level: ?usize = null,
    autonomy: Autonomy = .workspace,
    autonomy_call: ?u64 = null,
    notify: bool = true,
    starter: ?usize = null,
    /// A write or CLI install that failed (static text).
    err: ?[]const u8 = null,
};

// The gate.

fn markerPath(a: *App) ?[]u8 {
    const path = a.settings.path orelse return null;
    const dir = std.fs.path.dirname(path) orelse return null;
    return std.fs.path.join(a.gpa, &.{ dir, "setup.json" }) catch null;
}

pub fn writeGate(a: *App, done: bool) void {
    const p = markerPath(a) orelse return;
    defer a.gpa.free(p);
    const body = if (done) "{\"state\":\"done\"}\n" else "{\"state\":\"pending\"}\n";
    std.Io.Dir.cwd().writeFile(a.settings.io, .{ .sub_path = p, .data = body }) catch {};
}

/// Whether to show it at launch: asked for, pending, or a first run. Never
/// for an offscreen scene unless asked for.
fn check(a: *App) void {
    if (a.env) |env| {
        if (env.get("HARNESS_SETUP_STEP")) |s| return open(a, std.fmt.parseInt(usize, s, 10) catch 0);
        if (env.get("HARNESS_SETUP_OFF") != null) return;
    }
    if (!enabled or a.offscreen) return;
    const p = markerPath(a) orelse return;
    defer a.gpa.free(p);
    const body = std.Io.Dir.cwd().readFileAlloc(a.settings.io, p, a.gpa, .limited(4096)) catch {
        // No marker: a first run when there were no settings either; an
        // existing install otherwise, which keeps what it has.
        if (a.settings.fresh) {
            writeGate(a, false);
            open(a, 0);
        } else writeGate(a, true);
        return;
    };
    defer a.gpa.free(body);
    if (std.mem.indexOf(u8, body, "pending") != null) open(a, 0);
}

/// Opens it at `step` (Replay setup: 0), over Settings too.
pub fn open(a: *App, step: usize) void {
    a.view.setup = .{ .step = @min(step, questions) };
    if (a.view.settings_open) set.close(a);
    seed(a, &a.view.setup.?);
    if (a.engine.up()) {
        const s = &a.view.setup.?;
        if (a.engine.call("GetAutonomy", .{}, .of(App, a, onAutonomy))) |id| s.autonomy_call = id;
        agent.ensureModels(a, "graff");
    }
    a.redraw();
}

fn onAutonomy(a: *App, id: u64, r: rpc.Reply) void {
    const s = if (a.view.setup) |*x| x else return;
    if (id != 0 and s.autonomy_call != id) return;
    s.autonomy_call = null;
    // Not chosen yet: the full access existing installs run with stays
    // the engine's default, and setup suggests Workspace.
    if (r == .ok) if (readAutonomy(r.ok)) |v| if (v.chosen) {
        s.autonomy = v.autonomy;
    };
    a.redraw();
}

/// The extras as this device has them, once the catalog is in.
fn seed(a: *App, s: *Setup) void {
    if (s.extras_seen or a.harnesses.items.len == 0) return;
    s.extras_seen = true;
    for (extra_list, 0..) |ex, i| if (harness(a, ex.id)) |h| {
        s.extras_on[i] = h.offered and h.installed;
        s.extras_was[i] = s.extras_on[i];
    };
}

fn allExtrasMissing(a: *const App, s: *const Setup) bool {
    if (!s.extras_seen) return false;
    for (extra_list) |ex| {
        const h = harness(a, ex.id) orelse return false;
        if (h.installed) return false;
    }
    return true;
}

fn installableMissingCount(a: *const App, s: *const Setup) usize {
    if (!s.extras_seen) return 0;
    var count: usize = 0;
    for (extra_list) |ex| {
        const h = harness(a, ex.id) orelse continue;
        if (!h.installed and h.can_install) count += 1;
    }
    return count;
}

fn harness(a: *const App, id: []const u8) ?workspace.Harness {
    for (a.harnesses.items) |h| if (std.mem.eql(u8, h.id, id)) return h;
    return null;
}

/// Graff's first three models, once listed.
fn models(a: *const App) []const workspace.Model {
    if (!std.mem.eql(u8, a.models_for, "graff")) return &.{};
    return a.models.items[0..@min(3, a.models.items.len)];
}

fn ladder(a: *const App, m: workspace.Model) []const []const u8 {
    if (m.levels.len > 0) return m.levels;
    if (harness(a, "graff")) |h| return h.levels;
    return &.{};
}

/// The model and rung picked, if Graff's models are listed.
const Effort = struct { model: workspace.Model, levels: []const []const u8, at: ?usize };

fn effort(a: *const App, s: *const Setup) ?Effort {
    const ms = models(a);
    if (ms.len == 0) return null;
    const m = ms[@min(s.model, ms.len - 1)];
    const l = ladder(a, m);
    var at = s.level;
    if (at == null) if (rules.defaultReasoning(l)) |d| {
        for (l, 0..) |x, i| if (std.mem.eql(u8, x, d)) {
            at = i;
        };
    };
    if (at) |i| if (i >= l.len) {
        at = if (l.len > 0) l.len - 1 else null;
    };
    return .{ .model = m, .levels = l, .at = at };
}

fn levelBlurb(level: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, level, "none") or eql(u8, level, "minimal")) return "Answers straight away.";
    if (eql(u8, level, "low")) return "Quick answers and light edits.";
    if (eql(u8, level, "medium")) return "Balanced for everyday changes.";
    if (eql(u8, level, "high")) return "Thinks before it edits. The default for real work.";
    if (eql(u8, level, "xhigh")) return "Takes its time on hard problems.";
    return "The most thinking it does. Slower, for the hardest work.";
}

// The answers.

fn syncAgentsPage(a: *App, v: json.Value) void {
    const page = @import("view_settings_agents.zig");
    if (a.view.agents.list != null and a.view.agents.target == null) page.setList(a, v);
}

fn onEnabled(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| {
            a.harnesses.replace(v) catch {};
            syncAgentsPage(a, v);
        },
        .err => if (a.view.setup) |*s| {
            s.err = "Couldn't switch that agent. Try again from Settings > Agents.";
        },
        else => {},
    }
    a.redraw();
}

pub fn installExtra(a: *App, idx: usize) void {
    const s = if (a.view.setup) |*x| x else return;
    if (idx >= extra_list.len or s.installing != null) return;
    s.err = null;
    s.installing = idx;
    s.install_call = null;
    if (a.engine.call("InstallHarness", .{
        .harness = extra_list[idx].id,
        .targetDeviceId = @as(?[]const u8, null),
        .beta = false,
    }, .of(App, a, onInstall))) |id| {
        if (a.view.setup) |*cur| cur.install_call = id;
    }
    a.redraw();
}

fn installBoth(a: *App) void {
    const s = if (a.view.setup) |*x| x else return;
    if (s.installing != null) return;
    s.install_both_pending = true;
    for (extra_list, 0..) |ex, i| {
        const h = harness(a, ex.id) orelse continue;
        if (!h.installed and h.can_install) return installExtra(a, i);
    }
    s.install_both_pending = false;
}

fn onInstall(a: *App, id: u64, r: rpc.Reply) void {
    const s = if (a.view.setup) |*x| x else return;
    const which = s.installing orelse return;
    if (id != 0 and s.install_call != id) return;
    s.install_call = null;
    s.installing = null;
    switch (r) {
        .ok => |v| {
            a.harnesses.replace(v) catch {};
            syncAgentsPage(a, v);
            s.extras_seen = true;
            if (harness(a, extra_list[which].id)) |h| {
                s.extras_was[which] = h.offered and h.installed;
                if (h.installed) s.extras_on[which] = true;
            }
            if (s.install_both_pending) {
                s.install_both_pending = false;
                for (extra_list, 0..) |ex, i| {
                    const h = harness(a, ex.id) orelse continue;
                    if (!h.installed and h.can_install) {
                        installExtra(a, i);
                        return;
                    }
                }
            }
        },
        .err => {
            s.install_both_pending = false;
            s.err = "Couldn't install that CLI automatically. Run the command below in Terminal, then click Check again.";
        },
        else => s.install_both_pending = false,
    }
    a.redraw();
}

fn cancelInstall(a: *App) void {
    const s = if (a.view.setup) |*x| x else return;
    const which = s.installing orelse return;
    s.installing = null;
    s.install_call = null;
    s.install_both_pending = false;
    _ = a.engine.call("CancelInstall", .{
        .harness = extra_list[which].id,
        .targetDeviceId = @as(?[]const u8, null),
        .beta = false,
    }, .of(App, a, onCancelInstall));
    a.redraw();
}

fn onCancelInstall(a: *App, _: u64, r: rpc.Reply) void {
    if (r == .ok) {
        a.harnesses.replace(r.ok) catch {};
        syncAgentsPage(a, r.ok);
    }
    a.redraw();
}

fn refreshClis(a: *App) void {
    const s = if (a.view.setup) |*x| x else return;
    if (s.refresh_call != null or s.installing != null) return;
    s.err = null;
    s.refresh_call = null;
    if (a.engine.call("ListHarnesses", .{}, .of(App, a, onRefresh))) |id| {
        if (a.view.setup) |*cur| cur.refresh_call = id;
    }
    a.redraw();
}

fn onRefresh(a: *App, id: u64, r: rpc.Reply) void {
    const s = if (a.view.setup) |*x| x else return;
    if (id != 0 and s.refresh_call != id) return;
    s.refresh_call = null;
    switch (r) {
        .ok => |v| {
            var was_installed = [_]bool{ false, false };
            for (extra_list, 0..) |ex, i| if (harness(a, ex.id)) |h| {
                was_installed[i] = h.installed;
            };
            a.harnesses.replace(v) catch {};
            syncAgentsPage(a, v);
            s.extras_seen = true;
            for (extra_list, 0..) |ex, i| if (harness(a, ex.id)) |h| {
                if (h.installed and !was_installed[i]) s.extras_on[i] = true else if (!s.extras_on[i]) s.extras_on[i] = h.offered and h.installed;
                s.extras_was[i] = h.offered and h.installed;
            };
        },
        .err => s.err = "Couldn't re-check installed CLIs right now.",
        else => {},
    }
    a.redraw();
}

fn onSaved(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| if (readAutonomy(v)) |x| @import("view_settings_agents.zig").setAutonomy(a, x),
        .err => if (a.view.setup) |*s| {
            s.err = "Couldn't save the access level. Change it in Settings > Agents.";
        },
        else => {},
    }
    a.redraw();
}

pub fn next(a: *App) void {
    const s = if (a.view.setup) |*x| x else return;
    s.err = null;
    switch (s.step) {
        0 => for (extra_list, 0..) |ex, i| if (s.extras_on[i] != s.extras_was[i]) {
            s.extras_was[i] = s.extras_on[i];
            _ = a.engine.call("SetHarnessEnabled", .{ .harness = ex.id, .enabled = s.extras_on[i] }, .of(App, a, onEnabled));
        },
        2 => _ = a.engine.call("SetAutonomy", .{ .autonomy = s.autonomy.wire() }, .of(App, a, onSaved)),
        else => {},
    }
    if (s.step >= questions) return finish(a, false);
    s.step += 1;
    a.redraw();
}

fn back(a: *App) void {
    const s = if (a.view.setup) |*x| x else return;
    if (s.step > 0) s.step -= 1;
    a.redraw();
}

/// ←/→: the effort's rung or the autonomy's stop.
fn nudge(a: *App, by: i32) void {
    const s = if (a.view.setup) |*x| x else return;
    switch (s.step) {
        1 => if (effort(a, s)) |e| if (e.levels.len > 0) {
            const at: i32 = @intCast(e.at orelse 0);
            s.level = @intCast(std.math.clamp(at + by, 0, @as(i32, @intCast(e.levels.len - 1))));
        },
        2 => {
            const at: i32 = @backingInt(s.autonomy);
            s.autonomy = @fromBackingInt(@intCast(@as(u2, @intCast(std.math.clamp(at + by, 0, 2)))));
        },
        else => {},
    }
    a.redraw();
}

/// Done (or skipped): the gate says so; finished, the new chat runs Graff
/// on the picked model and level, notifications as answered, the starter
/// in the composer.
pub fn finish(a: *App, skipped: bool) void {
    const s = a.view.setup orelse return;
    writeGate(a, true);
    if (!skipped) {
        var model: ?[]u8 = null;
        var level: ?[]u8 = null;
        defer if (model) |m| a.gpa.free(m);
        defer if (level) |l| a.gpa.free(l);
        if (effort(a, &s)) |e| {
            model = a.gpa.dupe(u8, e.model.id) catch null;
            if (e.at) |i| level = a.gpa.dupe(u8, e.levels[i]) catch null;
        }
        agent.setHarness(a, "graff");
        if (model) |m| agent.setModel(a, m);
        if (level) |l| {
            if (a.new_reasoning) |old| a.gpa.free(old);
            a.new_reasoning = a.gpa.dupe(u8, l) catch null;
        }
        if (a.settings.get(.notifications_enabled) != s.notify) a.settings.set(.notifications_enabled, s.notify);
        if (s.starter) |i| a.composer.set(starters[i]);
    }
    a.view.setup = null;
    a.view.focus_composer = true;
    a.redraw();
}

/// Open, it has every key: Return goes on, Escape back, ←/→ adjust.
pub fn keys(c: *ui.Context, a: *App) bool {
    if (a.view.setup == null) return false;
    const S = ui.Shortcut;
    if (c.shortcut(.{ .key = S.enter })) {
        next(a);
    } else if (c.shortcut(.{ .key = S.escape })) {
        back(a);
    } else if (c.shortcut(.{ .key = S.left })) {
        nudge(a, -1);
    } else if (c.shortcut(.{ .key = S.right })) nudge(a, 1);
    return true;
}

// Drawing.

const left_w: f32 = 420;
const text_w: f32 = left_w - 2 * 40;
const right_w: f32 = 500;

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.view.setup_checked) {
        a.view.setup_checked = true;
        check(a);
    }
    const s = if (a.view.setup) |*x| x else return;
    seed(a, s);
    ui.key(c, "setup-overlay");
    const root = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(9).row().bg(k.shell);
    defer root.end();
    questionPane(c, a, k, s);
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
    const right = ui.div(c).column().grow().w(0).hFull().center().bg(k.composer);
    defer right.end();
    switch (s.step) {
        0 => agentsPane(c, a, k, s),
        1 => effortPane(c, a, k, s),
        2 => autonomyPane(c, k, s),
        3 => notifyPane(c, k, s),
        else => readyPane(c, a, k, s),
    }
}

fn copy(a: *const App, s: *const Setup) [2][]const u8 {
    return switch (s.step) {
        0 => if (allExtrasMissing(a, s))
            .{ "Set up your coding CLIs", "Graff works right away. Neither Claude Code nor ChatGPT (Codex CLI) was found on this computer — install either below or use Graff first." }
        else
            .{ "Start with Graff", "Graff is already connected through your CodeGraff sign-in. Add Claude Code or ChatGPT (Codex CLI) below, or install any missing CLI right here." },
        1 => .{ "How hard should it think?", "Your default for new Graff sessions. Change it per message from the composer." },
        2 => .{ "How much can it do without asking?", "Applies to every agent on this computer. Change it any time in Settings > Agents." },
        3 => .{ "Ping you when it needs you?", "A desktop banner when a session waits on you or finishes while Harness is in the background." },
        else => .{ "Your first agent is ready", "Graff is live on this computer." },
    };
}

fn questionPane(c: *ui.Context, a: *App, k: theme.Colors, s: *Setup) void {
    const col = ui.div(c).column().w(left_w).hFull().px(40).pt(72).pb(32).gap(14);
    defer col.end();
    if (s.step < questions) {
        const prog = ui.div(c).row().gap(10).itemsCenter();
        defer prog.end();
        {
            const bars = ui.div(c).row().gap(4);
            defer bars.end();
            for (0..questions) |i| ui.div(c).w(28).h(4).roundedFull().bg(if (i <= s.step) k.text else k.ink(0.12)).end();
        }
        ui.text(c, c.print("{d} of {d}", .{ s.step + 1, questions }), set.st(c, 12, .{ .color = k.muted }));
    } else {
        const done = ui.div(c).row().gap(6).itemsCenter();
        defer done.end();
        icons.icon(c, .check, 14, k.success, 0);
        ui.text(c, "All set", set.st(c, 12, .{ .weight = .medium, .color = k.success }));
    }
    const words = copy(a, s);
    {
        const t = ui.div(c).column().w(text_w).gap(8);
        defer t.end();
        ui.text(c, words[0], set.st(c, 26, .{ .weight = .semibold, .wrap = true, .color = k.text }));
        ui.text(c, words[1], set.st(c, 14, .{ .wrap = true, .color = k.muted }));
    }
    if (s.err) |why| {
        const e = ui.div(c).column().w(text_w);
        defer e.end();
        ui.text(c, why, set.st(c, 12.5, .{ .wrap = true, .color = k.danger_muted }));
    }
    ui.spacer(c);
    {
        const r = ui.div(c).row().w(text_w).gap(8).itemsCenter();
        defer r.end();
        if (s.step > 0) {
            ui.key(c, "setup-back");
            const b = ui.div(c).row().px(14).py(9).rounded(9).border(k.border).borderW(1).hover(k.ink(0.05));
            defer b.end();
            ui.text(c, "Back", set.st(c, 13, .{ .color = k.text }));
            if (b.clicked()) back(a);
        }
        ui.spacer(c);
        ui.key(c, "setup-next");
        const n = ui.div(c).row().px(18).py(9).rounded(9).bg(k.text).hover(k.text.alpha(0.88));
        defer n.end();
        ui.text(c, if (s.step >= questions) "Start a session" else "Next", set.st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
        if (n.clicked()) next(a);
    }
    {
        const r = ui.div(c).row().w(text_w).itemsCenter();
        defer r.end();
        if (s.step >= questions) {
            ui.text(c, "Change any of this in Settings", set.st(c, 12, .{ .color = k.faint }));
        } else {
            ui.key(c, "setup-skip");
            const sk = ui.div(c).row().py(4).hover(k.ink(0.04)).rounded(6);
            defer sk.end();
            ui.text(c, "Skip setup", set.st(c, 12, .{ .color = if (sk.hovered()) k.text else k.muted }));
            if (sk.clicked()) finish(a, true);
        }
    }
}

fn card(c: *ui.Context, k: theme.Colors, selected: bool) ui.Div {
    var d = ui.div(c).row().wFull().px(16).py(14).gap(12).itemsCenter().rounded(12).borderW(1);
    d = if (selected) d.border(k.text).bg(k.card) else d.border(k.border).bg(k.card);
    return d;
}

fn checkCircle(c: *ui.Context, k: theme.Colors, on: bool) void {
    var d = ui.div(c).row().w(20).h(20).roundedFull().center();
    d = if (on) d.bg(k.text) else d.border(k.border_strong).borderW(1);
    defer d.end();
    if (on) icons.icon(c, .check, 12, k.on_solid, 0);
}

fn status(c: *ui.Context, k: theme.Colors, good: bool, text: []const u8) void {
    const r = ui.div(c).row().gap(6).itemsCenter();
    defer r.end();
    kit.dot(c, 6, if (good) k.success else k.ink(0.25));
    ui.text(c, text, set.st(c, 12, .{ .color = k.muted }));
}

fn agentsPane(c: *ui.Context, a: *App, k: theme.Colors, s: *Setup) void {
    const col = ui.div(c).column().w(right_w).gap(12);
    defer col.end();
    {
        ui.key(c, "setup-agent-graff");
        const g = card(c, k, true);
        defer g.end();
        icons.icon(c, .@"graff-mark", 28, k.text, 0);
        {
            const t = ui.div(c).column().grow().w(0).gap(3);
            defer t.end();
            {
                const n = ui.div(c).row().gap(8).itemsCenter();
                defer n.end();
                ui.text(c, "Graff", set.st(c, 15, .{ .weight = .semibold, .color = k.text }));
                const b = ui.div(c).row().px(8).py(2).roundedFull().bg(k.success.alpha(0.12));
                defer b.end();
                ui.text(c, "Recommended", set.st(c, 10.5, .{ .weight = .medium, .color = k.success_muted }));
            }
            if (a.harnesses.items.len == 0)
                status(c, k, false, "Checking this computer…")
            else
                status(c, k, true, "Connected with CodeGraff — no extra CLI needed");
        }
        checkCircle(c, k, true);
    }
    set.space(c, 4);
    {
        const hdr = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer hdr.end();
        ui.text(c, "C\u{200A}L\u{200A}A\u{200A}U\u{200A}D\u{200A}E\u{2002}C\u{200A}O\u{200A}D\u{200A}E\u{2002}&\u{2002}C\u{200A}H\u{200A}A\u{200A}T\u{200A}G\u{200A}P\u{200A}T\u{2002}C\u{200A}L\u{200A}I\u{200A}S", set.st(c, 10.5, .{ .weight = .medium, .color = k.muted }));
        ui.spacer(c);
        if (installableMissingCount(a, s) >= 2 and s.installing == null) {
            ui.key(c, "setup-install-both");
            const both = ui.div(c).row().px(10).py(4).roundedFull().gap(5).itemsCenter().bg(k.text).hover(k.text.alpha(0.88));
            defer both.end();
            icons.icon(c, .@"download-minimalistic", 11, k.on_solid, 0);
            ui.text(c, "Install both", set.st(c, 11, .{ .weight = .medium, .color = k.on_solid }));
            if (both.clicked()) installBoth(a);
        }
        if (s.installing == null) {
            ui.key(c, "setup-refresh-clis");
            const ref = ui.div(c).row().px(10).py(4).roundedFull().gap(5).itemsCenter().border(k.border).borderW(1).bg(k.card).hover(k.ink(0.05));
            defer ref.end();
            if (s.refresh_call != null) {
                kit.miniSpinner(c, k.muted);
                ui.text(c, "Checking…", set.st(c, 11, .{ .color = k.muted }));
            } else {
                icons.icon(c, .refresh, 11, k.muted, 0);
                ui.text(c, "Check again", set.st(c, 11, .{ .color = k.muted }));
                if (ref.clicked()) refreshClis(a);
            }
        }
    }
    for (extra_list, 0..) |ex, i| {
        const h = harness(a, ex.id);
        const installed = if (h) |x| x.installed else false;
        const can_install = if (h) |x| x.can_install else false;
        const busy = s.installing == i;
        const picked = s.extras_on[i];
        const border_c = if (picked) k.text else if (busy) k.border_strong else k.border;
        ui.key(c, c.print("setup-extra-{s}", .{ex.id}));
        const card_box = ui.div(c).column().wFull().px(16).py(12).gap(10).rounded(12).border(border_c).borderW(1).bg(k.card);
        defer card_box.end();
        {
            const top = ui.div(c).row().wFull().gap(12).itemsCenter();
            defer top.end();
            {
                const mark = icons.harnessMark(ex.id);
                const tile = ui.div(c).row().w(34).h(34).rounded(8).bg(k.ink(0.04)).center();
                defer tile.end();
                icons.icon(c, mark.name, 20, mark.brand orelse k.text, 0);
            }
            {
                const t = ui.div(c).column().grow().w(0).gap(3);
                defer t.end();
                {
                    const title_row = ui.div(c).row().gap(6).itemsCenter();
                    defer title_row.end();
                    ui.text(c, ex.name, set.st(c, 14, .{ .weight = .medium, .color = k.text }));
                    const badge = ui.div(c).row().px(6).py(2).roundedFull().bg(k.ink(0.06));
                    defer badge.end();
                    ui.text(c, ex.cli, set.st(c, 10, .{ .mono = true, .color = k.muted }));
                }
                if (!s.extras_seen)
                    status(c, k, false, "Checking this computer…")
                else if (busy) {
                    const sr = ui.div(c).row().gap(6).itemsCenter();
                    defer sr.end();
                    kit.miniSpinner(c, k.muted);
                    ui.text(c, "Installing CLI on this computer…", set.st(c, 12, .{ .color = k.muted }));
                } else if (installed and picked)
                    status(c, k, true, "Optional, on")
                else if (installed)
                    status(c, k, true, "Optional, ready")
                else
                    status(c, k, false, "Not installed on this computer");
            }
            if (busy) {
                ui.key(c, c.print("setup-cancel-{s}", .{ex.id}));
                const cancel_btn = ui.div(c).row().px(10).py(5).rounded(7).border(k.border).borderW(1).hover(k.ink(0.05));
                defer cancel_btn.end();
                ui.text(c, "Cancel", set.st(c, 11.5, .{ .color = k.muted }));
                if (cancel_btn.clicked()) cancelInstall(a);
            } else if (installed) {
                checkCircle(c, k, picked);
            } else if (s.extras_seen and can_install) {
                const blocked = s.installing != null;
                ui.key(c, c.print("setup-install-{s}", .{ex.id}));
                var inst = ui.div(c).row().px(11).py(5).rounded(7).gap(5).itemsCenter().bg(if (blocked) k.ink(0.15) else k.text);
                if (!blocked) inst = inst.hover(k.text.alpha(0.88));
                defer inst.end();
                icons.icon(c, .@"download-minimalistic", 11.5, if (blocked) k.muted else k.on_solid, 0);
                ui.text(c, "Install CLI", set.st(c, 11.5, .{ .weight = .medium, .color = if (blocked) k.muted else k.on_solid }));
                if (!blocked and inst.clicked()) installExtra(a, i);
            }
            if (installed and !busy and top.clicked()) {
                s.extras_on[i] = !s.extras_on[i];
                a.redraw();
            }
        }
        if (s.extras_seen and !installed and !busy) {
            const cmd_bar = ui.div(c).row().wFull().px(10).py(6).rounded(8).bg(k.shell).border(k.border).borderW(1).gap(8).itemsCenter();
            defer cmd_bar.end();
            ui.text(c, "$", set.st(c, 11, .{ .mono = true, .color = k.faint }));
            kit.ellipsisText(c, ex.cmd, set.st(c, 11, .{ .mono = true, .color = k.muted }), right_w - 134);
            ui.spacer(c);
            const copied = s.copied == i and c.time < s.copied_until;
            ui.key(c, c.print("setup-copy-{s}", .{ex.id}));
            const cp = ui.div(c).row().px(8).py(3).rounded(6).gap(4).itemsCenter().bg(k.ink(0.05)).hover(k.ink(0.09));
            defer cp.end();
            icons.icon(c, if (copied) .check else .copy, 11, if (copied) k.success else k.muted, 0);
            ui.text(c, if (copied) "Copied" else "Copy", set.st(c, 11, .{ .weight = .medium, .color = if (copied) k.success else k.muted }));
            if (cp.clicked()) {
                c.clipboard.write(c.clipboard.ctx, ex.cmd);
                s.copied = i;
                s.copied_until = c.time + 2.0;
                a.redraw();
            }
        }
    }
    const note = ui.div(c).column().w(right_w).pt(2);
    defer note.end();
    ui.text(c, "Built-in Graff works without installing anything. Or install either CLI above and click Check again once it finishes.", set.st(c, 12, .{ .wrap = true, .color = k.faint }));
}

fn effortPane(c: *ui.Context, a: *App, k: theme.Colors, s: *Setup) void {
    const col = ui.div(c).column().w(right_w).gap(16);
    defer col.end();
    const ms = models(a);
    {
        const tabs = ui.div(c).row().gap(6).p(4).rounded(10).bg(k.ink(0.04));
        defer tabs.end();
        if (ms.len == 0) ui.text(c, "Loading Graff's models…", set.st(c, 12, .{ .color = k.muted }));
        for (ms, 0..) |m, i| {
            const on = i == @min(s.model, ms.len - 1);
            ui.key(c, c.print("setup-model-{d}", .{i}));
            var t = ui.div(c).row().px(12).py(6).rounded(7);
            t = if (on) t.bg(k.card).border(k.border).borderW(1) else t.hover(k.ink(0.05));
            defer t.end();
            kit.ellipsisText(c, m.label, set.st(c, 12.5, .{ .weight = if (on) .medium else .regular, .color = if (on) k.text else k.muted }), 140);
            if (t.clicked() and !on) {
                s.model = i;
                s.level = null;
                a.redraw();
            }
        }
    }
    const e = effort(a, s);
    const lv: ?[]const u8 = if (e) |x| (if (x.at) |i| x.levels[i] else null) else null;
    {
        const t = ui.div(c).column().w(right_w).gap(4);
        defer t.end();
        ui.text(c, if (lv) |l| rules.reasoningLabel(l) else "Default", set.st(c, 34, .{ .weight = .semibold, .color = k.text }));
        ui.text(c, if (lv) |l| levelBlurb(l) else "Graff picks how hard to think.", set.st(c, 14, .{ .wrap = true, .color = k.muted }));
    }
    if (e) |x| if (x.levels.len > 0) {
        const at = x.at orelse 0;
        {
            const r = ui.div(c).row().w(right_w).gap(10).itemsCenter();
            defer r.end();
            ui.key(c, "setup-effort-less");
            if (kit.iconButton(c, k, .@"alt-arrow-left", .{ .size = 30, .radius = 8, .icon = 14 })) nudge(a, -1);
            {
                const bars = ui.div(c).row().grow().w(0).gap(4);
                defer bars.end();
                for (x.levels, 0..) |_, i| {
                    ui.key(c, c.print("setup-effort-{d}", .{i}));
                    const b = ui.div(c).grow().w(0).h(10).rounded(3).bg(if (i <= at) k.text else k.ink(0.1));
                    defer b.end();
                    if (b.clicked()) {
                        s.level = i;
                        a.redraw();
                    }
                }
            }
            ui.key(c, "setup-effort-more");
            if (kit.iconButton(c, k, .@"alt-arrow-right", .{ .size = 30, .radius = 8, .icon = 14 })) nudge(a, 1);
        }
        ui.text(c, c.print("Level {d} of {d}", .{ at + 1, x.levels.len }), set.st(c, 12, .{ .color = k.faint }));
    };
    ui.text(c, "Graff's models from your CodeGraff account", set.st(c, 12, .{ .color = k.faint }));
}

fn autonomyPane(c: *ui.Context, k: theme.Colors, s: *Setup) void {
    const col = ui.div(c).column().w(right_w).gap(16);
    defer col.end();
    {
        const t = ui.div(c).column().w(right_w).gap(4);
        defer t.end();
        ui.text(c, s.autonomy.label(), set.st(c, 34, .{ .weight = .semibold, .color = k.text }));
        ui.text(c, s.autonomy.blurb(), set.st(c, 14, .{ .wrap = true, .color = k.muted }));
    }
    {
        const stops = ui.div(c).row().w(right_w).gap(6).p(4).rounded(10).bg(k.ink(0.04));
        defer stops.end();
        for (Autonomy.all) |x| {
            const on = x == s.autonomy;
            ui.key(c, c.print("setup-autonomy-{s}", .{x.wire()}));
            var t = ui.div(c).row().grow().w(0).py(8).rounded(7).justifyCenter();
            t = if (on) t.bg(k.card).border(k.border).borderW(1) else t.hover(k.ink(0.05));
            defer t.end();
            ui.text(c, x.label(), set.st(c, 12.5, .{ .weight = if (on) .medium else .regular, .color = if (on) k.text else k.muted }));
            if (t.clicked()) s.autonomy = x;
        }
    }
    {
        const list = card(c, k, false);
        defer list.end();
        const inner = ui.div(c).column().grow().w(0).gap(10);
        defer inner.end();
        for (capabilities, 0..) |cap, i| {
            const yes = i < s.autonomy.allowed();
            const r = ui.div(c).row().gap(10).itemsCenter();
            defer r.end();
            icons.icon(c, if (yes) .check else .close, 14, if (yes) k.success else k.faint, 0);
            ui.text(c, cap, set.st(c, 13, .{ .color = if (yes) k.text else k.muted }));
            if (!yes) {
                ui.spacer(c);
                ui.text(c, "Asks first", set.st(c, 11.5, .{ .color = k.faint }));
            }
        }
    }
}

fn notifyPane(c: *ui.Context, k: theme.Colors, s: *Setup) void {
    const col = ui.div(c).column().w(right_w).gap(12);
    defer col.end();
    const choices = [_]struct { on: bool, icon: icons.Name, title: []const u8, body: []const u8, key: []const u8 }{
        .{ .on = true, .icon = .bell, .title = "Yes, ping me", .body = "When a session needs your input, finishes, or fails.", .key = "setup-notify-yes" },
        .{ .on = false, .icon = .check, .title = "No, I'll check in", .body = "Sessions still show their status in the sidebar.", .key = "setup-notify-no" },
    };
    for (choices) |ch| {
        const picked = s.notify == ch.on;
        ui.key(c, ch.key);
        const d = card(c, k, picked);
        defer d.end();
        icons.icon(c, ch.icon, 20, k.text, 0);
        {
            const t = ui.div(c).column().grow().w(0).gap(2);
            defer t.end();
            ui.text(c, ch.title, set.st(c, 15, .{ .weight = .semibold, .color = k.text }));
            ui.text(c, ch.body, set.st(c, 12, .{ .color = k.muted }));
        }
        checkCircle(c, k, picked);
        if (d.clicked()) s.notify = ch.on;
    }
    const note = ui.div(c).column().w(right_w).pt(4);
    defer note.end();
    ui.text(c, "Sounds and the background-only rule live in Settings > Notifications.", set.st(c, 12, .{ .wrap = true, .color = k.faint }));
}

fn summary(c: *ui.Context, k: theme.Colors, key: []const u8, value: []const u8) void {
    const r = ui.div(c).column().grow().w(0).gap(2);
    defer r.end();
    ui.text(c, key, set.st(c, 11, .{ .color = k.muted }));
    kit.ellipsisText(c, value, set.st(c, 14, .{ .weight = .medium, .color = k.text }), (right_w - 40) / 2 - 8);
}

fn readyPane(c: *ui.Context, a: *App, k: theme.Colors, s: *Setup) void {
    const col = ui.div(c).column().w(right_w).gap(18);
    defer col.end();
    var names: std.ArrayList(u8) = .empty;
    names.appendSlice(c.alloc(), "Graff") catch {};
    for (extra_list, 0..) |ex, i| if (s.extras_on[i]) {
        names.appendSlice(c.alloc(), ", ") catch {};
        names.appendSlice(c.alloc(), ex.summary_name) catch {};
    };
    const e = effort(a, s);
    const model = if (e) |x| x.model.label else "Default";
    const thinking = if (e) |x| (if (x.at) |i| rules.reasoningLabel(x.levels[i]) else "Default") else "Default";
    {
        const d = ui.div(c).column().w(right_w).p(20).gap(16).rounded(12).border(k.border).borderW(1).bg(k.card);
        defer d.end();
        const rows = [_][4][]const u8{
            .{ "Agents", names.items, "Model", model },
            .{ "Thinking", thinking, "Access", s.autonomy.label() },
            .{ "Notifications", if (s.notify) "Desktop banners on" else "Off", "", "" },
        };
        for (rows) |row| {
            const r = ui.div(c).row().wFull().gap(16);
            defer r.end();
            summary(c, k, row[0], row[1]);
            if (row[2].len > 0) summary(c, k, row[2], row[3]) else ui.spacer(c);
        }
    }
    ui.text(c, "Start with a prompt, or open an empty session", set.st(c, 12, .{ .color = k.muted }));
    const chips = ui.div(c).row().gap(8);
    defer chips.end();
    for (starter_labels, 0..) |label, i| {
        const on = s.starter == i;
        ui.key(c, c.print("setup-starter-{d}", .{i}));
        var ch = ui.div(c).row().px(14).py(8).roundedFull().borderW(1);
        ch = if (on) ch.border(k.text).bg(k.selected) else ch.border(k.border).bg(k.card).hover(k.ink(0.04));
        defer ch.end();
        ui.text(c, label, set.st(c, 13, .{ .color = k.text }));
        if (ch.clicked()) {
            s.starter = if (on) null else i;
            a.redraw();
        }
    }
}

const testing = std.testing;

test "autonomy's wire names round trip, and a reply reads" {
    for (Autonomy.all) |x| try testing.expectEqual(x, Autonomy.parse(x.wire()).?);
    try testing.expect(Autonomy.parse("danger") == null);
    var o: json.ObjectMap = .empty;
    defer o.deinit(testing.allocator);
    try o.put(testing.allocator, "autonomy", .{ .string = "workspace" });
    try o.put(testing.allocator, "chosen", .{ .bool = true });
    const r = readAutonomy(.{ .object = o }).?;
    try testing.expectEqual(Autonomy.workspace, r.autonomy);
    try testing.expect(r.chosen);
}

test "the access a level allows grows with it" {
    try testing.expect(Autonomy.read_only.allowed() < Autonomy.workspace.allowed());
    try testing.expectEqual(capabilities.len, Autonomy.full_access.allowed());
}
