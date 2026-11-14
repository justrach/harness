//! Desktop update surfaces for Harness and the managed Codegraff engine
//! (`crates/ui/src/shell/app_update.rs` and `crates/ui/src/shell.rs`
//! `render_graff_notice`):
//! - `#sidebar-graff-update-row` and `#sidebar-update-row` in the sidebar
//!   footer above the account avatar (bottom-left).
//! - `#titlebar-update` in the titlebar's left cluster when the sidebar is
//!   collapsed or in Settings.
//! - `#app-updated` and `#graff-notice` floating cards at the bottom-right.
//! - `olderEngineNotice` (`crates/ui/src/state.rs`) when attaching to an
//!   older background engine daemon.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tip = @import("view_tooltip.zig");
const graff_update = @import("graff_update.zig");
const App = @import("app.zig").App;

pub const max_highlights = 4;

pub const GraffKind = enum {
    none,
    updating,
    updated,
    available,
};

pub const RestartPlace = enum {
    none,
    sidebar_row,
    titlebar,
};

pub const State = struct {
    lock: std.atomic.Value(bool) = .init(false),
    dirty: bool = false,
    graff_kind: GraffKind = .none,
    graff_from: [32]u8 = undefined,
    graff_from_len: usize = 0,
    graff_to: [32]u8 = undefined,
    graff_to_len: usize = 0,
    graff_highlights: [max_highlights][160]u8 = undefined,
    graff_highlight_lens: [max_highlights]usize = @splat(0),
    graff_highlights_total: usize = 0,
    graff_card_open: bool = true,
    graff_updating_manual: bool = false,

    restart_dismissed: [32]u8 = undefined,
    restart_dismissed_len: usize = 0,
    titlebar_dismissed: [32]u8 = undefined,
    titlebar_dismissed_len: usize = 0,
    /// True in the desktop app and unit tests; false only in legacy GPUI
    /// parity scenes recorded against an unmanaged binary.
    desktop_update: bool = true,
    /// Only a production macOS bundle with its own sibling CLI may install.
    app_install_checked: bool = false,
    app_can_install: bool = false,
    /// The CLI has already replaced the bundle on disk; reopening uses it.
    app_ready: bool = false,
    app_downloading: bool = false,
    app_checking: bool = false,
    app_checked_ms: i64 = 0,
    app_failed: [160]u8 = undefined,
    app_failed_len: usize = 0,
    app_updated: [32]u8 = undefined,
    app_updated_len: usize = 0,
    app_updated_until: f64 = 0,

    pub fn appFailed(s: *const State) ?[]const u8 {
        return if (s.app_failed_len == 0) null else s.app_failed[0..s.app_failed_len];
    }

    pub fn setAppFailed(s: *State, msg: []const u8) void {
        const trimmed = std.mem.trim(u8, msg, " \t\r\n");
        const n = @min(trimmed.len, s.app_failed.len);
        @memcpy(s.app_failed[0..n], trimmed[0..n]);
        s.app_failed_len = n;
    }

    pub fn graffFrom(s: *const State) ?[]const u8 {
        return if (s.graff_from_len == 0) null else s.graff_from[0..s.graff_from_len];
    }

    pub fn graffTo(s: *const State) ?[]const u8 {
        return if (s.graff_to_len == 0) null else s.graff_to[0..s.graff_to_len];
    }

    pub fn restartDismissed(s: *const State) ?[]const u8 {
        return if (s.restart_dismissed_len == 0) null else s.restart_dismissed[0..s.restart_dismissed_len];
    }

    pub fn titlebarDismissed(s: *const State) ?[]const u8 {
        return if (s.titlebar_dismissed_len == 0) null else s.titlebar_dismissed[0..s.titlebar_dismissed_len];
    }

    fn acquire(s: *State) void {
        while (s.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(s: *State) void {
        s.lock.store(false, .release);
    }

    pub fn publishGraff(
        s: *State,
        kind: GraffKind,
        from: ?[]const u8,
        to: []const u8,
        version_output: ?[]const u8,
    ) void {
        s.acquire();
        defer s.release();
        s.graff_kind = kind;
        if (from) |f| {
            const n = @min(f.len, s.graff_from.len);
            @memcpy(s.graff_from[0..n], f[0..n]);
            s.graff_from_len = n;
        } else {
            s.graff_from_len = 0;
        }
        const tn = @min(to.len, s.graff_to.len);
        @memcpy(s.graff_to[0..tn], to[0..tn]);
        s.graff_to_len = tn;
        s.graff_highlight_lens = @splat(0);
        s.graff_highlights_total = if (version_output) |out|
            whatsNew(&s.graff_highlights, &s.graff_highlight_lens, out, from, to)
        else
            0;
        s.graff_card_open = true;
        s.graff_updating_manual = false;
        s.dirty = true;
    }
};

pub const EngineVersionAction = enum {
    up_to_date,
    replace_old_session,
    notify_only,
};

/// True when the connected engine is older than `app_ver`.
pub fn isOlderEngine(app_ver: []const u8, engine_ver: ?[]const u8) bool {
    const app_parts = parseStrictDotted(app_ver) orelse return false;
    if (engine_ver) |ev| {
        const eng_parts = parseStrictDotted(ev) orelse return false;
        return compareParts(eng_parts, app_parts) == .lt;
    }
    return true;
}

/// Pure decision rule proved in `Nano/FrameSchedule.lean`
/// (`decideEngineVersionAction`): when a live desktop session connects to an
/// older background `harness headless` process after an update, kill and
/// replace the old engine session once instead of showing a warning banner.
pub fn decideEngineVersionAction(
    app_ver: []const u8,
    engine_ver: ?[]const u8,
    live_session: bool,
    already_replaced: bool,
) EngineVersionAction {
    if (!isOlderEngine(app_ver, engine_ver)) return .up_to_date;
    if (live_session and !already_replaced) return .replace_old_session;
    return .notify_only;
}

/// Pure version comparison (`older_engine_notice` in `crates/ui/src/state.rs`).
pub fn olderEngineNotice(buf: []u8, app_ver: []const u8, engine_ver: ?[]const u8) ?[]const u8 {
    if (!isOlderEngine(app_ver, engine_ver)) return null;
    if (engine_ver) |ev| {
        return std.fmt.bufPrint(
            buf,
            "Harness {s} is connected to an engine that is still running {s}, so some changes won't apply yet. To update it, run `harness daemon stop`, then quit and reopen Harness. Chats that are running will stop.",
            .{ app_ver, ev },
        ) catch null;
    }
    return std.fmt.bufPrint(
        buf,
        "Harness {s} is connected to an engine that is still running an older version, so some changes won't apply yet. To update it, run `harness daemon stop`, then quit and reopen Harness. Chats that are running will stop.",
        .{app_ver},
    ) catch null;
}

const Parts = struct {
    nums: [6]u64 = @splat(0),
    len: usize = 0,
};

fn parseStrictDotted(raw: []const u8) ?Parts {
    const clean = std.mem.trim(u8, raw, " \t\r\n");
    const bare = std.mem.trimStart(u8, clean, "v");
    if (bare.len == 0) return null;
    var out: Parts = .{};
    var it = std.mem.splitScalar(u8, bare, '.');
    while (it.next()) |part| {
        if (part.len == 0 or out.len >= out.nums.len) return null;
        out.nums[out.len] = std.fmt.parseInt(u64, part, 10) catch return null;
        out.len += 1;
    }
    return if (out.len >= 3) out else null;
}

fn compareParts(a: Parts, b: Parts) std.math.Order {
    const n = @max(a.len, b.len);
    for (0..n) |i| {
        const x = if (i < a.len) a.nums[i] else 0;
        const y = if (i < b.len) b.nums[i] else 0;
        if (x != y) return std.math.order(x, y);
    }
    return .eq;
}

/// Extract "What's new" bullet lines from `graff --version` for releases in
/// `(from, to]` (or `== to` when `from` is null), matching
/// `crates/harness/src/graff_bundle.rs:whats_new`.
pub fn whatsNew(
    out_lines: *[max_highlights][160]u8,
    out_lens: *[max_highlights]usize,
    version_output: []const u8,
    from: ?[]const u8,
    to: []const u8,
) usize {
    const to_parts = parseStrictDotted(to) orelse return 0;
    const from_parts = if (from) |f| parseStrictDotted(f) else null;
    var total: usize = 0;
    var in_range = false;
    var lines = std.mem.splitScalar(u8, version_output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "•")) {
            const item = std.mem.trim(u8, trimmed["•".len..], " \t");
            if (in_range and item.len > 0) {
                if (total < max_highlights) {
                    const n = @min(item.len, out_lines[total].len);
                    @memcpy(out_lines[total][0..n], item[0..n]);
                    out_lens[total] = n;
                }
                total += 1;
            }
        } else if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and std.mem.indexOfAny(u8, std.mem.trim(u8, line, " \t"), " \t") == null) {
            if (parseStrictDotted(line)) |ver| {
                const le_to = compareParts(ver, to_parts) != .gt;
                const gt_from = if (from_parts) |fp| compareParts(ver, fp) == .gt else compareParts(ver, to_parts) == .eq;
                in_range = le_to and gt_from;
            }
        }
    }
    return total;
}

