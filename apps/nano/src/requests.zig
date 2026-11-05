//! Every request harness-nano sends the engine, built in one place so
//! `protocol/desktop/requests.json` can pin each one's JSON: the Zig runner
//! (parity.zig) checks these builders produce it, and the Rust runner
//! (crates/engine/tests/desktop_requests.rs) sends the same JSON to a real
//! engine and checks it is accepted. Optional fields are left out when null
//! (`rpc.Mux.call` writes them so); `{}` is `rpc.empty`, never `[]`.
const rpc = @import("rpc.zig");

const Empty = rpc.Empty;

/// A request's method and params.
pub fn Request(comptime P: type) type {
    return struct { method: []const u8, params: P };
}

pub fn none(method: []const u8) Request(Empty) {
    return .{ .method = method, .params = rpc.empty };
}

// ── chats ────────────────────────────────────────────────────────────

pub const Config = struct {
    harness: []const u8,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    modelOptions: Empty = .{},
    sandbox: []const u8 = "workspace-write",
};

pub fn createChat(chat_id: []const u8, space_id: ?[]const u8, config: Config) Request(struct { op: []const u8, chatId: []const u8, spaceId: ?[]const u8, config: Config }) {
    return .{ .method = "Mutate", .params = .{ .op = "createChat", .chatId = chat_id, .spaceId = space_id, .config = config } };
}

pub fn setChatConfig(chat_id: []const u8, config: Config) Request(struct { op: []const u8, chatId: []const u8, config: Config }) {
    return .{ .method = "Mutate", .params = .{ .op = "setChatConfig", .chatId = chat_id, .config = config } };
}

pub fn markChatSeen(chat_id: []const u8) Request(struct { op: []const u8, chatId: []const u8 }) {
    return .{ .method = "Mutate", .params = .{ .op = "markChatSeen", .chatId = chat_id } };
}

pub fn setChatArchived(chat_id: []const u8, archived: bool) Request(struct { op: []const u8, chatId: []const u8, archived: bool }) {
    return .{ .method = "Mutate", .params = .{ .op = "setChatArchived", .chatId = chat_id, .archived = archived } };
}

pub fn createSpace(space_id: []const u8, device_id: []const u8, path: []const u8, git: bool) Request(struct { op: []const u8, spaceId: []const u8, deviceId: []const u8, path: []const u8, gitDetected: bool }) {
    return .{ .method = "Mutate", .params = .{ .op = "createSpace", .spaceId = space_id, .deviceId = device_id, .path = path, .gitDetected = git } };
}

pub fn focusChat(chat_id: []const u8) Request(struct { chatId: []const u8 }) {
    return .{ .method = "FocusChat", .params = .{ .chatId = chat_id } };
}

pub fn watchDoc(chat_id: []const u8, opening_tail: bool) Request(struct { chatId: []const u8, openingTail: bool }) {
    return .{ .method = "WatchDocMessages", .params = .{ .chatId = chat_id, .openingTail = opening_tail } };
}

pub fn fetchToolBlob(blob_ref: []const u8) Request(struct { blobRef: []const u8 }) {
    return .{ .method = "FetchToolBlob", .params = .{ .blobRef = blob_ref } };
}

pub fn listModels(harness: []const u8) Request(struct { harness: []const u8 }) {
    return .{ .method = "ListModels", .params = .{ .harness = harness } };
}

// ── commands ─────────────────────────────────────────────────────────

pub const RunRequest = struct {
    prompt: []const u8,
    turnOrigin: []const u8 = "human",
    harness: ?[]const u8 = null,
    model: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    modelOptions: Empty = .{},
    cwd: []const u8,
    sandbox: []const u8 = "workspace-write",
    autoApprove: bool = false,
};

const Run = struct { kind: []const u8, messageId: []const u8, request: RunRequest };

pub fn run(chat_id: []const u8, message_id: []const u8, request: RunRequest) Request(struct { chatId: []const u8, command: Run }) {
    return .{ .method = "QueueCommand", .params = .{ .chatId = chat_id, .command = Run{ .kind = "run", .messageId = message_id, .request = request } } };
}

pub fn interrupt(chat_id: []const u8) Request(struct { chatId: []const u8, command: struct { kind: []const u8 } }) {
    return .{ .method = "QueueCommand", .params = .{ .chatId = chat_id, .command = .{ .kind = "interrupt" } } };
}

pub const Answer = @import("wizard.zig").Answer;

