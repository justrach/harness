//! The session footer's pull request, driven headlessly on made-up
//! projects, chats and PRs and no engine: its badge in each state
//! (change_requests.rs `pull_request_badge`, Composer surface), muted for a
//! shared branch's merged or closed PR (#357), its card, and the merge
//! controls (pickers.rs `render_change_request_merge`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const cr = @import("change_requests.zig");
const merging = @import("app_change_requests.zig");
const prs = @import("view_change_requests.zig");

const testing = std.testing;

const spaces =
    \\[{"id":"g","deviceId":"d","path":"/work/fieldnotes","gitDetected":true,"checkoutId":"main-co"}]
;

// "own" works in a worktree of its own; "main" and "peer" share the
// project's folder; "legacy" has no source context.
const chats =
    \\[{"id":"own","deviceId":"d","title":"Own","archived":false,"spaceId":"g","cwd":"/work/fieldnotes-wt/badges","branch":"feat/badges",
    \\  "sourceContext":{"checkoutId":"wt-1","repoRoot":"/work/fieldnotes","cwd":"/work/fieldnotes-wt/badges","branch":"feat/badges","observedAt":"2026-10-01T00:00:00Z"}},
    \\ {"id":"main","deviceId":"d","title":"Main","archived":false,"spaceId":"g","cwd":"/work/fieldnotes","branch":"feat/shared",
    \\  "sourceContext":{"checkoutId":"main-co","repoRoot":"/work/fieldnotes","cwd":"/work/fieldnotes","branch":"feat/shared","observedAt":"2026-10-01T00:00:00Z"}},
    \\ {"id":"peer","deviceId":"d","title":"Peer","archived":false,"spaceId":"g","cwd":"/work/fieldnotes","branch":"feat/shared",
    \\  "sourceContext":{"checkoutId":"main-co","repoRoot":"/work/fieldnotes","cwd":"/work/fieldnotes","branch":"feat/shared","observedAt":"2026-10-01T00:00:00Z"}},
    \\ {"id":"legacy","deviceId":"d","title":"Legacy","archived":false,"spaceId":"g","cwd":"/work/fieldnotes-wt/old","branch":"feat/badges"}]
;

fn pr(state: cr.State) cr.Summary {
    return .{ .provider = "github", .number = 90, .title = "Add pull request badges", .url = "https://example.invalid/acme/fieldnotes/pull/90", .state = state, .base_ref = "main", .head_ref = "feat/badges" };
}

