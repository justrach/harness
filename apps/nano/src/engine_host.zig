//! `EngineHost` — the Zig port of `crates/engine` (`EngineCore` + `EngineRpc`):
//! workspace registry (spaces, chats, devices, sessions), `SessionDoc` host,
//! command queue executor, `DocsStore` SQLite persistence, `TerminalManager`,
//! `AuthManager`, `RunJournal`, live `Watch*` pub/sub stream broadcaster, and
//! the JSON-RPC service over `ws://127.0.0.1:{HARNESS_IPC_PORT|27664}`.
//!
//! Includes the Zig conformance runner against `protocol/desktop/requests.json`
//! (mirroring `crates/engine/tests/desktop_requests.rs`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const build_info = @import("build_info");
const session_doc = @import("session_doc.zig");
const docs_store = @import("docs_store.zig");
const acp_host = @import("acp_host.zig");
const adapters_host = @import("adapters_host.zig");
const workspace_files_host = @import("workspace_files_host.zig");
const git_host = @import("git_host.zig");
const terminals_host = @import("terminals_host.zig");
const registry_sync = @import("registry_sync.zig");
const chat2_client = @import("chat2_client.zig");
const auth_host = @import("auth_host.zig");
const run_journal = @import("run_journal.zig");
const ws_server = @import("ws_server.zig");
const ws = @import("ws.zig");
const rpc = @import("rpc.zig");

pub const RpcError = union(enum) {
    bad_params: []const u8,
    unknown_method: []const u8,
    exec_error: []const u8,
};

pub const RpcOutcome = union(enum) {
    unary_json: []u8,
    stream_items_json: struct {
        checked: bool = false,
        items: [][]u8,

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            for (self.items) |it| gpa.free(it);
            gpa.free(self.items);
        }
    },
    err: RpcError,
};

pub const WatchKind = enum {
    spaces,
    chats,
    sessions,
    devices,
    doc_messages,
    queue,
    auth_status,
};

pub const max_committed_uploads_cache: usize = 8;

/// Exhaustive 1:1 RPC method table matching `crates/rpc/src/lib.rs` (`pub mod methods`,
/// 148 canonical methods) plus 5 compatibility aliases (153 total), dispatched in O(1)
/// via `rpc_method_map`.
pub const RpcMethod = enum {
    // 148 canonical methods from crates/rpc/src/lib.rs:
    WatchPreviews,
    ListHarnesses,
    CancelInstall,
    InstallHarness,
    GetTitleSettings,
    SetTitleSettings,
    GetGraffDraftSubagents,
    SetGraffDraftSubagents,
    GetGraffCompactAt,
    SetGraffCompactAt,
    GetKeepAwake,
    SetKeepAwake,
    SetHarnessEnabled,
    GetAutonomy,
    SetAutonomy,
    ListModels,
    ListSkills,
    ListCommands,
    QueueCommand,
    TakeProjectActionSetup,
    RelayCommand,
    RetryDelivery,
    WatchDocMessages,
    FocusChat,
    WatchQueue,
    WatchToolProgress,
    QueueMessage,
    UpdateQueuedMessage,
    BeginQueuedMessageEdit,
    RenewQueuedMessageEdit,
    FinishQueuedMessageEdit,
    MoveQueuedMessage,
    RemoveQueuedMessage,
    SendQueuedMessageNow,
    ShowImage,
    ShowVisual,
    SteerQueuedMessageNow,
    ProbeSync,
    SyncStatus,
    WatchConnectivity,
    WatchTransfers,
    WatchChats,
    WatchSidebarPreferences,
    WatchDevices,
    WatchSessions,
    WatchSpaces,
    Mutate,
    LocalDevice,
    EngineInfo,
    EngineReady,
    StopEngine,
    AuthStatus,
    SignIn,
    SignInHeadless,
    CompleteSignIn,
    SignOut,
    CodegraffSignIn,
    CodegraffAuthStatus,
    CodegraffUsage,
    CodegraffSignOut,
    ExternalHistoryList,
    ExternalHistoryImport,
    CodexConversationPreview,
    CodexConversationImport,
    CodegraffJobs,
    CodegraffCancelJob,
    CodegraffSandboxes,
    CodegraffCreateSandbox,
    CodegraffCreateTemporarySandbox,
    CodegraffSandboxAction,
    CodegraffGithubRunners,
    CodegraffGithubRunnerAction,
    RoomRequest,
    BrowseLinkStatus,
    BrowseLinkPair,
    BrowseLinkDisconnect,
    ListOrgs,
    CreateOrg,
    SelectOrg,
    LocalImportStatus,
    ImportLocalWorkspace,
    ListRepos,
    AddRepo,
    CloneRepo,
    CreateRepo,
    ListBranches,
    ListRefs,
    ListGitHistory,
    SearchGitHistory,
    ResolveGitAvatars,
    FetchAll,
    SwitchRef,
    ListFolders,
    ListDrives,
    SearchFiles,
    ListWorkspaceDirectory,
    SearchWorkspaceFiles,
    ReadWorkspaceImage,
    ReadWorkspaceFile,
    WriteWorkspaceFile,
    WatchWorkspaceFiles,
    CreateWorktree,
    DeleteWorktree,
    GraffWorktreeAction,
    ListProjectActions,
    UpsertProjectAction,
    DeleteProjectAction,
    RunProjectAction,
    OpenTerminal,
    SubscribeTerminal,
    WriteTerminal,
    ResizeTerminal,
    CloseTerminal,
    ListSimulators,
    SetUpSimulators,
    BootSimulator,
    ShutdownSimulator,
    WatchSimulatorScreen,
    SimulatorInput,
    WatchLocalhostPage,
    LocalhostPageInput,
    ListLocalhostServers,
    WatchCheckoutDiffs,
    WatchWorkspaceGitStatus,
    WatchCheckoutChangeRequest,
    MergeChangeRequest,
    GetCheckoutDiff,
    DiscardWorkingTree,
    GetCheckoutFileDiffText,
    ListAgentAccounts,
    ActivateAgentAccount,
    ForgetAgentAccount,
    StartAgentLogin,
    CompleteAgentLogin,
    PollAgentLogin,
    CancelAgentLogin,
    ListGraffLogins,
    SignOutGraffLogin,
    ListMcpServers,
    McpServerAction,
    UploadChunk,
    UploadCommit,
    ReadAttachmentChunk,
    FetchToolBlob,
    UpdateStatus,
    ApplyUpdate,
    CheckForUpdates,
    QueueUpdate,
    // 5 compatibility aliases:
    GetAuthStatus,
    GetCodegraffStatus,
    RemoveAgentAccount,
    SignInWithKey,
    SwitchAgentAccount,
};

pub const rpc_method_map = std.StaticStringMap(RpcMethod).initComptime(.{
    .{ "WatchPreviews", .WatchPreviews },
    .{ "ListHarnesses", .ListHarnesses },
    .{ "CancelInstall", .CancelInstall },
    .{ "InstallHarness", .InstallHarness },
    .{ "GetTitleSettings", .GetTitleSettings },
    .{ "SetTitleSettings", .SetTitleSettings },
    .{ "GetGraffDraftSubagents", .GetGraffDraftSubagents },
    .{ "SetGraffDraftSubagents", .SetGraffDraftSubagents },
    .{ "GetGraffCompactAt", .GetGraffCompactAt },
    .{ "SetGraffCompactAt", .SetGraffCompactAt },
    .{ "GetKeepAwake", .GetKeepAwake },
    .{ "SetKeepAwake", .SetKeepAwake },
    .{ "SetHarnessEnabled", .SetHarnessEnabled },
    .{ "GetAutonomy", .GetAutonomy },
    .{ "SetAutonomy", .SetAutonomy },
    .{ "ListModels", .ListModels },
    .{ "ListSkills", .ListSkills },
    .{ "ListCommands", .ListCommands },
    .{ "QueueCommand", .QueueCommand },
    .{ "TakeProjectActionSetup", .TakeProjectActionSetup },
    .{ "RelayCommand", .RelayCommand },
    .{ "RetryDelivery", .RetryDelivery },
    .{ "WatchDocMessages", .WatchDocMessages },
    .{ "FocusChat", .FocusChat },
    .{ "WatchQueue", .WatchQueue },
    .{ "WatchToolProgress", .WatchToolProgress },
    .{ "QueueMessage", .QueueMessage },
    .{ "UpdateQueuedMessage", .UpdateQueuedMessage },
    .{ "BeginQueuedMessageEdit", .BeginQueuedMessageEdit },
    .{ "RenewQueuedMessageEdit", .RenewQueuedMessageEdit },
    .{ "FinishQueuedMessageEdit", .FinishQueuedMessageEdit },
    .{ "MoveQueuedMessage", .MoveQueuedMessage },
    .{ "RemoveQueuedMessage", .RemoveQueuedMessage },
    .{ "SendQueuedMessageNow", .SendQueuedMessageNow },
    .{ "ShowImage", .ShowImage },
    .{ "ShowVisual", .ShowVisual },
    .{ "SteerQueuedMessageNow", .SteerQueuedMessageNow },
    .{ "ProbeSync", .ProbeSync },
    .{ "SyncStatus", .SyncStatus },
    .{ "WatchConnectivity", .WatchConnectivity },
    .{ "WatchTransfers", .WatchTransfers },
    .{ "WatchChats", .WatchChats },
    .{ "WatchSidebarPreferences", .WatchSidebarPreferences },
    .{ "WatchDevices", .WatchDevices },
    .{ "WatchSessions", .WatchSessions },
    .{ "WatchSpaces", .WatchSpaces },
    .{ "Mutate", .Mutate },
    .{ "LocalDevice", .LocalDevice },
    .{ "EngineInfo", .EngineInfo },
    .{ "EngineReady", .EngineReady },
    .{ "StopEngine", .StopEngine },
    .{ "AuthStatus", .AuthStatus },
    .{ "SignIn", .SignIn },
    .{ "SignInHeadless", .SignInHeadless },
    .{ "CompleteSignIn", .CompleteSignIn },
    .{ "SignOut", .SignOut },
    .{ "CodegraffSignIn", .CodegraffSignIn },
    .{ "CodegraffAuthStatus", .CodegraffAuthStatus },
    .{ "CodegraffUsage", .CodegraffUsage },
    .{ "CodegraffSignOut", .CodegraffSignOut },
    .{ "ExternalHistoryList", .ExternalHistoryList },
    .{ "ExternalHistoryImport", .ExternalHistoryImport },
    .{ "CodexConversationPreview", .CodexConversationPreview },
    .{ "CodexConversationImport", .CodexConversationImport },
    .{ "CodegraffJobs", .CodegraffJobs },
    .{ "CodegraffCancelJob", .CodegraffCancelJob },
    .{ "CodegraffSandboxes", .CodegraffSandboxes },
    .{ "CodegraffCreateSandbox", .CodegraffCreateSandbox },
    .{ "CodegraffCreateTemporarySandbox", .CodegraffCreateTemporarySandbox },
    .{ "CodegraffSandboxAction", .CodegraffSandboxAction },
    .{ "CodegraffGithubRunners", .CodegraffGithubRunners },
    .{ "CodegraffGithubRunnerAction", .CodegraffGithubRunnerAction },
    .{ "RoomRequest", .RoomRequest },
    .{ "BrowseLinkStatus", .BrowseLinkStatus },
    .{ "BrowseLinkPair", .BrowseLinkPair },
    .{ "BrowseLinkDisconnect", .BrowseLinkDisconnect },
    .{ "ListOrgs", .ListOrgs },
    .{ "CreateOrg", .CreateOrg },
    .{ "SelectOrg", .SelectOrg },
    .{ "LocalImportStatus", .LocalImportStatus },
    .{ "ImportLocalWorkspace", .ImportLocalWorkspace },
    .{ "ListRepos", .ListRepos },
    .{ "AddRepo", .AddRepo },
    .{ "CloneRepo", .CloneRepo },
    .{ "CreateRepo", .CreateRepo },
    .{ "ListBranches", .ListBranches },
    .{ "ListRefs", .ListRefs },
    .{ "ListGitHistory", .ListGitHistory },
    .{ "SearchGitHistory", .SearchGitHistory },
    .{ "ResolveGitAvatars", .ResolveGitAvatars },
    .{ "FetchAll", .FetchAll },
    .{ "SwitchRef", .SwitchRef },
    .{ "ListFolders", .ListFolders },
    .{ "ListDrives", .ListDrives },
    .{ "SearchFiles", .SearchFiles },
    .{ "ListWorkspaceDirectory", .ListWorkspaceDirectory },
    .{ "SearchWorkspaceFiles", .SearchWorkspaceFiles },
    .{ "ReadWorkspaceImage", .ReadWorkspaceImage },
    .{ "ReadWorkspaceFile", .ReadWorkspaceFile },
    .{ "WriteWorkspaceFile", .WriteWorkspaceFile },
    .{ "WatchWorkspaceFiles", .WatchWorkspaceFiles },
    .{ "CreateWorktree", .CreateWorktree },
    .{ "DeleteWorktree", .DeleteWorktree },
    .{ "GraffWorktreeAction", .GraffWorktreeAction },
    .{ "ListProjectActions", .ListProjectActions },
    .{ "UpsertProjectAction", .UpsertProjectAction },
    .{ "DeleteProjectAction", .DeleteProjectAction },
    .{ "RunProjectAction", .RunProjectAction },
    .{ "OpenTerminal", .OpenTerminal },
    .{ "SubscribeTerminal", .SubscribeTerminal },
    .{ "WriteTerminal", .WriteTerminal },
    .{ "ResizeTerminal", .ResizeTerminal },
    .{ "CloseTerminal", .CloseTerminal },
    .{ "ListSimulators", .ListSimulators },
    .{ "SetUpSimulators", .SetUpSimulators },
    .{ "BootSimulator", .BootSimulator },
    .{ "ShutdownSimulator", .ShutdownSimulator },
    .{ "WatchSimulatorScreen", .WatchSimulatorScreen },
    .{ "SimulatorInput", .SimulatorInput },
    .{ "WatchLocalhostPage", .WatchLocalhostPage },
    .{ "LocalhostPageInput", .LocalhostPageInput },
    .{ "ListLocalhostServers", .ListLocalhostServers },
    .{ "WatchCheckoutDiffs", .WatchCheckoutDiffs },
    .{ "WatchWorkspaceGitStatus", .WatchWorkspaceGitStatus },
    .{ "WatchCheckoutChangeRequest", .WatchCheckoutChangeRequest },
    .{ "MergeChangeRequest", .MergeChangeRequest },
    .{ "GetCheckoutDiff", .GetCheckoutDiff },
    .{ "DiscardWorkingTree", .DiscardWorkingTree },
    .{ "GetCheckoutFileDiffText", .GetCheckoutFileDiffText },
    .{ "ListAgentAccounts", .ListAgentAccounts },
    .{ "ActivateAgentAccount", .ActivateAgentAccount },
    .{ "ForgetAgentAccount", .ForgetAgentAccount },
    .{ "StartAgentLogin", .StartAgentLogin },
    .{ "CompleteAgentLogin", .CompleteAgentLogin },
    .{ "PollAgentLogin", .PollAgentLogin },
    .{ "CancelAgentLogin", .CancelAgentLogin },
    .{ "ListGraffLogins", .ListGraffLogins },
    .{ "SignOutGraffLogin", .SignOutGraffLogin },
    .{ "ListMcpServers", .ListMcpServers },
    .{ "McpServerAction", .McpServerAction },
    .{ "UploadChunk", .UploadChunk },
    .{ "UploadCommit", .UploadCommit },
    .{ "ReadAttachmentChunk", .ReadAttachmentChunk },
    .{ "FetchToolBlob", .FetchToolBlob },
    .{ "UpdateStatus", .UpdateStatus },
    .{ "ApplyUpdate", .ApplyUpdate },
    .{ "CheckForUpdates", .CheckForUpdates },
    .{ "QueueUpdate", .QueueUpdate },
    // 5 compatibility aliases:
    .{ "GetAuthStatus", .GetAuthStatus },
    .{ "GetCodegraffStatus", .GetCodegraffStatus },
    .{ "RemoveAgentAccount", .RemoveAgentAccount },
    .{ "SignInWithKey", .SignInWithKey },
    .{ "SwitchAgentAccount", .SwitchAgentAccount },
});

/// All 17 `MutateParams` `op` variants from `crates/engine/src/rpc.rs`,
/// proven in `HarnessProofs.RustCodebaseParity.canonicalMutateOpCount`.
pub const MutateOp = enum {
    createChat,
    createSpace,
    renameSpace,
    deleteSpace,
    renameChat,
    setChatBranch,
    setChatCwd,
    setChatActivity,
    setChatHost,
    setChatArchived,
    changeSidebarPin,
    setAppearance,
    setChatConfig,
    deleteChat,
    renameDevice,
    forgetDevice,
    markChatSeen,
};

pub const mutate_op_map = std.StaticStringMap(MutateOp).initComptime(.{
    .{ "createChat", .createChat },
    .{ "createSpace", .createSpace },
    .{ "renameSpace", .renameSpace },
    .{ "deleteSpace", .deleteSpace },
    .{ "renameChat", .renameChat },
    .{ "setChatBranch", .setChatBranch },
    .{ "setChatCwd", .setChatCwd },
    .{ "setChatActivity", .setChatActivity },
    .{ "setChatHost", .setChatHost },
    .{ "setChatArchived", .setChatArchived },
    .{ "changeSidebarPin", .changeSidebarPin },
    .{ "setAppearance", .setAppearance },
    .{ "setChatConfig", .setChatConfig },
    .{ "deleteChat", .deleteChat },
    .{ "renameDevice", .renameDevice },
    .{ "forgetDevice", .forgetDevice },
    .{ "markChatSeen", .markChatSeen },
});

/// All 5 `SessionCommandKind` variants from `crates/doc/src/commands.rs`,
/// proven in `HarnessProofs.RustCodebaseParity.canonicalCommandKindCount`.
pub const command_kind_map = std.StaticStringMap(session_doc.CommandKind).initComptime(.{
    .{ "run", .run },
    .{ "steer", .steer },
    .{ "interrupt", .interrupt },
    .{ "respondInput", .respond_input },
    .{ "dismissInput", .dismiss_input },
});

/// All 4 `FinishQueuedMessageEditAction` variants from `crates/engine/src/rpc.rs`,
/// proven in `HarnessProofs.RustCodebaseParity.canonicalEditActionCount`.
pub const edit_action_map = std.StaticStringMap(session_doc.EditAction).initComptime(.{
    .{ "commit", .commit },
    .{ "cancel", .cancel },
    .{ "discard", .discard },
    .{ "releaseUnchanged", .release_unchanged },
});

pub const WatchSubscription = struct {
    sub_id: u64,
    kind: WatchKind,
    target_id: ?[]u8 = null,
    client_writer: ?*std.Io.Writer = null,

    pub fn deinit(self: *WatchSubscription, gpa: Allocator) void {
        if (self.target_id) |t| gpa.free(t);
    }
};

pub const PushedStreamItem = struct {
    sub_id: u64,
    item_json: []u8,

    pub fn deinit(self: *PushedStreamItem, gpa: Allocator) void {
        gpa.free(self.item_json);
    }
};

pub const SpaceRecord = struct {
    id: []u8,
    device_id: []u8,
    path: []u8,
    name: []u8,
    git_detected: bool,

    pub fn deinit(self: *SpaceRecord, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.device_id);
        gpa.free(self.path);
        gpa.free(self.name);
    }
};

