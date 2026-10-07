package harness.codegraff.android.ui.sheets

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import harness.codegraff.android.demo.FolderListing
import harness.codegraff.android.model.ConnectivityRules
import harness.codegraff.android.ui.components.MiniSpinner
import kotlinx.coroutines.launch

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.AppModel
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.demo.DemoDataset
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.LineIcon
import harness.codegraff.android.theme.LineIconView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.mono
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.HarnessSheet
import harness.codegraff.android.ui.components.SheetCard
import harness.codegraff.android.ui.components.SheetPrimaryButton
import harness.codegraff.android.ui.components.SheetSeparator
import harness.codegraff.android.ui.components.pressWashClickable

/** Projectless drafts need only a host, including when there are no spaces (SessionHostPickerSheet.swift). */
@Composable
fun SessionHostPickerSheet(state: WorkspaceState, selectedDeviceId: String?, onSelected: (String) -> Unit, onDismiss: () -> Unit) {
    val p = Theme.palette
    HarnessSheet("Select a device", onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (state.executionDevices.isEmpty()) {
                Text("Connect a desktop device to start a session. No project is required.", style = sans(15f), color = p.textMuted)
            } else {
                SheetCard {
                    state.executionDevices.forEachIndexed { index, device ->
                        if (index > 0) SheetSeparator()
                        Row(
                            Modifier.fillMaxWidth().pressWashClickable({ onSelected(device.id); onDismiss() }, cornerRadius = 0.dp)
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(device.name, style = sans(16f), color = p.text)
                                Text(ConnectivityRules.hostStatusLine(state.hostStatus(device.id)), style = sans(12f), color = p.textMuted)
                            }
                            if (selectedDeviceId == device.id) GlyphView(Glyph.Check, 16.dp, p.text, strokeWidth = 2.4f)
                        }
                    }
                }
                Text("Runs in the selected device’s home folder without a project.", style = sans(12f), color = p.textMuted, modifier = Modifier.padding(horizontal = 4.dp))
            }
        }
    }
}

/**
 * The desktop add-space palette translated to a sheet: device tabs, a mono breadcrumb with an up
 * button, the device's folders (git repos badged), and "Use this folder" pinned at the bottom
 * (NewSpaceSheet in SpaceView.swift).
 */
