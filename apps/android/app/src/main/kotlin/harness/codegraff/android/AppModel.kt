package harness.codegraff.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.ChangeRequestSummary
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.DeviceRow
import harness.codegraff.android.model.HomeFilterNames
import harness.codegraff.android.model.MessageEntry
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.MessageRole
import harness.codegraff.android.model.MessageStatus
import harness.codegraff.android.model.PRESENCE_FRESH_MS
import harness.codegraff.android.model.SessionRow
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.Space
import harness.codegraff.android.model.UserInputAnswer
import harness.codegraff.android.model.chatIndicator
import harness.codegraff.android.model.effectiveStatus
import harness.codegraff.android.model.sortActive
import harness.codegraff.android.model.sortPinnedFirst
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.random.Random

/** Everything the screens read: one snapshot of the (demo) workspace. */
data class AppState(
    val devices: List<DeviceRow>,
    val spaces: List<Space>,
    val chats: List<Chat>,
    val sessions: Map<String, SessionRow>,
    val changeRequests: Map<String, ChangeRequestSummary>,
    val entries: Map<String, List<MessageEntry>>,
    val pinnedSessionIds: List<String>,
    val now: Long,
) {
    fun chat(id: String): Chat? = chats.firstOrNull { it.id == id }

    fun entries(chatId: String): List<MessageEntry> = entries[chatId].orEmpty()

    fun space(chat: Chat): Space? = chat.spaceId?.let { id -> spaces.firstOrNull { it.id == id } }

    fun deviceName(deviceId: String): String = devices.firstOrNull { it.id == deviceId }?.name ?: deviceId

    fun deviceOnline(deviceId: String): Boolean {
        val seen = devices.firstOrNull { it.id == deviceId }?.lastSeenAt ?: return false
        return now - seen < PRESENCE_FRESH_MS
    }

    val executionDevices: List<DeviceRow> get() = devices.filter { it.canHostSessions }

    /** Active sessions in Home order: pins first, then when you last called each one. */
    val overviewChats: List<Chat>
        get() {
            val liveSpaces = spaces.map { it.id }.toSet()
            val live = chats.filter { !it.archived && (it.spaceId?.let(liveSpaces::contains) ?: true) }
            return sortPinnedFirst(live, pinnedSessionIds)
        }

    fun chatsIn(spaceId: String): List<Chat> =
        sortPinnedFirst(chats.filter { !it.archived && it.spaceId == spaceId }, pinnedSessionIds)

    /** Archived sessions, newest first, scoped to a space and a search query. */
    fun archivedMatches(spaceId: String?, query: String): List<Chat> {
        val terms = query.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return sortActive(chats.filter { it.archived && (spaceId == null || it.spaceId == spaceId) }).filter { chat ->
            if (terms.isEmpty()) return@filter true
            val names = filterNames(chat)
            val fields = listOfNotNull(chat.displayTitle, chat.lastMessagePreview, chat.branch, names.project, names.device)
            terms.all { t -> fields.any { it.contains(t, ignoreCase = true) } }
        }
    }

    fun indicator(chat: Chat): ChatIndicator = chatIndicator(chat, effectiveStatus(sessions[chat.id], now))

    fun liveStatus(chat: Chat): SessionStatus? = effectiveStatus(sessions[chat.id], now)

    fun changeRequest(chat: Chat): ChangeRequestSummary? = changeRequests[chat.id]

    fun isPinned(chatId: String): Boolean = chatId in pinnedSessionIds

    fun filterNames(chat: Chat): HomeFilterNames = HomeFilterNames(space(chat)?.displayName, deviceName(chat.deviceId))
}

/**
 * Screen state for the app. Today it drives the offline demo dataset, the same starting
 * point as the iOS `-demo` mode; the live sync client will replace it behind the same
 * [AppState]. Which session is open is UI state (the navigation path), not model state.
 */
