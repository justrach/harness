//! Model rows and maker marks follow crates/ui/src/pickers.rs and the
//! two-step picker in pickers/model_preview.rs: models grouped by the route
//! they're served through, a detail card that states only what the catalog
//! says, then a reasoning slider. Catalogs retain their agent identity,
//! including replies arriving after a tab switch.
const std = @import("std");
const ui = @import("nanoui").ui;
const workspace = @import("workspace.zig");
const icons = @import("icons.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Favorite = struct { harness: []const u8, model: []const u8 };
pub const Row = struct {
    harness: []const u8,
    model: workspace.Model,
    /// A section's heading: the provider's name, its route's mark.
    header: ?[]const u8 = null,
};

/// The model staged for its reasoning (`Pending`): the second step.
pub const Stage = struct {
    harness: []u8,
    model: []u8,
    /// Index into the model's levels; null for the model's default.
    level: ?usize = null,
    error_text: ?[]const u8 = null,
};

pub const Catalog = struct {
    app: *App,
    harness: []u8,
    models: workspace.Models,
    loaded: bool = false,
    loading: bool = false,

    fn reply(cat: *Catalog, _: u64, r: @import("rpc.zig").Reply) void {
        cat.loading = false;
        switch (r) {
            .ok => |v| {
                cat.models.replace(v) catch return;
                cat.loaded = true;
                if (std.mem.eql(u8, cat.app.models_for, cat.harness)) copyModels(&cat.app.models, cat.models.items) catch {};
            },
            else => {},
        }
        cat.app.redraw();
    }
};

pub const State = struct {
    query: ui.TextBuffer = .{},
    starred: bool = false,
    focus: bool = false,
    active: usize = 0,
    reveal: bool = false,
    scroll_id: u64 = 0,
    tab_offset: f32 = 0,
    height: f32 = 337,
    visible: bool = false,
    closing_since: ?f64 = null,
    anchor: ?ui.Rect = null,
    favorites: std.ArrayList(Favorite) = .empty,
    loaded_favorites: bool = false,
    catalogs: std.StringHashMapUnmanaged(*Catalog) = .empty,
    /// A click is applied before the next frame, never freeing text that
    /// the current frame's composer or rows still borrow.
    pending: ?struct { harness: ?[]u8 = null, model: ?[]u8 = null, reasoning: ?[]u8 = null } = null,
    /// The second step, once a model is clicked.
    stage: ?Stage = null,
    /// The row whose detail card shows, and when the pointer reached the
    /// row it's waiting on (180 ms, 60 once a card is showing).
    detail: ?usize = null,
    hover_target: ?usize = null,
    hover_since: f64 = 0,
    detail_rect: ?ui.Rect = null,
    /// The slider's track as last laid out, and a drag on it.
    track: ?ui.Rect = null,
    dragging: bool = false,

    pub fn clearStage(s: *State, gpa: Allocator) void {
        if (s.stage) |st| {
            gpa.free(st.harness);
            gpa.free(st.model);
        }
        s.stage = null;
        s.dragging = false;
    }

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (s.favorites.items) |f| {
            gpa.free(f.harness);
            gpa.free(f.model);
        }
        s.favorites.deinit(gpa);
        var it = s.catalogs.valueIterator();
        while (it.next()) |item| {
            const cat = item.*;
            cat.models.deinit();
            gpa.free(cat.harness);
            gpa.destroy(cat);
        }
        s.catalogs.deinit(gpa);
        s.clearStage(gpa);
        if (s.pending) |p| {
            if (p.harness) |v| gpa.free(v);
            if (p.model) |v| gpa.free(v);
            if (p.reasoning) |v| gpa.free(v);
        }
    }

    pub fn favorite(s: *const State, harness: []const u8, model: []const u8) bool {
        for (s.favorites.items) |f| if (std.mem.eql(u8, f.harness, harness) and std.mem.eql(u8, f.model, model)) return true;
        return false;
    }

    pub fn toggleFavorite(s: *State, gpa: Allocator, harness: []const u8, model: []const u8) void {
        for (s.favorites.items, 0..) |f, i| {
            if (!std.mem.eql(u8, f.harness, harness) or !std.mem.eql(u8, f.model, model)) continue;
            gpa.free(f.harness);
            gpa.free(f.model);
            _ = s.favorites.orderedRemove(i);
            return;
        }
        const h = gpa.dupe(u8, harness) catch return;
        const m = gpa.dupe(u8, model) catch {
            gpa.free(h);
            return;
        };
        s.favorites.append(gpa, .{ .harness = h, .model = m }) catch {
            gpa.free(h);
            gpa.free(m);
        };
    }
};

