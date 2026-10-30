//! Settings › MCP servers, as the GPUI app's (settings/mcp.rs): the servers
//! graff starts for agents (`ListMcpServers`), each with its state, tool
//! count and origin; Reconnect, Sign in and the switch act through
//! `McpServerAction`, and a row opens to its tools.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Tool = struct { name: []const u8, description: []const u8 };

/// A server (`McpServerRow`).
pub const Server = struct {
    name: []const u8,
    source: []const u8 = "",
    transport: []const u8 = "",
    origin: []const u8 = "",
    enabled: bool = true,
    state: []const u8 = "",
    problem: ?[]const u8 = null,
    tool_count: usize = 0,
    tools: []Tool = &.{},
};

fn parseServer(a: Allocator, o: json.ObjectMap) ?Server {
    const str = workspace.str;
    var tools: std.ArrayList(Tool) = .empty;
    if (o.get("tools")) |t| if (t == .array) for (t.array.items) |v| if (v == .object) {
        tools.append(a, .{ .name = str(a, v.object, "name") orelse continue, .description = str(a, v.object, "description") orelse "" }) catch {};
    };
    return .{
        .name = str(a, o, "name") orelse return null,
        .source = str(a, o, "source") orelse "",
        .transport = str(a, o, "transport") orelse "",
        .origin = str(a, o, "origin") orelse "",
        .enabled = if (o.get("enabled")) |v| !(v == .bool and !v.bool) else true,
        .state = str(a, o, "state") orelse "",
        // What went wrong: its detail, else its error.
        .problem = str(a, o, "detail") orelse str(a, o, "error"),
        .tool_count = if (o.get("toolCount")) |v| (if (v == .integer and v.integer > 0) @intCast(v.integer) else 0) else 0,
        .tools = tools.items,
    };
}

pub const Servers = workspace.List(Server, parseServer);

/// The page's state, kept between visits as the GPUI app keeps its page.
pub const Mcp = struct {
    phase: enum { idle, loading, loaded, failed } = .idle,
    servers: Servers,
    failure: std.ArrayList(u8) = .empty,
    /// An action's error, over the list; cleared by a click.
    notice: std.ArrayList(u8) = .empty,
    /// The server an action is running for; "" for Check all.
    busy: ?std.ArrayList(u8) = null,
    open: std.StringHashMapUnmanaged(void) = .empty,
    /// The project (its space id) the last load was for (`McpTarget`);
    /// none for every project, as before the engine was up.
    target: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) Mcp {
        return .{ .servers = .init(gpa) };
    }

    pub fn deinit(m: *Mcp, gpa: Allocator) void {
        m.servers.deinit();
        m.failure.deinit(gpa);
        m.notice.deinit(gpa);
        if (m.busy) |*b| b.deinit(gpa);
        m.closeAll(gpa);
        m.open.deinit(gpa);
        m.target.deinit(gpa);
    }

    fn closeAll(m: *Mcp, gpa: Allocator) void {
        var it = m.open.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        m.open.clearRetainingCapacity();
    }
};

/// A state's words and its dot's colour (`McpServerState`).
pub fn stateLabel(s: []const u8) []const u8 {
    const names = .{
        .{ "ready", "Connected" },          .{ "on_demand", "Starts on first use" }, .{ "connecting", "Connecting" },
        .{ "failed", "Failed" },            .{ "needs_login", "Sign-in required" },  .{ "off", "Off" },
        .{ "opt_in", "Off (optional)" },    .{ "not_started", "Not started" },
    };
    inline for (names) |n| if (std.mem.eql(u8, s, n[0])) return n[1];
    return "Not checked yet";
}

fn stateColor(k: theme.Colors, s: []const u8) ui.Color {
    if (std.mem.eql(u8, s, "ready") or std.mem.eql(u8, s, "on_demand")) return k.success;
    if (std.mem.eql(u8, s, "failed")) return k.danger;
    if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "opt_in") or std.mem.eql(u8, s, "not_started")) return k.muted.alpha(0.4);
    return k.warning;
}

