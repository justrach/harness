//! GitHub CI runners for Settings › GitHub CI (the engine's
//! `CodegraffGithubRunners`), as the GPUI app reads them
//! (crates/ui/src/codegraff_runners.rs): which panel the page shows, budgets
//! and spend, each repository's size with its hourly price, and the recent
//! jobs. Pure, so the page stays a thin renderer.
const std = @import("std");
const json = std.json;
const rules = @import("rules.zig");
const Allocator = std.mem.Allocator;

/// The page's answer from the engine (`GithubRunners`).
pub const Runners = struct {
    /// The gateway knows runners at all.
    available: bool = false,
    /// Runners are open to this account (`false`: coming soon).
    enabled: bool = false,
    install_url: ?[]const u8 = null,
    installations: []Installation = &.{},
    recent_jobs: []Job = &.{},
    sizes: []Size = &.{},
};

pub const Installation = struct {
    installation_id: []const u8 = "",
    account: []const u8 = "",
    account_type: ?[]const u8 = null,
    suspended: bool = false,
    monthly_budget_micro_usd: ?i64 = null,
    untrusted_budget_micro_usd: ?i64 = null,
    used_this_month_micro_usd: ?i64 = null,
    max_concurrent: ?u32 = null,
    repos: []Repo = &.{},
};

pub const Repo = struct {
    full_name: []const u8 = "",
    enabled: bool = false,
    default_size: ?[]const u8 = null,
    private: bool = false,
};

pub const Job = struct {
    repo: []const u8 = "",
    run_id: ?i64 = null,
    job_id: ?i64 = null,
    workflow: ?[]const u8 = null,
    job_name: ?[]const u8 = null,
    tier: ?[]const u8 = null,
    size: ?[]const u8 = null,
    state: []const u8 = "",
    /// When it was queued, started and completed, in milliseconds since the
    /// epoch (`moment`: an RFC 3339 time, or seconds or milliseconds).
    queued_at: ?i64 = null,
    started_at: ?i64 = null,
    completed_at: ?i64 = null,
    duration_seconds: ?f64 = null,
    cost_micro_usd: ?i64 = null,
    conclusion: ?[]const u8 = null,
    html_url: ?[]const u8 = null,
};

pub const Size = struct {
    key: []const u8 = "",
    cpu: ?f64 = null,
    memory_gib: ?f64 = null,
    disk_gib: ?f64 = null,
    price_per_hour_micro_usd: ?i64 = null,
};

/// The most concurrent jobs an installation may run.
pub const max_concurrent: u32 = 8;
/// After Connect, how often the page re-reads while the user installs the
/// app in the browser, and for how long.
pub const connect_poll_s: f64 = 10;
pub const connect_watch_s: f64 = 5 * 60;

/// What a workflow says to run on Codegraff.
pub const yaml_snippet = "jobs:\n  build:\n    runs-on: codegraff\n    steps:\n      - uses: actions/checkout@v4\n";

/// The not-connected explanation.
pub const explainer = "Jobs with runs-on: codegraff run in a fresh Codegraff sandbox per job, billed per second from your Codegraff credit. Pull requests from forks run in a smaller, isolated tier. For public repositories, require approval for workflows from outside contributors.";

// Reading the answer. Tolerant of fields added later; everything kept is
// copied into `ar`.

/// The engine's reply: null when signed out of Codegraff.
pub fn parse(ar: Allocator, v: json.Value) !?Runners {
    const o = switch (v) {
        .null => return null,
        .object => |o| o,
        else => return error.UnexpectedReply,
    };
    var r: Runners = .{
        .available = boolean(o, "available"),
        .enabled = boolean(o, "enabled"),
        .install_url = try str(ar, o, "installUrl"),
    };
    if (array(o, "installations")) |items| {
        var list: std.ArrayList(Installation) = .empty;
        for (items) |item| if (item == .object) try list.append(ar, try installation(ar, item.object));
        r.installations = list.items;
    }
    if (array(o, "recentJobs")) |items| {
        var list: std.ArrayList(Job) = .empty;
        for (items) |item| if (item == .object) try list.append(ar, try job(ar, item.object));
        r.recent_jobs = list.items;
    }
    if (array(o, "sizes")) |items| {
        var list: std.ArrayList(Size) = .empty;
        for (items) |item| if (item == .object) try list.append(ar, .{
            .key = try str(ar, item.object, "key") orelse "",
            .cpu = float(item.object, "cpu"),
            .memory_gib = float(item.object, "memoryGiB"),
            .disk_gib = float(item.object, "diskGiB"),
            .price_per_hour_micro_usd = int(item.object, "pricePerHourMicroUsd"),
        });
        r.sizes = list.items;
    }
    return r;
}

