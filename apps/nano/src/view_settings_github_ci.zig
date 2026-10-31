//! Settings › GitHub CI, as the GPUI app's (settings/github_ci.rs): run
//! GitHub Actions jobs (`runs-on: codegraff`) on Codegraff sandboxes.
//!
//! Not connected, the page explains what happens and what it costs, offers
//! Connect GitHub (the Codegraff app's install page, in the browser) and a
//! workflow snippet to copy; after Connect it re-reads every 10 seconds for
//! up to 5 minutes. Connected, each installation has its monthly budgets, a
//! cap on concurrent jobs and its repositories (on or off, and their default
//! size), with the recent jobs below. Everything reads the engine's
//! `CodegraffGithubRunners` (the rules in runners.zig) and acts through
//! `CodegraffGithubRunnerAction`.
const std = @import("std");
const rules = @import("rules.zig");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const mcp = @import("view_settings_mcp.zig");
const rpc = @import("rpc.zig");
const runners = @import("runners.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

/// While a job is queued or running, the page re-reads this often.
const jobs_poll_s: f64 = 20;
/// How many recent jobs the page lists.
const jobs_shown: usize = 12;
/// How long Copy says "Copied".
const copied_s: f64 = 1.5;

const phi: f32 = 1.618;

/// Which budget an input edits.
pub const Budget = enum {
    monthly,
    /// Jobs from outside contributors (fork pull requests).
    untrusted,

    fn key(b: Budget) []const u8 {
        return switch (b) {
            .monthly => "monthlyBudgetMicroUsd",
            .untrusted => "untrustedBudgetMicroUsd",
        };
    }

    fn current(b: Budget, i: *const runners.Installation) ?i64 {
        return switch (b) {
            .monthly => i.monthly_budget_micro_usd,
            .untrusted => i.untrusted_budget_micro_usd,
        };
    }
};

/// An installation budget's amount field, and why its last Save was refused.
const Input = struct {
    /// "<installation>:<budget key>".
    key: []u8,
    buf: *ui.TextBuffer,
    problem: ?[]const u8 = null,
};

/// The page's state, kept between visits as the GPUI app keeps its page.
pub const Page = struct {
    phase: enum { idle, loading, ready, failed } = .idle,
    /// The answer, in its own arena; null when signed out.
    arena: ?std.heap.ArenaAllocator = null,
    runners: ?runners.Runners = null,
    /// Why the first read failed.
    failure: std.ArrayList(u8) = .empty,
    /// An action's (or a later read's) error, over the page; a click clears it.
    notice: std.ArrayList(u8) = .empty,
    /// The action in flight (`"<installation>:<what>"`); one at a time.
    busy: ?[]u8 = null,
    /// The installation whose Disconnect asks "for good?".
    confirm: ?[]u8 = null,
    inputs: std.ArrayList(Input) = .empty,
    /// The repository whose size menu is open (`"<installation>\n<name>"`),
    /// and its trigger as last laid out.
    size_menu: ?[]u8 = null,
    size_anchor: ?ui.Rect = null,
    /// After Connect: keep re-reading until then (or an installation appears).
    connect_until: ?f64 = null,
    copied_until: ?f64 = null,
    next_poll: ?f64 = null,

    pub fn deinit(p: *Page, gpa: Allocator) void {
        if (p.arena) |*ar| ar.deinit();
        p.failure.deinit(gpa);
        p.notice.deinit(gpa);
        if (p.busy) |b| gpa.free(b);
        if (p.confirm) |b| gpa.free(b);
        if (p.size_menu) |b| gpa.free(b);
        for (p.inputs.items) |i| {
            gpa.free(i.key);
            gpa.destroy(i.buf);
        }
        p.inputs.deinit(gpa);
    }

    fn isBusy(p: *const Page, what: []const u8) bool {
        return if (p.busy) |b| std.mem.eql(u8, b, what) else false;
    }

    fn input(p: *Page, key: []const u8) ?*Input {
        for (p.inputs.items) |*i| if (std.mem.eql(u8, i.key, key)) return i;
        return null;
    }
};

fn setText(gpa: Allocator, l: *std.ArrayList(u8), text: []const u8) void {
    l.clearRetainingCapacity();
    l.appendSlice(gpa, text) catch {};
}

fn replace(gpa: Allocator, slot: *?[]u8, text: ?[]const u8) void {
    if (slot.*) |old| gpa.free(old);
    slot.* = if (text) |t| gpa.dupe(u8, t) catch null else null;
}

/// Read the runners. Rows already on screen stay through a reload.
pub fn load(a: *App) void {
    const p = &a.view.github_ci;
    if (a.engine.state != .connected) {
        p.phase = .failed;
        setText(a.gpa, &p.failure, "Engine not connected");
        return;
    }
    if (p.phase != .ready) p.phase = .loading;
    a.call("CodegraffGithubRunners", .{}, .of(App, a, onLoad));
}

fn onLoad(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| apply(a, v),
        .err => |e| failed(a, if (std.mem.eql(u8, e, "not connected")) "Engine not connected" else e),
        else => {},
    }
    a.redraw();
}

