//! Settings › Agents' rules, as the GPUI app's (settings/harnesses.rs, the
//! engine's registry.rs and the adapters' install.rs): what each agent is
//! called and needs, when it may be installed, signed in to or switched,
//! and the catalog rows as the engine sends them (`HarnessDescriptor`).
const std = @import("std");
const json = std.json;
const workspace = @import("workspace.zig");
const Allocator = std.mem.Allocator;

/// The agents the engine knows (`HarnessId`), named as on the wire.
pub const Id = enum {
    claude_code,
    codex,
    cursor,
    devin,
    grok,
    hermes,
    graff,
    pi,
    opencode,
    antigravity,
    exo,
    mock,

    /// The wire name (`kebab-case`).
    pub fn wire(id: Id) []const u8 {
        return switch (id) {
            .claude_code => "claude-code",
            else => @tagName(id),
        };
    }

    pub fn parse(s: []const u8) ?Id {
        inline for (comptime std.enums.values(Id)) |id| if (std.mem.eql(u8, s, comptime wire(id))) return id;
        return null;
    }

    /// Its Rust name (`{id:?}`), which the title picker shows for agents it
    /// has no name for.
    pub fn debugName(id: Id) []const u8 {
        return switch (id) {
            .claude_code => "ClaudeCode",
            .codex => "Codex",
            .cursor => "Cursor",
            .devin => "Devin",
            .grok => "Grok",
            .hermes => "Hermes",
            .graff => "Graff",
            .pi => "Pi",
            .opencode => "Opencode",
            .antigravity => "Antigravity",
            .exo => "Exo",
            .mock => "Mock",
        };
    }
};

/// One catalog row (`HarnessDescriptor`). `installed` defaults true so a
/// catalog from an engine predating it never reads as uninstallable;
/// `enabled` null is an engine predating the setting.
pub const Descriptor = struct {
    id: Id,
    name: []const u8,
    installed: bool = true,
    can_install: bool = false,
    enabled: ?bool = null,
};

fn parseDescriptor(a: Allocator, o: json.ObjectMap) ?Descriptor {
    const raw = o.get("id") orelse return null;
    if (raw != .string) return null;
    const id = Id.parse(raw.string) orelse return null;
    const flag = struct {
        fn get(m: json.ObjectMap, k: []const u8) ?bool {
            const v = m.get(k) orelse return null;
            return if (v == .bool) v.bool else null;
        }
    }.get;
    return .{
        .id = id,
        .name = workspace.str(a, o, "name") orelse id.wire(),
        .installed = flag(o, "installed") orelse true,
        .can_install = flag(o, "canInstall") orelse false,
        .enabled = flag(o, "enabled"),
    };
}

pub const Descriptors = workspace.List(Descriptor, parseDescriptor);

/// One-line blurb per agent; the catalog descriptor does not carry one.
pub fn blurb(id: Id) []const u8 {
    return switch (id) {
        .claude_code => "Anthropic's coding agent, driven through the Claude Code CLI.",
        .codex => "OpenAI's coding agent, driven through the Codex CLI.",
        .cursor => "Cursor's coding agent, driven through the cursor-agent CLI.",
        .devin => "Cognition's Devin agent (devin CLI).",
        .grok => "xAI's Grok Build agent (grok CLI).",
        .hermes => "Nous Research's Hermes Agent (hermes CLI).",
        .graff => "codegraff's graff agent over ACP (graff CLI).",
        .pi => "The pi coding agent (pi CLI).",
        .opencode => "SST's opencode agent (opencode CLI).",
        .antigravity => "Google's Antigravity agent (Antigravity ACP server).",
        .exo => "Exo, the self-improving agent, over ACP via its agent-cli adapter.",
        .mock => "Scripted test harness.",
    };
}

/// The CLI named in the not-installed hint (`cli_name`).
pub fn cliName(id: Id) []const u8 {
    return switch (id) {
        .claude_code => "claude",
        .cursor => "cursor-agent",
        .antigravity => "Antigravity",
        .exo => "exo-cli",
        else => @tagName(id),
    };
}

