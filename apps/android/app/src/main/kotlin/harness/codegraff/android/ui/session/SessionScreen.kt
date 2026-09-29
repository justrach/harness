package harness.codegraff.android.ui.session

import harness.codegraff.android.model.ChatGPTSignIn
import harness.codegraff.android.ui.signin.PlanUsageLine
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import harness.codegraff.android.model.MessageQueue
import harness.codegraff.android.model.QueueComposerEdit
import harness.codegraff.android.model.QueueEditFinishResult
import harness.codegraff.android.model.QueueEditStartResult
import harness.codegraff.android.model.QueuedMessage
import java.util.UUID
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppModel
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.HarnessCatalog
import harness.codegraff.android.model.MessagePart
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.TranscriptBuilderCache
import androidx.compose.runtime.collectAsState
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.Motion
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.BranchContextChip
import harness.codegraff.android.ui.components.GlassCircleButton
import harness.codegraff.android.ui.components.rememberHaptics
import harness.codegraff.android.ui.components.statusBarHeight
import harness.codegraff.android.ui.components.HarnessPulse
import harness.codegraff.android.ui.components.PullRequestBadge
import harness.codegraff.android.ui.components.PullRequestBadgeSurface
import harness.codegraff.android.ui.components.TranscriptSkeleton
import harness.codegraff.android.ui.components.WorkingSpinner
import harness.codegraff.android.ui.components.glass
import harness.codegraff.android.ui.home.SessionSwitcherPill
import harness.codegraff.android.ui.home.projectLocation
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Session screen: transcript, status strip and composer (or the question panel while input is
 * requested, replacing the composer like the desktop). Reading marks the chat seen (the synced
 * marker behind the green dot everywhere) (SessionView.swift).
 */
