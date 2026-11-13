//! Device-local choices for native new-chat wallpaper geometry.
const ui = @import("nanoui").ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const set = @import("view_settings.zig");
const wall = @import("wallpaper.zig");

pub fn card(c: *ui.Context, a: *App, k: theme.Colors) void {
    const box = ui.div(c).column().wFull().p(1).rounded(12).border(k.border).borderW(1).bg(if (k.frosted) k.card else k.shell);
    defer box.end();
    {
        const row = set.row(c, k, false, false);
        defer row.end();
        set.tile(c, k, .@"file-image");
        set.words(c, k, "New-chat wallpaper", "Optional art behind new chats only. Conversations stay plain.", 210);
        const choices = ui.div(c).row().gap(6);
        defer choices.end();
        inline for (.{ .{ "None", wall.Scene.none }, .{ "Dusk", wall.Scene.dusk }, .{ "Dunes", wall.Scene.dunes } }) |item| {
            if (choice(c, k, item[0], wall.scene(&a.settings) == item[1])) {
                a.settings.setText("newChatWallpaper", @tagName(item[1]));
                c.changed = true;
            }
        }
    }
    {
        const row = set.row(c, k, true, false);
        defer row.end();
        set.tile(c, k, .@"magic-stick-3");
        set.words(c, k, "Wallpaper parallax", "Follows the pointer, then settles. Reduce motion keeps the scene still.", 210);
        const choices = ui.div(c).row().gap(6);
        defer choices.end();
        inline for (.{ .{ "Off", wall.Reach.off }, .{ "Subtle", wall.Reach.subtle }, .{ "Normal", wall.Reach.normal } }) |item| {
            if (choice(c, k, item[0], wall.reach(&a.settings) == item[1])) {
                a.settings.setText("wallpaperParallax", @tagName(item[1]));
                c.changed = true;
            }
        }
    }
}

fn choice(c: *ui.Context, k: theme.Colors, label: []const u8, active: bool) bool {
    ui.key(c, label);
    const b = ui.div(c).row().h(28).px(10).itemsCenter().rounded(7).control()
        .border(if (active) k.accent else k.border).borderW(1)
        .bg(if (active) k.accent_wash else k.raised.alpha(0.3)).hover(k.hover);
    defer b.end();
    ui.text(c, label, .{ .size = 11.5, .color = if (active) k.accent else k.text });
    return b.clicked();
}
