//! 1:1 Zig port of `crates/engine/src/agent_accounts.rs` and `crates/engine/src/graff_logins.rs`.
//!
//! Discovers stored local credentials and probes live plan/rate-limit usage windows
//! (with a 60s in-memory cache) for:
//! - `ListAgentAccounts`: Claude Code (`~/.claude.json` + `.credentials.json` / macOS Keychain),
//!   Codex (`~/.codex/auth.json` JWT claims / `OPENAI_API_KEY`), and Cursor (`~/.cursor/sdk/auth.json`).
//! - `ListGraffLogins`: all 6 `GRAFF_LOGIN_PROVIDERS` (`xai`, `kimi`, `zai`, `chatgpt-new`,
//!   `anthropic`, `claude-agent`).
const std = @import("std");
const builtin = @import("builtin");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const http_zig = @import("http_zig");
const auth_host = @import("auth_host.zig");

pub const usage_cache_ttl_ms: i64 = 60_000;

pub const default_claude_usage_url = "https://api.anthropic.com/api/oauth/usage";
pub const default_codex_usage_url = "https://chatgpt.com/backend-api/wham/usage";
pub const default_cursor_backend_url = "https://api2.cursor.sh";

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

pub const CachedUsage = struct {
    fetched_ms: i64,
    windows_json: []u8,
    plan_override: ?[]u8 = null,

    pub fn deinit(self: *CachedUsage, gpa: Allocator) void {
        gpa.free(self.windows_json);
        if (self.plan_override) |p| gpa.free(p);
    }
};

