//! Appearance's theme library as the GPUI app's (settings/appearance.rs):
//! "Add a theme" (a local VS Code theme, package or extension folder,
//! analysed and imported as a copy or linked to its source), the library's
//! imported and linked entries with their actions, and "Theme mapping",
//! what an entry's import made of each colour.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const themes = @import("themes.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const look = @import("view_settings_appearance.zig");
const dialogs = @import("view_chat_menu.zig");
const imp = @import("theme_import.zig");
const library = @import("theme_library.zig");
const ops = @import("app_theme_library.zig");
const mc = @import("model_color.zig");
const App = @import("app.zig").App;
const Color = ui.Color;

/// The open "Add a theme" dialog (`ImportDialog`).
pub const Import = struct {
    /// The compilation and what's made of it; reset when it's compiled again.
    arena: std.heap.ArenaAllocator,
    source: ui.TextBuffer = .{},
    focus: bool = true,
    link: bool = false,
    compilation: ?imp.Compilation = null,
    /// The compilation as the GPUI app serializes it: its variants'
    /// colours and its reports, read as the library's are.
    doc: ?json.ObjectMap = null,
    selected: std.StringHashMapUnmanaged(void) = .empty,
    review: ?[]const u8 = null,
    err: std.ArrayList(u8) = .empty,
    /// What was clicked, done at the next frame's start (`settleFrame`):
    /// each frees or remakes what this frame drew.
    pending: enum { none, close, primary, browse } = .none,
};

pub fn open(a: *App) void {
    close(a);
    const d = a.gpa.create(Import) catch return;
    d.* = .{ .arena = .init(a.gpa) };
    a.view.theme_import = d;
}

pub fn close(a: *App) void {
    const d = a.view.theme_import orelse return;
    d.arena.deinit();
    d.err.deinit(a.gpa);
    a.gpa.destroy(d);
    a.view.theme_import = null;
}

/// Escape closes the dialog, or the review.
pub fn escape(c: *ui.Context, a: *App) void {
    if (a.view.theme_import == null and !a.view.theme_review_open) return;
    if (!c.shortcut(.{ .key = ui.Shortcut.escape })) return;
    close(a);
    a.view.theme_review_open = false;
}

pub fn anyOpen(a: *const App) bool {
    return a.view.theme_import != null or a.view.theme_review_open;
}

/// `source_name`: a package's folder, else the file's stem.
pub fn sourceName(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    var p = trimmed;
    if (std.mem.eql(u8, std.fs.path.basename(p), "package.json")) p = std.fs.path.dirname(p) orelse p;
    const base = std.fs.path.basename(p);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| (if (dot == 0) base else base[0..dot]) else base;
    return if (stem.len == 0) "Custom theme" else stem;
}

/// `compile_import`.
fn compile(a: *App, d: *Import) void {
    d.err.clearRetainingCapacity();
    const source = std.mem.trim(u8, d.source.text(), " \t\n\r");
    if (source.len == 0) {
        d.err.appendSlice(a.gpa, "Choose a local theme file or extension folder.") catch {};
        return;
    }
    _ = d.arena.reset(.retain_capacity);
    d.compilation = null;
    d.doc = null;
    d.selected = .empty;
    d.review = null;
    const ar = d.arena.allocator();
    const path = ar.dupe(u8, source) catch return;
    const name = sourceName(path);
    const id = std.fmt.allocPrint(ar, "custom-{s}", .{imp.slug(ar, name) catch return}) catch return;
    switch (imp.compile(ar, a.io, path, .{ .family_id = id, .family_name = name, .source_url = path })) {
        .err => |f| d.err.appendSlice(a.gpa, f.message) catch {},
        .ok => |c| {
            for (c.variants.items) |v| d.selected.put(ar, v.id, {}) catch {};
            var aw: std.Io.Writer.Allocating = .init(ar);
            imp.writeCompilation(&aw.writer, &c) catch return;
            const doc = json.parseFromSliceLeaky(json.Value, ar, aw.written(), .{}) catch return;
            d.doc = if (doc == .object) doc.object else null;
            d.compilation = c;
        },
    }
}

