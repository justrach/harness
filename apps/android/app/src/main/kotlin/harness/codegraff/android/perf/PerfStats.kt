package harness.codegraff.android.perf

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.floor
import kotlin.math.max

/**
 * The anonymous performance batch the apps send when sharing is on. It is the desktop app's format: samples are
 * counted into fixed ranges, so batches from any number of launches add up to exact fleet percentiles. Numbers and
 * fixed names only: no chat content, account, device or session identifiers, and the id is random per launch.
 * `apps/parity/vectors/perf-stats.json` pins the JSON; the iOS app builds the same shape.
 */
object PerfMetric {
    const val AppLaunch = "app_launch_ms"
    const val ConversationLoad = "conversation_load_ms"
    const val TranscriptRows = "transcript_rows_ms"
    const val MarkdownParse = "markdown_parse_ms"
    const val HomeGroup = "home_group_ms"
    const val SendApply = "send_apply_ms"
    const val MainStall = "main_stall_ms"
    /** One frame's render cost on Android. iOS reports `main_turn_ms` instead: the two are not the same measure. */
    const val FrameCost = "frame_cost_ms"

    /** The order metrics appear in a batch. `main_turn_ms` is iOS only and never sent from here. */
    val ORDER = listOf(
        AppLaunch, ConversationLoad, TranscriptRows, MarkdownParse, HomeGroup, SendApply, MainStall, FrameCost, "main_turn_ms",
    )

    /** The batch name of each timed operation. */
    val forSpan: Map<String, String> = mapOf(
        PerfSpan.StartupFirstFrame to AppLaunch,
        PerfSpan.NavigationOpen to ConversationLoad,
        PerfSpan.TranscriptRows to TranscriptRows,
        PerfSpan.MarkdownParse to MarkdownParse,
        PerfSpan.HomeGroup to HomeGroup,
        PerfSpan.SendApply to SendApply,
        PerfSpan.MainStall to MainStall,
    )
}

class PerfMetricBatch(val name: String, val count: Long, val sumMs: Double, val maxMs: Double, val buckets: LongArray)

class PerfWindow(val startMs: Long, val endMs: Long, val metrics: List<PerfMetricBatch>)

/**
 * Samples since the last upload, counted into the desktop app's fixed ranges. A window that could not be sent is put
 * back and merges into the next one. Recording is a bucket lookup and an add, cheap enough for every frame.
 */
class PerfHistograms(private val now: () -> Long = System::currentTimeMillis) {
    private class Histogram {
        var count = 0L
        var sumMs = 0.0
        var maxMs = 0.0
        val buckets = LongArray(BUCKET_COUNT)
    }

    private val metrics = HashMap<String, Histogram>()
    private var windowStartMs = now()

    @Synchronized
    fun add(metric: String, ms: Double) {
        if (!ms.isFinite() || metric !in PerfMetric.ORDER) return
        val clamped = ms.coerceIn(0.0, MAX_SAMPLE_MS)
        val h = metrics.getOrPut(metric) { Histogram() }
        h.buckets[bucketIndex(clamped)]++
        h.count++
        h.sumMs += clamped
        if (clamped > h.maxMs) h.maxMs = clamped
    }

    /** Samples held, across every metric. */
    @Synchronized
    fun pendingSamples(): Long = metrics.values.sumOf { it.count }

    /** Empties the window; null when nothing was sampled. */
    @Synchronized
    fun take(): PerfWindow? {
        val end = now()
        // The server refuses a window over seven days, and an app can stay alive that long without a flush.
        val start = max(windowStartMs, end - MAX_WINDOW_MS)
        windowStartMs = end
        val taken = HashMap(metrics)
        metrics.clear()
        val batches = PerfMetric.ORDER.mapNotNull { name ->
            val h = taken[name]?.takeIf { it.count > 0 } ?: return@mapNotNull null
            PerfMetricBatch(name, h.count, h.sumMs, h.maxMs, h.buckets.copyOf())
        }
        return if (batches.isEmpty()) null else PerfWindow(start, max(end, start), batches)
    }

