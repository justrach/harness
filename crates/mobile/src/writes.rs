//! The registry writes a viewer device may make, ported from the iOS `WorkspaceStore` (and its `RegistryDoc` pin
//! logic): chat creates, archive, rename, seen marks, chat config, checkout retargets, deletes and pins. A phone owns
//! no device row and never writes host fields. Every function is pure over the doc; the caller pushes and persists.

use std::collections::{BTreeMap, HashMap};

use harness_doc::{
    KIND_CHATS, KIND_PREFERENCES, KIND_SESSIONS, KIND_SIDEBAR_PINS, KIND_SPACES, OpKind,
    RegistryDoc, RowOp, SIDEBAR_PINS_STATE_ID,
};
use serde_json::{Map, Value, json};

use crate::projection;

/// `WorkspaceStore.maxSidebarPins`.
pub const MAX_SIDEBAR_PINS: usize = 200;

/// A chat's agent picks as `ChatConfig` encodes them on iOS: absent optionals are left out, options always present.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct NewChatConfig {
    pub harness: String,
    pub model: Option<String>,
    pub reasoning: Option<String>,
    pub model_options: HashMap<String, String>,
    pub sandbox: Option<String>,
}

fn config_value(config: &NewChatConfig, keep_options: Option<&Map<String, Value>>) -> Value {
    let mut out = Map::new();
    out.insert("harness".into(), json!(config.harness));
    if let Some(model) = &config.model {
        out.insert("model".into(), json!(model));
    }
    if let Some(reasoning) = &config.reasoning {
        out.insert("reasoning".into(), json!(reasoning));
    }
    // Options the phone cannot show (non-string values) survive an edit made here.
    let mut options = keep_options
        .map(|kept| {
            kept.iter()
                .filter(|(_, v)| !v.is_string())
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect::<Map<_, _>>()
        })
        .unwrap_or_default();
    for (key, choice) in &config.model_options {
        options.insert(key.clone(), json!(choice));
    }
    out.insert("modelOptions".into(), Value::Object(options));
    if let Some(sandbox) = &config.sandbox {
        out.insert("sandbox".into(), json!(sandbox));
    }
    Value::Object(out)
}

fn fields<const N: usize>(pairs: [(&str, Value); N]) -> BTreeMap<String, Value> {
    pairs.into_iter().map(|(k, v)| (k.to_owned(), v)).collect()
}

/// Mint a chat (workspace_host.rs `create_chat` shape, as iOS writes it). Born on chat2 (`roomGen` 2).
#[allow(clippy::too_many_arguments)] // the row's own fields, named at the one call site
pub fn create_chat(
    doc: &mut RegistryDoc,
    chat_id: &str,
    device_id: &str,
    space_id: Option<&str>,
    cwd: &str,
    config: &NewChatConfig,
    branch: Option<&str>,
    now_ms: i64,
) {
    let mut set = fields([
        ("id", json!(chat_id)),
        ("deviceId", json!(device_id)),
        ("archived", json!(false)),
        ("cwd", json!(cwd)),
        ("createdAt", json!(now_ms)),
        ("roomGen", json!(2)),
    ]);
    if let Some(space_id) = space_id {
        set.insert("spaceId".into(), json!(space_id));
    }
    if let Some(branch) = branch {
        set.insert("branch".into(), json!(branch));
    }
    set.insert("config".into(), config_value(config, None));
    doc.write(KIND_CHATS, chat_id, OpKind::Upsert, set);
}

/// Create a project folder row, deduplicated on (device, path) like the desktop palette. iOS asks the owning host to
/// create it over the relay first and writes the row itself only when the host cannot be reached; the host stamps
/// git on arrival either way. Returns the space's id (the existing one for a duplicate).
pub fn create_space(
    doc: &mut RegistryDoc,
    space_id: &str,
    device_id: &str,
    path: &str,
    git_detected: bool,
    now_ms: i64,
) -> String {
    if let Some(existing) = projection::spaces(doc)
        .into_iter()
        .find(|space| space.device_id == device_id && space.path == path)
    {
        return existing.id;
    }
    doc.write(
        KIND_SPACES,
        space_id,
        OpKind::Upsert,
        fields([
            ("id", json!(space_id)),
            ("deviceId", json!(device_id)),
            ("path", json!(path)),
            ("gitDetected", json!(git_detected)),
            ("createdAt", json!(now_ms)),
        ]),
    );
    space_id.to_owned()
}