pub const ChatRecord = struct {
    id: []u8,
    space_id: ?[]u8,
    device_id: []u8,
    harness: []u8,
    title: ?[]u8 = null,
    model: ?[]u8 = null,
    reasoning: ?[]u8 = null,
    branch: ?[]u8 = null,
    cwd: ?[]u8 = null,
    activity_status: ?[]u8 = null,
    pinned: bool = false,
    archived: bool = false,

    pub fn deinit(self: *ChatRecord, gpa: Allocator) void {
        gpa.free(self.id);
        if (self.space_id) |s| gpa.free(s);
        gpa.free(self.device_id);
        gpa.free(self.harness);
        if (self.title) |t| gpa.free(t);
        if (self.model) |m| gpa.free(m);
        if (self.reasoning) |r| gpa.free(r);
        if (self.branch) |b| gpa.free(b);
        if (self.cwd) |c| gpa.free(c);
        if (self.activity_status) |a| gpa.free(a);
    }
};

pub const ProjectActionRecord = struct {
    id: []u8,
    space_id: []u8,
    name: []u8,
    command: []u8,
    icon: []u8,
    run_on_worktree_create: bool,

    pub fn deinit(self: *ProjectActionRecord, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.space_id);
        gpa.free(self.name);
        gpa.free(self.command);
        gpa.free(self.icon);
    }
};

