//! Pure Agent Work model (`crates/ui/src/agent_work.rs`, `AgentWork.swift`,
//! and `Nano.SubagentTasks` in `apps/nano/lean-proofs/Nano/SubagentTasks.lean`).
//!
//! Derives the composer footer's step-progress pill, active subagent count,
//! timeline steps, substeps, subagent rows, and tool family chips from the
//! transcript and `WatchToolProgress` without side effects or I/O.
const std = @import("std");
const ui = @import("nanoui").ui;
const tr = @import("transcript.zig");
const agent_link = @import("agent_link.zig");
const icons = @import("icons.zig");
const progress_mod = @import("app_tool_progress.zig");
const Allocator = std.mem.Allocator;

pub const max_footer_dots: usize = 6;
pub const max_substeps: usize = 3;

pub const StepState = enum {
    done,
    active,
    pending,
};

pub const AgentState = enum {
    running,
    completed,
    failed,
    cancelled,

    pub fn isRunning(s: AgentState) bool {
        return s == .running;
    }
};

pub const Substep = struct {
    title: []const u8,
    active: bool,
    status_word: ?[]const u8 = null,
};

pub const Step = struct {
    label: []const u8,
    state: StepState,
    asks_first: bool = false,
    duration_s: ?u64 = null,
    substeps: []Substep = &.{},
};

pub const AgentRow = struct {
    part_id: []const u8 = "",
    subagent_ref: []const u8 = "",
    title: []const u8,
    model: []const u8 = "",
    detail: []const u8 = "",
    state: AgentState,
    part_ptr: ?*const tr.Part = null,
};

pub const ToolChip = struct {
    icon: icons.Name,
    label: []const u8,
};

pub const AgentWork = struct {
    live: bool = false,
    steps: []Step = &.{},
    agents: []AgentRow = &.{},
    tools: []ToolChip = &.{},

    pub fn isEmpty(w: AgentWork) bool {
        return w.steps.len == 0 and w.agents.len == 0;
    }

    pub fn doneSteps(w: AgentWork) usize {
        var n: usize = 0;
        for (w.steps) |s| if (s.state == .done) {
            n += 1;
        };
        return n;
    }

    pub fn runningAgents(w: AgentWork) usize {
        var n: usize = 0;
        for (w.agents) |a| if (a.state == .running) {
            n += 1;
        };
        return n;
    }

    pub fn failedAgents(w: AgentWork) usize {
        var n: usize = 0;
        for (w.agents) |a| if (a.state == .failed) {
            n += 1;
        };
        return n;
    }

    pub fn animating(w: AgentWork) bool {
        if (w.runningAgents() > 0) return true;
        for (w.steps) |s| {
            if (s.state == .active) return true;
            for (s.substeps) |sub| if (sub.active) return true;
        }
        return false;
    }
};

/// Exact mirror of `Nano.SubagentTasks.resolveAgentState`:
/// 1. Live `WatchToolProgress` state (`running`/`completed`/`failed`/`cancelled`) is authoritative.
/// 2. Persisted `subagentStatus` is used next, never leaving a settled turn ghost-running.
/// 3. Falls back to tool `resolved` / `is_error` gated by `turn_live`.
pub fn resolveAgentState(
    live_state: ?[]const u8,
    doc_status: ?agent_link.Status,
    resolved: bool,
    is_error: bool,
    turn_live: bool,
) AgentState {
    if (live_state) |st| {
        if (std.mem.eql(u8, st, "running") or std.mem.eql(u8, st, "parked") or std.mem.eql(u8, st, "waking")) return .running;
        if (std.mem.eql(u8, st, "completed") or std.mem.eql(u8, st, "done")) return .completed;
        if (std.mem.eql(u8, st, "failed") or std.mem.eql(u8, st, "error")) return .failed;
        if (std.mem.eql(u8, st, "cancelled") or std.mem.eql(u8, st, "aborted") or std.mem.eql(u8, st, "stopped")) return .cancelled;
    }
    if (doc_status) |ds| {
        return switch (ds) {
            .done => .completed,
            .failed => .failed,
            .cancelled, .disconnected => .cancelled,
            .running => if (!resolved and turn_live) .running else if (is_error) .failed else .completed,
        };
    }
    if (is_error) return .failed;
    if (!resolved and turn_live) return .running;
    return .completed;
}