pub fn copyModels(to: *workspace.Models, models: []const workspace.Model) !void {
    var next: std.heap.ArenaAllocator = .init(to.arena.child_allocator);
    errdefer next.deinit();
    const gpa = next.allocator();
    const out = try gpa.alloc(workspace.Model, models.len);
    for (models, out) |m, *n| {
        n.* = m;
        n.id = try gpa.dupe(u8, m.id);
        n.label = try gpa.dupe(u8, m.label);
        n.description = if (m.description) |v| try gpa.dupe(u8, v) else null;
        n.maker = if (m.maker) |v| try gpa.dupe(u8, v) else null;
        n.billing = if (m.billing) |v| try gpa.dupe(u8, v) else null;
        n.reasoning_default = if (m.reasoning_default) |v| try gpa.dupe(u8, v) else null;
        const levels = try gpa.alloc([]const u8, m.levels.len);
        for (m.levels, levels) |v, *l| l.* = try gpa.dupe(u8, v);
        n.levels = levels;
    }
    to.arena.deinit();
    to.arena = next;
    to.items = out;
}

pub fn ensureCatalog(a: *App, harness: []const u8, refresh: bool) ?*Catalog {
    const p = &a.view.model_picker;
    const cat = p.catalogs.get(harness) orelse blk: {
        const cat = a.gpa.create(Catalog) catch return null;
        const id = a.gpa.dupe(u8, harness) catch {
            a.gpa.destroy(cat);
            return null;
        };
        cat.* = .{ .app = a, .harness = id, .models = .init(a.gpa) };
        p.catalogs.put(a.gpa, id, cat) catch {
            a.gpa.free(id);
            a.gpa.destroy(cat);
            return null;
        };
        break :blk cat;
    };
    if (!cat.loading and (!cat.loaded or refresh) and a.engine.up()) {
        cat.loading = true;
        a.request(@import("requests.zig").listModels(harness), .of(Catalog, cat, Catalog.reply));
    }
    return cat;
}

pub fn modelsFor(a: *const App, harness: []const u8) []const workspace.Model {
    if (std.mem.eql(u8, a.models_for, harness) or std.mem.eql(u8, a.target().harness, harness)) return a.models.items;
    const cat = a.view.model_picker.catalogs.get(harness) orelse return &.{};
    return cat.models.items;
}

pub fn provider(id: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return "";
    return id[0..slash];
}

