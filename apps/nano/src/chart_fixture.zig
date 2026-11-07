//! Standalone OFFLINE visual fixture. Never connected to an account/engine.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Harness · DEMO FIXTURE" });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io, 27999);
    defer a.deinit();
    a.selected = try init.gpa.dupe(u8, "DEMO FIXTURE — not account data");
    var parsed = try std.json.parseFromSlice(std.json.Value, init.gpa, @embedFile("fixtures/agent_edits.json"), .{});
    defer parsed.deinit();
    try a.transcript.apply(parsed.value);
    a.dark = init.environ_map.get("HARNESS_CHART_LIGHT") == null;
    a.window = try app.newWindow(.{ .title = "Harness · DEMO FIXTURE (offline)", .width = 1200, .height = 900, .min_width = 760, .min_height = 480, .title_bar = .hidden, .theme = theme.ui(a.dark.?), .content = .{ .view = .init(&a, view) } });
    // Deliberately no a.start(): fixture must never touch a live engine.
    try app.run();
}
fn view(a: *App, c: *ui.Context) void {
    @import("view.zig").view(a, c);
    const badge = ui.div(c).fixed().offset(280, 10).px(10).py(4).rounded(4).bg(theme.colors(a.dark.?).code_bg).layer(50);
    ui.text(c, "OFFLINE DEMO FIXTURE · NOT ACCOUNT DATA", .{ .size = 10, .color = theme.colors(a.dark.?).muted });
    badge.end();
}