/// The project the list is for: the one picked for new chats when it was
/// loaded (`McpTarget`, `selected_space_row`); none for every project.
fn project(a: *const App) ?workspace.Space {
    return a.findSpace(if (a.mcp.target.items.len > 0) a.mcp.target.items else null);
}

/// A different project lists different servers.
fn retargeted(a: *const App) bool {
    return !std.mem.eql(u8, a.mcp.target.items, a.space orelse "");
}

fn load(a: *App) void {
    a.mcp.phase = .loading;
    // Without the engine there's no list, and the target stays as it was.
    if (a.engine.up()) {
        a.mcp.target.clearRetainingCapacity();
        a.mcp.target.appendSlice(a.gpa, a.space orelse "") catch {};
    }
    if (project(a)) |p| {
        a.call("ListMcpServers", .{ .cwd = p.path }, .of(App, a, onList));
    } else a.call("ListMcpServers", .{}, .of(App, a, onList));
}

fn onList(a: *App, _: u64, r: rpc.Reply) void {
    switch (r) {
        .ok => |v| {
            a.mcp.servers.replace(v) catch return fail(a, "Unexpected reply");
            a.mcp.phase = .loaded;
            a.mcp.closeAll(a.gpa);
        },
        .err => |e| fail(a, if (std.mem.eql(u8, e, "not connected")) "Engine not connected" else e),
        else => {},
    }
    a.redraw();
}

fn fail(a: *App, why: []const u8) void {
    a.mcp.phase = .failed;
    a.mcp.failure.clearRetainingCapacity();
    a.mcp.failure.appendSlice(a.gpa, why) catch {};
}

fn act(a: *App, action: []const u8, name: ?[]const u8) void {
    if (a.mcp.busy != null) return;
    a.mcp.notice.clearRetainingCapacity();
    var b: std.ArrayList(u8) = .empty;
    b.appendSlice(a.gpa, name orelse "") catch {};
    a.mcp.busy = b;
    if (project(a)) |p| {
        a.call("McpServerAction", .{ .action = action, .name = name, .cwd = p.path }, .of(App, a, onAction));
    } else a.call("McpServerAction", .{ .action = action, .name = name }, .of(App, a, onAction));
}

fn onAction(a: *App, _: u64, r: rpc.Reply) void {
    if (a.mcp.busy) |*b| b.deinit(a.gpa);
    a.mcp.busy = null;
    switch (r) {
        .ok => |v| merge(a, v) catch {
            a.mcp.notice.clearRetainingCapacity();
            a.mcp.notice.appendSlice(a.gpa, "Unexpected reply") catch {};
        },
        .err => |e| {
            a.mcp.notice.clearRetainingCapacity();
            a.mcp.notice.appendSlice(a.gpa, e) catch {};
        },
        else => {},
    }
    a.redraw();
}

/// The servers an action touched, in place by name; new ones after.
fn merge(a: *App, reply: json.Value) !void {
    if (a.mcp.phase != .loaded or reply != .array) return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var rows: json.Array = .init(ar);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (reply.array.items) |v| if (v == .object) if (v.object.get("name")) |n| if (n == .string) seen.put(ar, n.string, {}) catch {};
    for (a.mcp.servers.items) |s| {
        if (seen.contains(s.name)) {
            for (reply.array.items) |v| if (v == .object) if (v.object.get("name")) |n| if (n == .string and std.mem.eql(u8, n.string, s.name)) try rows.append(v);
        } else try rows.append(try asJson(ar, s));
    }
    for (reply.array.items) |v| if (v == .object) if (v.object.get("name")) |n| if (n == .string) {
        var known = false;
        for (a.mcp.servers.items) |s| known = known or std.mem.eql(u8, s.name, n.string);
        if (!known) try rows.append(v);
    };
    try a.mcp.servers.replace(.{ .array = rows });
}

