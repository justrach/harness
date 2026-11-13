//! Catalog-backed completion provenance. Plain / and $ text is never promoted
//! by matching a catalog. Only acceptance mints existing harness-invoke links.
const std = @import("std");
const ui = @import("nanoui").ui;
const rpc = @import("rpc.zig");
const requests = @import("requests.zig");
const rules = @import("completion_rules.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

pub const Action = enum { model, new, resume_chat, settings, diff, files, terminal, rename, stop, help };
pub const SkillCommand = struct { name: []const u8, harness: []const u8 };
pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    path: ?[]const u8 = null,
    command: ?SkillCommand = null,
    action: ?Action = null,
    pub fn prefix(e: Entry) u8 {
        return if (e.path != null) '$' else '/';
    }
};
const Selection = struct { start: usize, end: usize, display: []u8, link: []u8 };
const LongEdit = struct {
    before: []u8,
    after: []u8,
    scope: []u8,
    before_caret: usize,
    after_caret: usize,
    before_refs: ?[]u8,
    after_refs: ?[]u8 = null,
    at_after: bool = true,
    fn deinit(x: *LongEdit, gpa: Allocator) void {
        gpa.free(x.before);
        gpa.free(x.after);
        gpa.free(x.scope);
        if (x.before_refs) |v| gpa.free(v);
        if (x.after_refs) |v| gpa.free(v);
    }
};

pub const State = struct {
    scope: ?[]u8 = null,
    arena: ?std.heap.ArenaAllocator = null,
    commands: std.ArrayList(Entry) = .empty,
    skills: std.ArrayList(Entry) = .empty,
    commands_request: ?u64 = null,
    skills_request: ?u64 = null,
    commands_done: bool = false,
    skills_done: bool = false,
    failed: bool = false,
    remote: bool = false,
    active: usize = 0,
    query: std.ArrayList(u8) = .empty,
    snapshot: std.ArrayList(u8) = .empty,
    selected: std.ArrayList(Selection) = .empty,
    dismissed: bool = false,
    token_start: ?usize = null,
    menu_id: u64 = 0,
    parked: std.StringHashMapUnmanaged([]u8) = .empty,
    undo_refs: std.ArrayList([]u8) = .empty,
    long_edit: ?LongEdit = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.clearSelections(gpa);
        s.selected.deinit(gpa);
        s.snapshot.deinit(gpa);
        s.query.deinit(gpa);
        s.commands.deinit(gpa);
        s.skills.deinit(gpa);
        var parked = s.parked.iterator();
        while (parked.next()) |p| {
            gpa.free(p.key_ptr.*);
            gpa.free(p.value_ptr.*);
        }
        s.parked.deinit(gpa);
        for (s.undo_refs.items) |v| gpa.free(v);
        s.undo_refs.deinit(gpa);
        if (s.long_edit) |*x| x.deinit(gpa);
        if (s.arena) |*ar| ar.deinit();
        if (s.scope) |v| gpa.free(v);
        s.* = .{};
    }
    fn clearSelections(s: *State, gpa: Allocator) void {
        for (s.selected.items) |sel| {
            gpa.free(sel.display);
            gpa.free(sel.link);
        }
        s.selected.clearRetainingCapacity();
    }
    fn drop(s: *State, gpa: Allocator, ix: usize) void {
        const sel = s.selected.orderedRemove(ix);
        gpa.free(sel.display);
        gpa.free(sel.link);
    }
    /// Minimal changed span: edits wholly before a reference move it; any
    /// overlap or appended name suffix invalidates it rather than retargeting.
    pub fn sync(s: *State, gpa: Allocator, text: []const u8) !void {
        const old = s.snapshot.items;
        if (std.mem.eql(u8, old, text)) return;
        var lo: usize = 0;
        while (lo < old.len and lo < text.len and old[lo] == text[lo]) lo += 1;
        var old_end = old.len;
        var new_end = text.len;
        while (old_end > lo and new_end > lo and old[old_end - 1] == text[new_end - 1]) {
            old_end -= 1;
            new_end -= 1;
        }
        var ix: usize = 0;
        while (ix < s.selected.items.len) {
            const sel = &s.selected.items[ix];
            if (old_end <= sel.start) {
                sel.start = sel.start - (old_end - lo) + (new_end - lo);
                sel.end = sel.end - (old_end - lo) + (new_end - lo);
            } else if (lo < sel.end or (lo == sel.end and new_end > lo and text[lo] != ' ' and text[lo] != '\n' and text[lo] != '\t' and text[lo] != ')')) {
                s.drop(gpa, ix);
                continue;
            }
            if (sel.end > text.len or !std.mem.eql(u8, sel.display, text[sel.start..sel.end]) or (sel.end < text.len and (std.ascii.isAlphanumeric(text[sel.end]) or text[sel.end] == '-' or text[sel.end] == '_' or text[sel.end] == ':' or text[sel.end] >= 0x80))) {
                s.drop(gpa, ix);
                continue;
            }
            ix += 1;
        }
        try s.snapshot.replaceRange(gpa, 0, old.len, text);
        s.dismissed = false;
    }
};

