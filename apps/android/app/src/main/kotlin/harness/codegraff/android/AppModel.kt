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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.random.Random

/**
 * Everything Home, the switcher and the session header read: the workspace minus transcripts.
 * Streaming a reply changes only the entries, never this, so those screens do not recompose per
 * token (the same split the iOS app gets from observing the workspace and each session store
 * separately). Derived lists are computed once per instance.
 */
data class WorkspaceState(
    val devices: List<DeviceRow>,
    val spaces: List<Space>,
    val chats: List<Chat>,
    val sessions: Map<String, SessionRow>,
    val changeRequests: Map<String, ChangeRequestSummary>,
    val pinnedSessionIds: List<String>,
    /** Wall clock, refreshed on a slow tick and on writes: relative times and stale-session checks read it. */
    val now: Long,
) {
    private val chatsById by lazy(LazyThreadSafetyMode.NONE) { chats.associateBy { it.id } }

    /** Active sessions in Home order: pins first, then when you last called each one. */
    val overviewChats: List<Chat> by lazy(LazyThreadSafetyMode.NONE) {
        val liveSpaces = spaces.map { it.id }.toSet()
        sortPinnedFirst(chats.filter { !it.archived && (it.spaceId?.let(liveSpaces::contains) ?: true) }, pinnedSessionIds)
    }

    val executionDevices: List<DeviceRow> by lazy(LazyThreadSafetyMode.NONE) { devices.filter { it.canHostSessions } }

    fun chat(id: String): Chat? = chatsById[id]

    fun space(chat: Chat): Space? = chat.spaceId?.let { id -> spaces.firstOrNull { it.id == id } }

    fun deviceName(deviceId: String): String = devices.firstOrNull { it.id == deviceId }?.name ?: deviceId

    fun deviceOnline(deviceId: String): Boolean {
        val seen = devices.firstOrNull { it.id == deviceId }?.lastSeenAt ?: return false
        return now - seen < PRESENCE_FRESH_MS
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

/** A snapshot of the workspace and every transcript, for tests and one-shot reads. */
data class AppState(val workspace: WorkspaceState, val entries: Map<String, List<MessageEntry>>) {
    fun entries(chatId: String): List<MessageEntry> = entries[chatId].orEmpty()
}

/**
 * Screen state for the app. Today it drives the offline demo dataset, the same starting point as the
 * iOS `-demo` mode; the live sync client will replace it behind the same flows. Which session is open
 * is UI state (the navigation path), not model state.
 *
 * The workspace and the transcripts are separate flows on purpose: a streamed token replaces only one
 * chat's entry list, so only that session's screen recomposes.
 */
class AppModel(
    private val clock: () -> Long = System::currentTimeMillis,
    /** Fixed delay between streamed words; null uses the demo's 30-140 ms jitter. */
    private val tickMs: Long? = null,
) : ViewModel() {
    private val _workspace: MutableStateFlow<WorkspaceState>
    private val _entries: MutableStateFlow<Map<String, List<MessageEntry>>>

    val workspace: StateFlow<WorkspaceState> get() = _workspace

    /** The workspace and all transcripts as one value. */
    val state: AppState get() = AppState(_workspace.value, _entries.value)

    /** One chat's transcript. Emits only when that chat's list is replaced. */
    fun entriesFlow(chatId: String): Flow<List<MessageEntry>> =
        _entries.map { it[chatId].orEmpty() }.distinctUntilChanged { a, b -> a === b }

    fun entries(chatId: String): List<MessageEntry> = _entries.value[chatId].orEmpty()

    private var streamJob: Job? = null
    private var counter = 0

    init {
        val now = clock()
        val demo = DemoDataset.standard(now)
        _workspace = MutableStateFlow(
            WorkspaceState(demo.devices, demo.spaces, demo.chats, demo.sessions, demo.changeRequests, emptyList(), now),
        )
        _entries = MutableStateFlow(demo.entries)
    }

    /** Refreshes `now` on a slow interval so relative times and stale-session checks move on. Launch from the UI's lifecycle. */
    suspend fun runClock(everyMs: Long = 15_000) {
        while (true) {
            delay(everyMs)
            _workspace.update { it.copy(now = clock()) }
        }
    }

    private fun update(block: (WorkspaceState) -> WorkspaceState) {
        _workspace.update { block(it).copy(now = clock()) }
    }

    private fun updateChat(chatId: String, block: (Chat) -> Chat) = update { s ->
        s.copy(chats = s.chats.map { if (it.id == chatId) block(it) else it })
    }

    private fun setEntries(chatId: String, block: (List<MessageEntry>) -> List<MessageEntry>) =
        _entries.update { it + (chatId to block(it[chatId].orEmpty())) }

    /** Opening a session marks it seen, which clears its "needs you" state. */
    fun markSeen(chatId: String) {
        // Skip the write when nothing would change: leaving a session marks it seen again.
        val chat = _workspace.value.chat(chatId) ?: return
        if (!chat.unseen) return
        updateChat(chatId) { it.copy(lastSeenAt = clock()) }
    }

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
        val device = _workspace.value.chat(chatId)?.deviceId ?: "dev-mac"
        setEntries(chatId) { entries ->
            entries +
                MessageEntry("u-$at", MessageRole.User, listOf(MessagePart.Text("t0", trimmed)), at, "ios-demo", MessageStatus.Complete) +
                MessageEntry(liveId, MessageRole.Assistant, listOf(MessagePart.Text("t0", "")), at, device, MessageStatus.Streaming)
        }
        update { s ->
            s.copy(
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
        setEntries(chatId) { entries -> entries.map { e -> if (e.status == MessageStatus.Streaming) e.copy(status = MessageStatus.Aborted) else e } }
        update { s ->
            s.copy(
                sessions = s.sessions + (chatId to (s.sessions[chatId]?.copy(status = SessionStatus.Idle, startedAt = null, updatedAt = clock())
                    ?: SessionRow(chatId, s.chat(chatId)?.deviceId.orEmpty(), SessionStatus.Idle, null, clock()))),
            )
        }
    }

    /** Answer an open input request: the chip resolves and the session stops waiting on you. */
    fun respondInput(chatId: String, requestId: String, @Suppress("UNUSED_PARAMETER") answers: List<UserInputAnswer>) {
        setEntries(chatId) { entries ->
            entries.map { e ->
                e.copy(parts = e.parts.map { p -> if (p is MessagePart.Input && p.requestId == requestId) p.copy(resolved = true) else p })
            }
        }
        update { s -> s.copy(sessions = s.sessions - chatId) }
    }

    /** A streamed token: touches only this chat's transcript, never the workspace. */
    private fun setReply(chatId: String, replyId: String, text: String, status: MessageStatus) = setEntries(chatId) { entries ->
        entries.map { e -> if (e.id == replyId) e.copy(parts = listOf(MessagePart.Text("t0", text)), status = status) else e }
    }
}
