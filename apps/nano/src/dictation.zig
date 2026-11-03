//! Dictation through Codex's native voice, as the GPUI app's
//! (crates/harness/src/codex/dictation.rs and voice_host.rs): the device's
//! own Codex CLI and its packaged WebRTC voice helper capture the
//! microphone, and Codex's realtime session transcribes what the person
//! says. Only their own transcript is used; the realtime model is told to
//! stay silent, the helper never plays its audio.
//!
//! The session runs on a private, ephemeral `codex app-server` thread with
//! every tool off, a read-only sandbox and no project docs, in the temp
//! folder: it can transcribe, nothing else. It uses the Codex CLI's own
//! sign-in and spends that account's realtime allowance, as Codex's voice
//! mode does.
//!
//! The helper speaks big-endian length-prefixed JSON frames on its pipes;
//! the app-server, newline-delimited JSON-RPC. Both run on a thread of
//! their own; events reach the app through a `Sink`.
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const Allocator = std.mem.Allocator;
const posix = std.posix;

/// Why the helper can't be used (`VoiceHostError`).
pub const HostError = error{ Unavailable, RuntimeUnavailable, DeviceUnavailable, Protocol };

/// What a person reads when a session can't go on (`user_message`).
pub fn userMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.Unavailable => "Dictation needs the Codex CLI 0.159 or newer.",
        error.RuntimeUnavailable => "Codex's voice runtime would not start.",
        error.DeviceUnavailable => "The microphone could not be opened. Check that Harness may use it in System Settings.",
        else => "Codex's voice helper stopped responding.",
    };
}

/// Why the mic can't dictate on this device (`dictation_unavailable_message`).
pub fn unavailableMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.Unavailable => "Dictation uses Codex's voice: install the Codex CLI 0.159 or newer and sign in with `codex login`.",
        error.RuntimeUnavailable => "Codex's voice runtime would not start. Updating the Codex CLI may help.",
        error.DeviceUnavailable => "The microphone could not be opened. Check that Harness may use it in System Settings.",
        else => "Codex's voice helper stopped responding.",
    };
}

/// Told to both the realtime model and its backing thread.
pub const instructions = "You are a dictation service inside a text editor. " ++
    "The user is dictating text to type, and their words are transcribed separately. Never answer, " ++
    "comment, ask questions, call tools, hand off or take any action. Stay silent.";

/// How long finishing waits for words still in flight, and with none.
const finish_grace_ms = 2500;
const finish_idle_grace_ms = 600;
const level_interval_ms = 120;
/// The same utterance can come as both a canonical item and a legacy
/// transcript-done; a repeat this soon after is the same words.
const duplicate_window_ms = 3000;
const max_frame = 128 * 1024;
const helper_rel = "codex-resources/voice/bin/codex-voice-host";

// Finding the runtime.

pub const Runtime = struct { codex: []const u8, helper: []const u8 };

/// The device's Codex CLI with a voice helper, or why there's none.
pub fn detect(a: Allocator, io: std.Io, env: *const std.process.Environ.Map) HostError!Runtime {
    const codex = resolveCodex(a, io, env) orelse return error.Unavailable;
    return .{ .codex = codex, .helper = try helperFor(a, io, codex) };
}

/// `resolve_codex_executable`: `CODEX_EXECUTABLE`, else `codex` on PATH or
/// where its installers put it.
pub fn resolveCodex(a: Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("CODEX_EXECUTABLE")) |p| if (p.len > 0) return if (executable(io, p)) a.dupe(u8, p) catch null else null;
    if (env.get("PATH")) |path| {
        var it = std.mem.tokenizeScalar(u8, path, ':');
        while (it.next()) |dir| {
            const p = std.fs.path.join(a, &.{ dir, "codex" }) catch continue;
            if (executable(io, p)) return p;
        }
    }
    const home = env.get("HOME") orelse "";
    const extra = [_][]const u8{ ".local/bin/codex", ".codex/bin/codex", ".npm-global/bin/codex" };
    for (extra) |rel| {
        if (home.len == 0) break;
        const p = std.fs.path.join(a, &.{ home, rel }) catch continue;
        if (executable(io, p)) return p;
    }
    for ([_][]const u8{ "/opt/homebrew/bin/codex", "/usr/local/bin/codex" }) |p| if (executable(io, p)) return a.dupe(u8, p) catch null;
    return null;
}

fn executable(io: std.Io, p: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind != .directory and (@intFromEnum(st.permissions) & 0o111) != 0;
}

fn realPath(a: Allocator, io: std.Io, p: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, p, a) catch null;
}

/// `helper_for`: the voice helper inside the Codex installation behind
/// `codex` (a standalone install, or npm's shim with its platform package).
pub fn helperFor(a: Allocator, io: std.Io, codex: []const u8) HostError![]const u8 {
    const exe = realPath(a, io, codex) orelse return error.Unavailable;
    const root = std.fs.path.dirname(std.fs.path.dirname(exe) orelse return error.Unavailable) orelse return error.Unavailable;
    var found: HostError = error.Unavailable;
    if (helperIn(a, io, root)) |p| return p else |e| if (e != error.Unavailable) {
        found = e;
    }
    // npm: <package>/bin/codex.js → <package>/node_modules/@openai/codex-*/vendor/<target>
    const target = runtimeTarget() orelse return found;
    const scoped = std.fs.path.join(a, &.{ root, "node_modules", "@openai" }) catch return found;
    var dir = std.Io.Dir.cwd().openDir(io, scoped, .{ .iterate = true }) catch return found;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, "codex-")) continue;
        const vendor = std.fs.path.join(a, &.{ scoped, e.name, "vendor", target }) catch continue;
        if (helperIn(a, io, vendor)) |p| return p else |err| if (err != error.Unavailable) {
            found = err;
        }
    }
    return found;
}

fn helperIn(a: Allocator, io: std.Io, root: []const u8) HostError![]const u8 {
    const pkg_path = std.fs.path.join(a, &.{ root, "codex-package.json" }) catch return error.Unavailable;
    const text = std.Io.Dir.cwd().readFileAlloc(io, pkg_path, a, .limited(1 << 20)) catch return error.Unavailable;
    const pkg = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch return error.Unavailable;
    if (pkg != .object) return error.Unavailable;
    const layout = pkg.object.get("layoutVersion") orelse return error.Unavailable;
    if (layout != .integer or layout.integer != 1) return error.Unavailable;
    const v = pkg.object.get("version") orelse return error.Unavailable;
    if (v != .string) return error.Unavailable;
    const version = Version.parse(v.string) orelse return error.Unavailable;
    if (version.lessThan(.{ .major = 0, .minor = 159, .patch = 0 })) return error.Unavailable;
    const path = std.fs.path.join(a, &.{ root, helper_rel }) catch return error.Unavailable;
    // The runtime only starts from its real codex-resources/voice folder:
    // a symlinked helper is as good as missing.
    const real = realPath(a, io, path) orelse return error.Unavailable;
    if (!std.mem.eql(u8, real, path)) return error.Unavailable;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.Unavailable;
    if (st.kind != .file) return error.Unavailable;
    return path;
}