/// Show an answer as if the engine gave it (tests and fixtures).
pub fn setRunners(a: *App, v: json.Value) void {
    apply(a, v);
}

fn apply(a: *App, v: json.Value) void {
    const p = &a.view.github_ci;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    const got = runners.parse(arena.allocator(), v) catch {
        arena.deinit();
        return failed(a, "Unexpected reply");
    };
    if (p.arena) |*old| old.deinit();
    p.arena = arena;
    p.runners = got;
    if (p.runners) |*rs| {
        ensureInputs(a, rs);
        // The installation the user went to the browser for has arrived.
        if (rs.installations.len > 0) p.connect_until = null;
    }
    p.phase = .ready;
    schedulePoll(a);
}

fn failed(a: *App, why: []const u8) void {
    const p = &a.view.github_ci;
    if (p.phase == .ready) setText(a.gpa, &p.notice, why) else {
        p.phase = .failed;
        setText(a.gpa, &p.failure, why);
    }
    schedulePoll(a);
}

/// Re-read on a timer while waiting for a Connect to land or while a job is
/// working.
fn schedulePoll(a: *App) void {
    const p = &a.view.github_ci;
    const watching = if (p.connect_until) |t| a.now < t else false;
    if (!watching) p.connect_until = null;
    const working = p.phase == .ready and if (p.runners) |*rs| runners.jobsWorking(rs) else false;
    p.next_poll = if (watching) a.now + runners.connect_poll_s else if (working) a.now + jobs_poll_s else null;
}

/// One input per installation budget, made on first sight with the saved
/// amount.
fn ensureInputs(a: *App, rs: *const runners.Runners) void {
    const p = &a.view.github_ci;
    for (rs.installations) |*inst| for (std.enums.values(Budget)) |b| {
        const key = std.fmt.allocPrint(a.gpa, "{s}:{s}", .{ inst.installation_id, b.key() }) catch return;
        if (p.input(key) != null) {
            a.gpa.free(key);
            continue;
        }
        const buf = a.gpa.create(ui.TextBuffer) catch return a.gpa.free(key);
        buf.* = .{};
        const text = runners.budgetInputText(a.gpa, b.current(inst)) catch "";
        defer a.gpa.free(text);
        buf.set(text);
        p.inputs.append(a.gpa, .{ .key = key, .buf = buf }) catch {
            a.gpa.free(key);
            a.gpa.destroy(buf);
        };
    };
}

/// Run one `CodegraffGithubRunnerAction`, then re-read. `busy` (owned)
/// names it for its button.
fn act(a: *App, busy: []u8, params: anytype) void {
    const p = &a.view.github_ci;
    if (p.busy != null or a.engine.state != .connected) return a.gpa.free(busy);
    p.busy = busy;
    p.notice.clearRetainingCapacity();
    a.call("CodegraffGithubRunnerAction", params, .of(App, a, onAction));
    a.redraw();
}

fn onAction(a: *App, _: u64, r: rpc.Reply) void {
    const p = &a.view.github_ci;
    replace(a.gpa, &p.busy, null);
    switch (r) {
        .err => |e| setText(a.gpa, &p.notice, e),
        else => {},
    }
    load(a);
    a.redraw();
}

fn busyKey(a: *App, id: []const u8, what: []const u8) ?[]u8 {
    return std.fmt.allocPrint(a.gpa, "{s}:{s}", .{ id, what }) catch null;
}

