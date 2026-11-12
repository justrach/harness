//! Minimal C-ABI bridge over `loro` 1.13 implementing the `chat2` `SessionDoc`
//! container layout (`meta`, `messages`, `commands`, `queue`, and `VersionVector`
//! frontiers) so Zig `harness-engine` and `harness-nano` round-trip binary
//! Loro snapshots and incremental CRDT updates with Desktop/iOS Harness peers.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

use loro::{
    Container, ExportMode, LoroDoc, LoroList, LoroMap, LoroText, LoroValue, ToJson,
    ValueOrContainer, VersionVector,
};
use serde_json::{json, Map, Value};

pub struct LoroSession {
    doc: LoroDoc,
}

unsafe fn slice_from_raw<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        unsafe { slice::from_raw_parts(ptr, len) }
    }
}

unsafe fn write_out_bytes(bytes: Vec<u8>, out_ptr: *mut *mut u8, out_len: *mut usize) {
    if out_ptr.is_null() || out_len.is_null() {
        return;
    }
    if bytes.is_empty() {
        unsafe {
            *out_ptr = std::ptr::null_mut();
            *out_len = 0;
        }
        return;
    }
    let mut boxed: Box<[u8]> = bytes.into_boxed_slice();
    let len = boxed.len();
    let raw = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_ptr = raw;
        *out_len = len;
    }
}

#[no_mangle]
pub extern "C" fn loro_bytes_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        let raw_slice = std::ptr::slice_from_raw_parts_mut(ptr, len);
        drop(Box::from_raw(raw_slice));
    }));
}

#[no_mangle]
pub extern "C" fn loro_session_new() -> *mut LoroSession {
    catch_unwind(|| Box::into_raw(Box::new(LoroSession { doc: LoroDoc::new() })))
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn loro_session_free(session: *mut LoroSession) {
    if session.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
        drop(Box::from_raw(session));
    }));
}

/// Import a Loro snapshot or update blob.
/// Returns `0` when cleanly applied, `1` when buffered awaiting causal dependencies,
/// or `-1` on invalid bytes.
#[no_mangle]
pub extern "C" fn loro_session_import(
    session: *mut LoroSession,
    bytes_ptr: *const u8,
    bytes_len: usize,
) -> i32 {
    if session.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { &mut *session };
        let bytes = unsafe { slice_from_raw(bytes_ptr, bytes_len) };
        if bytes.is_empty() {
            return 0;
        }
        match s.doc.import(bytes) {
            Ok(status) => {
                if status.pending.is_some() {
                    1
                } else {
                    0
                }
            }
            Err(_) => -1,
        }
    }))
    .unwrap_or(-1)
}

/// Exact `chat2` client-side frontier precision check:
/// empty or undecodable frontiers return `0` (not contained -> fetch checkpoint).
#[no_mangle]
pub extern "C" fn loro_session_contains_frontier(
    session: *const LoroSession,
    frontier_ptr: *const u8,
    frontier_len: usize,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { &*session };
        let frontier = unsafe { slice_from_raw(frontier_ptr, frontier_len) };
        if frontier.is_empty() {
            return 0;
        }
        let Ok(vv) = VersionVector::decode(frontier) else {
            return 0;
        };
        if vv.is_empty() {
            return 0;
        }
        if s.doc.oplog_vv().includes_vv(&vv) {
            1
        } else {
            0
        }
    }))
    .unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn loro_session_export_snapshot(
    session: *const LoroSession,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if session.is_null() || out_ptr.is_null() || out_len.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { &*session };
        match s.doc.export(ExportMode::Snapshot) {
            Ok(bytes) => {
                unsafe { write_out_bytes(bytes, out_ptr, out_len) };
                0
            }
            Err(_) => -1,
        }
    }))
    .unwrap_or(-1)
}

#[no_mangle]
pub extern "C" fn loro_session_export_frontier(
    session: *const LoroSession,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if session.is_null() || out_ptr.is_null() || out_len.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { &*session };
        let bytes = s.doc.oplog_vv().encode();
        unsafe { write_out_bytes(bytes, out_ptr, out_len) };
        0
    }))
    .unwrap_or(-1)
}

