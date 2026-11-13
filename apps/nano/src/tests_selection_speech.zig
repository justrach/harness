//! Native macOS selected-text queries used by Spoken Content. Synthetic
//! replies only; no system speech preferences or live windows are changed.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const testing = std.testing;
const App = @import("app.zig").App;
const objc = nanoui.objc;
const first = "Synthetic café 👩‍💻 starts here.";
const second = "A second synthetic paragraph ends here.";
const selected = first ++ "\n" ++ second;

const NativeSpeech = struct {
    a: App,
    runtime: nanoui.App,
    window: *nanoui.Window,

    fn view(n: *@This(), c: *ui.Context) void {
        // The native window stays hidden; emulate activation only inside
        // this fixture's context so selection survives its synthetic frames.
        c.window_focused = true;
        @import("view.zig").view(&n.a, c);
    }

    fn init(n: *@This()) !void {
        @import("theme.zig").registerFonts();
        n.a = .init(testing.allocator, testing.io, 1);
        n.a.offscreen = true;
        n.a.openChat("speech-fixture", null);
        n.a.composer.set("Synthetic draft must not be read instead of the selection.");
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
            \\{"reset":[{"id":"speech-output","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic café 👩‍💻 starts here.\n\nA second synthetic paragraph ends here."}]}]}
        , .{});
        defer parsed.deinit();
        try n.a.transcript.apply(parsed.value);
        const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
        n.runtime = .{ .gpa = testing.allocator, .io = testing.io, .options = .{ .quit_on_last_window_closed = false }, .nsapp = nsapp, .delegate = nsapp, .flags = .{ .hidden = true } };
        n.a.view.focus_composer = true;
        n.window = try n.runtime.newWindow(.{ .width = 1200, .height = 780, .visible = false, .content = .{ .view = .init(n, NativeSpeech.view) } });
        n.frame();
    }

    fn deinit(n: *@This()) void {
        n.runtime.running = true;
        n.window.close();
        nanoui.runFor(0.1);
        n.runtime.running = false;
        n.runtime.windows.deinit(testing.allocator);
        n.a.deinit();
    }

    fn frame(n: *@This()) void {
        const s = n.window.surface.?;
        s.ctx.frame = 0; // A synchronous frame for a never-shown window.
        s.frame();
    }

    fn key(n: *@This(), chars: []const u8, code: u16, flags: objc.NSUInteger) void {
        const s = n.window.surface.?;
        s.ctx.frame = 0;
        const event = objc.msg(objc.Object, objc.class("NSEvent"), "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
            @as(objc.NSUInteger, 10),                                         objc.CGPoint{},          flags,                @as(f64, 0),
            objc.msg(objc.NSInteger, n.window.nswindow, "windowNumber", .{}), @as(?objc.Object, null), objc.nsString(chars), objc.nsString(chars),
            objc.NO,                                                          code,
        });
        // In-process dispatch, not a system-wide hotkey or synthesized input
        // into another application. This checks Harness's modifier routing.
        objc.msg(void, s.nsview, "keyDown:", .{event});
    }

    fn textRect(n: *@This(), text: []const u8) !ui.Rect {
        for (n.window.surface.?.ctx.nodes.items) |node| {
            if (node.content == .text and std.mem.eql(u8, node.content.text.str, text)) return node.rect;
        }
        return error.SyntheticTextMissing;
    }

    fn selectOutput(n: *@This()) !void {
        const c = &n.window.surface.?.ctx;
        const a = try n.textRect(first);
        const b = try n.textRect(second);
        c.input.mouse = .{ .x = a.x, .y = a.y + a.h / 2 };
        c.updateHot();
        c.input.click_count = 1;
        c.pointerDown();
        n.frame();
        c.input.mouse = .{ .x = b.x + b.w, .y = b.y + b.h / 2 };
        n.frame();
        c.pointerUp();
        n.frame();
        n.frame();
    }
};

fn has(obj: objc.Object, name: [:0]const u8) bool {
    return objc.msg(objc.BOOL, obj, "respondsToSelector:", .{objc.sel(name)});
}

