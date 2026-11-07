//! Every test: `zig build test`.
test {
    _ = @import("ws.zig");
    _ = @import("rpc.zig");
    _ = @import("workspace.zig");
    _ = @import("transcript.zig");
    _ = @import("engine.zig");
    _ = @import("app.zig");
    _ = @import("rules.zig");
    _ = @import("tools.zig");
    _ = @import("diff.zig");
    _ = @import("wizard.zig");
    _ = @import("termlog.zig");
    _ = @import("parity.zig");
    _ = @import("app_files.zig");
    _ = @import("queue.zig");
    _ = @import("app_queue.zig");
    _ = @import("tabs.zig");
    _ = @import("icons.zig");
    _ = @import("release.zig");
    _ = @import("view.zig");
    _ = @import("markdown.zig");
    _ = @import("markdown_html.zig");
    _ = @import("highlight.zig");
}

test {
    _ = @import("edit_history.zig");
}
