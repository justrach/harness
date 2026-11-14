//! Home's agent-update island: one bottom-anchored surface for the compact
//! summary pill (`3 agent updates · <Device> ^`) and the expanded agent list.
//! Ported from Zeron's `crates/ui/src/shell/harness_updates.rs`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const motion_rules = @import("motion_rules.zig");
const updates = @import("agent_updates.zig");
const App = @import("app.zig").App;

pub const chip_height: f32 = 38;
pub const summary_height: f32 = chip_height - 2;
pub const row_height: f32 = 64;
pub const list_width: f32 = 360;
pub const mark_size: f32 = 22;
pub const mark_step: f32 = 14;
pub const max_marks: usize = 3;
/// The dismiss button (24) and the gap before it (4).
const dismiss_w: f32 = 28;

const ActionSpec = struct {
    label: []const u8,
    method: ?[]const u8,
};

fn actionFor(st: updates.Status) ?ActionSpec {
    return switch (st.phase) {
        .available => if (st.can_apply)
            .{ .label = "Update", .method = "ApplyHarnessUpdate" }
        else
            .{ .label = "View steps", .method = null },
        .manual_action_required => if (st.can_apply)
            .{ .label = "Check and update", .method = "ApplyHarnessUpdate" }
        else
            null,
        .waiting_for_idle, .preparing, .downloading => .{ .label = "Cancel", .method = "CancelHarnessUpdate" },
        .failed => if (st.can_apply and st.error_kind == .install)
            .{ .label = "Retry update", .method = "ApplyHarnessUpdate" }
        else
            .{ .label = "Check again", .method = "CheckHarnessUpdates" },
        else => null,
    };
}

fn detailText(c: *ui.Context, st: updates.Status) []const u8 {
    return switch (st.phase) {
        .available => if (st.installed_version != null and st.latest_version != null)
            c.print("{s} → {s}", .{ st.installed_version.?, st.latest_version.? })
        else if (st.latest_version) |lat|
            c.print("Version {s} available", .{lat})
        else
            "Update available",
        .manual_action_required => "Latest version unavailable; updater will check and install if needed",
        .waiting_for_idle => "Waiting for the current run",
        .preparing => "Preparing update…",
        .downloading => st.progress_message orelse "Downloading…",
        .installing => "Installing…",
        .verifying => "Verifying installation…",
        .updated => if (st.installed_version) |ver| c.print("Updated to {s}", .{ver}) else "Updated",
        .failed => st.error_message orelse if (st.error_kind == .install) "Update failed" else "Couldn’t check for updates",
        else => "Checking for updates…",
    };
}

fn summaryChevron(c: *ui.Context, k: theme.Colors, reveal: f32) void {
    const tick: u32 = @intFromFloat(@round(std.math.clamp(reveal, 0, 1) * 16));
    const angle = 180.0 * (1.0 - @as(f32, @floatFromInt(tick)) / 16.0);
    const box = ui.div(c).row().size(24, 24).center();
    defer box.end();
    _ = ui.svg(c, .{
        .key = c.print("agent-updates-chevron-{d}", .{tick}),
        .bytes = c.print("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 14 14\"><path fill=\"none\" stroke=\"black\" stroke-width=\"1.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\" transform=\"rotate({d} 7 7)\" d=\"M4 5.5 L7 8.5 L10 5.5\"/></svg>", .{angle}),
        .size = 14,
        .color = k.muted,
    });
}

fn markStack(c: *ui.Context, k: theme.Colors, rows: []const updates.VisibleRow) void {
    const count = @min(rows.len, max_marks);
    if (count == 0) return;
    const total_w = mark_size + mark_step * @as(f32, @floatFromInt(count - 1));
    const box = ui.div(c).row().size(total_w, mark_size);
    defer box.end();
    var idx = count;
    while (idx > 0) {
        idx -= 1;
        const row = rows[idx];
        const mark = icons.harnessMark(row.status.harness);
        var circle = ui.div(c).row().absolute().offset(@as(f32, @floatFromInt(idx)) * mark_step, 0).size(mark_size, mark_size).center().roundedFull();
        if (count > 1) {
            circle = circle.bg(k.composer).border(k.border).borderW(1);
        }
        icons.icon(c, mark.name, 14, mark.brand orelse k.muted, 0);
        circle.end();
    }
}

