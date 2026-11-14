//! The Settings page's sections (crates/ui/src/shell.rs `SettingsSection`),
//! and Nano's own settings file in Harness's data folder. Older Nano builds
//! shared `ui-settings.json` with the GPUI app; the first open copies those
//! preferences into `nano-ui-settings.json` once, so the two apps can keep
//! different sidebar and display choices without either rewriting the other.
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
    browsing,
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
            .browsing => "Links & browsing",
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
            .appearance, .notifications, .shortcuts, .files, .browsing => "General",
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
            .browsing => .global,
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
    attach_sound_enabled: bool = true,
    notifications_enabled: bool = true,
    notifications_background_only: bool = true,
    share_performance_stats: bool = true,
    /// Separate opt-in: the old timing-only switch never started Nano uploads.
    share_desktop_responsiveness: bool = false,
    files_autosave_enabled: bool = false,
    files_word_wrap: bool = false,
    files_show_all: bool = false,
    open_github_links_in_harness: bool = true,
    archive_sessions_on_close: bool = false,
    /// What ⌘W does to a session was chosen (`archive_on_close_chosen`).
    archive_on_close_chosen: bool = false,
    escape_stops_active_agent: bool = false,
    transcript_compact_mode: bool = true,
    pause_animations_in_background: bool = false,
    /// The Write page starts in the interface sans; Aa offers a serif.
    write_sans: bool = true,
    // Current desktop defaults: group by project; identity details stay quiet.
    sidebar_compact: bool = true,
    sidebar_show_project_icon: bool = false,
    sidebar_show_harness: bool = true,
    sidebar_show_updated: bool = true,
    sidebar_show_branch: bool = true,
    sidebar_show_project_label: bool = false,
    sidebar_show_archived: bool = true,
    // Settings › Appshots.
    appshots_enabled: bool = false,
    appshot_sound_enabled: bool = true,
    // Settings › Devices.
    restart_to_install_updates: bool = true,
};

/// One of `Prefs`'s switches.
pub const Flag = enum {
    sound_enabled,
    sound_completion_enabled,
    sound_input_enabled,
    sound_attention_enabled,
    attach_sound_enabled,
    notifications_enabled,
    notifications_background_only,
    share_performance_stats,
    share_desktop_responsiveness,
    files_autosave_enabled,
    files_word_wrap,
    files_show_all,
    open_github_links_in_harness,
    archive_sessions_on_close,
    archive_on_close_chosen,
    escape_stops_active_agent,
    transcript_compact_mode,
    pause_animations_in_background,
    write_sans,
    sidebar_compact,
    sidebar_show_project_icon,
    sidebar_show_harness,
    sidebar_show_updated,
    sidebar_show_branch,
    sidebar_show_project_label,
    sidebar_show_archived,
    appshots_enabled,
    appshot_sound_enabled,
    restart_to_install_updates,
};

pub const sidebar_min: f32 = 224;
pub const sidebar_max: f32 = 400;
pub const sidebar_default: f32 = sidebar_min;

/// A side panel's preferred width (`right_pane_width` in `ui_settings.rs`).
pub const right_pane_min: f32 = 360;
pub const right_pane_default: f32 = 520;

/// Interface text sizes (`UiFontSize::ALL` in `typography.rs`, 16px baseline).
pub const ui_font_sizes = [_]f32{ 12, 13, 14, 15, 16, 18, 20 };
pub const ui_font_size_default: f32 = 16;

pub fn normalizeUiFontSize(size: f32) f32 {
    if (!std.math.isFinite(size)) return ui_font_size_default;
    var best: f32 = ui_font_size_default;
    var best_diff: f32 = std.math.inf(f32);
    for (ui_font_sizes) |candidate| {
        const diff = @abs(candidate - size);
        if (diff < best_diff) {
            best_diff = diff;
            best = candidate;
        }
    }
    return best;
}

/// The next supported interface text size up (`step > 0`) or down (`step < 0`),
/// held at the ends (`UiFontSize::stepped`).
pub fn stepUiFontSize(size: f32, step: i32) f32 {
    const norm = normalizeUiFontSize(size);
    var at: i32 = 4;
    for (ui_font_sizes, 0..) |candidate, idx| {
        if (candidate == norm) {
            at = @intCast(idx);
            break;
        }
    }
    const last: i32 = @intCast(ui_font_sizes.len - 1);
    const next_ix: usize = @intCast(std.math.clamp(at + step, 0, last));
    return ui_font_sizes[next_ix];
}

/// The desktop's first-window size (`lib.rs`, 1320×880).
pub const window_default_width: f64 = 1320;
pub const window_default_height: f64 = 880;

/// `WindowGeometry` in Nano's settings file (copied once from the old shared
/// ui-settings file). Nano restores its size,
/// while the centered placement stays AppKit's so a disconnected display
/// cannot put the window off screen.
pub const WindowGeometry = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    fn valid(g: WindowGeometry) bool {
        return std.math.isFinite(g.x) and std.math.isFinite(g.y) and
            std.math.isFinite(g.width) and std.math.isFinite(g.height) and
            g.width > 0 and g.height > 0;
    }
};

