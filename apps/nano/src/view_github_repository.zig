//! Repository-wide read-only GitHub browsing with native Markdown prose.
//! No webview, image loading or provider-supplied executable links.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const flow = @import("app_github_repository.zig");
const icons = @import("icons.zig");
const behavior = @import("control_behavior.zig");
const groups = @import("control_group.zig");

pub fn view(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.panels.github_repository;
    const ready = s.pending == null;
    // Own a bounded column: headers may be arbitrarily tall, but must never
    // push pagination below the viewport. Only the middle region scrolls.
    ui.key(c, "github-repository-content");
    const surface = ui.div(c).column().wFull().grow().h(0);
    defer surface.end();
    const parent = c.node(c.node(surface.index).parent);
    const bounds = c.rects.get(surface.id()) orelse c.rects.get(parent.id);
    const width = if (bounds) |r| r.w else c.size.w;
    const compact = width < 420;
    {
        var bar = ui.div(c).wFull().px(12).py(6).gap(6);
        bar = if (compact) bar.column() else bar.row().itemsCenter();
        defer bar.end();
        const title = if (s.repository()) |r| c.print("{s}/{s}", .{ r.owner, r.name }) else "Repository GitHub";
        var name = ui.div(c).column().h(20).clip();
        name = if (compact) name.wFull() else name.grow().w(0);
        {
            defer name.end();
            const room = if (c.rects.get(name.id())) |r| r.w else @max(0, width - 200);
            if (c.rects.get(name.id()) == null) c.animationFrame();
            kit.ellipsisText(c, title, .{ .size = 12, .weight = .medium, .color = k.text }, room);
        }
        var actions = ui.div(c).row().gap(6).itemsCenter();
        if (compact) actions = actions.wFull().justifyEnd();
        defer actions.end();
        if (button(c, k, "Sessions", true, false)) flow.hide(a);
        if (button(c, k, "Refresh", ready, false)) flow.refresh(a);
    }
    rule(c, k);
    var page = s.current();
    {
        const viewport = ui.div(c).column().wFull().grow().h(0).scrollY();
        defer viewport.end();
        if (s.error_text) |text| note(c, k, text, true);
        const in_list = s.kind == .pulls or s.kind == .issues;
        if (in_list) {
            {
                const tabs = ui.div(c).row().wFull().px(12).py(8).gap(6).itemsCenter();
                defer tabs.end();
                if (groups.choices(c, k, "GitHub item type", &.{ "Pull requests", "Issues" }, if (s.list_kind == .pulls) 0 else 1, ready, .tab)) |chosen|
                    flow.list(a, if (chosen == 0) .pulls else .issues, s.filter);
            }
            {
                var filters = ui.div(c).wFull().px(12).pb(8).gap(6);
                filters = if (compact) filters.column() else filters.row().itemsCenter();
                defer filters.end();
                {
                    const choices = ui.div(c).row().gap(6).itemsCenter();
                    defer choices.end();
                    const states = [_]flow.Filter{ .open, .closed, .all };
                    const selected: usize = switch (s.filter) {
                        .open => 0,
                        .closed => 1,
                        .all => 2,
                    };
                    if (groups.choices(c, k, "GitHub state filter", &.{ "Open", "Closed", "All" }, selected, ready, .radio_button)) |chosen|
                        flow.list(a, s.list_kind, states[chosen]);
                }
                if (!compact) ui.spacer(c);
                ui.text(c, "Repository-wide", .{ .size = 10.5, .color = k.muted });
            }
            rule(c, k);
        } else detailHeader(c, a, k, ready);
        page = s.current();
        const current = page orelse return note(c, k, if (!ready) "Loading from the repository's host…" else "No GitHub page is loaded. Refresh to retry.", false);
        if (current.truncated) note(c, k, "Some content was clipped by the host's size limits. Open on GitHub for the full content.", true);
        const content = ui.div(c).column().wFull().p(14).gap(10);
        defer content.end();
        switch (s.kind) {
            .pulls, .issues => list(c, a, k, current, ready and s.error_text == null),
            .pull, .issue => summary(c, a, k, current),
            .files => files(c, a, k, current),
            .activity => activity(c, a, k, current),
        }
    }
    if (page != null and s.kind != .pull and s.kind != .issue) {
        const current = page.?;
        rule(c, k);
        const footer = ui.div(c).row().wFull().h(42).px(12).gap(8).itemsCenter();
        defer footer.end();
        if (button(c, k, "Previous", ready and current.page > 1 and s.error_text == null, false)) flow.turnPage(a, false);
        {
            const status = ui.div(c).column().grow().w(0);
            defer status.end();
            ui.text(c, if (!ready) "Loading…" else c.print("Page {d}", .{current.page}), .{ .size = 11, .color = k.muted });
        }
        if (button(c, k, "Next", ready and current.hasNextPage and s.error_text == null, false)) flow.turnPage(a, true);
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
        stateBadge(c, k, detail.number, detail.state, detail.isDraft);
        ui.text(c, detail.title, .{ .size = 16, .weight = .semibold, .wrap = true, .color = k.text });
        ui.text(c, c.print("{s} · opened {s}", .{ detail.author, date(detail.createdAt) }), .{ .size = 11, .color = k.muted, .wrap = true });
        if (detail.headRef) |head| ui.text(c, c.print("{s} → {s}", .{ head, detail.baseRef orelse "" }), .{ .size = 11, .mono = true, .color = k.muted, .wrap = true });
        if (detail.changedFiles) |count| ui.text(c, c.print("{d} files · +{d} / −{d}", .{ count, detail.additions orelse 0, detail.deletions orelse 0 }), .{ .size = 11, .color = k.muted, .wrap = true });
    };
    {
        const tabs = ui.div(c).row().wFull().px(12).pb(8).gap(6).itemsCenter();
        defer tabs.end();
        const enabled = ready and s.details != null and s.error_text == null;
        const pull = s.selected_kind == .pull;
        const labels: []const []const u8 = if (pull) &.{ "Summary", "Code", "Activity" } else &.{ "Summary", "Activity" };
        const sections: []const flow.Kind = if (pull) &.{ s.selected_kind, .files, .activity } else &.{ s.selected_kind, .activity };
        const selected: usize = if (s.kind == .files) 1 else if (s.kind == .activity) labels.len - 1 else 0;
        if (groups.choices(c, k, "GitHub detail section", labels, selected, enabled, .tab)) |chosen| flow.section(a, sections[chosen]);
    }
    rule(c, k);
}
fn list(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page, enabled: bool) void {
    if (page.items.len == 0) {
        const empty = ui.div(c).column().wFull().p(20).gap(8).itemsCenter();
        defer empty.end();
        icons.icon(c, if (a.panels.github_repository.list_kind == .pulls) .@"pull-request" else .@"chat-round-line", 24, k.muted, 0);
        ui.text(c, "No matching items", .{ .size = 14, .weight = .semibold, .color = k.text });
        ui.text(c, if (page.hasNextPage) "No matches on this page. Try the next page or another filter." else "Try another state filter, or Refresh to check again.", .{ .size = 12, .color = k.muted, .wrap = true });
    }
    for (page.items) |item| {
        ui.key(c, c.print("github-{d}", .{item.number}));
        const card = ui.div(c).column().wFull().p(12).gap(7).border(k.border).borderW(1).rounded(8);
        defer card.end();
        if (enabled) _ = card.hover(k.hover).control();
        const activated = behavior.activate(c, card, k, item.title, enabled, false);
        stateBadge(c, k, item.number, item.state, item.isDraft);
        ui.text(c, item.title, .{ .size = 13, .weight = .semibold, .color = k.text, .wrap = true });
        ui.text(c, c.print("{s} · updated {s}", .{ item.author, date(item.updatedAt) }), .{ .size = 10.5, .color = k.muted, .wrap = true });
        if (activated) flow.openItem(a, item.number);
    }
}
fn summary(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const detail = page.detail orelse return;
    // Zeron's description hierarchy, rendered with our bounded native prose
    // renderer rather than a webview or provider-controlled HTML surface.
    const card = ui.div(c).column().wFull().p(16).gap(14).border(k.border).borderW(1).rounded(10);
    defer card.end();
    ui.text(c, "Description", .{ .size = 12, .weight = .semibold, .color = k.muted });
    if (std.mem.trim(u8, detail.body, " \t\r\n").len == 0) {
        ui.text(c, "No description provided.", .{ .size = 12, .color = k.muted, .wrap = true });
    } else @import("view_markdown.zig").githubMarkdown(c, k, detail.body, a);
}
fn files(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
    const s = &a.panels.github_repository;
    ui.text(c, "Expand a file to review its changes.", .{ .size = 11, .color = k.muted, .wrap = true });
    if (page.files.len == 0) ui.text(c, "No files on this page.", .{ .size = 12, .color = k.muted });
    for (page.files, 0..) |file, i| {
        ui.key(c, file.filename);
        const expanded = s.expanded_file == i;
        const card = ui.div(c).column().wFull().border(if (expanded) k.accent.alpha(0.3) else k.border).borderW(1).rounded(9).clip();
        defer card.end();
        {
            const row = ui.div(c).column().wFull().p(10).gap(6).bg(k.ink(0.015)).hover(k.hover).control();
            defer row.end();
            const activated = behavior.activate(c, row, k, file.filename, true, expanded);
            {
                const heading = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer heading.end();
                icons.icon(c, if (expanded) .@"alt-arrow-down" else .@"alt-arrow-right", 12, k.muted, 0);
                @import("file_icons.zig").icon(c, file.filename, false, k.dark, 15);
                const name = ui.div(c).column().grow().w(0);
                defer name.end();
                const room = if (c.rects.get(name.id())) |r| r.w else 0;
                if (c.rects.get(name.id()) == null) c.animationFrame();
                kit.ellipsisText(c, file.filename, .{ .size = 11.5, .mono = true, .weight = .medium, .color = k.text }, room);
            }
            {
                const stats = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer stats.end();
                ui.text(c, file.status, .{ .size = 10.5, .color = k.muted, .wrap = true });
                ui.text(c, c.print("+{d}", .{file.additions}), .{ .size = 11, .mono = true, .color = k.diff_add, .wrap = true });
                ui.text(c, c.print("−{d}", .{file.deletions}), .{ .size = 11, .mono = true, .color = k.diff_del, .wrap = true });
            }
            if (activated) s.expanded_file = if (expanded) null else i;
        }
        if (expanded) {
            rule(c, k);
            if (file.previousFilename != null or file.patchTruncated) {
                const notices = ui.div(c).column().wFull().px(12).py(8).gap(5).bg(k.ink(0.015));
                defer notices.end();
                if (file.previousFilename) |old| ui.text(c, c.print("Previously: {s}", .{old}), .{ .size = 11, .wrap = true, .color = k.muted });
                if (file.patchTruncated) ui.text(c, "Patch incomplete; open on GitHub for the full diff.", .{ .size = 11, .wrap = true, .color = k.warning });
            }
            const parsed = if (s.content) |snapshot| (if (i < snapshot.patches.len) snapshot.patches[i] else null) else null;
            if (parsed) |patch| {
                // Until this local card has a measured rect, use a conservative
                // width; never borrow a neighboring pane's global host width.
                const available = if (c.rects.get(card.id())) |r| r.w - 2 else 1;
                @import("view_github_diff.zig").draw(c, k, &patch, @max(1, available));
            } else {
                const fallback = ui.div(c).column().wFull().p(12).bg(k.ink(0.015));
                defer fallback.end();
                ui.text(c, file.patch orelse "Patch not supplied by GitHub (binary, large or omitted).", .{ .size = 11, .mono = file.patch != null, .wrap = true, .color = k.muted });
            }
        }
    }
}
fn activity(c: *ui.Context, a: *App, k: theme.Colors, page: flow.Page) void {
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
        if (event.body) |text| @import("view_markdown.zig").githubMarkdown(c, k, text, a);
    }
}
fn stateBadge(c: *ui.Context, k: theme.Colors, number: u64, state: []const u8, draft: bool) void {
    const tone = if (draft) k.muted else if (std.mem.eql(u8, state, "open")) k.success else if (std.mem.eql(u8, state, "closed")) k.danger else k.accent;
    const badge = ui.div(c).row().px(8).py(3).gap(5).itemsCenter().rounded(10).bg(tone.alpha(0.10));
    defer badge.end();
    icons.icon(c, .@"pull-request", 12, tone, 0);
    ui.text(c, c.print("#{d} · {s}{s}", .{ number, state, if (draft) " · draft" else "" }), .{ .size = 10.5, .weight = .medium, .color = tone, .wrap = true });
}
fn date(text: []const u8) []const u8 {
    return text[0..@min(10, text.len)];
}
fn button(c: *ui.Context, k: theme.Colors, label: []const u8, enabled: bool, selected: bool) bool {
    ui.key(c, label);
    const b = ui.div(c).row().h(27).px(8).itemsCenter().rounded(6).bg(if (selected) k.selected else .transparent);
    defer b.end();
    if (enabled) _ = b.hover(k.hover).control();
    const activated = behavior.activate(c, b, k, label, enabled, selected);
    ui.text(c, label, .{ .size = 11.5, .color = if (enabled) k.text else k.faint });
    return activated;
}
fn rule(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}
fn note(c: *ui.Context, k: theme.Colors, text: []const u8, warning: bool) void {
    const box = ui.div(c).column().wFull().p(12).bg(if (warning) k.warning.alpha(0.06) else .transparent);
    defer box.end();
    ui.text(c, text, .{ .size = 11.5, .color = if (warning) k.warning else k.muted, .wrap = true });
}
