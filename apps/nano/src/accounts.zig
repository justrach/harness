//! Settings › Accounts' rules, as pure functions (crates/ui/src/settings/
//! accounts.rs, crates/ui/src/codegraff_jobs.rs): the engine's replies read
//! into plain structs, the usage meters' thresholds, the reset moment, the
//! ChatGPT row's states, the sign-in dialog's titles, and the copy each
//! state shows.
const std = @import("std");
const json = std.json;
const rules = @import("rules.zig");
const Allocator = std.mem.Allocator;

/// `USAGE_WARN_FRACTION`, `USAGE_CRITICAL_FRACTION`.
pub const warn_fraction: f32 = 0.80;
pub const critical_fraction: f32 = 0.95;

/// `UsageLevel`: indigo (the accent), amber, red.
pub const Level = enum { normal, warn, critical };

pub fn usageLevel(fraction: f32) Level {
    return if (fraction >= critical_fraction) .critical else if (fraction >= warn_fraction) .warn else .normal;
}

/// Why a `ListAgentAccounts` load happens (`LoadTrigger`).
pub const Trigger = enum { mount, retry, refresh, post_login, post_action };

/// Whether a load asks the engine to probe usage (`force_usage_for`): all but
/// the re-list after Switch/Forget, which rides the warm cache.
pub fn forceUsage(t: Trigger) bool {
    return t != .post_action;
}

/// The agents with their own sign-ins here, as the engine names them.
pub const Harness = enum {
    claude_code,
    codex,
    cursor,
    graff,

    pub fn wire(h: Harness) []const u8 {
        return switch (h) {
            .claude_code => "claude-code",
            .codex => "codex",
            .cursor => "cursor",
            .graff => "graff",
        };
    }
};

/// The provider cards in order: harness, name, CLI command (`PROVIDERS`).
pub const Provider = struct { harness: Harness, name: []const u8, cli: []const u8 };
pub const providers = [_]Provider{
    .{ .harness = .claude_code, .name = "Claude Code", .cli = "claude" },
    .{ .harness = .codex, .name = "Codex", .cli = "codex" },
    .{ .harness = .cursor, .name = "Cursor", .cli = "cursor-agent" },
};

/// One CLI plan rate-limit window (`AgentUsageWindow`).
pub const Window = struct {
    label: []const u8,
    used_fraction: f32,
    resets_ms: ?i64 = null,
};

/// `AgentAccount`.
pub const Account = struct {
    id: []const u8,
    harness: []const u8,
    email: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    plan_label: ?[]const u8 = null,
    active: bool = false,
    switchable: bool = false,
    usage: []const Window = &.{},
    usage_error: ?[]const u8 = null,

    /// The row's title (`email`, else the display name).
    pub fn title(a: Account) []const u8 {
        return a.email orelse a.display_name orelse "Unknown account";
    }
};

pub const Warning = struct { harness: []const u8, message: []const u8 };

/// `AgentAccountsSnapshot`.
pub const Snapshot = struct {
    accounts: []const Account = &.{},
    warnings: []const Warning = &.{},
};

/// One `ListGraffLogins` row (`GraffLoginProvider`).
pub const GraffLogin = struct {
    id: []const u8,
    name: []const u8,
    signed_in: bool = false,
    account: ?[]const u8 = null,
    plan_usage: ?bool = null,
    display_name: ?[]const u8 = null,
    organization: ?[]const u8 = null,
    plan_label: ?[]const u8 = null,
    usage_windows: []const Window = &.{},
    prepaid_cents: ?i64 = null,
    reset_credits: ?f64 = null,
};

/// `CodegraffUsage`'s reply when signed in.
pub const Usage = struct {
    email: []const u8,
    tier: []const u8,
    credits_micro_usd: i64 = 0,
    spend_30d_micro_usd: i64 = 0,
    requests_30d: i64 = 0,
    key_budget_monthly_micro_usd: ?i64 = null,
    key_spend_monthly_micro_usd: i64 = 0,
    key_budget_resets_at: []const u8 = "",
};

/// A CodeGraff PR-agent run (`CodegraffJob`). `pr` as the place shows it.
pub const Job = struct {
    id: []const u8 = "",
    kind: []const u8 = "",
    status: []const u8 = "",
    cancellable: bool = false,
    step: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    pr: ?[]const u8 = null,
    title: ?[]const u8 = null,
    result_url: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// `AgentLoginMode`.
pub const Mode = enum { paste_code, browser, host_browser, device_code, relay_browser };

/// `StartAgentLogin`'s reply.
pub const Start = struct {
    login_id: []const u8,
    url: []const u8,
    mode: Mode,
    code: ?[]const u8 = null,
};

pub const PollStatus = enum { pending, done, @"error" };
pub const Poll = struct { status: PollStatus, message: ?[]const u8 = null };

// Reading the replies. Strings are copied into `ar`.

fn str(ar: Allocator, o: json.ObjectMap, key: []const u8) !?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) try ar.dupe(u8, v.string) else null;
}