fn actionButton(c: *ui.Context, a: *App, k: theme.Colors, row: updates.VisibleRow, interactive: bool) void {
    const spec = actionFor(row.status) orelse return;
    const available = spec.method == null or row.connected;
    const enabled = interactive and available;
    const primary = if (spec.method) |m| std.mem.eql(u8, m, "ApplyHarnessUpdate") else false;
    ui.key(c, c.print("harness-update-action-{s}-{s}", .{ row.device_id, row.status.harness }));
    var btn = ui.div(c).row().h(26).px(11).center().roundedFull().control();
    if (primary) {
        btn = btn.bg(k.text);
        if (enabled) btn = btn.hover(k.text.alpha(0.85));
    } else {
        btn = btn.bg(k.hover);
        if (enabled) btn = btn.hover(k.wash(0.14));
    }
    if (!available) btn = btn.opacity(0.45);
    defer btn.end();
    ui.text(c, spec.label, .{
        .size = 11.5,
        .line_height = 14,
        .weight = theme.ui_medium_weight,
        .color = if (primary) k.shell else k.muted,
    });
    if (enabled and btn.clicked()) {
        if (spec.method) |m| {
            updates.runAction(a, row.device_id, m, row.status.harness);
        } else {
            updates.setExpanded(a, false, c.time, c.reduced_motion);
            a.view.settings_open = true;
            a.redraw();
        }
    }
}

