//! Native extension panel collector for bound macOS GitHub Actions runners
//! (`harness-m3-1` & `harness-m3-2`) with cloud-fallback observability.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const WorkerSpec = struct {
    default_name: []const u8,
    dir_name: []const u8,
    service: []const u8,
    log_rel: []const u8,
};

pub const workers = [2]WorkerSpec{
    .{
        .default_name = "harness-m3-1",
        .dir_name = "harness-1",
        .service = "actions.runner.justrach-harness.harness-m3-1",
        .log_rel = "Library/Logs/actions.runner.justrach-harness.harness-m3-1/stdout.log",
    },
    .{
        .default_name = "harness-m3-2",
        .dir_name = "harness-2",
        .service = "actions.runner.justrach-harness.harness-m3-2",
        .log_rel = "Library/Logs/actions.runner.justrach-harness.harness-m3-2/stdout.log",
    },
};

pub const heartbeat_service = "actions.runner.justrach-harness.heartbeat";
pub const default_repo = "justrach/harness";
pub const heartbeat_state_path = "/tmp/harness-runner-heartbeat.state";
pub const heavy_lock_pid_path = "/tmp/harness-ci-heavy-build.lock/pid";

pub const mac = if (builtin.os.tag == .macos) struct {
    pub const PROC_ALL_PIDS: u32 = 1;
    pub const PROC_PIDTBSDSHORTINFO: c_int = 13;
    pub const RUSAGE_INFO_V2: c_int = 2;
    pub const PROC_PIDPATHINFO_MAXSIZE: usize = 4096;

    pub const ShortInfo = extern struct {
        pid: u32,
        ppid: u32,
        pgid: u32,
        status: u32,
        comm: [16]u8,
        flags: u32,
        uid: u32,
        gid: u32,
        ruid: u32,
        rgid: u32,
        svuid: u32,
        svgid: u32,
        rfu: u32,
    };

    pub const Rusage = extern struct {
        uuid: [16]u8,
        user_time: u64,
        system_time: u64,
        pkg_idle_wkups: u64,
        interrupt_wkups: u64,
        pageins: u64,
        wired_size: u64,
        resident_size: u64,
        phys_footprint: u64,
        proc_start_abstime: u64,
        proc_exit_abstime: u64,
        child_user_time: u64,
        child_system_time: u64,
        child_pkg_idle_wkups: u64,
        child_interrupt_wkups: u64,
        child_pageins: u64,
        child_elapsed_abstime: u64,
        diskio_bytesread: u64,
        diskio_byteswritten: u64,
    };

    pub const Timebase = extern struct { numer: u32, denom: u32 };

    pub const StatVfs = extern struct {
        f_bsize: c_ulong,
        f_frsize: c_ulong,
        f_blocks: c_uint,
        f_bfree: c_uint,
        f_bavail: c_uint,
        f_files: c_uint,
        f_ffree: c_uint,
        f_favail: c_uint,
        f_fsid: c_ulong,
        f_flag: c_ulong,
        f_namemax: c_ulong,
    };

    pub extern "c" fn proc_listpids(kind: u32, typeinfo: u32, buffer: ?*anyopaque, buffersize: c_int) c_int;
    pub extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
    pub extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
    pub extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *Rusage) c_int;
    pub extern "c" fn mach_timebase_info(info: *Timebase) c_int;
    pub extern "c" fn statvfs(path: [*:0]const u8, buf: *StatVfs) c_int;
    pub extern "c" fn getuid() c_uint;
} else struct {};

pub const RunnerConfig = struct {
    agent_name: ?[]const u8 = null,
    agent_id: ?i64 = null,
    repo: ?[]const u8 = null,
};

pub const CompletedJob = struct {
    worker: []const u8,
    job: []const u8,
    result: []const u8,
    epoch: i64,
};

pub const LogParse = struct {
    version: ?[]const u8 = null,
    active_job: ?[]const u8 = null,
    active_started_epoch: ?i64 = null,
    completed: []const CompletedJob = &.{},
};

pub const ProcSample = struct {
    pid: ?u32 = null,
    listener_alive: bool = false,
    worker_alive: bool = false,
    cpu_pct: u32 = 0,
    rss_bytes: u64 = 0,
};