const Harness = struct {
    a: App,
    t: ui.Tester,

    /// Opens `chat` with its branch's PR in `state` (none: no snapshot).
    fn init(h: *Harness, chat: []const u8, state: ?cr.State) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        var s = try std.json.parseFromSlice(std.json.Value, testing.allocator, spaces, .{});
        defer s.deinit();
        try h.a.spaces.replace(s.value);
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        if (state) |st| {
            const c = h.a.findChat(chat).?;
            const src = c.source.?;
            var summary = pr(st);
            summary.head_ref = src.branch;
            try h.a.change_requests.client.store(
                .{ .device_id = "d", .cwd = src.repo_root, .branch = src.branch, .checkout_id = src.checkout_id },
                .{ .checkout_id = src.checkout_id, .device_id = "d", .cwd = src.repo_root, .branch = src.branch, .change_request = summary },
            );
        }
        h.a.openChat(chat, null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn colors(h: *Harness) @import("theme.zig").Colors {
        return @import("view_settings_appearance.zig").withAccent(@import("theme.zig").colors(true), &h.a);
    }

    /// The text `s`'s colour, and the box it's in.
    fn text(h: *Harness, s: []const u8) ?struct { color: ui.Color, box: ui.Rect, bg: ?ui.Color, radius: f32 } {
        for (h.t.ctx.nodes.items) |n| switch (n.content) {
            .text => |tx| if (std.mem.eql(u8, tx.str, s)) {
                const p = h.t.ctx.nodes.items[n.parent];
                return .{ .color = tx.color, .box = p.rect, .bg = p.style.background, .radius = p.style.radius };
            },
            else => {},
        };
        return null;
    }

    /// `NANO_SNAP_DIR=dir`, running the test binary: saves what it saw.
    fn snap(h: *Harness, name: []const u8) void {
        const d = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(d), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

fn expectColor(want: ui.Color, got: ui.Color) !void {
    try testing.expectApproxEqAbs(want.r, got.r, 1e-4);
    try testing.expectApproxEqAbs(want.g, got.g, 1e-4);
    try testing.expectApproxEqAbs(want.b, got.b, 1e-4);
    try testing.expectApproxEqAbs(want.a, got.a, 1e-4);
}

test "an open PR from the chat's own worktree: a 20-point badge in the success tone at the footer's right, Merge beside it" {
    var h: Harness = undefined;
    try h.init("own", .open);
    defer h.deinit();
    h.snap("footer-pr-open");
    const k = h.colors();
    const b = h.text("#90").?;
    try expectColor(k.success.alpha(0.85), b.color);
    try expectColor(k.success.alpha(0.08), b.bg.?);
    try testing.expectEqual(@as(f32, 20), b.box.h);
    try testing.expectEqual(@as(f32, 6), b.radius);
    try testing.expect(h.t.hasText("Merge"));
    // The trailing group: the badge ends where the composer's pill does,
    // Merge before it.
    const pill = h.a.view.composer_anchor.?;
    try testing.expectApproxEqAbs(pill.x + pill.w, b.box.x + b.box.w, 0.5);
    try testing.expect(h.t.findText("Merge").?.x < b.box.x);
    try testing.expect(h.t.findText("feat/badges").?.x < h.t.findText("Merge").?.x);
}

test "merged in the accent, closed in danger; neither offers Merge" {
    for ([_]cr.State{ .merged, .closed }) |st| {
        var h: Harness = undefined;
        try h.init("own", st);
        defer h.deinit();
        h.snap(if (st == .merged) "footer-pr-merged" else "footer-pr-closed");
        const k = h.colors();
        const b = h.text("#90").?;
        const tone = if (st == .merged) k.accent else k.danger;
        try expectColor(tone.alpha(0.85), b.color);
        try expectColor(tone.alpha(0.08), b.bg.?);
        try testing.expect(!h.t.hasText("Merge"));
    }
}

test "#357: a shared branch's merged PR is muted; its open one keeps its tone" {
    {
        var h: Harness = undefined;
        try h.init("main", .merged);
        defer h.deinit();
        h.snap("footer-pr-shared-merged");
        const k = h.colors();
        try expectColor(k.muted.alpha(0.85), h.text("#90").?.color);
        try expectColor(k.muted.alpha(0.08), h.text("#90").?.bg.?);
    }
    {
        var h: Harness = undefined;
        try h.init("main", .open);
        defer h.deinit();
        try expectColor(h.colors().success.alpha(0.85), h.text("#90").?.color);
        try testing.expect(h.t.hasText("Merge"));
    }
}

fn hover(t: *ui.Tester, s: []const u8) !void {
    const r = t.findText(s) orelse return error.TextNotFound;
    t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
}

test "the badge deepens under the pointer, and after 350 ms its card says what it is and where it was found" {
    var h: Harness = undefined;
    try h.init("main", .open);
    defer h.deinit();
    const k = h.colors();
    try hover(&h.t, "#90");
    h.t.frame();
    const b = h.text("#90").?;
    try expectColor(k.success, b.color);
    try expectColor(k.success.alpha(0.16), b.bg.?);
    // The card needs a nanoui with tooltips (justrach/nanoui, Div.tooltipWith).
    if (comptime @hasDecl(ui.Div, "tooltipWith")) try card(&h, k);
}

fn card(h: *Harness, k: @import("theme.zig").Colors) !void {
    try testing.expect(!h.t.hasText("PR #90 · Open"));
    h.t.advance(0.4);
    h.t.frame();
    h.snap("footer-pr-card");
    try testing.expect(h.t.tooltipText() != null);
    try testing.expect(h.t.hasText("PR #90 · Open"));
    try testing.expect(h.t.hasText("Add pull request badges"));
    try testing.expect(h.t.hasText("Found from branch feat/shared, also used by 1 other chat. Not necessarily this chat's."));
    try expectColor(k.success, h.text("PR #90 · Open").?.color);
    // Its own chat's PR has no note.
    var own: Harness = undefined;
    try own.init("own", .open);
    defer own.deinit();
    try hover(&own.t, "#90");
    own.t.frame();
    own.t.advance(0.4);
    own.t.frame();
    try testing.expect(own.t.hasText("PR #90 · Open"));
    try testing.expect(!own.t.containsText("Found from branch"));
}

test "Merge asks Merge #90?; Cancel takes it back; confirming without an engine says so" {
    var h: Harness = undefined;
    try h.init("own", .open);
    defer h.deinit();
    try h.t.clickText("Merge");
    h.t.settle(1);
    h.snap("footer-pr-armed");
    try testing.expect(h.t.hasText("Merge #90?"));
    try testing.expect(h.t.hasText("Cancel"));
    try expectColor(h.colors().success.alpha(0.75), h.text("Merge #90?").?.color);
    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Merge #90?"));
    try testing.expect(h.t.hasText("Merge"));
    try h.t.clickText("Merge");
    h.t.settle(1);
    try h.t.clickText("Merge #90?");
    h.t.settle(1);
    h.snap("footer-pr-refused");
    try testing.expect(h.a.change_requests.busy == null);
    try testing.expect(h.t.hasText("not connected"));
    try expectColor(h.colors().danger, h.text("not connected").?.color);
    // Merge is offered again beside the answer.
    try testing.expect(h.t.hasText("Merge"));
}

test "a merge running says Merging #90…; the host's yes is in success" {
    var h: Harness = undefined;
    try h.init("own", .open);
    defer h.deinit();
    h.a.change_requests.busy = try testing.allocator.dupe(u8, "own");
    h.t.settle(1);
    h.snap("footer-pr-merging");
    try testing.expect(h.t.hasText("Merging #90…"));
    try testing.expect(!h.t.hasText("Merge"));
    try expectColor(h.colors().muted.alpha(0.7), h.text("Merging #90…").?.color);
    merging.applyMerge(&h.a, .{ .merged = true, .message = "Merged pull request #90" });
    h.t.settle(1);
    try testing.expect(h.t.hasText("Merged pull request #90"));
    try expectColor(h.colors().success, h.text("Merged pull request #90").?.color);
}

test "the host's answer stays after the PR merged: no Merge, the answer, the merged badge" {
    var h: Harness = undefined;
    try h.init("own", .merged);
    defer h.deinit();
    h.a.change_requests.busy = try testing.allocator.dupe(u8, "own");
    merging.applyMerge(&h.a, .{ .merged = true, .message = "Merged pull request #90" });
    h.t.settle(1);
    try testing.expect(h.t.hasText("Merged pull request #90"));
    try testing.expect(!h.t.hasText("Merge"));
    try testing.expect(h.t.hasText("#90"));
}

test "no badge without a current source context, nor on a device whose engine refused the watch" {
    {
        var h: Harness = undefined;
        try h.init("legacy", null);
        defer h.deinit();
        try h.a.change_requests.client.store(.{ .device_id = "d", .cwd = "/work/fieldnotes", .branch = "feat/badges", .checkout_id = "wt-1" }, .{ .checkout_id = "wt-1", .device_id = "d", .cwd = "/work/fieldnotes", .branch = "feat/badges", .change_request = pr(.open) });
        h.t.settle(1);
        try testing.expect(h.t.hasText("Worktree"));
        try testing.expect(!h.t.hasText("#90"));
    }
    {
        var h: Harness = undefined;
        try h.init("own", .open);
        defer h.deinit();
        try testing.expect(h.t.hasText("#90"));
        h.a.change_requests.client.markUnsupported("d", "0.2.2");
        h.t.settle(1);
        try testing.expect(!h.t.hasText("#90"));
        try testing.expect(!h.t.hasText("Merge"));
    }
}

/// The Sidebar surface (the command palette's): 16 tall, 4 in, 4 round,
/// 10-point mono, no glyph.
const SidebarBadge = struct {
    k: @import("theme.zig").Colors,
    fn view(s: *SidebarBadge, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().p(20).itemsStart();
        defer root.end();
        prs.badge(c, s.k, pr(.closed), .own_branch, .sidebar, false);
    }
};

test "the Sidebar surface: 16 tall, 4 round, 10-point number, no glyph" {
    @import("theme.zig").registerFonts();
    var s: SidebarBadge = .{ .k = @import("theme.zig").colors(true) };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, SidebarBadge.view), .{ .width = 200, .height = 80, .dark = true });
    defer t.deinit();
    t.frame();
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "#90")) {
            const p = t.ctx.nodes.items[n.parent];
            try testing.expectEqual(@as(f32, 16), p.rect.h);
            try testing.expectEqual(@as(f32, 4), p.style.radius);
            try testing.expectEqual(@as(f32, 10), tx.style.size);
            try testing.expect(tx.style.mono);
            try expectColor(s.k.danger.alpha(0.85), tx.color);
            // No glyph: the number alone, 4 in from either side.
            try testing.expectApproxEqAbs(p.rect.w - 8, n.rect.w, 0.5);
            return;
        },
        else => {},
    };
    return error.TextNotFound;
}
