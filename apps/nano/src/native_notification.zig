//! macOS system-owned session alerts. In background a chime is attached to
//! the notification, never played separately: Focus and per-app notification
//! sound preferences remain the system's decision. No Focus preferences are
//! read or changed. Unbundled development runs report unavailable capability.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("nanoui").objc;
extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

pub fn focused() bool {
    if (builtin.os.tag != .macos) return true;
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    return objc.msg(objc.BOOL, app, "isActive", .{}) and objc.msg(?objc.Object, app, "keyWindow", .{}) != null;
}

fn center() ?objc.Object {
    if (builtin.os.tag != .macos) return null;
    const cls = objc_getClass("NSUserNotificationCenter") orelse return null;
    return objc.msg(?objc.Object, cls, "defaultUserNotificationCenter", .{});
}

pub fn available() bool {
    if (builtin.os.tag != .macos) return false;
    return objc_getClass("NSUserNotification") != null and center() != null;
}

pub fn soundAvailable(name: [:0]const u8) bool {
    if (!available()) return false;
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.msg(?objc.Object, bundle, "pathForResource:ofType:", .{ objc.nsString(name), @as(?objc.Object, null) }) != null;
}

/// True only when the notification was handed to the native center. A missing
/// center/bundle can fall back locally; system suppression after delivery must
/// NOT fall back to direct audio, which would bypass Focus.
pub fn post(title: [:0]const u8, body: [:0]const u8, sound_name: ?[:0]const u8) bool {
    return postForChat(title, body, sound_name, null, null);
}

pub fn postForChat(title: [:0]const u8, body: [:0]const u8, sound_name: ?[:0]const u8, chat: ?[]const u8, workspace: ?[]const u8) bool {
    if (builtin.os.tag != .macos) return false;
    const c = center() orelse return false;
    const note = notification(title, body, sound_name, chat, workspace) orelse return false;
    defer objc.msg(void, note, "release", .{});
    // Match the original preference: a banner explicitly enabled in the
    // foreground is not silently discarded by the native center.
    objc.msg(void, c, "setDelegate:", .{presentationDelegate()});
    objc.msg(void, c, "deliverNotification:", .{note});
    return true;
}

fn notification(title: [:0]const u8, body: [:0]const u8, sound_name: ?[:0]const u8, chat: ?[]const u8, workspace: ?[]const u8) ?objc.Object {
    const cls = objc_getClass("NSUserNotification") orelse return null;
    const note = objc.msg(objc.Object, cls, "new", .{});
    objc.msg(void, note, "setTitle:", .{objc.nsString(title)});
    objc.msg(void, note, "setInformativeText:", .{objc.nsString(body)});
    // Explicit nil still prevents the system's chime doubling local audio.
    const sound: ?objc.Object = if (sound_name) |name| objc.nsString(name) else null;
    objc.msg(void, note, "setSoundName:", .{sound});
    if (chat) |id| if (workspace) |locator| {
        const values = [_]objc.Object{ objc.nsString(id), objc.nsString(locator) };
        const keys = [_]objc.Object{ objc.nsString("harnessChatId"), objc.nsString("harnessWorkspace") };
        const payload = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, 2) });
        objc.msg(void, note, "setUserInfo:", .{payload});
    };
    return note;
}

pub const ActivationHandler = struct {
    ctx: *anyopaque,
    activate: *const fn (*anyopaque, []const u8, []const u8) void,
};
var activation_handler: ?ActivationHandler = null;
pub fn setActivationHandler(handler: ActivationHandler) void {
    activation_handler = handler;
}
pub fn clearActivationHandler(ctx: *anyopaque) void {
    if (activation_handler) |handler| if (handler.ctx == ctx) {
        activation_handler = null;
    };
}
fn payloadString(payload: objc.Object, key: []const u8) ?[]const u8 {
    const value = objc.msg(?objc.Object, payload, "objectForKey:", .{objc.nsString(key)}) orelse return null;
    if (!objc.msg(objc.BOOL, value, "isKindOfClass:", .{objc.class("NSString")})) return null;
    const size = objc.msg(objc.NSUInteger, value, "lengthOfBytesUsingEncoding:", .{@as(objc.NSUInteger, 4)});
    if (size == 0 or size > 4096) return null;
    const bytes = objc.msg(?[*]const u8, value, "UTF8String", .{}) orelse return null;
    if (std.mem.indexOfScalar(u8, bytes[0..size], 0) != null) return null;
    return bytes[0..size];
}
fn didActivate(_: objc.Object, _: objc.SEL, _: objc.Object, note: objc.Object) callconv(.c) void {
    const handler = activation_handler orelse return;
    const payload = objc.msg(?objc.Object, note, "userInfo", .{}) orelse return;
    if (!objc.msg(objc.BOOL, payload, "isKindOfClass:", .{objc.class("NSDictionary")})) return;
    const chat = payloadString(payload, "harnessChatId") orelse return;
    const workspace = payloadString(payload, "harnessWorkspace") orelse return;
    handler.activate(handler.ctx, chat, workspace);
}

