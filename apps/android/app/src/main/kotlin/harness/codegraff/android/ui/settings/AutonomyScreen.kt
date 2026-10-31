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
import harness.codegraff.android.model.Autonomy
import harness.codegraff.android.model.AutonomySetting
import kotlinx.coroutines.launch

private sealed interface AutonomyState {
    data object Loading : AutonomyState
    data class Loaded(val setting: AutonomySetting) : AutonomyState
    data class Failed(val message: String) : AutonomyState
}

/**
 * Settings > Autonomy: how much agents on one computer may do without asking (AutonomyView.swift). The level
 * belongs to the computer (its engine sets the sandbox and auto-approve for every run it starts), so this reads
 * and writes it there over the relay. A computer nobody set stays on full access.
 */
@Composable
internal fun AutonomyContent(
    workspace: WorkspaceState,
    load: suspend (deviceId: String) -> AutonomySetting,
    save: suspend (deviceId: String, autonomy: Autonomy) -> AutonomySetting,
) {
    val p = Theme.palette
    val hosts = workspace.executionDevices.sortedBy { !workspace.deviceOnline(it.id) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val deviceId = selected?.takeIf { id -> hosts.any { it.id == id } } ?: hosts.firstOrNull()?.id
    var state by remember(deviceId) { mutableStateOf<AutonomyState>(AutonomyState.Loading) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    fun describe(deviceId: String, error: Throwable): AutonomyState {
        val name = workspace.deviceName(deviceId)
        val message = error.message.orEmpty()
        return if (message.contains("unknown method", ignoreCase = true)) {
            AutonomyState.Failed("Update Harness on $name to change this from your phone.")
        } else {
            AutonomyState.Failed("Couldn't reach $name: ${message.ifEmpty { "no answer" }}")
        }
    }

    LaunchedEffect(deviceId) {
        val id = deviceId ?: return@LaunchedEffect
        state = runCatching { load(id) }.fold({ AutonomyState.Loaded(it) }, { describe(id, it) })
    }

    SheetBody {
        if (hosts.isEmpty()) {
            Text("Agents run on your computers. Open Harness on one and sign in.", style = sans(15f), color = p.textMuted)
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
            SheetLabel("Without asking, agents may")
            when (val current = state) {
                AutonomyState.Loading -> Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = p.text)
                }
                is AutonomyState.Failed -> Text(current.message, style = sans(15f), color = p.textMuted, modifier = Modifier.padding(horizontal = 4.dp))
                is AutonomyState.Loaded -> SheetCard {
                    Autonomy.entries.forEachIndexed { index, level ->
                        if (index > 0) SheetSeparator()
                        SheetSelectRow(title = level.label, subtitle = level.blurb, selected = current.setting.autonomy == level) {
                            val id = deviceId ?: return@SheetSelectRow
                            if (saving || (current.setting.autonomy == level && current.setting.chosen)) return@SheetSelectRow
                            saving = true
                            state = AutonomyState.Loaded(AutonomySetting(level, true))
                            scope.launch {
                                state = runCatching { save(id, level) }.fold({ AutonomyState.Loaded(it) }, { describe(id, it) })
                                saving = false
                            }
                        }
                    }
                }
            }
            Text(
                "Applies to every agent on this computer from its next run. Read only and Workspace also stop agents approving their own requests. Claude Code, Codex and ACP agents follow it today.",
                style = sans(12.5f), color = p.textFaint, modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }
}
