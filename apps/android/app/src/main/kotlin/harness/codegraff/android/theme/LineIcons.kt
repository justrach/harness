package harness.codegraff.android.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.min

/**
 * Stroked UI glyphs: the desktop's hand-drawn Solar-Linear-style icons (LineIcons.swift),
 * same path data, stroked at 1.5 in a 24 unit box with round caps.
 */
enum class LineIcon(val paths: List<String>, val circles: List<Triple<Float, Float, Float>>) {
    GitBranch(
        listOf("M6.5 7.75v8.5", "M17.5 9.75c0 2.9-2.6 4.35-6.2 4.72c-1.9.2-3.3.9-4 2.03"),
        listOf(Triple(6.5f, 5.5f, 2.25f), Triple(6.5f, 18.5f, 2.25f), Triple(17.5f, 7.5f, 2.25f)),
    ),
    PullRequest(
        listOf("M6 7.25v9.5", "M15 5h.75A2.25 2.25 0 0 1 18 7.25v9.5", "m12.75 7.75 2.5-2.75-2.5-2.75"),
        listOf(Triple(6f, 5f, 2.25f), Triple(6f, 19f, 2.25f), Triple(18f, 19f, 2.25f)),
    ),
    Folder(
        listOf(
            "M18 10h-5",
            "M2 6.95c0-.883 0-1.324.07-1.692A4 4 0 0 1 5.257 2.07C5.626 2 6.068 2 6.95 2c.386 0 .58 0 .766.017a4 4 0 0 1 2.18.904c.144.119.28.255.554.529L11 4c.816.816 1.224 1.224 1.712 1.495a4 4 0 0 0 .848.352C14.098 6 14.675 6 15.828 6h.374c2.632 0 3.949 0 4.804.77q.119.105.224.224c.77.855.77 2.172.77 4.804V14c0 3.771 0 5.657-1.172 6.828S17.771 22 14 22h-4c-3.771 0-5.657 0-6.828-1.172S2 17.771 2 14z",
        ),
        emptyList(),
    ),
    FolderWithFiles(
        listOf(
            "M18 10h-5",
            "M10 3h6.5c.464 0 .697 0 .892.026a3 3 0 0 1 2.582 2.582c.026.195.026.428.026.892",
            "M2 6.95c0-.883 0-1.324.07-1.692A4 4 0 0 1 5.257 2.07C5.626 2 6.068 2 6.95 2c.386 0 .58 0 .766.017a4 4 0 0 1 2.18.904c.144.119.28.255.554.529L11 4c.816.816 1.224 1.224 1.712 1.495a4 4 0 0 0 .848.352C14.098 6 14.675 6 15.828 6h.374c2.632 0 3.949 0 4.804.77q.119.105.224.224c.77.855.77 2.172.77 4.804V14c0 3.771 0 5.657-1.172 6.828S17.771 22 14 22h-4c-3.771 0-5.657 0-6.828-1.172S2 17.771 2 14z",
        ),
        emptyList(),
    ),
}

@Composable
fun LineIconView(icon: LineIcon, size: Dp = 14.dp, color: Color = Theme.palette.textMuted, modifier: Modifier = Modifier) {
    val paths = remember(icon) { icon.paths.map { PathParser().parsePathString(it).toPath() } }
    Canvas(modifier.size(size)) {
        val scale = min(this.size.width, this.size.height) / 24f
        val dx = (this.size.width - 24f * scale) / 2
        val dy = (this.size.height - 24f * scale) / 2
        withTransform({
            translate(dx, dy)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
            val stroke = Stroke(width = 1.5f, cap = StrokeCap.Round, join = StrokeJoin.Round)
            paths.forEach { drawPath(it, color, style = stroke) }
            icon.circles.forEach { (cx, cy, r) -> drawCircle(color, radius = r, center = Offset(cx, cy), style = stroke) }
        }
    }
}