/// Pure placement rule (`restart_place` in `crates/ui/src/shell/app_update.rs`).
pub fn restartPlace(
    update_ver: ?[]const u8,
    sidebar_fits: bool,
    dismissed: ?[]const u8,
) RestartPlace {
    const ver = update_ver orelse return .none;
    if (dismissed) |d| if (std.mem.eql(u8, d, ver)) return .none;
    return if (sidebar_fits) .sidebar_row else .titlebar;
}

pub fn appUpdateVersion(a: *const App) ?[]const u8 {
    if (a.env) |env| {
        if (env.get("HARNESS_DEV_APP_UPDATE")) |v| if (std.mem.eql(u8, v, "1")) return "preview";
    }
    const latest = a.release.version() orelse return null;
    const current = @import("build_info").version;
    return if (graff_update.newer(latest, current)) latest else null;
}

/// Installed app update version ready to reopen into (`app_restart_version` in
/// `crates/ui/src/shell/app_update.rs`). Unstaged GitHub releases use the
/// titlebar indicator instead of crowding the sidebar footer.
pub fn appRestartVersion(a: *const App) ?[]const u8 {
    if (a.env) |env| {
        if (env.get("HARNESS_DEV_APP_UPDATE")) |v| if (std.mem.eql(u8, v, "1")) return "preview";
    }
    if (!a.updates.app_ready) return null;
    return appUpdateVersion(a);
}

pub fn sidebarFits(a: *const App) bool {
    return a.view.sidebar_open and !a.view.settings_open;
}

pub fn graffVisible(a: *const App) bool {
    const s = &a.updates;
    if (s.graff_kind == .none) return false;
    const to = s.graffTo() orelse return false;
    if (s.graff_kind == .updating) return true;
    if (a.settings.text("graffNoticeDismissed")) |d| {
        if (std.mem.eql(u8, d, to)) return false;
    }
    return true;
}

pub fn dismissGraff(a: *App) void {
    const to = a.updates.graffTo() orelse return;
    a.settings.setText("graffNoticeDismissed", to);
    a.updates.graff_card_open = false;
    a.redraw();
}

pub const UpdateAction = union(enum) {
    none,
    check,
    downloading,
    update: []const u8,
    restart: []const u8,
    retry: []const u8,
};

pub const UpdateSummary = struct {
    line: []const u8,
    action: UpdateAction,
};

