//! Desktop workspace geometry, from origin/main's workspace_panels.rs and
//! instrument_strip.rs. This module is also the renderer-independent contract
//! for transcript/composer bounds: chrome never guesses their available room.
const std = @import("std");

pub const gutter: f32 = 8;
pub const titlebar_height: f32 = 38;
pub const top_pad: f32 = 4;
pub const header_height: f32 = titlebar_height + top_pad;
pub const tab_height: f32 = 32;
pub const tab_top: f32 = (header_height - tab_height) / 2;
pub const body_radius: f32 = 10;
pub const shoulder: f32 = 8;
pub const slot_min: f32 = 72;
pub const slot_max: f32 = 260;
pub const slot_room_for_add: f32 = 112;
pub const slot_room_for_close: f32 = 136;
pub const device_room: f32 = 120;
pub const panel_min: f32 = 220;
pub const right_pane_default: f32 = 520;
pub const new_tab_room: f32 = 24 + gutter;

pub const Frame = struct {
    x: f32 = 256,
    y: f32 = header_height,
    width: f32 = 936,
    height: f32 = 730,
    chat_width: f32 = 936,
    host_width: f32 = 0,
    files_width: f32 = 0,
    leading: f32 = 0,
    strip: bool = false,
};

/// How much of `width` a new side panel gets (`side_panel_share` in
/// `workspace_panels.rs`): its `preferred` width (`right_pane_width`,
/// 520 by default) while every other panel keeps `panel_min`, or an
/// equal share when the window is narrower than that.
pub fn sidePanelShare(width: f32, others: usize, preferred: f32) f32 {
    const o: f32 = @floatFromInt(others);
    const equal = 1.0 / (o + 1.0);
    const available = width - gutter * o;
    if (available <= 0) return equal;
    const room = available - o * panel_min;
    return std.math.clamp(@min(preferred, room) / available, equal, 1.0);
}

pub fn frame(width: f32, height: f32, sidebar: f32, expanded_sidebar: f32, chat_panels: usize, horizontal: bool, host: bool, files: bool) Frame {
    return frameWithSide(width, height, sidebar, expanded_sidebar, chat_panels, horizontal, host, files, right_pane_default);
}

pub fn frameWithSide(width: f32, height: f32, sidebar: f32, expanded_sidebar: f32, chat_panels: usize, horizontal: bool, host: bool, files: bool, preferred: f32) Frame {
    const leading = gutter * (1 - std.math.clamp(sidebar / @max(1, expanded_sidebar), 0, 1));
    const chats = if (horizontal) @max(chat_panels, 1) else 1;
    const count = chats + @intFromBool(host) + @intFromBool(files);
    const room = @max(0, width - sidebar - leading - gutter);
    const gaps = gutter * @as(f32, @floatFromInt(count - 1));
    const available = @max(0, room - gaps);
    // A side panel (`host`) in a horizontal row gets its preferred width
    // (`sidePanelShare`), while the other panels share the rest equally.
    const host_width: f32 = if (host and horizontal)
        available * sidePanelShare(room, count - 1, preferred)
    else if (host)
        available / @as(f32, @floatFromInt(count))
    else
        0;
    const other_count = count - @intFromBool(host and horizontal);
    const other_room = if (host and horizontal) @max(0, available - host_width) else available;
    const each = if (other_count > 0) other_room / @as(f32, @floatFromInt(other_count)) else 0;
    const files_width = if (files) each else 0;
    const chat_width = each * @as(f32, @floatFromInt(chats)) + gutter * @as(f32, @floatFromInt(chats - 1));
    return .{
        .x = sidebar + leading,
        .y = header_height,
        .width = @min(room, each * @as(f32, @floatFromInt(chats + @intFromBool(files))) + host_width + gaps),
        .height = @max(0, height - header_height - gutter),
        .chat_width = chat_width,
        .host_width = host_width,
        .files_width = files_width,
        .leading = leading,
        .strip = chat_panels > 1 or host or files,
    };
}