/// How the sidebar groups sessions (`SidebarOrganization`), as saved.
pub const Organization = enum {
    by_device,
    by_project,
    in_one_list,
    /// Optional attention grouping: "Needs you", "Today" and "Earlier".
    by_status,

    pub fn key(o: Organization) []const u8 {
        return switch (o) {
            .by_device => "byDevice",
            .by_project => "byProject",
            .in_one_list => "inOneList",
            .by_status => "byStatus",
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

/// How far back the sidebar shows recent sessions (`sidebarLastActivity`).
pub const LastActivity = enum {
    d1,
    d3,
    d7,
    d30,
    all,

    pub fn key(o: LastActivity) []const u8 {
        return switch (o) {
            .d1 => "1d",
            .d3 => "3d",
            .d7 => "7d",
            .d30 => "30d",
            .all => "all",
        };
    }

    pub fn label(o: LastActivity) []const u8 {
        return switch (o) {
            .d1 => "1d",
            .d3 => "3d",
            .d7 => "7d",
            .d30 => "30d",
            .all => "All",
        };
    }

    pub fn windowMs(o: LastActivity) ?i64 {
        const day_ms: i64 = 24 * 60 * 60 * 1000;
        return switch (o) {
            .d1 => 1 * day_ms,
            .d3 => 3 * day_ms,
            .d7 => 7 * day_ms,
            .d30 => 30 * day_ms,
            .all => null,
        };
    }

    pub fn matches(o: LastActivity, chat_ms: i64, now_ms: i64) bool {
        const window = o.windowMs() orelse return true;
        if (chat_ms <= 0 or now_ms <= 0) return true;
        return now_ms -| chat_ms <= window;
    }
};

/// A new install shows less (`UiSettings::first_run`): a turn's tool steps
/// fold into one line and sidebar rows drop branch names. Both stay one
/// toggle away, and an existing settings file keeps what it chose.
pub fn firstRun() Prefs {
    var p: Prefs = .{};
    p.sidebar_show_branch = false;
    return p;
}

fn fromKey(comptime E: type, k: ?[]const u8, default: E) E {
    const want = k orelse return default;
    inline for (comptime std.enums.values(E)) |e| if (std.mem.eql(u8, e.key(), want)) return e;
    return default;
}

fn jsonNumber(v: ?json.Value) ?f64 {
    return switch (v orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
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

/// Nano's preferences live beside Harness's, not inside them.
const settings_file = "nano-ui-settings.json";
/// The file older Nano builds shared with the GPUI app.
const legacy_settings_file = "ui-settings.json";

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
    /// The GPUI app's `openTabs`: chats opened as tabs, in visual order.
    open_tabs: std.ArrayList([]const u8) = .empty,
    doc_arena: ?std.heap.ArenaAllocator = null,
    /// The file wasn't there to read: a first run (view_setup.zig).
    fresh: bool = false,

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
        return jsonNumber(s.doc.get(key));
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
        if (std.mem.eql(u8, key, "followUpBehavior")) {
            s.writeMany(&.{
                .{ .key = key, .value = .{ .string = value } },
                .{ .key = followup_default_key, .value = .{ .bool = true } },
            });
            return;
        }
        s.write(key, .{ .string = value });
    }

    pub fn clearText(s: *Store, key: []const u8) void {
        _ = s.doc.orderedRemove(key);
        s.write(key, .null);
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

    /// The open chat tabs, as the GPUI app stores them: `openTabs` in visual
    /// order and `lastChatId` for the active one. Other keys stay as they are.
    pub fn setOpenTabs(s: *Store, ids: []const []const u8, active: ?[]const u8) void {
        if (!s.updateOpenTabs(ids, active)) return;
        s.flushOpenTabsAndLayout();
    }

    pub fn updateOpenTabs(s: *Store, ids: []const []const u8, active: ?[]const u8) bool {
        var same = s.open_tabs.items.len == ids.len;
        if (same) for (s.open_tabs.items, ids) |have, want| {
            if (!std.mem.eql(u8, have, want)) {
                same = false;
                break;
            }
        };
        if (same) {
            const last = s.text("lastChatId");
            if ((active == null and last == null) or
                (active != null and last != null and std.mem.eql(u8, active.?, last.?)))
                return false;
        }
        if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
        const a = s.doc_arena.?.allocator();
        s.open_tabs = .empty;
        for (ids) |id| s.open_tabs.append(a, a.dupe(u8, id) catch return false) catch return false;
        if (active) |id| s.remember("lastChatId", .{ .string = id }) else _ = s.doc.orderedRemove("lastChatId");
        return true;
    }

    /// Nano's tab-split layout. Kept beside the shared `openTabs` so Nano
    /// can reopen panes, shares, focus and panel tabs without rewriting the
    /// desktop's richer `workspaceWindows` records.
    pub fn tabLayout(s: *const Store) ?[]const u8 {
        return s.text("nanoTabLayout");
    }

    pub fn setTabLayout(s: *Store, body: []const u8) void {
        if (!s.updateTabLayout(body)) return;
        s.write("nanoTabLayout", .{ .string = body });
    }

    pub fn updateTabLayout(s: *Store, body: []const u8) bool {
        if (s.text("nanoTabLayout")) |old| if (std.mem.eql(u8, old, body)) return false;
        s.remember("nanoTabLayout", .{ .string = body });
        return true;
    }

    pub fn flushOpenTabsAndLayout(s: *Store) void {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const ar = arena.allocator();
        var tabs: json.Array = .init(ar);
        for (s.open_tabs.items) |id| tabs.append(.{ .string = id }) catch return;
        const active = s.text("lastChatId");
        if (s.text("nanoTabLayout")) |layout_body| {
            s.writeMany(&.{
                .{ .key = "openTabs", .value = .{ .array = tabs } },
                .{ .key = "lastChatId", .value = if (active) |id| .{ .string = id } else .null },
                .{ .key = "nanoTabLayout", .value = .{ .string = layout_body } },
            });
        } else {
            s.writeMany(&.{
                .{ .key = "openTabs", .value = .{ .array = tabs } },
                .{ .key = "lastChatId", .value = if (active) |id| .{ .string = id } else .null },
            });
        }
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
        if (env.get("HARNESS_DATA_DIR")) |dir| return openIn(gpa, io, dir);
        if (env.get("HOME")) |home| {
            const dir = std.fs.path.join(gpa, &.{ home, ".harness" }) catch return .{ .gpa = gpa, .io = io };
            defer gpa.free(dir);
            return openIn(gpa, io, dir);
        }
        return .{ .gpa = gpa, .io = io };
    }

    /// Opens Nano's own file in `dir`. On first run after the split, adopts
    /// the old shared document once, but starts its own grouping at the
    /// current default instead of inheriting Harness's flat/collapsed choice.
    fn openIn(gpa: Allocator, io: std.Io, dir: []const u8) Store {
        var s: Store = .{ .gpa = gpa, .io = io };
        s.path = std.fs.path.join(gpa, &.{ dir, settings_file }) catch return s;
        s.load();
        if (s.fresh) s.adoptShared(io, dir);
        return s;
    }

    fn adoptShared(s: *Store, io: std.Io, dir: []const u8) void {
        const shared = std.fs.path.join(s.gpa, &.{ dir, legacy_settings_file }) catch return;
        defer s.gpa.free(shared);
        const raw = std.Io.Dir.cwd().readFileAlloc(io, shared, s.gpa, .limited(8 << 20)) catch return;
        defer s.gpa.free(raw);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var root = json.parseFromSliceLeaky(json.Value, a, raw, .{}) catch return;
        if (root != .object) return;
        root.object.put(a, "sidebarOrganization", .{ .string = Organization.by_project.key() }) catch return;
        const body = json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 }) catch return;
        // The session uses the migrated choices even if the first write fails;
        // the next launch retries the copy from the still-shared document.
        s.apply(body);
        if (!compactDefaultApplied(body)) s.prefs.transcript_compact_mode = true;
        s.fresh = false;
        const own = s.path orelse return;
        const tmp = std.fmt.allocPrint(a, "{s}.nano-tmp", .{own}) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = body }) catch return;
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), own, io) catch {};
    }

    /// Reads what the file says; what it doesn't say keeps its default.
    pub fn load(s: *Store) void {
        const path = s.path orelse return;
        const body = std.Io.Dir.cwd().readFileAlloc(s.io, path, s.gpa, .limited(8 << 20)) catch {
            s.fresh = true;
            s.prefs = firstRun();
            return;
        };
        defer s.gpa.free(body);
        s.apply(body);
        // Compact mode is the default now (`transcript_compact_default_applied`):
        // a file from before it was turns it on once, whatever it said.
        if (!compactDefaultApplied(body)) s.set(.transcript_compact_mode, true);
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
        if (o.get("openTabs")) |v| if (v == .array) {
            if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
            const a = s.doc_arena.?.allocator();
            s.open_tabs = .empty;
            for (v.array.items) |id| if (id == .string) s.open_tabs.append(a, a.dupe(u8, id.string) catch continue) catch {};
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
        // New project shares the desktop's per-device starting-folder history.
        if (o.get("projectFoldersByDevice")) |v| {
            if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
            const a = s.doc_arena.?.allocator();
            const body_copy = json.Stringify.valueAlloc(a, v, .{}) catch return;
            const copy = json.parseFromSliceLeaky(json.Value, a, body_copy, .{}) catch return;
            s.remember("projectFoldersByDevice", copy);
        }
        // The scalars, for pages to read: strings and numbers.
        var it = o.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .string, .integer, .float => s.remember(e.key_ptr.*, e.value_ptr.*),
            else => {},
        };
        // Pre-GPT-6.0+ files wrote `"followUpBehavior": "queue"` as the
        // struct default; drop that unchosen default so Codex / GPT-6.0+
        // models steer by default until the user picks a mode explicitly.
        if (!followUpDefaultApplied(body)) {
            if (s.text("followUpBehavior")) |v| if (std.mem.eql(u8, v, "queue")) {
                _ = s.doc.orderedRemove("followUpBehavior");
            };
        }
    }

    pub fn get(s: *const Store, comptime flag: Flag) bool {
        return @field(s.prefs, @tagName(flag));
    }

    pub fn set(s: *Store, comptime flag: Flag, on: bool) void {
        @field(s.prefs, @tagName(flag)) = on;
        s.write(comptime camel(@tagName(flag)), .{ .bool = on });
        // A choice made from here on is kept: the one-time switch is done.
        if (flag == .transcript_compact_mode) s.write(compact_default_key, .{ .bool = true });
        // The switch and the first-close question both count as the choice
        // (`set_archive_sessions_on_close`).
        if (flag == .archive_sessions_on_close and !s.prefs.archive_on_close_chosen) s.set(.archive_on_close_chosen, true);
    }

    pub fn toggle(s: *Store, comptime flag: Flag) void {
        s.set(flag, !s.get(flag));
    }

    /// Experience mode from the Lean 4 state machine (`motion_rules.zig:UiMode`):
    /// Live disk-backed stores (`s.path != null`) default to `.zen` ("for normies"),
    /// while in-memory test stores (`s.path == null`) default to `.developer` unless
    /// explicitly switched with `applyUiMode`.
    pub fn baseUiMode(s: *const Store) @import("motion_rules.zig").UiMode {
        const rules = @import("motion_rules.zig");
        if (s.text("uiMode")) |raw| {
            if (std.mem.eql(u8, raw, "zen")) return .zen;
            if (std.mem.eql(u8, raw, "developer")) return .developer;
        }
        return if (s.path != null) rules.UiState.initial.mode else .developer;
    }

    pub fn hierarchyProfile(s: *const Store) @import("motion_rules.zig").HierarchyProfile {
        const rules = @import("motion_rules.zig");
        var p = rules.HierarchyProfile.ofMode(s.baseUiMode());
        for (rules.MovingPart.all) |part| {
            if (s.text(part.key())) |raw| {
                if (std.mem.eql(u8, raw, "on")) p = p.setPart(part, true);
                if (std.mem.eql(u8, raw, "off")) p = p.setPart(part, false);
            }
        }
        return p;
    }

    pub fn uiMode(s: *const Store) @import("motion_rules.zig").UiMode {
        return s.hierarchyProfile().effectiveMode();
    }

    pub fn applyUiMode(s: *Store, mode: @import("motion_rules.zig").UiMode) void {
        const rules = @import("motion_rules.zig");
        for (rules.MovingPart.all) |part| s.clearText(part.key());
        s.setText("uiMode", mode.key());
        switch (mode) {
            .zen => {
                s.setText("sidebarOrganization", Organization.in_one_list.key());
                s.set(.sidebar_show_harness, true);
                s.set(.sidebar_show_project_icon, true);
                s.set(.sidebar_show_branch, false);
                s.set(.sidebar_show_project_label, false);
            },
            .developer => {
                s.setText("sidebarOrganization", Organization.by_project.key());
                s.set(.sidebar_show_harness, true);
                s.set(.sidebar_show_branch, true);
            },
        }
    }

    pub fn toggleMovingPart(s: *Store, part: @import("motion_rules.zig").MovingPart) void {
        const next = !s.hierarchyProfile().partEnabled(part);
        s.setText(part.key(), if (next) "on" else "off");
        switch (part) {
            .grouped_sections => s.setText("sidebarOrganization", if (next) Organization.by_project.key() else Organization.in_one_list.key()),
            .row_tech_badges => {
                s.set(.sidebar_show_harness, next);
                s.set(.sidebar_show_branch, next);
            },
            else => {},
        }
    }

    pub fn toggleUiMode(s: *Store) void {
        const rules = @import("motion_rules.zig");
        const next = rules.stepUiState(.{ .mode = s.uiMode() }, .toggle_mode).mode;
        s.applyUiMode(next);
    }

    pub fn organization(s: *const Store) Organization {
        return fromKey(Organization, s.text("sidebarOrganization"), .by_project);
    }

    /// Shared desktop bounds; invalid saved values use the desktop default.
    pub fn sidebarWidth(s: *const Store) f32 {
        const value = s.number("sidebarWidth") orelse return sidebar_default;
        if (!std.math.isFinite(value)) return sidebar_default;
        return @floatCast(std.math.clamp(value, sidebar_min, sidebar_max));
    }

    pub fn rightPaneWidth(s: *const Store) f32 {
        const value = s.number("rightPaneWidth") orelse return right_pane_default;
        if (!std.math.isFinite(value)) return right_pane_default;
        return @max(right_pane_min, @as(f32, @floatCast(value)));
    }

    pub fn uiFontSize(s: *const Store) f32 {
        const value = s.number("uiFontSize") orelse return ui_font_size_default;
        if (!std.math.isFinite(value)) return ui_font_size_default;
        return normalizeUiFontSize(@floatCast(value));
    }

    pub fn setUiFontSize(s: *Store, size: f32) void {
        s.setNumber("uiFontSize", normalizeUiFontSize(size));
    }

    /// The desktop window's last saved size, or the desktop's same first-run
    /// size. Position is intentionally left to AppKit's centering here.
    pub fn windowSize(s: *const Store) struct { width: f64, height: f64 } {
        const fallback: @TypeOf(s.windowSize()) = .{ .width = window_default_width, .height = window_default_height };
        const v = s.doc.get("windowGeometry") orelse return fallback;
        if (v != .object) return fallback;
        const geo = WindowGeometry{
            .x = jsonNumber(v.object.get("x")) orelse return fallback,
            .y = jsonNumber(v.object.get("y")) orelse return fallback,
            .width = jsonNumber(v.object.get("width")) orelse return fallback,
            .height = jsonNumber(v.object.get("height")) orelse return fallback,
        };
        if (!geo.valid()) return fallback;
        return .{ .width = geo.width, .height = geo.height };
    }

    pub fn sort(s: *const Store) Sort {
        return fromKey(Sort, s.text("sidebarSort"), .last_updated);
    }

    pub fn lastActivity(s: *const Store) LastActivity {
        return fromKey(LastActivity, s.text("sidebarLastActivity"), .all);
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

    pub fn projectFolderOverride(s: *const Store, device: []const u8) ?[]const u8 {
        const root = s.doc.get("projectFoldersByDevice") orelse return null;
        if (root != .object) return null;
        const pref = root.object.get(device) orelse return null;
        if (pref != .object) return null;
        const value = pref.object.get("overridePath") orelse return null;
        if (value != .string or !@import("project_paths.zig").valid(value.string)) return null;
        return value.string;
    }

    /// Only confirmation changes a host's override; resetting preserves its learned history.
    pub fn setProjectFolderOverride(s: *Store, device: []const u8, path: ?[]const u8) bool {
        if (device.len == 0) return false;
        if (path) |value| if (!@import("project_paths.zig").valid(value)) return false;
        if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
        const a = s.doc_arena.?.allocator();
        var root = s.doc.get("projectFoldersByDevice") orelse json.Value{ .object = .empty };
        if (root != .object) root = .{ .object = .empty };
        var pref = root.object.get(device) orelse json.Value{ .object = .empty };
        if (pref != .object) pref = .{ .object = .empty };
        if (path) |value| {
            const copy = a.dupe(u8, std.mem.trim(u8, value, " \t\r\n")) catch return false;
            pref.object.put(a, "overridePath", .{ .string = copy }) catch return false;
        } else {
            _ = pref.object.orderedRemove("overridePath");
        }
        root.object.put(a, a.dupe(u8, device) catch return false, pref) catch return false;
        s.remember("projectFoldersByDevice", root);
        s.write("projectFoldersByDevice", root);
        return true;
    }

    /// Record only acknowledged project creation, as the desktop does.
    pub fn recordProjectFolder(s: *Store, device: []const u8, path: []const u8, spaces: []const @import("workspace.zig").Space) void {
        if (s.doc_arena == null) s.doc_arena = .init(s.gpa);
        const a = s.doc_arena.?.allocator();
        var root = s.doc.get("projectFoldersByDevice") orelse json.Value{ .object = .empty };
        if (root != .object) root = .{ .object = .empty };
        var pref = root.object.get(device) orelse json.Value{ .object = .empty };
        if (pref != .object) pref = .{ .object = .empty };
        var counts = pref.object.get("parentCounts") orelse json.Value{ .object = .empty };
        if (counts != .object) counts = .{ .object = .empty };
        const parent_path = @import("project_paths.zig").parent;
        if (counts.object.count() == 0) {
            // spaces already includes the newly acknowledged row. Seed once,
            // so that row is counted once rather than seeded and added twice.
            for (spaces) |space| {
                if (!std.mem.eql(u8, space.device_id orelse continue, device)) continue;
                const p = parent_path(space.path) orelse continue;
                const key = a.dupe(u8, p) catch return;
                std.mem.replaceScalar(u8, key, '\\', '/');
                const old = counts.object.get(key);
                const n: i64 = if (old) |v| (if (v == .integer) @max(0, v.integer) else 0) else 0;
                counts.object.put(a, key, .{ .integer = n +| 1 }) catch return;
            }
        } else if (parent_path(path)) |p| {
            const key = a.dupe(u8, p) catch return;
            std.mem.replaceScalar(u8, key, '\\', '/');
            const old = counts.object.get(key);
            const n: i64 = if (old) |v| (if (v == .integer) @max(0, v.integer) else 0) else 0;
            counts.object.put(a, key, .{ .integer = n +| 1 }) catch return;
        }
        pref.object.put(a, "parentCounts", counts) catch return;
        root.object.put(a, a.dupe(u8, device) catch return, pref) catch return;
        s.remember("projectFoldersByDevice", root);
        s.write("projectFoldersByDevice", root);
    }

    /// The page last shown, for the next time Settings opens.
    pub fn setSection(s: *Store, sec: Section) void {
        s.section = sec;
        s.write("settingsSection", .{ .string = sec.key() });
    }

    /// Sets one key in the file as it is now (the other app may have
    /// written since), and swaps it in whole.
    fn write(s: *Store, key: []const u8, value: json.Value) void {
        s.writeMany(&.{.{ .key = key, .value = value }});
    }

    /// Several keys in one atomic replacement, for state whose parts must
    /// agree (the open tabs and which one is active).
    fn writeMany(s: *Store, entries: []const WriteEntry) void {
        const path = s.path orelse return;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const body = std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(8 << 20)) catch "{}";
        const out = mergedEntries(a, body, entries) catch return;
        const tmp = std.fmt.allocPrint(a, "{s}.nano-tmp", .{path}) catch return;
        std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = tmp, .data = out }) catch return;
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, s.io) catch return;
    }
};