fn normalize_doc_part_for_app(raw_part: &Value, entry_id: &str, ix: usize) -> Option<Value> {
    let obj = raw_part.as_object()?;
    let id = obj
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{entry_id}#part-{ix}"));
    let kind = obj
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            if obj.contains_key("reasoning") {
                "reasoning"
            } else if obj.contains_key("call") {
                "tool"
            } else if obj.contains_key("message") {
                "error"
            } else {
                "text"
            }
        });

    let mut out = Map::new();
    out.insert("id".into(), Value::String(id));
    out.insert("kind".into(), Value::String(kind.to_owned()));

    match kind {
        "reasoning" => {
            let body = obj
                .get("reasoning")
                .and_then(Value::as_str)
                .or_else(|| obj.get("text").and_then(Value::as_str))
                .unwrap_or_default();
            out.insert("text".into(), Value::String(body.to_owned()));
            out.insert("reasoning".into(), Value::String(body.to_owned()));
        }
        "tool" => {
            if let Some(call) = obj.get("call") {
                out.insert("call".into(), call.clone());
            } else {
                out.insert("call".into(), json!({"kind": "unknown", "name": "Tool"}));
            }
            // In Loro `DocPartJson`, `isError` presence IS the resolution marker (`schema.rs:276`).
            let is_err_opt = obj.get("isError").and_then(Value::as_bool);
            let resolved = is_err_opt.is_some()
                || obj.get("resolved").and_then(Value::as_bool).unwrap_or(false);
            out.insert("resolved".into(), Value::Bool(resolved));
            out.insert("isError".into(), Value::Bool(is_err_opt.unwrap_or(false)));
            for k in [
                "output",
                "diff",
                "outputRef",
                "outputBytes",
                "diffRef",
                "diffStats",
                "subagentRef",
                "subagentStatus",
                "subagentTail",
                "view",
            ] {
                if let Some(v) = obj.get(k) {
                    if !v.is_null() {
                        out.insert(k.into(), v.clone());
                    }
                }
            }
        }
        "error" => {
            let msg = obj
                .get("message")
                .and_then(Value::as_str)
                .or_else(|| obj.get("text").and_then(Value::as_str))
                .unwrap_or_default();
            out.insert("message".into(), Value::String(msg.to_owned()));
            if let Some(reauth) = obj.get("reauth") {
                if !reauth.is_null() {
                    out.insert("reauth".into(), reauth.clone());
                }
            }
        }
        "image" => {
            for k in ["path", "name", "mimeType"] {
                if let Some(v) = obj.get(k) {
                    out.insert(k.into(), v.clone());
                }
            }
        }
        "visual" => {
            for k in ["title", "script"] {
                if let Some(v) = obj.get(k) {
                    out.insert(k.into(), v.clone());
                }
            }
        }
        "input" => {
            if let Some(q) = obj.get("questions") {
                out.insert("questions".into(), q.clone());
            }
            out.insert(
                "resolved".into(),
                Value::Bool(obj.get("resolved").and_then(Value::as_bool).unwrap_or(false)),
            );
        }
        _ => {
            let txt = obj.get("text").and_then(Value::as_str).unwrap_or_default();
            out.insert("text".into(), Value::String(txt.to_owned()));
        }
    }

    Some(Value::Object(out))
}

