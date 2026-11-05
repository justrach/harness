//! A pending question from the agent, answered in the composer's place
//! (crates/ui/src/composer.rs `render_wizard`, `wizard_finish`): the newest
//! assistant entry's unresolved input part opens the wizard, the draft is
//! set aside meanwhile and comes back after; the composer's text is the
//! current page's typed answer.
const std = @import("std");
const tr = @import("transcript.zig");
const requests = @import("requests.zig");
const Wizard = @import("wizard.zig").Wizard;
const App = @import("app.zig").App;

/// The question waiting for an answer, if any: an unresolved input part in
/// the newest assistant entry, not answered from here a moment ago.
pub fn pendingInput(a: *const App) ?*const tr.Part {
    const entries = a.transcript.entries.items;
    var i = entries.len;
    while (i > 0) {
        i -= 1;
        const e = &entries[i];
        if (e.role != .assistant) continue;
        for (e.parts.items) |*p| if (p.kind == .input and !p.resolved and p.questions.len > 0) {
            if (a.answered) |done| if (std.mem.eql(u8, done, p.request_id)) return null;
            return p;
        };
        return null;
    }
    return null;
}

/// Opens or closes the wizard as questions come and go; each frame.
pub fn syncWizard(a: *App) void {
    const pending = pendingInput(a);
    if (a.wizard) |*w| {
        if (pending != null and std.mem.eql(u8, pending.?.request_id, w.request_id)) return;
        closeWizard(a);
    }
    const p = pending orelse return;
    const w = Wizard.init(a.gpa, p.request_id, p.questions) catch return;
    a.draft_stash.clearRetainingCapacity();
    a.draft_stash.appendSlice(a.gpa, a.composer.text()) catch {};
    a.composer.set(w.typed[0].items);
    a.wizard = w;
}

fn closeWizard(a: *App) void {
    if (a.wizard) |*w| w.deinit();
    a.wizard = null;
    a.composer.set(a.draft_stash.items);
    a.draft_stash.clearRetainingCapacity();
}

/// Keeps what is typed with the page it was typed on.
fn saveTyped(a: *App, w: *Wizard) void {
    w.typed[w.page].clearRetainingCapacity();
    w.typed[w.page].appendSlice(a.gpa, a.composer.text()) catch {};
}

/// The composer's text belongs to the page being left; the next page's
/// comes in.
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

/// Next, or Submit on the last page.
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

/// The auto-advance after a single-choice pick; from `tick`. The time it
/// is due, while it waits.
pub fn tick(a: *App, now: f64) ?f64 {
    const w = if (a.wizard) |*w| w else return null;
    const at = w.advance_at orelse return null;
    if (now < at) return at;
    w.advance_at = null;
    advance(a);
    return null;
}

fn submit(a: *App) void {
    const chat = a.selected orelse return;
    const w = if (a.wizard) |*w| w else return;
    var arena: std.heap.ArenaAllocator = .init(a.gpa);
    defer arena.deinit();
    const answers = w.answers(arena.allocator()) catch return;
    a.request(requests.respondInput(chat, w.request_id, answers), .of(App, a, App.onNotice));
    markAnswered(a, w.request_id);
    closeWizard(a);
    a.redraw();
}

/// "Cancel question": dismiss it without answering, which stops its turn.
pub fn dismiss(a: *App) void {
    const chat = a.selected orelse return;
    const w = a.wizard orelse return;
    a.request(requests.dismissInput(chat, w.request_id), .of(App, a, App.onNotice));
    markAnswered(a, w.request_id);
    closeWizard(a);
    a.redraw();
}

fn markAnswered(a: *App, request_id: []const u8) void {
    if (a.answered) |old| a.gpa.free(old);
    a.answered = a.gpa.dupe(u8, request_id) catch null;
}

pub fn deinit(a: *App) void {
    if (a.wizard) |*w| w.deinit();
    if (a.answered) |s| a.gpa.free(s);
    a.draft_stash.deinit(a.gpa);
}
