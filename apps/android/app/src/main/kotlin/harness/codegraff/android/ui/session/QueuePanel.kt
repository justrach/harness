package harness.codegraff.android.ui.session

import android.content.ClipData
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.mimeTypes
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.QueueState
import harness.codegraff.android.model.MessageQueue
import harness.codegraff.android.model.QueueAction
import harness.codegraff.android.model.QueueDeliveryGate
import harness.codegraff.android.model.QueuedMessage
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.mono
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.home.HarnessMenu
import harness.codegraff.android.ui.home.MenuRow

/** The numbers QueuePanelView.swift lays the panel out with; apps/parity/ux-contract.json holds the same ones. */
object QueueUX {
    const val ROW_HEIGHT_DP = 56
    const val ROW_GAP_DP = 6
    const val MAX_VISIBLE_ROWS = 3
    const val CONTROL_SIZE_DP = 44

    /** The panel's scrolling area: up to three rows and the gaps between them. */
    fun listHeightDp(count: Int): Int {
        val visible = minOf(count, MAX_VISIBLE_ROWS)
        return visible * ROW_HEIGHT_DP + maxOf(0, visible - 1) * ROW_GAP_DP
    }
}

/**
 * Queued messages, stacked directly above the composer (QueuePanelView.swift). Everything typed while the agent is
 * busy waits here until the host sends it. Rows can be reordered by dragging or with the menu, retyped in the
 * composer, sent immediately (which stops the turn to do it), or dropped.
 */
