//! VS Code theme import, as the GPUI app's (crates/theme/src/vscode.rs
//! `compile_source`): a theme file, or an extension package's
//! `contributes.themes`, made Harness theme variants with a report of what
//! mapped, what fell back and what was repaired. The cases in
//! apps/parity/vectors/theme-import.json pin it to the Rust compiler, byte
//! for byte (each variant's asset hash is over its JSON).
const std = @import("std");
const json = std.json;
const mc = @import("model_color.zig");
const Rgba = mc.Rgba;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_source_bytes: u64 = 4 * 1024 * 1024;
const max_include_depth = 32;
const max_package_variants = 128;

pub const Options = struct {
    family_id: []const u8,
    family_name: []const u8,
    source_url: []const u8,
    revision: []const u8 = "local",
    license: []const u8 = "User supplied",
};

pub const Colors = struct {
    background: Rgba = .{},
    shell: Rgba = .{},
    raised: Rgba = .{},
    card: Rgba = .{},
    dialog: Rgba = .{},
    overlay: Rgba = .{},
    hover: Rgba = .{},
    active: Rgba = .{},
    border: Rgba = .{},
    borderStrong: Rgba = .{},
    text: Rgba = .{},
    textMuted: Rgba = .{},
    textFaint: Rgba = .{},
    solid: Rgba = .{},
    onSolid: Rgba = .{},
    danger: Rgba = .{},
    dangerMuted: Rgba = .{},
    warning: Rgba = .{},
    warningMuted: Rgba = .{},
    success: Rgba = .{},
    successMuted: Rgba = .{},
    input: Rgba = .{},
    cursor: Rgba = .{},
    diffAdd: Rgba = .{},
    diffDelete: Rgba = .{},
    diffHunk: Rgba = .{},
};

pub const Accent = struct {
    primary: Rgba = .{},
    strong: Rgba = .{},
    wash: Rgba = .{},
    on: Rgba = .{},
    selection: Rgba = .{},
    caret: Rgba = .{},
    activity: Rgba = .{},
    glyph: [3]Rgba = .{ .{}, .{}, .{} },

    /// `AccentRoles::derive`.
    pub fn derive(primary_in: Rgba, dark: bool, background: Rgba) Accent {
        const primary = primary_in.ensureContrast(background, 3.0);
        const on = primary.bestOn();
        var strong = primary;
        if (on.contrast(strong) < 4.5) strong = strong.ensureContrast(on, 4.5);
        const light = primary.mix(if (dark) Rgba.white else background, if (dark) 0.28 else 0.18);
        const deep = primary.mix(Rgba.black, if (dark) 0.18 else 0.26);
        return .{
            .primary = primary,
            .strong = strong,
            .wash = primary.withAlpha(if (dark) 0.22 else 0.12),
            .on = on,
            .selection = primary.withAlpha(if (dark) 0.35 else 0.50),
            .caret = primary,
            .activity = primary,
            .glyph = .{ light, primary, deep },
        };
    }
};

pub const Terminal = struct {
    background: Rgba = .{},
    foreground: Rgba = .{},
    selection: Rgba = .{},
    ansi: [16]Rgba = @splat(.{}),
};

pub const Source = struct {
    format: []const u8 = "",
    url: []const u8 = "",
    revision: []const u8 = "",
    license: []const u8 = "",
    asset_hash: []const u8 = "",
};

const SyntaxEntry = struct { role: []const u8, color: Rgba };

pub const Variant = struct {
    id: []const u8,
    family_id: []const u8,
    name: []const u8,
    dark: bool,
    /// "opaque" or "frosted".
    treatment: []const u8,
    colors: Colors,
    accent: Accent,
    /// The roles, kept sorted (a BTreeMap there).
    syntax: std.ArrayList(SyntaxEntry),
    terminal: Terminal,
    source: Source,

    fn setSyntax(v: *Variant, a: Allocator, role: []const u8, color: Rgba) !void {
        for (v.syntax.items) |*e| if (std.mem.eql(u8, e.role, role)) {
            e.color = color;
            return;
        };
        var at: usize = 0;
        while (at < v.syntax.items.len and std.mem.order(u8, v.syntax.items[at].role, role) == .lt) at += 1;
        try v.syntax.insert(a, at, .{ .role = role, .color = color });
    }
};

pub const Mapping = struct { role: []const u8, key: []const u8, value: []const u8 };
pub const Adjustment = struct { role: []const u8, original: []const u8, resolved: []const u8, reason: []const u8 };
pub const Candidate = struct { key: []const u8, value: []const u8 };
pub const Issue = struct { variant_id: []const u8, structural: bool, err: bool, message: []const u8 };

pub const Report = struct {
    source_files: std.ArrayList([]const u8) = .empty,
    source_hash: []const u8 = "",
    mappings: std.ArrayList(Mapping) = .empty,
    fallbacks: std.ArrayList([]const u8) = .empty,
    dropped: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,
    adjustments: std.ArrayList(Adjustment) = .empty,
    accent_candidates: std.ArrayList(Candidate) = .empty,
    validation: std.ArrayList(Issue) = .empty,
};

pub const Failure = struct { id: []const u8, name: []const u8, path: []const u8, message: []const u8 };

pub const Compilation = struct {
    path: []const u8,
    package: bool,
    family_id: []const u8,
    family_name: []const u8,
    variants: std.ArrayList(Variant) = .empty,
    /// Each variant's report, by its id, in the variants' order.
    reports: std.ArrayList(Report) = .empty,
    failures: std.ArrayList(Failure) = .empty,
};

/// An error with its message, as anyhow's outermost context reads.
pub const Failed = struct { message: []const u8 };

pub const Result = union(enum) { ok: Compilation, err: Failed };

fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) error{Failed}!noreturn {
    last_error = std.fmt.allocPrint(a, fmt, args) catch "out of memory";
    return error.Failed;
}

threadlocal var last_error: []const u8 = "";

/// `compile_source`: `path` a theme file, a `package.json`, or a folder
/// holding one. All memory is `a`'s (an arena).
pub fn compile(a: Allocator, io: std.Io, path: []const u8, options: Options) Result {
    const c = compileInner(a, io, path, options) catch |e| return .{ .err = .{ .message = if (e == error.Failed) last_error else @errorName(e) } };
    return .{ .ok = c };
}

fn compileInner(a: Allocator, io: std.Io, path_in: []const u8, options: Options) !Compilation {
    const path = canonical(a, io, path_in) catch try fail(a, "could not resolve {s}", .{path_in});
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch try fail(a, "could not resolve {s}", .{path_in});
    var package_json: ?[]const u8 = null;
    if (stat.kind == .directory) {
        const candidate = try std.fs.path.join(a, &.{ path, "package.json" });
        if (exists(io, candidate)) package_json = candidate;
    } else if (std.mem.eql(u8, std.fs.path.basename(path), "package.json")) package_json = path;
    if (package_json) |pj| return compilePackage(a, io, path, pj, options);
    return compileSingle(a, io, path, options);
}

fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn canonical(a: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, a);
}

fn compileSingle(a: Allocator, io: std.Io, path: []const u8, options: Options) !Compilation {
    const parent = std.fs.path.dirname(path) orelse try fail(a, "{s} has no parent directory", .{path});
    const root = canonical(a, io, parent) catch try fail(a, "could not resolve theme root for {s}", .{path});
    var stack: std.ArrayList([]const u8) = .empty;
    const normalized = try loadTheme(a, io, path, root, &stack);
    const dark = detectAppearance(a, io, path, null, &normalized);
    const name = declaredName(a, io, path) orelse options.family_name;
    var c: Compilation = .{ .path = path, .package = false, .family_id = options.family_id, .family_name = options.family_name };
    const imported = try convert(a, io, normalized, .{ .id = options.family_id, .family_id = options.family_id, .name = name, .dark = dark, .source_url = options.source_url, .revision = options.revision, .license = options.license });
    try c.variants.append(a, imported.variant);
    try c.reports.append(a, imported.report);
    return c;
}

