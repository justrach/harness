//! Answering an agent's questions, as the GPUI composer's `Wizard` does
//! (crates/ui/src/composer.rs): one page per question; a single-choice pick
//! moves on by itself after 220 ms, multi-choice picks toggle; typed text
//! replaces the picks (trimmed, unless the question is multiline, which
//! always answers with what was typed). The answers go out as
//! `respondInput` with `[{questionId, labels}]`.
const std = @import("std");
const tr = @import("transcript.zig");
const Allocator = std.mem.Allocator;

pub const auto_advance_s = 0.22;

pub const Answer = struct {
    questionId: []const u8,
    labels: []const []const u8,
};

pub const Wizard = struct {
    gpa: Allocator,
    /// Its own copy of the questions: the transcript may replace the part.
    arena: *std.heap.ArenaAllocator,
    request_id: []const u8,
    questions: []const tr.Question,
    page: usize = 0,
    /// Each page's picks, as option indices in the order clicked.
    picks: []std.ArrayList(u8),
    /// Each page's typed answer (the composer's text while on it).
    typed: []std.ArrayList(u8),
    /// When a single-choice pick moves on by itself.
    advance_at: ?f64 = null,

    pub fn init(gpa: Allocator, request_id: []const u8, source: []const tr.Question) !Wizard {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const a = arena.allocator();
        const questions = try a.alloc(tr.Question, source.len);
        for (source, questions) |q, *d| {
            const opts = try a.alloc([]const u8, q.options.len);
            for (q.options, opts) |o, *od| od.* = try a.dupe(u8, o);
            d.* = .{
                .id = try a.dupe(u8, q.id),
                .header = try a.dupe(u8, q.header),
                .question = try a.dupe(u8, q.question),
                .options = opts,
                .multi_select = q.multi_select,
                .multiline = q.multiline,
                .prefill = if (q.prefill) |pf| try a.dupe(u8, pf) else null,
            };
        }
        const picks = try gpa.alloc(std.ArrayList(u8), questions.len);
        errdefer gpa.free(picks);
        const typed = try gpa.alloc(std.ArrayList(u8), questions.len);
        errdefer gpa.free(typed);
        for (picks) |*p| p.* = .empty;
        for (typed, questions) |*t, q| {
            t.* = .empty;
            if (q.prefill) |pre| try t.appendSlice(gpa, pre);
        }
        return .{ .gpa = gpa, .arena = arena, .request_id = try a.dupe(u8, request_id), .questions = questions, .picks = picks, .typed = typed };
    }

    pub fn deinit(w: *Wizard) void {
        for (w.picks) |*p| p.deinit(w.gpa);
        for (w.typed) |*t| t.deinit(w.gpa);
        w.gpa.free(w.picks);
        w.gpa.free(w.typed);
        w.arena.deinit();
        w.gpa.destroy(w.arena);
    }

    pub fn question(w: *const Wizard) tr.Question {
        return w.questions[w.page];
    }

    pub fn last(w: *const Wizard) bool {
        return w.page + 1 >= w.questions.len;
    }

    pub fn picked(w: *const Wizard, option: usize) bool {
        return std.mem.indexOfScalar(u8, w.picks[w.page].items, @intCast(option)) != null;
    }

    /// Picks option `i` at time `now`; a single-choice pick schedules the
    /// move to the next page (or the submit, on the last).
    pub fn pick(w: *Wizard, i: usize, now: f64) void {
        const q = w.question();
        if (i >= q.options.len or i > 255) return;
        const list = &w.picks[w.page];
        const idx: u8 = @intCast(i);
        if (q.multi_select) {
            if (std.mem.indexOfScalar(u8, list.items, idx)) |at| {
                _ = list.orderedRemove(at);
            } else list.append(w.gpa, idx) catch {};
            return;
        }
        list.clearRetainingCapacity();
        list.append(w.gpa, idx) catch {};
        w.advance_at = now + auto_advance_s;
    }

    fn typedText(w: *const Wizard, page: usize) []const u8 {
        const t = w.typed[page].items;
        return if (w.questions[page].multiline) t else std.mem.trim(u8, t, " \t\n");
    }

    /// Next or Submit can be pressed: a pick, typed text, or a multiline
    /// question (which may be answered empty).
    pub fn canAdvance(w: *const Wizard) bool {
        const q = w.question();
        return q.multiline or w.picks[w.page].items.len > 0 or w.typedText(w.page).len > 0;
    }

    /// The answers, in `arena`.
    pub fn answers(w: *const Wizard, arena: Allocator) ![]Answer {
        const out = try arena.alloc(Answer, w.questions.len);
        for (w.questions, 0..) |q, i| {
            const typed = w.typedText(i);
            const labels: []const []const u8 = if (q.multiline or typed.len > 0) blk: {
                const one = try arena.alloc([]const u8, 1);
                one[0] = try arena.dupe(u8, typed);
                break :blk one;
            } else blk: {
                const many = try arena.alloc([]const u8, w.picks[i].items.len);
                for (w.picks[i].items, 0..) |o, j| many[j] = q.options[o];
                break :blk many;
            };
            out[i] = .{ .questionId = q.id, .labels = labels };
        }
        return out;
    }
};

const testing = std.testing;

const qs = [_]tr.Question{
    .{ .id = "q-sync", .header = "Question", .question = "Which sync?", .options = &.{ "Poll", "Event-driven", "Hybrid" } },
    .{ .id = "q-gates", .header = "Question", .question = "Which suites?", .options = &.{ "Unit", "E2E", "Golden" }, .multi_select = true },
};

test "a single pick moves on; multi picks toggle in click order" {
    var w: Wizard = try .init(testing.allocator, "r1", &qs);
    defer w.deinit();
    try testing.expect(!w.canAdvance());
    w.pick(1, 10);
    try testing.expectEqual(@as(?f64, 10.22), w.advance_at);
    try testing.expect(w.canAdvance());
    w.page = 1;
    w.pick(2, 11);
    w.pick(0, 11);
    w.pick(2, 11);
    w.pick(2, 11);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try w.answers(arena.allocator());
    try testing.expectEqualStrings("Event-driven", a[0].labels[0]);
    try testing.expectEqual(@as(usize, 2), a[1].labels.len);
    try testing.expectEqualStrings("Unit", a[1].labels[0]);
    try testing.expectEqualStrings("Golden", a[1].labels[1]);
}

test "typed text replaces the picks, trimmed" {
    var w: Wizard = try .init(testing.allocator, "r1", &qs);
    defer w.deinit();
    w.pick(0, 0);
    try w.typed[0].appendSlice(testing.allocator, "  my own  ");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try w.answers(arena.allocator());
    try testing.expectEqual(@as(usize, 1), a[0].labels.len);
    try testing.expectEqualStrings("my own", a[0].labels[0]);
    try testing.expectEqual(@as(usize, 0), a[1].labels.len);
}
