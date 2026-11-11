//! graff Bots host (`crates/engine/src/bots.rs`, `crates/proto/src/bots.rs`,
//! `crates/harness/src/acp/graff_bot.rs` — codegraff ADR 0333, 0334).
//!
//! Bots are experimental and off until enabled (`~/.graff/bots/enabled` or `GRAFF_BOTS=1`).
//! While off, `BotsState` spawns zero child processes and returns the default disabled payload,
//! and `BotDetail` / `RunBot` / non-toggle `BotAction` refuse with `off_msg`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const too_old_msg = "This graff can't run bots yet. Update graff to use them here.";
pub const off_msg = "Bots are off. Turn them on in Settings › Agents.";
pub const bad_bot_name_msg = "A bot's name is lowercase letters, digits, - and _ (32 at most).";
pub const bad_routine_msg = "Say which routine.";
pub const stale_after_secs: u64 = 300;
pub const session_stale_ms: i64 = 45_000;

/// Allowed `graff bot --user <verb>` store commands (`crates/harness/src/acp/graff_bot.rs`).
/// `run`, `tick`, and `trigger` are excluded by design so runs always happen in standing chats.
pub const allowed_cli_verbs = [_][]const u8{
    "state",
    "show",
    "prompt",
    "create",
    "rm",
    "set",
    "remember",
    "forget",
    "about",
    "missed",
    "due",
    "routine",
    "enable",
    "disable",
};

pub fn isAllowedCliVerb(verb: []const u8) bool {
    for (allowed_cli_verbs) |v| {
        if (std.mem.eql(u8, v, verb)) return true;
    }
    return false;
}

/// `crates/proto/src/bots.rs::valid_bot_name`
pub fn validBotName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (name[0] == '-' or name[0] == '_') return false;
    for (name) |c| {
        if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

/// `crates/proto/src/bots.rs::valid_routine_id`
pub fn validRoutineId(id: []const u8) bool {
    if (id.len < 2 or id.len > 12) return false;
    if (id[0] != 'r') return false;
    for (id[1..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// `crates/engine/src/bots.rs::flag_on`
pub fn flagOn(env_val: ?[]const u8, marker_file_exists: bool) bool {
    if (env_val) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(trimmed, "1") or std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
        if (std.ascii.eqlIgnoreCase(trimmed, "0") or std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    }
    return marker_file_exists;
}

pub fn sameFolder(a: []const u8, b: []const u8) bool {
    return std.mem.eql(
        u8,
        std.mem.trimEnd(u8, a, "/\\"),
        std.mem.trimEnd(u8, b, "/\\"),
    );
}

pub fn framedPromptAlloc(gpa: Allocator, standing: []const u8, turn: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s}\n\n{s}",
        .{ std.mem.trim(u8, standing, " \t\r\n"), std.mem.trim(u8, turn, " \t\r\n") },
    );
}

/// `crates/engine/src/bots.rs::refusal`
pub fn refusalMessageAlloc(gpa: Allocator, success: bool, stdout: []const u8, stderr: []const u8) !?[]u8 {
    const out_trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (std.mem.indexOf(u8, stderr, "unknown flag") != null or
        std.mem.startsWith(u8, out_trimmed, "usage: graff bot"))
    {
        return try gpa.dupe(u8, too_old_msg);
    }
    if (success) return null;

    var last_non_empty: ?[]const u8 = null;
    var out_lines = std.mem.splitScalar(u8, stdout, '\n');
    while (out_lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len > 0) last_non_empty = t;
    }
    var err_lines = std.mem.splitScalar(u8, stderr, '\n');
    while (err_lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len > 0) last_non_empty = t;
    }

    const chosen = last_non_empty orelse "graff exited with an error";
    const stripped = if (std.mem.startsWith(u8, chosen, "graff bot: "))
        chosen["graff bot: ".len..]
    else
        chosen;
    const copy = try gpa.dupe(u8, stripped);
    if (copy.len > 0 and std.ascii.isLower(copy[0])) {
        copy[0] = std.ascii.toUpper(copy[0]);
    }
    return copy;
}