fn compilePackage(a: Allocator, io: std.Io, selected: []const u8, package_json: []const u8, options: Options) !Compilation {
    const source = try readBounded(a, io, package_json, "package manifest");
    const manifest = jsonc(a, source) catch try fail(a, "could not parse {s}", .{package_json});
    const contributes = if (manifest == .object) manifest.object.get("contributes") else null;
    const themes = if (contributes) |cv| (if (cv == .object) cv.object.get("themes") else null) else null;
    const declarations = if (themes) |t| (if (t == .array) t.array.items else null) else null;
    const decls = declarations orelse try fail(a, "{s} does not declare contributes.themes", .{package_json});
    if (decls.len == 0) try fail(a, "{s} declares no theme variants", .{package_json});
    if (decls.len > max_package_variants) try fail(a, "{s} declares {d} theme variants; the limit is {d}", .{ package_json, decls.len, max_package_variants });
    const parent = std.fs.path.dirname(package_json) orelse try fail(a, "{s} has no parent directory", .{package_json});
    const root = canonical(a, io, parent) catch try fail(a, "could not resolve package root {s}", .{parent});
    var family_name = options.family_name;
    for ([_][]const u8{ "displayName", "name" }) |k| {
        const v = manifest.object.get(k) orelse continue;
        if (v != .string) continue;
        if (std.mem.trim(u8, v.string, " \t\n\r").len == 0) break;
        family_name = v.string;
        break;
    }
    var c: Compilation = .{ .path = selected, .package = true, .family_id = options.family_id, .family_name = family_name };
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (decls, 0..) |d, index| {
        const obj: ?json.ObjectMap = if (d == .object) d.object else null;
        var label: []const u8 = try std.fmt.allocPrint(a, "Variant {d}", .{index + 1});
        if (obj) |o| if (o.get("label")) |l| if (l == .string and std.mem.trim(u8, l.string, " \t\n\r").len > 0) {
            label = l.string;
        };
        var id = try std.fmt.allocPrint(a, "{s}-{s}", .{ options.family_id, try slug(a, label) });
        if (used.contains(id)) {
            id = try std.fmt.allocPrint(a, "{s}-{d}", .{ id, index + 1 });
        }
        try used.put(a, id, {});
        const relative: ?[]const u8 = if (obj) |o| (if (o.get("path")) |p| (if (p == .string) p.string else null) else null) else null;
        const rel = relative orelse {
            try c.failures.append(a, .{ .id = id, .name = label, .path = package_json, .message = "theme declaration has no path" });
            continue;
        };
        const theme_path = try std.fs.path.join(a, &.{ root, rel });
        const ui_theme: ?[]const u8 = if (obj) |o| (if (o.get("uiTheme")) |u| (if (u == .string) u.string else null) else null) else null;
        var stack: std.ArrayList([]const u8) = .empty;
        const variant = blk: {
            const normalized = loadTheme(a, io, theme_path, root, &stack) catch |e| break :blk e;
            const dark = detectAppearance(a, io, theme_path, ui_theme, &normalized);
            break :blk convert(a, io, normalized, .{ .id = id, .family_id = options.family_id, .name = label, .dark = dark, .source_url = options.source_url, .revision = options.revision, .license = options.license });
        };
        if (variant) |imported| {
            try c.variants.append(a, imported.variant);
            try c.reports.append(a, imported.report);
        } else |e| {
            try c.failures.append(a, .{ .id = id, .name = label, .path = theme_path, .message = if (e == error.Failed) last_error else @errorName(e) });
        }
    }
    if (c.variants.items.len == 0) {
        var details: std.ArrayList(u8) = .empty;
        for (c.failures.items, 0..) |f, i| {
            if (i > 0) try details.appendSlice(a, "; ");
            try details.print(a, "{s}: {s}", .{ f.name, f.message });
        }
        try fail(a, "no package variants compiled successfully: {s}", .{details.items});
    }
    return c;
}

fn declaredName(a: Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const source = readBounded(a, io, path, "theme source") catch return null;
    const v = jsonc(a, source) catch return null;
    if (v != .object) return null;
    const n = v.object.get("name") orelse return null;
    if (n != .string or std.mem.trim(u8, n.string, " \t\n\r").len == 0) return null;
    return n.string;
}

/// `detect_appearance`: the declaration's uiTheme, else the file's
/// `type`, else whichever of black or white reads better on its editor
/// background; dark when nothing says.
fn detectAppearance(a: Allocator, io: std.Io, path: []const u8, ui_theme: ?[]const u8, n: *const Normalized) bool {
    if (ui_theme) |u| {
        if (std.ascii.eqlIgnoreCase(u, "vs") or std.ascii.eqlIgnoreCase(u, "hc-light")) return false;
        if (std.ascii.eqlIgnoreCase(u, "vs-dark") or std.ascii.eqlIgnoreCase(u, "hc-black")) return true;
    }
    if (readBounded(a, io, path, "theme source")) |source| {
        if (jsonc(a, source)) |v| {
            if (v == .object) if (v.object.get("type")) |t| if (t == .string) {
                if (std.ascii.eqlIgnoreCase(t.string, "light")) return false;
                if (std.ascii.eqlIgnoreCase(t.string, "dark")) return true;
            };
        } else |_| {}
    } else |_| {}
    if (n.colors.get("editor.background")) |bg| if (Rgba.css(bg)) |background| {
        return !(Rgba.black.contrast(background) > Rgba.white.contrast(background));
    };
    return true;
}

/// `slug`: lower-case ASCII letters and digits, runs of anything else one
/// hyphen; "theme" when nothing's left.
pub fn slug(a: Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var separator = false;
    var it = std.unicode.Utf8View.initUnchecked(value).iterator();
    while (it.nextCodepoint()) |cp| {
        const lower: u21 = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
        if (lower < 128 and std.ascii.isAlphanumeric(@intCast(lower))) {
            if (separator and out.items.len > 0) try out.append(a, '-');
            separator = false;
            try out.append(a, @intCast(lower));
        } else separator = true;
    }
    return if (out.items.len == 0) "theme" else out.items;
}

const TokenRule = struct { scopes: []const []const u8, foreground: ?[]const u8, font_style: ?[]const u8 };
const SemanticStyle = struct { foreground: ?[]const u8 = null, font_style: ?[]const u8 = null };

const Normalized = struct {
    /// Key to value, the later file's over the earlier's (a BTreeMap there).
    colors: std.StringHashMapUnmanaged([]const u8) = .empty,
    token_colors: std.ArrayList(TokenRule) = .empty,
    semantic: std.StringHashMapUnmanaged(SemanticStyle) = .empty,
    files: std.ArrayList([]const u8) = .empty,
};