@Composable
fun NewSpaceSheet(state: WorkspaceState, model: AppModel, onCreated: (String) -> Unit, onDismiss: () -> Unit) {
    val p = Theme.palette
    val devices = state.executionDevices
    var deviceId by remember { mutableStateOf<String?>(null) }
    val selectedDevice = deviceId ?: devices.firstOrNull()?.id
    var path by remember(selectedDevice) { mutableStateOf<String?>(null) }
    var currentIsRepo by remember(selectedDevice) { mutableStateOf(false) }
    // Asked of the computer over the relay; the last listing stays up while the next one loads.
    var listing by remember(selectedDevice) { mutableStateOf<FolderListing?>(null) }
    var loading by remember(selectedDevice) { mutableStateOf(false) }
    var error by remember(selectedDevice) { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(selectedDevice, path) {
        val device = selectedDevice ?: return@LaunchedEffect
        loading = true
        error = null
        val result = model.listFolders(device, path)
        loading = false
        if (result != null) listing = result
        else if (listing == null) error = "Couldn't reach ${state.deviceName(device)}. Make sure it's online."
    }

    HarnessSheet("New space", onDismiss) {
        if (devices.isEmpty()) {
            Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                GlyphView(Glyph.Monitor, 30.dp, p.textFaint, strokeWidth = 1.2f)
                Text("No devices yet", style = sans(15f, FontWeight.Medium), color = p.text)
                Text("Run Harness on a computer first — its folders will show up here.", style = sans(13f), color = p.textMuted, textAlign = TextAlign.Center)
            }
        } else if (listing == null) {
            Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                error?.let { Text(it, style = sans(13f), color = p.danger, textAlign = TextAlign.Center) } ?: MiniSpinner()
            }
        } else {
            val listing = listing!!
            Column(Modifier.fillMaxWidth().heightIn(max = 620.dp)) {
                // Device tabs.
                Row(
                    Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 14.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    devices.forEach { device ->
                        val selected = device.id == selectedDevice
                        Row(
                            Modifier.height(48.dp).clip(CircleShape).background(if (selected) p.ink(0.15f) else p.ink(0.05f), CircleShape)
                                .clickable(role = Role.Tab) { deviceId = device.id }.padding(horizontal = 14.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp),
                        ) {
                            Box(Modifier.size(6.dp).background(if (state.deviceOnline(device.id)) p.statusCompleted.opacity(0.9f) else p.ink(0.18f), CircleShape))
                            Text(device.name, style = sans(13f, FontWeight.Medium), color = if (selected) p.text else p.textMuted)
                        }
                    }
                }
                // Breadcrumb.
                Row(Modifier.padding(horizontal = 20.dp).padding(bottom = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    val canUp = listing.parent != null
                    Box(
                        Modifier.size(48.dp).clip(CircleShape).clickable(enabled = canUp, role = Role.Button) { currentIsRepo = false; path = listing.parent }
                            .semantics { contentDescription = "Up one folder" },
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(Modifier.size(32.dp).background(p.ink(0.06f), CircleShape), contentAlignment = Alignment.Center) {
                            GlyphView(Glyph.ChevronLeft, 14.dp, if (canUp) p.text else p.textFaint.opacity(0.4f), strokeWidth = 2.6f)
                        }
                    }
                    Text(listing.path, style = mono(12f), color = p.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (loading) MiniSpinner()
                }
                // Folders.
                Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 12.dp)) {
                    error?.let { Text(it, style = sans(13f), color = p.danger, modifier = Modifier.padding(horizontal = 4.dp, vertical = 4.dp)) }
                    val folders = listing.entries.filter { it.isDir }
                    if (folders.isEmpty() && !loading && error == null) {
                        Text("No folders here", style = sans(13f), color = p.textFaint, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(vertical = 28.dp))
                    } else {
                        SheetCard {
                            folders.forEachIndexed { ix, entry ->
                                Row(
                                    Modifier.fillMaxWidth().pressWashClickable({
                                        val base = listing.path
                                        currentIsRepo = entry.isRepo
                                        path = if (base.endsWith("/")) base + entry.name else "$base/${entry.name}"
                                    }, cornerRadius = 0.dp).padding(horizontal = 16.dp, vertical = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                                ) {
                                    LineIconView(if (entry.isRepo) LineIcon.FolderWithFiles else LineIcon.Folder, 16.dp, if (entry.isRepo) p.accent.opacity(0.85f) else p.textMuted)
                                    Text(entry.name, style = sans(15f), color = p.text, maxLines = 1, modifier = Modifier.weight(1f))
                                    if (entry.isRepo) {
                                        Text(
                                            "git", style = mono(10f), color = p.accent.opacity(0.85f),
                                            modifier = Modifier.background(p.accent.opacity(0.12f), CircleShape).padding(horizontal = 7.dp, vertical = 3.dp),
                                        )
                                    }
                                    GlyphView(Glyph.ChevronRight, 12.dp, p.textFaint, strokeWidth = 2.6f)
                                }
                                if (ix < folders.lastIndex) SheetSeparator()
                            }
                        }
                    }
                    if (listing.truncated) {
                        Text("Listing truncated — this folder has more entries.", style = sans(12f), color = p.textFaint, modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp))
                    }
                }
                val name = listing.path.trimEnd('/').substringAfterLast('/')
                Box(Modifier.background(p.surfaceDialog.opacity(0.94f)).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 6.dp)) {
                    SheetPrimaryButton(if (name.isEmpty()) "Use this folder" else "Use “$name”") {
                        if (creating) return@SheetPrimaryButton
                        creating = true
                        scope.launch {
                            // The git flag the engine stamped when we descended into this folder; the host re-checks it.
                            val id = model.createSpace(selectedDevice!!, listing.path, null, currentIsRepo)
                            creating = false
                            onDismiss()
                            onCreated(id)
                        }
                    }
                }
            }
        }
    }
}