fn scopeKey(a: *const App, gpa: Allocator) ![]u8 {
    const host = if (a.selected) |id| (if (a.findChat(id)) |ch| ch.device_id else null) else a.draftDevice();
    const space = if (a.selected == null) @import("app_agent.zig").newChatSpace(a) else null;
    return std.fmt.allocPrint(gpa, "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{s}", .{ host orelse "", a.target().harness, a.selected orelse "", if (space) |sp| sp.id else "", if (space) |sp| sp.path else "" });
}

fn ensure(a: *App) void {
    const s = &a.completion;
    const key = scopeKey(a, a.gpa) catch return;
    const same = if (s.scope) |old| std.mem.eql(u8, old, key) else false;
    if (same) {
        a.gpa.free(key);
    } else {
        if (s.commands_request) |id| a.engine.cancel(id);
        if (s.skills_request) |id| a.engine.cancel(id);
        if (s.scope) |old| a.gpa.free(old);
        s.scope = key;
        s.clearSelections(a.gpa);
        s.commands.clearRetainingCapacity();
        s.skills.clearRetainingCapacity();
        if (s.arena) |*ar| ar.deinit();
        s.arena = .init(a.gpa);
        s.commands_done = false;
        s.skills_done = false;
        s.failed = false;
        s.commands_request = null;
        s.skills_request = null;
    }
    const host = if (a.selected) |id| (if (a.findChat(id)) |ch| ch.device_id else null) else a.draftDevice();
    s.remote = if (host) |h| (if (a.device_id) |local| !std.mem.eql(u8, h, local) else true) else false;
    if (s.remote or !a.engine.up()) return;
    const space = if (a.selected == null) @import("app_agent.zig").newChatSpace(a) else null;
    const scope: requests.CatalogScope = .{ .harness = a.target().harness, .chatId = a.selected, .spaceId = if (space) |sp| sp.id else null, .path = if (space) |sp| sp.path else null };
    if (!s.commands_done and s.commands_request == null) s.commands_request = a.send_(requests.listCommands(scope), .of(App, a, commandsReply));
    if (!s.skills_done and s.skills_request == null) s.skills_request = a.send_(requests.listSkills(scope), .of(App, a, skillsReply));
}

