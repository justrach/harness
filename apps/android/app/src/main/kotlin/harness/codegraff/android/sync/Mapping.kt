package harness.codegraff.android.sync

import harness.codegraff.android.core.AgentDescriptorRecord
import harness.codegraff.android.core.ChangeRequestRecord
import harness.codegraff.android.core.ChatConfigRecord
import harness.codegraff.android.core.ConnectivitySnapshot
import harness.codegraff.android.core.ConnectivityState
import harness.codegraff.android.core.FolderListingRecord
import harness.codegraff.android.core.HarnessInfoRecord
import harness.codegraff.android.core.HostStatus as HostStatusRecord
import harness.codegraff.android.core.ModelInfoRecord
import harness.codegraff.android.core.RepoRefRecord
import harness.codegraff.android.demo.FolderEntry
import harness.codegraff.android.demo.FolderListing
import harness.codegraff.android.model.AgentDescriptor
import harness.codegraff.android.model.ChangeRequestState
import harness.codegraff.android.model.ChangeRequestSummary
import harness.codegraff.android.model.Connection
import harness.codegraff.android.model.ConnectivityUi
import harness.codegraff.android.model.HarnessInfo
import harness.codegraff.android.model.HostStatus
import harness.codegraff.android.model.ModelInfo
import harness.codegraff.android.model.ModelOptionChoiceInfo
import harness.codegraff.android.model.ModelOptionInfo
import harness.codegraff.android.model.RepoRef
import harness.codegraff.android.core.ChatRecord
import harness.codegraff.android.core.DeviceRecord
import harness.codegraff.android.core.MessageEntryRecord
import harness.codegraff.android.core.MessagePartRecord
import harness.codegraff.android.core.MessageRoleRecord
import harness.codegraff.android.core.MessageStatusRecord
import harness.codegraff.android.core.NewChatConfig
import harness.codegraff.android.core.QueueDeliveryGateRecord
import harness.codegraff.android.core.QueuedMessageRecord
import harness.codegraff.android.core.SessionRowRecord
import harness.codegraff.android.core.SessionStatusRecord
import harness.codegraff.android.core.SpaceRecord
import harness.codegraff.android.core.ToolFieldRecord
import harness.codegraff.android.core.UserInputQuestionRecord
import harness.codegraff.android.core.WorkspaceSnapshot
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.DeviceRow
import harness.codegraff.android.model.MessageEntry
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.MessageRole
import harness.codegraff.android.model.MessageStatus
import harness.codegraff.android.model.QueueDeliveryGate
import harness.codegraff.android.model.QueuedMessage
import harness.codegraff.android.model.RenderToolCall
import harness.codegraff.android.model.SessionRow
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.Space
import harness.codegraff.android.model.UserInputQuestion

// The native core's records onto the app's model types. The core has already applied iOS's projection rules (which
// rows count, defaults, order); this is only a change of types.

fun DeviceRecord.toModel() = DeviceRow(id, name, platform, lastSeenAt, createdAt, version, capabilities)

fun SpaceRecord.toModel() = Space(id, deviceId, path, name, gitDetected, createdAt)

fun ChatConfigRecord.toModel() = ChatConfig(harness, model, reasoning, modelOptions, sandbox)

fun ChatConfig.toNative() = NewChatConfig(harness, model, reasoning, modelOptions, sandbox)

fun ChatRecord.toModel() = Chat(
    id = id, deviceId = deviceId, title = title, archived = archived, cwd = cwd, branch = branch,
    config = config?.toModel(), lastMessagePreview = lastMessagePreview, lastMessageAt = lastMessageAt,
    createdAt = createdAt, spaceId = spaceId, lastSeenAt = lastSeenAt, lastPromptAt = lastPromptAt,
)

fun SessionStatusRecord.toModel() = when (this) {
    SessionStatusRecord.IDLE -> SessionStatus.Idle
    SessionStatusRecord.WORKING -> SessionStatus.Working
    SessionStatusRecord.AWAITING_INPUT -> SessionStatus.AwaitingInput
    SessionStatusRecord.ERRORED -> SessionStatus.Errored
}

fun SessionRowRecord.toModel() = SessionRow(chatId, deviceId, status.toModel(), startedAt, updatedAt)

/** The registry's view, as the parts [harness.codegraff.android.WorkspaceState] is built from. */
data class LiveWorkspace(
    val devices: List<DeviceRow>,
    val spaces: List<Space>,
    val chats: List<Chat>,
    val sessions: Map<String, SessionRow>,
    val pinnedSessionIds: List<String>,
    val presence: Map<String, Long>,
    val connected: Boolean,
    val synced: Boolean,
    val hostStatuses: Map<String, HostStatus>,
    val changeRequests: Map<String, ChangeRequestSummary>,
)

fun HostStatusRecord.toModel() = when (this) {
    HostStatusRecord.ONLINE -> HostStatus.Online
    HostStatusRecord.UNKNOWN -> HostStatus.Unknown
    HostStatusRecord.OFFLINE -> HostStatus.Offline
}

fun ChangeRequestRecord.toModel(): ChangeRequestSummary? {
    val state = when (state) {
        "open" -> ChangeRequestState.Open
        "closed" -> ChangeRequestState.Closed
        "merged" -> ChangeRequestState.Merged
        else -> return null
    }
    return ChangeRequestSummary(provider, number.toLong(), title, url, state, baseRef, headRef)
}

