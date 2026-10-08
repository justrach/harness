//! Text typed on another device, as US-keyboard HID key presses for the
//! simulator (USB HID Usage Tables, keyboard page 0x07).

const LEFT_SHIFT: u16 = 225;

/// One key transition the hub's HID socket accepts (`{type, usage}`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub(crate) struct KeyEvent {
    #[serde(rename = "type")]
    pub kind: KeyKind,
    pub usage: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum KeyKind {
    Down,
    Up,
}

/// (usage, shift) for one character, or None for one a US keyboard can't type.
fn usage(c: char) -> Option<(u16, bool)> {
    const DIGITS: &str = "1234567890";
    const SHIFTED_DIGITS: &str = "!@#$%^&*()";
    const PUNCTUATION: [(char, char, u16); 11] = [
        ('-', '_', 45),
        ('=', '+', 46),
        ('[', '{', 47),
        (']', '}', 48),
        ('\\', '|', 49),
        (';', ':', 51),
        ('\'', '"', 52),
        ('`', '~', 53),
        (',', '<', 54),
        ('.', '>', 55),
        ('/', '?', 56),
    ];
    match c {
        'a'..='z' => Some((4 + (c as u16 - 'a' as u16), false)),
        'A'..='Z' => Some((4 + (c as u16 - 'A' as u16), true)),
        '\n' => Some((40, false)),
        '\t' => Some((43, false)),
        ' ' => Some((44, false)),
        _ => {
            if let Some(i) = DIGITS.find(c) {
                return Some((30 + i as u16, false));
            }
            if let Some(i) = SHIFTED_DIGITS.find(c) {
                return Some((30 + i as u16, true));
            }
            PUNCTUATION.iter().find_map(|&(plain, shifted, usage)| {
                (c == plain)
                    .then_some((usage, false))
                    .or((c == shifted).then_some((usage, true)))
            })
        }
    }
}

/// Every press for `text`, or the first character that can't be typed.
pub(crate) fn type_text(text: &str) -> Result<Vec<KeyEvent>, char> {
    let mut events = Vec::new();
    for c in text.chars().filter(|&c| c != '\r') {
        let (usage, shift) = usage(c).ok_or(c)?;
        let press = |kind, usage| KeyEvent { kind, usage };
        if shift {
            events.push(press(KeyKind::Down, LEFT_SHIFT));
        }
        events.push(press(KeyKind::Down, usage));
        events.push(press(KeyKind::Up, usage));
        if shift {
            events.push(press(KeyKind::Up, LEFT_SHIFT));
        }
    }
    Ok(events)
}

/// Named keys the viewer sends on their own.
pub(crate) fn named(key: &str) -> Option<u16> {
    Some(match key {
        "enter" => 40,
        "escape" => 41,
        "backspace" => 42,
        "tab" => 43,
        "right" => 79,
        "left" => 80,
        "down" => 81,
        "up" => 82,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usages(text: &str) -> Vec<(KeyKind, u16)> {
        type_text(text)
            .unwrap()
            .into_iter()
            .map(|e| (e.kind, e.usage))
            .collect()
    }

    #[test]
    fn letters_digits_and_punctuation_map_to_us_keys_with_shift_where_needed() {
        use KeyKind::*;
        assert_eq!(usages("a"), vec![(Down, 4), (Up, 4)]);
        assert_eq!(
            usages("Z"),
            vec![(Down, LEFT_SHIFT), (Down, 29), (Up, 29), (Up, LEFT_SHIFT)]
        );
        assert_eq!(usages("0"), vec![(Down, 39), (Up, 39)]);
        assert_eq!(
            usages("?"),
            vec![(Down, LEFT_SHIFT), (Down, 56), (Up, 56), (Up, LEFT_SHIFT)]
        );
        assert_eq!(usages("\r\n"), vec![(Down, 40), (Up, 40)]);
    }

    #[test]
    fn a_character_off_the_us_keyboard_is_refused_by_name() {
        assert_eq!(type_text("hé"), Err('é'));
    }
}