/// Materialize `messages` from `LoroDoc` as a JSON array of normalized `SessionMessageEntry` objects,
/// joining `continuationOf` entries onto their root entry in list order (`join_continuation_entries`).
#[no_mangle]
pub extern "C" fn loro_session_read_messages_json(
    session: *const LoroSession,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
) -> i32 {
    if session.is_null() || out_ptr.is_null() || out_len.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { &*session };
        let raw_messages = s.doc.get_list("messages").get_deep_value().to_json_value();
        let Some(arr) = raw_messages.as_array() else {
            unsafe { write_out_bytes(b"[]".to_vec(), out_ptr, out_len) };
            return 0;
        };

        let mut out_entries: Vec<Map<String, Value>> = Vec::with_capacity(arr.len());
        let mut root_index: HashMap<String, usize> = HashMap::new();

        for (entry_ix, item) in arr.iter().enumerate() {
            let Some(obj) = item.as_object() else {
                continue;
            };
            let id = obj
                .get("id")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .unwrap_or_else(|| format!("recovered-{entry_ix}"));
            let role = match obj.get("role").and_then(Value::as_str) {
                Some("user") => "user",
                Some("system") => "system",
                _ => "assistant",
            };
            let created_at = obj.get("createdAt").and_then(Value::as_i64).unwrap_or(0);
            let device_id = obj
                .get("deviceId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned();
            let status = obj.get("status").and_then(Value::as_str).map(str::to_owned);
            let cont_of = obj
                .get("continuationOf")
                .and_then(Value::as_str)
                .map(str::to_owned);
            let duration_ms = obj.get("durationMs").and_then(Value::as_i64);

            let mut norm_parts: Vec<Value> = Vec::new();
            if let Some(parts_arr) = obj.get("parts").and_then(Value::as_array) {
                for (pix, p_val) in parts_arr.iter().enumerate() {
                    if let Some(np) = normalize_doc_part_for_app(p_val, &id, pix) {
                        norm_parts.push(np);
                    }
                }
            }

            if let Some(root_id) = &cont_of {
                if let Some(&root_pos) = root_index.get(root_id) {
                    if let Some(Value::Array(existing_parts)) =
                        out_entries[root_pos].get_mut("parts")
                    {
                        existing_parts.extend(norm_parts);
                    }
                    if let Some(dms) = duration_ms {
                        out_entries[root_pos].insert("durationMs".into(), Value::Number(dms.into()));
                    }
                    if let Some(st) = status {
                        out_entries[root_pos].insert("status".into(), Value::String(st));
                    }
                    continue;
                }
            }

            let mut norm = Map::new();
            norm.insert("id".into(), Value::String(id.clone()));
            norm.insert("role".into(), Value::String(role.into()));
            norm.insert("createdAt".into(), Value::Number(created_at.into()));
            norm.insert("deviceId".into(), Value::String(device_id));
            if let Some(st) = status {
                norm.insert("status".into(), Value::String(st));
            }
            if let Some(dms) = duration_ms {
                norm.insert("durationMs".into(), Value::Number(dms.into()));
            }
            norm.insert("parts".into(), Value::Array(norm_parts));

            if cont_of.is_none() {
                root_index.insert(id, out_entries.len());
            }
            out_entries.push(norm);
        }

        let final_val = Value::Array(out_entries.into_iter().map(Value::Object).collect());
        match serde_json::to_vec(&final_val) {
            Ok(bytes) => {
                unsafe { write_out_bytes(bytes, out_ptr, out_len) };
                0
            }
            Err(_) => -1,
        }
    }))
    .unwrap_or(-1)
}

fn map_str(map: &LoroMap, key: &str) -> Option<String> {
    match map.get(key) {
        Some(ValueOrContainer::Value(LoroValue::String(s))) => Some(s.to_string()),
        _ => None,
    }
}

fn map_i64(map: &LoroMap, key: &str) -> Option<i64> {
    match map.get(key) {
        Some(ValueOrContainer::Value(LoroValue::I64(n))) => Some(n),
        _ => None,
    }
}

fn map_bool(map: &LoroMap, key: &str) -> Option<bool> {
    match map.get(key) {
        Some(ValueOrContainer::Value(LoroValue::Bool(b))) => Some(b),
        _ => None,
    }
}

fn push_part_to_loro(parts: &LoroList, part: &Map<String, Value>) -> Result<(), loro::LoroError> {
    let map = parts.push_container(LoroMap::new())?;
    let id = part.get("id").and_then(Value::as_str).unwrap_or("part");
    let kind = part.get("kind").and_then(Value::as_str).unwrap_or("text");
    map.insert("id", id)?;
    map.insert("kind", kind)?;

    match kind {
        "reasoning" => {
            let body = part
                .get("reasoning")
                .and_then(Value::as_str)
                .or_else(|| part.get("text").and_then(Value::as_str))
                .unwrap_or_default();
            let t = map.insert_container("reasoning", LoroText::new())?;
            if !body.is_empty() {
                t.insert(0, body)?;
            }
        }
        "tool" => {
            if let Some(call) = part.get("call") {
                map.insert("call", LoroValue::from(call.clone()))?;
            }
            let resolved = part
                .get("resolved")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if resolved {
                let is_err = part
                    .get("isError")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                map.insert("isError", is_err)?;
            }
            if let Some(output) = part.get("output").and_then(Value::as_str) {
                map.insert("output", output)?;
            }
            for k in ["diff", "diffStats", "view"] {
                if let Some(v) = part.get(k) {
                    if !v.is_null() {
                        map.insert(k, LoroValue::from(v.clone()))?;
                    }
                }
            }
            for k in [
                "outputRef",
                "diffRef",
                "subagentRef",
                "subagentStatus",
                "subagentTail",
            ] {
                if let Some(s) = part.get(k).and_then(Value::as_str) {
                    map.insert(k, s)?;
                }
            }
            if let Some(ob) = part.get("outputBytes").and_then(Value::as_i64) {
                map.insert("outputBytes", ob)?;
            }
        }
        "error" => {
            let msg = part
                .get("message")
                .and_then(Value::as_str)
                .or_else(|| part.get("text").and_then(Value::as_str))
                .unwrap_or_default();
            map.insert("message", msg)?;
            if let Some(reauth) = part.get("reauth").and_then(Value::as_str) {
                map.insert("reauth", reauth)?;
            }
        }
        "image" => {
            for k in ["path", "name", "mimeType"] {
                if let Some(s) = part.get(k).and_then(Value::as_str) {
                    map.insert(k, s)?;
                }
            }
        }
        "visual" => {
            for k in ["title", "script"] {
                if let Some(s) = part.get(k).and_then(Value::as_str) {
                    map.insert(k, s)?;
                }
            }
        }
        "input" => {
            if let Some(q) = part.get("questions") {
                map.insert("questions", LoroValue::from(q.clone()))?;
            }
            let resolved = part
                .get("resolved")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            map.insert("resolved", resolved)?;
        }
        _ => {
            let txt = part.get("text").and_then(Value::as_str).unwrap_or_default();
            let t = map.insert_container("text", LoroText::new())?;
            if !txt.is_empty() {
                t.insert(0, txt)?;
            }
        }
    }
    Ok(())
}

