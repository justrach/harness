//! Session icons preserve existing named artwork and complete Unicode glyphs.
use super::*;
use unicode_segmentation::UnicodeSegmentation;
use unicode_width::UnicodeWidthStr;

const EMOJI_PREFIX: &str = "emoji:";

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum SessionIcon {
    Svg(&'static str),
    Emoji(String),
}

impl SessionIcon {
    pub(super) fn from_key(key: Option<&str>) -> Self {
        if let Some(key) = key {
            if let Some((_, _, glyph)) = session_sidebar::SESSION_ICONS
                .iter()
                .find(|(id, _, _)| *id == key)
            {
                return Self::Svg(glyph);
            }
            if let Some(emoji) = key.strip_prefix(EMOJI_PREFIX)
                && emoji_key(emoji).as_deref() == Some(key)
            {
                return Self::Emoji(emoji.to_owned());
            }
        }
        Self::Svg(icons::WIDGET)
    }

    pub(super) fn render(&self, size: f32, color: gpui::Hsla) -> AnyElement {
        match self {
            Self::Svg(glyph) => icon(glyph)
                .size(px(size))
                .text_color(color)
                .into_any_element(),
            Self::Emoji(emoji) => div()
                .size(px(size))
                .flex_none()
                .flex()
                .items_center()
                .justify_center()
                .text_size(px(size * 0.85))
                .line_height(px(size))
                .text_color(color)
                .child(emoji.clone())
                .into_any_element(),
        }
    }
}

pub(super) fn is_valid_key(key: &str) -> bool {
    session_sidebar::SESSION_ICONS
        .iter()
        .any(|(id, _, _)| *id == key)
        || key
            .strip_prefix(EMOJI_PREFIX)
            .is_some_and(|emoji| emoji_key(emoji).as_deref() == Some(key))
}

/// Preserve a complete extended grapheme, including modifiers, flags and ZWJ
/// sequences. Native character palettes may know newer emoji than this app does;
/// allow any single printable Unicode glyph instead of a versioned emoji list.
pub(super) fn emoji_key(input: &str) -> Option<String> {
    let input = input.trim();
    if input.is_empty()
        || input
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace())
        || input.graphemes(true).count() != 1
        || input.width() == 0
    {
        return None;
    }
    Some(format!("{EMOJI_PREFIX}{input}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_emoji_icons_preserve_complete_unicode_sequences() {
        for emoji in [
            "🚀",
            "👩🏽‍💻",
            "🇸🇬",
            "❤️",
            "1️⃣",
            "👨‍👩‍👧‍👦",
            "🏴\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
            "✦",
            "e\u{301}",
        ] {
            let key = emoji_key(emoji).unwrap();
            assert_eq!(key, format!("emoji:{emoji}"));
            assert!(is_valid_key(&key));
            assert_eq!(
                SessionIcon::from_key(Some(&key)),
                SessionIcon::Emoji(emoji.into())
            );
            assert_eq!(emoji_key(&format!(" {emoji} \n")), Some(key));
        }
    }

    #[test]
    fn session_emoji_icons_reject_multiple_glyphs_and_control_characters() {
        for input in [
            "",
            " ",
            "\n",
            "🚀🐱",
            "ab",
            "🚀 🐱",
            "\0",
            "\r\n",
            "🚀\u{7f}",
            "\u{200d}",
            "\u{fe0f}",
        ] {
            assert!(emoji_key(input).is_none(), "accepted {input:?}");
        }
        for key in [
            "emoji:",
            "emoji:🚀🐱",
            "emoji: 🚀",
            "emoji:🚀 ",
            "removed-icon",
            "🚀",
        ] {
            assert!(!is_valid_key(key), "accepted {key:?}");
            assert_eq!(
                SessionIcon::from_key(Some(key)),
                SessionIcon::Svg(icons::WIDGET)
            );
        }
    }

    #[test]
    fn session_emoji_icons_preserve_named_icon_compatibility() {
        assert_eq!(SessionIcon::from_key(None), SessionIcon::Svg(icons::WIDGET));
        for (key, _, glyph) in session_sidebar::SESSION_ICONS {
            assert!(is_valid_key(key));
            assert_eq!(SessionIcon::from_key(Some(key)), SessionIcon::Svg(glyph));
        }
    }
}