/// Renders the bottom-anchored Zeron Agent-Update Island over Home (`a.selected == null`).
/// The caller provides the enclosing pane's `(pane_w, pane_h)`.
pub fn island(c: *ui.Context, a: *App, k: theme.Colors, pane_w: f32, pane_h: f32) void {
    const s = &a.agent_updates;
    if (a.selected != null) {
        updates.setExpanded(a, false, c.time, c.reduced_motion);
        s.card_rect = null;
        return;
    }
    const rows = updates.collectVisible(a, c.alloc());
    if (rows.len == 0) {
        s.expanded = false;
        s.reveal_tween = null;
        s.width_tween = null;
        s.height_tween = null;
        s.card_rect = null;
        return;
    }
    const multiple = rows.len > 1;
    if (!multiple and s.expanded) {
        updates.setExpanded(a, false, c.time, c.reduced_motion);
    }

    // Outside click dismisses the expanded card cleanly without eating the click if not expanded.
    if (s.expanded and c.input.pressed and c.input.button == .left) {
        if (s.card_rect) |cr| {
            if (!cr.contains(c.input.mouse)) {
                updates.setExpanded(a, false, c.time, c.reduced_motion);
            }
        }
    }

    const expanded = s.expanded;
    const reveal = if (s.reveal_tween) |tw| tw.sample(c.time, c.reduced_motion) else if (expanded) @as(f32, 1) else @as(f32, 0);
    var animating = if (s.reveal_tween) |tw| tw.animating(c.time, c.reduced_motion) else false;

    const first = rows[0];
    const first_name = updates.agentName(first.status.harness);
    var all_updated = true;
    var any_active = false;
    var any_disconnected = false;
    var unique_devices: usize = 0;
    for (rows, 0..) |r, idx| {
        if (r.status.phase != .updated) all_updated = false;
        if (r.connected and r.status.phase.isActive()) any_active = true;
        if (!r.connected) any_disconnected = true;
        var seen_dev = false;
        for (rows[0..idx]) |prev| {
            if (std.mem.eql(u8, prev.device_id, r.device_id)) {
                seen_dev = true;
                break;
            }
        }
        if (!seen_dev) unique_devices += 1;
    }

    const lead_title = if (multiple)
        (if (all_updated) c.print("{d} agents updated", .{rows.len}) else c.print("{d} agent updates", .{rows.len}))
    else switch (first.status.phase) {
        .available => if (first.status.latest_version) |v| c.print("{s} {s} available", .{ first_name, v }) else c.print("{s} update available", .{first_name}),
        .manual_action_required => c.print("{s} · latest version unavailable", .{first_name}),
        .waiting_for_idle => c.print("{s} · waiting for idle", .{first_name}),
        .preparing => c.print("Preparing {s}…", .{first_name}),
        .downloading => c.print("Downloading {s}…", .{first_name}),
        .installing => c.print("Updating {s}…", .{first_name}),
        .verifying => c.print("Verifying {s}…", .{first_name}),
        .updated => c.print("{s} updated", .{first_name}),
        .failed => if (first.status.error_kind == .install) c.print("{s} update failed", .{first_name}) else c.print("{s} update check failed", .{first_name}),
        else => return,
    };

    const with_dev = if (unique_devices <= 1)
        c.print("{s} · {s}", .{ lead_title, first.device_name })
    else
        c.print("{s} · {d} devices", .{ lead_title, unique_devices });
    const title = if (any_disconnected) c.print("{s} · disconnected", .{with_dev}) else with_dev;

    const has_activity = any_active or all_updated or (!multiple and first.status.phase == .failed);
    const single_action = if (!multiple) actionFor(first.status) else null;
    const trailing: f32 = if (multiple) 8 else if (single_action != null) 5 else 12;
    const marks_count = @min(rows.len, max_marks);
    const marks_w = mark_size + mark_step * @as(f32, @floatFromInt(marks_count - 1));
    const controls_w: f32 = if (multiple)
        24 + 8
    else if (single_action) |act|
        @ceil(c.text.width(act.label, .{ .size = 11.5, .weight = theme.ui_medium_weight })) + 22 + 8
    else
        0;
    const title_w = @ceil(c.text.width(title, .{ .size = 12, .weight = theme.ui_medium_weight }));
    const max_w = @max(0, pane_w - 32);
    const max_h = @max(chip_height, pane_h - 64);
    const compact_w = @min(max_w, 12 + marks_w + 8 + title_w + (if (has_activity) @as(f32, 22) else 0) + controls_w + dismiss_w + trailing + 4);

    const target = motion_rules.updateIslandTarget(expanded, compact_w, max_w, rows.len, max_h);
    s.width_tween = retargetTween(s.width_tween, target.w, c.time, c.reduced_motion);
    s.height_tween = retargetTween(s.height_tween, target.h, c.time, c.reduced_motion);
    const cur_w = s.width_tween.?.sample(c.time, c.reduced_motion);
    const cur_h = s.height_tween.?.sample(c.time, c.reduced_motion);
    if (s.width_tween.?.animating(c.time, c.reduced_motion) or s.height_tween.?.animating(c.time, c.reduced_motion)) {
        animating = true;
    }
    if (animating) c.animationFrame();

    const radius = motion_rules.sampleTween(19, 16, reveal);
    const list_w = @min(list_width, max_w);

    // Zero-height bottom anchor in Home's column: the card sits 12px above the pane bottom,
    // growing upward as `cur_h` increases so the bottom edge never moves!
    const bottom_margin: f32 = 12;
    const left_x = @max(16, (pane_w - cur_w) * 0.5);
    ui.key(c, "home-harness-update-card");
    var card = kit.shadowLg(
        ui.div(c).column().absolute()
            .offset(left_x, -(cur_h + bottom_margin))
            .size(cur_w, cur_h)
            .rounded(radius)
            .bg(k.composer)
            .border(k.border.alpha(0.85)).borderW(1)
            .clip()
            .control(),
    );
    defer card.end();
    if (c.rects.get(c.node(card.index).id)) |r| s.card_rect = r;

    // Summary header (`36px` inside `1px` top/bottom border).
    {
        ui.key(c, "home-harness-update-summary");
        var sum = ui.div(c).row().wFull().h(summary_height).pl(12).pr(trailing).itemsCenter().control();
        if (multiple) sum = sum.hover(k.hover.alpha(0.45));
        defer sum.end();
        var dismissed = false;
        // Collapsing brand mark stack (`0..0.55`).
        const mark_slot_w = marks_w * (1 - reveal);
        if (mark_slot_w > 0.5) {
            const mwrap = ui.div(c).row().w(mark_slot_w).h(mark_size).clip().opacity(1 - motion_rules.updateStage(reveal, 0, 0.55));
            markStack(c, k, rows);
            mwrap.end();
            _ = c.leaf(.{ .width = .{ .px = 8 * (1 - reveal) } }, .none, null);
        }
        {
            const tbox = ui.div(c).row().grow().w(0).clip();
            defer tbox.end();
            kit.ellipsisText(c, title, .{ .size = 12, .line_height = 16, .weight = theme.ui_medium_weight, .color = k.text }, @max(40, cur_w - 48 - dismiss_w));
        }
        if (has_activity) {
            const act_box = ui.div(c).row().pl(8).itemsCenter();
            defer act_box.end();
            if (any_active) {
                kit.snake(c, k);
            } else if (all_updated) {
                icons.icon(c, .check, 14, k.success, 0);
            } else {
                icons.icon(c, .@"danger-triangle", 14, k.danger, 0);
            }
        }
        if (!multiple) {
            const btn_wrap = ui.div(c).row().pl(8).itemsCenter();
            defer btn_wrap.end();
            actionButton(c, a, k, first, true);
        } else {
            const chev_wrap = ui.div(c).row().pl(8).itemsCenter();
            defer chev_wrap.end();
            summaryChevron(c, k, reveal);
        }
        {
            ui.key(c, "home-harness-update-dismiss");
            const wrap = ui.div(c).row().pl(4).itemsCenter();
            defer wrap.end();
            const btn = ui.div(c).row().size(24, 24).center().roundedFull().hover(k.wash(0.12)).control();
            defer btn.end();
            icons.icon(c, .close, 11, k.muted, 0);
            if (btn.clicked()) dismissed = true;
        }
        if (dismissed) {
            updates.dismiss(a);
            return;
        }
        if (multiple and sum.clicked()) {
            updates.setExpanded(a, !s.expanded, c.time, c.reduced_motion);
        }
    }

    if (reveal <= 0.001) return;

    // Header hairline divider (`0.20..0.65`).
    _ = c.leaf(.{
        .width = .fill,
        .height = .{ .px = 1 },
        .background = k.border.alpha(0.65 * motion_rules.updateStage(reveal, 0.20, 0.65)),
    }, .none, null);

    // Centered list host (`0.30..0.72` list fade, `0.42..0.90` row glide & fade).
    const body_h = @max(0, cur_h - summary_height - 1);
    const list_alpha = motion_rules.updateStage(reveal, 0.30, 0.72);
    const row_reveal = motion_rules.updateStage(reveal, 0.42, 0.90);
    const list_host = ui.div(c).column()
        .offset((cur_w - list_w) * 0.5, 0)
        .size(@max(0, list_w - 2), body_h)
        .clip()
        .scrollY()
        .opacity(list_alpha);
    defer list_host.end();

    for (rows, 0..) |row, idx| {
        ui.key(c, c.print("harness-update-row-{s}-{s}", .{ row.device_id, row.status.harness }));
        const rwrap = ui.div(c).column().wFull().h(row_height).offset(0, 3 * (1 - row_reveal)).opacity(row_reveal);
        defer rwrap.end();
        if (idx > 0) {
            const div_row = ui.div(c).row().wFull().pl(42).pr(12);
            _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border.alpha(0.55) }, .none, null);
            div_row.end();
        }
        const label = if (row.connected) detailText(c, row.status) else "Disconnected · reconnect to update";
        const action_w: f32 = if (actionFor(row.status)) |act|
            @ceil(c.text.width(act.label, .{ .size = 11.5, .weight = theme.ui_medium_weight })) + 22
        else
            0;
        // Account for this action's actual width; “Check and update” is wider
        // than the ordinary Update button and must not overlap the copy.
        const text_w = @max(0, list_w - 2 - 24 - 20 - 20 - action_w);
        const tip_text = c.print("{s} · {s}\n{s}", .{ updates.agentName(row.status.harness), row.device_name, row.status.manual_command orelse label });
        const inner = tip.on(ui.div(c).row().wFull().grow().px(12).gap(10).itemsCenter(), k, .{ .text = tip_text, .delay = tip.quick });
        defer inner.end();
        const mark = icons.harnessMark(row.status.harness);
        icons.icon(c, mark.name, 20, mark.brand orelse k.muted, 0);
        {
            const col = ui.div(c).column().grow().w(0).gap(2);
            defer col.end();
            kit.ellipsisText(c, updates.agentName(row.status.harness), .{ .size = 12.5, .line_height = 16, .weight = theme.ui_medium_weight, .color = k.text }, text_w);
            if (unique_devices > 1) {
                kit.ellipsisText(c, row.device_name, .{ .size = 11, .line_height = 14, .color = k.muted }, text_w);
            }
            if (row.connected and row.status.phase == .manual_action_required) {
                kit.ellipsisText(c, "Latest unavailable", .{ .size = 11, .line_height = 14, .color = k.muted }, text_w);
                kit.ellipsisText(c, "Updater checks / installs", .{ .size = 11, .line_height = 14, .color = k.muted }, text_w);
            } else {
                kit.ellipsisText(c, label, .{
                    .size = 11,
                    .line_height = 14,
                    .color = if (row.status.phase == .failed) k.danger else k.muted,
                }, text_w);
            }
        }
        if (row.status.phase == .updated) {
            icons.icon(c, .check, 14, k.success, 0);
        }
        actionButton(c, a, k, row, expanded and row_reveal >= 0.90);
    }
}

