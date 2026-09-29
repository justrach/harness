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
import androidx.compose.material3.Text
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
fun SettingsSheet(onDismiss: () -> Unit, onSignOut: () -> Unit) {
    var showAppearance by rememberSaveable { mutableStateOf(false) }
    HarnessSheet(
        title = if (showAppearance) "Appearance" else "Settings",
        onDismiss = onDismiss,
        trailing = if (showAppearance) ({ BackButton { showAppearance = false } }) else null,
    ) {
        if (showAppearance) AppearanceContent() else SettingsContent(onOpenAppearance = { showAppearance = true }, onSignOut = { onDismiss(); onSignOut() })
    }
}

@Composable
private fun BackButton(onClick: () -> Unit) {
    Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(24.dp)).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
        Text("Done", style = sans(15f, FontWeight.SemiBold), color = Theme.palette.accent)
    }
}

@Composable
private fun SettingsContent(onOpenAppearance: () -> Unit, onSignOut: () -> Unit) {
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
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Section("Account") {
            ValueRow("Signed in", "Demo mode")
            Divider()
            ActionRow("Sign out", destructive = true, onClick = onSignOut)
        }
        Section("Appearance") {
            LinkRow("Theme", themeSummary, onOpenAppearance)
        }
        Section("About") {
            ValueRow("Version", version)
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
private fun ValueRow(title: String, value: String) {
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
private fun ActionRow(title: String, destructive: Boolean, onClick: () -> Unit) {
    val p = Theme.palette
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).pressWashClickable(onClick, cornerRadius = 0.dp).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) { Text(title, style = sans(16f), color = if (destructive) p.danger else p.text) }
}
