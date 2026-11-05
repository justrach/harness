//! The window, laid out as Harness's (crates/ui/src/shell.rs): the sidebar
//! on the left, the open chat on the right with its header in the title
//! bar's row, and over both the title bar's buttons: the sidebar toggle,
//! back and forward through the tabs, and a new tab. A split tab shows its
//! panes side by side (⌘D) or stacked (⌘⇧D), each its share of the column.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const sidebar = @import("view_sidebar.zig");
const transcript_view = @import("view_transcript.zig");
const tabs = @import("tabs.zig");
const settings_view = @import("view_settings.zig");
const App = @import("app.zig").App;

/// Where the title bar's buttons start: right of the traffic lights.
const cluster_x: f32 = 88;
/// Three 24-point buttons, 8 then 2 points apart.
const cluster_w: f32 = 24 * 3 + 8 + 2;

pub fn view(a: *App, c: *ui.Context) void {
    @import("view_picker.zig").prepare(a);
    // The themes Settings › Appearance picked, for every palette drawn now.
    theme.light_id = a.settings.themeId(false);
    theme.dark_id = a.settings.themeId(true);
    const dark = a.dark orelse nanoui.isDark();
    c.theme = theme.ui(dark);
    // The accent Settings › Appearance chose, in place of the theme's.
    const base = @import("view_settings_appearance.zig").withAccent(theme.colors(dark), a);
    const surfaces = @import("surface_palette.zig");
    const requested = surfaces.requested(a.settings.text("surface"), base.recommended_frosted);
    const k = surfaces.apply(base, @import("app_surface.zig").sync(a, requested, dark));
    c.theme.background = if (k.frosted) .transparent else k.shell;
    c.theme.surface = k.composer;
    // Context.begin seeded an implicit root before the view resolved its
    // live theme. It must not leave an opaque sheet under a glass window.
    c.node(0).style.background = c.theme.background;
    @import("view_transcript.zig").column_w = @import("view_settings_appearance.zig").transcriptWidth(a);
    a.ansi = k.ansi;
    if (a.tick(c.time)) |wait| c.frameIn(wait);
    c.title_bar_height = sidebar.titlebar_h;
    @import("view_kit.zig").beginFrame(c, k);
    // Box edges on the device's pixels, a half toward zero, as GPUI's
    // taffy.rs puts them; text keeps the line heights nano gives it.
    if (comptime @hasField(ui.Context, "pixel_snap_text")) {
        c.pixel_snap = true;
        c.pixel_snap_text = false;
    }
    // Hover as GPUI's: none after the keyboard until the pointer moves.
    if (comptime @hasField(ui.Context, "keyboard_hides_hover")) c.keyboard_hides_hover = true;
    // A live snapshot asking for Settings (nanoui's NANOUI_LIVE_SNAPSHOT,
    // "settings" or "settings:<section>"): drawn in that frame alone, which
    // isn't shown; what the window shows is put back after.
    const peek: []const u8 = if (comptime @hasField(ui.Context, "snapshot_request")) c.snapshot_request else "";
    const Shown = struct { open: bool, section: @import("settings.zig").Section };
    var shown: ?Shown = null;
    if (std.mem.startsWith(u8, peek, "settings")) {
        shown = .{ .open = a.view.settings_open, .section = a.settings.section };
        a.view.settings_open = true;
        if (std.mem.indexOfScalar(u8, peek, ':')) |at| if (@import("settings.zig").Section.fromKey(peek[at + 1 ..])) |sec| {
            a.settings.section = sec;
        };
    }
    defer if (shown) |was| {
        a.view.settings_open = was.open;
        a.settings.section = was.section;
    };
    // Text breaks into lines where the GPUI app breaks it, with a nanoui
    // that has its rule (justrach/nanoui gpui-wrap).
    if (comptime @hasField(@TypeOf(c.text.*), "wrap_rule")) c.text.wrap_rule = .glyph_positions;
    // Glyphs land on the device's pixels as GPUI's `paint_glyph` puts them.
    if (comptime @hasField(@TypeOf(c.text.*), "glyph_snap")) c.text.glyph_snap = .half_toward_zero;
    // A line taller than its font's centres its glyphs as GPUI's
    // `ShapedLine::paint` does (justrach/nanoui baseline_rule).
    if (comptime @hasField(@TypeOf(c.text.*), "baseline_rule")) c.text.baseline_rule = .glyph_box;
    // Last frame's let-go transcript, now nothing drawn reads it.
    a.reap();
    @import("app_subagents.zig").settleFrame(a);
    @import("app_browser.zig").settleFrame(a);
    @import("view_settings_theme_import.zig").settleFrame(a);
    // Capture once, before drawing the search can blur it on a pointer
    // press. An open but unfocused search must not steal another field.
    if (c.input.pressed and a.view.sidebar_press_frame != c.frame) {
        a.view.sidebar_press_frame = c.frame;
        const focused_sidebar = if (c.rects.get(c.focus)) |r| r.x < a.view.sidebar_width else false;
        a.view.sidebar_press_focus = @import("view_sidebar_search.zig").hasFocus(a) or focused_sidebar;
    }
    keys(c, a);
    a.syncPeers();
    {
        const root = ui.div(c).row().sizeFull().bg(k.shell);
        defer root.end();
        // One retained motion owner, independent of the sidebar's mount state.
        // CSS ease-out is cubic-bezier(0, 0, 0.58, 1), as GPUI's RESIZE.
        const animated = ui.motion.number(c, "sidebar-width", if (a.view.sidebar_open or a.view.settings_open) sidebar.width else 0, .{
            .tween = .{ .duration = 0.2, .ease = .{ .bezier = .{ 0, 0, 0.58, 1 } } },
        });
        // Settings navigation stays full width, even when the chat sidebar
        // was closed (or in flight) when Settings opened.
        a.view.sidebar_width = if (a.view.settings_open) sidebar.width else animated;
        @import("view_drag.zig").update(c, a);
        {
            ui.key(c, "sidebar-slot");
            const slot = ui.div(c).w(a.view.sidebar_width).hFull().clip();
            defer slot.end();
            if (a.view.sidebar_width > 0) {
                // Shrink only the viewport: rows retain their layout and slide
                // left beneath its clip, rather than squeezing their contents.
                const content = ui.div(c).absolute().offset(a.view.sidebar_width - sidebar.width, 0).w(sidebar.width).hFull();
                defer content.end();
                if (a.view.settings_open) settings_view.nav(c, a, k) else sidebar.sidebar(c, a, k);
                ui.div(c).absolute().offset(sidebar.width - 1, 0).size(1, c.size.h).bg(k.border).end();
            }
        }
        ui.key(c, "main-column");
        const main = ui.div(c).row().grow().w(0).hFull();
        defer main.end();
        column: {
            const chat = ui.div(c).column().grow().w(0).hFull().clip();
            defer chat.end();
            if (a.view.settings_open) {
                _ = c.leaf(.{ .width = .fill, .height = .{ .px = sidebar.titlebar_h } }, .none, null);
                settings_view.page(c, a, k);
                break :column;
            }
            header(c, a, k);
            if (a.tabs.layout()) |s| if (!s.zoomed) {
                panes(c, a, k, s);
            } else focused(c, a, k) else focused(c, a, k);
        }
        if (a.selected != null and a.panels.host_open) {
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
            @import("view_host.zig").host(c, a, k);
        }
        if (a.selected != null and a.panels.files_open) {
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
            @import("view_files.zig").explorer(c, a, k);
        }
    }
    titlebar(c, a, k);
    if (c.input.released) a.view.sidebar_press_focus = false;
    const popup = surfaces.popup(k);
    trailing(c, a, popup);
    @import("view_diffs.zig").overlays(c, a, popup);
    @import("view_actions.zig").overlays(c, a, popup);
    @import("view_menus.zig").menus(c, a, popup);
    @import("view_sidebar_menus.zig").menus(c, a, popup);
    @import("view_picker.zig").popover(c, a, popup);
    @import("view_drag.zig").overlay(c, a, popup);
    @import("view_chat_menu.zig").overlays(c, a, popup);
    // Over everything, as the GPUI app's deferred palette (priority 2).
    @import("view_palette.zig").overlay(c, a, popup);
    @import("app_browser.zig").syncNative(a, c);
}