const WriteEntry = struct { key: []const u8, value: json.Value };

/// The GPUI app's marker that compact mode's new default was applied.
const compact_default_key = "transcriptCompactDefaultApplied";
const followup_default_key = "followUpGpt6DefaultApplied";

fn followUpDefaultApplied(body: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const v = json.parseFromSliceLeaky(json.Value, arena.allocator(), body, .{}) catch return true;
    if (v != .object) return true;
    const m = v.object.get(followup_default_key) orelse return false;
    return m == .bool and m.bool;
}

/// Whether the file `body` already had compact mode's default applied.
fn compactDefaultApplied(body: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const v = json.parseFromSliceLeaky(json.Value, arena.allocator(), body, .{}) catch return true;
    if (v != .object) return true;
    const m = v.object.get(compact_default_key) orelse return false;
    return m == .bool and m.bool;
}

/// `text`'s object with each entry set, every other key as it was.
fn mergedEntries(a: Allocator, text: []const u8, entries: []const WriteEntry) ![]u8 {
    var root = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch json.Value{ .object = .empty };
    if (root != .object) root = .{ .object = .empty };
    for (entries) |entry| try root.object.put(a, entry.key, entry.value);
    return json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
}

/// `text`'s object with `key` set to `value`, every other key as it was.
pub fn merged(a: Allocator, text: []const u8, key: []const u8, value: json.Value) ![]u8 {
    return mergedEntries(a, text, &.{.{ .key = key, .value = value }});
}

