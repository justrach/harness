//! New conversations use the same bottom-anchored input as established
//! conversations. Suggestions are separate conversation content, not a
//! heading or cards attached to a floating expanded composer (shell.rs).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const composer = @import("view_composer.zig");
const transcript_view = @import("view_transcript.zig");
const App = @import("app.zig").App;

const Starter = struct {
    icon: icons.Name,
    title: []const u8,
    /// One line on its tile saying what you get.
    blurb: []const u8,
    prompt: []const u8,
    needs_project: bool = false,
    fresh_folder: bool = false,
};

const starters = [_]Starter{
    .{ .icon = .@"magic-stick-3", .fresh_folder = true, .title = "Build something new", .blurb = "Describe an idea. The agent makes a folder, writes the code, and runs it.", .prompt = "Build something new from scratch. Create a new folder for it under ~/Projects, set it up, and get a first working version running. Ask me anything you need to know before you start.\n\nMy idea: " },
    .{ .icon = .magnifer, .title = "Research a topic", .blurb = "Get a sourced write-up on anything, with the key takeaways up front.", .prompt = "Research the topic below and give me a concise, well-sourced write-up: key takeaways first, then the details, with links to your sources.\n\nTopic: " },
    .{ .icon = .global, .title = "Plan a launch", .blurb = "Positioning, a go-to-market plan, and landing page copy for your product.", .prompt = "Help me take my product to market. Ask me about the product, who it's for, and my goals, then draft positioning, a go-to-market plan, and landing page copy.\n\nThe product: " },
    .{ .icon = .@"file-code", .title = "Tour this project", .blurb = "Learn what the code does, how it's organized, and where to start.", .prompt = "Give me a tour of this project: what it does, how it's organized, how to run it, and where I'd start making changes.", .needs_project = true },
};

pub const suggestion_gap: f32 = 14;
pub const chip_h: f32 = 28;
pub const chip_gap: f32 = 6;

/// The greeting over the composer (`starters::greeting`): "Hi Rach. What
/// should Graff do?", by the first name only and never by an email; else
/// just the question.
pub fn greeting(buf: []u8, name: ?[]const u8) []const u8 {
    const question = "What should Graff do?";
    const n = std.mem.trim(u8, name orelse return question, " \t\n");
    var words = std.mem.tokenizeAny(u8, n, " \t\n");
    const first = words.next() orelse return question;
    if (std.mem.indexOfScalar(u8, first, '@') != null) return question;
    return std.fmt.bufPrint(buf, "Hi {s}. {s}", .{ first, question }) catch question;
}

test "the greeting uses the first name only (greeting_uses_the_first_name_only)" {
    var b: [96]u8 = undefined;
    try std.testing.expectEqualStrings("Hi Rach. What should Graff do?", greeting(&b, "Rach Pradhan"));
    try std.testing.expectEqualStrings("What should Graff do?", greeting(&b, "  "));
    try std.testing.expectEqualStrings("What should Graff do?", greeting(&b, "rach@example.com"));
    try std.testing.expectEqualStrings("What should Graff do?", greeting(&b, null));
}

pub fn canvas(c: *ui.Context, a: *App, k: theme.Colors) void {
    const pane_w = transcript_view.paneWidth(c, a);
    const pane_h = transcript_view.paneHeight(c, a) orelse c.size.h;
    const w = composer.dockedWidth(pane_w, transcript_view.column_w);
    const area = ui.div(c).column().wFull().grow().h(0).itemsCenter();
    defer area.end();
    // Center the hero and starter chips optically in spacious canvases while
    // keeping bottom-aligned flow in short or expanded panes so chips never
    // overlap the composer dock.
    const center_hero = pane_h >= 520 and !a.view.composer_expanded and a.composer.text().len == 0;
    {
        ui.scroll(c, .{
            .width = .fill,
            .height = .{ .px = 0 },
            .grow = 1,
            .align_items = .center,
            .justify = if (center_hero) .center else .end,
            .follow_end = !center_hero,
        });
        defer ui.end(c);
        if (center_hero) _ = c.leaf(.{ .height = .{ .px = @min(72, (pane_h - 460) * 0.28) } }, .none, null);
        suggestions(c, a, k, w);
    }
    _ = c.leaf(.{ .height = .{ .px = 24 } }, .none, null);
    composer.docked(c, a, k);
    const agent_updates = @import("agent_updates.zig");
    if (agent_updates.hasVisible(a)) {
        _ = c.leaf(.{ .height = .{ .px = 46 } }, .none, null);
        const host = ui.div(c).row().wFull().h(0);
        defer host.end();
        @import("view_agent_updates.zig").island(c, a, k, pane_w, pane_h);
    }
}

