//! A WKWebView inside the native pane, deliberately WITHOUT nanoui's IPC
//! bridge. Ordinary websites never receive app/engine capabilities.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const web = @import("browser_url.zig");
const saved = @import("saved_view.zig");

pub const Events = struct {
    ctx: *anyopaque,
    changed: *const fn (*anyopaque) void,
};

pub const Native = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []u8,
    view: objc.Object,
    delegate: objc.Object,
    events: Events,
    saved_view: ?saved.View = null,
    loading: bool = false,
    visible: bool = false,
    attached: bool = false,
    allow_blank: bool = false,
    error_text: [512]u8 = undefined,
    error_len: usize = 0,
    rect: ?nanoui.ui.Rect = null,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, home: []const u8, events: Events) !*Native {
        const pool = objc.Pool.push();
        defer pool.pop();
        const self = try gpa.create(Native);
        errdefer gpa.destroy(self);
        const owned_home = try gpa.dupe(u8, home);
        errdefer gpa.free(owned_home);
        const cls = objc.defineClass(.{ .name = "HarnessNanoBrowserDelegate", .protocols = &.{ "WKNavigationDelegate", "WKURLSchemeHandler" }, .methods = &.{
            .{ .name = "webView:decidePolicyForNavigationAction:decisionHandler:", .imp = &decide, .types = "v@:@@@?" },
            .{ .name = "webView:didStartProvisionalNavigation:", .imp = &started, .types = "v@:@@" },
            .{ .name = "webView:didFinishNavigation:", .imp = &finished, .types = "v@:@@" },
            .{ .name = "webView:didFailNavigation:withError:", .imp = &failed, .types = "v@:@@@" },
            .{ .name = "webView:didFailProvisionalNavigation:withError:", .imp = &failed, .types = "v@:@@@" },
            .{ .name = "webView:startURLSchemeTask:", .imp = &schemeStart, .types = "v@:@@" },
            .{ .name = "webView:stopURLSchemeTask:", .imp = &schemeStop, .types = "v@:@@" },
        } });
        const delegate = objc.msg(objc.Object, cls, "new", .{});
        const config = objc.new("WKWebViewConfiguration");
        defer objc.release(config);
        // Tests never consult or change a person's website data.
        if (builtin.is_test) objc.msg(void, config, "setWebsiteDataStore:", .{objc.msg(objc.Object, objc.class("WKWebsiteDataStore"), "nonPersistentDataStore", .{})});
        objc.msg(void, config, "setURLSchemeHandler:forURLScheme:", .{ delegate, objc.nsString("graff-view") });
        const view = objc.msg(objc.Object, objc.alloc("WKWebView"), "initWithFrame:configuration:", .{ objc.CGRect{}, config });
        self.* = .{ .gpa = gpa, .io = io, .home = owned_home, .view = view, .delegate = delegate, .events = events };
        objc.setZig(delegate, self);
        objc.msg(void, view, "setNavigationDelegate:", .{delegate});
        objc.msg(void, view, "setHidden:", .{objc.YES});
        return self;
    }

    pub fn destroy(s: *Native) void {
        // WebKit may still deliver a cancellation after removeFromSuperview.
        objc.setZig(s.delegate, null);
        objc.msg(void, s.view, "setNavigationDelegate:", .{@as(?objc.Object, null)});
        objc.msg(void, s.view, "stopLoading", .{});
        objc.msg(void, s.view, "removeFromSuperview", .{});
        objc.release(s.view);
        objc.release(s.delegate);
        s.gpa.free(s.home);
        s.gpa.destroy(s);
    }

    pub fn navigate(s: *Native, address: []const u8) void {
        const generated = saved.fromUrl(address);
        if (generated == null and !web.allowedNavigation(address)) return;
        const pool = objc.Pool.push();
        defer pool.pop();
        s.saved_view = generated;
        s.allow_blank = false;
        s.error_len = 0;
        const target_url = objc.msg(?objc.Object, objc.class("NSURL"), "URLWithString:", .{objc.nsString(address)}) orelse return;
        const request = objc.msg(objc.Object, objc.class("NSURLRequest"), "requestWithURL:", .{target_url});
        _ = objc.msg(?objc.Object, s.view, "loadRequest:", .{request});
    }

    pub fn mount(s: *Native, parent: objc.Object, rect: nanoui.ui.Rect) void {
        if (!s.attached) {
            objc.msg(void, parent, "addSubview:", .{s.view});
            s.attached = true;
        }
        if (s.rect == null or !std.meta.eql(s.rect.?, rect)) {
            const bounds = objc.msg(objc.CGRect, parent, "bounds", .{});
            const flipped = objc.msg(objc.BOOL, parent, "isFlipped", .{});
            objc.msg(void, s.view, "setFrame:", .{objc.CGRect{ .origin = .{ .x = rect.x, .y = if (flipped) rect.y else bounds.size.height - rect.y - rect.h }, .size = .{ .width = rect.w, .height = rect.h } }});
            s.rect = rect;
        }
        s.show(true);
    }

    pub fn show(s: *Native, visible: bool) void {
        if (s.visible == visible) return;
        objc.msg(void, s.view, "setHidden:", .{if (visible) objc.NO else objc.YES});
        s.visible = visible;
    }

    pub fn url(s: *const Native) []const u8 {
        const u = objc.msg(?objc.Object, s.view, "URL", .{}) orelse return "";
        return objc.fromNSString(objc.msg(?objc.Object, u, "absoluteString", .{}));
    }

    pub fn title(s: *const Native) []const u8 {
        return objc.fromNSString(objc.msg(?objc.Object, s.view, "title", .{}));
    }

    pub fn canBack(s: *const Native) bool {
        return objc.msg(objc.BOOL, s.view, "canGoBack", .{});
    }

    pub fn canForward(s: *const Native) bool {
        return objc.msg(objc.BOOL, s.view, "canGoForward", .{});
    }

    pub fn back(s: *Native) void {
        _ = objc.msg(?objc.Object, s.view, "goBack", .{});
    }

    pub fn forward(s: *Native) void {
        _ = objc.msg(?objc.Object, s.view, "goForward", .{});
    }

    pub fn reload(s: *Native) void {
        _ = objc.msg(?objc.Object, s.view, "reload", .{});
    }

    fn notify(s: *Native) void {
        s.events.changed(s.events.ctx);
    }
};

