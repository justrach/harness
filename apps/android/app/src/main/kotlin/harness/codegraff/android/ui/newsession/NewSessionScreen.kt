package harness.codegraff.android.ui.newsession

import androidx.compose.runtime.key
import harness.codegraff.android.model.DeviceCatalog
import harness.codegraff.android.model.ModelInfo
import harness.codegraff.android.model.modelSelection
import harness.codegraff.android.ui.components.CatalogLoad
import harness.codegraff.android.ui.components.rememberDeviceCatalog
import harness.codegraff.android.model.HostNotice

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppModel
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.CheckoutKind
import harness.codegraff.android.model.ChatConfig
import harness.codegraff.android.model.ChatMode
import harness.codegraff.android.model.HarnessCatalog
import harness.codegraff.android.model.NewSessionDestination
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.HarnessMark
import harness.codegraff.android.theme.LineIcon
import harness.codegraff.android.theme.LineIconView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.GlassCircleButton
import harness.codegraff.android.ui.rememberPref
import harness.codegraff.android.ui.session.CheckoutPickerSheet
import harness.codegraff.android.ui.session.ComposerChip
import harness.codegraff.android.ui.session.ComposerShell
import harness.codegraff.android.ui.session.ModelOptionPickerSheet
import harness.codegraff.android.ui.session.ModelPickerSheet
import harness.codegraff.android.ui.session.RefPickerSheet
import harness.codegraff.android.ui.session.StagedAttachment
import harness.codegraff.android.ui.session.TraitPickerSheet
import harness.codegraff.android.ui.sheets.SessionHostPickerSheet

/**
 * New session: a real composer page, not a form. The faded mark, "What are we building?" and a glass
 * composer with picker chips. The destination fixes a project or execution host; the composer carries
 * the agent/model chip, and sending mints the chat, starts the first run and swaps straight into the
 * live session (NewSessionView.swift).
 */
