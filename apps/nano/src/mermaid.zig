//! Fast zero-copy Mermaid parser + pre-computed Sugiyama graph rank/order
//! layout for `harness-nano` (ported from `nanodocs/src/mermaid.zig`).
//!
//! Parses `flowchart` / `graph` (`TD`, `LR`, `BT`, `RL`), `stateDiagram`,
//! `classDiagram`, `erDiagram`, `sequenceDiagram`, and `pie` charts, and
//! pre-computes cycle-breaking (`back`), longest-path `ranks`, barycenter
//! `order`, and topological `sorted` indices.
const std = @import("std");

pub const Dir = enum { down, up, right, left };

pub const Shape = enum { rect, round, stadium, circle, diamond, hexagon, cylinder, subroutine, flag, start, end };

pub const Node = struct { id: []const u8, label: []const u8, shape: Shape = .rect };

pub const Line = enum { solid, dotted, thick, invisible };

pub const Edge = struct {
    from: usize,
    to: usize,
    label: []const u8 = "",
    line: Line = .solid,
    head: bool = true,
    tail: bool = false,
};

pub const Flow = struct {
    kind_label: []const u8 = "FLOWCHART",
    dir: Dir = .down,
    nodes: []const Node,
    edges: []const Edge,
    back: []const bool = &.{},
    ranks: []const usize = &.{},
    num_ranks: usize = 0,
    sorted: []const usize = &.{},
    back_count: usize = 0,
};

pub const Actor = struct { id: []const u8, label: []const u8, person: bool = false };

pub const Step = union(enum) {
    message: struct { from: usize, to: usize, text: []const u8, dashed: bool, head: bool },
    note: struct { from: usize, to: usize, side: enum { left, right, over }, text: []const u8 },
    section: []const u8,
};

pub const Seq = struct { actors: []const Actor, steps: []const Step };

pub const PieSlice = struct { label: []const u8, value: f32 };
pub const Pie = struct { title: []const u8, slices: []const PieSlice };

pub const Diagram = union(enum) {
    flow: Flow,
    seq: Seq,
    pie: Pie,
    other: []const u8,

    pub fn drawable(d: Diagram) bool {
        return switch (d) {
            .flow => |f| f.nodes.len > 0,
            .seq => |s| s.actors.len > 0,
            .pie => |p| p.slices.len > 0,
            .other => false,
        };
    }
};

pub fn parse(arena: std.mem.Allocator, src: []const u8) Diagram {
    return parseOr(arena, src) catch .{ .other = "diagram" };
}

fn parseOr(arena: std.mem.Allocator, src: []const u8) !Diagram {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        var l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, l, "%%")) |c| l = std.mem.trim(u8, l[0..c], " \t");
        if (l.len > 0) try lines.append(arena, l);
    }
    if (lines.items.len == 0) return .{ .other = "empty" };
    const head = lines.items[0];
    var words = std.mem.tokenizeAny(u8, head, " \t");
    const kind = words.next() orelse "";
    if (std.mem.eql(u8, kind, "graph") or std.mem.eql(u8, kind, "flowchart")) {
        var f: FlowParser = .{ .arena = arena };
        f.dir = dirOf(words.next() orelse "TD");
        for (lines.items[1..]) |l| {
            var parts = std.mem.splitScalar(u8, l, ';');
            while (parts.next()) |stmt| try f.statement(std.mem.trim(u8, stmt, " \t"));
        }
        return .{ .flow = try f.finish("FLOWCHART") };
    }
    if (std.mem.startsWith(u8, kind, "stateDiagram")) {
        var f: FlowParser = .{ .arena = arena };
        for (lines.items[1..]) |l| try f.state(l);
        return .{ .flow = try f.finish("STATE DIAGRAM") };
    }
    if (std.mem.startsWith(u8, kind, "classDiagram") or std.mem.startsWith(u8, kind, "erDiagram")) {
        var f: FlowParser = .{ .arena = arena };
        for (lines.items[1..]) |l| try f.classOrEr(l);
        const kl = if (std.mem.startsWith(u8, kind, "er")) "ER DIAGRAM" else "CLASS DIAGRAM";
        return .{ .flow = try f.finish(kl) };
    }
    if (std.mem.eql(u8, kind, "sequenceDiagram")) {
        var s: SeqParser = .{ .arena = arena };
        for (lines.items[1..]) |l| try s.line(l);
        return .{ .seq = .{ .actors = s.actors.items, .steps = s.steps.items } };
    }
    if (std.mem.eql(u8, kind, "pie")) {
        return parsePie(arena, head, lines.items[1..]);
    }
    return .{ .other = kind };
}

