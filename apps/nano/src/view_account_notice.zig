//! The Harness account's lost-session strip (#300), separate from provider
//! reauthentication. Its marker belongs to the local engine's data directory.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const account = @import("app_account.zig");
const theme = @import("theme.zig");

/// Above the sidebar's account menu, as in the original desktop. Also used
/// in Accounts so an already-open Settings page explains the local fallback.
pub fn strip(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!account.showLostSession(a)) return;
    ui.key(c, "signed-out-strip");
    const row = ui.div(c).row().wFull().px(8).py(6).gap(6).itemsStart().rounded(6).bg(k.accent.alpha(0.09));
    defer row.end();
    {
        const sign_in = ui.div(c).column().grow().minW(0).hover(k.accent.alpha(0.08)).control();
        defer sign_in.end();
        ui.text(c, account.lost_session_copy, .{ .size = 11, .wrap = true, .color = k.accent });
        if (sign_in.clicked()) account.enableSync(a);
    }
    {
        ui.key(c, "signed-out-dismiss");
        const dismiss = ui.div(c).row().size(18, 20).center().rounded(4).hover(k.hover).control();
        defer dismiss.end();
        ui.text(c, "×", .{ .size = 13, .color = k.muted });
        if (dismiss.clicked()) account.dismissLostSession(a);
    }
}