fn installation(ar: Allocator, o: json.ObjectMap) !Installation {
    var i: Installation = .{
        .installation_id = try str(ar, o, "installationId") orelse "",
        .account = try str(ar, o, "account") orelse "",
        .account_type = try str(ar, o, "accountType"),
        .suspended = boolean(o, "suspended"),
        .monthly_budget_micro_usd = int(o, "monthlyBudgetMicroUsd"),
        .untrusted_budget_micro_usd = int(o, "untrustedBudgetMicroUsd"),
        .used_this_month_micro_usd = int(o, "usedThisMonthMicroUsd"),
        .max_concurrent = if (int(o, "maxConcurrent")) |n| (if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null) else null,
    };
    if (array(o, "repos")) |items| {
        var list: std.ArrayList(Repo) = .empty;
        for (items) |item| if (item == .object) try list.append(ar, .{
            .full_name = try str(ar, item.object, "fullName") orelse "",
            .enabled = boolean(item.object, "enabled"),
            .default_size = try str(ar, item.object, "defaultSize"),
            .private = boolean(item.object, "private"),
        });
        i.repos = list.items;
    }
    return i;
}

fn job(ar: Allocator, o: json.ObjectMap) !Job {
    return .{
        .repo = try str(ar, o, "repo") orelse "",
        .run_id = int(o, "runId"),
        .job_id = int(o, "jobId"),
        .workflow = try str(ar, o, "workflow"),
        .job_name = try str(ar, o, "jobName"),
        .tier = try str(ar, o, "tier"),
        .size = try str(ar, o, "size"),
        .state = try str(ar, o, "state") orelse "",
        .queued_at = moment(o.get("queuedAt")),
        .started_at = moment(o.get("startedAt")),
        .completed_at = moment(o.get("completedAt")),
        .duration_seconds = float(o, "durationSeconds"),
        .cost_micro_usd = int(o, "costMicroUsd"),
        .conclusion = try str(ar, o, "conclusion"),
        .html_url = try str(ar, o, "htmlUrl"),
    };
}

fn str(ar: Allocator, o: json.ObjectMap, k: []const u8) !?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) try ar.dupe(u8, v.string) else null;
}