/// The focused pane: its chat's transcript over the composer, or a new
/// chat's page.
fn focused(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.selected == null) {
        @import("view_newchat.zig").canvas(c, a, k);
    } else {
        transcript_view.transcript(c, a, k);
        @import("view_composer.zig").docked(c, a, k);
        @import("view_actions.zig").dock(c, a, k);
    }
}

/// A split's panes along its axis, each its share of the column; the
/// focused one is the tab's chat, the others its neighbors, read only
/// (`render_chat_split`, shell/chat_split.rs).
fn panes(c: *ui.Context, a: *App, k: theme.Colors, s: *tabs.Split) void {
    const across = s.axis == .horizontal;
    var box = ui.div(c).grow().wFull().h(0);
    box = if (across) box.row() else box.column();
    defer box.end();
    const total: f32 = if (across) transcript_view.mainWidth(c, a) else c.size.h - sidebar.titlebar_h;
    var focus: ?usize = null;
    const press = a.view.pane_press;
    if (c.input.pressed or c.input.released) a.view.pane_press = null;
    for (s.panes.items, s.shares.items, 0..) |chat, share, ix| {
        ui.key(c, c.print("pane-{d}", .{ix}));
        if (ix > 0) divider(c, a, k, ix, across, total);
        const size = @max(0, total * share - 1);
        var pane = ui.div(c).column().clip();
        pane = if (across) pane.w(size).hFull() else pane.h(size).wFull();
        defer pane.end();
        if (ix == s.focus) {
            focused(c, a, k);
            continue;
        }
        // A message's hover/copy controls are the top hit, not the pane.
        // Capture the whole subtree, then finish its action before focus
        // moves the transcript into the active outlet (as GPUI does).
        const it = pane.interaction();
        if (c.input.pressed and it.hovered) a.view.pane_press = .{ .tab = a.tabs.active, .pane = ix };
        if (c.input.released and it.hovered) if (press) |p| {
            if (p.tab == a.tabs.active and p.pane == ix) focus = ix;
        };
        if (neighbor(c, a, k, ix, chat, size)) return;
    }
    if (focus) |ix| a.focusPane(ix);
}