/// Pure status line and button for Settings › Devices (`update_summary` in
/// `crates/ui/src/settings/devices.rs`).
pub fn updateSummary(buf: []u8, a: *const App, now_ms: i64) UpdateSummary {
    const latest = appUpdateVersion(a);
    if (!a.updates.desktop_update) {
        if (latest) |ver| {
            return .{
                .line = std.fmt.bufPrint(buf, "Update v{s} is available. Install the latest release to update.", .{ver}) catch "An update is available.",
                .action = .none,
            };
        }
        return .{
            .line = "This build doesn't update itself. Install the latest release to update.",
            .action = .none,
        };
    }
    if (a.updates.app_checking and !a.updates.app_ready and !a.updates.app_downloading) {
        return .{ .line = "Checking for updates…", .action = .none };
    }
    if (a.release.schedule.failures > 0 and !a.updates.app_ready and !a.updates.app_downloading) {
        return .{ .line = "Couldn't check for updates. Will retry automatically; check your connection.", .action = .check };
    }
    if (a.updates.app_install_checked and !a.updates.app_can_install) {
        return .{
            .line = if (latest) |ver|
                std.fmt.bufPrint(buf, "v{s} is available. Update this installation manually; checks run hourly.", .{ver}) catch "Update available; install manually."
            else
                "Checks run hourly. This installation must be updated manually.",
            .action = if (a.updates.app_checking) .none else .check,
        };
    }
    if (a.updates.app_ready) {
        const ver = latest orelse @import("build_info").version;
        return .{
            .line = std.fmt.bufPrint(buf, "Harness v{s} is installed. Restart when you're ready to use it.", .{ver}) catch "Update installed. Restart when ready.",
            .action = .{ .restart = ver },
        };
    }
    if (a.updates.app_downloading) {
        const line = if (latest) |ver|
            std.fmt.bufPrint(buf, "Downloading v{s}…", .{ver}) catch "Downloading update…"
        else
            "Downloading update…";
        return .{ .line = line, .action = .downloading };
    }
    if (a.updates.appFailed()) |err| {
        if (latest) |ver| {
            return .{
                .line = std.fmt.bufPrint(buf, "Updating to v{s} failed: {s}", .{ ver, err }) catch "Update failed.",
                .action = .{ .retry = ver },
            };
        }
    }
    if (a.updates.app_checking) {
        return .{ .line = "Checking for updates…", .action = .none };
    }
    if (latest) |ver| {
        return .{
            .line = std.fmt.bufPrint(buf, "Harness v{s} is available.", .{ver}) catch "An update is available.",
            .action = .{ .update = ver },
        };
    }
    if (a.updates.appFailed()) |err| {
        return .{
            .line = std.fmt.bufPrint(buf, "Couldn't check for updates: {s}", .{err}) catch "Couldn't check for updates.",
            .action = .check,
        };
    }
    if (a.updates.app_checked_ms > 0) {
        var seen_buf: [32]u8 = undefined;
        const seen = @import("view_settings_devices.zig").lastSeen(&seen_buf, a.updates.app_checked_ms, now_ms);
        return .{
            .line = std.fmt.bufPrint(buf, "Up to date · checked {s}", .{seen}) catch "Up to date.",
            .action = .check,
        };
    }
    return .{ .line = "No release check completed yet.", .action = .check };
}

/// Call from App.tick, not a render/scroll callback. The real-clock deadline
/// survives sleep; minute wakeups also notice clock changes. Checks never
/// download, apply or restart anything (including with HARNESS_AUTO_UPDATE=0).
/// Returns seconds until another tick is needed, or null for fixtures/tests.
pub fn tick(a: *App) ?f32 {
    if (a.offscreen or builtin.is_test) return null;
    initialize(a);
    if (a.release.startIfDue()) {
        a.updates.app_checking = a.release.schedule.in_flight;
        a.redraw();
    }
    return a.release.schedule.delaySeconds(a.nowMs());
}

pub fn checkForUpdates(a: *App) void {
    a.updates.app_failed_len = 0;
    if (!a.offscreen and !builtin.is_test) {
        initialize(a);
        a.release.start();
        a.updates.app_checking = a.release.schedule.in_flight;
    }
    a.redraw();
}

pub fn onReleaseChecked(a: *App) void {
    a.updates.app_checking = false;
    if (a.release.succeeded) {
        a.updates.app_checked_ms = a.nowMs();
        a.updates.app_failed_len = 0;
    } else {
        a.updates.setAppFailed("Release manifest unavailable. Try again when online.");
    }
    // `harness update` applies immediately; it is not a background staging API.
    // Automatic checks must never invoke it or consume restart preferences.
    a.redraw();
}

pub fn triggerAppUpdate(a: *App, ver: []const u8) void {
    if (std.mem.eql(u8, ver, "preview")) return;
    initialize(a);
    if (!a.updates.app_can_install) {
        openExternalUrl("https://github.com/justrach/harness/releases/latest");
        return;
    }
    if (a.updates.app_ready) {
        restartIntoUpdate(a);
        return;
    }
    startAppDownload(a);
}

fn startAppDownload(a: *App) void {
    a.updates.acquire();
    const already = a.updates.app_downloading;
    a.updates.app_downloading = true;
    a.updates.app_failed_len = 0;
    a.updates.release();
    a.redraw();
    if (already or a.offscreen or builtin.is_test) return;
    const t = std.Thread.spawn(.{}, appUpdateWorker, .{a}) catch {
        a.updates.acquire();
        a.updates.app_downloading = false;
        a.updates.setAppFailed("couldn't start background installer");
        a.updates.release();
        a.redraw();
        return;
    };
    t.detach();
}

/// Pure install identity. Never search /Applications, PATH or an engine
/// override: those can belong to a different install than the running app.
pub fn currentBundle(exe: []const u8, os: std.Target.Os.Tag) ?[]const u8 {
    if (os != .macos or !std.mem.startsWith(u8, exe, "/")) return null;
    const suffix = "/Contents/MacOS/harness-nano";
    if (!std.mem.endsWith(u8, exe, suffix)) return null;
    const bundle = exe[0 .. exe.len - suffix.len];
    return if (std.mem.endsWith(u8, bundle, ".app")) bundle else null;
}

