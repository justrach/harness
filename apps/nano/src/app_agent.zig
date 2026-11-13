//! What the next message runs on: the agent, model and reasoning level a
//! new chat starts with, or the open chat's own (its config row, replaced
//! whole by `SetChatConfig` when picked, as the GPUI pickers do), and the
//! models the engine lists for that agent.
const std = @import("std");
const rules = @import("rules.zig");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const workspace = @import("workspace.zig");
const composer_defaults = @import("composer_defaults.zig");
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
    // A plain chat runs on graff's tiers, starting on the first on offer;
    // never the catalog's default model (`selected_model`).
    if (chatMode(a)) {
        t.harness = chat_mode.harness;
        if (t.model == null or !chat_mode.offers(t.model.?)) t.model = chat_mode.defaultId(graffCatalog(a));
    }
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
    // Chat mode names its tiers itself (`selected_model_label`).
    if (chatMode(a)) {
        if (id) |x| if (chat_mode.labelFor(x)) |l| return l;
        if (chatAvailability(a) == .unavailable) return chat_mode.unavailable_chip;
    }
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
    a.retireSlice(a.models_for);
    a.models_for = copy;
    picker.copyModels(&a.models, cat.models.items) catch {};
}

pub fn togglePicker(a: *App) void {
    a.picker = if (a.picker == .none) .model else .none;
    if (a.picker != .none) @import("view_picker.zig").opened(a);
    a.redraw();
}

pub fn togglePickerCompact(a: *App) void {
    a.picker = if (a.picker == .none) .model else .none;
    if (a.picker != .none) @import("view_picker.zig").openedCompact(a);
    a.redraw();
}

/// The agent a new chat starts with.
pub fn setHarness(a: *App, id: []const u8) void {
    const copy = a.gpa.dupe(u8, id) catch return;
    a.retireSlice(a.new_harness);
    a.new_harness = copy;
    setNew(a, &a.new_model, null);
    setNew(a, &a.new_reasoning, null);
    // GPUI's effective picks fall back to the sticky per-agent model and
    // the last reasoning level after an agent switch.
    if (!a.new_chat_mode) composer_defaults.adopt(a, id);
    if (a.selected == null and !a.new_chat_mode) composer_defaults.rememberHarness(a);
    ensureModels(a, id);
    a.redraw();
}

/// The model a new chat starts with; null is the agent's default.
pub fn setModel(a: *App, id: ?[]const u8) void {
    setNew(a, &a.new_model, id);
    a.picker = .none;
    if (a.selected == null) composer_defaults.rememberModel(a);
    a.redraw();
}

fn setNew(a: *App, field: *?[]u8, value: ?[]const u8) void {
    if (field.*) |old| a.retireSlice(old);
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
        composer_defaults.rememberReasoning(a);
        return a.redraw();
    }
    setChatConfig(a, null, level, false);
}

/// The model page commits model and level together. Sending two
/// SetChatConfig calls raced: the level call still named the old model and
/// could turn a just-picked Max back into that model's default.
pub fn pickModelAndReasoning(a: *App, id: []const u8, level: []const u8) void {
    a.picker = .none;
    if (a.selected == null) {
        setNew(a, &a.new_model, id);
        setNew(a, &a.new_reasoning, level);
        composer_defaults.rememberModel(a);
        composer_defaults.rememberReasoning(a);
        a.ensureModels(a.target().harness);
        a.view.focus_composer = true;
        return a.redraw();
    }
    storeChatConfig(a, id, level);
}

/// Applies model and reasoning changes live from the compact thinking tier
/// panel without closing the popover (`compact.rs` `pick_compact_effort`).
pub fn applyLiveModelAndReasoning(a: *App, id: []const u8, level: ?[]const u8) void {
    if (a.selected == null) {
        setNew(a, &a.new_model, id);
        setNew(a, &a.new_reasoning, level);
        composer_defaults.rememberModel(a);
        if (level != null) composer_defaults.rememberReasoning(a);
        a.ensureModels(a.target().harness);
        return a.redraw();
    }
    storeChatConfigLive(a, id, level, false);
}

/// Replaces the open chat's config: its agent stays, the model or the
/// level changes (a new model takes its own default level).
fn setChatConfig(a: *App, model: ?[]const u8, reasoning: ?[]const u8, new_model: bool) void {
    a.picker = .none;
    const id = a.selected orelse return;
    const ch = a.findChat(id) orelse return;
    storeChatConfig(a, if (new_model) model else ch.model, if (new_model) null else reasoning orelse ch.reasoning);
}

/// One request carries both values, and the local row changes now instead
/// of waiting for the next WatchChats item.
fn storeChatConfig(a: *App, model: ?[]const u8, reasoning: ?[]const u8) void {
    storeChatConfigLive(a, model, reasoning, true);
}