fn loadTheme(a: Allocator, io: std.Io, path_in: []const u8, root: []const u8, stack: *std.ArrayList([]const u8)) !Normalized {
    const path = canonical(a, io, path_in) catch try fail(a, "could not resolve {s}", .{path_in});
    try ensureContained(a, path, root, "theme source");
    for (stack.items) |p| if (std.mem.eql(u8, p, path)) try fail(a, "VS Code theme include cycle: {s}", .{path});
    if (stack.items.len >= max_include_depth) try fail(a, "VS Code theme include depth exceeds {d}", .{max_include_depth});
    try stack.append(a, path);
    const source = try readBounded(a, io, path, "theme source");
    const value = jsonc(a, source) catch try fail(a, "could not parse JSONC theme {s}", .{path});
    if (value != .object) try fail(a, "{s} is not a JSON object", .{path});
    const object = value.object;
    var theme: Normalized = if (object.get("include")) |inc| (if (inc == .string) try loadTheme(a, io, try resolveRelative(a, path, inc.string), root, stack) else .{}) else .{};
    try theme.files.append(a, path);
    if (object.get("colors")) |colors| if (colors == .object) {
        var it = colors.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try theme.colors.put(a, e.key_ptr.*, e.value_ptr.string);
    };
    if (object.get("tokenColors")) |tc| switch (tc) {
        .array => |rules| try parseTokenRules(a, rules.items, &theme.token_colors),
        .string => |relative| {
            const joined = try resolveRelative(a, path, relative);
            const token_path = canonical(a, io, joined) catch try fail(a, "could not resolve {s}", .{joined});
            try ensureContained(a, token_path, root, "external token file");
            try theme.files.append(a, token_path);
            try loadTokenFile(a, io, token_path, &theme.token_colors);
        },
        else => {},
    };
    if (object.get("semanticTokenColors")) |sem| if (sem == .object) {
        var it = sem.object.iterator();
        while (it.next()) |e| try theme.semantic.put(a, e.key_ptr.*, semanticStyle(e.value_ptr.*));
    };
    _ = stack.pop();
    return theme;
}

/// `Path::starts_with`: whole components.
fn ensureContained(a: Allocator, path: []const u8, root: []const u8, kind: []const u8) !void {
    const inside = std.mem.startsWith(u8, path, root) and (path.len == root.len or path[root.len] == '/' or (root.len > 0 and root[root.len - 1] == '/'));
    if (!inside) try fail(a, "{s} {s} resolves outside selected theme root {s}; symlinks are allowed only when their targets remain inside the root", .{ kind, path, root });
}

fn readBounded(a: Allocator, io: std.Io, path: []const u8, kind: []const u8) ![]const u8 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch try fail(a, "could not inspect {s} {s}", .{ kind, path });
    if (stat.size > max_source_bytes) try fail(a, "{s} {s} is {d} bytes; the limit is {d}", .{ kind, path, stat.size, max_source_bytes });
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_source_bytes + 1)) catch try fail(a, "could not read {s} {s}", .{ kind, path });
}

fn resolveRelative(a: Allocator, owner: []const u8, relative: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ std.fs.path.dirname(owner) orelse ".", relative });
}

fn parseTokenRules(a: Allocator, values: []const json.Value, out: *std.ArrayList(TokenRule)) !void {
    for (values) |v| {
        if (v != .object) continue;
        const o = v.object;
        var scopes: std.ArrayList([]const u8) = .empty;
        if (o.get("scope")) |s| switch (s) {
            .string => |text| {
                var it = std.mem.splitScalar(u8, text, ',');
                while (it.next()) |part| {
                    const t = std.mem.trim(u8, part, " \t\n\r");
                    if (t.len > 0) try scopes.append(a, t);
                }
            },
            .array => |list| for (list.items) |x| if (x == .string) try scopes.append(a, x.string),
            else => {},
        };
        const settings = o.get("settings") orelse continue;
        if (settings != .object) continue;
        try out.append(a, .{
            .scopes = scopes.items,
            .foreground = str(settings.object, "foreground"),
            .font_style = str(settings.object, "fontStyle"),
        });
    }
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn loadTokenFile(a: Allocator, io: std.Io, path: []const u8, out: *std.ArrayList(TokenRule)) !void {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".tmTheme") or std.ascii.eqlIgnoreCase(ext, ".plist")) return loadPlist(a, io, path, out);
    const source = try readBounded(a, io, path, "token file");
    const value = jsonc(a, source) catch try fail(a, "could not parse token file {s}", .{path});
    const values = switch (value) {
        .array => |l| l.items,
        .object => |o| if (o.get("tokenColors")) |t| (if (t == .array) t.array.items else null) else null,
        else => null,
    } orelse try fail(a, "{s} does not contain token rules", .{path});
    try parseTokenRules(a, values, out);
}

fn semanticStyle(v: json.Value) SemanticStyle {
    return switch (v) {
        .string => |s| .{ .foreground = s },
        .object => |o| .{ .foreground = str(o, "foreground"), .font_style = str(o, "fontStyle") },
        else => .{},
    };
}

// TextMate plists.

const Plist = union(enum) {
    string: []const u8,
    array: []const Plist,
    dict: []const struct { key: []const u8, value: Plist },
    other,

    fn get(p: Plist, key: []const u8) ?Plist {
        if (p != .dict) return null;
        for (p.dict) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }
};

fn loadPlist(a: Allocator, io: std.Io, path: []const u8, out: *std.ArrayList(TokenRule)) !void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch try fail(a, "could not inspect TextMate plist {s}", .{path});
    if (stat.size > max_source_bytes) try fail(a, "TextMate plist {s} is {d} bytes; the limit is {d}", .{ path, stat.size, max_source_bytes });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_source_bytes + 1)) catch try fail(a, "could not parse TextMate plist {s}", .{path});
    var parser: PlistParser = .{ .a = a, .s = text };
    const root = parser.document() catch try fail(a, "could not parse TextMate plist {s}", .{path});
    const settings = root.get("settings") orelse try fail(a, "{s} has no TextMate settings array", .{path});
    if (settings != .array) try fail(a, "{s} has no TextMate settings array", .{path});
    for (settings.array) |entry| {
        if (entry != .dict) continue;
        var scopes: std.ArrayList([]const u8) = .empty;
        if (entry.get("scope")) |s| if (s == .string) {
            var it = std.mem.splitScalar(u8, s.string, ',');
            while (it.next()) |part| {
                const t = std.mem.trim(u8, part, " \t\n\r");
                if (t.len > 0) try scopes.append(a, t);
            }
        };
        const style = entry.get("settings") orelse continue;
        if (style != .dict) continue;
        const fg: ?[]const u8 = if (style.get("foreground")) |f| (if (f == .string) f.string else null) else null;
        const fs_: ?[]const u8 = if (style.get("fontStyle")) |f| (if (f == .string) f.string else null) else null;
        try out.append(a, .{ .scopes = scopes.items, .foreground = fg, .font_style = fs_ });
    }
}