@Composable
fun QueuePanel(
    queue: QueueState,
    editingId: String?,
    supportsActions: Boolean,
    onEdit: (QueuedMessage) -> Unit,
    onCancelEdit: () -> Unit,
    onAction: (QueuedMessage, QueueAction) -> Unit,
    onMove: (id: String, to: Int) -> Unit,
    onMoveBy: (id: String, direction: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = Theme.palette
    val rows = queue.rows
    var dragTarget by remember { mutableStateOf<String?>(null) }
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(QueueUX.ROW_GAP_DP.dp)) {
        MessageQueue.label(rows.size)?.let { label ->
            Text(
                label.uppercase(), style = sans(10f, FontWeight.Medium).copy(letterSpacing = 0.6.sp), color = p.textFaint,
                modifier = Modifier.padding(start = 4.dp),
            )
        }
        LazyColumn(
            Modifier.height(QueueUX.listHeightDp(rows.size).dp),
            verticalArrangement = Arrangement.spacedBy(QueueUX.ROW_GAP_DP.dp),
        ) {
            itemsIndexed(rows, key = { _, row -> row.id }) { index, item ->
                QueueRow(
                    item, index, rows.size, queue, editing = editingId == item.id, supportsActions = supportsActions,
                    targeted = dragTarget == item.id, onTarget = { entered -> dragTarget = if (entered) item.id else if (dragTarget == item.id) null else dragTarget },
                    onEdit = onEdit, onCancelEdit = onCancelEdit, onAction = onAction, onMove = onMove, onMoveBy = onMoveBy,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun QueueRow(
    item: QueuedMessage,
    index: Int,
    count: Int,
    queue: QueueState,
    editing: Boolean,
    supportsActions: Boolean,
    targeted: Boolean,
    onTarget: (Boolean) -> Unit,
    onEdit: (QueuedMessage) -> Unit,
    onCancelEdit: () -> Unit,
    onAction: (QueuedMessage, QueueAction) -> Unit,
    onMove: (String, Int) -> Unit,
    onMoveBy: (String, Int) -> Unit,
) {
    val p = Theme.palette
    val pending = item.id in queue.pending
    val gated = item.deliveryGate != null || pending
    val shape = RoundedCornerShape(10.dp)
    val displayText = when {
        pending -> "Updating…"
        editing -> "Editing below"
        else -> when (val gate = item.deliveryGate) {
            is QueueDeliveryGate.Editing -> "Editing on ${gate.ownerDeviceId}"
            is QueueDeliveryGate.ReviewRequired -> "Needs review"
            null -> MessageQueue.oneLine(MessageQueue.visibleText(item.text, item.attachments))
        }
    }
    val primary = MessageQueue.primaryAction(item, supportsActions, pending)
    val lockedByOther = item.deliveryGate is QueueDeliveryGate.Editing && !editing
    var menuOpen by remember { mutableStateOf(false) }

    // Drag to reorder, with the menu doing the same thing for anyone who would rather not hold a row on a moving list.
    // A protected row stays put while its text is being edited or awaits review, but other rows may drop onto it.
    val target = remember(item.id, index, onMove) {
        object : DragAndDropTarget {
            override fun onEntered(event: DragAndDropEvent) = onTarget(true)
            override fun onExited(event: DragAndDropEvent) = onTarget(false)
            override fun onEnded(event: DragAndDropEvent) = onTarget(false)
            override fun onDrop(event: DragAndDropEvent): Boolean {
                onTarget(false)
                val dropped = event.toAndroidDragEvent().clipData?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
                    ?: return false
                if (dropped == item.id) return false
                onMove(dropped, index)
                return true
            }
        }
    }
    val draggable = item.deliveryGate == null && !pending

    Row(
        Modifier.fillMaxWidth().height(QueueUX.ROW_HEIGHT_DP.dp)
            .background(if (targeted) p.ink(0.10f) else p.ink(0.04f), shape)
            .border(1.dp, p.border, shape)
            .clip(shape)
            .dragAndDropTarget(shouldStartDragAndDrop = { it.mimeTypes().contains("text/plain") }, target = target)
            .then(
                if (draggable) Modifier.dragAndDropSource(
                    block = {
                        detectDragGesturesAfterLongPress(
                            onDragStart = { _ -> startTransfer(DragAndDropTransferData(ClipData.newPlainText("queue-row", item.id))) },
                            onDrag = { _, _ -> },
                        )
                    },
                ) else Modifier,
            )
            .padding(start = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "${index + 1}", style = mono(10f), color = p.textFaint, textAlign = TextAlign.End,
            modifier = Modifier.widthIn(min = 12.dp),
        )
        if (item.attachments.isNotEmpty() && !editing) QueueAttachmentPreview(item.attachments.size - 1)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                displayText, style = sans(12.5f), color = if (editing) p.textMuted else p.text,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            if (item.attachments.isNotEmpty() && !editing) {
                Text(
                    item.attachments.joinToString(" · ") { "Image" }, style = sans(10.5f), color = p.textMuted,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Row {
            IconControl(
                if (editing) Glyph.Close else Glyph.Pencil, if (editing) "Stop editing" else "Edit",
                enabled = !lockedByOther && !pending,
            ) { if (editing) onCancelEdit() else onEdit(item) }
            IconControl(Glyph.ArrowRight, "Send now, interrupting the response", enabled = primary != null) {
                primary?.let { onAction(item, it) }
            }
            Box {
                IconControl(Glyph.Ellipsis, "More queue actions", enabled = true, glyphSize = 13) { menuOpen = true }
                HarnessMenu(menuOpen, { menuOpen = false }) {
                    MenuRow("Move up", null, false, Glyph.ChevronUp, enabled = !(index == 0 || gated)) { menuOpen = false; onMoveBy(item.id, -1) }
                    MenuRow("Move down", null, false, Glyph.ChevronDown, enabled = !(index >= count - 1 || gated)) { menuOpen = false; onMoveBy(item.id, 1) }
                    MenuRow("Remove", null, false, Glyph.Trash, enabled = supportsActions && !pending, destructive = true) {
                        menuOpen = false; onAction(item, QueueAction.Remove)
                    }
                }
            }
        }
    }
}

/** A 44dp tap target around a small glyph, dimmed when it cannot act. */
@Composable
private fun IconControl(glyph: Glyph, label: String, enabled: Boolean, glyphSize: Int = 12, onClick: () -> Unit) {
    val p = Theme.palette
    Box(
        Modifier.size(QueueUX.CONTROL_SIZE_DP.dp).clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { GlyphView(glyph, glyphSize.dp, if (enabled) p.textMuted else p.textFaint.opacity(0.4f), strokeWidth = 2.2f) }
}

/** The row's image thumbnail slot: a placeholder here, since the demo has no uploaded bytes to decode. */
@Composable
private fun QueueAttachmentPreview(extra: Int) {
    val p = Theme.palette
    Box(
        Modifier.size(width = 40.dp, height = QueueUX.CONTROL_SIZE_DP.dp)
            .semantics { contentDescription = if (extra > 0) "Preview image, $extra more attachments" else "Preview image" },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.size(width = 40.dp, height = 28.dp).clip(RoundedCornerShape(5.dp)).background(p.ink(0.06f)), contentAlignment = Alignment.Center) {
            GlyphView(Glyph.Photo, 14.dp, p.textFaint, strokeWidth = 1.8f)
            if (extra > 0) {
                Text(
                    "+$extra", style = sans(9f, FontWeight.Medium), color = p.text,
                    modifier = Modifier.align(Alignment.BottomEnd).background(p.bg.opacity(0.9f), RoundedCornerShape(3.dp)).padding(horizontal = 3.dp),
                )
            }
        }
    }
}
