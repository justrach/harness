//! The release app's root module. It only forwards to nano (src/main.zig,
//! the `nano` module), so nano keeps its own build mode (ReleaseSafe) while
//! std, built with the root, can be built for size. See build.zig.

const std = @import("std");

pub const std_options: std.Options = .{ .log_level = .warn, .enable_segfault_handler = true };

pub fn main(init: std.process.Init) !void {
    return @import("nano").main(init);
}