pub const BotVerb = enum {
    enable,
    disable,
    create,
    remove,
    setJob,
    setModel,
    setProject,
    setPrimary,
    routineAdd,
    routinePause,
    routineResume,
    routineRemove,
    missedClear,
    remember,
    forget,
    about,
};

pub const bot_verb_map = std.StaticStringMap(BotVerb).initComptime(.{
    .{ "enable", .enable },
    .{ "disable", .disable },
    .{ "create", .create },
    .{ "remove", .remove },
    .{ "setJob", .setJob },
    .{ "setModel", .setModel },
    .{ "setProject", .setProject },
    .{ "setPrimary", .setPrimary },
    .{ "routineAdd", .routineAdd },
    .{ "routinePause", .routinePause },
    .{ "routineResume", .routineResume },
    .{ "routineRemove", .routineRemove },
    .{ "missedClear", .missedClear },
    .{ "remember", .remember },
    .{ "forget", .forget },
    .{ "about", .about },
});

pub const ActionPlan = union(enum) {
    ok: struct {
        verb: BotVerb,
        bot_name: ?[]u8,
        argv_tail: [][]u8,

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            if (self.bot_name) |b| gpa.free(b);
            for (self.argv_tail) |s| gpa.free(s);
            gpa.free(self.argv_tail);
        }
    },
    bad_params: []const u8,
    failed_msg: []u8,
};

fn optTrimmedStr(obj: json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return std.mem.trim(u8, v.string, " \t\r\n");
    }
    return "";
}

fn appendOwnedWord(gpa: Allocator, list: *std.ArrayList([]u8), word: []const u8) !void {
    const copy = try gpa.dupe(u8, word);
    errdefer gpa.free(copy);
    try list.append(gpa, copy);
}

/// Build `graff bot --user <args...>` matching `crates/engine/src/bots.rs::action_args`.
pub fn buildActionPlan(gpa: Allocator, obj: json.ObjectMap) !ActionPlan {
    const action_str = if (obj.get("action")) |v| (if (v == .string) v.string else return .{ .bad_params = "missing action" }) else return .{ .bad_params = "missing action" };
    const verb = bot_verb_map.get(action_str) orelse return .{ .bad_params = "unknown bot action" };

    const bot_raw = optTrimmedStr(obj, "bot");
    const routine_raw = optTrimmedStr(obj, "routine");
    const text = optTrimmedStr(obj, "text");
    const when = optTrimmedStr(obj, "when");
    const project = optTrimmedStr(obj, "project");
    const primary_opt: ?bool = if (obj.get("primary")) |pv| (if (pv == .bool) pv.bool else null) else null;

    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }

    var bot_owned: ?[]u8 = null;
    errdefer if (bot_owned) |b| gpa.free(b);

    switch (verb) {
        .enable => {
            try appendOwnedWord(gpa, &list, "enable");
        },
        .disable => {
            try appendOwnedWord(gpa, &list, "disable");
        },
        .create => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            if (text.len == 0) return .{ .failed_msg = try gpa.dupe(u8, "Say what the bot's job is.") };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "create");
            try appendOwnedWord(gpa, &list, bot_raw);
            if (project.len > 0) {
                try appendOwnedWord(gpa, &list, "--project");
                try appendOwnedWord(gpa, &list, project);
            }
            if (primary_opt == true) {
                try appendOwnedWord(gpa, &list, "--primary");
            }
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, text);
        },
        .remove => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "rm");
            try appendOwnedWord(gpa, &list, bot_raw);
        },
        .setJob => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            if (text.len == 0) return .{ .failed_msg = try gpa.dupe(u8, "Say the job.") };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "set");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, "job");
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, text);
        },
        .setModel => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "set");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, "model");
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, text);
        },
        .setProject => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "set");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, "project");
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, text);
        },
        .setPrimary => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "set");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, "primary");
            try appendOwnedWord(gpa, &list, if (primary_opt == false) "false" else "true");
        },
        .routineAdd => {
            if (when.len == 0) return .{ .failed_msg = try gpa.dupe(u8, "Say when it runs: 30m (once) or @every 2h.") };
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            if (text.len == 0) return .{ .failed_msg = try gpa.dupe(u8, "Say what the routine does.") };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "routine");
            try appendOwnedWord(gpa, &list, "add");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, when);
            try appendOwnedWord(gpa, &list, text);
        },
        .routinePause, .routineResume, .routineRemove => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            if (!validRoutineId(routine_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_routine_msg) };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "routine");
            try appendOwnedWord(gpa, &list, switch (verb) {
                .routinePause => "pause",
                .routineResume => "resume",
                else => "rm",
            });
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, routine_raw);
        },
        .missedClear => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            if (!validRoutineId(routine_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_routine_msg) };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "missed");
            try appendOwnedWord(gpa, &list, "clear");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, routine_raw);
        },
        .remember => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            if (text.len == 0) return .{ .failed_msg = try gpa.dupe(u8, "Say what to remember.") };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "remember");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, text);
        },
        .forget => {
            if (!validBotName(bot_raw)) return .{ .failed_msg = try gpa.dupe(u8, bad_bot_name_msg) };
            if (text.len == 0) return .{ .failed_msg = try gpa.dupe(u8, "Say which entry.") };
            bot_owned = try gpa.dupe(u8, bot_raw);
            try appendOwnedWord(gpa, &list, "forget");
            try appendOwnedWord(gpa, &list, bot_raw);
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, text);
        },
        .about => {
            try appendOwnedWord(gpa, &list, "about");
            try appendOwnedWord(gpa, &list, "--");
            try appendOwnedWord(gpa, &list, text);
        },
    }

    return .{ .ok = .{
        .verb = verb,
        .bot_name = bot_owned,
        .argv_tail = try list.toOwnedSlice(gpa),
    } };
}