fn boolean(o: json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

fn int(o: json.ObjectMap, k: []const u8) ?i64 {
    const v = o.get(k) orelse return null;
    return if (v == .integer) v.integer else null;
}

fn float(o: json.ObjectMap, k: []const u8) ?f64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn array(o: json.ObjectMap, k: []const u8) ?[]json.Value {
    const v = o.get(k) orelse return null;
    return if (v == .array) v.array.items else null;
}

/// A time as the engine sends it: RFC 3339, or a number of milliseconds or
/// seconds (`moment`).
fn moment(v: ?json.Value) ?i64 {
    return switch (v orelse return null) {
        .string => |s| rules.parseTime(s),
        // Milliseconds or seconds.
        .integer => |n| if (n > 100_000_000_000) n else n * 1000,
        else => null,
    };
}

// The page's rules.

/// Which panel the page shows.
pub const Panel = enum {
    /// Signed out of Codegraff.
    signed_out,
    /// The gateway has no runners yet (404).
    unavailable,
    /// Runners exist but aren't open to this account yet.
    coming_soon,
    /// Open, nothing installed: explain and offer Connect.
    not_connected,
    connected,
};

pub fn panel(runners: ?*const Runners) Panel {
    const r = runners orelse return .signed_out;
    if (!r.available) return .unavailable;
    if (!r.enabled) return .coming_soon;
    if (r.installations.len == 0) return .not_connected;
    return .connected;
}

/// The link Connect opens: only an https one.
pub fn installUrl(runners: *const Runners) ?[]const u8 {
    return https(runners.install_url);
}

fn https(url: ?[]const u8) ?[]const u8 {
    const u = std.mem.trim(u8, url orelse return null, &std.ascii.whitespace);
    return if (std.mem.startsWith(u8, u, "https://")) u else null;
}

/// "$50", "$12.50", "$0.0042" (sub-cent amounts keep their digits).
pub fn formatDollars(gpa: Allocator, micro_usd: i64) ![]u8 {
    const sign = if (micro_usd < 0) "-" else "";
    const micro = @abs(micro_usd);
    if (micro == 0) return gpa.dupe(u8, "$0");
    if (micro % 1_000_000 == 0) return std.fmt.allocPrint(gpa, "{s}${d}", .{ sign, micro / 1_000_000 });
    const dollars = @as(f64, @floatFromInt(micro)) / 1_000_000.0;
    if (micro < 10_000) {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d:.4}", .{dollars}) catch unreachable;
        return std.fmt.allocPrint(gpa, "{s}${s}", .{ sign, std.mem.trimEnd(u8, text, "0") });
    }
    return std.fmt.allocPrint(gpa, "{s}${d:.2}", .{ sign, dollars });
}

/// A budget as typed, in micro-USD, or what's wrong with it.
pub const Budget = union(enum) {
    ok: i64,
    err: []const u8,
};

/// A budget as typed ("50", "$50", "1,250.50").
pub fn parseBudget(text: []const u8) Budget {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    const trimmed = std.mem.trimStart(u8, std.mem.trim(u8, text, &std.ascii.whitespace), "$");
    for (trimmed) |ch| {
        if (ch == ',' or std.ascii.isWhitespace(ch)) continue;
        if (n == buf.len) return .{ .err = "That budget is too large." };
        buf[n] = ch;
        n += 1;
    }
    const cleaned = buf[0..n];
    if (cleaned.len == 0) return .{ .err = "Enter a budget in dollars." };
    const dot = std.mem.indexOfScalar(u8, cleaned, '.');
    const whole = if (dot) |d| cleaned[0..d] else cleaned;
    const cents = if (dot) |d| cleaned[d + 1 ..] else "";
    if (!digits(whole) or !digits(cents) or (whole.len == 0 and cents.len == 0))
        return .{ .err = "Enter a dollar amount, like 50 or 12.50." };
    if (cents.len > 2) return .{ .err = "Use at most two decimal places." };
    const dollars: i64 = if (whole.len == 0) 0 else std.fmt.parseInt(i64, whole, 10) catch return .{ .err = "That budget is too large." };
    if (dollars > 100_000) return .{ .err = "Budgets go up to $100,000 a month." };
    var c: i64 = 0;
    for (0..2) |i| c = c * 10 + (if (i < cents.len) cents[i] - '0' else 0);
    return .{ .ok = dollars * 1_000_000 + c * 10_000 };
}

fn digits(s: []const u8) bool {
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// The budget as the input shows it: "50", "12.50".
pub fn budgetInputText(gpa: Allocator, micro_usd: ?i64) ![]u8 {
    const micro = micro_usd orelse return gpa.dupe(u8, "");
    const text = try formatDollars(gpa, micro);
    defer gpa.free(text);
    return gpa.dupe(u8, std.mem.trimStart(u8, text, "$"));
}

/// How much of the month's budget is used, for the meter (null without a
/// budget).
pub fn budgetFraction(i: *const Installation) ?f32 {
    const budget = i.monthly_budget_micro_usd orelse return null;
    const used = @max(i.used_this_month_micro_usd orelse 0, 0);
    if (budget <= 0) return 1.0;
    return @floatCast(std.math.clamp(@as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(budget)), 0.0, 1.0));
}

