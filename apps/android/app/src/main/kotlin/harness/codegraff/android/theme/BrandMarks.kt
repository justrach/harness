package harness.codegraff.android.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.min

/**
 * Harness brand marks: the exact SVG path data the desktop bundles, parsed once
 * and drawn aspect-fit. Marks tint with the caller's color like any glyph; Claude
 * keeps its brand orange (BrandMarks.swift).
 */
enum class BrandMark(
    val viewBoxWidth: Float,
    val viewBoxHeight: Float,
    /** The source SVG's fill rule; the shape must fill even-odd where the asset says so or its holes fill in solid. */
    val evenOddFill: Boolean,
    internal val pathData: String,
) {
    Claude(256f, 257f, false, BrandMarkPaths.CLAUDE),
    OpenAi(256f, 260f, false, BrandMarkPaths.OPENAI),
    Cursor(466.73f, 532.09f, false, BrandMarkPaths.CURSOR),
    Devin(263f, 300f, false, BrandMarkPaths.DEVIN),
    Grok(16f, 16f, false, BrandMarkPaths.GROK),
    Hermes(24f, 24f, true, BrandMarkPaths.HERMES),
    Pi(800f, 800f, true, BrandMarkPaths.PI),
    OpenCode(24f, 30f, true, BrandMarkPaths.OPENCODE),
    Antigravity(24f, 24f, true, BrandMarkPaths.ANTIGRAVITY);

    companion object {
        fun forHarness(harness: String): BrandMark = when (harness) {
            "codex" -> OpenAi
            "cursor" -> Cursor
            "devin" -> Devin
            "grok" -> Grok
            "hermes" -> Hermes
            "pi" -> Pi
            "opencode" -> OpenCode
            "antigravity" -> Antigravity
            else -> Claude // claude-code and mock share the mark, like the desktop
        }

        /** Claude orange, the same in every theme. */
        val ClaudeBrand = Color(0xFFD97757)

        /** The mark's OWN color, or null when it has none and takes the caller's. */
        fun brandTint(harness: String): Color? = when (harness) {
            "claude-code", "mock" -> ClaudeBrand
            else -> null // codex, cursor, devin, grok, hermes, pi are monochrome marks
        }
    }
}

private val parsedPaths = HashMap<BrandMark, Path>()

private fun BrandMark.path(): Path = synchronized(parsedPaths) {
    parsedPaths.getOrPut(this) {
        PathParser().parsePathString(pathData).toPath().also {
            it.fillType = if (evenOddFill) PathFillType.EvenOdd else PathFillType.NonZero
        }
    }
}

@Composable
fun BrandMarkIcon(mark: BrandMark, size: Dp, color: Color, modifier: Modifier = Modifier) {
    val path = remember(mark) { mark.path() }
    Canvas(modifier.size(size)) {
        val scale = min(this.size.width / mark.viewBoxWidth, this.size.height / mark.viewBoxHeight)
        val dx = (this.size.width - mark.viewBoxWidth * scale) / 2
        val dy = (this.size.height - mark.viewBoxHeight * scale) / 2
        withTransform({
            translate(dx, dy)
            scale(scale, scale, pivot = Offset.Zero)
        }) { drawPath(path, color) }
    }
}

/**
 * Harness brand mark for a harness id. Claude keeps its orange even on the mono
 * surface; others take [neutral] (HarnessBadge in Loaders.swift).
 */
@Composable
fun HarnessBadge(
    harness: String,
    size: Dp = 14.dp,
    dimmed: Boolean = false,
    neutral: Color = Theme.palette.text,
    modifier: Modifier = Modifier,
) {
    val tint = (BrandMark.brandTint(harness) ?: neutral).opacity(if (dimmed) 0.6f else 0.9f)
    BrandMarkIcon(BrandMark.forHarness(harness), size, tint, modifier)
}

/** The compact CodeGraff-aligned Harness mark used on sign-in and the new-session canvas. */
@Composable
fun HarnessMark(size: Dp, color: Color = Theme.palette.text, modifier: Modifier = Modifier) {
    Canvas(modifier.size(size)) {
        val scale = min(this.size.width, this.size.height) / 1000f
        val dx = (this.size.width - 1000f * scale) / 2
        val dy = (this.size.height - 1000f * scale) / 2
        withTransform({
            translate(dx, dy)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
            val ring = Path().apply {
                moveTo(778f, 275f)
                cubicTo(678f, 180f, 545f, 160f, 418f, 205f)
                cubicTo(272f, 255f, 212f, 389f, 222f, 526f)
                cubicTo(234f, 700f, 371f, 812f, 531f, 814f)
                cubicTo(650f, 817f, 733f, 772f, 794f, 722f)
            }
            drawPath(ring, color, style = Stroke(width = 108f, cap = StrokeCap.Round))
            val glyphs = listOf(
                listOf(Offset(456f, 457f), Offset(383f, 500f), Offset(456f, 543f)),
                listOf(Offset(536f, 437f), Offset(493f, 563f)),
                listOf(Offset(578f, 457f), Offset(651f, 500f), Offset(578f, 543f)),
            )
            for (points in glyphs) {
                val glyph = Path().apply {
                    moveTo(points.first().x, points.first().y)
                    points.drop(1).forEach { lineTo(it.x, it.y) }
                }
                drawPath(glyph, color, style = Stroke(width = 31f, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            val pixels = listOf(
                Triple(802f, 455f, 27f), Triple(849f, 495f, 38f), Triple(790f, 552f, 48f),
                Triple(860f, 574f, 23f), Triple(823f, 630f, 34f), Triple(893f, 662f, 18f),
            )
            for ((x, y, s) in pixels) {
                drawRoundRect(
                    color, topLeft = Offset(x, y), size = Size(s, s),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(s / 7, s / 7),
                )
            }
        }
    }
}