const testing = std.testing;

test "Nano keeps its own settings and starts by project without rewriting Harness's file" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const shared_body =
        \\{"sidebarOrganization":"inOneList","soundEnabled":false,"themeSelection":{"light":"synthetic-light","dark":"synthetic-dark"},"syntheticKeep":17}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = legacy_settings_file, .data = shared_body });
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    var s = Store.openIn(testing.allocator, io, base);
    defer s.deinit();
    try testing.expect(!s.fresh);
    try testing.expectEqual(Organization.by_project, s.organization());
    try testing.expect(!s.get(.sound_enabled));
    try testing.expectEqualStrings("synthetic-light", s.themeId(false));
    try testing.expectEqualStrings("synthetic-dark", s.themeId(true));
    try testing.expectEqualStrings(settings_file, std.fs.path.basename(s.path.?));

    const own = try std.fs.path.join(a, &.{ base, settings_file });
    const migrated = try std.Io.Dir.cwd().readFileAlloc(io, own, a, .limited(1 << 20));
    const back = try json.parseFromSliceLeaky(json.Value, a, migrated, .{});
    try testing.expectEqualStrings("byProject", back.object.get("sidebarOrganization").?.string);
    try testing.expectEqual(@as(i64, 17), back.object.get("syntheticKeep").?.integer);
    try testing.expectEqualStrings("synthetic-light", back.object.get("themeSelection").?.object.get("light").?.string);
    const shared = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ base, legacy_settings_file }), a, .limited(1 << 20));
    try testing.expectEqualStrings(shared_body, shared);

    s.setText("sidebarOrganization", "byDevice");
    const changed = try std.Io.Dir.cwd().readFileAlloc(io, own, a, .limited(1 << 20));
    const own_back = try json.parseFromSliceLeaky(json.Value, a, changed, .{});
    try testing.expectEqualStrings("byDevice", own_back.object.get("sidebarOrganization").?.string);
    const shared_again = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ base, legacy_settings_file }), a, .limited(1 << 20));
    try testing.expectEqualStrings(shared_body, shared_again);

    var restored = Store.openIn(testing.allocator, io, base);
    defer restored.deinit();
    try testing.expectEqual(Organization.by_device, restored.organization());
    try testing.expect(!restored.get(.sound_enabled));
}