fn flag(o: json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn number(o: json.ObjectMap, key: []const u8) ?f64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn int(o: json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn array(v: ?json.Value) []const json.Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn parseWindows(ar: Allocator, v: ?json.Value) ![]const Window {
    var windows: std.ArrayList(Window) = .empty;
    for (array(v)) |w| {
        if (w != .object) continue;
        const resets = try str(ar, w.object, "resetsAt");
        try windows.append(ar, .{
            .label = (try str(ar, w.object, "label")) orelse "",
            .used_fraction = @floatCast(number(w.object, "usedFraction") orelse 0),
            .resets_ms = if (resets) |r| rules.parseTime(r) else null,
        });
    }
    return windows.items;
}

pub fn parseSnapshot(ar: Allocator, v: json.Value) !Snapshot {
    if (v != .object) return error.Unexpected;
    var accounts: std.ArrayList(Account) = .empty;
    for (array(v.object.get("accounts"))) |item| {
        if (item != .object) continue;
        const o = item.object;
        try accounts.append(ar, .{
            .id = (try str(ar, o, "id")) orelse continue,
            .harness = (try str(ar, o, "harness")) orelse "",
            .email = try str(ar, o, "email"),
            .display_name = try str(ar, o, "displayName"),
            .plan_label = try str(ar, o, "planLabel"),
            .active = flag(o, "active"),
            .switchable = flag(o, "switchable"),
            .usage = try parseWindows(ar, o.get("usageWindows")),
            .usage_error = try str(ar, o, "usageError"),
        });
    }
    var warnings: std.ArrayList(Warning) = .empty;
    for (array(v.object.get("warnings"))) |item| {
        if (item != .object) continue;
        try warnings.append(ar, .{
            .harness = (try str(ar, item.object, "harness")) orelse "",
            .message = (try str(ar, item.object, "message")) orelse "",
        });
    }
    return .{ .accounts = accounts.items, .warnings = warnings.items };
}

pub fn parseGraffLogins(ar: Allocator, v: json.Value) ![]const GraffLogin {
    if (v != .array) return error.Unexpected;
    var out: std.ArrayList(GraffLogin) = .empty;
    for (v.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const plan = o.get("planUsage");
        try out.append(ar, .{
            .id = (try str(ar, o, "id")) orelse continue,
            .name = (try str(ar, o, "name")) orelse "",
            .signed_in = flag(o, "signedIn"),
            .account = try str(ar, o, "account"),
            .plan_usage = if (plan) |p| (if (p == .bool) p.bool else null) else null,
            .display_name = try str(ar, o, "displayName"),
            .organization = try str(ar, o, "organization"),
            .plan_label = try str(ar, o, "planLabel"),
            .usage_windows = try parseWindows(ar, o.get("usageWindows")),
            .prepaid_cents = int(o, "prepaidCents"),
            .reset_credits = number(o, "resetCredits"),
        });
    }
    return out.items;
}

/// `Option<CodegraffUsage>`: null when signed out.
pub fn parseUsage(ar: Allocator, v: json.Value) !?Usage {
    if (v == .null) return null;
    if (v != .object) return error.Unexpected;
    const o = v.object;
    return .{
        .email = (try str(ar, o, "email")) orelse "",
        .tier = (try str(ar, o, "tier")) orelse "",
        .credits_micro_usd = int(o, "credits_micro_usd") orelse 0,
        .spend_30d_micro_usd = int(o, "spend_30d_micro_usd") orelse 0,
        .requests_30d = int(o, "requests_30d") orelse 0,
        .key_budget_monthly_micro_usd = int(o, "key_budget_monthly_micro_usd"),
        .key_spend_monthly_micro_usd = int(o, "key_spend_monthly_micro_usd") orelse 0,
        .key_budget_resets_at = (try str(ar, o, "key_budget_resets_at")) orelse "",
    };
}

/// `Option<CodegraffJobs>`: null when signed out.
pub fn parseJobs(ar: Allocator, v: json.Value) !?[]const Job {
    if (v == .null) return null;
    if (v != .object) return error.Unexpected;
    var out: std.ArrayList(Job) = .empty;
    for (array(v.object.get("jobs"))) |item| {
        if (item != .object) continue;
        const o = item.object;
        const pr: ?[]const u8 = if (o.get("pr")) |p| switch (p) {
            .integer => |n| try std.fmt.allocPrint(ar, "#{d}", .{n}),
            .string => |s| if (s.len == 0) null else if (s[0] == '#') try ar.dupe(u8, s) else try std.fmt.allocPrint(ar, "#{s}", .{s}),
            else => null,
        } else null;
        try out.append(ar, .{
            .id = (try str(ar, o, "id")) orelse "",
            .kind = (try str(ar, o, "kind")) orelse "",
            .status = (try str(ar, o, "status")) orelse "",
            .cancellable = flag(o, "cancellable"),
            .step = try str(ar, o, "step"),
            .repo = try str(ar, o, "repo"),
            .pr = pr,
            .title = try str(ar, o, "title"),
            .result_url = try str(ar, o, "result_url"),
            .@"error" = try str(ar, o, "error"),
        });
    }
    return out.items;
}

pub fn parseStart(ar: Allocator, v: json.Value) !Start {
    if (v != .object) return error.Unexpected;
    const o = v.object;
    const mode_s = (try str(ar, o, "mode")) orelse return error.Unexpected;
    const modes = .{ .{ "paste-code", Mode.paste_code }, .{ "browser", Mode.browser }, .{ "host-browser", Mode.host_browser }, .{ "device-code", Mode.device_code }, .{ "relay-browser", Mode.relay_browser } };
    const mode: Mode = inline for (modes) |m| {
        if (std.mem.eql(u8, mode_s, m[0])) break m[1];
    } else return error.Unexpected;
    return .{
        .login_id = (try str(ar, o, "loginId")) orelse return error.Unexpected,
        .url = (try str(ar, o, "url")) orelse "",
        .mode = mode,
        .code = try str(ar, o, "code"),
    };
}

pub fn parsePoll(ar: Allocator, v: json.Value) !Poll {
    if (v != .object) return error.Unexpected;
    const s = (try str(ar, v.object, "status")) orelse return error.Unexpected;
    const status = std.meta.stringToEnum(PollStatus, s) orelse return error.Unexpected;
    return .{ .status = status, .message = try str(ar, v.object, "message") };
}

// The page's rules.

/// Whether `a` is `h`'s (`provider_accounts` filters by it, in the engine's
/// order: switching must not move a row).
pub fn isOf(a: Account, h: Harness) bool {
    return std.mem.eql(u8, a.harness, h.wire());
}

/// Maps a chat/account wire harness string to its usage-reporting provider.
pub fn providerHarness(harness_wire: []const u8) ?Harness {
    if (std.mem.eql(u8, harness_wire, "claude") or std.mem.eql(u8, harness_wire, "claude-code")) return .claude_code;
    if (std.mem.eql(u8, harness_wire, "codex")) return .codex;
    if (std.mem.eql(u8, harness_wire, "cursor")) return .cursor;
    return null;
}

/// Human-readable provider title for account usage headers.
pub fn providerName(h: Harness) []const u8 {
    return switch (h) {
        .claude_code => "Claude Code",
        .codex => "Codex",
        .cursor => "Cursor",
        .graff => "graff",
    };
}

/// Whether `harness_wire` reports rate-limit usage windows.
pub fn reportsUsage(harness_wire: []const u8) bool {
    return providerHarness(harness_wire) != null;
}

fn matchesProvider(acc: Account, h: Harness) bool {
    return providerHarness(acc.harness) == h;
}

/// Maximum clamped usage fraction across `acc.usage`, or null when empty.
pub fn usedFraction(acc: Account) ?f32 {
    if (acc.usage.len == 0) return null;
    var best: f32 = 0;
    for (acc.usage) |w| {
        best = @max(best, std.math.clamp(w.used_fraction, 0, 1));
    }
    return best;
}

/// Whether a Cursor model draws from the first-party Cursor pool rather than Other.
pub fn cursorModelIsFirstParty(model: []const u8) bool {
    const m = std.mem.trim(u8, model, " \t\n\r");
    const prefixes = [_][]const u8{ "default", "auto", "composer", "vega", "grok", "cursor-grok" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, m, prefix) and (m.len == prefix.len or m[prefix.len] == '-' or m[prefix.len] == '.')) {
            return true;
        }
    }
    return false;
}