/// `finish_import`.
fn finish(a: *App, d: *Import) void {
    if (d.selected.count() == 0) {
        d.err.clearRetainingCapacity();
        d.err.appendSlice(a.gpa, "Select at least one variant to import.") catch {};
        return;
    }
    const c = d.compilation orelse return;
    const ar = d.arena.allocator();
    var ids: std.ArrayList([]const u8) = .empty;
    for (c.variants.items) |v| if (d.selected.contains(v.id)) ids.append(ar, v.id) catch return;
    if (ops.install(a, c, ids.items, d.link, &d.err)) close(a);
}

fn analyzeOrFinish(a: *App, d: *Import) void {
    if (d.compilation != null) finish(a, d) else compile(a, d);
}

/// GPUI's `overflow_y_scroll` scrolls with no bar drawn.
fn bare(d: ui.Div) ui.Div {
    if (@hasField(ui.Style, "scrollbar")) d.c.node(d.index).style.scrollbar = .{ .overlay = .{ .a = 0 } };
    return d;
}

fn hairline(k: theme.Colors, alpha: f32) Color {
    return if (k.dark) .{ .r = 1, .g = 1, .b = 1, .a = alpha } else .{ .a = @min(alpha * 1.35, 0.5) };
}

fn rule(c: *ui.Context, color: Color) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = color }, .none, null);
}

fn space(c: *ui.Context, h: f32) void {
    _ = c.leaf(.{ .height = .{ .px = h } }, .none, null);
}

/// `compact_action`: 28 high, 9 a side, bordered, 11.5-point words.
fn compactAction(c: *ui.Context, a: *App, k: theme.Colors, label: []const u8, o: struct { h: f32 = 28, px: f32 = 9, color: ?Color = null }) bool {
    const fill = k.raised.alpha(0.34);
    // `btn_ghost`'s hover is a listener's, and only its words show it.
    const lh = kit.listenerHover(&a.view.hovers, ui.div(c).row().h(o.h).px(o.px + 1).itemsCenter().rounded(7).border(k.border).borderW(1).bg(fill), fill);
    const b = lh.div;
    defer b.end();
    ui.text(c, label, set.st(c, 11.5, .{ .color = o.color orelse if (lh.hovered) k.text else k.muted }));
    return b.clicked();
}

fn compactWidth(c: *ui.Context, label: []const u8) f32 {
    return 2 * 10 + @ceil(c.text.width(label, .{ .size = 11.5 }));
}

