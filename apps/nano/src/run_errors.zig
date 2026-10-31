//! What a failed run's error means for the person reading it, as the GPUI
//! app reads it (crates/proto/src/run_errors.rs): the agent's provider needs
//! a sign-in, its usage limit was reached, or something else. Only plain
//! error text is labelled here; a provider-typed failure keeps its own
//! reconnect card (reauth_recovery.zig), and no sign-in route is ever taken
//! from the message: "Log in" routes by the chat's own agent. The cases both
//! apps agree on live in apps/parity/vectors/run-errors.json.
const std = @import("std");

/// `ProviderProblem`: a reason a turn couldn't run that signing in fixes.
pub const ProviderProblem = enum {
    /// Not signed in, signed out, or an expired or rejected login.
    signed_out,
    /// The account's usage or rate limit was hit (another account helps).
    limit_reached,

    /// The error card's label.
    pub fn label(p: ProviderProblem) []const u8 {
        return switch (p) {
            .signed_out => "Signed out",
            .limit_reached => "Limit reached",
        };
    }

    /// The button that fixes it.
    pub fn actionLabel(_: ProviderProblem) []const u8 {
        return "Log in";
    }

    /// The vector's name for it.
    pub fn asStr(p: ProviderProblem) []const u8 {
        return switch (p) {
            .signed_out => "signedOut",
            .limit_reached => "limitReached",
        };
    }
};

const signed_out = [_][]const u8{
    "isn't signed in",
    "is not signed in",
    "not signed in",
    "not logged in",
    "please run /login",
    "run `claude login`",
    "run codex login",
    "authentication failed",
    "authentication_error",
    "sign in to claude again",
    "please sign in again",
    "sign in again",
    "log in again",
    "invalid api key",
    "invalid x-api-key",
    "oauth token has expired",
    "token has expired",
    "token expired",
    "unauthorized",
    "http 401",
    "status 401",
    "(401)",
    "401 ",
    "logged out",
};

const limit_reached = [_][]const u8{
    "usage limit",
    "limit reached",
    "rate limit",
    "rate-limit",
    "you've hit your",
    "you have hit your",
    "hit your limit",
    "quota",
    "http 429",
    "status 429",
    "(429)",
    "too many requests",
};

/// `NOT_THE_PROVIDER`: hosted credit, GitHub's own API and Harness's own
/// account read like a sign-in or limit, but signing in doesn't fix them.
const not_the_provider = [_][]const u8{ "credit", "github", "graphql:", "harness login" };

/// `provider_problem`: the problem `message` reports, if signing in to the
/// agent's provider can fix it. ASCII is folded to lower case, and a curly
/// apostrophe reads as a straight one.
pub fn providerProblem(message: []const u8) ?ProviderProblem {
    var buf: [4096]u8 = undefined;
    const text = fold(&buf, message);
    for (not_the_provider) |n| if (std.mem.indexOf(u8, text, n) != null) return null;
    for (signed_out) |n| if (std.mem.indexOf(u8, text, n) != null) return .signed_out;
    for (limit_reached) |n| if (std.mem.indexOf(u8, text, n) != null) return .limit_reached;
    return null;
}

/// `message` lower-cased with U+2019 as `'`, cut to `buf` (every needle is
/// ASCII, and a run error longer than 4 KiB is its own tail of stderr).
fn fold(buf: []u8, message: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < message.len and n < buf.len) {
        if (std.mem.startsWith(u8, message[i..], "\u{2019}")) {
            buf[n] = '\'';
            i += 3;
        } else {
            buf[n] = std.ascii.toLower(message[i]);
            i += 1;
        }
        n += 1;
    }
    return buf[0..n];
}

/// `chatgpt_plan::is_usage_limit_error`: the ChatGPT plan's own limit,
/// which the GPUI app shows as its plan-usage card, never with "Log in".
pub fn isPlanUsageLimit(message: []const u8) bool {
    return std.mem.indexOf(u8, message, "subscription_sharing_usage_limit_exceeded") != null or
        std.mem.indexOf(u8, message, "subscription_sharing_v2_usage_limit_exceeded") != null or
        std.mem.indexOf(u8, message, "ChatGPT plan usage limit") != null;
}

const testing = std.testing;

test "reads the errors the adapters and engine write" {
    for ([_][]const u8{
        "Claude Code isn't signed in. Use Settings → Agents → Sign in.",
        "Authentication failed — sign in to Claude again.",
        "Invalid API key · Please run /login",
        "OAuth token has expired. Please obtain a new token or refresh your existing token.",
        "Not logged in · Please run /login",
        "Request failed (401) Unauthorized",
        "Codex isn\u{2019}t signed in on this computer.",
    }) |m| try testing.expectEqual(@as(?ProviderProblem, .signed_out), providerProblem(m));
    for ([_][]const u8{
        "Claude usage limit reached — try again after the limit resets.",
        "Claude 5-hour limit reached — the turn was blocked. Try again after it resets.",
        "You've hit your usage limit. Upgrade to Pro or try again later.",
        "429 Too Many Requests",
        "rate limited (429): quota/billing cap",
    }) |m| try testing.expectEqual(@as(?ProviderProblem, .limit_reached), providerProblem(m));
    for ([_][]const u8{
        "Claude is overloaded right now — try again shortly.",
        "The selected model isn't available.",
        "Your Codegraff credit is used up. Add credit and try again.",
        "GitHub API rate limit reached",
        "GraphQL: API rate limit exceeded",
        "not signed in — run `harness login` on this machine first",
        "Harness exited with status 1",
        "Listening on port 4012",
        "",
    }) |m| try testing.expectEqual(@as(?ProviderProblem, null), providerProblem(m));
}

test "labels name the problem and the fix" {
    try testing.expectEqualStrings("Signed out", ProviderProblem.signed_out.label());
    try testing.expectEqualStrings("Limit reached", ProviderProblem.limit_reached.label());
    try testing.expectEqualStrings("Log in", ProviderProblem.signed_out.actionLabel());
    try testing.expectEqualStrings("Log in", ProviderProblem.limit_reached.actionLabel());
}

// The shared vector, read from the repository at test time (never copied),
// as `matches_the_shared_parity_vector` and the phone's ParityTests read it.
test "run errors: the shared parity vector" {
    const dir = @import("parity_options").vectors_dir;
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const path = try std.fs.path.join(ar.allocator(), &.{ dir, "run-errors.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, ar.allocator(), .limited(1 << 20));
    const v = try std.json.parseFromSliceLeaky(std.json.Value, ar.allocator(), text, .{});
    const cases = v.object.get("cases").?.array.items;
    try testing.expect(cases.len > 0);
    const labels = v.object.get("labels").?.object;
    const action = v.object.get("actionLabel").?.string;
    for (cases) |c| {
        const message = c.object.get("message").?.string;
        const expect: ?[]const u8 = switch (c.object.get("expect").?) {
            .string => |s| s,
            else => null,
        };
        const got = providerProblem(message);
        const got_s: ?[]const u8 = if (got) |p| p.asStr() else null;
        if (expect) |e| {
            testing.expect(got_s != null and std.mem.eql(u8, e, got_s.?)) catch |err| {
                std.debug.print("{s}: want {s}, got {?s}\n", .{ message, e, got_s });
                return err;
            };
            try testing.expectEqualStrings(labels.get(e).?.string, got.?.label());
            try testing.expectEqualStrings(action, got.?.actionLabel());
        } else {
            testing.expect(got == null) catch |err| {
                std.debug.print("{s}: want null, got {?s}\n", .{ message, got_s });
                return err;
            };
        }
    }
}