fn asJson(ar: Allocator, s: Server) !json.Value {
    var o: json.ObjectMap = .empty;
    try o.put(ar, "name", .{ .string = s.name });
    try o.put(ar, "source", .{ .string = s.source });
    try o.put(ar, "transport", .{ .string = s.transport });
    try o.put(ar, "origin", .{ .string = s.origin });
    try o.put(ar, "enabled", .{ .bool = s.enabled });
    try o.put(ar, "state", .{ .string = s.state });
    if (s.problem) |p| try o.put(ar, "detail", .{ .string = p });
    try o.put(ar, "toolCount", .{ .integer = @intCast(s.tool_count) });
    var tools: json.Array = .init(ar);
    for (s.tools) |t| {
        var to: json.ObjectMap = .empty;
        try to.put(ar, "name", .{ .string = t.name });
        try to.put(ar, "description", .{ .string = t.description });
        try tools.append(.{ .object = to });
    }
    try o.put(ar, "tools", .{ .array = tools });
    return .{ .object = o };
}

const phi: f32 = 1.618;

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.mcp.phase == .idle or (a.mcp.phase != .loading and a.engine.up() and retargeted(a))) load(a);
    const m = &a.mcp;
    {
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        set.header(c, k, "MCP servers", if (m.phase == .loaded and m.servers.items.len > 0) m.servers.items.len else null);
        ui.spacer(c);
        const checking = if (m.busy) |b| b.items.len == 0 else false;
        var b = ui.div(c).row().px(11).py(7).gap(6).itemsCenter().rounded(8).border(k.border).borderW(1).hover(k.ink(0.06));
        if (checking) b = b.opacity(0.5);
        defer b.end();
        const hot = b.hovered();
        icons.icon(c, .refresh, 14, k.muted, 0);
        ui.text(c, if (checking) "Checking…" else "Check all", .{ .size = 12, .line_height = 12 * phi, .color = if (hot) k.text else k.muted });
        if (b.clicked()) act(a, "reconnect", null);
    }
    const copy = if (project(a)) |p|
        c.print("Servers graff starts for agents in {s}: this project's .mcp.json plus your user-level and imported servers. Reconnect runs a fresh handshake and refreshes the tools the next turn sees.", .{p.name})
    else
        "Servers graff starts for agents in every project: your user-level and imported servers. Pick a project to include its .mcp.json. Reconnect runs a fresh handshake and refreshes the tools the next turn sees.";
    set.subtitle(c, k, copy, false);
    if (m.notice.items.len > 0) if (errorStrip(c, k, m.notice.items)) m.notice.clearRetainingCapacity();
    switch (m.phase) {
        .idle, .loading => {
            set.space(c, 24);
            ui.text(c, "Loading MCP servers…", .{ .size = 12.5, .line_height = 12.5 * phi, .color = k.muted.alpha(0.6) });
        },
        .failed => {
            _ = errorStrip(c, k, m.failure.items);
            set.space(c, 8);
            const r = ui.div(c).row().px(10).py(6).rounded(8).hover(k.ink(0.06));
            defer r.end();
            ui.text(c, "Retry", .{ .size = 12, .line_height = 12 * phi, .color = k.muted });
            if (r.clicked()) load(a);
        },
        .loaded => if (m.servers.items.len == 0) empty(c, k) else list(c, a, k),
    }
}

/// `error_strip`: red-tinted, a warning triangle, the words. True when
/// clicked.
pub fn errorStrip(c: *ui.Context, k: theme.Colors, message: []const u8) bool {
    set.space(c, 16);
    const s = ui.div(c).row().wFull().px(17).py(13).gap(8).rounded(12).border(k.danger.alpha(0.2)).borderW(1).bg(k.danger.alpha(0.06));
    defer s.end();
    {
        const ic = ui.div(c).column().pt(2);
        defer ic.end();
        icons.icon(c, .@"danger-triangle", 16, k.danger_muted.alpha(0.9), 0);
    }
    // Wrapped text needs its width up front: the strip less its border,
    // insets, icon and gap (at zero it took a line a word).
    const w = ui.div(c).column().w(@max(set.inner_w - 2 - 2 * 17 - 16 - 8, 80));
    {
        defer w.end();
        ui.text(c, message, .{ .size = 12.5, .line_height = 12.5 * phi, .wrap = true, .color = k.danger_muted.alpha(0.9) });
    }
    return s.clicked();
}

