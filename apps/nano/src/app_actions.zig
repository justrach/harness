//! Project actions (crates/ui/src/shell/actions_ui.rs, project_actions.rs):
//! named commands kept per project on its device (`ListProjectActions`,
//! `UpsertProjectAction`, `DeleteProjectAction`). Running one
//! (`RunProjectAction`) starts it in a terminal in the chat's checkout; its
//! output streams into a tab of the dock under the chat
//! (`SubscribeTerminal`), and closing the tab ends it (`CloseTerminal`).
const std = @import("std");
const nanoui = @import("nanoui");
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const termlog = @import("termlog.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const icons = [_][]const u8{ "play", "test", "lint", "configure", "build", "debug" };

pub const Action = struct { id: []const u8, name: []const u8, command: []const u8, icon: []const u8, setup: bool };

pub const Status = enum { idle, loading, ready, unavailable, unsupported };

pub const Editor = struct {
    /// The action being changed (owned); null adds one.
    id: ?[]u8 = null,
    name: nanoui.ui.TextBuffer = .{},
    command: nanoui.ui.TextBuffer = .{},
    icon: usize = 0,
    setup: bool = false,
    err: ?[]const u8 = null,
    saving: bool = false,
    confirm_delete: bool = false,
    /// The name field takes the keys when the dialog opens.
    want_focus: bool = true,
};

pub const Run = struct {
    terminal: []u8,
    name: []u8,
    log: termlog.Log,
    exited: ?i64 = null,
    watch: ?u64 = null,
};

pub const Actions = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    status: Status = .idle,
    list: []Action = &.{},
    error_text: ?[]const u8 = null,
    space: ?[]u8 = null,
    menu: bool = false,
    anchor: ?nanoui.ui.Rect = null,
    editor: ?Editor = null,
    /// The last action run, by project, for the control's main button.
    last: std.StringHashMapUnmanaged([]u8) = .empty,
    runs: std.ArrayList(Run) = .empty,
    dock_open: bool = false,
    dock_active: usize = 0,

    pub fn init(gpa: Allocator) Actions {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(x: *Actions) void {
        x.arena.deinit();
        if (x.space) |s| x.gpa.free(s);
        if (x.editor) |e| if (e.id) |id| x.gpa.free(id);
        var it = x.last.iterator();
        while (it.next()) |e| {
            x.gpa.free(e.key_ptr.*);
            x.gpa.free(e.value_ptr.*);
        }
        x.last.deinit(x.gpa);
        for (x.runs.items) |*r| freeRun(x.gpa, r);
        x.runs.deinit(x.gpa);
    }
};

fn freeRun(gpa: Allocator, r: *Run) void {
    gpa.free(r.terminal);
    gpa.free(r.name);
    r.log.deinit();
}

/// The project whose actions show: the open chat's, when it lives on the
/// project's own device.
pub fn spaceOf(a: *const App) ?[]const u8 {
    const chat = a.findChat(a.selected orelse return null) orelse return null;
    const sid = chat.space_id orelse return null;
    const space = a.findSpace(sid) orelse return null;
    if (space.device_id != null and chat.device_id != null and !std.mem.eql(u8, space.device_id.?, chat.device_id.?)) return null;
    return sid;
}

fn host(a: *const App) ?[]const u8 {
    const dev = (a.findChat(a.selected orelse return null) orelse return null).device_id orelse return null;
    if (a.device_id) |mine| if (std.mem.eql(u8, mine, dev)) return null;
    return dev;
}

/// Lists the open chat's project's actions, when it changed.
pub fn refresh(a: *App) void {
    const x = &a.actions;
    const sid = spaceOf(a) orelse {
        x.status = .idle;
        return;
    };
    if (x.space) |s| if (std.mem.eql(u8, s, sid) and x.status != .idle) return;
    if (x.space) |s| x.gpa.free(s);
    x.space = x.gpa.dupe(u8, sid) catch null;
    x.status = .loading;
    a.request(requests.listActions(sid, host(a)), .of(App, a, onSnapshot));
}

fn onSnapshot(a: *App, _: u64, r: rpc.Reply) void {
    const x = &a.actions;
    switch (r) {
        .ok => |v| {
            _ = x.arena.reset(.retain_capacity);
            const ar = x.arena.allocator();
            var out: std.ArrayList(Action) = .empty;
            const list = if (v == .object) v.object.get("actions") else null;
            if (list) |l| if (l == .array) for (l.array.items) |it| if (it == .object) {
                const o = it.object;
                out.append(ar, .{
                    .id = ar.dupe(u8, str(o, "id") orelse continue) catch continue,
                    .name = ar.dupe(u8, str(o, "name") orelse "") catch continue,
                    .command = ar.dupe(u8, str(o, "command") orelse "") catch continue,
                    .icon = ar.dupe(u8, str(o, "icon") orelse "play") catch continue,
                    .setup = if (o.get("runOnWorktreeCreate")) |s| s == .bool and s.bool else false,
                }) catch {};
            };
            x.list = out.items;
            x.status = .ready;
            if (x.editor) |*e| {
                e.saving = false;
                closeEditor(a);
            }
        },
        .err => |e| {
            if (x.editor) |*ed| {
                ed.saving = false;
                ed.err = x.arena.allocator().dupe(u8, e) catch "Couldn't save the action";
                return a.redraw();
            }
            x.status = if (std.mem.indexOf(u8, e, "unknown method") != null) .unsupported else .unavailable;
            x.error_text = x.arena.allocator().dupe(u8, e) catch null;
        },
        else => {},
    }
    a.redraw();
}

/// The action the control's main button runs: the last one run here, else
/// the first that isn't a worktree's setup, else the first.
pub fn preferred(a: *const App) ?Action {
    const x = &a.actions;
    if (x.list.len == 0) return null;
    if (x.space) |s| if (x.last.get(s)) |id| for (x.list) |act| {
        if (std.mem.eql(u8, act.id, id)) return act;
    };
    for (x.list) |act| if (!act.setup) return act;
    return x.list[0];
}

pub fn openEditor(a: *App, act: ?Action) void {
    const x = &a.actions;
    x.menu = false;
    var e: Editor = .{};
    if (act) |it| {
        e.id = x.gpa.dupe(u8, it.id) catch null;
        e.name.set(it.name);
        e.command.set(it.command);
        e.setup = it.setup;
        for (icons, 0..) |n, i| if (std.mem.eql(u8, n, it.icon)) {
            e.icon = i;
        };
    }
    x.editor = e;
    a.redraw();
}

pub fn closeEditor(a: *App) void {
    const x = &a.actions;
    if (x.editor) |e| if (e.id) |id| x.gpa.free(id);
    x.editor = null;
    a.redraw();
}

/// "Save action": checked as the engine checks it first.
pub fn save(a: *App) void {
    const x = &a.actions;
    const e = if (x.editor) |*e| e else return;
    const sid = x.space orelse return;
    const name = std.mem.trim(u8, e.name.text(), " \t\n");
    const command = std.mem.trim(u8, e.command.text(), " \t\n");
    e.err = if (name.len == 0)
        "Action name is required"
    else if (name.len > 80)
        "Action name must not exceed 80 characters"
    else if (command.len == 0)
        "Action command is required"
    else
        null;
    if (e.err != null) return a.redraw();
    e.saving = true;
    a.request(requests.upsertAction(sid, e.id, .{ .name = name, .command = command, .icon = icons[e.icon], .runOnWorktreeCreate = e.setup }, host(a)), .of(App, a, onSnapshot));
}

pub fn delete(a: *App) void {
    const x = &a.actions;
    const e = if (x.editor) |*e| e else return;
    const id = e.id orelse return;
    const sid = x.space orelse return;
    e.saving = true;
    e.confirm_delete = false;
    a.request(requests.deleteAction(sid, id, host(a)), .of(App, a, onSnapshot));
}

/// Runs `act` in the chat's checkout; its output opens in the dock.
pub fn run(a: *App, act: Action) void {
    const x = &a.actions;
    x.menu = false;
    const sid = x.space orelse return;
    const chat = a.selected orelse return;
    const name = x.gpa.dupe(u8, act.name) catch return;
    x.runs.append(x.gpa, .{ .terminal = &.{}, .name = name, .log = .{ .gpa = x.gpa, .palette = a.ansi } }) catch return x.gpa.free(name);
    x.dock_active = x.runs.items.len - 1;
    x.dock_open = true;
    remember(a, sid, act.id);
    a.request(requests.runAction(sid, chat, act.id, host(a)), .of(App, a, onRun));
    a.redraw();
}

fn remember(a: *App, sid: []const u8, id: []const u8) void {
    const x = &a.actions;
    const v = x.gpa.dupe(u8, id) catch return;
    if (x.last.getPtr(sid)) |old| {
        x.gpa.free(old.*);
        old.* = v;
        return;
    }
    const k = x.gpa.dupe(u8, sid) catch return x.gpa.free(v);
    x.last.put(x.gpa, k, v) catch {
        x.gpa.free(k);
        x.gpa.free(v);
    };
}

fn onRun(a: *App, _: u64, r: rpc.Reply) void {
    const x = &a.actions;
    // The newest run without a terminal yet is this one's.
    var i = x.runs.items.len;
    const run_ = while (i > 0) {
        i -= 1;
        if (x.runs.items[i].terminal.len == 0 and x.runs.items[i].exited == null) break &x.runs.items[i];
    } else return;
    switch (r) {
        .ok => |v| {
            const term = if (v == .object) v.object.get("terminal") else null;
            const tid = if (term) |t| (if (t == .object) str(t.object, "id") else null) else null;
            run_.terminal = x.gpa.dupe(u8, tid orelse "") catch return;
            run_.watch = a.send_(requests.subscribeTerminal(run_.terminal, host(a)), .of(App, a, onOutput));
        },
        .err => |e| {
            run_.log.feed("\x1b[31mfailed to run action: ");
            run_.log.feed(e);
            run_.log.feed("\x1b[0m\n");
            run_.exited = -1;
        },
        else => {},
    }
    a.redraw();
}

fn onOutput(a: *App, id: u64, r: rpc.Reply) void {
    const x = &a.actions;
    const run_ = for (x.runs.items) |*it| {
        if (it.watch == id) break it;
    } else return;
    switch (r) {
        .item => |v| if (v == .object) {
            const o = v.object;
            const kind = str(o, "type") orelse "";
            if (std.mem.eql(u8, kind, "data")) {
                const b64 = str(o, "data") orelse "";
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(b64) catch return;
                const buf = x.gpa.alloc(u8, n) catch return;
                defer x.gpa.free(buf);
                dec.decode(buf, b64) catch return;
                run_.log.feed(buf);
            } else if (std.mem.eql(u8, kind, "exit")) {
                const code = if (o.get("exitCode")) |c| (if (c == .integer) c.integer else 0) else 0;
                run_.exited = code;
                var buf: [64]u8 = undefined;
                run_.log.feed(std.fmt.bufPrint(&buf, "\n\x1b[2m[process exited {d}]\x1b[0m\n", .{code}) catch "");
            }
        },
        .done, .err => run_.watch = null,
        .ok => {},
    }
    a.redraw();
}

/// Closes a dock tab, ending its program if it still runs.
pub fn closeRun(a: *App, i: usize) void {
    const x = &a.actions;
    if (i >= x.runs.items.len) return;
    var r = x.runs.orderedRemove(i);
    if (r.watch) |w| a.engine.cancel(w);
    if (r.exited == null and r.terminal.len > 0) a.request(requests.closeTerminal(r.terminal, host(a)), .of(App, a, App.onNotice));
    freeRun(x.gpa, &r);
    if (x.dock_active >= x.runs.items.len) x.dock_active = x.runs.items.len -| 1;
    if (x.runs.items.len == 0) x.dock_open = false;
    a.redraw();
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}
