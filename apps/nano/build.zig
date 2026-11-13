const std = @import("std");

pub fn build(b: *std.Build) void {
    // Match Windows' installed Rust/SDK toolchain by default. An explicit
    // GNU target still selects the matching Rust target below, never MSVC.
    const target = b.standardTargetOptions(.{ .default_target = if (b.graph.host.result.os.tag == .windows) .{ .abi = .msvc } else .{} });
    const optimize = b.standardOptimizeOption(.{});
    const loader = b.option([]const u8, "webview2-loader", "Path to the target's WebView2Loader.dll");
    const portable = b.option(bool, "portable", "Use portable text and CPU rendering for cross-platform regression tests") orelse false;
    const nanoui_dep = if (target.result.os.tag == .windows)
        b.dependency("nanoui", .{ .target = target, .optimize = optimize, .portable = portable, .webview2 = if (loader != null) "none" else "sdk" })
    else
        b.dependency("nanoui", .{ .target = target, .optimize = optimize, .portable = portable });
    const nanoui = nanoui_dep.module("nanoui");
    if (target.result.os.tag == .windows) {
        if (loader) |path| b.getInstallStep().dependOn(&b.addInstallBinFile(.{ .cwd_relative = path }, "WebView2Loader.dll").step);
    }
    // HTTPS with ALPN h2 for what the app asks the network itself (releases,
    // the edge); the engine's own socket is a local WebSocket (src/ws.zig).
    const http_zig = b.dependency("http_zig", .{ .target = target, .optimize = optimize }).module("http_zig");
    // Retain the original native TeX AST/box engine and its embedded STIX
    // glyph outlines. Cargo is a child of this build (the enclosing
    // scripts/heavy-build.sh lock covers both compilers; never nest locks).
    const rust_target = rustTarget(target.result);
    const math = b.addSystemCommand(&.{ "cargo", "build", "--quiet", "--locked", "--release", "-j2", "--manifest-path" });
    math.addFileArg(b.path("native_math/Cargo.toml"));
    math.addArgs(&.{ "--target", rust_target });
    math.addFileInput(b.path("native_math/Cargo.lock"));
    math.addFileInput(b.path("native_math/src/lib.rs"));
    const math_target = math.addPrefixedOutputDirectoryArg("--target-dir=", "native-math");
    const math_library = math_target.path(b, b.fmt("{s}/release/{s}", .{ rust_target, if (target.result.os.tag == .windows and target.result.abi == .msvc) "harness_native_math.lib" else "libharness_native_math.a" }));
    var linked_math = math_library;
    var math_index: ?*std.Build.Step.Run = null;
    if (target.result.os.tag == .windows) {
        const archive_tool = b.addExecutable(.{ .name = "math-archive", .root_module = b.createModule(.{
            .root_source_file = b.path("math_archive.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }) });
        const normalize = b.addRunArtifact(archive_tool);
        normalize.addFileArg(math_library);
        linked_math = normalize.addOutputFileArg("native-math.lib");
        const index = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "s" });
        index.addFileArg(linked_math);
        math_index = index;
    }
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
    // Harness's version, read directly from `../../Cargo.toml` via WriteFiles
    // so Zig's build runner hashes `Cargo.toml` on every build and never
    // reuses a stale cached version string across releases.
    const info_files = b.addWriteFiles();
    _ = info_files.addCopyFile(b.path("../../Cargo.toml"), "Cargo.toml");
    const info_root = info_files.add("build_info.zig",
        \\const std = @import("std");
        \\pub const version: []const u8 = blk: {
        \\    @setEvalBranchQuota(100_000);
        \\    const text = @embedFile("Cargo.toml");
        \\    const section = std.mem.indexOf(u8, text, "[workspace.package]") orelse break :blk "0.0.0";
        \\    var lines = std.mem.splitScalar(u8, text[section..], '\n');
        \\    while (lines.next()) |line| {
        \\        const t = std.mem.trim(u8, line, " \r");
        \\        if (!std.mem.startsWith(u8, t, "version")) continue;
        \\        const q = std.mem.indexOfScalar(u8, t, '"') orelse continue;
        \\        const end = std.mem.indexOfScalarPos(u8, t, q + 1, '"') orelse continue;
        \\        break :blk t[q + 1 .. end];
        \\    }
        \\    break :blk "0.0.0";
        \\};
        \\
    );
    const info_mod = b.createModule(.{ .root_source_file = info_root });
    const luau = b.dependency("luau", .{});
    const luau_h_files = b.addWriteFiles();
    const luau_shim = luau_h_files.add("luau_shim.h",
        \\#define LUA_USE_LONGJMP 1
        \\#define LUAI_MAXCSTACK 1000000
        \\#define LUA_VECTOR_SIZE 3
        \\#include "lua.h"
        \\#include "lualib.h"
        \\#include "luacode.h"
        \\
    );
    const luau_tc = b.addTranslateC(.{
        .root_source_file = luau_shim,
        .target = target,
        .optimize = optimize,
    });
    luau_tc.addIncludePath(luau.path("VM/include"));
    luau_tc.addIncludePath(luau.path("Compiler/include"));
    const luau_c = luau_tc.createModule();
    buildLuau(b, luau, target, optimize, luau_c);

    // Exercise the sandbox (including its deadline) without compiling the UI
    // or Rust math. The ordinary application tests still import these tests.
    const visual_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/visual_luau.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "luau_c", .module = luau_c }},
    }) });
    visual_tests.use_llvm = true;
    if (target.result.os.tag == .windows and target.result.abi == .msvc) visual_tests.linkage = .static;
    b.step("test-visual", "Run the isolated native visual sandbox tests").dependOn(&b.addRunArtifact(visual_tests).step);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "luau_c", .module = luau_c },
        .{ .name = "build_info", .module = info_mod },
        .{ .name = "nanoui", .module = nanoui },
        .{ .name = "http_zig", .module = http_zig },
        .{ .name = "fonts", .module = fonts },
        .{ .name = "icons_svg", .module = icons_svg },
        .{ .name = "file_icons_data", .module = file_icons_data },
        .{ .name = "themes_json", .module = themes_json },
    };

    const exe = b.addExecutable(.{ .name = "harness-nano", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = imports,
    }) });
    if (target.result.os.tag == .windows) {
        exe.subsystem = .windows;
        // Rust's native-math archive brings the MSVC CRT. Keep its normal
        // main startup while suppressing the console window; the GUI CRT
        // default would instead require a WinMain entry point.
        if (target.result.abi == .msvc) exe.entry = .{ .symbol_name = "mainCRTStartup" };
    }
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run harness-nano").dependOn(&run.step);

    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this text");
    const tests = b.addTest(.{ .filters = if (test_filter) |filter| &.{filter} else &.{}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .imports = imports,
    }) });
    // The vectors the Rust side runs too (protocol/desktop, at the repo root).
    const test_data = b.option([]const u8, "test-data-root", "Repository fixture root on a separate test runner");
    const protocol = if (test_data) |root| b.pathJoin(&.{ root, "protocol/desktop" }) else b.root.joinString(b.allocator, "../../protocol/desktop") catch @panic("OOM");
    const opts = b.addOptions();
    opts.addOption([]const u8, "protocol_dir", protocol);
    // And the app rules the phones share (apps/parity/vectors).
    opts.addOption([]const u8, "vectors_dir", if (test_data) |root| b.pathJoin(&.{ root, "apps/parity/vectors" }) else b.root.joinString(b.allocator, "../parity/vectors") catch @panic("OOM"));
    tests.root_module.addOptions("parity_options", opts);
    const test_step = b.step("test", "Run harness-nano tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // Pure AST/box geometry, safety and native-ABI regressions from the
    // original implementation remain part of the regular nano test gate.
    const math_tests = b.addSystemCommand(&.{ "cargo", "test", "--quiet", "--locked", "-j2", "--manifest-path" });
    math_tests.addFileArg(b.path("native_math/Cargo.toml"));
    math_tests.addArgs(&.{ "--target", rust_target });
    math_tests.addArg("--target-dir");
    math_tests.addDirectoryArg(math_target);
    test_step.dependOn(&math_tests.step);
    b.step("test-build", "Build tests for a separate Windows or native runner").dependOn(&b.addInstallArtifact(tests, .{}).step);

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
    inline for (.{ exe, tests, snap, profile, vectors }) |artifact| {
        artifact.use_llvm = true;
        // Luau /MT, libcpmt and Rust +crt-static must all use one static
        // CRT. Make that explicit rather than relying on Zig's defaults;
        // mixing CRTs breaks allocation/exception ownership.
        if (target.result.os.tag == .windows and target.result.abi == .msvc) artifact.linkage = .static;
        artifact.root_module.addObjectFile(linked_math);
        if (math_index) |index| artifact.step.dependOn(&index.step);
        // Rust's catch_unwind boundary needs the platform unwinder. Zig
        // supplies libunwind on Linux; libc alone does not export _Unwind_*.
        if (target.result.os.tag == .linux) artifact.root_module.linkSystemLibrary("unwind", .{});
        if (target.result.os.tag == .windows) {
            // Rust's native-static-libs, in addition to the matching CRT.
            for ([_][]const u8{ "kernel32", "ntdll", "userenv", "ws2_32", "dbghelp" }) |library| artifact.root_module.linkSystemLibrary(library, .{});
        }
    }
}

