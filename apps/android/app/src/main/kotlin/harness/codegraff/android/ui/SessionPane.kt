package harness.codegraff.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppState
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ToolCall
import harness.codegraff.android.model.TranscriptRow
import harness.codegraff.android.theme.Theme

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionPane(
    chat: Chat,
    state: AppState,
    showBack: Boolean,
    onBack: () -> Unit,
    onSend: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val device = state.dataset.device(chat.deviceId)?.name.orEmpty()
    val subtitle = listOfNotNull(device.ifEmpty { null }, chat.branch).joinToString(" · ")
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(chat.displayTitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.titleMedium)
                        if (subtitle.isNotEmpty()) {
                            Text(subtitle, maxLines = 1, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                },
                navigationIcon = {
                    if (showBack) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to sessions")
                        }
                    }
                },
            )
        },
        // Keeps the composer above the keyboard and the gesture bar.
        bottomBar = {
            Box(Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Bottom + WindowInsetsSides.Horizontal)).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Composer(onSend = onSend)
            }
        },
        contentWindowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal),
    ) { inner ->
        // In tabletop posture the transcript keeps to the top half, clear of the fold.
        val hingeTop = tabletopHingeTop()
        var contentTop by remember { mutableFloatStateOf(0f) }
        val density = LocalDensity.current
        val bounded = if (hingeTop != null) {
            Modifier.height(with(density) { heightAboveHinge(hingeTop, contentTop).toDp() })
        } else {
            Modifier.fillMaxSize()
        }
        Box(
            Modifier.padding(inner).fillMaxSize().onGloballyPositioned { contentTop = it.positionInWindow().y },
            contentAlignment = Alignment.TopCenter,
        ) {
            Transcript(state.transcript(chat.id), bounded)
        }
    }
}

/**
 * Newest row at index 0 of a reversed list: the bottom stays anchored while the
 * live reply grows, with no per-token scroll calls (the cost that made streaming janky).
 */
@Composable
private fun Transcript(rows: List<TranscriptRow>, modifier: Modifier) {
    LazyColumn(
        modifier.widthIn(max = Theme.readingWidth),
        reverseLayout = true,
        contentPadding = PaddingValues(Theme.spaceLG),
        verticalArrangement = Arrangement.spacedBy(Theme.spaceLG, Alignment.Top),
    ) {
        items(rows.asReversed(), key = { it.id }) { row -> TranscriptRowView(row) }
    }
}

@Composable
private fun TranscriptRowView(row: TranscriptRow) {
    when (row) {
        is TranscriptRow.User -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Text(
                row.text,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier
                    .widthIn(max = 480.dp)
                    .background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(Theme.bubbleRadius))
                    .padding(horizontal = Theme.spaceLG, vertical = Theme.spaceMD),
            )
        }
        is TranscriptRow.Assistant ->
            if (row.text.isEmpty()) {
                Text("…", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                MarkdownText(row.text)
            }
        is TranscriptRow.ToolGroup -> ToolGroupView(row)
    }
}

@Composable
private fun ToolGroupView(group: TranscriptRow.ToolGroup) {
    var open by rememberSaveable(group.id) { mutableStateOf(false) }
    Column {
        // A full-width, 48dp-tall target: the summary is the disclosure control.
        Box(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable { open = !open },
            contentAlignment = Alignment.CenterStart,
        ) {
            Text(
                (if (open) "⌄ " else "› ") + group.summary,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (open) {
            Column(Modifier.padding(start = Theme.spaceMD), verticalArrangement = Arrangement.spacedBy(Theme.spaceSM)) {
                group.calls.forEach { ToolCallView(it) }
            }
        }
    }
}

@Composable
private fun ToolCallView(call: ToolCall) {
    Column {
        Text(
            if (call.failed) "${call.label} · failed" else call.label,
            style = MaterialTheme.typography.labelMedium,
            color = if (call.failed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            call.detail,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = harness.codegraff.android.theme.GeistMono),
        )
    }
}

@Composable
fun EmptySessionPane(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            "Select a session",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
