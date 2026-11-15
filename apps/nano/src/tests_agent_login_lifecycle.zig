//! Deferred, synthetic StartAgentLogin replies through the real RPC mux.
//! No engine connection, browser URL, renderer, credentials, or auth files.
const std = @import("std");
const testing = std.testing;
const App = @import("app.zig").App;
const page = @import("view_settings_agents.zig");

fn scene(a: *App, text: []const u8) !void {
    a.engine.scene = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
}

/// Deliver any queued reply first, including an obsolete reply after its retry.
/// Dispatching it twice also checks that a terminal reply cannot cancel twice.
fn deliver(a: *App, index: usize, twice: bool) !void {
    const frame = a.engine.queued.orderedRemove(index);
    defer a.gpa.free(frame);
    try a.engine.mux.dispatch(frame);
    if (twice) try a.engine.mux.dispatch(frame);
}

fn cancellations(a: *App, login: []const u8) !usize {
    var count: usize = 0;
    for (a.engine.sent.items) |frame| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, frame, .{});
        defer parsed.deinit();
        const o = parsed.value.object;
        if (!std.mem.eql(u8, o.get("method").?.string, "CancelAgentLogin")) continue;
        const params = o.get("params").?.object;
        if (std.mem.eql(u8, params.get("loginId").?.string, login)) count += 1;
        try testing.expect(params.get("targetDeviceId") == null);
    }
    return count;
}

const starts =
    \\{"StartAgentLogin":{"$seq":[{"loginId":"old-login"},{"loginId":"current-login"}]},"CancelAgentLogin":{}}
;

test "agent login lifecycle cancel then late start cancels the returned login exactly once" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, starts);
    page.startSignIn(&a, .antigravity);
    try testing.expect(a.view.agents.sign_in.?.login_id == null);
    page.cancelSignIn(&a);
    page.cancelSignIn(&a);
    try testing.expectEqual(@as(usize, 0), try cancellations(&a, "old-login"));
    try deliver(&a, 0, true);
    try testing.expectEqual(@as(usize, 1), try cancellations(&a, "old-login"));
    try testing.expect(a.view.agents.sign_in == null);
    try testing.expect(a.view.agents.sign_in_failure == null);
}

test "agent login lifecycle retry cancels stale start without taking ownership of the new attempt" {
    // Both reply orders, with explicit cancellation or direct replacement.
    for ([_]bool{ false, true }) |new_first| {
        for ([_]bool{ false, true }) |explicit_cancel| {
            var a: App = .init(testing.allocator, testing.io, 1);
            defer a.deinit();
            try scene(&a, starts);
            page.startSignIn(&a, .antigravity);
            if (explicit_cancel) page.cancelSignIn(&a);
            page.startSignIn(&a, .antigravity);
            const current_call = a.view.agents.sign_in.?.call;
            if (new_first) try deliver(&a, 1, false);
            try deliver(&a, 0, true);
            try testing.expectEqual(@as(usize, 1), try cancellations(&a, "old-login"));
            if (!new_first) {
                try testing.expect(a.view.agents.sign_in.?.login_id == null);
                try testing.expectEqual(current_call, a.view.agents.sign_in.?.call);
                try deliver(&a, 0, false);
            }
            try testing.expectEqualStrings("current-login", a.view.agents.sign_in.?.login_id.?);
            try testing.expect(a.view.agents.sign_in.?.next_poll != null);
            try testing.expectEqual(@as(usize, 0), try cancellations(&a, "current-login"));
            page.cancelSignIn(&a);
            page.cancelSignIn(&a);
            try testing.expectEqual(@as(usize, 1), try cancellations(&a, "current-login"));
        }
    }
}

test "agent login lifecycle replacing an active attempt cancels its known login" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a, starts);
    page.startSignIn(&a, .antigravity);
    try deliver(&a, 0, false);
    page.startSignIn(&a, .antigravity);
    try testing.expectEqual(@as(usize, 1), try cancellations(&a, "old-login"));
    try testing.expect(a.view.agents.sign_in.?.login_id == null);
}

test "agent login lifecycle stale start failure leaves retry intact and current failure is reported" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a,
        \\{"StartAgentLogin":{"$seq":[{"$err":"Old synthetic failure"},{"$err":"Current synthetic failure"}]}}
    );
    page.startSignIn(&a, .antigravity);
    page.cancelSignIn(&a);
    page.startSignIn(&a, .antigravity);
    try deliver(&a, 0, false);
    try testing.expect(a.view.agents.sign_in != null);
    try testing.expect(a.view.agents.sign_in_failure == null);
    try deliver(&a, 0, false);
    try testing.expect(a.view.agents.sign_in == null);
    try testing.expectEqualStrings("Sign-in failed to start: Current synthetic failure", a.view.agents.sign_in_failure.?.message);
}

test "agent login lifecycle disconnected start fails synchronously and can be retried" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    page.startSignIn(&a, .antigravity);
    try testing.expect(a.view.agents.sign_in == null);
    try testing.expectEqualStrings("Sign-in failed to start: Engine not connected", a.view.agents.sign_in_failure.?.message);
    try scene(&a, starts);
    page.startSignIn(&a, .antigravity);
    try deliver(&a, 0, false);
    try testing.expect(a.view.agents.sign_in_failure == null);
    try testing.expectEqualStrings("old-login", a.view.agents.sign_in.?.login_id.?);
    page.cancelSignIn(&a);
    try testing.expectEqual(@as(usize, 1), try cancellations(&a, "old-login"));
}

test "agent login lifecycle cancelled start failure stays silent and malformed current reply fails" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    try scene(&a,
        \\{"StartAgentLogin":{"$seq":[{"$err":"Cancelled synthetic failure"},{}]}}
    );
    page.startSignIn(&a, .antigravity);
    page.cancelSignIn(&a);
    try deliver(&a, 0, false);
    try testing.expect(a.view.agents.sign_in_failure == null);
    page.startSignIn(&a, .antigravity);
    try deliver(&a, 0, false);
    try testing.expect(a.view.agents.sign_in == null);
    try testing.expectEqualStrings("Sign-in failed to start: Unexpected reply", a.view.agents.sign_in_failure.?.message);
}
