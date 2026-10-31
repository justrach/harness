//! Settings › Appshots, as the GPUI app's (settings/appshots.rs): capture
//! on or off, its sound, the global shortcut, where captures go, and the
//! two permissions macOS asks for. The choices are the GPUI app's own
//! (`appshotsEnabled`, `appshotSoundEnabled`, `appshotDestination`,
//! `keymap.captureAppshot`); Harness takes the captures.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const set = @import("view_settings.zig");
const shortcuts = @import("shortcuts.zig");
const App = @import("app.zig").App;

/// Where a capture goes (`AppshotDestination`), as saved.
pub const Destination = enum {
    automatic,
    last_session,
    new_session,

    pub fn key(d: Destination) []const u8 {
        return switch (d) {
            .automatic => "automatic",
            .last_session => "last-session",
            .new_session => "new-session",
        };
    }

    fn label(d: Destination) []const u8 {
        return switch (d) {
            .automatic => "Automatic",
            .last_session => "Last session",
            .new_session => "New session",
        };
    }

    fn description(d: Destination) []const u8 {
        return switch (d) {
            .automatic => "Use the open session, or the new-session composer when no session is open.",
            .last_session => "Use the open session, or return to the last session used for an Appshot.",
            .new_session => "Stage captures in a new-session composer, keeping existing drafts intact.",
        };
    }
};

pub fn destination(a: *const App) Destination {
    const v = a.settings.text("appshotDestination") orelse return .automatic;
    inline for (comptime std.enums.values(Destination)) |d| if (std.mem.eql(u8, d.key(), v)) return d;
    return .automatic;
}

/// A permission's state (`CapabilityState`), as its badge says it.
pub const Capability = enum {
    ready,
    required,

    fn badge(s: Capability) []const u8 {
        return switch (s) {
            .ready => "Ready",
            .required => "Required",
        };
    }
};

/// Screen Recording and Accessibility, as macOS says this process has them.
pub const Capabilities = struct { capture: Capability, text: Capability };

pub fn capabilities() Capabilities {
    return .{
        .capture = if (ask("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGPreflightScreenCaptureAccess")) .ready else .required,
        .text = if (ask("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", "AXIsProcessTrusted")) .ready else .required,
    };
}

/// A yes-or-no question for the system, looked up where the system has it.
fn ask(lib: [*:0]const u8, name: [*:0]const u8) bool {
    if (comptime @import("builtin").os.tag != .macos) return false;
    const h = std.c.dlopen(lib, .{ .LAZY = true }) orelse return false;
    const f: *const fn () callconv(.c) bool = @ptrCast(@alignCast(std.c.dlsym(h, name) orelse return false));
    return f();
}

