package harness.codegraff.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import harness.codegraff.android.model.ChatIndicator
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Glyph
import harness.codegraff.android.theme.GlyphView
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.sans

/** shell/spaces.rs status_dot_color: non-done states are muted (running is routine); only Done keeps its pop. */
@Composable
fun ChatIndicator.dotColor(): Color {
    val p = Theme.palette
    return when (this) {
        ChatIndicator.Working -> p.statusWorking.opacity(0.55f)
        ChatIndicator.AwaitingInput -> p.accent.opacity(0.6f)
        ChatIndicator.Errored -> p.danger.opacity(0.65f)
        ChatIndicator.Completed -> p.statusCompleted.opacity(0.9f)
        ChatIndicator.Idle -> p.ink(0.14f)
    }
}

/** The session row's top-right status glyph: a 6dp dot and the status word in the same color; Done trades the dot for a check. */
@Composable
fun StatusCorner(indicator: ChatIndicator) {
    val color = indicator.dotColor()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (indicator == ChatIndicator.Completed) {
            GlyphView(Glyph.Check, 10.dp, color, strokeWidth = 2.6f)
        } else {
            Row(Modifier.size(6.dp).background(color, CircleShape)) {}
        }
        indicator.label?.let { Text(it, style = sans(10f, FontWeight.Medium), color = color) }
    }
}