/// Fraction shown on the footer ring for `(harness_wire, model)`.
/// Cursor prefers the pool matching `model` ("Cursor" vs "Other") before falling back to `usedFraction`.
pub fn ringFraction(acc: Account, harness_wire: []const u8, model: ?[]const u8) ?f32 {
    if (providerHarness(harness_wire) == .cursor) {
        if (model) |raw| {
            const m = std.mem.trim(u8, raw, " \t\n\r");
            if (m.len > 0) {
                const want = if (cursorModelIsFirstParty(m)) "Cursor" else "Other";
                for (acc.usage) |w| {
                    if (std.mem.eql(u8, w.label, want)) return std.math.clamp(w.used_fraction, 0, 1);
                }
            }
        }
    }
    return usedFraction(acc);
}

/// Extracts the graff route prefix before `'/'` or `':'` (e.g. `"codex"`, `"chatgpt-new"`).
pub fn graffRoute(model: ?[]const u8) ?[]const u8 {
    const raw = model orelse return null;
    const sep = std.mem.indexOfAny(u8, raw, "/:") orelse return null;
    if (sep == 0) return null;
    return raw[0..sep];
}

pub fn graffLoginToAccount(alloc: Allocator, g: GraffLogin, active: bool) Account {
    const plan_label: ?[]const u8 = if (g.account != null) blk: {
        break :blk if (g.plan_label) |pl|
            (std.fmt.allocPrint(alloc, "{s} \u{00b7} {s}", .{ g.name, pl }) catch pl)
        else
            g.name;
    } else g.plan_label;
    return .{
        .id = g.id,
        .harness = "graff",
        .email = g.account,
        .display_name = g.display_name orelse g.name,
        .plan_label = plan_label,
        .active = active,
        .switchable = false,
        .usage = g.usage_windows,
    };
}

fn findSignedInGraffWithUsage(logins: ?[]const GraffLogin, id: []const u8) ?GraffLogin {
    const rows = logins orelse return null;
    for (rows) |g| {
        if (g.signed_in and g.usage_windows.len > 0 and std.mem.eql(u8, g.id, id)) return g;
    }
    return null;
}

fn activeCliAccountWithUsage(snap: ?Snapshot, h: Harness) ?Account {
    const s = snap orelse return null;
    for (s.accounts) |acc| {
        if (matchesProvider(acc, h) and acc.active and acc.usage.len > 0) return acc;
    }
    return null;
}

pub fn graffActiveAccount(alloc: Allocator, snap: ?Snapshot, logins: ?[]const GraffLogin, model: ?[]const u8) ?Account {
    if (graffRoute(model)) |route| {
        if (std.mem.eql(u8, route, "codex")) {
            if (activeCliAccountWithUsage(snap, .codex)) |acc| return acc;
            if (findSignedInGraffWithUsage(logins, "chatgpt-new")) |g| return graffLoginToAccount(alloc, g, true);
            return null;
        }
        if (std.mem.eql(u8, route, "chatgpt-new")) {
            if (findSignedInGraffWithUsage(logins, "chatgpt-new")) |g| return graffLoginToAccount(alloc, g, true);
            if (activeCliAccountWithUsage(snap, .codex)) |acc| return acc;
            return null;
        }
        if (std.mem.eql(u8, route, "claude-agent")) {
            if (findSignedInGraffWithUsage(logins, "claude-agent")) |g| return graffLoginToAccount(alloc, g, true);
            if (activeCliAccountWithUsage(snap, .claude_code)) |acc| return acc;
            return null;
        }
        if (std.mem.eql(u8, route, "anthropic")) {
            if (findSignedInGraffWithUsage(logins, "anthropic")) |g| return graffLoginToAccount(alloc, g, true);
            return null;
        }
        if (std.mem.eql(u8, route, "xai") or std.mem.eql(u8, route, "grok")) {
            if (findSignedInGraffWithUsage(logins, "xai")) |g| return graffLoginToAccount(alloc, g, true);
            return null;
        }
        if (findSignedInGraffWithUsage(logins, route)) |g| return graffLoginToAccount(alloc, g, true);
        return null;
    }
    if (logins) |rows| {
        for (rows) |g| {
            if (g.signed_in and g.usage_windows.len > 0) return graffLoginToAccount(alloc, g, true);
        }
    }
    return null;
}

pub fn graffMatchingAccounts(alloc: Allocator, snap: ?Snapshot, logins: ?[]const GraffLogin, model: ?[]const u8) []Account {
    const chosen = graffActiveAccount(alloc, snap, logins, model);
    var out: std.ArrayList(Account) = .empty;
    if (logins) |rows| {
        for (rows) |g| {
            if (!g.signed_in or g.usage_windows.len == 0) continue;
            const is_active = if (chosen) |ch| std.mem.eql(u8, ch.harness, "graff") and std.mem.eql(u8, ch.id, g.id) else false;
            out.append(alloc, graffLoginToAccount(alloc, g, is_active)) catch {};
        }
    }
    if (snap) |s| if (graffRoute(model)) |route| {
        const cli_harness: ?Harness = if (std.mem.eql(u8, route, "codex"))
            .codex
        else if (std.mem.eql(u8, route, "claude-agent"))
            .claude_code
        else
            null;
        if (cli_harness) |h| {
            for (s.accounts) |acc| {
                if (!matchesProvider(acc, h)) continue;
                var item = acc;
                if (chosen) |ch| {
                    item.active = std.mem.eql(u8, ch.harness, acc.harness) and std.mem.eql(u8, ch.id, acc.id);
                }
                out.append(alloc, item) catch {};
            }
        }
    };
    return out.toOwnedSlice(alloc) catch &.{};
}

/// First active account belonging to `harness_wire`'s provider.
pub fn activeAccountForHarness(snap: Snapshot, harness_wire: []const u8) ?Account {
    const h = providerHarness(harness_wire) orelse return null;
    for (snap.accounts) |acc| {
        if (matchesProvider(acc, h) and acc.active) return acc;
    }
    return null;
}

