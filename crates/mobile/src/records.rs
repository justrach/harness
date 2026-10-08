//! The values that cross to Kotlin. Plain records: the app maps them onto its own model types, so nothing here
//! holds a lock or a handle.

use std::collections::HashMap;

/// A computer (or phone) in the workspace registry (`devices` rows).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeviceRecord {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub last_seen_at: Option<i64>,
    pub created_at: Option<i64>,
    pub version: Option<String>,
    pub capabilities: Vec<String>,
}

/// A project folder on one computer (`spaces` rows).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SpaceRecord {
    pub id: String,
    pub device_id: String,
    pub path: String,
    pub name: Option<String>,
    pub git_detected: bool,
    pub git_checked_at: Option<i64>,
    pub checkout_id: Option<String>,
    pub created_at: i64,
}

/// The agent picks a chat runs with (the `config` field of a chat row).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatConfigRecord {
    pub harness: String,
    pub model: Option<String>,
    pub reasoning: Option<String>,
    /// Option id to choice id. Values that are not strings stay in the row and are not shown here.
    pub model_options: HashMap<String, String>,
    pub sandbox: Option<String>,
}

/// A session (`chats` rows).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ChatRecord {
    pub id: String,
    pub device_id: String,
    pub title: Option<String>,
    pub archived: bool,
    pub cwd: Option<String>,
    pub branch: Option<String>,
    pub checkout_id: Option<String>,
    pub config: Option<ChatConfigRecord>,
    pub last_message_preview: Option<String>,
    pub last_message_at: Option<i64>,
    pub created_at: i64,
    pub space_id: Option<String>,
    pub last_seen_at: Option<i64>,
    pub room_gen: Option<i64>,
    pub last_prompt_at: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SessionStatusRecord {
    Idle,
    Working,
    AwaitingInput,
    Errored,
}

impl SessionStatusRecord {
    pub(crate) fn parse(raw: &str) -> Option<Self> {
        match raw {
            "idle" => Some(Self::Idle),
            "working" => Some(Self::Working),
            "awaitingInput" => Some(Self::AwaitingInput),
            "errored" => Some(Self::Errored),
            _ => None,
        }
    }
}

/// A chat's live run status (`sessions` rows, keyed by chat id).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionRowRecord {
    pub chat_id: String,
    pub device_id: String,
    pub status: SessionStatusRecord,
    pub started_at: Option<i64>,
    pub updated_at: i64,
}

/// The desktop's appearance choice (`preferences/appearance`). Phones follow it and never write their own.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DesktopAppearanceRecord {
    pub mode: String,
    pub light: String,
    pub dark: String,
}

/// Everything the workspace registry says, projected the way the iOS `WorkspaceStore` projects it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct WorkspaceSnapshot {
    pub devices: Vec<DeviceRecord>,
    pub spaces: Vec<SpaceRecord>,
    pub chats: Vec<ChatRecord>,
    pub sessions: Vec<SessionRowRecord>,
    /// Pinned session ids in their shared order; empty until `pins_initialized`.
    pub pinned_session_ids: Vec<String>,
    pub pins_initialized: bool,
    pub desktop_appearance: Option<DesktopAppearanceRecord>,
    /// Device id to the epoch ms of its last presence beat heard this session.
    pub presence: HashMap<String, i64>,
    /// The registry socket is joined.
    pub connected: bool,
    /// Server state has reached this session over any transport (socket or HTTPS pull).
    pub synced: bool,
}

// ── session docs ────────────────────────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MessageRoleRecord {
    User,
    Assistant,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MessageStatusRecord {
    Streaming,
    Complete,
    Aborted,
}

/// One value of a tool call's map, kept as the doc has it.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ToolFieldRecord {
    Text {
        value: String,
    },
    Flag {
        value: bool,
    },
    Number {
        value: i64,
    },
    /// A todo list (`todo` calls' `items`).
    Tasks {
        items: Vec<TaskItemRecord>,
    },
    /// Any other list, each item as compact JSON (`applyPatch` changes).
    Items {
        items: Vec<String>,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TaskItemRecord {
    pub text: String,
    pub done: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct UserInputQuestionRecord {
    pub id: String,
    pub header: String,
    pub question: String,
    pub options: Vec<String>,
    pub multi_select: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum MessagePartRecord {
    Text {
        id: String,
        text: String,
    },
    /// An image the agent produced, stored on the host.
    Image {
        id: String,
        path: String,
        name: String,
        mime_type: String,
    },
    Tool {
        id: String,
        tag: String,
        fields: HashMap<String, ToolFieldRecord>,
        is_error: bool,
        resolved: bool,
    },
    Input {
        id: String,
        request_id: String,
        questions: Vec<UserInputQuestionRecord>,
        resolved: bool,
    },
    Error {
        id: String,
        message: String,
        /// The agent whose sign-in ran out (`reauth`), when that is the error.
        reauth: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MessageEntryRecord {
    pub id: String,
    pub role: MessageRoleRecord,
    pub parts: Vec<MessagePartRecord>,
    pub created_at: i64,
    pub device_id: String,
    pub status: Option<MessageStatusRecord>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum QueueDeliveryGateRecord {
    Editing {
        owner_device_id: String,
        expires_at_ms: i64,
    },
    ReviewRequired {
        owner_device_id: String,
    },
}

/// One message waiting on the chat's queue (`queue` movable list).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QueuedMessageRecord {
    pub id: String,
    pub text: String,
    pub attachments: Vec<String>,
    pub issued_by: String,
    pub issued_at: i64,
    pub edited_at: Option<i64>,
    pub hold_for_turn_end: bool,
    pub delivery_gate: Option<QueueDeliveryGateRecord>,
}

/// A chat's transcript and queue as the doc has them, plus its room's state.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SessionSnapshot {
    pub chat_id: String,
    pub entries: Vec<MessageEntryRecord>,
    pub queue: Vec<QueuedMessageRecord>,
    /// The chat2 room is joined and caught up.
    pub connected: bool,
    /// Epoch ms of the next redial while the room is down.
    pub retry_at_ms: Option<i64>,
    /// The chat is still on the legacy room generation, which the phone does not join (the host migrates it).
    pub waiting_for_migration: bool,
}
