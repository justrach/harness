package harness.codegraff.android.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.min

/**
 * The UI glyphs SwiftUI takes from SF Symbols (chevrons, plus, arrow.up, person.circle,
 * archivebox, pin, ...), drawn as 24-unit stroked paths (Lucide, ISC licensed) so they
 * tint and scale like the rest of the icon set.
 */
enum class Glyph(
    val paths: List<String>,
    val circles: List<Triple<Float, Float, Float>> = emptyList(),
    /** x, y, width, height, corner radius. */
    val rects: List<List<Float>> = emptyList(),
) {
    ArrowUp(listOf("M12 19V5", "M5 12l7-7 7 7")),
    ChevronDown(listOf("m6 9 6 6 6-6")),
    ChevronUp(listOf("m18 15-6-6-6 6")),
    ChevronRight(listOf("m9 18 6-6-6-6")),
    ChevronLeft(listOf("m15 18-6-6 6-6")),
    Check(listOf("M20 6 9 17l-5-5")),
    Plus(listOf("M5 12h14", "M12 5v14")),
    Close(listOf("M18 6 6 18", "M6 6l12 12")),
    Search(listOf("m21 21-4.3-4.3"), circles = listOf(Triple(11f, 11f, 8f))),
    PersonCircle(
        listOf("M7 20.662V19a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v1.662"),
        circles = listOf(Triple(12f, 12f, 10f), Triple(12f, 10f, 3f)),
    ),
    Pin(
        listOf(
            "M12 17v5",
            "M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z",
        ),
    ),
    Archive(listOf("M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8", "M10 12h4"), rects = listOf(listOf(2f, 3f, 20f, 5f, 1f))),
    Folder(listOf("M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z")),
    Laptop(listOf("M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9m16 0H4m16 0 1.28 2.55a1 1 0 0 1-.9 1.45H3.62a1 1 0 0 1-.9-1.45L4 16")),
    Server(
        listOf("M6 6h.01", "M6 18h.01"),
        rects = listOf(listOf(2f, 2f, 20f, 8f, 2f), listOf(2f, 14f, 20f, 8f, 2f)),
    ),
    Monitor(listOf("M8 21h8", "M12 17v4"), rects = listOf(listOf(2f, 3f, 20f, 14f, 2f))),
    Phone(listOf("M12 18h.01"), rects = listOf(listOf(5f, 2f, 14f, 20f, 2f))),
    Terminal(listOf("m4 17 6-6-6-6", "M12 19h8")),
    File(
        listOf(
            "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z", "M14 2v4a2 2 0 0 0 2 2h4",
            "M10 9H8", "M16 13H8", "M16 17H8",
        ),
    ),
    FilePlus(
        listOf("M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z", "M14 2v4a2 2 0 0 0 2 2h4", "M9 15h6", "M12 18v-6"),
    ),
    Pencil(listOf("M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z")),
    Globe(
        listOf("M2 12h20", "M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"),
        circles = listOf(Triple(12f, 12f, 10f)),
    ),
    Checklist(listOf("M9 6h11", "M9 12h11", "M9 18h11", "M4 6l1 1 2-2", "M4 12l1 1 2-2", "M4 18l1 1 2-2")),
    Grid(listOf("M3 3h7v7H3z", "M14 3h7v7h-7z", "M14 14h7v7h-7z", "M3 14h7v7H3z")),
    Warning(listOf("m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z", "M12 9v4", "M12 17h.01")),
    Chat(listOf("M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z")),
    Photo(listOf("m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"), circles = listOf(Triple(9f, 9f, 2f)), rects = listOf(listOf(3f, 3f, 18f, 18f, 2f))),
    FolderPlus(
        listOf(
            "M12 10v6", "M9 13h6",
            "M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z",
        ),
    ),
    Layers(
        listOf(
            "m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z",
            "M22 17.65l-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65", "M22 12.65l-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65",
        ),
    ),
    List(listOf("M3 6h.01", "M8 6h13", "M3 12h.01", "M8 12h13", "M3 18h.01", "M8 18h13")),
    Trash(listOf("M3 6h18", "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6", "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2")),
    Unarchive(listOf("M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8", "M12 17v-6", "m9 14 3-3 3 3"), rects = listOf(listOf(2f, 3f, 20f, 5f, 1f))),
}

@Composable
fun GlyphView(
    glyph: Glyph,
    size: Dp = 16.dp,
    color: Color = Theme.palette.textMuted,
    strokeWidth: Float = 1.9f,
    modifier: Modifier = Modifier,
) {
    val paths = remember(glyph) { glyph.paths.map { PathParser().parsePathString(it).toPath() } }
    Canvas(modifier.size(size)) {
        val scale = min(this.size.width, this.size.height) / 24f
        val dx = (this.size.width - 24f * scale) / 2
        val dy = (this.size.height - 24f * scale) / 2
        withTransform({
            translate(dx, dy)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
            val stroke = Stroke(width = strokeWidth, cap = StrokeCap.Round, join = StrokeJoin.Round)
            paths.forEach { drawPath(it, color, style = stroke) }
            glyph.circles.forEach { (cx, cy, r) -> drawCircle(color, radius = r, center = Offset(cx, cy), style = stroke) }
            glyph.rects.forEach { (x, y, w, h, r) ->
                drawRoundRect(color, topLeft = Offset(x, y), size = Size(w, h), cornerRadius = CornerRadius(r, r), style = stroke)
            }
        }
    }
}
