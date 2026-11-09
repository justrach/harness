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
const chrome = @import("panel_chrome.zig");
const strip = @import("view_tab_strip.zig");
const panel_chrome = @import("view_panel_chrome.zig");

/// Where the title bar's buttons start: right of the traffic lights.
const cluster_x: f32 = 88;
/// Three 24-point buttons, 8 then 2 points apart.
const cluster_w: f32 = 24 * 3 + 8 + 2;

pub fn view(a: *App, c: *ui.Context) void {
    @import("frame_profile.zig").beginPass();
    a.view.in_pre_tree = true;
    defer a.view.in_pre_tree = false;
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
    // A loader or a once-a-second clock must not become the display-link
    // rate in the middle of a scroll. The link takes the soonest request.
    if (c.scroll_moved.count() > 0) c.frameIn(1.0 / 120.0);
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
    @import("view_settings_devices_updates.zig").settleFrame(a);
    // Capture once, before drawing the search can blur it on a pointer
    // press. An open but unfocused search must not steal another field.
    if (c.input.pressed and a.view.sidebar_press_frame != c.frame) {
        a.view.sidebar_press_frame = c.frame;
        const focused_sidebar = if (c.rects.get(c.focus)) |r| r.x < a.view.sidebar_width else false;
        a.view.sidebar_press_focus = @import("view_sidebar_search.zig").hasFocus(a) or focused_sidebar;
        // A press out of a menu holding the keys closes it and drops them,
        // to no one: its focus handle goes with it (`restore_mounted_focus`).
        a.view.press_kept_keys = a.view.sidebar_press_focus or menuKeepsKeys(a);
    }
    strip.settle(a);
    keys(c, a);
    a.syncPeers();
    a.view.in_pre_tree = false;
    if (a.view.menus.overview.open and !a.view.settings_open) {
        @import("view_sessions.zig").page(c, a, k);
        @import("view_palette.zig").overlay(c, a, surfaces.popup(k));
        @import("view_chat_menu.zig").overlays(c, a, surfaces.popup(k));
        @import("view_project_setup.zig").overlay(c, a, surfaces.popup(k));
        @import("view_open_chooser.zig").overlay(c, a, surfaces.popup(k));
        @import("view_setup.zig").overlay(c, a, k);
        @import("app_browser.zig").syncNative(a, c);
        @import("frame_profile.zig").frame(a, c);
        return;
    }
    {
        const root = ui.div(c).row().sizeFull().bg(k.shell);
        defer root.end();
        // One retained seam tween, independent of the sidebar's mount state.
        // CSS ease-out (cubic-bezier(0, 0, 0.58, 1)) over 200ms, as GPUI's
        // RESIZE. A resize does not restart it, and a reversed Cmd+B takes
        // over at the seam's current position.
        const side_width = a.settings.sidebarWidth();
        const target_width: f32 = if (a.view.sidebar_open or a.view.settings_open) side_width else 0;
        if (!a.view.sidebar_ready) {
            a.view.sidebar_width = target_width;
            a.view.sidebar_ready = true;
            a.view.sidebar_tween = null;
        } else if (a.view.settings_open) {
            a.view.sidebar_width = side_width;
            a.view.sidebar_tween = null;
        } else if (c.reduced_motion) {
            a.view.sidebar_width = target_width;
            a.view.sidebar_tween = null;
        } else {
            var tween = a.view.sidebar_tween;
            if (tween == null and @abs(a.view.sidebar_width - target_width) > 0.01) {
                const start_time = if (a.window != null and !a.offscreen) c.time - (1.0 / 120.0) else c.time;
                tween = .{ .from = a.view.sidebar_width, .to = target_width, .started = start_time };
            }
            if (tween) |*tw| {
                if (tw.started == null) tw.started = c.time;
                if (tw.to != target_width) {
                    const previous_raw: f32 = @floatCast(std.math.clamp((c.time - (tw.started orelse c.time)) / 0.2, 0, 1));
                    const previous_eased = ui.motion.Easing.css_ease_out.sample(previous_raw)[0];
                    tw.from = tw.from + (tw.to - tw.from) * previous_eased;
                    tw.to = target_width;
                    tw.started = c.time;
                }
                const raw: f32 = @floatCast(std.math.clamp((c.time - (tw.started orelse c.time)) / 0.2, 0, 1));
                if (raw >= 1) {
                    a.view.sidebar_width = target_width;
                    tween = null;
                } else {
                    const eased = ui.motion.Easing.css_ease_out.sample(raw)[0];
                    a.view.sidebar_width = tw.from + (tw.to - tw.from) * eased;
                    c.frame_in = null;
                    c.animationFrame();
                }
            }
            a.view.sidebar_tween = tween;
        }
        @import("view_drag.zig").update(c, a);
        {
            ui.key(c, "sidebar-slot");
            const slot = ui.div(c).w(a.view.sidebar_width).hFull().clip();
            defer slot.end();
            if (a.view.sidebar_width > 0) {
                // Shrink only the viewport: rows retain their layout and slide
                // left beneath its clip, rather than squeezing their contents.
                const content = ui.div(c).absolute().offset(a.view.sidebar_width - side_width, 0).w(side_width).hFull();
                defer content.end();
                if (a.view.settings_open) settings_view.nav(c, a, k) else sidebar.sidebar(c, a, k);
                // Workspace panels own their entire rounded outline; there is
                // no longer a full-height border at the sidebar's edge.
                if (a.view.settings_open and !k.is_harp) ui.div(c).absolute().offset(side_width - 1, 0).size(1, c.size.h).bg(k.border).end();
            }
        }
        a.view.seam_inset = 2;
        const layout = a.tabs.layout();
        a.view.chrome = chrome.frameWithSide(c.size.w, c.size.h, a.view.sidebar_width, side_width, strip.chatCount(a), if (layout) |s| s.axis == .horizontal else true, strip.hasHost(a), strip.hasFiles(a), a.settings.rightPaneWidth());
        ui.key(c, "main-column");
        const main = ui.div(c).column().grow().w(0).hFull();
        defer main.end();
        if (a.view.settings_open) {
            if (k.is_harp) {
                const wrap = ui.div(c).row().pt(sidebar.titlebar_h + 8).pr(8).pb(8).hFull().wFull();
                defer wrap.end();
                const card = ui.div(c).column().grow().w(0).hFull().p(1).rounded(10).border(k.border).borderW(1).bg(k.background);
                defer card.end();
                settings_view.page(c, a, k);
            } else {
                _ = c.leaf(.{ .width = .fill, .height = .{ .px = sidebar.titlebar_h } }, .none, null);
                settings_view.page(c, a, k);
            }
        } else {
            const workspace = ui.div(c).row().pt(chrome.header_height).pl(a.view.chrome.leading).pr(chrome.gutter).pb(chrome.gutter).hFull().wFull();
            defer workspace.end();
            const expanded = a.view.strip.expanded;
            if (expanded == null or expanded.? == .chat) {
                const only = expanded != null;
                if (only) a.view.chrome.chat_width = a.view.chrome.width;
                const chat = ui.div(c).column().w(a.view.chrome.chat_width).hFull();
                defer chat.end();
                if (a.tabs.layout()) |s| {
                    if (!s.zoomed and !only and s.panes.items.len > 1) panes(c, a, k, s) else chatPanel(c, a, k);
                } else chatPanel(c, a, k);
            }
            if (strip.hasHost(a) and (expanded == null or expanded.? == .host)) {
                if (expanded == null) ui.div(c).w(chrome.gutter).hFull().end();
                if (expanded != null) a.view.chrome.host_width = a.view.chrome.width;
                const host = panel_chrome.body(c, k).w(a.view.chrome.host_width).hFull().clip();
                defer host.end();
                if (c.input.pressed and host.interaction().hovered) a.view.strip.focused = .host;
                @import("view_host.zig").host(c, a, k);
            }
            if (strip.hasFiles(a) and (expanded == null or expanded.? == .files)) {
                if (expanded == null) ui.div(c).w(chrome.gutter).hFull().end();
                if (expanded != null) a.view.chrome.files_width = a.view.chrome.width;
                const files = panel_chrome.body(c, k).w(a.view.chrome.files_width).hFull().clip();
                defer files.end();
                if (c.input.pressed and files.interaction().hovered) a.view.strip.focused = .files;
                @import("view_files.zig").explorer(c, a, k);
            }
        }
    }
    strip.draw(c, a, k);
    titlebar(c, a, k);
    if (c.input.released) a.view.sidebar_press_focus = false;
    const popup = surfaces.popup(k);
    trailing(c, a, popup);
    @import("view_diffs.zig").overlays(c, a, popup);
    @import("view_actions.zig").overlays(c, a, popup);
    @import("view_menus.zig").menus(c, a, popup);
    @import("view_sidebar_menus.zig").menus(c, a, popup);
    @import("view_picker.zig").popover(c, a, popup);
    @import("view_context.zig").overlay(c, a, popup);
    @import("view_drag.zig").overlay(c, a, popup);
    @import("view_chat_menu.zig").overlays(c, a, popup);
    closeChoice(c, a, popup);
    @import("view_updates.zig").overlayCard(c, a, popup);
    // Over everything, as the GPUI app's deferred palette (priority 2).
    @import("view_palette.zig").overlay(c, a, popup);
    @import("view_project_setup.zig").overlay(c, a, popup);
    @import("view_open_chooser.zig").overlay(c, a, popup);
    // First-run setup, over the whole window.
    @import("view_setup.zig").overlay(c, a, k);
    @import("app_browser.zig").syncNative(a, c);
    // After the overlays: a click that opens a menu has opened it.
    if (handsKeysBack(.{
        .released = c.input.released,
        .composer_drawn = a.view.composer_frame == c.frame,
        .nothing_focused = c.focus == 0,
        .kept = a.view.press_kept_keys or menuKeepsKeys(a),
    })) {
        // In the next frame, not this one again: what a release leaves for
        // the next frame's start (a drop's split) must not run under this one.
        a.view.focus_composer = true;
        c.frameIn(0);
    }
    @import("frame_profile.zig").frame(a, c);
}

