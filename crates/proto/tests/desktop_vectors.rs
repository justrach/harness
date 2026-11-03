//! Runs `protocol/desktop/rules.json` against harness-proto's view rules.
//! harness-nano runs the same file (`apps/nano/src/parity.zig`), so the
//! desktop shell and the Zig port can't drift apart without a test failing.

use chrono::{DateTime, Utc};
use harness_proto::view::{
    display_status, format_time_ago, sort_active, tool_chip_content, tool_group_summary,
};
use harness_proto::{Chat, ChatIndicator, Session, ToolCall};
use serde_json::Value;

fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../protocol/desktop/rules.json"
    );
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn at(ms: i64) -> DateTime<Utc> {
    DateTime::from_timestamp_millis(ms).unwrap()
}

fn name(case: &Value) -> String {
    case["name"].as_str().unwrap_or("").to_string()
}

#[test]
fn time_ago_reads_as_the_vectors_say() {
    let v = vectors();
    let now = v["nowMs"].as_i64().unwrap();
    for case in v["timeAgo"].as_array().unwrap() {
        let ago = case["agoMs"].as_i64().unwrap();
        assert_eq!(
            format_time_ago(at(now - ago), at(now)),
            case["expect"].as_str().unwrap(),
            "{ago} ms ago"
        );
    }
}

#[test]
fn tool_chips_read_as_the_vectors_say() {
    for case in vectors()["toolChip"].as_array().unwrap() {
        let call: ToolCall = serde_json::from_value(case["call"].clone()).unwrap();
        let (label, detail) = tool_chip_content(&call);
        assert_eq!(
            label,
            case["expect"]["label"].as_str().unwrap(),
            "{}",
            case["call"]
        );
        assert_eq!(
            detail,
            case["expect"]["detail"].as_str().unwrap(),
            "{}",
            case["call"]
        );
    }
}

#[test]
fn tool_group_summaries_read_as_the_vectors_say() {
    for case in vectors()["toolGroupSummary"].as_array().unwrap() {
        let tools: Vec<(ToolCall, bool)> = case["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| {
                let call = serde_json::from_value(t["call"].clone()).unwrap();
                (call, t["isError"].as_bool().unwrap_or(false))
            })
            .collect();
        assert_eq!(tool_group_summary(&tools), case["expect"].as_str().unwrap());
    }
}

#[test]
fn display_status_is_what_the_vectors_say() {
    let v = vectors();
    let now = at(v["nowMs"].as_i64().unwrap());
    for case in v["displayStatus"].as_array().unwrap() {
        let chat: Chat = serde_json::from_value(case["chat"].clone()).unwrap();
        let session: Option<Session> = serde_json::from_value(case["session"].clone()).unwrap();
        let got = display_status(&chat, session.as_ref(), now);
        let want: ChatIndicator = serde_json::from_value(case["expect"].clone()).unwrap();
        assert_eq!(got, want, "{}", name(case));
    }
}

#[test]
fn the_sidebar_orders_as_the_vectors_say() {
    for case in vectors()["sortActive"].as_array().unwrap() {
        let chats: Vec<Chat> = serde_json::from_value(case["chats"].clone()).unwrap();
        let mut rows: Vec<(ChatIndicator, &Chat)> =
            chats.iter().map(|c| (ChatIndicator::Idle, c)).collect();
        sort_active(&mut rows);
        let got: Vec<&str> = rows.iter().map(|(_, c)| c.id.as_str()).collect();
        let want: Vec<&str> = case["expect"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap())
            .collect();
        assert_eq!(got, want, "{}", name(case));
    }
}