fn string(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 512 or !std.unicode.utf8ValidateSlice(name)) return false;
    var it = std.unicode.Utf8View.initUnchecked(name).iterator();
    while (it.nextCodepoint()) |cp| if (cp <= 32 or (cp >= 0x7F and cp <= 0x9F) or cp == 0xA0 or cp == 0x1680 or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000 or (cp >= 0x2000 and cp <= 0x200A)) return false;
    return true;
}
fn copy(gpa: Allocator, text: []const u8) ![]const u8 {
    return gpa.dupe(u8, text);
}
fn receive(a: *App, id: u64, reply: rpc.Reply, skill: bool) void {
    const s = &a.completion;
    const wanted = if (skill) s.skills_request else s.commands_request;
    if (wanted == null or wanted.? != id) return;
    if (skill) {
        s.skills_request = null;
        s.skills_done = true;
    } else {
        s.commands_request = null;
        s.commands_done = true;
    }
    if (reply != .ok or reply.ok != .array) {
        s.failed = true;
        return a.redraw();
    }
    const gpa = s.arena.?.allocator();
    const list = if (skill) &s.skills else &s.commands;
    for (reply.ok.array.items) |v| {
        const name = string(v, "name") orelse continue;
        if (!validName(name)) continue;
        const description = string(v, "description") orelse "";
        var entry: Entry = .{ .name = copy(gpa, name) catch continue, .description = copy(gpa, description) catch continue };
        if (skill) {
            const enabled = v.object.get("enabled") orelse continue;
            if (enabled != .bool or !enabled.bool) continue;
            const path = string(v, "path") orelse continue;
            if (path.len == 0 or !std.unicode.utf8ValidateSlice(path)) continue;
            var path_chars = std.unicode.Utf8View.initUnchecked(path).iterator();
            const valid_path = while (path_chars.nextCodepoint()) |cp| {
                if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) break false;
            } else true;
            if (!valid_path) continue;
            entry.path = copy(gpa, path) catch continue;
            if (v.object.get("command")) |command| if (command != .null) {
                const cn = string(command, "name") orelse continue;
                const harness = string(command, "harness") orelse continue;
                if (!validName(cn) or !std.mem.eql(u8, harness, a.target().harness)) continue;
                var chars = std.unicode.Utf8View.initUnchecked(cn).iterator();
                const valid_command = while (chars.nextCodepoint()) |cp| {
                    if (!@import("completion_unicode.zig").alnum(cp) and cp != '-' and cp != '_' and cp != ':' and cp != '.') break false;
                } else true;
                if (!valid_command) continue;
                entry.command = .{ .name = copy(gpa, cn) catch continue, .harness = copy(gpa, harness) catch continue };
            };
        }
        list.append(a.gpa, entry) catch break;
    }
    a.redraw();
}
fn commandsReply(a: *App, id: u64, r: rpc.Reply) void {
    receive(a, id, r, false);
}
fn skillsReply(a: *App, id: u64, r: rpc.Reply) void {
    receive(a, id, r, true);
}

pub fn refresh(a: *App, caret: usize) ?rules.Token {
    const s = &a.completion;
    s.sync(a.gpa, a.composer.text()) catch return null;
    const tok = rules.token(a.composer.text(), caret) orelse {
        s.token_start = null;
        s.dismissed = false;
        return null;
    };
    ensure(a);
    if (s.token_start == null or s.token_start.? != tok.range.start or !std.mem.eql(u8, s.query.items, tok.query)) {
        s.query.replaceRange(a.gpa, 0, s.query.items.len, tok.query) catch return null;
        s.active = 0;
        s.dismissed = false;
    }
    s.token_start = tok.range.start;
    if (s.dismissed) return null;
    return tok;
}

const Native = struct { action: Action, name: []const u8, description: []const u8, chat: bool = false };
const native = [_]Native{
    .{ .action = .model, .name = "model", .description = "Choose agent, model and reasoning" },
    .{ .action = .new, .name = "new", .description = "Start a new session" },
    .{ .action = .resume_chat, .name = "resume", .description = "Resume a Harness session" },
    .{ .action = .settings, .name = "settings", .description = "Open Harness settings" },
    .{ .action = .help, .name = "help", .description = "Show keyboard shortcuts" },
    .{ .action = .diff, .name = "diff", .description = "Open changes", .chat = true },
    .{ .action = .files, .name = "files", .description = "Open files", .chat = true },
    .{ .action = .terminal, .name = "terminal", .description = "Open terminal", .chat = true },
    .{ .action = .rename, .name = "rename", .description = "Rename this session", .chat = true },
    .{ .action = .stop, .name = "stop", .description = "Stop the current run", .chat = true },
};