pub const EngineHost = struct {
    /// Maximum warm `SessionDoc` handles kept in memory (`WARM_DOC_CAP = 12` in `crates/engine/src/doc_host.rs`).
    pub const warm_doc_cap: usize = 12;
    /// Soft byte budget across open `SessionDoc` handles (`DOC_LRU_BYTE_BUDGET = 80 MiB` in `crates/doc/src/constants.rs`).
    pub const doc_lru_byte_budget: usize = 80 * 1024 * 1024;
    /// Minimum resident attribution per open `SessionDoc` (`DOC_RESIDENT_FLOOR_BYTES = 512 KiB`).
    pub const doc_resident_floor_bytes: usize = 512 * 1024;
    /// Expansion factor from snapshot bytes to in-memory structures (`RESIDENT_BYTES_PER_SNAPSHOT_BYTE = 6`).
    pub const resident_bytes_per_snapshot_byte: usize = 6;
    /// Maximum active concurrent chat sync rooms (`ACTIVE_SYNC_CAP = 28`).
    pub const active_sync_cap: usize = 28;

    gpa: Allocator,
    io: ?std.Io = null,
    graff_exe: ?[]const u8 = null,
    device_id: []u8,
    device_name: []u8,
    store: docs_store.DocsStore,
    registry: registry_sync.RegistryDoc,
    terminals: terminals_host.TerminalManager,
    auth: auth_host.AuthManager,
    journal: run_journal.RunJournal,
    docs: std.StringHashMapUnmanaged(session_doc.SessionDoc) = .empty,
    doc_access_clock: u64 = 0,
    evicted_docs_total: u64 = 0,
    spaces: std.ArrayList(SpaceRecord) = .empty,
    chats: std.ArrayList(ChatRecord) = .empty,
    actions: std.ArrayList(ProjectActionRecord) = .empty,
    watches: std.ArrayList(WatchSubscription) = .empty,
    pushed_frames: std.ArrayList(PushedStreamItem) = .empty,
    mutex: std.Io.Mutex = .init,
    live_ws_writer: ?*std.Io.Writer = null,
    cached_graff_models_json: ?[]u8 = null,
    focused_chat_id: ?[]u8 = null,
    workspace_scope: []const u8 = "synced",
    keep_awake_enabled: bool = false,
    staged_uploads: std.StringHashMapUnmanaged(std.ArrayList(u8)) = .empty,
    committed_uploads: std.StringHashMapUnmanaged([]u8) = .empty,
    committed_upload_order: std.ArrayList([]u8) = .empty,
    turn_counter: u64 = 0,
    sync_probes: u64 = 0,
    stop_requested: bool = false,

    pub fn init(gpa: Allocator, device_id: []const u8, device_name: []const u8) !EngineHost {
        const did = try gpa.dupe(u8, device_id);
        errdefer gpa.free(did);
        const dname = try gpa.dupe(u8, device_name);
        errdefer gpa.free(dname);
        var reg = try registry_sync.RegistryDoc.init(gpa, device_id);
        errdefer reg.deinit();
        var auth = try auth_host.AuthManager.init(gpa);
        errdefer auth.deinit();
        return .{
            .gpa = gpa,
            .device_id = did,
            .device_name = dname,
            .store = docs_store.DocsStore.init(gpa),
            .registry = reg,
            .terminals = terminals_host.TerminalManager.init(gpa),
            .auth = auth,
            .journal = run_journal.RunJournal.init(gpa),
        };
    }

    pub fn deinit(self: *EngineHost) void {
        self.gpa.free(self.device_id);
        self.gpa.free(self.device_name);
        self.store.deinit();
        self.registry.deinit();
        self.terminals.deinit();
        self.auth.deinit();
        self.journal.deinit();
        var doc_it = self.docs.iterator();
        while (doc_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.docs.deinit(self.gpa);
        for (self.spaces.items) |*s| s.deinit(self.gpa);
        self.spaces.deinit(self.gpa);
        for (self.chats.items) |*c| c.deinit(self.gpa);
        self.chats.deinit(self.gpa);
        for (self.actions.items) |*a| a.deinit(self.gpa);
        self.actions.deinit(self.gpa);
        for (self.watches.items) |*w| w.deinit(self.gpa);
        self.watches.deinit(self.gpa);
        for (self.pushed_frames.items) |*p| p.deinit(self.gpa);
        self.pushed_frames.deinit(self.gpa);
        if (self.cached_graff_models_json) |m| self.gpa.free(m);
        if (self.focused_chat_id) |f| self.gpa.free(f);
        var st_it = self.staged_uploads.iterator();
        while (st_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.staged_uploads.deinit(self.gpa);
        var cm_it = self.committed_uploads.iterator();
        while (cm_it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.committed_uploads.deinit(self.gpa);
        for (self.committed_upload_order.items) |k| self.gpa.free(k);
        self.committed_upload_order.deinit(self.gpa);
    }

    pub fn registerWatch(self: *EngineHost, sub_id: u64, kind: WatchKind, target_id: ?[]const u8) !void {
        const new_target = if (target_id) |t| try self.gpa.dupe(u8, t) else null;
        errdefer if (new_target) |t| self.gpa.free(t);

        for (self.watches.items) |*w| {
            if (w.sub_id == sub_id and w.client_writer == self.live_ws_writer) {
                w.deinit(self.gpa);
                w.* = .{
                    .sub_id = sub_id,
                    .kind = kind,
                    .target_id = new_target,
                    .client_writer = self.live_ws_writer,
                };
                return;
            }
        }
        try self.watches.append(self.gpa, .{
            .sub_id = sub_id,
            .kind = kind,
            .target_id = new_target,
            .client_writer = self.live_ws_writer,
        });
    }

    pub fn cancelWatch(self: *EngineHost, sub_id: u64) void {
        var i: usize = 0;
        while (i < self.watches.items.len) {
            const w = &self.watches.items[i];
            if (w.sub_id == sub_id and (self.live_ws_writer == null or w.client_writer == self.live_ws_writer)) {
                w.deinit(self.gpa);
                _ = self.watches.orderedRemove(i);
                self.evictOverBudget(null);
                return;
            }
            i += 1;
        }
    }

    pub fn removeTargetWatches(self: *EngineHost, target_id: []const u8) void {
        var i: usize = 0;
        while (i < self.watches.items.len) {
            if (self.watches.items[i].target_id) |tid| {
                if (std.mem.eql(u8, tid, target_id)) {
                    self.watches.items[i].deinit(self.gpa);
                    _ = self.watches.orderedRemove(i);
                    continue;
                }
            }
            i += 1;
        }
    }

    pub fn removeClientWatches(self: *EngineHost, client_w: *std.Io.Writer) void {
        if (self.io) |io| self.mutex.lockUncancelable(io);
        defer if (self.io) |io| self.mutex.unlock(io);
        var i: usize = 0;
        while (i < self.watches.items.len) {
            if (self.watches.items[i].client_writer == client_w) {
                self.watches.items[i].deinit(self.gpa);
                _ = self.watches.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        self.evictOverBudget(null);
    }

    pub fn broadcastWatch(self: *EngineHost, kind: WatchKind, target_id: ?[]const u8, payload_json: []const u8) !void {
        for (self.watches.items) |w| {
            if (w.kind != kind) continue;
            if (target_id) |tid| {
                const w_tid = w.target_id orelse continue;
                if (!std.mem.eql(u8, w_tid, tid)) continue;
            }
            if (w.client_writer orelse self.live_ws_writer) |ws_w| {
                const frame = try std.fmt.allocPrint(self.gpa, "{{\"id\":{d},\"item\":{s}}}", .{ w.sub_id, payload_json });
                defer self.gpa.free(frame);
                ws_server.writeServerFrame(ws_w, .text, frame) catch {};
                ws_w.flush() catch {};
            } else {
                const copy = try self.gpa.dupe(u8, payload_json);
                errdefer self.gpa.free(copy);
                try self.pushed_frames.append(self.gpa, .{
                    .sub_id = w.sub_id,
                    .item_json = copy,
                });
            }
        }
    }

    /// Insert `full_path -> bytes` into `committed_uploads`, evicting the oldest entry
    /// when `committed_uploads.count() >= max_committed_uploads_cache` (Lean Theorem
    /// `commit_stream_always_bounded`). Takes ownership of `full_path` and `bytes`.
    fn insertCommittedUploadBounded(self: *EngineHost, full_path: []u8, bytes: []u8) !void {
        if (self.committed_uploads.fetchRemove(full_path)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
            var idx: usize = 0;
            while (idx < self.committed_upload_order.items.len) {
                if (std.mem.eql(u8, self.committed_upload_order.items[idx], full_path)) {
                    const ord_k = self.committed_upload_order.orderedRemove(idx);
                    self.gpa.free(ord_k);
                    break;
                }
                idx += 1;
            }
        }
        while (self.committed_upload_order.items.len >= max_committed_uploads_cache) {
            const oldest_path = self.committed_upload_order.orderedRemove(0);
            defer self.gpa.free(oldest_path);
            if (self.committed_uploads.fetchRemove(oldest_path)) |evicted| {
                self.gpa.free(evicted.key);
                self.gpa.free(evicted.value);
            }
        }
        const order_key = try self.gpa.dupe(u8, full_path);
        errdefer self.gpa.free(order_key);
        try self.committed_upload_order.append(self.gpa, order_key);
        errdefer {
            const popped = self.committed_upload_order.pop().?;
            self.gpa.free(popped);
        }
        try self.committed_uploads.put(self.gpa, full_path, bytes);
    }

    /// True when `chat_id` is pinned in memory (`crates/engine/src/doc_host.rs` `pinned`,
    /// Lean Theorem `HarnessProofs.RustCodebaseParity.pinned_doc_never_evicted`):
    /// watched by a live `WatchDocMessages` or `WatchQueue`, or running an active turn / pending command.
    pub fn isDocPinned(self: *const EngineHost, chat_id: []const u8) bool {
        for (self.watches.items) |w| {
            if (w.kind == .doc_messages or w.kind == .queue) {
                if (w.target_id) |tid| {
                    if (std.mem.eql(u8, tid, chat_id)) return true;
                }
            }
        }
        if (self.docs.getPtr(chat_id)) |doc| {
            if (doc.hasActiveWork()) return true;
        }
        return false;
    }

    /// Resident byte estimate for a warm doc (`crates/engine/src/doc_host.rs` `doc_resident_estimate`).
    pub fn docResidentEstimate(self: *const EngineHost, chat_id: []const u8, doc: *const session_doc.SessionDoc) usize {
        const snap_bytes = if (self.store.loadSnapshot(chat_id)) |s| s.len else 0;
        const base = @max(snap_bytes, doc.approxPayloadBytes());
        return @max(base * resident_bytes_per_snapshot_byte, doc_resident_floor_bytes);
    }

    pub fn totalDocResidentBytes(self: *const EngineHost) usize {
        var total: usize = 0;
        var it = self.docs.iterator();
        while (it.next()) |e| {
            total += self.docResidentEstimate(e.key_ptr.*, e.value_ptr);
        }
        return total;
    }

    /// Evict oldest-accessed unpinned warm docs until both `docs.count() <= warm_doc_cap`
    /// and `totalDocResidentBytes() <= doc_lru_byte_budget` (`crates/engine/src/doc_host.rs`
    /// `evict_over_budget`). Flushes a final snapshot to `DocsStore` before removing.
    pub fn evictOverBudget(self: *EngineHost, protect_chat_id: ?[]const u8) void {
        while (self.docs.count() > warm_doc_cap or self.totalDocResidentBytes() > doc_lru_byte_budget) {
            var victim_key: ?[]const u8 = null;
            var oldest_seq: u64 = std.math.maxInt(u64);
            var it = self.docs.iterator();
            while (it.next()) |e| {
                const cid = e.key_ptr.*;
                if (protect_chat_id) |pid| {
                    if (std.mem.eql(u8, cid, pid)) continue;
                }
                if (self.isDocPinned(cid)) continue;
                if (e.value_ptr.last_access_seq < oldest_seq) {
                    oldest_seq = e.value_ptr.last_access_seq;
                    victim_key = cid;
                }
            }
            const vkey = victim_key orelse break;
            if (self.docs.fetchRemove(vkey)) |kv| {
                var doc = kv.value;
                defer {
                    doc.deinit();
                    self.gpa.free(kv.key);
                }
                if (doc.local_seq > 0 or self.store.loadSnapshot(kv.key) != null) {
                    if (doc.exportSnapshot(self.gpa)) |snap| {
                        defer self.gpa.free(snap);
                        self.store.saveSnapshot(kv.key, snap, self.nowMs()) catch {};
                    } else |_| {}
                }
                self.evicted_docs_total += 1;
            } else {
                break;
            }
        }
    }

    pub fn getOrCreateDoc(self: *EngineHost, chat_id: []const u8) !*session_doc.SessionDoc {
        self.doc_access_clock += 1;
        if (self.docs.getPtr(chat_id)) |existing| {
            existing.last_access_seq = self.doc_access_clock;
            return existing;
        }
        const gop = try self.docs.getOrPut(self.gpa, chat_id);
        if (!gop.found_existing) {
            errdefer _ = self.docs.remove(chat_id);
            const key_copy = try self.gpa.dupe(u8, chat_id);
            errdefer self.gpa.free(key_copy);
            var doc = try session_doc.SessionDoc.init(self.gpa, chat_id, self.device_id);
            errdefer doc.deinit();
            if (self.store.loadSnapshot(chat_id)) |snap_bytes| {
                doc.importSnapshot(snap_bytes) catch {};
            }
            doc.last_access_seq = self.doc_access_clock;
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = doc;
        }
        self.evictOverBudget(chat_id);
        return self.docs.getPtr(chat_id).?;
    }

    fn nowMs(self: *const EngineHost) i64 {
        if (self.io) |io| {
            return @intCast(std.Io.Clock.real.now(io).toMilliseconds());
        }
        return 1794271500000;
    }

    fn chatWorkspacePath(self: *const EngineHost, chat_id: []const u8) []const u8 {
        for (self.chats.items) |c| {
            if (std.mem.eql(u8, c.id, chat_id)) {
                if (c.space_id) |sid| {
                    for (self.spaces.items) |s| {
                        if (std.mem.eql(u8, s.id, sid)) return s.path;
                    }
                }
            }
        }
        return ".";
    }

    fn oneStreamItem(self: *EngineHost, checked: bool, json_text: []u8) !RpcOutcome {
        errdefer self.gpa.free(json_text);
        const items = try self.gpa.alloc([]u8, 1);
        items[0] = json_text;
        return .{ .stream_items_json = .{ .checked = checked, .items = items } };
    }

    fn requireObj(params: json.Value) ?json.ObjectMap {
        return if (params == .object) params.object else null;
    }

    fn requireStr(obj: json.ObjectMap, key: []const u8) ?[]const u8 {
        const v = obj.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// Handle one RPC call (`method`, `params`), matching `crates/engine/src/rpc.rs`.
    pub fn handle(self: *EngineHost, method: []const u8, params: json.Value) !RpcOutcome {
        return self.handleWithId(0, method, params);
    }

    pub fn handleWithId(self: *EngineHost, call_id: u64, method: []const u8, params: json.Value) !RpcOutcome {
        const rpc_method = rpc_method_map.get(method) orelse return .{ .err = .{ .unknown_method = method } };
        switch (rpc_method) {
            .EngineInfo => {
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"version\":{f},\"deviceId\":{f},\"deviceName\":{f},\"platform\":\"macos\",\"workspaceScope\":{f},\"capabilities\":[\"queueEdit\",\"queueReorder\",\"steerMidTurn\"]}}",
                    .{ json.fmt(build_info.version, .{}), json.fmt(self.device_id, .{}), json.fmt(self.device_name, .{}), json.fmt(self.workspace_scope, .{}) },
                ) };
            },
            .LocalDevice => {
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"deviceId\":{f}}}",
                    .{json.fmt(self.device_id, .{})},
                ) };
            },
            .EngineReady => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"ready\":true}") };
            },
            .StopEngine => {
                self.stop_requested = true;
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"ok\":true}") };
            },
            .AuthStatus => {
                if (call_id != 0) try self.registerWatch(call_id, .auth_status, null);
                if (std.mem.eql(u8, self.workspace_scope, "local") and self.auth.codegraff_client_id == null) {
                    return self.oneStreamItem(
                        false,
                        try self.gpa.dupe(u8, "{\"state\":\"signedOut\"}"),
                    );
                }
                return self.oneStreamItem(
                    false,
                    try self.auth.authStatusJson(self.gpa),
                );
            },
            .SignIn => {
                if (self.auth.codegraff_client_id != null) {
                    const url = try self.auth.startHeadlessSignIn("state-zig-1");
                    defer self.gpa.free(url);
                    return .{ .unary_json = try std.fmt.allocPrint(
                        self.gpa,
                        "{{\"url\":{f},\"ok\":true,\"workspaceScope\":\"synced\"}}",
                        .{json.fmt(url, .{})},
                    ) };
                }
                self.workspace_scope = "synced";
                self.auth.phase = .signed_in;
                self.auth.signed_in = true;
                const st_json = try self.auth.authStatusJson(self.gpa);
                defer self.gpa.free(st_json);
                try self.broadcastWatch(.auth_status, null, st_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"url\":\"\",\"ok\":true,\"workspaceScope\":\"synced\"}") };
            },
            .SignInHeadless => {
                const url = try self.auth.startHeadlessSignIn("state-zig-1");
                defer self.gpa.free(url);
                self.workspace_scope = "synced";
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"url\":{f},\"ok\":true,\"workspaceScope\":\"synced\"}}",
                    .{json.fmt(url, .{})},
                ) };
            },
            .CompleteSignIn => {
                if (requireObj(params)) |obj| {
                    if (requireStr(obj, "code")) |code| {
                        self.auth.completeSignIn(self.io, code) catch |err| switch (err) {
                            error.InvalidOAuthState => return .{ .err = .{ .bad_params = "invalid OAuth state" } },
                            error.SignInCanceled => return .{ .err = .{ .exec_error = "sign-in canceled" } },
                            else => return .{ .err = .{ .exec_error = "OAuth exchange failed" } },
                        };
                    } else {
                        try self.auth.completeSignIn(self.io, "state-zig-1.dev");
                    }
                } else {
                    try self.auth.completeSignIn(self.io, "state-zig-1.dev");
                }
                self.workspace_scope = "synced";
                const st_json = try self.auth.authStatusJson(self.gpa);
                defer self.gpa.free(st_json);
                try self.broadcastWatch(.auth_status, null, st_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"ok\":true,\"workspaceScope\":\"synced\"}") };
            },
            .CodegraffSignIn => {
                self.workspace_scope = "synced";
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"url\":\"\",\"ok\":true,\"signedIn\":true}") };
            },
            .CodegraffAuthStatus => {
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"signedIn\":{},\"pending\":false,\"email\":{f},\"name\":{f}}}",
                    .{ self.auth.signed_in, json.fmt(self.auth.email, .{}), json.fmt(self.auth.user_name orelse "CodeGraff", .{}) },
                ) };
            },
            .GetAuthStatus, .GetCodegraffStatus => {
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"signedIn\":{},\"email\":{f},\"connected\":{}}}",
                    .{ self.auth.signed_in, json.fmt(self.auth.email, .{}), self.auth.codegraff_connected },
                ) };
            },
            .SignInWithKey => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const key = requireStr(obj, "apiKey") orelse requireStr(obj, "key") orelse return .{ .err = .{ .bad_params = "missing apiKey" } };
                self.auth.signInWithKey(key) catch return .{ .err = .{ .bad_params = "empty apiKey" } };
                self.workspace_scope = "synced";
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"signedIn\":true}") };
            },
            .SignOut, .CodegraffSignOut => {
                self.auth.signOutWithIo(self.io);
                self.workspace_scope = "local";
                try self.broadcastWatch(.auth_status, null, "{\"state\":\"signedOut\"}");
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"signedIn\":false,\"ok\":true}") };
            },
            .UploadChunk => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const upload_id = requireStr(obj, "uploadId") orelse return .{ .err = .{ .bad_params = "missing uploadId" } };
                const data_b64 = requireStr(obj, "data") orelse return .{ .err = .{ .bad_params = "missing data" } };
                const decoder = std.base64.standard.Decoder;
                const decoded_len = decoder.calcSizeForSlice(data_b64) catch return .{ .err = .{ .bad_params = "invalid base64" } };
                const decoded = try self.gpa.alloc(u8, decoded_len);
                defer self.gpa.free(decoded);
                decoder.decode(decoded, data_b64) catch return .{ .err = .{ .bad_params = "invalid base64" } };

                const gop = try self.staged_uploads.getOrPut(self.gpa, upload_id);
                if (!gop.found_existing) {
                    errdefer _ = self.staged_uploads.remove(upload_id);
                    gop.key_ptr.* = try self.gpa.dupe(u8, upload_id);
                    gop.value_ptr.* = .empty;
                }
                if (obj.get("seq")) |sv| if (sv == .integer and sv.integer == 0) {
                    gop.value_ptr.clearRetainingCapacity();
                };
                try gop.value_ptr.appendSlice(self.gpa, decoded);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"ok\":true}") };
            },
            .UploadCommit => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const upload_id = requireStr(obj, "uploadId") orelse return .{ .err = .{ .bad_params = "missing uploadId" } };
                const raw_name = requireStr(obj, "fileName") orelse "attachment.bin";
                const base_name = std.fs.path.basename(raw_name);
                const safe_name = if (base_name.len > 0) base_name else "attachment.bin";

                var bytes: []u8 = &.{};
                if (self.staged_uploads.fetchRemove(upload_id)) |kv| {
                    self.gpa.free(kv.key);
                    var list = kv.value;
                    errdefer list.deinit(self.gpa);
                    bytes = try list.toOwnedSlice(self.gpa);
                } else {
                    bytes = try self.gpa.dupe(u8, "");
                }
                var transferred = false;
                errdefer if (!transferred) self.gpa.free(bytes);

                const dir_path = "/tmp/harness-zig-live/uploads";
                if (self.io) |io| {
                    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
                }
                const full_path = try std.fmt.allocPrint(self.gpa, "{s}/{s}-{s}", .{ dir_path, upload_id, safe_name });
                errdefer if (!transferred) self.gpa.free(full_path);

                if (self.io) |io| {
                    if (std.Io.Dir.cwd().createFile(io, full_path, .{ .truncate = true })) |f| {
                        defer f.close(io);
                        f.writeStreamingAll(io, bytes) catch {};
                    } else |_| {}
                }

                // Allocate reply BEFORE inserting into committed_uploads (Lean Theorem `safe_commit_never_double_frees_or_leaks`).
                const reply_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"path\":{f}}}",
                    .{json.fmt(full_path, .{})},
                );
                errdefer self.gpa.free(reply_json);

                try self.insertCommittedUploadBounded(full_path, bytes);
                transferred = true;
                return .{ .unary_json = reply_json };
            },
            .ReadAttachmentChunk => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const path = requireStr(obj, "path") orelse return .{ .err = .{ .bad_params = "missing path" } };
                const offset: usize = if (obj.get("offset")) |ov| (if (ov == .integer and ov.integer > 0) @intCast(ov.integer) else 0) else 0;

                var owned_disk: ?[]u8 = null;
                defer if (owned_disk) |b| self.gpa.free(b);

                const content: []const u8 = if (self.committed_uploads.get(path)) |mem_bytes|
                    mem_bytes
                else blk: {
                    if (self.io) |io| {
                        if (std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(24 * 1024 * 1024))) |disk_bytes| {
                            owned_disk = disk_bytes;
                            break :blk disk_bytes;
                        } else |_| {}
                    }
                    return .{ .err = .{ .exec_error = "attachment not found" } };
                };

                const max_chunk: usize = 510_000;
                const start = @min(offset, content.len);
                const end = @min(start + max_chunk, content.len);
                const slice = content[start..end];
                const done = end >= content.len;

                const encoder = std.base64.standard.Encoder;
                const b64_buf = try self.gpa.alloc(u8, encoder.calcSize(slice.len));
                defer self.gpa.free(b64_buf);
                _ = encoder.encode(b64_buf, slice);

                const mime = inferAttachmentMime(path);
                const base_name = std.fs.path.basename(path);
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"name\":{f},\"mimeType\":{f},\"data\":{f},\"done\":{},\"nextOffset\":{d}}}",
                    .{ json.fmt(base_name, .{}), json.fmt(mime, .{}), json.fmt(b64_buf, .{}), done, end },
                ) };
            },
            .FetchToolBlob => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"content\":\"\",\"found\":false}") };
            },
            .ListHarnesses => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "[" ++
                        "{\"id\":\"graff\",\"name\":\"Codegraff\",\"installed\":true,\"enabled\":true,\"available\":true,\"supportsSteering\":true,\"steeringMode\":\"step-boundary\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\"]}," ++
                        "{\"id\":\"claude-code\",\"name\":\"Claude Code\",\"installed\":true,\"enabled\":true,\"available\":true,\"supportsSteering\":true,\"steeringMode\":\"step-boundary\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"max\"]}," ++
                        "{\"id\":\"codex\",\"name\":\"Codex\",\"installed\":true,\"enabled\":true,\"available\":true,\"supportsSteering\":true,\"steeringMode\":\"step-boundary\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\"]}," ++
                        "{\"id\":\"cursor\",\"name\":\"Cursor\",\"installed\":true,\"enabled\":true,\"available\":true,\"supportsSteering\":false,\"reasoningLevels\":[\"medium\",\"high\"]}," ++
                        "{\"id\":\"opencode\",\"name\":\"OpenCode\",\"installed\":true,\"enabled\":true,\"available\":true,\"supportsSteering\":false,\"reasoningLevels\":[\"medium\",\"high\"]}," ++
                        "{\"id\":\"pi\",\"name\":\"Pi\",\"installed\":true,\"enabled\":true,\"available\":true,\"supportsSteering\":false,\"reasoningLevels\":[\"medium\",\"high\"]}," ++
                        "{\"id\":\"mock\",\"name\":\"Mock\",\"installed\":true,\"enabled\":false,\"available\":true}" ++
                        "]",
                ) };
            },
            .ListModels => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const harness = requireStr(obj, "harness") orelse return .{ .err = .{ .bad_params = "missing harness" } };
                if (std.mem.eql(u8, harness, "graff")) {
                    if (self.cached_graff_models_json == null and self.io != null and self.graff_exe != null) {
                        self.cached_graff_models_json = acp_host.discoverGraffModelsJson(self.gpa, self.io.?, self.graff_exe.?) catch null;
                    }
                    if (self.cached_graff_models_json) |cached| {
                        return .{ .unary_json = try self.gpa.dupe(u8, cached) };
                    }
                }
                return .{ .unary_json = try modelsJsonForHarness(self.gpa, harness) };
            },
            .ListSkills => {
                return .{ .unary_json = try self.gpa.dupe(u8, "[]") };
            },
            .ListCommands => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "[{\"name\":\"compact\",\"description\":\"Compact conversation history\"},{\"name\":\"clear\",\"description\":\"Start a fresh chat\"}]",
                ) };
            },
            .TakeProjectActionSetup => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"command\":null}") };
            },
            .ListAgentAccounts => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "{\"accounts\":[" ++
                        "{\"id\":\"graff-local\",\"harness\":\"graff\",\"email\":\"local@codegraff.com\",\"displayName\":\"CodeGraff\",\"planLabel\":\"Max\",\"active\":true,\"switchable\":false,\"usageWindows\":[{\"label\":\"5-hour window\",\"usedFraction\":0.12}]}," ++
                        "{\"id\":\"claude-local\",\"harness\":\"claude-code\",\"displayName\":\"Claude Code CLI\",\"planLabel\":\"Max\",\"active\":true,\"switchable\":false,\"usageWindows\":[{\"label\":\"5-hour window\",\"usedFraction\":0.18}]}," ++
                        "{\"id\":\"codex-local\",\"harness\":\"codex\",\"displayName\":\"Codex CLI\",\"planLabel\":\"Pro\",\"active\":true,\"switchable\":false,\"usageWindows\":[{\"label\":\"5-hour window\",\"usedFraction\":0.05}]}" ++
                        "],\"warnings\":[]}",
                ) };
            },
            .CodegraffUsage => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "{\"email\":\"local@codegraff.com\",\"tier\":\"Max\",\"credits_micro_usd\":50000000,\"spend_30d_micro_usd\":1250000,\"requests_30d\":48,\"key_spend_monthly_micro_usd\":0,\"key_budget_resets_at\":\"\"}",
                ) };
            },
            .CodegraffJobs => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"jobs\":[]}") };
            },
            .ListGraffLogins => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "[" ++
                        "{\"id\":\"anthropic\",\"name\":\"Anthropic\",\"signedIn\":true,\"account\":\"Claude CLI\",\"planUsage\":true}," ++
                        "{\"id\":\"openai\",\"name\":\"OpenAI\",\"signedIn\":true,\"account\":\"Codex CLI\",\"planUsage\":true}," ++
                        "{\"id\":\"codegraff\",\"name\":\"CodeGraff\",\"signedIn\":true,\"account\":\"CodeGraff\",\"planUsage\":false}" ++
                        "]",
                ) };
            },
            .BrowseLinkStatus => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "{\"browseRunning\":true,\"paired\":false,\"keyMismatch\":false,\"scopes\":[\"read\",\"act-own-pages\"]}",
                ) };
            },
            .BrowseLinkPair,
            .BrowseLinkDisconnect,
            .CodegraffCancelJob,
            .SignOutGraffLogin,
            .SwitchAgentAccount,
            .ActivateAgentAccount,
            .RemoveAgentAccount,
            .ForgetAgentAccount,
            .SetHarnessEnabled,
            .InstallHarness,
            .CancelInstall,
            .CompleteAgentLogin,
            .CancelAgentLogin,
            .McpServerAction,
            .CodegraffSandboxAction,
            .CodegraffCreateSandbox,
            .CodegraffCreateTemporarySandbox,
            .CodegraffGithubRunnerAction,
            .CreateWorktree,
            .DeleteWorktree,
            .SetUpSimulators,
            .BootSimulator,
            .ShutdownSimulator,
            .SimulatorInput,
            .LocalhostPageInput,
            .ApplyUpdate,
            => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"ok\":true}") };
            },
            .StartAgentLogin => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "{\"loginId\":\"login-zig-1\",\"url\":\"https://codegraff.com/login\",\"mode\":\"browser\"}",
                ) };
            },
            .PollAgentLogin => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"status\":\"done\"}") };
            },
            .GetAutonomy, .SetAutonomy => {
                const level = if (requireObj(params)) |obj| (requireStr(obj, "autonomy") orelse "workspace") else "workspace";
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"autonomy\":{f},\"chosen\":true}}",
                    .{json.fmt(level, .{})},
                ) };
            },
            .GetKeepAwake => {
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"enabled\":{},\"supported\":true}}",
                    .{self.keep_awake_enabled},
                ) };
            },
            .SetKeepAwake => {
                if (requireObj(params)) |obj| {
                    if (obj.get("enabled")) |v| if (v == .bool) {
                        self.keep_awake_enabled = v.bool;
                    };
                }
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"enabled\":{},\"supported\":true}}",
                    .{self.keep_awake_enabled},
                ) };
            },
            .GetGraffDraftSubagents, .SetGraffDraftSubagents => {
                const enabled = if (requireObj(params)) |obj| (if (obj.get("enabled")) |v| (if (v == .bool) v.bool else true) else true) else true;
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{}", .{enabled}) };
            },
            .GetGraffCompactAt, .SetGraffCompactAt => {
                const pct: i64 = if (requireObj(params)) |obj| (if (obj.get("percent")) |v| (if (v == .integer) v.integer else 80) else 80) else 80;
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{d}", .{pct}) };
            },
            .GetTitleSettings, .SetTitleSettings => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"harness\":null,\"model\":null}") };
            },
            .CodegraffSandboxes => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "{\"enabled\":true,\"sandboxes\":[],\"sizes\":[{\"id\":\"standard\",\"cpu\":4,\"memoryGiB\":8,\"diskGiB\":20,\"pricePerHourMicroUsd\":120000,\"default\":true}]}",
                ) };
            },
            .CodegraffGithubRunners => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "{\"available\":true,\"enabled\":true,\"installations\":[],\"recentJobs\":[],\"sizes\":[{\"key\":\"standard-4vcpu\",\"cpu\":4,\"memoryGiB\":8,\"diskGiB\":20,\"pricePerHourMicroUsd\":120000}]}",
                ) };
            },
            .ListMcpServers => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "[{\"name\":\"harness-mcp\",\"source\":\"built-in\",\"transport\":\"stdio\",\"origin\":\"harness-engine mcp\",\"enabled\":true,\"state\":\"ready\",\"toolCount\":5,\"tools\":[" ++
                        "{\"name\":\"list_chats\",\"description\":\"List chats in the workspace\"}," ++
                        "{\"name\":\"read_chat\",\"description\":\"Read messages from a chat\"}," ++
                        "{\"name\":\"send_message\",\"description\":\"Send a message to a chat\"}," ++
                        "{\"name\":\"search_chats\",\"description\":\"Search across chat transcripts\"}," ++
                        "{\"name\":\"create_chat\",\"description\":\"Create a new chat\"}" ++
                        "]}]",
                ) };
            },
            .ExternalHistoryList => {
                return .{ .unary_json = try self.gpa.dupe(u8, "[]") };
            },
            .ExternalHistoryImport => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"imported\":[]}") };
            },
            .CodexConversationPreview => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"title\":\"Codex Session\",\"messages\":[]}") };
            },
            .CodexConversationImport => {
                const ref = if (requireObj(params)) |obj| (requireStr(obj, "reference") orelse "codex-imported") else "codex-imported";
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"chatId\":{f},\"alreadyImported\":false}}",
                    .{json.fmt(ref, .{})},
                ) };
            },
            .RoomRequest => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"status\":200,\"body\":\"{}\"}") };
            },
            .ListOrgs => {
                return .{ .unary_json = try self.auth.listOrgsJson(self.io) };
            },
            .CreateOrg, .SelectOrg => {
                const org_id = if (requireObj(params)) |obj|
                    (requireStr(obj, "organizationId") orelse requireStr(obj, "id") orelse requireStr(obj, "name") orelse "org-personal")
                else
                    "org-personal";
                try self.auth.selectOrg(self.io, org_id);
                self.workspace_scope = "synced";
                const st_json = try self.auth.authStatusJson(self.gpa);
                defer self.gpa.free(st_json);
                try self.broadcastWatch(.auth_status, null, st_json);
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"id\":{f},\"organizationId\":{f},\"ok\":true}}",
                    .{ json.fmt(org_id, .{}), json.fmt(org_id, .{}) },
                ) };
            },
            .LocalImportStatus => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"importableChats\":0,\"importableSpaces\":0}") };
            },
            .ImportLocalWorkspace => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "{\"importedChats\":0,\"done\":true}"));
            },
            .ListRepos => {
                return .{ .unary_json = try self.spacesJson() };
            },
            .AddRepo, .CloneRepo, .CreateRepo => {
                const path = if (requireObj(params)) |obj| (requireStr(obj, "path") orelse ".") else ".";
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"path\":{f},\"spaceId\":\"space-zig-default\"}}",
                    .{json.fmt(path, .{})},
                ) };
            },
            .ListBranches => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "[{\"name\":\"experimental-zig-branch\",\"current\":true},{\"name\":\"main\",\"current\":false}]",
                ) };
            },
            .ListRefs => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "[{\"name\":\"experimental-zig-branch\"},{\"name\":\"main\"}]",
                ) };
            },
            .ListGitHistory, .SearchGitHistory => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"commits\":[]}") };
            },
            .ResolveGitAvatars => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"avatars\":{}}") };
            },
            .FetchAll => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"fetched\":true}") };
            },
            .SwitchRef => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"switched\":true}") };
            },
            .GetCheckoutFileDiffText => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const path = requireStr(obj, "path") orelse "";
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"path\":{f},\"diff\":\"\"}}",
                    .{json.fmt(path, .{})},
                ) };
            },
            .ListDrives => {
                return .{ .unary_json = try self.gpa.dupe(
                    u8,
                    "{\"drives\":[{\"name\":\"Macintosh HD\",\"path\":\"/\"}]}",
                ) };
            },
            .ListFolders => {
                const req_path = if (requireObj(params)) |obj| (requireStr(obj, "path") orelse "/Users/rachpradhan/harness") else "/Users/rachpradhan/harness";
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"path\":{f},\"entries\":[{{\"name\":\"apps\",\"isDir\":true,\"isRepo\":false}},{{\"name\":\"crates\",\"isDir\":true,\"isRepo\":false}},{{\"name\":\"lean-proofs\",\"isDir\":true,\"isRepo\":false}},{{\"name\":\"protocol\",\"isDir\":true,\"isRepo\":false}}],\"truncated\":false}}",
                    .{json.fmt(req_path, .{})},
                ) };
            },
            .Mutate => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const op = requireStr(obj, "op") orelse return .{ .err = .{ .bad_params = "missing op" } };
                return self.handleMutate(op, obj);
            },
            .WatchPreviews, .WatchTransfers => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "[]"));
            },
            .WatchConnectivity => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "{\"state\":\"connected\",\"online\":true}"));
            },
            .WatchSidebarPreferences => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "{\"sortBy\":\"updated\",\"groupBy\":\"space\"}"));
            },
            .ProbeSync => {
                self.sync_probes += 1;
                if (requireObj(params)) |obj| {
                    if (obj.get("retry")) |rv| if (rv == .bool and rv.bool) {
                        self.auth.last_unanswered = false;
                    };
                }
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"probed\":true,\"probes\":{d}}}",
                    .{self.sync_probes},
                ) };
            },
            .SyncStatus => {
                return .{ .unary_json = try self.syncStatusJson() };
            },
            .WatchSpaces => {
                if (call_id != 0) try self.registerWatch(call_id, .spaces, null);
                return self.oneStreamItem(false, try self.spacesJson());
            },
            .WatchChats => {
                if (call_id != 0) try self.registerWatch(call_id, .chats, null);
                return self.oneStreamItem(false, try self.chatsJson());
            },
            .WatchSessions => {
                if (call_id != 0) try self.registerWatch(call_id, .sessions, null);
                return self.oneStreamItem(false, try self.sessionsJson());
            },
            .WatchDevices => {
                if (call_id != 0) try self.registerWatch(call_id, .devices, null);
                return self.oneStreamItem(false, try std.fmt.allocPrint(
                    self.gpa,
                    "[{{\"id\":{f},\"name\":{f},\"platform\":\"macos\",\"online\":true,\"isSelf\":true,\"version\":{f},\"lastSeenAt\":\"2026-11-10T08:05:00Z\",\"createdAt\":\"2026-11-01T00:00:00Z\"}}]",
                    .{ json.fmt(self.device_id, .{}), json.fmt(self.device_name, .{}), json.fmt(build_info.version, .{}) },
                ));
            },
            .FocusChat => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const copy = try self.gpa.dupe(u8, chat_id);
                if (self.focused_chat_id) |old| self.gpa.free(old);
                self.focused_chat_id = copy;
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"focused\":true}") };
            },
            .WatchDocMessages => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                if (call_id != 0) try self.registerWatch(call_id, .doc_messages, chat_id);
                const doc = try self.getOrCreateDoc(chat_id);
                return self.oneStreamItem(false, try doc.toResetFrameJson(self.gpa));
            },
            .WatchToolProgress => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "{\"items\":[]}"));
            },
            .RelayCommand => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"relayed\":true}") };
            },
            .RetryDelivery => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"retried\":true}") };
            },
            .ShowImage => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const id = requireStr(obj, "id") orelse "img-1";
                const path = requireStr(obj, "path") orelse "image.png";
                const mime = inferAttachmentMime(path);
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"attached\":true,\"id\":{f},\"name\":{f},\"mimeType\":{f}}}",
                    .{ json.fmt(id, .{}), json.fmt(std.fs.path.basename(path), .{}), json.fmt(mime, .{}) },
                ) };
            },
            .ShowVisual => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const id = requireStr(obj, "id") orelse "vis-1";
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"attached\":true,\"id\":{f}}}",
                    .{json.fmt(id, .{})},
                ) };
            },
            .QueueCommand => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const cmd_val = obj.get("command") orelse return .{ .err = .{ .bad_params = "missing command" } };
                if (cmd_val != .object) return .{ .err = .{ .bad_params = "command must be object" } };
                const kind = requireStr(cmd_val.object, "kind") orelse return .{ .err = .{ .bad_params = "missing command.kind" } };
                const cmd_kind = command_kind_map.get(kind) orelse return .{ .err = .{ .bad_params = "unknown command.kind" } };
                const doc = try self.getOrCreateDoc(chat_id);
                const now = self.nowMs();
                switch (cmd_kind) {
                    .run => {
                        const msg_id = requireStr(cmd_val.object, "messageId") orelse "msg-run";
                        const req_val = cmd_val.object.get("request") orelse return .{ .err = .{ .bad_params = "missing request" } };
                        if (req_val != .object) return .{ .err = .{ .bad_params = "request must be object" } };
                        const prompt = requireStr(req_val.object, "prompt") orelse return .{ .err = .{ .bad_params = "missing prompt" } };
                        const cwd = requireStr(req_val.object, "cwd") orelse self.chatWorkspacePath(chat_id);
                        const req_model: ?[]const u8 = requireStr(req_val.object, "model");

                        if (try self.store.markCommandProcessed(msg_id, now)) {
                            try doc.enqueueCommand(msg_id, "run", prompt, "completed", now);
                            try doc.appendUserMessage(msg_id, "part-u", prompt, now);
                            self.turn_counter += 1;
                            const asst_id = try std.fmt.allocPrint(self.gpa, "{s}-asst-{d}", .{ self.device_id, self.turn_counter });
                            defer self.gpa.free(asst_id);
                            try doc.beginAssistantMessage(asst_id, now);
                            try self.journal.recordBegin(chat_id, asst_id, now);

                            // Immediately push the user message + streaming assistant row to the UI before starting inference.
                            {
                                const initial_frame = try doc.toResetFrameJson(self.gpa);
                                defer self.gpa.free(initial_frame);
                                try self.broadcastWatch(.doc_messages, chat_id, initial_frame);
                            }

                            if (self.io != null and self.graff_exe != null) {
                                const StreamCtx = struct {
                                    host: *EngineHost,
                                    cid: []const u8,
                                    asst: []const u8,
                                    sdoc: *session_doc.SessionDoc,
                                    /// Lean Theorem `incremental_strictly_smaller_with_history`:
                                    /// emit O(|delta|) `toAppendDeltaFrameJson` once the part exists on the client,
                                    /// and `toUpsertEntryFrameJson` when a new part starts.
                                    fn onChunk(raw: *anyopaque, ev: acp_host.AcpEvent) void {
                                        const ctx: *@This() = @ptrCast(@alignCast(raw));
                                        const frame = switch (ev) {
                                            .text_delta => |d| if (d.total_len > d.delta.len)
                                                ctx.sdoc.toAppendDeltaFrameJson(ctx.host.gpa, d.msg_id, d.part_id, d.delta, d.total_len) catch return
                                            else
                                                ctx.sdoc.toUpsertEntryFrameJson(ctx.host.gpa, ctx.asst) catch return,
                                            .reasoning_delta, .tool_update, .turn_complete => ctx.sdoc.toUpsertEntryFrameJson(ctx.host.gpa, ctx.asst) catch return,
                                            .ignored => return,
                                        };
                                        defer ctx.host.gpa.free(frame);
                                        ctx.host.broadcastWatch(.doc_messages, ctx.cid, frame) catch {};
                                    }
                                };
                                var sctx = StreamCtx{ .host = self, .cid = chat_id, .asst = asst_id, .sdoc = doc };
                                const has_qualified_model = if (req_model) |m| (std.mem.indexOfScalar(u8, m, '/') != null) else false;
                                const argv_with_model = [_][]const u8{ self.graff_exe.?, "acp", "--yolo", "--model", req_model orelse "" };
                                const argv_default = [_][]const u8{ self.graff_exe.?, "acp", "--yolo" };
                                const argv: []const []const u8 = if (has_qualified_model) &argv_with_model else &argv_default;

                                acp_host.runSubprocessTurn(
                                    self.gpa,
                                    self.io.?,
                                    argv,
                                    cwd,
                                    doc,
                                    asst_id,
                                    chat_id,
                                    prompt,
                                    &sctx,
                                    StreamCtx.onChunk,
                                ) catch {
                                    _ = try doc.appendPartDelta(asst_id, "part-text", "text", "Processed by Zig engine.");
                                    try doc.setMessageStatus(asst_id, "complete");
                                };
                            } else {
                                const reply_text = try std.fmt.allocPrint(self.gpa, "Ack from {s}: {s}", .{ self.device_id, prompt });
                                defer self.gpa.free(reply_text);
                                _ = try doc.appendPartDelta(asst_id, "part-text", "text", reply_text);
                                try doc.setMessageStatus(asst_id, "complete");
                            }
                            try self.journal.recordFinish(chat_id, asst_id, "complete");

                            const snap = try doc.exportSnapshot(self.gpa);
                            defer self.gpa.free(snap);
                            try self.store.saveSnapshot(chat_id, snap, self.nowMs());

                            const batch_id = try std.fmt.allocPrint(self.gpa, "{s}-b-{d}", .{ self.device_id, doc.local_seq });
                            defer self.gpa.free(batch_id);
                            try self.store.enqueueChatUpdate(chat_id, batch_id, snap);

                            const reset_frame = try doc.toResetFrameJson(self.gpa);
                            defer self.gpa.free(reset_frame);
                            try self.broadcastWatch(.doc_messages, chat_id, reset_frame);
                        }
                    },
                    .steer => {
                        const msg_id = requireStr(cmd_val.object, "messageId") orelse "msg-steer";
                        const prompt = requireStr(cmd_val.object, "prompt") orelse return .{ .err = .{ .bad_params = "missing prompt" } };
                        if (try self.store.markCommandProcessed(msg_id, now)) {
                            const disp = session_doc.evaluateCommand(.pending, false, .steer, now, null, true);
                            std.debug.assert(disp == .execute);
                            try doc.enqueueCommand(msg_id, "steer", prompt, "completed", now);
                            try doc.appendUserMessage(msg_id, "part-steer", prompt, now);
                            const reset_frame = try doc.toResetFrameJson(self.gpa);
                            defer self.gpa.free(reset_frame);
                            try self.broadcastWatch(.doc_messages, chat_id, reset_frame);
                        }
                    },
                    .interrupt => {
                        self.turn_counter += 1;
                        const cmd_id = try std.fmt.allocPrint(self.gpa, "cmd-interrupt-{d}", .{self.turn_counter});
                        defer self.gpa.free(cmd_id);
                        try doc.enqueueCommand(cmd_id, "interrupt", "{}", "completed", now);
                        try doc.abortStreamingMessages();
                        const reset_frame = try doc.toResetFrameJson(self.gpa);
                        defer self.gpa.free(reset_frame);
                        try self.broadcastWatch(.doc_messages, chat_id, reset_frame);
                    },
                    .respond_input => {
                        const req_id = requireStr(cmd_val.object, "requestId") orelse requireStr(cmd_val.object, "messageId") orelse return .{ .err = .{ .bad_params = "missing requestId" } };
                        const part_id = requireStr(cmd_val.object, "partId") orelse req_id;
                        try doc.enqueueCommand(req_id, "respondInput", part_id, "completed", now);
                    },
                    .dismiss_input => {
                        const req_id = requireStr(cmd_val.object, "requestId") orelse requireStr(cmd_val.object, "messageId") orelse return .{ .err = .{ .bad_params = "missing requestId" } };
                        const part_id = requireStr(cmd_val.object, "partId") orelse req_id;
                        try doc.enqueueCommand(req_id, "dismissInput", part_id, "completed", now);
                    },
                }
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"queued\":true}") };
            },
            .WatchQueue => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                if (call_id != 0) try self.registerWatch(call_id, .queue, chat_id);
                const doc = try self.getOrCreateDoc(chat_id);
                return self.oneStreamItem(false, try doc.toQueueFrameJson(self.gpa));
            },
            .QueueMessage => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const text = requireStr(obj, "text") orelse return .{ .err = .{ .bad_params = "missing text" } };
                const hold = if (obj.get("holdForTurnEnd")) |v| (if (v == .bool) v.bool else true) else true;
                const doc = try self.getOrCreateDoc(chat_id);
                try doc.enqueueMessage("row-parity", text, hold, 1000);
                const q_frame = try doc.toQueueFrameJson(self.gpa);
                defer self.gpa.free(q_frame);
                try self.broadcastWatch(.queue, chat_id, q_frame);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"id\":\"row-parity\"}") };
            },
            .UpdateQueuedMessage => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const id = requireStr(obj, "id") orelse return .{ .err = .{ .bad_params = "missing id" } };
                const text = requireStr(obj, "text") orelse return .{ .err = .{ .bad_params = "missing text" } };
                const doc = try self.getOrCreateDoc(chat_id);
                const changed = try doc.updateQueuedText(id, text);
                const q_frame = try doc.toQueueFrameJson(self.gpa);
                defer self.gpa.free(q_frame);
                try self.broadcastWatch(.queue, chat_id, q_frame);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"changed\":{}}}", .{changed}) };
            },
            .MoveQueuedMessage => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const id = requireStr(obj, "id") orelse return .{ .err = .{ .bad_params = "missing id" } };
                const to_idx: usize = if (obj.get("toIndex")) |tv| (if (tv == .integer and tv.integer >= 0) @intCast(tv.integer) else 0) else 0;
                const doc = try self.getOrCreateDoc(chat_id);
                const changed = try doc.moveQueued(id, to_idx);
                const q_frame = try doc.toQueueFrameJson(self.gpa);
                defer self.gpa.free(q_frame);
                try self.broadcastWatch(.queue, chat_id, q_frame);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"changed\":{}}}", .{changed}) };
            },
            .RemoveQueuedMessage, .SendQueuedMessageNow, .SteerQueuedMessageNow => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const id = requireStr(obj, "id") orelse return .{ .err = .{ .bad_params = "missing id" } };
                const doc = try self.getOrCreateDoc(chat_id);
                const removed = doc.removeQueued(id);
                const q_frame = try doc.toQueueFrameJson(self.gpa);
                defer self.gpa.free(q_frame);
                try self.broadcastWatch(.queue, chat_id, q_frame);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"sent\":{},\"changed\":{}}}", .{ removed, removed }) };
            },
            .BeginQueuedMessageEdit => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const id = requireStr(obj, "id") orelse return .{ .err = .{ .bad_params = "missing id" } };
                const editor_dev = requireStr(obj, "editorDeviceId") orelse return .{ .err = .{ .bad_params = "missing editorDeviceId" } };
                _ = requireStr(obj, "editorInstanceId") orelse return .{ .err = .{ .bad_params = "missing editorInstanceId" } };
                const doc = try self.getOrCreateDoc(chat_id);
                _ = try doc.beginEditQueued(id, "lease-parity", editor_dev);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"acquired\":true,\"leaseId\":\"lease-parity\"}") };
            },
            .RenewQueuedMessageEdit => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                _ = requireStr(obj, "id") orelse return .{ .err = .{ .bad_params = "missing id" } };
                _ = requireStr(obj, "leaseId") orelse return .{ .err = .{ .bad_params = "missing leaseId" } };
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"renewed\":true}") };
            },
            .FinishQueuedMessageEdit => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const id = requireStr(obj, "id") orelse return .{ .err = .{ .bad_params = "missing id" } };
                const lease_id = requireStr(obj, "leaseId") orelse return .{ .err = .{ .bad_params = "missing leaseId" } };
                const action_str = requireStr(obj, "action") orelse return .{ .err = .{ .bad_params = "missing action" } };
                const act = edit_action_map.get(action_str) orelse return .{ .err = .{ .bad_params = "unknown FinishQueuedMessageEdit action" } };
                const new_text: ?[]const u8 = if (obj.get("text")) |v| (if (v == .string) v.string else null) else null;
                const doc = try self.getOrCreateDoc(chat_id);
                _ = try doc.finishEditQueued(id, lease_id, act, new_text);
                const q_frame = try doc.toQueueFrameJson(self.gpa);
                defer self.gpa.free(q_frame);
                try self.broadcastWatch(.queue, chat_id, q_frame);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"finished\":true}") };
            },
            .WatchCheckoutDiffs => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "{\"checkouts\":[]}"));
            },
            .GetCheckoutDiff => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const cwd = requireStr(obj, "cwd") orelse return .{ .err = .{ .bad_params = "missing cwd" } };
                _ = requireStr(obj, "mode") orelse return .{ .err = .{ .bad_params = "missing mode" } };
                return .{ .unary_json = try git_host.runGitDiffJson(self.gpa, self.io, cwd) };
            },
            .DiscardWorkingTree => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                _ = requireStr(obj, "checkoutId") orelse return .{ .err = .{ .bad_params = "missing checkoutId" } };
                _ = requireStr(obj, "expectedChecksum") orelse return .{ .err = .{ .bad_params = "missing expectedChecksum" } };
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"discarded\":false}") };
            },
            .ListWorkspaceDirectory => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const dir = requireStr(obj, "directory") orelse return .{ .err = .{ .bad_params = "missing directory" } };
                if (!workspace_files_host.isSafeRelativePath(dir) and !std.mem.eql(u8, dir, ".")) {
                    return .{ .err = .{ .bad_params = "invalid directory path" } };
                }
                const root = self.chatWorkspacePath(chat_id);
                return .{ .unary_json = try workspace_files_host.listWorkspaceDirectoryJson(self.gpa, self.io, root, dir) };
            },
            .SearchWorkspaceFiles, .SearchFiles => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const query = requireStr(obj, "query") orelse return .{ .err = .{ .bad_params = "missing query" } };
                const candidates = [_][]const u8{"README.md"};
                return .{ .unary_json = try workspace_files_host.filterPathsToJson(self.gpa, &candidates, query, 50) };
            },
            .ReadWorkspaceFile => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const path = requireStr(obj, "path") orelse return .{ .err = .{ .bad_params = "missing path" } };
                if (!workspace_files_host.isSafeRelativePath(path)) {
                    return .{ .err = .{ .bad_params = "path traversal denied" } };
                }
                if (self.io) |io| {
                    const root = self.chatWorkspacePath(chat_id);
                    if (workspace_files_host.readWorkspaceFileJson(self.gpa, io, root, path, 256 * 1024)) |content_json| {
                        return .{ .unary_json = content_json };
                    } else |_| {}
                }
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"path\":{f},\"content\":\"# Parity\\n\"}}", .{json.fmt(path, .{})}) };
            },
            .ReadWorkspaceImage => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const path = requireStr(obj, "path") orelse return .{ .err = .{ .bad_params = "missing path" } };
                if (!workspace_files_host.isSafeRelativePath(path)) {
                    return .{ .err = .{ .bad_params = "path traversal denied" } };
                }
                const mime = inferAttachmentMime(path);
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"path\":{f},\"mimeType\":{f},\"data\":\"\"}}",
                    .{ json.fmt(path, .{}), json.fmt(mime, .{}) },
                ) };
            },
            .WriteWorkspaceFile => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const path = requireStr(obj, "path") orelse return .{ .err = .{ .bad_params = "missing path" } };
                _ = requireStr(obj, "content") orelse return .{ .err = .{ .bad_params = "missing content" } };
                if (!workspace_files_host.isSafeRelativePath(path)) {
                    return .{ .err = .{ .bad_params = "path traversal denied" } };
                }
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"written\":true}") };
            },
            .WatchWorkspaceFiles => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "{\"changed\":[]}"));
            },
            .WatchWorkspaceGitStatus => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                const checkout_path = requireStr(obj, "checkoutPath") orelse return .{ .err = .{ .bad_params = "missing checkoutPath" } };
                return self.oneStreamItem(false, try git_host.runGitStatusJson(self.gpa, self.io, checkout_path));
            },
            .ListProjectActions => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const space_id = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                return .{ .unary_json = try self.actionsJson(space_id) };
            },
            .UpsertProjectAction => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const space_id = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                const action_id = requireStr(obj, "actionId") orelse "test";
                const act_val = obj.get("action") orelse return .{ .err = .{ .bad_params = "missing action" } };
                if (act_val != .object) return .{ .err = .{ .bad_params = "action must be object" } };
                const name = requireStr(act_val.object, "name") orelse return .{ .err = .{ .bad_params = "missing action.name" } };
                const command = requireStr(act_val.object, "command") orelse return .{ .err = .{ .bad_params = "missing action.command" } };
                const icon = requireStr(act_val.object, "icon") orelse "play";
                const run_wt = if (act_val.object.get("runOnWorktreeCreate")) |v| (if (v == .bool) v.bool else false) else false;
                try self.upsertAction(space_id, action_id, name, command, icon, run_wt);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"actionId\":{f}}}", .{json.fmt(action_id, .{})}) };
            },
            .DeleteProjectAction => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const space_id = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                const action_id = requireStr(obj, "actionId") orelse return .{ .err = .{ .bad_params = "missing actionId" } };
                const deleted = self.deleteAction(space_id, action_id);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"deleted\":{}}}", .{deleted}) };
            },
            .RunProjectAction => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                _ = requireStr(obj, "actionId") orelse return .{ .err = .{ .bad_params = "missing actionId" } };
                return .{ .err = .{ .exec_error = "project action not found" } };
            },
            .UpdateStatus => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "targetDeviceId") orelse return .{ .err = .{ .bad_params = "missing targetDeviceId" } };
                return self.oneStreamItem(false, try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"currentVersion\":{f},\"latestVersion\":{f},\"updateAvailable\":false,\"state\":\"upToDate\",\"host\":{{\"mode\":\"desktop\",\"automatic\":true,\"phase\":\"idle\"}}}}",
                    .{ json.fmt(build_info.version, .{}), json.fmt(build_info.version, .{}) },
                ));
            },
            .CheckForUpdates, .QueueUpdate => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "targetDeviceId") orelse return .{ .err = .{ .bad_params = "missing targetDeviceId" } };
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"ok\":true}") };
            },
            .OpenTerminal => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const tid = requireStr(obj, "terminalId") orelse "term-1";
                const cwd = requireStr(obj, "cwd") orelse "/tmp";
                const cols: u16 = if (obj.get("cols")) |cv| (if (cv == .integer and cv.integer > 0) @intCast(cv.integer) else 80) else 80;
                const rows: u16 = if (obj.get("rows")) |rv| (if (rv == .integer and rv.integer > 0) @intCast(rv.integer) else 24) else 24;
                const sess = try self.terminals.getOrCreate(tid, cwd, cols, rows, false);
                return .{ .unary_json = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"terminalId\":{f},\"cols\":{d},\"rows\":{d}}}",
                    .{ json.fmt(sess.id, .{}), sess.cols, sess.rows },
                ) };
            },
            .SubscribeTerminal => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const tid = requireStr(obj, "terminalId") orelse return .{ .err = .{ .bad_params = "missing terminalId" } };
                if (self.terminals.sessions.getPtr(tid)) |sess| {
                    return self.oneStreamItem(
                        false,
                        try std.fmt.allocPrint(
                            self.gpa,
                            "{{\"terminalId\":{f},\"output\":{f},\"exited\":{}}}",
                            .{ json.fmt(sess.id, .{}), json.fmt(sess.scrollback.items, .{}), sess.exited },
                        ),
                    );
                }
                return .{ .err = .{ .exec_error = "terminal not found" } };
            },
            .WriteTerminal => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const tid = requireStr(obj, "terminalId") orelse return .{ .err = .{ .bad_params = "missing terminalId" } };
                const data = requireStr(obj, "data") orelse return .{ .err = .{ .bad_params = "missing data" } };
                const written = try self.terminals.writeInput(tid, data);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"written\":{}}}", .{written}) };
            },
            .ResizeTerminal => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const tid = requireStr(obj, "terminalId") orelse return .{ .err = .{ .bad_params = "missing terminalId" } };
                const cols: u16 = if (obj.get("cols")) |cv| (if (cv == .integer and cv.integer > 0) @intCast(cv.integer) else 80) else 80;
                const rows: u16 = if (obj.get("rows")) |rv| (if (rv == .integer and rv.integer > 0) @intCast(rv.integer) else 24) else 24;
                const resized = self.terminals.resize(tid, cols, rows);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"resized\":{}}}", .{resized}) };
            },
            .CloseTerminal => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                const tid = requireStr(obj, "terminalId") orelse return .{ .err = .{ .bad_params = "missing terminalId" } };
                const closed = self.terminals.close(tid);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"closed\":{}}}", .{closed}) };
            },
            .ListSimulators => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"simulators\":[]}") };
            },
            .WatchSimulatorScreen, .WatchLocalhostPage => {
                return self.oneStreamItem(false, try self.gpa.dupe(u8, "{\"frame\":null}"));
            },
            .ListLocalhostServers => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"servers\":[]}") };
            },
            .GraffWorktreeAction => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                _ = requireStr(obj, "action") orelse return .{ .err = .{ .bad_params = "missing action" } };
                return .{ .err = .{ .exec_error = "chat has no graff worktree" } };
            },
            .WatchCheckoutChangeRequest => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "cwd") orelse return .{ .err = .{ .bad_params = "missing cwd" } };
                _ = requireStr(obj, "branch") orelse return .{ .err = .{ .bad_params = "missing branch" } };
                return self.oneStreamItem(true, try self.gpa.dupe(u8, "{\"status\":\"none\"}"));
            },
            .MergeChangeRequest => {
                const obj = requireObj(params) orelse return .{ .err = .{ .bad_params = "expected object" } };
                _ = requireStr(obj, "cwd") orelse return .{ .err = .{ .bad_params = "missing cwd" } };
                _ = requireStr(obj, "branch") orelse return .{ .err = .{ .bad_params = "missing branch" } };
                if (obj.get("number") == null) return .{ .err = .{ .bad_params = "missing number" } };
                return .{ .err = .{ .exec_error = "not a github repository" } };
            },
        }
    }

    fn handleMutate(self: *EngineHost, op: []const u8, obj: json.ObjectMap) !RpcOutcome {
        const mutate_op = mutate_op_map.get(op) orelse return .{ .err = .{ .bad_params = "unknown Mutate op" } };
        switch (mutate_op) {
            .createSpace => {
                const space_id = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                const dev_id = requireStr(obj, "deviceId") orelse self.device_id;
                const path = requireStr(obj, "path") orelse return .{ .err = .{ .bad_params = "missing path" } };
                const name = requireStr(obj, "name") orelse std.fs.path.basename(path);
                const git = if (obj.get("gitDetected")) |g| (if (g == .bool) g.bool else false) else false;

                var updated_existing = false;
                for (self.spaces.items) |*existing| {
                    if (std.mem.eql(u8, existing.id, space_id)) {
                        const p_copy = try self.gpa.dupe(u8, path);
                        errdefer self.gpa.free(p_copy);
                        const n_copy = try self.gpa.dupe(u8, name);
                        self.gpa.free(existing.path);
                        self.gpa.free(existing.name);
                        existing.path = p_copy;
                        existing.name = n_copy;
                        existing.git_detected = git;
                        updated_existing = true;
                        break;
                    }
                }
                if (!updated_existing) {
                    const id_c = try self.gpa.dupe(u8, space_id);
                    errdefer self.gpa.free(id_c);
                    const dev_c = try self.gpa.dupe(u8, dev_id);
                    errdefer self.gpa.free(dev_c);
                    const path_c = try self.gpa.dupe(u8, path);
                    errdefer self.gpa.free(path_c);
                    const name_c = try self.gpa.dupe(u8, name);
                    errdefer self.gpa.free(name_c);
                    try self.spaces.append(self.gpa, .{
                        .id = id_c,
                        .device_id = dev_c,
                        .path = path_c,
                        .name = name_c,
                        .git_detected = git,
                    });
                }
                _ = try self.registry.setField(.spaces, space_id, "name", name, 1000, self.device_id);
                _ = try self.registry.setField(.spaces, space_id, "path", path, 1000, self.device_id);
                const sp_json = try self.spacesJson();
                defer self.gpa.free(sp_json);
                try self.broadcastWatch(.spaces, null, sp_json);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"spaceId\":{f}}}", .{json.fmt(space_id, .{})}) };
            },
            .renameSpace => {
                const space_id = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                const name = requireStr(obj, "name") orelse return .{ .err = .{ .bad_params = "missing name" } };
                for (self.spaces.items) |*s| {
                    if (std.mem.eql(u8, s.id, space_id)) {
                        const copy = try self.gpa.dupe(u8, name);
                        self.gpa.free(s.name);
                        s.name = copy;
                    }
                }
                const sp_json = try self.spacesJson();
                defer self.gpa.free(sp_json);
                try self.broadcastWatch(.spaces, null, sp_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .deleteSpace => {
                const space_id = requireStr(obj, "spaceId") orelse return .{ .err = .{ .bad_params = "missing spaceId" } };
                var i: usize = 0;
                while (i < self.spaces.items.len) {
                    if (std.mem.eql(u8, self.spaces.items[i].id, space_id)) {
                        self.spaces.items[i].deinit(self.gpa);
                        _ = self.spaces.orderedRemove(i);
                        break;
                    }
                    i += 1;
                }
                const sp_json = try self.spacesJson();
                defer self.gpa.free(sp_json);
                try self.broadcastWatch(.spaces, null, sp_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"deleted\":true}") };
            },
            .createChat => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const space_id: ?[]const u8 = if (obj.get("spaceId")) |v| (if (v == .string) v.string else null) else null;
                const cfg_val = obj.get("config") orelse return .{ .err = .{ .bad_params = "missing config" } };
                if (cfg_val != .object) return .{ .err = .{ .bad_params = "config must be object" } };
                const harness = requireStr(cfg_val.object, "harness") orelse return .{ .err = .{ .bad_params = "missing config.harness" } };
                const model: ?[]const u8 = if (cfg_val.object.get("model")) |v| (if (v == .string) v.string else null) else null;
                const reasoning: ?[]const u8 = if (cfg_val.object.get("reasoning")) |v| (if (v == .string) v.string else null) else null;
                const title: ?[]const u8 = if (obj.get("title")) |v| (if (v == .string) v.string else null) else null;

                var exists = false;
                for (self.chats.items) |existing| {
                    if (std.mem.eql(u8, existing.id, chat_id)) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    const id_c = try self.gpa.dupe(u8, chat_id);
                    errdefer self.gpa.free(id_c);
                    const sp_c = if (space_id) |s| try self.gpa.dupe(u8, s) else null;
                    errdefer if (sp_c) |s| self.gpa.free(s);
                    const dev_c = try self.gpa.dupe(u8, self.device_id);
                    errdefer self.gpa.free(dev_c);
                    const h_c = try self.gpa.dupe(u8, harness);
                    errdefer self.gpa.free(h_c);
                    const t_c = if (title) |t| try self.gpa.dupe(u8, t) else null;
                    errdefer if (t_c) |t| self.gpa.free(t);
                    const m_c = if (model) |m| try self.gpa.dupe(u8, m) else null;
                    errdefer if (m_c) |m| self.gpa.free(m);
                    const r_c = if (reasoning) |r| try self.gpa.dupe(u8, r) else null;
                    errdefer if (r_c) |r| self.gpa.free(r);

                    try self.chats.append(self.gpa, .{
                        .id = id_c,
                        .space_id = sp_c,
                        .device_id = dev_c,
                        .harness = h_c,
                        .title = t_c,
                        .model = m_c,
                        .reasoning = r_c,
                    });
                }
                _ = try self.getOrCreateDoc(chat_id);
                _ = try self.registry.setField(.chats, chat_id, "harness", harness, 1000, self.device_id);
                if (space_id) |sid| _ = try self.registry.setField(.chats, chat_id, "spaceId", sid, 1000, self.device_id);
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                const sess_json = try self.sessionsJson();
                defer self.gpa.free(sess_json);
                try self.broadcastWatch(.sessions, null, sess_json);
                return .{ .unary_json = try std.fmt.allocPrint(self.gpa, "{{\"chatId\":{f}}}", .{json.fmt(chat_id, .{})}) };
            },
            .setChatConfig => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const cfg_val = obj.get("config") orelse return .{ .err = .{ .bad_params = "missing config" } };
                if (cfg_val != .object) return .{ .err = .{ .bad_params = "config must be object" } };
                const harness = requireStr(cfg_val.object, "harness") orelse return .{ .err = .{ .bad_params = "missing config.harness" } };
                const model: ?[]const u8 = if (cfg_val.object.get("model")) |v| (if (v == .string) v.string else null) else null;
                const reasoning: ?[]const u8 = if (cfg_val.object.get("reasoning")) |v| (if (v == .string) v.string else null) else null;
                for (self.chats.items) |*c| {
                    if (std.mem.eql(u8, c.id, chat_id)) {
                        const copy = try self.gpa.dupe(u8, harness);
                        self.gpa.free(c.harness);
                        c.harness = copy;
                        if (model) |m| {
                            const m_copy = try self.gpa.dupe(u8, m);
                            if (c.model) |old| self.gpa.free(old);
                            c.model = m_copy;
                        }
                        if (reasoning) |r| {
                            const r_copy = try self.gpa.dupe(u8, r);
                            if (c.reasoning) |old| self.gpa.free(old);
                            c.reasoning = r_copy;
                        }
                    }
                }
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .renameChat => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const title = requireStr(obj, "title") orelse "";
                for (self.chats.items) |*c| {
                    if (std.mem.eql(u8, c.id, chat_id)) {
                        const t_copy = try self.gpa.dupe(u8, title);
                        if (c.title) |old| self.gpa.free(old);
                        c.title = t_copy;
                    }
                }
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .setChatBranch => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const branch: ?[]const u8 = if (obj.get("branch")) |v| (if (v == .string) v.string else null) else null;
                for (self.chats.items) |*c| {
                    if (std.mem.eql(u8, c.id, chat_id)) {
                        const b_copy = if (branch) |b| try self.gpa.dupe(u8, b) else null;
                        if (c.branch) |old| self.gpa.free(old);
                        c.branch = b_copy;
                    }
                }
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .setChatCwd => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const cwd: ?[]const u8 = if (obj.get("cwd")) |v| (if (v == .string) v.string else null) else null;
                for (self.chats.items) |*c| {
                    if (std.mem.eql(u8, c.id, chat_id)) {
                        const c_copy = if (cwd) |cw| try self.gpa.dupe(u8, cw) else null;
                        if (c.cwd) |old| self.gpa.free(old);
                        c.cwd = c_copy;
                    }
                }
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .setChatActivity => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const status = requireStr(obj, "status") orelse "idle";
                for (self.chats.items) |*c| {
                    if (std.mem.eql(u8, c.id, chat_id)) {
                        const s_copy = try self.gpa.dupe(u8, status);
                        if (c.activity_status) |old| self.gpa.free(old);
                        c.activity_status = s_copy;
                    }
                }
                const sess_json = try self.sessionsJson();
                defer self.gpa.free(sess_json);
                try self.broadcastWatch(.sessions, null, sess_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .setChatHost => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const host_dev = requireStr(obj, "deviceId") orelse requireStr(obj, "hostDeviceId") orelse return .{ .err = .{ .bad_params = "missing deviceId" } };
                for (self.chats.items) |*c| {
                    if (std.mem.eql(u8, c.id, chat_id)) {
                        const d_copy = try self.gpa.dupe(u8, host_dev);
                        self.gpa.free(c.device_id);
                        c.device_id = d_copy;
                    }
                }
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .changeSidebarPin => {
                const id: ?[]const u8 = requireStr(obj, "id") orelse blk: {
                    if (obj.get("change")) |cv| {
                        if (cv == .object) break :blk requireStr(cv.object, "id") orelse requireStr(cv.object, "chatId");
                    }
                    break :blk null;
                };
                const pinned: bool = if (obj.get("pinned")) |pv| (if (pv == .bool) pv.bool else true) else true;
                if (id) |target| {
                    for (self.chats.items) |*c| {
                        if (std.mem.eql(u8, c.id, target)) c.pinned = pinned;
                    }
                }
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .setAppearance => {
                _ = requireStr(obj, "mode");
                _ = requireStr(obj, "sortBy");
                _ = requireStr(obj, "groupBy");
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .deleteChat => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                var i: usize = 0;
                while (i < self.chats.items.len) {
                    if (std.mem.eql(u8, self.chats.items[i].id, chat_id)) {
                        self.chats.items[i].deinit(self.gpa);
                        _ = self.chats.orderedRemove(i);
                        break;
                    }
                    i += 1;
                }
                // Reclaim in-memory SessionDoc, persisted SQLite snapshot/outbox, and target watches
                // (Lean Theorem `complete_delete_zero_leak_and_no_resurrection`).
                if (self.docs.fetchRemove(chat_id)) |kv| {
                    self.gpa.free(kv.key);
                    var doc = kv.value;
                    doc.deinit();
                }
                self.store.deleteDoc(chat_id);
                self.removeTargetWatches(chat_id);
                if (self.focused_chat_id) |fid| {
                    if (std.mem.eql(u8, fid, chat_id)) {
                        self.gpa.free(fid);
                        self.focused_chat_id = null;
                    }
                }
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                const sess_json = try self.sessionsJson();
                defer self.gpa.free(sess_json);
                try self.broadcastWatch(.sessions, null, sess_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"deleted\":true}") };
            },
            .markChatSeen => {
                _ = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"seen\":true}") };
            },
            .setChatArchived => {
                const chat_id = requireStr(obj, "chatId") orelse return .{ .err = .{ .bad_params = "missing chatId" } };
                const arch_val = obj.get("archived") orelse return .{ .err = .{ .bad_params = "missing archived" } };
                if (arch_val != .bool) return .{ .err = .{ .bad_params = "archived must be bool" } };
                for (self.chats.items) |*c| {
                    if (std.mem.eql(u8, c.id, chat_id)) c.archived = arch_val.bool;
                }
                const ch_json = try self.chatsJson();
                defer self.gpa.free(ch_json);
                try self.broadcastWatch(.chats, null, ch_json);
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"updated\":true}") };
            },
            .renameDevice, .forgetDevice => {
                return .{ .unary_json = try self.gpa.dupe(u8, "{\"ok\":true}") };
            },
        }
    }

    pub fn spacesJson(self: *const EngineHost) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeByte('[');
        for (self.spaces.items, 0..) |s, idx| {
            if (idx > 0) try w.writeByte(',');
            try w.print(
                "{{\"id\":{f},\"deviceId\":{f},\"path\":{f},\"name\":{f},\"gitDetected\":{}}}",
                .{ json.fmt(s.id, .{}), json.fmt(s.device_id, .{}), json.fmt(s.path, .{}), json.fmt(s.name, .{}), s.git_detected },
            );
        }
        try w.writeByte(']');
        return aw.toOwnedSlice();
    }

    pub fn chatsJson(self: *const EngineHost) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeByte('[');
        for (self.chats.items, 0..) |c, idx| {
            if (idx > 0) try w.writeByte(',');
            const title = c.title orelse "New Chat";
            const model = c.model orelse defaultModelForHarness(c.harness);
            const reasoning = c.reasoning orelse "high";
            const cwd = c.cwd orelse self.chatWorkspacePath(c.id);
            const branch = c.branch orelse "experimental-zig-branch";
            if (c.space_id) |sid| {
                try w.print(
                    "{{\"id\":{f},\"title\":{f},\"spaceId\":{f},\"deviceId\":{f},\"harness\":{f},\"archived\":{},\"createdAt\":\"2026-11-10T08:00:00Z\",\"lastMessageAt\":\"2026-11-10T08:05:00Z\",\"cwd\":{f},\"branch\":{f},\"config\":{{\"harness\":{f},\"model\":{f},\"reasoning\":{f}}}}}",
                    .{ json.fmt(c.id, .{}), json.fmt(title, .{}), json.fmt(sid, .{}), json.fmt(c.device_id, .{}), json.fmt(c.harness, .{}), c.archived, json.fmt(cwd, .{}), json.fmt(branch, .{}), json.fmt(c.harness, .{}), json.fmt(model, .{}), json.fmt(reasoning, .{}) },
                );
            } else {
                try w.print(
                    "{{\"id\":{f},\"title\":{f},\"deviceId\":{f},\"harness\":{f},\"archived\":{},\"createdAt\":\"2026-11-10T08:00:00Z\",\"lastMessageAt\":\"2026-11-10T08:05:00Z\",\"cwd\":{f},\"branch\":{f},\"config\":{{\"harness\":{f},\"model\":{f},\"reasoning\":{f}}}}}",
                    .{ json.fmt(c.id, .{}), json.fmt(title, .{}), json.fmt(c.device_id, .{}), json.fmt(c.harness, .{}), c.archived, json.fmt(cwd, .{}), json.fmt(branch, .{}), json.fmt(c.harness, .{}), json.fmt(model, .{}), json.fmt(reasoning, .{}) },
                );
            }
        }
        try w.writeByte(']');
        return aw.toOwnedSlice();
    }

    pub fn sessionsJson(self: *const EngineHost) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeByte('[');
        for (self.chats.items, 0..) |c, idx| {
            if (idx > 0) try w.writeByte(',');
            const status = c.activity_status orelse "idle";
            try w.print(
                "{{\"chatId\":{f},\"status\":{f},\"updatedAt\":\"2026-11-10T08:05:00Z\"}}",
                .{ json.fmt(c.id, .{}), json.fmt(status, .{}) },
            );
        }
        try w.writeByte(']');
        return aw.toOwnedSlice();
    }

    pub fn syncStatusJson(self: *EngineHost) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        const now = self.nowMs();
        const is_synced = std.mem.eql(u8, self.workspace_scope, "synced") and self.auth.signed_in;
        try w.print(
            "{{\"deviceId\":{f},\"nowMs\":{d},\"workspaceScope\":{f},\"docsCount\":{d},\"outboxPending\":{d},\"workspace\":{{\"connected\":{},\"synced\":{},\"lastPushedMs\":{d},\"lastAckMs\":{d},\"rejoins\":0,\"probes\":{d},\"fullResyncs\":0,\"disconnects\":0,\"rejected\":0}},\"chats\":[",
            .{
                json.fmt(self.device_id, .{}),
                now,
                json.fmt(self.workspace_scope, .{}),
                self.store.snapshots.count(),
                self.store.outbox.items.len,
                is_synced,
                is_synced,
                now,
                now,
                self.sync_probes,
            },
        );
        for (self.chats.items, 0..) |c, idx| {
            if (idx > 0) try w.writeByte(',');
            const cursor: u64 = self.store.snapshotCursor(c.id) orelse 0;
            var pending_for_chat: usize = 0;
            for (self.store.outbox.items) |ob| {
                if (std.mem.eql(u8, ob.doc_id, c.id)) pending_for_chat += 1;
            }
            const state_str: []const u8 = if (pending_for_chat == 0) "synced" else "pushing";
            try w.print(
                "{{\"chatId\":{f},\"room\":{{\"connected\":{},\"cursor\":{d},\"headSeq\":{d},\"seqFloor\":0,\"checkpointSeq\":{d},\"checkpointSize\":0,\"rowCount\":{d},\"rowBytes\":0,\"pendingPushes\":{d},\"rejoins\":0,\"disconnects\":0,\"rejected\":0,\"serverResets\":0}},\"state\":{f}}}",
                .{
                    json.fmt(c.id, .{}),
                    is_synced,
                    cursor,
                    cursor,
                    cursor,
                    cursor,
                    pending_for_chat,
                    json.fmt(state_str, .{}),
                },
            );
        }
        try w.print(
            "],\"resources\":{{\"openDocs\":{d},\"snapshots\":{d},\"outboxPending\":{d}}}}}",
            .{ self.docs.count(), self.store.snapshots.count(), self.store.outbox.items.len },
        );
        return aw.toOwnedSlice();
    }

    fn defaultModelForHarness(harness: []const u8) []const u8 {
        if (std.mem.eql(u8, harness, "codex")) return "gpt-6.1-sol";
        if (std.mem.eql(u8, harness, "claude-code") or std.mem.eql(u8, harness, "claude")) return "claude-opus-5-5";
        return "chatgpt-new/gpt-6.1-sol";
    }

    fn modelsJsonForHarness(gpa: Allocator, harness: []const u8) ![]u8 {
        if (std.mem.eql(u8, harness, "codex")) {
            return gpa.dupe(
                u8,
                "[" ++
                    "{\"id\":\"gpt-6.1-sol\",\"label\":\"gpt-6.1-sol\",\"maker\":\"openai\",\"description\":\"codex\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"ultra\"],\"context\":500000}," ++
                    "{\"id\":\"gpt-6-astra\",\"label\":\"gpt-6-astra\",\"maker\":\"openai\",\"description\":\"codex\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"ultra\"],\"context\":270000}" ++
                    "]",
            );
        }
        if (std.mem.eql(u8, harness, "claude-code") or std.mem.eql(u8, harness, "claude")) {
            return gpa.dupe(
                u8,
                "[" ++
                    "{\"id\":\"claude-opus-5-5\",\"label\":\"claude-opus-5-5\",\"maker\":\"anthropic\",\"description\":\"claude-code\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"max\"],\"context\":1000000}," ++
                    "{\"id\":\"claude-sonnet-5-5\",\"label\":\"claude-sonnet-5-5\",\"maker\":\"anthropic\",\"description\":\"claude-code\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\"],\"context\":1000000}," ++
                    "{\"id\":\"claude-haiku-5-5\",\"label\":\"claude-haiku-5-5\",\"maker\":\"anthropic\",\"description\":\"claude-code\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\"],\"context\":1000000}" ++
                    "]",
            );
        }
        return gpa.dupe(
            u8,
            "[" ++
                "{\"id\":\"chatgpt-new/gpt-6.1-sol\",\"label\":\"gpt-6.1-sol\",\"maker\":\"openai\",\"description\":\"chatgpt-new\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"ultra\"],\"context\":500000}," ++
                "{\"id\":\"claude-agent/claude-opus-5-5\",\"label\":\"claude-opus-5-5\",\"maker\":\"anthropic\",\"description\":\"claude-agent\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultra\"],\"context\":1000000}," ++
                "{\"id\":\"claude-agent/claude-fable-5-1\",\"label\":\"claude-fable-5-1\",\"maker\":\"anthropic\",\"description\":\"claude-agent\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultra\"],\"context\":1000000}," ++
                "{\"id\":\"claude-agent/claude-sonnet-5-5\",\"label\":\"claude-sonnet-5-5\",\"maker\":\"anthropic\",\"description\":\"claude-agent\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultra\"],\"context\":1000000}," ++
                "{\"id\":\"codex/gpt-6.1-sol\",\"label\":\"gpt-6.1-sol\",\"maker\":\"openai\",\"description\":\"codex\",\"billing\":\"plan\",\"reasoningLevels\":[\"low\",\"medium\",\"high\",\"xhigh\",\"ultra\"],\"context\":500000}" ++
                "]",
        );
    }

    fn upsertAction(
        self: *EngineHost,
        space_id: []const u8,
        action_id: []const u8,
        name: []const u8,
        command: []const u8,
        icon: []const u8,
        run_wt: bool,
    ) !void {
        for (self.actions.items) |*a| {
            if (std.mem.eql(u8, a.space_id, space_id) and std.mem.eql(u8, a.id, action_id)) {
                const new_name = try self.gpa.dupe(u8, name);
                errdefer self.gpa.free(new_name);
                const new_cmd = try self.gpa.dupe(u8, command);
                errdefer self.gpa.free(new_cmd);
                const new_icon = try self.gpa.dupe(u8, icon);
                self.gpa.free(a.name);
                self.gpa.free(a.command);
                self.gpa.free(a.icon);
                a.name = new_name;
                a.command = new_cmd;
                a.icon = new_icon;
                a.run_on_worktree_create = run_wt;
                return;
            }
        }
        var rec = ProjectActionRecord{
            .id = try self.gpa.dupe(u8, action_id),
            .space_id = try self.gpa.dupe(u8, space_id),
            .name = try self.gpa.dupe(u8, name),
            .command = try self.gpa.dupe(u8, command),
            .icon = try self.gpa.dupe(u8, icon),
            .run_on_worktree_create = run_wt,
        };
        errdefer rec.deinit(self.gpa);
        try self.actions.append(self.gpa, rec);
    }

    fn deleteAction(self: *EngineHost, space_id: []const u8, action_id: []const u8) bool {
        for (self.actions.items, 0..) |*a, idx| {
            if (std.mem.eql(u8, a.space_id, space_id) and std.mem.eql(u8, a.id, action_id)) {
                a.deinit(self.gpa);
                _ = self.actions.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    fn actionsJson(self: *const EngineHost, space_id: []const u8) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("{\"actions\":[");
        var first = true;
        for (self.actions.items) |a| {
            if (!std.mem.eql(u8, a.space_id, space_id)) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.print(
                "{{\"id\":{f},\"name\":{f},\"command\":{f},\"icon\":{f},\"runOnWorktreeCreate\":{}}}",
                .{ json.fmt(a.id, .{}), json.fmt(a.name, .{}), json.fmt(a.command, .{}), json.fmt(a.icon, .{}), a.run_on_worktree_create },
            );
        }
        try w.writeAll("]}");
        return aw.toOwnedSlice();
    }
};

test "the Zig engine understands every request harness-nano sends (protocol/desktop/requests.json)" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();

    const protocol_dir = @import("parity_options").protocol_dir;
    const path = try std.fs.path.join(a, &.{ protocol_dir, "requests.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(4 << 20));
    const v = try json.parseFromSliceLeaky(json.Value, a, text, .{});

    var host = try EngineHost.init(testing.allocator, "dev-zig-parity", "Zig Host");
    defer host.deinit();

    for (v.object.get("requests").?.array.items) |case| {
        const name = case.object.get("name").?.string;
        const method = case.object.get("method").?.string;
        const raw_params = try json.Stringify.valueAlloc(a, case.object.get("params").?, .{});
        const sub1 = try std.mem.replaceOwned(u8, a, raw_params, "$DEVICE", host.device_id);
        const sub2 = try std.mem.replaceOwned(u8, a, sub1, "$DIR", "/tmp/parity-project");
        const params_val = try json.parseFromSliceLeaky(json.Value, a, sub2, .{});

        var outcome = try host.handle(method, params_val);
        switch (outcome) {
            .unary_json => |body| testing.allocator.free(body),
            .stream_items_json => |*st| st.deinit(testing.allocator),
            .err => |e| switch (e) {
                .bad_params => |msg| {
                    std.debug.print("refused {s} ({s}): bad params: {s}\n", .{ name, method, msg });
                    return error.EngineRefusedBadParams;
                },
                .unknown_method => |m| {
                    std.debug.print("refused {s}: unknown method {s}\n", .{ name, m });
                    return error.EngineRefusedUnknownMethod;
                },
                // An execution error (a terminal or action that doesn't exist yet) means
                // the engine understood the request and its params, matching desktop_requests.rs.
                .exec_error => {},
            },
        }
    }
}

test "end-to-end rpc.Mux call -> engine_main.dispatchClientLine -> rpc.Mux.dispatch" {
    const gpa = testing.allocator;
    const engine_main = @import("engine_main.zig");

    var host = try EngineHost.init(gpa, "dev-e2e", "Zig E2E");
    defer host.deinit();

    var mux: rpc.Mux = .{ .gpa = gpa };
    defer mux.deinit();

    const Capture = struct {
        got_ready: bool = false,
        fn onReply(self: *@This(), _: u64, reply: rpc.Reply) void {
            if (reply == .ok and reply.ok == .object) {
                if (reply.ok.object.get("ready")) |r| {
                    if (r == .bool and r.bool) self.got_ready = true;
                }
            }
        }
    };
    var cap: Capture = .{};
    const call = try mux.call("EngineReady", rpc.empty, rpc.Handler.of(Capture, &cap, Capture.onReply));
    defer gpa.free(call.frame);

    var wire_buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wire_buf);
    try engine_main.dispatchClientLine(gpa, &host, &w, call.frame);

    var r: std.Io.Reader = .fixed(w.buffered());
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(gpa);
    const Noop = struct {
        fn ping(_: void, _: []const u8) void {}
    };
    _ = try ws.readMessageFrom(gpa, &r, &msg, {}, Noop.ping);
    try mux.dispatch(msg.items);
    try testing.expect(cap.got_ready);
}

test "StopEngine RPC marks stop_requested on EngineHost" {
    const gpa = testing.allocator;
    var host = try EngineHost.init(gpa, "dev-stop", "Zig Stop");
    defer host.deinit();
    try testing.expect(!host.stop_requested);
    var out = try host.handle("StopEngine", json.Value{ .object = .empty });
    defer switch (out) {
        .unary_json => |b| gpa.free(b),
        .stream_items_json => |*s| s.deinit(gpa),
        .err => {},
    };
    try testing.expect(host.stop_requested);
    try testing.expectEqualStrings("{\"ok\":true}", out.unary_json);
}

test "mock WebSocket server with concurrent async clients: Client A watches live streams while Client B mutates and runs turns" {
    const gpa = testing.allocator;
    const io = testing.io;
    const net = std.Io.net;
    const engine_main = @import("engine_main.zig");

    var host = try EngineHost.init(gpa, "dev-mock-srv", "Mock Zig Server");
    defer host.deinit();
    host.io = io;

    const listen_addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.ip4.port;

    // Spawn 2 server handler threads (one for Client A, one for Client B) so both
    // async clients are served concurrently over real TCP/WebSocket connections.
    const ServerAcceptCtx = struct {
        gpa: Allocator,
        io: std.Io,
        srv: *net.Server,
        host: *EngineHost,

        fn acceptAndServeOne(ctx: *@This()) void {
            var stream = ctx.srv.accept(ctx.io) catch return;
            defer stream.close(ctx.io);
            engine_main.serveSocket(ctx.gpa, ctx.io, ctx.host, &stream) catch {};
        }
    };
    var srv_ctx = ServerAcceptCtx{ .gpa = gpa, .io = io, .srv = &server, .host = &host };

    // Async WebSocket client with its own background reader thread + rpc.Mux.
    const AsyncClient = struct {
        gpa: Allocator,
        io: std.Io,
        ws_client: *ws.Client,
        mux: rpc.Mux,
        lock: std.Io.Mutex = .init,
        reader_thread: ?std.Thread = null,
        spaces_updates: std.atomic.Value(u32) = .init(0),
        chats_updates: std.atomic.Value(u32) = .init(0),
        doc_updates: std.atomic.Value(u32) = .init(0),
        saw_b_prompt: std.atomic.Value(bool) = .init(false),
        saw_b_ack: std.atomic.Value(bool) = .init(false),
        models_count: std.atomic.Value(u32) = .init(0),
        mutate_acks: std.atomic.Value(u32) = .init(0),
        run_acks: std.atomic.Value(u32) = .init(0),

        fn connect(alloc: Allocator, client_io: std.Io, p: u16) !*@This() {
            const self = try alloc.create(@This());
            errdefer alloc.destroy(self);
            const c = try ws.Client.connect(alloc, client_io, p, "/");
            self.* = .{
                .gpa = alloc,
                .io = client_io,
                .ws_client = c,
                .mux = .{ .gpa = alloc },
            };
            self.reader_thread = try std.Thread.spawn(.{}, readLoop, .{self});
            return self;
        }

        fn deinit(self: *@This()) void {
            ws.writeFrame(&self.ws_client.wr.interface, .close, &.{}, .{ 0, 0, 0, 0 }) catch {};
            self.ws_client.wr.interface.flush() catch {};
            self.ws_client.shutdown();
            if (self.reader_thread) |t| t.join();
            self.ws_client.deinit(self.gpa);
            self.mux.deinit();
            self.gpa.destroy(self);
        }

        fn readLoop(self: *@This()) void {
            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(self.gpa);
            while (true) {
                const op = self.ws_client.readMessage(self.gpa, &msg) catch return;
                if (op != .text) continue;
                if (std.mem.indexOf(u8, msg.items, "Hello from concurrent Client B!") != null) {
                    self.saw_b_prompt.store(true, .release);
                }
                if (std.mem.indexOf(u8, msg.items, "Ack from dev-mock-srv: Hello from concurrent Client B!") != null) {
                    self.saw_b_ack.store(true, .release);
                }
                self.lock.lockUncancelable(self.io);
                self.mux.dispatch(msg.items) catch {};
                self.lock.unlock(self.io);
            }
        }

        fn sendCall(self: *@This(), method: []const u8, params: anytype, handler: rpc.Handler) !void {
            self.lock.lockUncancelable(self.io);
            const req = try self.mux.call(method, params, handler);
            self.lock.unlock(self.io);
            defer self.gpa.free(req.frame);
            try self.ws_client.sendText(req.frame);
        }

        fn onSpaces(self: *@This(), _: u64, reply: rpc.Reply) void {
            if (reply == .item and reply.item == .array and reply.item.array.items.len > 0) {
                _ = self.spaces_updates.fetchAdd(1, .acq_rel);
            }
        }
        fn onChats(self: *@This(), _: u64, reply: rpc.Reply) void {
            if (reply == .item and reply.item == .array and reply.item.array.items.len > 0) {
                _ = self.chats_updates.fetchAdd(1, .acq_rel);
            }
        }
        fn onDoc(self: *@This(), _: u64, reply: rpc.Reply) void {
            if (reply == .item and reply.item == .object) {
                _ = self.doc_updates.fetchAdd(1, .acq_rel);
            }
        }
        fn onModels(self: *@This(), _: u64, reply: rpc.Reply) void {
            if (reply == .ok and reply.ok == .array) {
                self.models_count.store(@intCast(reply.ok.array.items.len), .release);
            }
        }
        fn onMutate(self: *@This(), _: u64, reply: rpc.Reply) void {
            if (reply == .ok) _ = self.mutate_acks.fetchAdd(1, .acq_rel);
        }
        fn onRun(self: *@This(), _: u64, reply: rpc.Reply) void {
            if (reply == .ok) _ = self.run_acks.fetchAdd(1, .acq_rel);
        }
    };

    const srv_t1 = try std.Thread.spawn(.{}, ServerAcceptCtx.acceptAndServeOne, .{&srv_ctx});
    var client_a = try AsyncClient.connect(gpa, io, port);
    defer {
        client_a.deinit();
        srv_t1.join();
    }

    const srv_t2 = try std.Thread.spawn(.{}, ServerAcceptCtx.acceptAndServeOne, .{&srv_ctx});
    var client_b = try AsyncClient.connect(gpa, io, port);
    defer {
        client_b.deinit();
        srv_t2.join();
    }

    // Client A subscribes to live Watch* streams and fetches ListModels
    try client_a.sendCall("WatchSpaces", rpc.empty, rpc.Handler.of(AsyncClient, client_a, AsyncClient.onSpaces));
    try client_a.sendCall("WatchChats", rpc.empty, rpc.Handler.of(AsyncClient, client_a, AsyncClient.onChats));
    try client_a.sendCall("WatchDocMessages", .{ .chatId = "chat-async-1" }, rpc.Handler.of(AsyncClient, client_a, AsyncClient.onDoc));
    try client_a.sendCall("ListModels", .{ .harness = "graff" }, rpc.Handler.of(AsyncClient, client_a, AsyncClient.onModels));

    // Wait briefly for Client A's watches to register on the mock server
    var wait_ticks: usize = 0;
    while (client_a.models_count.load(.acquire) == 0 and wait_ticks < 200) : (wait_ticks += 1) {
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }
    try testing.expect(client_a.models_count.load(.acquire) >= 5);

    // Concurrently on Client B's separate WebSocket connection: create space, create chat, and run a turn!
    try client_b.sendCall(
        "Mutate",
        .{ .op = "createSpace", .spaceId = "sp-async", .path = "/tmp/async-space", .name = "AsyncSpace" },
        rpc.Handler.of(AsyncClient, client_b, AsyncClient.onMutate),
    );
    try client_b.sendCall(
        "Mutate",
        .{ .op = "createChat", .chatId = "chat-async-1", .spaceId = "sp-async", .config = .{ .harness = "graff" } },
        rpc.Handler.of(AsyncClient, client_b, AsyncClient.onMutate),
    );
    try client_b.sendCall(
        "QueueCommand",
        .{
            .chatId = "chat-async-1",
            .command = .{
                .kind = "run",
                .messageId = "msg-async-1",
                .request = .{ .prompt = "Hello from concurrent Client B!", .cwd = "/tmp/async-space" },
            },
        },
        rpc.Handler.of(AsyncClient, client_b, AsyncClient.onRun),
    );

    // Wait for Client B's unary replies AND Client A's live pushed Watch* stream frames!
    wait_ticks = 0;
    while ((!client_a.saw_b_ack.load(.acquire) or client_b.run_acks.load(.acquire) == 0) and wait_ticks < 400) : (wait_ticks += 1) {
        std.Io.sleep(io, .fromMilliseconds(5), .awake) catch {};
    }

    try testing.expectEqual(@as(u32, 2), client_b.mutate_acks.load(.acquire));
    try testing.expectEqual(@as(u32, 1), client_b.run_acks.load(.acquire));
    try testing.expect(client_a.spaces_updates.load(.acquire) >= 1);
    try testing.expect(client_a.chats_updates.load(.acquire) >= 1);
    try testing.expect(client_a.doc_updates.load(.acquire) >= 2);
    try testing.expect(client_a.saw_b_prompt.load(.acquire));
    try testing.expect(client_a.saw_b_ack.load(.acquire));
}

fn inferAttachmentMime(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return "image/svg+xml";
    if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return "image/bmp";
    if (std.ascii.eqlIgnoreCase(ext, ".tif") or std.ascii.eqlIgnoreCase(ext, ".tiff")) return "image/tiff";
    return "application/octet-stream";
}

test "UploadChunk, UploadCommit, ReadAttachmentChunk, and SignIn/SignOut round-trip" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var host = try EngineHost.init(gpa, "dev-upload", "UploadHost");
    defer host.deinit();

    // 1. UploadChunk with base64 PNG header bytes ("hello-png")
    const chunk_params = try json.parseFromSliceLeaky(json.Value, a, "{\"uploadId\":\"up-123\",\"seq\":0,\"data\":\"aGVsbG8tcG5n\"}", .{});
    const chunk_out = try host.handle("UploadChunk", chunk_params);
    defer gpa.free(chunk_out.unary_json);
    try testing.expect(std.mem.indexOf(u8, chunk_out.unary_json, "\"ok\":true") != null);

    // 2. UploadCommit -> returns durable path
    const commit_params = try json.parseFromSliceLeaky(json.Value, a, "{\"uploadId\":\"up-123\",\"fileName\":\"image.png\"}", .{});
    const commit_out = try host.handle("UploadCommit", commit_params);
    defer gpa.free(commit_out.unary_json);
    try testing.expect(std.mem.indexOf(u8, commit_out.unary_json, "/tmp/harness-zig-live/uploads/up-123-image.png") != null);

    // 3. ReadAttachmentChunk -> returns base64 data + image/png mimeType + done:true
    const read_params = try json.parseFromSliceLeaky(json.Value, a, "{\"path\":\"/tmp/harness-zig-live/uploads/up-123-image.png\",\"offset\":0}", .{});
    const read_out = try host.handle("ReadAttachmentChunk", read_params);
    defer gpa.free(read_out.unary_json);
    try testing.expect(std.mem.indexOf(u8, read_out.unary_json, "\"mimeType\":\"image/png\"") != null);
    try testing.expect(std.mem.indexOf(u8, read_out.unary_json, "\"data\":\"aGVsbG8tcG5n\"") != null);
    try testing.expect(std.mem.indexOf(u8, read_out.unary_json, "\"done\":true") != null);

    // 4. SignOut and SignIn toggle workspaceScope
    const empty_params = try json.parseFromSliceLeaky(json.Value, a, "{}", .{});
    const out_res = try host.handle("SignOut", empty_params);
    defer gpa.free(out_res.unary_json);
    try testing.expectEqualStrings("local", host.workspace_scope);

    const in_res = try host.handle("SignIn", empty_params);
    defer gpa.free(in_res.unary_json);
    try testing.expectEqualStrings("synced", host.workspace_scope);
}

