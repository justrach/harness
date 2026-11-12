//! Emacs's and Vim's keys in a text field, through the Tester.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

const Keys = struct {
    buf: ui.TextBuffer = .{},
    keys: ui.Keymap,
    last: ui.TextFieldResult = .{},
    history: i8 = 0,
    fn view(k: *@This(), c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10) });
        defer ui.end(c);
        c.focus = c.peekId(null);
        k.last = ui.textField(c, &k.buf, .{ .keys = k.keys });
        // Kept: the frame may be built again, without the key.
        if (k.last.history != 0) k.history = k.last.history;
    }
};

test "Emacs's keys in a text field: ends of the line, kill and yank, words" {
    var k: Keys = .{ .keys = .emacs };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Keys.view), .{ .width = 400, .height = 100 });
    defer t.deinit();
    t.settle(1);
    t.typeText("hello brave world");
    try testing.expect(t.shortcut(.{ .key = 'w', .ctrl = true }));
    try testing.expectEqualStrings("hello brave ", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'a', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'f', .alt = true }));
    try testing.expect(t.shortcut(.{ .key = 'k', .ctrl = true }));
    try testing.expectEqualStrings("hello", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'e', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'y', .ctrl = true }));
    try testing.expectEqualStrings("hello brave ", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'u', .ctrl = true }));
    try testing.expectEqualStrings("", k.buf.text());
    // The system's keys leave ^W to the app.
    var plain: Keys = .{ .keys = .system };
    var t2: ui.Tester = undefined;
    try t2.init(testing.allocator, .init(&plain, Keys.view), .{ .width = 400, .height = 100 });
    defer t2.deinit();
    t2.settle(1);
    t2.typeText("abc");
    try testing.expect(!t2.shortcut(.{ .key = 'w', .ctrl = true }));
    try testing.expectEqualStrings("abc", plain.buf.text());
}

test "Vim's keys in a text field: normal mode, motions, operators, put" {
    var k: Keys = .{ .keys = .vim };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&k, Keys.view), .{ .width = 400, .height = 100 });
    defer t.deinit();
    t.settle(1);
    t.typeText("git commit -m wip");
    try testing.expect(!k.last.vim_normal);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    try testing.expect(k.last.vim_normal);
    // Typing is commands now: 0 to the start, dw deletes a word.
    t.typeText("0dw");
    try testing.expectEqualStrings("commit -m wip", k.buf.text());
    // $ to the end, x deletes under the caret, p puts it back after.
    t.typeText("$x");
    try testing.expectEqualStrings("commit -m wi", k.buf.text());
    t.typeText("P");
    try testing.expectEqualStrings("commit -m wpi", k.buf.text());
    // A appends in insert mode; Esc and cc changes the whole line.
    t.typeText("A!");
    try testing.expectEqualStrings("commit -m wpi!", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    t.typeText("ccnew");
    try testing.expectEqualStrings("new", k.buf.text());
    try testing.expect(!k.last.vim_normal);
    // j and k ask the app for history.
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    t.typeText("k");
    try testing.expectEqual(@as(i8, -1), k.history);
}

fn field(k: *Keys, t: *ui.Tester) !void {
    try t.init(testing.allocator, .init(k, Keys.view), .{ .width = 500, .height = 100 });
    t.settle(1);
}

fn esc(t: *ui.Tester) !void {
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
}

test "Vim: counts, text objects, f and ;, undo and redo as one insert" {
    var k: Keys = .{ .keys = .vim };
    var t: ui.Tester = undefined;
    try field(&k, &t);
    defer t.deinit();
    t.typeText("git commit -m \"fix the bug\"");
    try esc(&t);
    // ci" changes inside the quotes; the change and its typing are one undo.
    t.typeText("0f\"ci\"done");
    try testing.expectEqualStrings("git commit -m \"done\"", k.buf.text());
    try esc(&t);
    t.typeText("u");
    try testing.expectEqualStrings("git commit -m \"fix the bug\"", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'r', .ctrl = true }));
    try testing.expectEqualStrings("git commit -m \"done\"", k.buf.text());
    // 2dw: two words; d2w the same.
    t.typeText("02dw");
    try testing.expectEqualStrings("-m \"done\"", k.buf.text());
    t.typeText("u0d2w");
    try testing.expectEqualStrings("-m \"done\"", k.buf.text());
    // ; repeats the last f.
    k.buf.set("a,b,c,d");
    t.settle(0.1);
    t.typeText("0f,;x");
    try testing.expectEqualStrings("a,bc,d", k.buf.text());
    // r, ~ with a count, dt.
    t.typeText("0rz3~");
    try testing.expectEqualStrings("Z,Bc,d", k.buf.text());
    t.typeText("0dt,");
    try testing.expectEqualStrings(",Bc,d", k.buf.text());
    // A whole insert session is one undo.
    t.typeText("A and more");
    try esc(&t);
    t.typeText("u");
    try testing.expectEqualStrings(",Bc,d", k.buf.text());
}