fn rustTarget(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .macos => if (target.cpu.arch == .aarch64) "aarch64-apple-darwin" else "x86_64-apple-darwin",
        .linux => if (target.cpu.arch == .aarch64) "aarch64-unknown-linux-gnu" else "x86_64-unknown-linux-gnu",
        .windows => if (target.abi == .msvc)
            (if (target.cpu.arch == .aarch64) "aarch64-pc-windows-msvc" else "x86_64-pc-windows-msvc")
        else
            (if (target.cpu.arch == .aarch64) "aarch64-pc-windows-gnullvm" else "x86_64-pc-windows-gnu"),
        else => @panic("native math needs a supported desktop Rust target"),
    };
}

fn buildLuau(
    b: *std.Build,
    luau: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    consumer: *std.Build.Module,
) void {
    const flags: []const []const u8 = if (optimize == .debug) &.{
        "-std=c++17",
        "-fexceptions",
        "-DLUA_USE_LONGJMP=1",
        "-DLUAI_MAXCSTACK=1000000",
        "-DLUA_VECTOR_SIZE=3",
        "-DLUA_API=extern \"C\"",
        "-DLUACODE_API=extern \"C\"",
    } else &.{
        "-std=c++17",
        "-fexceptions",
        "-fno-math-errno",
        "-DLUA_USE_LONGJMP=1",
        "-DLUAI_MAXCSTACK=1000000",
        "-DLUA_VECTOR_SIZE=3",
        "-DLUA_API=extern \"C\"",
        "-DLUACODE_API=extern \"C\"",
    };
    const common_files = [_][]const u8{
        "Common/src/BytecodeWire.cpp",
        "Common/src/StringUtils.cpp",
        "Common/src/TimeTrace.cpp",
    };
    const ast_files = [_][]const u8{
        "Ast/src/Allocator.cpp",
        "Ast/src/Ast.cpp",
        "Ast/src/Confusables.cpp",
        "Ast/src/Cst.cpp",
        "Ast/src/Lexer.cpp",
        "Ast/src/Location.cpp",
        "Ast/src/Parser.cpp",
        "Ast/src/PrettyPrinter.cpp",
    };
    const bytecode_files = [_][]const u8{
        "Bytecode/src/BytecodeBuilder.cpp",
        "Bytecode/src/BytecodeDump.cpp",
        "Bytecode/src/BytecodeGraph.cpp",
        "Bytecode/src/Sccp.cpp",
    };
    const compiler_files = [_][]const u8{
        "Compiler/src/BuiltinFolding.cpp",
        "Compiler/src/Builtins.cpp",
        "Compiler/src/Compiler.cpp",
        "Compiler/src/ConstantFolding.cpp",
        "Compiler/src/CostModel.cpp",
        "Compiler/src/TableShape.cpp",
        "Compiler/src/Types.cpp",
        "Compiler/src/ValueTracking.cpp",
        "Compiler/src/lcode.cpp",
    };
    const vm_files = [_][]const u8{
        "VM/src/lapi.cpp",
        "VM/src/laux.cpp",
        "VM/src/lbaselib.cpp",
        "VM/src/lbitlib.cpp",
        "VM/src/lbuffer.cpp",
        "VM/src/lbuflib.cpp",
        "VM/src/lbuiltins.cpp",
        "VM/src/lclass.cpp",
        "VM/src/lclasslib.cpp",
        "VM/src/lcorolib.cpp",
        "VM/src/ldblib.cpp",
        "VM/src/ldebug.cpp",
        "VM/src/ldo.cpp",
        "VM/src/lfunc.cpp",
        "VM/src/lgc.cpp",
        "VM/src/lgcdebug.cpp",
        "VM/src/linit.cpp",
        "VM/src/lintlib.cpp",
        "VM/src/lmathlib.cpp",
        "VM/src/lmem.cpp",
        "VM/src/lnumprint.cpp",
        "VM/src/lobject.cpp",
        "VM/src/loslib.cpp",
        "VM/src/lperf.cpp",
        "VM/src/lstate.cpp",
        "VM/src/lstring.cpp",
        "VM/src/lstrlib.cpp",
        "VM/src/ltable.cpp",
        "VM/src/ltablib.cpp",
        "VM/src/ltm.cpp",
        "VM/src/ludata.cpp",
        "VM/src/lutf8lib.cpp",
        "VM/src/lveclib.cpp",
        "VM/src/lvector.cpp",
        "VM/src/lvmexecute.cpp",
        "VM/src/lvmload.cpp",
        "VM/src/lvmutils.cpp",
    };
    const sources = common_files ++ ast_files ++ bytecode_files ++ compiler_files ++ vm_files;
    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        // Zig's bundled libc++/libc++abi cannot be mixed with MSVC vcruntime
        // headers or Rust's MSVC native-math archive. Compile Luau with the
        // installed MSVC toolset and /MT, then link its matching static C++
        // runtime. The helper bootstraps VS itself in both UI and package jobs;
        // neither requires a developer prompt or a workflow-specific setup.
        const compile = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
        compile.addFileArg(b.path("src/luau_windows.ps1"));
        compile.addArg("-OutputLibrary");
        const archive = compile.addOutputFileArg("luau.lib");
        compile.addArg("-LuauRoot");
        compile.addDirectoryArg(luau.path("."));
        compile.addArgs(&.{ "-Architecture", switch (target.result.cpu.arch) {
            .x86_64 => "x64",
            .aarch64 => "arm64",
            else => @panic("MSVC Luau needs a supported desktop architecture"),
        }, "-Optimize", @tagName(optimize) });
        // Track each translation unit as a build input as well as the root
        // directory (which includes the pinned Luau headers).
        for (sources) |source| compile.addFileArg(luau.path(source));
        consumer.addObjectFile(archive);
        consumer.link_libc = true;
        consumer.linkSystemLibrary("libcpmt", .{ .preferred_link_mode = .static });
        return;
    }

    const lib = b.addLibrary(.{
        .name = "luau",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        }),
    });
    lib.root_module.addIncludePath(luau.path("Common/include"));
    lib.root_module.addIncludePath(luau.path("Ast/include"));
    lib.root_module.addIncludePath(luau.path("Bytecode/include"));
    lib.root_module.addIncludePath(luau.path("Compiler/include"));
    lib.root_module.addIncludePath(luau.path("VM/include"));
    lib.root_module.addCSourceFiles(.{
        .root = luau.path("."),
        .files = &sources,
        .flags = flags,
    });
    consumer.linkLibrary(lib);
}