/// Optimistically flips `active` inside `harness_wire` without reordering rows.
pub fn markSwitched(items: []Account, id: []const u8, harness_wire: []const u8) void {
    const h = providerHarness(harness_wire) orelse return;
    var found = false;
    for (items) |acc| {
        if (matchesProvider(acc, h) and std.mem.eql(u8, acc.id, id)) {
            found = true;
            break;
        }
    }
    if (!found) return;
    for (items) |*acc| {
        if (matchesProvider(acc.*, h)) acc.active = std.mem.eql(u8, acc.id, id);
    }
}

/// Joins each window's label and formatted reset time with ` · ` for tooltips.
pub fn usageResets(ar: Allocator, windows: []const Window, now_ms: i64, fixed_offset_s: ?i64) []const u8 {
    if (windows.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    for (windows, 0..) |w, i| {
        if (i > 0) out.appendSlice(ar, " \u{00b7} ") catch return out.items;
        if (w.resets_ms) |at| {
            const off = fixed_offset_s orelse localOffset(at);
            var buf: [48]u8 = undefined;
            if (formatReset(&buf, at, now_ms, off)) |reset_str| {
                const part = std.fmt.allocPrint(ar, "{s}: {s}", .{ w.label, reset_str }) catch continue;
                out.appendSlice(ar, part) catch {};
            } else {
                out.appendSlice(ar, w.label) catch {};
            }
        } else {
            out.appendSlice(ar, w.label) catch {};
        }
    }
    return out.toOwnedSlice(ar) catch out.items;
}

pub fn countOf(s: Snapshot, h: Harness) usize {
    var n: usize = 0;
    for (s.accounts) |a| if (isOf(a, h)) {
        n += 1;
    };
    return n;
}

/// graff's OpenAI sign-in is the Codex login: it follows the active Codex
/// account (`openai_login`).
pub const OpenAi = struct { signed_in: bool, who: ?[]const u8 };
pub fn openaiLogin(s: Snapshot) OpenAi {
    for (s.accounts) |a| if (isOf(a, .codex) and a.active) return .{ .signed_in = true, .who = a.email orelse a.display_name };
    return .{ .signed_in = false, .who = null };
}

/// `GRAFF_LOGIN_PROVIDERS`' names.
const graff_names = [_][2][]const u8{
    .{ "xai", "xAI" },
    .{ "kimi", "Kimi" },
    .{ "zai", "Z.AI" },
    .{ "chatgpt-new", "ChatGPT" },
    .{ "anthropic", "Anthropic Console" },
    .{ "claude-agent", "Claude Agent" },
};

/// A graff provider's name for the sign-in dialog (`graff_provider_name`).
pub fn graffProviderName(id: ?[]const u8) []const u8 {
    const want = id orelse return "graff";
    for (graff_names) |n| if (std.mem.eql(u8, n[0], want)) return n[1];
    return "graff";
}

/// The dialog's title (`LoginFlow::title`).
pub fn loginTitle(buf: []u8, h: Harness, provider: ?[]const u8, reauthenticate: bool) []const u8 {
    return switch (h) {
        .codex => if (reauthenticate) "Sign in to ChatGPT (Codex)" else "Add Codex account",
        .cursor => "Connect Cursor",
        .graff => std.fmt.bufPrint(buf, "Sign in to {s}", .{graffProviderName(provider)}) catch "Sign in",
        .claude_code => "Add Claude account",
    };
}

/// graff's ChatGPT (plan) sign-in as its row shows it (`ChatgptPlanRow`).
pub const Chatgpt = union(enum) {
    /// The listing hasn't loaded, or failed.
    unknown,
    signed_out,
    ready: ?[]const u8,
    plan_off: ?[]const u8,

    pub fn rowFromListing(rows: ?[]const GraffLogin) ?GraffLogin {
        const list = rows orelse return null;
        for (list) |r| if (std.mem.eql(u8, r.id, "chatgpt-new")) return r;
        return null;
    }

    pub fn fromListing(rows: ?[]const GraffLogin) Chatgpt {
        const r = rowFromListing(rows) orelse return if (rows == null) .unknown else .signed_out;
        if (r.signed_in) return .{ .ready = r.account };
        if (r.plan_usage) |p| if (!p) return .{ .plan_off = r.account };
        return .signed_out;
    }

    pub fn status(row: Chatgpt, buf: []u8) []const u8 {
        return switch (row) {
            .unknown => "Separate from Codex · graff login chatgpt-new",
            .signed_out => "Not signed in · separate from Codex",
            .ready => |who| (if (who) |w| std.fmt.bufPrint(buf, "Signed in as {s} · using your ChatGPT plan", .{w}) else std.fmt.bufPrint(buf, "Signed in · using your ChatGPT plan", .{})) catch "",
            .plan_off => |who| (if (who) |w| std.fmt.bufPrint(buf, "Signed in as {s} · plan usage is off. Continue with ChatGPT and allow it, or use an OpenAI API key (graff key set openai).", .{w}) else std.fmt.bufPrint(buf, "Signed in · plan usage is off. Continue with ChatGPT and allow it, or use an OpenAI API key (graff key set openai).", .{})) catch "",
        };
    }
};

/// A graff provider row's line.
pub fn graffStatus(buf: []u8, p: GraffLogin) []const u8 {
    if (!p.signed_in) return "Not signed in";
    const head = if (p.account) |who|
        std.fmt.bufPrint(buf, "Signed in as {s}", .{who}) catch return "Signed in"
    else
        std.fmt.bufPrint(buf, "Signed in on this device", .{}) catch return "Signed in";
    var len = head.len;
    if (p.organization) |org| {
        if (std.fmt.bufPrint(buf[len..], " \u{00b7} {s}", .{org})) |tail| {
            len += tail.len;
        } else |_| {}
    }
    if (p.prepaid_cents) |cents| if (cents > 0) {
        const dollars = @divTrunc(cents, 100);
        const rem_cents: u64 = @intCast(@rem(cents, 100));
        if (std.fmt.bufPrint(buf[len..], " \u{00b7} ${d}.{d:0>2} prepaid", .{ dollars, rem_cents })) |tail| {
            len += tail.len;
        } else |_| {}
    };
    return buf[0..len];
}

/// The legacy Codex login's line under graff's providers.
pub fn openaiStatus(buf: []u8, s: ?Snapshot) []const u8 {
    const snap = s orelse return "Checking…";
    const o = openaiLogin(snap);
    if (!o.signed_in) return "Not signed in — add a Codex account below";
    const who = o.who orelse return "Credentials stored · legacy Codex login";
    return std.fmt.bufPrint(buf, "Credentials stored for {s} · legacy Codex login", .{who}) catch "";
}

/// What an empty provider card says.
pub fn emptyCopy(buf: []u8, p: Provider) []const u8 {
    return (if (p.harness == .cursor)
        std.fmt.bufPrint(buf, "{s} isn't connected on this device — connect it to run Cursor sessions.", .{p.name})
    else
        std.fmt.bufPrint(buf, "No {s} login detected on this device — sign in with \u{201C}{s}\u{201D} or add an account.", .{ p.name, p.cli })) catch "";
}

/// An avatar's letter: the first character, upper case, or "?".
pub fn initial(buf: *[4]u8, s: []const u8) []const u8 {
    if (s.len == 0) return "?";
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return "?";
    if (n == 1) {
        buf[0] = std.ascii.toUpper(s[0]);
        return buf[0..1];
    }
    if (n > s.len) return "?";
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// "$12.34", with more places for small amounts (`format_micro_usd`).
pub fn formatMicroUsd(buf: []u8, amount: i64) []const u8 {
    const dollars: f64 = @as(f64, @floatFromInt(amount)) / 1_000_000.0;
    const a = @abs(dollars);
    return (if (a < 0.01)
        std.fmt.bufPrint(buf, "${d:.6}", .{dollars})
    else if (a < 1.0)
        std.fmt.bufPrint(buf, "${d:.4}", .{dollars})
    else
        std.fmt.bufPrint(buf, "${d:.2}", .{dollars})) catch "";
}

/// The key budget's meter, when there's a budget.
pub fn budgetWindow(u: Usage) ?Window {
    const limit = u.key_budget_monthly_micro_usd orelse return null;
    const fraction: f32 = if (limit <= 0) 1 else @floatCast(std.math.clamp(@as(f64, @floatFromInt(u.key_spend_monthly_micro_usd)) / @as(f64, @floatFromInt(limit)), 0, 1));
    return .{ .label = "Key budget", .used_fraction = fraction, .resets_ms = rules.parseTime(u.key_budget_resets_at) };
}

/// "NN% used".
pub fn percentUsed(buf: []u8, fraction: f32) []const u8 {
    const f = std.math.clamp(fraction, 0, 1);
    return std.fmt.bufPrint(buf, "{d}% used", .{@as(u32, @intFromFloat(@round(f * 100)))}) catch "";
}

const day_ms: i64 = 86_400_000;

/// The reset moment, absolute (`format_reset`): a clock time within ~22
/// hours, a weekday within a week, else month and day. `offset_s` is the
/// local zone's offset from UTC at that moment.
pub fn formatReset(buf: []u8, resets_ms: ?i64, now_ms: i64, offset_s: i64) ?[]const u8 {
    const at = resets_ms orelse return null;
    // chrono's `num_hours` truncates toward zero.
    const hours = @divTrunc(at - now_ms, 3_600_000);
    const local = at + offset_s * 1000;
    const days = @divFloor(local, day_ms);
    const in_day = @mod(local, day_ms);
    if (hours < 22) {
        const h = @divFloor(in_day, 3_600_000);
        const m = @divFloor(@mod(in_day, 3_600_000), 60_000);
        const h12 = if (@mod(h, 12) == 0) 12 else @mod(h, 12);
        return std.fmt.bufPrint(buf, "resets {d}:{d:0>2} {s}", .{ @as(u64, @intCast(h12)), @as(u64, @intCast(m)), if (h < 12) "AM" else "PM" }) catch null;
    }
    if (hours < 24 * 7) {
        const names = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
        return std.fmt.bufPrint(buf, "resets {s}", .{names[@intCast(@mod(days, 7))]}) catch null;
    }
    const md = monthDay(days);
    return std.fmt.bufPrint(buf, "resets {s} {d}", .{ month_names[md.month - 1], md.day }) catch null;
}

pub const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// The civil month and day of a day count from 1970-01-01 (Hinnant).
pub fn monthDay(days: i64) struct { month: u8, day: u8 } {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .month = @intCast(m), .day = @intCast(d) };
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;

/// The local zone's offset from UTC, in seconds, at `at_ms`.
pub fn localOffset(at_ms: i64) i64 {
    if (comptime @import("builtin").os.tag == .windows) return 0;
    const t: c_long = @intCast(@divFloor(at_ms, 1000));
    var tm: Tm = undefined;
    _ = localtime_r(&t, &tm) orelse return 0;
    return tm.gmtoff;
}

/// Still queued or running (`job_active`).
pub fn jobActive(j: Job) bool {
    const s = j.status;
    return std.mem.eql(u8, s, "queued") or std.mem.eql(u8, s, "pending") or std.mem.eql(u8, s, "running");
}

fn jobKind(j: Job) []const u8 {
    if (std.mem.eql(u8, j.kind, "pr_review")) return "PR review";
    if (std.mem.eql(u8, j.kind, "pr_describe")) return "PR description";
    return "PR agent job";
}

fn nonBlank(s: ?[]const u8) ?[]const u8 {
    const x = s orelse return null;
    return if (std.mem.trim(u8, x, " \t\n").len == 0) null else x;
}

/// A job row's title and "repo #pr · status" line (`job_summary`).
pub fn jobSummary(ar: Allocator, j: Job) !struct { title: []const u8, detail: []const u8 } {
    const kind = jobKind(j);
    const s = j.status;
    const eq = std.mem.eql;
    const status: []const u8 = if (eq(u8, s, "queued") or eq(u8, s, "pending"))
        "Queued"
    else if (eq(u8, s, "running")) blk: {
        const step = j.step orelse "";
        break :blk if (eq(u8, step, "reviewing")) "Reviewing…" else if (eq(u8, step, "describing")) "Describing…" else if (eq(u8, step, "posting")) "Posting…" else if (eq(u8, step, "working")) "Working…" else "Starting…";
    } else if (eq(u8, s, "completed"))
        "Done"
    else if (eq(u8, s, "cancelled"))
        "Cancelled"
    else if (eq(u8, s, "error"))
        (if (nonBlank(j.@"error")) |e| try std.fmt.allocPrint(ar, "Failed: {s}", .{e}) else "Failed")
    else
        s;
    const place: []const u8 = if (j.repo != null and j.pr != null)
        try std.fmt.allocPrint(ar, "{s} {s}", .{ j.repo.?, j.pr.? })
    else
        j.repo orelse j.pr orelse "";
    return .{
        .title = nonBlank(j.title) orelse kind,
        .detail = try std.fmt.allocPrint(ar, "{s} · {s}", .{ if (place.len == 0) kind else place, status }),
    };
}

const testing = std.testing;

fn parsed(text: []const u8) !json.Parsed(json.Value) {
    return json.parseFromSlice(json.Value, testing.allocator, text, .{});
}

test "the ChatGPT row is ready only with plan usage" {
    try testing.expect(Chatgpt.fromListing(null) == .unknown);
    try testing.expect(Chatgpt.fromListing(&.{}) == .signed_out);
    try testing.expect(Chatgpt.fromListing(&.{.{ .id = "chatgpt-new", .name = "ChatGPT" }}) == .signed_out);
    var buf: [256]u8 = undefined;
    const ready = Chatgpt.fromListing(&.{.{ .id = "chatgpt-new", .name = "ChatGPT", .signed_in = true, .plan_usage = true, .account = "a@b.c" }});
    try testing.expectEqualStrings("Signed in as a@b.c · using your ChatGPT plan", ready.status(&buf));
    const off = Chatgpt.fromListing(&.{.{ .id = "chatgpt-new", .name = "ChatGPT", .plan_usage = false, .account = "a@b.c" }});
    try testing.expect(off == .plan_off);
    try testing.expect(std.mem.startsWith(u8, off.status(&buf), "Signed in as a@b.c · plan usage is off."));
    try testing.expect(std.mem.indexOf(u8, off.status(&buf), "or use an") != null);
    try testing.expectEqualStrings("Separate from Codex · graff login chatgpt-new", Chatgpt.status(.unknown, &buf));
}

test "job rows name the PR and where the run is" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const p = try parsed(
        \\{"jobs": [
        \\ {"id": "j1", "kind": "pr_review", "status": "running", "step": "posting", "cancellable": false, "repo": "acme/api", "pr": 42, "title": "Fix login", "unknown_field": true},
        \\ {"id": "j2", "kind": "pr_describe", "status": "error", "error": "no access"},
        \\ {"id": "j3", "status": "pending", "pr": "#7"}]}
    );
    defer p.deinit();
    const jobs = (try parseJobs(ar, p.value)).?;
    try testing.expect(jobActive(jobs[0]));
    const running = try jobSummary(ar, jobs[0]);
    try testing.expectEqualStrings("Fix login", running.title);
    try testing.expectEqualStrings("acme/api #42 · Posting…", running.detail);
    // No title falls back to the kind; a failure carries its reason.
    try testing.expect(!jobActive(jobs[1]));
    const failed = try jobSummary(ar, jobs[1]);
    try testing.expectEqualStrings("PR description", failed.title);
    try testing.expectEqualStrings("PR description · Failed: no access", failed.detail);
    try testing.expect(jobActive(jobs[2]));
    try testing.expectEqualStrings("#7 · Queued", (try jobSummary(ar, jobs[2])).detail);
    try testing.expect((try parseJobs(ar, .null)) == null);
}

test "the visit's first load forces the usage probe; Switch and Forget don't" {
    try testing.expect(forceUsage(.mount));
    try testing.expect(forceUsage(.retry));
    try testing.expect(forceUsage(.refresh));
    try testing.expect(forceUsage(.post_login));
    try testing.expect(!forceUsage(.post_action));
}

test "usage thresholds match Harness" {
    try testing.expectEqual(Level.normal, usageLevel(0));
    try testing.expectEqual(Level.normal, usageLevel(0.79));
    try testing.expectEqual(Level.warn, usageLevel(0.80));
    try testing.expectEqual(Level.warn, usageLevel(0.94));
    try testing.expectEqual(Level.critical, usageLevel(0.95));
    try testing.expectEqual(Level.critical, usageLevel(1));
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("42% used", percentUsed(&buf, 0.4249));
    try testing.expectEqualStrings("100% used", percentUsed(&buf, 1.3));
}

test "the reset moment is absolute: a clock time, a weekday, then month and day" {
    var buf: [32]u8 = undefined;
    // Thursday 2026-10-01 10:00 UTC.
    const now: i64 = rules.parseTime("2026-10-01T10:00:00Z").?;
    try testing.expect(formatReset(&buf, null, now, 0) == null);
    try testing.expectEqualStrings("resets 12:05 PM", formatReset(&buf, now + 125 * 60_000, now, 0).?);
    try testing.expectEqualStrings("resets 3:05 AM", formatReset(&buf, now + 125 * 60_000, now, -9 * 3600).?);
    try testing.expectEqualStrings("resets Sun", formatReset(&buf, now + 3 * day_ms, now, 0).?);
    try testing.expectEqualStrings("resets Oct 27", formatReset(&buf, now + 26 * day_ms, now, 0).?);
}

test "accounts keep the engine's order per provider; graff's OpenAI row follows the active Codex account" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parsed(
        \\{"accounts": [
        \\ {"id": "c1", "harness": "claude-code", "email": null, "planLabel": null, "active": false, "switchable": true},
        \\ {"id": "x1", "harness": "codex", "email": "a@x.test", "planLabel": "Plus", "active": false},
        \\ {"id": "c2", "harness": "claude-code", "email": "c@x.test", "planLabel": "Max", "active": true,
        \\  "usageWindows": [{"label": "5h", "usedFraction": 0.5, "resetsAt": "2026-10-01T12:00:00Z"}]}],
        \\ "warnings": [{"harness": "codex", "message": "Keychain said no"}]}
    );
    defer p.deinit();
    const s = try parseSnapshot(arena.allocator(), p.value);
    try testing.expectEqualStrings("c1", s.accounts[0].id);
    try testing.expectEqualStrings("c2", s.accounts[2].id);
    try testing.expectEqual(@as(usize, 2), countOf(s, .claude_code));
    try testing.expectEqual(@as(usize, 1), countOf(s, .codex));
    try testing.expectEqual(@as(usize, 0), countOf(s, .cursor));
    try testing.expectEqualStrings("Unknown account", s.accounts[0].title());
    try testing.expectEqual(@as(f32, 0.5), s.accounts[2].usage[0].used_fraction);
    try testing.expectEqual(rules.parseTime("2026-10-01T12:00:00Z"), s.accounts[2].usage[0].resets_ms);
    try testing.expectEqualStrings("Keychain said no", s.warnings[0].message);
    // Saved but not live: graff reads the live login, so not signed in.
    try testing.expect(!openaiLogin(s).signed_in);
    try testing.expect(!openaiLogin(.{}).signed_in);
    const live: Snapshot = .{ .accounts = &.{ .{ .id = "x1", .harness = "codex", .email = "a@x.test" }, .{ .id = "x2", .harness = "codex", .email = "b@x.test", .active = true } } };
    try testing.expectEqualStrings("b@x.test", openaiLogin(live).who.?);
    // A live login with no email still counts as signed in.
    const anonymous: Snapshot = .{ .accounts = &.{.{ .id = "x3", .harness = "codex", .active = true }} };
    try testing.expect(openaiLogin(anonymous).signed_in);
    try testing.expect(openaiLogin(anonymous).who == null);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("Credentials stored · legacy Codex login", openaiStatus(&buf, anonymous));
    try testing.expectEqualStrings("Checking…", openaiStatus(&buf, null));
}