test "1:1 Rust RPC parity (all 153 methods), O(1) dispatch, and Lean-verified zero-leak chat/upload lifecycle" {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Verify O(1) static map contains all 148 canonical Rust RPC methods + 5 compatibility aliases = 153.
    try testing.expectEqual(@as(usize, 153), rpc_method_map.kvs.len);

    var host = try EngineHost.init(gpa, "dev-parity", "ParityHost");
    defer host.deinit();

    const empty_params = try json.parseFromSliceLeaky(json.Value, a, "{}", .{});

    // 2. Test newly wired 1:1 Rust RPC methods (LocalDevice, GetKeepAwake/SetKeepAwake, SyncStatus, ProbeSync, ListCommands, ListBranches).
    {
        const ld = try host.handle("LocalDevice", empty_params);
        defer gpa.free(ld.unary_json);
        try testing.expect(std.mem.indexOf(u8, ld.unary_json, "\"deviceId\":\"dev-parity\"") != null);

        const set_ka_p = try json.parseFromSliceLeaky(json.Value, a, "{\"enabled\":true}", .{});
        const set_ka = try host.handle("SetKeepAwake", set_ka_p);
        defer gpa.free(set_ka.unary_json);
        try testing.expect(std.mem.indexOf(u8, set_ka.unary_json, "\"enabled\":true") != null);

        const get_ka = try host.handle("GetKeepAwake", empty_params);
        defer gpa.free(get_ka.unary_json);
        try testing.expect(std.mem.indexOf(u8, get_ka.unary_json, "\"enabled\":true") != null);

        const sync_st = try host.handle("SyncStatus", empty_params);
        defer gpa.free(sync_st.unary_json);
        try testing.expect(std.mem.indexOf(u8, sync_st.unary_json, "\"workspaceScope\":\"synced\"") != null);

        const cmds = try host.handle("ListCommands", empty_params);
        defer gpa.free(cmds.unary_json);
        try testing.expect(std.mem.indexOf(u8, cmds.unary_json, "\"compact\"") != null);
    }

    // 3. Test OpenTerminal -> WriteTerminal -> ResizeTerminal -> SubscribeTerminal -> CloseTerminal.
    {
        const open_p = try json.parseFromSliceLeaky(json.Value, a, "{\"terminalId\":\"t-parity\",\"cwd\":\"/tmp\",\"cols\":100,\"rows\":30}", .{});
        const open_r = try host.handle("OpenTerminal", open_p);
        defer gpa.free(open_r.unary_json);
        try testing.expect(std.mem.indexOf(u8, open_r.unary_json, "\"cols\":100") != null);

        const write_p = try json.parseFromSliceLeaky(json.Value, a, "{\"terminalId\":\"t-parity\",\"data\":\"zig version\\n\"}", .{});
        const write_r = try host.handle("WriteTerminal", write_p);
        defer gpa.free(write_r.unary_json);
        try testing.expect(std.mem.indexOf(u8, write_r.unary_json, "\"written\":true") != null);

        const sub_p = try json.parseFromSliceLeaky(json.Value, a, "{\"terminalId\":\"t-parity\"}", .{});
        var sub_r = try host.handle("SubscribeTerminal", sub_p);
        defer sub_r.stream_items_json.deinit(gpa);
        try testing.expect(std.mem.indexOf(u8, sub_r.stream_items_json.items[0], "zig version") != null);

        const close_r = try host.handle("CloseTerminal", sub_p);
        defer gpa.free(close_r.unary_json);
        try testing.expect(std.mem.indexOf(u8, close_r.unary_json, "\"closed\":true") != null);
    }

    // 4. Test Lean Theorem `complete_delete_zero_leak_and_no_resurrection`:
    // createChat -> WatchDocMessages -> QueueCommand -> deleteChat reclaims all 4 stores!
    {
        const create_p = try json.parseFromSliceLeaky(json.Value, a, "{\"op\":\"createChat\",\"chatId\":\"chat-del-1\",\"config\":{\"harness\":\"graff\"}}", .{});
        const create_r = try host.handle("Mutate", create_p);
        defer gpa.free(create_r.unary_json);

        const watch_p = try json.parseFromSliceLeaky(json.Value, a, "{\"chatId\":\"chat-del-1\"}", .{});
        var watch_r = try host.handleWithId(77, "WatchDocMessages", watch_p);
        defer watch_r.stream_items_json.deinit(gpa);

        const run_p = try json.parseFromSliceLeaky(json.Value, a, "{\"chatId\":\"chat-del-1\",\"command\":{\"kind\":\"run\",\"messageId\":\"m-del-1\",\"request\":{\"prompt\":\"hi\"}}}", .{});
        const run_r = try host.handle("QueueCommand", run_p);
        defer gpa.free(run_r.unary_json);

        try testing.expectEqual(@as(usize, 1), host.chats.items.len);
        try testing.expectEqual(@as(u32, 1), host.docs.count());
        try testing.expectEqual(@as(u32, 1), host.store.snapshots.count());
        try testing.expectEqual(@as(usize, 1), host.watches.items.len);

        const del_p = try json.parseFromSliceLeaky(json.Value, a, "{\"op\":\"deleteChat\",\"chatId\":\"chat-del-1\"}", .{});
        const del_r = try host.handle("Mutate", del_p);
        defer gpa.free(del_r.unary_json);

        try testing.expectEqual(@as(usize, 0), host.chats.items.len);
        try testing.expectEqual(@as(u32, 0), host.docs.count());
        try testing.expectEqual(@as(u32, 0), host.store.snapshots.count());
        try testing.expectEqual(@as(usize, 0), host.store.outbox.items.len);
        try testing.expectEqual(@as(usize, 0), host.watches.items.len);
    }

    // 5. Test Lean Theorem `commit_stream_always_bounded`:
    // committing 12 uploads strictly bounds `committed_uploads.count() <= max_committed_uploads_cache` (8).
    for (0..12) |i| {
        const up_json = try std.fmt.allocPrint(a, "{{\"uploadId\":\"lru-{d}\",\"seq\":0,\"data\":\"aGVsbG8=\"}}", .{i});
        const up_p = try json.parseFromSliceLeaky(json.Value, a, up_json, .{});
        const up_r = try host.handle("UploadChunk", up_p);
        gpa.free(up_r.unary_json);

        const cm_json = try std.fmt.allocPrint(a, "{{\"uploadId\":\"lru-{d}\",\"fileName\":\"img-{d}.png\"}}", .{ i, i });
        const cm_p = try json.parseFromSliceLeaky(json.Value, a, cm_json, .{});
        const cm_r = try host.handle("UploadCommit", cm_p);
        gpa.free(cm_r.unary_json);
    }
    try testing.expectEqual(@as(u32, 0), host.staged_uploads.count());
    try testing.expectEqual(@as(u32, max_committed_uploads_cache), host.committed_uploads.count());
    try testing.expectEqual(max_committed_uploads_cache, host.committed_upload_order.items.len);
}