const phi: f32 = 1.618;

pub fn suggestions(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    ui.key(c, "new-conversation-suggestions");
    const enter = ui.motion.frame(c, .{
        .initial = .{ .opacity = 0 },
        .target = .{ .opacity = 1 },
        .transition = .{ .tween = .{ .duration = 0.16, .ease = .linear } },
    });
    const box = ui.div(c).column().w(w).itemsCenter().gap(suggestion_gap).motion(enter);
    defer box.end();
    // Centered agent emblem tile above the greeting for visual balance.
    {
        const mark = icons.harnessMark(a.new_harness);
        const badge = ui.div(c).row().size(40, 40).center().rounded(12).bg(k.ink(if (k.dark) 0.06 else 0.035)).border(k.border).borderW(1);
        defer badge.end();
        icons.icon(c, mark.name, 20, mark.brand orelse k.text, 0);
    }
    const buf = c.alloc().alloc(u8, 128) catch return;
    const name = if (a.account.user) |u| u.name else null;
    kit.ellipsisText(c, if (a.new_chat_mode) chat_mode.heading_title else greeting(buf, name), .{ .size = 24, .line_height = 24 * phi, .weight = .semibold, .color = k.text }, w);
    starterChips(c, a, k, w);
}

const chat_mode = @import("chat_mode.zig");
const agent = @import("app_agent.zig");
const rules = @import("motion_rules.zig");
const tip = @import("view_tooltip.zig");

/// The footer's controls after the model chip, in the order drawn.
const Control = enum { mode, follow, computer, project, checkout, branch };
const control_count = std.enums.values(Control).len;

fn ix(x: Control) usize {
    return @backingInt(x);
}

/// How soon each gives up its words, then its place, where the footer is
/// narrow (`Nano.FooterChips`): first the computer and the project, which
/// the tab strip names too, and the follow-up switch, whose glyph says
/// which it is; the ref last.
const control_rank = [control_count]usize{ 4, 1, 0, 2, 3, 5 };
/// A picker chip but for its words: two 8-point insets, a 12-point glyph,
/// a 12-point chevron and the two 6-point gaps.
const chip_chrome: f32 = 52;
const chip_max_w: f32 = 280;
/// The same for Chat | Code (no chevron) and for the follow-up switch
/// (a 5-point gap).
const control_chrome = [control_count]f32{ 34, 33, chip_chrome, chip_chrome, chip_chrome, chip_chrome };
const chip_st: ui.TextStyle = .{ .size = 12, .line_height = 12 * phi, .weight = theme.ui_medium_weight };

/// Chat | Code (`render_chat_mode_switch`): which the new session is; a
/// click switches. Dimmed while no Auto tier is on offer, saying why.
fn modeSwitch(c: *ui.Context, a: *App, k: theme.Colors, slot: rules.FooterSlot) void {
    if (slot.w == 0) return;
    const plain = a.new_chat_mode;
    const unavailable = !plain and agent.chatAvailability(a) == .unavailable;
    const hint = if (plain) "Plain chat. Click for a coding session" else if (unavailable) chat_mode.unavailable_note else "Coding session. Click for a plain chat";
    ui.key(c, "picker-chat-mode");
    var b = ui.div(c).row().h(20).px(8).gap(6).itemsCenter().rounded(6).hover(k.hover);
    if (unavailable) b = b.opacity(0.5);
    b = tip.on(b, k, .{ .text = hint });
    defer b.end();
    const hot = b.hovered();
    icons.icon(c, if (plain) .@"chat-round-line" else .@"file-code", 12, k.muted.alpha(0.7), 0);
    if (slot.label > 0) ui.text(c, modeLabel(plain), .{ .size = 12, .line_height = 12 * phi, .weight = theme.ui_medium_weight, .color = if (hot) k.text.alpha(0.8) else k.muted.alpha(0.7) });
    if (b.clicked()) agent.setChatMode(a, !plain);
}

fn modeLabel(plain: bool) []const u8 {
    return if (plain) "Chat" else "Code";
}

