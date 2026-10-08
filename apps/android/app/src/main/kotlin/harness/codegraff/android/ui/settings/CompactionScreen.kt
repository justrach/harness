package harness.codegraff.android.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.SheetBody
import harness.codegraff.android.ui.components.SheetCard
import harness.codegraff.android.ui.components.SheetLabel
import harness.codegraff.android.ui.components.SheetSelectRow
import harness.codegraff.android.ui.components.SheetSeparator
import kotlinx.coroutines.launch

private sealed interface CompactionState {
    data object Loading : CompactionState
    /** null is graff's default (80%). */
    data class Loaded(val pct: Int?) : CompactionState
    data class Failed(val message: String) : CompactionState
}

/** The desktop's choices. null restores graff's default. */
private val choices: List<Int?> = listOf(null, 50, 60, 70, 75, 85, 90)

private fun label(pct: Int?): String = pct?.let { "$it%" } ?: "Default (80%)"

/**
 * Settings > Graff compaction. The setting belongs to the computer that runs graff (its engine passes it to every
 * graff chat it starts), so this reads and writes it on one computer over its relay: the same value the desktop's
 * Settings → Agents shows on the Graff row (CompactionView.swift).
 */
@Composable
internal fun CompactionContent(
    workspace: WorkspaceState,
    /** AppModel.graffCompactAt: the computer's value, null for graff's default. */
    load: suspend (deviceId: String) -> Int?,
    /** AppModel.setGraffCompactAt: answers with the value the computer kept. */
    save: suspend (deviceId: String, pct: Int?) -> Int?,
) {
    val p = Theme.palette
    // Computers that can run agents, online ones first.
    val hosts = workspace.executionDevices.sortedBy { !workspace.deviceOnline(it.id) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val deviceId = selected?.takeIf { id -> hosts.any { it.id == id } } ?: hosts.firstOrNull()?.id
    var state by remember(deviceId) { mutableStateOf<CompactionState>(CompactionState.Loading) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun describe(deviceId: String, error: Throwable): CompactionState {
        val name = workspace.deviceName(deviceId)
        val message = error.message.orEmpty()
        return if (message.contains("unknown method", ignoreCase = true)) {
            CompactionState.Failed("Update Harness on $name to change this from your phone.")
        } else {
            CompactionState.Failed("Couldn't reach $name: ${message.ifEmpty { "no answer" }}")
        }
    }

    LaunchedEffect(deviceId) {
        val id = deviceId ?: return@LaunchedEffect
        state = runCatching { load(id) }
            .fold({ CompactionState.Loaded(it) }, { describe(id, it) })
    }

    SheetBody {
        if (hosts.isEmpty()) {
            Text("Graff runs on your computers. Open Harness on one and sign in.", style = sans(15f), color = p.textMuted)
            return@SheetBody
        }
        if (hosts.size > 1) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SheetLabel("Computer")
                SheetCard {
                    hosts.forEachIndexed { index, host ->
                        if (index > 0) SheetSeparator()
                        SheetSelectRow(
                            title = host.name,
                            subtitle = if (workspace.deviceOnline(host.id)) null else "Offline",
                            selected = host.id == deviceId,
                        ) { selected = host.id }
                    }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SheetLabel("Compact context at")
            when (val current = state) {
                CompactionState.Loading -> Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = p.text)
                }
                is CompactionState.Failed -> Text(current.message, style = sans(15f), color = p.textMuted, modifier = Modifier.padding(horizontal = 4.dp))
                is CompactionState.Loaded -> SheetCard {
                    // A value set elsewhere (graff's own /compact-at range is wider) still shows.
                    val shown = if (current.pct in choices) choices else choices + current.pct
                    shown.forEachIndexed { index, choice ->
                        if (index > 0) SheetSeparator()
                        SheetSelectRow(title = label(choice), selected = current.pct == choice) {
                            val id = deviceId ?: return@SheetSelectRow
                            if (saving || current.pct == choice) return@SheetSelectRow
                            saving = true
                            state = CompactionState.Loaded(choice)
                            scope.launch {
                                // The engine answers with the value it kept; a failure says why.
                                state = runCatching { save(id, choice) }
                                    .fold({ CompactionState.Loaded(it) }, { describe(id, it) })
                                saving = false
                            }
                        }
                    }
                }
            }
            Text(
                "Graff compacts a conversation once it fills this much of the model's context window. Lower keeps each request smaller and cheaper; higher keeps more of the conversation word for word. Applies to Graff chats started after the change. To change one chat, type /compact-at 70 in it.",
                style = sans(12.5f), color = p.textFaint, modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}