fn empty(c: *ui.Context, k: theme.Colors) void {
    set.space(c, 96);
    const e = ui.div(c).column().wFull().itemsCenter();
    defer e.end();
    icons.icon(c, .@"remote-server", 28, k.muted.alpha(0.2), 0);
    set.space(c, 12);
    ui.text(c, "No MCP servers configured", .{ .size = 14, .line_height = 14 * phi, .color = k.muted.alpha(0.5) });
    set.space(c, 4);
    ui.text(c, "Add one with `graff mcp add`, or ask an agent to.", .{ .size = 12, .line_height = 12 * phi, .color = k.muted.alpha(0.4) });
}

fn list(c: *ui.Context, a: *App, k: theme.Colors) void {
    set.space(c, 16);
    const cd = ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell).clip();
    defer cd.end();
    for (a.mcp.servers.items, 0..) |s, ix| {
        ui.key(c, s.name);
        if (ix > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        server(c, a, k, s);
    }
}

fn server(c: *ui.Context, a: *App, k: theme.Colors, s: Server) void {
    const m = &a.mcp;
    const busy = if (m.busy) |b| (b.items.len == 0 and s.enabled) or std.mem.eql(u8, b.items, s.name) else false;
    const open = m.open.contains(s.name);
    const box = ui.div(c).column().wFull();
    defer box.end();
    const r = ui.div(c).row().wFull().px(20).py(14).gap(14).itemsCenter().hover(k.ink(0.015));
    {
        defer r.end();
        set.tile(c, k, if (std.mem.eql(u8, s.transport, "http")) .@"remote-server" else .terminal);
        // Wrapped text needs its width up front: the row less its edge,
        // insets, tile, the buttons after and the gaps (at zero, the
        // problem's line took a word a line and the row grew that tall).
        const sign_in = std.mem.eql(u8, s.state, "needs_login");
        var trailing: f32 = 14 + 40;
        if (sign_in) trailing += 14 + buttonW(c, if (busy) "Signing in…" else "Sign in");
        if (s.enabled) trailing += 14 + buttonW(c, if (busy) "Connecting…" else "Reconnect");
        const words_w = @max(set.inner_w - 2 - 2 * 20 - 36 - 14 - trailing, 80);
        const words = ui.div(c).column().w(words_w);
        {
            defer words.end();
            const t = ui.div(c).row().gap(8).itemsCenter();
            {
                defer t.end();
                ui.text(c, s.name, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
                if (s.source.len > 0) badge(c, k, s.source);
            }
            set.space(c, 1);
            const meta = ui.div(c).row().gap(8).itemsCenter();
            {
                defer meta.end();
                const st = set.st(c, 12, .{ .color = k.muted.alpha(0.65) });
                const dotrow = ui.div(c).row().gap(6).itemsCenter();
                {
                    defer dotrow.end();
                    _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = stateColor(k, s.state) }, .none, null);
                    ui.text(c, stateLabel(s.state), st);
                }
                if (s.tool_count > 0) {
                    ui.text(c, "·", set.st(c, 12, .{ .color = k.muted.alpha(0.3) }));
                    ui.text(c, c.print("{d} {s}", .{ s.tool_count, if (s.tool_count == 1) "tool" else "tools" }), st);
                }
                if (s.origin.len > 0) {
                    ui.text(c, "·", set.st(c, 12, .{ .color = k.muted.alpha(0.3) }));
                    ui.text(c, s.origin, st);
                }
            }
            if (s.problem) |p| {
                set.space(c, 4);
                ui.text(c, p, .{ .size = 12, .line_height = 12 * phi, .wrap = true, .color = k.danger_muted.alpha(0.9) });
            }
        }
        if (sign_in) {
            if (button(c, k, .@"key-minimalistic", if (busy) "Signing in…" else "Sign in", busy)) act(a, "login", s.name);
        }
        if (s.enabled) if (button(c, k, .restart, if (busy) "Connecting…" else "Reconnect", busy)) act(a, "reconnect", s.name);
        if (set.toggle(c, k, s.enabled, true)) act(a, if (s.enabled) "disable" else "enable", s.name);
    }
    if (r.clicked()) toggleOpen(a, s.name);
    if (!open) return;
    const tools = ui.div(c).column().wFull().pl(70).pr(20).pb(12).gap(4);
    defer tools.end();
    if (s.tools.len == 0) {
        ui.text(c, "No tools known yet. Reconnect lists them.", .{ .size = 12, .line_height = 12 * phi, .color = k.muted.alpha(0.6) });
        return;
    }
    for (s.tools) |t| {
        const row = ui.div(c).row().wFull().gap(8);
        defer row.end();
        ui.text(c, t.name, .{ .size = 12, .line_height = 12 * phi, .mono = true, .color = k.text });
        const d = ui.div(c).row().grow().w(0).clip();
        defer d.end();
        ui.text(c, t.description, .{ .size = 12, .line_height = 12 * phi, .color = k.muted.alpha(0.7) });
    }
}

