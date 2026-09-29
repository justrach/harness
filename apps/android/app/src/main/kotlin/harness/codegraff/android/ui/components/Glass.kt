package harness.codegraff.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Theme

/**
 * The floating surface SwiftUI paints with `glassEffect`: a translucent panel over
 * the content with a hairline edge. Android has no system glass material, so this is
 * the palette's shell color at high opacity plus a faint ink wash; [elevated] adds the
 * soft drop shadow floating pills carry.
 */
@Composable
fun Modifier.glass(shape: Shape, elevated: Boolean = false, wash: Float = 0.04f): Modifier {
    val p = Theme.palette
    return this
        .then(if (elevated) Modifier.shadow(10.dp, shape, ambientColor = Color.Black.copy(0.25f), spotColor = Color.Black.copy(0.25f)) else Modifier)
        .clip(shape)
        .background(p.surface.opacity(0.9f))
        .background(p.ink(wash))
        .border(1.dp, p.hairline(0.06f), shape)
}

/** A 44dp circular glass button with centered content (the nav bar's plus, person and back buttons). */
@Composable
fun GlassCircleButton(
    onClick: () -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    size: Dp = 44.dp,
    content: @Composable () -> Unit,
) {
    Box(
        modifier
            .size(size)
            .glass(CircleShape, elevated = true)
            .clickable(onClick = onClick, role = Role.Button)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { content() }
}

/** Brief hover-colored wash while a row or chip is pressed (SwiftUI `PressWashButtonStyle`). */
@Composable
fun Modifier.pressWashClickable(
    onClick: () -> Unit,
    cornerRadius: Dp = 8.dp,
    enabled: Boolean = true,
    role: Role = Role.Button,
): Modifier {
    val source = remember { MutableInteractionSource() }
    // The pressed state is read while drawing, so a touch repaints the wash without recomposing
    // the row, and no per-row clip layer is needed (the wash itself is a rounded rect).
    val pressed = source.collectIsPressedAsState()
    val wash = Theme.palette.elementHover
    return this
        .drawBehind { if (pressed.value) drawRoundRect(wash, cornerRadius = CornerRadius(cornerRadius.toPx())) }
        .clickable(interactionSource = source, indication = null, enabled = enabled, role = role, onClick = onClick)
}
