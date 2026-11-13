//! Conversation-owned workspace text editors. Every write uses the original
//! checkout/content fences and captured remote target; navigation never retargets it.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const rpc = @import("rpc.zig");
const Allocator = std.mem.Allocator;
pub const limit = 1024 * 1024;
test {
    _ = @import("tests_file_editor.zig");
}
pub const Target = struct {
    chatId: ?[]const u8 = null,
    spaceId: ?[]const u8 = null,
    checkoutPath: ?[]const u8 = null,
    targetDeviceId: ?[]const u8 = null,
};
const Snapshot = struct { text: []u8, revision: u64 };
pub const Editor = struct {
    app: *App,
    target: Target,
    path: []u8,
    id: u64,
    origin: @import("tab_history.zig").Identity,
    buffer: ui.TextBuffer = .{},
    baseline: []u8 = &.{},
    checkout: []u8 = &.{},
    hash: []u8 = &.{},
    encoding: []const u8 = "utf8",
    ending: []const u8 = "lf",
    loading: bool = true,
    editable: bool = false,
    conflict: bool = false,
    error_text: ?[]u8 = null,
    revision: u64 = 0,
    saved_revision: u64 = 0,
    read_id: ?u64 = null,
    save_id: ?u64 = null,
    pending: ?Snapshot = null,
    field: u64 = 0,
    focus: bool = false,
    focused: bool = false,
    preview: bool = false,

    pub fn create(a: *App, path: []const u8) !*Editor {
        if (!validPath(path)) return error.InvalidWorkspacePath;
        const e = try a.gpa.create(Editor);
        errdefer a.gpa.destroy(e);
        const owned_path = try a.gpa.dupe(u8, path);
        errdefer a.gpa.free(owned_path);
        e.* = .{ .app = a, .path = owned_path, .target = .{}, .id = a.panels.bumpShown(), .origin = a.tabs.identities.items[a.tabs.active] };
        if (a.selected) |chat| {
            const metadata = a.findChat(chat) orelse return error.MissingFileOwner;
            e.target.chatId = try a.gpa.dupe(u8, chat);
            errdefer a.gpa.free(e.target.chatId.?);
            if (metadata.device_id) |host| e.target.targetDeviceId = try a.gpa.dupe(u8, host);
        } else {
            const space = a.newChatSpace() orelse return error.MissingFileOwner;
            e.target.spaceId = try a.gpa.dupe(u8, space.id);
            errdefer a.gpa.free(e.target.spaceId.?);
            e.target.checkoutPath = try a.gpa.dupe(u8, space.path);
            errdefer a.gpa.free(e.target.checkoutPath.?);
            if (a.draftDevice()) |host| e.target.targetDeviceId = try a.gpa.dupe(u8, host);
        }
        if (a.tabs.layout()) |layout| e.origin.pane = layout.identities[layout.focus];
        e.preview = std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown");
        return e;
    }
    pub fn destroy(e: *Editor) void {
        const a = e.app;
        if (!a.engine.stopping.load(.acquire)) {
            if (e.read_id) |id| a.engine.cancel(id);
            if (e.save_id) |id| a.engine.cancel(id);
        }
        if (e.pending) |pending| a.gpa.free(pending.text);
        @import("text_buffer.zig").deinit(&e.buffer);
        a.gpa.free(e.path);
        a.gpa.free(e.baseline);
        a.gpa.free(e.checkout);
        a.gpa.free(e.hash);
        if (e.error_text) |text| a.gpa.free(text);
        inline for (.{ "chatId", "spaceId", "checkoutPath", "targetDeviceId" }) |field| if (@field(e.target, field)) |text| a.gpa.free(text);
        a.gpa.destroy(e);
    }
    fn originIsCurrent(e: *const Editor) bool {
        const a = e.app;
        const identity = a.tabs.identities.items[a.tabs.active];
        const pane = if (a.tabs.layout()) |layout| layout.identities[layout.focus] else identity.pane;
        return identity.workspace == e.origin.workspace and pane == e.origin.pane;
    }
    pub fn belongsTo(e: *const Editor, chat: ?[]const u8) bool {
        // A draft may become a conversation after its editor was opened.
        // Its captured space target remains valid, and its pane identity
        // keeps the surface visible without replacing that new conversation.
        return if (e.target.chatId) |owner| same(owner, chat) else e.originIsCurrent();
    }
    pub fn matchesCurrent(e: *const Editor, a: *const App) bool {
        return same(e.target.chatId, a.selected) and (e.target.chatId != null or e.originIsCurrent());
    }
    pub fn dirty(e: *const Editor) bool {
        return e.pending != null or e.revision != e.saved_revision or !std.mem.eql(u8, e.baseline, e.buffer.text());
    }
    pub fn changed(e: *Editor) void {
        e.revision +%= 1;
        e.app.redraw();
    }
    fn errorMessage(e: *Editor, message: ?[]const u8) void {
        if (e.error_text) |old| e.app.retireSlice(old);
        e.error_text = if (message) |text| e.app.gpa.dupe(u8, text) catch null else null;
    }
    pub fn read(e: *Editor) void {
        if (e.read_id != null or e.pending != null or e.dirty()) return;
        e.loading = true;
        e.errorMessage(null);
        e.read_id = e.app.engine.mux.next_id;
        e.read_id = e.app.send_(@import("requests.zig").readWorkspaceFile(.{ .chatId = e.target.chatId, .spaceId = e.target.spaceId, .checkoutPath = e.target.checkoutPath, .targetDeviceId = e.target.targetDeviceId, .path = e.path }), .of(Editor, e, onRead));
    }
    fn onRead(e: *Editor, id: u64, reply: rpc.Reply) void {
        if (id != 0 and e.read_id != id) return;
        e.read_id = null;
        e.loading = false;
        switch (reply) {
            .ok => |value| e.acceptRead(value) catch e.errorMessage("Could not retain file contents"),
            .err => |why| e.errorMessage(why),
            else => return,
        }
        e.app.redraw();
    }
    fn acceptRead(e: *Editor, value: std.json.Value) !void {
        if (e.dirty()) return e.errorMessage("File refresh did not replace unsaved edits");
        e.editable = false;
        if (value != .object) return e.errorMessage("Invalid file read response");
        const returned_path = str(value, "path") orelse return e.errorMessage("Missing file path in read response");
        if (!std.mem.eql(u8, returned_path, e.path)) return e.errorMessage("File read returned a different path");
        const text = str(value, "text") orelse {
            e.editable = false;
            return e.errorMessage(str(value, "readOnlyReason") orelse "This file cannot be shown as text");
        };
        const baseline = try e.app.gpa.dupe(u8, text);
        e.app.gpa.free(e.baseline);
        e.baseline = baseline;
        e.buffer.set(text);
        const checkout = try e.app.gpa.dupe(u8, str(value, "checkoutId") orelse "");
        e.app.gpa.free(e.checkout);
        e.checkout = checkout;
        const hash = try e.app.gpa.dupe(u8, str(value, "contentHash") orelse "");
        e.app.gpa.free(e.hash);
        e.hash = hash;
        const encoding = str(value, "encoding") orelse "unsupported";
        const ending = str(value, "lineEnding") orelse "mixed";
        e.encoding = if (std.mem.eql(u8, encoding, "utf8Bom")) "utf8Bom" else "utf8";
        e.ending = if (std.mem.eql(u8, ending, "crlf")) "crlf" else "lf";
        const writable_encoding = std.mem.eql(u8, encoding, "utf8") or std.mem.eql(u8, encoding, "utf8Bom");
        const writable_ending = std.mem.eql(u8, ending, "lf") or std.mem.eql(u8, ending, "crlf") or std.mem.eql(u8, ending, "none");
        const reason = value.object.get("readOnlyReason");
        const size = value.object.get("size");
        const within_limit = if (size) |v| v == .integer and v.integer >= 0 and v.integer <= limit else false;
        const truncated = value.object.get("truncated");
        e.editable = e.checkout.len > 0 and e.hash.len > 0 and writable_encoding and writable_ending and within_limit and
            !(if (truncated) |v| v != .bool or v.bool else true) and (reason == null or reason.? == .null) and
            validText(text, e.encoding, e.ending);
        e.conflict = false;
        e.revision = 0;
        e.saved_revision = 0;
        e.errorMessage(if (e.editable) null else str(value, "readOnlyReason") orelse "Read-only file: missing writable snapshot authority");
    }
    pub fn save(e: *Editor) bool {
        if (!e.editable or e.loading or e.pending != null or e.conflict or !e.dirty()) return false;
        if (!validText(e.buffer.text(), e.encoding, e.ending)) {
            e.errorMessage("File exceeds the editable limit or contains unsupported text");
            return false;
        }
        const text = e.app.gpa.dupe(u8, e.buffer.text()) catch return false;
        e.pending = .{ .text = text, .revision = e.revision };
        e.errorMessage(null);
        e.save_id = e.app.engine.mux.next_id;
        e.save_id = e.app.send_(@import("requests.zig").writeWorkspaceFile(.{
            .chatId = e.target.chatId,
            .spaceId = e.target.spaceId,
            .checkoutPath = e.target.checkoutPath,
            .targetDeviceId = e.target.targetDeviceId,
            .path = e.path,
            .text = text,
            .expectedCheckoutId = e.checkout,
            .expectedContentHash = e.hash,
            .encoding = e.encoding,
            .lineEnding = e.ending,
        }), .of(Editor, e, onSave));
        e.app.redraw();
        return true;
    }
    fn onSave(e: *Editor, id: u64, reply: rpc.Reply) void {
        if (id != 0 and e.save_id != id) return;
        const pending = e.pending orelse return;
        e.pending = null;
        e.save_id = null;
        defer e.app.gpa.free(pending.text);
        var written = false;
        switch (reply) {
            .ok => |value| {
                if (std.mem.eql(u8, str(value, "status") orelse "", "written")) {
                    const file = if (value == .object) value.object.get("file") else null;
                    if (file) |f| {
                        const path = str(f, "path") orelse "";
                        const hash = str(f, "contentHash") orelse "";
                        if (std.mem.eql(u8, path, e.path) and hash.len > 0) {
                            const baseline = e.app.gpa.dupe(u8, pending.text) catch return;
                            const owned_hash = e.app.gpa.dupe(u8, hash) catch {
                                e.app.gpa.free(baseline);
                                return;
                            };
                            e.app.gpa.free(e.baseline);
                            e.baseline = baseline;
                            e.app.gpa.free(e.hash);
                            e.hash = owned_hash;
                            e.saved_revision = pending.revision;
                            written = true;
                        }
                    }
                    if (!written) e.errorMessage("Invalid save acknowledgement; unsaved text retained");
                } else if (std.mem.eql(u8, str(value, "status") orelse "", "conflict")) {
                    e.conflict = true;
                    e.errorMessage("File changed on disk. Edits retained; reload only after explicitly discarding them.");
                } else e.errorMessage("Save was not acknowledged; unsaved text retained");
            },
            .err => |why| e.errorMessage(why),
            else => e.errorMessage("Save was not acknowledged; unsaved text retained"),
        }
        // baseline is the acknowledged snapshot, never whatever is typed now.
        // A later edit or failed/conflicting write must continue to block exit.
        if (written) continueExit(e.app);
        e.app.redraw();
    }
    pub fn discard(e: *Editor) void {
        if (e.pending != null) return;
        e.buffer.set(e.baseline);
        e.revision +%= 1;
        e.saved_revision = e.revision;
        e.errorMessage(null);
    }
};

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const value = v.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
fn same(a: ?[]const u8, b: ?[]const u8) bool {
    return if (a) |x| if (b) |y| std.mem.eql(u8, x, y) else false else b == null;
}
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 4096 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 256 or part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".") or std.ascii.eqlIgnoreCase(part, ".git") or std.mem.indexOfScalar(u8, part, ':') != null) return false;
    }
    return std.unicode.utf8ValidateSlice(path);
}
fn validText(text: []const u8, encoding: []const u8, ending: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null or std.mem.indexOfScalar(u8, text, '\r') != null) return false;
    const extra = if (std.mem.eql(u8, ending, "crlf")) std.mem.count(u8, text, "\n") else 0;
    const bom: usize = if (std.mem.eql(u8, encoding, "utf8Bom")) 3 else 0;
    return text.len <= limit and extra + bom <= limit - text.len;
}