pub const AgentAccountsHost = struct {
    gpa: Allocator,
    home_dir: ?[]u8 = null,
    claude_config_dir: ?[]u8 = null,
    codex_home_dir: ?[]u8 = null,
    anthropic_config_dir: ?[]u8 = null,
    xdg_config_home: ?[]u8 = null,
    user_name: ?[]u8 = null,
    openai_api_key_env: ?[]u8 = null,
    allow_macos_keychain: bool = true,
    claude_usage_url: []u8,
    codex_usage_url: []u8,
    cursor_backend_override: ?[]u8 = null,
    cache_mutex: std.Io.Mutex = .init,
    usage_cache: std.StringHashMapUnmanaged(CachedUsage) = .empty,
    h2_pool: auth_host.H2SessionPool = .{},

    pub fn init(gpa: Allocator) !AgentAccountsHost {
        const claude_u = try gpa.dupe(u8, default_claude_usage_url);
        errdefer gpa.free(claude_u);
        const codex_u = try gpa.dupe(u8, default_codex_usage_url);
        errdefer gpa.free(codex_u);
        return .{
            .gpa = gpa,
            .claude_usage_url = claude_u,
            .codex_usage_url = codex_u,
        };
    }

    pub fn deinit(self: *AgentAccountsHost) void {
        if (self.home_dir) |v| self.gpa.free(v);
        if (self.claude_config_dir) |v| self.gpa.free(v);
        if (self.codex_home_dir) |v| self.gpa.free(v);
        if (self.anthropic_config_dir) |v| self.gpa.free(v);
        if (self.xdg_config_home) |v| self.gpa.free(v);
        if (self.user_name) |v| self.gpa.free(v);
        if (self.openai_api_key_env) |v| self.gpa.free(v);
        self.gpa.free(self.claude_usage_url);
        self.gpa.free(self.codex_usage_url);
        if (self.cursor_backend_override) |v| self.gpa.free(v);
        var it = self.usage_cache.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(self.gpa);
        }
        self.usage_cache.deinit(self.gpa);
        self.h2_pool.deinit();
    }

    fn setOpt(self: *AgentAccountsHost, slot: *?[]u8, val: ?[]const u8) !void {
        const copy = if (val) |v| (if (v.len > 0) try self.gpa.dupe(u8, v) else null) else null;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = copy;
    }

    pub fn setEndpointOverrides(
        self: *AgentAccountsHost,
        claude_url: []const u8,
        codex_url: []const u8,
        cursor_backend: ?[]const u8,
    ) !void {
        const c1 = try self.gpa.dupe(u8, claude_url);
        self.gpa.free(self.claude_usage_url);
        self.claude_usage_url = c1;

        const c2 = try self.gpa.dupe(u8, codex_url);
        self.gpa.free(self.codex_usage_url);
        self.codex_usage_url = c2;

        try self.setOpt(&self.cursor_backend_override, cursor_backend);
    }

    pub fn configureFromEnv(self: *AgentAccountsHost, env: *const std.process.Environ.Map) !void {
        try self.setOpt(&self.home_dir, env.get("HOME"));
        try self.setOpt(&self.claude_config_dir, env.get("CLAUDE_CONFIG_DIR"));
        try self.setOpt(&self.codex_home_dir, env.get("CODEX_HOME"));
        try self.setOpt(&self.anthropic_config_dir, env.get("ANTHROPIC_CONFIG_DIR"));
        try self.setOpt(&self.xdg_config_home, env.get("XDG_CONFIG_HOME"));
        try self.setOpt(&self.user_name, env.get("USER"));
        try self.setOpt(&self.openai_api_key_env, env.get("OPENAI_API_KEY"));
    }

    pub fn configureSyntheticHome(self: *AgentAccountsHost, home: []const u8) !void {
        try self.setOpt(&self.home_dir, home);
        try self.setOpt(&self.claude_config_dir, null);
        try self.setOpt(&self.codex_home_dir, null);
        try self.setOpt(&self.anthropic_config_dir, null);
        try self.setOpt(&self.xdg_config_home, null);
        try self.setOpt(&self.openai_api_key_env, null);
        self.allow_macos_keychain = false;
    }

    fn putCachedUsage(
        self: *AgentAccountsHost,
        io: std.Io,
        key: []const u8,
        now_ms: i64,
        windows_json: []const u8,
        plan_override: ?[]const u8,
    ) !void {
        const win_copy = try self.gpa.dupe(u8, windows_json);
        errdefer self.gpa.free(win_copy);
        const plan_copy = if (plan_override) |p| try self.gpa.dupe(u8, p) else null;
        errdefer if (plan_copy) |p| self.gpa.free(p);

        self.cache_mutex.lockUncancelable(io);
        defer self.cache_mutex.unlock(io);

        if (self.usage_cache.getPtr(key)) |existing| {
            existing.deinit(self.gpa);
            existing.* = .{
                .fetched_ms = now_ms,
                .windows_json = win_copy,
                .plan_override = plan_copy,
            };
            return;
        }
        const key_copy = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(key_copy);
        try self.usage_cache.put(self.gpa, key_copy, .{
            .fetched_ms = now_ms,
            .windows_json = win_copy,
            .plan_override = plan_copy,
        });
    }

    const CachedLookup = struct {
        windows_json: []u8,
        plan_override: ?[]u8 = null,
        fresh: bool,

        fn deinit(self: *CachedLookup, gpa: Allocator) void {
            gpa.free(self.windows_json);
            if (self.plan_override) |p| gpa.free(p);
        }
    };

    fn lookupCachedUsageAlloc(
        self: *AgentAccountsHost,
        io: std.Io,
        key: []const u8,
        now_ms: i64,
        force_usage: bool,
    ) ?CachedLookup {
        self.cache_mutex.lockUncancelable(io);
        defer self.cache_mutex.unlock(io);
        const entry = self.usage_cache.get(key) orelse return null;
        const fresh = !force_usage or (now_ms - entry.fetched_ms < usage_cache_ttl_ms);
        const w_copy = self.gpa.dupe(u8, entry.windows_json) catch return null;
        const p_copy = if (entry.plan_override) |po| (self.gpa.dupe(u8, po) catch {
            self.gpa.free(w_copy);
            return null;
        }) else null;
        return .{ .windows_json = w_copy, .plan_override = p_copy, .fresh = fresh };
    }

    /// Build `ListGraffLogins` JSON array matching `GRAFF_LOGIN_PROVIDERS` in `crates/engine/src/graff_logins.rs`.
    pub fn listGraffLoginsJson(self: *const AgentAccountsHost, io: ?std.Io) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        const w = &aw.writer;

        const home = self.home_dir orelse "";
        try w.writeByte('[');

        // 1-3: xai, kimi, zai
        const simple = [_]struct { id: []const u8, name: []const u8, rel: []const u8 }{
            .{ .id = "xai", .name = "xAI", .rel = ".xai/credentials/graff-oauth.json" },
            .{ .id = "kimi", .name = "Kimi", .rel = ".kimi/credentials/graff-oauth.json" },
            .{ .id = "zai", .name = "Z.AI", .rel = ".zai/credentials/graff-oauth.json" },
        };
        for (simple, 0..) |p, idx| {
            if (idx > 0) try w.writeByte(',');
            const signed_in = if (io != null and home.len > 0)
                fileExistsJoin(self.gpa, io.?, home, p.rel)
            else
                false;
            try w.print(
                "{{\"id\":{f},\"name\":{f},\"signedIn\":{},\"account\":null,\"planUsage\":null}}",
                .{ json.fmt(p.id, .{}), json.fmt(p.name, .{}), signed_in },
            );
        }

        // 4: chatgpt-new (`~/.graff/credentials/chatgpt-new.json`)
        {
            var signed_in = false;
            var account_str: ?[]u8 = null;
            defer if (account_str) |s| self.gpa.free(s);
            var plan_usage: ?bool = null;

            if (io != null and home.len > 0) {
                if (readFileJoinAlloc(self.gpa, io.?, home, ".graff/credentials/chatgpt-new.json")) |raw| {
                    defer self.gpa.free(raw);
                    if (json.parseFromSlice(json.Value, self.gpa, raw, .{})) |parsed_val| {
                        var parsed = parsed_val;
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            const o = parsed.value.object;
                            const tok = nonEmptyField(o, "access_token") orelse nonEmptyField(o, "accessToken");
                            if (tok != null) {
                                if (nonEmptyField(o, "email")) |em| {
                                    account_str = self.gpa.dupe(u8, em) catch null;
                                }
                                var has_direct = false;
                                if (o.get("scopes")) |sv| {
                                    if (sv == .array) {
                                        for (sv.array.items) |item| {
                                            if (item == .string and std.mem.eql(u8, item.string, "chatgpt.tokens.use.direct")) {
                                                has_direct = true;
                                                break;
                                            }
                                        }
                                    } else if (sv == .string) {
                                        has_direct = std.mem.indexOf(u8, sv.string, "chatgpt.tokens.use.direct") != null;
                                    }
                                }
                                plan_usage = has_direct;
                                signed_in = has_direct;
                            }
                        }
                    } else |_| {}
                }
            }
            try w.writeByte(',');
            if (plan_usage) |pu| {
                try w.print(
                    "{{\"id\":\"chatgpt-new\",\"name\":\"ChatGPT\",\"signedIn\":{},\"account\":{f},\"planUsage\":{}}}",
                    .{ signed_in, json.fmt(account_str, .{}), pu },
                );
            } else {
                try w.print(
                    "{{\"id\":\"chatgpt-new\",\"name\":\"ChatGPT\",\"signedIn\":{},\"account\":{f},\"planUsage\":null}}",
                    .{ signed_in, json.fmt(account_str, .{}) },
                );
            }
        }

        // 5: anthropic ("Anthropic Console", `graff_logins.rs::anthropic_credentials_path`)
        {
            var signed_in = false;
            var account_str: ?[]u8 = null;
            defer if (account_str) |s| self.gpa.free(s);

            if (io != null) {
                const rio = io.?;
                var dir_owned: ?[]u8 = null;
                defer if (dir_owned) |d| self.gpa.free(d);
                const anth_dir: ?[]const u8 = if (self.anthropic_config_dir) |adir|
                    adir
                else if (self.xdg_config_home) |xdg| blk: {
                    dir_owned = std.fmt.allocPrint(self.gpa, "{s}/anthropic", .{std.mem.trimEnd(u8, xdg, "/")}) catch null;
                    break :blk dir_owned;
                } else if (home.len > 0) blk: {
                    dir_owned = std.fmt.allocPrint(self.gpa, "{s}/.config/anthropic", .{std.mem.trimEnd(u8, home, "/")}) catch null;
                    break :blk dir_owned;
                } else null;

                if (anth_dir) |adir| {
                    const active_raw = readFileJoinAlloc(self.gpa, rio, adir, "active_config");
                    defer if (active_raw) |ar| self.gpa.free(ar);
                    const profile = if (active_raw) |ar| blk: {
                        const t = std.mem.trim(u8, ar, " \t\r\n");
                        break :blk if (t.len > 0) t else "default";
                    } else "default";
                    if (std.fmt.allocPrint(self.gpa, "credentials/{s}.json", .{profile})) |prof_rel| {
                        defer self.gpa.free(prof_rel);
                        if (readFileJoinAlloc(self.gpa, rio, adir, prof_rel)) |cred_raw| {
                            defer self.gpa.free(cred_raw);
                            signed_in = true;
                            if (json.parseFromSlice(json.Value, self.gpa, cred_raw, .{})) |pv| {
                                var p = pv;
                                defer p.deinit();
                                if (p.value == .object) {
                                    if (nonEmptyField(p.value.object, "account_email")) |em| {
                                        account_str = self.gpa.dupe(u8, em) catch null;
                                    }
                                }
                            } else |_| {}
                        }
                    } else |_| {}
                    if (!signed_in) {
                        signed_in = fileExistsJoin(self.gpa, rio, adir, "credentials/graff-oauth.json") or
                            fileExistsJoin(self.gpa, rio, adir, "credentials.json");
                    }
                }
                if (!signed_in and home.len > 0) {
                    signed_in = fileExistsJoin(self.gpa, rio, home, ".graff/credentials/anthropic.json");
                }
            }
            try w.print(
                ",{{\"id\":\"anthropic\",\"name\":\"Anthropic Console\",\"signedIn\":{},\"account\":{f},\"planUsage\":null}}",
                .{ signed_in, json.fmt(account_str, .{}) },
            );
        }

        // 6: claude-agent ("Claude Agent", `~/.graff/credentials/claude-agent.json` marker file)
        {
            const signed_in = if (io != null and home.len > 0)
                fileExistsJoin(self.gpa, io.?, home, ".graff/credentials/claude-agent.json")
            else
                false;
            try w.print(
                ",{{\"id\":\"claude-agent\",\"name\":\"Claude Agent\",\"signedIn\":{},\"account\":null,\"planUsage\":null}}",
                .{signed_in},
            );
        }

        try w.writeByte(']');
        return aw.toOwnedSlice();
    }

    /// Build `ListAgentAccounts` JSON snapshot (`{ "accounts": [...], "warnings": [...] }`)
    /// matching `crates/engine/src/agent_accounts.rs` 1:1.
    /// Probes Claude, Codex, and Cursor usage concurrently over warm HTTP/2 connections.
    pub fn listAgentAccountsJson(
        self: *AgentAccountsHost,
        io: ?std.Io,
        now_ms: i64,
        force_usage: bool,
    ) ![]u8 {
        if (io == null) {
            return self.gpa.dupe(u8, "{\"accounts\":[],\"warnings\":[]}");
        }
        const rio = io.?;

        const ProbeWorker = struct {
            host: *AgentAccountsHost,
            wio: std.Io,
            now: i64,
            force: bool,
            acc_json: ?[]u8 = null,
            warn_json: ?[]u8 = null,

            fn runClaude(ctx: *@This()) void {
                var aw: std.Io.Writer.Allocating = .init(ctx.host.gpa);
                defer aw.deinit();
                var cnt: usize = 0;
                ctx.host.appendClaudeAccount(ctx.wio, ctx.now, ctx.force, &aw.writer, &cnt) catch return;
                if (cnt > 0) ctx.acc_json = aw.toOwnedSlice() catch null;
            }

            fn runCodex(ctx: *@This()) void {
                var aw: std.Io.Writer.Allocating = .init(ctx.host.gpa);
                defer aw.deinit();
                var cnt: usize = 0;
                ctx.host.appendCodexAccount(ctx.wio, ctx.now, ctx.force, &aw.writer, &cnt) catch return;
                if (cnt > 0) ctx.acc_json = aw.toOwnedSlice() catch null;
            }

            fn runCursor(ctx: *@This()) void {
                var aw: std.Io.Writer.Allocating = .init(ctx.host.gpa);
                defer aw.deinit();
                var ww: std.Io.Writer.Allocating = .init(ctx.host.gpa);
                defer ww.deinit();
                var cnt: usize = 0;
                var wcnt: usize = 0;
                ctx.host.appendCursorAccount(ctx.wio, ctx.now, ctx.force, &aw.writer, &cnt, &ww.writer, &wcnt) catch return;
                if (cnt > 0) ctx.acc_json = aw.toOwnedSlice() catch null;
                if (wcnt > 0) ctx.warn_json = ww.toOwnedSlice() catch null;
            }
        };

        var claude_w = ProbeWorker{ .host = self, .wio = rio, .now = now_ms, .force = force_usage };
        var codex_w = ProbeWorker{ .host = self, .wio = rio, .now = now_ms, .force = force_usage };
        var cursor_w = ProbeWorker{ .host = self, .wio = rio, .now = now_ms, .force = force_usage };
        defer {
            if (claude_w.acc_json) |s| self.gpa.free(s);
            if (codex_w.acc_json) |s| self.gpa.free(s);
            if (cursor_w.acc_json) |s| self.gpa.free(s);
            if (cursor_w.warn_json) |s| self.gpa.free(s);
        }

        const t1 = std.Thread.spawn(.{}, ProbeWorker.runClaude, .{&claude_w}) catch null;
        const t2 = std.Thread.spawn(.{}, ProbeWorker.runCodex, .{&codex_w}) catch null;
        if (t1 == null) ProbeWorker.runClaude(&claude_w);
        if (t2 == null) ProbeWorker.runCodex(&codex_w);
        ProbeWorker.runCursor(&cursor_w);
        if (t1) |th| th.join();
        if (t2) |th| th.join();

        var acc_aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer acc_aw.deinit();
        var acc_count: usize = 0;
        const parts = [_]?[]const u8{ claude_w.acc_json, codex_w.acc_json, cursor_w.acc_json };
        for (parts) |part_opt| {
            if (part_opt) |part| {
                if (acc_count > 0) try acc_aw.writer.writeByte(',');
                acc_count += 1;
                try acc_aw.writer.writeAll(part);
            }
        }

        return std.fmt.allocPrint(
            self.gpa,
            "{{\"accounts\":[{s}],\"warnings\":[{s}]}}",
            .{ acc_aw.written(), cursor_w.warn_json orelse "" },
        );
    }

    fn appendClaudeAccount(
        self: *AgentAccountsHost,
        io: std.Io,
        now_ms: i64,
        force_usage: bool,
        w: *std.Io.Writer,
        acc_count: *usize,
    ) !void {
        const home = self.home_dir orelse return;
        const cfg_raw = if (self.claude_config_dir) |cdir|
            readFileJoinAlloc(self.gpa, io, cdir, ".claude.json")
        else
            readFileJoinAlloc(self.gpa, io, home, ".claude.json");
        const raw = cfg_raw orelse return;
        defer self.gpa.free(raw);

        var parsed = json.parseFromSlice(json.Value, self.gpa, raw, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const oauth_val = parsed.value.object.get("oauthAccount") orelse return;
        if (oauth_val != .object) return;
        const oa = oauth_val.object;

        const email = nonEmptyField(oa, "emailAddress") orelse return;
        const id = nonEmptyField(oa, "accountUuid") orelse "claude-live";
        const display_name = nonEmptyField(oa, "displayName");
        const org_type = nonEmptyField(oa, "organizationType");
        const rate_tier = nonEmptyField(oa, "organizationRateLimitTier");

        const plan_label = try claudePlanAlloc(self.gpa, org_type, rate_tier);
        defer if (plan_label) |p| self.gpa.free(p);

        const cache_key = try std.fmt.allocPrint(self.gpa, "claude-code:{s}", .{email});
        defer self.gpa.free(cache_key);

        var cached = self.lookupCachedUsageAlloc(io, cache_key, now_ms, force_usage);
        defer if (cached) |*c| c.deinit(self.gpa);

        var windows_owned: ?[]u8 = null;
        defer if (windows_owned) |wo| self.gpa.free(wo);

        var switchable = cached != null;
        const windows_json: []const u8 = if (cached != null and cached.?.fresh)
            cached.?.windows_json
        else if (force_usage) blk: {
            const tok_opt = self.readClaudeAccessTokenAlloc(io);
            defer if (tok_opt) |t| self.gpa.free(t);
            if (tok_opt) |tok| {
                switchable = true;
                if (probeClaudeUsageJson(&self.h2_pool, self.gpa, io, self.claude_usage_url, tok)) |probed| {
                    self.putCachedUsage(io, cache_key, now_ms, probed, null) catch {};
                    windows_owned = probed;
                    break :blk probed;
                }
            }
            break :blk if (cached) |c| c.windows_json else "[]";
        } else blk: {
            switchable = true;
            break :blk "[]";
        };

        if (acc_count.* > 0) try w.writeByte(',');
        acc_count.* += 1;
        try w.print(
            "{{\"id\":{f},\"harness\":\"claude-code\",\"email\":{f},\"displayName\":{f},\"planLabel\":{f},\"active\":true,\"switchable\":{},\"usageWindows\":{s}}}",
            .{
                json.fmt(id, .{}),
                json.fmt(email, .{}),
                json.fmt(display_name, .{}),
                json.fmt(plan_label, .{}),
                switchable,
                windows_json,
            },
        );
    }

    fn readClaudeAccessTokenAlloc(self: *const AgentAccountsHost, io: std.Io) ?[]u8 {
        const home = self.home_dir orelse "";
        const cred_raw: ?[]u8 = if (self.claude_config_dir) |cdir|
            readFileJoinAlloc(self.gpa, io, cdir, ".credentials.json")
        else if (home.len > 0)
            readFileJoinAlloc(self.gpa, io, home, ".claude/.credentials.json")
        else
            null;

        if (cred_raw) |raw| {
            defer self.gpa.free(raw);
            if (extractClaudeOauthTokenAlloc(self.gpa, raw)) |tok| return tok;
        }

        if (comptime builtin.os.tag == .macos) {
            if (self.allow_macos_keychain) {
                // Probe existence first (`agent_accounts.rs:2457`) so machines with no
                // Keychain entry never trigger an authorization dialog.
                const has_item = if (captureProcessStdout(self.gpa, io, &.{
                    "/usr/bin/security",
                    "find-generic-password",
                    "-s",
                    "Claude Code-credentials",
                })) |probe_out| blk: {
                    self.gpa.free(probe_out);
                    break :blk true;
                } else false;
                if (!has_item) return null;

                if (self.user_name) |uname| {
                    if (captureProcessStdout(self.gpa, io, &.{
                        "/usr/bin/security",
                        "find-generic-password",
                        "-a",
                        uname,
                        "-s",
                        "Claude Code-credentials",
                        "-w",
                    })) |kc_out| {
                        defer self.gpa.free(kc_out);
                        if (extractClaudeOauthTokenAlloc(self.gpa, kc_out)) |tok| return tok;
                    }
                }
                if (captureProcessStdout(self.gpa, io, &.{
                    "/usr/bin/security",
                    "find-generic-password",
                    "-s",
                    "Claude Code-credentials",
                    "-w",
                })) |kc_out| {
                    defer self.gpa.free(kc_out);
                    if (extractClaudeOauthTokenAlloc(self.gpa, kc_out)) |tok| return tok;
                }
            }
        }
        return null;
    }

    fn appendCodexAccount(
        self: *AgentAccountsHost,
        io: std.Io,
        now_ms: i64,
        force_usage: bool,
        w: *std.Io.Writer,
        acc_count: *usize,
    ) !void {
        const home = self.home_dir orelse "";
        const auth_raw: ?[]u8 = if (self.codex_home_dir) |cdir|
            readFileJoinAlloc(self.gpa, io, cdir, "auth.json")
        else if (home.len > 0)
            readFileJoinAlloc(self.gpa, io, home, ".codex/auth.json")
        else
            null;
        defer if (auth_raw) |r| self.gpa.free(r);

        var parsed_opt: ?json.Parsed(json.Value) = if (auth_raw) |r|
            (json.parseFromSlice(json.Value, self.gpa, r, .{}) catch null)
        else
            null;
        defer if (parsed_opt) |*p| p.deinit();

        const root_obj: ?json.ObjectMap = if (parsed_opt) |p| (if (p.value == .object) p.value.object else null) else null;
        const tokens_obj: ?json.ObjectMap = if (root_obj) |ro|
            (if (ro.get("tokens")) |tv| (if (tv == .object) tv.object else null) else null)
        else
            null;

        const id_token = if (tokens_obj) |to| nonEmptyField(to, "id_token") else null;
        const access_token = if (tokens_obj) |to| nonEmptyField(to, "access_token") else null;
        var account_id: ?[]u8 = if (tokens_obj) |to|
            (if (nonEmptyField(to, "account_id")) |aid| try self.gpa.dupe(u8, aid) else null)
        else
            null;
        defer if (account_id) |aid| self.gpa.free(aid);

        var email: ?[]u8 = null;
        defer if (email) |e| self.gpa.free(e);
        var display_name: ?[]u8 = null;
        defer if (display_name) |d| self.gpa.free(d);
        var plan_label: ?[]u8 = null;
        defer if (plan_label) |p| self.gpa.free(p);

        if (id_token) |idt| {
            if (decodeJwtPayloadJson(self.gpa, idt)) |jwt_parsed_val| {
                var jwt_p = jwt_parsed_val;
                defer jwt_p.deinit();
                if (jwt_p.value == .object) {
                    const claims = jwt_p.value.object;
                    if (nonEmptyField(claims, "email")) |em| {
                        email = try self.gpa.dupe(u8, em);
                    }
                    if (nonEmptyField(claims, "name")) |nm| {
                        display_name = try self.gpa.dupe(u8, nm);
                    }
                    if (claims.get("https://api.openai.com/auth")) |auth_claim| {
                        if (auth_claim == .object) {
                            if (account_id == null) {
                                if (nonEmptyField(auth_claim.object, "chatgpt_account_id")) |caid| {
                                    account_id = try self.gpa.dupe(u8, caid);
                                }
                            }
                            if (nonEmptyField(auth_claim.object, "chatgpt_plan_type")) |pt| {
                                plan_label = try codexPlanAlloc(self.gpa, pt);
                            }
                        }
                    }
                }
            }
        }

        if (email == null and access_token == null) {
            const file_key = if (root_obj) |ro| nonEmptyField(ro, "OPENAI_API_KEY") else null;
            const api_key = file_key orelse self.openai_api_key_env;
            if (api_key) |k| {
                const trimmed = std.mem.trim(u8, k, " \t\r\n");
                if (trimmed.len > 0) {
                    const suffix = if (trimmed.len > 4) trimmed[trimmed.len - 4 ..] else trimmed;
                    display_name = try std.fmt.allocPrint(self.gpa, "API key \u{00B7}\u{2026}{s}", .{suffix});
                    plan_label = try self.gpa.dupe(u8, "API key");
                } else return;
            } else return;
        }

        const key_ident = account_id orelse email orelse "live";
        const cache_key = try std.fmt.allocPrint(self.gpa, "codex:{s}", .{key_ident});
        defer self.gpa.free(cache_key);

        var cached = self.lookupCachedUsageAlloc(io, cache_key, now_ms, force_usage);
        defer if (cached) |*c| c.deinit(self.gpa);

        var windows_owned: ?[]u8 = null;
        defer if (windows_owned) |wo| self.gpa.free(wo);

        const windows_json: []const u8 = if (cached != null and cached.?.fresh) blk: {
            if (cached.?.plan_override) |po| {
                const copy = try self.gpa.dupe(u8, po);
                if (plan_label) |old| self.gpa.free(old);
                plan_label = copy;
            }
            break :blk cached.?.windows_json;
        } else if (force_usage and access_token != null) blk: {
            if (probeCodexUsage(&self.h2_pool, self.gpa, io, self.codex_usage_url, access_token.?, account_id)) |res_val| {
                var res = res_val;
                errdefer {
                    self.gpa.free(res.windows_json);
                    if (res.plan_label) |pl| self.gpa.free(pl);
                }
                self.putCachedUsage(io, cache_key, now_ms, res.windows_json, res.plan_label) catch {};
                if (res.plan_label) |pl| {
                    if (plan_label) |old| self.gpa.free(old);
                    plan_label = pl;
                    res.plan_label = null;
                }
                windows_owned = res.windows_json;
                break :blk res.windows_json;
            }
            break :blk if (cached) |c| c.windows_json else "[]";
        } else "[]";

        const acct_id = account_id orelse "codex-live";
        if (acc_count.* > 0) try w.writeByte(',');
        acc_count.* += 1;
        try w.print(
            "{{\"id\":{f},\"harness\":\"codex\",\"email\":{f},\"displayName\":{f},\"planLabel\":{f},\"active\":true,\"switchable\":true,\"usageWindows\":{s}}}",
            .{
                json.fmt(acct_id, .{}),
                json.fmt(email, .{}),
                json.fmt(display_name, .{}),
                json.fmt(plan_label, .{}),
                windows_json,
            },
        );
    }

    fn appendCursorAccount(
        self: *AgentAccountsHost,
        io: std.Io,
        now_ms: i64,
        force_usage: bool,
        w: *std.Io.Writer,
        acc_count: *usize,
        warn_w: *std.Io.Writer,
        warn_count: *usize,
    ) !void {
        const home = self.home_dir orelse return;
        const raw = readFileJoinAlloc(self.gpa, io, home, ".cursor/sdk/auth.json") orelse return;
        defer self.gpa.free(raw);

        var parsed = json.parseFromSlice(json.Value, self.gpa, raw, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const o = parsed.value.object;

        const api_key = nonEmptyField(o, "apiKey") orelse return;
        const email = nonEmptyField(o, "email");
        const backend = self.cursor_backend_override orelse nonEmptyField(o, "backendUrl") orelse default_cursor_backend_url;
        const expires_ms = parseJsonEpochMs(o.get("apiKeyExpiresAtMs"));

        var expired = false;
        var plan_buf: [64]u8 = undefined;
        const plan_label: ?[]const u8 = if (expires_ms) |exp_ms| blk: {
            if (exp_ms < now_ms) {
                expired = true;
                break :blk "Key expired";
            }
            const civ = auth_host.civilFromDays(@divFloor(exp_ms, 86_400_000));
            const m_idx: usize = @intCast(@min(@max(@as(u8, 1), civ.month), 12) - 1);
            break :blk std.fmt.bufPrint(&plan_buf, "Key expires {s} {d}", .{ month_names[m_idx], civ.day }) catch null;
        } else null;

        if (expired) {
            if (warn_count.* > 0) try warn_w.writeByte(',');
            warn_count.* += 1;
            try warn_w.writeAll(
                "{\"harness\":\"cursor\",\"message\":\"The connected Cursor login's API key has expired \u{2014} connect again.\"}",
            );
        }

        const cache_key = try std.fmt.allocPrint(self.gpa, "cursor:{s}", .{email orelse "live"});
        defer self.gpa.free(cache_key);

        var cached = self.lookupCachedUsageAlloc(io, cache_key, now_ms, force_usage);
        defer if (cached) |*c| c.deinit(self.gpa);

        var windows_owned: ?[]u8 = null;
        defer if (windows_owned) |wo| self.gpa.free(wo);

        const windows_json: []const u8 = if (expired)
            "[]"
        else if (cached != null and cached.?.fresh)
            cached.?.windows_json
        else if (force_usage) blk: {
            if (probeCursorUsageJson(&self.h2_pool, self.gpa, io, backend, api_key)) |probed| {
                self.putCachedUsage(io, cache_key, now_ms, probed, null) catch {};
                windows_owned = probed;
                break :blk probed;
            }
            break :blk if (cached) |c| c.windows_json else "[]";
        } else "[]";

        if (acc_count.* > 0) try w.writeByte(',');
        acc_count.* += 1;
        try w.print(
            "{{\"id\":\"cursor-live\",\"harness\":\"cursor\",\"email\":{f},\"displayName\":null,\"planLabel\":{f},\"active\":true,\"switchable\":true,\"usageWindows\":{s}}}",
            .{
                json.fmt(email, .{}),
                json.fmt(plan_label, .{}),
                windows_json,
            },
        );
    }
};

/// Map Claude `organizationType` + `organizationRateLimitTier` to display badge (`"Max 20×"`, `"Pro"`, etc.).
pub fn claudePlanAlloc(gpa: Allocator, org_type: ?[]const u8, tier: ?[]const u8) !?[]u8 {
    const ot = org_type orelse return null;
    const base: []const u8 = if (std.mem.eql(u8, ot, "claude_max"))
        "Max"
    else if (std.mem.eql(u8, ot, "claude_pro"))
        "Pro"
    else if (std.mem.eql(u8, ot, "claude_team"))
        "Team"
    else if (std.mem.eql(u8, ot, "claude_enterprise"))
        "Enterprise"
    else
        return null;

    if (tier) |t| {
        if (t.len >= 3 and (t[t.len - 1] == 'x' or t[t.len - 1] == 'X')) {
            const without_x = t[0 .. t.len - 1];
            if (std.mem.lastIndexOfScalar(u8, without_x, '_')) |u_idx| {
                const digits = without_x[u_idx + 1 ..];
                if (digits.len > 0) {
                    var all_digits = true;
                    for (digits) |ch| if (!std.ascii.isDigit(ch)) {
                        all_digits = false;
                        break;
                    };
                    if (all_digits) {
                        return try std.fmt.allocPrint(gpa, "{s} {s}\u{00D7}", .{ base, digits });
                    }
                }
            }
        }
    }
    return try gpa.dupe(u8, base);
}

/// Map Codex `chatgpt_plan_type` / `plan_type` to `"ChatGPT Pro"`, `"ChatGPT Plus"`, etc.
pub fn codexPlanAlloc(gpa: Allocator, raw_plan: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, raw_plan, " \t\r\n");
    if (trimmed.len == 0) return null;
    var out = try gpa.alloc(u8, "ChatGPT ".len + trimmed.len);
    @memcpy(out[0.."ChatGPT ".len], "ChatGPT ");
    for (trimmed, 0..) |ch, i| {
        const prev_sep = (i == 0 or trimmed[i - 1] == '_' or trimmed[i - 1] == '-' or trimmed[i - 1] == ' ');
        out["ChatGPT ".len + i] = if (prev_sep)
            std.ascii.toUpper(ch)
        else if (ch == '_')
            ' '
        else
            std.ascii.toLower(ch);
    }
    return out;
}

