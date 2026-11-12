//! The desktop around the app: the clipboard, opening URLs and files in
//! other apps, the app's directories, the system's appearance and accent.
const std = @import("std");
const objc = @import("objc.zig");

pub const clipboard = struct {
    /// The clipboard's text, or null when it holds none. Caller frees it.
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        const s = objc.msg(?objc.Object, pb, "stringForType:", .{objc.nsString("public.utf8-plain-text")}) orelse return null;
        return try gpa.dupe(u8, objc.fromNSString(s));
    }

    pub fn writeText(text: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
        _ = objc.msg(objc.BOOL, pb, "setString:forType:", .{ objc.nsString(text), objc.nsString("public.utf8-plain-text") });
    }

    /// The image on the clipboard (a screenshot, an image copied from a
    /// page or an app) as PNG, or null when it holds none. Caller frees it.
    pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        if (objc.msg(?objc.Object, pb, "dataForType:", .{objc.nsString("public.png")})) |png| return try dupeData(gpa, png);
        const tiff = objc.msg(?objc.Object, pb, "dataForType:", .{objc.nsString("public.tiff")}) orelse return null;
        const rep = objc.msg(?objc.Object, objc.class("NSBitmapImageRep"), "imageRepWithData:", .{tiff}) orelse return null;
        const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
        // NSBitmapImageFileTypePNG
        const png = objc.msg(?objc.Object, rep, "representationUsingType:properties:", .{ @as(objc.NSUInteger, 4), props }) orelse return null;
        return try dupeData(gpa, png);
    }

    /// The paths of the files on the clipboard (copied in Finder), or null
    /// when it holds none. Free with `dialog.freePaths`.
    pub fn readFiles(gpa: std.mem.Allocator) !?[][]u8 {
        const pool = objc.Pool.push();
        defer pool.pop();
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        const classes = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{objc.class("NSURL")});
        const urls = objc.msg(?objc.Object, pb, "readObjectsForClasses:options:", .{ classes, @as(?objc.Object, null) }) orelse return null;
        const n = objc.msg(objc.NSUInteger, urls, "count", .{});
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |p| gpa.free(p);
            out.deinit(gpa);
        }
        for (0..n) |i| {
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
        const bytes = objc.msg([*]const u8, data, "bytes", .{});
        return try gpa.dupe(u8, bytes[0..len]);
    }

    /// Changes whenever anything writes to the clipboard.
    pub fn changeCount() isize {
        const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
        return objc.msg(objc.NSInteger, pb, "changeCount", .{});
    }
};

pub const shell = struct {
    /// Opens `url` (https:, mailto:, any scheme) in its default app.
    pub fn openUrl(url: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(url)}) orelse return false;
        return objc.msg(objc.BOOL, workspace(), "openURL:", .{u});
    }

    /// Opens the file or folder at `path` in its default app.
    pub fn openPath(file: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(file)});
        return objc.msg(objc.BOOL, workspace(), "openURL:", .{u});
    }

    /// Shows the file at `path` selected in a Finder window.
    pub fn showInFolder(file: []const u8) void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(file)});
        const arr = objc.msg(objc.Object, objc.class("NSArray"), "arrayWithObject:", .{u});
        objc.msg(void, workspace(), "activateFileViewerSelectingURLs:", .{arr});
    }

    /// Moves the file at `path` to the Trash.
    pub fn trash(file: []const u8) bool {
        const pool = objc.Pool.push();
        defer pool.pop();
        const u = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(file)});
        const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
        return objc.msg(objc.BOOL, fm, "trashItemAtURL:resultingItemURL:error:", .{ u, @as(?*anyopaque, null), @as(?*anyopaque, null) });
    }

    /// Plays the system's alert sound.
    pub fn beep() void {
        NSBeep();
    }

    fn workspace() objc.Object {
        return objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    }
};

extern "c" fn NSBeep() void;

pub const Directory = enum {
    /// ~/Library/Application Support/<app name>: settings, databases.
    data,
    /// ~/Library/Caches/<app name>: what can be made again.
    cache,
    home,
    documents,
    downloads,
    desktop,
    temp,
};

/// The path of a standard directory; for `data` and `cache`, the app's
/// own, created if missing. Caller frees it.
pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (dir == .temp) return gpa.dupe(u8, objc.fromNSString(NSTemporaryDirectory()));
    if (dir == .home) return gpa.dupe(u8, objc.fromNSString(NSHomeDirectory()));
    // NSSearchPathDirectory values.
    const which: objc.NSUInteger = switch (dir) {
        .data => 14, // application support
        .cache => 13,
        .documents => 9,
        .downloads => 15,
        .desktop => 12,
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

extern "c" fn NSTemporaryDirectory() objc.Object;
extern "c" fn NSHomeDirectory() objc.Object;

/// Whether the system shows dark mode.
pub fn isDark() bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    const appearance = objc.msg(objc.Object, nsapp, "effectiveAppearance", .{});
    const name = objc.fromNSString(objc.msg(?objc.Object, appearance, "name", .{}));
    return std.mem.indexOf(u8, name, "Dark") != null;
}

/// The accent color the user chose in System Settings, sRGB.
pub fn accentColor() [3]f32 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const c = objc.msg(objc.Object, objc.class("NSColor"), "controlAccentColor", .{});
    const srgb = objc.msg(objc.Object, objc.class("NSColorSpace"), "sRGBColorSpace", .{});
    const conv = objc.msg(?objc.Object, c, "colorUsingColorSpace:", .{srgb}) orelse return .{ 0.04, 0.52, 1 };
    return .{
        @floatCast(objc.msg(f64, conv, "redComponent", .{})),
        @floatCast(objc.msg(f64, conv, "greenComponent", .{})),
        @floatCast(objc.msg(f64, conv, "blueComponent", .{})),
    };
}