/// Exact mirror of `Nano.SubagentTasks.placeCard`: places the popover above
/// `anchor` when it fits, flips below when clipped at the top, and clamps into
/// `[margin, window - margin]` along both axes.
pub fn placeCard(anchor: ui.Rect, card_w: f32, card_h: f32, window: ui.Size, margin: f32, gap: f32) ui.Point {
    const max_x = @max(margin, window.w - margin - card_w);
    const ideal_x = anchor.x + anchor.w - card_w;
    const x = std.math.clamp(ideal_x, margin, max_x);

    const max_y = @max(margin, window.h - margin - card_h);
    const above_y = anchor.y - gap - card_h;
    const below_y = anchor.y + anchor.h + gap;
    const raw_y = if (above_y >= margin) above_y else below_y;
    const y = std.math.clamp(raw_y, margin, max_y);
    return .{ .x = x, .y = y };
}

/// Latest non-empty progress line from a subagent's rolling output, stripping
/// any leading `"▸ "` marker so the card/row shows crisp single-line status.
pub fn lastProgressLine(raw: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, raw, "\r\n");
    while (it.next()) |line| {
        var t = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "▸")) {
            t = std.mem.trimStart(u8, t["▸".len..], " \t");
        }
        if (t.len > 0) best = t;
    }
    return best;
}

/// Extracts a string field from `call.input` in serialized `Part.invocation` JSON.
pub fn invocationModel(alloc: Allocator, invocation: []const u8) []const u8 {
    if (invocation.len == 0) return "";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, invocation, .{}) catch return "";
    if (parsed != .object) return "";
    const input = parsed.object.get("input") orelse return "";
    if (input != .object) return "";
    if (input.object.get("model")) |m| if (m == .string and m.string.len > 0) return m.string;
    return "";
}