test "sign-in dialog titles name the graff provider" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Sign in to xAI", loginTitle(&buf, .graff, "xai", false));
    try testing.expectEqualStrings("Sign in to Kimi", loginTitle(&buf, .graff, "kimi", false));
    try testing.expectEqualStrings("Sign in to Z.AI", loginTitle(&buf, .graff, "zai", false));
    try testing.expectEqualStrings("Sign in to ChatGPT", loginTitle(&buf, .graff, "chatgpt-new", false));
    try testing.expectEqualStrings("Sign in to graff", loginTitle(&buf, .graff, null, false));
    try testing.expectEqualStrings("Sign in to graff", loginTitle(&buf, .graff, "nope", false));
    try testing.expectEqualStrings("Add Codex account", loginTitle(&buf, .codex, null, false));
    try testing.expectEqualStrings("Sign in to ChatGPT (Codex)", loginTitle(&buf, .codex, null, true));
    try testing.expectEqualStrings("Connect Cursor", loginTitle(&buf, .cursor, null, false));
    try testing.expectEqualStrings("Add Claude account", loginTitle(&buf, .claude_code, null, false));
}

test "CodeGraff usage, money, the key budget, avatars and empty copy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = try parsed(
        \\{"email": "ada@example.com", "tier": "Pro", "credits_micro_usd": 12340000, "spend_30d_micro_usd": 5000,
        \\ "requests_30d": 31, "key_budget_monthly_micro_usd": 20000000, "key_spend_monthly_micro_usd": 5000000,
        \\ "key_budget_resets_at": "2026-11-01T00:00:00Z"}
    );
    defer p.deinit();
    const u = (try parseUsage(arena.allocator(), p.value)).?;
    try testing.expectEqualStrings("Pro", u.tier);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("$12.34", formatMicroUsd(&buf, u.credits_micro_usd));
    try testing.expectEqualStrings("$0.005000", formatMicroUsd(&buf, u.spend_30d_micro_usd));
    try testing.expectEqualStrings("$0.5000", formatMicroUsd(&buf, 500_000));
    try testing.expectEqual(@as(f32, 0.25), budgetWindow(u).?.used_fraction);
    try testing.expect((try parseUsage(arena.allocator(), .null)) == null);
    var ib: [4]u8 = undefined;
    try testing.expectEqualStrings("A", initial(&ib, "ada@example.com"));
    try testing.expectEqualStrings("?", initial(&ib, ""));
    try testing.expectEqualStrings("No Codex login detected on this device — sign in with \u{201C}codex\u{201D} or add an account.", emptyCopy(&buf, providers[1]));
    try testing.expectEqualStrings("Cursor isn't connected on this device — connect it to run Cursor sessions.", emptyCopy(&buf, providers[2]));
}

