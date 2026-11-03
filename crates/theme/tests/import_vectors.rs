//! The VS Code theme import vectors (`apps/parity/vectors/theme-import.json`):
//! made-up themes and the exact compilation `compile_source` makes of each.
//! harness-nano runs the same cases against its port, so the two importers
//! can't drift apart. `UPDATE_THEME_VECTORS=1` rewrites `expected`.

use std::fs;
use std::path::Path;

use harness_theme::vscode::{CompileOptions, compile_source};
use serde_json::Value;

const VECTORS: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../apps/parity/vectors/theme-import.json"
);

/// Every string in `value` with the case folder's path written as `$ROOT`.
fn rooted(value: Value, root: &str) -> Value {
    match value {
        Value::String(s) => Value::String(s.replace(root, "$ROOT")),
        Value::Array(items) => Value::Array(items.into_iter().map(|v| rooted(v, root)).collect()),
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(k, v)| (k.replace(root, "$ROOT"), rooted(v, root)))
                .collect(),
        ),
        other => other,
    }
}

fn compile_case(case: &Value) -> Value {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    for (path, contents) in case["files"].as_object().unwrap() {
        let file = root.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, contents.as_str().unwrap()).unwrap();
    }
    let entry = case["entry"].as_str().unwrap();
    let path = if entry.is_empty() {
        root.clone()
    } else {
        root.join(entry)
    };
    let result = compile_source(
        Path::new(&path),
        CompileOptions {
            family_id: case["familyId"].as_str().unwrap().into(),
            family_name: case["familyName"].as_str().unwrap().into(),
            source_url: case["sourceUrl"].as_str().unwrap().into(),
            revision: "local".into(),
            license: "User supplied".into(),
        },
    );
    let value = match result {
        Ok(compilation) => serde_json::to_value(&compilation).unwrap(),
        Err(error) => serde_json::json!({ "error": error.to_string() }),
    };
    rooted(value, &root.display().to_string())
}

#[test]
fn theme_import_vectors_match_the_compiler() {
    let mut doc: Value = serde_json::from_str(&fs::read_to_string(VECTORS).unwrap()).unwrap();
    let update = std::env::var_os("UPDATE_THEME_VECTORS").is_some();
    let cases = doc["cases"].as_array_mut().unwrap();
    for case in cases.iter_mut() {
        let got = compile_case(case);
        if update {
            case["expected"] = got;
        } else {
            assert_eq!(
                case["expected"], got,
                "{}: the compiler changed; rerun with UPDATE_THEME_VECTORS=1 and port the change to harness-nano",
                case["name"]
            );
        }
    }
    if update {
        fs::write(VECTORS, serde_json::to_string_pretty(&doc).unwrap() + "\n").unwrap();
    }
}