/// "$12.50 of $50 used this month" / "$12.50 used this month · no monthly
/// budget".
pub fn spendLine(gpa: Allocator, i: *const Installation) ![]u8 {
    const used = try formatDollars(gpa, i.used_this_month_micro_usd orelse 0);
    defer gpa.free(used);
    const budget = i.monthly_budget_micro_usd orelse return std.fmt.allocPrint(gpa, "{s} used this month · no monthly budget", .{used});
    const of = try formatDollars(gpa, budget);
    defer gpa.free(of);
    return std.fmt.allocPrint(gpa, "{s} of {s} used this month", .{ used, of });
}

/// "Organization · suspended" and the like, under the account name.
pub fn installationMeta(gpa: Allocator, i: *const Installation) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (i.account_type) |t| {
        const kind = std.mem.trim(u8, t, &std.ascii.whitespace);
        if (kind.len > 0) try out.print(gpa, "{s} · ", .{kind});
    }
    var on: usize = 0;
    for (i.repos) |r| on += @intFromBool(r.enabled);
    if (i.repos.len == 0)
        try out.appendSlice(gpa, "No repositories")
    else
        try out.print(gpa, "{d} of {d} repositor{s} on", .{ on, i.repos.len, if (i.repos.len == 1) "y" else "ies" });
    if (i.suspended) try out.appendSlice(gpa, " · Suspended on GitHub");
    return out.toOwnedSlice(gpa);
}

/// The concurrent-job cap, kept within 1…`max_concurrent`.
pub fn stepConcurrent(current: ?u32, delta: i32) u32 {
    const now: i32 = @intCast(std.math.clamp(current orelse 1, 1, max_concurrent));
    return @intCast(std.math.clamp(now + delta, 1, @as(i32, max_concurrent)));
}

/// "Standard", "Large", or the key capitalised.
pub fn sizeName(gpa: Allocator, key: []const u8) ![]u8 {
    const k = std.mem.trim(u8, key, &std.ascii.whitespace);
    if (k.len == 0) return gpa.dupe(u8, "Default");
    const out = try gpa.dupe(u8, k);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// "Standard · 2 vCPU · 4 GB · $0.10/h".
pub fn sizeOptionLabel(gpa: Allocator, size: *const Size) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const name = try sizeName(gpa, size.key);
    defer gpa.free(name);
    try out.appendSlice(gpa, name);
    if (try machineSpec(gpa, size.cpu, size.memory_gib)) |spec| {
        defer gpa.free(spec);
        try out.print(gpa, " · {s}", .{spec});
    }
    if (size.price_per_hour_micro_usd) |price| {
        const rate = try formatRate(gpa, price);
        defer gpa.free(rate);
        try out.print(gpa, " · {s}", .{rate});
    }
    return out.toOwnedSlice(gpa);
}

/// The repository's size as its dropdown shows it: the named size, else
/// the first offered.
pub fn repoSizeLabel(gpa: Allocator, repo: *const Repo, sizes: []const Size) ![]u8 {
    var key: ?[]const u8 = null;
    if (repo.default_size) |d| {
        const k = std.mem.trim(u8, d, &std.ascii.whitespace);
        if (k.len > 0) key = k;
    }
    const size: ?*const Size = if (key) |k| for (sizes) |*s| {
        if (std.mem.eql(u8, s.key, k)) break s;
    } else null else if (sizes.len > 0) &sizes[0] else null;
    if (size) |s| {
        const name = try sizeName(gpa, s.key);
        const price = s.price_per_hour_micro_usd orelse return name;
        defer gpa.free(name);
        const rate = try formatRate(gpa, price);
        defer gpa.free(rate);
        return std.fmt.allocPrint(gpa, "{s} · {s}", .{ name, rate });
    }
    if (key) |k| return sizeName(gpa, k);
    return gpa.dupe(u8, "Default size");
}