fn runtimeTarget() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "aarch64-apple-darwin",
            .x86_64 => "x86_64-apple-darwin",
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "x86_64-unknown-linux-musl",
            .aarch64 => "aarch64-unknown-linux-musl",
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "x86_64-pc-windows-msvc",
            .aarch64 => "aarch64-pc-windows-msvc",
            else => null,
        },
        else => null,
    };
}

/// A semver, as far as ordering against a release needs: a pre-release
/// sorts before its release.
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    pre: bool = false,

    pub fn parse(s: []const u8) ?Version {
        const core_end = std.mem.indexOfAny(u8, s, "-+") orelse s.len;
        var it = std.mem.splitScalar(u8, s[0..core_end], '.');
        const major = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        const minor = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        const patch = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
        if (it.next() != null) return null;
        return .{ .major = major, .minor = minor, .patch = patch, .pre = core_end < s.len and s[core_end] == '-' };
    }

    pub fn lessThan(v: Version, w: Version) bool {
        if (v.major != w.major) return v.major < w.major;
        if (v.minor != w.minor) return v.minor < w.minor;
        if (v.patch != w.patch) return v.patch < w.patch;
        return v.pre and !w.pre;
    }
};

/// Codex 0.161 changed `openDevices`; the helper's version is in the voice
/// manifest beside it (none: the original form).
fn deviceSelection(a: Allocator, io: std.Io, helper: []const u8) HostError!bool {
    const voice = std.fs.path.dirname(std.fs.path.dirname(helper) orelse return error.Unavailable) orelse return error.Unavailable;
    const path = std.fs.path.join(a, &.{ voice, "manifest.json" }) catch return error.RuntimeUnavailable;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |e| return if (e == error.FileNotFound) false else error.RuntimeUnavailable;
    const m = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch return error.RuntimeUnavailable;
    if (m != .object) return error.RuntimeUnavailable;
    const v = m.object.get("appVersion") orelse return error.RuntimeUnavailable;
    if (v != .string) return error.RuntimeUnavailable;
    const version = Version.parse(v.string) orelse return error.RuntimeUnavailable;
    return !version.lessThan(.{ .major = 0, .minor = 161, .patch = 0 });
}

// The wire.

/// One realtime notification, as dictation cares about it (`Wire`).
pub const Wire = union(enum) {
    started,
    answer: []const u8,
    user_delta: []const u8,
    user_segment: []const u8,
    err: []const u8,
    closed: ?[]const u8,
    other,
};

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `classify`: only the person's own words on this thread count.
pub fn classify(thread: []const u8, method: []const u8, params: json.Value) Wire {
    if (params != .object) return .other;
    const p = params.object;
    const t = str(p, "threadId") orelse return .other;
    if (!std.mem.eql(u8, t, thread)) return .other;
    const user = if (str(p, "role")) |r| std.mem.eql(u8, r, "user") else false;
    const eq = std.mem.eql;
    if (eq(u8, method, "thread/realtime/started")) return .started;
    if (eq(u8, method, "thread/realtime/sdp")) return if (str(p, "sdp")) |s| .{ .answer = s } else .other;
    if (eq(u8, method, "thread/realtime/transcript/delta") and user) return if (str(p, "delta")) |s| .{ .user_delta = s } else .other;
    if (eq(u8, method, "thread/realtime/transcript/done") and user) return if (str(p, "text")) |s| .{ .user_segment = s } else .other;
    if (eq(u8, method, "thread/realtime/item/completed")) {
        const item = p.get("item") orelse return .other;
        if (item != .object) return .other;
        const ty = str(item.object, "type") orelse return .other;
        const role = str(item.object, "role") orelse return .other;
        if (!eq(u8, ty, "transcriptSegment") or !eq(u8, role, "user")) return .other;
        return if (str(item.object, "text")) |s| .{ .user_segment = s } else .other;
    }
    if (eq(u8, method, "thread/realtime/error")) return .{ .err = str(p, "message") orelse "" };
    if (eq(u8, method, "thread/realtime/closed")) return .{ .closed = str(p, "reason") };
    return .other;
}

/// The locked-down thread (`thread_params`).
pub fn threadParams(a: Allocator, cwd: []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(a, .{
        .cwd = cwd,
        .ephemeral = true,
        .approvalPolicy = "never",
        .sandbox = "read-only",
        .baseInstructions = instructions,
        .developerInstructions = instructions,
        .config = .{
            .project_doc_max_bytes = 0,
            .web_search = "disabled",
            .@"features.shell_tool" = false,
            .@"features.apply_patch_freeform" = false,
            .@"features.multi_agent" = false,
            .@"features.multi_agent_v2" = false,
            .@"features.apps" = false,
            .@"agents.enabled" = false,
            .@"features.browser_use" = false,
            .@"features.computer_use" = false,
            .@"features.js_repl" = false,
            .@"features.image_generation" = false,
            .@"features.memories" = false,
        },
    }, .{});
}

/// A v3 WebRTC call asking for audio (the only WebRTC versions), whose
/// speaker the helper keeps suppressed (`realtime_params`).
pub fn realtimeParams(a: Allocator, thread: []const u8, offer: []const u8, realtime_session: []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(a, .{
        .threadId = thread,
        .transport = .{ .type = "webrtc", .sdp = offer },
        .version = "v3",
        .outputModality = "audio",
        .realtimeSessionId = realtime_session,
        .clientManagedHandoffs = false,
        .includeStartupContext = false,
        .realtimeStartInstructions = instructions,
        .initialItems = .{.{ .role = "developer", .text = instructions }},
    }, .{});
}

// Pipes, with deadlines.

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

/// Waits until `fd` can be read, or `deadline` (ms, awake clock) passes.
fn readable(io: std.Io, fd: posix.fd_t, deadline: i64) !bool {
    const left = deadline - nowMs(io);
    if (left <= 0) return false;
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    return (try posix.poll(&fds, @intCast(@min(left, std.math.maxInt(i32))))) > 0;
}

