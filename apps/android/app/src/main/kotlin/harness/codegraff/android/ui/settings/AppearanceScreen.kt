package harness.codegraff.android.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.theme.LocalThemeStore
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.ThemeAppearance
import harness.codegraff.android.theme.ThemeStore
import harness.codegraff.android.theme.ThemeVariant
import harness.codegraff.android.theme.mono
import harness.codegraff.android.theme.sans
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.SegmentedButtonDefaults.itemShape
import harness.codegraff.android.ui.components.SheetBody
import harness.codegraff.android.ui.components.SheetCard
import harness.codegraff.android.ui.components.SheetLabel
import harness.codegraff.android.ui.components.SheetSelectRow
import harness.codegraff.android.ui.components.SheetSeparator

/**
 * Appearance settings (Settings > Appearance): the desktop's theme model on the phone: an
 * appearance mode plus independent light and dark variant choices from the same catalog. Every row
 * previews its variant in that variant's own colors, so the list reads as a palette catalog
 * (AppearanceSheet.swift).
 */
@Composable
internal fun AppearanceContent() {
    val store = LocalThemeStore.current
    val p = Theme.palette
    val systemDark = isSystemInDarkTheme()
    SheetBody {
        MatchDesktop(store)
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SheetLabel("Appearance")
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                ThemeStore.Mode.entries.forEachIndexed { index, mode ->
                    SegmentedButton(
                        selected = store.mode == mode,
                        onClick = { store.setMode(mode) },
                        shape = itemShape(index, ThemeStore.Mode.entries.size),
                        colors = SegmentedButtonDefaults.colors(
                            activeContainerColor = p.elementActive, activeContentColor = p.text, activeBorderColor = p.border,
                            inactiveContainerColor = androidx.compose.ui.graphics.Color.Transparent, inactiveContentColor = p.textMuted, inactiveBorderColor = p.border,
                        ),
                        label = { Text(mode.label, style = sans(14f, FontWeight.Medium)) },
                    )
                }
            }
        }
        ThemePreviewCard(store.active(systemDark))
        VariantSection(store, ThemeAppearance.Dark, "Dark theme")
        VariantSection(store, ThemeAppearance.Light, "Light theme")
        Text(
            "The same themes as Harness on your desktop.", style = sans(12.5f), color = p.textFaint,
            modifier = Modifier.fillMaxWidth(), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}

@Composable
private fun MatchDesktop(store: ThemeStore) {
    val p = Theme.palette
    val detail = when {
        !store.followDesktop -> "Using this phone's own choice."
        store.desktop == null -> "Waiting for your desktop to share its theme."
        else -> {
            val d = store.desktop!!
            val name = { id: String -> store.catalog.variant(id)?.name ?: id }
            val mode = ThemeStore.Mode.entries.firstOrNull { it.name.lowercase() == d.mode }?.label ?: d.mode
            "$mode · ${name(d.light)} and ${name(d.dark)}"
        }
    }
    SheetCard {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("Match desktop", style = sans(15f), color = p.text)
                Text(detail, style = sans(12.5f), color = p.textMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Switch(
                checked = store.followDesktop, onCheckedChange = { store.setFollowDesktop(it) },
                colors = SwitchDefaults.colors(checkedTrackColor = p.accent, checkedThumbColor = p.accentOn),
            )
        }
    }
}

@Composable
private fun VariantSection(store: ThemeStore, appearance: ThemeAppearance, title: String) {
    val variants = store.catalog.variants.filter { it.appearance == appearance }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SheetLabel(title)
        SheetCard {
            variants.forEachIndexed { index, variant ->
                if (index > 0) SheetSeparator()
                SheetSelectRow(
                    title = variant.name,
                    subtitle = familyName(store, variant),
                    selected = store.selectedId(appearance) == variant.id,
                    leading = { ThemeSwatch(variant) },
                ) { store.select(variant) }
            }
        }
    }
}