class AppModel(
    private val clock: () -> Long = System::currentTimeMillis,
    /** Fixed delay between streamed words; null uses the demo's 30-140 ms jitter. */
    private val tickMs: Long? = null,
) : ViewModel() {
    private val _state: MutableStateFlow<AppState>
    val state: StateFlow<AppState> get() = _state

    private var streamJob: Job? = null
    private var counter = 0

    init {
        val now = clock()
        val demo = DemoDataset.standard(now)
        _state = MutableStateFlow(
            AppState(
                devices = demo.devices, spaces = demo.spaces, chats = demo.chats, sessions = demo.sessions,
                changeRequests = demo.changeRequests, entries = demo.entries,
                pinnedSessionIds = emptyList(), now = now,
            ),
        )
    }

    private fun update(block: (AppState) -> AppState) {
        _state.update { block(it).copy(now = clock()) }
    }

    private fun updateChat(chatId: String, block: (Chat) -> Chat) = update { s ->
        s.copy(chats = s.chats.map { if (it.id == chatId) block(it) else it })
    }

    /** Opening a session marks it seen, which clears its "needs you" state. */
    fun markSeen(chatId: String) = updateChat(chatId) { it.copy(lastSeenAt = clock()) }

    fun archive(chatId: String) = updateChat(chatId) { it.copy(archived = true) }

    fun unarchive(chatId: String) = updateChat(chatId) { it.copy(archived = false) }

    fun setPinned(chatId: String, pinned: Boolean) = update { s ->
        s.copy(pinnedSessionIds = if (pinned) listOf(chatId) + s.pinnedSessionIds.filter { it != chatId } else s.pinnedSessionIds - chatId)
    }

    fun createSpace(deviceId: String, path: String, name: String?): String {
        val id = "space-${++counter}-${clock()}"
        update { s -> s.copy(spaces = s.spaces + Space(id, deviceId, path.trim(), name?.trim()?.ifEmpty { null }, gitDetected = false, createdAt = clock())) }
        return id
    }

    fun createChat(space: Space, config: ChatConfig, branch: String?, cwd: String?): String {
        val id = "chat-new-${++counter}-${clock()}"
        val now = clock()
        update { s ->
            s.copy(chats = s.chats + Chat(id, space.deviceId, null, false, cwd ?: space.path, branch, config, null, null, now, space.id, now))
        }
        return id
    }

    fun createProjectlessChat(deviceId: String, config: ChatConfig): String {
        val id = "chat-new-${++counter}-${clock()}"
        val now = clock()
        update { s -> s.copy(chats = s.chats + Chat(id, deviceId, null, false, "~", null, config, null, null, now, null, now)) }
        return id
    }

    /** Merge picks into the chat's config for the next dispatch (harness stays locked mid-chat). */
    fun setChatConfig(chatId: String, model: String?, reasoning: String?, modelOptions: Map<String, String>? = null) =
        updateChat(chatId) { chat ->
            val current = chat.config ?: ChatConfig("claude-code")
            chat.copy(config = current.copy(model = model, reasoning = reasoning, modelOptions = modelOptions ?: current.modelOptions))
        }

    /** Appends the user's message and streams the scripted reply into a live entry (simulateTurn). */
    fun send(chatId: String, text: String) {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        streamJob?.cancel()
        val at = clock()
        val liveId = "a-$at"
        val device = state.value.chat(chatId)?.deviceId ?: "dev-mac"
        update { s ->
            val entries = s.entries(chatId) +
                MessageEntry("u-$at", MessageRole.User, listOf(MessagePart.Text("t0", trimmed)), at, "ios-demo", MessageStatus.Complete) +
                MessageEntry(liveId, MessageRole.Assistant, listOf(MessagePart.Text("t0", "")), at, device, MessageStatus.Streaming)
            s.copy(
                entries = s.entries + (chatId to entries),
                sessions = s.sessions + (chatId to SessionRow(chatId, device, SessionStatus.Working, at, at)),
                chats = s.chats.map {
                    if (it.id != chatId) it else it.copy(
                        title = it.title ?: trimmed.take(48), lastPromptAt = at, lastMessageAt = at,
                        lastMessagePreview = trimmed, lastSeenAt = at,
                    )
                },
            )
        }
        streamJob = viewModelScope.launch {
            var shown = ""
            val tokens = Regex("""\S+\s*""").findAll(DemoDataset.STREAM_REPLY).map { it.value }
            for (token in tokens) {
                shown += token
                setReply(chatId, liveId, shown, MessageStatus.Streaming)
                delay(tickMs ?: Random.nextLong(30, 141))
            }
            setReply(chatId, liveId, shown, MessageStatus.Complete)
            val end = clock()
            update { s ->
                s.copy(
                    sessions = s.sessions + (chatId to SessionRow(chatId, device, SessionStatus.Idle, null, end)),
                    chats = s.chats.map {
                        if (it.id != chatId) it else it.copy(
                            lastMessageAt = end, lastSeenAt = end,
                            lastMessagePreview = "When the turn settles, this entry flips…",
                        )
                    },
                )
            }
        }
    }

    /** Stop: cancel the live reply and settle the entry as aborted. */
    fun interrupt(chatId: String) {
        streamJob?.cancel()
        update { s ->
            s.copy(
                entries = s.entries + (chatId to s.entries(chatId).map { e ->
                    if (e.status == MessageStatus.Streaming) e.copy(status = MessageStatus.Aborted) else e
                }),
                sessions = s.sessions + (chatId to (s.sessions[chatId]?.copy(status = SessionStatus.Idle, startedAt = null, updatedAt = clock())
                    ?: SessionRow(chatId, s.chat(chatId)?.deviceId.orEmpty(), SessionStatus.Idle, null, clock()))),
            )
        }
    }

    /** Answer an open input request: the chip resolves and the session stops waiting on you. */
    fun respondInput(chatId: String, requestId: String, @Suppress("UNUSED_PARAMETER") answers: List<UserInputAnswer>) {
        update { s ->
            s.copy(
                entries = s.entries + (chatId to s.entries(chatId).map { e ->
                    e.copy(parts = e.parts.map { p -> if (p is MessagePart.Input && p.requestId == requestId) p.copy(resolved = true) else p })
                }),
                sessions = s.sessions - chatId,
            )
        }
    }

    private fun setReply(chatId: String, replyId: String, text: String, status: MessageStatus) = update { s ->
        s.copy(
            entries = s.entries + (chatId to s.entries(chatId).map { e ->
                if (e.id == replyId) e.copy(parts = listOf(MessagePart.Text("t0", text)), status = status) else e
            }),
        )
    }
}
