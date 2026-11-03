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
    theme.registerFonts();
    const app = try nanoui.App.create(init, .{ .name = "Harness" });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io, Engine.portFrom(init.environ_map));
    defer a.deinit();
    a.new_harness = try init.gpa.dupe(u8, init.environ_map.get("HARNESS_NANO_HARNESS") orelse "graff");
    a.settings = .open(init.gpa, init.io, init.environ_map);
    a.env = init.environ_map;
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
    try @import("native_menu.zig").install(app, &a);
    a.window = try app.newWindow(.{
        .title = "Harness",
        .width = 1200,
        .height = 780,
        .min_width = 760,
        .min_height = 480,
        .title_bar = .hidden,
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
    try app.run();
}
