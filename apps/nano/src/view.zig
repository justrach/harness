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

test {
    _ = @import("tests_selection_retention.zig");
    _ = @import("peer_message.zig");
}

test "retention selection fully masked horizontal text cannot capture a gutter drag" {
    const Probe = struct {
        fn draw(_: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().wFull().hFull();
            c.node(root.index).style.selectable = true;
            defer root.end();
            const masked = ui.div(c).absolute().offset(0, 0).size(20, 24).clip();
            const hidden = ui.div(c).absolute().offset(30, 0).w(100);
            ui.text(c, "Hidden text", .{ .size = 14 });
            hidden.end();
            masked.end();
            const visible = ui.div(c).absolute().offset(100, 0).w(120);
            ui.text(c, "Visible text", .{ .size = 14 });
            visible.end();
        }
    };
    @import("theme.zig").registerFonts();
    var probe: Probe = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&probe, Probe.draw), .{ .width = 300, .height = 100 });
    defer t.deinit();
    t.settle(0.1);
    const leaf = findNearestSelectableLeaf(&t.ctx, .{ .x = 10, .y = 10 }) orelse return error.NoSelectionCandidate;
    try std.testing.expectEqualStrings("Visible text", t.ctx.nodes.items[leaf.index].content.text.str);
}

/// Where the title bar's buttons start: right of the traffic lights.
const cluster_x: f32 = @import("window_chrome.zig").leading;
/// Three 24-point buttons, 8 then 2 points apart.
const cluster_w: f32 = 24 * 3 + 8 + 2;