test "sections in the GPUI app's order, groups and saved keys" {
    try testing.expectEqual(Section.appearance, Section.all[0]);
    try testing.expectEqual(Section.files, Section.all[3]);
    try testing.expectEqual(Section.browsing, Section.all[4]);
    try testing.expectEqualStrings("Links & browsing", Section.browsing.label());
    try testing.expectEqualStrings("General", Section.browsing.group());
    try testing.expectEqual(icons.Name.global, Section.browsing.icon());
    try testing.expectEqual(@as(?Section, .browsing), Section.fromKey("browsing"));
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

test "a new install shows less; an existing file keeps its choices (missing_and_corrupt_files_yield_defaults)" {
    var s: Store = .{ .gpa = testing.allocator, .io = testing.io, .path = try testing.allocator.dupe(u8, "/nonexistent/harness-nano-test/ui-settings.json") };
    defer s.deinit();
    s.load();
    try testing.expect(s.fresh);
    try testing.expect(s.get(.transcript_compact_mode) and !s.get(.sidebar_show_branch));
    try testing.expectEqual(Organization.by_project, s.organization());
    var old: Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer old.deinit();
    old.apply("{}");
    try testing.expect(old.get(.transcript_compact_mode) and old.get(.sidebar_show_branch));
}

test "Write face loads and persists the shared writeSans boolean without replacing other settings" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ui-settings.json", .data = "{\"writeSans\":false,\"syntheticKeep\":17,\"transcriptCompactDefaultApplied\":true}" });
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    const path = try std.fs.path.join(a, &.{ base, "ui-settings.json" });
    var s: Store = .{ .gpa = testing.allocator, .io = io, .path = try testing.allocator.dupe(u8, path) };
    defer s.deinit();
    try testing.expect(s.get(.write_sans));
    s.load();
    try testing.expect(!s.get(.write_sans));
    s.toggle(.write_sans);
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    const back = try json.parseFromSliceLeaky(json.Value, a, saved, .{});
    try testing.expect(back.object.get("writeSans").?.bool);
    try testing.expectEqual(@as(i64, 17), back.object.get("syntheticKeep").?.integer);
    var restored: Store = .{ .gpa = testing.allocator, .io = io };
    defer restored.deinit();
    restored.apply(saved);
    try testing.expect(restored.get(.write_sans));
}