pub fn saveBudget(a: *App, id: []const u8, b: Budget) void {
    const p = &a.view.github_ci;
    var kb: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&kb, "{s}:{s}", .{ id, b.key() }) catch return;
    const in = p.input(key) orelse return;
    const amount = switch (runners.parseBudget(in.buf.text())) {
        .ok => |n| n,
        .err => |problem| {
            in.problem = problem;
            return a.redraw();
        },
    };
    in.problem = null;
    const text = runners.budgetInputText(a.gpa, amount) catch "";
    defer a.gpa.free(text);
    in.buf.set(text);
    const busy = busyKey(a, id, b.key()) orelse return;
    switch (b) {
        .monthly => act(a, busy, .{ .action = "installation", .installationId = id, .monthlyBudgetMicroUsd = amount }),
        .untrusted => act(a, busy, .{ .action = "installation", .installationId = id, .untrustedBudgetMicroUsd = amount }),
    }
}

fn setConcurrent(a: *App, id: []const u8, max: u32) void {
    const busy = busyKey(a, id, "concurrent") orelse return;
    act(a, busy, .{ .action = "installation", .installationId = id, .maxConcurrent = max });
}

fn repoBusy(a: *App, id: []const u8, name: []const u8) ?[]u8 {
    return std.fmt.allocPrint(a.gpa, "{s}:repo:{s}", .{ id, name }) catch null;
}

fn setRepoEnabled(a: *App, id: []const u8, name: []const u8, on: bool) void {
    const busy = repoBusy(a, id, name) orelse return;
    act(a, busy, .{ .action = "repo", .installationId = id, .fullName = name, .enabled = on });
}

fn setRepoSize(a: *App, id: []const u8, name: []const u8, size: []const u8) void {
    const busy = repoBusy(a, id, name) orelse return;
    act(a, busy, .{ .action = "repo", .installationId = id, .fullName = name, .defaultSize = size });
}

fn disconnect(a: *App, id: []const u8) void {
    const p = &a.view.github_ci;
    if (p.confirm == null or !std.mem.eql(u8, p.confirm.?, id)) {
        replace(a.gpa, &p.confirm, id);
        return a.redraw();
    }
    replace(a.gpa, &p.confirm, null);
    const busy = busyKey(a, id, "disconnect") orelse return;
    act(a, busy, .{ .action = "disconnect", .installationId = id });
}

/// Open the Codegraff app's install page and watch for the installation to
/// arrive.
fn connect(a: *App, url: []const u8) void {
    _ = nanoui.shell.openUrl(url);
    a.view.github_ci.connect_until = a.now + runners.connect_watch_s;
    schedulePoll(a);
    a.redraw();
}

fn copySnippet(c: *ui.Context, a: *App) void {
    c.clipboard.write(c.clipboard.ctx, runners.yaml_snippet);
    a.view.github_ci.copied_until = c.time + copied_s;
}

fn closeSizeMenu(a: *App) void {
    replace(a.gpa, &a.view.github_ci.size_menu, null);
    a.view.github_ci.size_anchor = null;
}

// Rendering.

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const p = &a.view.github_ci;
    if (p.phase == .idle) load(a);
    if (p.next_poll) |t| {
        if (c.time >= t) {
            p.next_poll = null;
            load(a);
        } else c.frameIn(@floatCast(t - c.time));
    }
    if (p.copied_until) |t| {
        if (c.time >= t) p.copied_until = null else c.frameIn(@floatCast(t - c.time));
    }
    {
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        set.header(c, k, "GitHub CI", null);
        ui.spacer(c);
        if (ghost(c, k, .{ .label = "Refresh", .icon = .refresh, .bordered = true, .dim = p.phase == .loading })) load(a);
    }
    set.subtitle(c, k, "Run GitHub Actions jobs on Codegraff sandboxes, billed per second from your Codegraff credit.", false);
    if (p.notice.items.len > 0) if (errorStrip(c, k, p.notice.items)) p.notice.clearRetainingCapacity();
    switch (p.phase) {
        .idle, .loading => {
            set.space(c, 24);
            ui.text(c, "Loading GitHub CI…", set.st(c, 12.5, .{ .color = k.muted.alpha(0.6) }));
        },
        .failed => {
            _ = errorStrip(c, k, p.failure.items);
            set.space(c, 8);
            const r = ui.div(c).row();
            defer r.end();
            if (ghost(c, k, .{ .label = "Retry" })) load(a);
        },
        .ready => {
            const rs: ?*const runners.Runners = if (p.runners) |*r| r else null;
            switch (runners.panel(rs)) {
                .signed_out => {
                    const cd = card(c, k, 16);
                    defer cd.end();
                    const r = set.row(c, k, true, false);
                    defer r.end();
                    quiet(c, k, "Sign in with Codegraff from the account menu to run GitHub Actions on Codegraff.", rowInner());
                },
                .unavailable, .coming_soon, .not_connected => |which| intro(c, a, k, rs.?, which),
                .connected => connected(c, a, k, rs.?),
            }
        },
    }
}

