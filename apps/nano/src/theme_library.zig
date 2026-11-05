//! The custom theme library, as the GPUI app keeps it (crates/theme/src/
//! library.rs `CustomThemeLibrary`): `theme-library.json` in Harness's data
//! folder, one entry per imported or linked family, written so either app
//! reads what the other wrote. Entries this app didn't make are kept as
//! they are.
const std = @import("std");
const json = std.json;
const imp = @import("theme_import.zig");
const Allocator = std.mem.Allocator;

const library_file = "theme-library.json";
const max_library_bytes = 16 * 1024 * 1024;
const max_entries = 256;
const max_variants = 1024;

pub const SourceKind = enum { imported_snapshot, linked_file, linked_package, editable_file };

/// An entry as the page shows it.
pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    kind: SourceKind,
    /// Where it came from, or (an imported copy without one) none.
    path: ?[]const u8,
    variants: usize,
    /// "Using last known good" and why, after a failed reload.
    warning: ?[]const u8,
    /// Its family's variants' ids and names, and its reports, for Review.
    raw: json.ObjectMap,

    pub fn linked(e: Entry) bool {
        return e.kind != .imported_snapshot;
    }

    /// `CustomThemeSource::label`.
    pub fn label(e: Entry) []const u8 {
        return switch (e.kind) {
            .imported_snapshot => "Imported",
            .linked_file => "Linked file",
            .linked_package => "Linked package",
            .editable_file => "Editable file",
        };
    }
};

pub const Library = struct {
    entries: std.ArrayList(json.Value) = .empty,

    pub fn views(l: *const Library, a: Allocator) ![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        for (l.entries.items) |v| if (view(v)) |e| try out.append(a, e);
        return out.items;
    }

    fn find(l: *Library, id: []const u8) ?*json.ObjectMap {
        for (l.entries.items) |*v| if (v.* == .object) if (v.object.get("id")) |x| if (x == .string and std.mem.eql(u8, x.string, id)) return &v.object;
        return null;
    }

    fn variantCount(l: *const Library) usize {
        var n: usize = 0;
        for (l.entries.items) |v| n += variantsOf(v).len;
        return n;
    }
};

fn variantsOf(v: json.Value) []const json.Value {
    if (v != .object) return &.{};
    const fam = v.object.get("family") orelse return &.{};
    if (fam != .object) return &.{};
    const vs = fam.object.get("variants") orelse return &.{};
    return if (vs == .array) vs.array.items else &.{};
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn view(v: json.Value) ?Entry {
    if (v != .object) return null;
    const o = v.object;
    const source = o.get("source") orelse return null;
    if (source != .object) return null;
    const kind_s = str(source.object, "kind") orelse return null;
    const kind: SourceKind = if (std.mem.eql(u8, kind_s, "importedSnapshot")) .imported_snapshot else if (std.mem.eql(u8, kind_s, "linkedFile")) .linked_file else if (std.mem.eql(u8, kind_s, "linkedPackage")) .linked_package else if (std.mem.eql(u8, kind_s, "editableFile")) .editable_file else return null;
    const path = if (kind == .imported_snapshot) str(source.object, "importedFrom") else str(source.object, "path");
    var warning: ?[]const u8 = null;
    if (o.get("status")) |s| if (s == .object) if (str(s.object, "kind")) |k| if (std.mem.eql(u8, k, "warning")) {
        warning = str(s.object, "message") orelse "";
    };
    return .{ .id = str(o, "id") orelse return null, .name = str(o, "name") orelse "", .kind = kind, .path = path, .variants = variantsOf(v).len, .warning = warning, .raw = o };
}

pub fn libraryPath(a: Allocator, dir: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ dir, library_file });
}

/// The library in `dir` (its recovery copy when the file is gone); empty
/// when there's neither.
pub fn load(a: Allocator, io: std.Io, dir: []const u8) !Library {
    const p = try libraryPath(a, dir);
    const backup = try std.fmt.allocPrint(a, "{s}.bak", .{p});
    const which = if (exists(io, p)) p else backup;
    const text = std.Io.Dir.cwd().readFileAlloc(io, which, a, .limited(max_library_bytes)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => {
            last_error = try std.fmt.allocPrint(a, "could not read {s}", .{p});
            return e;
        },
    };
    const doc = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch |e| {
        last_error = try std.fmt.allocPrint(a, "could not parse {s}", .{which});
        return e;
    };
    var lib: Library = .{};
    if (doc == .object) if (doc.object.get("entries")) |es| if (es == .array) try lib.entries.appendSlice(a, es.array.items);
    capacity(&lib) catch |e| {
        last_error = message(e);
        return e;
    };
    return lib;
}