fn readSome(fd: posix.fd_t, buf: []u8) !usize {
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// The voice helper's end of the pipe (`VoiceHost`): one request, one
/// reply; any failure leaves it unusable.
pub const Host = struct {
    io: std.Io,
    in: posix.fd_t,
    out: posix.fd_t,
    device_selection: bool,
    broken: bool = false,

    pub fn exchange(h: *Host, a: Allocator, message: []const u8, seconds: i64) HostError!json.Value {
        if (h.broken) return error.Protocol;
        errdefer h.broken = true;
        if (message.len > max_frame) return error.Protocol;
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(message.len), .big);
        writeAll(h.in, &len) catch return error.Protocol;
        writeAll(h.in, message) catch return error.Protocol;
        const deadline = nowMs(h.io) + seconds * 1000;
        try h.readExact(&len, deadline);
        const n = std.mem.readInt(u32, &len, .big);
        if (n == 0 or n > max_frame) return error.Protocol;
        const payload = a.alloc(u8, n) catch return error.Protocol;
        try h.readExact(payload, deadline);
        return json.parseFromSliceLeaky(json.Value, a, payload, .{}) catch error.Protocol;
    }

    fn readExact(h: *Host, buf: []u8, deadline: i64) HostError!void {
        var got: usize = 0;
        while (got < buf.len) {
            if (!(readable(h.io, h.out, deadline) catch return error.Protocol)) return error.Protocol;
            const n = readSome(h.out, buf[got..]) catch return error.Protocol;
            if (n == 0) return error.Protocol;
            got += n;
        }
    }

    pub fn expect(h: *Host, a: Allocator, message: []const u8, reply: []const u8, seconds: i64) HostError!void {
        const r = try h.exchange(a, message, seconds);
        const ty = if (r == .object) str(r.object, "type") orelse "" else "";
        if (!std.mem.eql(u8, ty, reply)) {
            h.broken = true;
            return error.Protocol;
        }
    }

    /// Hello, then the media runtime: a helper that can't start it exits
    /// here, which is the runtime's failing, not the session's.
    pub fn handshake(h: *Host, a: Allocator, commit: []const u8) HostError!void {
        const hello = json.Stringify.valueAlloc(a, .{ .type = "hello", .protocol = 1, .buildCommit = commit }, .{}) catch return error.Protocol;
        h.expect(a, hello, "ready", 30) catch return error.RuntimeUnavailable;
        h.expect(a, "{\"type\":\"initializeRuntime\"}", "runtimeReady", 30) catch return error.RuntimeUnavailable;
    }

    /// The WebRTC offer for the realtime session.
    pub fn offer(h: *Host, a: Allocator) HostError![]const u8 {
        const r = try h.exchange(a, "{\"type\":\"startTransport\"}", 20);
        if (r != .object or !std.mem.eql(u8, str(r.object, "type") orelse "", "offer")) return error.Protocol;
        const sdp = str(r.object, "sdp") orelse return error.Protocol;
        if (sdp.len == 0 or sdp.len > 64 * 1024) return error.Protocol;
        return sdp;
    }

    pub fn applyAnswer(h: *Host, a: Allocator, sdp: []const u8) HostError!void {
        const m = json.Stringify.valueAlloc(a, .{ .type = "applyAnswer", .sdp = sdp }, .{}) catch return error.Protocol;
        return h.expect(a, m, "transportReady", 20);
    }

    /// The default microphone and speaker; Codex 0.161 wants `selection`
    /// even for them, older helpers refuse it.
    pub fn openDevices(h: *Host, a: Allocator) HostError!void {
        const m = if (h.device_selection) "{\"type\":\"openDevices\",\"selection\":{}}" else "{\"type\":\"openDevices\"}";
        h.expect(a, m, "devicesOpened", 5) catch return error.DeviceUnavailable;
    }

    /// The speaker stays suppressed: dictation never plays the model.
    pub fn setMuted(h: *Host, a: Allocator, muted: bool) HostError!void {
        const m = json.Stringify.valueAlloc(a, .{ .type = "setAudioControls", .controls = .{ .microphoneMuted = muted, .speakerSuppressed = true } }, .{}) catch return error.Protocol;
        return h.expect(a, m, "audioControlsApplied", 5);
    }

    /// The microphone's peak, 0 to 65535.
    pub fn microphoneLevel(h: *Host, a: Allocator) HostError!u16 {
        const r = try h.exchange(a, "{\"type\":\"inspectAudio\"}", 5);
        if (r != .object or !std.mem.eql(u8, str(r.object, "type") orelse "", "audioState")) return error.Protocol;
        const st = r.object.get("state") orelse return error.Protocol;
        if (st != .object) return error.Protocol;
        const peak = st.object.get("microphonePeak") orelse return error.Protocol;
        if (peak != .integer or peak.integer < 0 or peak.integer > std.math.maxInt(u16)) return error.Protocol;
        return @intCast(peak.integer);
    }

    pub fn close(h: *Host, a: Allocator) void {
        _ = h.exchange(a, "{\"type\":\"close\"}", 2) catch {};
    }
};

