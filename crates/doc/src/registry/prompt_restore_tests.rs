use super::*;

fn row(archived: bool, clock: String) -> RegistryRow {
    RegistryRow {
        kind: KIND_CHATS.into(),
        id: "chat".into(),
        seq: 1,
        deleted: false,
        del_hlc: None,
        fields: fields([
            ("id", json!("chat")),
            ("deviceId", json!("remote")),
            ("createdAt", json!(1_000)),
            ("archived", json!(archived)),
            ("title", json!("Reference")),
        ]),
        clocks: [("archived".into(), clock)].into_iter().collect(),
    }
}

#[test]
fn close_archive_uses_intent_time_not_delivery_time_and_sends_win_ties() {
    let mut doc = RegistryDoc::new("sender");
    doc.apply_state(1, true, 0, vec![row(true, encode_hlc(1_000, 0, "remote"))]);
    let clock = doc.chat_prompt_clock("chat");
    let sent_at = clock.split('-').next().unwrap().parse::<i64>().unwrap();
    doc.restore_chat_on_send("chat", &clock).unwrap();
    doc.archive_chat_at("chat", sent_at - 1).unwrap();
    assert!(!doc.chat("chat").unwrap().unwrap().archived);
    doc.archive_chat_at("chat", sent_at).unwrap();
    assert!(!doc.chat("chat").unwrap().unwrap().archived);
    doc.archive_chat_at("chat", sent_at + 1).unwrap();
    assert!(doc.chat("chat").unwrap().unwrap().archived);
    doc.restore_chat_on_send("chat", &clock).unwrap();
    assert!(doc.chat("chat").unwrap().unwrap().archived);
}

#[test]
fn restore_waits_for_metadata_without_fabricating_or_clobbering_a_chat() {
    let mut doc = RegistryDoc::new("sender");
    let clock = doc.chat_prompt_clock("chat");
    assert!(!doc.restore_chat_on_send("chat", &clock).unwrap());
    assert!(doc.chat("chat").unwrap().is_none());
    doc.apply_state(1, true, 0, vec![row(true, encode_hlc(1_000, 0, "remote"))]);
    assert!(doc.restore_chat_on_send("chat", &clock).unwrap());
    let chat = doc.chat("chat").unwrap().unwrap();
    assert!(!chat.archived);
    assert_eq!(chat.device_id, "remote");
    assert_eq!(chat.title.as_deref(), Some("Reference"));
}

#[test]
fn send_fences_an_older_remote_archive_even_when_locally_unarchived() {
    let mut doc = RegistryDoc::new("sender");
    doc.apply_state(1, true, 0, vec![row(false, encode_hlc(1_000, 0, "remote"))]);
    let clock = doc.chat_prompt_clock("chat");
    assert!(doc.restore_chat_on_send("chat", &clock).unwrap());
    assert!(doc.apply_rows(2, vec![row(true, encode_hlc(2_000, 0, "remote"))]));
    assert!(!doc.chat("chat").unwrap().unwrap().archived);
}

#[test]
fn restore_retry_is_idempotent_and_does_not_undo_later_local_or_remote_archives() {
    let mut doc = RegistryDoc::new("sender");
    doc.apply_state(1, true, 0, vec![row(true, encode_hlc(1_000, 0, "remote"))]);
    let clock = doc.chat_prompt_clock("chat");
    doc.restore_chat_on_send("chat", &clock).unwrap();
    let pending = doc.pending_len();
    doc.restore_chat_on_send("chat", &clock).unwrap();
    assert_eq!(doc.pending_len(), pending);
    doc.set_chat_archived("chat", true).unwrap();
    doc.restore_chat_on_send("chat", &clock).unwrap();
    assert!(doc.chat("chat").unwrap().unwrap().archived);

    let mut doc = RegistryDoc::new("sender");
    doc.apply_state(1, true, 0, vec![row(true, encode_hlc(1_000, 0, "remote"))]);
    let clock = doc.chat_prompt_clock("chat");
    let later_ms = clock.split('-').next().unwrap().parse::<i64>().unwrap() + 1_000;
    assert!(doc.apply_rows(2, vec![row(true, encode_hlc(later_ms, 0, "remote"))]));
    doc.restore_chat_on_send("chat", &clock).unwrap();
    assert!(doc.chat("chat").unwrap().unwrap().archived);
}