/// Asks for one, the first time; System Settings after (`request_*_access`).
pub fn request(lib: [*:0]const u8, name: [*:0]const u8) void {
    if (comptime @import("builtin").os.tag != .macos) return;
    const h = std.c.dlopen(lib, .{ .LAZY = true }) orelse return;
    const f: *const fn () callconv(.c) bool = @ptrCast(@alignCast(std.c.dlsym(h, name) orelse return));
    _ = f();
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const caps = capabilities();
    const on = a.settings.get(.appshots_enabled);
    set.header(c, k, "Appshots", null);
    {
        // `page_subtitle(…).line_height(20)`, the column's width.
        set.space(c, 4);
        const sub = ui.div(c).column().w(set.inner_w);
        defer sub.end();
        ui.text(c, "Set up once, one permission at a time. Screen Recording captures the window; Accessibility optionally adds off-screen application text.", .{ .size = 13, .line_height = 20, .wrap = true, .color = k.muted });
    }
    {
        const cd = set.card(c, k);
        defer cd.end();
        {
            const r = row(c, k, true, "Capture Appshots", "Captures are staged for review and never sent automatically.", 32);
            defer r.end();
            if (toggle(c, k, on)) a.settings.toggle(.appshots_enabled);
        }
        {
            const r = row(c, k, false, "Capture sound", "Play a sound when an Appshot is ready.", 32);
            defer r.end();
            if (toggle(c, k, a.settings.get(.appshot_sound_enabled))) a.settings.toggle(.appshot_sound_enabled);
        }
        {
            const r = row(c, k, false, "Global shortcut", "The shortcut works while another application has focus.", badgeW(c, "Ready") + 10 + chipW(c, a));
            defer r.end();
            const ctl = ui.div(c).row().gap(10).itemsCenter();
            defer ctl.end();
            badge(c, k, "Ready");
            chip(c, a, k);
        }
        {
            const d = destination(a);
            var segs_w: f32 = 2 * 6;
            inline for (comptime std.enums.values(Destination)) |opt| segs_w += 22 + @ceil(c.text.width(opt.label(), .{ .size = 11 }));
            const r = row(c, k, false, "Destination", d.description(), segs_w);
            defer r.end();
            const segs = ui.div(c).row().gap(6).itemsCenter();
            defer segs.end();
            inline for (comptime std.enums.values(Destination)) |opt| {
                const lit = d == opt;
                // 10 by 7 inside the border, as GPUI's.
                var b = ui.div(c).row().px(11).py(8).rounded(7).borderW(1).border(if (lit) k.text.alpha(0.24) else k.border);
                if (lit) b = b.bg(k.ink(0.09));
                defer b.end();
                ui.text(c, opt.label(), .{ .size = 11, .line_height = 11 * 1.618, .color = if (lit) k.text else k.muted });
                if (b.clicked()) a.settings.setText("appshotDestination", opt.key());
            }
        }
        {
            const capture_label = if (a.view.capture_asked) "Open System Settings" else "Allow window capture";
            const capture_act = on and caps.capture == .required;
            const r = row(c, k, false, "Window capture", "Screen Recording lets Harness capture the frontmost window. macOS may request one restart.", badgeW(c, caps.capture.badge()) + (if (capture_act) 10 + actionW(c, capture_label) else 0));
            defer r.end();
            const ctl = ui.div(c).row().gap(10).itemsCenter();
            defer ctl.end();
            badge(c, k, caps.capture.badge());
            if (capture_act) if (action(c, k, capture_label)) {
                if (a.view.capture_asked) {
                    _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture");
                } else {
                    a.view.capture_asked = true;
                    request("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGRequestScreenCaptureAccess");
                }
            };
        }
        {
            const text_label = if (a.view.text_asked) "Open System Settings" else "Enable text capture";
            const text_act = on and caps.text == .required;
            const r = row(c, k, false, "Application text", "Accessibility adds visible and off-screen application text. Screenshots work without it.", badgeW(c, caps.text.badge()) + (if (text_act) 10 + actionW(c, text_label) else 0));
            defer r.end();
            const ctl = ui.div(c).row().gap(10).itemsCenter();
            defer ctl.end();
            badge(c, k, caps.text.badge());
            if (text_act) if (action(c, k, text_label)) {
                if (!a.view.text_asked) a.view.text_asked = true;
                _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
            };
        }
    }
    {
        // The recorder's helper line: Escape, or why keys were refused.
        set.space(c, 8);
        const h = ui.div(c).row().wFull().itemsCenter();
        defer h.end();
        // At least 20 tall (`min_h`).
        _ = c.leaf(.{ .width = .{ .px = 0 }, .height = .{ .px = 20 } }, .none, null);
        const helper = if (a.view.recording == shortcuts.all.len) "Press Escape to cancel." else a.view.shortcut_notice.items;
        ui.text(c, helper, .{ .size = 12, .line_height = 12 * 1.618, .color = k.muted });
    }
    set.space(c, 12);
    const foot = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer foot.end();
    {
        const t = ui.div(c).row().grow().w(0);
        defer t.end();
        ui.text(c, "Changed a permission? Check again after returning to Harness.", .{ .size = 12, .line_height = 12 * 1.618, .color = k.muted });
    }
    // Read every frame: Check again only says so.
    _ = action(c, k, "Check again");
}

