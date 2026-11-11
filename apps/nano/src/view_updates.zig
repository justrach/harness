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
    graff_card_h: ?f32 = null,
    graff_card_settled: bool = false,
    graff_updating_manual: bool = false,

    restart_dismissed: [32]u8 = undefined,
    restart_dismissed_len: usize = 0,
    titlebar_dismissed: [32]u8 = undefined,
    titlebar_dismissed_len: usize = 0,
    /// True in the desktop app and unit tests; false only in legacy GPUI
    /// parity scenes recorded against an unmanaged binary.
    desktop_update: bool = true,
    app_ready: bool = false,
    app_downloading: bool = false,
    app_checking: bool = false,
    app_checked_ms: i64 = 0,
    app_failed: [160]u8 = undefined,
    app_failed_len: usize = 0,
    app_relaunch_when_ready: bool = false,
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
        s.graff_card_h = null;
        s.graff_card_settled = false;
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

/// Staged app update version ready to restart into (`app_restart_version` in
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
    if (a.updates.app_ready) {
        const ver = latest orelse @import("build_info").version;
        return .{
            .line = std.fmt.bufPrint(buf, "Harness v{s} is downloaded and ready to install.", .{ver}) catch "Update downloaded and ready to install.",
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
    return .{ .line = "Up to date.", .action = .check };
}

pub fn checkForUpdates(a: *App) void {
    a.updates.app_checking = true;
    a.updates.app_failed_len = 0;
    if (!a.offscreen and !builtin.is_test) {
        a.release.start();
    }
    a.redraw();
}

pub fn onReleaseChecked(a: *App) void {
    a.updates.app_checking = false;
    a.updates.app_checked_ms = a.nowMs();
    if (!a.offscreen and !builtin.is_test and a.updates.desktop_update) {
        if (appUpdateVersion(a) != null and !a.updates.app_ready and !a.updates.app_downloading) {
            startAppDownload(a, false);
            return;
        }
    }
    a.redraw();
}

pub fn triggerAppUpdate(a: *App, ver: []const u8) void {
    if (std.mem.eql(u8, ver, "preview")) return;
    if (a.updates.app_ready) {
        restartIntoUpdate(a);
        return;
    }
    startAppDownload(a, true);
}

fn startAppDownload(a: *App, relaunch_when_ready: bool) void {
    a.updates.acquire();
    const already = a.updates.app_downloading;
    a.updates.app_downloading = true;
    a.updates.app_failed_len = 0;
    if (relaunch_when_ready) a.updates.app_relaunch_when_ready = true;
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

fn findHarnessCli(gpa: std.mem.Allocator, io: std.Io, env: ?*const std.process.Environ.Map) ?[]u8 {
    const app_bin = "/Applications/Harness.app/Contents/MacOS/harness";
    if (std.Io.Dir.cwd().access(io, app_bin, .{})) |_| {
        return gpa.dupe(u8, app_bin) catch null;
    } else |_| {}
    if (env) |e| return @import("engine_start.zig").find(gpa, e);
    return null;
}

fn appUpdateWorker(a: *App) void {
    if (comptime !std.process.can_spawn) return;
    const bin = findHarnessCli(a.gpa, a.io, a.env) orelse {
        a.updates.acquire();
        a.updates.app_downloading = false;
        a.updates.setAppFailed("Harness CLI not found in /Applications/Harness.app");
        a.updates.dirty = true;
        a.updates.release();
        nanoui.App.after(0, a, appUpdateDelivered);
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
        nanoui.App.after(0, a, appUpdateDelivered);
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
        .staged => {
            a.updates.app_ready = true;
            a.updates.app_failed_len = 0;
        },
        .up_to_date => {
            a.updates.app_ready = false;
            a.updates.app_relaunch_when_ready = false;
            a.updates.app_failed_len = 0;
        },
        .failed => |line| {
            a.updates.setAppFailed(line);
        },
    }
    a.updates.dirty = true;
    a.updates.release();
    nanoui.App.after(0, a, appUpdateDelivered);
}

pub const UpdateCommandOutcome = union(enum) {
    staged,
    up_to_date,
    failed: []const u8,
};

/// Pure classifier for `harness update` process output (ADR 0008). Only a
/// bundle swap (`"relaunch Harness to finish"`) marks an update ready; a no-op
/// (`"is up to date"`) must never mark `app_ready` or trigger a relaunch loop.
pub fn classifyUpdateOutput(exited_zero: bool, stdout: []const u8, stderr: []const u8) UpdateCommandOutcome {
    if (exited_zero and std.mem.indexOf(u8, stdout, "relaunch Harness to finish") != null) {
        return .staged;
    }
    if (exited_zero and std.mem.indexOf(u8, stdout, "is up to date") != null) {
        return .up_to_date;
    }
    const line = firstLine(stderr) orelse firstLine(stdout) orelse "update exited with an error";
    return .{ .failed = line };
}

/// Pure guard for whether `appUpdateDelivered` may exit and relaunch the app
/// immediately (ADR 0008): only when the update is staged AND the user
/// explicitly requested a relaunch (`relaunch_when_ready`).
pub fn shouldRelaunchOnDeliver(ready: bool, relaunch_when_ready: bool) bool {
    return ready and relaunch_when_ready;
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
    a.updates.acquire();
    const ready = a.updates.app_ready;
    const relaunch = a.updates.app_relaunch_when_ready;
    a.updates.app_relaunch_when_ready = false;
    a.updates.release();
    a.redraw();
    if (shouldRelaunchOnDeliver(ready, relaunch)) {
        restartIntoUpdate(a);
    }
}

pub fn restartIntoUpdate(a: *App) void {
    if (builtin.is_test or a.offscreen) return;
    @import("engine_start.zig").stopForUpdate(a);
    if (comptime builtin.os.tag == .macos) {
        const pid = std.c.getpid();
        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &cmd_buf,
            "while /bin/kill -0 {d} 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"/Applications/Harness.app\"",
            .{pid},
        ) catch return;
        if (std.process.spawn(a.io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        })) |child| {
            var c = child;
            _ = &c;
            std.process.exit(0);
        } else |_| {}
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
            c.print("Harness v{s} is available. Click to update.", .{ver});
        const label = if (ready)
            "Restart to update"
        else if (a.updates.app_downloading)
            c.print("Downloading v{s}…", .{ver})
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
            .text = "Not now: it installs the next time Harness restarts",
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
        c.print("Harness v{s} is available. Click to update.", .{ver});
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
    const card_id = c.peekId("graff-notice");
    const measured_h: ?f32 = if (c.rects.get(card_id)) |r| (if (r.h > 0 and r.h < 600) r.h else null) else null;
    const card_h = measured_h orelse s.graff_card_h orelse est_h;
    const card = @import("view_sidebar_menus.zig").held(kit.shadowLg(ui.div(c).fixed().offset(@max(16, c.size.w - card_w - 16), @max(16, c.size.h - card_h - 16))
        .layer(5).column().w(card_w).p(14).gap(10).rounded(12).border(k.border).borderW(1).bg(k.composer.alpha(1))));
    defer card.end();
    if (c.rects.get(c.node(card.index).id)) |r| {
        if (r.h > 0 and r.h < 600) s.graff_card_h = r.h;
        s.graff_card_settled = true;
    } else if (measured_h == null and !s.graff_card_settled) {
        s.graff_card_settled = true;
        c.frameIn(0);
    }

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

test "classifyUpdateOutput and shouldRelaunchOnDeliver prevent no-op relaunch loops (ADR 0008)" {
    try std.testing.expectEqual(
        UpdateCommandOutcome.up_to_date,
        classifyUpdateOutput(true, "Harness 0.2.178 is up to date (latest: 0.2.178).\n", ""),
    );
    try std.testing.expectEqual(
        UpdateCommandOutcome.staged,
        classifyUpdateOutput(true, "downloading harness-0.2.178-macos-arm64-app.tar.gz…\nupdated /Applications/Harness.app — relaunch Harness to finish.\n", ""),
    );
    switch (classifyUpdateOutput(false, "", "network timeout\n")) {
        .failed => |msg| try std.testing.expectEqualStrings("network timeout", msg),
        else => return error.ExpectedFailure,
    }
    // Background downloads (`relaunch_when_ready = false`) never auto-exit the window.
    try std.testing.expect(!shouldRelaunchOnDeliver(true, false));
    try std.testing.expect(!shouldRelaunchOnDeliver(false, true));
    try std.testing.expect(shouldRelaunchOnDeliver(true, true));
    // Verify build_info.version tracks Cargo.toml and is never a stale 0.2.175 cache.
    try std.testing.expect(!std.mem.eql(u8, @import("build_info").version, "0.2.175"));
    try std.testing.expect(!std.mem.eql(u8, @import("build_info").version, "0.0.0"));
}
