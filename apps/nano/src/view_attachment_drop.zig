//! Native file drops use nanoui's registered targets, then settle before
//! drawing the next frame. Switching panes must not free a drawn transcript.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");
const Allocator = std.mem.Allocator;

pub const State = struct {
    pending: ?Pending = null,
    // Native surfaces own the payload/window. Keep destination ownership here
    // across hover frames; rebuilding a mounted box must not retarget a drag.
    mounted: [@import("tabs.zig").max_panes]?Mounted = @splat(null),
    hover: ?struct { id: u64, destination: u64, cancelled: bool = false } = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.pending) |p| p.deinit(gpa);
        s.* = .{};
    }
};

const Mounted = struct { id: u64, destination: u64 };

const Pending = struct {
    urls: [][]u8,
    tab: usize,
    pane: ?usize,
    destination: u64,

    fn deinit(p: Pending, gpa: Allocator) void {
        for (p.urls) |url| gpa.free(url);
        gpa.free(p.urls);
    }
};

fn blocked(a: *const App) bool {
    return a.view.settings_open or @import("view.zig").menuKeepsKeys(a) or
        @import("view_chat_menu.zig").anyDialog(a) or a.wizard != null;
}

/// A fingerprint of the actual destination, including parked draft routing.
/// Refuse stale deliveries rather than attaching to another chat or host.
fn destination(a: *const App, pane: ?usize) ?u64 {
    var hash = std.hash.Wyhash.init(a.tabs.shown.items[a.tabs.active]);
    var chat: ?[]const u8 = a.selected;
    var draft: ?@import("tabs.zig").Draft = null;
    if (pane) |ix| {
        const split = a.tabs.layout() orelse return null;
        if (ix >= split.panes.items.len) return null;
        if (ix != split.focus) {
            chat = split.panes.items[ix];
            draft = split.drafts.items[ix];
        }
    }
    if (chat) |id| {
        const ch = a.findChat(id) orelse return null;
        if (ch.archived) return null;
        hash.update(id);
        hash.update(&.{0});
        hash.update(ch.device_id orelse "");
    } else {
        const space = if (draft) |d| (if (d.no_project) null else a.findSpace(d.space)) else a.newChatSpace();
        hash.update("draft");
        hash.update(&.{0});
        if (space) |sp| {
            hash.update(sp.id);
            hash.update(&.{0});
            hash.update(sp.device_id orelse "");
        }
        hash.update(&.{0});
        hash.update(if (draft) |d| d.device orelse "" else a.new_device orelse "");
    }
    if (a.queue_edit) |edit| hash.update(edit.row);
    // A resized/rearranged target is an obsolete mount, just as a replaced
    // chat is. Metadata/model updates intentionally do not affect ownership.
    if (a.tabs.layout()) |split| {
        hash.update(std.mem.asBytes(&split.axis));
        hash.update(std.mem.sliceAsBytes(split.shares.items));
        hash.update(std.mem.asBytes(&split.zoomed));
    }
    inline for (.{ "x", "y", "height", "chat_width" }) |field|
        hash.update(std.mem.asBytes(&@field(a.view.chrome, field)));
    return hash.final();
}

pub fn target(c: *ui.Context, a: *App, index: u32, pane: ?usize) void {
    if (c.input.drag_over == null and c.input.drop == null) a.file_drop.hover = null;
    if (blocked(a)) {
        if (a.file_drop.hover) |*hover| hover.cancelled = true;
        return;
    }
    const signature = destination(a, pane) orelse return;
    const id = c.node(index).id;
    const slot = pane orelse 0;
    if (slot >= a.file_drop.mounted.len) return;
    const previous = a.file_drop.mounted[slot];
    a.file_drop.mounted[slot] = .{ .id = id, .destination = signature };
    c.acceptDrop(index);
    if (c.input.drag_over) |point| if (c.rects.get(id)) |rect| if (rect.contains(point)) {
        if (a.file_drop.hover == null or a.file_drop.hover.?.id != id)
            a.file_drop.hover = .{ .id = id, .destination = signature };
        const hover = &a.file_drop.hover.?;
        if (hover.destination != signature) hover.cancelled = true;
        const unchanged_mount = if (previous) |mounted| mounted.id == id and mounted.destination == signature else false;
        if (!unchanged_mount) hover.cancelled = true;
    };
    const drop = c.dropAt(index) orelse return;
    // Text is not an attachment payload. Leave it available to a text drop
    // consumer, without swallowing it or displaying an attachment error.
    if (drop.urls.len == 0) return;
    // The native payload is borrowed for this frame only. Consume it once,
    // and own a copy until the pre-tree boundary can safely focus its pane.
    c.input.drop = null;
    const stale_mount = if (previous) |mounted| mounted.id != id or mounted.destination != signature else true;
    const stale_hover = if (a.file_drop.hover) |hover| hover.id != id or hover.cancelled or hover.destination != signature else false;
    if (stale_mount or stale_hover) {
        a.file_drop.hover = null;
        a.setNotice("The drop destination changed. Drop the files into the intended chat again.");
        return;
    }
    a.file_drop.hover = null;
    const urls = a.gpa.alloc([]u8, drop.urls.len) catch return a.setNotice("Couldn't prepare the dropped files. Try Attach files.");
    var n: usize = 0;
    for (drop.urls) |url| {
        urls[n] = a.gpa.dupe(u8, url) catch {
            for (urls[0..n]) |owned| a.gpa.free(owned);
            a.gpa.free(urls);
            return a.setNotice("Couldn't prepare the dropped files. Try Attach files.");
        };
        n += 1;
    }
    if (a.file_drop.pending) |pending| pending.deinit(a.gpa);
    a.file_drop.pending = .{ .urls = urls, .tab = a.tabs.active, .pane = pane, .destination = signature };
    c.frameIn(0);
    a.redraw();
}