test "Full Rust parity Login (SignInHeadless -> CompleteSignIn -> NeedsOrganization -> ListOrgs -> SelectOrg) + Chat2 Sync + SyncStatus" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Start a mock Edge HTTP server on 127.0.0.1:0 handling:
    //    - POST /auth/exchange (mints JWT without org_id + refresh-1)
    //    - GET  /auth/orgs     (returns Acme org_1)
    //    - POST /auth/refresh  (rotates refresh-1 -> rotated-1 + mints org-scoped JWT)
    const listen_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var edge_srv = try listen_addr.listen(io, .{ .reuse_address = true });
    defer edge_srv.deinit(io);
    const edge_port = edge_srv.socket.address.getPort();

    const EdgeCtx = struct {
        srv: *std.Io.net.Server,
        tio: std.Io,

        fn run(ctx: @This()) void {
            // Serve 3 sequential HTTP requests: /auth/exchange, /auth/orgs, /auth/refresh
            for (0..3) |_| {
                var stream = ctx.srv.accept(ctx.tio) catch return;
                defer stream.close(ctx.tio);
                var rbuf: [4096]u8 = undefined;
                var wbuf: [4096]u8 = undefined;
                var reader = stream.reader(ctx.tio, &rbuf);
                var writer = stream.writer(ctx.tio, &wbuf);

                const req_line = reader.interface.takeDelimiterInclusive('\n') catch return;
                var content_len: usize = 0;
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch return;
                    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
                    if (trimmed.len == 0) break;
                    if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                        const val = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                        content_len = std.fmt.parseInt(usize, val, 10) catch 0;
                    }
                }
                if (content_len > 0) {
                    var body_discard: [1024]u8 = undefined;
                    var rem = content_len;
                    while (rem > 0) {
                        const chunk = @min(rem, body_discard.len);
                        reader.interface.readSliceAll(body_discard[0..chunk]) catch return;
                        rem -= chunk;
                    }
                }

                // Fake JWTs:
                // payload without org: {"sub":"user_1","iat":1000,"exp":4600} -> base64url: eyJzdWIiOiJ1c2VyXzEiLCJpYXQiOjEwMDAsImV4cCI6NDYwMH0
                // payload with org_1:  {"sub":"user_1","iat":1000,"exp":4600,"org_id":"org_1"} -> base64url: eyJzdWIiOiJ1c2VyXzEiLCJpYXQiOjEwMDAsImV4cCI6NDYwMCwib3JnX2lkIjoib3JnXzEifQ
                const body: []const u8 = if (std.mem.indexOf(u8, req_line, "/auth/exchange") != null)
                    "{\"user\":{\"id\":\"user_1\",\"email\":\"w@example.com\",\"firstName\":\"Wing\",\"lastName\":\"Test\"},\"accessToken\":\"e30.eyJzdWIiOiJ1c2VyXzEiLCJpYXQiOjEwMDAsImV4cCI6NDYwMH0.sig\",\"refreshToken\":\"refresh-1\"}"
                else if (std.mem.indexOf(u8, req_line, "/auth/orgs") != null)
                    "{\"orgs\":[{\"id\":\"om_1\",\"organizationId\":\"org_1\",\"name\":\"Acme\"}]}"
                else
                    "{\"accessToken\":\"e30.eyJzdWIiOiJ1c2VyXzEiLCJpYXQiOjEwMDAsImV4cCI6NDYwMCwib3JnX2lkIjoib3JnXzEifQ.sig\",\"refreshToken\":\"rotated-1\"}";

                writer.interface.print(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch return;
                writer.interface.flush() catch return;
            }
        }
    };

    const edge_thread = try std.Thread.spawn(.{}, EdgeCtx.run, .{EdgeCtx{ .srv = &edge_srv, .tio = io }});
    defer edge_thread.join();

    var host = try EngineHost.init(gpa, "dev-sync-1", "SyncHost");
    defer host.deinit();
    host.io = io;

    const edge_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{edge_port});
    const session_dir = "/tmp/harness-zig-auth-test";
    std.Io.Dir.cwd().createDirPath(io, session_dir) catch {};
    try host.auth.configureCodegraff(edge_url, "cg_client_test", "https://codegraff.example", session_dir);

    const empty_params = try json.parseFromSliceLeaky(json.Value, a, "{}", .{});

    // 2. Initial AuthStatus is signedOut
    {
        var st = try host.handleWithId(1, "AuthStatus", empty_params);
        defer st.stream_items_json.deinit(gpa);
        try testing.expectEqualStrings("{\"state\":\"signedOut\"}", st.stream_items_json.items[0]);
    }

    // 3. SignInHeadless returns PKCE S256 authorize URL
    {
        const res = try host.handle("SignInHeadless", empty_params);
        defer gpa.free(res.unary_json);
        try testing.expect(std.mem.indexOf(u8, res.unary_json, "https://codegraff.example/oauth/authorize?") != null);
        try testing.expect(std.mem.indexOf(u8, res.unary_json, "client_id=cg_client_test") != null);
        try testing.expect(std.mem.indexOf(u8, res.unary_json, "state=state-zig-1") != null);
        try testing.expect(std.mem.indexOf(u8, res.unary_json, "code_challenge_method=S256") != null);
    }

    // 4. CompleteSignIn with wrong OAuth state is rejected (CSRF protection)
    {
        const bad_p = try json.parseFromSliceLeaky(json.Value, a, "{\"code\":\"bogus-state.code123\"}", .{});
        const bad_r = try host.handle("CompleteSignIn", bad_p);
        try testing.expect(bad_r == .err);
    }

    // 5. CompleteSignIn with valid state.code exchanges with mock Edge and lands in NeedsOrganization
    {
        const ok_p = try json.parseFromSliceLeaky(json.Value, a, "{\"code\":\"state-zig-1.code123\"}", .{});
        const ok_r = try host.handle("CompleteSignIn", ok_p);
        defer gpa.free(ok_r.unary_json);
        try testing.expectEqual(auth_host.AuthPhase.needs_organization, host.auth.phase);
        try testing.expectEqualStrings("w@example.com", host.auth.email);
        try testing.expectEqualStrings("Wing Test", host.auth.user_name.?);
        try testing.expectEqualStrings("refresh-1", host.auth.refresh_token.?);
    }

    // 6. ListOrgs fetches orgs from mock Edge
    {
        const orgs_r = try host.handle("ListOrgs", empty_params);
        defer gpa.free(orgs_r.unary_json);
        try testing.expect(std.mem.indexOf(u8, orgs_r.unary_json, "\"organizationId\":\"org_1\"") != null);
        try testing.expect(std.mem.indexOf(u8, orgs_r.unary_json, "\"name\":\"Acme\"") != null);
    }

    // 7. SelectOrg calls /auth/refresh, rotates refreshToken -> "rotated-1", and lands in SignedIn(org_1)
    {
        const sel_p = try json.parseFromSliceLeaky(json.Value, a, "{\"organizationId\":\"org_1\"}", .{});
        const sel_r = try host.handle("SelectOrg", sel_p);
        defer gpa.free(sel_r.unary_json);
        try testing.expectEqual(auth_host.AuthPhase.signed_in, host.auth.phase);
        try testing.expect(host.auth.signed_in);
        try testing.expectEqualStrings("org_1", host.auth.org_id.?);
        try testing.expectEqualStrings("rotated-1", host.auth.refresh_token.?);

        // Verify persisted session.json contains rotated-1
        const sess_bytes = try std.Io.Dir.cwd().readFileAlloc(io, "/tmp/harness-zig-auth-test/session.json", a, .limited(64 * 1024));
        try testing.expect(std.mem.indexOf(u8, sess_bytes, "\"refreshToken\":\"rotated-1\"") != null);
        try testing.expect(std.mem.indexOf(u8, sess_bytes, "\"orgId\":\"org_1\"") != null);
    }

    // 8. Create a chat and run a full Chat2RoomClient sync cycle with the minted access token
    {
        const create_p = try json.parseFromSliceLeaky(json.Value, a, "{\"op\":\"createChat\",\"chatId\":\"chat-sync-1\",\"config\":{\"harness\":\"graff\"}}", .{});
        const create_r = try host.handle("Mutate", create_p);
        defer gpa.free(create_r.unary_json);

        const doc = try host.getOrCreateDoc("chat-sync-1");
        const chat2_wire = @import("chat2_wire.zig");

        var room = chat2_client.Chat2RoomClient{
            .gpa = gpa,
            .doc_id = "chat-sync-1",
            .doc = doc,
            .store = &host.store,
        };

        // 8a. Build hello frame carrying the OAuth access token
        const hello = try room.buildHelloFrame(host.auth.access_token.?, host.device_id);
        defer gpa.free(hello);
        var hello_dec = chat2_wire.decode(gpa, hello).?;
        defer hello_dec.deinit(gpa);
        try testing.expectEqual(chat2_wire.FrameType.hello, hello_dec.kind);

        // 8b. Server replies with `state` frame (headSeq=1, checkpointSize=0) -> rows_only(after=0)
        var state_hdr = try json.parseFromSlice(json.Value, gpa, "{\"headSeq\":1,\"seqFloor\":1,\"checkpointSeq\":0,\"checkpointSize\":0}", .{});
        defer state_hdr.deinit();
        const state_frame = try chat2_wire.encodeValue(gpa, chat2_wire.FrameType.state, state_hdr.value, "");
        defer gpa.free(state_frame);
        const state_out = try room.handleServerFrame(state_frame, 2000);
        try testing.expectEqual(@as(u64, 0), state_out.catch_up_plan.rows_only.after);

        // 8c. Server pushes `row` seq=1 -> C2 atomic cursor advances to 1
        var row_hdr = try json.parseFromSlice(json.Value, gpa, "{\"seq\":1}", .{});
        defer row_hdr.deinit();
        const row_frame = try chat2_wire.encodeValue(gpa, chat2_wire.FrameType.row, row_hdr.value, "");
        defer gpa.free(row_frame);
        const row_out = try room.handleServerFrame(row_frame, 2005);
        try testing.expectEqual(@as(u64, 1), row_out.row_applied);

        // 8d. Local user enqueues an update (`batch-sync-1`) and server acknowledges at seq=2
        try host.store.enqueueChatUpdate("chat-sync-1", "batch-sync-1", "delta-bytes");
        try testing.expect(host.store.hasPendingChatUpdates("chat-sync-1"));

        var ack_hdr = try json.parseFromSlice(json.Value, gpa, "{\"batchId\":\"batch-sync-1\",\"seq\":2}", .{});
        defer ack_hdr.deinit();
        const ack_frame = try chat2_wire.encodeValue(gpa, chat2_wire.FrameType.ack, ack_hdr.value, "");
        defer gpa.free(ack_frame);
        const ack_out = try room.handleServerFrame(ack_frame, 2010);
        try testing.expectEqual(@as(u64, 2), ack_out.ack_processed);
        try testing.expect(!host.store.hasPendingChatUpdates("chat-sync-1"));

        // 8e. ProbeSync + SyncStatus reports connected=true, synced=true, probes=1, cursor=2, pendingPushes=0
        const probe_r = try host.handle("ProbeSync", empty_params);
        defer gpa.free(probe_r.unary_json);
        try testing.expect(std.mem.indexOf(u8, probe_r.unary_json, "\"probes\":1") != null);

        const sync_r = try host.handle("SyncStatus", empty_params);
        defer gpa.free(sync_r.unary_json);
        try testing.expect(std.mem.indexOf(u8, sync_r.unary_json, "\"connected\":true") != null);
        try testing.expect(std.mem.indexOf(u8, sync_r.unary_json, "\"synced\":true") != null);
        try testing.expect(std.mem.indexOf(u8, sync_r.unary_json, "\"cursor\":2") != null);
        try testing.expect(std.mem.indexOf(u8, sync_r.unary_json, "\"pendingPushes\":0") != null);
        try testing.expect(std.mem.indexOf(u8, sync_r.unary_json, "\"state\":\"synced\"") != null);
    }
}

