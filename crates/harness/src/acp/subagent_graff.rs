//! Draft ACP subagent sessions exposed by Graff.
//!
//! The parent announces a child with `subagent_update`; later ordinary ACP
//! updates carry the child's session ID. Harness keeps its existing subagent
//! document model by creating one parent Agent chip for each announcement and
//! routing child updates to that chip. A child ID is never used as a user-facing
//! session to prompt or resume.

use std::collections::{HashMap, HashSet};

use harness_proto::{AgentEvent, DoneStatus, ToolCall};
use serde_json::{Value, json};

use super::normalize::map_update;

#[derive(Default)]
pub(crate) struct GraffTracker {
    parent_session: String,
    children: HashMap<String, Child>,
    settled: HashSet<String>,
}

struct Child {
    parent: String,
    chip_id: String,
    name: String,
    task: String,
}

impl GraffTracker {
    pub(crate) fn new(parent_session: String) -> Self {
        Self {
            parent_session,
            ..Self::default()
        }
    }

    pub(crate) fn map(&mut self, session: Option<&str>, update: &Value) -> Vec<AgentEvent> {
        let Some(session) = session else {
            return Vec::new();
        };
        if update.get("sessionUpdate").and_then(Value::as_str) != Some("subagent_update") {
            if session == self.parent_session {
                return map_update(update);
            }
            let Some(child) = self.children.get(session) else {
                return Vec::new();
            };
            if self.settled.contains(session) {
                return Vec::new();
            }
            return self.wrap(&child.parent, &child.chip_id, map_update(update));
        }

        let Some(id) = update
            .get("subagentSessionId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        else {
            return Vec::new();
        };
        if id == self.parent_session || self.settled.contains(id)
            || session != self.parent_session && !self.children.contains_key(session)
        {
            return Vec::new();
        }
        let first = !self.children.contains_key(id);
        let correlated_chip = update
            .get("_meta")
            .and_then(|meta| meta.get("graff/parentToolCallId"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty());
        let child = self.children.entry(id.to_owned()).or_insert_with(|| Child {
            parent: session.to_owned(),
            chip_id: correlated_chip
                .map(str::to_owned)
                .unwrap_or_else(|| format!("acp-subagent:{id}")),
            name: String::new(),
            task: String::new(),
        });
        if child.parent != session {
            return Vec::new();
        }
        let mut changed = first;
        if let Some(name) = update.get("name").and_then(Value::as_str) {
            changed |= child.name != name;
            child.name = name.to_owned();
        }
        if let Some(task) = update.get("task").and_then(Value::as_str) {
            changed |= child.task != task;
            child.task = task.to_owned();
        }
        let parent = child.parent.clone();
        let chip_id = child.chip_id.clone();
        let task = child.task.clone();
        let title = if !task.is_empty() {
            task.clone()
        } else if !child.name.is_empty() {
            child.name.clone()
        } else {
            "Subagent".into()
        };
        let mut events = Vec::new();
        if changed {
            let call = AgentEvent::ToolCall {
                id: chip_id.clone(),
                call: ToolCall::Unknown {
                    name: format!("Agent: {title}"),
                    input: Some(json!({ "name": child.name, "task": task })),
                },
            };
            if parent == self.parent_session {
                events.push(call);
            } else if let Some(owner) = self.children.get(&parent) {
                events.push(AgentEvent::Subagent {
                    parent_tool_use_id: owner.chip_id.clone(),
                    event: Box::new(call),
                });
            }
        }
        if first {
            let opening = if task.is_empty() { title } else { task };
            events.extend(self.wrap(
                &parent,
                &chip_id,
                vec![AgentEvent::UserMessage { text: opening }],
            ));
        }
        let status = match update.get("state").and_then(Value::as_str) {
            Some("completed") => Some(DoneStatus::Completed),
            Some("failed") => Some(DoneStatus::Errored),
            Some("cancelled") => Some(DoneStatus::Cancelled),
            Some("disconnected") => Some(DoneStatus::Disconnected),
            _ => None,
        };
        if let Some(status) = status {
            self.settled.insert(id.to_owned());
            events.extend(self.wrap(
                &parent,
                &chip_id,
                vec![AgentEvent::Done {
                    status,
                    result: None,
                    error: None,
                    session_id: None,
                }],
            ));
        }
        events
    }

    pub(crate) fn finish_open(&mut self, _status: DoneStatus) -> Vec<AgentEvent> {
        let open: Vec<(String, String, String)> = self
            .children
            .iter()
            .filter(|(id, _)| !self.settled.contains(*id))
            .map(|(id, child)| (id.clone(), child.parent.clone(), child.chip_id.clone()))
            .collect();
        let mut events = Vec::new();
        for (id, parent, chip_id) in open {
            self.settled.insert(id);
            events.extend(self.wrap(
                &parent,
                &chip_id,
                vec![AgentEvent::Done {
                    // The parent ending without a child terminal update says
                    // nothing about the child's task outcome.
                    status: DoneStatus::Disconnected,
                    result: None,
                    error: None,
                    session_id: None,
                }],
            ));
        }
        events
    }

    fn wrap(&self, parent: &str, chip_id: &str, events: Vec<AgentEvent>) -> Vec<AgentEvent> {
        events
            .into_iter()
            .map(|event| {
                let event = AgentEvent::Subagent {
                    parent_tool_use_id: chip_id.to_owned(),
                    event: Box::new(event),
                };
                if parent == self.parent_session {
                    event
                } else if let Some(owner) = self.children.get(parent) {
                    AgentEvent::Subagent {
                        parent_tool_use_id: owner.chip_id.clone(),
                        event: Box::new(event),
                    }
                } else {
                    event
                }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use harness_proto::{AgentEvent, DoneStatus, ToolCall};
    use serde_json::json;

    use super::GraffTracker;

    #[test]
    fn announces_routes_and_settles_two_interleaved_children() {
        let mut tracker = GraffTracker::new("parent".into());
        for id in ["child-a", "child-b"] {
            let events = tracker.map(
                Some("parent"),
                &json!({
                    "sessionUpdate": "subagent_update", "subagentSessionId": id,
                    "name": "Explore", "task": format!("Inspect {id}")
                }),
            );
            assert!(
                matches!(&events[0], AgentEvent::ToolCall { id: chip, call: ToolCall::Unknown { name, .. } }
                if chip == &format!("acp-subagent:{id}") && name == &format!("Agent: Inspect {id}"))
            );
            assert!(
                matches!(&events[1], AgentEvent::Subagent { parent_tool_use_id, event }
                if parent_tool_use_id == &format!("acp-subagent:{id}") && matches!(event.as_ref(), AgentEvent::UserMessage { .. }))
            );
        }
        let child = tracker.map(Some("child-b"), &json!({
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Found it"}
        }));
        assert!(
            matches!(&child[..], [AgentEvent::Subagent { parent_tool_use_id, event }]
            if parent_tool_use_id == "acp-subagent:child-b"
                && matches!(event.as_ref(), AgentEvent::TextDelta { text } if text == "Found it"))
        );
        let done = tracker.map(Some("parent"), &json!({
            "sessionUpdate": "subagent_update", "subagentSessionId": "child-b", "state": "completed"
        }));
        assert!(matches!(&done[..], [AgentEvent::Subagent { event, .. }]
            if matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Completed, .. })));
        assert!(tracker.map(Some("child-b"), &json!({
            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Late"}
        })).is_empty());
        let unfinished = tracker.finish_open(DoneStatus::Interrupted);
        assert_eq!(unfinished.len(), 1);
        assert!(
            matches!(&unfinished[0], AgentEvent::Subagent { parent_tool_use_id, .. }
            if parent_tool_use_id == "acp-subagent:child-a")
        );
        assert!(matches!(&unfinished[0], AgentEvent::Subagent { event, .. }
            if matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Disconnected, .. })));
    }

