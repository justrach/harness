//! Composer-footer Agent Work indicator & popover card (`crates/ui/src/agent_work.rs`).
//!
//! Sits immediately left of the context-window ring in `view_session_footer.zig`:
//! connected step-progress nodes (`<= 6` steps) or `done/total` badge (`> 6`),
//! live subagent counter, and a hover/click-pinned popover showing the task
//! timeline, active substeps, subagents (click to open side panel), and tool chips.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const aw = @import("agent_work.zig");

const open_delay: f64 = 0.08;
const hide_delay: f64 = 0.14;
const enter_s: f64 = 0.14;
pub const card_w: f32 = 328;

pub const State = struct {
    anchor: ?ui.Rect = null,
    card: ?ui.Rect = null,
    card_id: u64 = 0,
    card_h: ?f32 = null,
    hover_since: ?f64 = null,
    leave_since: ?f64 = null,
    opened_at: ?f64 = null,
    open: bool = false,
    pinned: bool = false,
};

pub fn indicator(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.agent_work;
    const working = a.selectedStatus() == .working;
    const w = aw.derive(c.alloc(), a.transcript.entries.items, &a.tool_progress, working);
    if (w.isEmpty()) {
        s.* = .{};
        return;
    }

    ui.key(c, "agent-work-chip");
    var pill = ui.div(c).row().h(24).px(6).gap(6).itemsCenter().rounded(6).control();
    pill = if (s.open) pill.bg(k.hover) else pill.hover(k.hover);
    defer pill.end();

    if (w.steps.len > 0) {
        if (w.steps.len <= aw.max_footer_dots) {
            paintStepChain(c, k, w.steps);
        } else {
            const active = for (w.steps) |st| {
                if (st.state == .active) break true;
            } else false;
            statusGlyph(c, k, if (active) .active else if (w.doneSteps() == w.steps.len) .done else .pending, false, 12);
            ui.text(c, c.print("{d}/{d}", .{ w.doneSteps(), w.steps.len }), kit.style(c, 11, 16, .{ .tabular = true, .weight = .medium, .color = k.muted }));
        }
    }

    if (w.agents.len > 0) {
        if (w.steps.len > 0) {
            ui.text(c, "·", kit.style(c, 11, 16, .{ .color = k.faint }));
        }
        const running = w.runningAgents();
        const failed = w.failedAgents();
        if (running > 0) {
            paintSpinner(c, 12, 1.5, k.accent, k.accent.alpha(0.2));
            const label = if (w.steps.len == 0)
                (if (running == 1) "1 agent running" else c.print("{d} agents running", .{running}))
            else
                (if (running == 1) "1 agent" else c.print("{d} agents", .{running}));
            kit.rollText(c, "agent-work-footer-agents", label, kit.style(c, 11, 16, .{ .tabular = true, .weight = .medium, .color = k.text }));
        } else if (failed > 0) {
            paintFailedGlyph(c, 12, k.danger);
            ui.text(c, if (failed == 1) "1 failed" else c.print("{d} failed", .{failed}), kit.style(c, 11, 16, .{ .tabular = true, .weight = .medium, .color = k.danger }));
        } else {
            icons.icon(c, .bot, 12, k.muted, 0);
            const total = w.agents.len;
            const label = if (w.steps.len == 0)
                (if (total == 1) "1 agent done" else c.print("{d} agents done", .{total}))
            else
                (if (total == 1) "1 agent" else c.print("{d} agents", .{total}));
            ui.text(c, label, kit.style(c, 11, 16, .{ .tabular = true, .color = k.muted }));
        }
    }

    if (w.animating() and !c.reduced_motion) kit.loaderFrame(c, 1.0 / 30.0);

    s.anchor = c.rects.get(c.node(pill.index).id);
    if (pill.clicked()) {
        if (s.open and s.pinned) {
            s.pinned = false;
            s.open = false;
            s.opened_at = null;
        } else {
            s.pinned = true;
            if (!s.open) s.opened_at = c.time;
            s.open = true;
            s.leave_since = null;
        }
        c.changed = true;
        return;
    }

    const over_pill = if (s.anchor) |r| r.contains(c.input.mouse) else false;
    const over_card = if (s.card) |r| r.contains(c.input.mouse) else false;
    if (s.pinned) {
        if (kit.pressedOutside(c, s.anchor)) {
            s.pinned = false;
            s.open = false;
            s.opened_at = null;
            c.changed = true;
        }
        return;
    }

    if (over_pill) {
        s.leave_since = null;
        if (s.hover_since == null) s.hover_since = c.time;
        const waited = c.time - s.hover_since.?;
        if (!s.open and waited >= open_delay) {
            s.open = true;
            s.opened_at = c.time;
            c.changed = true;
        } else if (!s.open) {
            c.frameIn(@floatCast(open_delay - waited));
        }
    } else if (over_card and s.open) {
        s.leave_since = null;
    } else {
        s.hover_since = null;
        if (!s.open) return;
        if (s.leave_since == null) s.leave_since = c.time;
        const gone = c.time - s.leave_since.?;
        if (gone < hide_delay) {
            c.frameIn(@floatCast(hide_delay - gone));
            return;
        }
        s.open = false;
        s.opened_at = null;
        s.leave_since = null;
        c.changed = true;
    }
}

pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.view.agent_work;
    if (!s.open or a.selected == null or a.view.settings_open) {
        s.card = null;
        return;
    }
    const anchor = s.anchor orelse {
        s.card = null;
        return;
    };
    const working = a.selectedStatus() == .working;
    const w = aw.derive(c.alloc(), a.transcript.entries.items, &a.tool_progress, working);
    if (w.isEmpty()) {
        s.open = false;
        s.pinned = false;
        s.card = null;
        return;
    }

    const prev_h = s.card_h;
    if (s.card_id != 0) if (c.rects.get(s.card_id)) |r| {
        s.card = r;
        s.card_h = r.h;
    };
    const est_h = s.card_h orelse estimateHeight(w);
    const pos = aw.placeCard(anchor, card_w, est_h, c.size, 8, 8);

    const raw_t: f32 = if (c.reduced_motion or s.opened_at == null)
        1
    else
        @floatCast(std.math.clamp((c.time - s.opened_at.?) / enter_s, 0, 1));
    const eased = ui.motion.Easing.css_ease_out.sample(raw_t)[0];
    if (raw_t < 1) {
        c.frameIn(1.0 / 120.0);
        c.animationFrame();
    }
    const max_y = @max(8, c.size.h - 8 - est_h);
    const draw_y = std.math.clamp(pos.y + (1 - eased) * 4, 8, max_y);

    ui.key(c, "agent-work-card");
    const card = kit.shadowLg(
        ui.div(c)
            .fixed()
            .offset(pos.x, draw_y)
            .w(card_w)
            .maxH(@max(120, c.size.h - 16))
            .layer(6)
            .column()
            .rounded(12)
            .border(k.border)
            .borderW(1)
            .bg(k.composer)
            .control()
            .motion(.{ .opacity = eased }),
    );
    s.card_id = c.node(card.index).id;
    if (c.rects.get(s.card_id)) |r| {
        if (prev_h == null or @abs(r.h - prev_h.?) > 0.5 or @abs(r.y - draw_y) > 0.5) c.changed = true;
        s.card = r;
        s.card_h = r.h;
    } else {
        c.changed = true;
    }
    defer {
        kit.noteCard(c, card);
        card.end();
    }

    const body_scroll = ui.div(c)
        .column()
        .wFull()
        .maxH(@max(96, c.size.h - 18))
        .p(14)
        .gap(10)
        .scrollY()
        .wheel()
        .clip();
    defer body_scroll.end();

    if (w.steps.len > 0) {
        drawStepsSection(c, k, w);
    }

    if (w.steps.len > 0 and w.agents.len > 0) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    }

    if (w.agents.len > 0) {
        drawAgentsSection(c, a, k, w);
    }

    if (w.tools.len > 0) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        drawToolsSection(c, k, w.tools);
    }

    if (w.animating() and !c.reduced_motion) kit.loaderFrame(c, 1.0 / 30.0);
}