const Decision = extern struct {
    isa: ?*anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *const fn (*const Decision, isize) callconv(.c) void,
};

fn decide(delegate: objc.Object, _: objc.SEL, _: objc.Object, action: objc.Object, handler: *const Decision) callconv(.c) void {
    const s = objc.getZig(Native, delegate) orelse return handler.invoke(handler, 0);
    const request = objc.msg(objc.Object, action, "request", .{});
    const url = objc.msg(?objc.Object, request, "URL", .{}) orelse return handler.invoke(handler, 0);
    const address = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    const frame = objc.msg(?objc.Object, action, "targetFrame", .{});
    const main = if (frame) |f| objc.msg(objc.BOOL, f, "isMainFrame", .{}) else true;
    const allowed = if (s.saved_view) |view| saved.allowedNavigation(view, address, main) else web.allowedNavigation(address) or (s.allow_blank and std.mem.eql(u8, address, "about:blank"));
    if (allowed and frame == null) {
        _ = objc.msg(?objc.Object, s.view, "loadRequest:", .{request});
        handler.invoke(handler, 0);
    } else handler.invoke(handler, if (allowed) 1 else 0);
}

fn started(delegate: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Native, delegate) orelse return;
    s.loading = true;
    s.error_len = 0;
    s.notify();
}

fn finished(delegate: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Native, delegate) orelse return;
    s.loading = false;
    s.notify();
}

fn failed(delegate: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object, err: objc.Object) callconv(.c) void {
    const s = objc.getZig(Native, delegate) orelse return;
    const text = objc.fromNSString(objc.msg(?objc.Object, err, "localizedDescription", .{}));
    s.error_len = @min(text.len, s.error_text.len);
    @memcpy(s.error_text[0..s.error_len], text[0..s.error_len]);
    s.loading = false;
    s.notify();
}

fn schemeStart(delegate: objc.Object, _: objc.SEL, _: objc.Object, task: objc.Object) callconv(.c) void {
    const s = objc.getZig(Native, delegate) orelse return schemeFail(task);
    const pool = objc.Pool.push();
    defer pool.pop();
    const request = objc.msg(objc.Object, task, "request", .{});
    const url = objc.msg(objc.Object, request, "URL", .{});
    const address = objc.fromNSString(objc.msg(?objc.Object, url, "absoluteString", .{}));
    const view = saved.fromUrl(address) orelse return schemeFail(task);
    const selected = s.saved_view orelse return schemeFail(task);
    if (!std.meta.eql(view, selected)) return schemeFail(task);
    const body = saved.read(s.gpa, s.io, s.home, view) catch return schemeFail(task);
    defer s.gpa.free(body);
    const keys = [_]objc.Object{ objc.nsString("Content-Type"), objc.nsString("Content-Security-Policy"), objc.nsString("Cache-Control") };
    const values = [_]objc.Object{ objc.nsString("text/html; charset=utf-8"), objc.nsString(view.csp()), objc.nsString("no-store") };
    const headers = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(objc.NSUInteger, keys.len) });
    const response = objc.msg(objc.Object, objc.alloc("NSHTTPURLResponse"), "initWithURL:statusCode:HTTPVersion:headerFields:", .{ url, @as(objc.NSInteger, 200), objc.nsString("HTTP/1.1"), headers });
    defer objc.release(response);
    objc.msg(void, task, "didReceiveResponse:", .{response});
    const data = objc.msg(objc.Object, objc.class("NSData"), "dataWithBytes:length:", .{ body.ptr, @as(objc.NSUInteger, body.len) });
    objc.msg(void, task, "didReceiveData:", .{data});
    objc.msg(void, task, "didFinish", .{});
}

fn schemeFail(task: objc.Object) void {
    const err = objc.msg(objc.Object, objc.class("NSError"), "errorWithDomain:code:userInfo:", .{ objc.nsString("HarnessNanoSavedView"), @as(objc.NSInteger, 1), @as(?objc.Object, null) });
    objc.msg(void, task, "didFailWithError:", .{err});
}

fn schemeStop(_: objc.Object, _: objc.SEL, _: objc.Object, _: objc.Object) callconv(.c) void {}
