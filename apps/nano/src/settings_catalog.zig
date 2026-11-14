//! Searchable section descriptions and task-oriented aliases; no settings data.
const std = @import("std");
const Section = @import("settings.zig").Section;

pub fn description(section: Section) []const u8 {
    return switch (section) {
        .appearance => "Themes, text size, sidebar and motion",
        .notifications => "Sounds, alerts and anonymous performance sharing",
        .shortcuts => "Keyboard shortcuts, sending and completion",
        .files => "Autosave, word wrap and project folders",
        .browsing => "Where GitHub PR and issue links open",
        .harnesses => "Installed agents and run preferences",
        .agents => "Provider sign-in, usage and cloud sandboxes",
        .mcp => "Connect tools and MCP servers",
        .github_ci => "Repositories, CI runners and checks",
        .devices => "Connected computers and app updates",
        .appshots => "Capture app screenshots",
        .archived => "Find and restore archived conversations",
    };
}

fn keywords(section: Section) []const u8 {
    return switch (section) {
        .appearance => "font colors dark light compact animation reduce motion",
        .notifications => "privacy telemetry metrics responsiveness scroll statistics consent sound volume banner",
        .shortcuts => "keys hotkey enter return slash commands suggestions stop escape",
        .files => "hidden ignored directory starting folder editor save wrap",
        .browsing => "browser native internal external GitHub pull request PR issue transcript URL link opening",
        .harnesses => "models context compaction titles installed agent",
        .agents => "login authentication credentials account token subscription billing",
        .mcp => "integration tools protocol server",
        .github_ci => "continuous integration build test runner repository GitHub",
        .devices => "update release version hourly install computer host remote desktop",
        .appshots => "screenshot capture permission",
        .archived => "archive restore recover sessions chats history",
    };
}

pub fn matches(section: Section, query: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (words.next()) |word| {
        if (!contains(section.label(), word) and !contains(section.group(), word) and
            !contains(description(section), word) and !contains(keywords(section), word)) return false;
    }
    return true;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (0..hay.len - needle.len + 1) |i| if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    return false;
}

test "settings discovery searches task words across section metadata" {
    const t = std.testing;
    try t.expect(matches(.browsing, "GitHub links"));
    try t.expect(matches(.browsing, "external PR"));
    try t.expect(matches(.notifications, "privacy telemetry"));
    try t.expect(matches(.devices, "hourly updates"));
    try t.expect(matches(.appearance, "font motion"));
    try t.expect(!matches(.files, "GitHub links"));
    try t.expect(!matches(.browsing, "GitHub nonsense"));
    try t.expect(matches(.browsing, " \t "));
}
