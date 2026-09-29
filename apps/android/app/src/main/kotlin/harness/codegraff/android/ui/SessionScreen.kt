package harness.codegraff.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppState
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ToolCall
import harness.codegraff.android.model.TranscriptRow
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.Type

@Composable
fun SessionScreen(
    chat: Chat,
    state: AppState,
    onBack: () -> Unit,
    onSend: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val p = Theme.palette
    BackHandler(onBack = onBack)
    val rows = state.transcript(chat.id)
    val listState = rememberLazyListState()
    // Stick to the bottom as rows arrive and the live reply grows.
    val tail = (rows.lastOrNull() as? TranscriptRow.Assistant)?.text?.length ?: 0
    LaunchedEffect(rows.size, tail) {
        if (rows.isNotEmpty()) listState.scrollToItem(rows.lastIndex)
    }
    Column(modifier.fillMaxSize().background(p.bg).statusBarsPadding().imePadding().navigationBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(Theme.spaceMD), verticalAlignment = Alignment.CenterVertically) {
            Text(
                "‹",
                style = Type.title,
                color = p.text,
                modifier = Modifier.clickable(onClick = onBack).padding(horizontal = Theme.spaceMD),
            )
            Column {
                Text(chat.displayTitle, style = Type.row, color = p.text, maxLines = 1)
                val device = state.dataset.device(chat.deviceId)?.name.orEmpty()
                Text(device, style = Type.caption, color = p.textFaint)
            }
        }
        LazyColumn(
            Modifier.weight(1f).fillMaxWidth(),
            state = listState,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(Theme.spaceLG),
            verticalArrangement = Arrangement.spacedBy(Theme.spaceLG),
        ) {
            items(rows, key = { it.id }) { row -> TranscriptRowView(row) }
        }
        Composer(onSend = onSend)
    }
}

@Composable
private fun TranscriptRowView(row: TranscriptRow) {
    val p = Theme.palette
    when (row) {
        is TranscriptRow.User -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Text(
                row.text,
                style = Type.body,
                color = p.text,
                modifier = Modifier
                    .widthIn(max = 320.dp)
                    .background(p.surfaceRaised, RoundedCornerShape(Theme.bubbleRadius))
                    .padding(horizontal = Theme.spaceLG, vertical = Theme.spaceMD),
            )
        }
        is TranscriptRow.Assistant -> Text(
            if (row.live && row.text.isEmpty()) "…" else row.text,
            style = Type.body,
            color = p.text,
        )
        is TranscriptRow.ToolGroup -> ToolGroupView(row)
    }
}

@Composable
private fun ToolGroupView(group: TranscriptRow.ToolGroup) {
    val p = Theme.palette
    var open by remember { mutableStateOf(false) }
    Column {
        Text(
            (if (open) "⌄ " else "› ") + group.summary,
            style = Type.caption,
            color = p.textMuted,
            modifier = Modifier.clickable { open = !open },
        )
        if (open) {
            Column(Modifier.padding(start = Theme.spaceMD, top = Theme.spaceSM), verticalArrangement = Arrangement.spacedBy(Theme.spaceSM)) {
                group.calls.forEach { ToolCallView(it) }
            }
        }
    }
}

@Composable
private fun ToolCallView(call: ToolCall) {
    val p = Theme.palette
    Column {
        Text(
            if (call.failed) "${call.label} · failed" else call.label,
            style = Type.caption,
            color = if (call.failed) p.danger else p.textMuted,
        )
        Text(call.detail, style = Type.mono, color = p.text)
        Spacer(Modifier.padding(top = 2.dp))
    }
}