pub const WorkerStatus = struct {
    name: []const u8,
    configured: bool = false,
    agent_id: ?i64 = null,
    version: ?[]const u8 = null,
    active_job: ?[]const u8 = null,
    active_started_epoch: ?i64 = null,
    proc: ProcSample = .{},
};

pub const Snapshot = struct {
    now_epoch: i64,
    repo: []const u8 = "",
    paused: bool = false,
    heartbeat_known: bool = false,
    heartbeat_online: bool = false,
    lock_pid: ?u32 = null,
    disk_free_bytes: ?u64 = null,
    workers: [2]WorkerStatus,
    recent_jobs: []const CompletedJob = &.{},
};

pub fn parseRunnerConfig(a: Allocator, raw: []const u8) RunnerConfig {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "\xEF\xBB\xBF")) trimmed = trimmed[3..];
    if (trimmed.len == 0) return .{};
    const parsed = json.parseFromSliceLeaky(json.Value, a, trimmed, .{ .ignore_unknown_fields = true }) catch return .{};
    if (parsed != .object) return .{};
    var cfg: RunnerConfig = .{};
    if (parsed.object.get("agentName")) |v| if (v == .string and v.string.len > 0) {
        cfg.agent_name = a.dupe(u8, v.string) catch null;
    };
    if (parsed.object.get("agentId")) |v| switch (v) {
        .integer => |n| cfg.agent_id = n,
        .float => |f| cfg.agent_id = @intFromFloat(f),
        .string => |s| cfg.agent_id = std.fmt.parseInt(i64, s, 10) catch null,
        else => {},
    };
    if (parsed.object.get("gitHubUrl")) |v| if (v == .string) {
        cfg.repo = extractRepo(a, v.string);
    };
    return cfg;
}

pub fn extractRepo(a: Allocator, url: []const u8) ?[]const u8 {
    const marker = "github.com/";
    const idx = std.mem.indexOf(u8, url, marker) orelse return null;
    var rest = url[idx + marker.len ..];
    rest = std.mem.trimEnd(u8, rest, "/ \t\r\n");
    if (std.mem.endsWith(u8, rest, ".git")) rest = rest[0 .. rest.len - 4];
    var slash_parts: usize = 0;
    var end: usize = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '/') {
            slash_parts += 1;
            if (slash_parts == 2) {
                end = i;
                break;
            }
        }
    }
    rest = rest[0..end];
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') == null) return null;
    return a.dupe(u8, rest) catch null;
}

/// Converts `"YYYY-MM-DD HH:MM:SSZ"` UTC strings into Unix epoch seconds.
pub fn parseUtcTimestamp(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != ' ' and s[10] != 'T') or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m_adj = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * m_adj + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

pub fn parseRunnerLog(a: Allocator, worker_name: []const u8, text: []const u8) LogParse {
    var res: LogParse = .{};
    var completed: std.ArrayList(CompletedJob) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "Current runner version: '")) |v_ix| {
            const after = line[v_ix + "Current runner version: '".len ..];
            if (std.mem.indexOfScalar(u8, after, '\'')) |end_q| {
                res.version = a.dupe(u8, after[0..end_q]) catch res.version;
            }
            continue;
        }
        if (line.len < 22 or line[19] != 'Z' or line[20] != ':') continue;
        const ts = parseUtcTimestamp(line[0..20]) orelse continue;
        const body = std.mem.trimStart(u8, line[21..], " ");
        if (std.mem.startsWith(u8, body, "Running job: ")) {
            const job = std.mem.trim(u8, body["Running job: ".len..], " ");
            if (job.len > 0) {
                res.active_job = a.dupe(u8, job) catch res.active_job;
                res.active_started_epoch = ts;
            }
        } else if (std.mem.startsWith(u8, body, "Job ")) {
            const rest = body["Job ".len..];
            const marker = " completed with result: ";
            if (std.mem.indexOf(u8, rest, marker)) |m_ix| {
                const job = std.mem.trim(u8, rest[0..m_ix], " ");
                const result = std.mem.trim(u8, rest[m_ix + marker.len ..], " ");
                if (res.active_job) |aj| {
                    if (std.mem.eql(u8, aj, job)) {
                        res.active_job = null;
                        res.active_started_epoch = null;
                    }
                }
                if (job.len > 0 and result.len > 0) {
                    completed.append(a, .{
                        .worker = worker_name,
                        .job = a.dupe(u8, job) catch continue,
                        .result = a.dupe(u8, result) catch continue,
                        .epoch = ts,
                    }) catch {};
                }
            }
        }
    }
    res.completed = completed.items;
    return res;
}