fn extractClaudeOauthTokenAlloc(gpa: Allocator, raw_text: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");
    if (trimmed.len == 0) return null;
    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;
    if (o.get("claudeAiOauth")) |co| {
        if (co == .object) {
            if (nonEmptyField(co.object, "accessToken")) |tok| {
                return gpa.dupe(u8, tok) catch null;
            }
        }
    }
    if (nonEmptyField(o, "accessToken")) |tok| {
        return gpa.dupe(u8, tok) catch null;
    }
    return null;
}

fn decodeJwtPayloadJson(gpa: Allocator, jwt: []const u8) ?json.Parsed(json.Value) {
    const first_dot = std.mem.indexOfScalar(u8, jwt, '.') orelse return null;
    const rest = jwt[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    const seg = std.mem.trimEnd(u8, rest[0..second_dot], "=");
    if (seg.len == 0) return null;

    if (std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(seg)) |dec_len| {
        if (gpa.alloc(u8, dec_len)) |buf| {
            defer gpa.free(buf);
            if (std.base64.url_safe_no_pad.Decoder.decode(buf, seg)) |_| {
                return json.parseFromSlice(json.Value, gpa, buf, .{}) catch null;
            } else |_| {}
        } else |_| {}
    } else |_| {}

    if (std.base64.standard_no_pad.Decoder.calcSizeForSlice(seg)) |dec_len| {
        if (gpa.alloc(u8, dec_len)) |buf| {
            defer gpa.free(buf);
            if (std.base64.standard_no_pad.Decoder.decode(buf, seg)) |_| {
                return json.parseFromSlice(json.Value, gpa, buf, .{}) catch null;
            } else |_| {}
        } else |_| {}
    } else |_| {}
    return null;
}

fn probeClaudeUsageJson(pool: *auth_host.H2SessionPool, gpa: Allocator, io: std.Io, url: []const u8, token: []const u8) ?[]u8 {
    const extra = [_]http_zig.Header{
        .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
    };
    var resp = auth_host.AuthManager.edgeRequestPooled(pool, gpa, io, "GET", url, token, &extra, null) catch return null;
    defer resp.deinit(gpa);
    if (resp.status != 200) return null;

    var parsed = json.parseFromSlice(json.Value, gpa, resp.body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return null;
    var count: usize = 0;

    const specs = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "five_hour", .label = "Session" },
        .{ .key = "seven_day", .label = "Week" },
    };
    for (specs) |sp| {
        const win_val = o.get(sp.key) orelse continue;
        if (win_val != .object) continue;
        const util = parseJsonFloat(win_val.object.get("utilization")) orelse continue;
        const frac = std.math.clamp(util / 100.0, 0.0, 1.0);
        var rbuf: [32]u8 = undefined;
        const resets_at = formatResetValue(&rbuf, win_val.object.get("resets_at"), false);
        if (count > 0) w.writeByte(',') catch return null;
        count += 1;
        if (resets_at) |ra| {
            w.print(
                "{{\"label\":{f},\"usedFraction\":{d:.4},\"resetsAt\":{f}}}",
                .{ json.fmt(sp.label, .{}), frac, json.fmt(ra, .{}) },
            ) catch return null;
        } else {
            w.print(
                "{{\"label\":{f},\"usedFraction\":{d:.4}}}",
                .{ json.fmt(sp.label, .{}), frac },
            ) catch return null;
        }
    }
    w.writeByte(']') catch return null;
    return aw.toOwnedSlice() catch null;
}

