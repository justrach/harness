//! One desktop top lane: split panels have slots, one panel has folder tabs.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const chrome = @import("panel_chrome.zig");
const tabs = @import("tabs.zig");
const workspace = @import("workspace.zig");
const panels = @import("app_panels.zig");
const tip = @import("view_tooltip.zig");

pub const Panel = union(enum) { chat: usize, host, files };
pub const DevicePick = struct { panel: Panel, id: [256]u8 = undefined, len: u16 = 0 };
pub const Action = union(enum) {
    focus: Panel,
    new: Panel,
    close: Panel,
    zoom: Panel,
    split_right: Panel,
    split_down: Panel,
    move_left: Panel,
    move_right: Panel,
    global_tab: usize,
    close_global_tab: usize,
    panel_tab: struct { pane: usize, tab: usize },
    close_panel_tab: struct { pane: usize, tab: usize },
    host_tab: usize,
    close_host_tab: usize,
    folder: struct { panel: Panel, index: ?usize },
    device: DevicePick,
    add_folder: Panel,
};
pub const Menu = enum { panel, history, folder, device };
pub const State = struct {
    focused: Panel = .{ .chat = 0 },
    target: Panel = .{ .chat = 0 },
    menu: ?Menu = null,
    /// Composer project picker shares search state, but uses desktop's
    /// wider card and New project → No project action ordering.
    footer_folder: bool = false,
    anchor: ?ui.Rect = null,
    /// The computer chip's own anchor, so a folder menu or the footer cannot
    /// move the device popover while it is open.
    device_anchor: ?ui.Rect = null,
    pending: ?Action = null,
    expanded: ?Panel = null,
    cursor: usize = 0,
    rows: usize = 0,
    activate: bool = false,
    focus_menu: bool = false,
    query: ui.TextBuffer = .{},
    search_focus: bool = false,
    select_current: bool = false,
    search_scroll: u64 = 0,
    reveal: bool = false,
    pending_folder: ?usize = null,
};

pub fn chatCount(a: *const App) usize {
    return if (a.tabs.layout()) |s| s.panes.items.len else 1;
}
pub fn hasHost(a: *const App) bool {
    return a.panels.host_open;
}
pub fn hasFiles(a: *const App) bool {
    return a.panels.files_open;
}
pub fn count(a: *const App) usize {
    return chatCount(a) + @intFromBool(hasHost(a)) + @intFromBool(hasFiles(a));
}
pub fn same(a: Panel, b: Panel) bool {
    return switch (a) {
        .chat => |ix| switch (b) {
            .chat => |other| ix == other,
            else => false,
        },
        .host => b == .host,
        .files => b == .files,
    };
}
pub fn active(a: *const App) Panel {
    return switch (a.view.strip.focused) {
        .chat => .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 },
        .host => if (hasHost(a)) .host else .{ .chat = 0 },
        .files => if (hasFiles(a)) .files else .{ .chat = 0 },
    };
}
pub fn focus(a: *App, panel: Panel) void {
    const expanded = a.view.strip.expanded != null;
    switch (panel) {
        .chat => |ix| {
            const zoomed = if (a.tabs.layout()) |s| s.zoomed else false;
            a.focusPane(ix);
            if (zoomed) {
                if (a.tabs.layout()) |s| s.zoomed = true;
            }
        },
        .host, .files => {},
    }
    a.view.strip.focused = panel;
    if (expanded) a.view.strip.expanded = panel;
    a.redraw();
}