pub fn maker(m: workspace.Model) ?[]const u8 {
    if (m.maker) |v| if (v.len > 0) return v;
    const name = m.id[(std.mem.lastIndexOfScalar(u8, m.id, '/') orelse 0)..];
    const clean = std.mem.trimStart(u8, name, "/");
    const pairs = .{ .{ "claude", "anthropic" }, .{ "gpt", "openai" }, .{ "codex", "openai" }, .{ "o3", "openai" }, .{ "o4", "openai" }, .{ "grok", "xai" }, .{ "gemini", "google" }, .{ "gemma", "google" }, .{ "deepseek", "deepseek" }, .{ "mimo", "xiaomi" }, .{ "kimi", "moonshot" }, .{ "k2", "moonshot" }, .{ "k3", "moonshot" }, .{ "glm", "zai" }, .{ "qwen", "alibaba" }, .{ "minimax", "minimax" }, .{ "mistral", "mistral" }, .{ "codestral", "mistral" }, .{ "devstral", "mistral" }, .{ "muse-spark", "meta" }, .{ "llama", "meta" } };
    inline for (pairs) |pair| if (std.ascii.startsWithIgnoreCase(clean, pair[0])) return pair[1];
    const p = provider(m.id);
    if (std.mem.eql(u8, p, "codex")) return "openai";
    if (std.mem.eql(u8, p, "kimi") or std.mem.eql(u8, p, "moonshot")) return "moonshot";
    for ([_][]const u8{ "anthropic", "openai", "xai", "google", "deepseek", "xiaomi", "zai", "alibaba", "minimax", "mistral", "meta" }) |lab| if (std.mem.eql(u8, p, lab)) return lab;
    return null;
}

pub fn makerIcon(m: workspace.Model) ?icons.Name {
    const lab = maker(m) orelse return null;
    const pairs = .{ .{ "anthropic", icons.Name.@"claude-mark" }, .{ "openai", icons.Name.@"openai-mark" }, .{ "xai", icons.Name.@"grok-mark" }, .{ "google", icons.Name.@"maker-gemini" }, .{ "deepseek", icons.Name.@"maker-deepseek" }, .{ "xiaomi", icons.Name.@"maker-mimo" }, .{ "moonshot", icons.Name.@"maker-kimi" }, .{ "zai", icons.Name.@"maker-zai" }, .{ "alibaba", icons.Name.@"maker-qwen" }, .{ "minimax", icons.Name.@"maker-minimax" }, .{ "mistral", icons.Name.@"maker-mistral" }, .{ "meta", icons.Name.@"maker-meta" } };
    inline for (pairs) |pair| if (std.mem.eql(u8, lab, pair[0])) return pair[1];
    return null;
}

fn contains(text: []const u8, query: []const u8) bool {
    if (query.len > text.len) return false;
    for (0..text.len - query.len + 1) |i| if (std.ascii.eqlIgnoreCase(text[i..][0..query.len], query)) return true;
    return false;
}

pub fn searchRank(query: []const u8, m: workspace.Model) ?u8 {
    if (query.len == 0 or std.ascii.startsWithIgnoreCase(m.label, query)) return 0;
    if (contains(m.label, query)) return 1;
    if (contains(m.id, query) or contains(m.description orelse "", query)) return 2;
    return null;
}

/// The route a model is served through: its id's prefix (`claude-agent/…`),
/// else its maker (`route`).
pub fn route(m: workspace.Model) []const u8 {
    if (std.mem.indexOfScalar(u8, m.id, '/')) |slash| return m.id[0..slash];
    return maker(m) orelse "other";
}

/// Registry presentation only (model_preview.rs `PROVIDERS`): a route's
/// name and mark. Never used to filter a live catalog.
pub fn providerInfo(id: []const u8) struct { name: []const u8, icon: icons.Name } {
    const P = struct { []const u8, []const u8, icons.Name };
    const table = [_]P{
        .{ "anthropic", "Anthropic", .@"claude-mark" },       .{ "codegraff", "Codegraff", .@"graff-mark" },
        .{ "deepseek", "DeepSeek", .@"maker-deepseek" },      .{ "openai", "OpenAI", .@"openai-mark" },
        .{ "google", "Google", .@"maker-gemini" },            .{ "minimax", "MiniMax", .@"maker-minimax" },
        .{ "xiaomi", "Xiaomi", .@"maker-mimo" },              .{ "kilo", "Kilo Gateway", .globe },
        .{ "groq", "Groq", .globe },                          .{ "cerebras", "Cerebras", .globe },
        .{ "mistral", "Mistral", .@"maker-mistral" },         .{ "kimi", "Kimi", .@"maker-kimi" },
        .{ "moonshot", "Moonshot", .@"maker-kimi" },          .{ "xai", "xAI", .@"grok-mark" },
        .{ "zai", "Z.ai", .@"maker-zai" },                    .{ "meta", "Meta", .@"maker-meta" },
        .{ "vercel", "Vercel AI Gateway", .globe },           .{ "openrouter", "OpenRouter", .globe },
        .{ "fugu", "Sakana", .globe },                        .{ "fireworks", "Fireworks", .globe },
        .{ "mlx", "MLX", .globe },                            .{ "lmstudio", "LM Studio", .globe },
        .{ "omlx", "oMLX", .globe },                          .{ "chatgpt-new", "ChatGPT plan", .@"openai-mark" },
        .{ "codex", "Codex / ChatGPT", .@"openai-mark" },      .{ "claude-agent", "Claude Agent", .@"claude-mark" },
    };
    for (table) |p| if (std.mem.eql(u8, p[0], id)) return .{ .name = p[1], .icon = p[2] };
    return .{ .name = id, .icon = .globe };
}

