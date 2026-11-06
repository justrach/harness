//! Searchable desktop session icon choices. Emoji metadata is bundled open data;
//! selecting or searching never requires a network request.
use super::session_icon::{SessionIcon, emoji_key};
use super::session_sidebar::SESSION_ICONS;
use serde::Deserialize;
use std::sync::LazyLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum IconPickerTab {
    Emoji,
    Icons,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct IconChoice {
    pub key: String,
    pub label: String,
    pub icon: SessionIcon,
    pub category: Option<String>,
}

#[derive(Deserialize)]
struct EmojiEntry {
    emoji: String,
    label: String,
    category: String,
    search: String,
}

static EMOJI: LazyLock<Vec<EmojiEntry>> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../../assets/session-emoji/catalog.json"))
        .expect("bundled session emoji metadata must be valid")
});

pub(super) fn emoji_categories() -> &'static [(&'static str, &'static str)] {
    &[
        ("smileys_emotion", "Smileys & emotion"),
        ("people_body", "People & body"),
        ("animals_nature", "Animals & nature"),
        ("food_drink", "Food & drink"),
        ("travel_places", "Travel & places"),
        ("activities", "Activities"),
        ("objects", "Objects"),
        ("symbols", "Symbols"),
        ("flags", "Flags"),
    ]
}

fn search_terms(query: &str) -> Vec<String> {
    query
        .trim_matches(|ch: char| ch.is_whitespace() || ch == ':')
        .replace(['_', '-'], " ")
        .to_lowercase()
        .split_whitespace()
        .map(str::to_owned)
        .collect()
}

pub(super) fn choices(tab: IconPickerTab, query: &str) -> Vec<IconChoice> {
    let query = query.trim();
    let terms = search_terms(query);
    match tab {
        IconPickerTab::Icons => SESSION_ICONS
            .iter()
            .filter(|(key, label, _)| {
                let haystack = format!("{key} {label}").to_lowercase();
                terms.iter().all(|term| haystack.contains(term))
            })
            .map(|(key, label, glyph)| IconChoice {
                key: (*key).to_owned(),
                label: (*label).to_owned(),
                icon: SessionIcon::Svg(glyph),
                category: None,
            })
            .collect(),
        IconPickerTab::Emoji => {
            // A native palette or clipboard can supply emoji newer than our
            // metadata. Offer the full pasted grapheme without requiring a
            // catalogue match, but never turn an ASCII search letter into an icon.
            let direct_key = (!query.is_ascii()).then(|| emoji_key(query)).flatten();
            let mut results = Vec::new();
            if let Some(key) = &direct_key {
                let label = EMOJI
                    .iter()
                    .find(|entry| entry.emoji == query)
                    .map(|entry| entry.label.clone())
                    .unwrap_or_else(|| format!("Use {query}"));
                results.push(IconChoice {
                    key: key.clone(),
                    label,
                    icon: SessionIcon::Emoji(query.to_owned()),
                    category: EMOJI
                        .iter()
                        .find(|entry| entry.emoji == query)
                        .map(|entry| entry.category.clone()),
                });
            }
            results.extend(
                EMOJI
                    .iter()
                    .filter(|entry| {
                        !(direct_key.is_some() && entry.emoji == query)
                            && terms.iter().all(|term| {
                                entry.search.contains(term) || entry.emoji.contains(term)
                            })
                    })
                    .map(|entry| IconChoice {
                        key: format!("emoji:{}", entry.emoji),
                        label: entry.label.clone(),
                        icon: SessionIcon::Emoji(entry.emoji.clone()),
                        category: Some(entry.category.clone()),
                    }),
            );
            results
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::session_icon::is_valid_key;
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn session_icon_catalog_is_complete_unique_and_selectable() {
        let entries = choices(IconPickerTab::Emoji, "");
        assert!(
            entries.len() > 3000,
            "include skin-tone variants, not a small sample"
        );
        let mut keys = HashSet::new();
        for entry in entries {
            assert!(is_valid_key(&entry.key), "invalid emoji {:?}", entry.key);
            assert!(!entry.label.trim().is_empty());
            assert!(
                emoji_categories()
                    .iter()
                    .any(|(id, _)| Some(*id) == entry.category.as_deref())
            );
            assert!(keys.insert(entry.key), "duplicate emoji choice");
        }
    }

    #[test]
    fn session_icon_catalog_keeps_faces_and_people_in_separate_categories() {
        let entries = choices(IconPickerTab::Emoji, "");
        let category = |emoji: &str| {
            entries
                .iter()
                .find(|entry| entry.key == format!("emoji:{emoji}"))
                .and_then(|entry| entry.category.as_deref())
        };
        assert_eq!(category("😀"), Some("smileys_emotion"));
        assert_eq!(category("❤️"), Some("smileys_emotion"));
        assert_eq!(category("👋"), Some("people_body"));
        assert_eq!(category("👩🏽‍💻"), Some("people_body"));
        assert_eq!(category("🏽"), Some("people_body"));
        assert_eq!(category("🇸🇬"), Some("flags"));
        assert!(
            !entries
                .iter()
                .any(|entry| entry.category.as_deref() == Some("smileys_people"))
        );
    }

    #[test]
    fn session_icon_catalog_searches_names_aliases_and_multiple_words() {
        let search = |query| {
            choices(IconPickerTab::Emoji, query)
                .into_iter()
                .map(|choice| choice.key)
                .collect::<Vec<_>>()
        };
        assert_eq!(search("ROCKET"), search(" rocket "));
        assert!(search("rocket").contains(&"emoji:🚀".into()));
        assert!(
            search(":thumbsup:")
                .iter()
                .any(|key| key.starts_with("emoji:👍"))
        );
        assert!(
            search("woman technologist")
                .iter()
                .any(|key| key == "emoji:👩‍💻")
        );
        assert_eq!(search("woman technologist"), search("TECHNOLOGIST WOMAN"));
        assert!(search("thisemojiwillneverexist8675309").is_empty());
    }

    #[test]
    fn session_icon_catalog_pasted_emoji_preserves_the_whole_grapheme() {
        for emoji in ["👩🏽‍💻", "🇸🇬", "❤️", "1️⃣", "👨‍👩‍👧‍👦", "✦"]
        {
            let entries = choices(IconPickerTab::Emoji, emoji);
            assert_eq!(entries[0].key, format!("emoji:{emoji}"));
            assert_eq!(entries[0].icon, SessionIcon::Emoji(emoji.to_owned()));
            assert_eq!(
                entries
                    .iter()
                    .filter(|entry| entry.key == entries[0].key)
                    .count(),
                1
            );
        }
        assert!(
            !choices(IconPickerTab::Emoji, "a")
                .iter()
                .any(|entry| entry.key == "emoji:a")
        );
        assert!(
            !choices(IconPickerTab::Emoji, "🚀🐱")
                .iter()
                .any(|entry| entry.key == "emoji:🚀🐱")
        );
    }

    #[test]
    fn session_icon_catalog_stock_keys_remain_unchanged() {
        let icons = choices(IconPickerTab::Icons, "");
        assert_eq!(icons.len(), SESSION_ICONS.len());
        assert_eq!(choices(IconPickerTab::Icons, "web")[0].key, "globe");
        assert_eq!(choices(IconPickerTab::Icons, "CODE")[0].key, "code");
        assert!(choices(IconPickerTab::Icons, "🚀").is_empty());
        assert!(choices(IconPickerTab::Icons, "does not exist").is_empty());
    }
}