pub fn derive(
    alloc: Allocator,
    entries: []const tr.Entry,
    progress: *const progress_mod.State,
    session_working: bool,
) AgentWork {
    if (entries.len == 0 and progress.waiting == null) return .{};

    var turn_start: usize = 0;
    for (entries, 0..) |e, i| {
        if (e.role == .user) turn_start = i + 1;
    }
    const scope = entries[turn_start..];
    const turn_live = blk: {
        for (scope) |e| if (e.status == .streaming) break :blk true;
        if (entries.len > 0 and entries[entries.len - 1].role == .user and session_working) break :blk true;
        break :blk false;
    };

    // 1. Latest non-empty `.todo` checklist in `scope`.
    var latest_todo: ?struct { ei: usize, pi: usize, items: []const tr.TodoItem } = null;
    for (scope, 0..) |e, rel_ei| {
        for (e.parts.items, 0..) |p, pi| {
            if (p.kind == .tool and p.tool == .todo and p.todo_items.len > 0) {
                latest_todo = .{ .ei = rel_ei, .pi = pi, .items = p.todo_items };
            }
        }
    }

    var steps: std.ArrayList(Step) = .empty;
    if (latest_todo) |lt| {
        // Substeps from tools invoked after the latest `.todo` snapshot.
        var substeps: std.ArrayList(Substep) = .empty;
        for (scope[lt.ei..], lt.ei..) |e, rel_ei| {
            const start_pi: usize = if (rel_ei == lt.ei) lt.pi + 1 else 0;
            if (start_pi >= e.parts.items.len) continue;
            for (e.parts.items[start_pi..]) |p| {
                if (p.kind != .tool or p.tool == .todo or p.compaction != null) continue;
                const title = substepTitle(alloc, &p) orelse continue;
                const active = !p.resolved and turn_live;
                const word = if (active) statusWord(p.tool, p.agent) else null;
                if (substeps.items.len == max_substeps) _ = substeps.orderedRemove(0);
                substeps.append(alloc, .{ .title = title, .active = active, .status_word = word }) catch {};
            }
        }

        var seen_active = false;
        for (lt.items, 0..) |item, idx| {
            const st: StepState = if (item.done)
                .done
            else if (turn_live and !seen_active) blk: {
                seen_active = true;
                break :blk .active;
            } else .pending;

            steps.append(alloc, .{
                .label = item.text,
                .state = st,
                .duration_s = if (st == .done) stepDuration(scope, idx) else null,
                .substeps = if (st == .active) substeps.items else &.{},
            }) catch {};
        }
    }

    // Pending `AskUserQuestion` / `.input` gate in `scope`.
    for (scope) |e| {
        var gated: ?[]const u8 = null;
        for (e.parts.items) |p| {
            if (p.kind == .input and !p.resolved) {
                gated = if (p.questions.len > 0 and p.questions[0].question.len > 0)
                    p.questions[0].question
                else if (p.questions.len > 0 and p.questions[0].header.len > 0)
                    p.questions[0].header
                else
                    "Waiting on your answer";
                break;
            }
        }
        if (gated) |label| {
            steps.append(alloc, .{
                .label = label,
                .state = .pending,
                .asks_first = true,
            }) catch {};
            break;
        }
    }

    // 2. Subagent rows: running anywhere in the chat, or settled in current `scope`.
    var agents: std.ArrayList(AgentRow) = .empty;
    for (entries, 0..) |*e, ei| {
        const part_turn_live = (ei >= turn_start) and turn_live;
        for (e.parts.items) |*p| {
            if (p.kind != .tool or !p.agent) continue;
            // Skip pure control calls ("Wait for agent ...") when a real spawn row already exists with the same ref.
            const live = progress.find(p.id);
            const st = resolveAgentState(if (live) |l| l.state else null, p.subagent_status, p.resolved, p.is_error, part_turn_live);
            if (st != .running and ei < turn_start) continue;

            const title = if (p.subagent_title.len > 0)
                p.subagent_title
            else if (p.text.items.len > 0)
                p.text.items
            else
                "Subagent";
            const model = invocationModel(alloc, p.invocation);
            const detail = switch (st) {
                .running => (if (live) |l| lastProgressLine(l.output) else null) orelse
                    lastProgressLine(p.subagent_tail) orelse
                    lastProgressLine(p.output) orelse
                    "Starting…",
                .completed => if (p.subagent_ref.len > 0)
                    "Ready to review"
                else
                    (lastProgressLine(p.output) orelse "Done"),
                .failed => lastProgressLine(p.output) orelse "Failed",
                .cancelled => "Stopped",
            };

            const row: AgentRow = .{
                .part_id = p.id,
                .subagent_ref = p.subagent_ref,
                .title = title,
                .model = model,
                .detail = detail,
                .state = st,
                .part_ptr = p,
            };

            var merged = false;
            for (agents.items) |*existing| {
                const same_ref = p.subagent_ref.len > 0 and std.mem.eql(u8, existing.subagent_ref, p.subagent_ref);
                const same_id = p.id.len > 0 and std.mem.eql(u8, existing.part_id, p.id);
                if (same_ref or same_id) {
                    existing.* = row;
                    merged = true;
                    break;
                }
            }
            if (!merged) agents.append(alloc, row) catch {};
        }
    }

    // Merge cross-turn `graff/waiting` background subagents if not already present.
    if (progress.waiting) |w| {
        for (w.agents) |wa| {
            var exists = false;
            for (agents.items) |existing| {
                if ((wa.id.len > 0 and (std.mem.eql(u8, existing.part_id, wa.id) or std.mem.eql(u8, existing.subagent_ref, wa.id))) or
                    (wa.name.len > 0 and std.mem.eql(u8, existing.title, wa.name)))
                {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                const title = if (wa.name.len > 0) wa.name else if (wa.task.len > 0) wa.task else "Background agent";
                const detail = if (wa.task.len > 0 and wa.name.len > 0)
                    wa.task
                else if (w.wakes)
                    "Running in background · wakes when done"
                else
                    "Running in background";
                agents.append(alloc, .{
                    .part_id = wa.id,
                    .title = title,
                    .model = wa.model,
                    .detail = detail,
                    .state = .running,
                }) catch {};
            }
        }
    }

    // 3. Deduplicated tool-family chips across `scope`.
    var tools: std.ArrayList(ToolChip) = .empty;
    for (scope) |e| {
        for (e.parts.items) |p| {
            if (p.kind != .tool or p.tool == .todo or p.compaction != null) continue;
            const chip = familyChip(&p) orelse continue;
            const seen = for (tools.items) |have| {
                if (std.mem.eql(u8, have.label, chip.label)) break true;
            } else false;
            if (!seen) tools.append(alloc, chip) catch {};
        }
    }
    if (agents.items.len > 0) {
        const has_agents = for (tools.items) |have| {
            if (std.mem.eql(u8, have.label, "Agents")) break true;
        } else false;
        if (!has_agents) tools.insert(alloc, 0, .{ .icon = .bot, .label = "Agents" }) catch {};
    }

    return .{
        .live = turn_live or countRunning(agents.items) > 0,
        .steps = steps.items,
        .agents = agents.items,
        .tools = tools.items,
    };
}

fn countRunning(agents: []const AgentRow) usize {
    var n: usize = 0;
    for (agents) |a| if (a.state == .running) {
        n += 1;
    };
    return n;
}

fn stepDuration(scope: []const tr.Entry, step_ix: usize) ?u64 {
    var snapshots: [32]struct { created_ms: i64, done: bool } = undefined;
    var count: usize = 0;
    for (scope) |e| {
        for (e.parts.items) |p| {
            if (p.kind == .tool and p.tool == .todo and step_ix < p.todo_items.len and count < snapshots.len) {
                snapshots[count] = .{ .created_ms = e.created_ms, .done = p.todo_items[step_ix].done };
                count += 1;
            }
        }
    }
    if (count < 2) return null;
    var opened_at: ?i64 = null;
    for (snapshots[0..count]) |snap| {
        if (!snap.done) {
            if (opened_at == null and snap.created_ms > 0) opened_at = snap.created_ms;
        } else if (opened_at) |t0| {
            if (snap.created_ms > t0) {
                const secs: u64 = @intCast(@divTrunc(snap.created_ms - t0, 1000));
                if (secs > 0) return secs;
            }
        }
    }
    return null;
}

fn substepTitle(alloc: Allocator, p: *const tr.Part) ?[]const u8 {
    if (p.agent) {
        const t = if (p.subagent_title.len > 0) p.subagent_title else p.text.items;
        return if (t.len > 0) std.fmt.allocPrint(alloc, "Agent · {s}", .{t}) catch t else "Agent";
    }
    if (p.path.len > 0) {
        const base = std.fs.path.basename(p.path);
        const verb = switch (p.tool) {
            .readFile => "Read",
            .writeFile => "Write",
            .editFile, .applyPatch => "Edit",
            else => p.chip,
        };
        return std.fmt.allocPrint(alloc, "{s} {s}", .{ verb, base }) catch base;
    }
    const detail = std.mem.trim(u8, p.text.items, " \t\r\n");
    if (detail.len == 0) return if (p.chip.len > 0) p.chip else null;
    const line = detail[0 .. std.mem.indexOfScalar(u8, detail, '\n') orelse detail.len];
    return switch (p.tool) {
        .exec => line,
        .search, .glob => std.fmt.allocPrint(alloc, "Search {s}", .{line}) catch line,
        .webFetch, .webSearch => std.fmt.allocPrint(alloc, "{s} {s}", .{ p.chip, line }) catch line,
        else => std.fmt.allocPrint(alloc, "{s} {s}", .{ p.chip, line }) catch line,
    };
}

fn statusWord(kind: tr.ToolKind, is_agent: bool) []const u8 {
    if (is_agent) return "Delegating";
    return switch (kind) {
        .exec => "Running",
        .readFile => "Reading",
        .writeFile => "Writing",
        .editFile => "Editing",
        .applyPatch => "Applying",
        .search, .glob => "Searching",
        .webFetch, .webSearch => "Fetching",
        .todo, .mcp, .unknown => "Working",
    };
}

fn familyChip(p: *const tr.Part) ?ToolChip {
    if (p.agent) return .{ .icon = .bot, .label = "Agents" };
    if (std.mem.eql(u8, p.text.items, "subagent")) return .{ .icon = .bot, .label = "Agents" };
    return switch (p.tool) {
        .exec => .{ .icon = .terminal, .label = "Terminal" },
        .readFile, .writeFile, .editFile, .applyPatch => .{ .icon = .@"file-code", .label = "Files" },
        .search, .glob => .{ .icon = .magnifer, .label = "Search" },
        .webFetch, .webSearch => .{ .icon = .globe, .label = "Web" },
        .mcp => .{
            .icon = .widget,
            .label = if (std.mem.indexOf(u8, p.chip, " · ")) |at| p.chip[0..at] else "MCP",
        },
        .todo, .unknown => null,
    };
}

test "resolveAgentState matches Lean SubagentTasks invariants" {
    const testing = std.testing;
    // Settled turn never leaves a stale running doc status ghost-running.
    try testing.expectEqual(AgentState.completed, resolveAgentState(null, .running, false, false, false));
    try testing.expectEqual(AgentState.failed, resolveAgentState(null, .running, false, true, false));
    // Live WatchToolProgress overrides stale doc state even across turns.
    try testing.expectEqual(AgentState.running, resolveAgentState("running", null, false, false, false));
    try testing.expectEqual(AgentState.completed, resolveAgentState("completed", .running, false, false, true));
    try testing.expectEqual(AgentState.cancelled, resolveAgentState("cancelled", .running, false, false, true));
}

test "placeCard clamps within window margins and flips below when top-clipped" {
    const testing = std.testing;
    const win: ui.Size = .{ .w = 1200, .h = 780 };
    const p1 = placeCard(.{ .x = 900, .y = 720, .w = 64, .h = 24 }, 320, 260, win, 8, 8);
    try testing.expectEqual(@as(f32, 964 - 320), p1.x);
    try testing.expectEqual(@as(f32, 720 - 8 - 260), p1.y);

    // Near top edge: flips below anchor and stays inside [8, win - 8].
    const p2 = placeCard(.{ .x = 20, .y = 18, .w = 48, .h = 24 }, 320, 260, win, 8, 8);
    try testing.expectEqual(@as(f32, 8), p2.x);
    try testing.expectEqual(@as(f32, 18 + 24 + 8), p2.y);
}

test "derive merges todo checklist, substeps, live WatchToolProgress tail, and parked graff/waiting" {
    const testing = std.testing;
    var t: tr.Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[
        \\  {"id":"u1","role":"user","parts":[{"id":"up","kind":"text","text":"Audit the module"}]},
        \\  {"id":"a1","role":"assistant","status":"streaming","createdAt":10000,"parts":[
        \\    {"id":"todo1","kind":"tool","resolved":true,"call":{"kind":"todo","items":[
        \\      {"text":"Map entrypoints","done":true},
        \\      {"text":"Verify subagent bounds","done":false},
        \\      {"text":"Run test suite","done":false}]}},
        \\    {"id":"ag1","kind":"tool","resolved":false,"subagentRef":"doc-sub-1","call":{
        \\      "kind":"unknown","name":"Agent: Lean verifier","input":{"model":"claude-opus-4-6"}}},
        \\    {"id":"ex1","kind":"tool","resolved":false,"call":{"kind":"exec","command":"zig build test"}}
        \\  ]}
        \\]}
    , .{});
    defer parsed.deinit();
    try t.apply(parsed.value);

    var prog: progress_mod.State = .init(testing.allocator);
    defer prog.deinit();
    var prog_json = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"toolId":"ag1","output":"▸ Checking 360 state cells\n▸ Proving card_within_window","state":"running"}]
    , .{});
    defer prog_json.deinit();
    try prog.replace(null, prog_json.value);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const w = derive(arena.allocator(), t.entries.items, &prog, true);

    try testing.expect(w.live);
    try testing.expectEqual(@as(usize, 3), w.steps.len);
    try testing.expectEqual(@as(usize, 1), w.doneSteps());
    try testing.expectEqual(StepState.done, w.steps[0].state);
    try testing.expectEqual(StepState.active, w.steps[1].state);
    try testing.expectEqual(StepState.pending, w.steps[2].state);
    try testing.expectEqual(@as(usize, 2), w.steps[1].substeps.len);

    try testing.expectEqual(@as(usize, 1), w.agents.len);
    try testing.expectEqual(@as(usize, 1), w.runningAgents());
    try testing.expectEqualStrings("Lean verifier", w.agents[0].title);
    try testing.expectEqualStrings("claude-opus-4-6", w.agents[0].model);
    try testing.expectEqualStrings("Proving card_within_window", w.agents[0].detail);
}
