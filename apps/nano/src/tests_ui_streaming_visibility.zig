//! A live turn's content must be on screen, not merely present in the
//! retained node tree. Synthetic replies grow, fold, and replace parts.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const testing = std.testing;

fn apply(a: *App, text: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
}

fn visible(t: *ui.Tester, text: []const u8) !void {
    const rect = t.findText(text) orelse return error.MissingLiveText;
    if (!(rect.h > 0 and rect.y >= 38 and rect.y + rect.h < t.size.h - 80)) {
        std.debug.print("live text outside transcript: y={d} height={d} window={d}\n", .{ rect.y, rect.h, t.size.h });
        return error.LiveTextOutsideViewport;
    }
}

test "a short live turn stays visible when its expanded reasoning shrinks to tool rows" {
    @import("theme.zig").registerFonts();
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = false;
    a.view.sidebar_open = false;
    a.openChat("synthetic", null);
    try apply(&a,
        \\{"reset":[
        \\ {"id":"u1","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic first prompt"}]},
        \\ {"id":"a1","role":"assistant","status":"complete","parts":[{"id":"p","kind":"text","text":"Synthetic first answer"}]},
        \\ {"id":"u2","role":"user","parts":[{"id":"p","kind":"text","text":"Synthetic second prompt"}]},
        \\ {"id":"a2","role":"assistant","status":"streaming","parts":[{"id":"thought","kind":"reasoning","text":"Synthetic live thought"},{"id":"answer","kind":"text","text":""}]}]}
    );
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&a, @import("view.zig").view), .{ .width = 900, .height = 750, .dark = false });
    defer t.deinit();
    t.settle(1);
    try visible(&t, "Synthetic second prompt");
    try visible(&t, "Synthetic live thought");

    // A long live thought moves the viewport to its end. Replacing that
    // entry with short tool rows must clamp the old scroll offset.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);
    try frame.appendSlice(testing.allocator,
        \\{"upsert":[{"after":"u2","entry":{"id":"a2","role":"assistant","status":"streaming","parts":[{"id":"thought","kind":"reasoning","text":"
    );
    for (0..80) |_| try frame.appendSlice(testing.allocator, "A synthetic paragraph of live reasoning.\\n\\n");
    try frame.appendSlice(testing.allocator,
        \\Last synthetic live paragraph"},{"id":"answer","kind":"text","text":""}]}}],"count":4}
    );
    try apply(&a, frame.items);
    t.settle(1);
    try testing.expect(t.containsText("Last synthetic live paragraph"));

    try apply(&a,
        \\{"upsert":[{"after":"u2","entry":{"id":"a2","role":"assistant","status":"streaming","parts":[
        \\ {"id":"read1","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"synthetic-one.zig"}},
        \\ {"id":"read2","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"synthetic-two.zig"}},
        \\ {"id":"read3","kind":"tool","resolved":true,"call":{"kind":"readFile","path":"synthetic-three.zig"}},
        \\ {"id":"answer","kind":"text","text":""}]}}],"count":4}
    );
    t.settle(1);
    try visible(&t, "Synthetic second prompt");
    try visible(&t, "Read 3 files");
    t.advance(2);
    try visible(&t, "Read 3 files");

    try apply(&a,
        \\{"append":[{"entry":"a2","part":"answer","text":"Synthetic final reply","len":21}],"count":4}
    );
    t.settle(1);
    try visible(&t, "Synthetic final reply");
}