const CodexProbeResult = struct {
    windows_json: []u8,
    plan_label: ?[]u8 = null,
};

fn probeCodexUsage(
    pool: *auth_host.H2SessionPool,
    gpa: Allocator,
    io: std.Io,
    url: []const u8,
    token: []const u8,
    account_id: ?[]const u8,
) ?CodexProbeResult {
    var extra_buf: [1]http_zig.Header = undefined;
    var extra_len: usize = 0;
    if (account_id) |aid| {
        if (aid.len > 0) {
            extra_buf[0] = .{ .name = "chatgpt-account-id", .value = aid };
            extra_len = 1;
        }
    }
    var resp = auth_host.AuthManager.edgeRequestPooled(pool, gpa, io, "GET", url, token, extra_buf[0..extra_len], null) catch return null;
    defer resp.deinit(gpa);
    if (resp.status != 200) return null;

    var parsed = json.parseFromSlice(json.Value, gpa, resp.body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const o = parsed.value.object;

    var plan_label: ?[]u8 = null;
    errdefer if (plan_label) |pl| gpa.free(pl);
    if (nonEmptyField(o, "plan_type")) |pt| {
        plan_label = codexPlanAlloc(gpa, pt) catch null;
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return null;
    var count: usize = 0;

    if (o.get("rate_limit")) |rl| {
        if (rl == .object) {
            const win_keys = [_][]const u8{ "primary_window", "secondary_window" };
            for (win_keys) |wk| {
                const wv = rl.object.get(wk) orelse continue;
                if (wv != .object) continue;
                const used_pct = parseJsonFloat(wv.object.get("used_percent")) orelse continue;
                const frac = std.math.clamp(used_pct / 100.0, 0.0, 1.0);
                const span_secs: i64 = if (wv.object.get("limit_window_seconds")) |sv|
                    (if (sv == .integer) sv.integer else 0)
                else
                    0;
                const label: []const u8 = if (span_secs >= 28 * 86_400)
                    "Month"
                else if (span_secs >= 5 * 86_400)
                    "Week"
                else
                    "Session";
                var rbuf: [32]u8 = undefined;
                const reset_raw = wv.object.get("reset_at") orelse wv.object.get("resets_at");
                const resets_at = formatResetValue(&rbuf, reset_raw, false);
                if (count > 0) w.writeByte(',') catch return null;
                count += 1;
                if (resets_at) |ra| {
                    w.print(
                        "{{\"label\":{f},\"usedFraction\":{d:.4},\"resetsAt\":{f}}}",
                        .{ json.fmt(label, .{}), frac, json.fmt(ra, .{}) },
                    ) catch return null;
                } else {
                    w.print(
                        "{{\"label\":{f},\"usedFraction\":{d:.4}}}",
                        .{ json.fmt(label, .{}), frac },
                    ) catch return null;
                }
            }
        }
    }

    w.writeByte(']') catch return null;
    const win_slice = aw.toOwnedSlice() catch return null;
    return .{
        .windows_json = win_slice,
        .plan_label = plan_label,
    };
}

fn probeCursorUsageJson(pool: *auth_host.H2SessionPool, gpa: Allocator, io: std.Io, backend_url: []const u8, api_key: []const u8) ?[]u8 {
    const base = std.mem.trimEnd(u8, backend_url, "/");
    const ex_url = std.fmt.allocPrint(gpa, "{s}/auth/exchange_user_api_key", .{base}) catch return null;
    defer gpa.free(ex_url);

    var ex_resp = auth_host.AuthManager.edgeRequestPooled(pool, gpa, io, "POST", ex_url, api_key, &.{}, "{}") catch return null;
    defer ex_resp.deinit(gpa);
    if (ex_resp.status != 200) return null;

    var ex_parsed = json.parseFromSlice(json.Value, gpa, ex_resp.body, .{}) catch return null;
    defer ex_parsed.deinit();
    if (ex_parsed.value != .object) return null;
    const access_tok = nonEmptyField(ex_parsed.value.object, "accessToken") orelse return null;

    const usage_url = std.fmt.allocPrint(gpa, "{s}/aiserver.v1.DashboardService/GetCurrentPeriodUsage", .{base}) catch return null;
    defer gpa.free(usage_url);

    const extra = [_]http_zig.Header{
        .{ .name = "connect-protocol-version", .value = "1" },
    };
    var u_resp = auth_host.AuthManager.edgeRequestPooled(pool, gpa, io, "POST", usage_url, access_tok, &extra, "{}") catch return null;
    defer u_resp.deinit(gpa);
    if (u_resp.status != 200) return null;

    var u_parsed = json.parseFromSlice(json.Value, gpa, u_resp.body, .{}) catch return null;
    defer u_parsed.deinit();
    if (u_parsed.value != .object) return null;
    const uo = u_parsed.value.object;
    const pu_val = uo.get("planUsage") orelse return null;
    if (pu_val != .object) return null;

    const limit = parseJsonFloat(pu_val.object.get("limit")) orelse return null;
    if (limit <= 0.0) return null;
    const spend = parseJsonFloat(pu_val.object.get("totalSpend")) orelse 0.0;
    const frac = std.math.clamp(spend / limit, 0.0, 1.0);

    var rbuf: [32]u8 = undefined;
    const cycle_end = uo.get("billingCycleEnd") orelse pu_val.object.get("billingCycleEnd");
    const resets_at = formatResetValue(&rbuf, cycle_end, true);

    if (resets_at) |ra| {
        return std.fmt.allocPrint(
            gpa,
            "[{{\"label\":\"Month\",\"usedFraction\":{d:.4},\"resetsAt\":{f}}}]",
            .{ frac, json.fmt(ra, .{}) },
        ) catch null;
    }
    return std.fmt.allocPrint(
        gpa,
        "[{{\"label\":\"Month\",\"usedFraction\":{d:.4}}}]",
        .{frac},
    ) catch null;
}

/// Format a reset timestamp JSON value into RFC 3339:
/// - If JSON string containing `'T'` (already RFC 3339), returns it directly.
/// - If numeric string or integer/float: interprets as ms when `numeric_is_ms` (or `>= 100_000_000_000`),
///   otherwise as unix seconds (`* 1000`), and formats via `auth_host.formatRfc3339Ms`.
fn formatResetValue(buf: *[32]u8, val_opt: ?json.Value, numeric_is_ms: bool) ?[]const u8 {
    const v = val_opt orelse return null;
    switch (v) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) return null;
            if (std.mem.indexOfScalar(u8, trimmed, 'T') != null or std.mem.indexOfScalar(u8, trimmed, '-') != null) {
                return trimmed;
            }
            const parsed_num = std.fmt.parseInt(i64, trimmed, 10) catch return null;
            const ms = if (numeric_is_ms or parsed_num >= 100_000_000_000) parsed_num else parsed_num * 1_000;
            return auth_host.formatRfc3339Ms(buf, ms);
        },
        .integer => |n| {
            if (n <= 0) return null;
            const ms = if (numeric_is_ms or n >= 100_000_000_000) n else n * 1_000;
            return auth_host.formatRfc3339Ms(buf, ms);
        },
        .float => |f| {
            if (f <= 0) return null;
            const n: i64 = @intFromFloat(f);
            const ms = if (numeric_is_ms or n >= 100_000_000_000) n else n * 1_000;
            return auth_host.formatRfc3339Ms(buf, ms);
        },
        else => return null,
    }
}