/// The XML property lists TextMate themes are: dict, array, string, key,
/// and the scalars, which are kept as "other".
const PlistParser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,

    fn document(p: *PlistParser) !Plist {
        // Past the prolog, the doctype and <plist ...>.
        while (true) {
            p.skipSpace();
            if (p.i >= p.s.len) return error.Plist;
            if (std.mem.startsWith(u8, p.s[p.i..], "<?") or std.mem.startsWith(u8, p.s[p.i..], "<!") or std.mem.startsWith(u8, p.s[p.i..], "<plist")) {
                p.i = (std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return error.Plist) + 1;
                continue;
            }
            break;
        }
        return p.value();
    }

    fn skipSpace(p: *PlistParser) void {
        while (p.i < p.s.len) {
            if (std.ascii.isWhitespace(p.s[p.i])) {
                p.i += 1;
            } else if (std.mem.startsWith(u8, p.s[p.i..], "<!--")) {
                p.i = if (std.mem.indexOfPos(u8, p.s, p.i, "-->")) |e| e + 3 else p.s.len;
            } else break;
        }
    }

    fn tag(p: *PlistParser) ![]const u8 {
        p.skipSpace();
        if (p.i >= p.s.len or p.s[p.i] != '<') return error.Plist;
        const end = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return error.Plist;
        const t = p.s[p.i + 1 .. end];
        p.i = end + 1;
        return t;
    }

    fn text(p: *PlistParser, close: []const u8) ![]const u8 {
        const end = std.mem.indexOfPos(u8, p.s, p.i, close) orelse return error.Plist;
        const raw = p.s[p.i..end];
        p.i = end + close.len;
        return unescape(p.a, raw);
    }

    fn value(p: *PlistParser) error{ Plist, OutOfMemory }!Plist {
        const t = try p.tag();
        if (std.mem.eql(u8, t, "string/")) return .{ .string = "" };
        if (std.mem.eql(u8, t, "string")) return .{ .string = try p.text("</string>") };
        if (std.mem.eql(u8, t, "array/")) return .{ .array = &.{} };
        if (std.mem.eql(u8, t, "array")) {
            var items: std.ArrayList(Plist) = .empty;
            while (true) {
                p.skipSpace();
                if (std.mem.startsWith(u8, p.s[p.i..], "</array>")) {
                    p.i += "</array>".len;
                    break;
                }
                try items.append(p.a, try p.value());
            }
            return .{ .array = items.items };
        }
        if (std.mem.eql(u8, t, "dict/")) return .{ .dict = &.{} };
        if (std.mem.eql(u8, t, "dict")) {
            const E = @typeInfo(@FieldType(Plist, "dict")).pointer.child;
            var entries: std.ArrayList(E) = .empty;
            while (true) {
                p.skipSpace();
                if (std.mem.startsWith(u8, p.s[p.i..], "</dict>")) {
                    p.i += "</dict>".len;
                    break;
                }
                const k = try p.tag();
                if (!std.mem.eql(u8, k, "key")) return error.Plist;
                const key = try p.text("</key>");
                try entries.append(p.a, .{ .key = key, .value = try p.value() });
            }
            return .{ .dict = entries.items };
        }
        // A scalar (<integer>, <real>, <true/>, <date>, <data>): skipped.
        if (t.len > 0 and t[t.len - 1] == '/') return .other;
        const close = try std.fmt.allocPrint(p.a, "</{s}>", .{t});
        _ = try p.text(close);
        return .other;
    }
};

fn unescape(a: Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
                try out.append(a, raw[i]);
                i += 1;
                continue;
            };
            const ent = raw[i + 1 .. end];
            if (std.mem.eql(u8, ent, "amp")) try out.append(a, '&') else if (std.mem.eql(u8, ent, "lt")) try out.append(a, '<') else if (std.mem.eql(u8, ent, "gt")) try out.append(a, '>') else if (std.mem.eql(u8, ent, "quot")) try out.append(a, '"') else if (std.mem.eql(u8, ent, "apos")) try out.append(a, '\'') else if (ent.len > 1 and ent[0] == '#') {
                const cp = (if (ent[1] == 'x') std.fmt.parseInt(u21, ent[2..], 16) else std.fmt.parseInt(u21, ent[1..], 10)) catch 0xfffd;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch 0;
                try out.appendSlice(a, buf[0..n]);
            } else try out.appendSlice(a, raw[i .. end + 1]);
            i = end + 1;
        } else {
            try out.append(a, raw[i]);
            i += 1;
        }
    }
    return out.items;
}

// JSONC: what VS Code themes are written in.

/// Parses JSON with comments and trailing commas (the JSON5 VS Code themes
/// use: `//` and `/* */` comments, a comma before `}` or `]`, and
/// single-quoted strings).
pub fn jsonc(a: Allocator, text: []const u8) !json.Value {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '"' or ch == '\'') {
            // A string, single quotes made double.
            const q = ch;
            try out.append(a, '"');
            i += 1;
            while (i < text.len and text[i] != q) {
                if (text[i] == '\\' and i + 1 < text.len) {
                    if (q == '\'' and text[i + 1] == '\'') {
                        try out.append(a, '\'');
                    } else {
                        try out.appendSlice(a, text[i .. i + 2]);
                    }
                    i += 2;
                    continue;
                }
                if (q == '\'' and text[i] == '"') try out.appendSlice(a, "\\\"") else try out.append(a, text[i]);
                i += 1;
            }
            try out.append(a, '"');
            i += 1;
        } else if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
        } else if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
        } else if (ch == ',') {
            // A trailing comma: what follows (past space and comments) closes.
            var j = i + 1;
            while (j < text.len) {
                if (std.ascii.isWhitespace(text[j])) {
                    j += 1;
                } else if (text[j] == '/' and j + 1 < text.len and text[j + 1] == '/') {
                    while (j < text.len and text[j] != '\n') j += 1;
                } else if (text[j] == '/' and j + 1 < text.len and text[j + 1] == '*') {
                    j = if (std.mem.indexOfPos(u8, text, j + 2, "*/")) |e| e + 2 else text.len;
                } else break;
            }
            if (j < text.len and (text[j] == '}' or text[j] == ']')) {
                i += 1;
            } else {
                try out.append(a, ',');
                i += 1;
            }
        } else {
            try out.append(a, ch);
            i += 1;
        }
    }
    return json.parseFromSliceLeaky(json.Value, a, out.items, .{ .duplicate_field_behavior = .use_last });
}

// Conversion.

const ImportOptions = struct {
    id: []const u8,
    family_id: []const u8,
    name: []const u8,
    dark: bool,
    source_url: []const u8,
    revision: []const u8,
    license: []const u8,
};

const Imported = struct { variant: Variant, report: Report };

fn hexOf(a: Allocator, c: Rgba) []const u8 {
    var buf: [9]u8 = undefined;
    return a.dupe(u8, c.hex(&buf)) catch "";
}

/// The Harness base the import starts from (`harnesser-dark`/`-light`),
/// from the built-in catalog.
pub fn base(a: Allocator, dark: bool) !Variant {
    const doc = try json.parseFromSliceLeaky(json.Value, a, @import("themes_json").json, .{});
    const want = if (dark) "harnesser-dark" else "harnesser-light";
    for (doc.object.get("families").?.array.items) |f| for (f.object.get("variants").?.array.items) |v| {
        if (std.mem.eql(u8, v.object.get("id").?.string, want)) return variantFrom(a, v.object);
    };
    return error.NoBase;
}

pub fn variantFrom(a: Allocator, o: json.ObjectMap) !Variant {
    const col = struct {
        fn get(m: json.ObjectMap, key: []const u8) Rgba {
            const v = m.get(key) orelse return .{};
            return if (v == .string) Rgba.css(v.string) orelse .{} else .{};
        }
    };
    var v: Variant = .{
        .id = str(o, "id") orelse "",
        .family_id = str(o, "familyId") orelse "",
        .name = str(o, "name") orelse "",
        .dark = std.mem.eql(u8, str(o, "appearance") orelse "dark", "dark"),
        .treatment = str(o, "recommendedSurfaceTreatment") orelse str(o, "surfaceTreatment") orelse "opaque",
        .colors = .{},
        .accent = .{},
        .syntax = .empty,
        .terminal = .{},
        .source = .{},
    };
    if (o.get("colors")) |cs| if (cs == .object) inline for (@typeInfo(Colors).@"struct".field_names) |name| {
        @field(v.colors, name) = col.get(cs.object, name);
    };
    if (o.get("accent")) |ac| if (ac == .object) {
        inline for (.{ "primary", "strong", "wash", "on", "selection", "caret", "activity" }) |name| @field(v.accent, name) = col.get(ac.object, name);
        if (ac.object.get("glyph")) |g| if (g == .array) for (g.array.items[0..@min(3, g.array.items.len)], 0..) |x, i| {
            v.accent.glyph[i] = if (x == .string) Rgba.css(x.string) orelse .{} else .{};
        };
    };
    if (o.get("syntax")) |sy| if (sy == .object) {
        var it = sy.object.iterator();
        while (it.next()) |e| if (e.value_ptr.* == .string) try v.setSyntax(a, e.key_ptr.*, Rgba.css(e.value_ptr.string) orelse .{});
    };
    if (o.get("terminal")) |t| if (t == .object) {
        v.terminal.background = col.get(t.object, "background");
        v.terminal.foreground = col.get(t.object, "foreground");
        v.terminal.selection = col.get(t.object, "selection");
        if (t.object.get("ansi")) |an| if (an == .array) for (an.array.items[0..@min(16, an.array.items.len)], 0..) |x, i| {
            v.terminal.ansi[i] = if (x == .string) Rgba.css(x.string) orelse .{} else .{};
        };
    };
    if (o.get("source")) |s| if (s == .object) {
        v.source = .{
            .format = str(s.object, "format") orelse "",
            .url = str(s.object, "url") orelse "",
            .revision = str(s.object, "revision") orelse "",
            .license = str(s.object, "license") orelse "",
            .asset_hash = str(s.object, "assetHash") orelse "",
        };
    };
    return v;
}

