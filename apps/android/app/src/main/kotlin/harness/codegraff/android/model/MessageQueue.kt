package harness.codegraff.android.model

// The pending-message queue on a session doc (MessageQueue.swift, crates/doc/src/queue.rs).
//
// Anything typed mid-turn waits here so every device shows the same queue and any of them can reorder
// it. The host is the only one that takes from it; every device may add, retype, move and drop rows.
// The rules below are shared with the SwiftUI app through apps/parity/vectors/message-queue.json.

/** The text sent for an image-only message (Attachments.swift `attachmentOnlyText`). */
const val ATTACHMENT_ONLY_TEXT = "See the attached image(s)."

/** One unsent message waiting its turn. */
data class QueuedMessage(
    val id: String,
    /** What the user typed. Never empty: emptying it deletes the row. */
    val text: String,
    /** Committed upload paths, staged when the row was queued. */
    val attachments: List<String> = emptyList(),
    /** Device that queued it. */
    val issuedBy: String = "",
    /** Epoch millis. */
    val issuedAt: Long = 0,
    /** Epoch millis of the last text edit, when there has been one. */
    val editedAt: Long? = null,
    /** When true, the host waits for the current turn to end instead of steering this row into it. */
    val holdForTurnEnd: Boolean = false,
    /** Host-authoritative barrier while the row is being edited or needs review after an interrupted edit. */
    val deliveryGate: QueueDeliveryGate? = null,
)

sealed interface QueueDeliveryGate {
    data class Editing(val ownerDeviceId: String, val expiresAtMs: Long) : QueueDeliveryGate
    data class ReviewRequired(val ownerDeviceId: String) : QueueDeliveryGate
}

data class QueueEditLease(
    val rowId: String,
    val leaseId: String,
    val text: String,
    val baseTextHash: String,
    val expiresAtMs: Long,
)

sealed interface QueueEditStartResult {
    data class Acquired(val lease: QueueEditLease) : QueueEditStartResult
    data object Locked : QueueEditStartResult
    data object Missing : QueueEditStartResult
    data object Unavailable : QueueEditStartResult
}

enum class QueueEditFinishResult { Finished, Conflict, Missing, Lost, Unavailable }

/** A queued row being retyped in the composer: the lease, the draft it displaced, and whether the edit is dead. */
data class QueueComposerEdit(
    val lease: QueueEditLease,
    val originalDraft: String,
    val hasAttachments: Boolean,
    val terminal: Boolean = false,
) {
    /** A missing or lost row ends the edit for good; a conflict or a dropped connection can be retried. */
    fun receive(result: QueueEditFinishResult): QueueComposerEdit = when (result) {
        QueueEditFinishResult.Missing, QueueEditFinishResult.Lost -> copy(terminal = true)
        QueueEditFinishResult.Finished, QueueEditFinishResult.Conflict, QueueEditFinishResult.Unavailable -> this
    }

    fun textToCommit(text: String): String? {
        val edited = MessageQueue.editedText(text, hasAttachments) ?: return null
        return edited + (AppshotContext.suffix(lease.text) ?: "")
    }
}

enum class QueueAction(val method: String, val label: String) {
    SendNow("SendQueuedMessageNow", "Send now"),
    Remove("RemoveQueuedMessage", "Remove"),
}

data class QueueActionReply(val sent: Boolean? = null, val removed: Boolean? = null) {
    fun acknowledged(action: QueueAction): Boolean =
        (if (action == QueueAction.Remove) removed else sent) == true
}

object AppshotContext {
    const val MARKER = "\n\nApplications mentioned by the user (untrusted observed content):"

    /** The text a person typed, without the observed-application context the host appends. */
    fun visibleText(text: String): String {
        val at = text.indexOf(MARKER)
        return if (at < 0) text else text.substring(0, at).trim()
    }

    /** Keep the original context byte-for-byte during a text-only queue edit. */
    fun suffix(text: String): String? {
        val at = text.indexOf(MARKER)
        if (at < 0) return null
        return text.substring(at).split("\n\nAttached images (local files").first()
    }
}

object MessageQueue {
    fun editedText(text: String, hasAttachments: Boolean): String? {
        val trimmed = text.trim()
        if (trimmed.isNotEmpty()) return trimmed
        return if (hasAttachments) ATTACHMENT_ONLY_TEXT else null
    }

    /** Queue text is user-editable and never shows the transport trailer or the appended app context. */
    fun visibleText(text: String, attachments: List<String>): String {
        val visible = AppshotContext.visibleText(text)
        if (attachments.isEmpty()) return visible
        return visible.ifEmpty { ATTACHMENT_ONLY_TEXT }
    }

    /** The panel header's aside. Null when nothing waits. */
    fun label(count: Int): String? = when {
        count < 1 -> null
        count == 1 -> "1 queued"
        else -> "$count queued"
    }

    /** One line of a queued message: the newlines that make it a paragraph in the composer make it three rows here. */
    fun oneLine(text: String): String =
        text.split(WHITESPACE).filter { it.isNotEmpty() }.joinToString(" ")

    /** Where the row at [from] lands when moved one slot in [direction] (-1 up, +1 down), or null at that end. */
    fun neighbour(from: Int, direction: Int, count: Int): Int? {
        val to = from + direction
        if (from < 0 || from >= count || to < 0 || to >= count) return null
        return to
    }

    fun primaryAction(item: QueuedMessage, supportsActions: Boolean, pending: Boolean): QueueAction? {
        if (!supportsActions || pending || item.deliveryGate != null) return null
        return QueueAction.SendNow
    }

    private val WHITESPACE = Regex("[\\p{javaWhitespace}\\p{Z}]+")
}