pub fn updateCliFor(gpa: std.mem.Allocator, exe: []const u8, os: std.Target.Os.Tag) ?[]u8 {
    const bundle = currentBundle(exe, os) orelse return null;
    return std.fmt.allocPrint(gpa, "{s}/Contents/MacOS/harness", .{bundle}) catch null;
}

pub fn productionBundleId(id: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, id, " \t\r\n"), "harness.codegraff.app");
}

fn productionBundle(gpa: std.mem.Allocator, io: std.Io, bundle: []const u8) bool {
    if (builtin.os.tag != .macos or builtin.is_test) return false;
    const plist = std.fmt.allocPrint(gpa, "{s}/Contents/Info.plist", .{bundle}) catch return false;
    defer gpa.free(plist);
    // Read binary and XML plists alike; fail closed for dev/standalone bundles.
    const r = std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/plutil", "-extract", "CFBundleIdentifier", "raw", "-o", "-", plist },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
    }) catch return false;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |code| code == 0 and productionBundleId(r.stdout),
        else => false,
    };
}

fn findHarnessCli(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (builtin.os.tag != .macos or builtin.is_test) return null;
    const exe = std.process.executablePathAlloc(io, gpa) catch return null;
    defer gpa.free(exe);
    const bundle = currentBundle(exe, builtin.os.tag) orelse return null;
    if (!productionBundle(gpa, io, bundle)) return null;
    const cli = updateCliFor(gpa, exe, builtin.os.tag) orelse return null;
    std.Io.Dir.cwd().access(io, cli, .{}) catch {
        gpa.free(cli);
        return null;
    };
    return cli;
}

/// One install probe per session. Unsupported and source builds still check.
pub fn initialize(a: *App) void {
    if (a.updates.app_install_checked) return;
    a.updates.app_install_checked = true;
    if (a.offscreen or builtin.is_test) return;
    const cli = findHarnessCli(a.gpa, a.io) orelse return;
    a.gpa.free(cli);
    a.updates.app_can_install = true;
}

fn appUpdateWorker(a: *App) void {
    const bin = findHarnessCli(a.gpa, a.io) orelse {
        a.updates.acquire();
        a.updates.app_downloading = false;
        a.updates.setAppFailed("This installation cannot update itself. Install the latest release manually.");
        a.updates.dirty = true;
        a.updates.release();
        _ = nanoui.App.onMain(a, appUpdateDelivered);
        return;
    };
    defer a.gpa.free(bin);
    const res = std.process.run(a.gpa, a.io, .{
        .argv = &.{ bin, "update" },
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| {
        a.updates.acquire();
        a.updates.app_downloading = false;
        var ebuf: [96]u8 = undefined;
        a.updates.setAppFailed(std.fmt.bufPrint(&ebuf, "{t}", .{err}) catch "update command failed");
        a.updates.dirty = true;
        a.updates.release();
        _ = nanoui.App.onMain(a, appUpdateDelivered);
        return;
    };
    defer a.gpa.free(res.stdout);
    defer a.gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    a.updates.acquire();
    a.updates.app_downloading = false;
    switch (classifyUpdateOutput(ok, res.stdout, res.stderr)) {
        .installed => {
            a.updates.app_ready = true;
            a.updates.app_failed_len = 0;
        },
        .up_to_date => {
            a.updates.app_ready = false;
            a.updates.app_failed_len = 0;
        },
        .failed => |line| {
            a.updates.setAppFailed(line);
        },
    }
    a.updates.dirty = true;
    a.updates.release();
    _ = nanoui.App.onMain(a, appUpdateDelivered);
}

pub const UpdateCommandOutcome = union(enum) {
    installed,
    up_to_date,
    failed: []const u8,
};

/// Pure classifier for `harness update` process output (ADR 0008). Only a
/// bundle swap (`"relaunch Harness to finish"`) marks an update ready; a no-op
/// (`"is up to date"`) must never mark `app_ready` or trigger a relaunch loop.
pub fn classifyUpdateOutput(exited_zero: bool, stdout: []const u8, stderr: []const u8) UpdateCommandOutcome {
    if (exited_zero and std.mem.indexOf(u8, stdout, "relaunch Harness to finish") != null) {
        return .installed;
    }
    if (exited_zero and std.mem.indexOf(u8, stdout, "is up to date") != null) {
        return .up_to_date;
    }
    const line = firstLine(stderr) orelse firstLine(stdout) orelse "update exited with an error";
    return .{ .failed = line };
}

fn firstLine(s: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len > 0) return t;
    }
    return null;
}

fn appUpdateDelivered(ctx: ?*anyopaque) callconv(.c) void {
    const a: *App = @ptrCast(@alignCast(ctx.?));
    // Applying an update is not permission to stop agents or close a window.
    // A separate, explicit Restart click is required after installation.
    a.redraw();
}

pub fn restartIntoUpdate(a: *App) void {
    if (builtin.is_test or a.offscreen) return;
    if (builtin.os.tag == .macos) {
        const exe = std.process.executablePathAlloc(a.io, a.gpa) catch return;
        defer a.gpa.free(exe);
        const bundle = currentBundle(exe, builtin.os.tag) orelse return;
        if (!productionBundle(a.gpa, a.io, bundle)) return;
        var pid_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{std.c.getpid()}) catch return;
        // Pass the bundle as an argument, never interpolate it into a shell.
        const cmd = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \"$2\"";
        if (std.process.spawn(a.io, .{
            .argv = &.{ "/bin/sh", "-c", cmd, "harness-relaunch", pid, bundle },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        })) |child| {
            var c = child;
            _ = &c;
            @import("engine_start.zig").stopForUpdate(a);
            std.process.exit(0);
        } else |_| {
            a.updates.setAppFailed("Couldn't restart Harness. Quit and reopen it manually.");
            a.redraw();
        }
    } else {
        // No validated portable relaunch: never stop an engine or quit here.
        a.updates.setAppFailed("Quit and reopen Harness manually to use the update.");
        a.redraw();
    }
}