/// The open "Add a theme" dialog, over the page.
pub fn dialog(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = a.view.theme_import orelse return;
    const back = dialogs.scrim(c, k);
    defer back.end();
    ui.key(c, "theme-import-card");
    const card = kit.shadowLg(ui.div(c).w(600).maxH(760).column().p(1).rounded(16).bg(k.composer).border(hairline(k, 0.10)).borderW(1).clip());
    defer card.end();
    // `on_mouse_down_out`.
    if (kit.pressedOutside(c, c.rects.get(c.node(card.index).id))) return close(a);
    if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) d.pending = .primary;
    var act: enum { none, close, browse, primary } = .none;
    {
        const h = ui.div(c).row().wFull().px(20).pt(18).pb(16).gap(16);
        defer h.end();
        {
            // Wrapped words need their width up front: the card less its
            // insets, the gap and the close button.
            const words = ui.div(c).column().w(600 - 2 - 40 - 16 - 28);
            defer words.end();
            ui.text(c, "Add a theme", set.st(c, 15, .{ .weight = .semibold, .color = k.text }));
            space(c, 4);
            ui.text(c, "Import a local theme into your library or keep it linked to its source.", .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
        }
        const x = ui.div(c).row().size(28, 28).center().rounded(7).border(k.border).borderW(1).bg(k.raised.alpha(0.28)).hover(k.raised);
        defer x.end();
        icons.icon(c, .close, 12, k.muted, 0);
        if (x.clicked()) act = .close;
    }
    {
        const main = bare(ui.div(c).column().wFull().maxH(520).scrollY().px(20).pb(18));
        defer main.end();
        sectionLabel(c, k, "Source", 7);
        {
            const r = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer r.end();
            {
                const f = ui.div(c).row().grow().w(0).h(36).px(13).itemsCenter().rounded(8).border(hairline(k, 0.08)).borderW(1).bg(k.ink(0.04));
                defer f.end();
                const at = c.nodes.items.len;
                const res = ui.textField(c, &d.source, .{ .placeholder = "Theme file, package.json, or extension folder", .placeholder_color = k.faint, .width = .fill, .bare = true, .size = 14, .line_height = 22.75 });
                if (d.focus) {
                    c.focus = c.node(@intCast(at)).id;
                    c.changed = true;
                    d.focus = false;
                }
                // Edited to name another source, the analysis goes
                // (`ComposerInputEvent::Edited`); the compiled path is
                // canonical, so a typed one only matching it keeps it.
                if (res.changed) if (d.compilation) |comp| if (!std.mem.eql(u8, comp.path, std.mem.trim(u8, d.source.text(), " \t\n\r"))) {
                    d.compilation = null;
                    d.doc = null;
                    d.selected = .empty;
                    d.review = null;
                    d.err.clearRetainingCapacity();
                };
                if (res.submitted) d.pending = .primary;
            }
            if (compactAction(c, a, k, "Browse…", .{ .h = 36, .px = 12 })) act = .browse;
        }
        space(c, 16);
        sectionLabel(c, k, "Keep it up to date", 7);
        {
            const r = ui.div(c).row().wFull().gap(8);
            defer r.end();
            if (modeControl(c, k, "Import a copy", "Works independently from the original file.", !d.link)) d.link = false;
            if (modeControl(c, k, "Link to source", "Reload changes from the file on disk.", d.link)) d.link = true;
        }
        if (d.compilation) |comp| detected(c, a, k, d, comp) else {
            space(c, 14);
            const r = ui.div(c).row().wFull().gap(7);
            defer r.end();
            {
                // GPUI's icon is given no colour and draws nothing; its room
                // stays.
                _ = c.leaf(.{ .width = .{ .px = 13 }, .height = .{ .px = 14 } }, .none, null);
            }
            ui.text(c, "Harness finds light and dark variants automatically.", .{ .size = 11, .line_height = 16, .color = k.muted });
        }
        if (d.err.items.len > 0) {
            space(c, 12);
            const r = ui.div(c).row().wFull().p(10).gap(7).rounded(8).bg(k.danger.alpha(0.08));
            defer r.end();
            {
                // As the info line's, drawn in no colour.
                _ = c.leaf(.{ .width = .{ .px = 13 }, .height = .{ .px = 14 } }, .none, null);
            }
            const st: ui.TextStyle = .{ .size = 11, .line_height = 16, .color = k.danger };
            kit.ellipsisText(c, c.alloc().dupe(u8, d.err.items) catch "", st, 600 - 2 - 40 - 20 - 13 - 7);
        }
    }
    rule(c, hairline(k, 0.08));
    {
        const f = ui.div(c).row().wFull().px(20).py(12).gap(8).itemsCenter().justifyEnd().bg(k.raised.alpha(0.18));
        defer f.end();
        if (compactAction(c, a, k, "Cancel", .{ .h = 34, .px = 13 })) act = .close;
        const ready = d.compilation != null and d.selected.count() > 0;
        var b = ui.div(c).row().h(34).px(14).itemsCenter().rounded(8).bg(k.solid);
        if (d.compilation != null and !ready) b = b.opacity(0.45);
        defer b.end();
        ui.text(c, if (d.compilation != null) "Import selected" else "Analyze theme", set.st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
        if (b.clicked() and (d.compilation == null or ready)) act = .primary;
    }
    switch (act) {
        .none => {},
        .close => d.pending = .close,
        .primary => d.pending = .primary,
        .browse => d.pending = .browse,
    }
    if (d.pending != .none) c.animating = true;
}

/// At a frame's start, before anything is drawn: what last frame's clicks
/// asked of the dialog and the library, done now that nothing drawn reads
/// what they free.
pub fn settleFrame(a: *App) void {
    if (a.view.theme_reload) {
        a.view.theme_reload = false;
        if (a.settings.dataDir()) |dir| themes.loadLibrary(a.io, dir);
    }
    if (a.view.theme_pending) |p| {
        a.view.theme_pending = null;
        ops.run(a, p);
    }
    const d = a.view.theme_import orelse return;
    const pending = d.pending;
    d.pending = .none;
    switch (pending) {
        .none => {},
        .close => close(a),
        .primary => analyzeOrFinish(a, d),
        .browse => {
            // `choose_import_source`.
            const picked = nanoui.dialog.open(a.gpa, .{ .title = "Choose Theme Source", .button = "Choose", .files = true, .directories = true }) catch return;
            const paths = picked orelse return;
            defer nanoui.dialog.freePaths(a.gpa, paths);
            if (paths.len == 0) return;
            d.source.set(paths[paths.len - 1]);
            compile(a, d);
        },
    }
}

fn sectionLabel(c: *ui.Context, k: theme.Colors, label: []const u8, below: f32) void {
    ui.text(c, label, set.st(c, 11, .{ .weight = .semibold, .color = k.muted }));
    if (below > 0) space(c, below);
}

/// An install mode: a radio, its name and what it means.
fn modeControl(c: *ui.Context, k: theme.Colors, label: []const u8, description: []const u8, active: bool) bool {
    var box = ui.div(c).column().w((600 - 2 - 40 - 8) / 2).p(11).rounded(9).border(if (active) k.accent else k.border).borderW(1).bg(if (active) k.accent_wash else k.raised.alpha(0.28));
    if (!active) box = box.hover(k.raised);
    defer box.end();
    {
        const r = ui.div(c).row().gap(7).itemsCenter();
        defer r.end();
        const dot = ui.div(c).row().size(16, 16).center().roundedFull().border(if (active) k.accent else k.border_strong).borderW(1);
        {
            defer dot.end();
            if (active) _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = k.accent }, .none, null);
        }
        ui.text(c, label, set.st(c, 12, .{ .weight = .medium, .color = if (active) k.text else k.muted }));
    }
    const m = ui.div(c).row().pt(4).pl(23);
    defer m.end();
    ui.text(c, description, set.st(c, 10.5, .{ .wrap = true, .color = k.muted }));
    return box.clicked();
}

