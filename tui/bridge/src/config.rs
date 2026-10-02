//! `config/batchWrite`: the TUI saves its defaults (chosen model, reasoning
//! effort, …) by asking the server to edit `config.toml`, then reads the same
//! file itself on the next launch.
//!
//! The file lives in the TUI's own config home, never `~/.codex`: the model ids
//! saved here are Harness ids (`graff/<model>`), which would break a real
//! `codex` CLI that shared the file.

use std::path::PathBuf;

use serde_json::{Value, json};
use toml_edit::{Array, DocumentMut, InlineTable, Item, Table, Value as TomlValue};

use crate::wire::RpcError;

/// `$CODEX_HOME`, else `~/.harness/tui/codex-home`. `run.sh` exports the same
/// default, so the TUI and the bridge always agree on the directory.
pub fn codex_home() -> PathBuf {
    if let Some(home) = std::env::var_os("CODEX_HOME") {
        return PathBuf::from(home);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/".into());
    home.join(".harness/tui/codex-home")
}

/// `config/read`: the TUI overlays this onto its own config at startup, which
/// is how a model chosen in an earlier session (saved by `batch_write`) comes back.
pub fn read() -> Value {
    let path = codex_home().join("config.toml");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return json!({});
    };
    match text.parse::<DocumentMut>() {
        Ok(doc) => table_to_json(doc.as_table()),
        Err(err) => {
            tracing::warn!(path = %path.display(), %err, "ignoring unparseable config.toml");
            json!({})
        }
    }
}

fn table_to_json(table: &dyn toml_edit::TableLike) -> Value {
    Value::Object(table.iter().map(|(key, item)| (key.to_owned(), item_to_json(item))).collect())
}

fn item_to_json(item: &Item) -> Value {
    match item {
        Item::None => Value::Null,
        Item::Value(value) => value_to_json(value),
        Item::Table(table) => table_to_json(table),
        Item::ArrayOfTables(tables) => Value::Array(tables.iter().map(|t| table_to_json(t)).collect()),
    }
}

fn value_to_json(value: &TomlValue) -> Value {
    match value {
        TomlValue::String(s) => json!(s.value()),
        TomlValue::Integer(i) => json!(i.value()),
        TomlValue::Float(f) => json!(f.value()),
        TomlValue::Boolean(b) => json!(b.value()),
        TomlValue::Datetime(d) => json!(d.value().to_string()),
        TomlValue::Array(items) => Value::Array(items.iter().map(value_to_json).collect()),
        TomlValue::InlineTable(table) => table_to_json(table),
    }
}

pub fn batch_write(params: &Value) -> Result<Value, RpcError> {
    let edits = params
        .get("edits")
        .and_then(Value::as_array)
        .ok_or_else(|| RpcError::invalid_params("missing edits"))?;
    let path = params
        .get("filePath")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .unwrap_or_else(|| codex_home().join("config.toml"));

    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(RpcError::internal(format!("reading {}: {err}", path.display()))),
    };
    let mut doc: DocumentMut = text
        .parse()
        .map_err(|err| RpcError::internal(format!("{} is not valid TOML: {err}", path.display())))?;

    for edit in edits {
        let key_path = edit
            .get("keyPath")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("edit without keyPath"))?;
        let value = edit.get("value").unwrap_or(&Value::Null);
        let upsert = edit.get("mergeStrategy").and_then(Value::as_str) == Some("upsert");
        apply_edit(&mut doc, key_path, value, upsert)?;
    }

    let out = doc.to_string();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|err| RpcError::internal(format!("creating {}: {err}", dir.display())))?;
    }
    let tmp = path.with_extension("toml.tmp");
    std::fs::write(&tmp, &out)
        .and_then(|()| std::fs::rename(&tmp, &path))
        .map_err(|err| RpcError::internal(format!("writing {}: {err}", path.display())))?;

    Ok(json!({
        "filePath": path.display().to_string(),
        "status": "ok",
        "version": version(&out),
    }))
}

fn version(contents: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    contents.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn apply_edit(doc: &mut DocumentMut, key_path: &str, value: &Value, upsert: bool) -> Result<(), RpcError> {
    let mut keys: Vec<&str> = key_path.split('.').collect();
    let leaf = keys.pop().filter(|k| !k.is_empty()).ok_or_else(|| RpcError::invalid_params("empty keyPath"))?;
    let mut table = doc.as_table_mut();
    for key in keys {
        let entry = table.entry(key).or_insert_with(|| {
            let mut t = Table::new();
            t.set_implicit(true);
            Item::Table(t)
        });
        table = entry
            .as_table_mut()
            .ok_or_else(|| RpcError::invalid_params(format!("`{key}` in `{key_path}` is not a table")))?;
    }
    if value.is_null() {
        table.remove(leaf);
        return Ok(());
    }
    if upsert
        && let (Some(object), Some(existing)) = (value.as_object(), table.get_mut(leaf).and_then(Item::as_table_like_mut))
    {
        merge_object(existing, object);
        return Ok(());
    }
    table.insert(leaf, Item::Value(to_toml(value)));
    Ok(())
}

fn merge_object(into: &mut dyn toml_edit::TableLike, object: &serde_json::Map<String, Value>) {
    for (key, value) in object {
        match (value.as_object(), into.get_mut(key).and_then(Item::as_table_like_mut)) {
            (Some(child), Some(existing)) => merge_object(existing, child),
            _ if value.is_null() => {
                into.remove(key);
            }
            _ => {
                into.insert(key, Item::Value(to_toml(value)));
            }
        }
    }
}

fn to_toml(value: &Value) -> TomlValue {
    match value {
        Value::Null => TomlValue::from(""),
        Value::Bool(b) => TomlValue::from(*b),
        Value::Number(n) => match n.as_i64() {
            Some(i) => TomlValue::from(i),
            None => TomlValue::from(n.as_f64().unwrap_or_default()),
        },
        Value::String(s) => TomlValue::from(s.as_str()),
        Value::Array(items) => {
            let mut array = Array::new();
            for item in items {
                array.push(to_toml(item));
            }
            TomlValue::Array(array)
        }
        Value::Object(map) => {
            let mut table = InlineTable::new();
            for (key, value) in map {
                if !value.is_null() {
                    table.insert(key, to_toml(value));
                }
            }
            TomlValue::InlineTable(table)
        }
    }
}