pub fn paneSpan(total: f32, share: f32, count: usize, horizontal: bool) f32 {
    // Horizontal workspace gutters are 8; stacked clearance is 5.
    const gap = if (horizontal) gutter else tab_top;
    return @max(0, (total - gap * @as(f32, @floatFromInt(count -| 1))) * share);
}

pub fn tabWidth(width: f32, count: usize) f32 {
    const n: f32 = @floatFromInt(@max(count, 1));
    return std.math.clamp(@max(0, width - 4 - shoulder - 3 * (n - 1)) / n, 112, 240);
}

pub fn sharedSlotRoom(width: f32, left: f32, right: f32, count: usize) f32 {
    const n: f32 = @floatFromInt(@max(count, 1));
    return (width - left - right - 24 - n * 2) / n;
}

/// Slot widths align to columns only if every slot fits. Expanded or stacked
/// panels use shared slots instead, never positions from their hidden bodies.
pub fn columns(widths: []const f32, leading: f32, left: f32, right: f32, out: []f32) bool {
    if (widths.len == 0 or out.len < widths.len) return false;
    @memcpy(out[0..widths.len], widths);
    out[0] -= left - leading;
    out[widths.len - 1] -= new_tab_room + @max(0, right - gutter);
    for (out[0..widths.len]) |w| if (w < slot_min) return false;
    return true;
}

test "desktop strip columns keep their panels' widths and reserve the trailing plus" {
    var out: [3]f32 = undefined;
    try std.testing.expect(columns(&.{ 468, 468 }, 0, 0, 8, &out));
    try std.testing.expectEqual(@as(f32, 468), out[0]);
    try std.testing.expectEqual(@as(f32, 436), out[1]);
    try std.testing.expect(!columns(&.{ 95, 95 }, 8, 44, 8, &out));
    try std.testing.expectEqual(@as(f32, 240), tabWidth(1000, 2));
    try std.testing.expectEqual(@as(f32, 112), tabWidth(200, 4));
}

test "desktop panel geometry preserves content top across split and sidebar collapse" {
    const one = frame(1200, 780, 256, 256, 1, true, false, false);
    const split = frame(1200, 780, 256, 256, 2, true, false, false);
    const closed = frame(1200, 780, 0, 256, 1, true, false, false);
    try std.testing.expectEqual(one.y, split.y);
    try std.testing.expectEqual(@as(f32, 42), one.y);
    try std.testing.expectEqual(@as(f32, 730), one.height);
    try std.testing.expectEqual(@as(f32, 8), closed.x);
    try std.testing.expectEqual(@as(f32, 464), paneSpan(split.chat_width, 0.5, 2, true));
    try std.testing.expectEqual(@as(f32, 362.5), paneSpan(split.height, 0.5, 2, false));
    try std.testing.expect(!one.strip and split.strip);
}

test "a side panel gets the old width when the others can spare it" {
    // Beside one chat it never drops under half.
    try std.testing.expectEqual(@as(f32, 0.5), sidePanelShare(1200, 1, 520));
    try std.testing.expectApproxEqAbs(@as(f32, 520), sidePanelShare(900, 1, 520) * (900 - 8), 0.01);
    // Beside three, 520 wide while each of them keeps its minimum.
    const available = 2000.0 - 8.0 * 3.0;
    try std.testing.expectApproxEqAbs(@as(f32, 520.0 / available), sidePanelShare(2000, 3, 520), 0.001);
    // No room to spare: what the others can give, down to an equal share.
    const tight = 1136.0 - 8.0 * 3.0;
    try std.testing.expectApproxEqAbs(@as(f32, (tight - 660.0) / tight), sidePanelShare(1136, 3, 520), 0.001);
    try std.testing.expectEqual(@as(f32, 0.25), sidePanelShare(600, 3, 520));
}