/// Field sets are `update` ops: they never create or revive a row, so a missing chat writes nothing.
fn update_chat(doc: &mut RegistryDoc, chat_id: &str, set: BTreeMap<String, Value>) -> bool {
    if !doc.row_exists(KIND_CHATS, chat_id) {
        return false;
    }
    doc.write(KIND_CHATS, chat_id, OpKind::Update, set);
    true
}

pub fn set_archived(doc: &mut RegistryDoc, chat_id: &str, archived: bool) -> bool {
    update_chat(doc, chat_id, fields([("archived", json!(archived))]))
}

pub fn rename(doc: &mut RegistryDoc, chat_id: &str, title: &str) -> bool {
    update_chat(doc, chat_id, fields([("title", json!(title))]))
}

pub fn set_chat_checkout(doc: &mut RegistryDoc, chat_id: &str, cwd: &str, branch: &str) -> bool {
    update_chat(
        doc,
        chat_id,
        fields([("cwd", json!(cwd)), ("branch", json!(branch))]),
    )
}

pub fn set_chat_config(doc: &mut RegistryDoc, chat_id: &str, config: &NewChatConfig) -> bool {
    let current = doc.overlay_row(KIND_CHATS, chat_id);
    let kept = current
        .as_ref()
        .and_then(|row| row.fields.get("config"))
        .and_then(|c| c.get("modelOptions"))
        .and_then(Value::as_object)
        .cloned();
    let value = config_value(config, kept.as_ref());
    update_chat(doc, chat_id, fields([("config", value)]))
}

/// The synced seen mark, with a monotonic guard: no write when the stored stamp is already current.
pub fn mark_seen(doc: &mut RegistryDoc, chat_id: &str, now_ms: i64) -> bool {
    let Some(row) = doc.overlay_row(KIND_CHATS, chat_id) else {
        return false;
    };
    let current = row
        .fields
        .get("lastSeenAt")
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)));
    if current.is_some_and(|c| c >= now_ms) {
        return false;
    }
    doc.write(
        KIND_CHATS,
        chat_id,
        OpKind::Update,
        fields([("lastSeenAt", json!(now_ms))]),
    );
    true
}

/// Tombstone a chat and its session-status row in one batch.
pub fn delete_chat(doc: &mut RegistryDoc, chat_id: &str) {
    doc.delete_row_ops(&[(KIND_CHATS, chat_id), (KIND_SESSIONS, chat_id)]);
}

/// Hard-delete a space and every chat in it, in one batch.
pub fn delete_space(doc: &mut RegistryDoc, space_id: &str) {
    let chats: Vec<String> = projection::chats(doc)
        .into_iter()
        .filter(|chat| chat.space_id.as_deref() == Some(space_id))
        .map(|chat| chat.id)
        .collect();
    let mut keys: Vec<(&str, &str)> = Vec::new();
    for id in &chats {
        keys.push((KIND_CHATS, id));
        keys.push((KIND_SESSIONS, id));
    }
    keys.push((KIND_SPACES, space_id));
    doc.delete_row_ops(&keys);
}

/// Cache pin readiness even for an empty list, without importing old preferences.
pub fn initialize_pins(doc: &mut RegistryDoc) {
    if !projection::pins_initialized(doc) {
        doc.write(
            KIND_PREFERENCES,
            SIDEBAR_PINS_STATE_ID,
            OpKind::Upsert,
            fields([("initialized", json!(true))]),
        );
    }
}

