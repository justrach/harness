//! Pull-request badges: each active, identified checkout is watched on its host (`WatchCheckoutChangeRequest` over
//! the relay), and a chat shows the latest resolution only when its branch and checkout still match it. A port of the
//! iOS `ChangeRequestTracker` and `WorkspaceStore`'s watch loop.

use std::collections::{HashMap, HashSet};

use serde::Deserialize;

use crate::records::{ChatRecord, SpaceRecord};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WatchKey {
    pub device_id: String,
    pub cwd: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
#[serde(rename_all = "camelCase")]
pub struct ChangeRequestRecord {
    pub provider: String,
    pub number: u64,
    pub title: String,
    pub url: String,
    /// "open", "closed" or "merged".
    pub state: String,
    pub base_ref: String,
    pub head_ref: String,
}

/// The host's latest successful resolution for a checkout. No change request is an authoritative "none".
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckoutStatus {
    pub checkout_id: String,
    pub device_id: String,
    pub cwd: String,
    pub branch: String,
    #[serde(default)]
    pub change_request: Option<ChangeRequestRecord>,
}

fn trimmed(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|v| !v.is_empty())
}

fn effective_cwd(chat: &ChatRecord, spaces: &[SpaceRecord]) -> Option<String> {
    if let Some(cwd) = trimmed(chat.cwd.as_deref()) {
        return Some(cwd.to_owned());
    }
    let space_id = chat.space_id.as_deref()?;
    let space = spaces
        .iter()
        .find(|s| s.id == space_id && s.device_id == chat.device_id)?;
    trimmed(Some(&space.path)).map(str::to_owned)
}

/// Active, fully identified checkouts that need a host-side lookup.
pub fn desired_targets(
    chats: &[ChatRecord],
    spaces: &[SpaceRecord],
    unsupported: &HashSet<String>,
) -> HashSet<WatchKey> {
    chats
        .iter()
        .filter(|chat| !chat.archived && !unsupported.contains(&chat.device_id))
        .filter(|chat| trimmed(chat.branch.as_deref()).is_some())
        .filter_map(|chat| {
            Some(WatchKey {
                device_id: chat.device_id.clone(),
                cwd: effective_cwd(chat, spaces)?,
            })
        })
        .collect()
}

/// A chat's badge, never trusting the watch key alone: branch and checkout identity keep a stale PR from flashing
/// after a ref switch.
pub fn resolve(
    chat: &ChatRecord,
    spaces: &[SpaceRecord],
    snapshots: &HashMap<WatchKey, CheckoutStatus>,
) -> Option<ChangeRequestRecord> {
    let branch = trimmed(chat.branch.as_deref())?;
    let cwd = effective_cwd(chat, spaces)?;
    let snapshot = snapshots.get(&WatchKey {
        device_id: chat.device_id.clone(),
        cwd: cwd.clone(),
    })?;
    if snapshot.device_id != chat.device_id || snapshot.cwd != cwd || snapshot.branch != branch {
        return None;
    }
    if let Some(checkout) = &chat.checkout_id
        && (snapshot.checkout_id.is_empty() || &snapshot.checkout_id != checkout)
    {
        return None;
    }
    snapshot.change_request.clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chat(id: &str, branch: Option<&str>, cwd: Option<&str>, space: Option<&str>) -> ChatRecord {
        ChatRecord {
            id: id.into(),
            device_id: "mac".into(),
            title: None,
            archived: false,
            cwd: cwd.map(Into::into),
            branch: branch.map(Into::into),
            checkout_id: None,
            config: None,
            last_message_preview: None,
            last_message_at: None,
            created_at: 0,
            space_id: space.map(Into::into),
            last_seen_at: None,
            room_gen: None,
            last_prompt_at: None,
        }
    }

    fn space() -> SpaceRecord {
        SpaceRecord {
            id: "s".into(),
            device_id: "mac".into(),
            path: " /repo ".into(),
            name: None,
            git_detected: true,
            git_checked_at: None,
            checkout_id: None,
            created_at: 0,
        }
    }

    #[test]
    fn only_identified_active_checkouts_are_watched() {
        let chats = vec![
            chat("a", Some("main"), Some("/a"), None),
            chat("b", Some(" "), Some("/b"), None),
            chat("c", Some("dev"), None, Some("s")),
            chat("d", Some("dev"), None, None),
        ];
        let targets = desired_targets(&chats, &[space()], &HashSet::new());
        let mut cwds: Vec<String> = targets.into_iter().map(|t| t.cwd).collect();
        cwds.sort();
        assert_eq!(cwds, ["/a", "/repo"]);
        assert!(desired_targets(&chats, &[space()], &HashSet::from(["mac".to_owned()])).is_empty());
    }

    #[test]
    fn a_badge_needs_the_same_branch_and_checkout() {
        let pr = ChangeRequestRecord {
            provider: "github".into(),
            number: 7,
            title: "t".into(),
            url: "u".into(),
            state: "open".into(),
            base_ref: "main".into(),
            head_ref: "dev".into(),
        };
        let key = WatchKey {
            device_id: "mac".into(),
            cwd: "/a".into(),
        };
        let status = CheckoutStatus {
            checkout_id: "k1".into(),
            device_id: "mac".into(),
            cwd: "/a".into(),
            branch: "dev".into(),
            change_request: Some(pr.clone()),
        };
        let snapshots = HashMap::from([(key, status)]);
        let mut c = chat("a", Some("dev"), Some("/a"), None);
        assert_eq!(resolve(&c, &[], &snapshots), Some(pr));
        c.checkout_id = Some("k2".into());
        assert_eq!(resolve(&c, &[], &snapshots), None);
        c.checkout_id = None;
        c.branch = Some("other".into());
        assert_eq!(resolve(&c, &[], &snapshots), None);
    }
}
