//! A pending question borrows the composer. Answers, picks and page position
//! belong to the (chat, request), not the globally selected chat or its frame.
const std = @import("std");
const tr = @import("transcript.zig");
const requests = @import("requests.zig");
const rpc = @import("rpc.zig");
const Wizard = @import("wizard.zig").Wizard;
const Entry = @import("question_drafts.zig").Entry;
const App = @import("app.zig").App;

/// Later assistant status messages do not resolve an earlier input. Only a
/// successful acknowledgement or a resolved transcript part does that.
pub fn latestInput(a: *const App) ?*const tr.Part {
    return latestIn(&a.transcript);
}

fn latestIn(transcript: *const tr.Transcript) ?*const tr.Part {
    const entries = transcript.entries.items;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = &entries[i];
        if (e.role != .assistant) continue;
        var j = e.parts.items.len;
        while (j > 0) {
            j -= 1;
            const p = &e.parts.items[j];
            if (p.kind == .input and p.questions.len > 0) return p;
        }
    }
    return null;
}

pub fn pendingInput(a: *const App) ?*const tr.Part {
    const chat = a.selected orelse return null;
    const p = latestInput(a) orelse return null;
    // A newer question supersedes older ones, even once it resolves.
    if (p.resolved) return null;
    if (a.question_drafts.find(chat, p.request_id)) |saved| if (saved.phase != .draft) return null;
    return p;
}

/// Selection identifies the transcript, not keyboard ownership: a host or
/// files pane can be active while the selected chat remains on screen.
pub fn ownsActivePane(a: *const App) bool {
    if (a.selected == null or a.view.settings_open or a.view.write_open or a.bots.page != .none) return false;
    const pane = if (a.tabs.layout()) |s| s.focus else 0;
    const owner: @import("view_tab_strip.zig").Panel = .{ .chat = pane };
    if (!@import("view_tab_strip.zig").same(a.view.strip.focused, owner)) return false;
    if (a.view.strip.expanded) |expanded| if (!@import("view_tab_strip.zig").same(expanded, owner)) return false;
    return true;
}

/// Durable attention for rows (and panel tabs), even after session status
/// freshness expires. Never select the chat just to discover its question.
pub fn needsInput(a: *const App, chat: []const u8) bool {
    if (a.selected) |id| if (std.mem.eql(u8, id, chat)) return pendingInput(a) != null;
    for (a.peers.items) |*peer| {
        if (!std.mem.eql(u8, peer.id, chat)) continue;
        if (latestIn(&peer.transcript)) |p| {
            if (p.resolved) return false;
            if (a.question_drafts.find(chat, p.request_id)) |saved| return saved.phase == .draft;
            return true;
        }
        break;
    }
    for (a.question_drafts.entries.items) |saved| {
        if (std.mem.eql(u8, saved.chat, chat) and saved.phase == .draft and saved.wizard != null) return true;
    }
    return false;
}

/// Opens or closes the wizard as questions come and go; each frame. Queue
/// editing has exclusive ownership of the composer until its lease finishes.
pub fn syncWizard(a: *App) void {
    freeRetired(a);
    a.question_drafts.reconcile(a);
    if (a.queue_edit != null) return;
    const pending = pendingInput(a);
    if (a.wizard) |*w| {
        if (pending != null and std.mem.eql(u8, pending.?.request_id, w.request_id)) {
            // Retain the exact answer, page, picks and attachments while
            // another surface owns input, but never advance it offscreen.
            if (!ownsActivePane(a)) w.advance_at = null;
            return;
        }
        closeWizard(a);
    }
    if (!ownsActivePane(a)) return;
    const p = pending orelse return;
    const chat = a.selected orelse return;
    const saved = a.question_drafts.find(chat, p.request_id);
    const w = if (saved != null and saved.?.wizard != null) blk: {
        const w = saved.?.wizard.?;
        saved.?.wizard = null;
        break :blk w;
    } else Wizard.init(a.gpa, p.request_id, p.questions) catch return;
    a.draft_stash.clearRetainingCapacity();
    a.draft_stash.appendSlice(a.gpa, a.prompt_nav.draftOf(a.composer.text())) catch {};
    a.prompt_nav.retire(a);
    a.composer.set(w.typed[w.page].items);
    a.wizard = w;
    if (saved) |entry| if (entry.attachment_paths.items.len > 0) {
        @import("app_attachments.zig").restore(a, a.composer.text(), entry.attachment_paths.items) catch {
            a.setNotice("Couldn't restore the answer attachments; your answer is still available");
            return;
        };
        entry.clearAttachments();
    };
}

/// Close after resolution; question strings can still be borrowed by the
/// current UI frame and are retired on the next tick.
fn closeWizard(a: *App) void {
    freeRetired(a);
    a.retired_wizard = a.wizard;
    a.wizard = null;
    restorePrompt(a);
}

fn restorePrompt(a: *App) void {
    a.composer.set(a.draft_stash.items);
    a.draft_stash.clearRetainingCapacity();
}

/// Hand the composer to navigation or a queue editor without retiring the
/// unfinished answer. Disarm auto-advance while the question is offscreen.
pub fn suspendQuestion(a: *App) void {
    const w = if (a.wizard) |*w| w else return;
    const chat = a.selected orelse return;
    const saved = a.question_drafts.ensure(a, chat, w.request_id) catch return;
    saveTyped(a, w);
    w.advance_at = null;
    saved.retireWizard();
    saved.wizard = a.wizard;
    a.wizard = null;
    restorePrompt(a);
}