pub const Intent = enum { tab, window, quit, reload };
pub const Completion = struct { ctx: *anyopaque, func: *const fn (*anyopaque) void };
pub const CloseState = struct {
    intent: ?Intent = null,
    target: ?*Editor = null,
    completion: ?Completion = null,
};
pub fn cancelExit(a: *App) void {
    if (a.panels.file_close.intent != null) {
        if (blocking(a)) |e| e.focus = true;
    }
    a.panels.file_close = .{};
    a.redraw();
}
fn blocking(a: *App) ?*Editor {
    const close = a.panels.file_close;
    if (close.intent == .tab or close.intent == .reload) {
        if (close.target) |e| if (e.dirty()) return e;
        return null;
    }
    for (a.panels.tabs.items) |tab| if (tab.editor) |e| if (e.dirty()) return e;
    return null;
}
pub fn reveal(a: *App, e: *Editor) void {
    const was = a.view.in_pre_tree;
    a.view.in_pre_tree = true;
    defer a.view.in_pre_tree = was;
    a.view.palette.open = false;
    a.picker = .none;
    a.view.strip.menu = null;
    a.view.write_open = false;
    if (e.target.chatId) |chat| {
        a.openChatInTab(chat);
    } else {
        // Blank editors return to their actual canvas while it exists.
        // If that canvas was explicitly closed, recover a blank owner rather
        // than replacing an unrelated conversation or unsent draft.
        var found = false;
        for (a.tabs.identities.items, 0..) |identity, ix| {
            if (identity.workspace == e.origin.workspace) {
                a.showTab(ix);
                if (a.tabs.layout()) |layout| {
                    for (layout.identities[0..layout.panes.items.len], 0..) |pane, pane_ix| if (pane == e.origin.pane) {
                        a.focusPane(pane_ix);
                        found = true;
                        break;
                    };
                } else found = identity.pane == e.origin.pane;
                break;
            }
        }
        if (!found) {
            a.newTab();
            a.select(null, e.target.spaceId);
            e.origin = a.tabs.identities.items[a.tabs.active];
        }
    }
    for (a.panels.tabs.items, 0..) |tab, ix| if (tab.editor == e) {
        a.panels.active = ix;
        a.panels.host_open = true;
        a.view.strip.focused = .host;
        a.view.strip.expanded = null;
        e.preview = false;
        e.focus = true;
        break;
    };
}
pub fn requestExit(a: *App, intent: Intent, completion: Completion) bool {
    if (a.panels.file_close.intent != null) return false;
    a.panels.file_close = .{ .intent = intent, .completion = completion };
    if (blocking(a)) |e| {
        reveal(a, e);
        a.redraw();
        return false;
    }
    a.panels.file_close = .{};
    return true;
}
pub fn requestTabClose(a: *App, e: *Editor) bool {
    if (!e.dirty()) return true;
    if (a.panels.file_close.intent == null) a.panels.file_close = .{ .intent = .tab, .target = e };
    reveal(a, e);
    a.redraw();
    return false;
}
pub fn requestReload(a: *App, e: *Editor) void {
    if (e.pending != null) return;
    if (e.dirty()) {
        if (a.panels.file_close.intent == null) a.panels.file_close = .{ .intent = .reload, .target = e };
        reveal(a, e);
    } else {
        e.read();
    }
    a.redraw();
}
pub const Decision = enum { cancel, discard, save };
pub fn decide(a: *App, decision: Decision) void {
    const e = blocking(a) orelse return continueExit(a);
    switch (decision) {
        .cancel => cancelExit(a),
        .discard => {
            if (e.pending != null) return;
            e.discard();
            continueExit(a);
        },
        .save => {
            _ = e.save();
        },
    }
    a.redraw();
}
fn continueExit(a: *App) void {
    const state = a.panels.file_close;
    const intent = state.intent orelse return;
    if (blocking(a)) |e| {
        reveal(a, e);
        return;
    }
    a.panels.file_close = .{};
    if (intent == .tab) {
        for (a.panels.tabs.items, 0..) |tab, ix| if (tab.editor == state.target) {
            @import("app_panels.zig").closeTab(a, ix);
            break;
        };
    } else if (intent == .reload) {
        if (state.target) |e| e.read();
    } else if (state.completion) |completion| completion.func(completion.ctx);
}
pub fn saveFocused(a: *App) bool {
    if (!a.panels.host_open or a.view.settings_open or a.view.write_open) return false;
    const tab = a.panels.activeTab() orelse return false;
    const e = tab.editor orelse return false;
    if (!e.focused and @import("view_tab_strip.zig").active(a) != .host) return false;
    _ = e.save();
    return true;
}
pub fn keys(c: *ui.Context, a: *App) bool {
    if (a.panels.file_close.intent != null) {
        if (c.shortcut(.{ .key = ui.Shortcut.escape }) or c.input.key == .escape) decide(a, .cancel);
        // Returning from global dispatch alone does not stop composer/field
        // render handlers. The modal must release their entire input lease.
        if (c.input.shortcut) |shortcut| _ = c.shortcut(shortcut);
        c.input.shortcut = null;
        c.input.key = null;
        c.input.chars = "";
        c.input.ops = &.{};
        c.focus = 0;
        return true;
    }
    if (a.panels.activeTab()) |tab| if (tab.editor) |e| {
        if (e.field != 0 and c.focus == e.field and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) return true;
    };
    return false;
}
pub fn dialog(c: *ui.Context, a: *App, k: @import("theme.zig").Colors) void {
    if (a.panels.file_close.intent == null) return;
    const e = blocking(a) orelse return;
    const scrim = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(12).bg(.{ .a = 0.35 }).center();
    defer scrim.end();
    const card = ui.div(c).column().w(@min(460, c.size.w - 32)).p(20).gap(12).rounded(12).bg(k.overlay).border(k.border).borderW(1);
    defer card.end();
    _ = card.interaction();
    ui.text(c, "Save changes before closing?", .{ .size = 16, .weight = .semibold, .color = k.text });
    ui.text(c, e.path, .{ .size = 13, .color = k.muted, .wrap = true });
    if (e.error_text) |message| ui.text(c, message, .{ .size = 12, .color = k.danger, .wrap = true });
    if (e.pending != null) ui.text(c, "Saving… waiting for confirmation", .{ .size = 12, .color = k.muted });
    const actions = ui.div(c).row().wFull().justifyEnd().gap(8);
    defer actions.end();
    for ([_]struct { label: []const u8, decision: Decision }{ .{ .label = "Cancel", .decision = .cancel }, .{ .label = "Discard changes", .decision = .discard }, .{ .label = "Save changes", .decision = .save } }) |action| {
        const enabled = action.decision == .cancel or (e.pending == null and (action.decision != .save or !e.conflict));
        var button = ui.div(c).row().px(10).py(7).rounded(7);
        if (enabled) button = button.hover(k.selected).control() else button = button.opacity(0.4);
        defer button.end();
        ui.text(c, action.label, .{ .size = 13, .color = k.text });
        if (enabled and button.clicked()) decide(a, action.decision);
    }
}