/// Env var that points the GUI at a custom build of this agent's binary
/// (`executable_override`). Cursor's shim override is internal and not
/// advertised here.
pub fn executableOverride(id: Id) ?[]const u8 {
    return switch (id) {
        .claude_code => "CLAUDE_CODE_EXECUTABLE",
        .codex => "CODEX_EXECUTABLE",
        .devin => "DEVIN_EXECUTABLE",
        .grok => "GROK_EXECUTABLE",
        .hermes => "HERMES_EXECUTABLE",
        .graff => "GRAFF_EXECUTABLE",
        .pi => "PI_EXECUTABLE",
        .opencode => "OPENCODE_EXECUTABLE",
        .antigravity => "ANTIGRAVITY_ACP_EXECUTABLE",
        .exo => "EXO_ACP_EXECUTABLE",
        .cursor, .mock => null,
    };
}

/// The documented install command for a device without the installer's
/// prerequisites (`install::manual_command`).
pub fn manualCommand(id: Id) ?[]const u8 {
    return switch (id) {
        .claude_code => "curl -fsSL https://claude.ai/install.sh | bash",
        .codex => "npm install -g @openai/codex",
        .cursor => "curl https://cursor.com/install -fsS | bash",
        .opencode => "npm install -g @opencode/cli",
        .pi => "npm install -g --ignore-scripts @earendil-works/pi-coding-agent",
        .grok => "npm install -g @xai-official/grok",
        .hermes => "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash",
        .devin => "curl -fsSL https://cli.devin.ai/install.sh | bash",
        .exo => "curl -fsSL https://raw.githubusercontent.com/exoharness/exo/main/setup.sh -o setup.sh && bash setup.sh",
        .antigravity, .graff, .mock => null,
    };
}

pub fn offersSignIn(id: Id, installed: bool) bool {
    return id == .antigravity and installed;
}

pub fn offersInstall(id: Id, installed: bool, can_install: bool) bool {
    return id != .mock and !installed and can_install;
}

/// Why a missing agent can't be switched on, and how to get it
/// (`install_hint`).
pub fn installHint(a: Allocator, id: Id, enabled: bool, can_install: bool) ![]const u8 {
    if (id == .antigravity) return if (can_install)
        "Needs Antigravity's ACP server (separate from the agy CLI) — click Install"
    else
        "Needs Antigravity's ACP server (separate from the agy CLI) — set ANTIGRAVITY_ACP_EXECUTABLE to it";
    if (id == .exo) return "Start Exo with its agent-cli adapter to enable (`./exo.sh --setup agent-cli`; first install: https://github.com/exoharness/exo)";
    const hint = if (enabled)
        try std.fmt.allocPrint(a, "{s} CLI not installed — turn it off or install it", .{cliName(id)})
    else
        try std.fmt.allocPrint(a, "Install the {s} CLI to enable", .{cliName(id)});
    if (!can_install) if (manualCommand(id)) |command| return std.fmt.allocPrint(a, "{s}. Install with `{s}`", .{ hint, command });
    return hint;
}

pub fn installLabel(a: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "Installing {s}…", .{name});
}

/// What graff's Install or Install beta says once done.
pub fn graffInstallNotice(beta: bool) []const u8 {
    return if (beta)
        "Codegraff engine beta installed. New chats use the updated engine; open chats keep their current session."
    else
        "Codegraff engine updated. New chats use the updated engine; open chats keep their current session.";
}

/// Whether detection alone switches an agent on (`registry::default_on`).
pub fn defaultOn(id: Id) bool {
    return id == .graff or id == .codex or id == .claude_code;
}

/// A row's effective switch (`descriptor_enabled`): as the engine says,
/// else installed and on by default.
pub fn descriptorEnabled(d: Descriptor) bool {
    return d.enabled orelse (d.installed and defaultOn(d.id));
}

/// The agents that can title sessions (`supports_titles`).
pub fn supportsTitles(id: Id) bool {
    return id == .codex or id == .claude_code or id == .mock;
}

/// The rows shown (`visible_harnesses`): the mock only when the dev rig
/// opts in, or when it's all there is.
pub fn visible(a: Allocator, list: []const Descriptor, allow_mock: bool) ![]const Descriptor {
    if (allow_mock) return list;
    var real: std.ArrayList(Descriptor) = .empty;
    for (list) |d| if (d.id != .mock) try real.append(a, d);
    return if (real.items.len == 0) list else real.items;
}