/// A menu that takes the keys for itself (`window.focus` as it opens): the
/// composer's border and caret go quiet while it's up. The account menu has
/// no focus of its own, so it isn't one.
pub fn menuKeepsKeys(a: *const App) bool {
    const v = &a.view;
    return v.project_setup.open or v.open_chooser.open or v.strip.menu != null or v.more_menu or v.filter_menu or v.space_menu or v.checkout_menu or v.chat_menu.open or
        v.menus.ctx_at != null or v.menus.overview.open or v.palette.open or a.picker != .none;
}

/// A press lands on the window's root unless something nearer takes focus,
/// and the root passes the keys to the composer on the next frame
/// (`restore_mounted_focus`). Escape's blur isn't a press, so it stays. The
/// keys go at the release, once the click has opened whatever it opens.
pub fn handsKeysBack(s: struct { released: bool, composer_drawn: bool, nothing_focused: bool, kept: bool }) bool {
    return s.released and s.composer_drawn and s.nothing_focused and !s.kept;
}

/// The column's corners where it meets the open sidebar (`SEAM_RADIUS`).
const seam_radius: f32 = 12;

/// Whether the column rounds where it meets the sidebar: open at least two
/// radii wide, as GPUI's `seam_rounded`. Frosted glass keeps the straight
/// edge: its corners can't be filled with an opaque tone.
fn seamRounded(a: *const App, k: theme.Colors) bool {
    return !k.frosted and a.view.sidebar_width >= 2 * seam_radius;
}

