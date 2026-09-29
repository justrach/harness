package harness.codegraff.android.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import harness.codegraff.android.theme.opacity
import harness.codegraff.android.theme.Motion
import harness.codegraff.android.theme.Theme
import harness.codegraff.android.theme.rememberReduceMotion
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

// Loaders and status indicators: ports of crates/ui/src/loaders.rs (Loaders.swift).
// gradient-spin-pulse: a 3x3 cell grid with per-row "sunrise" tints; each cell pulses
// once per 750ms with phase = distance from bottom-center, so the wave travels upward.

private object GradientSpin {
    /** GSPIN_ROW_TINTS: row 0 cool blue, row 1 amber, row 2 pink. */
    val rowTints = listOf(Color(0xFFB6D3EF), Color(0xFFEDB185), Color(0xFFF888A0))
    const val DIM = 0.1f

    /** Opacity keyframe (motion.rs gspin_opacity): full at 0, ease down to dim by 45%, hold to 92%, rise to full. */
    fun opacity(phase: Float): Float {
        val p = ((phase % 1f) + 1f) % 1f
        if (p < 0.45f) {
            val t = p / 0.45f
            return 1f - (1f - DIM) * (t * t * (3f - 2f * t))
        }
        if (p < 0.92f) return DIM
        val t = (p - 0.92f) / 0.08f
        return DIM + (1f - DIM) * t
    }
}

/** 0..1 sawtooth over [periodMs]; frozen at 0 when animations are off. */
@Composable
private fun rememberCycle(periodMs: Int): State<Float> {
    val reduce = rememberReduceMotion()
    if (reduce) return remember { object : State<Float> { override val value = 0f } }
    return rememberInfiniteTransition(label = "loader").animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(periodMs, easing = LinearEasing), RepeatMode.Restart),
        label = "cycle",
    )
}

/** 3x3 working indicator for the status strip (cell 2.5, arrow-up wave). */
@Composable
fun WorkingSpinner(cellSize: Dp = 2.5.dp, modifier: Modifier = Modifier) {
    val t by rememberCycle(Motion.GRADIENT_SPIN_MS)
    val gap = cellSize * 0.8f
    val total = cellSize * 3 + gap * 2
    Canvas(modifier.size(total)) {
        val cell = cellSize.toPx()
        val g = gap.toPx()
        for (row in 0 until 3) for (col in 0 until 3) {
            val dx = (col - 1).toFloat()
            val dy = (2 - row).toFloat() // distance from bottom-center
            val dist = sqrt(dx * dx + dy * dy) / 2.5f
            drawRect(
                GradientSpin.rowTints[row].opacity(GradientSpin.opacity(t - dist)),
                topLeft = Offset(col * (cell + g), row * (cell + g)), size = Size(cell, cell),
            )
        }
    }
}

/** 2x3 mini spinner: cells snake clockwise around the perimeter (loaders.rs mini_gradient_spinner). */
@Composable
fun MiniSpinner(cellSize: Dp = 2.dp, modifier: Modifier = Modifier) {
    val t by rememberCycle(Motion.GRADIENT_SPIN_MS)
    val gap = cellSize * 0.8f
    val ring = listOf(0 to 0, 0 to 1, 1 to 1, 2 to 1, 2 to 0, 1 to 0)
    Canvas(modifier.size(width = cellSize * 2 + gap, height = cellSize * 3 + gap * 2)) {
        val cell = cellSize.toPx()
        val g = gap.toPx()
        for (row in 0 until 3) for (col in 0 until 2) {
            val phase = ring.indexOf(row to col).coerceAtLeast(0).toFloat() / ring.size
            drawRect(
                GradientSpin.rowTints[row].opacity(GradientSpin.opacity(t - phase)),
                topLeft = Offset(col * (cell + g), row * (cell + g)), size = Size(cell, cell),
            )
        }
    }
}

/** harness-pulse loading row: 5 cells, cosine wave, stagger 0.15/2.4 (loaders.rs:91). */
@Composable
fun HarnessPulse(cellSize: Dp = 6.dp, modifier: Modifier = Modifier) {
    val t by rememberCycle(Motion.HARNESS_PULSE_MS)
    val color = Theme.palette.text
    val gap = cellSize / 2
    Canvas(modifier.size(width = cellSize * 5 + gap * 4, height = cellSize)) {
        val cell = cellSize.toPx()
        val g = gap.toPx()
        for (ix in 0 until 5) {
            val phase = (((t - ix * (0.15f / 2.4f)) % 1f) + 1f) % 1f
            val wave = (1f - cos(phase * 2f * PI.toFloat())) / 2f
            val scale = 0.9f + 0.1f * wave
            val side = cell * scale
            val inset = (cell - side) / 2
            drawRoundRect(
                color.opacity(0.08f + 0.92f * wave),
                topLeft = Offset(ix * (cell + g) + inset, inset), size = Size(side, side),
                cornerRadius = CornerRadius(cell * 0.25f),
            )
        }
    }
}

/**
 * Loading placeholder in the transcript's own geometry: paragraph clusters, a trailing
 * user bubble, a tool chip, bottom-weighted like a real conversation tail. Blocks breathe
 * with a slight stagger; static under reduced motion.
 */
@Composable
fun TranscriptSkeleton(modifier: Modifier = Modifier) {
    val t by rememberCycle(2000)
    val reduce = rememberReduceMotion()
    fun breathe(ix: Int): Float {
        if (reduce) return 0.7f
        val phase = t - ix * 0.12f
        return 0.45f + 0.275f * (1f + sin(phase * 2f * PI.toFloat()))
    }
    val p = Theme.palette
    Column(
        modifier.fillMaxSize().padding(horizontal = 16.dp).padding(bottom = 56.dp),
        verticalArrangement = Arrangement.spacedBy(26.dp, Alignment.Bottom),
    ) {
        @Composable fun paragraph(fractions: List<Float>, ix: Int) {
            Column(Modifier.graphicsLayer { alpha = breathe(ix) }, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                fractions.forEach { f ->
                    Box(Modifier.fillMaxWidth(f).height(12.dp).background(p.ink(0.06f), RoundedCornerShape(4.dp)))
                }
            }
        }
        paragraph(listOf(0.92f, 0.8f, 0.55f), 0)
        Box(Modifier.fillMaxWidth().graphicsLayer { alpha = breathe(1) }, contentAlignment = Alignment.CenterEnd) {
            Box(Modifier.width(230.dp).height(42.dp).background(p.ink(0.07f), RoundedCornerShape(Theme.bubbleRadius)))
        }
        paragraph(listOf(0.85f, 0.62f), 2)
        Box(
            Modifier.fillMaxWidth(0.7f).widthIn(max = 360.dp).height(30.dp).graphicsLayer { alpha = breathe(3) }
                .background(p.ink(0.03f), RoundedCornerShape(9.dp)),
        )
        paragraph(listOf(0.9f, 0.78f, 0.42f), 4)
    }
}