pub fn openExternalUrl(url: []const u8) void {
    if (builtin.is_test) return;
    _ = nanoui.shell.openUrl(url);
}

/// Height contributed to the sidebar footer by any active update pills.
pub fn sidebarFooterExtraHeight(a: *const App) f32 {
    var h: f32 = 0;
    if (graffVisible(a)) h += 34;
    if (restartPlace(appUpdateVersion(a), sidebarFits(a), a.updates.restartDismissed()) == .sidebar_row) h += 34;
    return h;
}

/// Bottom-left sidebar footer rows (`#sidebar-graff-update-row` and
/// `#sidebar-update-row`), rendered right above the account avatar row.
pub fn sidebarFooterRows(c: *ui.Context, a: *App, k: theme.Colors) void {
    a.updates.acquire();
    const was_dirty = a.updates.dirty;
    a.updates.dirty = false;
    a.updates.release();
    if (was_dirty) c.changed = true;

    const show_graff = graffVisible(a);
    const update_ver = appUpdateVersion(a);
    const show_app = restartPlace(update_ver, sidebarFits(a), a.updates.restartDismissed()) == .sidebar_row;
    if (!show_graff and !show_app) return;

    const wrap = ui.div(c).column().wFull().pt(6).pb(2);
    defer wrap.end();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    if (show_graff) {
        sidebarGraffRow(c, a, k);
    }
    if (show_app) {
        if (update_ver) |ver| sidebarAppUpdateRow(c, a, k, ver);
    }
}

fn sidebarGraffRow(c: *ui.Context, a: *App, k: theme.Colors) void {
    const to = a.updates.graffTo() orelse return;
    const kind = a.updates.graff_kind;
    const pad = ui.div(c).column().wFull().px(8).pt(4);
    defer pad.end();
    ui.key(c, "sidebar-graff-update-row");
    const row = ui.div(c).row().wFull().pl(8).pr(4).py(4).gap(8).itemsCenter().rounded(6)
        .bg(k.accent_wash).hover(k.accent.alpha(0.18)).border(k.accent.alpha(0.3)).borderW(1);
    defer row.end();
    {
        const label = switch (kind) {
            .updating => c.print("Updating Codegraff to v{s}…", .{to}),
            .updated => c.print("Codegraff v{s} · What's new", .{to}),
            .available => c.print("Update Codegraff to v{s}", .{to}),
            .none => "",
        };
        const hint = switch (kind) {
            .updating => "Codegraff is updating in the background; open chats keep their session.",
            .updated => "Codegraff engine updated. Click to view release highlights.",
            .available => "A newer Codegraff engine release is available.",
            .none => "",
        };
        ui.key(c, "sidebar-graff-update-open");
        const open_btn = tip.on(ui.div(c).row().grow().w(0).gap(6).itemsCenter(), k, .{ .text = hint, .delay = tip.quick });
        defer open_btn.end();
        icons.icon(c, .@"graff-mark", 13, k.accent, 0);
        const text_w = @import("view_sidebar.zig").widthOf(a) - 16 - 12 - 13 - 6 - 26;
        kit.ellipsisText(c, label, .{ .size = 11, .line_height = 15, .weight = .medium, .color = k.text }, @max(40, text_w));
        if (open_btn.clicked()) {
            a.updates.graff_card_open = !a.updates.graff_card_open;
            a.redraw();
        }
    }
    if (kind != .updating) {
        ui.key(c, "sidebar-graff-update-dismiss");
        const close_btn = tip.on(ui.div(c).row().size(18, 18).center().rounded(4).hover(k.ink(0.08)), k, .{
            .text = "Dismiss for this version",
            .delay = tip.quick,
        });
        defer close_btn.end();
        icons.icon(c, .close, 10, k.muted, 0);
        if (close_btn.clicked()) dismissGraff(a);
    }
}

fn sidebarAppUpdateRow(c: *ui.Context, a: *App, k: theme.Colors, ver: []const u8) void {
    const ready = a.updates.app_ready or std.mem.eql(u8, ver, "preview");
    const pad = ui.div(c).column().wFull().px(8).pt(4);
    defer pad.end();
    ui.key(c, "sidebar-update-row");
    const row = ui.div(c).row().wFull().pl(8).pr(4).py(4).gap(8).itemsCenter().rounded(6)
        .bg(k.accent_wash).hover(k.accent.alpha(0.18)).border(k.accent.alpha(0.3)).borderW(1);
    defer row.end();
    {
        const hint = if (ready)
            c.print("Harness v{s} is ready. Click to restart into it.", .{ver})
        else
            c.print("Harness v{s} is available. {s}", .{ ver, if (a.updates.app_install_checked and !a.updates.app_can_install) "Click to view the release; install manually." else "Click to update." });
        const label = if (ready)
            "Restart to update"
        else if (a.updates.app_downloading)
            c.print("Downloading v{s}…", .{ver})
        else if (a.updates.app_install_checked and !a.updates.app_can_install)
            "View release"
        else
            c.print("Update to v{s}", .{ver});
        ui.key(c, "sidebar-update-restart");
        const btn = tip.on(ui.div(c).row().grow().w(0).gap(6).itemsCenter(), k, .{ .text = hint, .delay = tip.quick });
        defer btn.end();
        icons.icon(c, .refresh, 13, k.accent, 0);
        const text_w = @import("view_sidebar.zig").widthOf(a) - 16 - 12 - 13 - 6 - 26;
        kit.ellipsisText(c, label, .{ .size = 11, .line_height = 15, .weight = .medium, .color = k.text }, @max(40, text_w));
        if (btn.clicked()) triggerAppUpdate(a, ver);
    }
    {
        ui.key(c, "sidebar-update-dismiss");
        const close_btn = tip.on(ui.div(c).row().size(18, 18).center().rounded(4).hover(k.ink(0.08)), k, .{
            .text = if (ready) "Not now: use the update when you reopen Harness" else "Dismiss for this version",
            .delay = tip.quick,
        });
        defer close_btn.end();
        icons.icon(c, .close, 10, k.muted, 0);
        if (close_btn.clicked()) {
            const n = @min(ver.len, a.updates.restart_dismissed.len);
            @memcpy(a.updates.restart_dismissed[0..n], ver[0..n]);
            a.updates.restart_dismissed_len = n;
            a.redraw();
        }
    }
}