/// `RegistryDoc.changeSidebarPin` (iOS). A move never writes membership; an explicit unpin survives delayed moves.
pub fn change_pin(
    doc: &mut RegistryDoc,
    id: &str,
    pinned: Option<bool>,
    after: Option<&str>,
    before: Option<&str>,
) -> bool {
    if !projection::pins_initialized(doc) || id.is_empty() {
        return false;
    }
    if let Some(latest) = doc
        .overlay_row(KIND_SIDEBAR_PINS, id)
        .and_then(|row| row.clocks.values().max().cloned())
    {
        doc.observe_hlc(&latest);
    }
    let current = projection::ordered_pins(doc);
    if pinned == Some(false) {
        doc.write(
            KIND_SIDEBAR_PINS,
            id,
            OpKind::Upsert,
            fields([("pinned", json!(false))]),
        );
        return true;
    }
    let exists = current.iter().any(|(pin, _)| pin == id);
    if pinned.is_none() && !exists {
        return false;
    }
    if !exists && current.len() >= MAX_SIDEBAR_PINS {
        return false;
    }
    let others: Vec<&(String, String)> = current.iter().filter(|(pin, _)| pin != id).collect();
    let index = before
        .and_then(|anchor| others.iter().position(|(pin, _)| pin == anchor))
        .or_else(|| {
            after.and_then(|anchor| {
                others
                    .iter()
                    .position(|(pin, _)| pin == anchor)
                    .map(|i| i + 1)
            })
        })
        .unwrap_or(others.len());
    let hlc = doc.next_hlc();
    let lower = index.checked_sub(1).map(|i| others[i].1.as_str());
    let upper = others.get(index).map(|(_, key)| key.as_str());
    let Ok(key) = harness_proto::pin_order_key_between(lower, upper, &hlc) else {
        return false;
    };
    let mut set = fields([("orderKey", json!(key))]);
    if pinned == Some(true) {
        set.insert("pinned".into(), json!(true));
    }
    doc.enqueue_ops(vec![RowOp {
        kind: KIND_SIDEBAR_PINS.into(),
        id: id.into(),
        op: OpKind::Upsert,
        set: Some(set),
        hlc,
        clocks: None,
    }]);
    true
}

/// `WorkspaceStore.setPinned`: only for a chat that exists, never past the cap, and on a fresh install only once
/// the server's pin list has arrived (`synced`) or a cached one exists. Appends to the end of the pinned list.
pub fn set_pinned(doc: &mut RegistryDoc, chat_id: &str, pinned: bool, synced: bool) -> bool {
    if !projection::chats(doc).iter().any(|chat| chat.id == chat_id) {
        return false;
    }
    if !(synced || projection::pins_initialized(doc)) {
        return false;
    }
    let ids = projection::pinned_session_ids(doc);
    if ids.iter().any(|id| id == chat_id) == pinned {
        return false;
    }
    if pinned && ids.len() >= MAX_SIDEBAR_PINS {
        return false;
    }
    initialize_pins(doc);
    change_pin(
        doc,
        chat_id,
        Some(pinned),
        ids.last().map(String::as_str),
        None,
    )
}

