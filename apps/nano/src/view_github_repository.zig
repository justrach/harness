//! Repository-wide read-only GitHub browsing. Remote text stays plain native
//! text; no HTML, remote images or provider-supplied URLs are executed.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const flow = @import("app_github_repository.zig");

pub fn view(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.panels.github_repository;
    const ready = s.pending == null;
    {
        const bar = ui.div(c).row().wFull().h(40).px(12).gap(6).itemsCenter();
        defer bar.end();
        const title = if (s.repository()) |r| c.print("{s}/{s}", .{ r.owner, r.name }) else "Repository GitHub";
        const name = ui.div(c).column().grow().w(0).h(20).clip();
        {
            defer name.end();
            kit.ellipsisText(c, title, .{ .size = 12, .weight = .medium, .color = k.text }, @max(80, a.view.chrome.host_width - 180));
        }
        if (button(c, k, "Sessions", true, false)) flow.hide(a);
        if (button(c, k, "Refresh", ready, false)) flow.refresh(a);
    }
    rule(c, k);
    if (s.error_text) |text| note(c, k, text, true);
    const in_list = s.kind == .pulls or s.kind == .issues;
    if (in_list) {
        {
            const tabs = ui.div(c).row().wFull().px(12).py(8).gap(6).itemsCenter();
            defer tabs.end();
            if (button(c, k, "Pull requests", ready, s.list_kind == .pulls)) flow.list(a, .pulls, s.filter);
            if (button(c, k, "Issues", ready, s.list_kind == .issues)) flow.list(a, .issues, s.filter);
        }
        {
            const filters = ui.div(c).row().wFull().px(12).pb(8).gap(6).itemsCenter();
            defer filters.end();
            inline for (.{ .{ "Open", flow.Filter.open }, .{ "Closed", flow.Filter.closed }, .{ "All", flow.Filter.all } }) |filter| {
                if (button(c, k, filter[0], ready, s.filter == filter[1])) flow.list(a, s.list_kind, filter[1]);
            }
            ui.spacer(c);
            ui.text(c, "Repository-wide", .{ .size = 10.5, .color = k.muted });
        }
        rule(c, k);
    } else detailHeader(c, a, k, ready);
    const page = s.current() orelse return note(c, k, if (!ready) "Loading from the repository's host…" else "No GitHub page is loaded. Refresh to retry.", false);
    if (page.truncated) note(c, k, "Some content was clipped by the host's size limits. Open on GitHub for the full content.", true);
    {
        const content = ui.div(c).column().wFull().grow().h(0).p(14).gap(10).scrollY();
        defer content.end();
        switch (s.kind) {
            .pulls, .issues => list(c, a, k, page, ready and s.error_text == null),
            .pull, .issue => summary(c, k, page),
            .files => files(c, a, k, page),
            .activity => activity(c, k, page),
        }
    }
    if (s.kind != .pull and s.kind != .issue) {
        rule(c, k);
        const footer = ui.div(c).row().wFull().h(42).px(12).gap(8).itemsCenter();
        defer footer.end();
        if (button(c, k, "Previous", ready and page.page > 1 and s.error_text == null, false)) flow.turnPage(a, false);
        ui.text(c, if (!ready) "Loading…" else c.print("Page {d}", .{page.page}), .{ .size = 11, .color = k.muted });
        ui.spacer(c);
        if (button(c, k, "Next", ready and page.hasNextPage and s.error_text == null, false)) flow.turnPage(a, true);
    }
}
fn detailHeader(c: *ui.Context, a: *App, k: theme.Colors, ready: bool) void {
    const s = &a.panels.github_repository;
    {
        const bar = ui.div(c).row().wFull().px(12).py(8).gap(6).itemsCenter();
        defer bar.end();
        if (button(c, k, if (s.list_kind == .pulls) "Back to PRs" else "Back to issues", ready, false)) flow.back(a);
        ui.spacer(c);
        if (button(c, k, "Open on GitHub", s.repository() != null and s.number != null, false)) {
            const url = flow.itemUrl(c.alloc(), s.repository().?, s.number.?, s.selected_kind == .pull) catch return;
            _ = nanoui.shell.openUrl(url);
        }
    }
    if (s.details) |d| if (d.page.detail) |detail| {
        const box = ui.div(c).column().wFull().px(14).pb(10).gap(5);
        defer box.end();
        ui.text(c, c.print("#{d} · {s}{s}", .{ detail.number, detail.state, if (detail.isDraft) " · draft" else "" }), .{ .size = 11, .color = k.accent });
        ui.text(c, detail.title, .{ .size = 14, .weight = .semibold, .wrap = true, .color = k.text });
    };
    {
        const tabs = ui.div(c).row().wFull().px(12).pb(8).gap(6).itemsCenter();
        defer tabs.end();
        const enabled = ready and s.details != null and s.error_text == null;
        if (button(c, k, "Summary", enabled, s.kind == .pull or s.kind == .issue)) flow.section(a, s.selected_kind);
        if (s.selected_kind == .pull) if (button(c, k, "Code", enabled, s.kind == .files)) flow.section(a, .files);
        if (button(c, k, "Activity", enabled, s.kind == .activity)) flow.section(a, .activity);
    }
    rule(c, k);
}
fn list(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, enabled: bool) void {
    if (page.items.len == 0) {
        ui.text(c, if (page.hasNextPage) "No matching items on this page. More pages are available." else "No matching items on this page.", .{ .size = 12, .color = k.muted, .wrap = true });
    }
    for (page.items) |item| {
        ui.key(c, c.print("github-{d}", .{item.number}));
        const card = ui.div(c).column().wFull().h(98).p(10).gap(6).border(k.border).borderW(1).rounded(8).clip();
        defer card.end();
        if (enabled) _ = card.hover(k.hover).control();
        if (enabled) _ = kit.focusRing(c, card, k.accent, 2);
        ui.text(c, c.print("#{d} · {s}{s}", .{ item.number, item.state, if (item.isDraft) " · draft" else "" }), .{ .size = 10.5, .color = k.accent });
        ui.text(c, item.title, .{ .size = 12, .weight = .medium, .color = k.text, .wrap = true });
        ui.text(c, c.print("{s} · updated {s}", .{ item.author, date(item.updatedAt) }), .{ .size = 10.5, .color = k.muted });
        if (enabled and card.clicked()) flow.openItem(a, item.number);
    }
}
fn summary(c: *ui.Context, k: theme.Colors, page: flow.Page) void {
    const detail = page.detail orelse return;
    ui.text(c, c.print("{s} · opened {s}", .{ detail.author, date(detail.createdAt) }), .{ .size = 11, .color = k.muted, .wrap = true });
    if (detail.headRef) |head| ui.text(c, c.print("{s} → {s}", .{ head, detail.baseRef orelse "" }), .{ .size = 11, .mono = true, .color = k.muted, .wrap = true });
    if (detail.changedFiles) |count| ui.text(c, c.print("{d} files · +{d} / −{d}", .{ count, detail.additions orelse 0, detail.deletions orelse 0 }), .{ .size = 11, .color = k.muted });
    rule(c, k);
    ui.text(c, if (detail.body.len == 0) "No description provided." else detail.body, .{ .size = 12, .color = k.text, .wrap = true });
}
fn files(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const s = &a.panels.github_repository;
    ui.text(c, "GitHub may omit binary or large patches. Only one patch is expanded at a time.", .{ .size = 11, .color = k.muted, .wrap = true });
    if (page.files.len == 0) ui.text(c, "No files on this page.", .{ .size = 12, .color = k.muted });
    for (page.files, 0..) |file, i| {
        ui.key(c, file.filename);
        const card = ui.div(c).column().wFull().border(k.border).borderW(1).rounded(8).clip();
        defer card.end();
        {
            const row = ui.div(c).column().wFull().p(10).gap(5).hover(k.hover).control();
            defer row.end();
            ui.text(c, file.filename, .{ .size = 12, .mono = true, .wrap = true, .color = k.text });
            ui.text(c, c.print("{s} · +{d} / −{d} · {s}", .{ file.status, file.additions, file.deletions, if (s.expanded_file == i) "Collapse patch" else "Expand patch" }), .{ .size = 11, .color = k.muted });
            if (row.clicked()) s.expanded_file = if (s.expanded_file == i) null else i;
        }
        if (s.expanded_file == i) {
            const patch = ui.div(c).column().wFull().p(10).bg(k.ink(0.03));
            defer patch.end();
            if (file.previousFilename) |old| ui.text(c, c.print("Previously: {s}", .{old}), .{ .size = 11, .wrap = true, .color = k.muted });
            if (file.patchTruncated) ui.text(c, "Patch incomplete; open on GitHub for the full diff.", .{ .size = 11, .wrap = true, .color = k.warning });
            ui.text(c, file.patch orelse "Patch not supplied by GitHub (binary, large or omitted).", .{ .size = 11, .mono = true, .wrap = true, .color = k.text });
        }
    }
}
fn activity(c: *ui.Context, k: theme.Colors, page: flow.Page) void {
    if (page.events.len == 0) ui.text(c, "No activity on this page.", .{ .size = 12, .color = k.muted });
    for (page.events, 0..) |event, i| {
        ui.key(c, c.print("{s}-{d}", .{ event.id, i }));
        // Activity bodies have variable length. Intrinsic card height keeps
        // them readable instead of clipping them to a guessed timeline height.
        const row = ui.div(c).column().wFull().p(12).gap(6).border(k.border).borderW(1).rounded(8);
        defer row.end();
        ui.text(c, c.print("{s} · {s}", .{ event.author, event.event }), .{ .size = 12, .weight = .medium, .wrap = true, .color = k.text });
        ui.text(c, date(event.createdAt), .{ .size = 10.5, .color = k.muted });
        if (event.commitSha) |sha| ui.text(c, sha[0..@min(12, sha.len)], .{ .size = 11, .mono = true, .color = k.muted });
        if (event.body) |text| ui.text(c, text, .{ .size = 12, .color = k.text, .wrap = true });
    }
}
fn date(text: []const u8) []const u8 {
    return text[0..@min(10, text.len)];
}
fn button(c: *ui.Context, k: theme.Colors, label: []const u8, enabled: bool, selected: bool) bool {
    ui.key(c, label);
    const b = ui.div(c).row().h(27).px(8).itemsCenter().rounded(6).bg(if (selected) k.selected else .transparent);
    defer b.end();
    if (enabled) _ = b.hover(k.hover).control();
    if (enabled) _ = kit.focusRing(c, b, k.accent, 2);
    ui.text(c, label, .{ .size = 11.5, .color = if (enabled) k.text else k.faint });
    return enabled and b.clicked();
}
fn rule(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}
fn note(c: *ui.Context, k: theme.Colors, text: []const u8, warning: bool) void {
    const box = ui.div(c).column().wFull().p(12).bg(if (warning) k.warning.alpha(0.06) else .transparent);
    defer box.end();
    ui.text(c, text, .{ .size = 11.5, .color = if (warning) k.warning else k.muted, .wrap = true });
}
