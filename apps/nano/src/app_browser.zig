//! Browser surfaces are conversation-owned, lazy native views. Merely
//! launching nano or opening an empty tab must not start WebKit processes.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const web = @import("browser_url.zig");
const saved = @import("saved_view.zig");
pub const Native = if (builtin.os.tag == .macos) @import("browser_native.zig").Native else void;

pub const Browser = struct {
    app: *App,
    parent: []u8,
    url: []u8 = &.{},
    address: nanoui.ui.TextBuffer = .{},
    title: nanoui.ui.TextBuffer = .{},
    notice: nanoui.ui.TextBuffer = .{},
    saved_view: ?saved.View = null,
    native: ?*Native = null,
    body_node: u64 = 0,
    editing: bool = false,
    focus_address: bool = true,

    fn create(a: *App, parent: []const u8) !*Browser {
        const b = try a.gpa.create(Browser);
        errdefer a.gpa.destroy(b);
        b.* = .{ .app = a, .parent = try a.gpa.dupe(u8, parent) };
        b.title.set("Browser");
        return b;
    }

    pub fn destroy(b: *Browser) void {
        if (comptime builtin.os.tag == .macos) if (b.native) |n| n.destroy();
        const gpa = b.app.gpa;
        gpa.free(b.parent);
        gpa.free(b.url);
        gpa.destroy(b);
    }

    pub fn belongsTo(b: *const Browser, parent: ?[]const u8) bool {
        return if (parent) |p| std.mem.eql(u8, b.parent, p) else false;
    }

    pub fn navigate(b: *Browser, input: []const u8) void {
        if (b.saved_view != null) return;
        const url = web.normalize(b.app.gpa, input) catch |err| {
            b.notice.set(web.message(err));
            b.app.redraw();
            return;
        };
        b.app.gpa.free(b.url);
        b.url = url;
        b.address.set(url);
        b.notice.clear();
        b.focus_address = false;
        if (comptime builtin.os.tag == .macos) if (b.native) |n| n.navigate(b.url);
        b.app.redraw();
    }

    pub fn ensureNative(b: *Browser) void {
        if (comptime builtin.os.tag != .macos) return;
        if (b.native != null or b.url.len == 0 or b.app.window == null) return;
        const home = if (b.app.env) |env| env.get("HOME") orelse "" else "";
        const n = Native.create(b.app.gpa, b.app.io, home, .{ .ctx = b, .changed = nativeChanged }) catch {
            b.notice.set("The integrated browser could not start.");
            return;
        };
        b.native = n;
        n.navigate(b.url);
    }

    fn nativeChanged(ctx: *anyopaque) void {
        const b: *Browser = @ptrCast(@alignCast(ctx));
        const n = b.native orelse return;
        const title = n.title();
        if (title.len > 0) b.title.set(title);
        if (!b.editing) {
            const url = n.url();
            if (url.len > 0) b.address.set(url);
        }
        if (n.error_len > 0) b.notice.set(n.error_text[0..n.error_len]) else b.notice.clear();
        b.app.redraw();
    }
};

/// Transcript links are explicit HTTP(S), not address-bar guesses. A bad
/// link never falls through to an OS opener or a privileged URL scheme.
pub fn openLink(a: *App, parent: []const u8, url: []const u8) void {
    if (!web.allowedNavigation(url)) return;
    open(a, parent, url, null);
}

pub fn openBlank(a: *App) void {
    open(a, a.selected orelse return, null, null);
}

pub fn openSaved(a: *App, parent: []const u8, view: saved.View) void {
    const chat = a.findChat(parent) orelse return a.setNotice("This view's host is not known yet.");
    const local = a.device_id orelse return a.setNotice("This view's host is not known yet.");
    const host = chat.device_id orelse return a.setNotice("This view's host is not known yet.");
    if (!std.mem.eql(u8, local, host)) return a.setNotice("This view is saved on another computer. Open it there.");
    open(a, parent, null, view);
}

fn open(a: *App, parent: []const u8, url: ?[]const u8, view: ?saved.View) void {
    if (a.selected == null or !std.mem.eql(u8, a.selected.?, parent)) return;
    const b = Browser.create(a, parent) catch return;
    if (view) |v| {
        b.url = v.url(a.gpa) catch return b.destroy();
        b.saved_view = v;
        b.address.set(b.url);
        b.title.set(if (v.kind == .html) "Generated page" else "MCP App");
        b.focus_address = false;
    } else if (url) |u| b.navigate(u);
    if (a.panels.pending_browser) |old| old.destroy();
    a.panels.pending_browser = b;
    a.redraw();
}

pub fn settleFrame(a: *App) void {
    const p = &a.panels;
    const b = p.pending_browser orelse return;
    p.pending_browser = null;
    if (!b.belongsTo(a.selected)) return b.destroy();
    p.tabs.append(p.gpa, .{ .kind = .browser, .browser = b }) catch return b.destroy();
    p.active = p.tabs.items.len - 1;
    p.host_open = true;
}

/// Synchronize native visibility after the app has built its overlays.
/// Unlike frame timers, navigation callbacks wake the UI only on change.
pub fn syncNative(a: *App, c: *nanoui.ui.Context) void {
    if (comptime builtin.os.tag != .macos) return;
    const window = a.window orelse return;
    const active = if (a.panels.activeTab()) |t| t.browser else null;
    const modal = a.view.settings_open or a.picker != .none or a.view.palette.open or a.view.theme_import != null or
        a.view.account_menu or a.view.more_menu or a.view.filter_menu or a.view.space_menu;
    for (a.panels.tabs.items) |t| if (t.browser) |b| {
        const visible = active == b and a.panels.host_open and b.belongsTo(a.selected) and !modal;
        if (visible) b.ensureNative();
        const n = b.native orelse continue;
        if (visible) {
            if (c.rects.get(b.body_node)) |rect| {
                if (rect.w > 0 and rect.h > 0 and !overlayCovers(c, rect)) {
                    n.mount(nanoui.objc.msg(nanoui.objc.Object, window.nswindow, "contentView", .{}), rect);
                    continue;
                }
            } else c.changed = true;
        }
        n.show(false);
    };
}

fn overlayCovers(c: *nanoui.ui.Context, body: nanoui.ui.Rect) bool {
    for (c.nodes.items) |node| {
        if (node.style.layer == 0) continue;
        const r = c.rects.get(node.id) orelse {
            c.changed = true;
            return true;
        };
        if (r.x < body.x + body.w and r.x + r.w > body.x and r.y < body.y + body.h and r.y + r.h > body.y) return true;
    }
    return false;
}
