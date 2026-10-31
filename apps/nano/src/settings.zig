//! The Settings page's sections (crates/ui/src/shell.rs `SettingsSection`),
//! and the settings both apps keep in `ui-settings.json` in Harness's data
//! folder (crates/ui/src/settings.rs `UiSettings`): the GPUI app's own file,
//! read and written here key by key, so a change made in one app is the
//! other's too. Keys this app doesn't know are kept as they are.
const std = @import("std");
const json = std.json;
const icons = @import("icons.zig");
const shortcuts = @import("shortcuts.zig");
const Allocator = std.mem.Allocator;

pub const Section = enum {
    appearance,
    notifications,
    shortcuts,
    files,
    harnesses,
    agents,
    mcp,
    github_ci,
    devices,
    appshots,
    archived,

    /// The sidebar's order (`SettingsSection::ALL`).
    pub const all = std.enums.values(Section);

    pub fn label(s: Section) []const u8 {
        return switch (s) {
            .devices => "Devices",
            .harnesses => "Agents",
            .agents => "Accounts",
            .appearance => "Appearance",
            .files => "Files",
            .notifications => "Notifications",
            .shortcuts => "Shortcuts",
            .appshots => "Appshots",
            .archived => "Archived sessions",
            .mcp => "MCP servers",
            .github_ci => "GitHub CI",
        };
    }

    /// The heading it sits under in the sidebar.
    pub fn group(s: Section) []const u8 {
        return switch (s) {
            .appearance, .notifications, .shortcuts, .files => "General",
            .harnesses, .agents, .mcp, .github_ci => "Agents",
            .devices, .appshots, .archived => "Devices and data",
        };
    }

    pub fn icon(s: Section) icons.Name {
        return switch (s) {
            .devices, .appshots => .monitor,
            .harnesses => .widget,
            .agents => .@"key-minimalistic",
            .appearance => .tuning,
            .files => .folder,
            .notifications => .bell,
            .shortcuts => .keyboard,
            .archived => .@"archive-minimalistic",
            .mcp => .@"remote-server",
            .github_ci => .@"pull-request",
        };
    }

    /// As saved in `settingsSection`.
    pub fn key(s: Section) []const u8 {
        return switch (s) {
            .github_ci => "github-ci",
            else => @tagName(s),
        };
    }

    pub fn fromKey(k: []const u8) ?Section {
        for (all) |s| if (std.mem.eql(u8, s.key(), k)) return s;
        return null;
    }
};

/// The switches the Settings page shows, with `UiSettings`'s defaults.
/// Each is saved under its name in camel case (`sound_enabled` as
/// `soundEnabled`).
pub const Prefs = struct {
    sound_enabled: bool = true,
    sound_completion_enabled: bool = true,
    sound_input_enabled: bool = true,
    sound_attention_enabled: bool = true,
    notifications_enabled: bool = true,
    notifications_background_only: bool = true,
    share_performance_stats: bool = true,
    files_autosave_enabled: bool = false,
    files_word_wrap: bool = false,
    files_show_all: bool = false,
    archive_sessions_on_close: bool = false,
    escape_stops_active_agent: bool = false,
    transcript_compact_mode: bool = false,
    pause_animations_in_background: bool = false,
    // The sidebar's ⋯ menu (`sidebar_*`): all on, as the GPUI app's.
    sidebar_compact: bool = true,
    sidebar_show_project_icon: bool = true,
    sidebar_show_harness: bool = true,
    sidebar_show_branch: bool = true,
    sidebar_show_project_label: bool = true,
    sidebar_show_archived: bool = true,
    // Settings › Appshots.
    appshots_enabled: bool = false,
    appshot_sound_enabled: bool = true,
};

/// One of `Prefs`'s switches.
pub const Flag = enum {
    sound_enabled,
    sound_completion_enabled,
    sound_input_enabled,
    sound_attention_enabled,
    notifications_enabled,
    notifications_background_only,
    share_performance_stats,
    files_autosave_enabled,
    files_word_wrap,
    files_show_all,
    archive_sessions_on_close,
    escape_stops_active_agent,
    transcript_compact_mode,
    pause_animations_in_background,
    sidebar_compact,
    sidebar_show_project_icon,
    sidebar_show_harness,
    sidebar_show_branch,
    sidebar_show_project_label,
    sidebar_show_archived,
    appshots_enabled,
    appshot_sound_enabled,
};

