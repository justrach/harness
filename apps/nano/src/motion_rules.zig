//! Pure executable rules for frame scheduling, scroll-follow quiescence,
//! interruptible tweens, offscreen viewport culling, and top-strip slot layout.
//!
//! Formally verified in Lean 4 (`apps/nano/lean-proofs/`):
//! - `Nano/FrameSchedule.lean` (240-cell frame/focus/persistence cube)
//! - `Nano/ScrollFollow.lean`  (200-cell scroll-follow & stick-end quiescence cube)
//! - `Nano/Tween.lean`         (30-cell C⁰ retarget continuity & viewport culling cube)
//! - `Nano/StripMenu.lean`     (slot chip width conservation, scrim top, menu focus cube)
//!
//! Designed with zero `App` dependency so the motion and scroll kernels can be
//! shared directly with `nanoui`.
const std = @import("std");

pub const icon_and_gap: f32 = 13;
pub const editable_extra: f32 = 18;
pub const chip_gap: f32 = 6;

pub const ChipLayout = struct {
    dev_w: f32,
    dev_text_max: f32,
    pick_w: f32,
    pick_text_max: f32,
};

/// Width allocation for `🖥 <computer> ⌄` and `📁 <folder> ⌄` inside a top-strip
/// slot (`Nano.StripMenu.slotChipWidths`).
///
/// Guarantees (`chip_conservation_holds` in `Nano/StripMenu.lean`):
/// 1. When `dev_natural + 6 + pick_natural <= room`, neither chip's label or
///    `9px` `.@"alt-arrow-down"` chevron is ever clipped.
/// 2. Neither chip overflows `room`.
pub fn slotChipWidths(
    room_in: f32,
    dev_text_w_in: f32,
    dev_editable: bool,
    pick_text_w_in: ?f32,
    pick_changeable: bool,
) ChipLayout {
    const room = @max(0, room_in);
    const dev_text_w = @max(0, @ceil(dev_text_w_in));
    const dev_extra: f32 = if (dev_editable) editable_extra else 0;
    const dev_natural = dev_text_w + icon_and_gap + dev_extra;
    if (pick_text_w_in) |p_raw| {
        const p_text = @max(0, @ceil(p_raw));
        const pick_extra: f32 = if (pick_changeable) editable_extra else 0;
        const pick_natural = p_text + icon_and_gap + pick_extra;
        const dev_floor = @max(room * 0.5, room - (chip_gap + pick_natural));
        const dev_w = @max(0, @min(dev_natural, @min(room, dev_floor)));
        const pick_max = @max(0, room - @min(room, dev_w + chip_gap));
        const pick_w = if (pick_changeable) @min(pick_max, pick_natural) else pick_max;
        return .{
            .dev_w = dev_w,
            .dev_text_max = @max(0, dev_w - (icon_and_gap + dev_extra)),
            .pick_w = pick_w,
            .pick_text_max = @max(0, pick_w - (icon_and_gap + pick_extra)),
        };
    }
    const dev_w = @max(0, @min(dev_natural, room));
    return .{
        .dev_w = dev_w,
        .dev_text_max = @max(0, dev_w - (icon_and_gap + dev_extra)),
        .pick_w = 0,
        .pick_text_max = 0,
    };
}

/// Top Y coordinate of a strip menu's dismissal scrim (`Nano.StripMenu.scrimTop`).
/// Non-footer strip menus start below `header_height` (`42px`) so top-strip chips
/// remain clickable on the first click (`top_strip_click_bypasses_scrim`).
pub fn scrimTop(footer_folder: bool, header_height: f32) f32 {
    return if (footer_folder) 0 else header_height;
}

pub const MenuKind = enum {
    none,
    panel,
    history,
    folder,
    device,
};

pub const FocusDecision = struct {
    focus_composer: bool,
    focus_menu: bool,
    search_focus: bool,
};

/// Focus arbitration when `strip.settle` runs (`Nano.StripMenu.settleFocus`).
/// Proves (`settle_never_steals_menu_focus`) that an open strip menu never
/// loses focus to the composer when `focus(a, target)` selects a pane.
pub fn settleFocus(menu: MenuKind, active_is_chat: bool) FocusDecision {
    return switch (menu) {
        .none => .{
            .focus_composer = active_is_chat,
            .focus_menu = false,
            .search_focus = false,
        },
        .folder => .{
            .focus_composer = false,
            .focus_menu = true,
            .search_focus = true,
        },
        .panel, .history, .device => .{
            .focus_composer = false,
            .focus_menu = true,
            .search_focus = false,
        },
    };
}

pub const StickEndSync = struct {
    scroll: f32,
    seen: f32,
    follow: bool,
};