pub fn entries(a: *App, gpa: Allocator, tok: rules.Token) ![]Entry {
    var all: std.ArrayList(Entry) = .empty;
    if (tok.prefix == '/') for (a.completion.commands.items) |command| {
        const skill_command = for (a.completion.skills.items) |skill| {
            if (skill.command) |native_command| if (std.mem.eql(u8, native_command.name, command.name)) break true;
        } else false;
        if (!skill_command) try all.append(gpa, command);
    };
    try all.appendSlice(gpa, a.completion.skills.items);
    if (tok.prefix == '/') for (native) |n| {
        if (n.chat and a.selected == null) continue;
        // Until provider discovery completes, use an explicitly local namespace
        // rather than temporarily stealing a provider's unqualified command.
        var name = if (a.completion.commands_done) n.name else try std.fmt.allocPrint(gpa, "harness:{s}", .{n.name});
        while (for (all.items) |e| {
            if (std.mem.eql(u8, e.name, name)) break true;
        } else false) name = try std.fmt.allocPrint(gpa, "harness:{s}", .{name});
        try all.append(gpa, .{ .name = name, .description = n.description, .action = n.action });
    };
    var out: std.ArrayList(Entry) = .empty;
    for (all.items) |e| if (rules.matchRank(tok.query, e.name) != null) try out.append(gpa, e);
    // Stable: native commands retain their provider catalog order for equal rank.
    std.sort.insertion(Entry, out.items, tok.query, struct {
        fn less(query: []const u8, x: Entry, y: Entry) bool {
            return rules.matchRank(query, x.name).? < rules.matchRank(query, y.name).?;
        }
    }.less);
    return out.toOwnedSlice(gpa);
}

pub fn canonical(gpa: Allocator, entry: Entry) ![]u8 {
    const payload = if (entry.path) |path|
        try std.json.Stringify.valueAlloc(gpa, .{ .kind = "skill", .name = entry.name, .path = path, .command = entry.command }, .{ .emit_null_optional_fields = false })
    else
        try std.json.Stringify.valueAlloc(gpa, .{ .kind = "command", .name = entry.name }, .{});
    defer gpa.free(payload);
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(gpa);
    for (entry.name) |b| {
        if (b == '\\' or b == '[' or b == ']' or b == '`') try label.append(gpa, '\\');
        try label.append(gpa, b);
    }
    // Runtime payload size: encode explicitly.
    const encoded = try gpa.alloc(u8, payload.len * 2);
    defer gpa.free(encoded);
    const digits = "0123456789abcdef";
    for (payload, 0..) |b, i| {
        encoded[i * 2] = digits[b >> 4];
        encoded[i * 2 + 1] = digits[b & 15];
    }
    return std.fmt.allocPrint(gpa, "[{c}{s}](harness-invoke:{s})", .{ entry.prefix(), label.items, encoded });
}