/// The rounded seam (2bc9308f3): the hairline down the column's left edge
/// and, in each left corner, the sidebar's tone outside a quarter circle of
/// the column's colour whose edge carries the same hairline.
fn seam(c: *ui.Context, a: *App, k: theme.Colors) void {
    const x = a.view.sidebar_width;
    const r = seam_radius;
    ui.key(c, "sidebar-seam");
    ui.div(c).absolute().offset(x, r).size(1, @max(0, c.size.h - 2 * r)).bg(k.border).end();
    for ([_]f32{ 0, c.size.h - r }) |y| {
        const box = ui.div(c).absolute().offset(x, y).size(r, r).clip().bg(k.sidebar);
        defer box.end();
        // The circle's other three quarters fall outside the clip.
        const disc = ui.div(c).absolute().offset(0, if (y == 0) 0 else -r).size(2 * r, 2 * r).rounded(r).bg(k.column()).border(k.border).borderW(1);
        disc.end();
    }
}

/// The focused pane: its chat's transcript over the composer, or a new
/// chat's page.
fn chatPanel(c: *ui.Context, a: *App, k: theme.Colors) void {
    const panel = panel_chrome.body(c, k).grow().wFull().h(0);
    defer panel.end();
    if (c.input.pressed and panel.interaction().hovered) a.view.strip.focused = .{ .chat = if (a.tabs.layout()) |s| s.focus else 0 };
    if (strip.rendering.selectedBounds(a)) |selected| panel_chrome.join(c, k, a.view.chrome.chat_width, selected.left, selected.right);
    // Decorative shoulders change node count as the sidebar slides; the
    // writing subtree must keep its identity and keyboard focus.
    ui.key(c, "chat-panel-content");
    const content = ui.div(c).column().grow().wFull().h(0).rounded(9).clip();
    defer content.end();
    focused(c, a, k);
}