fn variantsOf(doc: ?json.ObjectMap) []const json.Value {
    const o = doc orelse return &.{};
    const fam = o.get("family") orelse return &.{};
    if (fam != .object) return &.{};
    const vs = fam.object.get("variants") orelse return &.{};
    return if (vs == .array) vs.array.items else &.{};
}

fn reportOf(doc: json.ObjectMap, id: []const u8) ?json.ObjectMap {
    const rs = doc.get("reports") orelse return null;
    if (rs != .object) return null;
    const r = rs.object.get(id) orelse return null;
    return if (r == .object) r.object else null;
}

fn str(o: json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// "Detected themes": each variant with its checkbox, preview and Details;
/// then the ones that didn't compile.
fn detected(c: *ui.Context, a: *App, k: theme.Colors, d: *Import, comp: imp.Compilation) void {
    space(c, 18);
    rule(c, hairline(k, 0.08));
    {
        const h = ui.div(c).row().wFull().pt(16).itemsEnd().justifyBetween();
        defer h.end();
        sectionLabel(c, k, "Detected themes", 0);
        const n = comp.variants.items.len;
        ui.text(c, c.print("{d} variant{s}", .{ n, if (n == 1) "" else "s" }), set.st(c, 10.5, .{ .color = k.muted }));
    }
    const doc = d.doc orelse return;
    for (variantsOf(d.doc)) |v| {
        if (v != .object) continue;
        const id = str(v.object, "id");
        const t = themes.colorsOf(v.object) orelse continue;
        const on = d.selected.contains(id);
        const reviewing_this = if (d.review) |r| std.mem.eql(u8, r, id) else false;
        space(c, 8);
        ui.key(c, c.print("theme-import-row-{s}", .{id}));
        const row = ui.div(c).column().wFull().p(12).rounded(10).border(if (on) k.accent.alpha(0.7) else k.border).borderW(1).bg(if (on) k.accent_wash.alpha(0.42) else k.raised.alpha(0.22));
        defer row.end();
        {
            const r = ui.div(c).row().wFull().gap(9).itemsCenter();
            defer r.end();
            const box = ui.div(c).row().size(18, 18).center().rounded(5).border(if (on) k.accent else k.border_strong).borderW(1).bg(if (on) k.accent else k.background);
            {
                defer box.end();
                if (on) icons.icon(c, .check, 12, onAccent(k.accent), 0);
            }
            if (box.clicked()) {
                if (on) _ = d.selected.remove(id) else d.selected.put(d.arena.allocator(), id, {}) catch {};
            }
            look.preview(c, k, t);
            {
                const w = ui.div(c).column().grow().w(0);
                defer w.end();
                ui.text(c, str(v.object, "name"), set.st(c, 12.5, .{ .weight = .medium, .color = k.text }));
                ui.text(c, if (t.dark) "Dark" else "Light", set.st(c, 11, .{ .color = k.muted }));
            }
            if (compactAction(c, a, k, if (reviewing_this) "Hide details" else "Details", .{})) d.review = if (reviewing_this) null else id;
        }
        if (reviewing_this) {
            space(c, 10);
            rule(c, hairline(k, 0.08));
            space(c, 10);
            scenePreview(c, t);
            if (reportOf(doc, id)) |rep| _ = reportPanel(c, k, rep, null);
        }
    }
    for (comp.failures.items) |f| {
        space(c, 8);
        const r = ui.div(c).row().wFull().p(10).rounded(8).bg(k.warning.alpha(0.08));
        defer r.end();
        ui.text(c, c.print("{s} could not be compiled · {s}", .{ f.name, f.message }), set.st(c, 11, .{ .wrap = true, .color = k.warning }));
    }
}

/// `theme.on_accent`: white or black, whichever reads on the accent.
fn onAccent(accent: Color) Color {
    const q = struct {
        fn f(x: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
        }
    };
    return (mc.Rgba{ .r = q.f(accent.r), .g = q.f(accent.g), .b = q.f(accent.b) }).bestOn().color();
}

/// `import_scene_preview`: the window in little, code in the theme's
/// colours over its terminal's first eight, and its diff and accent washes.
fn scenePreview(c: *ui.Context, t: theme.Colors) void {
    const r = ui.div(c).row().wFull().h(86).gap(8);
    defer r.end();
    {
        const m = ui.div(c).row().w(152).hFull().p(1).rounded(8).border(t.border).borderW(1).clip();
        defer m.end();
        look.miniature(c, t, 150, .all);
    }
    {
        const code = ui.div(c).column().grow().w(0).hFull().p(10).gap(6).rounded(8).border(t.border).borderW(1).bg(t.background).clip();
        defer code.end();
        const mono = struct {
            fn st(cc: *ui.Context, color: Color) ui.TextStyle {
                return set.st(cc, 10, .{ .mono = true, .color = color });
            }
        };
        {
            // Blocks, as GPUI lays a div's children out unless it's a flex.
            const line = ui.div(c).column();
            defer line.end();
            ui.text(c, "fn ", mono.st(c, t.syntax.keyword));
            ui.text(c, "preview", mono.st(c, t.syntax.function));
            ui.text(c, "() {", mono.st(c, t.syntax.punctuation));
        }
        ui.text(c, "  \"Theme mapping\"", mono.st(c, t.syntax.string));
        ui.spacer(c);
        const bar = ui.div(c).row().wFull().h(12).rounded(3).clip();
        defer bar.end();
        for (t.ansi[0..8]) |col| _ = c.leaf(.{ .grow = 1, .width = .{ .px = 0 }, .height = .fill, .background = col }, .none, null);
    }
    const side = ui.div(c).column().w(84).hFull().p(9).gap(6).rounded(8).border(t.border).borderW(1).bg(t.shell);
    defer side.end();
    for ([_]Color{ t.diff_add.alpha(0.35), t.diff_del.alpha(0.35), t.accent_wash }) |col| _ = c.leaf(.{ .width = .fill, .height = .{ .px = 12 }, .radius = 3, .background = col }, .none, null);
}

fn count(o: json.ObjectMap, key: []const u8) usize {
    const v = o.get(key) orelse return 0;
    return if (v == .array) v.array.items.len else 0;
}

fn items(o: json.ObjectMap, key: []const u8) []const json.Value {
    const v = o.get(key) orelse return &.{};
    return if (v == .array) v.array.items else &.{};
}

/// `{:?}` of a camelCase enum's name: its first letter raised.
fn debugName(c: *ui.Context, s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const out = c.alloc().dupe(u8, s) catch return s;
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// `report_panel`: what the import made of each colour, in counts and lines.
fn reportPanel(c: *ui.Context, k: theme.Colors, r: json.ObjectMap, height: ?f32) Span {
    space(c, 8);
    var p = bare(ui.div(c).column().wFull().maxH(168).scrollY().p(11).rounded(8).border(k.border).borderW(1).bg(k.raised.alpha(0.35)));
    if (height) |h| p = p.h(h);
    defer p.end();
    const st: ui.TextStyle = .{ .size = 11, .line_height = 16, .wrap = true, .color = k.muted };
    var tx = st;
    tx.color = k.text;
    ui.text(c, c.print("{d} mapped · {d} adjusted · {d} inferred/fallback · {d} unsupported · {d} warnings · {d} validation", .{
        count(r, "mappings"), count(r, "adjustments"), count(r, "fallbacks"), count(r, "dropped"), count(r, "warnings"), count(r, "validation"),
    }), tx);
    const line = struct {
        fn f(cc: *ui.Context, s: []const u8, style: ui.TextStyle) void {
            space(cc, 4);
            ui.text(cc, s, style);
        }
    };
    for (items(r, "adjustments")) |x| if (x == .object) line.f(c, c.print("Adjusted · {s} {s} → {s} · {s}", .{ str(x.object, "harnessRole"), str(x.object, "original"), str(x.object, "resolved"), str(x.object, "reason") }), st);
    for (items(r, "fallbacks")) |x| if (x == .string) line.f(c, c.print("Fallback · {s}", .{x.string}), st);
    for (items(r, "warnings")) |x| if (x == .string) line.f(c, c.print("Warning · {s}", .{x.string}), st);
    for (items(r, "validation")) |x| if (x == .object) line.f(c, c.print("Validation {s} {s} · {s}", .{ debugName(c, str(x.object, "category")), debugName(c, str(x.object, "severity")), str(x.object, "message") }), st);
    for (items(r, "dropped")) |x| if (x == .string) line.f(c, c.print("Unsupported · {s}", .{x.string}), st);
    for (items(r, "mappings")) |x| if (x == .object) line.f(c, c.print("{s} ← {s}", .{ str(x.object, "harnessRole"), str(x.object, "vscodeKey") }), st);
    return .{ .box = p.index, .first = p.index + 1, .last = @intCast(c.nodes.items.len - 1) };
}

/// A box's node, and its first and last within.
const Span = struct { box: u32, first: u32, last: u32 };

/// `report_panel`'s height as GPUI's flex column gives it when the card
/// would pass its cap: scrolling, a panel may shrink to nothing, and the
/// room missing comes off each in proportion to its size (flex-shrink);
/// what else the card holds keeps its height. `bases` are the panels'
/// own heights, `rest` everything else's, `room` the card's inside.
pub fn shrinkPanels(bases: []const f32, rest: f32, room: f32, out: []f32) void {
    var total: f32 = 0;
    for (bases) |b| total += b;
    const excess = rest + total - room;
    for (bases, out[0..bases.len]) |b, *o| o.* = if (excess > 0 and total > 0) @max(0, b - excess * b / total) else b;
}

/// What the review measured last frame: each panel's own height and the
/// rest of the card's.
var review_bases: [32]f32 = undefined;
var review_n: usize = 0;
var review_rest: f32 = 0;

// The library's rows.

/// The imported entries, then the linked, each under its heading; an
/// entry's action runs once they're drawn.
pub fn libraryRows(c: *ui.Context, a: *App, k: theme.Colors) void {
    const entries = themes.library.views(c.alloc()) catch return;
    var pending: ?ops.Pending = null;
    for ([_]bool{ false, true }) |linked| {
        var any = false;
        for (entries) |e| any = any or e.linked() == linked;
        if (!any) continue;
        rule(c, k.border);
        {
            const h = ui.div(c).row().wFull().px(16).pt(12).pb(4);
            defer h.end();
            ui.text(c, if (linked) "LINKED" else "IMPORTED", set.st(c, 10.5, .{ .weight = .semibold, .color = k.faint }));
        }
        for (entries) |e| if (e.linked() == linked) {
            if (entry(c, a, k, e)) |kind| pending = .of(kind, e.id);
        };
    }
    if (pending) |p| {
        a.view.theme_pending = p;
        c.animating = true;
    }
}

fn entry(c: *ui.Context, a: *App, k: theme.Colors, e: library.Entry) ?ops.Kind {
    ui.key(c, c.print("theme-entry-{s}", .{e.id}));
    const r = set.row(c, k, false, false);
    defer r.end();
    set.tile(c, k, if (e.linked()) .global else .document);
    const actions = [_]struct { ops.Kind, []const u8, bool }{
        .{ .reload, "Reload", e.linked() },
        .{ .reveal, "Reveal", true },
        .{ .reveal, "Review", true },
        .{ .duplicate, "Duplicate as editable", true },
        .{ .unlink, "Unlink", e.linked() },
        .{ .remove, "Remove", true },
    };
    var actions_w: f32 = 0;
    var shown: f32 = 0;
    for (actions) |x| if (x[2]) {
        actions_w += compactWidth(c, x[1]);
        shown += 1;
    };
    actions_w += 2 * (shown - 1);
    const words_w = @max(set.inner_w - 2 - 2 * 20 - 36 - 14 - 14 - actions_w, 40);
    {
        const w = ui.div(c).column().grow().w(0);
        defer w.end();
        ui.text(c, e.name, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
        const status = if (e.warning) |m|
            c.print("Using last known good · {s}", .{m})
        else
            c.print("{s} · {d} variant{s} · {s}", .{ e.label(), e.variants, if (e.variants == 1) "" else "s", e.path orelse "Self-contained snapshot" });
        kit.ellipsisText(c, status, set.st(c, 11, .{ .color = if (e.warning != null) k.warning else k.muted }), words_w);
    }
    const row = ui.div(c).row().gap(2).itemsCenter();
    defer row.end();
    var out: ?ops.Kind = null;
    for (actions) |x| if (x[2]) {
        const danger = x[0] == .remove;
        if (compactAction(c, a, k, x[1], .{ .color = if (danger) k.danger else null })) {
            if (std.mem.eql(u8, x[1], "Review")) {
                reviewing = e.id;
            } else out = x[0];
        }
    };
    return out;
}

/// The entry whose Review was clicked this frame; the app keeps its id.
var reviewing: ?[]const u8 = null;

/// Takes this frame's Review click into the app's state.
pub fn settle(a: *App) void {
    const id = reviewing orelse return;
    reviewing = null;
    a.view.theme_review.clearRetainingCapacity();
    a.view.theme_review.appendSlice(a.gpa, id) catch return;
    a.view.theme_review_open = true;
}

/// `load_warning`, or the last action's error, under the page's cards.
pub fn warning(c: *ui.Context, a: *App, k: theme.Colors) void {
    const text = if (a.view.library_error.items.len > 0) a.view.library_error.items else themes.load_warning orelse return;
    space(c, 8);
    ui.text(c, c.alloc().dupe(u8, text) catch "", set.st(c, 11.5, .{ .wrap = true, .color = k.warning }));
}

/// "Theme mapping": an entry's variants, each in little with its report.
pub fn reviewDialog(c: *ui.Context, a: *App, k: theme.Colors) void {
    settle(a);
    if (!a.view.theme_review_open) return;
    const id = a.view.theme_review.items;
    const raw: json.ObjectMap = for (themes.library.views(c.alloc()) catch &.{}) |e| {
        if (std.mem.eql(u8, e.id, id)) break e.raw;
    } else {
        a.view.theme_review_open = false;
        return;
    };
    const e = for (themes.library.views(c.alloc()) catch &.{}) |x| {
        if (std.mem.eql(u8, x.id, id)) break x;
    } else unreachable;
    const back = dialogs.scrim(c, k);
    defer back.end();
    ui.key(c, "theme-review-card");
    const card = bare(kit.shadowLg(ui.div(c).w(660).maxH(720).scrollY().column().p(21).rounded(16).bg(k.composer).border(hairline(k, 0.10)).borderW(1)));
    defer card.end();
    ui.text(c, "Theme mapping", set.st(c, 15, .{ .weight = .semibold, .color = k.text }));
    space(c, 6);
    ui.text(c, c.print("{s} · {s}", .{ e.name, e.label() }), .{ .size = 13, .line_height = 19, .wrap = true, .color = k.muted });
    const fam = raw.get("family") orelse return;
    const vs = if (fam == .object) fam.object.get("variants") else null;
    // The panels' heights from what last frame measured (`shrinkPanels`).
    var heights: [32]f32 = undefined;
    shrinkPanels(review_bases[0..review_n], review_rest, 720 - 2 * 21, &heights);
    var spans: [32]Span = undefined;
    var n: usize = 0;
    if (vs) |list| if (list == .array) for (list.array.items) |v| if (v == .object) {
        space(c, 14);
        ui.text(c, str(v.object, "name"), set.st(c, 12.5, .{ .weight = .medium, .color = k.text }));
        if (themes.colorsOf(v.object)) |t| scenePreview(c, t);
        if (reportOf(raw, str(v.object, "id"))) |rep| if (n < spans.len) {
            spans[n] = reportPanel(c, k, rep, if (n < review_n) heights[n] else null);
            n += 1;
        };
    };
    space(c, 16);
    const f = ui.div(c).row().wFull().justifyEnd();
    {
        defer f.end();
        const b = ui.div(c).row().px(12).py(6).rounded(8).bg(k.solid);
        defer b.end();
        ui.text(c, "Done", set.st(c, 13, .{ .weight = .medium, .color = k.on_solid }));
        if (b.clicked()) a.view.theme_review_open = false;
    }
    measure(c, card.index + 1, f.index, spans[0..n]);
}

/// Last frame's layout of the card: each panel's content and the rest.
fn measure(c: *ui.Context, first: u32, last: u32, spans: []const Span) void {
    const rect = struct {
        fn of(cc: *ui.Context, i: u32) ?ui.Rect {
            return cc.rects.get(cc.node(i).id);
        }
    };
    const top = rect.of(c, first) orelse return;
    const bottom = rect.of(c, last) orelse return;
    var rest = bottom.y + bottom.h - top.y;
    var bases: [32]f32 = undefined;
    for (spans, 0..) |sp, i| {
        const box = rect.of(c, sp.box) orelse return;
        const a = rect.of(c, sp.first) orelse return;
        const z = rect.of(c, sp.last) orelse return;
        bases[i] = @min(z.y + z.h - a.y + 2 * 11, 168);
        rest -= box.h;
    }
    var same = spans.len == review_n and @abs(rest - review_rest) < 0.25;
    for (bases[0..spans.len], 0..) |b, i| same = same and i < review_n and @abs(b - review_bases[i]) < 0.25;
    if (same) return;
    @memcpy(review_bases[0..spans.len], bases[0..spans.len]);
    review_n = spans.len;
    review_rest = rest;
    c.animating = true;
}

test "report panels shrink as a flex column's scrolling children: in proportion, never below nothing" {
    var out: [3]f32 = undefined;
    // 3 × 168 and 362 of the rest in 678: 188 too much, 62.67 off each.
    shrinkPanels(&.{ 168, 168, 168 }, 362, 678, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 168 - 188.0 / 3.0), out[0], 0.01);
    // Room to spare: as they are.
    shrinkPanels(&.{ 100, 40 }, 100, 678, out[0..2]);
    try std.testing.expectEqual(@as(f32, 40), out[1]);
    // Unequal: the bigger gives more.
    shrinkPanels(&.{ 150, 50 }, 600, 678, out[0..2]);
    try std.testing.expectApproxEqAbs(@as(f32, 150 - 122 * 0.75), out[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50 - 122 * 0.25), out[1], 0.01);
}

test "a theme's name comes from its file, or its package's folder" {
    try std.testing.expectEqualStrings("Dusk", sourceName("/themes/Dusk.json"));
    try std.testing.expectEqualStrings("harbor", sourceName("/ext/harbor/package.json"));
    try std.testing.expectEqualStrings("harbor", sourceName("/ext/harbor"));
    try std.testing.expectEqualStrings("Sunset", sourceName("/t/Sunset.tmTheme"));
}
