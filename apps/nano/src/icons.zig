//! Harness's icons (crates/ui/assets/icons: Solar Linear, CC BY 4.0, and the
//! agents' marks), embedded from the GPUI app's original SVG files. Drawn
//! at the screen's pixel density and tinted with the surrounding text.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Name = enum {
    @"action-build",
    @"action-configure",
    @"action-debug",
    @"action-lint",
    @"action-play",
    @"action-test",
    @"add-circle",
    @"alt-arrow-down",
    @"alt-arrow-left",
    @"alt-arrow-right",
    @"antigravity-mark",
    @"archive-minimalistic",
    @"archive-up-minimalistic",
    @"arrow-left",
    @"arrow-right",
    @"arrow-up",
    @"arrow-up-right",
    bell,
    bot,
    calendar,
    @"chat-round-line",
    check,
    checklist,
    @"claude-mark",
    @"clock-circle",
    close,
    cloud,
    copy,
    @"cursor-mark",
    @"danger-triangle",
    @"devin-mark",
    document,
    @"document-add",
    @"exo-mark",
    eye,
    @"eye-closed",
    @"fast-tier",
    @"file-code",
    @"file-image",
    @"file-tree",
    @"fold-vertical",
    folder,
    @"folder-with-files",
    @"git-branch",
    global,
    globe,
    @"graff-mark",
    @"grok-mark",
    @"hermes-mark",
    @"key-minimalistic",
    keyboard,
    laptop,
    list,
    @"logout-2",
    @"magic-stick-3",
    magnifer,
    @"maker-deepseek",
    @"maker-gemini",
    @"maker-kimi",
    @"maker-meta",
    @"maker-mimo",
    @"maker-minimax",
    @"maker-mistral",
    @"maker-qwen",
    @"maker-zai",
    microphone,
    monitor,
    moon,
    @"more-horizontal",
    @"openai-mark",
    @"opencode-mark",
    @"palette-search",
    paperclip,
    pen,
    @"pen-new-square",
    @"pi-mark",
    pin,
    plus,
    @"project-default",
    @"pull-request",
    @"queue-drag-handle",
    refresh,
    @"remote-server",
    restart,
    @"settings-minimalistic",
    @"sidebar-minimalistic",
    @"sidebar-minimalistic-left",
    smartphone,
    @"sort-vertical",
    @"split-columns",
    star,
    @"star-bold",
    sun,
    terminal,
    @"trash-bin-minimalistic",
    tuning,
    @"volume-loud",
    widget,
    @"wifi-off",
    @"wrap-text",
};

const bytes: std.EnumArray(Name, []const u8) = blk: {
    var a: std.EnumArray(Name, []const u8) = .initUndefined();
    for (std.enums.values(Name)) |n| a.set(n, @import("icons_svg").get(@tagName(n)));
    break :blk a;
};

/// `name` at `size` points, tinted `color`, centred in a `frame` box (its
/// size when 0).
pub fn icon(c: *ui.Context, name: Name, size: f32, color: ui.Color, frame: f32) void {
    const f = if (frame > 0) frame else size;
    const box = ui.div(c).row().size(f, f).center();
    defer box.end();
    _ = ui.svg(c, .{
        .key = @tagName(name),
        .bytes = bytes.get(name),
        .size = size,
        .color = color,
    });
}

/// An agent's mark and the colour it keeps (Claude's, also the mock
/// agent's), else null: tinted like the text around it
/// (`harness_brand_icon`, crates/ui/src/pickers.rs).
pub fn harnessMark(harness: []const u8) struct { name: Name, brand: ?ui.Color } {
    const eq = std.mem.eql;
    if (eq(u8, harness, "claude-code") or eq(u8, harness, "mock")) return .{ .name = .@"claude-mark", .brand = .hex(0xd97757) };
    const name: Name = if (eq(u8, harness, "codex"))
        .@"openai-mark"
    else if (eq(u8, harness, "cursor"))
        .@"cursor-mark"
    else if (eq(u8, harness, "devin"))
        .@"devin-mark"
    else if (eq(u8, harness, "grok"))
        .@"grok-mark"
    else if (eq(u8, harness, "hermes"))
        .@"hermes-mark"
    else if (eq(u8, harness, "pi"))
        .@"pi-mark"
    else if (eq(u8, harness, "opencode"))
        .@"opencode-mark"
    else if (eq(u8, harness, "antigravity"))
        .@"antigravity-mark"
    else if (eq(u8, harness, "exo"))
        .@"exo-mark"
    else
        .@"graff-mark";
    return .{ .name = name, .brand = null };
}

