//! GitHub-owned HTTPS image origins only. No local files, arbitrary web hosts,
//! credentials, custom ports or active SVG/HTML documents.
const std = @import("std");

pub fn allowed(url: []const u8) bool {
    const prefix = "https://";
    if (url.len > 8192 or !std.ascii.startsWithIgnoreCase(url, prefix)) return false;
    for (url) |ch| if (ch <= 0x20 or ch == 0x7f or ch == '\\') return false;
    const rest = url[prefix.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse return false;
    const host = rest[0..end];
    const path = rest[end..];
    if (host.len == 0 or std.mem.indexOfAny(u8, host, ":@%") != null or path[0] != '/') return false;
    if (std.ascii.eqlIgnoreCase(host, "github.com"))
        return std.mem.startsWith(u8, path, "/user-attachments/assets/") and path.len > "/user-attachments/assets/".len;
    if (std.ascii.endsWithIgnoreCase(host, ".githubusercontent.com")) {
        const sub = host[0 .. host.len - ".githubusercontent.com".len];
        if (sub.len == 0) return false;
        for (sub) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
        return true;
    }
    // GitHub attachment redirects use these fixed S3 buckets (often signed).
    return std.ascii.eqlIgnoreCase(host, "github-production-user-asset-6210df.s3.amazonaws.com") or
        std.ascii.eqlIgnoreCase(host, "github-production-repository-file-5c1aeb.s3.amazonaws.com");
}

/// Refuse documents even if a provider labels them image/*. Native decoding is
/// still responsible for dimensions and malformed raster data.
pub fn raster(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n") or
        std.mem.startsWith(u8, bytes, "\xff\xd8\xff") or
        std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a") or
        (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"));
}

test "github images permit GitHub-owned HTTPS origins but no local or arbitrary web authority" {
    for ([_][]const u8{
        "https://raw.githubusercontent.com/demo/repo/media/before.png",
        "https://user-images.githubusercontent.com/1/picture.png",
        "https://private-user-images.githubusercontent.com/1/picture.png?jwt=synthetic",
        "https://github.com/user-attachments/assets/synthetic-id",
        "https://github-production-user-asset-6210df.s3.amazonaws.com/image?signature=synthetic",
    }) |url| try std.testing.expect(allowed(url));
    for ([_][]const u8{
        "http://raw.githubusercontent.com/demo/image.png",            "https://githubusercontent.com/image.png",
        "https://raw.githubusercontent.com.evil.invalid/image.png",   "https://evil.invalid/image.png",
        "https://user@raw.githubusercontent.com/demo/image.png",      "https://raw.githubusercontent.com:443/image.png",
        "https://github.com/login",                                   "https://github.com/user-attachments/assets/",
        "https://127.0.0.1/image.png",                                "https://localhost/image.png",
        "file:///private/image.png",                                  "data:image/png;base64,AAAA",
        "picture.png",                                                "//raw.githubusercontent.com/picture.png",
        "https://raw.githubusercontent.com\\@evil.invalid/image.png", "https://raw.githubusercontent.com/image\n.png",
    }) |url| try std.testing.expect(!allowed(url));
    try std.testing.expect(!raster("<svg><script/></svg>"));
    try std.testing.expect(!raster("<html>not an image</html>"));
    try std.testing.expect(raster("\x89PNG\r\n\x1a\nsynthetic"));
}