fn exists(io: std.Io, p: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return true;
}

/// Written as `replace_file_recoverably` writes it: a temporary file, the
/// old one kept as `.bak` until the new one is in place.
pub fn save(a: Allocator, io: std.Io, dir: []const u8, lib: *const Library) !void {
    try capacity(lib);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var aw: std.Io.Writer.Allocating = .init(a);
    var arr = json.Array.init(a);
    try arr.appendSlice(lib.entries.items);
    var root: json.ObjectMap = .empty;
    try root.put(a, "entries", .{ .array = arr });
    try json.Stringify.value(json.Value{ .object = root }, .{ .whitespace = .indent_2 }, &aw.writer);
    if (aw.written().len > max_library_bytes) return error.LibraryTooLarge;
    const p = try libraryPath(a, dir);
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{p});
    const backup = try std.fmt.allocPrint(a, "{s}.bak", .{p});
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = aw.written() });
    if (!exists(io, p)) return cwd.rename(tmp, cwd, p, io);
    if (exists(io, backup)) try cwd.deleteFile(io, backup);
    try cwd.rename(p, cwd, backup, io);
    cwd.rename(tmp, cwd, p, io) catch |e| {
        cwd.rename(backup, cwd, p, io) catch {};
        return e;
    };
    cwd.deleteFile(io, backup) catch {};
}

fn capacity(lib: *const Library) !void {
    if (lib.entries.items.len > max_entries) return error.TooManyEntries;
    if (lib.variantCount() > max_variants) return error.TooManyVariants;
}

/// What an operation's error reads as, as the GPUI app words it.
pub fn message(e: anyerror) []const u8 {
    return switch (e) {
        error.TooManyEntries => "custom theme library is limited to 256 entries",
        error.TooManyVariants => "custom theme library is limited to 1024 variants",
        error.NothingSelected => "select at least one successfully compiled variant",
        error.UnknownTheme => "unknown custom theme",
        error.CannotReload => "imported snapshots cannot reload",
        error.NoLocation => "theme source has no location to reveal",
        error.LibraryTooLarge => "custom theme library exceeds the 16777216-byte limit",
        else => @errorName(e),
    };
}

/// `unique_id`: `base`, else `base-2`, `base-3`… whichever no entry has.
pub fn uniqueId(a: Allocator, lib: *const Library, base: []const u8) ![]const u8 {
    const taken = struct {
        fn f(l: *const Library, id: []const u8) bool {
            for (l.entries.items) |v| if (v == .object) if (v.object.get("id")) |x| if (x == .string and std.mem.eql(u8, x.string, id)) return true;
            return false;
        }
    };
    if (!taken.f(lib, base)) return base;
    var n: usize = 2;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(a, "{s}-{d}", .{ base, n });
        if (!taken.f(lib, candidate)) return candidate;
    }
}

/// `rekey_family`: the family and each variant under `new_id`.
fn rekey(a: Allocator, family: *imp.Compilation, new_id: []const u8) !void {
    const old = family.family_id;
    family.family_id = new_id;
    for (family.variants.items) |*v| {
        v.family_id = new_id;
        v.id = if (std.mem.startsWith(u8, v.id, old)) try std.fmt.allocPrint(a, "{s}{s}", .{ new_id, v.id[old.len..] }) else try std.fmt.allocPrint(a, "{s}-{s}", .{ new_id, v.id });
    }
}

/// The blocking problems (`validation_errors`): structural errors only.
fn blocking(a: Allocator, c: *const imp.Compilation) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (c.variants.items) |*v| {
        var issues: std.ArrayList(imp.Issue) = .empty;
        if (seen.contains(v.id)) try issues.append(a, .{ .variant_id = v.id, .structural = true, .err = true, .message = "variant id must be unique" });
        try seen.put(a, v.id, {});
        try imp.validate(a, v, &issues);
        for (issues.items) |i| if (i.structural and i.err) {
            if (out.items.len > 0) try out.appendSlice(a, "; ");
            try out.print(a, "{s}: {s}", .{ i.variant_id, i.message });
        };
    }
    return out.items;
}

pub var last_error: []const u8 = "";

