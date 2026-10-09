//! Settings search: the filter at the top of the Settings sidebar.
//!
//! A hand-kept index of the rows each page shows, with the words people tend
//! to type for them ("dark mode", "keybindings", "credits"), plus every
//! customizable shortcut by name. Picking a result opens its section.

use crate::settings::ShortcutId;
use crate::shell::SettingsSection;

/// One searchable setting.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsEntry {
    pub section: SettingsSection,
    pub title: &'static str,
    /// Space-separated synonyms; matched by word prefix, never shown.
    pub keywords: &'static str,
}

const fn entry(
    section: SettingsSection,
    title: &'static str,
    keywords: &'static str,
) -> SettingsEntry {
    SettingsEntry {
        section,
        title,
        keywords,
    }
}

use SettingsSection as S;

/// The rows of every page, in page order. Section names match on their own,
/// so only rows inside a page need listing here.
const ENTRIES: &[SettingsEntry] = &[
    entry(
        S::Devices,
        "Connected devices",
        "pair phone iphone android ipad remote rename computer",
    ),
    entry(
        S::Devices,
        "Updates",
        "version update upgrade release check install restart",
    ),
    entry(
        S::Harnesses,
        "Enable or install agents",
        "harness cli install update beta toggle claude codex cursor gemini opencode graff devin",
    ),
    entry(
        S::Harnesses,
        "Session titles",
        "title model harness automatic rename naming",
    ),
    entry(
        S::Harnesses,
        "Graff compaction point",
        "context compact compaction tokens window limit",
    ),
    entry(
        S::Harnesses,
        "Experimental Graff ACP child agents",
        "subagents delegate delegation acp children",
    ),
    entry(
        S::Harnesses,
        "Screen Recording",
        "permission capture privacy screen",
    ),
    entry(
        S::Agents,
        "Sign in to agent accounts",
        "login logout signin signout account credentials api key",
    ),
    entry(
        S::Agents,
        "Usage and limits",
        "usage quota plan limit credits balance billing top up rate",
    ),
    entry(
        S::Agents,
        "Harness cloud",
        "cloud sandbox sandboxes pr agent jobs remote",
    ),
    entry(S::Agents, "ChatGPT sign-in", "chatgpt openai codex login"),
    entry(
        S::Appearance,
        "Appearance mode",
        "light dark system mode color scheme",
    ),
    entry(S::Appearance, "Light theme", "theme palette colors"),
    entry(S::Appearance, "Dark theme", "theme palette colors"),
    entry(
        S::Appearance,
        "Accent color",
        "accent highlight tint colour",
    ),
    entry(
        S::Appearance,
        "Theme library",
        "import install vscode theme extension package",
    ),
    entry(
        S::Appearance,
        "Frosted glass",
        "blur translucent transparency vibrancy glass opaque solid",
    ),
    entry(
        S::Appearance,
        "New thread composer background",
        "wallpaper image picture background",
    ),
    entry(
        S::Appearance,
        "Background effect",
        "dither ascii halftone scanlines wallpaper effect",
    ),
    entry(
        S::Appearance,
        "Compact mode",
        "collapse fold thinking tool calls narration dense",
    ),
    entry(
        S::Appearance,
        "Reduce motion",
        "animation animations accessibility motion",
    ),
    entry(
        S::Appearance,
        "Pause animations in background",
        "animation cpu battery focus unfocused spinner",
    ),
    entry(
        S::Appearance,
        "Interface font",
        "font typeface family size text ui",
    ),
    entry(
        S::Appearance,
        "Terminal font",
        "font typeface family size monospace",
    ),
    entry(
        S::Appearance,
        "Code & diff font",
        "font typeface family size monospace code diff",
    ),
    entry(
        S::Appearance,
        "Conversation width",
        "transcript column width wide narrow",
    ),
    entry(S::Files, "Autosave", "save automatically editor"),
    entry(S::Files, "Autosave delay", "save delay debounce"),
    entry(S::Files, "Word wrap", "wrap lines editor soft"),
    entry(
        S::Files,
        "Show all files",
        "hidden ignored dotfiles gitignore tree",
    ),
    entry(
        S::Notifications,
        "Session sounds",
        "sound audio chime volume mute",
    ),
    entry(
        S::Notifications,
        "Task completed sound",
        "sound done finished",
    ),
    entry(
        S::Notifications,
        "Input required sound",
        "sound question permission waiting",
    ),
    entry(
        S::Notifications,
        "Errors and disconnections sound",
        "sound error disconnect failure",
    ),
    entry(
        S::Notifications,
        "Desktop notifications",
        "notify alert banner system",
    ),
    entry(
        S::Notifications,
        "Only when in the background",
        "notify focus unfocused background",
    ),
    entry(
        S::Notifications,
        "Share anonymous performance stats",
        "telemetry privacy analytics stats",
    ),
    entry(
        S::Shortcuts,
        "Keyboard shortcuts",
        "keybindings hotkeys keymap keys bindings",
    ),
    entry(
        S::Shortcuts,
        "Stop active agent with Escape",
        "esc escape interrupt stop cancel",
    ),
    entry(
        S::Shortcuts,
        "Send messages with",
        "enter return cmd ctrl newline submit send",
    ),
    entry(
        S::Shortcuts,
        "Composer completion",
        "autocomplete slash commands skills mentions completion",
    ),
    entry(S::Appshots, "Appshots", "screenshot capture window share"),
    entry(
        S::Archived,
        "Archive sessions when closing tabs or panes",
        "close tab pane archive automatically",
    ),
    entry(
        S::Archived,
        "Restore archived sessions",
        "unarchive restore history old deleted",
    ),
];