fn convert(a: Allocator, io: std.Io, theme: Normalized, options: ImportOptions) !Imported {
    var out = try base(a, options.dark);
    const fallback_background = out.colors.background;
    out.id = options.id;
    out.family_id = options.family_id;
    out.name = options.name;
    out.dark = options.dark;
    out.treatment = "opaque";
    var report: Report = .{};
    for (theme.files.items) |f| try report.source_files.append(a, f);
    try report.fallbacks.append(a, "surface treatment inferred as opaque because VS Code palettes target solid workbench backgrounds; the user's Harness surface preference can override it");
    const appearance_word = if (options.dark) "dark" else "light";

    const Apply = struct {
        fn apply(al: Allocator, th: *const Normalized, rep: *Report, word: []const u8, role: []const u8, keys: []const []const u8, target: *Rgba) !void {
            for (keys) |key| {
                const value = th.colors.get(key) orelse continue;
                if (Rgba.css(value)) |c| {
                    target.* = c;
                    try rep.mappings.append(al, .{ .role = role, .key = key, .value = hexOf(al, c) });
                    return;
                }
                try rep.warnings.append(al, try std.fmt.allocPrint(al, "ignored unsupported color {s}={s}", .{ key, value }));
            }
            try rep.fallbacks.append(al, try std.fmt.allocPrint(al, "{s} retained the Harness {s} fallback", .{ role, word }));
        }
    };
    const ap = Apply.apply;
    const c = &out.colors;
    try ap(a, &theme, &report, appearance_word, "background", &.{"editor.background"}, &c.background);
    try ap(a, &theme, &report, appearance_word, "shell", &.{ "sideBar.background", "activityBar.background", "panel.background" }, &c.shell);
    try ap(a, &theme, &report, appearance_word, "raised", &.{ "list.hoverBackground", "input.background" }, &c.raised);
    try ap(a, &theme, &report, appearance_word, "card", &.{ "panel.background", "sideBar.background" }, &c.card);
    try ap(a, &theme, &report, appearance_word, "dialog", &.{ "editorWidget.background", "quickInput.background" }, &c.dialog);
    try ap(a, &theme, &report, appearance_word, "overlay", &.{ "dropdown.background", "menu.background", "editorWidget.background" }, &c.overlay);
    try ap(a, &theme, &report, appearance_word, "hover", &.{ "list.hoverBackground", "toolbar.hoverBackground" }, &c.hover);
    try ap(a, &theme, &report, appearance_word, "active", &.{ "list.activeSelectionBackground", "list.inactiveSelectionBackground" }, &c.active);
    try ap(a, &theme, &report, appearance_word, "border", &.{ "panel.border", "widget.border", "contrastBorder" }, &c.border);
    try ap(a, &theme, &report, appearance_word, "borderStrong", &.{ "focusBorder", "contrastActiveBorder" }, &c.borderStrong);
    try ap(a, &theme, &report, appearance_word, "text", &.{ "foreground", "editor.foreground" }, &c.text);
    try ap(a, &theme, &report, appearance_word, "textMuted", &.{ "descriptionForeground", "tab.inactiveForeground" }, &c.textMuted);
    try ap(a, &theme, &report, appearance_word, "textFaint", &.{ "disabledForeground", "input.placeholderForeground" }, &c.textFaint);
    try ap(a, &theme, &report, appearance_word, "solid", &.{"button.background"}, &c.solid);
    try ap(a, &theme, &report, appearance_word, "onSolid", &.{"button.foreground"}, &c.onSolid);
    try ap(a, &theme, &report, appearance_word, "danger", &.{ "editorError.foreground", "errorForeground", "gitDecoration.deletedResourceForeground" }, &c.danger);
    try ap(a, &theme, &report, appearance_word, "warning", &.{ "editorWarning.foreground", "gitDecoration.modifiedResourceForeground" }, &c.warning);
    try ap(a, &theme, &report, appearance_word, "success", &.{ "gitDecoration.addedResourceForeground", "testing.iconPassed" }, &c.success);
    try ap(a, &theme, &report, appearance_word, "input", &.{"input.background"}, &c.input);
    try ap(a, &theme, &report, appearance_word, "cursor", &.{"editorCursor.foreground"}, &c.cursor);
    try ap(a, &theme, &report, appearance_word, "diffAdd", &.{ "diffEditor.insertedTextBackground", "gitDecoration.addedResourceForeground" }, &c.diffAdd);
    try ap(a, &theme, &report, appearance_word, "diffDelete", &.{ "diffEditor.removedTextBackground", "gitDecoration.deletedResourceForeground" }, &c.diffDelete);
    try ap(a, &theme, &report, appearance_word, "diffHunk", &.{ "diffEditor.diagonalFill", "editor.findMatchHighlightBackground" }, &c.diffHunk);

    for ([_][]const u8{ "focusBorder", "textLink.foreground", "button.background", "activityBarBadge.background", "progressBar.background", "editorCursor.foreground" }) |key| {
        const value = theme.colors.get(key) orelse continue;
        const color = Rgba.css(value) orelse continue;
        try report.accent_candidates.append(a, .{ .key = key, .value = hexOf(a, color) });
    }
    if (report.accent_candidates.items.len > 0) {
        const cand = report.accent_candidates.items[0];
        out.accent = Accent.derive(Rgba.css(cand.value).?, options.dark, out.colors.background);
        try report.mappings.append(a, .{ .role = "accent.*", .key = cand.key, .value = cand.value });
    } else try report.fallbacks.append(a, "accent.* retained the Harness fallback; curate a native accent");

    try ap(a, &theme, &report, appearance_word, "terminal.background", &.{"terminal.background"}, &out.terminal.background);
    try ap(a, &theme, &report, appearance_word, "terminal.foreground", &.{"terminal.foreground"}, &out.terminal.foreground);
    try ap(a, &theme, &report, appearance_word, "terminal.selection", &.{"terminal.selectionBackground"}, &out.terminal.selection);
    const ansi_keys = [_][]const u8{ "terminal.ansiBlack", "terminal.ansiRed", "terminal.ansiGreen", "terminal.ansiYellow", "terminal.ansiBlue", "terminal.ansiMagenta", "terminal.ansiCyan", "terminal.ansiWhite", "terminal.ansiBrightBlack", "terminal.ansiBrightRed", "terminal.ansiBrightGreen", "terminal.ansiBrightYellow", "terminal.ansiBrightBlue", "terminal.ansiBrightMagenta", "terminal.ansiBrightCyan", "terminal.ansiBrightWhite" };
    for (ansi_keys, 0..) |key, i| {
        const role = try std.fmt.allocPrint(a, "terminal.ansi[{d}]", .{i});
        try ap(a, &theme, &report, appearance_word, role, &.{key}, &out.terminal.ansi[i]);
    }

    try mapSyntax(a, &theme, &out, &report);
    try hardenVariant(a, &theme, &out, fallback_background, &report);

    var hasher = Sha256.init(.{});
    for (theme.files.items) |f| hasher.update(try readBounded(a, io, f, "theme source while hashing"));
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    report.source_hash = try std.fmt.allocPrint(a, "sha256:{x}", .{&digest});

    out.source = .{ .format = "vscode", .url = options.source_url, .revision = options.revision, .license = options.license, .asset_hash = "" };
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeVariant(&aw.writer, &out);
    var vh: [32]u8 = undefined;
    Sha256.hash(aw.written(), &vh, .{});
    out.source.asset_hash = try std.fmt.allocPrint(a, "sha256:{x}", .{&vh});
    try validate(a, &out, &report.validation);
    return .{ .variant = out, .report = report };
}