pub fn titlebarVisible(a: *const App) bool {
    const ver = appUpdateVersion(a) orelse return false;
    if (appRestartVersion(a)) |rver| {
        if (restartPlace(rver, sidebarFits(a), a.updates.restartDismissed()) != .titlebar) return false;
    }
    if (a.updates.titlebarDismissed()) |d| if (std.mem.eql(u8, d, ver)) return false;
    return true;
}

/// The update button in the titlebar's left cluster when the sidebar is
/// collapsed (`render_update_control` in `crates/ui/src/shell/app_update.rs`).
pub fn titlebarControl(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (!titlebarVisible(a)) return;
    const ver = appUpdateVersion(a).?;
    ui.div(c).w(4).end();
    ui.key(c, "titlebar-update");
    const ready = a.updates.app_ready or std.mem.eql(u8, ver, "preview");
    const label = if (ready)
        c.print("v{s} is ready — click to restart now.", .{ver})
    else
        c.print("Harness v{s} is available. {s}", .{ ver, if (a.updates.app_install_checked and !a.updates.app_can_install) "Click to view the release; install manually." else "Click to update." });
    const b = tip.on(ui.div(c).row().size(24, 24).center().rounded(6).hover(k.hover).control(), k, .{ .text = label, .delay = tip.quick });
    defer b.end();
    icons.icon(c, .refresh, 15, k.accent, 0);
    if (ready) {
        ui.div(c).absolute().offset(24 - 3 - 6, 3).size(6, 6).roundedFull().bg(k.accent).end();
    }
    if (b.clicked()) triggerAppUpdate(a, ver);
}

/// Floating bottom-right card (`render_app_update_card` / `render_graff_notice`
/// in `crates/ui/src/shell.rs:9199, 10945`).
pub fn overlayCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.updates.app_updated_len > 0) {
        if (c.time >= a.updates.app_updated_until) {
            a.updates.app_updated_len = 0;
        } else {
            c.frameIn(@floatCast(a.updates.app_updated_until - c.time));
            return appUpdatedCard(c, a, k);
        }
    }
    if (!graffVisible(a) or !a.updates.graff_card_open) return;
    if (a.updates.graff_kind != .updated and a.updates.graff_kind != .available) return;
    graffNoticeCard(c, a, k);
}

fn appUpdatedCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const ver = a.updates.app_updated[0..a.updates.app_updated_len];
    const card_w: f32 = 340;
    const card_h: f32 = 126;
    ui.key(c, "app-updated");
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(@max(16, c.size.w - card_w - 16), @max(16, c.size.h - card_h - 16))
        .layer(5).column().w(card_w).p(14).gap(10).rounded(12).border(k.border).borderW(1).bg(k.composer.alpha(1))));
    defer card.end();
    {
        const hd = ui.div(c).row().gap(10).itemsCenter();
        defer hd.end();
        const badge = ui.div(c).row().size(30, 30).center().rounded(8).bg(k.accent_wash);
        defer badge.end();
        icons.icon(c, .check, 16, k.accent, 0);
        ui.text(c, c.print("Updated to v{s}", .{ver}), .{ .size = 13, .line_height = 18, .weight = .semibold, .color = k.text });
    }
    ui.text(c, "You're on the new version.", .{ .size = 11.5, .line_height = 16, .color = k.muted });
    {
        const btns = ui.div(c).row().wFull().justifyEnd().gap(6).itemsCenter();
        defer btns.end();
        ui.key(c, "app-updated-notes");
        const notes = ui.div(c).row().px(10).py(4).rounded(6).border(k.border).borderW(1).hover(k.hover);
        if (notes.clicked()) openExternalUrl(c.print("https://github.com/justrach/harness/releases/tag/v{s}", .{ver}));
        ui.text(c, "Release notes", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.text });
        notes.end();

        ui.key(c, "app-updated-dismiss");
        const got_it = ui.div(c).row().px(10).py(4).rounded(6).border(k.solid).borderW(1).bg(k.solid);
        if (got_it.clicked()) {
            a.updates.app_updated_len = 0;
            a.redraw();
        }
        ui.text(c, "Got it", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.on_solid });
        got_it.end();
    }
}