/// After an authoritative registry state: create the pin list if missing and unpin chats that were deleted
/// (archived chats keep their pin, so unarchiving restores the position). True when anything was written.
pub fn prune_deleted_pins(doc: &mut RegistryDoc) -> bool {
    let known: std::collections::HashSet<String> = projection::chats(doc)
        .into_iter()
        .map(|chat| chat.id)
        .collect();
    let initialized = projection::pins_initialized(doc);
    // The projection the screens last read: empty while the list does not exist yet.
    let removed: Vec<String> = projection::pinned_session_ids(doc)
        .into_iter()
        .filter(|id| !known.contains(id))
        .collect();
    initialize_pins(doc);
    for id in &removed {
        change_pin(doc, id, Some(false), None, None);
    }
    !initialized || !removed.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_doc::RegistryRow;

    fn row(kind: &str, id: &str, fields: Value) -> RegistryRow {
        let fields: BTreeMap<String, Value> = serde_json::from_value(fields).unwrap();
        let clocks = fields
            .keys()
            .map(|k| (k.clone(), harness_doc::encode_hlc(1, 0, "desk")))
            .collect();
        RegistryRow {
            kind: kind.into(),
            id: id.into(),
            seq: 1,
            deleted: false,
            del_hlc: None,
            fields,
            clocks,
        }
    }

    fn doc_with(rows: Vec<RegistryRow>) -> RegistryDoc {
        let mut doc = RegistryDoc::new("phone");
        doc.apply_state(1, true, 0, rows);
        doc
    }

    fn chat(id: &str) -> RegistryRow {
        row(
            KIND_CHATS,
            id,
            json!({"id": id, "deviceId": "mac", "createdAt": 5}),
        )
    }

    #[test]
    fn a_new_chat_carries_exactly_the_fields_ios_writes() {
        let mut doc = RegistryDoc::new("phone");
        let config = NewChatConfig {
            harness: "graff".into(),
            model: Some("m".into()),
            ..Default::default()
        };
        create_chat(
            &mut doc,
            "c1",
            "mac",
            Some("s1"),
            "/repo",
            &config,
            Some("main"),
            42,
        );
        let row = doc.overlay_row(KIND_CHATS, "c1").unwrap();
        assert_eq!(
            Value::Object(row.fields.into_iter().collect()),
            json!({
                "id": "c1", "deviceId": "mac", "archived": false, "cwd": "/repo", "createdAt": 42, "roomGen": 2,
                "spaceId": "s1", "branch": "main",
                "config": {"harness": "graff", "model": "m", "modelOptions": {}},
            })
        );
    }

    #[test]
    fn field_writes_never_create_a_chat() {
        let mut doc = RegistryDoc::new("phone");
        assert!(!rename(&mut doc, "ghost", "x"));
        assert!(!set_archived(&mut doc, "ghost", true));
        assert!(!mark_seen(&mut doc, "ghost", 10));
        assert!(doc.overlay_row(KIND_CHATS, "ghost").is_none());
    }

    #[test]
    fn seen_marks_only_move_forward() {
        let mut doc = doc_with(vec![chat("c1")]);
        assert!(mark_seen(&mut doc, "c1", 100));
        assert!(!mark_seen(&mut doc, "c1", 100));
        assert!(!mark_seen(&mut doc, "c1", 50));
        assert!(mark_seen(&mut doc, "c1", 101));
    }

    #[test]
    fn a_config_edit_keeps_options_the_phone_cannot_show() {
        let mut doc = doc_with(vec![row(
            KIND_CHATS,
            "c1",
            json!({"id": "c1", "deviceId": "mac", "config": {"harness": "graff", "modelOptions": {"fast": true, "tier": "a"}}}),
        )]);
        let config = NewChatConfig {
            harness: "graff".into(),
            model_options: HashMap::from([("tier".to_owned(), "b".to_owned())]),
            ..Default::default()
        };
        assert!(set_chat_config(&mut doc, "c1", &config));
        let options =
            doc.overlay_row(KIND_CHATS, "c1").unwrap().fields["config"]["modelOptions"].clone();
        assert_eq!(options, json!({"fast": true, "tier": "b"}));
    }

    #[test]
    fn pins_wait_for_the_server_on_a_fresh_install_then_append() {
        let mut doc = doc_with(vec![chat("a"), chat("b")]);
        // No pin list yet and nothing heard from the server: no write.
        let mut fresh = RegistryDoc::new("phone");
        let _ = fresh.apply_rows(1, vec![chat("a")]);
        assert!(!set_pinned(&mut fresh, "a", true, false));
        assert!(set_pinned(&mut doc, "a", true, true));
        assert!(set_pinned(&mut doc, "b", true, true));
        assert_eq!(projection::pinned_session_ids(&doc), vec!["a", "b"]);
        assert!(!set_pinned(&mut doc, "a", true, true), "already pinned");
        assert!(set_pinned(&mut doc, "a", false, true));
        assert_eq!(projection::pinned_session_ids(&doc), vec!["b"]);
        assert!(!set_pinned(&mut doc, "missing", true, true));
    }

    #[test]
    fn pins_of_deleted_chats_are_dropped_and_archived_ones_kept() {
        let mut doc = doc_with(vec![chat("a"), chat("b")]);
        assert!(set_pinned(&mut doc, "a", true, true));
        assert!(set_pinned(&mut doc, "b", true, true));
        set_archived(&mut doc, "a", true);
        delete_chat(&mut doc, "b");
        assert!(prune_deleted_pins(&mut doc));
        assert_eq!(projection::pinned_session_ids(&doc), vec!["a"]);
        assert!(!prune_deleted_pins(&mut doc));
    }

    #[test]
    fn deleting_a_space_takes_its_chats_in_one_batch() {
        let mut doc = doc_with(vec![
            row(
                KIND_SPACES,
                "s1",
                json!({"id": "s1", "deviceId": "mac", "path": "/r"}),
            ),
            row(
                KIND_CHATS,
                "c1",
                json!({"id": "c1", "deviceId": "mac", "spaceId": "s1"}),
            ),
            row(KIND_CHATS, "c2", json!({"id": "c2", "deviceId": "mac"})),
        ]);
        let before = doc.pending_len();
        delete_space(&mut doc, "s1");
        assert_eq!(doc.pending_len(), before + 1);
        assert!(doc.overlay_row(KIND_CHATS, "c1").is_none());
        assert!(doc.overlay_row(KIND_SPACES, "s1").is_none());
        assert!(doc.overlay_row(KIND_CHATS, "c2").is_some());
    }
}
