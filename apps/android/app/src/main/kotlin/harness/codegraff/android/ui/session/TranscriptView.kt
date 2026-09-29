package harness.codegraff.android.ui.session

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.input.pointer.pointerInput
import harness.codegraff.android.model.MdBlock
import harness.codegraff.android.theme.rememberReduceMotion
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.model.RenderToolCall
import harness.codegraff.android.model.RowKind
import harness.codegraff.android.model.ToolItem
import harness.codegraff.android.model.TranscriptRow
import harness.codegraff.android.model.toolGroupSummary
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.mono
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.pressWashClickable

/** TranscriptView.maxContentWidth. */
private val MaxContentWidth = 736.dp

/**
 * The transcript: one lazy row per markdown block, tool group or chip, newest at index 0 of a
 * reversed list so the bottom stays anchored while the live reply grows and no scroll call runs
 * per streamed token.
 */
@Composable
fun TranscriptView(
    rows: List<TranscriptRow>,
    listState: LazyListState,
    contentPadding: PaddingValues,
    veils: VeilStore,
    modifier: Modifier = Modifier,
) {
    val reduceMotion = rememberReduceMotion()
    val focus = LocalFocusManager.current
    // The list is reversed once, not per recomposition, and only when the rows change.
    val reversed = remember(rows) { rows.asReversed() }
    LazyColumn(
        // Tapping the transcript dismisses the keyboard, like the iOS tap-to-blur.
        modifier.fillMaxWidth().pointerInput(Unit) { detectTapGestures { focus.clearFocus() } },
        state = listState,
        reverseLayout = true,
        contentPadding = contentPadding,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        items(reversed, key = { it.id }, contentType = { it.kind::class }) { row ->
            Box(
                Modifier.widthIn(max = MaxContentWidth).fillMaxWidth().padding(horizontal = 20.dp).padding(top = row.topGap.dp),
            ) { TranscriptRowView(row, veils, reduceMotion) }
        }
    }
}

@Composable
private fun TranscriptRowView(row: TranscriptRow, veils: VeilStore, reduceMotion: Boolean) {
    when (val kind = row.kind) {
        is RowKind.User -> UserBubble(kind.text, pending = kind.pending)
        is RowKind.Markdown -> {
            val veilable = kind.block is MdBlock.Paragraph || kind.block is MdBlock.Heading
            val length = when (val b = kind.block) {
                is MdBlock.Paragraph -> b.spans.sumOf { it.text.length }
                is MdBlock.Heading -> b.spans.sumOf { it.text.length }
                else -> 0
            }
            MarkdownBlockView(kind.block, veil = if (kind.streaming && veilable && !reduceMotion) veils.veil(row.id, length) else null)
        }
        is RowKind.ToolGroup -> ToolGroupView(row.id, kind.tools, kind.autoOpen)
        is RowKind.InputChip -> InputChipView(kind.header, kind.resolved)
        is RowKind.ErrorChip -> ErrorChipView(kind.message)
    }
}

// MARK: user bubble (transcript.rs:1671)

private fun needsCollapse(text: String): Boolean = text.length > 400 || text.split('\n').size > 5

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun UserBubble(text: String, pending: Boolean) {
    val p = Theme.palette
    var expanded by rememberSaveable(text.hashCode()) { mutableStateOf(false) }
    val collapsible = needsCollapse(text)
    val clipboard = LocalClipboardManager.current
    Column(
        Modifier.fillMaxWidth().alpha(if (pending) 0.65f else 1f),
        horizontalAlignment = Alignment.End,
    ) {
        Column(
            Modifier.widthIn(max = MaxContentWidth * 0.8f)
                .clip(RoundedCornerShape(Theme.bubbleRadius))
                .background(p.surfaceRaised, RoundedCornerShape(Theme.bubbleRadius))
                .combinedClickable(onClick = {}, onLongClick = { clipboard.setText(AnnotatedString(text)) })
                .padding(horizontal = 16.dp, vertical = 10.dp)
                .animateContentSize(),
        ) {
            Text(
                text, style = sans(17f, FontWeight.Normal, 26f), color = p.text,
                maxLines = if (expanded) Int.MAX_VALUE else 5, overflow = TextOverflow.Ellipsis,
            )
            if (collapsible) {
                Box(
                    Modifier.heightIn(min = 44.dp).pressWashClickable({ expanded = !expanded }, cornerRadius = 8.dp)
                        .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
                    contentAlignment = Alignment.CenterStart,
                ) { Text(if (expanded) "Show less" else "Show more", style = sans(14f), color = p.textMuted) }
            }
        }
    }
}

// MARK: tool group (transcript.rs render_tool_group)