fn hardenVariant(a: Allocator, source: *const Normalized, out: *Variant, fallback_background: Rgba, report: *Report) !void {
    const c = &out.colors;
    c.background = try flatten(a, "background", c.background, fallback_background, report);
    const background = c.background;
    c.shell = try flatten(a, "shell", c.shell, background, report);
    c.raised = try flatten(a, "raised", c.raised, background, report);
    c.card = try flatten(a, "card", c.card, background, report);
    c.dialog = try flatten(a, "dialog", c.dialog, background, report);
    c.overlay = try flatten(a, "overlay", c.overlay, background, report);
    c.input = try flatten(a, "input", c.input, background, report);
    c.solid = try flatten(a, "solid", c.solid, background, report);
    out.terminal.background = try flatten(a, "terminal.background", out.terminal.background, background, report);

    const grounds = [_]Rgba{ background, c.shell, c.raised, c.card, c.dialog, c.overlay, c.input };
    c.text = try hardenForeground(a, source, report, "text", c.text, &.{ "foreground", "sideBar.foreground", "editorWidget.foreground", "quickInput.foreground", "input.foreground", "menu.foreground", "editor.foreground" }, &grounds, 4.5, null);
    c.textMuted = try hardenForeground(a, source, report, "textMuted", c.textMuted, &.{ "descriptionForeground", "tab.inactiveForeground", "sideBarSectionHeader.foreground" }, &grounds, 4.5, c.text);
    c.textFaint = try hardenForeground(a, source, report, "textFaint", c.textFaint, &.{ "disabledForeground", "input.placeholderForeground", "descriptionForeground", "foreground" }, &grounds, 3.0, c.textMuted);
    c.onSolid = try hardenForeground(a, source, report, "onSolid", c.onSolid, &.{ "button.foreground", "foreground", "editor.foreground" }, &.{c.solid}, 4.5, c.text);
    out.terminal.foreground = try hardenForeground(a, source, report, "terminal.foreground", out.terminal.foreground, &.{ "terminal.foreground", "editor.foreground", "foreground" }, &.{out.terminal.background}, 4.5, c.text);

    inline for (.{ .{ "danger", "danger" }, .{ "warning", "warning" }, .{ "success", "success" }, .{ "cursor", "cursor" }, .{ "borderStrong", "borderStrong" } }) |r| {
        const original = @field(c, r[1]);
        @field(c, r[1]) = mc.harden(original, grounds[0..2], 3.0, null);
        try record(a, report, r[0], original, @field(c, r[1]), "raised to 3:1 across the main and shell surfaces");
    }
    try hardenAccent(a, out, report, grounds[0..4]);
}

fn flatten(a: Allocator, role: []const u8, color: Rgba, background: Rgba, report: *Report) !Rgba {
    if (color.a == 255) return color;
    const resolved = color.blendOver(background);
    try record(a, report, role, color, resolved, "flattened a translucent foundational surface against the theme background");
    return resolved;
}

fn least(color: Rgba, grounds: []const Rgba) f32 {
    var m: f32 = std.math.inf(f32);
    for (grounds) |g| m = @min(m, color.contrast(g));
    return m;
}

fn hardenForeground(a: Allocator, source: *const Normalized, report: *Report, role: []const u8, current: Rgba, keys: []const []const u8, grounds: []const Rgba, minimum: f32, preferred: ?Rgba) !Rgba {
    const current_contrast = least(current, grounds);
    if (current_contrast >= minimum) return current;
    for (keys) |key| {
        const value = source.colors.get(key) orelse continue;
        const candidate = Rgba.css(value) orelse continue;
        if (least(candidate, grounds) >= minimum) {
            try record(a, report, role, current, candidate, try std.fmt.allocPrint(a, "used {s} because the mapped color reached only {d:.2}:1", .{ key, current_contrast }));
            for (report.mappings.items) |*m| if (std.mem.eql(u8, m.role, role)) {
                m.key = key;
                m.value = hexOf(a, candidate);
                break;
            };
            return candidate;
        }
    }
    const resolved = mc.harden(current, grounds, minimum, preferred);
    try record(a, report, role, current, resolved, try std.fmt.allocPrint(a, "preserved the source hue while raising worst-case contrast from {d:.2}:1 to {d:.2}:1", .{ current_contrast, least(resolved, grounds) }));
    return resolved;
}

fn hardenAccent(a: Allocator, out: *Variant, report: *Report, grounds: []const Rgba) !void {
    const current = out.accent.primary;
    if (least(current, grounds) >= 3.0) return;
    for (report.accent_candidates.items) |cand| {
        const primary = Rgba.css(cand.value) orelse continue;
        if (least(primary, grounds) >= 3.0) {
            out.accent = Accent.derive(primary, out.dark, out.colors.background);
            try record(a, report, "accent.*", current, out.accent.primary, try std.fmt.allocPrint(a, "used {s} to keep interactions at 3:1", .{cand.key}));
            return;
        }
    }
    const primary = mc.harden(current, grounds, 3.0, null);
    out.accent = Accent.derive(primary, out.dark, out.colors.background);
    try record(a, report, "accent.*", current, out.accent.primary, "preserved the source hue while raising interaction contrast to 3:1");
}

fn record(a: Allocator, report: *Report, role: []const u8, original: Rgba, resolved: Rgba, reason: []const u8) !void {
    if (original.eql(resolved)) return;
    try report.adjustments.append(a, .{ .role = role, .original = hexOf(a, original), .resolved = hexOf(a, resolved), .reason = reason });
}