fn drawStepsSection(c: *ui.Context, k: theme.Colors, w: aw.AgentWork) void {
    const sec = ui.div(c).column().wFull().gap(8);
    defer sec.end();

    {
        const head = ui.div(c).row().wFull().itemsCenter();
        defer head.end();
        ui.text(c, "Tasks", kit.style(c, 11.5, 16, .{ .weight = .semibold, .color = k.muted }));
        ui.spacer(c);
        ui.text(c, c.print("{d} of {d}", .{ w.doneSteps(), w.steps.len }), kit.style(c, 11, 16, .{ .tabular = true, .color = k.faint }));
    }

    const list = ui.div(c).column().wFull().gap(0);
    defer list.end();

    for (w.steps, 0..) |step, idx| {
        const is_last = idx + 1 == w.steps.len;
        const row = ui.div(c).row().wFull().gap(9).itemsStart();
        defer row.end();

        // Left timeline rail: status glyph + vertical connector to next step.
        {
            const rail = ui.div(c).column().w(14).itemsCenter();
            defer rail.end();
            const pad_top = ui.div(c).pt(2);
            statusGlyph(c, k, step.state, step.asks_first, 14);
            pad_top.end();
            if (!is_last) {
                const spine_h: f32 = if (step.substeps.len > 0)
                    10 + @as(f32, @floatFromInt(step.substeps.len)) * 20
                else
                    10;
                const spine_color = if (step.state == .done) k.accent.alpha(0.45) else k.border;
                _ = c.leaf(.{ .width = .{ .px = 1.5 }, .height = .{ .px = spine_h }, .background = spine_color }, .none, null);
            }
        }

        // Right content: step label + optional duration/gate badge + substeps.
        const body = ui.div(c).column().wFull().pb(if (is_last) 0 else 8).gap(4);
        defer body.end();
        {
            const line = ui.div(c).row().wFull().gap(6).itemsCenter();
            defer line.end();
            const label_box = ui.div(c).column().wFull();
            const label_color = switch (step.state) {
                .active => k.text,
                .done => k.muted,
                .pending => if (step.asks_first) k.text else k.faint,
            };
            ui.text(c, step.label, kit.style(c, 12.5, 18, .{
                .wrap = true,
                .weight = if (step.state == .active) .medium else .regular,
                .color = label_color,
            }));
            label_box.end();

            if (step.asks_first) {
                const gate = ui.div(c).row().h(18).px(6).itemsCenter().rounded(5).bg(k.warning.alpha(0.15));
                ui.text(c, "Asks first", kit.style(c, 10.5, 14, .{ .weight = .medium, .color = k.warning }));
                gate.end();
            } else if (step.duration_s) |secs| {
                var dbuf: [32]u8 = undefined;
                const dstr = @import("view_working.zig").elapsedLabel(&dbuf, @intCast(secs));
                ui.text(c, c.print("{s}", .{dstr}), kit.style(c, 10.5, 16, .{ .tabular = true, .color = k.faint }));
            }
        }

        if (step.substeps.len > 0) {
            const subs = ui.div(c).column().wFull().pl(2).gap(3);
            defer subs.end();
            for (step.substeps) |sub| {
                const srow = ui.div(c).row().wFull().h(18).gap(6).itemsCenter();
                defer srow.end();
                paintSubstepElbow(c, k.border);
                const max_sub_w: f32 = if (sub.status_word != null) 186 else 236;
                kit.fadeText(c, sub.title, kit.style(c, 11, 16, .{
                    .mono = true,
                    .color = if (sub.active) k.text else k.muted,
                }), max_sub_w);
                if (sub.status_word) |word| {
                    ui.spacer(c);
                    ui.text(c, word, kit.style(c, 10.5, 16, .{ .weight = .medium, .color = k.accent }));
                }
            }
        }
    }
}

fn drawAgentsSection(c: *ui.Context, a: *App, k: theme.Colors, w: aw.AgentWork) void {
    const sec = ui.div(c).column().wFull().gap(6);
    defer sec.end();

    const running = w.runningAgents();
    const header_text = if (running > 0)
        (if (running == 1) "1 agent running" else c.print("{d} agents running", .{running}))
    else
        (if (w.agents.len == 1) "1 agent done" else c.print("{d} agents done", .{w.agents.len}));
    ui.text(c, header_text, kit.style(c, 11.5, 16, .{ .weight = .semibold, .color = k.muted }));

    for (w.agents, 0..) |ag, idx| {
        ui.key(c, c.print("agent-work-sub-{d}", .{idx}));
        const clickable = ag.subagent_ref.len > 0 and ag.part_ptr != null;
        var row = ui.div(c).row().wFull().px(8).py(6).gap(8).itemsCenter().rounded(8).bg(k.ink(0.03));
        if (clickable) row = kit.pressFeedback(row.control().hover(k.ink(0.07)));
        defer row.end();

        agentGlyph(c, k, ag.state, 14);

        {
            const mid = ui.div(c).column().grow().w(0).gap(1).clip();
            defer mid.end();
            {
                const top = ui.div(c).row().wFull().gap(6).itemsCenter();
                defer top.end();
                const title_max: f32 = if (ag.model.len > 0) 152 else 232;
                kit.fadeText(c, ag.title, kit.style(c, 12, 16, .{ .weight = .medium, .color = k.text }), title_max);
                if (ag.model.len > 0) {
                    kit.fadeText(c, ag.model, kit.style(c, 10.5, 15, .{ .color = k.faint }), 92);
                }
            }
            if (ag.detail.len > 0) {
                const detail_color = if (ag.state == .failed) k.danger else k.muted;
                kit.fadeText(c, ag.detail, kit.style(c, 11, 15, .{ .color = detail_color }), 242);
            }
        }

        if (clickable) {
            icons.icon(c, .@"arrow-up-right", 12, k.muted, 0);
            if (row.clicked()) {
                if (a.selected) |parent| {
                    @import("app_subagents.zig").open(a, parent, ag.part_ptr.?);
                    a.view.agent_work.pinned = false;
                    a.view.agent_work.open = false;
                }
            }
        }
    }
}