/// `HARNESS_PROVIDER=mock` (the e2e and dev rig) opts the mock in.
pub fn mockAllowed() bool {
    const v = std.c.getenv("HARNESS_PROVIDER") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, std.mem.span(v), " \t\n"), "mock");
}

/// The switch's rules (`rows`): the one enabled agent left can't be turned
/// off while it could run; turning off never needs the CLI, turning on
/// does; nothing while it signs in.
pub const Switch = struct { last_enabled: bool, interactive: bool };

pub fn switchRule(enabled: bool, installed: bool, enabled_count: usize, signing_in: bool) Switch {
    const last = enabled and enabled_count == 1 and installed;
    return .{ .last_enabled = last, .interactive = !signing_in and !last and (enabled or installed) };
}

/// graff's compaction points (`render_graff_compact_at`): null is graff's
/// own default.
pub const CompactChoice = struct { pct: ?u8, label: []const u8 };
pub const compact_choices = [_]CompactChoice{
    .{ .pct = null, .label = "Default (80%)" },
    .{ .pct = 50, .label = "50%" },
    .{ .pct = 60, .label = "60%" },
    .{ .pct = 70, .label = "70%" },
    .{ .pct = 75, .label = "75%" },
    .{ .pct = 85, .label = "85%" },
    .{ .pct = 90, .label = "90%" },
};

/// A point set some other way (`/compact-at 65`): not one of the pills.
pub fn customCompact(pct: ?u8) ?u8 {
    const p = pct orelse return null;
    for (compact_choices) |ch| if (ch.pct == p) return null;
    return p;
}

/// An Antigravity sign-in's phase (`SignInPhase`).
pub const SignInPhase = enum {
    starting,
    authenticating,

    pub fn pendingLabel(p: SignInPhase) []const u8 {
        return switch (p) {
            .starting => "Preparing Antigravity…",
            .authenticating => "Finish signing in in your browser.",
        };
    }

    pub fn failureLabel(p: SignInPhase) []const u8 {
        return switch (p) {
            .starting => "Setup failed",
            .authenticating => "Sign-in failed",
        };
    }
};

/// The title picker's label for its agent (`render_titles`).
pub fn titleHarnessLabel(id: ?Id) []const u8 {
    const h = id orelse return "Automatic (session agent when supported)";
    return switch (h) {
        .claude_code => "Claude Code",
        .codex => "Codex",
        else => h.debugName(),
    };
}

const testing = std.testing;

test "custom build override is advertised for bring-your-own agents" {
    try testing.expectEqualStrings("GRAFF_EXECUTABLE", executableOverride(.graff).?);
    try testing.expectEqualStrings("CLAUDE_CODE_EXECUTABLE", executableOverride(.claude_code).?);
    try testing.expect(executableOverride(.mock) == null);
}

test "explicit sign-in requires installed Antigravity" {
    try testing.expect(offersSignIn(.antigravity, true));
    try testing.expect(!offersSignIn(.antigravity, false));
    try testing.expect(!offersSignIn(.codex, true));
}

test "Antigravity setup copy matches each phase" {
    try testing.expectEqualStrings("Preparing Antigravity…", SignInPhase.starting.pendingLabel());
    try testing.expectEqualStrings("Setup failed", SignInPhase.starting.failureLabel());
    try testing.expectEqualStrings("Finish signing in in your browser.", SignInPhase.authenticating.pendingLabel());
    try testing.expectEqualStrings("Sign-in failed", SignInPhase.authenticating.failureLabel());
}

test "install visibility and hint follow target capabilities" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Id{ .antigravity, .codex, .opencode, .claude_code, .cursor, .pi, .grok, .hermes, .devin, .mock }) |id| {
        for ([_]bool{ false, true }) |installed| for ([_]bool{ false, true }) |available| {
            try testing.expectEqual(id != .mock and !installed and available, offersInstall(id, installed, available));
            try testing.expectEqual(id == .antigravity and installed, offersSignIn(id, installed));
        };
    }
    try testing.expectEqualStrings("Antigravity", cliName(.antigravity));
    try testing.expectEqualStrings("Needs Antigravity's ACP server (separate from the agy CLI) — click Install", try installHint(a, .antigravity, false, true));
    try testing.expect(std.mem.indexOf(u8, try installHint(a, .antigravity, false, false), "ANTIGRAVITY_ACP_EXECUTABLE") != null);
}