fun WorkspaceSnapshot.toModel() = LiveWorkspace(
    devices = devices.map { it.toModel() },
    spaces = spaces.map { it.toModel() },
    chats = chats.map { it.toModel() },
    sessions = sessions.associate { it.chatId to it.toModel() },
    pinnedSessionIds = pinnedSessionIds,
    presence = presence,
    connected = connected,
    synced = synced,
    hostStatuses = hostStatuses.mapValues { it.value.toModel() },
    changeRequests = changeRequests.mapNotNull { (id, pr) -> pr.toModel()?.let { id to it } }.toMap(),
)

fun ConnectivitySnapshot.toModel() = ConnectivityUi(
    state = when (state) {
        ConnectivityState.OFFLINE -> Connection.Offline
        ConnectivityState.RECONNECTING -> Connection.Reconnecting
        ConnectivityState.CONNECTED -> Connection.Connected
    },
    degradedChats = degradedChats.toSet(),
    retryAtMs = retryAtMs,
)

fun FolderListingRecord.toModel() = FolderListing(
    path = path,
    parent = if (!path.contains('/') || path == "/") null else path.substringBeforeLast('/').ifEmpty { "/" },
    entries = entries.map { FolderEntry(it.name, it.isDir, it.isRepo) },
    truncated = truncated,
)

fun RepoRefRecord.toModel() = RepoRef(name, current, worktreePath)

fun HarnessInfoRecord.toModel() = HarnessInfo(id, label)

fun AgentDescriptorRecord.toModel() = AgentDescriptor(id, installed, canInstall, enabled)

fun ModelInfoRecord.toModel() = ModelInfo(
    id = id,
    label = label,
    description = description,
    reasoningLevels = reasoningLevels,
    options = options.map { option ->
        ModelOptionInfo(option.id, option.label, option.choices.map { ModelOptionChoiceInfo(it.id, it.label) }, option.defaultChoice)
    },
)

private fun ToolFieldRecord.scalar(): String? = when (this) {
    is ToolFieldRecord.Text -> value
    is ToolFieldRecord.Flag -> value.toString()
    is ToolFieldRecord.Number -> value.toString()
    is ToolFieldRecord.Tasks, is ToolFieldRecord.Items -> null
}

private fun ToolFieldRecord.items(): List<String>? = when (this) {
    is ToolFieldRecord.Tasks -> items.map { item -> item.text }
    is ToolFieldRecord.Items -> items
    else -> null
}

private fun UserInputQuestionRecord.toModel() = UserInputQuestion(id, header, question, options, multiSelect)

fun MessagePartRecord.toModel(): MessagePart = when (this) {
    is MessagePartRecord.Text -> MessagePart.Text(id, text)
    is MessagePartRecord.Image -> MessagePart.Image(id, path, name, mimeType)
    is MessagePartRecord.Tool -> MessagePart.Tool(
        id,
        RenderToolCall(
            tag,
            fields.mapNotNull { (k, v) -> v.scalar()?.let { k to it } }.toMap(),
            fields.mapNotNull { (k, v) -> v.items()?.let { k to it } }.toMap(),
        ),
        isError,
        resolved,
    )
    is MessagePartRecord.Input -> MessagePart.Input(id, requestId, questions.map { it.toModel() }, resolved)
    is MessagePartRecord.Error -> MessagePart.Error(id, message)
}

fun MessageEntryRecord.toModel() = MessageEntry(
    id = id,
    role = when (role) {
        MessageRoleRecord.USER -> MessageRole.User
        MessageRoleRecord.ASSISTANT -> MessageRole.Assistant
        MessageRoleRecord.SYSTEM -> MessageRole.System
    },
    parts = parts.map { it.toModel() },
    createdAt = createdAt,
    deviceId = deviceId,
    status = when (status) {
        MessageStatusRecord.STREAMING -> MessageStatus.Streaming
        MessageStatusRecord.COMPLETE -> MessageStatus.Complete
        MessageStatusRecord.ABORTED -> MessageStatus.Aborted
        null -> null
    },
)

/**
 * A new transcript that keeps the previous list's entry objects where they did not change, so the row cache and the
 * lazy list skip them while a reply streams.
 */
fun List<MessageEntryRecord>.toModel(previous: List<MessageEntry>): List<MessageEntry> {
    val byId = previous.associateBy { it.id }
    return map { record ->
        val mapped = record.toModel()
        byId[mapped.id]?.takeIf { it == mapped } ?: mapped
    }
}

fun QueuedMessageRecord.toModel() = QueuedMessage(
    id = id,
    text = text,
    attachments = attachments,
    issuedBy = issuedBy,
    issuedAt = issuedAt,
    editedAt = editedAt,
    holdForTurnEnd = holdForTurnEnd,
    deliveryGate = when (val gate = deliveryGate) {
        is QueueDeliveryGateRecord.Editing -> QueueDeliveryGate.Editing(gate.ownerDeviceId, gate.expiresAtMs)
        is QueueDeliveryGateRecord.ReviewRequired -> QueueDeliveryGate.ReviewRequired(gate.ownerDeviceId)
        null -> null
    },
)