fn drawToolsSection(c: *ui.Context, k: theme.Colors, tools: []const aw.ToolChip) void {
    const row = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
    defer row.end();
    for (tools) |chip| {
        const pill = ui.div(c).row().h(22).px(7).gap(4).itemsCenter().rounded(6).bg(k.ink(0.05));
        defer pill.end();
        icons.icon(c, chip.icon, 11, k.muted, 0);
        ui.text(c, chip.label, kit.style(c, 11, 15, .{ .color = k.muted }));
    }
}

fn paintStepChain(c: *ui.Context, k: theme.Colors, steps: []const aw.Step) void {
    const node_sz: f32 = 12;
    const link_w: f32 = 6;
    const n: f32 = @floatFromInt(steps.len);
    const total_w = n * node_sz + @max(0, n - 1) * link_w;
    const cv = ui.canvas(c, .{ .width = .{ .px = total_w }, .height = .{ .px = node_sz } });
    const cy = node_sz / 2;

    for (steps, 0..) |step, i| {
        const x0 = @as(f32, @floatFromInt(i)) * (node_sz + link_w);
        const cx = x0 + node_sz / 2;
        paintStepOnCanvas(cv, c, k, .{ .x = cx, .y = cy }, 4.6, 1.35, step.state, step.asks_first);

        if (i + 1 < steps.len) {
            const lx0 = x0 + node_sz + 0.5;
            const lx1 = x0 + node_sz + link_w - 0.5;
            if (step.state == .done) {
                const seg = c.alloc().dupe(ui.Point, &.{ .{ .x = lx0, .y = cy }, .{ .x = lx1, .y = cy } }) catch continue;
                cv.polyline(seg, .{ .width = 1.35, .color = k.accent });
            } else {
                const mid1 = lx0 + 1.8;
                const mid2 = lx1 - 1.8;
                const d1 = c.alloc().dupe(ui.Point, &.{ .{ .x = lx0, .y = cy }, .{ .x = mid1, .y = cy } }) catch continue;
                const d2 = c.alloc().dupe(ui.Point, &.{ .{ .x = mid2, .y = cy }, .{ .x = lx1, .y = cy } }) catch continue;
                cv.polyline(d1, .{ .width = 1.25, .color = k.border });
                cv.polyline(d2, .{ .width = 1.25, .color = k.border });
            }
        }
    }
}

pub fn statusGlyph(c: *ui.Context, k: theme.Colors, state: aw.StepState, asks_first: bool, size: f32) void {
    const cv = ui.canvas(c, .{ .width = .{ .px = size }, .height = .{ .px = size } });
    paintStepOnCanvas(cv, c, k, .{ .x = size / 2, .y = size / 2 }, size * 0.38, 1.45, state, asks_first);
}

pub fn agentGlyph(c: *ui.Context, k: theme.Colors, state: aw.AgentState, size: f32) void {
    switch (state) {
        .running => paintSpinner(c, size, 1.5, k.accent, k.accent.alpha(0.2)),
        .completed => statusGlyph(c, k, .done, false, size),
        .failed => paintFailedGlyph(c, size, k.danger),
        .cancelled => {
            const cv = ui.canvas(c, .{ .width = .{ .px = size }, .height = .{ .px = size } });
            const cy = size / 2;
            cv.ring(.{ .x = cy, .y = cy }, size * 0.38, 1.35, k.border);
            const bar = c.alloc().dupe(ui.Point, &.{ .{ .x = cy - 2.5, .y = cy }, .{ .x = cy + 2.5, .y = cy } }) catch return;
            cv.polyline(bar, .{ .width = 1.4, .color = k.muted });
        },
    }
}