/// The line between two panes, and a 9-point grip on it: drag to share
/// the room differently, double-click to make them even
/// (`render_split_divider`).
fn divider(c: *ui.Context, a: *App, k: theme.Colors, ix: usize, across: bool, total: f32) void {
    const dragging = if (a.pane_drag) |d| d.divider == ix else false;
    var line = ui.div(c).bg(if (dragging) k.accent.alpha(0.7) else k.border);
    line = if (across) line.w(1).hFull() else line.h(1).wFull();
    defer line.end();
    var grip = ui.div(c).absolute();
    grip = if (across) grip.offset(-4, 0).w(9).hFull() else grip.offset(0, -4).h(9).wFull();
    defer grip.end();
    const it = grip.interaction();
    if (it.hovered or it.pressed) c.cursor = if (across) .resize_left_right else .resize_up_down;
    const at = if (across) c.input.mouse.x else c.input.mouse.y;
    if (it.double_clicked) {
        a.pane_drag = null;
        return a.tabs.equalize();
    }
    if (it.pressed) {
        if (a.pane_drag == null) {
            var d: tabs.Drag = .{ .divider = ix, .origin = at, .start = @splat(0) };
            const sh = a.tabs.layout().?.shares.items;
            @memcpy(d.start[0..sh.len], sh);
            a.pane_drag = d;
        }
        if (a.pane_drag) |d| if (d.divider == ix) a.tabs.dragDivider(d, (at - d.origin) / @max(total, 1));
    } else if (dragging) a.pane_drag = null;
}