test "github links preference defaults on and persists both choices without replacing other settings" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = settings_file, .data = "{\"syntheticKeep\":17,\"transcriptCompactDefaultApplied\":true}" });
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    var s = Store.openIn(testing.allocator, io, base);
    defer s.deinit();
    try testing.expect(s.get(.open_github_links_in_harness));
    for ([_]bool{ false, true }) |on| {
        s.set(.open_github_links_in_harness, on);
        const saved = try std.Io.Dir.cwd().readFileAlloc(io, s.path.?, a, .limited(1 << 20));
        const back = try json.parseFromSliceLeaky(json.Value, a, saved, .{});
        try testing.expectEqual(on, back.object.get("openGithubLinksInHarness").?.bool);
        try testing.expectEqual(@as(i64, 17), back.object.get("syntheticKeep").?.integer);
        var restored = Store.openIn(testing.allocator, io, base);
        defer restored.deinit();
        try testing.expectEqual(on, restored.get(.open_github_links_in_harness));
    }
}

test "compact mode turns on once for a file written before it was the default, then keeps the choice" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ui-settings.json", .data = "{\"transcriptCompactMode\":false,\"sidebarWidth\":300}" });
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    const path = try std.fs.path.join(a, &.{ base, "ui-settings.json" });
    {
        var s: Store = .{ .gpa = testing.allocator, .io = io, .path = try testing.allocator.dupe(u8, path) };
        defer s.deinit();
        s.load();
        try testing.expect(s.get(.transcript_compact_mode));
        try testing.expectEqual(@as(?f64, 300), s.number("sidebarWidth"));
        // Turned off after that, in Settings.
        s.toggle(.transcript_compact_mode);
    }
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    const back = try json.parseFromSliceLeaky(json.Value, a, saved, .{});
    try testing.expect(back.object.get(compact_default_key).?.bool);
    try testing.expectEqual(@as(i64, 300), back.object.get("sidebarWidth").?.integer);
    var again: Store = .{ .gpa = testing.allocator, .io = io, .path = try testing.allocator.dupe(u8, path) };
    defer again.deinit();
    again.load();
    try testing.expect(!again.get(.transcript_compact_mode));
}