fn readSmall(io: std.Io, a: Allocator, path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 * 1024)) catch null;
}

fn readTail(io: std.Io, a: Allocator, path: []const u8, max_bytes: usize) ?[]const u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const stat = f.stat(io) catch return null;
    const start: u64 = if (stat.size > max_bytes) stat.size - max_bytes else 0;
    const want: usize = @intCast(stat.size - start);
    if (want == 0) return "";
    const buf = a.alloc(u8, want) catch return null;
    const got = f.readPositionalAll(io, buf, start) catch return null;
    const text = buf[0..got];
    if (start > 0) {
        if (std.mem.indexOfScalar(u8, text, '\n')) |nl| return text[nl + 1 ..];
    }
    return text;
}

pub fn collect(a: Allocator, io: std.Io, env: *const std.process.Environ.Map) Snapshot {
    if (env.get("HARNESS_GH_RUNNERS_ROOT")) |root| {
        if (root.len > 0) return collectFixture(a, io, root);
    }
    return collectHost(a, io, env);
}

fn collectFixture(a: Allocator, io: std.Io, root: []const u8) Snapshot {
    const real_now: i64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
    const now_txt = if (readSmall(io, a, pathJoin(a, root, "now_epoch"))) |s| std.mem.trim(u8, s, " \t\r\n") else "";
    const now_epoch = if (now_txt.len > 0) (std.fmt.parseInt(i64, now_txt, 10) catch real_now) else real_now;
    const hb_raw = readSmall(io, a, pathJoin(a, root, "heartbeat.state")) orelse "";
    const hb_trim = std.mem.trim(u8, hb_raw, " \t\r\n");
    const paused = std.mem.eql(u8, hb_trim, "offline");
    const hb_online = std.mem.eql(u8, hb_trim, "online");
    const lock_raw = readSmall(io, a, pathJoin(a, root, "heavy-build.lock/pid")) orelse "";
    const lock_pid = std.fmt.parseInt(u32, std.mem.trim(u8, lock_raw, " \t\r\n"), 10) catch null;
    const disk_raw = readSmall(io, a, pathJoin(a, root, "disk_free_bytes")) orelse "";
    const disk_free = std.fmt.parseInt(u64, std.mem.trim(u8, disk_raw, " \t\r\n"), 10) catch null;

    var statuses: [2]WorkerStatus = undefined;
    var all_jobs: std.ArrayList(CompletedJob) = .empty;
    var repo: []const u8 = "";

    for (workers, 0..) |spec, ix| {
        const w_dir = pathJoin(a, root, spec.dir_name);
        const cfg_raw = readSmall(io, a, pathJoin(a, w_dir, ".runner"));
        const cfg = if (cfg_raw) |raw| parseRunnerConfig(a, raw) else RunnerConfig{};
        const name = cfg.agent_name orelse spec.default_name;
        if (repo.len == 0) if (cfg.repo) |r| {
            repo = r;
        };
        const log_raw = readTail(io, a, pathJoin(a, w_dir, "stdout.log"), 256 * 1024) orelse "";
        const lp = parseRunnerLog(a, name, log_raw);
        for (lp.completed) |job| all_jobs.append(a, job) catch {};

        var proc: ProcSample = .{};
        if (readSmall(io, a, pathJoin(a, w_dir, "proc.json"))) |pr| {
            proc = parseProcJson(a, pr);
        } else if (cfg_raw != null and !paused) {
            proc.listener_alive = true;
            proc.worker_alive = lp.active_job != null;
        }
        statuses[ix] = .{
            .name = name,
            .configured = cfg_raw != null,
            .agent_id = cfg.agent_id,
            .version = lp.version,
            .active_job = lp.active_job,
            .active_started_epoch = lp.active_started_epoch,
            .proc = proc,
        };
    }

    sortJobsDesc(all_jobs.items);
    return .{
        .now_epoch = now_epoch,
        .repo = repo,
        .paused = paused,
        .heartbeat_known = hb_trim.len > 0,
        .heartbeat_online = hb_online,
        .lock_pid = lock_pid,
        .disk_free_bytes = disk_free,
        .workers = statuses,
        .recent_jobs = all_jobs.items[0..@min(all_jobs.items.len, 5)],
    };
}

