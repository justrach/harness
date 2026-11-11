//! harness-nano: Harness's desktop app on nanoui. A window of its own,
//! drawn in Zig, over the same engine the GPUI app runs: the daemon (or
//! `harness headless`) on `HARNESS_IPC_PORT`. Nothing here holds workspace
//! state; the engine does, so both apps can be open on one engine at once.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const Engine = @import("engine.zig").Engine;
const theme = @import("theme.zig");
const crash_log = @import("crash_log.zig");

/// Warnings too, in every build: why a picture isn't drawn, say. A fatal
/// signal's stack trace in every build too, into the crash log.
pub const std_options: std.Options = .{ .log_level = .warn, .enable_segfault_handler = true };

pub fn main(init: std.process.Init) !void {
    const builtin = @import("builtin");
    var mobile_flag = (builtin.os.tag == .ios);
    var demo_flag = false;
    if (init.environ_map.get("HARNESS_MOBILE_PREVIEW")) |v| {
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true")) mobile_flag = true;
    }
    if (init.environ_map.get("HARNESS_MOBILE_DEMO")) |v| {
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true")) demo_flag = true;
    }
    {
        var args_it = try init.minimal.args.iterateAllocator(init.gpa);
        defer args_it.deinit();
        _ = args_it.next();
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--mobile")) mobile_flag = true;
            if (std.mem.eql(u8, arg, "--demo")) demo_flag = true;
        }
    }

    var embedded_host: ?*@import("ios_host.zig").EmbeddedHost = null;
    defer if (embedded_host) |eh| eh.stop();
    if (builtin.os.tag == .ios or (mobile_flag and demo_flag)) {
        embedded_host = try @import("ios_host.zig").EmbeddedHost.start(init.gpa, init.io, init.environ_map, demo_flag);
    }

    theme.registerFonts();
    const app = try nanoui.App.create(init, .{ .name = "Harness" });
    defer app.destroy();
    const engine_port = if (embedded_host) |eh| eh.port else Engine.portFrom(init.environ_map);
    var a: App = .init(init.gpa, init.io, engine_port);
    defer a.deinit();
    a.mobile_preview = mobile_flag;
    const harness_override = init.environ_map.get("HARNESS_NANO_HARNESS");
    a.new_harness = try init.gpa.dupe(u8, harness_override orelse "graff");
    a.settings = .open(init.gpa, init.io, init.environ_map);
    // The new chat opens on the last explicit picks, unless a scene or test
    // pinned its agent for this run.
    if (harness_override == null) @import("composer_defaults.zig").apply(&a);
    a.env = init.environ_map;
    @import("frame_profile.zig").start(&a);
    // Panics, fatal signals and hangs leave their stacks in ~/.harness/logs.
    if (a.settings.dataDir()) |dir| crash_log.start(init.io, dir);
    // Custom themes either app added, for the pickers and a picked one.
    if (a.settings.dataDir()) |dir| @import("themes.zig").loadLibrary(init.io, dir);
    a.view.setFilter(init.gpa, a.settings.spaceFilter());
    // System, Light or Dark, as Settings › Appearance has it.
    a.dark = switch (@import("view_settings_appearance.zig").mode(&a)) {
        .system => null,
        .light => false,
        .dark => true,
    };
    if (init.environ_map.get("HARNESS_MOBILE_THEME")) |tid| {
        if (tid.len > 0) a.mobile.setThemeOverride(init.gpa, tid);
    }
    if (init.environ_map.get("HARNESS_MOBILE_SHEET")) |sh| {
        if (std.mem.eql(u8, sh, "settings")) a.mobile.sheet = .settings;
        if (std.mem.eql(u8, sh, "new")) a.mobile.sheet = .new_session;
        if (std.mem.eql(u8, sh, "write")) a.mobile.sheet = .write_dock;
    }
    if (init.environ_map.get("HARNESS_MOBILE_SPLIT")) |sp| {
        a.mobile.split_mode = @import("ios_scroll.zig").SplitMode.parse(sp);
    }
    try @import("native_menu.zig").install(app, &a);
    // The same window size the desktop reopens with, rather than a one-off
    // Nano size that visibly jumps when moving between the two apps.
    const window_size = a.settings.windowSize();
    a.window = try app.newWindow(.{
        .title = "Harness",
        .width = window_size.width,
        .height = window_size.height,
        .min_width = if (mobile_flag) 320 else 760,
        .min_height = if (mobile_flag) 480 else 480,
        .title_bar = .hidden,
        .full_bleed = mobile_flag,
        .theme = theme.ui(nanoui.isDark()),
        .content = .{ .view = .init(&a, @import("view.zig").view) },
    });
    try a.start();
    // Whether this device can dictate, found off the main thread.
    @import("app_dictation.zig").probe(&a);
    // A chat to open at launch, for checks that render the window offscreen.
    if (init.environ_map.get("HARNESS_NANO_OPEN_CHAT")) |id| a.openChat(id, null);
    // Panels to open with it: "diffs", "files", or both.
    if (init.environ_map.get("HARNESS_NANO_PANELS")) |list| {
        a.panels.files_open = std.mem.indexOf(u8, list, "files") != null;
        if (std.mem.indexOf(u8, list, "diffs") != null) a.panels.tabs.append(a.gpa, .{ .kind = .diffs }) catch {};
        a.panels.host_open = a.panels.tabs.items.len > 0;
    }
    // Proves the crash log: a hang of 5 seconds, or a panic, once the
    // window is up.
    if (init.environ_map.get("HARNESS_NANO_CRASH_TEST")) |what| crash_log.selfTest(what);
    a.release.done = .{ .ctx = &a, .func = App.releaseCame };
    a.release.start();
    @import("graff_update.zig").start(&a);
    try app.run();
}