fn mapSyntax(a: Allocator, theme: *const Normalized, out: *Variant, report: *Report) !void {
    for (theme.token_colors.items) |rule| {
        const fg = rule.foreground orelse continue;
        const color = Rgba.css(fg) orelse {
            try report.warnings.append(a, try std.fmt.allocPrint(a, "ignored TextMate color {s}", .{fg}));
            continue;
        };
        if (rule.font_style) |style| if (style.len > 0) {
            try report.dropped.append(a, try std.fmt.allocPrint(a, "TextMate fontStyle `{s}` for {s}", .{ style, try std.mem.join(a, ", ", rule.scopes) }));
        };
        for (rule.scopes) |scope| if (roleForScope(a, scope)) |role| {
            try out.setSyntax(a, role, color);
            try report.mappings.append(a, .{ .role = try std.fmt.allocPrint(a, "syntax.{s}", .{role}), .key = scope, .value = hexOf(a, color) });
        };
    }
    // Selectors in order (a BTreeMap there).
    var selectors: std.ArrayList([]const u8) = .empty;
    var it = theme.semantic.keyIterator();
    while (it.next()) |k| try selectors.append(a, k.*);
    std.sort.insertion([]const u8, selectors.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    for (selectors.items) |selector| {
        const style = theme.semantic.get(selector).?;
        if (style.font_style) |fs_| if (fs_.len > 0) {
            try report.dropped.append(a, try std.fmt.allocPrint(a, "semantic fontStyle `{s}` for {s}", .{ fs_, selector }));
        };
        const fg = style.foreground orelse continue;
        const color = Rgba.css(fg) orelse continue;
        if (roleForSemantic(selector)) |role| {
            try out.setSyntax(a, role, color);
            try report.mappings.append(a, .{ .role = try std.fmt.allocPrint(a, "syntax.{s}", .{role}), .key = try std.fmt.allocPrint(a, "semantic:{s}", .{selector}), .value = hexOf(a, color) });
        }
    }
}

fn roleForScope(a: Allocator, scope: []const u8) ?[]const u8 {
    const lower = std.ascii.allocLowerString(a, scope) catch return null;
    const pairs = [_][2][]const u8{
        .{ "comment", "comment" },                 .{ "invalid", "invalid" },
        .{ "keyword", "keyword" },                 .{ "storage", "keyword" },
        .{ "string", "string" },                   .{ "constant.numeric", "number" },
        .{ "constant.language", "boolean" },       .{ "entity.name.type", "type" },
        .{ "support.type", "typeBuiltin" },        .{ "entity.name.function", "function" },
        .{ "support.function", "functionBuiltin" }, .{ "entity.other.attribute", "attribute" },
        .{ "entity.name.tag", "tag" },             .{ "variable.parameter", "parameter" },
        .{ "variable.other.property", "property" }, .{ "variable", "variable" },
        .{ "constant", "constant" },               .{ "keyword.operator", "operator" },
        .{ "punctuation", "punctuation" },
    };
    for (pairs) |p| if (std.mem.indexOf(u8, lower, p[0]) != null) return p[1];
    return null;
}

fn roleForSemantic(selector: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, selector, ".:") orelse selector.len;
    const token = selector[0..end];
    const roles = [_][2][]const u8{
        .{ "comment", "comment" },   .{ "keyword", "keyword" },     .{ "modifier", "keyword" },
        .{ "string", "string" },     .{ "regexp", "string" },       .{ "number", "number" },
        .{ "type", "type" },         .{ "class", "type" },          .{ "interface", "type" },
        .{ "enum", "type" },         .{ "struct", "type" },         .{ "function", "function" },
        .{ "method", "function" },   .{ "property", "property" },   .{ "enummember", "property" },
        .{ "parameter", "parameter" }, .{ "variable", "variable" }, .{ "macro", "macro" },
        .{ "decorator", "attribute" },
    };
    for (roles) |r| if (std.ascii.eqlIgnoreCase(token, r[0])) return r[1];
    return null;
}

/// `ThemeRegistry::validate` for one variant.
pub fn validate(a: Allocator, v: *const Variant, out: *std.ArrayList(Issue)) !void {
    if (std.mem.trim(u8, v.id, " \t\n\r").len == 0) try out.append(a, .{ .variant_id = v.id, .structural = true, .err = true, .message = "variant id must be unique" });
    const checks = [_]struct { role: []const u8, fg: Rgba, bg: Rgba, min: f32 }{
        .{ .role = "text", .fg = v.colors.text, .bg = v.colors.background, .min = 4.5 },
        .{ .role = "muted text", .fg = v.colors.textMuted, .bg = v.colors.background, .min = 4.5 },
        .{ .role = "accent", .fg = v.accent.primary, .bg = v.colors.background, .min = 3.0 },
        .{ .role = "on-accent", .fg = v.accent.on, .bg = v.accent.strong, .min = 4.5 },
        .{ .role = "terminal foreground", .fg = v.terminal.foreground, .bg = v.terminal.background, .min = 4.5 },
    };
    for (checks) |ch| {
        const actual = ch.fg.contrast(ch.bg);
        if (actual < ch.min) try out.append(a, .{ .variant_id = v.id, .structural = false, .err = true, .message = try std.fmt.allocPrint(a, "{s} contrast is {d:.2}:1; expected {d:.1}:1", .{ ch.role, actual, ch.min }) });
    }
    if (v.source.url.len == 0 or v.source.revision.len == 0 or v.source.license.len == 0 or v.source.asset_hash.len == 0)
        try out.append(a, .{ .variant_id = v.id, .structural = true, .err = true, .message = "source provenance is incomplete" });
    for (v.terminal.ansi, 0..) |color, i| {
        if (i % 8 == 0) continue;
        if (color.contrast(v.terminal.background) < 3.0)
            try out.append(a, .{ .variant_id = v.id, .structural = false, .err = false, .message = try std.fmt.allocPrint(a, "terminal ANSI slot {d} is below 3:1", .{i}) });
    }
}

// Writing: as serde writes these types, field for field.

fn writeColor(w: *std.Io.Writer, c: Rgba) !void {
    var buf: [9]u8 = undefined;
    try w.print("\"{s}\"", .{c.hex(&buf)});
}

fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try json.Stringify.encodeJsonString(s, .{}, w);
}

/// A variant as serde_json writes `ThemeVariant` (compact, its fields in
/// order, `syntax` sorted): what its asset hash is over.
pub fn writeVariant(w: *std.Io.Writer, v: *const Variant) !void {
    try w.writeAll("{\"id\":");
    try writeString(w, v.id);
    try w.writeAll(",\"familyId\":");
    try writeString(w, v.family_id);
    try w.writeAll(",\"name\":");
    try writeString(w, v.name);
    try w.print(",\"appearance\":\"{s}\",\"recommendedSurfaceTreatment\":\"{s}\",\"colors\":{{", .{ if (v.dark) "dark" else "light", v.treatment });
    inline for (@typeInfo(Colors).@"struct".field_names, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":", .{name});
        try writeColor(w, @field(v.colors, name));
    }
    try w.writeAll("},\"accent\":{");
    inline for (.{ "primary", "strong", "wash", "on", "selection", "caret", "activity" }, 0..) |name, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":", .{name});
        try writeColor(w, @field(v.accent, name));
    }
    try w.writeAll(",\"glyph\":[");
    for (v.accent.glyph, 0..) |g, i| {
        if (i > 0) try w.writeByte(',');
        try writeColor(w, g);
    }
    try w.writeAll("]},\"syntax\":{");
    for (v.syntax.items, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, e.role);
        try w.writeByte(':');
        try writeColor(w, e.color);
    }
    try w.writeAll("},\"terminal\":{\"background\":");
    try writeColor(w, v.terminal.background);
    try w.writeAll(",\"foreground\":");
    try writeColor(w, v.terminal.foreground);
    try w.writeAll(",\"selection\":");
    try writeColor(w, v.terminal.selection);
    try w.writeAll(",\"ansi\":[");
    for (v.terminal.ansi, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try writeColor(w, c);
    }
    try w.writeAll("]},\"source\":{\"format\":");
    try writeString(w, v.source.format);
    try w.writeAll(",\"url\":");
    try writeString(w, v.source.url);
    try w.writeAll(",\"revision\":");
    try writeString(w, v.source.revision);
    try w.writeAll(",\"license\":");
    try writeString(w, v.source.license);
    try w.writeAll(",\"assetHash\":");
    try writeString(w, v.source.asset_hash);
    try w.writeAll("}}");
}

