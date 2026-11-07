//! The app's state: the engine connection, the sidebar's spaces, chats and
//! sessions, the open chat's transcript, and the composer.
//!
//! On connect it watches what the GPUI app watches in `attach_engine`
//! (crates/ui/src/state.rs): spaces, chats and sessions, each item the whole
//! list. Opening a chat focuses it, marks it seen and watches its transcript
//! (`select_chat`). Sending mints the chat's id when it is new, creates it,
//! then queues a `run` command (`Composer::send`, crates/ui/src/composer.rs).
const std = @import("std");
const nanoui = @import("nanoui");
const rpc = @import("rpc.zig");
const engine_mod = @import("engine.zig");
const workspace = @import("workspace.zig");
const Transcript = @import("transcript.zig").Transcript;
const Tabs = @import("tabs.zig").Tabs;
const agent = @import("app_agent.zig");
const requests = @import("requests.zig");
const question = @import("app_question.zig");
const queue_mod = @import("app_queue.zig");
pub const uuid = @import("ids.zig").uuid;

/// The window's own state, apart from the engine's.
pub const View = struct {
    sidebar_open: bool = true,
    edit_selected: ?usize = null,
    edit_details: bool = false,
    /// The project filter: a space's id (owned), or all projects.
    filter: ?[]u8 = null,
    filter_menu: bool = false,
    more_menu: bool = false,
    search_open: bool = false,
    search: nanoui.ui.TextBuffer = .{},
    sessions_open: bool = true,
    archived_open: bool = true,
    /// Archived rows shown: 10, then 25 more at a time.
    archived_limit: usize = 10,
    space_menu: bool = false,
    account_menu: bool = false,
    /// Where the controls that open popovers were, as last laid out.
    filter_anchor: ?nanoui.ui.Rect = null,
    more_anchor: ?nanoui.ui.Rect = null,
    account_anchor: ?nanoui.ui.Rect = null,
    space_anchor: ?nanoui.ui.Rect = null,
    chip_anchor: ?nanoui.ui.Rect = null,
    composer_anchor: ?nanoui.ui.Rect = null,
    /// Tool groups opened or closed by hand, by "<entry>/<first part>".
    groups: std.StringHashMapUnmanaged(bool) = .empty,

    pub fn deinit(v: *View, gpa: Allocator) void {
        if (v.filter) |f| gpa.free(f);
        var it = v.groups.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        v.groups.deinit(gpa);
    }

    pub fn setFilter(v: *View, gpa: Allocator, space: ?[]const u8) void {
        if (v.filter) |f| gpa.free(f);
        v.filter = if (space) |s| gpa.dupe(u8, s) catch null else null;
        v.filter_menu = false;
    }

    /// Whether the group keyed `key` is open: as toggled, else `auto`.
    pub fn groupOpen(v: *const View, key: []const u8, auto: bool) bool {
        return v.groups.get(key) orelse auto;
    }

    pub fn toggleGroup(v: *View, gpa: Allocator, key: []const u8, auto: bool) void {
        const now = !v.groupOpen(key, auto);
        if (v.groups.getPtr(key)) |p| {
            p.* = now;
            return;
        }
        const k = gpa.dupe(u8, key) catch return;
        v.groups.put(gpa, k, now) catch gpa.free(k);
    }
};
const Allocator = std.mem.Allocator;

/// A stream the app keeps open, and when to open it again once it ended.
const Watch = struct {
    id: ?u64 = null,
    retry_at: ?f64 = null,
};