/// The model's mark: its maker's, else its route's (`model_icon`).
pub fn modelIcon(m: workspace.Model) icons.Name {
    return makerIcon(m) orelse providerInfo(route(m)).icon;
}

/// The reasoning slider's colour (`brand_accent`): the maker's (or the
/// route's) sourced accent, else its agent's; null for the theme's text.
pub fn brandHex(m: workspace.Model, harness: []const u8, dark: bool) ?u24 {
    const key = maker(m) orelse route(m);
    const Pair = struct { []const u8, u24, u24 };
    const table = [_]Pair{
        .{ "openai", 0x66b5ff, 0x66b5ff },   .{ "codex", 0x66b5ff, 0x66b5ff },     .{ "chatgpt-new", 0x66b5ff, 0x66b5ff },
        .{ "anthropic", 0xd97757, 0xd97757 }, .{ "moonshot", 0x00a1ff, 0x007cff }, .{ "kimi", 0x00a1ff, 0x007cff },
        .{ "deepseek", 0x3964fe, 0x3964fe }, .{ "google", 0x3186ff, 0x3186ff },   .{ "minimax", 0x1887fb, 0x1887fb },
        .{ "xiaomi", 0xff6900, 0xff6900 },   .{ "mistral", 0xff5229, 0xff5229 },  .{ "codegraff", 0x0285ff, 0x0285ff },
        .{ "groq", 0xf43e01, 0xf43e01 },     .{ "cerebras", 0xf15a27, 0xf15a27 }, .{ "kilo", 0xffdd00, 0xffdd00 },
        .{ "openrouter", 0x6467f2, 0x6467f2 }, .{ "fugu", 0xe10600, 0xe10600 },   .{ "fireworks", 0xffc0e7, 0x7a155c },
        .{ "lmstudio", 0x7b74db, 0x4338ca }, .{ "xai", 0xffffff, 0x000000 },      .{ "zai", 0xb4b4b4, 0x4d4d4d },
    };
    for (table) |p| if (std.mem.eql(u8, p[0], key)) return if (dark) p[1] else p[2];
    for ([_][]const u8{ "vercel", "mlx", "omlx" }) |mono| if (std.mem.eql(u8, mono, key)) return null;
    if (std.mem.eql(u8, harness, "graff")) return 0x0285ff;
    if (std.mem.eql(u8, harness, "claude-code")) return 0xd97757;
    if (std.mem.eql(u8, harness, "codex")) return 0x66b5ff;
    return null;
}

/// Off and High only: a switch, "Thinking" Off/On (`binary_reasoning_switch`).
pub fn binary(levels: []const []const u8) bool {
    if (levels.len != 2) return false;
    var off = false;
    var high = false;
    for (levels) |l| {
        off = off or std.mem.eql(u8, l, "none");
        high = high or std.mem.eql(u8, l, "high");
    }
    return off and high;
}