/// A pane other than the focused one (`render_peer_chat_pane`): its title
/// and a ✕ that closes it, over its chat's transcript, dimmed; or, empty,
/// where a click starts a chat. True when the ✕ closed it.
fn neighbor(c: *ui.Context, a: *App, k: theme.Colors, ix: usize, chat_id: ?[]const u8, w: f32) bool {
    {
        const h = ui.div(c).row().wFull().h(30).px(14).gap(6).itemsCenter();
        defer h.end();
        const ch = if (chat_id) |id| a.findChat(id) else null;
        const title = if (ch) |x| sidebar.chatLabel(x) else if (chat_id != null) "Untitled session" else "New session";
        kit.ellipsisText(c, title, .{ .size = 12, .color = k.muted }, @max(w - 28 - 20 - 6, 0));
        ui.spacer(c);
        if (kit.iconButton(c, k, .close, .{ .size = 20, .radius = 5, .icon = 12 })) {
            a.focusPane(ix);
            a.closeFocused();
            return true;
        }
    }
    // Ghostty dims unfocused splits.
    const body = ui.div(c).column().grow().wFull().opacity(0.8);
    defer body.end();
    if (chat_id) |id| {
        if (a.peer(id)) |p| _ = transcript_view.entries(c, a, k, &p.transcript, w, p.watch != null, 8);
        return false;
    }
    const empty = ui.div(c).column().grow().wFull().px(16).gap(4).center();
    defer empty.end();
    ui.text(c, "Empty pane", .{ .size = 13, .color = k.muted.alpha(0.8) });
    const space = a.newChatSpace();
    ui.text(c, if (space) |sp| c.print("Click to start a session in {s}", .{sp.name}) else "Click to start a session", .{ .size = 11.5, .color = k.muted.alpha(0.55) });
    return false;
}

