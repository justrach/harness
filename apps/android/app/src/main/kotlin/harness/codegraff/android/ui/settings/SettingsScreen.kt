package harness.codegraff.android.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.window.Dialog
import harness.codegraff.android.AccountDeletionState
import harness.codegraff.android.WorkspaceState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.LocalThemeStore
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.HarnessSheet
import harness.codegraff.android.ui.components.pressWashClickable

/**
 * Settings, opened from the person button on Home. Account actions live here rather than in a
 * quick menu: signing out is one tap away (SettingsView.swift).
 */
@Composable
fun SettingsSheet(
    onDismiss: () -> Unit,
    onSignOut: () -> Unit,
    /** Only a real CodeGraff sign-in has an account to delete; the offline demo shows no such row, as on iOS. */
    canDeleteAccount: Boolean = false,
    deletion: AccountDeletionState = AccountDeletionState(),
    onDeleteAccount: () -> Unit = {},
    onDismissDeletionError: () -> Unit = {},
    /** The workspace and the relay calls behind Settings > Graff compaction; the row is hidden without them. */
    workspace: WorkspaceState? = null,
    loadCompactAt: suspend (deviceId: String) -> Int? = { null },
    saveCompactAt: suspend (deviceId: String, pct: Int?) -> Int? = { _, pct -> pct },
) {
    var showAppearance by rememberSaveable { mutableStateOf(false) }
    var confirmDelete by rememberSaveable { mutableStateOf(false) }
    var showPerformance by rememberSaveable { mutableStateOf(false) }
    var showCompaction by rememberSaveable { mutableStateOf(false) }
    val version = LocalContext.current.let { c ->
        runCatching { c.packageManager.getPackageInfo(c.packageName, 0).versionName }.getOrNull() ?: "?"
    }
    HarnessSheet(
        title = if (showAppearance) "Appearance" else if (showPerformance) "Performance" else if (showCompaction) "Graff compaction" else "Settings",
        // The sheet stays put while the account is being deleted (interactiveDismissDisabled).
        onDismiss = { if (!deletion.busy) onDismiss() },
        trailing = if (showAppearance || showPerformance || showCompaction) ({ BackButton { showAppearance = false; showPerformance = false; showCompaction = false } }) else null,
    ) {
        if (showAppearance) AppearanceContent()
        else if (showPerformance) PerformanceContent(version)
        else if (showCompaction && workspace != null) CompactionContent(workspace, loadCompactAt, saveCompactAt)
        else SettingsContent(
            onOpenAppearance = { showAppearance = true },
            onOpenPerformance = { showPerformance = true },
            onOpenCompaction = if (workspace != null) ({ showCompaction = true }) else null,
            onSignOut = { onDismiss(); onSignOut() },
            canDeleteAccount = canDeleteAccount,
            deleting = deletion.busy,
            onDeleteAccount = { confirmDelete = true },
        )
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete your account?") },
            text = {
                Text("This permanently deletes your CodeGraff account and everything Harness keeps for it: chats, sessions, devices, and the agent rooms you made. Your posts in other people's rooms lose their text. This can't be undone.")
            },
            confirmButton = { TextButton(onClick = { confirmDelete = false; onDeleteAccount() }) { Text("Delete", color = Theme.palette.danger) } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
    deletion.error?.let { message ->
        AlertDialog(
            onDismissRequest = onDismissDeletionError,
            title = { Text("Account not deleted") },
            text = { Text(message) },
            confirmButton = { TextButton(onClick = onDismissDeletionError) { Text("OK") } },
        )
    }
    if (deletion.busy) {
        Dialog(onDismissRequest = {}) {
            Row(
                Modifier.clip(RoundedCornerShape(14.dp)).background(Theme.palette.surfaceDialog).padding(20.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp, color = Theme.palette.text)
                Text("Deleting account…", style = sans(15f), color = Theme.palette.text)
            }
        }
    }
}

@Composable
private fun BackButton(onClick: () -> Unit) {
    Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
        Text("Done", style = sans(15f, FontWeight.SemiBold), color = Theme.palette.accent)
    }
}

@Composable
private fun SettingsContent(
    onOpenAppearance: () -> Unit,
    onOpenPerformance: () -> Unit,
    onOpenCompaction: (() -> Unit)?,
    onSignOut: () -> Unit,
    canDeleteAccount: Boolean,
    deleting: Boolean,
    onDeleteAccount: () -> Unit,
) {
    val p = Theme.palette
    val store = LocalThemeStore.current
    val version = LocalContext.current.let { c ->
        runCatching { c.packageManager.getPackageInfo(c.packageName, 0).versionName }.getOrNull() ?: "?"
    }
    val themeSummary = run {
        val family = { id: String -> store.catalog.variant(id)?.familyId?.let { fid -> store.catalog.families.firstOrNull { it.id == fid }?.name } }
        val light = family(store.selectedId(harness.codegraff.android.theme.ThemeAppearance.Light))
        val dark = family(store.selectedId(harness.codegraff.android.theme.ThemeAppearance.Dark))
        val name = if (light == dark) (light ?: "Harness") else (family(store.active(true).id) ?: "Harness")
        if (store.isMatchingDesktop) "$name · Desktop" else "$name · ${store.mode.label}"
    }
    // Scrolls: with Diagnostics and the delete row the list is taller than a phone's half-height sheet.
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Section("Account") {
            if (canDeleteAccount) ValueRow("Signed in with", "CodeGraff") else ValueRow("Signed in", "Demo mode")
            Divider()
            ActionRow("Sign out", destructive = true, onClick = onSignOut)
        }
        Section("Appearance") {
            LinkRow("Theme", themeSummary, onOpenAppearance)
        }
        if (onOpenCompaction != null) {
            Section("Agents") {
                LinkRow("Graff compaction", "", onOpenCompaction)
            }
        }
        Section("Diagnostics") {
            LinkRow("Performance", Perf.startupMs?.let { "Started in $it ms" } ?: "", onOpenPerformance)
        }
        Section("About") {
            ValueRow("Version", version)
        }
        if (canDeleteAccount) {
            // Deleting the account sits apart at the bottom behind its own confirmation.
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(p.ink(0.045f))) {
                    ActionRow("Delete account…", destructive = true, enabled = !deleting, onClick = onDeleteAccount)
                }
                Text(
                    "Permanently deletes your CodeGraff account and everything Harness keeps for it.",
                    style = sans(12f), color = p.textMuted.opacity(0.7f), modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }
    }
}

