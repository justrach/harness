const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // HTTPS with ALPN h2 for what the app asks the network itself (releases,
    // the edge); the engine's own socket is a local WebSocket (src/ws.zig).
    const http_zig = b.dependency("http_zig", .{ .target = target, .optimize = optimize }).module("http_zig");
    // Harness's bundled fonts (assets/fonts), in a module that embeds them:
    // Geist isn't installed on most Macs.
    const font_files = b.addWriteFiles();
    _ = font_files.addCopyDirectory(b.path("assets/fonts"), "fonts", .{ .include_extensions = &.{".ttf"} });
    const fonts_root = font_files.add("fonts.zig",
        \\//! Geist and Geist Mono, as the GPUI app bundles them.
        \\pub const all = [_][]const u8{
        \\    @embedFile("fonts/Geist.ttf"),
        \\    @embedFile("fonts/Geist-Italic.ttf"),
        \\    @embedFile("fonts/Geist-Medium.ttf"),
        \\    @embedFile("fonts/Geist-MediumItalic.ttf"),
        \\    @embedFile("fonts/Geist-SemiBold.ttf"),
        \\    @embedFile("fonts/Geist-SemiBoldItalic.ttf"),
        \\    @embedFile("fonts/Geist-Bold.ttf"),
        \\    @embedFile("fonts/Geist-BoldItalic.ttf"),
        \\    @embedFile("fonts/GeistMono.ttf"),
        \\    @embedFile("fonts/GeistMono-Italic.ttf"),
        \\    @embedFile("fonts/GeistMono-Medium.ttf"),
        \\    @embedFile("fonts/GeistMono-MediumItalic.ttf"),
        \\    @embedFile("fonts/GeistMono-SemiBold.ttf"),
        \\    @embedFile("fonts/GeistMono-SemiBoldItalic.ttf"),
        \\    @embedFile("fonts/GeistMono-Bold.ttf"),
        \\    @embedFile("fonts/GeistMono-BoldItalic.ttf"),
        \\};
        \\
    );
    const fonts = b.createModule(.{ .root_source_file = fonts_root });
    // Harness's SVGs, rasterized at the screen's density,
    // not a second, pre-rendered copy of the icon set.
    const icon_files = b.addWriteFiles();
    _ = icon_files.addCopyDirectory(b.path("assets/icons"), "icons", .{ .include_extensions = &.{".svg"} });
    const icons_root = icon_files.add("icons_svg.zig",
        \\pub fn get(comptime name: []const u8) []const u8 {
        \\    return @embedFile("icons/" ++ name ++ ".svg");
        \\}
        \\
    );
    const icons_svg = b.createModule(.{ .root_source_file = icons_root });
    const file_icons_data = @import("file_icons_build.zig").module(b);
    // The desktop catalog: GPUI deliberately recolors its Codegraff themes
    // without changing the mobile palette. crates/theme checks this export.
    const theme_files = b.addWriteFiles();
    _ = theme_files.addCopyFile(b.path("themes.json"), "themes.json");
    const themes_root = theme_files.add("themes_json.zig",
        \\//! The built-in theme catalog, as JSON.
        \\pub const json = @embedFile("themes.json");
        \\
    );
    const themes_json = b.createModule(.{ .root_source_file = themes_root });
    // Harness's version, as the GPUI app has it: the workspace's.
    const info = b.addOptions();
    info.addOption([]const u8, "version", workspaceVersion(b));
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "build_info", .module = info.createModule() },
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "http_zig", .module = http_zig },
        .{ .name = "fonts", .module = fonts },
        .{ .name = "icons_svg", .module = icons_svg },
        .{ .name = "file_icons_data", .module = file_icons_data },
        .{ .name = "themes_json", .module = themes_json },
    };

    // Every release mode ships stripped; ReleaseSafe is the shipped one.
    const lean_release = optimize != .debug;
    const no_unwind = lean_release and target.result.os.tag != .windows;
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = lean_release,
        .link_libc = true,
        .unwind_tables = if (lean_release) .none else null,
        .omit_frame_pointer = if (lean_release) true else null,
        .error_tracing = if (lean_release) false else null,
        .imports = imports,
    });
    const exe = b.addExecutable(.{ .name = "harness-nano", .root_module = b.createModule(.{
        .root_source_file = b.path("src/entry.zig"),
        .target = target,
        .optimize = if (optimize == .safe) .small else optimize,
        .strip = lean_release,
        .link_libc = true,
        .unwind_tables = if (no_unwind) .none else null,
        .omit_frame_pointer = if (lean_release) true else null,
        .imports = &.{.{ .name = "nano", .module = app_mod }},
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run harness-nano").dependOn(&run.step);

    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this text");
    const tests = b.addTest(.{ .filters = if (test_filter) |filter| &.{filter} else &.{}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    // The vectors the Rust side runs too (protocol/desktop, at the repo root).
    const protocol = b.root.joinString(b.allocator, "../../protocol/desktop") catch @panic("OOM");
    const opts = b.addOptions();
    opts.addOption([]const u8, "protocol_dir", protocol);
    // And the app rules the phones share (apps/parity/vectors).
    opts.addOption([]const u8, "vectors_dir", b.root.joinString(b.allocator, "../parity/vectors") catch @panic("OOM"));
    tests.root_module.addOptions("parity_options", opts);
    b.step("test", "Run harness-nano tests").dependOn(&b.addRunArtifact(tests).step);

    // `zig build snap -- scene.json out-dir`: the window drawn offscreen
    // from a made-up scene, a PNG per step asked for (src/snap.zig).
    const snap = b.addExecutable(.{ .name = "harness-nano-snap", .root_module = b.createModule(.{
        .root_source_file = b.path("src/snap.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.installArtifact(snap);
    const run_snap = b.addRunArtifact(snap);
    run_snap.addPassthruArgs();
    b.step("snap", "Draw a scene offscreen to PNGs").dependOn(&run_snap.step);

    // `zig build profile -- replay.json out-dir`: the GPUI app's UI-only
    // resource replay, for bench/resource.py to measure (src/profile.zig).
    const profile = b.addExecutable(.{ .name = "harness-nano-profile", .root_module = b.createModule(.{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.installArtifact(profile);

    // `zig build vectors`: rewrite protocol/desktop/requests.json from the
    // request builders, after changing one on purpose.
    const vectors = b.addExecutable(.{ .name = "parity-vectors", .root_module = b.createModule(.{
        .root_source_file = b.path("src/vectors_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    const write_vectors = b.addRunArtifact(vectors);
    write_vectors.addArg(b.pathJoin(&.{ protocol, "requests.json" }));
    b.step("vectors", "Write protocol/desktop/requests.json").dependOn(&write_vectors.step);
    // Large UI artifacts must never use Zig's self-hosted backend.
    inline for (.{ exe, tests, snap, profile, vectors }) |artifact| artifact.use_llvm = true;
}

/// `version` under `[workspace.package]` in the repository's Cargo.toml.
fn workspaceVersion(b: *std.Build) []const u8 {
    const path = b.root.joinString(b.allocator, "../../Cargo.toml") catch return "0.0.0";
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 20)) catch return "0.0.0";
    const section = std.mem.indexOf(u8, text, "[workspace.package]") orelse return "0.0.0";
    var lines = std.mem.splitScalar(u8, text[section..], '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, t, "version")) continue;
        const q = std.mem.indexOfScalar(u8, t, '"') orelse continue;
        const end = std.mem.indexOfScalarPos(u8, t, q + 1, '"') orelse continue;
        return t[q + 1 .. end];
    }
    return "0.0.0";
}