fn storeChatConfigLive(a: *App, model: ?[]const u8, reasoning: ?[]const u8, focus_composer: bool) void {
    const id = a.selected orelse return;
    const ch = a.findChat(id) orelse return;
    const sent = a.send_(requests.setChatConfig(id, .{
        .harness = ch.harness orelse "graff",
        .model = model,
        .reasoning = reasoning,
        // The config is replaced whole: a plain chat stays one.
        .chatMode = if (ch.chat_mode) true else null,
    }), .of(App, a, App.onNotice));
    if (sent == null) return a.setNotice("The config change couldn't be sent. Reconnect and try again.");
    _ = @import("workspace.zig").setChatConfig(&a.chats, id, model, reasoning);
    if (focus_composer) a.view.focus_composer = true;
    a.redraw();
}

/// The project a new chat starts in: the one picked, else the first;
/// plain chats and explicitly projectless drafts have none.
pub fn newChatSpace(a: *const App) ?workspace.Space {
    if (a.selected == null) {
        if (a.new_chat_mode or a.new_no_project) return null;
        // An explicit project can arrive before its metadata. Keep its
        // identity rather than silently running in another folder.
        if (a.space != null and a.findSpace(a.space) == null) return null;
        if (a.new_device) |device| {
            if (a.findSpace(a.space)) |space| if (std.mem.eql(u8, space.device_id orelse a.device_id orelse "", device)) return space;
            for (a.spaces.items) |space| if (std.mem.eql(u8, space.device_id orelse a.device_id orelse "", device)) return space;
            return null;
        }
    }
    return a.findSpace(a.space) orelse if (a.spaces.items.len > 0) a.spaces.items[0] else null;
}

const chat_mode = @import("chat_mode.zig");

/// Whether the open chat, else the new one, is a plain chat.
pub fn chatMode(a: *const App) bool {
    if (a.selected) |id| return if (a.findChat(id)) |ch| ch.chat_mode else false;
    return a.new_chat_mode;
}

fn graffCatalog(a: *const App) []const workspace.Model {
    return @import("model_picker.zig").modelsFor(a, chat_mode.harness);
}

/// `chat_mode_availability`: graff installed, its catalog listing a tier.
pub fn chatAvailability(a: *const App) chat_mode.Availability {
    const installed: ?bool = if (a.harnesses.items.len == 0) null else for (a.harnesses.items) |h| {
        if (std.mem.eql(u8, h.id, chat_mode.harness)) break h.installed;
    } else false;
    const loaded = if (a.view.model_picker.catalogs.get(chat_mode.harness)) |cat| !cat.loading else false;
    // With the agents' list failed nothing has asked for graff's catalog
    // (`effective_harness` is none): pending, not unavailable.
    const list_failed = a.harnesses.items.len == 0 and a.harnesses_failed;
    return chat_mode.availability(installed, graffCatalog(a), !list_failed and (loaded or std.mem.eql(u8, a.models_for, chat_mode.harness)) and a.models.items.len > 0);
}

/// The composer's note in a plain chat: why it can't run, else the tier's
/// (`chat_mode_note`).
pub fn chatNote(a: *const App) ?[]const u8 {
    if (!chatMode(a)) return null;
    if (chatAvailability(a) == .unavailable) return chat_mode.unavailable_note;
    return chat_mode.noteFor(target(a).model);
}

/// Switches the new chat between a plain chat and a coding session
/// (`set_chat_mode`): a chat drops its project and starts on Auto (low);
/// either way the picks start over. With no tier on offer it stays a
/// coding session and asks graff's catalog again.
pub fn setChatMode(a: *App, on: bool) void {
    if (a.selected != null or a.new_chat_mode == on) return;
    if (on and chatAvailability(a) == .unavailable) {
        _ = @import("model_picker.zig").ensureCatalog(a, chat_mode.harness, true);
        return a.redraw();
    }
    a.new_chat_mode = on;
    setHarness(a, chat_mode.harness);
}

/// A plain-chat draft with no tier to run on holds its send
/// (`chat_mode_send_blocked`).
pub fn chatSendBlocked(a: *const App) bool {
    if (a.selected != null or !a.new_chat_mode) return false;
    return target(a).model == null;
}

/// Archives a chat from its row, or brings it back.
pub fn setArchived(a: *App, chat_id: []const u8, archived: bool) void {
    a.request(requests.setChatArchived(chat_id, archived), .of(App, a, App.onNotice));
}

/// The wall clock, in milliseconds since the epoch.
pub fn nowMs(a: *const App) i64 {
    return std.Io.Clock.real.now(a.io).toMilliseconds();
}