// The inset-grouped list look of the iOS Settings List: tracked section title, rounded card, hairline-separated rows.

@Composable
internal fun Section(title: String, content: @Composable () -> Unit) {
    val p = Theme.palette
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title.uppercase(), style = sans(12f, FontWeight.Medium), color = p.textMuted.opacity(0.7f), modifier = Modifier.padding(horizontal = 16.dp))
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(p.ink(0.045f))) { content() }
    }
}

@Composable
internal fun Divider() {
    Box(Modifier.fillMaxWidth().padding(start = 16.dp).heightIn(min = 1.dp).background(Theme.palette.hairline(0.06f)).padding(top = 1.dp))
}

@Composable
internal fun ValueRow(title: String, value: String) {
    val p = Theme.palette
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = sans(16f), color = p.text)
        Spacer(Modifier.weight(1f))
        Text(value, style = sans(16f), color = p.textMuted)
    }
}

@Composable
private fun LinkRow(title: String, value: String, onClick: () -> Unit) {
    val p = Theme.palette
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).pressWashClickable(onClick, cornerRadius = 0.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(title, style = sans(16f), color = p.text)
        Spacer(Modifier.weight(1f))
        Text(value, style = sans(16f), color = p.textMuted, maxLines = 1)
        GlyphView(Glyph.ChevronRight, 13.dp, p.textFaint, strokeWidth = 2.6f)
    }
}

@Composable
internal fun ActionRow(title: String, destructive: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val p = Theme.palette
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).pressWashClickable(onClick, cornerRadius = 0.dp, enabled = enabled).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) { Text(title, style = sans(16f), color = (if (destructive) p.danger else p.text).opacity(if (enabled) 1f else 0.4f)) }
}