/// Same footer and model anchor as an established conversation. A draft
/// adds mode, an explicit execution computer, and its project/checkout,
/// centered cleanly under the composer pill. Where the composer is too
/// narrow for them all (a split pane), `footerChipWidths` shortens long
/// labels, then leaves controls their glyph alone, so none is cut at the
/// composer's edge or pushed out of reach.
pub fn footer(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const wide = w >= rules.footer_wide_w;
    var r = ui.div(c).row().w(w).h(24).px(10).gap(rules.footerRowGap(w)).itemsCenter().clip();
    if (wide) r = r.justifyCenter();
    defer r.end();
    const model_w = composer.chip(c, a, k);
    if (wide) ui.div(c).size(3, 3).rounded(1.5).bg(k.muted.alpha(0.35)).end();
    const note = agent.chatNote(a);
    const note_st: ui.TextStyle = .{ .size = 11.5, .line_height = 11.5 * phi, .color = k.muted };
    const note_max = @max(0, w - 200);
    const note_w = if (note) |text| @min(@ceil(c.text.width(text, note_st)), note_max) else 0;

    const strip = @import("view_tab_strip.zig");
    const space = a.newChatSpace();
    const git_chrome = a.settings.hierarchyProfile().shows_git_checkout_chrome;
    var labels: [control_count]?[]const u8 = @splat(null);
    labels[ix(.mode)] = modeLabel(a.new_chat_mode);
    if (composer.followUpShown(a)) labels[ix(.follow)] = composer.followUpLabel(a);
    if (git_chrome) labels[ix(.computer)] = c.print("Run on: {s}", .{strip.deviceLabel(a, strip.device(a, strip.active(a)))});
    // Desktop exposes project choice only before sending a coding session.
    if (!a.new_chat_mode) labels[ix(.project)] = if (space) |s| s.name else "No project";
    if (git_chrome) if (space) |s| if (s.git) {
        labels[ix(.checkout)] = checkoutLabel(a.new_checkout_local);
        labels[ix(.branch)] = if (a.new_ref) |ref| (if (a.new_checkout_local) ref else c.print("From {s}", .{ref})) else "Select ref";
    };

    var chips: [control_count]rules.FooterChip = undefined;
    var fitted: [control_count]rules.FooterSlot = undefined;
    var n: usize = 0;
    for (labels, control_chrome, control_rank) |label, chrome, rank| if (label) |text| {
        const limit: f32 = if (chrome == chip_chrome) chip_max_w - chip_chrome else std.math.floatMax(f32);
        chips[n] = .{ .chrome = chrome, .text = @min(@ceil(c.text.width(text, chip_st)), limit), .rank = rank };
        n += 1;
    };
    rules.footerChipWidths(rules.footerRoom(w, model_w, note_w), chips[0..n], fitted[0..n]);
    var slots: [control_count]rules.FooterSlot = @splat(.{});
    n = 0;
    for (labels, &slots) |label, *slot| if (label != null) {
        slot.* = fitted[n];
        n += 1;
    };
    {
        const slot = if (wide)
            ui.div(c).row().hFull().gap(rules.footer_chip_gap).itemsCenter().clip()
        else
            ui.div(c).row().grow().w(0).hFull().gap(rules.footer_chip_gap).itemsCenter().clip();
        defer slot.end();
        modeSwitch(c, a, k, slots[ix(.mode)]);
        if (slots[ix(.follow)].w > 0) composer.followUpChip(c, a, k, slots[ix(.follow)].label == 0);
        // Keep the execution target beside the draft, not only in the
        // titlebar. Picking another host clears an incompatible project.
        var computer: ?ui.Rect = null;
        if (labels[ix(.computer)]) |label| {
            if (footerChipAt(c, k, "picker-computer", .monitor, label, slots[ix(.computer)], &computer))
                strip.open(a, .device, strip.active(a), computer);
        }
        if (labels[ix(.project)]) |label| projectChip(c, a, k, label, slots[ix(.project)]);
        if (git_chrome) if (space) |s| if (s.git) {
            if (labels[ix(.checkout)]) |label| if (footerChipAt(c, k, "picker-checkout", if (a.new_checkout_local) .folder else .@"folder-with-files", label, slots[ix(.checkout)], &a.view.checkout_anchor)) {
                a.view.checkout_menu = !a.view.checkout_menu;
                a.view.ref_menu = false;
            };
            if (labels[ix(.branch)]) |label| if (footerChipAt(c, k, "picker-branch", .@"git-branch", label, slots[ix(.branch)], &a.view.ref_anchor)) {
                a.view.ref_menu = !a.view.ref_menu;
                a.view.checkout_menu = false;
                if (a.view.ref_menu) @import("view_menus.zig").ensureRefs(a, s);
            };
        };
    }
    if (note) |text| kit.ellipsisText(c, text, note_st, note_max);
}