pub fn disabledStateJsonAlloc(gpa: Allocator) ![]u8 {
    return gpa.dupe(
        u8,
        "{\"enabled\":false,\"nowMs\":0,\"lastCheckMs\":0,\"gapFromMs\":0,\"gapToMs\":0,\"about\":\"\",\"bots\":[]}",
    );
}

fn jStr(o: json.ObjectMap, key: []const u8) []const u8 {
    if (o.get(key)) |v| if (v == .string) return v.string;
    return "";
}

fn jInt(o: json.ObjectMap, k1: []const u8, k2: []const u8) i64 {
    if (o.get(k1)) |v| if (v == .integer) return v.integer;
    if (k2.len > 0) {
        if (o.get(k2)) |v| if (v == .integer) return v.integer;
    }
    return 0;
}

fn jBool(o: json.ObjectMap, key: []const u8) bool {
    if (o.get(key)) |v| if (v == .bool) return v.bool;
    return false;
}

/// Convert `graff bot --user state --json` (snake_case) to wire `BotsState` (camelCase,
/// omitting `routine.message` on the wire per `crates/proto/src/bots.rs`).
pub fn translateGraffStateToWireJson(gpa: Allocator, raw_json: []const u8, enabled: bool) !?[]u8 {
    var parsed = json.parseFromSlice(json.Value, gpa, raw_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        "{{\"enabled\":{},\"nowMs\":{d},\"lastCheckMs\":{d},\"gapFromMs\":{d},\"gapToMs\":{d},\"about\":{f},\"bots\":[",
        .{
            enabled,
            jInt(o, "now_ms", "nowMs"),
            jInt(o, "last_check_ms", "lastCheckMs"),
            jInt(o, "gap_from_ms", "gapFromMs"),
            jInt(o, "gap_to_ms", "gapToMs"),
            json.fmt(jStr(o, "about"), .{}),
        },
    );

    if (o.get("bots")) |bv| {
        if (bv == .array) {
            var b_idx: usize = 0;
            for (bv.array.items) |item| {
                if (item != .object) continue;
                const bo = item.object;
                const name = jStr(bo, "name");
                if (name.len == 0) continue;
                if (b_idx > 0) try w.writeByte(',');
                b_idx += 1;
                try w.print(
                    "{{\"name\":{f},\"job\":{f},\"model\":{f},\"yolo\":{},\"project\":{f},\"primary\":{},\"chat\":{f},\"createdMs\":{d},\"routines\":[",
                    .{
                        json.fmt(name, .{}),
                        json.fmt(jStr(bo, "job"), .{}),
                        json.fmt(jStr(bo, "model"), .{}),
                        jBool(bo, "yolo"),
                        json.fmt(jStr(bo, "project"), .{}),
                        jBool(bo, "primary"),
                        json.fmt(jStr(bo, "chat"), .{}),
                        jInt(bo, "created_ms", "createdMs"),
                    },
                );
                if (bo.get("routines")) |rv| {
                    if (rv == .array) {
                        var r_idx: usize = 0;
                        for (rv.array.items) |ritem| {
                            if (ritem != .object) continue;
                            const ro = ritem.object;
                            const rid = jStr(ro, "id");
                            if (rid.len == 0) continue;
                            if (r_idx > 0) try w.writeByte(',');
                            r_idx += 1;
                            try w.print(
                                "{{\"id\":{f},\"instruction\":{f},\"when\":{f},\"atMs\":{d},\"intervalMs\":{d},\"paused\":{},\"done\":{},\"runs\":{d},\"lastRunMs\":{d},\"missedAtMs\":{d},\"missedOpen\":{d},\"due\":{}}}",
                                .{
                                    json.fmt(rid, .{}),
                                    json.fmt(jStr(ro, "instruction"), .{}),
                                    json.fmt(jStr(ro, "when"), .{}),
                                    jInt(ro, "at_ms", "atMs"),
                                    jInt(ro, "interval_ms", "intervalMs"),
                                    jBool(ro, "paused"),
                                    jBool(ro, "done"),
                                    @max(@as(i64, 0), jInt(ro, "runs", "")),
                                    jInt(ro, "last_run_ms", "lastRunMs"),
                                    jInt(ro, "missed_at_ms", "missedAtMs"),
                                    @max(@as(i64, 0), jInt(ro, "missed_open", "missedOpen")),
                                    jBool(ro, "due"),
                                },
                            );
                        }
                    }
                }
                try w.writeAll("]}");
            }
        }
    }

    try w.writeAll("]}");
    return try aw.toOwnedSlice();
}