@Composable
fun SessionScreen(
    chatId: String,
    state: WorkspaceState,
    model: AppModel,
    showBack: Boolean,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = Theme.palette
    val chat = state.chat(chatId)
    if (chat == null) {
        Column(modifier.fillMaxSize().background(p.bg), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            HarnessPulse()
            Text("Opening session…", style = sans(12f), color = p.textFaint, modifier = Modifier.padding(top = 12.dp))
        }
        return
    }
    LaunchedEffect(chatId) { model.markSeen(chatId) }
    DisposableEffect(chatId) { onDispose { model.markSeen(chatId) } }

    val status = state.liveStatus(chat)
    // This session's transcript is its own flow: a streamed token recomposes this screen, not Home.
    val entries by remember(chatId) { model.entriesFlow(chatId) }.collectAsState(initial = model.entries(chatId))
    // Owned per session so settled parts parse once and unchanged rows keep their identity.
    val cache = remember(chatId) { TranscriptBuilderCache() }
    val veils = remember(chatId) { VeilStore() }
    val rows = remember(entries) { cache.rows(entries) }
    val tall = LocalConfiguration.current.screenHeightDp >= 480
    val haptics = rememberHaptics()
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val topInset = statusBarHeight()
    val jumpVisible by remember { derivedStateOf { listState.firstVisibleItemIndex > 1 } }
    val openRequest = entries.asReversed().flatMap { it.parts }.filterIsInstance<MessagePart.Input>().firstOrNull { !it.resolved }

    Box(modifier.fillMaxSize().background(p.bg)) {
        Column(Modifier.fillMaxSize().imePadding().navigationBarsPadding()) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                TranscriptView(
                    rows, listState,
                    contentPadding = PaddingValues(top = topInset + 56.dp, bottom = if (tall) 24.dp else 8.dp),
                    veils = veils,
                )
                if (rows.isEmpty() && chat.lastMessageAt != null) {
                    Box(Modifier.fillMaxSize().background(p.bg)) { TranscriptSkeleton() }
                }
                // Bottom-right, clear of the centered jump-to-latest button.
                SessionSwitcherPill(state, current = chat.id, compact = true, modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp))
                androidx.compose.animation.AnimatedVisibility(jumpVisible, Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp), enter = fadeIn(), exit = fadeOut()) {
                    GlassCircleButton({ haptics.light(); scope.launch { listState.animateScrollToItem(0) } }, "Jump to latest", size = 40.dp) {
                        androidx.compose.foundation.layout.Box(Modifier.rotate(180f)) { GlyphView(Glyph.ArrowUp, 18.dp, p.text, strokeWidth = 2.2f) }
                    }
                }
            }
            // The composer owns real layout space: the transcript's viewport ends above it.
            Column(
                Modifier.drawBehind {
                    val extra = 24.dp.toPx()
                    drawRect(
                        Brush.verticalGradient(
                            0f to p.bg.opacity(0f), 0.25f to p.bg.opacity(0.45f), 0.6f to p.bg.opacity(0.72f), 1f to p.bg,
                            startY = -extra, endY = size.height,
                        ),
                        topLeft = Offset(0f, -extra), size = Size(size.width, size.height + extra),
                    )
                },
            ) {
                val sendState = false // sends are local in demo mode
                if (tall || status == SessionStatus.Working || status == SessionStatus.Errored || sendState) {
                    StatusStrip(chat, status, state)
                }
                Box(Modifier.padding(bottom = 8.dp)) {
                    if (openRequest != null) {
                        QuestionPanel(openRequest.requestId, openRequest.questions) { id, answers -> model.respondInput(chat.id, id, answers) }
                    } else {
                        ChatComposer(state, model, chat, runLive = status == SessionStatus.Working)
                    }
                }
            }
        }

        // The bar stays opaque so the header never collides with rows scrolling under it; the fade lives just below the bar.
        Column(Modifier.fillMaxWidth()) {
            Box(Modifier.fillMaxWidth().height(topInset + 52.dp).background(p.bg))
            Box(
                Modifier.fillMaxWidth().height(28.dp).background(
                    Brush.verticalGradient(0f to p.bg, 0.35f to p.bg.opacity(0.85f), 0.7f to p.bg.opacity(0.45f), 1f to Color.Transparent),
                ),
            )
        }
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (showBack) {
                GlassCircleButton(onBack, "Back") { GlyphView(Glyph.ChevronLeft, 20.dp, p.text, strokeWidth = 2.4f) }
            }
            Column(Modifier.weight(1f).padding(start = if (showBack) 0.dp else 8.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(chat.displayTitle, style = sans(15f, FontWeight.Medium), color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(projectLocation(chat, state), style = sans(12f), color = p.textMuted.opacity(0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/**
 * Reserved 24dp status strip (shell.rs render_status_strip): Working shows the sunrise spinner,
 * a rotating flavour word and the elapsed time; Errored shows "Run failed". The strip always
 * reserves its height so the composer never shifts.
 */
@Composable
private fun StatusStrip(chat: Chat, status: SessionStatus?, state: WorkspaceState) {
    val p = Theme.palette
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(status) {
        while (status == SessionStatus.Working) { now = System.currentTimeMillis(); delay(1000) }
    }
    Row(
        Modifier.fillMaxWidth().height(24.dp).padding(start = 26.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        when (status) {
            SessionStatus.Working -> {
                WorkingSpinner()
                val row = state.sessions[chat.id]
                val startedAt = row?.startedAt ?: row?.updatedAt ?: now
                val elapsed = (now - startedAt) / 1000
                Text("${Motion.flavourWord(Motion.flavourSeed(chat.id), elapsed)}…", style = sans(12f), color = p.textMuted)
                Text(Motion.formatElapsed(elapsed), style = sans(11f), color = p.textFaint)
            }
            SessionStatus.Errored -> Text("Run failed", style = sans(11f), color = p.danger)
            else -> {}
        }
    }
}

/** The live-chat composer: input, the photo attach button, the model and trait chips (harness stays locked mid-chat), and the morphing action button. */
@Composable
private fun ChatComposer(state: WorkspaceState, model: AppModel, chat: Chat, runLive: Boolean) {
    val clipboard = LocalClipboardManager.current
    var draft by rememberSaveable(chat.id) { mutableStateOf("") }
    var attachments by remember(chat.id) { mutableStateOf(listOf<StagedAttachment>()) }
    var showModelPicker by remember { mutableStateOf(false) }
    var showTraitPicker by remember { mutableStateOf(false) }
    var optionPicker by remember { mutableStateOf<harness.codegraff.android.model.ModelOptionInfo?>(null) }

    val harness = chat.config?.harness ?: "claude-code"
    val models = HarnessCatalog.models(harness)
    val currentModel = HarnessCatalog.resolve(chat.config?.model, models, harness)
    val currentReasoning = if (currentModel.reasoningLevels.isEmpty()) null
    else chat.config?.reasoning?.takeIf { it in currentModel.reasoningLevels } ?: HarnessCatalog.defaultReasoning(currentModel)

    // The chat's queue: what was typed mid-turn waits here, and a row can be retyped in this composer.
    val queue by remember(chat.id) { model.queueFlow(chat.id) }.collectAsState(initial = model.queue(chat.id))
    val scope = rememberCoroutineScope()
    var edit by remember(chat.id) { mutableStateOf<QueueComposerEdit?>(null) }
    var editBusy by remember(chat.id) { mutableStateOf(false) }
    var notice by remember(chat.id) { mutableStateOf<String?>(null) }
    val instanceId = remember(chat.id) { UUID.randomUUID().toString().lowercase() }
    val editingId = edit?.lease?.rowId

    fun finishLocalEdit(result: QueueEditFinishResult, failure: String) {
        edit = edit?.receive(result)
        when (result) {
            QueueEditFinishResult.Finished -> { draft = edit?.originalDraft ?: ""; edit = null; notice = null }
            QueueEditFinishResult.Conflict -> notice = "This message changed on another device; your edit is still here."
            QueueEditFinishResult.Missing -> notice = "Message removed. Stop editing to copy your text and restore your draft."
            QueueEditFinishResult.Lost -> notice = "Edit protection changed. Stop editing to copy your text and restore your draft."
            QueueEditFinishResult.Unavailable -> notice = failure
        }
    }

    /** Retype a queued message in the composer. Whatever was already in the box steps aside rather than being lost. */
    fun beginEdit(item: QueuedMessage) {
        if (edit != null || editBusy) return
        scope.launch {
            editBusy = true
            val result = model.beginQueuedEdit(chat.id, item.id, instanceId)
            editBusy = false
            when (result) {
                is QueueEditStartResult.Acquired -> {
                    edit = QueueComposerEdit(result.lease, originalDraft = draft, hasAttachments = item.attachments.isNotEmpty())
                    draft = MessageQueue.visibleText(result.lease.text, item.attachments)
                    notice = null
                }
                QueueEditStartResult.Locked -> notice = "That queued message is being edited on another device."
                QueueEditStartResult.Missing -> notice = "That queued message is no longer available."
                QueueEditStartResult.Unavailable -> notice = "Connect to the chat host to edit this message."
            }
        }
    }

    fun cancelEdit() {
        val lease = edit?.lease ?: return
        if (editBusy) return
        scope.launch {
            editBusy = true
            val result = model.finishQueuedEdit(chat.id, lease, "cancel")
            editBusy = false
            finishLocalEdit(result, "Couldn't cancel the protected edit.")
        }
    }

    fun commitEdit() {
        val lease = edit?.lease ?: return
        if (editBusy) return
        val edited = edit?.textToCommit(draft)
        scope.launch {
            editBusy = true
            val result = if (edited != null) model.finishQueuedEdit(chat.id, lease, "commit", edited)
            else model.finishQueuedEdit(chat.id, lease, "discard")
            editBusy = false
            finishLocalEdit(result, "Couldn't save the protected edit.")
        }
    }

    // The host holds the row for a minute at a time, so a long edit renews its lease.
    LaunchedEffect(edit?.lease?.leaseId, edit?.terminal) {
        val lease = edit?.lease ?: return@LaunchedEffect
        if (edit?.terminal == true) return@LaunchedEffect
        while (edit?.lease?.leaseId == lease.leaseId) {
            delay(20_000)
            if (!model.renewQueuedEdit(chat.id, lease)) notice = "Edit protection may have expired — review before sending."
        }
    }
    // Leaving the screen mid-edit puts the original draft back and releases the row.
    DisposableEffect(chat.id) {
        onDispose {
            val current = edit ?: return@onDispose
            draft = current.originalDraft
            model.cancelQueuedEditInBackground(chat.id, current.lease)
        }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) { uris: List<Uri> ->
        attachments = attachments + uris.map { StagedAttachment(it.toString(), it.lastPathSegment ?: "Photo", it) }
    }

    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        (notice ?: queue.error)?.let { message ->
            Text(
                message, style = sans(12f), color = Theme.palette.danger, maxLines = 2,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp),
            )
        }
        // What is waiting to be sent, stacked directly above the box it was typed in.
        if (queue.rows.isNotEmpty()) {
            QueuePanel(
                queue, editingId, supportsActions = true,
                onEdit = ::beginEdit, onCancelEdit = ::cancelEdit,
                onAction = { item, action -> scope.launch { model.performQueueAction(chat.id, item.id, action) } },
                onMove = { id, to -> model.moveQueued(chat.id, id, to) },
                onMoveBy = { id, direction -> model.moveQueuedBy(chat.id, id, direction) },
            )
        }
        if (editingId != null) {
            val dead = edit?.terminal == true
            Box(
                Modifier.padding(horizontal = 24.dp).heightIn(min = 44.dp)
                    .clickable(enabled = !editBusy, role = Role.Button) {
                        if (dead) {
                            clipboard.setText(AnnotatedString(draft))
                            finishLocalEdit(QueueEditFinishResult.Finished, "")
                        } else cancelEdit()
                    },
                contentAlignment = Alignment.CenterStart,
            ) { Text(if (dead) "Copy edit and stop editing" else "Stop editing", style = sans(12f), color = Theme.palette.textMuted) }
        }
        // OpenAI asks for this wherever requests run on the person's ChatGPT plan.
        if (ChatGPTSignIn.usesPlan(chat.config?.model)) PlanUsageLine(Modifier.padding(horizontal = 24.dp))
        ComposerShell(
            draft = draft, onDraftChange = { draft = it },
            sendEnabled = true, showStop = runLive,
            placeholder = if (editingId == null) "Message" else "Edit queued message",
            sendLabel = when {
                editingId != null -> "Save queued message"
                runLive -> "Queue message"
                else -> "Send message"
            },
            allowEmptySend = editingId != null,
            busy = editBusy,
            keepExpanded = showModelPicker || showTraitPicker || optionPicker != null,
            onSend = {
                if (editingId != null) {
                    commitEdit()
                } else {
                    model.send(chat.id, draft, attachments.map { it.uri.toString() })
                    draft = ""
                    attachments = emptyList()
                }
            },
            onStop = { model.interrupt(chat.id) },
            attachments = if (editingId == null) attachments else emptyList(),
            onAttach = if (editingId == null) ({ picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) else null,
            onRemoveAttachment = { id -> attachments = attachments.filterNot { it.id == id } },
        ) {
            state.changeRequest(chat)?.let { PullRequestBadge(it, surface = PullRequestBadgeSurface.Composer) }
            chat.branch?.trim()?.takeIf { it.isNotEmpty() }?.let { BranchContextChip(it) }
            ComposerChip(currentModel.label, badgeHarness = harness) { showModelPicker = true }
            currentReasoning?.let { ComposerChip(HarnessCatalog.reasoningLabel(it)) { showTraitPicker = true } }
            currentModel.options.forEach { option ->
                ComposerChip(HarnessCatalog.selectedChoice(option, chat.config?.modelOptions?.get(option.id)).label) { optionPicker = option }
            }
        }
    }

    if (showModelPicker) {
        ModelPickerSheet(
            harness = harness, modelId = currentModel.id, reasoning = chat.config?.reasoning,
            lockedHarness = true, harnesses = emptyList(), catalogs = emptyMap(),
            onPick = { _, picked, reasoning -> model.setChatConfig(chat.id, picked.id, reasoning) },
            onDismiss = { showModelPicker = false },
        )
    }
    if (showTraitPicker) {
        TraitPickerSheet(currentReasoning, currentModel.reasoningLevels, { model.setChatConfig(chat.id, chat.config?.model, it) }) { showTraitPicker = false }
    }
    optionPicker?.let { option ->
        ModelOptionPickerSheet(
            option, HarnessCatalog.selectedChoice(option, chat.config?.modelOptions?.get(option.id)).id,
            { choice ->
                val merged = (chat.config?.modelOptions ?: emptyMap()) + (option.id to choice)
                model.setChatConfig(chat.id, chat.config?.model, chat.config?.reasoning, merged)
            },
        ) { optionPicker = null }
    }
}
