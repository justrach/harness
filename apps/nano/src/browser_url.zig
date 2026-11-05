//! Address-bar normalization and navigation policy, without WebKit or I/O.
//! Mirrors the desktop browser's http(s)-only boundary (browser/model.rs).
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ EmptyAddress, InvalidAddress, UnsupportedScheme, Credentials };
const Parts = struct { scheme: []const u8, authority: []const u8, host: []const u8, tail: []const u8 };

fn parts(text: []const u8, explicit: bool) Error!Parts {
    if (text.len == 0) return error.EmptyAddress;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidAddress;
    for (text, 0..) |ch, i| {
        if (ch <= 0x20 or ch == 0x7f or ch == '\\') return error.InvalidAddress;
        if (ch == '%' and (i + 2 >= text.len or !std.ascii.isHex(text[i + 1]) or !std.ascii.isHex(text[i + 2]))) return error.InvalidAddress;
    }
    var scheme: []const u8 = "https";
    var rest = text;
    if (std.mem.indexOf(u8, text, "://")) |at| {
        const s = text[0..at];
        if (std.ascii.eqlIgnoreCase(s, "https")) scheme = "https" else if (std.ascii.eqlIgnoreCase(s, "http")) scheme = "http" else return error.UnsupportedScheme;
        rest = text[at + 3 ..];
    } else if (explicit) return error.UnsupportedScheme;
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (authority.len == 0) return error.InvalidAddress;
    if (std.mem.indexOfScalar(u8, authority, '@') != null) return error.Credentials;
    // Encoded host delimiters are ambiguous across URL parsers. Paths may
    // still contain ordinary, well-formed percent escapes.
    if (std.mem.indexOfScalar(u8, authority, '%') != null) return error.InvalidAddress;
    var host = authority;
    var port: ?[]const u8 = null;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.InvalidAddress;
        host = authority[1..close];
        _ = std.Io.net.Ip6Address.parse(host, 0) catch return error.InvalidAddress;
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.InvalidAddress;
            port = authority[close + 2 ..];
        }
    } else {
        if (std.mem.indexOfScalar(u8, authority, ':')) |at| {
            host = authority[0..at];
            port = authority[at + 1 ..];
        }
        if (host.len == 0 or host[0] == '.' or host[0] == '-' or host[host.len - 1] == '-') return error.InvalidAddress;
        for (host) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_' or ch >= 0x80)) return error.InvalidAddress;
    }
    if (port) |p| {
        if (p.len == 0) return error.InvalidAddress;
        for (p) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidAddress;
        _ = std.fmt.parseInt(u16, p, 10) catch return error.InvalidAddress;
    }
    return .{ .scheme = scheme, .authority = authority, .host = host, .tail = rest[end..] };
}

fn loopback(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (std.Io.net.Ip4Address.parse(host, 0)) |ip| return ip.bytes[0] == 127 else |_| {}
    if (std.Io.net.Ip6Address.parse(host, 0)) |ip| {
        for (ip.bytes[0..15]) |b| if (b != 0) return false;
        return ip.bytes[15] == 1;
    } else |_| {}
    return false;
}

/// Always returns an owned address; an explicit scheme is never changed.
pub fn normalize(gpa: Allocator, input: []const u8) (Error || Allocator.Error)![]u8 {
    const text = std.mem.trim(u8, input, " \t\r\n");
    const p = try parts(text, false);
    const explicit = std.mem.indexOf(u8, text, "://") != null;
    const scheme = if (!explicit and loopback(p.host)) "http" else p.scheme;
    const slash = if (p.tail.len == 0 or p.tail[0] != '/') "/" else "";
    const result = try std.fmt.allocPrint(gpa, "{s}://{s}{s}{s}", .{ scheme, p.authority, slash, p.tail });
    errdefer gpa.free(result);
    _ = std.Uri.parse(result) catch return error.InvalidAddress;
    // The authority has no credentials; its case is not significant.
    for (result[scheme.len + 3 ..][0..p.authority.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
    return result;
}

/// Redirects and clicked links must already be explicit web addresses.
pub fn allowedNavigation(address: []const u8) bool {
    _ = parts(address, true) catch return false;
    _ = std.Uri.parse(address) catch return false;
    return true;
}

pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyAddress => "Enter a website or localhost address.",
        error.UnsupportedScheme => "Only http and https addresses are supported.",
        error.Credentials => "Use an address without an embedded username or password.",
        else => "Enter a valid website or localhost address.",
    };
}

test "browser addresses normalize websites and loopback without changing explicit schemes" {
    const cases = [_][2][]const u8{
        .{ "example.com/path", "https://example.com/path" },
        .{ " Example.COM?x=1#test ", "https://example.com/?x=1#test" },
        .{ "localhost:3000", "http://localhost:3000/" },
        .{ "app.localhost:3000", "http://app.localhost:3000/" },
        .{ "127.0.0.1:5173/a?x=1", "http://127.0.0.1:5173/a?x=1" },
        .{ "127.12.34.56", "http://127.12.34.56/" },
        .{ "[::1]:8080", "http://[::1]:8080/" },
        .{ "[::1]", "http://[::1]/" },
        .{ "https://localhost:3000", "https://localhost:3000/" },
        .{ "HTTP://example.com", "http://example.com/" },
        .{ "example.com/a%20b", "https://example.com/a%20b" },
    };
    for (cases) |case| {
        const got = try normalize(std.testing.allocator, case[0]);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(case[1], got);
        try std.testing.expect(allowedNavigation(got));
    }
}

test "browser policy rejects privileged schemes, credentials and malformed addresses" {
    for ([_][]const u8{
        "",                              "javascript:alert(1)",        "file:///tmp/synthetic", "data:text/html,hi",      "harness://open/chat/a",
        "https://user:pass@example.com", "https://user@example.com",   "https://@example.com",  "https://",               "two words",
        "https://example.com/\nsecret",  "https://example.com/\\path", "example.com:%31",       "example.com:65536",      "example.com:",
        "[invalid]:8080",                "https://example.com/%xx",    "https://example.com/%", "https://%65xample.com/", "https:///example.com",
        "https://example.com:80:90/",
    }) |input| {
        if (normalize(std.testing.allocator, input)) |url| {
            std.testing.allocator.free(url);
            std.debug.print("unexpected browser address: {s}\n", .{input});
            return error.InvalidAddressAccepted;
        } else |_| {}
        try std.testing.expect(!allowedNavigation(input));
    }
    try std.testing.expect(!allowedNavigation("example.com"));
    try std.testing.expect(!allowedNavigation(" https://example.com"));
}
