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
const tabs_mod = @import("tabs.zig");
const Tabs = tabs_mod.Tabs;
const agent = @import("app_agent.zig");
const requests = @import("requests.zig");
const question = @import("app_question.zig");
const queue_mod = @import("app_queue.zig");
const drafts = @import("app_drafts.zig");
const account = @import("app_account.zig");
const change_requests = @import("app_change_requests.zig");
pub const uuid = @import("ids.zig").uuid;

/// The window's own state, apart from the engine's.
pub const View = struct {
    sidebar_open: bool = true,
    /// Effective slot width this frame, shared by chat, header and drop zones.
    sidebar_width: f32 = 256,
    /// Focus before a pointer press blurs a control in the sliding sidebar.
    sidebar_press_frame: u64 = 0,
    sidebar_press_focus: bool = false,
    /// The project filter: a space's id (owned), or all projects.
    filter: ?[]u8 = null,
    filter_menu: bool = false,
    more_menu: bool = false,
    /// The header's project and view menus (view_sidebar_menus.zig).
    menus: @import("view_sidebar_menus.zig").State = .{},
    /// The session search under the header (view_sidebar_search.zig).
    search: @import("view_sidebar_search.zig").State = .{},
    /// ⌘K's command palette (view_palette.zig).
    palette: @import("view_palette.zig").State = .{},
    sessions_open: bool = true,
    pinned_open: bool = true,
    /// Where the sidebar's drop places were, as last laid out: the Pinned
    /// header and rows, the Sessions header and rows.
    pin_header: ?nanoui.ui.Rect = null,
    pin_rows: ?nanoui.ui.Rect = null,
    sessions_header: ?nanoui.ui.Rect = null,
    session_rows: ?nanoui.ui.Rect = null,
    archived_open: bool = true,
    /// Archived rows shown: 10, then 25 more at a time.
    archived_limit: usize = 10,
    space_menu: bool = false,
    account_menu: bool = false,
    /// Where the controls that open popovers were, as last laid out.
    filter_anchor: ?nanoui.ui.Rect = null,
    more_anchor: ?nanoui.ui.Rect = null,
    account_anchor: ?nanoui.ui.Rect = null,
    /// The account menu's height as last drawn, to keep it in the window.
    account_h: ?f32 = null,
    /// The Settings page is open, in the sidebar's place; its search.
    settings_open: bool = false,
    settings_search: nanoui.ui.TextBuffer = .{},
    /// Settings › Shortcuts: the shortcut whose chip waits for keys, and
    /// why the last combination was refused.
    recording: ?usize = null,
    /// Settings › Appshots asked for Screen Recording or Accessibility once.
    capture_asked: bool = false,
    text_asked: bool = false,
    /// A session row being dragged toward a split target (view_drag.zig).
    drag: @import("view_drag.zig").Drag = .{},
    /// A session row's menu and the dialogs it leads to.
    chat_menu: @import("view_chat_menu.zig").Menu = .{},
    chat_menu_h: ?f32 = null,
    dialogs: @import("view_chat_menu.zig").Dialogs = .{},
    shortcut_notice: std.ArrayList(u8) = .empty,
    space_anchor: ?nanoui.ui.Rect = null,
    chip_anchor: ?nanoui.ui.Rect = null,
    model_picker: @import("model_picker.zig").State = .{},
    composer_anchor: ?nanoui.ui.Rect = null,
    /// A press in a peer, including its message/control descendants.
    pane_press: ?struct { tab: usize, pane: usize } = null,
    /// The composer takes the keys when next drawn; its field's id as last
    /// drawn, for keeping them when it moves.
    focus_composer: bool = false,
    composer_id: u64 = 0,
    /// Stable compact-capacity decision, with the GPUI composer's hysteresis.
    composer_expanded: bool = false,
    /// The composer's caret as of its last frame: where dictated words go.
    composer_caret: usize = 0,
    /// The prompt rail's hover and glide (view_rail.zig).
    rail: @import("view_rail.zig").State = .{},
    /// Tool groups opened or closed by hand, by "<entry>/<first part>".
    groups: std.StringHashMapUnmanaged(bool) = .empty,
    /// Settings › GitHub CI, kept between visits.
    github_ci: @import("view_settings_github_ci.zig").Page = .{},
    /// Settings › Agents, kept between visits.
    agents: @import("view_settings_agents.zig").Page = .{},
    /// Settings › Accounts, kept between visits.
    accounts: @import("view_settings_accounts.zig").Page = .{},
    /// Settings › Archived sessions' Unarchive and Delete all.
    archived: @import("view_settings_archived.zig").Page = .{},
    /// Settings › Devices' Rename, Remove and copied id.
    devices: @import("view_settings_devices.zig").Page = .{},
    /// Settings › Appearance's open theme menu (true: the dark one), its
    /// trigger and its height as last drawn.
    theme_menu: ?bool = null,
    theme_anchor: ?nanoui.ui.Rect = null,
    theme_menu_h: ?f32 = null,
    /// Appearance's "Add a theme" dialog, the entry "Theme mapping" shows,
    /// and what the library's last action said.
    theme_import: ?*@import("view_settings_theme_import.zig").Import = null,
    theme_review: std.ArrayList(u8) = .empty,
    theme_review_open: bool = false,
    library_error: std.ArrayList(u8) = .empty,
    /// An entry's action, and a library read the picker asked for, done at
    /// the next frame's start (`settleFrame`).
    theme_pending: ?@import("app_theme_library.zig").Pending = null,
    theme_reload: bool = false,
    /// Boxes hovered as GPUI's `hover_listener` hovers them (kit.listenerHover).
    hovers: std.AutoHashMapUnmanaged(u64, bool) = .empty,

    pub fn deinit(v: *View, gpa: Allocator) void {
        v.github_ci.deinit(gpa);
        v.palette.deinit(gpa);
        v.model_picker.deinit(gpa);
        v.agents.deinit(gpa);
        v.accounts.deinit(gpa);
        v.archived.deinit(gpa);
        v.devices.deinit(gpa);
        v.hovers.deinit(gpa);
        v.theme_review.deinit(gpa);
        v.library_error.deinit(gpa);
        if (v.theme_import) |d| {
            d.arena.deinit();
            d.err.deinit(gpa);
            gpa.destroy(d);
        }
        v.shortcut_notice.deinit(gpa);
        v.drag.deinit(gpa);
        v.chat_menu.id.deinit(gpa);
        v.dialogs.deinit(gpa);
        v.menus.deinit(gpa);
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

/// A split pane's chat other than the focused one: its own transcript,
/// watched while it shows (the GPUI app's `peer_chat_views`).
pub const Peer = struct {
    id: []u8,
    transcript: Transcript,
    watch: ?u64 = null,
    /// Retry an ended stream after the same delay as the focused one.
    retry_at: ?f64 = null,
};

/// A stream the app keeps open, and when to open it again once it ended.
const Watch = struct {
    id: ?u64 = null,
    retry_at: ?f64 = null,
};

/// Seconds before a stream that ended is opened again, as the GPUI app.
const retry_s = 2.0;

/// App-owned rather than part-owned: transcript updates can replace parts
/// while a full-output request is in flight. The callback context stays put.
const ToolBlob = struct {
    app: *App,
    ref: []u8,
    status: enum { loading, ready, failed } = .loading,
    text: []u8 = &.{},

    fn onReply(b: *ToolBlob, _: u64, reply: rpc.Reply) void {
        b.status = .failed;
        switch (reply) {
            .ok => |v| {
                if (v == .object) if (v.object.get("text")) |text| {
                    if (text == .string) {
                        const copy = b.app.gpa.dupe(u8, text.string) catch {
                            b.app.redraw();
                            return;
                        };
                        b.app.gpa.free(b.text);
                        b.text = copy;
                        b.status = .ready;
                    }
                };
            },
            else => {},
        }
        b.app.redraw();
    }
};

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
    /// UI-only feedback until the engine echoes a locally submitted message.
    pending_sends: std.ArrayList(*@import("app_send_feedback.zig").Pending) = .empty,
    /// Full tool output, keyed by its owned sidecar reference.
    tool_blobs: std.StringHashMapUnmanaged(*ToolBlob) = .empty,
    /// What `select` let go of: the frame that let go may have drawn it
    /// already, and lays it out after. Freed at the next frame's start
    /// (`reap`).
    retired: std.ArrayList(Transcript) = .empty,
    retired_ids: std.ArrayList([]u8) = .empty,
    /// The process's environment (main's), for what's started from here.
    env: ?*const std.process.Environ.Map = null,
    /// Drawn offscreen (a scene): no main run loop to post to.
    offscreen: bool = false,
    /// Dictation through the device's Codex voice.
    dictation: @import("app_dictation.zig").State = .{},
    composer: nanoui.ui.TextBuffer = .{},
    /// ↑/↓ through the open chat's earlier prompts.
    prompt_nav: @import("prompt_history.zig").Nav = .{},
    attachments: @import("app_attachments.zig").State = .{},
    /// The last error the engine gave, shown under the composer.
    notice: [200]u8 = undefined,
    notice_len: usize = 0,
    /// The view's clock, as of its last frame.
    now: f64 = 0,
    dark: ?bool = null,
    glass: @import("app_surface.zig").State = .{},
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
    ansi: [16]nanoui.ui.Color = @import("theme.zig").builtin(true).ansi,
    /// The surface pane and the file explorer beside the chat.
    panels: @import("app_panels.zig").Panels,
    /// The open chats, one per tab, and their split panes.
    tabs: Tabs,
    /// The active tab's other panes' chats, each watched.
    peers: std.ArrayList(Peer) = .empty,
    /// A split's divider being dragged.
    pane_drag: ?tabs_mod.Drag = null,
    /// Each chat's unsent prompt by its id, and "" the new chat's while a
    /// chat shows (app_drafts.zig).
    drafts: std.StringHashMapUnmanaged([]u8) = .empty,
    /// The settings shared with the GPUI app (`ui-settings.json`).
    settings: @import("settings.zig").Store,
    /// Settings › MCP servers, kept between visits.
    mcp: @import("view_settings_mcp.zig").Mcp,
    /// The workspace's scope, the Harness account and the Codegraff
    /// sign-in, for the account badge's menu (app_account.zig).
    account: account.Account = .{},
    /// The account's Codegraff cloud sandboxes (app_sandboxes.zig).
    cloud_sandboxes: @import("app_sandboxes.zig").State = .{},
    /// What the window shows that isn't the engine's: the sidebar, its
    /// project filter and search, open sections and tool groups.
    view: View = .{},
    /// The newest Harness release, asked of GitHub over HTTP/2.
    release: @import("release.zig").Check,
    /// Failed runs' in-chat ChatGPT reconnects (app_reauth.zig).
    reauth: @import("app_reauth.zig").State,
    /// The session footer's Graff worktree action and verdict
    /// (app_graff_worktree.zig).
    graff_worktree: @import("app_graff_worktree.zig").State = .{},
    /// Each active chat's branch's pull request, watched, and the session
    /// footer's merge (app_change_requests.zig).
    change_requests: change_requests.State,

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
            .settings = .{ .gpa = gpa, .io = io },
            .mcp = .init(gpa),
            .transcript = .{ .gpa = gpa },
            .harnesses = .init(gpa),
            .models = .init(gpa),
            .release = .{ .gpa = gpa, .io = io },
            .reauth = .init(gpa),
            .change_requests = .init(gpa),
        };
    }

    /// Starts the connection; `a` must stay where it is from now on.
    pub fn start(a: *App) !void {
        a.engine.events = .{ .ctx = a, .state = stateChanged };
        try a.engine.start();
    }

    pub fn deinit(a: *App) void {
        @import("app_surface.zig").deinit(a);
        a.engine.deinit();
        a.attachments.deinit(a.gpa);
        @import("app_send_feedback.zig").deinit(a);
        var blobs = a.tool_blobs.valueIterator();
        while (blobs.next()) |value| {
            const b = value.*;
            a.gpa.free(b.ref);
            a.gpa.free(b.text);
            a.gpa.destroy(b);
        }
        a.tool_blobs.deinit(a.gpa);
        a.spaces.deinit();
        a.chats.deinit();
        a.sessions.deinit();
        a.devices.deinit();
        a.tabs.deinit();
        for (a.peers.items) |*p| {
            p.transcript.deinit();
            a.gpa.free(p.id);
        }
        a.peers.deinit(a.gpa);
        drafts.deinit(a);
        a.prompt_nav.reset(a.gpa);
        a.account.deinit(a.gpa);
        a.cloud_sandboxes.deinit();
        a.settings.deinit();
        a.mcp.deinit(a.gpa);
        a.view.deinit(a.gpa);
        question.deinit(a);
        queue_mod.deinit(a);
        a.panels.deinit();
        a.actions.deinit();
        a.transcript.deinit();
        a.reap();
        a.dictation.deinit(a.gpa);
        a.retired.deinit(a.gpa);
        a.retired_ids.deinit(a.gpa);
        if (a.selected) |s| a.gpa.free(s);
        if (a.space) |s| a.gpa.free(s);
        if (a.device_id) |d| a.gpa.free(d);
        if (a.new_model) |m| a.gpa.free(m);
        if (a.new_reasoning) |m| a.gpa.free(m);
        a.gpa.free(a.models_for);
        a.gpa.free(a.new_harness);
        a.harnesses.deinit();
        a.models.deinit();
        a.reauth.deinit();
        a.graff_worktree.deinit(a.gpa);
        a.change_requests.deinit();
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
        a.newTab();
        a.select(null, id);
    }

    pub fn releaseCame(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.redraw();
    }

    pub fn redraw(a: *App) void {
        if (a.window) |w| w.redraw();
    }

    /// The agents and the new chat's agent's models, for the composer.
    pub fn loadAgents(a: *App) void {
        a.request(requests.none("ListHarnesses"), .of(App, a, onHarnesses));
        a.ensureModels(a.target().harness);
    }

    fn stateChanged(ctx: ?*anyopaque, s: engine_mod.State) void {
        const a: *App = @ptrCast(@alignCast(ctx.?));
        switch (s) {
            .connected => {
                a.request(requests.none("EngineInfo"), .of(App, a, onEngineInfo));
                a.loadAgents();
                a.request(requests.none("EngineReady"), .of(App, a, onNotice));
                a.watchSidebar();
                change_requests.reconcile(a);
                account.watch(a);
                // A cloud sandbox left running keeps costing credit: show it
                // from the start.
                @import("app_sandboxes.zig").refresh(a);
                if (a.selected != null) {
                    a.watchDoc(true);
                    queue_mod.watch(a);
                    @import("app_panels.zig").chatChanged(a);
                }
            },
            .disconnected, .connecting => {
                for (a.peers.items) |*p| p.* = .{ .id = p.id, .transcript = p.transcript };
                a.account.w_auth = null;
                // Every stream ended with the socket; they open on reconnect.
                a.w_devices = .{};
                a.w_spaces = .{};
                a.w_chats = .{};
                a.w_sessions = .{};
                a.w_doc = .{};
                a.w_queue = .{};
                change_requests.disconnected(a);
            },
        }
        a.redraw();
    }

    /// Sends a request built in requests.zig; the call's id, for a stream.
    pub fn send_(a: *App, r: anytype, h: rpc.Handler) ?u64 {
        return a.engine.call(r.method, r.params, h);
    }

    /// One request per reference; failures may be retried explicitly.
    pub fn fetchToolBlob(a: *App, ref: []const u8) void {
        if (ref.len == 0) return;
        const b = a.tool_blobs.get(ref) orelse blk: {
            const owned_ref = a.gpa.dupe(u8, ref) catch return;
            const blob = a.gpa.create(ToolBlob) catch {
                a.gpa.free(owned_ref);
                return;
            };
            blob.* = .{ .app = a, .ref = owned_ref, .status = .failed };
            a.tool_blobs.put(a.gpa, owned_ref, blob) catch {
                a.gpa.free(owned_ref);
                a.gpa.destroy(blob);
                return;
            };
            break :blk blob;
        };
        if (b.status != .failed) return;
        b.status = .loading;
        if (a.send_(requests.fetchToolBlob(b.ref), .of(ToolBlob, b, ToolBlob.onReply)) == null) b.status = .failed;
        a.redraw();
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
        // A scene's answers, a frame after their calls.
        if (a.engine.pump()) a.redraw();
        question.syncWizard(a);
        var next: ?f64 = question.tick(a, now);
        if (queue_mod.tick(a, now)) |t| next = if (next) |n| @min(n, t) else t;
        if (account.tick(a, now)) |t| next = if (next) |n| @min(n, t) else t;
        if (@import("app_reauth.zig").tick(a, now)) |t| next = if (next) |n| @min(n, t) else t;
        if (@import("app_sandboxes.zig").tick(a, now)) |t| next = if (next) |n| @min(n, t) else t;
        if (change_requests.tick(a, now)) |t| next = if (next) |n| @min(n, t) else t;
        if (@import("app_subagents.zig").tick(a, now)) |t| next = if (next) |n| @min(n, t) else t;
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
        for (a.peers.items) |*p| if (p.retry_at) |t| {
            if (now >= t) {
                p.retry_at = null;
                if (a.engine.state == .connected) a.watchPeer(p);
            } else next = if (next) |n| @min(n, t) else t;
        };
        return if (next) |n| @floatCast(n - now) else null;
    }

    /// A stream ended or failed: try again soon, while connected.
    fn ended(a: *App, w: *Watch) void {
        w.id = null;
        if (a.engine.state == .connected) w.retry_at = a.now + retry_s;
    }

    fn onDevices(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| {
                a.devices.replace(v) catch {};
                change_requests.devicesArrived(a);
            },
            .done, .err => a.ended(&a.w_devices),
            .ok => {},
        }
        a.redraw();
    }

    /// The sessions in the sidebar's order (Settings' `sidebarSort`).
    pub fn resort(a: *App) void {
        workspace.sortChatsBy(a.chats.items, a.settings.sort() == .created);
    }

    /// The sidebar's project filter, kept in the settings as the GPUI app
    /// keeps it; with no session open, the new one goes there too.
    pub fn setSpaceFilter(a: *App, id: ?[]const u8) void {
        a.view.setFilter(a.gpa, id);
        a.settings.setSpaceFilter(id);
        if (id) |s| if (a.selected == null) a.select(null, s);
        a.redraw();
    }

    pub fn deviceName(a: *const App, id: ?[]const u8) []const u8 {
        const want = id orelse return "Unknown device";
        for (a.devices.items) |d| if (std.mem.eql(u8, d.id, want)) return d.name;
        return "Unknown device";
    }

    /// Shows `chat_id` from the sidebar: in its tab, else the current one.
    pub fn openChat(a: *App, chat_id: []const u8, space_id: ?[]const u8) void {
        if (a.tabs.find(chat_id)) |at| {
            if (at.tab != a.tabs.active) a.showTab(at.tab);
            if (at.pane) |ix| a.focusPane(ix);
            return;
        }
        a.tabs.setCurrent(chat_id);
        a.select(chat_id, space_id);
    }

    /// Shows `chat_id` keeping the tabs as they are, as the command palette
    /// and the session search do (`open_chat_in_tab`): the open chat stays
    /// (the composer takes the keys), a chat in another pane or tab is shown
    /// there, and any other gets a new tab of its own at the end.
    pub fn openChatInTab(a: *App, chat_id: []const u8) void {
        if (a.findChat(chat_id) == null) return;
        a.view.settings_open = false;
        if (a.selected) |s| if (std.mem.eql(u8, s, chat_id)) {
            a.view.focus_composer = true;
            return a.redraw();
        };
        if (a.tabs.find(chat_id)) |at| {
            if (at.tab != a.tabs.active) a.showTab(at.tab);
            if (at.pane) |ix| a.focusPane(ix);
            return;
        }
        a.park();
        a.tabs.appendTab();
        a.tabs.setCurrent(chat_id);
        a.select(chat_id, null);
    }

    /// `/resume`'s choice: `chat_id` in the current tab (or pane), wherever
    /// else it's open (`open_chat`).
    pub fn replaceCurrent(a: *App, chat_id: ?[]const u8) void {
        a.view.settings_open = false;
        a.tabs.setCurrent(chat_id);
        a.select(chat_id, null);
    }

    /// The active tab's new-chat draft, parked with it.
    fn park(a: *App) void {
        const d = drafts.canvas(a) catch return;
        a.tabs.park(a.tabs.active, null, d);
    }

    /// "+", ⌘T: a new chat in a tab of its own, with the picks of the one
    /// left and an empty prompt.
    pub fn newTab(a: *App) void {
        var d = drafts.canvas(a) catch return;
        const fresh = d.fresh(a.gpa) catch return d.deinit(a.gpa);
        a.tabs.park(a.tabs.active, null, d);
        a.tabs.newTab();
        a.select(null, null);
        drafts.adopt(a, fresh);
    }

    /// Back and forward, and the tab list's rows: show another tab, its
    /// draft back as it was left (`load_chat_tab`).
    pub fn showTab(a: *App, i: usize) void {
        if (i >= a.tabs.items.items.len or i == a.tabs.active) return;
        a.park();
        a.tabs.active = i;
        a.select(a.tabs.current(), null);
        if (a.tabs.unpark(i, null)) |d| drafts.adopt(a, d);
    }

    pub fn closeTab(a: *App, i: usize) void {
        // Another tab: the one shown stays as it is.
        if (i != a.tabs.active) return a.tabs.close(i);
        a.tabs.close(i);
        a.select(a.tabs.current(), null);
        if (a.tabs.unpark(a.tabs.active, null)) |d| drafts.adopt(a, d);
    }

    /// ⌘D, ⌘⇧D: the focused pane split, focus in the new pane: a new chat
    /// with the picks of the pane left and an empty prompt (`split_chat`).
    pub fn splitPane(a: *App, axis: tabs_mod.Axis) void {
        var d = drafts.canvas(a) catch return;
        var fresh = d.fresh(a.gpa) catch return d.deinit(a.gpa);
        if (!(a.tabs.split(axis) catch false)) {
            d.deinit(a.gpa);
            return fresh.deinit(a.gpa);
        }
        a.tabs.park(a.tabs.active, a.tabs.layout().?.focus - 1, d);
        a.select(null, null);
        drafts.adopt(a, fresh);
    }

    /// A session dropped on a split target: the focused pane split along
    /// `axis`, `chat_id` opened in the new pane. Dragging the chat already
    /// open moves it; the pane it leaves is a new chat (`split_chat_opening`).
    pub fn splitOpening(a: *App, axis: tabs_mod.Axis, chat_id: []const u8) void {
        if (a.findChat(chat_id) == null or !a.tabs.canSplit(axis)) return;
        var d = drafts.canvas(a) catch return;
        if (!(a.tabs.split(axis) catch false)) return d.deinit(a.gpa);
        a.tabs.park(a.tabs.active, a.tabs.layout().?.focus - 1, d);
        a.tabs.detach(chat_id);
        a.tabs.setCurrent(chat_id);
        a.select(chat_id, null);
    }

    /// Focus pane `ix`: the pane left keeps its draft, and `ix`'s comes
    /// back (`select_chat_pane`).
    pub fn focusPane(a: *App, ix: usize) void {
        const s = a.tabs.layout() orelse return;
        if (ix >= s.panes.items.len or ix == s.focus) return;
        const from = s.focus;
        const d = drafts.canvas(a) catch return;
        a.tabs.focusPane(ix);
        a.tabs.park(a.tabs.active, from, d);
        const back = a.tabs.unpark(a.tabs.active, ix);
        a.select(a.tabs.current(), null);
        if (back) |b| {
            var x = b;
            if (a.selected == null) drafts.adopt(a, b) else x.deinit(a.gpa);
        }
    }

    /// ⌘] / ⌘[: the next pane in a split, else the next tab.
    pub fn stepPane(a: *App, forward: bool) void {
        if (a.tabs.layout()) |s| return a.focusPane(s.cycled(forward));
        const by: i32 = if (forward) 1 else -1;
        if (a.tabs.canStep(by)) a.showTab(@intCast(@as(i64, @intCast(a.tabs.active)) + by));
    }

    /// ⌥⌘+arrow: the pane that way.
    pub fn focusToward(a: *App, d: tabs_mod.Direction) void {
        const s = a.tabs.layout() orelse return;
        if (s.toward(d)) |ix| a.focusPane(ix);
    }

    /// ⌘W: the focused pane in a split, the next one's draft back; else
    /// the tab.
    pub fn closeFocused(a: *App) void {
        if (!a.tabs.closePane()) return a.closeTab(a.tabs.active);
        const back = a.tabs.unpark(a.tabs.active, if (a.tabs.layout()) |s| s.focus else null);
        a.select(a.tabs.current(), null);
        if (back) |b| {
            var x = b;
            if (a.selected == null) drafts.adopt(a, b) else x.deinit(a.gpa);
        }
    }

    /// Watches the transcript of every chat in the active tab's other
    /// panes, and lets go of those no longer shown.
    pub fn syncPeers(a: *App) void {
        var wanted: [tabs_mod.max_panes]?[]const u8 = @splat(null);
        if (a.tabs.layout()) |s| if (!s.zoomed) for (s.panes.items, 0..) |p, ix| {
            if (ix != s.focus) wanted[ix] = p;
        };
        const live = a.engine.state == .connected;
        var i: usize = 0;
        while (i < a.peers.items.len) {
            const p = &a.peers.items[i];
            const keep = for (wanted) |w| {
                if (w) |x| if (std.mem.eql(u8, x, p.id)) break true;
            } else false;
            if (keep) {
                if (p.watch == null and p.retry_at == null and live) a.watchPeer(p);
                i += 1;
                continue;
            }
            if (p.watch) |w| a.engine.cancel(w);
            p.transcript.deinit();
            a.gpa.free(p.id);
            _ = a.peers.swapRemove(i);
        }
        for (wanted) |w| if (w) |id| if (a.peer(id) == null) {
            const owned = a.gpa.dupe(u8, id) catch return;
            a.peers.append(a.gpa, .{ .id = owned, .transcript = .{ .gpa = a.gpa } }) catch return a.gpa.free(owned);
            if (live) a.watchPeer(&a.peers.items[a.peers.items.len - 1]);
        };
    }

    pub fn peer(a: *App, id: []const u8) ?*Peer {
        for (a.peers.items) |*p| if (std.mem.eql(u8, p.id, id)) return p;
        return null;
    }

    fn watchPeer(a: *App, p: *Peer) void {
        p.watch = a.send_(requests.watchDoc(p.id, true), .of(App, a, onPeerDoc));
    }

    fn onPeerDoc(a: *App, id: u64, r: rpc.Reply) void {
        // A focus change moves the subscription with its transcript.
        if (a.w_doc.id == id) return onDoc(a, id, r);
        for (a.peers.items) |*p| if (p.watch == id) {
            switch (r) {
                .item => |v| p.transcript.apply(v) catch {
                    // Watch afresh, keeping the last verified rows until
                    // its authoritative reset arrives.
                    a.engine.cancel(id);
                    p.watch = null;
                },
                .done, .err => {
                    p.watch = null;
                    p.retry_at = if (a.engine.state == .connected) a.now + retry_s else null;
                },
                .ok => {},
            }
            break;
        };
        a.redraw();
    }

    fn onSpaces(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| {
                a.spaces.replace(v) catch {};
                change_requests.reconcile(a);
            },
            .done, .err => a.ended(&a.w_spaces),
            .ok => {},
        }
        a.redraw();
    }

    fn onChats(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| {
                a.chats.replace(v) catch {};
                a.resort();
                // The open chat's agent and folder are known now: list its
                // models, and fill panels that waited for them.
                a.ensureModels(a.target().harness);
                @import("app_panels.zig").chatsArrived(a);
                change_requests.reconcile(a);
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
        if (a.w_doc.id != id) return onPeerDoc(a, id, r);
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
        a.account.scope = account.readScope(v.object);
        if (v.object.get("capabilities")) |caps| if (caps == .array) {
            a.caps = queue_mod.readCaps(caps.array.items);
        };
        const id = v.object.get("deviceId") orelse return;
        if (id != .string) return;
        if (a.device_id) |d| a.gpa.free(d);
        a.device_id = a.gpa.dupe(u8, id.string) catch null;
        // Watches opened before routed through `targetDeviceId`.
        change_requests.restart(a);
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
        drafts.leave(a);
        defer drafts.enter(a);
        a.view.focus_composer = true;
        @import("app_panes.zig").select(a, chat_id);
        a.notice_len = 0;
        queue_mod.stop(a);
        if (a.selected) |s| a.retired_ids.append(a.gpa, s) catch a.gpa.free(s);
        a.selected = if (chat_id) |c| a.gpa.dupe(u8, c) catch null else null;
        if (space_id) |s| {
            if (a.space) |old| a.gpa.free(old);
            a.space = a.gpa.dupe(u8, s) catch null;
        }
        const chat = a.selected orelse return a.redraw();
        a.request(requests.focusChat(chat), .of(App, a, onNotice));
        a.markSeen(chat);
        if (a.w_doc.id == null and a.w_doc.retry_at == null) a.watchDoc(true);
        queue_mod.watch(a);
        @import("app_panels.zig").chatChanged(a);
        a.ensureModels(a.target().harness);
        a.redraw();
    }

    /// Opened, a chat is seen (`mark_chat_seen`): here at once, its
    /// Done giving way to its time, then on the host; only when unseen.
    /// At a frame's start, before anything is drawn: what `select` let go
    /// of, freed.
    pub fn reap(a: *App) void {
        @import("app_attachments.zig").reap(a);
        @import("app_send_feedback.zig").reap(a);
        for (a.retired.items) |*t| t.deinit();
        a.retired.clearRetainingCapacity();
        for (a.retired_ids.items) |s| a.gpa.free(s);
        a.retired_ids.clearRetainingCapacity();
    }

    pub fn markSeen(a: *App, id: []const u8) void {
        for (a.chats.items) |*ch| if (std.mem.eql(u8, ch.id, id)) {
            if (!workspace.unseen(ch.*)) return;
            ch.last_seen_ms = a.nowMs();
            a.request(requests.markChatSeen(id), .of(App, a, onNotice));
            return;
        };
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
        if (@import("app_send_feedback.zig").active(a, id, &a.transcript) != null) return .working;
        return workspace.statusOf(a.sessions.items, id);
    }

    /// Sends what the composer holds: to the open chat, or to a new one.
    pub fn send(a: *App) void {
        if (a.queue_edit != null) return queue_mod.finishEdit(a, .commit);
        const attachments = @import("app_attachments.zig");
        const text = std.mem.trim(u8, a.composer.text(), " \n\t");
        const attached = attachments.prompt(a, text) catch {
            a.setNotice("Wait for the attachments to finish, or remove/retry the failed file.");
            return a.redraw();
        };
        defer if (attached) |p| a.gpa.free(p);
        const prompt = attached orelse text;
        // `/resume` is the workspace's, not the agent's: the palette that
        // puts a chat in this tab (`WorkspaceCommand::Resume`).
        if (std.mem.eql(u8, prompt, "/resume")) {
            a.composer.clear();
            return @import("view_palette.zig").toggle(a, .replace_current);
        }
        if (prompt.len == 0 or a.engine.state != .connected) return;
        if (a.queues()) {
            queue_mod.queueMessage(a, prompt);
            attachments.clear(a);
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
        const feedback = @import("app_send_feedback.zig");
        const pending = feedback.begin(a, chat_id, message_id, prompt) catch {
            a.setNotice("Couldn't prepare the message. Please try again.");
            return a.redraw();
        };
        a.request(requests.run(chat_id, message_id, .{
            .prompt = prompt,
            .harness = harness,
            .model = model,
            .reasoning = reasoning,
            .cwd = cwd,
        }), .of(feedback.Pending, pending, feedback.Pending.onReply));
        // Sent: the prompt is no one's draft any more.
        attachments.clear(a);
        a.composer.clear();
        if (a.selected == null) {
            a.tabs.setCurrent(chat_id);
            a.select(chat_id, null);
        }
        a.redraw();
    }

    /// Stops the open chat's turn.
    pub fn interrupt(a: *App) void {
        const chat = a.selected orelse return;
        a.request(requests.interrupt(chat), .of(App, a, onNotice));
    }
};