fn parseProcJson(a: Allocator, raw: []const u8) ProcSample {
    const v = json.parseFromSliceLeaky(json.Value, a, std.mem.trim(u8, raw, " \t\r\n"), .{}) catch return .{};
    if (v != .object) return .{};
    return .{
        .pid = if (v.object.get("pid")) |p| (if (p == .integer and p.integer > 0) std.math.cast(u32, p.integer) else null) else null,
        .listener_alive = if (v.object.get("listener_alive")) |b| (b == .bool and b.bool) else false,
        .worker_alive = if (v.object.get("worker_alive")) |b| (b == .bool and b.bool) else false,
        .cpu_pct = if (v.object.get("cpu_pct")) |n| (if (n == .integer and n.integer >= 0) std.math.cast(u32, n.integer) orelse 0 else 0) else 0,
        .rss_bytes = if (v.object.get("rss_bytes")) |n| (if (n == .integer and n.integer >= 0) std.math.cast(u64, n.integer) orelse 0 else 0) else 0,
    };
}

fn collectHost(a: Allocator, io: std.Io, env: *const std.process.Environ.Map) Snapshot {
    const home = env.get("HOME") orelse "";
    const now_epoch: i64 = @intCast(std.Io.Clock.real.now(io).toSeconds());
    const hb_raw = readSmall(io, a, heartbeat_state_path) orelse "";
    const hb_trim = std.mem.trim(u8, hb_raw, " \t\r\n");
    const paused = std.mem.eql(u8, hb_trim, "offline");
    const lock_raw = readSmall(io, a, heavy_lock_pid_path) orelse "";
    const raw_lock_pid = std.fmt.parseInt(u32, std.mem.trim(u8, lock_raw, " \t\r\n"), 10) catch null;

    var statuses: [2]WorkerStatus = undefined;
    var all_jobs: std.ArrayList(CompletedJob) = .empty;
    var repo: []const u8 = "";

    for (workers, 0..) |spec, ix| {
        const w_dir = std.fmt.allocPrint(a, "{s}/.github-runners/{s}", .{ home, spec.dir_name }) catch "";
        const cfg_raw = if (w_dir.len > 0) readSmall(io, a, pathJoin(a, w_dir, ".runner")) else null;
        const cfg = if (cfg_raw) |raw| parseRunnerConfig(a, raw) else RunnerConfig{};
        const name = cfg.agent_name orelse spec.default_name;
        if (repo.len == 0) if (cfg.repo) |r| {
            repo = r;
        };
        const log_path = if (home.len > 0) pathJoin(a, home, spec.log_rel) else "";
        const log_raw = if (log_path.len > 0) (readTail(io, a, log_path, 256 * 1024) orelse "") else "";
        const lp = parseRunnerLog(a, name, log_raw);
        for (lp.completed) |job| all_jobs.append(a, job) catch {};

        statuses[ix] = .{
            .name = name,
            .configured = cfg_raw != null,
            .agent_id = cfg.agent_id,
            .version = lp.version,
            .active_job = lp.active_job,
            .active_started_epoch = lp.active_started_epoch,
        };
    }

    var lock_alive = false;
    const disk_free = if (comptime builtin.os.tag == .macos) blk: {
        probeMacProcs(a, io, home, &statuses, raw_lock_pid, &lock_alive);
        break :blk macDiskFree();
    } else null;

    const listeners_online = @as(usize, @intFromBool(statuses[0].proc.listener_alive)) +
        @intFromBool(statuses[1].proc.listener_alive);
    sortJobsDesc(all_jobs.items);

    return .{
        .now_epoch = now_epoch,
        .repo = if (repo.len > 0) repo else default_repo,
        .paused = paused or (listeners_online == 0 and std.mem.eql(u8, hb_trim, "offline")),
        .heartbeat_known = hb_trim.len > 0 or listeners_online > 0,
        .heartbeat_online = std.mem.eql(u8, hb_trim, "online") or (hb_trim.len == 0 and listeners_online > 0),
        .lock_pid = if (lock_alive) raw_lock_pid else null,
        .disk_free_bytes = disk_free,
        .workers = statuses,
        .recent_jobs = all_jobs.items[0..@min(all_jobs.items.len, 5)],
    };
}

