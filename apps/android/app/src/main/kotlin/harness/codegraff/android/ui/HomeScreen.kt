package harness.codegraff.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppState
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.compactAge
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.Type

@Composable
fun HomeScreen(state: AppState, onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val p = Theme.palette
    var archivedOpen by remember { mutableStateOf(false) }
    Column(modifier.fillMaxSize().background(p.bg).statusBarsPadding()) {
        Text(
            "Sessions",
            style = Type.title,
            color = p.text,
            modifier = Modifier.padding(horizontal = Theme.spaceLG, vertical = Theme.spaceMD),
        )
        LazyColumn(Modifier.fillMaxSize()) {
            items(state.active, key = { it.id }) { chat ->
                ChatRow(chat, state, onClick = { onOpen(chat.id) })
                HorizontalDivider(color = p.border)
            }
            if (state.archived.isNotEmpty()) {
                item("archived-header") {
                    Text(
                        (if (archivedOpen) "Archived ▾" else "Archived ▸"),
                        style = Type.caption,
                        color = p.textMuted,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { archivedOpen = !archivedOpen }
                            .padding(Theme.spaceLG),
                    )
                }
                if (archivedOpen) {
                    items(state.archived, key = { it.id }) { chat ->
                        ChatRow(chat, state, onClick = { onOpen(chat.id) })
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatRow(chat: Chat, state: AppState, onClick: () -> Unit) {
    val p = Theme.palette
    val status = state.sessions[chat.id]?.status
    val deviceName = state.dataset.device(chat.deviceId)?.name.orEmpty()
    Column(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = Theme.spaceLG, vertical = Theme.spaceMD),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                deviceName,
                style = Type.caption,
                color = p.textFaint,
                modifier = Modifier.weight(1f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            StatusDot(status, unseen = chat.unseen)
            Spacer(Modifier.size(6.dp))
            Text(compactAge(chat.calledAt, state.now), style = Type.caption, color = p.textFaint)
        }
        Spacer(Modifier.height(2.dp))
        Text(chat.displayTitle, style = Type.row, color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
        chat.lastMessagePreview?.let {
            Text(it, style = Type.caption, color = p.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
fun StatusDot(status: SessionStatus?, unseen: Boolean) {
    val p = Theme.palette
    val color = when (status) {
        SessionStatus.Working -> p.accent
        SessionStatus.AwaitingInput -> p.warning
        SessionStatus.Errored -> p.danger
        else -> if (unseen) p.success else null
    } ?: return
    Box(Modifier.size(8.dp).clip(CircleShape).background(color))
}
