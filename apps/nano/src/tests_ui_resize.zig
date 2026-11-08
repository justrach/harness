//! Window-resize contracts: the shell, its panels and the composer stay
//! inside the live bounds at every width, including narrow split layouts.
const std = @import("std");
const testing = std.testing;
const Harness = @import("tests_ui_tab_strip.zig").Harness;
const chrome = @import("panel_chrome.zig");

test "window resizing keeps multi-panel chrome and composer inside the window" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.a.splitPane(.horizontal);
    h.a.panels.host_open = true;
    h.a.panels.files_open = true;
    h.t.settle(1);

    const sizes = [_][2]f32{
        .{ 1200, 780 },
        .{ 980, 640 },
        .{ 900, 600 },
        .{ 840, 520 },
        .{ 760, 480 },
        .{ 1320, 880 },
        .{ 720, 720 },
    };
    for (sizes) |size| {
        h.t.resize(size[0], size[1]);
        h.t.settle(0.3);
        const f = h.a.view.chrome;
        try testing.expect(std.math.isFinite(f.x) and std.math.isFinite(f.width));
        try testing.expect(std.math.isFinite(f.height));
        try testing.expect(f.x >= 0);
        try testing.expect(f.x + f.width <= size[0] + 0.51);
        try testing.expect(f.width >= 0 and f.height >= 0);
        const pill = h.a.view.composer_anchor orelse return error.NoComposer;
        try testing.expect(std.math.isFinite(pill.x) and std.math.isFinite(pill.w));
        try testing.expect(pill.x >= f.x - 0.51);
        try testing.expect(pill.x + pill.w <= f.x + f.width + 0.51);
        try testing.expect(pill.y + pill.h <= size[1] + 0.51);
    }
}

test "narrow panels share the available room instead of using a fixed minimum" {
    const f = chrome.frame(760, 480, 224, 224, 2, true, true, true);
    try testing.expectApproxEqAbs(@as(f32, 760 - 224 - chrome.gutter), f.width, 0.01);
    try testing.expect(f.chat_width + chrome.gutter + f.host_width + chrome.gutter + f.files_width <= f.width + 0.01);
    // Ordinary widths still have generous panes.
    const wide = chrome.frame(1600, 900, 224, 224, 2, true, true, true);
    try testing.expect(wide.chat_width > 500);
}

test "Cmd B stays continuous through a live window resize" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const width = @import("settings.zig").sidebar_default;
    h.press(.{ .key = 'b', .cmd = true });
    var previous = width;
    var saw_motion = false;
    const sizes = [_]f32{ 1200, 1040, 900, 800, 1320 };
    for (sizes, 0..) |w, i| {
        h.t.resize(w, 780);
        h.t.advance(0.02);
        const now = h.a.view.sidebar_width;
        try testing.expect(std.math.isFinite(now));
        try testing.expect(now >= 0 and now <= width + 0.01);
        if (now < previous - 0.01) saw_motion = true;
        try testing.expect(now <= previous + 0.01);
        previous = now;
        if (i == sizes.len - 1) h.t.advance(0.3);
    }
    try testing.expect(saw_motion);
    try testing.expectApproxEqAbs(@as(f32, 0), h.a.view.sidebar_width, 0.01);
}