fn graffNoticeCard(c: *ui.Context, a: *App, k: theme.Colors) void {
    const s = &a.updates;
    const to = s.graffTo() orelse return;
    const from = s.graffFrom();
    const can_update = s.graff_kind == .available;
    const shown_count = @min(s.graff_highlights_total, max_highlights);
    const hidden = s.graff_highlights_total -| max_highlights;
    const card_w: f32 = 340;
    const text_col_w: f32 = card_w - 28 - 13;

    var est_h: f32 = 28 + 34 + 10 + 28 + 10 + 26;
    if (shown_count > 0) {
        est_h += 10 + 18;
        for (0..shown_count) |i| {
            const line = s.graff_highlights[i][0..s.graff_highlight_lens[i]];
            const w = c.text.width(line, .{ .size = 12 });
            const n_lines = @max(1.0, @ceil(w / @max(1.0, text_col_w - 8)));
            est_h += n_lines * 17 + 5;
        }
        if (hidden > 0) est_h += 18;
    }
    const note = if (can_update)
        "Installs in the background; open chats keep their current session."
    else if (from) |f|
        c.print("New chats use it. Open chats stay on v{s} until you start a new one.", .{f})
    else
        "New chats use it.";
    const note_lines = @max(1.0, @ceil(c.text.width(note, .{ .size = 11 }) / @max(1.0, card_w - 28 - 8)));
    est_h += (note_lines - 1.0) * 16;

    ui.key(c, "graff-notice");
    const card_id = c.peekId(null);
    const measured_h: ?f32 = if (c.rects.get(card_id)) |r| (if (r.h > 0 and r.h < 600) r.h else null) else null;
    if (measured_h == null) c.frameIn(0);
    const card_h = measured_h orelse est_h;
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(@max(16, c.size.w - card_w - 16), @max(16, c.size.h - card_h - 16))
        .layer(5).column().w(card_w).p(14).gap(10).rounded(12).border(k.border).borderW(1).bg(k.composer.alpha(1))));
    defer card.end();

    // Header: Codegraff mark tile, title, and version step.
    {
        const hd = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer hd.end();
        {
            const tile = ui.div(c).row().size(30, 30).center().rounded(8).bg(k.accent_wash);
            defer tile.end();
            icons.icon(c, .@"graff-mark", 16, k.accent, 0);
        }
        {
            const col = ui.div(c).column().grow().w(0).gap(3);
            defer col.end();
            const title = if (can_update) "Codegraff engine update available" else "Codegraff engine updated";
            ui.text(c, title, .{ .size = 13, .line_height = 17, .weight = .semibold, .color = k.text });
            const ver_row = ui.div(c).row().gap(5).itemsCenter();
            defer ver_row.end();
            if (from) |f| {
                ui.text(c, c.print("v{s}", .{f}), .{ .size = 11, .line_height = 15, .color = k.muted });
                icons.icon(c, .@"arrow-right", 11, k.faint, 0);
            } else if (can_update) {
                ui.text(c, "Not installed", .{ .size = 11, .line_height = 15, .color = k.muted });
                icons.icon(c, .@"arrow-right", 11, k.faint, 0);
            }
            const chip = ui.div(c).row().px(6).py(1).rounded(6).bg(k.accent_wash);
            defer chip.end();
            ui.text(c, c.print("v{s}", .{to}), .{ .size = 11, .line_height = 15, .weight = .semibold, .color = k.accent });
        }
    }

    // Body: WHAT'S NEW highlights from `graff --version`.
    if (shown_count > 0) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        ui.key(c, "graff-notice-highlights");
        const body = ui.div(c).column().wFull().gap(5);
        defer body.end();
        ui.text(c, "WHAT'S NEW", .{ .size = 10.5, .line_height = 14, .weight = .semibold, .color = k.faint });
        for (0..shown_count) |i| {
            const line = s.graff_highlights[i][0..s.graff_highlight_lens[i]];
            const item = ui.div(c).row().wFull().gap(8).itemsStart();
            defer item.end();
            {
                const dot_pad = ui.div(c).column().pt(6);
                defer dot_pad.end();
                kit.dot(c, 5, k.accent);
            }
            const tbox = ui.div(c).column().w(text_col_w);
            defer tbox.end();
            ui.text(c, line, .{ .size = 12, .line_height = 17, .wrap = true, .color = k.text });
        }
        if (hidden > 0) {
            const more = ui.div(c).row().pl(13);
            defer more.end();
            ui.text(c, c.print("+{d} more in the release notes", .{hidden}), .{ .size = 11, .line_height = 15, .color = k.muted });
        }
    }

    // Footnote: what happens to open chats.
    {
        const foot = ui.div(c).row().wFull().gap(6).itemsStart();
        defer foot.end();
        const ncol = ui.div(c).column().w(card_w - 28);
        defer ncol.end();
        ui.text(c, note, .{ .size = 11, .line_height = 16, .color = k.muted, .wrap = true });
    }

    // Action buttons.
    {
        const btns = ui.div(c).row().wFull().justifyEnd().gap(6).itemsCenter();
        defer btns.end();
        if (can_update) {
            ui.key(c, "graff-notice-update");
            const upd = ui.div(c).row().px(10).py(4).rounded(6).border(k.border).borderW(1).hover(k.hover);
            if (!s.graff_updating_manual and upd.clicked()) {
                s.graff_updating_manual = true;
                graff_update.startManual(a);
                a.redraw();
            }
            ui.text(c, if (s.graff_updating_manual) "Updating…" else "Update", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.accent });
            upd.end();
        }
        {
            ui.key(c, "graff-notice-whats-new");
            const notes = ui.div(c).row().px(10).py(4).rounded(6).border(k.border).borderW(1).hover(k.hover);
            if (notes.clicked()) openExternalUrl(c.print("https://github.com/justrach/codegraff/releases/tag/v{s}", .{to}));
            ui.text(c, "Release notes", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.text });
            notes.end();
        }
        {
            ui.key(c, "graff-notice-dismiss");
            const got_it = ui.div(c).row().px(10).py(4).rounded(6).border(k.solid).borderW(1).bg(k.solid);
            if (got_it.clicked()) dismissGraff(a);
            ui.text(c, "Got it", .{ .size = 11.5, .line_height = 16, .weight = .medium, .color = k.on_solid });
            got_it.end();
        }
    }
}

test "native updater resolves only the running bundle never a global CLI" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { exe: []const u8, cli: []const u8 }{
        .{ .exe = "/Applications/Harness.app/Contents/MacOS/harness-nano", .cli = "/Applications/Harness.app/Contents/MacOS/harness" },
        .{ .exe = "/Users/example/Applications/Harness.app/Contents/MacOS/harness-nano", .cli = "/Users/example/Applications/Harness.app/Contents/MacOS/harness" },
        .{ .exe = "/Volumes/Test's Disk/Harness.app/Contents/MacOS/harness-nano", .cli = "/Volumes/Test's Disk/Harness.app/Contents/MacOS/harness" },
    };
    for (cases) |case| {
        const cli = updateCliFor(gpa, case.exe, .macos) orelse return error.ExpectedSibling;
        defer gpa.free(cli);
        try std.testing.expectEqualStrings(case.cli, cli);
    }
    for ([_][]const u8{ "/work/zig-out/bin/harness-nano", "/usr/local/bin/harness-nano", "/tmp/not-a-bundle/Contents/MacOS/harness-nano" }) |exe| {
        try std.testing.expect(updateCliFor(gpa, exe, .macos) == null);
    }
    try std.testing.expect(updateCliFor(gpa, "/tmp/Harness.app/Contents/MacOS/harness-nano", .linux) == null);
    try std.testing.expect(updateCliFor(gpa, "C:\\Harness\\harness-nano.exe", .windows) == null);
    try std.testing.expect(currentBundle("/tmp/Harness.app/Contents/MacOS/harness-nano", .windows) == null);
}

