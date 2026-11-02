//! Runs `protocol/desktop/theme.json` against the built-in Codegraff themes.
//! harness-nano draws with the same roles (`apps/nano/src/parity.zig`).

use harness_theme::builtin_registry;
use serde_json::Value;

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/desktop/theme.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn the_codegraff_roles_are_the_vectors() {
    for v in vectors()["variants"].as_array().unwrap() {
        let id = v["id"].as_str().unwrap();
        let t = builtin_registry()
            .variant(id)
            .unwrap_or_else(|| panic!("no theme {id}"));
        let c = &t.colors;
        let roles = [
            ("background", c.background),
            ("shell", c.shell),
            ("raised", c.raised),
            ("card", c.card),
            ("text", c.text),
            ("textMuted", c.text_muted),
            ("textFaint", c.text_faint),
            ("hover", c.hover),
            ("border", c.border),
            ("borderStrong", c.border_strong),
            ("danger", c.danger),
            ("dangerMuted", c.danger_muted),
            ("warning", c.warning),
            ("success", c.success),
            ("solid", c.solid),
            ("onSolid", c.on_solid),
            ("diffAdd", c.diff_add),
            ("diffDelete", c.diff_delete),
        ];
        for (name, got) in roles {
            assert_eq!(
                got.to_string(),
                v["colors"][name].as_str().unwrap(),
                "{id} {name}"
            );
        }
        assert_eq!(
            t.accent.primary.to_string(),
            v["accent"]["primary"].as_str().unwrap(),
            "{id} accent"
        );
        assert_eq!(
            t.accent.wash.to_string(),
            v["accent"]["wash"].as_str().unwrap(),
            "{id} wash"
        );
        for (i, g) in t.accent.glyph.iter().enumerate() {
            assert_eq!(
                g.to_string(),
                v["accent"]["glyph"][i].as_str().unwrap(),
                "{id} glyph {i}"
            );
        }
        for (i, a) in t.terminal.ansi.iter().enumerate() {
            assert_eq!(
                a.to_string(),
                v["ansi"][i].as_str().unwrap(),
                "{id} ansi {i}"
            );
        }
    }
}