/// How well an entry matched; lower sorts first.
fn rank(entry_title: &str, keywords: &str, section_label: &str, query: &str) -> Option<u8> {
    let title = entry_title.to_lowercase();
    let words: Vec<&str> = query.split_whitespace().collect();
    if words.is_empty() {
        return None;
    }
    if title.starts_with(query) {
        return Some(0);
    }
    let title_words = || title.split(|c: char| !c.is_alphanumeric());
    if words
        .iter()
        .all(|word| title_words().any(|title_word| title_word.starts_with(word)))
    {
        return Some(1);
    }
    if title.contains(query) {
        return Some(2);
    }
    let haystack = format!("{title} {keywords} {}", section_label.to_lowercase());
    words
        .iter()
        .all(|word| {
            haystack
                .split(|c: char| !c.is_alphanumeric())
                .any(|candidate| candidate.starts_with(word))
        })
        .then_some(3)
}

/// Settings matching `query`, best first; empty for a blank query. Sections
/// this platform hides never appear.
pub fn search(query: &str, shown: impl Fn(SettingsSection) -> bool) -> Vec<SettingsEntry> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Vec::new();
    }
    let sections = SettingsSection::ALL
        .into_iter()
        .map(|section| entry(section, section.label(), ""));
    let shortcuts = ShortcutId::ALL
        .into_iter()
        .filter(|id| !matches!(id, ShortcutId::JumpSession(_)))
        .map(|id| entry(S::Shortcuts, id.label(), "shortcut keybinding hotkey"));
    let mut hits: Vec<(u8, usize, SettingsEntry)> = sections
        .chain(ENTRIES.iter().cloned())
        .chain(shortcuts)
        .filter(|candidate| shown(candidate.section))
        .enumerate()
        .filter_map(|(order, candidate)| {
            rank(
                candidate.title,
                candidate.keywords,
                candidate.section.label(),
                &query,
            )
            .map(|score| (score, order, candidate))
        })
        .collect();
    hits.sort_by_key(|(score, order, _)| (*score, *order));
    hits.into_iter()
        .map(|(_, _, candidate)| candidate)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn titles(query: &str) -> Vec<&'static str> {
        search(query, |_| true)
            .into_iter()
            .map(|entry| entry.title)
            .collect()
    }

    #[test]
    fn blank_queries_show_nothing() {
        assert!(titles("").is_empty());
        assert!(titles("   ").is_empty());
    }

    #[test]
    fn titles_outrank_synonyms_and_sections_lead_their_rows() {
        let hits = titles("appear");
        assert_eq!(hits[0], "Appearance");
        assert_eq!(hits[1], "Appearance mode");
        // "motion" is in both the title and the keywords of Reduce motion.
        assert_eq!(titles("motion")[0], "Reduce motion");
    }

    #[test]
    fn synonyms_find_rows_whose_titles_do_not_say_them() {
        assert_eq!(titles("dark mode")[0], "Appearance mode");
        assert!(titles("keybindings").contains(&"Keyboard shortcuts"));
        assert!(titles("credits").contains(&"Usage and limits"));
        assert!(titles("animations").contains(&"Pause animations in background"));
        let search = search("blur", |_| true);
        assert_eq!(search[0].section, SettingsSection::Appearance);
    }

    #[test]
    fn every_word_must_match_and_case_does_not_matter() {
        assert_eq!(titles("TERMINAL font")[0], "Terminal font");
        assert!(titles("terminal zzz").is_empty());
    }

    #[test]
    fn shortcuts_are_searchable_by_action() {
        let hits = search("split terminal", |_| true);
        assert!(
            hits.iter().any(|hit| hit.title == "Split terminal right"
                && hit.section == SettingsSection::Shortcuts)
        );
    }

    #[test]
    fn hidden_sections_never_appear() {
        assert!(titles("appshots").contains(&"Appshots"));
        let hits = search("appshots", |section| section != SettingsSection::Appshots);
        assert!(
            hits.iter()
                .all(|hit| hit.section != SettingsSection::Appshots)
        );
    }
}