fn parsePie(arena: std.mem.Allocator, head: []const u8, rest: []const []const u8) !Diagram {
    var title: []const u8 = "";
    if (std.mem.indexOf(u8, head, "title ")) |ti| {
        title = try label(arena, head[ti + 6 ..]);
    }
    var slices: std.ArrayList(PieSlice) = .empty;
    for (rest) |l| {
        if (std.mem.startsWith(u8, l, "title ")) {
            title = try label(arena, l[6..]);
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        const name = try label(arena, l[0..colon]);
        const val_str = std.mem.trim(u8, l[colon + 1 ..], " \t");
        const val = std.fmt.parseFloat(f32, val_str) catch continue;
        try slices.append(arena, .{ .label = name, .value = val });
    }
    return .{ .pie = .{ .title = title, .slices = slices.items } };
}

fn dirOf(s: []const u8) Dir {
    if (std.mem.eql(u8, s, "LR")) return .right;
    if (std.mem.eql(u8, s, "RL")) return .left;
    if (std.mem.eql(u8, s, "BT")) return .up;
    return .down;
}

fn label(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var t = std.mem.trim(u8, raw, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
    if (t.len >= 2 and t[0] == '`' and t[t.len - 1] == '`') t = t[1 .. t.len - 1];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var col: usize = 0;
    while (i < t.len) {
        const rest = t[i..];
        if (std.ascii.startsWithIgnoreCase(rest, "<br>") or std.ascii.startsWithIgnoreCase(rest, "<br/>") or std.ascii.startsWithIgnoreCase(rest, "<br />")) {
            try out.append(arena, '\n');
            i += std.mem.indexOfScalar(u8, rest, '>').? + 1;
            col = 0;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "\\n")) {
            try out.append(arena, '\n');
            i += 2;
            col = 0;
            continue;
        }
        if (t[i] == ' ' and col >= 28 and rest.len > 4) {
            try out.append(arena, '\n');
            i += 1;
            col = 0;
            continue;
        }
        try out.append(arena, t[i]);
        i += 1;
        col += 1;
    }
    return out.items;
}

const FlowParser = struct {
    arena: std.mem.Allocator,
    dir: Dir = .down,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,

    fn finish(f: *FlowParser, kind_label: []const u8) !Flow {
        const a = f.arena;
        const n = f.nodes.items.len;
        const edges = f.edges.items;
        const back = try a.alloc(bool, edges.len);
        @memset(back, false);
        const ranks = try a.alloc(usize, n);
        @memset(ranks, 0);

        // 1. Cycle breaking via iterative DFS
        const visit = try a.alloc(u8, n);
        @memset(visit, 0);
        var stack: std.ArrayList(struct { v: usize, next: usize }) = .empty;
        for (0..n) |root| {
            if (visit[root] != 0) continue;
            try stack.append(a, .{ .v = root, .next = 0 });
            visit[root] = 1;
            while (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.next >= edges.len) {
                    visit[top.v] = 2;
                    _ = stack.pop();
                    continue;
                }
                const k = top.next;
                top.next += 1;
                const e = edges[k];
                if (e.from != top.v or e.to >= n) continue;
                if (visit[e.to] == 1) {
                    back[k] = true;
                } else if (visit[e.to] == 0) {
                    visit[e.to] = 1;
                    try stack.append(a, .{ .v = e.to, .next = 0 });
                }
            }
        }

        // 2. Longest-path rank assignment
        var changed = true;
        var rounds: usize = 0;
        while (changed and rounds <= n) : (rounds += 1) {
            changed = false;
            for (edges, back) |e, is_back| {
                if (is_back or e.from >= n or e.to >= n) continue;
                if (ranks[e.to] < ranks[e.from] + 1) {
                    ranks[e.to] = ranks[e.from] + 1;
                    changed = true;
                }
            }
        }
        var num_ranks: usize = 0;
        for (ranks) |r| num_ranks = @max(num_ranks, r + 1);

        // 3. Barycenter ordering within ranks & pre-sorting node indices
        const ord = try a.alloc(f32, n);
        for (ord, 0..) |*o, i| o.* = @floatFromInt(i);
        const sum = try a.alloc(f32, n);
        const cnt = try a.alloc(f32, n);
        for (0..2) |_| {
            @memset(sum, 0);
            @memset(cnt, 0);
            for (edges, back) |e, is_back| {
                if (is_back or e.from >= n or e.to >= n) continue;
                sum[e.to] += ord[e.from];
                cnt[e.to] += 1;
            }
            for (ord, 0..) |*o, i| if (cnt[i] > 0) {
                o.* = sum[i] / cnt[i] + @as(f32, @floatFromInt(i)) * 0.001;
            };
        }

        const sorted = try a.alloc(usize, n);
        for (sorted, 0..) |*v, i| v.* = i;
        const SortCtx = struct {
            ranks: []const usize,
            ord: []const f32,
            fn lt(ctx: @This(), x: usize, y: usize) bool {
                return if (ctx.ranks[x] != ctx.ranks[y]) ctx.ranks[x] < ctx.ranks[y] else ctx.ord[x] < ctx.ord[y];
            }
        };
        std.mem.sort(usize, sorted, SortCtx{ .ranks = ranks, .ord = ord }, SortCtx.lt);

        var back_count: usize = 0;
        for (back) |is_b| if (is_b) {
            back_count += 1;
        };

        return .{
            .kind_label = kind_label,
            .dir = f.dir,
            .nodes = f.nodes.items,
            .edges = edges,
            .back = back,
            .ranks = ranks,
            .num_ranks = num_ranks,
            .sorted = sorted,
            .back_count = back_count,
        };
    }

    fn node(f: *FlowParser, id: []const u8, text: ?[]const u8, shape: ?Shape) !usize {
        for (f.nodes.items, 0..) |*n, i| if (std.mem.eql(u8, n.id, id)) {
            if (text) |t| n.label = t;
            if (shape) |s| n.shape = s;
            return i;
        };
        try f.nodes.append(f.arena, .{ .id = id, .label = text orelse id, .shape = shape orelse .rect });
        return f.nodes.items.len - 1;
    }

    fn statement(f: *FlowParser, s: []const u8) !void {
        if (s.len == 0) return;
        if (std.mem.eql(u8, s, "end") or std.mem.startsWith(u8, s, "end ") or std.mem.eql(u8, s, "subgraph") or std.mem.startsWith(u8, s, "subgraph ")) return;
        const skip = [_][]const u8{ "classDef ", "class ", "style ", "linkStyle ", "click ", "direction " };
        for (skip) |w| if (std.mem.startsWith(u8, s, w)) {
            if (std.mem.eql(u8, w, "direction ")) f.dir = dirOf(std.mem.trim(u8, s[w.len..], " "));
            return;
        };
        var i: usize = 0;
        var sources: std.ArrayList(usize) = .empty;
        try f.group(s, &i, &sources);
        while (true) {
            skipSpace(s, &i);
            const e = edgeAt(f.arena, s, &i) orelse break;
            skipSpace(s, &i);
            var targets: std.ArrayList(usize) = .empty;
            try f.group(s, &i, &targets);
            if (targets.items.len == 0) break;
            for (sources.items) |a| for (targets.items) |b| {
                var edge = e;
                edge.from = a;
                edge.to = b;
                try f.edges.append(f.arena, edge);
            };
            sources = targets;
        }
    }

    fn group(f: *FlowParser, s: []const u8, i: *usize, out: *std.ArrayList(usize)) !void {
        while (true) {
            skipSpace(s, i);
            const n = try f.nodeAt(s, i) orelse return;
            try out.append(f.arena, n);
            skipSpace(s, i);
            if (i.* < s.len and s[i.*] == '&') i.* += 1 else return;
        }
    }

    fn nodeAt(f: *FlowParser, s: []const u8, i: *usize) !?usize {
        const start = i.*;
        while (i.* < s.len) : (i.* += 1) {
            const ch = s[i.*];
            if (std.mem.indexOfScalar(u8, " \t[({>&;|", ch) != null) break;
            if ((ch == '-' or ch == '=' or ch == '.' or ch == '~' or ch == '<') and i.* + 1 < s.len and std.mem.indexOfScalar(u8, "-=.~>", s[i.* + 1]) != null) break;
        }
        if (i.* == start) return null;
        const id = s[start..i.*];
        const opens = [_]struct { []const u8, []const u8, Shape }{
            .{ "([", "])", .stadium }, .{ "[[", "]]", .subroutine }, .{ "[(", ")]", .cylinder },
            .{ "((", "))", .circle },  .{ "{{", "}}", .hexagon },    .{ "[/", "/]", .rect },
            .{ "[\\", "\\]", .rect },  .{ "[", "]", .rect },         .{ "(", ")", .round },
            .{ "{", "}", .diamond },   .{ ">", "]", .flag },
        };
        for (opens) |o| if (std.mem.startsWith(u8, s[i.*..], o[0])) {
            const body = i.* + o[0].len;
            const close = closeOf(s, body, o[1]) orelse continue;
            i.* = close + o[1].len;
            if (std.mem.startsWith(u8, s[i.*..], ":::")) while (i.* < s.len and s[i.*] != ' ') : (i.* += 1) {};
            return try f.node(id, try label(f.arena, s[body..close]), o[2]);
        };
        return try f.node(id, null, null);
    }

    fn state(f: *FlowParser, l: []const u8) !void {
        if (std.mem.startsWith(u8, l, "direction ")) {
            f.dir = dirOf(std.mem.trim(u8, l["direction ".len..], " "));
            return;
        }
        if (std.mem.startsWith(u8, l, "state ")) {
            const rest = l["state ".len..];
            if (std.mem.indexOf(u8, rest, " as ")) |as| {
                const id = std.mem.trim(u8, rest[as + 4 ..], " {");
                _ = try f.node(id, try label(f.arena, rest[0..as]), .round);
            }
            return;
        }
        if (std.mem.eql(u8, l, "}") or std.mem.startsWith(u8, l, "note ") or std.mem.startsWith(u8, l, "end note")) return;
        const arrow = std.mem.indexOf(u8, l, "-->") orelse {
            if (std.mem.indexOfScalar(u8, l, ':')) |c| _ = try f.node(std.mem.trim(u8, l[0..c], " "), try label(f.arena, l[c + 1 ..]), .round);
            return;
        };
        var right = l[arrow + 3 ..];
        var text: []const u8 = "";
        if (std.mem.indexOfScalar(u8, right, ':')) |c| {
            text = try label(f.arena, right[c + 1 ..]);
            right = right[0..c];
        }
        const a = try f.stateNode(std.mem.trim(u8, l[0..arrow], " "), true);
        const b = try f.stateNode(std.mem.trim(u8, right, " "), false);
        try f.edges.append(f.arena, .{ .from = a, .to = b, .label = text });
    }

    fn stateNode(f: *FlowParser, id: []const u8, from: bool) !usize {
        if (std.mem.eql(u8, id, "[*]")) return f.node(if (from) "[*]start" else "[*]end", "", if (from) .start else .end);
        return f.node(id, null, .round);
    }

    fn classOrEr(f: *FlowParser, l: []const u8) !void {
        if (std.mem.startsWith(u8, l, "direction ")) {
            f.dir = dirOf(std.mem.trim(u8, l["direction ".len..], " "));
            return;
        }
        if (std.mem.startsWith(u8, l, "class ")) {
            const name = std.mem.trim(u8, l["class ".len..], " {");
            if (name.len > 0) _ = try f.node(name, name, .subroutine);
            return;
        }
        const rels = [_][]const u8{ "<|--", "--|>", "*--", "--*", "o--", "--o", "-->", "<--", "..>", "<..", "||--o{", "}o--||", "||--|{", "||--||", "--" };
        for (rels) |rel| if (std.mem.indexOf(u8, l, rel)) |at| {
            const left = std.mem.trim(u8, l[0..at], " \t");
            var right = std.mem.trim(u8, l[at + rel.len ..], " \t");
            var edge_lbl: []const u8 = "";
            if (std.mem.indexOfScalar(u8, right, ':')) |c| {
                edge_lbl = try label(f.arena, right[c + 1 ..]);
                right = std.mem.trim(u8, right[0..c], " \t");
            }
            if (left.len == 0 or right.len == 0) return;
            const a = try f.node(left, left, .subroutine);
            const b = try f.node(right, right, .subroutine);
            try f.edges.append(f.arena, .{ .from = a, .to = b, .label = edge_lbl });
            return;
        };
    }
};

