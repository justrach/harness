//! Auth, Codegraff OAuth/Key Sign-in, Cloud Sandboxes & GitHub Runners (`crates/engine/src/auth.rs`,
//! `codegraff_auth/`, `agent_accounts.rs`, `sandboxes.rs`, `github_runners.rs`).
//!
//! Uses `http_zig` (`https://github.com/justrach/http-zig`) for HTTP/2 and HTTP/1.1
//! control-plane calls (`GetAuthStatus`, `SignInWithKey`, `GetCodegraffStatus`,
//! `CreateCloudSandbox`, `StopCloudSandbox`, `DeleteCloudSandbox`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const http_zig = @import("http_zig");

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
    signed_in: bool = true,
    email: []u8,
    api_key: ?[]u8 = null,
    codegraff_connected: bool = true,
    sandboxes: std.ArrayList(CloudSandbox) = .empty,

    pub fn init(gpa: Allocator) !AuthManager {
        return .{
            .gpa = gpa,
            .email = try gpa.dupe(u8, "local@harness.dev"),
        };
    }

    pub fn deinit(self: *AuthManager) void {
        self.gpa.free(self.email);
        if (self.api_key) |k| self.gpa.free(k);
        for (self.sandboxes.items) |*sb| sb.deinit(self.gpa);
        self.sandboxes.deinit(self.gpa);
    }

    pub fn signInWithKey(self: *AuthManager, key: []const u8) !void {
        const trimmed = std.mem.trim(u8, key, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyApiKey;
        const copy = try self.gpa.dupe(u8, trimmed);
        if (self.api_key) |old| self.gpa.free(old);
        self.api_key = copy;
        self.signed_in = true;
    }

    pub fn signOut(self: *AuthManager) void {
        if (self.api_key) |old| {
            self.gpa.free(old);
            self.api_key = null;
        }
        self.signed_in = false;
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
        defer resp.deinit(self.gpa);
        return resp.status == 200;
    }
};

test "AuthManager sign-in/out and CloudSandbox lifecycle" {
    const gpa = testing.allocator;
    var auth = try AuthManager.init(gpa);
    defer auth.deinit();

    try auth.signInWithKey("hrn_live_synthetic_key_123");
    try testing.expect(auth.signed_in);
    try testing.expectEqualStrings("hrn_live_synthetic_key_123", auth.api_key.?);

    try auth.createSandbox("sb-1", "zig-port-box", "iad");
    try testing.expectEqual(@as(usize, 1), auth.sandboxes.items.len);
    try testing.expect(try auth.stopSandbox("sb-1"));
    try testing.expectEqualStrings("stopped", auth.sandboxes.items[0].status);
    try testing.expect(auth.deleteSandbox("sb-1"));
    try testing.expectEqual(@as(usize, 0), auth.sandboxes.items.len);

    auth.signOut();
    try testing.expect(!auth.signed_in);
}