fn update_part_in_loro(map: &LoroMap, part: &Map<String, Value>) -> Result<bool, loro::LoroError> {
    let mut dirty = false;
    let kind = part.get("kind").and_then(Value::as_str).unwrap_or("text");
    match kind {
        "text" | "reasoning" => {
            let field = if kind == "reasoning" {
                "reasoning"
            } else {
                "text"
            };
            let new_str = if kind == "reasoning" {
                part.get("reasoning")
                    .and_then(Value::as_str)
                    .or_else(|| part.get("text").and_then(Value::as_str))
                    .unwrap_or_default()
            } else {
                part.get("text").and_then(Value::as_str).unwrap_or_default()
            };
            match map.get(field) {
                Some(ValueOrContainer::Container(Container::Text(t))) => {
                    let old_str = t.to_string();
                    if old_str != new_str {
                        if let Some(delta) = new_str.strip_prefix(&old_str) {
                            let char_len = t.len_unicode();
                            t.insert(char_len, delta)?;
                        } else {
                            let _ = t.update(new_str, Default::default());
                        }
                        dirty = true;
                    }
                }
                _ => {
                    let t = map.insert_container(field, LoroText::new())?;
                    if !new_str.is_empty() {
                        t.insert(0, new_str)?;
                    }
                    dirty = true;
                }
            }
        }
        "tool" => {
            if let Some(call) = part.get("call") {
                map.insert("call", LoroValue::from(call.clone()))?;
                dirty = true;
            }
            if let Some(output) = part.get("output").and_then(Value::as_str) {
                if map_str(map, "output").as_deref() != Some(output) {
                    map.insert("output", output)?;
                    dirty = true;
                }
            }
            let resolved = part
                .get("resolved")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            if resolved {
                let is_err = part
                    .get("isError")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                if map_bool(map, "isError") != Some(is_err) {
                    map.insert("isError", is_err)?;
                    dirty = true;
                }
            }
        }
        _ => {}
    }
    Ok(dirty)
}