/// Codex's app-server: newline-delimited JSON-RPC. What comes while a
/// request waits for its answer is kept for later.
pub const Rpc = struct {
    a: Allocator,
    io: std.Io,
    in: posix.fd_t,
    out: posix.fd_t,
    buf: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,
    held: std.ArrayList(json.Value) = .empty,
    held_at: usize = 0,
    eof: bool = false,

    fn send(r: *Rpc, line: []const u8) !void {
        try writeAll(r.in, line);
        try writeAll(r.in, "\n");
    }

    pub fn notify(r: *Rpc, method: []const u8) void {
        const line = json.Stringify.valueAlloc(r.a, .{ .jsonrpc = "2.0", .method = method }, .{}) catch return;
        r.send(line) catch {};
    }

    /// The answer's `result`; `error.Rpc` with `last_error` set when it's an
    /// error, `error.Timeout` past `timeout_ms`, `error.Eof` when it stops.
    pub fn request(r: *Rpc, method: []const u8, params_json: []const u8, timeout_ms: i64) !json.Value {
        const id = r.next_id;
        r.next_id += 1;
        const line = try std.fmt.allocPrint(r.a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
        try r.send(line);
        const deadline = nowMs(r.io) + timeout_ms;
        while (true) {
            const msg = (try r.readMessage(deadline)) orelse return error.Timeout;
            if (msg == .object) if (msg.object.get("id")) |mid| if (msg.object.get("method") == null and mid == .integer and mid.integer == id) {
                if (msg.object.get("error")) |e| {
                    last_rpc_error = if (e == .object) str(e.object, "message") orelse "error" else "error";
                    return error.Rpc;
                }
                return msg.object.get("result") orelse .null;
            };
            try r.held.append(r.a, msg);
        }
    }


    /// The next notification or request (held ones first), or null past
    /// `deadline`.
    pub fn next(r: *Rpc, deadline: i64) !?json.Value {
        if (r.held_at < r.held.items.len) {
            r.held_at += 1;
            return r.held.items[r.held_at - 1];
        }
        return r.readMessage(deadline);
    }

    fn readMessage(r: *Rpc, deadline: i64) !?json.Value {
        while (true) {
            if (std.mem.indexOfScalar(u8, r.buf.items, '\n')) |nl| {
                const line = try r.a.dupe(u8, r.buf.items[0..nl]);
                r.buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
                if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
                return json.parseFromSliceLeaky(json.Value, r.a, line, .{}) catch continue;
            }
            if (r.eof) return error.Eof;
            if (!try readable(r.io, r.out, deadline)) return null;
            var chunk: [16 * 1024]u8 = undefined;
            const n = try readSome(r.out, &chunk);
            if (n == 0) {
                r.eof = true;
                continue;
            }
            try r.buf.appendSlice(r.a, chunk[0..n]);
        }
    }

    pub fn respondError(r: *Rpc, id: json.Value, code: i64, message: []const u8) void {
        const line = json.Stringify.valueAlloc(r.a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{}) catch return;
        r.send(line) catch {};
    }
};

// The session.

/// What the session says, as `DictationEvent`. Strings last only for the
/// call: the sink copies what it keeps.
pub const Event = union(enum) {
    listening,
    level: f32,
    partial: []const u8,
    segment: []const u8,
    failed: []const u8,
    ended,
};

pub const Sink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, e: Event) void,

    fn send(s: Sink, e: Event) void {
        s.func(s.ctx, e);
    }
};

/// Finishing (stop listening, keep the last words) and cancelling (now),
/// from any thread.
pub const Controls = struct {
    finish: std.atomic.Value(bool) = .init(false),
    abort: std.atomic.Value(bool) = .init(false),

    fn finishing(c: *Controls) bool {
        return c.finish.load(.acquire);
    }
    fn aborted(c: *Controls) bool {
        return c.abort.load(.acquire);
    }
};

/// How the helper is reached: in the app a process, in a test a pipe.
pub const Opener = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, a: Allocator, io: std.Io) HostError!Host,
};

const Stop = error{Stopped};

/// `session`: set up, listen, then deliver the words, until finished,
/// cancelled or failed. A failure's words are returned.
pub fn session(a: Allocator, io: std.Io, rpc: *Rpc, opener: Opener, controls: *Controls, sink: Sink, session_id: []const u8, tmp: []const u8) ?[]const u8 {
    var host_opt: ?Host = null;
    const thread = setup(a, io, rpc, opener, controls, session_id, tmp, &host_opt) catch |e| {
        if (host_opt) |*h| h.close(a);
        return switch (e) {
            // Stopped before the mic opened: nothing was said yet.
            error.Stopped => null,
            error.Failed => last_failure,
        };
    };
    var host = host_opt.?;
    sink.send(.listening);
    var partial: std.ArrayList(u8) = .empty;
    var last: ?struct { text: []const u8, at: i64 } = null;
    var deadline: ?i64 = null;
    var next_level = nowMs(io);
    var scratch: std.heap.ArenaAllocator = .init(a);
    defer scratch.deinit();
    const outcome: ?[]const u8 = loop: while (true) {
        _ = scratch.reset(.retain_capacity);
        const sa = scratch.allocator();
        if (controls.aborted()) break :loop null;
        const now = nowMs(io);
        if (deadline == null and controls.finishing()) {
            host.setMuted(sa, true) catch {};
            sink.send(.{ .level = 0 });
            const idle = std.mem.trim(u8, partial.items, " \t\r\n").len == 0;
            deadline = now + @as(i64, if (idle) finish_idle_grace_ms else finish_grace_ms);
        }
        if (deadline) |d| if (now >= d) {
            // Words heard but never finalized still belong to the person.
            const words = std.mem.trim(u8, partial.items, " \t\r\n");
            if (words.len > 0) sink.send(.{ .segment = words });
            break :loop null;
        };
        if (deadline == null and now >= next_level) {
            const peak = host.microphoneLevel(sa) catch |e| break :loop userMessage(e);
            sink.send(.{ .level = @as(f32, @floatFromInt(peak)) / 65535.0 });
            // Missed ticks are skipped.
            while (next_level <= now) next_level += level_interval_ms;
        }
        // Wait for the next message, the next level, the deadline, or 50 ms
        // to look at the controls again.
        var wake = now + 50;
        if (deadline) |d| wake = @min(wake, d) else wake = @min(wake, next_level);
        const msg = (rpc.next(@max(wake, now + 1)) catch break :loop "Codex stopped.") orelse continue;
        if (msg != .object) continue;
        const method = str(msg.object, "method") orelse continue;
        if (msg.object.get("id")) |id| {
            rpc.respondError(id, -32601, "not supported during dictation");
            continue;
        }
        switch (classify(thread, method, msg.object.get("params") orelse .null)) {
            .user_delta => |delta| {
                partial.appendSlice(a, delta) catch {};
                sink.send(.{ .partial = std.mem.trim(u8, partial.items, " \t\r\n") });
            },
            .user_segment => |raw| {
                const text = std.mem.trim(u8, raw, " \t\r\n");
                partial.clearRetainingCapacity();
                const repeat = if (last) |l| std.mem.eql(u8, l.text, text) and nowMs(io) - l.at < duplicate_window_ms else false;
                if (text.len > 0 and !repeat) {
                    last = .{ .text = a.dupe(u8, text) catch text, .at = nowMs(io) };
                    sink.send(.{ .segment = text });
                }
                // Finishing, and everything said is in: done.
                if (deadline != null) break :loop null;
            },
            .err => |m| break :loop std.fmt.allocPrint(a, "Codex: {s}", .{m}) catch "Codex failed.",
            .closed => |reason| {
                if (deadline != null) break :loop null;
                break :loop if (reason) |r| std.fmt.allocPrint(a, "Codex ended the voice session: {s}", .{r}) catch "Codex ended the voice session." else "Codex ended the voice session.";
            },
            else => {},
        }
    };
    const stop = std.fmt.allocPrint(a, "{{\"threadId\":\"{s}\"}}", .{thread}) catch "";
    _ = rpc.request("thread/realtime/stop", stop, 2000) catch {};
    host.close(a);
    return outcome;
}

threadlocal var last_failure: []const u8 = "";
/// The last error answer's message, for the failure that names it.
threadlocal var last_rpc_error: []const u8 = "";