/// "CI · test", falling back to whichever is known.
pub fn jobTitle(gpa: Allocator, j: *const Job) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for ([_]?[]const u8{ j.workflow, j.job_name }) |part| if (part) |p| {
        const t = std.mem.trim(u8, p, &std.ascii.whitespace);
        if (t.len == 0) continue;
        if (out.items.len > 0) try out.appendSlice(gpa, " · ");
        try out.appendSlice(gpa, t);
    };
    if (out.items.len == 0) try out.appendSlice(gpa, "Job");
    return out.toOwnedSlice(gpa);
}

/// Whether a job's state is good, bad or neither.
pub const Tone = enum { working, good, bad, quiet };

pub const Status = struct { label: []const u8, tone: Tone };

/// "Queued", "Running", "Succeeded", "Failed", "Cancelled", … An unknown
/// state or conclusion reads as itself, capitalised, in `gpa`.
pub fn jobStatus(gpa: Allocator, j: *const Job) !Status {
    const ws = &std.ascii.whitespace;
    const conclusion = std.mem.trim(u8, j.conclusion orelse "", ws);
    const state = std.mem.trim(u8, j.state, ws);
    const in = struct {
        fn in(s: []const u8, set: []const []const u8) bool {
            for (set) |x| if (std.mem.eql(u8, s, x)) return true;
            return false;
        }
    }.in;
    if (in(state, &.{ "queued", "waiting", "pending" })) return .{ .label = "Queued", .tone = .working };
    if (in(state, &.{ "in_progress", "running", "started" })) return .{ .label = "Running", .tone = .working };
    if (std.mem.eql(u8, conclusion, "success")) return .{ .label = "Succeeded", .tone = .good };
    if (in(conclusion, &.{ "failure", "timed_out", "startup_failure" })) return .{ .label = "Failed", .tone = .bad };
    if (std.mem.eql(u8, conclusion, "cancelled")) return .{ .label = "Cancelled", .tone = .quiet };
    if (in(conclusion, &.{ "skipped", "neutral" })) return .{ .label = "Skipped", .tone = .quiet };
    if (state.len == 0 and conclusion.len == 0) return .{ .label = "Unknown", .tone = .quiet };
    const said = try gpa.dupe(u8, if (conclusion.len == 0) state else conclusion);
    defer gpa.free(said);
    std.mem.replaceScalar(u8, said, '_', ' ');
    return .{ .label = try sizeName(gpa, said), .tone = .quiet };
}

/// "45s", "3m 5s", "1h 2m".
pub fn formatDuration(gpa: Allocator, seconds: f64) ![]u8 {
    const s: u64 = @intFromFloat(@round(@max(seconds, 0)));
    if (s < 60) return std.fmt.allocPrint(gpa, "{d}s", .{s});
    if (s < 3600) return std.fmt.allocPrint(gpa, "{d}m {d}s", .{ s / 60, s % 60 });
    return std.fmt.allocPrint(gpa, "{d}h {d}m", .{ s / 3600, (s % 3600) / 60 });
}

/// "just now", "5 min ago", "3h ago", "2d ago".
fn ago(gpa: Allocator, at_ms: i64, now_ms: i64) ![]u8 {
    const m = @divTrunc(now_ms - at_ms, 60_000);
    if (m < 1) return gpa.dupe(u8, "just now");
    if (m < 60) return std.fmt.allocPrint(gpa, "{d} min ago", .{m});
    if (m < 60 * 24) return std.fmt.allocPrint(gpa, "{d}h ago", .{@divTrunc(m, 60)});
    return std.fmt.allocPrint(gpa, "{d}d ago", .{@divTrunc(m, 60 * 24)});
}