/// `error_strip`: red-tinted, a warning triangle, the words wrapped at the
/// column's width. True when clicked.
fn errorStrip(c: *ui.Context, k: theme.Colors, message: []const u8) bool {
    set.space(c, 16);
    const s = ui.div(c).row().wFull().px(17).py(13).gap(8).rounded(12).border(k.danger.alpha(0.2)).borderW(1).bg(k.danger.alpha(0.06));
    defer s.end();
    {
        const ic = ui.div(c).column().pt(2);
        defer ic.end();
        icons.icon(c, .@"danger-triangle", 16, k.danger_muted.alpha(0.9), 0);
    }
    const w = ui.div(c).column().w(@max(set.inner_w - 2 * 17 - 16 - 8, 80));
    {
        defer w.end();
        ui.text(c, message, set.st(c, 12.5, .{ .wrap = true, .color = k.danger_muted.alpha(0.9) }));
    }
    return s.clicked();
}

/// A card row's inside width: the column less the card's edges and the
/// row's insets.
fn rowInner() f32 {
    return set.inner_w - 2 - 2 * 20;
}

/// `section_card`, `mt` below what's above.
fn card(c: *ui.Context, k: theme.Colors, mt: f32) ui.Div {
    set.space(c, mt);
    return ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
}

/// The quiet line (`quiet_text`), wrapped at `w`.
fn quiet(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    const q = ui.div(c).column().w(@max(w, 80));
    defer q.end();
    ui.text(c, text, set.st(c, 12, .{ .wrap = true, .color = k.muted }));
}

/// `row_title`, cut with an ellipsis at `w`.
fn title(c: *ui.Context, k: theme.Colors, text: []const u8, w: f32) void {
    kit.ellipsisText(c, text, set.st(c, 13, .{ .weight = .medium, .color = k.text }), @max(w, 40));
}

const Ghost = struct {
    label: []const u8,
    icon: ?icons.Name = null,
    /// With the hairline edge some of the page's actions carry.
    bordered: bool = false,
    dim: bool = false,
    color: ?ui.Color = null,
};

/// `ghost_action`'s width.
fn ghostW(c: *ui.Context, g: Ghost) f32 {
    return 2 * 10 + (if (g.bordered) @as(f32, 2) else 0) + (if (g.icon != null) @as(f32, 14 + 6) else 0) + c.text.width(g.label, .{ .size = 12 });
}

/// `ghost_action`: 12-point muted words, maybe an icon and an edge, a wash
/// under the pointer. True when clicked.
fn ghost(c: *ui.Context, k: theme.Colors, g: Ghost) bool {
    const pad: f32 = if (g.bordered) 1 else 0;
    var b = ui.div(c).row().px(10 + pad).py(6 + pad).gap(6).itemsCenter().rounded(8).hover(k.ink(0.06));
    if (g.bordered) b = b.border(k.border).borderW(1);
    if (g.dim) b = b.opacity(0.5);
    defer b.end();
    const hot = b.hovered();
    if (g.icon) |i| icons.icon(c, i, 14, k.muted, 0);
    ui.text(c, g.label, set.st(c, 12, .{ .color = g.color orelse if (hot) k.text else k.muted }));
    return b.clicked();
}

