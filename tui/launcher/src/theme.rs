//! Codegraff colors for the terminal UI.
//!
//! Codex's TUI leaves its named colors (red, green, cyan, …) and the screen
//! background to the terminal. So this sets the terminal's own palette from
//! Harness's Codegraff theme (`crates/theme/src/builtins.rs`: `terminal_background`,
//! `ansi`, `accent`) with the OSC color sequences, and puts it back on exit.
//! It also installs a matching syntax/accent `.tmTheme`, which is how Codex
//! takes custom colors for code, diffs and the accent.
//!
//! `HARNESS_TUI_THEME=dark|light` picks the variant (default dark);
//! `HARNESS_TUI_THEME=terminal` leaves the terminal's colors alone.

use std::io::IsTerminal;
use std::io::Write;
use std::path::Path;

use toml_edit::DocumentMut;

struct Palette {
    /// `.tmTheme` file stem and the value of `tui.theme`.
    name: &'static str,
    background: &'static str,
    text: &'static str,
    accent: &'static str,
    success: &'static str,
    danger: &'static str,
    ansi: [&'static str; 16],
    comment: &'static str,
    keyword: &'static str,
    string: &'static str,
    number: &'static str,
    type_name: &'static str,
    function: &'static str,
    punctuation: &'static str,
    tag: &'static str,
    invalid: &'static str,
}

const DARK: Palette = Palette {
    name: "codegraff",
    background: "#16140f",
    text: "#edeae2",
    accent: "#e8a33d",
    success: "#7fa86b",
    danger: "#d2674f",
    ansi: [
        "#16140f", "#d2674f", "#7fa86b", "#d9a441", "#8a9bb0", "#bd80e4", "#7fa86b", "#edeae2",
        "#5c564b", "#d2674f", "#7fa86b", "#e8a33d", "#8a9bb0", "#bd80e4", "#9a9384", "#faf8f3",
    ],
    comment: "#5c564b",
    keyword: "#e8a33d",
    string: "#7fa86b",
    number: "#d9a441",
    type_name: "#edeae2",
    function: "#e8a33d",
    punctuation: "#9a9384",
    tag: "#d2674f",
    invalid: "#d2674f",
};

const LIGHT: Palette = Palette {
    name: "codegraff-light",
    background: "#faf8f3",
    text: "#1a1813",
    accent: "#c77d20",
    success: "#5c7e47",
    danger: "#b14228",
    ansi: [
        "#1a1813", "#b14228", "#5c7e47", "#9a6e1b", "#3b6fb0", "#7a4ea3", "#2f8f9d", "#6b6557",
        "#a8a090", "#b14228", "#5c7e47", "#c77d20", "#3b6fb0", "#7a4ea3", "#2f8f9d", "#1a1813",
    ],
    comment: "#a8a090",
    keyword: "#c77d20",
    string: "#5c7e47",
    number: "#9a6e1b",
    type_name: "#1a1813",
    function: "#c77d20",
    punctuation: "#6b6557",
    tag: "#b14228",
    invalid: "#b14228",
};

/// Puts the terminal palette back when dropped (or on `restore`).
pub struct ThemeGuard {
    restore: Option<&'static str>,
}

impl ThemeGuard {
    pub fn restore(&mut self) {
        if let Some(sequence) = self.restore.take() {
            let mut out = std::io::stdout();
            let _ = out.write_all(sequence.as_bytes());
            let _ = out.flush();
        }
    }
}

impl Drop for ThemeGuard {
    fn drop(&mut self) {
        self.restore();
    }
}

/// Apply the Codegraff palette. Returns a guard that restores the terminal's
/// colors, or `None` when theming is off or stdout is not a terminal.
pub fn apply(codex_home: Option<&Path>) -> Option<ThemeGuard> {
    let palette = match std::env::var("HARNESS_TUI_THEME").as_deref() {
        Ok("terminal") => return None,
        Ok("light") => &LIGHT,
        _ => &DARK,
    };
    if let Some(home) = codex_home {
        // Best effort: without the theme file Codex still runs, just uncolored by us.
        if let Err(err) = install_syntax_theme(home, palette) {
            eprintln!("harness-tui: could not install the Codegraff syntax theme: {err}");
        }
    }
    if !std::io::stdout().is_terminal() {
        return None;
    }
    let mut sequence = String::from("\x1b]4");
    for (index, color) in palette.ansi.iter().enumerate() {
        sequence.push_str(&format!(";{index};{color}"));
    }
    // Palette, default foreground, default background, cursor.
    sequence.push_str(&format!(
        "\x07\x1b]10;{}\x07\x1b]11;{}\x07\x1b]12;{}\x07",
        palette.text, palette.background, palette.accent
    ));
    let mut out = std::io::stdout();
    let _ = out.write_all(sequence.as_bytes());
    let _ = out.flush();
    // Reset palette (104), foreground (110), background (111), cursor (112).
    Some(ThemeGuard {
        restore: Some("\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07"),
    })
}

fn install_syntax_theme(home: &Path, palette: &Palette) -> std::io::Result<()> {
    let themes = home.join("themes");
    std::fs::create_dir_all(&themes)?;
    let file = themes.join(format!("{}.tmTheme", palette.name));
    let xml = tm_theme(palette);
    if std::fs::read_to_string(&file).ok().as_deref() != Some(xml.as_str()) {
        std::fs::write(&file, xml)?;
    }

    // Select it once; after that a theme picked with /theme stays picked.
    let config = home.join("config.toml");
    let text = std::fs::read_to_string(&config).unwrap_or_default();
    let mut doc: DocumentMut = text
        .parse()
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, format!("{}: {err}", config.display())))?;
    let tui = doc
        .entry("tui")
        .or_insert_with(|| toml_edit::Item::Table(toml_edit::Table::new()))
        .as_table_mut()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidData, "`tui` in config.toml is not a table"))?;
    if !tui.contains_key("theme") {
        tui.insert("theme", toml_edit::value(palette.name));
        std::fs::write(&config, doc.to_string())?;
    }
    Ok(())
}

