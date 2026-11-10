//! Git & Diff Host (`crates/engine/src/diff_sync.rs`, `repos.rs`, `source_control.rs`, `graff_worktree.rs`).
//!
//! Pure-Zig parsers and runners for `git status --porcelain=v2 --branch`,
//! unified diffs (`git diff HEAD`), GitHub remote URL extraction, and
//! optimistic working-tree checksum verification (`DiscardWorkingTree`).
const std = @import("std");
const json = std.json;
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const GitRemoteRepo = struct {
    owner: []const u8,
    repo: []const u8,
};

/// Parse `git@github.com:owner/repo.git` or `https://github.com/owner/repo.git`.
pub fn parseGitRemoteUrl(raw_url: []const u8) ?GitRemoteRepo {
    const trimmed = std.mem.trim(u8, raw_url, " \t\r\n");
    const after_host = if (std.mem.indexOf(u8, trimmed, "github.com:")) |idx|
        trimmed[idx + "github.com:".len ..]
    else if (std.mem.indexOf(u8, trimmed, "github.com/")) |idx|
        trimmed[idx + "github.com/".len ..]
    else
        return null;

    const clean = if (std.mem.endsWith(u8, after_host, ".git"))
        after_host[0 .. after_host.len - 4]
    else
        after_host;

    const slash = std.mem.indexOfScalar(u8, clean, '/') orelse return null;
    const owner = clean[0..slash];
    const repo = clean[slash + 1 ..];
    if (owner.len == 0 or repo.len == 0 or std.mem.indexOfScalar(u8, repo, '/') != null) return null;
    return .{ .owner = owner, .repo = repo };
}

pub const PorcelainStatus = struct {
    branch: []u8,
    ahead: u32 = 0,
    behind: u32 = 0,
    staged_count: u32 = 0,
    unstaged_count: u32 = 0,
    untracked_count: u32 = 0,

    pub fn deinit(self: *PorcelainStatus, gpa: Allocator) void {
        gpa.free(self.branch);
    }

    pub fn isClean(self: PorcelainStatus) bool {
        return self.staged_count == 0 and self.unstaged_count == 0 and self.untracked_count == 0;
    }
};

/// Parse `git status --porcelain=v2 --branch` output.
pub fn parseGitStatusPorcelainV2(gpa: Allocator, text: []const u8) !PorcelainStatus {
    var branch: []const u8 = "HEAD";
    var ahead: u32 = 0;
    var behind: u32 = 0;
    var staged: u32 = 0;
    var unstaged: u32 = 0;
    var untracked: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "# branch.head ")) {
            branch = std.mem.trim(u8, line["# branch.head ".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            var toks = std.mem.tokenizeScalar(u8, line["# branch.ab ".len..], ' ');
            while (toks.next()) |t| {
                if (std.mem.startsWith(u8, t, "+")) {
                    ahead = std.fmt.parseInt(u32, t[1..], 10) catch 0;
                } else if (std.mem.startsWith(u8, t, "-")) {
                    behind = std.fmt.parseInt(u32, t[1..], 10) catch 0;
                }
            }
        } else if (std.mem.startsWith(u8, line, "1 ") or std.mem.startsWith(u8, line, "2 ")) {
            if (line.len >= 4) {
                const x = line[2];
                const y = line[3];
                if (x != '.') staged += 1;
                if (y != '.') unstaged += 1;
            }
        } else if (std.mem.startsWith(u8, line, "? ")) {
            untracked += 1;
        }
    }

    return .{
        .branch = try gpa.dupe(u8, branch),
        .ahead = ahead,
        .behind = behind,
        .staged_count = staged,
        .unstaged_count = unstaged,
        .untracked_count = untracked,
    };
}

/// Compute a 16-hex-character checksum of a unified diff for `DiscardWorkingTree`.
pub fn computeDiffChecksum(diff_text: []const u8) [16]u8 {
    const h = std.hash.Wyhash.hash(0, diff_text);
    var out: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{h}) catch unreachable;
    return out;
}

/// Parse a unified diff (`git diff HEAD`) into the JSON payload returned by
/// `GetCheckoutDiff` / `WatchCheckoutDiffs`.
pub fn parseUnifiedDiffToJson(gpa: Allocator, checkout_path: []const u8, branch: []const u8, diff_text: []const u8) ![]u8 {
    const FileStat = struct {
        path: []const u8,
        additions: u32 = 0,
        deletions: u32 = 0,
    };
    var files: std.ArrayList(FileStat) = .empty;
    defer files.deinit(gpa);

    var lines = std.mem.splitScalar(u8, diff_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            const b_marker = " b/";
            const path = if (std.mem.lastIndexOf(u8, line, b_marker)) |idx|
                line[idx + b_marker.len ..]
            else
                line["diff --git ".len..];
            try files.append(gpa, .{ .path = path });
        } else if (files.items.len > 0) {
            if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
                files.items[files.items.len - 1].additions += 1;
            } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
                files.items[files.items.len - 1].deletions += 1;
            }
        }
    }

    const checksum = computeDiffChecksum(diff_text);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"checkoutPath\":");
    try json.Stringify.encodeJsonString(checkout_path, .{}, w);
    try w.writeAll(",\"branch\":");
    try json.Stringify.encodeJsonString(branch, .{}, w);
    try w.writeAll(",\"checksum\":");
    try json.Stringify.encodeJsonString(&checksum, .{}, w);
    try w.writeAll(",\"files\":[");
    for (files.items, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try json.Stringify.encodeJsonString(f.path, .{}, w);
        try w.print(",\"additions\":{d},\"deletions\":{d}}}", .{ f.additions, f.deletions });
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

fn captureGitStdout(gpa: Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) ?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .cwd = .{ .path = cwd },
    }) catch return null;
    defer _ = child.wait(io) catch {};

    var out_buf: [65536]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &out_buf);
    const r = &reader.interface;
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const line = (r.takeDelimiter('\n') catch break) orelse break;
        out.appendSlice(gpa, line) catch {
            out.deinit(gpa);
            return null;
        };
        out.append(gpa, '\n') catch {
            out.deinit(gpa);
            return null;
        };
        if (out.items.len > 512 * 1024) break;
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return null;
    };
}

