package harness.codegraff.android.ui.session

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.model.HarnessCatalog
import harness.codegraff.android.model.HarnessInfo
import harness.codegraff.android.model.ModelInfo
import harness.codegraff.android.model.ModelOptionInfo
import harness.codegraff.android.model.RepoRef
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.HarnessBadge
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.HarnessSheet
import harness.codegraff.android.ui.components.PickRow
import harness.codegraff.android.ui.components.SheetBody
import harness.codegraff.android.ui.components.SheetLabel
import kotlinx.coroutines.launch

/**
 * The model picker: one scrolling list of models sectioned per harness (collapsible uppercase
 * provider headers with the brand mark; picking a model picks its harness), the selected row a
 * filled high-contrast pill with a trailing check. Effort lives in its own sheet, split like the
 * desktop's footer pickers. Sections collapse to one once a chat exists, since harness is locked
 * mid-chat (NewSessionView.swift ModelPickerSheet).
 */
@Composable
fun ModelPickerSheet(
    harness: String,
    modelId: String,
    reasoning: String?,
    lockedHarness: Boolean,
    harnesses: List<HarnessInfo>,
    catalogs: Map<String, List<ModelInfo>>,
    onPick: (harness: String, model: ModelInfo, reasoning: String?) -> Unit,
    onDismiss: () -> Unit,
) {
    val p = Theme.palette
    fun models(h: String) = catalogs[h] ?: HarnessCatalog.models(h)
    val sections = if (lockedHarness) listOf(HarnessInfo(harness, HarnessCatalog.label(harness)))
    else harnesses.ifEmpty { HarnessCatalog.harnesses }
    // Accordion state: which harness sections show their models. Seeded with the current harness.
    var open by rememberSaveable { mutableStateOf(setOf(harness)) }
    HarnessSheet("Select model", onDismiss) {
        SheetBody {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SheetLabel("Model")
                sections.forEach { h ->
                    if (sections.size > 1) SectionHeader(h, open = h.id in open, count = models(h.id).size) {
                        open = if (h.id in open) open - h.id else open + h.id
                    }
                    if (sections.size == 1 || h.id in open) {
                        models(h.id).forEach { m ->
                            PickRow(m.label, selected = harness == h.id && m.id == modelId, subtitle = m.description) {
                                val keep = reasoning?.takeIf { it in m.reasoningLevels }
                                onPick(h.id, m, keep ?: HarnessCatalog.defaultReasoning(m))
                            }
                        }
                    }
                }
            }
        }
    }
}

/** t3's collapsible ProviderHeader: brand mark, tracked-out uppercase name, trailing count and chevron. */
@Composable
private fun SectionHeader(h: HarnessInfo, open: Boolean, count: Int, toggle: () -> Unit) {
    val p = Theme.palette
    Row(
        Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = toggle)
            .semantics { stateDescription = if (open) "Expanded" else "Collapsed" }
            .padding(start = 4.dp, end = 4.dp, top = 12.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        HarnessBadge(h.id, 13.dp)
        Text(h.label.uppercase(), style = sans(10.5f, FontWeight.Medium).copy(letterSpacing = 1.2.sp), color = p.textMuted.opacity(0.7f))
        Spacer(Modifier.weight(1f))
        if (!open) Text("$count", style = sans(10.5f), color = p.textFaint)
        GlyphView(if (open) Glyph.ChevronUp else Glyph.ChevronDown, 10.dp, p.textFaint, strokeWidth = 3f)
    }
}

/** The effort ladder in its own sheet: the composer's second picker chip, split from the model list like the desktop's Traits dropdown. */
@Composable
fun TraitPickerSheet(reasoning: String?, levels: List<String>, onPick: (String) -> Unit, onDismiss: () -> Unit) {
    HarnessSheet("Traits", onDismiss) {
        SheetBody {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SheetLabel("Effort")
                levels.forEach { level ->
                    PickRow(HarnessCatalog.reasoningLabel(level), selected = reasoning == level, subtitle = HarnessCatalog.effortHint(level)) { onPick(level) }
                }
            }
        }
    }
}

/** Generic harness option picker: Codex Standard/Fast, Claude context window, toggles. */
@Composable
fun ModelOptionPickerSheet(option: ModelOptionInfo, choiceId: String, onPick: (String) -> Unit, onDismiss: () -> Unit) {
    fun hint(id: String): String? = if (option.id == "serviceTier") {
        when (id) {
            "default" -> "Standard response speed"
            "fast" -> "Faster responses with increased usage"
            else -> null
        }
    } else null
    HarnessSheet(option.label, onDismiss) {
        SheetBody {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SheetLabel(option.label)
                option.choices.forEach { c -> PickRow(c.label, selected = choiceId == c.id, subtitle = hint(c.id)) { onPick(c.id) } }
            }
        }
    }
}

/** Base-ref selector (the desktop footer's branch popover): branch rows with current-checkout / worktree markers. */
@Composable
fun RefPickerSheet(refs: List<RepoRef>, selected: String?, onPick: (RepoRef) -> Unit, onDismiss: () -> Unit) {
    HarnessSheet("Select ref", onDismiss) {
        SheetBody {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SheetLabel("Ref")
                if (refs.isEmpty()) {
                    Text(
                        "Loading refs from the device…", style = sans(13f), color = Theme.palette.textFaint,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 28.dp),
                    )
                }
                refs.forEach { ref ->
                    PickRow(
                        ref.name, selected = ref.name == selected,
                        subtitle = when {
                            ref.current -> "Current checkout"
                            ref.worktreePath != null -> "Checked out in a worktree"
                            else -> null
                        },
                    ) { onPick(ref); onDismiss() }
                }
            }
        }
    }
}

/** Where the session runs (the desktop's checkout popover): the space's folder as-is, or a fresh isolated worktree created off the base ref. */
@Composable
fun CheckoutPickerSheet(
    kind: harness.codegraff.android.model.CheckoutKind,
    selectedRefHasWorktree: Boolean,
    onPick: (harness.codegraff.android.model.CheckoutKind) -> Unit,
    onDismiss: () -> Unit,
) {
    HarnessSheet("Checkout", onDismiss) {
        SheetBody {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                SheetLabel("Checkout")
                PickRow(
                    if (selectedRefHasWorktree) "Current worktree" else "Current checkout",
                    selected = kind == harness.codegraff.android.model.CheckoutKind.Local,
                    subtitle = if (selectedRefHasWorktree) "Reuse the picked ref's existing worktree" else "Run in the space's folder as-is",
                ) { onPick(harness.codegraff.android.model.CheckoutKind.Local); onDismiss() }
                PickRow(
                    "New worktree", selected = kind == harness.codegraff.android.model.CheckoutKind.NewWorktree,
                    subtitle = "A fresh isolated worktree created off the picked base ref",
                ) { onPick(harness.codegraff.android.model.CheckoutKind.NewWorktree); onDismiss() }
            }
        }
    }
}
