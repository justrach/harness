//! Tool Access Map parity with release/v0.2.172: real recent history,
//! horizontally scrollable graph, and an honest subagent boundary.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const tr = @import("transcript.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const access = @import("tool_access.zig");
const panels = @import("app_panels.zig");
const workspace = @import("workspace.zig");

pub const graph_width: f32 = 692; // 16*2 + 180*2 + 220 + 80.

pub fn open(a: *App, chat: []const u8) void {
    if (a.selected == null or !std.mem.eql(u8, a.selected.?, chat)) return;
    a.view.tool_ui.openAccess(a.gpa, chat);
    for (a.panels.tabs.items, 0..) |t, i| if (t.kind == .tool_access and std.mem.eql(u8, t.path, chat)) {
        a.panels.host_open = true;
        return panels.showTab(a, i);
    };
    const owned = a.gpa.dupe(u8, chat) catch return;
    a.panels.tabs.append(a.gpa, .{ .kind = .tool_access, .path = owned }) catch return a.gpa.free(owned);
    a.panels.host_open = true;
    panels.showTab(a, a.panels.tabs.items.len - 1);
}

pub fn draw(c: *ui.Context, a: *App, k: theme.Colors) void {
    const tab = a.panels.activeTab() orelse return;
    const chat_id = if (tab.path.len > 0) tab.path else a.selected orelse return;
    a.view.tool_ui.openAccess(a.gpa, chat_id);
    const chat = a.findChat(chat_id);
    const t: ?*const tr.Transcript = if (a.selected != null and std.mem.eql(u8, a.selected.?, chat_id)) &a.transcript else if (a.peer(chat_id)) |p| &p.transcript else null;
    const session = workspace.sessionOf(a.sessions.items, chat_id);
    const harness = if (chat) |ch| ch.harness orelse "agent" else "agent";
    const cache = a.view.tool_ui.accessMap(a.gpa, chat_id, c.time) orelse return;
    const map = cache.refresh(a.gpa, chat_id, .{
        .id = "main",
        .name = if (std.mem.eql(u8, harness, "claude-code")) "claude" else harness,
        .model = if (chat) |ch| ch.model orelse "" else "",
        .task = if (chat) |ch| ch.title orelse ch.preview orelse "This chat" else "This chat",
        .running = if (session) |s| s.status == .working or s.status == .awaiting_input else false,
    }, if (t) |transcript| transcript.entries.items else &.{});
    const root = ui.div(c).column().wFull().grow().h(0).bg(k.panel);
    defer root.end();
    {
        const header = ui.div(c).row().wFull().h(40).px(16).gap(8).itemsCenter();
        defer header.end();
        icons.icon(c, .widget, 14, k.accent, 0);
        ui.text(c, "Tool access", kit.style(c, 14, 20, .{ .weight = .semibold, .color = k.text }));
        ui.spacer(c);
        ui.text(c, map.stats(c.alloc()), .{ .size = 11, .color = k.muted });
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    if (map.agents.len == 0) return;
    a.view.tool_ui.selected_agent = @min(a.view.tool_ui.selected_agent, map.agents.len - 1);
    agentTabs(c, a, k, map);
    if (a.view.tool_ui.selected_tool) |family| detail(c, a, k, map, family) else graph(c, a, k, map);
}

fn agentTabs(c: *ui.Context, a: *App, k: theme.Colors, map: access.Snapshot) void {
    var total: f32 = 32;
    const st: ui.TextStyle = .{ .size = 12, .color = k.text };
    for (map.agents, 0..) |agent, i| total += @min(220, c.text.width(agent.name, st) + 44) + (if (i > 0) @as(f32, 8) else 0);
    const viewport = ui.div(c).row().wFull().h(44).clip();
    defer viewport.end();
    horizontal(c, viewport, &a.view.tool_ui.agent_scroll, total);
    const tabs = ui.div(c).row().absolute().offset(16 - a.view.tool_ui.agent_scroll, 12).gap(8);
    defer tabs.end();
    for (map.agents, 0..) |agent, i| {
        ui.key(c, c.print("tool-access-agent-{s}", .{agent.id}));
        const on = i == a.view.tool_ui.selected_agent;
        const width = @min(220, c.text.width(agent.name, st) + 44);
        const tab = kit.pressFeedback(ui.div(c).row().size(width, 32).px(12).gap(6).itemsCenter().rounded(8).bg(if (on) k.raised else k.ink(0.04)).border(if (on) k.border else k.border.alpha(0)).borderW(1).control());
        defer tab.end();
        icons.icon(c, .bot, 12, if (on) k.text else k.muted, 0);
        kit.fadeText(c, agent.name, .{ .size = 12, .color = if (on) k.text else k.muted }, @max(width - 44, 0));
        if (tab.clicked()) {
            a.view.tool_ui.selected_agent = i;
            a.view.tool_ui.selected_tool = null;
            a.view.tool_ui.selected_call = null;
        }
    }
}

/// Nano's pinned UI has vertical scroll boxes and a public sideways wheel
/// channel. Own that channel in this clipped viewport, without stealing a
/// vertical transcript scroll or introducing per-frame timers.
fn horizontal(c: *ui.Context, viewport: ui.Div, offset: *f32, content: f32) void {
    c.node(viewport.index).style.wheel = true;
    const rect = c.rects.get(c.node(viewport.index).id) orelse return;
    const delta = if (viewport.hovered()) c.input.scroll.x else 0;
    const next = access.panOffset(offset.*, delta, content, rect.w);
    if (delta != 0) c.input.scroll.x = 0;
    if (next != offset.*) c.changed = true;
    offset.* = next;
}

fn graph(c: *ui.Context, a: *App, k: theme.Colors, map: access.Snapshot) void {
    const agent = map.agents[a.view.tool_ui.selected_agent];
    if (a.view.tool_ui.selected_agent > 0) {
        const own = ui.div(c).column().wFull().grow().h(0).p(16).center().gap(12);
        defer own.end();
        agentCard(c, k, agent);
        ui.text(c, "Its tool calls are in its own transcript. Open it from the chat.", .{ .size = 11, .wrap = true, .color = k.muted });
        return;
    }
    const viewport = ui.div(c).column().wFull().grow().h(0).clip();
    defer viewport.end();
    const rect = c.rects.get(c.node(viewport.index).id);
    const width = @max(graph_width, if (rect) |r| r.w else graph_width);
    const top = @max(0, ((if (rect) |r| r.h else 280) - 280) / 2);
    horizontal(c, viewport, &a.view.tool_ui.map_scroll, width);
    const stage = ui.div(c).row().absolute().offset(-a.view.tool_ui.map_scroll, top).size(width, 280);
    defer stage.end();
    const cv = ui.canvas(c, .{ .absolute = true, .width = .fill, .height = .fill });
    const color = ui.Color.hex(0x398bf0).alpha(0.85);
    for (map.nodes[0..4], 0..) |node, i| if (node.calls > 0) {
        const y = 140 + (@as(f32, @floatFromInt(i)) - 1.5) * 62;
        link(cv, .{ .x = 196, .y = y }, .{ .x = width / 2 - 110, .y = 140 }, color);
    };
    if (map.nodes[4].calls > 0) link(cv, .{ .x = width / 2 + 110, .y = 140 }, .{ .x = width - 196, .y = 140 }, color);
    {
        const left = ui.div(c).column().absolute().offset(16, 21).gap(10);
        defer left.end();
        for (map.nodes[0..4]) |node| nodeCard(c, a, k, node);
    }
    {
        const middle = ui.div(c).column().absolute().offset((width - 220) / 2, 92);
        defer middle.end();
        agentCard(c, k, agent);
    }
    {
        const right = ui.div(c).column().absolute().offset(width - 196, 114);
        defer right.end();
        nodeCard(c, a, k, map.nodes[4]);
    }
}

/// One bounded 24-segment cubic ribbon. Canvas geometry avoids a large
/// square SVG texture for each viewport width or family combination.
fn link(cv: *ui.Canvas, from: ui.Point, to: ui.Point, color: ui.Color) void {
    const c1: ui.Point = .{ .x = from.x + (to.x - from.x) * 0.45, .y = from.y };
    const c2: ui.Point = .{ .x = from.x + (to.x - from.x) * 0.55, .y = to.y };
    var points: [25]ui.Point = undefined;
    for (&points, 0..) |*point, i| {
        const t = @as(f32, @floatFromInt(i)) / 24;
        const s = 1 - t;
        point.* = .{ .x = s * s * s * from.x + 3 * s * s * t * c1.x + 3 * s * t * t * c2.x + t * t * t * to.x, .y = s * s * s * from.y + 3 * s * s * t * c1.y + 3 * s * t * t * c2.y + t * t * t * to.y };
    }
    var outline: [50]ui.Point = undefined;
    for (points, 0..) |point, i| {
        const before = points[i -| 1];
        const after = points[@min(i + 1, points.len - 1)];
        const dx = after.x - before.x;
        const dy = after.y - before.y;
        const length = @max(@sqrt(dx * dx + dy * dy), 0.0001);
        const nx = -dy / length * 0.75;
        const ny = dx / length * 0.75;
        outline[i] = .{ .x = point.x + nx, .y = point.y + ny };
        outline[49 - i] = .{ .x = point.x - nx, .y = point.y - ny };
    }
    cv.fill(&outline, color);
}

fn agentCard(c: *ui.Context, k: theme.Colors, agent: access.Agent) void {
    const blue: ui.Color = .hex(0x398bf0);
    const card = ui.div(c).column().size(220, 96).px(16).py(12).gap(8).rounded(8).border(k.border).borderW(1).bg(k.raised);
    defer card.end();
    {
        const head = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer head.end();
        icons.icon(c, .bot, 16, k.text, 0);
        {
            const words = ui.div(c).column().grow().w(0).clip();
            defer words.end();
            kit.fadeText(c, agent.name, .{ .size = 14, .weight = .semibold, .color = k.text }, if (agent.running) 85 else 150);
            if (agent.model.len > 0) kit.fadeText(c, agent.model, .{ .size = 11, .color = k.muted }, 150);
        }
        if (agent.running) {
            const pill = ui.div(c).row().h(22).px(8).gap(6).itemsCenter().rounded(11).bg(blue.alpha(0.18));
            defer pill.end();
            if (!c.reduced_motion) kit.snake(c, k);
            ui.text(c, "Running", .{ .size = 11, .color = blue });
        }
    }
    kit.fadeText(c, agent.task, .{ .size = 11, .color = k.muted }, 186);
}

fn nodeCard(c: *ui.Context, a: *App, k: theme.Colors, node: access.Node) void {
    ui.key(c, c.print("tool-access-node-{s}", .{@tagName(node.family)}));
    const card = kit.pressFeedback(ui.div(c).column().size(180, 52).px(12).gap(2).justifyCenter().rounded(8).border(k.border).borderW(1).bg(k.raised).control().motion(.{ .opacity = if (node.calls > 0) 1 else 0.45 }));
    defer card.end();
    {
        const row = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer row.end();
        icons.icon(c, node.family.icon(), 14, if (node.failed) k.danger else k.muted, 0);
        ui.text(c, node.family.name(), .{ .size = 13, .weight = .semibold, .color = if (node.failed) k.danger else k.text });
    }
    ui.text(c, node.subtitle(c.alloc()), .{ .size = 11, .color = k.muted });
    if (card.clicked()) {
        a.view.tool_ui.selected_tool = node.family;
        a.view.tool_ui.selected_call = null;
    }
}

fn detail(c: *ui.Context, a: *App, k: theme.Colors, map: access.Snapshot, family: access.Family) void {
    const node = map.nodes[@backingInt(family)];
    const outer = ui.div(c).column().wFull().grow().h(0).p(16);
    defer outer.end();
    const panel = ui.div(c).column().wFull().grow().h(0).rounded(8).border(k.border).borderW(1).bg(k.raised).clip();
    defer panel.end();
    {
        const header = ui.div(c).row().wFull().h(44).px(14).gap(10).itemsCenter();
        defer header.end();
        ui.key(c, "tool-access-back");
        if (kit.iconButton(c, k, .@"alt-arrow-left", .{ .size = 24, .icon = 14, .tip = .{ .text = "Back to the map" } })) {
            a.view.tool_ui.selected_tool = null;
            a.view.tool_ui.selected_call = null;
        }
        icons.icon(c, family.icon(), 14, k.muted, 0);
        {
            const words = ui.div(c).column().gap(1);
            defer words.end();
            ui.text(c, family.name(), .{ .size = 13, .weight = .semibold, .color = k.text });
            ui.text(c, node.subtitle(c.alloc()), .{ .size = 11, .color = k.muted });
        }
        ui.spacer(c);
        ui.text(c, c.print("{d} {s}", .{ node.calls, if (node.calls == 1) "call" else "calls" }), .{ .size = 11, .color = k.muted });
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const selected = map.record(family, a.view.tool_ui.selected_call);
    if (selected == null) {
        const empty = ui.div(c).column().wFull().grow().center();
        defer empty.end();
        ui.text(c, c.print("{s} hasn't called it yet", .{map.agents[a.view.tool_ui.selected_agent].name}), .{ .size = 13, .color = k.muted });
        return;
    }
    const split = ui.div(c).row().wFull().grow().h(0);
    defer split.end();
    {
        const records = ui.div(c).column().w(260).hFull();
        defer records.end();
        ui.scroll(c, .{ .width = .fill, .grow = 1, .height = .{ .px = 0 }, .padding = .{ .top = 8, .bottom = 8 } });
        defer ui.end(c);
        var shown: usize = 0;
        for (map.records) |rec| {
            if (rec.family != family) continue;
            shown += 1;
            ui.key(c, c.print("tool-access-call-{d}", .{rec.id}));
            const on = selected.?.id == rec.id;
            const call = kit.pressFeedback(ui.div(c).row().wFull().px(12).py(8).gap(8).itemsCenter().bg(if (on) k.ink(0.06) else k.ink(0)).control().hover(k.ink(0.04)));
            defer call.end();
            icons.icon(c, if (rec.part.is_error) .close else .check, 12, if (rec.part.is_error) k.danger else k.success, 0);
            kit.fadeText(c, c.print("{s} {s}", .{ rec.part.chip, rec.part.text.items }), .{ .size = 11, .mono = true, .color = k.text }, 214);
            if (call.clicked()) a.view.tool_ui.selected_call = rec.id;
        }
        if (shown < node.calls) {
            const tail = ui.div(c).row().px(12).py(8);
            defer tail.end();
            ui.text(c, c.print("Latest {d} of {d}", .{ shown, node.calls }), .{ .size = 11, .color = k.faint });
        }
    }
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
    const io = ui.div(c).column().grow().w(0).hFull();
    defer io.end();
    ui.scroll(c, .{ .width = .fill, .grow = 1, .height = .{ .px = 0 }, .padding = .{ .left = 14, .right = 14, .top = 14, .bottom = 14 }, .gap = 12 });
    defer ui.end(c);
    ioBlock(c, k, "INPUT", selected.?.input);
    ioBlock(c, k, "OUTPUT", selected.?.output);
}

fn ioBlock(c: *ui.Context, k: theme.Colors, label: []const u8, text: []const u8) void {
    const box = ui.div(c).column().wFull().gap(6);
    defer box.end();
    ui.text(c, label, .{ .size = 11, .weight = .semibold, .color = k.muted });
    const body = ui.div(c).column().wFull().p(10).rounded(8).bg(k.ink(0.05));
    defer body.end();
    ui.text(c, text, .{ .size = 11, .mono = true, .wrap = true, .color = k.text });
}