test "a login's start and poll replies" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try parsed(
        \\{"loginId": "l1", "url": "https://example.com/oauth", "mode": "paste-code"}
    );
    defer s.deinit();
    const start = try parseStart(arena.allocator(), s.value);
    try testing.expectEqual(Mode.paste_code, start.mode);
    try testing.expectEqualStrings("l1", start.login_id);
    const q = try parsed(
        \\{"status": "pending", "message": "Still waiting"}
    );
    defer q.deinit();
    const poll = try parsePoll(arena.allocator(), q.value);
    try testing.expectEqual(PollStatus.pending, poll.status);
    try testing.expectEqualStrings("Still waiting", poll.message.?);
}

test "account usage rules: error parsing, ring fractions, Cursor pools, optimistic switch, and reset tooltip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const p = try parsed(
        \\{"accounts": [
        \\ {"id": "c1", "harness": "claude-code", "email": "first@example.com", "active": true, "switchable": true,
        \\  "usageWindows": [{"label": "5h", "usedFraction": 0.24, "resetsAt": "2026-10-01T12:05:00Z"},
        \\                   {"label": "7d", "usedFraction": 1.30, "resetsAt": "2026-10-04T10:00:00Z"}]},
        \\ {"id": "c2", "harness": "claude-code", "email": "second@example.com", "active": false, "switchable": true,
        \\  "usageError": "Rate limit probe timed out"},
        \\ {"id": "cu1", "harness": "cursor", "email": "dev@example.com", "active": true, "switchable": false,
        \\  "usageWindows": [{"label": "Cursor", "usedFraction": 0.18}, {"label": "Other", "usedFraction": 0.72}]},
        \\ {"id": "cu2", "harness": "cursor", "email": "month@example.com", "active": false, "switchable": false,
        \\  "usageWindows": [{"label": "Month", "usedFraction": -0.2}]}
        \\]}
    );
    defer p.deinit();
    const s = try parseSnapshot(ar, p.value);

    try testing.expect(reportsUsage("claude"));
    try testing.expect(reportsUsage("claude-code"));
    try testing.expect(reportsUsage("codex"));
    try testing.expect(reportsUsage("cursor"));
    try testing.expect(!reportsUsage("graff"));
    try testing.expectEqualStrings("Claude Code", providerName(providerHarness("claude").?));
    try testing.expectEqualStrings("Rate limit probe timed out", s.accounts[1].usage_error.?);

    try testing.expectEqual(@as(?f32, 1.0), usedFraction(s.accounts[0]));
    try testing.expectEqual(@as(?f32, null), usedFraction(s.accounts[1]));
    try testing.expectEqual(@as(?f32, 0.0), usedFraction(s.accounts[3]));

    try testing.expect(cursorModelIsFirstParty("composer-2.5"));
    try testing.expect(cursorModelIsFirstParty("grok-4.7"));
    try testing.expect(cursorModelIsFirstParty("default"));
    try testing.expect(!cursorModelIsFirstParty("grokker-1"));
    try testing.expect(!cursorModelIsFirstParty("claude-opus-5-5"));
    try testing.expect(!cursorModelIsFirstParty("gpt-5.5"));

    try testing.expectEqual(@as(?f32, 0.18), ringFraction(s.accounts[2], "cursor", "composer-2.5"));
    try testing.expectEqual(@as(?f32, 0.72), ringFraction(s.accounts[2], "cursor", "claude-opus-5-5"));
    try testing.expectEqual(@as(?f32, 0.0), ringFraction(s.accounts[3], "cursor", "claude-opus-5-5"));

    try testing.expectEqualStrings("c1", activeAccountForHarness(s, "claude").?.id);
    markSwitched(@constCast(s.accounts), "c2", "claude-code");
    try testing.expect(!s.accounts[0].active);
    try testing.expect(s.accounts[1].active);
    try testing.expect(s.accounts[2].active); // unrelated harness untouched
    try testing.expectEqualStrings("c2", activeAccountForHarness(s, "claude-code").?.id);
    // Switching to an unknown id leaves active accounts untouched.
    markSwitched(@constCast(s.accounts), "missing", "claude-code");
    try testing.expect(s.accounts[1].active);

    const now_ms = rules.parseTime("2026-10-01T10:00:00Z").?;
    const tip = usageResets(ar, s.accounts[0].usage, now_ms, 0);
    try testing.expectEqualStrings("5h: resets 12:05 PM \u{00b7} 7d: resets Sun", tip);
    try testing.expectEqualStrings("Cursor \u{00b7} Other", usageResets(ar, s.accounts[2].usage, now_ms, 0));
    try testing.expectEqualStrings("", usageResets(ar, &.{}, now_ms, 0));
}