/// Mutate before labels are built: parked drafts may own the strings that a
/// previous frame used. Never close them while building that frame's nodes.
pub fn settle(a: *App) void {
    const action = a.view.strip.pending orelse return;
    a.view.strip.pending = null;
    switch (action) {
        .focus => |p| focus(a, p),
        .new => |p| newTab(a, p),
        .close => |p| {
            focus(a, p);
            switch (p) {
                .chat => a.closePanel(),
                .host => {
                    a.panels.host_open = false;
                },
                .files => {
                    a.panels.files_open = false;
                },
            }
            a.view.strip.expanded = null;
            a.view.strip.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
        },
        .zoom => |p| {
            if (a.view.strip.expanded) |expanded| {
                if (same(expanded, p)) a.view.strip.expanded = null else a.view.strip.expanded = p;
            } else a.view.strip.expanded = p;
            focus(a, p);
            if (p == .chat) {
                if (a.tabs.layout()) |s| s.zoomed = a.view.strip.expanded != null;
                a.rememberTabs();
            }
        },
        .split_right, .split_down => |p| {
            focus(a, p);
            splitChoosingDestination(a, if (action == .split_right) .horizontal else .vertical);
        },
        .move_left, .move_right => |p| {
            focus(a, p);
            if (p == .chat) {
                a.tabs.movePane(action == .move_right);
                a.rememberTabs();
                const moved: Panel = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
                a.view.strip.focused = moved;
                if (a.view.strip.expanded != null) a.view.strip.expanded = moved;
            }
        },
        .global_tab => |ix| {
            a.showTab(ix);
            a.view.strip.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
        },
        .close_global_tab => |ix| a.closeTabArchiving(ix),
        .panel_tab => |at| {
            focus(a, .{ .chat = at.pane });
            a.showPaneTab(at.tab);
        },
        .close_panel_tab => |at| {
            if (a.tabs.layout()) |s| if (at.pane < s.panes.items.len) {
                const group = &s.groups[at.pane];
                if (at.tab < group.items.items.len and at.tab != group.active) {
                    var removed = group.items.orderedRemove(at.tab);
                    if (group.active > at.tab) group.active -= 1;
                    const closed_id = removed.chat;
                    removed.chat = null;
                    if (removed.draft) |*d| d.deinit(a.gpa);
                    defer if (closed_id) |x| a.gpa.free(x);
                    if (s.panes.items.len == 1 and group.count() == 1) {
                        if (a.tabs.drafts.items[a.tabs.active]) |*d| d.deinit(a.gpa);
                        a.tabs.drafts.items[a.tabs.active] = s.drafts.items[0];
                        s.drafts.items[0] = null;
                        s.deinit(a.gpa);
                        a.tabs.splits.items[a.tabs.active] = null;
                    }
                    a.rememberTabs();
                    if (closed_id) |x| a.archiveClosed(x, a.settings.get(.archive_sessions_on_close));
                    a.redraw();
                    return;
                }
            };
            focus(a, .{ .chat = at.pane });
            a.closeArchiving(a.settings.get(.archive_sessions_on_close));
        },
        .host_tab => |ix| {
            focus(a, .host);
            panels.showTab(a, ix);
        },
        .close_host_tab => |ix| panels.closeTab(a, ix),
        .folder => |pick| {
            focus(a, pick.panel);
            const space = if (pick.index) |ix| (if (ix < a.spaces.items.len) a.spaces.items[ix].id else return) else null;
            if (a.selected) |sel| {
                const cur_space = if (a.findChat(sel)) |ch| ch.space_id else null;
                const same_space = if (cur_space) |cs| (if (space) |sp| std.mem.eql(u8, cs, sp) else false) else space == null;
                if (!same_space) {
                    a.tabs.setCurrent(null);
                    a.select(null, space);
                }
            } else {
                if (space == null) a.pickDraftDevice(a.draftDevice());
                a.select(null, space);
            }
            a.new_no_project = space == null;
            if (space == null) {
                if (a.space) |old| a.gpa.free(old);
                a.space = null;
            }
        },
        .device => |pick| {
            if (pick.panel != .chat or pick.panel.chat >= chatCount(a)) return;
            focus(a, pick.panel);
            const wanted = pick.id[0..pick.len];
            if (a.selected) |sel| {
                const cur_dev = (if (a.findChat(sel)) |ch| ch.device_id else null) orelse a.device_id orelse "local";
                if (!std.mem.eql(u8, cur_dev, wanted)) {
                    a.tabs.setCurrent(null);
                    a.select(null, null);
                    a.pickDraftDevice(wanted);
                }
            } else {
                a.pickDraftDevice(wanted);
            }
        },
        .add_folder => |p| {
            focus(a, p);
            @import("app_open_chooser.zig").open(a, .new_project);
        },
    }
    const motion = @import("motion_rules.zig");
    const menu_kind: motion.MenuKind = if (a.view.strip.menu) |m| switch (m) {
        .panel => .panel,
        .history => .history,
        .folder => .folder,
        .device => .device,
    } else .none;
    const focus_decision = motion.settleFocus(menu_kind, active(a) == .chat);
    if (focus_decision.focus_menu) {
        a.view.focus_composer = false;
        a.view.strip.focus_menu = true;
        if (focus_decision.search_focus) {
            a.view.strip.search_focus = true;
            a.view.strip.select_current = true;
        }
    } else if (focus_decision.focus_composer) {
        a.view.focus_composer = true;
    }
    a.redraw();
}
pub fn newTab(a: *App, panel: Panel) void {
    focus(a, panel);
    switch (panel) {
        .chat => @import("app_open_chooser.zig").open(a, .new_tab),
        .host => {
            a.panels.active = a.panels.tabs.items.len;
            a.redraw();
        },
        .files => {
            a.panels.host_open = true;
            a.panels.active = a.panels.tabs.items.len;
            a.view.strip.focused = .host;
            a.redraw();
        },
    }
}
/// Queue the stable routing ID, not a device-list index: a device watch can
/// replace/reorder its rows before the next frame applies a pointer action.
pub fn queueDevice(a: *App, panel: Panel, id: []const u8) void {
    var pick: DevicePick = .{ .panel = panel };
    if (id.len > pick.id.len) return a.setNotice("This device identifier is too long to select.");
    @memcpy(pick.id[0..id.len], id);
    pick.len = @intCast(id.len);
    queue(a, .{ .device = pick });
}

