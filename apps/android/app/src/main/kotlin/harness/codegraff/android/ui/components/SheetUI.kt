package harness.codegraff.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.LineIcon
import harness.codegraff.android.theme.LineIconView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans

// Sheet design language: the mobile app's grouped-card system (SheetUI.swift):
// panel cards, hairline-separated rows, centered headers, tracked section labels.

object SheetStyle {
    val cardRadius = 20.dp
}

/**
 * A modal bottom sheet in the app's sheet chrome: dialog-colored panel, 32dp top
 * corners, drag handle, centered inline [title] and a trailing close button.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HarnessSheet(
    title: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val p = Theme.palette
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
        containerColor = p.surfaceDialog,
        shape = RoundedCornerShape(topStart = 32.dp, topEnd = 32.dp),
        modifier = modifier,
    ) {
        Column(Modifier.fillMaxWidth().navigationBarsPadding()) {
            Box(Modifier.fillMaxWidth().height(48.dp), contentAlignment = Alignment.Center) {
                Text(title, style = sans(16f, FontWeight.SemiBold), color = p.text, textAlign = TextAlign.Center)
                Box(Modifier.align(Alignment.CenterEnd).padding(end = 8.dp)) {
                    trailing?.invoke() ?: CloseButton(onDismiss)
                }
            }
            content()
        }
    }
}

@Composable
fun CloseButton(onClick: () -> Unit) {
    Box(
        Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onClick, role = Role.Button)
            .semantics { contentDescription = "Close" },
        contentAlignment = Alignment.Center,
    ) { GlyphView(Glyph.Close, 15.dp, Theme.palette.text, strokeWidth = 2.2f) }
}

/** Scrolling body of a sheet: 20dp padding, 22dp between groups. */
@Composable
fun SheetBody(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(
        modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp).padding(bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(22.dp),
        content = content,
    )
}

/** Grouped card: rows separated by inset hairlines. */
@Composable
fun SheetCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val p = Theme.palette
    val shape = RoundedCornerShape(SheetStyle.cardRadius)
    Column(
        modifier.fillMaxWidth().background(p.ink(0.045f), shape).border(1.dp, p.hairline(0.06f), shape).clip(shape),
        content = content,
    )
}

/** Inset hairline between card rows. */
@Composable
fun SheetSeparator() {
    Box(Modifier.fillMaxWidth().padding(start = 16.dp).height(1.dp).background(Theme.palette.hairline(0.06f)))
}

/** Uppercase tracked section label above a card. */
@Composable
fun SheetLabel(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        style = sans(11f, FontWeight.Medium).copy(letterSpacing = 1.sp),
        color = Theme.palette.textMuted.opacity(0.6f),
        modifier = modifier.padding(horizontal = 4.dp),
    )
}

/** Selectable row: title and optional subtitle, a check when selected. */
@Composable
fun SheetSelectRow(
    title: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    leading: (@Composable () -> Unit)? = null,
    onClick: () -> Unit,
) {
    val p = Theme.palette
    Row(
        modifier.fillMaxWidth().pressWashClickable(onClick, cornerRadius = 0.dp, role = Role.RadioButton)
            .semantics { this.selected = selected }
            .padding(horizontal = 16.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        leading?.invoke()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = sans(15f), color = p.text)
            if (!subtitle.isNullOrEmpty()) {
                Text(subtitle, style = sans(12.5f), color = p.textMuted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        Box(Modifier.alpha(if (selected) 1f else 0f)) { GlyphView(Glyph.Check, 15.dp, p.text, strokeWidth = 2.4f) }
    }
}

/** Navigation-style row: title, trailing detail, chevron. */
@Composable
fun SheetLinkRow(title: String, modifier: Modifier = Modifier, detail: String? = null, onClick: () -> Unit) {
    val p = Theme.palette
    Row(
        modifier.fillMaxWidth().pressWashClickable(onClick, cornerRadius = 0.dp).padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(title, style = sans(15f), color = p.text)
        Spacer(Modifier.weight(1f))
        if (detail != null) Text(detail, style = sans(14f), color = p.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        GlyphView(Glyph.ChevronRight, 13.dp, p.textFaint, strokeWidth = 2.4f)
    }
}

/** Primary pill button pinned at a sheet's bottom. */
@Composable
fun SheetPrimaryButton(title: String, enabled: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val p = Theme.palette
    Box(
        modifier.fillMaxWidth().height(50.dp)
            .background(if (enabled) p.text else p.ink(0.08f), CircleShape)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = sans(15f, FontWeight.SemiBold), color = if (enabled) p.bg else p.textFaint)
    }
}

/**
 * The ONE row style every picker sheet uses (model, trait, ref): the selected row is a
 * filled high-contrast pill with a trailing check; unselected rows sit almost flat.
 */
@Composable
fun PickRow(
    title: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    icon: LineIcon? = null,
    busy: Boolean = false,
    onClick: () -> Unit,
) {
    val p = Theme.palette
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier.fillMaxWidth().clip(shape)
            .background(if (selected) p.text else p.ink(0.03f), shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { this.selected = selected }
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (icon != null) {
            Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) {
                LineIconView(icon, 15.dp, if (selected) p.bg else p.textMuted)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = sans(15f, FontWeight.Medium), color = if (selected) p.bg else p.text)
            if (subtitle != null) {
                Text(subtitle, style = sans(12f), color = if (selected) p.bg.opacity(0.65f) else p.textMuted)
            }
        }
        if (busy) {
            androidx.compose.material3.CircularProgressIndicator(
                Modifier.size(18.dp), color = if (selected) p.bg else p.textMuted, strokeWidth = 2.dp,
            )
        } else {
            Box(Modifier.alpha(if (selected) 1f else 0f)) { GlyphView(Glyph.Check, 15.dp, p.bg, strokeWidth = 2.6f) }
        }
    }
}