pub fn levelLabel(level: []const u8, is_binary: bool) []const u8 {
    if (is_binary and std.mem.eql(u8, level, "high")) return "On";
    return @import("rules.zig").reasoningLabel(level);
}

/// "Low – High": the levels the catalog lists (`reasoning_range`).
pub fn reasoningRange(buf: []u8, levels: []const []const u8) ?[]const u8 {
    if (levels.len == 0) return null;
    const rules = @import("rules.zig");
    const first = rules.reasoningLabel(levels[0]);
    const last = rules.reasoningLabel(levels[levels.len - 1]);
    if (std.mem.eql(u8, first, last)) return first;
    return std.fmt.bufPrint(buf, "{s} – {s}", .{ first, last }) catch null;
}

/// The catalog's billing tag, in words (`billing_label`).
pub fn billingLabel(billing: []const u8) []const u8 {
    const pairs = .{ .{ "plan", "Your plan" }, .{ "credits", "Credits" }, .{ "api", "API usage" }, .{ "local", "Runs locally" } };
    inline for (pairs) |p| if (std.mem.eql(u8, billing, p[0])) return p[1];
    return billing;
}

/// "1M", "200k", "1.05M" (`harness_proto::context_label`).
pub fn contextLabel(buf: []u8, tokens: u64) []const u8 {
    if (tokens >= 1 << 10 and std.math.isPowerOfTwo(tokens)) {
        return (if (tokens >= 1 << 20) std.fmt.bufPrint(buf, "{d}M", .{tokens >> 20}) else std.fmt.bufPrint(buf, "{d}k", .{tokens >> 10})) catch "";
    }
    if (tokens < 1_000) return std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "";
    const thousands = (tokens + 500) / 1_000;
    if (thousands < 1_000) return std.fmt.bufPrint(buf, "{d}k", .{thousands}) catch "";
    const hundredths = (tokens + 5_000) / 10_000;
    const whole = hundredths / 100;
    const frac = hundredths % 100;
    if (frac == 0) return std.fmt.bufPrint(buf, "{d}M", .{whole}) catch "";
    if (frac % 10 == 0) return std.fmt.bufPrint(buf, "{d}.{d}M", .{ whole, frac / 10 }) catch "";
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}M", .{ whole, frac }) catch "";
}

/// The picker's rows (`preview_rows`): the starred models across agents;
/// a search's matches, flat; else the agent's models in one headed
/// section per route, in first-appearance order except that Claude
/// Agent's leads Anthropic's (`route_sections`).
pub fn rows(a: *const App, gpa: Allocator) ![]Row {
    const p = &a.view.model_picker;
    const harness = a.target().harness;
    const query = std.mem.trim(u8, p.query.text(), " \t\r\n");
    var out: std.ArrayList(Row) = .empty;
    if (@import("app_agent.zig").chatMode(a)) {
        // A plain chat offers the three Auto tiers and nothing else.
        const chat_mode = @import("chat_mode.zig");
        var buf: [chat_mode.tiers.len]workspace.Model = undefined;
        for (chat_mode.models(&buf, modelsFor(a, chat_mode.harness))) |m| {
            if (query.len > 0 and searchRank(query, m) == null) continue;
            try out.append(gpa, .{ .harness = chat_mode.harness, .model = m });
        }
        return out.toOwnedSlice(gpa);
    }
    if (p.starred) {
        for (p.favorites.items) |f| {
            if (a.selected != null and !std.mem.eql(u8, f.harness, harness)) continue;
            for (modelsFor(a, f.harness)) |m| if (std.mem.eql(u8, m.id, f.model) and searchRank(query, m) != null) {
                try out.append(gpa, .{ .harness = f.harness, .model = m });
            };
        }
        return out.toOwnedSlice(gpa);
    }
    const models = a.models.items;
    if (query.len > 0) {
        for (0..3) |rank| for (models) |m| {
            if (searchRank(query, m)) |r| if (r == rank) try out.append(gpa, .{ .harness = harness, .model = m });
        };
        return out.toOwnedSlice(gpa);
    }
    var routes: std.ArrayList([]const u8) = .empty;
    for (models) |m| {
        const id = route(m);
        for (routes.items) |have| {
            if (std.mem.eql(u8, have, id)) break;
        } else try routes.append(gpa, id);
    }
    claudeAgentFirst(routes.items);
    for (routes.items) |id| {
        var first = true;
        for (models) |m| if (std.mem.eql(u8, route(m), id)) {
            if (first) try out.append(gpa, .{ .harness = harness, .model = m, .header = providerInfo(id).name });
            first = false;
            try out.append(gpa, .{ .harness = harness, .model = m });
        };
    }
    return out.toOwnedSlice(gpa);
}

