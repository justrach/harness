package harness.codegraff.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import harness.codegraff.android.model.ChangeRequestState
import harness.codegraff.android.model.ChangeRequestSummary
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.LineIcon
import harness.codegraff.android.theme.LineIconView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.mono
import harness.codegraff.android.theme.sans

@Composable
private fun ChangeRequestState.badgeColor(): Color {
    val p = Theme.palette
    return when (this) {
        ChangeRequestState.Open -> p.statusCompleted
        ChangeRequestState.Merged -> p.inlineCodeText
        ChangeRequestState.Closed -> p.danger
    }
}

enum class PullRequestBadgeSurface { SessionRow, Composer }

/**
 * Shared provider-neutral PR affordance. The full title stays available to screen readers
 * while narrow surfaces render only the stable numeric identity (PullRequestBadge.swift).
 */
@Composable
fun PullRequestBadge(
    summary: ChangeRequestSummary,
    modifier: Modifier = Modifier,
    surface: PullRequestBadgeSurface = PullRequestBadgeSurface.SessionRow,
) {
    val composer = surface == PullRequestBadgeSurface.Composer
    val color = summary.state.badgeColor()
    val shape = RoundedCornerShape(if (composer) 12.dp else 5.dp)
    val uriHandler = LocalUriHandler.current
    Row(
        modifier
            .height(if (composer) 40.dp else 18.dp)
            .clip(shape)
            .background(color.opacity(0.09f), shape)
            .border(1.dp, color.opacity(0.13f), shape)
            .clickable(role = Role.Button) { runCatching { uriHandler.openUri(summary.url) } }
            .semantics { contentDescription = summary.accessibilityLabel }
            .padding(horizontal = if (composer) 12.dp else 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (composer) 6.dp else 0.dp),
    ) {
        if (composer) LineIconView(LineIcon.PullRequest, 14.dp, color.opacity(0.9f))
        Text(
            "#${summary.number}", style = mono(if (composer) 12f else 10f, FontWeight.Medium),
            color = color.opacity(0.9f), maxLines = 1,
        )
    }
}

/** Read-only checkout context in an existing session's composer. */
@Composable
fun BranchContextChip(branch: String, modifier: Modifier = Modifier) {
    val p = Theme.palette
    Row(
        modifier
            .height(40.dp)
            .background(p.ink(0.06f), CircleShape)
            .border(1.dp, p.hairline(0.08f), CircleShape)
            .semantics(mergeDescendants = true) { contentDescription = "Branch $branch" }
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LineIconView(LineIcon.GitBranch, 14.dp, p.textMuted)
        Text(branch, style = sans(12f, FontWeight.Medium), color = p.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}