pub fn view(a: *App, c: *ui.Context) void {
    @import("performance.zig").begin(a, c);
    a.markdown_cache.beginFrame();
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
    c.setZoom(a.settings.uiFontSize() / 16.0);
    @import("view_transcript.zig").column_w = @import("view_settings_appearance.zig").transcriptWidth(a);
    a.ansi = k.ansi;
    if (a.tick(c.time)) |wait| c.frameIn(wait);
    // A loader or a once-a-second clock must not become the display-link
    // rate in the middle of a scroll. The link takes the soonest request.
    if (c.scroll_moved.count() > 0) c.frameIn(1.0 / 120.0);
    if (a.view.last_win_w > 0 and (@abs(c.size.w - a.view.last_win_w) > 0.5 or @abs(c.size.h - a.view.last_win_h) > 0.5)) {
        a.view.resize_until = c.time + 0.16;
    }
    a.view.last_win_w = c.size.w;
    a.view.last_win_h = c.size.h;
    if (!a.offscreen and c.time < a.view.resize_until) c.frameIn(1.0 / 120.0);
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
    @import("pane_gesture.zig").observe(a, c);
    settleSelectionPreTree(a, c);
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
    @import("view_attachment_drop.zig").prepare(a);
    if (!@import("github_images.zig").keys(c, a)) keys(c, a);
    c.setZoom(a.settings.uiFontSize() / 16.0);
    if (!a.offscreen and c.time < a.view.resize_until) c.frameIn(1.0 / 120.0);
    a.syncPeers();
    a.view.in_pre_tree = false;
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
        a.view.chrome = chrome.frameWithSide(c.size.w, c.size.h, a.view.sidebar_width, side_width, strip.chatCount(a), if (layout) |s| s.axis == .horizontal and !s.zoomed else true, strip.hasHost(a), strip.hasFiles(a), a.settings.rightPaneWidth());
        ui.key(c, "main-column");
        const main = ui.div(c).column().grow().w(0).hFull();
        defer main.end();
        if (a.view.settings_open) {
            if (k.is_harp) {
                const wrap = ui.div(c).row().pt(sidebar.titlebar_h + 8).pr(8).pb(8).hFull().wFull();
                defer wrap.end();
                const card = ui.div(c).column().grow().w(0).hFull().p(1).rounded(10).border(k.border).borderW(1).bg(k.background).clip();
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
                const nested_github = githubChildInSplit(a);
                const chat = ui.div(c).column().w(a.view.chrome.chat_width + (if (nested_github) a.view.chrome.host_width + chrome.gutter else 0)).hFull();
                defer chat.end();
                if (a.tabs.layout()) |s| {
                    if (!s.zoomed and !only and s.panes.items.len > 1) panes(c, a, k, s) else chatPanel(c, a, k);
                } else chatPanel(c, a, k);
            }
            if (strip.hasHost(a) and !githubChildInSplit(a) and (expanded == null or expanded.? == .host)) {
                if (expanded == null) ui.div(c).w(chrome.gutter).hFull().end();
                if (expanded != null) a.view.chrome.host_width = a.view.chrome.width;
                hostPanel(c, a, k);
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
    @import("window_chrome.zig").draw(c, a, k);
    if (c.input.released) a.view.sidebar_press_focus = false;
    const popup = surfaces.popup(k);
    trailing(c, a, popup);
    @import("view_question.zig").overlay(c, a, k);
    @import("view_diffs.zig").overlays(c, a, popup);
    @import("view_actions.zig").overlays(c, a, popup);
    @import("view_menus.zig").menus(c, a, popup);
    @import("view_sidebar_menus.zig").menus(c, a, popup);
    @import("view_picker.zig").popover(c, a, popup);
    @import("view_context.zig").overlay(c, a, popup);
    @import("view_drag.zig").overlay(c, a, popup);
    @import("view_chat_menu.zig").overlays(c, a, popup);
    @import("view_link_menu.zig").overlay(c, a, popup);
    closeChoice(c, a, popup);
    @import("app_file_editor.zig").dialog(c, a, popup);
    @import("view_updates.zig").overlayCard(c, a, popup);
    // Over everything, as the GPUI app's deferred palette (priority 2).
    @import("view_palette.zig").overlay(c, a, popup);
    @import("view_project_setup.zig").overlay(c, a, popup);
    @import("view_open_chooser.zig").overlay(c, a, popup);
    // First-run setup, over the whole window.
    @import("view_setup.zig").overlay(c, a, k);
    @import("app_browser.zig").syncNative(a, c);
    settleSelectionPostTree(a, c);
    // After the overlays: a click that opens a menu has opened it.
    if (handsKeysBack(.{
        .released = c.input.released,
        .composer_drawn = a.view.composer_frame == c.frame,
        .nothing_focused = c.focus == 0,
        .kept = a.view.press_kept_keys or menuKeepsKeys(a) or c.selection.moved or c.selection.text.items.len > 0,
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
    return v.project_setup.open or v.open_chooser.open or v.strip.menu != null or v.more_menu or v.filter_menu or v.space_menu or v.checkout_menu or v.ref_menu or v.chat_menu.open or v.link_menu.open or
        v.menus.ctx_at != null or v.palette.open or v.search.focus or a.picker != .none;
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
    @import("view_attachment_drop.zig").target(c, a, panel.index, if (a.tabs.layout()) |s| s.focus else null);
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
    // The catch-up, a bot's details or the new-bot form take it the same way.
    if (a.bots.page != .none) return @import("view_bots_page.zig").page(c, a, k, transcript_view.paneWidth(c, a));
    if (a.selected == null) {
        @import("view_newchat.zig").canvas(c, a, k);
    } else {
        if (a.settings.hierarchyProfile().shows_action_toolbar) @import("view_actions.zig").toolbar(c, a, k);
        @import("view_bots.zig").strip(c, a, k, @min(transcript_view.paneWidth(c, a), transcript_view.column_w));
        transcript_view.transcript(c, a, k);
        @import("view_composer.zig").docked(c, a, k);
        @import("view_actions.zig").dock(c, a, k);
    }
}

fn githubChildInSplit(a: *const App) bool {
    const s = a.tabs.layout() orelse return false;
    return s.panes.items.len > 1 and !s.zoomed and a.view.strip.expanded == null and strip.hasHost(a) and @import("app_github_repository.zig").surface(a);
}

fn hostPanel(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.key(c, "workspace-host-body");
    const host = panel_chrome.body(c, k).w(a.view.chrome.host_width).hFull().clip();
    defer host.end();
    if (c.input.pressed and host.interaction().hovered) a.view.strip.focused = .host;
    @import("view_host.zig").host(c, a, k);
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

    const child_parent = if (githubChildInSplit(a)) @import("app_github_repository.zig").parentPane(a) else null;
    for (s.panes.items, s.shares.items, 0..) |chat, share, ix| {
        ui.key(c, c.print("pane-{d}", .{ix}));
        if (ix > 0) divider(c, a, k, ix, across, total);
        const target = chrome.paneSpan(total, share, s.panes.items.len, across);
        const size = if (reveal) |r| revealSpan(total, across, r, ix, target, reveal_t) else target;
        const owns_child = child_parent != null and child_parent.? == ix;
        const extra = if (owns_child) a.view.chrome.host_width + chrome.gutter else 0;
        var group = ui.div(c).row();
        group = if (across) group.w(size + extra).hFull() else group.h(size).wFull();
        defer group.end();
        {
            const saved_width = a.view.chrome.chat_width;
            // In a vertical split only the parent's row shares its width.
            if (!across and child_parent != null and !owns_child) a.view.chrome.chat_width += a.view.chrome.host_width + chrome.gutter;
            defer a.view.chrome.chat_width = saved_width;
            const pane = panel_chrome.body(c, k).clip().w(if (across) size else a.view.chrome.chat_width).hFull();
            defer pane.end();
            @import("view_attachment_drop.zig").target(c, a, pane.index, ix);
            if (c.input.pressed and pane.interaction().hovered) a.view.strip.focused = .{ .chat = ix };
            if (ix == s.focus) {
                focused(c, a, k);
            } else {
                // Capture the whole subtree before focus moves the transcript.
                const it = pane.interaction();
                if (c.input.pressed and it.hovered and c.window_focused) a.view.pane_press = .{ .tab = @import("pane_gesture.zig").context(a, c), .pane = ix };
                if (c.input.released and it.hovered and c.window_focused) if (press) |p| {
                    if (p.tab == @import("pane_gesture.zig").context(a, c) and p.pane == ix) focus = ix;
                };
                const neighbor_w = @max(0, (if (across) size else a.view.chrome.chat_width) - a.view.seam_inset);
                if (neighbor(c, a, k, ix, chat, neighbor_w)) return;
            }
        }
        if (owns_child) {
            ui.div(c).w(chrome.gutter).hFull().end();
            hostPanel(c, a, k);
        }
    }
    if (focus) |ix| {
        if (s.panes.items[ix]) |id| {
            if (c.selection.anchor != null) @import("selection_owner.zig").state(c).promoted_chat = std.hash.Wyhash.hash(0, id);
        }
        strip.queue(a, .{ .focus = .{ .chat = ix } });
        c.changed = true;
    }
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
    if (@import("app_file_editor.zig").keys(c, a)) return;
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
    const picker_had_keys = a.picker != .none;
    palette.keys(c, a);
    if (a.picker != .none) @import("view_picker.zig").keys(c, a);
    // Modal searches own the event even when it is not one of their editing
    // keys. Never navigate or open a second picker underneath them.
    if (palette_had_keys or a.view.palette.open or picker_had_keys or a.picker != .none) return;
    // A dialog has the keys; else an open header menu takes Escape, the
    // arrows and Return.
    const header_menus = @import("view_sidebar_menus.zig");
    // Settings › Accounts' sign-in dialog or device list, Archived's Delete
    // all or Devices' Rename takes Escape first; otherwise Escape exits
    // Settings back to the workspace (`#settings-back [esc]`).
    if (a.view.settings_open and !palette_had_keys and !a.view.palette.open) {
        if (@import("view_settings_accounts.zig").escape(c, a) or
            @import("view_settings_archived.zig").escape(c, a) or
            @import("view_settings_devices.zig").escape(c, a) or
            @import("view_settings_theme_import.zig").escape(c, a))
        {
            return;
        }
        if (a.view.theme_menu != null and c.shortcut(.{ .key = S.escape })) {
            a.view.theme_menu = null;
            a.redraw();
            return;
        }
        if (a.view.agents.device_menu and c.shortcut(.{ .key = S.escape })) {
            a.view.agents.device_menu = false;
            a.redraw();
            return;
        }
        if (a.view.github_ci.size_menu != null and c.shortcut(.{ .key = S.escape })) {
            if (a.view.github_ci.size_menu) |m| a.gpa.free(m);
            a.view.github_ci.size_menu = null;
            a.view.github_ci.size_anchor = null;
            a.redraw();
            return;
        }
        if (!chat_menu.anyOpen(a) and !header_menus.anyOpen(a) and a.view.strip.menu == null and
            (c.shortcut(.{ .key = S.escape }) or c.input.key == .escape))
        {
            c.input.key = null;
            c.focus = 0;
            settings_view.close(a);
            return;
        }
    }
    if (@import("view_composer_completion.zig").keys(c, a)) return;
    // Configured commands win over fixed aliases: on Linux/Windows both
    // mod-1 (session jump) and Ctrl+1 (tab focus) use the native Control key.
    if (sessionNavigationKeys(c, a)) {
        strip.finishNavigation(c, a);
        return;
    }
    if (strip.navigationKeys(c, a)) return;
    if (boundShortcut(c, a, "reopenClosedTab")) {
        strip.finishNavigation(c, a);
        a.reopenClosedTab();
        return;
    }
    if (closeOnlyPressed(c, a)) {
        strip.finishNavigation(c, a);
        a.closeArchiving(false);
        return;
    }
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
    if (boundShortcut(c, a, "toggleSidebar")) {
        @import("frame_profile.zig").note(a, "cmd-b");
        c.changed = false;
        toggleSidebar(c, a, false);
    }
    if (c.shortcut(.{ .key = '=', .cmd = true }) or
        c.shortcut(.{ .key = '=', .cmd = true, .shift = true }) or
        c.shortcut(.{ .key = '+', .cmd = true }) or
        c.shortcut(.{ .key = '+', .cmd = true, .shift = true }))
    {
        a.stepZoom(1);
    }
    if (c.shortcut(.{ .key = '-', .cmd = true }) or
        c.shortcut(.{ .key = '-', .cmd = true, .shift = true }) or
        c.shortcut(.{ .key = '_', .cmd = true }) or
        c.shortcut(.{ .key = '_', .cmd = true, .shift = true }))
    {
        a.stepZoom(-1);
    }
    if (c.shortcut(.{ .key = '0', .cmd = true })) {
        a.resetZoom();
    }
    if (c.shortcut(.{ .key = ',', .cmd = true })) settings_view.open(a);
    if (boundShortcut(c, a, "newProject")) {
        @import("app_open_chooser.zig").open(a, .new_project);
        return;
    }
    if (!a.view.settings_open and boundShortcut(c, a, "openProjectPicker")) {
        strip.toggleProjectPicker(a);
        return;
    }
    if (!a.view.settings_open and !picker_had_keys and boundShortcut(c, a, "openModelPicker")) {
        a.picker = .model;
        @import("view_picker.zig").opened(a);
        a.redraw();
        return;
    }
    if (boundShortcut(c, a, "saveFile")) {
        if (!@import("app_file_editor.zig").saveFocused(a)) {
            if (a.view.write_open) @import("view_write.zig").close(a);
        }
    }
    if (boundShortcut(c, a, "browserReload")) {
        if (a.panels.host_open) if (a.panels.activeTab()) |tab| if (tab.browser) |b| b.reload();
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
    if (a.selected != null and boundShortcut(c, a, "toggleFiles")) @import("app_files.zig").toggle(a);
    if (a.selected != null and (boundShortcut(c, a, "toggleChanges") or boundShortcut(c, a, "toggleTerminal"))) @import("app_panels.zig").toggleHost(a);
    if (boundShortcut(c, a, "newSession") or c.shortcut(.{ .key = 'n', .cmd = true })) a.newTab();
    if (boundShortcut(c, a, "archiveSession")) {
        if (a.selected) |sel| a.setArchived(sel, true);
    }
    if (c.shortcut(.{ .key = 'j', .cmd = true, .shift = true })) strip.nextAttention(a);
    if (c.shortcut(.{ .key = 'm', .cmd = true, .shift = true })) {
        a.settings.toggleUiMode();
        a.redraw();
    }
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
    if (boundShortcut(c, a, "splitTerminal")) strip.splitChoosingFolder(a, .horizontal);
    if (boundShortcut(c, a, "splitTerminalDown")) strip.splitChoosingFolder(a, .vertical);
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
    // An unobscured question owns Escape (Back); the no-menu fallback
    // must not consume it before the question's surface can see it.
    if (a.view.link_menu.open and c.shortcut(.{ .key = S.escape })) {
        a.view.link_menu.open = false;
    } else if (@import("view_chat_menu.zig").anyOpen(a) and c.shortcut(.{ .key = S.escape })) {
        @import("view_chat_menu.zig").dismiss(a);
    } else if (a.view.write_open and !a.view.palette.open and a.picker == .none and c.shortcut(.{ .key = S.escape })) {
        // The global fallback must not swallow Write's Save/back gesture.
        @import("view_write.zig").close(a);
    } else if ((a.wizard == null or menuKeepsKeys(a) or a.view.account_menu) and c.shortcut(.{ .key = S.escape }) and a.queue_edit == null) {
        a.picker = .none;
        a.view.filter_menu = false;
        a.view.more_menu = false;
        a.view.account_menu = false;
    }
}

/// Session navigation is shared by the normal workspace and a focused strip
/// search. The focused panel's tabs take precedence, then workspaces, then
/// the visible sidebar; every sidebar destination uses the preserving opener.
fn sessionNavigationKeys(c: *ui.Context, a: *App) bool {
    const next = boundShortcut(c, a, "nextSession");
    const prev = !next and boundShortcut(c, a, "prevSession");
    if (next or prev) {
        if (a.tabs.layout()) |layout| {
            const group = &layout.groups[layout.focus];
            const count = group.count();
            if (count > 1) {
                a.showPaneTab(if (next) (group.active + 1) % count else (group.active + count - 1) % count);
                return true;
            }
        }
        const n = a.tabs.items.items.len;
        if (n >= 2) {
            a.showTab(if (next) (a.tabs.active + 1) % n else (a.tabs.active + n - 1) % n);
        } else {
            const visible = sidebar.visibleSessionIds(c, a);
            if (visible.len > 0) {
                var at: ?usize = null;
                if (a.selected) |sel| {
                    for (visible, 0..) |id, ix| if (std.mem.eql(u8, id, sel)) {
                        at = ix;
                        break;
                    };
                }
                const to = if (at) |cur| (if (next) (cur + 1) % visible.len else (cur + visible.len - 1) % visible.len) else if (next) 0 else visible.len - 1;
                a.openChatInTab(visible[to]);
            }
        }
        return true;
    }
    for (0..9) |slot| if (boundShortcutSlot(c, a, "jumpSession", @intCast(slot))) {
        const visible = sidebar.visibleSessionIds(c, a);
        if (slot < visible.len) a.openChatInTab(visible[slot]);
        return true;
    };
    return false;
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
pub fn boundShortcut(c: *ui.Context, a: *App, key: []const u8) bool {
    const sc = @import("shortcuts.zig");
    const pressed = c.input.shortcut orelse return false;
    for (sc.all) |entry| if (entry.slot == null and std.mem.eql(u8, entry.key, key)) {
        if (!sc.matches(a.settings.combo(entry), pressed)) return false;
        return c.shortcut(pressed);
    };
    return false;
}

pub fn boundShortcutSlot(c: *ui.Context, a: *App, key: []const u8, slot: u8) bool {
    const sc = @import("shortcuts.zig");
    const pressed = c.input.shortcut orelse return false;
    for (sc.all) |entry| if (entry.slot == slot and std.mem.eql(u8, entry.key, key)) {
        if (!sc.matches(a.settings.combo(entry), pressed)) return false;
        return c.shortcut(pressed);
    };
    return false;
}

/// The close-without-archiving shortcut as Settings › Shortcuts binds it.
fn closeOnlyPressed(c: *ui.Context, a: *App) bool {
    const sc = @import("shortcuts.zig");
    const s = c.input.shortcut orelse return false;
    for (sc.all) |entry| if (std.mem.eql(u8, entry.key, "closeTabWithoutArchiving")) {
        if (!sc.matches(a.settings.combo(entry), s)) return false;
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
        icons.icon(c, .@"clock-circle", 16, k.muted, 0);
        if (history.clicked()) strip.open(a, .history, strip.active(a), c.rects.get(c.node(history.index).id));
        history.end();
        ui.div(c).w(4).end();
        const dev = a.settings.uiMode() == .developer;
        ui.key(c, "titlebar-ui-mode-pill");
        if (kit.iconButton(c, k, if (dev) .terminal else .@"magic-stick-3", .{
            .on = dev,
            .tip = .{ .text = "Toggle Zen / Developer mode (⇧⌘M)" },
        })) {
            a.settings.toggleUiMode();
            a.redraw();
        }
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
    const bar = ui.div(c).fixed().offset(c.size.w - @import("window_chrome.zig").trailing - 6 - w, 4 + (34 - 28) / 2).row().itemsCenter().layer(3);
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

fn selectionScope(a: *const App) u64 {
    var h = std.hash.Wyhash.init(0x5345_4c5f_5343_4f50);
    h.update(std.mem.asBytes(&a.tabs.active));
    if (a.selected) |sel| {
        h.update(&.{1});
        h.update(sel);
    } else {
        h.update(&.{0});
    }
    h.update(&.{ @intFromBool(a.view.settings_open), @intFromBool(a.view.write_open) });
    if (a.wizard) |*wz| {
        h.update(&.{1});
        h.update(wz.request_id);
        h.update(std.mem.asBytes(&wz.page));
        const q = wz.question();
        h.update(q.question);
    } else {
        h.update(&.{0});
    }
    return h.final();
}

fn settleSelectionPreTree(a: *App, c: *ui.Context) void {
    // nanoui's field-selection block is sticky; each new press gets a
    // fresh hit decision. Otherwise selecting the draft once disables all
    // later output/question selections in this native context.
    if (c.input.pressed) c.selection.blocked = false;
    const owner = @import("selection_owner.zig").state(c);
    if (c.input.pressed and c.input.button == .left) owner.return_focus = if (c.focus == a.view.composer_id) c.focus else 0;
    if (c.right_press or c.input.button != .left or c.input.secondary) {
        c.selection.pressed = false;
        c.selection.dragging = false;
    }
    const scope = selectionScope(a);
    const promotion = owner.promoted_chat != 0 and a.selected != null and owner.promoted_chat == std.hash.Wyhash.hash(0, a.selected.?);
    if (!c.window_focused or (a.view.selection_scope != 0 and a.view.selection_scope != scope and !promotion)) {
        c.selection.clear();
        a.view.selection_had_text = false;
        a.view.whitespace_drag = .{};
        owner.* = .{};
    }
    if (a.view.selection_scope != scope and promotion) owner.promoted_chat = 0;
    a.view.selection_scope = scope;
    // An empty paint cache is not an empty selection: both endpoints can
    // be offscreen. Post-tree validation checks the actual source nodes.
    a.view.selection_had_text = c.selection.text.items.len > 0;
}

fn settleSelectionPostTree(a: *App, c: *ui.Context) void {
    const owner = @import("selection_owner.zig").state(c);
    if (c.selection.pressed and !c.selection.blocked) {
        owner.surface = 0;
        if (findNearestSelectableLeaf(c, c.input.mouse)) |leaf| {
            var ix = leaf.index;
            while (ix != 0) : (ix = c.nodes.items[ix].parent) {
                if (c.nodes.items[ix].style.scroll) {
                    owner.surface = c.nodes.items[ix].id;
                    break;
                }
            }
        }
    }
    if (owner.surface != 0 and (c.selection.pressed or c.selection.anchor != null)) {
        // The dependency's selection registry is window-wide. Restrict its
        // painted candidates to the scroll surface that owns this gesture.
        // Ownership survives paragraphs and culled anchors; another pane or
        // the question's separate scroller cannot extend or steal it.
        for (c.nodes.items, 0..) |*n, index| {
            var ix: u32 = @intCast(index);
            var inside = false;
            while (true) {
                if (c.nodes.items[ix].id == owner.surface) {
                    inside = true;
                    break;
                }
                if (ix == 0) break;
                ix = c.nodes.items[ix].parent;
            }
            if (!inside) n.style.selectable = false;
        }
    }
    if (c.right_press or c.input.button != .left or c.input.secondary) {
        c.selection.pressed = false;
        c.selection.dragging = false;
    }
    if (c.selection.pressed) {
        if (!c.selection.blocked and !a.view.settings_open and !menuKeepsKeys(a) and c.input.mouse.x >= a.view.sidebar_width and !anySelectableLeafContains(c, c.input.mouse) and findWhitespaceStartLeaf(c, c.input.mouse) != null) {
            a.view.whitespace_drag = .{ .active = true, .origin = c.input.mouse };
        } else {
            a.view.whitespace_drag = .{};
        }
    }
    if (!c.input.down or c.input.released or c.selection.blocked) {
        a.view.whitespace_drag.active = false;
    }
    if (c.input.down and c.input.button == .left and !c.input.secondary and !c.right_press and !c.selection.blocked) {
        if (a.view.whitespace_drag.active and c.selection.anchor == null) {
            const origin = a.view.whitespace_drag.origin;
            const p = c.input.mouse;
            if (@abs(p.x - origin.x) > 1 or @abs(p.y - origin.y) > 1) {
                if (findWhitespaceStartLeaf(c, origin)) |leaf| {
                    const at = hitLeafIndex(c, leaf.index, leaf.rect, leaf.visible, origin);
                    c.selection.anchor = .{ .id = c.nodes.items[leaf.index].id, .at = at };
                    c.selection.focus = .{ .id = c.nodes.items[leaf.index].id, .at = at };
                    c.selection.dragging = true;
                    c.selection.pressed = false;
                }
            }
        }
        if (c.selection.dragging and c.selection.anchor != null and !anySelectableLeafContains(c, c.input.mouse)) {
            if (findNearestSelectableLeaf(c, c.input.mouse)) |leaf| {
                c.selection.focus = .{
                    .id = c.nodes.items[leaf.index].id,
                    .at = hitLeafIndex(c, leaf.index, leaf.rect, leaf.visible, c.input.mouse),
                };
                c.selection.moved = c.selection.moved or !std.meta.eql(c.selection.anchor, c.selection.focus);
                c.selection.pressed = false;
                // Gaps between paragraphs are still part of the same drag.
                // Stopping here freezes its end at the first paragraph.
                c.changed = true;
            }
        }
    }
    const left_press_blurred = c.input.pressed and c.input.button == .left and !c.input.secondary and !c.right_press and c.focus == 0;
    const page_selection_active = c.selection.anchor != null and (c.selection.moved or c.selection.text.items.len > 0);
    if (left_press_blurred or page_selection_active) {
        var it = c.edits.valueIterator();
        while (it.next()) |e| e.anchor = e.caret;
        if (c.focused_text) |*ft| ft.anchor = ft.caret;
        // Do not repeatedly erase a newly acquired editor/control focus
        // merely because the last completed page gesture moved.
        if (page_selection_active and c.focus == 0 and owner.return_focus == a.view.composer_id) c.focus = owner.return_focus;
    }
    c.selection.order.clearRetainingCapacity();
    registerSelectionOrder(c, 0, false);
    validateSelectionSnapshot(c, owner);
    gatherSelection(c);
    if (!c.copy_done and c.shortcut(.{ .key = 'c', .cmd = true })) {
        if (c.focus == a.view.composer_id and a.view.composer_id != 0) {
            if (c.edits.get(c.focus)) |e| if (e.anchor != e.caret) {
                const txt = a.composer.text();
                const lo = @min(e.caret, e.anchor);
                const hi = @min(@max(e.caret, e.anchor), txt.len);
                if (hi > lo) {
                    c.clipboard.write(c.clipboard.ctx, txt[lo..hi]);
                    c.copy_done = true;
                }
            };
        }
        if (!c.copy_done and c.selection.text.items.len > 0) {
            c.clipboard.write(c.clipboard.ctx, c.selection.text.items);
            c.copy_done = true;
        }
    }
}

/// Paint intentionally skips offscreen lines. Keep the gesture's reading
/// order and Copy source independent of visibility, using the same native
/// selectability inheritance as paint. Transcript rows remain mounted while
/// a selection owns them, even when their glyphs are culled.
fn registerSelectionOrder(c: *ui.Context, ix: u32, inherited: bool) void {
    const n = c.nodes.items[ix];
    const selectable = (inherited or n.style.selectable) and !n.style.control;
    if (selectable and n.content == .text and n.content.text.str.len > 0) {
        const order: u32 = @intCast(c.selection.order.count());
        c.selection.order.put(c.gpa, n.id, order) catch {};
    }
    var child = n.first_child;
    while (child != no_child) : (child = c.nodes.items[child].next) registerSelectionOrder(c, child, selectable);
}

fn gatherSelection(c: *ui.Context) void {
    const ends = c.selection.ordered() orelse return;
    const lo = c.selection.order.get(ends[0].id) orelse return;
    const hi = c.selection.order.get(ends[1].id) orelse return;
    c.selection.text.clearRetainingCapacity();
    for (c.nodes.items) |n| {
        if (n.content != .text) continue;
        const order = c.selection.order.get(n.id) orelse continue;
        if (order < lo or order > hi) continue;
        const str = n.content.text.str;
        const start = if (n.id == ends[0].id) @min(ends[0].at, str.len) else 0;
        const end = if (n.id == ends[1].id) @min(ends[1].at, str.len) else str.len;
        if (end <= start) continue;
        if (c.selection.text.items.len > 0) c.selection.text.append(c.gpa, '\n') catch {};
        c.selection.text.appendSlice(c.gpa, str[start..end]) catch {};
    }
}

/// Copy is offered before this frame's paint. Do not let last paint's
/// clipboard cache outlive a removed/collapsed/replaced selection. Hash
/// only selected bytes, so streaming beyond the selected range is harmless.
fn validateSelectionSnapshot(c: *ui.Context, owner: *@import("selection_owner.zig").State) void {
    if (c.selection.anchor == null or c.selection.dragging or c.selection.pressed) {
        owner.snapshot = 0;
        return;
    }
    const ends = c.selection.ordered() orelse return;
    const lo = c.selection.order.get(ends[0].id) orelse {
        c.selection.clear();
        owner.snapshot = 0;
        return;
    };
    const hi = c.selection.order.get(ends[1].id) orelse {
        c.selection.clear();
        owner.snapshot = 0;
        return;
    };
    var found_start = false;
    var found_end = false;
    var h = std.hash.Wyhash.init(0x5345_4c45_4354_4544);
    for (c.nodes.items) |n| {
        if (n.content != .text) continue;
        const order = c.selection.order.get(n.id) orelse continue;
        if (order < lo or order > hi) continue;
        if (n.id == ends[0].id) found_start = true;
        if (n.id == ends[1].id) found_end = true;
        const str = n.content.text.str;
        const start = if (n.id == ends[0].id) @min(ends[0].at, str.len) else 0;
        const end = if (n.id == ends[1].id) @min(ends[1].at, str.len) else str.len;
        h.update(std.mem.asBytes(&n.id));
        if (end > start) h.update(str[start..end]);
    }
    const snapshot = h.final();
    if (!found_start or !found_end or (owner.snapshot != 0 and owner.snapshot != snapshot)) {
        c.selection.clear();
        owner.snapshot = 0;
    } else owner.snapshot = snapshot;
}

const no_child = std.math.maxInt(u32);

const SelectableLeaf = struct {
    index: u32,
    rect: ui.Rect,
    visible: ui.Rect,
    score: f32,
};

fn anySelectableLeafContains(c: *const ui.Context, p: ui.Point) bool {
    if (c.nodes.items.len == 0) return false;
    return walkContains(c, 0, false, null, p);
}

fn walkContains(c: *const ui.Context, ix: u32, sel_in: bool, clip_in: ?ui.Rect, p: ui.Point) bool {
    const n = c.nodes.items[ix];
    const block_select = n.style.control or (n.interactive and n.first_child == no_child);
    if (block_select) return false;
    const selectable = sel_in or n.style.selectable;
    const r = c.rects.get(n.id);
    const clip = if ((n.style.clip or n.style.scroll) and r != null)
        if (clip_in) |prev| intersectRect(prev, r.?) else r.?
    else
        clip_in;
    if (n.first_child == no_child) {
        const text_len = switch (n.content) {
            .text => |tx| tx.str.len,
            else => 0,
        };
        if (!selectable or text_len == 0 or r == null) return false;
        if (clip) |cl| if (!cl.contains(p)) return false;
        return r.?.contains(p);
    }
    var ch = n.first_child;
    while (ch != no_child) : (ch = c.nodes.items[ch].next) {
        if (walkContains(c, ch, selectable, clip, p)) return true;
    }
    return false;
}

fn findNearestSelectableLeaf(c: *const ui.Context, p: ui.Point) ?SelectableLeaf {
    if (c.nodes.items.len == 0) return null;
    var best: ?SelectableLeaf = null;
    walkNearest(c, 0, false, null, p, &best);
    return best;
}

/// A new gutter gesture belongs to a visible text band in its own scroll
/// viewport. The unrestricted nearest-leaf search is only for extending an
/// already-owned drag through paragraph gaps or beyond its visible ends.
fn findWhitespaceStartLeaf(c: *const ui.Context, p: ui.Point) ?SelectableLeaf {
    const leaf = findNearestSelectableLeaf(c, p) orelse return null;
    if (p.y < leaf.visible.y or p.y >= leaf.visible.y + leaf.visible.h) return null;
    var ix = leaf.index;
    while (ix != 0) : (ix = c.nodes.items[ix].parent) {
        const n = c.nodes.items[ix];
        if (n.style.scroll) {
            const viewport = c.rects.get(n.id) orelse return null;
            return if (viewport.contains(p)) leaf else null;
        }
    }
    return null;
}

fn walkNearest(c: *const ui.Context, ix: u32, sel_in: bool, clip_in: ?ui.Rect, p: ui.Point, best: *?SelectableLeaf) void {
    const n = c.nodes.items[ix];
    const block_select = n.style.control or (n.interactive and n.first_child == no_child);
    if (block_select) return;
    const selectable = sel_in or n.style.selectable;
    const r = c.rects.get(n.id);
    const clip = if ((n.style.clip or n.style.scroll) and r != null)
        if (clip_in) |prev| intersectRect(prev, r.?) else r.?
    else
        clip_in;
    if (n.first_child == no_child) {
        const text_len = switch (n.content) {
            .text => |tx| tx.str.len,
            else => 0,
        };
        if (!selectable or text_len == 0 or r == null) return;
        const rect = r.?;
        if (rect.w <= 0 or rect.h <= 0) return;
        const visible = if (clip) |cl| intersectRect(rect, cl) else rect;
        // Fully masked lines/columns are not candidates, including nested
        // horizontal clips and exact zero-width/height boundaries.
        if (visible.w <= 0 or visible.h <= 0) return;
        const dy: f32 = if (p.y < visible.y) visible.y - p.y else if (p.y > visible.y + visible.h) p.y - (visible.y + visible.h) else 0;
        const dx: f32 = if (p.x < visible.x) visible.x - p.x else if (p.x > visible.x + visible.w) p.x - (visible.x + visible.w) else 0;
        const clip_penalty: f32 = if (clip) |cl| (if (cl.contains(p)) @as(f32, 0) else 100_000) else 0;
        const score = clip_penalty + dy * 1000.0 + dx;
        if (best.* == null or score < best.*.?.score) {
            best.* = .{ .index = ix, .rect = rect, .visible = visible, .score = score };
        }
        return;
    }
    var ch = n.first_child;
    while (ch != no_child) : (ch = c.nodes.items[ch].next) {
        walkNearest(c, ch, selectable, clip, p, best);
    }
}

fn intersectRect(a: ui.Rect, b: ui.Rect) ui.Rect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.w, b.x + b.w);
    const y2 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x1, .y = y1, .w = @max(0, x2 - x1), .h = @max(0, y2 - y1) };
}

fn hitLeafIndex(c: *ui.Context, ix: u32, r: ui.Rect, visible: ui.Rect, pointer: ui.Point) usize {
    // Resolve against the original wrapping geometry, but inside the
    // paint-time mask. A collapsed/partially scrolled leaf must never map
    // an out-of-band drag to a hidden continuation line.
    const eps = @min(@as(f32, 0.001), visible.h / 4);
    var p = pointer;
    if (p.y < visible.y) {
        p.y = visible.y + eps;
        p.x = visible.x;
    } else if (p.y >= visible.y + visible.h) {
        p.y = visible.y + visible.h - eps;
        p.x = visible.x + visible.w;
    }
    const n = c.nodes.items[ix];
    const tx = switch (n.content) {
        .text => |t| t,
        else => return 0,
    };
    const lh = c.text.lineHeight(tx.style);
    const lines = if (tx.lines.len > 0)
        tx.lines
    else if (tx.spans.len > 0)
        c.text.wrapAttributed(tx.str, tx.style, tx.spans, r.w)
    else if (tx.style.wrap)
        c.text.wrap(tx.str, tx.style, r.w)
    else
        null;
    if (lines) |ls| {
        if (ls.len == 0) return 0;
        if (p.y < r.y) return 0;
        if (p.y > r.y + r.h) return tx.str.len;
        const raw = @floor((p.y - r.y) / @max(lh, 1));
        const row: usize = @intFromFloat(std.math.clamp(raw, 0, @as(f32, @floatFromInt(ls.len - 1))));
        const line = ls[row];
        const col = hitSliceAt(c, tx.str[line.start..line.end], tx.style, p.x - r.x);
        return line.start + col;
    }
    if (p.y < r.y and p.x <= r.x) return 0;
    if (p.y > r.y + r.h and p.x >= r.x) return tx.str.len;
    return hitSliceAt(c, tx.str, tx.style, p.x - r.x);
}

fn hitSliceAt(c: *ui.Context, slice: []const u8, style: ui.TextStyle, x: f32) usize {
    if (x <= 0 or slice.len == 0) return 0;
    var best: usize = 0;
    var best_d: f32 = x;
    var i: usize = 0;
    while (i < slice.len) {
        const step = std.unicode.utf8ByteSequenceLength(slice[i]) catch 1;
        i = @min(i + step, slice.len);
        const w = c.text.width(slice[0..i], style);
        const d = @abs(x - w);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}
