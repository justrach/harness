const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // HTTPS with ALPN h2 for what the app asks the network itself (releases,
    // the edge); the engine's own socket is a local WebSocket (src/ws.zig).
    const http_zig = b.dependency("http_zig", .{ .target = target, .optimize = optimize }).module("http_zig");
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "http_zig", .module = http_zig },
    };

    const exe = b.addExecutable(.{ .name = "harness-nano", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run harness-nano").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    // The vectors the Rust side runs too (protocol/desktop, at the repo root).
    const protocol = b.root.joinString(b.allocator, "../../protocol/desktop") catch @panic("OOM");
    const opts = b.addOptions();
    opts.addOption([]const u8, "protocol_dir", protocol);
    tests.root_module.addOptions("parity_options", opts);
    b.step("test", "Run harness-nano tests").dependOn(&b.addRunArtifact(tests).step);

    // An explicit offline fixture build, not shipped with the production app.
    const fixture = b.addExecutable(.{ .name = "harness-chart-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("src/chart_fixture.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.step("chart-fixture", "Build offline native chart visual fixture").dependOn(&b.addInstallArtifact(fixture, .{}).step);

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
}
