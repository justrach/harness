package harness.codegraff.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.AgentDescriptor
import harness.codegraff.android.model.AgentReadiness
import harness.codegraff.android.model.DeviceAgents
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfSpan
import harness.codegraff.android.model.ChangeRequestSummary
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.DeviceRow
import harness.codegraff.android.model.HomeFilterNames
import harness.codegraff.android.model.HostStatus
import harness.codegraff.android.model.MessageEntry
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.MessageRole
import harness.codegraff.android.model.MessageStatus
import harness.codegraff.android.model.PRESENCE_FRESH_MS
import harness.codegraff.android.model.ATTACHMENT_ONLY_TEXT
import harness.codegraff.android.model.AccountApi
import harness.codegraff.android.model.AccountDeletion
import harness.codegraff.android.model.QueueAction
import harness.codegraff.android.model.QueueActionReply
import harness.codegraff.android.model.QueueDeliveryGate
import harness.codegraff.android.model.QueueEditFinishResult
import harness.codegraff.android.model.QueueEditLease
import harness.codegraff.android.model.QueueEditStartResult
import harness.codegraff.android.model.QueuedMessage
import harness.codegraff.android.model.MessageQueue
import harness.codegraff.android.model.SessionRow
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.Space
import harness.codegraff.android.model.UserInputAnswer
import harness.codegraff.android.model.chatIndicator
import harness.codegraff.android.model.effectiveStatus
import harness.codegraff.android.model.sortActive
import harness.codegraff.android.model.sortPinnedFirst
import harness.codegraff.android.core.SessionSnapshot
import harness.codegraff.android.sync.LiveSync
import harness.codegraff.android.sync.toModel
import harness.codegraff.android.sync.toNative
import harness.codegraff.android.demo.FolderListing
import harness.codegraff.android.model.ConnectivityRules
import harness.codegraff.android.model.ConnectivityUi
import harness.codegraff.android.model.HarnessCatalog
import harness.codegraff.android.model.HarnessInfo
import harness.codegraff.android.model.HostNotice
import harness.codegraff.android.model.ModelInfo
import harness.codegraff.android.model.RepoRef
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.CancellationException
import java.security.MessageDigest
import java.util.UUID
import kotlin.random.Random

/** The device id this phone's own writes carry, matching the demo transcript's local messages. */
private const val LOCAL_DEVICE_ID = "ios-demo"

