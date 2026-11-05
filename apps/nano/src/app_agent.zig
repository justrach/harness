//! What the next message runs on: the agent, model and reasoning level a
//! new chat starts with, or the open chat's own (its config row, replaced
//! whole by `SetChatConfig` when picked, as the GPUI pickers do), and the
//! models the engine lists for that agent.
const std = @import("std");
const rules = @import("rules.zig");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;

pub const Target = struct {
    harness: []const u8,
    model: ?[]const u8,
    reasoning: ?[]const u8,
};

/// The open chat's agent, model and level, else the new chat's. A level
/// not picked reads as the model's default.
pub fn target(a: *const App) Target {
    var t: Target = .{ .harness = a.new_harness, .model = a.new_model, .reasoning = a.new_reasoning };
    if (a.selected) |id| if (a.findChat(id)) |ch| {
        t = .{ .harness = ch.harness orelse "graff", .model = ch.model, .reasoning = ch.reasoning };
    };
    // The model's ladder, else its agent's (`trait_ladder`), at its default.
    if (t.reasoning == null) if (modelOf(a, t.model) != null) {
        t.reasoning = rules.defaultReasoning(ladder(a, t.harness, t.model));
    };
    return t;
}

/// The model `id` names, else (none picked) the catalog's first: the one
/// the agent runs by default.
fn modelOf(a: *const App, id: ?[]const u8) ?workspace.Model {
    if (id) |want| {
        for (a.models.items) |m| if (std.mem.eql(u8, m.id, want)) return m;
        return null;
    }
    return if (a.models.items.len > 0) a.models.items[0] else null;
}

pub fn modelLabel(a: *const App, id: ?[]const u8) []const u8 {
    if (modelOf(a, id)) |m| return m.label;
    return id orelse harnessName(a, target(a).harness);
}

pub fn levelsOf(a: *const App, id: ?[]const u8) []const []const u8 {
    return ladder(a, target(a).harness, id);
}

/// The model's levels, else (it lists none) its agent's; none before the
/// model is known (`trait_ladder`).
fn ladder(a: *const App, harness: []const u8, model: ?[]const u8) []const []const u8 {
    const m = modelOf(a, model) orelse return &.{};
    if (m.levels.len > 0) return m.levels;
    for (a.harnesses.items) |h| if (std.mem.eql(u8, h.id, harness)) return h.levels;
    return &.{};
}

pub fn harnessName(a: *const App, id: []const u8) []const u8 {
    for (a.harnesses.items) |h| if (std.mem.eql(u8, h.id, id)) return h.name;
    return id;
}

/// Lists `harness`'s models, unless they are listed already.
pub fn ensureModels(a: *App, harness: []const u8) void {
    if (a.engine.state != .connected) return;
    const picker = @import("model_picker.zig");
    const cat = picker.ensureCatalog(a, harness, false) orelse return;
    if (std.mem.eql(u8, a.models_for, harness)) return;
    const copy = a.gpa.dupe(u8, harness) catch return;
    a.gpa.free(a.models_for);
    a.models_for = copy;
    picker.copyModels(&a.models, cat.models.items) catch {};
}

pub fn togglePicker(a: *App) void {
    a.picker = if (a.picker == .none) .model else .none;
    if (a.picker != .none) @import("view_picker.zig").opened(a);
    a.redraw();
}

/// The agent a new chat starts with.
pub fn setHarness(a: *App, id: []const u8) void {
    const copy = a.gpa.dupe(u8, id) catch return;
    a.gpa.free(a.new_harness);
    a.new_harness = copy;
    setNew(a, &a.new_model, null);
    setNew(a, &a.new_reasoning, null);
    ensureModels(a, id);
    a.redraw();
}

/// The model a new chat starts with; null is the agent's default.
pub fn setModel(a: *App, id: ?[]const u8) void {
    setNew(a, &a.new_model, id);
    a.picker = .none;
    a.redraw();
}

fn setNew(a: *App, field: *?[]u8, value: ?[]const u8) void {
    if (field.*) |old| a.gpa.free(old);
    field.* = if (value) |v| a.gpa.dupe(u8, v) catch null else null;
}

pub fn pickModel(a: *App, id: []const u8) void {
    if (a.selected == null) {
        setNew(a, &a.new_reasoning, null);
        return setModel(a, id);
    }
    setChatConfig(a, id, null, true);
}

pub fn pickReasoning(a: *App, level: []const u8) void {
    a.picker = .none;
    if (a.selected == null) {
        setNew(a, &a.new_reasoning, level);
        return a.redraw();
    }
    setChatConfig(a, null, level, false);
}

/// Replaces the open chat's config: its agent stays, the model or the
/// level changes (a new model takes its own default level).
fn setChatConfig(a: *App, model: ?[]const u8, reasoning: ?[]const u8, new_model: bool) void {
    a.picker = .none;
    const id = a.selected orelse return;
    const ch = a.findChat(id) orelse return;
    a.request(requests.setChatConfig(id, .{
        .harness = ch.harness orelse "graff",
        .model = if (new_model) model else ch.model,
        .reasoning = if (new_model) null else reasoning orelse ch.reasoning,
    }), .of(App, a, App.onNotice));
    a.redraw();
}

/// The project a new chat starts in: the one picked, else the first.
pub fn newChatSpace(a: *const App) ?workspace.Space {
    return a.findSpace(a.space) orelse if (a.spaces.items.len > 0) a.spaces.items[0] else null;
}

/// Archives a chat from its row, or brings it back.
pub fn setArchived(a: *App, chat_id: []const u8, archived: bool) void {
    a.request(requests.setChatArchived(chat_id, archived), .of(App, a, App.onNotice));
}

/// The wall clock, in milliseconds since the epoch.
pub fn nowMs(a: *const App) i64 {
    return std.Io.Clock.real.now(a.io).toMilliseconds();
}
