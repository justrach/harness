//! Model rows and maker marks follow crates/ui/src/pickers.rs. Catalogs
//! retain their agent identity, including replies arriving after a tab switch.
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
    header: ?[]const u8 = null,
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
    reasoning_open: bool = false,
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

pub fn providerName(id: []const u8) []const u8 {
    const pairs = .{ .{ "anthropic", "Anthropic" }, .{ "cerebras", "Cerebras" }, .{ "codegraff", "Codegraff" }, .{ "codex", "Codex" }, .{ "deepseek", "DeepSeek" }, .{ "fugu", "Fugu" }, .{ "kimi", "Kimi" }, .{ "lmstudio", "LM Studio" }, .{ "mlx", "MLX" }, .{ "openai", "OpenAI" }, .{ "openrouter", "OpenRouter" }, .{ "xai", "xAI" }, .{ "xiaomi", "Xiaomi" }, .{ "", "Other" } };
    inline for (pairs) |pair| if (std.mem.eql(u8, pair[0], id)) return pair[1];
    return id;
}

pub fn billingRank(billing: ?[]const u8) u8 {
    const b = billing orelse return 2;
    if (std.mem.eql(u8, b, "plan")) return 0;
    if (std.mem.eql(u8, b, "local")) return 1;
    if (std.mem.eql(u8, b, "api")) return 3;
    return 2;
}

pub fn billingNote(billing: ?[]const u8) ?[]const u8 {
    const b = billing orelse return null;
    const pairs = .{ .{ "plan", "your plan" }, .{ "local", "local" }, .{ "credits", "credits" }, .{ "api", "your key" } };
    inline for (pairs) |pair| if (std.mem.eql(u8, b, pair[0])) return pair[1];
    return null;
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

pub fn rows(a: *const App, gpa: Allocator) ![]Row {
    const p = &a.view.model_picker;
    const harness = a.target().harness;
    const query = std.mem.trim(u8, p.query.text(), " \t\r\n");
    var out: std.ArrayList(Row) = .empty;
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
        for (0..3) |rank| for ([_]bool{ true, false }) |starred| for (models) |m| {
            if (p.favorite(harness, m.id) != starred) continue;
            if (searchRank(query, m)) |r| if (r == rank) try out.append(gpa, .{ .harness = harness, .model = m });
        };
        return out.toOwnedSlice(gpa);
    }
    var groups: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (models, 0..) |m, i| if (!p.favorite(harness, m.id)) {
        const result = try groups.getOrPut(gpa, provider(m.id));
        if (!result.found_existing) result.value_ptr.* = i;
    };
    var starred_head = false;
    for (models) |m| if (p.favorite(harness, m.id)) {
        if (!starred_head and groups.count() > 1) try out.append(gpa, .{ .harness = harness, .model = m, .header = "Starred" });
        starred_head = true;
        try out.append(gpa, .{ .harness = harness, .model = m });
    };
    for (0..4) |rank| for (groups.keys(), groups.values()) |provider_id, first| {
        if (billingRank(models[first].billing) != rank) continue;
        if (groups.count() > 1) {
            const name = providerName(provider_id);
            const title = if (billingNote(models[first].billing)) |note| try std.fmt.allocPrint(gpa, "{s} · {s}", .{ name, note }) else name;
            try out.append(gpa, .{ .harness = harness, .model = models[first], .header = title });
        }
        for (models) |m| if (!p.favorite(harness, m.id) and std.mem.eql(u8, provider(m.id), provider_id)) {
            var shown = m;
            if (groups.count() > 1) if (m.description) |d| if (std.mem.startsWith(u8, d, provider_id) and provider_id.len > 0) {
                const rest = d[provider_id.len..];
                shown.description = if (rest.len == 0) null else if (std.mem.startsWith(u8, rest, " · ")) rest[" · ".len..] else d;
            };
            try out.append(gpa, .{ .harness = harness, .model = shown });
        };
    };
    return out.toOwnedSlice(gpa);
}