/// The explanation, Connect and the snippet: everything before an
/// installation exists (`render_intro`).
fn intro(c: *ui.Context, a: *App, k: theme.Colors, rs: *const runners.Runners, which: runners.Panel) void {
    const p = &a.view.github_ci;
    const url = runners.installUrl(rs);
    const open = which == .not_connected and url != null;
    const label = switch (which) {
        .coming_soon, .unavailable => "Coming soon",
        else => if (p.connect_until != null) "Waiting for GitHub…" else "Connect GitHub",
    };
    const note: ?[]const u8 = switch (which) {
        .unavailable => "GitHub CI isn't available on Codegraff yet. This page fills in once it is.",
        .coming_soon => "GitHub CI is coming soon to your Codegraff account.",
        else => if (p.connect_until != null)
            "Finish installing the Codegraff app on GitHub in your browser. This page updates when you come back."
        else if (url == null)
            "Codegraff didn't send an install link. Try Refresh."
        else
            null,
    };
    const label_style = set.st(c, 13, .{ .weight = .medium, .color = if (open) k.on_solid else k.muted.alpha(0.7) });
    const button_w = 2 * 12 + c.text.width(label, label_style);
    const cd = card(c, k, 16);
    defer cd.end();
    {
        const r = set.row(c, k, true, false).itemsStart();
        defer r.end();
        set.tile(c, k, .@"pull-request");
        const w = rowInner() - 36 - 14 - 14 - button_w;
        {
            const col = ui.div(c).column().w(w).gap(4);
            defer col.end();
            title(c, k, "Run GitHub Actions on Codegraff", w);
            quiet(c, k, runners.explainer, w);
            if (note) |n| {
                const nb = ui.div(c).column().w(w).pt(4);
                defer nb.end();
                ui.text(c, n, set.st(c, 12, .{ .wrap = true, .color = k.muted.alpha(0.8) }));
            }
        }
        const b = ui.div(c).row().px(12).py(6).rounded(8).bg(if (open) k.solid else k.ink(0.06));
        defer b.end();
        ui.text(c, label, label_style);
        if (open and b.clicked()) connect(a, url.?);
    }
    snippet(c, a, k, true);
}

/// The `runs-on: codegraff` snippet with Copy (`render_snippet`).
fn snippet(c: *ui.Context, a: *App, k: theme.Colors, inside: bool) void {
    const copied = a.view.github_ci.copied_until != null;
    const copy: Ghost = .{ .label = if (copied) "Copied" else "Copy", .icon = .copy, .bordered = true };
    if (inside) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsStart();
    defer r.end();
    const w = rowInner() - 12 - ghostW(c, copy);
    {
        const col = ui.div(c).column().w(w).gap(6);
        defer col.end();
        quiet(c, k, "In a workflow, run a job on Codegraff:", w);
        const code = ui.div(c).column().wFull().px(13).py(9).rounded(8).bg(k.ink(0.04)).border(k.border).borderW(1);
        defer code.end();
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, runners.yaml_snippet, "\n"), '\n');
        while (lines.next()) |line| ui.text(c, line, set.st(c, 12, .{ .mono = true, .color = k.text }));
    }
    if (ghost(c, k, copy)) copySnippet(c, a);
}

fn connected(c: *ui.Context, a: *App, k: theme.Colors, rs: *const runners.Runners) void {
    const p = &a.view.github_ci;
    for (rs.installations, 0..) |*inst, ix| installation(c, a, k, rs, inst, ix);
    set.space(c, 8);
    {
        const r = ui.div(c).row().wFull().justifyEnd();
        defer r.end();
        if (runners.installUrl(rs)) |url| {
            if (ghost(c, k, .{ .label = if (p.connect_until != null) "Waiting for GitHub…" else "Connect another account" })) connect(a, url);
        }
    }
    jobs(c, a, k, rs);
    const cd = card(c, k, 16);
    defer cd.end();
    snippet(c, a, k, false);
}