// No platform app, window, live profile or engine connection: only the island
// rendered by nanoui's in-process headless tester.
const TestHarness = struct {
    app: App,
    tester: ui.Tester,

    fn init(h: *TestHarness) !void {
        theme.registerFonts();
        h.app = .init(std.testing.allocator, std.testing.io, 1);
        h.app.offscreen = true;
        h.app.dark = true;
        try h.tester.init(std.testing.allocator, .init(&h.app, testView), .{
            .width = 1100,
            .height = 400,
            .dark = true,
            .theme = theme.ui(true),
        });
    }

    fn testView(a: *App, c: *ui.Context) void {
        const root = ui.div(c).column().wFull().hFull();
        defer root.end();
        const anchor = ui.div(c).column().absolute().offset(0, 400).wFull();
        defer anchor.end();
        island(c, a, theme.colors(true), 1100, 400);
    }

    fn snap(h: *TestHarness, name: []const u8) !void {
        const dir = std.c.getenv("NANO_UPDATE_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name });
        try h.tester.screenshot(path);
    }

    fn deinit(h: *TestHarness) void {
        h.tester.deinit();
        h.app.deinit();
    }
};

test "Antigravity checklist shows an honest native check and update action" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();
    try updates.setTestStatuses(&h.app, "synthetic-device", true,
        \\[{"harness":"antigravity","installedVersion":"1.5.7","phase":"manual-action-required","canApply":true}]
    );
    h.tester.settle(1);
    try std.testing.expectEqual(@as(usize, 1), updates.visibleCount(&h.app));
    try std.testing.expect(h.tester.hasText("Antigravity · latest version unavailable · synthetic-device"));
    try std.testing.expect(h.tester.hasText("Check and update"));
    try std.testing.expect(!h.tester.hasText("Antigravity update available"));
    try h.snap("antigravity-checklist-native");
    try h.tester.clickText("Check and update");
    h.tester.settle(0.3);
    const action = h.app.agent_updates.last_action orelse return error.MissingNativeUpdateAction;
    try std.testing.expectEqualStrings("ApplyHarnessUpdate", action.method);
    try std.testing.expectEqualStrings("antigravity", action.harness);
    try std.testing.expectEqualStrings("synthetic-device", action.device_id);
}