fn paintStepOnCanvas(
    cv: *ui.Canvas,
    c: *ui.Context,
    k: theme.Colors,
    center: ui.Point,
    radius: f32,
    stroke: f32,
    state: aw.StepState,
    asks_first: bool,
) void {
    switch (state) {
        .done => {
            fillCircle(cv, c, center, radius + 0.5, k.accent);
            const r = radius * 0.52;
            const check = c.alloc().dupe(ui.Point, &.{
                .{ .x = center.x - r * 0.95, .y = center.y + r * 0.05 },
                .{ .x = center.x - r * 0.20, .y = center.y + r * 0.80 },
                .{ .x = center.x + r * 1.05, .y = center.y - r * 0.75 },
            }) catch return;
            cv.polyline(check, .{ .width = 1.45, .color = .hex(0xffffff) });
        },
        .active => paintSpinnerOnCanvas(cv, c, center, radius, stroke, k.accent, k.accent.alpha(0.22)),
        .pending => {
            const tint = if (asks_first) k.warning else k.border;
            cv.ring(center, radius, stroke, tint);
        },
    }
}

pub fn paintSpinner(c: *ui.Context, size: f32, stroke: f32, color: ui.Color, track: ui.Color) void {
    const cv = ui.canvas(c, .{ .width = .{ .px = size }, .height = .{ .px = size } });
    paintSpinnerOnCanvas(cv, c, .{ .x = size / 2, .y = size / 2 }, size * 0.38, stroke, color, track);
}

fn paintSpinnerOnCanvas(
    cv: *ui.Canvas,
    c: *ui.Context,
    center: ui.Point,
    radius: f32,
    stroke: f32,
    color: ui.Color,
    track: ui.Color,
) void {
    cv.ring(center, radius, stroke, track);
    const phase: f32 = if (c.reduced_motion) 0 else @floatCast(@mod(c.time, 1.0));
    const start_angle = -std.math.pi / 2.0 + phase * std.math.tau;
    const sweep = std.math.tau * (306.0 / 360.0); // 54° gap, as GPUI's SPINNER_SWEEP
    const segs: usize = 24;
    const pts = c.alloc().alloc(ui.Point, segs + 1) catch return;
    for (pts, 0..) |*pt, i| {
        const a = start_angle + sweep * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
        pt.* = .{ .x = center.x + radius * @cos(a), .y = center.y + radius * @sin(a) };
    }
    cv.polyline(pts, .{ .width = stroke, .color = color });
}

fn paintFailedGlyph(c: *ui.Context, size: f32, danger: ui.Color) void {
    const cv = ui.canvas(c, .{ .width = .{ .px = size }, .height = .{ .px = size } });
    const mid: ui.Point = .{ .x = size / 2, .y = size / 2 };
    fillCircle(cv, c, mid, size * 0.40, danger.alpha(0.18));
    const d = size * 0.18;
    const a1 = c.alloc().dupe(ui.Point, &.{ .{ .x = mid.x - d, .y = mid.y - d }, .{ .x = mid.x + d, .y = mid.y + d } }) catch return;
    const a2 = c.alloc().dupe(ui.Point, &.{ .{ .x = mid.x + d, .y = mid.y - d }, .{ .x = mid.x - d, .y = mid.y + d } }) catch return;
    cv.polyline(a1, .{ .width = 1.4, .color = danger });
    cv.polyline(a2, .{ .width = 1.4, .color = danger });
}

fn paintSubstepElbow(c: *ui.Context, color: ui.Color) void {
    const cv = ui.canvas(c, .{ .width = .{ .px = 10 }, .height = .{ .px = 14 } });
    const pts = c.alloc().dupe(ui.Point, &.{
        .{ .x = 2, .y = 1 },
        .{ .x = 2, .y = 7 },
        .{ .x = 4, .y = 9 },
        .{ .x = 9, .y = 9 },
    }) catch return;
    cv.polyline(pts, .{ .width = 1.15, .color = color });
}

fn fillCircle(cv: *ui.Canvas, c: *ui.Context, center: ui.Point, radius: f32, color: ui.Color) void {
    const n: usize = 20;
    const pts = c.alloc().alloc(ui.Point, n) catch return;
    for (pts, 0..) |*pt, i| {
        const a = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        pt.* = .{ .x = center.x + radius * @cos(a), .y = center.y + radius * @sin(a) };
    }
    cv.fill(pts, color);
}

fn estimateHeight(w: aw.AgentWork) f32 {
    var h: f32 = 28;
    if (w.steps.len > 0) {
        h += 24 + @as(f32, @floatFromInt(w.steps.len)) * 28;
        for (w.steps) |st| h += @as(f32, @floatFromInt(st.substeps.len)) * 20;
    }
    if (w.steps.len > 0 and w.agents.len > 0) h += 16;
    if (w.agents.len > 0) {
        h += 24 + @as(f32, @floatFromInt(w.agents.len)) * 42;
    }
    if (w.tools.len > 0) h += 40;
    return h;
}
