//! The requests in `protocol/desktop/requests.json`, built by the same
//! functions the app sends them with (requests.zig). `zig build vectors`
//! writes the file from here; the Zig runner checks the builders still
//! produce it, and the Rust runner (crates/engine/tests/desktop_requests.rs)
//! sends each to a real engine and checks it is understood.
//!
//! Placeholders the Rust runner fills in: `$DEVICE` (the engine's device
//! id) and `$DIR` (the project's folder).
const std = @import("std");
const json = std.json;
const r = @import("requests.zig");

const chat = "chat-parity";
const space = "space-parity";
const device = "$DEVICE";
const dir = "$DIR";

pub const Case = struct { name: []const u8, method: []const u8, params: []u8, stream: bool };

fn case(gpa: std.mem.Allocator, name: []const u8, req: anytype, stream: bool) !Case {
    const params = try json.Stringify.valueAlloc(gpa, req.params, .{ .emit_null_optional_fields = false });
    return .{ .name = name, .method = req.method, .params = params, .stream = stream };
}

/// Every request, in the order a runner sends them (a project and a chat
/// first, so later requests name ones that exist).
pub fn cases(gpa: std.mem.Allocator) ![]Case {
    const answers = [_]r.Answer{ .{ .questionId = "q1", .labels = &.{"Event-driven"} }, .{ .questionId = "q2", .labels = &.{ "Unit", "E2E" } } };
    const list = [_]Case{
        try case(gpa, "create a project", r.createSpace(space, device, dir, false), false),
        try case(gpa, "create a chat", r.createChat(chat, space, .{ .harness = "mock" }), false),
        try case(gpa, "engine info", r.none("EngineInfo"), false),
        try case(gpa, "engine ready", r.none("EngineReady"), false),
        try case(gpa, "list agents", r.none("ListHarnesses"), false),
        try case(gpa, "list models", r.listModels("mock"), false),
        try case(gpa, "watch spaces", r.none("WatchSpaces"), true),
        try case(gpa, "watch chats", r.none("WatchChats"), true),
        try case(gpa, "watch sessions", r.none("WatchSessions"), true),
        try case(gpa, "watch devices", r.none("WatchDevices"), true),
        try case(gpa, "focus a chat", r.focusChat(chat), false),
        try case(gpa, "mark a chat seen", r.markChatSeen(chat), false),
        try case(gpa, "watch a transcript", r.watchDoc(chat, true), true),
        try case(gpa, "set a chat's config", r.setChatConfig(chat, .{ .harness = "mock", .reasoning = "medium" }), false),
        try case(gpa, "archive a chat", r.setChatArchived(chat, true), false),
        try case(gpa, "unarchive a chat", r.setChatArchived(chat, false), false),
        try case(gpa, "run a prompt", r.run(chat, "11111111-0000-4000-8000-000000000001", .{ .prompt = "Add rate limiting", .harness = "mock", .cwd = dir }), false),
        try case(gpa, "stop the run", r.interrupt(chat), false),
        try case(gpa, "answer a question", r.respondInput(chat, "req-parity", &answers), false),
        try case(gpa, "dismiss a question", r.dismissInput(chat, "req-parity"), false),
        try case(gpa, "watch the queue", r.watchQueue(chat), true),
        try case(gpa, "queue a message", r.queueMessage(chat, "Then update the changelog"), false),
        try case(gpa, "remove a queued message", r.removeQueued(chat, "row-parity", null), false),
        try case(gpa, "send a queued message now", r.sendQueuedNow(chat, "row-parity", null), false),
        try case(gpa, "begin editing a queued message", r.beginEdit(chat, "row-parity", device, "22222222-0000-4000-8000-000000000002", null), false),
        try case(gpa, "renew an edit", r.renewEdit(chat, "row-parity", "lease-parity", null), false),
        try case(gpa, "save an edit", r.finishEdit(chat, "row-parity", "lease-parity", "commit", "Then update the README", "abc123", null), false),
        try case(gpa, "cancel an edit", r.finishEdit(chat, "row-parity", "lease-parity", "cancel", null, null, null), false),
        try case(gpa, "watch the checkout diffs", r.watchDiffs(null), true),
        try case(gpa, "the working tree's diff", r.getDiff(dir, "workingTree", null, null, null), false),
        try case(gpa, "the branch's diff", r.getDiff(dir, "branch", "main", null, null), false),
        try case(gpa, "the latest turn's diff", r.getDiff(dir, "turn", null, chat, null), false),
        try case(gpa, "discard the working tree", r.discard(chat, "checkout-parity", "sum-parity", null), false),
        try case(gpa, "list a folder", r.listDirectory(chat, "", false, null), false),
        try case(gpa, "search files", r.searchFiles(chat, "readme", true, null), false),
        try case(gpa, "read a file", r.readFile(chat, "README.md", null), false),
        try case(gpa, "watch git", r.watchGit(space, dir, null), true),
        try case(gpa, "list project actions", r.listActions(space, null), false),
        // Before the action exists: a real run would leave a terminal open.
        try case(gpa, "run a project action", r.runAction(space, chat, "test", null), false),
        try case(gpa, "add a project action", r.upsertAction(space, null, .{ .name = "Test", .command = "echo hi", .icon = "test", .runOnWorktreeCreate = false }, null), false),
        try case(gpa, "change a project action", r.upsertAction(space, "test", .{ .name = "Test", .command = "echo hello", .icon = "play", .runOnWorktreeCreate = true }, null), false),
        try case(gpa, "watch a terminal", r.subscribeTerminal("terminal-parity", null), true),
        try case(gpa, "close a terminal", r.closeTerminal("terminal-parity", null), false),
        try case(gpa, "delete a project action", r.deleteAction(space, "test", null), false),
        // The chat isn't in a Graff worktree: the engine refuses it, understood.
        try case(gpa, "merge a Graff worktree back", r.graffWorktreeAction(chat, "merge", null), false),
        // The project isn't a git checkout: no PR to watch or merge, answered.
        try case(gpa, "watch a branch's pull request", r.watchChangeRequest(.{ .cwd = dir, .branch = "main" }), true),
        try case(gpa, "merge a branch's pull request", r.mergeChangeRequest(.{ .cwd = dir, .branch = "main", .number = 90 }), false),
    };
    return gpa.dupe(Case, &list);
}

/// The vector file's JSON.
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer) !void {
    const list = try cases(gpa);
    try w.writeAll(
        \\{
        \\  "comment": "Every request harness-nano sends the engine, written by `zig build vectors` (apps/nano/src/parity_requests.zig) from the builders the app sends them with. The Zig runner checks the builders still produce exactly these; the Rust runner (crates/engine/tests/desktop_requests.rs) sends each, in order, to a real engine and fails on bad params or an unknown method. $DEVICE and $DIR are the engine's device id and the project's folder.",
        \\  "requests": [
        \\
    );
    for (list, 0..) |c, i| {
        try w.print("    {{\"name\": {f}, \"method\": {f}, \"stream\": {}, \"params\": {s}}}{s}\n", .{
            json.fmt(c.name, .{}), json.fmt(c.method, .{}), c.stream, c.params, if (i + 1 < list.len) "," else "",
        });
    }
    try w.writeAll("  ]\n}\n");
}