fn hex(color: &str) -> (u8, u8, u8) {
    let value = u32::from_str_radix(color.trim_start_matches('#'), 16).unwrap_or(0);
    ((value >> 16) as u8, (value >> 8) as u8, value as u8)
}

/// `amount` of `color` over `background`, as a hex string.
fn tint(color: &str, background: &str, amount: f32) -> String {
    let (c, b) = (hex(color), hex(background));
    let mix = |c: u8, b: u8| (f32::from(c) * amount + f32::from(b) * (1.0 - amount)).round() as u8;
    format!("#{:02x}{:02x}{:02x}", mix(c.0, b.0), mix(c.1, b.1), mix(c.2, b.2))
}

fn tm_theme(p: &Palette) -> String {
    let rule = |scope: &str, foreground: &str| {
        format!(
            "    <dict><key>scope</key><string>{scope}</string>\n      <key>settings</key><dict><key>foreground</key><string>{foreground}</string></dict></dict>\n"
        )
    };
    let diff = |scope: &str, foreground: &str, fill: &str| {
        format!(
            "    <dict><key>scope</key><string>{scope}</string>\n      <key>settings</key><dict><key>foreground</key><string>{foreground}</string><key>background</key><string>{fill}</string></dict></dict>\n"
        )
    };
    let mut xml = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n",
    );
    xml.push_str(&format!("  <key>name</key><string>{}</string>\n  <key>settings</key>\n  <array>\n", p.name));
    xml.push_str(&format!(
        "    <dict><key>settings</key><dict><key>foreground</key><string>{}</string></dict></dict>\n",
        p.text
    ));
    xml.push_str(&rule("codex.accent", p.accent));
    xml.push_str(&rule("comment, punctuation.definition.comment", p.comment));
    xml.push_str(&rule("string, punctuation.definition.string", p.string));
    xml.push_str(&rule("keyword, storage, markup.heading, keyword.operator", p.keyword));
    xml.push_str(&rule("support.type, support.class, support.variable, entity.name.type", p.type_name));
    xml.push_str(&rule("constant, constant.numeric", p.number));
    xml.push_str(&rule("entity.name.function, support.function", p.function));
    xml.push_str(&rule("punctuation", p.punctuation));
    xml.push_str(&rule("entity.name.tag, markup.deleted.tag", p.tag));
    xml.push_str(&rule("invalid", p.invalid));
    xml.push_str(&diff("markup.inserted", p.success, &tint(p.success, p.background, 0.22)));
    xml.push_str(&diff("markup.deleted", p.danger, &tint(p.danger, p.background, 0.22)));
    xml.push_str("  </array>\n</dict>\n</plist>\n");
    xml
}
