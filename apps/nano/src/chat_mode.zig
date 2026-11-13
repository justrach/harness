//! Chat mode (crates/ui/src/chat_mode.rs): a plain conversation instead of
//! a coding session. No project, graff on the hosted gateway's auto tiers
//! only, offered as Auto (low), Auto (high) and Auto (smart). Pure, so the
//! picker's rules are tested without the window.
const std = @import("std");
const workspace = @import("workspace.zig");

/// Chat mode always runs on graff, which reaches the hosted gateway.
pub const harness = "graff";

pub const Tier = struct {
    id: []const u8,
    /// Older gateways list the same tier under this id.
    fallback_id: ?[]const u8 = null,
    label: []const u8,
    /// Under the row in the model menu.
    note: ?[]const u8 = null,
    /// In the composer footer while the tier is selected.
    footer_note: ?[]const u8 = null,
};

pub const tiers = [_]Tier{
    .{ .id = "codegraff/auto-low", .fallback_id = "codegraff/auto-medium", .label = "Auto (low)" },
    .{ .id = "codegraff/auto-high", .label = "Auto (high)" },
    .{ .id = "codegraff/auto-smart", .label = "Auto (smart)", .note = smart_cost_note, .footer_note = "Auto (smart) may incur API costs." },
};

pub const smart_cost_note = "May incur API costs.";
pub const unavailable_note = "Chat needs the hosted Auto models, which aren't available right now.";
pub const unavailable_chip = "Auto unavailable";
pub const heading_eyebrow = "New chat on the Auto models";
pub const heading_title = "What's on your mind?";

pub const Availability = enum { pending, available, unavailable };

/// Whether chat mode can be offered: graff installed (when the agents are
/// listed), and its catalog lists a tier; `loaded` says the catalog came
/// back (or failed) rather than still being asked for.
pub fn availability(graff_installed: ?bool, catalog: []const workspace.Model, loaded: bool) Availability {
    if (graff_installed) |yes| if (!yes) return .unavailable;
    if (defaultId(catalog) != null) return .available;
    return if (loaded) .unavailable else .pending;
}

fn tierRow(catalog: []const workspace.Model, t: Tier) ?workspace.Model {
    for (catalog) |m| if (std.mem.eql(u8, m.id, t.id)) return m;
    if (t.fallback_id) |f| for (catalog) |m| if (std.mem.eql(u8, m.id, f)) return m;
    return null;
}

/// The rows chat mode offers, in tier order, under the tier names.
pub fn models(out: *[tiers.len]workspace.Model, catalog: []const workspace.Model) []workspace.Model {
    var n: usize = 0;
    for (tiers) |t| if (tierRow(catalog, t)) |row| {
        var m = row;
        m.label = t.label;
        m.description = t.note;
        out[n] = m;
        n += 1;
    };
    return out[0..n];
}

/// The model a new chat starts on: the first tier on offer.
pub fn defaultId(catalog: []const workspace.Model) ?[]const u8 {
    for (tiers) |t| if (tierRow(catalog, t)) |m| return m.id;
    return null;
}

fn tierOf(id: []const u8) ?Tier {
    for (tiers) |t| {
        if (std.mem.eql(u8, t.id, id)) return t;
        if (t.fallback_id) |f| if (std.mem.eql(u8, f, id)) return t;
    }
    return null;
}

pub fn offers(id: []const u8) bool {
    return tierOf(id) != null;
}

/// The tier's name for `id`, whatever the catalog calls the row.
pub fn labelFor(id: []const u8) ?[]const u8 {
    return if (tierOf(id)) |t| t.label else null;
}

/// The footer note while `id` is selected.
pub fn noteFor(id: ?[]const u8) ?[]const u8 {
    return if (tierOf(id orelse return null)) |t| t.footer_note else null;
}

fn fake(id: []const u8, label: []const u8) workspace.Model {
    return .{ .id = id, .label = label };
}

test "only the auto tiers are offered, in order, under their names (only_the_auto_tiers_are_offered_in_order_under_their_names)" {
    const catalog = [_]workspace.Model{
        fake("codegraff/auto-smart", "auto-smart"),
        fake("codegraff/claude-opus-5-5", "Claude Opus 5.5"),
        fake("codegraff/auto-high", "Auto (high)"),
        fake("chatgpt-new/gpt-6.1-sol", "GPT-6.1 Sol"),
        fake("codegraff/auto-low", "Auto (low)"),
    };
    var buf: [tiers.len]workspace.Model = undefined;
    const offered = models(&buf, &catalog);
    try std.testing.expectEqual(@as(usize, 3), offered.len);
    try std.testing.expectEqualStrings("codegraff/auto-low", offered[0].id);
    try std.testing.expectEqualStrings("Auto (smart)", offered[2].label);
    try std.testing.expectEqualStrings(smart_cost_note, offered[2].description.?);
    try std.testing.expectEqualStrings("codegraff/auto-low", defaultId(&catalog).?);
}

test "an older gateway's auto-medium stands in for Auto (low)" {
    const catalog = [_]workspace.Model{ fake("codegraff/auto-high", "x"), fake("codegraff/auto-medium", "y") };
    try std.testing.expectEqualStrings("codegraff/auto-medium", defaultId(&catalog).?);
    try std.testing.expectEqualStrings("Auto (low)", labelFor("codegraff/auto-medium").?);
    try std.testing.expect(offers("codegraff/auto-medium") and !offers("codegraff/claude-opus-5-5"));
    try std.testing.expectEqualStrings("Auto (smart) may incur API costs.", noteFor("codegraff/auto-smart").?);
    try std.testing.expect(noteFor("codegraff/auto-low") == null);
}

test "availability: waiting, listed, or not on offer" {
    const none = [_]workspace.Model{fake("codegraff/claude-opus-5-5", "x")};
    const some = [_]workspace.Model{fake("codegraff/auto-low", "x")};
    try std.testing.expectEqual(Availability.pending, availability(null, &.{}, false));
    try std.testing.expectEqual(Availability.available, availability(true, &some, true));
    try std.testing.expectEqual(Availability.unavailable, availability(true, &none, true));
    try std.testing.expectEqual(Availability.unavailable, availability(false, &some, true));
}