/** Family names only where they add something ("Ayu" under "Ayu Mirage" is noise; "Rosé Pine" under "Moon" is not). */
private fun familyName(store: ThemeStore, variant: ThemeVariant): String? {
    val family = store.catalog.families.firstOrNull { it.id == variant.familyId } ?: return null
    return family.name.takeUnless { variant.name.contains(it, ignoreCase = true) }
}

/** A variant's palette at a glance: its background plate carrying text, accent, string and warning marks. */
@Composable
private fun ThemeSwatch(variant: ThemeVariant) {
    val c = variant.colors
    val shape = RoundedCornerShape(8.dp)
    Box(Modifier.size(width = 44.dp, height = 32.dp).background(c.background, shape).border(1.dp, c.border, shape)) {
        Column(Modifier.align(Alignment.TopStart).padding(6.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Box(Modifier.size(width = 20.dp, height = 3.dp).background(c.text, CircleShape))
            Box(Modifier.size(width = 13.dp, height = 3.dp).background(c.textMuted, CircleShape))
        }
        Row(Modifier.align(Alignment.BottomEnd).padding(5.dp).height(7.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Box(Modifier.size(7.dp).background(variant.accent.primary, CircleShape))
            Box(Modifier.size(7.dp).background(variant.syntax["string"] ?: c.success, CircleShape))
            Box(Modifier.size(7.dp).background(c.warning, CircleShape))
        }
    }
}

/** A miniature Harness transcript painted in [variant]'s colors: prompt bubble, reply with inline code, a code block, and status dots. */
@Composable
private fun ThemePreviewCard(variant: ThemeVariant) {
    val c = variant.colors
    val syntax = { key: String -> variant.syntax[key] ?: variant.accent.primary }
    val outer = RoundedCornerShape(20.dp)
    Column(
        Modifier.fillMaxWidth().background(c.background, outer).border(1.dp, c.borderStrong, outer).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(variant.name, style = sans(11f, FontWeight.Medium), color = c.textMuted)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            Text(
                "Split panes evenly", style = sans(14f), color = c.text,
                modifier = Modifier.background(c.raised, RoundedCornerShape(16.dp)).padding(horizontal = 12.dp, vertical = 7.dp),
            )
        }
        Text(
            androidx.compose.ui.text.buildAnnotatedString {
                append("Updated ")
                pushStyle(androidx.compose.ui.text.SpanStyle(color = variant.accent.primary)); append("layout.rs"); pop()
                append(" so every pane gets an equal share.")
            },
            style = sans(14f), color = c.text,
        )
        val codeShape = RoundedCornerShape(10.dp)
        Text(
            androidx.compose.ui.text.buildAnnotatedString {
                pushStyle(androidx.compose.ui.text.SpanStyle(color = syntax("keyword"))); append("fn "); pop()
                pushStyle(androidx.compose.ui.text.SpanStyle(color = syntax("function"))); append("split"); pop()
                append("(n: ")
                pushStyle(androidx.compose.ui.text.SpanStyle(color = syntax("type"))); append("usize"); pop()
                append(") -> ")
                pushStyle(androidx.compose.ui.text.SpanStyle(color = syntax("string"))); append("\"even\""); pop()
                pushStyle(androidx.compose.ui.text.SpanStyle(color = syntax("comment"))); append(" // "); pop()
                pushStyle(androidx.compose.ui.text.SpanStyle(color = syntax("number"))); append("1"); pop()
            },
            style = mono(12.5f), color = c.text, maxLines = 1,
            modifier = Modifier.fillMaxWidth().background(c.shell, codeShape).border(1.dp, c.border, codeShape).padding(10.dp),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            listOf("Working" to variant.accent.activity, "Done" to c.success, "Needs you" to c.warning, "Failed" to c.danger).forEach { (label, color) ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Box(Modifier.size(6.dp).background(color, CircleShape))
                    Text(label, style = sans(11.5f), color = c.textMuted)
                }
            }
        }
    }
}