/// Run `git status --porcelain=v2 --branch` in `checkout_path` when `maybe_io` is set.
pub fn runGitStatusJson(gpa: Allocator, maybe_io: ?std.Io, checkout_path: []const u8) ![]u8 {
    if (maybe_io) |io| {
        if (captureGitStdout(gpa, io, checkout_path, &.{ "git", "status", "--porcelain=v2", "--branch" })) |out| {
            defer gpa.free(out);
            if (out.len > 0) {
                var st = try parseGitStatusPorcelainV2(gpa, out);
                defer st.deinit(gpa);
                return std.fmt.allocPrint(
                    gpa,
                    "{{\"branch\":{f},\"dirty\":{},\"ahead\":{d},\"behind\":{d}}}",
                    .{ json.fmt(st.branch, .{}), !st.isClean(), st.ahead, st.behind },
                );
            }
        }
    }
    return gpa.dupe(u8, "{\"branch\":\"main\",\"dirty\":false,\"ahead\":0,\"behind\":0}");
}

/// Run `git diff HEAD` in `cwd` when `maybe_io` is set.
pub fn runGitDiffJson(gpa: Allocator, maybe_io: ?std.Io, cwd: []const u8) ![]u8 {
    if (maybe_io) |io| {
        if (captureGitStdout(gpa, io, cwd, &.{ "git", "diff", "HEAD" })) |diff_text| {
            defer gpa.free(diff_text);
            return parseUnifiedDiffToJson(gpa, cwd, "HEAD", diff_text);
        }
    }
    return parseUnifiedDiffToJson(gpa, cwd, "HEAD", "");
}

test "git_host parses porcelain v2 status, unified diffs, GitHub remotes, and runs real git status" {
    const gpa = testing.allocator;

    const r1 = parseGitRemoteUrl("git@github.com:justrach/harness.git").?;
    try testing.expectEqualStrings("justrach", r1.owner);
    try testing.expectEqualStrings("harness", r1.repo);

    const r2 = parseGitRemoteUrl("https://github.com/justrach/http-zig").?;
    try testing.expectEqualStrings("justrach", r2.owner);
    try testing.expectEqualStrings("http-zig", r2.repo);

    var st = try parseGitStatusPorcelainV2(
        gpa,
        "# branch.oid c9517005\n# branch.head experimental-zig-branch\n# branch.ab +3 -1\n1 M. N... 100644 100644 100644 abc def src/a.zig\n1 .M N... 100644 100644 100644 abc def src/b.zig\n? src/new.zig\n",
    );
    defer st.deinit(gpa);
    try testing.expectEqualStrings("experimental-zig-branch", st.branch);
    try testing.expectEqual(@as(u32, 3), st.ahead);
    try testing.expectEqual(@as(u32, 1), st.behind);
    try testing.expectEqual(@as(u32, 1), st.staged_count);
    try testing.expectEqual(@as(u32, 1), st.unstaged_count);
    try testing.expectEqual(@as(u32, 1), st.untracked_count);

    const diff_json = try parseUnifiedDiffToJson(
        gpa,
        "/repo",
        "experimental-zig-branch",
        "diff --git a/src/a.zig b/src/a.zig\n--- a/src/a.zig\n+++ b/src/a.zig\n@@ -1,2 +1,3 @@\n-old\n+new1\n+new2\n",
    );
    defer gpa.free(diff_json);
    var parsed = try json.parseFromSlice(json.Value, gpa, diff_json, .{});
    defer parsed.deinit();
    const files = parsed.value.object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 1), files.len);
    try testing.expectEqualStrings("src/a.zig", files[0].object.get("path").?.string);
    try testing.expectEqual(@as(i64, 2), files[0].object.get("additions").?.integer);
    try testing.expectEqual(@as(i64, 1), files[0].object.get("deletions").?.integer);

    // Real git status on current worktree
    const live_status = try runGitStatusJson(gpa, testing.io, ".");
    defer gpa.free(live_status);
    try testing.expect(std.mem.indexOf(u8, live_status, "experimental-zig-branch") != null);
}