fn closeOf(s: []const u8, from: usize, close: []const u8) ?usize {
    var i = from;
    while (i < s.len and (s[i] == ' ')) i += 1;
    if (i < s.len and s[i] == '"') if (std.mem.indexOfScalarPos(u8, s, i + 1, '"')) |q| {
        i = q + 1;
    };
    return std.mem.indexOfPos(u8, s, i, close);
}

fn skipSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) i.* += 1;
}

fn edgeAt(arena: std.mem.Allocator, s: []const u8, i: *usize) ?Edge {
    const start = i.*;
    var j = start;
    while (j < s.len and std.mem.indexOfScalar(u8, "<-=.~", s[j]) != null) j += 1;
    if (j < s.len and s[j] == '>') j += 1;
    if (j < s.len and (s[j] == 'x' or s[j] == 'o') and (j + 1 >= s.len or s[j + 1] == ' ' or s[j + 1] == '|')) j += 1;
    var tok = s[start..j];
    if (tok.len < 2) return null;
    var e: Edge = .{ .from = 0, .to = 0 };
    if (std.mem.eql(u8, tok, "--") or std.mem.eql(u8, tok, "==") or std.mem.eql(u8, tok, "-.")) {
        var k = j;
        while (k + 2 < s.len) : (k += 1) {
            if (s[k] == ' ' and std.mem.indexOfScalar(u8, "-=.", s[k + 1]) != null and std.mem.indexOfScalar(u8, "-=.>", s[k + 2]) != null) break;
        } else return null;
        e.label = label(arena, s[j..k]) catch "";
        var m = k + 1;
        while (m < s.len and std.mem.indexOfScalar(u8, "-=.", s[m]) != null) m += 1;
        if (m < s.len and (s[m] == '>' or s[m] == 'x' or s[m] == 'o')) m += 1;
        tok = s[start..m];
        j = m;
    }
    if (std.mem.indexOfScalar(u8, tok, '~') != null) e.line = .invisible else if (std.mem.indexOfScalar(u8, tok, '.') != null) e.line = .dotted else if (std.mem.indexOfScalar(u8, tok, '=') != null) e.line = .thick;
    const last = tok[tok.len - 1];
    e.head = last == '>' or last == 'x' or last == 'o';
    e.tail = tok[0] == '<';
    i.* = j;
    skipSpace(s, i);
    if (i.* < s.len and s[i.*] == '|') if (std.mem.indexOfScalarPos(u8, s, i.* + 1, '|')) |close| {
        e.label = label(arena, s[i.* + 1 .. close]) catch "";
        i.* = close + 1;
    };
    return e;
}