fn macDiskFree() ?u64 {
    if (comptime builtin.os.tag != .macos) return null;
    var sv: mac.StatVfs = undefined;
    if (mac.statvfs("/", &sv) != 0) return null;
    const block_size: u64 = if (sv.f_frsize > 0) @intCast(sv.f_frsize) else @intCast(sv.f_bsize);
    return block_size * @as(u64, sv.f_bavail);
}

fn probeMacProcs(
    a: Allocator,
    io: std.Io,
    home: []const u8,
    statuses: *[2]WorkerStatus,
    raw_lock_pid: ?u32,
    lock_alive: *bool,
) void {
    if (comptime builtin.os.tag != .macos) return;
    if (home.len == 0) return;
    const bytes_need = mac.proc_listpids(mac.PROC_ALL_PIDS, 0, null, 0);
    if (bytes_need <= 0) return;
    const count_cap = @as(usize, @intCast(bytes_need)) / @sizeOf(c_int) + 32;
    const pids = a.alloc(c_int, count_cap) catch return;
    const bytes_got = mac.proc_listpids(mac.PROC_ALL_PIDS, 0, pids.ptr, @intCast(count_cap * @sizeOf(c_int)));
    if (bytes_got <= 0) return;
    const n_pids = @as(usize, @intCast(bytes_got)) / @sizeOf(c_int);

    const ProcMeta = struct { pid: u32, ppid: u32, slot: i8 };
    const metas = a.alloc(ProcMeta, n_pids) catch return;
    var meta_len: usize = 0;

    var p1_buf: [512]u8 = undefined;
    var p2_buf: [512]u8 = undefined;
    const prefix0 = std.fmt.bufPrint(&p1_buf, "{s}/.github-runners/{s}/", .{ home, workers[0].dir_name }) catch return;
    const prefix1 = std.fmt.bufPrint(&p2_buf, "{s}/.github-runners/{s}/", .{ home, workers[1].dir_name }) catch return;
    var path_buf: [mac.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;

    for (pids[0..n_pids]) |pid_c| {
        if (pid_c <= 0) continue;
        const pid_u: u32 = @intCast(pid_c);
        if (raw_lock_pid) |lp| if (pid_u == lp) {
            lock_alive.* = true;
        };
        var si: mac.ShortInfo = undefined;
        if (mac.proc_pidinfo(pid_c, mac.PROC_PIDTBSDSHORTINFO, 0, &si, @sizeOf(mac.ShortInfo)) != @sizeOf(mac.ShortInfo)) continue;
        const plen = mac.proc_pidpath(pid_c, &path_buf, path_buf.len);
        const path = if (plen > 0) path_buf[0..@intCast(plen)] else "";
        var slot: i8 = -1;
        if (std.mem.startsWith(u8, path, prefix0)) slot = 0 else if (std.mem.startsWith(u8, path, prefix1)) slot = 1;
        if (slot >= 0) {
            const idx: usize = @intCast(slot);
            if (std.mem.endsWith(u8, path, "/Runner.Listener") or statuses[idx].proc.pid == null) {
                statuses[idx].proc.pid = pid_u;
                statuses[idx].proc.listener_alive = true;
            }
            if (std.mem.endsWith(u8, path, "/Runner.Worker")) statuses[idx].proc.worker_alive = true;
        }
        metas[meta_len] = .{ .pid = pid_u, .ppid = si.ppid, .slot = slot };
        meta_len += 1;
    }

    var changed = true;
    var pass: usize = 0;
    while (changed and pass < 16) : (pass += 1) {
        changed = false;
        for (metas[0..meta_len]) |*m| {
            if (m.slot >= 0 or m.ppid <= 1) continue;
            for (metas[0..meta_len]) |parent| {
                if (parent.pid == m.ppid and parent.slot >= 0) {
                    m.slot = parent.slot;
                    changed = true;
                    break;
                }
            }
        }
    }

    const CpuSample = struct { pid: u32, slot: u8, cpu_ticks: u64 };
    var samples: std.ArrayList(CpuSample) = .empty;
    for (metas[0..meta_len]) |m| {
        if (m.slot < 0) continue;
        const idx: usize = @intCast(m.slot);
        var ru: mac.Rusage = undefined;
        if (mac.proc_pid_rusage(@intCast(m.pid), mac.RUSAGE_INFO_V2, &ru) == 0) {
            statuses[idx].proc.rss_bytes +|= ru.phys_footprint;
            samples.append(a, .{ .pid = m.pid, .slot = @intCast(idx), .cpu_ticks = ru.user_time +| ru.system_time }) catch {};
        }
    }

    const any_busy = statuses[0].proc.worker_alive or statuses[1].proc.worker_alive or
        statuses[0].active_job != null or statuses[1].active_job != null;
    if (!any_busy or samples.items.len == 0) return;

    const t0 = std.Io.Clock.awake.now(io).toNanoseconds();
    std.Io.sleep(io, .fromMilliseconds(80), .awake) catch return;
    const t1 = std.Io.Clock.awake.now(io).toNanoseconds();
    if (t1 <= t0) return;
    const dt_ns: u128 = @intCast(t1 - t0);

    var tb: mac.Timebase = .{ .numer = 1, .denom = 1 };
    _ = mac.mach_timebase_info(&tb);
    const numer: u128 = @max(tb.numer, 1);
    const denom: u128 = @max(tb.denom, 1);

    var delta_ticks = [2]u128{ 0, 0 };
    for (samples.items) |s| {
        var ru: mac.Rusage = undefined;
        if (mac.proc_pid_rusage(@intCast(s.pid), mac.RUSAGE_INFO_V2, &ru) == 0) {
            const now_ticks = ru.user_time +| ru.system_time;
            if (now_ticks > s.cpu_ticks) delta_ticks[s.slot] += now_ticks - s.cpu_ticks;
        }
    }
    for (0..2) |idx| {
        const cpu_ns = (delta_ticks[idx] * numer) / denom;
        statuses[idx].proc.cpu_pct = @intCast((cpu_ns * 100) / dt_ns);
    }
}

fn pathJoin(a: Allocator, dir: []const u8, file: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), file }) catch "";
}