fn saveTyped(a: *App, w: *Wizard) void {
    w.typed[w.page].clearRetainingCapacity();
    w.typed[w.page].appendSlice(a.gpa, a.composer.text()) catch {};
}

fn turnPage(a: *App, w: *Wizard, to: usize) void {
    saveTyped(a, w);
    w.page = to;
    w.advance_at = null;
    a.composer.set(w.typed[to].items);
    a.redraw();
}

pub fn pick(a: *App, option: usize) void {
    if (a.wizard) |*w| w.pick(option, a.now);
    a.redraw();
}

pub fn advance(a: *App) void {
    const w = if (a.wizard) |*w| w else return;
    saveTyped(a, w);
    if (!w.canAdvance()) return;
    if (w.last()) return submit(a);
    turnPage(a, w, w.page + 1);
}

pub fn back(a: *App) void {
    const w = if (a.wizard) |*w| w else return;
    if (w.page == 0) return;
    turnPage(a, w, w.page - 1);
}

pub fn tick(a: *App, now: f64) ?f64 {
    var next: ?f64 = null;
    for (a.question_drafts.entries.items) |saved| {
        const deadline = saved.deadline orelse continue;
        if (now < deadline) {
            next = if (next) |old| @min(old, deadline) else deadline;
            continue;
        }
        // A lost command reply and an accepted-but-unresolved command are
        // both retryable. Cancel the old handler before reusing its entry.
        if (saved.call) |id| a.engine.cancel(id);
        saved.call = null;
        saved.deadline = null;
        saved.phase = .draft;
        if (a.selected) |chat| if (std.mem.eql(u8, chat, saved.chat)) {
            a.setNotice("The question has not resolved; your answer is still available to retry");
        };
        a.redraw();
    }
    syncWizard(a);
    const w = if (a.wizard) |*w| w else return next;
    if (!ownsActivePane(a)) return next;
    const at = w.advance_at orelse return next;
    if (now < at) return if (next) |old| @min(old, at) else at;
    w.advance_at = null;
    advance(a);
    return next;
}

fn submit(a: *App) void {
    const chat = a.selected orelse return;
    const w = if (a.wizard) |*w| w else return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const answers = w.answers(arena.allocator()) catch return;
    const attachments = @import("app_attachments.zig");
    const trailer = attachments.prompt(a, "") catch {
        a.setNotice("Wait for the answer attachments to finish uploading before submitting");
        return;
    };
    defer if (trailer) |text| a.gpa.free(text);
    if (trailer) |text| if (answers.len > 0) {
        const last = &answers[answers.len - 1];
        const labels = arena.allocator().alloc([]const u8, last.labels.len + 1) catch return;
        @memcpy(labels[0..last.labels.len], last.labels);
        labels[last.labels.len] = text;
        last.labels = labels;
    };
    const saved = a.question_drafts.ensure(a, chat, w.request_id) catch return;
    captureAttachments(a, saved) catch return;
    suspendQuestion(a);
    // Only committed references ride the command. Failed or unacknowledged
    // delivery keeps those refs in the request-owned recovery entry.
    attachments.clear(a);
    saved.phase = .in_flight;
    saved.deadline = a.now + 30;
    saved.settle_s = 2;
    const req = requests.respondInput(saved.chat, saved.request, answers);
    saved.call = a.engine.call(req.method, req.params, .of(Entry, saved, onAnswered));
    a.redraw();
}

fn captureAttachments(a: *App, saved: *Entry) !void {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |path| a.gpa.free(path);
        paths.deinit(a.gpa);
    }
    for (a.attachments.items.items) |item| if (item.active(a)) {
        const path = try a.gpa.dupe(u8, item.path orelse continue);
        paths.append(a.gpa, path) catch |err| {
            a.gpa.free(path);
            return err;
        };
    };
    saved.clearAttachments();
    saved.attachment_paths = paths;
}

/// Dismiss follows the same acknowledgement rule as answering. A transport
/// failure must leave the original question available, not suppress it.
pub fn dismiss(a: *App) void {
    const chat = a.selected orelse return;
    const w = a.wizard orelse return;
    const saved = a.question_drafts.ensure(a, chat, w.request_id) catch return;
    suspendQuestion(a);
    saved.phase = .in_flight;
    saved.deadline = a.now + 30;
    saved.settle_s = 5;
    const req = requests.dismissInput(saved.chat, saved.request);
    saved.call = a.engine.call(req.method, req.params, .of(Entry, saved, onAnswered));
    a.redraw();
}

fn onAnswered(saved: *Entry, _: u64, reply: rpc.Reply) void {
    const a = saved.app;
    switch (reply) {
        .ok => {
            saved.phase = .answered;
            saved.call = null;
            // QueueCommand acceptance is not proof the host resolved input.
            // Keep the exact wizard until transcript resolution or recovery.
            saved.deadline = a.now + saved.settle_s;
        },
        .err => |err| {
            saved.phase = .draft;
            saved.call = null;
            saved.deadline = null;
            // A late failure is owned by the old chat. Never replace the
            // answer or composer of the newly selected conversation.
            if (a.selected) |chat| if (std.mem.eql(u8, chat, saved.chat)) {
                a.setNotice(err);
                syncWizard(a);
            };
        },
        else => return,
    }
    a.redraw();
}

fn freeRetired(a: *App) void {
    if (a.retired_wizard) |*w| w.retire(a);
    a.retired_wizard = null;
}

pub fn deinit(a: *App) void {
    if (a.wizard) |*w| w.deinit();
    if (a.retired_wizard) |*w| w.deinit();
    a.retired_wizard = null;
    a.question_drafts.deinit(a.gpa);
    a.draft_stash.deinit(a.gpa);
}