/// "Large · 3m 5s · $0.0050 · 5 min ago · fork".
pub fn jobMeta(gpa: Allocator, j: *const Job, now_ms: i64) ![]u8 {
    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |p| gpa.free(p);
        parts.deinit(gpa);
    }
    if (j.size) |s| if (std.mem.trim(u8, s, &std.ascii.whitespace).len > 0) try parts.append(gpa, try sizeName(gpa, s));
    const duration: ?f64 = j.duration_seconds orelse if (j.started_at != null and j.completed_at != null)
        @floatFromInt(@divTrunc(j.completed_at.? - j.started_at.?, 1000))
    else
        null;
    if (duration) |d| try parts.append(gpa, try formatDuration(gpa, d));
    if (j.cost_micro_usd) |cost| try parts.append(gpa, try formatDollars(gpa, cost));
    if (j.completed_at orelse j.started_at orelse j.queued_at) |at| try parts.append(gpa, try ago(gpa, at, now_ms));
    if (j.tier) |t| if (std.mem.eql(u8, t, "untrusted")) try parts.append(gpa, try gpa.dupe(u8, "Fork, isolated"));
    return std.mem.join(gpa, " · ", parts.items);
}

/// The job's page on GitHub, when it is an https link.
pub fn jobUrl(j: *const Job) ?[]const u8 {
    return https(j.html_url);
}

/// Anything still queued or running moves on its own, so the page re-reads
/// while one is.
pub fn jobsWorking(r: *const Runners) bool {
    for (r.recent_jobs) |*j| {
        var buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const s = jobStatus(fba.allocator(), j) catch continue;
        if (s.tone == .working) return true;
    }
    return false;
}

// From codegraff_sandboxes.rs.

/// An hourly price: "$0.10/h", "$0.125/h", "$1.50/h".
pub fn formatRate(gpa: Allocator, micro_usd: i64) ![]u8 {
    const dollars = @as(f64, @floatFromInt(@max(micro_usd, 0))) / 1_000_000.0;
    var buf: [64]u8 = undefined;
    var text: []const u8 = std.fmt.bufPrint(&buf, "{d:.3}", .{dollars}) catch unreachable;
    // Cents always show; a third decimal only when it says something.
    if (std.mem.endsWith(u8, text, "0")) text = text[0 .. text.len - 1];
    return std.fmt.allocPrint(gpa, "${s}/h", .{text});
}

/// "4 GB", "0.5 GB".
fn formatGb(gpa: Allocator, gib: f64) ![]u8 {
    if (gib == @trunc(gib)) return std.fmt.allocPrint(gpa, "{d:.0} GB", .{gib});
    return std.fmt.allocPrint(gpa, "{d} GB", .{@round(gib * 10.0) / 10.0});
}

/// "2 vCPU · 4 GB" when both are known.
pub fn machineSpec(gpa: Allocator, cpu: ?f64, memory_gib: ?f64) !?[]u8 {
    const c = cpu orelse return null;
    const m = memory_gib orelse return null;
    if (!(c > 0) or !(m > 0)) return null;
    const gb = try formatGb(gpa, m);
    defer gpa.free(gb);
    if (c == @trunc(c)) return try std.fmt.allocPrint(gpa, "{d:.0} vCPU · {s}", .{ c, gb });
    return try std.fmt.allocPrint(gpa, "{d} vCPU · {s}", .{ c, gb });
}

// The GPUI app's tests, case for case.

const testing = std.testing;

const listed_json =
    \\{"available": true, "enabled": true,
    \\ "installUrl": "https://github.com/apps/codegraff/installations/new",
    \\ "installations": [{
    \\   "installationId": "4242", "account": "octo-org", "accountType": "Organization",
    \\   "suspended": false, "monthlyBudgetMicroUsd": 50000000,
    \\   "usedThisMonthMicroUsd": 12500000, "maxConcurrent": 3,
    \\   "repos": [
    \\     {"fullName": "octo-org/app", "enabled": true, "defaultSize": "large", "private": true},
    \\     {"fullName": "octo-org/docs", "enabled": false}
    \\   ]
    \\ }],
    \\ "recentJobs": [],
    \\ "sizes": [
    \\   {"key": "standard", "cpu": 2, "memoryGiB": 4, "diskGiB": 40, "pricePerHourMicroUsd": 100000},
    \\   {"key": "large", "cpu": 4, "memoryGiB": 8, "diskGiB": 40, "pricePerHourMicroUsd": 200000}
    \\ ]}
;

