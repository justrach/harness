//! Native file drops use nanoui's registered targets, then settle before
//! drawing the next frame. Switching panes must not free a drawn transcript.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const attachments = @import("app_attachments.zig");
const Allocator = std.mem.Allocator;

pub const State = struct {
    pending: ?Pending = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.pending) |p| p.deinit(gpa);
        s.* = .{};
    }
};

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
    return hash.final();
}

/// The legacy attachment_drop_veil: shade only the receiving conversation
/// while OS files hover, without activating it until the actual drop.
/// Never retain hover state: native exit/cancellation clears drag_over.
pub fn shade(c: *ui.Context, a: *App, k: @import("theme.zig").Colors, index: u32) void {
    if (blocked(a)) return;
    const point = c.input.drag_over orelse return;
    const rect = c.rects.get(c.node(index).id) orelse return;
    if (!rect.contains(point)) return;
    const scrim: ui.Color = .{ .a = if (k.dark) 0.4 else 0.32 * (0.4 / 0.6) };
    const veil = ui.div(c).absolute().offset(0, 0).sizeFull().center().layer(5).bg(scrim).rounded(9);
    defer veil.end();
    ui.text(c, "Drop to attach", .{ .size = 13, .color = k.text });
}

pub fn target(c: *ui.Context, a: *App, index: u32, pane: ?usize) void {
    if (blocked(a)) return;
    c.acceptDrop(index);
    const drop = c.dropAt(index) orelse return;
    // The native payload is borrowed for this frame only. Consume it once,
    // and own a copy until the pre-tree boundary can safely focus its pane.
    c.input.drop = null;
    if (drop.urls.len == 0) {
        a.setNotice("Drop a file or image from Finder, or use Attach files.");
        return;
    }
    const signature = destination(a, pane) orelse return;
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
    a.file_drop.deinit(a.gpa);
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
    if (pending.pane) |ix| {
        a.focusPane(ix);
        if ((a.tabs.layout() orelse return).focus != ix) {
            a.setNotice("Couldn't focus the drop destination. Try again.");
            return;
        }
    }
    for (pending.urls) |url| {
        if (url.len == 0) continue;
        const path = filePath(a.gpa, url) catch {
            a.setNotice("Only local files and images can be attached. Use Attach files to choose one.");
            continue;
        };
        defer a.gpa.free(path);
        attachments.stageFile(a, path) catch {
            a.setNotice("Couldn't attach the dropped file. Choose a readable, non-empty file up to 24 MB.");
        };
    }
}

/// AppKit supplies file URLs (percent-encoded UTF-8), Windows also supplies
/// absolute paths. Never treat a remote URL/authority as a local filename.
pub fn filePath(gpa: Allocator, url: []const u8) ![]u8 {
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
