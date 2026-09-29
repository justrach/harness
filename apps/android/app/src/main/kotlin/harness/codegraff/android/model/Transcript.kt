package harness.codegraff.android.model

/** One row of a session transcript. */
sealed interface TranscriptRow {
    val id: String

    data class User(override val id: String, val text: String) : TranscriptRow

    data class Assistant(
        override val id: String,
        val text: String,
        /** True while the reply is still streaming in. */
        val live: Boolean = false,
    ) : TranscriptRow

    data class ToolGroup(
        override val id: String,
        val summary: String,
        val calls: List<ToolCall>,
    ) : TranscriptRow
}

data class ToolCall(val kind: ToolKind, val label: String, val detail: String, val failed: Boolean = false)

enum class ToolKind { Search, Run, Edit, Read }