test "Vim: visual mode, yank and put, dd, ^W in insert mode" {
    var k: Keys = .{ .keys = .vim };
    var t: ui.Tester = undefined;
    try field(&k, &t);
    defer t.deinit();
    t.typeText("hello brave world");
    // ^W in insert mode deletes the word before the caret.
    try testing.expect(t.shortcut(.{ .key = 'w', .ctrl = true }));
    try testing.expectEqualStrings("hello brave ", k.buf.text());
    t.typeText("world");
    try esc(&t);
    // v e y: the first word yanked; $ p puts it after the last character.
    t.typeText("0vey");
    try testing.expect(!k.last.vim_visual);
    t.typeText("$p");
    try testing.expectEqualStrings("hello brave worldhello", k.buf.text());
    // Visual selection, then U upcases it.
    t.typeText("0ve");
    try testing.expect(k.last.vim_visual);
    t.typeText("U");
    try testing.expectEqualStrings("HELLO brave worldhello", k.buf.text());
    // yiw then viwp swaps a word for it.
    t.typeText("wyiwwviwp");
    try testing.expectEqualStrings("HELLO brave brave", k.buf.text());
    // dd: the line; u brings it back.
    t.typeText("dd");
    try testing.expectEqualStrings("", k.buf.text());
    t.typeText("u");
    try testing.expectEqualStrings("HELLO brave brave", k.buf.text());
}

test "Emacs: transpose, case, the kill ring and M-y, the region, undo" {
    var k: Keys = .{ .keys = .emacs };
    var t: ui.Tester = undefined;
    try field(&k, &t);
    defer t.deinit();
    t.typeText("teh");
    try testing.expect(t.shortcut(.{ .key = 't', .ctrl = true }));
    try testing.expectEqualStrings("the", k.buf.text());
    k.buf.set("hello world");
    t.settle(0.1);
    try testing.expect(t.shortcut(.{ .key = 't', .alt = true }));
    try testing.expectEqualStrings("world hello", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'a', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'u', .alt = true }));
    try testing.expect(t.shortcut(.{ .key = 'c', .alt = true }));
    try testing.expectEqualStrings("WORLD Hello", k.buf.text());
    // Kills one after another join; M-y swaps a yank for the kill before.
    k.buf.set("one two three");
    t.settle(0.1);
    try testing.expect(t.shortcut(.{ .key = 'a', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'd', .alt = true }));
    try testing.expect(t.shortcut(.{ .key = 'd', .alt = true }));
    try testing.expectEqualStrings(" three", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'e', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'h', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'w', .ctrl = true }));
    try testing.expectEqualStrings(" ", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'y', .ctrl = true }));
    try testing.expectEqualStrings(" thre", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = 'y', .alt = true }));
    try testing.expectEqualStrings(" one two", k.buf.text());
    // C-/ undoes one command at a time: the M-y, then the yank.
    try testing.expect(t.shortcut(.{ .key = '/', .ctrl = true }));
    try testing.expectEqualStrings(" thre", k.buf.text());
    try testing.expect(t.shortcut(.{ .key = '/', .ctrl = true }));
    try testing.expectEqualStrings(" ", k.buf.text());
    // The mark: C-SPC, M-f, M-w copies the region; C-y puts it.
    k.buf.set("copy this");
    t.settle(0.1);
    try testing.expect(t.shortcut(.{ .key = 'a', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = ' ', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'f', .alt = true }));
    try testing.expect(t.shortcut(.{ .key = 'w', .alt = true }));
    try testing.expect(t.shortcut(.{ .key = 'e', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = 'y', .ctrl = true }));
    try testing.expectEqualStrings("copy thiscopy", k.buf.text());
}