fn parseJsonFloat(val_opt: ?json.Value) ?f64 {
    const v = val_opt orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn parseJsonEpochMs(val_opt: ?json.Value) ?i64 {
    const v = val_opt orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
        else => null,
    };
}

fn nonEmptyField(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v != .string) return null;
    const t = std.mem.trim(u8, v.string, " \t\r\n");
    return if (t.len > 0) t else null;
}

fn fileExistsJoin(gpa: Allocator, io: std.Io, dir: []const u8, rel: []const u8) bool {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), rel }) catch return false;
    defer gpa.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn readFileJoinAlloc(gpa: Allocator, io: std.Io, dir: []const u8, rel: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), rel }) catch return null;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024)) catch null;
}

fn captureProcessStdout(gpa: Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    var out_buf: [16384]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &out_buf);
    const r = &reader.interface;
    var out: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        out.appendSlice(gpa, chunk[0..n]) catch {
            out.deinit(gpa);
            _ = child.wait(io) catch {};
            return null;
        };
        if (out.items.len > 256 * 1024) break;
    }
    const term = child.wait(io) catch {
        out.deinit(gpa);
        return null;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            out.deinit(gpa);
            return null;
        },
        else => {
            out.deinit(gpa);
            return null;
        },
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

test "AgentAccountsHost 1:1 parity: Claude Max 20x, Codex ChatGPT Pro, Cursor Key expires Jan 14, and all 6 GRAFF_LOGIN_PROVIDERS" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Synthetic temp directory (never reads real $HOME)
    const tmp_home = "/tmp/harness-zig-synth-agent-accounts-test";
    std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, tmp_home) catch {};

    try std.Io.Dir.cwd().createDirPath(io, tmp_home ++ "/.claude");
    try std.Io.Dir.cwd().createDirPath(io, tmp_home ++ "/.codex");
    try std.Io.Dir.cwd().createDirPath(io, tmp_home ++ "/.cursor/sdk");
    try std.Io.Dir.cwd().createDirPath(io, tmp_home ++ "/.graff/credentials");

    // 1. Synthetic Claude Code config (`Max 20×`) + `.credentials.json`
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_home ++ "/.claude.json",
        .data = "{\"oauthAccount\":{\"accountUuid\":\"u-claude-1\",\"emailAddress\":\"ada@example.com\",\"displayName\":\"Ada\",\"organizationType\":\"claude_max\",\"organizationRateLimitTier\":\"default_claude_max_20x\"}}",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_home ++ "/.claude/.credentials.json",
        .data = "{\"claudeAiOauth\":{\"accessToken\":\"claude_tok_synth_1\"}}",
    });

    // 2. Synthetic Codex `auth.json` with JWT `id_token` (`chatgpt_plan_type: "pro"`)
    const codex_payload = "{\"email\":\"ada@example.com\",\"name\":\"Ada\",\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_synth_1\",\"chatgpt_plan_type\":\"pro\"}}";
    var b64_buf: [512]u8 = undefined;
    const enc_payload = std.base64.url_safe_no_pad.Encoder.encode(&b64_buf, codex_payload);
    const codex_auth = try std.fmt.allocPrint(
        a,
        "{{\"tokens\":{{\"id_token\":\"e30.{s}.sig\",\"access_token\":\"codex_tok_synth_1\",\"account_id\":\"acct_synth_1\"}}}}",
        .{enc_payload},
    );
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_home ++ "/.codex/auth.json",
        .data = codex_auth,
    });

    // 3. Synthetic Cursor `~/.cursor/sdk/auth.json` (`2027-01-14T00:00:00Z` = 1799884800000 ms)
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_home ++ "/.cursor/sdk/auth.json",
        .data = "{\"apiKey\":\"cur_key_synth_1\",\"email\":\"ada@example.com\",\"apiKeyExpiresAtMs\":1799884800000}",
    });

    // 4. Synthetic graff credentials (`claude-agent.json` without email -> "Signed in on this device", `chatgpt-new.json` with plan scope)
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_home ++ "/.graff/credentials/claude-agent.json",
        .data = "{\"access_token\":\"ca_synth_1\"}",
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_home ++ "/.graff/credentials/chatgpt-new.json",
        .data = "{\"access_token\":\"cgpt_synth_1\",\"email\":\"ada@example.com\",\"scopes\":[\"openid\",\"chatgpt.tokens.use.direct\"]}",
    });

    // 5. Loopback mock usage server (4 requests: Claude usage, Codex wham/usage, Cursor exchange, Cursor GetCurrentPeriodUsage)
    const any_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var srv = try any_addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    const port = srv.socket.address.getPort();

    var stop_mock = std.atomic.Value(bool).init(false);
    const MockUsage = struct {
        s: *std.Io.net.Server,
        tio: std.Io,
        stop: *std.atomic.Value(bool),

        fn run(ctx: @This()) void {
            while (!ctx.stop.load(.acquire)) {
                var stream = ctx.s.accept(ctx.tio) catch return;
                defer stream.close(ctx.tio);
                if (ctx.stop.load(.acquire)) return;
                var rbuf: [4096]u8 = undefined;
                var wbuf: [4096]u8 = undefined;
                var reader = stream.reader(ctx.tio, &rbuf);
                var writer = stream.writer(ctx.tio, &wbuf);

                const req_line = reader.interface.takeDelimiterInclusive('\n') catch continue;
                var content_len: usize = 0;
                while (true) {
                    const line = reader.interface.takeDelimiterInclusive('\n') catch break;
                    const trimmed = std.mem.trimEnd(u8, line, "\r\n");
                    if (trimmed.len == 0) break;
                    if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                        const v = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                        content_len = std.fmt.parseInt(usize, v, 10) catch 0;
                    }
                }
                if (content_len > 0) {
                    var dbuf: [256]u8 = undefined;
                    var rem = content_len;
                    while (rem > 0) {
                        const c = @min(rem, dbuf.len);
                        reader.interface.readSliceAll(dbuf[0..c]) catch break;
                        rem -= c;
                    }
                }

                const body: []const u8 = if (std.mem.indexOf(u8, req_line, "/api/oauth/usage") != null)
                    "{\"five_hour\":null,\"seven_day\":{\"utilization\":22.0,\"resets_at\":\"2026-11-17T08:00:00.000Z\"}}"
                else if (std.mem.indexOf(u8, req_line, "/wham/usage") != null)
                    "{\"plan_type\":\"pro\",\"rate_limit\":{\"primary_window\":{\"used_percent\":75,\"limit_window_seconds\":604800,\"reset_at\":1794960000}}}"
                else if (std.mem.indexOf(u8, req_line, "/auth/exchange_user_api_key") != null)
                    "{\"accessToken\":\"cur_access_synth_1\"}"
                else
                    "{\"billingCycleEnd\":\"1794873600000\",\"planUsage\":{\"totalSpend\":2000,\"limit\":2000}}";

                writer.interface.print(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
                    .{ body.len, body },
                ) catch continue;
                writer.interface.flush() catch continue;
            }
        }
    };

    const th = try std.Thread.spawn(.{}, MockUsage.run, .{MockUsage{ .s = &srv, .tio = io, .stop = &stop_mock }});
    defer {
        stop_mock.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", port)) |wake_addr| {
            if (wake_addr.connect(io, .{ .mode = .stream })) |ws_wake| ws_wake.close(io) else |_| {}
        } else |_| {}
        th.join();
    }

    var host_acc = try AgentAccountsHost.init(gpa);
    defer host_acc.deinit();
    try host_acc.configureSyntheticHome(tmp_home);
    const base_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{port});
    const claude_u = try std.fmt.allocPrint(a, "{s}/api/oauth/usage", .{base_url});
    const codex_u = try std.fmt.allocPrint(a, "{s}/backend-api/wham/usage", .{base_url});
    try host_acc.setEndpointOverrides(claude_u, codex_u, base_url);

    // Verify ListGraffLogins
    const graff_json = try host_acc.listGraffLoginsJson(io);
    defer gpa.free(graff_json);
    const graff_val = try json.parseFromSliceLeaky(json.Value, a, graff_json, .{});
    try testing.expectEqual(@as(usize, 6), graff_val.array.items.len);
    try testing.expectEqualStrings("xai", graff_val.array.items[0].object.get("id").?.string);
    try testing.expectEqualStrings("chatgpt-new", graff_val.array.items[3].object.get("id").?.string);
    try testing.expectEqual(true, graff_val.array.items[3].object.get("signedIn").?.bool);
    try testing.expectEqual(true, graff_val.array.items[3].object.get("planUsage").?.bool);
    try testing.expectEqualStrings("claude-agent", graff_val.array.items[5].object.get("id").?.string);
    try testing.expectEqual(true, graff_val.array.items[5].object.get("signedIn").?.bool);
    try testing.expect(graff_val.array.items[5].object.get("account").? == .null);

    // Verify ListAgentAccounts
    const snap_json = try host_acc.listAgentAccountsJson(io, 1794334000000, true);
    defer gpa.free(snap_json);
    const snap_val = try json.parseFromSliceLeaky(json.Value, a, snap_json, .{});
    const accs = snap_val.object.get("accounts").?.array.items;
    try testing.expectEqual(@as(usize, 3), accs.len);

    // Claude Code: Max 20×, Week 0.22, resetsAt RFC3339
    try testing.expectEqualStrings("claude-code", accs[0].object.get("harness").?.string);
    try testing.expectEqualStrings("ada@example.com", accs[0].object.get("email").?.string);
    try testing.expectEqualStrings("Max 20\u{00D7}", accs[0].object.get("planLabel").?.string);
    const claude_wins = accs[0].object.get("usageWindows").?.array.items;
    try testing.expectEqual(@as(usize, 1), claude_wins.len);
    try testing.expectEqualStrings("Week", claude_wins[0].object.get("label").?.string);
    try testing.expectEqualStrings("2026-11-17T08:00:00.000Z", claude_wins[0].object.get("resetsAt").?.string);

    // Codex: ChatGPT Pro, Week 0.75, resetsAt formatted from unix seconds 1794960000 -> 2026-11-18T00:00:00.000Z
    try testing.expectEqualStrings("codex", accs[1].object.get("harness").?.string);
    try testing.expectEqualStrings("ChatGPT Pro", accs[1].object.get("planLabel").?.string);
    const codex_wins = accs[1].object.get("usageWindows").?.array.items;
    try testing.expectEqual(@as(usize, 1), codex_wins.len);
    try testing.expectEqualStrings("Week", codex_wins[0].object.get("label").?.string);
    try testing.expectEqualStrings("2026-11-18T00:00:00.000Z", codex_wins[0].object.get("resetsAt").?.string);

    // Cursor: Key expires Jan 14, Month 1.0, resetsAt formatted from ms string 1794873600000 -> 2026-11-17T00:00:00.000Z
    try testing.expectEqualStrings("cursor", accs[2].object.get("harness").?.string);
    try testing.expectEqualStrings("Key expires Jan 14", accs[2].object.get("planLabel").?.string);
    const cur_wins = accs[2].object.get("usageWindows").?.array.items;
    try testing.expectEqual(@as(usize, 1), cur_wins.len);
    try testing.expectEqualStrings("Month", cur_wins[0].object.get("label").?.string);
    try testing.expectEqualStrings("2026-11-17T00:00:00.000Z", cur_wins[0].object.get("resetsAt").?.string);
}