test "native updater release completion never installs or uses restart preference" {
    var a: App = .init(std.testing.allocator, std.testing.io, 1);
    defer a.deinit();
    a.settings.set(.restart_to_install_updates, true);
    a.updates.app_install_checked = true;
    a.updates.app_can_install = true;
    const ver = "99.0.0";
    @memcpy(a.release.latest[0..ver.len], ver);
    a.release.latest_len = ver.len;
    a.release.succeeded = true;
    onReleaseChecked(&a);
    try std.testing.expect(!a.updates.app_downloading);
    try std.testing.expect(!a.updates.app_ready);
    try std.testing.expect(a.settings.get(.restart_to_install_updates));
    try std.testing.expect(a.updates.app_checked_ms > 0);
    var buf: [200]u8 = undefined;
    try std.testing.expect(updateSummary(&buf, &a, a.nowMs()).action == .update);
    a.updates.app_can_install = false;
    try std.testing.expect(updateSummary(&buf, &a, a.nowMs()).action == .check);
    a.release.schedule.failures = 1;
    try std.testing.expect(std.mem.startsWith(u8, updateSummary(&buf, &a, a.nowMs()).line, "Couldn't check"));
}

test "native updater rejects dev and standalone bundle identities" {
    try std.testing.expect(productionBundleId("harness.codegraff.app\n"));
    try std.testing.expect(!productionBundleId("harness.codegraff.app.dev"));
    try std.testing.expect(!productionBundleId("com.justrach.harness-nano"));
    try std.testing.expect(!productionBundleId(""));
}

test "olderEngineNotice reports only older engines" {
    var buf: [320]u8 = undefined;
    const n1 = olderEngineNotice(&buf, "0.2.170", "0.2.169") orelse return error.ExpectedNotice;
    try std.testing.expect(std.mem.indexOf(u8, n1, "0.2.169") != null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.2.99") != null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", null) != null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.2.170") == null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.2.171") == null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "0.3.0") == null);
    try std.testing.expect(olderEngineNotice(&buf, "0.2.170", "custom") == null);
    try std.testing.expectEqual(
        EngineVersionAction.replace_old_session,
        decideEngineVersionAction("0.2.179", "0.2.178", true, false),
    );
    try std.testing.expectEqual(
        EngineVersionAction.notify_only,
        decideEngineVersionAction("0.2.179", "0.2.178", true, true),
    );
    try std.testing.expectEqual(
        EngineVersionAction.notify_only,
        decideEngineVersionAction("0.2.179", "0.2.178", false, false),
    );
    try std.testing.expectEqual(
        EngineVersionAction.up_to_date,
        decideEngineVersionAction("0.2.179", "0.2.179", true, false),
    );
}

test "whatsNew extracts bullets in range from graff --version" {
    const sample =
        \\graff 0.302.74.5
        \\
        \\What's new
        \\──────────
        \\0.302.74.5
        \\  • first highlight
        \\  • second highlight
        \\
        \\0.302.74.4
        \\  • older highlight
        \\
        \\0.302.74.3
        \\  • skipped highlight
    ;
    var lines: [max_highlights][160]u8 = undefined;
    var lens: [max_highlights]usize = @splat(0);
    const total = whatsNew(&lines, &lens, sample, "0.302.74.3", "0.302.74.5");
    try std.testing.expectEqual(@as(usize, 3), total);
    try std.testing.expectEqualStrings("first highlight", lines[0][0..lens[0]]);
    try std.testing.expectEqualStrings("second highlight", lines[1][0..lens[1]]);
    try std.testing.expectEqualStrings("older highlight", lines[2][0..lens[2]]);
}

test "restartPlace chooses sidebar row when open and titlebar when collapsed" {
    try std.testing.expectEqual(RestartPlace.none, restartPlace(null, true, null));
    try std.testing.expectEqual(RestartPlace.sidebar_row, restartPlace("0.2.175", true, null));
    try std.testing.expectEqual(RestartPlace.titlebar, restartPlace("0.2.175", false, null));
    try std.testing.expectEqual(RestartPlace.none, restartPlace("0.2.175", true, "0.2.175"));
}

test "classifyUpdateOutput distinguishes an installed bundle from a no-op (ADR 0008)" {
    try std.testing.expectEqual(
        UpdateCommandOutcome.up_to_date,
        classifyUpdateOutput(true, "Harness 0.2.178 is up to date (latest: 0.2.178).\n", ""),
    );
    try std.testing.expectEqual(
        UpdateCommandOutcome.installed,
        classifyUpdateOutput(true, "downloading harness-0.2.178-macos-arm64-app.tar.gz…\nupdated /Applications/Harness.app — relaunch Harness to finish.\n", ""),
    );
    switch (classifyUpdateOutput(false, "", "network timeout\n")) {
        .failed => |msg| try std.testing.expectEqualStrings("network timeout", msg),
        else => return error.ExpectedFailure,
    }
    // Verify build_info.version tracks Cargo.toml and is never a stale 0.2.175 cache.
    try std.testing.expect(!std.mem.eql(u8, @import("build_info").version, "0.2.175"));
    try std.testing.expect(!std.mem.eql(u8, @import("build_info").version, "0.0.0"));
}