fn fail(comptime fmt: []const u8, args: anytype, a: Allocator) error{Failed} {
    last_failure = std.fmt.allocPrint(a, fmt, args) catch "Dictation failed.";
    return error.Failed;
}

fn failWith(msg: []const u8) error{Failed} {
    last_failure = msg;
    return error.Failed;
}

fn codexError(a: Allocator, e: anyerror) error{Failed} {
    return switch (e) {
        error.Rpc => fail("Codex couldn't start dictation: {s}", .{last_rpc_error}, a),
        error.Eof => failWith("Codex stopped."),
        error.Timeout => failWith("Codex took too long to start dictation."),
        else => fail("Codex couldn't start dictation: {t}", .{e}, a),
    };
}

fn checkStop(controls: *Controls) Stop!void {
    if (controls.aborted() or controls.finishing()) return error.Stopped;
}

fn setup(a: Allocator, io: std.Io, rpc: *Rpc, opener: Opener, controls: *Controls, session_id: []const u8, tmp: []const u8, host_out: *?Host) (Stop || error{Failed})![]const u8 {
    const init_params = "{\"clientInfo\":{\"name\":\"harness-dictation\",\"title\":\"Harness\",\"version\":\"0.0.0\"},\"capabilities\":{\"experimentalApi\":true}}";
    _ = rpc.request("initialize", init_params, 30_000) catch |e| return codexError(a, e);
    rpc.notify("initialized");
    try checkStop(controls);
    const tparams = threadParams(a, std.mem.trimEnd(u8, tmp, "/")) catch return failWith("Dictation failed.");
    const started = rpc.request("thread/start", tparams, 30_000) catch |e| return codexError(a, e);
    const thread = blk: {
        if (started == .object) if (started.object.get("thread")) |t| if (t == .object) if (str(t.object, "id")) |id| if (id.len > 0) break :blk id;
        return failWith("Codex started no thread for dictation.");
    };
    try checkStop(controls);
    host_out.* = opener.func(opener.ctx, a, io) catch |e| return failWith(userMessage(e));
    const host = &host_out.*.?;
    const offer = host.offer(a) catch |e| return failWith(userMessage(e));
    try checkStop(controls);
    const rparams = realtimeParams(a, thread, offer, session_id) catch return failWith("Dictation failed.");
    _ = rpc.request("thread/realtime/start", rparams, 30_000) catch |e| return codexError(a, e);
    // The answer comes as a notification once the call is accepted.
    const until = nowMs(io) + 30_000;
    const answer = while (true) {
        try checkStop(controls);
        if (nowMs(io) >= until) return failWith("Codex took too long to start dictation.");
        const msg = (rpc.next(@min(until, nowMs(io) + 50)) catch return failWith("Codex stopped.")) orelse continue;
        if (msg != .object) continue;
        const method = str(msg.object, "method") orelse continue;
        if (msg.object.get("id")) |id| {
            rpc.respondError(id, -32601, "not supported during dictation");
            continue;
        }
        switch (classify(thread, method, msg.object.get("params") orelse .null)) {
            .answer => |sdp| break sdp,
            .err => |m| return fail("Codex: {s}", .{m}, a),
            .closed => return failWith("Codex closed the voice session."),
            else => {},
        }
    };
    host.applyAnswer(a, answer) catch |e| return failWith(userMessage(e));
    host.openDevices(a) catch |e| return failWith(userMessage(e));
    host.setMuted(a, false) catch |e| return failWith(userMessage(e));
    try checkStop(controls);
    return thread;
}

// The app's session: processes, a thread, events to the main thread.