test "graff login metadata parsing, organization/prepaid status, and provider name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const p = try parsed(
        \\[
        \\ {"id":"xai","name":"xAI","signedIn":true,"account":"ada@example.test","planLabel":"SuperGrok Heavy","prepaidCents":1250,"resetCredits":50.0,
        \\  "usageWindows":[{"label":"Credits","usedFraction":0.35,"resetsAt":"2027-02-01T00:00:00Z"}]},
        \\ {"id":"anthropic","name":"Anthropic Console","signedIn":true,"account":"ops@acme.test","organization":"Acme Labs","planLabel":"Max",
        \\  "usageWindows":[{"label":"Session","usedFraction":0.18},{"label":"Fable","usedFraction":0.85}]},
        \\ {"id":"claude-agent","name":"Claude Agent","signedIn":true,"account":"dev@studio.test","organization":"Studio Team","planLabel":"Claude Max 20x"}
        \\]
    );
    defer p.deinit();
    const rows = try parseGraffLogins(ar, p.value);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("SuperGrok Heavy", rows[0].plan_label.?);
    try testing.expectEqual(@as(?i64, 1250), rows[0].prepaid_cents);
    try testing.expectEqual(@as(?f64, 50.0), rows[0].reset_credits);
    try testing.expectEqual(@as(usize, 1), rows[0].usage_windows.len);
    try testing.expectEqualStrings("Fable", rows[1].usage_windows[1].label);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("Signed in as ada@example.test \u{00b7} $12.50 prepaid", graffStatus(&buf, rows[0]));
    try testing.expectEqualStrings("Signed in as ops@acme.test \u{00b7} Acme Labs", graffStatus(&buf, rows[1]));
    try testing.expectEqualStrings("Claude Agent", graffProviderName("claude-agent"));
}