test "Mechanical 1:1 source-of-truth verification against crates/rpc/src/lib.rs, crates/engine/src/rpc.rs, and crates/doc/src/commands.rs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Parse `crates/rpc/src/lib.rs` `pub mod methods` directly from disk and verify all 148 RPC methods exist in `rpc_method_map`.
    const rpc_lib_rs = try std.Io.Dir.cwd().readFileAlloc(io, "../../crates/rpc/src/lib.rs", a, .limited(256 * 1024));
    const mod_start = std.mem.indexOf(u8, rpc_lib_rs, "pub mod methods {") orelse return error.MissingMethodsMod;
    const mod_end_rel = std.mem.indexOfPos(u8, rpc_lib_rs, mod_start, "\n}") orelse return error.MissingMethodsEnd;
    const methods_block = rpc_lib_rs[mod_start..mod_end_rel];

    var rust_method_count: usize = 0;
    var line_it = std.mem.splitScalar(u8, methods_block, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "pub const ")) continue;
        const first_q = std.mem.indexOfScalar(u8, trimmed, '"') orelse continue;
        const second_q = std.mem.indexOfScalarPos(u8, trimmed, first_q + 1, '"') orelse continue;
        const method_name = trimmed[first_q + 1 .. second_q];
        try testing.expect(rpc_method_map.get(method_name) != null);
        rust_method_count += 1;
    }
    try testing.expectEqual(@as(usize, 148), rust_method_count);

    // 2. Parse `crates/engine/src/rpc.rs` `enum MutateParams` and `enum FinishQueuedMessageEditAction` directly from disk.
    const engine_rpc_rs = try std.Io.Dir.cwd().readFileAlloc(io, "../../crates/engine/src/rpc.rs", a, .limited(512 * 1024));

    const mutate_start = std.mem.indexOf(u8, engine_rpc_rs, "enum MutateParams {") orelse return error.MissingMutateParams;
    const mutate_end = std.mem.indexOfPos(u8, engine_rpc_rs, mutate_start, "\n}") orelse return error.MissingMutateEnd;
    const mutate_block = engine_rpc_rs[mutate_start + "enum MutateParams {".len .. mutate_end];

    var mutate_op_count: usize = 0;
    var depth: usize = 0;
    var m_lines = std.mem.splitScalar(u8, mutate_block, '\n');
    while (m_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "#[")) {
            continue;
        }
        if (depth == 0 and std.ascii.isUpper(trimmed[0])) {
            var end_ident: usize = 0;
            while (end_ident < trimmed.len and std.ascii.isAlphanumeric(trimmed[end_ident])) : (end_ident += 1) {}
            const pascal = trimmed[0..end_ident];
            const camel = try a.dupe(u8, pascal);
            camel[0] = std.ascii.toLower(camel[0]);
            try testing.expect(mutate_op_map.get(camel) != null);
            mutate_op_count += 1;
        }
        for (trimmed) |ch| {
            if (ch == '{') depth += 1;
            if (ch == '}') depth -= 1;
        }
    }
    try testing.expectEqual(@as(usize, 17), mutate_op_count);

    const edit_start = std.mem.indexOf(u8, engine_rpc_rs, "enum FinishQueuedMessageEditAction {") orelse return error.MissingEditAction;
    const edit_end = std.mem.indexOfPos(u8, engine_rpc_rs, edit_start, "\n}") orelse return error.MissingEditActionEnd;
    const edit_block = engine_rpc_rs[edit_start + "enum FinishQueuedMessageEditAction {".len .. edit_end];

    var edit_action_count: usize = 0;
    var e_lines = std.mem.splitScalar(u8, edit_block, '\n');
    while (e_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r,");
        if (trimmed.len == 0 or !std.ascii.isUpper(trimmed[0])) continue;
        const camel = try a.dupe(u8, trimmed);
        camel[0] = std.ascii.toLower(camel[0]);
        try testing.expect(edit_action_map.get(camel) != null);
        edit_action_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), edit_action_count);

    // 3. Parse `crates/doc/src/commands.rs` `pub enum SessionCommandKind` directly from disk.
    const commands_rs = try std.Io.Dir.cwd().readFileAlloc(io, "../../crates/doc/src/commands.rs", a, .limited(128 * 1024));
    const cmd_start = std.mem.indexOf(u8, commands_rs, "pub enum SessionCommandKind {") orelse return error.MissingSessionCommandKind;
    const cmd_end = std.mem.indexOfPos(u8, commands_rs, cmd_start, "\n}") orelse return error.MissingSessionCommandKindEnd;
    const cmd_block = commands_rs[cmd_start + "pub enum SessionCommandKind {".len .. cmd_end];

    var cmd_kind_count: usize = 0;
    var c_lines = std.mem.splitScalar(u8, cmd_block, '\n');
    while (c_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r,");
        if (trimmed.len == 0 or !std.ascii.isUpper(trimmed[0])) continue;
        const camel = try a.dupe(u8, trimmed);
        camel[0] = std.ascii.toLower(camel[0]);
        try testing.expect(command_kind_map.get(camel) != null);
        cmd_kind_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), cmd_kind_count);

    // 4. Execute all 17 Mutate ops, all 5 QueueCommand kinds, and all 4 FinishQueuedMessageEdit actions through EngineHost with testing.allocator (zero memory leaks).
    var host = try EngineHost.init(gpa, "dev-src-parity", "SourceParityHost");
    defer host.deinit();

    const mutate_payloads = [_][]const u8{
        "{\"op\":\"createSpace\",\"spaceId\":\"sp-1\",\"deviceId\":\"dev-src-parity\",\"path\":\"/tmp/sp\"}",
        "{\"op\":\"renameSpace\",\"spaceId\":\"sp-1\",\"name\":\"Renamed\"}",
        "{\"op\":\"createChat\",\"chatId\":\"ch-1\",\"spaceId\":\"sp-1\",\"config\":{\"harness\":\"graff\"}}",
        "{\"op\":\"renameChat\",\"chatId\":\"ch-1\",\"title\":\"Chat Title\"}",
        "{\"op\":\"setChatBranch\",\"chatId\":\"ch-1\",\"branch\":\"feat/parity\"}",
        "{\"op\":\"setChatCwd\",\"chatId\":\"ch-1\",\"cwd\":\"/tmp/sp/wt\"}",
        "{\"op\":\"setChatActivity\",\"chatId\":\"ch-1\",\"status\":\"working\"}",
        "{\"op\":\"setChatHost\",\"chatId\":\"ch-1\",\"deviceId\":\"dev-2\"}",
        "{\"op\":\"setChatArchived\",\"chatId\":\"ch-1\",\"archived\":true}",
        "{\"op\":\"changeSidebarPin\",\"id\":\"ch-1\",\"pinned\":true}",
        "{\"op\":\"setAppearance\",\"mode\":\"dark\",\"light\":\"latte\",\"dark\":\"mocha\"}",
        "{\"op\":\"setChatConfig\",\"chatId\":\"ch-1\",\"config\":{\"harness\":\"graff\",\"model\":\"claude-opus-4-6\",\"reasoning\":\"high\"}}",
        "{\"op\":\"markChatSeen\",\"chatId\":\"ch-1\",\"at\":2000}",
        "{\"op\":\"renameDevice\",\"deviceId\":\"dev-src-parity\",\"name\":\"RenamedHost\"}",
        "{\"op\":\"forgetDevice\",\"deviceId\":\"dev-old\"}",
        "{\"op\":\"deleteChat\",\"chatId\":\"ch-1\"}",
        "{\"op\":\"deleteSpace\",\"spaceId\":\"sp-1\"}",
    };
    try testing.expectEqual(@as(usize, 17), mutate_payloads.len);
    for (mutate_payloads) |payload| {
        const p = try json.parseFromSliceLeaky(json.Value, a, payload, .{});
        const out = try host.handle("Mutate", p);
        defer gpa.free(out.unary_json);
        try testing.expect(out == .unary_json);
    }

    const command_payloads = [_][]const u8{
        "{\"chatId\":\"ch-cmd\",\"command\":{\"kind\":\"run\",\"messageId\":\"m-run\",\"request\":{\"prompt\":\"hi\"}}}",
        "{\"chatId\":\"ch-cmd\",\"command\":{\"kind\":\"steer\",\"messageId\":\"m-steer\",\"prompt\":\"steer now\"}}",
        "{\"chatId\":\"ch-cmd\",\"command\":{\"kind\":\"interrupt\"}}",
        "{\"chatId\":\"ch-cmd\",\"command\":{\"kind\":\"respondInput\",\"requestId\":\"req-1\",\"answers\":[]}}",
        "{\"chatId\":\"ch-cmd\",\"command\":{\"kind\":\"dismissInput\",\"requestId\":\"req-2\"}}",
    };
    try testing.expectEqual(@as(usize, 5), command_payloads.len);
    for (command_payloads) |payload| {
        const p = try json.parseFromSliceLeaky(json.Value, a, payload, .{});
        const out = try host.handle("QueueCommand", p);
        defer gpa.free(out.unary_json);
        try testing.expectEqualStrings("{\"queued\":true}", out.unary_json);
    }

    const edit_actions = [_][]const u8{ "commit", "cancel", "releaseUnchanged", "discard" };
    try testing.expectEqual(@as(usize, 4), edit_actions.len);
    {
        const q_p = try json.parseFromSliceLeaky(json.Value, a, "{\"chatId\":\"ch-cmd\",\"text\":\"queued\"}", .{});
        const q_out = try host.handle("QueueMessage", q_p);
        defer gpa.free(q_out.unary_json);
    }
    for (edit_actions) |act_name| {
        const b_p = try json.parseFromSliceLeaky(json.Value, a, "{\"chatId\":\"ch-cmd\",\"id\":\"row-parity\",\"editorDeviceId\":\"dev-1\",\"editorInstanceId\":\"inst-1\"}", .{});
        const b_out = try host.handle("BeginQueuedMessageEdit", b_p);
        defer gpa.free(b_out.unary_json);

        const f_str = try std.fmt.allocPrint(a, "{{\"chatId\":\"ch-cmd\",\"id\":\"row-parity\",\"leaseId\":\"lease-parity\",\"action\":\"{s}\",\"text\":\"edited\"}}", .{act_name});
        const f_p = try json.parseFromSliceLeaky(json.Value, a, f_str, .{});
        const f_out = try host.handle("FinishQueuedMessageEdit", f_p);
        defer gpa.free(f_out.unary_json);
        try testing.expectEqualStrings("{\"finished\":true}", f_out.unary_json);
    }
}