test "Rust sidebar organization choices survive unrelated settings writes and reloads" {
    const io = testing.io;
    const cases = [_]Organization{ .by_project, .by_device, .in_one_list, .by_status };
    for (cases) |organization| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const body = try std.fmt.allocPrint(a,
            \\{{"sidebarOrganization":"{s}","sidebarGrouped":false,"syntheticKeep":17,"transcriptCompactDefaultApplied":true}}
        , .{organization.key()});
        try tmp.dir.writeFile(io, .{ .sub_path = "ui-settings.json", .data = body });
        const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
        const path = try std.fs.path.join(a, &.{ base, "ui-settings.json" });
        var s: Store = .{ .gpa = testing.allocator, .io = io, .path = try testing.allocator.dupe(u8, path) };
        defer s.deinit();
        s.load();
        try testing.expectEqual(organization, s.organization());
        s.toggle(.sidebar_show_project_icon);
        s.toggle(.sidebar_show_branch);
        s.setSpaceFilter("synthetic-project");
        s.setPins(&.{"synthetic-pin"});
        const saved = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
        const back = try json.parseFromSliceLeaky(json.Value, a, saved, .{});
        try testing.expectEqualStrings(organization.key(), back.object.get("sidebarOrganization").?.string);
        try testing.expectEqual(@as(i64, 17), back.object.get("syntheticKeep").?.integer);
        var restored: Store = .{ .gpa = testing.allocator, .io = io, .path = try testing.allocator.dupe(u8, path) };
        defer restored.deinit();
        restored.load();
        try testing.expectEqual(organization, restored.organization());
        try testing.expectEqual(s.get(.sidebar_show_project_icon), restored.get(.sidebar_show_project_icon));
        try testing.expectEqual(s.get(.sidebar_show_branch), restored.get(.sidebar_show_branch));
        try testing.expectEqualStrings("synthetic-project", restored.spaceFilter().?);
        try testing.expectEqualStrings("synthetic-pin", restored.pins.items[0]);
    }
}