/** How long the host holds a queued row for an edit before another device may take it. */
private const val EDIT_LEASE_MS = 60_000L

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
    /** What each computer reports in `ListHarnesses`, by device id. Demo only until the device relay is wired on Android. */
    val agents: Map<String, List<AgentDescriptor>> = emptyMap(),
    /** Device id to the epoch ms of its last presence beat heard this session (live sync only). */
    val presence: Map<String, Long> = emptyMap(),
    /** The registry socket is joined. Always true for the demo. */
    val connected: Boolean = true,
    /** Server state has reached this session over any transport. Always true for the demo. */
    val synced: Boolean = true,
    /** Live sync: what the presence rule says about each computer. Unused by the demo. */
    val hostStatuses: Map<String, HostStatus> = emptyMap(),
    /** Statuses come from the presence rule (live) rather than the demo's `lastSeenAt` freshness. */
    val live: Boolean = false,
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

    /**
     * What a screen may claim about a computer (AppModel.hostStatus): live sync applies the presence rule; the demo
     * reads a fresh `lastSeenAt` as online and anything else as offline, as the iOS demo does.
     */
    fun hostStatus(deviceId: String): HostStatus {
        if (live) return hostStatuses[deviceId] ?: HostStatus.Unknown
        val seen = devices.firstOrNull { it.id == deviceId }?.lastSeenAt ?: return HostStatus.Offline
        return if (now - seen < PRESENCE_FRESH_MS) HostStatus.Online else HostStatus.Offline
    }

    fun deviceOnline(deviceId: String): Boolean = hostStatus(deviceId) == HostStatus.Online

    /** Whether an agent has been brought in: every computer's agents, judged by [AgentReadiness]. */
    val agentReadiness: AgentReadiness by lazy(LazyThreadSafetyMode.NONE) {
        AgentReadiness.evaluate(devices.map { DeviceAgents(it.id, it.name, deviceOnline(it.id), agents[it.id].orEmpty()) })
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
 * One chat's pending-message queue (SessionStore.queue / queueActionsPending / queueActionError). Kept out of the
 * workspace and the transcript so queueing a message recomposes only the panel above the composer.
 */
data class QueueState(
    val rows: List<QueuedMessage> = emptyList(),
    /** Rows with a host action in flight; they cannot be moved, edited or sent again. */
    val pending: Set<String> = emptySet(),
    val error: String? = null,
)

/** Account deletion progress for Settings (AppModel.accountDeletionBusy / accountDeletionError). */
data class AccountDeletionState(val busy: Boolean = false, val error: String? = null)

/** A snapshot of the workspace and every transcript, for tests and one-shot reads. */
data class AppState(val workspace: WorkspaceState, val entries: Map<String, List<MessageEntry>>) {
    fun entries(chatId: String): List<MessageEntry> = entries[chatId].orEmpty()
}

/**
 * Screen state for the app. It drives either the offline demo dataset (the iOS `-demo` mode) or a live sync with
 * the edge through the native core ([LiveSync]), behind the same flows. Which session is open is UI state (the
 * navigation path), not model state.
 *
 * The workspace and the transcripts are separate flows on purpose: a streamed token replaces only one
 * chat's entry list, so only that session's screen recomposes.
 */
class AppModel(
    private val clock: () -> Long = System::currentTimeMillis,
    /** Fixed delay between streamed words; null uses the demo's 30-140 ms jitter. */
    private val tickMs: Long? = null,
    /** A live sync to drive instead of the demo; null falls back to [liveFactory], then to the demo. */
    liveSync: LiveSync? = null,
    /** The CodeGraff sign-in behind [liveSync]; null falls back to [accountFactory]. */
    accountApi: AccountApi? = null,
) : ViewModel() {
    private val _workspace: MutableStateFlow<WorkspaceState>
    private val _entries: MutableStateFlow<Map<String, List<MessageEntry>>>

    val workspace: StateFlow<WorkspaceState> get() = _workspace

    companion object {
        /** Demo rig: which dataset a new model starts with (`onboarding-*`; anything else is the standard demo). Set from an intent extra. */
        @Volatile
        var scenario: String? = null

        /** Opens the live sync for a new model; null runs the demo. Set by the activity before the model exists. */
        @Volatile
        var liveFactory: (() -> LiveSync)? = null

        /** The CodeGraff sign-in a live model runs under (none for the demo or a dev edge). Set with [liveFactory]. */
        @Volatile
        var accountFactory: (() -> AccountApi)? = null
    }

    /** The live sync this model drives, or null for the demo. */
    val live: LiveSync? = liveSync ?: liveFactory?.invoke()

    /** The CodeGraff account this model is signed in with, for account deletion. */
    val account: AccountApi? = accountApi ?: if (live != null) accountFactory?.invoke() else null

    /** Live sync with an edge, rather than the offline demo. */
    val isLive: Boolean get() = live != null

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
        val demo = if (live != null) null else when (scenario) {
            "onboarding-nocomputer" -> DemoDataset.onboarding(now, computerOnline = false, agentReady = false)
            "onboarding-noagent" -> DemoDataset.onboarding(now, computerOnline = true, agentReady = false)
            "onboarding-ready" -> DemoDataset.onboarding(now, computerOnline = true, agentReady = true)
            else -> DemoDataset.standard(now)
        }
        _workspace = MutableStateFlow(
            if (demo == null) {
                WorkspaceState(emptyList(), emptyList(), emptyList(), emptyMap(), emptyMap(), emptyList(), now, connected = false, synced = false)
            } else {
                WorkspaceState(demo.devices, demo.spaces, demo.chats, demo.sessions, demo.changeRequests, emptyList(), now, demo.agents)
            },
        )
        _entries = MutableStateFlow(demo?.entries.orEmpty())
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
        // Live: the synced seen mark, which only ever moves forward (WorkspaceStore.markSeen).
        live?.let { it.core.markSeen(chatId); return }
        // Skip the write when nothing would change: leaving a session marks it seen again.
        val chat = _workspace.value.chat(chatId) ?: return
        if (!chat.unseen) return
        updateChat(chatId) { it.copy(lastSeenAt = clock()) }
    }

    fun archive(chatId: String) {
        live?.let { it.core.setArchived(chatId, true); return }
        updateChat(chatId) { it.copy(archived = true) }
    }

    fun unarchive(chatId: String) {
        live?.let { it.core.setArchived(chatId, false); return }
        updateChat(chatId) { it.copy(archived = false) }
    }

    fun setPinned(chatId: String, pinned: Boolean) {
        live?.let { it.core.setPinned(chatId, pinned); return }
        update { s ->
            s.copy(pinnedSessionIds = if (pinned) listOf(chatId) + s.pinnedSessionIds.filter { it != chatId } else s.pinnedSessionIds - chatId)
        }
    }

    /**
     * Add a project folder on a computer. Live: the owning host creates it over the relay, and the phone writes the
     * row itself only when the host cannot be reached (WorkspaceStore.createSpace).
     */
    suspend fun createSpace(deviceId: String, path: String, name: String?, gitDetected: Boolean = false): String {
        live?.let { return it.core.addSpace(deviceId, path.trim(), gitDetected) }
        val id = "space-${++counter}-${clock()}"
        update { s -> s.copy(spaces = s.spaces + Space(id, deviceId, path.trim(), name?.trim()?.ifEmpty { null }, gitDetected = false, createdAt = clock())) }
        return id
    }

    fun createChat(space: Space, config: ChatConfig, branch: String?, cwd: String?): String {
        live?.let { return it.core.createChat(space.deviceId, space.id, cwd ?: space.path, config.toNative(), branch) }
        val id = "chat-new-${++counter}-${clock()}"
        val now = clock()
        update { s ->
            s.copy(chats = s.chats + Chat(id, space.deviceId, null, false, cwd ?: space.path, branch, config, null, null, now, space.id, now))
        }
        return id
    }

    fun createProjectlessChat(deviceId: String, config: ChatConfig): String {
        live?.let { return it.core.createChat(deviceId, null, "~", config.toNative(), null) }
        val id = "chat-new-${++counter}-${clock()}"
        val now = clock()
        update { s -> s.copy(chats = s.chats + Chat(id, deviceId, null, false, "~", null, config, null, null, now, null, now)) }
        return id
    }

    /** Merge picks into the chat's config for the next dispatch (harness stays locked mid-chat). */
    fun setChatConfig(chatId: String, model: String?, reasoning: String?, modelOptions: Map<String, String>? = null) {
        val chat = _workspace.value.chat(chatId) ?: return
        val current = chat.config ?: ChatConfig("claude-code")
        val next = current.copy(model = model, reasoning = reasoning, modelOptions = modelOptions ?: current.modelOptions)
        live?.let { it.core.setChatConfig(chatId, next.toNative()); return }
        updateChat(chatId) { it.copy(config = next) }
    }

    /**
     * Sends the message, or parks it on the chat's queue while a reply is still streaming, like the composer does
     * (ComposerView.send: `runLive` queues, otherwise it delivers).
     */
    fun send(chatId: String, text: String, attachments: List<String> = emptyList()) {
        if (text.isBlank() && attachments.isEmpty()) return
        val body = text.ifBlank { ATTACHMENT_ONLY_TEXT }
        Perf.measure(PerfSpan.SendApply) {
            if (isRunLive(chatId)) enqueueMessage(chatId, body, attachments) else deliver(chatId, body)
        }
    }

    fun isRunLive(chatId: String): Boolean {
        val state = _workspace.value
        return state.chat(chatId)?.let(state::liveStatus) == SessionStatus.Working
    }

    /** Appends the user's message and streams the scripted reply into a live entry (simulateTurn). */
    private fun deliver(chatId: String, text: String) {
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
            // The host takes the front of the queue once the turn settles.
            deliverNextQueued(chatId)
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

    // MARK: queue (SessionQueue.swift). The demo stands in for the chat host: it acknowledges actions, takes the
    // front of the queue when a turn settles, and hands out edit leases. Live sync will replace it behind the same calls.

    private val _queues = MutableStateFlow<Map<String, QueueState>>(emptyMap())
    private val editLeases = HashMap<String, String>()

    /** One chat's queue. Emits only when that chat's queue changes. */
    fun queueFlow(chatId: String): Flow<QueueState> = _queues.map { it[chatId] ?: QueueState() }.distinctUntilChanged()

    fun queue(chatId: String): QueueState = _queues.value[chatId] ?: QueueState()

    private fun setQueue(chatId: String, block: (QueueState) -> QueueState) =
        _queues.update { it + (chatId to block(it[chatId] ?: QueueState())) }

    private fun mapRow(chatId: String, id: String, block: (QueuedMessage) -> QueuedMessage) =
        setQueue(chatId) { s -> s.copy(rows = s.rows.map { if (it.id == id) block(it) else it }) }

    /** Stand in for a host stamping a delivery gate on a row, which tests need and the demo never does. */
    internal fun setDeliveryGateForTesting(chatId: String, id: String, gate: QueueDeliveryGate?) =
        mapRow(chatId, id) { it.copy(deliveryGate = gate) }

    private fun dropRow(chatId: String, id: String) = setQueue(chatId) { s -> s.copy(rows = s.rows.filterNot { it.id == id }) }

    /** Park a message on the queue. The host decides where it goes: the front of the next turn. */
    fun enqueueMessage(chatId: String, text: String, attachments: List<String> = emptyList(), holdForTurnEnd: Boolean = true): String? {
        if (text.trim().isEmpty()) return null
        val id = UUID.randomUUID().toString().lowercase()
        val row = QueuedMessage(id, text, attachments, issuedBy = LOCAL_DEVICE_ID, issuedAt = clock(), holdForTurnEnd = holdForTurnEnd)
        setQueue(chatId) { it.copy(rows = it.rows + row) }
        return id
    }

    /** Move a row to [to], clamped to the queue. The same slot is a no-op. */
    fun moveQueued(chatId: String, id: String, to: Int) {
        val q = queue(chatId)
        if (id in q.pending) return
        val from = q.rows.indexOfFirst { it.id == id }
        if (from < 0 || q.rows[from].deliveryGate != null) return
        val target = to.coerceIn(0, q.rows.size - 1)
        if (from == target) return
        setQueue(chatId) { s ->
            val rows = s.rows.toMutableList()
            rows.add(target, rows.removeAt(from))
            s.copy(rows = rows)
        }
    }

    /** Nudge a row one slot up (-1) or down (+1). */
    fun moveQueuedBy(chatId: String, id: String, direction: Int) {
        val q = queue(chatId)
        val from = q.rows.indexOfFirst { it.id == id }
        val to = MessageQueue.neighbour(from, direction, q.rows.size) ?: return
        moveQueued(chatId, id, to)
    }

    /**
     * The host serializes these actions with delivery. A removal is applied only after its acknowledgement; a lost
     * reply is uncertain and leaves sync to reconcile. Protected rows can only be removed.
     */
    suspend fun performQueueAction(
        chatId: String,
        id: String,
        action: QueueAction,
        call: (suspend (method: String, params: Map<String, String>) -> QueueActionReply)? = null,
    ): Boolean {
        val q = queue(chatId)
        val row = q.rows.firstOrNull { it.id == id } ?: return false
        if (id in q.pending) return false
        if (action != QueueAction.Remove && row.deliveryGate != null) return false
        setQueue(chatId) { it.copy(pending = it.pending + id, error = null) }
        try {
            val reply = call?.invoke(action.method, mapOf("chatId" to chatId, "id" to id)) ?: demoHost(chatId, row, action)
            if (!reply.acknowledged(action)) {
                setQueue(chatId) { it.copy(error = "The host did not confirm the action. The message may have already left the queue.") }
                return false
            }
            if (action == QueueAction.Remove) dropRow(chatId, id)
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            setQueue(chatId) {
                it.copy(error = "Couldn't complete ${action.label.lowercase()}. Check the connection to the chat host and the queue before retrying.")
            }
            return false
        } finally {
            setQueue(chatId) { it.copy(pending = it.pending - id) }
        }
    }

    private fun demoHost(chatId: String, row: QueuedMessage, action: QueueAction): QueueActionReply = when (action) {
        QueueAction.Remove -> QueueActionReply(removed = true)
        QueueAction.SendNow -> {
            // Sending now stops the turn to do it; the row leaves the queue with the next sync.
            if (isRunLive(chatId)) interrupt(chatId)
            dropRow(chatId, row.id)
            deliver(chatId, MessageQueue.visibleText(row.text, row.attachments))
            QueueActionReply(sent = true)
        }
    }

    /** When a turn settles the host takes the front of the queue, skipping rows that are protected or in flight. */
    private fun deliverNextQueued(chatId: String) {
        val q = queue(chatId)
        val next = q.rows.firstOrNull { it.deliveryGate == null && it.id !in q.pending } ?: return
        dropRow(chatId, next.id)
        deliver(chatId, MessageQueue.visibleText(next.text, next.attachments))
    }

    // Protected editing: the host hands out a lease, the row is gated while it is retyped, and a changed row conflicts.

    suspend fun beginQueuedEdit(chatId: String, id: String, instanceId: String): QueueEditStartResult {
        val q = queue(chatId)
        if (id in q.pending) return QueueEditStartResult.Unavailable
        val row = q.rows.firstOrNull { it.id == id } ?: return QueueEditStartResult.Unavailable
        val gate = row.deliveryGate
        if (gate is QueueDeliveryGate.Editing && gate.expiresAtMs > clock() && editLeases[id]?.substringBefore('|') != instanceId) {
            return QueueEditStartResult.Locked
        }
        val leaseId = UUID.randomUUID().toString().lowercase()
        val expires = clock() + EDIT_LEASE_MS
        editLeases[id] = "$instanceId|$leaseId"
        mapRow(chatId, id) { it.copy(deliveryGate = QueueDeliveryGate.Editing(LOCAL_DEVICE_ID, expires)) }
        return QueueEditStartResult.Acquired(QueueEditLease(id, leaseId, row.text, textHash(row.text), expires))
    }

    suspend fun renewQueuedEdit(chatId: String, lease: QueueEditLease): Boolean {
        if (queue(chatId).rows.none { it.id == lease.rowId } || editLeases[lease.rowId]?.substringAfter('|') != lease.leaseId) return false
        val expires = clock() + EDIT_LEASE_MS
        mapRow(chatId, lease.rowId) { it.copy(deliveryGate = QueueDeliveryGate.Editing(LOCAL_DEVICE_ID, expires)) }
        return true
    }

    suspend fun finishQueuedEdit(chatId: String, lease: QueueEditLease, action: String, text: String? = null): QueueEditFinishResult {
        val row = queue(chatId).rows.firstOrNull { it.id == lease.rowId } ?: return QueueEditFinishResult.Missing
        if (editLeases[lease.rowId]?.substringAfter('|') != lease.leaseId) return QueueEditFinishResult.Lost
        if (textHash(row.text) != lease.baseTextHash) return QueueEditFinishResult.Conflict
        when (action) {
            "commit" -> {
                val edited = text ?: return QueueEditFinishResult.Lost
                mapRow(chatId, lease.rowId) { it.copy(text = edited, editedAt = clock(), deliveryGate = null) }
            }
            "cancel" -> mapRow(chatId, lease.rowId) { it.copy(deliveryGate = null) }
            "discard" -> dropRow(chatId, lease.rowId)
            else -> return QueueEditFinishResult.Lost
        }
        editLeases.remove(lease.rowId)
        return QueueEditFinishResult.Finished
    }

    /** Release an edit lease when the screen goes away, where a suspending call cannot run. */
    fun cancelQueuedEditInBackground(chatId: String, lease: QueueEditLease) {
        viewModelScope.launch { finishQueuedEdit(chatId, lease, "cancel") }
    }

    private fun textHash(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    // MARK: account deletion (AppModel.deleteAccount)

    private val _accountDeletion = MutableStateFlow(AccountDeletionState())
    val accountDeletion: StateFlow<AccountDeletionState> get() = _accountDeletion

    /** Only a real CodeGraff sign-in has an account to delete; the offline demo has none, as on iOS. */
    val canDeleteAccount: Boolean get() = account != null

    /**
     * Delete the signed-in account. Success signs out; a refusal keeps the session but stores the tokens the
     * edge rotated.
     */
    suspend fun deleteAccount(api: AccountApi?, onSignedOut: () -> Unit = {}) {
        if (_accountDeletion.value.busy) return
        _accountDeletion.value = AccountDeletionState(busy = true)
        var error: String? = null
        try {
            val tokens = api?.currentTokens()
            if (api == null || tokens == null) {
                error = "Sign in with CodeGraff to delete your account."
            } else when (val result = api.delete(tokens)) {
                AccountDeletion.Deleted -> onSignedOut()
                is AccountDeletion.Refused -> {
                    result.tokens?.let(api::storeTokens)
                    error = result.message
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = "Couldn't reach Harness. Check your connection and try again."
        } finally {
            _accountDeletion.value = AccountDeletionState(busy = false, error = error)
        }
    }

    fun dismissAccountDeletionError() {
        _accountDeletion.update { it.copy(error = null) }
    }

    /** A streamed token: touches only this chat's transcript, never the workspace. */
    private fun setReply(chatId: String, replyId: String, text: String, status: MessageStatus) = setEntries(chatId) { entries ->
        entries.map { e -> if (e.id == replyId) e.copy(parts = listOf(MessagePart.Text("t0", text)), status = status) else e }
    }

    // MARK: connectivity (Connectivity.swift, AppModel.hostNotice / chatDeliveryDegraded)

    private val _connectivity = MutableStateFlow(ConnectivityUi())

    /** The graced connection state. The demo is always connected. */
    val connectivity: StateFlow<ConnectivityUi> get() = _connectivity

    /** Chats whose room has dialed (live). A room that never dialed is not "degraded". */
    private val roomsActive = MutableStateFlow<Set<String>>(emptySet())

    /** The one warning the new-session screen may show for a computer; null when there is nothing true to say. */
    fun hostNotice(deviceId: String): HostNotice? {
        if (live == null) return null
        val ws = _workspace.value
        return ConnectivityRules.hostNotice(sessionExpired = false, ws.hostStatus(deviceId), ws.connected)
    }

    /** A send to this chat would queue rather than deliver promptly. Never in the demo. */
    fun chatDeliveryDegraded(chat: Chat): Boolean {
        if (live == null) return false
        return ConnectivityRules.deliveryDegraded(
            _connectivity.value, chat.id, chat.id in roomsActive.value, _workspace.value.hostStatus(chat.deviceId),
        )
    }

    // MARK: requests to a computer (the device relay). The demo serves its canned data.

    private val harnessCache = HashMap<String, List<HarnessInfo>>()
    private val modelCache = HashMap<String, List<ModelInfo>>()

    /** A computer's folders; null when it cannot be reached. */
    suspend fun listFolders(deviceId: String, path: String?): FolderListing? {
        val live = live ?: return DemoDataset.listFolders(deviceId, path)
        return runCatching { live.core.listFolders(deviceId, path) }.getOrNull()?.toModel()
    }

    /** The project's branches (git projects only); empty when the computer cannot be reached. */
    suspend fun listRefs(space: Space): List<RepoRef> {
        if (!space.gitDetected) return emptyList()
        val live = live ?: return DemoDataset.listRefs(space.path)
        return runCatching { live.core.listRefs(space.deviceId, space.path) }.getOrNull().orEmpty().map { it.toModel() }
    }

    /**
     * The agents a computer offers: its live catalog, else the last one it sent this session, else the static pair
     * (AppModel.listHarnesses).
     */
    suspend fun listHarnesses(deviceId: String): List<HarnessInfo> {
        val live = live ?: return HarnessCatalog.harnesses
        val fetched = runCatching { live.core.listHarnesses(deviceId) }.getOrNull()?.map { it.toModel() }
        if (!fetched.isNullOrEmpty()) harnessCache[deviceId] = fetched
        return harnessCache[deviceId] ?: HarnessCatalog.harnesses
    }

    /** Where graff compacts on one computer (Settings > Graff compaction); null is graff's default. The demo keeps it. */
    suspend fun graffCompactAt(deviceId: String): Int? {
        val live = live ?: return null
        return live.core.graffCompactAt(deviceId)?.toInt()
    }

    suspend fun setGraffCompactAt(deviceId: String, pct: Int?): Int? {
        val live = live ?: return pct
        return live.core.setGraffCompactAt(deviceId, pct?.toUByte())?.toInt()
    }

    /** The models an agent offers on the computer that runs the session, with the same fallbacks. */
    suspend fun listModels(deviceId: String, harness: String): List<ModelInfo> {
        val live = live ?: return HarnessCatalog.models(harness)
        val key = "$deviceId|$harness"
        val fetched = runCatching { live.core.listModels(deviceId, harness) }.getOrNull()?.map { it.toModel() }
        if (!fetched.isNullOrEmpty()) modelCache[key] = fetched
        return modelCache[key] ?: HarnessCatalog.models(harness)
    }

    // MARK: live sync. Started last, so every flow the collectors write to already exists.

    init {
        live?.let(::startLive)
    }

    private fun startLive(live: LiveSync) {
        viewModelScope.launch {
            live.feed.connectivity.collect { snapshot -> snapshot?.let { _connectivity.value = it.toModel() } }
        }
        // Onboarding asks every online computer which agents it has (AppModel.agentReadiness).
        viewModelScope.launch {
            _workspace.map { ws -> ws.devices.filter { ws.deviceOnline(it.id) }.map { it.id }.toSet() }
                .distinctUntilChanged()
                .collect { online ->
                    val agents = online.associateWith { id ->
                        runCatching { live.core.agentDescriptors(id) }.getOrNull().orEmpty().map { it.toModel() }
                    }
                    _workspace.update { it.copy(agents = agents) }
                }
        }
        viewModelScope.launch {
            live.feed.workspace.collect { snapshot ->
                snapshot ?: return@collect
                val w = snapshot.toModel()
                _workspace.update {
                    it.copy(
                        devices = w.devices, spaces = w.spaces, chats = w.chats, sessions = w.sessions,
                        pinnedSessionIds = w.pinnedSessionIds, presence = w.presence, connected = w.connected,
                        synced = w.synced, hostStatuses = w.hostStatuses, changeRequests = w.changeRequests,
                        live = true, now = clock(),
                    )
                }
            }
        }
        viewModelScope.launch {
            var seen = emptyMap<String, SessionSnapshot>()
            live.feed.sessions.collect { snapshots ->
                // Only the chats whose snapshot was replaced are re-mapped; the rest keep their lists (and identity).
                val changed = snapshots.filter { (id, snapshot) -> seen[id] !== snapshot }
                seen = snapshots
                roomsActive.value = snapshots.filterValues { it.roomActive }.keys
                if (changed.isEmpty()) return@collect
                _entries.update { all ->
                    all + changed.mapValues { (id, snapshot) -> snapshot.entries.toModel(all[id].orEmpty()) }
                }
                _queues.update { all ->
                    all + changed.mapValues { (id, snapshot) ->
                        (all[id] ?: QueueState()).copy(rows = snapshot.queue.map { it.toModel() })
                    }
                }
            }
        }
        live.core.start()
    }

    /** A session screen opened: the live core hydrates the chat from disk and joins its room. */
    fun attachSession(chatId: String) {
        val live = live ?: return
        viewModelScope.launch(Dispatchers.IO) { live.feed.sessionChanged(live.core.openSession(chatId)) }
    }

    /** The session screen went away; the chat stays warm until it is among the coldest. */
    fun detachSession(chatId: String) {
        live?.core?.closeSession(chatId)
    }

    /** The app came to the front: revive the rooms now rather than after their backoff. */
    fun foregrounded() {
        live?.core?.foregrounded()
    }

    /** The app went to the background: persist everything now, and stop status wake-ups until it returns. */
    fun backgrounded() {
        val live = live ?: return
        live.core.backgrounded()
        viewModelScope.launch(Dispatchers.IO) { live.core.flush() }
    }

    override fun onCleared() {
        val live = live ?: return
        // Leaving the rooms persists and waits on the core's own threads; not on the main thread.
        Thread({ live.core.stop() }, "harness-sync-stop").start()
    }
}
