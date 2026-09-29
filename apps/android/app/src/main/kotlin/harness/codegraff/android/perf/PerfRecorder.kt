package harness.codegraff.android.perf

import kotlin.math.ceil

/** Timing for one named operation over the last [PerfRecorder.capacity] runs. */
data class SpanStat(
    val name: String,
    val count: Long,
    val p50: Double,
    val p95: Double,
    val max: Double,
    /** Lifetime time spent in this operation, so the list can put the costliest first. */
    val totalMs: Double,
    /** Runs that went over the operation's budget. */
    val overBudget: Long,
)

/**
 * Keeps a bounded window of durations per operation name. Pure Kotlin so the maths is unit-testable; [Perf]
 * is the Android-facing wrapper that feeds it.
 */
class PerfRecorder(private val capacity: Int = 128) {
    private class Series(capacity: Int) {
        val ring = DoubleArray(capacity)
        var next = 0
        var filled = 0
        var count = 0L
        var totalMs = 0.0
        var max = 0.0
        var overBudget = 0L
    }

    private val series = LinkedHashMap<String, Series>()

    @Synchronized
    fun record(name: String, ms: Double, budgetMs: Double = Double.MAX_VALUE) {
        val s = series.getOrPut(name) { Series(capacity) }
        s.ring[s.next] = ms
        s.next = (s.next + 1) % capacity
        if (s.filled < capacity) s.filled++
        s.count++
        s.totalMs += ms
        if (ms > s.max) s.max = ms
        if (ms > budgetMs) s.overBudget++
    }

    @Synchronized
    fun stats(): List<SpanStat> = series.map { (name, s) ->
        val window = s.ring.copyOf(s.filled).also { it.sort() }
        SpanStat(name, s.count, percentile(window, 0.50), percentile(window, 0.95), s.max, s.totalMs, s.overBudget)
    }.sortedByDescending { it.totalMs }

    @Synchronized
    fun reset() = series.clear()

    companion object {
        /** Nearest-rank percentile of an ascending array. */
        fun percentile(sorted: DoubleArray, q: Double): Double {
            if (sorted.isEmpty()) return 0.0
            val rank = ceil(q * sorted.size).toInt().coerceIn(1, sorted.size)
            return sorted[rank - 1]
        }
    }
}

/** Where a frame's time went, by the stage the platform reports. */
enum class FrameStage(val label: String) {
    Input("Touch handling"),
    Animation("Compose and animations"),
    Layout("Measure and layout"),
    Draw("Drawing"),
    Sync("Uploading to the GPU"),
    Commands("Rendering"),
    Swap("Waiting on the GPU or display"),
}

/**
 * Counts frames and blames each slow one on the stage that took longest, which is the part scroll
 * numbers alone cannot say: a 30 ms frame spent in layout needs a different fix than one spent in drawing.
 */
class FrameTally {
    var frames = 0L
        private set
    var slow = 0L
        private set
    var frozen = 0L
        private set
    private val slowBlame = LongArray(FrameStage.entries.size)
    private val stageTotals = DoubleArray(FrameStage.entries.size)
    private val totals = PerfRecorder(capacity = 512)

    @Synchronized
    fun add(totalMs: Double, stagesMs: DoubleArray, budgetMs: Double) {
        frames++
        totals.record("frame", totalMs)
        for (i in stagesMs.indices) stageTotals[i] += stagesMs[i]
        if (totalMs > FROZEN_MS) frozen++
        if (totalMs > budgetMs) {
            slow++
            slowBlame[stagesMs.indices.maxByOrNull { stagesMs[it] } ?: 0]++
        }
    }

    @Synchronized
    fun snapshot(): FrameSummary {
        val frame = totals.stats().firstOrNull()
        return FrameSummary(
            frames, slow, frozen,
            p50 = frame?.p50 ?: 0.0, p95 = frame?.p95 ?: 0.0, worst = frame?.max ?: 0.0,
            slowFramesBlamedOn = FrameStage.entries.mapIndexed { i, st -> st to slowBlame[i] }.filter { it.second > 0 }.sortedByDescending { it.second },
            meanStageMs = FrameStage.entries.mapIndexed { i, st -> st to (if (frames == 0L) 0.0 else stageTotals[i] / frames) },
        )
    }

    @Synchronized
    fun reset() {
        frames = 0; slow = 0; frozen = 0
        slowBlame.fill(0); stageTotals.fill(0.0); totals.reset()
    }

    companion object {
        /** Android's own cut-off for a frozen frame. */
        const val FROZEN_MS = 700.0
    }
}

data class FrameSummary(
    val frames: Long,
    val slow: Long,
    val frozen: Long,
    val p50: Double,
    val p95: Double,
    val worst: Double,
    val slowFramesBlamedOn: List<Pair<FrameStage, Long>>,
    val meanStageMs: List<Pair<FrameStage, Double>>,
) {
    val slowPercent: Double get() = if (frames == 0L) 0.0 else 100.0 * slow / frames
}