/// `install`: the selected variants (all, when none are named) as a new
/// entry, kept as a copy or linked to `c.path`; its id.
pub fn install(a: Allocator, lib: *Library, compiled: imp.Compilation, selected: []const []const u8, link: bool) ![]const u8 {
    var c = compiled;
    var kept: std.ArrayList(imp.Variant) = .empty;
    var kept_reports: std.ArrayList(imp.Report) = .empty;
    for (c.variants.items, c.reports.items) |v, r| {
        var wanted = selected.len == 0;
        for (selected) |s| wanted = wanted or std.mem.eql(u8, s, v.id);
        if (wanted) {
            try kept.append(a, v);
            try kept_reports.append(a, r);
        }
    }
    if (kept.items.len == 0) return error.NothingSelected;
    if (lib.entries.items.len >= max_entries) return error.TooManyEntries;
    if (lib.variantCount() + kept.items.len > max_variants) return error.TooManyVariants;
    c.variants = kept;
    c.reports = kept_reports;
    const entry_id = try uniqueId(a, lib, c.family_id);
    if (!std.mem.eql(u8, entry_id, c.family_id)) try rekey(a, &c, entry_id);
    const problems = try blocking(a, &c);
    if (problems.len > 0) {
        last_error = try std.fmt.allocPrint(a, "theme validation failed: {s}", .{problems});
        return error.Invalid;
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    const w = &aw.writer;
    try w.writeAll("{\"id\":");
    try json.Stringify.encodeJsonString(entry_id, .{}, w);
    try w.writeAll(",\"name\":");
    try json.Stringify.encodeJsonString(c.family_name, .{}, w);
    try w.writeAll(",\"source\":");
    if (!link) {
        try w.writeAll("{\"kind\":\"importedSnapshot\",\"importedFrom\":");
    } else if (c.package) {
        try w.writeAll("{\"kind\":\"linkedPackage\",\"path\":");
    } else try w.writeAll("{\"kind\":\"linkedFile\",\"path\":");
    try json.Stringify.encodeJsonString(c.path, .{}, w);
    try w.writeAll("},\"family\":{\"id\":");
    try json.Stringify.encodeJsonString(entry_id, .{}, w);
    try w.writeAll(",\"name\":");
    try json.Stringify.encodeJsonString(c.family_name, .{}, w);
    try w.writeAll(",\"variants\":[");
    for (c.variants.items, 0..) |*v, i| {
        if (i > 0) try w.writeByte(',');
        try imp.writeVariant(w, v);
    }
    try w.writeAll("]},\"reports\":{");
    for (c.variants.items, c.reports.items, 0..) |v, *r, i| {
        if (i > 0) try w.writeByte(',');
        try json.Stringify.encodeJsonString(v.id, .{}, w);
        try w.writeByte(':');
        try imp.writeReport(w, r);
    }
    try w.writeAll("},\"selectedVariantIds\":[");
    for (c.variants.items, 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try json.Stringify.encodeJsonString(v.id, .{}, w);
    }
    try w.writeAll("],\"status\":{\"kind\":\"ready\"}}");
    try lib.entries.append(a, try json.parseFromSliceLeaky(json.Value, a, aw.written(), .{}));
    return entry_id;
}

pub fn remove(lib: *Library, id: []const u8) !void {
    for (lib.entries.items, 0..) |v, i| if (v == .object) if (v.object.get("id")) |x| if (x == .string and std.mem.eql(u8, x.string, id)) {
        _ = lib.entries.orderedRemove(i);
        return;
    };
    return error.UnknownTheme;
}

/// `unlink`: a linked entry becomes a copy, still saying where it came from.
pub fn unlink(a: Allocator, lib: *Library, id: []const u8) !void {
    const o = lib.find(id) orelse return error.UnknownTheme;
    const was = view(.{ .object = o.* }) orelse return error.UnknownTheme;
    var source: json.ObjectMap = .empty;
    try source.put(a, "kind", .{ .string = "importedSnapshot" });
    try source.put(a, "importedFrom", if (was.path) |p| .{ .string = p } else .null);
    try o.put(a, "source", .{ .object = source });
    try setReady(a, o);
}

fn setReady(a: Allocator, o: *json.ObjectMap) !void {
    var status: json.ObjectMap = .empty;
    try status.put(a, "kind", .{ .string = "ready" });
    try o.put(a, "status", .{ .object = status });
}

fn setWarning(a: Allocator, o: *json.ObjectMap, text: []const u8) !void {
    var status: json.ObjectMap = .empty;
    try status.put(a, "kind", .{ .string = "warning" });
    try status.put(a, "message", .{ .string = text });
    try o.put(a, "status", .{ .object = status });
}

/// `reload`: a linked entry compiled again from its source; on any
/// failure the last good family stays and the entry says why. The library
/// is to be saved either way.
pub fn reload(a: Allocator, io: std.Io, lib: *Library, id: []const u8) !void {
    const o = lib.find(id) orelse return error.UnknownTheme;
    const e = view(.{ .object = o.* }) orelse return error.UnknownTheme;
    switch (e.kind) {
        .imported_snapshot => return error.CannotReload,
        .editable_file => {
            const p = e.path orelse return error.UnknownTheme;
            const text = std.Io.Dir.cwd().readFileAlloc(io, p, a, .limited(max_library_bytes)) catch {
                last_error = try std.fmt.allocPrint(a, "could not read editable theme {s}", .{p});
                try setWarning(a, o, last_error);
                return error.Failed;
            };
            const family = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch {
                last_error = try std.fmt.allocPrint(a, "could not parse editable theme {s}", .{p});
                try setWarning(a, o, last_error);
                return error.Failed;
            };
            const fid = if (family == .object) str(family.object, "id") orelse "" else "";
            if (!std.mem.eql(u8, fid, e.id)) {
                last_error = try std.fmt.allocPrint(a, "editable theme family id must remain `{s}` (found `{s}`)", .{ e.id, fid });
                try setWarning(a, o, last_error);
                return error.Failed;
            }
            var ids = json.Array.init(a);
            for (variantsOf(.{ .object = family.object })) |v| if (v == .object) if (v.object.get("id")) |x| try ids.append(x);
            try o.put(a, "selectedVariantIds", .{ .array = ids });
            try o.put(a, "name", family.object.get("name") orelse .{ .string = "" });
            try o.put(a, "family", family);
            try o.put(a, "reports", .{ .object = .empty });
            try setReady(a, o);
            return;
        },
        .linked_file, .linked_package => {},
    }
    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    if (o.get("selectedVariantIds")) |sv| if (sv == .array) for (sv.array.items) |x| if (x == .string) try wanted.put(a, x.string, {});
    const result = imp.compile(a, io, e.path orelse "", .{ .family_id = e.id, .family_name = e.name, .source_url = e.path orelse "" });
    const c = switch (result) {
        .err => |f| {
            last_error = f.message;
            try setWarning(a, o, f.message);
            return error.Failed;
        },
        .ok => |c| c,
    };
    var failed: std.ArrayList(u8) = .empty;
    for (c.failures.items) |f| if (wanted.contains(f.id)) {
        if (failed.items.len > 0) try failed.appendSlice(a, "; ");
        try failed.print(a, "{s}: {s}", .{ f.name, f.message });
    };
    if (failed.items.len > 0) {
        last_error = failed.items;
        try setWarning(a, o, last_error);
        return error.Failed;
    }
    var kept = c;
    kept.variants = .empty;
    kept.reports = .empty;
    for (c.variants.items, c.reports.items) |v, r| if (wanted.contains(v.id)) {
        try kept.variants.append(a, v);
        try kept.reports.append(a, r);
    };
    if (kept.variants.items.len == 0) {
        last_error = "the linked source no longer contains any selected variants";
        try setWarning(a, o, last_error);
        return error.Failed;
    }
    const problems = try blocking(a, &kept);
    if (problems.len > 0) {
        last_error = try std.fmt.allocPrint(a, "theme validation failed: {s}", .{problems});
        try setWarning(a, o, last_error);
        return error.Failed;
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    try aw.writer.writeAll("{\"family\":{\"id\":");
    try json.Stringify.encodeJsonString(kept.family_id, .{}, &aw.writer);
    try aw.writer.writeAll(",\"name\":");
    try json.Stringify.encodeJsonString(kept.family_name, .{}, &aw.writer);
    try aw.writer.writeAll(",\"variants\":[");
    for (kept.variants.items, 0..) |*v, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try imp.writeVariant(&aw.writer, v);
    }
    try aw.writer.writeAll("]},\"reports\":{");
    for (kept.variants.items, kept.reports.items, 0..) |v, *r, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try json.Stringify.encodeJsonString(v.id, .{}, &aw.writer);
        try aw.writer.writeByte(':');
        try imp.writeReport(&aw.writer, r);
    }
    try aw.writer.writeAll("}}");
    const fresh = try json.parseFromSliceLeaky(json.Value, a, aw.written(), .{});
    try o.put(a, "family", fresh.object.get("family").?);
    try o.put(a, "reports", fresh.object.get("reports").?);
    try setReady(a, o);
}

