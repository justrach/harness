package harness.codegraff.android.model

// Kotlin mirrors of the workspace and session doc rows the desktop and iOS apps
// share (apps/ios/Harness/Models/Entities.swift). Field names match the doc schema;
// the derivations (title, unseen, indicator, ordering) are ports of the same rules.

data class DeviceRow(
    val id: String,
    val name: String,
    val platform: String,
    val lastSeenAt: Long? = null,
    val createdAt: Long? = null,
) {
    /** Phones and tablets are peers, not hosts: only desktops and servers run sessions. */
    val canHostSessions: Boolean get() = platform == "macos" || platform == "linux" || platform == "windows"
}

data class Space(
    val id: String,
    val deviceId: String,
    val path: String,
    val name: String? = null,
    val gitDetected: Boolean = false,
    val createdAt: Long = 0,
) {
    /** Display name: the explicit name, else the folder's basename. */
    val displayName: String
        get() = name?.takeIf { it.isNotEmpty() } ?: path.trimEnd('/').substringAfterLast('/')
}

data class ChatConfig(
    val harness: String,
    val model: String? = null,
    val reasoning: String? = null,
    /** Harness-specific option picks (option id to choice id), round-tripped so a mobile edit never clobbers desktop picks. */
    val modelOptions: Map<String, String> = emptyMap(),
    val sandbox: String? = null,
)

data class Chat(
    val id: String,
    val deviceId: String,
    val title: String? = null,
    val archived: Boolean = false,
    val cwd: String? = null,
    val branch: String? = null,
    val config: ChatConfig? = null,
    val lastMessagePreview: String? = null,
    val lastMessageAt: Long? = null,
    val createdAt: Long,
    val spaceId: String? = null,
    val lastSeenAt: Long? = null,
    /** When a person last prompted this chat (a send or steer). Agent replies move `lastMessageAt`, never this. */
    val lastPromptAt: Long? = null,
) {
    /** Where the chat sits in lists: when you last called it; older hosts fall back to the last message, then creation. */
    val calledAt: Long get() = lastPromptAt ?: lastMessageAt ?: createdAt

    val displayTitle: String get() = title?.takeIf { it.isNotEmpty() } ?: "New session"

    /** entities.rs:123: unseen when a message arrived after the last seen mark. */
    val unseen: Boolean
        get() {
            val last = lastMessageAt ?: return false
            val seen = lastSeenAt ?: return true
            return last > seen
        }
}

enum class SessionStatus { Idle, Working, AwaitingInput, Errored }

data class SessionRow(
    val chatId: String,
    val deviceId: String,
    val status: SessionStatus,
    val startedAt: Long? = null,
    val updatedAt: Long,
)

// ---- pull requests ----

enum class ChangeRequestState(val label: String) { Open("Open"), Closed("Closed"), Merged("Merged") }

data class ChangeRequestSummary(
    val provider: String,
    val number: Long,
    val title: String,
    val url: String,
    val state: ChangeRequestState,
    val baseRef: String,
    val headRef: String,
) {
    val accessibilityLabel: String get() = "Pull request $number, ${state.label}, $title"
}

// ---- derived display status (entities.rs / state.rs ports) ----

/** Ordered by how much attention a session wants: lower rank sorts first. */
enum class ChatIndicator(val rank: Int, val label: String?) {
    AwaitingInput(0, "Input"),
    Errored(1, "Failed"),
    Working(2, "Working"),
    Completed(3, "Done"),
    Idle(4, null),
}

/** state.rs:277: a Working/AwaitingInput row older than this reads as stale (a crashed backend never shows eternal "Working"). */
const val SESSION_STALE_MS = 45_000L

/** workspace_host.rs:45: presence freshness window for device online dots. */
const val PRESENCE_FRESH_MS = 45_000L

fun effectiveStatus(row: SessionRow?, now: Long): SessionStatus? {
    if (row == null) return null
    return when (row.status) {
        SessionStatus.Working, SessionStatus.AwaitingInput ->
            // Negative ages (clock skew) are fresh.
            if (now - row.updatedAt > SESSION_STALE_MS) null else row.status
        SessionStatus.Errored, SessionStatus.Idle -> row.status
    }
}

/** entities.rs:147: live Working/AwaitingInput win; Errored only if unseen; else unseen means Completed; else Idle. */
fun chatIndicator(chat: Chat, live: SessionStatus?): ChatIndicator = when (live) {
    SessionStatus.Working -> ChatIndicator.Working
    SessionStatus.AwaitingInput -> ChatIndicator.AwaitingInput
    SessionStatus.Errored -> if (chat.unseen) ChatIndicator.Errored else ChatIndicator.Idle
    else -> if (chat.unseen) ChatIndicator.Completed else ChatIndicator.Idle
}

/**
 * The Sessions list order: when you last CALLED each session (your last send or steer),
 * newest first, id tiebreak. Status drives the dot, never the position.
 */
fun sortActive(chats: List<Chat>): List<Chat> =
    chats.sortedWith(compareByDescending<Chat> { it.calledAt }.thenBy { it.id })

/** Known pins in their shared manual order, then the automatic recency order for everything else. */
fun sortPinnedFirst(chats: List<Chat>, pinnedSessionIds: List<String>): List<Chat> {
    val recent = sortActive(chats)
    val byId = recent.associateBy { it.id }
    val seen = HashSet<String>()
    val pinned = pinnedSessionIds.mapNotNull { id -> if (seen.add(id)) byId[id] else null }
    return pinned + recent.filter { seen.add(it.id) }
}

/** Compact age for list rows: "now", "5m", "3h", "5d" (relativeTime in HomeView.swift). */
fun relativeTime(thenMs: Long, nowMs: Long): String {
    val delta = maxOf(0L, nowMs - thenMs) / 1000
    return when {
        delta < 60 -> "now"
        delta < 3_600 -> "${delta / 60}m"
        delta < 86_400 -> "${delta / 3_600}h"
        else -> "${delta / 86_400}d"
    }
}

/** Where a new session runs: in a project, or on a host with no project. */
sealed interface NewSessionDestination {
    data class Project(val spaceId: String) : NewSessionDestination
    data class Projectless(val deviceId: String) : NewSessionDestination
}

data class RepoRef(val name: String, val current: Boolean, val worktreePath: String?)

enum class CheckoutKind { Local, NewWorktree }