/// How the sidebar groups sessions (`SidebarOrganization`), as saved.
pub const Organization = enum {
    by_device,
    by_project,
    in_one_list,

    pub fn key(o: Organization) []const u8 {
        return switch (o) {
            .by_device => "byDevice",
            .by_project => "byProject",
            .in_one_list => "inOneList",
        };
    }
};

/// The sessions' order (`SidebarSort`): when last prompted, or made.
pub const Sort = enum {
    last_updated,
    created,

    pub fn key(o: Sort) []const u8 {
        return switch (o) {
            .last_updated => "lastUpdated",
            .created => "created",
        };
    }
};

fn fromKey(comptime E: type, k: ?[]const u8, default: E) E {
    const want = k orelse return default;
    inline for (comptime std.enums.values(E)) |e| if (std.mem.eql(u8, e.key(), want)) return e;
    return default;
}

comptime {
    // A switch for every pref, and a pref for every switch.
    for (@typeInfo(Prefs).@"struct".field_names, std.enums.values(Flag)) |name, flag| {
        if (!std.mem.eql(u8, name, @tagName(flag))) @compileError("Flag and Prefs disagree at " ++ name);
    }
}

/// `sound_enabled` → `soundEnabled`.
pub fn camel(comptime name: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var up = false;
    inline for (name) |ch| {
        if (ch == '_') {
            up = true;
        } else {
            out = out ++ &[_]u8{if (up) std.ascii.toUpper(ch) else ch};
            up = false;
        }
    }
    return out;
}

/// The pin profile of a local workspace (`sidebar_pin_profile_key`).
const pin_profile = "local";

pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    /// The file, or none (scenes and tests keep settings in memory).
    path: ?[]u8 = null,
    prefs: Prefs = .{},
    section: Section = .devices,
    /// The file's other keys as last read or written: a choice, a number or
    /// a name a page shows (`text`, `number`).
    doc: std.StringArrayHashMapUnmanaged(json.Value) = .empty,
    /// `keymap`'s combinations by key, "jumpSession.N" for the nine slots.
    keymap: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// This device's pinned sessions in order: the "local" profile's
    /// `sidebarPinnedSessionIdsByProfile` (pins.zig).
    pins: std.ArrayList([]const u8) = .empty,
    doc_arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(s: *Store) void {
        if (s.path) |p| s.gpa.free(p);
        if (s.doc_arena) |*a| a.deinit();
    }

    /// A string the file holds under `key`, if it holds one.
    pub fn text(s: *const Store, key: []const u8) ?[]const u8 {
        const v = s.doc.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    /// A number the file holds under `key`, if it holds one.
    pub fn number(s: *const Store, key: []const u8) ?f64 {
        const v = s.doc.get(key) orelse return null;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => null,
        };
    }

    /// The accent preset's name, or null for the theme's own.
    pub fn accent(s: *const Store) ?[]const u8 {
        const v = s.text("accent") orelse return null;
        return if (std.mem.eql(u8, v, "themeDefault")) null else v;
    }

    pub fn setAccent(s: *Store, preset: ?[]const u8) void {
        s.remember("accent", .{ .string = preset orelse "themeDefault" });
        if (preset) |name| {
            var arena: std.heap.ArenaAllocator = .init(s.gpa);
            defer arena.deinit();
            var obj: json.ObjectMap = .empty;
            obj.put(arena.allocator(), "preset", .{ .string = name }) catch return;
            s.write("accent", .{ .object = obj });
        } else s.write("accent", .{ .string = "themeDefault" });
    }

    /// Harness's data folder, where the settings file is.
    pub fn dataDir(s: *const Store) ?[]const u8 {
        return std.fs.path.dirname(s.path orelse return null);
    }

    /// The variant picked for the appearance (`themeSelection`), by id.
    pub fn themeId(s: *const Store, dark: bool) []const u8 {
        return s.text(if (dark) "themeSelection.dark" else "themeSelection.light") orelse
            (if (dark) "codegraff-dark" else "codegraff-light");
    }

    /// Picks `id` for the appearance; the file keeps both, as the GPUI app
    /// writes them (`{"light": …, "dark": …}`).
    pub fn setTheme(s: *Store, dark: bool, id: []const u8) void {
        s.remember(if (dark) "themeSelection.dark" else "themeSelection.light", .{ .string = id });
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        var obj: json.ObjectMap = .empty;
        obj.put(arena.allocator(), "light", .{ .string = s.themeId(false) }) catch return;
        obj.put(arena.allocator(), "dark", .{ .string = s.themeId(true) }) catch return;
        s.write("themeSelection", .{ .object = obj });
    }

    pub fn setText(s: *Store, key: []const u8, value: []const u8) void {
        s.remember(key, .{ .string = value });
        s.write(key, .{ .string = value });
    }

    pub fn setNumber(s: *Store, key: []const u8, value: f64) void {
        const v: json.Value = if (@floor(value) == value and @abs(value) < 1e15) .{ .integer = @intFromFloat(value) } else .{ .float = value };
        s.remember(key, v);
        s.write(key, v);
    }

    fn rememberCombo(s: *Store, key: []const u8, slot: ?u8, keys: []const u8) void {
        if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
        const a = s.doc_arena.?.allocator();
        const k = (if (slot) |n| std.fmt.allocPrint(a, "{s}.{d}", .{ key, n }) else a.dupe(u8, key)) catch return;
        s.keymap.put(a, k, a.dupe(u8, keys) catch return) catch {};
    }

    /// The combination `sc` has: the file's, else its default.
    pub fn combo(s: *const Store, sc: shortcuts.Shortcut) []const u8 {
        var buf: [64]u8 = undefined;
        const k = if (sc.slot) |n| std.fmt.bufPrint(&buf, "{s}.{d}", .{ sc.key, n }) catch return sc.default else sc.key;
        return s.keymap.get(k) orelse sc.default;
    }

    /// Rebinds `sc` (null: back to its default), and writes the keymap whole
    /// as the GPUI app writes it.
    pub fn setCombo(s: *Store, sc: shortcuts.Shortcut, value: ?[]const u8) void {
        s.rememberCombo(sc.key, sc.slot, value orelse sc.default);
        s.writeKeymap();
    }

    /// Every shortcut back to its default.
    pub fn resetKeymap(s: *Store) void {
        for (shortcuts.all) |sc| s.rememberCombo(sc.key, sc.slot, sc.default);
        s.writeKeymap();
    }

    /// Whether any shortcut differs from its default.
    pub fn keymapChanged(s: *const Store) bool {
        for (shortcuts.all) |sc| if (!std.mem.eql(u8, s.combo(sc), sc.default)) return true;
        return false;
    }

    fn writeKeymap(s: *Store) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var obj: json.ObjectMap = .empty;
        // What this app doesn't show (an Appshot's key) as the file had it.
        obj.put(a, "captureAppshot", .{ .string = s.combo(shortcuts.appshot) }) catch return;
        var jump: json.Array = .init(a);
        for (shortcuts.all) |sc| {
            if (sc.slot != null) {
                jump.append(.{ .string = s.combo(sc) }) catch return;
            } else obj.put(a, sc.key, .{ .string = s.combo(sc) }) catch return;
        }
        obj.put(a, "jumpSession", .{ .array = jump }) catch return;
        s.write("keymap", .{ .object = obj });
    }

    /// The pins, replaced and written: only this profile's, the others as
    /// the file has them (an empty list drops the profile's key).
    pub fn setPins(s: *Store, list: []const []const u8) void {
        if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
        const a = s.doc_arena.?.allocator();
        var next: std.ArrayList([]const u8) = .empty;
        for (list) |id| next.append(a, a.dupe(u8, id) catch return) catch return;
        s.pins = next;
        const path = s.path orelse return;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        const body = std.Io.Dir.cwd().readFileAlloc(s.io, path, ar, .limited(8 << 20)) catch "{}";
        var byp: json.ObjectMap = .empty;
        if (json.parseFromSliceLeaky(json.Value, ar, body, .{})) |root| {
            if (root == .object) if (root.object.get("sidebarPinnedSessionIdsByProfile")) |v| if (v == .object) {
                byp = v.object;
            };
        } else |_| {}
        if (list.len == 0) {
            _ = byp.orderedRemove(pin_profile);
        } else {
            var arr: json.Array = .init(ar);
            for (list) |id| arr.append(.{ .string = id }) catch return;
            byp.put(ar, pin_profile, .{ .array = arr }) catch return;
        }
        s.write("sidebarPinnedSessionIdsByProfile", .{ .object = byp });
    }

    /// Keeps `value` (copied) as the file's `key`.
    fn remember(s: *Store, key: []const u8, value: json.Value) void {
        if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
        const a = s.doc_arena.?.allocator();
        const v: json.Value = switch (value) {
            .string => |str| .{ .string = a.dupe(u8, str) catch return },
            else => value,
        };
        const k = if (s.doc.getKey(key)) |have| have else a.dupe(u8, key) catch return;
        s.doc.put(a, k, v) catch {};
    }

    /// The file in Harness's data folder: `HARNESS_DATA_DIR`, else
    /// `~/.harness`.
    pub fn open(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) Store {
        var s: Store = .{ .gpa = gpa, .io = io };
        const path = if (env.get("HARNESS_DATA_DIR")) |d|
            std.fs.path.join(gpa, &.{ d, "ui-settings.json" })
        else if (env.get("HOME")) |h|
            std.fs.path.join(gpa, &.{ h, ".harness", "ui-settings.json" })
        else
            return s;
        s.path = path catch return s;
        s.load();
        return s;
    }

    /// Reads what the file says; what it doesn't say keeps its default.
    pub fn load(s: *Store) void {
        const path = s.path orelse return;
        const body = std.Io.Dir.cwd().readFileAlloc(s.io, path, s.gpa, .limited(8 << 20)) catch return;
        defer s.gpa.free(body);
        s.apply(body);
    }

    pub fn apply(s: *Store, body: []const u8) void {
        const parsed = json.parseFromSlice(json.Value, s.gpa, body, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const o = parsed.value.object;
        inline for (comptime std.enums.values(Flag)) |flag| {
            if (o.get(comptime camel(@tagName(flag)))) |v| if (v == .bool) {
                @field(s.prefs, @tagName(flag)) = v.bool;
            };
        }
        if (o.get("settingsSection")) |v| if (v == .string) if (Section.fromKey(v.string)) |sec| {
            s.section = sec;
        };
        if (o.get("keymap")) |km| if (km == .object) {
            var kit = km.object.iterator();
            while (kit.next()) |e| switch (e.value_ptr.*) {
                .string => |keys| s.rememberCombo(e.key_ptr.*, null, keys),
                .array => |arr| for (arr.items, 0..) |v, i| if (v == .string) s.rememberCombo(e.key_ptr.*, @intCast(i), v.string),
                else => {},
            };
        };
        if (o.get("sidebarPinnedSessionIdsByProfile")) |byp| if (byp == .object) if (byp.object.get(pin_profile)) |list| if (list == .array) {
            if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
            const a = s.doc_arena.?.allocator();
            s.pins = .empty;
            for (list.array.items) |v| if (v == .string) s.pins.append(a, a.dupe(u8, v.string) catch continue) catch {};
        };
        // `themeSelection`: {"light": id, "dark": id}, kept as two names.
        if (o.get("themeSelection")) |v| if (v == .object) {
            if (v.object.get("light")) |l| if (l == .string) s.remember("themeSelection.light", l);
            if (v.object.get("dark")) |d| if (d == .string) s.remember("themeSelection.dark", d);
        };
        // `accent`: "themeDefault", or {"preset": name}, kept as its name.
        if (o.get("accent")) |v| switch (v) {
            .string => s.remember("accent", v),
            .object => |obj| if (obj.get("preset")) |pre| if (pre == .string) s.remember("accent", pre),
            else => {},
        };
        // The scalars, for pages to read: strings and numbers.
        var it = o.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .string, .integer, .float => s.remember(e.key_ptr.*, e.value_ptr.*),
            else => {},
        };
    }

    pub fn get(s: *const Store, comptime flag: Flag) bool {
        return @field(s.prefs, @tagName(flag));
    }

    pub fn set(s: *Store, comptime flag: Flag, on: bool) void {
        @field(s.prefs, @tagName(flag)) = on;
        s.write(comptime camel(@tagName(flag)), .{ .bool = on });
    }

    pub fn toggle(s: *Store, comptime flag: Flag) void {
        s.set(flag, !s.get(flag));
    }

    pub fn organization(s: *const Store) Organization {
        return fromKey(Organization, s.text("sidebarOrganization"), .in_one_list);
    }

    pub fn sort(s: *const Store) Sort {
        return fromKey(Sort, s.text("sidebarSort"), .last_updated);
    }

    /// The sidebar's project filter (`spaceFilter`): a space's id, or all.
    pub fn spaceFilter(s: *const Store) ?[]const u8 {
        return s.text("spaceFilter");
    }

    pub fn setSpaceFilter(s: *Store, id: ?[]const u8) void {
        if (id) |v| return s.setText("spaceFilter", v);
        _ = s.doc.orderedRemove("spaceFilter");
        s.write("spaceFilter", .null);
    }

    /// The page last shown, for the next time Settings opens.
    pub fn setSection(s: *Store, sec: Section) void {
        s.section = sec;
        s.write("settingsSection", .{ .string = sec.key() });
    }

    /// Sets one key in the file as it is now (the other app may have
    /// written since), and swaps it in whole.
    fn write(s: *Store, key: []const u8, value: json.Value) void {
        const path = s.path orelse return;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const body = std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(8 << 20)) catch "{}";
        const out = merged(a, body, key, value) catch return;
        const tmp = std.fmt.allocPrint(a, "{s}.nano-tmp", .{path}) catch return;
        std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = tmp, .data = out }) catch return;
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, s.io) catch return;
    }
};