fn focused(c: *ui.Context, a: *App, k: theme.Colors) void {
    // The Write page takes the pane: the transcript and composer step aside.
    if (a.view.write_open) return @import("view_write.zig").page(c, a, k, transcript_view.paneWidth(c, a));
    if (a.selected == null) {
        @import("view_newchat.zig").canvas(c, a, k);
    } else {
        @import("view_actions.zig").toolbar(c, a, k);
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
    const total: f32 = if (across) a.view.chrome.chat_width else a.view.chrome.height;
    var focus: ?usize = null;
    const press = a.view.pane_press;
    if (c.input.pressed or c.input.released) a.view.pane_press = null;

    // A new split grows from the geometry it replaced. Copy the reveal so
    // clearing it at the end cannot pull the widths out from under this frame.
    var reveal: ?@import("app.zig").SplitReveal = null;
    var reveal_t: f32 = 1;
    if (a.view.split_reveal) |saved| {
        var r = saved;
        if (r.tab != a.tabs.active or r.new_index >= s.panes.items.len) {
            a.view.split_reveal = null;
        } else {
            if (r.started == null) {
                r.started = c.time;
                a.view.split_reveal = r;
            }
            const duration: f64 = 0.24;
            const raw: f32 = if (c.reduced_motion) 1 else @floatCast(std.math.clamp((c.time - (r.started orelse c.time)) / duration, 0, 1));
            const inverse = 1 - raw;
            reveal_t = if (c.reduced_motion) 1 else 1 - inverse * inverse * inverse * inverse * inverse;
            reveal = r;
            if (raw >= 1) {
                a.view.split_reveal = null;
            } else {
                c.frame_in = null;
                c.animationFrame();
            }
        }
    }

    for (s.panes.items, s.shares.items, 0..) |chat, share, ix| {
        ui.key(c, c.print("pane-{d}", .{ix}));
        if (ix > 0) divider(c, a, k, ix, across, total);
        const target = chrome.paneSpan(total, share, s.panes.items.len, across);
        const size = if (reveal) |r| revealSpan(total, across, r, ix, target, reveal_t) else target;
        var pane = panel_chrome.body(c, k).clip();
        pane = if (across) pane.w(size).hFull() else pane.h(size).wFull();
        defer pane.end();
        if (c.input.pressed and pane.interaction().hovered) a.view.strip.focused = .{ .chat = ix };
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
    if (focus) |ix| strip.focus(a, .{ .chat = ix });
}

/// One pane's width on the split insertion curve: old panes dissolve their
/// previous spans into the even split while the inserted pane opens from 0.
pub fn revealSpan(total: f32, across: bool, r: @import("app.zig").SplitReveal, ix: usize, target: f32, t: f32) f32 {
    if (ix == r.new_index) return target * t;
    const old_ix = if (ix < r.new_index) ix else ix - 1;
    if (old_ix >= r.old_count) return target;
    const old = chrome.paneSpan(total, r.from_shares[old_ix], r.old_count, across);
    return old + (target - old) * t;
}

/// The line between two panes, and a 9-point grip on it: drag to share
/// the room differently, double-click to make them even
/// (`render_split_divider`).
fn divider(c: *ui.Context, a: *App, k: theme.Colors, ix: usize, across: bool, total: f32) void {
    const dragging = if (a.pane_drag) |d| d.divider == ix else false;
    const gap = if (across) chrome.gutter else chrome.tab_top;
    var line = ui.div(c);
    if (dragging) line = line.bg(k.accent.alpha(0.2));
    line = if (across) line.w(gap).hFull() else line.h(gap).wFull();
    defer line.end();
    var grip = ui.div(c).absolute();
    grip = if (across) grip.offset((gap - 9) / 2, 0).w(9).hFull() else grip.offset(0, (gap - 9) / 2).h(9).wFull();
    defer grip.end();
    const it = grip.interaction();
    if (it.hovered or it.pressed) c.cursor = if (across) .resize_left_right else .resize_up_down;
    const at = if (across) c.input.mouse.x else c.input.mouse.y;
    if (it.double_clicked) {
        a.pane_drag = null;
        a.tabs.equalize();
        a.rememberTabs();
        return;
    }
    if (it.pressed) {
        if (a.pane_drag == null) {
            var d: tabs.Drag = .{ .divider = ix, .origin = at, .start = @splat(0) };
            const sh = a.tabs.layout().?.shares.items;
            @memcpy(d.start[0..sh.len], sh);
            a.pane_drag = d;
        }
        if (a.pane_drag) |d| if (d.divider == ix) a.tabs.dragDivider(d, (at - d.origin) / @max(total, 1));
    } else if (dragging) {
        a.pane_drag = null;
        a.rememberTabs();
    }
}

/// A pane other than the focused one (`render_peer_chat_pane`): its title
/// and a ✕ that closes it, over its chat's transcript, dimmed; or, empty,
/// where a click starts a chat. True when the ✕ closed it.
fn neighbor(c: *ui.Context, a: *App, k: theme.Colors, ix: usize, chat_id: ?[]const u8, w: f32) bool {
    _ = ix;
    // The strip is this panel's only header, even when unfocused.
    if (chat_id) |id| {
        if (a.peer(id)) |p| _ = transcript_view.entries(c, a, k, &p.transcript, w, p.watch != null, 8);
        return false;
    }
    const body = ui.div(c).column().grow().wFull();
    defer body.end();
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
    // First-run setup covers the window and has every key.
    if (@import("view_setup.zig").keys(c, a)) return;
    if (@import("view_project_setup.zig").keys(c, a)) return;
    if (@import("view_open_chooser.zig").keys(c, a)) return;
    // ⌘K, the command palette (fixed, as the GPUI app binds it); open, it
    // takes ↑↓, Return and Escape before anything else.
    const palette = @import("view_palette.zig");
    if (c.shortcut(@import("shortcuts.zig").command_palette)) palette.toggle(a, .preserve_tabs);
    const chat_menu = @import("view_chat_menu.zig");
    if (chat_menu.anyDialog(a)) {
        if (c.shortcut(.{ .key = S.escape })) chat_menu.dismiss(a);
        return;
    }
    const palette_had_keys = a.view.palette.open;
    palette.keys(c, a);
    // All sessions is a full route, not a sheet over a live composer.
    // Closing its history palette must not also close the overview.
    if (a.view.menus.overview.open and !a.view.settings_open) {
        if (!palette_had_keys) @import("view_sessions.zig").keys(c, a);
        return;
    }
    if (a.picker != .none) @import("view_picker.zig").keys(c, a);
    // A dialog has the keys; else an open header menu takes Escape, the
    // arrows and Return.
    const header_menus = @import("view_sidebar_menus.zig");
    // Settings › Accounts' sign-in dialog or device list, Archived's Delete
    // all or Devices' Rename takes Escape first.
    if (a.view.settings_open) {
        @import("view_settings_accounts.zig").escape(c, a);
        _ = @import("view_settings_archived.zig").escape(c, a);
        _ = @import("view_settings_devices.zig").escape(c, a);
        @import("view_settings_theme_import.zig").escape(c, a);
    }
    if (strip.navigationKeys(c, a)) return;
    if (a.view.strip.menu != null) {
        strip.keys(c, a);
        return;
    }
    if (chat_menu.anyDialog(a)) {
        if (c.shortcut(.{ .key = S.escape })) chat_menu.dismiss(a);
    } else if (header_menus.anyOpen(a)) header_menus.keys(c, a) else if (!a.view.palette.open) {
        // The session search, while it holds the keys.
        @import("view_sidebar_search.zig").keys(c, a);
    }
    if (c.shortcut(.{ .key = 'b', .cmd = true })) {
        @import("frame_profile.zig").note(a, "cmd-b");
        c.changed = false;
        toggleSidebar(c, a, false);
    }
    if (c.shortcut(.{ .key = ',', .cmd = true })) settings_view.open(a);
    if (boundShortcut(c, a, "newProject")) {
        @import("app_open_chooser.zig").open(a, .new_project);
        return;
    }
    // The Write page, from the composer's place (`ToggleWriteDocument`); the
    // page takes the same keys back itself.
    if (!a.view.write_open and !a.view.settings_open and a.picker == .none and c.shortcut(@import("view_write.zig").toggle)) @import("view_write.zig").open(a);
    // ⌘F (`open_sidebar_search`): the sidebar, then its search, focused.
    if (!a.view.settings_open and a.picker == .none and c.shortcut(.{ .key = 'f', .cmd = true })) {
        if (!a.view.sidebar_open) toggleSidebar(c, a, false);
        const search = @import("view_sidebar_search.zig");
        if (!a.view.search.open) search.toggle(a) else a.view.search.focus = true;
    }
    if (a.selected != null and c.shortcut(.{ .key = 'e', .cmd = true })) @import("app_files.zig").toggle(a);
    if (a.selected != null and c.shortcut(.{ .key = 'r', .cmd = true })) @import("app_panels.zig").toggleHost(a);
    if (c.shortcut(.{ .key = 't', .cmd = true }) or c.shortcut(.{ .key = 'n', .cmd = true })) a.newTab();
    if (c.shortcut(.{ .key = 'j', .cmd = true, .shift = true })) strip.nextAttention(a);
    for (0..@min(strip.count(a), 6)) |ix| {
        if (c.shortcut(.{ .key = @as(u21, '1') + @as(u21, @intCast(ix)), .cmd = true, .alt = true })) {
            const chats = strip.chatCount(a);
            strip.focus(a, if (ix < chats) .{ .chat = ix } else if (strip.hasHost(a) and ix == chats) .host else .files);
        }
    }
    if (a.view.strip.menu != null and c.shortcut(.{ .key = S.escape })) {
        a.view.strip.menu = null;
        a.redraw();
    }
    // The first ⌘W's question: Escape dismisses it, Enter confirms close without archiving.
    if (a.view.close_choice and c.shortcut(.{ .key = S.escape })) {
        a.view.close_choice = false;
        a.redraw();
    }
    if (a.view.close_choice and c.shortcut(.{ .key = S.enter })) {
        a.chooseCloseArchiving(false);
    }
    if (c.shortcut(.{ .key = 'w', .cmd = true })) a.closeByShortcut();
    // Close without archiving (⌥⌘W, rebindable): never asks, never archives.
    if (closeOnlyPressed(c, a)) a.closeArchiving(false);
    if (c.shortcut(.{ .key = 'd', .cmd = true })) strip.splitChoosingFolder(a, .horizontal);
    if (c.shortcut(.{ .key = 'd', .cmd = true, .shift = true })) strip.splitChoosingFolder(a, .vertical);
    if (c.shortcut(.{ .key = S.enter, .cmd = true, .shift = true })) strip.queue(a, .{ .zoom = strip.active(a) });
    if (c.shortcut(.{ .key = '=', .cmd = true, .ctrl = true })) {
        a.tabs.equalize();
        a.rememberTabs();
    }
    const arrows = [_]struct { u21, tabs.Direction }{ .{ S.left, .left }, .{ S.right, .right }, .{ S.up, .up }, .{ S.down, .down } };
    for (arrows) |x| {
        if (c.shortcut(.{ .key = x[0], .cmd = true, .ctrl = true })) {
            a.tabs.resize(x[1]);
            a.rememberTabs();
        }
    }
    // A session menu or its dialog, over everything, takes Escape first.
    if (@import("view_chat_menu.zig").anyOpen(a) and c.shortcut(.{ .key = S.escape })) {
        @import("view_chat_menu.zig").dismiss(a);
    } else if (a.view.write_open and !a.view.palette.open and a.picker == .none and c.shortcut(.{ .key = S.escape })) {
        // The global fallback must not swallow Write's Save/back gesture.
        @import("view_write.zig").close(a);
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

/// The close badges as the keys read (`close_shortcut_badges`): ⌘W, and
/// the close-without-archiving shortcut as bound.
pub fn closeBadges(c: *ui.Context, a: *App) [2][]const u8 {
    const sc = @import("shortcuts.zig");
    const close = c.alloc().alloc(u8, 32) catch return .{ "", "" };
    const only = c.alloc().alloc(u8, 32) catch return .{ "", "" };
    var combo: []const u8 = "mod-alt-w";
    for (sc.all) |entry| if (std.mem.eql(u8, entry.key, "closeTabWithoutArchiving")) {
        combo = a.settings.combo(entry);
    };
    return .{ sc.badge(close, "mod-w"), sc.badge(only, combo) };
}

/// The first ⌘W's question (`render_archive_choice_dialog`): ✕ dismisses,
/// "Archive it" or "Just close it" saves the default and closes.
fn closeChoice(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!a.view.close_choice) return;
    const ac = @import("archive_close.zig");
    const menu = @import("view_chat_menu.zig");
    const b = closeBadges(c, a);
    const back = menu.scrim(c, k);
    defer back.end();
    const card = menu.dialog(c, k);
    defer card.end();
    {
        ui.key(c, "archive-choice-dismiss");
        const x = ui.div(c).row().absolute().offset(360 - 2 - 8 - 20, 8).size(20, 20).center().rounded(5).hover(k.ink(0.08));
        defer x.end();
        icons.icon(c, .close, 12, k.muted, 0);
        if (x.clicked()) {
            a.view.close_choice = false;
            return a.redraw();
        }
    }
    _ = c.leaf(.{ .height = .{ .px = 12 } }, .none, null);
    const title = c.alloc().alloc(u8, 96) catch return;
    ui.text(c, ac.choiceTitle(title, b[0]), .{ .size = 15, .line_height = kit.measured(15 * 1.618), .weight = .semibold, .wrap = true, .color = k.text });
    _ = c.leaf(.{ .height = .{ .px = 6 } }, .none, null);
    const body = c.alloc().alloc(u8, 480) catch return;
    ui.text(c, ac.choiceBody(body, b[1]), .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
    _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
    const r = ui.div(c).row().wFull().gap(8).justifyEnd();
    defer r.end();
    var pick: ?bool = null;
    {
        ui.key(c, "archive-choice-archive");
        const g = ui.div(c).row().px(12).py(6).rounded(8).hover(k.ink(0.06));
        defer g.end();
        ui.text(c, "Archive it", .{ .size = 13, .line_height = kit.measured(13 * 1.618), .color = if (g.hovered()) k.text else k.muted });
        if (g.clicked()) pick = true;
    }
    {
        ui.key(c, "archive-choice-close");
        const p = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
        defer p.end();
        ui.text(c, "Just close it", .{ .size = 13, .line_height = kit.measured(13 * 1.618), .weight = .medium, .color = k.on_solid });
        if (p.clicked()) pick = false;
    }
    if (pick) |archive| a.chooseCloseArchiving(archive);
}

/// A rebindable command, matched exactly as Settings › Shortcuts stores it.
fn boundShortcut(c: *ui.Context, a: *App, key: []const u8) bool {
    const sc = @import("shortcuts.zig");
    const pressed = c.input.shortcut orelse return false;
    var buf: [64]u8 = undefined;
    const combo = sc.fromShortcut(&buf, pressed) orelse return false;
    for (sc.all) |entry| if (std.mem.eql(u8, entry.key, key)) {
        if (!std.mem.eql(u8, combo, a.settings.combo(entry))) return false;
        return c.shortcut(pressed);
    };
    return false;
}

/// The close-without-archiving shortcut as Settings › Shortcuts binds it.
fn closeOnlyPressed(c: *ui.Context, a: *App) bool {
    const sc = @import("shortcuts.zig");
    const s = c.input.shortcut orelse return false;
    var buf: [32]u8 = undefined;
    const pressed = sc.fromShortcut(&buf, s) orelse return false;
    for (sc.all) |entry| if (std.mem.eql(u8, entry.key, "closeTabWithoutArchiving")) {
        if (!std.mem.eql(u8, pressed, a.settings.combo(entry))) return false;
        return c.shortcut(s);
    };
    return false;
}

fn titlebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    // With no sidebar in view, a running cloud sandbox (billed until turned
    // off) still shows under the sidebar toggle. The GPUI app hides its
    // settings sidebar with the sidebar; this one keeps it, with the strip.
    if (!a.view.sidebar_open and !a.view.settings_open) @import("view_sandbox_strip.zig").chip(c, a, k);
    const bar = ui.div(c).fixed().offset(cluster_x, 4 + (34 - 24) / 2).row().itemsCenter().layer(3);
    defer bar.end();
    ui.key(c, "workspace-sidebar-toggle");
    if (kit.iconButton(c, k, .@"sidebar-minimalistic-left", .{ .tip = .{ .text = "Toggle sidebar" } })) toggleSidebar(c, a, true);
    // The history control arrives when the seam finishes collapsing rather
    // than on the ⌘B press, so it never pops over the still-sliding sidebar.
    if (a.view.sidebar_width <= 1 or a.view.settings_open) {
        ui.div(c).w(4).end();
        ui.key(c, "titlebar-chat-history");
        const history = ui.div(c).row().size(24, 24).center().rounded(6).hover(k.hover).control();
        defer history.end();
        icons.icon(c, .@"clock-circle", 16, k.muted, 0);
        if (history.clicked()) strip.open(a, .history, strip.active(a), c.rects.get(c.node(history.index).id));
    }
    @import("view_updates.zig").titlebarControl(c, a, k);
}

/// The title bar's right end, over the panels: the files panel and the
/// surface pane's toggles (`shell/tabs.rs`); a new chat has none.
fn trailing(c: *ui.Context, a: *App, k: theme.Colors) void {
    // Workspace controls belong to each slot's menu, not over the strip.
    if (!a.view.settings_open or a.selected == null) return;
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
    // The header is the title bar's (GPUI draws it there), not inside the
    // seam's border the column's content is.
    const left = @max(side + 16, cluster_x + cluster_w + 12 + 32) - side - a.view.seam_inset;
    const bar = ui.div(c).row().wFull().h(sidebar.titlebar_h).pt(4).pl(left).pr(6).gap(6).itemsCenter().clip();
    defer bar.end();
    const id = a.selected orelse return;
    const chat = a.findChat(id) orelse return;
    const mark = icons.harnessMark(chat.harness orelse "graff");
    icons.icon(c, mark.name, 14, mark.brand orelse k.muted, 0);
    const room = @import("view_transcript.zig").contentWidth(c, a) - left - 6 - 70;
    const title = sidebar.chatLabel(chat);
    const title_st: ui.TextStyle = .{ .size = 12, .weight = .medium, .color = k.text.alpha(0.85) };
    const title_w = @min(c.text.width(title, title_st), room * 0.6);
    kit.fadeText(c, title, title_st, title_w);
    const space = a.findSpace(chat.space_id);
    const where = c.print("{s} @ {s}", .{ if (space) |s| s.name else "~", a.deviceName(chat.device_id) });
    kit.fadeText(c, where, .{ .size = 12, .color = k.muted.alpha(0.5) }, room - title_w - 20 - 12);
}