pub fn queue(a: *App, action: Action) void {
    a.view.strip.pending = action;
    a.view.strip.menu = null;
    a.redraw();
}
pub fn open(a: *App, menu: Menu, target: Panel, anchor: ?ui.Rect) void {
    @import("frame_profile.zig").note(a, switch (menu) {
        .panel => "strip-menu-panel",
        .history => "strip-menu-history",
        .folder => "strip-menu-folder",
        .device => "strip-menu-device",
    });
    a.view.focus_composer = false;
    a.view.strip.menu = menu;
    a.view.strip.footer_folder = false;
    a.view.strip.cursor = 0;
    a.view.strip.rows = 0;
    a.view.strip.focus_menu = true;
    a.view.strip.query.clear();
    a.view.strip.search_focus = menu == .folder;
    a.view.strip.select_current = menu == .folder;
    a.view.strip.search_scroll = 0;
    a.view.strip.reveal = true;
    a.view.strip.target = target;
    if (menu == .device) a.view.strip.device_anchor = anchor else a.view.strip.anchor = anchor;
    a.redraw();
}
/// Workspace focus shortcuts remain available while a folder search owns
/// text input. Dismiss it before transferring focus, so typing cannot land
/// in a hidden field or be swallowed by its former menu.
pub fn navigationKeys(c: *ui.Context, a: *App) bool {
    const state = &a.view.strip;
    var handled = true;
    if (c.shortcut(.{ .key = '[', .cmd = true })) {
        @import("frame_profile.zig").note(a, "cmd-[");
        a.stepPane(false);
        state.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
    } else if (c.shortcut(.{ .key = ']', .cmd = true })) {
        @import("frame_profile.zig").note(a, "cmd-]");
        a.stepPane(true);
        state.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
    } else if (c.shortcut(.{ .key = 'l', .cmd = true })) {
        state.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
    } else handled = false;
    if (!handled) {
        const arrows = [_]struct { u21, tabs.Direction }{ .{ ui.Shortcut.left, .left }, .{ ui.Shortcut.right, .right }, .{ ui.Shortcut.up, .up }, .{ ui.Shortcut.down, .down } };
        for (arrows) |arrow| if (c.shortcut(.{ .key = arrow[0], .cmd = true, .alt = true })) {
            a.focusToward(arrow[1]);
            state.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
            handled = true;
            break;
        };
    }
    if (!handled) return false;
    state.menu = null;
    state.pending_folder = null;
    c.changed = false;
    a.view.focus_composer = true;
    a.redraw();
    return true;
}

pub fn keys(c: *ui.Context, a: *App) void {
    const state = &a.view.strip;
    if (state.menu == null) return;
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
        state.menu = null;
        a.view.focus_composer = true;
    } else if (c.shortcut(.{ .key = 't', .cmd = true }) or c.shortcut(.{ .key = 'n', .cmd = true })) {
        state.menu = null;
        state.pending_folder = null;
        a.newTab();
    } else if (c.shortcut(.{ .key = 'w', .cmd = true })) {
        state.menu = null;
        state.pending_folder = null;
        a.closeByShortcut();
    } else if (c.shortcut(.{ .key = 'd', .cmd = true })) {
        state.menu = null;
        splitChoosingFolder(a, .horizontal);
    } else if (c.shortcut(.{ .key = 'd', .cmd = true, .shift = true })) {
        state.menu = null;
        splitChoosingFolder(a, .vertical);
    } else if (state.rows > 0) {
        if (c.shortcut(.{ .key = ui.Shortcut.down })) {
            state.cursor = (state.cursor + 1) % state.rows;
            state.reveal = true;
        }
        if (c.shortcut(.{ .key = ui.Shortcut.up })) {
            state.cursor = (state.cursor + state.rows - 1) % state.rows;
            state.reveal = true;
        }
        if (c.shortcut(.{ .key = ui.Shortcut.enter })) state.activate = true;
    }
}