/// `text`'s object with `key` set to `value`, every other key as it was.
pub fn merged(a: Allocator, text: []const u8, key: []const u8, value: json.Value) ![]u8 {
    var root = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch json.Value{ .object = .empty };
    if (root != .object) root = .{ .object = .empty };
    try root.object.put(a, key, value);
    return json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
}

const testing = std.testing;

test "sections in the GPUI app's order, groups and saved keys" {
    try testing.expectEqual(Section.appearance, Section.all[0]);
    try testing.expectEqualStrings("Accounts", Section.agents.label());
    try testing.expectEqualStrings("Agents", Section.harnesses.label());
    try testing.expectEqualStrings("Devices and data", Section.archived.group());
    try testing.expectEqual(@as(?Section, .github_ci), Section.fromKey("github-ci"));
    try testing.expectEqual(@as(?Section, null), Section.fromKey("nope"));
    try testing.expectEqualStrings("soundCompletionEnabled", comptime camel("sound_completion_enabled"));
}

test "the file's switches are read, and a change keeps every other key" {
    var s: Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer s.deinit();
    s.apply(
        \\{"soundEnabled":false,"filesWordWrap":true,"settingsSection":"files","sidebarWidth":300}
    );
    try testing.expect(!s.get(.sound_enabled));
    try testing.expect(s.get(.files_word_wrap));
    try testing.expect(s.get(.notifications_enabled));
    try testing.expectEqual(Section.files, s.section);
    try testing.expectEqual(@as(?f64, 300), s.number("sidebarWidth"));
    try testing.expect(s.text("sidebarWidth") == null);
    s.setText("accent", "violet");
    try testing.expectEqualStrings("violet", s.text("accent").?);
    s.setNumber("transcriptWidth", 832);
    s.apply(
        \\{"keymap":{"saveFile":"mod-alt-s","jumpSession":["mod-1","ctrl-2"]}}
    );
    try testing.expectEqualStrings("mod-alt-s", s.combo(shortcuts.all[0]));
    try testing.expectEqualStrings("ctrl-2", s.combo(shortcuts.all[shortcuts.all.len - 8]));
    try testing.expectEqualStrings("mod-b", s.combo(shortcuts.all[2]));
    try testing.expect(s.keymapChanged());
    try testing.expectEqual(@as(?f64, 832), s.number("transcriptWidth"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try merged(arena.allocator(),
        \\{"sidebarWidth":300,"keymap":{"x":1},"soundEnabled":true}
    , "soundEnabled", .{ .bool = false });
    const back = try json.parseFromSliceLeaky(json.Value, arena.allocator(), out, .{});
    try testing.expectEqual(false, back.object.get("soundEnabled").?.bool);
    try testing.expectEqual(@as(i64, 300), back.object.get("sidebarWidth").?.integer);
    try testing.expect(back.object.get("keymap").? == .object);
    // A file that isn't there, or isn't JSON, starts from nothing.
    const fresh = try merged(arena.allocator(), "not json", "filesShowAll", .{ .bool = true });
    try testing.expect((try json.parseFromSliceLeaky(json.Value, arena.allocator(), fresh, .{})).object.get("filesShowAll").?.bool);
}

test "the sidebar's view options read as the GPUI app saves them" {
    var s: Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer s.deinit();
    try testing.expectEqual(Organization.in_one_list, s.organization());
    try testing.expectEqual(Sort.last_updated, s.sort());
    try testing.expect(s.get(.sidebar_compact) and s.get(.sidebar_show_archived));
    try testing.expect(s.spaceFilter() == null);
    s.apply(
        \\{"sidebarOrganization":"byProject","sidebarSort":"created","sidebarCompact":false,"spaceFilter":"s1"}
    );
    try testing.expectEqual(Organization.by_project, s.organization());
    try testing.expectEqual(Sort.created, s.sort());
    try testing.expect(!s.get(.sidebar_compact));
    try testing.expectEqualStrings("s1", s.spaceFilter().?);
    s.setSpaceFilter(null);
    try testing.expect(s.spaceFilter() == null);
    s.setText("sidebarOrganization", "nonsense");
    try testing.expectEqual(Organization.in_one_list, s.organization());
}
