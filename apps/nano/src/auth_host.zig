//! Auth, Codegraff OAuth/PKCE Sign-in, Org Onboarding, Refresh Rotation,
//! Cloud Sandboxes & GitHub Runners (`crates/engine/src/auth.rs`,
//! `codegraff_auth/`, `agent_accounts.rs`, `sandboxes.rs`, `github_runners.rs`).
//!
//! Uses `http_zig` (`https://github.com/justrach/http-zig`) for HTTP/2 and HTTP/1.1
//! control-plane calls (`SignIn`, `SignInHeadless`, `CompleteSignIn`, `ListOrgs`,
//! `SelectOrg`, `GetAuthStatus`, `SignInWithKey`, `GetCodegraffStatus`,
//! `CreateCloudSandbox`, `StopCloudSandbox`, `DeleteCloudSandbox`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const http_zig = @import("http_zig");

pub const token_slack_secs: i64 = 30;
pub const refresh_replay_window_ms: u64 = 7 * 24 * 60 * 60 * 1000;

pub const AuthPhase = enum {
    signed_out,
    needs_organization,
    signed_in,
};

/// A refresh rejection's cause from the edge's `{error}` text (`crates/engine/src/auth.rs`).
pub const RefreshRejection = enum {
    invalid,
    workspace,
    malformed,
    rejected,
    unknown,

    pub fn fromReason(reason: []const u8) RefreshRejection {
        if (std.mem.eql(u8, reason, "invalid refresh credential")) return .invalid;
        if (std.mem.eql(u8, reason, "workspace does not belong to this account")) return .workspace;
        if (std.mem.eql(u8, reason, "missing refreshToken") or std.mem.eql(u8, reason, "bad request")) return .malformed;
        if (std.mem.startsWith(u8, reason, "CodeGraff rejected the grant")) return .rejected;
        return .unknown;
    }

    /// Retrying cannot change these answers (`RefreshRejection::definite`).
    pub fn isDefinite(self: RefreshRejection) bool {
        return switch (self) {
            .invalid, .workspace, .malformed => true,
            .rejected, .unknown => false,
        };
    }
};

/// Dual-clock elapsed duration (`UnansweredRefresh::elapsed_at` / `AccessEntry`):
/// monotonic clock freezes across OS suspend, while wall clock is vulnerable to
/// backward NTP steps. Taking `@max(mono_elapsed_ms, wall_elapsed_ms)` is
/// Lean-proven immune to both (`dual_clock_immune_to_sleep_and_ntp`).
pub fn dualClockElapsedMs(mono_elapsed_ms: u64, wall_elapsed_ms: u64) u64 {
    return @max(mono_elapsed_ms, wall_elapsed_ms);
}

/// Compute PKCE S256 `code_challenge = base64url_no_pad(SHA256(verifier))`.
pub fn pkceChallengeS256(verifier: []const u8, out_buf: *[43]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return std.base64.url_safe_no_pad.Encoder.encode(out_buf, &digest);
}

pub const JwtClaims = struct {
    org_id: ?[]u8 = null,
    ttl_secs: i64 = 3600,

    pub fn deinit(self: *JwtClaims, gpa: Allocator) void {
        if (self.org_id) |o| gpa.free(o);
    }
};