    /** Puts an unsent window back, so its samples go out with the next one. */
    @Synchronized
    fun restore(window: PerfWindow) {
        windowStartMs = minOf(windowStartMs, window.startMs)
        for (m in window.metrics) {
            val h = metrics.getOrPut(m.name) { Histogram() }
            for (i in m.buckets.indices) h.buckets[i] += m.buckets[i]
            h.count += m.count
            h.sumMs += m.sumMs
            if (m.maxMs > h.maxMs) h.maxMs = m.maxMs
        }
    }

    companion object {
        /** Upper bounds in ms; the last range is everything above. Identical to the desktop app's and the server's. */
        val BUCKETS_MS = doubleArrayOf(
            1.0, 2.0, 4.0, 8.33, 16.67, 33.0, 50.0, 75.0, 100.0, 150.0, 200.0, 300.0, 500.0, 750.0,
            1000.0, 1500.0, 2000.0, 3000.0, 5000.0, 10000.0, 20000.0, 60000.0,
        )
        val BUCKET_COUNT = BUCKETS_MS.size + 1
        const val MAX_SAMPLE_MS = 60_000.0
        /** Six days: inside the server's seven-day limit on how long a window may be. */
        const val MAX_WINDOW_MS = 6L * 24 * 60 * 60 * 1000

        fun bucketIndex(ms: Double): Int {
            for (i in BUCKETS_MS.indices) if (ms <= BUCKETS_MS[i]) return i
            return BUCKETS_MS.size
        }
    }
}

/** What identifies the batch: the app, the OS and the hardware model, never a person. */
class PerfBatchMeta(
    /** Random and fresh for every launch, in the `install_id` field the desktop format already has. */
    val installId: String,
    val os: String,
    val arch: String,
    val appVersion: String,
    val osVersion: String,
    val device: String,
    val refreshHz: Int,
)

class PerfStatsBatch(val meta: PerfBatchMeta, val window: PerfWindow) {
    fun toJson(): JSONObject = JSONObject().apply {
        put("schema", SCHEMA)
        put("install_id", meta.installId)
        put("app_version", versionString(meta.appVersion))
        put("os", meta.os)
        put("arch", meta.arch)
        put("os_version", meta.osVersion)
        put("device", meta.device.filter { it in ALLOWED_DEVICE_CHARS }.take(MAX_DEVICE_LENGTH))
        put("refresh_hz", meta.refreshHz.coerceIn(MIN_REFRESH_HZ, MAX_REFRESH_HZ))
        put("window_start_ms", window.startMs)
        put("window_end_ms", max(window.endMs, window.startMs))
        put("metrics", JSONArray().apply {
            for (m in window.metrics) put(JSONObject().apply {
                put("name", m.name)
                put("count", m.count)
                put("sum_ms", round2(m.sumMs))
                put("max_ms", round2(m.maxMs))
                put("buckets", JSONArray().apply { m.buckets.forEach { put(it) } })
            })
        })
    }

    companion object {
        const val SCHEMA = "harness.mobile.stats.v1"
        const val MAX_DEVICE_LENGTH = 40
        const val MAX_VERSION_LENGTH = 32
        const val MIN_REFRESH_HZ = 24
        const val MAX_REFRESH_HZ = 240

        /** What the server accepts in a device model: letters, digits and ` ,._()-`. */
        private val ALLOWED_DEVICE_CHARS: Set<Char> = (('a'..'z') + ('A'..'Z') + ('0'..'9') + " ,._()-".toList()).toSet()

        private val ALLOWED_VERSION_CHARS: Set<Char> = (('a'..'z') + ('A'..'Z') + ('0'..'9') + ".+-".toList()).toSet()

        /** What the server accepts in a version: letters, digits and `.+-`, up to 32 characters; anything else becomes `-`. */
        internal fun versionString(raw: String): String =
            raw.map { if (it in ALLOWED_VERSION_CHARS) it else '-' }.joinToString("").take(MAX_VERSION_LENGTH).ifEmpty { "0" }

        private fun round2(x: Double) = floor(x * 100 + 0.5) / 100
    }
}