/// The shared strip owns the project's searchable menu and panel-local
/// mutation.
fn projectChip(c: *ui.Context, a: *App, k: theme.Colors, label: []const u8, slot: rules.FooterSlot) void {
    if (footerChipAt(c, k, "picker-project", .folder, label, slot, &a.view.space_anchor)) {
        if (a.view.strip.menu == .folder and a.view.strip.footer_folder) {
            a.view.strip.menu = null;
            a.view.space_menu = false;
        } else {
            a.view.space_menu = true;
        }
        a.redraw();
    }
}

pub fn checkoutLabel(local: bool) []const u8 {
    return if (local) "Current checkout" else "New worktree";
}

/// A quiet chip: an icon, its words and a chevron (`footer_chip`), keeping
/// where it was laid out for a menu to hang from. `slot` is the room it
/// was given: its words ellipsized to `slot.label`, its glyph alone at 0
/// (the words then in its tooltip), nothing at all at `slot.w` 0.
fn footerChipAt(c: *ui.Context, k: theme.Colors, key: []const u8, icon: icons.Name, label: []const u8, slot: rules.FooterSlot, anchor: ?*?ui.Rect) bool {
    if (slot.w == 0) return false;
    const glyph_only = slot.label == 0;
    ui.key(c, key);
    var b = ui.div(c).row().h(20).maxW(chip_max_w).px(8).gap(6).itemsCenter().rounded(6).hover(k.hover);
    if (glyph_only or c.text.width(label, chip_st) > slot.label) b = tip.on(b, k, .{ .text = label });
    defer b.end();
    if (anchor) |p| if (c.rects.get(c.node(b.index).id)) |r| {
        p.* = r;
    };
    const hot = b.hovered();
    icons.icon(c, icon, 12, k.muted.alpha(0.7), 0);
    if (glyph_only) return b.clicked();
    var st = chip_st;
    st.color = if (hot) k.text.alpha(0.8) else k.muted.alpha(0.7);
    kit.ellipsisText(c, label, st, slot.label);
    icons.icon(c, .@"alt-arrow-down", 12, k.muted.alpha(0.5), 0);
    return b.clicked();
}

/// The same 28px outlined chips as starters::chip, flex-wrapped with
/// measured titles. A narrow panel never gets two clipped fixed cards.
fn starterChips(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    var shown: [starters.len]Starter = undefined;
    var widths: [starters.len]f32 = undefined;
    var n: usize = 0;
    for (starters) |s| {
        if (s.needs_project and a.newChatSpace() == null) continue;
        shown[n] = s;
        // GPUI's text element rounds its intrinsic width up to a point.
        widths[n] = @min(w, @ceil(c.text.width(s.title, .{ .size = 12 })) + 20 + 2 + 13 + 6);
        n += 1;
    }
    const box = ui.div(c).column().w(w).gap(chip_gap).itemsCenter();
    defer box.end();
    var start: usize = 0;
    while (start < n) {
        const end = chipRowEnd(widths[0..n], start, w);
        const row = ui.div(c).row().gap(chip_gap).itemsCenter();
        defer row.end();
        for (shown[start..end], widths[start..end], 0..) |s, cw, chip_ix| {
            ui.key(c, s.title);
            const chip_enter = ui.motion.frame(c, .{
                .initial = .{ .opacity = 0 },
                .target = .{ .opacity = 1 },
                .transition = .{ .tween = .{ .duration = 0.14, .ease = .linear } },
                .delay = ui.motion.stagger(start + chip_ix, 0.025),
            });
            const b = ui.div(c).row().h(chip_h).w(cw).px(11).gap(6).itemsCenter().rounded(14).bg(k.ink(if (k.dark) 0.04 else 0.022)).border(k.border).borderW(1).hover(k.hover).motion(chip_enter);
            defer b.end();
            const ink = if (b.hovered()) k.text else k.muted;
            icons.icon(c, s.icon, 13, ink, 0);
            kit.ellipsisText(c, s.title, .{ .size = 12, .line_height = 12 * phi, .color = ink }, @max(0, cw - 22 - 13 - 6));
            if (b.clicked()) {
                if (s.fresh_folder) a.new_no_project = true;
                a.composer.set(s.prompt);
                a.view.focus_composer = true;
                a.redraw();
            }
        }
        start = end;
    }
}

/// End-exclusive wrapped row; even a too-wide chip must make progress.
pub fn chipRowEnd(widths: []const f32, start: usize, available: f32) usize {
    var end = start;
    var used: f32 = 0;
    while (end < widths.len) : (end += 1) {
        const next = used + (if (end > start) chip_gap else @as(f32, 0)) + widths[end];
        if (end > start and next > available) break;
        used = next;
    }
    return end;
}