/// A running dictation: `finish` or `cancel` it; it ends on its own after.
pub const Running = struct {
    gpa: Allocator,
    io: std.Io,
    runtime: Runtime,
    env: *const std.process.Environ.Map,
    controls: Controls = .{},
    sink: Sink,
    thread: ?std.Thread = null,

    pub fn start(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map, runtime: Runtime, sink: Sink) !*Running {
        const r = try gpa.create(Running);
        errdefer gpa.destroy(r);
        r.* = .{ .gpa = gpa, .io = io, .env = env, .sink = sink, .runtime = .{
            .codex = try gpa.dupe(u8, runtime.codex),
            .helper = try gpa.dupe(u8, runtime.helper),
        } };
        r.thread = try std.Thread.spawn(.{}, work, .{r});
        return r;
    }

    pub fn finish(r: *Running) void {
        r.controls.finish.store(true, .release);
    }

    pub fn cancel(r: *Running) void {
        r.controls.abort.store(true, .release);
    }

    /// After its `ended`: the thread joined, the session freed.
    pub fn destroy(r: *Running) void {
        if (r.thread) |t| t.join();
        r.gpa.free(r.runtime.codex);
        r.gpa.free(r.runtime.helper);
        r.gpa.destroy(r);
    }

    fn work(r: *Running) void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        if (r.run(arena.allocator())) |message| r.sink.send(.{ .failed = message });
        r.sink.send(.ended);
    }

    fn run(r: *Running, a: Allocator) ?[]const u8 {
        // Codex's own folder first on its PATH (`compose_child_path`).
        var env = r.env.clone(a) catch return "Codex could not start.";
        const dir = std.fs.path.dirname(r.runtime.codex) orelse ".";
        const path = std.fmt.allocPrint(a, "{s}:{s}", .{ dir, r.env.get("PATH") orelse "/usr/bin:/bin" }) catch return "Codex could not start.";
        env.put("PATH", path) catch {};
        var child = std.process.spawn(r.io, .{
            .argv = &.{ r.runtime.codex, "app-server" },
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |e| return std.fmt.allocPrint(a, "Codex could not start: {t}", .{e}) catch "Codex could not start.";
        defer shutdown(r.io, &child);
        var rpc: Rpc = .{ .a = a, .io = r.io, .in = child.stdin.?.handle, .out = child.stdout.?.handle };
        var uuid: [36]u8 = undefined;
        sessionId(r.io, &uuid);
        var helper: HelperProcess = .{ .r = r };
        defer helper.stop();
        return session(a, r.io, &rpc, .{ .ctx = &helper, .func = HelperProcess.open }, &r.controls, r.sink, &uuid, r.env.get("TMPDIR") orelse "/tmp");
    }
};

/// Close its input, give it a second, then kill it (`shutdown_child`).
fn shutdown(io: std.Io, child: *std.process.Child) void {
    if (child.stdin) |f| {
        f.close(io);
        child.stdin = null;
    }
    child.kill(io);
}

fn sessionId(io: std.Io, out: *[36]u8) void {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(b, .lower);
    _ = std.fmt.bufPrint(out, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch {};
}

/// The helper as a process: its environment an allowlist, as Codex runs it.
const HelperProcess = struct {
    r: *Running,
    child: ?std.process.Child = null,

    fn open(ctx: ?*anyopaque, a: Allocator, io: std.Io) HostError!Host {
        const self: *HelperProcess = @ptrCast(@alignCast(ctx.?));
        const path = self.r.runtime.helper;
        const selection = try deviceSelection(a, io, path);
        var env = std.process.Environ.Map.init(a);
        const allow = [_][]const u8{ "SYSTEMROOT", "WINDIR", "HOME", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "TEMP", "TMP", "TMPDIR", "XDG_RUNTIME_DIR", "PULSE_SERVER", "PULSE_COOKIE", "PIPEWIRE_REMOTE", "DBUS_SESSION_BUS_ADDRESS", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE" };
        for (allow) |k| if (self.r.env.get(k)) |v| env.put(k, v) catch {};
        // Its runtime starts only with exactly this GStreamer environment.
        for ([_][]const u8{ "GST_PLUGIN_PATH", "GST_PLUGIN_PATH_1_0", "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_SYSTEM_PATH_1_0" }) |k| env.put(k, "") catch {};
        env.put("GST_REGISTRY", "/dev/null") catch {};
        env.put("GST_REGISTRY_UPDATE", "no") catch {};
        env.put("GST_REGISTRY_FORK", "no") catch {};
        const dir = std.fs.path.dirname(path) orelse ".";
        // Its build commit, which the hello must name.
        const commit = blk: {
            var probe = std.process.spawn(io, .{ .argv = &.{ path, "--build-commit" }, .environ_map = &env, .cwd = .{ .path = dir }, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return error.RuntimeUnavailable;
            defer probe.kill(io);
            var buf: [256]u8 = undefined;
            var got: usize = 0;
            const deadline = nowMs(io) + 5000;
            while (got < buf.len) {
                if (!(readable(io, probe.stdout.?.handle, deadline) catch false)) break;
                const n = readSome(probe.stdout.?.handle, buf[got..]) catch break;
                if (n == 0) break;
                got += n;
            }
            const c = std.mem.trim(u8, buf[0..got], " \t\r\n");
            if (c.len == 0 or c.len > 128) return error.RuntimeUnavailable;
            break :blk a.dupe(u8, c) catch return error.RuntimeUnavailable;
        };
        self.child = std.process.spawn(io, .{ .argv = &.{path}, .environ_map = &env, .cwd = .{ .path = dir }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore }) catch return error.RuntimeUnavailable;
        var host: Host = .{ .io = io, .in = self.child.?.stdin.?.handle, .out = self.child.?.stdout.?.handle, .device_selection = selection };
        try host.handshake(a, commit);
        return host;
    }

    fn stop(self: *HelperProcess) void {
        if (self.child) |*c| c.kill(self.r.io);
        self.child = null;
    }
};

/// Inserts dictated words at `at` in `text`, spaced from the words around
/// them (`insert_dictation`): what goes in.
pub fn spaced(a: Allocator, text: []const u8, at: usize, words_in: []const u8) ![]const u8 {
    const words = std.mem.trim(u8, words_in, " \t\r\n");
    if (words.len == 0) return "";
    const before = at > 0 and !std.ascii.isWhitespace(text[at - 1]);
    const after = at < text.len and !std.ascii.isWhitespace(text[at]);
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (before) " " else "", words, if (after) " " else "" });
}

const testing = std.testing;

test "only the person's words on this thread count" {
    const a = testing.allocator;
    const parse = struct {
        fn f(al: Allocator, s: []const u8) !json.Parsed(json.Value) {
            return json.parseFromSlice(json.Value, al, s, .{});
        }
    };
    const cases = [_]struct { []const u8, []const u8, Wire }{
        .{ "thread/realtime/transcript/delta", "{\"threadId\":\"thr\",\"role\":\"user\",\"delta\":\"hel\"}", .{ .user_delta = "hel" } },
        .{ "thread/realtime/transcript/delta", "{\"threadId\":\"thr\",\"role\":\"assistant\",\"delta\":\"Sure\"}", .other },
        .{ "thread/realtime/item/completed", "{\"threadId\":\"thr\",\"item\":{\"type\":\"transcriptSegment\",\"role\":\"user\",\"text\":\"hello there\"}}", .{ .user_segment = "hello there" } },
        .{ "thread/realtime/item/completed", "{\"threadId\":\"thr\",\"item\":{\"type\":\"transcriptSegment\",\"role\":\"assistant\",\"text\":\"Hi!\"}}", .other },
        .{ "thread/realtime/transcript/delta", "{\"threadId\":\"other\",\"role\":\"user\",\"delta\":\"x\"}", .other },
        .{ "thread/realtime/sdp", "{\"threadId\":\"thr\",\"sdp\":\"answer\"}", .{ .answer = "answer" } },
        .{ "thread/realtime/closed", "{\"threadId\":\"thr\",\"reason\":null}", .{ .closed = null } },
    };
    for (cases) |c| {
        const p = try parse.f(a, c[1]);
        defer p.deinit();
        try testing.expectEqualDeep(c[2], classify("thr", c[0], p.value));
    }
}

test "the session is a v3 WebRTC call with no context and no tools" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try json.parseFromSliceLeaky(json.Value, a, try realtimeParams(a, "thr", "offer", "sess"), .{});
    try testing.expectEqualStrings("v3", p.object.get("version").?.string);
    try testing.expectEqualStrings("audio", p.object.get("outputModality").?.string);
    try testing.expectEqual(false, p.object.get("includeStartupContext").?.bool);
    try testing.expectEqualStrings("webrtc", p.object.get("transport").?.object.get("type").?.string);
    try testing.expectEqualStrings("offer", p.object.get("transport").?.object.get("sdp").?.string);
    const t = try json.parseFromSliceLeaky(json.Value, a, try threadParams(a, "/tmp"), .{});
    try testing.expectEqual(true, t.object.get("ephemeral").?.bool);
    try testing.expectEqualStrings("read-only", t.object.get("sandbox").?.string);
    try testing.expectEqualStrings("never", t.object.get("approvalPolicy").?.string);
    try testing.expectEqual(false, t.object.get("config").?.object.get("features.shell_tool").?.bool);
    try testing.expectEqual(@as(i64, 0), t.object.get("config").?.object.get("project_doc_max_bytes").?.integer);
}

test "versions order as semver: a pre-release before its release" {
    const v = Version.parse("0.159.2").?;
    try testing.expect(!v.lessThan(.{ .major = 0, .minor = 159, .patch = 0 }));
    try testing.expect(Version.parse("0.158.9").?.lessThan(.{ .major = 0, .minor = 159, .patch = 0 }));
    try testing.expect(Version.parse("0.159.0-alpha.1").?.lessThan(.{ .major = 0, .minor = 159, .patch = 0 }));
    try testing.expect(Version.parse("0.159") == null);
}

test "dictated words are spaced from the text around them" {
    const a = testing.allocator;
    const s = try spaced(a, "hello", 5, " world ");
    defer a.free(s);
    try testing.expectEqualStrings(" world", s);
    const t = try spaced(a, "ab", 1, "x");
    defer a.free(t);
    try testing.expectEqualStrings(" x ", t);
    try testing.expectEqualStrings("", try spaced(a, "", 0, "  "));
}

fn writePackage(io: std.Io, root: std.Io.Dir, version: []const u8, helper: bool) !void {
    try root.createDirPath(io, "bin");
    try root.writeFile(io, .{ .sub_path = "bin/codex", .data = "" });
    var buf: [128]u8 = undefined;
    try root.writeFile(io, .{ .sub_path = "codex-package.json", .data = try std.fmt.bufPrint(&buf, "{{\"layoutVersion\":1,\"version\":\"{s}\"}}", .{version}) });
    if (helper) {
        try root.createDirPath(io, "codex-resources/voice/bin");
        try root.writeFile(io, .{ .sub_path = helper_rel, .data = "" });
    }
}

test "the helper resolves from a standalone install, from 0.159, and not without its helper" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    try tmp.dir.createDirPath(io, "codex");
    var root = try tmp.dir.openDir(io, "codex", .{});
    defer root.close(io);
    try writePackage(io, root, "0.160.0", true);
    const codex = try std.fs.path.join(a, &.{ base, "codex", "bin", "codex" });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ base, "codex", helper_rel }), try helperFor(a, io, codex));
    try writePackage(io, root, "0.158.9", true);
    try testing.expectError(error.Unavailable, helperFor(a, io, codex));
    try root.deleteFile(io, helper_rel);
    try writePackage(io, root, "0.160.0", false);
    try testing.expectError(error.Unavailable, helperFor(a, io, codex));
}