@Composable
private fun ToolGroupView(id: String, tools: List<ToolItem>, autoOpen: Boolean) {
    val p = Theme.palette
    // The person's own toggle wins; until then a group at the live tail stays open.
    var userOpen by rememberSaveable(id) { mutableStateOf<Boolean?>(null) }
    val open = userOpen ?: autoOpen
    val rotation by animateFloatAsState(if (open) 90f else 0f, label = "disclosure")
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 44.dp)
                .pressWashClickable({ userOpen = !open }, cornerRadius = 8.dp)
                .semantics { stateDescription = if (open) "Expanded" else "Collapsed" },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.width(26.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.rotate(rotation)) { GlyphView(Glyph.ChevronRight, 12.dp, p.textMuted, strokeWidth = 2.8f) }
            }
            Text(toolGroupSummary(tools), style = sans(14f), color = p.textMuted, maxLines = 2, modifier = Modifier.weight(1f))
        }
        AnimatedVisibility(
            open,
            enter = expandVertically(animationSpec = harness.codegraff.android.theme.Motion.resize()) + fadeIn(),
            exit = shrinkVertically(animationSpec = harness.codegraff.android.theme.Motion.resize()) + fadeOut(),
        ) {
            Column(Modifier.fillMaxWidth()) {
                tools.forEachIndexed { index, tool -> ToolChipRow(tool, continues = index < tools.size - 1) }
            }
        }
    }
}

private fun RenderToolCall.glyph(): Glyph = when (tag) {
    "exec" -> Glyph.Terminal
    "readFile", "applyPatch" -> Glyph.File
    "writeFile" -> Glyph.FilePlus
    "editFile" -> Glyph.Pencil
    "search" -> Glyph.Search
    "glob" -> Glyph.Folder
    "webFetch", "webSearch" -> Glyph.Globe
    "todo" -> Glyph.Checklist
    else -> Glyph.Grid
}

/**
 * Desktop activity rail: quiet summary, connected icons, plain detail rows. Long commands remain
 * available through a disclosure instead of being lost to truncation on a phone.
 */
@Composable
private fun ToolChipRow(tool: ToolItem, continues: Boolean) {
    val p = Theme.palette
    var expanded by rememberSaveable(tool.call.tag + tool.call.chipDetail) { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    Row(
        Modifier.fillMaxWidth().height(IntrinsicSize.Min).heightIn(min = 44.dp)
            .combinedClickableCompat(onClick = { expanded = !expanded }, onLongClick = { clipboard.setText(AnnotatedString(tool.call.expandedDetail)) })
            .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(Modifier.width(26.dp).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Box(Modifier.width(1.dp).height(5.dp).background(p.borderStrong))
            Box(Modifier.size(width = 26.dp, height = 18.dp), contentAlignment = Alignment.Center) {
                GlyphView(tool.call.glyph(), 14.dp, if (tool.isError) p.danger else p.textMuted, strokeWidth = 1.7f)
            }
            Box(Modifier.width(1.dp).weight(1f).background(if (continues) p.borderStrong else androidx.compose.ui.graphics.Color.Transparent))
        }
        Column(Modifier.weight(1f).padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(tool.call.chipLabel, style = sans(14f, FontWeight.Medium), color = if (tool.isError) p.danger else p.textMuted)
                if (tool.isError) Text("Failed", style = sans(12f), color = p.danger)
                else if (!tool.resolved) Text("Running", style = sans(12f), color = p.textFaint)
            }
            val detail = if (expanded) tool.call.expandedDetail else tool.call.chipDetail
            if (detail.isNotEmpty()) {
                Text(
                    detail, style = mono(13f), color = p.text.opacity(0.85f),
                    maxLines = if (expanded) Int.MAX_VALUE else 2, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableCompat(onClick: () -> Unit, onLongClick: () -> Unit): Modifier =
    this.combinedClickable(onClick = onClick, onLongClick = onLongClick)

// MARK: chips (transcript.rs ErrorChip / InputChip)

@Composable
private fun ErrorChipView(message: String) {
    val p = Theme.palette
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier.fillMaxWidth().height(34.dp).background(p.danger.opacity(0.05f), shape)
            .border(1.dp, p.danger.opacity(0.16f), shape).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.size(20.dp).background(p.danger.opacity(0.12f), RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
            GlyphView(Glyph.Warning, 12.dp, p.dangerSoft.opacity(0.8f), strokeWidth = 2f)
        }
        Text("Error", style = sans(12f, FontWeight.Medium), color = p.text)
        Text(message, style = sans(12f), color = p.text.opacity(0.8f), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun InputChipView(header: String, resolved: Boolean) {
    val p = Theme.palette
    val shape = RoundedCornerShape(10.dp)
    // Neutral throughout: resolution never recolors.
    Row(
        Modifier.fillMaxWidth().height(34.dp).background(p.ink(0.045f), shape)
            .border(1.dp, p.hairline(0.08f), shape).padding(horizontal = 8.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Question: ${if (resolved) header else "awaiting your answer"}" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.size(20.dp).background(p.ink(0.09f), RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
            GlyphView(Glyph.Chat, 12.dp, p.textMuted, strokeWidth = 2f)
        }
        Text("Question", style = sans(12f, FontWeight.Medium), color = p.text)
        Text(if (resolved) header else "Awaiting your answer…", style = sans(12f), color = p.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
    }
}