test "Antigravity checklist expanded row explains the unknown latest version and stays dismissible" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();
    try updates.setTestStatuses(&h.app, "synthetic-device", true,
        \\[{"harness":"antigravity","installedVersion":"1.5.7","phase":"manual-action-required","canApply":true},
        \\ {"harness":"pi","installedVersion":"1.5.0","latestVersion":"1.5.2","phase":"available","canApply":true}]
    );
    h.tester.settle(1);
    updates.setExpanded(&h.app, true, h.tester.time, false);
    h.tester.settle(1);
    try std.testing.expect(h.tester.hasText("Antigravity"));
    try std.testing.expect(h.tester.hasText("Latest unavailable"));
    const explanation = h.tester.findText("Updater checks / installs") orelse return error.MissingUpdaterExplanation;
    const button = h.tester.findText("Check and update") orelse return error.MissingUpdaterButton;
    try std.testing.expect(explanation.x + explanation.w < button.x);
    const rows = updates.collectVisible(&h.app, h.tester.ctx.alloc());
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("Latest version unavailable; updater will check and install if needed", detailText(&h.tester.ctx, rows[0].status));
    try h.snap("antigravity-checklist-expanded");
    updates.dismiss(&h.app);
    h.tester.settle(1);
    try std.testing.expectEqual(@as(usize, 0), updates.visibleCount(&h.app));
    try std.testing.expect(!h.tester.hasText("Check and update"));
}

test "Antigravity checklist keeps legacy manual servers hidden and disconnect disables native action" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();
    try updates.setTestStatuses(&h.app, "synthetic-device", true,
        \\[{"harness":"antigravity","phase":"manual-action-required","canApply":false,"manualCommand":"Update the configured Antigravity ACP server"}]
    );
    h.tester.settle(1);
    try std.testing.expectEqual(@as(usize, 0), updates.visibleCount(&h.app));
    try std.testing.expect(!h.tester.hasText("Check and update"));
    try updates.setTestStatuses(&h.app, "synthetic-device", false,
        \\[{"harness":"antigravity","phase":"manual-action-required","canApply":true}]
    );
    h.tester.settle(1);
    try std.testing.expect(h.tester.hasText("Check and update"));
    try h.tester.clickText("Check and update");
    h.tester.settle(0.3);
    try std.testing.expect(h.app.agent_updates.last_action == null);
}

fn retargetTween(old: ?updates.Tween, target: f32, now: f64, reduced: bool) updates.Tween {
    if (old) |tw| {
        if (@abs(tw.to - target) <= 0.5) return tw;
        return .{ .from = tw.sample(now, reduced), .to = target, .start = now };
    }
    return .{ .from = target, .to = target, .start = now };
}