/// Engine tools that arrive by name still deserve a meaningful glyph, not
/// the same generic widget for reads, commands, todos and workflow trees.
/// Every mark is an original Harness SVG from the existing shared bundle.
pub fn namedTool(raw: []const u8) Name {
    var name = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name = name[dot + 1 ..];
    const mappings = .{
        .{ "shell", Name.terminal },        .{ "bash", Name.terminal },               .{ "rlm", Name.terminal },
        .{ "read_file", Name.document },    .{ "read_tool_result", Name.document },   .{ "write_file", Name.@"document-add" },
        .{ "edit_file", Name.pen },         .{ "todo_write", Name.checklist },        .{ "todo_read", Name.checklist },
        .{ "workflow", Name.@"file-tree" }, .{ "codedb", Name.magnifer },             .{ "subagent", Name.bot },
        .{ "subagent_resume", Name.bot },   .{ "ask_user", Name.@"chat-round-line" }, .{ "webfetch", Name.global },
    };
    inline for (mappings) |m| if (std.mem.eql(u8, name, m[0])) return m[1];
    return .widget;
}

test "named tools reuse Harness's semantic SVGs instead of a generic widget" {
    try std.testing.expectEqual(Name.checklist, namedTool("todo_write"));
    try std.testing.expectEqual(Name.checklist, namedTool("functions.todo_write"));
    try std.testing.expectEqual(Name.@"file-tree", namedTool("workflow"));
    try std.testing.expectEqual(Name.document, namedTool("read_file"));
    try std.testing.expectEqual(Name.terminal, namedTool("functions.shell"));
    try std.testing.expectEqual(Name.widget, namedTool("synthetic_unknown_tool"));
}

fn iconSheet(_: *u8, c: *ui.Context) void {
    const row = ui.div(c).row();
    defer row.end();
    for (std.enums.values(Name)) |name| icon(c, name, 14, .hex(0x765432), 18);
}

test "every original Harness SVG renders at screen density inside its existing frame" {
    for ([_]f32{ 1, 2 }) |scale| {
        var state: u8 = 0;
        var t: ui.Tester = undefined;
        try t.init(std.testing.allocator, .init(&state, iconSheet), .{ .scale = scale });
        defer t.deinit();
        var count: usize = 0;
        for (t.ctx.nodes.items) |node| switch (node.content) {
            .image => |im| {
                const decoded = t.text.images.decoded.get(im.key).?.?;
                try std.testing.expectEqual(@as(u32, @intFromFloat(14 * scale)), decoded.width);
                try std.testing.expectEqual(decoded.width, decoded.height);
                try std.testing.expectEqual(@as(f32, 14), node.rect.w);
                try std.testing.expectEqual(@as(f32, 14), node.rect.h);
                count += 1;
            },
            else => {},
        };
        try std.testing.expectEqual(std.enums.values(Name).len, count);
        const cached = t.text.images.decoded.count();
        t.frame();
        try std.testing.expectEqual(cached, t.text.images.decoded.count());
    }
}

test "every agent has a mark; Claude's and the mock's keep Claude's colour" {
    try std.testing.expectEqual(Name.@"claude-mark", harnessMark("mock").name);
    try std.testing.expect(harnessMark("claude-code").brand != null);
    try std.testing.expectEqual(Name.@"openai-mark", harnessMark("codex").name);
    try std.testing.expect(harnessMark("codex").brand == null);
    try std.testing.expectEqual(Name.@"graff-mark", harnessMark("graff").name);
}
