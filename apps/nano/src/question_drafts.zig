//! Question state belongs to a (chat, request), including while its RPC is
//! outstanding. Entries have stable addresses so a late reply cannot mutate
//! the wizard of whatever chat happens to be selected by then.
const std = @import("std");
const App = @import("app.zig").App;
const Wizard = @import("wizard.zig").Wizard;

pub const Entry = struct {
    app: *App,
    chat: []u8,
    request: []u8,
    wizard: ?Wizard = null,
    phase: enum { draft, in_flight, answered } = .draft,
    call: ?u64 = null,
    deadline: ?f64 = null,
    settle_s: f64 = 2,
    attachment_paths: std.ArrayList([]u8) = .empty,

    pub fn clearAttachments(e: *Entry) void {
        for (e.attachment_paths.items) |path| e.app.gpa.free(path);
        e.attachment_paths.deinit(e.app.gpa);
        e.attachment_paths = .empty;
    }

    pub fn retireWizard(e: *Entry) void {
        if (e.wizard) |*w| w.retire(e.app);
        e.wizard = null;
    }
};

pub const State = struct {
    entries: std.ArrayList(*Entry) = .empty,

    pub fn find(s: *const State, chat: []const u8, request: []const u8) ?*Entry {
        for (s.entries.items) |e| {
            if (std.mem.eql(u8, e.chat, chat) and std.mem.eql(u8, e.request, request)) return e;
        }
        return null;
    }

    pub fn ensure(s: *State, a: *App, chat: []const u8, request: []const u8) !*Entry {
        if (s.find(chat, request)) |e| return e;
        const e = try a.gpa.create(Entry);
        errdefer a.gpa.destroy(e);
        const owned_chat = try a.gpa.dupe(u8, chat);
        errdefer a.gpa.free(owned_chat);
        const owned_request = try a.gpa.dupe(u8, request);
        errdefer a.gpa.free(owned_request);
        e.* = .{ .app = a, .chat = owned_chat, .request = owned_request };
        try s.entries.append(a.gpa, e);
        return e;
    }

    /// Resolution or a newer request retires the old draft and cancels its
    /// callback before freeing its stable context. Missing replay data alone
    /// is not authoritative evidence of resolution.
    pub fn reconcile(s: *State, a: *App) void {
        const chat = a.selected orelse return;
        const latest = @import("app_question.zig").latestInput(a);
        var i: usize = 0;
        while (i < s.entries.items.len) {
            const e = s.entries.items[i];
            const obsolete = if (std.mem.eql(u8, chat, e.chat) and latest != null)
                latest.?.resolved or !std.mem.eql(u8, latest.?.request_id, e.request)
            else
                false;
            if (!obsolete) {
                i += 1;
                continue;
            }
            if (e.call) |id| a.engine.cancel(id);
            e.retireWizard();
            e.clearAttachments();
            a.gpa.free(e.chat);
            a.gpa.free(e.request);
            a.gpa.destroy(e);
            _ = s.entries.orderedRemove(i);
        }
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        for (s.entries.items) |e| {
            if (e.wizard) |*w| w.deinit();
            e.clearAttachments();
            gpa.free(e.chat);
            gpa.free(e.request);
            gpa.destroy(e);
        }
        s.entries.deinit(gpa);
        s.* = .{};
    }
};
