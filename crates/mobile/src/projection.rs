//! Registry rows to typed records: a port of `WorkspaceStore.project()` in the iOS app, field for field, so both
//! phones read the same rows the same way (which fields are required, the defaults, and the ordering).

use std::collections::{BTreeMap, HashMap};

use harness_doc::{
    KIND_CHATS, KIND_DEVICES, KIND_PREFERENCES, KIND_SESSIONS, KIND_SIDEBAR_PINS, KIND_SPACES,
    RegistryDoc, SIDEBAR_PINS_STATE_ID,
};
use serde_json::Value;

use crate::records::{
    ChatConfigRecord, ChatRecord, DesktopAppearanceRecord, DeviceRecord, SessionRowRecord,
    SessionStatusRecord, SpaceRecord,
};

type Fields = BTreeMap<String, Value>;

fn string(fields: &Fields, key: &str) -> Option<String> {
    fields.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn boolean(fields: &Fields, key: &str) -> Option<bool> {
    fields.get(key).and_then(Value::as_bool)
}

/// `JSONValue.int64Value`: integers, and doubles truncated toward zero.
fn int(fields: &Fields, key: &str) -> Option<i64> {
    let value = fields.get(key)?;
    value.as_i64().or_else(|| value.as_f64().map(|f| f as i64))
}

pub fn devices(doc: &RegistryDoc) -> Vec<DeviceRecord> {
    let mut out: Vec<DeviceRecord> = doc
        .overlay_rows(KIND_DEVICES)
        .into_iter()
        .map(|row| {
            let f = &row.fields;
            let id = string(f, "id").unwrap_or(row.id.clone());
            DeviceRecord {
                name: string(f, "name").unwrap_or_else(|| id.clone()),
                platform: string(f, "platform").unwrap_or_default(),
                last_seen_at: int(f, "lastSeenAt"),
                created_at: int(f, "createdAt"),
                version: string(f, "version"),
                capabilities: f
                    .get("capabilities")
                    .and_then(Value::as_array)
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|v| v.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default(),
                id,
            }
        })
        .collect();
    // Swift's `<` on String compares by Unicode scalars, as Rust's `cmp` on str does.
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

pub fn spaces(doc: &RegistryDoc) -> Vec<SpaceRecord> {
    let mut out: Vec<SpaceRecord> = doc
        .overlay_rows(KIND_SPACES)
        .into_iter()
        .filter_map(|row| {
            let f = &row.fields;
            Some(SpaceRecord {
                device_id: string(f, "deviceId")?,
                path: string(f, "path")?,
                id: string(f, "id").unwrap_or(row.id.clone()),
                name: string(f, "name"),
                git_detected: boolean(f, "gitDetected").unwrap_or(false),
                git_checked_at: int(f, "gitCheckedAt"),
                checkout_id: string(f, "checkoutId"),
                created_at: int(f, "createdAt").unwrap_or(0),
            })
        })
        .collect();
    // Creation order, id tiebreak.
    out.sort_by(|a, b| (a.created_at, &a.id).cmp(&(b.created_at, &b.id)));
    out
}

fn chat_config(value: &Value) -> Option<ChatConfigRecord> {
    let c = value.as_object()?;
    let text = |key: &str| c.get(key).and_then(Value::as_str).map(str::to_owned);
    Some(ChatConfigRecord {
        harness: text("harness").unwrap_or_else(|| "claude-code".into()),
        model: text("model"),
        reasoning: text("reasoning"),
        model_options: c
            .get("modelOptions")
            .and_then(Value::as_object)
            .map(|options| {
                options
                    .iter()
                    .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_owned())))
                    .collect()
            })
            .unwrap_or_default(),
        sandbox: text("sandbox"),
    })
}

pub fn chats(doc: &RegistryDoc) -> Vec<ChatRecord> {
    doc.overlay_rows(KIND_CHATS)
        .into_iter()
        .filter_map(|row| {
            let f = &row.fields;
            Some(ChatRecord {
                device_id: string(f, "deviceId")?,
                id: string(f, "id").unwrap_or(row.id.clone()),
                title: string(f, "title"),
                archived: boolean(f, "archived").unwrap_or(false),
                cwd: string(f, "cwd"),
                branch: string(f, "branch"),
                checkout_id: string(f, "checkoutId"),
                config: f.get("config").and_then(chat_config),
                last_message_preview: string(f, "lastMessagePreview"),
                last_message_at: int(f, "lastMessageAt"),
                created_at: int(f, "createdAt").unwrap_or(0),
                space_id: string(f, "spaceId"),
                last_seen_at: int(f, "lastSeenAt"),
                room_gen: int(f, "roomGen"),
                last_prompt_at: int(f, "lastPromptAt"),
            })
        })
        .collect()
}

pub fn sessions(doc: &RegistryDoc) -> Vec<SessionRowRecord> {
    let mut by_chat: HashMap<String, SessionRowRecord> = HashMap::new();
    for row in doc.overlay_rows(KIND_SESSIONS) {
        let f = &row.fields;
        let (Some(chat_id), Some(device_id), Some(status)) = (
            string(f, "chatId"),
            string(f, "deviceId"),
            string(f, "status")
                .as_deref()
                .and_then(SessionStatusRecord::parse),
        ) else {
            continue;
        };
        by_chat.insert(
            chat_id.clone(),
            SessionRowRecord {
                chat_id,
                device_id,
                status,
                started_at: int(f, "startedAt"),
                updated_at: int(f, "updatedAt").unwrap_or(0),
            },
        );
    }
    let mut out: Vec<_> = by_chat.into_values().collect();
    out.sort_by(|a, b| a.chat_id.cmp(&b.chat_id));
    out
}

pub fn pins_initialized(doc: &RegistryDoc) -> bool {
    doc.row_exists(KIND_PREFERENCES, SIDEBAR_PINS_STATE_ID)
}

/// `RegistryDoc.orderedSidebarPins` (iOS): rows pinned with a valid order key, by key then id.
pub fn ordered_pins(doc: &RegistryDoc) -> Vec<(String, String)> {
    let mut pins: Vec<(String, String)> = doc
        .overlay_rows(KIND_SIDEBAR_PINS)
        .into_iter()
        .filter_map(|row| {
            if row.fields.get("pinned").and_then(Value::as_bool) != Some(true) {
                return None;
            }
            let key = row.fields.get("orderKey")?.as_str()?;
            harness_proto::valid_pin_order_key(key).then(|| (row.id.clone(), key.to_owned()))
        })
        .collect();
    pins.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));
    pins
}

/// The pinned ids the screens read: empty until the pin list exists (a fresh install waits for the server).
pub fn pinned_session_ids(doc: &RegistryDoc) -> Vec<String> {
    if !pins_initialized(doc) {
        return Vec::new();
    }
    ordered_pins(doc).into_iter().map(|(id, _)| id).collect()
}

pub fn desktop_appearance(doc: &RegistryDoc) -> Option<DesktopAppearanceRecord> {
    let row = doc.overlay_row(KIND_PREFERENCES, "appearance")?;
    let f = &row.fields;
    Some(DesktopAppearanceRecord {
        mode: string(f, "mode")?,
        light: string(f, "light")?,
        dark: string(f, "dark")?,
    })
}
