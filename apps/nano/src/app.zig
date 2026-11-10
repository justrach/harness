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

/// The sidebar seam's own tween. Keeping its start/end here means a resize
/// or a reversed Cmd+B cannot restart it from a stale motion-store sample.
pub const SidebarTween = struct {
    from: f32,
    to: f32,
    started: ?f64 = null,
};

/// A split's insertion tween. The old pane widths are captured before the
/// split, so the new pane grows into place while its neighbors give way.
pub const SplitReveal = struct {
    tab: usize,
    new_index: usize,
    old_count: usize,
    from_shares: [tabs_mod.max_panes]f32 = @splat(0),
    started: ?f64 = null,
};

/// The window's own state, apart from the engine's.
pub const View = struct {
    sidebar_open: bool = true,
    /// A prompt was just sent: the open chat's transcript goes to its end
    /// and follows the reply again, however far up it was read.
    stick_end: bool = false,
    /// The jump pill is up. It stays until the reader is near the end.
    jump_shown: bool = false,
    jump_box: u64 = 0,
    jump_distance: f32 = 0,
    /// The scroll box already pulled back from a blank offset.
    blank_recovered: u64 = 0,
    /// Effective slot width this frame, shared by chat, header and drop zones.
    sidebar_width: f32 = 256,
    /// The seam's current 200ms tween, and whether the first frame has
    /// adopted the saved width instead of animating from the default.
    sidebar_tween: ?SidebarTween = null,
    sidebar_ready: bool = false,
    /// Actual workspace content bounds, shared by strip and transcript layout.
    chrome: @import("panel_chrome.zig").Frame = .{},
    strip: @import("view_tab_strip.zig").State = .{},
    tool_ui: @import("tool_ui_state.zig").State = .{},
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
    /// Name-first New project form and internal folder navigator.
    project_setup: @import("app_project_setup.zig").State = .{},
    /// Shared computer-and-folder start sheet for tabs, splits and projects.
    open_chooser: @import("app_open_chooser.zig").State = .{},
    /// The split last made, while its new pane grows into place.
    split_reveal: ?SplitReveal = null,
    /// The new chat's checkout menu (`PickerKind::Checkout`) and its chip.
    checkout_menu: bool = false,
    checkout_anchor: ?nanoui.ui.Rect = null,
    /// The new chat's git ref menu (`PickerKind::Branch`) and its chip.
    ref_menu: bool = false,
    ref_anchor: ?nanoui.ui.Rect = null,
    ref_loading: bool = false,
    ref_space: ?[]u8 = null,
    refs: std.ArrayList([]u8) = .empty,
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
    settings_search_focus: bool = false,
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
    /// The context ring's hover card (view_context.zig).
    context: @import("view_context.zig").State = .{},
    composer_anchor: ?nanoui.ui.Rect = null,
    /// A press in a peer, including its message/control descendants.
    pane_press: ?struct { tab: usize, pane: usize } = null,
    /// The composer takes the keys when next drawn; its field's id as last
    /// drawn, for keeping them when it moves. True at launch: the window
    /// opens with the composer focused, as GPUI's does.
    focus_composer: bool = true,
    composer_id: u64 = 0,
    /// The frame the composer's field was last drawn in.
    composer_frame: u64 = 0,
    /// The press under way began with the keys in the session search or a
    /// menu that keeps them.
    press_kept_keys: bool = false,
    /// The Write page has the pane (view_write.zig); its field takes the
    /// keys when next drawn.
    write_open: bool = false,
    write_focus: bool = false,
    /// The first ⌘W's question is up (archive_close.zig).
    close_choice: bool = false,
    /// The sidebar's inline note (`sidebar_notice`) and when it goes; a
    /// click dismisses it sooner.
    sidebar_notice: [280]u8 = undefined,
    sidebar_notice_len: usize = 0,
    sidebar_notice_until: ?f64 = null,
    /// The rounded seam's hairline is the column's left border, which
    /// takes layout room in GPUI (`border_l_1`): 1 while it shows, else 0.
    seam_inset: f32 = 0,
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
    /// First-run setup, while it shows (view_setup.zig), and whether
    /// launch has asked if it should.
    setup: ?@import("view_setup.zig").Setup = null,
    setup_checked: bool = false,
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
    /// True while `view.zig` is running pre-tree setup/input dispatch before
    /// building nodes, so `a.redraw()` does not redundantly reset `frame_in`.
    in_pre_tree: bool = false,
    /// Last observed window size and active live-resize horizon for 120Hz reflow.
    last_win_w: f32 = 0,
    last_win_h: f32 = 0,
    resize_until: f64 = 0,
    /// Active streaming scroll-glide horizon and last streaming content signature.
    stream_glide_until: f64 = 0,
    stream_sig: u64 = 0,

    pub fn deinit(v: *View, gpa: Allocator) void {
        @import("text_buffer.zig").deinit(&v.settings_search);
        v.project_setup.deinit();
        v.open_chooser.deinit();
        @import("text_buffer.zig").deinit(&v.search.query);
        @import("text_buffer.zig").deinit(&v.strip.query);
        v.tool_ui.deinit(gpa);
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
            @import("text_buffer.zig").deinit(&d.source);
            d.arena.deinit();
            d.err.deinit(gpa);
            gpa.destroy(d);
        }
        v.shortcut_notice.deinit(gpa);
        if (v.ref_space) |s| gpa.free(s);
        for (v.refs.items) |r| gpa.free(r);
        v.refs.deinit(gpa);
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
    /// Last status seen per chat, so a finish chimes once (`sound.zig`).
    sound_seen: std.StringHashMapUnmanaged(struct { status: workspace.Status, seen: bool = false }) = .empty,
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
    retired_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    retired_ids: std.ArrayList([]u8) = .empty,
    /// The process's environment (main's), for what's started from here.
    env: ?*const std.process.Environ.Map = null,
    /// `harness headless`, started here when no engine answers.
    engine_start: @import("engine_start.zig").State = .{},
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
    /// The agents' list failed (`Loadable::Error`): no longer loading.
    harnesses_failed: bool = false,
    /// Where a new chat in a git project runs: a fresh worktree, GPUI's
    /// default (`CheckoutKind::NewWorktree`), unless the project's own
    /// checkout was picked.
    new_checkout_local: bool = false,
    /// Optional base branch/ref for a new chat's worktree (`Select ref`).
    new_ref: ?[]u8 = null,
    /// The new chat is a plain chat (chat_mode.zig), not a coding session.
    new_chat_mode: bool = false,
    /// An explicit projectless draft, unlike an uninitialized folder pick.
    new_no_project: bool = false,
    /// A draft's execution target; never changes this machine's identity.
    new_device: ?[]u8 = null,
    new_reasoning: ?[]u8 = null,
    /// The agent `models` lists models for (owned).
    models_for: []u8 = &.{},
    /// The model chip's picker is open.
    picker: enum { none, harness, model } = .none,
    /// The agent's pending question being answered, the draft set aside
    /// meanwhile, and the request just answered from here.
    wizard: ?@import("wizard.zig").Wizard = null,
    /// A wizard closed while a frame was drawing it: that frame's text
    /// still points into it until layout and paint are done, so it is
    /// freed at the next tick.
    retired_wizard: ?@import("wizard.zig").Wizard = null,
    draft_stash: std.ArrayList(u8) = .empty,
    answered: ?[]u8 = null,
    /// The open chat's queue, what the engine can do with it, and a row
    /// being edited in the composer (or asked for).
    queue: @import("queue.zig").Rows,
    w_queue: Watch = .{},
    caps: queue_mod.Caps = .{},
    queue_edit: ?queue_mod.Edit = null,
    queue_begin: ?[]u8 = null,
    /// Steers queued and waiting for their row's id, to promote it.
    steers: std.ArrayList(queue_mod.PendingSteer) = .empty,
    /// This window's editor id for queue edit leases.
    instance: [36]u8 = undefined,
    instance_set: bool = false,
    /// The project's actions, their editor, and the dock their runs show in.
    actions: @import("app_actions.zig").Actions,
    /// The terminal palette of the theme last drawn.
    ansi: [16]nanoui.ui.Color = @import("theme.zig").fallback(true).ansi,
    /// The surface pane and the file explorer beside the chat.
    panels: @import("app_panels.zig").Panels,
    /// The open chats, one per tab, and their split panes.
    tabs: Tabs,
    /// The saved GPUI `openTabs` were applied (or there were none): this
    /// window may now publish its own tabs back to the shared settings.
    tabs_ready: bool = false,
    tabs_dirty: bool = false,
    tabs_save_at: f64 = 0,
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
    /// Desktop update pills & Codegraff engine update notice (`view_updates.zig`).
    updates: @import("view_updates.zig").State = .{},
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
        @import("text_buffer.zig").deinit(&a.composer);
        @import("app_surface.zig").deinit(a);
        // An engine started from here stays up: others may be on it now.
        a.engine.deinit();
        a.reap();
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
        {
            var it = a.sound_seen.keyIterator();
            while (it.next()) |k| a.gpa.free(k.*);
            a.sound_seen.deinit(a.gpa);
        }
        a.devices.deinit();
        a.rememberTabs();
        if (a.tabs_dirty) {
            a.tabs_dirty = false;
            a.settings.flushOpenTabsAndLayout();
        }
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
        for (a.retired.items) |*t| t.deinit();
        for (a.retired_arenas.items) |*ar| ar.deinit();
        for (a.retired_ids.items) |s| a.gpa.free(s);
        a.dictation.deinit(a.gpa);
        a.retired.deinit(a.gpa);
        a.retired_arenas.deinit(a.gpa);
        a.retired_ids.deinit(a.gpa);
        if (a.selected) |s| a.gpa.free(s);
        if (a.space) |s| a.gpa.free(s);
        if (a.device_id) |d| a.gpa.free(d);
        if (a.new_model) |m| a.gpa.free(m);
        if (a.new_reasoning) |m| a.gpa.free(m);
        if (a.new_device) |id| a.gpa.free(id);
        if (a.new_ref) |r| a.gpa.free(r);
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
    pub const togglePickerCompact = agent.togglePickerCompact;
    pub const pickModel = agent.pickModel;
    pub const pickReasoning = agent.pickReasoning;
    pub const pickModelAndReasoning = agent.pickModelAndReasoning;
    pub const applyLiveModelAndReasoning = agent.applyLiveModelAndReasoning;
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

    /// v0.2.173 pickers::new_project dispatches AddSpacePalette, not an OS dialog.
    pub const addFolder = @import("app_project_setup.zig").open;

    pub fn releaseCame(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        @import("view_updates.zig").onReleaseChecked(a);
    }

    pub fn redraw(a: *App) void {
        if (a.view.in_pre_tree) return;
        if (a.window) |w| {
            @import("frame_profile.zig").countRedraw();
            w.redraw();
        }
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
                @import("engine_start.zig").connected(a);
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
                // Nothing answers: start an engine, as a person would.
                if (s == .disconnected) @import("engine_start.zig").disconnected(a);
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
        if (a.w_queue.retry_at) |t| {
            if (now >= t) {
                a.w_queue = .{};
                queue_mod.watch(a);
            } else next = if (next) |n| @min(n, t) else t;
        }
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
        if (a.tabs_dirty) {
            if (now >= a.tabs_save_at) {
                a.tabs_dirty = false;
                @import("frame_profile.zig").note(a, "flush-tabs");
                a.settings.flushOpenTabsAndLayout();
            } else next = if (next) |n| @min(n, a.tabs_save_at) else a.tabs_save_at;
        }
        return if (next) |n| @max(@as(f32, 0.016), @as(f32, @floatCast(n - now))) else null;
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
        if (a.view.filter) |old| {
            a.retireSlice(old);
            a.view.filter = null;
        }
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

    /// The selected project owns its host; a projectless draft keeps its
    /// explicit computer, falling back to the local device only if unpicked.
    pub fn draftDevice(a: *const App) ?[]const u8 {
        if (a.newChatSpace()) |space| if (space.device_id) |id| return id;
        return a.new_device orelse a.device_id;
    }

    fn storeDraftDevice(a: *App, id: ?[]const u8) bool {
        const copy = if (id) |dev| a.gpa.dupe(u8, dev) catch return false else null;
        if (a.new_device) |old| a.retireSlice(old);
        a.new_device = copy;
        return true;
    }

    /// A computer pick cannot move an established conversation. A draft keeps
    /// its folder only on the same computer; otherwise it becomes projectless,
    /// rather than silently choosing a different folder on the new machine.
    pub fn pickDraftDevice(a: *App, id: ?[]const u8) void {
        if (a.selected != null) return;
        const space = a.newChatSpace();
        const effective = id orelse a.device_id;
        const keep_folder = if (space) |sp| (if (sp.device_id) |host| (if (effective) |dev| std.mem.eql(u8, host, dev) else false) else false) else false;
        if (!a.storeDraftDevice(id)) return;
        if (!keep_folder) {
            if (a.space) |old| a.retireSlice(old);
            a.space = null;
            a.new_no_project = true;
        }
        a.view.focus_composer = true;
        a.redraw();
    }

    /// Reopens the chat tabs the GPUI app saved (`openTabs`), in their
    /// order, with `lastChatId` active. Missing chats are skipped; a tab
    /// that is already open, a test scene, or an explicit launch chat keeps
    /// the current tabs.
    pub fn restoreTabs(a: *App) void {
        if (a.tabs_ready) return;
        if (a.selected != null or a.tabs.items.items.len != 1 or a.tabs.current() != null) {
            a.tabs_ready = true;
            return;
        }
        if (@import("app_tab_layout.zig").restore(a)) return;
        a.tabs_ready = true;
        const active = a.settings.text("lastChatId");
        // A pre-tabs GPUI file has only the last chat. Reopen that one rather
        // than starting blank; an explicitly empty `openTabs` has no active
        // chat and stays empty.
        if (a.settings.open_tabs.items.len == 0) {
            const only = active orelse return;
            if (a.findChat(only) == null) return;
            a.tabs.setCurrent(only);
            a.tabs.clearShown();
            a.select(only, null);
            return;
        }
        var wanted: usize = 0;
        var active_ix: ?usize = null;
        for (a.settings.open_tabs.items) |id| {
            if (a.findChat(id) == null or a.tabs.find(id) != null) continue;
            if (wanted == 0) a.tabs.setCurrent(id) else {
                a.tabs.newTab();
                a.tabs.setCurrent(id);
            }
            if (active) |last| {
                if (std.mem.eql(u8, last, id)) active_ix = wanted;
            }
            wanted += 1;
        }
        if (wanted == 0) return;
        a.tabs.active = active_ix orelse 0;
        a.tabs.clearShown();
        a.select(a.tabs.current(), null);
    }

    /// Publishes every open chat tab, and the active one, into the GPUI
    /// app's shared `openTabs`; Nano's versioned record beside it keeps the
    /// pane arrangement, shares, focus, zoom and panel tabs for its own reopen.
    pub fn rememberTabs(a: *App) void {
        if (!a.tabs_ready) return;
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(a.gpa);
        for (a.tabs.items.items) |id| addTabId(a, &ids, id);
        for (a.tabs.splits.items) |layout_state| if (layout_state) |s| {
            for (s.panes.items) |id| addTabId(a, &ids, id);
            for (s.groups[0..s.panes.items.len]) |group| for (group.items.items) |tab| addTabId(a, &ids, tab.chat);
        };
        const tabs_changed = a.settings.updateOpenTabs(ids.items, a.tabs.current());
        const layout_changed = @import("app_tab_layout.zig").rememberInMemory(a);
        if (!tabs_changed and !layout_changed) return;
        if (a.window != null and !a.offscreen) {
            a.tabs_dirty = true;
            a.tabs_save_at = a.now + 0.25;
        } else {
            a.settings.flushOpenTabsAndLayout();
        }
    }

    fn addTabId(a: *App, ids: *std.ArrayList([]const u8), id: ?[]const u8) void {
        const chat = id orelse return;
        for (ids.items) |have| if (std.mem.eql(u8, have, chat)) return;
        ids.append(a.gpa, chat) catch {};
    }

    /// Shows `chat_id` from the sidebar: in its tab, else the current one.
    pub fn openChat(a: *App, chat_id: []const u8, space_id: ?[]const u8) void {
        if (a.tabs.find(chat_id)) |at| {
            if (at.tab != a.tabs.active) a.showTab(at.tab);
            if (at.pane) |ix| a.focusPane(ix);
            if (at.panel_tab) |ix| a.showPaneTab(ix);
            return;
        }
        a.tabs.setCurrent(chat_id);
        a.select(chat_id, space_id);
    }

    /// Navigation reuses an open conversation, then its project's workspace.
    /// Conversations in that workspace share panel tabs; another project's
    /// workspace keeps its own panels and drafts (`open_chat_preserving_tabs`).
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
            if (at.panel_tab) |ix| a.showPaneTab(ix);
            return;
        }
        const project = a.findChat(chat_id).?.space_id;
        const destination: ?usize = if (sameProject(a.workspaceProject(a.tabs.active), project))
            a.tabs.active
        else for (0..a.tabs.items.items.len) |ix| {
            if (sameProject(a.workspaceProject(ix), project)) break ix;
        } else null;
        if (destination) |ix| {
            a.showTab(ix);
            a.tabs.isolateWorkspace() catch return;
            a.addChatTab(true);
        } else {
            a.newWorkspaceSession();
            a.tabs.isolateWorkspace() catch return;
        }
        a.tabs.setCurrent(chat_id);
        a.select(chat_id, project);
    }

    /// The workspace's selected conversation or parked draft owns its project.
    /// Never use the currently focused workspace's draft for an inactive one.
    pub fn workspaceProject(a: *const App, ix: usize) ?[]const u8 {
        if (ix >= a.tabs.items.items.len) return null;
        if (a.tabs.items.items[ix]) |id| if (a.findChat(id)) |chat| return chat.space_id;
        if (a.tabs.drafts.items[ix]) |d| return if (d.no_project) null else d.space;
        if (ix == a.tabs.active) if (a.newChatSpace()) |space| return space.id;
        return null;
    }

    fn sameProject(left: ?[]const u8, right: ?[]const u8) bool {
        return if (left) |id| (if (right) |other| std.mem.eql(u8, id, other) else false) else right == null;
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

    fn freshPanelDraft(a: *App, draft: tabs_mod.Draft) !tabs_mod.Draft {
        var fresh = try draft.fresh(a.gpa);
        errdefer fresh.deinit(a.gpa);
        // The new tab runs in its panel's folder, not whichever project's
        // canvas happened to be used before opening this established chat.
        if (a.selected) |id| if (a.findChat(id)) |chat| {
            const space = if (chat.space_id) |sp| try a.gpa.dupe(u8, sp) else null;
            if (fresh.space) |old| a.gpa.free(old);
            fresh.space = space;
            fresh.no_project = chat.space_id == null;
            const device = if (chat.device_id) |dev| try a.gpa.dupe(u8, dev) else null;
            if (fresh.device) |old| a.gpa.free(old);
            fresh.device = device;
        };
        return fresh;
    }

    /// "+", ⌘T: a new chat in a tab of its own (a fresh full-window canvas,
    /// like Ghostty), with the picks of the one left and an empty prompt.
    pub fn newTab(a: *App) void {
        var d = drafts.canvas(a) catch return;
        const fresh = a.freshPanelDraft(d) catch return d.deinit(a.gpa);
        const focus_pane = if (a.tabs.layout()) |s| s.focus else null;
        a.tabs.park(a.tabs.active, focus_pane, d);
        a.tabs.newTab();
        a.view.strip.focused = .{ .chat = 0 };
        a.view.strip.expanded = null;
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        a.select(null, null);
        drafts.adopt(a, fresh);
    }

    pub fn addChatTab(a: *App, append: bool) void {
        var d = drafts.canvas(a) catch return;
        const fresh = a.freshPanelDraft(d) catch return d.deinit(a.gpa);
        if (a.tabs.layout() != null) {
            const inserted = if (append) a.tabs.appendPaneTab(d) else a.tabs.newPaneTab(d);
            inserted catch {
                d.deinit(a.gpa);
                var unused = fresh;
                unused.deinit(a.gpa);
                return;
            };
        } else {
            a.tabs.park(a.tabs.active, null, d);
            a.tabs.newTab();
        }
        a.view.strip.expanded = null;
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        a.select(null, null);
        drafts.adopt(a, fresh);
    }

    /// Sidebar / All sessions "+": an independent workspace, not another
    /// tab inside the focused panel. Keep the entire old split and its
    /// focused draft parked together for when that workspace is reopened.
    pub fn newWorkspaceSession(a: *App) void {
        a.tabs.isolateWorkspace() catch return;
        var d = drafts.canvas(a) catch return;
        const fresh = a.freshPanelDraft(d) catch return d.deinit(a.gpa);
        a.tabs.park(a.tabs.active, null, d);
        a.tabs.newTab();
        a.view.strip.focused = .{ .chat = 0 };
        a.view.strip.expanded = null;
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        a.select(null, null);
        drafts.adopt(a, fresh);
    }

    /// Switch tabs inside the focused split panel; its neighbors stay put.
    pub fn showPaneTab(a: *App, ix: usize) void {
        var outgoing = drafts.canvas(a) catch return;
        const back = a.tabs.selectPaneTab(ix, outgoing) catch return outgoing.deinit(a.gpa);
        a.select(a.tabs.current(), null);
        if (back) |d| drafts.adopt(a, d);
        a.redraw();
    }

    /// Back and forward, and the tab list's rows: show another tab, its
    /// draft back as it was left (`load_chat_tab`).
    pub fn showTab(a: *App, i: usize) void {
        if (i >= a.tabs.items.items.len or i == a.tabs.active) return;
        a.park();
        a.tabs.active = i;
        a.tabs.noteShown();
        a.view.split_reveal = null;
        a.view.strip.expanded = null;
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        const focus_pane = if (a.tabs.layout()) |s| s.focus else null;
        a.view.strip.focused = .{ .chat = focus_pane orelse 0 };
        a.select(a.tabs.current(), null);
        if (a.tabs.unpark(i, focus_pane)) |d| {
            if (a.selected == null) drafts.adopt(a, d) else {
                var unused = d;
                unused.deinit(a.gpa);
            }
        } else if (a.tabs.unpark(i, null)) |d| {
            if (a.selected == null) drafts.adopt(a, d) else {
                var unused = d;
                unused.deinit(a.gpa);
            }
        }
    }

    pub fn isOnlyNewChat(a: *const App) bool {
        if (a.selected != null or a.tabs.items.items.len != 1) return false;
        if (a.tabs.layout()) |s| return s.panes.items.len == 1 and s.groups[0].count() == 1;
        return true;
    }

    pub fn closeTab(a: *App, i: usize) void {
        // Another tab: the one shown stays as it is.
        if (i != a.tabs.active) {
            a.tabs.close(i);
            a.rememberTabs();
            return a.redraw();
        }
        if (a.isOnlyNewChat()) return a.redraw();
        const was_chat = a.selected != null;
        a.tabs.close(i);
        a.view.split_reveal = null;
        a.view.strip.expanded = null;
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        const focus_pane = if (a.tabs.layout()) |s| s.focus else null;
        a.view.strip.focused = .{ .chat = focus_pane orelse 0 };
        a.select(a.tabs.current(), null);
        if (a.tabs.unpark(a.tabs.active, focus_pane)) |d| {
            if (a.selected == null) drafts.adopt(a, d) else {
                var unused = d;
                unused.deinit(a.gpa);
            }
        } else if (a.tabs.unpark(a.tabs.active, null)) |d| {
            if (a.selected == null) drafts.adopt(a, d) else {
                var unused = d;
                unused.deinit(a.gpa);
            }
        } else if (was_chat and a.selected == null) {
            @import("app_attachments.zig").clear(a);
            a.composer.clear();
        }
    }

    /// ⌘D, ⌘⇧D: the focused pane split, focus in the new pane: a new chat
    /// with the picks of the pane left and an empty prompt (`split_chat`).
    pub fn splitPane(a: *App, axis: tabs_mod.Axis) void {
        var d = drafts.canvas(a) catch return;
        var fresh = a.freshPanelDraft(d) catch return d.deinit(a.gpa);
        var reveal: SplitReveal = .{ .tab = a.tabs.active, .new_index = 0, .old_count = 1 };
        reveal.from_shares[0] = 1;
        if (a.tabs.layout()) |old| {
            reveal.old_count = old.panes.items.len;
            for (old.shares.items, 0..) |share, ix| reveal.from_shares[ix] = share;
        }
        if (!(a.tabs.split(axis) catch false)) {
            d.deinit(a.gpa);
            return fresh.deinit(a.gpa);
        }
        a.tabs.park(a.tabs.active, a.tabs.layout().?.focus - 1, d);
        reveal.new_index = a.tabs.layout().?.focus;
        a.view.split_reveal = reveal;
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
        if (a.tabs.layout()) |s| {
            if (s.panes.items.len > 1) return a.focusPane(s.cycled(forward));
            const group = &s.groups[s.focus];
            const n = group.count();
            if (n > 1) {
                const next = if (forward) (group.active + 1) % n else (group.active + n - 1) % n;
                return a.showPaneTab(next);
            }
        }
        const n = a.tabs.items.items.len;
        if (n > 1) {
            const next = if (forward) (a.tabs.active + 1) % n else (a.tabs.active + n - 1) % n;
            a.showTab(next);
        }
    }

    /// ⌥⌘+arrow: the pane that way.
    pub fn focusToward(a: *App, d: tabs_mod.Direction) void {
        const s = a.tabs.layout() orelse return;
        if (s.toward(d)) |ix| a.focusPane(ix);
    }

    /// ⌘= / ⌘+ / ⌘-: steps the interface text size through the supported
    /// sizes (`UiFontSize::stepped`) and schedules 120Hz reflow.
    pub fn stepZoom(a: *App, step: i32) void {
        const settings_mod = @import("settings.zig");
        const cur = a.settings.uiFontSize();
        const next = settings_mod.stepUiFontSize(cur, step);
        if (next == cur) return;
        a.settings.setUiFontSize(next);
        a.view.resize_until = a.now + 0.16;
        a.redraw();
    }

    /// ⌘0: resets the interface text size to the 16 px baseline.
    pub fn resetZoom(a: *App) void {
        const settings_mod = @import("settings.zig");
        if (a.settings.uiFontSize() == settings_mod.ui_font_size_default) return;
        a.settings.setUiFontSize(settings_mod.ui_font_size_default);
        a.view.resize_until = a.now + 0.16;
        a.redraw();
    }

    /// ⌘W (`close_chat_view_by_shortcut`): asks first until a choice is
    /// made, then closes, archiving per Settings › Archived.
    pub fn closeByShortcut(a: *App) void {
        const strip = @import("view_tab_strip.zig");
        const rules = @import("motion_rules.zig");
        const active_surface: rules.CloseSurface = switch (strip.active(a)) {
            .chat => .chat,
            .host => .host,
            .files => .files,
        };
        const split_panes = strip.chatCount(a);
        const group_tabs = if (a.tabs.layout()) |s| s.groups[s.focus].count() else 1;
        const zoomed = if (a.tabs.layout()) |s| s.zoomed else false;
        const host_bg_open = strip.hasHost(a) and a.panels.activeTab() != null;
        const expanded = a.view.strip.expanded != null or zoomed;
        const ac = @import("archive_close.zig");
        const needs_ask = ac.asks(a.settings.get(.archive_on_close_chosen), a.settings.get(.archive_sessions_on_close), a.selected != null);
        switch (rules.decideCloseTarget(
            active_surface,
            a.view.close_choice,
            group_tabs,
            split_panes,
            host_bg_open,
            expanded,
            a.isOnlyNewChat(),
            needs_ask,
        )) {
            .confirm_choice => return a.chooseCloseArchiving(false),
            .close_host => {
                a.view.close_choice = false;
                if (a.panels.active < a.panels.tabs.items.len) @import("app_panels.zig").closeTab(a, a.panels.active) else a.panels.host_open = false;
                a.view.strip.menu = null;
                return a.redraw();
            },
            .close_files => {
                a.panels.files_open = false;
                a.view.strip.menu = null;
                return a.redraw();
            },
            .noop => return a.redraw(),
            .ask_choice => {
                a.view.close_choice = true;
                return a.redraw();
            },
            .close_pane_tab, .close_split_pane, .close_tab => {
                a.closeArchiving(a.settings.get(.archive_sessions_on_close));
            },
        }
    }

    /// The question's answer: saved as the default, then this close.
    pub fn chooseCloseArchiving(a: *App, archive: bool) void {
        if (!a.view.close_choice) return;
        a.view.close_choice = false;
        a.settings.set(.archive_sessions_on_close, archive);
        a.closeArchiving(archive);
    }

    /// Closes the focused pane or tab, then archives the chat it showed if
    /// `may_archive` and it's idle and shown nowhere else.
    pub fn closeArchiving(a: *App, may_archive: bool) void {
        a.view.close_choice = false;
        const id = if (a.selected) |s| a.gpa.dupe(u8, s) catch null else null;
        defer if (id) |x| a.gpa.free(x);
        a.closeFocused();
        if (id) |x| a.archiveClosed(x, may_archive);
    }

    /// A tab's ✕: archives per the setting, and never asks.
    pub fn closeTabArchiving(a: *App, i: usize) void {
        const tab_chat = if (i < a.tabs.items.items.len) a.tabs.items.items[i] else null;
        const id = if (tab_chat) |s| a.gpa.dupe(u8, s) catch null else null;
        defer if (id) |x| a.gpa.free(x);
        a.closeTab(i);
        if (id) |x| a.archiveClosed(x, a.settings.get(.archive_sessions_on_close));
    }

    pub fn archiveClosed(a: *App, id: []const u8, may_archive: bool) void {
        const ac = @import("archive_close.zig");
        const st = workspace.statusOf(a.sessions.items, id);
        var sending = false;
        for (a.pending_sends.items) |p| if (!p.rejected and std.mem.eql(u8, p.chat, id)) {
            sending = true;
        };
        switch (ac.decide(may_archive, a.tabs.find(id) != null, sending or st == .working or st == .awaiting_input)) {
            .archive => a.setArchived(id, true),
            .running => a.setSidebarNotice(ac.running_notice, ac.notice_s),
            .off, .still_open => {},
        }
    }

    /// The sidebar's inline note, for `seconds` (null: until clicked).
    pub fn setSidebarNotice(a: *App, text: []const u8, seconds: ?f64) void {
        const n = @min(text.len, a.view.sidebar_notice.len);
        @memcpy(a.view.sidebar_notice[0..n], text[0..n]);
        a.view.sidebar_notice_len = n;
        a.view.sidebar_notice_until = if (seconds) |s| a.now + s else null;
        a.redraw();
    }

    /// ⌘W: the focused pane in a split, the next one's draft back; else
    /// the tab.
    pub fn closeFocused(a: *App) void {
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        a.view.split_reveal = null;
        if (a.isOnlyNewChat()) return a.redraw();
        if (!a.tabs.closePaneTab()) return a.closePanel();
        a.restorePanelDraft();
    }

    /// Explicit Close panel is different from closing its selected tab.
    pub fn closePanel(a: *App) void {
        a.view.strip.menu = null;
        a.view.strip.pending_folder = null;
        a.view.split_reveal = null;
        a.view.strip.expanded = null;
        if (a.isOnlyNewChat()) return a.redraw();
        if (!a.tabs.closePane()) return a.closeTab(a.tabs.active);
        a.view.strip.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
        a.restorePanelDraft();
    }

    fn restorePanelDraft(a: *App) void {
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
            const in_split = for (wanted) |w| {
                if (w) |x| if (std.mem.eql(u8, x, p.id)) break true;
            } else false;
            if (in_split or @import("app_panes.zig").otherSlotHas(a, p.id)) {
                if (in_split and p.watch == null and p.retry_at == null and live) a.watchPeer(p);
                i += 1;
                continue;
            }
            if (p.watch) |w| a.engine.cancel(w);
            a.retired.append(a.gpa, p.transcript) catch p.transcript.deinit();
            a.retireSlice(p.id);
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
                a.restoreTabs();
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
        @import("sound.zig").observe(a);
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

    pub fn onEngineInfo(a: *App, _: u64, r: rpc.Reply) void {
        const v = switch (r) {
            .ok => |v| v,
            else => return,
        };
        if (v != .object) return;
        a.account.scope = account.readScope(v.object);
        if (v.object.get("capabilities")) |caps| if (caps == .array) {
            a.caps = queue_mod.readCaps(caps.array.items);
        };
        if (v.object.get("version")) |ver_val| if (ver_val == .string) {
            const updates = @import("view_updates.zig");
            const live_session = !a.offscreen and a.engine.scene == null and
                (if (a.env) |env| env.get("HARNESS_NANO_NO_ENGINE_START") == null else false);
            switch (updates.decideEngineVersionAction(
                @import("build_info").version,
                ver_val.string,
                live_session,
                a.engine_start.replaced_once,
            )) {
                .up_to_date => a.view.sidebar_notice_len = 0,
                .replace_old_session => {
                    @import("engine_start.zig").replaceOlderEngine(a);
                    return;
                },
                .notify_only => {
                    var notice_buf: [280]u8 = undefined;
                    if (updates.olderEngineNotice(&notice_buf, @import("build_info").version, ver_val.string)) |msg| {
                        a.setSidebarNotice(msg, null);
                    }
                },
            }
        };
        const id = v.object.get("deviceId") orelse return;
        if (id != .string) return;
        if (a.device_id) |d| a.retireSlice(d);
        a.device_id = a.gpa.dupe(u8, id.string) catch null;
        // Watches opened before routed through `targetDeviceId`.
        change_requests.restart(a);
    }

    fn onHarnesses(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .ok => |v| {
                a.harnesses.replace(v) catch {};
                a.harnesses_failed = false;
            },
            // The picker's to say (its retry row), not the composer's.
            .err => a.harnesses_failed = true,
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
        // Another chat closes the Write page; its draft stays the old one's.
        a.view.write_open = false;
        @import("app_panes.zig").select(a, chat_id);
        a.notice_len = 0;
        queue_mod.stop(a);
        const same = if (a.selected) |s| (if (chat_id) |c| std.mem.eql(u8, s, c) else false) else chat_id == null;
        if (!same) if (a.selected) |s| a.retireSlice(s);
        if (!same) a.selected = if (chat_id) |c| a.gpa.dupe(u8, c) catch null else null;
        // A leftover offset from the previous chat parks this one in padding.
        if (!same) a.view.stick_end = true;
        if (space_id) |s| {
            if (a.space) |old| a.retireSlice(old);
            a.space = a.gpa.dupe(u8, s) catch null;
            a.new_no_project = false;
            if (a.findSpace(s)) |space| _ = a.storeDraftDevice(space.device_id);
        }
        a.rememberTabs();
        const chat = a.selected orelse {
            @import("app_panels.zig").chatChanged(a);
            return a.redraw();
        };
        if (!same) a.request(requests.focusChat(chat), .of(App, a, onNotice));
        a.markSeen(chat);
        if (!same and a.w_doc.id == null and a.w_doc.retry_at == null) a.watchDoc(true);
        queue_mod.watch(a);
        @import("app_panels.zig").chatChanged(a);
        a.ensureModels(a.target().harness);
        a.redraw();
    }

    pub fn retireArena(a: *App, arena: std.heap.ArenaAllocator) void {
        var ar = arena;
        if (ar.queryCapacity() == 0) {
            ar.deinit();
            return;
        }
        a.retired_arenas.append(a.gpa, ar) catch ar.deinit();
    }

    pub fn retireSlice(a: *App, slice: []u8) void {
        if (slice.len == 0) return;
        a.retired_ids.append(a.gpa, slice) catch a.gpa.free(slice);
    }

    /// Opened, a chat is seen (`mark_chat_seen`): here at once, its
    /// Done giving way to its time, then on the host; only when unseen.
    /// At a frame's start, before anything is drawn: what `select` let go
    /// of, freed.
    pub fn reap(a: *App) void {
        @import("app_attachments.zig").reap(a);
        @import("app_send_feedback.zig").reap(a);
        a.spaces.reap();
        a.chats.reap();
        a.sessions.reap();
        a.devices.reap();
        a.queue.reap();
        a.harnesses.reap();
        a.models.reap();
        a.view.model_picker.reap(a.gpa);
        for (a.retired.items) |*t| t.deinit();
        a.retired.clearRetainingCapacity();
        for (a.retired_arenas.items) |*ar| ar.deinit();
        a.retired_arenas.clearRetainingCapacity();
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
        a.sendFollowUp(null);
    }

    /// As `send`, with a follow-up during a run named by the shortcut that
    /// asked for it (`choose_follow_up`) rather than Settings' choice.
    pub fn sendFollowUp(a: *App, explicit: ?queue_mod.FollowUp) void {
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
        // A plain chat with no Auto tier would fall to graff's own default.
        if (@import("app_agent.zig").chatSendBlocked(a)) return;
        if (a.queues()) {
            // Enter falls back to the queue when a steer can't go now; a
            // shortcut asking for one says why instead.
            const blocker = queue_mod.steerBlocker(a, text.len > 0, attachments.count(a) > 0);
            if (explicit == .steer) if (blocker) |why| {
                a.setNotice(why);
                return a.redraw();
            };
            const action = explicit orelse queue_mod.followUpAction(queue_mod.followUpBehavior(a), blocker);
            if (action == .steer) queue_mod.steer(a, prompt) else queue_mod.queueMessage(a, prompt);
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
        var worktree: ?requests.WorktreeSpec = null;
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
            const agent_mod = @import("app_agent.zig");
            const space = agent_mod.newChatSpace(a);
            if (space) |s| cwd = s.path;
            // A git project's new chat runs in a fresh worktree unless its
            // own checkout was picked (`CheckoutPlan::NewWorktree`); cwd
            // stays the repo, where an older host runs it.
            if (space) |s| if (s.git and !a.new_checkout_local) {
                worktree = .{ .repoPath = s.path, .base = a.new_ref orelse "", .spaceId = s.id };
            };
            const t = agent_mod.target(a);
            const plain = a.new_chat_mode;
            harness = if (plain) t.harness else a.new_harness;
            model = if (plain) t.model else a.new_model;
            reasoning = a.new_reasoning;
            const config: requests.Config = .{
                .harness = harness.?,
                .model = model,
                .reasoning = reasoning,
                .chatMode = if (plain) true else null,
            };
            // A chat with no project names its device instead.
            if (space) |s|
                a.request(requests.createChat(id, s.id, config), .of(App, a, onNotice))
            else
                a.request(requests.createChatOn(id, a.draftDevice(), config), .of(App, a, onNotice));
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
            .worktree = worktree,
        }), .of(feedback.Pending, pending, feedback.Pending.onReply));
        // Sent: the prompt is no one's draft any more.
        attachments.clear(a);
        a.composer.clear();
        a.view.stick_end = true;
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
