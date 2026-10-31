//! Native text-input events, not only synthetic shortcuts: spaces and
//! Return must work in the composer and the appearance controls.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const appearance = @import("view_settings_appearance.zig");
const testing = std.testing;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        theme.registerFonts();
        theme.light_id = "codegraff-light";
        theme.dark_id = "codegraff-dark";
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.offscreen = true;
        appearance.setMode(&h.a, .light);
        const chats = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\[{"id":"input","deviceId":"synthetic","title":"Synthetic input"}]
        , .{});
        defer chats.deinit();
        try h.a.chats.replace(chats.value);
        h.a.openChat("input", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{
            .width = 1200,
            .height = 880,
            .scale = 2,
            .dark = false,
            .theme = theme.ui(false),
        });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn caretX(h: *const Harness) !f32 {
        for (h.t.ctx.nodes.items) |n| {
            if (n.content == .none and n.style.absolute and n.style.width == .px and
                n.style.width.px == 1.5 and n.style.height == .px and n.style.height.px == 22.75)
                return n.rect.x;
        }
        return error.NoComposerCaret;
    }

    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "native composer spaces advance the caret before the next word is typed" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.textOps(&.{.{ .insert = "Synthetic" }});
    const before = try h.caretX();
    h.t.textOps(&.{.{ .insert = " " }});
    try testing.expectEqualStrings("Synthetic ", h.a.composer.text());
    const one = try h.caretX();
    h.t.textOps(&.{.{ .insert = " " }});
    const two = try h.caretX();
    h.snap("composer-trailing-spaces");
    try testing.expect(one > before + 2);
    try testing.expect(two > one + 2);
    h.t.textOps(&.{.{ .insert = "website" }});
    try testing.expectEqualStrings("Synthetic  website", h.a.composer.text());
    h.t.textOps(&.{.{ .command = .move_line_start }});
    h.t.textOps(&.{.{ .insert = " " }});
    try testing.expectEqualStrings(" Synthetic  website", h.a.composer.text());
}

test "a long pasted paragraph expands the composer instead of painting over its controls" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const phrase = "Synthetic pasted text must stay inside the input, above the model and send controls. ";
    var buffer: [phrase.len * 18]u8 = undefined;
    for (0..18) |i| @memcpy(buffer[i * phrase.len ..][0..phrase.len], phrase);
    const paragraph: []const u8 = &buffer;
    h.t.textOps(&.{.{ .insert = paragraph }});
    h.t.settle(0.3);
    try testing.expectEqualStrings(paragraph, h.a.composer.text());
    h.snap("composer-pasted-paragraph");
    const pill = h.a.view.composer_anchor.?;
    try testing.expect(pill.h > 100);
    const field = h.t.ctx.rects.get(h.a.view.composer_id) orelse return error.NoComposerField;
    try testing.expect(field.y >= pill.y);
    try testing.expect(field.y + field.h <= pill.y + pill.h - 32);
    try testing.expectEqual(h.a.view.composer_id, h.t.ctx.focus);
    h.t.textOps(&.{.{ .command = .select_all }});
    h.t.textOps(&.{.{ .insert = "Short again" }});
    h.t.settle(0.3);
    try testing.expectEqualStrings("Short again", h.a.composer.text());
    try testing.expectApproxEqAbs(@as(f32, 49), h.a.view.composer_anchor.?.h, 1);
}

const ClipboardFixture = struct {
    text: []const u8 = "",
    image: bool = false,
    reads: usize = 0,

    fn read(raw: ?*anyopaque, gpa: std.mem.Allocator) !?@import("app_attachments.zig").Paste {
        const self: *ClipboardFixture = @ptrCast(@alignCast(raw.?));
        self.reads += 1;
        if (self.image) return .{ .image = try gpa.dupe(u8, @embedFile("icons/project-default.png")) };
        return .{ .text = try gpa.dupe(u8, self.text) };
    }
};

test "composer Paste preserves paragraphs, replaces the selection, and leaves other fields alone" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var clipboard: ClipboardFixture = .{ .text = "First synthetic paragraph\r\n\r\nSecond paragraph\nLast line" };
    h.a.attachments.source = .{ .ctx = &clipboard, .read = ClipboardFixture.read };
    h.t.textOps(&.{.{ .insert = "replace this" }});
    h.t.textOps(&.{.{ .command = .select_all }});
    try testing.expect(h.t.shortcut(.{ .key = 'v', .cmd = true }));
    h.t.settle(0.3);
    try testing.expectEqualStrings("First synthetic paragraph\n\nSecond paragraph\nLast line", h.a.composer.text());
    try testing.expectEqual(@as(usize, 1), clipboard.reads);
    try testing.expect(h.a.view.composer_anchor.?.h > 100);
    h.snap("composer-pasted-paragraphs");
    h.t.ctx.focus = 0;
    try testing.expect(!h.t.shortcut(.{ .key = 'v', .cmd = true }));
    try testing.expectEqual(@as(usize, 1), clipboard.reads);
}

