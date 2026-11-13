//! Native Git/GitHub surfaces over existing host-owned engine services.
//! No plugin interpreter, local subprocesses, or automatic remote writes.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const git = @import("app_git.zig");
const panels = @import("app_panels.zig");
const prs = @import("app_change_requests.zig");
const cr = @import("change_requests.zig");

pub fn history(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.panels.history;
    {
        const bar = ui.div(c).row().wFull().h(40).px(12).gap(8).itemsCenter();
        defer bar.end();
        icons.icon(c, .@"git-branch", 14, k.muted, 0);
        const chat = if (a.selected) |id| a.findChat(id) else null;
        kit.ellipsisText(c, if (chat) |ch| ch.branch orelse "Checkout history" else "Git history", .{ .size = 12, .mono = true, .color = k.text }, 200);
        ui.spacer(c);
        if (button(c, k, "Changes", true)) panels.addDiffsTab(a);
        if (button(c, k, "Refresh", s.pending == null)) git.load(a, 0);
    }
    rule(c, k);
    if (a.selected == null) return empty(c, k, "Open a project session to inspect its checkout.");
    if (s.error_text) |e| {
        const msg = ui.div(c).column().wFull().p(12).bg(k.warning.alpha(0.06));
        ui.text(c, e, .{ .size = 12, .wrap = true, .color = k.muted });
        msg.end();
    }
    const snapshot = s.snapshot orelse return empty(c, k, if (s.pending != null) "Loading Git history…" else "Git history is not loaded.");
    const page = snapshot.page;
    if (page.comparison) |comparison| {
        const note = ui.div(c).row().wFull().px(14).py(8);
        defer note.end();
        ui.text(c, c.print("{d} ahead · {d} behind {s} (local refs)", .{ comparison.ahead, comparison.behind, comparison.base }), .{ .size = 11, .color = k.muted });
    }
    if (page.commits.len == 0) return empty(c, k, "No commits yet.");
    {
        const list = ui.div(c).column().wFull().grow().h(0).px(12).scrollY();
        defer list.end();
        for (page.commits, 0..) |commit, i| {
            ui.key(c, commit.sha);
            const is_head = if (page.headSha) |head| std.mem.eql(u8, head, commit.sha) else false;
            // A chronological rail, not a branch graph. Endpoint flags
            // describe the full list, not just this visible page.
            const row = nanoui.kit.timelineItem(c, .{
                .height = 68,
                .first = i == 0 and s.cursor == 0,
                .last = i + 1 == page.commits.len and page.nextCursor == null,
                .color = if (is_head) k.accent else k.muted,
            });
            defer row.end();
            const body = ui.div(c).column().grow().w(0).gap(4).clip();
            defer body.end();
            kit.ellipsisText(c, commit.subject, .{ .size = 12.5, .weight = .medium, .color = k.text }, @max(80, a.view.chrome.host_width - 74));
            const meta = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
            defer meta.end();
            ui.text(c, commit.sha[0..@min(7, commit.sha.len)], .{ .size = 10.5, .mono = true, .color = k.muted });
            kit.ellipsisText(c, c.print("{s} · {s}", .{ commit.authorName, commit.authoredAt[0..@min(10, commit.authoredAt.len)] }), .{ .size = 10.5, .color = k.muted }, 180);
            if (is_head) tag(c, k, "HEAD", k.accent);
            if (commit.parentShas.len > 1) tag(c, k, "Merge", k.muted);
            for (commit.refs, 0..) |ref, j| {
                if (j >= 2) break;
                tag(c, k, ref.label, k.muted);
            }
        }
    }
    rule(c, k);
    const footer = ui.div(c).row().wFull().h(42).px(12).gap(8).itemsCenter();
    defer footer.end();
    if (button(c, k, "Previous", s.cursor > 0 and s.pending == null)) git.load(a, git.previousCursor(s.cursor));
    ui.text(c, if (s.pending != null) "Loading…" else c.print("{d}–{d}", .{ s.cursor + 1, s.cursor + page.commits.len }), .{ .size = 11, .color = k.muted });
    ui.spacer(c);
    if (button(c, k, "Next", page.nextCursor != null and s.pending == null)) git.load(a, page.nextCursor.?);
}

pub const PullRequest = struct { chat_id: []const u8, summary: cr.Summary, provenance: cr.Provenance };

