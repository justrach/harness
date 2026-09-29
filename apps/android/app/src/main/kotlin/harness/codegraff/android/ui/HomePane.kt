package harness.codegraff.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppState
import harness.codegraff.android.model.Attention
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.SessionStatus
import harness.codegraff.android.model.compactAge
import harness.codegraff.android.theme.Theme

enum class HomeFilter(val label: String) { All("All"), NeedsYou("Needs you"), Running("Running") }

fun AppState.visible(filter: HomeFilter): List<Chat> = when (filter) {
    HomeFilter.All -> active
    HomeFilter.NeedsYou -> active.filter { attention(it) == Attention.NeedsYou }
    HomeFilter.Running -> active.filter { attention(it) == Attention.Running }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomePane(
    state: AppState,
    selectedId: String?,
    onOpen: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var filter by rememberSaveable { mutableStateOf(HomeFilter.All) }
    var archivedOpen by rememberSaveable { mutableStateOf(false) }
    val shown = state.visible(filter)

    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = { LargeTopAppBar(title = { Text("Sessions") }, scrollBehavior = scrollBehavior) },
    ) { inner ->
        LazyColumn(Modifier.fillMaxSize(), contentPadding = inner) {
            item(key = "filters") {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = Theme.spaceLG, vertical = Theme.spaceSM),
                    horizontalArrangement = Arrangement.spacedBy(Theme.spaceSM),
                ) {
                    HomeFilter.entries.forEach { option ->
                        val count = when (option) {
                            HomeFilter.All -> null
                            HomeFilter.NeedsYou -> state.needsYouCount
                            HomeFilter.Running -> state.runningCount
                        }
                        FilterChip(
                            selected = filter == option,
                            onClick = { filter = option },
                            label = { Text(if (count == null) option.label else "${option.label} · $count") },
                        )
                    }
                }
            }
            if (shown.isEmpty()) {
                item(key = "empty") {
                    Text(
                        "Nothing here right now.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(Theme.spaceLG),
                    )
                }
            }
            items(shown, key = { it.id }) { chat ->
                ChatItem(chat, state, selected = chat.id == selectedId, onClick = { onOpen(chat.id) })
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
            if (state.archived.isNotEmpty() && filter == HomeFilter.All) {
                item(key = "archived-header") {
                    TextButton(
                        onClick = { archivedOpen = !archivedOpen },
                        modifier = Modifier.padding(horizontal = Theme.spaceSM),
                    ) { Text(if (archivedOpen) "Archived ▾" else "Archived ▸") }
                }
                if (archivedOpen) {
                    items(state.archived, key = { it.id }) { chat ->
                        ChatItem(chat, state, selected = chat.id == selectedId, onClick = { onOpen(chat.id) })
                    }
                }
            }
        }
    }
}

@Composable
private fun ChatItem(chat: Chat, state: AppState, selected: Boolean, onClick: () -> Unit) {
    val attention = state.attention(chat)
    val status = state.sessions[chat.id]?.status
    val device = state.dataset.device(chat.deviceId)?.name.orEmpty()
    val age = compactAge(chat.calledAt, state.now)
    val statusLabel = statusLabel(status, attention)
    ListItem(
        modifier = Modifier
            .clickable(onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = "${chat.displayTitle}, $device, $statusLabel, $age"
            },
        overlineContent = { Text(device) },
        headlineContent = {
            Text(
                chat.displayTitle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                fontWeight = if (chat.unseen) FontWeight.SemiBold else FontWeight.Medium,
            )
        },
        supportingContent = chat.lastMessagePreview?.let { preview ->
            { Text(preview, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Theme.spaceSM)) {
                StatusDot(status, attention)
                Text(age, style = MaterialTheme.typography.labelMedium)
            }
        },
        colors = ListItemDefaults.colors(
            containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent,
        ),
    )
}

private fun statusLabel(status: SessionStatus?, attention: Attention): String = when {
    status == SessionStatus.Working -> "running"
    status == SessionStatus.AwaitingInput -> "waiting for you"
    status == SessionStatus.Errored -> "errored"
    attention == Attention.NeedsYou -> "unread"
    else -> "idle"
}

/** Running is the accent, waiting or unread is warning, errored is error; idle shows nothing. */
@Composable
fun StatusDot(status: SessionStatus?, attention: Attention) {
    val palette = Theme.palette
    val color = when {
        status == SessionStatus.Working -> MaterialTheme.colorScheme.primary
        status == SessionStatus.Errored -> MaterialTheme.colorScheme.error
        status == SessionStatus.AwaitingInput -> palette.warning
        attention == Attention.NeedsYou -> palette.success
        else -> return
    }
    Box(Modifier.size(8.dp).clip(CircleShape).background(color))
}
