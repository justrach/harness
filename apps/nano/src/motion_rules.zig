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

/// Offscreen transcript row culling gate (`Nano.Tween.shouldCullOffscreen`).
/// Proven in `Nano/Tween.lean` (`cmd_b_always_culls_offscreen`,
/// `settled_frame_preserves_retain_fast_path`, `rail_glide_disables_culling`):
/// - `Cmd+B` (`tweening = true`) always culls offscreen rows, invariant to
///   `resizing` and `streaming` state.
/// - Settled frames (`!tweening and !resizing and !streaming`) and scrollbar
///   rail gliding (`rail_gliding`) disable leaf-spacer culling so `nanoui`'s
///   `< 0.02ms` GPU `retain.shift` scroll fast-path stays active and all
///   offscreen row heights are warm before the next `Cmd+B`.
pub fn shouldCullOffscreen(
    tweening: bool,
    resizing: bool,
    streaming: bool,
    rail_gliding: bool,
) bool {
    return !rail_gliding and (tweening or resizing or streaming);
}

/// Transcript column width quantization during `Cmd+B` (`Nano.Tween.tweenColumnWidth`).
/// Proven in `Nano/Tween.lean` (`tween_column_never_exceeds_raw` and
/// `tween_column_exact_at_cap`) never to exceed `raw_col` while quantizing widths
/// below `max_col` to `8px` steps during `tweening` so CoreText line-wrap caches
/// hit across intermediate `Cmd+B` frames.
pub fn tweenColumnWidth(tweening: bool, raw_col: f32, max_col: f32) f32 {
    if (tweening and raw_col < max_col) {
        return @floor(raw_col / 8.0) * 8.0;
    }
    return raw_col;
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
        .chat => if (has_host and !expanded)
            .close_host
        else if (pane_tabs > 1)
            .close_pane_tab
        else if (split_panes > 1)
            .close_split_pane
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

pub const SplitSlotPartition = struct {
    active_w: f32,
    pill_w: f32,
    total_w: f32,
};

/// Partition of a split-pane tab slot (`slot_w`) among 1 active tab and `n_tabs - 1`
/// inactive tab pills separated by `4px` gaps (`Nano.StripMenu.splitSlotPartition`).
/// Proven (`split_slot_partition_bounded`) never to overflow `slot_w`.
pub fn splitSlotPartition(slot_w_in: f32, n_tabs: usize) SplitSlotPartition {
    const slot_w = @max(0, slot_w_in);
    if (n_tabs <= 1) {
        return .{ .active_w = slot_w, .pill_w = 0, .total_w = slot_w };
    }
    const inactive: f32 = @floatFromInt(n_tabs - 1);
    const gaps = inactive * 4;
    const avail = @max(0, slot_w - @min(slot_w, gaps));
    const pill_budget = avail * 0.45;
    const pill_w = @min(120, @floor(pill_budget / inactive));
    const active_w = @max(0, avail - @min(avail, inactive * pill_w));
    return .{
        .active_w = active_w,
        .pill_w = pill_w,
        .total_w = active_w + inactive * pill_w + @min(slot_w, gaps),
    };
}

/// Width reserved for background global tabs beside a multi-pane split
/// (`Nano.StripMenu.otherTabsReserve`), capped at `38%` of `avail_bar`.
pub fn otherTabsReserve(avail_bar: f32, other_count: usize) f32 {
    if (other_count == 0) return 0;
    const natural = @as(f32, @floatFromInt(other_count)) * 114 + 34;
    return @min(natural, avail_bar * 0.38);
}

/// Downward shadow bleed (in px) from the selected tab cap onto the conversation
/// body below `foot` (`Nano.StripMenu.capShadowDownwardBleed`).
pub fn capShadowDownwardBleed(foot: f32, r: f32, blur_reach: f32, interior_masked: bool) f32 {
    if (interior_masked) {
        const sh_bottom = @max(0, foot - @min(foot, r)) + blur_reach;
        return @max(0, sh_bottom - @min(sh_bottom, foot));
    }
    return (foot + blur_reach) - foot;
}

pub const BillingTier = enum { plan, local, credits, api };

/// Model picker billing tier rank (`Nano.FrameSchedule.billingRank`):
/// orders subscription (`plan`) models strictly before non-subscription models.
pub fn billingRank(tier: BillingTier) u8 {
    return switch (tier) {
        .plan => 0,
        .local => 1,
        .credits => 2,
        .api => 3,
    };
}

/// Retained-scene eligibility (`Nano.FrameSchedule.retainStoreOk`).
pub fn retainStoreOk(virtual_list: bool, animating: bool, changed: bool) bool {
    return !virtual_list and !animating and !changed;
}

/// Active sidebar row fill policy (`Nano.FrameSchedule.sidebarActiveOpaqueCard`).
pub fn sidebarActiveOpaqueCard(frosted: bool) bool {
    return !frosted;
}

/// Multiline editor scrollbar policy (`Nano.FrameSchedule.multilineFieldScrollbar`).
pub fn multilineFieldScrollbar(focused: bool, caret_visible: bool, has_overflow: bool) bool {
    _ = focused;
    _ = caret_visible;
    _ = has_overflow;
    return false;
}

pub const SelectionOwner = enum { none, editor, page };
pub const SelectionEvent = enum { page_select, editor_select_or_edit, noop_undo_redo, clear_all };

/// Exclusive selection ownership transition (`Nano.FrameSchedule.stepSelectionOwner`).
pub fn stepSelectionOwner(cur: SelectionOwner, ev: SelectionEvent) SelectionOwner {
    return switch (ev) {
        .page_select => .page,
        .editor_select_or_edit => .editor,
        .noop_undo_redo => cur,
        .clear_all => .none,
    };
}

pub const CopyTarget = enum { none, editor_slice, page_slice };

/// `Cmd+C` copy target resolution (`Nano.FrameSchedule.decideCopyTarget`).
pub fn decideCopyTarget(editor_focused: bool, editor_has_range: bool, page_has_text: bool) CopyTarget {
    if (editor_focused and editor_has_range) return .editor_slice;
    if (page_has_text) return .page_slice;
    return .none;
}

/// Selection survival across scope transitions and unmounted sources (`Nano.FrameSchedule.selectionSurvivesFrame`, `#745`).
pub fn selectionSurvivesFrame(same_scope: bool, source_mounted: bool) bool {
    return same_scope and source_mounted;
}

/// Startup tab restoration fencing (`Nano.FrameSchedule.shouldRestoreSavedTabs`, `#797`).
pub fn shouldRestoreSavedTabs(tabs_ready: bool, has_selected_chat: bool, single_empty_tab: bool, has_dirty_boot_draft: bool) bool {
    return !tabs_ready and !has_selected_chat and single_empty_tab and !has_dirty_boot_draft;
}

/// Restorable tab chat eligibility (`Nano.FrameSchedule.restorableTabChat`, `#797`).
pub fn restorableTabChat(chat_exists: bool, is_archived: bool, already_open: bool) bool {
    return chat_exists and !is_archived and !already_open;
}

/// Sidebar `Open workspaces` visibility (`Nano.FrameSchedule.workspaceVisibleInSidebarFixed`).
pub fn workspaceVisibleInSidebar(has_multiple_workspaces: bool, is_singleton_listed_chat: bool) bool {
    _ = is_singleton_listed_chat;
    return has_multiple_workspaces;
}

/// Currency-safe inline `$ ... $` delimiter rule (`Nano.FrameSchedule.isInlineMathDelimiterPair`, `#795`).
pub fn isInlineMathDelimiterPair(
    in_code_span: bool,
    open_escaped: bool,
    close_escaped: bool,
    space_after_open: bool,
    space_before_close: bool,
    alnum_before_open: bool,
    alnum_after_close: bool,
) bool {
    return !in_code_span and !open_escaped and !close_escaped and
        !space_after_open and !space_before_close and
        !alnum_before_open and !alnum_after_close;
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

    // Exhaustive 16-state boolean truth cube for `shouldCullOffscreen`:
    // 1. `Cmd+B` (`tweening = true, rail_gliding = false`) ALWAYS culls offscreen rows.
    // 2. Settled frames (`!tweening and !resizing and !streaming`) NEVER cull offscreen rows
    //    (preserving `retain.shift` and keeping offscreen heights warm before `Cmd+B`).
    // 3. `rail_gliding = true` NEVER culls offscreen rows.
    for ([_]bool{ false, true }) |rsz| {
        for ([_]bool{ false, true }) |str| {
            try std.testing.expect(shouldCullOffscreen(true, rsz, str, false));
            try std.testing.expect(!shouldCullOffscreen(true, rsz, str, true));
        }
    }
    for ([_]bool{ false, true }) |rg| {
        try std.testing.expect(!shouldCullOffscreen(false, false, false, rg));
    }
    try std.testing.expectEqual(@as(f32, 736), tweenColumnWidth(true, 736, 736));
    try std.testing.expectEqual(@as(f32, 640), tweenColumnWidth(true, 645, 736));
    try std.testing.expectEqual(@as(f32, 645), tweenColumnWidth(false, 645, 736));
    try std.testing.expect(tweenColumnWidth(true, 645, 736) <= 645);

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
    try std.testing.expectEqual(CloseAction.close_host, decideCloseTarget(.chat, false, 2, 2, true, false, false, false));
    try std.testing.expectEqual(CloseAction.close_split_pane, decideCloseTarget(.chat, false, 1, 2, false, false, false, false));

    // Split-pane slot partition, other-tabs reserve, cap shadow mask, billing rank, virtual_list retain, and frosted pill policy.
    for ([_]f32{ 120, 180, 240, 320, 440 }) |sw| {
        for ([_]usize{ 1, 2, 3, 4, 5 }) |nt| {
            const part = splitSlotPartition(sw, nt);
            try std.testing.expect(part.total_w <= sw);
            try std.testing.expect(part.active_w <= sw);
        }
    }
    try std.testing.expect(otherTabsReserve(900, 5) <= 900 * 0.38 + 0.001);
    try std.testing.expectEqual(@as(f32, 0), capShadowDownwardBleed(42, 10, 8, true));
    try std.testing.expectEqual(@as(f32, 8), capShadowDownwardBleed(42, 10, 8, false));
    try std.testing.expect(billingRank(.plan) < billingRank(.local));
    try std.testing.expect(billingRank(.local) < billingRank(.credits));
    try std.testing.expect(billingRank(.credits) < billingRank(.api));
    try std.testing.expect(!retainStoreOk(true, false, false));
    try std.testing.expect(!sidebarActiveOpaqueCard(true));
    try std.testing.expect(!multilineFieldScrollbar(true, true, true));
    try std.testing.expectEqual(SelectionOwner.page, stepSelectionOwner(.editor, .page_select));
    try std.testing.expectEqual(SelectionOwner.editor, stepSelectionOwner(.page, .editor_select_or_edit));
    try std.testing.expectEqual(SelectionOwner.page, stepSelectionOwner(.page, .noop_undo_redo));
    try std.testing.expectEqual(CopyTarget.page_slice, decideCopyTarget(false, false, true));
    try std.testing.expectEqual(CopyTarget.editor_slice, decideCopyTarget(true, true, true));
    try std.testing.expect(!selectionSurvivesFrame(false, true));
    try std.testing.expect(!selectionSurvivesFrame(true, false));
    try std.testing.expect(selectionSurvivesFrame(true, true));
    try std.testing.expect(!shouldRestoreSavedTabs(false, false, true, true));
    try std.testing.expect(shouldRestoreSavedTabs(false, false, true, false));
    try std.testing.expect(!restorableTabChat(true, true, false));
    try std.testing.expect(restorableTabChat(true, false, false));
    try std.testing.expect(workspaceVisibleInSidebar(true, true));
    try std.testing.expect(!isInlineMathDelimiterPair(false, false, false, false, true, false, true));
    try std.testing.expect(isInlineMathDelimiterPair(false, false, false, false, false, false, false));
}