fn toggleOpen(a: *App, name: []const u8) void {
    if (a.mcp.open.fetchRemove(name)) |kv| return a.gpa.free(kv.key);
    const k = a.gpa.dupe(u8, name) catch return;
    a.mcp.open.put(a.gpa, k, {}) catch a.gpa.free(k);
}

/// `badge`: a quiet pill.
pub fn badge(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const b = ui.div(c).row().px(9).py(3).roundedFull().border(k.border).borderW(1);
    defer b.end();
    ui.text(c, label, .{ .size = 10.5, .line_height = 10.5 * phi, .color = k.muted });
}

/// `action_button`: a bordered ghost action with its icon.
/// A `button`'s width: 11 in each side (10 and its border), the glyph, the
/// gap and the words.
fn buttonW(c: *ui.Context, label: []const u8) f32 {
    return 2 * 11 + 14 + 6 + c.text.width(label, .{ .size = 12 });
}

fn button(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8, busy: bool) bool {
    var b = ui.div(c).row().px(11).py(7).gap(6).itemsCenter().rounded(8).border(k.border).borderW(1).hover(k.ink(0.06));
    if (busy) b = b.opacity(0.5);
    defer b.end();
    icons.icon(c, icon, 14, k.muted, 0);
    ui.text(c, label, .{ .size = 12, .line_height = 12 * phi, .color = if (b.hovered()) k.text else k.muted });
    return b.clicked();
}

const testing = std.testing;

test "servers read as the engine sends them, and state names as the GPUI app's" {
    var l: Servers = .init(testing.allocator);
    defer l.deinit();
    const v = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"name":"codedb","source":"global","transport":"stdio","origin":"codedb","enabled":true,"state":"on_demand","toolCount":1,"tools":[{"name":"search","description":"Find code"}]},
        \\ {"name":"lic","state":"failed","error":"lic: not licensed","toolCount":0,"tools":[]},
        \\ {"name":"off","enabled":false,"state":"off"}]
    , .{});
    defer v.deinit();
    try l.replace(v.value);
    try testing.expectEqual(@as(usize, 3), l.items.len);
    try testing.expectEqualStrings("Starts on first use", stateLabel(l.items[0].state));
    try testing.expectEqualStrings("search", l.items[0].tools[0].name);
    try testing.expectEqualStrings("lic: not licensed", l.items[1].problem.?);
    try testing.expect(!l.items[2].enabled);
    try testing.expectEqualStrings("Not checked yet", stateLabel("whatever"));
}
