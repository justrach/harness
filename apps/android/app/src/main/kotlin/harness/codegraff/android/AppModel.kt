package harness.codegraff.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.Attention
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.SessionRow
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.TranscriptRow
import harness.codegraff.android.model.attention
import harness.codegraff.android.model.sortedByCalledAt
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class AppState(
    val dataset: DemoDataset,
    val chats: List<Chat>,
    val sessions: Map<String, SessionRow>,
    val transcripts: Map<String, List<TranscriptRow>>,
    val now: Long,
) {
    val active: List<Chat> get() = chats.filter { !it.archived }.sortedByCalledAt()
    val archived: List<Chat> get() = chats.filter { it.archived }.sortedByCalledAt()

    fun chat(id: String): Chat? = chats.firstOrNull { it.id == id }

    fun transcript(chatId: String): List<TranscriptRow> = transcripts[chatId].orEmpty()

    fun attention(chat: Chat): Attention = chat.attention(sessions[chat.id]?.status)

    val needsYouCount: Int get() = active.count { attention(it) == Attention.NeedsYou }
    val runningCount: Int get() = active.count { attention(it) == Attention.Running }
}

/**
 * Screen state for the app. Today it drives the offline demo dataset, the same
 * starting point as the iOS `-demo` mode; the live sync client will replace
 * `DemoDataset` behind the same `AppState`. Which session is open is UI state
 * (the adaptive list-detail navigator), not model state.
 */
class AppModel(
    private val clock: () -> Long = System::currentTimeMillis,
    private val tickMs: Long = 35L,
) : ViewModel() {
    private val _state: MutableStateFlow<AppState>
    val state: StateFlow<AppState> get() = _state

    private var streamJob: Job? = null

    init {
        val now = clock()
        val dataset = DemoDataset.standard(now)
        _state = MutableStateFlow(
            AppState(
                dataset = dataset,
                chats = dataset.chats,
                sessions = dataset.sessions,
                transcripts = dataset.chats.associate { it.id to dataset.transcript(it.id) },
                now = now,
            ),
        )
    }

    /** Opening a session marks it seen, which clears its "needs you" state. */
    fun markSeen(chatId: String) {
        _state.update { s ->
            s.copy(
                chats = s.chats.map { if (it.id == chatId) it.copy(lastSeenAt = clock()) else it },
                now = clock(),
            )
        }
    }

    /** Appends the user's message, then streams the scripted reply into a live row. */
    fun send(chatId: String, text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        streamJob?.cancel()
        val at = clock()
        val userId = "u-$at"
        val replyId = "a-$at"
        _state.update { s ->
            s.copy(
                transcripts = s.transcripts + (chatId to s.transcript(chatId) +
                    TranscriptRow.User(userId, trimmed) +
                    TranscriptRow.Assistant(replyId, "", live = true)),
                chats = s.chats.map {
                    if (it.id == chatId) {
                        it.copy(lastPromptAt = at, lastMessageAt = at, lastSeenAt = at, lastMessagePreview = trimmed)
                    } else {
                        it
                    }
                },
                sessions = s.sessions + (chatId to SessionRow(chatId, s.chats.first { it.id == chatId }.deviceId, SessionStatus.Working, at)),
                now = at,
            )
        }
        streamJob = viewModelScope.launch {
            var shown = ""
            for (token in Regex("""\S+\s*""").findAll(DemoDataset.STREAM_REPLY).map { it.value }) {
                shown += token
                delay(tickMs)
                setReply(chatId, replyId, shown, live = true)
            }
            setReply(chatId, replyId, shown, live = false)
            _state.update { s -> s.copy(sessions = s.sessions - chatId, now = clock()) }
        }
    }

    private fun setReply(chatId: String, replyId: String, text: String, live: Boolean) {
        _state.update { s ->
            s.copy(
                transcripts = s.transcripts + (chatId to s.transcript(chatId).map {
                    if (it.id == replyId) TranscriptRow.Assistant(replyId, text, live) else it
                }),
                now = clock(),
            )
        }
    }
}