var delegate: ?objc.Object = null;
fn presentationDelegate() objc.Object {
    if (delegate) |d| return d;
    const cls = objc.defineClass(.{ .name = "HarnessNanoNotificationDelegate", .protocols = &.{"NSUserNotificationCenterDelegate"}, .methods = &.{
        .{ .name = "userNotificationCenter:shouldPresentNotification:", .imp = @ptrCast(&shouldPresent), .types = "c@:@@" },
        .{ .name = "userNotificationCenter:didActivateNotification:", .imp = @ptrCast(&didActivate), .types = "v@:@@" },
    } });
    const d = objc.msg(objc.Object, cls, "new", .{});
    delegate = d; // The center retains its delegate weakly; process singleton.
    return d;
}
test "external navigation native notification delegate exposes activation routing" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    const d = presentationDelegate();
    try @import("std").testing.expect(objc.msg(objc.BOOL, d, "respondsToSelector:", .{objc.sel("userNotificationCenter:didActivateNotification:")}));
}

test "external navigation native activation payload preserves tabs and rejects stale workspace and teardown" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const pool = objc.Pool.push();
    defer pool.pop();
    var h: @import("tests_ui_tab_strip.zig").Harness = undefined;
    try h.init(true);
    defer h.deinit();
    h.a.account.scope = .local;
    h.a.chats_synced = true;
    const External = @import("app_external_navigation.zig");
    var navigation: External.State = .{};
    defer navigation.deinit(testing.allocator);
    const Probe = struct {
        app: *@import("app.zig").App,
        navigation: *External.State,
        calls: usize = 0,
        fn click(ctx: *anyopaque, chat: []const u8, workspace: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.navigation.openTarget(self.app, chat, workspace);
        }
    };
    var probe: Probe = .{ .app = &h.a, .navigation = &navigation };
    setActivationHandler(.{ .ctx = &probe, .activate = Probe.click });
    defer clearActivationHandler(&probe);
    const locator = External.localLocator("local").?;
    const note = notification("Synthetic completion", "Synthetic body", "harness-done.wav", "b", &locator) orelse return error.SkipZigTest;
    defer objc.release(note);
    const d = presentationDelegate();
    const fake_center = objc.msg(objc.Object, objc.class("NSObject"), "new", .{});
    defer objc.release(fake_center);
    // A real Objective-C delegate event with the exact payload constructor
    // postForChat uses, but no delivery or system notification is performed.
    objc.msg(void, d, "userNotificationCenter:didActivateNotification:", .{ fake_center, note });
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expect(h.a.tabs.find("a") != null);
    const count = h.a.tabs.items.items.len;
    objc.msg(void, d, "userNotificationCenter:didActivateNotification:", .{ fake_center, note });
    try testing.expectEqual(count, h.a.tabs.items.items.len);
    h.a.openChatInTab("a");
    const foreign = External.localLocator("different-device").?;
    const stale = notification("Synthetic old alert", "Synthetic", null, "b", &foreign).?;
    defer objc.release(stale);
    objc.msg(void, d, "userNotificationCenter:didActivateNotification:", .{ fake_center, stale });
    try testing.expectEqualStrings("a", h.a.selected.?);
    const missing = notification("Synthetic payloadless", "Synthetic", null, null, null).?;
    defer objc.release(missing);
    const calls = probe.calls;
    objc.msg(void, d, "userNotificationCenter:didActivateNotification:", .{ fake_center, missing });
    try testing.expectEqual(calls, probe.calls);
    clearActivationHandler(&probe);
    objc.msg(void, d, "userNotificationCenter:didActivateNotification:", .{ fake_center, note });
    try testing.expectEqual(calls, probe.calls);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expect(objc.msg(objc.BOOL, d, "userNotificationCenter:shouldPresentNotification:", .{ fake_center, note }));
}

fn shouldPresent(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) objc.BOOL {
    return true;
}