/// `duplicate_as_editable`: the family copied to a file of its own under
/// `custom-themes`, as an editable entry ("… Copy").
pub fn duplicateAsEditable(a: Allocator, io: std.Io, lib: *Library, dir: []const u8, id: []const u8) ![]const u8 {
    const o = lib.find(id) orelse return error.UnknownTheme;
    const original = view(.{ .object = o.* }) orelse return error.UnknownTheme;
    if (lib.entries.items.len >= max_entries) return error.TooManyEntries;
    if (lib.variantCount() + original.variants > max_variants) return error.TooManyVariants;
    const new_id = try uniqueId(a, lib, try std.fmt.allocPrint(a, "{s}-copy", .{original.id}));
    const fam_v = o.get("family") orelse return error.UnknownTheme;
    // A copy of the family, re-keyed.
    var aw0: std.Io.Writer.Allocating = .init(a);
    try json.Stringify.value(fam_v, .{}, &aw0.writer);
    var family = try json.parseFromSliceLeaky(json.Value, a, aw0.written(), .{});
    const old_id = str(family.object, "id") orelse original.id;
    try family.object.put(a, "id", .{ .string = new_id });
    try family.object.put(a, "name", .{ .string = try std.fmt.allocPrint(a, "{s} Copy", .{str(family.object, "name") orelse original.name}) });
    var ids = json.Array.init(a);
    if (family.object.getPtr("variants")) |vs| if (vs.* == .array) for (vs.array.items) |*v| if (v.* == .object) {
        const vid = str(v.object, "id") orelse "";
        const nid = if (std.mem.startsWith(u8, vid, old_id)) try std.fmt.allocPrint(a, "{s}{s}", .{ new_id, vid[old_id.len..] }) else try std.fmt.allocPrint(a, "{s}-{s}", .{ new_id, vid });
        try v.object.put(a, "id", .{ .string = nid });
        try v.object.put(a, "familyId", .{ .string = new_id });
        try ids.append(.{ .string = nid });
    };
    const folder = try std.fs.path.join(a, &.{ dir, "custom-themes" });
    try std.Io.Dir.cwd().createDirPath(io, folder);
    const file = try std.fs.path.join(a, &.{ folder, try std.fmt.allocPrint(a, "{s}.harness-theme.json", .{new_id}) });
    var aw: std.Io.Writer.Allocating = .init(a);
    try json.Stringify.value(family, .{ .whitespace = .indent_2 }, &aw.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = aw.written() });
    var entry: json.ObjectMap = .empty;
    try entry.put(a, "id", .{ .string = new_id });
    try entry.put(a, "name", family.object.get("name").?);
    var source: json.ObjectMap = .empty;
    try source.put(a, "kind", .{ .string = "editableFile" });
    try source.put(a, "path", .{ .string = file });
    try entry.put(a, "source", .{ .object = source });
    try entry.put(a, "family", family);
    try entry.put(a, "reports", .{ .object = .empty });
    try entry.put(a, "selectedVariantIds", .{ .array = ids });
    try setReady(a, &entry);
    try lib.entries.append(a, .{ .object = entry });
    return new_id;
}