/// One edit and one undo state, independent of the reference's wire encoding.
pub fn accept(a: *App, c: *ui.Context, tok: rules.Token, entry: Entry) void {
    const s = &a.completion;
    const text = a.composer.text();
    var range = rules.replacementRange(text, tok, entry.name);
    const action = entry.action;
    if (action != null and range.end < text.len and text[range.end] == ' ') range.end += 1;
    const insertion = if (action != null) a.gpa.dupe(u8, "") catch return else std.fmt.allocPrint(a.gpa, "{c}{s}{s}", .{ entry.prefix(), entry.name, if (range.end == text.len or (text[range.end] != ' ' and text[range.end] != '\n' and text[range.end] != '\t')) " " else "" }) catch return;
    defer a.gpa.free(insertion);
    const display = if (action == null) a.gpa.dupe(u8, insertion[0 .. entry.name.len + 1]) catch return else null;
    const link = if (action == null) canonical(a.gpa, entry) catch {
        a.gpa.free(display.?);
        return;
    } else null;
    var keep = false;
    defer if (!keep) {
        if (display) |v| a.gpa.free(v);
        if (link) |v| a.gpa.free(v);
    };
    // The pinned toolkit intentionally omits >1KiB snapshots. Preserve this
    // formerly shipped one-step completion transaction without changing its
    // general editor history or copying/truncating a long draft.
    var long_edit: ?LongEdit = null;
    if (text.len > 1024 or text.len - (range.end - range.start) + insertion.len > 1024) {
        const before = a.gpa.dupe(u8, text) catch return;
        const after = std.fmt.allocPrint(a.gpa, "{s}{s}{s}", .{ text[0..range.start], insertion, text[range.end..] }) catch {
            a.gpa.free(before);
            return;
        };
        const scope = scopeKey(a, a.gpa) catch {
            a.gpa.free(before);
            a.gpa.free(after);
            return;
        };
        const refs = capture(a, text) catch {
            a.gpa.free(before);
            a.gpa.free(after);
            a.gpa.free(scope);
            return;
        };
        long_edit = .{ .before = before, .after = after, .scope = scope, .before_caret = tok.caret, .after_caret = range.start + insertion.len, .before_refs = refs };
    }
    defer if (long_edit) |*x| x.deinit(a.gpa);
    if (c.edits.getPtr(a.view.composer_id)) |e| e.undo.begin(text, tok.caret);
    if (a.composer.replace(range.start, range.end, insertion) != insertion.len) return;
    const caret = range.start + insertion.len;
    a.composer.want_caret = caret;
    if (c.edits.getPtr(a.view.composer_id)) |e| {
        e.caret = caret;
        e.anchor = caret;
        e.marked = null;
        e.undo.commit(a.composer.text(), caret, true, false);
    }
    s.sync(a.gpa, a.composer.text()) catch return;
    if (display != null) {
        s.selected.append(a.gpa, .{ .start = range.start, .end = range.start + display.?.len, .display = display.?, .link = link.? }) catch return;
        std.sort.insertion(Selection, s.selected.items, {}, struct {
            fn less(_: void, x: Selection, y: Selection) bool {
                return x.start < y.start;
            }
        }.less);
        keep = true;
    }
    s.dismissed = true;
    if (capture(a, a.composer.text()) catch null) |blob| {
        if (s.undo_refs.items.len >= 12) a.gpa.free(s.undo_refs.orderedRemove(0));
        s.undo_refs.append(a.gpa, blob) catch a.gpa.free(blob);
    }
    if (long_edit) |*x| {
        x.after_refs = capture(a, a.composer.text()) catch null;
        if (s.long_edit) |*old| old.deinit(a.gpa);
        s.long_edit = x.*;
        long_edit = null;
    }
    c.selection.clear();
    c.changed = true;
    if (action) |act| activate(a, act);
    a.redraw();
}

fn activate(a: *App, action: Action) void {
    switch (action) {
        .model => a.togglePicker(),
        .new => a.newTab(),
        .resume_chat => @import("view_palette.zig").toggle(a, .replace_current),
        .settings => @import("view_settings.zig").open(a),
        .help => {
            @import("view_settings.zig").open(a);
            a.settings.setSection(.shortcuts);
        },
        .diff => @import("app_panels.zig").addDiffsTab(a),
        .files => @import("app_files.zig").open(a),
        .terminal => @import("app_panels.zig").toggleHost(a),
        .stop => a.interrupt(),
        .rename => if (a.selected) |id| {
            var own: std.ArrayList(u8) = .empty;
            own.appendSlice(a.gpa, id) catch return;
            if (a.view.dialogs.rename) |*old| old.deinit(a.gpa);
            a.view.dialogs.rename = own;
            a.view.dialogs.space = false;
            a.view.dialogs.name.set(if (a.findChat(id)) |ch| ch.title orelse "" else "");
            a.view.dialogs.focus_name = true;
        },
    }
}