@Composable
fun NewSessionScreen(
    destination: NewSessionDestination,
    state: WorkspaceState,
    model: AppModel,
    showBack: Boolean,
    onBack: () -> Unit,
    onCreated: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = Theme.palette
    // Sticky run config (the old app persisted these to prefs.db).
    val harnessPref = rememberPref("newSessionHarness", "claude-code")
    val modelPref = rememberPref("newSessionModel", "")
    val reasoningPref = rememberPref("newSessionReasoning", "")
    // Chat mode keeps its own pick, so it never changes the coding defaults.
    val chatModelPref = rememberPref("newChatModel", "")
    val isChat = destination is NewSessionDestination.PlainChat

    var draft by rememberSaveable { mutableStateOf("") }
    var selectedHostId by rememberSaveable { mutableStateOf<String?>(null) }
    var showHostPicker by remember { mutableStateOf(false) }
    var showPicker by remember { mutableStateOf(false) }
    var showTraitPicker by remember { mutableStateOf(false) }
    var showRefPicker by remember { mutableStateOf(false) }
    var showCheckoutPicker by remember { mutableStateOf(false) }
    var attachments by remember { mutableStateOf(listOf<StagedAttachment>()) }

    val effective = when {
        destination is NewSessionDestination.Projectless && selectedHostId != null -> NewSessionDestination.Projectless(selectedHostId!!)
        destination is NewSessionDestination.PlainChat && selectedHostId != null -> NewSessionDestination.PlainChat(selectedHostId!!)
        else -> destination
    }
    val space = (effective as? NewSessionDestination.Project)?.let { d -> state.spaces.firstOrNull { it.id == d.spaceId } }
    val deviceId = when (effective) {
        is NewSessionDestination.Project -> space?.deviceId
        is NewSessionDestination.Projectless -> effective.deviceId
        is NewSessionDestination.PlainChat -> effective.deviceId
    }
    val contextLabel = when (effective) {
        is NewSessionDestination.Project -> space?.displayName ?: "Project unavailable"
        is NewSessionDestination.Projectless -> "No project"
        is NewSessionDestination.PlainChat -> "Chat"
    }
    val refreshKey = state.connected to deviceId?.let(state::hostStatus)
    val refContext = listOf(space?.deviceId, space?.id, space?.path, space?.gitDetected)
    var pickedRef by rememberSaveable(refContext) { mutableStateOf<String?>(null) }
    var checkoutKind by rememberSaveable(refContext) { mutableStateOf(CheckoutKind.Local) }
    val refLoad = rememberDeviceCatalog(refContext, refreshKey,
        initial = { space?.let(model::cachedRefs) ?: DeviceCatalog() },
        fetch = { space?.let { model.listRefs(it) } ?: DeviceCatalog(emptyList(), isLive = true) },
    )
    val refs = refLoad.catalog.items
    val selectedRef = pickedRef ?: (refs.firstOrNull { it.current } ?: refs.firstOrNull())?.name
    val selectedRefRow = refs.firstOrNull { it.name == selectedRef }
    val refUnavailable = refLoad.catalog.isLive && selectedRef != null && selectedRefRow == null

    // A chat runs on graff whatever the coding default is.
    val harness = if (isChat) ChatMode.HARNESS else harnessPref.value
    var optionPicker by remember(deviceId, harness, modelPref.value) { mutableStateOf<harness.codegraff.android.model.ModelOptionInfo?>(null) }
    val optionSelections = remember(deviceId, harness, modelPref.value) { mutableStateMapOf<String, String>() }
    val harnessLoad = rememberDeviceCatalog(deviceId, refreshKey,
        initial = { deviceId?.let(model::cachedHarnesses) ?: DeviceCatalog() },
        fetch = { deviceId?.let { model.listHarnesses(it) } ?: DeviceCatalog(emptyList(), isLive = true) },
    )
    val harnesses = harnessLoad.catalog.items
    // Load each offered agent rather than giving unopened sections fabricated static models.
    // A chat only needs graff's.
    val catalogLoads = mutableMapOf<String, CatalogLoad<ModelInfo>>()
    (listOf(harness) + if (isChat) emptyList() else harnesses.map { it.id }).distinct().forEach { agent ->
        key(deviceId, agent) {
            catalogLoads[agent] = rememberDeviceCatalog(deviceId to agent, refreshKey,
                initial = { deviceId?.let { model.cachedModels(it, agent) } ?: DeviceCatalog() },
                fetch = { deviceId?.let { model.listModels(it, agent) } ?: DeviceCatalog(emptyList(), isLive = true) },
            )
        }
    }
    // A chat offers the three auto tiers and nothing else, and keeps its own last pick.
    val chatAvailability = if (isChat) ChatMode.availability(catalogLoads.getValue(harness).catalog, harnessLoad.catalog) else null
    val selection = if (isChat) ChatMode.selection(chatModelPref.value, catalogLoads.getValue(harness).catalog, harnessLoad.catalog)
    else modelSelection(harness, modelPref.value, reasoningPref.value, catalogLoads.getValue(harness).catalog, harnessLoad.catalog)
    val selectedModel = selection.model
    val reasoning = selection.reasoning

    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) { uris: List<Uri> ->
        attachments = attachments + uris.map { StagedAttachment(it.toString(), it.lastPathSegment ?: "Photo", it) }
    }
    val hostUnavailable = state.synced && state.executionDevices.none { it.id == deviceId }
    val selectionReady = deviceId != null && !hostUnavailable && selection.canSend && !refUnavailable
    val canSend = selectionReady && (draft.trim().isNotEmpty() || attachments.isNotEmpty())

    fun send() {
        val device = deviceId ?: return
        if (!canSend) return
        val prompt = draft.trim().ifEmpty { "Look at the attached photos." }
        // Only non-default picks ride the run, matching the desktop picker.
        val options = selectedModel.options.mapNotNull { option ->
            val choice = HarnessCatalog.selectedChoice(option, optionSelections[option.id])
            if (choice.id != option.defaultChoice) option.id to choice.id else null
        }.toMap()
        val config = ChatConfig(harness, selectedModel.id, reasoning, options, "workspace-write", chatMode = isChat)
        val chatId = if (space != null) {
            // A New-worktree plan rides the queued run as a spec the HOST materializes, so an offline send never blocks.
            val cwd = if (checkoutKind == CheckoutKind.NewWorktree) space.path else selectedRefRow?.worktreePath
            model.createChat(space, config, selectedRef, cwd)
        } else {
            model.createProjectlessChat(device, config)
        }
        model.send(chatId, prompt)
        draft = ""
        attachments = emptyList()
        onCreated(chatId)
    }

    Column(modifier.fillMaxSize().background(p.bg).imePadding().navigationBarsPadding()) {
        // Canvas: tap dismisses the keyboard, like the old app.
        val focus = androidx.compose.ui.platform.LocalFocusManager.current
        Box(
            Modifier.weight(1f).fillMaxWidth().background(p.bg)
                .pointerInput(Unit) { detectTapGestures { focus.clearFocus() } },
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                Box(Modifier.alpha(0.22f)) { HarnessMark(84.dp) }
                Text(if (isChat) "What's on your mind?" else "What are we building?", style = sans(15f), color = p.textFaint)
            }
            // Header: back + "New session" over the device it will run on.
            Row(
                Modifier.align(Alignment.TopStart).fillMaxWidth().statusBarsPadding().padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (showBack) GlassCircleButton(onBack, "Back") { GlyphView(Glyph.ChevronLeft, 20.dp, p.text, strokeWidth = 2.4f) }
                Column(Modifier.padding(start = if (showBack) 0.dp else 8.dp), verticalArrangement = Arrangement.spacedBy(1.dp)) {
                    Text("New session", style = sans(13f, FontWeight.Medium), color = p.text)
                    Text(
                        if (deviceId != null) "$contextLabel · ${state.deviceName(deviceId)}" else contextLabel,
                        style = sans(10.5f), color = p.textMuted.opacity(0.6f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }

        if (effective is NewSessionDestination.Projectless || effective is NewSessionDestination.PlainChat) {
            Box(
                Modifier.fillMaxWidth().padding(bottom = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Row(
                    Modifier.height(48.dp).clip(CircleShape).clickable(role = Role.Button) { showHostPicker = true }.padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    GlyphView(Glyph.Monitor, 16.dp, p.text, strokeWidth = 1.8f)
                    Text(deviceId?.let(state::deviceName) ?: "Select a device", style = sans(13f, FontWeight.Medium), color = p.text)
                }
            }
        }

        // Where-it-runs scope row (checkout + base ref), left-aligned above the composer.
        if (space?.gitDetected == true) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                val checkoutLabel = when (checkoutKind) {
                    CheckoutKind.NewWorktree -> "New worktree"
                    CheckoutKind.Local -> if (selectedRefRow?.worktreePath != null) "Current worktree" else "Current checkout"
                }
                val checkoutIcon = if (checkoutKind == CheckoutKind.Local && selectedRefRow?.worktreePath == null) LineIcon.Folder else LineIcon.FolderWithFiles
                ScopeChip(checkoutIcon, checkoutLabel) { showCheckoutPicker = true }
                val refLabel = selectedRef?.let { if (checkoutKind == CheckoutKind.NewWorktree) "From $it" else it } ?: "Select ref"
                ScopeChip(LineIcon.GitBranch, refLabel) { showRefPicker = true }
            }
        }

        // Only what is true: a phone that is not connected, or a computer that is positively gone.
        deviceId?.let { id -> model.hostNotice(id) }?.let { notice ->
            val name = state.deviceName(deviceId!!)
            Text(
                when (notice) {
                    HostNotice.SignedOut -> "You're signed out — tap to sign in again."
                    HostNotice.Reconnecting -> "Reconnecting — $name's status will show once you're connected."
                    HostNotice.Offline -> "$name is offline — the run will start when it reconnects."
                },
                style = sans(12f), color = p.warning.opacity(0.9f),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 8.dp)
                    .background(p.warning.opacity(0.1f), RoundedCornerShape(12.dp)).padding(horizontal = 14.dp, vertical = 8.dp),
            )
        }
        if ((deviceId != null && hostUnavailable) || selection.unavailable || refUnavailable) {
            Text(
                when {
                    hostUnavailable -> "The selected device is no longer available. Select another device."
                    refUnavailable -> "The selected ref is no longer available. Select another ref."
                    isChat -> ChatMode.UNAVAILABLE_NOTE
                    else -> "The selected agent or model is not available on this device. Select another model."
                },
                style = sans(12f), color = p.warning,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp),
            )
        }
        if (isChat) ChatMode.note(selectedModel.id)?.let { note ->
            Text(
                note, style = sans(12f), color = p.textMuted,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 6.dp).testTag("chat-mode-note"),
            )
        }
        ComposerShell(
            draft = draft, onDraftChange = { draft = it },
            placeholder = if (isChat) "Ask anything…" else "Do anything…", sendEnabled = selectionReady, showStop = false,
            alwaysExpanded = true, onSend = ::send,
            modifier = Modifier.padding(bottom = 8.dp),
            attachments = attachments,
            onAttach = { photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
            onRemoveAttachment = { id -> attachments = attachments.filterNot { it.id == id } },
        ) {
            // Model + trait chips, split like the desktop's footer pickers.
            ComposerChip(selectedModel.label, badgeHarness = harness) { showPicker = true }
            reasoning?.let { ComposerChip(HarnessCatalog.reasoningLabel(it)) { showTraitPicker = true } }
            selectedModel.options.forEach { option ->
                ComposerChip(HarnessCatalog.selectedChoice(option, optionSelections[option.id]).label) { optionPicker = option }
            }
        }
    }

    if (showPicker) {
        if (isChat) {
            ModelPickerSheet(
                harness = harness, modelId = selectedModel.id, reasoning = null, lockedHarness = true,
                harnesses = harnesses, catalogs = mapOf(harness to ChatMode.models(catalogLoads.getValue(harness).catalog.items)),
                loading = chatAvailability == ChatMode.Availability.Pending,
                confirmedHarnesses = harnessLoad.catalog.isLive,
                confirmedCatalogs = catalogLoads.filterValues { it.catalog.isLive }.keys,
                onRetry = { harnessLoad.retry(); catalogLoads.values.forEach { it.retry() } },
                onPick = { _, picked, _ -> chatModelPref.set(picked.id) },
                onDismiss = { showPicker = false },
            )
        } else {
            ModelPickerSheet(
                harness = harness, modelId = selectedModel.id, reasoning = reasoning, lockedHarness = false,
                harnesses = harnesses, catalogs = catalogLoads.mapValues { it.value.catalog.items },
                loading = harnessLoad.loading || catalogLoads.values.any { it.loading },
                confirmedHarnesses = harnessLoad.catalog.isLive,
                confirmedCatalogs = catalogLoads.filterValues { it.catalog.isLive }.keys,
                onRetry = { harnessLoad.retry(); catalogLoads.values.forEach { it.retry() } },
                onPick = { h, picked, r -> harnessPref.set(h); modelPref.set(picked.id); reasoningPref.set(r ?: "") },
                onDismiss = { showPicker = false },
            )
        }
    }
    if (showTraitPicker) TraitPickerSheet(reasoning, selectedModel.reasoningLevels, { reasoningPref.set(it) }) { showTraitPicker = false }
    optionPicker?.let { option ->
        ModelOptionPickerSheet(option, HarnessCatalog.selectedChoice(option, optionSelections[option.id]).id, { optionSelections[option.id] = it }) { optionPicker = null }
    }
    if (showRefPicker) {
        RefPickerSheet(refs, selectedRef, loading = refLoad.loading, confirmed = refLoad.catalog.isLive, onRetry = refLoad::retry, onPick = { row ->
            pickedRef = row.name
            if (row.worktreePath != null) checkoutKind = CheckoutKind.Local
        }) { showRefPicker = false }
    }
    if (showCheckoutPicker) {
        CheckoutPickerSheet(checkoutKind, selectedRefRow?.worktreePath != null, { kind ->
            // Dropping back to Local with a plain non-current ref picked drops the pick: the current branch takes over.
            if (kind == CheckoutKind.Local && checkoutKind == CheckoutKind.NewWorktree && selectedRefRow != null &&
                selectedRefRow.worktreePath == null && !selectedRefRow.current
            ) pickedRef = refs.firstOrNull { it.current }?.name
            checkoutKind = kind
        }) { showCheckoutPicker = false }
    }
    if (showHostPicker) {
        SessionHostPickerSheet(state, deviceId, onSelected = { selectedHostId = it }) { showHostPicker = false }
    }
}

@Composable
private fun ScopeChip(icon: LineIcon, label: String, onClick: () -> Unit) {
    val p = Theme.palette
    Row(
        Modifier.height(40.dp).clip(CircleShape).background(p.ink(0.08f), CircleShape).border(1.dp, p.hairline(0.08f), CircleShape)
            .clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LineIconView(icon, 13.dp, p.textMuted)
        Text(label, style = sans(13f, FontWeight.Medium), color = p.text.opacity(0.9f), maxLines = 1)
    }
}