const SeqParser = struct {
    arena: std.mem.Allocator,
    actors: std.ArrayList(Actor) = .empty,
    steps: std.ArrayList(Step) = .empty,

    fn actor(s: *SeqParser, id: []const u8) !usize {
        for (s.actors.items, 0..) |a, i| if (std.mem.eql(u8, a.id, id)) return i;
        try s.actors.append(s.arena, .{ .id = id, .label = id });
        return s.actors.items.len - 1;
    }

    fn line(s: *SeqParser, l: []const u8) !void {
        for ([_][]const u8{ "participant ", "actor " }) |w| if (std.mem.startsWith(u8, l, w)) {
            const rest = std.mem.trim(u8, l[w.len..], " ");
            const as = std.mem.indexOf(u8, rest, " as ");
            const id = if (as) |a| rest[0..a] else rest;
            const i = try s.actor(id);
            if (as) |a| s.actors.items[i].label = try label(s.arena, rest[a + 4 ..]);
            s.actors.items[i].person = w[0] == 'a';
            return;
        };
        if (std.ascii.startsWithIgnoreCase(l, "note ")) return s.note(l["note ".len..]);
        const sections = [_][]const u8{ "loop", "alt", "else", "opt", "par", "and", "critical", "break", "option" };
        for (sections) |w| if (std.mem.startsWith(u8, l, w) and (l.len == w.len or l[w.len] == ' ')) {
            try s.steps.append(s.arena, .{ .section = try label(s.arena, l) });
            return;
        };
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse return;
        const head = l[0..colon];
        const arrows = [_]struct { []const u8, bool, bool }{
            .{ "-->>", true, true }, .{ "->>", false, true }, .{ "--x", true, true }, .{ "-x", false, true },
            .{ "--)", true, true },  .{ "-)", false, true },  .{ "-->", true, false }, .{ "->", false, false },
        };
        for (arrows) |a| if (std.mem.indexOf(u8, head, a[0])) |at| {
            const from = std.mem.trim(u8, head[0..at], " ");
            const to = std.mem.trim(u8, head[at + a[0].len ..], " +-");
            if (from.len == 0 or to.len == 0) return;
            const fi = try s.actor(from);
            const ti = try s.actor(to);
            try s.steps.append(s.arena, .{ .message = .{ .from = fi, .to = ti, .text = try label(s.arena, l[colon + 1 ..]), .dashed = a[1], .head = a[2] } });
            return;
        };
    }

    fn note(s: *SeqParser, rest_in: []const u8) !void {
        const colon = std.mem.indexOfScalar(u8, rest_in, ':') orelse return;
        const where = std.mem.trim(u8, rest_in[0..colon], " ");
        const text = try label(s.arena, rest_in[colon + 1 ..]);
        const Side = @FieldType(@FieldType(Step, "note"), "side");
        var side: Side = .over;
        var who = where;
        for ([_]struct { []const u8, Side }{ .{ "left of ", .left }, .{ "right of ", .right }, .{ "over ", .over } }) |w| if (std.ascii.startsWithIgnoreCase(where, w[0])) {
            side = w[1];
            who = where[w[0].len..];
        };
        var names = std.mem.splitScalar(u8, who, ',');
        const a = try s.actor(std.mem.trim(u8, names.next() orelse return, " "));
        const b = if (names.next()) |n| try s.actor(std.mem.trim(u8, n, " ")) else a;
        try s.steps.append(s.arena, .{ .note = .{ .from = @min(a, b), .to = @max(a, b), .side = side, .text = text } });
    }
};

test "mermaid parser handles graph TD with quoted labels, br tags, and cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\graph TD
        \\  ROOT["harness/ (repo root)"]
        \\  ROOT --> APPS["apps/"]
        \\  APPS --> APPS_H["harness/ — GPUI desktop binary +<br/>`harness headless` engine"]
        \\  APPS_H --> ROOT
    ;
    const d = parse(arena.allocator(), src);
    try std.testing.expect(d.drawable());
    try std.testing.expectEqual(@as(usize, 3), d.flow.nodes.len);
    try std.testing.expectEqual(@as(usize, 3), d.flow.edges.len);
    try std.testing.expectEqual(@as(usize, 1), d.flow.back_count);
}
