package harness.codegraff.android.ui.session

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.HarnessBadge
import harness.codegraff.android.theme.Motion
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.glass
import harness.codegraff.android.ui.components.rememberHaptics
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** A photo staged in the composer until the message is sent. */
data class StagedAttachment(val id: String, val name: String, val uri: Uri)

/**
 * Composer: the floating glass shell in the t3 mobile composer's shape. A collapsed capsule
 * (editor + send circle) morphs into an expanded card with a toolbar ROW below it (attach
 * circle, scrolling chips, pinned send) when the editor takes focus. A live run plus text queues
 * the message; a live run with an empty composer offers Stop (ComposerView.swift ComposerShell).
 *
 * Expansion is focus-driven, with the deterministic content triggers kept as a floor
 * (attachments, newline, more than 26 characters), so content is never measured.
 */
@Composable
fun ComposerShell(
    draft: String,
    onDraftChange: (String) -> Unit,
    sendEnabled: Boolean,
    showStop: Boolean,
    onSend: () -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String = "Message",
    sendLabel: String = "Send message",
    busy: Boolean = false,
    /** New-session composers stay expanded: the picker chips ARE the page. */
    alwaysExpanded: Boolean = false,
    /** Hold the expanded layout while a picker sheet is up, so it doesn't flap when the editor blurs. */
    keepExpanded: Boolean = false,
    onStop: () -> Unit = {},
    attachments: List<StagedAttachment> = emptyList(),
    onAttach: (() -> Unit)? = null,
    onRemoveAttachment: (String) -> Unit = {},
    chips: @Composable RowScope.() -> Unit,
) {
    val p = Theme.palette
    var focused by remember { mutableStateOf(false) }
    val compact = LocalConfiguration.current.screenHeightDp < 480
    val expanded = alwaysExpanded || keepExpanded || focused || attachments.isNotEmpty() || draft.contains('\n') || draft.length > 26
    val radius by animateDpAsState(if (expanded) 20.dp else 24.dp, Motion.resize(), label = "radius")
    val margin by animateDpAsState(if (focused) 10.dp else 16.dp, Motion.resize(), label = "margin")
    val shape = RoundedCornerShape(radius)
    val focus = remember { FocusRequester() }
    val hasContent = draft.trim().isNotEmpty() || attachments.isNotEmpty()
    val buttonActive = if (showStop && !hasContent) true else sendEnabled && hasContent && !busy

    val haptics = rememberHaptics()
    fun sendOrStop() {
        if (showStop && !hasContent) { haptics.medium(); onStop() } else if (buttonActive) { haptics.light(); onSend() }
    }

    @Composable
    fun SendButton() {
        Box(
            Modifier.size(44.dp).clip(CircleShape)
                .background(if (buttonActive) p.text else p.ink(0.10f), CircleShape)
                .clickable(enabled = buttonActive, role = Role.Button, onClick = ::sendOrStop)
                .semantics { contentDescription = if (showStop && !hasContent) "Stop response" else sendLabel },
            contentAlignment = Alignment.Center,
        ) {
            when {
                busy -> CircularProgressIndicator(Modifier.size(18.dp), color = p.bg, strokeWidth = 2.dp)
                showStop && !hasContent -> Box(Modifier.size(12.dp).background(p.bg, RoundedCornerShape(3.5.dp)))
                else -> GlyphView(Glyph.ArrowUp, 18.dp, if (buttonActive) p.bg else p.textFaint, strokeWidth = 2.4f)
            }
        }
    }

    Box(
        modifier.fillMaxWidth().padding(horizontal = margin),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.widthIn(max = 736.dp).fillMaxWidth()
                .glass(shape)
                .background(p.ink(0.04f), shape)
                .border(1.dp, p.hairline(0.05f), shape)
                // The whole glass surface focuses the editor, not just the field's own text box.
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { focus.requestFocus() }
                .padding(horizontal = if (expanded) 12.dp else 5.dp, vertical = if (expanded) 12.dp else 5.dp),
        ) {
            if (expanded && attachments.isNotEmpty()) {
                AttachmentStrip(attachments, onRemoveAttachment, Modifier.padding(bottom = 10.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    Modifier.weight(1f)
                        .padding(start = if (expanded) 4.dp else 13.dp, end = if (expanded) 4.dp else 0.dp, top = if (expanded) 4.dp else 5.dp, bottom = if (expanded) 4.dp else 5.dp)
                        .heightIn(min = if (expanded && !compact) 64.dp else 0.dp),
                    contentAlignment = if (expanded) Alignment.TopStart else Alignment.CenterStart,
                ) {
                    if (draft.isEmpty()) Text(placeholder, style = sans(17f), color = p.text.opacity(0.3f))
                    BasicTextField(
                        value = draft, onValueChange = onDraftChange,
                        textStyle = sans(17f, FontWeight.Normal, 24f).copy(color = p.text),
                        cursorBrush = SolidColor(p.text),
                        maxLines = if (compact) 2 else 7,
                        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
                        modifier = Modifier.fillMaxWidth()
                            .focusRequester(focus)
                            .onFocusChanged { focused = it.isFocused }
                            .semantics { contentDescription = placeholder }
                            // A hardware keyboard sends with Ctrl or Cmd + Enter.
                            .onPreviewKeyEvent { e ->
                                if (e.type == KeyEventType.KeyDown && e.key == Key.Enter && (e.isCtrlPressed || e.isMetaPressed)) {
                                    sendOrStop(); true
                                } else false
                            },
                    )
                }
                if (!expanded) SendButton()
            }
            if (expanded) {
                Row(
                    Modifier.fillMaxWidth().padding(top = if (compact) 0.dp else 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (onAttach != null) {
                        Box(
                            Modifier.size(44.dp).clip(CircleShape).background(p.ink(0.06f), CircleShape)
                                .border(1.dp, p.hairline(0.08f), CircleShape)
                                .clickable(enabled = !busy, role = Role.Button) { onAttach() }
                                .semantics { contentDescription = "Attach photos" },
                            contentAlignment = Alignment.Center,
                        ) { GlyphView(Glyph.Plus, 18.dp, p.textMuted, strokeWidth = 2f) }
                    }
                    // Chips scroll; the send button stays pinned. A trailing fade hints at more.
                    Row(
                        Modifier.weight(1f)
                            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                            .drawWithContent {
                                drawContent()
                                drawRect(
                                    Brush.horizontalGradient(listOf(Color.Black, Color.Transparent), startX = size.width - 24.dp.toPx(), endX = size.width),
                                    blendMode = BlendMode.DstIn,
                                )
                            }
                            .horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        content = chips,
                    )
                    SendButton()
                }
            }
        }
    }
}

/** The composer's picker trigger chip: optional brand mark, label, chevron: one per picker, split like the desktop's footer. */
@Composable
fun ComposerChip(label: String, modifier: Modifier = Modifier, badgeHarness: String? = null, onClick: () -> Unit) {
    val p = Theme.palette
    Row(
        modifier.height(40.dp)
            .clip(CircleShape)
            .background(p.ink(0.08f), CircleShape)
            .border(1.dp, p.hairline(0.08f), CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (badgeHarness != null) HarnessBadge(badgeHarness, 15.dp)
        Text(label, style = sans(13f, FontWeight.Medium), color = p.text.opacity(0.9f), maxLines = 1)
        GlyphView(Glyph.ChevronDown, 10.dp, p.textFaint, strokeWidth = 3f)
    }
}

/** Staged image attachments inside the pill (attachment-ui.tsx AttachmentStrip). */
@Composable
private fun AttachmentStrip(attachments: List<StagedAttachment>, remove: (String) -> Unit, modifier: Modifier = Modifier) {
    val p = Theme.palette
    Row(modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        attachments.forEach { att ->
            Box(Modifier.size(64.dp)) {
                val thumbnail by rememberThumbnail(att.uri)
                val shape = RoundedCornerShape(12.dp)
                Box(Modifier.size(64.dp).clip(shape).background(p.ink(0.08f), shape).border(1.dp, p.hairline(0.08f), shape)) {
                    thumbnail?.let { Image(it.asImageBitmap(), att.name, Modifier.size(64.dp), contentScale = androidx.compose.ui.layout.ContentScale.Crop) }
                }
                Box(
                    Modifier.align(Alignment.TopEnd).size(22.dp).clip(CircleShape).background(p.bg.opacity(0.85f), CircleShape)
                        .clickable { remove(att.id) }.semantics { contentDescription = "Remove ${att.name}" },
                    contentAlignment = Alignment.Center,
                ) { GlyphView(Glyph.Close, 11.dp, p.text, strokeWidth = 2.6f) }
            }
        }
    }
}

@Composable
private fun rememberThumbnail(uri: Uri) = run {
    val resolver = LocalContext.current.contentResolver
    produceState<Bitmap?>(null, uri) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1
                while (bounds.outWidth / sample > 256 && bounds.outHeight / sample > 256) sample *= 2
                resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            }.getOrNull()
        }
    }
}