test "install phase copy and the hint's manual command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Installing Claude Code…", try installLabel(a, "Claude Code"));
    try testing.expectEqualStrings("Installing Pi…", try installLabel(a, "Pi"));
    try testing.expectEqualStrings("Install the codex CLI to enable. Install with `npm install -g @openai/codex`", try installHint(a, .codex, false, false));
    try testing.expect(std.mem.startsWith(u8, try installHint(a, .codex, true, false), "codex CLI not installed — turn it off or install it."));
    try testing.expectEqualStrings("Install the codex CLI to enable", try installHint(a, .codex, false, true));
    // graff has no manual command: the hint stops at the sentence.
    try testing.expectEqualStrings("Install the graff CLI to enable", try installHint(a, .graff, false, false));
}

test "enablement: the engine's word, else installed and on by default; the last one stands" {
    try testing.expect(descriptorEnabled(.{ .id = .codex, .name = "Codex" }));
    try testing.expect(!descriptorEnabled(.{ .id = .codex, .name = "Codex", .installed = false }));
    try testing.expect(!descriptorEnabled(.{ .id = .pi, .name = "Pi" }));
    try testing.expect(descriptorEnabled(.{ .id = .pi, .name = "Pi", .enabled = true }));
    try testing.expect(!descriptorEnabled(.{ .id = .graff, .name = "Graff", .enabled = false }));
    // The last enabled, installed agent is held on.
    try testing.expectEqual(Switch{ .last_enabled = true, .interactive = false }, switchRule(true, true, 1, false));
    // Uninstalled, it can still be turned off (its hint says to).
    try testing.expectEqual(Switch{ .last_enabled = false, .interactive = true }, switchRule(true, false, 1, false));
    // Off and missing: can't be turned on.
    try testing.expect(!switchRule(false, false, 2, false).interactive);
    try testing.expect(switchRule(false, true, 2, false).interactive);
    try testing.expect(!switchRule(true, true, 2, true).interactive);
}

test "the catalog reads as the engine sends it; the mock hides unless alone" {
    var l: Descriptors = .init(testing.allocator);
    defer l.deinit();
    const v = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"id":"graff","name":"Graff","installed":true,"canInstall":true,"enabled":true},
        \\ {"id":"pi","name":"Pi","installed":false},
        \\ {"id":"mock","name":"Mock"},
        \\ {"id":"from-the-future","name":"Later"},
        \\ {"id":"codex","name":"Codex"}]
    , .{});
    defer v.deinit();
    try l.replace(v.value);
    try testing.expectEqual(@as(usize, 4), l.items.len);
    try testing.expect(l.items[0].can_install and l.items[0].enabled.?);
    try testing.expect(!l.items[1].installed and l.items[1].enabled == null);
    try testing.expect(l.items[3].installed);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 3), (try visible(arena.allocator(), l.items, false)).len);
    try testing.expectEqual(@as(usize, 4), (try visible(arena.allocator(), l.items, true)).len);
    const only_mock = [_]Descriptor{.{ .id = .mock, .name = "Mock" }};
    try testing.expectEqual(@as(usize, 1), (try visible(arena.allocator(), &only_mock, false)).len);
}

test "compact-at pills, a custom point, and the title labels" {
    try testing.expectEqual(@as(usize, 7), compact_choices.len);
    try testing.expectEqualStrings("Default (80%)", compact_choices[0].label);
    try testing.expect(customCompact(null) == null);
    try testing.expect(customCompact(70) == null);
    try testing.expectEqual(@as(?u8, 65), customCompact(65));
    try testing.expectEqualStrings("Automatic (session agent when supported)", titleHarnessLabel(null));
    try testing.expectEqualStrings("Claude Code", titleHarnessLabel(.claude_code));
    try testing.expectEqualStrings("Mock", titleHarnessLabel(.mock));
    try testing.expectEqual(Id.claude_code, Id.parse("claude-code").?);
    try testing.expect(Id.parse("claude_code") == null);
    try testing.expect(defaultOn(.graff) and !defaultOn(.pi));
    try testing.expect(supportsTitles(.codex) and !supportsTitles(.graff));
}