/// ⌘D keeps the release flow: split now, then choose the new pane's folder
/// from the menu under its slot.
pub fn splitChoosingFolder(a: *App, axis: tabs.Axis) void {
    @import("frame_profile.zig").note(a, if (axis == .horizontal) "cmd-d" else "cmd-shift-d");
    const before = chatCount(a);
    a.splitPane(axis);
    if (chatCount(a) <= before) return;
    const pane = a.tabs.layout().?.focus;
    a.view.strip.focused = .{ .chat = pane };
    a.view.strip.pending_folder = pane;
    a.view.strip.expanded = null;
    a.redraw();
}

/// An explicit "Split right/down" in the panel menu asks for the destination
/// first; the pane is created with that computer and folder already selected.
pub fn splitChoosingDestination(a: *App, axis: tabs.Axis) void {
    focus(a, active(a));
    @import("app_open_chooser.zig").open(a, if (axis == .horizontal) .split_right else .split_down);
}

pub fn offerSplitFolder(c: *ui.Context, a: *App, panel: Panel, anchor: ?ui.Rect) void {
    const pane = a.view.strip.pending_folder orelse return;
    if (panel != .chat or panel.chat != pane) return;
    const layout = a.tabs.layout() orelse {
        a.view.strip.pending_folder = null;
        return;
    };
    if (layout.focus != pane or a.view.strip.menu != null) {
        a.view.strip.pending_folder = null;
        return;
    }
    const host = device(a, panel);
    var any = false;
    for (a.spaces.items) |space| {
        if (host) |id| {
            const dev = space.device_id orelse continue;
            if (!std.mem.eql(u8, dev, id)) continue;
        }
        any = true;
        break;
    }
    if (!any) {
        a.view.strip.pending_folder = null;
        a.view.focus_composer = true;
        return;
    }
    const at = anchor orelse {
        c.frameIn(0);
        return;
    };
    a.view.strip.pending_folder = null;
    open(a, .folder, panel, at);
}

pub fn chatId(a: *const App, pane: usize) ?[]const u8 {
    if (a.tabs.layout()) |s| return if (pane == s.focus) a.selected else if (pane < s.panes.items.len) s.panes.items[pane] else null;
    return a.selected;
}
pub fn title(a: *const App, panel: Panel) []const u8 {
    return switch (panel) {
        .chat => |ix| if (chatId(a, ix)) |id| (if (a.findChat(id)) |chat| @import("view_sidebar.zig").chatLabel(chat) else "Conversation") else "New tab",
        .host => if (a.panels.activeTab()) |tab| hostTitle(a, tab) else "New tab",
        .files => "Files",
    };
}
pub fn hostTitle(a: *const App, tab: panels.Tab) []const u8 {
    return if (tab.kind == .tool_access) "Tool access" else if (tab.agent) |agent| agent.title else if (tab.browser) |browser| browser.title.text() else if (tab.kind == .diffs) a.panels.scope.label() else std.fs.path.basename(tab.path);
}
pub fn glyph(a: *const App, panel: Panel) icons.Name {
    return switch (panel) {
        .chat => .@"chat-round-line",
        .files => .folder,
        .host => if (a.panels.activeTab()) |tab| switch (tab.kind) {
            .browser => .globe,
            .file => .document,
            .diffs => .list,
            .subagent => .bot,
            .tool_access => .widget,
        } else .plus,
    };
}
pub fn device(a: *const App, panel: Panel) ?[]const u8 {
    const id = switch (panel) {
        .chat => |ix| chatId(a, ix),
        .host, .files => a.selected,
    };
    if (id) |chat| if (a.findChat(chat)) |ch| return ch.device_id;
    if (panel == .chat) if (a.tabs.layout()) |s| {
        if (panel.chat != s.focus and panel.chat < s.drafts.items.len) {
            if (s.drafts.items[panel.chat]) |draft| {
                if (!draft.no_project) {
                    if (parkedSpace(a, draft)) |space| if (space.device_id) |host| return host;
                }
                return draft.device orelse a.device_id;
            }
            return a.device_id;
        }
    };
    return a.draftDevice();
}
pub fn deviceLabel(a: *const App, id: ?[]const u8) []const u8 {
    return @import("strip_device.zig").label(id, a.device_id, a.devices.items, a.cloud_sandboxes.list);
}
pub const Folder = struct { name: []const u8, changeable: bool };
pub fn folder(a: *const App, panel: Panel) ?Folder {
    const pane = switch (panel) {
        .chat => |ix| ix,
        else => return null,
    };
    if (chatId(a, pane)) |id| {
        const ch = a.findChat(id) orelse return null;
        const space = a.findSpace(ch.space_id) orelse return .{ .name = "No project", .changeable = true };
        return .{ .name = space.name, .changeable = true };
    }
    if (a.tabs.layout()) |s| if (pane != s.focus) {
        const draft = s.drafts.items[pane] orelse return .{ .name = "No project", .changeable = true };
        const space = parkedSpace(a, draft);
        return .{ .name = if (space) |sp| sp.name else "No project", .changeable = true };
    };
    const space = a.newChatSpace();
    return .{ .name = if (space) |sp| sp.name else "No project", .changeable = true };
}
fn parkedSpace(a: *const App, draft: tabs.Draft) ?workspace.Space {
    if (draft.no_project) return null;
    if (a.findSpace(draft.space)) |space| return space;
    for (a.spaces.items) |space| {
        if (draft.device) |id| {
            const host = space.device_id orelse continue;
            if (!std.mem.eql(u8, host, id)) continue;
        }
        return space;
    }
    return null;
}