pub fn translateGraffDetailToWireJson(gpa: Allocator, raw_json: []const u8) !?[]u8 {
    var parsed = json.parseFromSlice(json.Value, gpa, raw_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    return try std.fmt.allocPrint(
        gpa,
        "{{\"memory\":{f},\"log\":{f}}}",
        .{
            json.fmt(jStr(o, "memory"), .{}),
            json.fmt(jStr(o, "log"), .{}),
        },
    );
}

pub const CliOutcome = union(enum) {
    ok: []u8,
    err_msg: []u8,
};

pub fn checkMarkerEnabled(gpa: Allocator, io: ?std.Io, home_dir: ?[]const u8, env_override: ?[]const u8) bool {
    var marker = false;
    if (io) |live_io| {
        if (home_dir) |home| {
            if (std.fmt.allocPrint(gpa, "{s}/.graff/bots/enabled", .{std.mem.trimEnd(u8, home, "/")})) |p| {
                defer gpa.free(p);
                if (std.Io.Dir.cwd().statFile(live_io, p, .{})) |st| {
                    marker = (st.kind == .file);
                } else |_| {}
            } else |_| {}
        }
    }
    return flagOn(env_override, marker);
}

pub fn runGraffBotCli(
    gpa: Allocator,
    io: std.Io,
    home_dir: []const u8,
    graff_bin_override: ?[]const u8,
    args: []const []const u8,
) !CliOutcome {
    const verb = if (args.len > 0) args[0] else "";
    if (!isAllowedCliVerb(verb)) {
        return .{ .err_msg = try std.fmt.allocPrint(gpa, "not a graff bot command: {s}", .{verb}) };
    }

    var managed_path_owned: ?[]u8 = null;
    defer if (managed_path_owned) |p| gpa.free(p);

    const prog: []const u8 = if (graff_bin_override) |ov| ov else blk: {
        const candidate = try std.fmt.allocPrint(gpa, "{s}/.harness/bin/graff", .{std.mem.trimEnd(u8, home_dir, "/")});
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| {
            managed_path_owned = candidate;
            break :blk candidate;
        } else |_| {
            gpa.free(candidate);
            break :blk "graff";
        }
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, prog);
    try argv.append(gpa, "bot");
    try argv.append(gpa, "--user");
    for (args) |a| try argv.append(gpa, a);

    var env_map = std.process.Environ.Map.init(gpa);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("NO_COLOR", "1");
    if (comptime builtin.os.tag != .windows) {
        if (std.c.getenv("PATH")) |p_z| {
            try env_map.put("PATH", std.mem.span(p_z));
        } else {
            try env_map.put("PATH", "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin");
        }
        if (std.c.getenv("GRAFF_BOTS")) |gb_z| {
            try env_map.put("GRAFF_BOTS", std.mem.span(gb_z));
        }
    }

    const res = std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env_map,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(512 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return .{
            .err_msg = try gpa.dupe(u8, "The `graff` CLI was not found on this device — install it first."),
        },
        else => return .{
            .err_msg = try std.fmt.allocPrint(gpa, "Could not run graff bot: {t}", .{err}),
        },
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const exited_ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (try refusalMessageAlloc(gpa, exited_ok, res.stdout, res.stderr)) |refused| {
        return .{ .err_msg = refused };
    }
    return .{ .ok = try gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n")) };
}

test "1:1 Rust bots wire translation, command-word safety, and CLI verb allowlist" {
    const gpa = testing.allocator;

    // 1. CLI verb allowlist (`crates/harness/src/acp/graff_bot.rs`)
    for ([_][]const u8{ "", "run", "tick", "trigger", "--help", "state; rm" }) |bad| {
        try testing.expect(!isAllowedCliVerb(bad));
    }
    for ([_][]const u8{ "state", "show", "prompt", "create", "rm", "set", "due", "routine", "enable", "disable" }) |ok| {
        try testing.expect(isAllowedCliVerb(ok));
    }

    // 2. Bot name & routine id validation (`crates/proto/src/bots.rs`)
    for ([_][]const u8{ "triage", "release-notes", "bot_2", "9lives" }) |ok| {
        try testing.expect(validBotName(ok));
    }
    for ([_][]const u8{ "", "Triage", "a b", "../x", "-lead", "_lead", "--yolo", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }) |bad| {
        try testing.expect(!validBotName(bad));
    }
    for ([_][]const u8{ "r1", "r42" }) |ok| {
        try testing.expect(validRoutineId(ok));
    }
    for ([_][]const u8{ "", "r", "1", "r1x", "--json", "r-1" }) |bad| {
        try testing.expect(!validRoutineId(bad));
    }

    // 3. Snake_case -> camelCase translation & stripping `routine.message` (`crates/proto/src/bots.rs:171-194`)
    const snake =
        \\{"scope":"user","now_ms":9,"last_check_ms":7,"gap_from_ms":3,"gap_to_ms":7,"about":"Alex.",
        \\ "bots":[{"name":"notes","job":"Draft release notes","model":"","yolo":false,"project":"/repo/comet",
        \\          "primary":false,"chat":"c1","created_ms":1,
        \\          "routines":[{"bot":"notes","id":"r1","instruction":"draft","when":"every 6h",
        \\                       "at_ms":5,"interval_ms":21600000,"paused":false,"done":false,"runs":11,
        \\                       "last_run_ms":4,"missed_at_ms":2,"missed_open":1,"due":false,
        \\                       "message":"[routine r1] draft"}]}]}
    ;
    const wire = (try translateGraffStateToWireJson(gpa, snake, true)) orelse return error.TestUnexpectedResult;
    defer gpa.free(wire);
    try testing.expect(std.mem.indexOf(u8, wire, "\"enabled\":true") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"lastCheckMs\":7") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"gapFromMs\":3") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"missedOpen\":1") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"intervalMs\":21600000") != null);
    try testing.expect(std.mem.indexOf(u8, wire, "\"message\"") == null);
}