/// ⌘B the sidebar, ⌘T or ⌘N a new tab; ⌘D and ⌘⇧D split the chat, ⌘[ and
/// ⌘] step through its panes (through tabs with none), ⌥⌘ and ⌃⌘ with an
/// arrow focus and resize them, ⌃⌘= evens them, ⌘⇧↩ zooms one; ⌘W closes
/// the pane, then the tab; Escape closes what is open
/// (protocol/keymap-macos.json, the GPUI app's `shell::` bindings).
fn keys(c: *ui.Context, a: *App) void {
    const S = ui.Shortcut;
    // A shortcut being rebound takes the keys first.
    const rebinding = @import("view_settings_shortcuts.zig");
    if (rebinding.recording(a)) return rebinding.capture(c, a);
    // ⌘K, the command palette (fixed, as the GPUI app binds it); open, it
    // takes ↑↓, Return and Escape before anything else.
    const palette = @import("view_palette.zig");
    if (c.shortcut(@import("shortcuts.zig").command_palette)) palette.toggle(a, .preserve_tabs);
    palette.keys(c, a);
    if (a.picker != .none) @import("view_picker.zig").keys(c, a);
    // A dialog has the keys; else an open header menu takes Escape, the
    // arrows and Return.
    const chat_menu = @import("view_chat_menu.zig");
    const header_menus = @import("view_sidebar_menus.zig");
    // Settings › Accounts' sign-in dialog or device list, Archived's Delete
    // all or Devices' Rename takes Escape first.
    if (a.view.settings_open) {
        @import("view_settings_accounts.zig").escape(c, a);
        _ = @import("view_settings_archived.zig").escape(c, a);
        _ = @import("view_settings_devices.zig").escape(c, a);
        @import("view_settings_theme_import.zig").escape(c, a);
    }
    if (chat_menu.anyDialog(a)) {
        if (c.shortcut(.{ .key = S.escape })) chat_menu.dismiss(a);
    } else if (header_menus.anyOpen(a)) header_menus.keys(c, a) else if (!a.view.palette.open) {
        // The session search, while it holds the keys.
        @import("view_sidebar_search.zig").keys(c, a);
    }
    if (c.shortcut(.{ .key = 'b', .cmd = true })) toggleSidebar(c, a, false);
    if (c.shortcut(.{ .key = ',', .cmd = true })) settings_view.open(a);
    if (c.shortcut(.{ .key = 'l', .cmd = true })) a.view.focus_composer = true;
    if (a.selected != null and c.shortcut(.{ .key = 'e', .cmd = true })) @import("app_files.zig").toggle(a);
    if (a.selected != null and c.shortcut(.{ .key = 'r', .cmd = true })) @import("app_panels.zig").toggleHost(a);
    if (c.shortcut(.{ .key = 't', .cmd = true }) or c.shortcut(.{ .key = 'n', .cmd = true })) a.newTab();
    if (c.shortcut(.{ .key = 'w', .cmd = true })) a.closeFocused();
    if (c.shortcut(.{ .key = 'd', .cmd = true })) a.splitPane(.horizontal);
    if (c.shortcut(.{ .key = 'd', .cmd = true, .shift = true })) a.splitPane(.vertical);
    if (c.shortcut(.{ .key = '[', .cmd = true })) a.stepPane(false);
    if (c.shortcut(.{ .key = ']', .cmd = true })) a.stepPane(true);
    if (c.shortcut(.{ .key = S.enter, .cmd = true, .shift = true })) a.tabs.toggleZoom();
    if (c.shortcut(.{ .key = '=', .cmd = true, .ctrl = true })) a.tabs.equalize();
    const arrows = [_]struct { u21, tabs.Direction }{ .{ S.left, .left }, .{ S.right, .right }, .{ S.up, .up }, .{ S.down, .down } };
    for (arrows) |x| {
        if (c.shortcut(.{ .key = x[0], .cmd = true, .alt = true })) a.focusToward(x[1]);
        if (c.shortcut(.{ .key = x[0], .cmd = true, .ctrl = true })) a.tabs.resize(x[1]);
    }
    // A session menu or its dialog, over everything, takes Escape first.
    if (@import("view_chat_menu.zig").anyOpen(a) and c.shortcut(.{ .key = S.escape })) {
        @import("view_chat_menu.zig").dismiss(a);
    } else if (c.shortcut(.{ .key = S.escape }) and a.queue_edit == null) {
        a.picker = .none;
        a.view.filter_menu = false;
        a.view.more_menu = false;
        a.view.account_menu = false;
    }
}

/// Mouse and keyboard share search cleanup and return hidden controls' focus
/// to the composer. Motion is owned entirely by nanoui on the next layout.
fn toggleSidebar(c: *ui.Context, a: *App, pointer: bool) void {
    a.view.sidebar_open = !a.view.sidebar_open;
    if (!a.view.sidebar_open) {
        // A pointer press on the toggle may already have blurred the search
        // before its release invokes this helper.
        const search_focused = @import("view_sidebar_search.zig").hasFocus(a) or (pointer and a.view.sidebar_press_focus);
        const in_sidebar = if (c.rects.get(c.focus)) |r| r.x < a.view.sidebar_width else false;
        @import("view_sidebar_search.zig").close(a);
        a.view.search.focus = false;
        if (!a.view.settings_open and (search_focused or in_sidebar)) {
            c.focus = 0;
            a.view.focus_composer = true;
        }
    }
    a.redraw();
}