pub fn attention(a: *const App, panel: Panel, k: theme.Colors) ?ui.Color {
    const pane = switch (panel) {
        .chat => |ix| ix,
        else => return null,
    };
    var input = false;
    if (chatId(a, pane)) |id| switch (workspace.statusOf(a.sessions.items, id)) {
        .errored => return k.danger,
        .awaiting_input => input = true,
        .idle, .working => {},
    };
    if (a.tabs.layout()) |s| {
        if (pane < s.panes.items.len) for (s.groups[pane].items.items) |tab| if (tab.chat) |id| switch (workspace.statusOf(a.sessions.items, id)) {
            .errored => return k.danger,
            .awaiting_input => input = true,
            .idle, .working => {},
        };
    }
    return if (input) k.warning else null;
}
/// The explicit attention shortcut visits requesting tabs in panel order;
/// streaming alone never changes focus or creates an attention marker.
pub fn nextAttention(a: *App) void {
    const s = a.tabs.layout() orelse return;
    const total = s.panes.items.len;
    const start = s.focus + 1;
    for (0..total) |offset| {
        const pane = (start + offset) % total;
        const group = &s.groups[pane];
        for (0..group.count()) |ix| {
            const chat = if (ix == group.active) chatId(a, pane) else group.items.items[ix].chat;
            const id = chat orelse continue;
            const status = workspace.statusOf(a.sessions.items, id);
            if (status != .awaiting_input and status != .errored) continue;
            focus(a, .{ .chat = pane });
            if (ix != group.active) a.showPaneTab(ix);
            return;
        }
    }
}

pub fn tabCount(a: *const App, panel: Panel) usize {
    return switch (panel) {
        .chat => |ix| if (a.tabs.layout()) |s| s.groups[ix].count() else a.tabs.items.items.len,
        .host => blk: {
            var visible: usize = 0;
            for (a.panels.tabs.items) |tab| {
                if (tab.agent) |agent| if (!agent.belongsTo(a.selected)) continue;
                if (tab.browser) |browser| if (!browser.belongsTo(a.selected)) continue;
                visible += 1;
            }
            break :blk visible;
        },
        .files => 1,
    };
}
/// Desktop's toggle + history, then 10+4px control clearance. The history
/// control's 28 points ride the collapse tween with the seam instead of
/// flipping on `sidebar_open` at the ⌘B press, so opening the sidebar can
/// never teleport the lane backwards before the first tween frame.
pub fn leftInset(a: *const App) f32 {
    return @import("motion_rules.zig").stripLeftInset(
        a.view.sidebar_width,
        a.settings.sidebarWidth(),
        a.view.settings_open,
        @import("view_updates.zig").titlebarVisible(a),
    );
}

pub const rendering = @import("view_tab_strip_render.zig");
pub const draw = rendering.draw;
pub const menus = @import("view_tab_strip_menus.zig").draw;

test {
    _ = @import("panel_chrome.zig");
    _ = @import("strip_device.zig");
    _ = @import("strip_folder_search.zig");
    _ = @import("tests_ui_tab_strip.zig");
    _ = @import("tests_ui_strip_folder_search.zig");
    _ = @import("tests_ui_strip_devices.zig");
}