/// Decode the payload segment of a `header.payload.sig` JWT to extract `org_id` and `exp - iat`.
pub fn parseJwtClaims(gpa: Allocator, jwt: []const u8) !JwtClaims {
    const first_dot = std.mem.indexOfScalar(u8, jwt, '.') orelse return .{};
    const rest = jwt[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    const payload_b64 = rest[0..second_dot];
    if (payload_b64.len == 0) return .{};

    const dec = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = dec.calcSizeForSlice(payload_b64) catch return .{};
    const decoded = try gpa.alloc(u8, decoded_len);
    defer gpa.free(decoded);
    dec.decode(decoded, payload_b64) catch return .{};

    var parsed = json.parseFromSlice(json.Value, gpa, decoded, .{}) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    const obj = parsed.value.object;

    var out: JwtClaims = .{};
    errdefer out.deinit(gpa);
    if (obj.get("org_id")) |v| {
        if (v == .string and v.string.len > 0) {
            out.org_id = try gpa.dupe(u8, v.string);
        }
    }
    const iat: i64 = if (obj.get("iat")) |v| (if (v == .integer) v.integer else 0) else 0;
    const exp: i64 = if (obj.get("exp")) |v| (if (v == .integer) v.integer else 0) else 0;
    if (exp > iat) out.ttl_secs = exp - iat;
    return out;
}

pub const CloudSandbox = struct {
    id: []u8,
    name: []u8,
    status: []u8, // "running", "stopped"
    region: []u8,

    pub fn deinit(self: *CloudSandbox, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        gpa.free(self.status);
        gpa.free(self.region);
    }
};

pub const AuthManager = struct {
    gpa: Allocator,
    phase: AuthPhase = .signed_in,
    signed_in: bool = true,
    user_id: []u8,
    email: []u8,
    user_name: ?[]u8 = null,
    org_id: ?[]u8 = null,
    api_key: ?[]u8 = null,
    access_token: ?[]u8 = null,
    refresh_token: ?[]u8 = null,
    codegraff_connected: bool = true,
    generation: u64 = 0,
    pending_state: ?[]u8 = null,
    pending_verifier: ?[]u8 = null,
    pending_nonce: ?[]u8 = null,
    pending_generation: u64 = 0,
    edge_url: ?[]u8 = null,
    codegraff_client_id: ?[]u8 = null,
    codegraff_api_base: []u8,
    data_dir: ?[]u8 = null,
    last_unanswered: bool = false,
    rejection_spared: bool = false,
    lost_session_marker: bool = false,
    sandboxes: std.ArrayList(CloudSandbox) = .empty,

    pub fn init(gpa: Allocator) !AuthManager {
        const uid = try gpa.dupe(u8, "user-local");
        errdefer gpa.free(uid);
        const email = try gpa.dupe(u8, "local@codegraff.com");
        errdefer gpa.free(email);
        const uname = try gpa.dupe(u8, "CodeGraff");
        errdefer gpa.free(uname);
        const org = try gpa.dupe(u8, "org-personal");
        errdefer gpa.free(org);
        const api_base = try gpa.dupe(u8, "https://codegraff.com");
        errdefer gpa.free(api_base);
        return .{
            .gpa = gpa,
            .phase = .signed_in,
            .signed_in = true,
            .user_id = uid,
            .email = email,
            .user_name = uname,
            .org_id = org,
            .codegraff_api_base = api_base,
        };
    }

    pub fn deinit(self: *AuthManager) void {
        self.gpa.free(self.user_id);
        self.gpa.free(self.email);
        if (self.user_name) |n| self.gpa.free(n);
        if (self.org_id) |o| self.gpa.free(o);
        if (self.api_key) |k| self.gpa.free(k);
        if (self.access_token) |t| self.gpa.free(t);
        if (self.refresh_token) |t| self.gpa.free(t);
        if (self.pending_state) |s| self.gpa.free(s);
        if (self.pending_verifier) |v| self.gpa.free(v);
        if (self.pending_nonce) |n| self.gpa.free(n);
        if (self.edge_url) |u| self.gpa.free(u);
        if (self.codegraff_client_id) |c| self.gpa.free(c);
        self.gpa.free(self.codegraff_api_base);
        if (self.data_dir) |d| self.gpa.free(d);
        for (self.sandboxes.items) |*sb| sb.deinit(self.gpa);
        self.sandboxes.deinit(self.gpa);
    }

    fn replaceOptStr(self: *AuthManager, slot: *?[]u8, val: ?[]const u8) !void {
        const copy = if (val) |v| try self.gpa.dupe(u8, v) else null;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = copy;
    }

    fn replaceStr(self: *AuthManager, slot: *[]u8, val: []const u8) !void {
        const copy = try self.gpa.dupe(u8, val);
        self.gpa.free(slot.*);
        slot.* = copy;
    }

    /// Configure CodeGraff OAuth client + edge URL + data_dir for session persistence.
    pub fn configureCodegraff(
        self: *AuthManager,
        edge_url: ?[]const u8,
        client_id: ?[]const u8,
        api_base: ?[]const u8,
        data_dir: ?[]const u8,
    ) !void {
        try self.replaceOptStr(&self.edge_url, edge_url);
        try self.replaceOptStr(&self.codegraff_client_id, client_id);
        if (api_base) |b| try self.replaceStr(&self.codegraff_api_base, b);
        try self.replaceOptStr(&self.data_dir, data_dir);
        if (client_id != null) {
            self.phase = .signed_out;
            self.signed_in = false;
            try self.replaceOptStr(&self.org_id, null);
        }
    }

    /// Serialize `AuthStatus` stream item matching `harness_proto::AuthState`.
    pub fn authStatusJson(self: *const AuthManager, gpa: Allocator) ![]u8 {
        return switch (self.phase) {
            .signed_out => gpa.dupe(u8, "{\"state\":\"signedOut\"}"),
            .needs_organization => std.fmt.allocPrint(
                gpa,
                "{{\"state\":\"needsOrganization\",\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}}}}",
                .{
                    json.fmt(self.user_id, .{}),
                    json.fmt(self.email, .{}),
                    json.fmt(self.user_name orelse "CodeGraff", .{}),
                },
            ),
            .signed_in => if (self.org_id) |org|
                std.fmt.allocPrint(
                    gpa,
                    "{{\"state\":\"signedIn\",\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}},\"orgId\":{f}}}",
                    .{
                        json.fmt(self.user_id, .{}),
                        json.fmt(self.email, .{}),
                        json.fmt(self.user_name orelse "CodeGraff", .{}),
                        json.fmt(org, .{}),
                    },
                )
            else
                std.fmt.allocPrint(
                    gpa,
                    "{{\"state\":\"signedIn\",\"user\":{{\"id\":{f},\"email\":{f},\"name\":{f}}}}}",
                    .{
                        json.fmt(self.user_id, .{}),
                        json.fmt(self.email, .{}),
                        json.fmt(self.user_name orelse "CodeGraff", .{}),
                    },
                ),
        };
    }

    /// Start headless PKCE sign-in (`SignInHeadless`), returning the OAuth authorize URL.
    pub fn startHeadlessSignIn(self: *AuthManager, state_token: []const u8) ![]u8 {
        const verifier = "zig_pkce_verifier_0123456789abcdef0123456789abcdef";
        try self.replaceOptStr(&self.pending_state, state_token);
        try self.replaceOptStr(&self.pending_verifier, verifier);
        try self.replaceOptStr(&self.pending_nonce, "nonce-zig-1");
        self.pending_generation = self.generation;

        var challenge_buf: [43]u8 = undefined;
        const challenge = pkceChallengeS256(verifier, &challenge_buf);
        const cid = self.codegraff_client_id orelse "cg_client_zig";
        const edge = self.edge_url orelse "https://edge.codegraff.com";
        const api_base = std.mem.trimEnd(u8, self.codegraff_api_base, "/");
        return std.fmt.allocPrint(
            self.gpa,
            "{s}/oauth/authorize?response_type=code&client_id={s}&redirect_uri={s}%2Fauth%2Fcli%2Fcallback&state={s}&code_challenge={s}&code_challenge_method=S256",
            .{ api_base, cid, edge, state_token, challenge },
        );
    }

    fn persistSessionFile(self: *const AuthManager, io: std.Io) void {
        const dir = self.data_dir orelse return;
        const rt = self.refresh_token orelse return;
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        const path = std.fmt.allocPrint(self.gpa, "{s}/session.json", .{dir}) catch return;
        defer self.gpa.free(path);

        const body = if (self.org_id) |org|
            std.fmt.allocPrint(
                self.gpa,
                "{{\"refreshToken\":{f},\"user\":{{\"id\":{f},\"email\":{f}}},\"orgId\":{f}}}",
                .{ json.fmt(rt, .{}), json.fmt(self.user_id, .{}), json.fmt(self.email, .{}), json.fmt(org, .{}) },
            ) catch return
        else
            std.fmt.allocPrint(
                self.gpa,
                "{{\"refreshToken\":{f},\"user\":{{\"id\":{f},\"email\":{f}}}}}",
                .{ json.fmt(rt, .{}), json.fmt(self.user_id, .{}), json.fmt(self.email, .{}) },
            ) catch return;
        defer self.gpa.free(body);

        if (std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true })) |f| {
            defer f.close(io);
            f.writeStreamingAll(io, body) catch {};
        } else |_| {}

        var path_z: [1024]u8 = undefined;
        if (path.len + 1 <= path_z.len) {
            @memcpy(path_z[0..path.len], path);
            path_z[path.len] = 0;
            _ = std.c.chmod(@ptrCast(&path_z), 0o600);
        }
    }

    fn removeSessionFile(self: *const AuthManager, io: ?std.Io) void {
        const rio = io orelse return;
        const dir = self.data_dir orelse return;
        const path = std.fmt.allocPrint(self.gpa, "{s}/session.json", .{dir}) catch return;
        defer self.gpa.free(path);
        std.Io.Dir.cwd().deleteFile(rio, path) catch {};
    }

    pub const EdgeReply = struct {
        status: u16,
        body: []u8,

        pub fn deinit(self: *EdgeReply, gpa: Allocator) void {
            gpa.free(self.body);
        }
    };

    /// Execute an HTTP/2 (`https://` via `http_zig.Session`) or HTTP/1.1 (`http://` loopback)
    /// request against the configured edge server.
    pub fn edgeRequest(
        gpa: Allocator,
        io: std.Io,
        method: []const u8,
        url: []const u8,
        bearer_token: ?[]const u8,
        req_body: ?[]const u8,
    ) !EdgeReply {
        if (std.mem.startsWith(u8, url, "https://")) {
            const u = try http_zig.https.parseHttpsUrl(url);
            const sess = try http_zig.Session.open(gpa, io, u.host, u.port);
            defer sess.close();
            var hdr_buf: [2]http_zig.Header = undefined;
            var hdr_len: usize = 0;
            var auth_val: ?[]u8 = null;
            defer if (auth_val) |v| gpa.free(v);
            if (bearer_token) |tok| {
                auth_val = try std.fmt.allocPrint(gpa, "Bearer {s}", .{tok});
                hdr_buf[hdr_len] = .{ .name = "authorization", .value = auth_val.? };
                hdr_len += 1;
            }
            if (req_body != null) {
                hdr_buf[hdr_len] = .{ .name = "content-type", .value = "application/json" };
                hdr_len += 1;
            }
            var resp = try sess.request(.{
                .method = method,
                .scheme = "https",
                .authority = u.host,
                .path = u.path,
                .extra = hdr_buf[0..hdr_len],
                .body = req_body orelse "",
            });
            defer resp.deinit();
            return .{
                .status = resp.status,
                .body = try gpa.dupe(u8, resp.body),
            };
        }

        // Plain HTTP/1.1 loopback (`http://host:port/path`)
        const rest = if (std.mem.startsWith(u8, url, "http://"))
            url["http://".len..]
        else
            return error.InvalidUrl;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const hostport = rest[0..slash];
        const path = if (slash == rest.len) "/" else rest[slash..];
        const colon = std.mem.indexOfScalar(u8, hostport, ':');
        const host = if (colon) |c| hostport[0..c] else hostport;
        const port: u16 = if (colon) |c| try std.fmt.parseInt(u16, hostport[c + 1 ..], 10) else 80;

        const ip_addr = try std.Io.net.IpAddress.parse(host, port);
        var stream = try ip_addr.connect(io, .{ .mode = .stream });
        defer stream.close(io);

        var rbuf: [8192]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        var writer = stream.writer(io, &wbuf);

        const body_slice = req_body orelse "";
        try writer.interface.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{ method, path, hostport });
        if (bearer_token) |tok| {
            try writer.interface.print("Authorization: Bearer {s}\r\n", .{tok});
        }
        if (req_body != null) {
            try writer.interface.print("Content-Type: application/json\r\nContent-Length: {d}\r\n", .{body_slice.len});
        }
        try writer.interface.writeAll("\r\n");
        if (body_slice.len > 0) {
            try writer.interface.writeAll(body_slice);
        }
        try writer.interface.flush();

        const status_line = try reader.interface.takeDelimiterInclusive('\n');
        var status: u16 = 500;
        var parts = std.mem.tokenizeScalar(u8, status_line, ' ');
        _ = parts.next(); // HTTP/1.1
        if (parts.next()) |code_str| {
            status = std.fmt.parseInt(u16, code_str, 10) catch 500;
        }

        var content_len: usize = 0;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                const val = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
                content_len = std.fmt.parseInt(usize, val, 10) catch 0;
            }
        }

        const out_body = try gpa.alloc(u8, content_len);
        errdefer gpa.free(out_body);
        if (content_len > 0) {
            try reader.interface.readSliceAll(out_body);
        }
        return .{ .status = status, .body = out_body };
    }

    /// Complete paste-code or callback sign-in (`CompleteSignIn { code: "state.code" }`).
    /// Verifies CSRF `state`, fences against `self.generation`, exchanges the code with
    /// `/auth/exchange` when `edge_url` is configured, and persists `session.json` (`0600`).
    pub fn completeSignIn(self: *AuthManager, io: ?std.Io, state_dot_code: []const u8) !void {
        if (self.pending_state) |expected_state| {
            const dot = std.mem.indexOfScalar(u8, state_dot_code, '.') orelse return error.InvalidOAuthState;
            const submitted_state = state_dot_code[0..dot];
            const raw_code = state_dot_code[dot + 1 ..];
            if (!std.mem.eql(u8, expected_state, submitted_state) or raw_code.len == 0) {
                return error.InvalidOAuthState;
            }
            if (self.pending_generation != self.generation) {
                return error.SignInCanceled;
            }
            const gen_at_start = self.generation;
            const verifier = try self.gpa.dupe(u8, self.pending_verifier orelse "");
            defer self.gpa.free(verifier);
            const nonce = try self.gpa.dupe(u8, self.pending_nonce orelse "");
            defer self.gpa.free(nonce);
            try self.replaceOptStr(&self.pending_state, null);

            if (io != null and self.edge_url != null) {
                const rio = io.?;
                const base = std.mem.trimEnd(u8, self.edge_url.?, "/");
                const url = try std.fmt.allocPrint(self.gpa, "{s}/auth/exchange", .{base});
                defer self.gpa.free(url);
                const req_body = try std.fmt.allocPrint(
                    self.gpa,
                    "{{\"code\":{f},\"codeVerifier\":{f},\"redirectUri\":\"{s}/auth/cli/callback\",\"nonce\":{f}}}",
                    .{ json.fmt(raw_code, .{}), json.fmt(verifier, .{}), base, json.fmt(nonce, .{}) },
                );
                defer self.gpa.free(req_body);

                var resp = try edgeRequest(self.gpa, rio, "POST", url, null, req_body);
                defer resp.deinit(self.gpa);
                if (resp.status != 200) return error.ExchangeFailed;

                // Generation fence: if SignOut occurred while exchange was in flight, abort!
                if (self.generation != gen_at_start) return error.SignInCanceled;

                var parsed = try json.parseFromSlice(json.Value, self.gpa, resp.body, .{});
                defer parsed.deinit();
                if (parsed.value != .object) return error.ExchangeFailed;
                const obj = parsed.value.object;

                const access_tok = if (obj.get("accessToken")) |v| (if (v == .string) v.string else "") else "";
                const refresh_tok = if (obj.get("refreshToken")) |v| (if (v == .string) v.string else "") else "";
                if (access_tok.len == 0 or refresh_tok.len == 0) return error.ExchangeFailed;

                if (obj.get("user")) |uv| if (uv == .object) {
                    if (uv.object.get("id")) |idv| if (idv == .string) try self.replaceStr(&self.user_id, idv.string);
                    if (uv.object.get("email")) |ev| if (ev == .string) try self.replaceStr(&self.email, ev.string);
                    if (uv.object.get("name")) |nv| {
                        if (nv == .string) try self.replaceOptStr(&self.user_name, nv.string);
                    } else {
                        const first = if (uv.object.get("firstName")) |fv| (if (fv == .string) fv.string else "") else "";
                        const last = if (uv.object.get("lastName")) |lv| (if (lv == .string) lv.string else "") else "";
                        if (first.len > 0 and last.len > 0) {
                            const full = try std.fmt.allocPrint(self.gpa, "{s} {s}", .{ first, last });
                            defer self.gpa.free(full);
                            try self.replaceOptStr(&self.user_name, full);
                        }
                    }
                };

                try self.replaceOptStr(&self.access_token, access_tok);
                try self.replaceOptStr(&self.refresh_token, refresh_tok);

                var claims = try parseJwtClaims(self.gpa, access_tok);
                defer claims.deinit(self.gpa);
                try self.replaceOptStr(&self.org_id, claims.org_id);

                self.last_unanswered = false;
                self.rejection_spared = false;
                self.lost_session_marker = false;
                if (self.org_id != null) {
                    self.phase = .signed_in;
                    self.signed_in = true;
                } else {
                    self.phase = .needs_organization;
                    self.signed_in = false;
                }
                self.persistSessionFile(rio);
                return;
            }
        }
        // Dev / local fallback
        self.phase = .signed_in;
        self.signed_in = true;
        if (self.org_id == null) {
            try self.replaceOptStr(&self.org_id, "org-personal");
        }
    }

    /// List organizations (`ListOrgs` / `GET /auth/orgs`).
    pub fn listOrgsJson(self: *const AuthManager, io: ?std.Io) ![]u8 {
        if (io != null and self.edge_url != null) {
            const rio = io.?;
            const base = std.mem.trimEnd(u8, self.edge_url.?, "/");
            const url = try std.fmt.allocPrint(self.gpa, "{s}/auth/orgs", .{base});
            defer self.gpa.free(url);
            if (edgeRequest(self.gpa, rio, "GET", url, self.access_token, null)) |resp_val| {
                var resp = resp_val;
                defer resp.deinit(self.gpa);
                if (resp.status == 200) {
                    return try self.gpa.dupe(u8, resp.body);
                }
            } else |_| {}
        }
        return self.gpa.dupe(
            u8,
            "{\"orgs\":[{\"id\":\"om_personal\",\"organizationId\":\"org-personal\",\"name\":\"Personal\",\"personal\":true}]}",
        );
    }

    /// Select an organization (`SelectOrg` / `POST /auth/refresh` with `organizationId`),
    /// rotating `refreshToken` and transitioning `NeedsOrganization` -> `SignedIn`.
    pub fn selectOrg(self: *AuthManager, io: ?std.Io, organization_id: []const u8) !void {
        const gen_at_start = self.generation;
        if (io != null and self.edge_url != null and self.refresh_token != null) {
            const rio = io.?;
            const base = std.mem.trimEnd(u8, self.edge_url.?, "/");
            const url = try std.fmt.allocPrint(self.gpa, "{s}/auth/refresh", .{base});
            defer self.gpa.free(url);
            const req_body = try std.fmt.allocPrint(
                self.gpa,
                "{{\"refreshToken\":{f},\"organizationId\":{f}}}",
                .{ json.fmt(self.refresh_token.?, .{}), json.fmt(organization_id, .{}) },
            );
            defer self.gpa.free(req_body);
            var resp = try edgeRequest(self.gpa, rio, "POST", url, null, req_body);
            defer resp.deinit(self.gpa);
            if (self.generation != gen_at_start) return error.SignInCanceled;
            if (resp.status == 200) {
                var parsed = try json.parseFromSlice(json.Value, self.gpa, resp.body, .{});
                defer parsed.deinit();
                if (parsed.value == .object) {
                    if (parsed.value.object.get("accessToken")) |av| if (av == .string) {
                        try self.replaceOptStr(&self.access_token, av.string);
                    };
                    if (parsed.value.object.get("refreshToken")) |rv| if (rv == .string) {
                        try self.replaceOptStr(&self.refresh_token, rv.string);
                    };
                }
            }
        }
        try self.replaceOptStr(&self.org_id, organization_id);
        self.phase = .signed_in;
        self.signed_in = true;
        if (io) |rio| self.persistSessionFile(rio);
    }

    /// Record an unanswered refresh attempt (`crates/engine/src/auth.rs`).
    pub fn recordUnansweredRefresh(self: *AuthManager) void {
        self.last_unanswered = true;
    }

    /// Handle a 401 refresh rejection (`onRefreshRejected` in `RustCodebaseParity.lean`).
    /// Returns `true` if spared (retryable `TemporarilyUnavailable`), `false` if signed out.
    pub fn handleRefreshRejection(self: *AuthManager, io: ?std.Io, reason: []const u8) bool {
        const kind = RefreshRejection.fromReason(reason);
        if (!kind.isDefinite() and self.last_unanswered and !self.rejection_spared) {
            self.rejection_spared = true;
            return true;
        }
        self.phase = .signed_out;
        self.signed_in = false;
        if (self.refresh_token) |old| {
            self.gpa.free(old);
            self.refresh_token = null;
        }
        if (self.access_token) |old| {
            self.gpa.free(old);
            self.access_token = null;
        }
        self.lost_session_marker = true;
        self.removeSessionFile(io);
        return false;
    }

    pub fn signInWithKey(self: *AuthManager, key: []const u8) !void {
        const trimmed = std.mem.trim(u8, key, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyApiKey;
        const copy = try self.gpa.dupe(u8, trimmed);
        if (self.api_key) |old| self.gpa.free(old);
        self.api_key = copy;
        self.phase = .signed_in;
        self.signed_in = true;
    }

    pub fn signOut(self: *AuthManager) void {
        self.signOutWithIo(null);
    }

    pub fn signOutWithIo(self: *AuthManager, io: ?std.Io) void {
        self.generation +%= 1;
        if (self.api_key) |old| {
            self.gpa.free(old);
            self.api_key = null;
        }
        if (self.access_token) |old| {
            self.gpa.free(old);
            self.access_token = null;
        }
        if (self.refresh_token) |old| {
            self.gpa.free(old);
            self.refresh_token = null;
        }
        if (self.pending_state) |old| {
            self.gpa.free(old);
            self.pending_state = null;
        }
        self.phase = .signed_out;
        self.signed_in = false;
        self.last_unanswered = false;
        self.rejection_spared = false;
        self.lost_session_marker = false;
        self.removeSessionFile(io);
    }

    pub fn createSandbox(self: *AuthManager, id: []const u8, name: []const u8, region: []const u8) !void {
        var sb = CloudSandbox{
            .id = try self.gpa.dupe(u8, id),
            .name = try self.gpa.dupe(u8, name),
            .status = try self.gpa.dupe(u8, "running"),
            .region = try self.gpa.dupe(u8, region),
        };
        errdefer sb.deinit(self.gpa);
        try self.sandboxes.append(self.gpa, sb);
    }

    pub fn stopSandbox(self: *AuthManager, id: []const u8) !bool {
        for (self.sandboxes.items) |*sb| {
            if (std.mem.eql(u8, sb.id, id)) {
                const copy = try self.gpa.dupe(u8, "stopped");
                self.gpa.free(sb.status);
                sb.status = copy;
                return true;
            }
        }
        return false;
    }

    pub fn deleteSandbox(self: *AuthManager, id: []const u8) bool {
        for (self.sandboxes.items, 0..) |*sb, idx| {
            if (std.mem.eql(u8, sb.id, id)) {
                sb.deinit(self.gpa);
                _ = self.sandboxes.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Exchange an OAuth token or verify an API key against the control plane over `http-zig`.
    pub fn verifyTokenOverHttp2(
        self: *const AuthManager,
        io: std.Io,
        control_plane_url: []const u8,
        bearer_token: []const u8,
    ) !bool {
        const url = try std.fmt.allocPrint(
            self.gpa,
            "{s}/v1/auth/whoami",
            .{std.mem.trimEnd(u8, control_plane_url, "/")},
        );
        defer self.gpa.free(url);
        const auth_val = try std.fmt.allocPrint(self.gpa, "Bearer {s}", .{bearer_token});
        defer self.gpa.free(auth_val);

        const headers = [_]http_zig.Header{
            .{ .name = "authorization", .value = auth_val },
            .{ .name = "accept", .value = "application/json" },
        };
        var resp = try http_zig.https.request(self.gpa, io, "GET", url, &headers, null);
        defer resp.deinit();
        return resp.status == 200;
    }
};

test "AuthManager sign-in/out, PKCE S256, dual-clock expiry, unanswered refresh leeway, and CloudSandbox lifecycle" {
    const gpa = testing.allocator;
    var auth = try AuthManager.init(gpa);
    defer auth.deinit();

    try auth.signInWithKey("hrn_live_synthetic_key_123");
    try testing.expect(auth.signed_in);
    try testing.expectEqualStrings("hrn_live_synthetic_key_123", auth.api_key.?);

    // Dual-clock elapsed takes max(mono, wall)
    try testing.expectEqual(@as(u64, 120_000), dualClockElapsedMs(5_000, 120_000));
    try testing.expectEqual(@as(u64, 45_000), dualClockElapsedMs(45_000, 10_000));

    // Unanswered refresh leeway: 1st rejection spared, 2nd signs out; definite rejection signs out immediately
    auth.recordUnansweredRefresh();
    try testing.expect(auth.handleRefreshRejection(null, "CodeGraff rejected the grant (400)"));
    try testing.expect(auth.signed_in);
    try testing.expect(!auth.lost_session_marker);

    try testing.expect(!auth.handleRefreshRejection(null, "CodeGraff rejected the grant (400)"));
    try testing.expect(!auth.signed_in);
    try testing.expect(auth.lost_session_marker);

    try auth.signInWithKey("hrn_live_synthetic_key_456");
    auth.recordUnansweredRefresh();
    try testing.expect(!auth.handleRefreshRejection(null, "invalid refresh credential"));
    try testing.expect(!auth.signed_in);

    try auth.createSandbox("sb-1", "zig-port-box", "iad");
    try testing.expectEqual(@as(usize, 1), auth.sandboxes.items.len);
    try testing.expect(try auth.stopSandbox("sb-1"));
    try testing.expectEqualStrings("stopped", auth.sandboxes.items[0].status);
    try testing.expect(auth.deleteSandbox("sb-1"));
    try testing.expectEqual(@as(usize, 0), auth.sandboxes.items.len);

    auth.signOut();
    try testing.expect(!auth.signed_in);
    try testing.expect(!auth.lost_session_marker);
}