pub fn respondInput(chat_id: []const u8, request_id: []const u8, answers: []const Answer) Request(struct { chatId: []const u8, command: struct { kind: []const u8, requestId: []const u8, answers: []const Answer } }) {
    return .{ .method = "QueueCommand", .params = .{ .chatId = chat_id, .command = .{ .kind = "respondInput", .requestId = request_id, .answers = answers } } };
}

pub fn dismissInput(chat_id: []const u8, request_id: []const u8) Request(struct { chatId: []const u8, command: struct { kind: []const u8, requestId: []const u8 } }) {
    return .{ .method = "QueueCommand", .params = .{ .chatId = chat_id, .command = .{ .kind = "dismissInput", .requestId = request_id } } };
}

// ── the queue ────────────────────────────────────────────────────────

pub fn watchQueue(chat_id: []const u8) Request(struct { chatId: []const u8 }) {
    return .{ .method = "WatchQueue", .params = .{ .chatId = chat_id } };
}

pub fn queueMessage(chat_id: []const u8, text: []const u8) Request(struct { chatId: []const u8, text: []const u8, holdForTurnEnd: bool }) {
    return .{ .method = "QueueMessage", .params = .{ .chatId = chat_id, .text = text, .holdForTurnEnd = true } };
}

const Row = struct { chatId: []const u8, id: []const u8, targetDeviceId: ?[]const u8 };

pub fn removeQueued(chat_id: []const u8, row: []const u8, host: ?[]const u8) Request(Row) {
    return .{ .method = "RemoveQueuedMessage", .params = Row{ .chatId = chat_id, .id = row, .targetDeviceId = host } };
}

pub fn sendQueuedNow(chat_id: []const u8, row: []const u8, host: ?[]const u8) Request(Row) {
    return .{ .method = "SendQueuedMessageNow", .params = Row{ .chatId = chat_id, .id = row, .targetDeviceId = host } };
}

pub fn beginEdit(chat_id: []const u8, row: []const u8, device: []const u8, instance: []const u8, host: ?[]const u8) Request(struct { chatId: []const u8, id: []const u8, editorDeviceId: []const u8, editorInstanceId: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "BeginQueuedMessageEdit", .params = .{ .chatId = chat_id, .id = row, .editorDeviceId = device, .editorInstanceId = instance, .targetDeviceId = host } };
}

pub fn renewEdit(chat_id: []const u8, row: []const u8, lease: []const u8, host: ?[]const u8) Request(struct { chatId: []const u8, id: []const u8, leaseId: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "RenewQueuedMessageEdit", .params = .{ .chatId = chat_id, .id = row, .leaseId = lease, .targetDeviceId = host } };
}

/// `action` is commit, cancel or discard; a commit carries the text and
/// the hash of the text the lease began from.
pub fn finishEdit(chat_id: []const u8, row: []const u8, lease: []const u8, action: []const u8, text: ?[]const u8, hash: ?[]const u8, host: ?[]const u8) Request(struct { chatId: []const u8, id: []const u8, leaseId: []const u8, action: []const u8, text: ?[]const u8, expectedTextHash: ?[]const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "FinishQueuedMessageEdit", .params = .{ .chatId = chat_id, .id = row, .leaseId = lease, .action = action, .text = text, .expectedTextHash = hash, .targetDeviceId = host } };
}

// ── panels ───────────────────────────────────────────────────────────

pub fn watchDiffs(host: ?[]const u8) Request(struct { targetDeviceId: ?[]const u8 }) {
    return .{ .method = "WatchCheckoutDiffs", .params = .{ .targetDeviceId = host } };
}

pub fn getDiff(cwd: []const u8, mode: []const u8, base_ref: ?[]const u8, chat_id: ?[]const u8, host: ?[]const u8) Request(struct { cwd: []const u8, mode: []const u8, baseRef: ?[]const u8, chatId: ?[]const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "GetCheckoutDiff", .params = .{ .cwd = cwd, .mode = mode, .baseRef = base_ref, .chatId = chat_id, .targetDeviceId = host } };
}

pub fn discard(chat_id: []const u8, checkout_id: []const u8, checksum: []const u8, host: ?[]const u8) Request(struct { chatId: []const u8, checkoutId: []const u8, expectedChecksum: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "DiscardWorkingTree", .params = .{ .chatId = chat_id, .checkoutId = checkout_id, .expectedChecksum = checksum, .targetDeviceId = host } };
}