fn installation(c: *ui.Context, a: *App, k: theme.Colors, rs: *const runners.Runners, inst: *const runners.Installation, ix: usize) void {
    const p = &a.view.github_ci;
    const id = inst.installation_id;
    ui.key(c, c.print("github-ci-installation-{d}", .{ix}));
    const confirming = if (p.confirm) |x| std.mem.eql(u8, x, id) else false;
    const disconnecting = p.isBusy(c.print("{s}:disconnect", .{id}));
    const cd = card(c, k, 16);
    defer cd.end();
    {
        const r = set.row(c, k, true, false);
        defer r.end();
        set.tile(c, k, .@"pull-request");
        const g: Ghost = .{
            .label = if (disconnecting) "Disconnecting…" else if (confirming) "Disconnect for good?" else "Disconnect",
            .dim = disconnecting,
            .color = if (confirming) k.danger_muted else null,
        };
        const w = rowInner() - 36 - 14 - 14 - ghostW(c, g);
        {
            const col = ui.div(c).column().w(w);
            defer col.end();
            title(c, k, inst.account, w);
            quiet(c, k, runners.installationMeta(c.alloc(), inst) catch "", w);
        }
        if (ghost(c, k, g)) disconnect(a, id);
    }
    budgetRow(c, a, k, inst, .monthly);
    budgetRow(c, a, k, inst, .untrusted);
    concurrencyRow(c, a, k, inst);
    if (inst.repos.len == 0) {
        const r = set.row(c, k, false, false);
        defer r.end();
        quiet(c, k, "No repositories yet. Choose them in the Codegraff app's settings on GitHub.", rowInner());
    }
    for (inst.repos) |*repo| repoRow(c, a, k, inst, repo, rs.sizes);
}

fn budgetRow(c: *ui.Context, a: *App, k: theme.Colors, inst: *const runners.Installation, b: Budget) void {
    const p = &a.view.github_ci;
    const id = inst.installation_id;
    const key = c.print("{s}:{s}", .{ id, b.key() });
    ui.key(c, c.print("github-ci-budget-{s}", .{key}));
    const busy = p.isBusy(key);
    const head = switch (b) {
        .monthly => "Monthly budget",
        .untrusted => "Fork pull request budget",
    };
    const description = switch (b) {
        .monthly => runners.spendLine(c.alloc(), inst) catch "",
        .untrusted => "Jobs from outside contributors stop at this amount each month.",
    };
    const in = p.input(key);
    const save: Ghost = .{ .label = if (busy) "Saving…" else "Save", .bordered = true, .dim = busy };
    const r = set.row(c, k, false, false);
    defer r.end();
    const w = rowInner() - (if (in != null) @as(f32, 112 + 14) else 0) - 14 - ghostW(c, save);
    {
        const col = ui.div(c).column().w(w);
        defer col.end();
        title(c, k, head, w);
        quiet(c, k, description, w);
        if (b == .monthly) if (runners.budgetFraction(inst)) |fraction| {
            const level = if (fraction >= 0.95) k.danger else if (fraction >= 0.80) k.warning else k.accent;
            const mw = @min(w, 260);
            const box = ui.div(c).column().pt(6);
            defer box.end();
            const meter = ui.div(c).row().w(mw).h(5).roundedFull().bg(k.ink(0.07)).clip();
            defer meter.end();
            if (fraction > 0) _ = c.leaf(.{ .width = .{ .px = mw * @max(fraction, 0.015) }, .height = .{ .px = 5 }, .radius = 2.5, .background = level.alpha(0.85) }, .none, null);
        };
        if (in) |i| if (i.problem) |problem| {
            const pb = ui.div(c).column().w(w).pt(4);
            defer pb.end();
            ui.text(c, problem, set.st(c, 12, .{ .wrap = true, .color = k.danger_muted.alpha(0.9) }));
        };
    }
    if (in) |i| {
        const f = ui.div(c).row().w(112).px(9).py(3).gap(4).itemsCenter().rounded(6).border(if (i.problem != null) k.danger.alpha(0.5) else k.border).borderW(1).bg(k.ink(0.03));
        defer f.end();
        ui.text(c, "$", set.st(c, 12.5, .{ .color = k.muted }));
        const fw = ui.div(c).row().grow().w(0);
        defer fw.end();
        // A ComposerInput: its own 14-point text on a 22.75-point line
        // (less the 2 points a bare field keeps above and below).
        const res = ui.textField(c, i.buf, .{ .placeholder = "Amount", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .line_height = 22.75 });
        if (res.changed) i.problem = null;
        if (res.submitted) saveBudget(a, id, b);
    }
    if (ghost(c, k, save)) saveBudget(a, id, b);
}