test "GPUI open tabs and their active chat survive unrelated settings writes" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ui-settings.json", .data =
        \\{"openTabs":["synthetic-a","synthetic-b"],"lastChatId":"synthetic-b","syntheticKeep":17}
    });
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    const path = try std.fs.path.join(a, &.{ base, "ui-settings.json" });
    var s: Store = .{ .gpa = testing.allocator, .io = io, .path = try testing.allocator.dupe(u8, path) };
    defer s.deinit();
    s.load();
    try testing.expectEqual(@as(usize, 2), s.open_tabs.items.len);
    try testing.expectEqualStrings("synthetic-a", s.open_tabs.items[0]);
    try testing.expectEqualStrings("synthetic-b", s.text("lastChatId").?);
    s.toggle(.sidebar_show_branch);
    s.setOpenTabs(&.{ "synthetic-b", "synthetic-c" }, "synthetic-c");
    const saved = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20));
    const back = try json.parseFromSliceLeaky(json.Value, a, saved, .{});
    try testing.expectEqual(@as(i64, 17), back.object.get("syntheticKeep").?.integer);
    try testing.expectEqualStrings("synthetic-c", back.object.get("lastChatId").?.string);
    try testing.expectEqualStrings("synthetic-b", back.object.get("openTabs").?.array.items[0].string);
    var restored: Store = .{ .gpa = testing.allocator, .io = io, .path = try testing.allocator.dupe(u8, path) };
    defer restored.deinit();
    restored.load();
    try testing.expectEqual(@as(usize, 2), restored.open_tabs.items.len);
    try testing.expectEqualStrings("synthetic-c", restored.open_tabs.items[1]);
    try testing.expectEqualStrings("synthetic-c", restored.text("lastChatId").?);
}

test "the sidebar's view options read as the GPUI app saves them" {
    var s: Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer s.deinit();
    try testing.expectEqual(Organization.by_project, s.organization());
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
    try testing.expectEqual(Organization.by_project, s.organization());
    s.setText("sidebarOrganization", "inOneList");
    try testing.expectEqual(Organization.in_one_list, s.organization());
}

test "the window reopens at the desktop's saved size and falls back safely" {
    var s: Store = .{ .gpa = testing.allocator, .io = testing.io };
    defer s.deinit();
    var size = s.windowSize();
    try testing.expectEqual(window_default_width, size.width);
    try testing.expectEqual(window_default_height, size.height);
    s.apply(
        \\{"windowGeometry":{"displayUuid":"synthetic-display","x":300,"y":100,"width":1320,"height":880}}
    );
    size = s.windowSize();
    try testing.expectEqual(@as(f64, 1320), size.width);
    try testing.expectEqual(@as(f64, 880), size.height);
    for ([_][]const u8{
        \\{"windowGeometry":{"x":0,"y":0,"width":0,"height":880}}
        ,
        \\{"windowGeometry":{"x":"0","y":0,"width":1200,"height":780}}
        ,
        \\{"windowGeometry":[]}
        ,
    }) |body| {
        s.apply(body);
        size = s.windowSize();
        try testing.expectEqual(window_default_width, size.width);
        try testing.expectEqual(window_default_height, size.height);
    }
}

test "font size steps through the supported sizes and holds at the ends" {
    try testing.expectEqual(@as(f32, 15), stepUiFontSize(14, 1));
    try testing.expectEqual(@as(f32, 18), stepUiFontSize(16, 1));
    try testing.expectEqual(@as(f32, 15), stepUiFontSize(16, -1));
    try testing.expectEqual(@as(f32, 20), stepUiFontSize(20, 1));
    try testing.expectEqual(@as(f32, 12), stepUiFontSize(12, -1));
    // An off-table size steps from its nearest supported one.
    try testing.expectEqual(@as(f32, 18), stepUiFontSize(17, 1));
}