test "a paste beyond the editing buffer is kept losslessly as a text attachment" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var bytes: [20 * 1024]u8 = undefined;
    @memset(&bytes, 'x');
    @memcpy(bytes[bytes.len - 12 ..], "complete end");
    var clipboard: ClipboardFixture = .{ .text = &bytes };
    h.a.attachments.source = .{ .ctx = &clipboard, .read = ClipboardFixture.read };
    h.t.textOps(&.{.{ .insert = "Keep this introduction" }});
    try testing.expect(h.t.shortcut(.{ .key = 'v', .cmd = true }));
    h.t.settle(0.3);
    try testing.expectEqualStrings("Keep this introduction", h.a.composer.text());
    try testing.expectEqual(@as(usize, 1), @import("app_attachments.zig").count(&h.a));
    const item = h.a.attachments.items.items[0];
    try testing.expectEqualStrings("pasted-text.txt", item.name);
    try testing.expectEqualSlices(u8, &bytes, item.bytes);
    // Its tile is the file's icon: the text was never decoded as a picture.
    for (h.t.text.images.decoded.values()) |d| try testing.expect(d != null);
}

test "image Paste stages one removable preview and enables image-only send after upload" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"UploadChunk":{},"UploadCommit":{"path":"/synthetic/uploads/image.png"},"QueueCommand":{}}
    , .{});
    h.a.engine.state = .connected;
    var clipboard: ClipboardFixture = .{ .image = true };
    h.a.attachments.source = .{ .ctx = &clipboard, .read = ClipboardFixture.read };
    try testing.expect(h.t.shortcut(.{ .key = 'v', .cmd = true }));
    h.t.settle(0.3);
    const attachments = @import("app_attachments.zig");
    try testing.expectEqual(@as(usize, 1), clipboard.reads);
    try testing.expectEqual(@as(usize, 1), attachments.count(&h.a));
    try testing.expect(attachments.ready(&h.a));
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expect(h.t.hasText("image.png"));
    h.snap("composer-pasted-image");
    h.a.send();
    h.t.frame();
    try testing.expectEqual(@as(usize, 0), attachments.count(&h.a));
    try testing.expectEqual(@as(usize, 1), h.a.pending_sends.items.len);
    try testing.expect(std.mem.indexOf(u8, h.a.pending_sends.items[0].part.text.items, "/synthetic/uploads/image.png") != null);
}

test "native Return activates the command palette dark theme result" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = h.t.shortcut(.{ .key = 'k', .cmd = true });
    h.t.textOps(&.{.{ .insert = "dark" }});
    try testing.expect(h.t.hasText("Switch to dark theme"));
    h.t.textOps(&.{.{ .command = .insert_newline }});
    h.snap("palette-native-dark");
    try testing.expectEqual(true, h.a.dark.?);
    try testing.expectEqualDeep(theme.ui(true).background, h.t.ctx.theme.background);
    try testing.expect(h.a.view.palette.open);
    h.t.textOps(&.{.{ .command = .insert_newline }});
    // The old dark-only query has no matching action after switching.
    try testing.expectEqual(true, h.a.dark.?);
}

test "shortcut Return repaints the selected appearance in the same frame" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = h.t.shortcut(.{ .key = 'k', .cmd = true });
    h.t.textOps(&.{.{ .insert = "theme" }});
    _ = h.t.shortcut(.{ .key = ui.Shortcut.enter });
    try testing.expectEqual(true, h.a.dark.?);
    try testing.expectEqualDeep(theme.ui(true).background, h.t.ctx.theme.background);
}

test "the theme picker opens and applies a palette without an unrelated input" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .appearance;
    h.t.settle(1);
    const alternate = for (@import("themes.zig").all()) |v| {
        if (!v.dark and !std.mem.eql(u8, v.id, "codegraff-light")) break v;
    } else return error.NoAlternateLightTheme;
    try h.t.clickText("Codegraff Light");
    try testing.expect(h.a.view.theme_menu != null);
    h.snap("theme-picker-open");
    try testing.expect(h.t.hasText(alternate.name));
    try h.t.clickText(alternate.name);
    h.snap("theme-picker-selected");
    try testing.expect(h.a.view.theme_menu == null);
    try testing.expectEqualStrings(alternate.id, h.a.settings.themeId(false));
    const colors = @import("surface_palette.zig").apply(alternate.colors, alternate.colors.recommended_frosted);
    const background: ui.Color = if (colors.frosted) .transparent else colors.shell;
    try testing.expectEqualDeep(background, h.t.ctx.theme.background);
    try testing.expectEqualDeep(colors.composer, h.t.ctx.theme.surface);
}