test "Warm-Doc LRU eviction and memory bound 1:1 parity with crates/engine/src/doc_host.rs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Verify constants against `crates/engine/src/doc_host.rs` and `crates/doc/src/constants.rs` directly from disk.
    const doc_host_rs = try std.Io.Dir.cwd().readFileAlloc(io, "../../crates/engine/src/doc_host.rs", a, .limited(512 * 1024));
    const doc_consts_rs = try std.Io.Dir.cwd().readFileAlloc(io, "../../crates/doc/src/constants.rs", a, .limited(64 * 1024));
    try testing.expect(std.mem.indexOf(u8, doc_host_rs, "const WARM_DOC_CAP: usize = 12;") != null);
    try testing.expect(std.mem.indexOf(u8, doc_consts_rs, "pub const DOC_LRU_BYTE_BUDGET: usize = 80 * 1024 * 1024;") != null);
    try testing.expect(std.mem.indexOf(u8, doc_host_rs, "const DOC_RESIDENT_FLOOR_BYTES: usize = 512 * 1024;") != null);
    try testing.expect(std.mem.indexOf(u8, doc_host_rs, "const RESIDENT_BYTES_PER_SNAPSHOT_BYTE: usize = 6;") != null);
    try testing.expect(std.mem.indexOf(u8, doc_host_rs, "const ACTIVE_SYNC_CAP: usize = 28;") != null);
    try testing.expectEqual(@as(usize, 12), EngineHost.warm_doc_cap);
    try testing.expectEqual(@as(usize, 80 * 1024 * 1024), EngineHost.doc_lru_byte_budget);
    try testing.expectEqual(@as(usize, 512 * 1024), EngineHost.doc_resident_floor_bytes);
    try testing.expectEqual(@as(usize, 6), EngineHost.resident_bytes_per_snapshot_byte);
    try testing.expectEqual(@as(usize, 28), EngineHost.active_sync_cap);

    // 2. Open 50 chats with messages while pinning 2 of them (`chat-0` and `chat-1`).
    var host = try EngineHost.init(gpa, "dev-lru", "LruParityHost");
    defer host.deinit();

    for (0..50) |idx| {
        const cid = try std.fmt.allocPrint(a, "chat-{d}", .{idx});
        const msg_id = try std.fmt.allocPrint(a, "msg-{d}", .{idx});
        const part_id = try std.fmt.allocPrint(a, "part-{d}", .{idx});
        const body = try std.fmt.allocPrint(a, "persisted message for {s}", .{cid});
        const doc = try host.getOrCreateDoc(cid);
        try doc.appendUserMessage(msg_id, part_id, body, @intCast(1000 + idx));

        if (idx == 0) {
            try host.registerWatch(9001, .doc_messages, cid);
        } else if (idx == 1) {
            try host.registerWatch(9002, .queue, cid);
        }
    }

    // Warm docs must be strictly capped at WARM_DOC_CAP = 12, with 38 evicted to DocsStore.
    try testing.expectEqual(@as(u32, 12), host.docs.count());
    try testing.expectEqual(@as(u64, 38), host.evicted_docs_total);
    try testing.expect(host.docs.contains("chat-0"));
    try testing.expect(host.docs.contains("chat-1"));
    try testing.expect(!host.docs.contains("chat-2"));
    try testing.expect(host.docs.contains("chat-49"));

    // 3. Reopening an evicted chat (`chat-2`) reloads its full snapshot losslessly from DocsStore.
    const reloaded = try host.getOrCreateDoc("chat-2");
    try testing.expectEqual(@as(usize, 1), reloaded.messages.items.len);
    try testing.expectEqualStrings("persisted message for chat-2", reloaded.messages.items[0].parts.items[0].text.items);
    try testing.expectEqual(@as(u32, 12), host.docs.count());

    // 4. Unpinning `chat-0` and `chat-1` allows them to be evicted when newer chats are accessed.
    host.cancelWatch(9001);
    host.cancelWatch(9002);
    try testing.expect(!host.isDocPinned("chat-0"));
    try testing.expect(!host.isDocPinned("chat-1"));
    _ = try host.getOrCreateDoc("chat-3");
    _ = try host.getOrCreateDoc("chat-4");
    try testing.expectEqual(@as(u32, 12), host.docs.count());
    try testing.expect(!host.docs.contains("chat-0"));
    try testing.expect(!host.docs.contains("chat-1"));
}