pub fn prepare(a: *App) void {
    const pending = a.file_drop.pending orelse return;
    a.file_drop.pending = null;
    defer pending.deinit(a.gpa);
    if (blocked(a) or pending.tab != a.tabs.active or pending.destination != destination(a, pending.pane)) {
        a.setNotice("The drop destination changed. Drop the files into the intended chat again.");
        return;
    }
    var focused = false;
    for (pending.urls) |url| {
        if (url.len == 0) continue;
        const path = filePath(a.gpa, url) catch {
            a.setNotice("Only local files and images can be attached. Use Attach files to choose one.");
            continue;
        };
        defer a.gpa.free(path);
        // Reject bad/empty/oversize files before activating a different pane
        // or disturbing its draft/queue edit. Valid siblings still attach.
        const bytes = attachments.readFile(a, path) catch {
            a.setNotice("Couldn't attach the dropped file. Choose a readable, non-empty file up to 24 MB.");
            continue;
        };
        defer a.gpa.free(bytes);
        if (!focused) {
            if (pending.pane) |ix| {
                a.focusPane(ix);
                if ((a.tabs.layout() orelse return).focus != ix) {
                    a.setNotice("Couldn't focus the drop destination. Try again.");
                    return;
                }
            }
            focused = true;
        }
        attachments.stage(a, std.fs.path.basename(path), bytes) catch {
            a.setNotice("Couldn't attach the dropped file. Choose a readable, non-empty file up to 24 MB.");
        };
    }
}

/// AppKit supplies file URLs (percent-encoded UTF-8), Windows also supplies
/// absolute paths. Never treat a remote URL/authority as a local filename.
pub fn filePath(gpa: Allocator, url: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, url, 0) != null) return error.InvalidFileUrl;
    if (std.fs.path.isAbsolute(url)) return gpa.dupe(u8, url);
    if (!std.mem.startsWith(u8, url, "file://")) return error.NotLocalFile;
    const rest = url[7..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NotLocalFile;
    if (slash > 0 and !std.ascii.eqlIgnoreCase(rest[0..slash], "localhost")) return error.NotLocalFile;
    const raw = rest[slash..];
    const path = try gpa.alloc(u8, raw.len);
    errdefer gpa.free(path);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const byte = if (raw[i] == '%') value: {
            if (i + 2 >= raw.len) return error.InvalidFileUrl;
            const hi = try std.fmt.charToDigit(raw[i + 1], 16);
            const lo = try std.fmt.charToDigit(raw[i + 2], 16);
            i += 2;
            break :value hi * 16 + lo;
        } else raw[i];
        if (byte == 0) return error.InvalidFileUrl;
        path[n] = byte;
        n += 1;
    }
    return gpa.realloc(path, n);
}

test "file drop paths decode local URLs without accepting remote hosts or NULs" {
    const a = std.testing.allocator;
    const path = try filePath(a, "file://localhost/tmp/synthetic%20%23%E2%9C%93.png");
    defer a.free(path);
    try std.testing.expectEqualStrings("/tmp/synthetic #✓.png", path);
    for ([_][]const u8{ "https://example.invalid/image.png", "file://remote/tmp/image.png", "file:///tmp/%00.png", "file:///tmp/%xx", "file:///tmp/%" }) |url|
        try std.testing.expectError(if (std.mem.startsWith(u8, url, "https") or std.mem.startsWith(u8, url, "file://remote")) error.NotLocalFile else if (std.mem.endsWith(u8, url, "%xx")) error.InvalidCharacter else error.InvalidFileUrl, filePath(a, url));
}