fn concurrencyRow(c: *ui.Context, a: *App, k: theme.Colors, inst: *const runners.Installation) void {
    const p = &a.view.github_ci;
    const id = inst.installation_id;
    const current = std.math.clamp(inst.max_concurrent orelse 1, 1, runners.max_concurrent);
    const busy = p.isBusy(c.print("{s}:concurrent", .{id}));
    const r = set.row(c, k, false, false);
    defer r.end();
    const w = rowInner() - 14 - (24 + 8 + 16 + 8 + 24);
    {
        const col = ui.div(c).column().w(w);
        defer col.end();
        title(c, k, "Concurrent jobs", w);
        quiet(c, k, c.print("How many jobs run at once, 1 to {d}. More wait in the queue.", .{runners.max_concurrent}), w);
    }
    const s = ui.div(c).row().gap(8).itemsCenter();
    defer s.end();
    for ([_]i32{ -1, 0, 1 }) |delta| {
        if (delta == 0) {
            var v = ui.div(c).row().w(16).justifyCenter();
            if (busy) v = v.opacity(0.5);
            defer v.end();
            ui.text(c, c.print("{d}", .{current}), set.st(c, 13, .{ .color = k.text }));
            continue;
        }
        const next = runners.stepConcurrent(current, delta);
        const enabled = next != current and !busy;
        var b = ui.div(c).row().size(24, 24).center().rounded(6).border(k.border).borderW(1);
        if (enabled) b = b.hover(k.ink(0.06));
        defer b.end();
        ui.text(c, if (delta < 0) "−" else "+", set.st(c, 13, .{ .color = if (enabled) k.text else k.muted.alpha(0.4) }));
        if (enabled and b.clicked()) setConcurrent(a, id, next);
    }
}

fn repoRow(c: *ui.Context, a: *App, k: theme.Colors, inst: *const runners.Installation, repo: *const runners.Repo, sizes: []const runners.Size) void {
    const p = &a.view.github_ci;
    const id = inst.installation_id;
    const name = repo.full_name;
    ui.key(c, c.print("github-ci-repo-{s}-{s}", .{ id, name }));
    const busy = p.isBusy(c.print("{s}:repo:{s}", .{ id, name }));
    const menu_key = c.print("{s}\n{s}", .{ id, name });
    const menu_open = if (p.size_menu) |m| std.mem.eql(u8, m, menu_key) else false;
    const size_label = if (sizes.len > 0) runners.repoSizeLabel(c.alloc(), repo, sizes) catch "" else "";
    const trigger_w: f32 = if (sizes.len > 0) 2 * 9 + c.text.width(size_label, .{ .size = 12 }) + 4 + 12 + 14 else 0;
    const r = set.row(c, k, false, false);
    defer r.end();
    const w = rowInner() - trigger_w - 14 - 40;
    {
        // `flex_1`: the rest of the row, whatever the size label measures.
        const t = ui.div(c).row().grow().w(0).gap(8).itemsCenter();
        defer t.end();
        const badge_w: f32 = if (repo.private) 8 + 2 * 9 + c.text.width("Private", .{ .size = 10.5 }) else 0;
        title(c, k, name, w - badge_w);
        if (repo.private) mcp.badge(c, k, "Private");
    }
    if (sizes.len > 0) {
        const tr = ui.div(c).row().px(9).py(5).gap(4).itemsCenter().rounded(6).border(k.border).borderW(1).hover(k.ink(0.05));
        defer tr.end();
        if (menu_open) p.size_anchor = c.rects.get(c.node(tr.index).id);
        ui.text(c, size_label, set.st(c, 12, .{ .color = k.muted }));
        icons.icon(c, .@"sort-vertical", 12, k.muted.alpha(0.6), 0);
        if (tr.clicked()) {
            if (menu_open) closeSizeMenu(a) else replace(a.gpa, &p.size_menu, menu_key);
        }
    }
    {
        var sw = ui.div(c).row();
        if (busy) sw = sw.opacity(0.5);
        defer sw.end();
        if (set.toggle(c, k, repo.enabled, true)) setRepoEnabled(a, id, name, !repo.enabled);
    }
    if (menu_open) if (p.size_anchor) |at| sizeMenu(c, a, k, inst, repo, sizes, at);
}

