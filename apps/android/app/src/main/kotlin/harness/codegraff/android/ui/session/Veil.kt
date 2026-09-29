package harness.codegraff.android.ui.session

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Streaming fade-in veil, a port of crates/ui/src/markdown/veil.rs (Veil.swift).
 *
 * Paint-only: newly appended text dissolves in by multiplying a fading alpha into its color. Spans
 * split at chunk boundaries and never change layout. Fade duration tracks the append cadence (an EMA
 * of inter-chunk gaps); a re-attach seeds the baseline so already-streamed text never re-fades.
 */
class RowVeil(
    seededLength: Int = 0,
    private val clock: () -> Double = { System.nanoTime() / 1_000_000.0 },
) {
    private class Span(val start: Int, val end: Int, val startMs: Double, val durationMs: Double)

    data class Segment(val start: Int, val end: Int, val alpha: Float)

    private val spans = ArrayList<Span>()
    private var settledLength = seededLength
    private var emaMs = EMA_SEED_MS
    private var lastAppendMs: Double? = null

    private fun covered() = settledLength + spans.sumOf { it.end - it.start }

    /** Register growth to [newLength]; the delta becomes a fading span. */
    fun noteLength(newLength: Int) {
        if (newLength <= covered()) return
        val now = clock()
        lastAppendMs?.let { last ->
            val gap = min(now - last, GAP_CLAMP_MS)
            emaMs = emaMs * 0.7 + gap * 0.3
        }
        lastAppendMs = now
        val from = covered()
        // Fast-stream boost: concurrent chunks fade slightly slower.
        val active = spans.count { now - it.startMs < it.durationMs }
        val boost = 1 + 0.3 * max(0, active - 2)
        val duration = min(max(emaMs * 3, MIN_FADE_MS), MAX_FADE_MS) * boost
        spans += Span(from, newLength, now, duration)
        prune(now)
    }

    private fun prune(now: Double) {
        var absorbed = 0
        for (span in spans) {
            if (now - span.startMs >= span.durationMs) absorbed = max(absorbed, span.end) else break
        }
        if (absorbed > 0) {
            settledLength = max(settledLength, absorbed)
            spans.removeAll { it.end <= absorbed }
        }
    }

    val isFading: Boolean
        get() {
            val now = clock()
            return spans.any { now - it.startMs < it.durationMs }
        }

    /** The veil as contiguous (range, alpha) segments over [totalLength] characters: settled text is 1, fading spans partial. */
    fun segments(totalLength: Int): List<Segment> {
        val now = clock()
        val out = ArrayList<Segment>()
        var cursor = 0
        for (span in spans.sortedBy { it.start }) {
            val lower = min(span.start, totalLength)
            val upper = min(span.end, totalLength)
            if (lower > cursor) out += Segment(cursor, lower, 1f)
            if (upper > lower) {
                val progress = ((now - span.startMs) / span.durationMs).coerceIn(0.0, 1.0)
                out += Segment(lower, upper, opacity(progress).toFloat())
            }
            cursor = max(cursor, upper)
        }
        if (cursor < totalLength) out += Segment(cursor, totalLength, 1f)
        return out
    }

    companion object {
        // veil.rs constants.
        const val EMA_SEED_MS = 160.0
        const val MIN_FADE_MS = 120.0
        const val MAX_FADE_MS = 400.0
        const val CURVE_POW = 1.6
        const val GAP_CLAMP_MS = 1000.0

        /** Alpha curve: 1 - (1-p)^1.6, fast attack and a soft landing. */
        fun opacity(progress: Double): Double = 1 - (1 - progress.coerceIn(0.0, 1.0)).pow(CURVE_POW)
    }
}

/** Keeps each row's fade clock across recomposition and lazy-list reuse. */
class VeilStore {
    private val veils = HashMap<String, RowVeil>()

    /**
     * The row's veil, with its current length registered. A first sight seeds the baseline, so a row that
     * already has text (reopening a chat mid-stream) never fades what was already on screen.
     */
    fun veil(rowId: String, length: Int): RowVeil {
        val existing = veils[rowId]
        if (existing != null) {
            // Register the delta before the text is built: doing it afterwards paints one opaque frame first.
            existing.noteLength(length)
            return existing
        }
        return RowVeil(seededLength = length).also { veils[rowId] = it }
    }
}