/// Only sessions in the selected repository on the same host. A shared
/// branch contributes one PR, with the selected session preferred.
pub fn sessionPullRequests(a: *const App, allocator: std.mem.Allocator) ![]PullRequest {
    var result: std.ArrayList(PullRequest) = .empty;
    errdefer result.deinit(allocator);
    const id = a.selected orelse return result.toOwnedSlice(allocator);
    const selected = a.findChat(id) orelse return result.toOwnedSlice(allocator);
    const source = selected.source orelse return result.toOwnedSlice(allocator);
    const selected_pr = prs.forChat(a, selected);
    if (selected_pr) |pr| try result.append(allocator, .{ .chat_id = id, .summary = pr[0], .provenance = pr[1] });
    for (a.chats.items) |chat| {
        if (chat.archived or chat.parent_chat_id != null or std.mem.eql(u8, chat.id, id)) continue;
        const other = chat.source orelse continue;
        if (!std.mem.eql(u8, source.repo_root, other.repo_root) or !std.mem.eql(u8, selected.device_id orelse "", chat.device_id orelse "")) continue;
        const pr = prs.forChat(a, chat) orelse continue;
        const duplicate = for (result.items) |existing| {
            if (std.mem.eql(u8, existing.summary.url, pr[0].url)) break true;
        } else false;
        if (!duplicate) try result.append(allocator, .{ .chat_id = chat.id, .summary = pr[0], .provenance = pr[1] });
    }
    return result.toOwnedSlice(allocator);
}

pub fn github(c: *ui.Context, a: *App, k: theme.Colors) void {
    {
        const title = ui.div(c).column().wFull().p(14).gap(5);
        defer title.end();
        ui.text(c, "Session pull requests", .{ .size = 15, .weight = .semibold, .color = k.text });
        ui.text(c, "Branches used by this repository’s sessions—not every PR on GitHub.", .{ .size = 11.5, .wrap = true, .color = k.muted });
    }
    rule(c, k);
    const items = sessionPullRequests(a, c.alloc()) catch return;
    if (items.len == 0) return empty(c, k, if (a.engine.state != .connected) "Connect to the host to discover session pull requests." else "No session pull request is available. The host needs gh installed and signed in to GitHub.");
    const list = ui.div(c).column().wFull().grow().h(0).p(14).gap(12).scrollY();
    defer list.end();
    for (items) |item| {
        const pr = item.summary;
        ui.key(c, pr.url);
        const card = ui.div(c).column().wFull().p(12).gap(9).border(k.border).borderW(1).rounded(10);
        defer card.end();
        const model = cr.model(c.alloc(), pr);
        const tone = @import("view_change_requests.zig").badgeColor(k, pr, item.provenance);
        {
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            icons.icon(c, .@"pull-request", 14, tone, 0);
            ui.text(c, model.number, .{ .size = 12, .mono = true, .color = tone });
            tag(c, k, model.state_label, tone);
        }
        ui.text(c, model.title, .{ .size = 13, .weight = .medium, .wrap = true, .color = k.text });
        ui.text(c, c.print("{s} → {s}", .{ pr.head_ref, pr.base_ref }), .{ .size = 11, .mono = true, .wrap = true, .color = k.muted });
        if (item.provenance.note(c.alloc(), pr)) |note| ui.text(c, note, .{ .size = 11, .wrap = true, .color = k.muted });
        {
            const row = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer row.end();
            if (button(c, k, "Open on GitHub", true)) _ = nanoui.shell.openUrl(pr.url);
            const selected = if (a.selected) |id| std.mem.eql(u8, id, item.chat_id) else false;
            if (!selected) {
                if (button(c, k, "Open session", true)) a.openChatInTab(item.chat_id);
            } else if (a.findChat(item.chat_id)) |chat| @import("view_change_requests.zig").mergeControls(c, a, k, chat, pr);
        }
    }
}

fn button(c: *ui.Context, k: theme.Colors, label: []const u8, enabled: bool) bool {
    const b = ui.div(c).row().h(26).px(8).itemsCenter().rounded(6).hover(if (enabled) k.hover else .transparent).control();
    defer b.end();
    ui.text(c, label, .{ .size = 11.5, .color = if (enabled) k.text else k.faint });
    return enabled and b.clicked();
}
fn tag(c: *ui.Context, k: theme.Colors, label: []const u8, color: ui.Color) void {
    const chip = ui.div(c).row().px(5).py(2).rounded(4).bg(color.alpha(0.08)).maxW(160).clip();
    defer chip.end();
    kit.ellipsisText(c, label, .{ .size = 10, .color = color }, 150);
    _ = k;
}
fn rule(c: *ui.Context, k: theme.Colors) void {
    ui.div(c).wFull().h(1).bg(k.border).end();
}
fn empty(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const box = ui.div(c).column().wFull().grow().p(24).center();
    defer box.end();
    ui.text(c, label, .{ .size = 12, .wrap = true, .color = k.muted });
}