test "openDevices names a selection from Codex 0.161" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    try tmp.dir.createDirPath(io, "codex-resources/voice/bin");
    const helper = try std.fs.path.join(a, &.{ base, helper_rel });
    try testing.expectEqual(false, try deviceSelection(a, io, helper));
    for ([_]struct { []const u8, bool }{ .{ "0.160.0", false }, .{ "0.161.0", true }, .{ "0.170.2", true } }) |c| {
        var buf: [64]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = "codex-resources/voice/manifest.json", .data = try std.fmt.bufPrint(&buf, "{{\"appVersion\":\"{s}\"}}", .{c[0]}) });
        try testing.expectEqual(c[1], try deviceSelection(a, io, helper));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "codex-resources/voice/manifest.json", .data = "{" });
    try testing.expectError(error.RuntimeUnavailable, deviceSelection(a, io, helper));
}

// The session against a fake app-server and a fake helper, over pipes.

const Fake = struct {
    io: std.Io,
    /// The app-server's ends: it reads `rpc_in`, writes `rpc_out`.
    rpc_in: posix.fd_t,
    rpc_out: posix.fd_t,
    host_in: posix.fd_t,
    host_out: posix.fd_t,
    /// What the helper is to answer `openDevices` with.
    devices_reply: []const u8 = "devicesOpened",
    got_error_reply: bool = false,
    got_stop: bool = false,
    muted_at_finish: bool = false,
    closed: bool = false,
    // The session's ends of the helper's pipes.
    host_in_w: posix.fd_t = -1,
    host_out_r: posix.fd_t = -1,

    fn line(fd: posix.fd_t, buf: *std.ArrayList(u8), a: Allocator) ?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
                const l = a.dupe(u8, buf.items[0..nl]) catch return null;
                buf.replaceRangeAssumeCapacity(0, nl + 1, &.{});
                return l;
            }
            var chunk: [4096]u8 = undefined;
            const n = readSome(fd, &chunk) catch return null;
            if (n == 0) return null;
            buf.appendSlice(a, chunk[0..n]) catch return null;
        }
    }

    fn appServer(f: *Fake) void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var buf: std.ArrayList(u8) = .empty;
        while (line(f.rpc_in, &buf, a)) |l| {
            const msg = json.parseFromSliceLeaky(json.Value, a, l, .{}) catch continue;
            const o = msg.object;
            const method = str(o, "method") orelse {
                // The answer to our own request.
                if (o.get("error") != null) f.got_error_reply = true;
                continue;
            };
            const id = o.get("id") orelse continue;
            const reply = struct {
                fn send(fd: posix.fd_t, al: Allocator, i: json.Value, result: []const u8) void {
                    const s = std.fmt.allocPrint(al, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}\n", .{ i.integer, result }) catch return;
                    writeAll(fd, s) catch {};
                }
            }.send;
            if (std.mem.eql(u8, method, "initialize")) reply(f.rpc_out, a, id, "{}");
            if (std.mem.eql(u8, method, "thread/start")) reply(f.rpc_out, a, id, "{\"thread\":{\"id\":\"thr\"}}");
            if (std.mem.eql(u8, method, "thread/realtime/start")) {
                reply(f.rpc_out, a, id, "{}");
                const said =
                    \\{"jsonrpc":"2.0","method":"thread/realtime/started","params":{"threadId":"thr"}}
                    \\{"jsonrpc":"2.0","method":"thread/realtime/sdp","params":{"threadId":"thr","sdp":"answer-sdp"}}
                    \\{"jsonrpc":"2.0","method":"thread/realtime/transcript/delta","params":{"threadId":"thr","role":"user","delta":"hel"}}
                    \\{"jsonrpc":"2.0","method":"thread/realtime/transcript/delta","params":{"threadId":"thr","role":"assistant","delta":"Sure"}}
                    \\{"jsonrpc":"2.0","method":"thread/realtime/transcript/delta","params":{"threadId":"thr","role":"user","delta":"lo there"}}
                    \\{"jsonrpc":"2.0","id":99,"method":"item/tool/call","params":{}}
                    \\{"jsonrpc":"2.0","method":"thread/realtime/item/completed","params":{"threadId":"thr","item":{"type":"transcriptSegment","role":"user","text":" hello there "}}}
                    \\
                ;
                writeAll(f.rpc_out, said) catch {};
            }
            if (std.mem.eql(u8, method, "thread/realtime/stop")) {
                f.got_stop = true;
                reply(f.rpc_out, a, id, "{}");
            }
        }
    }

    fn helper(f: *Fake) void {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        while (true) {
            var len: [4]u8 = undefined;
            var h: Host = .{ .io = f.io, .in = f.host_out, .out = f.host_in, .device_selection = false };
            h.readExact(&len, nowMs(f.io) + 10_000) catch return;
            const payload = a.alloc(u8, std.mem.readInt(u32, &len, .big)) catch return;
            h.readExact(payload, nowMs(f.io) + 10_000) catch return;
            const msg = json.parseFromSliceLeaky(json.Value, a, payload, .{}) catch return;
            const ty = str(msg.object, "type") orelse "";
            const eq = std.mem.eql;
            const reply: []const u8 = if (eq(u8, ty, "hello"))
                "{\"type\":\"ready\"}"
            else if (eq(u8, ty, "initializeRuntime"))
                "{\"type\":\"runtimeReady\"}"
            else if (eq(u8, ty, "startTransport"))
                "{\"type\":\"offer\",\"sdp\":\"offer-sdp\"}"
            else if (eq(u8, ty, "applyAnswer"))
                (if (eq(u8, str(msg.object, "sdp") orelse "", "answer-sdp")) "{\"type\":\"transportReady\"}" else "{\"type\":\"wrong\"}")
            else if (eq(u8, ty, "openDevices"))
                (std.fmt.allocPrint(a, "{{\"type\":\"{s}\"}}", .{f.devices_reply}) catch return)
            else if (eq(u8, ty, "setAudioControls")) blk: {
                const muted = msg.object.get("controls").?.object.get("microphoneMuted").?.bool;
                if (muted) f.muted_at_finish = true;
                break :blk "{\"type\":\"audioControlsApplied\"}";
            } else if (eq(u8, ty, "inspectAudio"))
                "{\"type\":\"audioState\",\"state\":{\"microphonePeak\":32767}}"
            else if (eq(u8, ty, "close")) blk: {
                f.closed = true;
                break :blk "{\"type\":\"closed\"}";
            } else "{\"type\":\"unknown\"}";
            std.mem.writeInt(u32, &len, @intCast(reply.len), .big);
            writeAll(f.host_out, &len) catch return;
            writeAll(f.host_out, reply) catch return;
        }
    }

    fn open(ctx: ?*anyopaque, a: Allocator, io: std.Io) HostError!Host {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        var h: Host = .{ .io = io, .in = f.host_in_w, .out = f.host_out_r, .device_selection = false };
        try h.handshake(a, "fake-commit");
        return h;
    }
};