fn parsed(ar: Allocator, text: []const u8) !?Runners {
    const v = try json.parseFromSliceLeaky(json.Value, ar, text, .{});
    return parse(ar, v);
}

fn listed(ar: Allocator) !Runners {
    return (try parsed(ar, listed_json)).?;
}

test "the panel follows sign-in, availability and installs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try testing.expectEqual(Panel.signed_out, panel(null));
    try testing.expect((try parsed(ar, "null")) == null);
    try testing.expectEqual(Panel.unavailable, panel(&.{}));
    try testing.expectEqual(Panel.coming_soon, panel(&.{ .available = true }));
    try testing.expectEqual(Panel.not_connected, panel(&.{ .available = true, .enabled = true }));
    const r = try listed(ar);
    try testing.expectEqual(Panel.connected, panel(&r));
    var insecure = r;
    insecure.install_url = "http://example.invalid";
    try testing.expect(installUrl(&insecure) == null);
    try testing.expect(installUrl(&r) != null);
}

test "dollars read plainly" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try testing.expectEqualStrings("$50", try formatDollars(ar, 50_000_000));
    try testing.expectEqualStrings("$12.50", try formatDollars(ar, 12_500_000));
    try testing.expectEqualStrings("$0.005", try formatDollars(ar, 5_000));
    try testing.expectEqualStrings("$0.0042", try formatDollars(ar, 4_200));
    try testing.expectEqualStrings("$0", try formatDollars(ar, 0));
    try testing.expectEqualStrings("12.50", try budgetInputText(ar, 12_500_000));
    try testing.expectEqualStrings("", try budgetInputText(ar, null));
}

test "budgets parse and refuse nonsense" {
    try testing.expectEqual(Budget{ .ok = 50_000_000 }, parseBudget("50"));
    try testing.expectEqual(Budget{ .ok = 1_250_500_000 }, parseBudget(" $1,250.5 "));
    try testing.expectEqual(Budget{ .ok = 250_000 }, parseBudget("0.25"));
    try testing.expectEqual(Budget{ .ok = 500_000 }, parseBudget(".5"));
    try testing.expectEqual(Budget{ .ok = 0 }, parseBudget("0"));
    try testing.expectEqualStrings("Enter a budget in dollars.", parseBudget("").err);
    for ([_][]const u8{ "-5", "abc", "1.2.3", "." }) |bad| try testing.expectEqualStrings("Enter a dollar amount, like 50 or 12.50.", parseBudget(bad).err);
    try testing.expectEqualStrings("Use at most two decimal places.", parseBudget("1.234").err);
    try testing.expectEqualStrings("Budgets go up to $100,000 a month.", parseBudget("100001").err);
    try testing.expectEqualStrings("That budget is too large.", parseBudget("99999999999999999999").err);
}

test "spend and the meter follow the budget" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try listed(ar);
    const install = &r.installations[0];
    try testing.expectEqualStrings("$12.50 of $50 used this month", try spendLine(ar, install));
    try testing.expectEqual(@as(?f32, 0.25), budgetFraction(install));
    try testing.expectEqualStrings("Organization · 1 of 2 repositories on", try installationMeta(ar, install));
    var open_ended = install.*;
    open_ended.monthly_budget_micro_usd = null;
    open_ended.suspended = true;
    open_ended.repos = open_ended.repos[0..1];
    try testing.expectEqual(@as(?f32, null), budgetFraction(&open_ended));
    try testing.expectEqualStrings("$12.50 used this month · no monthly budget", try spendLine(ar, &open_ended));
    try testing.expectEqualStrings("Organization · 1 of 1 repository on · Suspended on GitHub", try installationMeta(ar, &open_ended));
    var zero = install.*;
    zero.monthly_budget_micro_usd = 0;
    try testing.expectEqual(@as(?f32, 1.0), budgetFraction(&zero));
}

test "concurrency stays between one and eight" {
    try testing.expectEqual(@as(u32, 4), stepConcurrent(3, 1));
    try testing.expectEqual(@as(u32, 8), stepConcurrent(8, 1));
    try testing.expectEqual(@as(u32, 1), stepConcurrent(1, -1));
    try testing.expectEqual(@as(u32, 2), stepConcurrent(null, 1));
    try testing.expectEqual(@as(u32, 7), stepConcurrent(40, -1));
}