/// Quiescent `stick_end` scroll state (`Nano.ScrollFollow.verifiedStickEnd`).
///
/// Instead of writing `floatMax(f32)` (which forces `scroll_moved`, a 120Hz
/// display link, `animating = true`, and a `recoverBlank` 2nd-pass rebuild),
/// aligns `scroll` and `seen` to `known_max orelse 0` with `follow = true`.
/// Proven in `Nano/ScrollFollow.lean` (`stick_end_stationary_quiescent` and
/// `stick_end_follows_growth`) to be 100% quiescent on stationary transcripts
/// while snapping to `new_max` whenever the transcript grows.
pub fn stickEndScroll(known_max: ?f32) StickEndSync {
    const target = known_max orelse 0;
    return .{
        .scroll = target,
        .seen = target,
        .follow = true,
    };
}

/// Samples a tween at eased progress `eased_progress` in `[0, 1]`
/// (`Nano.Tween.sample`).
pub fn sampleTween(from: f32, to: f32, eased_progress: f32) f32 {
    if (eased_progress >= 1.0) return to;
    if (eased_progress <= 0.0) return from;
    return from + (to - from) * eased_progress;
}

/// Sound offscreen row culling during an active layout tween
/// (`Nano.Tween.skipOffscreen`).
/// Proven in `Nano/Tween.lean` (`culling_never_drops_visible_row`) never to
/// skip any row that intersects `[view_top, view_bottom]`.
pub fn skipOffscreenRow(
    tweening: bool,
    row_top: f32,
    row_bottom: f32,
    view_top: f32,
    view_bottom: f32,
    pad: f32,
) bool {
    if (!tweening) return false;
    return row_bottom < view_top - pad or row_top > view_bottom + pad;
}

/// Right-side control reservation inside a top-strip slot (`Nano.StripMenu.slotControlsWidth`).
/// When unhovered (`!hovered`) and `menu_count <= 1`, reserves `0px` instead of `66px`.
pub fn slotControlsWidth(slot_w: f32, hovered: bool, menu_count: usize) f32 {
    if (hovered) {
        return 18 + (if (slot_w >= 220) @as(f32, 24) else 0) + (if (slot_w >= 136) @as(f32, 24) else 0);
    }
    if (menu_count > 1) return 18;
    return 0;
}

/// Available horizontal room for the slot's title and `🖥 <computer> ⌄ 📁 <folder> ⌄`
/// chips (`Nano.StripMenu.slotTextRoom`).
pub fn slotTextRoom(slot_w: f32, hovered: bool, menu_count: usize) f32 {
    const ctrl = slotControlsWidth(slot_w, hovered, menu_count);
    const ctrl_reserve: f32 = if (ctrl > 0) 6 + ctrl else 0;
    return @max(0, slot_w - (7 + 4 + 14 + 6 + ctrl_reserve));
}

/// Left inset of the top instrument strip (`Nano.StripMenu.stripLeftInset`).
/// Accounts for traffic lights (`88px`), sidebar toggle (`24px`), collapsed history
/// button (`28px`), optional titlebar update button (`26px`), and `14px` clearance.
pub fn stripLeftInset(sidebar_w: f32, side_max: f32, settings_open: bool, has_update: bool) f32 {
    const side = @max(1, side_max);
    const collapsed = 1 - std.math.clamp(sidebar_w / side, 0, 1);
    const history: f32 = if (settings_open) 28 else 28 * collapsed;
    const updates: f32 = if (!settings_open and has_update) 26 else 0;
    return @max(0, 88 + 24 + history + updates + 14 - sidebar_w);
}

pub const CloseSurface = enum { chat, host, files };
pub const CloseAction = enum {
    noop,
    confirm_choice,
    ask_choice,
    close_host,
    close_files,
    close_pane_tab,
    close_split_pane,
    close_tab,
};

/// `Cmd+W` close target resolution (`Nano.FrameSchedule.decideCloseTarget`).
pub fn decideCloseTarget(
    surface: CloseSurface,
    close_choice_open: bool,
    pane_tabs: usize,
    split_panes: usize,
    has_host: bool,
    expanded: bool,
    is_only_new_chat: bool,
    asks_archive: bool,
) CloseAction {
    if (close_choice_open) return .confirm_choice;
    return switch (surface) {
        .host => .close_host,
        .files => .close_files,
        .chat => if (pane_tabs > 1)
            .close_pane_tab
        else if (split_panes > 1)
            .close_split_pane
        else if (has_host and !expanded)
            .close_host
        else if (is_only_new_chat)
            .noop
        else if (asks_archive)
            .ask_choice
        else
            .close_tab,
    };
}

pub fn closeRedrawPasses(coalesce_pre_tree: bool, has_archive_side_effect: bool) usize {
    if (coalesce_pre_tree) return 1;
    return 1 + @as(usize, if (has_archive_side_effect) 1 else 0) + 1;
}

