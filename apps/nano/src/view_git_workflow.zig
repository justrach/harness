//! Native staged/unstaged controls, with a separate explicit confirmation
//! before committing the index or publishing to an existing upstream.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const flow = @import("app_git_workflow.zig");

pub fn view(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.panels.git_workflow;
    {
        const bar = ui.div(c).row().wFull().h(40).px(12).gap(8).itemsCenter();
        defer bar.end();
        ui.text(c, "Git changes", .{ .size = 13, .weight = .medium, .color = k.text });
        ui.spacer(c);
        if (button(c, k, "History", s.pending == null)) {
            s.open = false;
            @import("app_git.zig").load(a, 0);
        }
        if (button(c, k, "Refresh", s.pending == null)) flow.load(a);
    }
    rule(c, k);
    if (s.error_text) |text| note(c, k, text, true);
    if (s.notice) |text| note(c, k, text, false);
    const snap = s.snapshot orelse return note(c, k, if (s.pending != null) "Loading Git changes…" else "Open a project session, then refresh its Git changes.", false);
    const page = snap.page;
    {
        const heading = ui.div(c).column().wFull().px(14).py(10).gap(5);
        defer heading.end();
        ui.text(c, page.branch orelse "Detached HEAD", .{ .size = 12, .mono = true, .color = k.text, .wrap = true });
        if (page.blockedReason) |why| note(c, k, why, true);
        if (page.upstream) |upstream| {
            ui.text(c, c.print("Upstream: {s}/{s}", .{ upstream.remote, upstream.branch }), .{ .size = 11, .color = k.muted, .wrap = true });
        } else ui.text(c, "No push destination. Set an upstream in your terminal first.", .{ .size = 11, .color = k.muted, .wrap = true });
        ui.text(c, "Only selected files are staged. Commit uses the index, not all working changes.", .{ .size = 11, .color = k.muted, .wrap = true });
    }
    const enabled = flow.canAct(a) and s.confirm == null;
    {
        const list = ui.div(c).column().wFull().grow().h(0).px(14).gap(6).scrollY();
        defer list.end();
        section(c, a, k, page, true, enabled);
        section(c, a, k, page, false, enabled);
    }
    rule(c, k);
    {
        const footer = ui.div(c).column().wFull().p(14).gap(9);
        defer footer.end();
        if (s.pending != null) {
            ui.text(c, if (s.action_kind != null) "Applying Git action…" else "Refreshing…", .{ .size = 12, .color = k.muted });
            ui.text(c, "Do not retry while the host is working.", .{ .size = 11, .color = k.muted });
        } else if (s.confirm) |kind| {
            if (kind == .commit) {
                ui.text(c, c.print("Commit {d} staged file{s}?", .{ page.stagedCount(), if (page.stagedCount() == 1) "" else "s" }), .{ .size = 13, .weight = .medium, .color = k.text });
                ui.text(c, s.message.text(), .{ .size = 12, .color = k.text, .wrap = true });
                ui.text(c, "Git hooks and your configured author identity apply. Unstaged edits stay untouched.", .{ .size = 11, .color = k.muted, .wrap = true });
            } else {
                const upstream = page.upstream orelse return;
                ui.text(c, c.print("Push {s} to {s}/{s}?", .{ page.branch orelse "", upstream.remote, upstream.branch }), .{ .size = 13, .weight = .medium, .color = k.text, .wrap = true });
                const sha = page.headSha orelse "";
                ui.text(c, c.print("Publish committed history through {s}. No force push; working files are not uploaded.", .{sha[0..@min(12, sha.len)]}), .{ .size = 11, .color = k.muted, .wrap = true });
            }
            const row = ui.div(c).row().wFull().gap(8);
            defer row.end();
            if (button(c, k, if (kind == .commit) "Confirm commit" else "Confirm push", if (kind == .commit) flow.canCommit(a) else flow.canPush(a))) flow.confirm(a);
            if (button(c, k, "Cancel", true)) flow.cancel(a);
        } else {
            ui.text(c, "Commit message", .{ .size = 12, .weight = .medium, .color = k.text });
            const box = ui.div(c).row().wFull().px(10).py(8).border(k.border).borderW(1).rounded(8);
            {
                defer box.end();
                ui.key(c, "git-commit-message");
                _ = ui.textField(c, &s.message, .{ .placeholder = "Describe the staged changes", .placeholder_color = k.faint, .bare = true, .width = .fill, .size = 12 });
            }
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            if (button(c, k, "Commit staged…", flow.canCommit(a))) flow.arm(a, .commit);
            ui.spacer(c);
            if (button(c, k, "Push…", flow.canPush(a))) flow.arm(a, .push);
        }
    }
}
fn section(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, staged: bool, enabled: bool) void {
    ui.key(c, if (staged) "staged-files" else "unstaged-files");
    var count: usize = 0;
    for (page.files) |file| if (if (staged) file.staged() else file.unstaged()) {
        count += 1;
    };
    const section_box = ui.div(c).column().wFull().gap(5).py(8);
    defer section_box.end();
    ui.text(c, c.print("{s} ({d})", .{ if (staged) "Staged" else "Unstaged", count }), .{ .size = 12, .weight = .semibold, .color = k.text });
    if (count == 0) ui.text(c, if (staged) "Nothing staged." else "No unstaged changes.", .{ .size = 11, .color = k.muted });
    for (page.files) |file| {
        if (!(if (staged) file.staged() else file.unstaged())) continue;
        ui.key(c, file.path);
        const row = ui.div(c).row().wFull().h(38).gap(8).py(5).itemsCenter();
        defer row.end();
        ui.text(c, if (staged) file.indexStatus else file.worktreeStatus, .{ .size = 11, .mono = true, .color = k.accent });
        const name = ui.div(c).column().grow().w(0).h(20).clip();
        {
            defer name.end();
            kit.ellipsisText(c, file.path, .{ .size = 11.5, .mono = true, .color = k.text }, @max(80, a.view.chrome.host_width - 150));
        }
        if (button(c, k, if (staged) "Unstage" else "Stage", enabled)) flow.fileAction(a, file.path, !staged);
    }
}
fn button(c: *ui.Context, k: theme.Colors, label: []const u8, enabled: bool) bool {
    const b = ui.div(c).row().h(28).px(8).itemsCenter().rounded(6).bg(if (enabled) k.hover else .transparent);
    defer b.end();
    if (enabled) _ = b.hover(k.selected).control();
    if (enabled) _ = kit.focusRing(c, b, k.accent, 2);
    ui.text(c, label, .{ .size = 11.5, .color = if (enabled) k.text else k.faint });
    return enabled and b.clicked();
}
fn rule(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}
fn note(c: *ui.Context, k: theme.Colors, text: []const u8, warning: bool) void {
    const box = ui.div(c).column().wFull().p(12).bg(if (warning) k.warning.alpha(0.07) else .transparent);
    defer box.end();
    ui.text(c, text, .{ .size = 11.5, .color = if (warning) k.warning else k.muted, .wrap = true });
}