fn sync_one_entry(messages: &LoroList, entry: &Map<String, Value>) -> Result<bool, loro::LoroError> {
    let Some(entry_id) = entry.get("id").and_then(Value::as_str) else {
        return Ok(false);
    };
    if entry_id.is_empty() {
        return Ok(false);
    }

    // Reverse scan: the active streaming message is almost always at the tail.
    let mut found_map: Option<LoroMap> = None;
    for i in (0..messages.len()).rev() {
        if let Some(ValueOrContainer::Container(Container::Map(m))) = messages.get(i) {
            if map_str(&m, "id").as_deref() == Some(entry_id) {
                found_map = Some(m);
                break;
            }
        }
    }

    if let Some(map) = found_map {
        let mut dirty = false;
        if let Some(st) = entry.get("status").and_then(Value::as_str) {
            if map_str(&map, "status").as_deref() != Some(st) {
                map.insert("status", st)?;
                dirty = true;
            }
        }
        if let Some(dms) = entry.get("durationMs").and_then(Value::as_i64) {
            if map_i64(&map, "durationMs") != Some(dms) {
                map.insert("durationMs", dms)?;
                dirty = true;
            }
        }
        let parts_list = match map.get("parts") {
            Some(ValueOrContainer::Container(Container::List(l))) => l,
            _ => {
                dirty = true;
                map.insert_container("parts", LoroList::new())?
            }
        };
        if let Some(parts_arr) = entry.get("parts").and_then(Value::as_array) {
            for p_val in parts_arr {
                let Some(p_obj) = p_val.as_object() else {
                    continue;
                };
                let p_id = p_obj.get("id").and_then(Value::as_str).unwrap_or("");
                let mut existing_part: Option<LoroMap> = None;
                if !p_id.is_empty() {
                    for j in (0..parts_list.len()).rev() {
                        if let Some(ValueOrContainer::Container(Container::Map(pm))) =
                            parts_list.get(j)
                        {
                            if map_str(&pm, "id").as_deref() == Some(p_id) {
                                existing_part = Some(pm);
                                break;
                            }
                        }
                    }
                }
                if let Some(pm) = existing_part {
                    if update_part_in_loro(&pm, p_obj)? {
                        dirty = true;
                    }
                } else {
                    push_part_to_loro(&parts_list, p_obj)?;
                    dirty = true;
                }
            }
        }
        return Ok(dirty);
    }

    let map = messages.push_container(LoroMap::new())?;
    map.insert("id", entry_id)?;
    let role = entry
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or("assistant");
    map.insert("role", role)?;
    let created_at = entry.get("createdAt").and_then(Value::as_i64).unwrap_or(0);
    map.insert("createdAt", created_at)?;
    let device_id = entry
        .get("deviceId")
        .and_then(Value::as_str)
        .unwrap_or_default();
    map.insert("deviceId", device_id)?;
    if let Some(st) = entry.get("status").and_then(Value::as_str) {
        map.insert("status", st)?;
    }
    if let Some(cont) = entry.get("continuationOf").and_then(Value::as_str) {
        map.insert("continuationOf", cont)?;
    }
    if let Some(dms) = entry.get("durationMs").and_then(Value::as_i64) {
        map.insert("durationMs", dms)?;
    }
    let parts_list = map.insert_container("parts", LoroList::new())?;
    if let Some(parts_arr) = entry.get("parts").and_then(Value::as_array) {
        for p_val in parts_arr {
            if let Some(p_obj) = p_val.as_object() {
                push_part_to_loro(&parts_list, p_obj)?;
            }
        }
    }
    Ok(true)
}

/// Sync one `SessionMessageEntry` object (`{...}`) or an array of entries (`[...]`) into
/// `LoroSession` and export the resulting `ExportMode::updates(&before)` CRDT delta bytes.
/// If nothing changed, writes `out_len = 0` and returns `0`.
#[no_mangle]
pub extern "C" fn loro_session_sync_messages_json(
    session: *mut LoroSession,
    chat_id_ptr: *const u8,
    chat_id_len: usize,
    entries_json_ptr: *const u8,
    entries_json_len: usize,
    out_update_ptr: *mut *mut u8,
    out_update_len: *mut usize,
) -> i32 {
    if session.is_null() || out_update_ptr.is_null() || out_update_len.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let s = unsafe { &mut *session };
        let chat_id_bytes = unsafe { slice_from_raw(chat_id_ptr, chat_id_len) };
        let json_bytes = unsafe { slice_from_raw(entries_json_ptr, entries_json_len) };
        let Ok(chat_id) = std::str::from_utf8(chat_id_bytes) else {
            return -1;
        };
        let Ok(parsed) = serde_json::from_slice::<Value>(json_bytes) else {
            return -1;
        };

        let before = s.doc.oplog_vv();
        let mut dirty = false;

        let meta = s.doc.get_map("meta");
        if map_str(&meta, "chatId").is_none() && !chat_id.is_empty() {
            if meta.insert("chatId", chat_id).is_ok() {
                let _ = meta.insert("schemaVersion", 1i64);
                dirty = true;
            }
        }

        let messages = s.doc.get_list("messages");
        match &parsed {
            Value::Array(arr) => {
                for v in arr {
                    if let Some(obj) = v.as_object() {
                        if sync_one_entry(&messages, obj).unwrap_or(false) {
                            dirty = true;
                        }
                    }
                }
            }
            Value::Object(obj) => {
                if sync_one_entry(&messages, obj).unwrap_or(false) {
                    dirty = true;
                }
            }
            _ => return -1,
        }

        if !dirty {
            unsafe { write_out_bytes(Vec::new(), out_update_ptr, out_update_len) };
            return 0;
        }

        s.doc.commit();
        if s.doc.oplog_vv() == before {
            unsafe { write_out_bytes(Vec::new(), out_update_ptr, out_update_len) };
            return 0;
        }

        match s.doc.export(ExportMode::updates(&before)) {
            Ok(delta) => {
                unsafe { write_out_bytes(delta, out_update_ptr, out_update_len) };
                0
            }
            Err(_) => -1,
        }
    }))
    .unwrap_or(-1)
}
