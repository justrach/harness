package harness.codegraff.android.ui.newsession

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppModel
import harness.codegraff.android.AppState
import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.model.CheckoutKind
import harness.codegraff.android.model.ChatConfig
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
    state: AppState,
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

    var draft by rememberSaveable { mutableStateOf("") }
    var selectedHostId by rememberSaveable { mutableStateOf<String?>(null) }
    var showHostPicker by remember { mutableStateOf(false) }
    var showPicker by remember { mutableStateOf(false) }
    var showTraitPicker by remember { mutableStateOf(false) }
    var optionPicker by remember { mutableStateOf<harness.codegraff.android.model.ModelOptionInfo?>(null) }
    var showRefPicker by remember { mutableStateOf(false) }
    var showCheckoutPicker by remember { mutableStateOf(false) }
    var attachments by remember { mutableStateOf(listOf<StagedAttachment>()) }
    val optionSelections = remember { mutableStateMapOf<String, String>() }
    var selectedRef by rememberSaveable { mutableStateOf<String?>(null) }
    var checkoutKind by rememberSaveable { mutableStateOf(CheckoutKind.Local) }

    val effective = if (destination is NewSessionDestination.Projectless && selectedHostId != null) {
        NewSessionDestination.Projectless(selectedHostId!!)
    } else destination
    val space = (effective as? NewSessionDestination.Project)?.let { d -> state.spaces.firstOrNull { it.id == d.spaceId } }
    val deviceId = when (effective) {
        is NewSessionDestination.Project -> space?.deviceId
        is NewSessionDestination.Projectless -> effective.deviceId
    }
    val contextLabel = when (effective) {
        is NewSessionDestination.Project -> space?.displayName ?: "Project unavailable"
        is NewSessionDestination.Projectless -> "No project"
    }
    val refs = remember(space?.path) { space?.takeIf { it.gitDetected }?.let { DemoDataset.listRefs(it.path) }.orEmpty() }
    if (selectedRef == null && refs.isNotEmpty()) selectedRef = (refs.firstOrNull { it.current } ?: refs.first()).name
    val selectedRefRow = refs.firstOrNull { it.name == selectedRef }

    val harness = harnessPref.value
    val harnesses = HarnessCatalog.harnesses
    val models = HarnessCatalog.models(harness)
    val selectedModel = HarnessCatalog.resolveExisting(modelPref.value, models) ?: models.firstOrNull() ?: HarnessCatalog.defaultModel(harness)
    val reasoning = if (selectedModel.reasoningLevels.isEmpty()) null
    else reasoningPref.value.takeIf { it in selectedModel.reasoningLevels } ?: HarnessCatalog.defaultReasoning(selectedModel)

    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) { uris: List<Uri> ->
        attachments = attachments + uris.map { StagedAttachment(it.toString(), it.lastPathSegment ?: "Photo", it) }
    }
    val canSend = deviceId != null && (draft.trim().isNotEmpty() || attachments.isNotEmpty())

    fun send() {
        val device = deviceId ?: return
        if (!canSend) return
        val prompt = draft.trim().ifEmpty { "Look at the attached photos." }
        // Only non-default picks ride the run, matching the desktop picker.
        val options = selectedModel.options.mapNotNull { option ->
            val choice = HarnessCatalog.selectedChoice(option, optionSelections[option.id])
            if (choice.id != option.defaultChoice) option.id to choice.id else null
        }.toMap()
        val config = ChatConfig(harness, selectedModel.id, reasoning, options, "workspace-write")
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
        Box(
            Modifier.weight(1f).fillMaxWidth().background(p.bg),
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(24.dp)) {
                Box(Modifier.alpha(0.22f)) { HarnessMark(84.dp) }
                Text("What are we building?", style = sans(15f), color = p.textFaint)
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

        if (effective is NewSessionDestination.Projectless) {
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

        ComposerShell(
            draft = draft, onDraftChange = { draft = it },
            placeholder = "Do anything…", sendEnabled = deviceId != null, showStop = false,
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
        ModelPickerSheet(
            harness = harness, modelId = selectedModel.id, reasoning = reasoning, lockedHarness = false,
            harnesses = harnesses, catalogs = emptyMap(),
            onPick = { h, picked, r -> harnessPref.set(h); modelPref.set(picked.id); reasoningPref.set(r ?: "") },
            onDismiss = { showPicker = false },
        )
    }
    if (showTraitPicker) TraitPickerSheet(reasoning, selectedModel.reasoningLevels, { reasoningPref.set(it) }) { showTraitPicker = false }
    optionPicker?.let { option ->
        ModelOptionPickerSheet(option, HarnessCatalog.selectedChoice(option, optionSelections[option.id]).id, { optionSelections[option.id] = it }) { optionPicker = null }
    }
    if (showRefPicker) {
        RefPickerSheet(refs, selectedRef, onPick = { row ->
            selectedRef = row.name
            if (row.worktreePath != null) checkoutKind = CheckoutKind.Local
        }) { showRefPicker = false }
    }
    if (showCheckoutPicker) {
        CheckoutPickerSheet(checkoutKind, selectedRefRow?.worktreePath != null, { kind ->
            // Dropping back to Local with a plain non-current ref picked drops the pick: the current branch takes over.
            if (kind == CheckoutKind.Local && checkoutKind == CheckoutKind.NewWorktree && selectedRefRow != null &&
                selectedRefRow.worktreePath == null && !selectedRefRow.current
            ) selectedRef = refs.firstOrNull { it.current }?.name
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