/// Claude Agent's section ahead of Anthropic's, wherever each first came.
fn claudeAgentFirst(routes: [][]const u8) void {
    var agent: ?usize = null;
    var anthropic: ?usize = null;
    for (routes, 0..) |r, i| {
        if (std.mem.eql(u8, r, "claude-agent")) agent = i;
        if (std.mem.eql(u8, r, "anthropic")) anthropic = i;
    }
    const from = agent orelse return;
    const to = anthropic orelse return;
    if (from < to) return;
    const moving = routes[from];
    std.mem.copyBackwards([]const u8, routes[to + 1 .. from + 1], routes[to..from]);
    routes[to] = moving;
}

const testing = std.testing;

test "Claude Agent's section leads Anthropic's (claude_agent_models_get_their_own_section_ahead_of_anthropic)" {
    var r = [_][]const u8{ "openai", "anthropic", "xai", "claude-agent" };
    claudeAgentFirst(&r);
    try testing.expectEqualStrings("claude-agent", r[1]);
    try testing.expectEqualStrings("anthropic", r[2]);
    try testing.expectEqualStrings("xai", r[3]);
    try testing.expectEqualStrings("Claude Agent", providerInfo("claude-agent").name);
    try testing.expectEqualStrings("unknown-route", providerInfo("unknown-route").name);
}

test "the detail card states only what the catalog says (the_detail_card_states_only_what_the_catalog_says)" {
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("Low – High", reasoningRange(&b, &.{ "low", "medium", "high" }).?);
    try testing.expectEqualStrings("High", reasoningRange(&b, &.{"high"}).?);
    try testing.expect(reasoningRange(&b, &.{}) == null);
    try testing.expectEqualStrings("Your plan", billingLabel("plan"));
    try testing.expectEqualStrings("odd", billingLabel("odd"));
    try testing.expectEqualStrings("1M", contextLabel(&b, 1 << 20));
    try testing.expectEqualStrings("200k", contextLabel(&b, 200_000));
    try testing.expectEqualStrings("1.05M", contextLabel(&b, 1_050_000));
    try testing.expectEqualStrings("1.5M", contextLabel(&b, 1_500_000));
}

test "every slider has a colour and Grok and Z.ai differ (every_slider_has_a_color_and_grok_and_zai_differ)" {
    const grok: workspace.Model = .{ .id = "xai/grok-4", .label = "Grok" };
    const glm: workspace.Model = .{ .id = "zai/glm-5", .label = "GLM" };
    try testing.expect(brandHex(grok, "graff", true).? != brandHex(glm, "graff", true).?);
    const odd: workspace.Model = .{ .id = "nobody/thing", .label = "Thing" };
    try testing.expectEqual(@as(?u24, 0x0285ff), brandHex(odd, "graff", true));
    try testing.expectEqual(@as(?u24, 0xd97757), brandHex(odd, "claude-code", false));
    try testing.expect(binary(&.{ "none", "high" }));
    try testing.expect(!binary(&.{ "low", "high" }));
    try testing.expectEqualStrings("On", levelLabel("high", true));
}