test "graff route selection and matching accounts preserve reportsUsage false" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    try testing.expect(!reportsUsage("graff"));
    try testing.expectEqualStrings("codex", graffRoute("codex/gpt-6-astra").?);
    try testing.expectEqualStrings("claude-agent", graffRoute("claude-agent:opus").?);
    try testing.expect(graffRoute("bare-model") == null);

    const logins_json = try parsed(
        \\[
        \\ {"id":"chatgpt-new","name":"ChatGPT","signedIn":true,"account":"dev@acme.test","planLabel":"Pro",
        \\  "usageWindows":[{"label":"Session","usedFraction":0.38},{"label":"Week","usedFraction":0.24}]},
        \\ {"id":"claude-agent","name":"Claude Agent","signedIn":true,"account":"cl@acme.test","planLabel":"Max",
        \\  "usageWindows":[{"label":"5h","usedFraction":0.42}]}
        \\]
    );
    defer logins_json.deinit();
    const logins = try parseGraffLogins(ar, logins_json.value);

    const snap_json = try parsed(
        \\{"accounts":[
        \\ {"id":"cx-1","harness":"codex","email":"cli@codex.test","planLabel":"Plus","active":true,"switchable":true,
        \\  "usageWindows":[{"label":"Session","usedFraction":0.61}]}
        \\]}
    );
    defer snap_json.deinit();
    const snap = try parseSnapshot(ar, snap_json.value);

    // codex route prefers active Codex CLI account, falling back to ChatGPT login when absent.
    const codex_cli = graffActiveAccount(ar, snap, logins, "codex/gpt-6-astra").?;
    try testing.expectEqualStrings("cx-1", codex_cli.id);
    const codex_fallback = graffActiveAccount(ar, null, logins, "codex/gpt-6-astra").?;
    try testing.expectEqualStrings("chatgpt-new", codex_fallback.id);
    try testing.expectEqualStrings("ChatGPT \u{00b7} Pro", codex_fallback.plan_label.?);

    // chatgpt-new prefers Graff ChatGPT login even when a Codex CLI login exists.
    const chatgpt = graffActiveAccount(ar, snap, logins, "chatgpt-new/gpt-6-sol").?;
    try testing.expectEqualStrings("chatgpt-new", chatgpt.id);

    // Non-plan API route shows no usage ring.
    try testing.expect(graffActiveAccount(ar, snap, logins, "deepseek/deepseek-v3.2") == null);

    const matching = graffMatchingAccounts(ar, snap, logins, "codex/gpt-6-astra");
    try testing.expectEqual(@as(usize, 3), matching.len);
}