fn writeStrings(w: *std.Io.Writer, list: []const []const u8) !void {
    try w.writeByte('[');
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, s);
    }
    try w.writeByte(']');
}

/// An `ImportReport` as serde writes it.
pub fn writeReport(w: *std.Io.Writer, r: *const Report) !void {
    try w.writeAll("{\"sourceFiles\":");
    try writeStrings(w, r.source_files.items);
    try w.writeAll(",\"sourceHash\":");
    try writeString(w, r.source_hash);
    try w.writeAll(",\"mappings\":[");
    for (r.mappings.items, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"harnessRole\":");
        try writeString(w, m.role);
        try w.writeAll(",\"vscodeKey\":");
        try writeString(w, m.key);
        try w.writeAll(",\"value\":");
        try writeString(w, m.value);
        try w.writeByte('}');
    }
    try w.writeAll("],\"fallbacks\":");
    try writeStrings(w, r.fallbacks.items);
    try w.writeAll(",\"dropped\":");
    try writeStrings(w, r.dropped.items);
    try w.writeAll(",\"warnings\":");
    try writeStrings(w, r.warnings.items);
    try w.writeAll(",\"adjustments\":[");
    for (r.adjustments.items, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"harnessRole\":");
        try writeString(w, m.role);
        try w.writeAll(",\"original\":");
        try writeString(w, m.original);
        try w.writeAll(",\"resolved\":");
        try writeString(w, m.resolved);
        try w.writeAll(",\"reason\":");
        try writeString(w, m.reason);
        try w.writeByte('}');
    }
    try w.writeAll("],\"accentCandidates\":[");
    for (r.accent_candidates.items, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"vscodeKey\":");
        try writeString(w, m.key);
        try w.writeAll(",\"value\":");
        try writeString(w, m.value);
        try w.writeByte('}');
    }
    try w.writeAll("],\"validation\":[");
    for (r.validation.items, 0..) |m, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"variant_id\":");
        try writeString(w, m.variant_id);
        try w.print(",\"category\":\"{s}\",\"severity\":\"{s}\",\"message\":", .{ if (m.structural) "structural" else "contrast", if (m.err) "error" else "warning" });
        try writeString(w, m.message);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// A `SourceCompilation` as serde writes it.
pub fn writeCompilation(w: *std.Io.Writer, c: *const Compilation) !void {
    try w.writeAll("{\"path\":");
    try writeString(w, c.path);
    try w.print(",\"sourceKind\":\"{s}\",\"family\":{{\"id\":", .{if (c.package) "package" else "file"});
    try writeString(w, c.family_id);
    try w.writeAll(",\"name\":");
    try writeString(w, c.family_name);
    try w.writeAll(",\"variants\":[");
    for (c.variants.items, 0..) |*v, i| {
        if (i > 0) try w.writeByte(',');
        try writeVariant(w, v);
    }
    try w.writeAll("]},\"reports\":{");
    for (c.variants.items, c.reports.items, 0..) |v, *r, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, v.id);
        try w.writeByte(':');
        try writeReport(w, r);
    }
    try w.writeAll("},\"failures\":[");
    for (c.failures.items, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try writeString(w, f.id);
        try w.writeAll(",\"name\":");
        try writeString(w, f.name);
        try w.writeAll(",\"path\":");
        try writeString(w, f.path);
        try w.writeAll(",\"message\":");
        try writeString(w, f.message);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

const testing = std.testing;

/// Every string in `v` with `root` written as $ROOT, for comparing with a
/// vector.
fn rooted(a: Allocator, v: json.Value, root: []const u8) !json.Value {
    return switch (v) {
        .string => |s| .{ .string = try std.mem.replaceOwned(u8, a, s, root, "$ROOT") },
        .array => |arr| blk: {
            var out = json.Array.init(a);
            for (arr.items) |x| try out.append(try rooted(a, x, root));
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var out: json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| try out.put(a, try std.mem.replaceOwned(u8, a, e.key_ptr.*, root, "$ROOT"), try rooted(a, e.value_ptr.*, root));
            break :blk .{ .object = out };
        },
        else => v,
    };
}

fn same(x: json.Value, y: json.Value, where: []const u8) bool {
    switch (x) {
        .object => |xo| {
            if (y != .object or xo.count() != y.object.count()) {
                std.debug.print("{s}: object differs\n", .{where});
                return false;
            }
            var it = xo.iterator();
            while (it.next()) |e| {
                const other = y.object.get(e.key_ptr.*) orelse {
                    std.debug.print("{s}: no {s}\n", .{ where, e.key_ptr.* });
                    return false;
                };
                if (!same(e.value_ptr.*, other, e.key_ptr.*)) return false;
            }
            return true;
        },
        .array => |xa| {
            if (y != .array or xa.items.len != y.array.items.len) {
                std.debug.print("{s}: array length differs\n", .{where});
                return false;
            }
            for (xa.items, y.array.items) |p, q| if (!same(p, q, where)) return false;
            return true;
        },
        .string => |s| {
            if (y != .string or !std.mem.eql(u8, s, y.string)) {
                std.debug.print("{s}: \"{s}\" != {f}\n", .{ where, s, std.json.fmt(y, .{}) });
                return false;
            }
            return true;
        },
        else => return std.meta.eql(std.meta.activeTag(x), std.meta.activeTag(y)),
    }
}

test "the theme-import vectors compile as the GPUI app's compiler compiles them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ @import("parity_options").vectors_dir, "theme-import.json" });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(8 << 20));
    const doc = try json.parseFromSliceLeaky(json.Value, a, text, .{});
    for (doc.object.get("cases").?.array.items) |case| {
        const o = case.object;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var it = o.get("files").?.object.iterator();
        while (it.next()) |e| {
            if (std.fs.path.dirname(e.key_ptr.*)) |d| try tmp.dir.createDirPath(testing.io, d);
            try tmp.dir.writeFile(testing.io, .{ .sub_path = e.key_ptr.*, .data = e.value_ptr.string });
        }
        const rel = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        const root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, rel, a);
        const entry = o.get("entry").?.string;
        const target = if (entry.len == 0) root else try std.fs.path.join(a, &.{ root, entry });
        const result = compile(a, testing.io, target, .{
            .family_id = o.get("familyId").?.string,
            .family_name = o.get("familyName").?.string,
            .source_url = o.get("sourceUrl").?.string,
        });
        var aw: std.Io.Writer.Allocating = .init(a);
        switch (result) {
            .ok => |c| try writeCompilation(&aw.writer, &c),
            .err => |e| {
                try aw.writer.writeAll("{\"error\":");
                try writeString(&aw.writer, e.message);
                try aw.writer.writeByte('}');
            },
        }
        const got = try rooted(a, try json.parseFromSliceLeaky(json.Value, a, aw.written(), .{}), root);
        if (!same(o.get("expected").?, got, o.get("name").?.string)) {
            std.debug.print("case: {s}\n", .{o.get("name").?.string});
            return error.Differs;
        }
    }
}

test "JSONC: comments, trailing commas and single quotes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try jsonc(arena.allocator(), "{ // a\n 'a': 'it\\'s', /* b */ \"b\": [1, 2,], }");
    try testing.expectEqualStrings("it's", v.object.get("a").?.string);
    try testing.expectEqual(@as(usize, 2), v.object.get("b").?.array.items.len);
    try testing.expectEqualStrings("harbor-night", try slug(arena.allocator(), "Harbor  Night!"));
    try testing.expectEqualStrings("theme", try slug(arena.allocator(), "—"));
}