/// Root send/queue/steer hook. Null means untouched ordinary prompt text.
pub fn prompt(a: *App) !?[]u8 {
    const s = &a.completion;
    const key = try scopeKey(a, a.gpa);
    defer a.gpa.free(key);
    if (s.scope == null or !std.mem.eql(u8, key, s.scope.?)) return null;
    try s.sync(a.gpa, a.composer.text());
    if (s.selected.items.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a.gpa);
    var at: usize = 0;
    for (s.selected.items) |sel| {
        try out.appendSlice(a.gpa, a.composer.text()[at..sel.start]);
        try out.appendSlice(a.gpa, sel.link);
        at = sel.end;
    }
    try out.appendSlice(a.gpa, a.composer.text()[at..]);
    return try out.toOwnedSlice(a.gpa);
}

/// Internal draft sidecar. Never reconstructed from user-pasted display text.
const Saved = struct { scope: []const u8, text: []const u8, references: []Selection };

pub fn capture(a: *App, text: []const u8) !?[]u8 {
    const s = &a.completion;
    const key = try scopeKey(a, a.gpa);
    defer a.gpa.free(key);
    if (s.scope == null or !std.mem.eql(u8, s.scope.?, key)) return null;
    // A question/queue editor temporarily borrows the composer. Its displaced
    // draft is passed explicitly, and may still be our unchanged snapshot.
    if (std.mem.eql(u8, text, a.composer.text())) try s.sync(a.gpa, text);
    if (s.selected.items.len == 0 or !std.mem.eql(u8, s.snapshot.items, text)) return null;
    return try std.json.Stringify.valueAlloc(a.gpa, Saved{ .scope = key, .text = text, .references = s.selected.items }, .{});
}

pub fn restore(a: *App, blob: ?[]const u8) void {
    ensure(a);
    const s = &a.completion;
    s.clearSelections(a.gpa);
    s.snapshot.replaceRange(a.gpa, 0, s.snapshot.items.len, a.composer.text()) catch return;
    const bytes = blob orelse return;
    var parsed = std.json.parseFromSlice(Saved, a.gpa, bytes, .{}) catch return;
    defer parsed.deinit();
    const saved = parsed.value;
    if (!std.mem.eql(u8, saved.scope, s.scope.?) or !std.mem.eql(u8, saved.text, a.composer.text())) return;
    var end: usize = 0;
    for (saved.references) |ref| {
        if (ref.start < end or ref.end < ref.start or ref.end > saved.text.len or !std.mem.eql(u8, saved.text[ref.start..ref.end], ref.display)) {
            s.clearSelections(a.gpa);
            return;
        }
        const display = a.gpa.dupe(u8, ref.display) catch return;
        const link = a.gpa.dupe(u8, ref.link) catch {
            a.gpa.free(display);
            return;
        };
        s.selected.append(a.gpa, .{ .start = ref.start, .end = ref.end, .display = display, .link = link }) catch {
            a.gpa.free(display);
            a.gpa.free(link);
            return;
        };
        end = ref.end;
    }
}

/// app_drafts.leave hook: selected chat drafts and the shared canvas each
/// keep provenance alongside, never inside the visible text string.
pub fn park(a: *App, text: []const u8) void {
    const s = &a.completion;
    const key = a.selected orelse "";
    const blob = capture(a, text) catch return;
    if (s.parked.fetchRemove(key)) |old| {
        a.gpa.free(old.key);
        a.gpa.free(old.value);
    }
    if (blob) |value| {
        const owned = a.gpa.dupe(u8, key) catch {
            a.gpa.free(value);
            return;
        };
        s.parked.put(a.gpa, owned, value) catch {
            a.gpa.free(owned);
            a.gpa.free(value);
        };
    }
}

pub fn enter(a: *App) void {
    restore(a, a.completion.parked.get(a.selected orelse ""));
}

/// tabs.Draft carries this independently so two fresh canvases cannot steal
/// each other's completion identity even when their visible prompts match.
pub fn canvas(a: *App, text: []const u8) !?[]u8 {
    if (a.selected == null) return capture(a, text);
    const blob = a.completion.parked.get("") orelse return null;
    var parsed = try std.json.parseFromSlice(Saved, a.gpa, blob, .{});
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.text, text)) return null;
    return try a.gpa.dupe(u8, blob);
}