/// `row`: the title and its line, at least 160 wide, the control
/// (`control_w` wide) after.
fn row(c: *ui.Context, k: theme.Colors, first: bool, title: []const u8, description: []const u8, control_w: f32) ui.Div {
    ui.key(c, title);
    const r = set.row(c, k, first, false);
    {
        // Wrapped text needs its width up front: the row less its insets,
        // the gap and the control.
        const w = ui.div(c).column().w(@max(set.inner_w - 2 - 2 * 20 - 14 - control_w, 160)).gap(4);
        defer w.end();
        ui.text(c, title, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
        ui.text(c, description, .{ .size = 12, .line_height = 18, .wrap = true, .color = k.muted });
    }
    return r;
}

/// The bare `toggle_switch`: the row's control, at its edge.
fn toggle(c: *ui.Context, k: theme.Colors, on: bool) bool {
    const track = ui.div(c).row().w(32).h(18).roundedFull().bg(if (on) k.text else k.ink(0.15)).pl(if (on) 16 else 2).itemsCenter();
    defer track.end();
    _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = if (on) k.on_solid else k.ink(0.7) }, .none, null);
    return track.clicked();
}

fn badgeW(c: *ui.Context, label: []const u8) f32 {
    return 2 * 8 + 2 + c.text.width(label, .{ .size = 10.5 });
}

fn actionW(c: *ui.Context, label: []const u8) f32 {
    return 2 * 10 + c.text.width(label, .{ .size = 12 });
}

fn chipW(c: *ui.Context, a: *const App) f32 {
    var buf: [64]u8 = undefined;
    const shown = shortcuts.display(&buf, a.settings.combo(shortcuts.appshot));
    const reset: f32 = if (std.mem.eql(u8, a.settings.combo(shortcuts.appshot), shortcuts.appshot.default)) 0 else 10 + c.text.width("Reset", .{ .size = 11 });
    return @max(96, 2 * 13 + 2 + c.text.width(shown, .{ .size = 12, .mono = true })) + reset;
}

/// `badge`: a hairline pill, 8 by 2 inside its border (which GPUI's box
/// holds, and nanoui draws over: 9 by 3 here).
pub fn badge(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const b = ui.div(c).row().px(9).py(3).roundedFull().border(k.border).borderW(1);
    defer b.end();
    ui.text(c, label, set.st(c, 10.5, .{ .color = k.muted }));
}

/// `ghost_action`: 12-point muted words, a wash under the pointer.
pub fn action(c: *ui.Context, k: theme.Colors, label: []const u8) bool {
    const b = ui.div(c).row().px(10).py(6).gap(6).rounded(8).itemsCenter().hover(k.ink(0.06));
    defer b.end();
    ui.text(c, label, set.st(c, 12, .{ .color = if (b.hovered()) k.text else k.muted }));
    return b.clicked();
}

/// The shortcut's chip, recorded as a Shortcuts page chip is.
fn chip(c: *ui.Context, a: *App, k: theme.Colors) void {
    const sc = shortcuts.appshot;
    const ix = shortcuts.all.len;
    const combo = a.settings.combo(sc);
    const recording = a.view.recording == ix;
    if (!recording and !std.mem.eql(u8, combo, sc.default)) {
        const reset = ui.div(c).row().itemsCenter();
        defer reset.end();
        ui.text(c, "Reset", set.st(c, 11, .{ .color = if (reset.hovered()) k.text else k.muted.alpha(0.7) }));
        if (reset.clicked()) a.settings.setCombo(sc, null);
    }
    var b = ui.div(c).row().minW(96).px(13).py(7).rounded(8).justifyCenter().borderW(1);
    b = if (recording) b.bg(k.text).border(k.text.alpha(0.3)) else b.bg(k.background).border(k.border).hover(k.ink(0.03));
    defer b.end();
    var buf: [64]u8 = undefined;
    const label = if (recording) "Press keys…" else shortcuts.display(&buf, combo);
    ui.text(c, c.print("{s}", .{label}), .{ .size = 12, .line_height = 12 * 1.618, .mono = true, .color = if (recording) k.on_solid else k.text });
    if (b.clicked()) {
        a.view.recording = if (recording) null else ix;
        a.view.shortcut_notice.clearRetainingCapacity();
    }
}
