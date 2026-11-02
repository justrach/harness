//! Small, deterministic summaries for the session overview. A missing transcript
//! is not an empty plan, and a running task never implies invented progress.

use chrono::{DateTime, Utc};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
use harness_proto::{Chat, ChatIndicator, ToolCall};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct OverviewStep {
    pub text: String,
    pub done: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct OverviewActivity {
    pub title: String,
    pub update: String,
    /// One arrival animation per question/message, not per streamed token.
    pub update_key: Option<String>,
    pub checklist: Vec<OverviewStep>,
    pub completed_steps: usize,
    pub total_steps: usize,
    pub pending_question: bool,
    pub updated_at: Option<DateTime<Utc>>,
    pub age_label: String,
}

pub(super) fn overview_activity(
    chat: &Chat,
    indicator: ChatIndicator,
    entries: &[SessionMessageEntry],
    now: DateTime<Utc>,
) -> OverviewActivity {
    let title = nonempty_line(chat.title.as_deref().unwrap_or(""))
        .unwrap_or_else(|| "New conversation".into());
    let pending = crate::composer::pending_input_request(entries);
    let pending_question = pending.is_some();
    let latest = entries
        .iter()
        .enumerate()
        .rev()
        .find(|(_, entry)| entry.role == MessageRole::Assistant);
    // A newly sent prompt can briefly precede its assistant row. Do not show
    // the previous turn's completed plan as progress on the new request.
    // Steers beneath an unanswered question are deliberately different: the
    // native composer keeps that same question available until it is resolved.
    let latest = latest.filter(|(index, entry)| {
        pending_question
            || indicator != ChatIndicator::Working
            || entry.status == Some(MessageStatus::Streaming)
            || !entries[index + 1..]
                .iter()
                .any(|entry| entry.role == MessageRole::User)
    });
    let latest_entry = latest.map(|(_, entry)| entry);
    let update_key = pending
        .as_ref()
        .map(|(id, _)| format!("question:{id}"))
        .or_else(|| latest_entry.map(|entry| format!("message:{}", entry.id)));
    let turn_start = entries
        .iter()
        .rposition(|entry| entry.role == MessageRole::User)
        .map_or(0, |index| index + 1);
    let checklist: Vec<OverviewStep> = entries[turn_start..]
        .iter()
        .rev()
        .filter(|entry| entry.role == MessageRole::Assistant)
        .flat_map(|entry| entry.parts.iter().rev())
        .find_map(|part| match part {
            MessagePart::Tool {
                call: ToolCall::Todo { items },
                ..
            } => Some(items),
            _ => None,
        })
        .into_iter()
        .flatten()
        .filter_map(|item| {
            nonempty_line(&item.text).map(|text| OverviewStep {
                text,
                done: item.done,
            })
        })
        .collect();
    let completed_steps = checklist.iter().filter(|step| step.done).count();
    let total_steps = checklist.len();
    let question = pending.and_then(|(_, questions)| {
        questions.into_iter().find_map(|question| {
            nonempty_line(&question.question).or_else(|| nonempty_line(&question.header))
        })
    });
    let assistant_update = latest_entry.and_then(|entry| {
        entry.parts.iter().rev().find_map(|part| match part {
            MessagePart::Text { text, .. } => readable_update(text),
            MessagePart::Error { message, .. } => nonempty_line(message),
            // Reasoning and tool output do not belong on a monitoring card.
            _ => None,
        })
    });
    let update = question
        .or(assistant_update)
        .unwrap_or_else(|| match indicator {
            ChatIndicator::Working => "Working on this task.".into(),
            ChatIndicator::AwaitingInput => "Waiting for your input.".into(),
            ChatIndicator::Errored => "The last run stopped with an error.".into(),
            ChatIndicator::Completed | ChatIndicator::Idle => chat
                .last_message_preview
                .as_deref()
                .and_then(readable_update)
                .unwrap_or_else(|| {
                    if chat.last_message_at.is_none() && entries.is_empty() {
                        "No activity yet.".into()
                    } else if indicator == ChatIndicator::Completed {
                        "Ready to review.".into()
                    } else {
                        "Ready to continue.".into()
                    }
                }),
        });
    let entry_time = latest_entry.and_then(|entry| {
        DateTime::from_timestamp_millis(
            entry
                .created_at
                .saturating_add(entry.duration_ms.unwrap_or_default().max(0)),
        )
    });
    let updated_at = chat.last_message_at.max(entry_time);
    OverviewActivity {
        title,
        update,
        update_key,
        checklist,
        completed_steps,
        total_steps,
        pending_question,
        updated_at,
        age_label: age_label(updated_at, now),
    }
}

fn nonempty_line(text: &str) -> Option<String> {
    let text = harness_proto::view::single_line(text);
    (!text.is_empty()).then_some(text)
}

/// Keep the most recent prose paragraph, rather than a streamed response's old
/// opening sentence or the contents of its last code block. This is a preview,
/// not a Markdown renderer; the full message remains in the conversation.
fn readable_update(text: &str) -> Option<String> {
    let mut latest = None;
    let mut paragraph = String::new();
    let mut fence: Option<char> = None;
    for line in text.lines() {
        let line = line.trim();
        let marker = if line.starts_with("```") {
            Some('`')
        } else if line.starts_with("~~~") {
            Some('~')
        } else {
            None
        };
        if let Some(marker) = marker {
            if fence == Some(marker) {
                fence = None;
            } else if fence.is_none() {
                if let Some(value) = nonempty_line(&paragraph) {
                    latest = Some(value);
                    paragraph.clear();
                }
                fence = Some(marker);
            }
            continue;
        }
        if fence.is_some() {
            continue;
        }
        if line.is_empty() {
            if let Some(value) = nonempty_line(&paragraph) {
                latest = Some(value);
                paragraph.clear();
            }
            continue;
        }
        if !paragraph.is_empty() {
            paragraph.push(' ');
        }
        paragraph.push_str(line.trim_start_matches('#').trim_start());
    }
    nonempty_line(&paragraph).or(latest).map(|text| {
        let mut chars = text.chars();
        let mut preview: String = chars.by_ref().take(320).collect();
        if chars.next().is_some() {
            preview.push('…');
        }
        preview
    })
}

fn age_label(updated_at: Option<DateTime<Utc>>, now: DateTime<Utc>) -> String {
    let Some(updated_at) = updated_at else {
        return "No activity yet".into();
    };
    let seconds = now.signed_duration_since(updated_at).num_seconds().max(0);
    let age = if seconds < 60 {
        return "Updated just now".into();
    } else if seconds < 3600 {
        format!("{}m", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h", seconds / 3600)
    } else {
        format!("{}d", seconds / 86_400)
    };
    format!("Updated {age} ago")
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeDelta;
    use harness_proto::{TodoItem, UserInputQuestion};

    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-10-26T12:00:00Z")
            .unwrap()
            .to_utc()
    }

    fn chat() -> Chat {
        serde_json::from_value(serde_json::json!({
            "id": "overview-test", "deviceId": "synthetic", "title": "Fix CSV exports",
            "archived": false, "createdAt": "2026-10-26T10:00:00Z"
        }))
        .unwrap()
    }

    fn assistant(parts: Vec<MessagePart>) -> SessionMessageEntry {
        SessionMessageEntry {
            id: "assistant".into(),
            role: MessageRole::Assistant,
            parts,
            created_at: (now() - TimeDelta::minutes(2)).timestamp_millis(),
            device_id: "synthetic".into(),
            status: Some(MessageStatus::Streaming),
            continuation_of: None,
            duration_ms: None,
        }
    }

    fn text(value: &str) -> MessagePart {
        MessagePart::Text {
            id: "text".into(),
            text: value.into(),
        }
    }

    fn todo(items: &[(&str, bool)]) -> MessagePart {
        serde_json::from_value(serde_json::json!({
            "kind": "tool", "id": "todo", "call": {
                "kind": "todo", "items": items.iter().map(|(text,done)| TodoItem {
                    text: (*text).into(), done: *done
                }).collect::<Vec<_>>()
            }
        }))
        .unwrap()
    }

    fn input() -> MessagePart {
        MessagePart::Input {
            id: "input".into(),
            request_id: "question".into(),
            questions: vec![UserInputQuestion {
                id: "format".into(),
                header: "Date format".into(),
                question: "How should dates be exported?".into(),
                options: vec!["ISO".into(), "Original".into()],
                multi_select: false,
                prefill: None,
                multiline: false,
            }],
            resolved: false,
        }
    }

    #[test]
    fn overview_data_uses_latest_plan_without_inventing_step_progress() {
        let entries = [assistant(vec![
            todo(&[("Old plan", false)]),
            text("Preparing the fix."),
            todo(&[
                ("Reproduce issue", true),
                ("Prepare fix", true),
                ("Choose format", false),
            ]),
        ])];
        let activity = overview_activity(&chat(), ChatIndicator::Working, &entries, now());
        assert_eq!(activity.total_steps, 3);
        assert_eq!(activity.completed_steps, 2);
        assert_eq!(activity.checklist[2].text, "Choose format");
        assert!(!activity.checklist[2].done);
        assert_eq!(activity.update, "Preparing the fix.");
    }

    #[test]
    fn overview_data_empty_plan_clears_older_steps() {
        let entries = [assistant(vec![todo(&[("Old step", false)]), todo(&[])])];
        let activity = overview_activity(&chat(), ChatIndicator::Working, &entries, now());
        assert!(activity.checklist.is_empty());
        assert_eq!(activity.total_steps, 0);
    }

    #[test]
    fn overview_data_plan_survives_a_later_assistant_status_in_the_same_turn() {
        let entries = [
            assistant(vec![todo(&[("Inspect", true), ("Verify", false)])]),
            assistant(vec![text("Checking the final result.")]),
        ];
        let activity = overview_activity(&chat(), ChatIndicator::Working, &entries, now());
        assert_eq!(activity.total_steps, 2);
        assert_eq!(activity.completed_steps, 1);
        assert_eq!(activity.update, "Checking the final result.");
        let cleared = [entries[0].clone(), assistant(vec![todo(&[])])];
        assert!(
            overview_activity(&chat(), ChatIndicator::Working, &cleared, now())
                .checklist
                .is_empty()
        );
    }

    #[test]
    fn overview_data_question_matches_native_composer_after_a_steer() {
        let mut question = assistant(vec![text("Working."), input()]);
        question.status = Some(MessageStatus::Aborted);
        let mut steer = assistant(vec![text("Keep going when I answer.")]);
        steer.role = MessageRole::User;
        let entries = [question, steer];
        let activity = overview_activity(&chat(), ChatIndicator::Idle, &entries, now());
        assert!(activity.pending_question);
        assert_eq!(activity.update, "How should dates be exported?");
        let newer = [entries[0].clone(), assistant(vec![text("Work resumed.")])];
        assert!(
            !overview_activity(&chat(), ChatIndicator::Working, &newer, now()).pending_question
        );
    }

    #[test]
    fn overview_data_does_not_reuse_old_plan_for_a_new_turn() {
        let mut completed = assistant(vec![
            text("Previous task finished."),
            todo(&[("Old step", true)]),
        ]);
        completed.status = Some(MessageStatus::Complete);
        let mut new_prompt = assistant(vec![text("Start the next task.")]);
        new_prompt.role = MessageRole::User;
        let entries = [completed, new_prompt];
        let mut row = chat();
        row.last_message_preview = Some("Start the next task.".into());
        let activity = overview_activity(&row, ChatIndicator::Working, &entries, now());
        assert!(activity.checklist.is_empty());
        assert_eq!(activity.update, "Working on this task.");
    }

    #[test]
    fn overview_data_skips_reasoning_tool_output_and_code() {
        let entries = [assistant(vec![
            text(
                "An old paragraph.\n\nChecking keyboard navigation.\n\n```rust\nsecret_code();\n```",
            ),
            MessagePart::Reasoning {
                id: "reasoning".into(),
                text: "Hidden reasoning".into(),
            },
        ])];
        let activity = overview_activity(&chat(), ChatIndicator::Working, &entries, now());
        assert_eq!(activity.update, "Checking keyboard navigation.");
        assert_eq!(readable_update("```\nonly code\n```"), None);
        assert_eq!(
            readable_update(&"界".repeat(400)).unwrap().chars().count(),
            321
        );
    }

    #[test]
    fn overview_data_missing_transcript_has_no_fabricated_plan_or_question() {
        let activity = overview_activity(&chat(), ChatIndicator::AwaitingInput, &[], now());
        assert!(!activity.pending_question);
        assert!(activity.checklist.is_empty());
        assert_eq!(activity.update, "Waiting for your input.");
        assert_eq!(activity.age_label, "No activity yet");
    }

    #[test]
    fn overview_data_ages_use_message_updates_and_tolerate_clock_skew() {
        let mut row = chat();
        row.last_message_at = Some(now() - TimeDelta::seconds(65));
        let activity = overview_activity(&row, ChatIndicator::Idle, &[], now());
        assert_eq!(activity.age_label, "Updated 1m ago");
        assert_eq!(
            age_label(Some(now() + TimeDelta::minutes(5)), now()),
            "Updated just now"
        );
    }

    #[test]
    fn overview_data_arrival_identity_survives_streaming_appends() {
        let first = overview_activity(
            &chat(),
            ChatIndicator::Working,
            &[assistant(vec![text("Checking")])],
            now(),
        );
        let appended = overview_activity(
            &chat(),
            ChatIndicator::Working,
            &[assistant(vec![text("Checking the final result.")])],
            now(),
        );
        assert_eq!(first.update_key, appended.update_key);
        assert_ne!(first.update, appended.update);
        let question = overview_activity(
            &chat(),
            ChatIndicator::AwaitingInput,
            &[assistant(vec![input()])],
            now(),
        );
        assert_eq!(question.update_key.as_deref(), Some("question:question"));
        assert_ne!(question.update_key, appended.update_key);
    }
}