test "sizes show their machine and rate" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try listed(ar);
    try testing.expectEqualStrings("Standard · 2 vCPU · 4 GB · $0.10/h", try sizeOptionLabel(ar, &r.sizes[0]));
    const repos = r.installations[0].repos;
    try testing.expectEqualStrings("Large · $0.20/h", try repoSizeLabel(ar, &repos[0], r.sizes));
    // No size named: the first.
    try testing.expectEqualStrings("Standard · $0.10/h", try repoSizeLabel(ar, &repos[1], r.sizes));
    try testing.expectEqualStrings("Xl", try repoSizeLabel(ar, &.{ .default_size = "xl" }, r.sizes));
    try testing.expectEqualStrings("Default size", try repoSizeLabel(ar, &.{}, &.{}));
}

test "jobs say what ran, how it went and what it cost" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const now = rules.parseTime("2026-10-22T10:08:05Z").?;
    const v = try json.parseFromSliceLeaky(json.Value, ar,
        \\{"repo": "octo-org/app", "workflow": "CI", "jobName": "test", "size": "standard",
        \\ "state": "completed", "conclusion": "success",
        \\ "startedAt": "2026-10-22T10:00:05Z", "completedAt": "2026-10-22T10:03:05Z",
        \\ "costMicroUsd": 5000, "tier": "untrusted",
        \\ "htmlUrl": "https://github.com/octo-org/app/actions/runs/1/job/2"}
    , .{});
    const done = try job(ar, v.object);
    try testing.expectEqualStrings("CI · test", try jobTitle(ar, &done));
    const s = try jobStatus(ar, &done);
    try testing.expectEqualStrings("Succeeded", s.label);
    try testing.expectEqual(Tone.good, s.tone);
    try testing.expectEqualStrings("Standard · 3m 0s · $0.005 · 5 min ago · Fork, isolated", try jobMeta(ar, &done, now));
    try testing.expect(jobUrl(&done) != null);

    const queued: Job = .{ .state = "queued" };
    try testing.expectEqualStrings("Queued", (try jobStatus(ar, &queued)).label);
    try testing.expectEqualStrings("Job", try jobTitle(ar, &queued));
    try testing.expectEqualStrings("", try jobMeta(ar, &queued, now));
    const failed: Job = .{ .state = "completed", .conclusion = "failure", .duration_seconds = 3725, .html_url = "javascript:alert(1)" };
    const f = try jobStatus(ar, &failed);
    try testing.expectEqualStrings("Failed", f.label);
    try testing.expectEqual(Tone.bad, f.tone);
    try testing.expectEqualStrings("1h 2m", try jobMeta(ar, &failed, now));
    try testing.expect(jobUrl(&failed) == null);
    var r = try listed(ar);
    try testing.expect(!jobsWorking(&r));
    var jobs = [_]Job{queued};
    r.recent_jobs = &jobs;
    try testing.expect(jobsWorking(&r));
    try testing.expectEqualStrings("45s", try formatDuration(ar, 45.4));
}

test "rates read as dollars per hour" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    try testing.expectEqualStrings("$0.10/h", try formatRate(ar, 100_000));
    try testing.expectEqualStrings("$0.125/h", try formatRate(ar, 125_000));
    try testing.expectEqualStrings("$2.00/h", try formatRate(ar, 2_000_000));
    try testing.expectEqualStrings("$0.00/h", try formatRate(ar, -5));
    try testing.expectEqualStrings("2 vCPU · 4 GB", (try machineSpec(ar, 2, 4)).?);
    try testing.expectEqualStrings("0.5 vCPU · 0.5 GB", (try machineSpec(ar, 0.5, 0.5)).?);
    try testing.expect((try machineSpec(ar, 2, null)) == null);
    try testing.expect((try machineSpec(ar, null, 4)) == null);
}