const Heard = struct {
    events: std.ArrayList([]const u8) = .empty,
    controls: *Controls,

    fn sink(ctx: *anyopaque, e: Event) void {
        const h: *Heard = @ptrCast(@alignCast(ctx));
        const a = std.heap.page_allocator;
        const s = switch (e) {
            .listening => "listening",
            .level => |l| std.fmt.allocPrint(a, "level {d:.1}", .{l}) catch return,
            .partial => |p| std.fmt.allocPrint(a, "partial {s}", .{p}) catch return,
            .segment => |p| std.fmt.allocPrint(a, "segment {s}", .{p}) catch return,
            .failed => |p| std.fmt.allocPrint(a, "failed {s}", .{p}) catch return,
            .ended => "ended",
        };
        // Levels repeat with time: one is enough to know they come.
        if (h.events.items.len > 0 and std.mem.startsWith(u8, s, "level 0.5") and std.mem.eql(u8, h.events.items[h.events.items.len - 1], s)) return;
        h.events.append(a, s) catch {};
        // The first finished words: the person stops.
        if (e == .segment) h.controls.finish.store(true, .release);
    }
};

fn pipePair() ![2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.Pipe;
    return fds;
}

fn runFake(devices_reply: []const u8) !struct { heard: []const []const u8, failure: ?[]const u8, fake: Fake } {
    const io = testing.io;
    const to_server = try pipePair();
    const from_server = try pipePair();
    const to_helper = try pipePair();
    const from_helper = try pipePair();
    var fake: Fake = .{ .io = io, .rpc_in = to_server[0], .rpc_out = from_server[1], .host_in = to_helper[0], .host_out = from_helper[1], .devices_reply = devices_reply, .host_in_w = to_helper[1], .host_out_r = from_helper[0] };
    const server = try std.Thread.spawn(.{}, Fake.appServer, .{&fake});
    const helper = try std.Thread.spawn(.{}, Fake.helper, .{&fake});
    var controls: Controls = .{};
    var heard: Heard = .{ .controls = &controls };
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    var rpc: Rpc = .{ .a = arena.allocator(), .io = io, .in = to_server[1], .out = from_server[0] };
    const failure = session(arena.allocator(), io, &rpc, .{ .ctx = &fake, .func = Fake.open }, &controls, .{ .ctx = &heard, .func = Heard.sink }, "sess", "/tmp");
    // Hung up: both fakes see the end of their input.
    for ([_]posix.fd_t{ to_server[1], to_helper[1] }) |fd| _ = std.c.close(fd);
    server.join();
    helper.join();
    for ([_]posix.fd_t{ to_server[0], from_server[0], from_server[1], to_helper[0], from_helper[0], from_helper[1] }) |fd| _ = std.c.close(fd);
    return .{ .heard = heard.events.items, .failure = failure, .fake = fake };
}

test "a dictation: listening, levels, the person's words as they come, then theirs alone on finishing" {
    const r = try runFake("devicesOpened");
    try testing.expect(r.failure == null);
    const want = [_][]const u8{ "listening", "level 0.5", "partial hel", "partial hello there", "segment hello there", "level 0.0" };
    // In this order, the levels possibly repeating between them.
    var at: usize = 0;
    for (r.heard) |e| if (at < want.len and std.mem.eql(u8, e, want[at])) {
        at += 1;
    };
    if (at != want.len) {
        for (r.heard) |e| std.debug.print("heard: {s}\n", .{e});
        return error.EventsOutOfOrder;
    }
    // The assistant's words never; the server's own request refused; the
    // mic muted on finishing, the call stopped and the helper closed.
    for (r.heard) |e| try testing.expect(std.mem.indexOf(u8, e, "Sure") == null);
    try testing.expect(r.fake.got_error_reply);
    try testing.expect(r.fake.muted_at_finish);
    try testing.expect(r.fake.got_stop);
    try testing.expect(r.fake.closed);
}

test "a microphone that won't open says what to do" {
    const r = try runFake("refused");
    try testing.expectEqualStrings("The microphone could not be opened. Check that Harness may use it in System Settings.", r.failure.?);
}