/// The size dropdown under its trigger, right-aligned to it
/// (`anchored_menu_below_end`): "Default size", then each size.
fn sizeMenu(c: *ui.Context, a: *App, k: theme.Colors, inst: *const runners.Installation, repo: *const runners.Repo, sizes: []const runners.Size, at: ui.Rect) void {
    {
        // A press anywhere else closes it (`on_mouse_down_out`); its
        // trigger toggles it itself.
        if (kit.pressedOutside(c, at)) return closeSizeMenu(a);
    }
    const w: f32 = 260;
    // Its right edge at the trigger's padding box's, inside its border.
    const x = rules.snapToWindow(at.x + at.w - 1 - w, w, c.size.w, 8);
    // Hung from the trigger's padding box, inside its border: 6 under
    // that, 4.5 under the border's outer edge as drawn.
    const y = at.y + at.h + 4.5;
    const m = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(4 + 1).gap(2)
        .bg(k.composer).border(k.border).borderW(1).rounded(12)));
    defer m.end();
    {
        // `menu_heading`: small capitals, spaced.
        const hd = ui.div(c).row().wFull().px(8).pt(6).pb(4);
        defer hd.end();
        ui.text(c, tracked(c, "Default size"), set.st(c, 10, .{ .weight = .medium, .color = k.muted }));
    }
    for (sizes) |*size| {
        ui.key(c, c.print("github-ci-size-{s}", .{size.key}));
        const active = if (repo.default_size) |d| std.mem.eql(u8, d, size.key) else false;
        var row = ui.div(c).row().wFull().px(8).py(6).gap(10).itemsCenter().rounded(7);
        row = if (active) row.bg(k.selected) else row.hover(k.selected);
        defer row.end();
        const hot = row.hovered();
        kit.ellipsisText(c, runners.sizeOptionLabel(c.alloc(), size) catch "", set.st(c, 13, .{ .color = if (active or hot) k.text else k.text.alpha(0.9) }), w - 2 * 5 - 16);
        if (row.clicked()) {
            closeSizeMenu(a);
            setRepoSize(a, inst.installation_id, repo.full_name, size.key);
        }
    }
}

/// Upper case with a hair space between letters (`tracked_upper`).
fn tracked(c: *ui.Context, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |ch, i| {
        if (i > 0) out.appendSlice(c.alloc(), "\u{200A}") catch {};
        out.append(c.alloc(), std.ascii.toUpper(ch)) catch {};
    }
    return out.items;
}

fn jobs(c: *ui.Context, a: *App, k: theme.Colors, rs: *const runners.Runners) void {
    const now = a.nowMs();
    set.space(c, 24);
    ui.text(c, "Recent jobs", set.st(c, 12, .{ .weight = .medium, .color = k.muted }));
    const cd = card(c, k, 8);
    defer cd.end();
    if (rs.recent_jobs.len == 0) {
        const r = set.row(c, k, true, false);
        defer r.end();
        quiet(c, k, "No jobs yet. Push a workflow with runs-on: codegraff to start one.", rowInner());
        return;
    }
    for (rs.recent_jobs[0..@min(rs.recent_jobs.len, jobs_shown)], 0..) |*j, ix| {
        ui.key(c, c.print("github-ci-job-{d}", .{ix}));
        const status = runners.jobStatus(c.alloc(), j) catch runners.Status{ .label = "", .tone = .quiet };
        const color = switch (status.tone) {
            .good => k.success,
            .bad => k.danger,
            .working => k.accent,
            .quiet => k.muted.alpha(0.5),
        };
        const meta = runners.jobMeta(c.alloc(), j, now) catch "";
        const link = runners.jobUrl(j);
        const open: Ghost = .{ .label = "Open on GitHub" };
        const r = set.row(c, k, ix == 0, false);
        defer r.end();
        kit.dot(c, 7, color);
        const w = rowInner() - 7 - 14 - (if (link != null) 14 + ghostW(c, open) else 0);
        {
            const col = ui.div(c).column().w(w);
            defer col.end();
            title(c, k, c.print("{s} · {s}", .{ j.repo, runners.jobTitle(c.alloc(), j) catch "" }), w);
            quiet(c, k, if (meta.len == 0) status.label else c.print("{s} · {s}", .{ status.label, meta }), w);
        }
        if (link) |url| if (ghost(c, k, open)) {
            _ = nanoui.shell.openUrl(url);
        };
    }
}