    #[test]
    fn correlated_spawn_uses_parent_tool_id_and_preserves_terminal_outcomes() {
        let mut tracker = GraffTracker::new("parent".into());
        assert!(tracker.map(Some("parent"), &json!({
            "sessionUpdate": "subagent_update", "subagentSessionId": "parent"
        })).is_empty());
        let spawn = tracker.map(
            Some("parent"),
            &json!({
                "sessionUpdate": "subagent_update", "subagentSessionId": "child",
                "task": "Inspect tests", "_meta": {"graff/parentToolCallId": "call-9"}
            }),
        );
        assert!(matches!(&spawn[0], AgentEvent::ToolCall { id, .. } if id == "call-9"));
        assert!(
            matches!(&spawn[1], AgentEvent::Subagent { parent_tool_use_id, .. }
            if parent_tool_use_id == "call-9")
        );
        let cancelled = tracker.map(Some("parent"), &json!({
            "sessionUpdate": "subagent_update", "subagentSessionId": "child", "state": "cancelled"
        }));
        assert!(
            matches!(&cancelled[..], [AgentEvent::Subagent { parent_tool_use_id, event }]
            if parent_tool_use_id == "call-9"
                && matches!(event.as_ref(), AgentEvent::Done { status: DoneStatus::Cancelled, .. }))
        );
        assert!(tracker.map(Some("parent"), &json!({
            "sessionUpdate": "subagent_update", "subagentSessionId": "child", "state": "failed"
        })).is_empty());
    }
}