/// Seconds before a stream that ended is opened again, as the GPUI app.
const retry_s = 2.0;

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    engine: engine_mod.Engine,
    window: ?*nanoui.Window = null,
    spaces: workspace.Spaces,
    chats: workspace.Chats,
    sessions: workspace.Sessions,
    devices: workspace.Devices,
    w_devices: Watch = .{},
    w_spaces: Watch = .{},
    w_chats: Watch = .{},
    w_sessions: Watch = .{},
    w_doc: Watch = .{},
    /// The open chat (owned), and the space a new chat starts in.
    selected: ?[]u8 = null,
    space: ?[]u8 = null,
    transcript: Transcript,
    composer: nanoui.ui.TextBuffer = .{},
    /// The last error the engine gave, shown under the composer.
    notice: [200]u8 = undefined,
    notice_len: usize = 0,
    /// The view's clock, as of its last frame.
    now: f64 = 0,
    dark: ?bool = null,
    /// This engine's device: a space added here is this device's folder.
    device_id: ?[]u8 = null,
    /// The agents to pick from, and the models the picked one offers.
    harnesses: workspace.Harnesses,
    models: workspace.Models,
    /// The agent and model a new chat runs (owned); `HARNESS_NANO_HARNESS`
    /// starts with another agent (`mock` against a test engine).
    new_harness: []u8 = &.{},
    new_model: ?[]u8 = null,
    new_reasoning: ?[]u8 = null,
    /// The agent `models` lists models for (owned).
    models_for: []u8 = &.{},
    /// The model chip's picker is open.
    picker: enum { none, harness, model } = .none,
    /// The agent's pending question being answered, the draft set aside
    /// meanwhile, and the request just answered from here.
    wizard: ?@import("wizard.zig").Wizard = null,
    draft_stash: std.ArrayList(u8) = .empty,
    answered: ?[]u8 = null,
    /// The open chat's queue, what the engine can do with it, and a row
    /// being edited in the composer (or asked for).
    queue: @import("queue.zig").Rows,
    w_queue: Watch = .{},
    caps: queue_mod.Caps = .{},
    queue_edit: ?queue_mod.Edit = null,
    queue_begin: ?[]u8 = null,
    /// This window's editor id for queue edit leases.
    instance: [36]u8 = undefined,
    instance_set: bool = false,
    /// The project's actions, their editor, and the dock their runs show in.
    actions: @import("app_actions.zig").Actions,
    /// The terminal palette of the theme last drawn.
    ansi: [16]nanoui.ui.Color = @import("theme.zig").colors(true).ansi,
    /// The surface pane and the file explorer beside the chat.
    panels: @import("app_panels.zig").Panels,
    /// The open chats, one per tab.
    tabs: Tabs,
    /// What the window shows that isn't the engine's: the sidebar, its
    /// project filter and search, open sections and tool groups.
    view: View = .{},
    /// The newest Harness release, asked of GitHub over HTTP/2.
    release: @import("release.zig").Check,

    pub fn init(gpa: Allocator, io: std.Io, port: u16) App {
        return .{
            .gpa = gpa,
            .io = io,
            .engine = .init(gpa, io, port),
            .spaces = .init(gpa),
            .chats = .init(gpa),
            .sessions = .init(gpa),
            .devices = .init(gpa),
            .queue = .init(gpa),
            .panels = .init(gpa),
            .actions = .init(gpa),
            .tabs = .init(gpa),
            .transcript = .{ .gpa = gpa },
            .harnesses = .init(gpa),
            .models = .init(gpa),
            .release = .{ .gpa = gpa, .io = io },
        };
    }

    /// Starts the connection; `a` must stay where it is from now on.
    pub fn start(a: *App) !void {
        a.engine.events = .{ .ctx = a, .state = stateChanged };
        try a.engine.start();
    }

    pub fn deinit(a: *App) void {
        a.engine.deinit();
        a.spaces.deinit();
        a.chats.deinit();
        a.sessions.deinit();
        a.devices.deinit();
        a.tabs.deinit();
        a.view.deinit(a.gpa);
        question.deinit(a);
        queue_mod.deinit(a);
        a.panels.deinit();
        a.actions.deinit();
        a.transcript.deinit();
        if (a.selected) |s| a.gpa.free(s);
        if (a.space) |s| a.gpa.free(s);
        if (a.device_id) |d| a.gpa.free(d);
        if (a.new_model) |m| a.gpa.free(m);
        if (a.new_reasoning) |m| a.gpa.free(m);
        a.gpa.free(a.models_for);
        a.gpa.free(a.new_harness);
        a.harnesses.deinit();
        a.models.deinit();
    }

    pub const setHarness = agent.setHarness;
    pub const setModel = agent.setModel;
    pub const harnessName = agent.harnessName;
    pub const modelLabel = agent.modelLabel;
    pub const target = agent.target;
    pub const levelsOf = agent.levelsOf;
    pub const togglePicker = agent.togglePicker;
    pub const pickModel = agent.pickModel;
    pub const pickReasoning = agent.pickReasoning;
    pub const ensureModels = agent.ensureModels;
    pub const newChatSpace = agent.newChatSpace;
    pub const setArchived = agent.setArchived;
    pub const nowMs = agent.nowMs;
    pub const pendingInput = question.pendingInput;
    pub const wizardPick = question.pick;
    pub const wizardAdvance = question.advance;
    pub const wizardBack = question.back;
    pub const wizardDismiss = question.dismiss;
    pub const queueRemove = queue_mod.remove;
    pub const queueSendNow = queue_mod.sendNow;
    pub const queueBeginEdit = queue_mod.beginEdit;
    pub const queueFinishEdit = queue_mod.finishEdit;
    pub const queues = queue_mod.queues;

    /// This window's editor id, minted once.
    pub fn instanceId(a: *App, buf: *[36]u8) []const u8 {
        if (!a.instance_set) {
            _ = uuid(a.io, &a.instance);
            a.instance_set = true;
        }
        buf.* = a.instance;
        return buf;
    }

    /// Asks for a folder and adds it as a space on this device, as the
    /// GPUI app's "Add folder" does (`createSpace`).
    pub fn addFolder(a: *App) void {
        const device = a.device_id orelse return a.setNotice("The engine hasn't said which device it is yet.");
        const picked = nanoui.dialog.open(a.gpa, .{ .title = "Add a folder", .button = "Add", .files = false, .directories = true }) catch return;
        const paths = picked orelse return;
        defer nanoui.dialog.freePaths(a.gpa, paths);
        if (paths.len == 0) return;
        var buf: [36]u8 = undefined;
        const id = uuid(a.io, &buf);
        var git_buf: [4096]u8 = undefined;
        const git_path = std.fmt.bufPrint(&git_buf, "{s}/.git", .{paths[0]}) catch "";
        const git = std.Io.Dir.cwd().access(a.io, git_path, .{}) != error.FileNotFound;
        a.request(requests.createSpace(id, device, paths[0], git), .of(App, a, onNotice));
        a.tabs.newTab();
        a.select(null, id);
    }

    pub fn releaseCame(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.redraw();
    }

    pub fn redraw(a: *App) void {
        if (a.window) |w| w.redraw();
    }

    fn stateChanged(ctx: ?*anyopaque, s: engine_mod.State) void {
        const a: *App = @ptrCast(@alignCast(ctx.?));
        switch (s) {
            .connected => {
                a.request(requests.none("EngineInfo"), .of(App, a, onEngineInfo));
                a.request(requests.none("ListHarnesses"), .of(App, a, onHarnesses));
                a.ensureModels(a.target().harness);
                a.request(requests.none("EngineReady"), .of(App, a, onNotice));
                a.watchSidebar();
                if (a.selected != null) {
                    a.watchDoc(true);
                    queue_mod.watch(a);
                    @import("app_panels.zig").chatChanged(a);
                }
            },
            .disconnected, .connecting => {
                // Every stream ended with the socket; they open on reconnect.
                a.w_devices = .{};
                a.w_spaces = .{};
                a.w_chats = .{};
                a.w_sessions = .{};
                a.w_doc = .{};
                a.w_queue = .{};
            },
        }
        a.redraw();
    }

    /// Sends a request built in requests.zig; the call's id, for a stream.
    pub fn send_(a: *App, r: anytype, h: rpc.Handler) ?u64 {
        return a.engine.call(r.method, r.params, h);
    }

    pub fn request(a: *App, r: anytype, h: rpc.Handler) void {
        _ = a.engine.call(r.method, r.params, h);
    }

    pub fn call(a: *App, method: []const u8, params: anytype, h: rpc.Handler) void {
        _ = a.engine.call(method, params, h);
    }

    fn watchSidebar(a: *App) void {
        if (a.w_devices.id == null) a.w_devices = .{ .id = a.send_(requests.none("WatchDevices"), .of(App, a, onDevices)) };
        if (a.w_spaces.id == null) a.w_spaces = .{ .id = a.send_(requests.none("WatchSpaces"), .of(App, a, onSpaces)) };
        if (a.w_chats.id == null) a.w_chats = .{ .id = a.send_(requests.none("WatchChats"), .of(App, a, onChats)) };
        if (a.w_sessions.id == null) a.w_sessions = .{ .id = a.send_(requests.none("WatchSessions"), .of(App, a, onSessions)) };
    }

    /// Streams to open again, now that it's time; the seconds until the next.
    pub fn tick(a: *App, now: f64) ?f32 {
        a.now = now;
        question.syncWizard(a);
        var next: ?f64 = question.tick(a, now);
        if (queue_mod.tick(a, now)) |t| next = if (next) |n| @min(n, t) else t;
        if (a.w_queue.retry_at) |t| if (now >= t) {
            a.w_queue = .{};
            queue_mod.watch(a);
        };
        inline for (.{ "w_devices", "w_spaces", "w_chats", "w_sessions", "w_doc" }) |name| {
            const w = &@field(a, name);
            if (w.retry_at) |t| {
                if (now >= t) {
                    w.* = .{};
                    if (comptime std.mem.eql(u8, name, "w_doc")) a.watchDoc(false) else a.watchSidebar();
                } else next = if (next) |n| @min(n, t) else t;
            }
        }
        return if (next) |n| @floatCast(n - now) else null;
    }

    /// A stream ended or failed: try again soon, while connected.
    fn ended(a: *App, w: *Watch) void {
        w.id = null;
        if (a.engine.state == .connected) w.retry_at = a.now + retry_s;
    }

    fn onDevices(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| a.devices.replace(v) catch {},
            .done, .err => a.ended(&a.w_devices),
            .ok => {},
        }
        a.redraw();
    }

    pub fn deviceName(a: *const App, id: ?[]const u8) []const u8 {
        const want = id orelse return "Unknown device";
        for (a.devices.items) |d| if (std.mem.eql(u8, d.id, want)) return d.name;
        return "Unknown device";
    }

    /// Shows `chat_id` from the sidebar: in its tab, else the current one.
    pub fn openChat(a: *App, chat_id: []const u8, space_id: ?[]const u8) void {
        a.tabs.show(chat_id);
        a.select(chat_id, space_id);
    }

    /// "+": a new chat in a tab of its own.
    pub fn newTab(a: *App) void {
        a.tabs.newTab();
        a.select(null, null);
    }

    /// Back and forward, and the tab list's rows: show another tab.
    pub fn showTab(a: *App, i: usize) void {
        if (i >= a.tabs.items.items.len) return;
        a.tabs.active = i;
        a.select(a.tabs.current(), null);
    }

    pub fn closeTab(a: *App, i: usize) void {
        a.tabs.close(i);
        a.select(a.tabs.current(), null);
    }

    fn onSpaces(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| a.spaces.replace(v) catch {},
            .done, .err => a.ended(&a.w_spaces),
            .ok => {},
        }
        a.redraw();
    }

    fn onChats(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| {
                a.chats.replace(v) catch {};
                workspace.sortChats(a.chats.items);
                // The open chat's agent and folder are known now: list its
                // models, and fill panels that waited for them.
                a.ensureModels(a.target().harness);
                @import("app_panels.zig").chatsArrived(a);
            },
            .done, .err => a.ended(&a.w_chats),
            .ok => {},
        }
        a.redraw();
    }

    fn onSessions(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| a.sessions.replace(v) catch {},
            .done, .err => a.ended(&a.w_sessions),
            .ok => {},
        }
        a.redraw();
    }

    fn onDoc(a: *App, id: u64, r: rpc.Reply) void {
        if (a.w_doc.id != id) return;
        switch (r) {
            .item => |v| a.transcript.apply(v) catch {
                // Out of step: start over from a fresh reset.
                a.engine.cancel(id);
                a.w_doc = .{};
                a.watchDoc(false);
            },
            .done, .err => a.ended(&a.w_doc),
            .ok => {},
        }
        a.redraw();
    }

    fn onEngineInfo(a: *App, _: u64, r: rpc.Reply) void {
        const v = switch (r) {
            .ok => |v| v,
            else => return,
        };
        if (v != .object) return;
        if (v.object.get("capabilities")) |caps| if (caps == .array) {
            a.caps = queue_mod.readCaps(caps.array.items);
        };
        const id = v.object.get("deviceId") orelse return;
        if (id != .string) return;
        if (a.device_id) |d| a.gpa.free(d);
        a.device_id = a.gpa.dupe(u8, id.string) catch null;
    }

    fn onHarnesses(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .ok => |v| a.harnesses.replace(v) catch {},
            .err => |e| a.setNotice(e),
            else => {},
        }
        a.redraw();
    }

    pub fn onModels(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .ok => |v| a.models.replace(v) catch {},
            else => {},
        }
        a.redraw();
    }

    pub fn onNotice(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .err => |e| {
                if (std.mem.startsWith(u8, e, "unknown method") or std.mem.eql(u8, e, "not connected")) return;
                a.setNotice(e);
                a.redraw();
            },
            else => {},
        }
    }

    pub fn setNotice(a: *App, text: []const u8) void {
        const n = @min(text.len, a.notice.len);
        @memcpy(a.notice[0..n], text[0..n]);
        a.notice_len = n;
    }

    pub fn noticeText(a: *const App) ?[]const u8 {
        return if (a.notice_len == 0) null else a.notice[0..a.notice_len];
    }

    fn watchDoc(a: *App, opening: bool) void {
        const chat = a.selected orelse return;
        a.w_doc = .{ .id = a.send_(requests.watchDoc(chat, opening), .of(App, a, onDoc)) };
    }

    /// Opens `chat_id`, or (null) a new chat in `space_id`.
    pub fn select(a: *App, chat_id: ?[]const u8, space_id: ?[]const u8) void {
        if (a.w_doc.id) |id| a.engine.cancel(id);
        a.w_doc = .{};
        a.transcript.clear();
        a.view.edit_selected = null;
        a.view.edit_details = false;
        a.notice_len = 0;
        queue_mod.stop(a);
        if (a.selected) |s| a.gpa.free(s);
        a.selected = if (chat_id) |c| a.gpa.dupe(u8, c) catch null else null;
        if (space_id) |s| {
            if (a.space) |old| a.gpa.free(old);
            a.space = a.gpa.dupe(u8, s) catch null;
        }
        const chat = a.selected orelse return a.redraw();
        a.request(requests.focusChat(chat), .of(App, a, onNotice));
        a.request(requests.markChatSeen(chat), .of(App, a, onNotice));
        a.watchDoc(true);
        queue_mod.watch(a);
        @import("app_panels.zig").chatChanged(a);
        a.ensureModels(a.target().harness);
        a.redraw();
    }

    pub fn findChat(a: *const App, id: []const u8) ?workspace.Chat {
        for (a.chats.items) |c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    pub fn findSpace(a: *const App, id: ?[]const u8) ?workspace.Space {
        const want = id orelse return null;
        for (a.spaces.items) |s| if (std.mem.eql(u8, s.id, want)) return s;
        return null;
    }

    pub fn selectedStatus(a: *const App) workspace.Status {
        const id = a.selected orelse return .idle;
        return workspace.statusOf(a.sessions.items, id);
    }

    /// Sends what the composer holds: to the open chat, or to a new one.
    pub fn send(a: *App) void {
        if (a.queue_edit != null) return queue_mod.finishEdit(a, .commit);
        const prompt = std.mem.trim(u8, a.composer.text(), " \n\t");
        if (prompt.len == 0 or a.engine.state != .connected) return;
        if (a.queues()) {
            queue_mod.queueMessage(a, prompt);
            a.composer.clear();
            return a.redraw();
        }
        var chat_buf: [36]u8 = undefined;
        var message_buf: [36]u8 = undefined;
        const message_id = uuid(a.io, &message_buf);
        var harness: ?[]const u8 = null;
        var model: ?[]const u8 = null;
        var reasoning: ?[]const u8 = null;
        var cwd: []const u8 = "~";
        const chat_id = if (a.selected) |id| blk: {
            if (a.findChat(id)) |c| {
                harness = c.harness;
                model = c.model;
                reasoning = c.reasoning;
                if (c.cwd) |d| cwd = d;
            }
            break :blk id;
        } else blk: {
            const id = uuid(a.io, &chat_buf);
            const space = a.findSpace(a.space) orelse if (a.spaces.items.len > 0) a.spaces.items[0] else null;
            if (space) |s| cwd = s.path;
            harness = a.new_harness;
            model = a.new_model;
            reasoning = a.new_reasoning;
            a.request(requests.createChat(id, if (space) |s| s.id else null, .{
                .harness = a.new_harness,
                .model = a.new_model,
                .reasoning = a.new_reasoning,
            }), .of(App, a, onNotice));
            break :blk id;
        };
        a.request(requests.run(chat_id, message_id, .{
            .prompt = prompt,
            .harness = harness,
            .model = model,
            .reasoning = reasoning,
            .cwd = cwd,
        }), .of(App, a, onNotice));
        if (a.selected == null) {
            a.tabs.setCurrent(chat_id);
            a.select(chat_id, null);
        }
        a.composer.clear();
        a.redraw();
    }

    /// Stops the open chat's turn.
    pub fn interrupt(a: *App) void {
        const chat = a.selected orelse return;
        a.request(requests.interrupt(chat), .of(App, a, onNotice));
    }
};