pub fn listDirectory(chat_id: []const u8, dir: []const u8, include_ignored: bool, host: ?[]const u8) Request(struct { chatId: []const u8, directory: []const u8, includeIgnored: bool, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "ListWorkspaceDirectory", .params = .{ .chatId = chat_id, .directory = dir, .includeIgnored = include_ignored, .targetDeviceId = host } };
}

pub fn searchFiles(chat_id: []const u8, query: []const u8, include_ignored: bool, host: ?[]const u8) Request(struct { chatId: []const u8, query: []const u8, includeIgnored: bool, limit: u16, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "SearchWorkspaceFiles", .params = .{ .chatId = chat_id, .query = query[0..@min(query.len, 256)], .includeIgnored = include_ignored, .limit = 200, .targetDeviceId = host } };
}

pub fn readFile(chat_id: []const u8, path: []const u8, host: ?[]const u8) Request(struct { chatId: []const u8, path: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "ReadWorkspaceFile", .params = .{ .chatId = chat_id, .path = path, .targetDeviceId = host } };
}

pub fn watchGit(space_id: []const u8, checkout: []const u8, host: ?[]const u8) Request(struct { spaceId: []const u8, checkoutPath: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "WatchWorkspaceGitStatus", .params = .{ .spaceId = space_id, .checkoutPath = checkout, .targetDeviceId = host } };
}

// ── project actions ──────────────────────────────────────────────────

pub const ActionDraft = struct { name: []const u8, command: []const u8, icon: []const u8, runOnWorktreeCreate: bool };

pub fn listActions(space_id: []const u8, host: ?[]const u8) Request(struct { spaceId: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "ListProjectActions", .params = .{ .spaceId = space_id, .targetDeviceId = host } };
}

pub fn upsertAction(space_id: []const u8, action_id: ?[]const u8, action: ActionDraft, host: ?[]const u8) Request(struct { spaceId: []const u8, actionId: ?[]const u8, action: ActionDraft, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "UpsertProjectAction", .params = .{ .spaceId = space_id, .actionId = action_id, .action = action, .targetDeviceId = host } };
}

pub fn deleteAction(space_id: []const u8, action_id: []const u8, host: ?[]const u8) Request(struct { spaceId: []const u8, actionId: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "DeleteProjectAction", .params = .{ .spaceId = space_id, .actionId = action_id, .targetDeviceId = host } };
}

pub fn runAction(space_id: []const u8, chat_id: []const u8, action_id: []const u8, host: ?[]const u8) Request(struct { spaceId: []const u8, chatId: []const u8, actionId: []const u8, cols: u16, rows: u16, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "RunProjectAction", .params = .{ .spaceId = space_id, .chatId = chat_id, .actionId = action_id, .cols = 80, .rows = 24, .targetDeviceId = host } };
}

pub fn subscribeTerminal(terminal_id: []const u8, host: ?[]const u8) Request(struct { terminalId: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "SubscribeTerminal", .params = .{ .terminalId = terminal_id, .targetDeviceId = host } };
}

pub fn closeTerminal(terminal_id: []const u8, host: ?[]const u8) Request(struct { terminalId: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "CloseTerminal", .params = .{ .terminalId = terminal_id, .targetDeviceId = host } };
}

// ── Graff worktrees ──────────────────────────────────────────────────

/// `GraffWorktreeAction`: "merge", "archive", "remove" or "discard" the
/// chat's Graff worktree (`run_graff_worktree_action`, pickers.rs).
pub fn graffWorktreeAction(chat_id: []const u8, action: []const u8, host: ?[]const u8) Request(struct { chatId: []const u8, action: []const u8, targetDeviceId: ?[]const u8 }) {
    return .{ .method = "GraffWorktreeAction", .params = .{ .chatId = chat_id, .action = action, .targetDeviceId = host } };
}

// ── pull requests ────────────────────────────────────────────────────

/// `WatchCheckoutChangeRequest` (state.rs `spawn_change_request_watch`):
/// the branch's PR on the checkout at `cwd`, a checked stream.
pub fn watchChangeRequest(p: @import("change_requests.zig").WatchParams) Request(@import("change_requests.zig").WatchParams) {
    return .{ .method = "WatchCheckoutChangeRequest", .params = p };
}

/// `MergeChangeRequest` (pickers.rs `run_change_request_merge`).
pub fn mergeChangeRequest(p: @import("change_requests.zig").MergeParams) Request(@import("change_requests.zig").MergeParams) {
    return .{ .method = "MergeChangeRequest", .params = p };
}
