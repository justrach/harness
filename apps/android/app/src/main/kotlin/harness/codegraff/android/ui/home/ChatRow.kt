package harness.codegraff.android.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import harness.codegraff.android.WorkspaceState
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.model.relativeTime
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.HarnessBadge
import harness.codegraff.android.theme.LineIcon
import harness.codegraff.android.theme.LineIconView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans
import harness.codegraff.android.ui.components.MiniSpinner
import harness.codegraff.android.ui.components.PullRequestBadge
import harness.codegraff.android.ui.components.StatusCorner
import harness.codegraff.android.ui.components.pressWashClickable

/** "project @ device", the project name in its own tint (projectless sessions stay muted). */
@Composable
fun projectLocation(chat: Chat, state: WorkspaceState): AnnotatedString {
    val device = state.deviceName(chat.deviceId)
    val spaceId = chat.spaceId ?: return AnnotatedString("No project @ $device")
    val project = state.space(chat)?.displayName ?: chat.cwd?.trimEnd('/')?.substringAfterLast('/') ?: "?"
    val tint = Theme.palette.projectTint(spaceId)
    return buildAnnotatedString {
        withStyle(SpanStyle(color = tint)) { append(project) }
        append(" @ $device")
    }
}

/**
 * The desktop session row (shell.rs `render_chat_row`), line for line: a muted context line
 * with the status word in the corner (dot + word; Done keeps its pop with a check; idle rows
 * carry the time-ago there instead); the title on its own line; harness mark and branch close it
 * out, with the mini spinner riding the row's bottom-right while Working. The context line reads
 * "space @ device" because the phone's list interleaves every device (HomeView.swift ChatRow).
 */
@Composable
fun ChatRow(chat: Chat, state: WorkspaceState, showLocation: Boolean, modifier: Modifier = Modifier, onSelect: () -> Unit) {
    val p = Theme.palette
    val indicator = state.indicator(chat)
    val pullRequest = state.changeRequest(chat)
    val subline = p.textMuted.opacity(0.5f)
    val pinned = state.isPinned(chat.id)
    val time = relativeTime(chat.lastMessageAt ?: chat.createdAt, state.now)
    val description = "${chat.displayTitle}, ${state.deviceName(chat.deviceId)}, ${indicator.label ?: time}"

    Box(modifier.fillMaxWidth()) {
        Column(
            Modifier.fillMaxWidth()
                .pressWashClickable(onSelect, cornerRadius = 8.dp)
                .semantics(mergeDescendants = true) { contentDescription = description }
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            // Line 1: space @ device, status corner (time-ago when idle).
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (showLocation) {
                    Text(
                        projectLocation(chat, state), style = sans(13f), color = subline,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                    )
                } else {
                    Spacer(Modifier.weight(1f))
                }
                if (indicator == ChatIndicator.Idle) {
                    Text(time, style = sans(12f, FontWeight.Medium), color = subline, maxLines = 1)
                } else {
                    StatusCorner(indicator)
                }
            }
            // Line 2: the session title.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (pinned) GlyphView(Glyph.Pin, 12.dp, p.textMuted, strokeWidth = 2f)
                Text(
                    chat.displayTitle, style = sans(17f, FontWeight.Medium), color = p.text,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
            }
            // Line 3: harness brand mark, then the branch when the engine stamped one; the Working spinner rides bottom-right.
            Row(
                Modifier.padding(end = if (pullRequest != null) 46.dp else 0.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                chat.config?.harness?.let { HarnessBadge(it, 11.dp, neutral = subline) }
                chat.branch?.trim()?.takeIf { it.isNotEmpty() }?.let { branch ->
                    LineIconView(LineIcon.GitBranch, 11.dp, subline)
                    Text(branch, style = sans(13f), color = subline, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.weight(1f))
                if (indicator == ChatIndicator.Working) MiniSpinner()
            }
        }
        if (pullRequest != null) {
            PullRequestBadge(pullRequest, Modifier.align(Alignment.BottomEnd).padding(end = 8.dp, bottom = 6.dp))
        }
    }
}