test "lean StripMenu kernel: screenshot slot chevron unclipped and conservation cube holds" {
    const shot = slotChipWidths(180, 43, true, 40, true);
    try std.testing.expectEqual(@as(f32, 74), shot.dev_w);
    try std.testing.expectEqual(@as(f32, 43), shot.dev_text_max);
    try std.testing.expectEqual(@as(f32, 71), shot.pick_w);
    try std.testing.expectEqual(@as(f32, 40), shot.pick_text_max);

    const rooms = [_]f32{ 60, 100, 140, 151, 180, 240 };
    const dev_widths = [_]f32{ 20, 43, 80 };
    const pick_widths = [_]?f32{ null, 20, 40, 90 };
    for (rooms) |room| {
        for (dev_widths) |dw| {
            for ([_]bool{ false, true }) |de| {
                for (pick_widths) |pw| {
                    for ([_]bool{ false, true }) |pc| {
                        const out = slotChipWidths(room, dw, de, pw, pc);
                        const dev_extra: f32 = if (de) editable_extra else 0;
                        const dev_nat = dw + icon_and_gap + dev_extra;
                        try std.testing.expect(out.dev_w <= room);
                        if (pw) |p| {
                            const pick_extra: f32 = if (pc) editable_extra else 0;
                            const pick_nat = p + icon_and_gap + pick_extra;
                            if (dev_nat + chip_gap + pick_nat <= room) {
                                try std.testing.expectEqual(dev_nat, out.dev_w);
                                try std.testing.expectEqual(dw, out.dev_text_max);
                                if (pc) {
                                    try std.testing.expectEqual(pick_nat, out.pick_w);
                                    try std.testing.expectEqual(p, out.pick_text_max);
                                }
                            }
                        } else if (dev_nat <= room) {
                            try std.testing.expectEqual(dw, out.dev_text_max);
                        }
                    }
                }
            }
        }
    }
}

test "lean StripMenu kernel: scrimTop and settleFocus preserve top-strip click and menu focus" {
    try std.testing.expectEqual(@as(f32, 42), scrimTop(false, 42));
    try std.testing.expectEqual(@as(f32, 0), scrimTop(true, 42));

    for ([_]MenuKind{ .none, .panel, .history, .folder, .device }) |m| {
        for ([_]bool{ false, true }) |is_chat| {
            const d = settleFocus(m, is_chat);
            if (m == .none) {
                try std.testing.expect(!d.focus_menu);
                try std.testing.expectEqual(is_chat, d.focus_composer);
            } else {
                try std.testing.expect(!d.focus_composer);
                try std.testing.expect(d.focus_menu);
                try std.testing.expectEqual(m == .folder, d.search_focus);
            }
        }
    }
}

test "lean ScrollFollow and Tween kernels: stickEndScroll quiescence and C0 retarget continuity" {
    const known = stickEndScroll(480);
    try std.testing.expectEqual(@as(f32, 480), known.scroll);
    try std.testing.expectEqual(@as(f32, 480), known.seen);
    try std.testing.expect(known.follow);

    const fresh = stickEndScroll(null);
    try std.testing.expectEqual(@as(f32, 0), fresh.scroll);
    try std.testing.expectEqual(@as(f32, 0), fresh.seen);
    try std.testing.expect(fresh.follow);

    const mid = sampleTween(0, 256, 0.5);
    const reversed = sampleTween(mid, 0, 0.0);
    try std.testing.expectEqual(mid, reversed);

    try std.testing.expect(!skipOffscreenRow(true, 50, 120, 100, 700, 160));
    try std.testing.expect(skipOffscreenRow(true, 900, 1000, 100, 700, 160));
    try std.testing.expect(!skipOffscreenRow(false, 900, 1000, 100, 700, 160));

    // Unhovered 184px slot recovers 72px of room (`153px`), fitting both `This Mac ⌄` and `harness ⌄`.
    const room = slotTextRoom(184, false, 1);
    try std.testing.expectEqual(@as(f32, 153), room);
    const chips = slotChipWidths(room, 43, true, 40, true);
    try std.testing.expectEqual(@as(f32, 43), chips.dev_text_max);
    try std.testing.expectEqual(@as(f32, 40), chips.pick_text_max);

    // Update button (`🔄`, x <= 166) never overlaps the first slot (`x = 180`).
    try std.testing.expectEqual(@as(f32, 180), stripLeftInset(0, 224, false, true));

    // Cmd+W hierarchy & single-pass coalescing.
    try std.testing.expectEqual(@as(usize, 1), closeRedrawPasses(true, true));
    try std.testing.expectEqual(@as(usize, 1), closeRedrawPasses(true, false));
    try std.testing.expectEqual(CloseAction.confirm_choice, decideCloseTarget(.chat, true, 1, 1, false, false, false, true));
    try std.testing.expectEqual(CloseAction.close_split_pane, decideCloseTarget(.chat, false, 1, 2, true, false, false, false));
}