test "native speech exposes the highlighted output and UTF16 range to macOS" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    var n: NativeSpeech = undefined;
    try n.init();
    defer n.deinit();
    try n.selectOutput();
    const s = n.window.surface.?;
    try testing.expect(s.ctx.selection.anchor != null);
    try testing.expect(has(s.nsview, "accessibilitySelectedText"));
    try testing.expectEqualStrings(selected, objc.fromNSString(objc.msg(?objc.Object, s.nsview, "accessibilitySelectedText", .{})));
    try testing.expect(has(s.nsview, "accessibilityFocusedUIElement"));
    const focused = objc.msg(?objc.Object, s.nsview, "accessibilityFocusedUIElement", .{}) orelse return error.NativeSelectionFocusMissing;
    try testing.expect(has(focused, "accessibilitySelectedText"));
    try testing.expectEqualStrings("AXTextArea", objc.fromNSString(objc.msg(?objc.Object, focused, "accessibilityRole", .{})));
    try testing.expect(!objc.msg(objc.BOOL, focused, "isAccessibilityEditable", .{}));
    const children = objc.msg(objc.Object, s.nsview, "accessibilityChildren", .{});
    try testing.expect(objc.msg(objc.BOOL, children, "containsObject:", .{focused}));
    try testing.expectEqualStrings(selected, objc.fromNSString(objc.msg(?objc.Object, focused, "accessibilitySelectedText", .{})));
    const Range = extern struct { location: usize, length: usize };
    const range = objc.msg(Range, focused, "accessibilitySelectedTextRange", .{});
    const value = objc.msg(objc.Object, focused, "accessibilityValue", .{});
    try testing.expectEqualStrings(selected, objc.fromNSString(objc.msg(?objc.Object, value, "substringWithRange:", .{range})));
    try testing.expectEqual(objc.msg(usize, objc.nsString(selected), "length", .{}), range.length);
    // Repeated native queries must not repaint, change focus, or erase it.
    const anchor = s.ctx.selection.anchor;
    const focus = s.ctx.focus;
    const frame = s.ctx.frame;
    for (0..5) |_| try testing.expectEqualStrings(selected, objc.fromNSString(objc.msg(?objc.Object, focused, "accessibilitySelectedText", .{})));
    try testing.expectEqual(anchor, s.ctx.selection.anchor);
    try testing.expectEqual(focus, s.ctx.focus);
    try testing.expectEqual(frame, s.ctx.frame);
    n.key("\x1b", 53, 1 << 19); // Option-Escape must not erase the selection.
    try testing.expectEqualStrings(selected, objc.fromNSString(objc.msg(?objc.Object, s.nsview, "accessibilitySelectedText", .{})));
    try testing.expectEqual(focused, objc.msg(?objc.Object, s.nsview, "accessibilityFocusedUIElement", .{}).?);
}

test "native speech withdraws stale selection after output is replaced" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    var n: NativeSpeech = undefined;
    try n.init();
    defer n.deinit();
    try n.selectOutput();
    const s = n.window.surface.?;
    try testing.expect(has(s.nsview, "accessibilitySelectedText"));
    try testing.expect(has(s.nsview, "accessibilityFocusedUIElement"));
    const old = objc.msg(?objc.Object, s.nsview, "accessibilityFocusedUIElement", .{}) orelse return error.NativeSelectionFocusMissing;
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"reset":[{"id":"replacement","role":"assistant","parts":[{"id":"p","kind":"text","text":"Replacement synthetic output."}]}]}
    , .{});
    defer parsed.deinit();
    try n.a.transcript.apply(parsed.value);
    n.frame();
    try testing.expectEqualStrings("", objc.fromNSString(objc.msg(?objc.Object, s.nsview, "accessibilitySelectedText", .{})));
    try testing.expectEqualStrings("", objc.fromNSString(objc.msg(?objc.Object, old, "accessibilitySelectedText", .{})));
    try testing.expect(!objc.msg(objc.BOOL, old, "isAccessibilityFocused", .{}));
}

test "native speech exports the real composer selection without changing text input" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    var n: NativeSpeech = undefined;
    try n.init();
    defer n.deinit();
    const text = "Synthetic draft café 👩‍💻.";
    n.a.composer.set(text);
    n.frame();
    n.key("a", 0, 1 << 20); // AppKit's real Cmd-A -> Select All input path.
    const s = n.window.surface.?;
    try testing.expectEqualStrings(text, objc.fromNSString(objc.msg(?objc.Object, s.nsview, "accessibilitySelectedText", .{})));
    const focused = objc.msg(?objc.Object, s.nsview, "accessibilityFocusedUIElement", .{}) orelse return error.NativeSelectionFocusMissing;
    try testing.expectEqualStrings("AXTextField", objc.fromNSString(objc.msg(?objc.Object, focused, "accessibilityRole", .{})));
    try testing.expectEqualStrings(text, objc.fromNSString(objc.msg(?objc.Object, focused, "accessibilitySelectedText", .{})));
    const Range = extern struct { location: usize, length: usize };
    const range = objc.msg(Range, focused, "accessibilitySelectedTextRange", .{});
    try testing.expectEqual(@as(usize, 0), range.location);
    try testing.expectEqual(objc.msg(usize, objc.nsString(text), "length", .{}), range.length);
    const input_range = objc.msg(Range, s.nsview, "selectedRange", .{});
    try testing.expectEqual(range, input_range);
    try testing.expectEqualStrings(text, n.a.composer.text());
}

test "native speech selection is isolated between native windows" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    var a: NativeSpeech = undefined;
    try a.init();
    defer a.deinit();
    var b: NativeSpeech = undefined;
    try b.init();
    defer b.deinit();
    try a.selectOutput();
    try testing.expectEqualStrings(selected, objc.fromNSString(objc.msg(?objc.Object, a.window.surface.?.nsview, "accessibilitySelectedText", .{})));
    try testing.expectEqualStrings("", objc.fromNSString(objc.msg(?objc.Object, b.window.surface.?.nsview, "accessibilitySelectedText", .{})));
}
