package harness.codegraff.android.model

// Kotlin mirrors of the workspace and session doc rows the desktop and iOS apps
// share (apps/ios/Harness/Models/Entities.swift). Field names match the doc
// schema; the derivations (title, unseen, calledAt) are ports of the same rules.

data class DeviceRow(
    val id: String,
    val name: String,
    val platform: String,
    val lastSeenAt: Long? = null,
)

data class Space(
    val id: String,
    val deviceId: String,
    val path: String,
    val name: String? = null,
) {
    /** Display name: the explicit name, else the folder's basename. */
    val displayName: String
        get() = name?.takeIf { it.isNotEmpty() } ?: path.trimEnd('/').substringAfterLast('/')
}

data class ChatConfig(
    val harness: String,
    val model: String? = null,
    val reasoning: String? = null,
    val sandbox: String? = null,
)

data class Chat(
    val id: String,
    val deviceId: String,
    val title: String? = null,
    val archived: Boolean = false,
    val branch: String? = null,
    val config: ChatConfig? = null,
    val lastMessagePreview: String? = null,
    val lastMessageAt: Long? = null,
    val createdAt: Long,
    val spaceId: String? = null,
    val lastSeenAt: Long? = null,
    val lastPromptAt: Long? = null,
) {
    /** Where the chat sits in lists: when you last called it, else last message, else creation. */
    val calledAt: Long get() = lastPromptAt ?: lastMessageAt ?: createdAt

    val displayTitle: String get() = title?.takeIf { it.isNotEmpty() } ?: "New session"

    /** Unseen when a message arrived after the last seen mark. */
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
    val updatedAt: Long,
)

/** Newest-called first; the order Home lists active sessions in. */
fun List<Chat>.sortedByCalledAt(): List<Chat> = sortedByDescending { it.calledAt }

/** Compact age for list rows: "now", "40s", "2m", "3h", "5d". */
fun compactAge(thenMs: Long, nowMs: Long): String {
    val seconds = ((nowMs - thenMs) / 1000).coerceAtLeast(0)
    return when {
        seconds < 5 -> "now"
        seconds < 60 -> "${seconds}s"
        seconds < 3_600 -> "${seconds / 60}m"
        seconds < 86_400 -> "${seconds / 3_600}h"
        else -> "${seconds / 86_400}d"
    }
}
