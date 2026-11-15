//! Shared native activation: a single interaction handles pointer, keyboard and
//! assistive presses. A focus ring is decoration, never a second interaction.
const ui = @import("nanoui").ui;
const theme = @import("theme.zig");

pub fn activate(c: *ui.Context, d: ui.Div, k: theme.Colors, label: []const u8, enabled: bool, selected: bool) bool {
    return activateIndex(c, d.index, k, label, enabled, selected);
}

pub fn activateIndex(c: *ui.Context, index: u32, k: theme.Colors, label: []const u8, enabled: bool, selected: bool) bool {
    c.addA11y(index, .button, label, "", selected, enabled);
    if (!enabled) return false;
    const interaction = c.interact(index, .{ .focusable = true });
    if (interaction.focused and c.keyboard_modality) {
        c.node(index).style.border = k.accent;
        c.node(index).style.border_width = 1;
    }
    if (interaction.clicked) c.changed = true;
    return interaction.clicked;
}

pub fn indicate(c: *ui.Context, d: ui.Div, k: theme.Colors, focused: bool) void {
    if (focused and c.keyboard_modality) _ = d.border(k.accent).borderW(1);
}
