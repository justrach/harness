//! Unsent prompts, kept as the GPUI composer keeps them
//! (crates/ui/src/composer.rs `drafts`, pickers.rs `CanvasDraft`): each chat
//! its own, there again when the window comes back to it; a new chat's
//! prompt and picks parked with its pane or tab while another shows; and a
//! new pane or tab starting with the same picks and an empty prompt.
const std = @import("std");
const App = @import("app.zig").App;
const Draft = @import("tabs.zig").Draft;

/// The new chat's key in `App.drafts`: its prompt while a chat shows.
const canvas_key = "";

/// The composer's own prompt: set aside while a question or a queued
/// message being edited borrows the composer, and while a recalled earlier
/// prompt shows, the draft from before recall.
fn live(a: *const App) []const u8 {
    return if (a.wizard != null or a.queue_edit != null) a.draft_stash.items else a.prompt_nav.draftOf(a.composer.text());
}

/// Before the selection changes: the prompt kept under the chat it was
/// written in. A question or a queued edit in progress stays with it.
pub fn leave(a: *App) void {
    put(a, a.selected orelse canvas_key, live(a));
    a.prompt_nav.reset(a.gpa);
    if (a.wizard) |*w| w.deinit();
    a.wizard = null;
    a.draft_stash.clearRetainingCapacity();
}

/// After: the selected chat's prompt, or the new chat's, in the composer.
pub fn enter(a: *App) void {
    a.composer.set(a.drafts.get(a.selected orelse canvas_key) orelse "");
}

fn put(a: *App, key: []const u8, text: []const u8) void {
    if (text.len == 0) {
        if (a.drafts.fetchRemove(key)) |kv| {
            a.gpa.free(kv.key);
            a.gpa.free(kv.value);
        }
        return;
    }
    const value = a.gpa.dupe(u8, text) catch return;
    const got = a.drafts.getOrPut(a.gpa, key) catch return a.gpa.free(value);
    if (got.found_existing) {
        a.gpa.free(got.value_ptr.*);
    } else {
        got.key_ptr.* = a.gpa.dupe(u8, key) catch {
            a.drafts.removeByPtr(got.key_ptr);
            return a.gpa.free(value);
        };
    }
    got.value_ptr.* = value;
}

pub fn deinit(a: *App) void {
    var it = a.drafts.iterator();
    while (it.next()) |kv| {
        a.gpa.free(kv.key_ptr.*);
        a.gpa.free(kv.value_ptr.*);
    }
    a.drafts.deinit(a.gpa);
}

fn dupe(a: *App, s: ?[]const u8) !?[]u8 {
    return if (s) |x| try a.gpa.dupe(u8, x) else null;
}

/// The new chat's prompt and picks as they stand (`current_canvas_draft`).
pub fn canvas(a: *App) !Draft {
    const text = if (a.selected == null) live(a) else a.drafts.get(canvas_key) orelse "";
    var d: Draft = .{ .text = try a.gpa.dupe(u8, text), .harness = &.{} };
    errdefer d.deinit(a.gpa);
    d.harness = try a.gpa.dupe(u8, a.new_harness);
    d.model = try dupe(a, a.new_model);
    d.reasoning = try dupe(a, a.new_reasoning);
    d.space = try dupe(a, a.space);
    return d;
}

/// A parked draft back as the new chat's (`adopt_canvas_draft`); takes it.
pub fn adopt(a: *App, d: Draft) void {
    if (a.selected == null) a.composer.set(d.text) else put(a, canvas_key, d.text);
    a.gpa.free(d.text);
    a.gpa.free(a.new_harness);
    a.new_harness = d.harness;
    inline for (.{ .{ "new_model", "model" }, .{ "new_reasoning", "reasoning" }, .{ "space", "space" } }) |f| {
        if (@field(a, f[0])) |old| a.gpa.free(old);
        @field(a, f[0]) = @field(d, f[1]);
    }
    a.ensureModels(a.target().harness);
}

const testing = std.testing;

test "each chat keeps its own prompt; the new chat's is kept while a chat shows" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    a.composer.set("for the new chat");
    a.select("a", null);
    try testing.expectEqualStrings("", a.composer.text());
    a.composer.set("for a");
    a.select("b", null);
    try testing.expectEqualStrings("", a.composer.text());
    a.select("a", null);
    try testing.expectEqualStrings("for a", a.composer.text());
    var d = try canvas(&a);
    defer d.deinit(testing.allocator);
    try testing.expectEqualStrings("for the new chat", d.text);
    a.select(null, null);
    try testing.expectEqualStrings("for the new chat", a.composer.text());
}