/// Adopt borrows a tabs.Draft sidecar; the draft still owns/frees its bytes.
pub fn adopt(a: *App, blob: ?[]const u8) void {
    const s = &a.completion;
    const value = if (blob) |b| a.gpa.dupe(u8, b) catch return else null;
    if (s.parked.fetchRemove("")) |old| {
        a.gpa.free(old.key);
        a.gpa.free(old.value);
    }
    if (value) |b| {
        const key = a.gpa.dupe(u8, "") catch {
            a.gpa.free(b);
            return;
        };
        s.parked.put(a.gpa, key, b) catch {
            a.gpa.free(key);
            a.gpa.free(b);
            return;
        };
    }
    if (a.selected == null) restore(a, value);
}

/// A new engine connection must rediscover, but must not erase draft intent.
pub fn reconnected(a: *App) void {
    const s = &a.completion;
    s.commands_request = null;
    s.skills_request = null;
    s.commands_done = false;
    s.skills_done = false;
    s.failed = false;
    s.commands.clearRetainingCapacity();
    s.skills.clearRetainingCapacity();
}

pub fn retry(a: *App) void {
    if (a.completion.commands_request) |id| a.engine.cancel(id);
    if (a.completion.skills_request) |id| a.engine.cancel(id);
    reconnected(a);
    ensure(a);
    a.redraw();
}

/// Only the immediate long completion transaction; ordinary editing keeps
/// the toolkit's own undo system. Matching plain text alone never restores it.
pub fn historyKey(a: *App, c: *ui.Context) bool {
    if (c.focus == 0 or c.focus != a.view.composer_id) return false;
    const key = c.input.shortcut orelse return false;
    if ((!key.cmd and !key.ctrl) or key.alt or (key.key != 'z' and key.key != 'y')) return false;
    const x = if (a.completion.long_edit) |*v| v else return false;
    const redo = key.shift or (key.ctrl and key.key == 'y');
    if (redo == x.at_after) return false;
    const scope = scopeKey(a, a.gpa) catch return false;
    defer a.gpa.free(scope);
    if (!std.mem.eql(u8, scope, x.scope) or !std.mem.eql(u8, a.composer.text(), if (redo) x.before else x.after)) return false;
    a.composer.set(if (redo) x.after else x.before);
    a.composer.want_caret = if (redo) x.after_caret else x.before_caret;
    x.at_after = redo;
    const refs = if (redo) x.after_refs else x.before_refs;
    restore(a, refs);
    c.input.shortcut = null;
    c.input.ops = &.{};
    c.input.key = null;
    c.changed = true;
    a.redraw();
    return true;
}

/// Same-text paste replacing a selected span drops its provenance too.
pub fn beforeEdit(a: *App, c: *ui.Context) void {
    const e = c.edits.get(a.view.composer_id) orelse return;
    var anchor = e.anchor;
    var caret = e.caret;
    for (c.input.ops) |op| {
        if (op == .select) {
            anchor = op.select.anchor;
            caret = op.select.caret;
            continue;
        }
        if (op != .insert and op != .set_marked) continue;
        if (a.completion.long_edit) |*x| {
            x.deinit(a.gpa);
            a.completion.long_edit = null;
        }
        const lo = @min(anchor, caret);
        const hi = @max(anchor, caret);
        if (lo == hi) continue;
        var ix: usize = 0;
        while (ix < a.completion.selected.items.len) {
            const ref = a.completion.selected.items[ix];
            if (lo < ref.end and hi > ref.start) a.completion.drop(a.gpa, ix) else ix += 1;
        }
    }
}

pub fn afterEdit(a: *App, c: *ui.Context, changed: bool) void {
    const e = c.edits.get(a.view.composer_id) orelse return;
    if (changed and e.undo.restored) {
        for (a.completion.undo_refs.items) |blob| {
            var parsed = std.json.parseFromSlice(Saved, a.gpa, blob, .{}) catch continue;
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.text, a.composer.text())) {
                restore(a, blob);
                return;
            }
        }
    }
    a.completion.sync(a.gpa, a.composer.text()) catch {};
}

test {
    _ = @import("completion_rules.zig");
}