fn sortJobsDesc(items: []CompletedJob) void {
    std.mem.sort(CompletedJob, items, {}, struct {
        fn less(_: void, lhs: CompletedJob, rhs: CompletedJob) bool {
            return lhs.epoch > rhs.epoch;
        }
    }.less);
}

pub const buildPanelJson = @import("github_runners_json.zig").buildPanelJson;

const testing = std.testing;

test "parseRunnerConfig strips UTF-8 BOM and extracts repo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw = "\xEF\xBB\xBF{\"agentId\":21,\"agentName\":\"worker-m3-1\",\"gitHubUrl\":\"https://github.com/acme/app\"}";
    const cfg = parseRunnerConfig(arena.allocator(), raw);
    try testing.expectEqualStrings("worker-m3-1", cfg.agent_name.?);
    try testing.expectEqual(@as(i64, 21), cfg.agent_id.?);
    try testing.expectEqualStrings("acme/app", cfg.repo.?);
}

test "parseRunnerLog extracts runner version, active job, and recent completions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const log =
        \\Current runner version: '2.338.2'
        \\2026-11-15 10:00:00Z: Running job: clippy
        \\2026-11-15 10:01:30Z: Job clippy completed with result: Succeeded
        \\2026-11-15 10:02:00Z: Running job: verify
    ;
    const lp = parseRunnerLog(arena.allocator(), "worker-m3-1", log);
    try testing.expectEqualStrings("2.338.2", lp.version.?);
    try testing.expectEqualStrings("verify", lp.active_job.?);
    try testing.expectEqual(parseUtcTimestamp("2026-11-15 10:02:00Z").?, lp.active_started_epoch.?);
    try testing.expectEqual(@as(usize, 1), lp.completed.len);
    try testing.expectEqualStrings("clippy", lp.completed[0].job);
    try testing.expectEqualStrings("Succeeded", lp.completed[0].result);
}

test "parseProcJson reads worker process metrics cleanly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const raw = "{\"pid\":28410,\"listener_alive\":true,\"worker_alive\":true,\"cpu_pct\":184,\"rss_bytes\":1503238554}";
    const sample = parseProcJson(arena.allocator(), raw);
    try testing.expectEqual(@as(?u32, 28410), sample.pid);
    try testing.expect(sample.listener_alive);
    try testing.expect(sample.worker_alive);
    try testing.expectEqual(@as(u32, 184), sample.cpu_pct);
    try testing.expectEqual(@as(u64, 1503238554), sample.rss_bytes);
}