fn titlebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    // With no sidebar in view, a running cloud sandbox (billed until turned
    // off) still shows under the sidebar toggle. The GPUI app hides its
    // settings sidebar with the sidebar; this one keeps it, with the strip.
    if (!a.view.sidebar_open and !a.view.settings_open) @import("view_sandbox_strip.zig").chip(c, a, k);
    const bar = ui.div(c).fixed().offset(cluster_x, 4 + (34 - 24) / 2).row().itemsCenter().layer(3);
    defer bar.end();
    if (kit.iconButton(c, k, .@"sidebar-minimalistic-left", .{})) toggleSidebar(c, a, true);
    _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
    if (kit.iconButton(c, k, .@"arrow-left", .{ .disabled = !a.tabs.canStep(-1) })) a.showTab(a.tabs.active - 1);
    _ = c.leaf(.{ .width = .{ .px = 2 } }, .none, null);
    if (kit.iconButton(c, k, .@"arrow-right", .{ .disabled = !a.tabs.canStep(1) })) a.showTab(a.tabs.active + 1);
    if (a.selected != null) {
        _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
        if (kit.iconButton(c, k, .plus, .{})) a.newTab();
    }
}

/// The title bar's right end, over the panels: the files panel and the
/// surface pane's toggles (`shell/tabs.rs`); a new chat has none.
fn trailing(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.selected == null) return;
    const va = @import("view_actions.zig");
    const actions_w = va.controlWidth(c, a);
    // The actions control, the row's 8-point gap, then the two toggles 4
    // apart (`PANEL_TOGGLE_GAP`), 6 from the edge
    // (`TITLEBAR_ACTION_EDGE_INSET`).
    const w: f32 = 28 * 2 + 4 + (if (actions_w > 0) actions_w + 8 else 0);
    const bar = ui.div(c).fixed().offset(c.size.w - 6 - w, 4 + (34 - 28) / 2).row().itemsCenter().layer(3);
    defer bar.end();
    if (actions_w > 0) {
        va.control(c, a, k);
        _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
    }
    if (kit.iconButton(c, k, .@"file-tree", .{ .size = 28, .on = a.panels.files_open })) @import("app_files.zig").toggle(a);
    _ = c.leaf(.{ .width = .{ .px = 4 } }, .none, null);
    if (kit.iconButton(c, k, .@"sidebar-minimalistic", .{ .size = 28 })) @import("app_panels.zig").toggleHost(a);
}

/// The chat's identity in the title bar's row: its agent's mark, its title,
/// and "project @ device" (`shell/tabs.rs`).
fn header(c: *ui.Context, a: *App, k: theme.Colors) void {
    const side = a.view.sidebar_width;
    // Clear of the title bar's buttons, and 16 points into the main column.
    const left = @max(side + 16, cluster_x + cluster_w + 12 + 32) - side;
    const bar = ui.div(c).row().wFull().h(sidebar.titlebar_h).pt(4).pl(left).pr(6).gap(6).itemsCenter().clip();
    defer bar.end();
    const id = a.selected orelse return;
    const chat = a.findChat(id) orelse return;
    const mark = icons.harnessMark(chat.harness orelse "graff");
    icons.icon(c, mark.name, 14, mark.brand orelse k.muted, 0);
    const room = @import("view_transcript.zig").mainWidth(c, a) - left - 6 - 70;
    const title = sidebar.chatLabel(chat);
    const title_st: ui.TextStyle = .{ .size = 12, .weight = .medium, .color = k.text.alpha(0.85) };
    const title_w = @min(c.text.width(title, title_st), room * 0.6);
    kit.fadeText(c, title, title_st, title_w);
    const space = a.findSpace(chat.space_id);
    const where = c.print("{s} @ {s}", .{ if (space) |s| s.name else "~", a.deviceName(chat.device_id) });
    kit.fadeText(c, where, .{ .size = 12, .color = k.muted.alpha(0.5) }, room - title_w - 20 - 12);
}
