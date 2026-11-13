//! The system around the app on iOS: the clipboard (UIPasteboard), opening
//! URLs in other apps, the app's sandbox directories, the appearance and
//! the tint. What a phone has no place for (a Finder to show a file in)
//! does nothing.
const std = @import("std");
const objc = @import("../objc.zig");

extern "c" fn UIImagePNGRepresentation(image: objc.Object) ?objc.Object;
extern "c" fn NSTemporaryDirectory() objc.Object;
extern "c" fn NSHomeDirectory() objc.Object;

fn board() objc.Object {
    return objc.msg(objc.Object, objc.class("UIPasteboard"), "generalPasteboard", .{});
}

/// Reading what another app copied may ask the user first (iOS 16 and
/// later); `changeCount` never does.
pub const clipboard = struct {
    /// The clipboard's text, or null when it holds none. Caller frees it.
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const s = objc.msg(?objc.Object, board(), "string", .{}) orelse return null;
        return try gpa.dupe(u8, objc.fromNSString(s));
    }

    pub fn writeText(text: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        objc.msg(void, board(), "setString:", .{objc.nsString(text)});
    }

    /// The image on the clipboard as PNG, or null when it holds none.
    /// Caller frees it.
    pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = board();
        if (objc.msg(?objc.Object, pb, "dataForPasteboardType:", .{objc.nsString("public.png")})) |png| return try dupeData(gpa, png);
        const image = objc.msg(?objc.Object, pb, "image", .{}) orelse return null;
        const png = UIImagePNGRepresentation(image) orelse return null;
        return try dupeData(gpa, png);
    }

    /// The files on the clipboard (file URLs), or null when it holds none.
    /// Free with `dialog.freePaths`.
    pub fn readFiles(gpa: std.mem.Allocator) !?[][]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const urls = objc.msg(?objc.Object, board(), "URLs", .{}) orelse return null;
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |p| gpa.free(p);
            out.deinit(gpa);
        }
        for (0..objc.msg(objc.NSUInteger, urls, "count", .{})) |i| {
            const url = objc.msg(objc.Object, urls, "objectAtIndex:", .{i});
            if (!objc.msg(objc.BOOL, url, "isFileURL", .{})) continue;
            try out.append(gpa, try gpa.dupe(u8, objc.fromNSString(objc.msg(?objc.Object, url, "path", .{}))));
        }
        if (out.items.len == 0) {
            out.deinit(gpa);
            return null;
        }
        return try out.toOwnedSlice(gpa);
    }

    fn dupeData(gpa: std.mem.Allocator, data: objc.Object) ![]u8 {
        const len = objc.msg(objc.NSUInteger, data, "length", .{});
        // No bytes at all for empty data.
        const bytes = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return try gpa.alloc(u8, 0);
        return try gpa.dupe(u8, bytes[0..len]);
    }

    /// Changes whenever anything writes to the clipboard.
    pub fn changeCount() isize {
        return objc.msg(objc.NSInteger, board(), "changeCount", .{});
    }
};

pub const shell = struct {
    /// Opens `url` (https:, mailto:, tel:, an app's scheme) in its app.
    pub fn openUrl(url: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return false;
        const app = objc.msg(objc.Object, objc.class("UIApplication"), "sharedApplication", .{});
        const opts = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
        objc.msg(void, app, "openURL:options:completionHandler:", .{ u, opts, @as(?*anyopaque, null) });
        return true;
    }

    /// Other apps can't open a file of this app's sandbox by its path.
    pub fn openPath(file: []const u8) bool {
        _ = file;
        return false;
    }

    /// There is no file manager to show it in.
    pub fn showInFolder(file: []const u8) void {
        _ = file;
    }

    /// Moves the file at `path` to the Trash, where the system has one.
    pub fn trash(file: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(file)});
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        return objc.msg(objc.BOOL, fm, "trashItemAtURL:resultingItemURL:error:", .{ u, @as(?*anyopaque, null), @as(?*anyopaque, null) });
    }

    /// A phone's alert: a warning tap of the haptic engine.
    pub fn beep() void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const g = objc.new("UINotificationFeedbackGenerator");
        defer objc.release(g);
        objc.msg(void, g, "notificationOccurred:", .{@as(objc.NSInteger, 1)});
    }
};

pub const Directory = enum {
    /// Library/Application Support/<app name>: settings, databases.
    data,
    /// Library/Caches/<app name>: what can be made again.
    cache,
    /// The app's container.
    home,
    /// Documents: what the Files app shows of the app, when Info.plist
    /// lets it (`UIFileSharingEnabled`).
    documents,
    /// No Downloads or Desktop on iOS: Documents.
    downloads,
    desktop,
    temp,
};

/// The path of a directory of the app's sandbox; for `data` and `cache`,
/// the app's own, created if missing. Caller frees it.
pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (dir == .temp) return gpa.dupe(u8, objc.fromNSString(NSTemporaryDirectory()));
    if (dir == .home) return gpa.dupe(u8, objc.fromNSString(NSHomeDirectory()));
    // NSSearchPathDirectory values.
    const which: objc.NSUInteger = switch (dir) {
        .data => 14, // application support
        .cache => 13,
        .documents, .downloads, .desktop => 9,
        else => unreachable,
    };
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const urls = objc.msg(objc.Object, fm, "URLsForDirectory:inDomains:", .{ which, @as(objc.NSUInteger, 1) });
    const first = objc.msg(?objc.Object, urls, "firstObject", .{}) orelse return error.NoSuchDirectory;
    const base = objc.fromNSString(objc.msg(?objc.Object, first, "path", .{}));
    if (dir != .data and dir != .cache) return gpa.dupe(u8, base);
    const full = try std.fs.path.join(gpa, &.{ base, app_name });
    errdefer gpa.free(full);
    _ = objc.msg(objc.BOOL, fm, "createDirectoryAtPath:withIntermediateDirectories:attributes:error:", .{
        objc.nsString(full), objc.YES, @as(?objc.Object, null), @as(?*anyopaque, null),
    });
    return full;
}

/// Whether the system shows dark mode.
pub fn isDark() bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const traits = objc.msg(objc.Object, objc.class("UITraitCollection"), "currentTraitCollection", .{});
    return objc.msg(objc.NSInteger, traits, "userInterfaceStyle", .{}) == 2;
}

/// The system's tint: blue (an app's own accent is in an asset catalog,
/// which nanoui's bundles don't have).
pub fn accentColor() [3]f32 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const c = objc.msg(objc.Object, objc.class("UIColor"), "systemBlueColor", .{});
    var rgba: [4]f64 = .{ 0.04, 0.52, 1, 1 };
    if (!objc.msg(objc.BOOL, c, "getRed:green:blue:alpha:", .{ &rgba[0], &rgba[1], &rgba[2], &rgba[3] })) return .{ 0.04, 0.52, 1 };
    return .{ @floatCast(rgba[0]), @floatCast(rgba[1]), @floatCast(rgba[2]) };
}