const testing = std.testing;

test "an import installs as the GPUI app's library keeps it; a second takes the next id; unlink, duplicate and remove" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "Dusk.json", .data =
        \\{ "name": "Dusk", "type": "dark", "colors": { "editor.background": "#14161c", "foreground": "#d8dee9", "focusBorder": "#88c0d0" } }
    });
    const root = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}), a);
    const src = try std.fs.path.join(a, &.{ root, "Dusk.json" });
    var lib: Library = .{};
    for (0..2) |_| {
        const c = switch (imp.compile(a, testing.io, src, .{ .family_id = "custom-dusk", .family_name = "Dusk", .source_url = src })) {
            .ok => |c| c,
            .err => return error.Compile,
        };
        _ = try install(a, &lib, c, &.{}, false);
    }
    const es = try lib.views(a);
    try testing.expectEqual(@as(usize, 2), es.len);
    try testing.expectEqualStrings("custom-dusk", es[0].id);
    try testing.expectEqualStrings("custom-dusk-2", es[1].id);
    try testing.expectEqualStrings("Imported", es[0].label());
    try testing.expectEqualStrings(src, es[0].path.?);
    // The second's variant is re-keyed under its entry.
    try testing.expectEqualStrings("custom-dusk-2", variantsOf(lib.entries.items[1])[0].object.get("id").?.string);

    // Saved and read back as the same entries.
    try save(a, testing.io, root, &lib);
    var again = try load(a, testing.io, root);
    try testing.expectEqual(@as(usize, 2), (try again.views(a)).len);

    const copy = try duplicateAsEditable(a, testing.io, &again, root, "custom-dusk");
    try testing.expectEqualStrings("custom-dusk-copy", copy);
    try testing.expectEqualStrings("Editable file", (try again.views(a))[2].label());
    try remove(&again, "custom-dusk-2");
    try testing.expectEqual(@as(usize, 2), (try again.views(a)).len);
    try testing.expectError(error.UnknownTheme, remove(&again, "nope"));
}
